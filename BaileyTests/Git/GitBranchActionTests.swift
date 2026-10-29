import Foundation
import XCTest
@testable import Bailey

private actor ArchiveFixtureBackend: WorkspaceBackend {
    private var exceedReadLimit = false
    private var failCleanup = false
    private(set) var temporaryFolders: [String] = []
    private(set) var cleanupAttempts: [String] = []

    func simulateOversizeRead(_ value: Bool) { exceedReadLimit = value }
    func simulateCleanupFailure(_ value: Bool) { failCleanup = value }

    func run(argv: [String], cwd: String?, env: [String: String]?,
             stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        var variables = ProcessInfo.processInfo.environment
        for (key, value) in env ?? [:] { variables[key] = value }
        let result = try await LocalWorkspaceBackend.shared.run(
            argv: ["/usr/bin/env"] + argv, cwd: cwd, env: variables,
            stdin: stdin, timeout: timeout
        )
        if argv.first == "mktemp", result.status == 0 {
            let folder = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            temporaryFolders.append(folder)
        }
        return result
    }

    func read(path: String, maxBytes: Int) async throws -> Data {
        if exceedReadLimit { throw WorkspaceError.tooLarge }
        return try await LocalWorkspaceBackend.shared.read(path: path, maxBytes: maxBytes)
    }
    func delete(paths: [String]) async throws {
        for path in paths {
            cleanupAttempts.append(path)
            guard temporaryFolders.contains(path), path.hasPrefix("/tmp/bailey-archive-") else {
                throw WorkspaceError.notFound
            }
            if failCleanup { throw WorkspaceError.timedOut }
            try FileManager.default.removeItem(atPath: path)
        }
    }

    func cleanUpTestOwnedFolders() {
        for folder in temporaryFolders where folder.hasPrefix("/tmp/bailey-archive-") {
            try? FileManager.default.removeItem(atPath: folder)
        }
    }
    func list(directory: String) async throws -> [WorkspaceEntry] { [] }
    func stat(path: String) async throws -> WorkspaceStat? {
        try await LocalWorkspaceBackend.shared.stat(path: path)
    }
    func readSymlinkDestination(path: String) async throws -> String? { nil }
    func write(path: String, data: Data) async throws { throw WorkspaceError.notFound }
    func createFile(path: String) async throws { throw WorkspaceError.notFound }
    func createDirectory(path: String) async throws { throw WorkspaceError.notFound }
    func copy(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func rename(from: String, to: String) async throws { throw WorkspaceError.notFound }
}

@MainActor
final class GitBranchActionTests: XCTestCase {
    private var directory: URL!
    private var model: GitStatusModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-branch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = GitStatusModel()
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Branch Test"])
        _ = try git(["config", "user.email", "branch@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["config", "core.hooksPath", "/dev/null"])
        _ = try git(["commit", "--allow-empty", "-qm", "root"])
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let result = GitCommandExecution.run(arguments, in: directory.path, timeout: 12)
        guard result.status == 0 else {
            XCTFail(result.stderr)
            throw WorkspaceError.notFound
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func settle() async throws {
        let deadline = Date().addingTimeInterval(16)
        while !model.hasResolvedStatus || model.isBusy || model.isRefreshing {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func refresh() async throws {
        model.sync(root: directory.path)
        try await settle()
    }

    func testGraphBranchSwitchRejectsExternallyMovedRefBeforeCheckingOut() async throws {
        let original = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "from-graph"])
        _ = try git(["commit", "--allow-empty", "-qm", "later main"])
        let moved = try git(["rev-parse", "HEAD"])
        XCTAssertNotEqual(original, moved)
        try await refresh()
        XCTAssertEqual(model.refsByName["refs/heads/from-graph"]?.oid, original)
        _ = try git(["update-ref", "refs/heads/from-graph", moved])

        model.switchBranch(to: "from-graph", expectedOID: original)
        try await settle()
        XCTAssertNotNil(model.lastError,
                        "An old Graph menu must not switch to an externally moved branch")
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"]), "refs/heads/main")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), moved)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/from-graph"]), moved)
        XCTAssertTrue(try git(["status", "--porcelain=v1"]).isEmpty)

        model.refresh()
        try await settle()
        model.switchBranch(to: "from-graph", expectedOID: moved)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"]), "refs/heads/from-graph")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), moved)
        XCTAssertTrue(try git(["status", "--porcelain=v1"]).isEmpty)
    }

    func testSwitchRejectsOptionNamesAndPreviousCheckoutAliasInsteadOfChangingHead() async throws {
        _ = try git(["branch", "other"])
        let original = try git(["rev-parse", "HEAD"])
        for name in ["-d", "-"] {
            _ = try git(["update-ref", "refs/heads/" + name, original])
            _ = try git(["switch", "other"])
            _ = try git(["switch", "main"])
            try await refresh()
            XCTAssertTrue(model.branches.contains(name), "The external Ref must actually exist")
            model.switchBranch(to: name, expectedOID: original)
            try await settle()
            XCTAssertNotNil(model.lastError, "An option or shorthand must not select a different target")
            XCTAssertEqual(try git(["symbolic-ref", "HEAD"]), "refs/heads/main")
            XCTAssertEqual(try git(["rev-parse", "HEAD"]), original)
        }
        model.switchBranch(to: "other", expectedOID: original)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"]), "refs/heads/other")
    }

    func testHistoryBranchCreationCheckoutAndExplicitReplacement() async throws {
        let root = try git(["rev-parse", "HEAD"])
        try Data("new\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "second"])
        let second = try git(["rev-parse", "HEAD"])
        try await refresh()
        let target = model.actionTarget()
        model.createBranch(named: "feature/start", at: root, checkout: false, replacing: nil, target: target)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/feature/start"]), root)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), second)

        model.createBranch(named: "feature/start", at: second, checkout: false, replacing: nil, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/feature/start"]), root)

        model.createBranch(named: "feature/start", at: second, checkout: true, replacing: root, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), second)
        XCTAssertEqual(try git(["branch", "--show-current"]), "feature/start")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/feature/start"]), second)
    }

    func testRenameDeleteAndNoUnsafeForceDefaults() async throws {
        let root = try git(["rev-parse", "HEAD"])
        try Data("new\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "second"])
        let second = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "feature/original", second])
        _ = try git(["branch", "feature/other", root])
        try await refresh()
        model.renameBranch(from: "feature/original", to: "feature/renamed", target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/feature/renamed"]), second)
        model.renameBranch(from: "feature/renamed", to: "feature/other", target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/feature/renamed"]), second)

        model.deleteBranch("feature/renamed", force: false, remoteNames: [], target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        let missing = GitCommandExecution.run(["show-ref", "--verify", "refs/heads/feature/renamed"], in: directory.path)
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), second)
    }

    func testPushSpecificNonHeadBranchToChosenRemote() async throws {
        let root = try git(["rev-parse", "HEAD"])
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-bare-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: remote) }
        let initialized = GitCommandExecution.run(["init", "--bare", "-q", remote.path], in: directory.path)
        XCTAssertEqual(initialized.status, 0, initialized.stderr)
        _ = try git(["remote", "add", "origin", remote.path])
        _ = try git(["branch", "feature/old", root])
        try Data("new\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "main moved"])
        let head = try git(["rev-parse", "HEAD"])
        try await refresh()
        model.pushBranch("feature/old", remotes: ["origin"], setUpstream: true, mode: .normal, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        let remoteOID = GitCommandExecution.run(["--git-dir", remote.path, "rev-parse", "refs/heads/feature/old"], in: directory.path)
        XCTAssertEqual(remoteOID.stdout.trimmingCharacters(in: .whitespacesAndNewlines), root)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/feature/old"]), root)
    }

    func testMultiRemoteDeleteContinuesAfterRemoteRejection() async throws {
        let name = "topic/fanout"
        _ = try git(["branch", name])
        let remoteDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-remotes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: remoteDirectory) }
        for alias in ["one", "two", "three"] {
            let path = remoteDirectory.appendingPathComponent(alias)
            let initResult = GitCommandExecution.run(["init", "--bare", "-q", path.path], in: directory.path)
            XCTAssertEqual(initResult.status, 0, initResult.stderr)
            _ = try git(["remote", "add", alias, path.path])
            _ = try git(["push", alias, "refs/heads/" + name + ":refs/heads/" + name])
            _ = try git(["fetch", "-q", alias])
        }
        let protectedRemote = remoteDirectory.appendingPathComponent("two").path
        let protection = GitCommandExecution.run(
            ["--git-dir", protectedRemote, "config", "receive.denyDeletes", "true"], in: directory.path
        )
        XCTAssertEqual(protection.status, 0, protection.stderr)

        try await refresh()
        XCTAssertEqual(Set(model.trackingRemotes(for: name)), Set(["one", "two", "three"]))
        model.deleteBranch(name, force: false, remoteNames: ["one", "two", "three"],
                           target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError, "The middle remote rejection must be reported")
        XCTAssertNotNil(model.operation?.output.range(of: "three"))
        let local = GitCommandExecution.run(["show-ref", "--verify", "refs/heads/" + name], in: directory.path)
        XCTAssertNotEqual(local.status, 0)
        for alias in ["one", "two", "three"] {
            let path = remoteDirectory.appendingPathComponent(alias).path
            let remote = GitCommandExecution.run(["--git-dir", path, "show-ref", "--verify",
                                                  "refs/heads/" + name], in: directory.path)
            XCTAssertEqual(remote.status == 0, alias == "two", "Remote \(alias) must reflect the actual partial result")
        }
    }

    func testDeletingAlreadyMissingRemoteRemovesOnlyMatchingTrackingRef() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-missing-remote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        _ = try git(["branch", "topic/missing"])
        for remote in ["origin", "second"] {
            let server = fixture.appendingPathComponent(remote)
            let initialized = GitCommandExecution.run(
                ["init", "--bare", "-q", server.path], in: directory.path
            )
            XCTAssertEqual(initialized.status, 0)
            _ = try git(["remote", "add", remote, server.path])
            _ = try git(["push", remote, "topic/missing:topic/missing"])
            _ = try git(["fetch", "-q", remote])
        }
        let first = fixture.appendingPathComponent("origin")
        let disappeared = GitCommandExecution.run(
            ["--git-dir", first.path, "update-ref", "-d", "refs/heads/topic/missing"],
            in: directory.path
        )
        XCTAssertEqual(disappeared.status, 0)

        try await refresh()
        model.deleteBranch("topic/missing", force: false, remoteNames: ["origin"],
                           target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, "The server reports a missing remote ref; remove only its stale local tracking ref")
        XCTAssertNotEqual(GitCommandExecution.run(
            ["show-ref", "--verify", "refs/remotes/origin/topic/missing"],
            in: directory.path
        ).status, 0)
        XCTAssertEqual(GitCommandExecution.run(
            ["show-ref", "--verify", "refs/remotes/second/topic/missing"],
            in: directory.path
        ).status, 0, "Another remote with the same branch name must remain intact")
    }

    func testMultiRemotePushStopsBeforeSecondAfterFirstRejects() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-first-push-reject-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for remote in ["rejecting", "unattempted"] {
            let server = fixture.appendingPathComponent(remote)
            let initialized = GitCommandExecution.run(
                ["init", "--bare", "-q", server.path], in: directory.path
            )
            XCTAssertEqual(initialized.status, 0)
            _ = try git(["remote", "add", remote, server.path])
        }
        _ = try git(["switch", "-c", "topic/push"])
        _ = try git(["push", "rejecting", "topic/push"])
        try Data("remote".utf8).write(to: directory.appendingPathComponent("remote.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "remote version"])
        _ = try git(["push", "rejecting", "topic/push"])
        let remoteOID = try git(["rev-parse", "HEAD"])
        _ = try git(["reset", "--hard", "HEAD~"])
        try Data("local".utf8).write(to: directory.appendingPathComponent("local.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "divergent local version"])
        _ = try git(["switch", "main"])
        try await refresh()
        model.pushBranch("topic/push", remotes: ["rejecting", "unattempted"],
                         setUpstream: true, mode: .normal, target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.operation?.output.contains("unattempted") == true,
                      "The operation should explicitly identify the unattempted remote")
        let rejecting = GitCommandExecution.run([
            "--git-dir", fixture.appendingPathComponent("rejecting").path,
            "rev-parse", "refs/heads/topic/push"
        ], in: directory.path)
        XCTAssertEqual(rejecting.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       remoteOID)
        XCTAssertNotEqual(GitCommandExecution.run([
            "--git-dir", fixture.appendingPathComponent("unattempted").path,
            "show-ref", "--verify", "refs/heads/topic/push"
        ], in: directory.path).status, 0, "A failed first push cannot mutate the next remote")
    }

    func testBranchRefValidationAndOtherWorktreeCheckoutGuard() async throws {
        try await refresh()
        let head = try git(["rev-parse", "HEAD"])
        for name in ["-unsafe", "invalid..ref", "invalid ref", "invalid~ref"] {
            model.createBranch(named: name, at: nil, checkout: false, replacing: nil,
                               target: model.actionTarget())
            try await settle()
            XCTAssertNotNil(model.lastError, "Invalid Git branch name must not be accepted: \(name)")
            XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
            XCTAssertEqual(try git(["for-each-ref", "--format=%(refname)", "refs/heads"]),
                           "refs/heads/main", "Invalid input must not create any additional ref")
        }
        model.createBranch(named: "topic/with.dots", at: nil, checkout: false, replacing: nil,
                           target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        let expected = try git(["rev-parse", "refs/heads/topic/with.dots"])
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-linked-worktree-" + UUID().uuidString)
        defer {
            _ = GitCommandExecution.run(["worktree", "remove", "-f", linked.path],
                                        in: directory.path)
            try? FileManager.default.removeItem(at: linked)
        }
        _ = try git(["worktree", "add", "-q", linked.path, "topic/with.dots"])
        try await refresh()
        model.createBranch(named: "topic/with.dots", at: nil, checkout: false, replacing: expected,
                           target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError, "A checked-out branch in another worktree must not be force-moved")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/topic/with.dots"]), expected)
    }

    func testUnmergedLocalBranchRequiresForceAndLeavesRemoteUntouched() async throws {
        _ = try git(["switch", "-c", "unmerged"])
        try Data("isolated".utf8).write(to: directory.appendingPathComponent("alone.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "isolated"])
        let branchOID = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "main"])
        try await refresh()
        model.deleteBranch("unmerged", force: false, remoteNames: [], target: model.actionTarget())
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/unmerged"]), branchOID)
        model.deleteBranch("unmerged", force: true, remoteNames: [], target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        let missing = GitCommandExecution.run(["show-ref", "--verify", "refs/heads/unmerged"], in: directory.path)
        XCTAssertNotEqual(missing.status, 0)
    }

    func testPushRemotesDefaultsOrderAndLastSuccessfulUpstream() async throws {
        let remotes = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-push-remotes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: remotes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: remotes) }
        for alias in ["origin", "backup", "third"] {
            let path = remotes.appendingPathComponent(alias)
            let result = GitCommandExecution.run(["init", "--bare", "-q", path.path], in: directory.path)
            XCTAssertEqual(result.status, 0)
            _ = try git(["remote", "add", alias, path.path])
        }
        _ = try git(["branch", "feature"])
        _ = try git(["config", "branch.feature.pushRemote", "backup"])
        _ = try git(["config", "branch.feature.remote", "origin"])
        _ = try git(["config", "remote.pushDefault", "third"])
        try await refresh()
        let preferredBackup = await model.preferredPushRemote(for: "feature")
        XCTAssertEqual(preferredBackup, "backup")
        _ = try git(["config", "--unset", "branch.feature.pushRemote"])
        let preferredOrigin = await model.preferredPushRemote(for: "feature")
        XCTAssertEqual(preferredOrigin, "origin")
        _ = try git(["config", "--unset", "branch.feature.remote"])
        let preferredThird = await model.preferredPushRemote(for: "feature")
        XCTAssertEqual(preferredThird, "third")

        model.pushBranch("feature", remotes: ["origin", "backup", "third"],
                         setUpstream: true, mode: .normal, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["config", "branch.feature.remote"]), "third")
        XCTAssertEqual(try git(["config", "branch.feature.merge"]), "refs/heads/feature")
        for alias in ["origin", "backup", "third"] {
            let result = GitCommandExecution.run(["--git-dir", remotes.appendingPathComponent(alias).path,
                                                  "rev-parse", "refs/heads/feature"], in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
    }

    func testPushForceWithLeaseRejectsStaleTrackingWhileForceSucceeds() async throws {
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-force-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: remote) }
        XCTAssertEqual(GitCommandExecution.run(["init", "--bare", "-q", remote.path], in: directory.path).status, 0)
        _ = try git(["remote", "add", "origin", remote.path])
        _ = try git(["switch", "-c", "feature"])
        let baseline = try git(["rev-parse", "HEAD"])
        try Data("remote".utf8).write(to: directory.appendingPathComponent("remote.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "remote divergence"])
        let remoteCommit = try git(["rev-parse", "HEAD"])
        _ = try git(["push", "origin", "feature:feature"])
        _ = try git(["reset", "--hard", baseline])
        try Data("local".utf8).write(to: directory.appendingPathComponent("local.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "local divergence"])
        let localCommit = try git(["rev-parse", "HEAD"])
        _ = try git(["update-ref", "refs/remotes/origin/feature", baseline])
        _ = try git(["switch", "main"])
        try await refresh()
        for mode in [GitStatusModel.BranchPushMode.normal, .forceWithLease] {
            model.pushBranch("feature", remotes: ["origin"], setUpstream: false,
                             mode: mode, target: model.actionTarget())
            try await settle()
            XCTAssertNotNil(model.lastError)
            let remoteOID = GitCommandExecution.run(["--git-dir", remote.path, "rev-parse",
                                                      "refs/heads/feature"], in: directory.path)
            XCTAssertEqual(remoteOID.stdout.trimmingCharacters(in: .whitespacesAndNewlines), remoteCommit)
        }
        model.pushBranch("feature", remotes: ["origin"], setUpstream: false,
                         mode: .force, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        let remoteOID = GitCommandExecution.run(["--git-dir", remote.path, "rev-parse",
                                                 "refs/heads/feature"], in: directory.path)
        XCTAssertEqual(remoteOID.stdout.trimmingCharacters(in: .whitespacesAndNewlines), localCommit)
    }

    func testLocalZipArchiveContainsSelectedBranchNotHead() async throws {
        try Data("old bytes\n".utf8).write(to: directory.appendingPathComponent("old.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "base archive"])
        let selectedOID = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "archive-base"])
        try Data("new bytes\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "new head"])
        try await refresh()
        let archive = directory.deletingLastPathComponent()
            .appendingPathComponent("bailey-archive-" + UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        await model.createArchive(reference: "refs/heads/archive-base", objectOID: selectedOID,
                                  destination: archive, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertTrue(try Data(contentsOf: archive).starts(with: Data("PK".utf8)))
        let listed = try unzip(["-Z", "-1", archive.path])
        XCTAssertTrue(listed.contains("old.txt"))
        XCTAssertFalse(listed.contains("new.txt"))
        XCTAssertEqual(try unzip(["-p", archive.path, "old.txt"]), "old bytes\n")
    }

    func testRemoteArchiveIsBoundedAndCleanupFailuresKeepDestinationIntact() async throws {
        try Data("selected revision\n".utf8).write(to: directory.appendingPathComponent("selected.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "revision"])
        let selectedOID = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "selected-archive"])
        try Data("not selected".utf8).write(to: directory.appendingPathComponent("new.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "later"])
        let backend = ArchiveFixtureBackend()
        let archive = directory.deletingLastPathComponent()
            .appendingPathComponent("bailey-remote-archive-" + UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        model.sync(root: directory.path, backend: backend, scope: "ssh:archive-fixture")
        try await settle()
        XCTAssertTrue(model.isRepo)

        await model.createArchive(reference: "refs/heads/selected-archive", objectOID: selectedOID,
                                  destination: archive, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertEqual(try unzip(["-p", archive.path, "selected.txt"]), "selected revision\n")
        XCTAssertFalse(try unzip(["-Z", "-1", archive.path]).contains("new.txt"))

        await backend.simulateOversizeRead(true)
        let bytesBefore = try Data(contentsOf: archive)
        await model.createArchive(reference: "refs/heads/selected-archive", objectOID: selectedOID,
                                  destination: archive, target: model.actionTarget())
        try await settle()
        XCTAssertTrue(model.lastError?.contains("64 MiB") == true)
        XCTAssertEqual(try Data(contentsOf: archive), bytesBefore,
                       "An oversized SSH read must not alter an existing archive")
        await backend.simulateOversizeRead(false)
        await backend.simulateCleanupFailure(true)
        await model.createArchive(reference: "refs/heads/selected-archive", objectOID: selectedOID,
                                  destination: archive, target: model.actionTarget())
        try await settle()
        XCTAssertTrue(model.lastError?.contains(String(localized:
            "Remote temporary archive could not be removed:", table: "Git")) == true)
        XCTAssertTrue(model.lastError?.contains("/tmp/bailey-archive-") == true)
        XCTAssertEqual(try unzip(["-p", archive.path, "selected.txt"]), "selected revision\n")
        let folders = await backend.temporaryFolders
        let attempted = await backend.cleanupAttempts
        XCTAssertEqual(attempted, folders, "Every archive temp must be cleaned or explicitly reported")
        await backend.cleanUpTestOwnedFolders()
        for path in folders { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
    }

    private func unzip(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }
}
