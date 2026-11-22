import Foundation
import Markdown
import SwiftSoup
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
        var original = String(header.body)
        original.makeContiguousUTF8()
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
        let renderedCoordinates = protected.source == original ? coordinates
            : MarkdownOriginalCoordinates(body: protected.source, headerUTF16: 0)
        func originalByteRange(_ rendered: Range<Int>) -> NSRange? {
            guard let beforeMath = protected.rewrite.originalBytes(for: rendered),
                  let beforeNotes = footnotes.rewrite.originalBytes(for: beforeMath) else { return nil }
            return coordinates.utf16Range(beforeNotes)
        }
        func originalRange(_ range: Markdown.SourceRange) -> NSRange? {
            renderedCoordinates.bytes(range).flatMap(originalByteRange)
        }
        func projectText(_ node: Markdown.Text) -> [MarkdownInline] {
            let value = node.string
            let rawBytes = protected.source.utf8
            guard let span = node.range.flatMap(renderedCoordinates.bytes) else { return protected.inlines(value) }
            let start = rawBytes.index(rawBytes.startIndex, offsetBy: span.lowerBound)
            let end = rawBytes.index(start, offsetBy: span.count)
            let raw = rawBytes[start..<end]
            let normalized: MarkdownSourceRewrite?
            if value.utf8.elementsEqual(raw) {
                normalized = nil
            } else {
                let rewrite = MarkdownSourceRewrite.normalizingInlineText(String(decoding: raw, as: UTF8.self))
                guard rewrite.source.utf8.elementsEqual(value.utf8) else { return protected.inlines(value) }
                normalized = rewrite
            }
            let bytes = value.utf8
            return protected.inlines(value) { part in
                let from = bytes.distance(from: bytes.startIndex, to: part.startIndex)
                let display = from..<(from + part.utf8.count)
                if let normalized {
                    return normalized.segments(in: display).map { segment in
                        let start = bytes.index(part.startIndex, offsetBy: segment.lowerBound - from)
                        let end = bytes.index(start, offsetBy: segment.count)
                        let source = normalized.originalBytes(for: segment).flatMap {
                            originalByteRange((span.lowerBound + $0.lowerBound)..<(span.lowerBound + $0.upperBound))
                        }
                        return .text(String(decoding: bytes[start..<end], as: UTF8.self), source: source)
                    }
                }
                return [.text(String(part), source: originalByteRange(
                    (span.lowerBound + display.lowerBound)..<(span.lowerBound + display.upperBound)
                ))]
            }
        }
        func projectCode(_ node: Markdown.InlineCode) -> [MarkdownInline] {
            let fallback: [MarkdownInline] = [.code(node.code)]
            guard let span = node.range.flatMap(renderedCoordinates.bytes) else { return fallback }
            let bytes = protected.source.utf8
            let start = bytes.index(bytes.startIndex, offsetBy: span.lowerBound)
            let end = bytes.index(start, offsetBy: span.count)
            let raw = bytes[start..<end]
            let fence = raw.prefix(while: { $0 == 0x60 }).count
            guard fence > 0, raw.count >= fence * 2,
                  raw.suffix(fence).allSatisfy({ $0 == 0x60 }) else { return fallback }

            let inner = String(decoding: raw.dropFirst(fence).dropLast(fence), as: UTF8.self)
            let innerBytes = Array(inner.utf8)
            var edits: [MarkdownSourceRewrite.Replacement] = []
            var cursor = 0
            while cursor < innerBytes.count {
                let size: Int
                if innerBytes[cursor] == 13 {
                    size = cursor + 1 < innerBytes.count && innerBytes[cursor + 1] == 10 ? 2 : 1
                } else if innerBytes[cursor] == 10 {
                    size = 1
                } else {
                    cursor += 1
                    continue
                }
                edits.append(.init(bytes: cursor..<(cursor + size), text: " "))
                cursor += size
            }
            let rewrite = MarkdownSourceRewrite(inner, replacing: edits)
            let normalized = rewrite.source
            let trimmed = normalized.first == " " && normalized.last == " "
                && normalized.contains(where: { $0 != " " })
            let lower = trimmed ? 1 : 0
            let upper = normalized.utf8.count - (trimmed ? 1 : 0)
            guard lower <= upper else { return fallback }
            let rewrittenBytes = Array(normalized.utf8)
            guard String(decoding: rewrittenBytes[lower..<upper], as: UTF8.self) == node.code
            else { return fallback }

            var mapped: [MarkdownInline] = []
            for segment in rewrite.segments(in: lower..<upper) where !segment.isEmpty {
                guard let original = rewrite.originalBytes(for: segment) else { return fallback }
                let offset = span.lowerBound + fence
                let originalSpan = (offset + original.lowerBound)..<(offset + original.upperBound)
                mapped.append(.code(String(decoding: rewrittenBytes[segment], as: UTF8.self),
                                    source: originalByteRange(originalSpan)))
            }
            return mapped.isEmpty ? fallback : mapped
        }
        var occupiedAnchors = Set<String>()
        var blocks = try document.children.compactMap { node -> Block? in
            try Task.checkCancellation()
            guard let rendered = project(
                node, math: math, projectText: projectText,
                projectCode: projectCode, allowsAlert: true
            ) else { return nil }
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
                         content: rendered, sourceRange: node.range.flatMap(originalRange))
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
            let noteInline = (mathAST.child(at: 0) as? Markdown.Paragraph)
                .map {
                    projectInline($0.children, projectText: { noteProtected.inlines($0.string) },
                                  projectCode: { [.code($0.code)] })
                }
                ?? [.text(note.text)]
            blocks.append(Block(anchor: "bailey-note:\(note.name)",
                                line: note.line + headerLineCount,
                                content: .paragraph([.text("\(note.number). ")] + noteInline),
                                sourceRange: coordinates.lines(note.line...note.endLine)))
        }
        return Self(properties: header.properties, warning: header.warning, blocks: blocks)
    }

    private typealias TextProjection = (Markdown.Text) -> [MarkdownInline]
    private typealias CodeProjection = (Markdown.InlineCode) -> [MarkdownInline]

    private static func project(_ node: any Markdown.Markup,
                                math: MarkdownMath.Source,
                                projectText: TextProjection,
                                projectCode: CodeProjection,
                                allowsAlert: Bool = false) -> MarkdownNativeBlock? {
        if let heading = node as? Markdown.Heading {
            return .heading(heading.level, projectInline(
                heading.children, projectText: projectText, projectCode: projectCode
            ))
        }
        if let paragraph = node as? Markdown.Paragraph {
            if let latex = math.display(paragraph) { return .mathBlock(latex) }
            let inline = projectInline(
                paragraph.children, projectText: projectText, projectCode: projectCode
            )
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
            let blocks = quote.children.compactMap {
                project($0, math: math, projectText: projectText, projectCode: projectCode)
            }
            guard allowsAlert,
                  let opening = quote.child(at: 0) as? Markdown.Paragraph,
                  opening.childCount == 1 || opening.child(at: 1) is Markdown.SoftBreak
                      || opening.child(at: 1) is Markdown.LineBreak,
                  case .paragraph(let contents) = blocks.first,
                  case .text(let marker, let source?) = contents.first,
                  source.length == marker.utf16.count,
                  let alert = MarkdownAlert(rawValue: marker)
            else { return .quote(blocks) }
            let openingBody = Array(contents.dropFirst(2))
            let body = openingBody.isEmpty ? [] : [MarkdownNativeBlock.paragraph(openingBody)]
            return .alert(alert, body + blocks.dropFirst())
        }
        if let list = node as? Markdown.UnorderedList {
            return .list(ordered: false, start: 1, items: projectItems(list.children, math: math, projectText: projectText, projectCode: projectCode))
        }
        if let list = node as? Markdown.OrderedList {
            return .list(ordered: true, start: Int(clamping: list.startIndex),
                         items: projectItems(list.children, math: math, projectText: projectText, projectCode: projectCode))
        }
        if let table = node as? Markdown.Table {
            let head = table.head.children.compactMap { $0 as? Markdown.Table.Cell }
                .map { projectInline($0.children, projectText: projectText, projectCode: projectCode) }
            var rows: [[[MarkdownInline]]] = []
            for row in table.body.rows {
                rows.append(row.children.compactMap { $0 as? Markdown.Table.Cell }
                    .map { projectInline($0.children, projectText: projectText, projectCode: projectCode) })
            }
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
                                      projectText: TextProjection,
                                     projectCode: CodeProjection) -> [MarkdownListItem] {
        nodes.compactMap { $0 as? Markdown.ListItem }.map { item in
            let checked: Bool?
            switch item.checkbox {
            case .checked: checked = true
            case .unchecked: checked = false
            case nil: checked = nil
            }
            return MarkdownListItem(checked: checked,
                                    blocks: item.children.compactMap { project($0, math: math, projectText: projectText, projectCode: projectCode) })
        }
    }

    private static func projectInline(_ nodes: Markdown.MarkupChildren,
                                      projectText: TextProjection,
                                      projectCode: CodeProjection) -> [MarkdownInline] {
        nodes.flatMap { node -> [MarkdownInline] in
            if let text = node as? Markdown.Text {
                return projectText(text)
            }
            if let code = node as? Markdown.InlineCode { return projectCode(code) }
            if let emphasized = node as? Markdown.Emphasis {
                return [.emphasis(projectInline(emphasized.children, projectText: projectText, projectCode: projectCode))]
            }
            if let strong = node as? Markdown.Strong {
                return [.strong(projectInline(strong.children, projectText: projectText, projectCode: projectCode))]
            }
            if let strike = node as? Markdown.Strikethrough {
                return [.strike(projectInline(strike.children, projectText: projectText, projectCode: projectCode))]
            }
            if let link = node as? Markdown.Link {
                return [.link(link.destination ?? "", projectInline(link.children, projectText: projectText, projectCode: projectCode))]
            }
            if let image = node as? Markdown.Image {
                return [.image(image.source ?? "", inlinePlainText(projectInline(image.children, projectText: projectText, projectCode: projectCode)))]
            }
            if let html = node as? Markdown.InlineHTML { return [.html(html.rawHTML)] }
            if node is Markdown.LineBreak { return [.lineBreak] }
            if node is Markdown.SoftBreak { return [.text(" ")] }
            return [.text(node.format())]
        }
    }

    private static func inlinePlainText(_ inline: [MarkdownInline]) -> String {
        inline.map { node in
            switch node {
            case .text(let source, _), .code(let source, _), .html(let source): source
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

nonisolated struct MarkdownSourceRewrite {
    struct Replacement {
        let bytes: Range<Int>
        let text: String
    }

    private struct Edit {
        let original: Range<Int>
        let rewritten: Range<Int>
    }

    let source: String
    private let edits: [Edit]

    static func normalizingInlineText(_ source: String) -> Self {
        let bytes = Array(source.utf8)
        var edits: [Replacement] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 92, index + 1 < bytes.count {
                let next = bytes[index + 1]
                if (33...47).contains(next) || (58...64).contains(next)
                    || (91...96).contains(next) || (123...126).contains(next) {
                    edits.append(.init(bytes: index..<(index + 2),
                                       text: String(decoding: [next], as: UTF8.self)))
                    index += 2
                    continue
                }
            } else if byte == 38, index + 1 < bytes.count,
                      let semicolon = bytes[(index + 1)..<min(index + 34, bytes.count)].firstIndex(of: 59) {
                let range = index..<(semicolon + 1)
                if bytes[(index + 1)..<semicolon].allSatisfy({
                    $0 == 35 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                }) {
                    let reference = String(decoding: bytes[range], as: UTF8.self)
                    if let value = try? Entities.unescape(string: reference, strict: true),
                       value != reference {
                        edits.append(.init(bytes: range, text: value))
                        index = range.upperBound
                        continue
                    }
                }
            }
            index += 1
        }
        return Self(source, replacing: edits)
    }

    init(_ source: String, replacing replacements: [Replacement] = []) {
        guard !replacements.isEmpty else {
            self.source = source
            edits = []
            return
        }
        let bytes = Array(source.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var edits: [Edit] = []
        var cursor = 0
        for replacement in replacements {
            let range = replacement.bytes
            guard range.lowerBound >= cursor, range.upperBound <= bytes.count else { continue }
            result.append(contentsOf: bytes[cursor..<range.lowerBound])
            let start = result.count
            result.append(contentsOf: replacement.text.utf8)
            edits.append(Edit(original: range, rewritten: start..<result.count))
            cursor = range.upperBound
        }
        result.append(contentsOf: bytes[cursor...])
        self.source = String(decoding: result, as: UTF8.self)
        self.edits = edits
    }

    func originalBytes(for rewritten: Range<Int>) -> Range<Int>? {
        guard rewritten.lowerBound >= 0, rewritten.upperBound <= source.utf8.count else { return nil }
        let start = originalBoundary(rewritten.lowerBound, leading: true)
        guard !rewritten.isEmpty else { return start..<start }
        let end = originalBoundary(rewritten.upperBound, leading: false)
        return start..<end
    }

    private func originalBoundary(_ offset: Int, leading: Bool) -> Int {
        let upper = firstEdit(after: offset, includingSameStart: leading)
        guard upper > 0 else { return offset }
        let edit = edits[upper - 1]
        if offset < edit.rewritten.upperBound {
            return leading ? edit.original.lowerBound : edit.original.upperBound
        }
        return edit.original.upperBound + (offset - edit.rewritten.upperBound)
    }

    func segments(in range: Range<Int>) -> [Range<Int>] {
        let start = max(0, firstEdit(after: range.lowerBound, includingSameStart: true) - 1)
        var segments: [Range<Int>] = []
        var cursor = range.lowerBound
        for edit in edits[start...] {
            if edit.rewritten.lowerBound >= range.upperBound { break }
            for boundary in [edit.rewritten.lowerBound, edit.rewritten.upperBound] {
                guard boundary > cursor, boundary < range.upperBound else { continue }
                segments.append(cursor..<boundary)
                cursor = boundary
            }
        }
        segments.append(cursor..<range.upperBound)
        return segments
    }

    private func firstEdit(after offset: Int, includingSameStart: Bool) -> Int {
        var lower = 0
        var upper = edits.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let start = edits[middle].rewritten.lowerBound
            if start < offset || (includingSameStart && start == offset) { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
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

    private func byteOffset(_ location: Markdown.SourceLocation) -> Int? {
        let row = location.line - 1
        let column = location.column - 1
        guard row >= 0, row < lineStarts.count, column >= 0 else { return nil }
        let start = lineStarts[row]
        let end = row + 1 < lineStarts.count ? lineStarts[row + 1] : body.endIndex
        let bytes = body.utf8
        guard let boundary = bytes.index(start, offsetBy: column, limitedBy: end) else { return nil }
        return bytes.distance(from: bytes.startIndex, to: boundary)
    }

    func bytes(_ source: Markdown.SourceRange) -> Range<Int>? {
        guard let lower = byteOffset(source.lowerBound),
              let upper = byteOffset(source.upperBound),
              upper >= lower else { return nil }
        return lower..<upper
    }

    private func utf16Offset(_ byteOffset: Int) -> Int? {
        let bytes = body.utf8
        guard let boundary = bytes.index(bytes.startIndex, offsetBy: byteOffset,
                                         limitedBy: bytes.endIndex) else { return nil }
        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lineStarts[middle] <= boundary { lower = middle + 1 }
            else { upper = middle }
        }
        let row = lower - 1
        guard let prefix = String(bytes: bytes[lineStarts[row]..<boundary], encoding: .utf8)
        else { return nil }
        return headerUTF16 + lineUTF16Starts[row] + prefix.utf16.count
    }

    func utf16Range(_ bytes: Range<Int>) -> NSRange? {
        guard let lower = utf16Offset(bytes.lowerBound),
              let upper = utf16Offset(bytes.upperBound),
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

nonisolated enum MarkdownAlert: String, Sendable {
    case note = "[!NOTE]"
    case tip = "[!TIP]"
    case important = "[!IMPORTANT]"
    case warning = "[!WARNING]"
    case caution = "[!CAUTION]"
}

nonisolated indirect enum MarkdownNativeBlock: Sendable {
    case heading(Int, [MarkdownInline])
    case paragraph([MarkdownInline])
    case image(String, String)
    case quote([Self])
    case alert(MarkdownAlert, [Self])
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
    case text(String, source: NSRange? = nil)
    case code(String, source: NSRange? = nil)
    case emphasis([Self])
    case strong([Self])
    case strike([Self])
    case link(String, [Self])
    case image(String, String)
    case math(String, display: Bool)
    case html(String)
    case lineBreak
}
