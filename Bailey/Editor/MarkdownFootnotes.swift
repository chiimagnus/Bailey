import Foundation

nonisolated struct MarkdownFootnotes {
    struct Note {
        let name: String
        let number: Int
        let text: String

        var anchor: String { "bailey-note:\(name)" }
    }

    let definitionLines: Set<Int>
    let referencedNotes: [Note]
    private let byName: [String: Note]
    private let lines: [Substring]

    init(lines: [Substring], markup: AttributedString) {
        self.lines = lines
        var excluded = IndexSet()
        for run in markup.runs {
            guard let position = run.markdownSourcePosition,
                  position.startLine > 0, position.endLine >= position.startLine else { continue }
            if run.presentationIntent == nil || run.presentationIntent?.components.contains(where: {
                if case .codeBlock = $0.kind { return true }
                return false
            }) == true {
                excluded.insert(integersIn: position.startLine...position.endLine)
            }
        }
        var indexed: [String: Note] = [:]
        var definitionLines: Set<Int> = []
        for (index, line) in lines.enumerated() where !excluded.contains(index + 1) {
            guard let match = line.firstMatch(of: /^ {0,3}\[\^([A-Za-z0-9_-]+)\]:[ \t]*(.*)$/) else { continue }
            let name = match.1.lowercased()
            guard indexed[name] == nil else { continue }
            var body = String(match.2)
            for next in lines.dropFirst(index + 1) {
                guard next.hasPrefix("    ") || next.hasPrefix("\t") else { break }
                body += "\n" + next.trimmingCharacters(in: .whitespaces)
            }
            indexed[name] = Note(name: name, number: indexed.count + 1, text: body)
            definitionLines.insert(index + 1)
        }
        var seen: Set<String> = []
        var referenced: [Note] = []
        let linked = Self.link(in: markup, lines: lines, byName: indexed)
        for run in linked.runs {
            guard let sourceLine = run.markdownSourcePosition?.startLine,
                  !definitionLines.contains(sourceLine),
                  let fragment = run.link?.fragment, fragment.hasPrefix("bailey-note:"),
                  let note = indexed[String(fragment.dropFirst("bailey-note:".count))],
                  seen.insert(note.name).inserted else { continue }
            referenced.append(Note(name: note.name, number: referenced.count + 1,
                                   text: note.text))
        }
        self.definitionLines = definitionLines
        referencedNotes = referenced
        byName = Dictionary(uniqueKeysWithValues: referenced.map { ($0.name, $0) })
    }

    func link(in markup: AttributedString) -> AttributedString {
        Self.link(in: markup, lines: lines, byName: byName)
    }

    private static func link(in markup: AttributedString, lines: [Substring],
                             byName: [String: Note]) -> AttributedString {
        guard !byName.isEmpty, markup.characters.contains("^") else { return markup }
        var result = AttributedString()
        for run in markup.runs {
            let value = markup[run.range]
            let text = String(value.characters)
            guard run.inlinePresentationIntent?.contains(.code) != true,
                  run.presentationIntent?.components.contains(where: {
                      if case .codeBlock = $0.kind { return true }
                      return false
                  }) != true,
                  let position = run.markdownSourcePosition, lines.indices.contains(position.startLine - 1),
                  position.startColumn > 0 else { result.append(value); continue }
            let original = lines[position.startLine - 1].utf8
            if run.link != nil, text.hasPrefix("^"), let note = byName[String(text.dropFirst()).lowercased()],
               position.startColumn >= 2 {
                let link = original.dropFirst(position.startColumn - 2)
                let raw = String(decoding: link.prefix(text.utf8.count + 3), as: UTF8.self)
                if raw.hasPrefix("[\(text)]"), !raw.hasSuffix("("), !raw.hasSuffix("[") {
                    result.append(reference(note, attributes: run.attributes))
                    continue
                }
            }
            guard run.link == nil, text.contains("[^"),
                  String(decoding: original.dropFirst(position.startColumn - 1).prefix(text.utf8.count),
                         as: UTF8.self) == text else { result.append(value); continue }
            var cursor = text.startIndex
            for match in text.matches(of: /\[\^([A-Za-z0-9_-]+)\]/) {
                guard let note = byName[match.1.lowercased()] else { continue }
                result.append(AttributedString(String(text[cursor..<match.range.lowerBound]), attributes: run.attributes))
                result.append(reference(note, attributes: run.attributes))
                cursor = match.range.upperBound
            }
            result.append(AttributedString(String(text[cursor...]), attributes: run.attributes))
        }
        return result
    }

    private static func reference(_ note: Note, attributes: AttributeContainer) -> AttributedString {
        var linked = attributes
        linked.link = URL(string: "#" + note.anchor)
        return AttributedString("[\(note.number)]", attributes: linked)
    }
}
