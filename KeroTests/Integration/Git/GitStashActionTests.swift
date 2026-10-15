import Foundation
import XCTest
@testable import kero

@MainActor
final class GitStashActionTests: XCTestCase {
    private var root: URL!
    private var model: GitStatusModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kero-stash-actions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        model = GitStatusModel()
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Stash Test"])
        try git(["config", "user.email", "stash@invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try write("a.txt", "base a\n"); try write("b.txt", "base b\n")
        try git(["add", "."]); try git(["commit", "-qm", "base"])
    }

    override func tearDown() async throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let result = GitCommandExecution.run(arguments, in: root.path)
        guard result.status == 0 else { XCTFail(result.stderr); throw WorkspaceError.notFound }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func settle() async throws {
        let deadline = Date().addingTimeInterval(15)
        while !model.hasResolvedStatus || model.isBusy || model.isRefreshing {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func refresh() async throws { model.sync(root: root.path); try await settle() }

    private func makeTwoStashes() throws {
        for name in ["a", "b"] {
            try write(name + ".txt", "staged " + name + "\n")
            try git(["add", name + ".txt"])
            try write(name + ".txt", "work " + name + "\n")
            try git(["stash", "push", "-qm", "message " + name])
        }
    }

    func testListSnapshotKeepsSelectorsOIDsAndMessagesAndCountIsDerived() async throws {
        try makeTwoStashes(); try await refresh()
        XCTAssertEqual(model.stashCount, 2)
        XCTAssertEqual(model.stashes.map(\.selector), ["stash@{0}", "stash@{1}"])
        XCTAssertEqual(model.stashes[1].oid, try git(["rev-parse", "stash@{1}"]))
        XCTAssertTrue(model.stashes[1].message.contains("message a"))
        try git(["stash", "clear"]); model.refresh(); try await settle()
        XCTAssertTrue(model.stashes.isEmpty)
        XCTAssertEqual(model.stashCount, 0)
        XCTAssertEqual(GitStatusModel.parseStashes(""), [])
        XCTAssertNil(GitStatusModel.parseStashes("broken\0record\0"))
    }

    func testApplySelectedStashRestoresActualIndexOnlyWhenRequestedAndKeepsReflog() async throws {
        try makeTwoStashes(); try await refresh()
        let selected = model.stashes[1]
        for restoreIndex in [false, true] {
            model.actOnStash(selected, action: .apply, reinstateIndex: restoreIndex, target: model.actionTarget())
            try await settle()
            XCTAssertNil(model.lastError)
            XCTAssertEqual(try text("a.txt"), "work a\n")
            XCTAssertEqual(try text("b.txt"), "base b\n")
            XCTAssertEqual(try git(["show", ":a.txt"]), restoreIndex ? "staged a" : "base a")
            XCTAssertEqual(model.stashCount, 2)
            try git(["reset", "--hard", "HEAD"]); model.refresh(); try await settle()
        }
    }

    func testPopSelectedStashRemovesOnlyThatEntryWithBothIndexModes() async throws {
        for restoreIndex in [false, true] {
            try makeTwoStashes(); try await refresh()
            let retained = model.stashes[0].oid
            model.actOnStash(model.stashes[1], action: .pop, reinstateIndex: restoreIndex, target: model.actionTarget())
            try await settle()
            XCTAssertNil(model.lastError)
            XCTAssertEqual(try text("a.txt"), "work a\n")
            XCTAssertEqual(try git(["show", ":a.txt"]), restoreIndex ? "staged a" : "base a")
            XCTAssertEqual(model.stashes.map(\.oid), [retained])
            try git(["reset", "--hard", "HEAD"]); try git(["stash", "clear"])
        }
    }

    func testBranchChecksOutRestoresIndexAndDropsSelectedSelectorNotLatest() async throws {
        try makeTwoStashes(); try await refresh()
        let retained = model.stashes[0].oid
        model.actOnStash(model.stashes[1], action: .branch, branchName: "from/stash", target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["branch", "--show-current"]), "from/stash")
        XCTAssertEqual(try text("a.txt"), "work a\n")
        XCTAssertEqual(try git(["show", ":a.txt"]), "staged a")
        XCTAssertEqual(model.stashes.map(\.oid), [retained])
    }

    func testSelectorShiftRejectsPopDropAndBranchBeforeAnySideEffect() async throws {
        for action in [GitStatusModel.StashAction.pop, .drop, .branch] {
            try makeTwoStashes(); try await refresh()
            let selected = model.stashes[1]
            try write("a.txt", "new stash\n"); try git(["stash", "push", "-qm", "shift"])
            let before = try git(["stash", "list", "--format=%H"])
            model.actOnStash(selected, action: action, branchName: "must-not-exist", target: model.actionTarget())
            try await settle()
            XCTAssertNotNil(model.lastError)
            XCTAssertEqual(try git(["stash", "list", "--format=%H"]), before)
            XCTAssertEqual(try git(["branch", "--show-current"]), "main")
            XCTAssertEqual(try git(["branch", "--list", "must-not-exist"]), "")
            XCTAssertEqual(try text("a.txt"), "base a\n")
            try git(["stash", "clear"])
        }
    }

    func testApplyFixedOIDStillRestoresSelectedContentAfterSelectorMoves() async throws {
        try makeTwoStashes(); try await refresh()
        let selected = model.stashes[1]
        try write("a.txt", "new stash\n"); try git(["stash", "push", "-qm", "shift"])
        model.actOnStash(selected, action: .apply, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try text("a.txt"), "work a\n")
        XCTAssertEqual(model.stashCount, 3)
    }

    func testSameOIDStashSelectorShiftCannotDeleteAnotherReflogEntry() async throws {
        try write("a.txt", "first\n")
        try git(["stash", "push", "-qm", "original"])
        let oid = try git(["rev-parse", "stash@{0}"])
        try write("b.txt", "second\n")
        try git(["stash", "push", "-qm", "other"])
        try git(["stash", "store", "-m", "duplicate", oid])
        try git(["stash", "drop", "-q", "stash@{1}"])
        try await refresh()
        XCTAssertEqual(model.stashes.count, 2)
        XCTAssertEqual(model.stashes[0].oid, model.stashes[1].oid)
        XCTAssertNotEqual(model.stashes[0].message, model.stashes[1].message)
        let selected = model.stashes[1]
        try write("a.txt", "inserted\n")
        try git(["stash", "push", "-qm", "inserted"])
        let actualList = try git(["stash", "list", "--format=%gd:%gs"])
        XCTAssertEqual(try git(["rev-parse", selected.selector + "^{commit}"]), selected.oid,
                       "The old OID check passes for the wrong reflog entry")
        model.actOnStash(selected, action: .drop, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError, "The chosen reflog entry moved despite the matching OID")
        XCTAssertEqual(try git(["stash", "list", "--format=%gd:%gs"]), actualList,
                       "The other duplicate must not be deleted")
    }

    func testConflictDuringPopKeepsStashAndRealUnmergedIndex() async throws {
        try makeTwoStashes(); try await refresh()
        let selected = model.stashes[1]
        try write("a.txt", "conflicting committed change\n")
        try git(["add", "a.txt"]); try git(["commit", "-qm", "conflict"])
        model.refresh(); try await settle()
        model.actOnStash(selected, action: .pop, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.stashes.contains { $0.oid == selected.oid })
        XCTAssertFalse(try git(["ls-files", "-u"]).isEmpty)
        XCTAssertTrue(try text("a.txt").contains("<<<<<<<"))
    }

    func testDropDoesNotSaveUnrelatedBuffersAndBranchNameFailureKeepsStash() async throws {
        try makeTwoStashes(); try await refresh()
        model.actOnStash(model.stashes[1], action: .branch, branchName: "main", target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.stashCount, 2)
        let retained = model.stashes[0].oid
        model.actOnStash(model.stashes[1], action: .drop, target: model.actionTarget(), prepare: {
            XCTFail("Deleting only a reflog entry must not save unrelated edits")
            return false
        })
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.stashes.map(\.oid), [retained])
        XCTAssertEqual(try text("a.txt"), "base a\n")
    }

    func testFailedSaveAndWorkspaceChangeNeverApplyPopOrCreateBranch() async throws {
        try makeTwoStashes(); try await refresh()
        let selected = model.stashes[1]
        for action in [GitStatusModel.StashAction.apply, .pop, .branch] {
            model.actOnStash(selected, action: action, branchName: "refused", target: model.actionTarget(), prepare: { false })
            try await settle()
            XCTAssertNotNil(model.lastError)
            XCTAssertEqual(model.stashCount, 2)
            XCTAssertEqual(try text("a.txt"), "base a\n")
            XCTAssertEqual(try git(["branch", "--list", "refused"]), "")
        }
        model.actOnStash(selected, action: .pop, target: model.actionTarget(), prepare: {
            self.model.sync(root: "")
            return true
        })
        let deadline = Date().addingTimeInterval(15)
        while model.isBusy {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.stashes.isEmpty)
        XCTAssertEqual(try git(["stash", "list", "--format=%H"]).split(separator: "\n").count, 2)
        XCTAssertEqual(try text("a.txt"), "base a\n")
    }
}
