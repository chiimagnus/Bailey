//
//  RecentCommitsView.swift
//  kero
//

import AppKit
import SwiftUI

/// Commit history decorates the shared tree rows with its own graph gutter.
struct RecentCommitsView: View {
    @Binding private var expandedCommitIDs: Set<String>
    @Binding private var collapsedFolders: Set<String>
    @State private var requestedLastCommit: String?

    let commits: [GitStatusModel.RecentCommit]
    let viewMode: GitViewMode
    let fontScale: CGFloat
    let hasMoreCommits: Bool
    let isLoadingMore: Bool
    let loadMore: () -> Bool
    let openDiff: (GitStatusModel.RecentCommit, GitStatusModel.RecentCommit.FileChange) -> Void

    init(
        commits: [GitStatusModel.RecentCommit],
        expandedCommitIDs: Binding<Set<String>>,
        collapsedFolders: Binding<Set<String>>,
        viewMode: GitViewMode,
        fontScale: CGFloat,
        hasMoreCommits: Bool,
        isLoadingMore: Bool,
        loadMore: @escaping () -> Bool,
        openDiff: @escaping (GitStatusModel.RecentCommit, GitStatusModel.RecentCommit.FileChange) -> Void
    ) {
        self.commits = commits
        _expandedCommitIDs = expandedCommitIDs
        _collapsedFolders = collapsedFolders
        self.viewMode = viewMode
        self.fontScale = fontScale
        self.hasMoreCommits = hasMoreCommits
        self.isLoadingMore = isLoadingMore
        self.loadMore = loadMore
        self.openDiff = openDiff
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(commits) { commit in
                let expanded = expandedCommitIDs.contains(commit.id)
                let isLast = commit.id == commits.last?.id
                VStack(alignment: .leading, spacing: 0) {
                    commitRow(commit, isFirst: commit.id == commits.first?.id,
                              continuesBelow: expanded || !isLast, expanded: expanded)
                    if expanded {
                        commitFiles(commit, isLast: isLast)
                    }
                }
                .onAppear {
                    if isLast { requestMoreIfNeeded(after: commit.id) }
                }
            }
        }
        .onChange(of: commits.last?.id) {
            requestedLastCommit = nil
        }
    }

    private func requestMoreIfNeeded(after id: String) {
        guard hasMoreCommits, !isLoadingMore, requestedLastCommit != id else { return }
        if loadMore() { requestedLastCommit = id }
    }

    private func commitRow(
        _ commit: GitStatusModel.RecentCommit,
        isFirst: Bool, continuesBelow: Bool, expanded: Bool
    ) -> some View {
        TreeRowSurface(
            depth: 0, scale: fontScale, selected: expanded,
            leadingInset: 21, trailingInset: TreeRowStyle.contentInset,
            showsGuides: false,
            height: max(22, ceil(26 * fontScale))
        ) { _ in
            Button {
                if !expandedCommitIDs.insert(commit.id).inserted {
                    expandedCommitIDs.remove(commit.id)
                }
            } label: {
                HStack(spacing: 5) {
                    ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        Text(commit.subject)
                            .font(.system(size: 11.5 * fontScale))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(commit.author.uppercased())
                            .font(.system(size: 9.5 * fontScale, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let reference = primaryReference(for: commit) {
                    Text(reference)
                        .font(.system(size: 9.5 * fontScale, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: 104)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: Theme.accent)))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(commit.shortHash) \u{00B7} \(commit.author) \u{00B7} \(commit.relativeDate)")
            .accessibilityLabel(String(
                localized: "\(commit.subject), \(commit.shortHash), by \(commit.author), \(commit.relativeDate)", table: "Git"
            ))
            .accessibilityValue(expanded
                ? String(localized: "Expanded", table: "Git")
                : String(localized: "Collapsed", table: "Git"))
            .contextMenu {
                Button(String(localized: "Copy Commit Hash", table: "Git")) { copy(commit.hash) }
                Button(String(localized: "Copy Commit Message", table: "Git")) { copy(commit.subject) }
            }
        }
        .background {
            CommitTreeRails(isCommit: true, startsAtCenter: isFirst,
                            endsAtCenter: !continuesBelow, expanded: expanded)
        }
    }

    private func primaryReference(for commit: GitStatusModel.RecentCommit) -> String? {
        commit.references.first {
            $0.contains("/") && !$0.hasPrefix("HEAD -> ") && !$0.contains("/HEAD")
        } ?? commit.references.first.map {
            $0.hasPrefix("HEAD -> ") ? String($0.dropFirst("HEAD -> ".count)) : $0
        }
    }

    @ViewBuilder
    private func commitFiles(_ commit: GitStatusModel.RecentCommit, isLast: Bool) -> some View {
        if commit.files.isEmpty {
            TreeRowSurface(depth: 0, scale: fontScale, hoverEnabled: false, leadingInset: 39) { _ in
                Text(String(localized: "No changed files", table: "Git"))
                    .font(.system(size: 9.5 * fontScale))
                    .foregroundStyle(.tertiary)
            }
            .background { fileRails(continuesBelow: !isLast) }
        } else if viewMode == .tree {
            let section = "commit:" + commit.hash
            let byPath = Dictionary(commit.files.map { ($0.path, $0) },
                                    uniquingKeysWith: { first, _ in first })
            let nodes = TreeDisplayModel.pathRows(commit.files.map(displayRow),
                                                  section: section, collapsed: collapsedFolders)
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                let continues = index < nodes.count - 1 || !isLast
                if node.isDirectory {
                    TreeFolderRow(row: node, scale: fontScale, leadingInset: 39) {
                        let key = section + ":" + node.path
                        if !collapsedFolders.insert(key).inserted { collapsedFolders.remove(key) }
                    }
                    .background { fileRails(continuesBelow: continues) }
                    .contextMenu {
                        Button(String(localized: "Copy Relative Path", table: "Git")) { copy(node.path) }
                    }
                } else if let file = byPath[node.path] {
                    changedFile(file, row: node, in: commit, showDirectory: false)
                        .background { fileRails(continuesBelow: continues) }
                }
            }
        } else {
            ForEach(Array(commit.files.indices), id: \.self) { index in
                let file = commit.files[index]
                changedFile(file, row: displayRow(file), in: commit, showDirectory: true)
                    .background {
                        fileRails(continuesBelow: index < commit.files.count - 1 || !isLast)
                    }
            }
        }
    }

    private func changedFile(
        _ file: GitStatusModel.RecentCommit.FileChange,
        row: TreeDisplayModel.Row,
        in commit: GitStatusModel.RecentCommit, showDirectory: Bool
    ) -> some View {
        TreeFileRow(row: row, scale: fontScale,
                    directory: showDirectory ? file.directory : nil,
                    leadingInset: 39,
                    accessibilityHint: String(localized: "Opens changes", table: "Sidebar"),
                    open: { openDiff(commit, file) }) { _ in EmptyView() }
        .contextMenu {
            Button(String(localized: "Copy Relative Path", table: "Git")) { copy(file.path) }
        }
    }

    private func displayRow(_ file: GitStatusModel.RecentCommit.FileChange) -> TreeDisplayModel.Row {
        TreeDisplayModel.Row(name: file.fileName, path: file.path, isDirectory: false,
                             status: .init(file.status))
    }

    private func fileRails(continuesBelow: Bool) -> some View {
        CommitTreeRails(isCommit: false, startsAtCenter: false,
                        endsAtCenter: !continuesBelow, expanded: false)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Continuous graph and hierarchy lines are painted across the entire SwiftUI row.
private struct CommitTreeRails: View {
    let isCommit: Bool
    let startsAtCenter: Bool
    let endsAtCenter: Bool
    let expanded: Bool

    var body: some View {
        Canvas { context, size in
            let accent = Color(nsColor: Theme.accent)
            let midpoint = size.height / 2
            var graph = Path()
            graph.move(to: CGPoint(x: 14, y: startsAtCenter ? midpoint : 0))
            graph.addLine(to: CGPoint(x: 14, y: endsAtCenter ? midpoint : size.height))
            context.stroke(graph, with: .color(accent.opacity(0.72)), lineWidth: 1.5)
            if isCommit {
                let radius: CGFloat = expanded ? 5 : 4
                context.fill(Path(ellipseIn: CGRect(x: 14-radius,y:midpoint-radius,
                                                     width:radius*2,height:radius*2)),
                             with: .color(accent))
            } else {
                context.fill(Path(CGRect(x: 34.5, y: 0, width: 1, height: size.height)),
                             with: .color(.primary.opacity(0.18)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

