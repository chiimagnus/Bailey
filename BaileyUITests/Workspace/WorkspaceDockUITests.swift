import AppKit
import XCTest

@MainActor
final class WorkspaceDockUITests: XCTestCase {
    func testCrossGroupDragReleaseCannotSelectDestinationButRealClickCan() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("unchanged.swift", text: "original bytes\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let window = app.windows.firstMatch
        let projects = WorkspaceUITestSupport.element("bailey.dock.projects", in: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        projects.click()

        let origin = window.coordinate(withNormalizedOffset: .zero)
        let source = origin.withOffset(CGVector(
            dx: window.frame.width * 0.06, dy: window.frame.height * 0.72))
        let destination = origin.withOffset(CGVector(
            dx: window.frame.width * 0.92, dy: window.frame.height * 0.72))
        source.click(forDuration: 0.12, thenDragTo: destination)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(projects.waitForNonExistence(timeout: 12),
                      "The first Cmd-W after a cross-group drag must close its original Projects panel")
        XCTAssertTrue(files.exists, "Drag release must not activate or close the Files target")

        files.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(files.waitForNonExistence(timeout: 12),
                      "A genuine Files click must route Cmd-W to the destination group")
        XCTAssertTrue(window.exists, "Closing two tool panes must not destroy the project window")
        XCTAssertEqual(try Data(contentsOf: file), Data("original bytes\n".utf8))
    }

    func testClosingExplicitlyActivatedProjectsKeepsFilesWithoutDragging() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("unchanged.swift", text: "original bytes\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let projects = WorkspaceUITestSupport.element("bailey.dock.projects", in: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        XCTAssertTrue(projects.isHittable,
                      "The default narrow Projects group must expose a clickable header tab")
        projects.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.exists,
                      "Closing an active tool must not close the main app window")
        XCTAssertTrue(projects.waitForNonExistence(timeout: 12))
        XCTAssertTrue(files.exists, "Closing Projects alone must preserve the Files panel")
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    func testDockFocusHandoffNeverSendsKeysToHiddenEditor() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("project/a-first.swift", text: "first file\n")
        let file = try fixture.file("project/b-focused.swift", text: "do not change this file\n")
        let projectRoot = fixture.root.appendingPathComponent("project", isDirectory: true)
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(projectRoot, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, "do not change this file\n")
        editor.click()

        let blankFilesArea = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: window.frame.width * 0.92, dy: window.frame.height * 0.80))
        blankFilesArea.click()
        app.typeKey("z", modifierFlags: [])
        XCTAssertEqual(editor.value as? String, "do not change this file\n",
                       "After clicking an empty tool pane, typing must not reach the old editor")

        WorkspaceUITestSupport.element("bailey.dock.git", in: app).click()
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(first, in: window)
            .waitForExistence(timeout: 15),
            "Returning from Git to Files must restore the visible tree's keyboard navigation")
        XCTAssertEqual(try Data(contentsOf: file), Data("do not change this file\n".utf8))
        XCTAssertEqual(try Data(contentsOf: first), Data("first file\n".utf8))
    }
}
