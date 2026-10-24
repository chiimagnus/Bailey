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

    func testKeyboardFocusAndPaletteRestorationStayWithTheOwningWindow() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let firstA = try fixture.file("window-a/a-first.swift", text: "first A\n")
        let secondA = try fixture.file("window-a/b-second.swift", text: "second A\n")
        let firstB = try fixture.file("window-b/a-first.swift", text: "first B\n")
        let secondB = try fixture.file("window-b/b-second.swift", text: "second B\n")
        let folderA = fixture.root.appendingPathComponent("window-a", isDirectory: true)
        let folderB = fixture.root.appendingPathComponent("window-b", isDirectory: true)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")

        try WorkspaceUITestSupport.addFolder(folderA, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        var windowA = try XCTUnwrap(window(containing: secondA, in: app))
        let rowA = WorkspaceUITestSupport.fileRow(secondA, in: windowA)
        XCTAssertTrue(rowA.waitForExistence(timeout: 20))
        rowA.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(secondA, in: windowA)
            .waitForExistence(timeout: 15))
        var editorA = windowA.textViews.firstMatch
        XCTAssertTrue(editorA.waitForExistence(timeout: 15))
        editorA.click()
        editorA.typeText("WINDOW_A_MARKER")
        XCTAssertTrue((editorA.value as? String)?.contains("WINDOW_A_MARKER") == true)
        let firstABytes = try Data(contentsOf: firstA)

        // Creating a second window makes A resign key status and autosave its buffer.
        app.typeKey("n", modifierFlags: [.command, .shift])
        waitForMarker("WINDOW_A_MARKER", in: secondA)
        let savedA = try Data(contentsOf: secondA)
        XCTAssertEqual(workspaceWindowCount(in: app), 2)
        let emptyWindow = try XCTUnwrap(app.windows.allElementsBoundByIndex.first {
            $0.buttons["bailey.emptyState.addFolder"].exists
        })
        try WorkspaceUITestSupport.addFolder(folderB, to: app, in: emptyWindow)
        emptyWindow.descendants(matching: .any)
            .matching(identifier: "bailey.dock.files").firstMatch.click()

        var windowB = try XCTUnwrap(window(containing: secondB, in: app))
        let rowB = WorkspaceUITestSupport.fileRow(secondB, in: windowB)
        XCTAssertTrue(rowB.waitForExistence(timeout: 20))
        rowB.doubleClick()
        var editorB = windowB.textViews.firstMatch
        XCTAssertTrue(editorB.waitForExistence(timeout: 15))
        editorB.click()
        editorB.typeText("WINDOW_B_MARKER")
        XCTAssertTrue((editorB.value as? String)?.contains("WINDOW_B_MARKER") == true)
        XCTAssertEqual(try Data(contentsOf: secondA), savedA,
                       "Typing in the second window must not edit the background window")
        XCTAssertEqual(try Data(contentsOf: firstA), firstABytes)

        windowA = try XCTUnwrap(window(containing: secondA, in: app))
        windowB = try XCTUnwrap(window(containing: secondB, in: app))
        editorB = windowB.textViews.firstMatch
        editorB.click()
        windowB = try XCTUnwrap(window(containing: secondB, in: app))
        editorB = windowB.textViews.firstMatch
        app.typeKey("p", modifierFlags: .command)
        let searchB = windowB.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(searchB.waitForExistence(timeout: 10))
        searchB.typeText("File Manager")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertFalse(windowB.textFields["bailey.commandPalette.search"].waitForExistence(timeout: 5),
                       "Selecting File Manager must close the palette in this window")
        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        windowB = try XCTUnwrap(window(containing: secondB, in: app))
        windowA = try XCTUnwrap(window(containing: secondA, in: app))
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(firstB, in: windowB)
            .waitForExistence(timeout: 15),
            "The second window's restored Files focus must open its own first file")
        waitForMarker("WINDOW_B_MARKER", in: secondB)
        let savedB = try Data(contentsOf: secondB)
        XCTAssertFalse(WorkspaceUITestSupport.fileTab(firstA, in: windowA).exists,
                       "Keyboard navigation in the second window must not open a file in the first")
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(secondA, in: windowA).exists)
        XCTAssertEqual(try Data(contentsOf: secondA), savedA)

        windowA = try XCTUnwrap(window(containing: secondA, in: app))
        windowB = try XCTUnwrap(window(containing: secondB, in: app))
        // Window B covers A: select the actual first window before clicking its editor.
        app.typeKey("`", modifierFlags: .command)
        editorA = windowA.textViews.firstMatch
        XCTAssertTrue((editorA.value as? String)?.contains("WINDOW_A_MARKER") == true)
        editorA.click()
        windowA = try XCTUnwrap(window(containing: secondA, in: app))
        editorA = windowA.textViews.firstMatch
        app.typeKey("p", modifierFlags: .command)
        let searchA = windowA.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(searchA.waitForExistence(timeout: 10))
        searchA.typeText("File Manager")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertFalse(windowA.textFields["bailey.commandPalette.search"].waitForExistence(timeout: 5),
                       "Selecting File Manager must close the palette in this window")
        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        windowA = try XCTUnwrap(window(containing: secondA, in: app))
        windowB = try XCTUnwrap(window(containing: secondB, in: app))
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(firstA, in: windowA)
            .waitForExistence(timeout: 15),
            "The first window must regain its own Files keyboard focus")
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(firstB, in: windowB).exists)
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(secondB, in: windowB).exists)
        XCTAssertEqual(try Data(contentsOf: secondB), savedB,
                       "Keyboard navigation in the first window must not change the second")
        XCTAssertEqual(try Data(contentsOf: firstB), Data("first B\n".utf8))
        XCTAssertEqual(workspaceWindowCount(in: app), 2)
    }

    private func workspaceWindowCount(in app: XCUIApplication) -> Int {
        app.windows.allElementsBoundByIndex.filter {
            $0.descendants(matching: .any)
                .matching(identifier: "bailey.dock.files").firstMatch.exists
        }.count
    }

    private func window(containing file: URL, in app: XCUIApplication) -> XCUIElement? {
        app.windows.allElementsBoundByIndex.first {
            WorkspaceUITestSupport.fileTab(file, in: $0).exists
                || WorkspaceUITestSupport.fileRow(file, in: $0).exists
        }
    }

    private func waitForMarker(_ marker: String, in file: URL) {
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (try? String(contentsOf: file, encoding: .utf8))?.contains(marker) == true
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed,
                       "The active window must save the marker to its own file")
    }
}
