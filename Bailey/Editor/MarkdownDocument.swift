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
        var sourceRange: NSRange? = nil
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
        let headerLineCount = source[..<header.body.startIndex].filter(\.isMarkdownLineEnding).count
        let original = String(header.body)
        let coordinates = MarkdownOriginalCoordinates(
            body: original, headerUTF16: source[..<header.body.startIndex].utf16.count
        )
        let initialDocument = Markdown.Document(parsing: original, options: [.disableSmartOpts])
        let footnotes = MarkdownFootnotes(source: original, document: initialDocument)
        let unprotectedDocument = footnotes.source == original ? initialDocument
            : Markdown.Document(parsing: footnotes.source, options: [.disableSmartOpts])
        let protected = MarkdownMath.protect(footnotes.source, ast: unprotectedDocument)
        let document = protected.expressions.isEmpty ? unprotectedDocument
            : Markdown.Document(parsing: protected.source, options: [.disableSmartOpts])
        let math = MarkdownMath.Source(protected.source)
        // Render from the rewritten AST, but only the original AST can provide
        // exact source ranges when formulas or footnotes changed byte lengths.
        var originalByLine: [Int: [Markdown.SourceRange]] = [:]
        for node in initialDocument.children {
            if let range = node.range {
                originalByLine[range.lowerBound.line, default: []].append(range)
            }
        }
        var occupiedAnchors = Set<String>()
        var blocks = try document.children.compactMap { node -> Block? in
            try Task.checkCancellation()
            guard let rendered = project(node, math: math, protected: protected) else { return nil }
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
            let sourceRange: NSRange?
            if let line = node.range?.lowerBound.line,
               var originalRanges = originalByLine[line], !originalRanges.isEmpty {
                sourceRange = coordinates.range(originalRanges.removeFirst())
                originalByLine[line] = originalRanges
            } else {
                sourceRange = nil
            }
            return Block(anchor: anchor,
                         line: (node.range?.lowerBound.line ?? 1) + headerLineCount,
                         content: rendered, sourceRange: sourceRange)
        }
        let notes = footnotes.definitions
        if let first = notes.first {
            blocks.append(Block(anchor: nil, line: first.line + headerLineCount,
                                content: .rule))
        }
        for note in notes {
            try Task.checkCancellation()
            let noteAST = Markdown.Document(parsing: note.text, options: [.disableSmartOpts])
            let noteProtected = MarkdownMath.protect(note.text, ast: noteAST)
            let mathAST = noteProtected.expressions.isEmpty ? noteAST
                : Markdown.Document(parsing: noteProtected.source, options: [.disableSmartOpts])
            let noteMath = MarkdownMath.Source(noteProtected.source)
            let noteInline = (mathAST.child(at: 0) as? Markdown.Paragraph)
                .map { projectInline($0.children, math: noteMath, protected: noteProtected) }
                ?? [.text(note.text)]
            blocks.append(Block(anchor: "bailey-note:\(note.name)",
                                line: note.line + headerLineCount,
                                content: .paragraph([.text("\(note.number). ")] + noteInline),
                                sourceRange: coordinates.lines(note.line...note.endLine)))
        }
        return Self(properties: header.properties, warning: header.warning, blocks: blocks)
    }

    private static func project(_ node: any Markdown.Markup,
                                math: MarkdownMath.Source,
                                protected: MarkdownMath.Protected) -> MarkdownNativeBlock? {
        if let heading = node as? Markdown.Heading {
            return .heading(heading.level, projectInline(heading.children, math: math, protected: protected))
        }
        if let paragraph = node as? Markdown.Paragraph {
            if let latex = math.display(paragraph) { return .mathBlock(latex) }
            let inline = projectInline(paragraph.children, math: math, protected: protected)
            if inline.count == 1, case let .math(latex, display: true) = inline[0] {
                return .mathBlock(latex)
            }
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
            return .quote(quote.children.compactMap { project($0, math: math, protected: protected) })
        }
        if let list = node as? Markdown.UnorderedList {
            return .list(ordered: false, start: 1, items: projectItems(list.children, math: math, protected: protected))
        }
        if let list = node as? Markdown.OrderedList {
            return .list(ordered: true, start: Int(clamping: list.startIndex),
                         items: projectItems(list.children, math: math, protected: protected))
        }
        if let table = node as? Markdown.Table {
            let head = table.head.children.compactMap { $0 as? Markdown.Table.Cell }
                .map { projectInline($0.children, math: math, protected: protected) }
            let rows = Array(table.body.rows.map { row in
                row.children.compactMap { $0 as? Markdown.Table.Cell }
                    .map { projectInline($0.children, math: math, protected: protected) }
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

    private static func projectItems(_ nodes: Markdown.MarkupChildren,
                                     math: MarkdownMath.Source,
                                     protected: MarkdownMath.Protected) -> [MarkdownListItem] {
        nodes.compactMap { $0 as? Markdown.ListItem }.map { item in
            let checked: Bool?
            switch item.checkbox {
            case .checked: checked = true
            case .unchecked: checked = false
            case nil: checked = nil
            }
            return MarkdownListItem(checked: checked,
                                    blocks: item.children.compactMap { project($0, math: math, protected: protected) })
        }
    }

    private static func projectInline(_ nodes: Markdown.MarkupChildren,
                                      math: MarkdownMath.Source,
                                      protected: MarkdownMath.Protected) -> [MarkdownInline] {
        nodes.flatMap { node -> [MarkdownInline] in
            if let text = node as? Markdown.Text {
                return protected.inlines(text.string)
            }
            if let text = node as? Markdown.InlineCode { return [.code(text.code)] }
            if let emphasized = node as? Markdown.Emphasis {
                return [.emphasis(projectInline(emphasized.children, math: math, protected: protected))]
            }
            if let strong = node as? Markdown.Strong {
                return [.strong(projectInline(strong.children, math: math, protected: protected))]
            }
            if let strike = node as? Markdown.Strikethrough {
                return [.strike(projectInline(strike.children, math: math, protected: protected))]
            }
            if let link = node as? Markdown.Link {
                return [.link(link.destination ?? "", projectInline(link.children, math: math, protected: protected))]
            }
            if let image = node as? Markdown.Image {
                return [.image(image.source ?? "", inlinePlainText(projectInline(image.children, math: math, protected: protected)))]
            }
            if let html = node as? Markdown.InlineHTML { return [.html(html.rawHTML)] }
            if node is Markdown.LineBreak { return [.lineBreak] }
            if node is Markdown.SoftBreak { return [.text("\n")] }
            return [.text(node.format())]
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
            case .math(let latex, let display): display ? "$$\(latex)$$" : "$\(latex)$"
            }
        }.joined()
    }

    private static func splitHeader(_ source: String)
        -> (body: Substring, properties: [Property], warning: String?) {
        let content = source.first == "\u{FEFF}" ? source.dropFirst() : source[...]
        guard let firstLineEnd = content.firstIndex(where: \.isMarkdownLineEnding),
              content[..<firstLineEnd] == "---"
        else { return (content, [], nil) }
        let yamlStart = content.index(after: firstLineEnd)
        var cursor = yamlStart
        while cursor < content.endIndex {
            let newline = content[cursor...].firstIndex(where: \.isMarkdownLineEnding)
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

/// A sorted, compact lookup over the original source ranges of rendered blocks.
/// The extra footnote views can appear in a different order than their source.
nonisolated struct MarkdownBlockIndex: Sendable {
    private struct Entry: Sendable {
        let range: NSRange
        let index: Int
    }
    private let entries: [Entry]

    init(_ document: MarkdownDocument) {
        entries = document.blocks.enumerated().compactMap { index, block in
            block.sourceRange.map { Entry(range: $0, index: index) }
        }.sorted { $0.range.location < $1.range.location }
    }

    func block(atUTF16Offset offset: Int) -> Int? {
        guard !entries.isEmpty else { return nil }
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].range.location <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        return entries[max(0, lower - 1)].index
    }
}

/// Converts cmark's 1-based UTF-8 byte columns into TextKit's original UTF-16
/// offsets. Line breaks (including CRLF) are measured in the unmodified source.
private nonisolated struct MarkdownOriginalCoordinates {
    private let body: String
    private let headerUTF16: Int
    private let lineStarts: [String.Index]
    private let lineUTF16Starts: [Int]
    private let lineUTF16Ends: [Int]

    init(body: String, headerUTF16: Int) {
        self.body = body
        self.headerUTF16 = headerUTF16
        var indices = [body.startIndex]
        var starts = [0]
        var ends: [Int] = []
        var offset = 0
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            let next = body.index(after: index)
            if character.isMarkdownLineEnding {
                ends.append(offset)
                offset += character.utf16.count
                indices.append(next)
                starts.append(offset)
            } else {
                offset += character.utf16.count
            }
            index = next
        }
        ends.append(offset)
        lineStarts = indices
        lineUTF16Starts = starts
        lineUTF16Ends = ends
    }

    private func offset(_ location: Markdown.SourceLocation) -> Int? {
        let row = location.line - 1
        let column = location.column - 1
        guard row >= 0, row < lineStarts.count, column >= 0 else { return nil }
        let start = lineStarts[row]
        let end = row + 1 < lineStarts.count ? lineStarts[row + 1] : body.endIndex
        let bytes = body.utf8
        guard let boundary = bytes.index(start, offsetBy: column, limitedBy: end),
              let prefix = String(bytes: bytes[start..<boundary], encoding: .utf8)
        else { return nil }
        return headerUTF16 + lineUTF16Starts[row] + prefix.utf16.count
    }

    func range(_ source: Markdown.SourceRange) -> NSRange? {
        guard let lower = offset(source.lowerBound),
              let upper = offset(source.upperBound),
              upper >= lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    func lines(_ lines: ClosedRange<Int>) -> NSRange? {
        let first = lines.lowerBound - 1
        let last = lines.upperBound - 1
        guard first >= 0, last < lineUTF16Ends.count else { return nil }
        let start = headerUTF16 + lineUTF16Starts[first]
        let end = headerUTF16 + lineUTF16Ends[last]
        return NSRange(location: start, length: end - start)
    }
}

extension Character {
    nonisolated var isMarkdownLineEnding: Bool {
        self == "\n" || self == "\r" || self == "\r\n"
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
    case mathBlock(String)
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
    case math(String, display: Bool)
    case html(String)
    case lineBreak
}
