import AppKit
import Foundation
import XCTest

@MainActor
final class CSVPreviewUITests: XCTestCase {
    func testFocusedFontCommandsAdjustOnlyTheVisibleContentKind() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("workspace/Zoom.csv", text: "Name,Value\nAlpha,123\nBeta,456\n")
        let config = try fixture.file(".config/bailey-dev/config.toml", text: "font-size = 15\npanel.font-size = 14\neditor.font-size = 13\ntable.font-size = 11\nreader.font-size = 16\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", configurationHome: fixture.root,
                                                    project: file.deletingLastPathComponent(), clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        let cell = table.staticTexts["Alpha"]
        XCTAssertTrue(cell.waitForExistence(timeout: 12))
        cell.click()
        let originalHeight = cell.frame.height
        func expect(_ key: String, _ size: Int) {
            let persisted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
                return text.split(separator: "\n").contains { $0 == "\(key) = \(size)" }
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 5), .completed,
                           "\(key) must be \(size); \((try? String(contentsOf: config, encoding: .utf8)) ?? "unreadable")")
        }
        app.menuBarItems["Window"].click()
        let windowMenu = try XCTUnwrap(app.menus.allElementsBoundByIndex.first {
            $0.menuItems["Bring All to Front"].exists
        })
        XCTAssertTrue(windowMenu.menuItems["Move & Resize"].exists)
        XCTAssertTrue(windowMenu.menuItems["Zoom In"].isEnabled)
        XCTAssertTrue(windowMenu.menuItems["Zoom Out"].isEnabled)
        XCTAssertTrue(windowMenu.menuItems["Reset Zoom"].isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey("+", modifierFlags: .command)
        expect("table.font-size", 12)
        let larger = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in cell.frame.height > originalHeight }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [larger], timeout: 5), .completed)
        expect("font-size", 15)
        expect("editor.font-size", 13)
        app.menuBarItems["Window"].click()
        windowMenu.menuItems["Zoom Out"].click()
        expect("table.font-size", 11)
        app.typeKey("+", modifierFlags: .command)
        expect("table.font-size", 12)
        app.typeKey("-", modifierFlags: .command)
        expect("table.font-size", 11)
        app.typeKey("+", modifierFlags: .command)
        expect("table.font-size", 12)
        app.typeKey("0", modifierFlags: .command)
        expect("table.font-size", 11)

        app.typeKey("v", modifierFlags: [.command, .shift])
        let source = window.textViews.firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.click()
        app.typeKey("+", modifierFlags: .command)
        expect("editor.font-size", 14)
        expect("table.font-size", 11)
        expect("font-size", 15)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Name,Value\nAlpha,123\nBeta,456\n")
    }

    func testWindowShortcutAndBackgroundTabMenuKeepTheirOwnCSVTargets() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let backgroundSource = "Name,Value\nBackground,17\n"
        let foregroundSource = "Name,Value\nForeground,38\n"
        let otherSource = "Name,Value\nOther window,61\n"
        let backgroundFile = try fixture.file("one/shared.csv", text: backgroundSource)
        let foregroundFile = try fixture.file("one/visible.csv", text: foregroundSource)
        let otherFile = try fixture.file("two/shared.csv", text: otherSource)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: backgroundFile.deletingLastPathComponent())
        let firstID = app.windows.firstMatch.identifier
        let first = app.windows.matching(identifier: firstID).firstMatch
        func open(_ file: URL, in window: XCUIElement) {
            let row = WorkspaceUITestSupport.fileRow(file, in: window)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
        }
        func table(in window: XCUIElement) -> XCUIElement {
            window.descendants(matching: .any).matching(identifier: "bailey.csv.table").firstMatch
        }
        let tabMenu = app.menus.containing(.menuItem, identifier: "Close Others").firstMatch

        open(backgroundFile, in: first)
        let background = WorkspaceUITestSupport.fileTab(backgroundFile, in: first)
        XCTAssertTrue(background.waitForExistence(timeout: 10))
        open(foregroundFile, in: first)
        XCTAssertTrue(table(in: first).staticTexts["Foreground"].waitForExistence(timeout: 10))
        XCTAssertFalse(background.isSelected)
        background.rightClick()
        let showSource = WorkspaceUITestSupport.menuItem("Show Source", in: tabMenu)
        XCTAssertTrue(showSource.waitForExistence(timeout: 5))
        showSource.click()
        XCTAssertTrue(table(in: first).staticTexts["Foreground"].exists)
        XCTAssertFalse(background.isSelected)
        background.click()
        let firstEditor = first.textViews.firstMatch
        XCTAssertTrue(firstEditor.waitForExistence(timeout: 10))
        XCTAssertEqual(firstEditor.value as? String, backgroundSource)

        app.typeKey("n", modifierFlags: [.command, .shift])
        let other = app.windows.matching(NSPredicate(format: "identifier != %@", firstID)).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 15))
        try WorkspaceUITestSupport.addFolder(otherFile.deletingLastPathComponent(), to: app, in: other)
        other.descendants(matching: .any).matching(identifier: "bailey.dock.files").firstMatch.click()
        open(otherFile, in: other)
        let secondTable = table(in: other)
        XCTAssertTrue(secondTable.staticTexts["Other window"].waitForExistence(timeout: 10))
        secondTable.staticTexts["Other window"].click()
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(secondTable.waitForNonExistence(timeout: 10))
        XCTAssertEqual(other.textViews.firstMatch.value as? String, otherSource)
        XCTAssertEqual(firstEditor.value as? String, backgroundSource)

        WorkspaceUITestSupport.fileTab(otherFile, in: other).rightClick()
        let split = WorkspaceUITestSupport.menuItem("Show Side by Side", in: tabMenu)
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.click()
        XCTAssertTrue(secondTable.staticTexts["Other window"].waitForExistence(timeout: 10))
        let initial = secondTable.frame
        let edge = try XCTUnwrap(other.otherElements.matching(identifier: "bailey.dock.divider")
            .allElementsBoundByIndex.filter { $0.frame.height > 60 && $0.frame.width < 30 }.min {
                min(abs($0.frame.midX - initial.minX), abs($0.frame.midX - initial.maxX)) <
                    min(abs($1.frame.midX - initial.minX), abs($1.frame.midX - initial.maxX))
            })
        let divider = edge.frame
        let start = other.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: divider.midX - other.frame.minX, dy: divider.midY - other.frame.minY)
        )
        let direction: CGFloat = divider.midX < initial.midX ? 1 : -1
        start.click(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: direction * 75, dy: 0)))
        XCTAssertLessThan(secondTable.frame.width, initial.width - 20)
        XCTAssertTrue(secondTable.staticTexts["Other window"].exists)
        XCTAssertEqual(try Data(contentsOf: backgroundFile), Data(backgroundSource.utf8))
        XCTAssertEqual(try Data(contentsOf: foregroundFile), Data(foregroundSource.utf8))
        XCTAssertEqual(try Data(contentsOf: otherFile), Data(otherSource.utf8))
    }

    func testSystemFileDeliveryAndColdRestoreDisplayTheSameNativeTable() async throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "Name,Value\r\nFinder sample,17\r\n"
        let file = try fixture.file("Finder sample.csv", text: original)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root, project: fixture.root, clipboardIsReadOnly: true
        )
        let devID = "chiimagnus.bailey.dev"
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: devID)
        guard applications.count == 1, let owner = applications.first else {
            return XCTFail("System delivery must have exactly one isolated Bailey Dev recipient")
        }
        let bundleURL = try XCTUnwrap(owner.bundleURL)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = app.launchArguments
        configuration.environment = app.launchEnvironment
        let delivered = try await NSWorkspace.shared.open([file], withApplicationAt: bundleURL, configuration: configuration)
        XCTAssertEqual(delivered.processIdentifier, owner.processIdentifier)
        XCTAssertEqual(delivered.bundleIdentifier, devID)
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        XCTAssertTrue(table.staticTexts["17"].waitForExistence(timeout: 15))
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: app.windows.firstMatch).exists)

        app.typeKey("q", modifierFlags: .command)
        let quit = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.state == .notRunning }, object: nil)
        let quitResult = await XCTWaiter.fulfillment(of: [quit], timeout: 12)
        XCTAssertEqual(quitResult, .completed)
        guard app.state == .notRunning else { return XCTFail("The original Dev instance must quit before relaunch") }
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: app.windows.firstMatch).waitForExistence(timeout: 15))
        XCTAssertTrue(table.staticTexts["Finder sample"].waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
    }

    func testSortingFilteringFindingAndCopyingUseDisplayedCellsWithoutWritingSource() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "Name,Group,Value\r\nItem 10,equipe,orange\r\nItem 2,Équipe,blue\r\nOther,elsewhere,green\r\n"
        let file = try fixture.file("samples.csv", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        let two = table.staticTexts["Item 2"]
        let ten = table.staticTexts["Item 10"]
        XCTAssertTrue(two.waitForExistence(timeout: 12))
        func header(_ title: String) -> XCUIElement {
            table.buttons.matching(NSPredicate(format: "title == %@", title)).firstMatch
        }

        XCTAssertGreaterThan(two.frame.minY, ten.frame.minY)
        let name = header("Name")
        XCTAssertTrue(name.exists, table.debugDescription)
        name.click()
        XCTAssertGreaterThan(two.frame.minY, ten.frame.minY, "Selecting a heading must not sort the data")
        name.rightClick()
        let sort = WorkspaceUITestSupport.menuItem("Sort Ascending", in: app)
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        sort.click()
        let sorted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            two.exists && ten.exists && two.frame.minY < ten.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sorted], timeout: 8), .completed)

        let group = header("Group")
        XCTAssertTrue(group.exists, table.debugDescription)
        group.rightClick()
        let filterAction = WorkspaceUITestSupport.menuItem("Filter Column…", in: app)
        XCTAssertTrue(filterAction.waitForExistence(timeout: 5))
        filterAction.click()
        let filter = app.textFields["bailey.csv.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.click()
        filter.typeText("equipe\n")
        XCTAssertTrue(table.staticTexts["Other"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(two.exists)
        XCTAssertTrue(ten.exists)

        two.click()
        app.typeKey("f", modifierFlags: .command)
        let find = app.textFields["bailey.csv.find"]
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        find.typeText("blue")
        XCTAssertEqual(find.value as? String, "blue")
        let count = app.staticTexts["bailey.csv.match-count"]
        let found = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR label == %@", "1", "1"), object: count
        )
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 5), .completed, count.debugDescription)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(find.waitForNonExistence(timeout: 5))

        two.click()
        XCUIElement.perform(withKeyModifiers: .shift) { table.staticTexts["blue"].click() }
        let beforeCopy = NSPasteboard.general.changeCount
        app.typeKey("c", modifierFlags: .command)
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSPasteboard.general.changeCount != beforeCopy &&
                NSPasteboard.general.string(forType: .string) == "Item 2\tÉquipe\tblue"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 8), .completed)
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
    }

    func testSortedGridAndSourceShareNativeUndoAndExactSave() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "Name,Group,Value\r\nItem 10,\"équipe\",orange\r\nItem 2,中文,blue\nOther,elsewhere,green\r\n"
        let gridEdit = original.replacingOccurrences(of: ",blue\n", with: ",\"a,b\"\n")
        let sourceEdit = gridEdit.replacingOccurrences(of: ",green\r\n", with: ",olive\r\n")
        func encoded(_ text: String) -> Data { Data([0xef, 0xbb, 0xbf]) + Data(text.utf8) }
        let file = try fixture.file("Editable.csv", text: original)
        try encoded(original).write(to: file, options: .atomic)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        let blue = table.staticTexts["blue"]
        XCTAssertTrue(blue.waitForExistence(timeout: 12))
        XCTAssertFalse(window.textViews.firstMatch.exists, "The grid starts without a source editor")
        let two = table.staticTexts["Item 2"], ten = table.staticTexts["Item 10"]
        let name = table.buttons.matching(NSPredicate(format: "title == %@", "Name")).firstMatch
        XCTAssertTrue(name.exists)
        name.rightClick()
        let sort = WorkspaceUITestSupport.menuItem("Sort Ascending", in: app)
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        sort.click()
        let sorted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            two.exists && ten.exists && two.frame.minY < ten.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sorted], timeout: 8), .completed)

        blue.doubleClick()
        app.typeText("a,b")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let changed = table.staticTexts["a,b"]
        XCTAssertTrue(changed.waitForExistence(timeout: 10))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(blue.waitForExistence(timeout: 10))
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(changed.waitForExistence(timeout: 10))

        changed.click()
        app.typeKey("v", modifierFlags: [.command, .shift])
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(Data((editor.value as? String ?? "").utf8), Data(gridEdit.utf8))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(sourceEdit, forType: .string))
        editor.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(Data((editor.value as? String ?? "").utf8), Data(sourceEdit.utf8))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let olive = table.staticTexts["olive"], green = table.staticTexts["green"]
        XCTAssertTrue(olive.waitForExistence(timeout: 10))
        olive.click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(green.waitForExistence(timeout: 10))
        XCTAssertTrue(changed.exists)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(blue.waitForExistence(timeout: 10))
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(changed.waitForExistence(timeout: 10))
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(olive.waitForExistence(timeout: 10))
        olive.click()
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == encoded(sourceEdit)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed,
                       "Saving must preserve BOM, physical row order, quotes and mixed line endings")
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(tab.waitForNonExistence(timeout: 10))
        row.doubleClick()
        XCTAssertTrue(olive.waitForExistence(timeout: 10))
        XCTAssertTrue(changed.exists)
        XCTAssertEqual(try Data(contentsOf: file), encoded(sourceEdit))
    }

    func testRealContextMenuAndStructuralEditsSaveExactBytes() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "Name,Value,Note\nAlpha,1,one\nBeta,2,two\nGamma,3,three\n"
        let file = try fixture.file("Context.csv", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root,
                                                    clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        XCTAssertTrue(table.staticTexts["Alpha"].waitForExistence(timeout: 12))
        func menu(_ title: String, at element: XCUIElement) {
            element.rightClick()
            let item = WorkspaceUITestSupport.menuItem(title, in: app)
            XCTAssertTrue(item.waitForExistence(timeout: 5), title)
            XCTAssertTrue(item.isEnabled, title)
            item.click()
        }
        func save(_ expected: String) {
            app.typeKey("s", modifierFlags: .command)
            let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (try? Data(contentsOf: file)) == Data(expected.utf8)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed,
                           "Expected \(expected); actual \((try? String(contentsOf: file, encoding: .utf8)) ?? "unreadable")")
        }
        func undo() {
            app.typeKey("z", modifierFlags: .command)
            save(original)
        }
        func header(_ title: String) -> XCUIElement {
            table.buttons.matching(NSPredicate(format: "title == %@", title)).firstMatch
        }

        // Ordinary cells never expose row operations, even with a multi-cell selection.
        table.staticTexts["1"].click()
        for multi in [false, true] {
            if multi { XCUIElement.perform(withKeyModifiers: .shift) { table.staticTexts["2"].click() } }
            table.staticTexts["1"].rightClick()
            for title in ["Insert Row After", "Delete Rows", "Fill Selected Cells…"] {
                XCTAssertFalse(WorkspaceUITestSupport.menuItem(title, in: app).exists, title)
            }
        }
        let gutter = WorkspaceUITestSupport.element("bailey.csv.records", in: app)
        XCTAssertTrue(gutter.exists)
        func record(at cell: XCUIElement) -> XCUICoordinate {
            let point = CGPoint(x: gutter.frame.midX, y: cell.frame.midY)
            XCTAssertTrue(gutter.frame.contains(point), "Row number must be inside the gutter")
            return window.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY))
        }
        record(at: table.staticTexts["Alpha"]).rightClick()
        let insertRow = WorkspaceUITestSupport.menuItem("Insert Row After", in: app)
        XCTAssertTrue(insertRow.waitForExistence(timeout: 5))
        XCTAssertFalse(WorkspaceUITestSupport.menuItem("Fill Selected Cells…", in: app).exists)
        insertRow.click()
        save("Name,Value,Note\nAlpha,1,one\n,,\nBeta,2,two\nGamma,3,three\n")
        undo()
        let beta = table.staticTexts["Beta"]
        XCTAssertTrue(beta.waitForExistence(timeout: 5))
        record(at: beta).click()
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        save("Name,Value,Note\nAlpha,1,one\n,,\nGamma,3,three\n")
        undo()
        XCTAssertTrue(beta.waitForExistence(timeout: 5))
        record(at: beta).rightClick()
        let deleteRows = WorkspaceUITestSupport.menuItem("Delete Rows", in: app)
        XCTAssertTrue(deleteRows.waitForExistence(timeout: 5))
        deleteRows.click()
        save("Name,Value,Note\nAlpha,1,one\nGamma,3,three\n")
        undo()

        menu("Insert Column Right", at: header("Value"))
        save("Name,Value,,Note\nAlpha,1,,one\nBeta,2,,two\nGamma,3,,three\n")
        undo()
        menu("Move Column Left", at: header("Value"))
        save("Value,Name,Note\n1,Alpha,one\n2,Beta,two\n3,Gamma,three\n")
        undo()
        header("Note").rightClick()
        let deleteColumn = WorkspaceUITestSupport.menuItem("Delete Column", in: app)
        XCTAssertTrue(deleteColumn.waitForExistence(timeout: 5))
        XCTAssertFalse(WorkspaceUITestSupport.menuItem("Changes All Records", in: app).exists)
        deleteColumn.click()
        save("Name,Value\nAlpha,1\nBeta,2\nGamma,3\n")
        undo()

        for key in [XCUIKeyboardKey.delete, .forwardDelete] {
            XCTAssertTrue(table.staticTexts["Alpha"].waitForExistence(timeout: 5))
            table.staticTexts["Alpha"].click()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(key.rawValue, modifierFlags: [])
            save("Name,Value,Note\n,,\n,,\n,,\n")
            undo()
        }
    }

    func testEmptyCSVInsertCreatesHeaderAndEditableDataRow() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("Empty.csv", text: "")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root,
                                                    clipboardIsReadOnly: true)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let insert = app.buttons["Insert Row"]
        XCTAssertTrue(insert.waitForExistence(timeout: 10))
        insert.click()
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let rows = table.descendants(matching: .tableRow)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 1)
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8)) == "\"\"\n\"\"\n"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
    }

    func testMultilineFieldsRenderAndEditInTheTableWithoutPopover() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "编号,文本,值\n001,含\tTab 字段,1\n002,\"包含\n换行\",=1+1\n003,中文🛰️11,11131\n"
        let file = try fixture.file("Multiline.csv", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root,
                                                    clipboardIsReadOnly: true)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        let first = table.staticTexts["001"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let multi = table.staticTexts.matching(NSPredicate(format: "value == %@", "包含\n换行")).firstMatch
        XCTAssertTrue(multi.exists, app.debugDescription)
        XCTAssertGreaterThan(multi.frame.height, first.frame.height)
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "CSV actual multiline display"
        before.lifetime = .keepAlways
        add(before)
        first.doubleClick()
        let editor = WorkspaceUITestSupport.element("bailey.csv.cell.editor", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let initialWidth = editor.frame.width
        let value = "Expanded1234567890123456789012345"
        app.typeText(value)
        XCTAssertGreaterThan(editor.frame.width, initialWidth + 30)
        XCTAssertFalse(app.buttons["Apply Field"].exists)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .option)
        app.typeText("second")
        XCTAssertTrue(editor.exists)
        XCTAssertEqual(editor.value as? String, value + "\nsecond")
        let during = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        during.name = "CSV expanding in-cell editor"
        during.lifetime = .keepAlways
        add(during)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8))
        app.typeKey("s", modifierFlags: .command)
        let expected = original.replacingOccurrences(of: "001,", with: "\"\(value)\nsecond\",")
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == Data(expected.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        app.typeKey("s", modifierFlags: .command)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == Data(original.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
    }

    func testCompactColumnsAndDirectHeaderEditingWithoutRedundantMenus() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "A;B;C;材料;加载方式;应变率(s⁻¹);备注\n"
            + "1;2;3;天然页岩;SHPB 单轴动态压缩;82.4;baseline\n"
            + "4;5;6;泥页岩;巴西劈裂;116.3;轴向加载\n"
            + "7;8;9;页岩;循环冲击;1.20e2;测量值\n"
        let file = try fixture.file("Layout.csv", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root,
                                                    clipboardIsReadOnly: true)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        XCTAssertTrue(table.staticTexts["1"].waitForExistence(timeout: 12))
        func header(_ title: String) -> XCUIElement {
            table.buttons.matching(NSPredicate(format: "title == %@", title)).firstMatch
        }
        let first = header("A")
        XCTAssertTrue(first.exists)
        let narrow = first.frame.width
        XCTAssertTrue((23...30).contains(narrow))
        XCTAssertTrue((17...21).contains(first.frame.height))
        XCTAssertTrue(table.staticTexts["天然页岩"].exists)
        let compact = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        compact.name = "CSV compact - mixed Chinese English and numeric"
        compact.lifetime = .keepAlways
        add(compact)
        let gutter = WorkspaceUITestSupport.element("bailey.csv.records", in: app)
        XCTAssertTrue(gutter.exists)
        XCTAssertLessThan(gutter.frame.width, 30)
        first.rightClick()
        let filter = WorkspaceUITestSupport.menuItem("Filter Column…", in: app)
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        for title in ["Delimiter", "Rename Header…", "Fit Column Width", "Column Statistics…", "Use First Row as Header"] {
            XCTAssertFalse(WorkspaceUITestSupport.menuItem(title, in: app).exists, title)
        }
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(filter.waitForNonExistence(timeout: 5))
        first.doubleClick()
        app.typeText("Measured")
        app.typeKey(" ", modifierFlags: [])
        app.typeText("strain")
        app.typeKey(" ", modifierFlags: [])
        app.typeText("rate")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let renamed = header("Measured strain rate")
        XCTAssertTrue(renamed.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertGreaterThan(renamed.frame.width, narrow + 30)
        app.typeKey("s", modifierFlags: .command)
        let expected = original.replacingOccurrences(of: "A;", with: "Measured strain rate;")
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == Data(expected.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertEqual(first.frame.width, narrow, accuracy: 1)
        app.typeKey("s", modifierFlags: .command)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == Data(original.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
    }

    func testColumnMenuWithoutStatisticsAndReplaceThroughActualControls() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "Name,Value,Note\nAlpha,12,old old\nBeta,,old\nGamma,3,hidden\nDelta,7,keep\n"
        let file = try fixture.file("Analysis.csv", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root,
                                                    clipboardIsReadOnly: true)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        XCTAssertTrue(table.staticTexts["Alpha"].waitForExistence(timeout: 12))
        let value = table.buttons.matching(NSPredicate(format: "title == %@", "Value")).firstMatch
        XCTAssertTrue(value.exists)
        value.rightClick()
        let filter = WorkspaceUITestSupport.menuItem("Filter Column…", in: app)
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        XCTAssertFalse(WorkspaceUITestSupport.menuItem("Column Statistics…", in: app).exists)
        XCTAssertFalse(WorkspaceUITestSupport.menuItem("Find Visible Empty Fields", in: app).exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(filter.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
        let find = app.textFields["bailey.csv.find"]

        table.staticTexts["old old"].click()
        app.typeKey("f", modifierFlags: [.command, .option])
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        find.click()
        find.typeText("old")
        let replacement = app.textFields["bailey.csv.replacement"]
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        replacement.click()
        replacement.typeText("new")
        let replace = app.buttons["Replace"].firstMatch
        let replaceAll = app.buttons["Replace All"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: replace)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, app.debugDescription)
        replace.click()
        XCTAssertTrue(table.staticTexts["new old"].waitForExistence(timeout: 8))
        let readyAll = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: replaceAll)
        XCTAssertEqual(XCTWaiter.wait(for: [readyAll], timeout: 5), .completed)
        replaceAll.click()
        XCTAssertTrue(table.staticTexts["new new"].waitForExistence(timeout: 8))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        // Closing the overlay through its actual button works even if it owns focus.
        if find.exists { app.buttons["Close"].firstMatch.click() }
        table.staticTexts["new new"].click()
        app.typeKey("s", modifierFlags: .command)
        let expected = original.replacingOccurrences(of: "old", with: "new")
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == Data(expected.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
    }

    func testLargeRealTableFindEditAndSaveRetainAllOtherBytes() throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_PREVIEW_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_PREVIEW_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = URL(fileURLWithPath: root).appending(path: "tables/100000行.csv")
        let original = try Data(contentsOf: source)
        let text = try XCTUnwrap(String(data: original, encoding: .utf8))
        let lastRecord = try XCTUnwrap(text.split(whereSeparator: \.isNewline).last)
        XCTAssertTrue(lastRecord.hasPrefix("100000,"))
        let expected = text.replacingOccurrences(of: String(lastRecord), with: "100001," + lastRecord.dropFirst(7))
        let edited = Data(expected.utf8)
        let file = fixture.root.appending(path: "100000行.csv")
        try FileManager.default.copyItem(at: source, to: file)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root,
                                                    clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let opened = Date()
        row.doubleClick()
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        let first = table.staticTexts["000001"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let firstVisible = Date()
        first.click()
        app.typeKey("f", modifierFlags: .command)
        let find = app.textFields["bailey.csv.find"]
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        let searching = Date()
        find.typeText("100000")
        let count = app.staticTexts["bailey.csv.match-count"]
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(describing: count.value ?? "") == "1"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 15), .completed)
        XCTAssertEqual(find.value as? String, "100000")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(find.waitForNonExistence(timeout: 5))
        // The macOS AX snapshot enumerates only the first 1000 rows even
        // after NSTableView has revealed row 99999. Use the actual scroll
        // offset/row stride to address the last visible cell, not an AX query
        // that can never reach it. The saved bytes prove the exact row edited.
        let rows = table.descendants(matching: .tableRow)
        let rowStride = rows.element(boundBy: 1).frame.minY - rows.element(boundBy: 0).frame.minY
        XCTAssertGreaterThan(rowStride, 0)
        let firstFrame = first.frame
        let target = CGPoint(x: firstFrame.midX, y: firstFrame.midY + rowStride * 99_999)
        XCTAssertTrue(table.frame.contains(target), "Find must reveal the actual last row: \(target), table \(table.frame)")
        let lastVisible = Date()
        let lastCell = table.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: target.x - table.frame.minX, dy: target.y - table.frame.minY)
        )
        lastCell.doubleClick()
        app.typeText("100001")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let editVisible = Date()
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == edited
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 12), .completed)
        print("CSV_REAL_LARGE bytes=\(original.count) firstVisible=\(firstVisible.timeIntervalSince(opened)) search=\(lastVisible.timeIntervalSince(searching)) edit=\(editVisible.timeIntervalSince(lastVisible)) save=\(Date().timeIntervalSince(editVisible))")
        XCTAssertEqual(try Data(contentsOf: file), edited)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testConflictingGridDraftSurvivesTwoActualWindowsAndExplicitRetry() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let baseline = "Name,Value\r\nItem,old\n"
        let original = Data(baseline.utf8)
        let external = Data("Name,Value\r\nItem,ext\n".utf8)
        let secondBytes = Data("Name,Value\r\nItem,second\n".utf8)
        let draft = Data("Name,Value\r\nItem,draft\n".utf8)
        let file = try fixture.file("Conflict.csv", text: baseline)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let firstID = app.windows.firstMatch.identifier
        let first = app.windows.matching(identifier: firstID).firstMatch
        func grid(_ window: XCUIElement) -> XCUIElement {
            window.descendants(matching: .any).matching(identifier: "bailey.csv.table").firstMatch
        }
        func open(_ window: XCUIElement, expecting value: String) {
            let row = WorkspaceUITestSupport.fileRow(file, in: window)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
            XCTAssertTrue(grid(window).staticTexts[value].waitForExistence(timeout: 10))
        }
        func edit(_ window: XCUIElement, from: String, to: String) {
            let table = grid(window)
            table.staticTexts[from].doubleClick()
            app.typeText(to)
            app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
            XCTAssertTrue(table.staticTexts[to].waitForExistence(timeout: 10))
        }
        func conflict(_ window: XCUIElement) -> XCUIElement {
            let message = "The file changed outside Bailey"
            return window.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", message, message
            )).firstMatch
        }
        open(first, expecting: "old")
        edit(first, from: "old", to: "draft")
        XCTAssertEqual(try Data(contentsOf: file), original)
        // XCTest runs in a separate process, outside Bailey's conditional writer.
        try external.write(to: file, options: .atomic)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(conflict(first).waitForExistence(timeout: 10))
        XCTAssertTrue(grid(first).staticTexts["draft"].exists)
        XCTAssertEqual(try Data(contentsOf: file), external)
        app.typeKey("n", modifierFlags: [.command, .shift])
        let other = app.windows.matching(NSPredicate(format: "identifier != %@", firstID)).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 15))
        let second = app.windows.matching(identifier: other.identifier).firstMatch
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app, in: second)
        second.descendants(matching: .any).matching(identifier: "bailey.dock.files").firstMatch.click()
        open(second, expecting: "ext")
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: first).exists)
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: second).exists)
        edit(second, from: "ext", to: "second")
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == secondBytes
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        // Native window cycling, not a coordinate click on an occluded window.
        app.typeKey("`", modifierFlags: .command)
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.identifier == firstID
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 10), .completed)
        XCTAssertTrue(grid(first).staticTexts["draft"].waitForExistence(timeout: 10))
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(conflict(first).waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: file), secondBytes)
        XCTAssertTrue(grid(first).staticTexts["draft"].exists)
        // Explicitly restore the accepted baseline before retrying the draft.
        try original.write(to: file, options: .atomic)
        app.typeKey("s", modifierFlags: .command)
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == draft && !conflict(first).exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 10), .completed)
        XCTAssertEqual(try Data(contentsOf: file), draft)
    }

    func testNativeConflictReviewCancelAndVersionBoundOverwrite() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "Name,Value\r\nItem,old\n"
        let external = Data("Name,Value\r\nItem,ext\n".utf8)
        let newer = Data("Name,Value\r\nItem,two\n".utf8)
        let draft = Data("Name,Value\r\nItem,draft\n".utf8)
        let file = try fixture.file("Review.csv", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        XCTAssertTrue(table.staticTexts["old"].waitForExistence(timeout: 10))
        table.staticTexts["old"].doubleClick()
        app.typeText("draft")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertTrue(table.staticTexts["draft"].waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
        try external.write(to: file, options: .atomic)
        app.typeKey("s", modifierFlags: .command)
        let compare = app.buttons["bailey.saveConflict.compare"].firstMatch
        XCTAssertTrue(compare.waitForExistence(timeout: 10))
        func openReview(containing disk: String) -> XCUIElement {
            compare.click()
            let review = app.textViews["bailey.saveConflict.review"].firstMatch
            XCTAssertTrue(review.waitForExistence(timeout: 15))
            XCTAssertTrue((review.value as? String)?.contains(disk) == true)
            XCTAssertTrue((review.value as? String)?.contains("Item,draft") == true)
            return review
        }
        let initial = openReview(containing: "Item,ext")
        XCTAssertEqual(try Data(contentsOf: file), external)
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(initial.waitForNonExistence(timeout: 5))
        XCTAssertTrue(table.staticTexts["draft"].exists)
        XCTAssertEqual(try Data(contentsOf: file), external)
        _ = openReview(containing: "Item,ext")
        try newer.write(to: file, options: .atomic)
        let overwrite = app.buttons["bailey.saveConflict.overwrite"].firstMatch
        XCTAssertTrue(overwrite.isEnabled)
        overwrite.click()
        let again = app.buttons["Compare Again"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        XCTAssertFalse(overwrite.isEnabled)
        XCTAssertEqual(try Data(contentsOf: file), newer)
        again.click()
        let review = app.textViews["bailey.saveConflict.review"].firstMatch
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (review.value as? String)?.contains("Item,two") == true && overwrite.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 15), .completed)
        overwrite.click()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == draft && !overwrite.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        XCTAssertEqual(try Data(contentsOf: file), draft)
        XCTAssertTrue(table.staticTexts["draft"].exists)
        XCTAssertFalse(compare.exists)
    }

    func testMalformedTableShowsLocalizedLineAndKeepsReadableRowsAndSource() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "名称,值\r\n可读,17\r\n残缺,\"未结束"
        let file = try fixture.file("样本.csv", text: original)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "zh-Hans", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        XCTAssertTrue(table.staticTexts["可读"].waitForExistence(timeout: 10))
        let issue = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "第 3 行", "第 3 行"
        )).firstMatch
        XCTAssertTrue(issue.exists)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(table.waitForNonExistence(timeout: 10))
        XCTAssertTrue((window.textViews.firstMatch.value as? String)?.contains("残缺,\"未结束") == true)
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
    }

    func testFileOpensNativeTableAndUsesTheSameSourceAndCompanionActions() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "Item,Value\r\n青🧪,42\r\nSecond,9\r\n"
        let file = try fixture.file("测量.CSV", text: original)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()

        let table = WorkspaceUITestSupport.element("bailey.csv.table", in: app)
        XCTAssertTrue(table.staticTexts["青🧪"].waitForExistence(timeout: 15))
        XCTAssertTrue(table.staticTexts["42"].exists)
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        XCTAssertTrue(tab.exists)
        tab.rightClick()
        let sideBySide = WorkspaceUITestSupport.menuItem("Show Side by Side", in: app)
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 5))
        sideBySide.click()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(table.staticTexts["青🧪"].exists)

        table.staticTexts["青🧪"].click()
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(table.waitForNonExistence(timeout: 10))
        XCTAssertTrue((window.textViews.firstMatch.value as? String)?.contains("青🧪,42") == true)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(table.staticTexts["青🧪"].waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
    }
}
