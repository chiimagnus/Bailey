import AppKit
import SwiftDraw
import SwiftUI

struct SVGPreviewSnapshot {
    struct Drawing {
        let request: String
        let artwork: SVGArtwork.Vector
    }

    let request: String
    let drawing: Drawing?
    let error: String?

    @concurrent static func parse(_ text: String) async throws -> SVGArtwork.Vector {
        guard text.utf8.count <= SVGArtwork.byteLimit else { throw WorkspaceError.tooLarge }
        let artwork = try SVGArtwork.parse(Data(text.utf8))
        let size = artwork.image.size
        guard max(size.width, size.height) <= 32_768,
              size.width * size.height <= 8_000_000 else { throw WorkspaceError.tooLarge }
        return artwork
    }
}

struct SVGFilePreview: View {
    let file: FileTab
    let onFocused: () -> Void
    let onShowSource: () -> Void

    var body: some View {
        let request = file.textPreviewRequestID
        let snapshot = file.svgPreview
        Group {
            if let drawing = snapshot?.drawing {
                VStack(spacing: 0) {
                    if !drawing.artwork.omitted.isEmpty {
                        let names = drawing.artwork.omitted.prefix(8).joined(separator: ", ")
                        notice(String(localized: "SVG preview omits: \(names)", table: "Editor"))
                    }
                    NativeSVGViewport(svg: drawing.artwork.image, request: drawing.request,
                                      viewportPosition: file.graphicViewportPosition,
                                      onViewportPositionChange: { position in
                        guard file.previewKind == .svg, case .text = file.content,
                              file.svgPreview?.drawing?.request == drawing.request else { return }
                        file.graphicViewportPosition = position
                    }, onFocused: onFocused)
                }
                .overlay(alignment: .top) {
                    if drawing.request != request {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SVG preview not updated.", tableName: "Editor")
                                .fontWeight(.medium)
                            if snapshot?.request == request, let error = snapshot?.error {
                                notice(error)
                            } else {
                                Text("Updating SVG preview…", tableName: "Editor")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                        .padding(8)
                    }
                }
            } else if snapshot?.request == request, let error = snapshot?.error {
                notice(error).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: request) { await file.showSVGPreview(request: request) }
    }

    private func notice(_ message: String) -> some View {
        HStack {
            Text(message).foregroundStyle(.secondary)
            Button(FilePreviewMode.source.title, action: onShowSource)
                .buttonStyle(.link)
                .accessibilityIdentifier("bailey.svg.showSource")
        }
        .padding(8)
    }

}

private struct NativeSVGViewport: NSViewRepresentable {
    let svg: SVG
    let request: String
    let viewportPosition: PreviewScrollView.Position?
    let onViewportPositionChange: (PreviewScrollView.Position?) -> Void
    let onFocused: () -> Void

    func makeNSView(context: Context) -> SVGPreviewScrollView { SVGPreviewScrollView() }

    func updateNSView(_ scroll: SVGPreviewScrollView, context: Context) {
        scroll.onFocused = onFocused
        scroll.install(svg, request: request, position: viewportPosition,
                       onPositionChange: onViewportPositionChange)
    }

    static func dismantleNSView(_ scroll: SVGPreviewScrollView, coordinator: ()) { scroll.clear() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SVGPreviewScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

private struct NativeSVGDrawing: View {
    let svg: SVG

    var body: some View {
        // Draw at the current device scale without SVGView's shared filter
        // cache, which retained buffers after complex documents were closed.
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            context.draw(svg, in: CGRect(origin: .zero, size: size))
        }
        .frame(width: svg.size.width, height: svg.size.height)
    }
}

final class SVGPreviewScrollView: PreviewScrollView {
    private let canvas = PreviewCanvasView()
    private var request: String?
    private var content: NSHostingView<NativeSVGDrawing>?
    var onFocused: () -> Void = {}

    init() {
        super.init(frame: .zero)
        documentView = canvas
        setAccessibilityIdentifier("bailey.svg.preview")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocused()
        return true
    }

    func install(_ svg: SVG, request: String, position: Position? = nil,
                 onPositionChange: ((Position?) -> Void)? = nil) {
        if self.request != request {
            onViewportPositionChange = nil
            self.request = request
            content?.removeFromSuperview()
            let content = NSHostingView(rootView: NativeSVGDrawing(svg: svg))
            content.frame = CGRect(origin: .zero, size: svg.size)
            canvas.setFrameSize(svg.size)
            canvas.addSubview(content)
            self.content = content
            restorePosition(position)
        }
        onViewportPositionChange = onPositionChange
    }

    func clear() {
        onViewportPositionChange = nil
        content?.removeFromSuperview()
        content = nil
        request = nil
        onFocused = {}
    }
}
