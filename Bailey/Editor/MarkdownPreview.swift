import SwiftUI
import Textual

struct MarkdownPreview: View {
    let document: MarkdownDocument
    let revision: String
    let resource: MarkdownResource
    var openLink: (URL) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let warning = document.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(document.blocks.indices, id: \.self) { index in
                        let block = document.blocks[index]
                        Group {
                            switch block.content {
                            case .markdown(let markup):
                                StructuredText(revision, parser: PreparedMarkdown(markup: markup))
                                    .textual.structuredTextStyle(.gitHub)
                                    .textual.textSelection(.enabled)
                            case .html(let nodes):
                                MarkdownHTMLContent(nodes: nodes, resource: resource)
                            }
                        }
                        .id(block.anchor ?? "markdown-block:\(index)")
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .environment(\.openURL, OpenURLAction { url in
                if url.absoluteString.hasPrefix("#"), let fragment = url.fragment,
                   document.blocks.contains(where: { $0.anchor == fragment }) {
                    proxy.scrollTo(fragment, anchor: .top)
                } else {
                    openLink(url)
                }
                return .handled
            })
        }
        .textual.imageAttachmentLoader(MarkdownImageLoader(resource: resource))
        .textual.emojiAttachmentLoader(MarkdownImageLoader(resource: resource))
        .accessibilityIdentifier("markdown-preview")
    }
}

private struct PreparedMarkdown: MarkupParser {
    let markup: AttributedString

    func attributedString(for input: String) throws -> AttributedString { markup }
}

private struct MarkdownHTMLContent: View {
    let nodes: [MarkdownHTML]
    let resource: MarkdownResource

    var body: some View {
        ForEach(nodes.indices, id: \.self) { index in
            switch nodes[index] {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(verbatim: text).textSelection(.enabled)
                }
            case .image(let url, let alt):
                MarkdownHTMLImage(url: url, alt: alt, resource: resource)
            case .details(let label, let children):
                DisclosureGroup {
                    VStack(alignment: .leading) { MarkdownHTMLContent(nodes: children, resource: resource) }
                } label: {
                    Text(verbatim: label)
                }
            case .emphasis(let children, let tag):
                MarkdownHTMLContent(nodes: children, resource: resource)
                    .fontWeight(["b", "strong"].contains(tag) ? .bold : nil)
                    .italic(["em", "i"].contains(tag))
                    .strikethrough(["s", "del"].contains(tag))
                    .fontDesign(["code", "kbd"].contains(tag) ? .monospaced : nil)
            }
        }
    }
}

private struct MarkdownHTMLImage: View {
    let url: URL
    let alt: String
    let resource: MarkdownResource
    @State private var image: MarkdownImage?

    var body: some View {
        Group {
            if let image {
                image.body
                    .frame(maxWidth: image.image.map { CGFloat($0.width) }, alignment: .leading)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            let decoded = try? await resource.image(url)
            guard !Task.isCancelled else { return }
            image = MarkdownImage(image: decoded, alt: alt, url: url)
        }
    }
}
