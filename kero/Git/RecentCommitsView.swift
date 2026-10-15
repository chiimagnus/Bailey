import AppKit
import SwiftUI

/// Commit history shares the file-tree rows while drawing its own real Git DAG.
struct RecentCommitsView: View {
    typealias Commit = GitStatusModel.RecentCommit
    typealias Reference = Commit.Reference

    enum BranchAction { case rename, delete, push, merge, rebase, archive }
    enum RemoteAction { case checkout, fetch, merge, pull, delete, archive }
    enum TagAction { case details, delete, push, archive }
    enum HistoricalFileAction { case viewRevision, compareWorktree, openWorkingFile, resetFile }

    private let themeChanges = Theme.changes
    @Binding private var expandedCommitIDs: Set<String>
    @Binding private var collapsedFolders: Set<String>
    @State private var requestedLastCommit: String?
    @State private var viewportWidth: CGFloat = 0

    let commits: [Commit]
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

    init(
        commits: [Commit],
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
        stashAction: @escaping (GitStatusModel.Stash, GitStatusModel.StashAction) -> Void = { _, _ in }
    ) {
        self.commits = commits
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
                              spacing: spacing, expanded: expanded)
                    if expanded {
                        if let stash = commit.stash {
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
        } else {
            loadBinaryStatus(commit)
        }
    }

    private func commitRow(
        _ commit: Commit, graph: CommitGraphLayout.Row, gutter: CGFloat,
        spacing: CGFloat, expanded: Bool
    ) -> some View {
        TreeRowSurface(
            depth: 0, scale: fontScale, selected: expanded,
            leadingInset: gutter, trailingInset: TreeRowStyle.contentInset,
            showsGuides: false,
            height: max(36, ceil(38 * fontScale))
        ) { _, layout in
            VStack(alignment: .leading, spacing: 2 * fontScale) {
                HStack(spacing: 4 * fontScale) {
                    Button { toggle(commit) } label: {
                        ScrollView(.horizontal) {
                            Text(verbatim: commit.subject)
                                .font(.system(size: 12.5 * fontScale))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                        .frame(minWidth: 64 * fontScale, maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(-1)
                    .help(commit.subject)
                    .accessibilityLabel(commit.subject)
                    .accessibilityValue(expanded
                        ? String(localized: "Expanded", table: "Git")
                        : String(localized: "Collapsed", table: "Git"))
                    if let stash = commit.stash {
                        stashBadge(stash, in: commit)
                            .layoutPriority(1)
                    } else if !commit.references.isEmpty {
                        referenceStrip(commit.references, commit: commit)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 6 * fontScale) {
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
                        .font(.system(size: 11 * fontScale, design: .serif).italic())
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
            CommitGraphRails(row: graph, fontScale: fontScale, laneSpacing: spacing)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(commit) }
        .contextMenu {
            if let stash = commit.stash {
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

    private func stashBadge(_ stash: GitStatusModel.Stash, in commit: Commit) -> some View {
        Button { toggle(commit) } label: {
            HStack(spacing: 3) {
                Image(systemName: "archivebox")
                    .font(.system(size: 9 * fontScale))
                Text(verbatim: stash.selector)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 10 * fontScale, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 7 * fontScale)
            .padding(.vertical, 3 * fontScale)
            .background(Capsule().fill(Color(nsColor: .systemGray)))
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

    private func referenceStrip(_ references: [Reference], commit: Commit) -> some View {
        ViewThatFits(in: .horizontal) {
            referenceGroup(references, shown: references.count, commit: commit)
            if references.count > 2 {
                referenceGroup(references, shown: 2, commit: commit)
            }
            if references.count > 1 {
                referenceGroup(references, shown: 1, commit: commit)
            }
            referenceGroup(references, shown: 0, commit: commit)
        }
    }

    private func referenceGroup(_ references: [Reference], shown: Int, commit: Commit) -> some View {
        HStack(spacing: 4 * fontScale) {
            ForEach(Array(references.prefix(shown))) { reference in
                referenceBadge(reference, commit: commit)
            }
            if shown < references.count {
                Menu {
                    ForEach(Array(references.dropFirst(shown))) { reference in
                        Menu(reference.name) {
                            referenceActions(reference, commit: commit)
                        }
                    }
                } label: {
                    Text("+\(references.count - shown)")
                        .font(.system(size: 10 * fontScale, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(references.dropFirst(shown).map(\.name).joined(separator: ", "))
                .accessibilityLabel(references.dropFirst(shown).map(\.name).joined(separator: ", "))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func referenceBadge(_ reference: Reference, commit: Commit) -> some View {
        let background: Color = {
            switch reference.kind {
            case .currentBranch: Color(nsColor: .systemBlue)
            case .localBranch, .remoteBranch: Color(nsColor: .systemIndigo)
            case .tag: Color(nsColor: .systemBrown)
            case .detachedHead: Color(nsColor: .systemGray)
            }
        }()
        let label = HStack(spacing: 3) {
            if reference.kind == .tag {
                Image(systemName: "tag")
                    .font(.system(size: 9 * fontScale))
            }
            Text(verbatim: reference.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 10 * fontScale, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 7 * fontScale)
        .padding(.vertical, 3 * fontScale)
        .frame(maxWidth: 142 * fontScale)
        .background(Capsule().fill(background))
        .help(reference.name)

        Button {
            if reference.kind == .tag {
                expandedCommitIDs.insert(commit.id)
            } else {
                copy(reference.name)
            }
        } label: { label }
            .buttonStyle(.plain)
            .contextMenu {
                referenceActions(reference, commit: commit)
            }
    }

    @ViewBuilder
    private func referenceActions(_ reference: Reference, commit: Commit) -> some View {
        switch reference.kind {
        case .currentBranch, .localBranch:
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

private struct CommitGraphRails: View {
    private let themeChanges = Theme.changes
    private static let firstLaneX: CGFloat = 8

    static func spacing(lanes: Int, viewportWidth: CGFloat, scale: CGFloat) -> CGFloat {
        guard lanes > 1, viewportWidth > 0 else { return 9 }
        let maxGutter = viewportWidth * 0.34 / scale
        return min(9, max(1, (maxGutter - firstLaneX - 8) / CGFloat(lanes - 1)))
    }

    static func gutter(lanes: Int, spacing: CGFloat, scale: CGFloat) -> CGFloat {
        (firstLaneX + CGFloat(max(0, lanes - 1)) * spacing + 8) * scale
    }

    var row: CommitGraphLayout.Row? = nil
    var bottomRails: [CommitGraphLayout.Rail] = []
    let fontScale: CGFloat
    let laneSpacing: CGFloat

    private func laneX(_ lane: Int) -> CGFloat {
        (Self.firstLaneX + CGFloat(lane) * laneSpacing) * fontScale
    }

    private func color(_ index: Int) -> Color {
        if index == 0 { return Color(red: 0.41, green: 0.52, blue: 0.96) }
        let colors: [NSColor] = [.systemGreen, .systemPurple, .systemTeal,
                                 .systemYellow, .systemRed]
        return Color(nsColor: colors[(index - 1) % colors.count])
    }

    var body: some View {
        let _ = themeChanges.revision
        Canvas { context, size in
            let middle = size.height / 2
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
                    context.stroke(
                        path, with: .color(color(linkColor)), style: StrokeStyle(
                            lineWidth: 1.6 * fontScale, lineCap: .round, lineJoin: .round
                        )
                    )
                }
                let radius = 3.2 * fontScale
                let x = laneX(row.node.lane)
                context.fill(
                    Path(ellipseIn: CGRect(x: x - radius, y: middle - radius,
                                           width: 2 * radius, height: 2 * radius)),
                    with: .color(color(row.node.color))
                )
            } else {
                for rail in bottomRails {
                    var path = Path()
                    path.move(to: CGPoint(x: laneX(rail.lane), y: 0))
                    path.addLine(to: CGPoint(x: laneX(rail.lane), y: size.height))
                    context.stroke(path, with: .color(color(rail.color)),
                                   lineWidth: 1.6 * fontScale)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
