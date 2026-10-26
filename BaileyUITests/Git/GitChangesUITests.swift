import Foundation
import XCTest

@MainActor
final class GitChangesUITests: XCTestCase {
    func testRightClickAnotherGitChangeMovesKeyboardCursorWithoutOpeningDiff() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("alpha.txt", text: "first old\n")
        let second = try fixture.file("beta.txt", text: "second old\n")
        try fixture.initializeGit()
        try "first new\n".write(to: first, atomically: true, encoding: .utf8)
        try "second new\n".write(to: second, atomically: true, encoding: .utf8)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window, relativeTo: fixture.root)
        let secondRow = WorkspaceUITestSupport.fileRow(second, in: window, relativeTo: fixture.root)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 25))
        XCTAssertTrue(secondRow.waitForExistence(timeout: 25))
        firstRow.click()
        secondRow.rightClick()
        XCTAssertTrue(app.menuItems["Copy Path"].waitForExistence(timeout: 8))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let tab = window.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "beta.txt"
        )).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 15),
                      "Return after context-click must browse the clicked Git change")
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data(" M alpha.txt\n M beta.txt\n".utf8))
    }

    func testStagedAndUnstagedRowsPreviewTheirDistinctGitBaselines() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("index-side.txt", text: "HEAD contents\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "INDEX contents\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "index-side.txt"])
        try "WORKTREE contents\n".write(to: file, atomically: true, encoding: .utf8)

        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let rows = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", index-side.txt"))
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 25),
                      "A path with index and worktree edits must have two distinct Git Changes rows")

        func contents() -> Set<String> {
            Set(window.textViews.allElementsBoundByIndex.compactMap { $0.value as? String })
        }
        func expectSplit(old: String, new: String) {
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let values = contents()
                return values.contains(old) && values.contains(new)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 20), .completed,
                           "The native Split Diff must show the actual baseline and selected Git side")
        }
        rows.element(boundBy: 0).click()
        // Staged revisions are intentionally read-only and have no Edit/Review
        // control. They do expose the native Split/Unified layout selector.
        let layout = window.radioGroups["bailey.diff.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 15))
        layout.radioButtons.element(boundBy: 1).click()
        expectSplit(old: "HEAD contents\n", new: "INDEX contents\n")

        rows.element(boundBy: 1).click()
        // Worktree diffs can be edited, so explicitly re-enter Review before
        // comparing two immutable sides; this selector is absent for staged.
        let mode = window.radioGroups["bailey.diff.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        mode.radioButtons.element(boundBy: 0).click()
        XCTAssertTrue(layout.waitForExistence(timeout: 15))
        layout.radioButtons.element(boundBy: 1).click()
        expectSplit(old: "INDEX contents\n", new: "WORKTREE contents\n")
        XCTAssertEqual(try fixture.git(["show", ":index-side.txt"]),
                       Data("INDEX contents\n".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("WORKTREE contents\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data("MM index-side.txt\n".utf8))
    }

    func testGitGraphSpaceExpandsCommitWhenChangesListIsEmpty() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("only-committed.txt", text: "committed\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 20))
        let graphCommit = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history"
        )).firstMatch
        XCTAssertTrue(graphCommit.waitForExistence(timeout: 20))
        let historicalFile = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "bailey.git.history.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", " + file.lastPathComponent))
            .firstMatch
        XCTAssertFalse(historicalFile.exists, "A clean Graph starts with history collapsed")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(historicalFile.waitForExistence(timeout: 15),
                      "With no Changes rows, Space must activate the focused Git Graph commit")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
    }

    func testNestedGitChangesTreeSupportsArrowSpaceReturnAndCollapseWithoutWritingIndex() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let alpha = try fixture.file("nested/alpha.txt", text: "alpha old\n")
        let beta = try fixture.file("nested/beta.txt", text: "beta old\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "alpha new\n".write(to: alpha, atomically: true, encoding: .utf8)
        try "beta new\n".write(to: beta, atomically: true, encoding: .utf8)
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let folder = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "nested,"))
            .firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 25))
        // A direct tree-row click puts the keyboard receiver in the Git list.
        folder.click()
        folder.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileRow(alpha, in: window,
            relativeTo: fixture.root).waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        let firstTab = window.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "alpha.txt"
        )).firstMatch
        XCTAssertTrue(firstTab.waitForExistence(timeout: 15),
                      "Right+Space must browse the first nested Git Changes file")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let secondTab = window.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "beta.txt"
        )).firstMatch
        XCTAssertTrue(secondTab.waitForExistence(timeout: 15),
                      "Down+Return must browse the next nested file using the Git keyboard receiver")
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
        XCTAssertFalse(WorkspaceUITestSupport.fileRow(alpha, in: window,
            relativeTo: fixture.root).exists,
            "Left from the nested file must select and then collapse its parent")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["diff", "--cached", "--name-only"]).isEmpty)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data(" M nested/alpha.txt\n M nested/beta.txt\n".utf8))
    }

    func testCommandPaletteCancellationRestoresGitChangesKeyboardNavigation() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("alpha.txt", text: "alpha old\n")
        let second = try fixture.file("beta.txt", text: "beta old\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "alpha new\n".write(to: first, atomically: true, encoding: .utf8)
        try "beta new\n".write(to: second, atomically: true, encoding: .utf8)
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 20))
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window, relativeTo: fixture.root)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 25))
        firstRow.click()
        XCTAssertTrue(window.radioGroups["bailey.diff.mode"].waitForExistence(timeout: 15))
        app.typeKey("p", modifierFlags: .command)
        let search = window.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5),
                      "Escape must dismiss an empty palette before Git keyboard navigation resumes")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        let mode = window.radioGroups["bailey.diff.mode"]
        mode.radioButtons.element(boundBy: 1).click()
        let pane = window.textViews.firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 15))
        XCTAssertEqual(pane.value as? String, "beta new\n",
                       "Down+Space must browse the next Git Changes file without moving focus to Diff")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["diff", "--cached", "--name-only"]).isEmpty)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data(" M alpha.txt\n M beta.txt\n".utf8))
    }

    func testChangingProjectsCannotDisplayOrWriteTheFormerGitRepository() throws {
        let firstFixture = try WorkspaceUITestFixture(in: self)
        let first = try firstFixture.file("first-change.txt", text: "first committed\n")
        try firstFixture.initializeGit()
        try "first modified\n".write(to: first, atomically: true, encoding: .utf8)
        let secondFixture = try WorkspaceUITestFixture(in: self)
        let second = try secondFixture.file("second-change.txt", text: "second committed\n")
        try secondFixture.initializeGit()
        try "second modified\n".write(to: second, atomically: true, encoding: .utf8)
        let headA = try firstFixture.git(["rev-parse", "HEAD"])
        let headB = try secondFixture.git(["rev-parse", "HEAD"])

        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(firstFixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window,
                                                      relativeTo: firstFixture.root)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 25))
        firstRow.click()

        app.typeKey("a", modifierFlags: [.command, .shift])
        try WorkspaceUITestSupport.choose(secondFixture.root, in: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let secondRow = WorkspaceUITestSupport.fileRow(second, in: window,
                                                       relativeTo: secondFixture.root)
        XCTAssertTrue(secondRow.waitForExistence(timeout: 25))
        XCTAssertFalse(firstRow.exists,
                       "Changing the selected project must remove the former Git Changes rows")
        secondRow.click()
        XCTAssertTrue(window.radioGroups["bailey.diff.mode"].waitForExistence(timeout: 15))
        XCTAssertEqual(try firstFixture.git(["rev-parse", "HEAD"]), headA)
        XCTAssertEqual(try secondFixture.git(["rev-parse", "HEAD"]), headB)
        XCTAssertTrue(try firstFixture.git(["diff", "--cached", "--name-only"]).isEmpty)
        XCTAssertTrue(try secondFixture.git(["diff", "--cached", "--name-only"]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: first), Data("first modified\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second modified\n".utf8))
    }

    func testExternalGitInitializationAppearsWithoutManualRefresh() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("initialized-externally.txt", text: "initial content\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.root.appendingPathComponent(".git").path))

        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 20))

        // Git is initialized by another process after the panel has mounted.
        // Neither user activation nor an explicit refresh is sent to the app.
        try fixture.initializeGit()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history"
        )).firstMatch.waitForExistence(timeout: 25),
          "Creating .git externally must make the real Git Graph discover the repository")
        XCTAssertEqual(try fixture.git(["show", "HEAD:initialized-externally.txt"]),
                       try Data(contentsOf: file))
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
    }

    func testExternalWorktreeIndexAndCommitRefreshTheRealGitPanel() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("external.txt", text: "baseline\n")
        try fixture.initializeGit()
        let headBefore = try fixture.git(["rev-parse", "HEAD"])

        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 20))
        let window = app.windows.firstMatch
        let changed = WorkspaceUITestSupport.fileRow(file, in: window, relativeTo: fixture.root)
        XCTAssertFalse(changed.exists, "Unmodified fixture must have no Git Changes row")

        try "external edit 中文\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(changed.waitForExistence(timeout: 25),
                      "FSEvents must refresh the visible Git Changes without a manual refresh")
        changed.click()
        XCTAssertTrue(window.radioGroups["bailey.diff.mode"].waitForExistence(timeout: 15),
                      "A real Git Changes click must open its native Diff")

        try fixture.git(["add", "--", "external.txt"])
        XCTAssertEqual(try fixture.git(["show", ":external.txt"]), Data("external edit 中文\n".utf8))
        try fixture.git(["-c", "user.name=BaileyUITest", "-c",
                         "user.email=tests@example.invalid", "commit", "-qm", "E2E external commit"])
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label == %@", "E2E external commit")
        ).firstMatch.waitForExistence(timeout: 25),
          "External commit must appear in Git Graph through real file events")
        XCTAssertNotEqual(try fixture.git(["rev-parse", "HEAD"]), headBefore)
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("external edit 中文\n".utf8))
    }

    func testIgnoreMenuRejectsTrackedChangesAndWritesLiteralUntrackedRule() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let tracked = try fixture.file("tracked.txt", text: "baseline\n")
        try fixture.initializeGit()
        let originalHead = try fixture.git(["rev-parse", "HEAD"])
        try "changed tracked content\n".write(to: tracked, atomically: true, encoding: .utf8)
        let ignored = try fixture.file("literal?.txt", text: "new file\n")
        let intent = try fixture.file("intent-added.txt", text: "index intent\n")
        try fixture.git(["add", "-N", "--", "intent-added.txt"])

        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 20))
        let window = app.windows.firstMatch
        let trackedRow = WorkspaceUITestSupport.fileRow(tracked, in: window,
                                                        relativeTo: fixture.root)
        let ignoredRow = WorkspaceUITestSupport.fileRow(ignored, in: window,
                                                        relativeTo: fixture.root)
        let intentRow = WorkspaceUITestSupport.fileRow(intent, in: window,
                                                       relativeTo: fixture.root)
        XCTAssertTrue(trackedRow.waitForExistence(timeout: 25))
        XCTAssertTrue(intentRow.waitForExistence(timeout: 25))
        XCTAssertTrue(ignoredRow.waitForExistence(timeout: 25))
        let ignoreOption = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Add to .gitignore", "添加到 .gitignore"]
        )).firstMatch
        trackedRow.rightClick()
        XCTAssertFalse(ignoreOption.exists,
                       "Git ignore must not be offered for a tracked modification")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        intentRow.rightClick()
        XCTAssertFalse(ignoreOption.exists,
                       "Intent-to-add files are already in the index and cannot be ignored")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        ignoredRow.rightClick()
        XCTAssertTrue(ignoreOption.waitForExistence(timeout: 8),
                      "Only an untracked Git Changes row may offer Add to .gitignore")
        ignoreOption.click()

        let rule = fixture.root.appendingPathComponent(".gitignore")
        let ruleWritten = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: rule.path)
                && (try? fixture.git(["check-ignore", "--no-index", "--", "literal?.txt"])) != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ruleWritten], timeout: 20), .completed)
        XCTAssertNil(try? fixture.git(["check-ignore", "--no-index", "--", "literalX.txt"]),
                     "The literal question mark must not become a wildcard")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), originalHead)
        XCTAssertEqual(try Data(contentsOf: tracked), Data("changed tracked content\n".utf8))
        XCTAssertEqual(try Data(contentsOf: ignored), Data("new file\n".utf8))
        let status = String(decoding: try fixture.git(["status", "--porcelain=v1"]), as: UTF8.self)
        XCTAssertFalse(status.contains("literal?.txt"), "Ignored paths must leave Git Changes")
        XCTAssertTrue(status.contains("tracked.txt"), "Ignoring one path must not hide tracked edits")
        XCTAssertTrue(status.contains("intent-added.txt"), "Ignoring one path must not erase intent-to-add")
    }

    func testMergeConflictMarkResolvedStagesOnlyTheActualConflictedPath() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("conflicted.txt", text: "baseline\n")
        let sibling = try fixture.file("untouched.txt", text: "keep\n")
        try fixture.initializeGit()
        try fixture.git(["config", "user.name", "BaileyUIFixture"])
        try fixture.git(["config", "user.email", "fixture@example.invalid"])
        try fixture.git(["switch", "-c", "topic"])
        try "topic edit\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "conflicted.txt"])
        try fixture.git(["commit", "-qm", "topic edit"])
        try fixture.git(["switch", "main"])
        try "main edit\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "conflicted.txt"])
        try fixture.git(["commit", "-qm", "main edit"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertThrowsError(try fixture.git(["merge", "--no-commit", "topic"]))
        let stages = String(decoding: try fixture.git(["ls-files", "-u", "--", "conflicted.txt"]),
                            as: UTF8.self)
        XCTAssertTrue(stages.contains(" 1\tconflicted.txt"))
        XCTAssertTrue(stages.contains(" 2\tconflicted.txt"))
        XCTAssertTrue(stages.contains(" 3\tconflicted.txt"))
        let conflictBytes = try Data(contentsOf: file)
        XCTAssertTrue(String(decoding: conflictBytes, as: UTF8.self).contains("<<<<<<<"))

        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window, relativeTo: fixture.root)
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        row.rightClick()
        let resolve = app.menuItems.matching(NSPredicate(
            format: "title CONTAINS[cd] %@ OR title CONTAINS[cd] %@",
            "Mark Resolved", "标记为已解决"
        )).firstMatch
        XCTAssertTrue(resolve.waitForExistence(timeout: 8))
        XCTAssertTrue(resolve.isEnabled)
        resolve.click()

        let stageZero = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let result = try? fixture.git(["ls-files", "-u", "--", "conflicted.txt"]),
                  result.isEmpty else { return false }
            return (try? fixture.git(["show", ":conflicted.txt"])) == conflictBytes
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stageZero], timeout: 25), .completed,
                       "Mark Resolved must replace conflict stages with exactly the current worktree bytes")
        XCTAssertEqual(try Data(contentsOf: file), conflictBytes)
        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep\n".utf8))
        XCTAssertEqual(try fixture.git(["show", ":untouched.txt"]), Data("keep\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(".git/MERGE_HEAD").path),
            "Mark Resolved must not silently commit or cancel the ongoing merge")
    }

    func testFolderInlineStageAndUnstageAreScopedToThatDirectory() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let insideA = try fixture.file("selected/a.txt", text: "A old\n")
        let insideB = try fixture.file("selected/b.txt", text: "B old\n")
        let outside = try fixture.file("outside/c.txt", text: "C old\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "A new\n".write(to: insideA, atomically: true, encoding: .utf8)
        try "B new\n".write(to: insideB, atomically: true, encoding: .utf8)
        try "C new\n".write(to: outside, atomically: true, encoding: .utf8)

        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let folder = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "selected,"))
            .firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 25))

        func inlineAction(_ titles: [String]) -> XCUIElement? {
            let y = folder.frame.midY
            return window.buttons.matching(NSPredicate(format: "label IN %@", titles))
                .allElementsBoundByIndex.first { abs($0.frame.midY - y) < 5 }
        }
        let stage = try XCTUnwrap(inlineAction(["Stage Changes", "暂存更改"]),
                                  "The selected folder must expose its own inline Stage button")
        XCTAssertTrue(stage.isHittable)
        stage.click()
        let staged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":selected/a.txt"])) == Data("A new\n".utf8)
                && (try? fixture.git(["show", ":selected/b.txt"])) == Data("B new\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [staged], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["show", ":outside/c.txt"]), Data("C old\n".utf8))

        XCTAssertTrue(folder.waitForExistence(timeout: 20))
        let unstage = try XCTUnwrap(inlineAction(["Unstage Changes", "取消暂存更改"]),
                                    "The same folder must offer inline Unstage after the index changes")
        XCTAssertTrue(unstage.isHittable)
        unstage.click()
        let unstaged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":selected/a.txt"])) == Data("A old\n".utf8)
                && (try? fixture.git(["show", ":selected/b.txt"])) == Data("B old\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unstaged], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["show", ":outside/c.txt"]), Data("C old\n".utf8))
        XCTAssertEqual(try Data(contentsOf: outside), Data("C new\n".utf8))
        XCTAssertEqual(try Data(contentsOf: insideA), Data("A new\n".utf8))
        XCTAssertEqual(try Data(contentsOf: insideB), Data("B new\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data(" M outside/c.txt\n M selected/a.txt\n M selected/b.txt\n".utf8))
    }

    func testFolderStageAndUnstageTouchesOnlyNestedSelectedDirectory() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("selected/a.txt", text: "A original\n")
        let second = try fixture.file("selected/b.txt", text: "B original\n")
        let sibling = try fixture.file("untouched/c.txt", text: "C original\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "A changed\n".write(to: first, atomically: true, encoding: .utf8)
        try "B changed\n".write(to: second, atomically: true, encoding: .utf8)
        try "C changed\n".write(to: sibling, atomically: true, encoding: .utf8)

        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 20))
        let folder = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "selected,"))
            .firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 25),
                      "The default Git Changes tree must expose the selected directory")
        folder.rightClick()
        let stage = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Stage Changes", "暂存更改"]
        )).firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 8))
        stage.click()
        let folderStaged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":selected/a.txt"])) == Data("A changed\n".utf8)
                && (try? fixture.git(["show", ":selected/b.txt"])) == Data("B changed\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [folderStaged], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["show", ":untouched/c.txt"]), Data("C original\n".utf8),
                       "Staging a directory must not accidentally stage its sibling")

        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        folder.rightClick()
        let unstage = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Unstage Changes", "取消暂存更改"]
        )).firstMatch
        XCTAssertTrue(unstage.waitForExistence(timeout: 8))
        unstage.click()
        let folderUnstaged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":selected/a.txt"])) == Data("A original\n".utf8)
                && (try? fixture.git(["show", ":selected/b.txt"])) == Data("B original\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [folderUnstaged], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["show", ":untouched/c.txt"]), Data("C original\n".utf8))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("C changed\n".utf8))
        XCTAssertEqual(try Data(contentsOf: first), Data("A changed\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("B changed\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data(" M selected/a.txt\n M selected/b.txt\n M untouched/c.txt\n".utf8))
    }

    func testStageAndUnstageContextMenuChangeOnlyTheSelectedFixtureIndex() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("stage.txt", text: "committed version\n")
        let untouched = try fixture.file("untouched.txt", text: "unchanged sibling\n")
        try fixture.initializeGit()
        let headBefore = try fixture.git(["rev-parse", "HEAD"])
        try "new worktree version\n".write(to: file, atomically: true, encoding: .utf8)

        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 20))
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch,
                                                 relativeTo: fixture.root)
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        row.rightClick()
        let stage = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Stage Changes", "暂存更改"]
        )).firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 8), "Stage menu must be reachable from the real file row")
        stage.click()
        let indexStaged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":stage.txt"])) == Data("new worktree version\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [indexStaged], timeout: 15), .completed)

        let unstage = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Unstage Changes", "取消暂存更改"]
        )).firstMatch
        XCTAssertTrue(unstage.waitForExistence(timeout: 20),
                      "The staged row must expose an inline Unstage button after Git refresh")
        unstage.click()
        let indexUnstaged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":stage.txt"])) == Data("committed version\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [indexUnstaged], timeout: 15), .completed)
        XCTAssertEqual(try Data(contentsOf: file), Data("new worktree version\n".utf8))
        XCTAssertEqual(try Data(contentsOf: untouched), Data("unchanged sibling\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), headBefore)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), Data(" M stage.txt\n".utf8))
    }
}
