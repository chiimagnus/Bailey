import XCTest

@MainActor
final class WorkspaceFilesUITests: XCTestCase {
    func testAddFolderAndOpenFileThroughRealFileTree() throws {
        let fixture = try WorkspaceUITestFixture()
        let first = try fixture.file("a-first.swift", text: "let first = 1\n")
        let second = try fixture.file("b-second.swift", text: "let second = 2\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        defer {
            app.terminate()
            fixture.remove()
        }

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        files.click()

        let firstRow = WorkspaceUITestSupport.fileRow(first, in: app)
        let secondRow = WorkspaceUITestSupport.fileRow(second, in: app)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20))
        XCTAssertTrue(secondRow.waitForExistence(timeout: 20))
        firstRow.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(first, in: app)
        XCTAssertTrue(tab.waitForExistence(timeout: 15),
                      "Double-clicking a file in the real File Manager must open its editor tab")

        files.click()
        secondRow.click()
        let preview = WorkspaceUITestSupport.fileTab(second, in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15),
                      "Clicking another file should open a preview tab without dropping the File Manager")
    }

    func testCommandPaletteRestoresFileTreeKeyboardAfterDismissal() throws {
        let fixture = try WorkspaceUITestFixture()
        let first = try fixture.file("a-first.swift", text: "let first = 1\n")
        let second = try fixture.file("b-second.swift", text: "let second = 2\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        defer {
            app.terminate()
            fixture.remove()
        }

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        files.click()
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: app)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20))
        firstRow.click()

        app.typeKey("p", modifierFlags: .command)
        let search = app.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(search.waitForExistence(timeout: 5),
                       "Escape without a query must dismiss the command palette")

        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(
            WorkspaceUITestSupport.fileTab(second, in: app)
                .waitForExistence(timeout: 15),
            "After closing the palette, Down+Space must act on the real Files selection"
        )
    }

    func testNativeEditorSavesActualFileContentsToDisk() throws {
        let fixture = try WorkspaceUITestFixture()
        let file = try fixture.file("editable.swift", text: "let original = 1\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        defer {
            app.terminate()
            fixture.remove()
        }

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let row = WorkspaceUITestSupport.fileRow(file, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: app)
            .waitForExistence(timeout: 15))
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        editor.typeText("bailey_native_editor_saved_marker")
        app.typeKey("s", modifierFlags: .command)

        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (try? String(contentsOf: file, encoding: .utf8))?
                    .contains("bailey_native_editor_saved_marker") == true
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed,
                       "Command-S must persist real editor bytes, not only publish a model change")
    }

    func testOpeningTheSameFileFromMenuReusesItsExistingTab() throws {
        let fixture = try WorkspaceUITestFixture()
        let file = try fixture.file("deduplicate.swift", text: "let one = 1\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        defer {
            app.terminate()
            fixture.remove()
        }

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let row = WorkspaceUITestSupport.fileRow(file, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(file, in: app)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))

        app.typeKey("o", modifierFlags: .command)
        try WorkspaceUITestSupport.choose(file, button: "Open", in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "bailey.tab.file")
            .matching(NSPredicate(format: "label CONTAINS %@", file.lastPathComponent)).count, 1,
                       "Reopening an existing file through Open File must reuse its editor tab")
    }
}
