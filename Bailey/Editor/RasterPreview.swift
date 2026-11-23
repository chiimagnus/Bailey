import Foundation
import ImageIO

nonisolated struct RasterPreview: Sendable {
    let poster: CGImage
    let pixelSize: CGSize

    static func source(_ bytes: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(bytes as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary)
    }

    static func decode(_ source: CGImageSource, index: Int = 0, maximumDimension: Int) -> Self? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0, width <= 32_000_000 / height else { return nil }
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let pixelSize = (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ]
        guard let poster = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return nil
        }
        return Self(poster: poster, pixelSize: pixelSize)
    }
}
