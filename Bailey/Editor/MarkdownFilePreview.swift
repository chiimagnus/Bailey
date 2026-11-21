import SwiftUI

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
