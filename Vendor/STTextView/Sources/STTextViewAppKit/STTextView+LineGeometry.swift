import AppKit
import STTextKitPlus

extension STTextView {
    var uniformDocumentHeight: CGFloat? {
        guard usesPlainTextGeometry, isHorizontallyResizable, !hasVariableLineHeight,
              let uniformLineHeight, let textLineIndex else { return nil }
        return CGFloat(textLineIndex.lineCount) * uniformLineHeight
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
        let row = min(textLineIndex.lineCount - 1, Int(top / uniformLineHeight))
        guard let location = textContentManager.location(textContentManager.documentRange.location,
                                                        offsetBy: textLineIndex.offset(atLine: row)) else { return }
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
    private var lineLengths: [Int]
    private var paragraphBreaks: [Int]
    private var lengths: PrefixSums
    private var paragraphs: PrefixSums
    private(set) var length: Int

    var lineCount: Int { lineLengths.count }

    init(_ text: NSString) {
        length = text.length
        let positions = Self.starts(in: text, from: 0, to: text.length)
        lineLengths = positions.enumerated().map { index, start in
            (index + 1 < positions.count ? positions[index + 1] : text.length) - start
        }
        paragraphBreaks = positions.map { $0 > 0 && text.character(at: $0 - 1) != 0x2028 ? 1 : 0 }
        lengths = PrefixSums(lineLengths)
        paragraphs = PrefixSums(paragraphBreaks)
    }

    func offset(atLine row: Int) -> Int { lengths.sum(before: row) }
    func paragraph(at offset: Int) -> Int { paragraphs.sum(before: row(at: offset) + 1) }
    func row(at offset: Int) -> Int { min(lengths.containing(offset), lineCount - 1) }

    mutating func replace(in range: NSRange, replacementLength: Int, text: NSString) {
        precondition(range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= length)
        let originalCount = lineCount
        let first = max(0, row(at: range.location) - 1)
        let last = min(originalCount, row(at: NSMaxRange(range)) + 2)
        let oldEnd = last < originalCount ? offset(atLine: last) : length
        let delta = replacementLength - range.length
        let end = oldEnd + delta
        let inserted = Self.starts(in: text, from: offset(atLine: first), to: end,
                                   includesEnd: last == originalCount)
        let newLengths = inserted.enumerated().map { index, start in
            (index + 1 < inserted.count ? inserted[index + 1] : end) - start
        }
        let newBreaks = inserted.map { $0 > 0 && text.character(at: $0 - 1) != 0x2028 ? 1 : 0 }
        let nextBreak = last < originalCount && end > 0
            ? (text.character(at: end - 1) == 0x2028 ? 0 : 1) : 0

        if newLengths.count == last - first {
            for (offset, value) in newLengths.enumerated() {
                let row = first + offset
                let shift = value - lineLengths[row]
                lineLengths[row] = value
                lengths.add(shift, at: row)
                let breakShift = newBreaks[offset] - paragraphBreaks[row]
                paragraphBreaks[row] = newBreaks[offset]
                paragraphs.add(breakShift, at: row)
            }
            if last < originalCount {
                let breakShift = nextBreak - paragraphBreaks[last]
                paragraphBreaks[last] = nextBreak
                paragraphs.add(breakShift, at: last)
            }
        } else {
            lineLengths.replaceSubrange(first..<last, with: newLengths)
            paragraphBreaks.replaceSubrange(first..<last, with: newBreaks)
            if last < originalCount {
                paragraphBreaks[first + newBreaks.count] = nextBreak
            }
            lengths = PrefixSums(lineLengths)
            paragraphs = PrefixSums(paragraphBreaks)
        }
        length = text.length
    }

    private struct PrefixSums {
        private var tree: [Int]

        init(_ values: [Int]) {
            tree = Array(repeating: 0, count: values.count + 1)
            tree.withUnsafeMutableBufferPointer { buffer in
                values.withUnsafeBufferPointer { input in
                    for row in input.indices {
                        let index = row + 1
                        buffer[index] += input[row]
                        let parent = index + (index & -index)
                        if parent < buffer.count { buffer[parent] += buffer[index] }
                    }
                }
            }
        }

        func sum(before row: Int) -> Int {
            var index = row
            var result = 0
            while index > 0 {
                result += tree[index]
                index -= index & -index
            }
            return result
        }

        func containing(_ offset: Int) -> Int {
            var index = 0
            var covered = 0
            var step = 1
            while step < tree.count { step <<= 1 }
            step >>= 1
            while step > 0 {
                let next = index + step
                if next < tree.count && covered + tree[next] <= offset {
                    index = next
                    covered += tree[next]
                }
                step >>= 1
            }
            return index
        }

        mutating func add(_ delta: Int, at row: Int) {
            guard delta != 0 else { return }
            var index = row + 1
            while index < tree.count {
                tree[index] += delta
                index += index & -index
            }
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
