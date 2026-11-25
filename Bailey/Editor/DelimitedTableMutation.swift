import Foundation

/// A prepared mutation contains only source intervals and their old/new text.
/// The grid is a presentation of the existing document, never a writable copy.
nonisolated enum DelimitedTableMutation {
    enum Change: Sendable {
        case cells([DelimitedTablePresentation.Cell: String])
        case paste(String, rows: [Int], origin: DelimitedTablePresentation.Cell, columns: Int)
        case insertRows(before: Int, count: Int)
        case deleteRows(Set<Int>)
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
                let quoted = old.utf16.first == 34
                let replacement = escape(value, separator: index.separator, quoted: quoted)
                edits.append(.init(range: field.source, old: old, new: replacement))
            }
            replacements = edits
        case .insertRows(let before, let count):
            let columns = max(1, index.columnCount)
            guard (0...index.records.count).contains(before), count > 0,
                  count <= 1_000_000 / columns,
                  index.records.count <= 1_000_000 / columns - count else { throw Failure.invalidSelection }
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
            replacements = rows.map { row in
                let range = index.records[row].source
                return .init(range: range, old: text.substring(with: range), new: "")
            }
        }

        let ordered = replacements.sorted { $0.range.location > $1.range.location }
        guard !ordered.isEmpty else { return [] }
        let length = ordered.reduce(text.length) { $0 + $1.new.utf16.count - $1.range.length }
        guard length <= FileTab.maxTextBytes else { throw Failure.tooLarge }
        // Validate the actual candidate encoding before the atomic storage edit.
        // This runs off the main actor and never serializes the grid or changes
        // any untouched field, record order, quote spelling or line ending.
        let candidate = NSMutableString(string: source)
        for edit in ordered {
            try Task.checkCancellation()
            candidate.replaceCharacters(in: edit.range, with: edit.new)
        }
        guard let bytes = encoding.encoded(candidate as String) else { throw Failure.cannotEncode }
        guard bytes.count <= FileTab.maxTextBytes else { throw Failure.tooLarge }
        try Task.checkCancellation()
        return ordered
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
