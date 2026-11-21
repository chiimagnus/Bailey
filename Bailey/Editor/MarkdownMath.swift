import Foundation
import Markdown

/// A narrowly scoped math extension to swift-markdown's AST.
/// cmark-gfm owns all Markdown syntax; only ordinary Text ranges may contain inline math.
nonisolated enum MarkdownMath {
    struct Protected {
        struct Expression {
            let latex: String
            let display: Bool
        }

        let source: String
        let expressions: [String: Expression]

        func inlines(_ text: String) -> [MarkdownInline] {
            guard !expressions.isEmpty,
                  let first = text.range(of: "\u{E000}BAILEY_MATH_")
            else { return [.text(text)] }

            var result: [MarkdownInline] = []
            var cursor = text.startIndex
            var searching: String.Index = first.lowerBound
            while searching < text.endIndex,
                  let open = text.range(of: "\u{E000}BAILEY_MATH_", range: searching..<text.endIndex),
                  let close = text[open.upperBound...].firstIndex(of: "\u{E001}") {
                let end = text.index(after: close)
                let token = String(text[open.lowerBound..<end])
                guard let expression = expressions[token] else {
                    searching = end
                    continue
                }
                if cursor < open.lowerBound {
                    result.append(.text(String(text[cursor..<open.lowerBound])))
                }
                result.append(.math(expression.latex, display: expression.display))
                cursor = end
                searching = end
            }
            if cursor < text.endIndex {
                result.append(.text(String(text[cursor...])))
            }
            return result.isEmpty ? [.text(text)] : result
        }
    }

    /// Shield TeX punctuation before the final cmark pass. The first cmark AST
    /// only locates true prose; code, HTML, links, and image spans remain literal.
    /// Ordinary Markdown files without inline math still parse only once.
    static func protect(_ source: String, ast: Markdown.Document) -> Protected {
        guard source.contains("$"),
              !source.contains("\u{E000}BAILEY_MATH_") else {
            return Protected(source: source, expressions: [:])
        }

        let bytes = Array(source.utf8)
        var starts = [0]
        for index in bytes.indices {
            if bytes[index] == 10 || bytes[index] == 13
                && (index + 1 == bytes.count || bytes[index + 1] != 10) {
                starts.append(index + 1)
            }
        }

        func offset(_ location: Markdown.SourceLocation) -> Int? {
            let row = location.line - 1
            guard starts.indices.contains(row) else { return nil }
            let absolute = starts[row] + location.column - 1
            guard absolute >= starts[row], absolute <= bytes.count else { return nil }
            return absolute
        }

        func span(_ node: any Markdown.Markup) -> Range<Int>? {
            guard let range = node.range,
                  let start = offset(range.lowerBound),
                  let end = offset(range.upperBound),
                  start <= end else { return nil }
            return start..<end
        }

        var prose: [Range<Int>] = []
        var excluded: [Range<Int>] = []
        func collect(_ node: any Markdown.Markup) {
            if node is Markdown.CodeBlock || node is Markdown.InlineCode
                || node is Markdown.HTMLBlock || node is Markdown.InlineHTML
                || node is Markdown.Link || node is Markdown.Image {
                if let range = span(node) { excluded.append(range) }
                return
            }
            if node is Markdown.Paragraph || node is Markdown.Heading
                || node is Markdown.Table.Cell {
                if let range = span(node) { prose.append(range) }
            }
            for child in node.children { collect(child) }
        }
        collect(ast)
        prose.sort { $0.lowerBound < $1.lowerBound }
        excluded.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in excluded {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        func excludedAt(_ index: Int) -> Bool {
            var low = 0
            var high = merged.count
            while low < high {
                let middle = low + (high - low) / 2
                if merged[middle].upperBound <= index { low = middle + 1 }
                else { high = middle }
            }
            return low < merged.count && merged[low].lowerBound <= index
        }

        struct Replacement {
            let range: Range<Int>
            let token: String
            let latex: String
            let display: Bool
        }

        var replacements: [Replacement] = []
        for region in prose {
            var index = region.lowerBound
            while index < region.upperBound {
                guard bytes[index] == 36, !excludedAt(index) else {
                    index += 1
                    continue
                }
                var backslashes = 0
                while index > region.lowerBound + backslashes
                    && bytes[index - backslashes - 1] == 92 {
                    backslashes += 1
                }
                guard backslashes.isMultiple(of: 2) else { index += 1; continue }

                let double = index + 1 < region.upperBound && bytes[index + 1] == 36
                    && !excludedAt(index + 1)
                let size = double ? 2 : 1
                var close = index + size
                var found: Int?
                while close + size <= min(region.upperBound, index + (8 << 10)) {
                    if bytes[close] == 10 || bytes[close] == 13 { break }
                    // Never stretch an expression over code, HTML, or link nodes.
                    // Those regions belong to cmark and must retain their AST semantics.
                    if excludedAt(close) { break }
                    var closeSlashes = 0
                    while close > region.lowerBound + closeSlashes
                        && bytes[close - closeSlashes - 1] == 92 {
                        closeSlashes += 1
                    }
                    if bytes[close] == 36, closeSlashes.isMultiple(of: 2),
                       (size == 1 || close + 1 < region.upperBound
                        && bytes[close + 1] == 36 && !excludedAt(close + 1)) {
                        found = close
                        break
                    }
                    close += 1
                }
                guard let found else { index += size; continue }
                let expressionBytes = bytes[(index + size)..<found]
                guard let first = expressionBytes.first, let last = expressionBytes.last,
                      first != 32, first != 9, last != 32, last != 9,
                      !expressionBytes.isEmpty else {
                    // A rejected candidate has not consumed its closing delimiter:
                    // that dollar may open the next valid expression after currency.
                    index += size
                    continue
                }
                let latex = String(decoding: expressionBytes, as: UTF8.self)
                let token = "\u{E000}BAILEY_MATH_\(replacements.count)\u{E001}"
                replacements.append(Replacement(range: index..<(found + size), token: token,
                                                latex: latex, display: double))
                index = found + size
            }
        }
        guard !replacements.isEmpty else {
            return Protected(source: source, expressions: [:])
        }
        var rewritten: [UInt8] = []
        rewritten.reserveCapacity(bytes.count + replacements.count * 8)
        var expressions: [String: Protected.Expression] = [:]
        var cursor = 0
        for replacement in replacements {
            rewritten.append(contentsOf: bytes[cursor..<replacement.range.lowerBound])
            rewritten.append(contentsOf: replacement.token.utf8)
            expressions[replacement.token] = Protected.Expression(
                latex: replacement.latex, display: replacement.display)
            cursor = replacement.range.upperBound
        }
        rewritten.append(contentsOf: bytes[cursor...])
        return Protected(source: String(decoding: rewritten, as: UTF8.self),
                         expressions: expressions)
    }

    struct Source {
        private let lines: [String]

        init(_ markdown: String) {
            lines = markdown.contains("$")
                ? markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .map(String.init)
                : []
        }

        func raw(_ range: Markdown.SourceRange?) -> String? {
            guard let range, range.lowerBound.line == range.upperBound.line,
                  lines.indices.contains(range.lowerBound.line - 1) else { return nil }
            let bytes = Array(lines[range.lowerBound.line - 1].utf8)
            let start = range.lowerBound.column - 1
            let end = range.upperBound.column - 1
            guard start >= 0, end >= start, end <= bytes.count else { return nil }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        func display(_ paragraph: Markdown.Paragraph) -> String? {
            guard let range = paragraph.range,
                  range.lowerBound.line > 0,
                  range.upperBound.line >= range.lowerBound.line,
                  lines.indices.contains(range.lowerBound.line - 1),
                  lines.indices.contains(range.upperBound.line - 1)
            else { return nil }
            let first = range.lowerBound.line - 1
            let last = range.upperBound.line - 1
            let raw: String
            if first == last {
                guard let portion = self.raw(range) else { return nil }
                raw = portion
            } else {
                let firstBytes = Array(lines[first].utf8)
                let lastBytes = Array(lines[last].utf8)
                let start = range.lowerBound.column - 1
                let end = range.upperBound.column - 1
                guard start >= 0, start <= firstBytes.count,
                      end >= 0, end <= lastBytes.count else { return nil }
                let content = [String(decoding: firstBytes[start...], as: UTF8.self)]
                    + lines[(first + 1)..<last]
                    + [String(decoding: lastBytes[..<end], as: UTF8.self)]
                raw = content.joined(separator: "\n")
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"),
                  trimmed.utf8.count >= 5, trimmed.utf8.count <= 16 << 10 else { return nil }
            let inner = trimmed.dropFirst(2).dropLast(2)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !inner.isEmpty else { return nil }
            return inner
        }
    }
}
