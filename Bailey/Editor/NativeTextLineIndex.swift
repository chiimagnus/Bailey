// Adapted from Bailey's former local STTextView line geometry implementation.
// Source license and author attribution: Bailey/Resources/Licenses/LICENSE-sttextview-source.txt
import Foundation

/// UTF-16 line breaks with a Fenwick index; not a rendering engine.
struct NativeTextLineIndex {
    private var lineLengths: [Int]
    private var lengths: PrefixSums
    private var maximums: LineMaximums
    private(set) var length: Int

    var lineCount: Int { lineLengths.count }
    var maximumLineUnits: Int { maximums.value }

    init(_ text: NSString) {
        length = text.length
        let positions = Self.starts(in: text, from: 0, to: text.length)
        lineLengths = positions.enumerated().map { index, start in
            (index + 1 < positions.count ? positions[index + 1] : text.length) - start
        }
        lengths = PrefixSums(lineLengths)
        maximums = LineMaximums(lineLengths)
    }

    func offset(atLine row: Int) -> Int { lengths.sum(before: row) }
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
        if newLengths.count == last - first {
            for (offset, value) in newLengths.enumerated() {
                let row = first + offset
                let shift = value - lineLengths[row]
                lineLengths[row] = value
                lengths.add(shift, at: row)
            }
            maximums.refresh(lineLengths, from: first, to: last)
        } else {
            lineLengths.replaceSubrange(first..<last, with: newLengths)
            lengths = PrefixSums(lineLengths)
            maximums = LineMaximums(lineLengths)
        }
        length = text.length
    }

    /// Fixed-size blocks keep maxima exact while avoiding a second full tree.
    private struct LineMaximums {
        private static let blockSize = 256
        private var blocks: [Int] = []

        init(_ values: [Int]) {
            blocks.reserveCapacity((values.count + Self.blockSize - 1) / Self.blockSize)
            for start in stride(from: 0, to: values.count, by: Self.blockSize) {
                blocks.append(values[start..<min(start + Self.blockSize, values.count)].max() ?? 0)
            }
        }

        var value: Int { blocks.max() ?? 0 }

        mutating func refresh(_ values: [Int], from first: Int, to last: Int) {
            guard first < last else { return }
            for block in (first / Self.blockSize)...((last - 1) / Self.blockSize) {
                let start = block * Self.blockSize
                blocks[block] = values[start..<min(start + Self.blockSize, values.count)].max() ?? 0
            }
        }
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
