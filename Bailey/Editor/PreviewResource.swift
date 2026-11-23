import Foundation

nonisolated struct PreviewResource: Sendable {
    let path: String
    let directory: String?
    let backend: any WorkspaceBackend

    private func relativePath(for url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == nil, components.host == nil, components.query == nil,
              !components.path.isEmpty, !components.path.hasPrefix("/") else {
            throw CocoaError(.fileReadNoPermission)
        }
        return (path as NSString).deletingLastPathComponent + "/" + components.path
    }

    private func scopedPath(_ absolutePath: String) throws -> (candidate: String, directory: String) {
        guard let directory, LocalPathScope.contains(path, in: directory),
              absolutePath.hasPrefix("/"), !absolutePath.contains("\\"), !absolutePath.utf8.contains(0) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var segments: [Substring] = []
        for segment in absolutePath.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": _ = segments.popLast()
            default: segments.append(segment)
            }
        }
        let candidate = "/" + segments.joined(separator: "/")
        guard LocalPathScope.contains(candidate, in: directory) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return (candidate, directory)
    }

    func read(_ url: URL, maxBytes: Int) async throws -> Data {
        try await read(path: relativePath(for: url), maxBytes: maxBytes)
    }

    func read(path absolutePath: String, maxBytes: Int) async throws -> Data {
        let (candidate, directory) = try scopedPath(absolutePath)
        if let local = backend as? LocalWorkspaceBackend {
            return try await local.read(path: candidate, maxBytes: maxBytes, confinedTo: directory)
        }
        return try await remoteResource(candidate, directory: directory, maxBytes: maxBytes)
    }

    func resolvedFile(_ url: URL) async throws -> String {
        let (candidate, directory) = try scopedPath(relativePath(for: url))
        if let local = backend as? LocalWorkspaceBackend {
            try await local.checkConfinedFile(candidate, in: directory)
        } else {
            _ = try await remoteResource(candidate, directory: directory, maxBytes: nil)
        }
        return candidate
    }

    private func remoteResource(_ candidate: String, directory: String, maxBytes: Int?) async throws -> Data {
        if let maxBytes, maxBytes < 0 || maxBytes == .max { throw WorkspaceError.tooLarge }
        let count = maxBytes.map { String($0 + 1) } ?? ""
        let result = try await backend.runLimited(
            argv: ["sh", "-c", """
                root=$(realpath -- "$1" && printf '.') || exit 1
                root=${root%?}; root=${root%?}
                candidate=$(realpath -- "$2" && printf '.') || exit 1
                candidate=${candidate%?}; candidate=${candidate%?}
                [ -n "$root" ] && [ -d "$root" ] && [ -f "$candidate" ] || exit 1
                case "$candidate" in "${root%/}/"*) ;; *) exit 1;; esac
                if [ -n "$3" ]; then head -c "$3" -- "$candidate"; fi
                """, "bailey-preview", directory, candidate, count],
            cwd: nil, env: nil, stdin: nil, timeout: 25, stdoutLimit: maxBytes.map { $0 + 1 } ?? 0,
            stderrLimit: 16_384
        )
        guard result.status == 0 else { throw CocoaError(.fileReadNoPermission) }
        if let maxBytes, result.stdout.count > maxBytes { throw WorkspaceError.tooLarge }
        return result.stdout
    }
}
