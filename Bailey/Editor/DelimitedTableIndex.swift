import Foundation

nonisolated struct DelimitedTableIndex: Sendable {
    enum Separator: UInt16, CaseIterable, Sendable {
        case comma = 44
        case semicolon = 59
        case tab = 9

        static func preferred(for path: String) -> Self? {
            switch (path as NSString).pathExtension.lowercased() {
            case "csv": .comma
            case "tsv": .tab
            default: nil
            }
        }
    }

    struct Field: Sendable {
        private let start: UInt32
        private let length: UInt32

        fileprivate init(_ start: Int, endingAt end: Int) {
            self.start = UInt32(start)
            length = UInt32(end - start)
        }

        var source: NSRange { NSRange(location: Int(start), length: Int(length)) }

        func value(in text: NSString, limit: Int? = nil) -> String {
            var range = source
            let quoted = range.length >= 2 && text.character(at: range.location) == 34
            if quoted { range = NSRange(location: range.location + 1, length: range.length - 2) }
            let truncated = limit.map { range.length > $0 } ?? false
            if truncated, let limit {
                range.length = limit
                if (0xDC00...0xDFFF).contains(text.character(at: NSMaxRange(range))) { range.length -= 1 }
            }
            var value = text.substring(with: range)
            if quoted { value = value.replacingOccurrences(of: "\"\"", with: "\"", options: .literal) }
            return truncated ? value + "…" : value
        }
    }

    struct Record: Sendable {
        let source: NSRange
        let physicalLine: Int
        let lineEndingLength: Int
        fileprivate let fieldIndices: Range<Int>
        var fieldCount: Int { fieldIndices.count }
    }

    enum Problem: Equatable, Sendable {
        case unexpectedQuote
        case textAfterQuote
        case unclosedQuote
        case nul
        case unevenColumns(expected: Int, actual: Int)
        case fieldLimit
        case sourceLimit
    }

    struct Issue: Equatable, Sendable {
        let problem: Problem
        let line: Int
        let column: Int
    }

    let separator: Separator
    let needsSeparatorChoice: Bool
    let records: [Record]
    let columnCount: Int
    let issue: Issue?
    private let fields: [Field]

    func fields(in record: Record) -> ArraySlice<Field> { fields[record.fieldIndices] }

    @concurrent static func parse(
        _ text: String, preferred: Separator, selected: Separator? = nil
    ) async throws -> Self {
        try Task.checkCancellation()
        let units = text.utf16
        let sampleLimit = 16_384
        var separator = selected ?? preferred
        var needsSeparatorChoice = false
        if selected == nil {
            let sample = units.prefix(sampleLimit + 1)
            let hasMore = sample.count > sampleLimit
            let candidates = try Separator.allCases.filter { candidate in
                let scanned = try scan(sample.prefix(sampleLimit), separator: candidate)
                return scanned.records.contains {
                    $0.fieldIndices.count > 1 && (!hasMore || $0.lineEndingLength > 0)
                }
            }
            if candidates.count == 1, let detected = candidates.first { separator = detected }
            needsSeparatorChoice = candidates.count > 1 || (candidates.isEmpty && hasMore)
            if needsSeparatorChoice, !candidates.contains(separator), let candidate = candidates.first {
                separator = candidate
            }
        }
        let scanned = try scan(units, separator: separator)
        return Self(separator: separator, needsSeparatorChoice: needsSeparatorChoice,
                    records: scanned.records, columnCount: scanned.columnCount,
                    issue: scanned.issue, fields: scanned.fields)
    }

    private static func scan<Units: Sequence>(_ units: Units, separator: Separator) throws -> Scanner
        where Units.Element == UInt16 {
        var iterator = units.makeIterator()
        var current = iterator.next()
        var scanner = Scanner()
        while let unit = current {
            current = iterator.next()
            let length = unit == 13 && current == 10 ? 2 : 1
            if length == 2 { current = iterator.next() }
            if scanner.offset >= scanner.nextCancellationCheck {
                try Task.checkCancellation()
                scanner.nextCancellationCheck = scanner.offset + 65_536
            }
            guard scanner.offset <= (32 << 20) - length else {
                scanner.fail(.sourceLimit)
                return scanner
            }
            guard scanner.consume(unit, length: length, separator: separator.rawValue) else { return scanner }
        }
        try Task.checkCancellation()
        if scanner.phase == .quoted {
            scanner.fail(.unclosedQuote)
        } else if scanner.offset > scanner.recordStart {
            _ = scanner.finishRecord(endingLength: 0)
        }
        return scanner
    }

    private struct Scanner {
        enum Phase { case initial, bare, quoted, closed }

        var records: [Record] = []
        var fields: [Field] = []
        var issue: Issue?
        var columnCount = 0
        var nextCancellationCheck = 0
        var offset = 0
        var phase = Phase.initial
        var recordStart = 0
        private var fieldStart = 0
        private var recordFirstField = 0
        private var recordLine = 1
        private var line = 1
        private var lineStart = 0

        mutating func consume(_ unit: UInt16, length: Int, separator: UInt16) -> Bool {
            if unit == 0 { fail(.nul); return false }
            if unit == 10 || unit == 13 {
                if phase != .quoted, !finishRecord(endingLength: length) { return false }
                offset += length
                line += 1
                lineStart = offset
                return true
            }
            switch phase {
            case .quoted:
                if unit == 34 { phase = .closed }
            case .initial, .bare, .closed:
                if unit == separator {
                    guard finishField() else { return false }
                    fieldStart = offset + 1
                    phase = .initial
                } else if unit == 34 {
                    guard phase != .bare else { fail(.unexpectedQuote); return false }
                    phase = .quoted
                } else {
                    guard phase != .closed else { fail(.textAfterQuote); return false }
                    phase = .bare
                }
            }
            offset += length
            return true
        }

        private mutating func finishField() -> Bool {
            guard fields.count < 1_000_000 else { fail(.fieldLimit); return false }
            fields.append(Field(fieldStart, endingAt: offset))
            return true
        }

        mutating func finishRecord(endingLength: Int) -> Bool {
            guard finishField() else { return false }
            let end = offset + endingLength
            let indices = recordFirstField..<fields.count
            columnCount = max(columnCount, indices.count)
            if issue == nil, let first = records.first,
               first.fieldIndices.count != indices.count {
                issue = Issue(problem: .unevenColumns(expected: first.fieldIndices.count, actual: indices.count),
                              line: recordLine, column: 1)
            }
            records.append(Record(source: NSRange(location: recordStart, length: end - recordStart),
                                  physicalLine: recordLine, lineEndingLength: endingLength, fieldIndices: indices))
            recordStart = end
            fieldStart = end
            recordFirstField = fields.count
            recordLine = line + 1
            phase = .initial
            return true
        }

        mutating func fail(_ problem: Problem) {
            fields.removeLast(fields.count - recordFirstField)
            issue = Issue(problem: problem, line: line, column: offset - lineStart + 1)
        }
    }
}
