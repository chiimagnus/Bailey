import AppKit
import XCTest

@MainActor
final class WorkspaceSmokeUITests: XCTestCase {
    func testDevelopmentAppNameMatchesFinderDockAndMenuBar() throws {
        let app = try WorkspaceUITestSupport.launch(in: self)
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev"
        ).first)
        XCTAssertEqual(running.bundleURL?.lastPathComponent, "Bailey Dev.app")
        XCTAssertEqual(running.localizedName, "Bailey Dev")
        XCTAssertTrue(app.menuBars.menuBarItems["Bailey Dev"].waitForExistence(timeout: 12))
    }

    func testProjectsAddPopoverUsesAlignedActionsAndOpensPicker() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let add = WorkspaceUITestSupport.element("bailey.projects.addPicker", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.click()
        let local = app.buttons["Add Projects…"]
        let remote = app.buttons["Add SSH Files or Projects…"]
        XCTAssertTrue(local.waitForExistence(timeout: 10))
        XCTAssertTrue(remote.waitForExistence(timeout: 10))
        XCTAssertEqual(local.frame.minX, remote.frame.minX, accuracy: 2,
                       "Popover actions must share the same left edge")
        XCTAssertEqual(local.frame.maxX, remote.frame.maxX, accuracy: 2,
                       "Popover actions must share the same right edge")
        XCTAssertLessThan(local.frame.width, 500, "Popover should size to its contents")
        local.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))
        add.click()
        let ssh = app.buttons["Add SSH Files or Projects…"]
        XCTAssertTrue(ssh.waitForExistence(timeout: 10))
        ssh.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertEqual(app.windows.count, 1)
    }

    func testRepeatedLaunchDoesNotResetTheCurrentTestProject() throws {
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
        XCTAssertTrue(WorkspaceUITestSupport.fileRow(marker, in: reused.windows.firstMatch).exists,
                      "Repeated access in one test must not reset the project")
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
