import AppKit
import Observation
import SwiftUI

@Observable
final class DelimitedTableControls {
    var separator: DelimitedTableIndex.Separator?
    var configuration = DelimitedTablePresentation.Configuration()
    var query = ""
    var showsFind = false
    var findFocus = 0
    var findStep = 0
    @ObservationIgnored var selectedValue = ""

    func perform(_ action: FindAction) {
        switch action {
        case .show:
            showsFind = true
            findFocus &+= 1
        case .hide: showsFind = false
        case .next: findStep &+= 1
        case .previous: findStep &-= 1
        case .useSelection:
            if !selectedValue.isEmpty { query = selectedValue }
        case .replace: break
        }
    }
}

struct CSVTableView: View {
    private struct ParseRequest: Hashable {
        let source: String
        let separator: DelimitedTableIndex.Separator?
    }

    private struct DisplayRequest: Hashable {
        let parse: ParseRequest
        let configuration: DelimitedTablePresentation.Configuration
    }

    private struct SearchRequest: Hashable {
        let display: UUID
        let query: String
    }

    private enum Input: Hashable { case find, filter }

    let file: FileTab
    let canFocus: () -> Bool
    let onFocused: () -> Void
    let onShowSource: () -> Void
    @State private var parsed: (ParseRequest, FileTab.DelimitedSnapshot)?
    @State private var displayed: (ParseRequest, DelimitedTablePresentation)?
    @State private var search: (SearchRequest, [DelimitedTablePresentation.Cell])?
    @State private var failed: ParseRequest?
    @State private var filterColumn: Int?
    @State private var filterDraft = ""
    @FocusState private var focusedInput: Input?

    private var controls: DelimitedTableControls { file.delimitedTable }

    var body: some View {
        let parse = ParseRequest(source: file.textPreviewRequestID, separator: controls.separator)
        let display = DisplayRequest(parse: parse, configuration: controls.configuration)
        let active = displayed.flatMap { $0.0 == parse ? $0.1 : nil }
        let query = active.map { SearchRequest(display: $0.id, query: controls.query) }
        let matches = search.flatMap { $0.0 == query ? $0.1 : nil } ?? []
        surface(parse, active: active, matches: matches)
            .overlay(alignment: .topTrailing) { overlay(matches: matches.count) }
            .task(id: parse) {
                do {
                    guard let result = try await file.delimitedSnapshot(using: parse.separator),
                          !Task.isCancelled, parse.source == file.textPreviewRequestID else { return }
                    parsed = (parse, result)
                } catch is CancellationError {
                    return
                } catch {
                    failed = parse
                }
            }
            .task(id: parsed?.0 == parse ? display : nil) {
                guard let parsed, parsed.0 == parse else { return }
                do {
                    let result = try await DelimitedTablePresentation.evaluate(
                        source: parsed.1.source, index: parsed.1.index, configuration: display.configuration
                    )
                    guard !Task.isCancelled, parse.source == file.textPreviewRequestID else { return }
                    displayed = (parse, result)
                } catch is CancellationError {
                    return
                } catch {
                    failed = parse
                }
            }
            .task(id: query) {
                guard let query, let active, let parsed, parsed.0 == parse else { return }
                do {
                    let found = try await active.find(
                        query.query, source: parsed.1.source, index: parsed.1.index,
                        columnCount: DelimitedGrid.maximumColumns
                    )
                    guard !Task.isCancelled, parse.source == file.textPreviewRequestID else { return }
                    search = (query, found)
                } catch {}
            }
            .onChange(of: controls.findFocus) {
                filterColumn = nil
                focus(.find)
            }
    }

    @ViewBuilder
    private func surface(
        _ request: ParseRequest, active: DelimitedTablePresentation?, matches: [DelimitedTablePresentation.Cell]
    ) -> some View {
        VStack(spacing: 0) {
            if let parsed, parsed.0 == request, let active {
                let snapshot = parsed.1
                if let issue = snapshot.index.issue {
                    notice(String(localized: "Table issue at line \(issue.line), column \(issue.column).", table: "Editor"))
                } else if snapshot.index.columnCount > DelimitedGrid.maximumColumns {
                    notice(String(localized: "This table has too many columns to display.", table: "Editor"))
                } else if snapshot.index.needsSeparatorChoice {
                    notice(String(localized: "Choose the table delimiter.", table: "Editor"))
                }
                if snapshot.index.records.isEmpty {
                    Spacer()
                    Text("No table rows to display.", tableName: "Editor").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    NativeDelimitedGrid(
                        snapshot: snapshot, presentation: active, controls: controls,
                        findStep: controls.findStep, matches: matches, onFocused: onFocused,
                        onFilter: { column in
                            filterDraft = controls.configuration.filters[column] ?? ""
                            filterColumn = column
                        }
                    )
                }
            } else if failed == request {
                notice(String(localized: "Could not display the table.", table: "Editor"))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func notice(_ message: String) -> some View {
        HStack {
            Text(message)
            Spacer()
            Menu(String(localized: "Delimiter", table: "Editor")) {
                ForEach(DelimitedTableIndex.Separator.allCases, id: \.self) { separator in
                    Button(separator.title) { controls.separator = separator }
                }
            }.fixedSize()
            Button(FilePreviewMode.source.title, action: onShowSource).buttonStyle(.link)
        }
        .padding(8)
    }

    @ViewBuilder
    private func overlay(matches: Int) -> some View {
        if let column = filterColumn {
            HStack {
                TextField(String(localized: "Filter Column", table: "Editor"), text: $filterDraft)
                    .accessibilityIdentifier("bailey.csv.filter")
                    .focused($focusedInput, equals: .filter)
                    .onSubmit { applyFilter(column) }
                Button(String(localized: "Apply Filter", table: "Editor")) { applyFilter(column) }
                Button { filterColumn = nil } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
            .onKeyPress(.escape) { filterColumn = nil; return .handled }
            .padding(6).frame(maxWidth: 350)
            .background(.regularMaterial, in: .rect(cornerRadius: 8)).padding(8)
            .onAppear { focus(.filter) }
        } else if controls.showsFind {
            @Bindable var controls = controls
            HStack(spacing: 6) {
                TextField(String(localized: "Find", table: "Terminal"), text: $controls.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("bailey.csv.find")
                    .focused($focusedInput, equals: .find)
                    .onSubmit { controls.perform(.next) }
                Text(verbatim: "\(matches)").monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityIdentifier("bailey.csv.match-count")
                Button { controls.perform(.previous) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel(Text("Previous Match", tableName: "Terminal"))
                Button { controls.perform(.next) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel(Text("Next Match", tableName: "Terminal"))
                Button { controls.perform(.hide) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
            .buttonStyle(.borderless)
            .padding(6).frame(maxWidth: 320)
            .background(.regularMaterial, in: .rect(cornerRadius: 8)).padding(8)
            .onKeyPress(.escape) { controls.perform(.hide); return .handled }
            .onAppear { focus(.find) }
        }
    }

    private func applyFilter(_ column: Int) {
        controls.configuration.filters[column] = filterDraft.isEmpty ? nil : filterDraft
        filterColumn = nil
    }

    private func focus(_ input: Input) {
        DispatchQueue.main.async {
            guard canFocus(),
                  input == .filter ? filterColumn != nil : controls.showsFind && filterColumn == nil else { return }
            focusedInput = input
        }
    }
}

private extension DelimitedTableIndex.Separator {
    var title: String {
        switch self {
        case .comma: String(localized: "Comma", table: "Editor")
        case .semicolon: String(localized: "Semicolon", table: "Editor")
        case .tab: String(localized: "Tab", table: "Editor")
        }
    }
}

private struct NativeDelimitedGrid: NSViewRepresentable {
    let snapshot: FileTab.DelimitedSnapshot
    let presentation: DelimitedTablePresentation
    let controls: DelimitedTableControls
    let findStep: Int
    let matches: [DelimitedTablePresentation.Cell]
    let onFocused: () -> Void
    let onFilter: (Int) -> Void

    func makeNSView(context: Context) -> DelimitedGrid { DelimitedGrid() }

    func updateNSView(_ grid: DelimitedGrid, context: Context) {
        grid.controls = controls
        grid.table.onFocused = onFocused
        grid.onFilter = onFilter
        grid.install(snapshot, presentation: presentation)
        grid.showMatch(matches, step: findStep)
    }

    static func dismantleNSView(_ grid: DelimitedGrid, coordinator: ()) { grid.detach() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DelimitedGrid, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

final class DelimitedGrid: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    static let maximumColumns = 4096
    let table = DelimitedNativeTable()
    var controls: DelimitedTableControls?
    var onFilter: (Int) -> Void = { _ in }
    private var snapshot: FileTab.DelimitedSnapshot?
    private var presentation: DelimitedTablePresentation?
    private var source: NSString = ""
    private var copyTask: Task<Void, Never>?
    private var previousMatches: [DelimitedTablePresentation.Cell] = []
    private var previousStep = 0
    private var matchIndex = 0

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        let header = DelimitedHeader()
        header.onMenu = { [weak self] column in self?.columnMenu(column) }
        table.headerView = header
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = true
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("bailey.csv.table")
        table.onCopy = { [weak self] in self?.copySelection() }
        table.onSelection = { [weak self] cell in
            guard let self else { return }
            controls?.selectedValue = cell.map { value($0, limit: 4096) } ?? ""
        }
        documentView = table
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func detach() {
        copyTask?.cancel()
        copyTask = nil
        snapshot = nil
        presentation = nil
        source = ""
        controls = nil
        table.onFocused = {}
        onFilter = { _ in }
        table.reloadData()
    }

    func install(_ snapshot: FileTab.DelimitedSnapshot, presentation: DelimitedTablePresentation) {
        guard presentation.id != self.presentation?.id else { return }
        let oldHeader = self.presentation?.header
        let rebuildColumns = self.snapshot?.requestID != snapshot.requestID ||
            self.snapshot?.index.separator != snapshot.index.separator || oldHeader != presentation.header
        self.snapshot = snapshot
        source = snapshot.source as NSString
        if rebuildColumns {
            self.presentation = nil
            table.reloadData()
            installColumns(index: snapshot.index, header: presentation.header)
        }
        self.presentation = presentation
        table.clearSelection()
        previousMatches = []
        table.reloadData()
    }

    private func installColumns(index: DelimitedTableIndex, header: Bool) {
        let count = min(index.columnCount, Self.maximumColumns)
        let columns = table.tableColumns
        for column in columns.dropFirst(count) { table.removeTableColumn(column) }
        for columnIndex in 0..<count {
            let column: NSTableColumn
            if columnIndex < columns.count {
                column = columns[columnIndex]
            } else {
                column = NSTableColumn(identifier: .init(String(columnIndex)))
                column.width = 140
                column.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
                table.addTableColumn(column)
            }
            let title = header && !index.records.isEmpty
                ? DelimitedTablePresentation.value(in: source, index: index, record: 0, column: columnIndex, limit: 128) : ""
            column.title = title.isEmpty ? String(columnIndex + 1) : title
        }
        table.sortDescriptors = (controls?.configuration.sort ?? []).map {
            NSSortDescriptor(key: String($0.column), ascending: $0.ascending)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { presentation?.rows.count ?? 0 }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let order = tableView.sortDescriptors.compactMap { entry -> DelimitedTablePresentation.Sort? in
            guard let key = entry.key, let column = Int(key) else { return nil }
            return .init(column: column, ascending: entry.ascending)
        }
        if controls?.configuration.sort != order { controls?.configuration.sort = order }
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, let columnIndex = Int(column.identifier.rawValue) else { return nil }
        let cell = DelimitedTablePresentation.Cell(row: row, column: columnIndex)
        let cellID = NSUserInterfaceItemIdentifier("bailey.csv.cell")
        let label = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = cellID
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.stringValue = value(cell, limit: 4096)
        table.style(label, cell: cell)
        return label
    }

    private func value(_ cell: DelimitedTablePresentation.Cell, limit: Int) -> String {
        guard let snapshot, let presentation, presentation.rows.indices.contains(cell.row) else { return "" }
        return DelimitedTablePresentation.value(
            in: source, index: snapshot.index, record: presentation.rows[cell.row], column: cell.column, limit: limit
        )
    }

    func showMatch(_ matches: [DelimitedTablePresentation.Cell], step: Int) {
        if matches != previousMatches {
            previousMatches = matches
            previousStep = step
            matchIndex = 0
        } else if !matches.isEmpty, step != previousStep {
            let delta = (step &- previousStep) % matches.count
            matchIndex = (matchIndex + delta + matches.count) % matches.count
            previousStep = step
        } else {
            return
        }
        guard matches.indices.contains(matchIndex) else { return }
        table.select(matches[matchIndex], reveal: true)
    }

    private func copySelection() {
        guard let presentation, let snapshot, !table.selection.blocks.isEmpty else { return }
        copyTask?.cancel()
        let selection = table.selection
        let changeCount = NSPasteboard.general.changeCount
        copyTask = Task { [weak self] in
            guard let value = try? await presentation.copy(selection, source: snapshot.source, index: snapshot.index),
                  !Task.isCancelled, let self, self.presentation?.id == presentation.id,
                  self.window?.isKeyWindow == true, NSPasteboard.general.changeCount == changeCount else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }

    private func columnMenu(_ column: Int) -> NSMenu? {
        guard let controls, table.tableColumns.indices.contains(column) else { return nil }
        let menu = NSMenu()
        func item(_ title: String, action: Selector, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            return item
        }
        menu.addItem(item(String(localized: "Filter Column…", table: "Editor"), action: #selector(filter(_:)), tag: column))
        if controls.configuration.filters[column] != nil {
            menu.addItem(item(String(localized: "Clear Column Filter", table: "Editor"), action: #selector(clearFilter(_:)), tag: column))
        }
        let header = item(String(localized: "Use First Row as Header", table: "Editor"), action: #selector(toggleHeader))
        header.state = controls.configuration.header ? .on : .off
        menu.addItem(header)
        let delimiter = NSMenuItem(title: String(localized: "Delimiter", table: "Editor"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for separator in DelimitedTableIndex.Separator.allCases {
            let choice = item(separator.title, action: #selector(chooseDelimiter(_:)), tag: Int(separator.rawValue))
            choice.state = snapshot?.index.separator == separator ? .on : .off
            submenu.addItem(choice)
        }
        delimiter.submenu = submenu
        menu.addItem(delimiter)
        return menu
    }

    @objc private func filter(_ sender: NSMenuItem) { onFilter(sender.tag) }
    @objc private func clearFilter(_ sender: NSMenuItem) { controls?.configuration.filters.removeValue(forKey: sender.tag) }
    @objc private func toggleHeader() { controls?.configuration.header.toggle() }
    @objc private func chooseDelimiter(_ sender: NSMenuItem) {
        controls?.separator = DelimitedTableIndex.Separator(rawValue: UInt16(sender.tag))
    }
}

private final class DelimitedHeader: NSTableHeaderView {
    var onMenu: (Int) -> NSMenu? = { _ in nil }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu(column(at: convert(event.locationInWindow, from: nil)))
    }
}

final class DelimitedNativeTable: NSTableView {
    typealias Cell = DelimitedTablePresentation.Cell
    private(set) var selection = DelimitedTablePresentation.Selection()
    var onFocused: () -> Void = {}
    var onSelection: (Cell?) -> Void = { _ in }
    var onCopy: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocused()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let cell = cell(at: event) else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        select(cell, extending: event.modifierFlags.contains(.shift), adding: event.modifierFlags.contains(.command))
    }

    override func mouseDragged(with event: NSEvent) {
        _ = autoscroll(with: event)
        if let cell = cell(at: event) { select(cell, extending: true) }
    }

    private func cell(at event: NSEvent) -> Cell? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        return row >= 0 && column >= 0 ? Cell(row: row, column: column) : nil
    }

    override func keyDown(with event: NSEvent) {
        guard numberOfRows > 0, numberOfColumns > 0,
              let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else {
            super.keyDown(with: event)
            return
        }
        let previous = selection.caret ?? Cell(row: 0, column: 0)
        var row = previous.row
        var column = previous.column
        switch key {
        case UInt32(NSUpArrowFunctionKey): row -= 1
        case UInt32(NSDownArrowFunctionKey): row += 1
        case UInt32(NSLeftArrowFunctionKey): column -= 1
        case UInt32(NSRightArrowFunctionKey): column += 1
        default: super.keyDown(with: event); return
        }
        select(Cell(row: max(0, min(row, numberOfRows - 1)), column: max(0, min(column, numberOfColumns - 1))),
               extending: event.modifierFlags.contains(.shift), reveal: true)
    }

    override func selectAll(_ sender: Any?) {
        guard numberOfRows > 0, numberOfColumns > 0 else { return }
        selection.select(Cell(row: 0, column: 0))
        select(Cell(row: numberOfRows - 1, column: numberOfColumns - 1), extending: true)
    }

    @objc func copy(_ sender: Any?) { onCopy() }

    func select(_ cell: Cell, extending: Bool = false, adding: Bool = false, reveal: Bool = false) {
        guard (0..<numberOfRows).contains(cell.row), (0..<numberOfColumns).contains(cell.column) else { return }
        selection.select(cell, extending: extending, adding: adding)
        var rows = IndexSet()
        for block in selection.blocks {
            rows.insert(integersIn: block.rows.lowerBound..<(block.rows.upperBound + 1))
        }
        selectRowIndexes(rows, byExtendingSelection: false)
        if reveal {
            scrollRowToVisible(cell.row)
            scrollColumnToVisible(cell.column)
        }
        refreshSelection()
        onSelection(cell)
    }

    func clearSelection() {
        selection = .init()
        deselectAll(nil)
        refreshSelection()
        onSelection(nil)
    }

    private func refreshSelection() {
        let columns = columnIndexes(in: visibleRect)
        enumerateAvailableRowViews { _, row in
            for column in columns {
                guard let label = view(atColumn: column, row: row, makeIfNecessary: false) as? NSTextField else { continue }
                style(label, cell: Cell(row: row, column: column))
            }
        }
    }

    func style(_ label: NSTextField, cell: Cell) {
        let selected = selection.contains(cell)
        label.drawsBackground = selected
        label.backgroundColor = .selectedContentBackgroundColor
        label.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        label.setAccessibilitySelected(selected)
    }
}
