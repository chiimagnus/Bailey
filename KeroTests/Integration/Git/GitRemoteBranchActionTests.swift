import Foundation
import XCTest
@testable import kero

@MainActor
final class GitRemoteBranchActionTests: XCTestCase {
    private var directory: URL!
    private var model: GitStatusModel!
    private var remoteFolders: [URL] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-remote-menu-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = GitStatusModel()
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Remote Menu Test"])
        _ = try git(["config", "user.email", "remote@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["config", "core.hooksPath", "/dev/null"])
        _ = try git(["commit", "--allow-empty", "-qm", "base"])
    }

    override func tearDown() async throws {
        for folder in remoteFolders { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let result = GitCommandExecution.run(args, in: directory.path, timeout: 15)
        guard result.status == 0 else {
            XCTFail(result.stderr)
            throw WorkspaceError.notFound
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeBareRemote(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-remote-bare-" + UUID().uuidString)
        let result = GitCommandExecution.run(["init", "--bare", "-q", folder.path],
                                             in: directory.path)
        XCTAssertEqual(result.status, 0, result.stderr)
        remoteFolders.append(folder)
        _ = try git(["remote", "add", name, folder.path])
        return folder
    }

    private func settle() async throws {
        let deadline = Date().addingTimeInterval(20)
        while !model.hasResolvedStatus || model.isBusy || model.isRefreshing {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func refresh() async throws {
        model.sync(root: directory.path)
        try await settle()
    }

    func testCheckoutRemoteCreatesTrackingBranchAtSelectedRemoteOID() async throws {
        _ = try makeBareRemote("origin")
        _ = try git(["push", "origin", "main:refs/heads/topic/nested"])
        _ = try git(["fetch", "-q", "origin"])
        let expected = try git(["rev-parse", "HEAD"])
        try await refresh()
        let remote = try XCTUnwrap(model.remoteBranch(named: "origin/topic/nested"))
        model.checkoutRemoteBranch(remote, localName: "topic/nested",
                                   checkoutExistingAndPull: false, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertEqual(try git(["branch", "--show-current"]), "topic/nested")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), expected)
        XCTAssertEqual(try git(["config", "branch.topic/nested.remote"]), "origin")
        XCTAssertEqual(try git(["config", "branch.topic/nested.merge"]), "refs/heads/topic/nested")
    }

    func testRemoteCheckoutNameConflictThenExplicitExistingCheckoutAndPull() async throws {
        _ = try makeBareRemote("origin")
        let base = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "topic/nested"])
        try Data("from origin\n".utf8).write(to: directory.appendingPathComponent("remote.txt"))
        _ = try git(["add", "remote.txt"])
        _ = try git(["commit", "-qm", "remote commit"])
        let newer = try git(["rev-parse", "HEAD"])
        _ = try git(["push", "origin", "main:refs/heads/topic/nested"])
        _ = try git(["reset", "--hard", base])
        _ = try git(["fetch", "-q", "origin"])
        try await refresh()
        let remote = try XCTUnwrap(model.remoteBranch(named: "origin/topic/nested"))

        model.checkoutRemoteBranch(remote, localName: "topic/nested",
                                   checkoutExistingAndPull: false, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError, "A conflicting local branch must not be silently replaced")
        XCTAssertEqual(try git(["branch", "--show-current"]), "main")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/topic/nested"]), base)

        model.checkoutRemoteBranch(remote, localName: "topic/nested",
                                   checkoutExistingAndPull: true, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertEqual(try git(["branch", "--show-current"]), "topic/nested")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), newer)
        XCTAssertEqual(String(data: try Data(contentsOf: directory.appendingPathComponent("remote.txt")),
                              encoding: .utf8), "from origin\n")
    }

    func testExistingCheckoutSucceedsEvenWhenFollowingPullFails() async throws {
        _ = try makeBareRemote("origin")
        let base = try git(["rev-parse", "HEAD"])
        try Data("base\n".utf8).write(to: directory.appendingPathComponent("conflict.txt"))
        _ = try git(["add", "conflict.txt"])
        _ = try git(["commit", "-qm", "shared base"])
        let shared = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-c", "topic/conflict"])
        try Data("local\n".utf8).write(to: directory.appendingPathComponent("conflict.txt"))
        _ = try git(["commit", "-qam", "local edit"])
        let local = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "main"])
        try Data("server\n".utf8).write(to: directory.appendingPathComponent("conflict.txt"))
        _ = try git(["commit", "-qam", "remote edit"])
        _ = try git(["push", "origin", "main:refs/heads/topic/conflict"])
        _ = try git(["reset", "--hard", shared])
        _ = try git(["fetch", "-q", "origin"])
        try await refresh()
        let remote = try XCTUnwrap(model.remoteBranch(named: "origin/topic/conflict"))
        model.checkoutRemoteBranch(remote, localName: "topic/conflict",
                                   checkoutExistingAndPull: true, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError, "A conflicting Pull must be reported")
        XCTAssertEqual(try git(["branch", "--show-current"]), "topic/conflict",
                       "Switch succeeded; Pull failure must not roll back an unrelated checkout")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), local)
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"]), base)
    }

    func testRemoteRefChangesAfterSnapshotRejectOldTargetBeforeSideEffects() async throws {
        let server = try makeBareRemote("origin")
        _ = try git(["push", "origin", "main:refs/heads/topic/stale"])
        _ = try git(["fetch", "-q", "origin"])
        try await refresh()
        let remote = try XCTUnwrap(model.remoteBranch(named: "origin/topic/stale"))
        let start = try git(["rev-parse", "HEAD"])
        _ = try git(["commit", "--allow-empty", "-qm", "other ref target"])
        let moved = try git(["rev-parse", "HEAD"])
        _ = try git(["reset", "--hard", start])
        _ = try git(["update-ref", "refs/remotes/origin/topic/stale", moved])
        model.deleteRemoteBranch(remote, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), start)
        XCTAssertEqual(GitCommandExecution.run(["--git-dir", server.path,
            "show-ref", "--verify", "refs/heads/topic/stale"], in: directory.path).status, 0,
            "Stale confirmation must not delete a remote branch")
    }

    func testFetchRemoteIntoNoncurrentLocalBranchWithoutAndWithForce() async throws {
        _ = try makeBareRemote("origin")
        let original = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "topic/nested"])
        try Data("server".utf8).write(to: directory.appendingPathComponent("server.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "remote state"])
        let server = try git(["rev-parse", "HEAD"])
        _ = try git(["push", "origin", "main:refs/heads/topic/nested"])
        _ = try git(["fetch", "-q", "origin"])
        try await refresh()
        let remote = try XCTUnwrap(model.remoteBranch(named: "origin/topic/nested"))
        model.fetchIntoLocalBranch(remote, force: false, destinationOID: original, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/topic/nested"]), server)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), server)

        _ = try git(["update-ref", "refs/heads/topic/nested", original])
        try await refresh()
        let refreshed = try XCTUnwrap(model.remoteBranch(named: "origin/topic/nested"))
        // The tracking source remains the same OID; -f must still respect Git's
        // protection for worktrees where the destination is checked out.
        model.fetchIntoLocalBranch(refreshed, force: true, destinationOID: original, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/topic/nested"]), server)
    }

    func testPullSquashProducesSingleParentCommit() async throws {
        _ = try makeBareRemote("origin")
        let original = try git(["rev-parse", "HEAD"])
        try Data("squashed".utf8).write(to: directory.appendingPathComponent("server.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "remote work"])
        _ = try git(["push", "origin", "main:refs/heads/topic/nested"])
        _ = try git(["reset", "--hard", original])
        _ = try git(["fetch", "-q", "origin"])
        try await refresh()
        let remote = try XCTUnwrap(model.remoteBranch(named: "origin/topic/nested"))
        model.pullRemoteBranch(remote, noFastForward: false, squash: true,
                               target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertEqual(try git(["rev-parse", "HEAD^"]), original)
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]),
                       "Merge branch 'origin/topic/nested'")
        XCTAssertEqual(try git(["show", "HEAD:server.txt"]), "squashed")
    }

    func testRemoteDeleteLeavesOtherServerWithSameNameUntouched() async throws {
        let origin = try makeBareRemote("origin")
        let backup = try makeBareRemote("backup")
        _ = try git(["push", "origin", "main:refs/heads/topic/nested"])
        _ = try git(["push", "backup", "main:refs/heads/topic/nested"])
        _ = try git(["fetch", "-q", "--all"])
        try await refresh()
        let remote = try XCTUnwrap(model.remoteBranch(named: "origin/topic/nested"))
        model.deleteRemoteBranch(remote, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertNotEqual(GitCommandExecution.run([
            "--git-dir", origin.path, "show-ref", "--verify", "refs/heads/topic/nested"
        ], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run([
            "--git-dir", backup.path, "show-ref", "--verify", "refs/heads/topic/nested"
        ], in: directory.path).status, 0)
    }


    func testForceFetchOverridesDivergenceButNeverCheckedOutWorktree() async throws {
        _ = try makeBareRemote("origin")
        let base = try git(["rev-parse", "HEAD"])
        try Data("server".utf8).write(to: directory.appendingPathComponent("remote-side.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "remote divergent"])
        let remoteOID = try git(["rev-parse", "HEAD"])
        _ = try git(["push", "origin", "main:refs/heads/topic/nested"])
        _ = try git(["reset", "--hard", base])
        _ = try git(["switch", "-c", "topic/nested"])
        try Data("local".utf8).write(to: directory.appendingPathComponent("local-side.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "local divergent"])
        let localOID = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "main"])
        _ = try git(["fetch", "-q", "origin"])
        try await refresh()
        let selected = try XCTUnwrap(model.remoteBranch(named: "origin/topic/nested"))
        model.fetchIntoLocalBranch(selected, force: false, destinationOID: localOID, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError, "Normal fetch must reject a non-FF update")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/topic/nested"]), localOID)
        model.fetchIntoLocalBranch(selected, force: true, destinationOID: localOID, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/topic/nested"]), remoteOID)

        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-remote-linked-" + UUID().uuidString)
        defer {
            _ = GitCommandExecution.run(["worktree", "remove", "-f", linked.path],
                                         in: directory.path)
            try? FileManager.default.removeItem(at: linked)
        }
        _ = try git(["worktree", "add", "-q", linked.path, "topic/nested"])
        _ = try git(["update-ref", "refs/remotes/origin/topic/nested", base])
        try await refresh()
        let tracked = try XCTUnwrap(model.remoteBranch(named: "origin/topic/nested"))
        model.fetchIntoLocalBranch(tracked, force: true, destinationOID: remoteOID, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError, "Other worktree checkout must block even force fetch")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/topic/nested"]), remoteOID)
        XCTAssertEqual(GitCommandExecution.run(["rev-parse", "HEAD"], in: linked.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines), remoteOID)
    }

    func testPullNoFFCreatesRealMergeCommit() async throws {
        _ = try makeBareRemote("origin")
        let base = try git(["rev-parse", "HEAD"])
        try Data("remote content".utf8).write(to: directory.appendingPathComponent("side.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "remote change"])
        let server = try git(["rev-parse", "HEAD"])
        _ = try git(["push", "origin", "main:refs/heads/topic/nested"])
        _ = try git(["reset", "--hard", base])
        _ = try git(["fetch", "-q", "origin"])
        try await refresh()
        let remote = try XCTUnwrap(model.remoteBranch(named: "origin/topic/nested"))
        model.pullRemoteBranch(remote, noFastForward: true, squash: false,
                               target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertEqual(try git(["rev-list", "--parents", "-n", "1", "HEAD"])
            .split(separator: " ").count, 3)
        XCTAssertEqual(try git(["rev-parse", "HEAD^1"]), base)
        XCTAssertEqual(try git(["rev-parse", "HEAD^2"]), server)
    }

    func testDeletionOfAlreadyAbsentRemoteRemovesOnlyStaleTrackingRef() async throws {
        let first = try makeBareRemote("origin")
        _ = try makeBareRemote("backup")
        _ = try git(["push", "origin", "main:refs/heads/topic/nested"])
        _ = try git(["push", "backup", "main:refs/heads/topic/nested"])
        _ = try git(["fetch", "-q", "--all"])
        let removed = GitCommandExecution.run([
            "--git-dir", first.path, "update-ref", "-d", "refs/heads/topic/nested"
        ], in: directory.path)
        XCTAssertEqual(removed.status, 0)
        try await refresh()
        let selected = try XCTUnwrap(model.remoteBranch(named: "origin/topic/nested"))
        model.deleteRemoteBranch(selected, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertNotEqual(GitCommandExecution.run([
            "show-ref", "--verify", "refs/remotes/origin/topic/nested"
        ], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run([
            "show-ref", "--verify", "refs/remotes/backup/topic/nested"
        ], in: directory.path).status, 0)
    }

    func testRemoteProtectedBranchDeletionKeepsServerAndLocalTracking() async throws {
        let server = try makeBareRemote("origin")
        _ = try git(["push", "origin", "main:refs/heads/topic/nested"])
        _ = try git(["fetch", "-q", "origin"])
        let protected = GitCommandExecution.run([
            "--git-dir", server.path, "config", "receive.denyDeletes", "true"
        ], in: directory.path)
        XCTAssertEqual(protected.status, 0)
        try await refresh()
        let remote = try XCTUnwrap(model.remoteBranch(named: "origin/topic/nested"))
        model.deleteRemoteBranch(remote, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError, "Git server protections must not be bypassed")
        XCTAssertEqual(GitCommandExecution.run([
            "--git-dir", server.path, "show-ref", "--verify", "refs/heads/topic/nested"
        ], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run([
            "show-ref", "--verify", "refs/remotes/origin/topic/nested"
        ], in: directory.path).status, 0)
    }

    func testSymbolicRemoteHEADIsHiddenButRealHEADBranchRemains() async throws {
        let oid = try git(["rev-parse", "HEAD"])
        _ = try git(["remote", "add", "origin", directory.path])
        _ = try git(["remote", "add", "upstream", directory.path])
        _ = try git(["update-ref", "refs/remotes/origin/HEAD", oid])
        _ = try git(["update-ref", "refs/remotes/upstream/main", oid])
        _ = try git(["symbolic-ref", "refs/remotes/upstream/HEAD",
                      "refs/remotes/upstream/main"])
        try await refresh()
        let refs = try XCTUnwrap(model.recentCommits.first { $0.hash == oid }).references
            .filter { $0.kind == .remoteBranch }.map(\.name)
        XCTAssertTrue(refs.contains("origin/HEAD"),
                      "A direct remote HEAD ref is a real branch and must remain")
        XCTAssertFalse(refs.contains { $0.hasPrefix("upstream/HEAD") },
                       "A symbolic remote HEAD is an alias, not a separately manageable branch")
        XCTAssertTrue(refs.contains("upstream/main"))
    }

    func testLongerConfiguredRemotePrefixIdentifiesCorrectRepository() async throws {
        _ = try git(["config", "remote.origin.url", directory.path])
        _ = try git(["config", "remote.origin.fetch",
                      "+refs/heads/*:refs/remotes/origin/*"])
        _ = try git(["config", "remote.origin/team.url", directory.path])
        _ = try git(["config", "remote.origin/team.fetch",
                      "+refs/heads/*:refs/remotes/origin/team/*"])
        let oid = try git(["rev-parse", "HEAD"])
        _ = try git(["update-ref", "refs/remotes/origin/team/topic/nested", oid])
        try await refresh()
        let target = try XCTUnwrap(model.remoteBranch(named: "origin/team/topic/nested"))
        XCTAssertEqual(target.remote, "origin/team")
        XCTAssertEqual(target.branch, "topic/nested")
        XCTAssertEqual(target.oid, oid)
        XCTAssertNil(model.remoteBranch(named: "unconfigured/foo"))
    }
}
