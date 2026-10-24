import AppKit
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

    func testCancelingFolderPickerDoesNotCreateAnEmptyProject() throws {
        let app = try WorkspaceUITestSupport.launch(in: self)

        app.buttons["bailey.emptyState.addFolder"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["bailey.emptyState.addFolder"].waitForExistence(timeout: 10),
                      "Cancel must leave the original empty workspace unchanged")
    }

    func testLaunchServicesOpensAndReusesFilesInTheExistingDevWindow() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("incoming.swift", text: "let external = true\n")
        let unicode = try fixture.file("中文 🧪.swift", text: "let 测试 = 1\n")
        let nested = try fixture.file("nested/deep.md", text: "# hello\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.git", in: app).click()
        let originalWindowCount = app.windows.count
        let bundle = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "chiimagnus.bailey.dev")
                .compactMap(\.bundleURL).first,
            "Only the isolated Bailey Dev instance may receive system file-open events"
        )
        XCTAssertTrue(bundle.path.contains("DerivedData-Dev/Build/Products/Debug/"),
                      "A Launch Services test may never target the installed Bailey")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: bundle, configuration: config) {
            _, error in XCTAssertNil(error, "Launch Services should deliver an actual file URL")
        }
        let window = app.windows.firstMatch
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: window)
            .waitForExistence(timeout: 20),
            "An Apple Event must create a real file tab in the current project")
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 1)
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, "let external = true\n")

        // The narrow Dock strip can scroll Git outside the AX viewport.
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 10))
        NSWorkspace.shared.open([file], withApplicationAt: bundle, configuration: config) {
            _, error in XCTAssertNil(error, "A repeated system open must reach the same Dev app")
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 1,
                       "Repeated system opens must reuse the existing buffer")
        NSWorkspace.shared.open([unicode, nested], withApplicationAt: bundle, configuration: config) {
            _, error in XCTAssertNil(error, "System batch-open must deliver both file URLs")
        }
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(unicode, in: window)
            .waitForExistence(timeout: 15))
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(nested, in: window)
            .waitForExistence(timeout: 15))
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 3,
                       "One system batch must open each new file exactly once")
        XCTAssertEqual(app.windows.count, originalWindowCount,
                       "External document opening must not create an additional workspace window")
        XCTAssertEqual(try Data(contentsOf: file), Data("let external = true\n".utf8))
        XCTAssertEqual(try Data(contentsOf: unicode), Data("let 测试 = 1\n".utf8))
        XCTAssertEqual(try Data(contentsOf: nested), Data("# hello\n".utf8))
    }

    func testLaunchServicesReusesTheOriginalFileOwnerAcrossWindows() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let a = try fixture.file("owner-a/shared.swift", text: "file A\n")
        let b = try fixture.file("owner-b/other.swift", text: "file B\n")
        let folderA = fixture.root.appendingPathComponent("owner-a", isDirectory: true)
        let folderB = fixture.root.appendingPathComponent("owner-b", isDirectory: true)
        let app = try WorkspaceUITestSupport.launch(in: self)

        try WorkspaceUITestSupport.addFolder(folderA, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let ownerWindow = try XCTUnwrap(window(containing: a, in: app))
        let rowA = WorkspaceUITestSupport.fileRow(a, in: ownerWindow)
        XCTAssertTrue(rowA.waitForExistence(timeout: 20))
        rowA.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(a, in: ownerWindow)
            .waitForExistence(timeout: 15))

        app.typeKey("n", modifierFlags: [.command, .shift])
        let emptyWindow = try XCTUnwrap(app.windows.allElementsBoundByIndex.first {
            $0.buttons["bailey.emptyState.addFolder"].exists
        })
        let receiverWindow = app.windows.matching(identifier: emptyWindow.identifier).firstMatch
        try WorkspaceUITestSupport.addFolder(folderB, to: app, in: receiverWindow)
        let rowB = WorkspaceUITestSupport.fileRow(b, in: receiverWindow)
        XCTAssertTrue(rowB.waitForExistence(timeout: 20))
        rowB.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(b, in: receiverWindow).waitForExistence(timeout: 10))
        let receiverTabCount = receiverWindow.buttons.matching(identifier: "bailey.tab.file").count
        XCTAssertNotEqual(ownerWindow.identifier, receiverWindow.identifier,
                          "The fixture must establish distinct windows before the Apple Event")

        let bundle = try XCTUnwrap(
            NSRunningApplication.runningApplications(withBundleIdentifier: "chiimagnus.bailey.dev")
                .compactMap(\.bundleURL).first
        )
        XCTAssertTrue(bundle.path.contains("DerivedData-Dev/Build/Products/Debug/"))
        let eventDelivered = expectation(description: "Launch Services delivered the existing file")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([a], withApplicationAt: bundle, configuration: config) {
            _, error in
            XCTAssertNil(error)
            eventDelivered.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [eventDelivered], timeout: 15), .completed)
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(a, in: app.windows.firstMatch)
            .waitForExistence(timeout: 15),
            "System file-open must reactivate the owning window, not the receiving project")
        // Keep both windows pinned by AX identifier: index queries change when
        // Launch Services raises the owning window.
        XCTAssertNotEqual(ownerWindow.identifier, receiverWindow.identifier)
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(a, in: ownerWindow).exists)
        XCTAssertEqual(ownerWindow.buttons.matching(identifier: "bailey.tab.file").count, 1)
        XCTAssertEqual(receiverWindow.buttons.matching(identifier: "bailey.tab.file").count,
                       receiverTabCount, "The receiving window must not gain the other window's file")
        XCTAssertFalse(WorkspaceUITestSupport.fileTab(a, in: receiverWindow).exists)
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(b, in: receiverWindow).exists)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "file A\n")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "file B\n")
    }

    func testNativeFolderPickersStayInsideTheirOwningWindows() throws {
        let app = try WorkspaceUITestSupport.launch(in: self)
        let firstID = app.windows.firstMatch.identifier
        let first = app.windows.matching(identifier: firstID).firstMatch

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertEqual(app.windows.count, 2)
        let newID = try XCTUnwrap(app.windows.allElementsBoundByIndex
            .first(where: { $0.identifier != firstID })?.identifier)
        let second = app.windows.matching(identifier: newID).firstMatch
        XCTAssertNotEqual(first.identifier, second.identifier)

        for (owner, other) in [(second, first), (first, second)] {
            activate(owner, in: app)
            let add = owner.buttons["bailey.emptyState.addFolder"]
            XCTAssertTrue(add.waitForExistence(timeout: 15))
            add.click()
            XCTAssertTrue(owner.sheets.firstMatch.waitForExistence(timeout: 15))
            XCTAssertFalse(other.sheets.firstMatch.exists,
                           "Native folder picker must never attach to another workspace window")
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            XCTAssertTrue(owner.sheets.firstMatch.waitForNonExistence(timeout: 10))
            XCTAssertTrue(add.exists, "Cancel must not add a project")
        }
        XCTAssertEqual(app.windows.count, 2)
    }

    func testNativeWindowCloseAndRelaunchRestoreTheSameFileAndBytes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("restored/sample.swift", text: "let restored = true\n")
        let folder = fixture.root.appendingPathComponent("restored", isDirectory: true)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root
        )
        try WorkspaceUITestSupport.addFolder(folder, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let owner = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: owner)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.doubleClick()
        let editor = owner.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let originalBytes = try Data(contentsOf: file)
        editor.click()
        editor.typeText("RESTORED_MARKER")
        XCTAssertTrue((editor.value as? String)?.contains("RESTORED_MARKER") == true)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes,
                       "The native edit must still be unsaved before window closure")

        // A native close must save pending edits and the Bailey session snapshot;
        // terminate() alone is not a normal Quit.
        let close = owner.buttons["_XCUI:CloseWindow"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.click()
        XCTAssertTrue(owner.waitForNonExistence(timeout: 12))
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8))?.contains("RESTORED_MARKER") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed,
                       "Closing a dirty native window must persist the new disk bytes")
        let savedBytes = try Data(contentsOf: file)
        app.terminate()
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 4) {
            // With AppKit state restoration intentionally disabled, obtain a
            // real WindowGroup scene through the existing system menu command.
            let newWindow = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["New Window", "新建窗口"])).firstMatch
            XCTAssertTrue(newWindow.waitForExistence(timeout: 10))
            newWindow.click()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15),
                      "The native New Window command must open the restored workspace")
        let restoredWindow = app.windows.firstMatch
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: restoredWindow)
            .waitForExistence(timeout: 20), "The restored session must retain its file tab")
        XCTAssertTrue(restoredWindow.textViews.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue((restoredWindow.textViews.firstMatch.value as? String)?
            .contains("RESTORED_MARKER") == true)
        XCTAssertEqual(try Data(contentsOf: file), savedBytes)
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
        let windowA = try XCTUnwrap(window(containing: secondA, in: app))
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
        let unboundEmpty = try XCTUnwrap(app.windows.allElementsBoundByIndex.first {
            $0.buttons["bailey.emptyState.addFolder"].exists
        })
        let emptyWindow = app.windows.matching(identifier: unboundEmpty.identifier).firstMatch
        try WorkspaceUITestSupport.addFolder(folderB, to: app, in: emptyWindow)
        emptyWindow.descendants(matching: .any)
            .matching(identifier: "bailey.dock.files").firstMatch.click()

        let windowB = try XCTUnwrap(window(containing: secondB, in: app))
        XCTAssertNotEqual(windowA.identifier, windowB.identifier,
                          "A and B must be separate native windows")
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

        editorB = windowB.textViews.firstMatch
        editorB.click()
        app.typeKey("p", modifierFlags: .command)
        let searchB = windowB.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(searchB.waitForExistence(timeout: 10))
        searchB.typeText("File Manager")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertFalse(windowB.textFields["bailey.commandPalette.search"].waitForExistence(timeout: 5),
                       "Selecting File Manager must close the palette in this window")
        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(firstB, in: windowB)
            .waitForExistence(timeout: 15),
            "The second window's restored Files focus must open its own first file")
        waitForMarker("WINDOW_B_MARKER", in: secondB)
        let savedB = try Data(contentsOf: secondB)
        XCTAssertFalse(WorkspaceUITestSupport.fileTab(firstA, in: windowA).exists,
                       "Keyboard navigation in the second window must not open a file in the first")
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(secondA, in: windowA).exists)
        XCTAssertEqual(try Data(contentsOf: secondA), savedA)

        // A is behind B. Cycle native windows until A is actually frontmost.
        activate(windowA, in: app)
        editorA = windowA.textViews.firstMatch
        XCTAssertTrue((editorA.value as? String)?.contains("WINDOW_A_MARKER") == true)
        editorA.click()
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

    private func activate(_ window: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<app.windows.count {
            if app.windows.firstMatch.identifier == window.identifier { return }
            app.typeKey("`", modifierFlags: .command)
        }
        XCTAssertEqual(app.windows.firstMatch.identifier, window.identifier,
                       "A background window must become the actual keyboard owner")
    }

    private func workspaceWindowCount(in app: XCUIApplication) -> Int {
        app.windows.allElementsBoundByIndex.filter {
            $0.descendants(matching: .any)
                .matching(identifier: "bailey.dock.files").firstMatch.exists
        }.count
    }

    private func window(containing file: URL, in app: XCUIApplication) -> XCUIElement? {
        // Resolve each candidate by its stable ID before testing file identity.
        // A query built with element(boundBy:) can retarget when window order changes.
        for candidate in app.windows.allElementsBoundByIndex {
            let window = app.windows.matching(identifier: candidate.identifier).firstMatch
            if WorkspaceUITestSupport.fileTab(file, in: window).exists
                || WorkspaceUITestSupport.fileRow(file, in: window).exists {
                return window
            }
        }
        return nil
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
