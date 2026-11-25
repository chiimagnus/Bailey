import CoreGraphics
import Foundation
import ImageIO
import SwiftDraw
import UniformTypeIdentifiers

nonisolated enum SVGArtwork {
    static let byteLimit = 1 << 20
    private static let nodeLimit = 4_096
    private static let depthLimit = 48
    private static let referenceDepthLimit = 16

    struct Sanitized {
        let xml: String
        let omitted: [String]
    }

    struct Vector: Sendable {
        let image: SVG
        let omitted: [String]
    }

    struct Raster: Sendable {
        let image: CGImage
        let pointSize: CGSize
    }

    static func parse(_ data: Data) throws -> Vector {
        let cleaned = try sanitizedXML(data)
        guard let svg = SVG(xml: cleaned.xml),
              svg.size.width.isFinite, svg.size.height.isFinite,
              svg.size.width > 0, svg.size.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        return Vector(image: svg, omitted: cleaned.omitted)
    }

    static func render(_ data: Data) throws -> Raster {
        let svg = try parse(data).image
        let scale = min(2, 2048 / max(svg.size.width, svg.size.height))
        let width = max(1, Int(ceil(svg.size.width * scale)))
        let height = max(1, Int(ceil(svg.size.height * scale)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CocoaError(.fileReadCorruptFile) }
        let image = try rasterize(svg, width: width, height: height,
                                  space: space, background: .transparent)
        return Raster(image: image, pointSize: svg.size)
    }

    struct PNGOptions: Sendable {
        static let maximumDimension = 32_768
        static let maximumPixels = 8_000_000

        enum ColorSpace: String, CaseIterable, Sendable {
            case sRGB, displayP3
        }

        enum Background: String, CaseIterable, Sendable {
            case transparent, white, black
        }

        let width: Int
        let height: Int
        var colorSpace: ColorSpace = .sRGB
        var background: Background = .transparent

        var isValid: Bool {
            (1...Self.maximumDimension).contains(width) &&
                (1...Self.maximumDimension).contains(height) && width <= Self.maximumPixels / height
        }
    }

    @concurrent static func png(_ vector: Vector, options: PNGOptions) async throws -> Data {
        try Task.checkCancellation()
        guard options.isValid else { throw WorkspaceError.tooLarge }
        let name = options.colorSpace == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3
        guard let space = CGColorSpace(name: name) else { throw CocoaError(.fileWriteUnknown) }
        let image = try rasterize(vector.image, width: options.width, height: options.height,
                                  space: space, background: options.background, aspectFit: true)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try Task.checkCancellation()
        return data as Data
    }

    private static func rasterize(_ svg: SVG, width: Int, height: Int, space: CGColorSpace,
                                  background: PNGOptions.Background, aspectFit: Bool = false) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileReadCorruptFile) }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if background != .transparent {
            let component: CGFloat = background == .white ? 1 : 0
            context.setFillColor(red: component, green: component, blue: component, alpha: 1)
            context.fill(bounds)
        }
        let destination: CGRect
        if aspectFit {
            let scale = min(CGFloat(width) / svg.size.width, CGFloat(height) / svg.size.height)
            let size = CGSize(width: svg.size.width * scale, height: svg.size.height * scale)
            destination = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height)
        } else {
            destination = bounds
        }
        context.draw(drawing(svg, in: destination))
        guard let image = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

    /// Keep the Core Graphics context in its native space. SwiftDraw captures
    /// the initial CTM as the pattern's base space, so flipping the context
    /// before entering its renderer displaces or reflects asymmetric tiles.
    /// Apply the SVG's top-left orientation in its own vector commands instead.
    static func drawing(_ svg: SVG, in destination: CGRect) -> SVG {
        svg.scaled(x: destination.width / svg.size.width, y: -destination.height / svg.size.height)
            .translated(tx: destination.minX, ty: destination.maxY)
    }

    static func sanitizedXML(_ data: Data) throws -> Sanitized {
        let root = try documentRoot(data)
        var budget = nodeLimit
        var omitted = Set<String>()
        var references = [XMLElement]()
        var rasterPixels = [String: Int]()
        try clean(root, depth: 0, budget: &budget, references: &references, rasterPixels: &rasterPixels, omitted: &omitted)
        try checkExpansion(of: root, references: references, rasterPixels: rasterPixels, omitted: &omitted)
        return Sanitized(xml: root.xmlString, omitted: omitted.sorted())
    }

    static func validateDocument(_ data: Data) throws {
        _ = try documentRoot(data)
    }

    private static func documentRoot(_ data: Data) throws -> XMLElement {
        try Task.checkCancellation()
        guard data.count <= byteLimit else { throw WorkspaceError.tooLarge }
        guard let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
              !source.localizedCaseInsensitiveContains("<!doctype") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let xml = try XMLDocument(xmlString: utf8XML(source), options: [.nodeLoadExternalEntitiesNever])
        guard let root = xml.rootElement(), root.localName == "svg" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    private static func utf8XML(_ source: String) -> String {
        guard source.hasPrefix("<?xml"),
              let separator = source.utf8.dropFirst(5).first, [9, 10, 13, 32].contains(separator),
              let end = source.range(of: "?>")?.upperBound else { return source }
        let declaration = source[..<end].replacingOccurrences(
            of: #"\bencoding\s*=\s*(?:"[A-Za-z][A-Za-z0-9._-]*"|'[A-Za-z][A-Za-z0-9._-]*')"#,
            with: #"encoding="UTF-8""#, options: .regularExpression
        )
        return declaration + source[end...]
    }

    private static let instanceTargets: Set<String> = [
        "svg", "g", "rect", "circle", "ellipse", "line", "polygon", "polyline", "path", "text", "use", "symbol", "image",
    ]
    private static let allowed = instanceTargets.union([
        "defs", "title", "desc", "tspan", "linearGradient", "radialGradient", "stop", "pattern",
        "clipPath", "mask", "filter", "feGaussianBlur", "feOffset", "feBlend", "feComposite",
        "feFlood", "feMerge", "feMergeNode", "feColorMatrix", "feDropShadow",
    ])

    private static let fragmentReferences: Set<String> = ["use", "pattern", "linearGradient", "radialGradient"]

    /// Only a validated, self-contained PNG or JPEG is passed to SwiftDraw's image decoder.
    private static func embeddedRaster(_ href: String) throws -> (href: String, pixels: Int)? {
        let formats: [(String, UTType)] = [("data:image/png;base64,", .png),
            ("data:image/jpeg;base64,", .jpeg), ("data:image/jpg;base64,", .jpeg)]
        guard let (prefix, type) = formats.first(where: { href.hasPrefix($0.0) }),
              let bytes = Data(base64Encoded: String(href.dropFirst(prefix.count)).filter { !$0.isWhitespace })
        else { return nil }
        do {
            guard let source = try RasterPreview.source(bytes),
                  CGImageSourceGetType(source) as String? == type.identifier,
                  CGImageSourceGetCount(source) == 1,
                  let size = RasterPreview.pixelSize(source, at: 0) else { return nil }
            try Task.checkCancellation()
            return (prefix + bytes.base64EncodedString(), Int(size.width) * Int(size.height))
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private static func clean(
        _ element: XMLElement, depth: Int, budget: inout Int, references: inout [XMLElement],
        rasterPixels: inout [String: Int], omitted: inout Set<String>
    ) throws {
        try Task.checkCancellation()
        guard depth <= depthLimit, budget > 0 else { throw WorkspaceError.tooLarge }
        budget -= 1
        let kind = element.localName ?? ""
        if fragmentReferences.contains(kind) || kind == "image" {
            let attributes = element.attributes ?? []
            let reference = attributes.first { $0.name == "href" }
                ?? attributes.first { $0.name == "xlink:href" }
            let href = reference?.stringValue
            for attribute in attributes where attribute.localName?.lowercased() == "href" {
                attribute.detach()
            }
            var accepted: String?
            if kind == "image" {
                if let href, let raster = try embeddedRaster(href) {
                    accepted = raster.href
                    rasterPixels[raster.href] = raster.pixels
                }
            } else if let href, localFragment(href) != nil {
                accepted = href
                references.append(element)
            }
            if let accepted {
                let localHref = XMLNode(kind: .attribute)
                localHref.name = "href"
                localHref.stringValue = accepted
                element.addAttribute(localHref)
            } else {
                if reference != nil { omitted.insert("@href") }
                if kind == "use" || kind == "image" {
                    omitted.insert(kind)
                    element.detach()
                    return
                }
            }
        }
        for attribute in element.attributes ?? [] {
            let name = attribute.localName?.lowercased() ?? ""
            let value = attribute.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if attribute.name == "href", fragmentReferences.contains(kind) || kind == "image" { continue }
            guard !name.hasPrefix("on"), name != "href", name != "base",
                  !(name == "style" && value.contains("@")), let urls = localURLs(in: value) else {
                omitted.insert("@" + name)
                attribute.detach()
                continue
            }
            if ["fill", "stroke", "style", "clip-path", "mask", "filter"].contains(name),
               urls.value != value {
                attribute.stringValue = urls.value
            }
        }
        for child in element.children ?? [] {
            if let child = child as? XMLElement, let name = child.localName, allowed.contains(name) {
                try clean(child, depth: depth + 1, budget: &budget, references: &references, rasterPixels: &rasterPixels, omitted: &omitted)
            } else if child.kind != .text {
                if child.kind == .element, let name = child.localName { omitted.insert(name) }
                child.detach()
            }
        }
    }

    private static func checkExpansion(
        of root: XMLElement, references: [XMLElement], rasterPixels: [String: Int], omitted: inout Set<String>
    ) throws {
        var targets = [String: XMLElement]()
        var ambiguous = Set<String>()
        var pending = [root]
        while let element = pending.popLast() {
            try Task.checkCancellation()
            if let id = element.attribute(forName: "id")?.stringValue,
               targets.updateValue(element, forKey: id) != nil {
                ambiguous.insert(id)
            }
            pending.append(contentsOf: (element.children ?? []).compactMap { $0 as? XMLElement })
        }
        for reference in references {
            let kind = reference.localName ?? ""
            if let href = reference.attribute(forName: "href")?.stringValue, let id = localFragment(href),
               let target = targets[id], let name = target.localName, target !== root {
                guard !ambiguous.contains(id) else { throw CocoaError(.fileReadCorruptFile) }
                let valid = kind == "use" ? instanceTargets.contains(name) :
                    (kind == "pattern" ? name == "pattern" : ["linearGradient", "radialGradient"].contains(name))
                if valid { continue }
            }
            if kind == "use" {
                reference.detach()
                omitted.insert(kind)
            } else {
                reference.attribute(forName: "href")?.detach()
                omitted.insert("@href")
            }
        }

        var nodes = nodeLimit
        var bytes = byteLimit
        var pixels = RasterPreview.pixelLimit
        func visit(_ element: XMLElement, depth: Int, path: Set<String>, inheritedPaints: Set<String>) throws {
            try Task.checkCancellation()
            guard depth <= depthLimit, nodes > 0 else { throw WorkspaceError.tooLarge }
            nodes -= 1
            if element.localName == "image", let href = element.attribute(forName: "href")?.stringValue {
                pixels -= rasterPixels[href] ?? 0
            }
            guard pixels >= 0 else { throw WorkspaceError.tooLarge }
            let attributes = element.attributes ?? []
            let children = element.children ?? []
            bytes -= (element.name?.utf8.count ?? 0) + attributes.reduce(0) { cost, attribute in
                cost + (attribute.name?.utf8.count ?? 0) + (attribute.stringValue?.utf8.count ?? 0)
            } + children.reduce(0) { cost, child in
                cost + (child.kind == .text ? child.stringValue?.utf8.count ?? 0 : 0)
            }
            guard bytes >= 0 else { throw WorkspaceError.tooLarge }

            func follow(_ id: String, paints: Set<String> = []) throws {
                guard let target = targets[id] else { return }
                guard !ambiguous.contains(id), !path.contains(id) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard path.count < referenceDepthLimit else { throw WorkspaceError.tooLarge }
                try visit(target, depth: depth + 1, path: path.union([id]), inheritedPaints: paints)
            }

            var paints = inheritedPaints
            for attribute in attributes where attribute.name != "href" {
                for id in localURLs(in: attribute.stringValue ?? "")?.fragments ?? [] {
                    guard !ambiguous.contains(id) else { throw CocoaError(.fileReadCorruptFile) }
                    switch targets[id]?.localName {
                    case "linearGradient", "radialGradient", "pattern":
                        paints.insert(id)
                    case "clipPath", "mask", "filter":
                        try follow(id)
                    default:
                        break
                    }
                }
            }
            for id in paints {
                try follow(id)
                try follow(id)
            }
            if fragmentReferences.contains(element.localName ?? ""),
               let href = element.attribute(forName: "href")?.stringValue, let id = localFragment(href) {
                try follow(id, paints: element.localName == "use" ? paints : [])
            }
            for child in children.compactMap({ $0 as? XMLElement }) {
                try visit(child, depth: depth + 1, path: path, inheritedPaints: paints)
            }
        }
        try visit(root, depth: 0, path: [], inheritedPaints: [])
    }

    private static func localFragment(_ value: String) -> String? {
        let fragment = value.dropFirst()
        guard value.first == "#", !fragment.isEmpty,
              !fragment.contains(where: { $0.isWhitespace || "#/()'\"\\".contains($0) }),
              let decoded = URL(string: value)?.fragment(percentEncoded: false), !decoded.isEmpty else { return nil }
        return decoded
    }

    private static func localURLs(in value: String) -> (value: String, fragments: [String])? {
        guard value.range(of: "url", options: .caseInsensitive) != nil else { return (value, []) }
        var remaining = value[...]
        var fragments = [String]()
        var normalized = ""
        while let start = remaining.range(of: #"url\s*\("#, options: [.regularExpression, .caseInsensitive]) {
            normalized += remaining[..<start.lowerBound]
            remaining = remaining[start.upperBound...]
            guard let end = remaining.firstIndex(of: ")") else { return nil }
            let token = remaining[..<end].trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))
            )
            guard let fragment = localFragment(token) else { return nil }
            fragments.append(fragment)
            normalized += "url(" + token + ")"
            remaining = remaining[remaining.index(after: end)...]
        }
        return (normalized + remaining, fragments)
    }
}
