//
//  SourceTextEditor.swift
//  kero
//

import AppKit
import STTextView
import SwiftUI

/// Scroll offset and cursor position of a file tab's editor, kept on the
/// `FileTab` so it survives tab switches, and in the session snapshot so it
/// survives relaunches. Optional fields represent state not yet captured.
struct EditorState: Codable, Equatable {
    var selectionLocation: Int?
    var selectionLength: Int?
    var scrollX: Double?
    var scrollY: Double?
}

/// Editor colors derived from the selected ghostty theme (`Theme.background`
/// is the same color, so the editor blends into the window). Selection color
/// is not included: STTextView always uses the system selection color.
struct EditorPalette: Equatable {
    var text: NSColor
    var background: NSColor
    var insertionPoint: NSColor
    var lineHighlight: NSColor
    var gutterText: NSColor

    static func theme(dark: Bool) -> EditorPalette {
        let theme = Theme.terminal(dark: dark)
        return EditorPalette(
            text: theme.foregroundNSColor,
            background: theme.backgroundNSColor,
            insertionPoint: theme.accentNSColor,
            lineHighlight: theme.surfaceNSColor(elevation: 0.04),
            gutterText: theme.surfaceNSColor(elevation: 0.3)
        )
    }
}

/// STTextView wrapped for SwiftUI: plain-text editing with line numbers and
/// the system search-and-replace find bar (⌘F / ⌥⌘F via the Edit ▸ Find menu,
/// routed here by `FileTab.performFindAction`). Text edits are written
/// straight back to `FileTab.text`; scroll/cursor state is written back to
/// `FileTab.editorState` as it changes and restored when the view is
/// restored on relaunch. The tab retains the native editor across remounts.
struct SourceTextEditor: NSViewRepresentable {
    let file: FileTab
    let font: NSFont
    let palette: EditorPalette
    let wrapLines: Bool
    var isFocused: Bool = true
    var onFocused: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        if let coordinator = file.editorCoordinator,
           coordinator.revision == file.reloadRevision {
            return coordinator
        }
        let coordinator = Coordinator(file: file)
        file.editorCoordinator = coordinator
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let scrollView = context.coordinator.scrollView ?? makeScrollView(coordinator: context.coordinator)
        if let textView = scrollView.documentView as? FocusReportingTextView {
            textView.onBecomeFirstResponder = onFocused
            textView.onResignFirstResponder = { [weak file] in file?.autoSaveOnFocusLoss() }
            apply(to: textView, scrollView: scrollView)
        }
        context.coordinator.wasFocused = isFocused
        file.editorView = scrollView
        let container = SourceEditorContainer(scrollView: scrollView)
        container.focusOnAttach = isFocused
        return container
    }

    private func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scrollView = RestorableScrollView()
        let textView = FocusReportingTextView()
        textView.onBecomeFirstResponder = onFocused
        textView.onResignFirstResponder = { [weak file] in file?.autoSaveOnFocusLoss() }
        scrollView.wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView

        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        // The window uses a full-size content view, so automatic insets
        // would add a titlebar-height top inset that misaligns the gutter
        // numbers against the text by one line.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        // The gutter is a document-height floating subview that scrolls
        // vertically with the text; since macOS 14 NSViews no longer clip
        // subviews by default, so without this the scrolled-away line
        // numbers draw outside the scroll view, over the header above it.
        scrollView.clipsToBounds = true

        // Configure typography before setting the text: the font/color
        // setters restyle the whole document, and restyling after layout
        // used to leave stale layout fragments that broke gutter numbering.
        textView.showsLineNumbers = true
        textView.highlightSelectedLine = true
        // Highlight every match as the query is typed in the find bar, the way
        // the terminal's find bar searches as you type. Off by default in
        // STTextView.
        textView.isIncrementalSearchingEnabled = true
        apply(to: textView, scrollView: scrollView)
        textView.text = file.text

        // Tree-sitter syntax highlighting, for file types with
        // a bundled grammar. Added after the text is set so the plugin's
        // initial full-document parse — which runs when the view lands in a
        // window — sees the whole document. The plugin only layers foreground
        // colors as rendering attributes; the font stays kero's (see
        // SyntaxHighlighting.theme).
        textView.updateSyntaxHighlighting(for: file.path)

        // Captured before the coordinator attaches, because its scroll
        // observer starts overwriting `editorState` immediately.
        let state = file.editorState
        if let location = state.selectionLocation {
            let limit = (textView.text ?? "").utf16.count
            let start = min(max(0, location), limit)
            let length = min(max(0, state.selectionLength ?? 0), limit - start)
            textView.textSelection = NSRange(location: start, length: length)
        }

        coordinator.attach(textView: textView, scrollView: scrollView)

        // Restore the saved scroll offset during the first layout pass — while
        // the frame is finally known but before the first paint — so the file
        // opens already at its saved position. Doing this asynchronously (after
        // the initial paint at the top) makes the editor visibly scroll into
        // place and flashes the auto-hiding scroller.
        if state.scrollX != nil || state.scrollY != nil {
            scrollView.restoreOnFirstLayout = { [weak scrollView, weak textView] in
                guard let scrollView, let textView else { return }
                let clipView = scrollView.contentView
                // setBoundsOrigin (not scroll(to:)) avoids clamping against a
                // content height that TextKit2 has only estimated so far.
                clipView.setBoundsOrigin(NSPoint(x: state.scrollX ?? 0, y: state.scrollY ?? 0))
                scrollView.reflectScrolledClipView(clipView)
                // Lay out the viewport around the restored offset in this same
                // pass so the region is painted in place, not after a scroll.
                textView.needsLayout = true
            }
        }

        return scrollView
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let container = container as? SourceEditorContainer,
              container.scrollView.superview === container else { return }
        let scrollView = container.scrollView
        guard let textView = scrollView.documentView as? STTextView else { return }
        (textView as? FocusReportingTextView)?.onBecomeFirstResponder = onFocused
        (textView as? FocusReportingTextView)?.onResignFirstResponder = {
            [weak file] in file?.autoSaveOnFocusLoss()
        }
        apply(to: textView, scrollView: scrollView)
        // Take focus on the unfocused→focused edge (keyboard navigation moving
        // focus here), never on every render.
        if isFocused, !context.coordinator.wasFocused {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        context.coordinator.wasFocused = isFocused
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        guard let container = container as? SourceEditorContainer,
              container.scrollView.superview === container else { return }
        container.scrollView.removeFromSuperview()
        (container.scrollView.documentView as? FocusReportingTextView)?.onBecomeFirstResponder = nil
        (container.scrollView.documentView as? FocusReportingTextView)?.onResignFirstResponder = nil
        if coordinator.file?.editorView === container.scrollView {
            coordinator.file?.editorView = nil
        }
    }

    /// Take exactly the space SwiftUI offers. Without this, SwiftUI sizes the
    /// editor from the scroll view's `fittingSize`, which STTextView derives
    /// from the entire document — enormous for a large file, and degenerate
    /// for an empty one. Because the main window tracks its content's ideal
    /// size, that runaway measurement drives the window size and drops it into
    /// an unbounded layout loop (a hard crash: "more Layout Window passes than
    /// there are views"). Reporting the proposed size keeps the editor a
    /// space-filling pane that never influences the window's size.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSView, context: Context
    ) -> CGSize? {
        func resolve(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
            guard let value, value.isFinite else { return fallback }
            return value
        }
        return CGSize(
            width: resolve(proposal.width, fallback: nsView.frame.width),
            height: resolve(proposal.height, fallback: nsView.frame.height)
        )
    }

    /// Guarded assignments: the font/color setters restyle the whole
    /// document, and this runs on every SwiftUI render.
    private func apply(to textView: STTextView, scrollView: NSScrollView) {
        textView.isEditable = file.readOnlyReason == nil && file.reloadError == nil
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != palette.text {
            textView.textColor = palette.text
        }
        if textView.backgroundColor != palette.background {
            textView.backgroundColor = palette.background
            scrollView.backgroundColor = palette.background
        }
        textView.insertionPointColor = palette.insertionPoint
        textView.selectedLineHighlightColor = palette.lineHighlight
        // false = wrap at the view width, true = expand horizontally.
        textView.isHorizontallyResizable = !wrapLines
        if let gutter = textView.gutterView {
            gutter.textColor = palette.gutterText
            gutter.selectedLineTextColor = palette.text
        }
    }

    @MainActor
    final class Coordinator: NSObject, STTextViewDelegate {
        fileprivate weak var file: FileTab?
        let revision: UInt
        private(set) var scrollView: NSScrollView?
        private weak var textView: STTextView?
        private var scrollObserver: (any NSObjectProtocol)?
        /// Last-applied focus state, so `updateNSView` can act only on the
        /// unfocused→focused edge.
        var wasFocused = false

        init(file: FileTab) {
            self.file = file
            revision = file.reloadRevision
        }

        func attach(textView: STTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            textView.textDelegate = self
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let file = self.file,
                          file.editorCoordinator === self,
                          let clipView = scrollView?.contentView else { return }
                    guard scrollView?.window != nil else { return }
                    file.editorState.scrollX = clipView.bounds.origin.x
                    file.editorState.scrollY = clipView.bounds.origin.y
                }
            }
        }

        isolated deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func updateSyntaxHighlighting(for path: String) {
            (textView as? FocusReportingTextView)?.updateSyntaxHighlighting(for: path)
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard let textView, let file, file.editorCoordinator === self else { return }
            file.text = textView.text ?? ""
            file.refreshDirtyState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, let file, file.editorCoordinator === self else { return }
            let selection = textView.textSelection
            file.editorState.selectionLocation = selection.location
            file.editorState.selectionLength = selection.length
        }
    }
}

private final class SourceEditorContainer: NSView {
    let scrollView: NSScrollView
    var focusOnAttach = false

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAttach, let window,
              let editor = scrollView.documentView as? FocusReportingTextView else { return }
        focusOnAttach = false
        window.makeFirstResponder(editor)
        (scrollView as? RestorableScrollView)?.restoreScrollAfterFocus()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard scrollView.superview === self, bounds.width > 0, bounds.height > 0 else { return }
        if scrollView.frame != bounds { scrollView.frame = bounds }
    }
}

/// STTextView that reports when it takes first-responder status (a click, or a
/// programmatic focus), so the owning work tab can mark itself selected.
final class FocusReportingTextView: STTextView {
    var onBecomeFirstResponder: (() -> Void)?
    var onResignFirstResponder: (() -> Void)?
    weak var syntaxCoordinator: SyntaxHighlightCoordinator?
    private var syntaxLanguage: SyntaxLanguage?

    func updateSyntaxHighlighting(for path: String) {
        let language = SyntaxHighlighting.language(for: path)
        guard language != syntaxLanguage else { return }
        syntaxCoordinator?.deactivate()
        syntaxCoordinator = nil
        removePlugins(of: SyntaxHighlightPlugin.self)
        textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textContentManager.documentRange)
        if let plugin = SyntaxHighlighting.plugin(for: path) { addPlugin(plugin) }
        syntaxLanguage = language
    }
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecomeFirstResponder?() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResignFirstResponder?() }
        return resigned
    }
}

/// NSScrollView that runs a one-shot restoration during its first real layout
/// pass — before the first paint — so a restored file opens already scrolled to
/// its saved position instead of visibly jumping there afterward.
private final class RestorableScrollView: NSScrollView {
    var restoreOnFirstLayout: (() -> Void)?
    private var lastViewportSize: NSSize = .zero
    private var geometryUpdateScheduled = false
    private var detachedScrollOrigin: NSPoint?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, newWindow == nil, restoreOnFirstLayout == nil {
            let offset = contentView.bounds.origin
            detachedScrollOrigin = offset
            restoreOnFirstLayout = { [weak self] in
                guard let self else { return }
                let clip = self.contentView
                clip.setBoundsOrigin(offset)
                self.reflectScrolledClipView(clip)
                self.documentView?.needsLayout = true
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func restoreScrollAfterFocus() {
        guard let detachedScrollOrigin else { return }
        self.detachedScrollOrigin = nil
        let clip = contentView
        clip.setBoundsOrigin(detachedScrollOrigin)
        reflectScrolledClipView(clip)
    }

    override func layout() {
        super.layout()
        let viewportSize = contentView.bounds.size
        if viewportSize != lastViewportSize {
            lastViewportSize = viewportSize
            scheduleEditorGeometryUpdate()
        }
        if window != nil, bounds.width > 0, bounds.height > 0,
           let restore = restoreOnFirstLayout {
            restoreOnFirstLayout = nil
            restore()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleEditorGeometryUpdate()
    }

    /// STTextView's document view can inherit the viewport's width while the
    /// window is resizing. Re-run its content sizing after AppKit finishes the
    /// scroll-view layout, then clamp the old offset to the new scroll range
    /// and refresh the scroller thumb/proportion.
    private func scheduleEditorGeometryUpdate() {
        guard !geometryUpdateScheduled else { return }
        geometryUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryUpdateScheduled = false
            guard let textView = self.documentView as? STTextView else { return }

            textView.needsLayout = true
            textView.layoutSubtreeIfNeeded()

            // Re-place the scrollers against the new width. An overlay scroller
            // that was faded out when the viewport changed keeps the frame it
            // had, so it comes back at the editor's *old* trailing edge — most
            // visibly after Dock group resizing, where it reappears
            // mid-document with text running past it.
            self.tile()

            let clipView = self.contentView
            let constrainedBounds = clipView.constrainBoundsRect(clipView.bounds)
            if constrainedBounds.origin != clipView.bounds.origin {
                clipView.setBoundsOrigin(constrainedBounds.origin)
            }
            self.reflectScrolledClipView(clipView)
        }
    }
}
