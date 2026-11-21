import Foundation

/// Applies safe HTML inline semantics to Textual's existing Markdown source runs.
/// Markdown presentation intents and source positions stay on the same text buffer.
nonisolated enum MarkdownInlineHTML {
    private struct Tag {
        let name: String
        let closing: Bool
        let raw: String
    }

    private struct Element {
        let name: String
        let intent: InlinePresentationIntent
        let link: URL?
    }

    static func containsBlock(_ nodes: [MarkdownHTML]) -> Bool {
        nodes.contains { node in
            switch node {
            case .paragraph, .quote, .image, .svg, .table, .media, .details,
                 .heading, .list, .horizontalRule: return true
            case .emphasis(let children, _), .link(_, let children):
                return containsBlock(children)
            case .text, .lineBreak: return false
            }
        }
    }

    static func render(_ markup: AttributedString) -> AttributedString {
        let runs = Array(markup.runs)
        var tags: [Int: Tag] = [:]
        var opening: [(name: String, index: Int)] = []
        var paired: Set<Int> = []
        for (index, run) in runs.enumerated() {
            guard run.inlinePresentationIntent?.contains(.inlineHTML) == true,
                  let tag = tag(String(markup[run.range].characters)) else { continue }
            tags[index] = tag
            guard !["img", "br"].contains(tag.name) else { continue }
            if tag.closing {
                guard let last = opening.last, last.name == tag.name else { continue }
                paired.insert(last.index)
                paired.insert(index)
                opening.removeLast()
            } else if opening.count < 32 {
                opening.append((tag.name, index))
            }
        }

        var active: [Element] = []
        var output = AttributedString()
        for (index, run) in runs.enumerated() {
            let value = markup[run.range]
            if let tag = tags[index] {
                if tag.name == "br", !tag.closing {
                    var line = AttributedString("\n", attributes: run.attributes)
                    line.inlinePresentationIntent = [.lineBreak]
                    output.append(line)
                    continue
                }
                if tag.name == "img", !tag.closing,
                   let parsed = MarkdownHTML.parse(tag.raw),
                   case .image(let url, let alt, _, _) = parsed.first {
                    var attributes = run.attributes
                    attributes.inlinePresentationIntent = nil
                    attributes.imageURL = url
                    output.append(AttributedString(alt.isEmpty ? "Image" : alt, attributes: attributes))
                    continue
                }
                if paired.contains(index) {
                    if tag.closing {
                        active.removeLast()
                    } else {
                        active.append(element(for: tag))
                    }
                    continue
                }
            }
            var text = AttributedString(value)
            for element in active {
                if element.intent != [] {
                    text.inlinePresentationIntent = (text.inlinePresentationIntent ?? []).union(element.intent)
                }
                if text.link == nil, let link = element.link { text.link = link }
            }
            output.append(text)
        }
        return output
    }

    private static func element(for tag: Tag) -> Element {
        let intent: InlinePresentationIntent
        switch tag.name {
        case "b", "strong": intent = .stronglyEmphasized
        case "i", "em": intent = .emphasized
        case "s", "del": intent = .strikethrough
        case "code", "kbd": intent = .code
        default: intent = []
        }
        var link: URL?
        if tag.name == "a", let parsed = MarkdownHTML.parse(tag.raw + "link</a>"),
           case .link(let destination, _) = parsed.first {
            link = destination
        }
        return Element(name: tag.name, intent: intent, link: link)
    }

    private static func tag(_ source: String) -> Tag? {
        guard source.first == "<", source.last == ">" else { return nil }
        var content = String(source.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        let closing = content.hasPrefix("/")
        if closing { content.removeFirst() }
        let name = String(content.prefix { $0.isASCII && $0.isLetter }).lowercased()
        guard ["a", "span", "b", "strong", "i", "em", "s", "del", "code", "kbd", "img", "br"].contains(name) else {
            return nil
        }
        let remainder = String(content.dropFirst(name.count))
        guard remainder.isEmpty || remainder.first?.isWhitespace == true || remainder.first == "/" else { return nil }
        if closing && !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return Tag(name: name, closing: closing, raw: source)
    }
}
