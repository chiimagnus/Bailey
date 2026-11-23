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

    static func gifFrame(_ source: CGImageSource, at index: Int, maximumDimension: Int) throws -> GIFFrame {
        try Task.checkCancellation()
        guard let image = decode(source, index: index, maximumDimension: maximumDimension)?.poster else {
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
