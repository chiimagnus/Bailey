import Foundation
@testable import Bailey

/// Git commands operate only in a temporary test repository. Remote metadata
/// is independently controllable so a failed SSH stat can never trash a Mac file.
actor DiscardRemoteWorkspaceFixture: WorkspaceBackend {
    private var online = true
    private var failGit = false
    private var failHistoryLog = false
    private var failStashList = false
    private var failIgnoredStatus = false
    private var failRefSnapshot = false
    private var failRemoteList = false
    private var failGitDirectory = false
    private var failOperationMarker = false
    private var failWorktreeList = false
    private var pauseNextGit = false
    private var pauseHistory = false
    private var pauseRefs = false
    private var pauseHistoryMain = false
    private var emptyNextBatch = false
    private(set) var requestTimeouts: [TimeInterval?] = []
    private(set) var commands: [String] = []
    private var pausedGit: CheckedContinuation<Void, Never>?
    private var pausedHistory: CheckedContinuation<Void, Never>?
    private(set) var historyWaiting = false
    private(set) var awaitingGit = false
    private(set) var gitRuns = 0
    private var pauseMetadata = false
    private(set) var metadataReads = 0
    private(set) var deleteAttempts = 0

    func setOnline(_ value: Bool) { online = value }
    func setGitUnavailable(_ value: Bool) { failGit = value }
    func setHistoryLogUnavailable(_ value: Bool) { failHistoryLog = value }
    func setStashListUnavailable(_ value: Bool) { failStashList = value }
    func setIgnoredStatusUnavailable(_ value: Bool) { failIgnoredStatus = value }
    func setRefSnapshotUnavailable(_ value: Bool) { failRefSnapshot = value }
    func setRemoteListUnavailable(_ value: Bool) { failRemoteList = value }
    func setGitDirectoryUnavailable(_ value: Bool) { failGitDirectory = value }
    func setOperationMarkerUnavailable(_ value: Bool) { failOperationMarker = value }
    func setWorktreeListUnavailable(_ value: Bool) { failWorktreeList = value }
    func suspendNextGitRequest() { pauseNextGit = true }
    func suspendHistoryRequest() { pauseHistory = true }
    func suspendRefSnapshotRequest() { pauseRefs = true }
    func omitNextBatch() { emptyNextBatch = true }
    func suspendHistory() { pauseHistoryMain = true }
    func releaseHistory() {
        pausedHistory?.resume()
        pausedHistory = nil
        historyWaiting = false
    }
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
        let script = stdin.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let historyRequest = script.contains("git 'log' ")
        let refsRequest = script.contains(" LC_ALL=C git 'for-each-ref' ")
        if pauseNextGit || (pauseHistory && historyRequest) || (pauseRefs && refsRequest) {
            pauseNextGit = false
            pauseHistory = false
            pauseRefs = false
            awaitingGit = true
            await withCheckedContinuation { pausedGit = $0 }
        }
        if pauseHistoryMain, let stdin,
           String(decoding: stdin, as: UTF8.self).contains(" LC_ALL=C git 'log' ") {
            pauseHistoryMain = false
            historyWaiting = true
            await withCheckedContinuation { pausedHistory = $0 }
        }
        if failGit || (failWorktreeList && argv == ["git", "worktree", "list", "--porcelain", "-z"]) {
            throw WorkspaceError.timedOut
        }
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
        if (failHistoryLog || failStashList || failIgnoredStatus || failRefSnapshot || failRemoteList || failGitDirectory),
           let stdin, let script = String(data: stdin, encoding: .utf8) {
            var failing = script
            if failHistoryLog {
                failing = failing.replacingOccurrences(of: " LC_ALL=C git 'log' ", with: " LC_ALL=C git 'invalid-test-history-log' ")
            }
            if failStashList {
                failing = failing.replacingOccurrences(of: " LC_ALL=C git 'stash' 'list' ", with: " LC_ALL=C git 'invalid-test-stash' 'list' ")
            }
            if failIgnoredStatus {
                failing = failing.replacingOccurrences(of: " '--ignored=matching'", with: " '--invalid-ignored-option'")
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
    func copy(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func rename(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot {
        .init(descendants: [], namesByPid: [:])
    }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { [] }
    func kill(pid: pid_t, force: Bool) async throws { throw WorkspaceError.notFound }
}
