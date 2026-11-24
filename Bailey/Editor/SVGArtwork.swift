import CoreGraphics
import Foundation
import SwiftDraw

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
        var budget = nodeLimit
        var omitted = Set<String>()
        var instances = [XMLElement]()
        try clean(root, depth: 0, budget: &budget, instances: &instances, omitted: &omitted)
        if !instances.isEmpty {
            try checkExpansion(of: root, instances: instances, omitted: &omitted)
        }
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
        "svg", "g", "rect", "circle", "ellipse", "line", "polygon", "polyline", "path", "text", "use", "symbol",
    ]
    private static let allowed = instanceTargets.union([
        "defs", "title", "desc", "tspan", "linearGradient", "radialGradient", "stop",
        "clipPath", "mask", "filter", "feGaussianBlur", "feOffset", "feBlend", "feComposite",
        "feFlood", "feMerge", "feMergeNode", "feColorMatrix", "feDropShadow",
    ])

    private static func clean(
        _ element: XMLElement, depth: Int, budget: inout Int, instances: inout [XMLElement],
        omitted: inout Set<String>
    ) throws {
        try Task.checkCancellation()
        guard depth <= depthLimit, budget > 0 else { throw WorkspaceError.tooLarge }
        budget -= 1
        if element.localName == "use" {
            let attributes = element.attributes ?? []
            let reference = attributes.first { $0.name == "href" }
                ?? attributes.first { $0.name == "xlink:href" }
            guard let href = reference?.stringValue, localFragment(href) != nil else {
                if reference != nil { omitted.insert("@href") }
                omitted.insert("use")
                element.detach()
                return
            }
            for attribute in attributes where attribute.localName?.lowercased() == "href" {
                attribute.detach()
            }
            let localHref = XMLNode(kind: .attribute)
            localHref.name = "href"
            localHref.stringValue = href
            element.addAttribute(localHref)
            instances.append(element)
        }
        for attribute in element.attributes ?? [] {
            let name = attribute.localName?.lowercased() ?? ""
            let value = attribute.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name == "href", element.localName == "use" { continue }
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
                try clean(child, depth: depth + 1, budget: &budget, instances: &instances, omitted: &omitted)
            } else if child.kind != .text {
                if child.kind == .element, let name = child.localName { omitted.insert(name) }
                child.detach()
            }
        }
    }

    private static func checkExpansion(
        of root: XMLElement, instances: [XMLElement], omitted: inout Set<String>
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
        for instance in instances {
            if let href = instance.attribute(forName: "href")?.stringValue, let id = localFragment(href),
               let target = targets[id], let name = target.localName, target !== root,
               instanceTargets.contains(name) {
                continue
            }
            instance.detach()
            omitted.insert("use")
        }

        var nodes = nodeLimit
        var bytes = byteLimit
        func visit(_ element: XMLElement, depth: Int, path: Set<String>, inheritedPaints: Set<String>) throws {
            try Task.checkCancellation()
            guard depth <= depthLimit, nodes > 0 else { throw WorkspaceError.tooLarge }
            nodes -= 1
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
                    case "linearGradient", "radialGradient":
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
            if element.localName == "use", let href = element.attribute(forName: "href")?.stringValue,
               let id = localFragment(href) {
                try follow(id, paints: paints)
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
