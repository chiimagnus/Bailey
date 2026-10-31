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

    func testNativeDiffChromeRepaintsDuringAppearanceSwitchWithoutRedocking() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("theme-diff.swift", text: "let theme = 1\n")
        try fixture.initializeGit()
        try "let theme = 2\n".write(to: file, atomically: true, encoding: .utf8)
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
        let mode = window.radioGroups["bailey.diff.mode"]
        let layout = window.radioGroups["bailey.diff.layout"]
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        XCTAssertTrue(layout.waitForExistence(timeout: 15))
        mode.radioButtons.element(boundBy: 0).click()
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

        let mode = window.radioGroups["bailey.diff.mode"]
        let layout = window.radioGroups["bailey.diff.layout"]
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        XCTAssertTrue(layout.waitForExistence(timeout: 15))
        // The user's persisted mode may be Edit, which hides both review panes.
        // Enter Review explicitly before asserting Split's visible native panes.
        mode.radioButtons.element(boundBy: 0).click()
        let split = layout.radioButtons.element(boundBy: 1)
        split.click()
        XCTAssertEqual(String(describing: split.value ?? ""), "1",
                       "Split layout must actually be selected")
        XCTAssertGreaterThanOrEqual(window.textViews.count, 2,
                                    "Split mode must mount separate native text panes")
        let unified = layout.radioButtons.element(boundBy: 0)
        unified.click()
        XCTAssertEqual(String(describing: unified.value ?? ""), "1",
                       "Unified layout must actually be restored")
        let edit = mode.radioButtons.element(boundBy: 1)
        edit.click()
        XCTAssertEqual(String(describing: edit.value ?? ""), "1",
                       "Native worktree mode must switch to Edit")

        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, original,
                       "Edit mode must expose the live worktree content, not the old Git revision")
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        editor.typeText(updated)
        XCTAssertEqual(editor.value as? String, updated)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, original,
                       "Native Diff Undo must restore the worktree buffer")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(editor.value as? String, updated)
        app.typeKey("s", modifierFlags: .command)

        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8)) == updated
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed,
                       "Diff Command-S must persist exact native bytes in the selected Git worktree")
    }
}
