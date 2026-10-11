//
//  RightSidebarView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// Serialises the right pane's refreshes. Reading a panel costs a round trip
/// per directory on a remote workspace, so a tick arriving while one refresh
/// is in flight is folded into a single further pass rather than running
/// alongside it — and never dropped, so a `cd` mid-refresh still lands.
@MainActor
private final class PanelSyncQueue {
    private var isRunning = false
    private var pending = false

    func run(_ body: @escaping () async -> Void) {
        if isRunning {
            pending = true
            return
        }
        isRunning = true
        Task { @MainActor in
            repeat {
                pending = false
                await body()
            } while pending
            isRunning = false
        }
    }
}

/// One ``PortForwardController`` per remote connection, kept while the pane
/// lives so a forward opened from a port row is still known after the user
/// switches panels and comes back. The connection is held weakly: its
/// forwards die with it, so a finished connection's entry is dropped.
@MainActor
private final class PortForwardRegistry {
    private struct Entry {
        weak var connection: RemoteConnection?
        let controller: PortForwardController
    }

    private var entries: [UUID: Entry] = [:]

    func controller(for connection: RemoteConnection?) -> PortForwardController? {
        entries = entries.filter { $0.value.connection != nil }
        guard let connection else { return nil }
        if let existing = entries[connection.id]?.controller { return existing }
        let controller = PortForwardController(connection: connection)
        entries[connection.id] = Entry(connection: connection, controller: controller)
        return controller
    }
}

/// Hosts the pane's remote heading, which is AppKit and outlives any one
/// body evaluation — same shape as the diff viewer's web host.
private struct RemotePaneHeaderHost: NSViewRepresentable {
    let view: RemotePaneHeaderView
    let fontScale: CGFloat

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container {
            attach(to: container)
        }
        view.fontScale = fontScale
    }

    private func attach(to container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Renders one tool within a dock tab. Files, Git and Info retain their
/// original models and actions regardless of where the tab is parked.
struct RightSidebarView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var git: GitStatusModel
    let panel: RightPanel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @StateObject private var info = SessionInfoModel()
    @State private var applicationIsActive = NSApp.isActive
    /// Which rule produced the current panel root; drives the Files badge.
    @State private var rootSource = Project.PanelRootSource.shell
    @State private var syncQueue = PanelSyncQueue()
    /// The remote heading. Held here rather than rebuilt, so its state and
    /// its lamp survive every panel switch and poll.
    @State private var remoteHeader = RemotePaneHeaderView(frame: .zero)
    /// Mirrors the heading's own state, because the layout above has to give
    /// back the row's height when the session is local.
    @State private var remoteHeaderState = RemotePaneHeaderState.local
    @State private var portForwards = PortForwardRegistry()
    /// The selected session's forwards, or nil while it is local.
    @State private var forwards: PortForwardController?

    /// Changes whenever the selected session's connection appears, changes
    /// state, or is replaced.
    private var remoteConnectionToken: String {
        guard let session = manager.selectedSession else { return "none" }
        return workspaceEpoch(of: session)
    }

    /// A pinned local path must not inherit a different machine just because
    /// its terminal happens to be inside an interactive SSH session.
    private var fileActionSession: TerminalSession? {
        guard let project = manager.selectedProject else { return nil }
        if project.sshHost == nil, project.customDirectory != nil,
           project.selectedSession?.workspaceIdentity != nil { return nil }
        return project.selectedSession
    }

    private var sidebarFontScale: CGFloat {
        CGFloat(settings.sidebarFontSize / AppSettings.defaultSidebarFontSize)
    }

    /// The heading is a published-state read costing nothing, and a connection
    /// can die while the user is in another app — turning Wi-Fi off in Control
    /// Centre is exactly that. So it keeps ticking whenever the pane is on
    /// screen, active or not, while the panel refreshes below do not.
    private var pollsSelectedPanel: Bool {
        applicationIsActive && panel != .git
    }

    /// Every terminal in the selected project can change the same repository.
    /// Watching only these counters avoids reacting to prompt/input lifecycle
    /// updates while still catching commands completed in an unfocused pane.
    private var commandCompletionSequences: [UUID: UInt64] {
        Dictionary(uniqueKeysWithValues:
            manager.selectedProject?.sessions.map {
                ($0.id, $0.commandLifecycle.completionSequence)
            } ?? []
        )
    }

    /// Path of the file in the focused pane, so the tree can highlight it.
    /// Reactive: focus/selection is published up through the project to `manager`.
    private var openFilePath: String? {
        if case .file(let file)? = manager.selectedProject?.focusedContent {
            return file.path
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if remoteHeaderState != .local {
                RemotePaneHeaderHost(
                    view: remoteHeader,
                    fontScale: sidebarFontScale
                )
                .frame(height: remoteHeader.fittingSize.height)
                // Same inset as the panel headings below, so the
                // destination and the shell row share a left edge.
                // The view supplies its own top inset.
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            switch panel {
            case .files:
                if let project = manager.selectedProject {
                    FileTreePanel(
                        model: project.fileTree,
                        git: git,
                        session: fileActionSession,
                        sshHost: project.sshHost,
                        rootBadge: rootBadge,
                        currentFilePath: openFilePath,
                        openFile: { manager.openFile($0) },
                        openToSide: { manager.openFileToSide($0) },
                        onRename: { [workspace = project.workspaceIdentity] oldPath, newPath in
                            manager.fileRenamed(
                                from: oldPath, to: newPath, workspace: workspace
                            )
                        },
                        refreshGitStatus: { git.refresh() }
                    )
                }
            case .git:
                GitPanel(
                    model: git,
                    session: fileActionSession,
                    sshHost: manager.selectedProject?.sshHost,
                    openFile: { manager.openFile($0) },
                    openToSide: { manager.openFileToSide($0) },
                    openDiff: { entry, staged in
                        manager.openDiff(
                            repoRoot: git.repoRoot,
                            path: entry.path,
                            staged: staged,
                            untracked: entry.isUntracked,
                            origPath: entry.origPath
                        )
                    },
                    openCommitDiff: { commit, file in
                        manager.openCommitDiff(
                            repoRoot: git.repoRoot,
                            path: file.path,
                            commitHash: commit.hash,
                            parentHash: commit.parentHash,
                            status: file.status,
                            origPath: file.originalPath
                        )
                    }
                )
            case .info:
                InfoPanel(
                    model: info,
                    session: fileActionSession,
                    sshHost: manager.selectedProject?.sshHost,
                    forwards: forwards
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.sidebar))
        .onAppear { syncModels() }
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                applyRemoteHeading()
            }
        }
        // Files and process information remain live while visible. Git is
        // event-driven: terminal/Git command completion and app activation
        // refresh it without a repeating main-run-loop source.
        .task(id: pollsSelectedPanel) {
            guard pollsSelectedPanel else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                syncModels()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            applicationIsActive = true
            syncModels()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification
        )) { _ in
            applicationIsActive = false
        }
        .onChange(of: commandCompletionSequences) {
            syncModels()
        }
        .onChange(of: manager.selectedSession?.id) { syncModels() }
        .onChange(of: manager.selectedProjectID) { syncModels() }
        .onChange(of: manager.selectedProject?.sshHost) { syncModels() }
        // A `cd` in the terminal publishes the new cwd immediately (OSC 7 →
        // session.workingDirectory); resync at once so automatically rooted
        // panels follow the terminal without waiting for another event.
        .onChange(of: manager.selectedSession?.workingDirectory) { syncModels() }
        // A connection appearing, connecting, dying or being replaced changes
        // what the heading says; repaint it without waiting for the next tick.
        .onChange(of: remoteConnectionToken) { applyRemoteHeading() }
        // Same for pinning/unpinning the project directory.
        .onChange(of: manager.selectedProject?.customDirectory) { syncModels() }
        .environment(\.sidebarFontScale, sidebarFontScale)
        // Native button and control labels without a designed hierarchy use
        // the configured base size directly.
        .environment(\.font, .system(size: CGFloat(settings.sidebarFontSize)))
    }

    private func syncModels() {
        // Before the queue, not inside it: a refresh over a dead connection
        // waits out its deadlines, and the heading must not wait with it.
        applyRemoteHeading()
        syncQueue.run { await performSync() }
    }

    /// The heading, and the forwards that belong to the current connection.
    /// Cheap and synchronous — it reads published state and touches no
    /// workspace, so it stays correct while the panels are stalled.
    private func applyRemoteHeading() {
        guard let project = manager.selectedProject else {
            remoteHeaderState = .local
            forwards = nil
            return
        }
        if let host = project.sshHost {
            let state: RemotePaneHeaderState
            switch SSHHostWorkspaces.connectionState(for: host) {
            case .some(true): state = .connected(destination: host)
            case .some(false): state = .disconnected(destination: host)
            case .none: state = .connecting(destination: host)
            }
            remoteHeader.apply(state: state)
            remoteHeader.workingDirectory = project.customDirectory
            if remoteHeaderState != state { remoteHeaderState = state }
            forwards = nil
            return
        }
        if project.customDirectory != nil {
            remoteHeader.apply(state: .local)
            remoteHeaderState = .local
            forwards = nil
            return
        }
        guard let session = project.selectedSession else {
            remoteHeaderState = .local
            forwards = nil
            return
        }
        // An automatically scoped project may still follow its terminal's
        // connection. A pinned project never does.
        let headerState = session.remoteHeaderState
        remoteHeader.apply(state: headerState)
        remoteHeader.workingDirectory = headerState == .local
            ? nil
            : session.panelDirectoryPath
        if remoteHeaderState != headerState { remoteHeaderState = headerState }
        let controller = portForwards.controller(for: session.location.remoteConnection)
        if forwards !== controller { forwards = controller }
    }

    /// Which workspace a refresh belongs to. A connection changing state, or
    /// being replaced, makes results that were already in flight stale.
    private func workspaceEpoch(of session: TerminalSession) -> String {
        if let host = manager.selectedProject?.sshHost { return "ssh:" + host }
        if manager.selectedProject?.customDirectory != nil { return "local" }
        guard let connection = session.location.remoteConnection else { return "local" }
        return "\(connection.id) \(connection.state)"
    }

    private func performSync() async {
        guard manager.isPanelVisible,
              let project = manager.selectedProject,
              let context = project.panelContext
        else { return }
        let session = project.selectedSession
        // The panel path, not the session's own: once the session is on a
        // remote machine these panels follow the remote shell's directory,
        // while new local terminals and restore snapshots keep the local one.
        // A dead connection answers nothing: every call below would wait out
        // its own deadline, one after another, and stall the refresh loop for
        // as long as the link stays down. The panels keep their last remote
        // contents instead, which is what the heading is telling the user.
        if project.sshHost == nil, project.customDirectory == nil,
           let connection = session?.location.remoteConnection,
           connection.state == .disconnected {
            return
        }
        let epoch = session.map(workspaceEpoch) ?? context.scope

        let cwd = context.cwd
        let backend = context.backend
        // Files and Git anchor to the project directory — pinned when the
        // user set one, else the repository the session is working in — so
        // they don't re-root as the terminal cds around a repo; Info
        // describes the shell itself, showing its live cwd next to that root.
        // An agent that moves to its own worktree changes only its own
        // process directory, so the foreground job's cwd is passed in too.
        let (root, source) = await project.panelRoot(
            followingSessionAt: cwd,
            foregroundAt: context.foreground,
            backend: backend
        )
        // The connection may have died while that was in flight; its answer
        // describes a workspace that is no longer the one on screen.
        guard epoch == (project.selectedSession.map(workspaceEpoch) ?? context.scope),
              manager.selectedProjectID == project.id else { return }
        if rootSource != source { rootSource = source }
        switch manager.panelTab {
        case .files:
            await project.fileTree.sync(root: root, backend: backend, scope: context.scope)
        case .git:
            break
        case .info:
            // The panel pid, not the session's own: while remote these rows
            // describe the remote login shell and its children, so filtering
            // them by this Mac's shell pid would find nothing.
            await info.sync(
                root: project.sshHost == nil ? cwd : root,
                projectRoot: root, projectRootSource: source,
                shellName: session?.shellName ?? "",
                shellPid: project.sshHost == nil && fileActionSession != nil
                    ? session?.panelShellPid : nil,
                isRemote: project.workspaceIdentity != nil,
                backend: backend
            )
        }
    }

    /// Text badge for the Files header while the panels follow the foreground
    /// job instead of the shell — the agent's worktree in the common case, a
    /// plain "job" when it moved somewhere that isn't a linked worktree.
    /// The label and its spoken description travel together so neither is
    /// assembled from translated fragments.
    private var rootBadge: (text: String, description: String)? {
        guard case .foreground(let isWorktree) = rootSource else { return nil }
        if isWorktree {
            return (
                String(
                    localized: "worktree", table: "Sidebar",
                    comment: "Files header badge: the panels follow a Git worktree the terminal’s foreground job moved to."
                ),
                String(localized: "Following the terminal job’s worktree", table: "Sidebar")
            )
        }
        return (
            String(
                localized: "job", table: "Sidebar",
                comment: "Files header badge: the panels follow a directory the terminal’s foreground job moved to, outside any worktree of the shell’s repository."
            ),
            String(localized: "Following the terminal job’s directory", table: "Sidebar")
        )
    }
}

// MARK: - Shared panel chrome

private struct PanelHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .sidebarFont(size: 12, weight: .semibold)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .sidebarFont(size: 10)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - File tree

private struct FileTreePanel: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var git: GitStatusModel
    let session: TerminalSession?
    let sshHost: String?
    /// Set while the tree follows the terminal's foreground job into another
    /// checkout, so the header says why the root moved.
    let rootBadge: (text: String, description: String)?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void
    let refreshGitStatus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PanelHeader(title: model.rootName, subtitle: model.rootPath)
                if let rootBadge {
                    Text(verbatim: rootBadge.text)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.09))
                        )
                        .accessibilityLabel(rootBadge.description)
                }
                // Finder can only reach the local disk; while remote this
                // path names a directory on another machine.
                if sshHost == nil && session?.location.remoteConnection == nil {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: model.rootPath)]
                        )
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .sidebarFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Reveal in Finder", table: "Sidebar"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            FileTreeScrollView(
                model: model, git: git, session: session,
                sshHost: sshHost, currentFilePath: currentFilePath,
                openFile: openFile, openToSide: openToSide, onRename: onRename,
                refreshGitStatus: refreshGitStatus
            )
        }
    }
}

/// The same SwiftUI rows, 22 pt layout and hierarchy lines as the Git tree.
/// The tree stays viewport-sized; only long names scroll horizontally.
private struct FileTreeScrollView: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var git: GitStatusModel
    let session: TerminalSession?
    let sshHost: String?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (String, String) -> Void
    let refreshGitStatus: () -> Void
    @Environment(\.sidebarFontScale) private var fontScale

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.items) { item in
                    FileTreeRow(
                        model: model, git: git, item: item,
                        session: session, sshHost: sshHost,
                        currentFilePath: currentFilePath,
                        openFile: openFile, openToSide: openToSide,
                        onRename: onRename, refreshGitStatus: refreshGitStatus
                    )
                }
            }
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .id(model.rootPath)
    }
}

private struct FileTreeRow: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var git: GitStatusModel
    let item: FileTreeModel.Item
    let session: TerminalSession?
    let sshHost: String?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void
    let refreshGitStatus: () -> Void

    @State private var editingName = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.sidebarFontScale) private var fontScale

    private var isRenaming: Bool { model.renamingPath == item.path }

    /// The file open in the active tab, so it reads as selected in the tree.
    private var isCurrent: Bool { !item.isDirectory && item.path == currentFilePath }

    private var gitDecoration: GitStatusModel.FileDecoration? {
        git.fileDecoration(for: item.path, isDirectory: item.isDirectory)
    }

    private var displayRow: TreeDisplayModel.Row {
        var row = item
        row.status = gitDecoration
        return row
    }

    /// Whether this row names a file on another machine. A connection that has
    /// dropped still counts: the path is remote either way, and handing it to
    /// Finder would open whatever sits at the same path locally.
    private var isRemote: Bool {
        sshHost != nil || session?.location.remoteConnection != nil
    }

    var body: some View {
        if item.isDraft {
            // The transient input keeps the same focused fill but has no hover/menu.
            TreeRowSurface(
                depth: item.depth, scale: fontScale,
                focused: true, hoverEnabled: false
            ) { _, layout in
                draftRow
                    .modifier(layout)
            }
        } else if isRenaming {
            TreeRowSurface(
                depth: item.depth, scale: fontScale, selected: isCurrent
            ) { _, layout in
                renameRow
                    .modifier(layout)
            }
            .contextMenu { rowMenu }
        } else {
            semanticRow
                .contextMenu { rowMenu }
                .onDrag {
                    NSItemProvider(object: URL(fileURLWithPath: item.path) as NSURL)
                }
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        if !item.isDirectory {
            Button(String(localized: "Open", table: "Sidebar")) {
                openFile(item.path)
            }
            Button(String(localized: "Open to the Side", table: "Sidebar")) {
                openToSide(item.path)
            }
        }
        // Finder and the default app can only reach the local disk.
        if !isRemote {
            Button(String(localized: "Open in Default App", table: "Sidebar")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            }
            Button(String(localized: "Reveal in Finder", table: "Sidebar")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
        Button(String(localized: "Copy Path", table: "Sidebar")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
        if item.isDirectory {
            Button(String(localized: "cd Here", table: "Sidebar")) {
                session?.sendCommand("cd " + shellQuote(item.path) + "\n")
            }
            Divider()
            Button(String(localized: "New File…", table: "Sidebar")) {
                Task { await model.beginNewFile(in: item.path) }
            }
            Button(String(localized: "New Folder…", table: "Sidebar")) {
                Task { await model.beginNewFolder(in: item.path) }
            }
        }
        Divider()
        Button(String(localized: "Rename", table: "Sidebar")) {
            model.beginRename(item)
        }
        if isRemote {
            // No Trash on the remote: Freedesktop semantics vary between
            // distributions and a silently misplaced file is worse than an
            // explicit delete the user confirmed.
            Button(String(localized: "Delete…", table: "Sidebar"), role: .destructive) {
                guard confirmRemoteDelete() else { return }
                Task {
                    await model.delete(item)
                    refreshGitStatus()
                }
            }
        } else {
            Button(String(localized: "Move to Trash", table: "Sidebar"), role: .destructive) {
                Task {
                    await model.moveToTrash(item)
                    refreshGitStatus()
                }
            }
        }
    }

    /// Names the full remote path, because there is nothing to undo it with.
    private func confirmRemoteDelete() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Delete “\(item.name)” on \(sshHost ?? session?.location.remoteConnection?.displayName ?? "the remote machine")?", table: "Sidebar",
            comment: "Remote delete confirmation. The placeholders are a file name and a remote machine as user@host."
        )
        alert.informativeText = String(
            localized: "\(item.path) will be deleted. This cannot be undone — a remote file does not go to the Trash.", table: "Sidebar",
            comment: "Remote delete confirmation detail. The placeholder is a full path."
        )
        alert.addButton(withTitle: String(localized: "Delete", table: "Sidebar"))
        alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Commits an inline rename and, when the file actually moved, tells the
    /// app to follow it in any open tabs. Guarded by `isRenaming` so the
    /// commit-on-blur that fires right after Enter/Escape is a no-op.
    private func commitRename() {
        guard isRenaming else { return }
        let oldPath = item.path
        let newName = editingName
        Task {
            if let newPath = await model.rename(item, to: newName) {
                onRename(oldPath, newPath)
                refreshGitStatus()
            }
        }
    }

    /// Commits the inline new-file/folder input, opening a newly created file.
    /// Guarded so the commit-on-blur after Enter/Escape is a no-op.
    private func commitDraft() {
        guard item.isDraft, model.draft != nil else { return }
        let name = editingName
        Task {
            if let created = await model.commitDraft(name: name) {
                openFile(created)
            }
            refreshGitStatus()
        }
    }

    @ViewBuilder
    private var semanticRow: some View {
        if item.isDirectory {
            TreeFolderRow(row: displayRow, scale: fontScale) {
                Task { await model.toggle(item) }
            }
        } else {
            TreeFileRow(row: displayRow, scale: fontScale, selected: isCurrent,
                        open: { openFile(item.path) }) { _ in EmptyView() }
        }
    }

    private var renameRow: some View {
        HStack(spacing: TreeRowStyle.iconSpacing) {
            leadingGlyphs
            if !item.compactPrefix.isEmpty {
                Text(item.compactPrefix.joined(separator: " / ") + " /")
                    .sidebarFont(size: TreeRowStyle.fontSize)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            nameField(String(localized: "Name", table: "Sidebar"))
                .onSubmit { commitRename() }
                .onKeyPress(.escape) { model.cancelRename(); return .handled }
                .onChange(of: fieldFocused) {
                    // Commit on blur (Finder-style); unchanged names no-op.
                    if !fieldFocused { commitRename() }
                }
        }
        .onAppear {
            editingName = item.name
            focusField()
        }
    }

    private var draftRow: some View {
        HStack(spacing: TreeRowStyle.iconSpacing) {
            leadingGlyphs
            nameField(item.isDirectory
                ? String(localized: "Folder name", table: "Sidebar")
                : String(localized: "File name", table: "Sidebar"))
                .onSubmit { commitDraft() }
                .onKeyPress(.escape) {
                    Task { await model.cancelDraft() }
                    return .handled
                }
                .onChange(of: fieldFocused) {
                    // Blur commits a typed name, cancels an empty one (VS Code).
                    if !fieldFocused { commitDraft() }
                }
        }
        .onAppear {
            editingName = ""
            focusField()
        }
    }

    private func nameField(_ placeholder: String) -> some View {
        TextField(placeholder, text: $editingName)
            .textFieldStyle(.plain)
            .sidebarFont(size: 11.5)
            .foregroundStyle(.primary)
            .focused($fieldFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: Theme.background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(nsColor: Theme.accent).opacity(0.7), lineWidth: 1)
            )
    }

    /// Grab focus on the next runloop tick — a context menu is still
    /// dismissing when the input row appears, and a synchronous focus can be
    /// stolen back as it tears down.
    private func focusField() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var leadingGlyphs: some View {
        Group {
            if item.isDirectory {
                TreeFolderIcon(expanded: model.isExpanded(item), scale: fontScale)
            } else {
                MaterialFileIconView(path: item.path, size: TreeRowStyle.iconSize)
                    .frame(width: TreeRowStyle.iconSize)
            }
        }
    }
}

// MARK: - Git panel

private struct GitPanel: View {
    @ObservedObject private var settings = AppSettings.shared

    private enum EntryOperation: Equatable {
        case stage
        case unstage
        case discard
    }

    private enum OperationTrigger: Equatable {
        case branchMenu
        case moreMenu
        case primaryAction
        case commitMenu
        case syncButton
        case stageAll
        case unstageAll
        case discardAll
        case entry(path: String, operation: EntryOperation)
        case initializeRepository
    }

    private struct FileFingerprint: Equatable {
        let exists: Bool
        let size: UInt64
        let modificationDate: Date?
        let fileNumber: UInt64?
        let symbolicLinkDestination: String?
    }

    private struct PendingDiscard {
        let entry: GitStatusModel.Entry
        let fingerprints: [String: FileFingerprint]
        let branch: String?
        let headOID: String?
        let scope: String
    }

    @ObservedObject var model: GitStatusModel
    let session: TerminalSession?
    let sshHost: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let openDiff: (_ entry: GitStatusModel.Entry, _ staged: Bool) -> Void
    let openCommitDiff: (
        _ commit: GitStatusModel.RecentCommit,
        _ file: GitStatusModel.RecentCommit.FileChange
    ) -> Void

    @State private var commitMessage = ""
    @State private var pendingDiscard: PendingDiscard?
    @State private var pendingDiscardAll: [PendingDiscard] = []
    @State private var preparingDiscard = false
    @State private var confirmDiscardAll = false
    @State private var mergeCollapsed = false
    @State private var stagedCollapsed = false
    @State private var changesCollapsed = false
    private var collapsedFolders: Set<String> { model.collapsedFolders }
    private var collapsedFoldersBinding: Binding<Set<String>> {
        Binding(
            get: { model.collapsedFolders },
            set: { model.collapsedFolders = $0 }
        )
    }
    @State private var historyCollapsed = false
    @State private var expandedCommitIDs: Set<String> = []
    @State private var filterText = ""
    @State private var showFilter = false
    @State private var operationExpanded = false
    @State private var operationTrigger: OperationTrigger?
    @Environment(\.sidebarFontScale) private var sidebarFontScale

    var body: some View {
        VStack(spacing: 0) {
            header
            operationFailureBanner

            if let statusError = model.statusError {
                statusFailure(statusError)
            } else if !model.isRepo {
                if model.isResolvingInitialStatus {
                    placeholder(icon: "arrow.clockwise", text: String(localized: "Finding repository…", table: "Sidebar"))
                } else {
                    notRepository
                }
            } else {
                trackingBar
                repositoryOperationBanner
                commitBox
                filterBar
                changeList
            }
        }
        .confirmationDialog(
            discardTitle(for: pendingDiscard?.entry),
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(discardActionTitle(for: pendingDiscard?.entry),
                   role: .destructive) {
                if let pendingDiscard {
                    if remoteName != nil {
                        Task {
                            if await remoteDiscardSnapshotIsCurrent(pendingDiscard) {
                                performOperation(
                                    .entry(path: pendingDiscard.entry.path, operation: .discard)
                                ) { model.discard(pendingDiscard.entry) }
                            } else { model.cancelStaleDiscard() }
                        }
                    } else if discardSnapshotIsCurrent(pendingDiscard) {
                        performOperation(
                            .entry(path: pendingDiscard.entry.path, operation: .discard)
                        ) { model.discard(pendingDiscard.entry) }
                    } else { model.cancelStaleDiscard() }
                }
                pendingDiscard = nil
            }
            .disabled(model.isBusy)
        }
        .confirmationDialog(
            discardAllTitle,
            isPresented: Binding(
                get: { confirmDiscardAll },
                set: {
                    confirmDiscardAll = $0
                    if !$0 { pendingDiscardAll = [] }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Discard All Changes", table: "Sidebar"), role: .destructive) {
                let snapshot = pendingDiscardAll
                if remoteName != nil {
                    Task {
                        var verified = !snapshot.isEmpty
                        for entry in snapshot where verified {
                            verified = await remoteDiscardSnapshotIsCurrent(entry)
                        }
                        if verified {
                            performOperation(.discardAll) {
                                model.discardChanges(snapshot.map(\.entry))
                            }
                        } else { model.cancelStaleDiscard() }
                    }
                } else if !snapshot.isEmpty && snapshot.allSatisfy(discardSnapshotIsCurrent) {
                    performOperation(.discardAll) {
                        model.discardChanges(snapshot.map(\.entry))
                    }
                } else { model.cancelStaleDiscard() }
                pendingDiscardAll = []
                confirmDiscardAll = false
            }
            .disabled(model.isBusy)
        }
        .onChange(of: model.rootPath) {
            // A dialog must never carry a destructive file target across cwd.
            pendingDiscard = nil
            pendingDiscardAll = []
            confirmDiscardAll = false
        }
        .onChange(of: model.repositoryIdentity) {
            resetRepositoryDrafts()
        }
        .onChange(of: model.currentScope) {
            pendingDiscard = nil
            pendingDiscardAll = []
            confirmDiscardAll = false
        }
        .onChange(of: model.isBusy) {
            if !model.isBusy { operationTrigger = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if model.isRepo {
                branchMenu
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .sidebarFont(size: 11, weight: .medium)
                    .foregroundStyle(Color(nsColor: Theme.accent))
                PanelHeader(title: String(localized: "Git", table: "Sidebar"), subtitle: model.rootPath)
            }
            // User operations surface progress in their initiating control.
            // Keep repository discovery here because it has no trigger button.
            if model.isResolvingInitialStatus {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel(String(localized: "Refreshing Git status", table: "Sidebar"))
            }
            if preparingDiscard {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Verifying remote files", table: "Sidebar"))
            }
            if model.isRepo {
                headerButton(
                    "line.3.horizontal.decrease",
                    help: String(localized: "Filter Changed Files", table: "Sidebar"),
                    disabled: false
                ) {
                    showFilter.toggle()
                    if !showFilter { filterText = "" }
                }
                headerButton(
                    "arrow.clockwise",
                    help: String(localized: "Refresh Git Status", table: "Sidebar"),
                    disabled: model.isBusy || model.isResolvingInitialStatus
                ) {
                    model.refresh()
                }
                moreMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var branchMenu: some View {
        Menu {
            if !model.branches.isEmpty {
                ForEach(model.branches, id: \.self) { branch in
                    Button {
                        performOperation(.branchMenu) {
                            model.switchBranch(to: branch)
                        }
                    } label: {
                        if branch == model.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                    .disabled(branch == model.branch || model.isBusy)
                }
                Divider()
            }
            Button(String(localized: "Create New Branch…", table: "Sidebar")) {
                presentCreateBranchDialog()
            }
            .disabled(model.isBusy)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Image(systemName: "arrow.triangle.branch")
                        .sidebarFont(size: 11, weight: .medium)
                        .foregroundStyle(Color(nsColor: Theme.accent))
                        .opacity(operationIsLoading(.branchMenu) ? 0 : 1)
                    if operationIsLoading(.branchMenu) {
                        operationProgressView()
                    }
                }
                PanelHeader(
                    title: model.branch ?? String(localized: "Detached HEAD", table: "Sidebar"),
                    subtitle: model.rootPath
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(String(localized: "Switch or Create Branch", table: "Sidebar"))
        .accessibilityLabel(
            String(localized: "Current branch, \(model.branch ?? String(localized: "detached HEAD", table: "Sidebar"))", table: "Sidebar")
        )
    }

    private var moreMenu: some View {
        Menu {
            Button(String(localized: "Fetch", table: "Sidebar")) { performOperation(.moreMenu, model.fetch) }
                .disabled(model.isBusy || model.remotes.isEmpty)
            Button(String(localized: "Pull (Fast-forward Only)", table: "Sidebar")) { performOperation(.moreMenu, model.pull) }
                .disabled(model.isBusy || !model.hasUpstream)
            if model.hasUpstream {
                Button(String(localized: "Push", table: "Sidebar")) { performOperation(.moreMenu, model.push) }
                    .disabled(model.isBusy)
            } else if model.remotes.count > 1 {
                Menu(String(localized: "Publish Branch to", table: "Sidebar")) {
                    ForEach(model.remotes, id: \.self) { remote in
                        Button(remote) {
                            performOperation(.moreMenu) { model.publish(to: remote) }
                        }
                    }
                }
                .disabled(model.isBusy || model.branch == "detached HEAD")
            } else {
                Button(String(localized: "Publish Branch", table: "Sidebar")) { performOperation(.moreMenu, model.push) }
                    .disabled(model.isBusy || model.remotes.isEmpty || model.branch == "detached HEAD")
            }
            Button(String(localized: "Sync Changes", table: "Sidebar")) { performOperation(.moreMenu, model.syncChanges) }
                .disabled(
                    model.isBusy || model.remotes.isEmpty
                        || (!model.hasUpstream && model.remotes.count != 1)
                        || model.branch == "detached HEAD"
                )
            Divider()
            Button(String(localized: "Stash All Changes", table: "Sidebar")) {
                performOperation(.moreMenu) { model.stash(includeUntracked: true) }
            }
                .disabled(model.isBusy || model.totalChangeCount == 0)
            Button(
                model.stashCount == 1
                    ? String(localized: "Pop Stash", table: "Sidebar")
                    : String(localized: "Pop Stash (\(model.stashCount))", table: "Sidebar")
            ) {
                performOperation(.moreMenu, model.stashPop)
            }
            .disabled(model.isBusy || model.stashCount == 0)
            Divider()
            Button(String(localized: "Copy Changed Paths", table: "Sidebar")) { copyChangedPaths() }
                .disabled(model.totalChangeCount == 0)
            Button(String(localized: "Copy Repository Path", table: "Sidebar")) { copyToPasteboard(model.repoRoot) }
            // Finder can only show a path on this Mac.
            if remoteName == nil {
                Button(String(localized: "Reveal Repository in Finder", table: "Sidebar")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.repoRoot)])
                }
            }
        } label: {
            ZStack {
                Image(systemName: "ellipsis")
                    .sidebarFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .opacity(operationIsLoading(.moreMenu) ? 0 : 1)
                if operationIsLoading(.moreMenu) {
                    operationProgressView()
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "More Actions…", table: "Sidebar"))
        .accessibilityLabel(String(localized: "More Git Actions", table: "Sidebar"))
    }

    private func headerButton(
        _ systemImage: String, help: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .sidebarFont(size: 10, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var trackingBar: some View {
        if let branch = model.branch {
            HStack(spacing: 5) {
                Image(systemName: model.hasUpstream ? "arrow.triangle.2.circlepath" : "icloud.slash")
                    .sidebarFont(size: 9, weight: .medium)
                    .foregroundStyle(.secondary)
                Text(verbatim: model.upstream ?? (branch == "detached HEAD"
                    ? String(localized: "Detached HEAD", table: "Sidebar")
                    : String(localized: "Unpublished branch", table: "Sidebar")))
                    .sidebarFont(size: 9.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if model.behind > 0 {
                    badge(
                        "↓\(model.behind)",
                        label: String(localized: "\(model.behind) incoming commits", table: "Sidebar")
                    )
                }
                if model.ahead > 0 {
                    badge(
                        "↑\(model.ahead)",
                        label: String(localized: "\(model.ahead) outgoing commits", table: "Sidebar")
                    )
                }
            }
            .frame(height: 17)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Repository and operation state

    @ViewBuilder
    private var repositoryOperationBanner: some View {
        if let current = model.repositoryOperation {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.merge")
                    .sidebarFont(size: 10, weight: .semibold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: current)
                        .sidebarFont(size: 10.5, weight: .medium)
                    Text(model.mergeEntries.isEmpty
                         ? String(localized: "Finish or abort from the terminal", table: "Sidebar")
                         : String(
                            localized: "Resolve and stage \(model.mergeEntries.count) conflicted files", table: "Sidebar",
                            comment: "Git merge guidance. The placeholder is the number of conflicted files."
                         ))
                        .sidebarFont(size: 9.5)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(red: 0.74, green: 0.55, blue: 1.0))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.74, green: 0.55, blue: 1.0).opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var operationFailureBanner: some View {
        if let operation = model.operation,
           case .failed = operation.state {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .sidebarFont(size: 10)
                    Text(operation.statusLabel)
                        .sidebarFont(size: 10.5, weight: .medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !operation.output.isEmpty {
                        Button {
                            operationExpanded.toggle()
                        } label: {
                            Image(systemName: "chevron.right")
                                .sidebarFont(size: 8, weight: .semibold)
                                .rotationEffect(.degrees(operationExpanded ? 90 : 0))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(
                            operationExpanded
                                ? String(localized: "Hide Git Output", table: "Sidebar")
                                : String(localized: "Show Git Output", table: "Sidebar")
                        )
                        .accessibilityLabel(
                            operationExpanded
                                ? String(localized: "Hide Git Output", table: "Sidebar")
                                : String(localized: "Show Git Output", table: "Sidebar")
                        )
                    }
                    Button {
                        operationExpanded = false
                        model.dismissOperation()
                    } label: {
                        Image(systemName: "xmark")
                            .sidebarFont(size: 8, weight: .semibold)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Dismiss", table: "Sidebar"))
                    .accessibilityLabel(String(localized: "Dismiss Git Error", table: "Sidebar"))
                }
                if operationExpanded, !operation.output.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: operation.output)
                            .sidebarFont(size: 9, design: .monospaced)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .frame(maxHeight: 96)
                    .accessibilityLabel(String(localized: "Git Output", table: "Sidebar"))
                }
            }
            .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.36))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.88, green: 0.42, blue: 0.36).opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
        }
    }

    private func presentCreateBranchDialog() {
        guard !model.isBusy else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "Create New Branch", table: "Sidebar")
        alert.informativeText = String(localized: "Enter a name for the new branch.", table: "Sidebar")

        let field = NSTextField(string: "")
        field.placeholderString = String(localized: "Branch name", table: "Sidebar")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field

        let create = alert.addButton(withTitle: String(localized: "Create", table: "Sidebar"))
        create.keyEquivalent = "\r"
        create.isEnabled = false
        let cancel = alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
        cancel.keyEquivalent = "\u{1b}"

        let validator = NonemptyTextFieldValidator(button: create)
        field.delegate = validator
        alert.window.initialFirstResponder = field

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            _ = validator // Keep the field delegate alive until the sheet closes.
            guard response == .alertFirstButtonReturn else { return }
            performOperation(.branchMenu) {
                model.createBranch(named: field.stringValue)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    // MARK: Commit box

    private var commitBox: some View {
        VStack(spacing: 6) {
            TextField(
                "",
                text: $commitMessage,
                prompt: Text(commitFieldPlaceholder).foregroundStyle(.tertiary),
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .sidebarFont(size: 11.5)
                .lineLimit(1...4)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    performPrimaryAction()
                    return .handled
                }

            if !showSyncButton || canCommit(includeAll: false) {
                HStack(spacing: 4) {
                    actionButton(
                        icon: "checkmark",
                        title: commitButtonTitle,
                        enabled: canCommit(includeAll: false),
                        isLoading: operationIsLoading(.primaryAction),
                        help: String(localized: "Commit staged changes (⌘Return)", table: "Sidebar"),
                        action: performPrimaryAction
                    )
                    commitMenu
                }
            }

            if showSyncButton {
                actionButton(
                    icon: "arrow.triangle.2.circlepath",
                    title: syncButtonTitle,
                    enabled: !model.isBusy,
                    isLoading: operationIsLoading(.syncButton),
                    help: String(localized: "Pull remote commits, then push local ones", table: "Sidebar"),
                    action: {
                        performOperation(.syncButton, model.syncChanges)
                    }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var commitMenu: some View {
        Menu {
            Button(String(localized: "Commit Staged", table: "Sidebar")) {
                performCommit(includeAll: false, trigger: .commitMenu)
            }
                .disabled(!canCommit(includeAll: false))
            Button(String(localized: "Stage All & Commit", table: "Sidebar")) {
                performCommit(includeAll: true, trigger: .commitMenu)
            }
                .disabled(!canCommit(includeAll: true))
            Divider()
            Button(String(localized: "Amend Last Commit", table: "Sidebar")) {
                performCommit(includeAll: false, amend: true, trigger: .commitMenu)
            }
                .disabled(!canAmend(includeAll: false))
            Button(String(localized: "Stage All & Amend", table: "Sidebar")) {
                performCommit(includeAll: true, amend: true, trigger: .commitMenu)
            }
                .disabled(!canAmend(includeAll: true))
        } label: {
            ZStack {
                Image(systemName: "chevron.down")
                    .sidebarFont(size: 8, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .opacity(operationIsLoading(.commitMenu) ? 0 : 1)
                if operationIsLoading(.commitMenu) {
                    operationProgressView()
                }
            }
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Commit Options", table: "Sidebar"))
        .accessibilityLabel(String(localized: "Commit Options", table: "Sidebar"))
    }

    private func actionButton(
        icon: String, title: String, enabled: Bool, isLoading: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLoading {
                    operationProgressView()
                } else {
                    Image(systemName: icon)
                        .sidebarFont(size: 10, weight: .semibold)
                }
                Text(title)
                    .sidebarFont(size: 11, weight: .medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: Theme.accent).opacity(enabled || isLoading ? 0.85 : 0.3))
            )
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(
            isLoading ? String(localized: "\(title), in progress", table: "Sidebar") : title
        )
    }

    private var commitFieldPlaceholder: String {
        if model.stagedEntries.isEmpty {
            return model.recentCommits.isEmpty
                ? String(localized: "Message (stage changes to use ⌘⏎)", table: "Sidebar")
                : String(localized: "Message (stage changes to use ⌘⏎, or choose Amend)", table: "Sidebar")
        }
        if let branch = model.branch {
            return String(
                localized: "Message (⌘⏎ to commit on “\(branch)”)", table: "Sidebar",
                comment: "Commit message placeholder. The placeholder is the current branch name."
            )
        }
        return String(localized: "Message (⌘⏎ to commit)", table: "Sidebar")
    }

    private var showSyncButton: Bool {
        model.totalChangeCount == 0 && (model.ahead > 0 || model.behind > 0)
    }

    private var syncButtonTitle: String {
        var title = String(localized: "Sync Changes", table: "Sidebar")
        if model.behind > 0 { title += " \(model.behind)↓" }
        if model.ahead > 0 { title += " \(model.ahead)↑" }
        return title
    }

    private var commitButtonTitle: String {
        guard !model.stagedEntries.isEmpty else {
            return String(localized: "Commit Staged", table: "Sidebar")
        }
        return String(
            localized: "Commit \(model.stagedEntries.count) Staged Files", table: "Sidebar",
            comment: "Commit button title. The placeholder is the number of staged files."
        )
    }

    private func canCommit(includeAll: Bool) -> Bool {
        let hasEligibleChanges = includeAll
            ? (!model.changedEntries.isEmpty || !model.stagedEntries.isEmpty)
            : !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isBusy
    }

    private func canAmend(includeAll: Bool) -> Bool {
        let hasCommit = !model.recentCommits.isEmpty
        let hasEligibleChanges = !includeAll
            || !model.changedEntries.isEmpty
            || !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCommit
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isBusy
    }

    private func performPrimaryAction() {
        performCommit(includeAll: false, trigger: .primaryAction)
    }

    private func performCommit(
        includeAll: Bool,
        amend: Bool = false,
        trigger: OperationTrigger
    ) {
        guard amend ? canAmend(includeAll: includeAll) : canCommit(includeAll: includeAll) else { return }
        let submittedMessage = commitMessage
        performOperation(trigger) {
            model.commit(message: submittedMessage, includeAll: includeAll, amend: amend) { success in
                if success, commitMessage == submittedMessage { commitMessage = "" }
            }
        }
    }

    // MARK: Filter

    @ViewBuilder
    private var filterBar: some View {
        if showFilter {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .sidebarFont(size: 10)
                    .foregroundStyle(.tertiary)
                TextField(String(localized: "Filter changed files", table: "Sidebar"), text: $filterText)
                    .textFieldStyle(.plain)
                    .sidebarFont(size: 11)
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .sidebarFont(size: 10)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Clear Filter", table: "Sidebar"))
                    .accessibilityLabel(String(localized: "Clear Git Filter", table: "Sidebar"))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.045))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    // MARK: Change list

    // Only text scrolls horizontally. Section controls and row actions remain
    // anchored to the visible sidebar, even for exceptionally long paths.
    private var changeList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.totalChangeCount == 0 {
                    cleanState
                } else if visibleChangeCount == 0 {
                    inlinePlaceholder(
                        icon: "line.3.horizontal.decrease",
                        text: String(localized: "No changed files match “\(filterText)”", table: "Sidebar")
                    )
                }
                if !filteredMergeEntries.isEmpty {
                    GitSectionHeader(
                        title: String(localized: "MERGE CHANGES", table: "Sidebar"),
                        count: filteredMergeEntries.count,
                        isCollapsed: $mergeCollapsed,
                        actions: [],
                        actionsDisabled: model.isBusy
                    )
                    if !mergeCollapsed {
                        changedFileRows(filteredMergeEntries, kind: .merge)
                    }
                }
                if !filteredStagedEntries.isEmpty {
                    GitSectionHeader(
                        title: String(localized: "STAGED CHANGES", table: "Sidebar"),
                        count: filteredStagedEntries.count,
                        isCollapsed: $stagedCollapsed,
                        actions: filterText.isEmpty ? [
                            .init(
                                systemImage: "minus",
                                help: String(localized: "Unstage All Changes", table: "Sidebar"),
                                isLoading: operationIsLoading(.unstageAll)
                            ) {
                                performOperation(.unstageAll, model.unstageAll)
                            }
                        ] : [],
                        actionsDisabled: model.isBusy
                    )
                    if !stagedCollapsed {
                        changedFileRows(filteredStagedEntries, kind: .staged)
                    }
                }
                if !filteredChangedEntries.isEmpty {
                    GitSectionHeader(
                        title: String(localized: "CHANGES", table: "Sidebar"),
                        count: filteredChangedEntries.count,
                        isCollapsed: $changesCollapsed,
                        actions: filterText.isEmpty ? [
                            .init(
                                systemImage: "arrow.uturn.backward",
                                help: String(localized: "Discard All Changes", table: "Sidebar"),
                                isLoading: operationIsLoading(.discardAll)
                            ) {
                                requestDiscardAll()
                            },
                            .init(
                                systemImage: "plus",
                                help: String(localized: "Stage All Changes", table: "Sidebar"),
                                isLoading: operationIsLoading(.stageAll)
                            ) {
                                performOperation(.stageAll, model.stageAll)
                            },
                        ] : [],
                        actionsDisabled: model.isBusy
                    )
                    if !changesCollapsed {
                        changedFileRows(filteredChangedEntries, kind: .unstaged)
                    }
                }
                if filterText.isEmpty, !model.recentCommits.isEmpty {
                    GitSectionHeader(
                        title: String(localized: "RECENT COMMITS", table: "Sidebar"),
                        count: model.recentCommits.count,
                        isCollapsed: $historyCollapsed,
                        actions: [],
                        actionsDisabled: model.isBusy
                    )
                    if !historyCollapsed {
                        RecentCommitsView(
                            commits: model.recentCommits,
                            expandedCommitIDs: $expandedCommitIDs,
                            collapsedFolders: collapsedFoldersBinding,
                            viewMode: settings.gitViewMode,
                            fontScale: sidebarFontScale,
                            hasMoreCommits: model.hasMoreRecentCommits,
                            isLoadingMore: model.isLoadingMoreCommits,
                            loadMore: model.loadMoreCommits,
                            openDiff: openCommitDiff
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func changedFileRows(
        _ entries: [GitStatusModel.Entry], kind: GitEntryRow.Kind
    ) -> some View {
        if settings.gitViewMode == .tree {
            let files = entries.map { entry in
                TreeDisplayModel.Row(name: entry.fileName, path: entry.path, isDirectory: false,
                                     status: .init(entryStatus(entry, kind: kind)))
            }
            let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            ForEach(TreeDisplayModel.pathRows(files, section: kind.rawValue, collapsed: collapsedFolders)) { item in
                if item.isDirectory {
                    TreeFolderRow(row: item, scale: sidebarFontScale) {
                        model.toggleCollapsedFolder(kind.rawValue + ":" + item.path)
                    }
                } else if let entry = byPath[item.path] {
                    row(entry, kind: kind, showDirectory: false, displayRow: item)
                }
            }
        } else {
            ForEach(entries, id: \.path) { entry in
                row(entry, kind: kind)
            }
        }
    }

    private func entryStatus(_ entry: GitStatusModel.Entry, kind: GitEntryRow.Kind) -> Character {
        switch kind {
        case .merge: "U"
        case .staged: entry.staged
        case .unstaged: entry.unstaged
        }
    }

    private var filteredMergeEntries: [GitStatusModel.Entry] {
        model.mergeEntries.filter(matchesFilter)
    }

    private var filteredStagedEntries: [GitStatusModel.Entry] {
        model.stagedEntries.filter(matchesFilter)
    }

    private var filteredChangedEntries: [GitStatusModel.Entry] {
        model.changedEntries.filter(matchesFilter)
    }

    private var visibleChangeCount: Int {
        filteredMergeEntries.count + filteredStagedEntries.count + filteredChangedEntries.count
    }

    private func matchesFilter(_ entry: GitStatusModel.Entry) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || entry.path.localizedCaseInsensitiveContains(query)
    }

    private var cleanState: some View {
        inlinePlaceholder(
            icon: model.ahead > 0 || model.behind > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle",
            text: model.ahead > 0 || model.behind > 0
                ? String(localized: "Working tree clean, sync is pending", table: "Sidebar")
                : String(localized: "Working tree clean", table: "Sidebar")
        )
    }

    private func row(
        _ entry: GitStatusModel.Entry, kind: GitEntryRow.Kind,
        showDirectory: Bool = true, displayRow: TreeDisplayModel.Row? = nil
    ) -> some View {
        let stageTrigger = OperationTrigger.entry(path: entry.path, operation: .stage)
        let unstageTrigger = OperationTrigger.entry(path: entry.path, operation: .unstage)
        let discardTrigger = OperationTrigger.entry(path: entry.path, operation: .discard)
        return GitEntryRow(
            entry: entry,
            displayRow: displayRow ?? TreeDisplayModel.Row(
                name: entry.fileName, path: entry.path, isDirectory: false,
                status: .init(entryStatus(entry, kind: kind))
            ),
            kind: kind,
            showDirectory: showDirectory,
            isRemote: remoteName != nil,
            disabled: model.isBusy,
            isStageLoading: operationIsLoading(stageTrigger),
            isUnstageLoading: operationIsLoading(unstageTrigger),
            isDiscardLoading: operationIsLoading(discardTrigger),
            openDiff: {
                guard model.isCurrent(entry) else { return }
                var diffEntry = entry
                if kind == .unstaged && (entry.staged == "R" || entry.staged == "C") {
                    // A staged rename/copy's unstaged side compares the
                    // destination in the index with that same worktree path.
                    diffEntry.origPath = nil
                }
                openDiff(diffEntry, kind == .staged)
            },
            openFile: { openIfPossible(entry) },
            openToSide: { openIfPossible(entry, toSide: true) },
            stage: { performOperation(stageTrigger) { model.stage(entry) } },
            unstage: { performOperation(unstageTrigger) { model.unstage(entry) } },
            discard: {
                if remoteName == nil {
                    pendingDiscard = makePendingDiscard(entry)
                } else {
                    prepareRemoteDiscard([entry], all: false)
                }
            },
            absolutePath: model.absolutePath(for: entry),
            copyRelativePath: { copyToPasteboard(entry.path) },
            insertInTerminal: session.map { session in
                { session.sendCommand(shellQuoted(model.absolutePath(for: entry)) + " ") }
            }
        )
    }

    private func openIfPossible(_ entry: GitStatusModel.Entry, toSide: Bool = false) {
        guard model.isCurrent(entry) else { return }
        let path = model.absolutePath(for: entry)
        guard remoteName != nil || FileManager.default.fileExists(atPath: path) else { return }
        if toSide {
            openToSide(path)
        } else {
            openFile(path)
        }
    }

    /// The machine a discard would act on, or nil while local.
    private var remoteName: String? {
        sshHost ?? session?.location.remoteConnection?.displayName
    }

    private func discardTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return "" }
        // There is no Trash on the remote: these files are deleted outright,
        // so the confirmation says so and names the full path.
        if let remoteName {
            if entry.isUntracked {
                return String(
                    localized: "Delete \(entry.path) on \(remoteName)? A remote file is deleted outright, not moved to the Trash.", table: "Sidebar",
                    comment: "Remote discard confirmation. The placeholders are a repository-relative path and a remote machine as user@host."
                )
            }
            if entry.isWorktreeRename, let original = entry.origPath {
                return String(
                    localized: "Undo this rename? \(entry.path) is deleted on \(remoteName) and \(original) is restored.", table: "Sidebar",
                    comment: "Remote rename discard confirmation. The placeholders are the new path, a remote machine as user@host, and the old path."
                )
            }
            if entry.isWorktreeCopy {
                return String(
                    localized: "Discard this copy? \(entry.path) is deleted on \(remoteName), not moved to the Trash.", table: "Sidebar",
                    comment: "Remote copy discard confirmation. The placeholders are a path and a remote machine as user@host."
                )
            }
        }
        if entry.isUntracked {
            return String(
                localized: "Delete \(entry.fileName)? Its contents will move to the Trash.", table: "Sidebar",
                comment: "Discard confirmation. The placeholder is an untracked file name."
            )
        }
        if entry.isWorktreeRename, let original = entry.origPath {
            return String(
                localized: "Undo this rename? \(entry.fileName) will move to the Trash and \((original as NSString).lastPathComponent) will be restored.", table: "Sidebar",
                comment: "Rename discard confirmation. The placeholders are the new and old file names."
            )
        }
        if entry.isWorktreeCopy {
            return String(
                localized: "Discard this copy? \(entry.fileName) will move to the Trash.", table: "Sidebar",
                comment: "Copy discard confirmation. The placeholder is a file name."
            )
        }
        return String(
            localized: "Discard changes in \(entry.fileName)?", table: "Sidebar",
            comment: "Discard confirmation. The placeholder is a file name."
        )
    }

    private func discardActionTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return String(localized: "Discard Changes", table: "Sidebar") }
        if entry.isUntracked || entry.isWorktreeCopy {
            return remoteName == nil
                ? String(localized: "Move to Trash", table: "Sidebar")
                : String(localized: "Delete", table: "Sidebar")
        }
        if entry.isWorktreeRename { return String(localized: "Undo Rename", table: "Sidebar") }
        return String(localized: "Discard Changes", table: "Sidebar")
    }

    private var discardAllTitle: String {
        guard let remoteName else {
            return String(
                localized: "Discard the \(pendingDiscardAll.count) reviewed changes? Untracked and moved files go to the Trash.", table: "Sidebar",
                comment: "Discard-all confirmation. The placeholder is a number of changes."
            )
        }
        return String(
            localized: "Discard the \(pendingDiscardAll.count) reviewed changes? Untracked and moved files are deleted outright on \(remoteName), not moved to the Trash.", table: "Sidebar",
            comment: "Remote discard-all confirmation. The placeholders are a number of changes and a remote machine as user@host."
        )
    }

    private func makePendingDiscard(_ entry: GitStatusModel.Entry) -> PendingDiscard {
        var paths = [entry.path]
        if entry.isWorktreeRename, let original = entry.origPath {
            paths.append(original)
        }
        return PendingDiscard(
            entry: entry,
            fingerprints: Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, fileFingerprint(at: absolutePath(path, for: entry)))
            }),
            branch: model.branch,
            headOID: model.headOID,
            scope: model.currentScope
        )
    }

    private func discardSnapshotIsCurrent(_ pending: PendingDiscard) -> Bool {
        model.isCurrent(pending.entry)
            && model.currentScope == pending.scope
            && model.branch == pending.branch
            && model.headOID == pending.headOID
            && model.changedEntries.contains(pending.entry)
            && pending.fingerprints.allSatisfy { path, fingerprint in
                fileFingerprint(at: absolutePath(path, for: pending.entry)) == fingerprint
            }
    }

    private func absolutePath(_ path: String, for entry: GitStatusModel.Entry) -> String {
        let root = entry.repositoryRoot.isEmpty ? model.repoRoot : entry.repositoryRoot
        return (root as NSString).appendingPathComponent(path)
    }

    private func fileFingerprint(at path: String) -> FileFingerprint {
        let fm = FileManager.default
        let linkDestination = try? fm.destinationOfSymbolicLink(atPath: path)
        guard linkDestination != nil || fm.fileExists(atPath: path) else {
            return FileFingerprint(
                exists: false, size: 0, modificationDate: nil,
                fileNumber: nil, symbolicLinkDestination: nil
            )
        }
        let attributes = try? fm.attributesOfItem(atPath: path)
        return FileFingerprint(
            exists: true,
            size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes?[.modificationDate] as? Date,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
            symbolicLinkDestination: linkDestination
        )
    }

    private func requestDiscardAll() {
        if remoteName != nil {
            prepareRemoteDiscard(model.changedEntries, all: true)
        } else {
            pendingDiscardAll = model.changedEntries.map(makePendingDiscard)
            confirmDiscardAll = !pendingDiscardAll.isEmpty
        }
    }

    private var remoteBackend: WorkspaceBackend? {
        if let sshHost { return SSHHostWorkspaces.backend(for: sshHost) }
        return session?.location.remoteConnection?.workspaceBackend
    }

    private func remoteFingerprint(at path: String, backend: WorkspaceBackend) async throws -> FileFingerprint {
        guard let stat = try await backend.stat(path: path) else {
            return FileFingerprint(
                exists: false, size: 0, modificationDate: nil,
                fileNumber: nil, symbolicLinkDestination: nil
            )
        }
        let target = stat.isSymlink
            ? try await backend.readSymlinkDestination(path: path) : nil
        return FileFingerprint(
            exists: true, size: UInt64(max(0, stat.size)), modificationDate: stat.mtime,
            fileNumber: nil, symbolicLinkDestination: target
        )
    }

    private func remotePendingDiscard(_ entry: GitStatusModel.Entry,
                                      backend: WorkspaceBackend) async throws -> PendingDiscard {
        var paths = [entry.path]
        if entry.isWorktreeRename, let original = entry.origPath { paths.append(original) }
        var fingerprints: [String: FileFingerprint] = [:]
        for path in paths {
            fingerprints[path] = try await remoteFingerprint(
                at: absolutePath(path, for: entry), backend: backend
            )
        }
        return PendingDiscard(
            entry: entry, fingerprints: fingerprints,
            branch: model.branch, headOID: model.headOID,
            scope: model.currentScope
        )
    }

    private func remoteDiscardSnapshotIsCurrent(_ pending: PendingDiscard) async -> Bool {
        guard let backend = remoteBackend,
              model.currentScope == pending.scope,
              model.isCurrent(pending.entry),
              model.branch == pending.branch,
              model.headOID == pending.headOID,
              model.changedEntries.contains(pending.entry)
        else { return false }
        for (path, fingerprint) in pending.fingerprints {
            guard let current = try? await remoteFingerprint(
                at: absolutePath(path, for: pending.entry), backend: backend
            ), current == fingerprint else { return false }
        }
        return model.currentScope == pending.scope && model.isCurrent(pending.entry)
    }

    private func prepareRemoteDiscard(_ entries: [GitStatusModel.Entry], all: Bool) {
        guard !preparingDiscard, let backend = remoteBackend, !entries.isEmpty else { return }
        preparingDiscard = true
        let scope = model.currentScope
        Task {
            defer { preparingDiscard = false }
            do {
                var snapshots: [PendingDiscard] = []
                for entry in entries {
                    snapshots.append(try await remotePendingDiscard(entry, backend: backend))
                }
                guard model.currentScope == scope,
                      entries.allSatisfy(model.isCurrent) else { return }
                if all {
                    pendingDiscardAll = snapshots
                    confirmDiscardAll = true
                } else {
                    pendingDiscard = snapshots.first
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Could not verify remote files", table: "Sidebar")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: Bits

    private func performOperation(_ trigger: OperationTrigger, _ action: () -> Void) {
        operationExpanded = false
        operationTrigger = trigger
        action()
        if !model.isBusy { operationTrigger = nil }
    }

    private func operationIsLoading(_ trigger: OperationTrigger) -> Bool {
        model.isBusy && operationTrigger == trigger
    }

    private func operationProgressView() -> some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 11, height: 11)
            .accessibilityHidden(true)
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .sidebarFont(size: 24, weight: .light)
                .foregroundStyle(.quaternary)
            Text(verbatim: text)
                .sidebarFont(size: 11)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func inlinePlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .sidebarFont(size: 18, weight: .light)
                .foregroundStyle(.quaternary)
            Text(verbatim: text)
                .sidebarFont(size: 10.5)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
    }

    private var notRepository: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .sidebarFont(size: 24, weight: .light)
                .foregroundStyle(.quaternary)
            VStack(spacing: 2) {
                Text(String(localized: "No Git Repository", table: "Sidebar"))
                    .sidebarFont(size: 11.5, weight: .medium)
                Text(String(localized: "Initialize the terminal’s current directory to start tracking changes.", table: "Sidebar"))
                    .sidebarFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Button {
                performOperation(.initializeRepository) {
                    model.initializeRepository()
                }
            } label: {
                HStack(spacing: 5) {
                    if operationIsLoading(.initializeRepository) {
                        operationProgressView()
                    }
                    Text(String(localized: "Initialize Repository", table: "Sidebar"))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color(nsColor: Theme.accent))
            .disabled(model.rootPath.isEmpty || model.isBusy)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private func statusFailure(_ message: String) -> some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .sidebarFont(size: 24, weight: .light)
                .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.36))
            VStack(spacing: 3) {
                Text(String(localized: "Git Status Unavailable", table: "Sidebar"))
                    .sidebarFont(size: 11.5, weight: .medium)
                Text(verbatim: message)
                    .sidebarFont(size: 10, design: .monospaced)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
            Button(String(localized: "Retry", table: "Sidebar")) { model.refresh() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy || model.isResolvingInitialStatus)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func badge(_ text: String, label: String) -> some View {
        Text(verbatim: text)
            .sidebarFont(size: 10, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .accessibilityLabel(label)
    }

    private func copyChangedPaths() {
        let paths = Set(
            (model.mergeEntries + model.stagedEntries + model.changedEntries).map(\.path)
        ).sorted()
        copyToPasteboard(paths.joined(separator: "\n"))
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func resetRepositoryDrafts() {
        commitMessage = ""
        filterText = ""
        showFilter = false
        operationExpanded = false
        operationTrigger = nil
        pendingDiscard = nil
        pendingDiscardAll = []
        confirmDiscardAll = false
        mergeCollapsed = false
        stagedCollapsed = false
        changesCollapsed = false
        historyCollapsed = false
        expandedCommitIDs.removeAll()
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class NonemptyTextFieldValidator: NSObject, NSTextFieldDelegate {
    private weak var button: NSButton?

    init(button: NSButton) {
        self.button = button
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        button?.isEnabled = !field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}

private struct GitSectionHeader: View {
    struct Action: Identifiable {
        let id = UUID()
        let systemImage: String
        let help: String
        let isLoading: Bool
        let perform: () -> Void

        init(
            systemImage: String,
            help: String,
            isLoading: Bool = false,
            perform: @escaping () -> Void
        ) {
            self.systemImage = systemImage
            self.help = help
            self.isLoading = isLoading
            self.perform = perform
        }
    }

    let title: String
    let count: Int
    @Binding var isCollapsed: Bool
    let actions: [Action]
    var actionsDisabled = false
    /// When set, a small "?" after the title opens this in a popover.
    var helpText: String?

    @State private var isHovering = false
    @State private var isShowingHelp = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isCollapsed.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .sidebarFont(size: 7, weight: .semibold)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(title)
                        .sidebarFont(size: 9.5, weight: .medium)
                }
                .foregroundStyle(Color.secondary.opacity(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

            if let helpText {
                Button {
                    isShowingHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .sidebarFont(size: 9)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "About \(title)", table: "Sidebar"))
                .popover(isPresented: $isShowingHelp, arrowEdge: .bottom) {
                    Text(helpText)
                        .sidebarFont(size: 11)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 230, alignment: .leading)
                        .padding(12)
                }
            }

            ForEach(actions) { action in
                Button(action: action.perform) {
                    Group {
                        if action.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: action.systemImage)
                                .sidebarFont(size: 9, weight: .medium)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .contentShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .disabled(actionsDisabled)
                .opacity(action.isLoading ? 1 : (actionsDisabled ? 0.3 : (isHovering ? 1 : 0.55)))
                .help(action.help)
                .accessibilityLabel(
                    action.isLoading
                        ? String(localized: "\(action.help), in progress", table: "Sidebar")
                        : action.help
                )
            }

            Spacer(minLength: 0)

            if count > 0 {
                Text(String(localized: "\(count)", table: "Sidebar"))
                    .sidebarFont(size: 9, weight: .medium)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        // Fixed height so the taller hover buttons don't grow the header.
        .frame(height: 16)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .onHover { isHovering = $0 }
        .contextMenu {
            ForEach(actions) { action in
                Button(action.help, action: action.perform)
                    .disabled(actionsDisabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(title), \(count) items", table: "Sidebar"))
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }
}

private struct GitEntryRow: View {
    enum Kind: String {
        case merge, staged, unstaged
    }

    let entry: GitStatusModel.Entry
    let displayRow: TreeDisplayModel.Row
    let kind: Kind
    let showDirectory: Bool
    /// Whether this repository is on another machine, where discarding an
    /// untracked or copied file deletes it rather than moving it to the Trash.
    let isRemote: Bool
    let disabled: Bool
    let isStageLoading: Bool
    let isUnstageLoading: Bool
    let isDiscardLoading: Bool
    let openDiff: () -> Void
    let openFile: () -> Void
    let openToSide: () -> Void
    let stage: () -> Void
    let unstage: () -> Void
    let discard: () -> Void
    let absolutePath: String
    let copyRelativePath: () -> Void
    let insertInTerminal: (() -> Void)?

    @Environment(\.sidebarFontScale) private var fontScale

    var body: some View {
        TreeFileRow(
            row: displayRow,
            scale: fontScale, iconPath: absolutePath,
            directory: showDirectory ? entry.directory : nil,
            accessibilityHint: kind == .merge
                ? String(localized: "Opens conflict changes", table: "Sidebar")
                : String(localized: "Opens changes", table: "Sidebar"),
            open: openDiff
        ) { active in
            if !disabled || isStageLoading || isUnstageLoading || isDiscardLoading {
                hoverActions
                    .opacity(isStageLoading || isUnstageLoading || isDiscardLoading
                             ? 1 : (active ? 1 : 0.55))
            }
        }
        .contextMenu { menu }
    }

    private var hoverActions: some View {
        HStack(spacing: 0) {
            switch kind {
            case .merge:
                rowButton(
                    "plus",
                    help: String(localized: "Mark Resolved (Stage)", table: "Sidebar"),
                    isLoading: isStageLoading,
                    action: stage
                )
            case .staged:
                rowButton(
                    "minus",
                    help: String(localized: "Unstage Changes", table: "Sidebar"),
                    isLoading: isUnstageLoading,
                    action: unstage
                )
            case .unstaged:
                rowButton(
                    "arrow.uturn.backward",
                    help: String(localized: "Discard Changes", table: "Sidebar"),
                    isLoading: isDiscardLoading,
                    action: discard
                )
                rowButton(
                    "plus",
                    help: String(localized: "Stage Changes", table: "Sidebar"),
                    isLoading: isStageLoading,
                    action: stage
                )
            }
        }
    }

    private func rowButton(
        _ systemImage: String,
        help: String,
        isLoading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: systemImage)
                        .sidebarFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: TreeRowStyle.rowHeight(fontScale))
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(
            isLoading ? String(localized: "\(help), in progress", table: "Sidebar") : help
        )
    }

    @ViewBuilder
    private var menu: some View {
        if kind == .merge {
            Button(String(localized: "Open Changes", table: "Sidebar")) { openDiff() }
            Button(String(localized: "Open Conflicted File", table: "Sidebar")) { openFile() }
        } else {
            Button(String(localized: "Open Changes", table: "Sidebar")) { openDiff() }
            Button(String(localized: "Open File", table: "Sidebar")) { openFile() }
        }
        Button(String(localized: "Open File to the Side", table: "Sidebar")) { openToSide() }
        Divider()
        switch kind {
        case .merge:
            Button(String(localized: "Mark Resolved (Stage)", table: "Sidebar")) { stage() }
                .disabled(disabled)
        case .staged:
            Button(String(localized: "Unstage Changes", table: "Sidebar")) { unstage() }
                .disabled(disabled)
        case .unstaged:
            Button(String(localized: "Stage Changes", table: "Sidebar")) { stage() }
                .disabled(disabled)
            Button(destructiveMenuTitle) { discard() }
                .disabled(disabled)
        }
        Divider()
        if !isRemote {
            Button(String(localized: "Reveal in Finder", table: "Sidebar")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
            }
        }
        Button(String(localized: "Copy Path", table: "Sidebar")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(absolutePath, forType: .string)
        }
        Button(String(localized: "Copy Relative Path", table: "Sidebar")) { copyRelativePath() }
        if let insertInTerminal {
            Button(String(localized: "Insert Absolute Path in Terminal", table: "Sidebar")) { insertInTerminal() }
        }
    }

    private var destructiveMenuTitle: String {
        if entry.isUntracked || entry.isWorktreeCopy {
            return isRemote
                ? String(localized: "Delete…", table: "Sidebar")
                : String(localized: "Move to Trash…", table: "Sidebar")
        }
        if entry.isWorktreeRename { return String(localized: "Undo Rename…", table: "Sidebar") }
        return String(localized: "Discard Changes…", table: "Sidebar")
    }

}

// MARK: - Info panel

/// Session dashboard: working directory (with reveal/open/copy actions),
/// processes running under the shell, and ports they are listening on.
private struct InfoPanel: View {
    @ObservedObject var model: SessionInfoModel
    @ObservedObject private var themeChanges = Theme.changes
    let session: TerminalSession?
    let sshHost: String?
    /// The remote session's open forwards. Nil while local, where a listening
    /// port is already reachable on this Mac.
    var forwards: PortForwardController?

    @State private var currentDirectoryCollapsed = false
    @State private var projectDirectoryCollapsed = false
    @State private var processesCollapsed = false
    @State private var portsCollapsed = false

    private static let vsCodeURL = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")

    /// Whether these directories live on another machine. Finder and VS Code
    /// would otherwise open whatever sits at the same path locally.
    private var isRemote: Bool {
        sshHost != nil || session?.location.remoteConnection != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    currentDirectorySection
                    projectDirectorySection
                    processesSection
                    portsSection
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .sidebarFont(size: 11, weight: .medium)
                .foregroundStyle(Color(nsColor: Theme.accent))
            PanelHeader(
                title: session == nil
                    ? String(localized: "Project", table: "Sidebar")
                    : (model.shellName.isEmpty
                        ? String(localized: "Session", table: "Sidebar") : model.shellName),
                subtitle: model.shellPid > 0 ? "pid \(String(model.shellPid))" : nil
            )
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .sidebarFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Refresh", table: "Sidebar"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: Directories

    /// Hidden while the shell sits at the project root — it earns its row
    /// once the cwd diverges from the directory the panels anchor to.
    @ViewBuilder
    private var currentDirectorySection: some View {
        if model.rootPath != model.projectRootPath {
            GitSectionHeader(
                title: String(localized: "CURRENT DIRECTORY", table: "Sidebar"), count: 0,
                isCollapsed: $currentDirectoryCollapsed, actions: []
            )
            if !currentDirectoryCollapsed {
                directoryGroup(path: model.rootPath)
            }
        }
    }

    @ViewBuilder
    private var projectDirectorySection: some View {
        if !model.projectRootPath.isEmpty {
            GitSectionHeader(
                title: projectDirectoryTitle,
                count: 0,
                isCollapsed: $projectDirectoryCollapsed, actions: [],
                helpText: String(localized: "Files and Git anchor to this directory. When automatic, it follows the closest Git repository containing the shell’s current directory, or the one the terminal’s foreground job moved to — a coding agent that switched to its own worktree. A directory set manually from the project’s context menu is always used as-is.", table: "Sidebar")
            )
            if !projectDirectoryCollapsed {
                directoryGroup(path: model.projectRootPath)
            }
        }
    }

    /// Names the rule behind the project directory: a root taken from the
    /// foreground job says so rather than passing itself off as the shell's
    /// own repository.
    private var projectDirectoryTitle: String {
        switch model.projectRootSource {
        case .pinned:
            return String(localized: "PROJECT DIRECTORY", table: "Sidebar")
        case .shell:
            return String(localized: "PROJECT DIRECTORY (AUTO)", table: "Sidebar")
        case .foreground(let isWorktree):
            return isWorktree
                ? String(localized: "PROJECT DIRECTORY (WORKTREE)", table: "Sidebar")
                : String(localized: "PROJECT DIRECTORY (JOB)", table: "Sidebar")
        }
    }

    /// Path line plus Finder / VS Code / Copy actions, shared by both
    /// directory sections.
    private func directoryGroup(path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: path)
                .sidebarFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(path)
                .contextMenu {
                    Button(String(localized: "Copy Path", table: "Sidebar")) { copyPath(path) }
                }

            HStack(spacing: 4) {
                if !isRemote {
                    actionButton("Finder", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)]
                        )
                    }
                }
                if !isRemote, let vsCode = Self.vsCodeURL {
                    actionButton("VS Code", systemImage: "chevron.left.forwardslash.chevron.right") {
                        NSWorkspace.shared.open(
                            [URL(fileURLWithPath: path)],
                            withApplicationAt: vsCode,
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    }
                }
                actionButton(String(localized: "Copy", table: "Sidebar"), systemImage: "doc.on.doc") {
                    copyPath(path)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    /// Locally a listening port is already reachable here. On a remote it is
    /// not, so "open" means forward it to a loopback port first and open that.
    /// Never automatic: this only runs because someone clicked the row.
    private func openPort(_ port: SessionInfoModel.PortItem) {
        guard isRemote else {
            if let url = port.url { NSWorkspace.shared.open(url) }
            return
        }
        withForwardedURL(port) { NSWorkspace.shared.open($0) }
    }

    private func copyPortURL(_ port: SessionInfoModel.PortItem) {
        guard isRemote else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("http://localhost:\(port.port)", forType: .string)
            return
        }
        withForwardedURL(port) { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    /// Forwards `port` if it is not already, then hands over the loopback URL
    /// it is reachable on. Asking twice reuses the same forward.
    private func withForwardedURL(
        _ port: SessionInfoModel.PortItem, then use: @escaping (URL) -> Void
    ) {
        guard let forwards else { return }
        Task {
            do {
                let localPort = try await forwards.forward(remotePort: port.port)
                guard let url = URL(string: "http://127.0.0.1:\(localPort)/") else { return }
                use(url)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(
                    localized: "Couldn’t forward port \(port.port).", table: "Sidebar",
                    comment: "Remote port forward failure. The placeholder is a port number."
                )
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func actionButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .sidebarFont(size: 9, weight: .medium)
                Text(verbatim: title)
                    .sidebarFont(size: 10, weight: .medium)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(systemImage == "doc.on.doc"
            ? String(localized: "Copy Path", table: "Sidebar")
            : String(localized: "Open in \(title)", table: "Sidebar"))
    }

    // MARK: Processes

    @ViewBuilder
    private var processesSection: some View {
        GitSectionHeader(
            title: String(localized: "PROCESSES", table: "Sidebar"),
            count: model.processes.count,
            isCollapsed: $processesCollapsed,
            actions: []
        )
        if !processesCollapsed {
            if model.processes.isEmpty {
                emptyRow(String(localized: "No running processes", table: "Sidebar"))
            } else {
                ForEach(model.processes) { process in
                    InfoProcessRow(process: process) { force in
                        Task { await model.kill(process.pid, force: force) }
                    }
                }
            }
        }
    }

    // MARK: Ports

    @ViewBuilder
    private var portsSection: some View {
        GitSectionHeader(
            title: String(localized: "PORTS", table: "Sidebar"),
            count: model.ports.count,
            isCollapsed: $portsCollapsed,
            actions: []
        )
        if !portsCollapsed {
            if model.ports.isEmpty {
                emptyRow(String(localized: "No listening ports", table: "Sidebar"))
            } else {
                ForEach(model.ports) { port in
                    InfoPortRow(
                        port: port,
                        localPort: forwards?.localPort(forRemote: port.port),
                        isRemote: isRemote,
                        open: { openPort(port) },
                        copyURL: { copyPortURL(port) },
                        kill: { force in
                            Task { await model.kill(port.pid, force: force) }
                        }
                    )
                }
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .sidebarFont(size: 11)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct InfoProcessRow: View {
    let process: SessionInfoModel.ProcessItem
    let kill: (_ force: Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(red: 0.25, green: 0.73, blue: 0.31))
                .frame(width: 5, height: 5)
            Text(process.name)
                .sidebarFont(size: 11.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
                .help(process.executable)
            Text(String(process.pid))
                .sidebarFont(size: 10, design: .monospaced)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if isHovering {
                Button {
                    kill(false)
                } label: {
                    Image(systemName: "xmark")
                        .sidebarFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Terminate Process", table: "Sidebar"))
            } else {
                Text(String(localized: "\(process.cpu, format: .number.precision(.fractionLength(0)))% · \(process.memoryLabel)", table: "Sidebar"))
                    .sidebarFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        // Fixed height so the taller hover button doesn't grow the row.
        .frame(height: 16)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(String(localized: "Terminate", table: "Sidebar")) { kill(false) }
            Button(String(localized: "Force Kill", table: "Sidebar")) { kill(true) }
            Divider()
            Button(String(localized: "Copy PID", table: "Sidebar")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(process.pid)", forType: .string)
            }
            Button(String(localized: "Copy Executable Path", table: "Sidebar")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(process.executable, forType: .string)
            }
        }
    }
}

private struct InfoPortRow: View {
    let port: SessionInfoModel.PortItem
    /// The loopback port this remote port is forwarded to, once it is.
    let localPort: Int?
    let isRemote: Bool
    let open: () -> Void
    let copyURL: () -> Void
    let kill: (_ force: Bool) -> Void

    @State private var isHovering = false

    /// What clicking the row reaches. A remote port that is not forwarded yet
    /// has no address to show until it is, so the label says so instead of
    /// naming one that would not answer.
    private var urlString: String {
        if let localPort { return "http://127.0.0.1:\(localPort)" }
        return isRemote
            ? String(localized: "Forward this port and open it", table: "Sidebar")
            : "http://localhost:\(port.port)"
    }

    /// The port cell: the remote number alone, or both numbers once forwarded
    /// to a different local port, so a mismatch is obvious. A forward on the
    /// same number, the usual case, needs no arrow.
    private var portLabel: String {
        guard let localPort, localPort != port.port else { return String(port.port) }
        return "\(port.port) → \(localPort)"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                Image(systemName: isRemote ? "arrow.left.arrow.right" : "network")
                    .sidebarFont(size: 9, weight: .medium)
                    .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
                    .frame(width: 12)
                Text(portLabel)
                    .sidebarFont(size: 11.5, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                Text(port.processName)
                    .sidebarFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHovering {
                    Image(systemName: "arrow.up.forward")
                        .sidebarFont(size: 9, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
            }
            // Fixed height to match the other sidebar rows.
            .frame(height: 16)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(isRemote && localPort == nil
                ? String(localized: "Forward and Open", table: "Sidebar")
                : String(localized: "Open in Browser", table: "Sidebar")) {
                open()
            }
            Button(String(localized: "Copy URL", table: "Sidebar")) { copyURL() }
            Divider()
            Button(String(localized: "Kill Process (\(port.processName))", table: "Sidebar")) { kill(false) }
        }
    }

    private var helpText: String {
        guard isRemote else { return String(localized: "Open \(urlString)", table: "Sidebar") }
        guard let localPort else {
            return String(
                localized: "Forward remote port \(port.port) to this Mac and open it", table: "Sidebar",
                comment: "Port row tooltip on a remote session. The placeholder is a port number."
            )
        }
        return String(
            localized: "Remote port \(port.port), open at http://127.0.0.1:\(localPort)/", table: "Sidebar",
            comment: "Port row tooltip once forwarded. The placeholders are the remote and local port numbers."
        )
    }
}

private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
