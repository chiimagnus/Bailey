import Foundation
import Observation
import XCTest
@testable import kero

/// Git commands operate only in a temporary test repository. Remote metadata
/// is independently controllable so a failed SSH stat can never trash a Mac file.
private actor DiscardRemoteWorkspaceFixture: WorkspaceBackend {
    private var online = true
    private var failGit = false
    private var pauseMetadata = false
    private(set) var metadataReads = 0
    private(set) var deleteAttempts = 0

    func setOnline(_ value: Bool) { online = value }
    func setGitUnavailable(_ value: Bool) { failGit = value }
    func setPauseMetadata(_ value: Bool) { pauseMetadata = value }

    func stat(path: String) async throws -> WorkspaceStat? {
        metadataReads += 1
        if pauseMetadata { try await Task.sleep(for: .milliseconds(300)) }
        guard online else { throw WorkspaceError.timedOut }
        return try await LocalWorkspaceBackend.shared.stat(path: path)
    }

    func readSymlinkDestination(path: String) async throws -> String? {
        guard online else { throw WorkspaceError.timedOut }
        return try await LocalWorkspaceBackend.shared.readSymlinkDestination(path: path)
    }

    func run(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) async throws -> WorkspaceRunResult {
        if failGit { throw WorkspaceError.timedOut }
        // The remote protocol passes command names (git/sh), whereas the
        // local backend deliberately requires an absolute executable URL.
        var variables = ProcessInfo.processInfo.environment
        for (key, value) in env ?? [:] { variables[key] = value }
        return try await LocalWorkspaceBackend.shared.run(
            argv: ["/usr/bin/env"] + argv, cwd: cwd, env: variables,
            stdin: stdin, timeout: timeout
        )
    }

    func delete(paths: [String]) async throws {
        deleteAttempts += 1
        throw WorkspaceError.timedOut
    }

    func gitRoot(containing path: String) async throws -> String? {
        try await LocalWorkspaceBackend.shared.gitRoot(containing: path)
    }
    func isLinkedWorktree(_ root: String) async throws -> Bool { false }
    func list(directory: String) async throws -> [WorkspaceEntry] { [] }
    func read(path: String, maxBytes: Int) async throws -> Data { throw WorkspaceError.notFound }
    func write(path: String, data: Data) async throws { throw WorkspaceError.notFound }
    func createFile(path: String) async throws { throw WorkspaceError.notFound }
    func createDirectory(path: String) async throws { throw WorkspaceError.notFound }
    func rename(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot {
        .init(descendants: [], namesByPid: [:])
    }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { [] }
    func kill(pid: pid_t, force: Bool) async throws { throw WorkspaceError.notFound }
}

@MainActor
final class GitStatusModelTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Git model did not settle")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testStageUnstageDiscardCommitAndScopedDrafts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.path
        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: root, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ text: String) throws {
            try Data(text.utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        }
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.name", "Kero Test"])
        _ = try git(["config", "user.email", "test@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        try write("original\n")
        _ = try git(["add", "."])
        _ = try git(["commit", "-m", "initial"])

        let model = GitStatusModel()
        model.sync(root: root)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)

        let draftChanged = expectation(description: "Commit draft is observed")
        withObservationTracking({ _ = model.commitMessage }) { draftChanged.fulfill() }
        model.commitMessage = "local draft"
        await fulfillment(of: [draftChanged], timeout: 1)

        let collapseChanged = expectation(description: "Scoped Git folder state is observed")
        withObservationTracking({ _ = model.collapsedFolders }) { collapseChanged.fulfill() }
        model.toggleCollapsedFolder("docs")
        await fulfillment(of: [collapseChanged], timeout: 1)
        XCTAssertTrue(model.collapsedFolders.contains("docs"))
        model.sync(root: root, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.commitMessage.isEmpty)
        model.commitMessage = "remote draft"
        model.sync(root: root)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.commitMessage, "local draft")

        try write("changed\n")
        let statusChanged = expectation(description: "Git changes list is observed")
        withObservationTracking({ _ = model.changedEntries }) { statusChanged.fulfill() }
        model.refresh()
        try await wait { !model.isRefreshing }
        await fulfillment(of: [statusChanged], timeout: 1)
        let changed = try XCTUnwrap(model.changedEntries.first)
        model.stage(changed)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "tracked.txt")

        let staged = try XCTUnwrap(model.stagedEntries.first)
        model.unstage(staged)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertTrue(try git(["diff", "--cached", "--name-only"]).isEmpty)

        model.discard(try XCTUnwrap(model.changedEntries.first))
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("tracked.txt"), encoding: .utf8), "original\n")

        try write("committed\n")
        model.refresh()
        try await wait { !model.isRefreshing }
        model.commitMessage = "submitted"
        model.commit(message: model.commitMessage, includeAll: true)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "submitted")
        XCTAssertTrue(model.commitMessage.isEmpty)
    }

    func testDiscardReviewGuardsContentSymlinkAndRepositoryScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func git(_ args: [String]) throws {
            let result = GitCommandExecution.run(args, in: directory.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Discard Review Test"])
        try git(["config", "user.email", "test@invalid"])
        try git(["config", "commit.gpgsign", "false"])
        let tracked = directory.appendingPathComponent("tracked.txt")
        try Data("original\n".utf8).write(to: tracked)
        try git(["add", "."])
        try git(["commit", "-qm", "baseline"])

        let untracked = directory.appendingPathComponent("untracked.txt")
        let firstTarget = directory.appendingPathComponent("first.txt")
        let secondTarget = directory.appendingPathComponent("second.txt")
        let link = directory.appendingPathComponent("alias.txt")
        try Data("new".utf8).write(to: untracked)
        try Data("first".utf8).write(to: firstTarget)
        try Data("second".utf8).write(to: secondTarget)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: firstTarget
        )
        try Data("modified\n".utf8).write(to: tracked)

        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let trackedEntry = try XCTUnwrap(model.changedEntries.first { $0.path == "tracked.txt" })
        let untrackedEntry = try XCTUnwrap(model.changedEntries.first { $0.path == "untracked.txt" })
        let linkEntry = try XCTUnwrap(model.changedEntries.first { $0.path == "alias.txt" })

        // A new edit or a symlink retargeted while the confirmation is open
        // must not delete anything from the reviewed set.
        let originalReviews = model.prepareLocalDiscard([trackedEntry, untrackedEntry, linkEntry])
        XCTAssertEqual(originalReviews.count, 3)
        try Data("modified again (longer)\n".utf8).write(to: tracked)
        XCTAssertFalse(model.confirmLocalDiscard(originalReviews))
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "modified again (longer)\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: untracked.path))

        let linkReview = try XCTUnwrap(model.prepareLocalDiscard([linkEntry]).first)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: secondTarget
        )
        XCTAssertFalse(model.confirmLocalDiscard([linkReview]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       secondTarget.path)

        // Dismissing a valid confirmation never invokes a Git or delete action.
        let cancelled = model.prepareLocalDiscard([untrackedEntry])
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertEqual(try String(contentsOf: untracked, encoding: .utf8), "new")

        let oldScope = try XCTUnwrap(model.prepareLocalDiscard([trackedEntry]).first)
        model.sync(root: directory.path, scope: "ssh:unrelated-host")
        XCTAssertFalse(model.confirmLocalDiscard([oldScope]))
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "modified again (longer)\n")

        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let current = try XCTUnwrap(model.changedEntries.first { $0.path == "tracked.txt" })
        let reviewed = model.prepareLocalDiscard([current])
        XCTAssertTrue(model.confirmLocalDiscard(reviewed))
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "original\n")
        XCTAssertEqual(try String(contentsOf: untracked, encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       secondTarget.path)

        XCTAssertTrue(model.canOpen(untrackedEntry, isRemote: false))
        try FileManager.default.removeItem(at: untracked)
        XCTAssertFalse(model.canOpen(untrackedEntry, isRemote: false))
        XCTAssertTrue(model.canOpen(untrackedEntry, isRemote: true))
    }

    func testRemoteDiscardReviewRejectsDisconnectionAndInFlightScopeChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func git(_ args: [String]) throws {
            let result = GitCommandExecution.run(args, in: directory.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Remote Review Test"])
        try git(["config", "user.email", "test@invalid"])
        try git(["config", "commit.gpgsign", "false"])
        let tracked = directory.appendingPathComponent("tracked.txt")
        try Data("baseline".utf8).write(to: tracked)
        try git(["add", "."])
        try git(["commit", "-qm", "baseline"])
        let candidate = directory.appendingPathComponent("remote-only.txt")
        try Data("preserved remote fixture".utf8).write(to: candidate)

        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo, model.statusError ?? "Remote fixture must resolve Git")
        let entry = try XCTUnwrap(model.changedEntries.first { $0.path == "remote-only.txt" })

        let reviewed = try await model.prepareRemoteDiscard([entry])
        XCTAssertEqual(reviewed.count, 1)
        await backend.setOnline(false)
        let disconnected = await model.confirmRemoteDiscard(reviewed)
        XCTAssertFalse(disconnected)
        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8),
                       "preserved remote fixture")
        let attemptsAfterDisconnect = await backend.deleteAttempts
        XCTAssertEqual(attemptsAfterDisconnect, 0)

        await backend.setOnline(true)
        let oldReview = try await model.prepareRemoteDiscard([entry])
        try Data("changed after review".utf8).write(to: candidate)
        let contentChanged = await model.confirmRemoteDiscard(oldReview)
        XCTAssertFalse(contentChanged)
        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8),
                       "changed after review")
        let attemptsAfterChange = await backend.deleteAttempts
        XCTAssertEqual(attemptsAfterChange, 0)

        await backend.setPauseMetadata(true)
        let previousReads = await backend.metadataReads
        let reviewing = Task {
            try await model.prepareRemoteDiscard([entry])
        }
        let deadline = Date().addingTimeInterval(5)
        while await backend.metadataReads == previousReads, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let readsAfterStart = await backend.metadataReads
        XCTAssertGreaterThan(readsAfterStart, previousReads)
        model.sync(root: directory.path, backend: backend, scope: "ssh:another-host")
        do {
            _ = try await reviewing.value
            XCTFail("Metadata gathered in the old SSH context must be rejected")
        } catch GitStatusModel.DiscardReviewError.stale {
            // Expected: context changed before async preflight completed.
        }
        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8),
                       "changed after review")
        let attemptsAfterSwitch = await backend.deleteAttempts
        XCTAssertEqual(attemptsAfterSwitch, 0)
    }

    func testTransientGitFailurePreservesLastRepositorySnapshotAndRecovers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ args: [String]) throws {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Git Recovery Test"])
        try git(["config", "user.email", "test@invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try "baseline\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-qm", "first"])
        try git(["commit", "--allow-empty", "-qm", "second"])
        try "changed\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)

        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
        let priorChanges = model.changedEntries
        XCTAssertEqual(priorChanges.map(\.path), ["tracked.txt"])
        let priorBranch = model.branch

        await backend.setGitUnavailable(true)
        model.refresh()
        try await wait { model.statusError != nil && !model.isRefreshing }
        XCTAssertTrue(model.isRepo, "Temporary SSH/Git errors must not erase the repository")
        XCTAssertEqual(model.branch, priorBranch)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
        XCTAssertEqual(model.changedEntries, priorChanges)

        await backend.setGitUnavailable(false)
        model.refresh()
        try await wait { model.statusError == nil && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
        XCTAssertEqual(model.changedEntries, priorChanges)
    }

    func testUnbornRepositoryAndPagedHistorySurviveRepositorySwitch() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = fixture.appendingPathComponent("first")
        let second = fixture.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        func git(_ args: [String], in repository: URL) throws -> String {
            let result = GitCommandExecution.run(args, in: repository.path, timeout: 15)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for repository in [first, second] {
            _ = try git(["init", "-q"], in: repository)
            _ = try git(["config", "user.name", "Git Model Test"], in: repository)
            _ = try git(["config", "user.email", "test@invalid"], in: repository)
            _ = try git(["config", "commit.gpgsign", "false"], in: repository)
        }

        let model = GitStatusModel()
        model.sync(root: first.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertFalse(model.hasHead)
        XCTAssertNil(model.headOID)
        XCTAssertTrue(model.recentCommits.isEmpty)

        try Data("first commit\n".utf8).write(to: first.appendingPathComponent("initial.txt"))
        model.refresh()
        try await wait { !model.isRefreshing }
        let untracked = try XCTUnwrap(model.changedEntries.first { $0.path == "initial.txt" })
        model.stage(untracked)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: first), "initial.txt")

        let staged = try XCTUnwrap(model.stagedEntries.first { $0.path == "initial.txt" })
        model.unstage(staged)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertTrue(try git(["diff", "--cached", "--name-only"], in: first).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("initial.txt").path))

        model.stage(try XCTUnwrap(model.changedEntries.first { $0.path == "initial.txt" }))
        try await wait { !model.isBusy && !model.isRefreshing }
        model.commit(message: "first", includeAll: false)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try git(["log", "-1", "--format=%s"], in: first), "first")
        XCTAssertTrue(model.hasHead)

        for index in 1...31 {
            _ = try git(["commit", "--allow-empty", "-qm", "revision-\(index)"], in: first)
        }
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"], in: first), "32")
        model.refresh()
        try await wait { !model.isRefreshing && model.recentCommits.count == 30 }
        XCTAssertTrue(model.hasMoreRecentCommits)
        XCTAssertEqual(model.recentCommits.first?.subject, "revision-31")
        XCTAssertTrue(model.loadMoreCommits())
        try await wait { !model.isRefreshing && !model.isLoadingMoreCommits && model.recentCommits.count == 32 }
        XCTAssertFalse(model.hasMoreRecentCommits)
        XCTAssertEqual(model.recentCommits.last?.subject, "first")

        model.sync(root: second.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertFalse(model.hasHead)
        XCTAssertTrue(model.recentCommits.isEmpty)

        model.sync(root: first.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.hasHead)
        XCTAssertEqual(model.recentCommits.count, 32)
        XCTAssertFalse(model.hasMoreRecentCommits)
        XCTAssertEqual(model.recentCommits.first?.subject, "revision-31")
    }
}
