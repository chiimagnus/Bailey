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

    func testFileManagerClipboardCopyCutPasteAndTrashAgainstRealDisk() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("alpha.txt", text: "alpha original\n")
        let beta = try fixture.file("beta.txt", text: "beta original\n")
        let placeholder = try fixture.file("target/.keep", text: "")
        let target = placeholder.deletingLastPathComponent()
        let copiedAlpha = target.appendingPathComponent(alpha.lastPathComponent)
        let movedBeta = target.appendingPathComponent(beta.lastPathComponent)
        let originalClipboard = try WorkspaceUITestSupport.clipboardItems()
        defer {
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            if !originalClipboard.isEmpty { XCTAssertTrue(clipboard.writeObjects(originalClipboard)) }
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let alphaRow = WorkspaceUITestSupport.fileRow(alpha, in: window)
        let betaRow = WorkspaceUITestSupport.fileRow(beta, in: window)
        let targetRow = app.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label == %@", "target")).firstMatch
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 20))
        XCTAssertTrue(betaRow.waitForExistence(timeout: 20))
        XCTAssertTrue(targetRow.waitForExistence(timeout: 20))

        alphaRow.click()
        let copyMenu = try fileContextMenu(for: alphaRow, in: app)
        let copy = copyMenu.menuItems["Copy"]
        XCTAssertTrue(copy.exists)
        copy.click()
        let privateTransfer = NSPasteboard.PasteboardType("com.chiimagnus.bailey.files.transfer")
        XCTAssertNotNil(NSPasteboard.general.data(forType: privateTransfer),
                        "The Copy menu must publish a Bailey Files clipboard record")
        targetRow.click()
        XCTAssertNotNil(NSPasteboard.general.data(forType: privateTransfer),
                        "Selecting a destination must not erase clipboard data")
        app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(app.sheets.count, 0, "Copy+Paste should not show an error sheet")
        let copied = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: copiedAlpha.path) },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 20), .completed,
                       "Copy+Paste from Files should create bytes in the chosen folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alpha.path), "Copy cannot remove source")
        XCTAssertEqual(try Data(contentsOf: copiedAlpha), Data("alpha original\n".utf8))

        betaRow.click()
        app.typeKey("x", modifierFlags: .command)
        XCTAssertNotNil(NSPasteboard.general.data(forType: privateTransfer),
                        "Command+X must write a Files clipboard record")
        XCTAssertTrue(FileManager.default.fileExists(atPath: beta.path), "Cut must be deferred")
        targetRow.click()
        app.typeKey("v", modifierFlags: .command)
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: movedBeta.path) },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 20), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: beta.path),
                       "Cut+Paste must move rather than create another copy")
        XCTAssertEqual(try Data(contentsOf: movedBeta), Data("beta original\n".utf8))

        let trashMenu = try fileContextMenu(for: alphaRow, in: app)
        let trash = trashMenu.menuItems["Move to Trash"]
        XCTAssertTrue(trash.exists)
        trash.click()
        let deleted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !FileManager.default.fileExists(atPath: alpha.path) },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 20), .completed)
        XCTAssertEqual(try Data(contentsOf: copiedAlpha), Data("alpha original\n".utf8))
    }

    func testFocusedFilesKeyboardCopyPasteAndEditorCopyIsolation() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = try fixture.file("alpha.txt", text: "editor copy must stay text\n")
        let duplicate = fixture.root.appendingPathComponent("alpha copy.txt")
        let originalClipboard = try WorkspaceUITestSupport.clipboardItems()
        defer {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !originalClipboard.isEmpty { XCTAssertTrue(pasteboard.writeObjects(originalClipboard)) }
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let sourceRow = WorkspaceUITestSupport.fileRow(source, in: window)
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 15))
        sourceRow.click()
        app.typeKey("c", modifierFlags: .command)
        let privateTransfer = NSPasteboard.PasteboardType("com.chiimagnus.bailey.files.transfer")
        XCTAssertNotNil(NSPasteboard.general.data(forType: privateTransfer),
                        "Command+C with actual Files focus must copy files, not editor text")

        app.typeKey("v", modifierFlags: .command)
        let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: duplicate.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 15), .completed)
        XCTAssertEqual(try Data(contentsOf: source), Data("editor copy must stay text\n".utf8))
        XCTAssertEqual(try Data(contentsOf: duplicate), Data("editor copy must stay text\n".utf8))
        app.typeKey("v", modifierFlags: .command)
        let secondCopy = fixture.root.appendingPathComponent("alpha copy 2.txt")
        let repeated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: secondCopy.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [repeated], timeout: 15), .completed)
        XCTAssertEqual(try Data(contentsOf: secondCopy), Data("editor copy must stay text\n".utf8))

        sourceRow.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(source, in: window)
            .waitForExistence(timeout: 15))
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "editor copy must stay text\n",
                       "Editor Command+C must copy selected text")
        XCTAssertNil(NSPasteboard.general.data(forType: privateTransfer),
                     "Editor Command+C must replace the Files clipboard record")
    }

    func testMultiSelectContextTargetsAndBulkTrashAgainstRealDisk() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("a.txt", text: "a bytes\n")
        let beta = try fixture.file("b.txt", text: "b bytes\n")
        let gamma = try fixture.file("c.txt", text: "c bytes\n")
        let originalClipboard = try WorkspaceUITestSupport.clipboardItems()
        defer {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !originalClipboard.isEmpty { XCTAssertTrue(pasteboard.writeObjects(originalClipboard)) }
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileRow(alpha, in: window)
        let b = WorkspaceUITestSupport.fileRow(beta, in: window)
        let c = WorkspaceUITestSupport.fileRow(gamma, in: window)
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        XCTAssertTrue(c.waitForExistence(timeout: 15))
        a.click()
        XCUIElement.perform(withKeyModifiers: .shift) { b.click() }
        XCTAssertTrue(a.isSelected && b.isSelected && !c.isSelected)

        let otherMenu = try fileContextMenu(for: c, in: app)
        otherMenu.menuItems["Copy Path"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), gamma.path,
                       "Context-clicking an unselected row must act on that row only")

        let selectedMenu = try fileContextMenu(for: a, in: app)
        selectedMenu.menuItems["Copy Relative Path"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "a.txt\nb.txt",
                       "Context-clicking a selected row must copy the selected relative paths")
        let deleteMenu = try fileContextMenu(for: a, in: app)
        deleteMenu.menuItems["Move to Trash"].click()
        let deleted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: alpha.path)
                && !FileManager.default.fileExists(atPath: beta.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 15), .completed,
                       "Bulk Trash must remove both selected originals")
        XCTAssertEqual(try Data(contentsOf: gamma), Data("c bytes\n".utf8))
    }

    func testMultiSelectKeyboardCopyCutPasteWithoutMoveDialog() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("a.txt", text: "a original\n")
        let beta = try fixture.file("b.txt", text: "b original\n")
        let target = try fixture.file("target/.keep", text: "")
        let moved = try fixture.file("moved/.keep", text: "")
        let copyFolder = target.deletingLastPathComponent()
        let moveFolder = moved.deletingLastPathComponent()
        let originalClipboard = try WorkspaceUITestSupport.clipboardItems()
        defer {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !originalClipboard.isEmpty { XCTAssertTrue(pasteboard.writeObjects(originalClipboard)) }
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileRow(alpha, in: window)
        let b = WorkspaceUITestSupport.fileRow(beta, in: window)
        let targetRow = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label == %@", "target")).firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        XCTAssertTrue(targetRow.waitForExistence(timeout: 15))
        a.click()
        XCUIElement.perform(withKeyModifiers: .shift) { b.click() }
        XCTAssertTrue(a.isSelected && b.isSelected)
        app.typeKey("c", modifierFlags: .command)
        XCTAssertNotNil(NSPasteboard.general.data(forType:
            NSPasteboard.PasteboardType("com.chiimagnus.bailey.files.transfer")))
        targetRow.click()
        app.typeKey("v", modifierFlags: .command)
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: copyFolder.appendingPathComponent("a.txt").path)
                && FileManager.default.fileExists(atPath: copyFolder.appendingPathComponent("b.txt").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 20), .completed)
        XCTAssertEqual(try Data(contentsOf: copyFolder.appendingPathComponent("a.txt")),
                       Data("a original\n".utf8))
        XCTAssertEqual(try Data(contentsOf: copyFolder.appendingPathComponent("b.txt")),
                       Data("b original\n".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alpha.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: beta.path))

        a.click()
        XCUIElement.perform(withKeyModifiers: .shift) { b.click() }
        app.typeKey("x", modifierFlags: .command)
        XCTAssertTrue(FileManager.default.fileExists(atPath: alpha.path),
                      "Cut must not delete the source before a successful paste")
        let moveRow = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label == %@", "moved")).firstMatch
        XCTAssertTrue(moveRow.waitForExistence(timeout: 15))
        moveRow.click()
        app.typeKey("v", modifierFlags: .command)
        let movedFiles = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: alpha.path)
                && !FileManager.default.fileExists(atPath: beta.path)
                && FileManager.default.fileExists(atPath: moveFolder.appendingPathComponent("a.txt").path)
                && FileManager.default.fileExists(atPath: moveFolder.appendingPathComponent("b.txt").path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [movedFiles], timeout: 20), .completed)
        XCTAssertEqual(try Data(contentsOf: moveFolder.appendingPathComponent("a.txt")),
                       Data("a original\n".utf8))
        XCTAssertEqual(try Data(contentsOf: moveFolder.appendingPathComponent("b.txt")),
                       Data("b original\n".utf8))
    }

    func testAuthorizedSSHRemoteBulkDeleteRequiresNativeConfirmation() throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"],
              !host.isEmpty, !host.hasPrefix("-"),
              !host.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST to an explicitly authorized SSH test host")
        }
        let remoteRoot = "/tmp/bailey-p1-ui-" + UUID().uuidString.lowercased()
        let firstPath = remoteRoot + "/alpha.txt"
        let secondPath = remoteRoot + "/beta.txt"
        addTeardownBlock { @MainActor in
            _ = try? self.runSSH(host: host, command: "rm -rf -- '\(remoteRoot)'")
        }
        _ = try runSSH(host: host, command:
            "mkdir -p -- '\(remoteRoot)' && "
            + "printf 'alpha remote\\n' > '\(firstPath)' && "
            + "printf 'beta remote\\n' > '\(secondPath)'")
        XCTAssertEqual(try runSSH(host: host, command: "cat '\(firstPath)'"), "alpha remote\n")

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        app.menuBarItems["File"].click()
        let addSSH = app.menuItems["Add SSH Files or Folders…"]
        XCTAssertTrue(addSSH.waitForExistence(timeout: 10))
        addSSH.click()
        let window = app.windows.firstMatch
        let addSheet = window.sheets.firstMatch
        XCTAssertTrue(addSheet.waitForExistence(timeout: 10))
        let hostField = addSheet.comboBoxes.firstMatch
        let paths = addSheet.textViews.firstMatch
        XCTAssertTrue(hostField.waitForExistence(timeout: 10))
        XCTAssertTrue(paths.waitForExistence(timeout: 10))
        hostField.click()
        hostField.typeKey("a", modifierFlags: .command)
        hostField.typeText(host)
        paths.click()
        paths.typeText(remoteRoot)
        addSheet.buttons["Add"].click()

        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 25))
        files.click()
        let alpha = WorkspaceUITestSupport.fileRow(URL(fileURLWithPath: firstPath), in: window)
        let beta = WorkspaceUITestSupport.fileRow(URL(fileURLWithPath: secondPath), in: window)
        XCTAssertTrue(alpha.waitForExistence(timeout: 25), "Real SSH Files tree must show alpha")
        XCTAssertTrue(beta.waitForExistence(timeout: 25), "Real SSH Files tree must show beta")
        alpha.click()
        XCUIElement.perform(withKeyModifiers: .shift) { beta.click() }
        XCTAssertTrue(alpha.isSelected && beta.isSelected)

        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        let warning = window.sheets.firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10),
                      "Remote Delete must show a window-owned native confirmation")
        XCTAssertTrue(warning.buttons["Cancel"].exists)
        XCTAssertTrue(warning.buttons["Delete"].exists,
                      "Remote deletion must require an explicit destructive confirmation")
        warning.buttons["Cancel"].click()
        XCTAssertEqual(try runSSH(host: host, command:
            "test -f '\(firstPath)' && test -f '\(secondPath)' && printf preserved"),
            "preserved", "Cancel must not remove any remote bytes")

        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        let confirmed = window.sheets.firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout: 10))
        confirmed.buttons["Delete"].click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: alpha)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 25), .completed)
        XCTAssertEqual(try runSSH(host: host, command:
            "test ! -e '\(firstPath)' && test ! -e '\(secondPath)' && printf deleted"),
            "deleted", "Confirm must permanently remove only the remote fixture files")
    }

    private func runSSH(host: String, command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ControlMaster=no",
                             "-o", "ControlPath=none", "-o", "StrictHostKeyChecking=yes",
                             "-o", "ConnectTimeout=8", "-T", "--", host, command]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let reason = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "BaileyRemoteUITest", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return text
    }

    private func fileContextMenu(for row: XCUIElement, in app: XCUIApplication) throws -> XCUIElement {
        row.rightClick()
        return try XCTUnwrap(app.menus.allElementsBoundByIndex.first { menu in
            menu.frame.width > 50 && menu.menuItems["Copy Relative Path"].exists
        }, "Files context menu must be selected instead of the global Edit menu")
    }

    func testExplorerMenuUsesVSCodeFileAndDirectoryActions() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let nested = try fixture.file("folder/leaf.txt", text: "menu bytes\n")
        let originalClipboard = try WorkspaceUITestSupport.clipboardItems()
        defer {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !originalClipboard.isEmpty { XCTAssertTrue(pasteboard.writeObjects(originalClipboard)) }
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let folder = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label == %@", "folder")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        let folderMenu = try fileContextMenu(for: folder, in: app)
        for title in ["New File…", "New Folder…", "Cut", "Copy", "Paste",
                      "Copy Path", "Copy Relative Path", "Rename", "Move to Trash"] {
            XCTAssertTrue(folderMenu.menuItems[title].exists, "Missing VS Code folder action: \(title)")
        }
        for title in ["Move To…", "Duplicate", "cd Here", "Open in Integrated Terminal",
                      "Open to the Side", "Unfold Directory", "Fold Directory"] {
            XCTAssertFalse(folderMenu.menuItems[title].exists, "Removed action: \(title)")
        }
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        folder.click()
        app.typeKey("c", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        let folderCopy = fixture.root.appendingPathComponent("folder copy/leaf.txt")
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: folderCopy.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 15), .completed,
                       "Copy+Paste on the selected folder must create a sibling, not recurse")
        XCTAssertEqual(try Data(contentsOf: folderCopy), Data("menu bytes\n".utf8))
        XCTAssertEqual(try Data(contentsOf: nested), Data("menu bytes\n".utf8))

        let row = WorkspaceUITestSupport.fileRow(nested, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let fileMenu = try fileContextMenu(for: row, in: app)
        for title in ["Open", "Cut", "Copy", "Copy Path",
                      "Copy Relative Path", "Rename", "Move to Trash"] {
            XCTAssertTrue(fileMenu.menuItems[title].exists, "Missing VS Code file action: \(title)")
        }
        for title in ["Move To…", "Duplicate", "New File…", "New Folder…", "Paste",
                      "Open to the Side", "cd Here", "Unfold Directory", "Fold Directory"] {
            XCTAssertFalse(fileMenu.menuItems[title].exists, "Unrelated file action: \(title)")
        }
        fileMenu.menuItems["Copy Relative Path"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "folder/leaf.txt")
        XCTAssertEqual(try Data(contentsOf: nested), Data("menu bytes\n".utf8))
    }

    func testModifierMultiSelectionDoesNotOpenOrCollapseFiles() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("a.swift", text: "a\n")
        let beta = try fixture.file("b.swift", text: "b\n")
        let gamma = try fixture.file("c.swift", text: "c\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileRow(alpha, in: window)
        let b = WorkspaceUITestSupport.fileRow(beta, in: window)
        let c = WorkspaceUITestSupport.fileRow(gamma, in: window)
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        XCTAssertTrue(c.waitForExistence(timeout: 15))

        a.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(alpha, in: window)
            .waitForExistence(timeout: 15))
        let baselineTabs = window.buttons.matching(identifier: "bailey.tab.file").count
        XCUIElement.perform(withKeyModifiers: .shift) { c.click() }
        XCTAssertTrue(a.isSelected && b.isSelected && c.isSelected,
                      "Shift-click must select the range between visible rows")
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, baselineTabs,
                       "Shift selection must not preview or activate another file")
        XCUIElement.perform(withKeyModifiers: .command) { b.click() }
        XCTAssertTrue(a.isSelected && !b.isSelected && c.isSelected,
                      "Command-click selection: a=\(a.isSelected), b=\(b.isSelected), c=\(c.isSelected)")
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, baselineTabs)
        app.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(a.isSelected && b.isSelected && c.isSelected,
                      "Command+A in focused Files must select every visible row")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .shift)
        XCTAssertTrue(c.isSelected, "Shift+Down must keep the visible selection")
        XCTAssertEqual(try String(contentsOf: beta, encoding: .utf8), "b\n")
        XCTAssertEqual(try String(contentsOf: gamma, encoding: .utf8), "c\n")
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
