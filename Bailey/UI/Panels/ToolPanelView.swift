import AppKit
import Combine
import SwiftUI

/// Coalesces refreshes for one panel target; a different target must not wait
/// for an older SSH request to finish.
@MainActor
final class PanelSyncQueue {
    private struct Target: Equatable {
        let identity: PanelContext.Identity?
        let connectionRevision: UInt64
    }

    private var isRunning = false
    private var target: Target?
    private var generation: UInt = 0
    private var pendingBody: (() async -> Void)?
    private var activeTask: Task<Void, Never>?

    func run(
        for identity: PanelContext.Identity?, connectionRevision: UInt64 = 0,
        _ body: @escaping () async -> Void
    ) {
        let target = Target(identity: identity, connectionRevision: connectionRevision)
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
    @Environment(\.colorScheme) private var colorScheme
    let manager: WorkspaceWindowModel
    let git: GitStatusModel
    let panel: ToolPanel
    private let settings = AppSettings.shared
    private let themeChanges = Theme.changes
    @State private var applicationIsActive = NSApp.isActive
    private var filesTarget: PanelContext.Identity? {
        guard let project = manager.selectedProject,
              let context = project.panelContext else { return nil }
        return project.fileTree.syncedTarget(for: context)
    }
    @State private var syncQueue = PanelSyncQueue()
    @State private var watchedFileTree: FileTreeModel?
    @State private var watchedRemoteProject: Project?
    @State private var remoteWatcherMemberID = UUID()

    private struct RefreshTaskKey: Hashable {
        let active: Bool
        let gitPanel: Bool
        let gitScope: String
        let fileTarget: PanelContext.Identity?
    }

    private var refreshTaskKey: RefreshTaskKey {
        RefreshTaskKey(
            active: applicationIsActive, gitPanel: panel == .git,
            gitScope: git.currentScope,
            fileTarget: manager.selectedProject?.panelContext?.identity
        )
    }
    /// The remote heading. Held here rather than rebuilt, so its state and
    /// its lamp survive every panel switch and poll.
    @State private var remoteHeader = RemotePaneHeaderView(frame: .zero)
    /// Mirrors the heading's own state, because the layout above has to give
    /// back the row's height when the session is local.
    @State private var remoteHeaderState = RemotePaneHeaderState.local

    /// Git's terminal action can only target the selected project's machine.
    private var gitActionSession: TerminalSession? {
        guard let project = manager.selectedProject else { return nil }
        if project.sshHost == nil, project.selectedSession?.workspaceIdentity != nil {
            return nil
        }
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
        guard let target = filesTarget,
              case .file(let file)? = manager.selectedProject?.selectedTab?.content,
              file.workspaceIdentity == target.workspace else { return nil }
        return file.path
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
                        sshHost: project.sshHost,
                        currentFilePath: openFilePath,
                        openFile: { manager.openFile($0, activating: $1) },
                        isActive: project.dock.activeGroup?.selected == .files,
                        canFocusKeyboard: {
                            guard !manager.isCommandPaletteVisible,
                                  let files = project.dock.group(containing: .files) else { return false }
                            return project.dock.activeGroupID == files.id && files.selected == .files
                        },
                        onKeyboardAttached: {
                            manager.registerTreeResponder($0, for: .files, in: project)
                        },
                        renameFile: { [target = filesTarget] item, newName in
                            guard let target else { return nil }
                            return await manager.renameFile(
                                item, to: newName, in: project, target: target
                            )
                        },
                        onCommand: { [target = filesTarget] command in
                            guard let target else { return }
                            manager.performFileTreeCommand(
                                command, in: project, target: target, onChange: { git.refresh() }
                            )
                        },
                        refreshGitStatus: { git.refresh() },
                        isCurrentTarget: { [target = filesTarget] in
                            guard let target else { return false }
                            return manager.selectedProjectID == project.id
                                && project.matchesPanelTarget(target)
                        },
                        canPasteFiles: { [target = filesTarget] in
                            guard let target else { return false }
                            return manager.canPasteFileTree(in: project, target: target)
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
                        },
                        beginDrag: { [target = filesTarget] item in
                            guard let target else { return nil }
                            return manager.beginFileTreeDrag(for: item, in: project, target: target)
                        },
                        endDrag: { project.fileTree.cancelDrag(nonce: $0) },
                        receiveInternalDrop: { [target = filesTarget] record, directory, copy in
                            guard let target else { return false }
                            return manager.receiveFileTreeDrop(
                                record, into: directory, copy: copy,
                                in: project, target: target, onChange: { git.refresh() }
                            )
                        }
                    )
                }
            case .git:
                GitPanel(
                    model: git,
                    manager: manager,
                    project: manager.selectedProject,
                    session: gitActionSession,
                    sshHost: manager.selectedProject?.sshHost,
                    openFile: { manager.openFile($0) },
                    openDiff: { entry, staged in
                        manager.openDiff(
                            repoRoot: git.repoRoot,
                            path: entry.path,
                            staged: staged,
                            untracked: entry.isUntracked,
                            origPath: entry.origPath,
                            activating: false
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
                            origPath: file.originalPath,
                            activating: false
                        )
                    }
                )
                .id(manager.selectedProject?.panelContext?.identity)
                .id(manager.selectedProject?.panelContext?.connectionRevision)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.terminal(dark: colorScheme == .dark).sidebarNSColor))
        .onAppear {
            updateLocalFileWatcher()
            updateRemoteFileWatcher()
            syncModels()
        }
        .onDisappear {
            stopLocalFileWatcher()
            stopRemoteFileWatcher()
        }
        .task(id: refreshTaskKey) {
            guard applicationIsActive else { return }
            if panel == .git {
                await git.runRemoteRefreshLoop()
                return
            }
            guard manager.selectedProject?.panelContext?.isRemote == true else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard applicationIsActive, !Task.isCancelled else { return }
                if manager.selectedProject?.remoteFileEvents.healthy != true
                    || manager.selectedProject?.fileTree.hasVisibleDirectorySymlinks == true {
                    syncModels()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            applicationIsActive = true
            updateLocalFileWatcher()
            updateRemoteFileWatcher()
            syncModels()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification
        )) { _ in
            applicationIsActive = false
            updateLocalFileWatcher()
            updateRemoteFileWatcher()
        }
        .onChange(of: commandCompletionSequences) {
            syncModels()
        }
        .onChange(of: manager.selectedProject?.panelContext?.identity) {
            updateLocalFileWatcher()
            updateRemoteFileWatcher()
            syncModels()
        }
        .onChange(of: manager.selectedProject?.fileTree.rootPath) {
            updateRemoteFileWatcher()
        }
        .onChange(of: panel) {
            updateLocalFileWatcher()
            updateRemoteFileWatcher()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: SSHHostWorkspaces.connectionChanged
        )) { notification in
            guard let host = notification.object as? String,
                  manager.selectedProject?.panelContext?.identity.workspace == "ssh:" + host else { return }
            updateRemoteFileWatcher()
            syncModels()
        }
        .environment(\.panelFontScale, panelFontScale)
        // Native button and control labels without a designed hierarchy use
        // the configured base size directly.
        .environment(\.font, .system(size: CGFloat(settings.panelFontSize)))
    }

    private func stopLocalFileWatcher() {
        watchedFileTree?.setLocalFileEventsEnabled(false, member: remoteWatcherMemberID)
        watchedFileTree = nil
    }

    private func updateLocalFileWatcher() {
        let nextTree: FileTreeModel? = panel == .files && applicationIsActive
            && manager.selectedProject?.panelContext?.isRemote == false
            ? manager.selectedProject?.fileTree : nil
        if watchedFileTree !== nextTree {
            watchedFileTree?.setLocalFileEventsEnabled(false, member: remoteWatcherMemberID)
            watchedFileTree = nextTree
        }
        nextTree?.setLocalFileEventsEnabled(true, member: remoteWatcherMemberID)
    }

    private func stopRemoteFileWatcher() {
        watchedRemoteProject?.remoteFileEvents.unsubscribe(id: remoteWatcherMemberID)
        watchedRemoteProject = nil
    }

    private func updateRemoteFileWatcher() {
        let project = manager.selectedProject
        let context = project?.panelContext
        let remoteProject: Project? = panel == .files && applicationIsActive
            && context?.isRemote == true && project?.sshHost != nil
            ? project : nil
        if watchedRemoteProject !== remoteProject {
            watchedRemoteProject?.remoteFileEvents.unsubscribe(id: remoteWatcherMemberID)
            watchedRemoteProject = remoteProject
        }
        guard let remoteProject, let context,
              let host = remoteProject.sshHost, !remoteProject.fileTree.rootPath.isEmpty else { return }
        remoteProject.remoteFileEvents.subscribe(
            id: remoteWatcherMemberID, project: remoteProject,
            host: host, root: remoteProject.fileTree.rootPath, context: context
        )
    }

    private func syncModels() {
        applyRemoteHeading()
        guard panel == .files else { return }
        let context = manager.selectedProject?.panelContext
        syncQueue.run(for: context?.identity,
                      connectionRevision: context?.connectionRevision ?? 0) {
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
        updateRemoteHeading(.local, directory: nil)
    }

    private func updateRemoteHeading(_ state: RemotePaneHeaderState, directory: String?) {
        if remoteHeaderState != state {
            remoteHeader.apply(state: state)
            remoteHeaderState = state
        }
        remoteHeader.workingDirectory = directory
    }

    private func performSync() async {
        guard let project = manager.selectedProject else { return }
        let wasSynced = project.panelContext.flatMap { project.fileTree.syncedTarget(for: $0) } != nil
        let synced = await project.syncFiles(isCurrent: { manager.selectedProject === project })
        if !wasSynced, synced != nil { manager.autoRevealActiveFile(in: project) }
    }
}
