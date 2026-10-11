//
//  ToolPanelView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// Serialises tool-panel refreshes. Reading a panel costs a round trip
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
struct ToolPanelView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var git: GitStatusModel
    let panel: ToolPanel
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

    private var panelFontScale: CGFloat {
        CGFloat(settings.panelFontSize / AppSettings.defaultPanelFontSize)
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
                    fontScale: panelFontScale
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
        .environment(\.panelFontScale, panelFontScale)
        // Native button and control labels without a designed hierarchy use
        // the configured base size directly.
        .environment(\.font, .system(size: CGFloat(settings.panelFontSize)))
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
        guard let project = manager.selectedProject,
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
        switch panel {
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
                .panelFont(size: 11, weight: .medium)
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
                    .panelFont(size: 10, weight: .medium)
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
            PanelSectionHeader(
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
            PanelSectionHeader(
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
                .panelFont(size: 11)
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
                    .panelFont(size: 9, weight: .medium)
                Text(verbatim: title)
                    .panelFont(size: 10, weight: .medium)
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
        PanelSectionHeader(
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
        PanelSectionHeader(
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
            .panelFont(size: 11)
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
                .panelFont(size: 11.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
                .help(process.executable)
            Text(String(process.pid))
                .panelFont(size: 10, design: .monospaced)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if isHovering {
                Button {
                    kill(false)
                } label: {
                    Image(systemName: "xmark")
                        .panelFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Terminate Process", table: "Sidebar"))
            } else {
                Text(String(localized: "\(process.cpu, format: .number.precision(.fractionLength(0)))% · \(process.memoryLabel)", table: "Sidebar"))
                    .panelFont(size: 10)
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
                    .panelFont(size: 9, weight: .medium)
                    .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
                    .frame(width: 12)
                Text(portLabel)
                    .panelFont(size: 11.5, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                Text(port.processName)
                    .panelFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHovering {
                    Image(systemName: "arrow.up.forward")
                        .panelFont(size: 9, weight: .medium)
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
