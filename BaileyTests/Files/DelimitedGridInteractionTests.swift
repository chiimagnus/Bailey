import AppKit
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
func csvFullFieldEditor() -> NSTextView? {
    func find(_ view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView, editor.accessibilityIdentifier() == "bailey.csv.full-field" { return editor }
        return view.subviews.lazy.compactMap(find).first
    }
    return NSApp.windows.filter(\.isVisible).compactMap(\.contentView).lazy.compactMap(find).first
}

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

    func testColumnMenuInsertsAcrossHiddenRecordsAndKeepsColumnSettings() async throws {
        let original = "Name,Group\r\nShown,keep\nHidden,\"other\"\rLast,keep"
        let expected = "Name,,Group\r\nShown,,keep\nHidden,,\"other\"\rLast,,keep"
        func bytes(_ source: String) -> Data { Data([0xef, 0xbb, 0xbf]) + Data(source.utf8) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try bytes(original).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        defer { file.retireContent() }
        file.delimitedTable.configuration.filters[1] = "keep"
        let window = NSWindow(contentRect: NSRect(x: -800, y: -800, width: 350, height: 210),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file, rendersOnlyPreview: true))
        window.contentView = host
        window.orderBack(nil)
        let grid = try await self.grid(in: host, showing: "Shown")
        XCTAssertEqual(grid.table.numberOfRows, 2)
        grid.table.tableColumns[1].width = 190
        let header = try XCTUnwrap(grid.table.headerView)
        let origin = header.convert(NSPoint(x: 25, y: header.bounds.midY), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: origin, modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try XCTUnwrap(header.menu(for: click))
        let insertion = try XCTUnwrap(menu.item(withTitle: String(localized: "Insert Column Right", table: "Editor")))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(insertion.action), to: insertion.target, from: insertion))
        let task = try XCTUnwrap(file.delimitedEditTask)
        let inserted = await task.value
        XCTAssertTrue(inserted)
        XCTAssertEqual(file.delimitedTable.configuration.filters, [2: "keep"])
        XCTAssertEqual(file.delimitedTable.columnWidths[2], 190)
        await file.save()
        XCTAssertEqual(try Data(contentsOf: url), bytes(expected))
        file.documentUndoManager.undo()
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.documentUndoManager.canUndo)
        file.documentUndoManager.redo()
        XCTAssertEqual(file.text, expected)
        XCTAssertEqual(try Data(contentsOf: url), bytes(expected))
    }

    func testNativeHeaderEditorKeepsFullRawValueAndRetainsUnrepresentableInput() async throws {
        for encoding in [TextFileEncoding.utf8BOM, .latin1] {
            let title = String(repeating: "long ", count: 850) + "A\rB\nC\r\nD"
            let original = "\"\(title)\",Value\r\nItem,old\n"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
            let baseline = try XCTUnwrap(encoding.encoded(original))
            try baseline.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            file.reopen(using: encoding)
            try await file.waitForText()
            file.autoSaveSuspendedForClose = true
            defer { file.retireContent() }
            let window = NSWindow(contentRect: NSRect(x: -800, y: -800, width: 330, height: 210),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: FileViewerView(file: file))
            window.contentView = host
            window.orderBack(nil)
            let grid = try await self.grid(in: host, showing: "Item")
            let header = try XCTUnwrap(grid.table.headerView)
            let origin = header.convert(NSPoint(x: 25, y: header.bounds.midY), to: nil)
            let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: origin, modifierFlags: [],
                                                        timestamp: 0, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            let menu = try XCTUnwrap(header.menu(for: click))
            let rename = try XCTUnwrap(menu.item(withTitle: String(localized: "Rename Header…", table: "Editor")))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(rename.action), to: rename.target, from: rename))

            let native = try XCTUnwrap(csvFullFieldEditor())
            XCTAssertEqual(Data(native.string.utf8), Data(title.utf8))
            let end = NSRange(location: native.string.utf16.count, length: 0)
            native.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: end)
            await file.save()
            XCTAssertTrue(native.hasMarkedText())
            XCTAssertTrue(file.hasPendingDelimitedEdit)
            XCTAssertEqual(try Data(contentsOf: url), baseline)
            native.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
            await file.save()
            if encoding == .latin1 {
                XCTAssertEqual(file.delimitedDraft?.value, title + "中文")
                XCTAssertTrue(file.hasPendingDelimitedEdit)
                XCTAssertFalse(file.documentUndoManager.canUndo)
                XCTAssertEqual(try Data(contentsOf: url), baseline)
                file.setFilePreview(false)
                XCTAssertEqual(file.delimitedDraft?.value, title + "中文")
                file.discardDelimitedDraft()
                XCTAssertFalse(file.hasPendingDelimitedEdit)
            } else {
                XCTAssertEqual(try Data(contentsOf: url), encoding.encoded("\"\(title)中文\",Value\r\nItem,old\n"))
                XCTAssertFalse(file.hasPendingDelimitedEdit)
                let deadline = ContinuousClock.now.advanced(by: .seconds(4))
                while file.delimitedTable.pendingSelection != nil, ContinuousClock.now < deadline {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(grid.table.wholeColumns, IndexSet(integer: 0))
                file.documentUndoManager.undo()
                XCTAssertEqual(Data(file.text.utf8), Data(original.utf8))
            }
        }
    }

    func testGridOpensWholeLongAndMultilineFieldsAndKeepsReadOnlyValuesCopyable() async throws {
        let previousLight = Theme.terminal(dark: false).name
        let previousDark = Theme.terminal(dark: true).name
        defer { Theme.reloadSelection(light: previousLight, dark: previousDark) }
        for (value, multiline, readOnly) in [
            (String(repeating: "a", count: 4093) + "🧪", false, false),
            (String(repeating: "a", count: 4094) + "🧪", false, false),
            (String(repeating: "a", count: 4095) + "🧪", false, false),
            (String(repeating: "字", count: 18_000), false, false),
            ("e\u{301}\rA\nB\r\nC", true, false),
            ("read-only\r\ncomplete", true, true),
        ] {
            let raw = multiline ? "\"\(value)\"" : value
            let original = "Name,Value\r\nItem,\(raw)\n" + (readOnly ? "Bad,\"open" : "")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
            try Data(original.utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await file.waitForText()
            file.autoSaveSuspendedForClose = true
            defer { file.retireContent() }
            let window = NSWindow(contentRect: NSRect(x: -800, y: -800, width: 220, height: 155),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            defer { window.close() }
            let host = NSHostingView(rootView: FileViewerView(file: file))
            window.contentView = host
            window.orderBack(nil)
            Theme.reloadSelection(light: "Default Light", dark: previousDark)
            let grid = try await self.grid(in: host, showing: "Item")
            grid.table.onEdit(.init(row: 0, column: 1))

            if !multiline && value.utf16.count <= 4096 {
                let field = try XCTUnwrap(grid.table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)
                XCTAssertNil(csvFullFieldEditor())
                XCTAssertEqual((field.currentEditor() as? NSTextView)?.string, value)
                grid.cancelEditing()
                XCTAssertFalse(file.hasPendingDelimitedEdit)
                continue
            }

            let editor = try XCTUnwrap(csvFullFieldEditor())
            XCTAssertEqual(Data(editor.string.utf8), Data(value.utf8))
            XCTAssertEqual(editor.isEditable, !readOnly)
            XCTAssertTrue(editor.isSelectable)
            if readOnly {
                XCTAssertFalse(file.hasPendingDelimitedEdit)
                editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8))
                continue
            }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            editor.insertText("新增", replacementRange: NSRange(location: NSNotFound, length: 0))
            let typed = value + "\n新增"
            XCTAssertEqual(Data(editor.string.utf8), Data(typed.utf8))
            let selection = editor.selectedRange()
            let initialBackground = editor.backgroundColor
            Theme.reloadSelection(light: "Rose Pine Dawn", dark: previousDark)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while editor.backgroundColor == initialBackground, ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotEqual(editor.backgroundColor, initialBackground)
            XCTAssertTrue(csvFullFieldEditor() === editor)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(file.text, original)
            await file.save()
            let expected = "Name,Value\r\nItem,\"\(typed)\"\n"
            XCTAssertEqual(try Data(contentsOf: url), Data(expected.utf8))
            file.documentUndoManager.undo()
            XCTAssertEqual(Data(file.text.utf8), Data(original.utf8))
        }
    }

    func testDeleteClearsOnlySelectedVisibleFieldsInOneNativeUndoStep() async throws {
        let original = "Name,Keep,Note\r\nItem,g,\"old\"\nHidden,h,untouched\rLast,g,stay"
        let expected = "Name,Keep,Note\r\n,g,\"\"\nHidden,h,untouched\rLast,g,stay"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try Data(original.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        defer { file.retireContent() }
        file.delimitedTable.configuration.filters[1] = "g"
        let window = NSWindow(contentRect: NSRect(x: -800, y: -800, width: 420, height: 190),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = host
        window.orderBack(nil)
        let grid = try await self.grid(in: host, showing: "Item")
        XCTAssertEqual(grid.table.numberOfRows, 2)
        XCTAssertTrue(window.makeFirstResponder(grid.table))
        grid.table.select(.init(row: 0, column: 0))
        grid.table.select(.init(row: 0, column: 2), adding: true)
        grid.table.select(.init(row: 0, column: 2), adding: true)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                                 isARepeat: false, keyCode: 51))
        grid.table.keyDown(with: key)
        let task = try XCTUnwrap(file.delimitedEditTask)
        let accepted = await task.value
        XCTAssertTrue(accepted)
        await file.save()
        XCTAssertEqual(try Data(contentsOf: url), Data(expected.utf8))
        file.documentUndoManager.undo()
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.documentUndoManager.canUndo)
        file.documentUndoManager.redo()
        XCTAssertEqual(file.text, expected)
    }

    func testFindReplaceMenuTargetsOnlyTheCurrentWritableCSV() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid.csv")
        let malformed = root.appendingPathComponent("malformed.csv")
        try Data("Name,Value\nItem,café CAFÉ\n".utf8).write(to: valid)
        try Data("Name,Value\nOther,readable\nBad,\"open".utf8).write(to: malformed)
        let application = WorkspaceApplication()
        let manager = application.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        manager.openFile(valid.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let first = try XCTUnwrap(project.selectedTab)
        guard case .file(let file) = first.content else { return XCTFail("Expected CSV FileTab") }
        try await file.waitForText()
        let window = NSWindow(contentRect: NSRect(x: -800, y: -800, width: 320, height: 190),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: AnyView(FileViewerView(file: file, canFocus: { false })))
        window.contentView = host
        manager.attach(to: window)
        window.orderBack(nil)
        _ = try await grid(in: host, showing: "Item")
        XCTAssertTrue(manager.canFind)
        XCTAssertTrue(manager.canReplace)
        manager.performFindAction(.replace)
        XCTAssertTrue(file.delimitedTable.showsReplace)
        file.delimitedTable.query = "cafe"
        func editableFields(in view: NSView) -> Int {
            if let field = view as? NSTextField, field.isEditable, !field.isHiddenOrHasHiddenAncestor { return 1 }
            return view.subviews.reduce(0) { $0 + editableFields(in: $1) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while editableFields(in: host) < 2, ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(editableFields(in: host), 2)
        manager.openFile(malformed.path)
        let second = try XCTUnwrap(project.selectedTab)
        guard case .file(let readOnly) = second.content else { return XCTFail("Expected CSV FileTab") }
        try await readOnly.waitForText()
        host.rootView = AnyView(FileViewerView(file: readOnly, canFocus: { false }).id(readOnly.id))
        _ = try await grid(in: host, showing: "Other")
        XCTAssertTrue(manager.canFind)
        XCTAssertFalse(manager.canReplace)
        manager.performFindAction(.show)
        XCTAssertTrue(readOnly.delimitedTable.showsFind)
        XCTAssertFalse(readOnly.delimitedTable.showsReplace)
        XCTAssertEqual(file.delimitedTable.query, "cafe")
    }

    func testReadOnlyGridOffersSelectionStatisticsWithoutAnyEdit() async throws {
        let original = "Name,Value\r\nItem,\nOther,7\nThird,\"\"\nBad,\"open"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try Data(original.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        defer { file.retireContent() }
        let window = NSWindow(contentRect: NSRect(x: -800, y: -800, width: 300, height: 195),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = host
        window.orderBack(nil)
        let grid = try await self.grid(in: host, showing: "Item")
        XCTAssertEqual(grid.table.numberOfRows, 3)
        grid.table.select(.init(row: 0, column: 1))
        grid.table.select(.init(row: 2, column: 1), extending: true)
        let cell = grid.table.frameOfCell(atColumn: 1, row: 0)
        let point = grid.table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try XCTUnwrap(grid.table.menu(for: click))
        let stats = try XCTUnwrap(menu.item(withTitle: String(localized: "Selection Statistics…", table: "Editor")))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(stats.action), to: stats.target, from: stats))
        XCTAssertNil(menu.item(withTitle: String(localized: "Clear Selected Fields", table: "Editor")))

        let pid = ProcessInfo.processInfo.processIdentifier
        let access = await Task.detached {
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString,
                                                  &windows).rawValue
        }.value
        XCTAssertEqual(access, AXError.success.rawValue)
        func attribute(_ element: NSObject, _ key: String) -> Any? {
            guard element.responds(to: NSSelectorFromString(key)) else { return nil }
            return element.value(forKey: key)
        }
        func descendants(_ element: NSObject) -> [NSObject] {
            let children = attribute(element, "accessibilityChildrenInNavigationOrder") as? [NSObject]
                ?? attribute(element, "accessibilityChildren") as? [NSObject] ?? []
            return [element] + children.flatMap(descendants)
        }
        func elements() -> [NSObject] {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return (host.accessibilityChildren() as? [NSObject] ?? []).flatMap(descendants)
        }
        func label(_ element: NSObject) -> String? {
            attribute(element, "accessibilityLabel") as? String
        }
        func statisticsValues() -> [String] {
            elements().compactMap {
                guard attribute($0, "accessibilityRole") as? String == "AXStaticText" else { return nil }
                return attribute($0, "accessibilityValue") as? String
            }
        }
        let expected = [("Fields", "3"), ("Empty", "2"), ("Numeric", "1"),
                        ("Other or Out of Range", "0"), ("Minimum", "7"), ("Maximum", "7"),
                        ("Sum", "7"), ("Average", "7")]
            .flatMap { [String(localized: String.LocalizationValue($0.0), table: "Editor"), $0.1] }
        func statisticsArePublished() -> Bool {
            let values = statisticsValues()
            return values.indices.contains { values.dropFirst($0).starts(with: expected) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !statisticsArePublished(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(statisticsArePublished(), "Actual statistics: \(statisticsValues())")
        let selected = grid.table.selection
        let revision = file.textPreviewRequestID
        let previousLight = Theme.terminal(dark: false).name
        let previousDark = Theme.terminal(dark: true).name
        defer { Theme.reloadSelection(light: previousLight, dark: previousDark) }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            Theme.reloadSelection(light: "Rose Pine Dawn", dark: "Dracula")
            let expectedColor = Theme.terminal(dark: dark).backgroundNSColor
            let repaint = ContinuousClock.now.advanced(by: .seconds(2))
            while grid.scrollView.backgroundColor != expectedColor, ContinuousClock.now < repaint {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(grid.scrollView.backgroundColor, expectedColor)
            XCTAssertTrue(statisticsArePublished(), "Changing the theme must preserve the result")
            XCTAssertEqual(grid.table.selection, selected)
            XCTAssertEqual(file.textPreviewRequestID, revision)
        }
        let buttonLabel = String(localized: "Find Visible Empty Fields", table: "Editor")
        let find = try XCTUnwrap(elements().first {
            (label($0) == buttonLabel || attribute($0, "accessibilityTitle") as? String == buttonLabel)
                && attribute($0, "accessibilityRole") as? String == "AXButton"
        })
        let press = NSSelectorFromString("accessibilityPerformPress")
        guard find.responds(to: press) else { return XCTFail("The empty-search button has no native action") }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let invoke = unsafeBitCast(find.method(for: press), to: Press.self)
        XCTAssertTrue(invoke(find, press))
        func matchCountIsPublished() -> Bool {
            elements().contains {
                attribute($0, "accessibilityIdentifier") as? String == "bailey.csv.match-count"
                    && (attribute($0, "accessibilityValue") as? String == "2" || label($0) == "2")
            }
        }
        let searchDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !matchCountIsPublished(), ContinuousClock.now < searchDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(file.delimitedTable.showsFind)
        XCTAssertTrue(matchCountIsPublished(), "Find must report the two real empty fields in the partial table")
        let matches: Set<DelimitedTablePresentation.Cell> = [.init(row: 0, column: 1), .init(row: 2, column: 1)]
        let first = try XCTUnwrap(grid.table.selection.caret)
        XCTAssertTrue(matches.contains(first))
        file.delimitedTable.perform(.next)
        let navigationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while grid.table.selection.caret == first, ContinuousClock.now < navigationDeadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let next = try XCTUnwrap(grid.table.selection.caret)
        XCTAssertEqual(Set([first, next]), matches)
        XCTAssertFalse(file.hasPendingDelimitedEdit)
        XCTAssertFalse(file.isDirty)
        XCTAssertFalse(file.documentUndoManager.canUndo)
        await file.save()
        XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8))
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
