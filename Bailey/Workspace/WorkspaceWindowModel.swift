import AppKit
import Combine
import Foundation
import Observation
import SwiftUI
import WebKit

/// Tools can be docked in any group.
enum ToolPanel {
    case files
    case git
}

/// One Find menu command, routed from the menu bar to whichever find
/// implementation the focused pane owns: Ghostty's own search in a terminal,
/// `NSTextFinder`'s find bar in a file editor.
enum FindAction {
    case show
    case replace
    case hide
    case next
    case previous
    case useSelection
}

/// Owns the list of projects and the current selection. Each project holds
/// its own terminal sessions; the "selected session" is the selected
/// project's selected session.
@MainActor
@Observable
final class WorkspaceWindowModel {
    var projects: [Project] = [] {
        didSet {
            for project in oldValue where !projects.contains(where: { $0 === project }) {
                project.onSnapshotChange = nil
                project.onPresentationWindow = nil
            }
            for project in projects where !oldValue.contains(where: { $0 === project }) {
                bind(project)
            }
            requestSave()
        }
    }
    var selectedProjectID: UUID? {
        didSet {
            guard selectedProjectID != oldValue else { return }
            if let oldValue {
                projects.first { $0.id == oldValue }?.tabs.forEach { $0.content.autoSaveOnFocusLoss() }
            }
            requestSave()
        }
    }
    private(set) var isCommandPaletteVisible = false

    @ObservationIgnored private var projectCounter = 0
    @ObservationIgnored private var isInitialized = false
    @ObservationIgnored private var windowCloseObservation: AnyCancellable?
    @ObservationIgnored private var didCloseWindow = false
    /// The stable terminal/editor responder displaced by the command palette's
    /// search field. AppKit field editors are deliberately excluded because a
    /// SwiftUI TextField can reuse the same responder for the palette itself.
    @ObservationIgnored private weak var commandPalettePreviousResponder: NSResponder?
    @ObservationIgnored private weak var commandPaletteWindow: NSWindow?
    @ObservationIgnored private var commandPaletteContentID: UUID?
    /// Window hosting this manager, once SwiftUI has attached its content.
    /// Finder service requests use it to target the active Bailey window.
    @ObservationIgnored private weak var window: NSWindow?
    var attachedWindow: NSWindow? { window }

    var hasUnsavedEditorsInWindow: Bool {
        projects.contains { project in
            project.tabs.contains { $0.content.isDirty }
        }
    }

    /// Both a single window close and full app termination must wait for the
    /// same real file writes before native views and shells are torn down.
    func saveBeforeWindowClose() async -> Bool {
        for project in projects {
            for tab in project.tabs where tab.content.isDirty {
                await tab.content.save()
                guard !tab.content.isDirty else { return false }
            }
        }
        // A previously clean tab can become dirty while another save awaits IO.
        return !hasUnsavedEditorsInWindow
    }

    let application: WorkspaceApplication

    /// Constructing a SwiftUI State value must not register or consume a saved window.
    init(application: WorkspaceApplication) {
        self.application = application
    }

    var isClosed: Bool { didCloseWindow }

    func finishRegistration(hasNewDirectories: Bool) {
        isInitialized = true
        if hasNewDirectories { requestSave() }
    }

    /// The application owns the coalesced timer and all registered windows.
    func requestSave() {
        guard isInitialized else { return }
        application.requestSave(from: self)
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedSession: TerminalSession? {
        selectedProject?.selectedSession
    }

    /// The window supplies the current selection check without passing its
    /// entire model into the Git domain or retaining it across async work.
    func syncGitStatus(_ model: GitStatusModel) {
        model.syncSelectedProject(project: selectedProject) { [weak self] project in
            guard let self, !self.isClosed else { return false }
            return self.selectedProject === project
        }
    }

    // MARK: - Projects

    /// Only an explicitly selected folder creates or selects a local project.
    func addLocalFolders(_ urls: [URL]) {
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "localhost" else { continue }
            let root = url.standardizedFileURL.path
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &directory),
                  directory.boolValue,
                  FileManager.default.isReadableFile(atPath: root),
                  FileManager.default.isExecutableFile(atPath: root),
                  !NSWorkspace.shared.isFilePackage(atPath: root) else { continue }
            if let existing = projects.first(where: {
                $0.sshHost == nil && $0.customDirectory == root && $0.pinnedFile == nil
            }) {
                selectedProjectID = existing.id
                continue
            }
            let project = makeProject()
            project.customName = url.lastPathComponent
            project.customDirectory = root
            insert(project)
        }
    }

    /// Finder and the Open File picker reuse a Mac buffer in this window;
    /// new files belong to the current project, never to their parent folder.
    @discardableResult
    func openExternalLocalItems(
        _ urls: [URL], destination: (projectID: UUID, groupID: UUID)? = nil
    ) -> [URL] {
        if let destination {
            guard let project = selectedProject, project.id == destination.projectID,
                  project.dock.root.group(id: destination.groupID) != nil else { return urls }
        }
        typealias Item = (url: URL, path: String, resolved: String, isDirectory: Bool)
        var items: [Item] = []
        var rejected: [URL] = []
        for url in urls {
            guard url.isFileURL, url.host == nil || url.host == "localhost" else {
                rejected.append(url)
                continue
            }
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !NSWorkspace.shared.isFilePackage(atPath: path)
            else {
                rejected.append(url)
                continue
            }
            if isDirectory.boolValue &&
                (!FileManager.default.isReadableFile(atPath: path)
                 || !FileManager.default.isExecutableFile(atPath: path)) {
                rejected.append(url)
                continue
            }
            items.append((
                url: url, path: path, resolved: Self.resolvedLocalPath(path),
                isDirectory: isDirectory.boolValue
            ))
        }

        // Directory additions are explicit. They never change the target for
        // new files if this batch began in an existing project.
        let originalProject = selectedProject
        for item in items where item.isDirectory {
            addLocalFolders([URL(fileURLWithPath: item.path, isDirectory: true)])
        }
        let targetProject = originalProject ?? selectedProject

        for item in items where !item.isDirectory {
            let existing = projects.lazy.compactMap { project -> (Project, FileTab)? in
                for tab in project.tabs {
                    guard case .file(let file) = tab.content,
                          file.workspaceIdentity == nil,
                          Self.resolvedLocalPath(file.path) == item.resolved
                    else { continue }
                    return (project, file)
                }
                return nil
            }.first
            if let (project, file) = existing {
                selectedProjectID = project.id
                project.openLocalFile(file.path)
                continue
            }

            let fileType = (try? FileManager.default.attributesOfItem(atPath: item.resolved))?[.type]
                as? FileAttributeType
            guard fileType == .typeRegular, FileManager.default.isReadableFile(atPath: item.path),
                  let targetProject else {
                rejected.append(item.url)
                continue
            }
            selectedProjectID = targetProject.id
            targetProject.openLocalFile(item.path, inGroup: destination?.groupID)
        }
        return rejected
    }

    private static func resolvedLocalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func chooseFolders() {
        guard let receivingWindow = window else { return }
        WorkspaceNativeDialogs.chooseFolders(in: receivingWindow) { [weak self, weak receivingWindow] urls in
            guard let self, let receivingWindow, self.window === receivingWindow else { return }
            self.addLocalFolders(urls)
        }
    }

    func chooseFiles(inGroup destination: (projectID: UUID, groupID: UUID)? = nil) {
        guard let receivingWindow = window, let originalProjectID = selectedProject?.id else { return }
        if let destination {
            guard selectedProjectID == destination.projectID,
                  selectedProject?.dock.root.group(id: destination.groupID) != nil else { return }
        }
        WorkspaceNativeDialogs.chooseFiles(in: receivingWindow) { [weak self, weak receivingWindow] urls in
            guard let self, let receivingWindow, self.window === receivingWindow,
                  self.selectedProject?.id == originalProjectID else { return }
            if let destination {
                guard self.selectedProject?.dock.root.group(id: destination.groupID) != nil else { return }
            }
            application.openExternalFiles(urls, preferred: self, destination: destination)
        }
    }

    /// One SSH host can supply several independent roots. The remote file
    /// browser uses the already-supported POSIX shell on the SSH destination.
    func addSSHItems(host: String, paths: [String],
                     isCurrentTarget: (@MainActor () -> Bool)? = nil) async throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHHostWorkspaces.validHost(host) else {
            throw SSHItemError.invalidHost
        }
        let paths = paths.map(SSHHostWorkspaces.normalizedPath)
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else {
            throw SSHItemError.invalidPath
        }
        let backend = SSHHostWorkspaces.backend(for: host)
        var validated: [(path: String, directory: Bool)] = []
        for path in paths {
            guard let stat = try await backend.stat(path: path),
                  stat.isDirectory || stat.isRegular
            else { throw SSHItemError.notFound(path) }
            validated.append((path, stat.isDirectory))
        }
        guard isCurrentTarget?() ?? true else { return }
        for item in validated {
            let root = item.directory ? item.path
                : (item.path as NSString).deletingLastPathComponent
            let file = item.directory ? nil : item.path
            if let existing = projects.first(where: {
                $0.sshHost == host && $0.customDirectory == root
                    && $0.pinnedFile == file
            }) {
                selectedProjectID = existing.id
                continue
            }
            let project = makeProject()
            project.sshHost = host
            project.customDirectory = root
            project.pinnedFile = file
            project.customName = (item.path as NSString).lastPathComponent
            if let file { project.openFile(file) }
            insert(project)
        }
    }

    private enum SSHItemError: LocalizedError {
        case invalidHost
        case invalidPath
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .invalidHost: String(localized: "Enter an SSH host from ~/.ssh/config.", table: "Terminal")
            case .invalidPath: String(localized: "Enter an absolute remote directory or file path.", table: "Terminal")
            case .notFound(let path): String(localized: "Remote file or folder not found: \(path)", table: "Terminal")
            }
        }
    }

    func chooseSSHItems() {
        WorkspaceNativeDialogs.chooseSSHItems(
            in: window, aliases: Self.sshHostAliases()
        ) { [weak self] host, paths in
            guard let self else { return }
            Task {
                do {
                    try await self.addSSHItems(host: host, paths: paths)
                } catch {
                    WorkspaceNativeDialogs.showError(error, in: self.window)
                }
            }
        }
    }

    private static func sshHostAliases() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return data.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.first?.lowercased() == "host" else { return [] }
            return words.dropFirst().compactMap { value in
                let host = String(value)
                return host.contains("*") || host.contains("?") ? nil : host
            }
        }
    }

    private func insert(_ project: Project) {
        // Open the new project next to the current one rather than at the end.
        // Falls back to appending when nothing is selected yet.
        if let selectedProjectID,
           let index = projects.firstIndex(where: { $0.id == selectedProjectID }) {
            projects.insert(project, at: index + 1)
        } else {
            projects.append(project)
        }
        selectedProjectID = project.id
    }

    /// Called as soon as SwiftUI gives this manager an AppKit window. A
    /// launch-time Finder request may have been queued before that happened.
    func attach(to window: NSWindow) {
        guard !didCloseWindow else { return }
        application.register(self)
        if self.window !== window {
            windowCloseObservation = NotificationCenter.default
                .publisher(for: NSWindow.willCloseNotification, object: window)
                .sink { [weak self] _ in self?.windowClosed() }
        }
        self.window = window
        application.didAttach(self)
    }

    private func bind(_ project: Project) {
        project.onSnapshotChange = { [weak self] in self?.requestSave() }
        project.onPresentationWindow = { [weak self] in self?.attachedWindow }
    }

    private func makeProject() -> Project {
        projectCounter += 1
        let project = Project(
            fallbackName: "Project \(projectCounter)",
            workspaceConfiguration: AppSettings.shared.workspaceConfiguration
        )
        return project
    }

    func autoSaveEditedTabs() {
        for project in projects {
            for tab in project.tabs { tab.content.autoSaveOnFocusLoss() }
        }
    }

    func close(_ project: Project) {
        guard projects.contains(where: { $0 === project }),
              !project.tabs.contains(where: { $0.content.isClosing }) else { return }
        let dirty = project.tabs.map(\.content).filter(\.isDirty)
        guard !dirty.isEmpty else {
            project.terminateAll()
            remove(project)
            return
        }
        dirty.forEach { $0.suspendAutoSaveForClose(true) }
        Task { [weak self, weak project] in
            for content in dirty {
                await content.save()
                guard !content.isDirty else {
                    // A failed or superseded write must not destroy the editor.
                    dirty.forEach { $0.suspendAutoSaveForClose(false) }
                    return
                }
            }
            guard let self, let project,
                  self.projects.contains(where: { $0 === project }) else { return }
            // New drafts in tabs skipped before an awaited save must survive.
            guard !project.tabs.contains(where: { $0.content.isDirty }) else {
                dirty.forEach { $0.suspendAutoSaveForClose(false) }
                return
            }
            project.terminateAll()
            self.remove(project)
        }
    }

    private func remove(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects.remove(at: index)
        // A dismissed SwiftUI host may still cache this Project; its retired
        // editors must no longer be owned by the removed project's tab array.
        project.tabs.removeAll()
        if selectedProjectID == project.id {
            let neighbor = min(index, projects.count - 1)
            selectedProjectID = neighbor >= 0 ? projects[neighbor].id : nil
        }
        // Only an explicit project closure removes the Files/Git workspace.
    }

    /// Moves a dragged project across `targetID`: after it when moving down,
    /// or before it when moving up. Selection continues to follow its project ID.
    func moveProject(_ draggedID: UUID, to targetID: UUID) {
        guard draggedID != targetID,
              let draggedIndex = projects.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = projects.firstIndex(where: { $0.id == targetID })
        else { return }

        var reorderedProjects = projects
        let draggedProject = reorderedProjects.remove(at: draggedIndex)
        reorderedProjects.insert(draggedProject, at: targetIndex)
        projects = reorderedProjects
    }

    func selectProject(index: Int) {
        guard projects.indices.contains(index) else { return }
        selectedProjectID = projects[index].id
    }

    func selectNextProject() {
        shiftProjectSelection(by: 1)
    }

    func selectPreviousProject() {
        shiftProjectSelection(by: -1)
    }

    private func shiftProjectSelection(by offset: Int) {
        guard !projects.isEmpty,
              let current = projects.firstIndex(where: { $0.id == selectedProjectID })
        else { return }
        let next = (current + offset + projects.count) % projects.count
        selectedProjectID = projects[next].id
    }

    // MARK: - Sessions

    /// New sessions and browser tabs use the selected project.
    func newSession() {
        selectedProject?.newSession()
    }

    func newBrowserTab(initialURL: String? = nil) {
        selectedProject?.newBrowserTab(
            initialURL: initialURL,
            initialFocus: initialURL == nil ? .addressBar : .webContent
        )
    }

    /// Brings `session` to the foreground: selects its project and tab, then
    /// activates it. Backs the command palette's session switcher; a no-op
    /// if the session is no longer open anywhere.
    func revealSession(_ session: TerminalSession) {
        for project in projects {
            for tab in project.tabs {
                guard tab.content.id == session.id else { continue }
                selectedProjectID = project.id
                project.selectTab(tab.id)
                return
            }
        }
    }

    /// Clears the terminal in the focused pane. No-op while another content
    /// kind is focused, so ⌘K never wipes an off-screen terminal.
    func clearActiveTerminal() {
        if case .session(let session)? = selectedProject?.focusedContent {
            session.clear()
        }
    }

    /// Whether ⌘K has a terminal on screen to act on right now.
    var canClearActiveTerminal: Bool {
        if case .session? = selectedProject?.focusedContent { return true }
        return false
    }

    /// Routes a Find menu command to the focused pane. Driven off the focused
    /// pane rather than the first responder, so ⌘F and ⌘G keep working while
    /// the find bar's own field holds keyboard focus.
    func performFindAction(_ action: FindAction) {
        switch selectedProject?.focusedContent {
        case .session(let session): session.find.perform(action)
        case .file(let file): file.performFindAction(action)
        case .browser, .diff, .none: break
        }
    }

    /// Whether the Find menu has something searchable on screen right now.
    /// Diffs render their own views rather than a searchable text view.
    var canFind: Bool {
        switch selectedProject?.focusedContent {
        case .session, .file: return true
        case .browser, .diff, .none: return false
        }
    }

    /// Whether Find and Replace has an editable pane to act on: terminal
    /// output and diffs are read-only, so replace is only offered for a file.
    var canReplace: Bool {
        if case .file? = selectedProject?.focusedContent { return true }
        return false
    }

    func closeSelectedTab() {
        guard let project = selectedProject else { return }
        switch project.dock.activeGroup?.selected {
        case .tab: project.closeSelected()
        case .files?, .git?, .projects?:
            if let item = project.dock.activeGroup?.selected { project.dock.removeTool(item) }
        case nil:
            if project.tabs.isEmpty { close(project) }
        }
    }

    func selectNextTab() {
        selectedProject?.selectNext()
    }

    func selectPreviousTab() {
        selectedProject?.selectPrevious()
    }

    func selectTab(index: Int) {
        selectedProject?.select(index: index)
    }

    // MARK: - Browser

    private var selectedBrowser: BrowserTab? {
        if case .browser(let browser)? = selectedProject?.focusedContent {
            return browser
        }
        return nil
    }

    var hasSelectedBrowser: Bool {
        selectedBrowser != nil
    }

    func focusBrowserAddressBar() {
        selectedBrowser?.requestAddressFocus()
    }

    func reloadSelectedBrowser() {
        selectedBrowser?.reload()
    }

    func stopSelectedBrowser() {
        selectedBrowser?.stopLoading()
    }

    func openSelectedPageInDefaultBrowser() {
        selectedBrowser?.openInDefaultBrowser()
    }

    // MARK: - Files

    func newFile() async {
        await newItem(isDirectory: false)
    }

    func newFolder() async {
        await newItem(isDirectory: true)
    }

    private func newItem(isDirectory: Bool) async {
        guard let project = selectedProject, let context = project.panelContext else { return }
        let root: String
        do {
            root = try await context.resolvedRoot().root
        } catch {
            WorkspaceNativeDialogs.showError(error, in: window)
            return
        }
        guard selectedProjectID == project.id, project.matchesPanelTarget(context.identity) else { return }
        showPanel(.files)
        await project.fileTree.sync(root: root, backend: context.backend, scope: context.scope)
        guard selectedProjectID == project.id, project.matchesPanelTarget(context.identity) else { return }
        if isDirectory {
            await project.fileTree.beginNewFolder(in: root)
        } else {
            await project.fileTree.beginNewFile(in: root)
        }
    }

    /// Opens `path` as a file tab in the current project.
    func openFile(_ path: String, activating: Bool = true) {
        selectedProject?.openFile(path, activating: activating)
    }

    /// Opens a git diff tab in the current project.
    func openDiff(
        repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?,
        activating: Bool = true
    ) {
        selectedProject?.openDiff(
            repoRoot: repoRoot, path: path, staged: staged,
            untracked: untracked, origPath: origPath, activating: activating
        )
    }

    /// Opens the selected path as changed by one historical commit.
    func openCommitDiff(
        repoRoot: String,
        path: String,
        commitHash: String,
        parentHash: String?,
        status: Character,
        origPath: String?,
        activating: Bool = true
    ) {
        selectedProject?.openCommitDiff(
            repoRoot: repoRoot,
            path: path,
            commitHash: commitHash,
            parentHash: parentHash,
            status: status,
            origPath: origPath,
            activating: activating
        )
    }

    var canSaveSelectedFile: Bool { selectedProject?.focusedContent?.isDirty == true }

    /// Saves the focused pane if it holds a file or an editable diff.
    func saveSelectedFile() {
        guard let content = selectedProject?.focusedContent else { return }
        Task { await content.save() }
    }

    /// Protect every open editor on this machine before mutating a directory entry.
    func renameFile(
        _ item: FileTreeModel.Item, to newName: String,
        in project: Project, target: PanelContext.Identity
    ) async -> String? {
        guard selectedProjectID == project.id, project.matchesPanelTarget(target) else { return nil }
        do {
            return try await application.withProtectedFiles(
                paths: [item.path], workspace: target.workspace
            ) {
                guard self.selectedProjectID == project.id, project.matchesPanelTarget(target) else {
                    throw CancellationError()
                }
                let newPath = await project.fileTree.rename(item, to: newName)
                if let newPath {
                    self.application.fileRenamed(
                        from: item.path, to: newPath, workspace: target.workspace
                    )
                }
                return newPath
            }
        } catch {
            if !(error is CancellationError) { WorkspaceNativeDialogs.showError(error, in: window) }
            return nil
        }
    }

    func performFileOperation(
        _ operation: FileTreeModel.FileOperation, paths: [String], into directory: String?,
        in project: Project, target: PanelContext.Identity
    ) async -> FileTreeModel.FileBatchResult {
        guard selectedProjectID == project.id, project.matchesPanelTarget(target) else {
            return FileTreeModel.FileBatchResult()
        }
        do {
            return try await application.withProtectedFiles(paths: paths, workspace: target.workspace) {
                guard self.selectedProjectID == project.id,
                      project.matchesPanelTarget(target) else { throw CancellationError() }
                let outcome = await project.fileTree.performFileOperation(
                    operation, paths: paths, into: directory,
                    isCurrentTarget: {
                        self.selectedProjectID == project.id && project.matchesPanelTarget(target)
                    }
                )
                for entry in outcome.succeeded {
                    switch operation {
                    case .move:
                        if let destination = entry.destination {
                            self.application.fileRenamed(
                                from: entry.source, to: destination, workspace: target.workspace
                            )
                        }
                    case .delete:
                        self.application.filesDeleted(
                            paths: [entry.source], workspace: target.workspace
                        )
                    case .copy: break
                    }
                }
                return outcome
            }
        } catch {
            if !(error is CancellationError) { WorkspaceNativeDialogs.showError(error, in: window) }
            return FileTreeModel.FileBatchResult()
        }
    }

    func deleteFile(
        _ item: FileTreeModel.Item, in project: Project, target: PanelContext.Identity
    ) async -> Bool {
        let outcome = await performFileOperation(
            .delete, paths: [item.path], into: nil, in: project, target: target
        )
        return outcome.succeeded.contains { $0.source == item.path }
    }

    /// Keep tabs and pinned sidebar entries in sync on the affected machine,
    /// not in unrelated Mac/SSH projects with the same path.
    func fileRenamed(from oldPath: String, to newPath: String, workspace: String?) {
        application.fileRenamed(from: oldPath, to: newPath, workspace: workspace)
    }

    // MARK: - Panels & appearance

    func toggleCommandPalette() {
        if isCommandPaletteVisible {
            dismissCommandPalette()
        } else {
            commandPaletteWindow = window
            commandPaletteContentID = selectedProject?.focusedContent?.id
            if let responder = commandPaletteWindow?.firstResponder,
               commandPaletteWindow?.isKeyWindow == true, NSApp.isActive,
               isStableWorkspaceResponder(responder), ownsActiveResponder(responder) {
                commandPalettePreviousResponder = responder
            } else {
                commandPalettePreviousResponder = nil
            }
            isCommandPaletteVisible = true
        }
    }

    func dismissCommandPalette(restoringFocus: Bool = true) {
        guard isCommandPaletteVisible else { return }
        if !restoringFocus {
            commandPaletteWindow = nil
            commandPalettePreviousResponder = nil
            commandPaletteContentID = nil
        }
        isCommandPaletteVisible = false
    }

    /// Called by the palette after SwiftUI has actually removed its focused
    /// search field from the window.
    func restoreFocusAfterCommandPalette() {
        let window = commandPaletteWindow
        let responder = commandPalettePreviousResponder
        let contentID = commandPaletteContentID
        commandPaletteWindow = nil
        commandPalettePreviousResponder = nil
        commandPaletteContentID = nil

        // Let the removal transaction finish before restoring the displaced
        // AppKit responder.
        DispatchQueue.main.async {
            guard let window, NSApp.isActive, window.isKeyWindow,
                  window === self.window, window.attachedSheet == nil,
                  !self.isCommandPaletteVisible else { return }
            // A palette command may already have focused a new terminal or
            // editor. Never let restoration race that newer focus and win.
            if let current = window.firstResponder,
               self.isStableWorkspaceResponder(current),
               self.ownsActiveResponder(current) { return }
            if let responder, self.selectedProject?.focusedContent?.id == contentID,
               self.ownsActiveResponder(responder) {
                window.makeFirstResponder(responder)
            } else if let activeTree = self.activeTreeResponder(in: window) {
                // A palette switch can move from an editor, terminal, or old
                // tree into Files/Git. Restore the tool that is now visible.
                window.makeFirstResponder(activeTree)
            }
        }
    }

    func activeTreeResponder(in window: NSWindow) -> TreeKeyboardView? {
        guard let root = window.contentView,
              let selected = selectedProject?.dock.activeGroup?.selected,
              selected == .files || selected == .git else { return nil }
        func findTree(_ view: NSView) -> TreeKeyboardView? {
            if let tree = view as? TreeKeyboardView, ownsActiveResponder(tree) { return tree }
            return view.subviews.lazy.compactMap(findTree).first
        }
        return findTree(root)
    }

    /// Terminal and editor responders are public host views. WebKit instead
    /// makes a private descendant of WKWebView first responder, so walk its
    /// AppKit ancestry before deciding whether palette dismissal can restore
    /// the page's keyboard focus.
    private func isStableWorkspaceResponder(_ responder: NSResponder) -> Bool {
        if responder is any TerminalBackendSurface || responder is FocusReportingTextView
            || responder is DiffTextView || responder is TreeKeyboardView {
            return true
        }
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    func ownsActiveResponder(_ responder: NSResponder) -> Bool {
        guard let window, let view = responder as? NSView, view.window === window,
              !view.isHiddenOrHasHiddenAncestor else { return false }
        if view is TreeKeyboardView,
           let activeGroup = selectedProject?.dock.activeGroup,
           activeGroup.selected == .files || activeGroup.selected == .git,
           let windowContent = window.contentView {
            func belongsToActiveGroup(_ current: NSView) -> Bool {
                if let group = current as? DockGroupFocusView,
                   group.groupID == activeGroup.id {
                    return group.containsResponder(responder)
                }
                return current.subviews.contains(where: belongsToActiveGroup)
            }
            return belongsToActiveGroup(windowContent)
        }
        guard let content = selectedProject?.focusedContent else { return false }
        let root: NSView?
        switch content {
        case .session(let session):
            guard session.surface.superview is TerminalContainerView else { return false }
            root = session.surface
        case .file(let file): root = file.editorView
        case .browser(let browser): root = browser.webView
        case .diff(let diff): root = diff.nativeSurface
        }
        guard let root, root.window === window, !root.visibleRect.isEmpty,
              !root.isHiddenOrHasHiddenAncestor else { return false }
        return view === root || view.isDescendant(of: root)
    }

    /// Reuse an existing panel or reopen it in a tool group; never create
    /// another copy just because the user relocated the original.
    func showPanel(_ item: DockItem) {
        guard let project = selectedProject else { return }
        if project.dock.group(containing: item) != nil {
            project.dock.select(item)
        } else if let target = project.dock.root.groups.last(where: { group in
            group.items.contains(.files) || group.items.contains(.git)
        }) ?? project.dock.root.groups.last {
            project.dock.place(item, in: target.id)
        }
    }

    /// Re-themes every session after a light/dark appearance change.
    func refreshAppearance() {
        for project in projects {
            for session in project.sessions {
                session.applyTheme()
            }
        }
    }

    /// Called when this manager's window closes: drop it from the
    /// persisted set — except for the last window, whose snapshot is kept
    /// saved and queued so reopening (or relaunching) restores it — and
    /// kill its shells.
    func windowClosed() {
        guard !didCloseWindow else { return }
        didCloseWindow = true
        windowCloseObservation = nil
        window = nil
        application.windowClosed(self)
        guard !application.isQuitting else { return }
        for project in projects {
            project.terminateAll()
        }
        projects.removeAll()
        selectedProjectID = nil
    }

    // MARK: - Persistence

    /// Builds this window's layout snapshot and, alongside it, the scrollback
    /// to persist for its sessions. Each captured session gets a fresh
    /// `historyKey` stored on both sides so restore can pair them; sessions
    /// with no history (feature off, empty, or unserializable) get no key.
    func makeWindowSnapshot(
        captureTerminalHistory: Bool
    ) -> (snapshot: SessionSnapshot, histories: [String: String]) {
        typealias ProjectSnapshot = SessionSnapshot.ProjectSnapshot
        var histories: [String: String] = [:]
        let snapshot = SessionSnapshot(
            projects: projects.map { project in
                let projectSessions = project.sessions
                // A tab holding nothing but remote content is not written at
                // all, so the surviving tabs decide the selected index below.
                let savedTabs = project.tabs.compactMap { tab -> (PaneTab, ProjectSnapshot.TabSnapshot)? in
                    guard let content = Self.contentSnapshot(
                        tab.content, sshHost: project.sshHost
                    ) else { return nil }
                    var historyKey: String?
                    if case .session(let session) = tab.content,
                       let history = session.serializedHistory(captureLive: captureTerminalHistory),
                       !history.isEmpty {
                        let key = UUID().uuidString
                        histories[key] = history
                        historyKey = key
                    }
                    let isLocalFile: Bool? = if case .file(let file) = tab.content {
                        file.workspaceIdentity == nil ? true : nil
                    } else { nil }
                    return (tab, ProjectSnapshot.TabSnapshot(
                        content: content, historyKey: historyKey,
                        customName: tab.customName,
                        contextSessionIndex: tab.contextSession.flatMap { context in
                            projectSessions.firstIndex { $0.id == context.id }
                        },
                        localFile: isLocalFile
                    ))
                }
                let tabs = savedTabs.map(\.1)
                return ProjectSnapshot(
                    customName: project.customName,
                    customDirectory: project.customDirectory,
                    sshHost: project.sshHost,
                    pinnedFile: project.pinnedFile,
                    tabs: tabs,
                    selectedTabIndex: savedTabs.firstIndex { $0.0.id == project.selectedTabID },
                    dock: project.dock.snapshot(tabIDs: savedTabs.map { $0.0.id })
                )
            },
            selectedProjectIndex: projects.firstIndex { $0.id == selectedProjectID }
        )
        return (snapshot, histories)
    }

    /// A remote path can be saved only when its SSH host is pinned on the
    /// sidebar item. Otherwise relaunch could read a same-named Mac file.
    private static func isSnapshotable(_ content: PaneContent, sshHost: String?) -> Bool {
        let identity = sshHost.map { "ssh:" + $0 }
        switch content {
        case .file(let file): return file.workspaceIdentity == nil || file.workspaceIdentity == identity
        case .diff(let diff): return diff.workspaceIdentity == identity
        case .session, .browser: return true
        }
    }

    private static func contentSnapshot(
        _ content: PaneContent, sshHost: String?
    ) -> SessionSnapshot.ProjectSnapshot.ContentSnapshot? {
        guard isSnapshotable(content, sshHost: sshHost) else { return nil }
        switch content {
        case .session(let session):
            return .session(workingDirectory: session.currentDirectoryPath)
        case .file(let file):
            return .file(path: file.path, editorState: file.editorState)
        case .browser(let browser):
            return .browser(url: browser.snapshotURL)
        case .diff(let diff):
            return .diff(repoRoot: diff.repoRoot, path: diff.path,
                         source: diff.source, untracked: diff.untracked,
                         origPath: diff.origPath)
        }
    }

    /// Rebuilds projects and tabs from the saved window snapshot.
    func restore(from snapshot: SessionSnapshot, histories: [String: String]) -> Bool {
        for saved in snapshot.projects {
            let project = makeProject()
            project.customName = Project.normalizedCustomName(saved.customName)
            project.customDirectory = saved.customDirectory
            project.sshHost = saved.sshHost
            project.pinnedFile = saved.pinnedFile
            var restoredContexts: [(tab: PaneTab, sessionIndex: Int)] = []
            for savedTab in saved.tabs {
                let tab = project.restoreTab(from: savedTab, histories: histories)
                if let sessionIndex = savedTab.contextSessionIndex {
                    restoredContexts.append((tab, sessionIndex))
                }
            }
            let restoredSessions = project.sessions
            for context in restoredContexts
            where restoredSessions.indices.contains(context.sessionIndex) {
                context.tab.contextSession = restoredSessions[context.sessionIndex]
            }
            if let index = saved.selectedTabIndex, project.tabs.indices.contains(index) {
                project.selectTab(project.tabs[index].id)
            }
            project.dock.restore(saved.dock, tabIDs: project.tabs.map(\.id))
            project.resetRecency()
            if let pinnedFile = project.pinnedFile,
               !project.tabs.map(\.content).contains(where: { content in
                   if case .file(let file) = content {
                       return file.path == pinnedFile
                           && file.workspaceIdentity == project.workspaceIdentity
                   }
                   return false
               }) {
                project.openFile(pinnedFile)
            }
            projects.append(project)
        }
        guard !projects.isEmpty else { return false }
        if let index = snapshot.selectedProjectIndex, projects.indices.contains(index) {
            selectedProjectID = projects[index].id
        } else {
            selectedProjectID = projects.first?.id
        }
        return true
    }
}
