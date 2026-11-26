import Foundation
import ImageIO
import RasterRegions
import Synchronization
import XCTest

final class RasterRegionDecoderTests: XCTestCase {
    private static let cancellationCalls = Mutex(0)

    func testMalformedRegionsAndMidDecodeCancellationLeaveNoPixelBuffer() throws {
        let fixtures = RasterRegionFixtures.png.map { (name: $0.0, encoded: $0.1, png: true) }
            + RasterRegionFixtures.tiff.map { (name: $0.0, encoded: $0.1, png: false) }
        var seed: UInt32 = 20261124
        func next() -> UInt32 {
            seed = seed &* 1664525 &+ 1013904223
            return seed
        }
        var attempts = 0
        for fixture in fixtures {
            let bytes = try XCTUnwrap(Data(base64Encoded: fixture.encoded, options: .ignoreUnknownCharacters))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil), fixture.name)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], fixture.name)
            let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? UInt32, fixture.name)
            let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? UInt32, fixture.name)
            let read = fixture.png ? br_read_png_region : br_read_tiff_region

            @discardableResult
            func decode(_ input: Data, cancelled: BRCancel? = nil) -> BRStatus {
                var region = BRRegion()
                let status = input.withUnsafeBytes { buffer in
                    read(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count,
                         width, height, 1, 1, width - 2, height - 2, cancelled, &region)
                }
                attempts += 1
                defer { free(region.pixels) }
                if status == BR_OK {
                    XCTAssertNotNil(region.pixels, fixture.name)
                    XCTAssertEqual(region.width, width - 2, fixture.name)
                    XCTAssertEqual(region.height, height - 2, fixture.name)
                    XCTAssertEqual(region.row_bytes, Int(region.width) * Int(region.channels) * Int(region.bits_per_component) / 8, fixture.name)
                } else {
                    XCTAssertNil(region.pixels, fixture.name)
                }
                return status
            }

            let initial = decode(bytes)
            if fixture.name == "jpeg-compressed" {
                XCTAssertEqual(initial, BR_UNSUPPORTED)
            } else {
                XCTAssertEqual(initial, BR_OK, fixture.name)
                Self.cancellationCalls.withLock { $0 = 0 }
                XCTAssertEqual(decode(bytes, cancelled: {
                    RasterRegionDecoderTests.cancellationCalls.withLock {
                        $0 += 1
                        return $0 >= 5
                    }
                }), BR_CANCELLED, fixture.name)
                XCTAssertEqual(Self.cancellationCalls.withLock { $0 }, 5)
                XCTAssertEqual(decode(bytes), BR_OK, fixture.name)
            }
            for step in 0..<128 {
                decode(Data(bytes.prefix(bytes.count * step / 128)))
            }
            for _ in 0..<256 {
                var mutated = bytes
                let offset = Int(next()) % bytes.count
                mutated[offset] ^= 1 << Int(next() % 8)
                decode(mutated)
            }
            XCTAssertEqual(bytes, Data(base64Encoded: fixture.encoded, options: .ignoreUnknownCharacters))
        }
        print("RASTER_DECODER_BOUNDARIES attempts=\(attempts)")
        XCTAssertGreaterThanOrEqual(attempts, 9000)
    }
}
