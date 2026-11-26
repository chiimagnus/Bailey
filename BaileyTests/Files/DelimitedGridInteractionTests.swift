import AppKit
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
final class DelimitedGridInteractionTests: XCTestCase {
    func testDisplayChangesRejectStaleNativePasteBeforeSwiftUIUpdates() async throws {
        let original = "Name,Value\r\nBeta,old\nAlpha,keep"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try Data(original.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        defer { file.retireContent() }
        let window = NSWindow(contentRect: NSRect(x: -800, y: -800, width: 300, height: 170),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file, rendersOnlyPreview: true))
        window.contentView = host
        window.orderBack(nil)

        let grid = try await self.grid(in: host, showing: "Beta")
        let controls = file.delimitedTable
        let target = DelimitedTablePresentation.Cell(row: 0, column: 1)
        grid.table.select(target, reveal: true)
        controls.configuration.sort = [.init(column: 0, ascending: true)]
        grid.paste("stale sort")
        XCTAssertFalse(file.hasPendingDelimitedEdit)
        if let stale = file.delimitedEditTask {
            _ = await stale.value
            XCTFail("An old display accepted a paste and changed the physical row: \(file.text)")
            return
        }

        let sorted = try await self.grid(in: host, showing: "Alpha")
        XCTAssertTrue(sorted === grid)
        grid.table.select(target)
        controls.configuration.filters[0] = "Beta"
        grid.paste("stale filter")
        XCTAssertFalse(file.hasPendingDelimitedEdit)
        _ = try await self.grid(in: host, showing: "Beta")
        grid.table.select(target)
        controls.configuration.header = false
        controls.configuration.filters.removeAll()
        controls.configuration.sort.removeAll()
        grid.paste("stale header")
        XCTAssertFalse(file.hasPendingDelimitedEdit)
        _ = try await self.grid(in: host, showing: "Name")
        grid.table.select(target)
        controls.separator = .semicolon
        grid.paste("stale delimiter")
        XCTAssertFalse(file.hasPendingDelimitedEdit)
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.documentUndoManager.canUndo)
        XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8))
    }

    func testFixedRecordGutterSelectsPhysicalRecordsAcrossSortAndBothScrollAxes() async throws {
        let header = "Name,Value,Notes,Tail\r\n"
        let first = "Zulu,old,\"quoted\nline\",unchanged\r\n"
        let others = (0..<36).map { "Row \($0),value,notes,tail\n" }.joined()
        let original = header + first + others
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try Data(original.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        defer { file.retireContent() }
        let window = NSWindow(contentRect: NSRect(x: -800, y: -800, width: 260, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file, rendersOnlyPreview: true))
        window.contentView = host
        window.orderBack(nil)
        let grid = try await self.grid(in: host, showing: "Zulu")
        let gutter = try XCTUnwrap(grid.subviews.first { $0.accessibilityIdentifier() == "bailey.csv.records" })
        let headerView = try XCTUnwrap(grid.table.headerView)
        for width: CGFloat in [920, 480, 360, 260, 220, 150, 260] {
            window.setContentSize(NSSize(width: width, height: 160))
            host.layoutSubtreeIfNeeded()
            let nativeHeader = headerView.convert(headerView.bounds, to: nil)
            XCTAssertEqual(nativeHeader.height, 30)
            XCTAssertEqual(gutter.frame.width, 46)
            XCTAssertEqual(grid.scrollView.frame.minX, gutter.frame.maxX)
            XCTAssertEqual(grid.scrollView.frame.maxX, grid.bounds.maxX)
        }
        let frame = gutter.frame

        func buttons() -> [NSAccessibilityElement] {
            (gutter.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        }
        func record(_ number: Int) throws -> NSAccessibilityElement {
            try XCTUnwrap(buttons().first { $0.accessibilityLabel() == String(localized: "Record \(number)", table: "Editor") })
        }
        let oldAnchor = try record(2)
        XCTAssertTrue(oldAnchor.accessibilityPerformPress())
        XCTAssertEqual(grid.table.selection.rows, IndexSet(integer: 0))
        XCTAssertEqual(grid.table.selection.columns, IndexSet(integersIn: 0..<4))
        XCTAssertTrue(try record(2).isAccessibilitySelected())
        let all = try XCTUnwrap(buttons().first)
        XCTAssertTrue(all.accessibilityPerformPress())
        XCTAssertEqual(grid.table.selection.rows.count, 37)
        XCTAssertTrue(oldAnchor.accessibilityPerformPress())
        grid.table.selectRecord(2, modifiers: .shift)
        grid.table.selectRecord(4, modifiers: .command)
        XCTAssertEqual(grid.table.selection.rows, IndexSet([0, 1, 2, 4]))
        XCTAssertTrue(oldAnchor.accessibilityPerformPress())

        let column = grid.table.tableColumns[0]
        grid.tableView(grid.table, didClick: column)
        XCTAssertTrue(file.delimitedTable.configuration.sort.isEmpty)
        XCTAssertEqual(grid.table.selection.columns, IndexSet(integer: 0))
        XCTAssertEqual(grid.table.selection.rows.count, 37)
        XCTAssertTrue(oldAnchor.accessibilityPerformPress())
        let position = headerView.convert(NSPoint(x: 30, y: headerView.bounds.midY), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: position, modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try XCTUnwrap(headerView.menu(for: click))
        let sort = try XCTUnwrap(menu.item(withTitle: String(localized: "Sort Ascending", table: "Editor")))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(sort.action), to: sort.target, from: sort))
        _ = try await self.grid(in: host, showing: "Row 0")
        XCTAssertEqual(grid.table.selection.caret?.row, 36)
        XCTAssertFalse(oldAnchor.accessibilityPerformPress(), "An AX element from the old projection must be inert")
        XCTAssertEqual(try XCTUnwrap(buttons()[1].accessibilityLabel()), String(localized: "Record \(3)", table: "Editor"))

        grid.table.scrollColumnToVisible(3)
        grid.table.scrollRowToVisible(36)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(gutter.frame, frame)
        XCTAssertGreaterThan(grid.scrollView.contentView.bounds.minX, 0)
        XCTAssertGreaterThan(grid.scrollView.contentView.bounds.minY, 0)
        let anchor = try record(2)
        XCTAssertTrue(anchor.accessibilityPerformPress())
        XCTAssertEqual(grid.table.selection.caret?.row, 36)
        let expectedFrame = grid.table.convert(grid.table.rect(ofRow: 36), to: nil)
        let actualFrame = window.convertFromScreen(anchor.accessibilityFrame())
        XCTAssertEqual(actualFrame.midY, expectedFrame.midY, accuracy: 1)

        grid.table.select(.init(row: 36, column: 1), reveal: true)
        grid.paste("semi;colon")
        let write = try XCTUnwrap(file.delimitedEditTask)
        let accepted = await write.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(file.delimitedTable.separator, .comma)
        await file.save()
        let edited = header + first.replacingOccurrences(of: "Zulu,old", with: "Zulu,semi;colon") + others
        XCTAssertEqual(try Data(contentsOf: url), Data(edited.utf8))
        file.documentUndoManager.undo()
        XCTAssertEqual(file.text, original)
    }

    private func grid(in host: NSView, showing value: String) async throws -> DelimitedGrid {
        func find(_ view: NSView) -> DelimitedGrid? {
            if let grid = view as? DelimitedGrid { return grid }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            host.layoutSubtreeIfNeeded()
            if let grid = find(host), grid.table.numberOfRows > 0,
               let field = grid.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField,
               field.stringValue == value { return grid }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        XCTFail("Native CSV grid did not show \(value)")
        return try XCTUnwrap(find(host))
    }
}
