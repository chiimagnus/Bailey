import AppKit
import GhosttyTheme
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
    @ObservationIgnored var columnWidths: [Int: CGFloat] = [:]

    func accept(_ index: DelimitedTableIndex) {
        let next: DelimitedTablePresentation.Configuration
        if let displayedSeparator, displayedSeparator != index.separator {
            next = .init(header: configuration.header)
            columnWidths.removeAll()
        } else {
            next = configuration.restricted(to: min(index.columnCount, DelimitedGrid.maximumColumns))
            columnWidths = columnWidths.filter { $0.key < index.columnCount }
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
    @Environment(\.colorScheme) private var colorScheme

    private var controls: DelimitedTableControls { file.delimitedTable }

    var body: some View {
        let _ = Theme.changes.revision
        let theme = Theme.terminal(dark: colorScheme == .dark)
        let parse = ParseRequest(source: file.textPreviewRequestID, separator: controls.separator)
        let display = DisplayRequest(parse: parse, configuration: controls.configuration)
        let active = displayed.flatMap { $0.0 == parse ? $0.1 : nil }
        let query = active.map { SearchRequest(display: $0.id, query: controls.query) }
        let matches = search.flatMap { $0.0 == query ? $0.1 : nil } ?? []
        surface(parse, active: active, matches: matches, theme: theme)
            .overlay(alignment: .topTrailing) { overlay(matches: matches.count, theme: theme) }
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
        _ request: ParseRequest, active: DelimitedTablePresentation?, matches: [DelimitedTablePresentation.Cell],
        theme: GhosttyThemeDefinition
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
                    file: file, snapshot: snapshot, presentation: active, theme: theme,
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
    private func overlay(matches: Int, theme: GhosttyThemeDefinition) -> some View {
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
            .modifier(DelimitedOverlayStyle(theme: theme))
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
            .modifier(DelimitedOverlayStyle(theme: theme))
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

private struct DelimitedOverlayStyle: ViewModifier {
    let theme: GhosttyThemeDefinition

    func body(content: Content) -> some View {
        content.foregroundStyle(Color(nsColor: theme.foregroundNSColor))
            .background(Color(nsColor: theme.surfaceNSColor(elevation: 0.08)), in: .rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: theme.surfaceNSColor(elevation: 0.2)))
                .allowsHitTesting(false) }
            .padding(8)
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
    let theme: GhosttyThemeDefinition
    let findStep: Int
    let matches: [DelimitedTablePresentation.Cell]
    let onFocused: () -> Void
    let onFilter: (Int) -> Void

    func makeNSView(context: Context) -> DelimitedGrid { DelimitedGrid() }

    func updateNSView(_ grid: DelimitedGrid, context: Context) {
        grid.file = file
        grid.applyTheme(theme)
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
    weak var file: FileTab? {
        didSet { table.file = file }
    }
    private var controls: DelimitedTableControls? { file?.delimitedTable }
    private var theme: GhosttyThemeDefinition?
    private var palette: DelimitedPalette { table.palette }
    private var installingColumns = false
    var onFilter: (Int) -> Void = { _ in }
    private var snapshot: FileTab.DelimitedSnapshot?
    private var presentation: DelimitedTablePresentation?
    private var source: NSString = ""
    private var copyTask: Task<Void, Never>?
    private struct CellEdit {
        let field: DelimitedCellField
        let cell: DelimitedTablePresentation.Cell
        let snapshot: FileTab.DelimitedSnapshot
        let physical: DelimitedTablePresentation.Cell
        let original: String
        var editorAppearance: FieldEditorAppearance?
        var movement: Int? = nil
    }
    private struct FieldEditorAppearance {
        weak var editor: NSTextView?
        let insertionPoint: NSColor
        let selection: [NSAttributedString.Key: Any]
        let drawsBackground: Bool
        let textInset: NSSize

        init(_ editor: NSTextView) {
            self.editor = editor
            insertionPoint = editor.insertionPointColor
            selection = editor.selectedTextAttributes
            drawsBackground = editor.drawsBackground
            textInset = editor.textContainerInset
        }

        func restore() {
            editor?.insertionPointColor = insertionPoint
            editor?.selectedTextAttributes = selection
            editor?.drawsBackground = drawsBackground
            editor?.textContainerInset = textInset
        }
    }
    private var editing: CellEdit?
    private var previousMatches: [DelimitedTablePresentation.Cell] = []
    private var previousStep = 0
    private var matchIndex = 0

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        let header = DelimitedHeader(frame: NSRect(x: 0, y: 0, width: 0, height: 30))
        header.onMenu = { [weak self] column in self?.columnMenu(column) }
        table.headerView = header
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = 30
        table.intercellSpacing = .zero
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
        applyTheme(Theme.terminal(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func applyTheme(_ theme: GhosttyThemeDefinition) {
        guard self.theme != theme else { return }
        self.theme = theme
        table.palette = DelimitedPalette(theme)
        backgroundColor = palette.background
        contentView.backgroundColor = palette.background
        table.backgroundColor = palette.background
        table.headerView?.needsDisplay = true
        table.refreshSelection()
        if let edit = editing { styleEditor(edit) }
    }

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
        table.onFocused = {}
        onFilter = { _ in }
    }

    func install(_ snapshot: FileTab.DelimitedSnapshot, presentation: DelimitedTablePresentation) {
        guard presentation.id != self.presentation?.id else { return }
        finishEditing()
        let oldHeader = self.presentation?.header
        let needsFit = self.snapshot?.index.separator != snapshot.index.separator ||
            oldHeader != presentation.header
        let rebuildColumns = self.snapshot?.requestID != snapshot.requestID ||
            self.snapshot?.index.separator != snapshot.index.separator || oldHeader != presentation.header
        self.snapshot = snapshot
        source = snapshot.source as NSString
        if rebuildColumns {
            self.presentation = nil
            table.reloadData()
            installColumns(index: snapshot.index, header: presentation.header, fitExisting: needsFit)
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

    private func installColumns(index: DelimitedTableIndex, header: Bool, fitExisting: Bool) {
        installingColumns = true
        defer { installingColumns = false }
        let count = min(index.columnCount, Self.maximumColumns)
        let columns = table.tableColumns
        for column in columns.dropFirst(count) { table.removeTableColumn(column) }
        for columnIndex in 0..<count {
            let isNewColumn = columnIndex >= columns.count
            let column: NSTableColumn
            if !isNewColumn {
                column = columns[columnIndex]
            } else {
                column = NSTableColumn(identifier: .init(String(columnIndex)))
                column.minWidth = 44
                column.headerCell = DelimitedColumnHeader(textCell: "")
                column.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier.rawValue, ascending: true)
            }
            let title = header && !index.records.isEmpty
                ? DelimitedTablePresentation.value(in: source, index: index, record: 0, column: columnIndex, limit: 128) : ""
            let displayTitle = title.isEmpty ? String(columnIndex + 1) : Self.singleLine(title)
            if column.title != displayTitle { column.title = displayTitle }
            if let width = controls?.columnWidths[columnIndex] {
                column.width = width
            } else if fitExisting || isNewColumn {
                column.width = fittedWidth(columnIndex, title: displayTitle, index: index,
                                           header: header, samplesPerColumn: 4096 / count)
            }
            if isNewColumn { table.addTableColumn(column) }
        }
        table.sortDescriptors = (controls?.configuration.sort ?? []).map {
            NSSortDescriptor(key: String($0.column), ascending: $0.ascending)
        }
    }

    private func fittedWidth(_ column: Int, title: String, index: DelimitedTableIndex,
                             header: Bool, samplesPerColumn: Int) -> CGFloat {
        let headerAttributes: [NSAttributedString.Key: Any] = [.font: DelimitedColumnHeader.titleFont]
        let cellAttributes: [NSAttributedString.Key: Any] = [.font: DelimitedCellField.textFont]
        var width = (title as NSString).size(withAttributes: headerAttributes).width
        let first = header ? 1 : 0
        let rows = max(0, index.records.count - first)
        let samples = min(rows, 48, samplesPerColumn)
        for sample in 0..<samples {
            let row = samples == 1 ? 0 : sample * (rows - 1) / (samples - 1)
            guard let field = index.field(record: first + row, column: column) else { continue }
            let value = Self.singleLine(field.value(in: source, limit: 128))
            width = max(width, (value as NSString).size(withAttributes: cellAttributes).width)
            if width >= 268 { break }
        }
        return min(290, max(110, ceil(width) + 22))
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !installingColumns, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              let index = Int(column.identifier.rawValue) else { return }
        controls?.columnWidths[index] = column.width
    }

    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        guard let snapshot, let presentation else { return tableView.tableColumns[column].width }
        return fittedWidth(column, title: tableView.tableColumns[column].title, index: snapshot.index,
                           header: presentation.header, samplesPerColumn: 48)
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
        let label = tableView.makeView(withIdentifier: cellID, owner: self) as? DelimitedCellField
            ?? DelimitedCellField(frame: .zero)
        label.identifier = cellID
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isEditable = false
        label.isSelectable = false
        label.delegate = nil
        label.isBordered = false
        displayValue(in: label, at: cell)
        table.style(label, cell: cell)
        return label
    }

    private static func singleLine(_ value: String) -> String {
        guard value.utf8.contains(where: { $0 == 10 || $0 == 13 }) else { return value }
        return value.replacingOccurrences(of: "\r\n", with: " ↵ ")
            .replacingOccurrences(of: "\r", with: " ↵ ")
            .replacingOccurrences(of: "\n", with: " ↵ ")
    }

    private func displayValue(in label: DelimitedCellField, at cell: DelimitedTablePresentation.Cell) {
        let field = physicalCell(cell).flatMap { snapshot?.index.field(record: $0.row, column: $0.column) }
        let value = field?.value(in: source, limit: 4096) ?? ""
        label.isNumeric = field.map { $0.contentRange(in: source).length <= 4096 } == true &&
            DelimitedTablePresentation.finiteNumber(value) != nil
        label.stringValue = Self.singleLine(value)
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
        guard let field = table.view(atColumn: cell.column, row: cell.row, makeIfNecessary: true) as? DelimitedCellField,
              file.beginDelimitedEditing(in: self, using: snapshot) else { return }
        let original = value(cell)
        editing = CellEdit(field: field, cell: cell, snapshot: snapshot, physical: physical, original: original)
        field.stringValue = original
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        table.style(field, cell: cell)
        guard window.makeFirstResponder(field) else { cancelEditing(); return }
        if let editor = field.currentEditor() as? NSTextView {
            editing?.editorAppearance = FieldEditorAppearance(editor)
            editor.drawsBackground = false
            editor.textContainerInset = NSSize(width: 8, height: 6)
            if let edit = editing { styleEditor(edit) }
            editor.selectAll(nil)
        }
    }

    private func styleEditor(_ edit: CellEdit) {
        guard let editor = edit.field.currentEditor() as? NSTextView else { return }
        editor.textColor = palette.text
        editor.insertionPointColor = palette.focus
        editor.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.selectedText]
    }

    private func restoreField(_ edit: CellEdit) {
        edit.field.delegate = nil
        edit.field.isEditable = false
        edit.field.isSelectable = false
        edit.field.isBordered = false
        edit.editorAppearance?.restore()
        displayValue(in: edit.field, at: edit.cell)
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
        menu.addItem(item(String(localized: "Fit Column Width", table: "Editor"), action: #selector(fitColumnWidth(_:)), tag: column))
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
    @objc private func fitColumnWidth(_ sender: NSMenuItem) {
        guard snapshot != nil, presentation != nil, table.tableColumns.indices.contains(sender.tag) else { return }
        installingColumns = true
        defer { installingColumns = false }
        controls?.columnWidths.removeValue(forKey: sender.tag)
        table.tableColumns[sender.tag].width = tableView(table, sizeToFitWidthOfColumn: sender.tag)
    }
    @objc private func clearFilter(_ sender: NSMenuItem) { controls?.configuration.filters.removeValue(forKey: sender.tag) }
    @objc private func toggleHeader() { controls?.configuration.header.toggle() }
    @objc private func chooseDelimiter(_ sender: NSMenuItem) {
        controls?.separator = DelimitedTableIndex.Separator(rawValue: UInt16(sender.tag))
    }
}

private final class DelimitedHeader: NSTableHeaderView {
    var onMenu: (Int) -> NSMenu? = { _ in nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let table = tableView as? DelimitedNativeTable else { return }
        table.palette.header.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
        table.palette.grid.setFill()
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        NSRect(x: bounds.minX, y: bounds.maxY - pixel, width: bounds.width, height: pixel).fill()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu(column(at: convert(event.locationInWindow, from: nil)))
    }
}

private final class DelimitedColumnHeader: NSTableHeaderCell {
    static let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        guard let table = (controlView as? NSTableHeaderView)?.tableView as? DelimitedNativeTable else { return }
        let palette = table.palette
        palette.header.setFill()
        frame.fill()
        let pixel = 1 / (controlView.window?.backingScaleFactor ?? 1)
        palette.grid.setFill()
        NSRect(x: frame.maxX - pixel, y: frame.minY, width: pixel, height: frame.height).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: stringValue, attributes: [
            .font: Self.titleFont, .foregroundColor: palette.text, .paragraphStyle: paragraph
        ])
        let height = ceil(title.size().height)
        title.draw(with: NSRect(x: frame.minX + 11, y: floor(controlView.bounds.midY - height / 2),
                                width: max(0, frame.width - 22), height: height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

fileprivate final class DelimitedCellField: NSTextField {
    static let textFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var isNumeric = false
    var rule: NSColor? {
        didSet { if rule != oldValue { needsDisplay = true } }
    }
    var outline: NSColor? {
        didSet { if outline != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        cell = DelimitedCellText(textCell: "")
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        focusRingType = .none
        font = Self.textFont
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if isEditable, let backgroundColor {
            backgroundColor.setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        if let rule {
            rule.setFill()
            NSRect(x: bounds.maxX - pixel, y: bounds.minY, width: pixel, height: bounds.height).fill()
            NSRect(x: bounds.minX, y: isFlipped ? bounds.maxY - pixel : bounds.minY,
                   width: bounds.width, height: pixel).fill()
        }
        guard let outline else { return }
        outline.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: pixel / 2, dy: pixel / 2))
        border.lineWidth = pixel
        border.stroke()
    }
}

private final class DelimitedCellText: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let inset = min(10, rect.width / 4)
        var interior = super.drawingRect(forBounds: rect.insetBy(dx: inset, dy: 0))
        if let font {
            let height = min(interior.height, ceil(font.ascender - font.descender + font.leading) + 2)
            interior = interior.insetBy(dx: 0, dy: max(0, floor((interior.height - height) / 2)))
        }
        return interior
    }
}

fileprivate struct DelimitedPalette {
    let background: NSColor
    let text: NSColor
    let numeric: NSColor
    let header: NSColor
    let grid: NSColor
    let hover: NSColor
    let focus: NSColor
    let selection: NSColor
    let inactiveSelection: NSColor
    let selectedText: NSColor
    let input: NSColor

    init(_ theme: GhosttyThemeDefinition) {
        let canvas = theme.backgroundNSColor
        let foreground = theme.foregroundNSColor
        let accent = theme.accentNSColor
        background = canvas
        text = foreground
        let green = theme.paletteNSColor(2).flatMap { $0.blended(withFraction: 0.32, of: foreground) } ?? foreground
        numeric = Self.readable(green, on: canvas, toward: foreground, ratio: 4.5)
        header = theme.surfaceNSColor(elevation: 0.08)
        grid = theme.surfaceNSColor(elevation: 0.2)
        hover = theme.surfaceNSColor(elevation: 0.06)
        focus = Self.readable(accent, on: canvas, toward: foreground, ratio: 3)
        selection = canvas.blended(withFraction: 0.22, of: theme.selectionBackground == nil
                                    ? accent : theme.selectionBackgroundNSColor) ?? canvas
        inactiveSelection = theme.surfaceNSColor(elevation: 0.15)
        selectedText = Self.readable(theme.selectionForeground == nil ? foreground : theme.selectionForegroundNSColor,
                                     on: selection, toward: foreground, ratio: 4.5)
        input = canvas.blended(withFraction: 0.12, of: accent) ?? canvas
    }

    private static func readable(_ color: NSColor, on background: NSColor, toward text: NSColor, ratio: CGFloat) -> NSColor {
        func luminance(_ color: NSColor) -> CGFloat {
            guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent)
                + 0.0722 * linear(srgb.blueComponent)
        }
        let base = luminance(background) + 0.05
        for weight in [0.0, 0.25, 0.5, 0.75] {
            let candidate = color.blended(withFraction: weight, of: text) ?? text
            let level = luminance(candidate) + 0.05
            if max(base, level) / min(base, level) >= ratio { return candidate }
        }
        return text
    }
}

final class DelimitedNativeTable: NSTableView, NSMenuItemValidation {
    typealias Cell = DelimitedTablePresentation.Cell
    fileprivate lazy var palette = DelimitedPalette(
        Theme.terminal(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    )
    private var hoverArea: NSTrackingArea?
    private var hoveredCell: Cell?

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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        let center = NotificationCenter.default
        if let window {
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        if let newWindow {
            center.addObserver(self, selector: #selector(windowFocusChanged(_:)),
                               name: NSWindow.didBecomeKeyNotification, object: newWindow)
            center.addObserver(self, selector: #selector(windowFocusChanged(_:)),
                               name: NSWindow.didResignKeyNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowFocusChanged(_ notification: Notification) { refreshSelection() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved,
                                                         .mouseEnteredAndExited], owner: self)
        hoverArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hover(cell(at: event)) }
    override func mouseMoved(with event: NSEvent) { hover(cell(at: event)) }
    override func mouseExited(with event: NSEvent) { hover(nil) }

    private func hover(_ cell: Cell?) {
        guard cell != hoveredCell else { return }
        let previous = hoveredCell
        hoveredCell = cell
        for target in [previous, cell].compactMap({ $0 }) {
            guard target.row < numberOfRows, target.column < numberOfColumns,
                  let field = view(atColumn: target.column, row: target.row, makeIfNecessary: false) as? DelimitedCellField
            else { continue }
            style(field, cell: target)
        }
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
        hoveredCell = nil
        deselectAll(nil)
        refreshSelection()
        onSelection(nil)
    }

    fileprivate func refreshSelection() {
        let columns = columnIndexes(in: visibleRect)
        enumerateAvailableRowViews { _, row in
            for column in columns {
                guard let label = view(atColumn: column, row: row, makeIfNecessary: false) as? DelimitedCellField else { continue }
                style(label, cell: Cell(row: row, column: column))
            }
        }
    }

    fileprivate func style(_ label: DelimitedCellField, cell: Cell) {
        let selected = selection.contains(cell)
        let active = window?.isKeyWindow == true
        label.rule = palette.grid
        if label.isEditable {
            label.backgroundColor = palette.input
            label.outline = palette.focus
            label.drawsBackground = false
            if label.currentEditor() == nil { label.textColor = palette.text }
        } else {
            label.drawsBackground = selected || hoveredCell == cell
            label.backgroundColor = selected ? (active ? palette.selection : palette.inactiveSelection) : palette.hover
            label.outline = selected ? (active ? palette.focus : palette.grid) : nil
            label.textColor = selected && active ? palette.selectedText : label.isNumeric ? palette.numeric : palette.text
        }
        label.setAccessibilitySelected(selected)
    }
}
