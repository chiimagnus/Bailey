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
        case .pen:
            if layer.start == layer.end, !layer.via.contains(where: { $0 != layer.start }) {
                let radius = layer.strokeWidth / 2
                context.fillEllipse(in: CGRect(x: layer.start.x - radius, y: layer.start.y - radius,
                                               width: layer.strokeWidth, height: layer.strokeWidth))
            } else {
                context.move(to: layer.start)
                for point in layer.via { context.addLine(to: point) }
                context.addLine(to: layer.end)
                context.strokePath()
            }
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
                                    scale requestedScale: CGFloat, original: RasterDetail? = nil) async throws -> RasterDetail.Patch {
        try Task.checkCancellation()
        let region = region.intersection(poster.rect)
        guard !region.isEmpty, requestedScale.isFinite, requestedScale > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var scale = min(requestedScale, 32_768 / region.width, 32_768 / region.height,
                        sqrt(CGFloat(RasterPreview.pixelLimit) / (region.width * region.height)))
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        var pixels = region.applying(transform).integral
        if pixels.width > 32_768 || pixels.height > 32_768
            || pixels.width * pixels.height > CGFloat(RasterPreview.pixelLimit) {
            // Alignment can add less than two pixels to each dimension.
            // Solve (w*s+2)*(h*s+2) <= the pixel budget only when needed.
            let w = region.width, h = region.height
            let limit = CGFloat(RasterPreview.pixelLimit)
            scale = min(scale, 32_766 / w, 32_766 / h,
                        (limit - 4) / (w + h + sqrt((w - h) * (w - h) + limit * w * h)))
            transform = CGAffineTransform(scaleX: scale, y: scale)
            pixels = region.applying(transform).integral
        }
        let sourceSpace = poster.image.colorSpace
        let space = if let sourceSpace, sourceSpace.model == .rgb, sourceSpace.supportsOutput {
            sourceSpace
        } else {
            CGColorSpace(name: CGColorSpace.sRGB)!
        }
        let layout = try RenderLayout(state, bounds: poster.rect, pixels: pixels,
                                      content: pixels.intersection(poster.rect.applying(transform)),
                                      transform: transform)
        let exactDetail: RasterDetail.Patch?
        if let original, detail?.rect.contains(layout.sourceRegion) != true {
            exactDetail = try await original.render(layout.sourceRegion)
        } else {
            exactDetail = detail
        }
        let image = try render(state, poster: poster, detail: exactDetail, layout: layout,
                               space: space, background: .transparent)
        return .init(image: image, rect: pixels.applying(transform.inverted()))
    }

    @concurrent static func export(_ state: ImageAnnotationState, source: RasterDetail, options: Options) async throws -> Data {
        try Task.checkCancellation()
        guard options.isValid, let space = options.colorSpace.value else { throw WorkspaceError.tooLarge }
        let bounds = source.bounds
        _ = try state.validated(in: bounds.size)
        let region = state.crop ?? bounds
        let layout = try RenderLayout(state, bounds: bounds, region: region,
                                      width: options.width, height: options.height)
        let patch = try await source.render(layout.sourceRegion)
        try Task.checkCancellation()
        let image = try render(state, poster: patch, detail: nil, layout: layout,
                               space: space, background: options.background)
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

    /// Keep the output pixel grid anchored to the original image. A crop
    /// changes the output rectangle, not the phase of pixelation or blur.
    private struct RenderLayout {
        let pixels: CGRect
        let content: CGRect
        let working: CGRect
        let transform: CGAffineTransform
        let imageBounds: CGRect
        let sourceRegion: CGRect
        let filterRegions: [FilterRegion?]

        init(_ state: ImageAnnotationState, bounds: CGRect, region: CGRect,
             width: Int, height: Int) throws {
            guard width > 0, height > 0, width <= RasterPreview.pixelLimit / height else {
                throw WorkspaceError.tooLarge
            }
            let sx = CGFloat(width) / region.width, sy = CGFloat(height) / region.height
            let xScale = min(sx, sy)
            let yScale = xScale
            let tx = (CGFloat(width) - region.width * xScale) / 2 - region.minX * xScale
            let ty = (CGFloat(height) - region.height * yScale) / 2 - region.minY * yScale
            let ox = floor(tx), oy = floor(ty)
            let transform = CGAffineTransform(a: xScale, b: 0, c: 0, d: yScale,
                                              tx: tx - ox, ty: ty - oy)
            let pixels = CGRect(x: -ox, y: -oy, width: CGFloat(width), height: CGFloat(height))
            let content = region.applying(transform).intersection(pixels)
            try self.init(state, bounds: bounds, pixels: pixels, content: content, transform: transform)
        }

        init(_ state: ImageAnnotationState, bounds: CGRect, pixels: CGRect, content: CGRect,
             transform: CGAffineTransform) throws {
            let sourceBounds = bounds.applying(transform)
            let sourcePixels = sourceBounds.integral
            var required = content.integral.intersection(pixels)
            var regions = [FilterRegion?](repeating: nil, count: state.layers.count)

            // Work backwards through the ordered filters. Each predecessor
            // must produce every pixel a successor can sample, including
            // pixels outside the visible or exported crop.
            if state.hasFilters {
                let domain = CIImage(color: .black).cropped(to: sourcePixels)
                let input = domain.clampedToExtent()
                for index in state.layers.indices.reversed() {
                    try Task.checkCancellation()
                    let layer = state.layers[index]
                    guard layer.kind.filtersPixels else { continue }
                    let affected = layer.bounds.applying(transform).integral
                        .intersection(required).intersection(sourcePixels)
                    guard !affected.isEmpty else { continue }
                    let evaluation = layer.kind == .pixelate
                        ? pixelationCells(covering: affected, layer: layer, transform: transform)
                            .intersection(sourcePixels)
                        : affected
                    regions[index] = FilterRegion(output: affected, evaluation: evaluation)
                    let filter = ImageAnnotationDrawing.filtered(input, layer: layer, transform: transform)
                    var roi = filter.regionOfInterest(for: domain, in: evaluation)
                    if layer.kind == .pixelate {
                        // Core Image may omit the sampled cell center from
                        // a partial-cell ROI. Evaluate whole cells; include
                        // their interpolation neighbors in the source demand.
                        roi = roi.union(evaluation.insetBy(dx: -1, dy: -1))
                    }
                    roi = roi.integral.intersection(sourcePixels)
                    if !roi.isEmpty { required = required.union(roi) }
                }
            }
            guard !required.isEmpty, required.width <= 32_768, required.height <= 32_768,
                  required.width * required.height <= CGFloat(RasterPreview.pixelLimit) else {
                throw WorkspaceError.tooLarge
            }
            self.pixels = pixels
            self.content = content
            self.working = required
            self.transform = transform
            self.imageBounds = bounds
            let input = CIImage(color: .black).cropped(to: bounds)
            let resampled = ImageAnnotationDrawing.resample(input, transform: transform)
            let sourceRegion = resampled.regionOfInterest(for: input, in: required)
                .integral.intersection(bounds)
            guard !sourceRegion.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            self.sourceRegion = sourceRegion
            self.filterRegions = regions
        }
    }

    private struct FilterRegion {
        let output: CGRect
        let evaluation: CGRect
    }

    private static func pixelationCells(covering rect: CGRect, layer: ImageAnnotationLayer,
                                        transform: CGAffineTransform) -> CGRect {
        let size = pixelationScale(layer, transform: transform)
        let x = floor((rect.minX - transform.tx) / size) * size + transform.tx
        let y = floor((rect.minY - transform.ty) / size) * size + transform.ty
        let maxX = ceil((rect.maxX - transform.tx) / size) * size + transform.tx
        let maxY = ceil((rect.maxY - transform.ty) / size) * size + transform.ty
        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y).integral
    }

    private static func pixelationScale(_ layer: ImageAnnotationLayer, transform: CGAffineTransform) -> CGFloat {
        max(1, layer.strokeWidth * 4 * transform.a)
    }

    private static func filtered(_ input: CIImage, layer: ImageAnnotationLayer,
                                 transform: CGAffineTransform) -> CIImage {
        if layer.kind == .blur {
            input.applyingFilter("CIGaussianBlur",
                parameters: [kCIInputRadiusKey: max(1, layer.strokeWidth * 2 * transform.a)])
        } else {
            input.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: pixelationScale(layer, transform: transform),
                kCIInputCenterKey: CIVector(x: transform.tx, y: transform.ty)])
        }
    }

    /// The raster sampler and its source-demand calculation must be the same
    /// operation. Core Graphics' implicit high-quality resampler may choose
    /// different samples for an already-cropped CGImage.
    private static func resample(_ image: CIImage, transform: CGAffineTransform) -> CIImage {
        let clamped = image.clampedToExtent()
        let scaled: CIImage
        if transform.a == 1 && transform.d == 1 {
            scaled = clamped
        } else {
            scaled = clamped.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: transform.d,
                kCIInputAspectRatioKey: transform.a / transform.d
            ])
        }
        return scaled.transformed(by: CGAffineTransform(translationX: transform.tx, y: transform.ty))
    }

    private static func drawBase(_ patch: RasterDetail.Patch, in context: CGContext,
                                 layout: RenderLayout, space: CGColorSpace) throws {
        let transform = layout.transform
        // Native one-to-one copies preserve exact input samples and avoid a
        // second bitmap allocation when there is no resampling to perform.
        if transform == .identity,
           patch.rect.width == CGFloat(patch.image.width), patch.rect.height == CGFloat(patch.image.height) {
            context.draw(patch.image, in: patch.rect)
            return
        }
        let patchTransform = CGAffineTransform(scaleX: patch.rect.width / CGFloat(patch.image.width),
                                              y: patch.rect.height / CGFloat(patch.image.height))
        let input = CIImage(cgImage: patch.image).transformed(by: patchTransform)
            .transformed(by: CGAffineTransform(translationX: patch.rect.minX, y: patch.rect.minY))
        let area = layout.working.intersection(patch.rect.applying(transform).integral)
        guard !area.isEmpty else { return }
        let scaled = resample(input, transform: transform)
        let pixels = try renderedImage(scaled, area: area, space: space)
        context.saveGState()
        context.concatenate(transform.inverted())
        context.interpolationQuality = .none
        context.draw(pixels, in: area)
        context.restoreGState()
    }

    /// Materialize into an owned bitmap only after Core Image reports completion.
    /// createCGImage can return a transparent image after a GPU command-buffer
    /// failure; its optional result does not report the render task's error.
    static func renderedImage(_ image: CIImage, area: CGRect, space: CGColorSpace) throws -> CGImage {
        try Task.checkCancellation()
        let context = try bitmap(area, space: space, background: .transparent)
        guard let data = context.data else { throw CocoaError(.fileReadCorruptFile) }
        let destination = CIRenderDestination(bitmapData: data, width: context.width, height: context.height,
                                              bytesPerRow: context.bytesPerRow, format: .RGBA8)
        destination.colorSpace = space
        destination.alphaMode = .premultiplied
        destination.isFlipped = true
        let task = try filterContext.startTask(toRender: image, from: area, to: destination, at: .zero)
        _ = try task.waitUntilCompleted()
        try Task.checkCancellation()
        guard let pixels = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
        return pixels
    }

    private static func bitmap(_ pixels: CGRect, space: CGColorSpace,
                               background: Background) throws -> CGContext {
        guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw WorkspaceError.tooLarge }
        if background != .transparent {
            let value: CGFloat = background == .white ? 1 : 0
            context.setFillColor(CGColor(srgbRed: value, green: value, blue: value, alpha: 1))
            context.fill(CGRect(origin: .zero, size: pixels.size))
        }
        context.translateBy(x: -pixels.minX, y: -pixels.minY)
        return context
    }

    private static func render(_ state: ImageAnnotationState, poster: RasterDetail.Patch,
                               detail: RasterDetail.Patch?, layout: RenderLayout,
                               space: CGColorSpace, background: Background) throws -> CGImage {
        let working = layout.working
        let transform = layout.transform
        let context = try bitmap(working, space: space, background: background)
        context.concatenate(transform)
        context.clip(to: layout.imageBounds)
        context.interpolationQuality = .none
        if let detail, detail.rect.contains(layout.sourceRegion) {
            try drawBase(detail, in: context, layout: layout, space: space)
        } else if let detail {
            context.saveGState()
            context.addRects([poster.rect, detail.rect])
            context.clip(using: .evenOdd)
            try drawBase(poster, in: context, layout: layout, space: space)
            context.restoreGState()
            try drawBase(detail, in: context, layout: layout, space: space)
        } else {
            try drawBase(poster, in: context, layout: layout, space: space)
        }
        for (index, layer) in state.layers.enumerated() {
            try Task.checkCancellation()
            if !layer.kind.filtersPixels {
                drawVector(layer, in: context)
                continue
            }
            guard let region = layout.filterRegions[index] else { continue }
            guard let snapshot = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
            try autoreleasepool {
                let input = CIImage(cgImage: snapshot).transformed(by:
                    CGAffineTransform(translationX: working.minX, y: working.minY)).clampedToExtent()
                let output = filtered(input, layer: layer, transform: transform).cropped(to: region.evaluation)
                let patch = try renderedImage(output, area: region.evaluation, space: space)
                context.saveGState()
                context.concatenate(transform.inverted())
                context.clip(to: region.output)
                context.setBlendMode(.copy)
                context.draw(patch, in: region.evaluation)
                context.restoreGState()
            }
        }
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
        if working == layout.pixels, layout.content == layout.pixels { return image }

        // Discard sampling halos only after composition. Letterbox space is
        // the requested background, never source pixels outside the crop.
        let output = try bitmap(layout.pixels, space: space, background: background)
        output.interpolationQuality = .none
        output.clip(to: layout.content)
        output.setBlendMode(.copy)
        output.draw(image, in: working)
        guard let result = output.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}
