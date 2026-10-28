import AppKit
import XCTest

@MainActor
final class WorkspaceFilesUITests: XCTestCase {
    func testRealSettingsExcludeAndFileTabRevealHiddenRow() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let hidden = try fixture.file("workspace/node_modules/hidden.swift", text: "real hidden editor bytes\n")
        _ = try fixture.file("workspace/visible.swift", text: "visible\n")
        let workspace = fixture.root.appendingPathComponent("workspace", isDirectory: true)
        let config = fixture.root.appendingPathComponent(".config/bailey-dev/config.toml")
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root,
            project: workspace
        )
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let folder = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label == %@", "node_modules")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 20))
        folder.click()
        let hiddenRow = WorkspaceUITestSupport.fileRow(hidden, in: window)
        XCTAssertTrue(hiddenRow.waitForExistence(timeout: 15))
        hiddenRow.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(hidden, in: window)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))

        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 12))
        let fileManagerPage = settingsWindow.staticTexts.matching(
            NSPredicate(format: "value == %@", "File Manager")
        ).firstMatch
        XCTAssertTrue(fileManagerPage.waitForExistence(timeout: 12))
        fileManagerPage.click()
        let excluded = settingsWindow.textViews["Excluded file patterns"].firstMatch
        XCTAssertTrue(excluded.waitForExistence(timeout: 12),
                      "The native File Manager Settings page must expose a real pattern editor")
        excluded.click()
        excluded.typeKey("a", modifierFlags: .command)
        excluded.typeText("**/.git\n**/node_modules")
        settingsWindow.buttons["Apply"].click()
        let persisted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (try? String(contentsOf: config, encoding: .utf8))?
                    .contains("**/node_modules") == true
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 10), .completed,
                       "Applying the native Exclude editor must write real isolated TOML")

        excluded.click()
        excluded.typeKey("a", modifierFlags: .command)
        excluded.typeText("../invalid")
        settingsWindow.buttons["Apply"].click()
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("**/node_modules"),
                      "Invalid patterns must preserve the last valid saved configuration")

        app.typeKey("w", modifierFlags: .command)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: folder
        )
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 12), .completed,
                       "Files must apply the settings to the existing visible tree")

        tab.rightClick()
        let reveal = app.menuItems["Reveal in File Manager"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 8))
        XCTAssertTrue(app.menuItems["Reveal in Finder"].exists,
                      "The same local file must retain its native Finder action")
        reveal.click()
        XCTAssertTrue(hiddenRow.waitForExistence(timeout: 15),
                      "Reveal must expand the excluded ancestor and scroll to the real row")
        XCTAssertTrue(hiddenRow.isSelected, "Reveal must select the actual hidden file row")
        XCTAssertEqual(try String(contentsOf: hidden, encoding: .utf8),
                       "real hidden editor bytes\n")

        let menu = WorkspaceUITestSupport.element("bailey.files.showExcludedMenu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.click()
        let showExcluded = app.menuItems["Show Excluded Files"]
        XCTAssertTrue(showExcluded.waitForExistence(timeout: 8))
        showExcluded.click()
        let hiddenAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: folder
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenAgain], timeout: 10), .completed,
                       "Turning off temporary visibility must restore saved Exclude rules")
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("**/node_modules"),
                      "Temporary visibility must not write configuration")

        app.typeKey(",", modifierFlags: .command)
        let restoredSettings = app.windows["com_apple_SwiftUI_Settings_window"]
        let restoredFileManager = restoredSettings.staticTexts.matching(
            NSPredicate(format: "value == %@", "File Manager")
        ).firstMatch
        XCTAssertTrue(restoredFileManager.waitForExistence(timeout: 10))
        restoredFileManager.click()
        restoredSettings.buttons["Restore Default Exclusions"].click()
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
                return !text.contains("files.exclude")
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 12), .completed,
                       "Restoring the default must omit files.exclude so the default .git rule applies")
        app.typeKey("w", modifierFlags: .command)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        XCTAssertTrue(folder.waitForExistence(timeout: 12))
        XCTAssertEqual(try String(contentsOf: hidden, encoding: .utf8),
                       "real hidden editor bytes\n")
    }

    func testAuthorizedWindowsSSHExternalFilesRefreshInRealApp() throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"],
              !host.isEmpty, !host.hasPrefix("-"),
              !host.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw XCTSkip("Requires an explicitly authorized isolated Windows SSH host")
        }
        let remoteRoot = try runSSH(
            host: host, command: "mktemp -d /tmp/bailey-p2-ui-XXXXXX"
        ).trimmingCharacters(in: .newlines)
        guard (remoteRoot as NSString).deletingLastPathComponent == "/tmp",
              (remoteRoot as NSString).lastPathComponent.hasPrefix("bailey-p2-ui-") else {
            throw NSError(domain: "BaileyP2UI", code: 1)
        }
        addTeardownBlock { @MainActor in
            XCTAssertEqual(try self.runSSH(host: host,
                command: "rm -r -- '\(remoteRoot)' && test ! -e '\(remoteRoot)' && printf cleaned"),
                "cleaned", "Only this SSH GUI test directory may be deleted")
        }
        let fixture = try WorkspaceUITestFixture(in: self)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root
        )
        app.menuBarItems["Project"].click()
        let add = app.menuItems["Add SSH Files or Projects…"]
        XCTAssertTrue(add.waitForExistence(timeout: 12))
        add.click()
        let window = app.windows.firstMatch
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 12))
        let hostField = sheet.comboBoxes.firstMatch
        let paths = sheet.textViews.firstMatch
        XCTAssertTrue(hostField.waitForExistence(timeout: 12))
        XCTAssertTrue(paths.waitForExistence(timeout: 12))
        hostField.click()
        hostField.typeKey("a", modifierFlags: .command)
        hostField.typeText(host)
        paths.click()
        paths.typeText(remoteRoot)
        sheet.buttons["Add"].click()

        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 25))
        files.click()
        let created = remoteRoot + "/external-中文.txt"
        let renamed = remoteRoot + "/renamed-中文.txt"
        XCTAssertEqual(try runSSH(host: host,
            command: "printf 'REMOTE_P2_CONTENT\\n' > '\(created)' && printf made"), "made")
        let createdRow = WorkspaceUITestSupport.fileRow(URL(fileURLWithPath: created), in: window)
        XCTAssertTrue(createdRow.waitForExistence(timeout: 25),
                      "Remote independent CLI create must appear without UI Refresh")
        XCTAssertEqual(try runSSH(host: host,
            command: "mv -- '\(created)' '\(renamed)' && printf moved"), "moved")
        let renamedRow = WorkspaceUITestSupport.fileRow(URL(fileURLWithPath: renamed), in: window)
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 25))
        XCTAssertTrue(createdRow.waitForNonExistence(timeout: 15))
        XCTAssertEqual(try runSSH(host: host,
            command: "rm -- '\(renamed)' && printf removed"), "removed")
        XCTAssertTrue(renamedRow.waitForNonExistence(timeout: 20))

        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(git.waitForExistence(timeout: 15))
        git.click()
        let hidden = remoteRoot + "/while-hidden.txt"
        XCTAssertEqual(try runSSH(host: host,
            command: "printf 'HIDDEN_REMOTE_BYTES\\n' > '\(hidden)' && printf made"), "made")
        files.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileRow(
            URL(fileURLWithPath: hidden), in: window
        ).waitForExistence(timeout: 25), "Reopening Files must reconcile missed remote changes")
        XCTAssertEqual(try runSSH(host: host, command: "cat '\(hidden)'"),
                       "HIDDEN_REMOTE_BYTES\n")
    }

    func testAuthorizedWindowsSSHRejectsRealFinderDropWithoutAffectingLocalCopy() throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"],
              !host.isEmpty, !host.hasPrefix("-"),
              !host.contains(where: { $0.isWhitespace || $0.isNewline })
        else { throw XCTSkip("Requires an explicitly authorized Windows SSH host") }

        let remoteRoot = try runSSH(
            host: host, command: "mktemp -d /tmp/bailey-p2-ui-XXXXXX"
        ).trimmingCharacters(in: .newlines)
        guard (remoteRoot as NSString).deletingLastPathComponent == "/tmp",
              (remoteRoot as NSString).lastPathComponent.hasPrefix("bailey-p2-ui-")
        else { throw NSError(domain: "BaileyP2UI", code: 3) }
        addTeardownBlock { @MainActor in
            XCTAssertEqual(try self.runSSH(host: host,
                command: "rm -r -- '\(remoteRoot)' && test ! -e '\(remoteRoot)' && printf cleaned"),
                "cleaned", "Only the isolated remote test directory may be deleted")
        }
        XCTAssertEqual(try runSSH(host: host, command:
            "mkdir -p -- '\(remoteRoot)/drop-zone' && "
            + "printf 'REMOTE_UNCHANGED\n' > '\(remoteRoot)/drop-zone/protected.txt' && printf ready"),
            "ready")

        let fixture = try WorkspaceUITestFixture(in: self)
        let source = try fixture.file(
            "finder-source/local-only.txt", text: "MAC_FINDER_SOURCE_UNIQUE_BYTES\n"
        )
        let localAnchor = try fixture.file(
            "local-workspace/drop-zone/existing.txt", text: "LOCAL_DESTINATION_ANCHOR\n"
        )
        let localWorkspace = fixture.root.appendingPathComponent("local-workspace")
        let copied = localWorkspace.appendingPathComponent("drop-zone/local-only.txt")
        let sourceBytes = try Data(contentsOf: source)

        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root
        )
        app.menuBarItems["Project"].click()
        let addSSH = app.menuItems["Add SSH Files or Projects…"]
        XCTAssertTrue(addSSH.waitForExistence(timeout: 12))
        addSSH.click()
        let remoteWindow = app.windows.firstMatch
        let sheet = remoteWindow.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 12))
        let hostField = sheet.comboBoxes.firstMatch
        hostField.click()
        hostField.typeKey("a", modifierFlags: .command)
        hostField.typeText(host)
        let paths = sheet.textViews.firstMatch
        paths.click()
        paths.typeText(remoteRoot)
        sheet.buttons["Add"].click()

        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 25))
        files.click()
        let remoteFolder = remoteWindow.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label CONTAINS %@", "drop-zone"))
            .firstMatch
        XCTAssertTrue(remoteFolder.waitForExistence(timeout: 25))
        let finder = WorkspaceUITestSupport.finderDragSource(for: source)
        defer { WorkspaceUITestSupport.closeFinderDragWindow(finder.window) }
        let remotePoint = remoteFolder.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        XCTAssertLessThan(finder.window.frame.maxX, remotePoint.screenPoint.x - 20,
                          "Finder must not obscure the real SSH Files destination")
        finder.source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.4, thenDragTo: remotePoint)

        XCTAssertEqual(try runSSH(host: host, command:
            "test ! -e '\(remoteRoot)/drop-zone/local-only.txt' && "
            + "cat '\(remoteRoot)/drop-zone/protected.txt'"),
            "REMOTE_UNCHANGED\n", "Finder must not upload a Mac file into Windows Files")
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        // The same genuine Finder fileURL must be accepted by local Files;
        // otherwise a missed drag could falsely make the SSH rejection pass.
        app.activate()
        app.typeKey("n", modifierFlags: [.command, .shift])
        let emptyWindow = try XCTUnwrap(app.windows.allElementsBoundByIndex.first {
            $0.buttons["bailey.emptyState.addFolder"].exists
        })
        let localWindow = app.windows.matching(identifier: emptyWindow.identifier).firstMatch
        try WorkspaceUITestSupport.addFolder(localWorkspace, to: app, in: localWindow)
        let localFiles = localWindow.descendants(matching: .any)
            .matching(identifier: "bailey.dock.files").firstMatch
        XCTAssertTrue(localFiles.waitForExistence(timeout: 15))
        localFiles.click()
        let localFolder = localWindow.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label CONTAINS %@", "drop-zone"))
            .firstMatch
        XCTAssertTrue(localFolder.waitForExistence(timeout: 20))
        let localPoint = localFolder.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        XCTAssertLessThan(finder.window.frame.maxX, localPoint.screenPoint.x - 20)
        finder.source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.4, thenDragTo: localPoint)

        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: copied.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 20), .completed,
                       "The same Finder drag must actually copy into local Files")
        XCTAssertEqual(try Data(contentsOf: copied), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try String(contentsOf: localAnchor, encoding: .utf8),
                       "LOCAL_DESTINATION_ANCHOR\n")
        XCTAssertEqual(try runSSH(host: host, command:
            "test ! -e '\(remoteRoot)/drop-zone/local-only.txt' && "
            + "cat '\(remoteRoot)/drop-zone/protected.txt'"), "REMOTE_UNCHANGED\n")
    }

    func testAuthorizedWindowsSSHCommandPaletteOpensRealRemoteFiles() throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P3_TEST_SSH_HOST"],
              !host.isEmpty else {
            throw XCTSkip("Set BAILEY_P3_TEST_SSH_HOST for the isolated Windows SSH E2E")
        }
        let remoteRoot = try runSSH(
            host: host, command: "mktemp -d /tmp/bailey-p3-ui-XXXXXX"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (remoteRoot as NSString).deletingLastPathComponent == "/tmp",
              (remoteRoot as NSString).lastPathComponent.hasPrefix("bailey-p3-ui-") else {
            throw NSError(domain: "BaileyP3E2E", code: 1)
        }
        addTeardownBlock { @MainActor in
            XCTAssertEqual(try self.runSSH(host: host,
                command: "rm -r -- '\(remoteRoot)' && test ! -e '\(remoteRoot)' && printf cleaned"),
                "cleaned", "Only the dedicated remote test directory may be deleted")
        }

        let gitRoot = remoteRoot + "/git"
        let plainRoot = remoteRoot + "/plain"
        let gitFile = gitRoot + "/p3-git-中文.swift"
        let plainFile = plainRoot + "/p3-plain-中文.swift"
        _ = try runSSH(host: host, command:
            "mkdir -p -- '\(gitRoot)' '\(plainRoot)' && "
            + "git -C '\(gitRoot)' init -q -b main && "
            + "printf 'WINDOWS_GIT_UNIQUE_BYTES\\n' > '\(gitFile)' && "
            + "printf 'WINDOWS_UNTRACKED\\n' > '\(gitRoot)/p3-new.swift' && "
            + "printf '*.log\\n' > '\(gitRoot)/.gitignore' && "
            + "printf 'WINDOWS_IGNORED\\n' > '\(gitRoot)/p3-ignored.log' && "
            + "git -C '\(gitRoot)' add -- 'p3-git-中文.swift' '.gitignore' && "
            + "printf 'WINDOWS_PLAIN_UNIQUE_BYTES\\n' > '\(plainFile)'")
        XCTAssertEqual(try runSSH(host: host, command: "cat '\(gitFile)'"),
                       "WINDOWS_GIT_UNIQUE_BYTES\n")
        XCTAssertEqual(try runSSH(host: host, command: "cat '\(plainFile)'"),
                       "WINDOWS_PLAIN_UNIQUE_BYTES\n")

        // A same-named local file must remain untouched by remote lookup.
        // UI tests may only write inside their sandboxed temporary fixture.
        let fixture = try WorkspaceUITestFixture(in: self)
        let localTwin = try fixture.file("p3-git-中文.swift", text: "MAC_WRONG_MACHINE_BYTES\n")
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root
        )
        func addSSH(_ remoteFolder: String) {
            app.menuBarItems["Project"].click()
            let add = app.menuItems["Add SSH Files or Projects…"]
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            add.click()
            let sheet = app.windows.firstMatch.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            let hostField = sheet.comboBoxes.firstMatch
            let paths = sheet.textViews.firstMatch
            XCTAssertTrue(hostField.waitForExistence(timeout: 10))
            XCTAssertTrue(paths.waitForExistence(timeout: 10))
            hostField.click()
            hostField.typeKey("a", modifierFlags: .command)
            hostField.typeText(host)
            paths.click()
            paths.typeText(remoteFolder)
            sheet.buttons["Add"].click()
        }
        func quickOpen(_ name: String, at path: String, content: String) {
            app.typeKey("p", modifierFlags: .command)
            let search = app.textFields["bailey.commandPalette.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.typeText(name)
            let result = app.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] %@", name
            )).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 30),
                          "The real Windows SSH index must produce a selectable result")
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            let tab = WorkspaceUITestSupport.fileTab(
                URL(fileURLWithPath: path), in: app.windows.firstMatch
            )
            XCTAssertTrue(tab.waitForExistence(timeout: 25),
                          "Return must open the remote FileTab with its exact path")
            let editor = app.textViews.firstMatch
            let loaded = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", content), object: editor
            )
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed,
                           "The opened editor must contain real Windows bytes")
        }

        addSSH(gitRoot)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 25))
        files.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileRow(
            URL(fileURLWithPath: gitFile), in: app.windows.firstMatch
        ).waitForExistence(timeout: 25))
        quickOpen("p3-git", at: gitFile, content: "WINDOWS_GIT_UNIQUE_BYTES\n")
        XCTAssertEqual(try String(contentsOf: localTwin, encoding: .utf8),
                       "MAC_WRONG_MACHINE_BYTES\n")
        let gitTab = WorkspaceUITestSupport.fileTab(
            URL(fileURLWithPath: gitFile), in: app.windows.firstMatch
        )
        gitTab.rightClick()
        let reveal = app.menuItems["Reveal in File Manager"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 10))
        XCTAssertFalse(app.menuItems["Reveal in Finder"].exists,
                       "Remote file tabs may not ask Finder to reveal the same Mac path")
        reveal.click()
        let gitRow = WorkspaceUITestSupport.fileRow(
            URL(fileURLWithPath: gitFile), in: app.windows.firstMatch
        )
        XCTAssertTrue(gitRow.waitForExistence(timeout: 20))
        let revealedSelection = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == YES"), object: gitRow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [revealedSelection], timeout: 12), .completed,
                       "Remote reveal must select its own machine's row")

        if ProcessInfo.processInfo.environment["BAILEY_P3_EXTERNAL_DISCONNECT"] == "1" {
            // XCTest cannot access another App process's SSH socket (EPERM).
            // The authorized Mac-side test invocation closes only this Dev PID's master.
            let devApplications = NSRunningApplication.runningApplications(
                withBundleIdentifier: "chiimagnus.bailey.dev"
            )
            XCTAssertEqual(devApplications.count, 1)
            let devPID = try XCTUnwrap(devApplications.first?.processIdentifier)
            let ready = fixture.root.appendingPathComponent("p3-disconnect.ready")
            let completed = fixture.root.appendingPathComponent("p3-disconnect.done")
            try "\(devPID)\n".write(to: ready, atomically: true, encoding: .utf8)
            NSLog("P3_DISCONNECT_READY_PATH=%@", ready.path)
            let disconnected = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    FileManager.default.fileExists(atPath: completed.path)
                }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [disconnected], timeout: 60), .completed,
                           "The Mac-side controller must close only this test Dev SSH master")
            XCTAssertEqual(try String(contentsOf: completed, encoding: .utf8), "master-closed\n")
            _ = try runSSH(host: host, command:
                "printf 'WINDOWS_AFTER_RECONNECT\\n' > '\(gitRoot)/p3-new.swift'")
            let localOther = try fixture.file(
                "p3-new.swift", text: "MAC_UNTRACKED_DIFFERENT_BYTES\n"
            )
            quickOpen("p3-new", at: gitRoot + "/p3-new.swift",
                      content: "WINDOWS_AFTER_RECONNECT\n")
            XCTAssertTrue(gitTab.exists, "Reconnecting must keep the original Windows file tab")
            gitTab.click()
            let originalEditor = app.textViews.firstMatch
            let originalContent = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "WINDOWS_GIT_UNIQUE_BYTES\n"),
                object: originalEditor
            )
            XCTAssertEqual(XCTWaiter.wait(for: [originalContent], timeout: 20), .completed)
            XCTAssertEqual(try String(contentsOf: localOther, encoding: .utf8),
                           "MAC_UNTRACKED_DIFFERENT_BYTES\n")
            XCTAssertEqual(try String(contentsOf: localTwin, encoding: .utf8),
                           "MAC_WRONG_MACHINE_BYTES\n")
        }

        addSSH(plainRoot)
        files.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileRow(
            URL(fileURLWithPath: plainFile), in: app.windows.firstMatch
        ).waitForExistence(timeout: 25), "Switching projects must show the new remote root")
        quickOpen("p3-plain", at: plainFile, content: "WINDOWS_PLAIN_UNIQUE_BYTES\n")
        XCTAssertEqual(try String(contentsOf: localTwin, encoding: .utf8),
                       "MAC_WRONG_MACHINE_BYTES\n")
    }

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

    func testRapidCommandWCloseAllThenFilesCanOpenAnotherFile() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let files = try (0..<6).map { index in
            try fixture.file("rapid-\(index).swift", text: "let rapid = \(index)\n")
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let filesTab = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(filesTab.waitForExistence(timeout: 20))

        for path in files {
            filesTab.click()
            let row = WorkspaceUITestSupport.fileRow(path, in: app.windows.firstMatch)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
            XCTAssertTrue(WorkspaceUITestSupport.fileTab(path, in: app.windows.firstMatch)
                .waitForExistence(timeout: 15))
        }

        for _ in files { app.typeKey("w", modifierFlags: .command) }
        XCTAssertTrue(files.allSatisfy {
            !WorkspaceUITestSupport.fileTab($0, in: app.windows.firstMatch).exists
        }, "Command-W must close all work tabs before the Files click")

        let currentFilesTab = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(currentFilesTab.waitForExistence(timeout: 15))
        currentFilesTab.click()
        let first = try XCTUnwrap(files.first)
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: app.windows.firstMatch)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))
        firstRow.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(first, in: app.windows.firstMatch)
            .waitForExistence(timeout: 15),
            "Files must actually open a new tab after the last work tab is closed")
        XCTAssertEqual(app.windows.firstMatch.textViews.firstMatch.value as? String, "let rapid = 0\n")
    }

    func testFileManagerClipboardCopyCutPasteAndTrashAgainstRealDisk() throws {
        let volume = ProcessInfo.processInfo.environment["BAILEY_P2_TEST_TRASH_VOLUME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let fixture = try WorkspaceUITestFixture(in: self, baseDirectory: volume)
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
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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

    func testSystemEditMenuCopyPasteFollowsFileManagerFocus() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = try fixture.file("alpha.txt", text: "menu copy bytes\n")
        let duplicate = fixture.root.appendingPathComponent("alpha copy.txt")
        let originalClipboard = try WorkspaceUITestSupport.clipboardItems()
        defer {
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            if !originalClipboard.isEmpty { XCTAssertTrue(clipboard.writeObjects(originalClipboard)) }
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let sourceRow = WorkspaceUITestSupport.fileRow(source, in: window)
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 15))
        sourceRow.click()

        app.menuBarItems["Edit"].click()
        let copy = app.menuItems["Copy"]
        XCTAssertTrue(copy.isEnabled)
        copy.click()
        let fileClipboard = NSPasteboard.PasteboardType("com.chiimagnus.bailey.files.transfer")
        XCTAssertNotNil(NSPasteboard.general.data(forType: fileClipboard))

        app.menuBarItems["Edit"].click()
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.isEnabled)
        paste.click()
        let copied = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: duplicate.path) },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 15), .completed)
        XCTAssertEqual(try Data(contentsOf: duplicate), Data("menu copy bytes\n".utf8))

        sourceRow.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        app.menuBarItems["Edit"].click()
        app.menuItems["Copy"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "menu copy bytes\n")
        XCTAssertNil(NSPasteboard.general.data(forType: fileClipboard))
    }

    func testEditDeleteBackspaceShortcutUsesFocusedFileTree() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let doomed = try fixture.file("delete-with-backspace.txt", text: "remove me")
        let survivor = try fixture.file("keep-with-backspace.txt", text: "keep me")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let row = WorkspaceUITestSupport.fileRow(doomed, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()

        app.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Delete"].isEnabled)
        row.click()
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])

        let deleted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !FileManager.default.fileExists(atPath: doomed.path)
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 15), .completed)
        XCTAssertEqual(try Data(contentsOf: survivor), Data("keep me".utf8))
    }

    func testTerminalFocusedRightClickPreservesFilesSelectionAndInput() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let selectedFile = try fixture.file("a-selected.txt", text: "selected\n")
        let contextFile = try fixture.file("b-context.txt", text: "context\n")
        let marker = fixture.root.appendingPathComponent("terminal-input.txt")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileRow(selectedFile, in: window)
        let b = WorkspaceUITestSupport.fileRow(contextFile, in: window)
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        a.click()

        app.typeKey("t", modifierFlags: .command)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.6)).click()
        b.rightClick()
        XCTAssertTrue(a.isSelected && !b.isSelected,
                      "Context-click B must not mutate the existing A selection")
        XCTAssertTrue(app.menus.allElementsBoundByIndex.contains {
            $0.menuItems["Copy Relative Path"].exists
        }, "Files should display its context menu while Terminal owns input")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        app.typeText("printf terminal > '\(marker.path)'")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: marker.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 12), .completed,
                       "Closing the Files menu must preserve Terminal keyboard input")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "terminal")
    }

    func testControlClickKeepsNativeFilesContextMenuAndSingleTarget() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("first.txt", text: "first bytes\n")
        let second = try fixture.file("second.txt", text: "second bytes\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileRow(first, in: window)
        let b = WorkspaceUITestSupport.fileRow(second, in: window)
        if !a.isHittable {
            let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
            XCTAssertTrue(files.waitForExistence(timeout: 15))
            files.click()
        }
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        a.click()
        XCUIElement.perform(withKeyModifiers: .control) { b.click() }
        let menu = try XCTUnwrap(app.menus.allElementsBoundByIndex.first {
            $0.menuItems["Copy Relative Path"].exists
        }, "Control-click must open the clicked Files row's native context menu")
        XCTAssertTrue(a.isSelected)
        XCTAssertFalse(b.isSelected)
        menu.menuItems["Copy Path"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), second.path)
        XCTAssertEqual(try Data(contentsOf: first), Data("first bytes\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second bytes\n".utf8))
    }

    func testNativeDragCompressedFolderSegmentMovesItsRealAncestor() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let leaf = try fixture.file("a1/b1/c1/leaf.swift", text: "original leaf bytes\n")
        let marker = try fixture.file("target/.keep", text: "keep target\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let folder = { (name: String) in
            window.descendants(matching: .any)
                .matching(identifier: "bailey.tree.folder")
                .matching(NSPredicate(format: "label == %@", name)).firstMatch
        }
        if !folder("a1").isHittable {
            WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        }
        for name in ["a1", "b1", "c1"] {
            let row = folder(name)
            XCTAssertTrue(row.waitForExistence(timeout: 15), "Folder \(name) must be revealed")
            row.click()
        }
        let compact = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label CONTAINS %@", "a1 / b1")).firstMatch
        XCTAssertTrue(compact.waitForExistence(timeout: 15))
        let ancestor = compact.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder.component.0").firstMatch
        let destination = folder("target")
        XCTAssertTrue(ancestor.waitForExistence(timeout: 15))
        XCTAssertTrue(destination.waitForExistence(timeout: 15))
        ancestor.click(forDuration: 0.2, thenDragTo: destination)
        let moved = fixture.root.appendingPathComponent("target/a1/b1/c1/leaf.swift")
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: moved.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaf.path),
                       "Dragging compact ancestor a1 must move the whole a1 tree, not only c1")
        XCTAssertEqual(try Data(contentsOf: moved), Data("original leaf bytes\n".utf8))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep target\n".utf8))
    }

    func testNativeDragOptionCopiesSelectionAndUnselectedRowMovesOnlyItself() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("a.txt", text: "alpha original\n")
        let beta = try fixture.file("b.txt", text: "beta original\n")
        let gamma = try fixture.file("c.txt", text: "gamma original\n")
        let copyFolder = try fixture.file("target/.keep", text: "").deletingLastPathComponent()
        let moveFolder = try fixture.file("moved/.keep", text: "").deletingLastPathComponent()
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileRow(alpha, in: window)
        let b = WorkspaceUITestSupport.fileRow(beta, in: window)
        let c = WorkspaceUITestSupport.fileRow(gamma, in: window)
        let target = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label == %@", "target")).firstMatch
        let moved = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label == %@", "moved")).firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        XCTAssertTrue(c.waitForExistence(timeout: 15))
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        XCTAssertTrue(moved.waitForExistence(timeout: 15))
        a.click()
        XCUIElement.perform(withKeyModifiers: .command) { c.click() }
        XCTAssertTrue(a.isSelected && c.isSelected && !b.isSelected)
        XCUIElement.perform(withKeyModifiers: .option) {
            a.click(forDuration: 0.2, thenDragTo: target)
        }
        let copiedA = copyFolder.appendingPathComponent("a.txt")
        let copiedC = copyFolder.appendingPathComponent("c.txt")
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: copiedA.path)
                && FileManager.default.fileExists(atPath: copiedC.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 15), .completed)
        XCTAssertEqual(try Data(contentsOf: copiedA), Data("alpha original\n".utf8))
        XCTAssertEqual(try Data(contentsOf: copiedC), Data("gamma original\n".utf8))
        XCTAssertEqual(try Data(contentsOf: alpha), Data("alpha original\n".utf8))
        XCTAssertEqual(try Data(contentsOf: gamma), Data("gamma original\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyFolder.appendingPathComponent("b.txt").path))

        b.click(forDuration: 0.2, thenDragTo: moved)
        let movedB = moveFolder.appendingPathComponent("b.txt")
        let movedOnlyB = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: movedB.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [movedOnlyB], timeout: 15), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: beta.path))
        XCTAssertEqual(try Data(contentsOf: movedB), Data("beta original\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moveFolder.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moveFolder.appendingPathComponent("c.txt").path))
    }

    func testNativeMultiFileDragMovesOnlySelectedFilesAndPreservesBytes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("a.txt", text: "alpha original\n")
        let beta = try fixture.file("b.txt", text: "beta original\n")
        let gamma = try fixture.file("c.txt", text: "gamma original\n")
        let destination = try fixture.file("target/.keep", text: "")
            .deletingLastPathComponent()
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileRow(alpha, in: window)
        let b = WorkspaceUITestSupport.fileRow(beta, in: window)
        let c = WorkspaceUITestSupport.fileRow(gamma, in: window)
        let target = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label == %@", "target")).firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 15))
        XCTAssertTrue(b.waitForExistence(timeout: 15))
        XCTAssertTrue(c.waitForExistence(timeout: 15))
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        a.click()
        XCUIElement.perform(withKeyModifiers: .command) { c.click() }
        XCTAssertTrue(a.isSelected && c.isSelected && !b.isSelected)
        a.click(forDuration: 0.2, thenDragTo: target)
        let movedA = destination.appendingPathComponent("a.txt")
        let movedC = destination.appendingPathComponent("c.txt")
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: movedA.path)
                && FileManager.default.fileExists(atPath: movedC.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 15), .completed)
        XCTAssertEqual(try Data(contentsOf: movedA), Data("alpha original\n".utf8))
        XCTAssertEqual(try Data(contentsOf: movedC), Data("gamma original\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alpha.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gamma.path))
        XCTAssertEqual(try Data(contentsOf: beta), Data("beta original\n".utf8))
    }

    func testMultiSelectContextTargetsAndBulkTrashAgainstRealDisk() throws {
        let volume = ProcessInfo.processInfo.environment["BAILEY_P2_TEST_TRASH_VOLUME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let fixture = try WorkspaceUITestFixture(in: self, baseDirectory: volume)
        let alpha = try fixture.file("a.txt", text: "a bytes\n")
        let beta = try fixture.file("b.txt", text: "b bytes\n")
        let gamma = try fixture.file("c.txt", text: "c bytes\n")
        let originalClipboard = try WorkspaceUITestSupport.clipboardItems()
        defer {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !originalClipboard.isEmpty { XCTAssertTrue(pasteboard.writeObjects(originalClipboard)) }
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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
        XCTAssertTrue(a.isSelected && b.isSelected && !c.isSelected,
                      "Context click outside Selection targets C without changing A/B")
        a.click()
        XCUIElement.perform(withKeyModifiers: .shift) { b.click() }
        XCTAssertTrue(a.isSelected && b.isSelected && !c.isSelected)

        let selectedMenu = try fileContextMenu(for: a, in: app)
        XCTAssertTrue(a.isSelected && b.isSelected && !c.isSelected,
                      "Context-clicking inside the selection must preserve all selected rows")
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
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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
        app.menuBarItems["Project"].click()
        let addSSH = app.menuItems["Add SSH Files or Projects…"]
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

    func testAuthorizedWindowsSSHTwoWindowsKeepTargetsAfterIsolatedMasterExit() throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"],
              !host.isEmpty, !host.hasPrefix("-"),
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              ProcessInfo.processInfo.environment["BAILEY_P2_EXTERNAL_DISCONNECT"] == "1"
        else { throw XCTSkip("Requires a test-only Windows SSH host and Dev-master controller") }
        let originalClipboard = try WorkspaceUITestSupport.clipboardItems()
        defer {
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            if !originalClipboard.isEmpty { XCTAssertTrue(clipboard.writeObjects(originalClipboard)) }
        }
        let remoteRoot = try runSSH(
            host: host, command: "mktemp -d /tmp/bailey-p2-ui-XXXXXX"
        ).trimmingCharacters(in: .newlines)
        guard (remoteRoot as NSString).deletingLastPathComponent == "/tmp",
              (remoteRoot as NSString).lastPathComponent.hasPrefix("bailey-p2-ui-")
        else { throw NSError(domain: "BaileyP2UI", code: 2) }
        addTeardownBlock { @MainActor in
            XCTAssertEqual(try self.runSSH(host: host,
                command: "rm -r -- '\(remoteRoot)' && test ! -e '\(remoteRoot)' && printf cleaned"),
                "cleaned", "Clean only this isolated Windows SSH test directory")
        }
        let remoteA = remoteRoot + "/a-remote.txt"
        let remoteB = remoteRoot + "/b-remote.txt"
        let remoteNew = remoteRoot + "/after-reconnect.txt"
        _ = try runSSH(host: host, command:
            "printf 'REMOTE_A\\n' > '\(remoteA)' && "
            + "printf 'REMOTE_B\\n' > '\(remoteB)' && "
            + "git -C '\(remoteRoot)' init -q -b main")
        let fixture = try WorkspaceUITestFixture(in: self)
        let localTwin = try fixture.file("local-window/a-remote.txt", text: "LOCAL_ONLY\n")
        let localFolder = localTwin.deletingLastPathComponent()
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root
        )
        app.menuBarItems["Project"].click()
        app.menuItems["Add SSH Files or Projects…"].click()
        let remoteWindowID = app.windows.firstMatch.identifier
        let remoteWindow = app.windows.matching(identifier: remoteWindowID).firstMatch
        let sheet = remoteWindow.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 12))
        let hostField = sheet.comboBoxes.firstMatch
        hostField.click()
        hostField.typeKey("a", modifierFlags: .command)
        hostField.typeText(host)
        let paths = sheet.textViews.firstMatch
        paths.click()
        paths.typeText(remoteRoot)
        sheet.buttons["Add"].click()
        let filesA = remoteWindow.descendants(matching: .any)
            .matching(identifier: "bailey.dock.files").firstMatch
        XCTAssertTrue(filesA.waitForExistence(timeout: 25))
        filesA.click()
        let a = WorkspaceUITestSupport.fileRow(URL(fileURLWithPath: remoteA), in: remoteWindow)
        let b = WorkspaceUITestSupport.fileRow(URL(fileURLWithPath: remoteB), in: remoteWindow)
        XCTAssertTrue(a.waitForExistence(timeout: 25))
        XCTAssertTrue(b.waitForExistence(timeout: 25))
        a.click()
        XCUIElement.perform(withKeyModifiers: .shift) { b.click() }
        XCTAssertTrue(a.isSelected && b.isSelected)
        try fileContextMenu(for: a, in: app).menuItems["Copy Relative Path"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "a-remote.txt\nb-remote.txt")

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 15))
        let emptyWindow = try XCTUnwrap(app.windows.allElementsBoundByIndex.first {
            $0.buttons["bailey.emptyState.addFolder"].exists
        })
        let newWindow = app.windows.matching(identifier: emptyWindow.identifier).firstMatch
        try WorkspaceUITestSupport.addFolder(localFolder, to: app, in: newWindow)
        let filesB = newWindow.descendants(matching: .any)
            .matching(identifier: "bailey.dock.files").firstMatch
        XCTAssertTrue(filesB.waitForExistence(timeout: 15))
        filesB.click()
        let localRow = WorkspaceUITestSupport.fileRow(localTwin, in: newWindow)
        XCTAssertTrue(localRow.waitForExistence(timeout: 20))
        localRow.click()
        try fileContextMenu(for: localRow, in: app).menuItems["Copy Path"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), localTwin.path)
        XCTAssertTrue(a.isSelected && b.isSelected,
                      "The background Windows Files selection belongs to its own window")

        for _ in 0..<app.windows.count {
            if app.windows.firstMatch.identifier == remoteWindowID { break }
            app.typeKey("`", modifierFlags: .command)
        }
        XCTAssertEqual(app.windows.firstMatch.identifier, remoteWindowID)
        let dev = NSRunningApplication.runningApplications(withBundleIdentifier: "chiimagnus.bailey.dev")
        XCTAssertEqual(dev.count, 1)
        let devPID = try XCTUnwrap(dev.first?.processIdentifier)
        let ready = fixture.root.appendingPathComponent("p2-disconnect.ready")
        let done = fixture.root.appendingPathComponent("p2-disconnect.done")
        try "\(devPID)\n".write(to: ready, atomically: true, encoding: .utf8)
        NSLog("P2_DISCONNECT_READY_PATH=%@", ready.path)
        let disconnected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: done.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [disconnected], timeout: 65), .completed,
                       "Controller must close only this isolated Bailey Dev SSH master")
        XCTAssertEqual(try String(contentsOf: done, encoding: .utf8), "master-closed\n")

        XCTAssertEqual(try runSSH(host: host, command:
            "printf 'AFTER_RECONNECT\\n' > '\(remoteNew)' && printf created"), "created")
        XCTAssertTrue(WorkspaceUITestSupport.fileRow(
            URL(fileURLWithPath: remoteNew), in: remoteWindow
        ).waitForExistence(timeout: 30), "Remote Files must recover the fresh Windows listing")
        XCTAssertTrue(a.isSelected && b.isSelected,
                      "Reconnect must not silently retarget the old remote selection")
        try fileContextMenu(for: a, in: app).menuItems["Copy Relative Path"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "a-remote.txt\nb-remote.txt")
        XCTAssertEqual(try runSSH(host: host, command: "cat '\(remoteA)'"), "REMOTE_A\n")
        XCTAssertEqual(try runSSH(host: host, command: "cat '\(remoteB)'"), "REMOTE_B\n")
        XCTAssertEqual(try runSSH(host: host, command: "cat '\(remoteNew)'"), "AFTER_RECONNECT\n")
        XCTAssertTrue(try runSSH(host: host, command:
            "git -C '\(remoteRoot)' status --porcelain=v1").contains("after-reconnect.txt"))
        XCTAssertEqual(try Data(contentsOf: localTwin), Data("LOCAL_ONLY\n".utf8))
        XCTAssertFalse(WorkspaceUITestSupport.fileRow(
            URL(fileURLWithPath: remoteNew), in: newWindow
        ).exists, "The local window must not display an unrelated Windows file")
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

    func testSystemNewItemShortcutsUseFocusedFileManagerFolder() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let existing = try fixture.file("inside/existing.txt", text: "existing")
        let newFile = fixture.root.appendingPathComponent("inside/from-shortcut.txt")
        let newFolder = fixture.root.appendingPathComponent("inside/from-shortcut-folder")

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let folder = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label == %@", "inside")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        folder.click()
        app.typeKey("n", modifierFlags: .command)

        let fileName = window.textFields.matching(
            NSPredicate(format: "placeholderValue == %@", "File name")
        ).firstMatch
        XCTAssertTrue(fileName.waitForExistence(timeout: 15))
        fileName.typeText("from-shortcut.txt\n")
        let createdFile = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: newFile.path) },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [createdFile], timeout: 15), .completed)

        let existingRow = WorkspaceUITestSupport.fileRow(existing, in: window)
        XCTAssertTrue(existingRow.waitForExistence(timeout: 15))
        existingRow.click()
        app.typeKey("n", modifierFlags: [.command, .option])

        let folderName = window.textFields.matching(
            NSPredicate(format: "placeholderValue == %@", "Folder name")
        ).firstMatch
        XCTAssertTrue(folderName.waitForExistence(timeout: 15))
        folderName.typeText("from-shortcut-folder\n")
        let createdFolder = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                var isDirectory = ObjCBool(false)
                return FileManager.default.fileExists(
                    atPath: newFolder.path, isDirectory: &isDirectory
                ) && isDirectory.boolValue
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [createdFolder], timeout: 15), .completed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("from-shortcut.txt").path
        ))
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
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
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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

    func testHomeEndAndPageKeysScrollFocusedFilesWithoutOpeningOrSelectingThem() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        var files: [URL] = []
        for index in 0..<80 {
            files.append(try fixture.file(String(format: "%03d.txt", index), text: "real page row \(index)\n"))
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "zh-Hans", project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let first = WorkspaceUITestSupport.fileRow(files[0], in: window)
        let last = WorkspaceUITestSupport.fileRow(files[79], in: window)
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        app.typeKey(XCUIKeyboardKey.end, modifierFlags: [])
        XCTAssertTrue(last.waitForExistence(timeout: 15))
        XCTAssertTrue(last.isHittable)
        XCTAssertFalse(last.isSelected)
        app.typeKey(XCUIKeyboardKey.home, modifierFlags: [])
        XCTAssertTrue(first.isHittable)
        let initialFrame = first.frame
        app.typeKey(XCUIKeyboardKey.pageDown, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.pageDown, modifierFlags: [])
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            first.frame.minY < initialFrame.minY - 100
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 5), .completed,
                       "Repeated Page Down must actually scroll by more than a few rows")
        app.typeKey(XCUIKeyboardKey.pageUp, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.pageUp, modifierFlags: [])
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            first.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        XCTAssertFalse(first.isSelected)
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 0)
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(files[0], in: window).waitForExistence(timeout: 15))
        let content = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.textViews.allElementsBoundByIndex.contains { ($0.value as? String) == "real page row 0\n" }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [content], timeout: 15), .completed)
        XCTAssertEqual(try Data(contentsOf: files[0]), Data("real page row 0\n".utf8))
    }

    func testModifierMultiSelectionDoesNotOpenOrCollapseFiles() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("a.swift", text: "a\n")
        let beta = try fixture.file("b.swift", text: "b\n")
        let gamma = try fixture.file("c.swift", text: "c\n")
        let delta = try fixture.file("d.swift", text: "d\n")
        let epsilon = try fixture.file("e.swift", text: "e\n")
        let last = try fixture.file("f.swift", text: "f\n")
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let window = app.windows.firstMatch
        let a = WorkspaceUITestSupport.fileRow(alpha, in: window)
        let b = WorkspaceUITestSupport.fileRow(beta, in: window)
        let c = WorkspaceUITestSupport.fileRow(gamma, in: window)
        let deltaRow = WorkspaceUITestSupport.fileRow(delta, in: window)
        let epsilonRow = WorkspaceUITestSupport.fileRow(epsilon, in: window)
        let lastRow = WorkspaceUITestSupport.fileRow(last, in: window)
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
        a.click()
        XCUIElement.perform(withKeyModifiers: .command) { c.click() }
        XCUIElement.perform(withKeyModifiers: .shift) { epsilonRow.click() }
        XCTAssertTrue(a.isSelected && !b.isSelected && c.isSelected
                      && deltaRow.isSelected && epsilonRow.isSelected && !lastRow.isSelected)
        XCUIElement.perform(withKeyModifiers: .shift) { deltaRow.click() }
        XCTAssertTrue(a.isSelected && !b.isSelected && c.isSelected
                      && deltaRow.isSelected && !epsilonRow.isSelected)
        XCUIElement.perform(withKeyModifiers: .shift) { b.click() }
        XCTAssertTrue(a.isSelected && b.isSelected && c.isSelected && !deltaRow.isSelected)
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .shift)
        XCTAssertTrue(a.isSelected && !b.isSelected && c.isSelected && !deltaRow.isSelected)
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .shift)
        XCTAssertTrue(a.isSelected && !b.isSelected && c.isSelected && deltaRow.isSelected)
        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: .shift)
        XCTAssertTrue(a.isSelected && !b.isSelected && c.isSelected && !deltaRow.isSelected)
        c.rightClick()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(a.isSelected && !b.isSelected && c.isSelected)
        XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, baselineTabs,
                       "Modifier selection and context menus must not open more files")
        app.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(a.isSelected && b.isSelected && c.isSelected,
                      "Command+A in focused Files must select every visible row")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .shift)
        XCTAssertTrue(a.isSelected && b.isSelected && !c.isSelected
                      && deltaRow.isSelected && epsilonRow.isSelected && lastRow.isSelected,
                      "Shift+Down onto a selected row removes the previous Focus, not the other islands")
        XCTAssertEqual(try String(contentsOf: beta, encoding: .utf8), "b\n")
        XCTAssertEqual(try String(contentsOf: gamma, encoding: .utf8), "c\n")
    }

    func testCommandPaletteRestoresFileTreeKeyboardAfterDismissal() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("a-first.swift", text: "let first = 1\n")
        let second = try fixture.file("b-second.swift", text: "let second = 2\n")
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: language, project: fixture.root
        )
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
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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
