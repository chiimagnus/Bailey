//
//  FileTreeModel.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// Flattened, lazily-expanded view of a directory tree.
@MainActor
final class FileTreeModel: nonisolated ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String { path }
        let name: String
        let path: String
        let isDirectory: Bool
        let depth: Int
        /// Parent directory names folded into this row (VS Code compact folders).
        var compactPrefix: [String] = []
        var displayName: String { (compactPrefix + [name]).joined(separator: " / ") }
        /// True for the transient inline "new file/folder" input row, which
        /// has no backing file yet.
        var isDraft = false
    }

    /// A pending inline "new file/folder": an input row shown inside
    /// `parentDir` until the user names it (Enter) or cancels (Escape/blur).
    struct Draft: Equatable {
        let parentDir: String
        let isDirectory: Bool
    }

    @Published private(set) var rootPath = ""
    @Published private(set) var items: [Item] = []
    /// Path of the row currently being renamed inline, if any.
    @Published private(set) var renamingPath: String?
    /// The pending new-file/folder input row, if any.
    @Published private(set) var draft: Draft?
    @Published private var expanded: Set<String> = []
    private var workspaceScope = "local"
    /// A project can follow different checkouts; each retains its own outline.
    private struct Root: Hashable {
        let scope: String
        let path: String
    }
    private var expandedByRoot: [Root: Set<String>] = [:]

    /// The workspace this tree reads. Replaced on every `sync`, so the tree
    /// follows its session between the local disk and a remote machine.
    private var backend: WorkspaceBackend = LocalWorkspaceBackend.shared
    /// A rebuild is a round trip per visible directory, so only one runs at a
    /// time; anything arriving mid-flight is folded into one further pass.
    private var isRebuilding = false
    private var rebuildPending = false

    var rootName: String {
        (rootPath as NSString).lastPathComponent
    }

    func isExpanded(_ item: Item) -> Bool {
        expanded.contains(item.path)
    }

    /// Switches the visible root without discarding expansion state from the
    /// previously visited directory. Data is still reread on every refresh.
    func sync(root: String, backend: WorkspaceBackend, scope: String = "local") async {
        self.backend = backend
        if root != rootPath || workspaceScope != scope {
            if !rootPath.isEmpty {
                expandedByRoot[Root(scope: workspaceScope, path: rootPath)] = expanded
            }
            expanded = expandedByRoot[Root(scope: scope, path: root)] ?? []
            workspaceScope = scope
            rootPath = root
            items = []
            // Inline editing cannot continue in an inactive workspace.
            renamingPath = nil
            draft = nil
        }
        await rebuild()
    }

    func toggle(_ item: Item) async {
        guard item.isDirectory else { return }
        if !expanded.insert(item.path).inserted {
            expanded.remove(item.path)
        }
        await rebuild()
    }

    /// Moves `item` to the Trash, then rebuilds so it drops out of the tree.
    func moveToTrash(_ item: Item) async {
        let backend = self.backend
        let scope = workspaceScope
        let root = rootPath
        do {
            try await backend.delete(paths: [item.path])
            if scope == workspaceScope, root == rootPath { expanded.remove(item.path) }
        } catch {
            presentError(
                String(
                    localized: "Couldn’t move “\(item.name)” to the Trash.", table: "Workspace",
                    comment: "File operation error. The placeholder is a file or folder name."
                ),
                error.localizedDescription
            )
        }
        if scope == workspaceScope, root == rootPath { await rebuild() }
    }

    /// Deletes `item` outright, then rebuilds so it drops out of the tree.
    /// Used where the workspace has no Trash to move it to — a remote
    /// machine — so the caller confirms with the user first.
    func delete(_ item: Item) async {
        let backend = self.backend
        let scope = workspaceScope
        let root = rootPath
        do {
            try await backend.delete(paths: [item.path])
            if scope == workspaceScope, root == rootPath { expanded.remove(item.path) }
        } catch {
            presentError(
                String(
                    localized: "Couldn’t delete “\(item.name)”.", table: "Workspace",
                    comment: "File operation error. The placeholder is a file or folder name."
                ),
                error.localizedDescription
            )
        }
        if scope == workspaceScope, root == rootPath { await rebuild() }
    }

    // MARK: - Rename

    func beginRename(_ item: Item) {
        renamingPath = item.path
    }

    func cancelRename() {
        renamingPath = nil
    }

    /// Renames `item` in place. No-ops on an empty or unchanged name; shows an
    /// alert if the name collides or the filesystem move fails. Returns the new
    /// absolute path when the file actually moved, so callers can follow it
    /// (e.g. re-point open tabs).
    @discardableResult
    func rename(_ item: Item, to newName: String) async -> String? {
        let backend = self.backend
        let scope = workspaceScope
        let root = rootPath
        renamingPath = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return nil }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError(
                String(localized: "Couldn’t rename to “\(trimmed)”.", table: "Workspace"),
                String(localized: "A name can’t contain “/” or be “.” or “..”.", table: "Workspace")
            )
            return nil
        }
        let dir = (item.path as NSString).deletingLastPathComponent
        let dest = (dir as NSString).appendingPathComponent(trimmed)
        // A case-only rename ("foo"→"Foo") maps to the same file on a
        // case-insensitive volume, so don't treat that as a collision.
        let caseOnlyChange = trimmed.lowercased() == item.name.lowercased()
        let exists = (try? await backend.stat(path: dest)) ?? nil
        guard scope == workspaceScope, root == rootPath else { return nil }
        guard caseOnlyChange || exists == nil else {
            presentError(
                String(localized: "Couldn’t rename to “\(trimmed)”.", table: "Workspace"),
                String(localized: "An item named “\(trimmed)” already exists here.", table: "Workspace")
            )
            return nil
        }
        do {
            try await backend.rename(from: item.path, to: dest)
            if scope == workspaceScope, root == rootPath {
                remapExpanded(from: item.path, to: dest)
            }
        } catch {
            presentError(String(localized: "Couldn’t rename to “\(trimmed)”.", table: "Workspace"), error.localizedDescription)
            return nil
        }
        if scope == workspaceScope, root == rootPath { await rebuild() }
        return dest
    }

    /// Keeps expansion state after a directory rename by rewriting the old
    /// path prefix (for the folder itself and any expanded descendants).
    private func remapExpanded(from oldPath: String, to newPath: String) {
        guard expanded.contains(where: { $0 == oldPath || $0.hasPrefix(oldPath + "/") })
        else { return }
        expanded = Set(expanded.map { path in
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") {
                return newPath + String(path.dropFirst(oldPath.count))
            }
            return path
        })
    }

    // MARK: - Create (inline draft)

    /// Opens an inline input row for a new file inside `directory`.
    func beginNewFile(in directory: String) async {
        await startDraft(in: directory, isDirectory: false)
    }

    /// Opens an inline input row for a new folder inside `directory`.
    func beginNewFolder(in directory: String) async {
        await startDraft(in: directory, isDirectory: true)
    }

    private func startDraft(in directory: String, isDirectory: Bool) async {
        renamingPath = nil
        draft = Draft(parentDir: directory, isDirectory: isDirectory)
        // Reveal the folder's contents so the input row is visible.
        expanded.insert(directory)
        await rebuild()
    }

    func cancelDraft() async {
        guard draft != nil else { return }
        draft = nil
        await rebuild()
    }

    /// Commits the pending draft, creating the file or folder. An empty name
    /// cancels (matching VS Code). Returns the new file's path — for files
    /// only — so the caller can open it.
    @discardableResult
    func commitDraft(name: String) async -> String? {
        guard let draft else { return nil }
        let backend = self.backend
        let scope = workspaceScope
        let root = rootPath
        self.draft = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { await rebuild(); return nil }
        guard !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            presentError(
                String(localized: "Couldn’t create “\(trimmed)”.", table: "Workspace"),
                String(localized: "A name can’t contain “/” or be “.” or “..”.", table: "Workspace")
            )
            await rebuild()
            return nil
        }
        let dest = (draft.parentDir as NSString).appendingPathComponent(trimmed)
        let exists = (try? await backend.stat(path: dest)) ?? nil
        guard scope == workspaceScope, root == rootPath else { return nil }
        guard exists == nil else {
            presentError(
                String(localized: "Couldn’t create “\(trimmed)”.", table: "Workspace"),
                String(localized: "An item named “\(trimmed)” already exists here.", table: "Workspace")
            )
            await rebuild()
            return nil
        }
        var createdFile: String?
        if draft.isDirectory {
            do {
                try await backend.createDirectory(path: dest)
            } catch {
                presentError(String(localized: "Couldn’t create the folder.", table: "Workspace"), error.localizedDescription)
            }
        } else {
            do {
                try await backend.createFile(path: dest)
                createdFile = dest
            } catch WorkspaceError.createFileFailed {
                presentError(
                    String(localized: "Couldn’t create the file.", table: "Workspace"),
                    String(localized: "It could not be written to disk.", table: "Workspace")
                )
            } catch {
                presentError(String(localized: "Couldn’t create the file.", table: "Workspace"), error.localizedDescription)
            }
        }
        if scope == workspaceScope, root == rootPath {
            await rebuild()
            return createdFile
        }
        return nil
    }

    private func presentError(_ messageText: String, _ informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func rebuild() async {
        guard !rootPath.isEmpty else { return }
        // A rebuild requested while one is in flight would read the tree twice
        // over the same channel; run one more pass instead of a second walk.
        if isRebuilding {
            rebuildPending = true
            return
        }
        isRebuilding = true
        repeat {
            rebuildPending = false
            // A root that cannot be read leaves the tree as it was. On a
            // remote workspace that is a connection that has gone away, and
            // emptying the panel would claim the directory is empty.
            let path = rootPath
            let scope = workspaceScope
            let backend = self.backend
            let expanded = self.expanded
            let draft = self.draft
            if let out = await children(
                of: path, depth: 0, backend: backend,
                expanded: expanded, draft: draft
            ),
               path == rootPath, scope == workspaceScope, out != items {
                items = out
            }
        } while rebuildPending
        isRebuilding = false
    }

    /// The rows for one directory, or nil when it could not be read at all —
    /// which the caller treats as "keep what is on screen" rather than "this
    /// directory is empty".
    private func children(
        of dir: String, depth: Int, backend: WorkspaceBackend,
        expanded: Set<String>, draft: Draft?
    ) async -> [Item]? {
        // Guard against runaway recursion through symlink cycles.
        guard depth < 32 else { return [] }
        var out: [Item] = []
        // Show the inline new-file/folder input at the top of its folder.
        if let draft, draft.parentDir == dir {
            out.append(
                Item(
                    name: "", path: dir + "/\u{1}draft",
                    isDirectory: draft.isDirectory, depth: depth, isDraft: true
                )
            )
        }
        guard let entries = try? await backend.list(directory: dir) else { return nil }

        let rows = entries
            .filter { $0.name != ".git" }
            .map { entry in
                Item(
                    name: entry.name,
                    path: (dir as NSString).appendingPathComponent(entry.name),
                    isDirectory: entry.isDirectory,
                    depth: depth
                )
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

        for row in rows {
            let visibleRow = row.isDirectory
                ? await compactDirectory(row, backend: backend, draft: draft)
                : row
            out.append(visibleRow)
            if visibleRow.isDirectory, expanded.contains(visibleRow.path),
               let descendants = await children(
                   of: visibleRow.path, depth: depth + 1,
                   backend: backend, expanded: expanded, draft: draft
               ) {
                out.append(contentsOf: descendants)
            }
        }
        return out
    }

    /// Fold a chain of directories with exactly one directory child into one row.
    /// Stop at a directory that contains a draft so its inline input remains visible.
    private func compactDirectory(
        _ item: Item, backend: WorkspaceBackend, draft: Draft?
    ) async -> Item {
        var leaf = item
        var prefix = item.compactPrefix
        var traversed = 0

        while traversed < 32, draft?.parentDir != leaf.path {
            guard let entries = try? await backend.list(directory: leaf.path) else { break }
            let visible = entries.filter { $0.name != ".git" }
            guard visible.count == 1, let child = visible.first, child.isDirectory else { break }

            prefix.append(leaf.name)
            leaf = Item(
                name: child.name,
                path: (leaf.path as NSString).appendingPathComponent(child.name),
                isDirectory: true,
                depth: item.depth,
                compactPrefix: prefix
            )
            traversed += 1
        }
        return leaf
    }
}
