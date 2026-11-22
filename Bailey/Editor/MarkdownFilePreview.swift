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
        let request = file.markdownRequestID
        let target = file.markdownResourceID
        Group {
            if let parsed, parsed.target == target {
                MarkdownPreview(
                    document: parsed.document, revision: parsed.request,
                    resource: file.markdownResource(in: directory), assetRefresh: assetRefresh,
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
                        guard parsed.request == file.markdownRequestID,
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
                        guard parsed.request == file.markdownRequestID else { return }
                        file.markdownReadingOffset = offset
                        file.markdownReadingViewportY = viewportY
                    },
                    onReaderSourceScroll: { offset in
                        followReader(offset: offset, request: parsed.request)
                    },
                    onLocateSource: { offset in
                        guard parsed.request == file.markdownRequestID else { return }
                        onLocateSource(offset)
                    },
                    openLink: { url in
                        guard file.markdownRequestID == parsed.request else { return false }
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
                guard !Task.isCancelled, request == file?.markdownRequestID else { return }
                file?.markdownSourceIndex = (request: request, index: MarkdownBlockIndex(document))
                if file?.markdownReadingOffset == nil {
                    file?.editorCoordinator?.refreshMarkdownViewport()
                }
                parsed = (document, request, target)
            } catch {
                guard !Task.isCancelled, request == file?.markdownRequestID else { return }
                parsed = nil
                failed = true
            }
        }
    }

    private func followReader(offset: Int, request: String) {
        guard file.markdownScrollSyncEnabled,
              request == file.markdownRequestID else { return }
        file.pendingMarkdownSource = (request: request, offset: offset, focus: false)
        if file.editorCoordinator?.showMarkdownSource(atUTF16Offset: offset) == true {
            file.pendingMarkdownSource = nil
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
