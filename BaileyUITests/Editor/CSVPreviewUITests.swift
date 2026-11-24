import AppKit
import Foundation
import XCTest

@MainActor
final class CSVPreviewUITests: XCTestCase {
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
        name.click()
        let sorted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            two.exists && ten.exists && two.frame.minY < ten.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sorted], timeout: 8), .completed)

        blue.doubleClick()
        app.typeText("a,b")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let changed = table.staticTexts["a,b"]
        XCTAssertTrue(changed.waitForExistence(timeout: 10))
        changed.click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(blue.waitForExistence(timeout: 10))
        blue.click()
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
        green.click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(blue.waitForExistence(timeout: 10))
        blue.click()
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(changed.waitForExistence(timeout: 10))
        changed.click()
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
