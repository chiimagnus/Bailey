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

    func testFileTreeRenameAndDraftCancellationRestoreKeyboardNavigation() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("project/a-first.swift", text: "first original\n")
        let second = try fixture.file("project/b-second.swift", text: "second original\n")
        let projectRoot = fixture.root.appendingPathComponent("project", isDirectory: true)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let projectFolder = app.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label == %@", "project")).firstMatch
        XCTAssertTrue(projectFolder.waitForExistence(timeout: 15))
        projectFolder.click()
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20))
        firstRow.click()
        firstRow.rightClick()
        let rename = app.menuItems.matching(NSPredicate(format: "title IN %@", ["Rename", "重命名"]))
            .firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 8))
        rename.click()
        let renameField = window.textFields["Name"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 8))
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("renamed.swift")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(renameField.waitForNonExistence(timeout: 5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectRoot.appendingPathComponent("renamed.swift").path))

        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(second, in: window)
            .waitForExistence(timeout: 15),
            "Canceling rename must return keyboard navigation to the real Files tree")
        projectFolder.rightClick()
        let newFile = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["New File…", "New File...", "新建文件…"]
        )).firstMatch
        XCTAssertTrue(newFile.waitForExistence(timeout: 8))
        newFile.click()
        let draftField = window.textFields["File name"]
        XCTAssertTrue(draftField.waitForExistence(timeout: 10),
                      "The folder context menu must create the native inline file draft")
        draftField.typeText("discard-me.swift")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(draftField.waitForNonExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(first, in: window)
            .waitForExistence(timeout: 15),
            "Canceling a new-file draft must return keyboard navigation to the Files tree")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: projectRoot.path)),
                       Set(["a-first.swift", "b-second.swift"]))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first original\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second original\n")
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
