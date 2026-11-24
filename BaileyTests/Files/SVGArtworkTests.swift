import AppKit
import Darwin
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
        for nodes in [4095, 4096] {
            let data = Data((start + String(repeating: "<rect/>", count: nodes) + end).utf8)
            if nodes == 4095 {
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
        XCTAssertTrue(try SVGArtwork.sanitizedXML(artwork(instances: 123)).omitted.isEmpty)
        XCTAssertThrowsError(try SVGArtwork.sanitizedXML(artwork(instances: 124))) { error in
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
            XCTAssertTrue(try SVGArtwork.sanitizedXML(artwork(references: 123)).omitted.isEmpty, element)
            XCTAssertThrowsError(try SVGArtwork.sanitizedXML(artwork(references: 124)), element) { error in
                guard case WorkspaceError.tooLarge = error else { return XCTFail("Expected expanded SVG limit: \(error)") }
            }
        }
        let gradient = "<linearGradient id=\"shared\">" + String(repeating: "<stop offset=\"0\" stop-color=\"red\"/>", count: 31) + "</linearGradient>"
        func painted(references: Int) -> Data {
            let shapes = String(repeating: "<rect width=\"1\" height=\"1\" fill=\"url(#shared)\"/>", count: references)
            return Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><defs>\(gradient)</defs>\(shapes)</svg>".utf8)
        }
        XCTAssertTrue(try SVGArtwork.sanitizedXML(painted(references: 62)).omitted.isEmpty)
        XCTAssertThrowsError(try SVGArtwork.sanitizedXML(painted(references: 63))) { error in
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

    func testResearchSamplePlacesRealGeometryAndReportsOmittedElements() async throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_SVG_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_SVG_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        let file = URL(fileURLWithPath: root).appending(path: "graphics/复杂科研图.svg")
        let bytes = try Data(contentsOf: file)
        let vector = try SVGArtwork.parse(bytes)
        XCTAssertEqual(vector.image.size, CGSize(width: 1400, height: 620))
        XCTAssertEqual(vector.omitted, ["pattern"])
        let raster = try SVGArtwork.render(bytes)
        XCTAssertEqual(raster.pointSize, vector.image.size)
        let bitmap = NSBitmapImageRep(cgImage: raster.image)
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
        let bitmap = NSBitmapImageRep(cgImage: raster.image)
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
