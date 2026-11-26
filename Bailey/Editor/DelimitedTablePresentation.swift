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

    struct Selection: Hashable, Sendable {
        struct Block: Hashable, Sendable {
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

        mutating func remapColumns(_ indexes: [Int: Int]) {
            func project(_ cell: Cell?) -> Cell? {
                guard let cell, let column = indexes[cell.column] else { return nil }
                return Cell(row: cell.row, column: column)
            }
            blocks = blocks.compactMap { block in
                let columns = IndexSet(block.columns.compactMap { indexes[$0] })
                return columns.isEmpty ? nil : Block(rows: block.rows, columns: columns)
            }
            caret = project(caret) ?? blocks.first.flatMap { block in
                block.rows.first.flatMap { row in block.columns.first.map { Cell(row: row, column: $0) } }
            }
            anchor = project(anchor) ?? caret
        }
    }

    struct FieldScope: Sendable {
        let rows: [Int]?
        let firstRecord: Int
        let columns: IndexSet
        let selection: Selection?

        func visit(in index: DelimitedTableIndex, _ visit: (Int, IndexSet) throws -> Void) throws {
            let count = rows?.count ?? max(0, index.records.count - firstRecord)
            let offsets = selection?.rows ?? IndexSet(integersIn: 0..<count)
            for offset in offsets {
                try Task.checkCancellation()
                guard (0..<count).contains(offset) else { continue }
                let record = rows?[offset] ?? firstRecord + offset
                let selected = selection.map { $0.columns(in: offset).intersection(columns) } ?? columns
                if !selected.isEmpty { try visit(record, selected) }
            }
        }

        func contains(_ cell: Cell, in index: DelimitedTableIndex) -> Bool {
            guard index.records.indices.contains(cell.row), columns.contains(cell.column) else { return false }
            let offset: Int
            if let rows {
                guard let displayed = rows.firstIndex(of: cell.row) else { return false }
                offset = displayed
            } else {
                guard cell.row >= firstRecord else { return false }
                offset = cell.row - firstRecord
            }
            return selection?.contains(Cell(row: offset, column: cell.column)) ?? true
        }
    }

    struct Occurrence: Sendable, Equatable {
        let cell: Cell
        let range: NSRange
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
                if Self.firstMatch(query, in: field.value(in: text) as NSString) != nil {
                    matches.append(Cell(row: row, column: column))
                }
            }
        }
        try Task.checkCancellation()
        return matches
    }

    static func firstMatch(_ query: String, in value: NSString, from offset: Int = 0) -> NSRange? {
        guard !query.isEmpty, (0..<value.length).contains(offset) else { return nil }
        let found = value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                range: NSRange(location: offset, length: value.length - offset))
        return found.location == NSNotFound || found.length == 0 ? nil : found
    }

    @concurrent static func countOccurrences(
        _ query: String, in scope: FieldScope, source: String, index: DelimitedTableIndex
    ) async throws -> Int {
        guard !query.isEmpty else { return 0 }
        let source = source as NSString
        var count = 0
        try scope.visit(in: index) { row, columns in
            for column in columns {
                guard let field = index.field(record: row, column: column) else { continue }
                let value = field.value(in: source) as NSString
                var offset = 0
                while let match = firstMatch(query, in: value, from: offset) {
                    if count.isMultiple(of: 1024) { try Task.checkCancellation() }
                    count += 1
                    offset = NSMaxRange(match)
                }
            }
        }
        return count
    }

    @concurrent func nextVisibleOccurrence(
        _ query: String, from matches: [Cell], at caret: Cell?, after previous: Occurrence?,
        selection: Selection?, source: String, index: DelimitedTableIndex
    ) async throws -> Occurrence? {
        guard !matches.isEmpty else { return nil }
        let text = source as NSString
        let previousDisplay = previous.flatMap { occurrence in
            rows.firstIndex(of: occurrence.cell.row).map { Cell(row: $0, column: occurrence.cell.column) }
        }
        let continuation = caret == nil || caret == previousDisplay ? previous : nil
        let starting = (caret ?? previousDisplay).flatMap { cell in
            matches.firstIndex { $0.row > cell.row || $0.row == cell.row && $0.column >= cell.column }
        } ?? 0
        for step in 0..<matches.count {
            try Task.checkCancellation()
            let visible = matches[(starting + step) % matches.count]
            guard rows.indices.contains(visible.row), selection?.contains(visible) != false else { continue }
            let actual = Cell(row: rows[visible.row], column: visible.column)
            guard let field = index.field(record: actual.row, column: actual.column) else { continue }
            let offset = continuation.flatMap { $0.cell == actual ? NSMaxRange($0.range) : nil } ?? 0
            if let match = Self.firstMatch(query, in: field.value(in: text) as NSString, from: offset) {
                return Occurrence(cell: actual, range: match)
            }
        }
        return nil
    }

    @concurrent func copy(
        _ selection: Selection, source: String, index: DelimitedTableIndex
    ) async throws -> String? {
        let selectedRows = selection.rows
        let selectedColumns = selection.columns
        guard !selectedRows.isEmpty, !selectedColumns.isEmpty,
              let finalRow = selectedRows.last, rows.indices.contains(finalRow),
              selectedRows.count <= DelimitedTableIndex.maximumFields / selectedColumns.count else { return nil }
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
                let encoded = DelimitedTableMutation.escape(value, separator: .tab, quoted: emptyFinalRecord)
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
