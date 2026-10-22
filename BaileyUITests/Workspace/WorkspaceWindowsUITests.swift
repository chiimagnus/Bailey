import XCTest

@MainActor
final class WorkspaceWindowsUITests: XCTestCase {
    func testTwoEmptyWindowsHaveIndependentNativeLifecycle() throws {
        let app = try WorkspaceUITestSupport.launch(in: self)

        XCTAssertTrue(app.buttons["bailey.emptyState.addFolder"].exists)
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 15),
                      "Command-Shift-N must open a second real application window")
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertTrue(app.buttons.matching(identifier: "bailey.emptyState.addFolder").count >= 2)

        app.typeKey("w", modifierFlags: .command)
        let oneWindow = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 1"), object: app.windows
        )
        XCTAssertEqual(XCTWaiter.wait(for: [oneWindow], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["bailey.emptyState.addFolder"].exists)
    }

    func testSettingsOpensFromTheRealApplicationShortcut() throws {
        let app = try WorkspaceUITestSupport.launch(in: self)

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 15),
                      "Command-comma must open the real Settings window")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["bailey.emptyState.addFolder"].exists)
    }

    func testCancelingFolderPickerDoesNotCreateAnEmptyProject() throws {
        let app = try WorkspaceUITestSupport.launch(in: self)

        app.buttons["bailey.emptyState.addFolder"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["bailey.emptyState.addFolder"].waitForExistence(timeout: 10),
                      "Cancel must leave the original empty workspace unchanged")
    }
}
