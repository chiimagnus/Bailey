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
        case fill(DelimitedTablePresentation.FieldScope, String)
        case replace(DelimitedTablePresentation.FieldScope, query: String, with: String,
                     single: DelimitedTablePresentation.Occurrence?)
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
        guard index.issue == nil, !index.hasAmbiguousSeparator else { throw Failure.invalidTable }
        try Task.checkCancellation()
        let text = source as NSString
        let replacements: [Replacement]
        var expectedColumns: Int?
        var fieldEdits: [Replacement] = []
        var addedUnits = 0
        func append(_ edit: Replacement?) throws {
            guard let edit else { return }
            addedUnits += edit.new.utf16.count
            guard addedUnits <= DelimitedTableIndex.maximumSourceUnits else { throw Failure.tooLarge }
            fieldEdits.append(edit)
        }
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
            for (row, record) in clipboard.records.enumerated() {
                try Task.checkCancellation()
                let physical = rows[origin.row + row]
                let fields = clipboard.fields(in: record)
                try append(editFields(record: physical, columns: IndexSet(integersIn: origin.column..<(origin.column + fields.count)),
                                      text: text, index: index) { column, _ in
                    fields[fields.startIndex + column - origin.column].value(in: clipboardSource)
                })
            }
            replacements = fieldEdits
        case .cells(let cells):
            for (row, changes) in Dictionary(grouping: cells, by: { $0.key.row }) {
                try Task.checkCancellation()
                guard changes.allSatisfy({ $0.key.column >= 0 }) else { throw Failure.invalidSelection }
                try append(editFields(record: row, columns: IndexSet(changes.map(\.key.column)), text: text, index: index) { column, _ in
                    cells[.init(row: row, column: column)]
                })
            }
            replacements = fieldEdits
        case .fill(let scope, let value):
            try scope.visit(in: index) { row, columns in
                try append(editFields(record: row, columns: columns, text: text, index: index) { _, _ in value })
            }
            replacements = fieldEdits
        case .replace(let scope, let query, let replacement, let single):
            guard !query.isEmpty else { return [] }
            if let single {
                guard scope.contains(single.cell, in: index) else { throw Failure.invalidSelection }
                try append(editFields(record: single.cell.row, columns: IndexSet(integer: single.cell.column),
                                      text: text, index: index) { _, value in
                    guard DelimitedTablePresentation.firstMatch(query, in: value as NSString, from: single.range.location) == single.range else {
                        throw Failure.invalidSelection
                    }
                    return (value as NSString).replacingCharacters(in: single.range, with: replacement)
                })
            } else {
                try scope.visit(in: index) { row, columns in
                    try append(editFields(record: row, columns: columns, text: text, index: index) { _, value in
                        try replaceMatches(query, in: value as NSString, with: replacement)
                    })
                }
            }
            replacements = fieldEdits
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
        let candidate: String
        if ordered.count == 1, let edit = ordered.first {
            candidate = text.replacingCharacters(in: edit.range, with: edit.new)
        } else {
            var assembled = ""
            assembled.reserveCapacity(length)
            var start = 0
            for edit in ordered.reversed() {
                try Task.checkCancellation()
                assembled.append(text.substring(with: NSRange(location: start, length: edit.range.location - start)))
                assembled.append(edit.new)
                start = NSMaxRange(edit.range)
            }
            assembled.append(text.substring(from: start))
            candidate = assembled
        }
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

    private static func editFields(
        record: Int, columns: IndexSet, text: NSString, index: DelimitedTableIndex,
        transform: (Int, String) throws -> String?
    ) throws -> Replacement? {
        guard index.records.indices.contains(record) else { throw Failure.invalidSelection }
        let fields = index.fields(in: index.records[record])
        var start: Int?
        var end = 0
        var body = ""
        var units = 0
        for column in columns {
            guard column < fields.count else { throw Failure.invalidSelection }
            let field = fields[fields.startIndex + column]
            let previous = field.value(in: text)
            guard let value = try transform(column, previous), !previous.utf16.elementsEqual(value.utf16) else { continue }
            guard !value.utf16.contains(0) else { throw Failure.invalidSelection }
            let range = field.source
            let emptyRecord = value.isEmpty && fields.count == 1 &&
                (NSMaxRange(range) == text.length || joinsLineEndings(removing: range, in: text))
            let quoted = emptyRecord || (range.length > 0 && text.character(at: range.location) == 34)
            let escaped = escape(value, separator: index.separator, quoted: quoted)
            let gap = start == nil ? 0 : range.location - end
            units += gap + escaped.utf16.count
            guard units <= DelimitedTableIndex.maximumSourceUnits else { throw Failure.tooLarge }
            if start == nil { start = range.location }
            if gap > 0 { body.append(text.substring(with: NSRange(location: end, length: gap))) }
            body.append(escaped)
            end = NSMaxRange(range)
        }
        guard let start else { return nil }
        let range = NSRange(location: start, length: end - start)
        return .init(range: range, old: text.substring(with: range), new: body)
    }

    private static func replaceMatches(_ query: String, in value: NSString, with replacement: String) throws -> String? {
        var result = ""
        var offset = 0
        var units = 0
        let replacementUnits = replacement.utf16.count
        while let match = DelimitedTablePresentation.firstMatch(query, in: value, from: offset) {
            try Task.checkCancellation()
            units += match.location - offset + replacementUnits
            guard units <= DelimitedTableIndex.maximumSourceUnits else { throw Failure.tooLarge }
            result.append(value.substring(with: NSRange(location: offset, length: match.location - offset)))
            result.append(replacement)
            offset = NSMaxRange(match)
        }
        guard offset > 0 else { return nil }
        guard units + value.length - offset <= DelimitedTableIndex.maximumSourceUnits else { throw Failure.tooLarge }
        result.append(value.substring(from: offset))
        return result
    }

    private static func joinsLineEndings(removing range: NSRange, in text: NSString) -> Bool {
        range.location > 0 && NSMaxRange(range) < text.length &&
            text.character(at: range.location - 1) == 13 && text.character(at: NSMaxRange(range)) == 10
    }

    static func escape(_ value: String, separator: DelimitedTableIndex.Separator, quoted: Bool) -> String {
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
