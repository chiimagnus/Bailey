import Foundation

/// Copies the visible projection, never source delimiters, hidden front matter or scripts.
/// The source intervals come from the original swift-markdown projection; no text is laid out twice.
nonisolated enum MarkdownSelectionText {
    private struct Piece {
        let text: String
        let source: NSRange?
    }

    static func fullRange(in document: MarkdownDocument,
                          collapsed: Set<MarkdownDocument.HeadingIdentity> = []) -> NSRange? {
        var lower = Int.max
        var upper = 0
        for index in document.visibleBlockIndices(collapsed: collapsed) {
            guard let range = document.blocks[index].sourceRange else { continue }
            lower = min(lower, range.location)
            upper = max(upper, NSMaxRange(range))
        }
        guard lower != Int.max else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    static func copy(_ range: NSRange, from document: MarkdownDocument,
                     details: [String: Bool] = [:],
                     collapsed: Set<MarkdownDocument.HeadingIdentity> = []) -> String {
        guard range.length > 0 else { return "" }
        var result: [String] = []
        for index in document.visibleBlockIndices(collapsed: collapsed) {
            let block = document.blocks[index]
            guard let source = block.sourceRange,
                  NSIntersectionRange(range, source).length > 0 else { continue }
            let pieces = visible(block.content, path: [index], details: details)
            let text = select(pieces, from: range, inside: source)
            if !text.isEmpty { result.append(text) }
        }
        return result.joined(separator: "\n\n")
    }

    private static func select(_ pieces: [Piece], from selected: NSRange, inside block: NSRange) -> String {
        var nextLocations = [Int](repeating: NSMaxRange(block), count: pieces.count)
        var next = NSMaxRange(block)
        for index in pieces.indices.reversed() {
            nextLocations[index] = next
            if let source = pieces[index].source { next = source.location }
        }

        var result = ""
        var previous = block.location
        for (index, piece) in pieces.enumerated() {
            let position: NSRange
            if let source = piece.source {
                position = source
                previous = NSMaxRange(source)
            } else {
                position = NSRange(location: previous,
                                   length: max(0, nextLocations[index] - previous))
            }
            let intersection = NSIntersectionRange(selected, position)
            if intersection.length == 0 { continue }
            if let source = piece.source, source.length == piece.text.utf16.count {
                let visible = piece.text as NSString
                let offset = intersection.location - source.location
                let covered = NSRange(location: offset, length: intersection.length)
                let composed = visible.rangeOfComposedCharacterSequences(for: covered)
                result += visible.substring(with: composed)
            } else {
                result += piece.text
            }
        }
        return result
    }

    private static func separated(_ groups: [[Piece]], by separator: String) -> [Piece] {
        var output: [Piece] = []
        for group in groups {
            if !output.isEmpty { output.append(Piece(text: separator, source: nil)) }
            output.append(contentsOf: group)
        }
        return output
    }

    private static func visible(_ inline: [MarkdownInline]) -> [Piece] {
        let (tags, matched) = MarkdownInlineHTML.scan(inline)
        return inline.enumerated().flatMap { index, item -> [Piece] in
            if let tag = tags[index] {
                if tag.name == "br", !tag.closing {
                    return [Piece(text: "\n", source: nil)]
                }
                if matched.contains(index) { return [] }
            }
            switch item {
            case .text(let value, let source), .code(let value, let source):
                return [Piece(text: value, source: source)]
            case .strong(let children), .emphasis(let children), .strike(let children),
                 .link(_, let children):
                return visible(children)
            case .image(_, let alt):
                return [Piece(text: alt, source: nil)]
            case .math(let latex, _, let source):
                return [Piece(text: latex, source: source)]
            case .html(let raw):
                return [Piece(text: raw, source: nil)]
            case .lineBreak:
                return [Piece(text: "\n", source: nil)]
            }
        }
    }

    private static func visible(_ block: MarkdownNativeBlock, path: [Int],
                                details: [String: Bool], depth: Int = 0) -> [Piece] {
        switch block {
        case .paragraph(let inline), .heading(_, let inline):
            return visible(inline)
        case .image(_, let alt):
            return [Piece(text: alt, source: nil)]
        case .quote(let blocks), .alert(_, let blocks):
            return separated(blocks.enumerated().map { index, child in
                visible(child, path: path + [index], details: details, depth: depth)
            }, by: "\n")
        case .list(let ordered, let start, let items):
            return separated(items.enumerated().map { index, item in
                let marker: String
                if let checked = item.checked {
                    marker = checked ? "- [x] " : "- [ ] "
                } else {
                    marker = ordered ? "\(start + index). " : "- "
                }
                let children = separated(item.blocks.enumerated().map { blockIndex, child in
                    let nextDepth: Int
                    if case .list = child { nextDepth = depth + 1 }
                    else { nextDepth = depth }
                    return visible(child, path: path + [index, blockIndex],
                                   details: details, depth: nextDepth)
                }, by: "\n")
                return [Piece(text: String(repeating: "  ", count: depth) + marker, source: nil)]
                    + children
            }, by: "\n")
        case .table(let head, let rows, _):
            let allRows = [head] + rows
            return separated(allRows.map { row in
                separated(row.map(visible), by: "\t")
            }, by: "\n")
        case .code(let text, _, let runs):
            guard !runs.isEmpty else { return [Piece(text: text, source: nil)] }
            let value = text as NSString
            var pieces: [Piece] = []
            var cursor = 0
            for run in runs {
                guard run.displayed.location >= cursor,
                      NSMaxRange(run.displayed) <= value.length else { continue }
                if run.displayed.location > cursor {
                    pieces.append(Piece(text: value.substring(with: NSRange(
                        location: cursor, length: run.displayed.location - cursor
                    )), source: nil))
                }
                pieces.append(Piece(text: value.substring(with: run.displayed), source: run.original))
                cursor = NSMaxRange(run.displayed)
            }
            if cursor < value.length {
                pieces.append(Piece(text: value.substring(from: cursor), source: nil))
            }
            return pieces
        case .rawHTML(let text):
            return [Piece(text: text, source: nil)]
        case .mermaid:
            return [Piece(text: "Mermaid diagram", source: nil)]
        case .mathBlock(let latex):
            return [Piece(text: latex, source: nil)]
        case .html(let nodes):
            return visible(nodes, grouped: true, path: path, details: details)
        case .rule:
            return [Piece(text: "—", source: nil)]
        }
    }

    private static func visible(_ nodes: [MarkdownHTML], grouped: Bool,
                                path: [Int], details: [String: Bool]) -> [Piece] {
        let layoutNodes = grouped ? MarkdownHTML.groupedForPresentation(nodes) : nodes
        return layoutNodes.enumerated().flatMap { index, item -> [Piece] in
            let childPath = path + [index]
            switch item {
            case .text(let text):
                return [Piece(text: text, source: nil)]
            case .quote(let children):
                return visible(children, grouped: true, path: childPath, details: details)
            case .paragraph(let children), .heading(_, let children),
                 .emphasis(let children, _), .link(_, let children):
                return visible(children, grouped: !MarkdownHTML.isInline(children),
                               path: childPath, details: details)
            case .details(let label, let children, let open):
                guard details[MarkdownHTML.detailKey(childPath)] ?? open else {
                    return [Piece(text: label, source: nil)]
                }
                return [Piece(text: label + "\n", source: nil)]
                    + visible(children, grouped: true, path: childPath, details: details)
            case .lineBreak:
                return [Piece(text: "\n", source: nil)]
            case .image(_, let alt, _, _), .svg(_, let alt):
                return [Piece(text: alt, source: nil)]
            case .table(let rows):
                return separated(rows.enumerated().map { rowIndex, row in
                    separated(row.cells.enumerated().map { column, cell in
                        visible(cell.nodes, grouped: !MarkdownHTML.isInline(cell.nodes),
                                path: childPath + [rowIndex, column], details: details)
                    }, by: "\t")
                }, by: "\n")
            case .media(_, let video):
                return [Piece(text: video ? "Video" : "Audio", source: nil)]
            case .list(let ordered, let start, let items):
                return separated(items.enumerated().map { itemIndex, children in
                    [Piece(text: ordered ? "\(start + itemIndex). " : "- ", source: nil)]
                        + visible(children, grouped: !MarkdownHTML.isInline(children),
                                  path: childPath + [itemIndex], details: details)
                }, by: "\n")
            case .horizontalRule:
                return [Piece(text: "—", source: nil)]
            }
        }
    }
}
