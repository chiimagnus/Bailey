import Foundation
import XCTest

@MainActor
final class CSVPreviewUITests: XCTestCase {
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
