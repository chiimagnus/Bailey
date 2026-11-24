import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Bailey

@MainActor
final class PreviewScrollViewTests: XCTestCase {
    func testFileGIFAdvancesPast32FramesAndPausesWithoutRefitting() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Long.gif")
        let bytes = try makeLongGIF()
        try bytes.write(to: url)
        let source = try XCTUnwrap(RasterPreview.source(bytes))
        XCTAssertEqual(RasterPreview.gifFrameCount(source), 34)
        let last = try RasterPreview.gifFrame(source, at: 33, maximumDimension: 24)
        XCTAssertTrue(isGreen(NSBitmapImageRep(cgImage: last.image)))
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 320)
        let window = NSWindow(contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); file.retireContent() }
        let host = NSHostingView(rootView: FileViewerView(file: file).environment(\.appearsActive, true))
        window.contentView = host
        window.orderFront(nil)
        try await waitFor { previewScroll(in: host) != nil }
        let scroll = try XCTUnwrap(previewScroll(in: host))
        let pauseTitle = String(localized: "Pause Animation", table: "Editor")
        let resumeTitle = String(localized: "Resume Animation", table: "Editor")
        let item = try XCTUnwrap(scroll.menu?.item(withTitle: pauseTitle))
        scroll.zoomIn()
        let scale = scroll.pixelScale
        try await waitFor("Start playback") {
            file.gifPlayback?.image != nil || file.gifPlayback?.failed == true
        }
        XCTAssertFalse(file.gifPlayback?.failed == true)
        try await waitFor("Select the final green frame") {
            file.gifPlayback?.image.map { isGreen(NSBitmapImageRep(cgImage: $0)) } == true
        }
        try await waitFor("Draw the final green frame") { isGreen(scroll) }
        XCTAssertEqual(scroll.pixelScale, scale, accuracy: 0.001)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        try await waitFor { scroll.menu?.item(withTitle: resumeTitle) != nil }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(isGreen(scroll))
        let resume = try XCTUnwrap(scroll.menu?.item(withTitle: resumeTitle))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(resume.action), to: resume.target, from: resume))
        try await waitFor("Resume animation") { !isGreen(scroll) }
        XCTAssertEqual(scroll.pixelScale, scale, accuracy: 0.001)

        try await waitFor("Loop back to the last frame") { isGreen(scroll) }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let playback = try XCTUnwrap(file.gifPlayback)
        let remounted = NSHostingView(rootView: FileViewerView(file: file).environment(\.appearsActive, true))
        window.contentView = remounted
        try await waitFor("Remount a paused animation") {
            previewScroll(in: remounted)?.menu?.item(withTitle: resumeTitle) != nil
        }
        let remountedScroll = try XCTUnwrap(previewScroll(in: remounted))
        XCTAssertTrue(file.gifPlayback === playback)
        XCTAssertTrue(isGreen(remountedScroll))
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        file.retireContent()
        try await waitFor("Remove the native image viewer after a true close") { previewScroll(in: remounted) == nil }
        let retired = try XCTUnwrap(renderedBitmap(remountedScroll))
        let center = try XCTUnwrap(retired.colorAt(x: retired.pixelsWide / 2, y: retired.pixelsHigh / 2))
        XCTAssertEqual(center.alphaComponent, 0, accuracy: 0.01, "A cached native view must release its image on dismantle")
        XCTAssertNil(remountedScroll.menu?.item(withTitle: resumeTitle))
    }

    func testLongGIFDecodeStaysBoundedAndClosingReleasesThePoster() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appending(path: "240 frames.gif")
        let frameCount = 240
        let width = 640
        let height = 480
        let bytes = try makeLongGIF(width: width, height: height, count: frameCount)
        try bytes.write(to: fixture)
        let project = Project(fallbackName: "GIF retention", workspaceConfiguration: .standard)
        defer { project.closeAll() }

        let baseline = residentMiB()
        var peak = baseline
        var retained = baseline
        let started = ContinuousClock.now
        for cycle in 0..<3 {
            project.openLocalFile(fixture.path)
            guard case .file(let file)? = project.selectedTab?.content else {
                return XCTFail("Project did not open the GIF as a file tab")
            }
            file.loadIfNeeded()
            try await waitFor { file.gifFramesRequest() != nil }
            let load = try XCTUnwrap(file.gifFramesRequest())
            let playback = try XCTUnwrap(file.gifPlayback)
            let firstFrameStart = ContinuousClock.now
            do {
                let frames = try await load()
                XCTAssertEqual(frames.count, frameCount)
                for index in 0..<frames.count {
                    let frame = try await frames.read(index)
                    if index == 0 {
                        print("GIF_DECODE cycle=\(cycle) first_native_frame=\(firstFrameStart.duration(to: .now))")
                        XCTAssertFalse(isGreen(NSBitmapImageRep(cgImage: frame.image)))
                    } else if index == frames.count - 1 {
                        XCTAssertTrue(isGreen(NSBitmapImageRep(cgImage: frame.image)))
                    }
                    XCTAssertEqual(frame.image.width, width)
                    XCTAssertEqual(frame.image.height, height)
                    peak = max(peak, residentMiB())
                }
            }

            let running = Task { await playback.play(load: load) }
            defer { running.cancel() }
            try await waitFor { playback.image != nil }
            project.closeAll()
            XCTAssertTrue(project.tabs.isEmpty)
            XCTAssertNil(file.gifPlayback)
            XCTAssertNil(playback.image)
            if case .image = file.content { XCTFail("A closed file tab still holds its decoded poster") }
            await running.value
            retained = max(retained, residentMiB())
        }

        print("GIF_DECODE frames=\(frameCount * 3) elapsed=\(started.duration(to: .now)) rss_base_mib=\(baseline) rss_peak_mib=\(peak) rss_after_close_mib=\(retained)")
        let fullFrameSetMiB = Double(frameCount * width * height * 4) / 1_048_576
        XCTAssertLessThan(peak - baseline, fullFrameSetMiB / 2, "RSS must stay well below one full set of decoded frames")
        XCTAssertLessThan(retained - baseline, fullFrameSetMiB / 3, "Closing must not retain the decoded frame set")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [fixture.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: fixture), bytes)
    }

    func testFileImageRemountKeepsItsActualZoomAndPanAtANewWindowSize() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Position.gif")
        let bytes = try makeLongGIF(width: 1200, height: 900, count: 1)
        try bytes.write(to: url)
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        let frame = CGRect(x: 0, y: 0, width: 400, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); file.retireContent() }
        window.orderFront(nil)

        func mount() async throws -> PreviewScrollView {
            let host = NSHostingView(rootView: FileViewerView(file: file))
            window.contentView = host
            try await waitFor { previewScroll(in: host) != nil }
            host.layoutSubtreeIfNeeded()
            return try XCTUnwrap(previewScroll(in: host))
        }

        let first = try await mount()
        first.setZoom(3, at: CGPoint(x: 600, y: 450))
        first.contentView.scroll(to: CGPoint(x: 150, y: 210))
        first.reflectScrolledClipView(first.contentView)
        let visible = first.contentView.bounds
        XCTAssertEqual(first.pixelScale, 3, accuracy: 0.001)
        XCTAssertLessThan(visible.midX, 460)
        XCTAssertLessThan(visible.midY, 410)

        window.contentView = NSView(frame: frame)
        XCTAssertNil(first.window)
        window.setContentSize(NSSize(width: 620, height: 460))
        let remounted = try await mount()
        XCTAssertFalse(remounted === first)
        XCTAssertEqual(remounted.pixelScale, 3, accuracy: 0.001)
        XCTAssertEqual(remounted.contentView.bounds.midX, visible.midX, accuracy: 2)
        XCTAssertEqual(remounted.contentView.bounds.midY, visible.midY, accuracy: 2)

        let renamed = root.appending(path: "Renamed.gif")
        try FileManager.default.moveItem(at: url, to: renamed)
        file.updatePath(renamed.path)
        let renamedView = try await mount()
        XCTAssertEqual(renamedView.pixelScale, 3, accuracy: 0.001)
        XCTAssertEqual(renamedView.contentView.bounds.midX, visible.midX, accuracy: 2)
        XCTAssertEqual(renamedView.contentView.bounds.midY, visible.midY, accuracy: 2)
        XCTAssertEqual(try Data(contentsOf: renamed), bytes)

        renamedView.fit()
        let fitted = try await mount()
        XCTAssertLessThan(fitted.pixelScale, 3)
        XCTAssertEqual(fitted.contentView.bounds.midX, 600, accuracy: 2)
        XCTAssertEqual(fitted.contentView.bounds.midY, 450, accuracy: 2)
        fitted.setZoom(3, at: CGPoint(x: 600, y: 450))

        let revision = file.reloadRevision
        let replacement = try makeLongGIF(width: 300, height: 200, count: 1)
        try replacement.write(to: renamed, options: .atomic)
        file.reloadFromDiskIfClean()
        try await waitFor { file.reloadRevision > revision }
        let reloaded = try await mount()
        XCTAssertEqual(reloaded.pixelScale, 1, accuracy: 0.001)
        XCTAssertEqual(reloaded.documentView?.frame.size, NSSize(width: 300, height: 200))
        XCTAssertEqual(try Data(contentsOf: renamed), replacement)
    }

    func testRasterDetailIsReleasedBelowThumbnailScaleAndIgnoresLateDecode() async throws {
        try await checkRasterDetail(size: CGSize(width: 1024, height: 768),
                                    thumbnailSize: CGSize(width: 512, height: 384))
    }

    func testOnePixelWideThumbnailStillLoadsOriginalHeight() async throws {
        try await checkRasterDetail(size: CGSize(width: 1, height: 768),
                                    thumbnailSize: CGSize(width: 1, height: 384))
    }

    private func checkRasterDetail(size: CGSize, thumbnailSize: CGSize) async throws {
        let thumbnail = try solidRaster(size: thumbnailSize, color: .red)
        var reads = 0
        var cancelledReads = 0
        weak var lastDetail: CGImage?
        var pending: CheckedContinuation<CGImage, any Error>?
        defer { pending?.resume(throwing: CancellationError()) }
        let host = NSHostingView(rootView: ImageInspector(
            image: RasterPreview(poster: thumbnail, pixelSize: size),
            loadOriginal: {
                reads += 1
                if reads == 2 {
                    let lateImage = try await withCheckedThrowingContinuation { pending = $0 }
                    if Task.isCancelled { cancelledReads += 1 }
                    return .whole(lateImage)
                }
                let detail = try self.solidRaster(size: size, color: .green)
                lastDetail = detail
                return .whole(detail)
            }
        ))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 170, height: 140),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        try await waitFor { previewScroll(in: host) != nil }
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(previewScroll(in: host))
        let anchor = CGPoint(x: size.width / 2, y: size.height / 2)
        XCTAssertLessThan(scroll.pixelScale, 0.5)
        XCTAssertEqual(reads, 0, "Fit at \(scroll.pixelScale) does not need the original")
        scroll.actualSize()
        try await waitFor("Draw the original pixels") { lastDetail != nil && isGreen(scroll) }
        XCTAssertEqual(reads, 1)

        scroll.setZoom(0.25, at: anchor)
        try await waitFor("Drop original pixels when the poster can satisfy the viewport") {
            lastDetail == nil && !isGreen(scroll)
        }
        scroll.actualSize()
        try await waitFor("Request fresh detail after zooming back in") { pending != nil }
        scroll.setZoom(0.25, at: anchor)
        pending?.resume(returning: try solidRaster(size: size, color: .green))
        pending = nil
        try await waitFor("Cancel the detail request that is no longer needed") { cancelledReads == 1 }
        XCTAssertFalse(isGreen(scroll), "A late decode must not replace the poster")

        scroll.actualSize()
        try await waitFor("Render the new detail request") { reads == 3 && isGreen(scroll) }
        XCTAssertEqual(scroll.pixelScale, 1, accuracy: 0.001)
    }

    func testRegionalRasterPreservesEXIFMirroringAndDisplayP3AtClippedEdges() async throws {
        let size = CGSize(width: 600, height: 300)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let colors: [(CGRect, [CGFloat])] = [
            (CGRect(origin: .zero, size: size), [0.9, 0.1, 0.15, 1.0]),
            (CGRect(x: 0, y: 100, width: 310, height: 200), [0.1, 0.8, 0.2, 1.0]),
            (CGRect(x: 310, y: 175, width: 290, height: 125), [0.06, 0.09, 0.9, 1.0]),
        ]
        for (rect, components) in colors {
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: components)))
            context.fill(rect)
        }
        let raw = try XCTUnwrap(context.makeImage())
        for format in [UTType.jpeg, .heic] {
            for orientation in 1...8 {
                let bytes = NSMutableData()
                let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
                    bytes, format.identifier as CFString, 1, nil
                ))
                CGImageDestinationAddImage(destination, raw, [
                    kCGImagePropertyOrientation: orientation,
                    kCGImageDestinationLossyCompressionQuality: 1.0,
                ] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                let source = try XCTUnwrap(RasterPreview.source(bytes as Data))
                let reference = try XCTUnwrap(RasterPreview.decode(source, maximumDimension: 600))
                let detail = try RasterPreview.original(source, size: reference.pixelSize)
                guard case .region = detail else {
                    return XCTFail("Expected regional ImageIO for \(format) EXIF \(orientation)")
                }
                let request = CGRect(x: detail.bounds.width - 39, y: -8, width: 57, height: 76)
                let patch = try await detail.render(request)
                XCTAssertEqual(patch.rect, request.intersection(detail.bounds))
                XCTAssertEqual(patch.image.width, 39)
                XCTAssertEqual(patch.image.height, 68)
                let expected = try XCTUnwrap(reference.poster.cropping(to: CGRect(
                    x: patch.rect.minX, y: detail.bounds.height - patch.rect.maxY,
                    width: patch.rect.width, height: patch.rect.height
                )))
                let actualBitmap = NSBitmapImageRep(cgImage: patch.image)
                let referenceBitmap = NSBitmapImageRep(cgImage: expected)
                for sample in [CGPoint(x: 2, y: 2), CGPoint(x: 22, y: 59), CGPoint(x: 37, y: 65)] {
                    let actualPixel = try XCTUnwrap(actualBitmap.colorAt(x: Int(sample.x), y: Int(sample.y))?
                        .usingColorSpace(.displayP3))
                    let expectedPixel = try XCTUnwrap(referenceBitmap.colorAt(x: Int(sample.x), y: Int(sample.y))?
                        .usingColorSpace(.displayP3))
                    let description = "\(format) EXIF \(orientation) at \(sample)"
                    XCTAssertEqual(actualPixel.redComponent, expectedPixel.redComponent, accuracy: 0.025, description)
                    XCTAssertEqual(actualPixel.greenComponent, expectedPixel.greenComponent, accuracy: 0.025, description)
                    XCTAssertEqual(actualPixel.blueComponent, expectedPixel.blueComponent, accuracy: 0.025, description)
                }
            }
        }
    }

    func testNativeViewportReplacesRegionalPixelsWhenPannedWithoutReadingAgain() async throws {
        let size = CGSize(width: 1800, height: 240)
        let thumbnail = try solidRaster(size: CGSize(width: 900, height: 120), color: .red)
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            jpeg, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try solidRaster(size: size, color: .green), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(RasterPreview.source(jpeg as Data))
        let detail = try RasterPreview.original(source, size: size)
        var reads = 0
        let host = NSHostingView(rootView: ImageInspector(
            image: RasterPreview(poster: thumbnail, pixelSize: size),
            loadOriginal: { reads += 1; return detail }
        ))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 170, height: 140),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        try await waitFor { previewScroll(in: host) != nil }
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(previewScroll(in: host))
        func green(at column: Int) -> Bool {
            renderedBitmap(scroll, region: CGRect(x: column, y: 120, width: 1, height: 1)).map(isGreen) == true
        }
        func pan(to column: CGFloat) {
            let frame = scroll.contentView.bounds
            let target = CGRect(x: column - frame.width / 2, y: frame.minY,
                                width: frame.width, height: frame.height)
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(target).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        scroll.actualSize()
        try await waitFor { green(at: 900) }
        XCTAssertFalse(green(at: 20))
        XCTAssertFalse(green(at: 1700))
        pan(to: 20)
        try await waitFor { green(at: 20) && !green(at: 900) }
        for column in [900.0, 20, 900, 20, 1700] { pan(to: column) }
        try await waitFor { green(at: 1700) && !green(at: 20) && !green(at: 900) }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(scroll.pixelScale, 1, accuracy: 0.001)
        scroll.fit()
        try await waitFor { !green(at: 1700) }
    }

    func testCMYKJPEGUsesTheBoundedWholeDecodeWithoutLosingColor() async throws {
        let size = CGSize(width: 120, height: 60)
        let colorSpace = CGColorSpaceCreateDeviceCMYK()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 0])))
        context.fill(CGRect(origin: .zero, size: size))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            jpeg, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(RasterPreview.source(jpeg as Data))
        let raw = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(raw.colorSpace?.model, .cmyk)
        let detail = try RasterPreview.original(source, size: size)
        guard case .whole = detail else { return XCTFail("The RGB region path must not reinterpret CMYK pixels") }
        let patch = try await detail.render(CGRect(x: 30, y: 20, width: 20, height: 20))
        XCTAssertEqual(patch.rect.size, size)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: patch.image).colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.greenComponent - color.redComponent, 0.4)
        XCTAssertGreaterThan(color.blueComponent - color.redComponent, 0.4)
    }

    func testRealLargeJPEGRegionalPixelsDoNotKeepAFullRaster() async throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_IMAGE_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_IMAGE_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        let url = URL(fileURLWithPath: root).appending(path: "images/超清大图-6000x4000.jpg")
        let bytes = try Data(contentsOf: url)
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        defer { file.retireContent() }
        file.loadIfNeeded()
        try await waitFor { if case .loading = file.content { return false }; return true }
        let request = try XCTUnwrap(file.originalImageRequest())
        let baseline = rasterMemory()
        let detail = try await request()
        XCTAssertEqual(detail.bounds.size, CGSize(width: 6000, height: 4000))
        var last: RasterDetail.Patch?
        for rect in [CGRect(x: 384, y: 64, width: 256, height: 256),
                     CGRect(x: 2899, y: 1903, width: 256, height: 256),
                     CGRect(x: 5744, y: 3744, width: 256, height: 256)] {
            let patch = try await detail.render(rect)
            XCTAssertEqual(patch.rect, rect)
            XCTAssertEqual(patch.image.width, 256)
            XCTAssertEqual(patch.image.height, 256)
            let bitmap = NSBitmapImageRep(cgImage: patch.image)
            let pixel = try XCTUnwrap(bitmap.colorAt(x: 127, y: 191)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(pixel.redComponent + pixel.greenComponent + pixel.blueComponent, 0.1)
            last = patch
        }
        withExtendedLifetime(last) {
            let after = rasterMemory()
            print("Regional JPEG resident/peak MiB: \(baseline) → \(after)")
            XCTAssertLessThan(after.resident - baseline.resident, 48)
            XCTAssertLessThanOrEqual(after.peak, max(baseline.peak, baseline.resident + 48))
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    private func solidRaster(size: CGSize, color: NSColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        return try XCTUnwrap(context.makeImage())
    }

    private func residentMiB() -> Double {
        rasterMemory().resident
    }

    private func rasterMemory() -> (resident: Double, peak: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        return (Double(info.resident_size) / 1_048_576, Double(info.resident_size_max) / 1_048_576)
    }

    private func makeLongGIF(width: Int = 24, height: Int = 24, count: Int = 34) throws -> Data {
        let canvas = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        canvas.fill(rect)
        let red = try XCTUnwrap(canvas.makeImage())
        canvas.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        canvas.fill(rect)
        let green = try XCTUnwrap(canvas.makeImage())
        let bytes = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, count, nil))
        for index in 0..<count {
            let last = index == count - 1
            CGImageDestinationAddImage(encoder, last ? green : red, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: last ? 0.4 : 0.04],
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        return bytes as Data
    }

    private func previewScroll(in view: NSView) -> PreviewScrollView? {
        (view as? PreviewScrollView) ?? view.subviews.lazy.compactMap { self.previewScroll(in: $0) }.first
    }

    private func isGreen(_ scroll: PreviewScrollView) -> Bool {
        renderedBitmap(scroll).map { isGreen($0) } ?? false
    }

    private func renderedBitmap(_ scroll: PreviewScrollView, region: CGRect? = nil) -> NSBitmapImageRep? {
        guard let canvas = scroll.documentView else { return nil }
        let rect = region ?? canvas.bounds
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width),
                                            pixelsHigh: Int(rect.height), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
        canvas.draw(rect)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func isGreen(_ bitmap: NSBitmapImageRep) -> Bool {
        guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
            .usingColorSpace(.sRGB) else { return false }
        return color.greenComponent > 0.7 && color.redComponent < 0.25
    }

    private func waitFor(_ message: String = "Wait for image state",
                         file: StaticString = #filePath, line: UInt = #line, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !ready() {
            guard ContinuousClock.now < deadline else {
                XCTFail(message, file: file, line: line)
                throw WorkspaceError.timedOut
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    func testFitContainsExtremeAspectRatiosBelowManualZoomMinimum() {
        let viewport = CGRect(x: 0, y: 0, width: 480, height: 360)
        let window = NSWindow(contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
        for size in [CGSize(width: 40_000, height: 400), CGSize(width: 400, height: 40_000)] {
            let scroll = PreviewScrollView(frame: viewport)
            scroll.documentView = NSView(frame: CGRect(origin: .zero, size: size))
            window.contentView = scroll
            scroll.layoutSubtreeIfNeeded()
            scroll.fit()
            let fitted = scroll.pixelScale
            XCTAssertLessThan(fitted, 0.1, "Fit must allow the entire image even below the manual zoom floor")
            let visible = scroll.documentVisibleRect
            XCTAssertGreaterThanOrEqual(visible.width + 1, size.width)
            XCTAssertGreaterThanOrEqual(visible.height + 1, size.height)
            scroll.zoomOut()
            XCTAssertEqual(scroll.pixelScale, fitted, accuracy: 0.001, "Zoom out must not enlarge a fitted image")
            scroll.zoomIn()
            XCTAssertEqual(scroll.pixelScale, 0.1, accuracy: 0.001)
            scroll.fit()
            XCTAssertEqual(scroll.pixelScale, fitted, accuracy: 0.001)
        }
        withExtendedLifetime(window) {}
    }

    func testNativeZoomKeepsItsAnchorAndUsesBackingPixels() {
        let viewport = CGRect(x: 0, y: 0, width: 480, height: 360)
        let window = NSWindow(contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = PreviewScrollView(frame: viewport)
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 4097, height: 2800))
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        scroll.fit()
        XCTAssertLessThan(scroll.pixelScale, 1)

        scroll.actualSize()
        XCTAssertEqual(scroll.pixelScale, 1, accuracy: 0.001)
        XCTAssertEqual(scroll.magnification, 1 / window.backingScaleFactor, accuracy: 0.001)
        let point = CGPoint(x: 147, y: 132)
        for pixelScale in [1.3, 3.1, 4.0, 2.6, 1.0] {
            let anchor = scroll.contentView.convert(point, from: scroll)
            scroll.setZoom(pixelScale, at: anchor)
            let positioned = scroll.contentView.convert(point, from: scroll)
            XCTAssertEqual(positioned.x, anchor.x, accuracy: 3)
            XCTAssertEqual(positioned.y, anchor.y, accuracy: 3)
            XCTAssertEqual(scroll.pixelScale, pixelScale, accuracy: 0.001)
        }
        scroll.setZoom(100, at: CGPoint(x: 2049, y: 1400))
        XCTAssertEqual(scroll.pixelScale, 4, accuracy: 0.001)
        scroll.setZoom(0.001, at: CGPoint(x: 2049, y: 1400))
        XCTAssertEqual(scroll.pixelScale, 0.1, accuracy: 0.001)
        withExtendedLifetime(window) {}
    }
}
