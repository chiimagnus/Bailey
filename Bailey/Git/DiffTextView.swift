//  Native NSTextView rendering for the diff viewer: one "code pane" is a text
//  view inside a scroll view, a full-width decoration underlay behind it
//  (row tints, word-level emphasis, deletion markers), and a native gutter
//  with per-file line numbers to its left.
//
//  The text view is transparent and the scroll view draws no background; the
//  underlay sits *behind* the scroll view, viewport-sized, and repaints on
//  scroll and after every viewport layout pass. Everything it draws is
//  derived from the layout manager's actual fragment frames, so decorations
//  stay glued to the text through resizes, elastic scrolling, and variable
//  line heights.
//

import AppKit

/// Fixed line spacing keeps the rows of side-by-side native diffs aligned.
enum DiffTypography {
    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    static func paragraphStyle(for font: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = lineHeight(for: font)
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.defaultTabInterval = NativeCodeTextView.tabInterval
        return style
    }
}

// MARK: - Colors

/// Diff colors derived from the selected ghostty theme: added/removed tints
/// from ANSI green/red over the theme background. Resolved per draw against
/// the current appearance so theme and appearance switches repaint correctly.
struct DiffColorScheme {
    let background: NSColor
    let addedRow: NSColor
    let removedRow: NSColor
    let addedEmphasis: NSColor
    let removedEmphasis: NSColor
    let fillerRow: NSColor
    let fillerStripe: NSColor
    let collapsedBand: NSColor
    let gutterText: NSColor
    let addedGutterText: NSColor
    let removedGutterText: NSColor
    let deletionMarker: NSColor
    let annotationText: NSColor

    static func current(dark: Bool) -> DiffColorScheme {
        let theme = Theme.terminal(dark: dark)
        let background = theme.backgroundNSColor
        // ANSI green/red follow the theme; fall back to fixed diff hues for
        // palettes that don't define them.
        let green = theme.paletteNSColor(2) ?? NSColor(
            srgbRed: 0.25, green: 0.65, blue: 0.35, alpha: 1
        )
        let red = theme.paletteNSColor(1) ?? NSColor(
            srgbRed: 0.85, green: 0.35, blue: 0.35, alpha: 1
        )
        let foreground = theme.foregroundNSColor

        func over(_ tint: NSColor, _ fraction: CGFloat) -> NSColor {
            background.blended(withFraction: fraction, of: tint) ?? background
        }

        return DiffColorScheme(
            background: background,
            addedRow: over(green, 0.16),
            removedRow: over(red, 0.16),
            addedEmphasis: over(green, 0.38),
            removedEmphasis: over(red, 0.38),
            fillerRow: over(foreground, 0.03),
            fillerStripe: over(foreground, 0.06),
            collapsedBand: over(foreground, 0.05),
            gutterText: theme.surfaceNSColor(elevation: 0.35),
            addedGutterText: over(green, 0.75),
            removedGutterText: over(red, 0.75),
            deletionMarker: red,
            annotationText: theme.surfaceNSColor(elevation: 0.5)
        )
    }
}

/// Labels for a collapsed-run separator, shared by the foreground painter
/// and the gutter's accessibility elements.
enum DiffCollapsedRunLabel {
    static func text(hiddenLines: Int) -> String {
        hiddenLines == 1
            ? String(
                localized: "1 unmodified line",
                comment: "Separator row standing in for one folded context line in a diff."
            )
            : String(
                localized: "\(hiddenLines) unmodified lines",
                comment: "Separator row standing in for folded context lines in a diff."
            )
    }

    static func expandAction(hiddenLines: Int) -> String {
        String(
            localized: "Expand \(text(hiddenLines: hiddenLines))",
            comment: "Accessibility action for a folded run of context lines in a diff."
        )
    }
}

// MARK: - Decorations model

/// Everything a code pane needs to decorate its document, keyed by paragraph
/// (row) index. Built from a `DiffSideDocument` in review mode, or from the
/// edit-mode line lists while the buffer is live. The line diff runs off-main;
/// native colors, attributed ghost rows and decorations are built on MainActor.
struct DiffDecorations {
    struct Row {
        var kind: DiffRowKind
        let oldLine: Int?
        let newLine: Int?
        /// Review spans use document UTF-16; edit spans use source-line-relative UTF-16.
        let emphasis: [NSRange]
        let missingNewline: Bool
        /// Present on `.collapsed` separator rows.
        var collapsed: DiffCollapsedRun? = nil
    }

    /// A removed block rendered as read-only ghost rows in the gap above its
    /// anchor paragraph (edit mode). Lines are pre-baked with the old file's
    /// syntax colors and word-level emphasis backgrounds.
    struct GhostBlock {
        /// Buffer paragraph index the block precedes; `rows.count` means the
        /// block sits after the last line (a deletion at end-of-file).
        let anchorLine: Int
        /// 1-based old-file number of the first ghost line.
        let firstOldLine: Int
        let lines: [NSAttributedString]
        let kind: DiffRowKind

        init(anchorLine: Int, firstOldLine: Int, lines: [NSAttributedString],
             kind: DiffRowKind = .removed) {
            self.anchorLine = anchorLine
            self.firstOldLine = firstOldLine
            self.lines = lines
            self.kind = kind
        }
    }

    var rows: [Row]
    /// UTF-16 offset of each row's start; empty in edit mode, where the live
    /// buffer's offsets drift between recomputes and rows are addressed by
    /// paragraph counting instead.
    let lineStartOffsets: [Int]
    /// Edit mode: ghost deletion blocks keyed by anchor paragraph.
    var ghostsByAnchor: [Int: GhostBlock] = [:]
    /// Virtual Git rows, including removed rows absent from the editable buffer.
    struct PositionedGhost {
        let startRow: Int
        var visibleStartRow: Int
        let block: GhostBlock
    }
    var positionedGhosts: [PositionedGhost] = []
    let maxOldLine: Int
    let maxNewLine: Int

    static let empty = DiffDecorations(
        rows: [], lineStartOffsets: [], maxOldLine: 0, maxNewLine: 0
    )

    static func review(_ document: DiffSideDocument) -> DiffDecorations {
        var rows: [Row] = []
        rows.reserveCapacity(document.rows.count)
        var maxOld = 0
        var maxNew = 0
        for (index, row) in document.rows.enumerated() {
            let start = document.lineStartOffsets[index]
            rows.append(Row(
                kind: row.kind,
                oldLine: row.oldLine,
                newLine: row.newLine,
                emphasis: row.emphasis.map {
                    NSRange(location: start + $0.location, length: $0.length)
                },
                missingNewline: row.missingNewline,
                collapsed: row.collapsed
            ))
            maxOld = max(maxOld, row.oldLine ?? 0)
            maxNew = max(maxNew, row.newLine ?? 0)
        }
        return DiffDecorations(
            rows: rows,
            lineStartOffsets: document.lineStartOffsets,
            maxOldLine: maxOld,
            maxNewLine: maxNew
        )
    }

    static func edit(
        state: DiffEditState,
        snapshotOffsets: [Int],
        lineCount: Int,
        ghostBlocks: [GhostBlock]
    ) -> DiffDecorations {
        let added = Set(state.addedLines)
        // An empty buffer still renders one (empty) line.
        let rowCount = max(1, lineCount)
        var rows: [Row] = []
        rows.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            let emphasis = index < snapshotOffsets.count
                ? (state.addedEmphasis[index] ?? []) : []
            rows.append(Row(
                kind: added.contains(index) ? .added : .context,
                oldLine: nil,
                newLine: index + 1,
                emphasis: emphasis,
                missingNewline: false
            ))
        }
        var ghostsByAnchor: [Int: GhostBlock] = [:]
        var maxOld = 0
        for block in ghostBlocks {
            // A deleted-to-empty file has one virtual editable row, but
            // no source line to anchor its EOF ghosts above.
            ghostsByAnchor[lineCount == 0 ? rowCount : block.anchorLine] = block
            maxOld = max(maxOld, block.firstOldLine + block.lines.count - 1)
        }
        var decorations = DiffDecorations(
            rows: rows,
            lineStartOffsets: [],
            maxOldLine: maxOld,
            maxNewLine: rowCount
        )
        decorations.ghostsByAnchor = ghostsByAnchor
        var priorGhostRows = 0
        for (anchor, block) in ghostsByAnchor.sorted(by: { $0.key < $1.key }) {
            decorations.positionedGhosts.append(
                PositionedGhost(startRow: anchor + priorGhostRows,
                                visibleStartRow: anchor + priorGhostRows, block: block)
            )
            priorGhostRows += block.lines.count
        }
        return decorations
    }

    /// Map hidden source lines to display coordinates once per fold change,
    /// instead of scanning every fold on every gutter and background repaint.
    mutating func positionGhosts(for folds: [DiffEditFold]) {
        var completed = 0
        var foldIndex = 0
        for index in positionedGhosts.indices {
            let anchor = positionedGhosts[index].block.anchorLine
            while foldIndex < folds.count && folds[foldIndex].range.upperBound <= anchor {
                completed += max(0, folds[foldIndex].range.count - 1)
                foldIndex += 1
            }
            let partial: Int
            if foldIndex < folds.count {
                let range = folds[foldIndex].range
                partial = max(0, min(anchor, range.upperBound) - range.lowerBound - 1)
            } else {
                partial = 0
            }
            positionedGhosts[index].visibleStartRow = positionedGhosts[index].startRow
                - completed - partial
        }
    }

    /// Row index containing a document UTF-16 offset (review mode only).
    func rowIndex(forUTF16Offset offset: Int) -> Int? {
        guard !lineStartOffsets.isEmpty else { return nil }
        var lo = 0
        var hi = lineStartOffsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStartOffsets[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

// MARK: - Text view

/// Pins each unwrapped Git LF paragraph to its known source row, rather than
/// making TextKit estimate all preceding paragraph heights before scrolling.
nonisolated private final class DiffFixedRowFragment: NSTextLayoutFragment {
    var rowHeight: CGFloat = 0
    var wrapped = false
    var currentRow: (() -> Int)?

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.origin.y = CGFloat(currentRow?() ?? 0) * rowHeight
        frame.size.height = CGFloat(wrapped ? max(1, textLineFragments.count) : 1) * rowHeight
        return frame
    }
}

/// Keep the complete writable NSTextStorage while allowing TextKit to skip
/// whole hidden paragraph ranges. Its ordinary delegate filter still visited
/// every hidden paragraph, making initial layout proportional to source size.
nonisolated private final class FoldedDiffContentStorage: NSTextContentStorage {
    var hiddenRanges: [Range<Int>] = []

    override func enumerateTextElements(
        from location: (any NSTextLocation)?,
        options: NSTextContentManager.EnumerationOptions,
        using block: (NSTextElement) -> Bool
    ) -> (any NSTextLocation)? {
        guard !hiddenRanges.isEmpty else {
            return super.enumerateTextElements(from: location, options: options, using: block)
        }
        let reverse = options.contains(.reverse)
        let base = documentRange.location
        let endOffset = offset(from: base, to: documentRange.endLocation)
        var cursor: any NSTextLocation = location ?? (reverse ? documentRange.endLocation : base)
        while true {
            let position = offset(from: base, to: cursor)
            var low = 0
            var high = hiddenRanges.count
            while low < high {
                let middle = (low + high) / 2
                if reverse ? hiddenRanges[middle].lowerBound < position
                    : hiddenRanges[middle].upperBound <= position {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            let next = reverse
                ? (low > 0 ? hiddenRanges[low - 1] : nil)
                : (low < hiddenRanges.count ? hiddenRanges[low] : nil)
            if let next {
                let within = reverse
                    ? position > next.lowerBound && position <= next.upperBound
                    : next.contains(position)
                if within {
                    let target = reverse ? next.lowerBound : min(next.upperBound, endOffset)
                    if target == position { return cursor }
                    guard let advanced = self.location(base, offsetBy: target) else { return cursor }
                    cursor = advanced
                    continue
                }
            }
            var skippedTo: Int?
            var stoppedByCaller = false
            let edge = super.enumerateTextElements(from: cursor, options: options) { element in
                guard let elementRange = element.elementRange else {
                    let proceed = block(element)
                    if !proceed { stoppedByCaller = true }
                    return proceed
                }
                let start = offset(from: base, to: elementRange.location)
                if let next, reverse ? next.contains(start) : start >= next.lowerBound {
                    skippedTo = reverse ? next.lowerBound : min(next.upperBound, endOffset)
                    return false
                }
                let proceed = block(element)
                if !proceed { stoppedByCaller = true }
                return proceed
            }
            if stoppedByCaller { return edge }
            guard let skippedTo else { return edge }
            guard let advanced = self.location(base, offsetBy: skippedTo) else { return edge }
            cursor = advanced
        }
    }
}

/// The pane's text view expands collapsed-run separators on click instead
/// of placing a caret in the separator row.
final class DiffTextView: NativeCodeTextView, NSTextLayoutManagerDelegate {
    override init(contentStorage storage: NSTextContentStorage = FoldedDiffContentStorage()) {
        super.init(contentStorage: storage)
    }

    private var fixedLayoutRowHeight: CGFloat?
    var layoutRowForUTF16: ((Int) -> Int)?
    var ghostStartY: ((Int) -> CGFloat)?

    func setFixedLayoutRowHeight(_ height: CGFloat?) {
        guard fixedLayoutRowHeight != height else { return }
        fixedLayoutRowHeight = height
        nativeLayoutManager.delegate = height == nil ? nil : self
        nativeLayoutManager.invalidateLayout(for: nativeLayoutManager.documentRange)
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        guard let height = fixedLayoutRowHeight,
              let rowForOffset = layoutRowForUTF16,
              let range = textElement.elementRange else {
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        let offset = nativeContentManager.offset(
            from: nativeContentManager.documentRange.location, to: location
        )
        let fragment = DiffFixedRowFragment(textElement: textElement, range: range)
        fragment.rowHeight = height
        fragment.wrapped = wrapsLines
        // TextKit retains fragments across live diff updates. Ghosts, folds,
        // and wrapped prefixes can all change a cached paragraph's display row.
        fragment.currentRow = {
            MainActor.assumeIsolated { rowForOffset(offset) }
        }
        return fragment
    }

    var onNativeParagraphGeometryChanged: (() -> Void)?
    private(set) var editingFolds: [DiffEditFold] = []
    private var foldedHiddenPrefix: [Int] = []
    private var foldedNativeHiddenPrefix: [Int] = []
    private var foldedGitLines: NativeTextLineIndex?
    /// Git excludes the empty terminal line that TextKit retains after LF.
    private(set) var liveGitSourceLineCount: Int?

    private func rebuildFoldedHiddenPrefix() {
        var hidden = 0
        foldedHiddenPrefix = editingFolds.map { fold in
            hidden += max(0, fold.range.count - 1)
            return hidden
        }
    }

    private func rebuildFoldedUTF16Ranges() {
        let content = nativeContentManager as! FoldedDiffContentStorage
        guard let index = foldedGitLines, let storage = textStorage else {
            content.hiddenRanges = []
            foldedNativeHiddenPrefix = []
            return
        }
        let needsNativeParagraphs = hasNativeNonLFSeparators
        content.hiddenRanges = editingFolds.compactMap { fold in
            let start = index.offset(atLine: fold.range.lowerBound)
            let end = fold.range.upperBound >= index.lineCount
                ? index.length + 1 : index.offset(atLine: fold.range.upperBound)
            // The separator owns the first actual paragraph, even when one
            // Git-LF row contains several native CR/Unicode paragraphs.
            let firstEnd = needsNativeParagraphs && start < storage.length
                ? NSMaxRange(storage.mutableString.paragraphRange(
                    for: NSRange(location: start, length: 0)))
                : index.offset(atLine: fold.range.lowerBound + 1)
            return firstEnd < end ? firstEnd..<end : nil
        }
        var nativeHidden = 0
        foldedNativeHiddenPrefix = content.hiddenRanges.map { range in
            let first = lineNumber(atUTF16Offset: range.lowerBound) - 1
            let last = lineNumber(atUTF16Offset: range.upperBound) - 1
            nativeHidden += max(0, last - first)
            if range.upperBound > storage.length { nativeHidden += 1 }
            return nativeHidden
        }
    }

    func isNativeParagraphHidden(atUTF16 offset: Int) -> Bool {
        let ranges = (nativeContentManager as! FoldedDiffContentStorage).hiddenRanges
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].lowerBound <= offset { low = mid + 1 }
            else { high = mid }
        }
        return low > 0 && ranges[low - 1].contains(offset)
    }

    func hiddenNativeParagraphs(beforeUTF16 offset: Int) -> Int {
        let ranges = (nativeContentManager as! FoldedDiffContentStorage).hiddenRanges
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].upperBound <= offset { low = mid + 1 }
            else { high = mid }
        }
        let preceding = low == 0 ? 0 : foldedNativeHiddenPrefix[low - 1]
        guard low < ranges.count, ranges[low].contains(offset) else { return preceding }
        // A folded Git line may contain several native CR/Unicode paragraphs.
        // Hidden paragraphs inside that range must share the separator's
        // display row; counting only completed folds breaks Y monotonicity.
        let firstNativeRow = lineNumber(atUTF16Offset: ranges[low].lowerBound) - 1
        let currentNativeRow = lineNumber(atUTF16Offset: offset) - 1
        return preceding + currentNativeRow - firstNativeRow + 1
    }

    var totalHiddenNativeParagraphs: Int { foldedNativeHiddenPrefix.last ?? 0 }

    func hiddenSourceRows(before sourceRow: Int) -> Int {
        var low = 0
        var high = editingFolds.count
        while low < high {
            let middle = (low + high) / 2
            if editingFolds[middle].range.upperBound <= sourceRow { low = middle + 1 }
            else { high = middle }
        }
        let fullyHidden = low == 0 ? 0 : foldedHiddenPrefix[low - 1]
        if low < editingFolds.count {
            let fold = editingFolds[low].range
            if fold.contains(sourceRow) {
                // Every source row inside a fold projects onto its separator.
                return fullyHidden + sourceRow - fold.lowerBound
            }
        }
        return fullyHidden
    }

    struct LiveFoldEdit {
        let firstLine: Int
        let lastLine: Int
        let lineDelta: Int
        let endAtLineStart: Bool
        let foldsChanged: Bool
    }

    /// Fold in the TextKit layout, never in the underlying NSTextStorage.
    func setEditingFolds(_ folds: [DiffEditFold]) -> Bool {
        let oldFolds = editingFolds
        let layoutChanged = oldFolds != folds
        editingFolds = folds
        if layoutChanged { rebuildFoldedHiddenPrefix() }
        // A presentation refresh must never replace the live UTF-16 index
        // with offsets from an older immutable Diff snapshot.
        rebuildFoldedUTF16Ranges()
        if layoutChanged {
            if let storage = textStorage, storage.length > 0 {
                let changed = folds.difference(from: oldFolds)
                var first = Int.max
                for difference in changed {
                    let fold: DiffEditFold
                    switch difference {
                    case .insert(_, let value, _), .remove(_, let value, _): fold = value
                    }
                    first = min(first, fold.range.lowerBound)
                }
                let start = liveGitOffset(forLine: first) ?? 0
                storage.beginEditing()
                storage.edited(.editedAttributes,
                               range: NSRange(location: start, length: storage.length - start),
                               changeInLength: 0)
                storage.endEditing()
            }
            nativeLayoutManager.invalidateLayout(for: nativeLayoutManager.documentRange)
            needsLayout = true
            needsDisplay = true
        }
        return layoutChanged
    }

    func resetLiveGitLineIndex(_ text: String) {
        foldedGitLines = NativeTextLineIndex(gitLF: text)
        liveGitSourceLineCount = text.isEmpty ? 0
            : (foldedGitLines?.lineCount ?? 0) - (text.utf16.last == 10 ? 1 : 0)
    }
    var liveGitLineCount: Int? { foldedGitLines?.lineCount }
    func liveGitLine(atUTF16 offset: Int) -> Int? { foldedGitLines?.row(at: offset) }
    func liveGitOffset(forLine line: Int) -> Int? {
        guard let foldedGitLines, line >= 0, line < foldedGitLines.lineCount else { return nil }
        return foldedGitLines.offset(atLine: line)
    }

    /// Project collapsed source rows through a character edit before the
    /// background Diff reaches its 120 ms content version.
    func adjustLiveFoldSource(in previousRange: NSRange,
                              replacement: String) -> LiveFoldEdit? {
        guard let storage = textStorage,
              let originalCount = liveGitSourceLineCount,
              NSMaxRange(previousRange) <= (foldedGitLines?.length ?? -1) else { return nil }
        // A zero-width insertion after the final LF starts a new Git line,
        // even though the line index clamps EOF to the preceding row.
        let afterFinalLF = previousRange.length == 0
            && previousRange.location == foldedGitLines?.length
            && previousRange.location > 0
            && (foldedGitLines?.lineCount ?? 0) > originalCount
        let first = afterFinalLF ? originalCount
            : (foldedGitLines?.row(at: previousRange.location) ?? 0)
        let last = afterFinalLF ? originalCount
            : (foldedGitLines?.row(at: NSMaxRange(previousRange)) ?? 0)
        let endAtLineStart = afterFinalLF
            || foldedGitLines?.offset(atLine: last) == NSMaxRange(previousRange)
        foldedGitLines?.replace(in: previousRange,
                                replacementLength: replacement.utf16.count,
                                text: storage.mutableString)
        let sourceCount = storage.length == 0 ? 0
            : (foldedGitLines?.lineCount ?? 0)
                - (storage.mutableString.character(at: storage.length - 1) == 10 ? 1 : 0)
        let lineDelta = sourceCount - originalCount
        liveGitSourceLineCount = sourceCount
        if lineDelta == 0 {
            rebuildFoldedUTF16Ranges()
            return LiveFoldEdit(firstLine: first, lastLine: last,
                                lineDelta: 0, endAtLineStart: endAtLineStart,
                                foldsChanged: false)
        }
        let adjusted = editingFolds.compactMap { fold -> DiffEditFold? in
            if last < fold.range.lowerBound {
                let shifted = (fold.range.lowerBound + lineDelta)..<(fold.range.upperBound + lineDelta)
                return DiffEditFold(range: shifted, separator: fold.separator)
            }
            if first >= fold.range.upperBound { return fold }
            if first >= fold.range.lowerBound && last < fold.range.upperBound {
                let end = fold.range.upperBound + lineDelta
                guard end > fold.range.lowerBound else { return nil }
                return DiffEditFold(range: fold.range.lowerBound..<end,
                                    separator: fold.separator)
            }
            return nil
        }
        let changed = adjusted != editingFolds
        if changed {
            editingFolds = adjusted
            rebuildFoldedHiddenPrefix()
            nativeLayoutManager.invalidateLayout(for: nativeLayoutManager.documentRange)
            needsLayout = true
            needsDisplay = true
        }
        rebuildFoldedUTF16Ranges()
        return LiveFoldEdit(firstLine: first, lastLine: last,
                            lineDelta: lineDelta, endAtLineStart: endAtLineStart,
                            foldsChanged: changed)
    }

    var hasNativeNonLFSeparators: Bool { hasNativeOnlySeparators }

    override func storageCharactersDidChange(in previousRange: NSRange, replacement: String,
                                             nativeParagraphGeometryChanged: Bool) {
        // The shared native index tracks both paragraph count and separator
        // kinds. CRLF -> bare CR changes geometry even if row count is stable.
        if wrapsLines || nativeParagraphGeometryChanged {
            onNativeParagraphGeometryChanged?()
        }
    }

    /// Returns true when the click landed on a collapsed-run separator and
    /// was consumed by expanding it.
    var handleCollapsedClick: ((NSPoint) -> Bool)?
    var onResignFirstResponder: (() -> Void)?
    var onBecomeFirstResponder: (() -> Void)?

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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if handleCollapsedClick?(point) == true { return }
        super.mouseDown(with: event)
    }
}

// MARK: - Rows geometry

/// One visible row resolved against the current layout: its index, metadata,
/// and frame in text-view coordinates.
struct DiffVisibleRow {
    let index: Int
    let frame: CGRect
    /// Additional native visual line belonging to the same Git LF row.
    let isContinuation: Bool
    /// True only at the actual end of a Git line, not merely the viewport.
    let isLastSegment: Bool
}

/// Shared row-geometry walk used by the underlay and the gutter. Enumerates
/// the viewport's layout fragments and yields one entry per visual row.
///
/// Row indexes come from the immutable document's line-start table in review
/// mode; in edit mode the current TextKit paragraphs determine visible rows.
/// Ordinary LF documents use native paragraph counting; when bare CR splits
/// an additional paragraph, the Git row advances only at its next LF.
@MainActor
enum DiffRowGeometry {


    static func visibleRows(
        textView: DiffTextView, decorations: DiffDecorations
    ) -> [DiffVisibleRow] {
        let layoutManager = textView.nativeLayoutManager
        let contentManager = textView.nativeContentManager
        let viewport = layoutManager.textViewportLayoutController
        if viewport.viewportRange == nil { viewport.layoutViewport() }
        guard let viewportRange = viewport.viewportRange else { return [] }

        let byOffsets = !decorations.lineStartOffsets.isEmpty
        let nativeBreaks = textView.hasNativeNonLFSeparators
        var previousGitRow: Int?

        var rows: [DiffVisibleRow] = []
        layoutManager.enumerateTextLayoutFragments(in: viewportRange) { fragment in
            let fragmentFrame = fragment.layoutFragmentFrame
            let offset = contentManager.offset(
                from: layoutManager.documentRange.location,
                to: fragment.rangeInElement.location
            )
            let baseIndex = byOffsets
                ? (decorations.rowIndex(forUTF16Offset: offset) ?? 0)
                : (textView.liveGitLine(atUTF16: offset) ?? 0)
            let lineStart = byOffsets
                ? decorations.lineStartOffsets[baseIndex]
                : textView.liveGitOffset(forLine: baseIndex)
            if let lineStart, offset > lineStart { previousGitRow = baseIndex }

            // Native NSTextLineFragment.attributedString is the whole source
            // paragraph even for the synthetic zero-character terminal line.
            // Only characterRange identifies that extra line reliably.
            let bodyEnd = fragment.textLineFragments.lastIndex { $0.characterRange.length > 0 }
            let atDocumentEnd = fragment.rangeInElement.endLocation.compare(
                layoutManager.documentRange.endLocation
            ) == .orderedSame
            let terminatesGitLine = !nativeBreaks || atDocumentEnd
                || (fragment.textElement as? NSTextParagraph)?
                    .attributedString.string.utf16.last == 10
            var emittedBody = false
            for (linePosition, lineFragment) in fragment.textLineFragments.enumerated() {
                let extra = lineFragment.characterRange.length == 0
                let rowIndex = baseIndex + (extra && emittedBody ? 1 : 0)
                let continued = !extra && (emittedBody || previousGitRow == rowIndex)
                let endsGitLine = extra
                    ? bodyEnd == nil && atDocumentEnd
                    : linePosition == bodyEnd && terminatesGitLine
                let bounds = lineFragment.typographicBounds
                rows.append(DiffVisibleRow(
                    index: rowIndex,
                    frame: CGRect(
                        x: fragmentFrame.origin.x,
                        y: fragmentFrame.origin.y + bounds.minY
                            + textView.textContainerInset.height,
                        width: fragmentFrame.width,
                        height: bounds.height
                    ),
                    isContinuation: continued,
                    isLastSegment: endsGitLine
                ))
                if extra {
                    previousGitRow = nil
                } else {
                    emittedBody = true
                    previousGitRow = rowIndex
                }
            }
            return true
        }
        return rows
    }
}

/// Paint ghost rows independently of TextKit paragraph visibility. A long
/// deletion can fill the viewport even when its next live paragraph is far away.
@MainActor
private enum DiffGhostGeometry {
    struct VisibleBlock {
        let block: DiffDecorations.GhostBlock
        let bottomY: CGFloat
        let rowHeight: CGFloat
    }

    static func visibleBlocks(
        textView: DiffTextView, clipView: NSClipView, decorations: DiffDecorations
    ) -> [VisibleBlock] {
        guard textView.nativeLayoutManager.delegate != nil,
              !decorations.positionedGhosts.isEmpty else { return [] }
        let rowHeight = DiffTypography.paragraphStyle(
            for: textView.font ?? TerminalFont.current()
        ).maximumLineHeight
        guard rowHeight > 0 else { return [] }
        let viewport = clipView.bounds
        let ghosts = decorations.positionedGhosts
        // A leading deletion occupies the native text container's top inset.
        // Draw that ghost in the reserved gap, not on top of the first glyph.
        let leading = CGFloat(decorations.ghostsByAnchor[0]?.lines.count ?? 0) * rowHeight
        let inset = textView.textContainerInset.height - leading
        func topY(_ ghost: DiffDecorations.PositionedGhost) -> CGFloat {
            if (textView.wrapsLines || textView.hasNativeNonLFSeparators),
               let start = textView.ghostStartY?(ghost.block.anchorLine) {
                return start
            }
            return inset + CGFloat(ghost.visibleStartRow) * rowHeight
        }
        // Both the gutter and underlay query this on every scroll frame.
        // Skip blocks ending before the viewport instead of walking the file.
        var low = 0
        var high = ghosts.count
        while low < high {
            let middle = (low + high) / 2
            let ghost = ghosts[middle]
            let bottom = topY(ghost) + CGFloat(ghost.block.lines.count) * rowHeight
            if bottom <= viewport.minY { low = middle + 1 } else { high = middle }
        }
        var result: [VisibleBlock] = []
        for ghost in ghosts[low...] {
            let top = topY(ghost)
            if top >= viewport.maxY { break }
            let bottom = top + CGFloat(ghost.block.lines.count) * rowHeight
            result.append(VisibleBlock(
                block: ghost.block,
                bottomY: bottom - viewport.minY,
                rowHeight: rowHeight
            ))
        }
        return result
    }
}

// MARK: - Decoration underlay

/// Viewport-sized view behind the scroll view. Paints the pane background,
/// per-row diff tints, word-level emphasis, edit-mode deletion markers, and
/// the "no newline at end of file" glyph.
final class DiffDecorationUnderlayView: NSView {
    weak var textView: DiffTextView?
    weak var clipView: NSClipView?
    var decorations: DiffDecorations = .empty {
        didSet { needsDisplay = true }
    }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Text-view coordinates → this view's coordinates. The underlay's frame
    /// matches the scroll view's, and the clip view fills the scroll view, so
    /// the mapping is a translation by the scroll offset.
    private func converted(_ rect: CGRect) -> CGRect {
        guard let clipView else { return rect }
        return rect.offsetBy(
            dx: -clipView.bounds.origin.x, dy: -clipView.bounds.origin.y
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scheme = DiffColorScheme.current(dark: dark)

        scheme.background.setFill()
        dirtyRect.fill()

        guard let textView, let clipView, !decorations.rows.isEmpty else { return }
        let rows = DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)
        let virtualGhosts = textView.nativeLayoutManager.delegate != nil

        for row in rows {
            guard row.index < decorations.rows.count else { continue }
            let lastVisualSegment = row.isLastSegment
            let metadata = decorations.rows[row.index]
            let rowRect = CGRect(
                x: 0,
                y: converted(row.frame).origin.y,
                width: bounds.width,
                height: row.frame.height
            )
            // Pad the intersection test one point so the deletion marker
            // straddling the row's top edge isn't clipped away.
            guard rowRect.insetBy(dx: 0, dy: -2).intersects(dirtyRect) else { continue }

            switch metadata.kind {
            case .context:
                break
            case .added:
                scheme.addedRow.setFill()
                rowRect.fill()
            case .removed:
                scheme.removedRow.setFill()
                rowRect.fill()
            case .filler:
                scheme.fillerRow.setFill()
                rowRect.fill()
                drawFillerStripes(in: rowRect, color: scheme.fillerStripe)
            case .collapsed:
                // The shared foreground overlay owns the folded separator
                // for both read-only and editable text surfaces.
                break
            }

            if !metadata.emphasis.isEmpty {
                let emphasisColor = metadata.kind == .added
                    ? scheme.addedEmphasis : scheme.removedEmphasis
                emphasisColor.setFill()
                let sourceStart = decorations.lineStartOffsets.isEmpty
                    ? (textView.liveGitOffset(forLine: row.index) ?? 0) : 0
                for range in metadata.emphasis {
                    let absolute = NSRange(location: sourceStart + range.location,
                                           length: range.length)
                    for segment in segmentRects(for: absolute) {
                        let rect = converted(segment).intersection(rowRect)
                        guard !rect.isNull, rect.width > 0 else { continue }
                        NSBezierPath(
                            roundedRect: rect.insetBy(dx: 0, dy: 0.5),
                            xRadius: 2, yRadius: 2
                        ).fill()
                    }
                }
            }

            if metadata.missingNewline, lastVisualSegment {
                drawMissingNewlineBadge(
                    after: converted(row.frame), scheme: scheme
                )
            }

            // Read-only deletion ghosts (edit mode): the paragraph carries
            // spacing above it exactly tall enough for the block, and the
            // lines are drawn into that gap.
            if !virtualGhosts, !row.isContinuation,
               let block = decorations.ghostsByAnchor[row.index] {
                drawGhostBlock(
                    block,
                    endingAt: rowRect.minY,
                    rowHeight: row.frame.height,
                    textX: converted(row.frame).origin.x,
                    scheme: scheme
                )
            }
            // A deletion at end-of-file anchors past the last row and draws
            // below it (the last paragraph carries spacing after).
            if !virtualGhosts, lastVisualSegment, row.index == decorations.rows.count - 1,
               let block = decorations.ghostsByAnchor[decorations.rows.count] {
                drawGhostBlock(
                    block,
                    endingAt: rowRect.maxY + CGFloat(block.lines.count) * row.frame.height,
                    rowHeight: row.frame.height,
                    textX: converted(row.frame).origin.x,
                    scheme: scheme
                )
            }
        }
        if virtualGhosts {
            for ghost in DiffGhostGeometry.visibleBlocks(
                textView: textView, clipView: clipView, decorations: decorations
            ) {
                drawGhostBlock(
                    ghost.block, endingAt: ghost.bottomY, rowHeight: ghost.rowHeight,
                    textX: textView.textContainerInset.width - clipView.bounds.minX,
                    scheme: scheme
                )
            }
        }
    }

    /// Draws one ghost block whose last line's bottom edge sits at `bottomY`.
    private func drawGhostBlock(
        _ block: DiffDecorations.GhostBlock,
        endingAt bottomY: CGFloat,
        rowHeight: CGFloat,
        textX: CGFloat,
        scheme: DiffColorScheme
    ) {
        let startY = bottomY - CGFloat(block.lines.count) * rowHeight
        let first = max(0, Int(floor((bounds.minY - startY) / rowHeight)))
        let end = min(block.lines.count, Int(ceil((bounds.maxY - startY) / rowHeight)))
        guard first < end else { return }
        for index in first..<end {
            let y = startY + CGFloat(index) * rowHeight
            let rect = CGRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            (block.kind == .filler ? scheme.fillerRow : scheme.removedRow).setFill()
            rect.fill()
            if block.kind == .filler {
                drawFillerStripes(in: rect, color: scheme.fillerStripe)
            } else {
                block.lines[index].draw(at: CGPoint(x: textX, y: y))
            }
        }
    }

    /// Frames for a document range, in text-view coordinates. Ranges here are
    /// always within a single row, so segment enumeration yields one rect.
    private func segmentRects(for range: NSRange) -> [CGRect] {
        guard let textView,
              let textRange = NSTextRange(range, in: textView.nativeContentManager)
        else { return [] }
        var rects: [CGRect] = []
        textView.nativeLayoutManager.enumerateTextSegments(
            in: textRange, type: .standard, options: .rangeNotRequired
        ) { _, frame, _, _ in
            if frame.width > 0 { rects.append(frame) }
            return true
        }
        return rects
    }

    private func drawFillerStripes(in rect: CGRect, color: NSColor) {
        // Sparse diagonal hatching so filler rows read as "no content" rather
        // than empty lines.
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let step: CGFloat = 8
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.line(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        path.stroke()
    }

    private func drawMissingNewlineBadge(after lineFrame: CGRect, scheme: DiffColorScheme) {
        let text = NSAttributedString(
            string: "⌐ no newline",
            attributes: [
                .font: NSFont.systemFont(ofSize: max(8, lineFrame.height * 0.5)),
                .foregroundColor: scheme.annotationText,
            ]
        )
        let size = text.size()
        text.draw(at: CGPoint(
            x: lineFrame.maxX + 8,
            y: lineFrame.midY - size.height / 2
        ))
    }
}

// MARK: - Gutter

/// Which line numbers a pane's gutter shows.
enum DiffGutterLayout {
    /// One column carrying each row's own side: old numbers on removed rows,
    /// new numbers on added and context rows (unified view).
    case single
    /// A single column of old-file numbers (split view, left side).
    case oldOnly
    /// A single column of new-file numbers (split right side and edit mode).
    case newOnly
}

/// Fixed-width gutter to the left of a code pane: line numbers per file side,
/// a +/− change marker, row tint continuation, and edit-mode deletion
/// wedges. Sits outside the scroll view and repaints on scroll, so its
/// content never scrolls horizontally with the code.
final class DiffGutterView: NSView {
    weak var textView: DiffTextView?
    weak var clipView: NSClipView?
    var layoutStyle: DiffGutterLayout = .single
    var decorations: DiffDecorations = .empty {
        didSet {
            recalculateThickness()
            needsDisplay = true
        }
    }
    var font: NSFont = TerminalFont.current() {
        didSet {
            recalculateThickness()
            needsDisplay = true
        }
    }

    /// Width the pane should give the gutter for the current decorations.
    private(set) var thickness: CGFloat = 40

    private static let leadingPad: CGFloat = 8
    private static let markerWidth: CGFloat = 14

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        // An AX group (not an ignored view): its children are the virtual
        // "Expand N unmodified lines" buttons from accessibilityChildren(),
        // which an ignored view would drop from the hierarchy entirely.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(
            localized: "Diff gutter",
            comment: "Accessibility label for the diff view's line-number column."
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The number font: the code font's family at a slightly reduced size,
    /// matching how the editor's gutter reads against its text.
    private var numberFont: NSFont {
        let size = max(8, font.pointSize - 1.5)
        return NSFont(descriptor: font.fontDescriptor, size: size)
            ?? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    private func digitWidth(_ font: NSFont) -> CGFloat {
        ("8" as NSString).size(withAttributes: [.font: font]).width
    }

    private func recalculateThickness() {
        let numberFont = numberFont
        let digit = digitWidth(numberFont)
        func columnWidth(maxLine: Int) -> CGFloat {
            let digits = max(2, String(max(1, maxLine)).count)
            return CGFloat(digits) * digit
        }
        var width = Self.leadingPad
        switch layoutStyle {
        case .single:
            width += columnWidth(
                maxLine: max(decorations.maxOldLine, decorations.maxNewLine)
            )
        case .oldOnly:
            width += columnWidth(maxLine: decorations.maxOldLine)
        case .newOnly:
            width += columnWidth(maxLine: decorations.maxNewLine)
        }
        width += Self.markerWidth
        thickness = ceil(width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scheme = DiffColorScheme.current(dark: dark)

        scheme.background.setFill()
        dirtyRect.fill()

        guard let textView, let clipView, !decorations.rows.isEmpty else { return }
        let rows = DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)
        let virtualGhosts = textView.nativeLayoutManager.delegate != nil

        let numberFont = numberFont
        let digit = digitWidth(numberFont)

        func columnWidth(maxLine: Int) -> CGFloat {
            CGFloat(max(2, String(max(1, maxLine)).count)) * digit
        }

        // Right edge of the single number column per layout.
        let numberRight: CGFloat
        switch layoutStyle {
        case .single:
            numberRight = Self.leadingPad + columnWidth(
                maxLine: max(decorations.maxOldLine, decorations.maxNewLine)
            )
        case .oldOnly:
            numberRight = Self.leadingPad + columnWidth(maxLine: decorations.maxOldLine)
        case .newOnly:
            numberRight = Self.leadingPad + columnWidth(maxLine: decorations.maxNewLine)
        }
        let markerX = bounds.width - Self.markerWidth + 3

        for row in rows {
            guard row.index < decorations.rows.count else { continue }
            let lastVisualSegment = row.isLastSegment
            let metadata = decorations.rows[row.index]
            let y = row.frame.origin.y - clipView.bounds.origin.y
            let rowRect = CGRect(x: 0, y: y, width: bounds.width, height: row.frame.height)
            guard rowRect.intersects(dirtyRect) else { continue }

            var numberColor = scheme.gutterText
            var accentBar: NSColor?
            var marker: String?
            switch metadata.kind {
            case .context:
                break
            case .added:
                scheme.addedRow.setFill()
                rowRect.fill()
                numberColor = scheme.addedGutterText
                accentBar = scheme.addedGutterText
                marker = "+"
            case .removed:
                scheme.removedRow.setFill()
                rowRect.fill()
                numberColor = scheme.removedGutterText
                accentBar = scheme.removedGutterText
                marker = "−"
            case .filler:
                scheme.fillerRow.setFill()
                rowRect.fill()
            case .collapsed:
                scheme.collapsedBand.setFill()
                rowRect.fill()
                drawExpandChevrons(
                    in: rowRect,
                    direction: metadata.collapsed?.direction ?? .both,
                    color: scheme.annotationText
                )
                continue
            }

            // Edge accent on changed rows, like diffs.com's inline view.
            if let accentBar {
                accentBar.setFill()
                CGRect(x: 0, y: rowRect.minY, width: 3, height: rowRect.height).fill()
            }

            // EOF ghosts are drawn after the last physical segment, including
            // a native continuation from CR or a Unicode line separator.
            if !virtualGhosts, lastVisualSegment, row.index == decorations.rows.count - 1,
               let block = decorations.ghostsByAnchor[decorations.rows.count] {
                drawGhostGutterRows(
                    block,
                    endingAt: rowRect.maxY + CGFloat(block.lines.count) * row.frame.height,
                    rowHeight: row.frame.height,
                    numberFont: numberFont,
                    numberRight: numberRight,
                    markerX: markerX,
                    scheme: scheme
                )
            }
            // A physical continuation needs tint, not another number/ghost.
            if row.isContinuation { continue }

            // The number a row shows is its own side's: old for removed rows,
            // new for added and context (matching diffs.com's inline gutter);
            // split sides carry their fixed file side.
            let line: Int?
            switch layoutStyle {
            case .single:
                line = decorations.lineStartOffsets.isEmpty ? row.index + 1
                    : (metadata.kind == .removed ? metadata.oldLine : metadata.newLine)
            case .oldOnly:
                line = metadata.oldLine
            case .newOnly:
                line = decorations.lineStartOffsets.isEmpty ? row.index + 1 : metadata.newLine
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: numberColor,
            ]
            if let line {
                let string = NSAttributedString(string: String(line), attributes: attributes)
                let size = string.size()
                string.draw(at: CGPoint(
                    x: numberRight - size.width,
                    y: rowRect.midY - size.height / 2
                ))
            }
            if let marker {
                let string = NSAttributedString(string: marker, attributes: attributes)
                let size = string.size()
                string.draw(at: CGPoint(x: markerX, y: rowRect.midY - size.height / 2))
            }

            if !virtualGhosts, let block = decorations.ghostsByAnchor[row.index] {
                drawGhostGutterRows(
                    block,
                    endingAt: rowRect.minY,
                    rowHeight: rowRect.height,
                    numberFont: numberFont,
                    numberRight: numberRight,
                    markerX: markerX,
                    scheme: scheme
                )
            }

        }
        if virtualGhosts {
            for ghost in DiffGhostGeometry.visibleBlocks(
                textView: textView, clipView: clipView, decorations: decorations
            ) {
                drawGhostGutterRows(
                    ghost.block, endingAt: ghost.bottomY, rowHeight: ghost.rowHeight,
                    numberFont: numberFont, numberRight: numberRight, markerX: markerX,
                    scheme: scheme
                )
            }
        }
    }

    /// Gutter side of a deletion ghost block: row tints, old-file numbers,
    /// and − markers, ending at `bottomY`.
    private func drawGhostGutterRows(
        _ block: DiffDecorations.GhostBlock,
        endingAt bottomY: CGFloat,
        rowHeight: CGFloat,
        numberFont: NSFont,
        numberRight: CGFloat,
        markerX: CGFloat,
        scheme: DiffColorScheme
    ) {
        let startY = bottomY - CGFloat(block.lines.count) * rowHeight
        let first = max(0, Int(floor((bounds.minY - startY) / rowHeight)))
        let end = min(block.lines.count, Int(ceil((bounds.maxY - startY) / rowHeight)))
        guard first < end else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: scheme.removedGutterText,
        ]
        for lineOffset in first..<end {
            let y = startY + CGFloat(lineOffset) * rowHeight
            let rect = CGRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            (block.kind == .filler ? scheme.fillerRow : scheme.removedRow).setFill()
            rect.fill()
            if block.kind == .filler { continue }
            scheme.removedGutterText.setFill()
            CGRect(x: 0, y: rect.minY, width: 3, height: rect.height).fill()
            let number = NSAttributedString(
                string: String(block.firstOldLine + lineOffset), attributes: attributes
            )
            let numberSize = number.size()
            number.draw(at: CGPoint(
                x: numberRight - numberSize.width,
                y: rect.midY - numberSize.height / 2
            ))
            let marker = NSAttributedString(string: "−", attributes: attributes)
            let markerSize = marker.size()
            marker.draw(at: CGPoint(x: markerX, y: rect.midY - markerSize.height / 2))
        }
    }

    /// The expand affordance on a collapsed run: a chevron pointing where the
    /// revealed lines will appear, or a stacked pair for middle gaps that
    /// reveal at both edges.
    private func drawExpandChevrons(
        in rowRect: CGRect, direction: DiffCollapsedRun.Direction, color: NSColor
    ) {
        color.setStroke()
        let centerX = bounds.width / 2
        let width: CGFloat = 7
        let rise: CGFloat = 3.5
        let gap: CGFloat = 2.5

        func chevron(tipY: CGFloat, pointingUp: Bool) {
            let path = NSBezierPath()
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let baseY = tipY + (pointingUp ? rise : -rise)
            path.move(to: CGPoint(x: centerX - width / 2, y: baseY))
            path.line(to: CGPoint(x: centerX, y: tipY))
            path.line(to: CGPoint(x: centerX + width / 2, y: baseY))
            path.stroke()
        }

        switch direction {
        case .revealUp:
            chevron(tipY: rowRect.midY - rise / 2, pointingUp: true)
        case .revealDown:
            chevron(tipY: rowRect.midY + rise / 2, pointingUp: false)
        case .both:
            chevron(tipY: rowRect.midY - gap - rise, pointingUp: true)
            chevron(tipY: rowRect.midY + gap + rise, pointingUp: false)
        }
    }

    // MARK: Expansion interaction

    /// Fired with the fold's metadata when a collapsed separator row is
    /// clicked.
    var onExpandRun: ((DiffCollapsedRun) -> Void)?

    /// The collapsed run at a point in gutter coordinates, if any.
    private func collapsedRun(atGutterPoint point: NSPoint) -> DiffCollapsedRun? {
        guard let textView, let clipView else { return nil }
        let documentY = point.y + clipView.bounds.origin.y
        guard let row = DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)
            .first(where: { documentY >= $0.frame.minY && documentY < $0.frame.maxY }),
            row.index < decorations.rows.count
        else { return nil }
        return decorations.rows[row.index].collapsed
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let fold = collapsedRun(atGutterPoint: point) {
            onExpandRun?(fold)
            return
        }
        super.mouseDown(with: event)
    }

    /// Each visible collapsed row is exposed as an accessibility button, so
    /// the fold can be expanded without a pointer.
    private nonisolated final class ExpandAXElement: NSAccessibilityElement {
        // Accessibility can invoke this nonisolated ObjC entry point from
        // outside the main actor. Keep only a Sendable, actor-bound action.
        private nonisolated let press: @MainActor @Sendable () -> Void

        init(press: @escaping @MainActor @Sendable () -> Void) {
            self.press = press
            super.init()
        }

        nonisolated override func accessibilityPerformPress() -> Bool {
            let press = press
            if Thread.isMainThread {
                MainActor.assumeIsolated { press() }
            } else {
                Task { @MainActor in press() }
            }
            return true
        }
    }

    /// Owned by the view: the AX bridge resolves returned elements lazily, so
    /// elements built fresh inside `accessibilityChildren()` would be gone by
    /// the time an assistive client queries them.
    private var expandElements: [ExpandAXElement] = []

    override func accessibilityChildren() -> [Any]? {
        guard let textView, let clipView else { return nil }
        var elements: [ExpandAXElement] = []
        for row in DiffRowGeometry.visibleRows(textView: textView, decorations: decorations) {
            guard row.index < decorations.rows.count,
                  let info = decorations.rows[row.index].collapsed
            else { continue }
            let element = ExpandAXElement { [weak self] in
                self?.onExpandRun?(info)
            }
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(
                DiffCollapsedRunLabel.expandAction(hiddenLines: info.hiddenLines)
            )
            element.setAccessibilityParent(self)
            let top = row.frame.origin.y - clipView.bounds.origin.y
            element.setAccessibilityFrameInParentSpace(NSRect(
                x: 0,
                y: bounds.height - top - row.frame.height,
                width: bounds.width,
                height: row.frame.height
            ))
            elements.append(element)
        }
        expandElements = elements
        return elements.isEmpty ? nil : elements
    }
}

// MARK: - Code pane

/// Clip view that reports every scroll movement directly from its bounds
/// setters. NSScrollView reconfigures its subview stack when the find bar
/// appears, which can silently detach a bounds-change notification observer;
/// an override cannot be bypassed, so split-pane scroll sync and decoration
/// repaints survive.
private final class DiffClipView: NSClipView {
    var onBoundsChange: (() -> Void)?

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        onBoundsChange?()
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: newOrigin)
        onBoundsChange?()
    }
}

/// Paints the same folded separator over both review and editable TextKit.
/// Editable source paragraphs remain in storage, so a backdrop alone cannot
/// conceal their glyphs; one foreground painter keeps both modes identical.
private final class DiffFoldOverlayView: NSView {
    weak var textView: DiffTextView?
    weak var clipView: NSClipView?
    var decorations: DiffDecorations = .empty {
        didSet {
            hasCollapsedRows = decorations.rows.contains { $0.collapsed != nil }
            needsDisplay = true
        }
    }
    var labelFont: NSFont = .monospacedSystemFont(ofSize: 10, weight: .regular) {
        didSet { needsDisplay = true }
    }
    private var hasCollapsedRows = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard hasCollapsedRows, let textView, let clipView else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colors = DiffColorScheme.current(dark: dark)
        for row in DiffRowGeometry.visibleRows(textView: textView, decorations: decorations) {
            guard row.index < decorations.rows.count,
                  let fold = decorations.rows[row.index].collapsed,
                  !row.isContinuation else { continue }
            let frame = CGRect(x: 0, y: row.frame.minY - clipView.bounds.minY,
                               width: bounds.width, height: row.frame.height)
            guard frame.intersects(dirtyRect) else { continue }
            colors.collapsedBand.setFill()
            frame.fill()
            let label = NSAttributedString(
                string: DiffCollapsedRunLabel.text(hiddenLines: fold.hiddenLines),
                attributes: [.font: labelFont, .foregroundColor: colors.annotationText]
            )
            let size = label.size()
            label.draw(at: CGPoint(x: 12, y: frame.midY - size.height / 2))
        }
    }
}

/// One diff column: gutter + decoration underlay + transparent scroll/text
/// stack. Configured once as review (immutable attributed document) or edit
/// (live buffer with the editor's syntax plugin); the mode never changes for
/// a given instance: review and editable content retain distinct state.
final class DiffCodePaneView: NSView {
    enum Mode {
        case review
        case edit
    }

    let mode: Mode
    let scrollView = NSScrollView()
    let textView = DiffTextView()
    private let underlay = DiffDecorationUnderlayView()
    private let gutter = DiffGutterView()
    private let foldOverlay = DiffFoldOverlayView()
    /// Re-entrancy guard for vertical scroll syncing between split panes.
    private var isSyncingScroll = false
    private var isRefreshingViewport = false
    private var lastViewportBounds: NSRect?

    var onScroll: ((NSPoint) -> Void)?
    /// Fired with the fold's metadata when the user activates a collapsed-run
    /// separator (row click, gutter click, or accessibility press).
    var onExpandCollapsedRun: ((DiffCollapsedRun) -> Void)?
    /// Set while a fold-expansion click is waiting for its rebuilt document,
    /// so the swap keeps the raw scroll offset instead of re-anchoring by
    /// line. Single-shot.
    private var pendingExpansionSwap = false
    /// Identity of the display whose document this pane currently shows, so
    /// re-renders skip the expensive document swap when nothing changed.
    var renderedDisplayID: UUID?

    var decorations: DiffDecorations = .empty {
        didSet {
            underlay.decorations = decorations
            gutter.decorations = decorations
            foldOverlay.decorations = decorations
            let thickness = gutter.thickness
            if abs(thickness - gutterWidth) > 0.5 {
                gutterWidth = thickness
                needsLayout = true
            }
            if mode == .edit {
                if decorations.rows.count != oldValue.rows.count {
                    invalidateDocumentLayout()
                }
                applyGhostSpacing()
                applyContentHeightOverride()
            }
        }
    }

    private var appliedFoldRevision: UInt?
    private var needsCompleteDocumentLayout = false
    private var measuredDocumentHeight: CGFloat?
    private struct WrappedExtra: Equatable {
        let nativeRow: Int
        let prefix: Int
    }
    private var wrappedExtras: [WrappedExtra] = []
    private var lastLayoutWidth: CGFloat = 0
    private enum ReviewScrollTarget {
        case anchor(old: Int?, new: Int?, viewportY: CGFloat)
        case offset(CGFloat)
        case row(Int)
    }
    private var pendingReviewScroll: ReviewScrollTarget?

    private func rememberReviewAnchor() {
        guard mode == .review, pendingReviewScroll == nil,
              rowHeight > 0, !decorations.rows.isEmpty else { return }
        let y = scrollOffset.y
        for row in DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)
        where row.frame.maxY > y + 1 && row.index < decorations.rows.count {
            let source = decorations.rows[row.index]
            if source.oldLine != nil || source.newLine != nil {
                pendingReviewScroll = .anchor(old: source.oldLine, new: source.newLine,
                                              viewportY: row.frame.minY - y)
                break
            }
        }
    }

    private func displayRow(forSourceRow sourceRow: Int) -> Int {
        guard mode == .edit else { return sourceRow }
        let visibleRow = sourceRow - textView.hiddenSourceRows(before: sourceRow)
        let ghosts = decorations.positionedGhosts
        var low = 0
        var high = ghosts.count
        while low < high {
            let mid = (low + high) / 2
            if ghosts[mid].block.anchorLine <= sourceRow { low = mid + 1 }
            else { high = mid }
        }
        guard low > 0 else { return visibleRow }
        let last = ghosts[low - 1]
        return visibleRow + last.startRow - last.block.anchorLine + last.block.lines.count
    }

    private var usesNativeParagraphFixedLayout: Bool {
        rowHeight > 0 && !textView.wrapsLines && textView.hasNativeNonLFSeparators
    }

    private var usesPlainSourceFixedLayout: Bool {
        // A historical plain source is read-only and has no diff rows.
        // Empty decorations during an editable buffer replacement are transient.
        mode == .edit && !textView.isEditable && decorations.rows.isEmpty
            && textView.liveGitSourceLineCount != nil && rowHeight > 0
            && !textView.wrapsLines && !textView.hasNativeNonLFSeparators
    }

    private var usesSparseWrappedLayout: Bool {
        rowHeight > 0 && textView.wrapsLines && textView.longLineDisplayWidth == .showAll
    }

    private func extraWrappedRows(beforeNativeRow nativeRow: Int) -> Int {
        var low = 0
        var high = wrappedExtras.count
        while low < high {
            let mid = (low + high) / 2
            if wrappedExtras[mid].nativeRow < nativeRow { low = mid + 1 }
            else { high = mid }
        }
        return low == 0 ? 0 : wrappedExtras[low - 1].prefix
    }

    private func rebuildSparseWrappedLayout() {
        let content = textView.nativeContentManager
        let layout = textView.nativeLayoutManager
        let length = content.length
        guard let storage = textView.textStorage else { return }
        var prefix = 0
        var mapped: [WrappedExtra] = []
        for candidate in textView.nativeWrapCandidates() {
            guard candidate.offset < length,
                  !textView.isNativeParagraphHidden(atUTF16: candidate.offset) else { continue }
            // A wrapped paragraph must be laid out through its final line;
            // asking TextKit for only its first character is insufficient.
            let paragraph = storage.mutableString.paragraphRange(
                for: NSRange(location: candidate.offset, length: 0))
            guard let range = NSTextRange(paragraph, in: content) else { continue }
            layout.ensureLayout(for: range)
            guard let fragment = layout.textLayoutFragment(for: range.location) else { continue }
            let extra = max(0, fragment.textLineFragments.filter {
                $0.characterRange.length > 0
            }.count - 1)
            guard extra > 0 else { continue }
            prefix += extra
            mapped.append(WrappedExtra(nativeRow: candidate.row, prefix: prefix))
        }
        if wrappedExtras != mapped {
            wrappedExtras = mapped
            layout.invalidateLayout(for: layout.documentRange)
        }
    }

    private func fixedFragmentRow(atUTF16 offset: Int) -> Int {
        if usesNativeParagraphFixedLayout || usesSparseWrappedLayout {
            let nativeRow = textView.lineNumber(atUTF16Offset: offset) - 1
            let wrappedRows = extraWrappedRows(beforeNativeRow: nativeRow)
            guard mode == .edit, let gitRow = textView.liveGitLine(atUTF16: offset) else {
                return nativeRow + wrappedRows
            }
            let visibleSourceRow = gitRow - textView.hiddenSourceRows(before: gitRow)
            let precedingGhosts = displayRow(forSourceRow: gitRow) - visibleSourceRow
            let leading = decorations.ghostsByAnchor[0]?.lines.count ?? 0
            return nativeRow - textView.hiddenNativeParagraphs(beforeUTF16: offset)
                + wrappedRows + precedingGhosts - leading
        }
        let sourceRow = mode == .review
            ? (decorations.rowIndex(forUTF16Offset: offset) ?? 0)
            : (textView.liveGitLine(atUTF16: offset) ?? textView.lineNumber(atUTF16Offset: offset) - 1)
        // Leading deletion ghosts are represented by the native text inset;
        // all other ghost rows belong to the text fragment's display coordinate.
        let leading = mode == .edit ? (decorations.ghostsByAnchor[0]?.lines.count ?? 0) : 0
        return displayRow(forSourceRow: sourceRow) - leading
    }

    private func invalidateDocumentLayout() {
        needsCompleteDocumentLayout = true
        measuredDocumentHeight = nil
        wrappedExtras = []
        lastViewportBounds = nil
        needsLayout = true
    }

    func setEditingFolds(_ folds: [DiffEditFold],
                         baseDecorations: DiffDecorations, revision: UInt) {
        guard appliedFoldRevision != revision else { return }
        appliedFoldRevision = revision
        if textView.setEditingFolds(folds) {
            textView.setFixedLayoutRowHeight(nil)
            invalidateDocumentLayout()
        }
        var decorated = baseDecorations
        decorated.positionGhosts(for: folds)
        for fold in folds where fold.range.lowerBound < decorated.rows.count {
            decorated.rows[fold.range.lowerBound].kind = .collapsed
            decorated.rows[fold.range.lowerBound].collapsed = fold.separator
        }
        decorations = decorated
        if !folds.isEmpty { setFixedRowCount(nil) }
    }

    private var appliedGhostCounts: [Int: Int] = [:]

    /// Called only after the owning Diff tab is permanently closed.
    func retireNativeDocument() {
        onScroll = nil
        onExpandCollapsedRun = nil
        textView.handleCollapsedClick = nil
        textView.ghostStartY = nil
        textView.layoutRowForUTF16 = nil
        textView.onBecomeFirstResponder = nil
        textView.onResignFirstResponder = nil
        textView.retireNativeDocument()
        // A closed Diff has no remaining native owner. Detach its document
        // before removing the TextKit layout manager, which otherwise keeps
        // the content storage and paragraph cache alive after view disposal.
        let storage = textView.textContentStorage
        let layout = textView.textLayoutManager
        scrollView.documentView = nil
        if let storage, let layout { storage.removeTextLayoutManager(layout) }
        foldOverlay.decorations = .empty
        appliedGhostCounts = [:]
    }

    /// A new source owns its own folds, deletion ghosts and row decorations.
    /// Retire the old presentation before installing the new editable bytes.
    func setEditBufferText(_ text: String) {
        appliedFoldRevision = nil
        if !decorations.rows.isEmpty || !decorations.ghostsByAnchor.isEmpty {
            decorations = .empty
        }
        if !textView.editingFolds.isEmpty { _ = textView.setEditingFolds([]) }
        appliedGhostCounts = [:]
        textView.setFixedLayoutRowHeight(nil)
        textView.textContainerInset = .zero
        invalidateDocumentLayout()
        textView.text = text
        textView.resetLiveGitLineIndex(text)
        textView.configureWrapping(false, viewportWidth: scrollView.contentView.bounds.width)
        applyContentHeightOverride()
    }

    func applyLiveNativeEdit(previousRange: NSRange, replacement: String) {
        let previousFolds = textView.editingFolds
        guard mode == .edit,
              let live = textView.adjustLiveFoldSource(in: previousRange,
                                                        replacement: replacement) else { return }
        guard live.lineDelta != 0 || live.foldsChanged else { return }
        guard let liveCount = textView.liveGitSourceLineCount else { return }
        let count = max(1, liveCount)
        let previous = decorations
        let firstUnaffected = live.lastLine + (live.endAtLineStart ? 0 : 1)
        let newFirstUnaffected = firstUnaffected + live.lineDelta
        let firstChanged = min(live.firstLine, previous.rows.count, count)
        let lastReplaced = liveCount - live.lineDelta == 0 ? previous.rows.count
            : min(max(firstChanged, firstUnaffected), previous.rows.count)
        let nextUnaffected = liveCount == 0 ? count
            : min(max(firstChanged, newFirstUnaffected), count)
        var rows = previous.rows
        let newRows = (firstChanged..<nextUnaffected).map { line in
            DiffDecorations.Row(kind: .context, oldLine: nil, newLine: line + 1,
                                emphasis: [], missingNewline: false)
        }
        rows.replaceSubrange(firstChanged..<lastReplaced, with: newRows)
        if live.foldsChanged {
            for fold in previousFolds {
                let index = fold.range.lowerBound < firstChanged ? fold.range.lowerBound
                    : fold.range.lowerBound >= firstUnaffected
                        ? fold.range.lowerBound + live.lineDelta : -1
                guard rows.indices.contains(index) else { continue }
                rows[index].kind = .context
                rows[index].collapsed = nil
            }
        }
        var updated = DiffDecorations(
            rows: rows, lineStartOffsets: [],
            maxOldLine: previous.maxOldLine, maxNewLine: count)
        for (anchor, block) in previous.ghostsByAnchor {
            guard anchor < live.firstLine || anchor >= firstUnaffected else { continue }
            let nextAnchor = anchor >= firstUnaffected ? anchor + live.lineDelta : anchor
            updated.ghostsByAnchor[nextAnchor] = DiffDecorations.GhostBlock(
                anchorLine: nextAnchor, firstOldLine: block.firstOldLine,
                lines: block.lines, kind: block.kind)
        }
        var precedingGhostRows = 0
        for (anchor, block) in updated.ghostsByAnchor.sorted(by: { $0.key < $1.key }) {
            updated.positionedGhosts.append(.init(
                startRow: anchor + precedingGhostRows,
                visibleStartRow: anchor + precedingGhostRows, block: block))
            precedingGhostRows += block.lines.count
        }
        updated.positionGhosts(for: textView.editingFolds)
        if live.foldsChanged {
            for fold in textView.editingFolds where fold.range.lowerBound < updated.rows.count {
                updated.rows[fold.range.lowerBound].kind = .collapsed
                updated.rows[fold.range.lowerBound].collapsed = fold.separator
            }
        }
        invalidateDocumentLayout()
        decorations = updated
    }

    /// Reserve deletion rows in the same native fragment coordinates as the
    /// source text. Paragraph attributes remain untouched for Undo and syntax.
    private func applyGhostSpacing() {
        guard rowHeight > 0 else { return }
        let wanted = decorations.ghostsByAnchor.mapValues { $0.lines.count }
        let leadingHeight = CGFloat(wanted[0] ?? 0) * rowHeight
        guard wanted != appliedGhostCounts
            || abs(textView.textContainerInset.height - leadingHeight) > 0.5 else { return }
        appliedGhostCounts = wanted
        if abs(textView.textContainerInset.height - leadingHeight) > 0.5 {
            textView.textContainerInset = NSSize(width: 0, height: leadingHeight)
        }
        textView.nativeLayoutManager.invalidateLayout(for: textView.nativeLayoutManager.documentRange)
        invalidateDocumentLayout()
    }

    private var gutterWidth: CGFloat = 40

    init(mode: Mode, gutterLayout: DiffGutterLayout) {
        self.mode = mode
        super.init(frame: .zero)
        gutter.layoutStyle = gutterLayout

        wantsLayer = true

        // Transparent stack: the underlay paints the background (and tints)
        // behind everything.
        let clipView = DiffClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.clipsToBounds = true
        scrollView.documentView = textView
        textView.layoutRowForUTF16 = { [weak self] offset in
            self?.fixedFragmentRow(atUTF16: offset) ?? 0
        }
        textView.ghostStartY = { [weak self] anchor in
            self?.ghostStartY(forAnchor: anchor) ?? 0
        }
        textView.onNativeParagraphGeometryChanged = { [weak self] in
            self?.invalidateDocumentLayout()
        }
        clipView.onBoundsChange = { [weak self] in
            self?.handleScrolled()
        }

        // Native NSTextView paints an opaque system background by default;
        // keep diff row tints, word emphasis and deletion ghosts visible below it.
        textView.drawsBackground = false
        textView.isEditable = mode == .edit
        textView.isSelectable = true
        textView.highlightSelectedLine = false
        textView.showsLineNumbers = false
        textView.configureWrapping(false, viewportWidth: scrollView.contentView.bounds.width)
        textView.isIncrementalSearchingEnabled = true
        // Review documents are swapped wholesale (fold expansion, reloads);
        // the caret-follow scroll after such a swap would jump to the top and
        // discard the restored scroll position. Editors keep it for typing.

        underlay.textView = textView
        underlay.clipView = scrollView.contentView
        foldOverlay.textView = textView
        foldOverlay.clipView = scrollView.contentView
        gutter.textView = textView
        gutter.clipView = scrollView.contentView

        textView.handleCollapsedClick = { [weak self] point in
            self?.expandCollapsedRow(atDocumentY: point.y) ?? false
        }
        gutter.onExpandRun = { [weak self] fold in
            self?.activateFold(fold)
        }

        addSubview(underlay)
        addSubview(gutter)
        addSubview(scrollView)
        // The clipped document layer covers source glyphs, not native scrollers.
        clipView.addSubview(foldOverlay, positioned: .above, relativeTo: textView)
        foldOverlay.frame = clipView.bounds
        foldOverlay.autoresizingMask = [.width, .height]

        // Repaint decorations after every viewport layout pass; scroll
        // movements are reported synchronously by DiffClipView above.
    }

    /// Repaint viewport decorations and synchronize both axes in split mode.
    private func handleScrolled() {
        let viewport = scrollView.contentView.bounds
        if !isRefreshingViewport && !needsCompleteDocumentLayout
            && lastViewportBounds != viewport {
            isRefreshingViewport = true
            let previousY = lastViewportBounds?.minY ?? 0
            if viewport.height > 0 && abs(viewport.minY - previousY) > viewport.height {
                materializeNativeViewport(at: viewport.minY)
            }
            lastViewportBounds = viewport
            if !isSyncingScroll {
                scrollView.reflectScrolledClipView(scrollView.contentView)
                textView.nativeLayoutManager.textViewportLayoutController.layoutViewport()
            }
            lastViewportBounds = scrollView.contentView.bounds
            isRefreshingViewport = false
        }
        if foldOverlay.frame != viewport { foldOverlay.frame = viewport }
        underlay.needsDisplay = true
        gutter.needsDisplay = true
        foldOverlay.needsDisplay = true
        if !isSyncingScroll {
            onScroll?(scrollView.contentView.bounds.origin)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        let contentFrame = CGRect(
            x: gutterWidth, y: 0,
            width: max(0, bounds.width - gutterWidth), height: bounds.height
        )
        scrollView.frame = contentFrame
        textView.configureWrapping(false, viewportWidth: scrollView.contentView.bounds.width)
        let width = scrollView.contentView.bounds.width
        if textView.wrapsLines && abs(width - lastLayoutWidth) > 0.5 {
            invalidateDocumentLayout()
        }
        lastLayoutWidth = width
        if needsCompleteDocumentLayout, bounds.width > 0, bounds.height > 0 {
            needsCompleteDocumentLayout = false
            let fixedLF = rowHeight > 0 && !textView.wrapsLines
                && !textView.hasNativeNonLFSeparators
                && (!decorations.rows.isEmpty || usesPlainSourceFixedLayout)
            let fixedNative = usesNativeParagraphFixedLayout
            let sparseWrapped = usesSparseWrappedLayout
            textView.setFixedLayoutRowHeight(fixedLF || fixedNative || sparseWrapped ? rowHeight : nil)
            if sparseWrapped {
                rebuildSparseWrappedLayout()
            } else if !fixedLF && !fixedNative {
                let layout = textView.nativeLayoutManager
                layout.ensureLayout(for: layout.documentRange)
                measuredDocumentHeight = ceil(layout.usageBoundsForTextContainer.maxY)
            }
            applyContentHeightOverride()
        }
        if let target = pendingReviewScroll, bounds.width > 0, bounds.height > 0 {
            pendingReviewScroll = nil
            switch target {
            case .offset(let y):
                setVerticalScrollOffset(y)
            case .row(let index):
                setVerticalScrollOffset(documentY(forRow: index))
            case .anchor(let old, let new, let viewportY):
                if let index = decorations.rows.firstIndex(where: {
                    $0.oldLine == old && $0.newLine == new
                }) {
                    // A replaced TextKit document may preserve the clip Y
                    // while its target paragraph has no realized glyph lines.
                    materializeSourceRow(index)
                    setVerticalScrollOffset(max(0, documentY(forRow: index) - viewportY))
                    textView.nativeLayoutManager.textViewportLayoutController.layoutViewport()
                } else {
                    setVerticalScrollOffset(0)
                }
            }
        }
        underlay.frame = contentFrame
        foldOverlay.frame = scrollView.contentView.bounds
        // A document swap can shrink past the previous viewport origin.
        // NSClipView does not necessarily re-constrain that old origin when
        // NSTextView changes its frame during the same layout pass.
        scrollView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        var constrained = clip.constrainBoundsRect(clip.bounds).origin
        if mode == .review, let fixedRowCount,
           CGFloat(fixedRowCount) * rowHeight <= clip.bounds.height {
            // A compact diff fits entirely in the viewport. Previous deep
            // scroll coordinates have no matching content after the swap.
            constrained.y = 0
        }
        setScrollOffset(constrained)
        // Row rects span the current width; a resize must repaint them.
        underlay.needsDisplay = true
        gutter.needsDisplay = true
        foldOverlay.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        underlay.needsDisplay = true
        gutter.needsDisplay = true
        foldOverlay.needsDisplay = true
    }

    /// Follow a sibling pane without echoing scroll events back to it.
    func setScrollOffset(_ origin: NSPoint) {
        let clipView = scrollView.contentView
        let constrained = clipView.constrainBoundsRect(NSRect(origin: origin, size: clipView.bounds.size)).origin
        let current = clipView.bounds.origin
        guard abs(current.x - constrained.x) > 0.01 || abs(current.y - constrained.y) > 0.01 else { return }
        isSyncingScroll = true
        defer { isSyncingScroll = false }
        clipView.scroll(to: constrained)
        scrollView.reflectScrolledClipView(clipView)
        textView.nativeLayoutManager.textViewportLayoutController.layoutViewport()
    }

    func setVerticalScrollOffset(_ y: CGFloat) {
        let current = scrollView.contentView.bounds.origin
        setScrollOffset(NSPoint(x: current.x, y: y))
    }

    var scrollOffset: NSPoint { scrollView.contentView.bounds.origin }

    /// The fixed row height from the last applied paragraph style, for
    /// layout-independent scroll math.
    private var rowHeight: CGFloat = 0
    /// Review documents have a known row count; with the pinned line height
    /// that fixes the exact content height, so both split sides agree on
    /// their scroll range instead of trusting TextKit2's estimates (which
    /// undershoot runs of empty filler lines). Nil for the live edit buffer.
    private var fixedRowCount: Int?

    func setFixedRowCount(_ rows: Int?) {
        fixedRowCount = rows
        applyContentHeightOverride()
    }

    /// Marks the coming document swap as a fold expansion and reports it.
    private func activateFold(_ info: DiffCollapsedRun) {
        pendingExpansionSwap = true
        onExpandCollapsedRun?(info)
    }

    /// Swaps in a review document while keeping the reading position.
    ///
    /// Fold expansion inserts rows at the clicked separator, which is on
    /// screen — every row above the viewport keeps its index — so keeping the
    /// raw scroll offset leaves the content above the separator untouched
    /// while the revealed lines flow in at the click point (how GitHub and
    /// diffs.com behave). Other swaps (reloads, font/theme rebuilds) may
    /// change content anywhere, so they re-anchor to the first visible row
    /// carrying file line numbers instead.
    func setReviewDocument(_ text: NSAttributedString, decorations newDecorations: DiffDecorations) {
        let isExpansionSwap = pendingExpansionSwap
        pendingExpansionSwap = false
        let contentChanged = textView.attributedText.string != text.string
        if isExpansionSwap {
            pendingReviewScroll = .offset(scrollOffset.y)
        } else {
            rememberReviewAnchor()
        }
        invalidateDocumentLayout()
        defer {
            if contentChanged && !isExpansionSwap {
                let y = scrollView.contentView.bounds.origin.y
                setScrollOffset(NSPoint(x: 0, y: y))
            }
        }

        let selection = contentChanged ? nil : textView.selectedRanges
        textView.attributedText = text
        if let selection { textView.selectedRanges = selection }
        textView.configureWrapping(false, viewportWidth: scrollView.contentView.bounds.width)
        decorations = newDecorations
        // The shared native line index already owns paragraph separator kinds.
        setFixedRowCount(textView.wrapsLines || textView.hasNativeNonLFSeparators
            ? nil : newDecorations.rows.count)

        // The actual row positions are available after the next complete
        // layout; restoration there avoids anchoring to estimated TextKit Y.
    }

    /// Expands the collapsed run whose separator row contains `documentY`
    /// (text-view coordinates); returns whether one was hit.
    private func expandCollapsedRow(atDocumentY documentY: CGFloat) -> Bool {
        guard let row = DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)
            .first(where: { documentY >= $0.frame.minY && documentY < $0.frame.maxY }),
            row.index < decorations.rows.count,
            let info = decorations.rows[row.index].collapsed
        else { return false }
        activateFold(info)
        return true
    }

    private func applyContentHeightOverride() {
        var height = fixedRowCount.map { CGFloat($0) * rowHeight }
        if usesNativeParagraphFixedLayout || usesSparseWrappedLayout
            || usesPlainSourceFixedLayout {
            let length = textView.textStorage?.length ?? 0
            let ghostRows = mode == .edit ? decorations.ghostsByAnchor.values.reduce(0) {
                $0 + $1.lines.count
            } : 0
            height = needsCompleteDocumentLayout && usesSparseWrappedLayout
                ? textView.overrideContentHeight
                : CGFloat(textView.lineNumber(atUTF16Offset: length)
                    - textView.totalHiddenNativeParagraphs + ghostRows
                    + (wrappedExtras.last?.prefix ?? 0)) * rowHeight
        } else if textView.wrapsLines || textView.hasNativeNonLFSeparators
            || (mode == .edit && decorations.rows.isEmpty) {
            height = measuredDocumentHeight
        } else if mode == .edit {
            let empty = textView.nativeContentManager.documentRange.isEmpty
            if empty, let ghosts = decorations.ghostsByAnchor[decorations.rows.count] {
                height = CGFloat(ghosts.lines.count + 1) * rowHeight
            } else if !empty, !textView.wrapsLines, !textView.hasNativeNonLFSeparators,
                      max(1, textView.liveGitSourceLineCount ?? 0) == decorations.rows.count {
                let hidden = textView.editingFolds.reduce(0) {
                    $0 + max(0, $1.range.count - 1)
                }
                let removed = decorations.ghostsByAnchor.values.reduce(0) {
                    $0 + $1.lines.count
                }
                height = CGFloat(max(1, decorations.rows.count - hidden) + removed) * rowHeight
            } else {
                height = nil
            }
        }
        if textView.overrideContentHeight != height {
            textView.overrideContentHeight = height
            textView.needsLayout = true
        }
    }

    /// Guarded assignments: the font/color/paragraph-style setters restyle the
    /// whole document, and this runs on every re-render (each keystroke while
    /// editing).
    func applyTypography(font: NSFont, paragraphStyle: NSParagraphStyle, textColor: NSColor,
                         longLineDisplayWidth: LongLineDisplayWidth = .standard) {
        let previousFont = textView.font
        let previousWidth = textView.longLineDisplayWidth
        let wasWrapping = textView.wrapsLines
        if previousFont != font || previousWidth != longLineDisplayWidth {
            rememberReviewAnchor()
        }
        if textView.font != font {
            textView.font = font
        }
        textView.longLineDisplayWidth = longLineDisplayWidth
        textView.configureWrapping(false, viewportWidth: scrollView.contentView.bounds.width)
        if previousFont != font || previousWidth != longLineDisplayWidth
            || wasWrapping != textView.wrapsLines {
            invalidateDocumentLayout()
        }
        let effectiveStyle: NSParagraphStyle
        if textView.truncatesLongLines {
            let style = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            style.lineBreakMode = .byTruncatingTail
            effectiveStyle = style
        } else {
            effectiveStyle = paragraphStyle
        }
        if textView.defaultParagraphStyle?.isEqual(effectiveStyle) != true {
            textView.defaultParagraphStyle = effectiveStyle
            textView.typingAttributes[.paragraphStyle] = effectiveStyle
        }
        // Review documents own their per-token foreground attributes. Setting
        // NSTextView.textColor would overwrite all of those colors in storage.
        if mode == .edit, textView.textColor != textColor {
            textView.textColor = textColor
        }
        if gutter.font != font {
            gutter.font = font
        }
        let labelFont = NSFont(
            descriptor: font.fontDescriptor, size: max(8, font.pointSize - 1.5)
        ) ?? font
        if foldOverlay.labelFont != labelFont {
            foldOverlay.labelFont = labelFont
        }
        let oldRowHeight = rowHeight
        rowHeight = paragraphStyle.maximumLineHeight
        if mode == .edit {
            let typographyChanged = previousFont != font || abs(oldRowHeight - rowHeight) > 0.5
            if typographyChanged || wasWrapping != textView.wrapsLines {
                applyGhostSpacing()
            }
        }
        if mode == .review, !decorations.rows.isEmpty {
            fixedRowCount = textView.wrapsLines || textView.hasNativeNonLFSeparators
                ? nil : decorations.rows.count
        }
        applyContentHeightOverride()
    }

    /// First visible row index, for restoring position across folded/full
    /// presentations and document reloads.
    var firstVisibleRowIndex: Int? {
        DiffRowGeometry.visibleRows(textView: textView, decorations: decorations)
            .first(where: { $0.frame.maxY > scrollView.contentView.bounds.minY + 1 })?
            .index
    }

    /// The same native row geometry is used for explicit navigation and for
    /// keeping a stable reading anchor when a review document is replaced.
    /// Materialize the owning source paragraph before a cold scrollbar jump;
    /// TextKit's estimated folded positions cannot locate it by Y alone.
    private func materializeNativeViewport(at y: CGFloat) {
        guard mode == .edit,
              rowHeight > 0, textView.nativeLayoutManager.delegate != nil,
              let liveCount = textView.liveGitSourceLineCount else { return }
        let rowCount = decorations.rows.count
        guard rowCount > 0, max(1, liveCount) == rowCount else { return }
        var low = 0
        var high = rowCount
        while low < high {
            let mid = (low + high) / 2
            if documentY(forRow: mid) < y { low = mid + 1 }
            else { high = mid }
        }
        // The published Diff projection can be older than an in-progress
        // inline edit. Always materialize the target from the live text index.
        materializeSourceRow(min(low, rowCount - 1))
    }

    private func materializeSourceRow(_ row: Int) {
        let offset = mode == .review
            ? (decorations.lineStartOffsets.indices.contains(row)
                ? decorations.lineStartOffsets[row] : nil)
            : textView.liveGitOffset(forLine: row)
        guard let offset, let storage = textView.textStorage else { return }
        let range = textView.wrapsLines
            ? storage.mutableString.paragraphRange(for: NSRange(location: offset, length: 0))
            : NSRange(location: offset, length: 1)
        guard let target = NSTextRange(range, in: textView.nativeContentManager) else { return }
        textView.nativeLayoutManager.ensureLayout(for: target)
    }

    private func ghostStartY(forAnchor anchor: Int) -> CGFloat {
        let lines = decorations.ghostsByAnchor[anchor]?.lines.count ?? 0
        if anchor >= decorations.rows.count {
            return (textView.overrideContentHeight ?? textView.frame.height)
                - CGFloat(lines) * rowHeight
        }
        return documentY(forRow: anchor) - CGFloat(lines) * rowHeight
    }

    private func documentY(forRow rowIndex: Int) -> CGFloat {
        if usesNativeParagraphFixedLayout || usesSparseWrappedLayout {
            let offset = mode == .review
                ? (decorations.lineStartOffsets.indices.contains(rowIndex)
                    ? decorations.lineStartOffsets[rowIndex] : nil)
                : textView.liveGitOffset(forLine: rowIndex)
            if let offset {
                return CGFloat(fixedFragmentRow(atUTF16: offset)) * rowHeight
                    + textView.textContainerInset.height
            }
        }
        if textView.wrapsLines || textView.hasNativeNonLFSeparators {
            let offset = mode == .review
                ? (decorations.lineStartOffsets.indices.contains(rowIndex)
                    ? decorations.lineStartOffsets[rowIndex] : nil)
                : textView.liveGitOffset(forLine: rowIndex)
            if let offset {
                let content = textView.nativeContentManager
                if let target = NSTextRange(NSRange(location: offset, length: 1),
                                            in: content) {
                    let layout = textView.nativeLayoutManager
                    layout.ensureLayout(for: target)
                    if let fragment = layout.textLayoutFragment(for: target.location) {
                        scrollView.layoutSubtreeIfNeeded()
                        return fragment.layoutFragmentFrame.minY
                            + textView.textContainerInset.height
                    }
                }
            }
        }
        return CGFloat(displayRow(forSourceRow: rowIndex)) * rowHeight
    }

    func scrollToRow(_ rowIndex: Int) {
        if mode == .review, needsCompleteDocumentLayout {
            pendingReviewScroll = .row(rowIndex)
            return
        }
        guard rowIndex > 0, rowHeight > 0 else {
            setVerticalScrollOffset(0)
            return
        }
        if mode == .edit, rowIndex < (textView.liveGitSourceLineCount ?? 0) {
            if textView.nativeLayoutManager.delegate != nil,
               (max(1, textView.liveGitSourceLineCount ?? 0) == decorations.rows.count
                   || usesPlainSourceFixedLayout) {
                let y = documentY(forRow: rowIndex)
                if usesPlainSourceFixedLayout {
                    materializeSourceRow(rowIndex)
                } else {
                    materializeNativeViewport(at: y)
                }
                setVerticalScrollOffset(y)
            } else if let offset = textView.liveGitOffset(forLine: rowIndex) {
                textView.scrollRangeToVisible(NSRange(location: offset, length: 1))
            }
            return
        }
        setVerticalScrollOffset(documentY(forRow: rowIndex))
    }
}
