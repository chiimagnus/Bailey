import CoreGraphics
import Foundation
import SwiftDraw

nonisolated enum SVGArtwork {
    static let byteLimit = 1 << 20

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
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileReadCorruptFile) }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(svg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
        return Raster(image: image, pointSize: svg.size)
    }

    static func sanitizedXML(_ data: Data) throws -> Sanitized {
        let root = try documentRoot(data)
        var budget = 4_096
        var omitted = Set<String>()
        try clean(root, depth: 0, budget: &budget, omitted: &omitted)
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

    private static let allowed: Set<String> = [
        "svg", "g", "defs", "title", "desc", "rect", "circle", "ellipse", "line", "polygon",
        "polyline", "path", "text", "tspan", "linearGradient", "radialGradient", "stop",
        "clipPath", "mask", "filter", "feGaussianBlur", "feOffset", "feBlend", "feComposite",
        "feFlood", "feMerge", "feMergeNode", "feColorMatrix", "feDropShadow",
    ]

    private static func clean(
        _ element: XMLElement, depth: Int, budget: inout Int, omitted: inout Set<String>
    ) throws {
        try Task.checkCancellation()
        guard depth <= 48, budget > 0 else { throw WorkspaceError.tooLarge }
        budget -= 1
        for attribute in element.attributes ?? [] {
            let name = attribute.localName?.lowercased() ?? ""
            let value = attribute.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.hasPrefix("on") || name == "href" || name == "base"
                || name == "style" && value.contains("@")
                || containsNonlocalURL(value) {
                omitted.insert("@" + name)
                attribute.detach()
            }
        }
        for child in element.children ?? [] {
            if let child = child as? XMLElement, let name = child.localName, allowed.contains(name) {
                try clean(child, depth: depth + 1, budget: &budget, omitted: &omitted)
            } else if child.kind != .text {
                if child.kind == .element, let name = child.localName { omitted.insert(name) }
                child.detach()
            }
        }
    }

    private static func containsNonlocalURL(_ value: String) -> Bool {
        var remaining = value[...]
        while let start = remaining.range(of: "url(", options: .caseInsensitive) {
            remaining = remaining[start.upperBound...]
            guard let end = remaining.firstIndex(of: ")") else { return true }
            let token = remaining[..<end].trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))
            )
            let fragment = token.dropFirst()
            guard token.first == "#", !fragment.isEmpty,
                  !fragment.contains(where: {
                      $0.isWhitespace || "#/()'\"\\".contains($0)
                  }) else { return true }
            remaining = remaining[remaining.index(after: end)...]
        }
        return false
    }
}
