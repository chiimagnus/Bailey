import AppKit
import Combine
import SwiftUI

/// Coalesces refreshes for one panel target; a different target must not wait
/// for an older SSH request to finish.
@MainActor
final class PanelSyncQueue {
    private var isRunning = false
    private var target: PanelContext.Identity?
    private var generation: UInt = 0
    private var pendingBody: (() async -> Void)?
    private var activeTask: Task<Void, Never>?

    func run(for target: PanelContext.Identity?, _ body: @escaping () async -> Void) {
        if isRunning && self.target == target {
            pendingBody = body
            return
        }
        activeTask?.cancel()
        generation &+= 1
        let currentGeneration = generation
        self.target = target
        isRunning = true
        pendingBody = nil
        activeTask = Task { @MainActor in
            var currentBody = body
            while true {
                await currentBody()
                guard currentGeneration == generation else { return }
                guard let next = pendingBody else {
                    isRunning = false
                    activeTask = nil
                    return
                }
                pendingBody = nil
                currentBody = next
            }
        }
    }
}


/// Hosts the pane's AppKit remote heading across SwiftUI updates.
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

/// Renders one tool within a dock tab. Files and Git retain their
/// original models and actions regardless of where the tab is parked.
struct ToolPanelView: View {
    let manager: TerminalManager
    let git: GitStatusModel
    let panel: ToolPanel
    private let settings = AppSettings.shared
    private let themeChanges = Theme.changes
    @State private var applicationIsActive = NSApp.isActive
    /// Which rule produced the current panel root; drives the Files badge.
    @State private var rootSource = PanelContext.RootSource.shell
    @State private var filesTarget: PanelContext.Identity?
    @State private var syncQueue = PanelSyncQueue()
    /// The remote heading. Held here rather than rebuilt, so its state and
    /// its lamp survive every panel switch and poll.
    @State private var remoteHeader = RemotePaneHeaderView(frame: .zero)
    /// Mirrors the heading's own state, because the layout above has to give
    /// back the row's height when the session is local.
    @State private var remoteHeaderState = RemotePaneHeaderState.local

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

    private var openFilePath: String? {
        if case .file(let file)? = manager.selectedProject?.selectedTab?.content {
            return file.path
        }
        return nil
    }

    var body: some View {
        let _ = themeChanges.revision
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
                        onRename: { [workspace = project.workspaceIdentity] oldPath, newPath in
                            manager.fileRenamed(
                                from: oldPath, to: newPath, workspace: workspace
                            )
                        },
                        refreshGitStatus: { git.refresh() },
                        isCurrentTarget: { [target = filesTarget] in
                            guard let target else { return false }
                            return manager.selectedProjectID == project.id
                                && project.matchesPanelTarget(target)
                        },
                        canImportFromFinder: filesTarget?.workspace == nil
                            && project.workspaceBackend is LocalWorkspaceBackend,
                        importFromFinder: { [target = filesTarget] providers, directory in
                            guard let target, target.workspace == nil,
                                  manager.selectedProjectID == project.id,
                                  project.matchesPanelTarget(target) else { return false }
                            return FinderWindowDrop.receive(providers, preferred: manager) { urls, owner in
                                guard owner.selectedProjectID == project.id,
                                      project.matchesPanelTarget(target) else { return }
                                Task { @MainActor in
                                    let result = await project.fileTree.importFromFinder(
                                        urls, into: directory, isCurrentTarget: {
                                            owner.attachedWindow != nil
                                                && owner.selectedProjectID == project.id
                                                && project.matchesPanelTarget(target)
                                        }
                                    )
                                    if result?.copied.isEmpty == false { git.refresh() }
                                }
                            }
                        }
                    )
                }
            case .git:
                GitPanel(
                    model: git,
                    manager: manager,
                    project: manager.selectedProject,
                    session: fileActionSession,
                    sshHost: manager.selectedProject?.sshHost,
                    openFile: { manager.openFile($0) },
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
                            commitHash: file.fromStashUntracked
                                ? (commit.stash?.untrackedFilesHash ?? commit.hash) : commit.hash,
                            parentHash: file.fromStashUntracked ? nil : commit.parentHashes.first,
                            status: file.fromStashUntracked ? "A" : file.status,
                            origPath: file.originalPath
                        )
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.sidebar))
        .onAppear { syncModels() }
        .task(id: "\(applicationIsActive):\(panel):\(git.currentScope)") {
            guard applicationIsActive else { return }
            if panel == .git && git.currentScope == "local" { return }
            let interval: Duration = panel == .git ? .seconds(5) : .seconds(2)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard applicationIsActive else { return }
                if panel == .git {
                    // The local repository is event-driven; only SSH needs this poll.
                    guard git.currentScope != "local" else { return }
                    guard !git.isBusy else { continue }
                    // Keep the follow-up in this task so hiding the panel cancels it.
                    while git.isRefreshing && !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .milliseconds(250))
                        } catch {
                            return
                        }
                    }
                    guard applicationIsActive, !Task.isCancelled else { return }
                    if !git.isBusy { git.refresh() }
                } else {
                    syncModels()
                }
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
        .onChange(of: manager.selectedProject?.panelContext?.identity) { syncModels() }
        // A connection appearing, connecting, dying or being replaced changes
        // what the heading says; repaint it without waiting for the next tick.
        .onChange(of: remoteConnectionToken) { syncModels() }
        .onChange(of: manager.selectedProject?.selectedSession?.panelDirectoryPath) {
            applyRemoteHeading()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: SSHHostWorkspaces.connectionChanged
        )) { notification in
            guard notification.object as? String == manager.selectedProject?.sshHost else { return }
            applyRemoteHeading()
        }
        .environment(\.panelFontScale, panelFontScale)
        // Native button and control labels without a designed hierarchy use
        // the configured base size directly.
        .environment(\.font, .system(size: CGFloat(settings.panelFontSize)))
    }

    private func syncModels() {
        applyRemoteHeading()
        guard panel == .files else { return }
        syncQueue.run(for: manager.selectedProject?.panelContext?.identity) {
            await performSync()
        }
    }

    /// The heading belonging to the current connection.
    /// Cheap and synchronous — it reads observed state and touches no
    /// workspace, so it stays correct while the panels are stalled.
    private func applyRemoteHeading() {
        guard let project = manager.selectedProject else {
            updateRemoteHeading(.local, directory: nil)
            return
        }
        if let host = project.sshHost {
            let state: RemotePaneHeaderState
            switch SSHHostWorkspaces.connectionState(for: host) {
            case .some(true): state = .connected(destination: host)
            case .some(false): state = .disconnected(destination: host)
            case .none: state = .connecting(destination: host)
            }
            updateRemoteHeading(state, directory: project.customDirectory)
            return
        }
        if project.customDirectory != nil {
            updateRemoteHeading(.local, directory: nil)
            return
        }
        guard let session = project.selectedSession else {
            updateRemoteHeading(.local, directory: nil)
            return
        }
        // An automatically scoped project may still follow its terminal's
        // connection. A pinned project never does.
        let state = session.remoteHeaderState
        updateRemoteHeading(state, directory: state == .local ? nil : session.panelDirectoryPath)
    }

    private func updateRemoteHeading(_ state: RemotePaneHeaderState, directory: String?) {
        if remoteHeaderState != state {
            remoteHeader.apply(state: state)
            remoteHeaderState = state
        }
        remoteHeader.workingDirectory = directory
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
              let (source, target) = await project.syncFiles(in: manager),
              manager.selectedProject === project else { return }
        if rootSource != source { rootSource = source }
        if filesTarget != target { filesTarget = target }
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
