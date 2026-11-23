import AppKit
import SwiftUI

struct CSVTableView: View {
    let file: FileTab
    let onFocused: () -> Void
    let onShowSource: () -> Void
    @State private var snapshot: FileTab.DelimitedSnapshot?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot, snapshot.requestID == file.textPreviewRequestID {
                if let issue = snapshot.index.issue {
                    notice(String(localized: "Table issue at line \(issue.line), column \(issue.column).", table: "Editor"))
                } else if snapshot.index.columnCount > DelimitedGrid.maximumColumns {
                    notice(String(localized: "This table has too many columns to display.", table: "Editor"))
                }
                if snapshot.index.records.isEmpty {
                    Spacer()
                    Text("No table rows to display.", tableName: "Editor").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    NativeDelimitedGrid(snapshot: snapshot, onFocused: onFocused)
                }
            } else if failed {
                notice(String(localized: "Could not display the table.", table: "Editor"))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: file.textPreviewRequestID) {
            failed = false
            do {
                let result = try await file.delimitedSnapshot()
                guard !Task.isCancelled else { return }
                snapshot = result
                failed = result == nil
            } catch is CancellationError {
                return
            } catch {
                failed = true
            }
        }
    }

    private func notice(_ message: String) -> some View {
        HStack {
            Text(message)
            Spacer()
            Button(FilePreviewMode.source.title, action: onShowSource).buttonStyle(.link)
        }
        .padding(8)
    }
}

private struct NativeDelimitedGrid: NSViewRepresentable {
    let snapshot: FileTab.DelimitedSnapshot
    let onFocused: () -> Void

    func makeNSView(context: Context) -> DelimitedGrid { DelimitedGrid() }

    func updateNSView(_ grid: DelimitedGrid, context: Context) {
        grid.table.onFocused = onFocused
        grid.install(snapshot)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DelimitedGrid, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

final class DelimitedGrid: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    static let maximumColumns = 4096
    let table = DelimitedNativeTable()
    private var index: DelimitedTableIndex?
    private var requestID: String?
    private var source: NSString = ""

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("bailey.csv.table")
        documentView = table
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func install(_ snapshot: FileTab.DelimitedSnapshot) {
        guard snapshot.requestID != requestID else { return }
        requestID = snapshot.requestID
        source = snapshot.source as NSString
        index = snapshot.index
        let count = min(snapshot.index.columnCount, Self.maximumColumns)
        while table.tableColumns.count > count, let last = table.tableColumns.last {
            table.removeTableColumn(last)
        }
        let header = snapshot.index.records.first.map { snapshot.index.fields(in: $0) }
        for columnIndex in 0..<count {
            let column: NSTableColumn
            if columnIndex < table.tableColumns.count {
                column = table.tableColumns[columnIndex]
            } else {
                column = NSTableColumn(identifier: .init(String(columnIndex)))
                column.width = 140
                table.addTableColumn(column)
            }
            let title: String
            if let header, columnIndex < header.count {
                title = header[header.startIndex + columnIndex].value(in: source, limit: 128)
            } else {
                title = ""
            }
            column.title = title.isEmpty ? String(columnIndex + 1) : title
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { max(0, (index?.records.count ?? 0) - 1) }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let index, let column, let columnIndex = Int(column.identifier.rawValue),
              index.records.indices.contains(row + 1) else { return nil }
        let fields = index.fields(in: index.records[row + 1])
        let value = columnIndex < fields.count
            ? fields[fields.startIndex + columnIndex].value(in: source, limit: 4096) : ""
        let cellID = NSUserInterfaceItemIdentifier("bailey.csv.cell")
        let label = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = cellID
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.stringValue = value
        return label
    }
}

final class DelimitedNativeTable: NSTableView {
    var onFocused: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocused()
        return true
    }
}
