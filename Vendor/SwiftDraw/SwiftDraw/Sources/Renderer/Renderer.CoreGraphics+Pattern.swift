//
// Bailey modification: continuous sampling for bitmap pattern paints.

//  Renderer.CoreGraphics.swift
//  SwiftDraw
//
//  Created by Simon Whitty on 4/6/17.
//  Copyright 2020 WhileLoop Pty Ltd. All rights reserved.
//
//  Distributed under the permissive zlib license
//  Get the latest version from here:
//
//  https://github.com/swhitty/SwiftDraw
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//  claim that you wrote the original software. If you use this software
//  in a product, an acknowledgment in the product documentation would be
//  appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//  misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#if canImport(CoreGraphics)
import CoreImage
import CoreImage.CIFilterBuiltins

extension CGTransformingPattern {
    private static let tiler = CIContext(options: [.cacheIntermediates: false])

    /// Rasterize the vector cell at the requested scale with its edges on exact pixel boundaries.
    /// Sample a periodic field in device space: snapping each repeated cell independently either
    /// exposes transparent seams or moves the pattern's phase.
    func paint(in context: CGContext) {
        let toDevice = context.userSpaceToDeviceSpaceTransform
        let patternToDevice = transform.concatenating(toDevice)

        let det = patternToDevice.a * patternToDevice.d - patternToDevice.b * patternToDevice.c
        guard det.isFinite, det != 0 else { return }
        let visible = context.boundingBoxOfClipPath.applying(toDevice).integral.intersection(
            CGRect(x: 0, y: 0, width: context.width, height: context.height)
        )
        guard !visible.isEmpty else { return }
        let width = 2 * max(8, ceil(hypot(patternToDevice.a, patternToDevice.b) * bounds.width))
        let height = 2 * max(8, ceil(hypot(patternToDevice.c, patternToDevice.d) * bounds.height))
        guard width.isFinite, height.isFinite else { return }
        let scale = min(1, 8_192 / max(width, height), sqrt(4_194_304 / width / height))
        guard
            let tile = CGContext.makeFilterLayer(
                width: max(1, Int(width * scale)),
                height: max(1, Int(height * scale)),
                colorSpace: context.colorSpace
            ), let space = tile.colorSpace
        else { return }
        let canonicalToPattern = CGAffineTransform(
            scaleX: bounds.width / CGFloat(tile.width),
            y: bounds.height / CGFloat(tile.height)
        )
        tile.concatenate(canonicalToPattern.inverted())
        tile.translateBy(x: -bounds.minX, y: -bounds.minY)
        CGRenderer(context: tile, baseCTM: .identity).perform(contents)
        guard let image = tile.makeImage() else { return }

        let affine = CIFilter.affineTile()
        affine.inputImage = CIImage(cgImage: image)
        let deviceToPattern = patternToDevice.inverted()
        context.concatenate(toDevice.inverted())
        context.interpolationQuality = .none
        // Bound temporary device images (including long narrow PNG exports) without changing phase.
        for y in stride(from: Int(visible.minY), to: Int(visible.maxY), by: 512) {
            for x in stride(from: Int(visible.minX), to: Int(visible.maxX), by: 2048) {
                let origin = CGPoint(x: x, y: y)
                let point = origin.applying(deviceToPattern)
                let dx = (point.x - bounds.minX).truncatingRemainder(dividingBy: bounds.width)
                let dy = (point.y - bounds.minY).truncatingRemainder(dividingBy: bounds.height)
                guard dx.isFinite, dy.isFinite else { return }
                var local = patternToDevice
                local.tx = -(local.a * dx + local.c * dy)
                local.ty = -(local.b * dx + local.d * dy)
                affine.transform = canonicalToPattern.concatenating(local)
                let rect = CGRect(
                    x: 0,
                    y: 0,
                    width: min(2048, Int(visible.maxX) - x),
                    height: min(512, Int(visible.maxY) - y)
                )
                if let field = affine.outputImage,
                    let patch = Self.tiler.createCGImage(field, from: rect, format: .RGBA8, colorSpace: space)
                {
                    context.draw(patch, in: CGRect(origin: origin, size: rect.size))
                }
            }
        }
    }
}
#endif
