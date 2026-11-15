import Foundation
import XCTest
@testable import Bailey

@MainActor
final class GitCommitActionTests: XCTestCase {
    private var directory: URL!
    private var model: GitStatusModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = GitStatusModel()
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Commit Actions Test"])
        _ = try git(["config", "user.email", "actions@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["config", "core.hooksPath", "/dev/null"])
        _ = try commit("root", text: "root\n")
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func git(_ arguments: [String]) throws -> String {
        let result = GitCommandExecution.run(arguments, in: directory.path, timeout: 15)
        guard result.status == 0 else {
            XCTFail(result.stderr)
            throw WorkspaceError.notFound
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ subject: String, text: String) throws -> String {
        try text.write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", subject])
        return try git(["rev-parse", "HEAD"])
    }

    private func settle() async throws {
        let deadline = Date().addingTimeInterval(12)
        while !model.hasResolvedStatus || model.isBusy || model.isRefreshing {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func target(_ hash: String) async throws -> GitStatusModel.RecentCommit {
        model.sync(root: directory.path)
        try await settle()
        return try XCTUnwrap(model.recentCommits.first { $0.hash == hash })
    }

    func testBatchCommitOrderPreservesAncestryAndReversesRevertOrder() {
        func commit(_ hash: String, parents: [String]) -> GitStatusModel.RecentCommit {
            .init(hash: hash, shortHash: hash, subject: hash,
                  author: "Tester", date: .now, parentHashes: parents,
                  references: [], files: [])
        }
        let commits = [
            commit("side2", parents: ["side1"]), commit("main2", parents: ["main1"]),
            commit("main1", parents: ["root"]), commit("side1", parents: ["root"]),
        ]
        XCTAssertEqual(GitStatusModel.orderedBatchCommits(
            ["main2", "side2", "side1", "main1"], from: commits, reverse: false
        ), ["side1", "main1", "main2", "side2"])
        XCTAssertEqual(GitStatusModel.orderedBatchCommits(
            ["main2", "side2", "side1", "main1"], from: commits, reverse: true
        ), ["side2", "main2", "main1", "side1"])
    }

    func testBatchCherryPickUsesAncestryOrderAndKeepsCompleteChanges() async throws {
        let original = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-qc", "topic"])
        let first = try commit("topic one", text: "one\n")
        let second = try commit("topic two", text: "two\n")
        _ = try git(["switch", "main"])
        _ = try await target(original)
        model.actOnCommits([second, first], action: .cherryPick,
                           target: model.actionTarget(), recordOrigin: true)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["log", "-2", "--format=%s"]),
                       "topic two\ntopic one")
        XCTAssertEqual(try git(["log", "-2", "--format=%B"]).components(
            separatedBy: "(cherry picked from commit "
        ).count, 3)
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "3")
        XCTAssertEqual(try git(["show", "HEAD:tracked.txt"]), "two")
        XCTAssertEqual(try git(["status", "--porcelain=v1"]), "")
    }

    func testBatchCherryPickNoCommitLeavesHeadAndStagesEverySelectedChange() async throws {
        let root = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-qc", "topic"])
        let first = try commit("topic first", text: "first\n")
        let second = try commit("topic second", text: "second\n")
        _ = try git(["switch", "main"])
        _ = try await target(root)
        model.actOnCommits([second, first], action: .cherryPick,
                           target: model.actionTarget(), noCommit: true)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), root)
        XCTAssertEqual(try git(["show", ":tracked.txt"]), "second")
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "tracked.txt")
    }

    func testBatchActionRejectsStaleHeadAndUnsafeMergeSelection() async throws {
        let original = try git(["rev-parse", "HEAD"])
        let first = try commit("first", text: "first\n")
        let second = try commit("second", text: "second\n")
        _ = try await target(second)
        let staleTarget = model.actionTarget()
        _ = try commit("external", text: "external\n")
        model.actOnCommits([first, second], action: .drop, target: staleTarget)
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "external")
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "4")
        XCTAssertEqual(try git(["rev-parse", "HEAD~3"]), original)
    }

    func testBatchCherryPickConflictAfterFirstCommitCanAbortEntireSequence() async throws {
        let root = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-qc", "topic"])
        let file = directory.appendingPathComponent("new-feature.txt")
        try "feature\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try git(["add", "new-feature.txt"])
        _ = try git(["commit", "-qm", "add feature"])
        let first = try git(["rev-parse", "HEAD"])
        let conflicting = try commit("topic changes tracked", text: "topic\n")
        _ = try git(["switch", "main"])
        let main = try commit("main changes tracked", text: "main\n")
        _ = try await target(main)
        model.actOnCommits([conflicting, first], action: .cherryPick,
                           target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "add feature")
        XCTAssertFalse(try git(["ls-files", "-u"]).isEmpty)
        XCTAssertNotNil(model.repositoryOperation)
        XCTAssertEqual(try git(["show", "HEAD:new-feature.txt"]), "feature")

        _ = try git(["cherry-pick", "--abort"])
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), main)
        XCTAssertEqual(try git(["show", "HEAD:tracked.txt"]), "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try git(["status", "--porcelain=v1"]), "")
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"]), root)
    }

    func testBatchRevertConflictAfterFirstRevertCanAbortEntireSequence() async throws {
        let first = try commit("first tracked change", text: "first\n")
        let marker = directory.appendingPathComponent("marker.txt")
        try "marker\n".write(to: marker, atomically: true, encoding: .utf8)
        _ = try git(["add", "marker.txt"])
        _ = try git(["commit", "-qm", "second adds marker"])
        let second = try git(["rev-parse", "HEAD"])
        let originalHead = try commit("newer conflicting tracked change", text: "newer\n")
        _ = try await target(originalHead)
        model.actOnCommits([first, second], action: .revert, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "Revert \"second adds marker\"")
        XCTAssertFalse(try git(["ls-files", "-u"]).isEmpty)
        XCTAssertNotNil(model.repositoryOperation)
        _ = try git(["revert", "--abort"])
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), originalHead)
        XCTAssertEqual(try git(["show", "HEAD:marker.txt"]), "marker")
        XCTAssertEqual(try git(["show", "HEAD:tracked.txt"]), "newer")
        XCTAssertEqual(try git(["status", "--porcelain=v1"]), "")
    }

    func testBatchDropRechecksBranchesChangedAfterMenuSnapshot() async throws {
        let initial = try git(["rev-parse", "HEAD"])
        let first = try commit("drop candidate one", text: "one\n")
        let second = try commit("drop candidate two", text: "two\n")
        let newer = try commit("keep newer", text: "newer\n")
        _ = try await target(newer)
        let snapshot = model.actionTarget()
        let tree = try git(["rev-parse", "HEAD^{tree}"])
        // Create a real new fork without moving HEAD or changing the current worktree.
        let side = try git(["commit-tree", tree, "-p", first, "-m", "later fork"])
        _ = try git(["update-ref", "refs/heads/later-fork", side])
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), newer)

        model.actOnCommits([first, second], action: .drop, target: snapshot)
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), newer)
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]), tree)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/later-fork"]), side)
        XCTAssertEqual(try git(["rev-parse", "HEAD~3"]), initial)
        XCTAssertEqual(try git(["status", "--porcelain=v1"]), "")
    }

    func testBatchRevertRunsNewestToOldestAndRestoresOriginalTree() async throws {
        let originalTree = try git(["rev-parse", "HEAD^{tree}"])
        let first = try commit("change one", text: "one\n")
        let second = try commit("change two", text: "two\n")
        _ = try await target(second)
        model.actOnCommits([first, second], action: .revert, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]), originalTree)
        XCTAssertEqual(try git(["log", "-2", "--format=%s"]),
                       "Revert \"change one\"\nRevert \"change two\"")
        XCTAssertEqual(try git(["status", "--porcelain=v1"]), "")
    }

    func testBatchDropRemovesOnlySelectedLinearCommitsAndPreservesNewerTree() async throws {
        let root = try git(["rev-parse", "HEAD"])
        let first = try commit("drop first", text: "one\n")
        let second = try commit("drop second", text: "two\n")
        let kept = directory.appendingPathComponent("kept.txt")
        try "kept\n".write(to: kept, atomically: true, encoding: .utf8)
        _ = try git(["add", "kept.txt"])
        _ = try git(["commit", "-qm", "keep newer"])
        let oldHead = try git(["rev-parse", "HEAD"])
        _ = try await target(oldHead)
        model.actOnCommits([first, second], action: .drop, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"]), oldHead)
        XCTAssertEqual(try git(["rev-parse", "HEAD^"]), root)
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "2")
        XCTAssertEqual(try git(["show", "HEAD:kept.txt"]), "kept")
        XCTAssertEqual(try git(["show", "HEAD:tracked.txt"]), "root")
        XCTAssertEqual(try git(["status", "--porcelain=v1"]), "")
    }

    func testBatchDropRejectsForksAndNoncontiguousHistory() {
        let linear = ["root": [String](), "a": ["root"], "b": ["a"], "c": ["b"], "head": ["c"]]
        XCTAssertNotNil(GitStatusModel.batchDropPlan(
            selected: ["a", "b"], head: "head", parents: linear
        ))
        XCTAssertNil(GitStatusModel.batchDropPlan(
            selected: ["root", "a"], head: "head", parents: linear
        ))
        XCTAssertNil(GitStatusModel.batchDropPlan(
            selected: ["a", "c"], head: "head", parents: linear
        ))
        XCTAssertNil(GitStatusModel.batchDropPlan(
            selected: ["a", "b"], head: "head",
            parents: linear.merging(["fork": ["a"]]) { _, new in new }
        ))
    }

    func testSquashPlanOnlyAcceptsAContinuousLinearPartOfHead() {
        let linear = [
            "root": [String](), "a": ["root"], "b": ["a"], "c": ["b"], "head": ["c"],
        ]
        let expected = GitStatusModel.SquashPlan(
            newest: "c", oldest: "b", parent: "a", newerCount: 1
        )
        XCTAssertEqual(GitStatusModel.squashPlan(
            selected: ["b", "c"], head: "head", parents: linear
        ), expected)
        XCTAssertEqual(GitStatusModel.squashPlan(
            selected: ["c", "b"], head: "head", parents: linear
        ), expected)
        XCTAssertEqual(GitStatusModel.squashPlan(
            selected: ["root", "a"], head: "head", parents: linear
        )?.parent, nil)
        XCTAssertNil(GitStatusModel.squashPlan(
            selected: ["a", "c"], head: "head", parents: linear
        ))
        XCTAssertNil(GitStatusModel.squashPlan(
            selected: ["a", "missing"], head: "head", parents: linear
        ))
        XCTAssertNil(GitStatusModel.squashPlan(
            selected: ["a"], head: "head", parents: linear
        ))
        XCTAssertNil(GitStatusModel.squashPlan(
            selected: ["b", "b"], head: "head", parents: linear
        ))
        XCTAssertNil(GitStatusModel.squashPlan(
            selected: ["a", "b"], head: "head",
            parents: linear.merging(["head": ["c", "other"]]) { _, new in new }
        ))
        XCTAssertNil(GitStatusModel.squashPlan(
            selected: ["a", "b"], head: "head",
            parents: linear.merging(["b": ["a", "other"]]) { _, new in new }
        ))
    }

    func testSquashHeadCommitsKeepsExactTreeAndOldestAuthor() async throws {
        let root = try git(["rev-parse", "HEAD"])
        _ = try git(["config", "user.name", "New Committer"])
        try "second".write(to: directory.appendingPathComponent("second.txt"),
                           atomically: true, encoding: .utf8)
        _ = try git(["add", "second.txt"])
        _ = try git(["commit", "-qm", "second", "--author=Original Writer <author@example.invalid>"])
        let oldest = try git(["rev-parse", "HEAD"])
        let originalAuthorDate = try git(["log", "-1", "--format=%aI"])
        let third = try commit("third", text: "third\n")
        let fourth = try commit("fourth", text: "fourth\n")
        let oldTree = try git(["rev-parse", "HEAD^{tree}"])
        let selected = try await target(fourth)
        XCTAssertEqual(selected.hash, fourth)
        model.squashCommits([fourth, third, oldest], message: "合并提交\n\n真实正文", target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "2")
        XCTAssertEqual(try git(["rev-parse", "HEAD^"]), root)
        XCTAssertEqual(try git(["log", "-1", "--format=%B"]), "合并提交\n\n真实正文")
        XCTAssertEqual(try git(["log", "-1", "--format=%an <%ae>"]), "Original Writer <author@example.invalid>")
        XCTAssertEqual(try git(["log", "-1", "--format=%aI"]), originalAuthorDate)
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]), oldTree)
        XCTAssertEqual(try git(["status", "--porcelain=v1"]), "")
    }

    func testSquashMiddleCommitsReplaysNewerHistoryAndKeepsTag() async throws {
        let root = try git(["rev-parse", "HEAD"])
        let oldest = try commit("oldest", text: "oldest\n")
        let newer = try commit("newer", text: "newer\n")
        _ = try git(["tag", "keep-original", oldest])
        _ = try git(["branch", "preserve-oldest", oldest])
        let after = try commit("after", text: "after\n")
        let last = try commit("last", text: "last\n")
        let oldTree = try git(["rev-parse", "HEAD^{tree}"])
        _ = try await target(last)
        model.squashCommits([oldest, newer], message: "middle squash", target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "4")
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "last")
        XCTAssertEqual(try git(["log", "-2", "--format=%s"]).split(separator: "\n").last, "after")
        XCTAssertEqual(try git(["rev-parse", "HEAD~3"]), root)
        XCTAssertEqual(try git(["log", "-1", "--format=%s", "HEAD~2"]), "middle squash")
        XCTAssertEqual(try git(["rev-parse", "refs/tags/keep-original"]), oldest)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/preserve-oldest"]), oldest)
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]), oldTree)
    }

    func testSquashCanIncludeRootCommitOnDetachedHEAD() async throws {
        let root = try git(["rev-parse", "HEAD"])
        let newer = try commit("newer", text: "更新内容\n")
        let expectedTree = try git(["rev-parse", "HEAD^{tree}"])
        _ = try git(["switch", "--detach", newer])
        _ = try await target(newer)
        model.squashCommits([root, newer], message: "压缩包含根提交", target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["branch", "--show-current"]), "")
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "1")
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "压缩包含根提交")
        XCTAssertEqual(try git(["rev-parse", "HEAD^{tree}"]), expectedTree)
        XCTAssertEqual(try git(["status", "--porcelain=v1"]), "")
    }

    func testSquashWorksWithSHA256GitObjects() async throws {
        let repository = directory.appendingPathComponent("sha256")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        func git256(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: repository.path)
            guard result.status == 0 else {
                XCTFail(result.stderr)
                throw WorkspaceError.notFound
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git256(["init", "-q", "-b", "main", "--object-format=sha256"])
        _ = try git256(["config", "user.name", "Synthetic"])
        _ = try git256(["config", "user.email", "sha256@example.invalid"])
        _ = try git256(["config", "commit.gpgsign", "false"])
        try "旧版本\n".write(to: repository.appendingPathComponent("doc.txt"),
                             atomically: true, encoding: .utf8)
        _ = try git256(["add", "."])
        _ = try git256(["commit", "-qm", "oldest"])
        let oldest = try git256(["rev-parse", "HEAD"])
        try "新版本\n".write(to: repository.appendingPathComponent("doc.txt"),
                             atomically: true, encoding: .utf8)
        _ = try git256(["add", "."])
        _ = try git256(["commit", "-qm", "newer"])
        let newest = try git256(["rev-parse", "HEAD"])
        let tree = try git256(["rev-parse", "HEAD^{tree}"])
        XCTAssertEqual(newest.count, 64)

        let shaModel = GitStatusModel()
        shaModel.sync(root: repository.path)
        func settled() async throws {
            let deadline = Date().addingTimeInterval(15)
            while !shaModel.hasResolvedStatus || shaModel.isRefreshing || shaModel.isBusy {
                guard Date() < deadline else { throw WorkspaceError.timedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settled()
        shaModel.squashCommits([newest, oldest], message: "sha256 squash",
                               target: shaModel.actionTarget())
        try await settled()
        XCTAssertNil(shaModel.lastError)
        XCTAssertEqual(try git256(["rev-list", "--count", "HEAD"]), "1")
        XCTAssertEqual(try git256(["rev-parse", "HEAD"]).count, 64)
        XCTAssertEqual(try git256(["rev-parse", "HEAD^{tree}"]), tree)
    }

    func testSquashRejectsUnsignableCommitWithoutChangingHistory() async throws {
        let older = try commit("older", text: "older\n")
        let newer = try commit("newer", text: "newer\n")
        _ = try git(["config", "commit.gpgsign", "true"])
        _ = try git(["config", "gpg.program", "/usr/bin/false"])
        _ = try await target(newer)
        model.squashCommits([older, newer], message: "must be signed", target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), newer)
        XCTAssertEqual(try git(["rev-parse", "HEAD^"]), older)
        XCTAssertEqual(try git(["status", "--porcelain=v1"]), "")
    }

    func testSquashRejectsMovedHeadAndBlankMessage() async throws {
        let older = try commit("older", text: "older\n")
        let newer = try commit("newer", text: "newer\n")
        _ = try await target(newer)
        model.squashCommits([older, newer], message: "  \n  ", target: model.actionTarget())
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), newer)

        let external = try commit("external", text: "external\n")
        model.squashCommits([older, newer], message: "stale", target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), external)
        XCTAssertEqual(try git(["show", "HEAD:tracked.txt"]), "external")
    }

    func testSquashRejectsDirtyIndexAndWorktreeWithoutMovingHead() async throws {
        let older = try commit("older", text: "older\n")
        let newer = try commit("newer", text: "newer\n")
        for stage in [true, false] {
            let path = directory.appendingPathComponent("tracked.txt")
            try (stage ? "staged\n" : "unstaged\n").write(to: path, atomically: true, encoding: .utf8)
            if stage { _ = try git(["add", "tracked.txt"]) }
            _ = try await target(newer)
            model.squashCommits([newer, older], message: "should not commit", target: model.actionTarget())
            try await settle()
            XCTAssertNotNil(model.lastError)
            XCTAssertEqual(try git(["rev-parse", "HEAD"]), newer)
            XCTAssertEqual(try String(contentsOf: path, encoding: .utf8),
                           stage ? "staged\n" : "unstaged\n")
            _ = try git(["reset", "--hard", newer])
        }
    }

    func testSquashRejectsForeignBranchAndMergeHistory() async throws {
        let root = try git(["rev-parse", "HEAD"])
        let main = try commit("main", text: "main\n")
        _ = try git(["switch", "-c", "side", root])
        try "side\n".write(to: directory.appendingPathComponent("side.txt"),
                              atomically: true, encoding: .utf8)
        _ = try git(["add", "side.txt"])
        _ = try git(["commit", "-qm", "side"])
        let side = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "main"])
        _ = try await target(main)
        model.squashCommits([main, side], message: "bad", target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), main)
        _ = try git(["merge", "--no-ff", "-m", "merge", "side"])
        let merge = try git(["rev-parse", "HEAD"])
        _ = try await target(merge)
        model.squashCommits([merge, main], message: "bad merge", target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), merge)
    }

    func testCheckoutAndRevertUseSelectedCommitIncludingRoot() async throws {
        let root = try git(["rev-parse", "HEAD"])
        let second = try commit("second", text: "second\n")
        let selected = try await target(root)
        model.actOnCommit(selected, action: .checkout, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), root)
        XCTAssertEqual(try git(["branch", "--show-current"]), "")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("tracked.txt"), encoding: .utf8), "root\n")
        _ = try git(["switch", "main"])
        let toRevert = try await target(second)
        model.actOnCommit(toRevert, action: .revert, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD^"]), second)
        XCTAssertEqual(try git(["show", "HEAD:tracked.txt"]), "root")
        _ = try git(["reset", "--hard", root])
        let rootToRevert = try await target(root)
        model.actOnCommit(rootToRevert, action: .revert, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["ls-tree", "--name-only", "HEAD"]), "")
    }

    func testDropEligibilityUsesChildrenAndHeadNotReferenceCount() {
        let linear = ["root": [String](), "second": ["root"], "third": ["second"], "head": ["third"]]
        XCTAssertTrue(GitStatusModel.dropCommitPossible("second", head: "head", parents: linear))
        XCTAssertTrue(GitStatusModel.dropCommitPossible("head", head: "head", parents: linear))
        XCTAssertFalse(GitStatusModel.dropCommitPossible("root", head: "head", parents: linear))
        XCTAssertFalse(GitStatusModel.dropCommitPossible("second", head: "unknown", parents: linear))
        var forked = linear
        forked["side"] = ["second"]
        XCTAssertFalse(GitStatusModel.dropCommitPossible("second", head: "head", parents: forked))
        var merged = linear
        merged["head"] = ["third", "second"]
        XCTAssertFalse(GitStatusModel.dropCommitPossible("second", head: "head", parents: merged))
        var beyondHead = linear
        beyondHead["later"] = ["head"]
        XCTAssertTrue(GitStatusModel.dropCommitPossible("second", head: "head", parents: beyondHead))
        beyondHead["later"] = ["head", "third"]
        XCTAssertFalse(GitStatusModel.dropCommitPossible("second", head: "head", parents: beyondHead))
    }

    func testDropRewritesHeadAndRespectsConfiguredUpdateRefsWithTags() async throws {
        let root = try git(["rev-parse", "HEAD"])
        try Data("second".utf8).write(to: directory.appendingPathComponent("second.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "second"])
        let second = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "keep-second"])
        _ = try git(["tag", "keep-second", second])
        _ = try git(["update-ref", "refs/remotes/origin/keep-second", second])
        try Data("third".utf8).write(to: directory.appendingPathComponent("third.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "third"])
        let third = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "keep-third", third])
        try Data("fourth".utf8).write(to: directory.appendingPathComponent("fourth.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "fourth"])
        let fourth = try git(["rev-parse", "HEAD"])
        for updatesRefs in [false, true] {
            _ = try git(["reset", "--hard", fourth])
            _ = try git(["branch", "-f", "keep-second", second])
            _ = try git(["branch", "-f", "keep-third", third])
            _ = try git(["config", "rebase.updateRefs", updatesRefs ? "true" : "false"])
            let selected = try await target(second)
            XCTAssertTrue(model.canDrop(selected))
            model.actOnCommit(selected, action: .drop, target: model.actionTarget())
            try await settle()
            XCTAssertNil(model.lastError)
            XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "fourth")
            XCTAssertEqual(try git(["rev-parse", "HEAD^^"]), root)
            XCTAssertEqual(try git(["show", "HEAD:third.txt"]), "third")
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("second.txt").path))
            XCTAssertEqual(try git(["rev-parse", "refs/tags/keep-second"]), second)
            XCTAssertEqual(try git(["rev-parse", "refs/remotes/origin/keep-second"]), second)
            XCTAssertEqual(try git(["rev-parse", "refs/heads/keep-second"]), second)
            XCTAssertEqual(try git(["rev-parse", "refs/heads/keep-third"]), updatesRefs ? try git(["rev-parse", "HEAD^"]) : third)
        }
        _ = try git(["config", "rebase.updateRefs", "false"])
        _ = try git(["switch", "--detach", fourth])
        let detached = try await target(second)
        model.actOnCommit(detached, action: .drop, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["branch", "--show-current"]), "")
        XCTAssertEqual(try git(["rev-parse", "HEAD^^"]), root)
    }

    func testResetModesChangeOnlySpecifiedLayers() async throws {
        let root = try git(["rev-parse", "HEAD"])
        let second = try commit("second", text: "second\n")
        let path = directory.appendingPathComponent("tracked.txt")
        try Data("ordinary untracked".utf8).write(to: directory.appendingPathComponent("untracked.txt"))
        for mode in GitStatusModel.ResetMode.allCases {
            _ = try git(["reset", "--hard", second])
            try Data("index\n".utf8).write(to: path)
            _ = try git(["add", "tracked.txt"])
            try Data("worktree\n".utf8).write(to: path)
            let selected = try await target(root)
            model.actOnCommit(selected, action: .reset, target: model.actionTarget(), resetMode: mode)
            try await settle()
            XCTAssertNil(model.lastError)
            XCTAssertEqual(try git(["rev-parse", "HEAD"]), root)
            XCTAssertEqual(try git(["show", ":tracked.txt"]), mode == .soft ? "index" : "root")
            XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), mode == .hard ? "root\n" : "worktree\n")
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("untracked.txt"), encoding: .utf8), "ordinary untracked")
        }
    }

    func testHardResetRemovesUntrackedObstructionButKeepsOrdinaryUntracked() async throws {
        let obstacle = directory.appendingPathComponent("obstacle")
        try Data("tracked file".utf8).write(to: obstacle)
        _ = try git(["add", "obstacle"])
        _ = try git(["commit", "-qm", "with obstacle"])
        let selectedHash = try git(["rev-parse", "HEAD"])
        _ = try git(["rm", "obstacle"])
        _ = try git(["commit", "-qm", "without obstacle"])
        try FileManager.default.createDirectory(at: obstacle, withIntermediateDirectories: false)
        try Data("untracked child".utf8).write(to: obstacle.appendingPathComponent("child"))
        try Data("keep".utf8).write(to: directory.appendingPathComponent("keep.txt"))
        let selected = try await target(selectedHash)
        model.actOnCommit(selected, action: .reset, target: model.actionTarget(), resetMode: .hard)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try String(contentsOf: obstacle, encoding: .utf8), "tracked file")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("keep.txt"), encoding: .utf8), "keep")
    }

    func testBackgroundRebaseReplaysCommitsOnSelectedCommit() async throws {
        _ = try git(["switch", "-c", "side"])
        try Data("side".utf8).write(to: directory.appendingPathComponent("side.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "side"])
        let side = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "main"])
        _ = try commit("main", text: "main\n")
        let selected = try await target(side)
        model.actOnCommit(selected, action: .rebase, target: model.actionTarget(), ignoreDate: true)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD^"]), side)
        XCTAssertEqual(try git(["show", "HEAD:side.txt"]), "side")
        XCTAssertEqual(try git(["show", "HEAD:tracked.txt"]), "main")
    }

    func testCherryPickOriginAndNoCommitChangeRealIndex() async throws {
        let root = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-c", "side"])
        let side = try commit("side", text: "side\n")
        _ = try git(["switch", "main"])
        let selected = try await target(side)
        model.actOnCommit(selected, action: .cherryPick, target: model.actionTarget(), recordOrigin: true)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertTrue(try git(["log", "-1", "--format=%B"]).contains("(cherry picked from commit \(side))"))
        _ = try git(["reset", "--hard", root])
        let again = try await target(side)
        model.actOnCommit(again, action: .cherryPick, target: model.actionTarget(), noCommit: true)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), root)
        XCTAssertEqual(try git(["show", ":tracked.txt"]), "side")
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "tracked.txt")
    }

    func testSquashAlreadyUpToDateDoesNotCommitPreexistingStagedWork() async throws {
        let head = try git(["rev-parse", "HEAD"])
        try "private".write(to: directory.appendingPathComponent("private.txt"),
                            atomically: true, encoding: .utf8)
        _ = try git(["add", "private.txt"])
        let selected = try await target(head)
        model.actOnCommit(selected, action: .merge, target: model.actionTarget(), squash: true)
        try await settle()
        XCTAssertNotNil(model.lastError, "A no-op squash must not auto-commit unrelated staged work")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "private.txt")
    }

    func testSquashRejectsPreexistingStagedWorkBeforeMergingOtherCommit() async throws {
        let original = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-c", "topic"])
        let topic = try commit("topic", text: "topic\n")
        _ = try git(["switch", "main"])
        try "private".write(to: directory.appendingPathComponent("private.txt"),
                            atomically: true, encoding: .utf8)
        _ = try git(["add", "private.txt"])
        let selected = try await target(topic)
        model.actOnCommit(selected, action: .merge, target: model.actionTarget(), squash: true)
        try await settle()
        XCTAssertNotNil(model.lastError, "Squash must not commit pre-staged user content")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), original)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "private.txt")
        XCTAssertEqual(try git(["show", ":tracked.txt"]), "root")
    }

    func testMergeOptionsSquashMessageAndNoEmptyCommit() async throws {
        let root = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-c", "side"])
        let side = try commit("side", text: "side\n")
        _ = try git(["switch", "main"])
        for (noFastForward, squash, noCommit) in [
            (true, false, false), (false, false, true), (true, true, false), (true, true, true)
        ] {
            _ = try git(["reset", "--hard", root])
            let selected = try await target(side)
            model.actOnCommit(selected, action: .merge, target: model.actionTarget(),
                              noCommit: noCommit, noFastForward: noFastForward, squash: squash)
            try await settle()
            XCTAssertNil(model.lastError)
            let head = try git(["rev-parse", "HEAD"])
            if squash && noCommit {
                XCTAssertEqual(head, root)
                XCTAssertEqual(try git(["show", ":tracked.txt"]), "side")
            } else if squash {
                XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "Merge commit '\(side)'")
                XCTAssertEqual(try git(["rev-parse", "HEAD^"]), root)
                let again = try await target(side)
                model.actOnCommit(again, action: .merge, target: model.actionTarget(), squash: true)
                try await settle()
                XCTAssertNil(model.lastError)
                XCTAssertEqual(try git(["rev-parse", "HEAD"]), head, "No staged difference must not create an empty squash commit")
            } else if noFastForward {
                XCTAssertEqual(try git(["rev-parse", "HEAD^2"]), side)
            } else {
                XCTAssertEqual(head, side, "No Commit alone cannot prevent fast-forward")
            }
        }
    }

    func testMergeMainlineCherryPickAndRevert() async throws {
        let root = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-c", "side"])
        try "side".write(to: directory.appendingPathComponent("side.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "side"])
        _ = try git(["switch", "main"])
        let main = try commit("main", text: "main\n")
        _ = try git(["merge", "--no-ff", "-m", "merge", "side"])
        let merge = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "keep-merge"])
        _ = try git(["reset", "--hard", main])
        let selected = try await target(merge)
        model.actOnCommit(selected, action: .cherryPick, target: model.actionTarget(), parent: 1)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["show", "HEAD:side.txt"]), "side")
        _ = try git(["reset", "--hard", merge])
        let revert = try await target(merge)
        model.actOnCommit(revert, action: .revert, target: model.actionTarget(), parent: 2)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["show", "HEAD:tracked.txt"]), "root")
        XCTAssertEqual(try git(["show", "HEAD:side.txt"]), "side")
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"]), root)
    }

    func testConflictPreservesIndexAndCanAbortOrContinueWithGit() async throws {
        _ = try git(["switch", "-c", "side"])
        let side = try commit("side", text: "side\n")
        _ = try git(["switch", "main"])
        let main = try commit("main", text: "main\n")
        let selected = try await target(side)
        model.actOnCommit(selected, action: .cherryPick, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertNotNil(model.repositoryOperation)
        XCTAssertEqual(model.operation?.failedCommand, ["cherry-pick", side])
        XCTAssertTrue(model.operation?.gitError?.contains("could not apply") == true)
        XCTAssertTrue(try git(["ls-files", "-u"]).contains("tracked.txt"))
        _ = try git(["cherry-pick", "--abort"])
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), main)
        let again = try await target(side)
        model.actOnCommit(again, action: .merge, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertNotNil(model.repositoryOperation)
        try "resolved\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "tracked.txt"])
        _ = try git(["-c", "core.editor=true", "merge", "--continue"])
        model.refresh()
        try await settle()
        XCTAssertNil(model.repositoryOperation)
        XCTAssertEqual(try git(["show", "HEAD:tracked.txt"]), "resolved")
        XCTAssertEqual(try git(["rev-parse", "HEAD^2"]), side)
    }

    func testFailedSavePreparationAndChangedHeadDoNotMutate() async throws {
        let root = try git(["rev-parse", "HEAD"])
        let second = try commit("second", text: "second\n")
        let selected = try await target(root)
        model.actOnCommit(selected, action: .checkout, target: model.actionTarget(), prepare: { false })
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), second)
        let old = model.actionTarget()
        _ = try git(["commit", "--allow-empty", "-qm", "external"])
        let external = try git(["rev-parse", "HEAD"])
        model.actOnCommit(selected, action: .checkout, target: old)
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), external)
    }

    func testProjectResolutionCannotAuthorizeOldRepositorySnapshot() async throws {
        func awaitState(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition() {
                guard Date() < deadline else { throw WorkspaceError.timedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        for directory in [firstRoot, secondRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Projection"],
                              ["config", "user.email", "projection@invalid"], ["config", "commit.gpgsign", "false"],
                              ["commit", "--allow-empty", "-qm", directory.lastPathComponent + "-root"],
                              ["commit", "--allow-empty", "-qm", directory.lastPathComponent + "-head"]] {
                let result = GitCommandExecution.run(arguments, in: directory.path)
                XCTAssertEqual(result.status, 0, result.stderr)
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceApplication = WorkspaceApplication()
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let first = Project(fallbackName: "First", workspaceConfiguration: .standard)
        first.customDirectory = firstRoot.path
        let second = Project(fallbackName: "Second", workspaceConfiguration: .standard)
        second.customDirectory = secondRoot.path
        manager.projects = [first, second]
        manager.selectedProjectID = first.id
        let model = GitStatusModel()
        let firstIdentity = try XCTUnwrap(first.panelContext).identity
        let secondIdentity = try XCTUnwrap(second.panelContext).identity
        manager.syncGitStatus(model)
        try await awaitState { model.matchesPanelTarget(firstIdentity) && model.hasResolvedStatus && !model.isRefreshing }
        let old = try XCTUnwrap(model.recentCommits.last)
        let oldTarget = model.actionTarget()
        let originalHead = model.headOID
        manager.selectedProjectID = second.id
        manager.syncGitStatus(model)
        XCTAssertFalse(model.matchesPanelTarget(firstIdentity))
        XCTAssertFalse(model.isCurrent(oldTarget))
        model.actOnCommit(old, action: .checkout, target: model.actionTarget())
        XCTAssertFalse(model.isBusy, "An unresolved projection must not acquire a mutation")
        try await awaitState { model.matchesPanelTarget(secondIdentity) && !model.isRefreshing }
        XCTAssertEqual(GitCommandExecution.run(["rev-parse", "HEAD"], in: firstRoot.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertEqual(GitCommandExecution.run(["branch", "--show-current"], in: secondRoot.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines), "main")
        manager.selectedProjectID = first.id
        manager.syncGitStatus(model)
        try await awaitState { model.matchesPanelTarget(firstIdentity) && !model.isRefreshing }
        XCTAssertFalse(model.isCurrent(oldTarget), "Switching away and back must not revive an old confirmation")
    }
}
