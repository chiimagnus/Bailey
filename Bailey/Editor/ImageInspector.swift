import AppKit
import SwiftUI

struct ImageInspector: View {
    let image: RasterPreview
    var loadOriginal: (() async throws -> RasterDetail)? = nil
    var showsCloseButton = false
    var playback: GIFPlayback? = nil
    var loadAnimation: (() async throws -> GIFPlayback.Frames)? = nil
    var resourceRevision = ""
    var annotationFile: FileTab? = nil
    var onFocused: () -> Void = {}
    var viewportPosition: PreviewScrollView.Position? = nil
    var onViewportPositionChange: ((PreviewScrollView.Position?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appearsActive) private var active
    @Environment(\.accessibilityPlayAnimatedImages) private var automaticallyPlays
    @State private var detailUnavailable = false
    @State private var annotationRenderFailed = false
    @State private var annotationCanvas = AnnotationCanvasTarget()

    private struct AnimationDemand: Hashable {
        let revision: String
        let playing: Bool
    }

    var body: some View {
        let paused = playback?.isPaused(automaticallyPlays: automaticallyPlays)
        let demand = AnimationDemand(revision: resourceRevision,
                                     playing: active && paused == false && loadAnimation != nil)
        let document = annotationFile?.imageAnnotations
        RasterViewport(target: annotationCanvas, image: image, loadOriginal: loadOriginal,
                       animationFrame: playback?.image, paused: loadAnimation == nil ? nil : paused,
                       toggleAnimation: playback.map { playback in
                           { playback.togglePause(automaticallyPlays: automaticallyPlays) }
                       },
                       resourceRevision: resourceRevision, viewportPosition: viewportPosition,
                       onViewportPositionChange: onViewportPositionChange,
                       annotationFile: annotationFile, annotationDocument: document, annotationState: document?.state,
                       annotationSelection: document?.selection ?? [],
                       annotationEditing: document?.isEditing == true,
                       canAnnotate: annotationFile?.canAnnotateImage == true,
                       onFocused: onFocused,
                       onAnnotationFailure: { annotationRenderFailed = $0 },
                       onDetailFailure: { detailUnavailable = $0 })
            .task(id: demand) {
                guard demand.playing, let playback, let loadAnimation else { return }
                await playback.play(automaticallyPlays: automaticallyPlays, load: loadAnimation)
            }
            .overlay(alignment: .top) {
                if let document, document.isEditing, annotationFile?.canAnnotateImage == true {
                    ImageAnnotationToolbar(document: document, focusCanvas: annotationCanvas.focus)
                        .padding(8)
                }
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
                if annotationRenderFailed {
                    Label(String(localized: "Could not render image annotations.", table: "Editor"),
                          systemImage: "exclamationmark.triangle")
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                        .padding(8)
                } else if detailUnavailable || playback?.failed == true {
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

private final class AnnotationCanvasTarget {
    weak var scroll: RasterScrollView?

    func focus() {
        guard let scroll else { return }
        scroll.window?.makeFirstResponder(scroll)
    }
}

private struct RasterViewport: NSViewRepresentable {
    let target: AnnotationCanvasTarget
    let image: RasterPreview
    let loadOriginal: (() async throws -> RasterDetail)?
    let animationFrame: CGImage?
    let paused: Bool?
    let toggleAnimation: (() -> Void)?
    let resourceRevision: String
    let viewportPosition: PreviewScrollView.Position?
    let onViewportPositionChange: ((PreviewScrollView.Position?) -> Void)?
    let annotationFile: FileTab?
    let annotationDocument: ImageAnnotationDocument?
    let annotationState: ImageAnnotationState?
    let annotationSelection: Set<UUID>
    let annotationEditing: Bool
    let canAnnotate: Bool
    let onFocused: () -> Void
    let onAnnotationFailure: (Bool) -> Void
    let onDetailFailure: (Bool) -> Void

    func makeNSView(context: Context) -> RasterScrollView {
        let scroll = RasterScrollView(frame: .zero)
        target.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: RasterScrollView, context: Context) {
        scroll.update(image, loadOriginal: loadOriginal, animationFrame: animationFrame,
                      paused: paused, toggleAnimation: toggleAnimation,
                      resourceRevision: resourceRevision, viewportPosition: viewportPosition,
                      onViewportPositionChange: onViewportPositionChange,
                      annotationFile: annotationFile, annotationDocument: annotationDocument, annotationState: annotationState,
                      annotationSelection: annotationSelection, annotationEditing: annotationEditing,
                      canAnnotate: canAnnotate, onFocused: onFocused,
                      onAnnotationFailure: onAnnotationFailure, onDetailFailure: onDetailFailure)
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

    override func accessibilityLabel() -> String? {
        isScalableVector
            ? String(localized: "SVG preview", table: "Editor")
            : String(localized: "Image preview", table: "Editor")
    }

    override func accessibilityValue() -> Any? { accessibilityZoomDescription }

    private var accessibilityZoomDescription: String {
        fitting ? String(localized: "Fit", table: "Editor")
            : Double(pixelScale).formatted(.percent.precision(.fractionLength(0)))
    }

    private func notifyAccessibilityZoomChange(from previous: String) {
        guard window != nil, accessibilityZoomDescription != previous else { return }
        NSAccessibility.post(element: self, notification: .valueChanged)
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

    var isScalableVector: Bool { false }
    var pixelScale: CGFloat { magnification * backingScale }
    fileprivate var hasViewportLayout: Bool { viewportSize != .zero }
    private var minimumManualMagnification: CGFloat { 0.1 / backingScale }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

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
        if fitting {
            fit()
        } else {
            minMagnification = minimumManualMagnification
            updateMaximumMagnification(preserving: oldPixelScale)
            if pixelScale != oldPixelScale { setZoom(oldPixelScale, at: center) }
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
        updateMaximumMagnification(preserving: saved.pixelScale)
        setZoom(saved.pixelScale, at: center)
        let bounds = contentView.bounds
        positionToRestore = nil
        scroll(to: CGPoint(x: saved.center.x - bounds.width / 2, y: saved.center.y - bounds.height / 2))
    }

    private var fitMagnification: CGFloat? {
        guard let size = documentView?.frame.size, size.width > 0, size.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let scale = min(viewportSize.width / size.width, viewportSize.height / size.height)
        return isScalableVector ? scale : min(1 / backingScale, scale)
    }

    private func updateMaximumMagnification(preserving pixelScale: CGFloat = 0) {
        // Vector documents are not constrained by their intrinsic pixel size.
        // Very small SVGs still need room to zoom beyond their fitted scale.
        maxMagnification = isScalableVector
            ? max(64 / backingScale, (fitMagnification ?? 0) * 4, pixelScale / backingScale)
            : 4 / backingScale
    }

    @objc func fit() {
        let previous = accessibilityZoomDescription
        defer { notifyAccessibilityZoomChange(from: previous) }
        fitting = true
        guard let size = documentView?.frame.size, let scale = fitMagnification else { return }
        updateMaximumMagnification()
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
        let previous = accessibilityZoomDescription
        defer { notifyAccessibilityZoomChange(from: previous) }
        fitting = false
        minMagnification = minimumManualMagnification
        setMagnification(scale / backingScale, centeredAt: anchor)
    }

    override func magnify(with event: NSEvent) {
        let previous = accessibilityZoomDescription
        defer { notifyAccessibilityZoomChange(from: previous) }
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

private final class RasterScrollView: PreviewScrollView, NSMenuItemValidation {
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
    private lazy var annotationMenuItem = NSMenuItem(title: "", action: #selector(toggleAnnotations), keyEquivalent: "")
    private weak var annotationDocument: ImageAnnotationDocument?
    private weak var annotationFile: FileTab?
    private var outputTask: Task<Void, Never>?
    private weak var outputSheet: NSWindow?
    private lazy var copyMenuItem = NSMenuItem(title: String(localized: "Copy Annotated Image", table: "Editor"),
                                              action: #selector(copyAnnotations), keyEquivalent: "")
    private lazy var exportMenuItem = NSMenuItem(title: String(localized: "Export Annotated Image…", table: "Editor"),
                                                action: #selector(exportAnnotations), keyEquivalent: "")
    private var canAnnotate = false
    private var onFocused: (() -> Void)?
    private var onAnnotationFailure: ((Bool) -> Void)?
    private var annotationDragStart: CGPoint?
    private var annotationDragTool: ImageAnnotationTool?
    private var penSamples: [CGPoint] = []
    private var annotationTask: Task<Void, Never>?
    private struct AnnotationDemand: Equatable {
        let state: ImageAnnotationState
        let poster: ObjectIdentifier
        let detail: ObjectIdentifier?
        let scale: CGFloat
        let region: CGRect
    }
    private var annotationDemand: AnnotationDemand?
    private var annotationFailure = false

    override var undoManager: UndoManager? {
        annotationDocument?.canMutate == true ? annotationDocument?.undoManager : super.undoManager
    }

    private var focusedAnnotationUndoManager: UndoManager? {
        guard window?.firstResponder === self, canAnnotate,
              let document = annotationDocument, document.canMutate else { return nil }
        return document.undoManager
    }

    @objc func undo(_ sender: Any?) {
        guard let manager = focusedAnnotationUndoManager, manager.canUndo else { return }
        manager.undo()
        syncAnnotationState()
    }

    @objc func redo(_ sender: Any?) {
        guard let manager = focusedAnnotationUndoManager, manager.canRedo else { return }
        manager.redo()
        syncAnnotationState()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): focusedAnnotationUndoManager?.canUndo == true
        case #selector(redo(_:)): focusedAnnotationUndoManager?.canRedo == true
        default: true
        }
    }

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
                annotationFile: FileTab?, annotationDocument: ImageAnnotationDocument?, annotationState: ImageAnnotationState?,
                annotationSelection: Set<UUID>, annotationEditing: Bool, canAnnotate: Bool,
                onFocused: @escaping () -> Void, onAnnotationFailure: @escaping (Bool) -> Void,
                onDetailFailure: @escaping (Bool) -> Void) {
        self.loadOriginal = loadOriginal
        self.onDetailFailure = onDetailFailure
        self.toggleAnimation = toggleAnimation
        self.onFocused = onFocused
        self.onAnnotationFailure = onAnnotationFailure
        if self.annotationDocument !== annotationDocument || self.canAnnotate != canAnnotate
            || self.annotationFile !== annotationFile {
            cancelAnnotationDrag()
            cancelOutput()
        }
        self.annotationFile = annotationFile
        self.annotationDocument = annotationDocument
        self.canAnnotate = canAnnotate
        canvas.annotationEditing = annotationEditing && canAnnotate
        canvas.annotationSelection = annotationSelection
        if canvas.annotationState != annotationState {
            canvas.annotationState = annotationState
            invalidateAnnotationRendering()
        }
        if canAnnotate {
            annotationMenuItem.title = annotationEditing
                ? String(localized: "Finish Annotations", table: "Editor")
                : String(localized: "Annotate Image", table: "Editor")
            if annotationMenuItem.menu == nil {
                annotationMenuItem.target = self
                menu?.addItem(annotationMenuItem)
            }
            if copyMenuItem.menu == nil {
                copyMenuItem.target = self
                menu?.addItem(copyMenuItem)
            }
            if exportMenuItem.menu == nil {
                exportMenuItem.target = self
                menu?.addItem(exportMenuItem)
            }
        } else {
            annotationMenuItem.menu?.removeItem(annotationMenuItem)
            copyMenuItem.menu?.removeItem(copyMenuItem)
            exportMenuItem.menu?.removeItem(exportMenuItem)
        }
        let changedResource = self.resourceRevision != resourceRevision
        self.resourceRevision = resourceRevision
        if thumbnail !== image.poster {
            self.onViewportPositionChange = nil
            resetDetail()
            invalidateAnnotationRendering()
            thumbnail = image.poster
            canvas.image = image.poster
            canvas.setFrameSize(image.pixelSize)
            restorePosition(viewportPosition)
        } else if changedResource {
            cancelOutput()
            cancelAnnotationDrag()
            invalidateAnnotationRendering()
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
        updateAnnotationDemand()
    }

    private func cancelOutput() {
        outputTask?.cancel()
        outputTask = nil
        if let sheet = outputSheet { sheet.sheetParent?.endSheet(sheet, returnCode: .cancel) }
        outputSheet = nil
    }

    @objc private func copyAnnotations() {
        guard annotationDocument?.canMutate == true, canAnnotate, outputTask == nil, outputSheet == nil,
              let file = annotationFile, annotationDocument?.textEdit == nil else { return }
        let request = file.fileContentRevision
        runOutput(request: request, failureTitle: String(localized: "Could not copy image.", table: "Editor")) {
            try await file.copyAnnotatedImage(request: request)
        }
    }

    @objc private func exportAnnotations() {
        guard annotationDocument?.canMutate == true, canAnnotate, outputTask == nil, outputSheet == nil, let file = annotationFile,
              let document = annotationDocument, document.textEdit == nil, let window else { return }
        let request = file.fileContentRevision
        let settings = ImageAnnotationExportSettings(size: document.state.crop?.size ?? document.size)
        let accessory = NSHostingView(rootView: ImageAnnotationExportOptionsView(settings: settings))
        accessory.frame.size = accessory.fittingSize
        let alert = NSAlert()
        alert.messageText = String(localized: "Export Annotated Image…", table: "Editor")
        alert.accessoryView = accessory
        alert.addButton(withTitle: String(localized: "Continue", table: "Editor"))
        alert.addButton(withTitle: String(localized: "Cancel", table: "Editor"))
        outputSheet = alert.window
        alert.beginSheetModal(for: window) { [weak self, weak file] response in
            guard let self, let file, self.annotationFile === file, self.resourceRevision == request else { return }
            self.outputSheet = nil
            guard response == .alertFirstButtonReturn else { return }
            guard let options = settings.options else {
                self.showOutputError(String(localized: "Invalid image export settings.", table: "Editor"))
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [options.format.type]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = (file.name as NSString).deletingPathExtension + "-annotated." + options.format.fileExtension
            panel.message = String(localized: "Export a flattened image without modifying the original or its annotations.", table: "Editor")
            self.outputSheet = panel
            panel.beginSheetModal(for: window) { [weak self, weak file] response in
                guard let self, let file, self.annotationFile === file, self.resourceRevision == request else { return }
                self.outputSheet = nil
                guard response == .OK, let destination = panel.url else { return }
                self.runOutput(request: request, failureTitle: String(localized: "Could not export image.", table: "Editor")) { [weak self] in
                    let target = try await file.prepareAnnotationExport(request: request, options: options, to: destination)
                    guard let self, !Task.isCancelled, self.resourceRevision == request else { return }
                    if target.replacesExistingFile {
                        let confirmation = NSAlert()
                        confirmation.alertStyle = .warning
                        confirmation.messageText = String(localized: "Replace existing export?", table: "Editor")
                        confirmation.informativeText = target.path
                        confirmation.addButton(withTitle: String(localized: "Replace", table: "Editor"))
                        confirmation.addButton(withTitle: String(localized: "Cancel", table: "Editor"))
                        self.outputSheet = confirmation.window
                        let response = await confirmation.beginSheetModal(for: window)
                        guard self.outputSheet === confirmation.window, !Task.isCancelled,
                              self.resourceRevision == request else { return }
                        self.outputSheet = nil
                        guard response == .alertFirstButtonReturn else { return }
                    }
                    try await file.exportAnnotatedImage(request: request, options: options, to: destination,
                                                        confirmedTarget: target)
                }
            }
        }
    }

    private func runOutput(request: String, failureTitle: String,
                           _ operation: @escaping @MainActor () async throws -> Void) {
        outputTask = Task { @MainActor [weak self] in
            do {
                try await operation()
            } catch {
                if !Task.isCancelled, self?.resourceRevision == request {
                    self?.showOutputError(error.localizedDescription, title: failureTitle)
                }
            }
            if !Task.isCancelled, self?.resourceRevision == request { self?.outputTask = nil }
        }
    }

    private func showOutputError(_ message: String,
                                 title: String = String(localized: "Could not export image.", table: "Editor")) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in }
    }

    @objc private func toggleAnnotations() {
        guard annotationDocument?.canMutate == true, canAnnotate, let document = annotationDocument else { return }
        onFocused?()
        window?.makeFirstResponder(self)
        if document.isEditing { document.finish() }
        else { document.begin() }
        syncAnnotationState()
    }

    private func syncAnnotationState() {
        canvas.annotationSelection = annotationDocument?.selection ?? []
        canvas.annotationEditing = canAnnotate && annotationDocument?.isEditing == true
        let state = annotationDocument?.state
        if canvas.annotationState != state {
            canvas.annotationState = state
            invalidateAnnotationRendering()
        }
        updateAnnotationDemand()
    }

    private func cancelAnnotationDrag() {
        annotationDragStart = nil
        annotationDragTool = nil
        penSamples.removeAll(keepingCapacity: true)
        canvas.transientAnnotation = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard annotationDocument?.textEdit == nil else { return }
        onFocused?()
        guard annotationDocument?.canMutate == true, canAnnotate, let document = annotationDocument, document.isEditing,
              !event.modifierFlags.contains(.option) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let point = canvas.convert(event.locationInWindow, from: nil)
        guard canvas.bounds.contains(point) else { return }
        if document.tool == .select {
            if event.clickCount == 2 {
                document.editSelectedText(at: point)
                syncAnnotationState()
                return
            }
            document.select(at: point, tolerance: 6 / max(magnification, 0.01),
                            extending: event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command))
        }
        annotationDragStart = point
        annotationDragTool = document.tool
        syncAnnotationState()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let first = annotationDragStart else {
            super.mouseDragged(with: event)
            return
        }
        guard annotationDocument?.canMutate == true, canAnnotate, let document = annotationDocument, document.isEditing,
              document.tool == annotationDragTool else { cancelAnnotationDrag(); return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        if annotationDragTool == .pen, point != (penSamples.last ?? first) {
            if penSamples.count == ImageAnnotationLayer.maximumPenPoints - 2 {
                penSamples = stride(from: 0, to: penSamples.count, by: 2).map { penSamples[$0] }
            }
            penSamples.append(point)
        }
        canvas.transientAnnotation = document.proposedGesture(from: first, to: point, via: penSamples)
    }

    override func mouseUp(with event: NSEvent) {
        guard let first = annotationDragStart else {
            super.mouseUp(with: event)
            return
        }
        defer { cancelAnnotationDrag(); syncAnnotationState() }
        guard annotationDocument?.canMutate == true, canAnnotate, let document = annotationDocument, document.isEditing,
              document.tool == annotationDragTool else { return }
        let previousCount = document.state.layers.count
        document.commitGesture(from: first, to: canvas.convert(event.locationInWindow, from: nil), via: penSamples)
        if document.tool == .pen, previousCount == document.state.layers.count {
            showOutputError(String(localized: "Delete a stroke or export a copy before adding more ink.", table: "Editor"),
                            title: String(localized: "Pen limit reached", table: "Editor"))
        }
    }

    override func keyDown(with event: NSEvent) {
        guard window?.firstResponder === self, canAnnotate, let document = annotationDocument,
              document.canMutate, document.isEditing, document.textEdit == nil else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53:
            cancelAnnotationDrag()
            document.cancel()
        case 51, 117:
            document.removeSelection()
        default:
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
            guard modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
                  let tool = ImageAnnotationTool.allCases.first(where: { $0.shortcut == key }) else {
                super.keyDown(with: event)
                return
            }
            if document.tool != tool {
                cancelAnnotationDrag()
                document.tool = tool
            }
        }
        syncAnnotationState()
    }

    private func invalidateAnnotationRendering() {
        annotationTask?.cancel()
        annotationTask = nil
        annotationDemand = nil
        canvas.annotationComposite = nil
        setAnnotationFailure(false)
    }

    private func setAnnotationFailure(_ failed: Bool) {
        guard annotationFailure != failed else { return }
        annotationFailure = failed
        // Do not mutate SwiftUI state during NSViewRepresentable.update.
        Task { [weak self] in
            guard let self else { return }
            self.onAnnotationFailure?(self.annotationFailure)
        }
    }

    private func updateAnnotationDemand() {
        guard window != nil, hasViewportLayout, let state = canvas.annotationState,
              state.hasFilters, let thumbnail, !visibleImageRect.isEmpty else {
            if annotationDemand != nil { invalidateAnnotationRendering() }
            return
        }
        let visible = visibleImageRect
        let region = visible.insetBy(dx: -visible.width / 4,
                                    dy: -visible.height / 4).integral.intersection(canvas.bounds)
        let scale = min(pixelScale, 1)
        let detail = canvas.patch
        let original = self.detail
        let next = AnnotationDemand(state: state, poster: ObjectIdentifier(thumbnail),
                                    detail: detail.map { ObjectIdentifier($0.image) },
                                    scale: scale, region: region)
        if let current = annotationDemand, current.state == state, current.poster == next.poster,
           current.detail == next.detail, current.scale == scale,
           current.region.contains(visible) { return }
        invalidateAnnotationRendering()
        annotationDemand = next
        let poster = RasterDetail.Patch(image: thumbnail, rect: canvas.bounds)
        annotationTask = Task { [weak self] in
            do {
                let patch = try await ImageAnnotationDrawing.preview(state, poster: poster, detail: detail,
                                                                    region: region, scale: scale, original: original)
                guard !Task.isCancelled, let self, self.annotationDemand == next else { return }
                self.annotationTask = nil
                self.canvas.annotationComposite = patch
            } catch {
                guard !Task.isCancelled, let self, self.annotationDemand == next else { return }
                self.annotationTask = nil
                self.setAnnotationFailure(true)
            }
        }
    }

    @objc private func togglePlayback() { toggleAnimation?() }

    override func reflectScrolledClipView(_ clip: NSClipView) {
        super.reflectScrolledClipView(clip)
        updateDetailDemand()
        updateAnnotationDemand()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelAnnotationDrag()
            invalidateAnnotationRendering()
            resetDetail()
            if canvas.image !== thumbnail { canvas.image = thumbnail }
        } else {
            updateAnnotationDemand()
        }
    }

    func retire() {
        thumbnail = nil
        loadOriginal = nil
        onDetailFailure = nil
        toggleAnimation = nil
        onViewportPositionChange = nil
        animationMenuItem.menu?.removeItem(animationMenuItem)
        annotationMenuItem.menu?.removeItem(annotationMenuItem)
        copyMenuItem.menu?.removeItem(copyMenuItem)
        exportMenuItem.menu?.removeItem(exportMenuItem)
        cancelOutput()
        annotationFile = nil
        cancelAnnotationDrag()
        invalidateAnnotationRendering()
        annotationDocument = nil
        canAnnotate = false
        canvas.annotationState = nil
        canvas.annotationSelection = []
        canvas.annotationEditing = false
        onFocused = nil
        onAnnotationFailure = nil
        resetDetail()
        canvas.image = nil
    }

    private func resetDetail() {
        detailTask?.cancel()
        detailTask = nil
        detail = nil
        if canvas.patch != nil {
            canvas.patch = nil
            updateAnnotationDemand()
        }
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
                    self.updateAnnotationDemand()
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
    var annotationState: ImageAnnotationState? {
        didSet { if annotationState != oldValue { needsDisplay = true } }
    }
    var transientAnnotation: ImageAnnotationState? {
        didSet { if transientAnnotation != oldValue { needsDisplay = true } }
    }
    var annotationSelection: Set<UUID> = [] {
        didSet { if annotationSelection != oldValue { needsDisplay = true } }
    }
    var annotationEditing = false {
        didSet { if annotationEditing != oldValue { needsDisplay = true } }
    }
    var annotationComposite: RasterDetail.Patch? { didSet { needsDisplay = true } }
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
        if let state = transientAnnotation ?? annotationState {
            if transientAnnotation == nil, let composite = annotationComposite {
                context.saveGState()
                context.addRects([bounds, composite.rect])
                context.clip(using: .evenOdd)
                ImageAnnotationDrawing.drawPending(state, in: context)
                context.restoreGState()
                context.saveGState()
                context.clip(to: composite.rect)
                checker.setFill()
                composite.rect.fill()
                context.draw(composite.image, in: composite.rect)
                context.restoreGState()
            } else {
                ImageAnnotationDrawing.drawPending(state, in: context)
            }
            ImageAnnotationDrawing.drawGuides(state, selection: annotationSelection,
                editing: annotationEditing, bounds: bounds,
                magnification: enclosingScrollView?.magnification ?? 1, in: context)
        }
    }
}
