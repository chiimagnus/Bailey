import AppKit
import XCTest

@MainActor
final class WorkspaceRetentionUITests: XCTestCase {
    func testIsolatedSettingsThemePersistsAcrossRealAppRestart() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root
        )
        let config = fixture.root.appendingPathComponent(".config/bailey-dev/config.toml")
        let before = try Data(contentsOf: config)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("theme = \"dark\""))

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 15))
        let dark = app.radioButtons["Dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 12),
                      "Real Settings must expose the appearance control")
        dark.click()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: config) else { return false }
            return String(decoding: data, as: UTF8.self).contains("theme = \"dark\"")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 12), .completed,
                       "The selected appearance must be written to this isolated TOML")
        XCTAssertEqual(String(describing: dark.value ?? ""), "1",
                       "Native radio button value must reflect the selected theme")

        app.terminate()
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 4) {
            let newWindow = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["New Window", "新建窗口"])).firstMatch
            XCTAssertTrue(newWindow.waitForExistence(timeout: 10))
            newWindow.click()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        let restoredDark = app.radioButtons["Dark"].firstMatch
        XCTAssertTrue(restoredDark.waitForExistence(timeout: 12))
        XCTAssertEqual(String(describing: restoredDark.value ?? ""), "1",
                       "Restart must restore the selected theme in native Settings")
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8)
            .contains("theme = \"dark\""))
    }

    func testNormalQuitVetoesFailedSaveThenWritesAndRestoresSession() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("quit/unsaved.swift", text: "let original = 1\n")
        let folder = file.deletingLastPathComponent()
        let original = try Data(contentsOf: file)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root
        )
        try WorkspaceUITestSupport.addFolder(folder, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let owner = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: owner)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let editor = owner.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        editor.typeText("P4T5_DIRTY_QUIT")
        XCTAssertEqual(try Data(contentsOf: file), original)

        // Atomic replacement must fail until the directory becomes writable.
        // No global mocks, user files, SSH backend, or private termination hooks.
        let originalFileMode = (try FileManager.default.attributesOfItem(
            atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let originalFolderMode = (try FileManager.default.attributesOfItem(
            atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: originalFolderMode],
                                                   ofItemAtPath: folder.path)
            try? FileManager.default.setAttributes([.posixPermissions: originalFileMode],
                                                   ofItemAtPath: file.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: folder.path)
        app.typeKey("q", modifierFlags: .command)
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .notRunning
        }, object: nil)
        XCTAssertNotEqual(XCTWaiter.wait(for: [stopped], timeout: 3), .completed,
                          "A failed atomic file save must veto the real Quit")
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground)
        XCTAssertEqual(try Data(contentsOf: file), original,
                       "Failed Quit must not discard or partially overwrite the original")
        XCTAssertTrue((editor.value as? String)?.contains("P4T5_DIRTY_QUIT") == true)

        try FileManager.default.setAttributes([.posixPermissions: originalFolderMode],
                                              ofItemAtPath: folder.path)
        try FileManager.default.setAttributes([.posixPermissions: originalFileMode],
                                              ofItemAtPath: file.path)
        app.activate()
        app.typeKey("q", modifierFlags: .command)
        let successfullyQuit = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .notRunning
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [successfullyQuit], timeout: 20), .completed,
                       "A later real Command-Q must save and terminate")
        let stored = try Data(contentsOf: file)
        XCTAssertTrue(String(decoding: stored, as: UTF8.self).contains("P4T5_DIRTY_QUIT"))
        XCTAssertNotEqual(stored, original)

        // Same UUID and HOME: verify applicationWillTerminate's saved session.
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 4) {
            let newWindow = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["New Window", "新建窗口"])).firstMatch
            XCTAssertTrue(newWindow.waitForExistence(timeout: 10))
            newWindow.click()
        }
        let restored = app.windows.firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 15))
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: restored)
            .waitForExistence(timeout: 20))
        XCTAssertTrue((restored.textViews.firstMatch.value as? String)?
            .contains("P4T5_DIRTY_QUIT") == true)
        XCTAssertEqual(try Data(contentsOf: file), stored)
    }

    func testRealBrowserKeepsWebContentAcrossFileTabSwitches() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("project/neighbor.swift", text: "let untouched = true\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(file.deletingLastPathComponent(), to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: window).waitForExistence(timeout: 10))
        let originalBytes = try Data(contentsOf: file)

        let newBrowser = app.menuItems["New Browser Tab"]
        XCTAssertTrue(newBrowser.waitForExistence(timeout: 10))
        newBrowser.click()
        let address = window.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 12))
        // An in-memory page avoids network, browser defaults, and permission
        // changes while still using the real WKWebView/WebContent process.
        let html = "<html><head><title>P4T5 Browser Page</title></head><body>" +
            "<h1>Native Browser Retention</h1>" +
            "<input aria-label='P4T5 draft' value='initial'>" +
            "<div style='height:3000px'>Scroll area</div></body></html>"
        let addressURL = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        address.click()
        address.typeKey("a", modifierFlags: .command)
        address.typeText(addressURL)
        address.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let browser = window.webViews.firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 20))
        XCTAssertTrue(window.staticTexts["Native Browser Retention"].waitForExistence(timeout: 20))
        let draft = browser.textFields["P4T5 draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15),
                      "The real webpage must expose the editable HTML form")
        draft.click()
        draft.typeKey("a", modifierFlags: .command)
        draft.typeText("P4T5 UNSAVED FORM")
        XCTAssertEqual(draft.value as? String, "P4T5 UNSAVED FORM")

        WorkspaceUITestSupport.fileTab(file, in: window).click()
        XCTAssertEqual(window.textViews.firstMatch.value as? String, "let untouched = true\n")
        let browserTab = window.buttons["P4T5 Browser Page"]
        XCTAssertTrue(browserTab.waitForExistence(timeout: 15))
        browserTab.click()
        let reattached = window.webViews.firstMatch
        XCTAssertTrue(reattached.waitForExistence(timeout: 15))
        XCTAssertEqual(reattached.textFields["P4T5 draft"].value as? String,
                       "P4T5 UNSAVED FORM", "Switching tabs must not reload the WKWebView")
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 1)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
    }

    func testRealTerminalKeepsSameShellAcrossFileTabAndFind() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("workspace/neighbor.swift", text: "let terminalUntouched = true\n")
        let beforePID = fixture.root.appendingPathComponent("terminal-before.pid")
        let afterPID = fixture.root.appendingPathComponent("terminal-after.pid")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(file.deletingLastPathComponent(), to: app)
        let window = app.windows.firstMatch

        app.typeKey("t", modifierFlags: .command)
        let terminalCenter = window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.58))
        terminalCenter.click()
        func send(_ command: String, marker: URL) {
            app.typeText(command)
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            let output = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: marker.path)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [output], timeout: 15), .completed,
                           "The real focused Ghostty PTY must execute the command")
        }
        send("printf '%s' $$ > '\(beforePID.path)'", marker: beforePID)
        let originalShell = try String(contentsOf: beforePID, encoding: .utf8)
        XCTAssertFalse(originalShell.isEmpty)

        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: window).waitForExistence(timeout: 12))
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(window.textViews.firstMatch.value as? String,
                       "let terminalUntouched = true\n")

        app.typeKey("[", modifierFlags: [.command, .shift])
        terminalCenter.click()
        send("printf '%s' $$ > '\(afterPID.path)'", marker: afterPID)
        XCTAssertEqual(try String(contentsOf: afterPID, encoding: .utf8), originalShell,
                       "Switching real App tabs must preserve the same shell process")
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(window.textFields.firstMatch.waitForExistence(timeout: 12),
                      "Terminal Find must mount the native find input")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: window).exists)
        XCTAssertEqual(try Data(contentsOf: file), Data("let terminalUntouched = true\n".utf8))
    }

    func testFiveRoundsOfFiveRealFileTabsRetireWithoutChangingDisk() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let body = String(repeating: "let item = \"Chinese text\" // stable source\n", count: 10_000)
        let files = try (0..<5).map { index in
            try fixture.file("pressure/file-\(index).swift", text: body)
        }
        let expected = Data(body.utf8)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(files[0].deletingLastPathComponent(), to: app)
        // Close the narrow Projects tool group through the real user command,
        // so the remaining Files/Git work area can expand after the initially
        // empty center group is removed. The original layout deliberately
        // clips offscreen tabs; testing AX clicks outside that viewport is invalid.
        let projectsTool = WorkspaceUITestSupport.element("bailey.dock.projects", in: app)
        XCTAssertTrue(projectsTool.waitForExistence(timeout: 12))
        projectsTool.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(projectsTool.waitForNonExistence(timeout: 12),
                      "The pressure test must use an actual wide work area")
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.files", in: app).exists)
        let window = app.windows.firstMatch
        let windowID = window.identifier
        XCTAssertFalse(windowID.isEmpty)
        let owner = app.windows.matching(identifier: windowID).firstMatch
        let runningDev = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "chiimagnus.bailey.dev").first)
        let bundle = try XCTUnwrap(runningDev.bundleURL)
        XCTAssertTrue(bundle.path.contains("DerivedData-Dev/Build/Products/"),
                      "The pressure test must target the isolated Dev build, not the installed App")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        print("T5_APP_FILE_LIFETIME stage=baseline expectedTabs=0")
        for round in 0..<5 {
            NSWorkspace.shared.open(files, withApplicationAt: bundle, configuration: config) {
                _, error in XCTAssertNil(error, "The real App must accept the five-file batch")
            }
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                owner.buttons.matching(identifier: "bailey.tab.file").count == files.count
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 25), .completed,
                           "Every round must own exactly five distinct native file tabs")
            for file in files {
                XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: owner).exists)
                XCTAssertEqual(try Data(contentsOf: file), expected)
            }
            print("T5_APP_FILE_LIFETIME round=\(round) stage=open tabs=5")
            for file in files.reversed() {
                let tab = WorkspaceUITestSupport.fileTab(file, in: owner)
                XCTAssertTrue(tab.waitForExistence(timeout: 12))
                XCTAssertTrue(tab.isHittable, "The file tab must be visible inside its actual scroll viewport")
                tab.click()
                app.typeKey("w", modifierFlags: .command)
                XCTAssertTrue(tab.waitForNonExistence(timeout: 12),
                              "Command-W must close this exact file tab before the next close")
            }
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                owner.buttons.matching(identifier: "bailey.tab.file").count == 0
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 15), .completed,
                           "Closing all file tabs must retire the native documents")
            print("T5_APP_FILE_LIFETIME round=\(round) stage=closed tabs=0")
        }
        XCTAssertEqual(owner.buttons.matching(identifier: "bailey.tab.file").count, 0)
        XCTAssertEqual(app.windows.count, 1, "Five rounds must not leak native work windows")
        for file in files { XCTAssertEqual(try Data(contentsOf: file), expected) }
    }

    func testFinderNativeDropIntoWebKitUploadDoesNotOpenFileTab() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("upload/with space.txt", text: "native WebKit upload bytes\n")
        let initialBytes = try Data(contentsOf: file)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(file.deletingLastPathComponent(), to: app)
        let window = app.windows.firstMatch
        let newBrowser = app.menuItems["New Browser Tab"]
        XCTAssertTrue(newBrowser.waitForExistence(timeout: 10))
        newBrowser.click()
        let address = window.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 12))
        let html = """
            <html><head><title>Finder Native Upload</title></head>
            <body><h1>Finder file drop target</h1>
            <input id="upload" type="file" aria-label="P4T5 native file upload"
                   style="display:block;width:480px;height:120px;border:2px solid black">
            <p id="result">NO_FILE_SELECTED</p>
            <script>
              document.getElementById('upload').addEventListener('change', event => {
                document.getElementById('result').textContent =
                    'FINDER_UPLOAD_FILE: ' + (event.target.files[0]?.name || 'NONE');
              });
            </script></body></html>
            """
        address.click()
        address.typeKey("a", modifierFlags: .command)
        address.typeText("data:text/html;base64," + Data(html.utf8).base64EncodedString())
        address.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let browser = window.webViews.firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 20))
        XCTAssertTrue(browser.staticTexts["NO_FILE_SELECTED"].waitForExistence(timeout: 20))
        let upload = browser.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "P4T5 native file upload")).firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 15),
                      "WebKit file input must expose its native drag target: \(browser.debugDescription.prefix(2500))")

        let finder = finderDragSource(for: file)
        defer { closeFinderDragWindow(finder.window) }
        let target = upload.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        XCTAssertLessThan(finder.window.frame.maxX, target.screenPoint.x - 20,
                          "Finder must not obscure the real WKWebView file input")
        finder.source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.4, thenDragTo: target)
        XCTAssertTrue(browser.staticTexts["FINDER_UPLOAD_FILE: \(file.lastPathComponent)"]
            .waitForExistence(timeout: 20),
                      "The native HTML input must receive the actual Finder file URL")
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 0,
                       "WebKit must own file upload without Bailey creating a new editor")
        XCTAssertEqual(try Data(contentsOf: file), initialBytes)
    }

    func testFinderNativeDropIntoGhosttyPastesButDoesNotExecute() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("drag-source/with space.txt", text: "temporary finder source\n")
        let marker = fixture.root.appendingPathComponent("terminal-drop-marker.txt")
        let originalBytes = try Data(contentsOf: file)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(file.deletingLastPathComponent(), to: app)
        let window = app.windows.firstMatch
        app.typeKey("t", modifierFlags: .command)
        let terminal = window.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: 0.64))
        terminal.click()
        app.typeText("read -r DROP_LINE; printf '%s' \"$DROP_LINE\" > '\(marker.path)'")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        // Finder supplies the genuine system file URL drag. Its window is
        // moved into the left side so Bailey's receiving terminal remains
        // visible: a hidden target cannot be validated by AX coordinates.
        let finder = finderDragSource(for: file)
        defer { closeFinderDragWindow(finder.window) }
        XCTAssertLessThan(finder.window.frame.maxX, window.frame.midX + 70,
                          "Finder must not cover the native terminal drop target")
        finder.source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.4, thenDragTo: terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "A file drop must paste a Shell-escaped path without Return")
        app.activate()
        terminal.click()
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: marker.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 15), .completed,
                       "Return must execute the waiting Shell read after Finder drop")
        XCTAssertTrue(try String(contentsOf: marker, encoding: .utf8)
            .contains(file.lastPathComponent))
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 0,
                       "The terminal drop must not create a FileTab")
    }

    private func finderDragSource(for file: URL) -> (window: XCUIElement, source: XCUIElement) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        let window = finder.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        if !window.outlines["ListView"].waitForExistence(timeout: 2) {
            finder.activate()
            finder.typeKey("2", modifierFlags: .command)
        }
        XCTAssertTrue(window.outlines["ListView"].waitForExistence(timeout: 12),
                      "The selected Finder file must expose an actual draggable row")
        let title = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        title.click(forDuration: 0.2,
                    thenDragTo: title.withOffset(CGVector(dx: 40 - window.frame.minX, dy: 0)))
        let source = window.outlines["ListView"].outlineRows.firstMatch
            .textFields[file.lastPathComponent]
        XCTAssertTrue(source.waitForExistence(timeout: 12),
                      "The system drag must originate from the actual selected file")
        return (window, source)
    }

    private func closeFinderDragWindow(_ window: XCUIElement) {
        if window.exists { window.buttons["_XCUI:CloseWindow"].firstMatch.click() }
    }
}
