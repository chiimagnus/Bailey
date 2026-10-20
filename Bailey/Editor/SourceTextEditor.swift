import AppKit
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
/// is not included: NSTextView uses the system selection color.
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

/// Native NSTextView wrapped for SwiftUI: plain-text editing with line numbers and
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
        // Native NSTextView.
        textView.isIncrementalSearchingEnabled = true
        apply(to: textView, scrollView: scrollView)
        textView.text = file.text

        // Tree-sitter syntax highlighting, for file types with
        // a bundled grammar. Added after the text is set so the plugin's
        // initial full-document parse — which runs when the view lands in a
        // window — sees the whole document. The plugin only layers foreground
        // colors as rendering attributes; the font stays bailey's (see
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
        } else if state.scrollY != nil {
            // A newly loaded NSTextView can leave its insertion point at EOF.
            // With a restored scroll but no saved caret, that would make AppKit
            // scroll to EOF again while attaching the view.
            textView.textSelection = NSRange(location: 0, length: 0)
        }

        // Restore the saved scroll offset during the first layout pass — while
        // the frame is finally known but before the first paint — so the file
        // opens already at its saved position. Doing this asynchronously (after
        // the initial paint at the top) makes the editor visibly scroll into
        // place and flashes the auto-hiding scroller.
        if state.scrollX != nil || state.scrollY != nil {
            scrollView.restoreOnFirstLayout = { [weak scrollView, weak textView] in
                guard let scrollView, let textView else { return }
                let clipView = scrollView.contentView
                // Locate the saved region before positioning the clip. The
                // first AppKit layout may still report only one viewport of
                // document height; native range navigation establishes the
                // estimated height without laying out the whole file.
                if let offset = textView.approximateCharacterOffset(atDocumentY: state.scrollY ?? 0) {
                    textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
                }
                // Finish TextKit's layout before applying the exact saved offset;
                // older AppKit versions can otherwise scroll to the provisional
                // paragraph anchor during their next layout pass.
                textView.needsLayout = true
                textView.layoutSubtreeIfNeeded()
                clipView.setBoundsOrigin(NSPoint(x: state.scrollX ?? 0, y: state.scrollY ?? 0))
                scrollView.reflectScrolledClipView(clipView)
            }
        }

        coordinator.attach(textView: textView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let container = container as? SourceEditorContainer,
              container.scrollView.superview === container else { return }
        let scrollView = container.scrollView
        guard let textView = scrollView.documentView as? NativeCodeTextView else { return }
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
    /// editor from the scroll view's `fittingSize`, which AppKit derives
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
    private func apply(to textView: NativeCodeTextView, scrollView: NSScrollView) {
        textView.isEditable = file.readOnlyReason == nil && file.reloadError == nil
        if textView.font != font {
            textView.font = font
            textView.updateGutter()
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
        textView.configureWrapping(wrapLines, viewportWidth: scrollView.contentView.bounds.width)
        if let gutter = textView.gutterView {
            gutter.backgroundColor = palette.background
            gutter.textColor = palette.gutterText
            gutter.selectedLineTextColor = palette.text
            gutter.selectedLineHighlightColor = palette.lineHighlight
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate weak var file: FileTab?
        let revision: UInt
        private(set) var scrollView: NSScrollView?
        private weak var textView: NativeCodeTextView?
        private var pendingReplacement: (range: NSRange, removed: String, inserted: String)?
        private var scrollObserver: (any NSObjectProtocol)?
        /// Last-applied focus state, so `updateNSView` can act only on the
        /// unfocused→focused edge.
        var wasFocused = false

        init(file: FileTab) {
            self.file = file
            revision = file.reloadRevision
        }

        func attach(textView: NativeCodeTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            textView.delegate = self
            textView.onCharacterEdit = { [weak self] in self?.handleNativeCharacterEdit() }
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
                    // Ignore early AppKit clip updates until the saved
                    // position is applied to a sized document view.
                    if (scrollView as? RestorableScrollView)?.restoreOnFirstLayout != nil { return }
                    file.editorState.scrollX = clipView.bounds.origin.x
                    file.editorState.scrollY = (scrollView as? RestorableScrollView)?
                        .sessionScrollY ?? clipView.bounds.origin.y
                    (scrollView?.documentView as? NativeCodeTextView)?
                        .syntaxCoordinator?.updateViewportRange(
                            (scrollView?.documentView as? NativeCodeTextView)?
                                .textLayoutManager?.textViewportLayoutController.viewportRange
                        )
                }
            }
        }

        func retireObsoleteDocument() {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
                self.scrollObserver = nil
            }
            if let editor = textView as? FocusReportingTextView {
                editor.syntaxCoordinator?.deactivate()
                editor.syntaxCoordinator = nil
                editor.delegate = nil
                editor.onCharacterEdit = nil
                editor.onBecomeFirstResponder = nil
                editor.onResignFirstResponder = nil
            }
            // The prior SwiftUI host can outlive a file generation while
            // AppKit finishes its layout. Its scroll view must not keep the
            // obsolete text document alive after the new bytes are accepted.
            scrollView?.documentView = nil
            scrollView = nil
            textView = nil
        }

        isolated deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func currentText() -> String? { textView?.text }

        func appendText(_ suffix: String) -> Bool {
            guard let textView else { return false }
            return textView.appendDocumentText(suffix)
        }

        func updateSyntaxHighlighting(for path: String) {
            (textView as? FocusReportingTextView)?.updateSyntaxHighlighting(for: path)
        }

        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString: String?) -> Bool {
            guard view === textView, let file, file.editorCoordinator === self,
                  let replacementString, let storage = view.textStorage else { return true }
            pendingReplacement = (range, storage.attributedSubstring(from: range).string,
                                  replacementString)
            return true
        }

        private func handleNativeCharacterEdit() {
            guard let file, file.editorCoordinator === self else { return }
            if let pendingReplacement {
                file.recordNativeReplacement(at: pendingReplacement.range,
                    removing: pendingReplacement.removed, inserting: pendingReplacement.inserted)
                self.pendingReplacement = nil
            } else {
                file.nativeTextChangedWithoutReplacement()
            }
            file.refreshDirtyState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, let file, file.editorCoordinator === self else { return }
            let selection = textView.textSelection
            textView.needsDisplay = true
            textView.gutterView?.needsDisplay = true
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

/// Native NSTextView that reports when it takes first-responder status (a click, or a
/// programmatic focus), so the owning work tab can mark itself selected.
final class FocusReportingTextView: NativeCodeTextView {
    var onBecomeFirstResponder: (() -> Void)?
    var onResignFirstResponder: (() -> Void)?
    private var syntaxLanguage: SyntaxLanguage?

    func updateSyntaxHighlighting(for path: String) {
        let language = SyntaxHighlighting.language(for: path)
        guard language != syntaxLanguage else { return }
        syntaxCoordinator?.deactivate()
        syntaxCoordinator = nil
        nativeLayoutManager.removeRenderingAttribute(.foregroundColor,
                                                    for: nativeContentManager.documentRange)
        if let plugin = SyntaxHighlighting.configuration(for: path) {
            syntaxCoordinator = SyntaxHighlightCoordinator(
                textView: self, theme: plugin.theme, language: plugin.language,
                highlightsData: plugin.highlightsData, injectionsData: plugin.injectionsData
            )
        }
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
    private var reparentedOffset: NSPoint?
    private var appliedFindBarHeight: CGFloat = 0
    private var lastVisibleFindBarOriginY: CGFloat?

    var sessionScrollY: CGFloat { contentView.bounds.origin.y + appliedFindBarHeight }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, newWindow == nil {
            reparentedOffset = contentView.bounds.origin
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, reparentedOffset != nil { scheduleEditorGeometryUpdate() }
    }

    override func layout() {
        super.layout()
        alignFindBarAndDocument()
        let viewportSize = contentView.bounds.size
        if viewportSize != lastViewportSize {
            lastViewportSize = viewportSize
            scheduleEditorGeometryUpdate()
        }
        restoreInitialOffsetIfReady()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        if isFindBarVisible { lastVisibleFindBarOriginY = clipView.bounds.origin.y }
    }

    private func alignFindBarAndDocument() {
        let findHeight = isFindBarVisible ? (findBarView?.bounds.height ?? 0) : 0
        guard abs(findHeight - appliedFindBarHeight) > 0.5 else { return }
        let clipView = contentView
        let origin = clipView.bounds.origin
        // On hide, AppKit clamps a previously negative find-bar origin to 0
        // before laying out the scroll view. Recover that last visible origin
        // so we never apply the bar-height adjustment a second time.
        let previousY: CGFloat
        if findHeight == 0, origin.y == 0,
           let visibleY = lastVisibleFindBarOriginY, visibleY < 0 {
            previousY = visibleY
        } else {
            previousY = origin.y
        }
        let offset = appliedFindBarHeight - findHeight
        appliedFindBarHeight = findHeight
        if findHeight == 0 { lastVisibleFindBarOriginY = nil }
        // AppKit owns the find-bar content inset. We only reconcile the
        // document's visible origin when that top overlay changes height.
        clipView.setBoundsOrigin(NSPoint(x: origin.x, y: previousY + offset))
        reflectScrolledClipView(clipView)
    }

    private func restoreInitialOffsetIfReady() {
        guard window != nil, bounds.width > 0, bounds.height > 0,
              let textView = documentView as? NativeCodeTextView,
              textView.frame.width > 0, let restore = restoreOnFirstLayout else { return }
        // The initial 1000pt TextKit container may wrap long lines until the
        // scroll view gets its actual width. Size it first, before mapping a
        // persisted document Y position back to a paragraph.
        textView.configureWrapping(textView.wrapsLines,
                                   viewportWidth: contentView.bounds.width)
        restoreOnFirstLayout = nil
        restore()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleEditorGeometryUpdate()
    }

    /// TextKit 2's document view can inherit the viewport's width while the
    /// window is resizing. Re-run its content sizing after AppKit finishes the
    /// scroll-view layout, then clamp the old offset to the new scroll range
    /// and refresh the scroller thumb/proportion.
    private func scheduleEditorGeometryUpdate() {
        guard !geometryUpdateScheduled else { return }
        geometryUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryUpdateScheduled = false
            guard let textView = self.documentView as? NativeCodeTextView else { return }
            let clipView = self.contentView
            // TextKit 2 can revise the estimated document height during tile().
            // Save the reader's position before layout, not after AppKit has
            // already anchored the scroll view to a new document end.
            let previousOrigin = self.reparentedOffset ?? clipView.bounds.origin

            textView.configureWrapping(textView.wrapsLines,
                                       viewportWidth: self.contentView.bounds.width)
            textView.needsLayout = true
            textView.layoutSubtreeIfNeeded()

            // Re-place the scrollers against the new width. An overlay scroller
            // that was faded out when the viewport changed keeps the frame it
            // had, so it comes back at the editor's *old* trailing edge — most
            // visibly after Dock group resizing, where it reappears
            // mid-document with text running past it.
            self.tile()

            // Reparenting can shift the horizontal origin by the ruler width.
            // Restore the same clamped position after layout, without a second
            // caret-follow scrollRangeToVisible that later overrides it.
            let desiredBounds = NSRect(
                origin: NSPoint(x: max(0, previousOrigin.x),
                                y: max(-clipView.contentInsets.top, previousOrigin.y)),
                size: clipView.bounds.size
            )
            let constrainedBounds = clipView.constrainBoundsRect(desiredBounds)
            if constrainedBounds.origin != clipView.bounds.origin {
                clipView.setBoundsOrigin(constrainedBounds.origin)
            }
            self.reparentedOffset = nil
            self.reflectScrolledClipView(clipView)
            self.restoreInitialOffsetIfReady()
        }
    }
}
