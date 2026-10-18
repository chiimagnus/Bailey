import AppKit

/// A single AppKit text editor backed by TextKit 2. Source and Diff both use it.
/// The text storage is owned by the view retained by its tab, not by SwiftUI.
@MainActor
class NativeCodeTextView: NSTextView {
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
    var text: String? {
        get { string }
        set {
            let content = newValue ?? ""
            string = content
            resetDocumentIndex(content)
        }
    }

    var attributedText: NSAttributedString {
        get { textStorage ?? NSAttributedString(string: string) }
        set {
            textStorage?.setAttributedString(newValue)
            resetDocumentIndex(newValue.string)
        }
    }

    var textSelection: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }

    var nativeContentManager: NSTextContentStorage { textContentStorage! }
    var nativeLayoutManager: NSTextLayoutManager { textLayoutManager! }

    /// AppKit's accessibility setter can replace a read-only NSTextView's
    /// contents when called directly; the source buffer must enforce the same
    /// write boundary for keyboard and accessibility input.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if !isEditable,
           selector == #selector(setAccessibilityValue(_:))
            || selector == #selector(setAccessibilitySelectedText(_:)) {
            return false
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard isEditable else { return }
        super.setAccessibilityValue(accessibilityValue)
    }

    override func setAccessibilitySelectedText(_ accessibilitySelectedText: String?) {
        guard isEditable else { return }
        super.setAccessibilitySelectedText(accessibilitySelectedText)
    }

    /// Offscreen file operations cannot rely on the NSTextView responder
    /// chain to record undo. Treat direct NSTextStorage edits as the same
    /// document transaction as interactive typing.
    func appendDocumentText(_ suffix: String) -> Bool {
        guard isEditable, let storage = textStorage else { return false }
        guard !suffix.isEmpty else { return true }
        // AppKit leaves the current keystroke's automatic event group open.
        // Close it before the independent programmatic document transaction.
        breakUndoCoalescing()
        while documentUndoManager.groupingLevel > 0 {
            documentUndoManager.endUndoGrouping()
        }
        documentUndoManager.beginUndoGrouping()
        replaceDocumentText(in: storage, at: storage.length, expecting: "", with: suffix)
        documentUndoManager.endUndoGrouping()
        return true
    }

    private func replaceDocumentText(in storage: NSTextStorage, at location: Int,
                                     expecting expected: String, with replacement: String) {
        let range = NSRange(location: location, length: expected.utf16.count)
        guard NSMaxRange(range) <= storage.length,
              storage.attributedSubstring(from: range).string == expected else { return }
        documentUndoManager.registerUndo(withTarget: storage) { [weak self] storage in
            self?.replaceDocumentText(in: storage, at: location,
                                      expecting: replacement, with: expected)
        }
        storage.replaceCharacters(in: range, with: replacement)
    }

    var syntaxCoordinator: SyntaxHighlightCoordinator?
    var overrideContentHeight: CGFloat? {
        didSet {
            if let height = overrideContentHeight, height > 0 {
                minSize.height = height
                setFrameSize(NSSize(width: frame.width, height: height))
            } else {
                minSize.height = 0
                needsLayout = true
            }
        }
    }

    func installSyntaxHighlighting(_ configuration: SyntaxHighlightConfiguration) {
        syntaxCoordinator?.deactivate()
        nativeLayoutManager.removeRenderingAttribute(.foregroundColor,
                                                    for: nativeContentManager.documentRange)
        syntaxCoordinator = SyntaxHighlightCoordinator(
            textView: self, theme: configuration.theme, language: configuration.language,
            highlightsData: configuration.highlightsData,
            injectionsData: configuration.injectionsData
        )
    }
    var showsLineNumbers = false {
        didSet { if showsLineNumbers != oldValue { configureRuler() } }
    }
    var selectedLineHighlightColor: NSColor = .clear
    var highlightSelectedLine = false
    private(set) var gutterView: NativeLineNumberRuler?
    private var lineIndex: NativeTextLineIndex?
    private var isWrappingLines = false
    var wrapsLines: Bool { isWrappingLines }

    /// Called for actual character mutations, including Undo/Redo, which do
    /// not necessarily emit NSTextViewDelegate.textDidChange.
    var onCharacterEdit: (() -> Void)?
    private var textEditObserver: (any NSObjectProtocol)?
    private struct CompositionSnapshot {
        let text: String
        let selection: NSRange
    }
    private var composingOriginal: CompositionSnapshot?
    private var committingComposition = false

    /// AppKit may omit the provisional IME edit from the native undo group
    /// when the final insert targets an explicit, unrelated range. Treat one
    /// marked-text session as one native UndoManager transaction, irrespective
    /// of the number of interim candidates.
    override func setMarkedText(_ string: Any, selectedRange: NSRange,
                                replacementRange: NSRange) {
        if !hasMarkedText(), composingOriginal == nil {
            composingOriginal = CompositionSnapshot(text: self.string, selection: self.selectedRange())
            documentUndoManager.disableUndoRegistration()
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if replacementRange.location == NSNotFound, composingOriginal == nil, !hasMarkedText(),
           let replacement = (string as? NSAttributedString)?.string ?? (string as? String),
           insertAcrossSelections(replacement) {
            return
        }
        let hasComposition = composingOriginal != nil
        committingComposition = hasComposition
        super.insertText(string, replacementRange: replacementRange)
        committingComposition = false
        if hasComposition { finishComposition() }
    }

    override func unmarkText() {
        super.unmarkText()
        if !committingComposition { finishComposition() }
    }

    /// Native NSTextView stores disjoint selections but its default insertText
    /// edits only the primary range. Apply the complete TextKit 2 selection as
    /// one storage transaction and one UndoManager group.
    private func insertAcrossSelections(_ replacement: String) -> Bool {
        guard isEditable, let storage = textStorage else { return false }
        let ranges = nativeLayoutManager.textSelections.flatMap(\.textRanges)
            .map { NSRange($0, in: nativeContentManager) }
        guard ranges.count > 1 else { return false }
        let sorted = ranges.sorted { $0.location < $1.location }
        guard sorted.allSatisfy({ $0.location != NSNotFound && $0.length >= 0
            && NSMaxRange($0) <= storage.length }),
              zip(sorted, sorted.dropFirst()).allSatisfy({ NSMaxRange($0.0) <= $0.1.location }) else {
            return true // Refuse an invalid multi-range; never apply a partial edit.
        }
        breakUndoCoalescing()
        while documentUndoManager.groupingLevel > 0 {
            documentUndoManager.endUndoGrouping()
        }
        documentUndoManager.beginUndoGrouping()
        storage.beginEditing()
        for range in sorted.reversed() {
            let old = storage.attributedSubstring(from: range).string
            replaceDocumentText(in: storage, at: range.location, expecting: old,
                                with: replacement)
        }
        storage.endEditing()
        documentUndoManager.endUndoGrouping()

        var shift = 0
        let carets: [NSTextSelection] = sorted.compactMap { range in
            let offset = range.location + shift + replacement.utf16.count
            shift += replacement.utf16.count - range.length
            guard let location = nativeContentManager.location(
                nativeContentManager.documentRange.location, offsetBy: offset
            ) else { return nil }
            return NSTextSelection(location, affinity: .downstream)
        }
        if carets.count == sorted.count { nativeLayoutManager.textSelections = carets }
        return true
    }

    private func finishComposition() {
        guard let initial = composingOriginal, !hasMarkedText() else { return }
        composingOriginal = nil
        documentUndoManager.enableUndoRegistration()
        let completed = CompositionSnapshot(text: string, selection: selectedRange())
        guard !initial.text.utf16.elementsEqual(completed.text.utf16),
              let storage = textStorage else { return }
        documentUndoManager.beginUndoGrouping()
        documentUndoManager.registerUndo(withTarget: storage) { [weak self] storage in
            self?.restoreComposition(in: storage, from: completed, to: initial)
        }
        documentUndoManager.endUndoGrouping()
    }

    private func restoreComposition(in storage: NSTextStorage, from previous: CompositionSnapshot,
                                    to replacement: CompositionSnapshot) {
        guard previous.text.utf16.elementsEqual(storage.string.utf16) else { return }
        documentUndoManager.registerUndo(withTarget: storage) { [weak self] storage in
            self?.restoreComposition(in: storage, from: replacement, to: previous)
        }
        Self.replaceChangedText(in: storage, with: replacement.text)
        setSelectedRange(NSRange(
            location: min(replacement.selection.location, storage.length),
            length: min(replacement.selection.length,
                        max(0, storage.length - replacement.selection.location))
        ))
    }

    /// Restore only changed UTF-16 characters. A final IME insertion can
    /// explicitly replace a range unrelated to its marked-text region.
    private static func replaceChangedText(in storage: NSTextStorage, with desired: String) {
        let old = storage.string as NSString
        let next = desired as NSString
        let oldLength = old.length
        let nextLength = next.length
        var start = 0
        while start < min(oldLength, nextLength),
              old.character(at: start) == next.character(at: start) {
            start += 1
        }
        var end = 0
        while end < min(oldLength, nextLength) - start,
              old.character(at: oldLength - end - 1) == next.character(at: nextLength - end - 1) {
            end += 1
        }
        guard start < oldLength - end || start < nextLength - end else { return }
        // Avoid cutting the interior of a UTF-16 surrogate pair.
        if start > 0, start < oldLength,
           (0xD800...0xDBFF).contains(old.character(at: start - 1)) { start -= 1 }
        let remove = NSRange(location: start, length: oldLength - start - end)
        let insert = next.substring(with: NSRange(location: start, length: nextLength - start - end))
        storage.replaceCharacters(in: remove, with: insert)
    }

    init(contentStorage storage: NSTextContentStorage = NSTextContentStorage()) {
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
        storage.addTextLayoutManager(layout)
        layout.textContainer = container
        super.init(frame: CGRect(x: 0, y: 0, width: 1000, height: 0), textContainer: container)
        isRichText = false
        allowsUndo = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainerInset = .zero
        minSize = NSSize(width: 1000, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        resetDocumentIndex("")
        if let textStorage {
            textEditObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: textStorage, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let storage = self.textStorage else { return }
                    self.processStorageEdit(storage)
                }
            }
        }
    }

    isolated deinit {
        if let textEditObserver { NotificationCenter.default.removeObserver(textEditObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Native TextKit 2 can keep its paragraph cache bounded when the actual
    /// document view and its text container have the same *finite* width.
    func setCodeWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        let visibleHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let minimumHeight = overrideContentHeight ?? visibleHeight
        if abs(minSize.width - width) > 0.5 || abs(minSize.height - minimumHeight) > 0.5 {
            minSize = NSSize(width: width, height: minimumHeight)
        }
        if abs(frame.width - width) > 0.5 || frame.height < minimumHeight {
            setFrameSize(NSSize(width: width, height: max(frame.height, minimumHeight)))
        }
        if let container = textContainer, abs(container.size.width - width) > 0.5 {
            container.size.width = width
        }
    }

    override func characterIndex(for point: NSPoint) -> Int {
        guard window != nil else { return NSNotFound }
        return super.characterIndex(for: point)
    }

    override func firstRect(forCharacterRange range: NSRange,
                            actualRange: NSRangePointer?) -> NSRect {
        guard window != nil else { return .zero }
        return super.firstRect(forCharacterRange: range, actualRange: actualRange)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightSelectedLine, let viewport = textLayoutManager?.textViewportLayoutController.viewportRange,
              let manager = textContentStorage, let layout = textLayoutManager else { return }
        let offset = selectedRange().location
        let start = manager.offset(from: manager.documentRange.location, to: viewport.location)
        let end = manager.offset(from: manager.documentRange.location, to: viewport.endLocation)
        guard offset >= start, offset <= end,
              let location = manager.location(manager.documentRange.location, offsetBy: offset),
              let fragment = layout.textLayoutFragment(for: location) else { return }
        let local = manager.offset(from: fragment.rangeInElement.location, to: location)
        guard let line = fragment.textLineFragments.first(where: {
            local >= $0.characterRange.location && local <= NSMaxRange($0.characterRange)
        }) else { return }
        let bounds = line.typographicBounds
        let row = NSRect(x: rect.minX, y: fragment.layoutFragmentFrame.minY + bounds.minY,
                         width: rect.width, height: bounds.height)
        guard row.intersects(rect) else { return }
        selectedLineHighlightColor.setFill()
        row.intersection(rect).fill()
    }

    override func layout() {
        super.layout()
        // A short native text document must still cover the scroll viewport,
        // including the area below its final line, so clicks focus the editor.
        guard overrideContentHeight == nil,
              let height = enclosingScrollView?.contentView.bounds.height,
              frame.height < height else { return }
        setFrameSize(NSSize(width: frame.width, height: height))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureRuler()
    }

    private func configureRuler() {
        guard let scroll = enclosingScrollView else { return }
        if showsLineNumbers {
            let ruler = gutterView ?? NativeLineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
            ruler.editor = self
            ruler.clientView = self
            ruler.ruleThickness = 48
            ruler.reservedThicknessForMarkers = 0
            scroll.verticalRulerView = ruler
            scroll.hasVerticalRuler = true
            scroll.rulersVisible = true
            gutterView = ruler
        } else {
            scroll.hasVerticalRuler = false
            scroll.rulersVisible = false
            gutterView = nil
        }
    }

    private func resetDocumentIndex(_ document: String) {
        lineIndex = NativeTextLineIndex(document as NSString)
        gutterView?.needsDisplay = true
    }

    func lineNumber(atUTF16Offset offset: Int) -> Int {
        (lineIndex?.row(at: min(max(offset, 0), lineIndex?.length ?? 0)) ?? 0) + 1
    }

    func approximateCharacterOffset(atDocumentY y: CGFloat) -> Int? {
        guard let lineIndex, let font else { return nil }
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let line = min(lineIndex.lineCount - 1, max(0, Int(y / lineHeight)))
        return lineIndex.offset(atLine: line)
    }

    func configureWrapping(_ wraps: Bool, viewportWidth: CGFloat) {
        isWrappingLines = wraps
        guard viewportWidth > 0 else { return }
        let characterWidth = max(1, font?.maximumAdvancement.width ?? 8)
        // Grow the actual document *and* container, rather than handing TextKit 2
        // a container wider than its owning view (which materializes all rows).
        let codeWidth = wraps ? viewportWidth :
            max(viewportWidth, ceil(CGFloat(lineIndex?.maximumLineUnits ?? 0) * characterWidth * 2 + 24))
        setCodeWidth(codeWidth)
    }

    private func processStorageEdit(_ storage: NSTextStorage) {
        guard storage.editedMask.contains(.editedCharacters) else { return }
        let edited = storage.editedRange
        let priorLength = edited.length - storage.changeInLength
        guard edited.location != NSNotFound, edited.location >= 0,
              priorLength >= 0, NSMaxRange(edited) <= storage.length else {
            resetDocumentIndex(storage.string)
            return
        }
        let previousRange = NSRange(location: edited.location, length: priorLength)
        let replacement = storage.attributedSubstring(from: edited).string
        syntaxCoordinator?.willChangeContent(in: previousRange)
        if lineIndex?.length == storage.length - storage.changeInLength {
            lineIndex?.replace(in: previousRange, replacementLength: replacement.utf16.count,
                               text: storage.string as NSString)
        } else {
            resetDocumentIndex(storage.string)
        }
        syntaxCoordinator?.didChangeContent(nativeContentManager, in: previousRange,
                                           replacementString: replacement)
        gutterView?.needsDisplay = true
        if !isWrappingLines, let width = enclosingScrollView?.contentView.bounds.width {
            configureWrapping(false, viewportWidth: width)
        }
        storageCharactersDidChange()
        onCharacterEdit?()
    }

    /// Subclasses can invalidate presentation caches on every storage change,
    /// including Undo/Redo which bypass NSTextView.didChangeText.
    func storageCharactersDidChange() {}
}

/// UTF-16 range conversion onto the actual TextKit 2 document.
extension NSTextRange {
    convenience init?(_ range: NSRange, in manager: NSTextContentManager) {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              let start = manager.location(manager.documentRange.location, offsetBy: range.location),
              let end = manager.location(start, offsetBy: range.length) else { return nil }
        self.init(location: start, end: end)
    }
}

extension NSRange {
    init(_ range: NSTextRange, in manager: NSTextContentManager) {
        let start = manager.offset(from: manager.documentRange.location, to: range.location)
        let end = manager.offset(from: manager.documentRange.location, to: range.endLocation)
        self.init(location: start, length: end - start)
    }
}

extension NSTextLayoutManager {
    func enumerateTextLayoutFragments(in range: NSTextRange,
                                      using block: (NSTextLayoutFragment) -> Bool) {
        enumerateTextLayoutFragments(from: range.location) { fragment in
            if fragment.rangeInElement.location.compare(range.endLocation) != .orderedAscending {
                return false
            }
            return block(fragment)
        }
    }
}

extension NSTextContentManager {
    var length: Int { offset(from: documentRange.location, to: documentRange.endLocation) }

    func attributedString(in range: NSTextRange?) -> NSAttributedString? {
        guard let storage = (self as? NSTextContentStorage)?.textStorage else { return nil }
        guard let range else { return storage }
        if range.isEmpty { return nil }
        return storage.attributedSubstring(from: NSRange(range, in: self))
    }
}


@MainActor
final class NativeLineNumberRuler: NSRulerView {
    weak var editor: NativeCodeTextView?
    var textColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var selectedLineTextColor: NSColor = .labelColor { didSet { needsDisplay = true } }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let content = editor.textContentStorage,
              let layout = editor.textLayoutManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: max(9, (editor.font?.pointSize ?? 13) - 1.5), weight: .regular
        )
        let selectedRow = editor.lineNumber(atUTF16Offset: editor.selectedRange().location)
        layout.enumerateTextLayoutFragments(in: viewport) { fragment in
            let offset = content.offset(from: content.documentRange.location,
                                        to: fragment.rangeInElement.location)
            let number = editor.lineNumber(atUTF16Offset: offset)
            guard let first = fragment.textLineFragments.first else { return true }
            let point = editor.convert(NSPoint(x: 0,
                y: fragment.layoutFragmentFrame.minY + first.typographicBounds.midY), to: self)
            let label = NSAttributedString(string: String(number), attributes: [
                .font: font,
                .foregroundColor: number == selectedRow ? selectedLineTextColor : textColor
            ])
            let y = point.y - label.size().height / 2
            if y + label.size().height >= rect.minY, y <= rect.maxY {
                label.draw(at: NSPoint(x: bounds.maxX - label.size().width - 10, y: y))
            }
            return true
        }
    }
}
