import Foundation
import Markdown

/// cmark-gfm has no footnote nodes. Locate only references in parsed source ranges,
/// leaving escapes, code and links to the standard Markdown parser.
nonisolated struct MarkdownFootnotes {
    struct Note {
        let name: String
        let source: String
        let line: Int
        let endLine: Int
    }

    private struct Reference {
        let name: String
        let line: Int
        let start: Int
        let end: Int
    }

    private let notes: [String: Note]
    private(set) var referenced: [String] = []
    var source: String

    init(source original: String, document: Markdown.Document) {
        source = original
        guard original.contains("[^") else {
            notes = [:]
            return
        }

        var ignoredLines = Set<Int>()
        func excludeCode(_ node: any Markdown.Markup) {
            if node is Markdown.CodeBlock || node is Markdown.HTMLBlock,
               let range = node.range {
                ignoredLines.formUnion(range.lowerBound.line...range.upperBound.line)
            }
            for child in node.children { excludeCode(child) }
        }
        excludeCode(document)

        let rawLines = original.split(omittingEmptySubsequences: false, whereSeparator: \.isMarkdownLineEnding)
            .map(String.init)
        var lines = rawLines
        var definitions: [String: Note] = [:]
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            guard !ignoredLines.contains(index + 1),
                  let match = lines[index].firstMatch(of: /^ {0,3}\[\^([A-Za-z0-9_-]+)\]:[ \t]*(.*)$/)
            else { continue }
            let name = String(match.1).lowercased()
            guard definitions[name] == nil else { continue }
            var body = String(match.2)
            let line = index + 1
            lines[index] = ""
            while index + 1 < lines.count, !ignoredLines.contains(index + 2),
                  (lines[index + 1].hasPrefix("    ") || lines[index + 1].hasPrefix("\t")) {
                index += 1
                body += "\n" + lines[index].trimmingCharacters(in: .whitespaces)
                lines[index] = ""
            }
            definitions[name] = Note(name: name, source: body, line: line, endLine: index + 1)
        }
        notes = definitions
        guard !definitions.isEmpty else { return }

        func rawText(_ range: Markdown.SourceRange) -> String? {
            guard range.lowerBound.line == range.upperBound.line,
                  lines.indices.contains(range.lowerBound.line - 1) else { return nil }
            let bytes = Array(rawLines[range.lowerBound.line - 1].utf8)
            let start = range.lowerBound.column - 1
            let end = range.upperBound.column - 1
            guard start >= 0, end >= start, end <= bytes.count else { return nil }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        var found: [Reference] = []
        func record(_ raw: String, at range: Markdown.SourceRange) {
            guard range.lowerBound.line == range.upperBound.line else { return }
            let bytes = Array(raw.utf8)
            for match in raw.matches(of: /\[\^([A-Za-z0-9_-]+)\]/) {
                let name = String(match.1).lowercased()
                guard definitions[name] != nil else { continue }
                let start = raw.utf8.distance(from: raw.startIndex, to: match.range.lowerBound)
                let end = raw.utf8.distance(from: raw.startIndex, to: match.range.upperBound)
                var escapes = 0
                while start > escapes, bytes[start - escapes - 1] == 92 { escapes += 1 }
                guard escapes.isMultiple(of: 2) else { continue }
                found.append(Reference(name: name, line: range.lowerBound.line - 1,
                                       start: range.lowerBound.column - 1 + start,
                                       end: range.lowerBound.column - 1 + end))
            }
        }

        func visit(_ node: any Markdown.Markup) {
            if node is Markdown.CodeBlock || node is Markdown.HTMLBlock
                || node is Markdown.InlineCode || node is Markdown.Image { return }
            if let link = node as? Markdown.Link {
                // Reference-like links created by cmark from [^name]: definitions.
                if let range = link.range, let raw = rawText(range),
                   raw.wholeMatch(of: /\[\^([A-Za-z0-9_-]+)\]/) != nil {
                    record(raw, at: range)
                }
                return
            }
            if let text = node as? Markdown.Text {
                if text.string.contains("[^"), let range = node.range,
                   let raw = rawText(range) {
                    record(raw, at: range)
                }
                return
            }
            for child in node.children { visit(child) }
        }
        visit(document)

        found.sort { $0.line == $1.line ? $0.start < $1.start : $0.line < $1.line }
        var numbers: [String: Int] = [:]
        for item in found {
            if numbers[item.name] == nil {
                referenced.append(item.name)
                numbers[item.name] = referenced.count
            }
        }
        for item in found.reversed() {
            guard let number = numbers[item.name] else { continue }
            let bytes = Array(lines[item.line].utf8)
            guard item.start >= 0, item.end <= bytes.count, item.start <= item.end else { continue }
            let target = "[\(number)](#bailey-note:\(item.name))"
            lines[item.line] = String(decoding:
                Array(bytes[..<item.start]) + Array(target.utf8) + Array(bytes[item.end...]),
                as: UTF8.self)
        }
        source = lines.joined(separator: "\n")
    }

    var definitions: [(number: Int, name: String, text: String, line: Int, endLine: Int)] {
        referenced.enumerated().compactMap { index, name in
            guard let note = notes[name] else { return nil }
            return (index + 1, name, note.source, note.line, note.endLine)
        }
    }
}
