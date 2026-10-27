import AppKit
import XCTest

@MainActor
final class WorkspaceDockUITests: XCTestCase {
    func testDockFileTabSwitchRevealsOneSelectedExplorerRow() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("one.swift", text: "let one = 1\n")
        let second = try fixture.file("two.swift", text: "let two = 2\n")
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window)
        let secondRow = WorkspaceUITestSupport.fileRow(second, in: window)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))
        XCTAssertTrue(secondRow.waitForExistence(timeout: 15))

        firstRow.click()
        secondRow.click()
        let firstTab = WorkspaceUITestSupport.fileTab(first, in: window)
        let secondTab = WorkspaceUITestSupport.fileTab(second, in: window)
        XCTAssertTrue(firstTab.waitForExistence(timeout: 10))
        XCTAssertTrue(secondTab.waitForExistence(timeout: 10))

        for (tab, selected, other) in [
            (firstTab, firstRow, secondRow),
            (secondTab, secondRow, firstRow),
            (firstTab, firstRow, secondRow)
        ] {
            tab.click()
            let expected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "selected == true"), object: selected
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed)
            XCTAssertFalse(other.isSelected, "The previous Explorer row must not remain selected")
        }
        XCTAssertEqual(try Data(contentsOf: first), Data("let one = 1\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("let two = 2\n".utf8))
    }

    func testCrossGroupDragReleaseCannotSelectDestinationButRealClickCan() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("unchanged.swift", text: "original bytes\n")
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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

    func testOpenToolContextMenuCommandWClosesOnlyRightClickedPanel() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("do-not-close-git.txt", text: "keep original\n")
        let app = launchIsolatedDockProject(fixture)

        let window = app.windows.firstMatch
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        XCTAssertTrue(git.waitForExistence(timeout: 15))
        git.click()
        if !files.isHittable {
            let strip = window.scrollViews.containing(
                .button, identifier: "bailey.dock.git"
            ).firstMatch
            XCTAssertTrue(strip.waitForExistence(timeout: 5))
            strip.swipeRight()
        }
        XCTAssertTrue(files.isHittable, "The Files tab must be reachable by horizontal scrolling")
        files.rightClick()
        XCTAssertTrue(app.menus.allElementsBoundByIndex.contains {
            $0.menuItems["Close Panel"].exists
        }, "The native right-click menu must still be open")
        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(files.waitForNonExistence(timeout: 12),
                      "Cmd-W in the context menu must close Files only")
        XCTAssertTrue(git.exists && window.exists,
                      "The active Git group must remain after closing the inactive Files panel")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(git.waitForNonExistence(timeout: 12),
                      "After the menu closes, Cmd-W must return to the active Dock group")
        XCTAssertTrue(window.exists)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep original\n")
    }

    func testOpenFileTabContextMenuCommandWClosesOnlyRightClickedTab() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("left.txt", text: "first\n")
        let second = try fixture.file("right.txt", text: "second\n")
        let app = launchIsolatedDockProject(fixture)
        let bundle = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev").compactMap(\.bundleURL).first)
        XCTAssertTrue(bundle.path.contains("DerivedData-Dev/Build/Products/Debug/"))
        let opened = expectation(description: "Open two fixture files")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([first, second], withApplicationAt: bundle,
                                configuration: configuration) { _, error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 15), .completed)

        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileTab(first, in: window)
        let b = WorkspaceUITestSupport.fileTab(second, in: window)
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        b.click()
        a.rightClick()
        XCTAssertTrue(app.menus.allElementsBoundByIndex.contains {
            $0.menuItems["Close"].exists && $0.menuItems["Close Others"].exists
        }, "The native tab menu must be open before Cmd-W")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(a.waitForNonExistence(timeout: 12))
        XCTAssertTrue(b.exists && window.exists,
                      "Only the right-clicked inactive file tab may close")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second\n")
    }

    func testRightClickFileTabAndCommandWCloseTheSameFile() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("first.txt", text: "file A\n")
        let second = try fixture.file("second.txt", text: "file B\n")
        let third = try fixture.file("third.txt", text: "file C\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let bundle = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev").compactMap(\.bundleURL).first)
        XCTAssertTrue(bundle.path.contains("DerivedData-Dev/Build/Products/Debug/"))

        func open(_ urls: [URL]) throws {
            let delivered = expectation(description: "File-open event delivered to Bailey Dev")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: bundle, configuration: config) {
                _, error in
                XCTAssertNil(error)
                delivered.fulfill()
            }
            XCTAssertEqual(XCTWaiter.wait(for: [delivered], timeout: 15), .completed)
        }

        try open([first, second, third])
        let a = WorkspaceUITestSupport.fileTab(first, in: window)
        let b = WorkspaceUITestSupport.fileTab(second, in: window)
        let c = WorkspaceUITestSupport.fileTab(third, in: window)
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        XCTAssertTrue(c.waitForExistence(timeout: 15))
        c.click()
        b.rightClick()
        XCTAssertTrue(app.menus.allElementsBoundByIndex.contains {
            $0.menuItems["Close Others"].exists && $0.menuItems["Close"].exists
        }, "Right-click must open the file tab menu")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        guard b.waitForNonExistence(timeout: 7) else {
            XCTFail("Cmd-W must close right-clicked B, not the active C")
            return
        }
        XCTAssertTrue(a.exists && c.exists && window.exists)

        try open([second])
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        c.click()
        b.rightClick()
        let menu = try XCTUnwrap(app.menus.allElementsBoundByIndex.first {
            $0.menuItems["Close Others"].exists && $0.menuItems["Close"].exists
        })
        menu.menuItems["Close"].click()
        XCTAssertTrue(b.waitForNonExistence(timeout: 12))
        XCTAssertTrue(a.exists && c.exists)

        c.rightClick()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        a.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(a.waitForNonExistence(timeout: 12),
                      "A later primary click must replace the right-click target")
        XCTAssertTrue(c.exists && window.exists)
        XCTAssertEqual(try Data(contentsOf: first), Data("file A\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("file B\n".utf8))
        XCTAssertEqual(try Data(contentsOf: third), Data("file C\n".utf8))
    }

    func testCommandPaletteClosePanelUsesTheActiveTool() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("persist.txt", text: "not edited\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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
        XCTAssertTrue(app.menuItems["Close"].waitForExistence(timeout: 8))
        XCTAssertNotEqual(try contextOutlinePixels(of: firstTab), before,
                          "The inactive tab must show a context outline while its menu is open")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        firstTab.hover()
        XCTAssertEqual(try contextOutlinePixels(of: firstTab), before,
                       "Dismissal must remove the temporary context outline")
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
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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
        XCTAssertNotEqual(try contextOutlinePixels(of: row), before,
                          "The project context outline must be visible only during menu tracking")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        row.hover()
        XCTAssertEqual(try contextOutlinePixels(of: row), before,
                       "Dismissal must remove the project context outline")
    }

    private func launchIsolatedDockProject(_ fixture: WorkspaceUITestFixture) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "chiimagnus.bailey.dev")
        app.launchArguments = ["--isolated-ui-test", "-AppleLanguages", "(en)"]
        app.launchEnvironment["BAILEY_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["BAILEY_UI_TEST_PROJECT"] = fixture.root.path
        app.launchEnvironment["HOME"] = fixture.root.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = fixture.root.path
        app.launch()
        addTeardownBlock { @MainActor in
            if app.state != .notRunning { app.terminate() }
        }
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 1) {
            app.typeKey("n", modifierFlags: [.command, .shift])
        }
        return app
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
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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
        let app = try WorkspaceUITestSupport.launch(in: self, project: projectRoot)
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
