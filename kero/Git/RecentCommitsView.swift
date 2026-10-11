//
//  RecentCommitsView.swift
//  kero
//

import AppKit
import SwiftUI

/// One SwiftUI hierarchy for committed paths and worktree paths. The graph
/// occupies its own leading gutter; folder icons use TreeFolderIcon directly.
struct RecentCommitsView: View {
    @Binding private var expandedCommitIDs: Set<String>
    @Binding private var collapsedFolders: Set<String>
    @ObservedObject private var themeChanges = Theme.changes
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
            .padding(.leading, 27)
            .padding(.trailing, 5)
            .frame(height: max(22, ceil(26 * fontScale)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            CommitTreeRails(depth: 0, isCommit: true, startsAtCenter: isFirst,
                            endsAtCenter: !continuesBelow, expanded: expanded)
        }
        .background {
            if expanded { RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: Theme.accent).opacity(0.08)) }
        }
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
            fileRow(depth: 0, continuesBelow: !isLast) {
                Text(String(localized: "No changed files", table: "Git"))
                    .font(.system(size: 9.5 * fontScale))
                    .foregroundStyle(.tertiary)
            }
        } else if viewMode == .tree {
            let section = "commit:" + commit.hash
            let byPath = Dictionary(commit.files.map { ($0.path, $0) },
                                    uniquingKeysWith: { first, _ in first })
            let nodes = GitChangeTree.pathRows(commit.files.map(\.path),
                                               section: section, collapsed: collapsedFolders)
            ForEach(Array(nodes.indices), id: \.self) { index in
                let node = nodes[index]
                let continues = index < nodes.count - 1 || !isLast
                switch node.content {
                case .folder(let path, let name, let collapsed):
                    fileRow(depth: node.depth, continuesBelow: continues) {
                        Button {
                            let key = section + ":" + path
                            if !collapsedFolders.insert(key).inserted { collapsedFolders.remove(key) }
                        } label: {
                            HStack(spacing: TreeRowStyle.iconSpacing) {
                                TreeFolderIcon(expanded: !collapsed, scale: fontScale)
                                ScrollView(.horizontal) {
                                    Text(name)
                                        .font(.system(size: TreeRowStyle.fontSize * fontScale))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .scrollIndicators(.hidden)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(path)
                        .accessibilityLabel(name)
                        .accessibilityValue(collapsed
                            ? String(localized: "Collapsed", table: "Git")
                            : String(localized: "Expanded", table: "Git"))
                        .contextMenu {
                            Button(String(localized: "Copy Relative Path", table: "Git")) { copy(path) }
                        }
                    }
                case .file(let path):
                    if let file = byPath[path] {
                        fileRow(depth: node.depth, continuesBelow: continues) {
                            changedFile(file, in: commit, showDirectory: false)
                        }
                    }
                }
            }
        } else {
            ForEach(Array(commit.files.indices), id: \.self) { index in
                let file = commit.files[index]
                fileRow(depth: 0, continuesBelow: index < commit.files.count - 1 || !isLast) {
                    changedFile(file, in: commit, showDirectory: true)
                }
            }
        }
    }

    private func changedFile(
        _ file: GitStatusModel.RecentCommit.FileChange,
        in commit: GitStatusModel.RecentCommit, showDirectory: Bool
    ) -> some View {
        Button { openDiff(commit, file) } label: {
            HStack(spacing: TreeRowStyle.iconSpacing) {
                MaterialFileIconView(path: file.path, size: TreeRowStyle.iconSize,
                                     opacity: file.status == "D" ? 0.6 : 1)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        Text(file.fileName)
                            .font(.system(size: TreeRowStyle.fontSize * fontScale))
                            .foregroundStyle(.secondary)
                            .strikethrough(file.status == "D")
                            .fixedSize(horizontal: true, vertical: false)
                        if showDirectory && !file.directory.isEmpty {
                            Text(file.directory)
                                .font(.system(size: 9.5 * fontScale))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(String(file.status))
                    .font(.system(size: 9.5 * fontScale, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(nsColor: statusColor(for: file.status)))
                    .frame(width: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.path)
        .accessibilityLabel("\(file.fileName), \(statusName(for: file.status)), \(file.path)")
        .contextMenu {
            Button(String(localized: "Copy Relative Path", table: "Git")) { copy(file.path) }
        }
    }

    private func fileRow<Content: View>(
        depth: Int, continuesBelow: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.leading, 45 + CGFloat(depth) * TreeRowStyle.indent)
            .padding(.trailing, 5)
            .frame(height: TreeRowStyle.rowHeight(fontScale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                CommitTreeRails(depth: depth, isCommit: false,
                                startsAtCenter: false, endsAtCenter: !continuesBelow,
                                expanded: false)
            }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Continuous graph and hierarchy lines are painted across the entire SwiftUI row.
private struct CommitTreeRails: View {
    let depth: Int
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
                for level in 0..<depth {
                    let x = 45 + TreeRowStyle.iconSize / 2
                        + CGFloat(level) * TreeRowStyle.indent
                    context.fill(Path(CGRect(x: x-0.5, y: 0, width: 1, height: size.height)),
                                 with: .color(.primary.opacity(0.18)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private func statusName(for status: Character) -> String {
    switch status {
    case "M": String(localized: "Modified", table: "Git")
    case "A": String(localized: "Added", table: "Git")
    case "D": String(localized: "Deleted", table: "Git")
    case "R": String(localized: "Renamed", table: "Git")
    case "C": String(localized: "Copied", table: "Git")
    case "U": String(localized: "Conflict", table: "Git")
    default: String(localized: "Changed", table: "Git")
    }
}

private func statusColor(for status: Character) -> NSColor {
    switch status {
    case "M": NSColor(srgbRed: 0.82, green: 0.60, blue: 0.13, alpha: 1)
    case "A": NSColor(srgbRed: 0.25, green: 0.73, blue: 0.31, alpha: 1)
    case "D": NSColor(srgbRed: 1.0, green: 0.48, blue: 0.45, alpha: 1)
    case "R", "C": NSColor(srgbRed: 0.35, green: 0.65, blue: 1.0, alpha: 1)
    case "U": NSColor(srgbRed: 0.74, green: 0.55, blue: 1.0, alpha: 1)
    default: .secondaryLabelColor
    }
}
