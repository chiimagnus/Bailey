//
//  WorkspaceBackend.swift
//  kero
//

import Darwin
import Foundation

/// One directory entry, as the file tree needs it.
nonisolated struct WorkspaceEntry: Sendable, Equatable {
    let name: String
    /// Directory after following symlinks, matching `FileManager.fileExists`.
    let isDirectory: Bool
    let isSymlink: Bool
}

/// Metadata about one path, following symlinks for everything but `isSymlink`.
nonisolated struct WorkspaceStat: Sendable, Equatable {
    let isRegular: Bool
    let isDirectory: Bool
    /// True when the path *itself* is a symlink, whatever it resolves to.
    let isSymlink: Bool
    let size: Int
    let mtime: Date
}

/// One process under the session's shell.
nonisolated struct WorkspaceProcess: Sendable, Equatable {
    let pid: pid_t
    /// Executable name, e.g. "node".
    let name: String
    /// Full executable path.
    let executable: String
    let cpu: Double
    let memoryKB: Int
}

/// Descendants of one process, plus the names of every process on the machine.
/// The names come along because a listening socket can belong to the shell
/// itself, which is not one of its own descendants.
nonisolated struct WorkspaceProcessSnapshot: Sendable {
    /// Breadth-first, so commands the user ran come before their workers.
    let descendants: [WorkspaceProcess]
    let namesByPid: [pid_t: String]
}

/// One TCP port a process is listening on.
nonisolated struct WorkspacePort: Sendable, Equatable {
    let port: Int
    let pid: pid_t
}

nonisolated struct WorkspaceRunResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// Failures a consumer has to tell apart to keep its own wording. Anything
/// else propagates as the original system error, so messages built from
/// `localizedDescription` read exactly as they do without a backend.
nonisolated enum WorkspaceError: Error {
    case notFound
    case tooLarge
    case timedOut
}

/// The workspace a project's panels, editor and diff viewer operate on: the
/// Mac's own disk and process table, or a machine reached over SSH.
///
/// Every method is `async throws` because the remote implementation costs a
/// round trip per call and must never run on the main actor — the shape has to
/// be async even where the local implementation answers immediately.
nonisolated protocol WorkspaceBackend: Sendable {
    // MARK: Files
    func list(directory: String) async throws -> [WorkspaceEntry]
    func stat(path: String) async throws -> WorkspaceStat?
    /// The target of a symlink, or nil when `path` is not one.
    func readSymlinkDestination(path: String) async throws -> String?
    /// At most `maxBytes`; throws `WorkspaceError.tooLarge` beyond that and
    /// `.notFound` when the path is gone.
    func read(path: String, maxBytes: Int) async throws -> Data
    func write(path: String, data: Data) async throws
    func createFile(path: String) async throws
    func createDirectory(path: String) async throws
    func rename(from: String, to: String) async throws
    /// Locally this moves to the Trash.
    func delete(paths: [String]) async throws

    // MARK: Git geography
    /// Directory of the nearest enclosing git repository, walking up.
    func gitRoot(containing path: String) async throws -> String?
    /// Whether `root` is a linked worktree rather than a normal checkout.
    func isLinkedWorktree(_ root: String) async throws -> Bool

    // MARK: Processes
    func run(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) async throws -> WorkspaceRunResult
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort]
    func kill(pid: pid_t, force: Bool) async throws
}
