import Foundation
import SwiftTreeSitter

nonisolated final class TextCoordinateIndex {
    // Store UTF-16 line lengths, not absolute starts. A local edit then changes
    // only the affected lengths; the prefix index locates arbitrary positions.
    private var lineLengths: [Int] = []
    private var prefixTree: [Int] = []
    private(set) var length = 0

    init(_ text: String) {
        var start = 0
        for unit in text.utf16 {
            length += 1
            if unit == 10 {
                lineLengths.append(length - start)
                start = length
            }
        }
        lineLengths.append(length - start)
        rebuildPrefixTree()
    }

    func point(at offset: Int) -> Point? {
        guard offset >= 0, offset <= length else { return nil }
        let row = row(containing: offset)
        return Point(row: row, column: (offset - prefix(before: row)) * 2)
    }

    func replace(in range: NSRange, with replacement: String) {
        precondition(range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= length)
        let first = row(containing: range.location)
        let last = row(containing: NSMaxRange(range))
        let oldTail = last + 1 < lineLengths.count ? prefix(before: last + 1) : length

        var lengths: [Int] = []
        var cursor = range.location
        var start = prefix(before: first)
        for unit in replacement.utf16 {
            cursor += 1
            if unit == 10 {
                lengths.append(cursor - start)
                start = cursor
            }
        }
        let delta = cursor - range.location - range.length
        lengths.append(oldTail + delta - start)

        if lengths.count == last - first + 1 {
            for (offset, newLength) in lengths.enumerated() {
                let row = first + offset
                let change = newLength - lineLengths[row]
                lineLengths[row] = newLength
                add(change, at: row)
            }
        } else {
            lineLengths.replaceSubrange(first...last, with: lengths)
            rebuildPrefixTree()
        }
        length += delta
    }

    private func prefix(before row: Int) -> Int {
        var index = row
        var result = 0
        while index > 0 {
            result += prefixTree[index]
            index -= index & -index
        }
        return result
    }

    private func row(containing offset: Int) -> Int {
        var index = 0
        var consumed = 0
        var step = 1
        while step <= lineLengths.count { step <<= 1 }
        step >>= 1
        while step > 0 {
            let next = index + step
            if next <= lineLengths.count && consumed + prefixTree[next] <= offset {
                index = next
                consumed += prefixTree[next]
            }
            step >>= 1
        }
        return min(index, lineLengths.count - 1)
    }

    private func add(_ delta: Int, at row: Int) {
        guard delta != 0 else { return }
        var index = row + 1
        while index < prefixTree.count {
            prefixTree[index] += delta
            index += index & -index
        }
    }

    private func rebuildPrefixTree() {
        prefixTree = Array(repeating: 0, count: lineLengths.count + 1)
        prefixTree.withUnsafeMutableBufferPointer { buffer in
            lineLengths.withUnsafeBufferPointer { input in
                for row in input.indices {
                    let index = row + 1
                    buffer[index] += input[row]
                    let parent = index + (index & -index)
                    if parent < buffer.count { buffer[parent] += buffer[index] }
                }
            }
        }
    }
}
