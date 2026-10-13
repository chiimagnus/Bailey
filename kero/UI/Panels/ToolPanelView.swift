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
                        }
                    )
                }
            case .git:
                GitPanel(
                    model: git,
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
                            commitHash: commit.hash,
                            parentHash: commit.parentHash,
                            status: file.status,
                            origPath: file.originalPath
                        )
                    }
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
        // Files remain live while visible. Git is
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
        .onChange(of: manager.selectedProject?.panelContext?.identity) { syncModels() }
        // A connection appearing, connecting, dying or being replaced changes
        // what the heading says; repaint it without waiting for the next tick.
        .onChange(of: remoteConnectionToken) { syncModels() }
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

    /// The heading belonging to the current connection.
    /// Cheap and synchronous — it reads observed state and touches no
    /// workspace, so it stays correct while the panels are stalled.
    private func applyRemoteHeading() {
        guard let project = manager.selectedProject else {
            remoteHeaderState = .local
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
            return
        }
        if project.customDirectory != nil {
            remoteHeader.apply(state: .local)
            remoteHeaderState = .local
            return
        }
        guard let session = project.selectedSession else {
            remoteHeaderState = .local
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
        let backend = context.backend
        // Files and Git anchor to the project directory — pinned when the
        // user set one, else the repository the session is working in — so
        // they don't re-root as the terminal cds around a repo.
        // An agent that moves to its own worktree changes only its own
        // process directory, so the foreground job's cwd is passed in too.
        let (root, source) = await context.resolvedRoot()
        // The connection may have died while that was in flight; its answer
        // describes a workspace that is no longer the one on screen.
        guard project.matchesPanelTarget(context.identity),
              manager.selectedProjectID == project.id else { return }
        if rootSource != source { rootSource = source }
        switch panel {
        case .files:
            await project.fileTree.sync(root: root, backend: backend, scope: context.scope)
            if project.matchesPanelTarget(context.identity) { filesTarget = context.identity }
        case .git:
            break
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
