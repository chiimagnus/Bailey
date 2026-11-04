import Darwin
import XCTest

@MainActor
final class WorkspaceGitUITests: XCTestCase {
    func testGitChangesAreScopedToTheOpenedRepository() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let changed = try fixture.file("changed-file.swift", text: "let saved = 1\n")
        let other = try WorkspaceUITestFixture(in: self)
        _ = try other.file("outside.swift", text: "let outside = true\n")
        try other.initializeGit()
        let otherHead = try other.git(["rev-parse", "HEAD"])
        let originalGitDir = ProcessInfo.processInfo.environment["GIT_DIR"]
        let originalWorkTree = ProcessInfo.processInfo.environment["GIT_WORK_TREE"]
        do {
            defer {
                if let originalGitDir { setenv("GIT_DIR", originalGitDir, 1) }
                else { unsetenv("GIT_DIR") }
                if let originalWorkTree { setenv("GIT_WORK_TREE", originalWorkTree, 1) }
                else { unsetenv("GIT_WORK_TREE") }
            }
            setenv("GIT_DIR", other.root.appendingPathComponent(".git").path, 1)
            setenv("GIT_WORK_TREE", other.root.path, 1)
            try fixture.initializeGit()
            let actualRoot = String(decoding: try fixture.git(["rev-parse", "--show-toplevel"]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(URL(fileURLWithPath: actualRoot).resolvingSymlinksInPath(),
                           fixture.root.resolvingSymlinksInPath(),
                           "Inherited Git routing must never escape the UI fixture")
        }
        XCTAssertEqual(try other.git(["rev-parse", "HEAD"]), otherHead,
                       "The unrelated repository must not be changed by fixture setup")
        try "let saved = 2\n".write(to: changed, atomically: true, encoding: .utf8)
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(git.waitForExistence(timeout: 20))
        XCTAssertTrue(git.isHittable, "The native Git Manager shortcut must reveal a visible Git tab")

        let change = WorkspaceUITestSupport.fileRow(changed, in: app.windows.firstMatch, relativeTo: fixture.root)
        XCTAssertTrue(change.waitForExistence(timeout: 25),
                      "Git Changes must expose the modified file in the selected repository")
        change.click()
        let diff = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "changed-file.swift")
        ).firstMatch
        XCTAssertTrue(diff.waitForExistence(timeout: 15),
                      "The real Git Changes row must open a diff tab")
    }

    func testGitReviewShowsOnlyRealChangeForCRLFCheckout() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let name = "windows-eol.md"
        let file = try fixture.file(name, text: "alpha\nbeta\nlast\n")
        try fixture.initializeGit()
        try fixture.git(["config", "core.autocrlf", "true"])
        let pureEOL = "alpha\r\nbeta\r\nlast\r\n"
        try Data(pureEOL.utf8).write(to: file)
        XCTAssertTrue(try fixture.git(["diff", "--numstat", "HEAD", "--", name]).isEmpty,
                      "Git must see no change from checkout line endings")
        let modified = "alpha\r\nbeta edited\r\nlast\r\n"
        try Data(modified.utf8).write(to: file)
        XCTAssertEqual(String(decoding: try fixture.git(["diff", "--numstat", "HEAD", "--", name]),
                              as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                       "1\t1\t" + name)

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        app.typeKey("g", modifierFlags: [.command, .shift])
        let change = WorkspaceUITestSupport.fileRow(file, in: window, relativeTo: fixture.root)
        XCTAssertTrue(change.waitForExistence(timeout: 25))
        change.click()
        XCTAssertFalse(window.radioGroups["bailey.diff.mode"].exists)
        let editor = window.textViews["bailey.diff.worktree"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let rendered = try XCTUnwrap(editor.value as? String)
        XCTAssertEqual(rendered.components(separatedBy: "alpha").count - 1, 1,
                       "Unchanged first line must not be removed and re-added")
        XCTAssertEqual(rendered.components(separatedBy: "last").count - 1, 1)
        XCTAssertTrue(rendered.contains("beta edited"))
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Git Review with one real edit and Windows CRLF"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertEqual(try Data(contentsOf: file), Data(modified.utf8))
    }

    func testAuthorizedWindowsSSHGitReviewThroughRealUI() throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Windows SSH GUI requires explicitly authorized host")
        }
        func ssh(_ script: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-T", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "--", host, "sh -s",
            ]
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            input.fileHandleForWriting.write(Data(script.utf8))
            try? input.fileHandleForWriting.close()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "WindowsSSHGuiFixture", code: Int(process.terminationStatus),
                              userInfo: [
                                NSLocalizedDescriptionKey: String(decoding: stderr, as: UTF8.self)
                              ])
            }
            return String(decoding: stdout, as: UTF8.self)
        }
        let root = try ssh("mktemp -d /tmp/bailey-git-ui-XXXXXX\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The remote output is reused in shell commands, including cleanup.
        // Accept only the exact mktemp name so it cannot become shell input.
        guard root.range(of: #"^/tmp/bailey-git-ui-[A-Za-z0-9]{6}$"#,
                         options: .regularExpression) != nil else {
            throw NSError(domain: "WindowsSSHGuiFixture", code: 1)
        }
        defer {
            WorkspaceUITestSupport.finishSession()
            // The generated path is checked against the fixed owned prefix.
            try? ssh("rm -r -- '\(root)'\n")
        }

        let status = try ssh("""
        set -eu
        cd '\(root)'
        git init -q -b main
        git config user.name 'Bailey Windows UI Test'
        git config user.email fixture@invalid
        git config commit.gpgsign false
        git config core.autocrlf true
        git config filter.drop.clean "sed '/^TRANSIENT/d'"
        printf 'filtered.txt filter=drop\\n' > .gitattributes
        printf 'keep\\n' > filtered.txt
        git add -- .
        git commit -qm baseline
        printf 'changed\\nTRANSIENT\\n' > filtered.txt
        git diff --numstat -- filtered.txt
        """)
        XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines),
                       "1\t1\tfiltered.txt")
        let local = try WorkspaceUITestFixture(in: self)
        _ = try local.file("local.txt", text: "UI anchor\n")
        try local.initializeGit()
        let actualHome = try XCTUnwrap(getpwuid(getuid()))
        let actualSSHConfig = URL(fileURLWithPath: String(cString: actualHome.pointee.pw_dir))
            .appendingPathComponent(".ssh/config")
        XCTAssertTrue(FileManager.default.fileExists(atPath: actualSSHConfig.path),
                      "The UI fixture must use the real user's approved SSH alias file")
        _ = try local.file(".ssh/config", text: "Include \(actualSSHConfig.path)\n")
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: local.root, project: local.root
        )
        let window = app.windows.firstMatch
        let addProject = app.buttons["bailey.projects.addPicker"]
        XCTAssertTrue(addProject.waitForExistence(timeout: 15))
        addProject.click()
        let openSSH = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Add SSH Files")
        ).firstMatch
        XCTAssertTrue(openSSH.waitForExistence(timeout: 10))
        openSSH.click()
        let hostChoice = app.buttons.matching(identifier: "bailey.sshFolderPicker.hostChoice")
            .matching(NSPredicate(format: "value == %@", host)).firstMatch
        XCTAssertTrue(hostChoice.waitForExistence(timeout: 15),
                      "SSH picker must offer the authorized Windows host")
        hostChoice.click()
        let field = app.textFields["bailey.sshFolderPicker.path"]
        XCTAssertTrue(field.waitForExistence(timeout: 40))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText(root)
        field.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let confirmButton = app.buttons["bailey.sshFolderPicker.add"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 40))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: confirmButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 40), .completed)
        confirmButton.click()

        let addPanel = window.buttons["Add Panel"]
        XCTAssertTrue(addPanel.waitForExistence(timeout: 40),
                      "The selected SSH project must mount its workspace")
        addPanel.click()
        let gitAction = app.buttons.matching(
            NSPredicate(format: "label == %@", "Git Manager")
        ).firstMatch
        XCTAssertTrue(gitAction.waitForExistence(timeout: 15))
        gitAction.click()
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(git.waitForExistence(timeout: 40))
        let remoteURL = URL(fileURLWithPath: root + "/filtered.txt")
        let rootURL = URL(fileURLWithPath: root)
        let change = WorkspaceUITestSupport.fileRow(
            remoteURL, in: window, relativeTo: rootURL
        )
        XCTAssertTrue(change.waitForExistence(timeout: 90),
                      "Actual Windows SSH project must show its changed file")
        change.click()
        let review = window.textViews["bailey.diff.canonical"]
        XCTAssertTrue(review.waitForExistence(timeout: 40))
        let visible = try XCTUnwrap(review.value as? String)
        XCTAssertTrue(visible.contains("keep") && visible.contains("changed"))
        XCTAssertFalse(visible.contains("TRANSIENT"))
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Real Windows SSH Git Review with noninvertible clean filter"
        shot.lifetime = .keepAlways
        add(shot)

        let edit = window.textViews["bailey.diff.worktree"]
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        XCTAssertEqual(edit.value as? String, "changed\nTRANSIENT\n")
        edit.click()
        app.typeKey("a", modifierFlags: .command)
        edit.typeText("updated\nTRANSIENT\n")
        app.typeKey("s", modifierFlags: .command)
        let rawSave = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? ssh("cat -- '\(root)/filtered.txt'\n")) == "updated\nTRANSIENT\n"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rawSave], timeout: 65), .completed)
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (review.value as? String)?.contains("updated") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 65), .completed)
        XCTAssertFalse((review.value as? String ?? "").contains("TRANSIENT"))
    }

    func testGitCleanFilteredReviewAndRawEditRemainDistinct() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("filter-lines.txt", text: "keep\n")
        _ = try fixture.file(".gitattributes", text: "filter-lines.txt filter=drop\n")
        try fixture.initializeGit()
        try fixture.git(["config", "filter.drop.clean", "sed '/^TRANSIENT/d'"])
        let raw = "changed\nTRANSIENT\n"
        try Data(raw.utf8).write(to: file)
        XCTAssertEqual(
            String(decoding: try fixture.git(["diff", "--numstat", "--", "filter-lines.txt"]),
                   as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            "1\t1\tfilter-lines.txt"
        )

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        app.typeKey("g", modifierFlags: [.command, .shift])
        let row = WorkspaceUITestSupport.fileRow(file, in: window, relativeTo: fixture.root)
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        row.click()
        let review = window.textViews["bailey.diff.canonical"]
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        let visible = try XCTUnwrap(review.value as? String)
        XCTAssertTrue(visible.contains("keep") && visible.contains("changed"))
        XCTAssertFalse(visible.contains("TRANSIENT"),
                       "Review must display the Git-cleaned content, not invented raw lines")
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Git clean filter changes line count without losing real Review"
        shot.lifetime = .keepAlways
        add(shot)

        let editor = window.textViews["bailey.diff.worktree"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, raw,
                       "The editor must expose the original bytes hidden by a clean filter")
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        let next = "changed again\nTRANSIENT\n"
        editor.typeText(next)
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == Data(next.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed,
                       "Command-S must write raw source text without reapplying the clean filter")
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (review.value as? String)?.contains("changed again") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 20), .completed)
        XCTAssertFalse((review.value as? String ?? "").contains("TRANSIENT"))
        XCTAssertEqual(try Data(contentsOf: file), Data(next.utf8))
    }

    func testLargeSwiftEditableDiffRendersAllSourceLinesAround595() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let old = (0..<900).map { "    let line\($0) = \($0)" }
        var changed = old
        changed[594] = "    let line594 = 2026 // altered"
        changed[617] = "    let line617 = 2027 // altered"
        let file = try fixture.file("FileTreeModel.swift", text: old.joined(separator: "\n") + "\n")
        try fixture.initializeGit()
        try (changed.joined(separator: "\n") + "\n").write(to: file, atomically: true,
                                                           encoding: .utf8)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        app.typeKey("g", modifierFlags: [.command, .shift])
        let change = WorkspaceUITestSupport.fileRow(file, in: window, relativeTo: fixture.root)
        XCTAssertTrue(change.waitForExistence(timeout: 25))
        change.click()
        XCTAssertFalse(window.radioGroups["bailey.diff.mode"].exists)
        let layout = window.radioGroups["bailey.diff.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 15))
        layout.radioButtons.element(boundBy: 0).click()
        let preview = window.textViews["bailey.diff.canonical"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let folded = try XCTUnwrap(preview.value as? String)
        XCTAssertTrue(folded.contains("line594 = 2026"))
        XCTAssertTrue(folded.contains("line617 = 2027"))
        XCTAssertFalse(folded.contains("let line0 = 0"),
                       "Git Changes must hide distant unchanged lines just like historical Diff")
        let editor = window.textViews["bailey.diff.worktree"]
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.1)).click()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let displayed = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(displayed.contains("line594 = 2026"))
        XCTAssertTrue(displayed.contains("line617 = 2027"))
        XCTAssertTrue(displayed.contains("let line0 = 0"))
        XCTAssertTrue(displayed.contains("let line899 = 899"))
        editor.click()
        for _ in 0..<8 { editor.swipeUp() }
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Editable Git Diff with all 900 source lines and both modifications"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       changed.joined(separator: "\n") + "\n")
    }

    func testNativeDiffChromeRepaintsDuringAppearanceSwitchWithoutRedocking() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("theme-diff.swift", text: "let theme = 1\n")
        try fixture.initializeGit()
        try "let theme = 2\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "theme-diff.swift"])
        _ = try fixture.file(".config/bailey-dev/config.toml", text: """
            theme = "light"
            theme-light = "Ayu Light"
            theme-dark = "Adwaita Dark"
            """)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root, project: fixture.root
        )
        let window = app.windows.matching(identifier: "main-AppWindow-1").firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let change = WorkspaceUITestSupport.fileRow(file, in: window, relativeTo: fixture.root)
        XCTAssertTrue(change.waitForExistence(timeout: 25))
        change.click()
        let layout = window.radioGroups["bailey.diff.layout"]
        XCTAssertFalse(window.radioGroups["bailey.diff.mode"].exists)
        XCTAssertTrue(layout.waitForExistence(timeout: 15))
        layout.radioButtons.element(boundBy: 1).click()
        XCTAssertGreaterThanOrEqual(window.textViews.count, 2)

        func capture(_ title: String) throws -> (header: NSColor, body: NSColor, splitDivider: NSColor) {
            let shot = window.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = title
            attachment.lifetime = .keepAlways
            add(attachment)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                data: try XCTUnwrap(shot.image.tiffRepresentation)
            ))
            let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
            func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
                let pixel = try XCTUnwrap(bitmap.colorAt(
                    x: Int(x * scale), y: Int(y * scale)
                ))
                return try XCTUnwrap(pixel.usingColorSpace(.deviceRGB))
            }
            return try (color(350, 56), color(350, 350), color(419, 350))
        }
        func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent),
                abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent))
        }
        let before = try capture("Native split diff, Ayu Light")
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        let dark = settings.descendants(matching: .tab)["Dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 12))
        dark.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 12))

        let after = try capture("Native split diff, Adwaita Dark")
        XCTAssertGreaterThan(difference(before.body, after.body), 0.25,
                             "Retained native diff text background must change with appearance")
        XCTAssertLessThan(difference(after.header, after.body), 0.04,
                          "Diff native controls row must not remain in the previous theme")
        XCTAssertGreaterThan(difference(before.splitDivider, after.splitDivider), 0.25,
                             "Diff divider must change color with the selected appearance")
        XCTAssertLessThan(difference(after.splitDivider, after.body), 0.2,
                          "Retained Diff split divider must not keep the original light CGColor")

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        let darkPicker = settings.popUpButtons.element(boundBy: 1)
        XCTAssertTrue(darkPicker.waitForExistence(timeout: 12))
        darkPicker.click()
        let ayuDark = darkPicker.menuItems["Ayu"]
        XCTAssertTrue(ayuDark.waitForExistence(timeout: 12))
        ayuDark.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 12))
        let changedDark = try capture("Native split diff, Ayu Dark without appearance change")
        XCTAssertGreaterThan(difference(changedDark.body, after.body), 0.03,
                             "Native diff must apply a new dark palette without changing appearance")
        XCTAssertLessThan(difference(changedDark.splitDivider, changedDark.body), 0.2,
                          "Native split divider must also update for dark-to-dark palette changes")

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        let light = settings.descendants(matching: .tab)["Light"].firstMatch
        XCTAssertTrue(light.waitForExistence(timeout: 12))
        light.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 12))
        let restored = try capture("Native split diff, restored Ayu Light")
        XCTAssertLessThan(difference(restored.splitDivider, before.splitDivider), 0.04,
                          "Split divider must restore its light color after dark-to-light")
    }

    func testWorktreeDiffEditsAndPersistsRealGitFile() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("diff-edit.swift", text: "let value = 1\n")
        try fixture.initializeGit()
        let original = "let value = 2\n"
        let updated = "let value = 3 // 中文 👋\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)

        let window = app.windows.firstMatch
        app.typeKey("g", modifierFlags: [.command, .shift])
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(git.waitForExistence(timeout: 20))
        XCTAssertTrue(git.isHittable, "Git Manager must be on screen before selecting changes")
        let change = WorkspaceUITestSupport.fileRow(file, in: window, relativeTo: fixture.root)
        XCTAssertTrue(change.waitForExistence(timeout: 25))
        change.click()

        XCTAssertFalse(window.radioGroups["bailey.diff.mode"].exists,
                       "Worktree Diff must open directly into its editable native surface")
        let layout = window.radioGroups["bailey.diff.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 15))
        let editor = window.textViews["bailey.diff.worktree"]
        layout.radioButtons.element(boundBy: 1).click()
        let baseline = window.textViews["bailey.diff.baseline"]
        XCTAssertTrue(baseline.waitForExistence(timeout: 15))
        XCTAssertTrue((baseline.value as? String ?? "").contains("let value = 1"))
        XCTAssertEqual(window.textViews.count, 2,
                       "Split must retain the old readonly side and the current editable side")
        XCTAssertEqual(editor.value as? String, original)
        let splitShot = XCTAttachment(screenshot: window.screenshot())
        splitShot.name = "Native editable Split Diff: baseline readonly and worktree editable"
        splitShot.lifetime = .keepAlways
        add(splitShot)
        layout.radioButtons.element(boundBy: 0).click()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, original,
                       "Worktree Diff must expose the live worktree content, not the old Git revision")
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        editor.typeText(updated)
        XCTAssertEqual(editor.value as? String, updated)
        // Real native Undo/Redo is tested against this retained NSTextView in
        // NativeDiffTabTests. This UI test verifies the Split/Unified path,
        // keyboard editing and save without repeating synthetic Cmd-Z input.
        app.typeKey("s", modifierFlags: .command)

        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8)) == updated
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed,
                       "Diff Command-S must persist exact native bytes in the selected Git worktree")
    }
}
