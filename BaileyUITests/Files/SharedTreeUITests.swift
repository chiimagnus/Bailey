import AppKit
import XCTest

@MainActor
final class SharedTreeUITests: XCTestCase {
    func testFileAndFolderContextMenusDoNotBrowseOrOpen() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let nested = try fixture.file("folder/real-file.swift", text: "original file bytes\n")
        let another = try fixture.file("root-file.swift", text: "untouched\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let folder = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "folder")).firstMatch
        guard folder.waitForExistence(timeout: 20) else {
            XCTFail("The native Files tree must expose the fixture folder")
            return
        }
        let nestedRow = WorkspaceUITestSupport.fileRow(nested, in: window)
        XCTAssertFalse(nestedRow.exists)
        folder.rightClick()
        let copyFolder = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Copy Path", "复制路径"])).firstMatch
        XCTAssertTrue(copyFolder.waitForExistence(timeout: 8))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(nestedRow.exists, "Right-click must not toggle a folder")
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 0)

        folder.click()
        XCTAssertTrue(nestedRow.waitForExistence(timeout: 12))
        nestedRow.rightClick()
        let open = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Open", "打开"])).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 0,
                       "Context-click must not execute the file's primary browse action")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: nested), Data("original file bytes\n".utf8))
        XCTAssertEqual(try Data(contentsOf: another), Data("untouched\n".utf8))
    }

    func testRightClickUnselectedFileBecomesKeyboardTargetWithoutOpeningIt() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = try fixture.file("a-active.txt", text: "active\n")
        let clicked = try fixture.file("b-context.txt", text: "context\n")
        let previousClipboard = try WorkspaceUITestSupport.clipboardItems()
        defer {
            NSPasteboard.general.clearContents()
            if !previousClipboard.isEmpty {
                XCTAssertTrue(NSPasteboard.general.writeObjects(previousClipboard))
            }
        }

        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root
        )
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let first = WorkspaceUITestSupport.fileRow(original, in: window)
        let target = WorkspaceUITestSupport.fileRow(clicked, in: window)
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        first.click()
        target.rightClick()
        let menu = app.menus.allElementsBoundByIndex.first {
            $0.frame.width > 50 && $0.menuItems["Copy Relative Path"].exists
        }
        XCTAssertNotNil(menu, "Context target must expose its own menu")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.activate()
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), clicked.path,
                       "Cmd-C after context click must copy the right-clicked file")
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 1,
                       "Right click must not open another editor tab")
    }

    func testContextMenuCommandCCopiesRightClickedFileWhileFilesOwnsFocus() throws {
        guard (try? WorkspaceUITestSupport.clipboardItems()) != nil else {
            throw XCTSkip("The current clipboard cannot be backed up without losing data")
        }
        let fixture = try WorkspaceUITestFixture(in: self)
        let selected = try fixture.file("a-selected.txt", text: "alpha\n")
        let target = try fixture.file("b-context.txt", text: "beta\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileRow(selected, in: window)
        let b = WorkspaceUITestSupport.fileRow(target, in: window)
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        a.click()
        b.rightClick()
        XCTAssertTrue(a.isSelected && !b.isSelected)
        XCTAssertTrue(app.menus.allElementsBoundByIndex.contains {
            $0.menuItems["Copy Relative Path"].exists
        }, "Right-click menu must remain open when Cmd-C is sent")
        app.typeKey("c", modifierFlags: .command)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), target.path)
        XCTAssertNotNil(NSPasteboard.general.data(forType:
            NSPasteboard.PasteboardType("com.chiimagnus.bailey.files.transfer")))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "beta\n")
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "alpha\n")
    }

    func testContextMenuCommandCCopiesFileWithoutStealingTerminalFocus() throws {
        guard (try? WorkspaceUITestSupport.clipboardItems()) != nil else {
            throw XCTSkip("The current clipboard cannot be backed up without losing data")
        }
        let fixture = try WorkspaceUITestFixture(in: self)
        let target = try fixture.file("a-context.txt", text: "context\n")
        let selected = try fixture.file("b-selected.txt", text: "selected\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileRow(selected, in: window)
        let b = WorkspaceUITestSupport.fileRow(target, in: window)
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        a.click()
        app.typeKey("t", modifierFlags: .command)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.60)).click()
        b.rightClick()
        XCTAssertTrue(a.isSelected && !b.isSelected)
        XCTAssertTrue(app.menus.allElementsBoundByIndex.contains {
            $0.menuItems["Copy Relative Path"].exists
        })
        app.typeKey("c", modifierFlags: .command)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), target.path)
        XCTAssertNotNil(NSPasteboard.general.data(forType:
            NSPasteboard.PasteboardType("com.chiimagnus.bailey.files.transfer")))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let marker = fixture.root.appendingPathComponent("terminal-owns-focus.txt")
        app.typeText("printf terminal > '\(marker.path)'")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: marker.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 12), .completed)
    }

    func testCompactFoldersContextMenuCreatesInEachClickedPathComponent() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let nested = try fixture.file("a1/b1/c1/existing.swift", text: "existing\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch

        for (name, path) in [
            ("a1", "a1"), ("b1", "a1/b1"), ("c1", "a1/b1/c1")
        ] {
            let row = window.descendants(matching: .any)
                .matching(identifier: "bailey.tree.folder")
                .matching(NSPredicate(format: "label == %@", name)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), "Missing folder \(path)")
            row.click()
        }
        XCTAssertTrue(WorkspaceUITestSupport.fileRow(nested, in: window)
            .waitForExistence(timeout: 12))
        for (index, directory, name) in [
            (2, "a1/b1/c1", "child.swift"),
            (1, "a1/b1", "middle.swift"),
            (0, "a1", "parent.swift")
        ] {
            let compact = window.descendants(matching: .any)
                .matching(identifier: "bailey.tree.folder")
                .matching(NSPredicate(format: "label CONTAINS %@", "a1 / b1")).firstMatch
            XCTAssertTrue(compact.waitForExistence(timeout: 15))
            let component = compact.descendants(matching: .any)
                .matching(identifier: "bailey.tree.folder.component.\(index)").firstMatch
            XCTAssertTrue(component.waitForExistence(timeout: 10),
                          "Compact component \(index) must be independently accessible")
            component.rightClick()
            let contextMenu = try XCTUnwrap(app.menus.allElementsBoundByIndex.first {
                $0.frame.width > 50 && $0.frame.height > 50
            }, "The clicked compact segment must open its own visible context menu")
            let create = contextMenu.menuItems.matching(NSPredicate(
                format: "title IN %@", ["New File…", "New File..."]
            )).firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 8))
            create.click()
            let field = window.textFields["File name"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.typeText(name)
            field.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            let target = fixture.root.appendingPathComponent("\(directory)/\(name)")
            let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: target.path)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 12), .completed,
                           "\(name) must be created directly within \(directory)")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("a1/b1/c1/parent.swift").path))
    }

    func testCompactFoldersStayCompactedWithAccessibleComponentActions() throws {
        let originalClipboard = try WorkspaceUITestSupport.clipboardItems()
        defer {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !originalClipboard.isEmpty { XCTAssertTrue(pasteboard.writeObjects(originalClipboard)) }
        }
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("a1/b1/c1/leaf.swift", text: "leaf\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        func folder(_ label: String) -> XCUIElement {
            window.descendants(matching: .any)
                .matching(identifier: "bailey.tree.folder")
                .matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        for name in ["a1", "b1", "c1"] {
            let row = folder(name)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.click()
        }
        let compact = folder("a1 / b1 / c1")
        XCTAssertTrue(compact.waitForExistence(timeout: 12))
        let leaf = WorkspaceUITestSupport.fileRow(
            fixture.root.appendingPathComponent("a1/b1/c1/leaf.swift"), in: window
        )
        XCTAssertTrue(leaf.waitForExistence(timeout: 12))
        let middle = compact.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder.component.1").firstMatch
        XCTAssertTrue(middle.waitForExistence(timeout: 8))
        middle.click()
        XCTAssertTrue(leaf.waitForNonExistence(timeout: 12),
                      "Clicking the middle segment must toggle the compact folder")
        middle.click()
        XCTAssertTrue(leaf.waitForExistence(timeout: 12))
        let component = compact.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder.component.0").firstMatch
        XCTAssertTrue(component.waitForExistence(timeout: 10))
        component.rightClick()
        let popup = try XCTUnwrap(app.menus.allElementsBoundByIndex.first {
            $0.frame.width > 50 && $0.frame.height > 50
        })
        XCTAssertFalse(popup.menuItems["Unfold Directory"].exists)
        XCTAssertFalse(popup.menuItems["Fold Directory"].exists)
        let relative = popup.menuItems["Copy Relative Path"]
        XCTAssertTrue(relative.waitForExistence(timeout: 8))
        relative.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "a1")
        XCTAssertTrue(folder("a1 / b1 / c1").waitForExistence(timeout: 12))
        XCTAssertTrue(leaf.exists)
    }

    func testSharedTreeHitAreasOpenExactFileWithoutDuplicateTabs() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let nested = try fixture.file("folder/target.swift", text: "correct file\n")
        let unrelated = try fixture.file("unrelated.swift", text: "never opened\n")
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let folder = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "folder")).firstMatch
        guard folder.waitForExistence(timeout: 20) else {
            XCTFail("The native Files tree must expose the fixture folder")
            return
        }
        let target = WorkspaceUITestSupport.fileRow(nested, in: window)
        for fraction: CGFloat in [0.12, 0.66, 0.92] {
            folder.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).click()
            XCTAssertTrue(target.waitForExistence(timeout: 10),
                          "Folder must open across its full real row width")
            folder.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).click()
            XCTAssertTrue(target.waitForNonExistence(timeout: 10),
                          "Folder must close across its full real row width")
        }
        folder.click()
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        for fraction: CGFloat in [0.12, 0.66, 0.92] {
            target.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).click()
            XCTAssertTrue(WorkspaceUITestSupport.fileTab(nested, in: window)
                .waitForExistence(timeout: 15), "Every file row hit area must browse its own file")
            XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 1)
            XCTAssertFalse(WorkspaceUITestSupport.fileTab(unrelated, in: window).exists)
        }
        target.doubleClick()
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 1,
                       "Double-click must activate without creating a duplicate editor")
        XCTAssertEqual(window.textViews.firstMatch.value as? String, "correct file\n")
        XCTAssertEqual(try Data(contentsOf: nested), Data("correct file\n".utf8))
    }

    func testSharedTreeLongLabelsScrollButShortLabelsRemainStableAcrossRealDockResize() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let longName = String(repeating: "wide-", count: 12) + "target.swift"
        let longFile = try fixture.file(longName, text: "long name contents\n")
        let shortFile = try fixture.file("tiny.swift", text: "short name contents\n")
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let longRow = WorkspaceUITestSupport.fileRow(longFile, in: window)
        let shortRow = WorkspaceUITestSupport.fileRow(shortFile, in: window)
        XCTAssertTrue(longRow.waitForExistence(timeout: 20))
        XCTAssertTrue(shortRow.waitForExistence(timeout: 20))

        longRow.click()
        let narrowStart = try rowPixels(longRow)
        longRow.scroll(byDeltaX: -360, deltaY: 0)
        let narrowMoved = try rowPixels(longRow)
        XCTAssertNotEqual(narrowStart, narrowMoved,
                          "A real long file name must scroll inside its narrow Files row")

        shortRow.click()
        let shortStart = try rowPixels(shortRow)
        shortRow.scroll(byDeltaX: -360, deltaY: 0)
        XCTAssertEqual(try rowPixels(shortRow), shortStart,
                       "A short filename must not bounce under a horizontal wheel input")

        let divider = try XCTUnwrap(window.descendants(matching: .any)
            .matching(identifier: "bailey.dock.divider").allElementsBoundByIndex
            .filter { $0.frame.height > $0.frame.width }
            .max { $0.frame.minX < $1.frame.minX })
        let origin = window.coordinate(withNormalizedOffset: .zero)
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(
                dx: window.frame.width - 560, dy: window.frame.height / 2)))
        XCTAssertTrue(longRow.waitForExistence(timeout: 12))
        longRow.click()
        let wideStart = try rowPixels(longRow)
        longRow.scroll(byDeltaX: -360, deltaY: 0)
        XCTAssertEqual(try rowPixels(longRow), wideStart,
                       "Widening Files enough for the full name must stop unnecessary horizontal scrolling")
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(shortFile, in: window).exists)
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(longFile, in: window).exists)
        XCTAssertEqual(try Data(contentsOf: longFile), Data("long name contents\n".utf8))
    }

    private func rowPixels(_ row: XCUIElement) throws -> Data {
        let tiff = try XCTUnwrap(row.screenshot().image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    func testLongGitChangeScrollDoesNotMoveItsRealStageButton() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let name = String(repeating: "overflow-", count: 12) + "change.swift"
        let modified = try fixture.file(name, text: "old contents\n")
        let unchanged = try fixture.file("unrelated.swift", text: "keep this\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "new contents\n".write(to: modified, atomically: true, encoding: .utf8)
        let home = try WorkspaceUITestFixture(in: self)
        _ = try home.file(".config/bailey-dev/config.toml",
            text: "theme = \"dark\"\npanel.font-size = 18\n")
        let app = try WorkspaceUITestSupport.launch(in: self, configurationHome: home.root, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(modified, in: window, relativeTo: fixture.root)
        guard row.waitForExistence(timeout: 25) else {
            XCTFail("The actual modified Git entry must appear in the narrow Changes pane")
            return
        }
        row.hover()
        func stageButton() -> XCUIElement? {
            window.buttons.matching(NSPredicate(format: "label IN %@",
                ["Stage Changes", "暂存更改"])).allElementsBoundByIndex.first {
                abs($0.frame.midY - row.frame.midY) < 5
            }
        }
        let stage = try XCTUnwrap(stageButton(),
                                  "The modified Git file must retain its own inline Stage action")
        let stageX = stage.frame.minX
        let rowX = row.frame.minX
        let before = try rowPixels(row)
        row.scroll(byDeltaX: -420, deltaY: 0)
        XCTAssertNotEqual(try rowPixels(row), before,
                          "A long Git Changes filename must really scroll inside its row")
        XCTAssertEqual(stage.frame.minX, stageX, accuracy: 1,
                       "Horizontal name scrolling must not move its separate Git Stage action")
        XCTAssertEqual(row.frame.minX, rowX, accuracy: 1)
        stage.click()
        let staged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":" + name])) == Data("new contents\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [staged], timeout: 20), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: modified), Data("new contents\n".utf8))
        XCTAssertEqual(try Data(contentsOf: unchanged), Data("keep this\n".utf8))
        XCTAssertFalse(WorkspaceUITestSupport.fileTab(modified, in: window).exists,
                       "Using Stage must not accidentally open the file")
    }

    func testGitFolderShortNameDoesNotBounceAndInlineStageKeepsTheExactDirectory() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let a = try fixture.file("small/a.swift", text: "first old\n")
        let b = try fixture.file("small/b.swift", text: "second old\n")
        let other = try fixture.file("outside.swift", text: "untouched\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "first new\n".write(to: a, atomically: true, encoding: .utf8)
        try "second new\n".write(to: b, atomically: true, encoding: .utf8)
        let home = try WorkspaceUITestFixture(in: self)
        _ = try home.file(".config/bailey-dev/config.toml",
            text: "theme = \"dark\"\npanel.font-size = 18\n")
        let app = try WorkspaceUITestSupport.launch(in: self, configurationHome: home.root, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let folder = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "small,")).firstMatch
        guard folder.waitForExistence(timeout: 25) else {
            XCTFail("A modified Git folder must have its own real row")
            return
        }
        folder.hover()
        let stage = try XCTUnwrap(window.buttons.matching(NSPredicate(
            format: "label IN %@", ["Stage Changes", "暂存更改"])).allElementsBoundByIndex.first {
            abs($0.frame.midY - folder.frame.midY) < 5
        })
        let before = try rowPixels(folder)
        let stageX = stage.frame.minX
        folder.scroll(byDeltaX: -420, deltaY: 0)
        XCTAssertEqual(try rowPixels(folder), before,
                       "Short Git folder names must not bounce under horizontal scrolling")
        XCTAssertEqual(stage.frame.minX, stageX, accuracy: 1)
        stage.click()
        let correctIndex = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":small/a.swift"])) == Data("first new\n".utf8)
                && (try? fixture.git(["show", ":small/b.swift"])) == Data("second new\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [correctIndex], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["show", ":outside.swift"]), Data("untouched\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: other), Data("untouched\n".utf8))
        XCTAssertFalse(WorkspaceUITestSupport.fileTab(a, in: window).exists)
        XCTAssertFalse(WorkspaceUITestSupport.fileTab(b, in: window).exists)
    }

    func testLightFileSelectionFillRemainsAfterCommandPaletteTakesFocus() throws {
        try verifySelectionAndFocus(appearance: "light")
    }

    func testDarkFileSelectionFillRemainsAfterCommandPaletteTakesFocus() throws {
        try verifySelectionAndFocus(appearance: "dark")
    }

    private func verifySelectionAndFocus(appearance: String) throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("alpha.swift", text: "alpha bytes\n")
        let beta = try fixture.file("beta.swift", text: "beta bytes\n")
        let home = try WorkspaceUITestFixture(in: self)
        _ = try home.file(".config/bailey-dev/config.toml",
            text: "theme = \"\(appearance)\"\n")
        let app = try WorkspaceUITestSupport.launch(in: self, configurationHome: home.root, project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let first = WorkspaceUITestSupport.fileRow(alpha, in: window)
        let second = WorkspaceUITestSupport.fileRow(beta, in: window)
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        XCTAssertTrue(second.waitForExistence(timeout: 20))
        first.click()
        XCTAssertTrue(first.isSelected,
                      "The focused Files row must expose its native selected AX trait")
        let selected = try backgroundPixel(in: first)
        let unselected = try backgroundPixel(in: second)
        XCTAssertGreaterThan(rgbDifference(selected, unselected), 0.045,
                             "Only the actual current file should retain selection fill")
        app.typeKey("p", modifierFlags: .command)
        let search = app.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isSelected,
                      "Command Palette must not clear the file's selection when keyboard focus moves")
        let focusChanged = try backgroundPixel(in: first)
        let neutralWhileSearching = try backgroundPixel(in: second)
        XCTAssertGreaterThan(rgbDifference(focusChanged, neutralWhileSearching), 0.045,
                             "The selected row must retain its own fill while search owns the keyboard; selected=\(focusChanged), neutral=\(neutralWhileSearching)")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(beta, in: window).waitForExistence(timeout: 15))
        XCTAssertEqual(try Data(contentsOf: alpha), Data("alpha bytes\n".utf8))
        XCTAssertEqual(try Data(contentsOf: beta), Data("beta bytes\n".utf8))
    }

    private func backgroundPixel(in row: XCUIElement) throws -> NSColor {
        let tiff = try XCTUnwrap(row.screenshot().image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 9 / 10,
                                             y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    private func rgbDifference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    func testRealOpenFileMenuHasSingleItemAndCommandOUsesNativePicker() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("menu-target.swift", text: "menu target bytes\n")
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        let fileMenu = app.menuBars.menuBarItems.matching(NSPredicate(
            format: "title IN %@", ["File", "文件"])).firstMatch
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 10))
        fileMenu.click()
        let open = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Open File…", "打开文件…"]))
        XCTAssertEqual(open.count, 1, "File menu must contain exactly one localized Open File action")
        XCTAssertTrue(open.firstMatch.isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey("o", modifierFlags: .command)
        try WorkspaceUITestSupport.choose(file, in: app)
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: app.windows.firstMatch)
            .waitForExistence(timeout: 15))
        XCTAssertEqual(try Data(contentsOf: file), Data("menu target bytes\n".utf8))
    }
}
