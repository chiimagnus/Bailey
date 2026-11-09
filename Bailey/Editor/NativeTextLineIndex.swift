// Adapted from Bailey's former local STTextView line geometry implementation.
// Source license and author attribution: Bailey/Resources/Licenses/LICENSE-sttextview-source.txt
import Foundation

/// UTF-16 line breaks with a Fenwick index; not a rendering engine.
struct NativeTextLineIndex {
    enum BreakMode { case native, gitLF }

    private var lineLengths: [Int]
    private var lengths: PrefixSums
    private var nativeOnlyLineEnds: [Bool]
    private var nativeOnlySeparatorCount: Int
    private let breakMode: BreakMode
    private(set) var length: Int

    var lineCount: Int { lineLengths.count }
    var hasNativeOnlySeparators: Bool { nativeOnlySeparatorCount > 0 }

    init(_ text: NSString, breakMode: BreakMode = .native) {
        self.breakMode = breakMode
        length = text.length
        let positions = Self.starts(in: text, from: 0, to: text.length,
                                    breakMode: breakMode)
        lineLengths = positions.enumerated().map { index, start in
            (index + 1 < positions.count ? positions[index + 1] : text.length) - start
        }
        nativeOnlyLineEnds = breakMode == .native ? positions.enumerated().map { index, _ in
            Self.isNativeOnlyTerminator(
                in: text, end: index + 1 < positions.count ? positions[index + 1] : text.length
            )
        } : []
        nativeOnlySeparatorCount = nativeOnlyLineEnds.reduce(0) { $0 + ($1 ? 1 : 0) }
        lengths = PrefixSums(lineLengths)
    }

    func offset(atLine row: Int) -> Int { lengths.sum(before: row) }
    func row(at offset: Int) -> Int { min(lengths.containing(offset), lineCount - 1) }

    @discardableResult
    mutating func replace(in range: NSRange, replacementLength: Int,
                          text: NSString) -> (replaced: Range<Int>, inserted: Range<Int>) {
        precondition(range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= length)
        let originalCount = lineCount
        let first = max(0, row(at: range.location) - 1)
        let last = min(originalCount, row(at: NSMaxRange(range)) + 2)
        let oldEnd = last < originalCount ? offset(atLine: last) : length
        let delta = replacementLength - range.length
        let end = oldEnd + delta
        let inserted = Self.starts(in: text, from: offset(atLine: first), to: end,
                                   includesEnd: last == originalCount,
                                   breakMode: breakMode)
        let newLengths = inserted.enumerated().map { index, start in
            (index + 1 < inserted.count ? inserted[index + 1] : end) - start
        }
        let newNativeOnlyEnds = breakMode == .native ? inserted.enumerated().map { index, _ in
            Self.isNativeOnlyTerminator(
                in: text, end: index + 1 < inserted.count ? inserted[index + 1] : end
            )
        } : []
        if breakMode == .native {
            let removed = nativeOnlyLineEnds[first..<last].reduce(0) { $0 + ($1 ? 1 : 0) }
            let added = newNativeOnlyEnds.reduce(0) { $0 + ($1 ? 1 : 0) }
            nativeOnlySeparatorCount += added - removed
        }
        if newLengths.count == last - first {
            for (offset, value) in newLengths.enumerated() {
                let row = first + offset
                let shift = value - lineLengths[row]
                lineLengths[row] = value
                lengths.add(shift, at: row)
                if breakMode == .native { nativeOnlyLineEnds[row] = newNativeOnlyEnds[offset] }
            }
        } else {
            lineLengths.replaceSubrange(first..<last, with: newLengths)
            lengths = PrefixSums(lineLengths)
            if breakMode == .native {
                nativeOnlyLineEnds.replaceSubrange(first..<last, with: newNativeOnlyEnds)
            }
        }
        length = text.length
        return (first..<last, first..<(first + newLengths.count))
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

    private static func isNativeOnlyTerminator(in text: NSString, end: Int) -> Bool {
        guard end > 0 else { return false }
        switch text.character(at: end - 1) {
        case 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    private static func starts(in text: NSString, from start: Int, to end: Int,
                               includesEnd: Bool = true,
                               breakMode: BreakMode) -> [Int] {
        var result = [start]
        if breakMode == .gitLF {
            for offset in start..<end where text.character(at: offset) == 10 {
                let following = offset + 1
                if following < end || (includesEnd && following == text.length) {
                    result.append(following)
                }
            }
            return result
        }
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
