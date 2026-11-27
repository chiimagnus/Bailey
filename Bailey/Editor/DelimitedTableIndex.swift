import Foundation

nonisolated struct DelimitedTableIndex: Sendable {
    static let maximumColumns = 4096
    static let maximumFields = 1_000_000
    static let maximumSourceUnits = 32 << 20
    static let displayLimit = 4096

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

        func contentRange(in text: NSString) -> NSRange {
            let range = source
            return range.length >= 2 && text.character(at: range.location) == 34
                ? NSRange(location: range.location + 1, length: range.length - 2) : range
        }

        func value(in text: NSString, limit: Int? = nil) -> String {
            var range = contentRange(in: text)
            let quoted = range.location != Int(start)
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
        let displayLineCount: Int
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
    let hasAmbiguousSeparator: Bool
    let records: [Record]
    let columnCount: Int
    let issue: Issue?
    private let fields: [Field]

    func fields(in record: Record) -> ArraySlice<Field> { fields[record.fieldIndices] }

    func field(record: Int, column: Int) -> Field? {
        guard records.indices.contains(record), column >= 0 else { return nil }
        let fields = fields(in: records[record])
        return column < fields.count ? fields[fields.startIndex + column] : nil
    }

    @concurrent static func parse(
        _ text: String, preferred: Separator, selected: Separator? = nil
    ) async throws -> Self {
        try Task.checkCancellation()
        let units = text.utf16
        let sampleLimit = 16_384
        var separator = selected ?? preferred
        var hasAmbiguousSeparator = false
        if selected == nil {
            let hasMore = units.prefix(sampleLimit + 1).count > sampleLimit
            var candidates: [Separator] = []
            var consistent: [Separator] = []
            for candidate in Separator.allCases {
                let scanned = try scan(units, separator: candidate, sampleLimit: sampleLimit)
                guard scanned.records.contains(where: { $0.fieldCount > 1 }) else { continue }
                candidates.append(candidate)
                if scanned.issue == nil { consistent.append(candidate) }
            }
            if !consistent.isEmpty { candidates = consistent }
            if candidates.count == 1, let detected = candidates.first { separator = detected }
            hasAmbiguousSeparator = candidates.count > 1 || (candidates.isEmpty && hasMore)
            if hasAmbiguousSeparator, !candidates.contains(separator), let candidate = candidates.first {
                separator = candidate
            }
        }
        let scanned = try scan(units, separator: separator)
        return Self(separator: separator, hasAmbiguousSeparator: hasAmbiguousSeparator,
                    records: scanned.records, columnCount: scanned.columnCount,
                    issue: scanned.issue, fields: scanned.fields)
    }

    private static func scan<Units: Sequence>(
        _ units: Units, separator: Separator, sampleLimit: Int? = nil
    ) throws -> Scanner where Units.Element == UInt16 {
        var iterator = units.makeIterator()
        var current = iterator.next()
        var scanner = Scanner()
        while let unit = current {
            // A character budget must not prevent complete logical records from establishing the delimiter.
            if let sampleLimit, scanner.offset >= sampleLimit, scanner.records.count >= 2 { break }
            current = iterator.next()
            let length = unit == 13 && current == 10 ? 2 : 1
            if length == 2 { current = iterator.next() }
            if scanner.offset >= scanner.nextCancellationCheck {
                try Task.checkCancellation()
                scanner.nextCancellationCheck = scanner.offset + 65_536
            }
            guard scanner.offset <= maximumSourceUnits - length else {
                scanner.fail(.sourceLimit)
                return scanner
            }
            guard scanner.consume(unit, length: length, separator: separator.rawValue) else { return scanner }
        }
        try Task.checkCancellation()
        guard current == nil else { return scanner }
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
        private var fieldDisplayLines = 1
        private var recordDisplayLines = 1

        mutating func consume(_ unit: UInt16, length: Int, separator: UInt16) -> Bool {
            if unit == 0 { fail(.nul); return false }
            // Count visible explicit line breaks while scanning; CRLF is one unit here.
            if unit == 10 || unit == 13 {
                if phase == .quoted, offset - fieldStart <= displayLimit { fieldDisplayLines += 1 }
                if phase != .quoted, !finishRecord(endingLength: length) { return false }
                offset += length
                line += 1
                lineStart = offset
                return true
            }
            switch unit {
            case 11, 12, 133, 0x2028, 0x2029:
                if offset - fieldStart < displayLimit + (phase == .quoted ? 1 : 0) { fieldDisplayLines += 1 }
            default: break
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
            guard fields.count < maximumFields else { fail(.fieldLimit); return false }
            if fields.count - recordFirstField < maximumColumns {
                recordDisplayLines = max(recordDisplayLines, fieldDisplayLines)
            }
            fields.append(Field(fieldStart, endingAt: offset))
            fieldDisplayLines = 1
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
                                  physicalLine: recordLine, lineEndingLength: endingLength,
                                  displayLineCount: recordDisplayLines, fieldIndices: indices))
            recordDisplayLines = 1
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
