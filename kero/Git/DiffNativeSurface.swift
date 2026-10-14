//
//  DiffNativeSurface.swift
//  kero
//

import AppKit
import STTextView
import SwiftUI

/// One retained TextKit surface for a diff tab. Layout and gestures never
/// create a second editor document when SwiftUI moves the enclosing pane.
@MainActor
final class DiffNativeSurface: NSView, STTextViewDelegate {
    weak var diff: DiffTab?

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
        if window != nil { restorePendingViewports() }
    }

    private func restorePendingViewports() {
        guard window != nil, !pendingViewportOffsets.isEmpty else { return }
        let offsets = pendingViewportOffsets
        pendingViewportOffsets = []
        for (pane, origin) in offsets {
            let scroll = pane.scrollView
            scroll.contentView.setBoundsOrigin(origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    override func layout() {
        super.layout()
        unifiedPane?.frame = bounds
        editPane?.frame = bounds
        if let leftPane, let rightPane, let divider {
            let leftWidth = floor((bounds.width - 1) / 2)
            leftPane.frame = CGRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
            divider.frame = CGRect(x: leftWidth, y: 0, width: 1, height: bounds.height)
            rightPane.frame = CGRect(
                x: leftWidth + 1, y: 0, width: max(0, bounds.width - leftWidth - 1),
                height: bounds.height
            )
        }
        if bounds.width > 0, bounds.height > 0 { restorePendingViewports() }
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
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = EditorPalette.theme(dark: dark)
        let editing = diff.isEditing
        let split = diff.preferences.diffStyle == .split

        if diff.source.isPlainRevision {
            // A historical revision is an actual read-only document, not a diff
            // whose every line should be colored as an insertion.
            let pane = editPane ?? makeEditPane()
            pane.applyTypography(font: font, paragraphStyle: style, textColor: palette.text)
            if renderedEditRevision != diff.editBufferRevision {
                renderedEditRevision = diff.editBufferRevision
                pane.setEditBufferText(diff.newContent)
            }
            pane.textView.isEditable = false
            pane.decorations = .empty
        } else if editing {
            let pane = editPane ?? makeEditPane()
            pane.applyTypography(font: font, paragraphStyle: style, textColor: palette.text)
            pane.textView.insertionPointColor = palette.insertionPoint
            if renderedEditRevision != diff.editBufferRevision {
                renderedEditRevision = diff.editBufferRevision
                pane.setEditBufferText(diff.editedNewContent)
                // Install the language plugin only on a new edit pane. It
                // cannot be detached, so the review panes remain separate.
                if !paneHasSyntaxPlugin {
                    paneHasSyntaxPlugin = true
                    if let plugin = SyntaxHighlighting.plugin(for: diff.path) {
                        pane.textView.addPlugin(plugin)
                    }
                }
            }
            pane.decorations = diff.editDecorations
            if let anchor = pendingAnchor, let line = anchor.newLine {
                pendingAnchor = nil
                pane.scrollToRow(max(0, line - 1))
            }
        } else if let display = diff.display {
            if split {
                let left = leftPane ?? makeSplitPane(side: .oldOnly)
                let right = rightPane ?? makeSplitPane(side: .newOnly)
                apply(display.leftText, document: display.computation.splitLeft,
                      id: display.id, to: left, font: font, style: style, palette: palette)
                apply(display.rightText, document: display.computation.splitRight,
                      id: display.id, to: right, font: font, style: style, palette: palette)
                restoreAnchor(to: right, rows: display.computation.splitRight.rows)
                left.setScrollOffset(right.scrollOffset)
            } else {
                let pane = unifiedPane ?? makeUnifiedPane()
                apply(display.unifiedText, document: display.computation.unified,
                      id: display.id, to: pane, font: font, style: style, palette: palette)
                restoreAnchor(to: pane, rows: display.computation.unified.rows)
            }
        }

        let plain = diff.source.isPlainRevision
        unifiedPane?.isHidden = editing || split || plain
        leftPane?.isHidden = editing || !split || plain
        rightPane?.isHidden = editing || !split || plain
        divider?.isHidden = editing || !split || plain
        editPane?.isHidden = !(editing || plain)

        for pane in [unifiedPane, leftPane, rightPane, editPane] where pane?.isHidden == true {
            guard let pane, pane.scrollView.isFindBarVisible else { continue }
            pane.textView.textFinder.performAction(.hideFindInterface)
        }
        needsLayout = true
    }

    private var paneHasSyntaxPlugin = false

    private func makePane(mode: DiffCodePaneView.Mode, gutter: DiffGutterLayout) -> DiffCodePaneView {
        let pane = DiffCodePaneView(mode: mode, gutterLayout: gutter)
        pane.onExpandCollapsedRun = { [weak self] run in self?.diff?.expandRun(run) }
        addSubview(pane)
        return pane
    }

    private func makeEditPane() -> DiffCodePaneView {
        let pane = makePane(mode: .edit, gutter: .single)
        pane.textView.textDelegate = self
        pane.textView.onResignFirstResponder = { [weak self] in
            self?.diff?.autoSaveOnFocusLoss()
        }
        editPane = pane
        return pane
    }

    private func makeUnifiedPane() -> DiffCodePaneView {
        let pane = makePane(mode: .review, gutter: .single)
        unifiedPane = pane
        return pane
    }

    private func makeSplitPane(side: DiffGutterLayout) -> DiffCodePaneView {
        let pane = makePane(mode: .review, gutter: side)
        if side == .oldOnly {
            leftPane = pane
        } else {
            rightPane = pane
        }
        if let leftPane, let rightPane, divider == nil {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = Theme.divider.cgColor
            addSubview(line)
            divider = line
            leftPane.onScroll = { [weak rightPane] origin in
                rightPane?.setScrollOffset(origin)
            }
            rightPane.onScroll = { [weak leftPane] origin in
                leftPane?.setScrollOffset(origin)
            }
        }
        return pane
    }

    private func apply(
        _ text: NSAttributedString, document: DiffSideDocument, id: UUID,
        to pane: DiffCodePaneView, font: NSFont, style: NSParagraphStyle,
        palette: EditorPalette
    ) {
        pane.applyTypography(font: font, paragraphStyle: style, textColor: palette.text)
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

    func textViewDidChangeText(_ notification: Notification) {
        guard let textView = editPane?.textView,
              (notification.object as? STTextView) === textView else { return }
        diff?.updateEditedContent(textView.text ?? "")
    }

}

/// SwiftUI owns only the mount, never the native diff document and undo stack.
struct DiffNativeRoot: NSViewRepresentable {
    let diff: DiffTab

    func makeNSView(context: Context) -> DiffNativeSurface {
        if let existing = diff.nativeSurface { return existing }
        let view = DiffNativeSurface(diff: diff)
        diff.nativeSurface = view
        return view
    }

    func updateNSView(_ view: DiffNativeSurface, context: Context) {
        view.render()
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
