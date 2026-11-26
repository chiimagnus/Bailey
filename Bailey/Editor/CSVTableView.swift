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
    var editError: String?
    @ObservationIgnored var pendingCell: DelimitedTablePresentation.Cell?
    @ObservationIgnored var selectedValue = ""
    @ObservationIgnored private var displayedSeparator: DelimitedTableIndex.Separator?

    func accept(_ index: DelimitedTableIndex) {
        let next: DelimitedTablePresentation.Configuration
        if let displayedSeparator, displayedSeparator != index.separator {
            next = .init(header: configuration.header)
        } else {
            next = configuration.restricted(to: min(index.columnCount, DelimitedGrid.maximumColumns))
        }
        displayedSeparator = index.separator
        if next != configuration { configuration = next }
    }

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
                    controls.accept(result.index)
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
        let snapshot = parsed.flatMap { $0.0 == request && active != nil ? $0.1 : nil }
        let hasRows = snapshot.map { !$0.index.records.isEmpty } ?? false
        VStack(spacing: 0) {
            if let snapshot {
                if let issue = snapshot.index.issue {
                    notice(String(localized: "Table issue at line \(issue.line), column \(issue.column).", table: "Editor"))
                } else if snapshot.index.columnCount > DelimitedGrid.maximumColumns {
                    notice(String(localized: "This table has too many columns to display.", table: "Editor"))
                } else if snapshot.index.needsSeparatorChoice {
                    notice(String(localized: "Choose the table delimiter.", table: "Editor"))
                } else if !file.savedTextPreservesOriginalBytes {
                    notice(String(localized: "The current encoding cannot preserve the original bytes. Edit the source instead.", table: "Editor"))
                }
            }
            ZStack {
                NativeDelimitedGrid(
                    file: file, snapshot: snapshot, presentation: active, controls: controls,
                    findStep: controls.findStep, matches: matches, onFocused: onFocused,
                    onFilter: { column in
                        filterDraft = controls.configuration.filters[column] ?? ""
                        filterColumn = column
                    }
                )
                .opacity(hasRows ? 1 : 0)
                .allowsHitTesting(hasRows)
                .accessibilityHidden(!hasRows)

                if let snapshot, !hasRows {
                    VStack {
                        Spacer()
                        Text("No table rows to display.", tableName: "Editor").foregroundStyle(.secondary)
                        if file.canEditDelimited(snapshot) {
                            Button(String(localized: "Insert Row", table: "Editor")) {
                                file.submitDelimitedEdit(.insertRows(before: 0, count: 1), using: snapshot, selecting: nil)
                            }
                            .disabled(file.hasPendingDelimitedEdit)
                        }
                        Spacer()
                    }
                } else if snapshot == nil {
                    if failed == request {
                        notice(String(localized: "Could not display the table.", table: "Editor"))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
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
                    .accessibilityLabel(Text("Previous match", tableName: "Terminal"))
                Button { controls.perform(.next) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel(Text("Next match", tableName: "Terminal"))
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
    let file: FileTab
    let snapshot: FileTab.DelimitedSnapshot?
    let presentation: DelimitedTablePresentation?
    let controls: DelimitedTableControls
    let findStep: Int
    let matches: [DelimitedTablePresentation.Cell]
    let onFocused: () -> Void
    let onFilter: (Int) -> Void

    func makeNSView(context: Context) -> DelimitedGrid { DelimitedGrid() }

    func updateNSView(_ grid: DelimitedGrid, context: Context) {
        grid.controls = controls
        grid.file = file
        grid.table.file = file
        grid.table.onFocused = onFocused
        grid.onFilter = onFilter
        if let snapshot, let presentation, !snapshot.index.records.isEmpty {
            grid.install(snapshot, presentation: presentation)
            grid.showMatch(matches, step: findStep)
        } else {
            grid.clearProjection()
        }
    }

    static func dismantleNSView(_ grid: DelimitedGrid, coordinator: ()) { grid.detach() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DelimitedGrid, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

final class DelimitedGrid: NSScrollView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let maximumColumns = 4096
    let table = DelimitedNativeTable()
    weak var file: FileTab?
    var controls: DelimitedTableControls?
    var onFilter: (Int) -> Void = { _ in }
    private var snapshot: FileTab.DelimitedSnapshot?
    private var presentation: DelimitedTablePresentation?
    private var source: NSString = ""
    private var copyTask: Task<Void, Never>?
    private struct CellEdit {
        let field: NSTextField
        let cell: DelimitedTablePresentation.Cell
        let snapshot: FileTab.DelimitedSnapshot
        let physical: DelimitedTablePresentation.Cell
        let original: String
        var movement: Int? = nil
    }
    private var editing: CellEdit?
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
        table.onEdit = { [weak self] cell in self?.beginEditing(cell) }
        table.onPaste = { [weak self] text in self?.paste(text) }
        table.onMenu = { [weak self] in self?.recordMenu() }
        table.onSelection = { [weak self] cell in
            guard let self else { return }
            controls?.selectedValue = cell.map { value($0, limit: 4096) } ?? ""
        }
        documentView = table
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishEditing() }
        super.viewWillMove(toWindow: newWindow)
    }

    // The view and its first responder survive re-indexing; stale rows, selection
    // and pending clipboard work do not.
    func clearProjection() {
        guard snapshot != nil || presentation != nil else { return }
        finishEditing()
        copyTask?.cancel()
        copyTask = nil
        table.clearSelection()
        snapshot = nil
        presentation = nil
        source = ""
        previousMatches = []
        table.reloadData()
    }

    func detach() {
        clearProjection()
        file = nil
        table.file = nil
        controls = nil
        table.onFocused = {}
        onFilter = { _ in }
    }

    func install(_ snapshot: FileTab.DelimitedSnapshot, presentation: DelimitedTablePresentation) {
        guard presentation.id != self.presentation?.id else { return }
        finishEditing()
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
        if let cell = controls?.pendingCell {
            controls?.pendingCell = nil
            if let row = presentation.rows.firstIndex(of: cell.row) {
                table.select(.init(row: row, column: cell.column), reveal: true)
            }
        }
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
        label.isEditable = false
        label.isSelectable = false
        label.delegate = nil
        label.isBordered = false
        label.stringValue = value(cell, limit: 4096)
        table.style(label, cell: cell)
        return label
    }

    private func value(_ cell: DelimitedTablePresentation.Cell, limit: Int? = nil) -> String {
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

    private func physicalCell(_ cell: DelimitedTablePresentation.Cell) -> DelimitedTablePresentation.Cell? {
        guard let presentation, presentation.rows.indices.contains(cell.row),
              (0..<table.numberOfColumns).contains(cell.column) else { return nil }
        return .init(row: presentation.rows[cell.row], column: cell.column)
    }

    private func beginEditing(_ cell: DelimitedTablePresentation.Cell) {
        guard editing == nil, let file, !file.hasPendingDelimitedEdit, let snapshot,
              file.canEditDelimited(snapshot), let physical = physicalCell(cell),
              let window else { return }
        table.select(cell, reveal: true)
        table.layoutSubtreeIfNeeded()
        guard let field = table.view(atColumn: cell.column, row: cell.row, makeIfNecessary: true) as? NSTextField,
              file.beginDelimitedEditing(in: self, using: snapshot) else { return }
        let original = value(cell)
        editing = CellEdit(field: field, cell: cell, snapshot: snapshot, physical: physical, original: original)
        field.stringValue = original
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.delegate = self
        guard window.makeFirstResponder(field) else { cancelEditing(); return }
        field.currentEditor()?.selectAll(nil)
    }

    private func restoreField(_ edit: CellEdit) {
        edit.field.delegate = nil
        edit.field.isEditable = false
        edit.field.isSelectable = false
        edit.field.isBordered = false
        edit.field.stringValue = value(edit.cell, limit: 4096)
        table.style(edit.field, cell: edit.cell)
    }

    func finishEditing() {
        guard let edit = editing, let window = edit.field.window else { return }
        // Commit through AppKit's actual field editor, without activating a
        // different Dock group or retaining an offscreen editable field.
        window.endEditing(for: edit.field)
    }

    func cancelEditing() {
        guard let edit = editing else { return }
        editing = nil
        file?.endDelimitedEditing(in: self)
        edit.field.abortEditing()
        restoreField(edit)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let edit = editing, control === edit.field, !textView.hasMarkedText(),
              let window, window.firstResponder === textView else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditing()
            window.makeFirstResponder(table)
            return true
        }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            editing?.movement = NSReturnTextMovement
        case #selector(NSResponder.insertTab(_:)):
            editing?.movement = NSTabTextMovement
        case #selector(NSResponder.insertBacktab(_:)):
            editing?.movement = NSBacktabTextMovement
        default:
            return false
        }
        // Only explicit keyboard submission transfers focus back to the grid.
        // Ordinary blur, saving, and detaching must not take focus from others.
        guard window.makeFirstResponder(table) else {
            editing?.movement = nil
            return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let edit = editing, notification.object as? NSTextField === edit.field else { return }
        let value = edit.field.stringValue
        let movement = edit.movement ?? notification.userInfo?["NSTextMovement"] as? Int
        editing = nil
        restoreField(edit)
        guard movement != NSCancelTextMovement else {
            file?.endDelimitedEditing(in: self)
            return
        }
        var destination = edit.physical
        if movement == NSTabTextMovement || movement == NSBacktabTextMovement,
           let next = table.adjacent(to: edit.cell, backwards: movement == NSBacktabTextMovement),
           let physical = physicalCell(next) {
            destination = physical
        }
        if value.utf16.elementsEqual(edit.original.utf16) {
            file?.endDelimitedEditing(in: self)
            if let row = presentation?.rows.firstIndex(of: destination.row) {
                table.select(.init(row: row, column: destination.column), reveal: true)
            }
            return
        }
        file?.commitDelimitedEditing(in: self, change: .cells([edit.physical: value]),
                                     using: edit.snapshot, selecting: destination)
    }

    private func apply(_ change: DelimitedTableMutation.Change, snapshot: FileTab.DelimitedSnapshot,
                       selecting cell: DelimitedTablePresentation.Cell?) {
        file?.submitDelimitedEdit(change, using: snapshot, selecting: cell)
    }

    /// Read a rectangular TSV clipboard using the same parser as file data.
    /// Literal text (including formulas) is never evaluated or reformatted.
    func paste(_ text: String) {
        guard let file, !file.hasPendingDelimitedEdit, let snapshot, let presentation,
              let origin = table.selection.caret, presentation.rows.indices.contains(origin.row),
              file.canEditDelimited(snapshot) else { return }
        file.submitDelimitedEdit(.paste(text, rows: presentation.rows, origin: origin,
                                        columns: min(snapshot.index.columnCount, Self.maximumColumns)),
                                 using: snapshot,
                                 selecting: .init(row: presentation.rows[origin.row], column: origin.column))
    }

    private func recordMenu() -> NSMenu? {
        guard let file, let snapshot, file.canEditDelimited(snapshot), !file.hasPendingDelimitedEdit else { return nil }
        let menu = NSMenu()
        func item(_ title: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        menu.addItem(item(String(localized: "Insert Row", table: "Editor"), action: #selector(insertRow)))
        if table.selection.caret != nil {
            menu.addItem(item(String(localized: "Delete Rows", table: "Editor"), action: #selector(deleteRows)))
        }
        return menu
    }

    @objc private func insertRow() {
        guard let snapshot else { return }
        let row = table.selection.caret.flatMap(physicalCell)?.row ?? snapshot.index.records.count
        apply(.insertRows(before: row, count: 1), snapshot: snapshot, selecting: .init(row: row, column: 0))
    }

    @objc private func deleteRows() {
        guard let snapshot, let presentation else { return }
        let rows = Set(table.selection.blocks.flatMap { block in block.rows.compactMap { row in
            presentation.rows.indices.contains(row) ? presentation.rows[row] : nil
        } })
        guard !rows.isEmpty else { return }
        apply(.deleteRows(rows), snapshot: snapshot, selecting: nil)
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

final class DelimitedNativeTable: NSTableView, NSMenuItemValidation {
    typealias Cell = DelimitedTablePresentation.Cell
    private(set) var selection = DelimitedTablePresentation.Selection()
    var onFocused: () -> Void = {}
    var onSelection: (Cell?) -> Void = { _ in }
    var onCopy: () -> Void = {}
    var onEdit: (Cell) -> Void = { _ in }
    var onPaste: (String) -> Void = { _ in }
    var onMenu: () -> NSMenu? = { nil }
    weak var file: FileTab?
    override var undoManager: UndoManager? { file?.documentUndoManager ?? super.undoManager }

    private var focusedDocumentUndoManager: UndoManager? {
        guard window?.firstResponder === self, let file, !file.hasPendingDelimitedEdit else { return nil }
        return file.documentUndoManager
    }

    @objc func undo(_ sender: Any?) {
        guard let manager = focusedDocumentUndoManager, manager.canUndo else { return }
        manager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard let manager = focusedDocumentUndoManager, manager.canRedo else { return }
        manager.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): focusedDocumentUndoManager?.canUndo == true
        case #selector(redo(_:)): focusedDocumentUndoManager?.canRedo == true
        default: true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let cell = cell(at: event), !selection.contains(cell) { select(cell) }
        return onMenu()
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocused()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let cell = cell(at: event) else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        select(cell, extending: event.modifierFlags.contains(.shift), adding: event.modifierFlags.contains(.command))
        if event.clickCount == 2 { onEdit(cell) }
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
        case 13, 3:
            onEdit(previous)
            return
        case 9, 25:
            if let next = adjacent(to: previous, backwards: key == 25 || event.modifierFlags.contains(.shift)) {
                select(next, reveal: true)
            } else { super.keyDown(with: event) }
            return
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
    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { onPaste(text) }
    }

    func adjacent(to cell: Cell, backwards: Bool) -> Cell? {
        guard numberOfColumns > 0, numberOfRows > 0 else { return nil }
        let index = cell.row * numberOfColumns + cell.column + (backwards ? -1 : 1)
        guard (0..<(numberOfRows * numberOfColumns)).contains(index) else { return nil }
        return .init(row: index / numberOfColumns, column: index % numberOfColumns)
    }

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
