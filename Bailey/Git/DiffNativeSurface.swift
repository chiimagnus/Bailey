import AppKit
import SwiftUI

/// One retained TextKit surface for a diff tab. Layout and gestures never
/// create a second editor document when SwiftUI moves the enclosing pane.
@MainActor
final class DiffNativeSurface: NSView, NSTextViewDelegate {
    weak var diff: DiffTab?
    var canFocus: () -> Bool = { false }
    private var pendingFocus = false

    func requestFocus(_ focused: Bool) {
        pendingFocus = focused
        if focused { needsLayout = true }
    }

    private func focusIfRequested() {
        guard pendingFocus, canFocus(), NSApp.isActive, let window, window.isKeyWindow,
              let pane = [editPane, rightPane, unifiedPane, leftPane].compactMap({ $0 })
                .first(where: { !$0.isHidden }) else { return }
        if window.makeFirstResponder(pane.textView) { pendingFocus = false }
    }
    var onFocused: (() -> Void)? {
        didSet {
            for pane in [unifiedPane, leftPane, rightPane, editPane].compactMap({ $0 }) {
                pane.textView.onBecomeFirstResponder = onFocused
            }
        }
    }

    private var unifiedPane: DiffCodePaneView?
    private var leftPane: DiffCodePaneView?
    private var rightPane: DiffCodePaneView?
    private var divider: NSView?
    private var editPane: DiffCodePaneView?
    private var renderedEditRevision: UInt?
    private var pendingAnchor: (oldLine: Int?, newLine: Int?)?

    init(diff: DiffTab) {
        self.diff = diff
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// AppKit may reset scroll offsets when SwiftUI reattaches a retained pane.
    private var pendingViewportOffsets: [(pane: DiffCodePaneView, origin: NSPoint)] = []

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, newWindow == nil {
            pendingViewportOffsets = [unifiedPane, leftPane, rightPane, editPane]
                .compactMap { pane in pane.map { ($0, $0.scrollView.contentView.bounds.origin) } }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !pendingViewportOffsets.isEmpty { needsLayout = true }
    }

    private func restorePendingViewports() {
        guard window != nil, bounds.width > 0, bounds.height > 0,
              !pendingViewportOffsets.isEmpty else { return }
        let offsets = pendingViewportOffsets
        pendingViewportOffsets = []
        for (pane, origin) in offsets {
            pane.layoutSubtreeIfNeeded()
            pane.scrollView.layoutSubtreeIfNeeded()
            pane.textView.layoutSubtreeIfNeeded()
            let scroll = pane.scrollView
            scroll.contentView.setBoundsOrigin(origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    override func layout() {
        super.layout()
        let editing = diff?.isEditing == true
        let canonical = editing && diff?.showsCanonicalComparison == true
        let paired = editing && diff?.display != nil
            && (canonical || diff?.preferences.diffStyle == .split)
        let half = floor((bounds.width - 1) / 2)
        let leftFrame = CGRect(x: 0, y: 0, width: half, height: bounds.height)
        unifiedPane?.frame = canonical && paired ? leftFrame : bounds
        editPane?.frame = paired
            ? CGRect(x: half + 1, y: 0, width: max(0, bounds.width - half - 1),
                     height: bounds.height) : bounds
        if paired {
            leftPane?.frame = leftFrame
            divider?.frame = CGRect(x: half, y: 0, width: 1, height: bounds.height)
        }
        if let leftPane, let rightPane, let divider, !editing {
            let leftWidth = floor((bounds.width - 1) / 2)
            leftPane.frame = CGRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
            divider.frame = CGRect(x: leftWidth, y: 0, width: 1, height: bounds.height)
            rightPane.frame = CGRect(
                x: leftWidth + 1, y: 0, width: max(0, bounds.width - leftWidth - 1),
                height: bounds.height
            )
        }
        if bounds.width > 0, bounds.height > 0 { restorePendingViewports() }
        focusIfRequested()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        diff?.refreshNativeAppearance()
    }

    func rememberScrollAnchor() {
        guard let diff, let display = diff.display else { return }
        if diff.isEditing {
            if let row = editPane?.firstVisibleRowIndex { pendingAnchor = (nil, row + 1) }
            return
        }
        let split = diff.preferences.diffStyle == .split
        let pane = split ? rightPane : unifiedPane
        let rows = split ? display.computation.splitRight.rows : display.computation.unified.rows
        guard let index = pane?.firstVisibleRowIndex, index < rows.count else { return }
        for row in rows[index...] where row.oldLine != nil || row.newLine != nil {
            pendingAnchor = (row.oldLine, row.newLine)
            return
        }
    }

    func render() {
        guard let diff else { return }
        let font = TerminalFont.current()
        let style = DiffTypography.paragraphStyle(for: font)
        let longLineDisplayWidth = AppSettings.shared.longLineDisplayWidth
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = EditorPalette.theme(dark: dark)
        let editing = diff.isEditing
        let split = diff.preferences.diffStyle == .split

        if diff.source.isPlainRevision {
            // A historical revision is an actual read-only document, not a diff
            // whose every line should be colored as an insertion.
            let pane = editPane ?? makeEditPane()
            pane.applyTypography(font: font, paragraphStyle: style, textColor: palette.text,
                                 longLineDisplayWidth: longLineDisplayWidth)
            if renderedEditRevision != diff.editBufferRevision {
                renderedEditRevision = diff.editBufferRevision
                pane.setEditBufferText(diff.newContent)
            }
            pane.textView.isEditable = false
            pane.decorations = .empty
        } else if editing {
            let pane = editPane ?? makeEditPane()
            let width: LongLineDisplayWidth = split && !diff.showsCanonicalComparison
                && longLineDisplayWidth == .showAll ? .expanded : longLineDisplayWidth
            pane.applyTypography(font: font, paragraphStyle: style, textColor: palette.text,
                                 longLineDisplayWidth: width)
            pane.textView.insertionPointColor = palette.insertionPoint
            pane.textView.isEditable = diff.isEditableNow
            if renderedEditRevision != diff.editBufferRevision {
                renderedEditRevision = diff.editBufferRevision
                pane.setEditBufferText(diff.editedNewContent)
                // Keep syntax highlighting attached to the live native text buffer.
                if !paneHasSyntaxPlugin {
                    paneHasSyntaxPlugin = true
                    if let plugin = SyntaxHighlighting.configuration(for: diff.path) {
                        pane.textView.installSyntaxHighlighting(plugin)
                    }
                }
            }
            pane.decorations = diff.editDecorations
            if let display = diff.display {
                if diff.showsCanonicalComparison {
                    let review = unifiedPane ?? makeUnifiedPane()
                    apply(display.unifiedText, document: display.computation.unified,
                          id: display.id, to: review, font: font, style: style, palette: palette,
                          longLineDisplayWidth: longLineDisplayWidth)
                    _ = ensureDivider()
                } else if split {
                    let left = leftPane ?? makeSplitPane(side: .oldOnly)
                    apply(display.leftText, document: display.computation.splitLeft,
                          id: display.id, to: left, font: font, style: style, palette: palette,
                          longLineDisplayWidth: width)
                    _ = ensureDivider()
                    left.onScroll = { [weak pane] offset in pane?.setScrollOffset(offset) }
                    pane.onScroll = { [weak left] offset in left?.setScrollOffset(offset) }
                    left.setScrollOffset(pane.scrollOffset)
                }
            }
            if !split || diff.showsCanonicalComparison { pane.onScroll = nil }
            if let anchor = pendingAnchor, let line = anchor.newLine {
                pendingAnchor = nil
                pane.scrollToRow(max(0, line - 1))
            }
        } else if let display = diff.display {
            if split {
                // Two panes must share fixed row heights; wrapping one side
                // independently would move corresponding Git rows out of alignment.
                let splitWidth: LongLineDisplayWidth = longLineDisplayWidth == .showAll
                    ? .expanded : longLineDisplayWidth
                let left = leftPane ?? makeSplitPane(side: .oldOnly)
                let right = rightPane ?? makeSplitPane(side: .newOnly)
                apply(display.leftText, document: display.computation.splitLeft,
                      id: display.id, to: left, font: font, style: style, palette: palette,
                      longLineDisplayWidth: splitWidth)
                apply(display.rightText, document: display.computation.splitRight,
                      id: display.id, to: right, font: font, style: style, palette: palette,
                      longLineDisplayWidth: splitWidth)
                restoreAnchor(to: right, rows: display.computation.splitRight.rows)
                left.setScrollOffset(right.scrollOffset)
            } else {
                let pane = unifiedPane ?? makeUnifiedPane()
                apply(display.unifiedText, document: display.computation.unified,
                      id: display.id, to: pane, font: font, style: style, palette: palette,
                      longLineDisplayWidth: longLineDisplayWidth)
                restoreAnchor(to: pane, rows: display.computation.unified.rows)
            }
        }

        let plain = diff.source.isPlainRevision
        let canonical = editing && diff.showsCanonicalComparison && diff.display != nil
        let editableSplit = editing && split && diff.display != nil && !canonical
        unifiedPane?.isHidden = editing ? !canonical : split || plain
        leftPane?.isHidden = editing ? !editableSplit : !split || plain
        rightPane?.isHidden = editing || !split || plain
        divider?.isHidden = editing ? !(canonical || editableSplit) : !split || plain
        editPane?.isHidden = !(editing || plain)
        if let divider {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                divider.layer?.backgroundColor = Theme.divider.cgColor
            }
        }

        for pane in [unifiedPane, leftPane, rightPane, editPane] where pane?.isHidden == true {
            guard let pane, pane.scrollView.isFindBarVisible else { continue }
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.hideFindInterface.rawValue
            pane.textView.performFindPanelAction(item)
        }
        needsLayout = true
    }

    private var paneHasSyntaxPlugin = false

    private func makePane(mode: DiffCodePaneView.Mode, gutter: DiffGutterLayout) -> DiffCodePaneView {
        let pane = DiffCodePaneView(mode: mode, gutterLayout: gutter)
        pane.textView.onBecomeFirstResponder = onFocused
        pane.onExpandCollapsedRun = { [weak self] run in self?.diff?.expandRun(run) }
        addSubview(pane)
        return pane
    }

    private func makeEditPane() -> DiffCodePaneView {
        let pane = makePane(mode: .edit, gutter: .single)
        pane.textView.setAccessibilityIdentifier("bailey.diff.worktree")
        pane.textView.delegate = self
        pane.textView.onCharacterEdit = { [weak self] in self?.editTextDidChange() }
        pane.textView.onResignFirstResponder = { [weak self] in
            self?.diff?.autoSaveOnFocusLoss()
        }
        editPane = pane
        return pane
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        guard view === editPane?.textView else { return nil }
        return editPane?.textView.undoManager
    }

    private func makeUnifiedPane() -> DiffCodePaneView {
        let pane = makePane(mode: .review, gutter: .single)
        pane.textView.setAccessibilityIdentifier("bailey.diff.canonical")
        unifiedPane = pane
        return pane
    }

    private func makeSplitPane(side: DiffGutterLayout) -> DiffCodePaneView {
        let pane = makePane(mode: .review, gutter: side)
        pane.textView.setAccessibilityIdentifier(
            side == .oldOnly ? "bailey.diff.baseline" : "bailey.diff.readonly-new"
        )
        if side == .oldOnly {
            leftPane = pane
        } else {
            rightPane = pane
        }
        if let leftPane, let rightPane {
            _ = ensureDivider()
            leftPane.onScroll = { [weak rightPane] origin in
                rightPane?.setScrollOffset(origin)
            }
            rightPane.onScroll = { [weak leftPane] origin in
                leftPane?.setScrollOffset(origin)
            }
        }
        return pane
    }

    private func ensureDivider() -> NSView {
        if let divider { return divider }
        let view = NSView()
        view.wantsLayer = true
        addSubview(view)
        divider = view
        return view
    }

    private func apply(
        _ text: NSAttributedString, document: DiffSideDocument, id: UUID,
        to pane: DiffCodePaneView, font: NSFont, style: NSParagraphStyle,
        palette: EditorPalette, longLineDisplayWidth: LongLineDisplayWidth
    ) {
        pane.applyTypography(font: font, paragraphStyle: style, textColor: palette.text,
                             longLineDisplayWidth: longLineDisplayWidth)
        guard pane.renderedDisplayID != id else { return }
        pane.renderedDisplayID = id
        pane.setReviewDocument(text, decorations: .review(document))
    }

    private func restoreAnchor(to pane: DiffCodePaneView, rows: [DiffRow]) {
        guard let anchor = pendingAnchor else { return }
        pendingAnchor = nil
        if let index = rows.firstIndex(where: { row in
            if let line = anchor.newLine, let next = row.newLine { return next >= line }
            if let line = anchor.oldLine, let old = row.oldLine { return old >= line }
            return false
        }) {
            pane.scrollToRow(index)
        }
    }

    private func editTextDidChange() {
        guard let diff, diff.isEditing, let textView = editPane?.textView else { return }
        diff.updateEditedContent(textView.string)
    }

}

/// SwiftUI owns only the mount, never the native diff document and undo stack.
struct DiffNativeRoot: NSViewRepresentable {
    let diff: DiffTab
    var isFocused = false
    var canFocus: () -> Bool = { true }
    var onFocused: () -> Void = {}

    final class Coordinator {
        var wasFocused = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiffNativeSurface {
        if let existing = diff.nativeSurface { return existing }
        let view = DiffNativeSurface(diff: diff)
        diff.nativeSurface = view
        return view
    }

    func updateNSView(_ view: DiffNativeSurface, context: Context) {
        view.canFocus = canFocus
        view.onFocused = onFocused
        view.render()
        if isFocused != context.coordinator.wasFocused { view.requestFocus(isFocused) }
        context.coordinator.wasFocused = isFocused
    }

    static func dismantleNSView(_ view: DiffNativeSurface, coordinator: Coordinator) {
        view.onFocused = nil
        view.canFocus = { false }
        view.requestFocus(false)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: DiffNativeSurface, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.frame.width,
            height: proposal.height ?? nsView.frame.height
        )
    }
}
