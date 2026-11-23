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

    private func residentMiB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        return Double(info.resident_size) / 1_048_576
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
        guard let canvas = scroll.documentView,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width),
                                            pixelsHigh: Int(canvas.bounds.height), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return isGreen(bitmap)
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
