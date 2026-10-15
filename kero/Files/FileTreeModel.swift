//
//  FileTreeModel.swift
//  kero
//

import Foundation
import Observation

/// Flattened, lazily-expanded view of a directory tree.
@MainActor
@Observable
final class FileTreeModel {
    typealias Item = TreeDisplayModel.Row

    /// A pending inline "new file/folder": an input row shown inside
    /// `parentDir` until the user names it (Enter) or cancels (Escape/blur).
    struct Draft: Equatable {
        let parentDir: String
        let isDirectory: Bool
    }

    private(set) var rootPath = ""
    private(set) var items: [Item] = []
    /// Path of the row currently being renamed inline, if any.
    private(set) var renamingPath: String?
    /// The pending new-file/folder input row, if any.
    private(set) var draft: Draft?
    private var expanded: Set<String> = []
    @ObservationIgnored private var workspaceScope = "local"
    /// A project can follow different checkouts; each retains its own outline.
    private struct Root: Hashable {
        let scope: String
        let path: String
    }
    @ObservationIgnored private var expandedByRoot: [Root: Set<String>] = [:]

    /// The workspace this tree reads. Replaced on every `sync`, so the tree
    /// follows its session between the local disk and a remote machine.
    @ObservationIgnored private var backend: WorkspaceBackend = LocalWorkspaceBackend.shared
    /// Listings live only for the current root and channel. A refresh batches
    /// previously visible directories; expanding an already seen one uses the cache.
    @ObservationIgnored private var cachedDirectories: [String: [WorkspaceEntry]] = [:]
    @ObservationIgnored private var treeEpoch: UInt64 = 0
    @ObservationIgnored private var isRebuilding = false
    @ObservationIgnored private var rebuildPending = false
    @ObservationIgnored private var refreshPending = false

    /// The hosting window presents native operation errors even when Files is hidden.
    @ObservationIgnored var onError: ((_ title: String, _ detail: String) -> Void)?

    var rootName: String {
        (rootPath as NSString).lastPathComponent
    }

    func isExpanded(_ item: Item) -> Bool {
        expanded.contains(item.path)
    }

    /// Switches the visible root without discarding expansion state from the
    /// previously visited directory. Data is still reread on every refresh.
    func sync(root: String, backend: WorkspaceBackend, scope: String = "local") async {
        let channelChanged = (self.backend as AnyObject) !== (backend as AnyObject)
        self.backend = backend
        if root != rootPath || workspaceScope != scope {
            treeEpoch &+= 1
            cachedDirectories.removeAll()
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
        } else if channelChanged {
            treeEpoch &+= 1
            cachedDirectories.removeAll()
        }
        await rebuild(refresh: true)
    }

    func toggle(_ item: Item) async {
        guard item.isDirectory, items.contains(where: { $0.path == item.path && $0.isDirectory }) else { return }
        if !expanded.insert(item.path).inserted {
            expanded.remove(item.path)
        }
        // Update the row's disclosure/icon immediately, before any remote IO.
        items = items.map { row in
            guard row.path == item.path else { return row }
            var row = row
            row.isExpanded = expanded.contains(row.path)
            return row
        }
        await rebuild()
    }

    /// Moves `item` to the Trash, then rebuilds so it drops out of the tree.
    func moveToTrash(_ item: Item) async {
        let backend = self.backend
        let scope = workspaceScope
        let root = rootPath
        let epoch = treeEpoch
        do {
            try await backend.delete(paths: [item.path])
            if scope == workspaceScope, root == rootPath, epoch == treeEpoch {
                expanded.remove(item.path)
                invalidateDirectory(containing: item.path)
                await rebuild()
            }
        } catch {
            presentError(
                String(
                    localized: "Couldn’t move “\(item.name)” to the Trash.", table: "Workspace",
                    comment: "File operation error. The placeholder is a file or folder name."
                ),
                error.localizedDescription
            )
        }
    }

    /// Deletes `item` outright, then rebuilds so it drops out of the tree.
    /// Used where the workspace has no Trash to move it to — a remote
    /// machine — so the caller confirms with the user first.
    func delete(_ item: Item) async {
        let backend = self.backend
        let scope = workspaceScope
        let root = rootPath
        let epoch = treeEpoch
        do {
            try await backend.delete(paths: [item.path])
            if scope == workspaceScope, root == rootPath, epoch == treeEpoch {
                expanded.remove(item.path)
                invalidateDirectory(containing: item.path)
                await rebuild()
            }
        } catch {
            presentError(
                String(
                    localized: "Couldn’t delete “\(item.name)”.", table: "Workspace",
                    comment: "File operation error. The placeholder is a file or folder name."
                ),
                error.localizedDescription
            )
        }
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
        let epoch = treeEpoch
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
        let exists: WorkspaceStat?
        do {
            exists = try await backend.stat(path: dest)
        } catch {
            if scope == workspaceScope, root == rootPath, epoch == treeEpoch {
                presentError(String(localized: "Couldn’t rename to “\(trimmed)”.", table: "Workspace"), error.localizedDescription)
            }
            return nil
        }
        guard scope == workspaceScope, root == rootPath, epoch == treeEpoch else { return nil }
        guard caseOnlyChange || exists == nil else {
            presentError(
                String(localized: "Couldn’t rename to “\(trimmed)”.", table: "Workspace"),
                String(localized: "An item named “\(trimmed)” already exists here.", table: "Workspace")
            )
            return nil
        }
        do {
            try await backend.rename(from: item.path, to: dest)
        } catch {
            if scope == workspaceScope, root == rootPath, epoch == treeEpoch {
                presentError(String(localized: "Couldn’t rename to “\(trimmed)”.", table: "Workspace"), error.localizedDescription)
            }
            return nil
        }
        guard scope == workspaceScope, root == rootPath, epoch == treeEpoch else { return nil }
        remapExpanded(from: item.path, to: dest)
        invalidateDirectory(containing: item.path)
        let currentEpoch = treeEpoch
        await rebuild()
        return scope == workspaceScope && root == rootPath && currentEpoch == treeEpoch ? dest : nil
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
    func commitDraft(name: String, isCurrentTarget: () -> Bool = { true }) async -> String? {
        guard isCurrentTarget(), let draft else { return nil }
        let backend = self.backend
        let scope = workspaceScope
        let root = rootPath
        let epoch = treeEpoch
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
        let exists: WorkspaceStat?
        do {
            exists = try await backend.stat(path: dest)
        } catch {
            presentError(String(localized: "Couldn’t create “\(trimmed)”.", table: "Workspace"), error.localizedDescription)
            await rebuild()
            return nil
        }
        guard isCurrentTarget(), scope == workspaceScope, root == rootPath,
              epoch == treeEpoch else { return nil }
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
            } catch {
                presentError(String(localized: "Couldn’t create the file.", table: "Workspace"), error.localizedDescription)
            }
        }
        if isCurrentTarget(), scope == workspaceScope, root == rootPath,
           epoch == treeEpoch {
            invalidateDirectory(containing: dest)
            await rebuild()
            return createdFile
        }
        return nil
    }

    private func presentError(_ messageText: String, _ informativeText: String) {
        onError?(messageText, informativeText)
    }

    private func invalidateDirectory(containing path: String) {
        treeEpoch &+= 1
        cachedDirectories.removeValue(forKey: (path as NSString).deletingLastPathComponent)
    }

    private func rebuild(refresh: Bool = false) async {
        guard !rootPath.isEmpty else { return }
        if refresh { refreshPending = true }
        if isRebuilding {
            rebuildPending = true
            return
        }
        isRebuilding = true
        repeat {
            rebuildPending = false
            let needsRefresh = refreshPending
            refreshPending = false
            let path = rootPath
            let scope = workspaceScope
            let epoch = treeEpoch
            let backend = self.backend
            let expanded = self.expanded
            let draft = self.draft
            var refreshedDirectories: Set<String> = []
            if needsRefresh {
                let directories = Array(Set(cachedDirectories.keys).union([path])).sorted()
                refreshedDirectories = Set(directories)
                let fresh = await backend.list(directories: directories)
                if epoch == treeEpoch, path == rootPath, scope == workspaceScope {
                    cachedDirectories.merge(fresh, uniquingKeysWith: { _, new in new })
                } else {
                    rebuildPending = true
                    continue
                }
            }

            var traversal = TreeDisplayModel.Traversal(root: path, directoryDepthLimit: 32) {
                expanded.contains($0)
            }
            var visited: Set<String> = []
            while let directory = traversal.nextDirectory() {
                visited.insert(directory)
                var entries = cachedDirectories[directory]
                if entries == nil && !refreshedDirectories.contains(directory) {
                    entries = try? await backend.list(directory: directory)
                    if epoch != treeEpoch || path != rootPath || scope != workspaceScope {
                        rebuildPending = true
                        break
                    }
                    if let entries { cachedDirectories[directory] = entries }
                }
                traversal.receive(Self.children(of: directory, entries: entries, draft: draft))
            }
            if !rebuildPending, traversal.rootReadable,
               epoch == treeEpoch, path == rootPath, scope == workspaceScope {
                if traversal.rows != items { items = traversal.rows }
                cachedDirectories = cachedDirectories.filter { visited.contains($0.key) }
            } else if epoch != treeEpoch || path != rootPath || scope != workspaceScope {
                rebuildPending = true
            }
        } while rebuildPending
        isRebuilding = false
    }

    private static func children(
        of dir: String, entries: [WorkspaceEntry]?, draft: Draft?
    ) -> [Item]? {
        guard let entries else { return nil }
        var out: [Item] = []
        if let draft, draft.parentDir == dir {
            out.append(Item(
                name: "", path: dir + "/\u{1}draft",
                isDirectory: draft.isDirectory, isDraft: true
            ))
        }
        out += entries
            .filter { $0.name != ".git" }
            .map { entry in
                Item(
                    name: entry.name,
                    path: (dir as NSString).appendingPathComponent(entry.name),
                    isDirectory: entry.isDirectory
                )
            }
        return out
    }
}
