import AppKit
import XCTest

@MainActor
final class WorkspaceFilesUITests: XCTestCase {
    func testNativeFolderPickerRestoresMultipleClipboardItemsAndTypes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let folderName = "剪贴板 空格 é 👋"
        let file = try fixture.file(folderName + "/clipboard.txt", text: "correct native picker target\n")
        let folder = fixture.root.appendingPathComponent(folderName, isDirectory: true)
        let pasteboard = NSPasteboard.general
        let original = try WorkspaceUITestSupport.clipboardItems()
        defer {
            pasteboard.clearContents()
            if !original.isEmpty { XCTAssertTrue(pasteboard.writeObjects(original)) }
        }
        let first = NSPasteboardItem()
        XCTAssertTrue(first.setString("original clipboard text", forType: .string))
        XCTAssertTrue(first.setData(Data([0, 255, 10, 127]),
            forType: NSPasteboard.PasteboardType("chiimagnus.bailey.uitest.clipboard-marker")))
        let second = NSPasteboardItem()
        XCTAssertTrue(second.setString("<b>second clipboard item</b>", forType: .html))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        func contents() throws -> [[NSPasteboard.PasteboardType: Data]] {
            try (pasteboard.pasteboardItems ?? []).map { item in
                try Dictionary(uniqueKeysWithValues: item.types.map { type in
                    (type, try XCTUnwrap(item.data(forType: type)))
                })
            }
        }
        let expected = try contents()
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(folder, to: app)
        XCTAssertEqual(try contents(), expected,
                       "Native path entry must restore every clipboard item and byte type")
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: app.windows.firstMatch)
            .waitForExistence(timeout: 15))
        XCTAssertEqual(app.windows.firstMatch.textViews.firstMatch.value as? String,
                       "correct native picker target\n")
        XCTAssertEqual(try Data(contentsOf: file), Data("correct native picker target\n".utf8))
    }

    func testAddFolderAndOpenFileThroughRealFileTree() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("a-first.swift", text: "let first = 1\n")
        let second = try fixture.file("b-second.swift", text: "let second = 2\n")
        let app = try WorkspaceUITestSupport.launch(in: self)

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        files.click()

        let firstRow = WorkspaceUITestSupport.fileRow(first, in: app.windows.firstMatch)
        let secondRow = WorkspaceUITestSupport.fileRow(second, in: app.windows.firstMatch)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20))
        XCTAssertTrue(secondRow.waitForExistence(timeout: 20))
        firstRow.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(first, in: app.windows.firstMatch)
        XCTAssertTrue(tab.waitForExistence(timeout: 15),
                      "Double-clicking a file in the real File Manager must open its editor tab")

        files.click()
        secondRow.click()
        let preview = WorkspaceUITestSupport.fileTab(second, in: app.windows.firstMatch)
        XCTAssertTrue(preview.waitForExistence(timeout: 15),
                      "Clicking another file should open a preview tab without dropping the File Manager")
    }

    func testCommandPaletteRestoresFileTreeKeyboardAfterDismissal() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("a-first.swift", text: "let first = 1\n")
        let second = try fixture.file("b-second.swift", text: "let second = 2\n")
        let app = try WorkspaceUITestSupport.launch(in: self)

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        files.click()
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: app.windows.firstMatch)
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
            WorkspaceUITestSupport.fileTab(second, in: app.windows.firstMatch)
                .waitForExistence(timeout: 15),
            "After closing the palette, Down+Space must act on the real Files selection"
        )
    }

    func testPaletteFileManagerCommandRestoresKeyboardFocusFromEditor() throws {
        try verifyFileManagerPaletteFocus(language: "en", commandName: "File Manager")
    }

    func testPaletteFileManagerCommandRestoresKeyboardFocusFromEditorInChinese() throws {
        try verifyFileManagerPaletteFocus(language: "zh-Hans", commandName: "文件管理器")
    }

    private func verifyFileManagerPaletteFocus(language: String, commandName: String) throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("alpha.swift", text: "original\n")
        let second = try fixture.file("beta.swift", text: "original\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: language)

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let betaRow = WorkspaceUITestSupport.fileRow(second, in: app.windows.firstMatch)
        XCTAssertTrue(betaRow.waitForExistence(timeout: 20))
        betaRow.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(second, in: app.windows.firstMatch)
            .waitForExistence(timeout: 15))
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()

        app.typeKey("p", modifierFlags: .command)
        let search = app.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText(commandName)
        XCTAssertEqual(search.value as? String, commandName)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertFalse(search.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "bailey.tab.file").count, 1,
                       "Switching tools through the palette must not create a file tab")

        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(first, in: app.windows.firstMatch)
            .waitForExistence(timeout: 15),
            "Palette File Manager must return keyboard focus to the selected file tree")
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(second, in: app.windows.firstMatch).exists)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "original\n")
    }

    func testNativeEditorSavesActualFileContentsToDisk() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("editable.swift", text: "let original = 1\n")
        let app = try WorkspaceUITestSupport.launch(in: self)

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: app.windows.firstMatch)
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

    func testSameNamedFilesInSeparateFoldersSaveToTheirOwnPaths() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("alpha/shared.swift", text: "let value = 1\n")
        let beta = try fixture.file("beta/shared.swift", text: "let value = 2\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let window = app.windows.firstMatch
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))

        for (folderName, path, replacement) in [
            ("alpha", alpha, "let value = 101\n"),
            ("beta", beta, "let value = 202\n"),
        ] {
            files.click()
            let folder = window.descendants(matching: .any)
                .matching(identifier: "bailey.tree.folder")
                .matching(NSPredicate(format: "label == %@", folderName)).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 15))
            folder.click()
            let row = WorkspaceUITestSupport.fileRow(path, in: window)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
            XCTAssertTrue(WorkspaceUITestSupport.fileTab(path, in: window)
                .waitForExistence(timeout: 15))
            let editor = window.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 15))
            editor.click()
            app.typeKey("a", modifierFlags: .command)
            editor.typeText(replacement)
            app.typeKey("s", modifierFlags: .command)
            let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (try? String(contentsOf: path, encoding: .utf8)) == replacement
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed,
                           "Editing one same-named tab must write only its own file")
        }

        let alphaTab = WorkspaceUITestSupport.fileTab(alpha, in: window)
        let betaTab = WorkspaceUITestSupport.fileTab(beta, in: window)
        XCTAssertTrue(alphaTab.exists && betaTab.exists)
        alphaTab.click()
        XCTAssertEqual(window.textViews.firstMatch.value as? String, "let value = 101\n")
        betaTab.click()
        XCTAssertEqual(window.textViews.firstMatch.value as? String, "let value = 202\n")
        XCTAssertEqual(try String(contentsOf: alpha, encoding: .utf8), "let value = 101\n")
        XCTAssertEqual(try String(contentsOf: beta, encoding: .utf8), "let value = 202\n")
    }

    func testSameNamedFilesInDifferentFoldersHaveDistinctRowsAndTabs() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("alpha/shared.swift", text: "let alpha = 1\n")
        let beta = try fixture.file("beta/shared.swift", text: "let beta = 2\n")
        let app = try WorkspaceUITestSupport.launch(in: self)

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        let folders = app.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
        for (folderName, path) in [("alpha", alpha), ("beta", beta)] {
            files.click()
            let folder = folders.matching(NSPredicate(format: "label == %@", folderName)).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 15))
            folder.click()
            let row = WorkspaceUITestSupport.fileRow(path, in: app.windows.firstMatch)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
            XCTAssertTrue(WorkspaceUITestSupport.fileTab(path, in: app.windows.firstMatch)
                .waitForExistence(timeout: 15))
        }
        XCTAssertEqual(app.buttons.matching(identifier: "bailey.tab.file").count, 2,
                       "Identical basenames from different directories must remain distinct")
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(alpha, in: app.windows.firstMatch).exists)
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(beta, in: app.windows.firstMatch).exists)
    }

    func testChinesePickerOpensFileWithLongUnicodePath() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let folderName = "中文目录-" + String(repeating: "深", count: 50)
        let file = try fixture.file(folderName + "/文件-测试.swift", text: "let 中文 = true\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "zh-Hans")
        let add = app.buttons["bailey.emptyState.addFolder"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        XCTAssertEqual(add.label, "添加文件夹…", "The test must actually launch the Chinese UI")

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        files.click()
        let folder = app.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label == %@", folderName)).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 20))
        folder.click()
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "Long Unicode paths must remain uniquely addressable in the AX tree")
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: app.windows.firstMatch)
            .waitForExistence(timeout: 15))
    }

    func testOpeningTheSameFileFromMenuReusesItsExistingTab() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("deduplicate.swift", text: "let one = 1\n")
        let app = try WorkspaceUITestSupport.launch(in: self)

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(file, in: app.windows.firstMatch)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))

        app.typeKey("o", modifierFlags: .command)
        try WorkspaceUITestSupport.choose(file, in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "bailey.tab.file")
            .matching(NSPredicate(format: "label CONTAINS %@", file.lastPathComponent)).count, 1,
                       "Reopening an existing file through Open File must reuse its editor tab")
    }
}
