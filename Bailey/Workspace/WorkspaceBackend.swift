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

/// The workspace a project's panels, editor and diff viewer operate on:
/// the Mac's disk or a machine reached over SSH.
///
/// Every method is `async throws` because the remote implementation costs a
/// round trip per call and must never run on the main actor — the shape has to
/// be async even where the local implementation answers immediately.
nonisolated protocol WorkspaceBackend: Sendable {
    // MARK: Files
    func list(directory: String) async throws -> [WorkspaceEntry]
    /// Best-effort refresh: missing keys indicate directories that could not be read.
    func list(directories: [String]) async -> [String: [WorkspaceEntry]]
    func stat(path: String) async throws -> WorkspaceStat?
    /// The target of a symlink, or nil when `path` is not one.
    func readSymlinkDestination(path: String) async throws -> String?
    /// At most `maxBytes`; throws `WorkspaceError.tooLarge` beyond that and
    /// `.notFound` when the path is gone.
    func read(path: String, maxBytes: Int) async throws -> Data
    func write(path: String, data: Data) async throws
    func createFile(path: String) async throws
    func createDirectory(path: String) async throws
    /// Copy one file system entry without replacing an existing destination.
    func copy(from: String, to: String) async throws
    func rename(from: String, to: String) async throws
    /// Locally this moves to the Trash.
    func delete(paths: [String]) async throws

    // MARK: Commands
    func run(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) async throws -> WorkspaceRunResult
}

extension WorkspaceBackend {
    func list(directories: [String]) async -> [String: [WorkspaceEntry]] {
        var listed: [String: [WorkspaceEntry]] = [:]
        for directory in directories {
            listed[directory] = try? await list(directory: directory)
        }
        return listed
    }
}
