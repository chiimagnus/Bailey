import Foundation
import SwiftSoup

nonisolated indirect enum MarkdownHTML: Sendable, Equatable {
    struct TableCell: Sendable, Equatable {
        let nodes: [MarkdownHTML]
        let isHeader: Bool
    }

    struct TableRow: Sendable, Equatable {
        let cells: [TableCell]
        let shaded: Bool
    }

    case text(String)
    case paragraph([Self])
    case quote([Self])
    case lineBreak
    case image(URL, alt: String, width: Int?, height: Int?)
    case svg(String, alt: String)
    case table([TableRow])
    case media(URL, video: Bool)
    case details(String, [Self], open: Bool)
    case emphasis([Self], tag: String)
    case link(URL, [Self])
    case heading(Int, [Self])
    case list(ordered: Bool, start: Int, items: [[Self]])
    case horizontalRule

    private static let supported: Set<String> = [
        "img", "details", "b", "strong", "em", "i", "s", "del", "code", "kbd", "a",
        "div", "p", "span", "summary", "blockquote", "br", "svg", "table", "video", "audio",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "hr",
    ]

    static func parse(_ source: String) -> [Self]? {
        guard source.utf8.count <= 256 << 10 else { return nil }
        do {
            let parser = Parser.htmlParser().settings(.preserveCase)
            let document = try parser.parseInput(source, "")
            _ = document.outputSettings().prettyPrint(pretty: false)
            guard let body = document.body(),
                  body.children().contains(where: { supported.contains($0.tagNameNormal()) }) else { return nil }
            return try body.getChildNodes().flatMap { try render($0, depth: 0) }
        } catch {
            return nil
        }
    }

    private static func render(_ node: SwiftSoup.Node, depth: Int) throws -> [Self] {
        if let text = node as? TextNode { return [.text(text.getWholeText())] }
        guard let element = node as? Element, depth < 32 else { return [] }
        let tag = element.tagNameNormal()
        switch tag {
        case "img":
            let alt = try element.attr("alt")
            guard let url = try reference(element.attr("src")) else {
                return [.text(alt)]
            }
            return [.image(url, alt: alt,
                           width: dimension(try element.attr("width")),
                           height: dimension(try element.attr("height")))]
        case "svg":
            let title = element.children().first { $0.tagNameNormal() == "title" }
            let alt = try title?.text() ?? String(localized: "SVG image")
            return [.svg(try element.outerHtml(), alt: alt)]
        case "table":
            let rows = try element.select("tr").filter { row in
                var ancestor = row.parent()
                while let parent = ancestor {
                    if parent.tagNameNormal() == "table" { return parent === element }
                    ancestor = parent.parent()
                }
                return false
            }.map { row in
                let cells = try row.children().filter { ["th", "td"].contains($0.tagNameNormal()) }.map { cell in
                    TableCell(nodes: try cell.getChildNodes().flatMap { try render($0, depth: depth + 1) },
                              isHeader: cell.tagNameNormal() == "th")
                }
                // CSS tr:nth-child(2n) counts within thead/tbody, not the whole table.
                return TableRow(cells: cells, shaded: try !row.elementSiblingIndex().isMultiple(of: 2))
            }
            return [.table(rows)]
        case "video", "audio":
            let fallback = element.children().filter { $0.tagNameNormal() == "source" }
            let candidates = try [element.attr("src")] + fallback.map { try $0.attr("src") }
            if element.hasAttr("controls"),
               let url = candidates.compactMap(reference).first(where: { MarkdownMedia.video(for: $0) == (tag == "video") }) {
                return [.media(url, video: tag == "video")]
            }
            return [.text(try element.outerHtml())]
        case "details":
            let summary = element.children().first { $0.tagNameNormal() == "summary" }
            let label = try summary?.text() ?? String(localized: "Details")
            let children = try element.getChildNodes().filter { $0 !== summary }
                .flatMap { try render($0, depth: depth + 1) }
            return [.details(label, children, open: element.hasAttr("open"))]
        case "a":
            let children = try element.getChildNodes().flatMap { try render($0, depth: depth + 1) }
            guard let url = try reference(element.attr("href")),
                  url.scheme == nil || (["http", "https"].contains(url.scheme?.lowercased() ?? "")
                                        && url.host != nil) else { return children }
            return [.link(url, children)]
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let children = try element.getChildNodes().flatMap { try render($0, depth: depth + 1) }
            return [.heading(Int(String(tag.suffix(1))) ?? 6, children)]
        case "ul", "ol":
            let items = try element.children().filter { $0.tagNameNormal() == "li" }.map { child in
                try child.getChildNodes().flatMap { try render($0, depth: depth + 1) }
            }
            let start = Int(try element.attr("start")).flatMap {
                (-1_000_000...1_000_000).contains($0) ? $0 : nil
            } ?? 1
            return [.list(ordered: tag == "ol", start: start, items: items)]
        case "hr":
            return [.horizontalRule]
        case "li":
            return [.paragraph(try element.getChildNodes().flatMap { try render($0, depth: depth + 1) })]
        case "b", "strong", "em", "i", "s", "del", "code", "kbd":
            let children = try element.getChildNodes().flatMap { try render($0, depth: depth + 1) }
            return [.emphasis(children, tag: tag)]
        case "p", "div":
            return [.paragraph(try element.getChildNodes().flatMap { try render($0, depth: depth + 1) })]
        case "blockquote":
            return [.quote(try element.getChildNodes().flatMap { try render($0, depth: depth + 1) })]
        case "span", "summary":
            return try element.getChildNodes().flatMap { try render($0, depth: depth + 1) }
        case "br":
            return [.lineBreak]
        default:
            return [.text(try element.outerHtml())]
        }
    }

    private static func dimension(_ value: String) -> Int? {
        guard let number = Int(value), (1...4096).contains(number) else { return nil }
        return number
    }

    private static func reference(_ source: String) -> URL? {
        let encoded = source.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(
            withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#[]"))
        )
        guard let encoded, !encoded.isEmpty else { return nil }
        return URL(string: encoded)
    }
}
