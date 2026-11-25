import AppKit
import Darwin
import Foundation
import XCTest
@testable import Bailey

@MainActor
final class DelimitedTablePresentationTests: XCTestCase {
    func testNativeGridEditingAndPasteUsePhysicalRecordsAndOneUndoStack() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        let original = "Name,Group,Value\r\nItem 10,g,\"old\"\r\nItem 2,g,old\r\nOther,h,unchanged"
        let bytes = Data(original.utf8)
        try bytes.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        defer { file.retireContent() }
        let controls = file.delimitedTable
        controls.configuration.sort = [.init(column: 0, ascending: true)]
        controls.configuration.filters = [1: "g"]
        let grid = DelimitedGrid()
        grid.controls = controls
        grid.file = file
        grid.table.file = file
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = grid
        window.orderBack(nil)
        defer { grid.detach(); window.close() }

        func refresh() async throws {
            let result = try await file.delimitedSnapshot(using: .comma)
            let snapshot = try XCTUnwrap(result)
            let projection = try await DelimitedTablePresentation.evaluate(
                source: snapshot.source, index: snapshot.index, configuration: controls.configuration
            )
            grid.install(snapshot, presentation: projection)
            grid.layoutSubtreeIfNeeded()
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(condition())
        }
        try await refresh()
        XCTAssertTrue(grid.table.undoManager === file.documentUndoManager)
        XCTAssertEqual(grid.table.numberOfRows, 2)
        let cell = DelimitedTablePresentation.Cell(row: 0, column: 1)
        grid.table.select(cell, reveal: true)
        grid.paste("g\t\"青🧪\nline\"\r\ng\t\"a\"\"b\"")
        try await waitUntil { file.text.contains("青🧪") }
        let expected = "Name,Group,Value\r\nItem 10,g,\"a\"\"b\"\r\nItem 2,g,\"青🧪\nline\"\r\nOther,h,unchanged"
        XCTAssertEqual(file.text, expected)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        try await refresh()
        XCTAssertEqual(grid.table.selection.caret, cell)
        // An invalid clipboard cannot change a subset of the destination.
        grid.paste("x\ty\nragged")
        try await waitUntil { controls.editError != nil }
        XCTAssertEqual(file.text, expected)
        file.documentUndoManager.undo()
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.isDirty)
        file.documentUndoManager.redo()
        XCTAssertEqual(file.text, expected)
        try await refresh()
        grid.table.select(.init(row: 0, column: 2), reveal: true)
        grid.table.onEdit(.init(row: 0, column: 2))
        let field = try XCTUnwrap(grid.table.view(atColumn: 2, row: 0, makeIfNecessary: true) as? NSTextField)
        XCTAssertTrue(field.isEditable)
        XCTAssertEqual(field.stringValue, "青🧪\nline")
        let fieldEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        fieldEditor.insertText("discarded draft", replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
        fieldEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(file.text, expected)
        XCTAssertFalse(field.isEditable)
        grid.table.onEdit(.init(row: 0, column: 2))
        let nextEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        nextEditor.insertText("edited,field", replacementRange: NSRange(location: 0, length: nextEditor.string.utf16.count))
        XCTAssertTrue(window.makeFirstResponder(grid.table))
        try await waitUntil { file.text.contains("\"edited,field\"") }
        XCTAssertEqual(file.text, expected.replacingOccurrences(of: "\"青🧪\nline\"", with: "\"edited,field\""))
        file.documentUndoManager.undo()
        XCTAssertEqual(file.text, expected)
        file.documentUndoManager.undo()
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.isDirty)
        XCTAssertNil(file.editorView)
    }

    func testFocusedNativeGridReceivesStandardUndoAndRedoActions() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        let original = "Name,Value\r\nItem,old\n"
        try Data(original.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        defer { file.retireContent() }
        let grid = DelimitedGrid()
        grid.controls = file.delimitedTable
        grid.file = file
        grid.table.file = file
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentView!.bounds)
        grid.frame = container.bounds
        let other = NSTextField(frame: CGRect(x: 0, y: 0, width: 60, height: 20))
        container.addSubview(grid)
        container.addSubview(other)
        window.contentView = container
        window.orderBack(nil)
        defer { grid.detach(); window.close() }
        func refresh() async throws {
            let loaded = try await file.delimitedSnapshot(using: .comma)
            let snapshot = try XCTUnwrap(loaded)
            let presentation = try await DelimitedTablePresentation.evaluate(
                source: snapshot.source, index: snapshot.index, configuration: file.delimitedTable.configuration)
            grid.install(snapshot, presentation: presentation)
            grid.layoutSubtreeIfNeeded()
        }
        try await refresh()
        grid.table.onEdit(.init(row: 0, column: 1))
        let field = try XCTUnwrap(grid.table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("a,b", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(window.makeFirstResponder(grid.table))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while file.hasPendingDelimitedEdit, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let edited = "Name,Value\r\nItem,\"a,b\"\n"
        XCTAssertEqual(file.text, edited)
        XCTAssertTrue(file.documentUndoManager.canUndo)
        try await refresh()
        XCTAssertTrue(window.makeFirstResponder(grid.table))

        let undo = NSSelectorFromString("undo:")
        let redo = NSSelectorFromString("redo:")
        let undoItem = NSMenuItem(title: "Undo", action: undo, keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: redo, keyEquivalent: "Z")
        XCTAssertTrue(grid.table.responds(to: undo), "The focused table must implement the native menu action")
        XCTAssertTrue(grid.table.responds(to: redo))
        guard let validator = grid.table as? NSMenuItemValidation,
              grid.table.responds(to: undo), grid.table.responds(to: redo) else {
            return XCTFail("Standard Edit menu has no valid native responder")
        }
        XCTAssertTrue(validator.validateMenuItem(undoItem))
        XCTAssertFalse(validator.validateMenuItem(redoItem))
        _ = grid.table.perform(undo, with: undoItem)
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.isDirty)
        XCTAssertFalse(validator.validateMenuItem(undoItem))
        XCTAssertTrue(validator.validateMenuItem(redoItem))
        _ = grid.table.perform(redo, with: redoItem)
        XCTAssertEqual(file.text, edited)
        XCTAssertTrue(file.isDirty)
        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertFalse(validator.validateMenuItem(undoItem))
        _ = grid.table.perform(undo, with: undoItem)
        XCTAssertEqual(file.text, edited, "A different native text responder must own the command")
        XCTAssertEqual(try Data(contentsOf: path), Data(original.utf8))
        XCTAssertNil(file.editorView)
    }

    func testMountedGridRemainsEditableAfterPublishingTheSameTextRevision() async throws {
        for conversion in [nil, TextFileEncoding.utf16LEBOM] {
            let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".csv")
            let original = "Name,Value\r\nItem,old\n"
            try XCTUnwrap(TextFileEncoding.utf8BOM.encoded(original)).write(to: path)
            defer { try? FileManager.default.removeItem(at: path) }
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await file.waitForText()
            defer { file.retireContent() }
            let loaded = try await file.delimitedSnapshot(using: .comma)
            try await file.editDelimited(.cells([.init(row: 1, column: 1): "first"]), using: XCTUnwrap(loaded))
            let current = try await file.delimitedSnapshot(using: .comma)
            let snapshot = try XCTUnwrap(current)
            let presentation = try await DelimitedTablePresentation.evaluate(
                source: snapshot.source, index: snapshot.index, configuration: file.delimitedTable.configuration)
            let grid = DelimitedGrid()
            grid.controls = file.delimitedTable
            grid.file = file
            grid.table.file = file
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 260),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = grid
            window.orderBack(nil)
            defer { grid.detach(); window.close() }
            grid.install(snapshot, presentation: presentation)
            grid.layoutSubtreeIfNeeded()
            await file.save(as: conversion)
            XCTAssertFalse(file.isDirty)
            XCTAssertEqual(file.textPreviewRequestID, snapshot.requestID)
            XCTAssertTrue(file.canEditDelimited(snapshot), "Publishing a baseline must not invalidate the same source index")
            grid.table.onEdit(.init(row: 0, column: 1))
            let field = try XCTUnwrap(grid.table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)
            guard let editor = field.currentEditor() as? NSTextView else {
                XCTFail("The same mounted cell must remain editable after Save")
                continue
            }
            editor.insertText("中文", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            await file.save()
            let expected = "Name,Value\r\nItem,中文\n"
            XCTAssertEqual(file.text, expected)
            XCTAssertEqual(try Data(contentsOf: path), try XCTUnwrap((conversion ?? .utf8BOM).encoded(expected)))
        }
    }

    func testAcceptedGridEditsSurviveImmediateUnmountAndSave() async throws {
        for paste in [false, true] {
            let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".csv")
            let original = "Name,Value\r\nItem 10,old\r\nItem 2,old\n"
            func bytes(_ text: String) -> Data { Data([0xef, 0xbb, 0xbf]) + Data(text.utf8) }
            try bytes(original).write(to: path)
            defer { try? FileManager.default.removeItem(at: path) }
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await file.waitForText()
            defer { file.retireContent() }
            let controls = file.delimitedTable
            controls.configuration.sort = [.init(column: 0, ascending: true)]
            let grid = DelimitedGrid()
            grid.controls = controls
            grid.file = file
            grid.table.file = file
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 260),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = grid
            window.orderBack(nil)
            defer { grid.detach(); window.close() }
            let loaded = try await file.delimitedSnapshot(using: .comma)
            let snapshot = try XCTUnwrap(loaded)
            let presentation = try await DelimitedTablePresentation.evaluate(
                source: snapshot.source, index: snapshot.index, configuration: controls.configuration)
            grid.install(snapshot, presentation: presentation)
            grid.layoutSubtreeIfNeeded()
            let cell = DelimitedTablePresentation.Cell(row: 0, column: 1)
            grid.table.select(cell, reveal: true)
            if paste {
                grid.paste("\"中文,值\"")
            } else {
                grid.table.onEdit(cell)
                let field = try XCTUnwrap(grid.table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                XCTAssertTrue(editor.hasMarkedText())
                editor.insertText("中文,值", replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertFalse(editor.hasMarkedText())
                XCTAssertTrue(window.makeFirstResponder(grid.table))
            }
            // No run-loop delay between the user committing input and leaving
            // the table. Preparation/encoding has not had a chance to finish.
            XCTAssertEqual(file.text, original)
            grid.detach()
            file.setFilePreview(false)
            await file.save()
            let expected = "Name,Value\r\nItem 10,old\r\nItem 2,\"中文,值\"\n"
            XCTAssertEqual(file.text, expected, "paste=\(paste)")
            XCTAssertEqual(try Data(contentsOf: path), bytes(expected), "paste=\(paste)")
            XCTAssertFalse(file.isDirty)
            XCTAssertTrue(file.documentUndoManager.canUndo)
            file.documentUndoManager.undo()
            XCTAssertEqual(file.text, original)
            file.documentUndoManager.redo()
            XCTAssertEqual(file.text, expected)
        }
    }

    func testActiveNativeGridFieldIsIncludedInSaveAndProjectClose() async throws {
        for close in [false, true] {
            let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".csv")
            let original = "Name,Value\r\nItem,old\n"
            try Data(original.utf8).write(to: path)
            defer { try? FileManager.default.removeItem(at: path) }
            let project = Project(fallbackName: "Native table edit", workspaceConfiguration: .standard)
            project.openLocalFile(path.path)
            let tab = try XCTUnwrap(project.selectedTab)
            guard case .file(let file) = tab.content else { return XCTFail("Expected actual file") }
            try await file.waitForText()
            defer { project.terminateAll() }
            let controls = file.delimitedTable
            let grid = DelimitedGrid()
            grid.controls = controls
            grid.file = file
            grid.table.file = file
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 260),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = grid
            window.orderBack(nil)
            defer { grid.detach(); window.close() }
            let loaded = try await file.delimitedSnapshot(using: .comma)
            let snapshot = try XCTUnwrap(loaded)
            let presentation = try await DelimitedTablePresentation.evaluate(
                source: snapshot.source, index: snapshot.index, configuration: controls.configuration)
            grid.install(snapshot, presentation: presentation)
            grid.layoutSubtreeIfNeeded()
            grid.table.onEdit(.init(row: 0, column: 1))
            let field = try XCTUnwrap(grid.table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText("新值🧪", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            XCTAssertTrue(field.isEditable)
            XCTAssertEqual(file.text, original)
            // The native field still owns first responder when the user invokes
            // Save or closes the file tab through the project's real entry point.
            if close {
                project.close(tab)
                let deadline = ContinuousClock.now.advanced(by: .seconds(8))
                while project.tabs.contains(where: { $0 === tab }), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertFalse(project.tabs.contains(where: { $0 === tab }))
            } else {
                await file.save()
                XCTAssertEqual(file.text, "Name,Value\r\nItem,新值🧪\n")
                XCTAssertTrue(file.documentUndoManager.canUndo)
            }
            XCTAssertEqual(try Data(contentsOf: path), Data("Name,Value\r\nItem,新值🧪\n".utf8), "close=\(close)")
        }
    }

    func testProjectionDoesNotFilterRowsUsingColumnsAbsentFromTheNewIndex() async throws {
        let source = "Name;Value\nItem;42\nOther;2"
        let index = try await DelimitedTableIndex.parse(source, preferred: .comma, selected: .semicolon)
        let stale = DelimitedTablePresentation.Configuration(
            filters: [2: "unavailable"], sort: [.init(column: 2, ascending: true)]
        )
        let result = try await DelimitedTablePresentation.evaluate(source: source, index: index, configuration: stale)
        XCTAssertEqual(result.rows, [1, 2])
    }

    func testAcceptedColumnLayoutClearsOnlySettingsForDifferentFields() async throws {
        let controls = DelimitedTableControls()
        let original = try await DelimitedTableIndex.parse("A,B,C\n1,2,3", preferred: .comma)
        controls.accept(original)
        controls.configuration.filters = [0: "1", 2: "3"]
        controls.configuration.sort = [.init(column: 2, ascending: true)]
        let narrower = try await DelimitedTableIndex.parse("A,B\n1,2", preferred: .comma)
        controls.accept(narrower)
        XCTAssertEqual(controls.configuration.filters, [0: "1"])
        XCTAssertTrue(controls.configuration.sort.isEmpty)
        controls.configuration.header = false
        let different = try await DelimitedTableIndex.parse("A;B\n1;2", preferred: .comma)
        controls.accept(different)
        XCTAssertTrue(controls.configuration.filters.isEmpty)
        XCTAssertFalse(controls.configuration.header)
    }

    func testRepeatedNativeTableMountsClearRowsAndSelectionInBothAppearances() async throws {
        let text = "Name,Value\nApple,1\nBanana,2\n"
        let index = try await DelimitedTableIndex.parse(text, preferred: .comma)
        let presentation = try await DelimitedTablePresentation.evaluate(
            source: text, index: index, configuration: .init()
        )
        let viewport = CGRect(x: 0, y: 0, width: 460, height: 280)
        let window = NSWindow(contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var before = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        let started = ContinuousClock.now
        for serial in 0..<100 {
            try autoreleasepool {
                window.appearance = NSAppearance(named: serial.isMultiple(of: 2) ? .aqua : .darkAqua)
                let grid = DelimitedGrid()
                window.contentView = grid
                grid.install(.init(index: index, source: text, requestID: String(serial), documentRevision: String(serial)),
                             presentation: presentation)
                grid.layoutSubtreeIfNeeded()
                grid.table.select(.init(row: 1, column: 1), reveal: true)
                let cell = try XCTUnwrap(grid.table.view(atColumn: 1, row: 1, makeIfNecessary: true) as? NSTextField)
                XCTAssertEqual(cell.stringValue, "2")
                XCTAssertTrue(cell.isAccessibilitySelected())
                grid.detach()
                XCTAssertEqual(grid.table.numberOfRows, 0)
                XCTAssertTrue(grid.table.selection.blocks.isEmpty)
                window.contentView = nil
            }
        }
        var after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        print("CSV_TABLE_MOUNTS count=100 elapsed=\(started.duration(to: .now)) maxrss_before=\(before.ru_maxrss) maxrss_after=\(after.ru_maxrss)")
    }

    func testNativeGridVirtualizesTallAndWideTablesAndCanReachTheirLastCells() async throws {
        let viewport = CGRect(x: 0, y: 0, width: 480, height: 330)
        let window = NSWindow(contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let grid = DelimitedGrid()
        window.contentView = grid
        let tall = "Name,Value\n" + (0..<100_000).map { "Row \($0),\($0)\n" }.joined()
        let wide = (0..<2501).map { "column \($0)" }.joined(separator: ",") + "\n"
            + (0..<2501).map { "cell \($0)" }.joined(separator: ",")
        for (source, row, column, expected) in [
            (tall, 99_999, 1, "99999"),
            (wide, 0, 2500, "cell 2500"),
        ] {
            let index = try await DelimitedTableIndex.parse(source, preferred: .comma)
            let presentation = try await DelimitedTablePresentation.evaluate(
                source: source, index: index, configuration: .init()
            )
            grid.install(.init(index: index, source: source, requestID: expected, documentRevision: expected),
                         presentation: presentation)
            grid.layoutSubtreeIfNeeded()
            grid.table.select(.init(row: row, column: column), reveal: true)
            grid.layoutSubtreeIfNeeded()
            XCTAssertTrue(grid.table.frameOfCell(atColumn: column, row: row).intersects(grid.table.visibleRect))
            let field = try XCTUnwrap(grid.table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)
            XCTAssertEqual(field.stringValue, expected)
            XCTAssertTrue(field.isAccessibilitySelected())
            var realizedRows = 0
            grid.table.enumerateAvailableRowViews { _, _ in realizedRows += 1 }
            XCTAssertLessThan(realizedRows, 100)
        }
        grid.detach()
        XCTAssertEqual(grid.table.numberOfRows, 0)
    }

    func testSortedAndFilteredRowsRetainSourceIdentityAndFindQuotedCells() async throws {
        let source = "Name,Group,Value\r\nItem 10,Équipe,blue\r\nItem 2,equipe,\"blue\r\nred\"\r\nItem 3,Other,blue\r\n"
        let index = try await DelimitedTableIndex.parse(source, preferred: .comma)
        let configuration = DelimitedTablePresentation.Configuration(
            filters: [1: "equipe", 2: "blue"], sort: [.init(column: 0, ascending: true)]
        )
        let ordered = try await DelimitedTablePresentation.evaluate(
            source: source, index: index, configuration: configuration
        )
        XCTAssertEqual(ordered.rows, [2, 1])
        let matches = try await ordered.find("red", source: source, index: index, columnCount: 3)
        XCTAssertEqual(matches, [.init(row: 0, column: 2)])
        let original = source as NSString
        XCTAssertEqual(original.substring(with: index.records[2].source),
                       "Item 2,equipe,\"blue\r\nred\"\r\n")
        let reset = try await DelimitedTablePresentation.evaluate(
            source: source, index: index, configuration: .init(header: false)
        )
        XCTAssertEqual(reset.rows, [0, 1, 2, 3])
    }

    func testCopyUsesSelectedCellsInDisplayOrderWithoutLosingQuotesOrLineBreaks() async throws {
        let source = "Name,Text,Value\r\nB,\"a\"\"b\r\nc\",20\r\nA,one,10"
        let index = try await DelimitedTableIndex.parse(source, preferred: .comma)
        let ordered = try await DelimitedTablePresentation.evaluate(
            source: source, index: index, configuration: .init(sort: [.init(column: 0, ascending: true)])
        )
        var selection = DelimitedTablePresentation.Selection()
        selection.select(.init(row: 0, column: 0))
        selection.select(.init(row: 1, column: 1), adding: true)
        let copied = try await ordered.copy(selection, source: source, index: index)
        XCTAssertEqual(copied, "A\t\n\t\"a\"\"b\r\nc\"")
        selection.select(.init(row: 0, column: 1))
        selection.select(.init(row: 1, column: 2), extending: true)
        let rectangle = try await ordered.copy(selection, source: source, index: index)
        XCTAssertEqual(rectangle, "one\t10\n\"a\"\"b\r\nc\"\t20")
    }

    func testLargeDisplayEvaluatesOnDemandAndCanceledSearchHasNoResult() async throws {
        let source = "Name,Group\n" + (0..<100_000).map { "Item \($0),\($0 % 2)\n" }.joined()
        let index = try await DelimitedTableIndex.parse(source, preferred: .comma)
        let display = try await DelimitedTablePresentation.evaluate(
            source: source, index: index,
            configuration: .init(filters: [1: "1"], sort: [.init(column: 0, ascending: false)])
        )
        XCTAssertEqual(display.rows.count, 50_000)
        XCTAssertEqual(display.rows.first, 100_000)
        XCTAssertEqual(display.rows.last, 2)
        let search = Task { try await display.find("Item", source: source, index: index, columnCount: 2) }
        search.cancel()
        do {
            _ = try await search.value
            XCTFail("Canceled view search must not publish matches")
        } catch is CancellationError {}
    }
}
