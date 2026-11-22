import AppKit
import SwiftUI

struct MarkdownPreview: View {
    let document: MarkdownDocument
    let revision: String
    let resource: MarkdownResource
    let assetRefresh: UInt
    @Binding var position: Int?
    var openLink: (URL) async -> Bool = { _ in false }
    var navigation: Binding<String?> = .constant(nil)

    @State private var linkToOpen: URL?
    @State private var failedLink = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if let warning = document.warning {
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(renderRows, id: \.start) { row in
                                if row.end - row.start > 1 {
                                    paragraphRun(row.start..<row.end)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                        .id(row.start)
                                } else {
                                    MarkdownNativeBlockView(block: document.blocks[row.start].content,
                                                            resource: resource, assetRefresh: assetRefresh,
                                                            anchor: document.blocks[row.start].anchor)
                                        .id(row.start)
                                }
                            }
                        }
                        .scrollTargetLayout()
                        .font(.system(size: 16))
                        .lineSpacing(4)
                        .foregroundStyle(MarkdownGitHubColors.text(dark: colorScheme == .dark))
                        .tint(MarkdownGitHubColors.link(dark: colorScheme == .dark))
                        .frame(maxWidth: 890, alignment: .leading)
                        .padding(geometry.size.width < 768 ? 15 : 45)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .modifier(MarkdownLinkCursor())
                    }
                    .accessibilityIdentifier("bailey.markdown.preview")
                    .scrollPosition(id: $position, anchor: .top)
                    .task(id: navigation.wrappedValue) {
                        guard let fragment = navigation.wrappedValue else { return }
                        if let index = document.blocks.firstIndex(where: { $0.anchor == fragment }) {
                            proxy.scrollTo(index, anchor: .top)
                            position = index
                            failedLink = false
                        } else {
                            failedLink = true
                        }
                        navigation.wrappedValue = nil
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        if url.absoluteString.hasPrefix("#") {
                            let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
                            if let index = document.blocks.firstIndex(where: { $0.anchor == fragment }) {
                                proxy.scrollTo(index, anchor: .top)
                                position = index
                                failedLink = false
                            } else {
                                failedLink = true
                            }
                        } else {
                            linkToOpen = url
                        }
                        return .handled
                    })
                }
                if failedLink {
                    Label("Could not open this link.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(MarkdownGitHubColors.background(dark: colorScheme == .dark))
        .onChange(of: revision) { _, _ in
            linkToOpen = nil
            failedLink = false
        }
        .task(id: linkToOpen) {
            guard let url = linkToOpen else { return }
            let opened = await openLink(url)
            guard !Task.isCancelled else { return }
            failedLink = !opened
            linkToOpen = nil
        }
    }

    private struct RenderRow {
        let start: Int
        let end: Int
    }

    // One SwiftUI Text owns consecutive prose, so text selection can cross paragraphs.
    // Keep groups bounded: a single giant Text would defeat long-document lazy layout.
    private var renderRows: [RenderRow] {
        var result: [RenderRow] = []
        var start = 0
        while start < document.blocks.count {
            var end = start + 1
            if canMergeParagraph(at: start) {
                while end < document.blocks.count, end - start < 12 {
                    guard canMergeParagraph(at: end) else { break }
                    end += 1
                }
            }
            result.append(RenderRow(start: start, end: end))
            start = end
        }
        return result
    }

    private func canMergeParagraph(at index: Int) -> Bool {
        guard case let .paragraph(inline) = document.blocks[index].content else { return false }
        return !inline.contains { if case .image = $0 { true } else { false } }
            && !MarkdownMixedParagraph.containsMath(inline)
    }

    private func paragraphRun(_ indices: Range<Int>) -> Text {
        var inlines: [MarkdownInline] = []
        for index in indices {
            if !inlines.isEmpty { inlines.append(.text("\n\n")) }
            if case .paragraph(let inline) = document.blocks[index].content {
                inlines.append(contentsOf: inline)
            }
        }
        return MarkdownNativeText.make(inlines)
    }
}

struct MarkdownLinkGlyph: TextAttribute {}

/// Text's selection cursor overrides SwiftUI pointerStyle. The transparent
/// AppKit cursor rects use SwiftUI's exact glyph layout and never own mouse clicks.
private struct MarkdownLinkCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
            GeometryReader { geometry in
                MarkdownLinkCursorRects(rects: layouts.flatMap { entry in
                    let origin = geometry[entry.origin]
                    return entry.layout.flatMap { line in
                        line.compactMap { run -> CGRect? in
                            guard run[MarkdownLinkGlyph.self] != nil else { return nil }
                            return run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                        }
                    }
                })
            }
        }
    }
}

private struct MarkdownLinkCursorRects: NSViewRepresentable {
    let rects: [CGRect]

    func makeNSView(context: Context) -> MarkdownCursorRectView {
        MarkdownCursorRectView()
    }

    func updateNSView(_ view: MarkdownCursorRectView, context: Context) {
        guard view.linkRects != rects else { return }
        view.linkRects = rects
        view.updateTrackingAreas()
    }

    static func dismantleNSView(_ view: MarkdownCursorRectView, coordinator: ()) {
        view.clearTracking()
    }
}

final class MarkdownCursorRectView: NSView {
    var linkRects: [CGRect] = []
    private weak var trackingHost: NSView?
    private var linkTrackingAreas: [NSTrackingArea] = []
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { clearTracking() }
        super.viewWillMove(toWindow: newWindow)
    }

    func clearTracking() {
        if let trackingHost {
            linkTrackingAreas.forEach { trackingHost.removeTrackingArea($0) }
        }
        linkTrackingAreas.removeAll()
        trackingHost = nil
    }

    override func updateTrackingAreas() {
        clearTracking()
        var ancestor = superview
        while let view = ancestor, !(view is NSClipView) {
            ancestor = view.superview
        }
        if let host = (ancestor as? NSClipView)?.documentView ?? window?.contentView {
            trackingHost = host
            linkTrackingAreas = linkRects.map {
                NSTrackingArea(rect: convert($0, to: host),
                               options: [.activeInKeyWindow, .mouseEnteredAndExited,
                                         .mouseMoved, .cursorUpdate],
                               owner: self, userInfo: nil)
            }
            linkTrackingAreas.forEach(host.addTrackingArea)
        }
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }
}

enum MarkdownGitHubColors {
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

private struct MarkdownNativeBlockView: View {
    let block: MarkdownNativeBlock
    let resource: MarkdownResource
    let assetRefresh: UInt
    var anchor: String? = nil
    @State private var headingHovered = false
    @FocusState private var headingLinkFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private static let headingSizes: [CGFloat] = [32, 24, 20, 16, 14, 12]

    private static func headingSize(_ level: Int) -> CGFloat {
        headingSizes[max(1, min(level, 6)) - 1]
    }

    var body: some View {
        switch block {
        case .heading(let level, let inline):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let anchor {
                        ZStack {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("#" + anchor, forType: .string)
                            } label: {
                                Rectangle()
                                    .fill(.white.opacity(0.001))
                                    .frame(width: 20, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Copy heading link")
                            .accessibilityLabel("Copy heading link")
                            .accessibilityIdentifier("bailey.markdown.anchor.\(anchor)")
                            .focused($headingLinkFocused)

                            Image(systemName: "link")
                                .font(.system(size: 13))
                                .foregroundStyle(MarkdownGitHubColors.secondary(dark: colorScheme == .dark))
                                .opacity(headingHovered || headingLinkFocused ? 1 : 0)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .frame(width: 20, height: 24)
                        .overlay {
                            GeometryReader { geometry in
                                MarkdownLinkCursorRects(rects: [
                                    CGRect(origin: .zero, size: geometry.size)
                                ])
                                .accessibilityHidden(true)
                            }
                        }
                    }
                    Group {
                        if MarkdownMixedParagraph.containsMath(inline) {
                            MarkdownMixedParagraph(inline: inline, resource: resource,
                                                   assetRefresh: assetRefresh,
                                                   formulaFontSize: Self.headingSize(level))
                        } else {
                            MarkdownNativeText.make(inline).textSelection(.enabled)
                        }
                    }
                        .font(.system(size: Self.headingSize(level), weight: .semibold))
                        .foregroundStyle(level == 6
                            ? MarkdownGitHubColors.secondary(dark: colorScheme == .dark)
                            : MarkdownGitHubColors.text(dark: colorScheme == .dark))
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                }
                .contentShape(Rectangle())
                .onHover { headingHovered = $0 }
                .padding(.leading, -20)
                if level <= 2 { Divider() }
            }
            .padding(.top, 8)
        case .paragraph(let inline):
            if inline.contains(where: { if case .image = $0 { true } else { false } })
                || MarkdownMixedParagraph.containsMath(inline) {
                MarkdownMixedParagraph(inline: inline, resource: resource, assetRefresh: assetRefresh)
            } else {
                MarkdownNativeText.make(inline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .image(let source, let alt):
            if let url = URL(string: source) {
                MarkdownResourceImage(url: url, alt: alt, resource: resource,
                                      refresh: assetRefresh)
            } else {
                Text(verbatim: alt).foregroundStyle(.secondary)
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 16) {
                MarkdownGitHubColors.border(dark: colorScheme == .dark).frame(width: 4)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(blocks.indices, id: \.self) { index in
                        MarkdownNativeBlockView(block: blocks[index], resource: resource,
                                                assetRefresh: assetRefresh)
                    }
                }
                .foregroundStyle(.secondary)
            }
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let checked = items[index].checked {
                            Image(systemName: checked ? "checkmark.square" : "square")
                                .accessibilityLabel(checked ? "Completed" : "Incomplete")
                        } else {
                            Text(verbatim: ordered ? "\(start + index)." : "•")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items[index].blocks.indices, id: \.self) { blockIndex in
                                MarkdownNativeBlockView(block: items[index].blocks[blockIndex],
                                                        resource: resource, assetRefresh: assetRefresh)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.leading, 16)
        case .table(let head, let rows, let alignments):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(head.indices, id: \.self) { index in
                            cell(head[index], alignment: aligned(at: index, in: alignments), header: true)
                        }
                    }
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { column in
                                cell(rows[row][column],
                                     alignment: aligned(at: column, in: alignments), header: false)
                            }
                        }
                        .background(rows.indices.contains(row) && row.isMultiple(of: 2)
                            ? MarkdownGitHubColors.muted(dark: colorScheme == .dark)
                            : MarkdownGitHubColors.background(dark: colorScheme == .dark))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(MarkdownGitHubColors.border(dark: colorScheme == .dark))
                }
            }
        case .code(let source, let language):
            MarkdownCodeBlockView(source: source, language: language)
        case .mermaid(let source, let line):
            MarkdownMermaidView(source: source, line: line)
        case .mathBlock(let latex):
            MarkdownFormulaView(latex: latex, display: true)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .center)
        case .html(let nodes):
            MarkdownHTMLContent(nodes: nodes, resource: resource, assetRefresh: assetRefresh)
        case .rawHTML(let source):
            Text(verbatim: source).font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
        case .rule:
            Divider()
        }
    }

    private func aligned(at index: Int, in alignments: [MarkdownColumnAlignment]) -> Alignment {
        guard alignments.indices.contains(index) else { return .leading }
        switch alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func cell(_ inline: [MarkdownInline], alignment: Alignment, header: Bool) -> some View {
        Group {
            if MarkdownMixedParagraph.containsMath(inline) {
                MarkdownMixedParagraph(inline: inline, resource: resource,
                                       assetRefresh: assetRefresh)
            } else {
                MarkdownNativeText.make(inline)
                    .textSelection(.enabled)
            }
        }
            .fontWeight(header ? .semibold : .regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minWidth: 64, maxWidth: .infinity, alignment: alignment)
            .overlay(alignment: .trailing) {
                MarkdownGitHubColors.border(dark: colorScheme == .dark).frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                MarkdownGitHubColors.border(dark: colorScheme == .dark).frame(height: 1)
            }
    }
}


private struct MarkdownMixedParagraph: View {
    private enum Segment {
        case text([MarkdownInline])
        case image(String, String)
        case math(String, display: Bool)
    }

    let inline: [MarkdownInline]
    let resource: MarkdownResource
    let assetRefresh: UInt
    var formulaFontSize: CGFloat? = nil

    static func containsMath(_ nodes: [MarkdownInline]) -> Bool {
        nodes.contains { node in
            switch node {
            case .math: true
            case .strong(let children), .emphasis(let children), .strike(let children),
                 .link(_, let children): containsMath(children)
            default: false
            }
        }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var text: [MarkdownInline] = []
        func flush() {
            if !text.isEmpty { result.append(.text(text)); text.removeAll() }
        }
        func collect(_ nodes: [MarkdownInline],
                     decorated: @escaping (MarkdownInline) -> MarkdownInline) {
            for node in nodes {
                switch node {
                case .image(let source, let alt):
                    flush()
                    result.append(.image(source, alt))
                case .math(let latex, let display):
                    flush()
                    result.append(.math(latex, display: display))
                case .strong(let children):
                    collect(children) { decorated(.strong([$0])) }
                case .emphasis(let children):
                    collect(children) { decorated(.emphasis([$0])) }
                case .strike(let children):
                    collect(children) { decorated(.strike([$0])) }
                case .link(let destination, let children):
                    collect(children) { decorated(.link(destination, [$0])) }
                default:
                    text.append(decorated(node))
                }
            }
        }
        collect(inline, decorated: { $0 })
        flush()
        return result
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ForEach(segments.indices, id: \.self) { index in
                    content(segments[index], inline: true)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(segments.indices, id: \.self) { index in
                    content(segments[index], inline: false)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ segment: Segment, inline: Bool) -> some View {
        switch segment {
        case .text(let inlines):
            MarkdownNativeText.make(inlines)
                .fixedSize(horizontal: inline, vertical: true)
                .textSelection(.enabled)
        case .image(let source, let alt):
            if let url = URL(string: source) {
                MarkdownResourceImage(url: url, alt: alt, resource: resource, refresh: assetRefresh)
                    .fixedSize(horizontal: inline, vertical: false)
            } else {
                Text(verbatim: alt).foregroundStyle(.secondary)
            }
        case .math(let latex, let display):
            MarkdownFormulaView(latex: latex, display: display,
                                fontSize: formulaFontSize)
        }
    }
}

private struct MarkdownCodeBlockView: View {
    let source: String
    let language: String?
    @State private var hovering = false
    @State private var copied = false
    @FocusState private var copyFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal) {
            MarkdownCodeText(source: source, language: language)
                .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(source, forType: .string)
            } label: {
                Image(systemName: copied ? "checkmark" : "document.on.document")
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .foregroundStyle(MarkdownGitHubColors.secondary(dark: colorScheme == .dark)
                .opacity(hovering || copyFocused ? 1 : 0.001))
            .background(MarkdownGitHubColors.background(dark: colorScheme == .dark)
                            .opacity(hovering || copyFocused ? 1 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(MarkdownGitHubColors.border(dark: colorScheme == .dark)
                        .opacity(hovering || copyFocused ? 1 : 0))
            }
            .accessibilityLabel("Copy")
            .accessibilityValue(copied ? "Copied" : "Ready")
            .help(copied ? "Copied" : "Copy code")
            .focused($copyFocused)
            .pointerStyle(.link)
            .padding(7)
        }
        .background(MarkdownGitHubColors.muted(dark: colorScheme == .dark),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if !inside { copied = false }
        }
        .onChange(of: source) { _, _ in copied = false }
    }
}

struct MarkdownCodeText: View {
    struct Request: Hashable {
        let source: String
        let language: String?
    }

    private struct Rendered {
        let request: Request
        let value: AttributedString
    }

    let source: String
    let language: String?
    @State private var rendered: Rendered?

    private var request: Request { Request(source: source, language: language) }

    var body: some View {
        Group {
            if let rendered, rendered.request == request {
                Text(rendered.value)
            } else {
                Text(verbatim: source)
            }
        }
        .font(.system(size: 13.6, design: .monospaced))
        .lineSpacing(3)
        .textSelection(.enabled)
        .task(id: request) {
            rendered = nil
            guard let value = await Self.highlight(source, language: language),
                  !Task.isCancelled else { return }
            rendered = Rendered(request: request, value: value)
        }
    }

    /// Reuse the editor's Tree-sitter grammars, query cache and Diff capture pipeline.
    /// Large code blocks remain readable without forcing a full syntax parse.
    static func highlight(_ source: String, language marker: String?) async -> AttributedString? {
        guard source.utf8.count <= 1 << 20,
              let marker, let language = SyntaxHighlighting.language(forInjectionName: marker),
              let grammarIndex = language.grammarIndex else { return nil }
        let data = SyntaxHighlighting.highlightsData(for: language)
        guard let query = await HighlightQueryCache.shared.query(for: language, data: data)
        else { return nil }
        let context = DiffHighlightContext(grammarIndex: grammarIndex, query: query)
        let sourceParser = DiffSyntaxSource()
        let captures = await sourceParser.captures(
            text: source, context: context,
            ranges: [NSRange(location: 0, length: source.utf16.count)]
        )
        guard !Task.isCancelled else { return nil }
        let attributed = NSMutableAttributedString(string: source)
        for run in DiffSyntaxHighlighter.colors(for: captures) {
            attributed.addAttribute(.foregroundColor, value: run.color, range: run.range)
        }
        return AttributedString(attributed)
    }
}

/// Compose adjacent AST inline fragments as one Text so selection remains native.
enum MarkdownNativeText {
    private struct HTMLTag {
        let name: String
        let closing: Bool
        let raw: String
    }

    private struct ActiveHTML {
        let name: String
        let href: URL?
    }

    static func make(_ nodes: [MarkdownInline]) -> Text {
        var matched = Set<Int>()
        var opened: [(name: String, index: Int)] = []
        var tags: [Int: HTMLTag] = [:]
        for (index, node) in nodes.enumerated() {
            guard case let .html(raw) = node, let tag = parseTag(raw) else { continue }
            tags[index] = tag
            guard tag.name != "br" else { continue }
            if tag.closing {
                guard let last = opened.last, last.name == tag.name else { continue }
                matched.insert(last.index)
                matched.insert(index)
                opened.removeLast()
            } else if opened.count < 32 {
                opened.append((tag.name, index))
            }
        }

        var active: [ActiveHTML] = []
        var result = Text(verbatim: "")
        for (index, node) in nodes.enumerated() {
            if let tag = tags[index] {
                if tag.name == "br", !tag.closing {
                    result = result + Text(verbatim: "\n")
                    continue
                }
                if matched.contains(index) {
                    if tag.closing {
                        active.removeLast()
                    } else {
                        active.append(ActiveHTML(
                            name: tag.name,
                            href: tag.name == "a" ? validLink(in: tag.raw) : nil
                        ))
                    }
                    continue
                }
            }
            var text = part(node)
            for tag in active {
                switch tag.name {
                case "b", "strong": text = text.bold()
                case "i", "em": text = text.italic()
                case "s", "del": text = text.strikethrough()
                case "code", "kbd": text = text.font(.system(size: 13.5, design: .monospaced))
                case "a":
                    if let url = tag.href {
                        var linked = attributed([node])
                        linked.link = url
                        text = Text(linked).customAttribute(MarkdownLinkGlyph())
                    }
                default: break
                }
            }
            result = result + text
        }
        return result
    }

    private static func parseTag(_ raw: String) -> HTMLTag? {
        guard raw.utf8.count <= 8_192, raw.first == "<", raw.last == ">" else { return nil }
        var content = String(raw.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let closing = content.hasPrefix("/")
        if closing { content.removeFirst() }
        let name = String(content.prefix { $0.isASCII && $0.isLetter }).lowercased()
        guard ["a", "span", "b", "strong", "i", "em", "s", "del", "code", "kbd", "br"].contains(name)
        else { return nil }
        let remainder = content.dropFirst(name.count)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true || remainder.first == "/"
        else { return nil }
        if closing && !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return HTMLTag(name: name, closing: closing, raw: raw)
    }

    private static func validLink(in openTag: String) -> URL? {
        guard let elements = MarkdownHTML.parse(openTag + "link</a>"),
              case let .link(url, _) = elements.first else { return nil }
        return url
    }

    private static func part(_ node: MarkdownInline) -> Text {
        switch node {
        case .text(let content):
            return Text(verbatim: content)
        case .code:
            return Text(attributed([node]))
        case .emphasis(let children):
            return make(children).italic()
        case .strong(let children):
            return make(children).bold()
        case .strike(let children):
            return make(children).strikethrough()
        case .link(let destination, let children):
            guard let url = URL(string: destination) else { return make(children) }
            // Keep nested bold/italic/code styles when making the entire link clickable.
            var linked = attributed(children)
            linked.link = url
            return Text(linked).customAttribute(MarkdownLinkGlyph())
        case .image(_, let alt):
            return Text(verbatim: alt)
        case .math(let latex, let display):
            return Text(verbatim: display ? "$$\(latex)$$" : "$\(latex)$")
        case .html(let source):
            return Text(verbatim: source)
        case .lineBreak:
            return Text(verbatim: "\n")
        }
    }

    static func attributed(_ nodes: [MarkdownInline]) -> AttributedString {
        nodes.reduce(into: AttributedString()) { result, node in
            var part: AttributedString
            switch node {
            case .text(let value), .html(let value):
                part = AttributedString(value)
            case .code(let value):
                part = AttributedString(value)
                add(.code, to: &part)
                part.backgroundColor = Color.primary.opacity(0.08)
            case .strong(let children):
                part = attributed(children)
                add(.stronglyEmphasized, to: &part)
            case .emphasis(let children):
                part = attributed(children)
                add(.emphasized, to: &part)
            case .strike(let children):
                part = attributed(children)
                add(.strikethrough, to: &part)
            case .link(let destination, let children):
                part = attributed(children)
                part.link = URL(string: destination)
                if destination.hasPrefix("#bailey-note:"), !part.characters.isEmpty,
                   part.characters.allSatisfy(\.isNumber) {
                    part.font = .system(size: 12, weight: .medium)
                    part.baselineOffset = 5
                }
            case .image(_, let alt):
                part = AttributedString(alt)
            case .math(let latex, let display):
                part = AttributedString(display ? "$$\(latex)$$" : "$\(latex)$")
            case .lineBreak:
                part = AttributedString("\n")
            }
            result += part
        }
    }

    private static func add(_ intent: InlinePresentationIntent, to text: inout AttributedString) {
        for run in text.runs {
            text[run.range].inlinePresentationIntent =
                (run.inlinePresentationIntent ?? []).union(intent)
        }
    }
}
