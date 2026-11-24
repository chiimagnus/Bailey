import AppKit
import SwiftUI

struct ImageInspector: View {
    let image: RasterPreview
    var loadOriginal: (() async throws -> RasterDetail)? = nil
    var showsCloseButton = false
    var playback: GIFPlayback? = nil
    var loadAnimation: (() async throws -> GIFPlayback.Frames)? = nil
    var resourceRevision = ""
    var viewportPosition: PreviewScrollView.Position? = nil
    var onViewportPositionChange: ((PreviewScrollView.Position?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appearsActive) private var active
    @State private var detailUnavailable = false

    private struct AnimationDemand: Hashable {
        let revision: String
        let playing: Bool
    }

    var body: some View {
        let demand = AnimationDemand(revision: resourceRevision,
                                     playing: active && playback?.paused == false && loadAnimation != nil)
        RasterViewport(image: image, loadOriginal: loadOriginal,
                       animationFrame: playback?.image, paused: loadAnimation == nil ? nil : playback?.paused,
                       toggleAnimation: playback.map { playback in { playback.togglePause() } },
                       resourceRevision: resourceRevision, viewportPosition: viewportPosition,
                       onViewportPositionChange: onViewportPositionChange,
                       onDetailFailure: { detailUnavailable = $0 })
            .task(id: demand) {
                guard demand.playing, let playback, let loadAnimation else { return }
                await playback.play(load: loadAnimation)
            }
            .overlay(alignment: .topTrailing) {
                if showsCloseButton {
                    Button(String(localized: "Done", table: "Editor")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("bailey.image.close")
                        .padding(12)
                }
            }
            .overlay(alignment: .bottom) {
                if detailUnavailable || playback?.failed == true {
                    Label(playback?.failed == true
                          ? String(localized: "Could not play this GIF.", table: "Editor")
                          : String(localized: "Could not load original image pixels."),
                          systemImage: "exclamationmark.triangle")
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                        .padding(8)
                }
            }
    }
}

private struct RasterViewport: NSViewRepresentable {
    let image: RasterPreview
    let loadOriginal: (() async throws -> RasterDetail)?
    let animationFrame: CGImage?
    let paused: Bool?
    let toggleAnimation: (() -> Void)?
    let resourceRevision: String
    let viewportPosition: PreviewScrollView.Position?
    let onViewportPositionChange: ((PreviewScrollView.Position?) -> Void)?
    let onDetailFailure: (Bool) -> Void

    func makeNSView(context: Context) -> RasterScrollView {
        RasterScrollView(frame: .zero)
    }

    func updateNSView(_ scroll: RasterScrollView, context: Context) {
        scroll.update(image, loadOriginal: loadOriginal, animationFrame: animationFrame,
                      paused: paused, toggleAnimation: toggleAnimation,
                      resourceRevision: resourceRevision, viewportPosition: viewportPosition,
                      onViewportPositionChange: onViewportPositionChange,
                      onDetailFailure: onDetailFailure)
    }

    static func dismantleNSView(_ scroll: RasterScrollView, coordinator: ()) {
        scroll.retire()
    }
}

class PreviewScrollView: NSScrollView {
    struct Position {
        let pixelScale: CGFloat
        let center: CGPoint
    }

    private var fitting = true
    private var positionToRestore: Position?
    private var viewportSize = CGSize.zero
    private var backingScale: CGFloat = 1
    var onViewportPositionChange: ((Position?) -> Void)?
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
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        menu?.items.compactMap { item in
            guard item.target === self, item.action != nil else { return nil }
            let title = item.title
            return NSAccessibilityCustomAction(name: title) { [weak self, weak item] in
                guard let self, let item, item.menu === self.menu, item.title == title,
                      let action = item.action else { return false }
                return NSApp.sendAction(action, to: self, from: item)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var pixelScale: CGFloat { magnification * backingScale }
    fileprivate var hasViewportLayout: Bool { viewportSize != .zero }
    private var minimumManualMagnification: CGFloat { 0.1 / backingScale }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        updateViewport()
        restorePositionWhenReady()
    }

    override func reflectScrolledClipView(_ clip: NSClipView) {
        super.reflectScrolledClipView(clip)
        if window != nil { onViewportPositionChange?(position) }
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

    var position: Position? {
        positionToRestore ?? (fitting ? nil : Position(pixelScale: pixelScale, center: center))
    }

    func restorePosition(_ saved: Position?) {
        positionToRestore = saved
        if saved == nil {
            fit()
        } else {
            restorePositionWhenReady()
        }
    }

    private func restorePositionWhenReady() {
        guard let saved = positionToRestore, window != nil, viewportSize != .zero else { return }
        setZoom(saved.pixelScale, at: center)
        let bounds = contentView.bounds
        positionToRestore = nil
        scroll(to: CGPoint(x: saved.center.x - bounds.width / 2, y: saved.center.y - bounds.height / 2))
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
    private var loadOriginal: (() async throws -> RasterDetail)?
    private var onDetailFailure: ((Bool) -> Void)?
    private var detailTask: Task<Void, Never>?
    private var detail: RasterDetail?
    private var detailFailed = false
    private var resourceRevision = ""
    private var toggleAnimation: (() -> Void)?
    private lazy var animationMenuItem = NSMenuItem(title: "", action: #selector(togglePlayback), keyEquivalent: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        documentView = canvas
        setAccessibilityIdentifier("bailey.image.inspector")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(_ image: RasterPreview, loadOriginal: (() async throws -> RasterDetail)?,
                animationFrame: CGImage?, paused: Bool?, toggleAnimation: (() -> Void)?,
                resourceRevision: String, viewportPosition: Position?, onViewportPositionChange: ((Position?) -> Void)?,
                onDetailFailure: @escaping (Bool) -> Void) {
        self.loadOriginal = loadOriginal
        self.onDetailFailure = onDetailFailure
        self.toggleAnimation = toggleAnimation
        let changedResource = self.resourceRevision != resourceRevision
        self.resourceRevision = resourceRevision
        if thumbnail !== image.poster {
            self.onViewportPositionChange = nil
            resetDetail()
            thumbnail = image.poster
            canvas.image = image.poster
            canvas.setFrameSize(image.pixelSize)
            restorePosition(viewportPosition)
        } else if changedResource {
            resetDetail()
        }
        self.onViewportPositionChange = onViewportPositionChange
        if let paused {
            let frame = animationFrame ?? image.poster
            if canvas.image !== frame { canvas.image = frame }
            animationMenuItem.title = paused ? String(localized: "Resume Animation", table: "Editor")
                : String(localized: "Pause Animation", table: "Editor")
            if animationMenuItem.menu == nil {
                animationMenuItem.target = self
                menu?.addItem(animationMenuItem)
            }
        } else if animationMenuItem.menu != nil {
            menu?.removeItem(animationMenuItem)
        }
        updateDetailDemand()
    }

    @objc private func togglePlayback() { toggleAnimation?() }

    override func reflectScrolledClipView(_ clip: NSClipView) {
        super.reflectScrolledClipView(clip)
        updateDetailDemand()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            resetDetail()
            if canvas.image !== thumbnail { canvas.image = thumbnail }
        }
    }

    func retire() {
        thumbnail = nil
        loadOriginal = nil
        onDetailFailure = nil
        toggleAnimation = nil
        onViewportPositionChange = nil
        animationMenuItem.menu?.removeItem(animationMenuItem)
        resetDetail()
        canvas.image = nil
    }

    private func resetDetail() {
        detailTask?.cancel()
        detailTask = nil
        detail = nil
        if canvas.patch != nil { canvas.patch = nil }
        if detailFailed {
            detailFailed = false
            Task { [weak self] in
                guard let self else { return }
                self.onDetailFailure?(self.detailFailed)
            }
        }
    }

    private var visibleImageRect: CGRect {
        documentVisibleRect.intersection(canvas.bounds)
    }

    private func updateDetailDemand() {
        let size = canvas.bounds.size
        let visible = visibleImageRect
        guard window != nil, hasViewportLayout, !visible.isEmpty, let loadOriginal, let thumbnail,
              size.width * pixelScale > CGFloat(thumbnail.width)
                || size.height * pixelScale > CGFloat(thumbnail.height) else {
            if detailTask != nil || detail != nil || detailFailed { resetDetail() }
            return
        }
        guard detailTask == nil, !detailFailed,
              canvas.patch?.rect.contains(visible) != true else { return }
        detailTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let detail = if let existing = self?.detail { existing } else { try await loadOriginal() }
                guard !Task.isCancelled, let visible = self?.visibleImageRect else { return }
                guard !visible.isEmpty else {
                    self?.detailTask = nil
                    return
                }
                self?.detail = detail
                let requested = visible.insetBy(dx: -visible.width / 4, dy: -visible.height / 4)
                let patch = try await detail.render(requested)
                guard !Task.isCancelled, let self else { return }
                self.detailTask = nil
                let current = self.visibleImageRect
                if self.canvas.patch?.rect.contains(current) != true, patch.rect.intersects(current) {
                    self.canvas.patch = patch
                }
                self.updateDetailDemand()
            } catch is CancellationError {
                if !Task.isCancelled { self?.detailTask = nil }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.detailTask = nil
                self.detailFailed = true
                self.onDetailFailure?(true)
            }
        }
    }
}

class PreviewCanvasView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseDown(with event: NSEvent) { enclosingScrollView?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { enclosingScrollView?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { enclosingScrollView?.mouseUp(with: event) }
}

private final class RasterPreviewCanvas: PreviewCanvasView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var patch: RasterDetail.Patch? {
        didSet {
            if let oldValue { setNeedsDisplay(oldValue.rect) }
            if let patch { setNeedsDisplay(patch.rect) }
        }
    }
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
        if let patch {
            if patch.rect != bounds {
                context.saveGState()
                context.addRects([bounds, patch.rect])
                context.clip(using: .evenOdd)
                context.draw(image, in: bounds)
                context.restoreGState()
            }
            context.draw(patch.image, in: patch.rect)
        } else {
            context.draw(image, in: bounds)
        }
    }
}
