import AppKit
import MermaidRender
import SwiftUI

nonisolated enum MarkdownMermaid {
    @concurrent static func image(_ source: String, dark: Bool) async -> sending NSImage? {
        guard source.utf8.count <= 16 << 10, !Task.isCancelled else { return nil }
        let lines = source.split(whereSeparator: \.isNewline)
        guard lines.count <= 160, lines.allSatisfy({ line in
            line.utf8.count <= 1024 &&
                !["click", "link", "links"].contains(
                    line.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
                )
        }) else { return nil }
        let image = await MermaidRenderer.renderImage(source: source, theme: DiagramTheme(prefersDark: dark))
        guard !Task.isCancelled, let image, image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }
}

struct MarkdownMermaidView: View {
    let source: String
    let line: Int
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: image.size.width)
                    .accessibilityLabel(Text("Mermaid diagram"))
                    .accessibilityIdentifier("bailey.markdown.mermaid")
            } else if failed {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Could not render Mermaid at line \(line).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        Text(verbatim: source).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: colorScheme) {
            let image = await MarkdownMermaid.image(source, dark: colorScheme == .dark)
            guard !Task.isCancelled else { return }
            self.image = image
            failed = image == nil
        }
    }
}
