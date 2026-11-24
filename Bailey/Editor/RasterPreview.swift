import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import zlib
import RasterRegions

nonisolated struct RasterPreview: Sendable {
    static let pixelLimit = 32_000_000
    let poster: CGImage
    let pixelSize: CGSize
    var animationFrameCount: Int = 0

    struct GIFFrame: Hashable, Sendable {
        let image: CGImage
        let seconds: TimeInterval
    }

    private static func rasterType(_ source: CGImageSource) -> String? {
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image),
              !type.conforms(to: .svg), !type.conforms(to: .pdf) else { return nil }
        return identifier
    }

    static func recognizesHeader(_ bytes: Data) -> Bool {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, bytes as CFData, false)
        return rasterType(source) != nil
    }

    static func source(_ bytes: Data) throws -> CGImageSource? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary), let type = rasterType(source) else { return nil }
        if type == UTType.jpeg.identifier, !hasPrimaryJPEGEnd(bytes) {
            throw CocoaError(.fileReadCorruptFile)
        }
        if type == UTType.png.identifier, try !hasCompletePNGChunks(bytes) {
            throw CocoaError(.fileReadCorruptFile)
        }
        return source
    }

    // ImageIO accepts incomplete PNGs and can silently display damaged pixels.
    // Check the actual chunk boundaries and CRCs before handing off to ImageIO or WebKit.
    private static func hasCompletePNGChunks(_ data: Data) throws -> Bool {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count >= 8,
                  bytes.loadUnaligned(as: UInt64.self).bigEndian == 0x89504e470d0a1a0a else { return false }
            var offset = 8
            var hasImageData = false
            while bytes.count - offset >= 12 {
                try Task.checkCancellation()
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian)
                guard length <= Int(Int32.max), length <= bytes.count - offset - 12 else { return false }
                let type = bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).bigEndian
                let checksum = bytes.loadUnaligned(fromByteOffset: offset + 8 + length, as: UInt32.self).bigEndian
                guard crc32(0, base.advanced(by: offset + 4).assumingMemoryBound(to: UInt8.self),
                            UInt32(length + 4)) == UInt(checksum) else { return false }
                if type == 0x49444154 { hasImageData = true } // IDAT
                if type == 0x49454e44 { return length == 0 && hasImageData } // IEND
                offset += length + 12
            }
            return false
        }
    }

    private static func hasPrimaryJPEGEnd(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
                return false
            }
            var offset = 2
            var hasScan = false
            while offset < bytes.count {
                guard let prefix = memchr(base.advanced(by: offset), 0xff, bytes.count - offset) else { return false }
                offset = base.distance(to: UnsafeRawPointer(prefix)) + 1
                while offset < bytes.count, bytes[offset] == 0xff { offset += 1 }
                guard offset < bytes.count else { return false }
                let marker = bytes[offset]
                offset += 1
                switch marker {
                case 0xd9: return hasScan
                case 0xd8: return false
                case 0x00, 0x01, 0xd0...0xd7: continue
                default:
                    guard bytes.count - offset >= 2 else { return false }
                    let length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
                    guard length >= 2, length <= bytes.count - offset else { return false }
                    if marker == 0xda { hasScan = true }
                    offset += length
                }
            }
            return false
        }
    }

    static func pixelSize(_ source: CGImageSource, at index: Int) -> CGSize? {
        pixelSize(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
    }

    private static func pixelSize(_ properties: [CFString: Any]?) -> CGSize? {
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0, width <= pixelLimit / height else { return nil }
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    static func gifFrameCount(_ source: CGImageSource) -> Int {
        guard CGImageSourceGetType(source) as String? == UTType.gif.identifier else { return 0 }
        return CGImageSourceGetCount(source)
    }

    static func hasEmptyGIFFrame(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            func colorTableSize(_ packed: UInt8) -> Int {
                packed & 0x80 == 0 ? 0 : 3 << (Int(packed & 7) + 1)
            }

            guard bytes.count >= 13 else { return false }
            var offset = 13 + colorTableSize(bytes[10])
            while offset < bytes.count {
                switch bytes[offset] {
                case 0x21:
                    offset += 2
                case 0x2c:
                    guard offset + 9 < bytes.count else { return false }
                    offset += 11 + colorTableSize(bytes[offset + 9])
                    if offset < bytes.count, bytes[offset] == 0 { return true }
                default:
                    return false
                }
                while offset < bytes.count {
                    let size = Int(bytes[offset])
                    offset += size + 1
                    if size == 0 { break }
                }
            }
            return false
        }
    }

    static func gifFrame(_ source: CGImageSource, at index: Int, maximumDimension: Int) throws -> GIFFrame {
        try Task.checkCancellation()
        guard let image = decode(source, index: index, maximumDimension: maximumDimension)?.poster,
              CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
        return GIFFrame(image: image, seconds: delay.isFinite ? max(delay, 0.04) : 0.1)
    }

    static func decode(_ source: CGImageSource, index: Int = 0, maximumDimension: Int) -> Self? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        guard let pixelSize = pixelSize(properties) else { return nil }
        let orientation = CGImagePropertyOrientation(rawValue: properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1) ?? .up
        let frameCount = gifFrameCount(source)
        let poster: CGImage
        if frameCount == 0, max(pixelSize.width, pixelSize.height) <= CGFloat(maximumDimension) {
            // At native size, keep the decoded source (including indexed color)
            // rather than ask ImageIO to manufacture a color-converted thumbnail.
            guard let raw = CGImageSourceCreateImageAtIndex(source, index, [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary), let oriented = orientPixels(raw, exif: orientation) else { return nil }
            poster = oriented
        } else {
            let dpiWidth = properties?[kCGImagePropertyDPIWidth] as? Double ?? 72
            let dpiHeight = properties?[kCGImagePropertyDPIHeight] as? Double ?? 72
            // ImageIO's thumbnail transform also applies the print aspect ratio.
            // Use its native EXIF transform only when that cannot distort pixels.
            let needsPixelOrientation = dpiWidth != dpiHeight
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: !needsPixelOrientation,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            ]
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
            if needsPixelOrientation {
                guard let oriented = orientPixels(decoded, exif: orientation) else { return nil }
                poster = oriented
            } else {
                poster = decoded
            }
        }
        return Self(poster: poster, pixelSize: pixelSize,
                    animationFrameCount: index == 0 ? frameCount : 0)
    }

    private static func orientationTransform(for orientation: CGImagePropertyOrientation, size: CGSize) -> CGAffineTransform {
        // Constructing CIImage from a lazy CGImage can decode every pixel just
        // to obtain a transform. EXIF geometry depends only on the extent.
        CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size)).orientationTransform(for: orientation)
    }

    static func orientPixels(_ image: CGImage, exif: CGImagePropertyOrientation, materialize: Bool = false) -> CGImage? {
        guard exif != .up || materialize else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let transform = orientationTransform(for: exif, size: rect.size)
        let bounds = rect.applying(transform)
        guard let originalSpace = image.colorSpace else { return nil }
        let space = originalSpace.model == .indexed ? originalSpace.baseColorSpace ?? originalSpace : originalSpace
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
        let alpha: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : space.model == .rgb ? .noneSkipLast : .none
        let bitmapInfo = CGBitmapInfo(rawValue: alpha.rawValue).union(image.bitmapInfo.intersection(.floatComponents))
        guard let context = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height),
                                      bitsPerComponent: max(8, image.bitsPerComponent), bytesPerRow: 0,
                                      space: space, bitmapInfo: bitmapInfo.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.concatenate(transform)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    static func original(_ bytes: Data, source: CGImageSource, size: CGSize) throws -> RasterDetail {
        guard pixelSize(source, at: 0) == size else { throw CocoaError(.fileReadCorruptFile) }
        let type = CGImageSourceGetType(source) as String?
        if [UTType.png.identifier, UTType.tiff.identifier, UTType.jpeg.identifier, UTType.heic.identifier].contains(type),
           let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
           let colorSpace = raw.colorSpace {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = CGImagePropertyOrientation(rawValue: properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1) ?? .up
            let rawSize = CGSize(width: raw.width, height: raw.height)
            let transform = orientationTransform(for: orientation, size: rawSize)
            let pixels: RasterDetail.RegionSource?
            if type == UTType.png.identifier || type == UTType.tiff.identifier {
                let codec: RasterDetail.RegionSource.Codec = type == UTType.png.identifier ? .png : .tiff
                let invertsGray = codec == .tiff && colorSpace.model == .monochrome
                    && raw.decode.map { $0[0] == 1 && $0[1] == 0 } == true
                let supported = codec == .png || bytes.withUnsafeBytes { buffer in
                    br_tiff_region_supported(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count,
                                             UInt32(raw.width), UInt32(raw.height), invertsGray) == BR_OK
                }
                pixels = supported ? .encoded(.init(codec: codec, bytes: bytes, size: rawSize,
                    colorSpace: colorSpace, intent: raw.renderingIntent, invertsGray: invertsGray)) : nil
            } else if raw.bitsPerComponent == 8, colorSpace.model == .rgb, colorSpace.supportsOutput {
                pixels = .native(raw)
            } else {
                pixels = nil
            }
            if let pixels {
                let detail = RasterDetail.region(pixels, transform, orientation)
                if detail.bounds.size == size { return detail }
            }
        }
        guard let original = decode(source, maximumDimension: Int(max(size.width, size.height)))?.poster,
              original.width == Int(size.width), original.height == Int(size.height) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return .whole(original)
    }
}

nonisolated enum RasterDetail: Sendable {
    case whole(CGImage)
    case region(RegionSource, CGAffineTransform, CGImagePropertyOrientation)

    enum RegionSource: Sendable {
        enum Codec: Sendable { case png, tiff }

        struct Encoded: Sendable {
            let codec: Codec
            let bytes: Data
            let size: CGSize
            let colorSpace: CGColorSpace
            let intent: CGColorRenderingIntent
            let invertsGray: Bool
        }

        case native(CGImage)
        case encoded(Encoded)

        var size: CGSize {
            switch self {
            case .native(let image): CGSize(width: image.width, height: image.height)
            case .encoded(let source): source.size
            }
        }

        func crop(_ rect: CGRect) throws -> CGImage {
            switch self {
            case .native(let image):
                guard let cropped = image.cropping(to: rect) else { throw CocoaError(.fileReadCorruptFile) }
                return cropped
            case .encoded(let source):
                var region = BRRegion()
                let status = source.bytes.withUnsafeBytes { buffer in
                    let read = source.codec == .png ? br_read_png_region : br_read_tiff_region
                    return read(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count,
                        UInt32(source.size.width), UInt32(source.size.height), UInt32(rect.minX), UInt32(rect.minY),
                        UInt32(rect.width), UInt32(rect.height), { Task.isCancelled }, &region)
                }
                if status == BR_CANCELLED { throw CancellationError() }
                if status == BR_NO_MEMORY { throw WorkspaceError.tooLarge }
                guard status == BR_OK, let pointer = region.pixels else { throw CocoaError(.fileReadCorruptFile) }
                let pixels = Data(bytesNoCopy: pointer, count: region.row_bytes * Int(region.height), deallocator: .free)
                let model: CGColorSpaceModel
                switch region.model {
                case BR_GRAY: model = .monochrome
                case BR_RGB: model = .rgb
                case BR_CMYK: model = .cmyk
                case BR_INDEXED: model = .indexed
                default: throw CocoaError(.fileReadCorruptFile)
                }
                let originalSpace = source.colorSpace
                let space = originalSpace.model == .indexed && model != .indexed
                    ? originalSpace.baseColorSpace ?? originalSpace : originalSpace
                let alpha: CGImageAlphaInfo
                switch region.alpha {
                case BR_STRAIGHT_ALPHA: alpha = .last
                case BR_ASSOCIATED_ALPHA: alpha = .premultipliedLast
                default: alpha = .none
                }
                let bitmap = CGBitmapInfo(rawValue: alpha.rawValue)
                    .union(region.bits_per_component == 16 ? .byteOrder16Little : [])
                guard space.model == model, let provider = CGDataProvider(data: pixels as CFData) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                // Keep the native grayscale decode range, not inverted sample
                // values: ColorSync can apply the range after its color transform.
                let decode: [CGFloat] = source.invertsGray ? [1, 0] : []
                guard let image = decode.withUnsafeBufferPointer({ range in
                    CGImage(width: Int(region.width), height: Int(region.height),
                        bitsPerComponent: Int(region.bits_per_component),
                        bitsPerPixel: Int(region.channels * region.bits_per_component),
                        bytesPerRow: region.row_bytes, space: space, bitmapInfo: bitmap,
                        provider: provider, decode: range.isEmpty ? nil : range.baseAddress,
                        shouldInterpolate: false, intent: source.intent)
                }) else { throw CocoaError(.fileReadCorruptFile) }
                return image
            }
        }

        var needsMaterialization: Bool {
            if case .native = self { return true }
            return false
        }
    }

    struct Patch: Sendable {
        let image: CGImage
        let rect: CGRect
    }

    var bounds: CGRect {
        switch self {
        case .whole(let image): CGRect(x: 0, y: 0, width: image.width, height: image.height)
        case .region(let source, let transform, _):
            CGRect(origin: .zero, size: source.size).applying(transform)
        }
    }

    @concurrent func render(_ visible: CGRect) async throws -> Patch {
        try Task.checkCancellation()
        switch self {
        case .whole(let image):
            return Patch(image: image, rect: bounds)
        case .region(let source, let transform, let orientation):
            let rect = visible.integral.intersection(bounds)
            guard !rect.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let raw = rect.applying(transform.inverted())
            let decoderRect = CGRect(x: raw.minX, y: source.size.height - raw.maxY,
                                     width: raw.width, height: raw.height)
            let cropped = try source.crop(decoderRect)
            guard let pixels = RasterPreview.orientPixels(cropped, exif: orientation,
                                                           materialize: source.needsMaterialization) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try Task.checkCancellation()
            return Patch(image: pixels, rect: rect)
        }
    }
}

actor GIFFrameSource {
    private let source: CGImageSource
    private let maximumDimension: Int

    init(source: sending CGImageSource, maximumDimension: Int) {
        self.source = source
        self.maximumDimension = maximumDimension
    }

    func frame(at index: Int) throws -> RasterPreview.GIFFrame {
        try RasterPreview.gifFrame(source, at: index, maximumDimension: maximumDimension)
    }
}
