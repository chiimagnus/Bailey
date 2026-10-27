import CoreServices
import Darwin
import Foundation
import Observation

/// Files-only visibility patterns; Git and command-palette indexing do not consume these.
nonisolated enum FilesExcludeGlob {
    static func validate(_ patterns: [String]) throws {
        for pattern in patterns {
            let segments = pattern.split(separator: "/", omittingEmptySubsequences: false)
            guard !pattern.isEmpty, !pattern.hasPrefix("/"),
                  !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !pattern.contains(where: { "\\[]{}".contains($0) }),
                  !segments.contains(where: { $0.contains("**") && $0 != "**" })
            else {
                throw NSError(domain: "Bailey.FilesExclude", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Invalid file exclusion pattern: \(pattern)", table: "Settings"
                    )
                ])
            }
        }
    }

    static func excludes(_ relativePath: String, patterns: [String]) -> Bool {
        let path = relativePath.split(separator: "/").map(String.init)
        guard !path.isEmpty else { return false }
        return patterns.contains { pattern in
            let tokens = pattern.split(separator: "/").map(String.init)
            guard pattern.contains("/") else {
                return matchesSegment(pattern, name: path[path.count - 1])
            }
            var matched = Array(repeating: false, count: path.count + 1)
            matched[0] = true
            for token in tokens {
                var next = Array(repeating: false, count: path.count + 1)
                if token == "**" {
                    next[0] = matched[0]
                    for index in 1...path.count {
                        next[index] = matched[index] || next[index - 1]
                    }
                } else {
                    for index in 1...path.count where matched[index - 1] {
                        next[index] = matchesSegment(token, name: path[index - 1])
                    }
                }
                matched = next
            }
            return matched[path.count]
        }
    }

    private static func matchesSegment(_ pattern: String, name: String) -> Bool {
        let letters = Array(name)
        var matched = Array(repeating: false, count: letters.count + 1)
        matched[0] = true
        for token in pattern {
            var next = Array(repeating: false, count: letters.count + 1)
            if token == "*" {
                next[0] = matched[0]
                if !letters.isEmpty {
                    for index in 1...letters.count {
                        next[index] = matched[index] || next[index - 1]
                    }
                }
            } else if !letters.isEmpty {
                for index in 1...letters.count where matched[index - 1] {
                    next[index] = token == "?" || token == letters[index - 1]
                }
            }
            matched = next
        }
        return matched[letters.count]
    }
}

/// Flattened, lazily-expanded view of a directory tree.
@MainActor
@Observable
final class FileTreeModel {
    typealias Item = TreeDisplayModel.Row

    let settings: AppSettings
    private(set) var showExcluded = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    func setShowExcluded(_ visible: Bool) async {
        guard visible != showExcluded else { return }
        showExcluded = visible
        await rebuild()
    }

    func refreshVisibility() async {
        await rebuild()
    }

    /// Expand the current tree to an existing file without touching its editor.
    /// A hidden ancestor is revealed only in this Files tree, not in Settings.
    func revealFile(
        _ path: String, isCurrentTarget: () -> Bool = { true }
    ) async -> Bool {
        let root = rootPath
        let scope = workspaceScope
        let epoch = treeEpoch
        let backend = self.backend
        let normalized = (path as NSString).standardizingPath
        guard !root.isEmpty, path == normalized, path != root,
              LocalPathScope.contains(path, in: root), isCurrentTarget()
        else { return false }
        let relative = String(path.dropFirst(root.count + (root.hasSuffix("/") ? 0 : 1)))
        let parts = relative.split(separator: "/")
        guard !parts.isEmpty, parts.count <= 32 else { return false }
        do {
            let physicalRoot = try await Self.physicalDirectory(
                root, backend: backend, scope: scope
            )
            let physicalParent = try await Self.physicalDirectory(
                (path as NSString).deletingLastPathComponent, backend: backend, scope: scope
            )
            guard LocalPathScope.contains(physicalParent, in: physicalRoot),
                  let stat = try await backend.stat(path: path) else { return false }
            if !stat.isRegular {
                // Local stat describes a symlink itself. Its resolved file is
                // still a valid Files row when it stays inside this root.
                guard scope == "local", stat.isSymlink, !stat.isDirectory else { return false }
                let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard LocalPathScope.contains(resolvedPath, in: physicalRoot),
                      let target = try await backend.stat(path: resolvedPath), target.isRegular
                else { return false }
            }
        } catch { return false }
        guard epoch == treeEpoch, root == rootPath, scope == workspaceScope,
              isCurrentTarget() else { return false }

        var ancestor = root
        for segment in parts.dropLast() {
            ancestor = (ancestor as NSString).appendingPathComponent(String(segment))
            expanded.insert(ancestor)
        }
        if !Self.isVisible(path, in: root, excluding: settings.filesExclude) {
            showExcluded = true
        }
        await rebuild()
        await awaitPendingRebuild()
        guard epoch == treeEpoch, root == rootPath, scope == workspaceScope,
              isCurrentTarget() else { return false }
        if !items.contains(where: { !$0.isDraft && $0.path == path }) {
            // The last displayed parent may have been cached before this file
            // was created by another process. Refresh only that directory.
            cachedDirectories.removeValue(
                forKey: (path as NSString).deletingLastPathComponent
            )
            await rebuild()
            await awaitPendingRebuild()
        }
        guard epoch == treeEpoch, root == rootPath, scope == workspaceScope,
              isCurrentTarget(),
              let item = items.first(where: { !$0.isDraft && $0.path == path })
        else { return false }
        select(item)
        return true
    }

    /// A pending inline "new file/folder": an input row shown inside
    /// `parentDir` until the user names it (Enter) or cancels (Escape/blur).
    struct Draft: Equatable {
        let parentDir: String
        let isDirectory: Bool
    }

    private(set) var rootPath = ""
    /// Windows native watchers do not follow directory symlinks into another tree.
    var hasVisibleDirectorySymlinks: Bool {
        cachedDirectories.contains { parent, entries in
            entries.contains { entry in
                guard entry.isSymlink && entry.isDirectory else { return false }
                let path = (parent as NSString).appendingPathComponent(entry.name)
                return items.contains { $0.path == path || $0.path.hasPrefix(path + "/") }
            }
        }
    }
    private(set) var items: [Item] = []
    private(set) var contentRevision: UInt64 = 0
    /// Files' keyboard focus row, independent of Selection and the displayed FileTab.
    private(set) var selectedPath: String?
    private(set) var selectedCompactPath: String?
    private(set) var selectedPaths: Set<String> = []
    private(set) var contextMenuTargetPath: String?
    @ObservationIgnored private var selectionAnchorPath: String?
    @ObservationIgnored private var activeDrag: (nonce: UUID, paths: [String])?
    var hasActiveDrag: Bool { activeDrag != nil }
    /// Path of the row currently being renamed inline, if any.
    private(set) var renamingPath: String?
    /// The pending new-file/folder input row, if any.
    private(set) var draft: Draft?
    private var expanded: Set<String> = []
    @ObservationIgnored private var workspaceScope = "local"
    private var panelIdentity: PanelContext.Identity?
    private var connectionRevision: UInt64 = 0
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
    @ObservationIgnored private var rebuildGeneration: UInt64 = 0
    @ObservationIgnored private var isRebuilding = false
    @ObservationIgnored private var rebuildPending = false
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var rebuildWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var changedDirectoriesPending: Set<String> = []
    @ObservationIgnored private var localFileEventMembers: Set<UUID> = []
    private static let defaultLocalFileEventMember = UUID()
    private var localFileEventsEnabled: Bool { !localFileEventMembers.isEmpty }
    @ObservationIgnored private var localIndexGitDirectory: String?
    @ObservationIgnored private var localFileWatcher: GitFileEventWatcher?
    @ObservationIgnored private var localWatcherRoot = ""
    @ObservationIgnored private var localWatchMappings: [String: String] = [:]
    @ObservationIgnored private var localWatchedRootSymlinkPath: String?
    @ObservationIgnored private var localWatcherGitDirectory: String?
    @ObservationIgnored private var localWatcherGitDirectories: [String] = []
    @ObservationIgnored private var localWatcherToken: UInt64 = 0
    @ObservationIgnored private var pendingLocalEvents: [GitFileEventWatcher.Event] = []
    @ObservationIgnored private var localEventRefreshTask: Task<Void, Never>?

    /// The hosting window presents native operation errors even when Files is hidden.
    @ObservationIgnored var onError: ((_ title: String, _ detail: String) -> Void)?

    var rootName: String {
        (rootPath as NSString).lastPathComponent
    }

    func isExpanded(_ item: Item) -> Bool {
        expanded.contains(item.path)
    }

    var selectedItem: Item? {
        items.first { !$0.isDraft && $0.path == selectedPath }
    }

    var selectedDirectoryPath: String? {
        guard let item = selectedItem else { return nil }
        return item.isDirectory ? (selectedCompactPath ?? item.path)
            : (item.path as NSString).deletingLastPathComponent
    }

    var selectedOperationPaths: [String] {
        let paths = items.filter { !$0.isDraft && selectedPaths.contains($0.path) }.map(\.path)
        if paths.count > 1 { return paths }
        if let selectedPath, !selectedPaths.contains(selectedPath),
           items.contains(where: { !$0.isDraft && $0.path == selectedPath }) {
            return [selectedCompactPath ?? selectedPath]
        }
        guard !paths.isEmpty else { return [] }
        if paths.count == 1, paths.first == selectedPath, let selectedCompactPath {
            return [selectedCompactPath]
        }
        return paths
    }

    func select(
        _ item: Item, extending: Bool = false, toggling: Bool = false,
        componentPath: String? = nil
    ) {
        guard !item.isDraft, items.contains(where: { !$0.isDraft && $0.path == item.path }),
              componentPath == nil || item.compactComponents.contains(where: { $0.path == componentPath })
        else { return }
        selectedCompactPath = extending || toggling ? nil : componentPath
        if extending {
            selectRange(to: item.path)
        } else if toggling {
            if !selectedPaths.insert(item.path).inserted {
                selectedPaths.remove(item.path)
            }
            selectionAnchorPath = item.path
        } else {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
        }
        selectedPath = item.path
        contextMenuTargetPath = nil
        activeDrag = nil
    }

    func focus(_ item: Item) {
        guard !item.isDraft, items.contains(where: { !$0.isDraft && $0.path == item.path })
        else { return }
        selectedPath = item.path
        selectedCompactPath = nil
        selectionAnchorPath = item.path
        contextMenuTargetPath = nil
        activeDrag = nil
    }

    func selectForContextMenu(_ item: Item, componentPath: String? = nil) {
        guard !item.isDraft, items.contains(where: { !$0.isDraft && $0.path == item.path }),
              componentPath == nil || item.compactComponents.contains(where: { $0.path == componentPath })
        else { return }
        if !selectedPaths.contains(item.path)
            || (componentPath != nil && componentPath != item.path) {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
        }
        selectedPath = item.path
        selectedCompactPath = componentPath
        contextMenuTargetPath = componentPath ?? item.path
        activeDrag = nil
    }

    func dismissContextMenu(target: String) {
        if contextMenuTargetPath == target { contextMenuTargetPath = nil }
    }

    @discardableResult
    func moveSelection(by delta: Int, extending: Bool = false) -> Item? {
        let visible = items.filter { !$0.isDraft }
        guard !visible.isEmpty else { clearSelection(); return nil }
        let current = selectedPath.flatMap { path in visible.firstIndex { $0.path == path } }
        let start = current ?? (delta >= 0 ? -1 : visible.count)
        let next = max(0, min(visible.count - 1, start + delta))
        if extending {
            if current != next {
                if selectedPaths.contains(visible[next].path) {
                    if let current { selectedPaths.remove(visible[current].path) }
                } else {
                    selectedPaths.insert(visible[next].path)
                }
            }
        } else {
            selectionAnchorPath = visible[next].path
        }
        selectedPath = visible[next].path
        selectedCompactPath = nil
        contextMenuTargetPath = nil
        activeDrag = nil
        return visible[next]
    }

    private func selectRange(to path: String) {
        let visible = items.filter { !$0.isDraft }.map(\.path)
        guard let end = visible.firstIndex(of: path) else { return }
        let anchor = selectionAnchorPath ?? selectedPath ?? path
        let start = visible.firstIndex(of: anchor) ?? end
        var lower = start
        var upper = start
        while lower > 0 && selectedPaths.contains(visible[lower - 1]) { lower -= 1 }
        while upper + 1 < visible.count && selectedPaths.contains(visible[upper + 1]) { upper += 1 }
        selectedPaths.subtract(visible[lower...upper])
        selectedPaths.formUnion(visible[min(start, end)...max(start, end)])
        selectionAnchorPath = visible[start]
    }

    func clearExplicitSelection() {
        selectedPaths.removeAll()
        selectionAnchorPath = nil
        contextMenuTargetPath = nil
        activeDrag = nil
    }

    func selectAllVisible() {
        let visible = items.filter { !$0.isDraft }.map(\.path)
        selectedPaths = Set(visible)
        if let selectedPath {
            if !selectedPaths.contains(selectedPath) { self.selectedPath = visible.first }
        } else {
            selectedPath = visible.first
        }
        selectionAnchorPath = nil
        selectedCompactPath = nil
        contextMenuTargetPath = nil
        activeDrag = nil
    }

    func contextSelection(for item: Item) -> [String] {
        guard !item.isDraft else { return [] }
        if selectedPaths.contains(item.path) {
            return items.filter { !$0.isDraft && selectedPaths.contains($0.path) }.map(\.path)
        }
        return [item.path]
    }

    func beginDrag(for item: Item) -> (nonce: UUID, paths: [String])? {
        guard let displayed = items.first(where: {
            !$0.isDraft && ($0.path == item.path
                || ($0.isDirectory && $0.compactComponents.contains { $0.path == item.path }))
        }) else { return nil }
        let paths = displayed.path == item.path ? contextSelection(for: displayed) : [item.path]
        let record = (nonce: UUID(), paths: paths)
        activeDrag = record
        return record
    }

    func consumeDrag(nonce: UUID, paths: [String]) -> Bool {
        guard let activeDrag, activeDrag.nonce == nonce, activeDrag.paths == paths,
              paths.allSatisfy({ path in items.contains {
                  !$0.isDraft && ($0.path == path
                      || ($0.isDirectory && $0.compactComponents.contains { $0.path == path }))
              } })
        else { return false }
        self.activeDrag = nil
        return true
    }

    func clearSelection() {
        selectedPath = nil
        selectedCompactPath = nil
        selectedPaths.removeAll()
        contextMenuTargetPath = nil
        selectionAnchorPath = nil
        activeDrag = nil
    }

    func nextVisibleChild(of item: Item) -> Item? {
        guard item.isDirectory, let index = items.firstIndex(where: { $0.path == item.path }),
              index + 1 < items.count else { return nil }
        let next = items[index + 1]
        return !next.isDraft && next.path.hasPrefix(item.path + "/") ? next : nil
    }

    /// Visible Files and an open Cmd+P share one on-demand FSEvents stream.
    func setLocalFileEventsEnabled(_ enabled: Bool, member: UUID? = nil) {
        let member = member ?? Self.defaultLocalFileEventMember
        let wasEnabled = localFileEventsEnabled
        if enabled { localFileEventMembers.insert(member) }
        else { localFileEventMembers.remove(member) }
        guard wasEnabled != localFileEventsEnabled else { return }
        if localFileEventsEnabled { configureLocalFileWatcher() }
        else { stopLocalFileWatcher() }
    }

    func setLocalFileIndexGitDirectory(_ directory: String?) {
        guard localIndexGitDirectory != directory else { return }
        localIndexGitDirectory = directory
        configureLocalFileWatcher()
    }

    static func watchedRootSymlinkPath(_ root: String) -> String? {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: root)) != nil else {
            return nil
        }
        let parent = physicalRootPath((root as NSString).deletingLastPathComponent)
        // FSEvents is recursive: monitoring '/' for /tmp or /var would subscribe
        // to the entire filesystem. Those top-level aliases reconcile on activation.
        guard parent != "/" else { return nil }
        return (parent as NSString).appendingPathComponent((root as NSString).lastPathComponent)
    }

    private func stopLocalFileWatcher() {
        localWatcherToken &+= 1
        localEventRefreshTask?.cancel()
        localEventRefreshTask = nil
        pendingLocalEvents.removeAll()
        localFileWatcher = nil
        localWatcherRoot = ""
        localWatchMappings.removeAll()
        localWatchedRootSymlinkPath = nil
        localWatcherGitDirectory = nil
        localWatcherGitDirectories.removeAll()
    }

    private func configureLocalFileWatcher() {
        guard localFileEventsEnabled, workspaceScope == "local", !rootPath.isEmpty else {
            if localFileWatcher != nil { stopLocalFileWatcher() }
            return
        }
        let root = rootPath
        let physicalRoot = Self.physicalRootPath(root)
        var mappings = [root: physicalRoot]
        for (parent, entries) in cachedDirectories {
            for entry in entries where entry.isSymlink && entry.isDirectory {
                let path = (parent as NSString).appendingPathComponent(entry.name)
                // A displayed directory can be collapsed into a single row
                // ("link / child") without the link path in `items` or `expanded`.
                // It still needs events: changing the link's target can split
                // that compact row into multiple visible entries.
                if items.contains(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) {
                    mappings[path] = Self.physicalRootPath(path)
                }
            }
        }
        let gitDirectory = localIndexGitDirectory
        let linkPath = Self.watchedRootSymlinkPath(root)
        guard localFileWatcher == nil || localWatcherRoot != root || localWatchMappings != mappings
                || localWatcherGitDirectory != gitDirectory
                || localWatchedRootSymlinkPath != linkPath else { return }
        let replacedWatcher = localFileWatcher != nil
        stopLocalFileWatcher()
        var extraPaths = Array(mappings.values)
        if let linkPath {
            extraPaths.append((linkPath as NSString).deletingLastPathComponent)
        }
        let watchPaths = GitFileEventWatcher.paths(
            root: physicalRoot, gitDirectory: gitDirectory, worktrees: extraPaths
        )
        let token = localWatcherToken
        localFileWatcher = GitFileEventWatcher(paths: watchPaths, onEvents: { [weak self] events in
            Task { @MainActor [weak self] in
                guard let self, self.localWatcherToken == token,
                      self.localFileEventsEnabled, self.rootPath == root,
                      self.workspaceScope == "local" else { return }
                self.queueLocalFileEvents(events)
            }
        })
        if localFileWatcher != nil {
            localWatcherRoot = root
            localWatchMappings = mappings
            localWatchedRootSymlinkPath = linkPath
            localWatcherGitDirectory = gitDirectory
            localWatcherGitDirectories = gitDirectory.map(GitFileEventWatcher.gitMetadataDirectories) ?? []
            if replacedWatcher {
                // FSEvents uses SinceNow: the old and new streams cannot
                // cover the short resubscription gap without a fresh read.
                Task { @MainActor [weak self] in
                    guard let self, self.localWatcherToken == token,
                          self.localFileEventsEnabled, self.rootPath == root else { return }
                    await self.rebuild(refresh: true)
                }
            }
        }
    }

    private func queueLocalFileEvents(_ events: [GitFileEventWatcher.Event]) {
        pendingLocalEvents.append(contentsOf: events)
        guard localEventRefreshTask == nil else { return }
        let token = localWatcherToken
        localEventRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            guard let self, self.localWatcherToken == token else { return }
            let events = self.pendingLocalEvents
            self.pendingLocalEvents.removeAll()
            self.localEventRefreshTask = nil
            await self.refreshForLocalEvents(events)
        }
    }

    private static func physicalRootPath(_ root: String) -> String {
        root.withCString { source in
            guard let resolved = Darwin.realpath(source, nil) else { return root }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Recheck disk state, never apply event paths as file-tree entries.
    func refreshForLocalEvents(_ events: [GitFileEventWatcher.Event]) async {
        guard workspaceScope == "local", !rootPath.isEmpty, !events.isEmpty else { return }
        let rescanAll = kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagRootChanged |
            kFSEventStreamEventFlagEventIdsWrapped |
            kFSEventStreamEventFlagMount |
            kFSEventStreamEventFlagUnmount
        let rootLinkChanged = events.contains { event in
            guard let link = localWatchedRootSymlinkPath else { return false }
            return event.path == link || (
                event.path == (link as NSString).deletingLastPathComponent
                    && event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            )
        }
        if rootLinkChanged || events.contains(where: { $0.flags & FSEventStreamEventFlags(rescanAll) != 0 }) {
            let epoch = treeEpoch
            let revision = contentRevision
            await rebuild(refresh: true)
            if treeEpoch == epoch, contentRevision == revision { contentRevision &+= 1 }
            return
        }

        let epoch = treeEpoch
        let revision = contentRevision
        var directories: Set<String> = []
        // MustScanSubDirs may stand for unseen descendants, even when all
        // already-loaded directory listings are unchanged.
        var unseenStructuralChange = events.contains {
            $0.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
        } || events.contains { event in
            localWatcherGitDirectories.contains { directory in
                Self.affectsFileIndex(event.path, root: rootPath, gitDirectories: [directory])
            }
        }
        let structuralFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemRemoved |
            kFSEventStreamEventFlagItemRenamed |
            kFSEventStreamEventFlagMustScanSubDirs
        )
        let directoryEntryFlags = structuralFlags |
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) |
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsSymlink)
        let loaded = Set(cachedDirectories.keys)
        // FSEvents reports physical paths; expanded directory symlinks can
        // expose the same directory under several visible tree paths.
        let mappings = localWatchMappings.isEmpty
            ? [rootPath: Self.physicalRootPath(rootPath)] : localWatchMappings
        for event in events {
            // Never standardize a missing event path: NSString changes /private/var
            // to /var for existing entries but not reliably for deleted ones.
            let reported = event.path
            var aliases = mappings.compactMap { logical, physical -> String? in
                guard LocalPathScope.contains(reported, in: physical) else { return nil }
                let relative = String(reported.dropFirst(physical.count))
                return logical == "/" ? reported : logical + relative
            }
            if aliases.isEmpty, LocalPathScope.contains(reported, in: rootPath) {
                aliases = [reported]
            }
            for path in aliases {
                if Self.affectsFileIndex(path, root: rootPath, gitDirectories: localWatcherGitDirectories) {
                    unseenStructuralChange = true
                }
                // Git internal lock/object churn is not a change to the
                // visible or searchable file set when .git is excluded.
                let metadataRoots = [rootPath + "/.git"] + localWatcherGitDirectories
                if !showExcluded && !Self.isVisible(
                    path, in: rootPath, excluding: settings.filesExclude
                ) && metadataRoots.contains(where: { LocalPathScope.contains(path, in: $0) }) {
                    continue
                }
                // Pure file-content updates cannot change directory entries.
                // Git index/ignore changes already invalidate Cmd+P above.
                guard event.flags & directoryEntryFlags != 0 else { continue }
                if path == rootPath {
                    directories.formUnion(loaded)
                    directories.insert(rootPath)
                    continue
                }
                let parent = (path as NSString).deletingLastPathComponent
                // MustScanSubDirs does not promise per-item rename flags. The
                // directory itself may have moved, so its parent must also be
                // re-read even when only a subtree-rescan event was delivered.
                if loaded.contains(parent) { directories.insert(parent) }
                if loaded.contains(path) { directories.insert(path) }
                if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                    directories.formUnion(loaded.filter { LocalPathScope.contains($0, in: path) })
                }
                // The Files tree doesn't scan collapsed descendants. Cmd+P
                // still indexes those filenames, so structural events beyond
                // the loaded frontier must invalidate its on-demand index.
                let unread = !loaded.contains(parent) && !loaded.contains(path)
                let hidden = !showExcluded && !Self.isVisible(
                    parent, in: rootPath, excluding: settings.filesExclude
                )
                if (unread || hidden), event.flags & structuralFlags != 0 {
                    unseenStructuralChange = true
                }
            }
        }
        if !directories.isEmpty { await rebuild(changed: directories) }
        if unseenStructuralChange, treeEpoch == epoch, contentRevision == revision {
            contentRevision &+= 1
        }
    }

    private static func affectsFileIndex(
        _ path: String, root: String, gitDirectories: [String]
    ) -> Bool {
        if path == root + "/.git" || (path.hasSuffix("/.gitignore") && LocalPathScope.contains(path, in: root)) {
            return true
        }
        let directories = gitDirectories.isEmpty ? [root + "/.git"] : gitDirectories
        for directory in directories where path != directory && LocalPathScope.contains(path, in: directory) {
            let relative = String(path.dropFirst(directory.count + 1))
            if ["index", "HEAD", "packed-refs", "config", "commondir", "info/exclude"].contains(relative)
                || relative.hasPrefix("refs/") && !relative.hasSuffix(".lock") {
                return true
            }
        }
        return false
    }

    func syncedTarget(for context: PanelContext) -> PanelContext.Identity? {
        guard !rootPath.isEmpty, workspaceScope == context.scope,
              panelIdentity == context.identity,
              connectionRevision == context.connectionRevision,
              (backend as AnyObject) === (context.backend as AnyObject)
        else { return nil }
        return context.identity
    }

    func matchesIndexTarget(root: String, context: PanelContext) -> Bool {
        rootPath == root && syncedTarget(for: context) != nil
    }

    /// Switches the visible root without discarding expansion state from the
    /// previously visited directory. Data is still reread on every refresh.
    @discardableResult
    func sync(
        root: String, backend: WorkspaceBackend, scope: String = "local",
        panelIdentity: PanelContext.Identity? = nil, connectionRevision: UInt64 = 0
    ) async -> Bool {
        let scopeChanged = root != rootPath || workspaceScope != scope
        let backendChanged = (self.backend as AnyObject) !== (backend as AnyObject)
        let identityChanged = self.panelIdentity != panelIdentity
        let revisionChanged = self.connectionRevision != connectionRevision
        let channelChanged = backendChanged || identityChanged || revisionChanged
        // A pinned SSH connection can be replaced without changing the tree's
        // machine or root. Keep the last trustworthy rows while the new channel
        // attempts its first read; a failed read is not proof of deletion.
        let sameRemoteRootReconnected = !scopeChanged && !backendChanged && !identityChanged
            && revisionChanged && panelIdentity != nil && scope.hasPrefix("ssh:")
        if scopeChanged || channelChanged {
            stopLocalFileWatcher()
            if scopeChanged { localIndexGitDirectory = nil }
            changedDirectoriesPending.removeAll()
            treeEpoch &+= 1
            rebuildGeneration &+= 1
            cachedDirectories.removeAll()
            // A stalled old SSH traversal cannot delay the new workspace.
            isRebuilding = false
            rebuildPending = false
            refreshPending = false
            let waiters = rebuildWaiters
            rebuildWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        self.backend = backend
        self.panelIdentity = panelIdentity
        self.connectionRevision = connectionRevision
        if scopeChanged {
            if !rootPath.isEmpty {
                let previous = Root(scope: workspaceScope, path: rootPath)
                expandedByRoot[previous] = expanded
            }
            let current = Root(scope: scope, path: root)
            expanded = expandedByRoot[current] ?? []
            workspaceScope = scope
            rootPath = root
        }
        if scopeChanged || channelChanged {
            contextMenuTargetPath = nil
            activeDrag = nil
            if !sameRemoteRootReconnected {
                items = []
                showExcluded = false
                clearSelection()
            }
            // Inline editing and old rows cannot cross a replaced connection.
            renamingPath = nil
            draft = nil
        }
        configureLocalFileWatcher() // Subscribe before reading the new root.
        return await rebuild(refresh: true)
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
        configureLocalFileWatcher()
        await rebuild()
    }

    /// Copies Finder content only into this tree's current local workspace.
    /// The actual recursive disk operation runs in LocalWorkspaceBackend.
    func importFromFinder(
        _ sources: [URL], into directory: String, isCurrentTarget: () -> Bool
    ) async -> LocalFileImportResult? {
        let root = rootPath
        let scope = workspaceScope
        let epoch = treeEpoch
        let requested = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
        let targetRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        guard !sources.isEmpty, !root.isEmpty, scope == "local",
              backend is LocalWorkspaceBackend, isCurrentTarget()
        else { return nil }
        // A visible symlink may resolve outside the project. Reject both
        // lexical escapes and resolved escapes, and tell the user why this
        // otherwise accepted Finder drop did not create any files.
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let resolvedTarget = URL(fileURLWithPath: requested).resolvingSymlinksInPath().path
        guard LocalPathScope.contains(requested, in: targetRoot),
              LocalPathScope.contains(resolvedTarget, in: resolvedRoot) else {
            presentError(
                String(localized: "Couldn’t import some files or folders.", table: "Workspace"),
                String(localized: "Target folder is outside this project: \(directory)", table: "Workspace")
            )
            return nil
        }
        // Copy through the validated physical directory, not a symlink that can be retargeted.
        let result = await LocalWorkspaceBackend.shared.copyFromFinder(sources, into: resolvedTarget)
        if epoch == treeEpoch, scope == workspaceScope, root == rootPath, isCurrentTarget() {
            await rebuild(refresh: true)
            if !result.failures.isEmpty {
                presentError(
                    String(localized: "Couldn’t import some files or folders.", table: "Workspace"),
                    result.failures.joined(separator: "\n")
                )
            }
        }
        return result
    }

    enum FileOperation {
        case copy, move, delete
    }

    struct FileBatchResult {
        var succeeded: [(source: String, destination: String?)] = []
        var failures: [String] = []
    }

    private var canMutateCurrentFiles: Bool {
        !workspaceScope.hasPrefix("ssh:") || cachedDirectories[rootPath] != nil
    }

    /// One source entry per operation; parent selections absorb descendants.
    func performFileOperation(
        _ action: FileOperation, paths: [String], into directory: String?,
        isCurrentTarget: () -> Bool = { true }
    ) async -> FileBatchResult {
        let root = rootPath
        let scope = workspaceScope
        let epoch = treeEpoch
        let backend = self.backend
        guard !root.isEmpty, isCurrentTarget() else { return FileBatchResult() }
        guard canMutateCurrentFiles else {
            let reason = String(localized:
                "Remote file list has not been verified after reconnecting.", table: "Workspace")
            presentError(
                String(localized: "Couldn’t complete file operation.", table: "Workspace"), reason
            )
            return FileBatchResult(failures: [reason])
        }
        let sourcePaths = Array(Set(paths)).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count < $1.count
        }.reduce(into: [String]()) { accepted, path in
            guard !accepted.contains(where: { LocalPathScope.contains(path, in: $0) }) else { return }
            accepted.append(path)
        }

        var result = FileBatchResult()
        let rootPath = (root as NSString).standardizingPath
        let targetPath = directory.map { ($0 as NSString).standardizingPath }
        let physicalRoot: String
        do {
            physicalRoot = try await Self.physicalDirectory(
                root, backend: backend, scope: scope
            )
        } catch {
            result.failures = sourcePaths.map { "\($0): \(error.localizedDescription)" }
            if root == self.rootPath, scope == workspaceScope, epoch == treeEpoch,
               isCurrentTarget() {
                presentError(String(localized: "Couldn’t complete file operation.", table: "Workspace"),
                             result.failures.joined(separator: "\n"))
            }
            return result
        }
        var resolvedParents: [String: String] = [:]
        var physicalTarget: String?
        if action == .copy || action == .move {
            guard let targetPath, LocalPathScope.contains(targetPath, in: rootPath) else {
                result.failures = sourcePaths.map {
                    String(localized: "Destination is outside the current project: \($0)", table: "Workspace")
                }
                if root == self.rootPath, scope == workspaceScope, epoch == treeEpoch,
                   isCurrentTarget() {
                    presentError(String(localized: "Couldn’t complete file operation.", table: "Workspace"),
                                 result.failures.joined(separator: "\n"))
                }
                return result
            }
            do {
                let resolvedTarget = try await Self.physicalDirectory(
                    targetPath, backend: backend, scope: scope
                )
                guard LocalPathScope.contains(resolvedTarget, in: physicalRoot) else {
                    throw NSError(
                        domain: "Bailey.Files", code: 3,
                        userInfo: [NSLocalizedDescriptionKey:
                            String(localized: "Destination folder is outside this project.", table: "Workspace")]
                    )
                }
                physicalTarget = resolvedTarget
            } catch {
                result.failures = sourcePaths.map { "\($0): \(error.localizedDescription)" }
                if root == self.rootPath && scope == workspaceScope, epoch == treeEpoch,
                   isCurrentTarget() {
                    presentError(String(localized: "Couldn’t complete file operation.", table: "Workspace"),
                                 result.failures.joined(separator: "\n"))
                }
                return result
            }
        }

        for source in sourcePaths {
            guard isCurrentTarget(), root == self.rootPath, scope == workspaceScope,
                  epoch == treeEpoch else { break }
            let normalized = (source as NSString).standardizingPath
            guard normalized == source,
                  source != rootPath, LocalPathScope.contains(source, in: rootPath) else {
                result.failures.append(
                    String(localized: "Source is outside the current project: \(source)", table: "Workspace")
                )
                continue
            }
            let sourceParent = (source as NSString).deletingLastPathComponent
            let resolvedParent: String
            do {
                if let cached = resolvedParents[sourceParent] {
                    resolvedParent = cached
                } else {
                    resolvedParent = try await Self.physicalDirectory(
                        sourceParent, backend: backend, scope: scope
                    )
                    resolvedParents[sourceParent] = resolvedParent
                }
                guard LocalPathScope.contains(resolvedParent, in: physicalRoot) else {
                    throw NSError(
                        domain: "Bailey.Files", code: 4,
                        userInfo: [NSLocalizedDescriptionKey:
                            String(localized: "Source folder is outside this project.", table: "Workspace")]
                    )
                }
            } catch {
                result.failures.append("\(source): \(error.localizedDescription)")
                continue
            }
            guard isCurrentTarget(), root == self.rootPath, scope == workspaceScope,
                  epoch == treeEpoch else { break }
            // Pin IO to the verified physical parent. A directory symlink may
            // change targets while a backend call is awaiting execution.
            let physicalSource = (resolvedParent as NSString)
                .appendingPathComponent((source as NSString).lastPathComponent)
            let destination = targetPath.map {
                ($0 as NSString).appendingPathComponent((source as NSString).lastPathComponent)
            }
            let physicalDestination = physicalTarget.map {
                ($0 as NSString).appendingPathComponent((source as NSString).lastPathComponent)
            }
            do {
                var completedDestination = destination
                switch action {
                case .copy:
                    guard let physicalDestination else { continue }
                    if physicalSource == physicalDestination || source == targetPath {
                        let name = try await Self.copyWithUniqueName(
                            source: physicalSource, into: resolvedParent, backend: backend
                        )
                        completedDestination = (sourceParent as NSString).appendingPathComponent(name)
                    } else {
                        try await backend.copy(from: physicalSource, to: physicalDestination)
                    }
                case .move:
                    guard let physicalDestination, physicalDestination != source else { continue }
                    try await backend.rename(from: physicalSource, to: physicalDestination)
                case .delete:
                    try await backend.delete(paths: [physicalSource])
                }
                result.succeeded.append((
                    source: source, destination: action == .delete ? nil : completedDestination
                ))
            } catch {
                result.failures.append("\(source): \(error.localizedDescription)")
            }
        }

        if root == self.rootPath, scope == workspaceScope, epoch == treeEpoch,
           isCurrentTarget() {
            for entry in result.succeeded {
                if action == .move, let destination = entry.destination {
                    remapPaths(from: entry.source, to: destination)
                } else if action == .delete {
                    expanded = expanded.filter {
                        !LocalPathScope.contains($0, in: entry.source)
                    }
                }
                invalidateDirectory(containing: entry.source)
                if let destination = entry.destination { invalidateDirectory(containing: destination) }
            }
            if !result.succeeded.isEmpty { await rebuild(refresh: true) }
            if !result.failures.isEmpty {
                presentError(String(localized: "Couldn’t complete file operation.", table: "Workspace"),
                             result.failures.joined(separator: "\n"))
            }
        }
        return result
    }

    private static func copyWithUniqueName(
        source: String, into parent: String, backend: WorkspaceBackend
    ) async throws -> String {
        let original = (source as NSString).lastPathComponent
        let fileExtension = (original as NSString).pathExtension
        let stem = fileExtension.isEmpty ? original : String(original.dropLast(fileExtension.count + 1))
        for number in 1...100 {
            let suffix = number == 1 ? " copy" : " copy \(number)"
            let name = stem + suffix + (fileExtension.isEmpty ? "" : "." + fileExtension)
            let candidate = (parent as NSString).appendingPathComponent(name)
            do {
                try await backend.copy(from: source, to: candidate)
                return name
            } catch {
                let existing = try? await backend.stat(path: candidate)
                let link = try? await backend.readSymlinkDestination(path: candidate)
                if existing == nil && link == nil { throw error }
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private static func physicalDirectory(
        _ path: String, backend: WorkspaceBackend, scope: String
    ) async throws -> String {
        if scope == "local" {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        let result = try await backend.run(
            argv: ["pwd", "-P"], cwd: path, env: nil, stdin: nil, timeout: 25
        )
        guard result.status == 0, result.stdout.count <= 16_384,
              result.stdout.last == 10,
              let resolved = String(data: result.stdout.dropLast(), encoding: .utf8),
              resolved.hasPrefix("/") else {
            throw WorkspaceError.notFound
        }
        return resolved
    }

    // MARK: - Rename

    func beginRename(_ item: Item) {
        renamingPath = item.path
        if !items.contains(where: { $0.path == item.path }) {
            Task { await rebuild() }
        }
    }

    func cancelRename() {
        renamingPath = nil
        Task { await rebuild() }
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
        guard !newName.isEmpty, newName != item.name else { return nil }
        guard canMutateCurrentFiles else {
            presentError(
                String(localized: "Couldn’t rename to “\(newName)”.", table: "Workspace"),
                String(localized: "Remote file list has not been verified after reconnecting.",
                       table: "Workspace")
            )
            return nil
        }
        guard !newName.contains("/"), !newName.contains("\0"),
              newName != ".", newName != ".." else {
            presentError(
                String(localized: "Couldn’t rename to “\(newName)”.", table: "Workspace"),
                String(localized: "A name can’t contain “/” or be “.” or “..”.", table: "Workspace")
            )
            return nil
        }
        let dir = (item.path as NSString).deletingLastPathComponent
        let dest = (dir as NSString).appendingPathComponent(newName)
        let physicalParent: String
        do {
            let physicalRoot = try await Self.physicalDirectory(root, backend: backend, scope: scope)
            physicalParent = try await Self.physicalDirectory(dir, backend: backend, scope: scope)
            guard scope == workspaceScope, root == rootPath, epoch == treeEpoch else {
                return nil
            }
            guard LocalPathScope.contains(physicalParent, in: physicalRoot) else {
                presentError(
                    String(localized: "Couldn’t rename to “\(newName)”.", table: "Workspace"),
                    String(localized: "Source folder is outside this project.", table: "Workspace")
                )
                return nil
            }
        } catch {
            if scope == workspaceScope, root == rootPath, epoch == treeEpoch {
                presentError(
                    String(localized: "Couldn’t rename to “\(newName)”.", table: "Workspace"),
                    error.localizedDescription
                )
            }
            return nil
        }
        guard scope == workspaceScope, root == rootPath, epoch == treeEpoch else { return nil }
        let physicalSource = (physicalParent as NSString).appendingPathComponent(item.name)
        let physicalDest = (physicalParent as NSString).appendingPathComponent(newName)
        // A case-only rename ("foo"→"Foo") maps to the same file on a
        // case-insensitive volume, so don't treat that as a collision.
        let caseOnlyChange = newName.lowercased() == item.name.lowercased()
        let exists: WorkspaceStat?
        do {
            exists = try await backend.stat(path: physicalDest)
        } catch {
            if scope == workspaceScope, root == rootPath, epoch == treeEpoch {
                presentError(String(localized: "Couldn’t rename to “\(newName)”.", table: "Workspace"), error.localizedDescription)
            }
            return nil
        }
        guard scope == workspaceScope, root == rootPath, epoch == treeEpoch else { return nil }
        guard caseOnlyChange || exists == nil else {
            presentError(
                String(localized: "Couldn’t rename to “\(newName)”.", table: "Workspace"),
                String(localized: "An item named “\(newName)” already exists here.", table: "Workspace")
            )
            return nil
        }
        do {
            try await backend.rename(from: physicalSource, to: physicalDest)
        } catch {
            if scope == workspaceScope, root == rootPath, epoch == treeEpoch {
                presentError(String(localized: "Couldn’t rename to “\(newName)”.", table: "Workspace"), error.localizedDescription)
            }
            return nil
        }
        // The disk mutation succeeded; only the old tree's visual state is stale.
        guard scope == workspaceScope, root == rootPath, epoch == treeEpoch else { return dest }
        remapPaths(from: item.path, to: dest)
        invalidateDirectory(containing: item.path)
        await rebuild()
        return dest
    }

    private func remapPaths(from oldPath: String, to newPath: String) {
        func moved(_ path: String) -> String {
            guard LocalPathScope.contains(path, in: oldPath) else { return path }
            return newPath + String(path.dropFirst(oldPath.count))
        }
        expanded = Set(expanded.map(moved))
        selectedPath = selectedPath.map(moved)
        selectedCompactPath = selectedCompactPath.map(moved)
        selectedPaths = Set(selectedPaths.map(moved))
        selectionAnchorPath = selectionAnchorPath.map(moved)
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
        guard canMutateCurrentFiles else {
            presentError(
                String(localized: "Couldn’t complete file operation.", table: "Workspace"),
                String(localized: "Remote file list has not been verified after reconnecting.", table: "Workspace")
            )
            return nil
        }
        let backend = self.backend
        let scope = workspaceScope
        let root = rootPath
        let epoch = treeEpoch
        self.draft = nil
        guard !name.isEmpty else { await rebuild(); return nil }
        guard !name.contains("/"), !name.contains("\0"),
              name != ".", name != ".." else {
            presentError(
                String(localized: "Couldn’t create “\(name)”.", table: "Workspace"),
                String(localized: "A name can’t contain “/” or be “.” or “..”.", table: "Workspace")
            )
            await rebuild()
            return nil
        }
        let dest = (draft.parentDir as NSString).appendingPathComponent(name)
        let physicalDest: String
        do {
            let physicalRoot = try await Self.physicalDirectory(root, backend: backend, scope: scope)
            let physicalParent = try await Self.physicalDirectory(
                draft.parentDir, backend: backend, scope: scope
            )
            guard isCurrentTarget(), scope == workspaceScope,
                  root == rootPath, epoch == treeEpoch else { return nil }
            guard LocalPathScope.contains(physicalParent, in: physicalRoot) else {
                presentError(
                    String(localized: "Couldn’t create “\(name)”.", table: "Workspace"),
                    String(localized: "Target folder is outside this project.", table: "Workspace")
                )
                await rebuild()
                return nil
            }
            physicalDest = (physicalParent as NSString).appendingPathComponent(name)
        } catch {
            guard isCurrentTarget(), scope == workspaceScope,
                  root == rootPath, epoch == treeEpoch else { return nil }
            presentError(String(localized: "Couldn’t create “\(name)”.", table: "Workspace"),
                         error.localizedDescription)
            await rebuild()
            return nil
        }
        let exists: WorkspaceStat?
        do {
            exists = try await backend.stat(path: physicalDest)
        } catch {
            guard isCurrentTarget(), scope == workspaceScope, root == rootPath, epoch == treeEpoch else { return nil }
            presentError(String(localized: "Couldn’t create “\(name)”.", table: "Workspace"), error.localizedDescription)
            await rebuild()
            return nil
        }
        guard isCurrentTarget(), scope == workspaceScope, root == rootPath,
              epoch == treeEpoch else { return nil }
        guard exists == nil else {
            presentError(
                String(localized: "Couldn’t create “\(name)”.", table: "Workspace"),
                String(localized: "An item named “\(name)” already exists here.", table: "Workspace")
            )
            await rebuild()
            return nil
        }
        var createdFile: String?
        if draft.isDirectory {
            do {
                try await backend.createDirectory(path: physicalDest)
            } catch {
                guard isCurrentTarget(), scope == workspaceScope, root == rootPath, epoch == treeEpoch else { return nil }
                presentError(String(localized: "Couldn’t create the folder.", table: "Workspace"), error.localizedDescription)
            }
        } else {
            do {
                try await backend.createFile(path: physicalDest)
                createdFile = dest
            } catch {
                guard isCurrentTarget(), scope == workspaceScope, root == rootPath, epoch == treeEpoch else { return nil }
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

    private func awaitPendingRebuild() async {
        guard isRebuilding else { return }
        await withCheckedContinuation { rebuildWaiters.append($0) }
    }

    @discardableResult
    private func rebuild(refresh: Bool = false, changed: Set<String> = []) async -> Bool {
        guard !rootPath.isEmpty else { return false }
        if refresh { refreshPending = true }
        changedDirectoriesPending.formUnion(changed)
        if isRebuilding {
            rebuildPending = true
            return false
        }
        isRebuilding = true
        let generation = rebuildGeneration
        var readFailed = false
        repeat {
            rebuildPending = false
            let needsRefresh = refreshPending
            refreshPending = false
            let changedDirectories = changedDirectoriesPending
            changedDirectoriesPending.removeAll()
            let path = rootPath
            let scope = workspaceScope
            let epoch = treeEpoch
            let backend = self.backend
            let expanded = self.expanded
            let draft = self.draft
            let exclude = settings.filesExclude
            let revealAll = showExcluded
            var refreshedDirectories: Set<String> = []
            if needsRefresh || !changedDirectories.isEmpty {
                let candidates = needsRefresh
                    ? Set(cachedDirectories.keys).union([path]) : changedDirectories
                let directories = candidates.filter {
                    revealAll || Self.isVisible($0, in: path, excluding: exclude)
                }.sorted()
                refreshedDirectories = Set(directories)
                let fresh = await backend.list(directories: directories)
                guard generation == rebuildGeneration else { return false }
                if fresh.count != directories.count { readFailed = true }
                if epoch == treeEpoch, path == rootPath, scope == workspaceScope {
                    if fresh.contains(where: { cachedDirectories[$0.key] != $0.value }) {
                        contentRevision &+= 1
                    }
                    cachedDirectories.merge(fresh, uniquingKeysWith: { _, new in new })
                } else {
                    rebuildPending = true
                    continue
                }
            }

            let knownDirectories = Set(cachedDirectories.keys)
            let renaming = renamingPath
            var traversal = TreeDisplayModel.Traversal(
                root: path, directoryDepthLimit: 32,
                inspectDirectory: { expanded.contains($0) || knownDirectories.contains($0) },
                foldDirectory: { $0 != renaming }
            ) {
                expanded.contains($0)
            }
            var queriedDirectories = refreshedDirectories
            while let directory = traversal.nextDirectory() {
                if cachedDirectories[directory] == nil && !queriedDirectories.contains(directory) {
                    // Only explicitly opened or cached directories may join
                    // this batch; compact folders must not prefetch descendants.
                    let missing = ([directory] + traversal.pendingDirectories).filter {
                        cachedDirectories[$0] == nil && !queriedDirectories.contains($0)
                    }
                    queriedDirectories.formUnion(missing)
                    let fresh = await backend.list(directories: missing)
                    guard generation == rebuildGeneration else { return false }
                    if fresh.count != missing.count { readFailed = true }
                    if epoch != treeEpoch || path != rootPath || scope != workspaceScope {
                        rebuildPending = true
                        break
                    }
                    cachedDirectories.merge(fresh, uniquingKeysWith: { _, new in new })
                }
                traversal.receive(Self.children(
                    of: directory, entries: cachedDirectories[directory], draft: draft,
                    root: path, excluding: exclude, revealAll: revealAll
                ))
            }
            if exclude != settings.filesExclude || revealAll != showExcluded {
                rebuildPending = true
            }
            if !rebuildPending, traversal.rootReadable,
               generation == rebuildGeneration, epoch == treeEpoch,
               path == rootPath, scope == workspaceScope {
                let visiblePaths = Set(traversal.rows.filter { !$0.isDraft }.map(\.path))
                if let contextMenuTargetPath,
                   !traversal.rows.contains(where: {
                       $0.path == contextMenuTargetPath
                           || $0.compactComponents.contains { $0.path == contextMenuTargetPath }
                   }) {
                    self.contextMenuTargetPath = nil
                }
                if let selectedPath, !visiblePaths.contains(selectedPath) {
                    let visibleAncestor = traversal.rows
                        .filter { $0.isDirectory && selectedPath.hasPrefix($0.path + "/") }
                        .max(by: { $0.path.count < $1.path.count })
                    let compactedChild = traversal.rows.first {
                        $0.isDirectory && !$0.compactPrefix.isEmpty
                            && $0.path.hasPrefix(selectedPath + "/")
                    }
                    self.selectedPath = (visibleAncestor ?? compactedChild)?.path
                }
                selectedPaths.formIntersection(visiblePaths)
                if let selectedCompactPath,
                   !traversal.rows.contains(where: {
                       $0.path == selectedPath
                           && $0.compactComponents.contains { $0.path == selectedCompactPath }
                   }) {
                    self.selectedCompactPath = nil
                }
                if let anchor = selectionAnchorPath, !visiblePaths.contains(anchor) {
                    selectionAnchorPath = self.selectedPath
                }
                if traversal.rows != items { items = traversal.rows }
            } else if epoch != treeEpoch || path != rootPath || scope != workspaceScope {
                rebuildPending = true
            }
        } while rebuildPending && generation == rebuildGeneration
        if generation == rebuildGeneration {
            isRebuilding = false
            configureLocalFileWatcher()
            let waiters = rebuildWaiters
            rebuildWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        return generation == rebuildGeneration && !readFailed
    }

    private static func isVisible(
        _ path: String, in root: String, excluding patterns: [String]
    ) -> Bool {
        guard path == root || LocalPathScope.contains(path, in: root) else { return false }
        guard path != root else { return true }
        let relative = String(path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
        let parts = relative.split(separator: "/")
        var prefix = ""
        for part in parts {
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            if FilesExcludeGlob.excludes(prefix, patterns: patterns) { return false }
        }
        return true
    }

    private static func children(
        of dir: String, entries: [WorkspaceEntry]?, draft: Draft?,
        root: String, excluding patterns: [String], revealAll: Bool
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
            .filter { entry in
                revealAll || isVisible(
                    (dir as NSString).appendingPathComponent(entry.name),
                    in: root, excluding: patterns
                )
            }
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
