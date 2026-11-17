import Foundation

/// Resolve historical "Open File" and "Diff with Working File" paths:
/// prefer an existing original path, otherwise follow Git tree/Index renames
/// and confirm the result through the selected local or SSH backend.
nonisolated enum GitHistoricalFileLocator {
    enum Result: Equatable, Sendable {
        case found(String)
        case missing
        case failed(String)
    }

    private static let renameLimit = 2 << 20

    static func resolve(
        root: String, path: String, revision: String, backend: WorkspaceBackend
    ) async -> Result {
        func onDisk(_ relativePath: String) async -> Result {
            do {
                let file = (root as NSString).appendingPathComponent(relativePath)
                if let stat = try await backend.stat(path: file),
                   stat.isRegular || stat.isSymlink { return .found(relativePath) }
                return .missing
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        // Only compare Git trees and the Index. Consulting the live worktree
        // through Git diff would run LFS clean filters and create media.
        // NUL separators preserve whitespace, Unicode and newlines in paths.
        func renamed(_ source: String, comparing revisions: [String]) async -> Result {
            let args = ["diff", "--name-status", "-z", "--find-renames",
                        "--diff-filter=R"] + revisions + ["--"]
            let history = await GitCommandExecution.runData(
                args, in: root, stdoutLimit: renameLimit + 1, backend: backend
            )
            guard history.status == 0 else {
                return .failed(history.stderr.isEmpty
                    ? String(localized: "Unable to resolve historical file rename", table: "Git")
                    : history.stderr)
            }
            guard history.stdout.count <= renameLimit else {
                return .failed(String(localized: "Historical rename results are too large", table: "Git"))
            }
            let tokens = history.stdout.split(separator: 0, omittingEmptySubsequences: true)
            guard tokens.count.isMultiple(of: 3) else {
                return .failed(String(localized: "Unable to parse Git rename results", table: "Git"))
            }
            for index in stride(from: 0, to: tokens.count, by: 3) {
                guard let change = String(data: Data(tokens[index]), encoding: .utf8),
                      let old = String(data: Data(tokens[index + 1]), encoding: .utf8),
                      let new = String(data: Data(tokens[index + 2]), encoding: .utf8),
                      change.hasPrefix("R") else {
                    return .failed(String(localized: "Unable to parse Git rename results", table: "Git"))
                }
                if old == source { return .found(new) }
            }
            return .missing
        }

        let original = await onDisk(path)
        guard original == .missing else { return original }
        for comparison in [["--cached", revision], [revision, "HEAD"]] {
            switch await renamed(path, comparing: comparison) {
            case .failed(let message):
                return .failed(message)
            case .missing:
                continue
            case .found(let candidate):
                let current = await onDisk(candidate)
                guard current == .missing else { return current }
                // A committed rename can be renamed again in the Index.
                // Cumulative edits can hide the direct revision-to-Index rename
                // even though Git recognizes each individual rename.
                if comparison == [revision, "HEAD"] {
                    switch await renamed(candidate, comparing: ["--cached", "HEAD"]) {
                    case .failed(let message): return .failed(message)
                    case .missing: break
                    case .found(let staged):
                        let latest = await onDisk(staged)
                        guard latest == .missing else { return latest }
                    }
                }
            }
        }
        return .missing
    }
}
