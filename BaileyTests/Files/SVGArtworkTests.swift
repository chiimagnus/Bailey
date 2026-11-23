import AppKit
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

    func testNativeCanvasDisplaysSettledBlurOutsideTheSourceShape() async throws {
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
        func reds() throws -> (near: CGFloat, far: CGFloat) {
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            func red(at sourceX: CGFloat) throws -> CGFloat {
                let point = canvas.convert(CGPoint(x: sourceX, y: 24), to: scroll)
                let column = Int(point.x * CGFloat(bitmap.pixelsWide) / scroll.bounds.width)
                let row = Int(point.y * CGFloat(bitmap.pixelsHigh) / scroll.bounds.height)
                let pixel = try XCTUnwrap(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB))
                return (pixel.redComponent - pixel.greenComponent) * pixel.alphaComponent
            }
            return (try red(at: 14.5), try red(at: 3))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var pixels = try reds()
        while pixels.near < 0.04, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            pixels = try reds()
        }
        XCTAssertGreaterThan(pixels.near, 0.04)
        XCTAssertLessThan(pixels.far, 0.02)
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
