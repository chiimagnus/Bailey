import AppKit
import Observation
import SwiftUI

nonisolated struct TextFindOptions: Hashable, Sendable {
    var matchCase = false
    var wholeWord = false
    var regex = false

    func expression(for query: String) throws -> NSRegularExpression {
        let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        let bounded = wholeWord ? "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])" : pattern
        return try NSRegularExpression(pattern: bounded, options: matchCase ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive])
    }

    /// Preserve case for the whole word, initial letter, or matching
    /// hyphen/underscore-separated segments, as in the VS Code replace widget.
    static func preserveCase(of match: String, in replacement: String) -> String {
        guard let first = match.first, let initial = replacement.first else { return replacement }
        let separators: [Character] = ["-", "_"].filter { separator in
            match.contains(separator) && replacement.contains(separator)
                && match.split(separator: separator, omittingEmptySubsequences: false).count
                == replacement.split(separator: separator, omittingEmptySubsequences: false).count
        }
        if separators.count == 1, let separator = separators.first {
            let lhs = match.split(separator: separator, omittingEmptySubsequences: false)
            let rhs = replacement.split(separator: separator, omittingEmptySubsequences: false)
            return zip(lhs, rhs).map { preserveCase(of: String($0), in: String($1)) }
                .joined(separator: String(separator))
        }
        if match == match.uppercased() { return replacement.uppercased() }
        if match == match.lowercased() { return replacement.lowercased() }
        if first.isUppercase { return initial.uppercased() + replacement.dropFirst() }
        if first.isLowercase { return initial.lowercased() + replacement.dropFirst() }
        return replacement
    }
}

// The match stream is ordered and nonoverlapping, including zero-width
// matches. Encode gaps and lengths rather than allocating one NSRange per
// hit. Checkpoints bound random access without rescanning the document.
nonisolated struct TextFindMatchIndex: Sendable {
    private struct Page: Sendable {
        let firstLocation: Int
        let previousEnd: Int
        let offset: Int
    }

    private static let pageSize = 256
    private var pages: [Page] = []
    private var bytes: [UInt8] = []
    private var previousEnd = 0
    private(set) var count = 0

    var storageBytes: Int {
        bytes.count + pages.count * MemoryLayout<Page>.stride
    }

    mutating func append(_ range: NSRange) {
        precondition(range.location >= previousEnd)
        if count.isMultiple(of: Self.pageSize) {
            pages.append(Page(firstLocation: range.location, previousEnd: previousEnd, offset: bytes.count))
        }
        encode(range.location - previousEnd)
        encode(range.length)
        previousEnd = NSMaxRange(range)
        count += 1
    }

    private mutating func encode(_ value: Int) {
        var value = value
        while value >= 128 {
            bytes.append(UInt8(value & 127) | 128)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    struct Iterator: IteratorProtocol, Sequence {
        fileprivate let bytes: [UInt8]
        fileprivate var offset: Int
        fileprivate var previousEnd: Int
        fileprivate var remaining: Int
        fileprivate var before = Int.max

        var isEmpty: Bool {
            var copy = self
            return copy.next() == nil
        }

        mutating func next() -> NSRange? {
            guard remaining > 0 else { return nil }
            let start = previousEnd + decode()
            let length = decode()
            previousEnd = start + length
            remaining -= 1
            guard start < before else { remaining = 0; return nil }
            return NSRange(location: start, length: length)
        }

        private mutating func decode() -> Int {
            var value = 0, shift = 0
            while true {
                let byte = bytes[offset]
                offset += 1
                value |= Int(byte & 127) << shift
                if byte < 128 { return value }
                shift += 7
            }
        }
    }

    private func iterator(from index: Int) -> Iterator {
        guard index < count else { return Iterator(bytes: [], offset: 0, previousEnd: 0, remaining: 0) }
        let page = pages[index / Self.pageSize]
        var cursor = Iterator(bytes: bytes, offset: page.offset, previousEnd: page.previousEnd,
                              remaining: count - index / Self.pageSize * Self.pageSize)
        for _ in 0..<(index % Self.pageSize) { _ = cursor.next() }
        return cursor
    }

    func range(at index: Int) -> NSRange? {
        guard (0..<count).contains(index) else { return nil }
        var cursor = iterator(from: index)
        return cursor.next()
    }

    func lowerBound(_ location: Int) -> Int {
        guard !pages.isEmpty else { return 0 }
        var low = 0, high = pages.count
        while low < high {
            let middle = low + (high - low) / 2
            if pages[middle].firstLocation < location { low = middle + 1 }
            else { high = middle }
        }
        var index = max(0, low - 1) * Self.pageSize
        var cursor = iterator(from: index)
        while let range = cursor.next() {
            if range.location >= location { return index }
            index += 1
        }
        return count
    }

    func intersecting(_ range: NSRange) -> Iterator {
        var first = lowerBound(range.location)
        // A match beginning before the viewport may continue into it.
        if first > 0, let previous = self.range(at: first - 1),
           NSMaxRange(previous) > range.location { first -= 1 }
        var cursor = iterator(from: first)
        cursor.before = NSMaxRange(range)
        return cursor
    }
}

/// Search is derived from the actual mounted TextKit document, never a second
/// writable buffer.
@MainActor
@Observable
final class TextFind {
    private(set) var isPresented = false
    var showsReplace = false
    var query = "" { didSet { if query != oldValue { refresh(reveal: true) } } }
    var options = TextFindOptions() { didSet { if options != oldValue { refresh(reveal: true) } } }
    var replacement = ""
    var preserveCase = false
    private(set) var scope: NSRange?
    private(set) var selectionCandidate: NSRange?
    @ObservationIgnored private var selectionObserver: NSObjectProtocol?
    @ObservationIgnored private var selectingMatch = false
    private(set) var focusRequest = 0
    private(set) var total: Int?
    private(set) var current: Int?
    private(set) var invalidPattern = false
    @ObservationIgnored private(set) weak var target: NativeCodeTextView?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt = 0
    @ObservationIgnored private var ranges = TextFindMatchIndex()
    @ObservationIgnored private var lastRevealedRange: NSRange?

    var countLabel: String {
        guard !query.isEmpty else { return "" }
        if invalidPattern { return String(localized: "Invalid regular expression", table: "Editor") }
        guard let total else { return "" }
        return total == 0 ? String(localized: "No matches", table: "Interface")
            : String(localized: "\(current.map { String($0 + 1) } ?? "?") of \(total)", table: "Editor")
    }

    func attach(to view: NativeCodeTextView) {
        guard target !== view else { return }
        if scope != nil { dismiss() }
        removeSelectionObserver()
        target?.findOwner = nil
        target?.needsDisplay = true
        scope = nil
        selectionCandidate = nil
        target = view
        lastRevealedRange = nil
        view.findOwner = self
        if isPresented {
            observeSelection(of: view)
            refresh(reveal: false)
        }
    }

    private func observeSelection(of view: NativeCodeTextView) {
        removeSelectionObserver()
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: view, queue: .main
        ) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let self, let view, self.target === view, self.isPresented, !self.selectingMatch else { return }
                self.captureSelection()
            }
        }
        captureSelection()
    }

    func detach(from view: NativeCodeTextView? = nil) {
        if let view, target !== view { return }
        if scope != nil { dismiss() }
        removeSelectionObserver()
        target?.findOwner = nil
        target?.needsDisplay = true
        scope = nil
        selectionCandidate = nil
        target = nil
        lastRevealedRange = nil
        invalidate()
    }

    func present(replacing: Bool = false) {
        guard let target, target.window != nil else { return }
        if replacing {
            guard target.isEditable else { return }
            showsReplace = true
        }
        let wasPresented = isPresented
        isPresented = true
        focusRequest &+= 1
        if !wasPresented { observeSelection(of: target) }
        if (!wasPresented || !replacing && target.window?.firstResponder === target),
           !target.hasMarkedText() {
            let selection = target.selectedRange()
            if selection != lastRevealedRange, selection.location != NSNotFound,
               selection.length > 0, selection.length < 524_288,
               let storage = target.textStorage, NSMaxRange(selection) <= storage.length {
                captureSelection()
                let value = storage.attributedSubstring(from: selection).string
                if !value.contains(where: \.isNewline) {
                    let seed = options.regex ? NSRegularExpression.escapedPattern(for: value) : value
                    if seed != query { query = seed; return }
                }
            }
        }
        if !wasPresented { refresh(reveal: true) }
    }

    func dismiss() {
        isPresented = false
        removeSelectionObserver()
        scope = nil
        selectionCandidate = nil
        invalidate()
    }

    isolated deinit {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        task?.cancel()
    }

    private func removeSelectionObserver() {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
    }

    private func captureSelection() {
        guard let target else { selectionCandidate = nil; return }
        let selection = target.selectedRange()
        // The automatic result selection must not overwrite the user's range.
        if selection == lastRevealedRange { return }
        lastRevealedRange = nil
        selectionCandidate = selection.location != NSNotFound && selection.length > 0 ? selection : nil
    }

    func toggleSelectionScope() {
        if scope != nil { scope = nil }
        else {
            guard let selectionCandidate else { return }
            scope = selectionCandidate
        }
        refresh(reveal: true)
    }

    func documentChanged(in view: NativeCodeTextView, previousRange: NSRange? = nil, insertedLength: Int = 0) {
        guard target === view, isPresented else { return }
        lastRevealedRange = nil
        // Scope remains attached to the original text when typing or replacing
        // inside it. Edits crossing a scope boundary invalidate that range.
        func remap(_ range: NSRange?) -> NSRange? {
            guard let range, let edit = previousRange else { return nil }
            let delta = insertedLength - edit.length
            if NSMaxRange(edit) <= range.location && edit.location < range.location {
                return NSRange(location: range.location + delta, length: range.length)
            }
            if edit.location >= NSMaxRange(range) { return range }
            guard edit.location >= range.location, NSMaxRange(edit) <= NSMaxRange(range) else { return nil }
            let length = range.length + delta
            return length > 0 ? NSRange(location: range.location, length: length) : nil
        }
        let mappedScope = remap(scope)
        // Never silently turn a scoped Replace All into a document-wide edit.
        if scope != nil, mappedScope == nil {
            dismiss()
            return
        }
        scope = mappedScope
        selectionCandidate = remap(selectionCandidate)
        refresh(reveal: false)
    }

    private func invalidate() {
        generation &+= 1
        task?.cancel()
        task = nil
        total = nil
        current = nil
        invalidPattern = false
        ranges = TextFindMatchIndex()
        target?.needsDisplay = true
    }

    private func refresh(reveal: Bool) {
        invalidate()
        guard isPresented, !query.isEmpty, let target else { return }
        let request = generation
        let text = target.string, query = query, options = options, scope = scope
        let selection = target.selectedRange()
        task = Task { [weak self, weak target] in
            let result = await Self.matches(in: text, query: query, options: options,
                                            scope: scope)
            guard let self, let target, self.target === target,
                  isPresented, request == generation, !Task.isCancelled else { return }
            task = nil
            guard let result else { invalidPattern = true; total = 0; return }
            ranges = result
            total = result.count
            let position = result.lowerBound(selection.location)
            let index = position == result.count ? 0 : position
            if let range = result.range(at: index) {
                select(range, index: index, reveal: reveal && target.selectedRange() == selection)
            }
            target.needsDisplay = true
        }
    }

    func navigate(forward: Bool) {
        guard isPresented, let target, let total, total > 0 else { return }
        let selection = target.selectedRange()
        let position = ranges.lowerBound(selection.location)
        let next: Int
        if forward {
            let offset = ranges.range(at: position) == selection ? position + 1 : position
            next = offset == total ? 0 : offset
        } else {
            next = position == 0 ? total - 1 : position - 1
        }
        if let range = ranges.range(at: next) {
            select(range, index: next, reveal: true)
        }
    }

    private func select(_ range: NSRange, index: Int, reveal: Bool) {
        current = index
        guard reveal, let target else { return }
        lastRevealedRange = range
        selectingMatch = true
        target.textSelection = range
        selectingMatch = false
        target.scrollRangeToVisible(range)
        target.showFindIndicator(for: range)
        target.needsDisplay = true
    }

    func visibleMatches(in range: NSRange) -> TextFindMatchIndex.Iterator {
        ranges.intersecting(range)
    }

    func restoreFocus(canFocus: @escaping () -> Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !isPresented, canFocus(), NSApp.isActive,
                  let target, let window = target.window, window.isKeyWindow,
                  !target.isHiddenOrHasHiddenAncestor else { return }
            window.makeFirstResponder(target)
        }
    }

    func replace(all: Bool) {
        guard isPresented, showsReplace, let target, target.window != nil, target.isEditable,
              let total, total > 0, !target.hasMarkedText() else { return }
        let text = target.string, query = query, options = options, replacement = replacement
        let scope = scope, preserveCase = preserveCase
        let range = all ? nil : current.flatMap { ranges.range(at: $0) }
        if !all, target.selectedRange() != range {
            navigate(forward: true)
            return
        }
        guard all || range != nil else { return }
        task?.cancel()
        generation &+= 1
        let request = generation
        task = Task { [weak self, weak target] in
            let edit = await Self.replacement(in: text, query: query, options: options,
                                              replacement: replacement, range: range, scope: scope,
                                              preserveCase: preserveCase)
            guard let self, let target, self.target === target, isPresented, showsReplace,
                  generation == request, !Task.isCancelled, target.window != nil, target.isEditable,
                  self.replacement == replacement, self.preserveCase == preserveCase, !target.hasMarkedText(),
                  all || target.selectedRange() == range, let edit else { return }
            task = nil
            target.breakUndoCoalescing()
            let undo = target.undoManager
            while let undo, undo.groupingLevel > 0 { undo.endUndoGrouping() }
            undo?.beginUndoGrouping()
            target.insertText(edit.text, replacementRange: edit.range)
            target.breakUndoCoalescing()
            undo?.endUndoGrouping()
            if !all { refresh(reveal: true) }
        }
    }

    @concurrent private static func matches(in text: String, query: String, options: TextFindOptions,
                                            scope: NSRange?) async -> TextFindMatchIndex? {
        guard let expression = try? options.expression(for: query) else { return nil }
        let source = text as NSString
        var cached = TextFindMatchIndex()
        let searchRange = scope ?? NSRange(location: 0, length: source.length)
        guard NSMaxRange(searchRange) <= source.length else { return nil }
        var failed = false
        expression.enumerateMatches(in: text, options: [.reportProgress, .reportCompletion, .withTransparentBounds, .withoutAnchoringBounds],
                                    range: searchRange) { match, flags, stop in
            if flags.contains(.internalError) { failed = true; stop.pointee = true; return }
            if Task.isCancelled { stop.pointee = true; return }
            guard let range = match?.range else { return }
            cached.append(range)
        }
        guard !failed, !Task.isCancelled else { return nil }
        return cached
    }

    private nonisolated struct Edit: Sendable { let range: NSRange; let text: String }

    @concurrent private static func replacement(in text: String, query: String, options: TextFindOptions,
                                                replacement: String, range: NSRange?, scope: NSRange?,
                                                preserveCase: Bool) async -> Edit? {
        guard let expression = try? options.expression(for: query) else { return nil }
        let source = text as NSString
        let full = scope ?? NSRange(location: 0, length: source.length)
        guard NSMaxRange(full) <= source.length else { return nil }
        var result = ""
        var offset = 0
        var firstLocation: Int?
        var units = 0
        var edit: Edit?
        var failed = false
        expression.enumerateMatches(in: text, options: [.reportProgress, .reportCompletion, .withTransparentBounds, .withoutAnchoringBounds], range: full) { match, flags, stop in
            if flags.contains(.internalError) { failed = true; stop.pointee = true; return }
            if Task.isCancelled { stop.pointee = true; return }
            guard let match else { return }
            if let range, range != match.range { return }
            let raw = options.regex
                ? expression.replacementString(for: match, in: text, offset: 0, template: replacement)
                : replacement
            let value = preserveCase ? TextFindOptions.preserveCase(of: source.substring(with: match.range), in: raw) : raw
            if let range {
                edit = Edit(range: range, text: value)
                stop.pointee = true
                return
            }
            if firstLocation == nil { firstLocation = match.range.location; offset = match.range.location }
            let gap = match.range.location - offset
            units += gap + value.utf16.count
            guard units <= FileTab.maxTextBytes else { units = Int.max; stop.pointee = true; return }
            result.append(source.substring(with: NSRange(location: offset, length: gap)))
            result.append(value)
            offset = NSMaxRange(match.range)
        }
        guard !failed, !Task.isCancelled else { return nil }
        if range != nil { return edit }
        guard let firstLocation, units <= FileTab.maxTextBytes - firstLocation - (source.length - offset) else { return nil }
        return Edit(range: NSRange(location: firstLocation, length: offset - firstLocation), text: result)
    }
}

struct TextFindWidget: View {
    @Bindable var find: TextFind
    let canReplace: Bool
    let canFocus: () -> Bool
    let onFocused: () -> Void
    let toggleReplace: () -> Void

    var body: some View {
        if find.isPresented {
            FindWidget(query: $find.query, count: find.countLabel, hasMatches: (find.total ?? 0) > 0,
                       noResults: find.total == 0 && !find.query.isEmpty, invalidPattern: find.invalidPattern,
                       canReplace: canReplace, showsReplace: find.showsReplace, toggleReplace: toggleReplace,
                       selectionActive: find.scope != nil, canSelectScope: find.selectionCandidate != nil,
                       toggleSelection: find.toggleSelectionScope, focusRequest: find.focusRequest,
                       canFocus: { find.isPresented && canFocus() && find.target?.window?.isKeyWindow == true }, onFocused: onFocused,
                       navigate: find.navigate, dismiss: find.dismiss,
                       restoreFocus: { find.restoreFocus(canFocus: canFocus) },
                       options: {
                FindIconButton(icon: .text("Aa"), title: String(localized: "Match Case", table: "Editor"),
                               selected: find.options.matchCase) { find.options.matchCase.toggle() }
                    .accessibilityIdentifier("bailey.find.case")
                FindIconButton(icon: .text("ab", underlined: true), title: String(localized: "Match Whole Word", table: "Editor"),
                               selected: find.options.wholeWord) { find.options.wholeWord.toggle() }
                    .accessibilityIdentifier("bailey.find.word")
                FindIconButton(icon: .text(".*"), title: String(localized: "Use Regular Expression", table: "Editor"),
                               selected: find.options.regex) { find.options.regex.toggle() }
                    .accessibilityIdentifier("bailey.find.regex")
            }, replacement: { fieldWidth, showsActions in
                FindReplacementRow(replacement: $find.replacement, preserveCase: $find.preserveCase, canReplace: (find.total ?? 0) > 0,
                                   canReplaceAll: (find.total ?? 0) > 0,
                                   replace: { find.replace(all: false) }, replaceAll: { find.replace(all: true) },
                                   dismiss: find.dismiss, fieldWidth: fieldWidth, showsActions: showsActions)
            })
        }
    }
}

extension FileTab {
    var textView: NativeCodeTextView? {
        (editorView as? NSScrollView)?.documentView as? NativeCodeTextView
    }
}
