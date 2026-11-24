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

    func testSustainedRealGIFPlaybackRetiresItsNativeFrames() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BAILEY_IMAGE_LONG_SESSION"] == "1",
              let root = environment["BAILEY_IMAGE_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_IMAGE_LONG_SESSION=1 and BAILEY_IMAGE_ACCEPTANCE_ROOT")
        }
        let source = URL(fileURLWithPath: root).appending(path: "images/动画-34帧.gif")
        let bytes = try Data(contentsOf: source)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Sustained.gif")
        try bytes.write(to: url)
        let project = Project(fallbackName: "Sustained GIF", workspaceConfiguration: .standard)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { project.closeAll(); window.close() }
        project.openLocalFile(url.path)
        let pane = try XCTUnwrap(project.selectedTab)
        guard case .file(let file) = pane.content else { return XCTFail("Expected a file tab") }
        let before = rasterMemory()
        let cpuStart = cpuSeconds()
        let started = ContinuousClock.now
        weak var lastFrame: CGImage?
        let cycle = try await { @MainActor () async throws -> (firstPixels: Duration, frames: Int,
                                                              positions: Int, samples: [Double]) in
            let firstHost = NSHostingView(rootView: FileViewerView(file: file).environment(\.appearsActive, true))
            window.contentView = firstHost
            window.orderFront(nil)
            try await waitFor("Play the fixture in the native file surface") {
                previewScroll(in: firstHost) != nil && file.gifPlayback?.image != nil
            }
            let firstPixels = started.duration(to: .now)
            let firstScroll = try XCTUnwrap(previewScroll(in: firstHost))
            let playback = try XCTUnwrap(file.gifPlayback)
            firstScroll.zoomIn()
            let scale = firstScroll.pixelScale
            var residentSamples: [Double] = []
            @MainActor func observedSprite(_ scroll: PreviewScrollView) -> Int? {
                guard let strip = renderedBitmap(scroll, region: CGRect(x: 0, y: 101, width: 320, height: 1)) else {
                    return nil
                }
                let blue = stride(from: 20, to: 300, by: 2).filter { column in
                    guard let color = strip.colorAt(x: column, y: 0)?.usingColorSpace(.sRGB) else { return false }
                    return color.blueComponent > 0.69 && color.greenComponent < 0.54
                }
                guard let first = blue.first, let last = blue.last, last - first >= 10 else { return nil }
                return (first + last) / 2
            }
            @MainActor func observe(_ scroll: PreviewScrollView,
                                    forSeconds seconds: Int) async throws -> (frames: Int, positions: Int) {
                let start = ContinuousClock.now
                let end = start.advanced(by: .seconds(seconds))
                var nextPixels = start
                var nextMemory = start
                var prior: CGImage?
                var frames = 0
                var positions: Set<Int> = []
                while ContinuousClock.now < end {
                    guard !playback.failed else { throw CocoaError(.fileReadCorruptFile) }
                    if let current = playback.image, current !== prior {
                        frames += 1
                        prior = current
                    }
                    let now = ContinuousClock.now
                    if now >= nextPixels {
                        if let center = observedSprite(scroll) { positions.insert(center) }
                        nextPixels = now.advanced(by: .milliseconds(400))
                    }
                    if now >= nextMemory {
                        residentSamples.append(residentMiB())
                        nextMemory = now.advanced(by: .seconds(5))
                    }
                    try await Task.sleep(for: .milliseconds(35))
                }
                XCTAssertGreaterThan(frames, seconds * 7, "Playback must sustain the real 120 ms frames")
                XCTAssertGreaterThan(positions.count, 6, "Native pixels must show the moving sprite")
                XCTAssertEqual(scroll.pixelScale, scale, accuracy: 0.001)
                return (frames, positions.count)
            }

            let first = try await observe(firstScroll, forSeconds: 90)
            let pauseTitle = String(localized: "Pause Animation", table: "Editor")
            let resumeTitle = String(localized: "Resume Animation", table: "Editor")
            let pause = try XCTUnwrap(firstScroll.menu?.item(withTitle: pauseTitle))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(pause.action), to: pause.target, from: pause))
            let replacement = NSHostingView(rootView: FileViewerView(file: file).environment(\.appearsActive, true))
            do {
                let pausedFrame = try XCTUnwrap(playback.image)
                window.contentView = replacement
                try await waitFor("Remount the same paused frame") {
                    previewScroll(in: replacement)?.menu?.item(withTitle: resumeTitle) != nil
                }
                try await Task.sleep(for: .milliseconds(650))
                XCTAssertTrue(file.gifPlayback === playback)
                XCTAssertTrue(playback.paused)
                XCTAssertTrue(playback.image === pausedFrame)
            }
            let nextScroll = try XCTUnwrap(previewScroll(in: replacement))
            let resume = try XCTUnwrap(nextScroll.menu?.item(withTitle: resumeTitle))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(resume.action), to: resume.target, from: resume))
            let second = try await observe(nextScroll, forSeconds: 30)
            lastFrame = playback.image
            project.close(pane)
            XCTAssertTrue(project.tabs.isEmpty)
            XCTAssertNil(file.gifPlayback)
            XCTAssertNil(playback.image)
            try await waitFor("Closing must dismantle the real canvas") { previewScroll(in: replacement) == nil }
            let retired = try XCTUnwrap(renderedBitmap(nextScroll, region: CGRect(x: 159, y: 95, width: 1, height: 1)))
            XCTAssertEqual(try XCTUnwrap(retired.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)
            XCTAssertNil(nextScroll.menu?.item(withTitle: pauseTitle))
            window.contentView = nil
            return (firstPixels, first.frames + second.frames, first.positions + second.positions, residentSamples)
        }()
        try await waitFor("Closing must release the last decoded pixels") { lastFrame == nil }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
        let after = rasterMemory()
        print("GIF_SUSTAINED elapsed=\(started.duration(to: .now)) cpu_s=\(cpuSeconds() - cpuStart) first_pixels=\(cycle.firstPixels) frames=\(cycle.frames) drawn_positions=\(cycle.positions) rss_before=\(before) rss_after_close=\(after) samples=\(cycle.samples)")
        let warmed = try XCTUnwrap(cycle.samples.prefix(6).max())
        let late = try XCTUnwrap(cycle.samples.suffix(6).max())
        XCTAssertLessThan(late - warmed, 48, "Sustained playback must not retain each published frame")
    }

    func testNativeGIFsAtTheAttainableInlinePixelAndFrameBoundaries() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtures = [
            (width: 999, height: 286, frames: 28, pixels: 7_999_992, animated: true),
            (width: 1_000, height: 1_000, frames: 8, pixels: 8_000_000, animated: true),
            (width: 863, height: 927, frames: 10, pixels: 8_000_010, animated: false),
            (width: 24, height: 24, frames: 32, pixels: 18_432, animated: true),
            (width: 24, height: 24, frames: 33, pixels: 19_008, animated: false),
        ]
        for fixture in fixtures {
            let bytes = try makeLongGIF(width: fixture.width, height: fixture.height, count: fixture.frames)
            let native = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(native), fixture.frames)
            let preview = try MarkdownPicture.decode(bytes)
            XCTAssertEqual(preview.poster.width, fixture.width)
            XCTAssertEqual(preview.poster.height, fixture.height)
            XCTAssertFalse(isGreen(NSBitmapImageRep(cgImage: preview.poster)))
            XCTAssertEqual(preview.animation.count, fixture.animated ? fixture.frames : 0)
            if fixture.animated {
                let pixels = preview.animation.reduce(0) { $0 + $1.image.width * $1.image.height }
                XCTAssertEqual(pixels, fixture.pixels)
                let last = try XCTUnwrap(preview.animation.last)
                XCTAssertTrue(isGreen(NSBitmapImageRep(cgImage: last.image)))
            }

            let url = folder.appending(path: "\(fixture.pixels).gif")
            try bytes.write(to: url)
            let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            file.loadIfNeeded()
            try await waitFor { file.gifFramesRequest() != nil }
            let request = try XCTUnwrap(file.gifFramesRequest())
            let source = try await request()
            XCTAssertEqual(source.count, fixture.frames)
            let last = try await source.read(source.count - 1)
            XCTAssertEqual(last.image.width * last.image.height * source.count, fixture.pixels)
            XCTAssertTrue(isGreen(NSBitmapImageRep(cgImage: last.image)))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            file.retireContent()
        }
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
        let width = 120
        let height = 60
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericCMYK))
        var channels = Data(count: width * height * 4)
        for offset in stride(from: 0, to: channels.count, by: 4) { channels[offset] = 255 }
        let provider = try XCTUnwrap(CGDataProvider(data: channels as CFData))
        let cyan = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric
        ))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            jpeg, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cyan, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(RasterPreview.source(jpeg as Data))
        let reference = try XCTUnwrap(CGImageSourceCreateWithData(jpeg, nil))
        let raw = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reference, 0, nil))
        XCTAssertEqual(raw.colorSpace?.model, .cmyk)
        let size = CGSize(width: width, height: height)
        let detail = try RasterPreview.original(source, size: size)
        guard case .whole = detail else { return XCTFail("The RGB region path must not reinterpret CMYK pixels") }
        let patch = try await detail.render(CGRect(x: 30, y: 20, width: 20, height: 20))
        XCTAssertEqual(patch.rect.size, size)
        let output = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        func pixel(from image: CGImage) throws -> [Double] {
            let reader = try XCTUnwrap(CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: output, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            reader.interpolationQuality = .none
            reader.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            let bytes = try XCTUnwrap(reader.data).assumingMemoryBound(to: UInt8.self)
            let offset = 4 * reader.bytesPerRow + 4 * 4
            return (0..<3).map { Double(bytes[offset + $0]) / 255 }
        }
        let expected = try pixel(from: raw)
        let original = try pixel(from: cyan)
        XCTAssertGreaterThan(original[1] - original[0], 0.4, "Uncompressed CMYK: \(original)")
        XCTAssertGreaterThan(expected[1] - expected[0], 0.4, "Native JPEG: \(expected)")
        XCTAssertGreaterThan(expected[2] - expected[0], 0.4, "Native JPEG: \(expected)")
        for (actual, expected) in zip(try pixel(from: patch.image), expected) {
            XCTAssertEqual(actual, expected, accuracy: 0.02)
        }
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

    func testHundredRealRasterPreviewsRetireDecodedPixels() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BAILEY_IMAGE_LONG_SESSION"] == "1",
              let root = environment["BAILEY_IMAGE_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_IMAGE_LONG_SESSION=1 and BAILEY_IMAGE_ACCEPTANCE_ROOT")
        }
        let images = URL(fileURLWithPath: root).appending(path: "images")
        let fixtures = try ["超清大图-6000x4000.jpg", "极宽图.png", "动画-34帧.gif"].map { name in
            let url = images.appending(path: name)
            return (url: url, bytes: try Data(contentsOf: url))
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = Project(fallbackName: "Repeated raster previews", workspaceConfiguration: .standard)
        defer { project.closeAll() }
        let beforeCPU = cpuSeconds()
        let before = rasterMemory()
        let started = ContinuousClock.now
        var closedRSS: [Double] = []
        var firstPixels: [Duration] = []
        var completedByFormat: [String: Int] = [:]
        for cycle in 1...100 {
            let fixture = fixtures[(cycle - 1) % fixtures.count]
            let format = fixture.url.pathExtension
            let url = folder.appending(path: "Raster \(cycle).\(format)")
            try FileManager.default.copyItem(at: fixture.url, to: url)
            let openTime = ContinuousClock.now
            weak var retiredPoster: CGImage?
            weak var retiredDetail: CGImage?
            weak var retiredSource: CGImage?
            do {
                project.openLocalFile(url.path)
                let pane = try XCTUnwrap(project.selectedTab)
                guard case .file(let file) = pane.content else { return XCTFail("Expected the file tab") }
                file.loadIfNeeded()
                try await waitFor { if case .loading = file.content { return false }; return true }
                guard case .image(let preview) = file.content else { return XCTFail("Cannot preview \(format)") }
                retiredPoster = preview.poster
                if format == "gif" {
                    let request = try XCTUnwrap(file.gifFramesRequest())
                    let frames = try await request()
                    XCTAssertEqual(frames.count, 34)
                    let last = try await frames.read(33)
                    let renderer = NSBitmapImageRep(cgImage: last.image)
                    XCTAssertGreaterThan(try XCTUnwrap(renderer.colorAt(x: 200, y: 90)).alphaComponent, 0.9)
                    retiredDetail = last.image
                } else {
                    let request = try XCTUnwrap(file.originalImageRequest())
                    let detail = try await request()
                    let requestRect = CGRect(x: detail.bounds.midX, y: detail.bounds.midY, width: 256, height: 80)
                    let patch = try await detail.render(requestRect)
                    switch detail {
                    case .region(let original, _, _):
                        XCTAssertEqual(format, "jpg")
                        XCTAssertEqual(patch.rect, requestRect)
                        retiredSource = original
                    case .whole(let original):
                        XCTAssertEqual(format, "png")
                        XCTAssertEqual(patch.rect.size, CGSize(width: 9000, height: 240))
                        retiredSource = original
                    }
                    let renderer = NSBitmapImageRep(cgImage: patch.image)
                    XCTAssertNotNil(renderer.colorAt(x: patch.image.width / 2, y: patch.image.height / 2))
                    retiredDetail = patch.image
                }
                firstPixels.append(openTime.duration(to: .now))
                project.close(pane)
                XCTAssertTrue(project.tabs.isEmpty)
                XCTAssertNil(file.gifPlayback)
                XCTAssertNil(file.originalImageRequest())
            }
            try await waitFor("Decoded images must retire after closing \(url.lastPathComponent)") {
                retiredPoster == nil && retiredDetail == nil && retiredSource == nil
            }
            XCTAssertEqual(try Data(contentsOf: url), fixture.bytes)
            try FileManager.default.removeItem(at: url)
            completedByFormat[format, default: 0] += 1
            if cycle.isMultiple(of: 10) { closedRSS.append(residentMiB()) }
        }
        let durations = firstPixels.sorted()
        let after = rasterMemory()
        print("RASTER_SESSION files=\(completedByFormat) elapsed=\(started.duration(to: .now)) cpu_s=\(cpuSeconds() - beforeCPU) median_first_pixels=\(durations[49]) p95_first_pixels=\(durations[94]) rss_before=\(before) rss_after=\(after) closed_rss=\(closedRSS)")
        let warmed = try XCTUnwrap(closedRSS.prefix(5).max())
        let late = try XCTUnwrap(closedRSS.suffix(5).max())
        XCTAssertLessThan(late - warmed, 64, "Repeated closes must not accumulate per-image buffers")
        XCTAssertEqual(completedByFormat, ["jpg": 34, "png": 33, "gif": 33])
        for fixture in fixtures { XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.bytes) }
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

    private func cpuSeconds() -> Double {
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
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
