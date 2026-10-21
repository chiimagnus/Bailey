import XCTest

final class WorkspaceSmokeUITests: XCTestCase {
    func testIsolatedLaunchAndPaletteKeyboardFocus() throws {
        let app = XCUIApplication()
        guard app.state == .notRunning else {
            throw XCTSkip("A Bailey instance is already running; UI automation must not terminate it")
        }
        app.launchArguments = ["--isolated-ui-test"]
        app.launchEnvironment["BAILEY_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["bailey.emptyState.addFolder"].waitForExistence(timeout: 15))

        app.typeKey("p", modifierFlags: .command)
        let search = app.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.typeKey("z", modifierFlags: [])
        XCTAssertEqual(search.value as? String, "z", "The palette must receive actual keyboard input")

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: search
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["bailey.emptyState.addFolder"].exists)
    }
}
