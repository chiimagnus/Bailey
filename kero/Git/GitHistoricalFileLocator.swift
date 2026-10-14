import Foundation

/// Resolve Git Graph's "Open File" and "Diff with Working File" semantics:
/// keep the historical path when it still exists; only then look for a rename
/// between the selected revision and today's worktree. Never use Mac files
/// when the selected backend belongs to an SSH workspace.
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
        let current = (root as NSString).appendingPathComponent(path)
        do {
            if let stat = try await backend.stat(path: current),
               stat.isRegular || stat.isSymlink { return .found(path) }
        } catch WorkspaceError.notFound {
            // The old path is absent; the selected revision may have been renamed.
        } catch {
            return .failed(error.localizedDescription)
        }

        // Git may no longer recognize the rename against edited worktree
        // bytes (similarity drops below its threshold). Check the committed
        // revision-to-HEAD rename only if the direct comparison found none.
        // NUL separators preserve arbitrary whitespace in Git pathnames.
        for endpoint in [String?.none, "HEAD"] {
            var args = ["diff", "--name-status", "-z", "--find-renames",
                        "--diff-filter=R", revision]
            if let endpoint { args.append(endpoint) }
            args.append("--")
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
                guard old == path else { continue }
                do {
                    if let stat = try await backend.stat(
                        path: (root as NSString).appendingPathComponent(new)),
                       stat.isRegular || stat.isSymlink { return .found(new) }
                } catch WorkspaceError.notFound {
                    continue
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
        }
        return .missing
    }
}
