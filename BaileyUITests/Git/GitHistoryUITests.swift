import Foundation
import XCTest

@MainActor
final class GitHistoryUITests: XCTestCase {
    func testRealCommitHistoryOpensImmutableRevisionWithoutChangingWorkingFile() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let historical = "first revision 中文 👋\n"
        let current = "second revision\n"
        let file = try fixture.file("history.txt", text: historical)
        try fixture.initializeGit()
        let rootHash = try revision(in: fixture)
        try current.write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c", "user.email=tests@example.invalid",
                         "commit", "-qam", "Second revision"])
        let headHash = try revision(in: fixture)
        XCTAssertNotEqual(rootHash, headHash)
        XCTAssertEqual(try fixture.git(["show", ":history.txt"]), Data(current.utf8))

        let app = try WorkspaceUITestSupport.launch(in: self)
        let window = app.windows.firstMatch
        try showHistoricalFile(file, commit: "E2E fixture history", fixture: fixture, app: app)
        let historicalRow = historicalFileRow(file, fixture: fixture, window: window)
        historicalRow.click()
        let graphCommit = app.buttons.matching(NSPredicate(
            format: "label == %@", "E2E fixture history"
        )).firstMatch
        XCTAssertTrue(graphCommit.isHittable,
                      "Previewing the Git historical Diff must keep Git Graph active")
        openHistoricalMenu(file, fixture: fixture, window: window)
        let viewRevision = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["View File at Revision", "查看此提交中的文件"]
        )).firstMatch
        guard viewRevision.waitForExistence(timeout: 5) else {
            XCTFail("Historical context menu item missing. AX tree:\n"
                + String(app.debugDescription.prefix(16000)))
            return
        }
        XCTAssertTrue(viewRevision.isEnabled)
        viewRevision.click()

        let native = window.textViews.firstMatch
        XCTAssertTrue(native.waitForExistence(timeout: 15))
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", historical), object: native
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed,
                       "Historical revision must display actual immutable Git blob content")
        native.click()
        native.typeKey("x", modifierFlags: [])
        XCTAssertEqual(native.value as? String, historical,
                       "Typing must not modify a selected historical revision")
        XCTAssertEqual(try Data(contentsOf: file), Data(current.utf8))
        XCTAssertEqual(try fixture.git(["show", ":history.txt"]), Data(current.utf8))
        XCTAssertEqual(try revision(in: fixture), headHash)
    }

    func testRenamedHistoricalFileComparesAndOpensActualWorkingFile() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let historical = "original named file\n"
        let working = "renamed working file 中文 👋\n"
        let old = try fixture.file("original.txt", text: historical)
        try fixture.initializeGit()
        let rootHash = try revision(in: fixture)
        try fixture.git(["mv", "original.txt", "renamed.txt"])
        try fixture.git(["-c", "user.name=BaileyUITest", "-c",
                         "user.email=tests@example.invalid", "commit", "-qm", "Rename revision"])
        let renamed = fixture.root.appendingPathComponent("renamed.txt")
        try working.write(to: renamed, atomically: true, encoding: .utf8)
        let headHash = try revision(in: fixture)
        XCTAssertNotEqual(rootHash, headHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))

        let app = try WorkspaceUITestSupport.launch(in: self)
        let window = app.windows.firstMatch
        try showHistoricalFile(old, commit: "E2E fixture history", fixture: fixture, app: app)
        openHistoricalMenu(old, fixture: fixture, window: window)
        let compare = app.menuItems.matching(NSPredicate(format: "title IN %@",
            ["Compare with Working File", "与工作区文件比较"])).firstMatch
        XCTAssertTrue(compare.waitForExistence(timeout: 10))
        compare.click()
        let comparison = window.textViews.firstMatch
        XCTAssertTrue(comparison.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let content = comparison.value as? String else { return false }
            return content.contains("original named file") && content.contains("renamed working file")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed,
                       "Historical comparison must resolve the real renamed worktree contents")

        openHistoricalMenu(old, fixture: fixture, window: window)
        let open = app.menuItems.matching(NSPredicate(format: "title IN %@",
            ["Open Working File", "打开工作区文件"])).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(renamed, in: window)
            .waitForExistence(timeout: 15), "Git history must open the renamed path, not a nonexistent old path")
        let live = window.textViews.firstMatch
        let fileLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value == %@", working), object: live)
        XCTAssertEqual(XCTWaiter.wait(for: [fileLoaded], timeout: 15), .completed)
        XCTAssertEqual(try fixture.git(["show", rootHash + ":original.txt"]), Data(historical.utf8))
        XCTAssertEqual(try Data(contentsOf: renamed), Data(working.utf8))
        XCTAssertEqual(try revision(in: fixture), headHash)
    }

    func testBinaryAndOversizeHistoricalRevisionsShowNativeReadRestrictions() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let binary = try fixture.file("binary.bin", text: "")
        let binaryBytes = Data([0, 0xFF, 1, 2, 3])
        try binaryBytes.write(to: binary)
        let large = try fixture.file("large.txt", text: "")
        let largeBytes = Data(repeating: 65, count: (5 << 20) + 1)
        try largeBytes.write(to: large)
        try fixture.initializeGit()
        let headHash = try revision(in: fixture)
        XCTAssertEqual(try fixture.git(["show", ":binary.bin"]), binaryBytes)
        XCTAssertEqual(try fixture.git(["cat-file", "-s", "HEAD:large.txt"]),
                       Data("\(largeBytes.count)\n".utf8))

        let app = try WorkspaceUITestSupport.launch(in: self)
        let window = app.windows.firstMatch
        try showHistoricalFile(binary, commit: "E2E fixture history", fixture: fixture, app: app)
        openHistoricalMenu(binary, fixture: fixture, window: window)
        let view = app.menuItems.matching(NSPredicate(format: "title IN %@",
            ["View File at Revision", "查看此提交中的文件"])).firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 10))
        let metadata = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "enabled == NO"), object: view)
        XCTAssertEqual(XCTWaiter.wait(for: [metadata], timeout: 15), .completed,
                       "Binary Git blobs must not be offered as editable native text")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        openHistoricalMenu(large, fixture: fixture, window: window)
        let largeAction = app.menuItems.matching(NSPredicate(format: "title IN %@",
            ["View File at Revision", "查看此提交中的文件"])).firstMatch
        XCTAssertTrue(largeAction.waitForExistence(timeout: 10))
        XCTAssertTrue(largeAction.isEnabled)
        largeAction.click()
        let errors = ["File is too large to diff", "文件过大，无法显示 diff"]
        let tooLarge = window.staticTexts.matching(NSPredicate(
            format: "label IN %@ OR value IN %@", errors, errors)).firstMatch
        XCTAssertTrue(tooLarge.waitForExistence(timeout: 15),
                      "Over-limit historical blobs must display an explicit error instead of empty text")
        XCTAssertEqual(try Data(contentsOf: binary), binaryBytes)
        XCTAssertEqual(try Data(contentsOf: large), largeBytes)
        XCTAssertEqual(try revision(in: fixture), headHash)
    }

    func testHistoricalResetRejectsExternalEditAfterConfirmationOpens() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "first committed revision\n"
        let current = "second committed revision\n"
        let external = "EXTERNAL edit after alert appeared 👋\n"
        let file = try fixture.file("history.txt", text: original)
        try fixture.initializeGit()
        try current.write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c", "user.email=tests@example.invalid",
                         "commit", "-qam", "Second revision"])
        let headHash = try revision(in: fixture)

        let app = try WorkspaceUITestSupport.launch(in: self)
        let window = app.windows.firstMatch
        try showHistoricalFile(file, commit: "E2E fixture history", fixture: fixture, app: app)
        openHistoricalMenu(file, fixture: fixture, window: window)
        let reset = app.menuItems.matching(NSPredicate(format: "title IN %@",
            ["Reset File to Revision…", "恢复到此版本…"])).firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 10))
        reset.click()
        let alert = window.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        let confirm = alert.buttons.matching(NSPredicate(format: "title IN %@",
            ["Yes, Reset File", "确认恢复文件"])).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        try external.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Data(contentsOf: file), Data(external.utf8))
        confirm.click()
        // Unchanged disk/index bytes are true before the asynchronous Git
        // preflight has finished. Wait for its visible failed result first.
        let failure = window.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR value CONTAINS %@",
            "Reset File to Revision", "恢复文件到指定版本"
        )).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 30),
                      "The rejected historical reset must visibly report its failed operation")
        let rejected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == Data(external.utf8)
                && (try? fixture.git(["show", ":history.txt"])) == Data(current.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rejected], timeout: 15), .completed,
                       "Rejected reset must not change worktree bytes or Git index")
        XCTAssertEqual(try Data(contentsOf: file), Data(external.utf8),
                       "Stale confirmation must never overwrite externally modified bytes")
        XCTAssertEqual(try fixture.git(["show", ":history.txt"]), Data(current.utf8),
                       "Stale reset must not change the index")
        XCTAssertEqual(try revision(in: fixture), headHash)
        XCTAssertTrue(String(decoding: try fixture.git(["status", "--porcelain=v1"]),
                             as: UTF8.self).contains(" M history.txt"))
        let dismiss = window.descendants(matching: .any)
            .matching(identifier: "xmark")
            .matching(NSPredicate(format: "label IN %@",
                ["Dismiss Git Error", "关闭 Git 错误"])).firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10),
                      "Git must expose the error's dismiss action in the same window")
        XCTAssertTrue(dismiss.isHittable,
                      "A stale Git reset must report an actionable failure in the Git panel")
    }

    func testHistoricalResetConfirmationCancellationAndActualGitBytes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let history = "old saved revision\n"
        let current = "new committed revision\n"
        let local = "unsaved worktree revision\n"
        let file = try fixture.file("history.txt", text: history)
        let sibling = try fixture.file("other.txt", text: "unrelated file\n")
        try fixture.initializeGit()
        try current.write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["-c", "user.name=BaileyUITest", "-c", "user.email=tests@example.invalid",
                         "commit", "-qam", "Second revision"])
        let headHash = try revision(in: fixture)
        try local.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.git(["show", ":history.txt"]), Data(current.utf8))

        let app = try WorkspaceUITestSupport.launch(in: self)
        let window = app.windows.firstMatch
        try showHistoricalFile(file, commit: "E2E fixture history", fixture: fixture, app: app)
        // The same path is also shown above in Git Changes. Collapse that
        // section so the historical row is the only matching file target.
        let changes = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Changes", "更改"]
        )).firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 12))
        changes.click()

        func confirm(reset: Bool) throws {
            openHistoricalMenu(file, fixture: fixture, window: window)
            let resetOption = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["Reset File to Revision…", "恢复到此版本…"]
            )).firstMatch
            guard resetOption.waitForExistence(timeout: 5) else {
                XCTFail("Historical reset menu item missing. AX tree:\n"
                    + String(app.debugDescription.prefix(16000)))
                return
            }
            XCTAssertTrue(resetOption.isEnabled)
            resetOption.click()
            let alert = window.sheets.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 15),
                          "Reset requires a native, window-owned confirmation sheet")
            let names = reset ? ["Yes, Reset File", "确认恢复文件"] : ["Cancel", "取消"]
            let button = alert.buttons.matching(NSPredicate(format: "title IN %@", names)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 8),
                          "Native NSAlert exposes localized action names as titles")
            button.click()
        }

        try confirm(reset: false)
        XCTAssertEqual(try Data(contentsOf: file), Data(local.utf8),
                       "Cancel must preserve all uncommitted worktree bytes")
        XCTAssertEqual(try fixture.git(["show", ":history.txt"]), Data(current.utf8),
                       "Cancel must preserve the index")
        XCTAssertEqual(try revision(in: fixture), headHash)

        try confirm(reset: true)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == Data(history.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 25), .completed,
                       "Confirmed reset must replace real worktree bytes")
        XCTAssertEqual(try fixture.git(["show", ":history.txt"]), Data(history.utf8),
                       "Confirmed reset must replace the Git index with the chosen blob")
        XCTAssertEqual(try revision(in: fixture), headHash,
                       "Historical file reset must not move HEAD")
        XCTAssertEqual(try Data(contentsOf: sibling), Data("unrelated file\n".utf8),
                       "Historical reset must not touch other tracked files")
    }

    private func revision(in fixture: WorkspaceUITestFixture) throws -> String {
        String(decoding: try fixture.git(["rev-parse", "HEAD"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showHistoricalFile(
        _ file: URL, commit: String, fixture: WorkspaceUITestFixture, app: XCUIApplication
    ) throws {
        XCTAssertTrue(fixture.root.lastPathComponent.hasPrefix("Bailey-UITest-"))
        XCTAssertTrue(fixture.root.standardizedFileURL.path.hasPrefix(
            FileManager.default.temporaryDirectory.standardizedFileURL.path))
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(git.waitForExistence(timeout: 20))
        XCTAssertTrue(git.isHittable)
        let commitRow = app.buttons.matching(NSPredicate(format: "label == %@", commit)).firstMatch
        XCTAssertTrue(commitRow.waitForExistence(timeout: 20),
                      "Git Graph must show the old revision from real fixture commits")
        commitRow.click()
        XCTAssertTrue(historicalFileRow(file, fixture: fixture, window: app.windows.firstMatch)
            .waitForExistence(timeout: 15),
            "Git Graph must expose the selected commit's file, not the Git Changes row")
    }

    private func historicalFileRow(
        _ file: URL, fixture: WorkspaceUITestFixture, window: XCUIElement
    ) -> XCUIElement {
        let prefix = fixture.root.standardizedFileURL.path + "/"
        let absolute = file.standardizedFileURL.path
        precondition(absolute.hasPrefix(prefix), "Historical test file must belong to fixture")
        let relative = String(absolute.dropFirst(prefix.count))
        return window.descendants(matching: .any)
            .matching(identifier: "bailey.git.history.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", " + relative))
            .firstMatch
    }

    private func openHistoricalMenu(
        _ file: URL, fixture: WorkspaceUITestFixture, window: XCUIElement
    ) {
        let row = historicalFileRow(file, fixture: fixture, window: window)
        XCTAssertTrue(row.waitForExistence(timeout: 12))
        XCTAssertTrue(row.isHittable, "The historical file must be visible before opening its menu")
        row.rightClick()
    }
}
