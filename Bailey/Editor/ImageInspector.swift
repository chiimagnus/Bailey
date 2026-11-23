import AppKit
import SwiftUI

struct ImageInspector: View {
    let image: RasterPreview
    var loadOriginal: (() async throws -> CGImage)? = nil
    var showsCloseButton = false
    @Environment(\.dismiss) private var dismiss
    @State private var detailUnavailable = false

    var body: some View {
        RasterViewport(image: image, loadOriginal: loadOriginal,
                       onDetailFailure: { detailUnavailable = $0 })
            .overlay(alignment: .topTrailing) {
                if showsCloseButton {
                    Button(String(localized: "Done", table: "Editor")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("bailey.image.close")
                        .padding(12)
                }
            }
            .overlay(alignment: .bottom) {
                if detailUnavailable {
                    Label("Could not load original image pixels.", systemImage: "exclamationmark.triangle")
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                        .padding(8)
                }
            }
    }
}

private struct RasterViewport: NSViewRepresentable {
    let image: RasterPreview
    let loadOriginal: (() async throws -> CGImage)?
    let onDetailFailure: (Bool) -> Void

    func makeNSView(context: Context) -> RasterScrollView {
        RasterScrollView(frame: .zero)
    }

    func updateNSView(_ scroll: RasterScrollView, context: Context) {
        scroll.update(image, loadOriginal: loadOriginal, onDetailFailure: onDetailFailure)
    }

    static func dismantleNSView(_ scroll: RasterScrollView, coordinator: ()) {
        scroll.resetDetail()
    }
}

class PreviewScrollView: NSScrollView {
    private var fitting = true
    private var viewportSize = CGSize.zero
    private var backingScale: CGFloat = 1
    private var dragPoint: CGPoint?
    private var dragOrigin: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteredPreviewClipView()
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        allowsMagnification = true
        let menu = NSMenu()
        let actions: [(String, Selector)] = [
            (String(localized: "Fit", table: "Editor"), #selector(fit)),
            ("100%", #selector(actualSize)),
            (String(localized: "Zoom in", table: "Editor"), #selector(zoomIn)),
            (String(localized: "Zoom out", table: "Editor"), #selector(zoomOut)),
        ]
        for (title, action) in actions {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        self.menu = menu
        setAccessibilityCustomActions(actions.map { title, action in
            NSAccessibilityCustomAction(name: title) { [weak self] in
                guard let self else { return false }
                _ = self.perform(action)
                return true
            }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var pixelScale: CGFloat { magnification * backingScale }
    private var minimumManualMagnification: CGFloat { 0.1 / backingScale }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        updateViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateViewport()
    }

    private func updateViewport() {
        let size = contentView.frame.size
        let scale = window?.backingScaleFactor ?? 1
        guard size.width > 0, size.height > 0,
              size != viewportSize || scale != backingScale else { return }
        let oldPixelScale = pixelScale
        viewportSize = size
        backingScale = scale
        if !fitting { minMagnification = minimumManualMagnification }
        maxMagnification = 4 / scale
        if fitting {
            fit()
        } else if pixelScale != oldPixelScale {
            setZoom(oldPixelScale, at: center)
        }
    }

    private var center: CGPoint {
        CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    }

    @objc func fit() {
        fitting = true
        guard let size = documentView?.frame.size, size.width > 0, size.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return }
        let scale = min(1 / backingScale, viewportSize.width / size.width, viewportSize.height / size.height)
        minMagnification = min(minimumManualMagnification, scale)
        magnification = scale
        let bounds = contentView.bounds
        scroll(to: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
    }

    @objc func actualSize() { setZoom(1, at: center) }
    @objc func zoomIn() { setZoom(pixelScale * 1.25, at: center) }
    @objc func zoomOut() {
        guard magnification > minimumManualMagnification else { return }
        setZoom(pixelScale / 1.25, at: center)
    }

    func setZoom(_ scale: CGFloat, at anchor: CGPoint) {
        fitting = false
        minMagnification = minimumManualMagnification
        setMagnification(scale / backingScale, centeredAt: anchor)
    }

    override func magnify(with event: NSEvent) {
        if fitting, magnification < minimumManualMagnification, event.magnification <= 0 { return }
        fitting = false
        minMagnification = minimumManualMagnification
        super.magnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 70 : 8)
        guard delta > 0 || (delta < 0 && magnification > minimumManualMagnification) else { return }
        setZoom(pixelScale * exp(delta), at: contentView.convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            if fitting {
                setZoom(1, at: contentView.convert(event.locationInWindow, from: nil))
            } else {
                fit()
            }
            return
        }
        dragPoint = event.locationInWindow
        dragOrigin = contentView.bounds.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragPoint, let dragOrigin else { return }
        scroll(to: CGPoint(
            x: dragOrigin.x - (event.locationInWindow.x - dragPoint.x) / magnification,
            y: dragOrigin.y - (event.locationInWindow.y - dragPoint.y) / magnification
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragPoint = nil
        dragOrigin = nil
    }

    private func scroll(to origin: CGPoint) {
        let bounds = contentView.constrainBoundsRect(CGRect(origin: origin, size: contentView.bounds.size))
        contentView.scroll(to: bounds.origin)
        reflectScrolledClipView(contentView)
    }
}

private final class CenteredPreviewClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        let frame = documentView.frame
        if bounds.width > frame.width { bounds.origin.x = frame.midX - bounds.width / 2 }
        if bounds.height > frame.height { bounds.origin.y = frame.midY - bounds.height / 2 }
        return bounds
    }
}

private final class RasterScrollView: PreviewScrollView {
    private let canvas = RasterPreviewCanvas()
    private var thumbnail: CGImage?
    private var loadOriginal: (() async throws -> CGImage)?
    private var onDetailFailure: ((Bool) -> Void)?
    private var detailTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        documentView = canvas
        setAccessibilityIdentifier("bailey.image.inspector")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(_ image: RasterPreview, loadOriginal: (() async throws -> CGImage)?,
                onDetailFailure: @escaping (Bool) -> Void) {
        self.loadOriginal = loadOriginal
        self.onDetailFailure = onDetailFailure
        if thumbnail !== image.poster {
            resetDetail()
            thumbnail = image.poster
            canvas.image = image.poster
            canvas.setFrameSize(image.pixelSize)
            fit()
        }
        updateDetailDemand()
    }

    override func reflectScrolledClipView(_ clip: NSClipView) {
        super.reflectScrolledClipView(clip)
        updateDetailDemand()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { resetDetail() }
    }

    func resetDetail() {
        detailTask?.cancel()
        detailTask = nil
        if canvas.image !== thumbnail { canvas.image = thumbnail }
    }

    private func updateDetailDemand() {
        guard window != nil, let loadOriginal, let thumbnail, canvas.bounds.width > 0,
              pixelScale > CGFloat(thumbnail.width) / canvas.bounds.width else { return }
        guard detailTask == nil else { return }
        detailTask = Task { [weak self] in
            do {
                let image = try await loadOriginal()
                guard !Task.isCancelled else { return }
                self?.canvas.image = image
                self?.onDetailFailure?(false)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.onDetailFailure?(true)
            }
        }
    }
}

private final class RasterPreviewCanvas: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    private let checker = NSColor(patternImage: NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        NSColor.quaternaryLabelColor.setFill()
        CGRect(x: 0, y: 0, width: 8, height: 8).fill()
        CGRect(x: 8, y: 8, width: 8, height: 8).fill()
        return true
    })

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        checker.setFill()
        dirtyRect.fill()
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
    }

    override func mouseDown(with event: NSEvent) { enclosingScrollView?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { enclosingScrollView?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { enclosingScrollView?.mouseUp(with: event) }
}
