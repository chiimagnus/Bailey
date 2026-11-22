import SwiftUI

@Observable
@MainActor
final class MarkdownDetailsState {
    var expanded: [String: Bool] = [:]

    func isExpanded(_ path: [Int], initiallyOpen: Bool) -> Bool {
        expanded[MarkdownHTML.detailKey(path)] ?? initiallyOpen
    }

    func toggle(_ path: [Int], initiallyOpen: Bool) {
        let key = MarkdownHTML.detailKey(path)
        expanded[key] = !(expanded[key] ?? initiallyOpen)
    }
}

struct MarkdownHTMLContent: View {
    let nodes: [MarkdownHTML]
    let resource: MarkdownResource
    let assetRefresh: UInt
    var selectionPath: [Int] = []
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let layoutNodes = MarkdownHTML.groupedForPresentation(nodes)
        ForEach(layoutNodes.indices, id: \.self) { index in
            switch layoutNodes[index] {
            case .text(let text, _):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Self.inlineText([layoutNodes[index]]).textSelection(.enabled)
                }
            case .paragraph(let children):
                if MarkdownHTML.isInline(children) {
                    Self.inlineText(children).textSelection(.enabled)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        MarkdownHTMLContent(nodes: children, resource: resource,
                                            assetRefresh: assetRefresh, selectionPath: selectionPath + [index])
                    }
                }
            case .quote(let children):
                HStack(alignment: .top, spacing: 0) {
                    MarkdownGitHubColors.border(dark: colorScheme == .dark).frame(width: 4)
                    MarkdownHTMLContent(nodes: children, resource: resource,
                                        assetRefresh: assetRefresh, selectionPath: selectionPath + [index])
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
                        ForEach(rows.indices, id: \.self) { row in
                            GridRow {
                                ForEach(rows[row].cells.indices, id: \.self) { column in
                                    let cell = rows[row].cells[column]
                                    Group {
                                        if MarkdownHTML.isInline(cell.nodes) {
                                            Self.inlineText(cell.nodes)
                                        } else {
                                            MarkdownHTMLContent(nodes: cell.nodes, resource: resource,
                                                                assetRefresh: assetRefresh,
                                                                selectionPath: selectionPath + [index, row, column])
                                        }
                                    }
                                    .fontWeight(cell.isHeader ? .semibold : .regular)
                                    .monospacedDigit()
                                    .accessibilityAddTraits(cell.isHeader ? .isHeader : [])
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .overlay(alignment: .trailing) {
                                        MarkdownGitHubColors.border(dark: colorScheme == .dark)
                                            .frame(width: 1)
                                    }
                                }
                            }
                            .background(rows[row].shaded
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
                        if MarkdownHTML.isInline(children) {
                            Self.inlineText(children)
                        } else {
                            MarkdownHTMLContent(nodes: children, resource: resource,
                                                assetRefresh: assetRefresh,
                                                selectionPath: selectionPath + [index])
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
                            if MarkdownHTML.isInline(items[item]) {
                                Self.inlineText(items[item]).textSelection(.enabled)
                            } else {
                                MarkdownHTMLContent(nodes: items[item], resource: resource,
                                                    assetRefresh: assetRefresh,
                                                    selectionPath: selectionPath + [index, item])
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
                                    resource: resource, assetRefresh: assetRefresh,
                                    selectionPath: selectionPath + [index])
            case .link(let url, let children):
                if MarkdownHTML.isInline(children) {
                    Self.inlineText([.link(url, children)])
                        .tint(MarkdownGitHubColors.link(dark: colorScheme == .dark))
                        .textSelection(.enabled)
                } else {
                    Button { openURL(url) } label: {
                        MarkdownHTMLContent(nodes: children, resource: resource,
                                            assetRefresh: assetRefresh, selectionPath: selectionPath + [index])
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .foregroundStyle(MarkdownGitHubColors.link(dark: colorScheme == .dark))
                }
            case .emphasis(let children, let tag):
                if MarkdownHTML.isInline(children) {
                    Self.styledText(Self.inlineText(children), tag: tag).textSelection(.enabled)
                } else {
                    MarkdownHTMLContent(nodes: children, resource: resource,
                                        assetRefresh: assetRefresh, selectionPath: selectionPath + [index])
                        .fontWeight(["b", "strong"].contains(tag) ? .bold : nil)
                        .italic(["em", "i"].contains(tag))
                        .strikethrough(["s", "del"].contains(tag))
                        .fontDesign(["code", "kbd"].contains(tag) ? .monospaced : nil)
                }
            }
        }
    }

    private static func inlineText(_ nodes: [MarkdownHTML], link: URL? = nil) -> Text {
        nodes.reduce(Text(verbatim: "")) { result, node in
            switch node {
            case .text(let value, let source):
                let text: Text
                if let link {
                    var attributed = AttributedString(value)
                    attributed.link = link
                    text = Text(attributed).customAttribute(MarkdownLinkGlyph())
                } else {
                    text = Text(verbatim: value)
                }
                guard let source else { return result + text }
                return result + text.customAttribute(
                    MarkdownSourceGlyph(source: source, displayLength: value.utf16.count)
                )
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
    let selectionPath: [Int]
    @Environment(MarkdownDetailsState.self) private var disclosure

    private var expanded: Bool {
        disclosure.isExpanded(selectionPath, initiallyOpen: initiallyOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { disclosure.toggle(selectionPath, initiallyOpen: initiallyOpen) } label: {
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
            .pointerStyle(.link)
            .accessibilityIdentifier("bailey.markdown.details")
            if expanded {
                MarkdownHTMLContent(nodes: children, resource: resource,
                                    assetRefresh: assetRefresh, selectionPath: selectionPath)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var picture: MarkdownPicture?
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                MarkdownNativeImage(
                    picture: picture, alt: alt,
                    url: { if case .file(let url) = source { return url }; return nil }(),
                    width: width.map(CGFloat.init), height: height.map(CGFloat.init)
                )
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: Request(source: source, assetRefresh: assetRefresh)) {
            loaded = false
            picture = nil
            let decoded: MarkdownPicture?
            switch source {
            case .file(let url):
                decoded = try? await resource.picture(url)
            case .svg(let xml):
                decoded = try? await Self.svgPicture(xml)
            }
            guard !Task.isCancelled else { return }
            picture = decoded
            loaded = true
        }
    }

    @concurrent private static func svgPicture(_ xml: String) async throws -> MarkdownPicture {
        let raster = try MarkdownSVG.render(Data(xml.utf8))
        return MarkdownPicture(poster: raster.image, pointSize: raster.pointSize)
    }
}
