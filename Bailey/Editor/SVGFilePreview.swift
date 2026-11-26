import AppKit
import Observation
import SwiftDraw
import SwiftUI
import UniformTypeIdentifiers

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
                    NativeSVGViewport(file: file, svg: drawing.artwork.image, request: drawing.request,
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
    let file: FileTab
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
        scroll.setOutputTarget(file, request: file.svgOutputDrawing(request: request) == nil ? nil : request)
    }

    static func dismantleNSView(_ scroll: SVGPreviewScrollView, coordinator: ()) { scroll.clear() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SVGPreviewScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

private final class NativeSVGDrawing: NSView {
    private let svg: SVG

    init(svg: SVG) {
        self.svg = svg
        super.init(frame: CGRect(origin: .zero, size: svg.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Draw the visible region at the current device resolution, not the
        // SVG's intrinsic size. A separate bitmap has a known pattern origin
        // and avoids AppKit's differing base transforms for layers and snapshots.
        let visible = bounds.intersection(dirtyRect).intersection(context.boundingBoxOfClipPath)
        guard !visible.isEmpty else { return }
        let pixels = context.convertToDeviceSpace(visible).standardized.integral
        guard !pixels.isEmpty, !pixels.isInfinite else { return }
        let region = context.convertToUserSpace(pixels).standardized
        let scale = CGAffineTransform(scaleX: pixels.width / region.width,
                                      y: pixels.height / region.height)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let drawing = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let destination = bounds.offsetBy(dx: -region.minX, dy: -region.minY).applying(scale)
        drawing.draw(SVGArtwork.drawing(svg, in: destination))
        guard let image = drawing.makeImage() else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.interpolationQuality = .none
        context.draw(image, in: region)
        context.restoreGState()
    }
}

@Observable
private final class SVGPNGSettings {
    var width: String
    var height: String
    var colorSpace: SVGArtwork.PNGOptions.ColorSpace = .sRGB
    var background: SVGArtwork.PNGOptions.Background = .transparent

    init(size: CGSize) {
        width = String(max(1, Int(size.width.rounded(.down))))
        height = String(max(1, Int(size.height.rounded(.down))))
    }

    var options: SVGArtwork.PNGOptions? {
        guard let width = Int(width), let height = Int(height) else { return nil }
        let result = SVGArtwork.PNGOptions(width: width, height: height, colorSpace: colorSpace, background: background)
        return result.isValid ? result : nil
    }
}

private struct SVGPNGOptionsView: View {
    @Bindable var settings: SVGPNGSettings

    var body: some View {
        VStack(alignment: .leading) {
            Grid(alignment: .leading) {
                GridRow {
                    Text("Pixel width", tableName: "Editor")
                    TextField(String(localized: "Pixel width", table: "Editor"), text: $settings.width).labelsHidden()
                }
                GridRow {
                    Text("Pixel height", tableName: "Editor")
                    TextField(String(localized: "Pixel height", table: "Editor"), text: $settings.height).labelsHidden()
                }
                GridRow {
                    Text("Color space", tableName: "Editor")
                    Picker(String(localized: "Color space", table: "Editor"), selection: $settings.colorSpace) {
                        Text("sRGB").tag(SVGArtwork.PNGOptions.ColorSpace.sRGB)
                        Text("Display P3").tag(SVGArtwork.PNGOptions.ColorSpace.displayP3)
                    }.labelsHidden()
                }
                GridRow {
                    Text("Background", tableName: "Editor")
                    Picker(String(localized: "Background", table: "Editor"), selection: $settings.background) {
                        Text("Transparent", tableName: "Editor").tag(SVGArtwork.PNGOptions.Background.transparent)
                        Text("White", tableName: "Editor").tag(SVGArtwork.PNGOptions.Background.white)
                        Text("Black", tableName: "Editor").tag(SVGArtwork.PNGOptions.Background.black)
                    }.labelsHidden()
                }
            }
            Text("SVG export preserves aspect ratio. Maximum 8 million pixels.", tableName: "Editor")
                .font(.caption).foregroundStyle(.secondary)
            if settings.options == nil {
                Text("Invalid PNG dimensions.", tableName: "Editor").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(8)
        .frame(width: 320, alignment: .leading)
    }
}

final class SVGPreviewScrollView: PreviewScrollView {
    private let canvas = PreviewCanvasView()
    private var request: String?
    private var content: NativeSVGDrawing?
    var onFocused: () -> Void = {}
    private weak var outputFile: FileTab?
    private var outputRequest: String?
    private var outputTask: Task<Void, Never>?
    private weak var outputSheet: NSWindow?

    init() {
        super.init(frame: .zero)
        documentView = canvas
        setAccessibilityIdentifier("bailey.svg.preview")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isScalableVector: Bool { true }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        // Repaint visible vectors at the new device scale/position instead
        // of reusing AppKit's previously drawn scroll contents.
        if let content { content.setNeedsDisplay(content.visibleRect) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let content { content.setNeedsDisplay(content.visibleRect) }
    }

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
            let content = NativeSVGDrawing(svg: svg)
            canvas.setFrameSize(svg.size)
            canvas.addSubview(content)
            self.content = content
            restorePosition(position)
        }
        onViewportPositionChange = onPositionChange
    }

    func setOutputTarget(_ file: FileTab?, request: String?) {
        guard outputFile !== file || outputRequest != request else { return }
        outputTask?.cancel()
        outputTask = nil
        if let sheet = outputSheet { sheet.sheetParent?.endSheet(sheet, returnCode: .cancel) }
        outputSheet = nil
        if outputFile?.graphicViewport === self, outputFile !== file { outputFile?.graphicViewport = nil }
        outputFile = file
        file?.graphicViewport = self
        outputRequest = request
        let actions = [#selector(copyPNG), #selector(exportPNG)]
        if let menu {
            for item in menu.items where item.action.map(actions.contains) == true { menu.removeItem(item) }
            if request != nil, file != nil {
                menu.addItem(withTitle: String(localized: "Copy PNG…", table: "Editor"),
                             action: #selector(copyPNG), keyEquivalent: "").target = self
                menu.addItem(withTitle: String(localized: "Export PNG…", table: "Editor"),
                             action: #selector(exportPNG), keyEquivalent: "").target = self
            }
        }
    }

    @objc private func copyPNG() { presentOutput(exporting: false) }
    @objc private func exportPNG() { presentOutput(exporting: true) }

    private func presentOutput(exporting: Bool) {
        guard outputTask == nil, outputSheet == nil, let window, let file = outputFile,
              let request = outputRequest, let artwork = file.svgOutputDrawing(request: request) else { return }
        let settings = SVGPNGSettings(size: artwork.image.size)
        let accessory = NSHostingView(rootView: SVGPNGOptionsView(settings: settings))
        accessory.frame.size = accessory.fittingSize
        if exporting {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension + ".png"
            panel.message = String(localized: "Export PNG to a new local file. Existing files are not replaced.", table: "Editor")
            panel.accessoryView = accessory
            outputSheet = panel
            panel.beginSheetModal(for: window) { [weak self, weak file] response in
                guard let self, let file, self.outputRequest == request, self.outputFile === file else { return }
                self.outputSheet = nil
                guard response == .OK, let destination = panel.url else { return }
                self.runOutput(file, request: request, settings: settings, destination: destination)
            }
        } else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Copy PNG…", table: "Editor")
            alert.accessoryView = accessory
            alert.addButton(withTitle: String(localized: "Copy", table: "Editor"))
            alert.addButton(withTitle: String(localized: "Cancel", table: "Editor"))
            outputSheet = alert.window
            alert.beginSheetModal(for: window) { [weak self, weak file] response in
                guard let self, let file, self.outputRequest == request, self.outputFile === file else { return }
                self.outputSheet = nil
                guard response == .alertFirstButtonReturn else { return }
                self.runOutput(file, request: request, settings: settings, destination: nil)
            }
        }
    }

    private func runOutput(_ file: FileTab, request: String, settings: SVGPNGSettings, destination: URL?) {
        guard let options = settings.options else {
            showOutputError(String(localized: "Invalid PNG dimensions.", table: "Editor"))
            return
        }
        outputTask = Task { @MainActor [weak self] in
            do {
                if let destination { try await file.exportSVGPNG(request: request, options: options, to: destination) }
                else { try await file.copySVGPNG(request: request, options: options) }
            } catch {
                if !Task.isCancelled, self?.outputRequest == request {
                    self?.showOutputError(error.localizedDescription)
                }
            }
            if !Task.isCancelled, self?.outputRequest == request { self?.outputTask = nil }
        }
    }

    private func showOutputError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not output PNG.", table: "Editor")
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in }
    }

    func clear() {
        setOutputTarget(nil, request: nil)
        onViewportPositionChange = nil
        content?.removeFromSuperview()
        content = nil
        request = nil
        onFocused = {}
    }
}
