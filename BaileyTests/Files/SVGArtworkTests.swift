import AppKit
import Darwin
import WebKit
import XCTest
@testable import Bailey

@MainActor
final class SVGArtworkTests: XCTestCase {
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
        XCTAssertEqual(vector.omitted, ["pattern", "use"])
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

        let samples = [CGPoint(x: 230, y: 135), CGPoint(x: 1000, y: 135)]
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
            """, arguments: ["encoded": bytes.base64EncodedString(),
                              "coordinates": samples.map { [Int($0.x) + 80, Int($0.y) + 40] }],
            in: nil, contentWorld: .defaultClient)
        let expected = try XCTUnwrap(rawPixels as? [[Int]])
        XCTAssertEqual(expected.count, samples.count)
        for (point, target) in zip(samples, expected) {
            let rendered = try pixel(at: point)
            let channels = [rendered.redComponent, rendered.greenComponent, rendered.blueComponent, rendered.alphaComponent]
            XCTAssertEqual(target.count, channels.count)
            for (component, value) in zip(channels, target) {
                XCTAssertEqual(component, Double(value) / 255, accuracy: 0.12,
                               "Gradient must agree with the isolated native browser reference at \(point)")
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
