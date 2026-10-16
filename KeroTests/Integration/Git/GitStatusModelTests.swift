import Foundation
import Observation
import XCTest
@testable import kero

/// Git commands operate only in a temporary test repository. Remote metadata
/// is independently controllable so a failed SSH stat can never trash a Mac file.
private actor DiscardRemoteWorkspaceFixture: WorkspaceBackend {
    private var online = true
    private var failGit = false
    private var failHistoryLog = false
    private var failStashList = false
    private var failRefSnapshot = false
    private var failRemoteList = false
    private var failGitDirectory = false
    private var failOperationMarker = false
    private var pauseNextGit = false
    private var pauseHistory = false
    private var emptyNextBatch = false
    private(set) var requestTimeouts: [TimeInterval?] = []
    private(set) var commands: [String] = []
    private var pausedGit: CheckedContinuation<Void, Never>?
    private(set) var awaitingGit = false
    private(set) var gitRuns = 0
    private var pauseMetadata = false
    private(set) var metadataReads = 0
    private(set) var deleteAttempts = 0

    func setOnline(_ value: Bool) { online = value }
    func setGitUnavailable(_ value: Bool) { failGit = value }
    func setHistoryLogUnavailable(_ value: Bool) { failHistoryLog = value }
    func setStashListUnavailable(_ value: Bool) { failStashList = value }
    func setRefSnapshotUnavailable(_ value: Bool) { failRefSnapshot = value }
    func setRemoteListUnavailable(_ value: Bool) { failRemoteList = value }
    func setGitDirectoryUnavailable(_ value: Bool) { failGitDirectory = value }
    func setOperationMarkerUnavailable(_ value: Bool) { failOperationMarker = value }
    func suspendNextGitRequest() { pauseNextGit = true }
    func suspendHistoryRequest() { pauseHistory = true }
    func omitNextBatch() { emptyNextBatch = true }
    func releaseGitRequest() {
        pausedGit?.resume()
        pausedGit = nil
        awaitingGit = false
    }
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
        gitRuns += 1
        requestTimeouts.append(timeout)
        commands.append(argv.joined(separator: " ") + " " + (stdin.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
        if emptyNextBatch, argv == ["sh", "-s"] {
            emptyNextBatch = false
            return WorkspaceRunResult(status: 0, stdout: Data(), stderr: Data())
        }
        let historyRequest = stdin.flatMap { String(data: $0, encoding: .utf8) }?.contains("git 'log' ") == true
        if pauseNextGit || (pauseHistory && historyRequest) {
            pauseNextGit = false
            pauseHistory = false
            awaitingGit = true
            await withCheckedContinuation { pausedGit = $0 }
        }
        if failGit { throw WorkspaceError.timedOut }
        if failOperationMarker, argv.count == 3,
           argv[0] == "sh", argv[1] == "-c",
           argv[2].contains("for n in rebase-merge rebase-apply MERGE_HEAD") {
            throw WorkspaceError.timedOut
        }
        // The remote protocol passes command names (git/sh), whereas the
        // local backend deliberately requires an absolute executable URL.
        var variables = ProcessInfo.processInfo.environment
        for (key, value) in env ?? [:] { variables[key] = value }
        let commandInput: Data?
        if (failHistoryLog || failStashList || failRefSnapshot || failRemoteList || failGitDirectory),
           let stdin, let script = String(data: stdin, encoding: .utf8) {
            var failing = script
            if failHistoryLog {
                failing = failing.replacingOccurrences(of: " LC_ALL=C git 'log' ", with: " LC_ALL=C git 'invalid-test-history-log' ")
            }
            if failStashList {
                failing = failing.replacingOccurrences(of: " LC_ALL=C git 'stash' 'list' ", with: " LC_ALL=C git 'invalid-test-stash' 'list' ")
            }
            if failRefSnapshot {
                failing = failing.replacingOccurrences(of: " LC_ALL=C git 'for-each-ref' ", with: " LC_ALL=C git 'invalid-test-refs' ")
            }
            if failRemoteList {
                failing = failing.replacingOccurrences(of: " LC_ALL=C git 'remote' ", with: " LC_ALL=C git 'invalid-test-remotes' ")
            }
            if failGitDirectory {
                failing = failing.replacingOccurrences(of: " LC_ALL=C git 'rev-parse' '--absolute-git-dir' ",
                                                        with: " LC_ALL=C git 'invalid-test-git-dir' ")
            }
            commandInput = Data(failing.utf8)
        } else {
            commandInput = stdin
        }
        let localArguments = argv.map { $0.replacingOccurrences(of: "stat -c %s --", with: "stat -f %z --") }
        return try await LocalWorkspaceBackend.shared.run(
            argv: ["/usr/bin/env"] + localArguments, cwd: cwd, env: variables,
            stdin: commandInput, timeout: timeout
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

        XCTAssertFalse(model.canOpen(untrackedEntry, isRemote: false),
                       "An old file row cannot be reused after switching repository scope")
        let currentUntracked = try XCTUnwrap(model.changedEntries.first {
            $0.path == "untracked.txt"
        })
        XCTAssertTrue(model.canOpen(currentUntracked, isRemote: false))
        try FileManager.default.removeItem(at: untracked)
        XCTAssertFalse(model.canOpen(currentUntracked, isRemote: false))
        XCTAssertTrue(model.canOpen(currentUntracked, isRemote: true))
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

    func testIndexMutationAndPaginationAvoidUnrelatedGitQueries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Refresh Test"],
                     ["config", "user.email", "refresh@invalid"], ["config", "commit.gpgsign", "false"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        for number in 0..<34 {
            XCTAssertEqual(GitCommandExecution.run(["commit", "--allow-empty", "-qm", "change \(number)"],
                in: directory.path).status, 0)
        }
        try Data("one\ntwo\n".utf8).write(to: directory.appendingPathComponent("fresh.txt"))
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:scoped-refresh")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.hasCurrentDetails)
        XCTAssertEqual(model.recentCommits.count, 30)
        XCTAssertTrue(model.hasMoreRecentCommits)
        let initialHead = model.headOID
        let initialHistory = model.recentCommits

        let beforeStage = await backend.commands.count
        model.stageAll()
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(model.headOID, initialHead)
        XCTAssertEqual(model.recentCommits, initialHistory)
        XCTAssertTrue(model.hasCurrentDetails)
        XCTAssertTrue(model.hasCurrentLineTotals)
        XCTAssertEqual(model.lineAdditions, 2)
        XCTAssertEqual(GitCommandExecution.run(["diff", "--cached", "--name-only"], in: directory.path).stdout,
            "fresh.txt\n")
        let stagedCommands = Array((await backend.commands).dropFirst(beforeStage)).joined(separator: "\n")
        XCTAssertFalse(stagedCommands.contains("git 'log' "), stagedCommands)
        XCTAssertFalse(stagedCommands.contains("git 'for-each-ref' "), stagedCommands)
        XCTAssertFalse(stagedCommands.contains("git 'stash' 'list' "), stagedCommands)

        try Data("three\n".utf8).write(to: directory.appendingPathComponent("untracked.txt"))
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertEqual(model.lineAdditions, 3)

        let beforePage = await backend.commands.count
        XCTAssertTrue(model.loadMoreCommits())
        try await wait { !model.isLoadingMoreCommits && !model.isRefreshing }
        XCTAssertEqual(model.recentCommits.count, 34)
        XCTAssertFalse(model.hasMoreRecentCommits)
        let pageCommands = Array((await backend.commands).dropFirst(beforePage)).joined(separator: "\n")
        XCTAssertTrue(pageCommands.contains("git 'log' "), pageCommands)
        XCTAssertFalse(pageCommands.contains("git 'diff' '--numstat' "), pageCommands)
        XCTAssertFalse(pageCommands.contains("count_bytes()"), pageCommands)
        XCTAssertFalse(pageCommands.contains("git 'stash' 'list' "), pageCommands)
        XCTAssertTrue(model.hasCurrentDetails)
        XCTAssertEqual(model.lineAdditions, 3)

        XCTAssertEqual(GitCommandExecution.run(["tag", "outside"], in: directory.path).status, 0)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNotNil(model.refsByName["refs/tags/outside"])
    }

    func testIndexMutationDoesNotDowngradeQueuedFullRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Pending Test"],
                     ["config", "user.email", "pending@invalid"], ["config", "commit.gpgsign", "false"],
                     ["commit", "--allow-empty", "-qm", "initial"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:pending")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertNil(model.refsByName["refs/tags/new-external"])
        XCTAssertEqual(GitCommandExecution.run(["tag", "new-external"], in: directory.path).status, 0)
        try Data("new\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        model.stageAll()
        model.refresh()
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNotNil(model.refsByName["refs/tags/new-external"])
        XCTAssertEqual(model.stagedEntries.map(\.path), ["new.txt"])
        XCTAssertTrue(model.hasCurrentLineTotals)
    }

    func testHistoryPageEscalatesWhenExternalReferenceChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Page Test"],
                     ["config", "user.email", "page@invalid"], ["config", "commit.gpgsign", "false"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        for number in 0..<35 {
            XCTAssertEqual(GitCommandExecution.run(["commit", "--allow-empty", "-qm", "page \(number)"],
                in: directory.path).status, 0)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:page")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        await backend.suspendHistoryRequest()
        XCTAssertTrue(model.loadMoreCommits())
        let deadline = Date().addingTimeInterval(10)
        while !(await backend.awaitingGit), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let suspended = await backend.awaitingGit
        XCTAssertTrue(suspended)
        XCTAssertEqual(GitCommandExecution.run(["tag", "external-in-flight"], in: directory.path).status, 0)
        await backend.releaseGitRequest()
        try await wait { !model.isRefreshing && !model.isLoadingMoreCommits }
        XCTAssertEqual(model.recentCommits.count, 35)
        XCTAssertNotNil(model.refsByName["refs/tags/external-in-flight"])
        XCTAssertTrue(model.hasCurrentDetails)
    }

    func testHistoryPageDoesNotLoseFullRefreshForConcurrentFileChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Page Change Test"],
                     ["config", "user.email", "page-change@invalid"], ["config", "commit.gpgsign", "false"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        for number in 0..<32 {
            XCTAssertEqual(GitCommandExecution.run(["commit", "--allow-empty", "-qm", "page \(number)"],
                in: directory.path).status, 0)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:page-files")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.lineAdditions, 0)
        await backend.suspendHistoryRequest()
        XCTAssertTrue(model.loadMoreCommits())
        let deadline = Date().addingTimeInterval(10)
        while !(await backend.awaitingGit), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let suspended = await backend.awaitingGit
        XCTAssertTrue(suspended)
        try Data("fresh\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        // A change occurring after the page's core scan requires the normal
        // full-refresh event; the history query cannot infer an unseen write.
        model.refresh()
        await backend.releaseGitRequest()
        try await wait { !model.isRefreshing && !model.isLoadingMoreCommits }
        XCTAssertEqual(model.recentCommits.count, 32)
        XCTAssertEqual(model.changedEntries.map(\.path), ["new.txt"])
        XCTAssertEqual(model.lineAdditions, 1)
        XCTAssertTrue(model.hasCurrentLineTotals)
    }

    func testCoreStatusIsUsableWhileHistoryIsSuspended() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Core Test"],
                          ["config", "user.email", "core@invalid"], ["config", "commit.gpgsign", "false"],
                          ["commit", "--allow-empty", "-qm", "initial"]] {
            let result = GitCommandExecution.run(arguments, in: directory.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try Data("new text\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        let backend = DiscardRemoteWorkspaceFixture()
        await backend.suspendHistoryRequest()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:core-test")
        let deadline = Date().addingTimeInterval(10)
        while !(await backend.awaitingGit), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let suspended = await backend.awaitingGit
        XCTAssertTrue(suspended)
        XCTAssertTrue(model.hasResolvedStatus)
        XCTAssertTrue(model.isRepo)
        XCTAssertEqual(model.branch, "main")
        XCTAssertTrue(model.hasHead)
        XCTAssertNotNil(model.headOID)
        XCTAssertEqual(model.changedEntries.map(\.path), ["new.txt"])
        XCTAssertNil(model.repositoryOperation)
        XCTAssertFalse(model.hasCurrentDetails)
        XCTAssertFalse(model.hasCurrentLineTotals)
        let timeouts = await backend.requestTimeouts
        XCTAssertTrue(timeouts.allSatisfy { $0 != nil && $0! > 0 && $0! <= 24 })
        let runsBeforeAction = await backend.gitRuns
        model.fetch()
        XCTAssertFalse(model.isBusy)
        XCTAssertNotNil(model.lastError)
        let runsAfterAction = await backend.gitRuns
        XCTAssertEqual(runsBeforeAction, runsAfterAction)
        model.commit(message: "amended without history", includeAll: true, amend: true)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["amended without history"])
        XCTAssertTrue(model.hasCurrentDetails)
        let amended = model.headOID
        await backend.releaseGitRequest()
        try await wait { !model.isRefreshing }
        XCTAssertEqual(model.headOID, amended)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["amended without history"])
        XCTAssertEqual(GitCommandExecution.run(["show", "HEAD:new.txt"], in: directory.path).stdout, "new text\n")
    }

    func testMissingRemoteCoreBatchIsFailureWithoutIndividualRetry() async throws {
        let backend = DiscardRemoteWorkspaceFixture()
        await backend.omitNextBatch()
        let model = GitStatusModel()
        model.sync(root: "/tmp", backend: backend, scope: "ssh:missing-frame")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertNotNil(model.statusError)
        XCTAssertFalse(model.isRepo)
        let runs = await backend.gitRuns
        XCTAssertEqual(runs, 1)
    }

    func testCappedLineTotalsAreUnknownUntilACompleteReadSucceeds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(GitCommandExecution.run(["init", "-q"], in: directory.path).status, 0)
        let file = directory.appendingPathComponent("untracked")
        try Data(repeating: 65, count: 8 * 1_024 * 1_024 + 1).write(to: file)
        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertTrue(model.hasCurrentDetails)
        XCTAssertFalse(model.hasCurrentLineTotals)
        XCTAssertNil(model.statusError)
        XCTAssertEqual(model.changedEntries.map(\.path), ["untracked"])
        try Data("one\ntwo".utf8).write(to: file)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertTrue(model.hasCurrentLineTotals)
        XCTAssertEqual(model.lineAdditions, 2)
        XCTAssertEqual(model.lineDeletions, 0)
    }

    func testDetailsQualificationFollowsCoreIdentityRatherThanRefreshActivity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Qualification Test"],
                          ["config", "user.email", "qualification@invalid"], ["config", "commit.gpgsign", "false"],
                          ["commit", "--allow-empty", "-qm", "initial"]] {
            XCTAssertEqual(GitCommandExecution.run(arguments, in: directory.path).status, 0)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:qualification")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let oldHead = try XCTUnwrap(model.headOID)
        for changesHead in [false, true] {
            if changesHead {
                XCTAssertEqual(GitCommandExecution.run(["commit", "--allow-empty", "-qm", "changed"],
                    in: directory.path).status, 0)
            }
            await backend.suspendHistoryRequest()
            model.refresh()
            XCTAssertTrue(model.hasCurrentDetails, "Merely starting a query must not cancel a valid retry")
            let deadline = Date().addingTimeInterval(10)
            while !(await backend.awaitingGit), Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let suspended = await backend.awaitingGit
            XCTAssertTrue(suspended)
            XCTAssertEqual(model.hasCurrentDetails, !changesHead)
            if changesHead { XCTAssertNotEqual(model.headOID, oldHead) }
            await backend.releaseGitRequest()
            try await wait { !model.isRefreshing }
            XCTAssertTrue(model.hasCurrentDetails)
        }
        await backend.setHistoryLogUnavailable(true)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNotNil(model.statusError)
        XCTAssertFalse(model.hasCurrentDetails)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["changed", "initial"])
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
        try git(["branch", "topic/safe"])
        try git(["tag", "v1"])
        try git(["remote", "add", "origin", directory.path])
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
        let priorRefs = model.refsByName
        let priorRemotes = model.remotes
        XCTAssertNotNil(priorRefs["refs/heads/topic/safe"])
        XCTAssertNotNil(priorRefs["refs/tags/v1"])
        XCTAssertEqual(priorRemotes, ["origin"])

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

        // The main status command can succeed while the history subcommand
        // fails. That must not silently publish an empty Git Graph.
        await backend.setHistoryLogUnavailable(true)
        model.refresh()
        try await wait { model.statusError != nil && !model.isRefreshing }
        XCTAssertFalse(model.hasCurrentDetails)
        model.fetch()
        XCTAssertFalse(model.isBusy, "Old remotes must not drive a new action after details fail")
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
        XCTAssertEqual(model.changedEntries, priorChanges)
        await backend.setHistoryLogUnavailable(false)
        model.refresh()
        try await wait { model.statusError == nil && !model.isRefreshing }
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])

        // An individual metadata query failing must not publish a partial
        // successful snapshot that hides Branch/Tag menus or an in-progress operation.
        for kind in 0..<3 {
            switch kind {
            case 0: await backend.setRefSnapshotUnavailable(true)
            case 1: await backend.setRemoteListUnavailable(true)
            default: await backend.setGitDirectoryUnavailable(true)
            }
            model.refresh()
            try await wait { !model.isRefreshing }
            XCTAssertNotNil(model.statusError, "Metadata query \(kind) must fail the complete snapshot")
            XCTAssertEqual(model.refsByName, priorRefs)
            XCTAssertEqual(model.remotes, priorRemotes)
            XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
            switch kind {
            case 0: await backend.setRefSnapshotUnavailable(false)
            case 1: await backend.setRemoteListUnavailable(false)
            default: await backend.setGitDirectoryUnavailable(false)
            }
            model.refresh()
            try await wait { !model.isRefreshing }
            XCTAssertNil(model.statusError)
        }

        try git(["stash", "push", "-qm", "preserve on query failure"])
        model.refresh()
        try await wait { !model.isRefreshing }
        let priorStashes = model.stashes
        XCTAssertEqual(priorStashes.count, 1)
        await backend.setStashListUnavailable(true)
        model.refresh()
        try await wait { model.statusError != nil && !model.isRefreshing }
        XCTAssertEqual(model.stashes, priorStashes)
        XCTAssertEqual(model.stashes.count, 1)
        await backend.setStashListUnavailable(false)
        try git(["stash", "clear"])
        model.refresh()
        try await wait { model.statusError == nil && !model.isRefreshing }
        XCTAssertTrue(model.stashes.isEmpty)

        // A failed remote marker check must not turn an in-progress merge
        // into a clean repository that enables other commit actions.
        let marker = directory.appendingPathComponent(".git/MERGE_HEAD")
        try (try XCTUnwrap(model.headOID) + "\n").write(to: marker, atomically: true, encoding: .utf8)
        model.refresh()
        try await wait { !model.isRefreshing }
        let priorOperation = try XCTUnwrap(model.repositoryOperation)
        await backend.setOperationMarkerUnavailable(true)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNotNil(model.statusError, "Failed SSH marker check must not be treated as no operation")
        XCTAssertEqual(model.repositoryOperation, priorOperation)
        await backend.setOperationMarkerUnavailable(false)
        try FileManager.default.removeItem(at: marker)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNil(model.statusError)
        XCTAssertNil(model.repositoryOperation)
    }

    func testStashFileLoadRejectsStaleSSHChannelAndRetriesAfterFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-stash-ssh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.name", "Stash Channel Test"],
            ["config", "user.email", "stash-ssh@invalid"],
            ["config", "commit.gpgsign", "false"]
        ] {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        let file = directory.appendingPathComponent("tracked.txt")
        try "baseline\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitCommandExecution.run(["add", "."], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "base"], in: directory.path).status, 0)
        try "stash change\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitCommandExecution.run(
            ["stash", "push", "-qm", "saved"], in: directory.path
        ).status, 0)

        let oldChannel = DiscardRemoteWorkspaceFixture()
        let newChannel = DiscardRemoteWorkspaceFixture()
        defer { Task { await oldChannel.releaseGitRequest() } }
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: oldChannel, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing && model.isRepo }
        let selected = try XCTUnwrap(model.stashes.first)
        await oldChannel.suspendNextGitRequest()
        model.loadStashFiles(for: selected)
        let deadline = Date().addingTimeInterval(5)
        while await !oldChannel.awaitingGit, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let paused = await oldChannel.awaitingGit
        XCTAssertTrue(paused)
        XCTAssertEqual(model.stashFilesByOID[selected.oid], .loading)

        model.sync(root: directory.path, backend: newChannel, scope: "ssh:fixture")
        XCTAssertNil(model.stashFilesByOID[selected.oid],
                     "Replacing a channel must release the old loading indicator")
        try await wait { model.hasResolvedStatus && !model.isRefreshing && model.isRepo }
        let current = try XCTUnwrap(model.stashes.first)
        await newChannel.setGitUnavailable(true)
        model.loadStashFiles(for: current)
        try await wait {
            if case .failed = model.stashFilesByOID[current.oid] { return true }
            return false
        }
        await newChannel.setGitUnavailable(false)
        model.loadStashFiles(for: current)
        try await wait {
            if case .loaded = model.stashFilesByOID[current.oid] { return true }
            return false
        }
        await oldChannel.setGitUnavailable(true)
        await oldChannel.releaseGitRequest()
        if case .loaded(let changes) = model.stashFilesByOID[current.oid] {
            XCTAssertEqual(changes.map(\.path), ["tracked.txt"])
        } else {
            XCTFail("A completed new SSH read must not be overwritten by the old channel")
        }
    }

    func testReplacingSSHBackendDoesNotWaitForStaleGitWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ args: [String]) throws {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Git Channel Test"])
        try git(["config", "user.email", "test@invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try "hello".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-qm", "baseline"])

        let oldChannel = DiscardRemoteWorkspaceFixture()
        let newChannel = DiscardRemoteWorkspaceFixture()
        await oldChannel.suspendNextGitRequest()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: oldChannel, scope: "ssh:fixture")
        let oldDeadline = Date().addingTimeInterval(5)
        while await !oldChannel.awaitingGit, Date() < oldDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let oldStarted = await oldChannel.awaitingGit
        XCTAssertTrue(oldStarted)
        // The same host and repository, but a different SSH connection.
        model.sync(root: directory.path, backend: newChannel, scope: "ssh:fixture")
        let deadline = Date().addingTimeInterval(1.5)
        while await newChannel.gitRuns == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let launched = await newChannel.gitRuns
        await oldChannel.setGitUnavailable(true)
        await oldChannel.releaseGitRequest()
        XCTAssertGreaterThan(launched, 0, "A new SSH channel must not wait for an old Git worker")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertNil(model.statusError)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["baseline"])
    }

    func testContextChangeDuringMutationPreflightDoesNotSwitchOldRepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"],
                     ["config", "user.name", "Preflight Test"],
                     ["config", "user.email", "preflight@invalid"],
                     ["config", "commit.gpgsign", "false"],
                     ["commit", "--allow-empty", "-qm", "root"],
                     ["branch", "other"]] {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:first")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        await backend.suspendNextGitRequest()
        model.switchBranch(to: "other")
        let deadline = Date().addingTimeInterval(5)
        while await !backend.awaitingGit, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let paused = await backend.awaitingGit
        XCTAssertTrue(paused)
        model.sync(root: directory.path, backend: backend, scope: "ssh:second")
        await backend.releaseGitRequest()
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(GitCommandExecution.run(["branch", "--show-current"], in: directory.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines), "main")
    }

    func testNewEditDuringCommitPreflightStopsBeforeFirstMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Late Edit"],
                     ["config", "user.email", "edit@invalid"], ["config", "commit.gpgsign", "false"],
                     ["commit", "--allow-empty", "-qm", "first"], ["commit", "--allow-empty", "-qm", "second"]] {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let target = try XCTUnwrap(model.recentCommits.last)
        let head = model.headOID
        let filePath = directory.appendingPathComponent("editing.txt")
        try Data("baseline".utf8).write(to: filePath)
        let file = FileTab(path: filePath.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        await backend.suspendNextGitRequest()
        model.actOnCommit(target, action: .checkout, target: model.actionTarget(),
                          prepare: { true }, isCurrentTarget: { !file.isDirty })
        let deadline = Date().addingTimeInterval(5)
        while await !backend.awaitingGit, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        file.text = "new edit during preflight"
        file.refreshDirtyState()
        await backend.releaseGitRequest()
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(file.text, "new edit during preflight")
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(try String(contentsOf: filePath, encoding: .utf8), "baseline")
        XCTAssertEqual(GitCommandExecution.run(["rev-parse", "HEAD"], in: directory.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines), head)
    }

    func testRecentCommitsKeepMergeParentsAndTypedReferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func git(_ arguments: [String]) throws -> String {
            let result = GitCommandExecution.run(arguments, in: directory.path, timeout: 15)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Graph Test"])
        _ = try git(["config", "user.email", "graph@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        try "root".write(to: directory.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "root"])
        let root = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-qc", "feature/nested"])
        try "side".write(to: directory.appendingPathComponent("side.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "side"])
        let side = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-q", "main"])
        try "main".write(to: directory.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "main"])
        let firstParent = try git(["rev-parse", "HEAD"])
        _ = try git(["merge", "-q", "--no-ff", "-m", "merge", "feature/nested"])
        let merge = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "release/stable", merge])
        _ = try git(["branch", "feature,hotfix", merge])
        _ = try git(["tag", "v1.0", merge])
        _ = try git(["tag", "v1,hotfix", merge])
        _ = try git(["update-ref", "refs/remotes/origin/main", merge])
        _ = try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        // A second tip that HEAD cannot reach must still appear in the graph.
        _ = try git(["switch", "-qc", "experiment/other", root])
        _ = try git(["commit", "--allow-empty", "-qm", "independent tip"])
        let extra = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-q", "main"])

        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let rows = model.recentCommits
        let top = try XCTUnwrap(rows.first { $0.hash == merge })
        XCTAssertEqual(top.parentHashes, [firstParent, side])
        XCTAssertEqual(top.files.map(\.path), ["side.txt"], "Merge files must compare with the first parent")
        XCTAssertEqual(rows.first { $0.hash == root }?.parentHashes, [])
        XCTAssertNotNil(rows.first { $0.hash == extra })
        XCTAssertEqual(
            Set(top.references),
            Set([
                .init(kind: .currentBranch, name: "main"),
                .init(kind: .localBranch, name: "release/stable"),
                .init(kind: .localBranch, name: "feature,hotfix"),
                .init(kind: .remoteBranch, name: "origin/main"),
                .init(kind: .tag, name: "v1.0"),
                .init(kind: .tag, name: "v1,hotfix"),
            ])
        )
        XCTAssertEqual(rows.first { $0.hash == side }?.references,
                       [.init(kind: .localBranch, name: "feature/nested")])
        XCTAssertEqual(rows.first { $0.hash == side }?.files.map(\.path), ["side.txt"])
    }

    func testGitGraphUsesCommitDateOrderWithoutBreakingMergeParents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-git-order-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: directory.path, timeout: 15)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func datedGit(_ args: [String], date: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + args
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_AUTHOR_DATE"] = date
            environment["GIT_COMMITTER_DATE"] = date
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Graph Date Order"])
        _ = try git(["config", "user.email", "graph@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        try datedGit(["commit", "--allow-empty", "-qm", "root"], date: "2026-10-05T00:00:00+0000")
        let root = try git(["rev-parse", "HEAD"])
        for (subject, date) in [
            ("main1", "2026-10-07T11:26:00+0000"),
            ("main2", "2026-10-07T12:02:00+0000"),
            ("main3", "2026-10-07T12:15:00+0000"),
        ] {
            try datedGit(["commit", "--allow-empty", "-qm", subject], date: date)
        }
        _ = try git(["switch", "-qc", "side", root])
        for (subject, date) in [
            ("side1", "2026-10-07T19:08:00+0000"),
            ("side2", "2026-10-07T19:24:00+0000"),
        ] {
            try datedGit(["commit", "--allow-empty", "-qm", subject], date: date)
        }
        try datedGit(["merge", "-q", "--no-ff", "-m", "merged", "main"],
                     date: "2026-10-08T14:20:00+0000")

        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.recentCommits.map(\.subject),
                       ["merged", "side2", "side1", "main3", "main2", "main1", "root"],
                       "Git Graph must interleave branches by commit date, not group them topologically")
        let indexByHash = Dictionary(uniqueKeysWithValues: model.recentCommits.enumerated()
            .map { ($0.element.hash, $0.offset) })
        for (index, commit) in model.recentCommits.enumerated() {
            for parent in commit.parentHashes {
                XCTAssertGreaterThan(indexByHash[parent] ?? -1, index,
                                     "Git Graph must still place every child above its parent")
            }
        }
    }

    func testHistoricalBranchMustPointAtSelectedCommitWithoutSwitchingHEAD() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: directory.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "History Test"])
        _ = try git(["config", "user.email", "history@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["commit", "--allow-empty", "-qm", "first"])
        let selected = try git(["rev-parse", "HEAD"])
        _ = try git(["commit", "--allow-empty", "-qm", "second"])
        let head = try git(["rev-parse", "HEAD"])

        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let target = try XCTUnwrap(model.recentCommits.first { $0.hash == selected })
        let expectedRepository = model.repoRoot
        model.createBranch(named: "history/first", at: selected,
            checkout: false, replacing: nil, target: model.actionTarget())
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/history/first"]), selected)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try git(["branch", "--show-current"]), "main")
        XCTAssertTrue(model.recentCommits.first { $0.hash == selected }?.references.contains {
            $0.kind == .localBranch && $0.name == "history/first"
        } == true)

        model.createTag(named: "v1-local", at: selected, type: .lightweight,
                        message: "", replacing: nil, target: model.actionTarget())
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/tags/v1-local"]), selected)
        XCTAssertTrue(model.recentCommits.first { $0.hash == selected }?.references.contains {
            $0.kind == .tag && $0.name == "v1-local"
        } == true)

        model.createBranch(named: "history/first", at: selected,
            checkout: false, replacing: nil, target: model.actionTarget())
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNotNil(model.lastError, "Duplicate branch must fail without force")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/history/first"]), selected)

        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        func otherGit(_ args: [String]) -> Int32 {
            GitCommandExecution.run(args, in: other.path, timeout: 10).status
        }
        XCTAssertEqual(otherGit(["init", "-q", "-b", "other"]), 0)
        let before = model.operation
        model.sync(root: other.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        model.createTag(named: "should-not-exist", at: selected, type: .lightweight,
                        message: "", replacing: nil, target: model.actionTarget())
        XCTAssertNotNil(model.lastError)
        XCTAssertNotEqual(model.operation, before)
        XCTAssertNotEqual(otherGit(["show-ref", "--verify", "--quiet",
                                    "refs/tags/should-not-exist"]), 0)
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
