import Foundation

nonisolated struct DelimitedTablePresentation: Sendable {
    struct Sort: Hashable, Sendable {
        let column: Int
        let ascending: Bool
    }

    struct Configuration: Hashable, Sendable {
        var header = true
        var filters: [Int: String] = [:]
        var sort: [Sort] = []

        func restricted(to columnCount: Int) -> Self {
            Self(header: header,
                 filters: filters.filter { (0..<columnCount).contains($0.key) },
                 sort: sort.filter { (0..<columnCount).contains($0.column) })
        }
    }

    struct Cell: Hashable, Sendable {
        let row: Int
        let column: Int
    }

    struct Selection: Sendable {
        struct Block: Sendable {
            var rows: IndexSet
            var columns: IndexSet

            func contains(_ cell: Cell) -> Bool { rows.contains(cell.row) && columns.contains(cell.column) }
        }

        private(set) var blocks: [Block] = []
        private(set) var anchor: Cell?
        private(set) var caret: Cell?

        mutating func select(_ cell: Cell, extending: Bool = false, adding: Bool = false,
                             rows: Range<Int>? = nil, columns: Range<Int>? = nil) {
            let origin = extending ? anchor ?? cell : cell
            if extending, !blocks.isEmpty { blocks.removeLast() }
            else if !adding { blocks.removeAll(keepingCapacity: true) }
            blocks.append(Block(rows: IndexSet(integersIn: rows ?? min(origin.row, cell.row)..<(max(origin.row, cell.row) + 1)),
                                columns: IndexSet(integersIn: columns ?? min(origin.column, cell.column)..<(max(origin.column, cell.column) + 1))))
            anchor = origin
            caret = cell
        }

        func contains(_ cell: Cell) -> Bool { blocks.contains { $0.contains(cell) } }

        var rows: IndexSet {
            blocks.reduce(into: IndexSet()) { $0.formUnion($1.rows) }
        }

        var columns: IndexSet {
            blocks.reduce(into: IndexSet()) { $0.formUnion($1.columns) }
        }

        func columns(in row: Int) -> IndexSet {
            blocks.reduce(into: IndexSet()) { columns, block in
                if block.rows.contains(row) { columns.formUnion(block.columns) }
            }
        }

        mutating func remapRows(from previous: [Int], to current: [Int]) {
            guard !blocks.isEmpty else { return }
            let positions = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($0.element, $0.offset) })
            func project(_ cell: Cell?) -> Cell? {
                guard let cell, previous.indices.contains(cell.row), let row = positions[previous[cell.row]] else { return nil }
                return Cell(row: row, column: cell.column)
            }
            blocks = blocks.compactMap { block in
                var rows = IndexSet()
                for row in block.rows where previous.indices.contains(row) {
                    if let next = positions[previous[row]] { rows.insert(next) }
                }
                return rows.isEmpty ? nil : Block(rows: rows, columns: block.columns)
            }
            let first = blocks.first.flatMap { block in
                block.rows.first.flatMap { row in block.columns.first.map { Cell(row: row, column: $0) } }
            }
            caret = project(caret) ?? first
            anchor = project(anchor) ?? caret
        }
    }

    let id = UUID()
    let configuration: Configuration
    var header: Bool { configuration.header }
    let rows: [Int]

    @concurrent static func evaluate(
        source: String, index: DelimitedTableIndex, configuration requested: Configuration
    ) async throws -> Self {
        let configuration = requested.restricted(to: index.columnCount)
        let text = source as NSString
        let start = configuration.header && !index.records.isEmpty ? 1 : 0
        var rows: [Int] = []
        rows.reserveCapacity(index.records.count - start)
        for row in start..<index.records.count {
            if row.isMultiple(of: 1024) { try Task.checkCancellation() }
            if configuration.filters.allSatisfy({ column, query in
                query.isEmpty || value(in: text, index: index, record: row, column: column)
                    .range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }) {
                rows.append(row)
            }
        }
        if !configuration.sort.isEmpty {
            var decorated: [(row: Int, keys: [String])] = []
            decorated.reserveCapacity(rows.count)
            for (offset, row) in rows.enumerated() {
                if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
                decorated.append((row, configuration.sort.map {
                    value(in: text, index: index, record: row, column: $0.column)
                }))
            }
            var comparisons = 0
            try decorated.sort { left, right in
                comparisons += 1
                if comparisons.isMultiple(of: 16_384) { try Task.checkCancellation() }
                for (offset, sort) in configuration.sort.enumerated() {
                    let result = left.keys[offset].localizedStandardCompare(right.keys[offset])
                    if result != .orderedSame { return result == (sort.ascending ? .orderedAscending : .orderedDescending) }
                }
                return left.row < right.row
            }
            rows = decorated.map(\.row)
        }
        try Task.checkCancellation()
        return Self(configuration: requested, rows: rows)
    }

    @concurrent func find(
        _ query: String, source: String, index: DelimitedTableIndex, columnCount: Int
    ) async throws -> [Cell] {
        guard !query.isEmpty else { return [] }
        let text = source as NSString
        var matches: [Cell] = []
        for (row, original) in rows.enumerated() {
            if row.isMultiple(of: 256) { try Task.checkCancellation() }
            let fields = index.fields(in: index.records[original])
            for (column, field) in fields.prefix(columnCount).enumerated() {
                if field.value(in: text).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    matches.append(Cell(row: row, column: column))
                }
            }
        }
        try Task.checkCancellation()
        return matches
    }

    @concurrent func copy(
        _ selection: Selection, source: String, index: DelimitedTableIndex
    ) async throws -> String? {
        let selectedRows = selection.rows
        let selectedColumns = selection.columns
        guard !selectedRows.isEmpty, !selectedColumns.isEmpty,
              let finalRow = selectedRows.last, rows.indices.contains(finalRow),
              selectedRows.count <= 1_000_000 / selectedColumns.count else { return nil }
        let text = source as NSString
        var output = ""
        var size = 0
        for row in selectedRows {
            try Task.checkCancellation()
            let columns = selection.columns(in: row)
            for column in selectedColumns {
                if column != selectedColumns.first { output.append("\t"); size += 1 }
                guard columns.contains(column) else { continue }
                let value = Self.value(in: text, index: index, record: rows[row], column: column)
                let emptyFinalRecord = value.isEmpty && row == finalRow && selectedColumns.count == 1
                let encoded = emptyFinalRecord || value.utf8.contains(where: { $0 == 9 || $0 == 10 || $0 == 13 || $0 == 34 })
                    ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\"" : value
                size += encoded.utf8.count
                guard size <= 64 << 20 else { return nil }
                output.append(encoded)
            }
            if row != selectedRows.last { output.append("\n"); size += 1 }
            guard size <= 64 << 20 else { return nil }
        }
        return output
    }

    static func value(
        in text: NSString, index: DelimitedTableIndex, record: Int, column: Int, limit: Int? = nil
    ) -> String {
        index.field(record: record, column: column)?.value(in: text, limit: limit) ?? ""
    }

    static func finiteNumber(_ value: String) -> Double? {
        var nonzeroMantissa = false
        var inExponent = false
        for byte in value.utf8 {
            switch byte {
            case 69, 101: inExponent = true
            case 49...57: nonzeroMantissa = nonzeroMantissa || !inExponent
            case 43, 45, 46, 48: break
            default: return nil
            }
        }
        guard let result = Double(value), result.isFinite, result != 0 || !nonzeroMantissa else { return nil }
        return result
    }
}
