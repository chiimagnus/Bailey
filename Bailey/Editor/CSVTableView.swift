import AppKit
import GhosttyTheme
import Observation
import SwiftUI

private struct DelimitedAnalysisTarget: Hashable {
    let display: UUID
    let columns: IndexSet
    let selection: DelimitedTablePresentation.Selection?
}

@Observable
final class DelimitedTableControls {
    struct ParseRequest: Hashable {
        let source: String
        let separator: DelimitedTableIndex.Separator?
    }

    struct DisplayRequest: Hashable {
        let parse: ParseRequest
        let configuration: DelimitedTablePresentation.Configuration
    }

    enum PendingSelection: Equatable {
        case cell(DelimitedTablePresentation.Cell)
        case column(Int)
    }

    var separator: DelimitedTableIndex.Separator?
    var configuration = DelimitedTablePresentation.Configuration()
    var query = "" {
        didSet { if !query.isEmpty { emptySearch = nil } }
    }
    fileprivate var emptySearch: DelimitedAnalysisTarget?
    var showsFind = false
    var showsReplace = false
    var findFocus = 0
    var findStep = 0
    var editError: String?
    private(set) var parsed: FileTab.DelimitedSnapshot?
    @ObservationIgnored var pendingSelection: PendingSelection?
    @ObservationIgnored weak var grid: DelimitedGrid?
    @ObservationIgnored var columnWidths: [Int: CGFloat] = [:]
    @ObservationIgnored private var columnRevision: String?
    @ObservationIgnored private(set) var columnMove: (before: String, after: String, positions: [Int: Int])?

    func request(for file: FileTab) -> ParseRequest {
        ParseRequest(source: file.textPreviewRequestID, separator: separator)
    }

    func accept(_ snapshot: FileTab.DelimitedSnapshot) {
        let index = snapshot.index
        let next: DelimitedTablePresentation.Configuration
        if columnRevision.map({ $0 != snapshot.documentRevision }) == true ||
            parsed.map({ $0.index.separator != index.separator }) == true {
            next = .init(header: configuration.header)
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

    func retire() { parsed = nil }

    func perform(_ action: FindAction) {
        switch action {
        case .show:
            showsFind = true
            showsReplace = false
            emptySearch = nil
            findFocus &+= 1
        case .hide: showsFind = false
        case .next: findStep &+= 1
        case .previous: findStep &-= 1
        case .useSelection:
            if let value = grid?.selectedFieldValue(), !value.isEmpty { query = value }
        case .replace:
            showsFind = true
            showsReplace = true
            emptySearch = nil
            findFocus &+= 1
        }
    }

    fileprivate func findEmptyFields(_ target: DelimitedAnalysisTarget) {
        query = ""
        emptySearch = target
        showsFind = true
        showsReplace = false
        findFocus &+= 1
    }
}

struct CSVTableView: View {
    private typealias ParseRequest = DelimitedTableControls.ParseRequest
    private typealias DisplayRequest = DelimitedTableControls.DisplayRequest

    private struct SearchRequest: Hashable {
        let display: UUID
        let query: String
        let empty: DelimitedAnalysisTarget?
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
    let onShowSource: () -> Void
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
    @State private var statisticsTarget: DelimitedAnalysisTarget?
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
            SearchRequest(display: projection.id, query: controls.query,
                          empty: controls.emptySearch.flatMap { $0.display == projection.id ? $0 : nil })
        }
        let matches = search.flatMap { $0.0 == query ? $0.1 : nil } ?? []
        surface(snapshot: active == nil ? nil : snapshot, active: active, matches: matches, theme: theme,
                failed: parseFailed == parse || displayFailed == display)
            .overlay(alignment: .topTrailing) {
                overlay(display: display, snapshot: snapshot, active: active, matches: matches, theme: theme)
            }
            .task(id: parse) {
                guard snapshot == nil else { return }
                parseFailed = nil
                do {
                    guard let result = try await file.delimitedSnapshot(using: parse.separator),
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
                        columnCount: DelimitedTableIndex.maximumColumns, empty: query.empty != nil,
                        columns: query.empty?.columns, selection: query.empty?.selection
                    )
                    guard !Task.isCancelled, controls.request(for: file) == parse,
                          controls.configuration == display.configuration, controls.query == query.query else { return }
                    search = (query, found)
                } catch {}
            }
            .onChange(of: controls.findFocus) {
                filterTarget = nil
                statisticsTarget = nil
                focus(.find)
            }
            .onChange(of: display) {
                if filterTarget?.request != display { filterTarget = nil }
                pinnedSelection = nil
                statisticsTarget = nil
                controls.emptySearch = nil
            }
            .onChange(of: controls.query) { replaceCursor = nil; replaceTask?.cancel() }
            .onChange(of: controls.findStep) { replaceCursor = nil }
            .onChange(of: controls.showsFind) { if !controls.showsFind { replaceTask?.cancel() } }
            .onDisappear { replaceTask?.cancel() }
    }

    @ViewBuilder
    private func surface(
        snapshot: FileTab.DelimitedSnapshot?, active: DelimitedTablePresentation?,
        matches: [DelimitedTablePresentation.Cell], theme: GhosttyThemeDefinition, failed: Bool
    ) -> some View {
        let hasRows = snapshot.map { !$0.index.records.isEmpty } ?? false
        VStack(spacing: 0) {
            if let snapshot {
                if let issue = snapshot.index.issue {
                    notice(String(localized: "Table issue at line \(issue.line), column \(issue.column).", table: "Editor"))
                } else if snapshot.index.columnCount > DelimitedTableIndex.maximumColumns {
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
                    onFilter: { column, request in
                        statisticsTarget = nil
                        filterDraft = controls.configuration.filters[column] ?? ""
                        filterTarget = (column, request)
                    },
                    onStatistics: { target in
                        filterTarget = nil
                        controls.perform(.hide)
                        statisticsTarget = target
                    },
                    onSelectionChanged: { selection in
                        guard let target = statisticsTarget, let original = target.selection, original != selection else { return }
                        DispatchQueue.main.async {
                            if statisticsTarget == target { statisticsTarget = nil }
                        }
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
                                file.submitDelimitedEdit(.insertRows(before: 0, count: 1), using: snapshot, selecting: nil)
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
    private func overlay(display: DisplayRequest, snapshot: FileTab.DelimitedSnapshot?,
                         active: DelimitedTablePresentation?, matches: [DelimitedTablePresentation.Cell],
                         theme: GhosttyThemeDefinition) -> some View {
        if let target = statisticsTarget, let active, target.display == active.id, let snapshot {
            DelimitedStatisticsView(target: target, snapshot: snapshot, active: active, theme: theme,
                                    isCurrent: {
                                        guard let grid = controls.grid, grid.acceptsProjection(target.display) else { return false }
                                        return target.selection.map { $0 == grid.table.selection } ?? true
                                    },
                                    onClose: { statisticsTarget = nil },
                                    onFind: {
                                        guard controls.grid?.acceptsProjection(active.id) == true else { return }
                                        statisticsTarget = nil
                                        controls.findEmptyFields(target)
                                    })
                .id(target)
        } else if let target = filterTarget, target.request == display {
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
                    TextField(controls.emptySearch == nil ? String(localized: "Find", table: "Terminal")
                              : String(localized: "Empty Fields", table: "Editor"), text: $controls.query)
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
        .init(rows: request.range == .all ? nil : active.rows, firstRecord: active.header ? 1 : 0,
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

private struct DelimitedStatisticsView: View {
    let target: DelimitedAnalysisTarget
    let snapshot: FileTab.DelimitedSnapshot
    let active: DelimitedTablePresentation
    let theme: GhosttyThemeDefinition
    let isCurrent: () -> Bool
    let onClose: () -> Void
    let onFind: () -> Void
    @State private var all = false
    @State private var results: (Bool, [DelimitedTablePresentation.ColumnStatistics])?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Statistics", tableName: "Editor").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Close"))
            }
            if target.selection == nil {
                Picker(String(localized: "Statistics Range", table: "Editor"), selection: $all) {
                    Text("Visible Records", tableName: "Editor").tag(false)
                    Text("All Data Records", tableName: "Editor").tag(true)
                }
                .controlSize(.small)
            } else {
                Text("Selected Visible Fields", tableName: "Editor").font(.caption)
            }
            if snapshot.index.issue != nil {
                Text("Partial table — only indexed fields are counted.", tableName: "Editor")
                    .font(.caption)
            }
            if let results, results.0 == all {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(results.1, id: \.column) { result in
                            if result.column != results.1.first?.column { Divider() }
                            Text(verbatim: columnTitle(result.column)).font(.subheadline.weight(.medium)).lineLimit(1)
                            LabeledContent(String(localized: "Fields", table: "Editor"), value: result.total.formatted())
                            LabeledContent(String(localized: "Empty", table: "Editor"), value: result.empty.formatted())
                            LabeledContent(String(localized: "Numeric", table: "Editor"), value: result.numeric.formatted())
                            LabeledContent(String(localized: "Other or Out of Range", table: "Editor"), value: result.other.formatted())
                            LabeledContent(String(localized: "Minimum", table: "Editor"), value: number(result.minimum, count: result.numeric))
                            LabeledContent(String(localized: "Maximum", table: "Editor"), value: number(result.maximum, count: result.numeric))
                            LabeledContent(String(localized: "Sum", table: "Editor"), value: number(result.sum, count: result.numeric))
                            LabeledContent(String(localized: "Average", table: "Editor"), value: number(result.average, count: result.numeric))
                        }
                    }.font(.caption).monospacedDigit()
                }
                .frame(idealHeight: 164, maxHeight: 218)
            } else {
                ProgressView().controlSize(.small)
            }
            Button(String(localized: "Find Visible Empty Fields", table: "Editor"), action: onFind)
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: 350)
        .modifier(DelimitedOverlayStyle(theme: theme))
        .accessibilityIdentifier("bailey.csv.statistics")
        .onKeyPress(.escape) { onClose(); return .handled }
        .task(id: all) {
            let includeHidden = all
            let scope = DelimitedTablePresentation.FieldScope(
                rows: includeHidden ? nil : active.rows, firstRecord: active.header ? 1 : 0,
                columns: target.columns, selection: target.selection
            )
            guard let values = try? await DelimitedTablePresentation.statistics(in: scope, source: snapshot.source,
                                                                                 index: snapshot.index),
                  !Task.isCancelled, all == includeHidden, isCurrent() else { return }
            results = (includeHidden, values)
        }
    }

    private func columnTitle(_ column: Int) -> String {
        if active.header,
           let title = snapshot.index.field(record: 0, column: column)?.value(in: snapshot.source as NSString, limit: 128),
           !title.isEmpty { return title }
        return String(localized: "Column \(column + 1)", table: "Editor")
    }

    private func number(_ value: Double?, count: Int) -> String {
        guard let value else { return count == 0 ? "—" : String(localized: "Not Representable", table: "Editor") }
        if value != 0 && (abs(value) >= 1e9 || abs(value) < 1e-6) {
            return value.formatted(.number.notation(.scientific).precision(.significantDigits(1...10)))
        }
        return value.formatted(.number.precision(.significantDigits(1...10)))
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
    let onFilter: (Int, DelimitedTableControls.DisplayRequest) -> Void
    let onStatistics: (DelimitedAnalysisTarget) -> Void
    let onSelectionChanged: (DelimitedTablePresentation.Selection) -> Void

    func makeNSView(context: Context) -> DelimitedGrid { DelimitedGrid() }

    func updateNSView(_ grid: DelimitedGrid, context: Context) {
        grid.file = file
        grid.applyTheme(theme)
        grid.table.onFocused = onFocused
        grid.onFilter = onFilter
        grid.onStatistics = onStatistics
        grid.onSelectionChanged = onSelectionChanged
        if let snapshot, let presentation, !snapshot.index.records.isEmpty {
            grid.install(snapshot, presentation: presentation)
            grid.showMatch(matches, step: findStep)
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

final class DelimitedGrid: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let displayLimit = 4096
    let table = DelimitedNativeTable()
    let scrollView = NSScrollView()
    private lazy var gutter = DelimitedRecordGutter(grid: self)
    weak var file: FileTab? {
        didSet {
            guard file !== oldValue else { return }
            if oldValue?.delimitedTable.grid === self { oldValue?.delimitedTable.grid = nil }
            table.file = file
            controls?.grid = self
        }
    }
    private var controls: DelimitedTableControls? { file?.delimitedTable }
    private var theme: GhosttyThemeDefinition?
    fileprivate var palette: DelimitedPalette { table.palette }
    private var installingColumns = false
    var onFilter: (Int, DelimitedTableControls.DisplayRequest) -> Void = { _, _ in }
    fileprivate var onStatistics: (DelimitedAnalysisTarget) -> Void = { _ in }
    var onSelectionChanged: (DelimitedTablePresentation.Selection) -> Void = { _ in }
    private var snapshot: FileTab.DelimitedSnapshot?
    private var presentation: DelimitedTablePresentation?
    private var source: NSString = ""
    private var copyTask: Task<Void, Never>?
    private struct CellEdit {
        enum Input {
            case inline(DelimitedCellField, DelimitedTablePresentation.Cell)
            case full(DelimitedFieldPopover)
        }

        let input: Input
        let snapshot: FileTab.DelimitedSnapshot
        let physical: DelimitedTablePresentation.Cell
        let original: String
        let selection: DelimitedTableControls.PendingSelection?
        var editorAppearance: FieldEditorAppearance?
        var movement: Int? = nil

        var textEditor: NSTextView? {
            switch input {
            case .inline(let field, _): field.currentEditor() as? NSTextView
            case .full(let panel): panel.editor
            }
        }

        func draft(value: String, selecting target: DelimitedTableControls.PendingSelection? = nil) -> FileTab.DelimitedDraft {
            .init(cell: physical, value: value, snapshot: snapshot, selection: target ?? selection)
        }
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
        table.onClear = { [weak self] in
            guard let self else { return }
            fillSelection(with: "", selection: table.selection)
        }
        table.onMenu = { [weak self] cell in self?.recordMenu(at: cell) }
        table.acceptsGridActions = { [weak self] in self?.projectionIsCurrent == true }
        table.onSelectionChanged = { [weak self] in
            guard let self else { return }
            gutter.needsDisplay = true
            onSelectionChanged(table.selection)
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
        scrollView.frame = CGRect(x: bounds.minX + width, y: bounds.minY,
                                  width: bounds.width - width, height: bounds.height)
        gutter.needsDisplay = true
    }

    @objc private func viewportChanged(_ notification: Notification) {
        gutter.needsDisplay = true
        table.refreshHover()
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
        onStatistics = { _ in }
        onSelectionChanged = { _ in }
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
        let oldHeader = self.presentation?.header
        let needsFit = move != nil || self.snapshot?.index.separator != snapshot.index.separator ||
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

    private func installColumns(index: DelimitedTableIndex, header: Bool, fitExisting: Bool) {
        installingColumns = true
        defer { installingColumns = false }
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
                column.minWidth = 44
                column.headerCell = DelimitedColumnHeader(textCell: "")
            }
            let title = header && !index.records.isEmpty
                ? DelimitedTablePresentation.value(in: source, index: index, record: 0, column: columnIndex, limit: 128) : ""
            let displayTitle = header ? Self.singleLine(title) : String(columnIndex + 1)
            if column.title != displayTitle { column.title = displayTitle }
            if let width = controls?.columnWidths[columnIndex] {
                column.width = width
            } else if fitExisting || isNewColumn {
                column.width = fittedWidth(columnIndex, title: displayTitle, index: index,
                                           header: header, samplesPerColumn: 4096 / count)
            }
            if isNewColumn { table.addTableColumn(column) }
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

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard projectionIsCurrent, let column = Int(tableColumn.identifier.rawValue) else { return }
        table.window?.makeFirstResponder(table)
        table.selectColumn(column, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
        if let event = NSApp.currentEvent,
           event.type == .leftMouseDown || event.type == .leftMouseUp,
           event.clickCount == 2 { renameHeader(column) }
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
        let value = field?.value(in: source, limit: Self.displayLimit) ?? ""
        label.isNumeric = field.map { $0.contentRange(in: source).length <= Self.displayLimit } == true &&
            DelimitedTablePresentation.finiteNumber(value) != nil
        label.stringValue = Self.singleLine(value)
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
        if matches != previousMatches {
            previousMatches = matches
            previousStep = step
            matchIndex = table.selection.caret.flatMap { cell in
                matches.firstIndex { $0.row > cell.row || $0.row == cell.row && $0.column >= cell.column }
            } ?? 0
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
        guard projectionIsCurrent, editing == nil, let file, let snapshot, let physical = physicalCell(cell),
              let field = snapshot.index.field(record: physical.row, column: physical.column) else { return }
        let content = field.contentRange(in: source)
        if content.length > Self.displayLimit ||
            source.rangeOfCharacter(from: .newlines, options: [], range: content).location != NSNotFound {
            openFullCell(cell)
            return
        }
        guard let window, file.beginDelimitedEditing(in: self, using: snapshot) else { return }
        table.select(cell, reveal: true)
        table.layoutSubtreeIfNeeded()
        guard let field = table.view(atColumn: cell.column, row: cell.row, makeIfNecessary: true) as? DelimitedCellField else {
            file.endDelimitedEditing(in: self)
            return
        }
        let original = value(cell)
        editing = CellEdit(input: .inline(field, cell), snapshot: snapshot, physical: physical,
                           original: original, selection: .cell(physical))
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

    private func openFullCell(_ cell: DelimitedTablePresentation.Cell) {
        guard projectionIsCurrent, editing == nil, let file, let snapshot, let physical = physicalCell(cell),
              snapshot.index.field(record: physical.row, column: physical.column) != nil else { return }
        let editable = file.canEditDelimited(snapshot)
        guard !editable || !file.hasPendingDelimitedEdit else { return }
        table.select(cell, reveal: true)
        table.layoutSubtreeIfNeeded()
        guard let anchor = table.view(atColumn: cell.column, row: cell.row, makeIfNecessary: true) else { return }
        beginFullField(physical, selecting: .cell(physical), from: anchor.bounds, in: anchor, editable: editable)
    }

    private func styleEditor(_ edit: CellEdit) {
        if case .full(let panel) = edit.input {
            panel.apply(palette)
            return
        }
        guard let editor = edit.textEditor else { return }
        editor.textColor = palette.text
        editor.insertionPointColor = palette.focus
        editor.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.selectedText]
    }

    private func restoreField(_ edit: CellEdit) {
        switch edit.input {
        case .inline(let field, let cell):
            field.delegate = nil
            field.isEditable = false
            field.isSelectable = false
            field.isBordered = false
            edit.editorAppearance?.restore()
            displayValue(in: field, at: cell)
            table.style(field, cell: cell)
        case .full(let panel):
            panel.popover.close()
        }
    }

    private func renameHeader(_ column: Int) {
        guard projectionIsCurrent, presentation?.header == true,
              let header = table.headerView else { return }
        table.scrollColumnToVisible(column)
        beginFullField(.init(row: 0, column: column), selecting: .column(column),
                       from: header.headerRect(ofColumn: column), in: header, editable: true)
    }

    private func beginFullField(_ physical: DelimitedTablePresentation.Cell,
                                selecting selection: DelimitedTableControls.PendingSelection?,
                                from rect: NSRect, in anchor: NSView, editable: Bool) {
        guard editing == nil, let file, let snapshot, anchor.window != nil,
              let field = snapshot.index.field(record: physical.row, column: physical.column) else { return }
        if editable, !file.beginDelimitedEditing(in: self, using: snapshot) { return }
        let original = field.value(in: source)
        let panel = DelimitedFieldPopover(value: original, editable: editable)
        let edit = CellEdit(input: .full(panel), snapshot: snapshot, physical: physical,
                            original: original, selection: selection)
        editing = edit
        panel.confirm = { [weak self] in
            guard let self else { return }
            finishEditing()
            window?.makeFirstResponder(table)
        }
        panel.dismiss = { [weak self, weak panel] in
            guard let self, let panel, let edit = editing,
                  case .full(let current) = edit.input, current === panel else { return }
            endEditingForProjectionChange()
        }
        panel.cancel = { [weak self] in self?.cancelEditing() }
        styleEditor(edit)
        panel.show(from: rect, in: anchor)
        if !panel.popover.isShown { cancelEditing() }
    }

    func finishEditing() {
        guard let edit = editing, edit.textEditor?.hasMarkedText() != true else { return }
        switch edit.input {
        case .inline(let field, _):
            field.window?.endEditing(for: field)
        case .full(let panel):
            completeEditing(edit, value: panel.editor.string)
        }
    }

    private func endEditingForProjectionChange() {
        finishEditing()
        guard let edit = editing else { return }
        if let editor = edit.textEditor {
            file?.retainDelimitedEditing(in: self, draft: edit.draft(value: editor.string))
        }
        cancelEditing()
    }

    func cancelEditing() {
        guard let edit = editing else { return }
        editing = nil
        file?.endDelimitedEditing(in: self)
        if case .inline(let field, _) = edit.input { field.abortEditing() }
        restoreField(edit)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let edit = editing, case .inline(let field, _) = edit.input,
              control === field, !textView.hasMarkedText(),
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
        guard let edit = editing, case .inline(let field, _) = edit.input,
              notification.object as? NSTextField === field else { return }
        let movement = edit.movement ?? notification.userInfo?["NSTextMovement"] as? Int
        guard movement != NSCancelTextMovement else {
            editing = nil
            restoreField(edit)
            file?.endDelimitedEditing(in: self)
            return
        }
        completeEditing(edit, value: field.stringValue, movement: movement)
    }

    private func completeEditing(_ edit: CellEdit, value: String, movement: Int? = nil) {
        editing = nil
        restoreField(edit)
        var destination = edit.selection
        if case .inline(_, let cell) = edit.input,
           movement == NSTabTextMovement || movement == NSBacktabTextMovement,
           let next = table.adjacent(to: cell, backwards: movement == NSBacktabTextMovement),
           let physical = physicalCell(next) {
            destination = .cell(physical)
        }
        if value.utf16.elementsEqual(edit.original.utf16) {
            file?.endDelimitedEditing(in: self)
            if let destination { restoreSelection(destination) }
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
        let cell: DelimitedTablePresentation.Cell?
        let selection: DelimitedTablePresentation.Selection
    }

    fileprivate func recordMenu(at cell: DelimitedTablePresentation.Cell?) -> NSMenu? {
        guard projectionIsCurrent, let file, let snapshot, let presentation else { return nil }
        let target = RecordMenuTarget(projection: presentation.id, cell: cell ?? table.selection.caret,
                                      selection: table.selection)
        let menu = NSMenu()
        func item(_ title: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = target
            return item
        }
        if let cell = target.cell {
            if let physical = physicalCell(cell), snapshot.index.field(record: physical.row, column: physical.column) != nil {
                let title = file.canEditDelimited(snapshot)
                    ? String(localized: "Edit Full Field…", table: "Editor")
                    : String(localized: "View Full Field…", table: "Editor")
                menu.addItem(item(title, action: #selector(openFullCellItem(_:))))
            }
            menu.addItem(item(String(localized: "Select Row", table: "Editor"), action: #selector(selectRow(_:))))
        }
        if !target.selection.blocks.isEmpty {
            menu.addItem(item(String(localized: "Selection Statistics…", table: "Editor"), action: #selector(selectionStatistics(_:))))
        }
        if file.canEditDelimited(snapshot), !file.hasPendingDelimitedEdit {
            if !target.selection.blocks.isEmpty {
                menu.addItem(item(String(localized: "Fill Selection…", table: "Editor"), action: #selector(chooseFillValue(_:))))
                menu.addItem(item(String(localized: "Clear Selected Fields", table: "Editor"), action: #selector(clearSelectedFields(_:))))
                menu.addItem(.separator())
            }
            menu.addItem(item(String(localized: "Insert Row After", table: "Editor"), action: #selector(insertRow(_:))))
            if !target.selection.blocks.isEmpty {
                menu.addItem(item(String(localized: "Delete Rows", table: "Editor"), action: #selector(deleteRows(_:))))
            }
        }
        return menu
    }

    private func recordTarget(_ sender: NSMenuItem) -> RecordMenuTarget? {
        guard projectionIsCurrent, let target = sender.representedObject as? RecordMenuTarget,
              target.projection == presentation?.id else { return nil }
        return target
    }

    @objc private func selectRow(_ sender: NSMenuItem) {
        guard let row = recordTarget(sender)?.cell?.row else { return }
        table.selectRecord(row, modifiers: [])
    }

    @objc private func selectionStatistics(_ sender: NSMenuItem) {
        guard let target = recordTarget(sender) else { return }
        onStatistics(.init(display: target.projection, columns: target.selection.columns, selection: target.selection))
    }

    @objc private func openFullCellItem(_ sender: NSMenuItem) {
        if let cell = recordTarget(sender)?.cell { openFullCell(cell) }
    }

    @objc private func insertRow(_ sender: NSMenuItem) {
        guard let target = recordTarget(sender), let snapshot else { return }
        let row = target.cell.flatMap { recordNumber($0.row) } ?? snapshot.index.records.count
        file?.submitDelimitedEdit(.insertRows(before: row, count: 1), using: snapshot,
                                  selecting: .init(row: row, column: 0))
    }

    @objc private func deleteRows(_ sender: NSMenuItem) {
        guard let target = recordTarget(sender), let snapshot, let presentation else { return }
        let rows = Set(target.selection.rows.compactMap { row in
            presentation.rows.indices.contains(row) ? presentation.rows[row] : nil
        })
        guard !rows.isEmpty else { return }
        file?.submitDelimitedEdit(.deleteRows(rows), using: snapshot, selecting: nil)
    }

    @objc private func clearSelectedFields(_ sender: NSMenuItem) {
        if let target = recordTarget(sender) { fillSelection(with: "", selection: target.selection) }
    }

    @objc private func chooseFillValue(_ sender: NSMenuItem) {
        guard recordTarget(sender) != nil, let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Fill Selected Fields", table: "Editor")
        alert.informativeText = String(localized: "Only selected visible fields will change.", table: "Editor")
        let input = NSTextField(string: "")
        input.frame = NSRect(x: 0, y: 0, width: 270, height: 26)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "Fill", table: "Editor"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let target = recordTarget(sender) else { return }
            fillSelection(with: input.stringValue, selection: target.selection)
        }
    }

    private func fillSelection(with value: String, selection: DelimitedTablePresentation.Selection) {
        guard projectionIsCurrent, !selection.blocks.isEmpty, let snapshot, let presentation else { return }
        let scope = DelimitedTablePresentation.FieldScope(rows: presentation.rows, firstRecord: 0,
                                                          columns: selection.columns, selection: selection)
        file?.submitDelimitedEdit(.fill(scope, value), using: snapshot)
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
        menu.addItem(item(String(localized: "Fit Column Width", table: "Editor"), action: #selector(fitColumnWidth(_:)), tag: column))
        menu.addItem(item(String(localized: "Column Statistics…", table: "Editor"), action: #selector(columnStatistics(_:)), tag: column))
        if controls.configuration.filters[column] != nil {
            menu.addItem(item(String(localized: "Clear Column Filter", table: "Editor"), action: #selector(clearFilter(_:)), tag: column))
        }
        let header = item(String(localized: "Use First Row as Header", table: "Editor"), action: #selector(toggleHeader(_:)))
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
        if let snapshot, let file, file.canEditDelimited(snapshot), !file.hasPendingDelimitedEdit {
            let count = snapshot.index.columnCount
            if presentation.header {
                menu.addItem(item(String(localized: "Rename Header…", table: "Editor"), action: #selector(renameHeaderItem(_:)), tag: column))
            }
            if (1...DelimitedTableIndex.maximumColumns).contains(count) {
                menu.addItem(.separator())
                menu.addItem(.sectionHeader(title: String(localized: "Changes All Records", table: "Editor")))
                if count < DelimitedTableIndex.maximumColumns {
                    menu.addItem(item(String(localized: "Insert Column Left", table: "Editor"), action: #selector(insertColumnLeft(_:)), tag: column))
                    menu.addItem(item(String(localized: "Insert Column Right", table: "Editor"), action: #selector(insertColumnRight(_:)), tag: column))
                }
                if count > 1 {
                    menu.addItem(item(String(localized: "Delete Column from All Records", table: "Editor"), action: #selector(deleteColumn(_:)), tag: column))
                    let selected = table.wholeColumns
                    if selected.count > 1, selected.count < count {
                        let deletion = item(String(localized: "Delete Selected Columns from All Records", table: "Editor"),
                                            action: #selector(deleteSelectedColumns(_:)), tag: column)
                        deletion.representedObject = ColumnDeletion(projection: presentation.id, columns: selected)
                        menu.addItem(deletion)
                    }
                    if column > 0 {
                        menu.addItem(item(String(localized: "Move Column Left", table: "Editor"), action: #selector(moveColumnLeft(_:)), tag: column))
                    }
                    if column + 1 < count {
                        menu.addItem(item(String(localized: "Move Column Right", table: "Editor"), action: #selector(moveColumnRight(_:)), tag: column))
                    }
                    menu.addItem(item(String(localized: "Move Column to Position…", table: "Editor"), action: #selector(chooseColumnPosition(_:)), tag: column))
                }
            }
        }
        return menu
    }

    @objc private func renameHeaderItem(_ sender: NSMenuItem) {
        if accepts(sender) { renameHeader(sender.tag) }
    }

    @objc private func columnStatistics(_ sender: NSMenuItem) {
        guard accepts(sender), let projection = projectionID else { return }
        let selection = table.wholeColumns
        let columns = selection.contains(sender.tag) ? selection : IndexSet(integer: sender.tag)
        onStatistics(.init(display: projection, columns: columns, selection: nil))
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
        if accepts(sender) { changeColumns { $0.remove(at: sender.tag) } }
    }

    @objc private func deleteSelectedColumns(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ColumnDeletion, target.projection == projectionID else { return }
        changeColumns { order in
            for column in target.columns.reversed() { order.remove(at: column) }
        }
    }

    @objc private func moveColumnLeft(_ sender: NSMenuItem) { moveColumn(sender, to: sender.tag - 1) }
    @objc private func moveColumnRight(_ sender: NSMenuItem) { moveColumn(sender, to: sender.tag + 1) }

    private func moveColumn(_ sender: NSMenuItem, to destination: Int) {
        guard accepts(sender), sender.tag != destination, table.tableColumns.indices.contains(destination) else { return }
        changeColumns { order in
            let column = order.remove(at: sender.tag)
            order.insert(column, at: destination)
        }
    }

    @objc private func chooseColumnPosition(_ sender: NSMenuItem) {
        guard accepts(sender), let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Move Column to Position", table: "Editor")
        alert.informativeText = String(localized: "Enter a position from 1 to \(table.numberOfColumns). This changes every record.", table: "Editor")
        let position = NSTextField(string: String(sender.tag + 1))
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = NSNumber(value: table.numberOfColumns)
        formatter.allowsFloats = false
        position.formatter = formatter
        position.frame = NSRect(x: 0, y: 0, width: 125, height: 24)
        alert.accessoryView = position
        alert.addButton(withTitle: String(localized: "Move Column", table: "Editor"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = position
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let requested = position.objectValue as? NSNumber else { return }
            moveColumn(sender, to: requested.intValue - 1)
        }
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

    @objc private func fitColumnWidth(_ sender: NSMenuItem) {
        guard accepts(sender), table.tableColumns.indices.contains(sender.tag) else { return }
        installingColumns = true
        defer { installingColumns = false }
        controls?.columnWidths.removeValue(forKey: sender.tag)
        table.tableColumns[sender.tag].width = tableView(table, sizeToFitWidthOfColumn: sender.tag)
    }
    @objc private func clearFilter(_ sender: NSMenuItem) {
        guard accepts(sender) else { return }
        controls?.configuration.filters.removeValue(forKey: sender.tag)
    }

    @objc private func toggleHeader(_ sender: NSMenuItem) {
        guard accepts(sender) else { return }
        finishEditing()
        guard editing == nil else { return }
        controls?.configuration.header.toggle()
    }

    @objc private func chooseDelimiter(_ sender: NSMenuItem) {
        guard accepts(sender) else { return }
        finishEditing()
        guard editing == nil else { return }
        controls?.separator = DelimitedTableIndex.Separator(rawValue: UInt16(sender.tag))
    }
}

private final class DelimitedFieldPopover: NSObject, NSPopoverDelegate, NSTextViewDelegate {
    let popover = NSPopover()
    let editor = NSTextView(usingTextLayoutManager: true)
    private let scroll = NSScrollView()
    private let panel = NSView()
    var confirm: () -> Void = {}
    var cancel: () -> Void = {}
    var dismiss: () -> Void = {}

    init(value: String, editable: Bool) {
        super.init()
        panel.wantsLayer = true
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
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.font = DelimitedCellField.textFont
        editor.string = value
        editor.delegate = self
        editor.setAccessibilityIdentifier("bailey.csv.full-field")
        editor.setAccessibilityLabel(String(localized: "Full Field", table: "Editor"))
        editor.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let close = NSButton(title: editable ? String(localized: "Cancel") : String(localized: "Close"),
                             target: self, action: #selector(cancelField(_:)))
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.addView(close, in: .trailing)
        if editable {
            let apply = NSButton(title: String(localized: "Apply Field", table: "Editor"),
                                 target: self, action: #selector(confirmField(_:)))
            apply.keyEquivalent = "\r"
            apply.keyEquivalentModifierMask = .command
            buttons.addView(apply, in: .trailing)
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scroll)
        panel.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),
            buttons.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            buttons.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8)
        ])
        let controller = NSViewController()
        controller.view = panel
        popover.contentViewController = controller
        popover.animates = false
        popover.behavior = .transient
        popover.delegate = self
    }

    func show(from rect: NSRect, in anchor: NSView) {
        let width = min(420, max(220, anchor.window?.contentView?.bounds.width ?? 320))
        popover.contentSize = NSSize(width: width, height: 204)
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
        editor.window?.makeFirstResponder(editor)
    }

    func apply(_ palette: DelimitedPalette) {
        panel.layer?.backgroundColor = palette.header.cgColor
        scroll.backgroundColor = palette.input
        editor.backgroundColor = palette.input
        editor.textColor = palette.text
        editor.insertionPointColor = palette.focus
        editor.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.selectedText]
    }

    @objc private func confirmField(_ sender: NSButton) { if !editor.hasMarkedText() { confirm() } }
    @objc private func cancelField(_ sender: NSButton) { cancel() }

    func popoverShouldClose(_ popover: NSPopover) -> Bool { !editor.hasMarkedText() }
    func popoverDidClose(_ notification: Notification) { dismiss() }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() else { return false }
        cancel()
        return true
    }
}

private final class DelimitedRecordGutter: NSView {
    private weak var grid: DelimitedGrid?
    private static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
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
        return max(46, ceil(("0" as NSString).size(withAttributes: [.font: Self.font]).width) * CGFloat(digits) + 20)
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
        palette.header.setFill()
        dirtyRect.intersection(bounds).fill()
        func label(_ title: String, in rect: NSRect, color: NSColor) {
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: max(0, rect.maxX - size.width - 10),
                                                 y: floor(rect.midY - size.height / 2)),
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
        guard let grid, grid.projectionIsCurrent,
              let row = row(at: convert(event.locationInWindow, from: nil), in: grid.table) else { return nil }
        if grid.table.selection.columns(in: row).count != grid.table.numberOfColumns {
            activate(row, modifiers: [])
        }
        let column = grid.table.selection.caret?.column ?? 0
        return grid.recordMenu(at: .init(row: row, column: column))
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
        let column = table.column(at: NSPoint(x: frame.midX, y: 0))
        let sorts = table.file?.delimitedTable.configuration.sort ?? []
        let direction = sorts.first { $0.column == column }
        if let direction {
            let symbol = NSImage(systemSymbolName: direction.ascending ? "chevron.up" : "chevron.down",
                                 accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [palette.focus]))
            symbol?.draw(in: NSRect(x: frame.maxX - 19, y: controlView.bounds.midY - 4, width: 9, height: 8))
        }
        let height = ceil(title.size().height)
        let trailing = direction == nil ? 22.0 : 33.0
        title.draw(with: NSRect(x: frame.minX + 11, y: floor(controlView.bounds.midY - height / 2),
                                width: max(0, frame.width - trailing), height: height),
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
    let recordText: NSColor
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
        recordText = Self.readable(theme.surfaceNSColor(elevation: 0.57), on: header, toward: foreground, ratio: 4.5)
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
    var acceptsGridActions: () -> Bool = { false }
    var onSelectionChanged: () -> Void = {}
    var onCopy: () -> Void = {}
    var onEdit: (Cell) -> Void = { _ in }
    var onPaste: (String) -> Void = { _ in }
    var onClear: () -> Void = {}
    var onMenu: (Cell?) -> NSMenu? = { _ in nil }
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
        guard acceptsGridActions() else { return nil }
        let target = cell(at: event)
        if let target, !selection.contains(target) { select(target) }
        return onMenu(target)
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
        if reveal {
            scrollRowToVisible(cell.row)
            scrollColumnToVisible(cell.column)
        }
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

    private func syncSelection() {
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
