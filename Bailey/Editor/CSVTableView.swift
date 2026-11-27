import AppKit
import GhosttyTheme
import Observation
import SwiftUI

@Observable
final class DelimitedTableControls {
    struct ParseRequest: Hashable {
        let source: String
    }

    struct DisplayRequest: Hashable {
        let parse: ParseRequest
        let configuration: DelimitedTablePresentation.Configuration
    }

    enum PendingSelection: Equatable {
        case cell(DelimitedTablePresentation.Cell)
        case column(Int)
    }

    var configuration = DelimitedTablePresentation.Configuration()
    var query = ""
    var showsFind = false
    var showsReplace = false
    var findFocus = 0
    var findStep = 0
    var editError: String?
    private(set) var parsed: FileTab.DelimitedSnapshot?
    @ObservationIgnored var pendingSelection: PendingSelection?
    @ObservationIgnored weak var grid: DelimitedGrid?
    // Stored at the default table size; manual widths survive a change of scale.
    @ObservationIgnored var columnWidths: [Int: CGFloat] = [:]
    @ObservationIgnored private var columnRevision: String?
    @ObservationIgnored private(set) var columnMove: (before: String, after: String, positions: [Int: Int])?

    func request(for file: FileTab) -> ParseRequest {
        ParseRequest(source: file.textPreviewRequestID)
    }

    func accept(_ snapshot: FileTab.DelimitedSnapshot) {
        let index = snapshot.index
        let next: DelimitedTablePresentation.Configuration
        if columnRevision.map({ $0 != snapshot.documentRevision }) == true ||
            parsed.map({ $0.index.separator != index.separator }) == true {
            next = .init()
            columnWidths.removeAll()
            columnMove = nil
        } else {
            next = configuration.restricted(to: min(index.columnCount, DelimitedTableIndex.maximumColumns))
            columnWidths = columnWidths.filter { $0.key < index.columnCount }
        }
        columnRevision = snapshot.documentRevision
        parsed = snapshot
        if next != configuration { configuration = next }
    }

    func acceptEdit(_ change: DelimitedTableMutation.Change, from previous: String, to current: String) {
        columnRevision = current
        guard case .columns(let order) = change else { return }
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().compactMap { entry in
            entry.element.map { ($0, entry.offset) }
        })
        columnWidths = Dictionary(uniqueKeysWithValues: columnWidths.compactMap { old, width in
            positions[old].map { ($0, width) }
        })
        configuration.filters = Dictionary(uniqueKeysWithValues: configuration.filters.compactMap { old, filter in
            positions[old].map { ($0, filter) }
        })
        configuration.sort = configuration.sort.compactMap { sort in
            positions[sort.column].map { .init(column: $0, ascending: sort.ascending) }
        }
        columnMove = (previous, current, positions)
    }

    func finishColumnMove() { columnMove = nil }

    func retire() {
        grid?.clearProjection()
        parsed = nil
    }

    func perform(_ action: FindAction) {
        switch action {
        case .show:
            showsFind = true
            showsReplace = false
            findFocus &+= 1
        case .hide: showsFind = false
        case .next: findStep &+= 1
        case .previous: findStep &-= 1
        case .useSelection:
            if let value = grid?.selectedFieldValue(), !value.isEmpty { query = value }
        case .replace:
            showsFind = true
            showsReplace = true
            findFocus &+= 1
        }
    }
}

struct CSVTableView: View {
    private typealias ParseRequest = DelimitedTableControls.ParseRequest
    private typealias DisplayRequest = DelimitedTableControls.DisplayRequest

    private struct SearchRequest: Hashable {
        let display: UUID
        let query: String
    }

    private enum ReplaceScope: CaseIterable, Hashable {
        case visible, selection, all

        var title: String {
            switch self {
            case .visible: String(localized: "Visible Records", table: "Editor")
            case .selection: String(localized: "Current Selection", table: "Editor")
            case .all: String(localized: "All Data Records", table: "Editor")
            }
        }
    }

    private struct ReplaceRequest: Hashable {
        let display: UUID
        let query: String
        let range: ReplaceScope
        let selection: DelimitedTablePresentation.Selection?
    }

    private struct ReplaceCursor {
        let source: String
        let query: String
        let previous: DelimitedTablePresentation.Occurrence
    }

    private enum Input: Hashable { case find, filter }

    let file: FileTab
    let canFocus: () -> Bool
    let onFocused: () -> Void
    @State private var displayed: (DisplayRequest, DelimitedTablePresentation)?
    @State private var search: (SearchRequest, [DelimitedTablePresentation.Cell])?
    @State private var parseFailed: ParseRequest?
    @State private var displayFailed: DisplayRequest?
    @State private var filterTarget: (column: Int, request: DisplayRequest)?
    @State private var filterDraft = ""
    @State private var replacement = ""
    @State private var replaceScope = ReplaceScope.visible
    @State private var pinnedSelection: (UUID, DelimitedTablePresentation.Selection)?
    @State private var occurrenceCount: (ReplaceRequest, Int)?
    @State private var replaceCursor: ReplaceCursor?
    @State private var replaceTask: Task<Void, Never>?
    @FocusState private var focusedInput: Input?
    @Environment(\.colorScheme) private var colorScheme

    private var controls: DelimitedTableControls { file.delimitedTable }

    var body: some View {
        let _ = Theme.changes.revision
        let theme = Theme.terminal(dark: colorScheme == .dark)
        let parse = controls.request(for: file)
        let display = DisplayRequest(parse: parse, configuration: controls.configuration)
        let snapshot = controls.parsed.flatMap { $0.parseRequest == parse ? $0 : nil }
        let active = displayed.flatMap { $0.0 == display ? $0.1 : nil }
        let query = active.map { projection in
            SearchRequest(display: projection.id, query: controls.query)
        }
        let matches = search.flatMap { $0.0 == query ? $0.1 : nil }
        surface(snapshot: active == nil ? nil : snapshot, active: active, matches: matches, theme: theme,
                failed: parseFailed == parse || displayFailed == display)
            .overlay(alignment: .topTrailing) {
                overlay(display: display, snapshot: snapshot, active: active, matches: matches ?? [], theme: theme)
            }
            .task(id: parse) {
                guard snapshot == nil else { return }
                parseFailed = nil
                do {
                    guard let result = try await file.delimitedSnapshot(),
                          !Task.isCancelled, controls.request(for: file) == parse else { return }
                    controls.accept(result)
                } catch is CancellationError {
                    return
                } catch {
                    if !Task.isCancelled, controls.request(for: file) == parse { parseFailed = parse }
                }
            }
            .task(id: snapshot == nil ? nil : display) {
                guard let snapshot else { return }
                displayFailed = nil
                do {
                    let result = try await DelimitedTablePresentation.evaluate(
                        source: snapshot.source, index: snapshot.index, configuration: display.configuration
                    )
                    guard !Task.isCancelled, controls.request(for: file) == parse,
                          controls.configuration == display.configuration else { return }
                    displayed = (display, result)
                } catch is CancellationError {
                    return
                } catch {
                    if !Task.isCancelled, controls.request(for: file) == parse,
                       controls.configuration == display.configuration { displayFailed = display }
                }
            }
            .task(id: query) {
                guard let query, let active, let snapshot else { return }
                do {
                    let found = try await active.find(
                        query.query, source: snapshot.source, index: snapshot.index,
                        columnCount: DelimitedTableIndex.maximumColumns
                    )
                    guard !Task.isCancelled, controls.request(for: file) == parse,
                          controls.configuration == display.configuration, controls.query == query.query else { return }
                    search = (query, found)
                } catch {}
            }
            .onChange(of: controls.findFocus) {
                filterTarget = nil
                focus(.find)
            }
            .onChange(of: display) {
                if filterTarget?.request != display { filterTarget = nil }
                pinnedSelection = nil
            }
            .onChange(of: controls.query) { replaceCursor = nil; replaceTask?.cancel() }
            .onChange(of: controls.findStep) { replaceCursor = nil }
            .onChange(of: controls.showsFind) { if !controls.showsFind { replaceTask?.cancel() } }
            .onDisappear { replaceTask?.cancel() }
    }

    @ViewBuilder
    private func surface(
        snapshot: FileTab.DelimitedSnapshot?, active: DelimitedTablePresentation?,
        matches: [DelimitedTablePresentation.Cell]?, theme: GhosttyThemeDefinition, failed: Bool
    ) -> some View {
        let hasRows = snapshot.map { !$0.index.records.isEmpty } ?? false
        VStack(spacing: 0) {
            if let snapshot {
                if let issue = snapshot.index.issue {
                    notice(String(localized: "Table issue at line \(issue.line), column \(issue.column).", table: "Editor"))
                } else if snapshot.index.columnCount > DelimitedTableIndex.maximumColumns {
                    notice(String(localized: "This table has too many columns to display.", table: "Editor"))
                } else if !file.savedTextPreservesOriginalBytes {
                    notice(String(localized: "The current encoding cannot preserve the original bytes.", table: "Editor"))
                }
            }
            ZStack {
                NativeDelimitedGrid(
                    file: file, snapshot: snapshot, presentation: active, theme: theme,
                    fontSize: CGFloat(AppSettings.shared.tableFontSize),
                    findStep: controls.findStep, matches: matches, onFocused: onFocused,
                    onFilter: { column, request in
                        filterDraft = controls.configuration.filters[column] ?? ""
                        filterTarget = (column, request)
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
                                guard let active, controls.request(for: file) == snapshot.parseRequest,
                                      controls.configuration == active.configuration else { return }
                                file.submitDelimitedEdit(.insertRows(before: 0, count: 2), using: snapshot,
                                                         selecting: .init(row: 1, column: 0))
                            }
                            .disabled(file.hasPendingDelimitedEdit)
                        }
                        Spacer()
                    }
                } else if snapshot == nil {
                    if failed {
                        notice(String(localized: "Could not display the table.", table: "Editor"))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    private func notice(_ message: String) -> some View {
        Text(message).frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }

    @ViewBuilder
    private func overlay(display: DisplayRequest, snapshot: FileTab.DelimitedSnapshot?,
                         active: DelimitedTablePresentation?, matches: [DelimitedTablePresentation.Cell],
                         theme: GhosttyThemeDefinition) -> some View {
        if let target = filterTarget, target.request == display {
            HStack {
                TextField(String(localized: "Filter Column", table: "Editor"), text: $filterDraft)
                    .accessibilityIdentifier("bailey.csv.filter")
                    .focused($focusedInput, equals: .filter)
                    .onSubmit { applyFilter() }
                Button(String(localized: "Apply Filter", table: "Editor")) { applyFilter() }
                Button { filterTarget = nil } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
            }
            .onKeyPress(.escape) { filterTarget = nil; return .handled }
            .padding(6).frame(maxWidth: 350)
            .modifier(DelimitedOverlayStyle(theme: theme))
            .onAppear { focus(.filter) }
        } else if controls.showsFind {
            @Bindable var controls = controls
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField(String(localized: "Find", table: "Terminal"), text: $controls.query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("bailey.csv.find")
                        .focused($focusedInput, equals: .find)
                        .onSubmit { controls.perform(.next) }
                    Text(verbatim: "\(matches.count)").monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityIdentifier("bailey.csv.match-count")
                    Button { controls.perform(.previous) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel(Text("Previous match", tableName: "Terminal"))
                    Button { controls.perform(.next) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel(Text("Next match", tableName: "Terminal"))
                    Button { controls.perform(.hide) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Close"))
                }
                .buttonStyle(.borderless)
                if controls.showsReplace, let snapshot, let active {
                    replacementControls(snapshot: snapshot, active: active, matches: matches)
                }
            }
            .padding(6).frame(maxWidth: controls.showsReplace ? 380 : 320)
            .modifier(DelimitedOverlayStyle(theme: theme))
            .onKeyPress(.escape) { controls.perform(.hide); return .handled }
            .onAppear { focus(.find) }
        }
    }

    private func replaceRequest(_ active: DelimitedTablePresentation) -> ReplaceRequest? {
        guard !controls.query.isEmpty else { return nil }
        let selection: DelimitedTablePresentation.Selection?
        if replaceScope == .selection {
            guard let pinnedSelection, pinnedSelection.0 == active.id else { return nil }
            selection = pinnedSelection.1
        } else {
            selection = nil
        }
        return ReplaceRequest(display: active.id, query: controls.query, range: replaceScope, selection: selection)
    }

    private func scope(for request: ReplaceRequest, active: DelimitedTablePresentation,
                       snapshot: FileTab.DelimitedSnapshot) -> DelimitedTablePresentation.FieldScope {
        .init(rows: request.range == .all ? nil : active.rows,
              columns: IndexSet(integersIn: 0..<min(snapshot.index.columnCount, DelimitedTableIndex.maximumColumns)),
              selection: request.selection)
    }

    private func pinGridSelection(_ active: DelimitedTablePresentation) {
        guard let grid = controls.grid, grid.acceptsProjection(active.id),
              !grid.table.selection.blocks.isEmpty else { pinnedSelection = nil; return }
        pinnedSelection = (active.id, grid.table.selection)
    }

    private func replacementControls(snapshot: FileTab.DelimitedSnapshot, active: DelimitedTablePresentation,
                                     matches: [DelimitedTablePresentation.Cell]) -> some View {
        let request = replaceRequest(active)
        let count = occurrenceCount.flatMap { $0.0 == request ? $0.1 : nil }
        let canWrite = file.canEditDelimited(snapshot) && !file.hasPendingDelimitedEdit && (count ?? 0) > 0
        return VStack(alignment: .leading, spacing: 6) {
            TextField(String(localized: "Replace With", table: "Editor"), text: $replacement)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("bailey.csv.replacement")
            Picker(String(localized: "Replace In", table: "Editor"), selection: Binding(get: { replaceScope }, set: { next in
                replaceScope = next
                if next == .selection { pinGridSelection(active) }
            })) {
                ForEach(ReplaceScope.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if replaceScope == .selection {
                Button(String(localized: "Set Range from Grid Selection", table: "Editor")) { pinGridSelection(active) }
                    .controlSize(.small)
            }
            if snapshot.index.columnCount > DelimitedTableIndex.maximumColumns {
                Text("Only displayed columns are included.", tableName: "Editor").font(.caption)
            }
            HStack {
                Text("Matches: \(count ?? 0)", tableName: "Editor")
                    .font(.caption)
                    .accessibilityIdentifier("bailey.csv.replace-match-count")
                Spacer(minLength: 0)
                Button(String(localized: "Replace", table: "Editor")) {
                    replace(snapshot: snapshot, active: active, matches: matches, all: false)
                }.disabled(!canWrite || matches.isEmpty)
                Button(String(localized: "Replace All", table: "Editor")) {
                    replace(snapshot: snapshot, active: active, matches: matches, all: true)
                }.disabled(!canWrite)
            }
            .controlSize(.small)
        }
        .task(id: request) {
            guard let request else { return }
            let target = scope(for: request, active: active, snapshot: snapshot)
            guard let count = try? await DelimitedTablePresentation.countOccurrences(
                request.query, in: target, source: snapshot.source, index: snapshot.index
            ), !Task.isCancelled, replaceRequest(active) == request else { return }
            occurrenceCount = (request, count)
        }
    }

    private func replace(snapshot: FileTab.DelimitedSnapshot, active: DelimitedTablePresentation,
                         matches: [DelimitedTablePresentation.Cell], all: Bool) {
        guard let request = replaceRequest(active), let count = occurrenceCount,
              count.0 == request, count.1 > 0,
              let grid = controls.grid, grid.acceptsProjection(active.id) else { return }
        replaceTask?.cancel()
        let target = scope(for: request, active: active, snapshot: snapshot)
        let value = replacement
        if all {
            file.submitDelimitedEdit(.replace(target, query: request.query, with: value, single: nil), using: snapshot)
            return
        }
        let caret = grid.table.selection.caret
        let previous = replaceCursor.flatMap { cursor in
            cursor.source == snapshot.requestID && cursor.query == request.query ? cursor.previous : nil
        }
        replaceTask = Task { [weak grid] in
            guard let hit = try? await active.nextVisibleOccurrence(
                request.query, from: matches, at: caret, after: previous, selection: request.selection,
                source: snapshot.source, index: snapshot.index
            ), !Task.isCancelled, grid?.acceptsProjection(active.id) == true,
               controls.showsReplace, controls.showsFind, replaceRequest(active) == request, replacement == value,
               let operation = file.submitDelimitedEdit(.replace(target, query: request.query, with: value, single: hit),
                                                       using: snapshot, selecting: hit.cell),
               await operation.value, !Task.isCancelled else { return }
            replaceCursor = ReplaceCursor(source: file.textPreviewRequestID, query: request.query,
                                          previous: .init(cell: hit.cell, range: NSRange(location: hit.range.location,
                                                                                         length: value.utf16.count)))
        }
    }

    private func applyFilter() {
        guard let target = filterTarget, controls.request(for: file) == target.request.parse,
              controls.configuration == target.request.configuration else { filterTarget = nil; return }
        controls.configuration.filters[target.column] = filterDraft.isEmpty ? nil : filterDraft
        filterTarget = nil
    }

    private func focus(_ input: Input) {
        DispatchQueue.main.async {
            guard canFocus(),
                  input == .filter ? filterTarget != nil : controls.showsFind && filterTarget == nil else { return }
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

private struct NativeDelimitedGrid: NSViewRepresentable {
    let file: FileTab
    let snapshot: FileTab.DelimitedSnapshot?
    let presentation: DelimitedTablePresentation?
    let theme: GhosttyThemeDefinition
    let fontSize: CGFloat
    let findStep: Int
    let matches: [DelimitedTablePresentation.Cell]?
    let onFocused: () -> Void
    let onFilter: (Int, DelimitedTableControls.DisplayRequest) -> Void

    func makeNSView(context: Context) -> DelimitedGrid { DelimitedGrid() }

    func updateNSView(_ grid: DelimitedGrid, context: Context) {
        grid.file = file
        grid.applyTheme(theme)
        grid.applyFontSize(fontSize)
        grid.table.onFocused = onFocused
        grid.onFilter = onFilter
        if let snapshot, let presentation, !snapshot.index.records.isEmpty {
            grid.install(snapshot, presentation: presentation)
            if let matches { grid.showMatch(matches, step: findStep) }
        } else if let snapshot, snapshot.index.records.isEmpty {
            grid.clearProjection()
        }
    }

    static func dismantleNSView(_ grid: DelimitedGrid, coordinator: ()) { grid.detach() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DelimitedGrid, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

final class DelimitedGrid: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    let table = DelimitedNativeTable()
    let scrollView = NSScrollView()
    private lazy var gutter = DelimitedRecordGutter(grid: self)
    weak var file: FileTab? {
        didSet {
            guard file !== oldValue else { return }
            if oldValue?.delimitedTable.grid === self { oldValue?.delimitedTable.grid = nil }
            table.file = file
            controls?.grid = self
            previousStep = controls?.findStep ?? 0
        }
    }
    private var controls: DelimitedTableControls? { file?.delimitedTable }
    private var theme: GhosttyThemeDefinition?
    fileprivate var palette: DelimitedPalette { table.palette }
    var onFilter: (Int, DelimitedTableControls.DisplayRequest) -> Void = { _, _ in }
    private var snapshot: FileTab.DelimitedSnapshot?
    private var presentation: DelimitedTablePresentation?
    private var source: NSString = ""
    private var copyTask: Task<Void, Never>?
    private struct CellEdit {
        let editor: NSTextView
        let scroll: NSScrollView
        let undo = UndoManager()
        let displayed: DelimitedTablePresentation.Cell?
        let snapshot: FileTab.DelimitedSnapshot
        let physical: DelimitedTablePresentation.Cell
        let original: String
        let selection: DelimitedTableControls.PendingSelection
        let editable: Bool

        func draft(value: String, selecting target: DelimitedTableControls.PendingSelection? = nil) -> FileTab.DelimitedDraft {
            .init(cell: physical, value: value, snapshot: snapshot, selection: target ?? selection)
        }
    }
    private var editing: CellEdit?
    var activeEditor: NSTextView? { editing?.editor }
    private var previousMatches: [DelimitedTablePresentation.Cell] = []
    private var previousStep = 0
    fileprivate var projectionIsCurrent: Bool {
        guard let file, let controls, let snapshot, let presentation else { return false }
        return controls.request(for: file) == snapshot.parseRequest &&
            presentation.configuration == controls.configuration
    }
    fileprivate var projectionID: UUID? { presentation?.id }
    fileprivate var recordCount: Int { snapshot?.index.records.count ?? 0 }

    fileprivate func recordNumber(_ row: Int) -> Int? {
        guard let presentation, presentation.rows.indices.contains(row) else { return nil }
        return presentation.rows[row] + 1
    }

    init() {
        super.init(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        let header = DelimitedHeader(frame: NSRect(x: 0, y: 0, width: 0, height: table.compactRowHeight))
        header.onMenu = { [weak self] column in self?.columnMenu(column) }
        header.onEdit = { [weak self] column in self?.editHeader(column) ?? false }
        header.onClick = { [weak self] column, modifiers in
            self?.selectHeaderColumn(column, modifiers: modifiers)
        }
        header.onTrack = { [weak self] column, track in
            self?.trackColumnReorder(from: column, track) ?? false
        }
        table.headerView = header
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = table.compactRowHeight
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
        table.onClear = { [weak self] in
            guard let self else { return }
            clearSelection()
        }
        table.acceptsGridActions = { [weak self] in self?.projectionIsCurrent == true }
        table.onSelectionChanged = { [weak self] in
            guard let self else { return }
            gutter.needsDisplay = true
        }
        scrollView.documentView = table
        addSubview(scrollView)
        addSubview(gutter)
        applyTheme(Theme.terminal(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = min(gutter.preferredWidth, max(0, bounds.width - 36))
        gutter.frame = CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        let oldViewportSize = scrollView.contentView.bounds.size
        scrollView.frame = CGRect(x: bounds.minX + width, y: bounds.minY,
                                  width: bounds.width - width, height: bounds.height)
        if scrollView.contentView.bounds.size != oldViewportSize {
            table.tile()
        }
        gutter.needsDisplay = true
        updateHeaderHeight()
        if let edit = editing { layoutEditor(edit) }
    }

    @objc private func viewportChanged(_ notification: Notification) {
        guard !table.updatingColumns else { return }
        table.refreshViewportColumns()
        gutter.needsDisplay = true
        table.refreshHover()
        if let edit = editing { layoutEditor(edit) }
    }

    func applyTheme(_ theme: GhosttyThemeDefinition) {
        guard self.theme != theme else { return }
        self.theme = theme
        table.palette = DelimitedPalette(theme)
        scrollView.backgroundColor = palette.background
        scrollView.contentView.backgroundColor = palette.background
        table.backgroundColor = palette.background
        table.headerView?.needsDisplay = true
        gutter.needsDisplay = true
        table.refreshSelection()
        if let edit = editing { styleEditor(edit) }
    }

    private var fontScale: CGFloat { DelimitedCellLayout.scale(for: table.cellFont.pointSize) }

    func applyFontSize(_ size: CGFloat) {
        guard table.cellFont.pointSize != size else { return }
        let previousScale = fontScale
        let origin = scrollView.contentView.bounds.origin
        let topRow = table.row(at: NSPoint(x: max(0, origin.x), y: origin.y))
        let oldRect = topRow >= 0 ? table.rect(ofRow: topRow) : .zero
        let rowFraction = oldRect.height > 0 ? (origin.y - oldRect.minY) / oldRect.height : 0
        // Changing thousands of column widths with live rows repeatedly lays out
        // those rows. Reuse the existing projection after installing its geometry.
        let currentPresentation = presentation
        presentation = nil
        table.reloadData()
        table.updateFonts(size: size)
        let scale = fontScale
        let ratio = scale / previousScale
        table.updateColumns {
            for column in table.tableColumns {
                // Capture the width before AppKit clamps it to the new minimum.
                let width = column.width * ratio
                let maximum = column.maxWidth * ratio
                column.minWidth = 0
                column.maxWidth = maximum
                column.minWidth = DelimitedCellLayout.minimumColumnWidth(scale: scale)
                if currentPresentation == nil { column.width = width }
            }
            if let snapshot, let currentPresentation {
                installColumns(index: snapshot.index, configuration: currentPresentation.configuration)
            }
        }
        presentation = currentPresentation
        table.rowHeight = table.compactRowHeight
        // Font changes invalidate every row height. The active input is independent of reused cells.
        table.reloadData()
        updateHeaderHeight()
        needsLayout = true
        scrollView.tile()
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let newRect = topRow >= 0 && topRow < table.numberOfRows ? table.rect(ofRow: topRow) : .zero
        let y = newRect.minY + rowFraction * newRect.height
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: CGPoint(x: origin.x * ratio, y: y),
                                                         size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        table.syncSelection()
        gutter.needsDisplay = true
        if let edit = editing { styleEditor(edit) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endEditingForProjectionChange() }
        super.viewWillMove(toWindow: newWindow)
    }

    // The view and its first responder survive re-indexing; stale rows, selection
    // and pending clipboard work do not.
    func clearProjection() {
        guard snapshot != nil || presentation != nil else { return }
        endEditingForProjectionChange()
        copyTask?.cancel()
        copyTask = nil
        table.clearSelection()
        snapshot = nil
        presentation = nil
        source = ""
        previousMatches = []
        table.reloadData()
        needsLayout = true
    }

    func detach() {
        clearProjection()
        file = nil
        table.onFocused = {}
        onFilter = { _, _ in }
    }

    func install(_ snapshot: FileTab.DelimitedSnapshot, presentation: DelimitedTablePresentation) {
        guard presentation.id != self.presentation?.id else { return }
        endEditingForProjectionChange()
        let move = controls?.columnMove.flatMap { change in
            change.before == self.snapshot?.documentRevision && change.after == snapshot.documentRevision
                ? change.positions : nil
        }
        let previousRows = (move != nil || self.snapshot?.documentRevision == snapshot.documentRevision) &&
            self.snapshot?.index.separator == snapshot.index.separator ? self.presentation?.rows : nil
        let rebuildColumns = self.snapshot?.requestID != snapshot.requestID ||
            self.snapshot?.index.separator != snapshot.index.separator
        let previousConfiguration = self.presentation?.configuration ?? .init()
        let configuration = presentation.configuration
        self.snapshot = snapshot
        source = snapshot.source as NSString
        if rebuildColumns {
            self.presentation = nil
            table.reloadData()
            table.updateColumns {
                installColumns(index: snapshot.index, configuration: configuration)
            }
        } else if previousConfiguration != configuration {
            table.updateColumns {
                let columns = table.tableColumns
                for (index, column) in columns.enumerated() {
                    guard controls?.columnWidths[index] == nil,
                          DelimitedCellLayout.headerSymbols(previousConfiguration, column: index).count !=
                            DelimitedCellLayout.headerSymbols(configuration, column: index).count else { continue }
                    column.width = fittedWidth(index, title: column.title, index: snapshot.index,
                                               configuration: configuration, samplesPerColumn: 4096 / columns.count)
                }
            }
        }
        self.presentation = presentation
        for (column, item) in table.tableColumns.enumerated() {
            let sorted = presentation.configuration.sort.first { $0.column == column }
            item.headerCell.setAccessibilitySortDirection(sorted.map { $0.ascending ? .ascending : .descending } ?? .unknown)
        }
        previousMatches = []
        table.reloadData()
        if let previousRows {
            table.remapRows(from: previousRows, to: presentation.rows, columns: move)
        } else {
            table.clearSelection()
        }
        controls?.finishColumnMove()
        table.headerView?.needsDisplay = true
        needsLayout = true
        if let target = controls?.pendingSelection {
            controls?.pendingSelection = nil
            restoreSelection(target)
        }
    }

    private func installColumns(index: DelimitedTableIndex, configuration: DelimitedTablePresentation.Configuration) {
        let count = min(index.columnCount, DelimitedTableIndex.maximumColumns)
        let columns = table.tableColumns
        for column in columns.dropFirst(count) { table.removeTableColumn(column) }
        for columnIndex in 0..<count {
            let isNewColumn = columnIndex >= columns.count
            let column: NSTableColumn
            if !isNewColumn {
                column = columns[columnIndex]
            } else {
                column = NSTableColumn(identifier: .init(String(columnIndex)))
                column.maxWidth *= fontScale
                column.minWidth = DelimitedCellLayout.minimumColumnWidth(scale: fontScale)
                column.headerCell = DelimitedColumnHeader(textCell: "")
            }
            let title = DelimitedTablePresentation.value(in: source, index: index, record: 0, column: columnIndex, limit: DelimitedTableIndex.displayLimit)
            if column.title != title { column.title = title }
            if let width = controls?.columnWidths[columnIndex] {
                column.width = width * fontScale
            } else {
                column.width = fittedWidth(columnIndex, title: title, index: index,
                                           configuration: configuration, samplesPerColumn: 4096 / count)
            }
            if isNewColumn { table.addTableColumn(column) }
        }
    }

    private func fittedWidth(_ column: Int, title: String, index: DelimitedTableIndex,
                             configuration: DelimitedTablePresentation.Configuration, samplesPerColumn: Int) -> CGFloat {
        let padding = 2 * DelimitedCellLayout.horizontalPadding(scale: fontScale)
        let marker = CGFloat(DelimitedCellLayout.headerSymbols(configuration, column: column).count)
            * DelimitedCellLayout.headerMarkerWidth(scale: fontScale)
        var width = DelimitedCellLayout.textWidth(String(title.prefix(128)), font: table.columnTitleFont) + marker
        let rows = max(0, index.records.count - 1)
        let samples = min(rows, 48, samplesPerColumn)
        for sample in 0..<samples {
            let row = samples == 1 ? 0 : sample * (rows - 1) / (samples - 1)
            guard let field = index.field(record: 1 + row, column: column) else { continue }
            let value = field.value(in: source, limit: 128)
            width = max(width, DelimitedCellLayout.textWidth(value, font: table.cellFont))
        }
        return max(DelimitedCellLayout.minimumColumnWidth(scale: fontScale), ceil(width + padding + 1))
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !table.updatingColumns, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              let index = Int(column.identifier.rawValue) else { return }
        controls?.columnWidths[index] = column.width / fontScale
        if let edit = editing { styleEditor(edit) }
    }

    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
        guard let snapshot else { return tableView.tableColumns[column].width }
        return fittedWidth(column, title: tableView.tableColumns[column].title, index: snapshot.index,
                           configuration: presentation?.configuration ?? .init(),
                           samplesPerColumn: 48)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { presentation?.rows.count ?? 0 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let presentation, let snapshot, presentation.rows.indices.contains(row) else { return table.rowHeight }
        let lines = snapshot.index.records[presentation.rows[row]].displayLineCount
        return lines == 1 ? table.rowHeight : table.height(lines: lines)
    }

    private func updateHeaderHeight() {
        guard let header = table.headerView else { return }
        let lines = snapshot?.index.records.first?.displayLineCount ?? 1
        // A large header must not consume the data viewport. The inline editor still opens its full value.
        let height = min(table.height(lines: lines), max(table.rowHeight, bounds.height / 3))
        if header.frame.height != height {
            header.setFrameSize(NSSize(width: header.frame.width, height: height))
            scrollView.tile()
        }
        header.needsDisplay = true
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let column = Int(tableColumn.identifier.rawValue) else { return }
        selectHeaderColumn(column, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
    }

    private func selectHeaderColumn(_ column: Int, modifiers: NSEvent.ModifierFlags) {
        guard projectionIsCurrent else { return }
        table.window?.makeFirstResponder(table)
        table.selectColumn(column, modifiers: modifiers)
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, let columnIndex = Int(column.identifier.rawValue),
              table.viewportColumns.contains(columnIndex) else { return nil }
        let cell = DelimitedTablePresentation.Cell(row: row, column: columnIndex)
        let cellID = NSUserInterfaceItemIdentifier("bailey.csv.cell")
        let label = tableView.makeView(withIdentifier: cellID, owner: self) as? DelimitedCellField
            ?? DelimitedCellField(frame: .zero)
        label.identifier = cellID
        displayValue(in: label, at: cell)
        table.style(label, cell: cell)
        return label
    }

    private func displayValue(in label: DelimitedCellField, at cell: DelimitedTablePresentation.Cell) {
        let field = physicalCell(cell).flatMap { snapshot?.index.field(record: $0.row, column: $0.column) }
        let value = field?.value(in: source, limit: DelimitedTableIndex.displayLimit) ?? ""
        label.isNumeric = field.map { $0.contentRange(in: source).length <= DelimitedTableIndex.displayLimit } == true &&
            DelimitedTablePresentation.finiteNumber(value) != nil
        label.stringValue = value
    }

    private func value(_ cell: DelimitedTablePresentation.Cell, limit: Int? = nil) -> String {
        guard let snapshot, let presentation, presentation.rows.indices.contains(cell.row) else { return "" }
        return DelimitedTablePresentation.value(
            in: source, index: snapshot.index, record: presentation.rows[cell.row], column: cell.column, limit: limit
        )
    }

    func selectedFieldValue() -> String? {
        guard projectionIsCurrent, let cell = table.selection.caret else { return nil }
        return value(cell)
    }

    func acceptsProjection(_ id: UUID) -> Bool { projectionIsCurrent && presentation?.id == id }

    func showMatch(_ matches: [DelimitedTablePresentation.Cell], step: Int) {
        guard projectionIsCurrent else { return }
        let changed = matches != previousMatches
        let delta = step &- previousStep
        previousMatches = matches
        previousStep = step
        guard !matches.isEmpty, delta != 0 || (changed && controls?.showsFind == true) else { return }

        let caret = table.selection.caret
        let start: Int
        if delta < 0 {
            start = caret.flatMap { cell in
                matches.lastIndex { ($0.row, $0.column) < (cell.row, cell.column) }
            } ?? matches.count - 1
        } else {
            start = caret.flatMap { cell in
                matches.firstIndex {
                    ($0.row, $0.column) > (cell.row, cell.column) || (delta == 0 && $0 == cell)
                }
            } ?? 0
        }
        let offset = delta == 0 ? 0 : (delta - (delta > 0 ? 1 : -1)) % matches.count
        table.select(matches[(start + offset + matches.count) % matches.count], reveal: true)
    }

    private func physicalCell(_ cell: DelimitedTablePresentation.Cell) -> DelimitedTablePresentation.Cell? {
        guard let presentation, presentation.rows.indices.contains(cell.row),
              (0..<table.numberOfColumns).contains(cell.column) else { return nil }
        return .init(row: presentation.rows[cell.row], column: cell.column)
    }

    private func beginEditing(_ cell: DelimitedTablePresentation.Cell) {
        guard projectionIsCurrent, editing == nil, let physical = physicalCell(cell) else { return }
        table.select(cell, reveal: true)
        table.layoutSubtreeIfNeeded()
        beginField(physical, displayed: cell, selecting: .cell(physical))
    }

    private func editHeader(_ column: Int) -> Bool {
        guard projectionIsCurrent, editing == nil, table.tableColumns.indices.contains(column) else { return false }
        table.scrollColumnToVisible(column)
        beginField(.init(row: 0, column: column), displayed: nil, selecting: .column(column))
        return editing != nil
    }

    private func beginField(_ physical: DelimitedTablePresentation.Cell,
                            displayed: DelimitedTablePresentation.Cell?, selecting selection: DelimitedTableControls.PendingSelection) {
        guard editing == nil, let window, let file, let snapshot,
              let field = snapshot.index.field(record: physical.row, column: physical.column) else { return }
        let editable = file.canEditDelimited(snapshot)
        if editable, !file.beginDelimitedEditing(in: self, using: snapshot) { return }
        let original = field.value(in: source)
        let editor = NSTextView(usingTextLayoutManager: true)
        editor.isEditable = editable
        editor.isSelectable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.string = original
        editor.delegate = self
        editor.setAccessibilityIdentifier(displayed == nil ? "bailey.csv.header.editor" : "bailey.csv.cell.editor")
        let input = NSScrollView()
        input.borderType = .noBorder
        input.hasVerticalScroller = true
        input.autohidesScrollers = true
        input.wantsLayer = true
        input.documentView = editor
        let edit = CellEdit(editor: editor, scroll: input, displayed: displayed, snapshot: snapshot,
                            physical: physical, original: original, selection: selection, editable: editable)
        editing = edit
        addSubview(input, positioned: .above, relativeTo: scrollView)
        styleEditor(edit)
        guard window.makeFirstResponder(editor) else { cancelEditing(); return }
        editor.selectAll(nil)
        editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func styleEditor(_ edit: CellEdit) {
        let editor = edit.editor
        let font = edit.displayed == nil ? table.columnTitleFont : table.cellFont
        if !editor.hasMarkedText(), editor.font != font { editor.font = font }
        editor.backgroundColor = palette.input
        editor.textColor = palette.text
        editor.insertionPointColor = palette.focus
        editor.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.selectedText]
        editor.textContainerInset = NSSize(width: DelimitedCellLayout.horizontalPadding(scale: fontScale),
                                           height: DelimitedCellLayout.verticalPadding(scale: fontScale))
        edit.scroll.backgroundColor = palette.input
        edit.scroll.layer?.borderColor = palette.focus.cgColor
        edit.scroll.layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 1)
        layoutEditor(edit)
    }

    private func layoutEditor(_ edit: CellEdit) {
        let clip = scrollView.contentView
        var viewport = convert(clip.bounds, from: clip)
        let cell: NSRect
        if let displayed = edit.displayed {
            guard displayed.row < table.numberOfRows, displayed.column < table.numberOfColumns else { return }
            cell = convert(table.frameOfCell(atColumn: displayed.column, row: displayed.row), from: table)
        } else {
            guard let header = table.headerView, table.tableColumns.indices.contains(edit.physical.column) else { return }
            cell = convert(header.headerRect(ofColumn: edit.physical.column), from: header)
            viewport = viewport.union(convert(header.bounds, from: header).intersection(scrollView.frame))
        }
        guard viewport.width > 0, viewport.height > 0 else { return }
        let x = min(max(viewport.minX, cell.minX), max(viewport.minX, viewport.maxX - min(cell.width, viewport.width)))
        let top = min(max(viewport.minY + min(cell.height, viewport.height), cell.maxY), viewport.maxY)
        let availableWidth = max(1, viewport.maxX - x)
        let availableHeight = max(1, top - viewport.minY)
        let editor = edit.editor
        let font = editor.font ?? table.cellFont
        let inset = editor.textContainerInset
        let size: NSSize
        if let storage = editor.textStorage, storage.length <= DelimitedTableIndex.displayLimit {
            let value = storage.string
            let width = min(availableWidth, max(cell.width, ceil(DelimitedCellLayout.textWidth(value, font: font) + 2 * inset.width + 2)))
            let textWidth = max(1, width - 2 * inset.width)
            let textHeight = (value as NSString).boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
            let lines = DelimitedCellLayout.lines(value).count
            let height = max(cell.height, ceil(max(textHeight + 2 * inset.height + 1, table.height(lines: lines))))
            size = NSSize(width: width, height: min(availableHeight, height))
        } else {
            // Long values remain fully editable in the native scrolling text view without measuring the entire field on each key.
            size = NSSize(width: availableWidth, height: availableHeight)
        }
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        if edit.scroll.frame != frame { edit.scroll.frame = frame }
        let contentSize = edit.scroll.contentSize
        editor.minSize = NSSize(width: contentSize.width, height: contentSize.height)
        editor.maxSize = NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        if editor.frame.width != contentSize.width || editor.frame.height < contentSize.height {
            editor.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, editor.frame.height)))
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let edit = editing, notification.object as? NSTextView === edit.editor else { return }
        layoutEditor(edit)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editing?.undo }

    func finishEditing() {
        guard let edit = editing, !edit.editor.hasMarkedText() else { return }
        completeEditing(edit, returnFocus: true)
    }

    private func endEditingForProjectionChange() {
        finishEditing()
        guard let edit = editing else { return }
        if edit.editable { file?.retainDelimitedEditing(in: self, draft: edit.draft(value: edit.editor.string)) }
        cancelEditing()
    }

    private func removeEditor(_ edit: CellEdit, returnFocus: Bool) {
        editing = nil
        edit.editor.delegate = nil
        if returnFocus, window?.firstResponder === edit.editor { window?.makeFirstResponder(table) }
        edit.scroll.removeFromSuperview()
    }

    func cancelEditing() {
        guard let edit = editing else { return }
        if edit.editable { file?.endDelimitedEditing(in: self) }
        removeEditor(edit, returnFocus: true)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let edit = editing, textView === edit.editor, !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEditing()
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if edit.editable { textView.insertText("\n", replacementRange: textView.selectedRange()) }
        case #selector(NSResponder.insertNewline(_:)):
            completeEditing(edit, returnFocus: true)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            completeEditing(edit, movement: commandSelector == #selector(NSResponder.insertBacktab(_:)) ? NSBacktabTextMovement : NSTabTextMovement,
                            returnFocus: true)
        default: return false
        }
        return true
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let edit = editing, notification.object as? NSTextView === edit.editor else { return }
        if edit.editor.hasMarkedText(), edit.editable {
            file?.retainDelimitedEditing(in: self, draft: edit.draft(value: edit.editor.string))
            removeEditor(edit, returnFocus: false)
        } else {
            completeEditing(edit, returnFocus: false)
        }
    }

    private func completeEditing(_ edit: CellEdit, movement: Int? = nil, returnFocus: Bool) {
        let value = edit.editor.string
        removeEditor(edit, returnFocus: returnFocus)
        guard edit.editable else { return }
        var destination = edit.selection
        if let cell = edit.displayed,
           movement == NSTabTextMovement || movement == NSBacktabTextMovement,
           let next = table.adjacent(to: cell, backwards: movement == NSBacktabTextMovement),
           let physical = physicalCell(next) {
            destination = .cell(physical)
        }
        if value.utf16.elementsEqual(edit.original.utf16) {
            file?.endDelimitedEditing(in: self)
            restoreSelection(destination)
            return
        }
        file?.commitDelimitedEditing(in: self, draft: edit.draft(value: value, selecting: destination))
    }

    private func restoreSelection(_ target: DelimitedTableControls.PendingSelection) {
        switch target {
        case .cell(let cell):
            if let row = presentation?.rows.firstIndex(of: cell.row) {
                table.select(.init(row: row, column: cell.column), reveal: true)
            }
        case .column(let column):
            if table.tableColumns.indices.contains(column) {
                table.scrollColumnToVisible(column)
                table.selectColumn(column, modifiers: [])
            }
        }
    }

    /// Read a rectangular TSV clipboard using the same parser as file data.
    /// Literal text (including formulas) is never evaluated or reformatted.
    func paste(_ text: String) {
        guard projectionIsCurrent, let file, let snapshot, let presentation,
              let origin = table.selection.caret, presentation.rows.indices.contains(origin.row) else { return }
        file.submitDelimitedEdit(.paste(text, rows: presentation.rows, origin: origin,
                                        columns: table.numberOfColumns),
                                 using: snapshot,
                                 selecting: .init(row: presentation.rows[origin.row], column: origin.column))
    }

    private struct RecordMenuTarget {
        let projection: UUID
        let row: Int?
        let selection: DelimitedTablePresentation.Selection
    }

    fileprivate func recordMenu(at row: Int?) -> NSMenu? {
        guard projectionIsCurrent, let file, let snapshot, let presentation,
              file.canEditDelimited(snapshot), !file.hasPendingDelimitedEdit else { return nil }
        let target = RecordMenuTarget(projection: presentation.id, row: row, selection: table.selection)
        let menu = NSMenu()
        func item(_ title: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = target
            return item
        }
        let insertion = row == nil ? String(localized: "Insert Row", table: "Editor")
            : String(localized: "Insert Row After", table: "Editor")
        menu.addItem(item(insertion, action: #selector(insertRow(_:))))
        if row != nil {
            menu.addItem(item(String(localized: "Delete Rows", table: "Editor"), action: #selector(deleteRows(_:))))
        }
        return menu
    }

    private func recordTarget(_ sender: NSMenuItem) -> RecordMenuTarget? {
        guard projectionIsCurrent, let target = sender.representedObject as? RecordMenuTarget,
              target.projection == presentation?.id else { return nil }
        return target
    }

    @objc private func insertRow(_ sender: NSMenuItem) {
        guard let target = recordTarget(sender), let snapshot else { return }
        let row = target.row.flatMap { recordNumber($0) } ?? snapshot.index.records.count
        file?.submitDelimitedEdit(.insertRows(before: row, count: 1), using: snapshot,
                                  selecting: .init(row: row, column: 0))
    }

    @objc private func deleteRows(_ sender: NSMenuItem) {
        guard let target = recordTarget(sender), let snapshot, let presentation else { return }
        let rows = Set(target.selection.rows.compactMap { row in
            guard presentation.rows.indices.contains(row),
                  target.selection.columns(in: row).count == table.numberOfColumns else { return nil as Int? }
            return presentation.rows[row]
        })
        guard !rows.isEmpty else { return }
        file?.submitDelimitedEdit(.deleteRows(rows), using: snapshot, selecting: nil)
    }

    private func clearSelection() {
        let selection = table.selection
        guard projectionIsCurrent, !selection.blocks.isEmpty, let snapshot, let presentation else { return }
        let scope = DelimitedTablePresentation.FieldScope(rows: presentation.rows,
                                                          columns: selection.columns, selection: selection)
        file?.submitDelimitedEdit(.clear(scope), using: snapshot)
    }

    private func copySelection() {
        guard projectionIsCurrent, let presentation, let snapshot, !table.selection.blocks.isEmpty else { return }
        copyTask?.cancel()
        let selection = table.selection
        let changeCount = NSPasteboard.general.changeCount
        copyTask = Task { [weak self] in
            guard let value = try? await presentation.copy(selection, source: snapshot.source, index: snapshot.index),
                  !Task.isCancelled, let self, self.presentation?.id == presentation.id, self.projectionIsCurrent,
                  self.window?.isKeyWindow == true, NSPasteboard.general.changeCount == changeCount else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }

    private func columnMenu(_ column: Int) -> NSMenu? {
        guard projectionIsCurrent, let controls, let presentation,
              table.tableColumns.indices.contains(column) else { return nil }
        let menu = NSMenu()
        func item(_ title: String, action: Selector, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.representedObject = presentation.id
            return item
        }
        menu.addItem(item(String(localized: "Sort Ascending", table: "Editor"), action: #selector(sortAscending(_:)), tag: column))
        menu.addItem(item(String(localized: "Sort Descending", table: "Editor"), action: #selector(sortDescending(_:)), tag: column))
        if controls.configuration.sort.contains(where: { $0.column == column }) {
            menu.addItem(item(String(localized: "Clear Column Sort", table: "Editor"), action: #selector(clearSort(_:)), tag: column))
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Filter Column…", table: "Editor"), action: #selector(filter(_:)), tag: column))
        if controls.configuration.filters[column] != nil {
            menu.addItem(item(String(localized: "Clear Column Filter", table: "Editor"), action: #selector(clearFilter(_:)), tag: column))
        }
        if let snapshot, let file, file.canEditDelimited(snapshot), !file.hasPendingDelimitedEdit {
            let count = snapshot.index.columnCount
            if (1...DelimitedTableIndex.maximumColumns).contains(count) {
                menu.addItem(.separator())
                if count < DelimitedTableIndex.maximumColumns {
                    menu.addItem(item(String(localized: "Insert Column Left", table: "Editor"), action: #selector(insertColumnLeft(_:)), tag: column))
                    menu.addItem(item(String(localized: "Insert Column Right", table: "Editor"), action: #selector(insertColumnRight(_:)), tag: column))
                }
                if count > 1 {
                    let selected = table.wholeColumns
                    let columns = selected.contains(column) ? selected : IndexSet(integer: column)
                    if columns.count < count {
                        let deletion = item(String(localized: "Delete Column", table: "Editor"),
                                            action: #selector(deleteColumn(_:)), tag: column)
                        deletion.representedObject = ColumnDeletion(projection: presentation.id, columns: columns)
                        menu.addItem(deletion)
                    }
                }
            }
        }
        return menu
    }

    private struct ColumnDeletion {
        let projection: UUID
        let columns: IndexSet
    }

    private func changeColumns(_ transform: (inout [Int?]) -> Void) {
        guard projectionIsCurrent, let snapshot,
              (1...DelimitedTableIndex.maximumColumns).contains(snapshot.index.columnCount) else { return }
        var order = (0..<snapshot.index.columnCount).map(Optional.some)
        transform(&order)
        guard (1...DelimitedTableIndex.maximumColumns).contains(order.count) else { return }
        file?.submitDelimitedEdit(.columns(order), using: snapshot, selecting: nil)
    }

    @objc private func insertColumnLeft(_ sender: NSMenuItem) {
        if accepts(sender) { changeColumns { $0.insert(nil, at: sender.tag) } }
    }

    @objc private func insertColumnRight(_ sender: NSMenuItem) {
        if accepts(sender) { changeColumns { $0.insert(nil, at: sender.tag + 1) } }
    }

    @objc private func deleteColumn(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ColumnDeletion, target.projection == projectionID else { return }
        changeColumns { order in
            for column in target.columns.reversed() { order.remove(at: column) }
        }
    }

    private var canReorderColumns: Bool {
        guard projectionIsCurrent, editing == nil, let snapshot, let file,
              (2...DelimitedTableIndex.maximumColumns).contains(snapshot.index.columnCount),
              !file.hasPendingDelimitedEdit else { return false }
        return file.canEditDelimited(snapshot)
    }

    // Keep the native table in physical field order throughout the gesture.
    // Only the completed, still-current drop may change the document.
    @discardableResult
    func trackColumnReorder(from column: Int, _ track: (() -> Bool) -> Int?) -> Bool {
        guard canReorderColumns, let projectionID,
              table.tableColumns.indices.contains(column) else { return false }
        let isCurrent = { self.acceptsProjection(projectionID) && self.canReorderColumns }
        guard let destination = track(isCurrent), destination != column,
              isCurrent(), table.tableColumns.indices.contains(destination) else { return true }
        table.window?.makeFirstResponder(table)
        guard isCurrent() else { return true }
        changeColumns { order in
            let moved = order.remove(at: column)
            order.insert(moved, at: destination)
        }
        return true
    }

    private func accepts(_ sender: NSMenuItem) -> Bool {
        guard let id = sender.representedObject as? UUID else { return false }
        return projectionIsCurrent && presentation?.id == id
    }

    @objc private func filter(_ sender: NSMenuItem) {
        guard accepts(sender), let snapshot, let presentation else { return }
        onFilter(sender.tag, .init(parse: snapshot.parseRequest, configuration: presentation.configuration))
    }

    @objc private func sortAscending(_ sender: NSMenuItem) { sort(sender, ascending: true) }
    @objc private func sortDescending(_ sender: NSMenuItem) { sort(sender, ascending: false) }

    private func sort(_ sender: NSMenuItem, ascending: Bool) {
        guard accepts(sender), let controls else { return }
        let rest = controls.configuration.sort.filter { $0.column != sender.tag }
        controls.configuration.sort = [.init(column: sender.tag, ascending: ascending)] + rest
    }

    @objc private func clearSort(_ sender: NSMenuItem) {
        guard accepts(sender) else { return }
        controls?.configuration.sort.removeAll { $0.column == sender.tag }
    }

    @objc private func clearFilter(_ sender: NSMenuItem) {
        guard accepts(sender) else { return }
        controls?.configuration.filters.removeValue(forKey: sender.tag)
    }
}

private final class DelimitedRecordGutter: NSView {
    private weak var grid: DelimitedGrid?
    private var font: NSFont { grid?.table.recordFont ?? .monospacedSystemFont(ofSize: 10, weight: .regular) }
    override var isFlipped: Bool { true }

    init(grid: DelimitedGrid) {
        self.grid = grid
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Record Numbers", table: "Editor"))
        setAccessibilityIdentifier("bailey.csv.records")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var preferredWidth: CGFloat {
        let digits = String(grid?.recordCount ?? 0).count
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let numberWidth = ("0" as NSString).size(withAttributes: attributes).width * CGFloat(digits)
        let padding = DelimitedCellLayout.horizontalPadding(scale: DelimitedCellLayout.scale(for: grid?.table.cellFont.pointSize ?? 11))
        return ceil(max(numberWidth, ("#" as NSString).size(withAttributes: attributes).width) + 2 * padding)
    }

    private var headerRect: NSRect {
        guard let header = grid?.table.headerView else { return .zero }
        let geometry = convert(header.bounds, from: header)
        return NSRect(x: 0, y: geometry.minY, width: bounds.width, height: geometry.height)
    }

    private var viewport: NSRect {
        guard let clip = grid?.scrollView.contentView else { return .zero }
        let geometry = convert(clip.bounds, from: clip)
        return NSRect(x: 0, y: geometry.minY, width: bounds.width, height: geometry.height).intersection(bounds)
    }

    private func rowRect(_ row: Int, in table: NSTableView) -> NSRect {
        let geometry = convert(table.rect(ofRow: row), from: table)
        return NSRect(x: 0, y: geometry.minY, width: bounds.width, height: geometry.height)
    }

    private func visibleRows(in table: NSTableView) -> Range<Int> {
        let range = table.rows(in: table.visibleRect)
        return range.location == NSNotFound ? 0..<0 : range.location..<NSMaxRange(range)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid else { return }
        let palette = grid.palette
        let table = grid.table
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        palette.background.setFill()
        dirtyRect.intersection(bounds).fill()
        func label(_ title: String, in rect: NSRect, color: NSColor) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (title as NSString).size(withAttributes: attributes)
            let padding = DelimitedCellLayout.horizontalPadding(scale: DelimitedCellLayout.scale(for: table.cellFont.pointSize))
            (title as NSString).draw(at: NSPoint(x: max(0, rect.maxX - size.width - padding),
                                                 y: floor(rect.minY + min(rect.height, table.rowHeight) / 2 - size.height / 2)),
                                     withAttributes: attributes)
            palette.grid.setFill()
            NSRect(x: 0, y: rect.maxY - pixel, width: rect.width, height: pixel).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: viewport).addClip()
        for row in visibleRows(in: table) {
            guard let number = grid.recordNumber(row) else { continue }
            let rect = rowRect(row, in: table)
            guard rect.intersects(dirtyRect) else { continue }
            let selected = table.selection.columns(in: row).count == table.numberOfColumns
            if selected {
                (window?.isKeyWindow == true ? palette.selection : palette.inactiveSelection).setFill()
                rect.fill()
            }
            label(String(number), in: rect, color: selected ? palette.selectedText : palette.recordText)
        }
        NSGraphicsContext.restoreGraphicsState()
        label("#", in: headerRect, color: palette.recordText)
        palette.grid.setFill()
        NSRect(x: bounds.maxX - pixel, y: bounds.minY, width: pixel, height: bounds.height).fill()
    }

    private func row(at point: NSPoint, in table: NSTableView) -> Int? {
        guard viewport.contains(point) else { return nil }
        let point = table.convert(point, from: self)
        let row = table.row(at: NSPoint(x: table.visibleRect.midX, y: point.y))
        return row >= 0 ? row : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let grid, grid.projectionIsCurrent else { return }
        let point = convert(event.locationInWindow, from: nil)
        if headerRect.contains(point) {
            activate(nil, modifiers: event.modifierFlags)
        } else if let row = row(at: point, in: grid.table) {
            activate(row, modifiers: event.modifierFlags)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let grid, grid.projectionIsCurrent else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        if grid.table.numberOfRows == 0, headerRect.contains(point) {
            return grid.recordMenu(at: nil)
        }
        guard let row = row(at: point, in: grid.table) else { return nil }
        if grid.table.selection.columns(in: row).count != grid.table.numberOfColumns {
            guard activate(row, modifiers: []) else { return nil }
        } else {
            window?.makeFirstResponder(grid.table)
        }
        return grid.recordMenu(at: row)
    }

    @discardableResult
    private func activate(_ row: Int?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let grid, grid.projectionIsCurrent, grid.table.numberOfRows > 0 else { return false }
        if let row, !visibleRows(in: grid.table).contains(row) { return false }
        window?.makeFirstResponder(grid.table)
        if let row { grid.table.selectRecord(row, modifiers: modifiers) } else { grid.table.selectAll(nil) }
        return true
    }

    override func accessibilityChildren() -> [Any]? {
        guard let grid, let window, grid.projectionIsCurrent else { return [] }
        let selected = grid.table.selection
        let projection = grid.projectionID
        func element(_ title: String, frame: NSRect, row: Int?) -> DelimitedRecordAXElement {
            let button = DelimitedRecordAXElement { [weak self] in
                guard let self, self.grid?.projectionID == projection else { return false }
                return self.activate(row, modifiers: [])
            }
            button.setAccessibilityRole(.button)
            button.setAccessibilityLabel(title)
            button.setAccessibilityParent(self)
            button.setAccessibilityFrame(window.convertToScreen(convert(frame, to: nil)))
            button.setAccessibilityEnabled(grid.table.numberOfRows > 0)
            if let row {
                button.setAccessibilitySelected(selected.columns(in: row).count == grid.table.numberOfColumns)
            }
            return button
        }
        let all = element(String(localized: "Select All Cells", table: "Editor"), frame: headerRect, row: nil)
        return [all] + visibleRows(in: grid.table).compactMap { row in
            guard let number = grid.recordNumber(row) else { return nil }
            let frame = rowRect(row, in: grid.table).intersection(viewport)
            guard !frame.isEmpty else { return nil }
            return element(String(localized: "Record \(number)", table: "Editor"), frame: frame, row: row)
        }
    }
}

private nonisolated final class DelimitedRecordAXElement: NSAccessibilityElement {
    private let press: @MainActor @Sendable () -> Bool

    init(press: @escaping @MainActor @Sendable () -> Bool) {
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated(press)
    }
}

private final class DelimitedHeader: NSTableHeaderView {
    var onMenu: (Int) -> NSMenu? = { _ in nil }
    var onEdit: (Int) -> Bool = { _ in false }
    var onClick: (Int, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onTrack: (Int, (() -> Bool) -> Int?) -> Bool = { _, _ in false }
    private var dropMarker: NSRect?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = column(at: point)
        // Dividers retain AppKit's native resize and double-click fit behavior.
        guard column >= 0, headerRect(ofColumn: column).insetBy(dx: 4, dy: 0).contains(point) else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2, onEdit(column) { return }
        if !onTrack(column, { isCurrent in
            trackDrop(from: column, event: event, isCurrent: isCurrent)
        }) {
            super.mouseDown(with: event)
        }
    }

    private func trackDrop(from source: Int, event: NSEvent, isCurrent: () -> Bool) -> Int? {
        guard let window, let table = tableView, let scroll = table.enclosingScrollView else { return nil }
        let origin = event.locationInWindow
        var pointer = origin
        var dragging = false
        var lastScroll = ContinuousClock.now
        defer { setDropMarker(nil) }
        while isCurrent(), self.window === window, tableView === table {
            // A bounded wait also permits horizontal scrolling when the pointer stops at an edge.
            let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                       until: Date(timeIntervalSinceNow: dragging ? 1 / 30 : 0.1),
                                       inMode: .eventTracking, dequeue: true)
            guard isCurrent(), self.window === window else { return nil }
            if let next {
                if next.type == .keyDown {
                    if next.keyCode == 53 { return nil }
                    continue
                }
                guard next.windowNumber == window.windowNumber else { return nil }
                pointer = next.locationInWindow
                if next.type == .leftMouseUp {
                    if !dragging {
                        if headerRect(ofColumn: source).contains(convert(pointer, from: nil)) {
                            onClick(source, event.modifierFlags)
                        }
                        return nil
                    }
                    return drop(at: convert(pointer, from: nil), from: source)?.destination
                }
                dragging = dragging || abs(pointer.x - origin.x) >= 4 || abs(pointer.y - origin.y) >= 4
            }
            guard dragging else { continue }
            let now = ContinuousClock.now
            if lastScroll.duration(to: now) >= .milliseconds(33) {
                scrollAtEdge(convert(pointer, from: nil), in: scroll)
                lastScroll = now
            }
            let target = drop(at: convert(pointer, from: nil), from: source)
            setDropMarker(target.flatMap { $0.destination == source ? nil : $0.marker })
        }
        return nil
    }

    private func drop(at point: NSPoint, from source: Int) -> (destination: Int, marker: NSRect)? {
        guard let table = tableView, table.numberOfColumns > 0, visibleRect.contains(point) else { return nil }
        let hit = column(at: point)
        let boundary: Int
        let x: CGFloat
        if hit >= 0 {
            let rect = headerRect(ofColumn: hit)
            let before = point.x < rect.midX
            boundary = before ? hit : hit + 1
            x = before ? rect.minX : rect.maxX
        } else {
            let last = headerRect(ofColumn: table.numberOfColumns - 1)
            guard point.x >= last.maxX else { return nil }
            boundary = table.numberOfColumns
            x = last.maxX
        }
        let destination = boundary > source ? boundary - 1 : boundary
        let marker = NSRect(x: x - 1, y: bounds.minY, width: 2, height: bounds.height)
        return (destination, marker)
    }

    private func scrollAtEdge(_ point: NSPoint, in scroll: NSScrollView) {
        let visible = visibleRect
        guard (visible.minY...visible.maxY).contains(point.y) else { return }
        let margin = min(24, visible.width / 4)
        let delta = point.x < visible.minX + margin ? -min(24, visible.minX + margin - point.x)
            : max(0, min(24, point.x - visible.maxX + margin))
        guard delta != 0 else { return }
        let clip = scroll.contentView
        let old = clip.bounds
        let next = clip.constrainBoundsRect(old.offsetBy(dx: delta, dy: 0)).origin
        guard next.x != old.minX else { return }
        clip.scroll(to: next)
        scroll.reflectScrolledClipView(clip)
    }

    private func setDropMarker(_ marker: NSRect?) {
        guard dropMarker != marker else { return }
        if let dropMarker { setNeedsDisplay(dropMarker) }
        dropMarker = marker
        if let marker { setNeedsDisplay(marker) }
        displayIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let table = tableView as? DelimitedNativeTable else { return }
        table.palette.background.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
        table.palette.grid.setFill()
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        NSRect(x: bounds.minX, y: bounds.maxY - pixel, width: bounds.width, height: pixel).fill()
        if let dropMarker {
            table.palette.focus.setFill()
            dropMarker.fill()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu(column(at: convert(event.locationInWindow, from: nil)))
    }
}

fileprivate enum DelimitedCellLayout {
    static func scale(for size: CGFloat) -> CGFloat { size / CGFloat(FontSizeRole.table.defaultSize) }
    static func horizontalPadding(scale: CGFloat) -> CGFloat { 4 * scale }
    static func verticalPadding(scale: CGFloat) -> CGFloat { 2 * scale }
    static func minimumColumnWidth(scale: CGFloat) -> CGFloat { 24 * scale }
    static func headerMarkerWidth(scale: CGFloat) -> CGFloat { 11 * scale }

    static func headerSymbols(_ configuration: DelimitedTablePresentation.Configuration, column: Int) -> [String] {
        var symbols: [String] = []
        if let direction = configuration.sort.first(where: { $0.column == column }) {
            symbols.append(direction.ascending ? "chevron.up" : "chevron.down")
        }
        if configuration.filters[column]?.isEmpty == false {
            symbols.append("line.3.horizontal.decrease")
        }
        return symbols
    }

    static func lines(_ value: String) -> [Substring] { value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) }

    static func textWidth(_ value: String, font: NSFont) -> CGFloat {
        lines(value).map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }

    static func lineHeight(font: NSFont, header: NSFont, records: NSFont) -> CGFloat {
        let layout = NSLayoutManager()
        let line = max(layout.defaultLineHeight(for: font), layout.defaultLineHeight(for: header),
                       layout.defaultLineHeight(for: records))
        return ceil(line) + 1
    }

    static func rowHeight(lines: Int, lineHeight: CGFloat, scale: CGFloat) -> CGFloat {
        ceil(CGFloat(max(1, lines)) * lineHeight + 2 * verticalPadding(scale: scale))
    }

    static func draw(_ value: String, font: NSFont, color: NSColor, in rect: NSRect, lineHeight: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect).addClip()
        for (index, line) in lines(value).enumerated() {
            let y = rect.minY + CGFloat(index) * lineHeight
            guard y < rect.maxY else { break }
            let label = NSAttributedString(string: String(line), attributes: attributes)
            let height = ceil(label.size().height)
            label.draw(with: NSRect(x: rect.minX, y: y + max(0, floor((lineHeight - height) / 2)),
                                    width: rect.width, height: height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    static func textRect(in bounds: NSRect, scale: CGFloat) -> NSRect {
        bounds.insetBy(dx: min(horizontalPadding(scale: scale), bounds.width / 4),
                       dy: min(verticalPadding(scale: scale), bounds.height / 4))
    }
}

private final class DelimitedColumnHeader: NSTableHeaderCell {

    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        guard let table = (controlView as? NSTableHeaderView)?.tableView as? DelimitedNativeTable else { return }
        let palette = table.palette
        palette.background.setFill()
        frame.fill()
        let pixel = 1 / (controlView.window?.backingScaleFactor ?? 1)
        palette.grid.setFill()
        NSRect(x: frame.maxX - pixel, y: frame.minY, width: pixel, height: frame.height).fill()
        let column = table.column(at: NSPoint(x: frame.midX, y: 0))
        let symbols = DelimitedCellLayout.headerSymbols(table.file?.delimitedTable.configuration ?? .init(), column: column)
        let scale = DelimitedCellLayout.scale(for: table.cellFont.pointSize)
        var textRect = DelimitedCellLayout.textRect(in: frame, scale: scale)
        let marker = min(DelimitedCellLayout.headerMarkerWidth(scale: scale),
                         textRect.width / CGFloat(max(1, symbols.count)))
        for name in symbols {
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [palette.focus]))
            let size = min(8 * scale, marker, textRect.height)
            symbol?.draw(in: NSRect(x: textRect.maxX - size, y: frame.midY - size / 2, width: size, height: size))
            textRect.size.width -= marker
        }
        DelimitedCellLayout.draw(stringValue, font: table.columnTitleFont, color: palette.text,
                                 in: textRect, lineHeight: table.textLineHeight)
    }
}

fileprivate final class DelimitedCellField: NSTextField {
    var lineHeight: CGFloat = 14
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
        cell?.usesSingleLineMode = false
        cell?.isScrollable = false
        isEditable = false
        isSelectable = false
        isBordered = false
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The table owns cell geometry, not the intrinsic size of its displayed text.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func draw(_ dirtyRect: NSRect) {
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
        DelimitedCellLayout.textRect(in: rect, scale: DelimitedCellLayout.scale(for: font?.pointSize ?? 11))
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let font, let textColor else { return }
        guard let field = controlView as? DelimitedCellField else { return }
        DelimitedCellLayout.draw(stringValue, font: font, color: textColor,
                                 in: drawingRect(forBounds: cellFrame), lineHeight: field.lineHeight)
    }
}

fileprivate struct DelimitedPalette {
    let background: NSColor
    let text: NSColor
    let numeric: NSColor
    let recordText: NSColor
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
        recordText = Self.readable(theme.surfaceNSColor(elevation: 0.57), on: canvas, toward: foreground, ratio: 4.5)
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
    fileprivate var cellFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    fileprivate var columnTitleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    fileprivate var recordFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    fileprivate lazy var textLineHeight = DelimitedCellLayout.lineHeight(font: cellFont, header: columnTitleFont, records: recordFont)

    fileprivate func updateFonts(size: CGFloat) {
        cellFont = .monospacedSystemFont(ofSize: size, weight: .regular)
        columnTitleFont = .systemFont(ofSize: size, weight: .medium)
        recordFont = .monospacedSystemFont(ofSize: size * 10 / 11, weight: .regular)
        textLineHeight = DelimitedCellLayout.lineHeight(font: cellFont, header: columnTitleFont, records: recordFont)
    }
    fileprivate var compactRowHeight: CGFloat { height(lines: 1) }
    fileprivate func height(lines: Int) -> CGFloat {
        DelimitedCellLayout.rowHeight(lines: lines, lineHeight: textLineHeight, scale: DelimitedCellLayout.scale(for: cellFont.pointSize))
    }

    typealias Cell = DelimitedTablePresentation.Cell
    fileprivate lazy var palette = DelimitedPalette(
        Theme.terminal(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    )
    private var hoverArea: NSTrackingArea?
    private var hoveredCell: Cell?
    // AppKit reuses rows, but asks for every column of each realized row.
    // Materialize only viewport cells and invalidate the columns crossing its edge.
    fileprivate private(set) var viewportColumns = IndexSet()
    fileprivate private(set) var updatingColumns = false

    // AppKit retiles on every added or resized column; publish the final geometry once.
    fileprivate func updateColumns(_ update: () -> Void) {
        updatingColumns = true
        defer { updatingColumns = false }
        update()
        super.tile()
    }

    override func tile() {
        if !updatingColumns { super.tile() }
    }

    override func reloadData() {
        viewportColumns = columnIndexes(in: visibleRect)
        super.reloadData()
    }

    override func layout() {
        refreshViewportColumns()
        super.layout()
    }

    fileprivate func refreshViewportColumns() {
        guard !updatingColumns else { return }
        let visible = columnIndexes(in: visibleRect)
        let changed = viewportColumns.symmetricDifference(visible)
        guard !changed.isEmpty else { return }
        viewportColumns = visible
        var rows = IndexSet()
        enumerateAvailableRowViews { _, row in
            if (0..<numberOfRows).contains(row) { rows.insert(row) }
        }
        let columns = changed.intersection(IndexSet(integersIn: 0..<numberOfColumns))
        guard !rows.isEmpty, !columns.isEmpty else { return }
        reloadData(forRowIndexes: rows, columnIndexes: columns)
    }

    private(set) var selection = DelimitedTablePresentation.Selection()
    var onFocused: () -> Void = {}
    var acceptsGridActions: () -> Bool = { false }
    var onSelectionChanged: () -> Void = {}
    var onCopy: () -> Void = {}
    var onEdit: (Cell) -> Void = { _ in }
    var onPaste: (String) -> Void = { _ in }
    var onClear: () -> Void = {}
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

    fileprivate func refreshHover() {
        guard hoveredCell != nil, let window, window.isKeyWindow else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hover(visibleRect.contains(point) ? cell(at: point) : nil)
    }

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
        guard acceptsGridActions() else { return }
        guard let cell = cell(at: event) else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        select(cell, extending: event.modifierFlags.contains(.shift), adding: event.modifierFlags.contains(.command))
        if event.clickCount == 2 { onEdit(cell) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsGridActions() else { return }
        _ = autoscroll(with: event)
        if let cell = cell(at: event) { select(cell, extending: true) }
    }

    private func cell(at event: NSEvent) -> Cell? {
        cell(at: convert(event.locationInWindow, from: nil))
    }

    private func cell(at point: NSPoint) -> Cell? {
        let row = row(at: point)
        let column = column(at: point)
        return row >= 0 && column >= 0 ? Cell(row: row, column: column) : nil
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsGridActions(), numberOfRows > 0, numberOfColumns > 0,
              let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else {
            super.keyDown(with: event)
            return
        }
        let previous = selection.caret ?? Cell(row: 0, column: 0)
        var row = previous.row
        var column = previous.column
        switch key {
        case 8, 127, UInt32(NSDeleteFunctionKey):
            if window?.firstResponder === self { onClear() } else { super.keyDown(with: event) }
            return
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
        guard acceptsGridActions(), numberOfRows > 0, numberOfColumns > 0 else { return }
        selection.select(selection.caret ?? Cell(row: 0, column: 0), rows: 0..<numberOfRows, columns: 0..<numberOfColumns)
        syncSelection()
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
        if reveal { scrollToVisible(frameOfCell(atColumn: cell.column, row: cell.row)) }
        syncSelection()
    }

    func selectRecord(_ row: Int, modifiers: NSEvent.ModifierFlags) {
        guard (0..<numberOfRows).contains(row), numberOfColumns > 0 else { return }
        selection.select(Cell(row: row, column: selection.caret?.column ?? 0),
                         extending: modifiers.contains(.shift), adding: modifiers.contains(.command),
                         columns: 0..<numberOfColumns)
        syncSelection()
    }

    func selectColumn(_ column: Int, modifiers: NSEvent.ModifierFlags) {
        guard numberOfRows > 0, (0..<numberOfColumns).contains(column) else { return }
        selection.select(Cell(row: selection.caret?.row ?? 0, column: column),
                         extending: modifiers.contains(.shift), adding: modifiers.contains(.command),
                         rows: 0..<numberOfRows)
        syncSelection()
    }

    func remapRows(from previous: [Int], to current: [Int], columns: [Int: Int]?) {
        if let columns { selection.remapColumns(columns) }
        if previous != current { selection.remapRows(from: previous, to: current) }
        syncSelection()
    }

    override func accessibilitySelectedColumns() -> [Any]? {
        guard let columns = accessibilityColumns() else { return [] }
        return wholeColumns.compactMap { columns.indices.contains($0) ? columns[$0] : nil }
    }

    var wholeColumns: IndexSet {
        guard numberOfRows > 0 else { return [] }
        return selection.blocks.reduce(into: IndexSet()) { indexes, block in
            if block.rows.count == numberOfRows { indexes.formUnion(block.columns) }
        }
    }

    fileprivate func syncSelection() {
        selectRowIndexes(selection.rows, byExtendingSelection: false)
        refreshSelection()
        onSelectionChanged()
    }

    func clearSelection() {
        selection = .init()
        hoveredCell = nil
        syncSelection()
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
        if label.font != cellFont { label.font = cellFont }
        label.lineHeight = textLineHeight
        let selected = selection.contains(cell)
        let active = window?.isKeyWindow == true
        label.rule = palette.grid
        label.drawsBackground = selected || hoveredCell == cell
        label.backgroundColor = selected ? (active ? palette.selection : palette.inactiveSelection) : palette.hover
        label.outline = selected ? (active ? palette.focus : palette.grid) : nil
        label.textColor = selected && active ? palette.selectedText : label.isNumeric ? palette.numeric : palette.text
        label.setAccessibilitySelected(selected)
    }
}
