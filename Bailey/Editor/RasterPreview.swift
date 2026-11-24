import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import zlib

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

    private static func orientPixels(_ image: CGImage, exif: CGImagePropertyOrientation) -> CGImage? {
        guard exif != .up else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let transform = CIImage(cgImage: image).orientationTransform(for: exif)
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

    static func original(_ source: CGImageSource, size: CGSize) throws -> RasterDetail {
        guard pixelSize(source, at: 0) == size else { throw CocoaError(.fileReadCorruptFile) }
        let type = CGImageSourceGetType(source) as String?
        if type == UTType.jpeg.identifier || type == UTType.heic.identifier,
           let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
           raw.bitsPerComponent == 8, let colorSpace = raw.colorSpace, colorSpace.model == .rgb,
           colorSpace.supportsOutput {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
            let transform = CIImage(cgImage: raw)
                .orientationTransform(for: CGImagePropertyOrientation(rawValue: orientation) ?? .up)
            let detail = RasterDetail.region(raw, transform, colorSpace)
            if detail.bounds.size == size { return detail }
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
    case region(CGImage, CGAffineTransform, CGColorSpace)

    struct Patch: Sendable {
        let image: CGImage
        let rect: CGRect
    }

    var bounds: CGRect {
        switch self {
        case .whole(let image): CGRect(x: 0, y: 0, width: image.width, height: image.height)
        case .region(let image, let transform, _):
            CGRect(x: 0, y: 0, width: image.width, height: image.height).applying(transform)
        }
    }

    @concurrent func render(_ visible: CGRect) async throws -> Patch {
        try Task.checkCancellation()
        switch self {
        case .whole(let image):
            return Patch(image: image, rect: bounds)
        case .region(let image, let transform, let colorSpace):
            let rect = visible.integral.intersection(bounds)
            guard !rect.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let raw = rect.applying(transform.inverted())
            let decoderRect = CGRect(x: raw.minX, y: CGFloat(image.height) - raw.maxY,
                                     width: raw.width, height: raw.height)
            guard let cropped = image.cropping(to: decoderRect),
                  let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            context.interpolationQuality = .none
            context.translateBy(x: -rect.minX, y: -rect.minY)
            context.concatenate(transform)
            context.draw(cropped, in: raw)
            try Task.checkCancellation()
            guard let pixels = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
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
