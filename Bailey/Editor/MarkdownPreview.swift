import SwiftUI
import Textual
@_spi(Textual) import SwiftUIMath

struct MarkdownFilePreview: View {
    let file: FileTab
    let directory: String?
    let assetRefresh: UInt
    let onOpenLink: (URL) async -> Bool

    @State private var parsed: (document: MarkdownDocument, request: String, target: String)?
    @State private var failed = false

    var body: some View {
        let request = file.markdownRequestID
        let target = file.markdownResourceID
        Group {
            if let parsed, parsed.target == target {
                MarkdownPreview(
                    document: parsed.document, revision: parsed.request,
                    resource: file.markdownResource(in: directory), assetRefresh: assetRefresh,
                    position: Binding(get: { file.markdownScrollPosition },
                                      set: { file.markdownScrollPosition = $0 }),
                    openLink: onOpenLink
                )
                .id("\(target)-\(directory ?? "")")
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
    let assetRefresh: UInt
    @Binding var position: Int?
    var openLink: (URL) async -> Bool = { _ in false }
    @State private var linkToOpen: URL?
    @State private var failedLink = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let warning = document.warning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                        if failedLink {
                            Label("Could not open this link.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(document.blocks.indices, id: \.self) { index in
                            let block = document.blocks[index]
                            let isFootnote = block.anchor?.hasPrefix("bailey-note:") == true
                            Group {
                                if isFootnote && (index == 0
                                    || document.blocks[index - 1].anchor?.hasPrefix("bailey-note:") != true) {
                                    Divider()
                                        .overlay(MarkdownGitHubColors.border(dark: colorScheme == .dark))
                                }
                                switch block.content {
                                case .markdown(let markup):
                                    StructuredText(revision, parser: PreparedMarkdown(markup: markup))
                                        .textual.headingStyle(MarkdownGitHubHeadingStyle())
                                        .textual.inlineStyle(MarkdownGitHubColors.inlineStyle)
                                        .textual.tableStyle(MarkdownGitHubTableStyle())
                                        .textual.structuredTextStyle(.gitHub)
                                        .font(.system(size: isFootnote ? 12 : 16))
                                        .foregroundStyle(isFootnote
                                            ? MarkdownGitHubColors.secondary(dark: colorScheme == .dark)
                                            : MarkdownGitHubColors.text(dark: colorScheme == .dark))
                                        .textual.textSelection(.enabled)
                                        .frame(minHeight: 12, alignment: .topLeading)
                                        // Textual retains old resolved images when attachments disappear.
                                        // Plain text blocks need no re-mount on every edit or window activation.
                                        .id(markup.runs.contains {
                                            $0.imageURL != nil || $0.textual.emojiURL != nil
                                        } ? "\(revision)-\(assetRefresh)" : "text")
                                case .html(let nodes):
                                    MarkdownHTMLContent(nodes: nodes, resource: resource,
                                                        assetRefresh: assetRefresh)
                                case .mermaid(let source, let line):
                                    MarkdownMermaidView(source: source, line: line).id(source)
                                }
                            }
                            .id(index)
                        }
                    }
                    .scrollTargetLayout()
                    .font(.system(size: 16))
                    .foregroundStyle(MarkdownGitHubColors.text(dark: colorScheme == .dark))
                    .tint(MarkdownGitHubColors.link(dark: colorScheme == .dark))
                    // GitHub markdown-body: 980 px including padding, 45 px / 15 px below 768.
                    .frame(maxWidth: 890, alignment: .leading)
                    .padding(geometry.size.width < 768 ? 15 : 45)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollPosition(id: $position, anchor: .top)
                .environment(\.openURL, OpenURLAction { url in
                    if url.absoluteString.hasPrefix("#"), let fragment = url.fragment,
                       let index = document.blocks.firstIndex(where: { $0.anchor == fragment }) {
                        proxy.scrollTo(index, anchor: .top)
                    } else {
                        linkToOpen = url
                    }
                    return .handled
                })
            }
        }
        .background(MarkdownGitHubColors.background(dark: colorScheme == .dark))
        .textual.imageAttachmentLoader(MarkdownImageLoader(resource: resource))
        .textual.emojiAttachmentLoader(MarkdownImageLoader(resource: resource))
        .accessibilityIdentifier("bailey.markdown.preview")
        .task(id: linkToOpen) {
            guard let linkToOpen else { return }
            let opened = await openLink(linkToOpen)
            guard !Task.isCancelled else { return }
            failedLink = !opened
            self.linkToOpen = nil
        }
    }
}

private enum MarkdownGitHubColors {
    static let inlineStyle = InlineStyle.gitHub
        .link(.foregroundColor(DynamicColor(
            light: Color(red: 9 / 255, green: 105 / 255, blue: 218 / 255),
            dark: Color(red: 68 / 255, green: 147 / 255, blue: 248 / 255)
        )))
        .code(.monospaced, .fontScale(0.85), .backgroundColor(DynamicColor(
            light: Color(red: 129 / 255, green: 139 / 255, blue: 152 / 255).opacity(31 / 255),
            dark: Color(red: 101 / 255, green: 108 / 255, blue: 118 / 255).opacity(51 / 255)
        )))

    static func background(dark: Bool) -> Color {
        dark ? Color(red: 13 / 255, green: 17 / 255, blue: 23 / 255) : .white
    }

    static func text(dark: Bool) -> Color {
        dark ? Color(red: 240 / 255, green: 246 / 255, blue: 252 / 255)
             : Color(red: 31 / 255, green: 35 / 255, blue: 40 / 255)
    }

    static func link(dark: Bool) -> Color {
        dark ? Color(red: 68 / 255, green: 147 / 255, blue: 248 / 255)
             : Color(red: 9 / 255, green: 105 / 255, blue: 218 / 255)
    }

    static func muted(dark: Bool) -> Color {
        dark ? Color(red: 21 / 255, green: 27 / 255, blue: 35 / 255)
             : Color(red: 246 / 255, green: 248 / 255, blue: 250 / 255)
    }

    static func secondary(dark: Bool) -> Color {
        dark ? Color(red: 145 / 255, green: 152 / 255, blue: 161 / 255)
             : Color(red: 89 / 255, green: 99 / 255, blue: 110 / 255)
    }

    static func border(dark: Bool) -> Color {
        dark ? Color(red: 61 / 255, green: 68 / 255, blue: 77 / 255)
             : Color(red: 209 / 255, green: 217 / 255, blue: 224 / 255)
    }
}

private struct MarkdownGitHubHeadingStyle: StructuredText.HeadingStyle {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if configuration.headingLevel == 6 {
            configuration.label
                .textual.fontScale(0.85)
                .textual.lineSpacing(.fontScaled(0.125))
                .textual.blockSpacing(.init(top: 24, bottom: 16))
                .fontWeight(.semibold)
                .foregroundStyle(MarkdownGitHubColors.secondary(dark: colorScheme == .dark))
        } else {
            StructuredText.GitHubHeadingStyle.gitHub.makeBody(configuration: configuration)
        }
    }
}

private struct MarkdownGitHubTableStyle: StructuredText.TableStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let border = MarkdownGitHubColors.border(dark: colorScheme == .dark)
        let muted = MarkdownGitHubColors.muted(dark: colorScheme == .dark)
        configuration.label
            .textual.tableCellSpacing(horizontal: 0, vertical: 0)
            .textual.blockSpacing(.init(top: 0, bottom: 16))
            .textual.tableBackground { layout in
                Canvas { context, _ in
                    for row in layout.rowIndices.dropFirst() where row.isMultiple(of: 2) {
                        context.fill(Path(layout.rowBounds(row)), with: .color(muted))
                    }
                }
            }
            .textual.tableOverlay { layout in
                Canvas { context, _ in
                    for column in layout.columnIndices.dropLast() {
                        let bounds = layout.columnBounds(column)
                        context.fill(Path(CGRect(x: bounds.maxX - 0.5, y: layout.bounds.minY,
                                                 width: 1, height: layout.bounds.height)), with: .color(border))
                    }
                    for row in layout.rowIndices.dropLast() {
                        let bounds = layout.rowBounds(row)
                        context.fill(Path(CGRect(x: layout.bounds.minX, y: bounds.maxY - 0.5,
                                                 width: layout.bounds.width, height: 1)), with: .color(border))
                    }
                }
            }
            .border(border, width: 1)
    }
}

struct PreparedMarkdown: MarkupParser {
    let markup: AttributedString

    func attributedString(for input: String) throws -> AttributedString {
        guard markup.characters.contains("$") else { return markup }
        let math = AttributedStringMarkdownParser.inlineMarkdown(syntaxExtensions: [.math])
        var result = AttributedString()
        for run in markup.runs {
            let original = markup[run.range]
            let text = String(original.characters)
            guard text.utf8.count <= 4096, text.contains("$"),
                  run.inlinePresentationIntent?.contains(.code) != true, run.link == nil, run.imageURL == nil,
                  run.presentationIntent?.components.contains(where: {
                      if case .codeBlock = $0.kind { return true }
                      return false
                  }) != true,
                  let expanded = try? math.attributedString(for: text),
                  expanded.runs.contains(where: { $0.textual.attachment != nil }) else {
                result.append(original)
                continue
            }
            for part in expanded.runs {
                var attributes = run.attributes
                if let attachment = part.textual.attachment {
                    let notation = attachment.description
                    let display = notation.hasPrefix("$$")
                    let markers = display ? 2 : 1
                    let latex = String(notation.dropFirst(markers).dropLast(markers))
                    let bounds = Math.typographicBounds(
                        for: latex, fitting: .unspecified,
                        font: .init(name: .latinModern, size: 16), style: display ? .display : .text
                    )
                    if bounds.size.width > 0 {
                        attributes.textual.attachment = attachment
                        result.append(AttributedString("\u{FFFC}", attributes: attributes))
                    } else {
                        result.append(AttributedString(notation, attributes: attributes))
                    }
                } else {
                    result.append(AttributedString(String(expanded[part.range].characters), attributes: attributes))
                }
            }
        }
        return result
    }
}

private struct MarkdownHTMLContent: View {
    let nodes: [MarkdownHTML]
    let resource: MarkdownResource
    let assetRefresh: UInt
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let layoutNodes = Self.groupInline(nodes)
        ForEach(layoutNodes.indices, id: \.self) { index in
            switch layoutNodes[index] {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(verbatim: text).textSelection(.enabled)
                }
            case .paragraph(let children):
                if Self.isInline(children) {
                    Self.inlineText(children).textSelection(.enabled)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        MarkdownHTMLContent(nodes: children, resource: resource,
                                            assetRefresh: assetRefresh)
                    }
                }
            case .quote(let children):
                HStack(alignment: .top, spacing: 0) {
                    MarkdownGitHubColors.border(dark: colorScheme == .dark).frame(width: 4)
                    MarkdownHTMLContent(nodes: children, resource: resource,
                                        assetRefresh: assetRefresh)
                        .foregroundStyle(MarkdownGitHubColors.secondary(dark: colorScheme == .dark))
                        .padding(.leading, 16)
                }
                .fixedSize(horizontal: false, vertical: true)
            case .lineBreak:
                Text(verbatim: "\n")
            case .image(let url, let alt, let width, let height):
                MarkdownHTMLImage(source: .file(url), alt: alt, resource: resource,
                                  width: width, height: height, assetRefresh: assetRefresh)
            case .svg(let source, let alt):
                MarkdownHTMLImage(source: .svg(source), alt: alt, resource: resource)
            case .table(let rows):
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(rows.indices, id: \.self) { index in
                            GridRow {
                                ForEach(rows[index].cells.indices, id: \.self) { column in
                                    let cell = rows[index].cells[column]
                                    Group {
                                        if Self.isInline(cell.nodes) {
                                            Self.inlineText(cell.nodes)
                                        } else {
                                            MarkdownHTMLContent(nodes: cell.nodes, resource: resource,
                                                                assetRefresh: assetRefresh)
                                        }
                                    }
                                    .fontWeight(cell.isHeader ? .semibold : .regular)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 6)
                                    .overlay(alignment: .trailing) {
                                        MarkdownGitHubColors.border(dark: colorScheme == .dark)
                                            .frame(width: 1)
                                    }
                                }
                            }
                            .background(rows[index].shaded
                                ? MarkdownGitHubColors.muted(dark: colorScheme == .dark)
                                : MarkdownGitHubColors.background(dark: colorScheme == .dark))
                            .overlay(alignment: .bottom) {
                                MarkdownGitHubColors.border(dark: colorScheme == .dark)
                                    .frame(height: 1)
                            }
                        }
                    }
                    .border(MarkdownGitHubColors.border(dark: colorScheme == .dark), width: 1)
                    .textSelection(.enabled)
                }
            case .heading(let level, let children):
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        if Self.isInline(children) {
                            Self.inlineText(children)
                        } else {
                            MarkdownHTMLContent(nodes: children, resource: resource,
                                                assetRefresh: assetRefresh)
                        }
                    }
                    .font(.system(size: [32, 24, 20, 16, 14, 13.6][max(1, min(level, 6)) - 1],
                                  weight: .semibold))
                    .foregroundStyle(level == 6
                        ? MarkdownGitHubColors.secondary(dark: colorScheme == .dark)
                        : MarkdownGitHubColors.text(dark: colorScheme == .dark))
                    .textSelection(.enabled)
                    if level <= 2 {
                        Divider().overlay(MarkdownGitHubColors.border(dark: colorScheme == .dark))
                    }
                }
                .padding(.top, 8)
            case .list(let ordered, let start, let items):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items.indices, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ordered ? "\(start + item)." : "•")
                                .frame(width: 24, alignment: .trailing)
                            if Self.isInline(items[item]) {
                                Self.inlineText(items[item]).textSelection(.enabled)
                            } else {
                                MarkdownHTMLContent(nodes: items[item], resource: resource,
                                                    assetRefresh: assetRefresh)
                            }
                        }
                    }
                }
                .padding(.leading, 8)
            case .horizontalRule:
                Divider().overlay(MarkdownGitHubColors.border(dark: colorScheme == .dark))
            case .media(let url, let video):
                MarkdownMediaView(url: url, video: video, resource: resource).id(url)
            case .details(let label, let children, let open):
                MarkdownHTMLDetails(label: label, children: children, initiallyOpen: open,
                                    resource: resource, assetRefresh: assetRefresh)
            case .link(let url, let children):
                if Self.isInline(children) {
                    Self.inlineText([.link(url, children)])
                        .tint(MarkdownGitHubColors.link(dark: colorScheme == .dark))
                        .textSelection(.enabled)
                } else {
                    Button { openURL(url) } label: {
                        MarkdownHTMLContent(nodes: children, resource: resource,
                                            assetRefresh: assetRefresh)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MarkdownGitHubColors.link(dark: colorScheme == .dark))
                }
            case .emphasis(let children, let tag):
                if Self.isInline(children) {
                    Self.styledText(Self.inlineText(children), tag: tag).textSelection(.enabled)
                } else {
                    MarkdownHTMLContent(nodes: children, resource: resource,
                                        assetRefresh: assetRefresh)
                        .fontWeight(["b", "strong"].contains(tag) ? .bold : nil)
                        .italic(["em", "i"].contains(tag))
                        .strikethrough(["s", "del"].contains(tag))
                        .fontDesign(["code", "kbd"].contains(tag) ? .monospaced : nil)
                }
            }
        }
    }

    private static func groupInline(_ nodes: [MarkdownHTML]) -> [MarkdownHTML] {
        var blocks: [MarkdownHTML] = []
        var inline: [MarkdownHTML] = []
        func flush() {
            let meaningful = inline.contains { node in
                if case .text(let value) = node {
                    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return true
            }
            if meaningful { blocks.append(.paragraph(inline)) }
            inline.removeAll(keepingCapacity: true)
        }
        for node in nodes {
            if isInline([node]) {
                inline.append(node)
            } else {
                flush()
                blocks.append(node)
            }
        }
        flush()
        return blocks
    }

    private static func isInline(_ nodes: [MarkdownHTML]) -> Bool {
        nodes.allSatisfy {
            switch $0 {
            case .text, .lineBreak: return true
            case .emphasis(let children, _), .link(_, let children): return isInline(children)
            default: return false
            }
        }
    }

    private static func inlineText(_ nodes: [MarkdownHTML], link: URL? = nil) -> Text {
        nodes.reduce(Text(verbatim: "")) { result, node in
            switch node {
            case .text(let value):
                guard let link else { return result + Text(verbatim: value) }
                var attributed = AttributedString(value)
                attributed.link = link
                return result + Text(attributed)
            case .lineBreak: return result + Text(verbatim: "\n")
            case .emphasis(let children, let tag):
                return result + styledText(inlineText(children, link: link), tag: tag)
            case .link(let destination, let children):
                return result + inlineText(children, link: destination)
            default: return result
            }
        }
    }

    private static func styledText(_ text: Text, tag: String) -> Text {
        switch tag {
        case "b", "strong": text.bold()
        case "em", "i": text.italic()
        case "s", "del": text.strikethrough()
        case "code", "kbd": text.font(.system(size: 13.6, design: .monospaced))
        default: text
        }
    }
}

private struct MarkdownHTMLDetails: View {
    let label: String
    let children: [MarkdownHTML]
    let initiallyOpen: Bool
    let resource: MarkdownResource
    let assetRefresh: UInt
    @State private var expanded: Bool

    init(label: String, children: [MarkdownHTML], initiallyOpen: Bool,
         resource: MarkdownResource, assetRefresh: UInt) {
        self.label = label
        self.children = children
        self.initiallyOpen = initiallyOpen
        self.resource = resource
        self.assetRefresh = assetRefresh
        _expanded = State(initialValue: initiallyOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                        .font(.system(size: 9))
                        .frame(width: 12)
                    Text(verbatim: label)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bailey.markdown.details")
            if expanded {
                MarkdownHTMLContent(nodes: children, resource: resource,
                                    assetRefresh: assetRefresh)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: initiallyOpen) { _, next in expanded = next }
    }
}

private struct MarkdownHTMLImage: View {
    enum Source: Hashable {
        case file(URL)
        case svg(String)
    }

    private struct Request: Hashable {
        let source: Source
        let assetRefresh: UInt
    }

    let source: Source
    let alt: String
    let resource: MarkdownResource
    var width: Int? = nil
    var height: Int? = nil
    var assetRefresh: UInt = 0
    @State private var image: MarkdownImage?

    var body: some View {
        Group {
            if let image {
                let presented = sized(image)
                presented.body
                    .frame(maxWidth: presented.htmlSize?.width
                        ?? image.image.map { CGFloat($0.poster.width) }, alignment: .leading)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: Request(source: source, assetRefresh: assetRefresh)) {
            image = nil
            let decoded: MarkdownPicture?
            let url: URL?
            switch source {
            case .file(let link):
                url = link
                decoded = try? await resource.picture(link)
            case .svg(let xml):
                url = nil
                decoded = try? await Self.svgPicture(xml)
            }
            guard !Task.isCancelled else { return }
            image = MarkdownImage(image: decoded, alt: alt, url: url)
        }
    }

    private func sized(_ image: MarkdownImage) -> MarkdownImage {
        guard let picture = image.image, width != nil || height != nil else { return image }
        let naturalWidth = CGFloat(picture.poster.width)
        let naturalHeight = CGFloat(picture.poster.height)
        let displayWidth = width.map { CGFloat($0) }
            ?? height.map { CGFloat($0) * naturalWidth / naturalHeight }
            ?? naturalWidth
        let displayHeight = height.map { CGFloat($0) }
            ?? displayWidth * naturalHeight / naturalWidth
        var presented = image
        presented.htmlSize = CGSize(width: displayWidth, height: displayHeight)
        return presented
    }

    @concurrent private static func svgPicture(_ source: String) async throws -> MarkdownPicture {
        MarkdownPicture(poster: try MarkdownSVG.render(Data(source.utf8)))
    }
}
