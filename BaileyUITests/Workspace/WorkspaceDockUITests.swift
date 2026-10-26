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

    func testClosePanelSeparatesContextTargetFromCommandShortcut() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("keep.txt", text: "preserve me\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let window = app.windows.firstMatch
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        XCTAssertTrue(git.waitForExistence(timeout: 15))

        files.click()
        git.rightClick()
        let menu = app.menus["bailey.dock.git"].menuItems["Close Panel"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.click()
        XCTAssertTrue(git.waitForNonExistence(timeout: 12),
                      "Context Close Panel must remove only the right-clicked Git panel")
        XCTAssertTrue(files.exists, "Closing an inactive panel must preserve active Files")

        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(git.waitForExistence(timeout: 12))
        files.click()
        git.rightClick()
        XCTAssertTrue(app.menus["bailey.dock.git"].menuItems["Close Panel"]
            .waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(files.waitForNonExistence(timeout: 12),
                      "Cmd-W must close the active Files panel, not the prior right-click target")
        XCTAssertTrue(git.exists)
        XCTAssertTrue(window.exists)
        XCTAssertEqual(try Data(contentsOf: file), Data("preserve me\n".utf8))
    }

    func testCommandPaletteClosePanelUsesTheActiveTool() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("persist.txt", text: "not edited\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        XCTAssertTrue(git.waitForExistence(timeout: 15))
        files.click()
        app.typeKey("p", modifierFlags: .command)
        let search = app.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("Close Panel")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(files.waitForNonExistence(timeout: 12))
        XCTAssertTrue(git.exists)
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertEqual(try Data(contentsOf: file), Data("not edited\n".utf8))
    }

    func testRightClickInactiveFileTabClosesOnlyThatTab() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("first-tab.txt", text: "first\n")
        let second = try fixture.file("second-tab.txt", text: "second\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window)
        let secondRow = WorkspaceUITestSupport.fileRow(second, in: window)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))
        firstRow.doubleClick()
        XCTAssertTrue(secondRow.waitForExistence(timeout: 15))
        secondRow.doubleClick()
        let firstTab = WorkspaceUITestSupport.fileTab(first, in: window)
        let secondTab = WorkspaceUITestSupport.fileTab(second, in: window)
        XCTAssertTrue(firstTab.waitForExistence(timeout: 12))
        XCTAssertTrue(secondTab.waitForExistence(timeout: 12))

        firstTab.hover()
        let before = try contextOutlinePixels(of: firstTab)
        firstTab.rightClick()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertNotEqual(try contextOutlinePixels(of: firstTab), before,
                          "The inactive tab must show an independent context target outline")
        firstTab.rightClick()
        let contextMenu = try XCTUnwrap(app.menus.allElementsBoundByIndex.first {
            $0.menuItems["Close Others"].exists && $0.menuItems["Close"].exists
        }, "Only the tab context menu can close this inactive tab")
        contextMenu.menuItems["Close"].click()
        XCTAssertTrue(firstTab.waitForNonExistence(timeout: 12))
        XCTAssertTrue(secondTab.exists, "Right-clicking an inactive tab must not replace the active one")
        XCTAssertEqual(try Data(contentsOf: first), Data("first\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second\n".utf8))
    }

    func testProjectContextMenuExposesOnlyCloseAndUsesFolderName() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("folder-first.txt", text: "project contents\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let projects = WorkspaceUITestSupport.element("bailey.dock.projects", in: app)
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        projects.click()

        let row = app.descendants(matching: .any)
            .matching(identifier: "bailey.project.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.label.contains(fixture.root.lastPathComponent),
                      "The project name must be derived from its directory")
        row.hover()
        let before = try contextOutlinePixels(of: row)
        row.rightClick()
        XCTAssertTrue(app.menuItems["Close Project"].waitForExistence(timeout: 10))
        for removed in ["Rename…", "Use Automatic Title", "Set Project Directory…",
                        "Use Automatic Directory"] {
            XCTAssertFalse(app.menuItems[removed].exists,
                           "Project menu must not expose removed action \(removed)")
        }
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertNotEqual(try contextOutlinePixels(of: row), before,
                          "Right-clicked project must draw its own context outline")
    }

    private func contextOutlinePixels(of element: XCUIElement) throws -> Data {
        let tiff = try XCTUnwrap(element.screenshot().image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let height = bitmap.pixelsHigh
        let width = bitmap.pixelsWide
        var rgb: [UInt8] = []
        for y in (height / 3)..<(2 * height / 3) {
            for x in [1, 2, 3, max(0, width - 4), max(0, width - 3), max(0, width - 2)] {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                rgb += [color.redComponent, color.greenComponent, color.blueComponent].map {
                    UInt8(max(0, min(255, Int($0 * 255))))
                }
            }
        }
        return Data(rgb)
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
