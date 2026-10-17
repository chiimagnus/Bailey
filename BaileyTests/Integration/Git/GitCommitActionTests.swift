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
}
