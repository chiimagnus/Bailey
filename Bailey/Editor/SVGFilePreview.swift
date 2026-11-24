import AppKit
import SwiftDraw
import SwiftUI

struct SVGFilePreview: View {
    private enum Output {
        case image(SVGArtwork.Vector)
        case error(String)
    }

    let file: FileTab
    let onFocused: () -> Void
    let onShowSource: () -> Void
    @State private var rendered: (request: String, output: Output)?

    var body: some View {
        let request = file.textPreviewRequestID
        Group {
            if let rendered, rendered.request == request {
                switch rendered.output {
                case .image(let artwork):
                    VStack(spacing: 0) {
                        if !artwork.omitted.isEmpty {
                            let names = artwork.omitted.prefix(8).joined(separator: ", ")
                            notice(String(localized: "SVG preview omits: \(names)", table: "Editor"))
                        }
                        NativeSVGViewport(svg: artwork.image, request: request,
                                          viewportPosition: file.graphicViewportPosition,
                                          onViewportPositionChange: { position in
                            guard file.previewKind == .svg, case .text = file.content,
                                  file.textPreviewRequestID == request else { return }
                            file.graphicViewportPosition = position
                        }, onFocused: onFocused)
                    }
                case .error(let message):
                    notice(message).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: request) {
            let output: Output
            do {
                output = .image(try await Self.parse(file.text))
            } catch is CancellationError {
                return
            } catch WorkspaceError.tooLarge {
                output = .error(String(localized: "SVG is too large to preview. You can still edit the source.", table: "Editor"))
            } catch {
                output = .error(String(localized: "Could not display this SVG.", table: "Editor"))
            }
            guard !Task.isCancelled, request == file.textPreviewRequestID else { return }
            rendered = (request, output)
        }
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

    @concurrent private static func parse(_ text: String) async throws -> SVGArtwork.Vector {
        guard text.utf8.count <= SVGArtwork.byteLimit else { throw WorkspaceError.tooLarge }
        let artwork = try SVGArtwork.parse(Data(text.utf8))
        let size = artwork.image.size
        guard max(size.width, size.height) <= 32_768,
              size.width * size.height <= 8_000_000 else { throw WorkspaceError.tooLarge }
        return artwork
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
