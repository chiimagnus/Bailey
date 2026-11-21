import Foundation
import Markdown
import Yams

/// An immutable, Sendable projection of swift-markdown's AST for the native SwiftUI reader.
nonisolated struct MarkdownDocument: Sendable {
    struct Property: Sendable, Equatable {
        let name: String
        let value: String
    }

    struct Block: Sendable {
        let anchor: String?
        let line: Int
        let content: MarkdownNativeBlock
    }

    let properties: [Property]
    let warning: String?
    let blocks: [Block]

    static func supports(_ path: String) -> Bool {
        ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased())
    }

    @concurrent static func metadata(_ source: String) async -> (properties: [Property], warning: String?) {
        let header = splitHeader(source)
        return (header.properties, header.warning)
    }

    @concurrent static func parse(_ source: String) async throws -> Self {
        try Task.checkCancellation()
        let header = splitHeader(source)
        let headerLineCount = source[..<header.body.startIndex].filter(\.isNewline).count
        let original = String(header.body)
        let initialDocument = Markdown.Document(parsing: original, options: [.disableSmartOpts])
        let footnotes = MarkdownFootnotes(source: original, document: initialDocument)
        let document = footnotes.source == original ? initialDocument
            : Markdown.Document(parsing: footnotes.source, options: [.disableSmartOpts])
        var occupiedAnchors = Set<String>()
        var blocks = try document.children.compactMap { node -> Block? in
            try Task.checkCancellation()
            guard let rendered = project(node) else { return nil }
            let anchor: String?
            if case let .heading(_, inline) = rendered {
                let initial = inlinePlainText(inline).lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                var candidate = initial
                var suffix = 0
                while occupiedAnchors.contains(candidate) {
                    suffix += 1
                    candidate = "\(initial)-\(suffix)"
                }
                occupiedAnchors.insert(candidate)
                anchor = candidate
            } else {
                anchor = nil
            }
            return Block(anchor: anchor,
                         line: (node.range?.lowerBound.line ?? 1) + headerLineCount,
                         content: rendered)
        }
        for note in footnotes.definitions {
            try Task.checkCancellation()
            let noteAST = Markdown.Document(parsing: note.text, options: [.disableSmartOpts])
            let noteInline = (noteAST.children.first as? Markdown.Paragraph)
                .map { projectInline($0.children) } ?? [.text(note.text)]
            blocks.append(Block(anchor: "bailey-note:\(note.name)",
                                line: note.line + headerLineCount,
                                content: .paragraph([.text("[\(note.number)] ")] + noteInline)))
        }
        return Self(properties: header.properties, warning: header.warning, blocks: blocks)
    }

    private static func project(_ node: any Markdown.Markup) -> MarkdownNativeBlock? {
        if let heading = node as? Markdown.Heading {
            return .heading(heading.level, projectInline(heading.children))
        }
        if let paragraph = node as? Markdown.Paragraph {
            let inline = projectInline(paragraph.children)
            if inline.count == 1, case let .image(source, alt) = inline[0] {
                return .image(source, alt)
            }
            // cmark-gfm classifies single-line <audio>/<video> containers as inline HTML.
            // Keep those as native media blocks rather than printing literal tag syntax.
            if let first = inline.first, case let .html(opening) = first,
               ["<audio", "<video"].contains(where: { opening.lowercased().hasPrefix($0) }),
               let nodes = MarkdownHTML.parse(paragraph.format()) {
                return .html(nodes)
            }
            return .paragraph(inline)
        }
        if let quote = node as? Markdown.BlockQuote {
            return .quote(quote.children.compactMap(project))
        }
        if let list = node as? Markdown.UnorderedList {
            return .list(ordered: false, start: 1, items: projectItems(list.children))
        }
        if let list = node as? Markdown.OrderedList {
            return .list(ordered: true, start: Int(clamping: list.startIndex),
                         items: projectItems(list.children))
        }
        if let table = node as? Markdown.Table {
            let head = table.head.children.compactMap { $0 as? Markdown.Table.Cell }
                .map { projectInline($0.children) }
            let rows = Array(table.body.rows.map { row in
                row.children.compactMap { $0 as? Markdown.Table.Cell }
                    .map { projectInline($0.children) }
            })
            let alignments: [MarkdownColumnAlignment] = table.columnAlignments.map {
                switch $0 {
                case .center: .center
                case .right: .trailing
                default: .leading
                }
            }
            return .table(head: head, rows: rows, alignments: alignments)
        }
        if let code = node as? Markdown.CodeBlock {
            if code.language?.lowercased() == "mermaid" {
                return .mermaid(source: code.code, line: node.range?.lowerBound.line ?? 1)
            }
            return .code(code.code, language: code.language)
        }
        if let html = node as? Markdown.HTMLBlock {
            if let elements = MarkdownHTML.parse(html.rawHTML) {
                return .html(elements)
            }
            return .rawHTML(html.rawHTML)
        }
        if node is Markdown.ThematicBreak { return .rule }
        // Unsupported extensions stay visible as source rather than silently disappearing.
        return .rawHTML(node.format())
    }

    private static func projectItems(_ nodes: Markdown.MarkupChildren) -> [MarkdownListItem] {
        nodes.compactMap { $0 as? Markdown.ListItem }.map { item in
            let checked: Bool?
            switch item.checkbox {
            case .checked: checked = true
            case .unchecked: checked = false
            case nil: checked = nil
            }
            return MarkdownListItem(checked: checked,
                                    blocks: item.children.compactMap(project))
        }
    }

    private static func projectInline(_ nodes: Markdown.MarkupChildren) -> [MarkdownInline] {
        nodes.map { node in
            if let text = node as? Markdown.Text { return .text(text.string) }
            if let text = node as? Markdown.InlineCode { return .code(text.code) }
            if let emphasized = node as? Markdown.Emphasis {
                return .emphasis(projectInline(emphasized.children))
            }
            if let strong = node as? Markdown.Strong {
                return .strong(projectInline(strong.children))
            }
            if let strike = node as? Markdown.Strikethrough {
                return .strike(projectInline(strike.children))
            }
            if let link = node as? Markdown.Link {
                return .link(link.destination ?? "", projectInline(link.children))
            }
            if let image = node as? Markdown.Image {
                return .image(image.source ?? "", inlinePlainText(projectInline(image.children)))
            }
            if let html = node as? Markdown.InlineHTML {
                return .html(html.rawHTML)
            }
            if node is Markdown.LineBreak { return .lineBreak }
            if node is Markdown.SoftBreak { return .text("\n") }
            return .text(node.format())
        }
    }

    private static func inlinePlainText(_ inline: [MarkdownInline]) -> String {
        inline.map { node in
            switch node {
            case .text(let source), .code(let source), .html(let source): source
            case .strong(let children), .emphasis(let children), .strike(let children):
                inlinePlainText(children)
            case .link(_, let children): inlinePlainText(children)
            case .image(_, let alt): alt
            case .lineBreak: "\n"
            }
        }.joined()
    }

    private static func splitHeader(_ source: String)
        -> (body: Substring, properties: [Property], warning: String?) {
        let content = source.first == "\u{FEFF}" ? source.dropFirst() : source[...]
        guard let firstLineEnd = content.firstIndex(where: \.isNewline),
              content[..<firstLineEnd] == "---"
        else { return (content, [], nil) }
        let yamlStart = content.index(after: firstLineEnd)
        var cursor = yamlStart
        while cursor < content.endIndex {
            let newline = content[cursor...].firstIndex(where: \.isNewline)
            let lineEnd = newline ?? content.endIndex
            let line = content[cursor..<lineEnd]
            if line == "---" {
                let bodyStart = newline.map { content.index(after: $0) } ?? content.endIndex
                let body = content[bodyStart...]
                let yaml = content[yamlStart..<cursor]
                guard yaml.utf8.count <= 64 << 10 else {
                    return (content, [], "Front matter is too large to preview.")
                }
                do {
                    guard let node = try Yams.compose(yaml: String(yaml)) else { return (body, [], nil) }
                    guard let mapping = node.mapping else {
                        return (content, [], "Front matter must be a YAML mapping.")
                    }
                    var budget = 64 << 10
                    let properties = try mapping.map { pair in
                        try limitMetadata(pair.key, budget: &budget)
                        try limitMetadata(pair.value, budget: &budget)
                        return Property(name: pair.key.scalar?.string ?? "Key",
                                        value: try pair.value.scalar?.string ?? Yams.serialize(node: pair.value))
                    }
                    return (body, properties, nil)
                } catch {
                    return (content, [], "Invalid YAML front matter.")
                }
            }
            guard let newline else { break }
            cursor = content.index(after: newline)
        }
        return (content, [], "Unclosed YAML front matter.")
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

nonisolated struct MarkdownListItem: Sendable {
    let checked: Bool?
    let blocks: [MarkdownNativeBlock]
}

nonisolated enum MarkdownColumnAlignment: Sendable {
    case leading, center, trailing
}

nonisolated indirect enum MarkdownNativeBlock: Sendable {
    case heading(Int, [MarkdownInline])
    case paragraph([MarkdownInline])
    case image(String, String)
    case quote([Self])
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case table(head: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignments: [MarkdownColumnAlignment])
    case code(String, language: String?)
    case mermaid(source: String, line: Int)
    case html([MarkdownHTML])
    case rawHTML(String)
    case rule
}

nonisolated indirect enum MarkdownInline: Sendable {
    case text(String)
    case code(String)
    case emphasis([Self])
    case strong([Self])
    case strike([Self])
    case link(String, [Self])
    case image(String, String)
    case html(String)
    case lineBreak
}
