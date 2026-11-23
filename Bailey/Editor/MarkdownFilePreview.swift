import SwiftUI

struct MarkdownFilePreview: View {
    let file: FileTab
    let directory: String?
    let assetRefresh: UInt
    let onOpenLink: (URL) async -> Bool
    var onLocateSource: (Int) -> Void = { _ in }

    @State private var parsed: (document: MarkdownDocument, request: String, target: String)?
    @State private var failed = false

    var body: some View {
        let request = file.textPreviewRequestID
        let target = file.fileContentRevision
        Group {
            if let parsed, parsed.target == target {
                MarkdownPreview(
                    document: parsed.document, revision: parsed.request,
                    resource: file.markdownResource(in: directory), assetRefresh: assetRefresh,
                    collapsedHeadings: file.markdownCollapsedHeadings,
                    onToggleHeading: { heading in
                        guard parsed.request == file.textPreviewRequestID else { return }
                        if !file.markdownCollapsedHeadings.insert(heading).inserted {
                            file.markdownCollapsedHeadings.remove(heading)
                        }
                    },
                    onRevealHeading: { heading in
                        guard parsed.request == file.textPreviewRequestID else { return }
                        file.markdownCollapsedHeadings.remove(heading)
                    },
                    restoredBlock: parsed.request == request
                        ? file.markdownReadingOffset.flatMap {
                            file.markdownSourceIndex?.index.block(atUTF16Offset: $0)
                        }
                        : nil,
                    sourceBlock: file.markdownScrollSyncEnabled && parsed.request == request
                        ? file.markdownSourceOffset.flatMap {
                            file.markdownSourceIndex?.index.block(atUTF16Offset: $0)
                        } : nil,
                    restoredSourceOffset: parsed.request == request ? file.markdownReadingOffset : nil,
                    synchronizedSourceOffset: file.markdownScrollSyncEnabled && parsed.request == request
                        ? file.markdownSourceOffset : nil,
                    restoredViewportY: file.markdownReadingViewportY,
                    onReadingPosition: { block in
                        guard parsed.request == file.textPreviewRequestID,
                              parsed.document.blocks.indices.contains(block),
                              let source = parsed.document.blocks[block].sourceRange else { return }
                        file.markdownReadingOffset = source.location
                        file.markdownReadingViewportY = 0
                    },
                    onReaderScroll: { block in
                        guard parsed.document.blocks.indices.contains(block),
                              let source = parsed.document.blocks[block].sourceRange else { return }
                        followReader(offset: source.location, request: parsed.request)
                    },
                    onReadingSourceAnchor: { offset, viewportY in
                        guard parsed.request == file.textPreviewRequestID else { return }
                        file.markdownReadingOffset = offset
                        file.markdownReadingViewportY = viewportY
                    },
                    onReaderSourceScroll: { offset in
                        followReader(offset: offset, request: parsed.request)
                    },
                    onLocateSource: { offset in
                        guard parsed.request == file.textPreviewRequestID else { return }
                        onLocateSource(offset)
                    },
                    openLink: { url in
                        guard file.textPreviewRequestID == parsed.request else { return false }
                        return await onOpenLink(url)
                    },
                    navigation: parsed.request == request
                        ? Binding(get: { file.pendingMarkdownFragment },
                                  set: { file.pendingMarkdownFragment = $0 })
                        : .constant(nil)
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
                guard !Task.isCancelled, request == file?.textPreviewRequestID else { return }
                file?.markdownSourceIndex = (request: request, index: MarkdownBlockIndex(document))
                file?.installMarkdownOutline(document.headingOutline, request: request)
                if file?.markdownReadingOffset == nil {
                    file?.editorCoordinator?.refreshMarkdownViewport()
                }
                parsed = (document, request, target)
            } catch {
                guard !Task.isCancelled, request == file?.textPreviewRequestID else { return }
                parsed = nil
                failed = true
            }
        }
    }

    private func followReader(offset: Int, request: String) {
        guard file.markdownScrollSyncEnabled,
              request == file.textPreviewRequestID else { return }
        file.pendingMarkdownSource = (request: request, offset: offset, focus: false)
        if file.editorCoordinator?.showMarkdownSource(atUTF16Offset: offset) == true {
            file.pendingMarkdownSource = nil
        }
    }
}

struct MarkdownOutlineView: View {
    let file: FileTab
    let onChoose: (MarkdownDocument.OutlineHeading) -> Void
    let onDismiss: () -> Void

    @State private var selected: MarkdownDocument.HeadingIdentity?
    @State private var loading = true
    @State private var failed = false
    @FocusState private var focused: Bool

    private var headings: [MarkdownDocument.OutlineHeading] {
        file.markdownOutlineRequest == file.textPreviewRequestID ? file.markdownHeadingOutline : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Outline", tableName: "Editor").font(.headline)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                ContentUnavailableView("Could not render Markdown.", systemImage: "doc.text")
            } else if headings.isEmpty {
                ContentUnavailableView(String(localized: "No headings", table: "Editor"), systemImage: "list.bullet.indent")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(headings) { heading in
                                Button { onChoose(heading) } label: {
                                    HStack(spacing: 8) {
                                        Text("H\(heading.level)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Text(verbatim: heading.title.isEmpty ? "Untitled" : heading.title)
                                            .lineLimit(2)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.leading, CGFloat(heading.level - 1) * 12)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected == heading.id
                                        ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Level \(heading.level), \(heading.title)")
                                .accessibilityIdentifier("bailey.markdown.outline.\(heading.anchor)")
                                .id(heading.id)
                            }
                        }
                    }
                    .focusable()
                    .focused($focused)
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        if let heading = headings.first(where: { $0.id == selected }) { onChoose(heading) }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        onDismiss()
                        return .handled
                    }
                    .onChange(of: selected) { _, next in
                        if let next { proxy.scrollTo(next, anchor: .center) }
                    }
                }
                .onAppear {
                    selected = headings.first?.id
                    focused = true
                }
            }
        }
        .padding(14)
        .frame(width: 320, height: 410)
        .task(id: file.textPreviewRequestID) {
            let request = file.textPreviewRequestID
            failed = false
            loading = file.markdownOutlineRequest != request
            if loading {
                do {
                    let document = try await MarkdownDocument.parse(file.text)
                    guard !Task.isCancelled, request == file.textPreviewRequestID else { return }
                    file.installMarkdownOutline(document.headingOutline, request: request)
                } catch {
                    guard !Task.isCancelled else { return }
                    failed = true
                }
            }
            selected = headings.first?.id
            loading = false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !headings.isEmpty else { return }
        let position = headings.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : headings.count)
        selected = headings[min(max(0, position + delta), headings.count - 1)].id
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
        .task(id: file.textPreviewRequestID) {
            let request = file.textPreviewRequestID
            let result = await MarkdownDocument.metadata(file.text)
            guard !Task.isCancelled, request == file.textPreviewRequestID else { return }
            metadata = result
        }
    }
}
