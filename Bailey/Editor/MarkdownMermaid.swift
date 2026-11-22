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
        let theme = DiagramTheme(
            ink: color(dark ? 0xF0F6FC : 0x1F2328),
            secondaryTextColor: color(dark ? 0x9198A1 : 0x59636E),
            tertiaryTextColor: color(dark ? 0x9198A1 : 0x59636E, alpha: 0.72),
            canvas: color(dark ? 0x0D1117 : 0xFFFFFF),
            accent: color(dark ? 0x4493F8 : 0x0969DA),
            hairline: color(dark ? 0x3D444D : 0xD1D9E0),
            prefersDark: dark
        )
        let image = await MermaidRenderer.renderImage(source: source, theme: theme)
        guard !Task.isCancelled, let image, image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

struct MarkdownMermaidView: View {
    let source: String
    let line: Int
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var failed = false
    @State private var inspecting = false

    var body: some View {
        Group {
            if let image {
                Button { inspecting = true } label: {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: image.size.width)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(Text("Inspect diagram", tableName: "Editor"))
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
        .sheet(isPresented: $inspecting) {
            if let image {
                MarkdownImageInspector(image: image, showsCloseButton: true)
                    .frame(minWidth: 360, minHeight: 280)
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
