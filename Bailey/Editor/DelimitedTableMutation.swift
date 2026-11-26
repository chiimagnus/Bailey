import Foundation

/// A prepared mutation contains only source intervals and their old/new text.
/// The grid is a presentation of the existing document, never a writable copy.
nonisolated enum DelimitedTableMutation {
    enum Change: Sendable {
        case cells([DelimitedTablePresentation.Cell: String])
        case paste(String, rows: [Int], origin: DelimitedTablePresentation.Cell, columns: Int)
        case insertRows(before: Int, count: Int)
        case deleteRows(Set<Int>)
        case columns([Int?])
    }

    struct Replacement: Sendable {
        let range: NSRange
        let old: String
        let new: String
    }

    enum Failure: Error, Sendable {
        case invalidTable
        case invalidSelection
        case cannotEncode
        case tooLarge
    }

    @concurrent static func prepare(
        _ change: Change, source: String, index: DelimitedTableIndex,
        encoding: TextFileEncoding
    ) async throws -> [Replacement] {
        guard index.issue == nil, !index.needsSeparatorChoice else { throw Failure.invalidTable }
        try Task.checkCancellation()
        let text = source as NSString
        let replacements: [Replacement]
        var expectedColumns: Int?
        switch change {
        case .paste(let clipboardText, let rows, let origin, let columns):
            // Freeze physical row order when the user invokes Paste, rather
            // than consulting a possibly unmounted or resorted table later.
            let clipboard = try await DelimitedTableIndex.parse(clipboardText, preferred: .tab, selected: .tab)
            guard clipboard.issue == nil, !clipboard.records.isEmpty,
                  rows.indices.contains(origin.row), (0..<columns).contains(origin.column),
                  clipboard.records.count <= rows.count - origin.row,
                  clipboard.columnCount <= columns - origin.column else { throw Failure.invalidSelection }
            let clipboardSource = clipboardText as NSString
            var changes: [DelimitedTablePresentation.Cell: String] = [:]
            for (row, record) in clipboard.records.enumerated() {
                try Task.checkCancellation()
                let physical = rows[origin.row + row]
                for (column, field) in clipboard.fields(in: record).enumerated() {
                    changes[.init(row: physical, column: origin.column + column)] = field.value(in: clipboardSource)
                }
            }
            return try await prepare(.cells(changes), source: source, index: index, encoding: encoding)
        case .cells(let cells):
            var edits: [Replacement] = []
            for (cell, value) in cells {
                try Task.checkCancellation()
                guard index.records.indices.contains(cell.row), !value.utf16.contains(0) else {
                    throw Failure.invalidSelection
                }
                let fields = index.fields(in: index.records[cell.row])
                guard (0..<fields.count).contains(cell.column) else { throw Failure.invalidSelection }
                let field = fields[fields.startIndex + cell.column]
                if field.value(in: text).utf16.elementsEqual(value.utf16) { continue }
                let old = text.substring(with: field.source)
                // A bare empty row at EOF disappears; between CR and LF it merges two records.
                let emptyRecord = value.isEmpty && fields.count == 1 &&
                    (NSMaxRange(field.source) == text.length || joinsLineEndings(removing: field.source, in: text))
                let quoted = old.utf16.first == 34 || emptyRecord
                let replacement = escape(value, separator: index.separator, quoted: quoted)
                edits.append(.init(range: field.source, old: old, new: replacement))
            }
            replacements = edits
        case .insertRows(let before, let count):
            let columns = max(1, index.columnCount)
            guard (0...index.records.count).contains(before), count > 0,
                  count <= DelimitedTableIndex.maximumFields / columns,
                  index.records.count <= DelimitedTableIndex.maximumFields / columns - count else {
                throw Failure.invalidSelection
            }
            let separator = String(UnicodeScalar(index.separator.rawValue)!)
            // An empty single-column record at EOF needs explicit quotes.
            let row = columns == 1 ? "\"\"" : String(repeating: separator, count: columns - 1)
            let ending = lineEnding(near: before, text: text, index: index)
            let position = before < index.records.count ? index.records[before].source.location : text.length
            let appending = before == index.records.count
            let unterminated = appending && index.records.last?.lineEndingLength == 0
            let body = Array(repeating: row, count: count).joined(separator: ending)
            let value = (unterminated ? ending : "") + body + (unterminated ? "" : ending)
            replacements = [.init(range: NSRange(location: position, length: 0), old: "", new: value)]
        case .deleteRows(let rows):
            guard rows.allSatisfy(index.records.indices.contains) else { throw Failure.invalidSelection }
            replacements = IndexSet(rows).rangeView.map { run in
                let first = index.records[run.lowerBound].source
                let last = index.records[run.upperBound - 1].source
                let range = NSUnionRange(first, last)
                // Keep a surviving empty LF record distinct from a preceding CR record.
                let boundary = joinsLineEndings(removing: range, in: text) ? "\"\"" : ""
                return .init(range: range, old: text.substring(with: range), new: boundary)
            }
        case .columns(let order):
            let oldCount = index.columnCount
            let existing = order.compactMap { $0 }
            let allowed = 1...DelimitedTableIndex.maximumColumns
            guard !index.records.isEmpty, allowed.contains(oldCount), allowed.contains(order.count),
                  existing.allSatisfy((0..<oldCount).contains), Set(existing).count == existing.count,
                  index.records.count <= DelimitedTableIndex.maximumFields / order.count else { throw Failure.invalidSelection }
            expectedColumns = order.count
            let current = (0..<oldCount).map(Optional.some)
            let common = zip(current, order).prefix { $0.0 == $0.1 }.count
            if common == oldCount, common == order.count { return [] }
            let suffix = zip(current.dropFirst(common).reversed(), order.dropFirst(common).reversed())
                .prefix { $0.0 == $0.1 }.count
            let delimiter = String(UnicodeScalar(index.separator.rawValue)!)
            var edits: [Replacement] = []
            for record in index.records {
                try Task.checkCancellation()
                let fields = index.fields(in: record)
                guard fields.count == oldCount, let first = fields.first, let last = fields.last else {
                    throw Failure.invalidTable
                }
                let body = NSUnionRange(first.source, last.source)
                if order.count == 1, order[0].map({ fields[fields.startIndex + $0].source.length == 0 }) ?? true,
                   NSMaxRange(body) == text.length || joinsLineEndings(removing: body, in: text) {
                    edits.append(.init(range: body, old: text.substring(with: body), new: "\"\""))
                    continue
                }
                let start = common == 0 ? body.location : NSMaxRange(fields[fields.startIndex + common - 1].source)
                let end = suffix == 0 ? NSMaxRange(body) : fields[fields.endIndex - suffix].source.location
                let changed = order[common..<(order.count - suffix)]
                var value = changed.map { column in
                    column.map { text.substring(with: fields[fields.startIndex + $0].source) } ?? ""
                }.joined(separator: delimiter)
                if common > 0, !changed.isEmpty || suffix > 0 { value = delimiter + value }
                if suffix > 0, !changed.isEmpty { value += delimiter }
                let range = NSRange(location: start, length: end - start)
                let old = text.substring(with: range)
                if !old.utf16.elementsEqual(value.utf16) { edits.append(.init(range: range, old: old, new: value)) }
            }
            replacements = edits
        }

        let ordered = replacements.sorted { $0.range.location > $1.range.location }
        guard !ordered.isEmpty else { return [] }
        let length = ordered.reduce(text.length) { $0 + $1.new.utf16.count - $1.range.length }
        guard length <= DelimitedTableIndex.maximumSourceUnits else { throw Failure.tooLarge }
        // Validate the actual candidate encoding before the atomic storage edit.
        // This runs off the main actor and never serializes the grid or changes
        // any untouched field, record order, quote spelling or line ending.
        var candidate = ""
        candidate.reserveCapacity(length)
        var start = 0
        for edit in ordered.reversed() {
            try Task.checkCancellation()
            candidate.append(text.substring(with: NSRange(location: start, length: edit.range.location - start)))
            candidate.append(edit.new)
            start = NSMaxRange(edit.range)
        }
        candidate.append(text.substring(from: start))
        if let expectedColumns {
            let checked = try await DelimitedTableIndex.parse(candidate, preferred: index.separator, selected: index.separator)
            guard checked.issue == nil, checked.records.count == index.records.count,
                  checked.columnCount == expectedColumns else { throw Failure.invalidTable }
        }
        guard let bytes = encoding.encoded(candidate) else { throw Failure.cannotEncode }
        guard bytes.count <= FileTab.maxTextBytes else { throw Failure.tooLarge }
        try Task.checkCancellation()
        return ordered
    }

    private static func joinsLineEndings(removing range: NSRange, in text: NSString) -> Bool {
        range.location > 0 && NSMaxRange(range) < text.length &&
            text.character(at: range.location - 1) == 13 && text.character(at: NSMaxRange(range)) == 10
    }

    private static func escape(_ value: String, separator: DelimitedTableIndex.Separator, quoted: Bool) -> String {
        let needsQuotes = quoted || value.utf16.contains { $0 == 34 || $0 == 13 || $0 == 10 || $0 == separator.rawValue }
        return needsQuotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\"" : value
    }

    private static func lineEnding(near row: Int, text: NSString, index: DelimitedTableIndex) -> String {
        if let record = row < index.records.count && index.records[row].lineEndingLength > 0
            ? index.records[row] : index.records.prefix(row).last(where: { $0.lineEndingLength > 0 }) {
            return text.substring(with: NSRange(location: NSMaxRange(record.source) - record.lineEndingLength,
                                                length: record.lineEndingLength))
        }
        if let record = index.records.dropFirst(row).first(where: { $0.lineEndingLength > 0 }) {
            return text.substring(with: NSRange(location: NSMaxRange(record.source) - record.lineEndingLength,
                                                length: record.lineEndingLength))
        }
        return "\n"
    }
}
