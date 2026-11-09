import Foundation
import XCTest

@MainActor
final class GitChangesUITests: XCTestCase {
    func testCoreTimeoutKeepsFileDiffAndKeyboardBrowsingWhileGitWritesStayDisabled() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let home = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("nested/first.txt", text: "first HEAD\n")
        let second = try fixture.file("nested/second.txt", text: "second HEAD\n")
        try fixture.initializeGit()
        try "first INDEX\n".write(to: first, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "nested/first.txt"])
        try "first WORKTREE\n".write(to: first, atomically: true, encoding: .utf8)
        try "second WORKTREE\n".write(to: second, atomically: true, encoding: .utf8)
        let head = try fixture.git(["rev-parse", "HEAD"])
        let status = try fixture.git(["--no-optional-locks", "status", "--porcelain=v1"])
        let failure = home.root.appendingPathComponent("fail-status")
        let quotedFailure = "'" + failure.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try fixture.git(["config", "core.fsmonitor",
                         "if test -f \(quotedFailure); then /bin/rm -f \(quotedFailure); /bin/sleep 20; fi; false"])
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: home.root, project: fixture.root
        )
        let projectRow = app.buttons.matching(identifier: "bailey.project.row")
            .matching(NSPredicate(format: "label CONTAINS %@", fixture.root.path)).firstMatch
        XCTAssertTrue(projectRow.waitForExistence(timeout: 15))
        projectRow.click()
        let projectWindow = app.windows.containing(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "bailey.project.row", fixture.root.path
        )).firstMatch
        let window = app.windows.matching(identifier: projectWindow.identifier).firstMatch
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(window.buttons["Refresh Git Status"].waitForExistence(timeout: 15))
        let firstRows = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", nested/first.txt"))
        let secondRow = WorkspaceUITestSupport.fileRow(second, in: window, relativeTo: fixture.root)
        guard firstRows.element(boundBy: 1).waitForExistence(timeout: 25),
              secondRow.waitForExistence(timeout: 25) else {
            return XCTFail("The real Git snapshot must load before injecting failure:\n\(window.debugDescription)")
        }
        try Data("one-shot core timeout\n".utf8).write(to: failure)
        window.buttons["Refresh Git Status"].click()
        let warning = window.staticTexts["Git Status Unavailable"]
        XCTAssertTrue(warning.waitForExistence(timeout: 25), "A real core command timeout is the prerequisite")
        XCTAssertTrue(window.staticTexts["Git did not respond in time."].exists)
        let changedFolder = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "nested,")).element(boundBy: 1)
        XCTAssertTrue(changedFolder.exists)
        changedFolder.click()
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !secondRow.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
        changedFolder.click()
        XCTAssertTrue(secondRow.waitForExistence(timeout: 5))
        app.typeKey("a", modifierFlags: [.command])
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            firstRows.element(boundBy: 0).isSelected && firstRows.element(boundBy: 1).isSelected
                && secondRow.isSelected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(secondRow.isSelected)

        func expectSplit(old: String, new: String, worktree: Bool = false) {
            if worktree {
                XCTAssertFalse(window.radioGroups["bailey.diff.mode"].exists)
                let editor = window.textViews["bailey.diff.worktree"]
                let actual = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    editor.exists && (editor.value as? String) == new
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [actual], timeout: 15), .completed,
                               "Worktree must expose its exact editable contents without a mode switch")
                return
            }
            let layout = window.radioGroups["bailey.diff.layout"]
            XCTAssertTrue(layout.waitForExistence(timeout: 15))
            guard layout.exists else { return }
            layout.radioButtons.element(boundBy: 1).click()
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let values = Set(window.textViews.allElementsBoundByIndex.compactMap { $0.value as? String })
                return values.contains(old) && values.contains(new)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 15), .completed,
                           "Expected \(old) → \(new); actual native text: \(window.textViews.allElementsBoundByIndex.compactMap { $0.value as? String })")
        }

        firstRows.element(boundBy: 0).click()
        expectSplit(old: "first HEAD\n", new: "first INDEX\n")
        firstRows.element(boundBy: 1).click()
        expectSplit(old: "first INDEX\n", new: "first WORKTREE\n", worktree: true)
        firstRows.element(boundBy: 1).click()
        secondRow.rightClick()
        let stage = app.menuItems["Stage Changes"]
        XCTAssertTrue(stage.waitForExistence(timeout: 8))
        XCTAssertFalse(stage.isEnabled, "A readable snapshot must not authorize writes")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        expectSplit(old: "second HEAD\n", new: "second WORKTREE\n", worktree: true)
        secondRow.rightClick()
        let openHead = app.menuItems["Open HEAD File"]
        XCTAssertTrue(openHead.waitForExistence(timeout: 8))
        openHead.click()
        let historical = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.textViews.allElementsBoundByIndex.contains { ($0.value as? String) == "second HEAD\n" }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [historical], timeout: 15), .completed)
        secondRow.rightClick()
        let openFile = app.menuItems["Open File"]
        XCTAssertTrue(openFile.waitForExistence(timeout: 8))
        XCTAssertTrue(openFile.isEnabled)
        openFile.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(second, in: window).waitForExistence(timeout: 15))
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.textViews.allElementsBoundByIndex.contains { ($0.value as? String) == "second WORKTREE\n" }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 15), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["--no-optional-locks", "status", "--porcelain=v1"]), status)
        XCTAssertEqual(try fixture.git(["show", ":nested/first.txt"]), Data("first INDEX\n".utf8))

        XCTAssertFalse(FileManager.default.fileExists(atPath: failure.path),
                       "The one-shot hook must have entered its controlled timeout")
        window.buttons["Retry"].click()
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !warning.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 20), .completed)
        secondRow.rightClick()
        XCTAssertTrue(stage.waitForExistence(timeout: 8))
        XCTAssertTrue(stage.isEnabled)
        stage.click()
        let staged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":nested/second.txt"])) == Data("second WORKTREE\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [staged], timeout: 15), .completed)
        XCTAssertEqual(try Data(contentsOf: first), Data("first WORKTREE\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second WORKTREE\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
    }

    func testRightClickAnotherGitChangeMovesKeyboardCursorWithoutOpeningDiff() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("alpha.txt", text: "first old\n")
        let second = try fixture.file("beta.txt", text: "second old\n")
        try fixture.initializeGit()
        try "first new\n".write(to: first, atomically: true, encoding: .utf8)
        try "second new\n".write(to: second, atomically: true, encoding: .utf8)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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

    func testSwitchingActiveDiffTabsRevealsOnlyMatchingGitChange() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("reveal-one.txt", text: "one before\n")
        let second = try fixture.file("reveal-two.txt", text: "two before\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "one after\n".write(to: first, atomically: true, encoding: .utf8)
        try "two after\n".write(to: second, atomically: true, encoding: .utf8)

        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window, relativeTo: fixture.root)
        let secondRow = WorkspaceUITestSupport.fileRow(second, in: window, relativeTo: fixture.root)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 25))
        XCTAssertTrue(secondRow.waitForExistence(timeout: 25))
        firstRow.click()
        secondRow.click()

        let firstTab = window.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "reveal-one.txt"
        )).firstMatch
        let secondTab = window.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "reveal-two.txt"
        )).firstMatch
        XCTAssertTrue(firstTab.waitForExistence(timeout: 15))
        XCTAssertTrue(secondTab.waitForExistence(timeout: 15))

        for (tab, selected, other) in [
            (firstTab, firstRow, secondRow),
            (secondTab, secondRow, firstRow),
            (firstTab, firstRow, secondRow)
        ] {
            tab.click()
            let expected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "selected == true"), object: selected
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed,
                           "The selected Git row must follow the explicitly active Diff tab")
            XCTAssertFalse(other.isSelected,
                           "The former Diff must not retain an independent SCM selection")
        }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data(" M reveal-one.txt\n M reveal-two.txt\n".utf8))
        XCTAssertEqual(try Data(contentsOf: first), Data("one after\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two after\n".utf8))
    }

    func testFilesGitGraphDockAndPaletteKeepOneRealTargetThroughSwitches() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("chain-first.txt", text: "first committed\n")
        let middle = try fixture.file("chain-middle.txt", text: "middle committed\n")
        let last = try fixture.file("chain-last.txt", text: "last committed\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "first changed\n".write(to: first, atomically: true, encoding: .utf8)
        try "last changed\n".write(to: last, atomically: true, encoding: .utf8)

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let fileFirst = WorkspaceUITestSupport.fileRow(first, in: window)
        let fileMiddle = WorkspaceUITestSupport.fileRow(middle, in: window)
        let fileLast = WorkspaceUITestSupport.fileRow(last, in: window)
        XCTAssertTrue(fileLast.waitForExistence(timeout: 20))
        fileFirst.click()
        XCUIElement.perform(withKeyModifiers: .command) { fileLast.click() }
        XCTAssertTrue(fileFirst.isSelected && fileLast.isSelected && !fileMiddle.isSelected,
                      "Modifier click must retain the prior Files selection")
        fileMiddle.rightClick()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(fileFirst.isSelected && fileLast.isSelected && !fileMiddle.isSelected,
                      "Context cancellation must preserve the Files selection")

        fileFirst.doubleClick()
        let firstTab = WorkspaceUITestSupport.fileTab(first, in: window)
        XCTAssertTrue(firstTab.waitForExistence(timeout: 15))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let gitFirst = WorkspaceUITestSupport.fileRow(first, in: window, relativeTo: fixture.root)
        let gitLast = WorkspaceUITestSupport.fileRow(last, in: window, relativeTo: fixture.root)
        XCTAssertTrue(gitLast.waitForExistence(timeout: 25))
        gitLast.click()
        gitFirst.click()
        XCTAssertTrue(gitFirst.isSelected && !gitLast.isSelected,
                      "The selected Git resource must follow the active Diff")

        let commit = app.buttons["E2E fixture history"]
        XCTAssertTrue(commit.waitForExistence(timeout: 20))
        commit.click()
        let historyFirst = window.descendants(matching: .any)
            .matching(identifier: "bailey.git.history.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", chain-first.txt"))
            .firstMatch
        XCTAssertTrue(historyFirst.waitForExistence(timeout: 15))
        historyFirst.click()
        let historicalContent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.textViews.allElementsBoundByIndex.contains {
                ($0.value as? String)?.contains("first committed\n") == true
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [historicalContent], timeout: 15), .completed,
                       "Graph history must display the committed file, not its changed working copy")
        XCTAssertTrue(historyFirst.isSelected,
                      "Clicking a historical row explicitly selects that Graph resource")
        app.typeKey("p", modifierFlags: .command)
        let palette = window.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(palette.waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(palette.waitForNonExistence(timeout: 5),
                      "Escape must close the empty palette rather than reach the underlying editor")

        app.typeKey("e", modifierFlags: [.command, .shift])
        firstTab.click()
        XCTAssertTrue(fileFirst.isSelected && !fileMiddle.isSelected && !fileLast.isSelected,
                      "Returning to the active editor must reveal only its real Files row")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let revealed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: gitFirst
        )
        XCTAssertEqual(XCTWaiter.wait(for: [revealed], timeout: 8), .completed)
        XCTAssertFalse(gitLast.isSelected)

        gitFirst.rightClick()
        let stage = app.menuItems["Stage Changes"]
        XCTAssertTrue(stage.waitForExistence(timeout: 10))
        stage.click()
        let staged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":chain-first.txt"])) == Data("first changed\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [staged], timeout: 20), .completed,
                       "Stage must update the real index of the revealed file")
        XCTAssertEqual(try fixture.git(["show", ":chain-last.txt"]),
                       Data("last committed\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)

        let stagedFirst = WorkspaceUITestSupport.fileRow(first, in: window, relativeTo: fixture.root)
        XCTAssertTrue(stagedFirst.waitForExistence(timeout: 15))
        stagedFirst.rightClick()
        let unstage = app.menuItems["Unstage Changes"]
        XCTAssertTrue(unstage.waitForExistence(timeout: 10))
        unstage.click()
        let unstaged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["diff", "--cached", "--name-only"]))?.isEmpty == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unstaged], timeout: 20), .completed,
                       "Unstage must restore only the original index contents")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["diff", "--cached", "--name-only"]).isEmpty)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data(" M chain-first.txt\n M chain-last.txt\n".utf8))
        XCTAssertEqual(try Data(contentsOf: first), Data("first changed\n".utf8))
        XCTAssertEqual(try Data(contentsOf: middle), Data("middle committed\n".utf8))
        XCTAssertEqual(try Data(contentsOf: last), Data("last changed\n".utf8))
    }

    func testReturningToGitAfterOpeningOrdinaryFileRevealsOnlyMatchingChange() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("ordinary-match.txt", text: "first original\n")
        let second = try fixture.file("ordinary-other.txt", text: "second original\n")
        let unchanged = try fixture.file("ordinary-clean.txt", text: "untouched\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "first edited\n".write(to: first, atomically: true, encoding: .utf8)
        try "second edited\n".write(to: second, atomically: true, encoding: .utf8)
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        let window = app.windows.firstMatch
        app.typeKey("g", modifierFlags: [.command, .shift])
        let secondChange = WorkspaceUITestSupport.fileRow(second, in: window, relativeTo: fixture.root)
        XCTAssertTrue(secondChange.waitForExistence(timeout: 20))
        secondChange.click()

        app.typeKey("e", modifierFlags: [.command, .shift])
        let firstFile = WorkspaceUITestSupport.fileRow(first, in: window)
        XCTAssertTrue(firstFile.waitForExistence(timeout: 15))
        firstFile.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(first, in: window).waitForExistence(timeout: 15))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let firstChange = WorkspaceUITestSupport.fileRow(first, in: window, relativeTo: fixture.root)
        XCTAssertTrue(firstChange.waitForExistence(timeout: 15))
        let revealed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: firstChange
        )
        XCTAssertEqual(XCTWaiter.wait(for: [revealed], timeout: 8), .completed,
                       "Returning to Git must reveal the last explicitly opened ordinary file")
        XCTAssertFalse(secondChange.isSelected)

        app.typeKey("e", modifierFlags: [.command, .shift])
        let cleanFile = WorkspaceUITestSupport.fileRow(unchanged, in: window)
        XCTAssertTrue(cleanFile.waitForExistence(timeout: 15))
        cleanFile.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(unchanged, in: window).waitForExistence(timeout: 15))
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(firstChange.isSelected,
                      "An unchanged file must not clear the last valid Git selection")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data(" M ordinary-match.txt\n M ordinary-other.txt\n".utf8))
    }

    func testActiveStagedAndWorktreeDiffTabsChooseDifferentRowsForOnePath() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("same-path.txt", text: "HEAD\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "INDEX\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "same-path.txt"])
        try "WORKTREE\n".write(to: file, atomically: true, encoding: .utf8)

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let rows = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", same-path.txt"))
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 25))
        rows.element(boundBy: 0).click()
        rows.element(boundBy: 1).click()

        let stagedTab = window.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "same-path.txt", "Staged"
        )).firstMatch
        let workingTab = window.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND NOT label CONTAINS %@", "same-path.txt", "Staged"
        )).firstMatch
        XCTAssertTrue(stagedTab.waitForExistence(timeout: 15))
        XCTAssertTrue(workingTab.waitForExistence(timeout: 15))

        for (tab, selected, other) in [
            (stagedTab, rows.element(boundBy: 0), rows.element(boundBy: 1)),
            (workingTab, rows.element(boundBy: 1), rows.element(boundBy: 0))
        ] {
            tab.click()
            let expected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "selected == true"), object: selected
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed)
            XCTAssertFalse(other.isSelected, "The other side of the same path must not be selected")
        }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["show", ":same-path.txt"]), Data("INDEX\n".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("WORKTREE\n".utf8))
    }

    func testFocusedCommitShortcutUsesLatestDraftAndWritesOnlyStagedChanges() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let staged = try fixture.file("staged.txt", text: "before\n")
        let unstaged = try fixture.file("unstaged.txt", text: "stay\n")
        try fixture.initializeGit()
        try "staged change\n".write(to: staged, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "staged.txt"])
        try "unstaged change\n".write(to: unstaged, atomically: true, encoding: .utf8)
        let before = try fixture.git(["rev-parse", "HEAD"])

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        let window = app.windows.firstMatch
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app, in: window)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let input = WorkspaceUITestSupport.element("bailey.git.commit.message", in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 25))
        input.click()
        input.typeText("outdated message")
        input.typeKey("a", modifierFlags: .command)
        input.typeText("latest focused commit message")
        XCTAssertEqual(input.value as? String, "latest focused commit message")

        app.typeKey(XCUIKeyboardKey.return, modifierFlags: .command)
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["log", "-1", "--format=%s"])) ==
                Data("latest focused commit message\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 20), .completed,
                       "⌘Return must execute the currently focused Git panel's live commit action")
        XCTAssertNotEqual(try fixture.git(["rev-parse", "HEAD"]), before)
        XCTAssertEqual(try fixture.git(["show", "HEAD:staged.txt"]), Data("staged change\n".utf8))
        XCTAssertEqual(try fixture.git(["show", "HEAD:unstaged.txt"]), Data("stay\n".utf8))
        XCTAssertEqual(try Data(contentsOf: unstaged), Data("unstaged change\n".utf8))
        XCTAssertEqual(try fixture.git(["diff", "--cached", "--name-only"]), Data())
    }

    func testRealBaileySourceHistoryDiffLoadsAcrossIndexWorktreeAndOtherSource() throws {
        // This is the Bailey source repository's actual history and source bytes,
        // not a synthetic Git snapshot. All mutations stay in a temporary clone.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try WorkspaceUITestFixture(in: self)
        try fixture.git(["clone", "--local", "--no-hardlinks", "--single-branch", source.path, "."])
        let relativeDiff = "Bailey/Git/DiffViewerView.swift"
        let relativeTree = "Bailey/Shared/Tree/TreeRowStyle.swift"
        let diff = fixture.root.appendingPathComponent(relativeDiff)
        let tree = fixture.root.appendingPathComponent(relativeTree)
        func priorSource(_ path: String) throws -> Data {
            let history = String(decoding: try fixture.git(["log", "-2", "--format=%H", "--", path]),
                                 as: UTF8.self).split(separator: "\n")
            let previous = try XCTUnwrap(history.dropFirst().first,
                                        "An actual earlier Bailey source revision is required")
            return try fixture.git(["show", "\(previous):\(path)"])
        }
        let currentDiff = try Data(contentsOf: diff)
        let previousDiff = try priorSource(relativeDiff)
        let currentTree = try Data(contentsOf: tree)
        let previousTree = try priorSource(relativeTree)
        XCTAssertNotEqual(currentDiff, previousDiff)
        XCTAssertNotEqual(currentTree, previousTree)
        let head = try fixture.git(["rev-parse", "HEAD"])

        try previousDiff.write(to: diff)
        try fixture.git(["add", "--", relativeDiff])
        try currentDiff.write(to: diff)
        try previousTree.write(to: tree)
        let status = try fixture.git(["status", "--porcelain=v1"])
        XCTAssertEqual(String(decoding: status, as: UTF8.self),
                       "MM " + relativeDiff + "\n M " + relativeTree + "\n")
        func changedLine(_ args: [String]) throws -> String {
            let patch = String(decoding: try fixture.git(args), as: UTF8.self)
            let lines = patch.split(separator: "\n")
            let candidate = lines.first { line in
                line.hasPrefix("+") && !line.hasPrefix("+++")
                    && line.dropFirst().trimmingCharacters(in: .whitespaces).count > 18
            } ?? lines.first { line in
                line.hasPrefix("-") && !line.hasPrefix("---")
                    && line.dropFirst().trimmingCharacters(in: .whitespaces).count > 18
            }
            return try XCTUnwrap(candidate.map { String($0.dropFirst())
                .trimmingCharacters(in: .whitespaces) },
                "A real source change needs an identifiable added or removed line")
        }
        let stagedMarker = try changedLine(["diff", "--cached", "--unified=0", "--", relativeDiff])
        let worktreeMarker = try changedLine(["diff", "--unified=0", "--", relativeDiff])
        let otherMarker = try changedLine(["diff", "--unified=0", "--", relativeTree])

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let all = window.descendants(matching: .any).matching(identifier: "bailey.tree.file")
        let first = all.matching(NSPredicate(format: "label ENDSWITH %@",
                                            ", " + relativeDiff))
        let staged = first.element(boundBy: 0)
        let worktree = first.element(boundBy: 1)
        let other = all.matching(NSPredicate(format: "label ENDSWITH %@",
                                            ", " + relativeTree)).firstMatch
        XCTAssertTrue(worktree.waitForExistence(timeout: 35),
                      "The real Bailey source must expose both index and worktree changes")
        XCTAssertTrue(other.waitForExistence(timeout: 20))

        staged.click()
        let layout = window.radioGroups["bailey.diff.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 25))
        layout.radioButtons.element(boundBy: 1).click()
        let stageReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.textViews.allElementsBoundByIndex.contains {
                ($0.value as? String)?.contains(stagedMarker) == true
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stageReady], timeout: 25), .completed,
                       "Actual prior Bailey source must be visible as a staged native Diff")

        func verifyEditableSource(after clicking: XCUIElement, text: Data,
                                  previewMarker: String) {
            clicking.click()
            XCTAssertTrue(layout.waitForExistence(timeout: 25))
            layout.radioButtons.element(boundBy: 0).click()
            let editor = window.textViews["bailey.diff.worktree"]
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (editor.value as? String) == String(decoding: text, as: UTF8.self)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 25), .completed,
                           "The same folded editable TextKit document owns all real Bailey bytes")
            XCTAssertTrue((editor.value as? String ?? "").contains(previewMarker))
            let folded = window.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "unmodified lines")
            ).firstMatch
            XCTAssertTrue(folded.waitForExistence(timeout: 15))
            let label = folded.label
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).click()
            XCTAssertEqual(folded.label, label,
                           "Ordinary clicking in a real source Diff must not expand any fold")
        }
        verifyEditableSource(after: worktree, text: currentDiff,
                             previewMarker: worktreeMarker)
        verifyEditableSource(after: other, text: previousTree,
                             previewMarker: otherMarker)

        staged.click()
        XCTAssertTrue(layout.waitForExistence(timeout: 25))
        worktree.click()
        let editor = window.textViews["bailey.diff.worktree"]
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (editor.value as? String) == String(decoding: currentDiff, as: UTF8.self)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 25), .completed)
        XCTAssertEqual(try Data(contentsOf: diff), currentDiff)
        XCTAssertEqual(try Data(contentsOf: tree), previousTree)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), status)
        XCTAssertEqual(try fixture.git(["show", ":" + relativeDiff]), previousDiff)
    }

    func testRapidStagedWorktreeAndOtherDiffSwitchesFinishAtLatestSelectedFile() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let baseline = (0..<18_000).map { "let value\($0) = \($0)\n" }
        let first = try fixture.file("src/First.swift", text: baseline.joined())
        let second = try fixture.file("src/Second.swift", text: baseline.joined())
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])

        var index = baseline
        index[9_000] = "let value9000 = 9001 // INDEX_ONLY\n"
        try Data(index.joined().utf8).write(to: first)
        try fixture.git(["add", "--", "src/First.swift"])

        var worktree = index
        worktree[14_000] = "let value14000 = 14002 // WORKTREE_ONLY\n"
        let worktreeBytes = Data(worktree.joined().utf8)
        try worktreeBytes.write(to: first)
        var other = baseline
        other[12_000] = "let value12000 = 12003 // SECOND_ONLY\n"
        let otherBytes = Data(other.joined().utf8)
        try otherBytes.write(to: second)
        let status = try fixture.git(["status", "--porcelain=v1"])
        XCTAssertEqual(String(decoding: status, as: UTF8.self),
                       "MM src/First.swift\n M src/Second.swift\n")

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root)
        let window = app.windows.firstMatch
        app.typeKey("g", modifierFlags: [.command, .shift])
        let rows = window.descendants(matching: .any).matching(identifier: "bailey.tree.file")
        let firstRows = rows.matching(NSPredicate(format: "label ENDSWITH %@",
                                                 ", src/First.swift"))
        let staged = firstRows.element(boundBy: 0)
        let unstaged = firstRows.element(boundBy: 1)
        let independent = rows.matching(NSPredicate(format: "label ENDSWITH %@",
                                                   ", src/Second.swift")).firstMatch
        XCTAssertTrue(unstaged.waitForExistence(timeout: 30))
        XCTAssertTrue(independent.waitForExistence(timeout: 20))

        // Deliberately do not await any Diff display between these clicks.
        for target in [staged, independent, unstaged, independent, staged, unstaged] {
            target.click()
        }
        let layout = window.radioGroups["bailey.diff.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 25))
        layout.radioButtons.element(boundBy: 0).click()
        func expect(_ marker: String, not previous: String, staged: Bool = false) {
            let pane = staged ? window.textViews["bailey.diff.canonical"]
                              : window.textViews["bailey.diff.worktree"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let text = pane.value as? String else { return false }
                return pane.exists && text.contains(marker) && !text.contains(previous)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed,
                           "Rapid navigation must resolve the most recently selected Diff: \(marker)")
            XCTAssertTrue(pane.isHittable,
                          "Correct content in an invisible or stale tab does not count")
        }
        expect("WORKTREE_ONLY", not: "SECOND_ONLY")
        XCTAssertTrue(window.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "unmodified lines")
        ).firstMatch.waitForExistence(timeout: 15),
                      "The 18k-line editable worktree must still have explicit fold controls")

        independent.click()
        expect("SECOND_ONLY", not: "WORKTREE_ONLY")
        staged.click()
        expect("INDEX_ONLY", not: "WORKTREE_ONLY", staged: true)
        unstaged.click()
        expect("WORKTREE_ONLY", not: "SECOND_ONLY")
        XCTAssertTrue((window.textViews["bailey.diff.worktree"].value as? String ?? "")
            .contains("INDEX_ONLY"),
            "The worktree contains both the staged change and its own later unstaged edit")
        XCTAssertEqual(try Data(contentsOf: first), worktreeBytes)
        XCTAssertEqual(try Data(contentsOf: second), otherBytes)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), status,
                       "Fast browsing must not mutate Git or either source file")
    }

    func testComplexGitChangesPreserveEachRealDiffAcrossRepeatedBrowsing() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let baseline = (0..<3_600).map { "let line\($0) = \($0)\n" }
        let dense = try fixture.file("src/Multihunk.swift", text: baseline.joined())
        _ = try fixture.file("src/BeforeRename.swift", text: "let renamed = \"original\"\n")
        let removed = try fixture.file("src/Removed.swift", text: "let deleted = \"GONE_ONLY\"\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])

        var staged = baseline
        for row in stride(from: 30, to: 3_540, by: 180) {
            staged[row] = "let line\(row) = \(row) + 1 // INDEX_ONLY_\(row)\n"
        }
        try Data(staged.joined().utf8).write(to: dense)
        try fixture.git(["add", "--", "src/Multihunk.swift"])

        var worktree = staged
        for row in stride(from: 85, to: 3_550, by: 180) {
            worktree[row] = "let line\(row) = \(row) + 2 // WORKTREE_ONLY_\(row)\n"
        }
        worktree.removeSubrange(1_500..<1_507)
        worktree.insert("let inserted = \"INSERT_ONLY\"\n", at: 2_500)
        let rawWorktree = worktree.joined()
        try Data(rawWorktree.utf8).write(to: dense)

        try fixture.git(["mv", "src/BeforeRename.swift", "src/AfterRename.swift"])
        let renamed = fixture.root.appendingPathComponent("src/AfterRename.swift")
        try "let renamed = \"RENAMED_WORKTREE_ONLY\"\n".write(to: renamed, atomically: true,
                                                        encoding: .utf8)
        try FileManager.default.removeItem(at: removed)
        let untracked = try fixture.file("src/Untracked.swift", text: "let brandNew = \"UNTRACKED_ONLY\"\n")
        let status = try fixture.git(["status", "--porcelain=v1"])
        let statusText = String(decoding: status, as: UTF8.self)
        XCTAssertTrue(statusText.contains("MM src/Multihunk.swift"), statusText)
        XCTAssertTrue(statusText.contains("RM src/BeforeRename.swift -> src/AfterRename.swift"), statusText)
        XCTAssertTrue(statusText.contains(" D src/Removed.swift"), statusText)
        XCTAssertTrue(statusText.contains("?? src/Untracked.swift"), statusText)

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        let window = app.windows.firstMatch
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app, in: window)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let denseRows = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.file")
            .matching(NSPredicate(format: "label ENDSWITH %@",
                                  ", src/Multihunk.swift"))
        let stagedRow = denseRows.element(boundBy: 0)
        let worktreeRow = denseRows.element(boundBy: 1)
        XCTAssertTrue(worktreeRow.waitForExistence(timeout: 30),
                      "A partially staged file must have independent staged and unstaged rows")
        let layout = window.radioGroups["bailey.diff.layout"]
        let review = window.textViews["bailey.diff.canonical"]
        let editor = window.textViews["bailey.diff.worktree"]

        func expectStaged(after clicking: XCUIElement, contains marker: String,
                          excludes other: String) {
            clicking.click()
            XCTAssertTrue(layout.waitForExistence(timeout: 25))
            layout.radioButtons.element(boundBy: 0).click()
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let visible = review.value as? String else { return false }
                return review.exists && visible.contains(marker) && !visible.contains(other)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed,
                           "Staged Diff must show \(marker), not an unstaged change")
            XCTAssertTrue(review.isHittable)
        }

        expectStaged(after: stagedRow, contains: "INDEX_ONLY_30",
                     excludes: "WORKTREE_ONLY_85")
        let stagePreview = try XCTUnwrap(review.value as? String)
        XCTAssertFalse(stagePreview.contains("let line0 = 0"),
                       "Staged multi-hunk Diff must collapse distant unchanged context")

        worktreeRow.click()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (editor.value as? String) == rawWorktree
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 30), .completed,
                       "Editable Diff must own exactly the complete staged+unstaged source")
        let fold = window.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "unmodified lines")
        ).firstMatch
        XCTAssertTrue(fold.waitForExistence(timeout: 15))
        let originalLabel = fold.label
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)).click()
        XCTAssertEqual(fold.label, originalLabel,
                       "A code click must not unfold a complex multi-hunk Diff")

        expectStaged(after: stagedRow, contains: "INDEX_ONLY_30",
                     excludes: "WORKTREE_ONLY_85")
        let renameRows = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", src/AfterRename.swift"))
        let renamedStaged = renameRows.element(boundBy: 0)
        let renamedWorktree = renameRows.element(boundBy: 1)
        XCTAssertTrue(renamedWorktree.waitForExistence(timeout: 15),
                      "A staged rename with further edits must expose both stage sides")
        renamedStaged.click()
        renamedWorktree.click()
        let renamedVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.textViews.allElementsBoundByIndex.contains {
                ($0.value as? String)?.contains("RENAMED_WORKTREE_ONLY") == true
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [renamedVisible], timeout: 20), .completed,
                       "The renamed worktree file must use its actual new path")

        let removedRow = WorkspaceUITestSupport.fileRow(removed, in: window, relativeTo: fixture.root)
        XCTAssertTrue(removedRow.waitForExistence(timeout: 15))
        removedRow.click()
        let removedVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (review.value as? String)?.contains("GONE_ONLY") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removedVisible], timeout: 20), .completed,
                       "A deleted file must still show its old text instead of a blank Diff")
        XCTAssertTrue(review.isHittable)

        let untrackedRow = WorkspaceUITestSupport.fileRow(untracked, in: window,
                                                           relativeTo: fixture.root)
        XCTAssertTrue(untrackedRow.waitForExistence(timeout: 15))
        untrackedRow.click()
        let untrackedVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (editor.value as? String)?.contains("UNTRACKED_ONLY") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [untrackedVisible], timeout: 20), .completed,
                       "An untracked source must not retain a previous file's document")
        XCTAssertTrue(editor.isHittable)

        worktreeRow.click()
        XCTAssertEqual(editor.value as? String, rawWorktree)
        XCTAssertEqual(try Data(contentsOf: dense), Data(rawWorktree.utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), status,
                       "Preview browsing must never stage, discard or write Git changes")
    }

    func testStagedAndUnstagedRowsPreviewTheirDistinctGitBaselines() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("index-side.txt", text: "HEAD contents\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "INDEX contents\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "index-side.txt"])
        try "WORKTREE contents\n".write(to: file, atomically: true, encoding: .utf8)

        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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
        // The worktree is editable; its immutable index baseline stays in Git.
        XCTAssertFalse(window.radioGroups["bailey.diff.mode"].exists)
        let worktreeEditor = window.textViews["bailey.diff.worktree"]
        XCTAssertTrue(worktreeEditor.waitForExistence(timeout: 15))
        XCTAssertEqual(worktreeEditor.value as? String, "WORKTREE contents\n")
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
        _ = try fixture.file("nested/history.txt", text: "nested committed\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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
        let folder = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "nested")).firstMatch
        guard folder.waitForExistence(timeout: 10) else {
            return XCTFail("The historical directory must be rendered before checking its Focus")
        }
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        XCTAssertFalse(folder.isSelected, "Graph directory Focus must not manufacture AX Selection")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        let nested = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "bailey.git.history.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", nested/history.txt")).firstMatch
        XCTAssertTrue(nested.waitForExistence(timeout: 10))
        XCTAssertFalse(nested.isSelected, "A focused historical file is not a selected resource")
        app.typeKey(" ", modifierFlags: [])
        let displayed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.textViews.allElementsBoundByIndex.contains {
                ($0.value as? String)?.contains("nested committed") == true
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [displayed], timeout: 15), .completed,
                       "Space must reach the focused file's real historical Diff before checking its AX state")
        XCTAssertTrue(nested.isSelected,
                      "Space explicitly selects the focused Graph file when opening its Diff")
        nested.rightClick()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(nested.isSelected,
                      "Canceling the context menu must preserve the explicit Selection")
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
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 20))
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window, relativeTo: fixture.root)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 25))
        firstRow.click()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("p", modifierFlags: .command)
        let search = window.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5),
                      "Escape must dismiss an empty palette before Git keyboard navigation resumes")
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(" ", modifierFlags: [])
        let pane = window.textViews["bailey.diff.worktree"]
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

        let app = try WorkspaceUITestSupport.launch(in: self, project: firstFixture.root)
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
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 15))
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

        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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

        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 15),
                      "A real Git Changes click must open its native editable Diff")

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

        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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

        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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

        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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

        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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

    func testGitMultiSelectCommandShiftAndContextBatchStageRealIndex() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let names = ["a", "b", "c", "d", "e"]
        let files = try names.map { name in
            try fixture.file("select-\(name).txt", text: "\(name) before\n")
        }
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        for (name, file) in zip(names, files) {
            try "\(name) after\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let rows = files.map {
            WorkspaceUITestSupport.fileRow($0, in: window, relativeTo: fixture.root)
        }
        XCTAssertTrue(rows[4].waitForExistence(timeout: 25))
        rows[0].click()
        XCUIElement.perform(withKeyModifiers: .command) { rows[2].click() }
        XCTAssertTrue(rows[0].isSelected && rows[2].isSelected)
        XCTAssertFalse(rows[1].isSelected, "Cmd-click must toggle only the clicked Git resource")
        XCUIElement.perform(withKeyModifiers: .shift) { rows[4].click() }
        XCTAssertTrue(rows[0].isSelected && rows[2].isSelected
            && rows[3].isSelected && rows[4].isSelected)
        XCUIElement.perform(withKeyModifiers: .shift) { rows[3].click() }
        XCTAssertTrue(rows[0].isSelected && rows[2].isSelected && rows[3].isSelected)
        XCTAssertFalse(rows[1].isSelected || rows[4].isSelected)

        rows[2].rightClick()
        let stage = app.menuItems["Stage Changes"]
        XCTAssertTrue(stage.waitForExistence(timeout: 8))
        stage.click()
        let staged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ["a", "c", "d"].allSatisfy { name in
                (try? fixture.git(["show", ":select-\(name).txt"]))
                    == Data("\(name) after\n".utf8)
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [staged], timeout: 25), .completed,
                       "Selected SCM resources must be staged in one actual index operation")
        for name in ["b", "e"] {
            XCTAssertEqual(try fixture.git(["show", ":select-\(name).txt"]),
                           Data("\(name) before\n".utf8))
        }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        for (name, file) in zip(names, files) {
            XCTAssertEqual(try Data(contentsOf: file), Data("\(name) after\n".utf8))
        }
    }

    func testGitMultiSelectContextOutsideSetChangesOnlyClickedIndexPath() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let names = ["alpha", "beta", "gamma"]
        let files = try names.map { try fixture.file("group-\($0).txt", text: "\($0) old\n") }
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        for (name, file) in zip(names, files) {
            try "\(name) new\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let rows = files.map {
            WorkspaceUITestSupport.fileRow($0, in: app.windows.firstMatch, relativeTo: fixture.root)
        }
        XCTAssertTrue(rows[2].waitForExistence(timeout: 25))
        rows[0].click()
        XCUIElement.perform(withKeyModifiers: .command) { rows[2].click() }
        XCTAssertTrue(rows[0].isSelected && rows[2].isSelected)

        rows[1].rightClick()
        let stage = app.menuItems["Stage Changes"]
        XCTAssertTrue(stage.waitForExistence(timeout: 8))
        stage.click()
        let onlyContext = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":group-beta.txt"])) == Data("beta new\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [onlyContext], timeout: 20), .completed)
        XCTAssertEqual(try fixture.git(["show", ":group-alpha.txt"]), Data("alpha old\n".utf8))
        XCTAssertEqual(try fixture.git(["show", ":group-gamma.txt"]), Data("gamma old\n".utf8))
        XCTAssertTrue(rows[0].isSelected && rows[2].isSelected,
                      "SCM context-click outside Selection must not replace the prior set")

        rows[2].rightClick()
        XCTAssertTrue(stage.waitForExistence(timeout: 8))
        stage.click()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":group-alpha.txt"])) == Data("alpha new\n".utf8)
                && (try? fixture.git(["show", ":group-gamma.txt"])) == Data("gamma new\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 20), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        for (name, file) in zip(names, files) {
            XCTAssertEqual(try Data(contentsOf: file), Data("\(name) new\n".utf8))
        }
    }

    func testGitSelectAllEscapeAndKeyboardShiftRangeDoNotChangeGitIndex() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let names = ["a", "b", "c"]
        let files = try names.map { try fixture.file("keys-\($0).txt", text: "\($0) old\n") }
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        for (name, file) in zip(names, files) {
            try "\(name) new\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let rows = files.map {
            WorkspaceUITestSupport.fileRow($0, in: app.windows.firstMatch, relativeTo: fixture.root)
        }
        XCTAssertTrue(rows[2].waitForExistence(timeout: 25))
        rows[0].click()
        app.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(rows.allSatisfy(\.isSelected), "Cmd-A must select only Git resource rows")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(rows.contains(where: \.isSelected), "Escape must only clear Git Selection")

        rows[0].click()
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .shift)
        XCTAssertTrue(rows[0].isSelected && rows[1].isSelected && !rows[2].isSelected)
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: .shift)
        XCTAssertTrue(rows.allSatisfy(\.isSelected))
        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: .shift)
        XCTAssertTrue(rows[0].isSelected && rows[1].isSelected && !rows[2].isSelected)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        for (name, file) in zip(names, files) {
            XCTAssertEqual(try fixture.git(["show", ":keys-\(name).txt"]), Data("\(name) old\n".utf8))
            XCTAssertEqual(try Data(contentsOf: file), Data("\(name) new\n".utf8))
        }
    }

    func testGitMultiSelectedDiscardCancelAndConfirmPreservesUnselectedWorkingFile() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let names = ["discard-a", "discard-b", "discard-c"]
        let files = try names.map { try fixture.file("\($0).txt", text: "\($0) before\n") }
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        for (name, file) in zip(names, files) {
            try "\(name) after\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let rows = files.map {
            WorkspaceUITestSupport.fileRow($0, in: app.windows.firstMatch, relativeTo: fixture.root)
        }
        XCTAssertTrue(rows[2].waitForExistence(timeout: 25))
        XCUIElement.perform(withKeyModifiers: .command) { rows[0].click() }
        XCUIElement.perform(withKeyModifiers: .command) { rows[2].click() }
        XCTAssertTrue(rows[0].isSelected && rows[2].isSelected)

        func requestDiscard() {
            rows[0].rightClick()
            let action = app.menuItems["Discard Changes…"]
            XCTAssertTrue(action.waitForExistence(timeout: 8))
            action.click()
        }
        requestDiscard()
        let cancel = app.windows.firstMatch.sheets.firstMatch.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10),
                      "The multi-resource destructive action must open native confirmation")
        cancel.click()
        for (name, file) in zip(names, files) {
            XCTAssertEqual(try Data(contentsOf: file), Data("\(name) after\n".utf8))
            XCTAssertEqual(try fixture.git(["show", ":\(name).txt"]), Data("\(name) before\n".utf8))
        }
        XCTAssertTrue(rows[0].isSelected && rows[2].isSelected,
                      "Cancel must preserve the selected resources without changing bytes")

        requestDiscard()
        let confirm = app.windows.firstMatch.sheets.firstMatch.buttons["Discard Changes"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.click()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: files[0])) == Data("discard-a before\n".utf8)
                && (try? Data(contentsOf: files[2])) == Data("discard-c before\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 25), .completed)
        XCTAssertEqual(try Data(contentsOf: files[1]), Data("discard-b after\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        for name in names {
            XCTAssertEqual(try fixture.git(["show", ":\(name).txt"]),
                           Data("\(name) before\n".utf8))
        }
    }

    func testGitMultiSelectSamePathAcrossStagedAndChangesKeepsActionSectionsDistinct() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("both-sides.txt", text: "HEAD\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "INDEX\n".write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "both-sides.txt"])
        try "WORKTREE\n".write(to: file, atomically: true, encoding: .utf8)

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let rows = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "bailey.tree.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", both-sides.txt"))
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 25))
        let staged = rows.element(boundBy: 0)
        let changes = rows.element(boundBy: 1)
        staged.click()
        XCUIElement.perform(withKeyModifiers: .command) { changes.click() }
        XCTAssertTrue(staged.isSelected && changes.isSelected,
                      "Same path in STAGED and CHANGES must remain two selectable resources")

        changes.rightClick()
        let stage = app.menuItems["Stage Changes"]
        XCTAssertTrue(stage.waitForExistence(timeout: 8))
        stage.click()
        let stagedNew = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":both-sides.txt"])) == Data("WORKTREE\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stagedNew], timeout: 20), .completed)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data("M  both-sides.txt\n".utf8))

        let refreshed = rows.element(boundBy: 0)
        XCTAssertTrue(refreshed.waitForExistence(timeout: 15))
        refreshed.rightClick()
        let unstage = app.menuItems["Unstage Changes"]
        XCTAssertTrue(unstage.waitForExistence(timeout: 8))
        unstage.click()
        let restoredIndex = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":both-sides.txt"])) == Data("HEAD\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restoredIndex], timeout: 20), .completed)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: file), Data("WORKTREE\n".utf8))
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data(" M both-sides.txt\n".utf8))
    }

    func testGitMultiSelectDirectoryAndSeparateFileStagesOnlyExpandedPathspecs() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("bundle/a.txt", text: "A old\n")
        let second = try fixture.file("bundle/b.txt", text: "B old\n")
        let outside = try fixture.file("outside.txt", text: "outside old\n")
        let untouched = try fixture.file("untouched.txt", text: "untouched old\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        for (url, text) in [(first, "A"), (second, "B"), (outside, "outside"),
                            (untouched, "untouched")] {
            try "\(text) new\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        let folder = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.folder")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "bundle,"))
            .firstMatch
        let outsideRow = WorkspaceUITestSupport.fileRow(outside, in: window, relativeTo: fixture.root)
        XCTAssertTrue(folder.waitForExistence(timeout: 25))
        XCTAssertTrue(outsideRow.waitForExistence(timeout: 25))
        folder.click()
        XCUIElement.perform(withKeyModifiers: .command) { outsideRow.click() }
        XCTAssertTrue(folder.isSelected && outsideRow.isSelected,
                      "A directory and a leaf from another path must coexist in SCM Selection")
        folder.rightClick()
        let stage = app.menuItems["Stage Changes"]
        XCTAssertTrue(stage.waitForExistence(timeout: 8))
        stage.click()
        let staged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":bundle/a.txt"])) == Data("A new\n".utf8)
                && (try? fixture.git(["show", ":bundle/b.txt"])) == Data("B new\n".utf8)
                && (try? fixture.git(["show", ":outside.txt"])) == Data("outside new\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [staged], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["show", ":untouched.txt"]), Data("untouched old\n".utf8))
        XCTAssertEqual(try Data(contentsOf: untouched), Data("untouched new\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
    }

    func testStageAndUnstageContextMenuChangeOnlyTheSelectedFixtureIndex() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("stage.txt", text: "committed version\n")
        let untouched = try fixture.file("untouched.txt", text: "unchanged sibling\n")
        try fixture.initializeGit()
        let headBefore = try fixture.git(["rev-parse", "HEAD"])
        try "new worktree version\n".write(to: file, atomically: true, encoding: .utf8)

        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
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
