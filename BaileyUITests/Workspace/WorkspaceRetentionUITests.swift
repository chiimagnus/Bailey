import AppKit
import XCTest

@MainActor
final class WorkspaceRetentionUITests: XCTestCase {
    func testGitHostingSettingsStayInNativeSettingsWithoutExtraGraphToggles() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root
        )
        app.typeKey(",", modifierFlags: .command)
        let window = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let gitPage = window.staticTexts["Git Manager"].firstMatch
        XCTAssertTrue(gitPage.waitForExistence(timeout: 10))
        gitPage.click()

        XCTAssertTrue(window.staticTexts["Self-hosted Git Providers"].waitForExistence(timeout: 10))
        let hostRules = window.textViews["Custom Git hosting domains"]
        XCTAssertTrue(hostRules.waitForExistence(timeout: 10))
        XCTAssertFalse(window.staticTexts["Show stashes"].exists)
        XCTAssertFalse(window.staticTexts["Show tag labels"].exists)
        XCTAssertFalse(window.staticTexts["Show remote branch labels"].exists)
        XCTAssertFalse(window.staticTexts["Remote Fetch"].exists)

        hostRules.click()
        hostRules.typeText("git.example.com=gitlab")
        let apply = window.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        apply.click()
        let config = fixture.root.appendingPathComponent(".config/bailey-dev/config.toml")
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: config) else { return false }
            let text = String(decoding: data, as: UTF8.self)
            return text.contains("git.host-providers = [\"git.example.com=gitlab\"]")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLivePaletteChangeRepaintsDockWithoutPanelSwitch() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("workspace/theme-sample.txt", text: "Palette fixture\n")
        _ = try fixture.file(".config/bailey-dev/config.toml", text: """
            theme = "light"
            theme-light = "Ayu Light"
            theme-dark = "Adwaita Dark"
            toolbar.visibility = "always"
            """)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root,
            project: file.deletingLastPathComponent()
        )
        let main = app.windows.matching(identifier: "main-AppWindow-1").firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 12))
        let row = WorkspaceUITestSupport.fileRow(file, in: main)
        XCTAssertTrue(row.waitForExistence(timeout: 12))
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: main).waitForExistence(timeout: 12))

        func backgroundSamples() throws -> (projects: NSColor, editor: NSColor, sidePanel: NSColor, toolbar: NSColor) {
            let image = main.screenshot().image
            let data = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let scale = CGFloat(bitmap.pixelsWide) / main.frame.width
            func color(x: CGFloat, y: CGFloat = 250) throws -> NSColor {
                let pixel = try XCTUnwrap(bitmap.colorAt(
                    x: Int(x * scale), y: Int(y * scale)
                ))
                return try XCTUnwrap(pixel.usingColorSpace(.deviceRGB))
            }
            return try (color(x: 50), color(x: 340), color(x: 780),
                        color(x: 340, y: main.frame.height - 10))
        }

        func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent),
                abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent))
        }

        let before = try backgroundSamples()
        XCTAssertLessThan(difference(before.projects, before.editor), 0.012)
        XCTAssertLessThan(difference(before.toolbar, before.editor), 0.012)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(
            identifier: "com_apple_SwiftUI_Settings_window"
        ).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        // The native controls are PopUpButtons with values, not Buttons with labels.
        let palette = settings.popUpButtons.element(boundBy: 2)
        XCTAssertTrue(palette.waitForExistence(timeout: 12))
        let originalName = palette.value as? String ?? ""
        let targetName = originalName == "Ayu Light" ? "Apple System Colors Light" : "Ayu Light"
        palette.click()
        let choice = palette.menuItems[targetName]
        XCTAssertTrue(choice.waitForExistence(timeout: 12))
        choice.click()
        XCTAssertEqual(palette.value as? String, targetName)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 10),
                      "Close Settings before sampling the unobscured main window")

        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let sample = try? backgroundSamples() else { return false }
            return difference(before.editor, sample.editor) > 0.015
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed,
                       "Editor must show the newly selected palette")
        let after = try backgroundSamples()
        XCTAssertLessThan(difference(after.projects, after.editor), 0.012,
                          "Projects background must update without a Dock switch or resize")
        XCTAssertLessThan(difference(after.sidePanel, after.editor), 0.012,
                          "Files and the editor must use the same custom palette backdrop")
        XCTAssertLessThan(difference(after.toolbar, after.editor), 0.012,
                          "Bottom toolbar must repaint with the selected palette")

        let gitPanel = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(gitPanel.waitForExistence(timeout: 12))
        gitPanel.click()
        let gitBackgrounds = try backgroundSamples()
        XCTAssertLessThan(difference(gitBackgrounds.sidePanel, gitBackgrounds.editor), 0.012,
                          "Git must use the custom palette before changing appearance")

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        let dark = settings.descendants(matching: .tab)["Dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 12))
        dark.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 10))
        let darkBackgrounds = try backgroundSamples()
        XCTAssertGreaterThan(difference(after.editor, darkBackgrounds.editor), 0.1)
        XCTAssertLessThan(difference(darkBackgrounds.projects, darkBackgrounds.editor), 0.012,
                          "Projects must adopt the custom dark palette without remounting")
        XCTAssertLessThan(difference(darkBackgrounds.sidePanel, darkBackgrounds.editor), 0.012,
                          "Git background must repaint with the custom dark theme")
        XCTAssertLessThan(difference(darkBackgrounds.toolbar, darkBackgrounds.editor), 0.012)

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        let light = settings.descendants(matching: .tab)["Light"].firstMatch
        XCTAssertTrue(light.waitForExistence(timeout: 12))
        light.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 10))
        let restoredLight = try backgroundSamples()
        XCTAssertLessThan(difference(restoredLight.projects, restoredLight.editor), 0.012)
        XCTAssertLessThan(difference(restoredLight.sidePanel, restoredLight.editor), 0.012)
        XCTAssertLessThan(difference(restoredLight.toolbar, restoredLight.editor), 0.012)
        XCTAssertLessThan(difference(restoredLight.editor, after.editor), 0.012,
                          "Light appearance must restore the previously selected light palette")
    }

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
        let settingsWindow = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 12))
        let dark: XCUIElement
        if #available(macOS 27.0, *) {
            dark = settingsWindow.descendants(matching: .tab)["Dark"].firstMatch
        } else {
            dark = settingsWindow.radioButtons["Dark"].firstMatch
        }
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
                       "The native appearance control must reflect the selected theme")

        app.terminate()
        app.launch()
        app.activate()
        let mainWindow = app.windows.matching(identifier: "main-AppWindow-1").firstMatch
        if !mainWindow.waitForExistence(timeout: 4) {
            let newWindow = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["New Window", "新建窗口"])).firstMatch
            XCTAssertTrue(newWindow.waitForExistence(timeout: 10))
            newWindow.click()
        }
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15))
        // Reopen through the native menu after Xcode's synthetic no-window relaunch.
        let openSettings = app.menuItems.matching(NSPredicate(
            format: "title CONTAINS[c] %@", "Settings")).firstMatch
        XCTAssertTrue(openSettings.waitForExistence(timeout: 12))
        openSettings.click()
        let restoredWindow = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(restoredWindow.waitForExistence(timeout: 12),
                      "The native Settings menu must reopen the saved appearance after relaunch")
        let restoredDark: XCUIElement
        if #available(macOS 27.0, *) {
            restoredDark = restoredWindow.descendants(matching: .tab)["Dark"].firstMatch
        } else {
            restoredDark = restoredWindow.radioButtons["Dark"].firstMatch
        }
        XCTAssertTrue(restoredDark.waitForExistence(timeout: 12))
        XCTAssertEqual(String(describing: restoredDark.value ?? ""), "1",
                       "Restart must restore the selected theme in native Settings")
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8)
            .contains("theme = \"dark\""))
        app.typeKey("w", modifierFlags: .command)
        let closedSettings = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 1"), object: app.windows
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closedSettings], timeout: 10), .completed,
                       "Command-W must close only the native Settings window")
        XCTAssertTrue(app.buttons["bailey.emptyState.addFolder"].exists,
                      "Closing Settings must preserve the original workspace window")
    }

    func testNormalQuitVetoesFailedSaveThenWritesAndRestoresSession() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("quit/unsaved.swift", text: "let original = 1\n")
        let folder = file.deletingLastPathComponent()
        let original = try Data(contentsOf: file)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root,
            project: folder
        )
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

    func testBrowserAddressFocusSurvivesPaletteAndRepeatedCommandL() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("browser/untouched.txt", text: "saved bytes\n")
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: file.deletingLastPathComponent()
        )
        let window = app.windows.firstMatch
        let newBrowser = app.menuItems["New Browser Tab"]
        XCTAssertTrue(newBrowser.waitForExistence(timeout: 10))
        newBrowser.click()
        let address = window.textFields["Search or enter website name"]
        XCTAssertTrue(address.waitForExistence(timeout: 15))

        app.typeKey("l", modifierFlags: .command)
        app.typeText("first focus marker")
        XCTAssertEqual(address.value as? String, "first focus marker",
                       "The real address input must own Command-L keyboard events")

        app.typeKey("p", modifierFlags: .command)
        let palette = window.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(palette.waitForExistence(timeout: 10))
        palette.typeText("unmatched palette query")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(palette.waitForNonExistence(timeout: 10))

        app.typeKey("l", modifierFlags: .command)
        app.typeText("second focus marker")
        XCTAssertEqual(address.value as? String, "second focus marker",
                       "Repeating Command-L after a palette handoff must select the whole address")
        XCTAssertEqual(try Data(contentsOf: file), Data("saved bytes\n".utf8))
    }

    func testRealBrowserKeepsWebContentAcrossFileTabSwitches() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("project/neighbor.swift", text: "let untouched = true\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: file.deletingLastPathComponent())
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
        XCTAssertTrue(window.frame.contains(CGPoint(x: browserTab.frame.midX,
                                                  y: browserTab.frame.midY)),
                      "The browser tab must be visible within its owning window")
        browserTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
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
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: file.deletingLastPathComponent())
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

    func testFinderNativeDropIntoWebKitUploadDoesNotOpenFileTab() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("upload/with space.txt", text: "native WebKit upload bytes\n")
        let initialBytes = try Data(contentsOf: file)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: file.deletingLastPathComponent())
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

        let finder = WorkspaceUITestSupport.finderDragSource(for: file)
        defer { WorkspaceUITestSupport.closeFinderDragWindow(finder.window) }
        // Keep the actual WebKit drop point outside the Finder source window.
        let target = upload.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
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
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: file.deletingLastPathComponent())
        let window = app.windows.firstMatch
        app.typeKey("t", modifierFlags: .command)
        let terminal = window.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: 0.64))
        terminal.click()
        app.typeText("read -r DROP_LINE; printf '%s' \"$DROP_LINE\" > '\(marker.path)'")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        // Finder supplies the genuine system file URL drag. Its window is
        // moved into the left side so Bailey's receiving terminal remains
        // visible: a hidden target cannot be validated by AX coordinates.
        let finder = WorkspaceUITestSupport.finderDragSource(for: file)
        defer { WorkspaceUITestSupport.closeFinderDragWindow(finder.window) }
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
}
