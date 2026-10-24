import Foundation
import XCTest
@testable import Bailey

@MainActor
final class GitStashActionTests: XCTestCase {
    private var root: URL!
    private var model: GitStatusModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-stash-actions-" + UUID().uuidString)
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
        XCTAssertEqual(model.stashes.count, 2)
        XCTAssertEqual(model.stashes.map(\.selector), ["stash@{0}", "stash@{1}"])
        XCTAssertEqual(model.stashes[1].oid, try git(["rev-parse", "stash@{1}"]))
        XCTAssertTrue(model.stashes[1].message.contains("message a"))
        try git(["stash", "clear"]); model.refresh(); try await settle()
        XCTAssertTrue(model.stashes.isEmpty)
        XCTAssertEqual(model.stashes.count, 0)
        XCTAssertEqual(GitStatusModel.parseStashes(""), [])
        XCTAssertNil(GitStatusModel.parseStashes("broken\0record\0"))
    }

    func testStashGraphConnectsEachSelectorToItsBaseWithoutTreatingItAsANormalCommit() async throws {
        try makeTwoStashes()
        let duplicateOID = try git(["rev-parse", "stash@{1}"])
        try git(["stash", "store", "-m", "duplicate", duplicateOID])
        try await refresh()

        let graph = model.graphCommits
        let stashes = graph.filter { $0.stash != nil }
        XCTAssertEqual(stashes.count, 3)
        XCTAssertEqual(Set(stashes.map(\.id)).count, 3,
                       "Two reflog selectors with identical Git hashes are still separate rows")
        let baseOID = try git(["rev-parse", "HEAD"])
        let basePosition = try XCTUnwrap(graph.firstIndex {
            $0.hash == baseOID && $0.stash == nil
        })
        for node in stashes {
            XCTAssertEqual(node.parentHashes, [baseOID],
                           "The visual edge must never connect to the stash index/untracked parents")
            XCTAssertEqual(node.stash?.baseHash, baseOID)
        }
        XCTAssertEqual(graph[basePosition].hash, baseOID)
        XCTAssertEqual(graph.prefix(basePosition).filter { $0.stash != nil }.count, 3)

        let sharedDate = Date(timeIntervalSince1970: 1000)
        let many = (0..<12).map { index in
            GitStatusModel.Stash(
                selector: "stash@{\(index)}",
                oid: String(repeating: "0", count: 39) + String(index, radix: 16),
                message: "many", baseHash: baseOID, untrackedFilesHash: nil,
                author: "Tester", date: sharedDate
            )
        }
        XCTAssertEqual(GitStatusModel.graphCommits(model.recentCommits, stashes: many)
            .compactMap { $0.stash?.selector }, many.map(\.selector),
            "Stash ties follow numeric reflog order, not lexical selector order")
        let layout = CommitGraphLayout(commits: graph)
        XCTAssertEqual(layout.rows.count, graph.count)
        XCTAssertTrue(layout.rows[..<basePosition].contains {
            !$0.links.isEmpty
        }, "The stash rows should draw real parent connections")

        let detached = GitStatusModel.graphCommits([], stashes: model.stashes)
        XCTAssertEqual(detached.count, 3)
        XCTAssertTrue(CommitGraphLayout(commits: detached).rows.allSatisfy {
            $0.links.isEmpty
        }, "A history page without the base must not invent a graph connection")
        try git(["stash", "clear"])
        model.refresh()
        try await settle()
        XCTAssertEqual(model.graphCommits.count, model.recentCommits.count)
    }

    func testExpandedStashLoadsTrackedAndThirdParentUntrackedFiles() async throws {
        try write("a.txt", "tracked changed\n")
        try write("new file [1].txt", "untracked contents\n")
        try git(["stash", "push", "-u", "-m", "with untracked"])
        try await refresh()
        let stash = try XCTUnwrap(model.stashes.first)
        XCTAssertEqual(stash.baseHash, try git(["rev-parse", "HEAD"]))
        XCTAssertNotNil(stash.untrackedFilesHash)
        XCTAssertNil(model.stashFilesByOID[stash.oid], "Do not scan every stash during status refresh")

        model.loadStashFiles(for: stash)
        let deadline = Date().addingTimeInterval(15)
        var files: [GitStatusModel.RecentCommit.FileChange]?
        while Date() < deadline {
            switch model.stashFilesByOID[stash.oid] {
            case .loaded(let loaded):
                files = loaded
            case .failed(let message):
                XCTFail(message)
                throw WorkspaceError.notFound
            default:
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            break
        }
        let changes = try XCTUnwrap(files)
        XCTAssertTrue(changes.contains {
            $0.path == "a.txt" && !$0.fromStashUntracked && $0.status == "M"
        })
        XCTAssertTrue(changes.contains {
            $0.path == "new file [1].txt" && $0.fromStashUntracked && $0.status == "A"
        })
        let untrackedOID = try XCTUnwrap(stash.untrackedFilesHash)
        XCTAssertEqual(try git(["show", untrackedOID + ":new file [1].txt"]), "untracked contents")
        XCTAssertEqual(try git(["show", stash.oid + ":a.txt"]), "tracked changed")
        XCTAssertEqual(try text("a.txt"), "base a\n")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("new file [1].txt").path
        ))
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
            XCTAssertEqual(model.stashes.count, 2)
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
        XCTAssertEqual(model.stashes.count, 3)
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
        XCTAssertEqual(model.stashes.count, 2)
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
            XCTAssertEqual(model.stashes.count, 2)
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
