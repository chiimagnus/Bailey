import Foundation
import XCTest

@MainActor
final class GitUncommittedUITests: XCTestCase {
    func testResetCancelThenMixedThenHardPreservesCorrectGitBoundaries() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        try verifyIsolatedRepository(fixture)
        let tracked = try fixture.file("tracked.txt", text: "HEAD bytes\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        try "index bytes\n".write(to: tracked, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", "tracked.txt"])
        try "worktree bytes\n".write(to: tracked, atomically: true, encoding: .utf8)
        let untracked = try fixture.file("kept-untracked.txt", text: "keep this file\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        try showGit(fixture, in: app)

        func resetDialog() throws -> XCUIElement {
            try presentDialog(named: ["Reset…", "复位…"], app: app)
        }
        func clickButton(in sheet: XCUIElement, titles: [String]) {
            let button = sheet.buttons.matching(NSPredicate(format: "title IN %@", titles)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 8))
            button.click()
        }
        let first = try resetDialog()
        let mode = first.popUpButtons.firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 8))
        let initial = String(describing: mode.value ?? "")
        XCTAssertTrue(initial.contains("Mixed"), "The default reset must preserve working files")
        clickButton(in: first, titles: ["Cancel", "取消"])
        XCTAssertEqual(try fixture.git(["show", ":tracked.txt"]), Data("index bytes\n".utf8))
        XCTAssertEqual(try Data(contentsOf: tracked), Data("worktree bytes\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)

        let mixed = try resetDialog()
        clickButton(in: mixed, titles: ["Yes, Reset", "是，重置"])
        let indexReset = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["show", ":tracked.txt"])) == Data("HEAD bytes\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [indexReset], timeout: 25), .completed)
        XCTAssertEqual(try Data(contentsOf: tracked), Data("worktree bytes\n".utf8),
                       "Mixed reset must not overwrite the worktree")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)

        let hard = try resetDialog()
        let popUp = hard.popUpButtons.firstMatch
        XCTAssertTrue(popUp.waitForExistence(timeout: 8))
        popUp.click()
        let hardOption = app.menuItems.matching(NSPredicate(
            format: "title BEGINSWITH %@", "Hard"
        )).firstMatch
        XCTAssertTrue(hardOption.waitForExistence(timeout: 8),
                      "Hard must require explicitly selecting the destructive option")
        hardOption.click()
        clickButton(in: hard, titles: ["Yes, Reset", "是，重置"])
        let worktreeReset = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: tracked)) == Data("HEAD bytes\n".utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [worktreeReset], timeout: 25), .completed)
        XCTAssertEqual(try fixture.git(["show", ":tracked.txt"]), Data("HEAD bytes\n".utf8))
        XCTAssertEqual(try Data(contentsOf: untracked), Data("keep this file\n".utf8),
                       "Hard must keep unrelated ordinary untracked files")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]),
                       Data("?? kept-untracked.txt\n".utf8))
    }

    func testStashCancelThenConfirmChangesOnlyTheIsolatedRepository() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        try verifyIsolatedRepository(fixture)
        let tracked = try fixture.file("tracked.txt", text: "committed\n")
        try fixture.initializeGit()
        let originalHead = try fixture.git(["rev-parse", "HEAD"])
        try "edited\n".write(to: tracked, atomically: true, encoding: .utf8)
        let untracked = try fixture.file("new.txt", text: "untracked\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        try showGit(fixture, in: app)

        let first = try presentDialog(named: ["Stash…", "储藏…"], app: app)
        let cancel = first.buttons.matching(NSPredicate(
            format: "title IN %@", ["Cancel", "取消"]
        )).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.click()
        XCTAssertTrue(try fixture.git(["stash", "list"]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: tracked), Data("edited\n".utf8))
        XCTAssertEqual(try Data(contentsOf: untracked), Data("untracked\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), originalHead)

        let second = try presentDialog(named: ["Stash…", "储藏…"], app: app)
        let message = second.textFields.firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.click()
        message.typeText("isolated E2E stash")
        let confirm = second.buttons.matching(NSPredicate(
            format: "title IN %@", ["Yes, Stash", "是，储藏"]
        )).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        confirm.click()

        let stashed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["stash", "list"]))
                .map { String(decoding: $0, as: UTF8.self).contains("isolated E2E stash") } == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stashed], timeout: 25), .completed,
                       "A real Git stash must be created by the native sheet")
        XCTAssertEqual(try Data(contentsOf: tracked), Data("committed\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: untracked.path),
                       "Include Untracked defaults to on, so new.txt must be stashed")
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), originalHead)
    }

    func testCleanWarningCancelAndConfirmedDirectoryRemovalPreserveIgnoredFiles() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        try verifyIsolatedRepository(fixture)
        let committed = try fixture.file("tracked.txt", text: "keep me\n")
        try fixture.file(".gitignore", text: "*.ignore\n")
        try fixture.initializeGit()
        let head = try fixture.git(["rev-parse", "HEAD"])
        let untracked = try fixture.file("untracked.txt", text: "remove only on approval\n")
        let nested = try fixture.file("untracked-dir/nested.txt", text: "remove this directory\n")
        let ignored = try fixture.file("retained.ignore", text: "must never delete\n")
        let app = try WorkspaceUITestSupport.launch(in: self)
        try showGit(fixture, in: app)

        let first = try presentDialog(named: ["Clean…", "清理…"], app: app)
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR value CONTAINS %@", "Permanently delete", "永久删除"
        )).firstMatch.waitForExistence(timeout: 8),
        "Clean must warn that files and directories are permanently deleted")
        let cancel = first.buttons.matching(NSPredicate(
            format: "title IN %@", ["Cancel", "取消"]
        )).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: first
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed,
                       "Native Clean must honor its Escape cancel shortcut")
        for file in [committed, untracked, nested, ignored] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                          "Cancel must not modify the worktree: \(file.lastPathComponent)")
        }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)

        let second = try presentDialog(named: ["Clean…", "清理…"], app: app)
        let confirm = second.buttons.matching(NSPredicate(
            format: "title IN %@", ["Yes, Clean", "是，清理"]
        )).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        confirm.click()
        let cleaned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: untracked.path)
                && !FileManager.default.fileExists(atPath: nested.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cleaned], timeout: 25), .completed,
                       "Clean must act on the fixture's untracked files and directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.root.appendingPathComponent("untracked-dir").path))
        XCTAssertEqual(try Data(contentsOf: committed), Data("keep me\n".utf8))
        XCTAssertEqual(try Data(contentsOf: ignored), Data("must never delete\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertTrue(try fixture.git(["status", "--porcelain=v1"]).isEmpty)
    }

    private func verifyIsolatedRepository(_ fixture: WorkspaceUITestFixture) throws {
        let root = fixture.root.standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard root.hasPrefix(temporary + "/Bailey-UITest-") else {
            throw NSError(domain: "BaileyUITestFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Git mutations may only target a test-created temporary directory"
            ])
        }
    }

    private func showGit(_ fixture: WorkspaceUITestFixture, in app: XCUIApplication) throws {
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(WorkspaceUITestSupport.element("bailey.dock.git", in: app)
            .waitForExistence(timeout: 20))
    }

    private func presentDialog(named titles: [String], app: XCUIApplication) throws -> XCUIElement {
        let more = app.menuButtons.matching(identifier: "ellipsis").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "Git Manager's More menu is required")
        more.click()
        let option = app.menuItems.matching(NSPredicate(format: "title IN %@", titles)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 8))
        option.click()
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "The initiating window must own the native sheet")
        return sheet
    }
}
