import Foundation
import SwiftTreeSitter

nonisolated final class TextCoordinateIndex {
    private var lineStarts = [0]
    private(set) var length = 0

    init(_ text: String) {
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { lineStarts.append(offset) }
        }
        length = offset
    }

    func point(at offset: Int) -> Point? {
        guard offset >= 0, offset <= length else { return nil }
        let row = upperBound(offset) - 1
        return Point(row: row, column: (offset - lineStarts[row]) * 2)
    }

    func replace(in range: NSRange, with replacement: String) {
        let start = upperBound(range.location)
        let end = upperBound(NSMaxRange(range))
        var inserted: [Int] = []
        var insertedLength = 0
        for unit in replacement.utf16 {
            insertedLength += 1
            if unit == 10 { inserted.append(range.location + insertedLength) }
        }
        let delta = insertedLength - range.length
        lineStarts.replaceSubrange(start..<end, with: inserted)
        if delta != 0 {
            lineStarts.withUnsafeMutableBufferPointer { buffer in
                for index in (start + inserted.count)..<buffer.count {
                    buffer[index] += delta
                }
            }
        }
        length += delta
    }

    private func upperBound(_ offset: Int) -> Int {
        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lineStarts[middle] <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
