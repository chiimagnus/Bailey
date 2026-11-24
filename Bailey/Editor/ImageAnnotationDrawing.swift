import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageAnnotationDrawing {
    private static let filterContext = CIContext(options: [.cacheIntermediates: false])

    enum Format: String, CaseIterable, Sendable {
        case png, jpeg
        var type: UTType { self == .png ? .png : .jpeg }
        var fileExtension: String { self == .png ? "png" : "jpg" }
    }

    enum ColorSpace: String, CaseIterable, Sendable {
        case sRGB, displayP3
        var value: CGColorSpace? { CGColorSpace(name: self == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3) }
    }

    enum Background: String, CaseIterable, Sendable {
        case transparent, white, black
    }

    struct Options: Sendable {
        let width: Int
        let height: Int
        var format: Format = .png
        var colorSpace: ColorSpace = .sRGB
        var background: Background = .transparent
        var dpi: Double = 72
        var quality: Double = 0.9

        var isValid: Bool {
            width > 0 && height > 0 && width <= 32_768 && height <= 32_768 &&
                width <= RasterPreview.pixelLimit / height &&
                dpi.isFinite && (1...1_200).contains(dpi) &&
                quality.isFinite && (0...1).contains(quality) &&
                (format != .jpeg || background != .transparent)
        }
    }

    static func drawVector(_ layer: ImageAnnotationLayer, in context: CGContext) {
        guard !layer.kind.filtersPixels else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(layer.color.cgColor)
        context.setFillColor(layer.color.cgColor)
        context.setLineWidth(layer.strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch layer.kind {
        case .arrow:
            let start = layer.start, end = layer.end
            let dx = end.x - start.x, dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > 0 else { return }
            let head = min(length * 0.5, max(8, layer.strokeWidth * 4))
            let base = CGPoint(x: end.x - dx / length * head, y: end.y - dy / length * head)
            let half = head * 0.42
            let left = CGPoint(x: base.x - dy / length * half, y: base.y + dx / length * half)
            let right = CGPoint(x: base.x + dy / length * half, y: base.y - dx / length * half)
            context.move(to: start)
            context.addLine(to: base)
            context.strokePath()
            context.move(to: end)
            context.addLine(to: left)
            context.addLine(to: right)
            context.closePath()
            context.fillPath()
        case .rectangle:
            context.stroke(layer.bounds)
        case .ellipse:
            context.strokeEllipse(in: layer.bounds)
        case .text:
            let rect = layer.bounds
            context.clip(to: rect)
            context.textMatrix = .identity
            let frame = CTFramesetterCreateFrame(
                CTFramesetterCreateWithAttributedString(attributed(layer.text, size: max(8, layer.strokeWidth * 5),
                                                                   color: layer.color.cgColor)),
                CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil
            )
            CTFrameDraw(frame, context)
        case .number:
            let rect = layer.bounds
            context.fillEllipse(in: rect)
            let foreground = layer.color == .white ? ImageAnnotationColor.black.cgColor : ImageAnnotationColor.white.cgColor
            let line = CTLineCreateWithAttributedString(attributed(layer.text, size: rect.height * 0.52, color: foreground))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: rect.midX - width / 2, y: rect.midY - (ascent - descent) / 2)
            CTLineDraw(line, context)
        case .blur, .pixelate: break
        }
    }

    static func textSize(_ text: String, strokeWidth: CGFloat, within maximum: CGSize) -> CGSize {
        let frame = CTFramesetterCreateWithAttributedString(
            attributed(text, size: max(8, strokeWidth * 5), color: ImageAnnotationColor.black.cgColor)
        )
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(frame, CFRange(location: 0, length: 0), nil,
            CGSize(width: maximum.width, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: min(maximum.width, max(1, ceil(fitted.width) + 2)),
                      height: max(1, ceil(fitted.height) + 2))
    }

    private static func attributed(_ text: String, size: CGFloat, color: CGColor) -> CFAttributedString {
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// Temporary filter outlines are not exported. Until actual composited
    /// pixels arrive, obscure the affected region rather than show raw pixels
    /// as though a redaction had already been rendered.
    static func drawPending(_ state: ImageAnnotationState, in context: CGContext) {
        for layer in state.layers {
            if layer.kind.filtersPixels {
                context.saveGState()
                context.setFillColor(CGColor(gray: 0.35, alpha: 1))
                context.fill(layer.bounds)
                context.restoreGState()
            } else {
                drawVector(layer, in: context)
            }
        }
    }

    static func drawGuides(_ state: ImageAnnotationState, selection: Set<UUID>, editing: Bool,
                           bounds: CGRect, magnification: CGFloat, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if let crop = state.crop {
            context.setFillColor(CGColor(gray: 0, alpha: 0.42))
            context.addRects([bounds, crop])
            context.fillPath(using: .evenOdd)
        }
        guard editing else { return }
        let width = 1 / max(0.05, magnification)
        context.setStrokeColor(ImageAnnotationColor.blue.cgColor)
        context.setLineWidth(width)
        context.setLineDash(phase: 0, lengths: [4 * width, 3 * width])
        for layer in state.layers where selection.contains(layer.id) {
            context.stroke(layer.hitBounds.insetBy(dx: -width * 2, dy: -width * 2))
        }
        if let crop = state.crop { context.stroke(crop) }
    }

    /// Both the onscreen filtered patch and the flat export use this renderer.
    /// The input patch uses the original image coordinate system, including EXIF.
    @concurrent static func preview(_ state: ImageAnnotationState, poster: RasterDetail.Patch,
                                    detail: RasterDetail.Patch?, region: CGRect,
                                    scale requestedScale: CGFloat) async throws -> RasterDetail.Patch {
        try Task.checkCancellation()
        let region = region.intersection(poster.rect)
        guard !region.isEmpty, requestedScale.isFinite, requestedScale > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let scale = min(requestedScale, 32_768 / region.width, 32_768 / region.height,
                        sqrt(CGFloat(RasterPreview.pixelLimit) / (region.width * region.height)))
        let width = max(1, Int(floor(region.width * scale)))
        let height = max(1, Int(floor(region.height * scale)))
        let sourceSpace = poster.image.colorSpace
        let space = if let sourceSpace, sourceSpace.model == .rgb, sourceSpace.supportsOutput {
            sourceSpace
        } else {
            CGColorSpace(name: CGColorSpace.sRGB)!
        }
        let image = try render(state, poster: poster, detail: detail, region: region,
                               width: width, height: height, space: space,
                               background: .transparent, aspectFit: false)
        return .init(image: image, rect: region)
    }

    @concurrent static func export(_ state: ImageAnnotationState, source: RasterDetail, options: Options) async throws -> Data {
        try Task.checkCancellation()
        guard options.isValid, let space = options.colorSpace.value else { throw WorkspaceError.tooLarge }
        let bounds = source.bounds
        _ = try state.validated(in: bounds.size)
        let region = state.crop ?? bounds
        let patch = try await source.render(region)
        try Task.checkCancellation()
        let image = try render(state, poster: patch, detail: nil, region: region,
                               width: options.width, height: options.height, space: space,
                               background: options.background, aspectFit: true)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, options.format.type.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyDPIWidth: options.dpi,
            kCGImagePropertyDPIHeight: options.dpi,
        ]
        if options.format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try Task.checkCancellation()
        return data as Data
    }

    private static func render(_ state: ImageAnnotationState, poster: RasterDetail.Patch,
                               detail: RasterDetail.Patch?, region: CGRect, width: Int, height: Int,
                               space: CGColorSpace, background: Background, aspectFit: Bool) throws -> CGImage {
        guard width > 0, height > 0, width <= RasterPreview.pixelLimit / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw WorkspaceError.tooLarge }
        let pixels = CGRect(x: 0, y: 0, width: width, height: height)
        if background != .transparent {
            let value: CGFloat = background == .white ? 1 : 0
            context.setFillColor(CGColor(srgbRed: value, green: value, blue: value, alpha: 1))
            context.fill(pixels)
        }
        let sx = CGFloat(width) / region.width, sy = CGFloat(height) / region.height
        let xScale = aspectFit ? min(sx, sy) : sx
        let yScale = aspectFit ? min(sx, sy) : sy
        let transform = CGAffineTransform(a: xScale, b: 0, c: 0, d: yScale,
            tx: (pixels.width - region.width * xScale) / 2 - region.minX * xScale,
            ty: (pixels.height - region.height * yScale) / 2 - region.minY * yScale)
        context.concatenate(transform)
        context.clip(to: region)
        context.interpolationQuality = .high
        if let detail {
            context.saveGState()
            context.addRects([poster.rect, detail.rect])
            context.clip(using: .evenOdd)
            context.draw(poster.image, in: poster.rect)
            context.restoreGState()
            context.draw(detail.image, in: detail.rect)
        } else {
            context.draw(poster.image, in: poster.rect)
        }
        let filters = state.hasFilters ? filterContext : nil
        for layer in state.layers {
            try Task.checkCancellation()
            if !layer.kind.filtersPixels {
                drawVector(layer, in: context)
                continue
            }
            // Filter the pixels composed so far, not an independent copy of
            // the original. Layer order and alpha are shared with export.
            let rect = layer.bounds.intersection(region).applying(transform).integral.intersection(pixels)
            guard !rect.isEmpty else { continue }
            guard let filters, let snapshot = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
            try autoreleasepool {
                let image = CIImage(cgImage: snapshot).clampedToExtent()
                let parameters: [String: Any]
                let filter: String
                if layer.kind == .blur {
                    filter = "CIGaussianBlur"
                    parameters = [kCIInputRadiusKey: max(1, layer.strokeWidth * 2 * xScale)]
                } else {
                    filter = "CIPixellate"
                    parameters = [kCIInputScaleKey: max(1, layer.strokeWidth * 4 * xScale),
                                  kCIInputCenterKey: CIVector(x: transform.tx, y: transform.ty)]
                }
                let output = image.applyingFilter(filter, parameters: parameters).cropped(to: rect)
                guard let patch = filters.createCGImage(output, from: rect, format: .RGBA8, colorSpace: space) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                context.saveGState()
                context.concatenate(transform.inverted())
                context.clip(to: rect)
                context.setBlendMode(.copy)
                context.draw(patch, in: rect)
                context.restoreGState()
            }
        }
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }
}
