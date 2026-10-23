import XCTest

@MainActor
final class WorkspaceGitUITests: XCTestCase {
    func testGitGraphDisplaysTheRealCommitAndExpandsItsFiles() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let committed = try fixture.file("history-marker.swift", text: "let historyMarker = true\n")
        try fixture.initializeGit()
        let app = try WorkspaceUITestSupport.launch(in: self)

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(git.waitForExistence(timeout: 20))
        XCTAssertTrue(git.isHittable, "The native Git Manager shortcut must reveal a visible Git tab")

        let history = app.buttons.matching(
            NSPredicate(format: "label == %@", "E2E fixture history")
        ).firstMatch
        guard history.waitForExistence(timeout: 20) else {
            XCTFail("Git Graph did not expose the fixture commit. Accessibility tree:\n"
                + String(app.debugDescription.prefix(16000)))
            return
        }
        history.click()
        let path = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "bailey.git.history.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", " + committed.lastPathComponent))
            .firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 15),
                      "Opening a real Git Graph commit must reveal its changed file")
    }

    func testGitChangesAreScopedToTheOpenedRepository() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let changed = try fixture.file("changed-file.swift", text: "let saved = 1\n")
        try fixture.initializeGit()
        try "let saved = 2\n".write(to: changed, atomically: true, encoding: .utf8)
        let app = try WorkspaceUITestSupport.launch(in: self)

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
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

    func testWorktreeDiffEditsAndPersistsRealGitFile() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("diff-edit.swift", text: "let value = 1\n")
        try fixture.initializeGit()
        let original = "let value = 2\n"
        let updated = "let value = 3 // 中文 👋\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)

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
