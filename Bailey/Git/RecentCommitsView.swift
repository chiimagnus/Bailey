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

nonisolated struct CommitGraphLayoutCache: Sendable {
    private var cached: (commits: [GitStatusModel.RecentCommit], layout: CommitGraphLayout)?

    mutating func layout(for commits: [GitStatusModel.RecentCommit]) -> CommitGraphLayout {
        if let cached, cached.commits == commits { return cached.layout }
        let layout = cached.flatMap { $0.layout.reusingGeometry(from: $0.commits, for: commits) }
            ?? CommitGraphLayout(commits: commits)
        cached = (commits, layout)
        return layout
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

    /// Git Graph selection is independent of history topology, focus, and disclosure.
    struct Selection {
        private(set) var ids: Set<String> = []
        private(set) var anchor: String?
        private var extendedRange: Set<String> = []

        mutating func select(
            _ id: String, visible: [String], extending: Bool = false,
            toggling: Bool = false, fallbackAnchor: String? = nil
        ) {
            guard let end = visible.firstIndex(of: id) else { return }
            if extending {
                let source = [anchor, fallbackAnchor, id].compactMap { $0 }
                    .first { visible.contains($0) } ?? id
                let start = visible.firstIndex(of: source) ?? end
                let range = Set(visible[min(start, end)...max(start, end)])
                ids.subtract(extendedRange)
                ids.formUnion(range)
                extendedRange = range
                anchor = source
            } else {
                extendedRange.removeAll()
                if toggling {
                    if !ids.insert(id).inserted { ids.remove(id) }
                } else {
                    ids = [id]
                }
                anchor = id
            }
        }

        mutating func selectAll(visible: [String]) {
            ids = Set(visible)
            anchor = nil
            extendedRange.removeAll()
        }

        mutating func clear() {
            ids.removeAll()
            anchor = nil
            extendedRange.removeAll()
        }

        mutating func reconcile(visible: [String]) {
            guard !ids.isEmpty || anchor != nil else { return }
            let valid = Set(visible)
            ids.formIntersection(valid)
            extendedRange.formIntersection(valid)
            if let anchor, !valid.contains(anchor) {
                self.anchor = nil
                extendedRange.removeAll()
            }
        }
    }

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
    @State private var displayCache = GraphDisplayCache()
    @State private var keyboardFocused = false
    @State private var focusedRowID: String?
    @State private var selection = Selection()
    @State private var contextRowID: String?
    @Environment(\.controlActiveState) private var controlActiveState

    private let keyboardOwner: TreeKeyboardOwner
    private let isKeyboardActive: Bool
    private let onKeyboardFocused: () -> Void
    private let onKeyboardAttached: () -> Void

    private var currentTheme: GhosttyThemeDefinition {
        Theme.terminal(dark: colorScheme == .dark)
    }

    private var graphPalette: GitGraphPalette { GitGraphPalette.resolved(theme: currentTheme) }
    private var graphTextColor: Color { Color(nsColor: currentTheme.foregroundNSColor) }
    private var graphSecondaryText: Color { graphTextColor.opacity(0.65) }
    private var graphTertiaryText: Color { graphTextColor.opacity(0.45) }

    let commits: [Commit]
    let remotes: [String]
    let remoteURLs: [String: String]
    let knownRemotesByCommit: [String: Set<String>]
    let hostProviders: [String: GitHostedRemoteURL.Provider]
    let openHosted: (String, String) -> Void
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
    let loadMore: () -> Bool
    let openDiff: (Commit, Commit.FileChange) -> Void
    let canSwitchBranch: Bool
    let switchBranch: (String, String) -> Void
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
    let squashAction: ([String]) -> Void
    let commitBatchAction: ([String], GitStatusModel.CommitBatchAction) -> Void
    let headOID: String?
    let worktreeLocations: [GitStatusModel.WorktreeLocation]
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
        remotes: [String],
        remoteURLs: [String: String],
        knownRemotesByCommit: [String: Set<String>],
        hostProviders: [String: GitHostedRemoteURL.Provider],
        openHosted: @escaping (String, String) -> Void,
        stashFilesByOID: [String: GitStatusModel.StashFilesState],
        repoRoot: String,
        selectionScope: String,
        displayedDiff: DiffTab?,
        fileAction: @escaping (Commit, Commit.FileChange, HistoricalFileAction) -> Void,
        loadBinaryStatus: @escaping (Commit) -> Void,
        isBinaryFile: @escaping (Commit, Commit.FileChange) -> Bool,
        expandedCommitIDs: Binding<Set<String>>,
        collapsedFolders: Binding<Set<String>>,
        viewMode: GitViewMode,
        fontScale: CGFloat,
        hasMoreCommits: Bool,
        loadMore: @escaping () -> Bool,
        openDiff: @escaping (Commit, Commit.FileChange) -> Void,
        canSwitchBranch: Bool,
        switchBranch: @escaping (String, String) -> Void,
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
        squashAction: @escaping ([String]) -> Void,
        commitBatchAction: @escaping ([String], GitStatusModel.CommitBatchAction) -> Void,
        headOID: String?,
        worktreeLocations: [GitStatusModel.WorktreeLocation],
        canActOnStash: Bool,
        stashAction: @escaping (GitStatusModel.Stash, GitStatusModel.StashAction) -> Void,
        openWorktreeDiff: @escaping (GitStatusModel.WorktreeChanges, GitStatusModel.Entry, Bool) -> Void,
        canActOnWorktrees: Bool,
        canRevealWorktreeInFinder: Bool,
        worktreeAction: @escaping (GitStatusModel.WorktreeLocation, WorktreeAction) -> Void,
        canCreateWorktree: @escaping (Reference) -> Bool,
        createWorktree: @escaping (Reference, Commit) -> Void,
        keyboardOwner: TreeKeyboardOwner,
        isKeyboardActive: Bool,
        onKeyboardFocused: @escaping () -> Void,
        onKeyboardAttached: @escaping () -> Void
    ) {
        self.commits = commits
        self.remotes = remotes
        self.remoteURLs = remoteURLs
        self.knownRemotesByCommit = knownRemotesByCommit
        self.hostProviders = hostProviders
        self.openHosted = openHosted
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
        self.squashAction = squashAction
        self.commitBatchAction = commitBatchAction
        self.headOID = headOID
        self.worktreeLocations = worktreeLocations
        self.canActOnStash = canActOnStash
        self.stashAction = stashAction
        self.openWorktreeDiff = openWorktreeDiff
        self.canActOnWorktrees = canActOnWorktrees
        self.canRevealWorktreeInFinder = canRevealWorktreeInFinder
        self.worktreeAction = worktreeAction
        self.canCreateWorktree = canCreateWorktree
        self.createWorktree = createWorktree
        self.keyboardOwner = keyboardOwner
        self.isKeyboardActive = isKeyboardActive
        self.onKeyboardFocused = onKeyboardFocused
        self.onKeyboardAttached = onKeyboardAttached
    }

    var body: some View {
        let _ = themeChanges.revision
        let key = displayKey
        let presentation = displayCache.presentation(for: key)
        let display = presentation?.display ?? .empty
        VStack(alignment: .leading, spacing: 0) {
            if let graph = presentation?.layout {
                let spacing = CommitGraphRails.spacing(
                    lanes: graph.laneCount, viewportWidth: viewportWidth, scale: fontScale
                )
                let gutter = CommitGraphRails.gutter(
                    lanes: graph.laneCount, spacing: spacing, scale: fontScale
                )
                ForEach(display.runs) { run in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(run.rows) { row in
                            graphRow(row, graph: graph, gutter: gutter, spacing: spacing)
                        }
                    }
                    .frame(height: CGFloat(run.rows.count) * (run.isCommit
                        ? Self.commitRowHeight(fontScale) : TreeRowStyle.rowHeight(fontScale)),
                           alignment: .topLeading)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            if let presentation, hasMoreCommits,
               let last = presentation.key.commits.last(where: { $0.stash == nil })?.id {
                Color.clear.frame(height: 1)
                    .id(last)
                    .onScrollVisibilityChange(threshold: 0.1) { visible in
                        if visible, presentation.key.commits == commits { requestMoreIfNeeded(after: last) }
                    }
            }
        }
        // A long ref label must not dictate the Graph's viewport width.
        .containerRelativeFrame(.horizontal, alignment: .leading)
        .background {
            TreeKeyboardHost(owner: keyboardOwner, onKeyDown: handleGraphKey,
                onFocusChanged: { focused in
                    keyboardFocused = focused
                    if focused {
                        if focusedRowID == nil { focusedRowID = keyboardRows.first?.id }
                        onKeyboardFocused()
                    }
                }, onAttachedToWindow: onKeyboardAttached, onEditCommand: { action in
                    switch action {
                    case .selectAll:
                        selection.selectAll(visible: (presentation?.key.commits ?? []).filter {
                            $0.stash == nil && $0.worktree == nil
                        }.map(commitRowID))
                    case .copy:
                        let rows = selection.ids.isEmpty
                            ? Set([focusedRowID].compactMap { $0 }) : selection.ids
                        copy(selectedClipboardText(for: rows))
                    default: break
                    }
                }, canEditCommand: { action in
                    guard isKeyboardActive else { return false }
                    switch action {
                    case .selectAll: return presentation?.key.commits.contains { $0.stash == nil && $0.worktree == nil } == true
                    case .copy: return !selection.ids.isEmpty || focusedRowID != nil
                    default: return false
                    }
                })
        }
        .task(id: key) {
            guard !displayCache.isPrepared(for: key) else { return }
            if let prepared = await GraphDisplayCache.prepare(key, previous: displayCache),
               !Task.isCancelled {
                displayCache = prepared
            }
        }
        .onChange(of: commits.last(where: { $0.stash == nil })?.id) {
            requestedLastCommit = nil
        }
        .onChange(of: repoRoot) { _, _ in
            focusedRowID = nil
            selection.clear()
            contextRowID = nil
        }
        .onChange(of: selectionScope) { _, _ in
            focusedRowID = nil
            selection.clear()
            contextRowID = nil
        }
        .onChange(of: headOID) { _, _ in
            selection.clear()
        }
        .onChange(of: presentation?.display.navigationIDs) { _, ids in
            guard let ids else { return }
            selection.reconcile(visible: ids)
            if let contextRowID, !ids.contains(contextRowID) {
                self.contextRowID = nil
            }
            if let focusedRowID, !ids.contains(focusedRowID) {
                self.focusedRowID = ids.first
            } else if focusedRowID == nil && keyboardFocused {
                focusedRowID = ids.first
            }
        }
        .onChange(of: focusedRowID) { _, id in
            if keyboardFocused, let id { revealKeyboardRow(id) }
        }
        .onChange(of: keyboardFocused) { _, focused in
            if focused, let focusedRowID { revealKeyboardRow(focusedRowID) }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) {
            viewportWidth = $0
        }
        .tint(Color(nsColor: currentTheme.accentNSColor))
    }

    private nonisolated struct GraphRow: Identifiable, Sendable {
        enum Content: Sendable {
            case commit(expanded: Bool)
            case folder(TreeDisplayModel.Row, key: String)
            case historicalFile(Commit.FileChange, row: TreeDisplayModel.Row, showDirectory: Bool)
            case worktreeFile(GitStatusModel.WorktreeChanges, GitStatusModel.Entry,
                              row: TreeDisplayModel.Row, section: String, staged: Bool, showDirectory: Bool)
            case section(label: String, count: Int)
            case placeholder(String, secondary: Bool = false)
        }

        let id: String
        let commitIndex: Int
        var parent: String? = nil
        let content: Content

        static func historyID(_ commitID: String, file: Commit.FileChange) -> String {
            commitID + "\u{0}history\u{0}" + file.id
        }

        static func worktreeID(_ commitID: String, section: String, path: String) -> String {
            commitID + "\u{0}worktree\u{0}" + section + "\u{0}" + path
        }

        var isCommit: Bool {
            if case .commit = content { return true }
            return false
        }

        var isNavigable: Bool {
            switch content {
            case .section, .placeholder: false
            default: true
            }
        }

        var isExpandable: Bool {
            switch content {
            case .commit, .folder: true
            default: false
            }
        }
    }

    private nonisolated struct GraphRun: Identifiable, Sendable {
        let rows: ArraySlice<GraphRow>
        let isCommit: Bool
        var id: String { rows.first!.id }
    }

    private nonisolated struct GraphDisplay: Sendable {
        static let empty = GraphDisplay(rows: [])
        struct Position {
            let index: Int
            let precedingCommits: Int
            let navigationIndex: Int
            let isCommit: Bool
        }

        let runs: [GraphRun]
        let navigation: [GraphRow]
        let navigationIDs: [String]
        let positions: [String: Position]

        init(rows: [GraphRow]) {
            var runs: [GraphRun] = []
            var start = rows.startIndex
            while start < rows.endIndex {
                let isCommit = rows[start].isCommit
                var end = start + 1
                while end < rows.endIndex, rows[end].isCommit == isCommit { end += 1 }
                runs.append(GraphRun(rows: rows[start..<end], isCommit: isCommit))
                start = end
            }
            self.runs = runs
            var navigation: [GraphRow] = []
            var positions: [String: Position] = [:]
            var precedingCommits = 0
            for (index, row) in rows.enumerated() {
                if row.isNavigable {
                    positions[row.id] = Position(index: index, precedingCommits: precedingCommits,
                                                 navigationIndex: navigation.count, isCommit: row.isCommit)
                    navigation.append(row)
                }
                if row.isCommit { precedingCommits += 1 }
            }
            self.navigation = navigation
            navigationIDs = navigation.map(\.id)
            self.positions = positions
        }
    }

    private nonisolated struct GraphDisplayKey: Equatable, Sendable {
        let scope: String
        let repository: String
        let commits: [Commit]
        let stashFiles: [String: GitStatusModel.StashFilesState]
        let expanded: Set<String>
        let collapsed: Set<String>
        let mode: GitViewMode

        var prefix: String { "graph:\(scope)\u{0}\(repository)\u{0}" }

        // An outstanding disclosure calculation can keep its previous rows.
        // Never pair indices from a different repository or commit snapshot.
        func sameSource(as other: Self) -> Bool {
            guard scope == other.scope, repository == other.repository else { return false }
            if commits == other.commits { return true }
            // A newly fetched page may append rows; retain the already visible prefix.
            // Reference changes do not invalidate the identity of historical file rows.
            return commits.count <= other.commits.count && zip(commits, other.commits).allSatisfy {
                $0.id == $1.id && $0.parentHashes == $1.parentHashes
                    && $0.files == $1.files && $0.stash == $1.stash && $0.worktree == $1.worktree
            }
        }
    }

    private nonisolated struct GraphDisplayCache: Sendable {
        private struct FileIndex<Value: Equatable & Sendable>: Sendable {
            let files: [Value]
            let byPath: [String: Value]
            let tree: TreeDisplayModel.PathTree

            init(_ files: [Value], section: String, row: (Value) -> TreeDisplayModel.Row) {
                self.files = files
                let mapped = files.map { (value: $0, row: row($0)) }
                byPath = Dictionary(mapped.map { ($0.row.path, $0.value) },
                                    uniquingKeysWith: { first, _ in first })
                tree = TreeDisplayModel.PathTree(mapped.map(\.row), section: section)
            }
        }

        struct Presentation: Sendable {
            let key: GraphDisplayKey
            let display: GraphDisplay
            let layout: CommitGraphLayout
        }

        private var cached: Presentation?
        private var layoutCache = CommitGraphLayoutCache()
        private var historical: [String: FileIndex<Commit.FileChange>] = [:]
        private var worktrees: [String: FileIndex<GitStatusModel.Entry>] = [:]

        func isPrepared(for key: GraphDisplayKey) -> Bool { cached?.key == key }

        func presentation(for key: GraphDisplayKey) -> Presentation? {
            guard let cached, cached.key.sameSource(as: key) else { return nil }
            return cached
        }

        @concurrent static func prepare(_ key: GraphDisplayKey, previous: Self) async -> Self? {
            var cache = previous
            cache.update(for: key)
            return Task.isCancelled ? nil : cache
        }

        private mutating func update(for key: GraphDisplayKey) {
            if cached?.key.scope != key.scope || cached?.key.repository != key.repository {
                historical.removeAll()
                worktrees.removeAll()
                layoutCache = CommitGraphLayoutCache()
            } else if cached?.key.commits != key.commits {
                let historySections = Set(key.commits.filter { $0.worktree == nil }.map { "commit:" + $0.id })
                let worktreeSections = Set(key.commits.compactMap(\.worktree).flatMap { worktree in
                    ["merge", "staged", "changes"].map { "worktree:" + worktree.path + ":" + $0 }
                })
                historical = historical.filter { historySections.contains($0.key) }
                worktrees = worktrees.filter { worktreeSections.contains($0.key) }
            }
            guard let rows = buildRows(for: key), !Task.isCancelled else { return }
            let layout = layoutCache.layout(for: key.commits)
            guard !Task.isCancelled else { return }
            cached = Presentation(key: key, display: GraphDisplay(rows: rows), layout: layout)
        }

        mutating func historyRows(
            _ files: [Commit.FileChange], section: String, collapsed: Set<String>,
            row: (Commit.FileChange) -> TreeDisplayModel.Row
        ) -> (nodes: [TreeDisplayModel.Row], byPath: [String: Commit.FileChange]) {
            if historical[section]?.files != files {
                historical[section] = FileIndex(files, section: section, row: row)
            }
            let index = historical[section]!
            return (index.tree.rows(collapsed: collapsed), index.byPath)
        }

        mutating func worktreeRows(
            _ files: [GitStatusModel.Entry], section: String, collapsed: Set<String>,
            row: (GitStatusModel.Entry) -> TreeDisplayModel.Row
        ) -> (nodes: [TreeDisplayModel.Row], byPath: [String: GitStatusModel.Entry]) {
            if worktrees[section]?.files != files {
                worktrees[section] = FileIndex(files, section: section, row: row)
            }
            let index = worktrees[section]!
            return (index.tree.rows(collapsed: collapsed), index.byPath)
        }

        private static func folderID(_ commitID: String, section: String, path: String) -> String {
            commitID + "\u{0}folder\u{0}" + section + "\u{0}" + path
        }

        private mutating func buildRows(for key: GraphDisplayKey) -> [GraphRow]? {
            var rows: [GraphRow] = []
            for (index, commit) in key.commits.enumerated() {
                guard !Task.isCancelled else { return nil }
                let id = key.prefix + commit.id
                let expanded = key.expanded.contains(commit.id)
                rows.append(GraphRow(id: id, commitIndex: index, content: .commit(expanded: expanded)))
                guard expanded else { continue }
                if let worktree = commit.worktree {
                    appendWorktreeRows(worktree, commit: commit, index: index, key: key, to: &rows)
                } else if let stash = commit.stash {
                    switch key.stashFiles[stash.oid] {
                    case .loaded(let files):
                        appendHistoricalRows(files, commit: commit, index: index, key: key, to: &rows)
                    case .failed(let message):
                        rows.append(GraphRow(id: id + "\u{0}detail", commitIndex: index,
                                             content: .placeholder(message, secondary: true)))
                    default:
                        rows.append(GraphRow(id: id + "\u{0}detail", commitIndex: index,
                            content: .placeholder(String(localized: "Loading stash changes…", table: "Git"), secondary: true)))
                    }
                } else {
                    appendHistoricalRows(commit.files, commit: commit, index: index, key: key, to: &rows)
                }
            }
            return rows
        }

        private mutating func appendHistoricalRows(
            _ files: [Commit.FileChange], commit: Commit, index: Int, key: GraphDisplayKey,
            to rows: inout [GraphRow]
        ) {
            let id = key.prefix + commit.id
            if files.isEmpty {
                rows.append(GraphRow(id: id + "\u{0}detail", commitIndex: index,
                    content: .placeholder(String(localized: "No changed files", table: "Git"))))
            } else if key.mode == .tree
                && (commit.stash == nil || Set(files.map(\.path)).count == files.count) {
                let section = "commit:" + commit.id
                let projection = historyRows(files, section: section, collapsed: key.collapsed,
                                                           row: RecentCommitsView.displayRow)
                var parents: [(path: String, id: String)] = []
                for node in projection.nodes {
                    if Task.isCancelled { return }
                    while let last = parents.last, !node.path.hasPrefix(last.path + "/") {
                        parents.removeLast()
                    }
                    let parent = parents.last?.id ?? id
                    if node.isDirectory {
                        let rowID = Self.folderID(id, section: section, path: node.path)
                        rows.append(GraphRow(id: rowID, commitIndex: index, parent: parent,
                            content: .folder(node, key: section + ":" + node.path)))
                        parents.append((node.path, rowID))
                    } else if let file = projection.byPath[node.path] {
                        rows.append(GraphRow(id: GraphRow.historyID(id, file: file),
                            commitIndex: index, parent: parent,
                            content: .historicalFile(file, row: node, showDirectory: false)))
                    }
                }
            } else {
                for file in files {
                    if Task.isCancelled { return }
                    rows.append(GraphRow(id: GraphRow.historyID(id, file: file),
                        commitIndex: index, parent: id,
                        content: .historicalFile(file, row: RecentCommitsView.displayRow(file), showDirectory: true)))
                }
            }
        }

        private mutating func appendWorktreeRows(
            _ worktree: GitStatusModel.WorktreeChanges, commit: Commit, index: Int,
            key: GraphDisplayKey, to rows: inout [GraphRow]
        ) {
            let sections: [(name: String, label: String, staged: Bool, entries: [GitStatusModel.Entry])] = [
                ("merge", String(localized: "MERGE CHANGES", table: "Sidebar"), false,
                    worktree.entries.filter(\.isConflict)),
                ("staged", String(localized: "STAGED CHANGES", table: "Sidebar"), true,
                    worktree.entries.filter { !$0.isConflict && $0.staged != "." && $0.staged != "?" }),
                ("changes", String(localized: "CHANGES", table: "Sidebar"), false,
                    worktree.entries.filter { !$0.isConflict && $0.unstaged != "." })
            ]
            for section in sections where !section.entries.isEmpty {
                let parentID = key.prefix + commit.id
                rows.append(GraphRow(id: parentID + "\u{0}section\u{0}" + section.name,
                    commitIndex: index, content: .section(label: section.label, count: section.entries.count)))
                func displayRow(_ entry: GitStatusModel.Entry) -> TreeDisplayModel.Row {
                    .init(name: entry.fileName, path: entry.path, isDirectory: false,
                          status: .init(RecentCommitsView.worktreeDisplayStatus(entry, staged: section.staged)))
                }
                if key.mode == .tree {
                    let sectionKey = "worktree:" + worktree.path + ":" + section.name
                    let projection = worktreeRows(
                        section.entries, section: sectionKey, collapsed: key.collapsed, row: displayRow
                    )
                    var parents: [(path: String, id: String)] = []
                    for node in projection.nodes {
                    if Task.isCancelled { return }
                        while let last = parents.last, !node.path.hasPrefix(last.path + "/") {
                            parents.removeLast()
                        }
                        let parent = parents.last?.id ?? parentID
                        if node.isDirectory {
                            let rowID = Self.folderID(parentID, section: section.name, path: node.path)
                            rows.append(GraphRow(id: rowID, commitIndex: index, parent: parent,
                                content: .folder(node, key: sectionKey + ":" + node.path)))
                            parents.append((node.path, rowID))
                        } else if let entry = projection.byPath[node.path] {
                            rows.append(GraphRow(
                                id: GraphRow.worktreeID(parentID, section: section.name, path: entry.path),
                                commitIndex: index, parent: parent,
                                content: .worktreeFile(worktree, entry, row: node, section: section.name,
                                                      staged: section.staged, showDirectory: false)))
                        }
                    }
                } else {
                    for entry in section.entries {
                        if Task.isCancelled { return }
                        rows.append(GraphRow(
                            id: GraphRow.worktreeID(parentID, section: section.name, path: entry.path),
                            commitIndex: index, parent: parentID,
                            content: .worktreeFile(worktree, entry, row: displayRow(entry), section: section.name,
                                                  staged: section.staged, showDirectory: true)))
                    }
                }
            }
        }

    }

    private func commitRowID(_ commit: Commit) -> String {
        "graph:\(selectionScope)\u{0}\(repoRoot)\u{0}\(commit.id)"
    }

    private func historicalFileRowID(_ commit: Commit, file: Commit.FileChange) -> String {
        GraphRow.historyID(commitRowID(commit), file: file)
    }

    private func worktreeFileRowID(
        _ commit: Commit, section: String, path: String
    ) -> String {
        GraphRow.worktreeID(commitRowID(commit), section: section, path: path)
    }

    private var displayKey: GraphDisplayKey {
        GraphDisplayKey(
            scope: selectionScope, repository: repoRoot, commits: commits, stashFiles: stashFilesByOID,
            expanded: expandedCommitIDs,
            collapsed: Set(collapsedFolders.filter { $0.hasPrefix("commit:") || $0.hasPrefix("worktree:") }),
            mode: viewMode
        )
    }

    private var graphDisplay: GraphDisplay {
        displayCache.presentation(for: displayKey)?.display ?? .empty
    }

    private var keyboardRows: [GraphRow] { graphDisplay.navigation }

    @ViewBuilder
    private func graphRow(
        _ row: GraphRow, graph: CommitGraphLayout, gutter: CGFloat, spacing: CGFloat
    ) -> some View {
        let commit = commits[row.commitIndex]
        let layout = graph.rows[row.commitIndex]
        let inset = gutter + 8 * fontScale
        switch row.content {
        case .commit(let expanded):
            commitRow(commit, graph: layout, gutter: gutter, spacing: spacing, expanded: expanded,
                      inHeadHistory: graph.knownHeadHistory.contains(commit.hash))
        case .folder(let node, let key):
            TreeFolderRow(
                row: node, scale: fontScale, leadingInset: inset,
                focusRing: isFocusedRow(row.id), isSelected: selection.ids.contains(row.id),
                listActive: listFocused
            ) {
                if !selectRow(row.id) { toggleFolder(key) }
            }
            .background { fileRails(layout.bottomRails, spacing: spacing) }
        case .historicalFile(let file, let node, let showDirectory):
            changedFile(file, row: node, in: commit, showDirectory: showDirectory, inset: inset)
                .background { fileRails(layout.bottomRails, spacing: spacing) }
        case .worktreeFile(let worktree, let entry, let node, let section, let staged, let showDirectory):
            worktreeFile(entry, row: node, staged: staged, section: section, worktree: worktree,
                         commit: commit, inset: inset, showDirectory: showDirectory)
                .background { fileRails(layout.bottomRails, spacing: spacing) }
        case .section(let label, let count):
            TreeRowSurface(depth: 0, scale: fontScale, hoverEnabled: false, leadingInset: inset) { _, layout in
                HStack {
                    Text(verbatim: label)
                        .font(.system(size: 9 * fontScale, weight: .semibold))
                        .foregroundStyle(graphSecondaryText)
                    Spacer()
                    Text(count, format: .number)
                        .font(.system(size: 9 * fontScale))
                        .foregroundStyle(graphTertiaryText)
                }
                .modifier(layout)
            }
            .background { fileRails(layout.bottomRails, spacing: spacing) }
        case .placeholder(let message, let secondary):
            TreeRowSurface(depth: 0, scale: fontScale, hoverEnabled: false, leadingInset: inset) { _, layout in
                Text(verbatim: message)
                    .font(.system(size: 9.5 * fontScale))
                    .foregroundStyle(secondary ? graphSecondaryText : graphTertiaryText)
                    .modifier(layout)
            }
            .background { fileRails(layout.bottomRails, spacing: spacing) }
        }
    }

    private var listFocused: Bool {
        keyboardFocused && isKeyboardActive && controlActiveState == .key
    }

    private func isFocusedRow(_ id: String) -> Bool {
        focusedRowID == id && listFocused
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

    private var commitParents: [String: [String]] {
        Dictionary(uniqueKeysWithValues: commits.filter {
            $0.stash == nil && $0.worktree == nil
        }.map { ($0.hash, $0.parentHashes) })
    }

    /// Modifier selection does not expand commits, directories, or open a Diff.
    /// Shift uses the rendered commit order, never the HEAD ancestry.
    @discardableResult
    private func selectRow(_ id: String, commit: Bool = false) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let extending = flags.contains(.shift)
        let toggling = flags.contains(.command) && !extending
        let visible = commit ? commits.filter {
            $0.stash == nil && $0.worktree == nil
        }.map(commitRowID) : graphDisplay.navigationIDs
        selection.select(id, visible: visible, extending: extending, toggling: toggling,
                         fallbackAnchor: focusedRowID)
        focusRow(id)
        return extending || toggling
    }

    /// Reveal the row and, during keyboard navigation, its next neighbor in
    /// the direction of travel. The native viewport decides the minimum scroll.
    private func revealKeyboardRow(_ id: String, direction: Int = 0) {
        let display = graphDisplay
        guard isKeyboardActive, let view = keyboardOwner.view,
              view.window?.firstResponder === view,
              let scroll = view.enclosingScrollView, let document = scroll.documentView,
              let position = display.positions[id] else { return }
        let detailHeight = TreeRowStyle.rowHeight(fontScale)
        let commitHeight = Self.commitRowHeight(fontScale)
        let visible = scroll.documentVisibleRect
        // The keyboard host fills the Graph, not the Changes sections above it.
        let top = view.convert(NSPoint(x: view.bounds.minX,
                                      y: view.isFlipped ? view.bounds.minY : view.bounds.maxY),
                               to: document)
        func rect(for position: GraphDisplay.Position) -> NSRect {
            let offset = CGFloat(position.index - position.precedingCommits) * detailHeight
                + CGFloat(position.precedingCommits) * commitHeight
            let height = position.isCommit ? commitHeight : detailHeight
            let y = document.isFlipped ? top.y + offset : top.y - offset - height
            return NSRect(x: visible.minX, y: y, width: min(1, visible.width), height: height)
        }
        var target = rect(for: position)
        let neighbor = position.navigationIndex + direction
        if direction != 0, display.navigation.indices.contains(neighbor),
           let adjacent = display.positions[display.navigation[neighbor].id] {
            let pair = target.union(rect(for: adjacent))
            if pair.height <= visible.height { target = pair }
        }
        guard target.minY < visible.minY || target.maxY > visible.maxY else { return }
        document.scrollToVisible(target)
    }

    private func moveKeyboardCursor(to id: String, direction: Int) {
        focusedRowID = id
        revealKeyboardRow(id, direction: direction)
    }

    private func focusRow(_ id: String) {
        focusedRowID = id
        if isKeyboardActive {
            onKeyboardFocused()
            keyboardOwner.focus()
        }
    }

    private func selectContextRow(_ id: String) {
        contextRowID = id
    }

    private func dismissContextRow(_ id: String) {
        guard contextRowID == id else { return }
        contextRowID = nil
    }

    private func contextTarget(for id: String) -> ContextMenuClickTarget {
        ContextMenuClickTarget(
            onContextClick: { selectContextRow(id) },
            onMenuClosed: { dismissContextRow(id) },
            isExpectedMenu: { _ in contextRowID == id }
        )
    }

    private func toggleFolder(_ key: String) {
        if !collapsedFolders.insert(key).inserted {
            collapsedFolders.remove(key)
        }
    }

    private func isRequestedExpanded(_ row: GraphRow) -> Bool {
        switch row.content {
        case .commit: expandedCommitIDs.contains(commits[row.commitIndex].id)
        case .folder(_, let key): !collapsedFolders.contains(key)
        default: false
        }
    }

    private func activate(_ row: GraphRow) {
        let commit = commits[row.commitIndex]
        switch row.content {
        case .commit:
            toggle(commit)
        case .folder(_, let key):
            toggleFolder(key)
        case .historicalFile(let file, _, _):
            openDiff(commit, file)
        case .worktreeFile(let worktree, let entry, _, _, let staged, _):
            openWorktreeDiff(worktree, entry, staged)
        case .section, .placeholder:
            break
        }
    }

    private func handleGraphKey(_ event: NSEvent) -> Bool {
        guard isKeyboardActive, keyboardOwner.view?.window?.firstResponder === keyboardOwner.view,
              event.modifierFlags.intersection([.control, .option]).isEmpty
        else { return false }
        let display = graphDisplay
        let rows = display.navigation
        guard !rows.isEmpty else { return false }
        let current = focusedRowID.flatMap { display.positions[$0]?.navigationIndex }
        if event.modifierFlags.contains(.command) {
            guard let current, event.keyCode == 125 || event.keyCode == 126,
                  case .commit = rows[current].content,
                  let presentation = displayCache.presentation(for: displayKey),
                  let next = Self.navigationTarget(
                    commits: presentation.key.commits, current: presentation.key.commits[rows[current].commitIndex], parent: event.keyCode == 125,
                    alternate: event.modifierFlags.contains(.shift),
                    layout: presentation.layout
                  ) else { return false }
            moveKeyboardCursor(to: commitRowID(next), direction: event.keyCode == 125 ? 1 : -1)
            if expandedCommitIDs.insert(next.id).inserted { loadBinaryStatus(next) }
            return true
        }
        let extending = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 125, 126: // Down / Up: Shift extends the selection, plain arrows move focus only.
            let start = current ?? (event.keyCode == 125 ? -1 : rows.count)
            let direction = event.keyCode == 125 ? 1 : -1
            let next = max(0, min(rows.count - 1, start + direction))
            if extending {
                selection.select(rows[next].id, visible: display.navigationIDs, extending: true,
                                 fallbackAnchor: current.map { rows[$0].id })
            }
            moveKeyboardCursor(to: rows[next].id, direction: direction)
        case 49, 36, 76: // Space / Return / Enter: same action as clicking the current row
            guard !extending, let current else { return false }
            selection.select(rows[current].id, visible: display.navigationIDs)
            activate(rows[current])
        case 124: // Right expands or enters the first visible child
            guard !extending, let current else { return false }
            let row = rows[current]
            if row.isExpandable && !isRequestedExpanded(row) {
                activate(row)
            } else if rows.indices.contains(current + 1), rows[current + 1].parent == row.id {
                moveKeyboardCursor(to: rows[current + 1].id, direction: 1)
            } else { return false }
        case 123: // Left collapses or selects the parent
            guard !extending, let current else { return false }
            let row = rows[current]
            if row.isExpandable && isRequestedExpanded(row) {
                activate(row)
            } else if let parent = row.parent {
                moveKeyboardCursor(to: parent, direction: -1)
            } else { return false }
        case 53:
            guard !extending else { return false }
            selection.clear() // Escape clears selection without changing the keyboard cursor.
        default: return false
        }
        return true
    }

    private func requestMoreIfNeeded(after id: String) {
        guard requestedLastCommit != id else { return }
        if loadMore() { requestedLastCommit = id }
    }

    /// Navigate only real Git commits. Worktree and Stash pseudo nodes never form edges.
    static func navigationTarget(
        commits: [Commit], current: Commit, parent: Bool, alternate: Bool,
        layout: CommitGraphLayout
    ) -> Commit? {
        guard current.stash == nil, current.worktree == nil else { return nil }
        if parent {
            let index = alternate ? 1 : 0
            guard current.parentHashes.indices.contains(index) else { return nil }
            return commits.first {
                $0.stash == nil && $0.worktree == nil && $0.hash == current.parentHashes[index]
            }
        }
        let lane = commits.firstIndex {
            $0.stash == nil && $0.worktree == nil && $0.hash == current.hash
        }.map { layout.rows[$0].node.lane }
        // Preserve the existing history order within each group; only direct
        // children on the current path take priority over other children.
        var sameLane: [Commit] = []
        var otherLanes: [Commit] = []
        for (commit, row) in zip(commits, layout.rows)
            where commit.stash == nil && commit.worktree == nil && commit.parentHashes.contains(current.hash) {
            if row.node.lane == lane { sameLane.append(commit) }
            else { otherLanes.append(commit) }
        }
        return (sameLane + otherLanes).dropFirst(alternate ? 1 : 0).first
    }

    private func selectAndToggle(_ commit: Commit) {
        let isRealCommit = commit.stash == nil && commit.worktree == nil
        if !selectRow(commitRowID(commit), commit: isRealCommit) { toggle(commit) }
    }

    private var selectedHistoryCommits: [Commit] {
        commits.filter {
            $0.stash == nil && $0.worktree == nil && selection.ids.contains(commitRowID($0))
        }
    }

    private func isMultipleSelection(for id: String) -> Bool {
        selection.ids.count > 1 && selection.ids.contains(id)
    }

    private func selectedClipboardText(for ids: Set<String>) -> String {
        keyboardRows.compactMap { row -> String? in
            guard ids.contains(row.id) else { return nil }
            switch row.content {
            case .commit:
                let commit = commits[row.commitIndex]
                return commit.worktree?.path ?? commit.stash?.selector ?? commit.hash
            case .folder(let node, _):
                return node.path
            case .historicalFile(let file, _, _):
                return file.path
            case .worktreeFile(let worktree, let entry, _, _, _, _):
                return worktree.path + "/" + entry.path
            case .section, .placeholder:
                return nil
            }
        }.joined(separator: "\n")
    }

    private func toggle(_ commit: Commit) {
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

    private static func commitRowHeight(_ scale: CGFloat) -> CGFloat {
        max(36, ceil(38 * scale))
    }

    @ViewBuilder
    private func commitRow(
        _ commit: Commit, graph: CommitGraphLayout.Row, gutter: CGFloat,
        spacing: CGFloat, expanded: Bool, inHeadHistory: Bool
    ) -> some View {
        let content = TreeRowSurface(
            depth: 0, scale: fontScale,
            isSelected: selection.ids.contains(commitRowID(commit)),
            listActive: listFocused,
            focusRing: isFocusedRow(commitRowID(commit)),
            contextRing: contextRowID == commitRowID(commit),
            leadingInset: gutter, trailingInset: TreeRowStyle.contentInset,
            showsGuides: false,
            height: Self.commitRowHeight(fontScale)
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
                        Button { selectAndToggle(commit) } label: {
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
                            if commit.worktree == nil {
                                contextTarget(for: commitRowID(commit))
                                    .contextMenu { commitContextMenu(commit) }
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(commit.subject)
                        .accessibilityValue(expanded
                            ? String(localized: "Expanded", table: "Git")
                            : String(localized: "Collapsed", table: "Git"))
                        .accessibilityAddTraits(
                            selection.ids.contains(commitRowID(commit)) ? .isSelected : []
                        )
                        Spacer(minLength: 0)
                    }

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
                        .accessibilityIdentifier("bailey.git.history.copyHash")

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
            .frame(height: Self.commitRowHeight(fontScale))
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
            Button { selectAndToggle(commit) } label: {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 14 * fontScale, height: 14 * fontScale)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(
                x: (8 + CGFloat(graph.node.lane) * spacing - 7) * fontScale,
                y: Self.commitRowHeight(fontScale) / 2 - 7 * fontScale
            )
            .help(Self.nodeHelp(commit, inHeadHistory: inHeadHistory))
            .accessibilityLabel(commit.worktree.map { $0.branch ?? $0.path } ?? commit.shortHash + ": " + commit.subject)
            .accessibilityValue(commit.worktree?.path ?? commit.hash)
        }
        .contentShape(Rectangle())
        .onTapGesture { selectAndToggle(commit) }
        if commit.worktree == nil {
            content
                .background { contextTarget(for: commitRowID(commit)) }
                .contextMenu { commitContextMenu(commit) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func commitContextMenu(_ commit: Commit) -> some View {
        if isMultipleSelection(for: commitRowID(commit)) {
            multipleSelectionMenu()
        } else if let stash = commit.stash {
            stashActions(stash)
        } else if commit.worktree == nil {
            hostedCommitMenu(commit)
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
            Button(String(localized: "Copy Commit Subject", table: "Git")) {
                copy(commit.subject)
            }
        }
    }

    @ViewBuilder
    private func multipleSelectionMenu() -> some View {
        let selected = selectedHistoryCommits
        if selected.count == selection.ids.count {
            let hashes = selected.map(\.hash)
            let allOrdinary = selected.allSatisfy { $0.parentHashes.count <= 1 }
            let parents = commitParents
            let canDrop = !GitStatusModel.historyRewriteTargets(
                selected: hashes, kind: .drop, head: headOID, root: repoRoot,
                worktrees: worktreeLocations, parents: parents
            ).isEmpty
            let canSquash = !GitStatusModel.historyRewriteTargets(
                selected: hashes, kind: .squash, head: headOID, root: repoRoot,
                worktrees: worktreeLocations, parents: parents
            ).isEmpty
            Button(String(localized: "Copy Hashes", table: "Git")) {
                copy(hashes.joined(separator: "\n"))
            }
            Button(String(localized: "Copy Subjects", table: "Git")) {
                copy(selected.map(\.subject).joined(separator: "\n"))
            }
            Button(String(localized: "Copy Summaries", table: "Git")) {
                copy(selected.map { $0.hash + " " + $0.subject }.joined(separator: "\n"))
            }
            Divider()
            ForEach(GitStatusModel.CommitBatchAction.allCases, id: \.self) { action in
                Button(action.title) { commitBatchAction(hashes, action) }
                    .disabled(!canActOnCommit || !allOrdinary || (action == .drop && !canDrop))
            }
            Button(String(localized: "Squash…", table: "Git")) {
                squashAction(hashes)
            }
            .disabled(!canActOnCommit || !canSquash)
        }
    }

    @ViewBuilder
    private func hostedCommitMenu(_ commit: Commit) -> some View {
        let containing = knownRemotesByCommit[commit.hash] ?? []
        let available = remotes.compactMap { remote -> (String, String)? in
            guard containing.contains(remote), let url = remoteURLs[remote],
                  let link = GitHostedRemoteURL(
                      remoteURL: url, hostProviders: hostProviders
                  ), link.commitURL(commit.hash) != nil else { return nil }
            return (remote, link.provider.title)
        }
        if available.count == 1, let (remote, provider) = available.first {
            Button(String(localized: "Open on \(provider)", table: "Git")) {
                openHosted(remote, commit.hash)
            }
            Divider()
        } else if available.count > 1 {
            Menu(String(localized: "Open in Browser", table: "Git")) {
                ForEach(available.indices, id: \.self) { index in
                    let (remote, provider) = available[index]
                    Button("\(provider) · \(remote)") {
                        openHosted(remote, commit.hash)
                    }
                }
            }
            Divider()
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

    nonisolated static func worktreeDisplayStatus(_ entry: GitStatusModel.Entry,
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
        return Button { selectAndToggle(commit) } label: {
            HStack(spacing: 0) {
                Image(systemName: "square.stack")
                    .font(.system(size: Self.badgeFontSize * fontScale))
                    .foregroundStyle(palette.iconColor(colorIndex))
                    .frame(width: Self.badgeIconSize * fontScale,
                           height: Self.badgeHeight * fontScale)
                    .background(palette.color(colorIndex))
                if viewportWidth >= 180 * fontScale {
                    Text(verbatim: label)
                        .font(.system(size: Self.badgeFontSize * fontScale, weight: .medium))
                        .foregroundStyle(graphTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: min(128, max(52, viewportWidth * 0.32)) * fontScale)
                        .padding(.horizontal, Self.badgeHorizontalPadding * fontScale)
                }
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
            if isMultipleSelection(for: commitRowID(commit)) {
                multipleSelectionMenu()
            } else if let head = commit.references.first(where: { $0.kind == .detachedHead }) {
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
    }

    private func stashBadge(
        _ stash: GitStatusModel.Stash, in commit: Commit, colorIndex: Int
    ) -> some View {
        let outline = RoundedRectangle(cornerRadius: 4 * fontScale)
        let palette = graphPalette
        return Button { selectAndToggle(commit) } label: {
            HStack(spacing: 0) {
                Image(systemName: "archivebox")
                    .font(.system(size: Self.badgeFontSize * fontScale))
                    .foregroundStyle(palette.iconColor(colorIndex))
                    .frame(width: Self.badgeIconSize * fontScale,
                           height: Self.badgeHeight * fontScale)
                    .background(palette.color(colorIndex))
                if viewportWidth >= 180 * fontScale {
                    Text(verbatim: stash.selector)
                        .font(.system(size: Self.badgeFontSize * fontScale, weight: .medium))
                        .foregroundStyle(graphTextColor)
                        .padding(.horizontal, Self.badgeHorizontalPadding * fontScale)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(height: Self.badgeHeight * fontScale)
            .background(graphTextColor.opacity(0.06))
            .clipShape(outline)
            .overlay(outline.stroke(graphTextColor.opacity(0.35),
                                    lineWidth: 1 * fontScale))
        }
        .buttonStyle(.plain)
        .help(stash.selector + ": " + stash.message)
        .accessibilityLabel(stash.selector)
        .accessibilityAddTraits(
            selection.ids.contains(commitRowID(commit)) ? .isSelected : []
        )
        .background {
            contextTarget(for: commitRowID(commit))
        }
        .contextMenu {
            if isMultipleSelection(for: commitRowID(commit)) {
                multipleSelectionMenu()
            } else {
                stashActions(stash)
            }
        }
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
                let referencesMenu = Menu {
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
                if isMultipleSelection(for: commitRowID(commit)) {
                    referencesMenu
                        .background { contextTarget(for: commitRowID(commit)) }
                        .contextMenu { multipleSelectionMenu() }
                } else {
                    referencesMenu
                }
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
        return Button { selectAndToggle(commit) } label: {
            HStack(spacing: 0) {
                Image(systemName: reference.kind == .tag ? "tag.fill"
                      : reference.kind == .detachedHead ? "circle"
                      : "arrow.triangle.branch")
                    .font(.system(size: Self.badgeFontSize * fontScale))
                    .foregroundStyle(palette.iconColor(colorIndex))
                    .frame(width: Self.badgeIconSize * fontScale,
                           height: Self.badgeHeight * fontScale)
                    .background(palette.color(colorIndex))
                if viewportWidth >= 180 * fontScale {
                    Text(verbatim: reference.name)
                        .font(.system(size: Self.badgeFontSize * fontScale,
                                      weight: current ? .semibold : .medium))
                        .foregroundStyle(graphTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: min(88, max(42, viewportWidth * 0.22)) * fontScale)
                        .padding(.horizontal, Self.badgeHorizontalPadding * fontScale)
                }
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
        .contextMenu {
            if isMultipleSelection(for: commitRowID(commit)) {
                multipleSelectionMenu()
            } else {
                referenceActions(reference, commit: commit)
            }
        }
    }

    @ViewBuilder
    private func referenceActions(_ reference: Reference, commit: Commit) -> some View {
        hostedCommitMenu(commit)
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
                    switchBranch(reference.name, commit.hash)
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
                Button(String(localized: "Merge into Worktree…", table: "Git")) {
                    branchAction(reference, commit, .merge)
                }
                .disabled(!canActOnCommit)
                Button(String(localized: "Rebase Worktree onto This Branch…", table: "Git")) {
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
            Button(String(localized: "Merge into Worktree…", table: "Git")) {
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
            isSelected: selection.ids.contains(id), listActive: listFocused,
            focusRing: isFocusedRow(id), contextRing: contextRowID == id,
            leadingInset: inset,
            accessibilityHint: staged
                ? String(localized: "Open Staged Diff", table: "Git")
                : String(localized: "Open Working Changes", table: "Git"),
            open: {
                if !selectRow(id) { openWorktreeDiff(worktree, entry, staged) }
            }
        ) { _ in EmptyView() }
    }

    @ViewBuilder
    private func changedFile(
        _ file: Commit.FileChange, row: TreeDisplayModel.Row,
        in commit: Commit, showDirectory: Bool, inset: CGFloat
    ) -> some View {
        let id = historicalFileRowID(commit, file: file)
        let content = TreeFileRow(
            row: row, scale: fontScale,
            directory: showDirectory ? file.directory : nil,
            displayed: isDisplayedHistoryFile(file, in: commit),
            isSelected: selection.ids.contains(id),
            listActive: listFocused,
            focusRing: isFocusedRow(id),
            contextRing: contextRowID == id,
            leadingInset: inset,
            accessibilityHint: String(localized: "Opens changes", table: "Sidebar"),
            accessibilityID: "bailey.git.history.file",
            open: {
                if !selectRow(id) { openDiff(commit, file) }
            }
        ) { _ in EmptyView() }
        if file.status != "D" && commit.stash == nil {
            content
                .background { contextTarget(for: id) }
                .contextMenu {
                    if !isMultipleSelection(for: id) {
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
                }
        } else {
            content
        }
    }

    private nonisolated static func displayRow(_ file: Commit.FileChange) -> TreeDisplayModel.Row {
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

    private static var palettes: [GhosttyThemeDefinition: Self] = [:]

    static func resolved(theme: GhosttyThemeDefinition) -> Self {
        if let palette = palettes[theme] { return palette }
        let palette = Self(theme: theme)
        palettes[theme] = palette
        return palette
    }

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
        let palette = GitGraphPalette.resolved(theme: theme)
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
