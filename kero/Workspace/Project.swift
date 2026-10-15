//
//  Project.swift
//  kero
//

import AppKit
import Combine
import Foundation
import Observation

/// A project groups tabs and appears as one row in the left sidebar. Each tab
/// holds one terminal, file, browser, or diff; see
/// `PaneTab`. A project can have zero terminal sessions or tabs; closing the last
/// tab leaves the project open — only the explicit "Close Project" action (see
/// `TerminalManager.close(_:)`) removes it from the manager.
@MainActor
@Observable
final class Project: nonisolated Identifiable {
    nonisolated let id = UUID()

    /// User-assigned name; when nil the project title follows the
    /// selected session's terminal title.
    var customName: String? {
        didSet { if customName != oldValue { onSnapshotChange?() } }
    }
    /// User-pinned project directory ("Set Project Directory…" on the
    /// project row). When set, the file tree and git panels always anchor
    /// here. Nil means automatic: the closest git repository containing the
    /// selected session's working directory, re-derived as the session
    /// moves (see `panelRoot(followingSessionAt:)`).
    var customDirectory: String? {
        didSet { if customDirectory != oldValue { onSnapshotChange?() } }
    }
    /// Selected SSH host, if this sidebar root is remote.
    var sshHost: String? {
        didSet { if sshHost != oldValue { onSnapshotChange?() } }
    }
    /// An individually added file is anchored to its parent directory.
    var pinnedFile: String? {
        didSet { if pinnedFile != oldValue { onSnapshotChange?() } }
    }
    /// File browser state belongs to the project, not a transient tool tab.
    let fileTree = FileTreeModel()
    let dock: DockWorkspaceModel
    var tabs: [PaneTab] = [] {
        didSet {
            dock.syncTabs(tabs.map(\.id), near: selectedTabID)
            onSnapshotChange?()
        }
    }
    var selectedTabID: UUID? {
        didSet {
            guard selectedTabID != oldValue else { return }
            if let oldValue {
                tabs.first { $0.id == oldValue }?.content.autoSaveOnFocusLoss()
            }
            if let selectedTabID {
                recentTabIDs.removeAll { $0 == selectedTabID }
                recentTabIDs.insert(selectedTabID, at: 0)
                dock.select(.tab(selectedTabID))
            }
            onSnapshotChange?()
        }
    }

    /// Tab IDs newest-used first. Kept here rather than in the switcher
    /// because every way of reaching a tab — strip click, menu selection,
    /// opening a file — counts as a use.
    @ObservationIgnored private var recentTabIDs: [UUID] = []
    @ObservationIgnored private var isRemoteTabRebindPending = false
    @ObservationIgnored private var hostConnectionObservation: AnyCancellable?

    @ObservationIgnored var onSnapshotChange: (() -> Void)?
    private let fallbackName: String

    init(fallbackName: String, workspaceConfiguration: DockWorkspaceConfiguration) {
        self.fallbackName = fallbackName
        dock = DockWorkspaceModel(configuration: workspaceConfiguration)
        dock.onSnapshotChange = { [weak self] in self?.onSnapshotChange?() }
        hostConnectionObservation = NotificationCenter.default
            .publisher(for: SSHHostWorkspaces.connectionChanged)
            .sink { [weak self] notification in
                guard let self, let host = notification.object as? String, self.sshHost == host else { return }
                self.rebindRemoteTabs()
            }
    }

    var name: String {
        if let customName = Self.normalizedCustomName(customName) {
            return customName
        }
        guard let title = selectedSession?.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return fallbackName
        }
        return title
    }

    /// Manual project names are user-authored labels, not terminal protocol
    /// payloads. Normalize only surrounding whitespace.
    static func normalizedCustomName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Every terminal session across the project's independent tabs.
    var sessions: [TerminalSession] {
        tabs.compactMap { if case .session(let session) = $0.content { return session }; return nil }
    }

    var selectedTab: PaneTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Tabs by recency of use, selected first. Tabs not yet selected this
    /// session trail in strip order, so the sequence covers every tab even
    /// before any switching has happened.
    var tabsByRecency: [PaneTab] {
        var seen = Set<UUID>()
        var ordered: [PaneTab] = []
        func add(_ tab: PaneTab) {
            guard seen.insert(tab.id).inserted else { return }
            ordered.append(tab)
        }
        if let selectedTab { add(selectedTab) }
        for id in recentTabIDs {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            add(tab)
        }
        tabs.forEach(add)
        return ordered
    }

    /// Drops recorded recency, leaving strip order behind the selected tab.
    /// Restoring a window selects each tab as it is rebuilt; without this the
    /// order would just mirror the rebuild.
    func resetRecency() {
        recentTabIDs = selectedTabID.map { [$0] } ?? []
    }

    /// Content of the selected work tab.
    var focusedContent: PaneContent? {
        selectedTab?.content
    }

    var hasFiles: Bool {
        tabs.contains { $0.content.isFile }
    }

    var hasDiffs: Bool {
        tabs.contains { $0.content.isDiff }
    }

    /// Non-terminal tabs retain the session whose directory they were opened from.
    var selectedSession: TerminalSession? {
        if case .session(let session)? = focusedContent {
            return session
        }
        return selectedTab?.contextSession ?? sessions.first
    }

    // MARK: - Project directory

    var workspaceIdentity: String? {
        if let sshHost { return "ssh:" + sshHost }
        if customDirectory != nil { return nil }
        return selectedSession?.workspaceIdentity
    }

    var workspaceBackend: WorkspaceBackend {
        if let sshHost { return SSHHostWorkspaces.backend(for: sshHost) }
        if customDirectory != nil { return LocalWorkspaceBackend.shared }
        return selectedSession?.workspaceBackend ?? LocalWorkspaceBackend.shared
    }

    /// A pinned project is a workspace even without any shell. Automatic
    /// projects still follow their selected terminal when one exists.
    var panelContext: PanelContext? {
        if let directory = customDirectory {
            return PanelContext(
                identity: .pinned(project: id, workspace: workspaceIdentity, directory: directory),
                backend: workspaceBackend
            )
        }
        guard let session = selectedSession else { return nil }
        let connection = session.location.remoteConnection
        guard connection == nil || connection?.workingDirectory != nil else { return nil }
        return PanelContext(
            identity: .automatic(
                project: id, workspace: workspaceIdentity, directory: session.panelDirectoryPath,
                foreground: session.foregroundDirectoryPath, session: session.id,
                connection: connection?.id, state: connection?.state
            ),
            backend: workspaceBackend
        )
    }

    func matchesPanelTarget(_ identity: PanelContext.Identity) -> Bool {
        panelContext?.identity == identity
    }

    private func gitContents(repository: String, scope: String) -> [PaneContent] {
        let base = scope == "local" ? (repository as NSString).standardizingPath : repository
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return tabs.compactMap { tab in
            switch tab.content {
            case .file(let file):
                guard (file.workspaceIdentity ?? "local") == scope,
                      (scope == "local" ? (file.path as NSString).standardizingPath : file.path).hasPrefix(prefix) else { return nil }
            case .diff(let diff):
                guard (diff.workspaceIdentity ?? "local") == scope,
                      diff.repoRoot == repository,
                      (diff.source == .worktree || diff.source == .staged) else { return nil }
            case .session, .browser: return nil
            }
            return tab.content
        }
    }

    func saveBeforeGitAction(
        repository: String, scope: String, isCurrent: () -> Bool
    ) async -> Bool {
        let contents = gitContents(repository: repository, scope: scope)
        for content in contents {
            guard isCurrent() else { return false }
            await content.save()
            guard isCurrent(), !content.isDirty else { return false }
        }
        return isCurrent() && gitContents(repository: repository, scope: scope).allSatisfy {
            !$0.isDirty
        }
    }

    func canRunGitAction(repository: String, scope: String) -> Bool {
        gitContents(repository: repository, scope: scope).allSatisfy {
            guard !$0.isDirty else { return false }
            switch $0 {
            case .file(let file): return !file.isSaving
            case .diff(let diff): return !diff.isSaving
            case .session, .browser: return true
            }
        }
    }

    func reloadAfterGitAction(repository: String, scope: String) {
        for content in gitContents(repository: repository, scope: scope) {
            switch content {
            case .file(let file): file.reloadFromDiskIfClean()
            case .diff(let diff): diff.reload(afterGitAction: true)
            case .session, .browser: break
            }
        }
    }

    /// Synchronize the project's Files tree; only the latest active workspace
    /// may publish its root, and a disconnected shell retains the last tree.
    func syncFiles(in manager: TerminalManager) async -> (PanelContext.RootSource, PanelContext.Identity)? {
        guard manager.selectedProject === self,
              let context = panelContext else { return nil }
        if sshHost == nil, customDirectory == nil,
           selectedSession?.location.remoteConnection?.state == .disconnected { return nil }
        let (root, source) = await context.resolvedRoot()
        guard manager.selectedProject === self,
              matchesPanelTarget(context.identity) else { return nil }
        await fileTree.sync(root: root, backend: context.backend, scope: context.scope)
        guard manager.selectedProject === self,
              matchesPanelTarget(context.identity) else { return nil }
        return (source, context.identity)
    }

    /// Root for the file tree and git panels: the pinned directory when the
    /// user set one (and it still exists on disk), else the repository the
    /// terminal's foreground job moved to (an agent's worktree), else the
    /// closest git repository containing `cwd`, else `cwd` itself — the
    /// follow-the-terminal behavior used before projects had a directory.
    /// Everything but the pin is re-derived on every call, so the panels
    /// track the session in and out of repositories without sticking.
    func panelRoot(
        followingSessionAt cwd: String, foregroundAt foregroundCwd: String? = nil
    ) -> (root: String, source: PanelContext.RootSource) {
        if let pinned = customDirectory {
            return (pinned, .pinned)
        }
        let shellRoot = LocalWorkspaceBackend.gitRootSync(containing: cwd) ?? cwd
        // Only a *different repository* re-roots the panels. A foreground job
        // running in a subdirectory of the shell's own checkout resolves to
        // the same root and is ignored, which keeps the file tree from
        // collapsing its expanded rows every time a command runs.
        if let foregroundCwd,
           let foregroundRoot = LocalWorkspaceBackend.gitRootSync(containing: foregroundCwd),
           foregroundRoot != shellRoot {
            return (
                foregroundRoot,
                .foreground(isWorktree: LocalWorkspaceBackend.isLinkedWorktreeSync(foregroundRoot))
            )
        }
        return (shellRoot, .shell)
    }


    // MARK: - Sessions

    /// When no directory is given, the new session starts in the pinned
    /// project directory, then the current session's working directory
    /// (home when neither is known). A manual project directory is an
    /// explicit choice, so it also becomes the default for future terminals.
    @discardableResult
    func newSession(
        directory: String? = nil,
        launchCommand: String? = nil,
        initialWorkspace: PanelContext? = nil,
        initialInput: String? = nil
    ) -> TerminalSession {
        let session = makeSession(directory: directory, launchCommand: launchCommand, initialWorkspace: initialWorkspace, initialInput: initialInput)
        let tab = makeTab(content: .session(session))
        insertNextToSelected(tab)
        selectedTabID = tab.id
        return session
    }

    /// Builds a session wired for exit + change observation, without placing
    /// it in a tab. `restoredHistory` seeds the
    /// scrollback when reopening a saved session.
    private func makeSession(
        directory: String? = nil,
        restoredHistory: String? = nil,
        launchCommand: String? = nil,
        initialWorkspace: PanelContext? = nil,
        initialInput: String? = nil
    ) -> TerminalSession {
        let remoteCommand: String? = sshHost.map { host in
            let cwd = directory ?? customDirectory ?? "/"
            // Windows OpenSSH's MSYS2 zsh wrapper forwards single quotes
            // literally and its .exe login shell resets cwd to HOME.
            let remote = "cd " + RemoteCommands.doubleQuote(cwd)
                + " && case \"$SHELL\" in *.exe) exec zsh -i ;; "
                + "*) exec \"${SHELL:-/bin/sh}\" -i ;; esac"
            return "exec /usr/bin/ssh -tt -o BatchMode=yes "
                + "-o StrictHostKeyChecking=yes -- "
                + Self.shellQuoted(host) + " " + Self.shellQuoted(remote)
        }
        let session = TerminalSession(
            initialDirectory: sshHost == nil
                ? (directory ?? customDirectory ?? selectedSession?.currentDirectoryPath)
                : nil,
            restoredHistory: restoredHistory,
            launchCommand: launchCommand ?? remoteCommand,
            initialWorkspace: initialWorkspace,
            initialInput: initialInput
        )
        session.onExited = { [weak self] session in
            // Already dead — just drop its pane, no second terminate.
            self?.closeContent(.session(session), terminate: false)
        }
        session.onRemoteContextChange = { [weak self] in
            // Changing the real SSH target changes whether previously opened
            // remote files/diffs are writable; SwiftUI redraw alone is insufficient.
            self?.scheduleRemoteTabRebind()
        }
        return session
    }

    @discardableResult
    func newInteractiveGitSession(
        repository: String, arguments: [String], context: PanelContext
    ) throws -> TerminalSession {
        let command = "cd " + Self.shellQuoted(repository) + " && git "
            + arguments.map(Self.shellQuoted).joined(separator: " ")
        if context.isRemote {
            let connection = selectedSession?.location.remoteConnection
            guard let host = sshHost ?? connection?.destination,
                  let executable = Bundle.main.executableURL else { throw RemoteConnectionError.notConnected }
            if sshHost == nil {
                guard let connection, connection.state == .connected,
                      connection.workspaceIdentity == context.scope else { throw RemoteConnectionError.notConnected }
            }
            let port = connection?.port ?? 22
            let helper = executable.deletingLastPathComponent().appendingPathComponent("ssh").path
            let launch = Self.shellQuoted(helper)
                + " -tt -o BatchMode=yes -o StrictHostKeyChecking=yes -o ControlMaster=no -o ControlPath=none"
                + (sshHost == nil ? " -p \(port)" : "") + " -- " + Self.shellQuoted(host)
                + "; exitStatus=$?; printf '\\nSSH session ended (status %s). Press Enter to close this terminal.\\n' \"$exitStatus\"; read -r answer; exit \"$exitStatus\""
            let initial = PanelContext(
                identity: .pinned(project: id, workspace: context.identity.workspace, directory: repository),
                backend: context.backend
            )
            let pathBytes = (repository + "/.").utf8.map {
                "\\0" + String(repeating: "0", count: 3 - String($0, radix: 8).count) + String($0, radix: 8)
            }.joined()
            let input = "cd \"$(printf '%b' " + Self.shellQuoted(pathBytes) + ")\" && git "
                + arguments.map(Self.shellQuoted).joined(separator: " ") + "\r"
            return newSession(launchCommand: launch, initialWorkspace: initial, initialInput: input)
        }
        let shell = LocalWorkspaceBackend.loginShell
        let script = command + "; exec " + Self.shellQuoted(shell) + " -il"
        let launch = "exec " + Self.shellQuoted(shell) + " -ilc " + Self.shellQuoted(script)
        return newSession(directory: repository, launchCommand: launch)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Remote tabs

    /// A live workspace for `identity`, from whichever session in this project
    /// holds it. A file belongs to a machine, not to the terminal it happened
    /// to be opened from: reconnecting in a second terminal of the same
    /// project makes those tabs writable again.
    func connectedWorkspace(for identity: String) -> WorkspaceBackend? {
        if let sshHost, identity == "ssh:" + sshHost {
            guard SSHHostWorkspaces.connectionState(for: sshHost) != false else { return nil }
            return SSHHostWorkspaces.backend(for: sshHost)
        }
        for session in sessions {
            guard let connection = session.location.remoteConnection,
                  connection.workspaceIdentity == identity,
                  connection.state == .connected
            else { continue }
            let backend = session.workspaceBackend
            // The session reports a remote workspace only once the connection
            // is connected and its directory is known; until then it is still
            // answering with the local disk, which is not this file's machine.
            if !(backend is LocalWorkspaceBackend) { return backend }
        }
        return nil
    }

    /// Re-checks every remote file and diff against the project's connections.
    /// Real SSH state/directory callbacks happen after mutation; coalesce
    /// them one hop later instead of rechecking on every terminal UI update.
    private func scheduleRemoteTabRebind() {
        guard !isRemoteTabRebindPending else { return }
        isRemoteTabRebindPending = true
        Task { @MainActor in
            isRemoteTabRebindPending = false
            rebindRemoteTabs()
        }
    }

    func rebindRemoteTabs() {
        for content in tabs.map(\.content) {
            switch content {
            case .file(let file): file.reevaluateWorkspace(in: self)
            case .diff(let diff): diff.reevaluateWorkspace(in: self)
            case .session, .browser: break
            }
        }
    }

    func terminateAll() {
        for session in sessions {
            session.terminate()
        }
    }

    // MARK: - Files

    /// Opens `path` as a new file tab, reusing an existing tab for the
    /// same path. `editorState` seeds scroll/cursor state when restoring.
    func openFile(_ path: String, editorState: EditorState? = nil) {
        // Capture the current directory context *before* selection moves to the
        // new tab, so its panels track the tab the file was opened from. The
        // same session decides which workspace the path belongs to, so the
        // lookup below cannot reuse a tab from another machine.
        let context = selectedSession
        if let tab = findFileTab(path: path, workspace: workspaceIdentity) {
            if selectedTabID == tab.id, let workspaceIdentity {
                SSHHostWorkspaces.retryConnection(for: workspaceIdentity, path: path)
            }
            selectedTabID = tab.id
            return
        }
        let file = FileTab(
            path: path,
            backend: workspaceBackend, workspaceIdentity: workspaceIdentity
        )
        if let editorState {
            file.editorState = editorState
        }
        let tab = makeTab(content: .file(file))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    private func findFileTab(path: String, workspace: String?) -> PaneTab? {
        tabs.first {
            guard case .file(let file) = $0.content else { return false }
            return file.path == path && file.workspaceIdentity == workspace
        }
    }

    func ignoreGitPaths(
        _ paths: [String], isDirectory: Bool, repository: String,
        context: PanelContext, isCurrent: () -> Bool
    ) async throws {
        let patterns = try GitStatusModel.ignorePatterns(paths, isDirectory: isDirectory)
        let path = repository + "/.gitignore"
        guard isCurrent() else { throw CancellationError() }
        let existing = try await context.backend.stat(path: path)
        guard isCurrent() else { throw CancellationError() }
        if existing == nil {
            do {
                try await context.backend.createFile(path: path)
            } catch {
                guard try await context.backend.stat(path: path) != nil else { throw error }
            }
        }
        guard isCurrent() else { throw CancellationError() }
        openFile(path)
        guard let tab = findFileTab(path: path, workspace: workspaceIdentity),
              case .file(let file) = tab.content else { throw WorkspaceError.notFound }
        try await file.waitForText()
        guard isCurrent(), file.path == path else { throw CancellationError() }
        let newline = file.text.contains("\r\n") ? "\r\n" : "\n"
        let separator = file.text.isEmpty || file.text.hasSuffix("\n") ? "" : newline
        file.appendText(separator + patterns.joined(separator: newline) + newline)
        await file.save()
        guard isCurrent() else { throw CancellationError() }
        guard !file.isDirty, file.saveError == nil else {
            throw NSError(domain: "Kero.Editor", code: 2, userInfo: [NSLocalizedDescriptionKey:
                file.saveError ?? String(localized: "Edits could not be saved.", table: "Editor")])
        }
    }

    // MARK: - Browser

    /// Opens a native browser as a new tab beside the current selection.
    @discardableResult
    func newBrowserTab(
        initialURL: String? = nil,
        initialFocus: BrowserTab.InitialFocus = .addressBar
    ) -> BrowserTab {
        let context = selectedSession
        let browser = makeBrowser(
            initialURL: initialURL,
            initialFocus: initialFocus
        )
        let tab = makeTab(content: .browser(browser))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
        return browser
    }

    private func makeBrowser(
        initialURL: String?,
        initialFocus: BrowserTab.InitialFocus
    ) -> BrowserTab {
        BrowserTab(
            initialURL: initialURL,
            initialFocus: initialFocus
        )
    }

    // MARK: - File paths

    /// Only rename tabs from the machine where the change happened.
    /// A local and remote file with identical paths must remain independent.
    func updateFilePaths(from oldPath: String, to newPath: String, workspace: String?) {
        for tab in tabs {
            guard case .file(let file) = tab.content,
                  file.workspaceIdentity == workspace else { continue }
            if file.path == oldPath {
                file.updatePath(newPath)
            } else if file.path.hasPrefix(oldPath + "/") {
                file.updatePath(newPath + String(file.path.dropFirst(oldPath.count)))
            }
        }
        guard workspaceIdentity == workspace else { return }
        if let pinnedFile, pinnedFile == oldPath || pinnedFile.hasPrefix(oldPath + "/") {
            let updated = newPath + String(pinnedFile.dropFirst(oldPath.count))
            if customName == (pinnedFile as NSString).lastPathComponent {
                customName = (updated as NSString).lastPathComponent
            }
            self.pinnedFile = updated
        }
        if let customDirectory,
           customDirectory == oldPath || customDirectory.hasPrefix(oldPath + "/") {
            self.customDirectory = newPath + String(customDirectory.dropFirst(oldPath.count))
        }
    }

    // MARK: - Diffs

    /// Opens a git diff as a new tab, reusing (and reloading) an existing tab
    /// for the same file and stage side.
    func openDiff(
        repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?
    ) {
        let context = selectedSession
        if let tab = findDiffTab(
            repoRoot: repoRoot, path: path, source: staged ? .staged : .worktree,
            workspace: workspaceIdentity
        ),
           case .diff(let diff) = tab.content {
            diff.untracked = untracked
            diff.origPath = origPath
            diff.reload()
            selectedTabID = tab.id
            return
        }
        let diff = DiffTab(
            repoRoot: repoRoot, path: path, source: staged ? .staged : .worktree,
            untracked: untracked, origPath: origPath,
            backend: workspaceBackend, workspaceIdentity: workspaceIdentity
        )
        let tab = makeTab(content: .diff(diff))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    /// Opens one file as it changed in a historical commit, comparing the
    /// commit's first parent with the selected commit.
    func openCommitDiff(
        repoRoot: String,
        path: String,
        commitHash: String,
        parentHash: String?,
        status: Character,
        origPath: String?
    ) {
        openHistoricalDiff(repoRoot: repoRoot, path: path,
            source: .commit(hash: commitHash, parent: parentHash, status: String(status)),
            origPath: origPath)
    }

    func openHistoricalDiff(
        repoRoot: String, path: String, source: DiffTab.Source, origPath: String?
    ) {
        let context = selectedSession
        if let tab = findDiffTab(repoRoot: repoRoot, path: path,
                                 source: source, workspace: workspaceIdentity),
           case .diff(let diff) = tab.content {
            diff.origPath = origPath
            diff.reload()
            selectedTabID = tab.id
            return
        }
        let diff = DiffTab(repoRoot: repoRoot, path: path, source: source,
                           untracked: false, origPath: origPath,
                           backend: workspaceBackend, workspaceIdentity: workspaceIdentity)
        let tab = makeTab(content: .diff(diff))
        tab.contextSession = context
        insertNextToSelected(tab)
        selectedTabID = tab.id
    }

    private func findDiffTab(
        repoRoot: String, path: String, source: DiffTab.Source, workspace: String?
    ) -> PaneTab? {
        tabs.first {
            guard case .diff(let diff) = $0.content else { return false }
            return diff.repoRoot == repoRoot && diff.path == path
                && diff.source == source && diff.workspaceIdentity == workspace
        }
    }

    // MARK: - Closing

    /// Closes one tab's content. Dirty edits require confirmation; an exited
    /// shell is removed without terminating it again.
    func closeContent(_ content: PaneContent, terminate: Bool = true) {
        switch content {
        case .session(let session):
            if terminate { session.terminate() }
            removeTabWithContent(content.id)
        case .file, .diff:
            guard content.isDirty else {
                removeTabWithContent(content.id)
                return
            }
            // Closing is a focus transition, but it must not let a late
            // background save defeat an explicit Don't Save choice.
            content.suspendAutoSaveForClose(true)
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            Task { @MainActor in
                _ = await saveBeforeClosing(content, in: window)
            }
        case .browser:
            removeTabWithContent(content.id)
        }
    }

    func closeSelected() {
        guard let content = focusedContent else { return }
        closeContent(content)
    }

    func close(_ tab: PaneTab) {
        closeContent(tab.content)
    }

    /// "Close Others" is scoped to the tab group containing this tab, not
    /// an unrelated dock region elsewhere in the same workspace.
    func closeOthers(_ keep: PaneTab) {
        guard let group = dock.group(containing: .tab(keep.id)) else { return }
        selectedTabID = keep.id
        let ids = Set(group.items.compactMap { item -> UUID? in
            if case .tab(let id) = item, id != keep.id { return id }
            return nil
        })
        closeBatch(tabs.filter { ids.contains($0.id) }.map(\.content))
    }

    func closeToRight(of tab: PaneTab) {
        guard let group = dock.group(containing: .tab(tab.id)),
              let index = group.items.firstIndex(of: .tab(tab.id)) else { return }
        let ids = Set(group.items.dropFirst(index + 1).compactMap { item -> UUID? in
            if case .tab(let id) = item { return id }
            return nil
        })
        closeBatch(tabs.filter { ids.contains($0.id) }.map(\.content))
    }

    /// Closes file tabs while leaving other content open.
    func closeFiles() {
        closeBatch(tabs.map(\.content).filter { $0.isFile })
    }

    /// Closes diff tabs while leaving other content open.
    func closeDiffs() {
        closeBatch(tabs.map(\.content).filter { $0.isDiff })
    }

    /// Closes every tab, leaving the project open but empty.
    func closeAll() {
        closeBatch(tabs.map(\.content))
    }

    /// Asks whether to save before discarding an edited file, matching the
    /// standard macOS Save / Don't Save / Cancel prompt. Presented as a sheet
    /// on `window` (app-modal only when there's no window) so it doesn't block
    /// the whole app. Returns `true` if the user backed out — Cancel, or a save
    /// that failed — so a batch close can stop before tearing down other tabs.
    ///
    /// This is `async` on purpose: awaiting the sheet means each prompt in a
    /// batch is presented only after the previous one has fully dismissed.
    @discardableResult
    private func saveBeforeClosing(_ content: PaneContent, in window: NSWindow?) async -> Bool {
        await content.save()
        guard content.isDirty else {
            removeTabWithContent(content.id)
            return false
        }
        return await confirmCloseUnsaved(content, in: window)
    }

    @discardableResult
    private func confirmCloseUnsaved(_ content: PaneContent, in window: NSWindow?) async -> Bool {
        let response = await ProjectCloseConfirmation.present(title: content.title, in: window)

        switch response {
        case .alertFirstButtonReturn: // Save
            await content.save()
            // Keep the tab open if the write failed; the error bar shows why.
            guard !content.isDirty else {
                content.suspendAutoSaveForClose(false)
                return true
            }
            removeTabWithContent(content.id)
            return false
        case .alertSecondButtonReturn: // Don't Save
            removeTabWithContent(content.id)
            return false
        default: // Cancel
            content.suspendAutoSaveForClose(false)
            return true
        }
    }

    /// Handles dirty tabs in order, closing each accepted tab immediately.
    /// Clean tabs close after the prompts; Cancel stops the remaining prompts
    /// without rolling back tabs already closed by Save or Don't Save.
    private func closeBatch(_ targets: [PaneContent]) {
        let dirtyContents = targets.filter(\.isDirty)
        let cleanContents = targets.filter { !$0.isDirty }

        guard !dirtyContents.isEmpty else {
            cleanContents.forEach { closeContent($0) }
            return
        }

        let window = NSApp.keyWindow ?? NSApp.mainWindow
        dirtyContents.forEach { $0.suspendAutoSaveForClose(true) }
        Task { @MainActor in
            for content in dirtyContents {
                // Save on close first; only failures need the native prompt.
                if await saveBeforeClosing(content, in: window) {
                    dirtyContents.forEach { $0.suspendAutoSaveForClose(false) }
                    return
                }
            }
            cleanContents.forEach { closeContent($0) }
        }
    }

    // MARK: - Tab selection

    func select(index: Int) {
        let ids = dock.tabOrder
        guard ids.indices.contains(index) else { return }
        selectedTabID = ids[index]
    }

    func selectNext() {
        shiftSelection(by: 1)
    }

    func selectPrevious() {
        shiftSelection(by: -1)
    }

    private func shiftSelection(by offset: Int) {
        let ids = dock.tabOrder
        guard !ids.isEmpty, let current = ids.firstIndex(where: { $0 == selectedTabID })
        else { return }
        selectedTabID = ids[(current + offset + ids.count) % ids.count]
    }

    // MARK: - Layout mutation plumbing

    private func makeTab(content: PaneContent) -> PaneTab {
        register(PaneTab(content: content))
    }

    /// Wires semantic persistence changes for fresh and restored tabs.
    @discardableResult
    func register(_ tab: PaneTab) -> PaneTab {
        let notify: () -> Void = { [weak self] in self?.onSnapshotChange?() }
        tab.onSnapshotChange = notify
        switch tab.content {
        case .session(let session): session.onSnapshotChange = notify
        case .browser(let browser): browser.onSnapshotChange = notify
        case .file(let file): file.onSnapshotChange = notify
        case .diff(let diff): diff.onSnapshotChange = notify
        }
        return tab
    }

    /// Restores one independent tab and its saved content.
    @discardableResult
    func restoreTab(
        from snap: SessionSnapshot.ProjectSnapshot.TabSnapshot,
        histories: [String: String] = [:]
    ) -> PaneTab {
        let tab = PaneTab(content: makeContent(
            from: snap.content,
            restoredHistory: snap.historyKey.flatMap { histories[$0] }
        ))
        tab.customName = snap.customName
        append(tab)
        return tab
    }

    private func makeContent(
        from snap: SessionSnapshot.ProjectSnapshot.ContentSnapshot,
        restoredHistory: String? = nil
    ) -> PaneContent {
        switch snap {
        case .session(let workingDirectory):
            return .session(makeSession(directory: workingDirectory, restoredHistory: restoredHistory))
        case .file(let path, let editorState):
            let file = FileTab(
                path: path, backend: workspaceBackend,
                workspaceIdentity: workspaceIdentity
            )
            if let editorState { file.editorState = editorState }
            return .file(file)
        case .browser(let url):
            return .browser(makeBrowser(initialURL: url, initialFocus: .none))
        case .diff(let repoRoot, let path, let source, let untracked, let origPath):
            return .diff(DiffTab(
                repoRoot: repoRoot, path: path, source: source,
                untracked: untracked, origPath: origPath,
                backend: workspaceBackend, workspaceIdentity: workspaceIdentity
            ))
        }
    }

    /// Inserts a newly created tab immediately after the current selection so
    /// new tabs open next to the current one instead of at the end of the
    /// strip. Appends when there's no selection — the first tab, or while
    /// restoring, where selection tracks the last tab added.
    private func insertNextToSelected(_ tab: PaneTab) {
        if let selectedTabID,
           let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    /// Appends a tab and selects it — used while restoring, which builds tabs
    /// in saved order.
    func append(_ tab: PaneTab) {
        register(tab)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    private func removeTabWithContent(_ contentID: UUID) {
        guard let tab = tabs.first(where: { $0.content.id == contentID }) else { return }
        remove(tabID: tab.id)
    }

    private func remove(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        tab.onSnapshotChange = nil
        switch tab.content {
        case .session(let session):
            session.onSnapshotChange = nil
            session.onRemoteContextChange = nil
        case .browser(let browser): browser.onSnapshotChange = nil
        case .file(let file): file.onSnapshotChange = nil
        case .diff(let diff): diff.onSnapshotChange = nil
        }
        recentTabIDs.removeAll { $0 == tabID }
        tabs.remove(at: index)
        if case .session = tab.content { scheduleRemoteTabRebind() }
        if selectedTabID == tabID {
            let neighbor = min(index, tabs.count - 1)
            selectedTabID = neighbor >= 0 ? tabs[neighbor].id : nil
        }
        // Emptying the project does not close it — the project row stays in the
        // sidebar until the user explicitly closes it.
    }
}
