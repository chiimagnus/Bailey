import Foundation
import XCTest

@MainActor
final class GitHistoryUITests: XCTestCase {
    func testRealLFSHistoryStagedAndWorktreeShowCSVAcrossNativeDiffTabs() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let lfsBin = "/opt/homebrew/bin"
        guard FileManager.default.isExecutableFile(atPath: lfsBin + "/git-lfs") else {
            throw XCTSkip("Real Git LFS is not installed")
        }
        // The XCTest Runner's PATH omits Homebrew, even when Git LFS is installed.
        let previousPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", lfsBin + ":" + (previousPath ?? "/usr/bin:/bin"), 1)
        defer {
            if let previousPath { setenv("PATH", previousPath, 1) }
            else { unsetenv("PATH") }
        }
        try fixture.git(["lfs", "version"])
        try fixture.git(["init", "-q", "-b", "main"])
        for arguments in [
            ["config", "user.name", "BaileyUITest"],
            ["config", "user.email", "tests@example.invalid"],
            ["config", "commit.gpgsign", "false"],
            ["config", "filter.lfs.clean", "git-lfs clean -- %f"],
            ["config", "filter.lfs.smudge", "git-lfs smudge -- %f"],
            ["config", "filter.lfs.process", "git-lfs filter-process"],
            ["config", "filter.lfs.required", "true"],
        ] { try fixture.git(arguments) }
        _ = try fixture.file(".gitattributes", text: "*.csv filter=lfs diff=lfs merge=lfs -text\n")
        let path = "循环冲击.csv"
        let initial = "strain,stress\n0,1\n1,3\n"
        let revised = "strain,stress\n0,1\n1,9\n"
        let staged = "strain,stress\n0,1\n1,15\n"
        let worktree = "strain,stress\n0,1\n1,25\n"
        let file = try fixture.file(path, text: initial)
        try fixture.git(["add", "-A"])
        try fixture.git(["commit", "-qm", "LFS baseline"])
        let oldOID = try fixture.git(["rev-parse", "HEAD"])
        try revised.write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", path])
        try fixture.git(["commit", "-qm", "LFS revised CSV"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let pointer = try fixture.git(["show", "HEAD:" + path])
        XCTAssertTrue(String(decoding: pointer, as: UTF8.self)
            .hasPrefix("version https://git-lfs.github.com/spec/v1\n"),
            "The fixture must store an actual LFS pointer, not an ordinary CSV blob")
        XCTAssertNotEqual(oldOID, head)
        try staged.write(to: file, atomically: true, encoding: .utf8)
        try fixture.git(["add", "--", path])
        let stagedOID = try fixture.git(["rev-parse", ":" + path])
        try worktree.write(to: file, atomically: true, encoding: .utf8)
        let gitStatus = try fixture.git(["-c", "core.quotePath=false", "status", "--porcelain=v1"])
        XCTAssertEqual(gitStatus, Data("MM ".utf8) + Data(path.utf8)
            + Data("\n".utf8), "The fixture needs both staged and unstaged LFS changes")

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        try showHistoricalFile(file, commit: "LFS revised CSV", fixture: fixture, app: app)
        let history = historicalFileRow(file, fixture: fixture, window: window)
        history.click()
        let layout = window.radioGroups["bailey.diff.layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 15))
        layout.radioButtons.element(boundBy: 1).click()
        func expectReadonlyDiff(_ old: String, _ new: String) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let values = Set(window.textViews.allElementsBoundByIndex
                    .compactMap { $0.value as? String })
                return values.contains(old) && values.contains(new)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed,
                           "Real Git LFS Diff must display CSV bodies, never pointers")
        }
        expectReadonlyDiff(initial, revised)
        XCTAssertTrue(app.buttons["LFS revised CSV"].exists,
                      "Opening a historical LFS Diff must not hide the Git Graph")
        openHistoricalMenu(file, fixture: fixture, window: window)
        activateHistoricalMenu(.viewRevision, in: app)
        let readable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.textViews.allElementsBoundByIndex.contains { ($0.value as? String) == revised }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [readable], timeout: 15), .completed,
                       "Viewing an immutable LFS revision must show the full CSV body")

        let changes = window.descendants(matching: .any)
            .matching(identifier: "bailey.tree.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", " + path))
        XCTAssertTrue(changes.element(boundBy: 1).waitForExistence(timeout: 25),
                      "Git Graph must keep distinct Staged and Worktree LFS file rows")
        changes.element(boundBy: 0).click()
        XCTAssertTrue(layout.waitForExistence(timeout: 15))
        layout.radioButtons.element(boundBy: 1).click()
        expectReadonlyDiff(revised, staged)
        changes.element(boundBy: 1).click()
        let editor = window.textViews["bailey.diff.worktree"]
        let editable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (editor.value as? String) == worktree
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [editable], timeout: 15), .completed,
                       "Worktree must show real editable CSV bytes, not the stored pointer")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-parse", ":" + path]), stagedOID)
        XCTAssertEqual(try fixture.git(["-c", "core.quotePath=false", "status", "--porcelain=v1"]), gitStatus)
        XCTAssertEqual(try Data(contentsOf: file), Data(worktree.utf8))
    }

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

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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
        activateHistoricalMenu(.viewRevision, in: app)
        let revisionTabs = window.buttons.matching(NSPredicate(
            format: "label == %@", "history.txt (\(rootHash.prefix(7)))"
        ))
        XCTAssertTrue(revisionTabs.firstMatch.waitForExistence(timeout: 15),
                      "View Revision must open the immutable revision, not Worktree comparison")

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

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        try showHistoricalFile(old, commit: "E2E fixture history", fixture: fixture, app: app)
        openHistoricalMenu(old, fixture: fixture, window: window)
        activateHistoricalMenu(.compareWorktree, in: app)
        let comparisonTabs = window.buttons.matching(NSPredicate(
            format: "label == %@", "original.txt (\(rootHash.prefix(7))) ↔ Worktree"
        ))
        XCTAssertTrue(comparisonTabs.firstMatch.waitForExistence(timeout: 15),
                      "Compare must open the historical-versus-worktree Diff tab")
        let comparison = window.textViews.firstMatch
        XCTAssertTrue(comparison.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let contents = window.textViews.allElementsBoundByIndex
                .compactMap { $0.value as? String }.joined(separator: "\n")
            return contents.contains("original named file")
                && contents.contains("renamed working file")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed,
                       "Unified and split historical Diff must read both renamed file versions")

        openHistoricalMenu(old, fixture: fixture, window: window)
        activateHistoricalMenu(.openWorkingFile, in: app)
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

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        try showHistoricalFile(binary, commit: "E2E fixture history", fixture: fixture, app: app)
        // This XCTest Runner cannot enumerate native context-menu items.
        // Open the actual binary Git Diff and assert a visible read restriction,
        // rather than incorrectly treating the missing AX item as disabled.
        historicalFileRow(binary, fixture: fixture, window: window).click()
        let binaryErrors = ["Binary file", "二进制文件"]
        let binaryError = window.staticTexts.matching(NSPredicate(
            format: "label IN %@ OR value IN %@", binaryErrors, binaryErrors
        )).firstMatch
        XCTAssertTrue(binaryError.waitForExistence(timeout: 15),
                      "Binary Git revisions must display a read restriction instead of editable text")

        openHistoricalMenu(large, fixture: fixture, window: window)
        activateHistoricalMenu(.viewRevision, in: app)
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

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        try showHistoricalFile(file, commit: "E2E fixture history", fixture: fixture, app: app)
        openHistoricalMenu(file, fixture: fixture, window: window)
        activateHistoricalMenu(.resetFile, in: app)
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

        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        try showHistoricalFile(file, commit: "E2E fixture history", fixture: fixture, app: app)
        // Keep both sections present. historicalFileRow uses the history-only
        // accessibility identifier, even when Changes shows the same path.

        func confirm(reset: Bool) throws {
            openHistoricalMenu(file, fixture: fixture, window: window)
            activateHistoricalMenu(.resetFile, in: app)
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

    private enum HistoricalMenuAction: String {
        case viewRevision = "v"
        case compareWorktree = "c"
        case openWorkingFile = "o"
        case resetFile = "r"
    }

    private func activateHistoricalMenu(_ action: HistoricalMenuAction, in app: XCUIApplication) {
        // XCTest may omit native popup items from its AX tree. macOS menu
        // type-to-select finds a unique title regardless of the hovered row.
        app.typeKey(action.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
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
        let project = app.buttons.matching(identifier: "bailey.project.row")
            .matching(NSPredicate(format: "label CONTAINS %@", fixture.root.path)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.click()
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
