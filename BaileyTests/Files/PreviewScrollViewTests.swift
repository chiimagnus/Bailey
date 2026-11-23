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

    private func makeLongGIF() throws -> Data {
        let canvas = try XCTUnwrap(CGContext(
            data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        canvas.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        let red = try XCTUnwrap(canvas.makeImage())
        canvas.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        let green = try XCTUnwrap(canvas.makeImage())
        let bytes = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, 34, nil))
        for index in 0..<34 {
            let last = index == 33
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
