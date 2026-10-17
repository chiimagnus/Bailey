import Foundation

/// Indexes local project files for Command Palette without coupling disk or
/// Git calls to SwiftUI's view lifecycle.
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
