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

    private struct Folder {
        var children: [String: Folder] = [:]
        var files: [GitStatusModel.Entry] = []

        mutating func insert(_ entry: GitStatusModel.Entry, components: ArraySlice<String>) {
            guard let first = components.first else { return }
            if components.count == 1 {
                files.append(entry)
            } else {
                children[first, default: Folder()]
                    .insert(entry, components: components.dropFirst())
            }
        }
    }

    /// `section` isolates collapsed folders for merge, staged and unstaged rows.
    static func rows(
        _ entries: [GitStatusModel.Entry], section: String, collapsed: Set<String>
    ) -> [Row] {
        var root = Folder()
        for entry in entries {
            root.insert(entry, components: ArraySlice(entry.path.split(separator: "/").map(String.init)))
        }

        var result: [Row] = []
        func append(_ folder: Folder, path: String, depth: Int) {
            for (name, child) in folder.children.sorted(by: { $0.key < $1.key }) {
                let childPath = path.isEmpty ? name : path + "/" + name
                let key = section + ":" + childPath
                let isCollapsed = collapsed.contains(key)
                result.append(Row(
                    id: "folder:" + key, depth: depth,
                    content: .folder(path: childPath, name: name, collapsed: isCollapsed)
                ))
                if !isCollapsed { append(child, path: childPath, depth: depth + 1) }
            }
            for entry in folder.files.sorted(by: { $0.fileName < $1.fileName }) {
                result.append(Row(id: "file:" + section + ":" + entry.path,
                                  depth: depth, content: .file(entry)))
            }
        }
        append(root, path: "", depth: 0)
        return result
    }
}
