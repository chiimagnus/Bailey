import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct RasterPreview: Sendable {
    static let pixelLimit = 32_000_000
    let poster: CGImage
    let pixelSize: CGSize
    var animationFrameCount: Int = 0

    struct GIFFrame: Hashable, Sendable {
        let image: CGImage
        let seconds: TimeInterval
    }

    static func source(_ bytes: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(bytes as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary)
    }

    static func pixelSize(_ source: CGImageSource, at index: Int) -> CGSize? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
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
        guard let pixelSize = pixelSize(source, at: index) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ]
        guard let poster = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return nil
        }
        return Self(poster: poster, pixelSize: pixelSize,
                    animationFrameCount: index == 0 ? gifFrameCount(source) : 0)
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
