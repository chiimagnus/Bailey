import AppKit
import Darwin
import ImageIO
import WebKit
import XCTest
@testable import Bailey

@MainActor
final class SVGArtworkTests: XCTestCase {
    static func compressedSVGBytes() throws -> Data {
        try XCTUnwrap(Data(base64Encoded:
            "H4sIAAAAAAAAAxXMQQ6DMAwF0atY/wDYhF0VZ8FNqpImkdJSgYU5fmE9TxP3o9D56d9dUc1+D2Z3H3wa1q1wEBG+BOho2ef1VAgJBaFRkOKWX0beFquKIKCaW6mmuCK9W+8Ky88OTvGepD+3uwqDbAAAAA=="
        ))
    }

    private static let blur = """
        <svg xmlns="http://www.w3.org/2000/svg" width="48" height="48">
          <defs>
            <filter id="soft" filterUnits="userSpaceOnUse" x="0" y="0" width="48" height="48">
              <feGaussianBlur stdDeviation="2"/>
            </filter>
          </defs>
          <rect x="16" y="16" width="16" height="16" fill="red" filter="url(#soft)"/>
        </svg>
        """

    func testPNGOutputHasExactDimensionsAlphaAndColorProfileWithinBudget() async throws {
        let source = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="4" height="2">
              <rect width="2" height="2" fill="#ff0000" opacity="0.5"/>
            </svg>
            """.utf8)
        let vector = try SVGArtwork.parse(source)
        for (width, height, background, space) in [
            (1, 1, SVGArtwork.PNGOptions.Background.transparent, SVGArtwork.PNGOptions.ColorSpace.sRGB),
            (80, 40, .transparent, .displayP3), (40, 80, .white, .sRGB),
            (32_768, 1, .black, .displayP3), (4_000, 2_000, .transparent, .sRGB),
        ] {
            let png = try await SVGArtwork.png(vector, options: .init(width: width, height: height,
                                                                       colorSpace: space, background: background))
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            XCTAssertEqual(image.width, width)
            XCTAssertEqual(image.height, height)
            let profile = try XCTUnwrap(image.colorSpace?.copyICCData())
            XCTAssertGreaterThan(CFDataGetLength(profile), 0)
            if space == .displayP3 {
                let expected = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData())
                XCTAssertEqual(profile as Data, expected as Data)
            }
            if width == 80 {
                let bitmap = NSBitmapImageRep(cgImage: image)
                let red = try XCTUnwrap(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
                let empty = try XCTUnwrap(bitmap.colorAt(x: 60, y: 20)?.usingColorSpace(.sRGB))
                XCTAssertEqual(red.alphaComponent, 0.5, accuracy: 0.02)
                XCTAssertGreaterThan(red.redComponent - red.greenComponent, 0.6)
                XCTAssertEqual(empty.alphaComponent, 0, accuracy: 0.01)
            } else if width == 40 {
                let bitmap = NSBitmapImageRep(cgImage: image)
                let empty = try XCTUnwrap(bitmap.colorAt(x: 20, y: 4)?.usingColorSpace(.sRGB))
                XCTAssertEqual(empty.alphaComponent, 1, accuracy: 0.01)
                XCTAssertEqual(empty.redComponent, 1, accuracy: 0.01)
                XCTAssertEqual(empty.greenComponent, 1, accuracy: 0.01)
                XCTAssertEqual(empty.blueComponent, 1, accuracy: 0.01)
            }
        }
        for (width, height) in [(0, 1), (-1, 1), (32_769, 1), (4_001, 2_000), (Int.max, Int.max)] {
            do {
                _ = try await SVGArtwork.png(vector, options: .init(width: width, height: height))
                XCTFail("Invalid dimensions must not allocate a bitmap")
            } catch WorkspaceError.tooLarge {}
        }
        let blur = try SVGArtwork.parse(Data(Self.blur.utf8))
        let png = try await SVGArtwork.png(blur, options: .init(width: 192, height: 192))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let softEdge = try XCTUnwrap(bitmap.colorAt(x: 58, y: 96)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(softEdge.alphaComponent * (softEdge.redComponent - softEdge.greenComponent), 0.04)
    }

    func testPNGOutputUsesCurrentDraftAndDoesNotReplaceDestinationsOrSource() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Artwork.svg")
        let original = """
            <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">
              <rect width="16" height="16" fill="red"/>
            </svg>
            """
        let initialBytes = Data(original.utf8)
        try initialBytes.write(to: source)
        let file = FileTab(path: source.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        defer { file.retireContent() }
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let first = file.textPreviewRequestID
        await file.showSVGPreview(request: first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let options = SVGArtwork.PNGOptions(width: 32, height: 32)
        try await file.copySVGPNG(request: first, options: options, to: pasteboard)
        let red = try XCTUnwrap(pasteboard.data(forType: .png))
        let redBitmap = try XCTUnwrap(NSBitmapImageRep(data: red))
        XCTAssertGreaterThan(try XCTUnwrap(redBitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.sRGB)).redComponent, 0.9)

        file.text = original.replacingOccurrences(of: "red", with: "blue")
        file.refreshDirtyState()
        XCTAssertTrue(file.isDirty)
        let staleTarget = root.appending(path: "stale.png")
        do {
            try await file.exportSVGPNG(request: first, options: options, to: staleTarget)
            XCTFail("An old drawing must not be exported as the current draft")
        } catch WorkspaceError.changedExternally {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTarget.path))
        let current = file.textPreviewRequestID
        await file.showSVGPreview(request: current)
        try await file.copySVGPNG(request: current, options: options, to: pasteboard)
        let blue = try XCTUnwrap(pasteboard.data(forType: .png))
        let blueBitmap = try XCTUnwrap(NSBitmapImageRep(data: blue))
        XCTAssertGreaterThan(try XCTUnwrap(blueBitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.sRGB)).blueComponent, 0.9)
        XCTAssertNotEqual(red, blue)
        let target = root.appending(path: "Artwork.png")
        try await file.exportSVGPNG(request: current, options: options, to: target)
        XCTAssertEqual(try Data(contentsOf: target), blue)
        let link = root.appending(path: "link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let dangling = root.appending(path: "missing.png")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appending(path: "missing-target"))
        let folder = root.appending(path: "folder.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for occupied in [target, link, dangling, folder] {
            do {
                try await file.exportSVGPNG(request: current, options: .init(width: 16, height: 16), to: occupied)
                XCTFail("Export must never overwrite an existing destination: \(occupied.lastPathComponent)")
            } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: target), blue)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path))
        let denied = root.appending(path: "missing-dir/output.png")
        do {
            try await file.exportSVGPNG(request: current, options: options, to: denied)
            XCTFail("Missing destination parent must be reported")
        } catch {}
        let readonly = root.appending(path: "readonly")
        try FileManager.default.createDirectory(at: readonly, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonly.path)
        do {
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonly.path) }
            do {
                try await file.exportSVGPNG(request: current, options: options, to: readonly.appending(path: "output.png"))
                XCTFail("A read-only destination must reject export")
            } catch {}
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: readonly.path), [])
        }
        try FileManager.default.removeItem(at: readonly)
        let cancelledTarget = root.appending(path: "cancelled.png")
        let cancelled = Task { try await file.exportSVGPNG(request: current, options: options, to: cancelledTarget) }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled export must not publish") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledTarget.path))
        XCTAssertEqual(try Data(contentsOf: source), initialBytes)
        XCTAssertTrue(file.isDirty)
        XCTAssertNil(file.saveError)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       Set(["Artwork.svg", "Artwork.png", "link.png", "missing.png", "folder.png"]))
        file.text = "<svg>"
        await file.showSVGPreview(request: file.textPreviewRequestID)
        do {
            try await file.copySVGPNG(request: file.textPreviewRequestID, options: options, to: pasteboard)
            XCTFail("An invalid draft must not publish the retained last valid drawing")
        } catch WorkspaceError.changedExternally {}
        XCTAssertEqual(pasteboard.data(forType: .png), blue)
        XCTAssertEqual(try Data(contentsOf: source), initialBytes)
        // An explicit source save still uses the existing TextKit conditional
        // write, and reopening produces the same output from the new bytes.
        file.text = original.replacingOccurrences(of: "red", with: "blue")
        await file.save()
        XCTAssertFalse(file.isDirty)
        XCTAssertNil(file.saveError)
        XCTAssertEqual(try Data(contentsOf: source), Data(file.text.utf8))
        XCTAssertEqual(try Data(contentsOf: target), blue)
        let reopened = FileTab(path: source.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        defer { reopened.retireContent() }
        try await reopened.waitForText()
        await reopened.showSVGPreview(request: reopened.textPreviewRequestID)
        try await reopened.copySVGPNG(request: reopened.textPreviewRequestID, options: options, to: pasteboard)
        XCTAssertEqual(pasteboard.data(forType: .png), blue)

    }

    func testExclusiveOutputPublicationAllowsExactlyOneConcurrentWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "output.png")
        let first = Data(repeating: 0x11, count: 512 * 1024)
        let second = Data(repeating: 0x22, count: 512 * 1024)
        func publish(_ data: Data) async -> Bool {
            do {
                try await LocalWorkspaceBackend.shared.writeNewFile(path: target.path, data: data)
                return true
            } catch {
                let failure = error as NSError
                XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
                XCTAssertEqual(failure.code, Int(EEXIST))
                return false
            }
        }
        async let left = publish(first)
        async let right = publish(second)
        let (leftWon, rightWon) = await (left, right)
        XCTAssertNotEqual(leftWon, rightWon)
        XCTAssertEqual(try Data(contentsOf: target), leftWon ? first : second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["output.png"])
    }

    func testNativeCanvasSettlesTheCurrentSVGFilterWithoutReusingOldPixels() async throws {
        let svg = try SVGArtwork.parse(Data(Self.blur.utf8)).image
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = SVGPreviewScrollView()
        window.contentView = scroll
        window.orderBack(nil)
        scroll.install(svg, request: "settled-blur")
        scroll.layoutSubtreeIfNeeded()
        scroll.setZoom(4, at: CGPoint(x: 24, y: 24))
        let canvas = try XCTUnwrap(scroll.documentView)
        func shades(_ contrast: (NSColor) -> CGFloat) throws -> (near: CGFloat, far: CGFloat) {
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            func shade(at sourceX: CGFloat) throws -> CGFloat {
                let point = canvas.convert(CGPoint(x: sourceX, y: 24), to: scroll)
                let column = Int(point.x * CGFloat(bitmap.pixelsWide) / scroll.bounds.width)
                let row = Int(point.y * CGFloat(bitmap.pixelsHigh) / scroll.bounds.height)
                let pixel = try XCTUnwrap(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB))
                return contrast(pixel) * pixel.alphaComponent
            }
            return (try shade(at: 14.5), try shade(at: 3))
        }
        func settled(_ contrast: (NSColor) -> CGFloat) async throws -> (near: CGFloat, far: CGFloat) {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var pixels = try shades(contrast)
            while pixels.near < 0.04, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                pixels = try shades(contrast)
            }
            return pixels
        }
        let red = try await settled { $0.redComponent - $0.greenComponent }
        XCTAssertGreaterThan(red.near, 0.04)
        XCTAssertLessThan(red.far, 0.02)

        let revised = Self.blur.replacingOccurrences(of: "fill=\"red\"", with: "fill=\"blue\"")
        scroll.install(try SVGArtwork.parse(Data(revised.utf8)).image, request: "revised-blur")
        scroll.layoutSubtreeIfNeeded()
        scroll.setZoom(4, at: CGPoint(x: 24, y: 24))
        let blue = try await settled { $0.blueComponent - $0.greenComponent }
        XCTAssertGreaterThan(blue.near, 0.04)
        XCTAssertLessThan(blue.far, 0.02)
        XCTAssertLessThan(try shades { $0.redComponent - $0.greenComponent }.near, 0.02)
    }

    func testRepeatedNativeMountsReleaseCanvasesAcrossAppearances() throws {
        let svg = try SVGArtwork.parse(Data(Self.blur.utf8)).image
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }
        var before = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        let started = ContinuousClock.now
        for serial in 0..<100 {
            try autoreleasepool {
                window.appearance = NSAppearance(named: serial.isMultiple(of: 2) ? .aqua : .darkAqua)
                let scroll = SVGPreviewScrollView()
                window.contentView = scroll
                scroll.install(svg, request: String(serial))
                scroll.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let canvas = try XCTUnwrap(scroll.documentView)
                XCTAssertEqual(canvas.subviews.count, 1)
                scroll.clear()
                XCTAssertTrue(canvas.subviews.isEmpty)
                window.contentView = nil
            }
        }
        var after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        print("SVG_MOUNTS count=100 elapsed=\(started.duration(to: .now)) maxrss_before=\(before.ru_maxrss) maxrss_after=\(after.ru_maxrss)")
    }

    func testDecodedUnicodeSourceIsNotReinterpretedUsingItsDiskDeclaration() throws {
        for encoding in ["UTF-16", "GB18030"] {
            let source = "<?xml version=\"1.0\" encoding=\"\(encoding)\"?>"
                + "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"20\">"
                + "<text x=\"2\" y=\"14\">中文</text></svg>"
            let result = try SVGArtwork.sanitizedXML(Data(source.utf8))
            XCTAssertTrue(result.xml.contains("中文"), "A decoded source snapshot is already Unicode")
            XCTAssertEqual(try SVGArtwork.parse(Data(source.utf8)).image.size, CGSize(width: 60, height: 20))
            if encoding == "UTF-16" {
                let originalBytes = try XCTUnwrap(source.data(using: .utf16))
                XCTAssertTrue(try SVGArtwork.sanitizedXML(originalBytes).xml.contains("中文"))
            }
        }
    }

    func testNativeViewportResolvesQuarterPixelVectorBandsAtFourHundredPercent() throws {
        let stripes = (0..<40).map { column in
            "<rect x=\"\(10 + Double(column) * 0.5)\" width=\"0.25\" height=\"40\" fill=\"black\"/>"
        }.joined()
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" width="80" height="40">
              <rect width="80" height="40" fill="white"/>\(stripes)
            </svg>
            """
        let svg = try SVGArtwork.parse(Data(source.utf8)).image
        let frame = CGRect(x: 0, y: 0, width: 380, height: 260)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = SVGPreviewScrollView()
        window.contentView = scroll
        window.orderBack(nil)
        scroll.install(svg, request: "fine-lines")
        scroll.layoutSubtreeIfNeeded()
        scroll.setZoom(4, at: CGPoint(x: 40, y: 20))
        scroll.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(scroll.pixelScale, 4, accuracy: 0.001)
        let canvas = try XCTUnwrap(scroll.documentView)
        let start = canvas.convert(CGPoint(x: 12, y: 20), to: scroll)
        let end = canvas.convert(CGPoint(x: 28, y: 20), to: scroll)
        let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / scroll.bounds.width
        let sampleRow = Int(start.y * CGFloat(bitmap.pixelsHigh) / scroll.bounds.height)
        let colors = try (Int(start.x * scale)..<Int(end.x * scale)).map { column in
            try XCTUnwrap(bitmap.colorAt(x: column, y: sampleRow)?.usingColorSpace(.deviceRGB))
        }
        XCTAssertTrue(colors.allSatisfy { $0.alphaComponent > 0.98 })
        let transitions = zip(colors, colors.dropFirst()).filter { left, right in
            abs(left.redComponent - right.redComponent) > 0.5
        }.count
        XCTAssertGreaterThan(transitions, 30,
                             "Vector bands that merge at intrinsic size must resolve at current device scale")
    }

    func testCancellationWhileParsingAndDrawingLargeSVGDoesNotPublishPixels() async throws {
        let commands = String(repeating: "L20 24L21 25", count: 65_000)
        let source = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="64" height="48">
              <rect width="64" height="48" fill="#00cc00"/>
              <path d="M20 24\(commands)" fill="none" stroke="red"/>
            </svg>
            """.utf8)
        XCTAssertGreaterThan(source.count, SVGArtwork.byteLimit / 2)
        XCTAssertLessThan(source.count, SVGArtwork.byteLimit)
        let controlStarted = ContinuousClock.now
        let control = try await Task.detached { try SVGArtwork.render(source) }.value
        let controlDuration = controlStarted.duration(to: .now)
        XCTAssertEqual(control.pointSize, CGSize(width: 64, height: 48))
        let bitmap = NSBitmapImageRep(cgImage: control.image)
        let green = try XCTUnwrap(bitmap.colorAt(x: 90, y: 60)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(green.greenComponent - green.redComponent, 0.4)

        // The signal comes from the worker, not from its creator. The valid
        // near-limit path is already being consumed when the task is cancelled.
        for delay in [Duration.milliseconds(1), .milliseconds(12)] {
            let signal = AsyncStream<Void>.makeStream()
            let worker = Task.detached {
                signal.continuation.yield(())
                signal.continuation.finish()
                return try SVGArtwork.render(source)
            }
            var events = signal.stream.makeAsyncIterator()
            _ = await events.next()
            try await Task.sleep(for: delay)
            let cancelledAt = ContinuousClock.now
            worker.cancel()
            do {
                _ = try await worker.value
                XCTFail("A cancelled SVG request must not publish a raster")
            } catch is CancellationError {
                print("SVG_CANCEL bytes=\(source.count) control=\(controlDuration) delay=\(delay) retire=\(cancelledAt.duration(to: .now))")
            }
        }
    }

    func testRealSVGFilesKeepSourceAtTextLimitAndRefuseBeyondIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Large.svg")
        let xml = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"16\"/>".utf8)
        for delta in [-1, 0, 1] {
            let size = (32 << 20) + delta
            var bytes = xml
            bytes.append(Data(repeating: 0x20, count: size - bytes.count))
            try bytes.write(to: path, options: .atomic)
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            defer { file.retireContent() }
            if delta <= 0 {
                try await file.waitForText()
                XCTAssertTrue(file.canPreviewFile)
                XCTAssertTrue(file.showsFilePreview)
                XCTAssertEqual(Data(file.text.utf8), bytes)
                XCTAssertThrowsError(try SVGArtwork.parse(Data(file.text.utf8))) { error in
                    guard case WorkspaceError.tooLarge = error else { return XCTFail("Expected SVG preview budget: \(error)") }
                }
                file.setFilePreview(false)
                XCTAssertFalse(file.showsFilePreview)
                XCTAssertFalse(file.isDirty)
                XCTAssertEqual(file.nativeTextStorage.length, size)
            } else {
                do {
                    try await file.waitForText()
                    XCTFail("A source file above 32 MiB must not enter the editor")
                } catch {
                    guard case .unavailable = file.content else { return XCTFail("Expected unavailable file: \(error)") }
                    XCTAssertFalse(file.canPreviewFile)
                    XCTAssertTrue(file.text.isEmpty)
                }
            }
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }

    func testSharedSVGByteDepthAndNodeLimitsKeepExactBoundaries() throws {
        let start = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"16\">"
        let end = "</svg>"
        let root = start + end
        let exact = root + String(repeating: " ", count: SVGArtwork.byteLimit - root.utf8.count)
        XCTAssertEqual(try SVGArtwork.parse(Data(exact.utf8.dropLast())).image.size, CGSize(width: 24, height: 16))
        XCTAssertEqual(try SVGArtwork.parse(Data(exact.utf8)).image.size, CGSize(width: 24, height: 16))
        XCTAssertThrowsError(try SVGArtwork.parse(Data((exact + " ").utf8))) { error in
            guard case WorkspaceError.tooLarge = error else { return XCTFail("Expected SVG byte limit: \(error)") }
        }
        for depth in [48, 49] {
            let text = start + String(repeating: "<g>", count: depth)
                + String(repeating: "</g>", count: depth) + end
            if depth == 48 {
                XCTAssertTrue(try SVGArtwork.sanitizedXML(Data(text.utf8)).omitted.isEmpty)
            } else {
                XCTAssertThrowsError(try SVGArtwork.sanitizedXML(Data(text.utf8)))
            }
        }
        for nodes in [8191, 8192] {
            let data = Data((start + String(repeating: "<rect/>", count: nodes) + end).utf8)
            if nodes == 8191 {
                XCTAssertTrue(try SVGArtwork.sanitizedXML(data).omitted.isEmpty)
            } else {
                XCTAssertThrowsError(try SVGArtwork.sanitizedXML(data))
            }
        }
    }

    func testSharedRendererPlacesLocalSymbolsAndNestedInstances() throws {
        let source = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
                 width="64" height="24">
              <defs>
                <linearGradient id="ink"><stop offset="0" stop-color="#00aaff"/><stop offset="1" stop-color="#00aaff"/></linearGradient>
                <symbol id="tile" viewBox="0 0 8 8"><rect width="8" height="8"/></symbol>
                <g id="stamp"><use xlink:href="#tile" width="12" height="12"/></g>
              </defs>
              <use href="#stamp" x="6" y="5" style="fill: url('#ink')"/>
              <use href="#tile" x="33" y="5" width="16" height="12" fill="#ff2200"/>
              <use x="55" href="#not-present"/>
            </svg>
            """.utf8)
        let vector = try SVGArtwork.parse(source)
        XCTAssertEqual(vector.omitted, ["use"])
        let bitmap = NSBitmapImageRep(cgImage: try SVGArtwork.render(source).image)
        let nested = try XCTUnwrap(bitmap.colorAt(x: 24, y: 22)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(nested.alphaComponent, 0.98)
        XCTAssertGreaterThan(nested.blueComponent, 0.95)
        XCTAssertLessThan(nested.redComponent, 0.05)
        let symbol = try XCTUnwrap(bitmap.colorAt(x: 84, y: 22)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(symbol.alphaComponent, 0.98)
        XCTAssertGreaterThan(symbol.redComponent, 0.95)
        XCTAssertLessThan(symbol.blueComponent, 0.05)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 66, y: 22)).alphaComponent, 0.02,
                          "The symbol viewBox stays centered inside its wider viewport")
    }

    func testLocalInstancesShareTheExpandedGeometryBudget() throws {
        let shapes = (0..<31).map { column in
            "<rect x=\"\(column)\" width=\"1\" height=\"1\"/>"
        }.joined()
        func artwork(instances: Int) -> Data {
            let stamps = (0..<instances).map { row in "<use href=\"#row\" y=\"\(row)\"/>" }.joined()
            return Data("""
                <svg xmlns="http://www.w3.org/2000/svg" width="32" height="128">
                  <defs><g id="row">\(shapes)</g></defs>\(stamps)
                </svg>
                """.utf8)
        }
        XCTAssertTrue(try SVGArtwork.sanitizedXML(artwork(instances: 247)).omitted.isEmpty)
        XCTAssertThrowsError(try SVGArtwork.sanitizedXML(artwork(instances: 248))) { error in
            guard case WorkspaceError.tooLarge = error else { return XCTFail("Expected expanded SVG limit: \(error)") }
        }
    }

    func testPaintAndClippingReferencesShareExpandedBudgetWithoutUse() throws {
        for (element, attribute, member) in [
            ("clipPath", "clip-path", "<rect width=\"1\" height=\"1\"/>"),
            ("mask", "mask", "<rect width=\"1\" height=\"1\" fill=\"white\"/>"),
            ("filter", "filter", "<feOffset dx=\"1\" dy=\"0\"/>"),
        ] {
            func artwork(references: Int) -> Data {
                let definition = "<\(element) id=\"shared\">" + String(repeating: member, count: 31) + "</\(element)>"
                let shapes = String(repeating: "<rect width=\"1\" height=\"1\" \(attribute)=\"url(#shared)\"/>", count: references)
                return Data("""
                    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">
                      <defs>\(definition)</defs>\(shapes)
                    </svg>
                    """.utf8)
            }
            XCTAssertTrue(try SVGArtwork.sanitizedXML(artwork(references: 247)).omitted.isEmpty, element)
            XCTAssertThrowsError(try SVGArtwork.sanitizedXML(artwork(references: 248)), element) { error in
                guard case WorkspaceError.tooLarge = error else { return XCTFail("Expected expanded SVG limit: \(error)") }
            }
        }
        let gradient = "<linearGradient id=\"shared\">" + String(repeating: "<stop offset=\"0\" stop-color=\"red\"/>", count: 31) + "</linearGradient>"
        func painted(references: Int) -> Data {
            let shapes = String(repeating: "<rect width=\"1\" height=\"1\" fill=\"url(#shared)\"/>", count: references)
            return Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><defs>\(gradient)</defs>\(shapes)</svg>".utf8)
        }
        XCTAssertTrue(try SVGArtwork.sanitizedXML(painted(references: 125)).omitted.isEmpty)
        XCTAssertThrowsError(try SVGArtwork.sanitizedXML(painted(references: 126))) { error in
            guard case WorkspaceError.tooLarge = error else { return XCTFail("Expected expanded gradient limit: \(error)") }
        }
    }

    func testExpandedGeometryBudgetIncludesReusedPathData() throws {
        let contour = "M1 1" + String(repeating: " l1 0 l0 1 l-1 0 l0 -1", count: 2048) + " z"
        let copiesAtLimit = SVGArtwork.byteLimit / contour.utf8.count
        func artwork(instances: Int) -> Data {
            let stamps = (0..<instances).map { column in "<use href=\"#tile\" x=\"\(column * 4)\"/>" }.joined()
            return Data("""
                <svg xmlns="http://www.w3.org/2000/svg" width="128" height="4">
                  <defs><path id="tile" d="\(contour)"/></defs>\(stamps)
                </svg>
                """.utf8)
        }
        XCTAssertTrue(try SVGArtwork.sanitizedXML(artwork(instances: copiesAtLimit - 2)).omitted.isEmpty)
        XCTAssertThrowsError(try SVGArtwork.sanitizedXML(artwork(instances: copiesAtLimit))) { error in
            guard case WorkspaceError.tooLarge = error else { return XCTFail("Expected expanded SVG size: \(error)") }
        }
    }

    func testDocumentSampleAndBlurHaveObservablePixels() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent(".github/features/svg-source-preview/demo-plot.svg")
        let sample = try Data(contentsOf: file)
        let vector = try SVGArtwork.parse(sample)
        XCTAssertEqual(vector.image.size, CGSize(width: 900, height: 520))
        XCTAssertTrue(vector.omitted.isEmpty)
        let plot = NSBitmapImageRep(cgImage: try SVGArtwork.render(sample).image)
        let background = try XCTUnwrap(plot.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(background.alphaComponent, 0.95)
        XCTAssertGreaterThan(background.redComponent, 0.75)
        XCTAssertEqual(try Data(contentsOf: file), sample)

        let bitmap = NSBitmapImageRep(cgImage: try SVGArtwork.render(Data(Self.blur.utf8)).image)
        let inside = try XCTUnwrap(bitmap.colorAt(x: 48, y: 48)?.usingColorSpace(.deviceRGB))
        let near = try XCTUnwrap(bitmap.colorAt(x: 29, y: 48)?.usingColorSpace(.deviceRGB))
        let far = try XCTUnwrap(bitmap.colorAt(x: 3, y: 48)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(inside.alphaComponent, 0.9)
        XCTAssertGreaterThan(near.alphaComponent, 0.04)
        XCTAssertLessThan(near.alphaComponent, 0.6)
        XCTAssertLessThan(far.alphaComponent, 0.02)
    }

    func testNativePatternsAndEmbeddedRasterProduceRealPixels() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        for (type, mime) in [(NSBitmapImageRep.FileType.png, "image/png"), (.jpeg, "image/jpeg")] {
            let data = try XCTUnwrap(rep.representation(using: type, properties: [:]))
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
            let originalColor = try XCTUnwrap(decoded.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(originalColor.greenComponent - max(originalColor.redComponent, originalColor.blueComponent), 0.8)
            let href = "data:\(mime);base64,\(data.base64EncodedString())"
            let source = Data("""
                <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="40" height="16">
                  <defs>
                    <pattern id="tile" width="8" height="8" patternUnits="userSpaceOnUse">
                      <rect width="8" height="8" fill="red"/>
                      <rect x="4" width="4" height="8" fill="blue"/>
                    </pattern>
                    <pattern id="inherited" xlink:href="#tile"/>
                    <image id="embedded" width="8" height="8" href="\(href)"/>
                  </defs>
                  <rect width="24" height="16" fill="url(#inherited)"/>
                  <use href="#embedded" x="24" y="0"/>
                  <image x="32" y="8" width="8" height="8" xlink:href="\(href)"/>
                </svg>
                """.utf8)
            let vector = try SVGArtwork.parse(source)
            XCTAssertTrue(vector.omitted.isEmpty, "\(vector.omitted)")
            let png = try await SVGArtwork.png(vector, options: .init(width: 80, height: 32))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
            func color(_ x: Int, _ y: Int) throws -> NSColor {
                try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            }
            for x in [4, 20, 36] {
                let red = try color(x, 8)
                let blue = try color(x + 8, 8)
                XCTAssertGreaterThan(red.redComponent - red.blueComponent, 0.7)
                XCTAssertGreaterThan(blue.blueComponent - blue.redComponent, 0.7)
            }
            for (x, y) in [(56, 8), (72, 24)] {
                let green = try color(x, y)
                XCTAssertGreaterThan(green.greenComponent - max(green.redComponent, green.blueComponent), 0.6,
                                     "Embedded \(mime) at \(x),\(y): \(green)")
            }
            XCTAssertLessThan(try color(56, 24).alphaComponent, 0.01)
        }
    }

    func testOpaquePatternHasNoTileSeamsAtFractionalOutputScales() async throws {
        let bytes = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="360" height="220" viewBox="-180 -110 360 220">
              <defs>
                <pattern id="paper" width="2" height="2" patternUnits="userSpaceOnUse">
                  <rect width="2" height="2" fill="#f11a14"/>
                </pattern>
                <symbol id="sheet" viewBox="0 0 36 22"><rect width="36" height="22"/></symbol>
              </defs>
              <use href="#sheet" x="-180" y="-110" width="360" height="220" fill="url(#paper)"/>
            </svg>
            """.utf8)
        let vector = try SVGArtwork.parse(bytes)
        for (width, colorSpace) in [
            (439, SVGArtwork.PNGOptions.ColorSpace.sRGB), (675, .displayP3),
            (719, .sRGB), (720, .displayP3), (1087, .sRGB),
        ] {
            let height = (width * 220 + 359) / 360
            let png = try await SVGArtwork.png(vector, options: .init(width: width, height: height,
                                                                       colorSpace: colorSpace))
            let pixels = try sRGBBitmap(png)
            var mismatches = 0
            pixels.bytes.withUnsafeBytes { (rgba: UnsafeRawBufferPointer) in
                for y in 10..<(height - 10) {
                    for x in 10..<(width - 10) {
                        let index = y * pixels.bytesPerRow + x * 4
                        if rgba[index + 3] != 255 || rgba[index] < 230 ||
                            rgba[index + 1] > 35 || rgba[index + 2] > 30 {
                            mismatches += 1
                        }
                    }
                }
            }
            XCTAssertEqual(mismatches, 0, "Unexpected transparency or color at \(width) pixels")
        }
    }

    func testFractionalPatternKeepsPhaseClippingAndOpacityAcrossTheOutput() async throws {
        for (matrix, width, height) in [
            (CGAffineTransform.identity, 675, 338), (.identity, 3375, 1688),
            (CGAffineTransform(a: -1, b: 0.23, c: 0.17, d: 1, tx: 11.25, ty: -25.3), 2250, 1125),
        ] {
            let bytes = Data("""
                <svg xmlns="http://www.w3.org/2000/svg" width="360" height="180">
                  <defs>
                    <pattern id="tile" width="20" height="20" patternUnits="userSpaceOnUse"
                      patternTransform="matrix(\(matrix.a) \(matrix.b) \(matrix.c) \(matrix.d) \(matrix.tx) \(matrix.ty))">
                      <g opacity=".5">
                        <rect x="-4" width="9" height="20" fill="red"/>
                        <rect x="10" width="5" height="20" fill="blue"/>
                      </g>
                    </pattern>
                  </defs>
                  <rect width="360" height="180" fill="url(#tile)" fill-opacity=".5"/>
                </svg>
                """.utf8)
            let vector = try SVGArtwork.parse(bytes)
            let png = try await SVGArtwork.png(vector, options: .init(width: width, height: height))
            let pixels = try sRGBBitmap(png)
            let scale = min(CGFloat(width) / 360, CGFloat(height) / 180)
            let toPixel = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                           tx: (CGFloat(width) - 360 * scale) / 2,
                                           ty: (CGFloat(height) - 180 * scale) / 2)
            let toPattern = matrix.concatenating(toPixel).inverted()
            var mismatches = 0
            var checked = 0
            for y in stride(from: 10, to: height - 10, by: 19) {
                for x in 10..<(width - 10) {
                    let xInPattern = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(toPattern).x
                    let phase = xInPattern - floor(xInPattern / 20) * 20
                    let part = Int(phase / 5)
                    let offset = phase - CGFloat(part * 5)
                    // Only exclude the antialiasing footprint of the actual color transition,
                    // never the distance to a guessed or rounded repeat boundary.
                    guard min(offset, 5 - offset) / hypot(toPattern.a, toPattern.c) > 1.05 else { continue }
                    let index = y * pixels.bytesPerRow + x * 4
                    let alpha = Int(pixels.bytes[index + 3])
                    if part == 0 {
                        if abs(alpha - 64) > 1 || Int(pixels.bytes[index]) < 62 || pixels.bytes[index + 2] > 1 {
                            mismatches += 1
                        }
                    } else if part == 2 {
                        if abs(alpha - 64) > 1 || Int(pixels.bytes[index + 2]) < 62 || pixels.bytes[index] > 1 {
                            mismatches += 1
                        }
                    } else if alpha != 0 {
                        mismatches += 1
                    }
                    checked += 1
                }
            }
            XCTAssertGreaterThan(checked, 5_000)
            XCTAssertEqual(mismatches, 0, "Fractional pattern moved or changed alpha at \(width)×\(height)")
        }
    }

    func testFractionalPatternRespectsEvenOddFillAndDashedStroke() async throws {
        let bytes = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="96" height="48">
              <defs>
                <pattern id="ink" width="4.75" height="6.25" patternUnits="userSpaceOnUse">
                  <rect width="4.75" height="6.25" fill="red"/>
                </pattern>
              </defs>
              <path d="M 1 1 H 45 V 47 H 1 Z M 15 15 H 31 V 33 H 15 Z" fill="url(#ink)" fill-rule="evenodd"/>
              <path d="M 52 15 H 92" fill="none" stroke="url(#ink)" stroke-width="8"
                stroke-dasharray="6 5" stroke-opacity=".5"/>
            </svg>
            """.utf8)
        let vector = try SVGArtwork.parse(bytes)
        let png = try await SVGArtwork.png(vector, options: .init(width: 240, height: 120))
        let bitmap = try sRGBBitmap(png)
        func sample(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try XCTUnwrap(bitmap.colorAt(x: Int(x * 2.5), y: Int(y * 2.5)))
        }
        for (x, y) in [(5.0, 15.0), (32.0, 27.0)] {
            let color = try sample(x, y)
            XCTAssertEqual(color.alphaComponent, 1)
            XCTAssertGreaterThan(color.redComponent, 0.98)
        }
        for (x, y) in [(54.0, 15.0), (65.0, 15.0), (77.0, 15.0)] {
            let color = try sample(x, y)
            XCTAssertEqual(color.alphaComponent, 0.5, accuracy: 0.01)
            XCTAssertGreaterThan(color.redComponent, 0.98)
        }
        for (x, y) in [(22.0, 22.0), (47.0, 22.0), (60.0, 15.0), (65.0, 9.0)] {
            XCTAssertEqual(try sample(x, y).alphaComponent, 0)
        }
    }

    func testPatternReferencesAndEmbeddedRasterAreBoundedAndCannotReadExternalResources() throws {
        let root = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"32\" height=\"16\">"
        func artwork(_ body: String) -> Data { Data((root + body + "</svg>").utf8) }
        for href in ["https://example.invalid/a.png", "file:///tmp/not-authorized.png",
                     "../private.png", "data:image/svg+xml;base64,PHN2Zy8+",
                     "data:image/png;base64,AAAA"] {
            let cleaned = try SVGArtwork.sanitizedXML(artwork("""
                <image x="0" width="8" height="8" href="\(href)"/>
                <pattern id="external" href="\(href)" width="8" height="8"><rect width="8" height="8" fill="red"/></pattern>
                <rect x="16" width="16" height="16" fill="green"/>
                """))
            XCTAssertTrue(cleaned.omitted.contains("image"))
            XCTAssertTrue(cleaned.omitted.contains("@href"))
            XCTAssertFalse(cleaned.xml.contains(href))
        }
        for cycle in [
            "<pattern id=\"a\" href=\"#a\" width=\"4\" height=\"4\"/>",
            "<pattern id=\"a\" href=\"#b\"/><pattern id=\"b\" href=\"#a\"/>",
            "<pattern id=\"a\" width=\"4\" height=\"4\"><rect width=\"4\" height=\"4\" fill=\"url(#a)\"/></pattern>",
        ] {
            XCTAssertThrowsError(try SVGArtwork.sanitizedXML(artwork("<defs>\(cycle)</defs><rect width=\"32\" height=\"16\" fill=\"url(#a)\"/>")))
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 4096, height: 4096,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let dataURI = "data:image/png;base64," + png.base64EncodedString()
        let one = "<image id=\"raster\" width=\"8\" height=\"8\" href=\"\(dataURI)\"/>"
        XCTAssertTrue(try SVGArtwork.sanitizedXML(artwork(one)).omitted.isEmpty)
        let repeated = "<defs>\(one)</defs><use href=\"#raster\"/><use href=\"#raster\" x=\"8\"/>"
        XCTAssertThrowsError(try SVGArtwork.sanitizedXML(artwork(repeated))) { error in
            guard case WorkspaceError.tooLarge = error else { return XCTFail("Expected decoded pixel budget: \(error)") }
        }
    }

    func testResearchSamplePlacesRealGeometryAndReportsOmittedElements() async throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_SVG_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_SVG_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        let file = URL(fileURLWithPath: root).appending(path: "graphics/复杂科研图.svg")
        let bytes = try Data(contentsOf: file)
        let vector = try SVGArtwork.parse(bytes)
        XCTAssertEqual(vector.image.size, CGSize(width: 1400, height: 620))
        XCTAssertTrue(vector.omitted.isEmpty, "The real research plot now retains its supported grid pattern")
        let raster = try SVGArtwork.render(bytes)
        XCTAssertEqual(raster.pointSize, vector.image.size)
        let bitmap = try sRGBBitmap(raster.image)
        XCTAssertEqual(bitmap.pixelsWide, 2048)

        func pixel(at point: CGPoint) throws -> NSColor {
            let column = Int((point.x + 80) * CGFloat(bitmap.pixelsWide) / 1400)
            let row = Int((point.y + 40) * CGFloat(bitmap.pixelsHigh) / 620)
            return try XCTUnwrap(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB))
        }

        let background = try pixel(at: CGPoint(x: -60, y: -20))
        XCTAssertGreaterThan(background.alphaComponent, 0.98)
        XCTAssertGreaterThan(background.redComponent, 0.9)
        let axis = try pixel(at: CGPoint(x: 760, y: 440))
        XCTAssertLessThan(axis.redComponent, 0.45)
        XCTAssertGreaterThan(axis.blueComponent, axis.redComponent)
        let offAxis = try pixel(at: CGPoint(x: 760, y: 446))
        XCTAssertGreaterThan(offAxis.redComponent, 0.9)

        let samples = [
            CGPoint(x: 230, y: 135), CGPoint(x: 1000, y: 135),
            CGPoint(x: 346, y: 280), CGPoint(x: 580, y: 138), CGPoint(x: 855, y: 214),
        ]
        let expected = try await referencePixels(bytes, coordinates: samples.map { [Int($0.x) + 80, Int($0.y) + 40] })
        XCTAssertEqual(expected.count, samples.count)
        for (point, target) in zip(samples, expected) {
            let rendered = try pixel(at: point)
            let channels = [rendered.redComponent, rendered.greenComponent, rendered.blueComponent, rendered.alphaComponent]
            XCTAssertEqual(target.count, channels.count)
            for (component, value) in zip(channels, target) {
                XCTAssertEqual(component, Double(value) / 255, accuracy: 0.12,
                               "Gradients and reused markers must agree with the native reference at \(point)")
            }
        }
        let glyphPixels = try stride(from: 160, to: 255, by: 2).flatMap { column in
            try stride(from: 1, to: 25, by: 2).map { row in
                try pixel(at: CGPoint(x: column, y: row))
            }
        }
        XCTAssertGreaterThan(glyphPixels.filter { $0.redComponent < 0.45 }.count, 12,
                             "The Chinese heading must render dark glyph strokes, not just its background")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    /// Sample color-managed RGBA bytes directly. NSBitmapImageRep.colorAt can
    /// reinterpret even tagged sRGB components as device RGB on this host.
    private struct SRGBBitmap {
        let pixelsWide: Int
        let pixelsHigh: Int
        let bytesPerRow: Int
        let bytes: Data

        func colorAt(x: Int, y: Int) -> NSColor? {
            guard (0..<pixelsWide).contains(x), (0..<pixelsHigh).contains(y) else { return nil }
            let offset = y * bytesPerRow + x * 4
            let alpha = CGFloat(bytes[offset + 3])
            guard alpha > 0 else { return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0) }
            return NSColor(srgbRed: min(1, CGFloat(bytes[offset]) / alpha),
                           green: min(1, CGFloat(bytes[offset + 1]) / alpha),
                           blue: min(1, CGFloat(bytes[offset + 2]) / alpha),
                           alpha: alpha / 255)
        }
    }

    private func sRGBBitmap(_ image: CGImage) throws -> SRGBBitmap {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return SRGBBitmap(pixelsWide: image.width, pixelsHigh: image.height,
                          bytesPerRow: context.bytesPerRow,
                          bytes: Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * image.height))
    }

    private func sRGBBitmap(_ data: Data) throws -> SRGBBitmap {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try sRGBBitmap(XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    func testAsymmetricPatternKeepsDocumentCoordinatesAcrossRasterAndNativeOutput() async throws {
        // Neither the viewBox origin nor the output height is a multiple of
        // the tile period. A symmetric checkerboard would hide a flipped tile.
        let bytes = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="140" height="94" viewBox="-17 -13 140 94">
              <defs>
                <pattern id="tile" width="20" height="24" patternUnits="userSpaceOnUse" patternTransform="translate(3 5)">
                  <rect width="20" height="24" fill="#e02020"/>
                  <rect y="7" width="20" height="17" fill="#209030"/>
                  <rect x="11" y="7" width="9" height="17" fill="#2030e0"/>
                </pattern>
              </defs>
              <rect x="-17" y="-13" width="140" height="94" fill="url(#tile)"/>
            </svg>
            """.utf8)
        let vector = try SVGArtwork.parse(bytes)
        let coordinates = [[5, 20], [5, 29], [15, 29], [25, 44], [25, 53], [35, 53],
                           [65, 68], [65, 77], [75, 77]]
        let expected = try await referencePixels(bytes, coordinates: coordinates)
        XCTAssertEqual(Set(expected.map { pixel in pixel.prefix(3).enumerated().max { $0.element < $1.element }!.offset }),
                       Set([0, 1, 2]), "The reference must exercise all three asymmetric regions")
        func verify(_ bitmap: SRGBBitmap, name: String,
                    destination: CGRect, allowClipping: Bool = false) throws {
            var checked = 0
            for (point, expected) in zip(coordinates, expected) {
                let x = Int(destination.minX + (CGFloat(point[0]) + 0.5) * destination.width / 140)
                let y = Int(destination.minY + (CGFloat(point[1]) + 0.5) * destination.height / 94)
                if allowClipping && (!(1..<(bitmap.pixelsWide - 1)).contains(x) ||
                                     !(1..<(bitmap.pixelsHigh - 1)).contains(y)) { continue }
                checked += 1
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                let actual = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                for (channel, value) in zip(actual, expected) {
                    XCTAssertEqual(channel, Double(value) / 255, accuracy: 0.12, "\(name) pattern at \(point)")
                }
            }
            XCTAssertGreaterThanOrEqual(checked, allowClipping ? 3 : coordinates.count)
        }
        for (width, height) in [(140, 94), (280, 188), (280, 240), (400, 188)] {
            let png = try await SVGArtwork.png(vector, options: .init(width: width, height: height))
            let bitmap = try sRGBBitmap(png)
            let scale = min(CGFloat(width) / 140, CGFloat(height) / 94)
            let size = CGSize(width: 140 * scale, height: 94 * scale)
            try verify(bitmap, name: "export \(width)x\(height)",
                       destination: CGRect(x: (CGFloat(width) - size.width) / 2,
                                           y: (CGFloat(height) - size.height) / 2,
                                           width: size.width, height: size.height))
        }
        let raster = try SVGArtwork.render(bytes)
        let bitmap = try sRGBBitmap(raster.image)
        try verify(bitmap, name: "Markdown raster",
                   destination: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = SVGPreviewScrollView()
        window.contentView = scroll
        window.orderBack(nil)
        scroll.install(vector.image, request: "asymmetric-pattern")
        for (zoom, pan): (CGFloat, CGPoint?) in [(0.5, nil), (1, nil), (2, nil),
                                                    (4, CGPoint(x: 0, y: 0)),
                                                    (4, CGPoint(x: 30, y: 20))] {
            if pan != nil { window.setContentSize(CGSize(width: 220, height: 160)) }
            scroll.layoutSubtreeIfNeeded()
            scroll.setZoom(zoom, at: CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY))
            if let pan {
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(
                    CGRect(origin: pan, size: scroll.contentView.bounds.size)).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            scroll.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let canvas = try XCTUnwrap(scroll.documentView)
            let drawing = try XCTUnwrap(canvas.subviews.first)
            let destination = drawing.convert(drawing.bounds, to: scroll)
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "pattern-\(zoom)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let sx = CGFloat(bitmap.pixelsWide) / scroll.bounds.width
            let sy = CGFloat(bitmap.pixelsHigh) / scroll.bounds.height
            try verify(sRGBBitmap(png), name: "native \(zoom)",
                       destination: CGRect(x: destination.minX * sx,
                                           y: (scroll.isFlipped ? destination.minY : scroll.bounds.maxY - destination.maxY) * sy,
                                           width: destination.width * sx, height: destination.height * sy),
                       allowClipping: pan != nil)
        }
    }

    func testSmallPrintSizedSVGUsesTheAvailableViewportAndSupportsDeepVectorZoom() throws {
        let stripes = (0..<40).map { column in
            "<rect x=\"\(10 + Double(column) * 0.5)\" width=\"0.25\" height=\"40\" fill=\"black\"/>"
        }.joined()
        // Real PDF-extracted research SVGs use pt units and nonzero viewBoxes.
        let svg = try SVGArtwork.parse(Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="60pt" height="30pt" viewBox="100 200 80 40">
              <g transform="translate(100 200)">
                <rect width="80" height="40" fill="white"/>\(stripes)
              </g>
            </svg>
            """.utf8)).image
        let window = NSWindow(contentRect: CGRect(x: -2000, y: -2000, width: 480, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = SVGPreviewScrollView()
        window.contentView = scroll
        window.orderBack(nil)
        scroll.install(svg, request: "small-print-sized-svg")
        for size in [CGSize(width: 480, height: 360), CGSize(width: 200, height: 360),
                     CGSize(width: 720, height: 260)] {
            window.setContentSize(size)
            scroll.layoutSubtreeIfNeeded()
            scroll.fit()
            scroll.layoutSubtreeIfNeeded()
            let canvas = try XCTUnwrap(scroll.documentView)
            let actual = canvas.convert(canvas.bounds, to: scroll)
            let expected = min(scroll.contentView.frame.width / svg.size.width,
                               scroll.contentView.frame.height / svg.size.height)
            XCTAssertEqual(scroll.magnification, expected, accuracy: 0.01)
            XCTAssertEqual(actual.width, svg.size.width * expected, accuracy: 1)
            XCTAssertEqual(actual.height, svg.size.height * expected, accuracy: 1)
        }
        scroll.actualSize()
        XCTAssertEqual(scroll.pixelScale, 1, accuracy: 0.001)
        for scale: CGFloat in [4, 16, 64] {
            scroll.setZoom(scale, at: CGPoint(x: 20, y: 20))
            scroll.layoutSubtreeIfNeeded()
            XCTAssertEqual(scroll.pixelScale, scale, accuracy: 0.001)
            let canvas = try XCTUnwrap(scroll.documentView)
            let clip = scroll.contentView
            clip.scroll(to: clip.constrainBoundsRect(CGRect(x: 20 - clip.bounds.width / 2,
                y: 20 - clip.bounds.height / 2, width: clip.bounds.width, height: clip.bounds.height)).origin)
            scroll.reflectScrolledClipView(clip)
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            let sx = CGFloat(bitmap.pixelsWide) / scroll.bounds.width
            let sy = CGFloat(bitmap.pixelsHigh) / scroll.bounds.height
            let start = canvas.convert(CGPoint(x: 19, y: 20), to: scroll)
            let end = canvas.convert(CGPoint(x: 21, y: 20), to: scroll)
            let y = Int(start.y * sy)
            let left = Int(start.x * sx), right = Int(end.x * sx)
            guard left >= 0, right < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh else {
                XCTFail("Deep zoom must preserve the selected vector region")
                continue
            }
            let colors = try (left..<right).map { x in
                try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)).redComponent
            }
            let transitions = zip(colors, colors.dropFirst()).filter { abs($0 - $1) > 0.5 }.count
            XCTAssertGreaterThanOrEqual(transitions, 5, "The actual fine vector bands must resolve at \(scale)x")
        }
    }

    func testTinySVGFitAndManualZoomSurviveViewportResizeAndRemount() throws {
        let svg = try SVGArtwork.parse(Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="1" height="2">
              <rect width="1" height="2" fill="red"/>
            </svg>
            """.utf8)).image
        let window = NSWindow(contentRect: CGRect(x: -2000, y: -2000, width: 400, height: 320),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let first = SVGPreviewScrollView()
        window.contentView = first
        window.orderBack(nil)
        first.install(svg, request: "tiny")
        first.layoutSubtreeIfNeeded()
        let fitted = first.pixelScale
        XCTAssertGreaterThan(fitted, 64)
        first.zoomIn()
        XCTAssertEqual(first.pixelScale, fitted * 1.25, accuracy: 0.001)
        let saved = try XCTUnwrap(first.position)
        window.setContentSize(CGSize(width: 100, height: 120))
        first.layoutSubtreeIfNeeded()
        XCTAssertEqual(first.pixelScale, saved.pixelScale, accuracy: 0.001)
        let second = SVGPreviewScrollView()
        window.contentView = second
        second.install(svg, request: "tiny", position: saved)
        second.layoutSubtreeIfNeeded()
        XCTAssertEqual(second.pixelScale, saved.pixelScale, accuracy: 0.001)
        second.fit()
        let expected = min(second.contentView.frame.width / svg.size.width,
                           second.contentView.frame.height / svg.size.height)
        XCTAssertEqual(second.magnification, expected, accuracy: 0.01)
    }

    func testShaleResearchSVGsFitTheViewportAtReadableSize() async throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_SHALE_SVG_ROOT"] else {
            throw XCTSkip("Set BAILEY_SHALE_SVG_ROOT to the research data directory")
        }
        let directory = URL(fileURLWithPath: root)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey])).compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "svg" }
            .sorted { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty)
        let window = NSWindow(contentRect: CGRect(x: -2000, y: -2000, width: 620, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = SVGPreviewScrollView()
        window.contentView = scroll
        window.orderBack(nil)
        var passed = 0
        var failures = [String]()
        for file in files {
            do {
                let bytes = try Data(contentsOf: file)
                let artwork = try await SVGPreviewSnapshot.parse(String(decoding: bytes, as: UTF8.self))
                scroll.install(artwork.image, request: file.path)
                scroll.layoutSubtreeIfNeeded()
                scroll.fit()
                scroll.layoutSubtreeIfNeeded()
                let canvas = try XCTUnwrap(scroll.documentView)
                let actual = canvas.convert(canvas.bounds, to: scroll)
                let expected = min(scroll.contentView.frame.width / artwork.image.size.width,
                                   scroll.contentView.frame.height / artwork.image.size.height)
                guard abs(scroll.magnification - expected) < 0.01,
                      abs(actual.width - artwork.image.size.width * expected) < 1,
                      abs(actual.height - artwork.image.size.height * expected) < 1 else {
                    failures.append("\(file.lastPathComponent): fit=\(scroll.magnification), expected=\(expected), size=\(artwork.image.size)")
                    continue
                }
                // Verify rendered visible pixels rather than merely accepting XML.
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
                scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
                let image = try XCTUnwrap(bitmap.cgImage)
                let samples = try sRGBBitmap(image)
                var ink = 0
                let sx = CGFloat(samples.pixelsWide) / scroll.bounds.width
                let sy = CGFloat(samples.pixelsHigh) / scroll.bounds.height
                let xRange = max(0, Int(actual.minX * sx))..<min(samples.pixelsWide, Int(actual.maxX * sx))
                let top = scroll.isFlipped ? actual.minY : scroll.bounds.maxY - actual.maxY
                let yRange = max(0, Int(top * sy))..<min(samples.pixelsHigh, Int((top + actual.height) * sy))
                for y in stride(from: yRange.lowerBound, to: yRange.upperBound, by: 9) {
                    for x in stride(from: xRange.lowerBound, to: xRange.upperBound, by: 9) {
                        if let color = samples.colorAt(x: x, y: y),
                           color.alphaComponent > 0.5,
                           min(color.redComponent, color.greenComponent, color.blueComponent) < 0.65 { ink += 1 }
                    }
                }
                guard ink > 4 else { failures.append("\(file.lastPathComponent): no visible graph ink"); continue }
                XCTAssertEqual(try Data(contentsOf: file), bytes)
                passed += 1
            } catch {
                failures.append("\(file.path.replacingOccurrences(of: root + "/", with: "")): \(error)")
            }
            scroll.clear()
        }
        print("SHALE_SVG_FIT passed=\(passed)/\(files.count) failures=\(failures.count)")
        for failure in failures.prefix(20) { print("SHALE_SVG_FAILURE \(failure)") }
        XCTAssertEqual(failures.count, 0, "Every real research SVG must be readable and fill the viewport")
    }

    func testFitPresentsEveryCornerOfLargeNativeSVGAcrossPaneSizes() async throws {
        let bytes = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="1400" height="620">
              <rect width="700" height="310" fill="#ff0000"/>
              <rect x="700" width="700" height="310" fill="#00ff00"/>
              <rect y="310" width="700" height="310" fill="#0000ff"/>
              <rect x="700" y="310" width="700" height="310" fill="#ffff00"/>
            </svg>
            """.utf8)
        let svg = try SVGArtwork.parse(bytes).image
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = SVGPreviewScrollView()
        window.contentView = scroll
        window.orderBack(nil)
        scroll.install(svg, request: "all-corners")
        for size in [CGSize(width: 440, height: 400), CGSize(width: 770, height: 360),
                     CGSize(width: 260, height: 450), CGSize(width: 620, height: 480)] {
            window.setContentSize(size)
            scroll.layoutSubtreeIfNeeded()
            scroll.fit()
            scroll.layoutSubtreeIfNeeded()
            let canvas = try XCTUnwrap(scroll.documentView)
            let drawing = try XCTUnwrap(canvas.subviews.first)
            let destination = drawing.convert(drawing.bounds, to: scroll)
            XCTAssertEqual(destination.width / destination.height, 1400.0 / 620, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(destination.minX, scroll.bounds.minX - 1)
            XCTAssertGreaterThanOrEqual(destination.minY, scroll.bounds.minY - 1)
            XCTAssertLessThanOrEqual(destination.maxX, scroll.bounds.maxX + 1)
            XCTAssertLessThanOrEqual(destination.maxY, scroll.bounds.maxY + 1)
            func check() throws -> [Bool] {
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
                scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "fit-\(Int(size.width))-\(Int(size.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
                let samples: [(CGFloat, CGFloat, (NSColor) -> Bool)] = [
                    (0.25, 0.25, { $0.redComponent - max($0.greenComponent, $0.blueComponent) > 0.5 }),
                    (0.75, 0.25, { $0.greenComponent - max($0.redComponent, $0.blueComponent) > 0.35 }),
                    (0.25, 0.75, { $0.blueComponent - max($0.redComponent, $0.greenComponent) > 0.5 }),
                    (0.75, 0.75, { min($0.redComponent, $0.greenComponent) - $0.blueComponent > 0.5 }),
                ]
                let pixels = try sRGBBitmap(png)
                let matches = try samples.map { fx, fy, matches in
                    let x = destination.minX + fx * destination.width
                    let y = scroll.isFlipped ? destination.minY + fy * destination.height
                                             : scroll.bounds.maxY - destination.maxY + fy * destination.height
                    let color = try XCTUnwrap(pixels.colorAt(
                        x: Int(x * CGFloat(pixels.pixelsWide) / scroll.bounds.width),
                        y: Int(y * CGFloat(pixels.pixelsHigh) / scroll.bounds.height)
                    ))
                    return color.alphaComponent > 0.95 && matches(color)
                }
                return matches
            }
            XCTAssertEqual(try check(), [true, true, true, true],
                           "All four actual fit quadrants must be visible at \(size)")
        }
    }

    func testResearchPlotWholeImageMatchesReference() async throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_SVG_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Requires the real research SVG")
        }
        let file = URL(fileURLWithPath: root).appending(path: "graphics/复杂科研图.svg")
        let bytes = try Data(contentsOf: file)
        let vector = try SVGArtwork.parse(bytes)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let reference = WKWebView(frame: CGRect(x: 0, y: 0, width: 1400, height: 620), configuration: configuration)
        reference.loadHTMLString("""
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:">
            <title>Research SVG reference</title>
            """, baseURL: nil)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            reference.title == "Research SVG reference" && !reference.isLoading
        }, object: nil)
        await fulfillment(of: [loaded], timeout: 8)
        let result = try await reference.callAsyncJavaScript("""
            const image = new Image();
            image.src = 'data:image/svg+xml;base64,' + encoded;
            await image.decode();
            const canvas = document.createElement('canvas');
            canvas.width = image.naturalWidth;
            canvas.height = image.naturalHeight;
            canvas.getContext('2d').drawImage(image, 0, 0);
            return canvas.toDataURL('image/png').split(',')[1];
            """, arguments: ["encoded": bytes.base64EncodedString()], in: nil, contentWorld: .defaultClient)
        let expected = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(result as? String)))
        let actual = try await SVGArtwork.png(vector, options: .init(width: 1400, height: 620))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 620),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = SVGPreviewScrollView()
        window.contentView = scroll
        window.orderBack(nil)
        scroll.install(vector.image, request: "research-visual")
        scroll.layoutSubtreeIfNeeded()
        scroll.setZoom(1, at: CGPoint(x: 700, y: 310))
        let canvas = try XCTUnwrap(scroll.documentView)
        window.displayIfNeeded()
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let displayed = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        for (name, data) in [("reference", expected), ("export", actual), ("canvas", displayed)] {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let ref = try sRGBBitmap(expected)
        for (name, data) in [("export", actual), ("viewport", displayed)] {
            let candidate = try sRGBBitmap(data)
            // Explicitly check the thin grid, whose low contrast could pass
            // the whole-image tolerance even when displaced by half a cell.
            for row in [360, 400] {
                func intensity(_ bitmap: SRGBBitmap, x: Int, y: Int) throws -> CGFloat {
                    try XCTUnwrap(bitmap.colorAt(x: x * bitmap.pixelsWide / 1400,
                                                y: y * bitmap.pixelsHigh / 620)?.usingColorSpace(.sRGB)).redComponent
                }
                let referenceContrast = try intensity(ref, x: 450, y: row - 4) - intensity(ref, x: 450, y: row)
                XCTAssertGreaterThan(referenceContrast, 0.05)
                let line = try (row-1...row+1).map { try intensity(candidate, x: 450, y: $0) }.min()!
                let nearby = try intensity(candidate, x: 450, y: row - 4)
                XCTAssertGreaterThan(nearby - line, referenceContrast * 0.65, "\(name) grid at \(row)")
            }
            // Compare the complete scientific plot, not a few hand-picked points.
            // Exclude subpixel antialiasing through a two-pixel local neighbourhood,
            // and check meaningful disagreement in every region of the figure.
            var mismatches = 0
            var total = 0
            for y in stride(from: 2, to: 618, by: 2) {
                for x in stride(from: 2, to: 1398, by: 2) {
                    let target = try XCTUnwrap(ref.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    total += 1
                    var agrees = false
                    for dy in -1...1 {
                        for dx in -1...1 {
                            guard let pixel = candidate.colorAt(
                                x: (x + dx) * candidate.pixelsWide / ref.pixelsWide,
                                y: (y + dy) * candidate.pixelsHigh / ref.pixelsHigh
                            )?.usingColorSpace(.sRGB) else { continue }
                            if max(abs(pixel.redComponent - target.redComponent),
                                   abs(pixel.greenComponent - target.greenComponent),
                                   abs(pixel.blueComponent - target.blueComponent),
                                   abs(pixel.alphaComponent - target.alphaComponent)) <= 0.15 {
                                agrees = true
                                break
                            }
                        }
                        if agrees { break }
                    }
                    if !agrees { mismatches += 1 }
                }
            }
            let ratio = Double(mismatches) / Double(total)
            print("RESEARCH_SVG_VISUAL \(name) mismatch=\(mismatches)/\(total) ratio=\(ratio)")
            XCTAssertLessThan(ratio, 0.01, "\(name): whole-image geometry and color must agree with the independent reference")
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    private func referencePixels(_ bytes: Data, coordinates: [[Int]]) async throws -> [[Int]] {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let reference = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: configuration)
        reference.loadHTMLString("""
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:">
            <title>SVG pixel reference</title>
            """, baseURL: nil)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            reference.title == "SVG pixel reference" && !reference.isLoading
        }, object: nil)
        await fulfillment(of: [loaded], timeout: 8)
        let rawPixels = try await reference.callAsyncJavaScript("""
            const image = new Image();
            image.src = 'data:image/svg+xml;base64,' + encoded;
            await image.decode();
            const canvas = document.createElement('canvas');
            canvas.width = image.naturalWidth;
            canvas.height = image.naturalHeight;
            const context = canvas.getContext('2d');
            context.drawImage(image, 0, 0);
            return coordinates.map(([x, y]) => Array.from(context.getImageData(x, y, 1, 1).data));
            """, arguments: ["encoded": bytes.base64EncodedString(), "coordinates": coordinates],
            in: nil, contentWorld: .defaultClient)
        return try XCTUnwrap(rawPixels as? [[Int]])
    }

    func testDropShadowFontAndExtremeClippedPathMatchIndependentReference() async throws {
        // A long, valid path with coordinates far beyond the viewport must not
        // expand the backing surface. Compare the actual visible result.
        let segments = (0..<4_000).map { index in
            "L\(10 + index % 70) \(index.isMultiple(of: 2) ? 70 : 74)"
        }.joined(separator: " ")
        let bytes = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="128" height="100" viewBox="-16 -8 128 100">
              <defs>
                <filter id="shadow" filterUnits="userSpaceOnUse" x="0" y="0" width="90" height="50">
                  <feDropShadow dx="20" dy="4" stdDeviation="1" flood-color="#0040ff" flood-opacity="0.75"/>
                </filter>
                <clipPath id="plot"><rect x="0" y="50" width="90" height="30"/></clipPath>
              </defs>
              <rect x="10" y="10" width="20" height="20" fill="#ff0000" filter="url(#shadow)"/>
              <g clip-path="url(#plot)" fill="none">
                <path d="M-1000000 55 L1000000 55" stroke="#00aa22" stroke-width="5"/>
                <path d="M10 70 \(segments)" stroke="#d02070" stroke-width="1"/>
              </g>
              <text x="60" y="37" font-family="Helvetica" font-size="22" fill="#000000">HI</text>
            </svg>
            """.utf8)
        let vector = try SVGArtwork.parse(bytes)
        XCTAssertTrue(vector.omitted.isEmpty)
        let raster = try SVGArtwork.render(bytes)
        let bitmap = try sRGBBitmap(raster.image)
        XCTAssertEqual(bitmap.pixelsWide, 256)
        XCTAssertEqual(bitmap.pixelsHigh, 200)
        let geometry: [[Int]] = [[15, 18], [40, 22], [56, 22], [45, 55], [-4, 55], [95, 55]]
        let text = (60..<85).flatMap { x in (15..<40).map { y in [x, y] } }
        let coordinates = geometry + text
        let reference = try await referencePixels(bytes, coordinates: coordinates.map { [$0[0] + 16, $0[1] + 8] })
        XCTAssertEqual(reference.count, coordinates.count)
        func pixel(_ point: [Int]) throws -> NSColor {
            try XCTUnwrap(bitmap.colorAt(x: (point[0] + 16) * 2 + 1, y: (point[1] + 8) * 2 + 1)?.usingColorSpace(.sRGB))
        }
        XCTAssertGreaterThan(reference[1][3], 150, "The reference must actually contain the projected shadow")
        XCTAssertGreaterThan(reference[3][1], 130, "The extreme line must actually enter the clip")
        for (point, expected) in zip(geometry, reference) {
            let actual = try pixel(point)
            XCTAssertEqual(actual.alphaComponent, Double(expected[3]) / 255, accuracy: 0.12, "alpha at \(point)")
            if expected[3] > 100 {
                for (value, channel) in zip([actual.redComponent, actual.greenComponent, actual.blueComponent], expected) {
                    XCTAssertEqual(value, Double(channel) / 255, accuracy: 0.12, "color at \(point)")
                }
            }
        }
        let glyphs = try text.filter { try pixel($0).alphaComponent > 0.65 }
        let referenceGlyphs = zip(text, reference.dropFirst(geometry.count)).filter { $0.1[3] > 165 }.map { $0.0 }
        XCTAssertGreaterThan(referenceGlyphs.count, 30)
        XCTAssertGreaterThan(glyphs.count, 30)
        XCTAssertEqual(Double(glyphs.count), Double(referenceGlyphs.count), accuracy: Double(referenceGlyphs.count) * 0.35)
        XCTAssertEqual(try XCTUnwrap(glyphs.map { $0[0] }.min()), try XCTUnwrap(referenceGlyphs.map { $0[0] }.min()), accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(glyphs.map { $0[1] }.min()), try XCTUnwrap(referenceGlyphs.map { $0[1] }.min()), accuracy: 3)
    }

    func testMaskAndRotationKeepTheExpectedHalfTransparent() throws {
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" width="32" height="16">
              <defs>
                <mask id="half" maskUnits="userSpaceOnUse" x="0" y="0" width="32" height="16">
                  <rect width="16" height="16" fill="white"/>
                </mask>
              </defs>
              <g transform="rotate(180 16 8)">
                <rect width="32" height="16" fill="blue" mask="url(#half)"/>
              </g>
            </svg>
            """
        let data = Data(source.utf8)
        XCTAssertTrue(try SVGArtwork.parse(data).omitted.isEmpty)
        let bitmap = NSBitmapImageRep(cgImage: try SVGArtwork.render(data).image)
        let left = try XCTUnwrap(bitmap.colorAt(x: 10, y: 16)?.usingColorSpace(.deviceRGB))
        let right = try XCTUnwrap(bitmap.colorAt(x: 54, y: 16)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(left.alphaComponent, 0.05)
        XCTAssertGreaterThan(right.alphaComponent, 0.95)
        XCTAssertGreaterThan(right.blueComponent, 0.9)
    }
}
