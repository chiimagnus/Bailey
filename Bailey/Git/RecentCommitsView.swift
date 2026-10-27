import AppKit
import GhosttyTheme
import SwiftUI

struct GitGraphReferenceGroup {
    typealias Reference = GitStatusModel.RecentCommit.Reference

    let primary: Reference
    let remotes: [Reference]

    var references: [Reference] { [primary] + remotes }

    static func grouped(
        _ references: [Reference], remotes: [String],
        worktrees: [GitStatusModel.WorktreeLocation] = []
    ) -> [Self] {
        let checkedOut = Set(worktrees.compactMap(\.branch))
        let branches = references.filter { $0.kind == .localBranch }
        var ordered = references.filter { $0.kind == .currentBranch }
        ordered += references.filter { $0.kind == .detachedHead }
        ordered += branches.filter { checkedOut.contains($0.name) }
        ordered += branches.filter { !checkedOut.contains($0.name) }
        for kind in [Reference.Kind.remoteBranch, .tag, .remoteAlias] {
            ordered += references.filter { $0.kind == kind }
        }
        let locals = ordered.filter {
            $0.kind == .currentBranch || $0.kind == .localBranch
        }
        var ownerByName: [String: Reference] = [:]
        for local in locals where ownerByName[local.name] == nil {
            ownerByName[local.name] = local
        }

        var matchedRemoteIDs = Set<String>()
        var followers: [String: [Reference]] = [:]
        for reference in references where reference.kind == .remoteBranch {
            guard let remote = remotes.filter({
                reference.name.hasPrefix($0 + "/")
            }).max(by: { $0.count < $1.count }) else { continue }
            let branchName = String(reference.name.dropFirst(remote.count + 1))
            guard let owner = ownerByName[branchName] else { continue }
            followers[owner.id, default: []].append(reference)
            matchedRemoteIDs.insert(reference.id)
        }

        return ordered.compactMap { reference in
            guard !matchedRemoteIDs.contains(reference.id) else { return nil }
            return Self(primary: reference, remotes: followers[reference.id] ?? [])
        }
    }
}

/// Commit history shares the file-tree rows while drawing its own real Git DAG.
struct RecentCommitsView: View {
    typealias Commit = GitStatusModel.RecentCommit
    typealias Reference = Commit.Reference

    enum BranchAction { case rename, delete, push, merge, rebase, archive, createWorktree }
    enum RemoteAction { case checkout, fetch, merge, pull, delete, archive }
    enum TagAction { case details, delete, push, archive }
    enum HistoricalFileAction { case viewRevision, compareWorktree, openWorkingFile, resetFile }
    enum WorktreeAction { case open, revealInFinder, remove }

    static let badgeHeight: CGFloat = 16
    static let badgeIconSize: CGFloat = 16
    static let badgeFontSize: CGFloat = 9
    static let badgeHorizontalPadding: CGFloat = 4

    private let themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    @Binding private var expandedCommitIDs: Set<String>
    @Binding private var collapsedFolders: Set<String>
    @State private var requestedLastCommit: String?
    @State private var viewportWidth: CGFloat = 0
    @State private var localKeyboardOwner = TreeKeyboardOwner()
    @State private var keyboardFocused = false
    @State private var selectedRowID: String?
    @State private var contextRowID: String?
    @Environment(\.controlActiveState) private var controlActiveState

    private let providedKeyboardOwner: TreeKeyboardOwner?
    private let isKeyboardActive: Bool
    private let onKeyboardFocused: () -> Void
    private let onKeyboardAttached: () -> Void
    private let scrollToKeyboardRow: (String) -> Void

    private var keyboardOwner: TreeKeyboardOwner {
        providedKeyboardOwner ?? localKeyboardOwner
    }

    private var currentTheme: GhosttyThemeDefinition {
        Theme.terminal(dark: colorScheme == .dark)
    }

    private var graphPalette: GitGraphPalette { GitGraphPalette(theme: currentTheme) }
    private var graphTextColor: Color { Color(nsColor: currentTheme.foregroundNSColor) }
    private var graphSecondaryText: Color { graphTextColor.opacity(0.65) }
    private var graphTertiaryText: Color { graphTextColor.opacity(0.45) }

    let commits: [Commit]
    let remotes: [String]
    let stashFilesByOID: [String: GitStatusModel.StashFilesState]
    let repoRoot: String
    let selectionScope: String
    let displayedDiff: DiffTab?
    let fileAction: (Commit, Commit.FileChange, HistoricalFileAction) -> Void
    let loadBinaryStatus: (Commit) -> Void
    let isBinaryFile: (Commit, Commit.FileChange) -> Bool
    let viewMode: GitViewMode
    let fontScale: CGFloat
    let hasMoreCommits: Bool
    let isLoadingMore: Bool
    let loadMore: () -> Bool
    let openDiff: (Commit, Commit.FileChange) -> Void
    let canSwitchBranch: Bool
    let switchBranch: (String) -> Void
    let branchAction: (Reference, Commit, BranchAction) -> Void
    let remoteAction: (Reference, Commit, RemoteAction) -> Void
    let tagAction: (Reference, Commit, TagAction) -> Void
    let isAnnotatedTag: (String) -> Bool
    let canFetchRemoteBranch: (Reference) -> Bool
    let createBranch: (Commit) -> Void
    let addTag: (Commit) -> Void
    let canActOnCommit: Bool
    let canDropCommit: (Commit) -> Bool
    let commitAction: (Commit, GitStatusModel.CommitAction) -> Void
    let canActOnStash: Bool
    let stashAction: (GitStatusModel.Stash, GitStatusModel.StashAction) -> Void
    let openWorktreeDiff: (GitStatusModel.WorktreeChanges, GitStatusModel.Entry, Bool) -> Void
    let canActOnWorktrees: Bool
    let canRevealWorktreeInFinder: Bool
    let worktreeAction: (GitStatusModel.WorktreeLocation, WorktreeAction) -> Void
    let canCreateWorktree: (Reference) -> Bool
    let createWorktree: (Reference, Commit) -> Void

    init(
        commits: [Commit],
        remotes: [String] = [],
        stashFilesByOID: [String: GitStatusModel.StashFilesState] = [:],
        repoRoot: String,
        selectionScope: String = "local",
        displayedDiff: DiffTab? = nil,
        fileAction: @escaping (Commit, Commit.FileChange, HistoricalFileAction) -> Void,
        loadBinaryStatus: @escaping (Commit) -> Void,
        isBinaryFile: @escaping (Commit, Commit.FileChange) -> Bool,
        expandedCommitIDs: Binding<Set<String>>,
        collapsedFolders: Binding<Set<String>>,
        viewMode: GitViewMode,
        fontScale: CGFloat,
        hasMoreCommits: Bool,
        isLoadingMore: Bool,
        loadMore: @escaping () -> Bool,
        openDiff: @escaping (Commit, Commit.FileChange) -> Void,
        canSwitchBranch: Bool,
        switchBranch: @escaping (String) -> Void,
        branchAction: @escaping (Reference, Commit, BranchAction) -> Void,
        remoteAction: @escaping (Reference, Commit, RemoteAction) -> Void,
        tagAction: @escaping (Reference, Commit, TagAction) -> Void,
        isAnnotatedTag: @escaping (String) -> Bool,
        canFetchRemoteBranch: @escaping (Reference) -> Bool,
        createBranch: @escaping (Commit) -> Void,
        addTag: @escaping (Commit) -> Void,
        canActOnCommit: Bool,
        canDropCommit: @escaping (Commit) -> Bool,
        commitAction: @escaping (Commit, GitStatusModel.CommitAction) -> Void,
        canActOnStash: Bool = true,
        stashAction: @escaping (GitStatusModel.Stash, GitStatusModel.StashAction) -> Void = { _, _ in },
        openWorktreeDiff: @escaping (GitStatusModel.WorktreeChanges, GitStatusModel.Entry, Bool) -> Void = { _, _, _ in },
        canActOnWorktrees: Bool = false,
        canRevealWorktreeInFinder: Bool = false,
        worktreeAction: @escaping (GitStatusModel.WorktreeLocation, WorktreeAction) -> Void = { _, _ in },
        canCreateWorktree: @escaping (Reference) -> Bool = { _ in false },
        createWorktree: @escaping (Reference, Commit) -> Void = { _, _ in },
        keyboardOwner: TreeKeyboardOwner? = nil,
        isKeyboardActive: Bool = true,
        onKeyboardFocused: @escaping () -> Void = {},
        onKeyboardAttached: @escaping () -> Void = {},
        scrollToKeyboardRow: @escaping (String) -> Void = { _ in }
    ) {
        self.commits = commits
        self.remotes = remotes
        self.stashFilesByOID = stashFilesByOID
        self.repoRoot = repoRoot
        self.selectionScope = selectionScope
        self.displayedDiff = displayedDiff
        self.fileAction = fileAction
        self.loadBinaryStatus = loadBinaryStatus
        self.isBinaryFile = isBinaryFile
        _expandedCommitIDs = expandedCommitIDs
        _collapsedFolders = collapsedFolders
        self.viewMode = viewMode
        self.fontScale = fontScale
        self.hasMoreCommits = hasMoreCommits
        self.isLoadingMore = isLoadingMore
        self.loadMore = loadMore
        self.openDiff = openDiff
        self.canSwitchBranch = canSwitchBranch
        self.switchBranch = switchBranch
        self.branchAction = branchAction
        self.remoteAction = remoteAction
        self.tagAction = tagAction
        self.isAnnotatedTag = isAnnotatedTag
        self.canFetchRemoteBranch = canFetchRemoteBranch
        self.createBranch = createBranch
        self.addTag = addTag
        self.canActOnCommit = canActOnCommit
        self.canDropCommit = canDropCommit
        self.commitAction = commitAction
        self.canActOnStash = canActOnStash
        self.stashAction = stashAction
        self.openWorktreeDiff = openWorktreeDiff
        self.canActOnWorktrees = canActOnWorktrees
        self.canRevealWorktreeInFinder = canRevealWorktreeInFinder
        self.worktreeAction = worktreeAction
        self.canCreateWorktree = canCreateWorktree
        self.createWorktree = createWorktree
        providedKeyboardOwner = keyboardOwner
        self.isKeyboardActive = isKeyboardActive
        self.onKeyboardFocused = onKeyboardFocused
        self.onKeyboardAttached = onKeyboardAttached
        self.scrollToKeyboardRow = scrollToKeyboardRow
    }

    var body: some View {
        let _ = themeChanges.revision
        let graph = CommitGraphLayout(commits: commits)
        let spacing = CommitGraphRails.spacing(
            lanes: graph.laneCount, viewportWidth: viewportWidth, scale: fontScale
        )
        let gutter = CommitGraphRails.gutter(
            lanes: graph.laneCount, spacing: spacing, scale: fontScale
        )

        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                let expanded = expandedCommitIDs.contains(commit.id)
                VStack(alignment: .leading, spacing: 0) {
                    commitRow(commit, graph: graph.rows[index], gutter: gutter,
                              spacing: spacing, expanded: expanded,
                              inHeadHistory: graph.knownHeadHistory.contains(commit.hash))
                        .id(commitRowID(commit))
                    if expanded {
                        if let worktree = commit.worktree {
                            worktreeFiles(worktree, commit: commit,
                                          rails: graph.rows[index].bottomRails,
                                          gutter: gutter, spacing: spacing)
                        } else if let stash = commit.stash {
                            switch stashFilesByOID[stash.oid] {
                            case .loaded(let files):
                                commitFiles(commit, files: files, rails: graph.rows[index].bottomRails,
                                            gutter: gutter, spacing: spacing)
                            case .failed(let message):
                                stashDetailPlaceholder(message, rails: graph.rows[index].bottomRails,
                                                       gutter: gutter, spacing: spacing)
                            default:
                                stashDetailPlaceholder(String(localized: "Loading stash changes…", table: "Git"),
                                                       rails: graph.rows[index].bottomRails,
                                                       gutter: gutter, spacing: spacing)
                            }
                        } else {
                            commitFiles(commit, files: commit.files, rails: graph.rows[index].bottomRails,
                                        gutter: gutter, spacing: spacing)
                        }
                    }
                }
            }
            if hasMoreCommits {
                Color.clear.frame(height: 1)
                    .onAppear {
                        if let id = commits.last(where: { $0.stash == nil })?.id {
                            requestMoreIfNeeded(after: id)
                        }
                    }
            }
        }
        .background {
            TreeKeyboardHost(owner: keyboardOwner, onKeyDown: handleGraphKey,
                onFocusChanged: { focused in
                    keyboardFocused = focused
                    if focused {
                        if selectedRowID == nil { selectedRowID = keyboardRows.first?.id }
                        onKeyboardFocused()
                    }
                }, onAttachedToWindow: onKeyboardAttached)
        }
        .onChange(of: commits.last(where: { $0.stash == nil })?.id) {
            requestedLastCommit = nil
        }
        .onChange(of: repoRoot) { _, _ in
            selectedRowID = nil
            contextRowID = nil
        }
        .onChange(of: selectionScope) { _, _ in
            selectedRowID = nil
            contextRowID = nil
        }
        .onChange(of: keyboardRows.map(\.id)) { _, ids in
            if let contextRowID, !ids.contains(contextRowID) {
                self.contextRowID = nil
            }
            if let selectedRowID, !ids.contains(selectedRowID) {
                self.selectedRowID = ids.first
            } else if selectedRowID == nil && keyboardFocused {
                selectedRowID = ids.first
            }
        }
        .onChange(of: selectedRowID) { _, id in
            if keyboardFocused, let id { scrollToKeyboardRow(id) }
        }
        .onChange(of: keyboardFocused) { _, focused in
            if focused, let selectedRowID { scrollToKeyboardRow(selectedRowID) }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) {
            viewportWidth = $0
        }
        .tint(Color(nsColor: currentTheme.accentNSColor))
    }

    private enum NavigationAction {
        case commit(Commit)
        case folder(String)
        case historicalFile(Commit, Commit.FileChange)
        case worktreeFile(GitStatusModel.WorktreeChanges, GitStatusModel.Entry, Bool)
    }

    private struct NavigationRow {
        let id: String
        let parent: String?
        let action: NavigationAction
        var isExpandable = false
        var isExpanded = false
    }

    private func commitRowID(_ commit: Commit) -> String {
        "graph:\(selectionScope)\u{0}\(repoRoot)\u{0}\(commit.id)"
    }

    private func folderRowID(_ commit: Commit, section: String, path: String) -> String {
        commitRowID(commit) + "\u{0}folder\u{0}" + section + "\u{0}" + path
    }

    private func historicalFileRowID(_ commit: Commit, file: Commit.FileChange) -> String {
        commitRowID(commit) + "\u{0}history\u{0}" + file.id
    }

    private func worktreeFileRowID(
        _ commit: Commit, section: String, path: String
    ) -> String {
        commitRowID(commit) + "\u{0}worktree\u{0}" + section + "\u{0}" + path
    }

    private var keyboardRows: [NavigationRow] {
        var rows: [NavigationRow] = []
        for commit in commits {
            let id = commitRowID(commit)
            rows.append(NavigationRow(
                id: id, parent: nil, action: .commit(commit),
                isExpandable: true, isExpanded: expandedCommitIDs.contains(commit.id)
            ))
            guard expandedCommitIDs.contains(commit.id) else { continue }
            if let worktree = commit.worktree {
                appendWorktreeNavigation(worktree, commit: commit, to: &rows)
            } else if let stash = commit.stash {
                if case .loaded(let files) = stashFilesByOID[stash.oid] {
                    appendHistoricalNavigation(files, commit: commit, to: &rows)
                }
            } else {
                appendHistoricalNavigation(commit.files, commit: commit, to: &rows)
            }
        }
        return rows
    }

    private func appendHistoricalNavigation(
        _ files: [Commit.FileChange], commit: Commit, to rows: inout [NavigationRow]
    ) {
        let id = commitRowID(commit)
        if viewMode == .tree
            && (commit.stash == nil || Set(files.map(\.path)).count == files.count) {
            let section = "commit:" + commit.id
            let nodes = TreeDisplayModel.pathRows(files.map(displayRow),
                section: section, collapsed: collapsedFolders)
            let byPath = Dictionary(files.map { ($0.path, $0) },
                uniquingKeysWith: { first, _ in first })
            var parents: [(path: String, id: String)] = []
            for node in nodes {
                while let last = parents.last, !node.path.hasPrefix(last.path + "/") {
                    parents.removeLast()
                }
                let parent = parents.last?.id ?? id
                if node.isDirectory {
                    let folder = section + ":" + node.path
                    let rowID = folderRowID(commit, section: section, path: node.path)
                    rows.append(NavigationRow(id: rowID, parent: parent, action: .folder(folder),
                        isExpandable: true, isExpanded: node.isExpanded))
                    parents.append((node.path, rowID))
                } else if let file = byPath[node.path] {
                    rows.append(NavigationRow(id: historicalFileRowID(commit, file: file),
                        parent: parent, action: .historicalFile(commit, file)))
                }
            }
        } else {
            for file in files {
                rows.append(NavigationRow(id: historicalFileRowID(commit, file: file),
                    parent: id, action: .historicalFile(commit, file)))
            }
        }
    }

    private func appendWorktreeNavigation(
        _ worktree: GitStatusModel.WorktreeChanges, commit: Commit,
        to rows: inout [NavigationRow]
    ) {
        let sections: [(name: String, staged: Bool, entries: [GitStatusModel.Entry])] = [
            ("merge", false, worktree.entries.filter(\.isConflict)),
            ("staged", true, worktree.entries.filter {
                !$0.isConflict && $0.staged != "." && $0.staged != "?"
            }),
            ("changes", false, worktree.entries.filter {
                !$0.isConflict && $0.unstaged != "."
            }),
        ]
        for section in sections where !section.entries.isEmpty {
            let parentID = commitRowID(commit)
            if viewMode == .tree {
                let sectionKey = "worktree:" + worktree.path + ":" + section.name
                let files = section.entries.map { entry in
                    TreeDisplayModel.Row(name: entry.fileName, path: entry.path,
                        isDirectory: false,
                        status: .init(Self.worktreeDisplayStatus(entry, staged: section.staged)))
                }
                let nodes = TreeDisplayModel.pathRows(files,
                    section: sectionKey, collapsed: collapsedFolders)
                let byPath = Dictionary(section.entries.map { ($0.path, $0) },
                    uniquingKeysWith: { first, _ in first })
                var parents: [(path: String, id: String)] = []
                for node in nodes {
                    while let last = parents.last, !node.path.hasPrefix(last.path + "/") {
                        parents.removeLast()
                    }
                    let parent = parents.last?.id ?? parentID
                    if node.isDirectory {
                        let key = sectionKey + ":" + node.path
                        let rowID = folderRowID(commit, section: section.name, path: node.path)
                        rows.append(NavigationRow(id: rowID, parent: parent, action: .folder(key),
                            isExpandable: true, isExpanded: node.isExpanded))
                        parents.append((node.path, rowID))
                    } else if let entry = byPath[node.path] {
                        rows.append(NavigationRow(
                            id: worktreeFileRowID(commit, section: section.name, path: entry.path),
                            parent: parent, action: .worktreeFile(worktree, entry, section.staged)))
                    }
                }
            } else {
                for entry in section.entries {
                    rows.append(NavigationRow(
                        id: worktreeFileRowID(commit, section: section.name, path: entry.path),
                        parent: parentID, action: .worktreeFile(worktree, entry, section.staged)))
                }
            }
        }
    }

    private func isFocusedRow(_ id: String) -> Bool {
        selectedRowID == id && keyboardFocused && isKeyboardActive
            && controlActiveState == .key
    }

    private func isDisplayedHistoryFile(_ file: Commit.FileChange, in commit: Commit) -> Bool {
        guard let diff = displayedDiff, diff.repoRoot == repoRoot,
              diff.path == file.path else { return false }
        let hash = file.fromStashUntracked
            ? (commit.stash?.untrackedFilesHash ?? commit.hash) : commit.hash
        if case .commit(let openedHash, _, _) = diff.source { return openedHash == hash }
        return false
    }

    private func isDisplayedWorktreeFile(
        _ entry: GitStatusModel.Entry, staged: Bool, in worktree: GitStatusModel.WorktreeChanges
    ) -> Bool {
        guard let diff = displayedDiff else { return false }
        return diff.repoRoot == worktree.path && diff.path == entry.path
            && diff.source == (staged ? .staged : .worktree)
    }

    private func selectRow(_ id: String) {
        selectedRowID = id
        if isKeyboardActive {
            onKeyboardFocused()
            keyboardOwner.focus()
        }
    }

    private func selectContextRow(_ id: String) {
        selectedRowID = id
        contextRowID = id
    }

    private func dismissContextRow(_ id: String) {
        if contextRowID == id { contextRowID = nil }
    }

    private func contextTarget(for id: String) -> ContextMenuClickTarget {
        ContextMenuClickTarget(
            onContextClick: { selectContextRow(id) },
            onMenuClosed: { dismissContextRow(id) }
        )
    }

    private func toggleFolder(_ key: String) {
        if !collapsedFolders.insert(key).inserted {
            collapsedFolders.remove(key)
        }
    }

    private func activate(_ action: NavigationAction) {
        switch action {
        case .commit(let commit):
            toggle(commit)
        case .folder(let key):
            toggleFolder(key)
        case .historicalFile(let commit, let file):
            openDiff(commit, file)
        case .worktreeFile(let worktree, let entry, let staged):
            openWorktreeDiff(worktree, entry, staged)
        }
    }

    private func handleGraphKey(_ event: NSEvent) -> Bool {
        guard isKeyboardActive, keyboardOwner.view?.window?.firstResponder === keyboardOwner.view,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { return false }
        let rows = keyboardRows
        guard !rows.isEmpty else { return false }
        let current = selectedRowID.flatMap { id in rows.firstIndex { $0.id == id } }
        switch event.keyCode {
        case 125, 126: // Down / Up
            let start = current ?? (event.keyCode == 125 ? -1 : rows.count)
            let next = max(0, min(rows.count - 1, start + (event.keyCode == 125 ? 1 : -1)))
            selectedRowID = rows[next].id
        case 49, 36, 76: // Space / Return / Enter: same action as clicking the current row
            guard let current else { return false }
            activate(rows[current].action)
        case 124: // Right expands or enters the first visible child
            guard let current else { return false }
            let row = rows[current]
            if row.isExpandable && !row.isExpanded {
                activate(row.action)
            } else if rows.indices.contains(current + 1), rows[current + 1].parent == row.id {
                selectedRowID = rows[current + 1].id
            } else { return false }
        case 123: // Left collapses or selects the parent
            guard let current else { return false }
            let row = rows[current]
            if row.isExpandable && row.isExpanded {
                activate(row.action)
            } else if let parent = row.parent {
                selectedRowID = parent
            } else { return false }
        case 53: break // Escape leaves the keyboard cursor in place
        default: return false
        }
        return true
    }

    private func requestMoreIfNeeded(after id: String) {
        guard hasMoreCommits, !isLoadingMore, requestedLastCommit != id else { return }
        if loadMore() { requestedLastCommit = id }
    }

    private func toggle(_ commit: Commit) {
        selectRow(commitRowID(commit))
        if !expandedCommitIDs.insert(commit.id).inserted {
            expandedCommitIDs.remove(commit.id)
        } else if commit.worktree == nil {
            loadBinaryStatus(commit)
        }
    }

    static func nodeHelp(_ commit: Commit, inHeadHistory: Bool) -> String {
        if let worktree = commit.worktree {
            return [String(localized: "Uncommitted Changes", table: "Git"),
                    worktree.branch ?? String(localized: "Detached HEAD", table: "Git"),
                    worktree.path].joined(separator: "\n")
        }
        var lines = [commit.hash]
        if !commit.subject.isEmpty { lines.append(commit.subject) }
        if let stash = commit.stash {
            lines.append(stash.selector)
        } else if !commit.references.isEmpty {
            lines.append(commit.references.map(\.name).joined(separator: ", "))
        }
        if inHeadHistory {
            lines.append(String(localized: "In HEAD History", table: "Git"))
        }
        return lines.joined(separator: "\n")
    }

    private func commitRow(
        _ commit: Commit, graph: CommitGraphLayout.Row, gutter: CGFloat,
        spacing: CGFloat, expanded: Bool, inHeadHistory: Bool
    ) -> some View {
        TreeRowSurface(
            depth: 0, scale: fontScale,
            focusRing: isFocusedRow(commitRowID(commit)),
            contextRing: contextRowID == commitRowID(commit),
            leadingInset: gutter, trailingInset: TreeRowStyle.contentInset,
            showsGuides: false,
            height: max(36, ceil(38 * fontScale))
        ) { hovering, layout in
            GeometryReader { bounds in
                VStack(alignment: .leading, spacing: 2 * fontScale) {
                    HStack(spacing: 4 * fontScale) {
                        if let stash = commit.stash {
                            stashBadge(stash, in: commit, colorIndex: graph.node.color)
                                .layoutPriority(1)
                        } else if commit.worktree == nil {
                            if !commit.references.isEmpty || !commit.checkedOutWorktrees.isEmpty {
                                referenceStrip(commit.references, commit: commit,
                                               colorIndex: graph.node.color)
                                    .layoutPriority(1)
                            }
                        }
                        Button { toggle(commit) } label: {
                            if commit.worktree != nil {
                                Text(verbatim: commit.subject)
                                    .font(.system(size: 12 * fontScale))
                                    .foregroundStyle(graphSecondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ScrollView(.horizontal) {
                                    Text(verbatim: commit.subject)
                                        .font(.system(size: 12.5 * fontScale))
                                        .foregroundStyle(
                                            commit.stash == nil && commit.parentHashes.count > 1
                                                && !hovering
                                                ? graphTextColor.opacity(0.55) : graphTextColor
                                        )
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .scrollIndicators(.hidden)
                                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                                .frame(minWidth: 0,
                                       maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .layoutPriority(1)
                        .help(commit.subject)
                        .overlay {
                            contextTarget(for: commitRowID(commit))
                                .contextMenu { commitContextMenu(commit) }
                                .accessibilityHidden(true)
                        }
                        .accessibilityLabel(commit.subject)
                        .accessibilityValue(expanded
                            ? String(localized: "Expanded", table: "Git")
                            : String(localized: "Collapsed", table: "Git"))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(alignment: .firstTextBaseline, spacing: 6 * fontScale) {
                        if let worktree = commit.worktree {
                            Text(verbatim: Self.worktreeDisplayPath(
                                worktree.path, among: worktreePaths
                            ))
                                .font(.system(size: 10 * fontScale, design: .monospaced))
                                .foregroundStyle(graphSecondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(worktree.path)
                                .accessibilityLabel(worktree.path)
                        } else {
                        Button { copy(commit.hash) } label: {
                            Text(verbatim: commit.shortHash)
                                .font(.system(size: 10.5 * fontScale, design: .monospaced))
                                .foregroundStyle(graphSecondaryText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                        .help(commit.hash)
                        .accessibilityLabel(String(localized: "Copy Commit Hash", table: "Git"))

                        Text(verbatim: commit.author)
                            .font(.system(size: 11 * fontScale))
                            .foregroundStyle(graphSecondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)

                        Spacer(minLength: 3)

                        Text(verbatim: commit.relativeDate)
                            .font(.system(size: 10.5 * fontScale))
                            .foregroundStyle(graphSecondaryText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                .frame(width: max(0, bounds.size.width - gutter - TreeRowStyle.contentInset))
                .modifier(layout)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(graphTextColor.opacity(0.09))
                        .frame(height: 0.5)
                        .padding(.leading, gutter)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: max(36, ceil(38 * fontScale)))
        }
        .background {
            CommitGraphRails(
                row: graph,
                isHead: commit.references.contains {
                    $0.kind == .currentBranch || $0.kind == .detachedHead
                },
                isStash: commit.stash != nil,
                isWorktree: commit.worktree != nil,
                fontScale: fontScale, laneSpacing: spacing
            )
        }
        .overlay(alignment: .topLeading) {
            Button { toggle(commit) } label: {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 14 * fontScale, height: 14 * fontScale)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(
                x: (8 + CGFloat(graph.node.lane) * spacing - 7) * fontScale,
                y: max(36, ceil(38 * fontScale)) / 2 - 7 * fontScale
            )
            .help(Self.nodeHelp(commit, inHeadHistory: inHeadHistory))
            .accessibilityLabel(commit.worktree.map { $0.branch ?? $0.path } ?? commit.shortHash + ": " + commit.subject)
            .accessibilityValue(commit.worktree?.path ?? commit.hash)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(commit) }
        .background {
            contextTarget(for: commitRowID(commit))
        }
        .contextMenu { commitContextMenu(commit) }
    }

    @ViewBuilder
    private func commitContextMenu(_ commit: Commit) -> some View {
        if let worktree = commit.worktree {
            Button(String(localized: "Copy Worktree Path", table: "Git")) {
                copy(worktree.path)
            }
        } else if let stash = commit.stash {
            stashActions(stash)
        } else {
            Button(String(localized: "Create Branch at Commit…", table: "Git")) {
                createBranch(commit)
            }
            .disabled(!canSwitchBranch)
            Button(String(localized: "Create Tag at Commit…", table: "Git")) {
                addTag(commit)
            }
            .disabled(!canSwitchBranch)
            Divider()
            ForEach(GitStatusModel.CommitAction.allCases, id: \.self) { action in
                Button(action.title) { commitAction(commit, action) }
                    .disabled(!canActOnCommit || (action == .drop && !canDropCommit(commit)))
            }
            Divider()
            Button(String(localized: "Copy Commit Hash", table: "Git")) { copy(commit.hash) }
            Button(String(localized: "Copy Commit Subject", table: "Git")) {
                copy(commit.subject)
            }
        }
    }

    static func worktreeDisplayPath(_ path: String, among paths: [String]) -> String {
        let components = (path as NSString).pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { return path }
        for length in 1...components.count {
            let suffix = Array(components.suffix(length))
            let matches = paths.filter {
                Array(($0 as NSString).pathComponents.filter { $0 != "/" }.suffix(length))
                    == suffix
            }
            if matches.count == 1 { return suffix.joined(separator: "/") }
        }
        return path
    }

    static func worktreeDisplayLabel(
        _ location: GitStatusModel.WorktreeLocation, among paths: [String]
    ) -> String {
        let name = worktreeDisplayPath(location.path, among: paths)
        return location.branch ?? String(localized: "\(name) · No branch", table: "Git")
    }

    static func worktreeDisplayStatus(_ entry: GitStatusModel.Entry,
                                      staged: Bool) -> Character {
        entry.isConflict ? "U" : staged ? entry.staged : entry.unstaged
    }

    private func worktrees(
        for reference: Reference, in commit: Commit
    ) -> [GitStatusModel.WorktreeLocation] {
        switch reference.kind {
        case .currentBranch, .localBranch:
            commit.checkedOutWorktrees.filter { $0.branch == reference.name }
        case .detachedHead:
            commit.checkedOutWorktrees.filter { $0.branch == nil }
        default:
            []
        }
    }

    private var worktreePaths: [String] {
        Array(Set([repoRoot] + commits.flatMap { $0.checkedOutWorktrees.map(\.path) }
            + commits.compactMap { $0.worktree?.path }))
    }

    private func checkedOutWorktreeIndicator(
        _ commit: Commit, colorIndex: Int
    ) -> some View {
        let locations = commit.checkedOutWorktrees
        let paths = locations.map(\.path)
        let location = locations.first { $0.path == repoRoot }
            ?? locations.first { $0.branch == nil } ?? locations[0]
        let label = Self.worktreeDisplayLabel(location, among: worktreePaths)
        let outline = RoundedRectangle(cornerRadius: 4 * fontScale)
        let palette = graphPalette
        return Button { toggle(commit) } label: {
            HStack(spacing: 0) {
                Image(systemName: "square.stack")
                    .font(.system(size: Self.badgeFontSize * fontScale))
                    .foregroundStyle(palette.iconColor(colorIndex))
                    .frame(width: Self.badgeIconSize * fontScale,
                           height: Self.badgeHeight * fontScale)
                    .background(palette.color(colorIndex))
                Text(verbatim: label)
                    .font(.system(size: Self.badgeFontSize * fontScale, weight: .medium))
                    .foregroundStyle(graphTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: min(128, max(52, viewportWidth * 0.32)) * fontScale)
                    .padding(.horizontal, Self.badgeHorizontalPadding * fontScale)
                if locations.count > 1 {
                    Text("\(locations.count)")
                        .font(.system(size: Self.badgeFontSize * fontScale, weight: .medium))
                        .padding(.trailing, Self.badgeHorizontalPadding * fontScale)
                }
            }
            .foregroundStyle(graphSecondaryText)
            .frame(height: Self.badgeHeight * fontScale)
            .background(graphTextColor.opacity(0.04))
            .clipShape(outline)
            .overlay(outline.stroke(graphTextColor.opacity(0.35), lineWidth: 1 * fontScale))
        }
        .buttonStyle(.plain)
        .help(label + "\n" + paths.joined(separator: "\n"))
        .accessibilityLabel(label + ", " + String(localized: "Worktree", table: "Git")
                            + ": " + paths.joined(separator: ", "))
        .background {
            contextTarget(for: commitRowID(commit))
        }
        .contextMenu {
            if let head = commit.references.first(where: { $0.kind == .detachedHead }) {
                referenceActions(head, commit: commit)
            } else if let location = locations.first, locations.count == 1 {
                worktreeActions(location)
            } else {
                ForEach(locations, id: \.path) { location in
                    Menu(Self.worktreeDisplayPath(location.path, among: worktreePaths)) {
                        worktreeActions(location)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func worktreeActions(_ location: GitStatusModel.WorktreeLocation) -> some View {
        Button(String(localized: "Open Worktree", table: "Git")) {
            worktreeAction(location, .open)
        }
        .disabled(!canActOnWorktrees || location.isPrunable)
        if canRevealWorktreeInFinder {
            Button(String(localized: "Reveal in Finder", table: "Git")) {
                worktreeAction(location, .revealInFinder)
            }
            .disabled(!canActOnWorktrees || location.isPrunable)
        }
        Button(String(localized: "Remove Worktree…", table: "Git"), role: .destructive) {
            worktreeAction(location, .remove)
        }
        .disabled(!canActOnWorktrees || location.isMain
                  || location.isLocked || location.isPrunable)
        Divider()
        Button(String(localized: "Copy Worktree Path", table: "Git")) {
            copy(location.path)
        }
    }

    private func stashBadge(
        _ stash: GitStatusModel.Stash, in commit: Commit, colorIndex: Int
    ) -> some View {
        let outline = RoundedRectangle(cornerRadius: 4 * fontScale)
        let palette = graphPalette
        return Button { toggle(commit) } label: {
            HStack(spacing: 0) {
                Image(systemName: "archivebox")
                    .font(.system(size: Self.badgeFontSize * fontScale))
                    .foregroundStyle(palette.iconColor(colorIndex))
                    .frame(width: Self.badgeIconSize * fontScale,
                           height: Self.badgeHeight * fontScale)
                    .background(palette.color(colorIndex))
                Text(verbatim: stash.selector)
                    .font(.system(size: Self.badgeFontSize * fontScale, weight: .medium))
                    .foregroundStyle(graphTextColor)
                    .padding(.horizontal, Self.badgeHorizontalPadding * fontScale)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: Self.badgeHeight * fontScale)
            .background(graphTextColor.opacity(0.06))
            .clipShape(outline)
            .overlay(outline.stroke(graphTextColor.opacity(0.35),
                                    lineWidth: 1 * fontScale))
        }
        .buttonStyle(.plain)
        .help(stash.selector + ": " + stash.message)
        .background {
            contextTarget(for: commitRowID(commit))
        }
        .contextMenu { stashActions(stash) }
    }

    @ViewBuilder
    private func stashActions(_ stash: GitStatusModel.Stash) -> some View {
        ForEach(GitStatusModel.StashAction.allCases, id: \.self) { action in
            Button(action.title) { stashAction(stash, action) }
                .disabled(!canActOnStash)
        }
        Divider()
        Button(String(localized: "Copy Stash Name", table: "Git")) { copy(stash.selector) }
        Button(String(localized: "Copy Stash Hash", table: "Git")) { copy(stash.oid) }
    }

    private func referenceStrip(
        _ references: [Reference], commit: Commit, colorIndex: Int
    ) -> some View {
        let groups = GitGraphReferenceGroup.grouped(
            references, remotes: remotes, worktrees: commit.checkedOutWorktrees
        )
        let primary = groups.first?.primary
        let showsWorktree = !commit.checkedOutWorktrees.isEmpty
            && (primary == nil || primary?.kind == .detachedHead
                || primary.map { worktrees(for: $0, in: commit).isEmpty } == true)
        let hidden = showsWorktree
            ? groups.flatMap(\.references).filter { $0.kind != .detachedHead }
            : (groups.first?.remotes ?? []) + groups.dropFirst().flatMap(\.references)
        return HStack(spacing: 3 * fontScale) {
            if showsWorktree {
                checkedOutWorktreeIndicator(commit, colorIndex: colorIndex)
            } else if let primary {
                referenceBadge(primary, commit: commit, colorIndex: colorIndex)
            }
            if !hidden.isEmpty {
                Menu {
                    ForEach(hidden) { reference in
                        Menu(reference.name) {
                            referenceActions(reference, commit: commit)
                        }
                    }
                } label: {
                    Text("+\(hidden.count)")
                        .font(.system(size: Self.badgeFontSize * fontScale, weight: .medium))
                        .foregroundStyle(graphSecondaryText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(hidden.map(\.name).joined(separator: ", "))
                .accessibilityLabel(hidden.map(\.name).joined(separator: ", "))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func referenceBadge(
        _ reference: Reference, commit: Commit, colorIndex: Int
    ) -> some View {
        let current = reference.kind == .currentBranch
        let matched = worktrees(for: reference, in: commit)
        let outline = RoundedRectangle(cornerRadius: 4 * fontScale)
        let palette = graphPalette
        return Button { toggle(commit) } label: {
            HStack(spacing: 0) {
                Image(systemName: reference.kind == .tag ? "tag.fill"
                      : reference.kind == .detachedHead ? "circle"
                      : "arrow.triangle.branch")
                    .font(.system(size: Self.badgeFontSize * fontScale))
                    .foregroundStyle(palette.iconColor(colorIndex))
                    .frame(width: Self.badgeIconSize * fontScale,
                           height: Self.badgeHeight * fontScale)
                    .background(palette.color(colorIndex))
                Text(verbatim: reference.name)
                    .font(.system(size: Self.badgeFontSize * fontScale,
                                  weight: current ? .semibold : .medium))
                    .foregroundStyle(graphTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: min(88, max(42, viewportWidth * 0.22)) * fontScale)
                    .padding(.horizontal, Self.badgeHorizontalPadding * fontScale)
                if !matched.isEmpty {
                    Image(systemName: "square.stack")
                        .font(.system(size: 8 * fontScale))
                        .foregroundStyle(graphSecondaryText)
                    if commit.checkedOutWorktrees.count > 1 {
                        Text("\(commit.checkedOutWorktrees.count)")
                            .font(.system(size: Self.badgeFontSize * fontScale))
                            .foregroundStyle(graphSecondaryText)
                    }
                    Spacer(minLength: Self.badgeHorizontalPadding * fontScale)
                        .frame(width: Self.badgeHorizontalPadding * fontScale)
                }
            }
            .frame(height: Self.badgeHeight * fontScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(graphTextColor.opacity(0.04))
        .clipShape(outline)
        .overlay(outline.stroke(current ? palette.color(colorIndex)
                                        : graphTextColor.opacity(0.35),
                                lineWidth: 1 * fontScale))
        .help(reference.name + (matched.isEmpty ? ""
              : "\n" + matched.map(\.path).joined(separator: "\n")))
        .accessibilityLabel(reference.name + (matched.isEmpty ? ""
            : ", " + String(localized: "Worktree", table: "Git")))
        .background {
            contextTarget(for: commitRowID(commit))
        }
        .contextMenu { referenceActions(reference, commit: commit) }
    }

    @ViewBuilder
    private func referenceActions(_ reference: Reference, commit: Commit) -> some View {
        let matches = worktrees(for: reference, in: commit)
        if !matches.isEmpty {
            let locations = commit.checkedOutWorktrees.count > 1
                ? commit.checkedOutWorktrees : matches
            Menu(String(localized: "Worktree", table: "Git")) {
                if let location = locations.first, locations.count == 1 {
                    worktreeActions(location)
                } else {
                    ForEach(locations, id: \.path) { location in
                        Menu(Self.worktreeDisplayPath(location.path, among: worktreePaths)) {
                            worktreeActions(location)
                        }
                    }
                }
            }
            Divider()
        }
        switch reference.kind {
        case .currentBranch, .localBranch:
            if reference.kind == .localBranch && canCreateWorktree(reference) {
                Button(String(localized: "Create Worktree…", table: "Git")) {
                    createWorktree(reference, commit)
                }
                .disabled(!canActOnWorktrees)
            }
            if reference.kind == .localBranch {
                Button(String(localized: "Switch to This Branch", table: "Git")) {
                    switchBranch(reference.name)
                }
                .disabled(!canSwitchBranch)
            }
            Button(String(localized: "Rename Branch…", table: "Git")) {
                branchAction(reference, commit, .rename)
            }
            .disabled(!canActOnCommit)
            if reference.kind == .localBranch {
                Button(String(localized: "Delete Branch…", table: "Git")) {
                    branchAction(reference, commit, .delete)
                }
                .disabled(!canActOnCommit)
                Button(String(localized: "Merge into Current Branch…", table: "Git")) {
                    branchAction(reference, commit, .merge)
                }
                .disabled(!canActOnCommit)
                Button(String(localized: "Rebase Current Branch onto This Branch…", table: "Git")) {
                    branchAction(reference, commit, .rebase)
                }
                .disabled(!canActOnCommit)
            }
            Button(String(localized: "Push Branch…", table: "Git")) {
                branchAction(reference, commit, .push)
            }
            .disabled(!canActOnCommit)
            Button(String(localized: "Create Archive…", table: "Git")) {
                branchAction(reference, commit, .archive)
            }
            .disabled(!canActOnCommit)
            Divider()
            Button(String(localized: "Copy Branch Name", table: "Git")) {
                copy(reference.name)
            }
        case .tag:
            if isAnnotatedTag(reference.name) {
                Button(String(localized: "View Tag Details", table: "Git")) {
                    tagAction(reference, commit, .details)
                }
                .disabled(!canActOnCommit)
            }
            Button(String(localized: "Delete Tag…", table: "Git")) {
                tagAction(reference, commit, .delete)
            }
            .disabled(!canActOnCommit)
            Button(String(localized: "Push Tag…", table: "Git")) {
                tagAction(reference, commit, .push)
            }
            .disabled(!canActOnCommit)
            Button(String(localized: "Create Archive…", table: "Git")) {
                tagAction(reference, commit, .archive)
            }
            .disabled(!canActOnCommit)
            Divider()
            Button(String(localized: "Copy Tag Name", table: "Git")) {
                copy(reference.name)
            }
        case .detachedHead:
            Button(String(localized: "Copy Commit Hash", table: "Git")) { copy(commit.hash) }
        case .remoteAlias:
            Button(String(localized: "Copy Remote Branch Name", table: "Git")) {
                copy(reference.name)
            }
        case .remoteBranch:
            Button(String(localized: "Checkout Remote Branch…", table: "Git")) {
                remoteAction(reference, commit, .checkout)
            }
            .disabled(!canActOnCommit)
            if canFetchRemoteBranch(reference) {
                Button(String(localized: "Fetch into Local Branch…", table: "Git")) {
                    remoteAction(reference, commit, .fetch)
                }
                .disabled(!canActOnCommit)
            }
            Button(String(localized: "Merge into Current Branch…", table: "Git")) {
                remoteAction(reference, commit, .merge)
            }
            .disabled(!canActOnCommit)
            Button(String(localized: "Pull into Current Branch…", table: "Git")) {
                remoteAction(reference, commit, .pull)
            }
            .disabled(!canActOnCommit)
            Button(String(localized: "Delete Remote Branch…", table: "Git")) {
                remoteAction(reference, commit, .delete)
            }
            .disabled(!canActOnCommit)
            Button(String(localized: "Create Archive…", table: "Git")) {
                remoteAction(reference, commit, .archive)
            }
            .disabled(!canActOnCommit)
            Divider()
            Button(String(localized: "Copy Remote Branch Name", table: "Git")) {
                copy(reference.name)
            }
        }
    }

    @ViewBuilder
    private func worktreeFiles(
        _ worktree: GitStatusModel.WorktreeChanges, commit: Commit,
        rails: [CommitGraphLayout.Rail], gutter: CGFloat, spacing: CGFloat
    ) -> some View {
        let conflicts = worktree.entries.filter(\.isConflict)
        let staged = worktree.entries.filter {
            !$0.isConflict && $0.staged != "." && $0.staged != "?"
        }
        let changed = worktree.entries.filter {
            !$0.isConflict && $0.unstaged != "."
        }
        if !conflicts.isEmpty {
            worktreeSection(
                conflicts, label: String(localized: "MERGE CHANGES", table: "Sidebar"),
                section: "merge", staged: false, worktree: worktree, commit: commit,
                rails: rails, gutter: gutter, spacing: spacing
            )
        }
        if !staged.isEmpty {
            worktreeSection(
                staged, label: String(localized: "STAGED CHANGES", table: "Sidebar"),
                section: "staged", staged: true, worktree: worktree, commit: commit,
                rails: rails, gutter: gutter, spacing: spacing
            )
        }
        if !changed.isEmpty {
            worktreeSection(
                changed, label: String(localized: "CHANGES", table: "Sidebar"),
                section: "changes", staged: false, worktree: worktree, commit: commit,
                rails: rails, gutter: gutter, spacing: spacing
            )
        }
    }

    @ViewBuilder
    private func worktreeSection(
        _ entries: [GitStatusModel.Entry], label: String, section: String, staged: Bool,
        worktree: GitStatusModel.WorktreeChanges, commit: Commit,
        rails: [CommitGraphLayout.Rail], gutter: CGFloat, spacing: CGFloat
    ) -> some View {
        let inset = gutter + 8 * fontScale
        TreeRowSurface(
            depth: 0, scale: fontScale, hoverEnabled: false, leadingInset: inset
        ) { _, layout in
            HStack {
                Text(verbatim: label)
                    .font(.system(size: 9 * fontScale, weight: .semibold))
                    .foregroundStyle(graphSecondaryText)
                Spacer()
                Text(entries.count, format: .number)
                    .font(.system(size: 9 * fontScale))
                    .foregroundStyle(graphTertiaryText)
            }
            .modifier(layout)
        }
        .background { fileRails(rails, spacing: spacing) }

        if viewMode == .tree {
            let rows = entries.map { entry in
                TreeDisplayModel.Row(
                    name: entry.fileName, path: entry.path, isDirectory: false,
                    status: .init(Self.worktreeDisplayStatus(entry, staged: staged))
                )
            }
            let byPath = Dictionary(entries.map { ($0.path, $0) },
                                    uniquingKeysWith: { first, _ in first })
            let key = "worktree:" + worktree.path + ":" + section
            let nodes = TreeDisplayModel.pathRows(
                rows, section: key, collapsed: collapsedFolders
            )
            ForEach(nodes) { node in
                if node.isDirectory {
                    TreeFolderRow(
                        row: node, scale: fontScale, leadingInset: inset,
                        focusRing: isFocusedRow(folderRowID(
                            commit, section: section, path: node.path
                        )),
                        contextRing: contextRowID == folderRowID(
                            commit, section: section, path: node.path
                        )
                    ) {
                        let folder = key + ":" + node.path
                        selectRow(folderRowID(commit,
                            section: section, path: node.path))
                        toggleFolder(folder)
                    }
                    .id(folderRowID(commit,
                        section: section, path: node.path))
                    .background { fileRails(rails, spacing: spacing) }
                    .background {
                        contextTarget(for: folderRowID(
                            commit, section: section, path: node.path
                        ))
                    }
                    .contextMenu {
                        Button(String(localized: "Copy Absolute Path", table: "Git")) {
                            copy((worktree.path as NSString).appendingPathComponent(node.path))
                        }
                    }
                } else if let entry = byPath[node.path] {
                    worktreeFile(entry, row: node, staged: staged, section: section,
                                 worktree: worktree, commit: commit,
                                 inset: inset, showDirectory: false)
                        .background { fileRails(rails, spacing: spacing) }
                }
            }
        } else {
            ForEach(entries, id: \.id) { entry in
                let node = TreeDisplayModel.Row(
                    name: entry.fileName, path: entry.path, isDirectory: false,
                    status: .init(Self.worktreeDisplayStatus(entry, staged: staged))
                )
                worktreeFile(entry, row: node, staged: staged, section: section,
                             worktree: worktree, commit: commit,
                             inset: inset, showDirectory: true)
                    .background { fileRails(rails, spacing: spacing) }
            }
        }
    }

    private func worktreeFile(
        _ entry: GitStatusModel.Entry, row: TreeDisplayModel.Row, staged: Bool,
        section: String, worktree: GitStatusModel.WorktreeChanges, commit: Commit,
        inset: CGFloat, showDirectory: Bool
    ) -> some View {
        let id = worktreeFileRowID(commit,
            section: section, path: entry.path)
        return TreeFileRow(
            row: row, scale: fontScale,
            directory: showDirectory ? entry.directory : nil,
            displayed: isDisplayedWorktreeFile(entry, staged: staged, in: worktree),
            focusRing: isFocusedRow(id), contextRing: contextRowID == id,
            leadingInset: inset,
            accessibilityHint: staged
                ? String(localized: "Open Staged Diff", table: "Git")
                : String(localized: "Open Working Changes", table: "Git"),
            open: {
                selectRow(id)
                openWorktreeDiff(worktree, entry, staged)
            }
        ) { _ in EmptyView() }
        .id(id)
        .background {
            contextTarget(for: id)
        }
        .contextMenu {
            Button(staged
                   ? String(localized: "Open Staged Diff", table: "Git")
                   : String(localized: "Open Working Changes", table: "Git")) {
                openWorktreeDiff(worktree, entry, staged)
            }
            Divider()
            Button(String(localized: "Copy Absolute Path", table: "Git")) {
                copy((worktree.path as NSString).appendingPathComponent(entry.path))
            }
            Button(String(localized: "Copy Relative Path", table: "Git")) {
                copy(entry.path)
            }
        }
    }

    private func stashDetailPlaceholder(
        _ message: String, rails: [CommitGraphLayout.Rail], gutter: CGFloat, spacing: CGFloat
    ) -> some View {
        TreeRowSurface(
            depth: 0, scale: fontScale, hoverEnabled: false,
            leadingInset: gutter + 8 * fontScale
        ) { _, layout in
            Text(verbatim: message)
                .font(.system(size: 9.5 * fontScale))
                .foregroundStyle(graphSecondaryText)
                .modifier(layout)
        }
        .background { fileRails(rails, spacing: spacing) }
    }

    @ViewBuilder
    private func commitFiles(
        _ commit: Commit, files: [Commit.FileChange], rails: [CommitGraphLayout.Rail],
        gutter: CGFloat, spacing: CGFloat
    ) -> some View {
        let filesInset = gutter + 8 * fontScale
        if files.isEmpty {
            TreeRowSurface(
                depth: 0, scale: fontScale, hoverEnabled: false, leadingInset: filesInset
            ) { _, layout in
                Text(String(localized: "No changed files", table: "Git"))
                    .font(.system(size: 9.5 * fontScale))
                    .foregroundStyle(graphTertiaryText)
                    .modifier(layout)
            }
            .background { fileRails(rails, spacing: spacing) }
        } else if viewMode == .tree
                    && (commit.stash == nil || Set(files.map(\.path)).count == files.count) {
            let section = "commit:" + commit.id
            let byPath = Dictionary(files.map { ($0.path, $0) },
                                    uniquingKeysWith: { first, _ in first })
            let nodes = TreeDisplayModel.pathRows(files.map(displayRow),
                                                  section: section, collapsed: collapsedFolders)
            ForEach(nodes) { node in
                if node.isDirectory {
                    TreeFolderRow(row: node, scale: fontScale, leadingInset: filesInset,
                        focusRing: isFocusedRow(folderRowID(commit,
                            section: section, path: node.path)),
                        contextRing: contextRowID == folderRowID(commit,
                            section: section, path: node.path)) {
                        selectRow(folderRowID(commit, section: section, path: node.path))
                        toggleFolder(section + ":" + node.path)
                    }
                    .id(folderRowID(commit, section: section, path: node.path))
                    .background { fileRails(rails, spacing: spacing) }
                    .background {
                        contextTarget(for: folderRowID(
                            commit, section: section, path: node.path
                        ))
                    }
                    .contextMenu {
                        Button(String(localized: "Copy Absolute Path", table: "Git")) {
                            copy((repoRoot as NSString).appendingPathComponent(node.path))
                        }
                        Button(String(localized: "Copy Relative Path", table: "Git")) {
                            copy(node.path)
                        }
                    }
                } else if let file = byPath[node.path] {
                    changedFile(file, row: node, in: commit, showDirectory: false,
                                inset: filesInset)
                        .background { fileRails(rails, spacing: spacing) }
                }
            }
        } else {
            ForEach(files) { file in
                changedFile(file, row: displayRow(file), in: commit,
                            showDirectory: true, inset: filesInset)
                    .background { fileRails(rails, spacing: spacing) }
            }
        }
    }

    private func changedFile(
        _ file: Commit.FileChange, row: TreeDisplayModel.Row,
        in commit: Commit, showDirectory: Bool, inset: CGFloat
    ) -> some View {
        TreeFileRow(
            row: row, scale: fontScale,
            directory: showDirectory ? file.directory : nil,
            displayed: isDisplayedHistoryFile(file, in: commit),
            focusRing: isFocusedRow(historicalFileRowID(commit, file: file)),
            contextRing: contextRowID == historicalFileRowID(commit, file: file),
            leadingInset: inset,
            accessibilityHint: String(localized: "Opens changes", table: "Sidebar"),
            accessibilityID: "bailey.git.history.file",
            open: {
                selectRow(historicalFileRowID(commit, file: file))
                openDiff(commit, file)
            }
        ) { _ in EmptyView() }
        .id(historicalFileRowID(commit, file: file))
        .background {
            contextTarget(for: historicalFileRowID(commit, file: file))
        }
        .contextMenu {
            Button(String(localized: "Open Historical Diff", table: "Git")) {
                openDiff(commit, file)
            }
            if file.status != "D" && commit.stash == nil {
                Button(String(localized: "View File at Revision", table: "Git")) {
                    fileAction(commit, file, .viewRevision)
                }
                .disabled(isBinaryFile(commit, file))
                Button(String(localized: "Compare with Working File", table: "Git")) {
                    fileAction(commit, file, .compareWorktree)
                }
                .disabled(isBinaryFile(commit, file))
                Button(String(localized: "Open Working File", table: "Git")) {
                    fileAction(commit, file, .openWorkingFile)
                }
                Divider()
                Button(String(localized: "Reset File to Revision…", table: "Git")) {
                    fileAction(commit, file, .resetFile)
                }
                .disabled(!canActOnCommit)
            }
            Divider()
            Button(String(localized: "Copy Absolute Path", table: "Git")) {
                copy((repoRoot as NSString).appendingPathComponent(file.path))
            }
            Button(String(localized: "Copy Relative Path", table: "Git")) {
                copy(file.path)
            }
        }
    }

    private func displayRow(_ file: Commit.FileChange) -> TreeDisplayModel.Row {
        TreeDisplayModel.Row(name: file.fileName, path: file.path, isDirectory: false,
                             status: .init(file.status))
    }

    private func fileRails(_ rails: [CommitGraphLayout.Rail], spacing: CGFloat) -> some View {
        CommitGraphRails(bottomRails: rails, fontScale: fontScale, laneSpacing: spacing)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct GitGraphPalette {
    // Twelve stable lane identities, using Ghostty's normal and bright ANSI hues.
    private static let slots = [4, 5, 2, 3, 6, 1, 12, 13, 10, 11, 14, 9]

    let colors: [NSColor]
    let iconInks: [NSColor]
    private let disconnected: NSColor

    init(theme: GhosttyThemeDefinition) {
        let background = theme.sidebarNSColor.usingColorSpace(.sRGB) ?? theme.sidebarNSColor
        let foreground = theme.foregroundNSColor.usingColorSpace(.sRGB) ?? theme.foregroundNSColor
        let fallback = Self.contrast(foreground, background) >= 2.5
            ? foreground : (Self.luminance(background) >= 0.18 ? NSColor.black : .white)
        func visible(_ color: NSColor) -> NSColor {
            if Self.contrast(color, background) >= 2.5 { return color }
            for step in 1...10 {
                let mixed = color.blended(withFraction: CGFloat(step) / 10, of: fallback) ?? fallback
                if Self.contrast(mixed, background) >= 2.5 { return mixed }
            }
            return fallback
        }
        var lanes: [NSColor] = []
        for slot in Self.slots {
            let base = (theme.paletteNSColor(slot) ?? theme.accentNSColor)
                .usingColorSpace(.sRGB) ?? theme.accentNSColor
            var candidate = visible(base)
            if lanes.contains(where: { Self.distance(candidate, $0) < 0.12 }) {
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                let lightBackdrop = Self.luminance(background) >= 0.18
                search: for shade in 0...4 {
                    let delta = CGFloat(shade) * 0.15
                    let value = lightBackdrop ? max(0.2, brightness - delta)
                                              : min(1, brightness + delta)
                    for step in 1...24 {
                        let shift = CGFloat((step + 1) / 2) * (step.isMultiple(of: 2) ? -0.06 : 0.06)
                        let hueValue = (hue + shift + 2).truncatingRemainder(dividingBy: 1)
                        let variant = NSColor(calibratedHue: hueValue,
                            saturation: max(saturation, 0.55), brightness: value, alpha: 1)
                        let adjusted = visible(variant.usingColorSpace(.sRGB) ?? variant)
                        if lanes.allSatisfy({ Self.distance(adjusted, $0) >= 0.12 }) {
                            candidate = adjusted
                            break search
                        }
                    }
                }
            }
            lanes.append(candidate)
        }
        colors = lanes
        iconInks = colors.map { Self.luminance($0) >= 0.18 ? .black : .white }
        disconnected = foreground.withAlphaComponent(0.55)
    }

    func color(_ index: Int) -> Color {
        if index == CommitGraphLayout.unconnectedWorktreeColor {
            return Color(nsColor: disconnected)
        }
        return Color(nsColor: colors[index % colors.count])
    }

    func iconColor(_ index: Int) -> Color {
        Color(nsColor: iconInks[index % iconInks.count])
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    private static func contrast(_ left: NSColor, _ right: NSColor) -> CGFloat {
        let a = luminance(left)
        let b = luminance(right)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func distance(_ left: NSColor, _ right: NSColor) -> CGFloat {
        let a = left.usingColorSpace(.sRGB) ?? left
        let b = right.usingColorSpace(.sRGB) ?? right
        return max(abs(a.redComponent - b.redComponent),
                   abs(a.greenComponent - b.greenComponent),
                   abs(a.blueComponent - b.blueComponent))
    }
}

struct CommitGraphRails: View {
    private let themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    private static let firstLaneX: CGFloat = 8

    static func spacing(lanes: Int, viewportWidth: CGFloat, scale: CGFloat) -> CGFloat {
        guard lanes > 1, viewportWidth > 0 else { return 9 }
        let maxGutter = viewportWidth * 0.34 / scale
        return min(9, max(0, (maxGutter - firstLaneX - 8) / CGFloat(lanes - 1)))
    }

    static func gutter(lanes: Int, spacing: CGFloat, scale: CGFloat) -> CGFloat {
        (firstLaneX + CGFloat(max(0, lanes - 1)) * spacing + 8) * scale
    }

    var row: CommitGraphLayout.Row? = nil
    var bottomRails: [CommitGraphLayout.Rail] = []
    var isHead = false
    var isStash = false
    var isWorktree = false
    let fontScale: CGFloat
    let laneSpacing: CGFloat

    private func laneX(_ lane: Int) -> CGFloat {
        (Self.firstLaneX + CGFloat(lane) * laneSpacing) * fontScale
    }

    var body: some View {
        let _ = themeChanges.revision
        let theme = Theme.terminal(dark: colorScheme == .dark)
        let palette = GitGraphPalette(theme: theme)
        Canvas { context, size in
            let middle = size.height / 2
            let backdrop = Color(nsColor: theme.sidebarNSColor)
            let separation = StrokeStyle(
                lineWidth: min(4, max(2, laneSpacing - 0.6)) * fontScale,
                lineCap: .round, lineJoin: .round
            )
            let stroke = StrokeStyle(
                lineWidth: 2 * fontScale, lineCap: .round, lineJoin: .round
            )
            if let row {
                for link in row.links {
                    var path = Path()
                    let linkColor: Int
                    switch link {
                    case .incoming(let rail):
                        path.move(to: CGPoint(x: laneX(rail.lane), y: 0))
                        path.addLine(to: CGPoint(x: laneX(rail.lane), y: middle))
                        linkColor = rail.color
                    case .outgoing(let rail):
                        path.move(to: CGPoint(x: laneX(rail.lane), y: middle))
                        path.addLine(to: CGPoint(x: laneX(rail.lane), y: size.height))
                        linkColor = rail.color
                    case .through(let rail):
                        path.move(to: CGPoint(x: laneX(rail.lane), y: 0))
                        path.addLine(to: CGPoint(x: laneX(rail.lane), y: size.height))
                        linkColor = rail.color
                    case .depart(let from, let to, let color):
                        let x1 = laneX(from)
                        let x2 = laneX(to)
                        path.move(to: CGPoint(x: x1, y: middle))
                        path.addCurve(
                            to: CGPoint(x: x2, y: size.height),
                            control1: CGPoint(x: x1, y: middle + size.height / 5),
                            control2: CGPoint(x: x2, y: size.height - size.height / 5)
                        )
                        linkColor = color
                    case .arrive(let from, let to, let color):
                        let x1 = laneX(from)
                        let x2 = laneX(to)
                        path.move(to: CGPoint(x: x1, y: 0))
                        path.addCurve(
                            to: CGPoint(x: x2, y: middle),
                            control1: CGPoint(x: x1, y: size.height / 5),
                            control2: CGPoint(x: x2, y: middle - size.height / 5)
                        )
                        linkColor = color
                    }
                    context.stroke(path, with: .color(backdrop), style: separation)
                    context.stroke(path, with: .color(palette.color(linkColor)),
                                   style: stroke)
                }
                let radius = 4 * fontScale
                let x = laneX(row.node.lane)
                let node = Path(ellipseIn: CGRect(
                    x: x - radius, y: middle - radius, width: 2 * radius, height: 2 * radius
                ))
                let nodeColor = palette.color(row.node.color)
                if isWorktree {
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: x, y: middle - radius - 1.5 * fontScale))
                    diamond.addLine(to: CGPoint(x: x + radius + 1.5 * fontScale, y: middle))
                    diamond.addLine(to: CGPoint(x: x, y: middle + radius + 1.5 * fontScale))
                    diamond.addLine(to: CGPoint(x: x - radius - 1.5 * fontScale, y: middle))
                    diamond.closeSubpath()
                    context.fill(diamond, with: .color(backdrop))
                    context.stroke(diamond, with: .color(nodeColor), lineWidth: 2 * fontScale)
                } else if isHead || isStash {
                    context.fill(node, with: .color(backdrop))
                    context.stroke(node, with: .color(nodeColor), lineWidth: 2 * fontScale)
                    if isStash {
                        let innerRadius = 1.8 * fontScale
                        let inner = Path(ellipseIn: CGRect(
                            x: x - innerRadius, y: middle - innerRadius,
                            width: 2 * innerRadius, height: 2 * innerRadius
                        ))
                        context.stroke(inner, with: .color(nodeColor), lineWidth: fontScale)
                    }
                } else {
                    context.fill(node, with: .color(nodeColor))
                }
            } else {
                for rail in bottomRails {
                    var path = Path()
                    path.move(to: CGPoint(x: laneX(rail.lane), y: 0))
                    path.addLine(to: CGPoint(x: laneX(rail.lane), y: size.height))
                    context.stroke(path, with: .color(backdrop), style: separation)
                    context.stroke(path, with: .color(palette.color(rail.color)),
                                   style: stroke)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
