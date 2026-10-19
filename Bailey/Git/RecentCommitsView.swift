import AppKit
import SwiftUI

struct GitGraphReferenceGroup: Identifiable {
    typealias Reference = GitStatusModel.RecentCommit.Reference

    let primary: Reference
    let remotes: [Reference]

    var id: String { primary.id }
    var references: [Reference] { [primary] + remotes }

    func remoteTitle(_ reference: Reference) -> String {
        String(reference.name.dropLast(primary.name.count + 1))
    }

    static func grouped(_ references: [Reference], remotes: [String]) -> [Self] {
        let ordered = references.filter { $0.kind == .currentBranch }
            + references.filter { $0.kind != .currentBranch }
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
    @Binding private var expandedCommitIDs: Set<String>
    @Binding private var collapsedFolders: Set<String>
    @State private var requestedLastCommit: String?
    @State private var viewportWidth: CGFloat = 0

    let commits: [Commit]
    let remotes: [String]
    let stashFilesByOID: [String: GitStatusModel.StashFilesState]
    let repoRoot: String
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
        createWorktree: @escaping (Reference, Commit) -> Void = { _, _ in }
    ) {
        self.commits = commits
        self.remotes = remotes
        self.stashFilesByOID = stashFilesByOID
        self.repoRoot = repoRoot
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
                    if expanded {
                        if let worktree = commit.worktree {
                            worktreeFiles(worktree, rails: graph.rows[index].bottomRails,
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
        .onChange(of: commits.last(where: { $0.stash == nil })?.id) {
            requestedLastCommit = nil
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) {
            viewportWidth = $0
        }
    }

    private func requestMoreIfNeeded(after id: String) {
        guard hasMoreCommits, !isLoadingMore, requestedLastCommit != id else { return }
        if loadMore() { requestedLastCommit = id }
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

    private func commitRow(
        _ commit: Commit, graph: CommitGraphLayout.Row, gutter: CGFloat,
        spacing: CGFloat, expanded: Bool, inHeadHistory: Bool
    ) -> some View {
        TreeRowSurface(
            depth: 0, scale: fontScale, selected: expanded,
            leadingInset: gutter, trailingInset: TreeRowStyle.contentInset,
            showsGuides: false,
            height: max(36, ceil(38 * fontScale))
        ) { hovering, layout in
            VStack(alignment: .leading, spacing: 2 * fontScale) {
                HStack(spacing: 4 * fontScale) {
                    if let worktree = commit.worktree {
                        worktreeBadge(worktree, in: commit, gutter: gutter)
                            .layoutPriority(1)
                    } else if let stash = commit.stash {
                        stashBadge(stash, in: commit, colorIndex: graph.node.color)
                            .layoutPriority(1)
                    } else {
                        if !commit.checkedOutWorktrees.isEmpty {
                            checkedOutWorktreeStrip(commit)
                                .layoutPriority(1)
                        }
                        if !commit.references.isEmpty {
                            referenceStrip(commit.references, commit: commit,
                                           colorIndex: graph.node.color)
                                .layoutPriority(1)
                        }
                    }
                    Button { toggle(commit) } label: {
                        if commit.worktree != nil {
                            Text(verbatim: commit.subject)
                                .font(.system(size: 12 * fontScale))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(minWidth: 64 * fontScale,
                                       maxWidth: .infinity, alignment: .leading)
                        } else {
                            ScrollView(.horizontal) {
                                Text(verbatim: commit.subject)
                                    .font(.system(size: 12.5 * fontScale))
                                    .foregroundStyle(
                                        commit.stash == nil && commit.parentHashes.count > 1
                                            && !hovering && !expanded
                                            ? Color.primary.opacity(0.55) : Color.primary
                                    )
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .scrollIndicators(.hidden)
                            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                            .frame(minWidth: 64 * fontScale,
                                   maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(-1)
                    .help(commit.subject)
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
                            worktree.path, among: commits.compactMap { $0.worktree?.path }
                        ))
                            .font(.system(size: 10 * fontScale, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(worktree.path)
                            .accessibilityLabel(worktree.path)
                    } else {
                    Button { copy(commit.hash) } label: {
                        Text(verbatim: commit.shortHash)
                            .font(.system(size: 10.5 * fontScale, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .help(commit.hash)
                    .accessibilityLabel(String(localized: "Copy Commit Hash", table: "Git"))

                    Text(verbatim: commit.author)
                        .font(.system(size: 11 * fontScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)

                    Spacer(minLength: 3)

                    Text(verbatim: commit.relativeDate)
                        .font(.system(size: 10.5 * fontScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .modifier(layout)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: 0.5)
                    .padding(.leading, gutter)
                    .allowsHitTesting(false)
            }
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
        .contextMenu {
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
    }

    static func worktreeBadgeWidth(_ branch: String, viewportWidth: CGFloat,
                                   gutter: CGFloat, scale: CGFloat) -> CGFloat {
        let nameWidth = ceil((branch as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: badgeFontSize * scale, weight: .medium)
        ]).width)
        let icon = badgeIconSize * scale
        let available = min(104 * scale, max(icon, viewportWidth - gutter - 88 * scale))
        let offered = min(nameWidth + (badgeIconSize + 2 * badgeHorizontalPadding) * scale,
                          available)
        return offered >= 36 * scale ? offered : icon
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

    static func worktreeDisplayStatus(_ entry: GitStatusModel.Entry,
                                      staged: Bool) -> Character {
        entry.isConflict ? "U" : staged ? entry.staged : entry.unstaged
    }

    private func worktreeBadge(
        _ worktree: GitStatusModel.WorktreeChanges, in commit: Commit, gutter: CGFloat
    ) -> some View {
        let branch = worktree.branch ?? String(localized: "Detached HEAD", table: "Git")
        let badgeWidth = Self.worktreeBadgeWidth(
            branch, viewportWidth: viewportWidth, gutter: gutter, scale: fontScale
        )
        let showBranch = badgeWidth > Self.badgeIconSize * fontScale
        let outline = RoundedRectangle(cornerRadius: 4 * fontScale)
        return Button { toggle(commit) } label: {
            HStack(spacing: 0) {
                Image(systemName: "square.stack")
                    .font(.system(size: Self.badgeFontSize * fontScale))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: Self.badgeIconSize * fontScale,
                           height: Self.badgeHeight * fontScale)
                    .background(Color.primary.opacity(0.09))
                if showBranch {
                    Text(verbatim: branch)
                        .font(.system(size: Self.badgeFontSize * fontScale, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: badgeWidth -
                               (Self.badgeIconSize + 2 * Self.badgeHorizontalPadding) * fontScale,
                               alignment: .leading)
                        .padding(.horizontal, Self.badgeHorizontalPadding * fontScale)
                }
            }
            .frame(width: badgeWidth, height: Self.badgeHeight * fontScale,
                   alignment: .leading)
            .background(Color.primary.opacity(0.04))
            .clipShape(outline)
            .overlay(outline.stroke(Color.primary.opacity(0.22),
                                    lineWidth: 1 * fontScale))
        }
        .buttonStyle(.plain)
        .help(branch + "\n" + worktree.path)
        .accessibilityLabel(branch + ", " + worktree.path)
    }

    private func checkedOutWorktreeStrip(_ commit: Commit) -> some View {
        let locations = commit.checkedOutWorktrees
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 3 * fontScale) {
                ForEach(locations, id: \.path) { location in
                    checkedOutWorktreeBadge(location, in: commit)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            if locations.count > 1 {
                HStack(spacing: 3 * fontScale) {
                    checkedOutWorktreeBadge(locations[0], in: commit)
                    Menu {
                        ForEach(locations.dropFirst(), id: \.path) { location in
                            Menu(Self.worktreeDisplayPath(location.path, among: locations.map(\.path))) {
                                worktreeActions(location)
                            }
                        }
                    } label: {
                        Text("+\(locations.count - 1)")
                            .font(.system(size: Self.badgeFontSize * fontScale, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func checkedOutWorktreeBadge(
        _ location: GitStatusModel.WorktreeLocation, in commit: Commit
    ) -> some View {
        let allPaths = commits.flatMap { $0.checkedOutWorktrees.map(\.path) }
        let title = Self.worktreeDisplayPath(location.path, among: allPaths)
        let outline = RoundedRectangle(cornerRadius: 4 * fontScale)
        return Button { toggle(commit) } label: {
            HStack(spacing: 0) {
                Image(systemName: "square.stack")
                    .font(.system(size: Self.badgeFontSize * fontScale))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.badgeIconSize * fontScale,
                           height: Self.badgeHeight * fontScale)
                    .background(Color.primary.opacity(0.09))
                Text(verbatim: title)
                    .font(.system(size: Self.badgeFontSize * fontScale, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 82 * fontScale)
                    .padding(.horizontal, Self.badgeHorizontalPadding * fontScale)
            }
            .frame(height: Self.badgeHeight * fontScale)
            .background(Color.primary.opacity(0.06))
            .clipShape(outline)
            .overlay(outline.stroke(Color.primary.opacity(0.35), lineWidth: fontScale))
        }
        .buttonStyle(.plain)
        .help((location.branch ?? String(localized: "Detached HEAD", table: "Git"))
              + "\n" + location.path)
        .accessibilityLabel(String(localized: "Worktree", table: "Git") + ": " + location.path)
        .contextMenu { worktreeActions(location) }
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
        return Button { toggle(commit) } label: {
            HStack(spacing: 0) {
                Image(systemName: "archivebox")
                    .font(.system(size: Self.badgeFontSize * fontScale))
                    .foregroundStyle(GitGraphPalette.iconColor(colorIndex))
                    .frame(width: Self.badgeIconSize * fontScale,
                           height: Self.badgeHeight * fontScale)
                    .background(GitGraphPalette.color(colorIndex))
                Text(verbatim: stash.selector)
                    .font(.system(size: Self.badgeFontSize * fontScale, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, Self.badgeHorizontalPadding * fontScale)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: Self.badgeHeight * fontScale)
            .background(Color.primary.opacity(0.06))
            .clipShape(outline)
            .overlay(outline.stroke(Color.primary.opacity(0.35),
                                    lineWidth: 1 * fontScale))
        }
        .buttonStyle(.plain)
        .help(stash.selector + ": " + stash.message)
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
        let groups = GitGraphReferenceGroup.grouped(references, remotes: remotes)
        return ViewThatFits(in: .horizontal) {
            referenceGroup(groups, shown: groups.count, commit: commit, colorIndex: colorIndex)
            if groups.count > 2 {
                referenceGroup(groups, shown: 2, commit: commit, colorIndex: colorIndex)
            }
            if groups.count > 1 {
                referenceGroup(groups, shown: 1, commit: commit, colorIndex: colorIndex)
            }
            if !groups.isEmpty && !groups[0].remotes.isEmpty {
                referenceGroup(groups, shown: 1, commit: commit,
                               colorIndex: colorIndex, compactFirst: true)
            }
            referenceGroup(groups, shown: 0, commit: commit, colorIndex: colorIndex)
        }
    }

    private func referenceGroup(
        _ groups: [GitGraphReferenceGroup], shown: Int, commit: Commit, colorIndex: Int,
        compactFirst: Bool = false
    ) -> some View {
        let shownGroups = Array(groups.prefix(shown)).enumerated().map { index, group in
            compactFirst && index == 0
                ? GitGraphReferenceGroup(primary: group.primary, remotes: []) : group
        }
        let hidden = (compactFirst ? groups.first?.remotes ?? [] : [])
            + groups.dropFirst(shown).flatMap(\.references)
        return HStack(spacing: 3 * fontScale) {
            ForEach(shownGroups) { group in
                referenceBadge(group, commit: commit, colorIndex: colorIndex)
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
                        .foregroundStyle(.secondary)
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
        _ group: GitGraphReferenceGroup, commit: Commit, colorIndex: Int
    ) -> some View {
        let current = group.primary.kind == .currentBranch
        let color = GitGraphPalette.color(colorIndex)
        let outline = RoundedRectangle(cornerRadius: 4 * fontScale)
        return HStack(spacing: 0) {
            referenceSegment(group.primary, title: group.primary.name,
                             colorIndex: colorIndex, commit: commit, isRemoteSuffix: false)
            ForEach(group.remotes) { remote in
                referenceSegment(remote, title: group.remoteTitle(remote),
                                 colorIndex: colorIndex, commit: commit, isRemoteSuffix: true)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(Color.primary.opacity(0.06))
        .clipShape(outline)
        .overlay(outline.stroke(current ? color : Color.primary.opacity(0.35),
                                lineWidth: 1 * fontScale))
    }

    private func referenceSegment(
        _ reference: Reference, title: String, colorIndex: Int,
        commit: Commit, isRemoteSuffix: Bool
    ) -> some View {
        let current = reference.kind == .currentBranch
        let titleFont: Font = isRemoteSuffix
            ? .system(size: Self.badgeFontSize * fontScale).italic()
            : .system(size: Self.badgeFontSize * fontScale,
                      weight: current ? .semibold : .medium)
        return Button { toggle(commit) } label: {
            HStack(spacing: 0) {
                if isRemoteSuffix {
                    Rectangle()
                        .fill(Color.primary.opacity(0.3))
                        .frame(width: 1 * fontScale, height: 10 * fontScale)
                } else {
                    Image(systemName: reference.kind == .tag ? "tag.fill"
                          : reference.kind == .detachedHead ? "circle"
                          : "arrow.triangle.branch")
                        .font(.system(size: Self.badgeFontSize * fontScale))
                        .foregroundStyle(GitGraphPalette.iconColor(colorIndex))
                        .frame(width: Self.badgeIconSize * fontScale,
                               height: Self.badgeHeight * fontScale)
                        .background(GitGraphPalette.color(colorIndex))
                }
                Text(verbatim: title)
                    .font(titleFont)
                    .foregroundStyle(isRemoteSuffix ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 112 * fontScale)
                    .padding(.horizontal, Self.badgeHorizontalPadding * fontScale)
            }
            .frame(height: Self.badgeHeight * fontScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(reference.name)
        .accessibilityLabel(reference.name)
        .contextMenu {
            referenceActions(reference, commit: commit)
        }
    }

    @ViewBuilder
    private func referenceActions(_ reference: Reference, commit: Commit) -> some View {
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
        _ worktree: GitStatusModel.WorktreeChanges, rails: [CommitGraphLayout.Rail],
        gutter: CGFloat, spacing: CGFloat
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
                section: "merge", staged: false, worktree: worktree,
                rails: rails, gutter: gutter, spacing: spacing
            )
        }
        if !staged.isEmpty {
            worktreeSection(
                staged, label: String(localized: "STAGED CHANGES", table: "Sidebar"),
                section: "staged", staged: true, worktree: worktree,
                rails: rails, gutter: gutter, spacing: spacing
            )
        }
        if !changed.isEmpty {
            worktreeSection(
                changed, label: String(localized: "CHANGES", table: "Sidebar"),
                section: "changes", staged: false, worktree: worktree,
                rails: rails, gutter: gutter, spacing: spacing
            )
        }
    }

    @ViewBuilder
    private func worktreeSection(
        _ entries: [GitStatusModel.Entry], label: String, section: String, staged: Bool,
        worktree: GitStatusModel.WorktreeChanges, rails: [CommitGraphLayout.Rail],
        gutter: CGFloat, spacing: CGFloat
    ) -> some View {
        let inset = gutter + 8 * fontScale
        TreeRowSurface(
            depth: 0, scale: fontScale, hoverEnabled: false, leadingInset: inset
        ) { _, layout in
            HStack {
                Text(verbatim: label)
                    .font(.system(size: 9 * fontScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entries.count, format: .number)
                    .font(.system(size: 9 * fontScale))
                    .foregroundStyle(.tertiary)
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
                        row: node, scale: fontScale, leadingInset: inset
                    ) {
                        let folder = key + ":" + node.path
                        if !collapsedFolders.insert(folder).inserted {
                            collapsedFolders.remove(folder)
                        }
                    }
                    .background { fileRails(rails, spacing: spacing) }
                    .contextMenu {
                        Button(String(localized: "Copy Absolute Path", table: "Git")) {
                            copy((worktree.path as NSString).appendingPathComponent(node.path))
                        }
                    }
                } else if let entry = byPath[node.path] {
                    worktreeFile(entry, row: node, staged: staged,
                                 worktree: worktree, inset: inset, showDirectory: false)
                        .background { fileRails(rails, spacing: spacing) }
                }
            }
        } else {
            ForEach(entries, id: \.id) { entry in
                let node = TreeDisplayModel.Row(
                    name: entry.fileName, path: entry.path, isDirectory: false,
                    status: .init(Self.worktreeDisplayStatus(entry, staged: staged))
                )
                worktreeFile(entry, row: node, staged: staged,
                             worktree: worktree, inset: inset, showDirectory: true)
                    .background { fileRails(rails, spacing: spacing) }
            }
        }
    }

    private func worktreeFile(
        _ entry: GitStatusModel.Entry, row: TreeDisplayModel.Row, staged: Bool,
        worktree: GitStatusModel.WorktreeChanges, inset: CGFloat, showDirectory: Bool
    ) -> some View {
        TreeFileRow(
            row: row, scale: fontScale,
            directory: showDirectory ? entry.directory : nil,
            leadingInset: inset,
            accessibilityHint: staged
                ? String(localized: "Open Staged Diff", table: "Git")
                : String(localized: "Open Working Changes", table: "Git"),
            open: { openWorktreeDiff(worktree, entry, staged) }
        ) { _ in EmptyView() }
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
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.tertiary)
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
                    TreeFolderRow(row: node, scale: fontScale, leadingInset: filesInset) {
                        let key = section + ":" + node.path
                        if !collapsedFolders.insert(key).inserted {
                            collapsedFolders.remove(key)
                        }
                    }
                    .background { fileRails(rails, spacing: spacing) }
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
            leadingInset: inset,
            accessibilityHint: String(localized: "Opens changes", table: "Sidebar"),
            open: { openDiff(commit, file) }
        ) { _ in EmptyView() }
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
            Button(String(localized: "Copy Relative Path", table: "Git")) { copy(file.path) }
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

enum GitGraphPalette {
    static let colors: [NSColor] = [
        rgb(0, 133, 217), rgb(217, 0, 143), rgb(0, 217, 10), rgb(217, 133, 0),
        rgb(163, 0, 217), rgb(255, 0, 0), rgb(0, 217, 204), rgb(225, 56, 232),
        rgb(133, 217, 0), rgb(220, 91, 35), rgb(111, 36, 214), rgb(255, 204, 0),
    ]

    static let iconInks: [NSColor] = colors.map { color in
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
        return luminance >= 0.18 ? .black : .white
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }

    static func color(_ index: Int) -> Color {
        if index == CommitGraphLayout.unconnectedWorktreeColor {
            return Color(nsColor: .secondaryLabelColor)
        }
        return Color(nsColor: colors[index % colors.count])
    }

    static func iconColor(_ index: Int) -> Color {
        Color(nsColor: iconInks[index % iconInks.count])
    }
}

struct CommitGraphRails: View {
    private let themeChanges = Theme.changes
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
        Canvas { context, size in
            let middle = size.height / 2
            let backdrop = Color(nsColor: Theme.sidebar)
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
                    context.stroke(path, with: .color(GitGraphPalette.color(linkColor)),
                                   style: stroke)
                }
                let radius = 4 * fontScale
                let x = laneX(row.node.lane)
                let node = Path(ellipseIn: CGRect(
                    x: x - radius, y: middle - radius, width: 2 * radius, height: 2 * radius
                ))
                let nodeColor = GitGraphPalette.color(row.node.color)
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
                    context.stroke(path, with: .color(GitGraphPalette.color(rail.color)),
                                   style: stroke)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
