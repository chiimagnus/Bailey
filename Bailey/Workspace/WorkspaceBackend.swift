import CryptoKit
import Foundation

/// Immutable version of the raw bytes accepted by a document load/save.
/// Not a filesystem identity and not an atomic compare-and-rename primitive.
nonisolated struct WorkspaceFileVersion: Sendable, Equatable {
    let byteCount: Int
    let sha256: String

    init(data: Data) {
        byteCount = data.count
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ bytes: Data) -> Bool {
        byteCount == bytes.count && sha256 == WorkspaceFileVersion(data: bytes).sha256
    }

    enum PublicationStatus: Sendable {
        case published, unchanged
    }

    /// An uncertain write is resolved only by complete bytes of either known
    /// revision. A third revision remains a conflict; it is never a new base.
    @concurrent func publicationStatus(at path: String, previous: WorkspaceFileVersion,
                                       backend: WorkspaceBackend) async throws -> PublicationStatus {
        let bytes: Data
        do {
            bytes = try await backend.read(path: path, maxBytes: max(byteCount, previous.byteCount))
        } catch WorkspaceError.notFound {
            throw WorkspaceError.changedExternally
        } catch WorkspaceError.tooLarge {
            throw WorkspaceError.changedExternally
        }
        try Task.checkCancellation()
        let actual = WorkspaceFileVersion(data: bytes)
        if actual == self { return .published }
        if actual == previous { return .unchanged }
        throw WorkspaceError.changedExternally
    }
}

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
    /// An independent writer replaced the accepted source bytes before publish.
    case changedExternally

    /// A transport failure does not tell us whether publication occurred.
    /// Definite version conflicts and local write errors are not ambiguous.
    static func publicationUncertain(_ error: Error) -> Bool {
        switch error {
        case WorkspaceError.timedOut, RemoteConnectionError.notConnected:
            return true
        case let failure as RemoteCommandFailure:
            return failure.status == 255 || failure.status == -2
        case RemoteConnectionError.commandFailed(let status, _):
            return status == 255 || status == -2
        default:
            return false
        }
    }
}

/// A completed exchange whose displaced entry could not be verified or removed.
nonisolated struct DisplacedSaveError: LocalizedError, Equatable, Sendable {
    let recoveryPath: String

    var errorDescription: String? {
        String(localized: "The file changed during save or its previous version could not be verified. The destination may contain your draft. The displaced entry is preserved at: \(recoveryPath)", table: "Workspace")
    }
}

/// Keep recovery locations independent of transient retry failures. Clearing the
/// document's save failure also clears its notice, never the recovered files.
nonisolated struct WorkspaceSaveFailure {
    private var latest: String?
    private var recoveries: [DisplacedSaveError] = []

    var message: String? {
        get {
            let messages = [latest].compactMap { $0 } + recoveries.map(\.localizedDescription)
            return messages.isEmpty ? nil : messages.joined(separator: "\n")
        }
        set {
            latest = newValue
            if newValue == nil { recoveries.removeAll() }
        }
    }

    mutating func record(_ error: Error, message: String) {
        if let recovery = error as? DisplacedSaveError {
            if !recoveries.contains(recovery) { recoveries.append(recovery) }
            latest = nil
        } else {
            latest = message
        }
    }
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
    /// Read only the leading bytes of a regular file, without accepting it as a complete document.
    func readPrefix(path: String, maxBytes: Int) async throws -> Data
    func write(path: String, data: Data) async throws
    /// Document save: compare the accepted raw bytes before atomically publishing.
    /// No default fallback to unconditional write is permitted.
    func write(path: String, data: Data, ifUnchanged version: WorkspaceFileVersion) async throws
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
    /// Opt-in bounded output for Git objects and patches. Ordinary workspace
    /// commands keep their full output; a limit violation must fail, not truncate.
    func runLimited(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?, stdoutLimit: Int, stderrLimit: Int
    ) async throws -> WorkspaceRunResult
}

extension WorkspaceBackend {
    func readPrefix(path: String, maxBytes: Int) async throws -> Data {
        // In-memory fixtures can implement their existing bounded command path.
        let result = try await runLimited(argv: ["/usr/bin/head", "-c", String(maxBytes), "--", path],
                                          cwd: nil, env: nil, stdin: nil, timeout: 25,
                                          stdoutLimit: maxBytes, stderrLimit: 16_384)
        guard result.status == 0 else { throw CocoaError(.fileReadUnknown) }
        return result.stdout
    }

    func runLimited(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?, stdoutLimit: Int, stderrLimit: Int
    ) async throws -> WorkspaceRunResult {
        // In-memory fixtures can use the ordinary run path. Production local
        // and SSH backends override this requirement at the actual pipe reader.
        let result = try await run(argv: argv, cwd: cwd, env: env, stdin: stdin, timeout: timeout)
        guard result.stdout.count <= stdoutLimit, result.stderr.count <= stderrLimit else {
            throw WorkspaceError.tooLarge
        }
        return result
    }

    func list(directories: [String]) async -> [String: [WorkspaceEntry]] {
        var listed: [String: [WorkspaceEntry]] = [:]
        for directory in directories {
            listed[directory] = try? await list(directory: directory)
        }
        return listed
    }
}
