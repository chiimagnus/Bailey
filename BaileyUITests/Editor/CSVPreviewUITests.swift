import AppKit
import Foundation
import XCTest

@MainActor
final class CSVPreviewUITests: XCTestCase {
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
