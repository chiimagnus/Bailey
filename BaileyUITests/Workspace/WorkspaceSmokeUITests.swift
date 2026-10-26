import XCTest

@MainActor
final class WorkspaceSmokeUITests: XCTestCase {
    func testReusesDevAppWithoutKeepingThePreviousProject() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let marker = try fixture.file("marker.txt", text: "test-owned bytes\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        XCTAssertTrue(app.buttons["bailey.emptyState.addFolder"].waitForExistence(timeout: 12))
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        XCTAssertTrue(WorkspaceUITestSupport.fileRow(marker, in: app.windows.firstMatch)
            .waitForExistence(timeout: 15))

        let reused = try WorkspaceUITestSupport.launch(in: self)
        XCTAssertTrue(reused === app, "Repeated launch requests must reuse the running Dev app")
        XCTAssertEqual(reused.windows.count, 1)
        XCTAssertTrue(reused.buttons["bailey.emptyState.addFolder"].waitForExistence(timeout: 12),
                      "The previous test project must be closed before reusing its window")
    }

    func testIsolatedLaunchAndPaletteKeyboardFocus() throws {
        let app = try WorkspaceUITestSupport.launch(in: self)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["bailey.emptyState.addFolder"].waitForExistence(timeout: 15))

        app.typeKey("p", modifierFlags: .command)
        let search = app.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.typeKey("z", modifierFlags: [])
        XCTAssertEqual(search.value as? String, "z", "The palette must receive actual keyboard input")

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(search.exists)
        XCTAssertEqual(search.value as? String, "",
                       "First Escape must clear the native search field")

        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: search
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["bailey.emptyState.addFolder"].exists)
    }
}
