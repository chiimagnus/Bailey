import Foundation
import SwiftSoup
import Textual
import Yams

nonisolated struct MarkdownDocument: Sendable {
    struct Property: Sendable, Equatable {
        let name: String
        let value: String
    }

    struct Block: Sendable {
        let anchor: String?
        let content: Content
    }

    enum Content: Sendable {
        case markdown(AttributedString)
        case html([MarkdownHTML])
        case mermaid(source: String, line: Int)
    }

    let properties: [Property]
    let warning: String?
    let blocks: [Block]

    static func supports(_ path: String) -> Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdx": true
        default: false
        }
    }

    @concurrent static func metadata(_ source: String) async -> (properties: [Property], warning: String?) {
        let header = splitHeader(source)
        return (header.properties, header.warning)
    }

    @concurrent static func parse(_ source: String) async throws -> Self {
        try Task.checkCancellation()
        let header = splitHeader(source)
        let original = String(header.body)
        let headerLines = source[..<header.body.startIndex].filter(\.isNewline).count
        var originalLines: [Substring]?
        let rendered = try AttributedString(
            markdown: original, including: \.textual,
            options: .init(appliesSourcePositionAttributes: true)
        )
        try Task.checkCancellation()
        let footnotes = original.contains("[^") ? MarkdownFootnotes(lines: sourceLines(), markup: rendered) : nil
        let footnoteLines = Set(footnotes?.notes.map(\.line) ?? [])
        var blocks: [Block] = []
        var duplicates: [String: Int] = [:]
        var start = rendered.startIndex
        var latest: PresentationIntent.IntentType?
        for run in rendered.runs {
            let outermost = run.presentationIntent?.components.last
            if outermost == latest, outermost != nil { continue }
            if start != run.range.lowerBound {
                try Task.checkCancellation()
                append(rendered[start..<run.range.lowerBound], intent: latest)
            }
            start = run.range.lowerBound
            latest = outermost
        }
        if start != rendered.endIndex { append(rendered[start...], intent: latest) }
        for note in footnotes?.notes ?? [] {
            let text = "[\(note.number)] " + note.text
            let markup = (try? AttributedString(markdown: text)) ?? AttributedString(text)
            blocks.append(Block(anchor: note.anchor, content: .markdown(markup)))
        }
        return Self(properties: header.properties, warning: header.warning, blocks: blocks)

        func append(_ content: AttributedSubstring, intent: PresentationIntent.IntentType?) {
            let plain = String(content.characters)
            if case .codeBlock(let hint)? = intent?.kind,
               hint?.split(whereSeparator: \.isWhitespace).first?.lowercased() == "mermaid" {
                let line = (content.runs.first?.markdownSourcePosition?.startLine ?? 1) + headerLines
                blocks.append(Block(anchor: nil, content: .mermaid(source: plain, line: line)))
                return
            }
            let paragraph: Bool
            if case .paragraph = intent?.kind { paragraph = true } else { paragraph = false }
            if paragraph, let line = content.runs.first?.markdownSourcePosition?.startLine,
               footnoteLines.contains(line) { return }
            if (intent == nil || paragraph), plain.hasPrefix("<"),
               sourcePrefix(content.runs.first?.markdownSourcePosition, count: 1) == "<",
               let html = MarkdownHTML.parse(plain) {
                blocks.append(Block(anchor: nil, content: .html(html)))
                return
            }
            if paragraph, content.runs.count == 1, let url = content.runs.first?.imageURL {
                let node = MarkdownMedia.video(for: url).map { MarkdownHTML.media(url, video: $0) }
                    ?? .image(url, alt: plain)
                blocks.append(Block(anchor: nil, content: .html([node])))
                return
            }
            var anchor: String?
            if case .header = intent?.kind {
                let slug = plain.lowercased().replacingOccurrences(of: " ", with: "-")
                    .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                var next = duplicates[slug, default: 0]
                var unique = next == 0 ? slug : "\(slug)-\(next)"
                while duplicates[unique] != nil && unique != slug {
                    next += 1
                    unique = "\(slug)-\(next)"
                }
                duplicates[slug] = next + 1
                if unique != slug { duplicates[unique] = 1 }
                anchor = unique
            }
            var markup = AttributedString(content)
            switch intent?.kind {
            case .orderedList, .unorderedList:
                markup = formatTaskItems(content, sourcePrefix: sourcePrefix)
            default: break
            }
            if paragraph, plain.contains("<") {
                var inline = AttributedString()
                for run in markup.runs {
                    let value = markup[run.range]
                    let html = String(value.characters)
                    if run.inlinePresentationIntent == nil, html.lowercased().hasPrefix("<img"),
                       sourcePrefix(run.markdownSourcePosition, count: 1) == "<",
                       let nodes = MarkdownHTML.parse(html), nodes.count == 1,
                       case .image(let url, let alt) = nodes.first {
                        var attributes = run.attributes
                        attributes.imageURL = url
                        inline.append(AttributedString(alt.isEmpty ? "Image" : alt, attributes: attributes))
                    } else {
                        inline.append(value)
                    }
                }
                markup = inline
            }
            if let footnotes { markup = footnotes.link(in: markup) }
            blocks.append(Block(anchor: anchor, content: .markdown(markup)))
        }

        func sourceLines() -> [Substring] {
            if let originalLines { return originalLines }
            let lines = original.split(omittingEmptySubsequences: false) {
                $0 == "\n" || $0 == "\r\n" || $0 == "\r"
            }
            originalLines = lines
            return lines
        }

        func sourcePrefix(_ position: AttributedString.MarkdownSourcePosition?, count: Int) -> String? {
            guard let position else { return nil }
            let lines = sourceLines()
            guard lines.indices.contains(position.startLine - 1),
                  position.startColumn > 0 else { return nil }
            let bytes = lines[position.startLine - 1].utf8
            return String(decoding: bytes.dropFirst(position.startColumn - 1).prefix(count), as: UTF8.self)
        }
    }

    private static func formatTaskItems(
        _ content: AttributedSubstring,
        sourcePrefix: (AttributedString.MarkdownSourcePosition?, Int) -> String?
    ) -> AttributedString {
        var result = AttributedString()
        var previous: Int?
        for run in content.runs {
            let leaf = run.presentationIntent?.components.first?.identity
            let text = content[run.range]
            if leaf != previous, run.inlinePresentationIntent == nil, text.characters.first == "[",
               let prefix = sourcePrefix(run.markdownSourcePosition, 4) {
                let marker: String?
                switch prefix {
                case "[x] ", "[X] ": marker = "☑ "
                case "[ ] ": marker = "☐ "
                default: marker = nil
                }
                if let marker, text.characters.starts(with: prefix) {
                    result.append(AttributedString(marker, attributes: run.attributes))
                    let start = text.characters.index(text.startIndex, offsetBy: 4)
                    result.append(AttributedString(text[start...]))
                    previous = leaf
                    continue
                }
            }
            result.append(AttributedString(text))
            previous = leaf
        }
        return result
    }

    private static func splitHeader(_ source: String)
        -> (body: Substring, properties: [Property], warning: String?) {
        let body = source.first == "\u{FEFF}" ? source.dropFirst() : source[...]
        guard let firstEnd = body.firstIndex(where: \.isNewline),
              body[..<firstEnd] == "---" else { return (body, [], nil) }
        let payloadStart = body.index(after: firstEnd)
        var start = payloadStart
        while start < body.endIndex {
            let end = body[start...].firstIndex(where: \.isNewline) ?? body.endIndex
            if body[start..<end] == "---" {
                let markdown = body[(end == body.endIndex ? end : body.index(after: end))...]
                let yaml = body[payloadStart..<start]
                guard yaml.utf8.count <= 64 << 10 else {
                    return (markdown, [], String(localized: "Front matter is too large to preview."))
                }
                do {
                    guard let node = try Yams.compose(yaml: String(yaml)) else { return (markdown, [], nil) }
                    guard let mapping = node.mapping else {
                        return (markdown, [], String(localized: "Front matter must be a YAML mapping."))
                    }
                    var budget = 64 << 10
                    let properties = try mapping.map { pair in
                        try limitMetadata(pair.key, budget: &budget)
                        try limitMetadata(pair.value, budget: &budget)
                        return Property(name: pair.key.scalar?.string ?? String(localized: "Key"),
                                        value: try pair.value.scalar?.string ?? Yams.serialize(node: pair.value))
                    }
                    return (markdown, properties, nil)
                } catch {
                    return (markdown, [], String(localized: "Invalid YAML front matter."))
                }
            }
            start = end == body.endIndex ? end : body.index(after: end)
        }
        return (body, [], String(localized: "Unclosed YAML front matter."))
    }

    private static func limitMetadata(_ node: Yams.Node, budget: inout Int) throws {
        budget -= 8
        guard budget >= 0 else { throw WorkspaceError.tooLarge }
        switch node {
        case .scalar(let scalar):
            budget -= scalar.string.utf8.count
            guard budget >= 0 else { throw WorkspaceError.tooLarge }
        case .sequence(let sequence):
            for child in sequence { try limitMetadata(child, budget: &budget) }
        case .mapping(let mapping):
            for (key, value) in mapping {
                try limitMetadata(key, budget: &budget)
                try limitMetadata(value, budget: &budget)
            }
        case .alias: break
        }
    }
}

nonisolated indirect enum MarkdownHTML: Sendable, Equatable {
    struct TableCell: Sendable, Equatable {
        let text: String
        let isHeader: Bool
    }

    case text(String)
    case paragraph([Self])
    case quote([Self])
    case lineBreak
    case image(URL, alt: String)
    case svg(String, alt: String)
    case table([[TableCell]])
    case media(URL, video: Bool)
    case details(String, [Self], open: Bool)
    case emphasis([Self], tag: String)

    private static let supported: Set<String> = [
        "img", "details", "b", "strong", "em", "i", "s", "del", "code", "kbd",
        "div", "p", "span", "summary", "blockquote", "br", "svg", "table", "video", "audio",
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
            return [.image(url, alt: alt)]
        case "svg":
            let title = element.children().first { $0.tagNameNormal() == "title" }
            let alt = try title?.text() ?? String(localized: "SVG image")
            return [.svg(try element.outerHtml(), alt: alt)]
        case "table":
            let rows = try element.select("tr").map { row in
                try row.children().filter { ["th", "td"].contains($0.tagNameNormal()) }.map {
                    TableCell(text: try $0.text(), isHeader: $0.tagNameNormal() == "th")
                }
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

    private static func reference(_ source: String) -> URL? {
        let encoded = source.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(
            withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#[]"))
        )
        guard let encoded, !encoded.isEmpty else { return nil }
        return URL(string: encoded)
    }
}
