import Foundation

/// Indexes local and SSH project files for Command Palette without binding
/// file enumeration or Git commands to SwiftUI's view lifecycle.
nonisolated enum ProjectFileIndex {
    struct File: Sendable {
        let name: String
        let relativePath: String
        let absolutePath: String

        var parentPath: String? {
            let parent = (relativePath as NSString).deletingLastPathComponent
            return parent.isEmpty ? nil : parent
        }
    }

    struct RemoteResult: Sendable {
        let files: [File]
        let limited: Bool
    }

    enum RemoteIndexError: LocalizedError {
        case unavailable(String)
        case restrictedRoot
        case tooLarge
        case malformedGitOutput

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .restrictedRoot:
                return String(localized: "The remote home directory or filesystem root cannot be indexed.", table: "Interface")
            case .tooLarge:
                return String(localized: "The remote file index exceeds its size limit.", table: "Interface")
            case .malformedGitOutput:
                return String(localized: "The remote Git command returned an incomplete file listing.", table: "Interface")
            }
        }
    }

    private static let maxRemoteFiles = 10_000
    private static let maxRemoteDirectories = 400
    private static let maxGitBytes = 4 * 1_024 * 1_024

    /// Remote roots never touch the Mac filesystem or its Git client.
    static func loadRemote(in root: String, backend: WorkspaceBackend) async throws -> RemoteResult {
        guard !Task.isCancelled else { throw CancellationError() }
        guard root.hasPrefix("/"), root != "/" else { throw RemoteIndexError.restrictedRoot }
        // Compare remote physical directories, not user-entered spellings:
        // HOME/, HOME/. and symlink aliases must not trigger account-wide scans.
        let directories = try await backend.run(
            argv: ["/bin/sh", "-c",
                   "printf '%s\\0%s\\0' \"$(pwd -P)\" \"$(cd \"$HOME\" && pwd -P)\""],
            cwd: root, env: nil, stdin: nil, timeout: 10
        )
        let physical = directories.stdout.split(separator: 0)
        guard directories.status == 0, directories.stdout.last == 0,
              physical.count == 2,
              let physicalRoot = String(data: Data(physical[0]), encoding: .utf8),
              let physicalHome = String(data: Data(physical[1]), encoding: .utf8),
              physicalRoot.hasPrefix("/"), physicalHome.hasPrefix("/") else {
            throw RemoteIndexError.unavailable(String(localized: "Cannot determine the remote home directory.", table: "Interface"))
        }
        guard !Task.isCancelled else { throw CancellationError() }
        guard physicalRoot.contains(where: { $0 != "/" }),
              physicalRoot != physicalHome else {
            throw RemoteIndexError.restrictedRoot
        }

        let probe = try await remoteGit(["rev-parse", "--is-inside-work-tree"],
                                        in: root, backend: backend)
        if probe.status != 0 {
            guard probe.status == 128, probe.stderr.contains("not a git repository") else {
                throw RemoteIndexError.unavailable(probe.stderr)
            }
            return try await enumerateRemote(in: root, backend: backend)
        }

        var tracked = try await remoteGit(
            ["ls-files", "--cached", "--recurse-submodules", "-z"], in: root, backend: backend
        )
        if tracked.status != 0 {
            tracked = try await remoteGit(["ls-files", "--cached", "-z"], in: root, backend: backend)
        }
        let others = try await remoteGit(
            ["ls-files", "--others", "--exclude-standard", "-z"], in: root, backend: backend
        )
        let deleted = try await remoteGit(
            ["ls-files", "--deleted", "-z"], in: root, backend: backend
        )
        for result in [tracked, others, deleted] where result.status != 0 {
            throw RemoteIndexError.unavailable(result.stderr)
        }
        let paths = try Set(nulPaths(tracked.stdout) + nulPaths(others.stdout))
            .subtracting(nulPaths(deleted.stdout))
        guard paths.count <= maxRemoteFiles else { throw RemoteIndexError.tooLarge }
        let files = paths.compactMap { relative -> File? in
            guard !Task.isCancelled, isSafeRelativePath(relative) else { return nil }
            return File(name: (relative as NSString).lastPathComponent,
                        relativePath: relative,
                        absolutePath: (root as NSString).appendingPathComponent(relative))
        }.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        guard !Task.isCancelled else { throw CancellationError() }
        return RemoteResult(files: files, limited: false)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.isEmpty && !path.split(separator: "/",
            omittingEmptySubsequences: false).contains {
                $0.isEmpty || $0 == "." || $0 == ".."
            }
    }

    private static func nulPaths(_ data: Data) throws -> [String] {
        guard data.isEmpty || data.last == 0 else { throw RemoteIndexError.malformedGitOutput }
        return try data.split(separator: 0).map { part in
            guard let path = String(data: Data(part), encoding: .utf8) else {
                throw RemoteIndexError.malformedGitOutput
            }
            return path
        }
    }

    private static func remoteGit(
        _ args: [String], in root: String, backend: WorkspaceBackend
    ) async throws -> (status: Int32, stdout: Data, stderr: String) {
        try await boundedRemoteCommand(
            "git " + args.map(RemoteCommands.quote).joined(separator: " "),
            in: root, backend: backend
        )
    }

    /// The cap runs on the remote machine; a local post-read truncation would
    /// already have transferred and retained the entire oversized output.
    /// The unique footer preserves the real exit status despite the head pipe.
    private static func boundedRemoteCommand(
        _ command: String, in root: String, backend: WorkspaceBackend
    ) async throws -> (status: Int32, stdout: Data, stderr: String) {
        guard !Task.isCancelled else { throw CancellationError() }
        let marker = "bailey-index-" + UUID().uuidString
        let script = "{ \(command); status=$?; printf '\\n\(marker)%s\\n' \"$status\"; }"
            + " | head -c \(maxGitBytes + 128)"
        let result = try await backend.run(
            argv: ["/bin/sh", "-c", script], cwd: root,
            env: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"],
            stdin: nil, timeout: 25
        )
        guard !Task.isCancelled else { throw CancellationError() }
        guard result.status == 0 else {
            throw RemoteIndexError.unavailable(String(decoding: result.stderr, as: UTF8.self))
        }
        let footer = Data(("\n" + marker).utf8)
        guard let range = result.stdout.range(of: footer, options: .backwards) else {
            throw RemoteIndexError.tooLarge
        }
        let statusBytes = result.stdout[range.upperBound...]
        guard statusBytes.last == 10,
              let status = Int32(String(decoding: statusBytes.dropLast(), as: UTF8.self)),
              range.lowerBound <= maxGitBytes else {
            throw RemoteIndexError.tooLarge
        }
        return (status, Data(result.stdout[..<range.lowerBound]),
                String(decoding: result.stderr, as: UTF8.self))
    }

    /// The live SSH directory batch uses the same bounded remote execution as
    /// Git. LocalWorkspaceBackend remains the host fixture's native listing.
    private static func boundedRemoteDirectories(
        _ directories: [String], in root: String, backend: WorkspaceBackend
    ) async throws -> [String: [WorkspaceEntry]] {
        let tag = UUID().uuidString
        let commands = directories.enumerated().map { index, directory in
            let quoted = RemoteCommands.quote(directory)
            return (
                name: String(index),
                command: "[ -d \(quoted) ] && "
                    + RemoteCommands.listDirectoryCommand(path: directory) + " 2>/dev/null"
            )
        }
        let batch = try await boundedRemoteCommand(
            RemoteCommands.batchCommand(commands, tag: tag), in: root, backend: backend
        )
        guard batch.status == 0 else { throw RemoteIndexError.unavailable(batch.stderr) }
        let parsed = RemoteCommands.parseBatch(batch.stdout, tag: tag)
        var result: [String: [WorkspaceEntry]] = [:]
        for (index, directory) in directories.enumerated() {
            guard let entry = parsed[String(index)], entry.status == 0 else { continue }
            result[directory] = RemoteCommands.parseDirectoryListing(entry.stdout)
        }
        return result
    }

    private static func enumerateRemote(
        in root: String, backend: WorkspaceBackend
    ) async throws -> RemoteResult {
        var queue = [root]
        var files: [File] = []
        var scanned = 0
        var limited = false
        while !queue.isEmpty {
            guard !Task.isCancelled else { throw CancellationError() }
            if scanned >= maxRemoteDirectories { limited = true; break }
            let count = min(24, maxRemoteDirectories - scanned, queue.count)
            let directories = Array(queue.prefix(count))
            queue.removeFirst(count)
            scanned += count
            // Only actual SSH transport needs a pre-transfer cap. The local
            // backend is also used here by host tests for real filesystem IO.
            let listed = if backend is SSHWorkspaceBackend {
                try await boundedRemoteDirectories(directories, in: root, backend: backend)
            } else {
                await backend.list(directories: directories)
            }
            for directory in directories {
                guard let entries = listed[directory] else {
                    throw RemoteIndexError.unavailable(String(localized: "Could not list remote directory: \(directory)", table: "Interface"))
                }
                for entry in entries where entry.name != ".git" {
                    guard !Task.isCancelled else { throw CancellationError() }
                    guard isSafeRelativePath(entry.name) else { continue }
                    let absolute = (directory as NSString).appendingPathComponent(entry.name)
                    if entry.isDirectory {
                        if !entry.isSymlink { queue.append(absolute) }
                    } else if !entry.isSymlink {
                        let relative = String(absolute.dropFirst(root.count + (root.hasSuffix("/") ? 0 : 1)))
                        files.append(File(name: entry.name, relativePath: relative,
                                          absolutePath: absolute))
                        if files.count >= maxRemoteFiles {
                            limited = true
                            break
                        }
                    }
                }
                if limited { break }
            }
            if limited { break }
        }
        if !queue.isEmpty { limited = true }
        return RemoteResult(
            files: files.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            },
            limited: limited
        )
    }

    static func gitDirectory(in root: String) -> String? {
        let result = GitCommandExecution.run(["rev-parse", "--absolute-git-dir"], in: root)
        guard result.status == 0 else { return nil }
        let path = result.stdout.hasSuffix("\n") ? String(result.stdout.dropLast()) : result.stdout
        return path.hasPrefix("/") ? path : nil
    }

    static func load(in root: String) -> [File] {
        if let paths = gitProjectFilePaths(in: root) {
            return projectFiles(for: paths, in: root)
        }
        return enumeratedProjectFiles(in: root)
    }

    /// Include tracked and non-ignored untracked files, even when one
    /// submodule is temporarily unavailable.
    private static func gitProjectFilePaths(in root: String) -> Set<String>? {
        var tracked = GitCommandExecution.run(
            ["ls-files", "--cached", "--recurse-submodules", "-z"], in: root
        )
        if tracked.status != 0 {
            tracked = GitCommandExecution.run(["ls-files", "--cached", "-z"], in: root)
        }
        let untracked = GitCommandExecution.run(
            ["ls-files", "--others", "--exclude-standard", "-z"], in: root
        )
        guard tracked.status == 0, untracked.status == 0 else { return nil }
        return Set(nulSeparatedPaths(tracked.stdout) + nulSeparatedPaths(untracked.stdout))
    }

    private static func nulSeparatedPaths(_ output: String) -> [String] {
        output.split(separator: "\0").map(String.init)
    }

    private static func projectFiles(for paths: Set<String>, in root: String) -> [File] {
        let manager = FileManager.default
        return paths.compactMap { relative in
            guard !Task.isCancelled else { return nil }
            let path = (root as NSString).appendingPathComponent(relative)
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &directory),
                  !directory.boolValue else { return nil }
            return File(
                name: (relative as NSString).lastPathComponent,
                relativePath: relative, absolutePath: path
            )
        }.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    /// Enumerating relative paths avoids the /var versus /private/var alias
    /// mismatch that would otherwise silently discard every plain-directory file.
    private static func enumeratedProjectFiles(in root: String) -> [File] {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var files: [File] = []
        while let relative = enumerator.nextObject() as? String {
            if Task.isCancelled { break }
            let name = (relative as NSString).lastPathComponent
            if name == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let absolute = (root as NSString).appendingPathComponent(relative)
            guard let values = try? URL(fileURLWithPath: absolute)
                .resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            files.append(File(name: name, relativePath: relative, absolutePath: absolute))
        }
        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }
}
