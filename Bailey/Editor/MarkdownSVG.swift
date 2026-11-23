import CoreGraphics
import Foundation
import SwiftDraw

nonisolated enum MarkdownSVG {
    struct Raster: Sendable {
        let image: CGImage
        let pointSize: CGSize
    }

    static func render(_ data: Data) throws -> Raster {
        guard let svg = SVG(xml: try sanitizedXML(data)),
              svg.size.width.isFinite, svg.size.height.isFinite,
              svg.size.width > 0, svg.size.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
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

    static func sanitizedXML(_ data: Data) throws -> String {
        guard data.count <= 1 << 20 else { throw WorkspaceError.tooLarge }
        guard let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
              !source.localizedCaseInsensitiveContains("<!doctype") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let xml = try XMLDocument(xmlString: source, options: [.nodeLoadExternalEntitiesNever])
        guard let root = xml.rootElement(), root.localName == "svg" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var budget = 4_096
        try clean(root, depth: 0, budget: &budget)
        return root.xmlString
    }

    private static let allowed: Set<String> = [
        "svg", "g", "defs", "title", "desc", "rect", "circle", "ellipse", "line", "polygon",
        "polyline", "path", "text", "tspan", "linearGradient", "radialGradient", "stop",
        "clipPath", "mask", "filter", "feGaussianBlur", "feOffset", "feBlend", "feComposite",
        "feFlood", "feMerge", "feMergeNode", "feColorMatrix", "feDropShadow",
    ]

    private static func clean(_ element: XMLElement, depth: Int, budget: inout Int) throws {
        try Task.checkCancellation()
        guard depth <= 48, budget > 0 else { throw WorkspaceError.tooLarge }
        budget -= 1
        for attribute in element.attributes ?? [] {
            let name = attribute.localName?.lowercased() ?? ""
            let value = attribute.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.hasPrefix("on") || name == "href" || name == "base"
                || name == "style" && value.contains("@")
                || containsNonlocalURL(value) {
                attribute.detach()
            }
        }
        for child in element.children ?? [] {
            if let child = child as? XMLElement, let name = child.localName, allowed.contains(name) {
                try clean(child, depth: depth + 1, budget: &budget)
            } else if child.kind != .text {
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
