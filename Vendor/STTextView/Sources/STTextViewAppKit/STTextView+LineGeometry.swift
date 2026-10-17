import AppKit
import STTextKitPlus

extension STTextView {
    var uniformDocumentHeight: CGFloat? {
        guard usesPlainTextGeometry, isHorizontallyResizable, !hasVariableLineHeight,
              let uniformLineHeight, let textLineIndex else { return nil }
        return CGFloat(textLineIndex.starts.count) * uniformLineHeight
    }

    func updateUniformLineHeight() {
        guard usesPlainTextGeometry, isHorizontallyResizable, overrideContentHeight == nil,
              !hasVariableLineHeight else { return }
        let fragments = (fragmentViewMap.keyEnumerator().allObjects as? [NSTextLayoutFragment] ?? [])
            .filter { fragmentViewMap.object(forKey: $0)?.superview != nil }
        guard let first = fragments.first?.textLineFragments.first else { return }
        let height = uniformLineHeight ?? first.typographicBounds.height
        updateTextLineIndexIfNeeded()
        guard let textLineIndex else { return }
        for fragment in fragments {
            let range = NSRange(fragment.rangeInElement, in: textContentManager)
            let rows = textLineIndex.row(at: NSMaxRange(range)) - textLineIndex.row(at: range.location)
                + (NSMaxRange(range) == textLineIndex.length ? 1 : 0)
            if fragment.textLineFragments.count != rows
                || abs(fragment.layoutFragmentFrame.height - CGFloat(rows) * height) > 0.01
                || fragment.textLineFragments.contains(where: { abs($0.typographicBounds.height - height) > 0.01 }) {
                hasVariableLineHeight = true
                resetTextCoordinateOffset()
                return
            }
        }
        uniformLineHeight = height
    }

    func updateTextLineIndexIfNeeded() {
        if usesPlainTextGeometry, textLineIndex == nil,
           let storage = (textContentManager as? NSTextContentStorage)?.textStorage {
            textLineIndex = STTextLineIndex(storage.string as NSString)
        }
    }

    func alignUniformViewport() {
        guard uniformDocumentHeight != nil, let uniformLineHeight, let textLineIndex else { return }
        let top = max(0, visibleRect.minY)
        let row = min(textLineIndex.starts.count - 1, Int(top / uniformLineHeight))
        guard let location = textContentManager.location(textContentManager.documentRange.location,
                                                        offsetBy: textLineIndex.starts[row]) else { return }
        let controller = textLayoutManager.textViewportLayoutController
        controller.relocateViewport(to: location)
        let range = NSTextRange(location: location)
        textLayoutManager.ensureLayout(for: range)
        if let frame = textLayoutManager.textSegmentFrame(in: range, type: .standard) {
            setTextCoordinateOffset(frame.minY - CGFloat(row) * uniformLineHeight)
        }
    }

    func correctUniformViewportOrigin() {
        guard uniformDocumentHeight != nil, let uniformLineHeight, let textLineIndex,
              let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange,
              let fragment = textLayoutManager.textLayoutFragment(for: viewportRange.location) else { return }
        let offset = textContentManager.offset(from: textContentManager.documentRange.location,
                                               to: fragment.rangeInElement.location)
        setTextCoordinateOffset(fragment.layoutFragmentFrame.minY - CGFloat(textLineIndex.row(at: offset)) * uniformLineHeight)
    }

    func setTextCoordinateOffset(_ offset: CGFloat) {
        contentView.bounds.origin.y = offset
        contentViewportView.frame = contentView.bounds
        contentViewportView.bounds = contentView.bounds
        selectionView.frame = contentView.bounds
        selectionView.bounds = contentView.bounds
        gutterView?.bounds.origin.y = offset
        if let gutterView {
            gutterView.containerView.frame = gutterView.bounds
            gutterView.containerView.bounds = gutterView.bounds
            gutterView.markerContainerView.frame = gutterView.bounds
            gutterView.markerContainerView.bounds = gutterView.bounds
        }
    }

    func resetTextCoordinateOffset() {
        let offset = contentView.bounds.minY
        setTextCoordinateOffset(0)
        if offset != 0, let scrollView {
            let clip = scrollView.contentView
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + offset))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func captureViewportTextAnchor(force: Bool = false) {
        guard viewportTextAnchor == nil, usesPlainTextGeometry, window != nil,
              force || !isHorizontallyResizable || hasVariableLineHeight else { return }
        let visible = contentView.visibleRect
        let fragments = (fragmentViewMap.keyEnumerator().allObjects as? [NSTextLayoutFragment] ?? [])
            .filter { fragmentViewMap.object(forKey: $0)?.superview != nil && $0.textElement?.textContentManager === textContentManager }
            .sorted { $0.rangeInElement.location < $1.rangeInElement.location }
        for fragment in fragments {
            for line in fragment.textLineFragments {
                let rect = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                                           dy: fragment.layoutFragmentFrame.minY)
                if rect.maxY > visible.minY, rect.minY < visible.maxY,
                   let range = line.textRange(in: fragment) {
                    let location = textContentManager.offset(from: textContentManager.documentRange.location, to: range.location)
                    if location >= 0, location <= textContentManager.length,
                       let anchor = NSTextRange(NSRange(location: location, length: 0), in: textContentManager),
                       let frame = textLayoutManager.textSegmentFrame(in: anchor, type: .standard) {
                        viewportTextAnchor = (location, frame.minY - visible.minY)
                    }
                    return
                }
            }
        }
    }

    func restoreViewportTextAnchor() {
        guard window != nil else { return }
        defer { viewportTextAnchor = nil }
        guard let viewportTextAnchor, let scrollView else { return }
        let clip = scrollView.contentView
        let position: CGFloat
        if uniformDocumentHeight != nil, let textLineIndex, let uniformLineHeight {
            position = CGFloat(textLineIndex.row(at: viewportTextAnchor.location)) * uniformLineHeight
        } else if let range = NSTextRange(NSRange(location: viewportTextAnchor.location, length: 0), in: textContentManager),
                  let rect = textLayoutManager.textSegmentFrame(in: range, type: .standard) {
            position = convert(rect, from: contentView).minY
        } else { return }
        let origin = position - viewportTextAnchor.offset
        if abs(clip.bounds.minY - origin) > 0.01 {
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: origin))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

struct STTextLineIndex {
    private(set) var starts: [Int]
    private var paragraphs: [Int]
    private(set) var length: Int

    init(_ text: NSString) {
        length = text.length
        starts = Self.starts(in: text, from: 0, to: text.length)
        paragraphs = Self.paragraphs(in: text, starts: starts, first: 0)
    }

    func paragraph(at offset: Int) -> Int { paragraphs[row(at: offset)] }

    func row(at offset: Int) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if starts[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }

    mutating func replace(in range: NSRange, replacementLength: Int, text: NSString) {
        let first = max(0, row(at: range.location) - 1)
        let last = min(starts.count, row(at: NSMaxRange(range)) + 2)
        let end = last < starts.count ? starts[last] : length
        let delta = replacementLength - range.length
        let inserted = Self.starts(in: text, from: starts[first], to: end + delta,
                                   includesEnd: last == starts.count)
        let insertedParagraphs = Self.paragraphs(in: text, starts: inserted, first: paragraphs[first])
        let paragraphDelta = last < starts.count
            ? insertedParagraphs.last! + (text.character(at: end + delta - 1) == 0x2028 ? 0 : 1) - paragraphs[last]
            : 0
        starts.replaceSubrange(first..<last, with: inserted)
        paragraphs.replaceSubrange(first..<last, with: insertedParagraphs)
        if delta != 0 {
            starts.withUnsafeMutableBufferPointer { buffer in
                for index in (first + inserted.count)..<buffer.count { buffer[index] += delta }
            }
        }
        if paragraphDelta != 0 {
            paragraphs.withUnsafeMutableBufferPointer { buffer in
                for index in (first + inserted.count)..<buffer.count { buffer[index] += paragraphDelta }
            }
        }
        length = text.length
    }

    private static func paragraphs(in text: NSString, starts: [Int], first: Int) -> [Int] {
        var paragraph = first
        return starts.enumerated().map { index, offset in
            if index > 0, text.character(at: offset - 1) != 0x2028 { paragraph += 1 }
            return paragraph
        }
    }

    private static func starts(in text: NSString, from start: Int, to end: Int, includesEnd: Bool = true) -> [Int] {
        var result = [start]
        var offset = start
        while offset < end {
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                              for: NSRange(location: offset, length: 0))
            if lineEnd < end || (includesEnd && lineEnd == text.length && lineEnd > contentsEnd) {
                result.append(lineEnd)
            }
            offset = lineEnd
        }
        return result
    }
}
