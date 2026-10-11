// Git changed-file hierarchy built from porcelain paths, without filesystem IO.

import Foundation

enum GitChangeTree {
    enum Content {
        case folder(path: String, name: String, collapsed: Bool)
        case file(GitStatusModel.Entry)
    }

    struct Row: Identifiable {
        let id: String
        let depth: Int
        let content: Content
    }

    enum PathContent {
        case folder(path: String, name: String, collapsed: Bool)
        case file(path: String)
    }

    struct PathRow {
        let depth: Int
        let content: PathContent
    }

    private struct Folder {
        var children: [String: Folder] = [:]
        var files: [String] = []

        mutating func insert(_ path: String, components: ArraySlice<String>) {
            guard let first = components.first else { return }
            if components.count == 1 {
                files.append(path)
            } else {
                children[first, default: Folder()]
                    .insert(path, components: components.dropFirst())
            }
        }
    }

    /// Shared hierarchy for working-tree changes and committed paths.
    /// The section key keeps each commit's collapsed folders independent.
    static func pathRows(
        _ paths: [String], section: String, collapsed: Set<String>
    ) -> [PathRow] {
        var root = Folder()
        for path in paths {
            root.insert(path, components: ArraySlice(path.split(separator: "/").map(String.init)))
        }

        var result: [PathRow] = []
        func append(_ folder: Folder, path: String, depth: Int) {
            for (name, child) in folder.children.sorted(by: { $0.key < $1.key }) {
                let childPath = path.isEmpty ? name : path + "/" + name
                let key = section + ":" + childPath
                let isCollapsed = collapsed.contains(key)
                result.append(PathRow(
                    depth: depth,
                    content: .folder(path: childPath, name: name, collapsed: isCollapsed)
                ))
                if !isCollapsed { append(child, path: childPath, depth: depth + 1) }
            }
            for file in folder.files.sorted(by: {
                ($0 as NSString).lastPathComponent < ($1 as NSString).lastPathComponent
            }) {
                result.append(PathRow(depth: depth, content: .file(path: file)))
            }
        }
        append(root, path: "", depth: 0)
        return result
    }

    /// `section` isolates collapsed folders for merge, staged and unstaged rows.
    static func rows(
        _ entries: [GitStatusModel.Entry], section: String, collapsed: Set<String>
    ) -> [Row] {
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return pathRows(entries.map(\.path), section: section, collapsed: collapsed)
            .compactMap { item in
                switch item.content {
                case .folder(let path, let name, let isCollapsed):
                    return Row(
                        id: "folder:" + section + ":" + path, depth: item.depth,
                        content: .folder(path: path, name: name, collapsed: isCollapsed)
                    )
                case .file(let path):
                    guard let entry = byPath[path] else { return nil }
                    return Row(
                        id: "file:" + section + ":" + path, depth: item.depth,
                        content: .file(entry)
                    )
                }
            }
    }
}
