import AppKit
import SwiftUI

struct MarkdownPreview: View {
    let document: MarkdownDocument
    let revision: String
    let resource: MarkdownResource
    let assetRefresh: UInt
    var restoredBlock: Int? = nil
    var sourceBlock: Int? = nil
    var restoredSourceOffset: Int? = nil
    var synchronizedSourceOffset: Int? = nil
    var restoredViewportY: CGFloat = 0
    var onReadingPosition: (Int) -> Void = { _ in }
    var onReaderScroll: (Int) -> Void = { _ in }
    var onReadingSourceAnchor: (Int, CGFloat) -> Void = { _, _ in }
    var onReaderSourceScroll: (Int) -> Void = { _ in }
    var onLocateSource: ((Int) -> Void)? = nil
    var openLink: (URL) async -> Bool = { _ in false }
    var navigation: Binding<String?> = .constant(nil)

    @State private var position: Int?
    @State private var linkToOpen: URL?
    @State private var failedLink = false
    @State private var readerIsScrolling = false
    @State private var sourceCoordinates = MarkdownReaderCoordinates()
    @State private var detailsState = MarkdownDetailsState()
    @State private var selectedSource: NSRange?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let rows = renderRows
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if let warning = document.warning {
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(rows, id: \.start) { row in
                                if row.end - row.start > 1 {
                                    paragraphRun(row.start..<row.end)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                        .modifier(MarkdownGlyphMapping(group: row.start))
                                        .id(row.start)
                                } else {
                                    MarkdownNativeBlockView(block: document.blocks[row.start].content,
                                                            resource: resource, assetRefresh: assetRefresh,
                                                            anchor: document.blocks[row.start].anchor,
                                                            selectionPath: [row.start])
                                        .modifier(MarkdownGlyphMapping(group: row.start))
                                        .id(row.start)
                                }
                            }
                        }
                        .scrollTargetLayout()
                        .background {
                            MarkdownReaderClipBridge(
                                coordinates: sourceCoordinates, document: document,
                                detailsState: detailsState,
                                onSelectionChanged: { selectedSource = $0 },
                                onLocateSource: onLocateSource
                            )
                            .frame(width: 0, height: 0)
                        }
                        .font(.system(size: 16))
                        .lineSpacing(4)
                        .foregroundStyle(MarkdownGitHubColors.text(dark: colorScheme == .dark))
                        .tint(MarkdownGitHubColors.link(dark: colorScheme == .dark))
                        .frame(maxWidth: 890, alignment: .leading)
                        .padding(geometry.size.width < 768 ? 15 : 45)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .modifier(MarkdownLinkCursor())
                    }
                    .accessibilityIdentifier("bailey.markdown.preview")
                    .coordinateSpace(name: "bailey.markdown.reader")
                    .environment(detailsState)
                    .overlay {
                        Canvas { context, _ in
                            guard let selectedSource else { return }
                            let tint = Color(nsColor: .selectedTextBackgroundColor).opacity(0.42)
                            for hit in sourceCoordinates.hits {
                                for rect in hit.selectedGlyphRects(intersecting: selectedSource) {
                                    context.fill(Path(rect), with: .color(tint))
                                }
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.1) { visible in
                        position = visible.min()
                    }
                    .onPreferenceChange(MarkdownGlyphHitPreference.self) { hits in
                        sourceCoordinates.hits = hits
                        if !readerIsScrolling { sourceCoordinates.scrollPending() }
                    }
                    .onScrollPhaseChange { _, phase in
                        let isUserScroll = phase == .interacting || phase == .decelerating
                        if readerIsScrolling && !isUserScroll {
                            reportReaderScroll(position)
                        }
                        if isUserScroll && !readerIsScrolling {
                            sourceCoordinates.pendingSource = nil
                            sourceCoordinates.lastReportedOffset = nil
                        }
                        readerIsScrolling = isUserScroll
                    }
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, _ in
                        if readerIsScrolling { reportReaderScroll(position) }
                    }
                    .onChange(of: position) { _, position in
                        if readerIsScrolling { reportReaderScroll(position) }
                    }
                    .onChange(of: revision, initial: true) { _, _ in
                        guard !readerIsScrolling, let block = restoredBlock ?? sourceBlock else { return }
                        scroll(to: block, sourceOffset: restoredSourceOffset ?? synchronizedSourceOffset,
                               viewportY: restoredViewportY, rows: rows, proxy: proxy)
                    }
                    .onChange(of: synchronizedSourceOffset) { _, offset in
                        guard !readerIsScrolling, let offset, let block = sourceBlock else { return }
                        scroll(to: block, sourceOffset: offset, rows: rows, proxy: proxy)
                    }
                    .onChange(of: sourceBlock) { _, block in
                        guard !readerIsScrolling, synchronizedSourceOffset == nil,
                              let block else { return }
                        scroll(to: block, rows: rows, proxy: proxy)
                    }
                    .task(id: navigation.wrappedValue) {
                        guard let fragment = navigation.wrappedValue else { return }
                        if let index = document.blocks.firstIndex(where: { $0.anchor == fragment }) {
                            scroll(to: index, rows: rows, proxy: proxy)
                            failedLink = false
                        } else {
                            failedLink = true
                        }
                        navigation.wrappedValue = nil
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        if url.absoluteString.hasPrefix("#") {
                            let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
                            if let fragment, let index = document.blocks.firstIndex(where: { $0.anchor == fragment }) {
                                scroll(to: index, rows: rows, proxy: proxy)
                                failedLink = false
                            } else {
                                failedLink = true
                            }
                        } else {
                            linkToOpen = url
                        }
                        return .handled
                    })
                }
                if failedLink {
                    Label("Could not open this link.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(MarkdownGitHubColors.background(dark: colorScheme == .dark))
        .onChange(of: revision) { _, _ in
            sourceCoordinates.clearSelection()
            detailsState.expanded.removeAll()
            selectedSource = nil
            linkToOpen = nil
            failedLink = false
        }
        .task(id: linkToOpen) {
            guard let url = linkToOpen else { return }
            let opened = await openLink(url)
            guard !Task.isCancelled else { return }
            failedLink = !opened
            linkToOpen = nil
        }
    }

    private func reportReaderScroll(_ block: Int?) {
        if let visible = sourceCoordinates.firstVisibleSource() {
            onReadingSourceAnchor(visible.offset, visible.viewportY)
            if sourceCoordinates.lastReportedOffset != visible.offset {
                sourceCoordinates.lastReportedOffset = visible.offset
                onReaderSourceScroll(visible.offset)
            }
        } else if let block {
            onReadingPosition(block)
            onReaderScroll(block)
        }
    }

    private func scroll(to block: Int, sourceOffset: Int? = nil, viewportY: CGFloat = 0,
                        rows: [RenderRow], proxy: ScrollViewProxy) {
        guard let row = rows.first(where: { $0.start <= block && block < $0.end }) else { return }
        if let sourceOffset {
            if sourceCoordinates.scroll(to: sourceOffset, atViewportY: viewportY) {
                sourceCoordinates.pendingSource = nil
                onReadingSourceAnchor(sourceOffset, viewportY)
                return
            }
            sourceCoordinates.pendingSource = (sourceOffset, viewportY)
            if sourceCoordinates.hits.contains(where: {
                $0.viewportFrame(forSourceOffset: sourceOffset) != nil
            }) { return }
        }
        proxy.scrollTo(row.start, anchor: .top)
        onReadingPosition(block)
    }

    private struct RenderRow {
        let start: Int
        let end: Int
    }

    // One SwiftUI Text owns consecutive prose, so text selection can cross paragraphs.
    // Keep groups bounded: a single giant Text would defeat long-document lazy layout.
    private var renderRows: [RenderRow] {
        var result: [RenderRow] = []
        var start = 0
        while start < document.blocks.count {
            var end = start + 1
            if canMergeParagraph(at: start) {
                while end < document.blocks.count, end - start < 12 {
                    guard canMergeParagraph(at: end) else { break }
                    end += 1
                }
            }
            result.append(RenderRow(start: start, end: end))
            start = end
        }
        return result
    }

    private func canMergeParagraph(at index: Int) -> Bool {
        guard case let .paragraph(inline) = document.blocks[index].content else { return false }
        return !inline.contains { if case .image = $0 { true } else { false } }
            && !MarkdownMixedParagraph.containsMath(inline)
    }

    private func paragraphRun(_ indices: Range<Int>) -> Text {
        var result = Text(verbatim: "")
        for index in indices {
            if index != indices.lowerBound { result = result + Text(verbatim: "\n\n") }
            if case .paragraph(let inline) = document.blocks[index].content {
                result = result + MarkdownNativeText.make(inline)
            }
        }
        return result
    }
}

@MainActor
private final class MarkdownReaderCoordinates {
    weak var scrollView: NSScrollView?
    weak var attachedBridge: MarkdownReaderClipView?
    var hits: [MarkdownGlyphHit] = []
    var lastReportedOffset: Int?
    var pendingSource: (offset: Int, viewportY: CGFloat)?
    var document: MarkdownDocument?
    var selectedRange: NSRange?
    var onSelectionChanged: ((NSRange?) -> Void)?

    func clearSelection() {
        guard selectedRange != nil else { return }
        selectedRange = nil
        onSelectionChanged?(nil)
    }

    func select(from start: MarkdownSelectionGlyph, to end: MarkdownSelectionGlyph) {
        let lower = min(start.source.location, end.source.location)
        let upper = max(NSMaxRange(start.source), NSMaxRange(end.source))
        updateSelection(NSRange(location: lower, length: upper - lower))
    }

    func select(between anchor: Int, and caret: Int) {
        updateSelection(NSRange(location: min(anchor, caret), length: abs(anchor - caret)))
    }

    private func updateSelection(_ range: NSRange) {
        guard range.length > 0 else { clearSelection(); return }
        guard range != selectedRange else { return }
        selectedRange = range
        onSelectionChanged?(range)
    }

    func nextBoundary(from caret: Int, forward: Bool) -> Int? {
        var candidate: Int?
        for hit in hits {
            for glyph in hit.selectionGlyphs() {
                let boundary = forward ? NSMaxRange(glyph.source) : glyph.source.location
                guard forward ? boundary > caret : boundary < caret else { continue }
                if let best = candidate {
                    candidate = forward ? min(best, boundary) : max(best, boundary)
                } else {
                    candidate = boundary
                }
            }
        }
        return candidate
    }

    func sourceOffset(atViewportPoint point: CGPoint) -> Int? {
        for hit in hits {
            if let source = hit.sourceOffset(atViewportPoint: point) { return source }
        }
        return nil
    }

    func nearestGlyph(to point: CGPoint) -> MarkdownSelectionGlyph? {
        var nearest: MarkdownGlyphHit?
        var nearestDistance = CGFloat.infinity
        for hit in hits {
            let rect = hit.viewportFrame
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = dy * dy * 4 + dx * dx
            if distance < nearestDistance {
                nearest = hit
                nearestDistance = distance
            }
        }
        guard let hit = nearest else { return nil }
        var closest: MarkdownSelectionGlyph?
        var closestDistance = CGFloat.infinity
        for glyph in hit.selectionGlyphs() {
            let rect = glyph.frame
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = dy * dy * 4 + dx * dx
            if distance < closestDistance {
                closest = glyph
                closestDistance = distance
            }
        }
        return closest
    }

    func copySelection(details: [String: Bool]) -> String? {
        guard let selectedRange, let document else { return nil }
        return MarkdownSelectionText.copy(selectedRange, from: document, details: details)
    }

    func scrollPending() {
        guard let pendingSource else { return }
        if scroll(to: pendingSource.offset, atViewportY: pendingSource.viewportY) {
            self.pendingSource = nil
        }
    }

    func firstVisibleSource() -> (offset: Int, viewportY: CGFloat)? {
        guard let height = scrollView?.contentView.bounds.height else { return nil }
        var first: MarkdownGlyphHit?
        for hit in hits {
            let frame = hit.viewportFrame
            guard frame.maxY > 0, frame.minY < height else { continue }
            if let current = first {
                let previous = current.viewportFrame
                guard frame.minY < previous.minY - 1
                    || abs(frame.minY - previous.minY) <= 1 && frame.minX < previous.minX
                else { continue }
            }
            first = hit
        }
        return first.map { ($0.firstSourceOffset, $0.viewportFrame.minY) }
    }

    @discardableResult
    func scroll(to offset: Int, atViewportY viewportY: CGFloat) -> Bool {
        guard let scrollView, let document = scrollView.documentView else { return false }
        for hit in hits where hit.mark.source.location <= offset
                && offset < NSMaxRange(hit.mark.source) {
            guard let frame = hit.viewportFrame(forSourceOffset: offset) else { continue }
            let clip = scrollView.contentView
            let maximumY = max(0, document.frame.height - clip.bounds.height)
            let target = min(max(0, clip.bounds.minY + frame.minY - viewportY), maximumY)
            if abs(clip.bounds.minY - target) > 1 {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
                scrollView.reflectScrolledClipView(clip)
            }
            return true
        }
        return false
    }
}

/// Reuses the reader ScrollView and Text.Layout for cross-structure selection and source navigation.
private struct MarkdownReaderClipBridge: NSViewRepresentable {
    let coordinates: MarkdownReaderCoordinates
    let document: MarkdownDocument
    let detailsState: MarkdownDetailsState
    let onSelectionChanged: (NSRange?) -> Void
    let onLocateSource: ((Int) -> Void)?

    func makeNSView(context: Context) -> MarkdownReaderClipView {
        MarkdownReaderClipView()
    }

    func updateNSView(_ view: MarkdownReaderClipView, context: Context) {
        view.coordinates = coordinates
        view.detailsState = detailsState
        view.onLocateSource = onLocateSource
        coordinates.document = document
        coordinates.onSelectionChanged = onSelectionChanged
        view.attach()
    }

    static func dismantleNSView(_ view: MarkdownReaderClipView, coordinator: ()) {
        view.detachSelectionGesture()
        view.detachKeyboardMonitor()
        view.onLocateSource = nil
        view.detailsState = nil
        if let coordinates = view.coordinates, coordinates.attachedBridge === view {
            coordinates.attachedBridge = nil
            coordinates.scrollView = nil
            coordinates.onSelectionChanged = nil
            coordinates.document = nil
        }
        view.coordinates = nil
    }
}

private final class MarkdownReaderClipView: NSView, NSGestureRecognizerDelegate {
    var coordinates: MarkdownReaderCoordinates?
    var detailsState: MarkdownDetailsState?
    var onLocateSource: ((Int) -> Void)?
    private var dragAnchor: MarkdownSelectionGlyph?
    private var selectionAnchorOffset: Int?
    private var selectionCaretOffset: Int?
    private var keyboardMonitor: Any?
    private var previewHasInputFocus = false
    private lazy var selectionGesture = NSPanGestureRecognizer(target: self, action: #selector(selectText(_:)))
    private lazy var sourceClickGesture: NSClickGestureRecognizer = {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(locateSource(_:)))
        recognizer.numberOfClicksRequired = 2
        recognizer.delegate = self
        return recognizer
    }()

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        true
    }

    @objc private func locateSource(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended,
              let clip = coordinates?.scrollView?.contentView,
              let offset = coordinates?.sourceOffset(atViewportPoint: recognizer.location(in: clip))
        else { return }
        onLocateSource?(offset)
    }

    @objc private func selectText(_ recognizer: NSPanGestureRecognizer) {
        guard let coordinates, let clip = coordinates.scrollView?.contentView else { return }
        let point = recognizer.location(in: clip)
        let delta = recognizer.translation(in: clip)
        let origin = CGPoint(x: point.x - delta.x, y: point.y - delta.y)
        switch recognizer.state {
        case .began:
            dragAnchor = coordinates.nearestGlyph(to: origin)
            selectionAnchorOffset = dragAnchor?.insertionOffset(at: origin)
            selectionCaretOffset = selectionAnchorOffset
            coordinates.clearSelection()
        case .changed, .ended:
            if dragAnchor == nil { dragAnchor = coordinates.nearestGlyph(to: origin) }
            guard let anchor = dragAnchor,
                  let end = coordinates.nearestGlyph(to: point) else { return }
            if anchor.isSeparateText(from: end) {
                coordinates.select(from: anchor, to: end)
                selectionCaretOffset = end.insertionOffset(at: point)
                if recognizer.state == .ended { window?.makeFirstResponder(self) }
            } else {
                coordinates.clearSelection()
            }
            if recognizer.state == .ended { dragAnchor = nil }
        default:
            dragAnchor = nil
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let text = coordinates?.copySelection(details: detailsState?.expanded ?? [:]),
              !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let document = coordinates?.document,
              let range = MarkdownSelectionText.fullRange(in: document) else { return }
        selectionAnchorOffset = range.location
        selectionCaretOffset = NSMaxRange(range)
        coordinates?.select(between: range.location, and: NSMaxRange(range))
    }

    override func cancelOperation(_ sender: Any?) {
        coordinates?.clearSelection()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attach()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, coordinates?.attachedBridge === self {
            detachSelectionGesture()
            detachKeyboardMonitor()
            coordinates?.attachedBridge = nil
            coordinates?.scrollView = nil
        } else {
            attach()
        }
    }

    func attach() {
        guard window != nil, let coordinates, let scrollView = enclosingScrollView,
              coordinates.attachedBridge !== self || coordinates.scrollView !== scrollView else { return }
        detachSelectionGesture()
        coordinates.attachedBridge = self
        coordinates.scrollView = scrollView
        selectionGesture.delegate = self
        scrollView.contentView.addGestureRecognizer(selectionGesture)
        scrollView.contentView.addGestureRecognizer(sourceClickGesture)
        if keyboardMonitor == nil {
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                return self.routeReaderSelection(event)
            }
        }
        coordinates.scrollPending()
    }

    private func routeReaderSelection(_ event: NSEvent) -> NSEvent? {
        guard let window, let scrollView = coordinates?.scrollView else { return event }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            let clip = scrollView.contentView
            let point = clip.convert(event.locationInWindow, from: nil)
            previewHasInputFocus = event.window === window && clip.bounds.contains(point)
            if previewHasInputFocus, event.type == .leftMouseDown {
                if event.modifierFlags.contains(.shift), let anchor = selectionAnchorOffset,
                   let glyph = coordinates?.nearestGlyph(to: point) {
                    let caret = glyph.insertionOffset(at: point)
                    selectionCaretOffset = caret
                    coordinates?.select(between: anchor, and: caret)
                    window.makeFirstResponder(self)
                    return nil
                }
                selectionAnchorOffset = coordinates?.nearestGlyph(to: point)?.insertionOffset(at: point)
                selectionCaretOffset = selectionAnchorOffset
            } else {
                selectionAnchorOffset = nil
                selectionCaretOffset = nil
            }
            coordinates?.clearSelection()
            return event
        }
        guard previewHasInputFocus, event.window === window, window.isKeyWindow else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil)
            window.makeFirstResponder(self)
            return nil
        }
        if modifiers == .shift, let caret = selectionCaretOffset,
           let anchor = selectionAnchorOffset, event.keyCode == 123 || event.keyCode == 124,
           let next = coordinates?.nextBoundary(from: caret, forward: event.keyCode == 124) {
            selectionCaretOffset = next
            coordinates?.select(between: anchor, and: next)
            window.makeFirstResponder(self)
            return nil
        }
        return event
    }

    func detachKeyboardMonitor() {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        previewHasInputFocus = false
        selectionAnchorOffset = nil
        selectionCaretOffset = nil
    }

    func detachSelectionGesture() {
        selectionGesture.view?.removeGestureRecognizer(selectionGesture)
        sourceClickGesture.view?.removeGestureRecognizer(sourceClickGesture)
    }
}

private struct MarkdownSourceGlyph: TextAttribute, Equatable {
    let source: NSRange
    let displayLength: Int
    var sourceRuns: [MarkdownSourceRun] = []
    var displayedLineStarts: [Int] = []

    func original(for display: NSRange) -> NSRange? {
        if sourceRuns.isEmpty {
            guard source.length == displayLength else { return source }
            return NSRange(location: source.location + display.location, length: display.length)
        }
        var lower = 0
        var upper = sourceRuns.count
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if NSMaxRange(sourceRuns[mid].displayed) <= display.location { lower = mid + 1 }
            else { upper = mid }
        }
        guard lower < sourceRuns.count else { return nil }
        let run = sourceRuns[lower]
        guard run.displayed.location <= display.location,
              display.location < NSMaxRange(run.displayed) else { return nil }
        if run.displayed.length != run.original.length { return run.original }
        let offset = display.location - run.displayed.location
        return NSRange(location: run.original.location + offset,
                       length: min(display.length, run.original.length - offset))
    }
}

private struct MarkdownSelectionGlyph {
    let source: NSRange
    let frame: CGRect
    let group: Int
    let textIndex: Int

    func insertionOffset(at point: CGPoint) -> Int {
        point.x < frame.midX ? source.location : NSMaxRange(source)
    }

    func isSeparateText(from other: Self) -> Bool {
        group != other.group || textIndex != other.textIndex
    }
}

private struct MarkdownGlyphHit: Equatable {
    let mark: MarkdownSourceGlyph
    let first: Text.Layout.CharacterIndex
    let run: Text.Layout.Run
    let viewportOrigin: CGPoint
    let group: Int
    let textIndex: Int
    let isLink: Bool
    let displayedLineStart: Int

    var viewportFrame: CGRect {
        run.typographicBounds.rect.offsetBy(dx: viewportOrigin.x, dy: viewportOrigin.y)
    }

    func selectionGlyphs() -> [MarkdownSelectionGlyph] {
        run.compactMap { glyph in
            guard let firstIndex = glyph.characterIndices.min(),
                  let lastIndex = glyph.characterIndices.max() else { return nil }
            let displayed = NSRange(
                location: displayedLineStart + max(0, first.distance(to: firstIndex)),
                length: max(1, firstIndex.distance(to: lastIndex) + 1)
            )
            guard let mapped = mark.original(for: displayed), mapped.length > 0 else { return nil }
            return MarkdownSelectionGlyph(source: mapped,
                                          frame: glyph.typographicBounds.rect.offsetBy(
                                            dx: viewportOrigin.x, dy: viewportOrigin.y
                                          ),
                                          group: group, textIndex: textIndex)
        }
    }

    func selectedGlyphRects(intersecting selection: NSRange) -> [CGRect] {
        guard NSIntersectionRange(mark.source, selection).length > 0 else { return [] }
        return selectionGlyphs().compactMap {
            NSIntersectionRange($0.source, selection).length > 0 ? $0.frame : nil
        }
    }

    var firstSourceOffset: Int {
        let index = run.characterIndices.min() ?? first
        let distance = first.distance(to: index)
        return mark.original(for: NSRange(
            location: displayedLineStart + max(0, distance), length: 1
        ))?.location
            ?? mark.source.location
    }

    func viewportFrame(forSourceOffset target: Int) -> CGRect? {
        guard target >= mark.source.location, target < NSMaxRange(mark.source) else { return nil }
        for glyph in run {
            guard let start = glyph.characterIndices.min(),
                  let end = glyph.characterIndices.max() else { continue }
            let displayed = NSRange(
                location: displayedLineStart + max(0, first.distance(to: start)),
                length: max(1, start.distance(to: end) + 1)
            )
            guard let mapped = mark.original(for: displayed) else { continue }
            if target >= mapped.location && target < NSMaxRange(mapped) {
                return glyph.typographicBounds.rect
                    .offsetBy(dx: viewportOrigin.x, dy: viewportOrigin.y)
            }
        }
        return nil
    }

    func sourceOffset(atViewportPoint point: CGPoint) -> Int? {
        guard !isLink, viewportFrame.contains(point) else { return nil }
        for glyph in run {
            let frame = glyph.typographicBounds.rect
                .offsetBy(dx: viewportOrigin.x, dy: viewportOrigin.y)
            guard frame.contains(point), let index = glyph.characterIndices.min() else { continue }
            let relative = displayedLineStart + first.distance(to: index)
            guard relative >= 0, relative < mark.displayLength else { return nil }
            return mark.original(for: NSRange(location: relative, length: 1))?.location
        }
        return nil
    }
}

private struct MarkdownGlyphHitPreference: PreferenceKey {
    static var defaultValue: [MarkdownGlyphHit] { [] }

    static func reduce(value: inout [MarkdownGlyphHit], nextValue: () -> [MarkdownGlyphHit]) {
        value.append(contentsOf: nextValue())
    }
}

private struct MarkdownGlyphMapping: ViewModifier {
    let group: Int

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                    GeometryReader { geometry in
                        let mapped = layouts.enumerated().flatMap { textIndex, entry in
                            let origin = geometry[entry.origin]
                            let viewportFrame = geometry.frame(in: .named("bailey.markdown.reader"))
                            let viewportOrigin = CGPoint(x: origin.x + viewportFrame.minX,
                                                         y: origin.y + viewportFrame.minY)
                            var firstIndices: [NSRange: Text.Layout.CharacterIndex] = [:]
                            let lines = entry.layout.map { line in
                                line.compactMap { run -> (Text.Layout.Run, MarkdownSourceGlyph)? in
                                    guard let marker = run[MarkdownSourceGlyph.self],
                                          let index = run.characterIndices.min() else { return nil }
                                    if marker.displayedLineStarts.isEmpty {
                                        firstIndices[marker.source] = min(
                                            index, firstIndices[marker.source] ?? index
                                        )
                                    }
                                    return (run, marker)
                                }
                            }
                            return lines.enumerated().flatMap { lineIndex, runs in
                                var lineFirst: [NSRange: Text.Layout.CharacterIndex] = [:]
                                for (run, mark) in runs where !mark.displayedLineStarts.isEmpty {
                                    guard let index = run.characterIndices.min() else { continue }
                                    lineFirst[mark.source] = min(index, lineFirst[mark.source] ?? index)
                                }
                                return runs.compactMap { run, mark -> MarkdownGlyphHit? in
                                    let isCode = !mark.displayedLineStarts.isEmpty
                                    guard !isCode || mark.displayedLineStarts.indices.contains(lineIndex),
                                          let first = isCode ? lineFirst[mark.source]
                                              : firstIndices[mark.source] else { return nil }
                                    return MarkdownGlyphHit(
                                        mark: mark, first: first, run: run,
                                        viewportOrigin: viewportOrigin, group: group, textIndex: textIndex,
                                        isLink: run[MarkdownLinkGlyph.self] != nil,
                                        displayedLineStart: isCode ? mark.displayedLineStarts[lineIndex] : 0
                                    )
                                }
                            }
                        }
                        Color.clear.preference(key: MarkdownGlyphHitPreference.self, value: mapped)
                    }
                    .allowsHitTesting(false)
            }
    }
}

struct MarkdownLinkGlyph: TextAttribute {}

/// Text's selection cursor overrides SwiftUI pointerStyle. The transparent
/// AppKit cursor rects use SwiftUI's exact glyph layout and never own mouse clicks.
private struct MarkdownLinkCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
            GeometryReader { geometry in
                MarkdownLinkCursorRects(rects: layouts.flatMap { entry in
                    let origin = geometry[entry.origin]
                    return entry.layout.flatMap { line in
                        line.compactMap { run -> CGRect? in
                            guard run[MarkdownLinkGlyph.self] != nil else { return nil }
                            return run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                        }
                    }
                })
            }
        }
    }
}

private struct MarkdownLinkCursorRects: NSViewRepresentable {
    let rects: [CGRect]

    func makeNSView(context: Context) -> MarkdownCursorRectView {
        MarkdownCursorRectView()
    }

    func updateNSView(_ view: MarkdownCursorRectView, context: Context) {
        guard view.linkRects != rects else { return }
        view.linkRects = rects
        view.updateTrackingAreas()
    }

    static func dismantleNSView(_ view: MarkdownCursorRectView, coordinator: ()) {
        view.clearTracking()
    }
}

final class MarkdownCursorRectView: NSView {
    var linkRects: [CGRect] = []
    private weak var trackingHost: NSView?
    private var linkTrackingAreas: [NSTrackingArea] = []
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { clearTracking() }
        super.viewWillMove(toWindow: newWindow)
    }

    func clearTracking() {
        if let trackingHost {
            linkTrackingAreas.forEach { trackingHost.removeTrackingArea($0) }
        }
        linkTrackingAreas.removeAll()
        trackingHost = nil
    }

    override func updateTrackingAreas() {
        clearTracking()
        var ancestor = superview
        while let view = ancestor, !(view is NSClipView) {
            ancestor = view.superview
        }
        if let host = (ancestor as? NSClipView)?.documentView ?? window?.contentView {
            trackingHost = host
            linkTrackingAreas = linkRects.map {
                NSTrackingArea(rect: convert($0, to: host),
                               options: [.activeInKeyWindow, .mouseEnteredAndExited,
                                         .mouseMoved, .cursorUpdate],
                               owner: self, userInfo: nil)
            }
            linkTrackingAreas.forEach(host.addTrackingArea)
        }
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }
}

enum MarkdownGitHubColors {
    static func background(dark: Bool) -> Color {
        dark ? Color(red: 13 / 255, green: 17 / 255, blue: 23 / 255) : .white
    }
    static func text(dark: Bool) -> Color {
        dark ? Color(red: 240 / 255, green: 246 / 255, blue: 252 / 255)
             : Color(red: 31 / 255, green: 35 / 255, blue: 40 / 255)
    }
    static func link(dark: Bool) -> Color {
        dark ? Color(red: 68 / 255, green: 147 / 255, blue: 248 / 255)
             : Color(red: 9 / 255, green: 105 / 255, blue: 218 / 255)
    }
    static func muted(dark: Bool) -> Color {
        dark ? Color(red: 21 / 255, green: 27 / 255, blue: 35 / 255)
             : Color(red: 246 / 255, green: 248 / 255, blue: 250 / 255)
    }
    static func secondary(dark: Bool) -> Color {
        dark ? Color(red: 145 / 255, green: 152 / 255, blue: 161 / 255)
             : Color(red: 89 / 255, green: 99 / 255, blue: 110 / 255)
    }
    static func border(dark: Bool) -> Color {
        dark ? Color(red: 61 / 255, green: 68 / 255, blue: 77 / 255)
             : Color(red: 209 / 255, green: 217 / 255, blue: 224 / 255)
    }
}

private extension MarkdownAlert {
    var title: LocalizedStringResource {
        switch self {
        case .note: LocalizedStringResource("Note", table: "Editor")
        case .tip: LocalizedStringResource("Tip", table: "Editor")
        case .important: LocalizedStringResource("Important", table: "Editor")
        case .warning: LocalizedStringResource("Warning", table: "Editor")
        case .caution: LocalizedStringResource("Caution", table: "Editor")
        }
    }

    var symbol: String {
        switch self {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.circle"
        case .warning: "exclamationmark.triangle"
        case .caution: "stop.circle"
        }
    }

    var tint: Color {
        switch self {
        case .note: .blue
        case .tip: .green
        case .important: .purple
        case .warning: .orange
        case .caution: .red
        }
    }
}

private struct MarkdownNativeBlockView: View {
    let block: MarkdownNativeBlock
    let resource: MarkdownResource
    let assetRefresh: UInt
    var anchor: String? = nil
    var selectionPath: [Int] = []
    @State private var headingHovered = false
    @FocusState private var headingLinkFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private static let headingSizes: [CGFloat] = [32, 24, 20, 16, 14, 12]

    private static func headingSize(_ level: Int) -> CGFloat {
        headingSizes[max(1, min(level, 6)) - 1]
    }

    var body: some View {
        switch block {
        case .heading(let level, let inline):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let anchor {
                        ZStack {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("#" + anchor, forType: .string)
                            } label: {
                                Rectangle()
                                    .fill(.white.opacity(0.001))
                                    .frame(width: 20, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Copy heading link")
                            .accessibilityLabel("Copy heading link")
                            .accessibilityIdentifier("bailey.markdown.anchor.\(anchor)")
                            .focused($headingLinkFocused)

                            Image(systemName: "link")
                                .font(.system(size: 13))
                                .foregroundStyle(MarkdownGitHubColors.secondary(dark: colorScheme == .dark))
                                .opacity(headingHovered || headingLinkFocused ? 1 : 0)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .frame(width: 20, height: 24)
                        .overlay {
                            GeometryReader { geometry in
                                MarkdownLinkCursorRects(rects: [
                                    CGRect(origin: .zero, size: geometry.size)
                                ])
                                .accessibilityHidden(true)
                            }
                        }
                    }
                    Group {
                        if MarkdownMixedParagraph.containsMath(inline) {
                            MarkdownMixedParagraph(inline: inline, resource: resource,
                                                   assetRefresh: assetRefresh,
                                                   formulaFontSize: Self.headingSize(level))
                        } else {
                            MarkdownNativeText.make(inline).textSelection(.enabled)
                        }
                    }
                        .font(.system(size: Self.headingSize(level), weight: .semibold))
                        .foregroundStyle(level == 6
                            ? MarkdownGitHubColors.secondary(dark: colorScheme == .dark)
                            : MarkdownGitHubColors.text(dark: colorScheme == .dark))
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                }
                .contentShape(Rectangle())
                .onHover { headingHovered = $0 }
                .padding(.leading, -20)
                if level <= 2 { Divider() }
            }
            .padding(.top, 8)
        case .paragraph(let inline):
            if inline.contains(where: { if case .image = $0 { true } else { false } })
                || MarkdownMixedParagraph.containsMath(inline) {
                MarkdownMixedParagraph(inline: inline, resource: resource, assetRefresh: assetRefresh)
            } else {
                MarkdownNativeText.make(inline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .image(let source, let alt):
            if let url = URL(string: source) {
                MarkdownResourceImage(url: url, alt: alt, resource: resource,
                                      refresh: assetRefresh)
            } else {
                Text(verbatim: alt).foregroundStyle(.secondary)
            }
        case .quote(let blocks):
            quotation(blocks)
        case .alert(let alert, let blocks):
            quotation(blocks, alert: alert)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let checked = items[index].checked {
                            Image(systemName: checked ? "checkmark.square" : "square")
                                .accessibilityLabel(checked ? "Completed" : "Incomplete")
                        } else {
                            Text(verbatim: ordered ? "\(start + index)." : "•")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items[index].blocks.indices, id: \.self) { blockIndex in
                                MarkdownNativeBlockView(block: items[index].blocks[blockIndex],
                                                        resource: resource, assetRefresh: assetRefresh,
                                                        selectionPath: selectionPath + [index, blockIndex])
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.leading, 16)
        case .table(let head, let rows, let alignments):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(head.indices, id: \.self) { index in
                            cell(head[index], alignment: aligned(at: index, in: alignments), header: true)
                        }
                    }
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { column in
                                cell(rows[row][column],
                                     alignment: aligned(at: column, in: alignments), header: false)
                            }
                        }
                        .background(rows.indices.contains(row) && row.isMultiple(of: 2)
                            ? MarkdownGitHubColors.muted(dark: colorScheme == .dark)
                            : MarkdownGitHubColors.background(dark: colorScheme == .dark))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(MarkdownGitHubColors.border(dark: colorScheme == .dark))
                }
            }
        case .code(let source, let language, let sourceRuns):
            MarkdownCodeBlockView(source: source, language: language, sourceRuns: sourceRuns)
        case .mermaid(let source, let line):
            MarkdownMermaidView(source: source, line: line)
        case .mathBlock(let latex):
            MarkdownFormulaView(latex: latex, display: true)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .center)
        case .html(let nodes):
            MarkdownHTMLContent(nodes: nodes, resource: resource, assetRefresh: assetRefresh,
                                selectionPath: selectionPath)
        case .rawHTML(let source):
            Text(verbatim: source).font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
        case .rule:
            Divider()
        }
    }

    private func aligned(at index: Int, in alignments: [MarkdownColumnAlignment]) -> Alignment {
        guard alignments.indices.contains(index) else { return .leading }
        switch alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func quotation(_ blocks: [MarkdownNativeBlock], alert: MarkdownAlert? = nil) -> some View {
        HStack(alignment: .top, spacing: 16) {
            (alert?.tint ?? MarkdownGitHubColors.border(dark: colorScheme == .dark)).frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                if let alert {
                    Label {
                        Text(alert.title)
                    } icon: {
                        Image(systemName: alert.symbol).accessibilityHidden(true)
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(alert.tint)
                    .accessibilityAddTraits(.isHeader)
                }
                ForEach(blocks.indices, id: \.self) { index in
                    MarkdownNativeBlockView(block: blocks[index], resource: resource,
                                            assetRefresh: assetRefresh,
                                            selectionPath: selectionPath + [index])
                }
            }
            .foregroundStyle(alert == nil ? Color.secondary : MarkdownGitHubColors.text(dark: colorScheme == .dark))
        }
    }

    private func cell(_ inline: [MarkdownInline], alignment: Alignment, header: Bool) -> some View {
        Group {
            if MarkdownMixedParagraph.containsMath(inline) {
                MarkdownMixedParagraph(inline: inline, resource: resource,
                                       assetRefresh: assetRefresh)
            } else {
                MarkdownNativeText.make(inline)
                    .textSelection(.enabled)
            }
        }
            .fontWeight(header ? .semibold : .regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minWidth: 64, maxWidth: .infinity, alignment: alignment)
            .overlay(alignment: .trailing) {
                MarkdownGitHubColors.border(dark: colorScheme == .dark).frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                MarkdownGitHubColors.border(dark: colorScheme == .dark).frame(height: 1)
            }
    }
}


private struct MarkdownMixedParagraph: View {
    private enum Segment {
        case text([MarkdownInline])
        case image(String, String)
        case math(String, display: Bool)
    }

    let inline: [MarkdownInline]
    let resource: MarkdownResource
    let assetRefresh: UInt
    var formulaFontSize: CGFloat? = nil

    static func containsMath(_ nodes: [MarkdownInline]) -> Bool {
        nodes.contains { node in
            switch node {
            case .math: true
            case .strong(let children), .emphasis(let children), .strike(let children),
                 .link(_, let children): containsMath(children)
            default: false
            }
        }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var text: [MarkdownInline] = []
        func flush() {
            if !text.isEmpty { result.append(.text(text)); text.removeAll() }
        }
        func collect(_ nodes: [MarkdownInline],
                     decorated: @escaping (MarkdownInline) -> MarkdownInline) {
            for node in nodes {
                switch node {
                case .image(let source, let alt):
                    flush()
                    result.append(.image(source, alt))
                case .math(let latex, let display):
                    flush()
                    result.append(.math(latex, display: display))
                case .strong(let children):
                    collect(children) { decorated(.strong([$0])) }
                case .emphasis(let children):
                    collect(children) { decorated(.emphasis([$0])) }
                case .strike(let children):
                    collect(children) { decorated(.strike([$0])) }
                case .link(let destination, let children):
                    collect(children) { decorated(.link(destination, [$0])) }
                default:
                    text.append(decorated(node))
                }
            }
        }
        collect(inline, decorated: { $0 })
        flush()
        return result
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ForEach(segments.indices, id: \.self) { index in
                    content(segments[index], inline: true)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(segments.indices, id: \.self) { index in
                    content(segments[index], inline: false)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ segment: Segment, inline: Bool) -> some View {
        switch segment {
        case .text(let inlines):
            MarkdownNativeText.make(inlines)
                .fixedSize(horizontal: inline, vertical: true)
                .textSelection(.enabled)
        case .image(let source, let alt):
            if let url = URL(string: source) {
                MarkdownResourceImage(url: url, alt: alt, resource: resource, refresh: assetRefresh)
                    .fixedSize(horizontal: inline, vertical: false)
            } else {
                Text(verbatim: alt).foregroundStyle(.secondary)
            }
        case .math(let latex, let display):
            MarkdownFormulaView(latex: latex, display: display,
                                fontSize: formulaFontSize)
        }
    }
}

private struct MarkdownCodeBlockView: View {
    let source: String
    let language: String?
    let sourceRuns: [MarkdownSourceRun]
    @State private var hovering = false
    @State private var copied = false
    @FocusState private var copyFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal) {
            MarkdownCodeText(source: source, language: language, sourceRuns: sourceRuns)
                .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(source, forType: .string)
            } label: {
                Image(systemName: copied ? "checkmark" : "document.on.document")
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .foregroundStyle(MarkdownGitHubColors.secondary(dark: colorScheme == .dark)
                .opacity(hovering || copyFocused ? 1 : 0.001))
            .background(MarkdownGitHubColors.background(dark: colorScheme == .dark)
                            .opacity(hovering || copyFocused ? 1 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(MarkdownGitHubColors.border(dark: colorScheme == .dark)
                        .opacity(hovering || copyFocused ? 1 : 0))
            }
            .accessibilityLabel("Copy")
            .accessibilityValue(copied ? "Copied" : "Ready")
            .help(copied ? "Copied" : "Copy code")
            .focused($copyFocused)
            .pointerStyle(.link)
            .padding(7)
        }
        .background(MarkdownGitHubColors.muted(dark: colorScheme == .dark),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if !inside { copied = false }
        }
        .onChange(of: source) { _, _ in copied = false }
    }
}

struct MarkdownCodeText: View {
    struct Request: Hashable {
        let source: String
        let language: String?
    }

    private struct Rendered {
        let request: Request
        let value: AttributedString
    }

    let source: String
    let language: String?
    let sourceRuns: [MarkdownSourceRun]
    @State private var rendered: Rendered?

    private var request: Request { Request(source: source, language: language) }

    private var mappedText: Text {
        let text: Text
        if let rendered, rendered.request == request {
            text = Text(rendered.value)
        } else {
            text = Text(verbatim: source)
        }
        guard let first = sourceRuns.first, let last = sourceRuns.last else { return text }
        let sourceRange = NSRange(location: first.original.location,
                                  length: NSMaxRange(last.original) - first.original.location)
        let code = source as NSString
        var lineStarts = [0]
        for offset in 0..<code.length where code.character(at: offset) == 10 {
            lineStarts.append(offset + 1)
        }
        return text.customAttribute(MarkdownSourceGlyph(
            source: sourceRange, displayLength: code.length, sourceRuns: sourceRuns,
            displayedLineStarts: lineStarts
        ))
    }

    var body: some View {
        mappedText
        .font(.system(size: 13.6, design: .monospaced))
        .lineSpacing(3)
        .textSelection(.enabled)
        .task(id: request) {
            rendered = nil
            guard let value = await Self.highlight(source, language: language),
                  !Task.isCancelled else { return }
            rendered = Rendered(request: request, value: value)
        }
    }

    /// Reuse the editor's Tree-sitter grammars, query cache and Diff capture pipeline.
    /// Large code blocks remain readable without forcing a full syntax parse.
    static func highlight(_ source: String, language marker: String?) async -> AttributedString? {
        guard source.utf8.count <= 1 << 20,
              let marker, let language = SyntaxHighlighting.language(forInjectionName: marker),
              let grammarIndex = language.grammarIndex else { return nil }
        let data = SyntaxHighlighting.highlightsData(for: language)
        guard let query = await HighlightQueryCache.shared.query(for: language, data: data)
        else { return nil }
        let context = DiffHighlightContext(grammarIndex: grammarIndex, query: query)
        let sourceParser = DiffSyntaxSource()
        let captures = await sourceParser.captures(
            text: source, context: context,
            ranges: [NSRange(location: 0, length: source.utf16.count)]
        )
        guard !Task.isCancelled else { return nil }
        let attributed = NSMutableAttributedString(string: source)
        for run in DiffSyntaxHighlighter.colors(for: captures) {
            attributed.addAttribute(.foregroundColor, value: run.color, range: run.range)
        }
        return AttributedString(attributed)
    }
}

/// Compose adjacent AST inline fragments as one Text so selection remains native.
enum MarkdownNativeText {
    private struct ActiveHTML {
        let name: String
        let href: URL?
    }

    static func make(_ nodes: [MarkdownInline]) -> Text {
        let (tags, matched) = MarkdownInlineHTML.scan(nodes)

        var active: [ActiveHTML] = []
        var result = Text(verbatim: "")
        for (index, node) in nodes.enumerated() {
            if let tag = tags[index] {
                if tag.name == "br", !tag.closing {
                    result = result + Text(verbatim: "\n")
                    continue
                }
                if matched.contains(index) {
                    if tag.closing {
                        active.removeLast()
                    } else {
                        active.append(ActiveHTML(
                            name: tag.name,
                            href: tag.name == "a" ? validLink(in: tag.raw) : nil
                        ))
                    }
                    continue
                }
            }
            var text = part(node)
            for tag in active {
                switch tag.name {
                case "b", "strong": text = text.bold()
                case "i", "em": text = text.italic()
                case "s", "del": text = text.strikethrough()
                case "code", "kbd": text = text.font(.system(size: 13.5, design: .monospaced))
                case "a":
                    if let url = tag.href {
                        var linked = attributed([node])
                        linked.link = url
                        text = Text(linked).customAttribute(MarkdownLinkGlyph())
                    }
                default: break
                }
            }
            result = result + text
        }
        return result
    }

    private static func validLink(in openTag: String) -> URL? {
        guard let elements = MarkdownHTML.parse(openTag + "link</a>"),
              case let .link(url, _) = elements.first else { return nil }
        return url
    }

    private static func part(_ node: MarkdownInline) -> Text {
        switch node {
        case .text(let content, let source):
            if let source {
                return Text(verbatim: content).customAttribute(
                    MarkdownSourceGlyph(source: source, displayLength: content.utf16.count)
                )
            }
            return Text(verbatim: content)
        case .code(let content, let source):
            let text = Text(attributed([node]))
            guard let source else { return text }
            return text.customAttribute(
                MarkdownSourceGlyph(source: source, displayLength: content.utf16.count)
            )
        case .emphasis(let children):
            return make(children).italic()
        case .strong(let children):
            return make(children).bold()
        case .strike(let children):
            return make(children).strikethrough()
        case .link(let destination, let children):
            guard let url = URL(string: destination) else { return make(children) }
            // Keep nested bold/italic/code styles when making the entire link clickable.
            var linked = attributed(children)
            linked.link = url
            return Text(linked).customAttribute(MarkdownLinkGlyph())
        case .image(_, let alt):
            return Text(verbatim: alt)
        case .math(let latex, let display):
            return Text(verbatim: display ? "$$\(latex)$$" : "$\(latex)$")
        case .html(let source):
            return Text(verbatim: source)
        case .lineBreak:
            return Text(verbatim: "\n")
        }
    }

    static func attributed(_ nodes: [MarkdownInline]) -> AttributedString {
        nodes.reduce(into: AttributedString()) { result, node in
            var part: AttributedString
            switch node {
            case .text(let value, _), .html(let value):
                part = AttributedString(value)
            case .code(let value, _):
                part = AttributedString(value)
                add(.code, to: &part)
                part.backgroundColor = Color.primary.opacity(0.08)
            case .strong(let children):
                part = attributed(children)
                add(.stronglyEmphasized, to: &part)
            case .emphasis(let children):
                part = attributed(children)
                add(.emphasized, to: &part)
            case .strike(let children):
                part = attributed(children)
                add(.strikethrough, to: &part)
            case .link(let destination, let children):
                part = attributed(children)
                part.link = URL(string: destination)
                if destination.hasPrefix("#bailey-note:"), !part.characters.isEmpty,
                   part.characters.allSatisfy(\.isNumber) {
                    part.font = .system(size: 12, weight: .medium)
                    part.baselineOffset = 5
                }
            case .image(_, let alt):
                part = AttributedString(alt)
            case .math(let latex, let display):
                part = AttributedString(display ? "$$\(latex)$$" : "$\(latex)$")
            case .lineBreak:
                part = AttributedString("\n")
            }
            result += part
        }
    }

    private static func add(_ intent: InlinePresentationIntent, to text: inout AttributedString) {
        for run in text.runs {
            text[run.range].inlinePresentationIntent =
                (run.inlinePresentationIntent ?? []).union(intent)
        }
    }
}
