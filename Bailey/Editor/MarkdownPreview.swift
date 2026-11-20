import SwiftUI
import Textual

struct MarkdownFilePreview: View {
    let file: FileTab
    let directory: String?
    let onOpenLink: (URL) -> Void

    @State private var parsed: (document: MarkdownDocument, request: String, target: String)?
    @State private var failed = false

    var body: some View {
        let request = file.markdownRequestID
        let target = file.markdownResourceID
        Group {
            if let parsed, parsed.target == target {
                MarkdownPreview(
                    document: parsed.document, revision: parsed.request,
                    resource: file.markdownResource(in: directory),
                    position: Binding(get: { file.markdownScrollPosition },
                                      set: { file.markdownScrollPosition = $0 }),
                    openLink: onOpenLink
                )
                .id(target + (directory ?? ""))
            } else if failed {
                ContentUnavailableView("Could not render Markdown.", systemImage: "doc.text")
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: request) { [weak file] in
            failed = false
            do {
                if parsed?.target == target { try await Task.sleep(for: .milliseconds(150)) }
                guard let source = file?.text else { return }
                let document = try await MarkdownDocument.parse(source)
                guard !Task.isCancelled, request == file?.markdownRequestID else { return }
                parsed = (document, request, target)
            } catch {
                guard !Task.isCancelled, request == file?.markdownRequestID else { return }
                parsed = nil
                failed = true
            }
        }
    }
}

struct MarkdownMetadataView: View {
    let file: FileTab
    @State private var metadata: (properties: [MarkdownDocument.Property], warning: String?)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Front Matter", tableName: "Editor").font(.headline)
                if let metadata {
                    if let warning = metadata.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                    } else if metadata.properties.isEmpty {
                        Text("No YAML metadata.", tableName: "Editor").foregroundStyle(.secondary)
                    }
                    ForEach(Array(metadata.properties.enumerated()), id: \.offset) { _, property in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: property.name).fontWeight(.medium)
                            Text(verbatim: property.value.isEmpty ? "—" : property.value)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding()
        }
        .frame(width: 300, height: 220)
        .task(id: file.markdownRequestID) {
            let request = file.markdownRequestID
            let result = await MarkdownDocument.metadata(file.text)
            guard !Task.isCancelled, request == file.markdownRequestID else { return }
            metadata = result
        }
    }
}

struct MarkdownPreview: View {
    let document: MarkdownDocument
    let revision: String
    let resource: MarkdownResource
    @Binding var position: Int?
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
                                    .frame(minHeight: 12, alignment: .topLeading)
                            case .html(let nodes):
                                MarkdownHTMLContent(nodes: nodes, resource: resource)
                            }
                        }
                        .id(index)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: 820, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollPosition(id: $position, anchor: .top)
            .environment(\.openURL, OpenURLAction { url in
                if url.absoluteString.hasPrefix("#"), let fragment = url.fragment,
                   let index = document.blocks.firstIndex(where: { $0.anchor == fragment }) {
                    proxy.scrollTo(index, anchor: .top)
                } else {
                    openLink(url)
                }
                return .handled
            })
        }
        .textual.imageAttachmentLoader(MarkdownImageLoader(resource: resource))
        .textual.emojiAttachmentLoader(MarkdownImageLoader(resource: resource))
        .accessibilityIdentifier("bailey.markdown.preview")
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
