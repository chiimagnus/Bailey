import Foundation
import XCTest
@testable import kero

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
