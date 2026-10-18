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
final class TerminalManager {
    var projects: [Project] = [] {
        didSet { requestSave() }
    }
    var selectedProjectID: UUID? {
        didSet {
            guard selectedProjectID != oldValue else { return }
            if let oldValue {
                projects.first { $0.id == oldValue }?.selectedTab?.content.autoSaveOnFocusLoss()
            }
            requestSave()
        }
    }
    /// Debug FPS badge in the Dock header. Deliberately not persisted:
    /// every launch starts with it hidden.
    var isFPSCounterVisible = false
    private(set) var isCommandPaletteVisible = false

    @ObservationIgnored private var projectCounter = 0
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var isInitialized = false
    @ObservationIgnored private var terminationObservation: AnyCancellable?
    /// The stable terminal/editor responder displaced by the command palette's
    /// search field. AppKit field editors are deliberately excluded because a
    /// SwiftUI TextField can reuse the same responder for the palette itself.
    @ObservationIgnored private weak var commandPalettePreviousResponder: NSResponder?
    @ObservationIgnored private weak var commandPaletteWindow: NSWindow?
    /// Window hosting this manager, once SwiftUI has attached its content.
    /// Finder service requests use it to target the active Bailey window.
    @ObservationIgnored private weak var window: NSWindow?
    var attachedWindow: NSWindow? { window }

    /// Live managers in window-creation order; the persisted snapshot is
    /// one entry per registered manager.
    private static var registry: [TerminalManager] = []

    var hasUnsavedEditorsInWindow: Bool {
        projects.contains { project in
            project.tabs.contains { $0.content.isDirty }
        }
    }

    static var hasUnsavedEditors: Bool {
        registry.contains { $0.hasUnsavedEditorsInWindow }
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
        return true
    }

    static func saveBeforeTermination() async -> Bool {
        for manager in registry {
            guard await manager.saveBeforeWindowClose() else { return false }
        }
        return true
    }
    /// Read-only access for the private, authenticated SSH handoff.
    static var activeManagers: [TerminalManager] { registry }
    /// Folder requests can arrive while macOS is still launching Bailey, before
    /// a WindowGroup has produced a manager/window to receive them.
    private static var pendingDirectories: [String] = []
    /// System document events can precede SwiftUI windows and saved-window recovery.
    /// Keep the request and its completion together until the actual receiving
    /// window is ready; a queued event is not proof a file was opened.
    private struct PendingExternalOpen {
        let urls: [URL]
        let preferred: TerminalManager?
        let destination: (projectID: UUID, groupID: UUID)?
        let completion: (Bool) -> Void
    }
    private static var pendingExternalFiles: [PendingExternalOpen] = []
    /// Captured from SwiftUI's openWindow environment so a Finder request can
    /// reopen Bailey after the user has closed its last window.
    private static var windowOpener: (() -> Void)?
    /// Coalesces launch-time service requests while SwiftUI is still deciding
    /// whether it will create the initial WindowGroup window itself.
    private static var windowRequestScheduled = false
    private static var isOpeningWindow = false
    /// Window snapshots loaded from disk that no window has claimed yet.
    /// Each new manager claims the next; extras beyond the saved count
    /// start fresh.
    private static var pendingRestores: [SessionSnapshot] = []
    /// Terminal scrollback loaded from the sidecar store, keyed by the
    /// `historyKey` each restoring session pane carries. Shared across windows
    /// (keys are unique per pane), so restores read from it without consuming.
    private static var pendingHistories: [String: String] = [:]
    private static var hasLoadedStore = false
    /// Set on app termination so window teardown can't re-save a partial
    /// snapshot over the final full one.
    private static var isQuitting = false
    private static var didReopenWindows = false

    init() {
        if !Self.hasLoadedStore {
            Self.hasLoadedStore = true
            Self.pendingRestores = SessionStore.load()
            Self.pendingHistories = TerminalHistoryStore.load()
        }
        Self.registry.append(self)
        if !Self.pendingRestores.isEmpty {
            _ = restore(from: Self.pendingRestores.removeFirst())
        }
        // Only a window still claiming a snapshot reads the scrollback blobs,
        // so once the last one is claimed they are dead weight — several
        // hundred lines per restored session, held for the life of the process.
        if Self.pendingRestores.isEmpty, !Self.pendingHistories.isEmpty {
            Self.pendingHistories = [:]
        }
        let queuedDirectories = Self.takePendingDirectories()
        addLocalItems(queuedDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) })
        // The debounce can swallow changes made just before quitting;
        // capture a final snapshot while the shells are still alive.
        terminationObservation = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in
                guard !TerminalManager.isQuitting else { return }
                TerminalManager.isQuitting = true
                TerminalManager.saveAll(captureTerminalHistory: true)
            }
        isInitialized = true
        if !queuedDirectories.isEmpty { requestSave() }
    }

    /// Persist only changes to saved project/tab/layout content, not every UI redraw.
    func requestSave() {
        guard isInitialized, !Self.isQuitting else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard let self, !Task.isCancelled,
                  TerminalManager.registry.contains(where: { $0 === self }),
                  !TerminalManager.isQuitting else { return }
            TerminalManager.saveAll(captureTerminalHistory: false)
        }
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedSession: TerminalSession? {
        selectedProject?.selectedSession
    }

    // MARK: - Projects

    /// Only an explicitly selected folder creates or selects a local project.
    func addLocalItems(_ urls: [URL]) {
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
            addLocalItems([URL(fileURLWithPath: item.path, isDirectory: true)])
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
            self.addLocalItems(urls)
        }
    }

    func chooseFiles(inGroup destination: (projectID: UUID, groupID: UUID)? = nil) {
        guard let receivingWindow = window, selectedProject != nil else { return }
        if let destination {
            guard selectedProjectID == destination.projectID,
                  selectedProject?.dock.root.group(id: destination.groupID) != nil else { return }
        }
        WorkspaceNativeDialogs.chooseFiles(in: receivingWindow) { [weak self, weak receivingWindow] urls in
            guard let self, let receivingWindow, self.window === receivingWindow,
                  self.selectedProject != nil else { return }
            if let destination {
                guard self.selectedProjectID == destination.projectID,
                      self.selectedProject?.dock.root.group(id: destination.groupID) != nil else { return }
            }
            Self.openExternalFiles(urls, preferred: self, destination: destination)
        }
    }

    /// One SSH host can supply several independent roots. The remote file
    /// browser uses the already-supported POSIX shell on the SSH destination.
    func addSSHItems(host: String, paths: [String]) async throws {
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

    /// Finder/Dock documents use the original file tab in any window, then the
    /// receiving main window. Delay until all restored windows are registered
    /// and attached so cold launch never creates a second writable buffer.
    static func openExternalFiles(
        _ urls: [URL], preferred: TerminalManager? = nil,
        destination: (projectID: UUID, groupID: UUID)? = nil,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard !urls.isEmpty else { completion(false); return }
        guard preferred == nil || preferred?.window != nil else {
            completion(false)
            return
        }
        // This queue exists only while the OS is bringing a window on screen.
        // If window creation genuinely cannot complete, fail new requests
        // rather than retaining unbounded AppKit reply closures.
        guard pendingExternalFiles.count < 64 else {
            completion(false)
            return
        }
        pendingExternalFiles.append(.init(
            urls: urls, preferred: preferred, destination: destination, completion: completion
        ))
        deliverPendingExternalFiles()
        requestWindowForPendingDirectories()
    }

    private static func deliverPendingExternalFiles() {
        guard !pendingExternalFiles.isEmpty, pendingRestores.isEmpty,
              registry.contains(where: { $0.window != nil })
        else { return }

        let requests = pendingExternalFiles
        pendingExternalFiles = []
        for request in requests {
            // Not every manager in the process represents a window that will
            // appear. Only defer for an unmounted owner of a requested file.
            // Otherwise one unattached manager could block Finder permanently.
            let requestedPaths = Set(request.urls.filter(\.isFileURL).map {
                resolvedLocalPath($0.standardizedFileURL.path)
            })
            let awaitingOwner = registry.contains { manager in
                manager.window == nil && manager.projects.contains { project in
                    project.tabs.contains { tab in
                        guard case .file(let file) = tab.content,
                              file.workspaceIdentity == nil else { return false }
                        return requestedPaths.contains(resolvedLocalPath(file.path))
                    }
                }
            }
            if awaitingOwner {
                pendingExternalFiles.append(request)
                continue
            }
            let defaultManager = request.preferred
                ?? registry.first { $0.window != nil && $0.window === NSApp.keyWindow }
                ?? registry.first { $0.window != nil && $0.window === NSApp.mainWindow }
                ?? registry.last { $0.window != nil }
            guard let defaultManager, defaultManager.window != nil else {
                request.completion(false)
                continue
            }
            // Group by the actual owning window, including interleaved existing files.
            var groups: [(manager: TerminalManager, urls: [URL], lastIndex: Int)] = []
            for (index, url) in request.urls.enumerated() {
                let resolved = url.isFileURL
                    ? resolvedLocalPath(url.standardizedFileURL.path) : nil
                let alreadyOpen = resolved.flatMap { path in
                    registry.first { manager in
                        manager.projects.contains { project in
                            project.tabs.contains { tab in
                                guard case .file(let file) = tab.content,
                                      file.workspaceIdentity == nil else { return false }
                                return resolvedLocalPath(file.path) == path
                            }
                        }
                    }
                }
                let target = alreadyOpen ?? defaultManager
                if let position = groups.firstIndex(where: { $0.manager === target }) {
                    groups[position].urls.append(url)
                    groups[position].lastIndex = index
                } else {
                    groups.append((manager: target, urls: [url], lastIndex: index))
                }
            }
            // The final input determines focus, including interleaved files
            // that were already open in two other windows.
            groups.sort { $0.lastIndex < $1.lastIndex }
            var handled = false
            var lastReceiver: TerminalManager?
            for group in groups {
                let groupDestination = group.manager === request.preferred ? request.destination : nil
                let rejected = group.manager.openExternalLocalItems(
                    group.urls, destination: groupDestination
                )
                handled = handled || rejected.count < group.urls.count
                if let owner = group.manager.window, !rejected.isEmpty {
                    let message = group.manager.selectedProject == nil
                        ? String(localized: "Add a project folder before opening files.", table: "Interface")
                        : String(localized: "Some files or folders could not be opened in Bailey.", table: "Interface")
                    let details = rejected.map(\.lastPathComponent).joined(separator: "\n")
                    let error = NSError(domain: "Bailey.Finder", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: message,
                        NSLocalizedRecoverySuggestionErrorKey: details,
                    ])
                    WorkspaceNativeDialogs.showError(error, in: owner)
                }
                if rejected.count < group.urls.count { lastReceiver = group.manager }
            }
            if handled {
                NSApp.activate()
                lastReceiver?.window?.makeKeyAndOrderFront(nil)
            }
            request.completion(handled)
        }
    }

    /// Routes folders from the Finder service into the active Bailey window.
    /// If no window exists yet, the next WindowGroup manager claims them.
    static func openDirectories(_ directories: [String]) {
        guard !directories.isEmpty else { return }
        let manager = registry.first { $0.window != nil && $0.window === NSApp.keyWindow }
            ?? registry.first { $0.window != nil && $0.window === NSApp.mainWindow }
            ?? registry.last { $0.window != nil }
        guard let manager else {
            pendingDirectories.append(contentsOf: directories)
            requestWindowForPendingDirectories()
            return
        }

        manager.addLocalItems(
            directories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        manager.window?.makeKeyAndOrderFront(nil)
    }

    /// Called as soon as SwiftUI gives this manager an AppKit window. A
    /// launch-time Finder request may have been queued before that happened.
    func attach(to window: NSWindow) {
        self.window = window
        Self.isOpeningWindow = false
        let directories = Self.takePendingDirectories()
        addLocalItems(directories.map { URL(fileURLWithPath: $0, isDirectory: true) })
        if !directories.isEmpty {
            window.makeKeyAndOrderFront(nil)
        }
        Self.deliverPendingExternalFiles()
    }

    private static func takePendingDirectories() -> [String] {
        let directories = pendingDirectories
        pendingDirectories = []
        return directories
    }

    /// Installs SwiftUI's WindowGroup opener before any window needs to appear.
    /// Commands are constructed during app launch even when macOS starts Bailey
    /// solely to handle a service request.
    static func registerWindowOpener(_ open: @escaping () -> Void) {
        windowOpener = open
        deliverPendingExternalFiles()
        requestWindowForPendingDirectories()
    }

    private static func requestWindowForPendingDirectories() {
        guard (!pendingDirectories.isEmpty || !pendingExternalFiles.isEmpty),
              !registry.contains(where: { $0.window != nil }),
              !windowRequestScheduled,
              !isOpeningWindow
        else { return }

        windowRequestScheduled = true
        // Give SwiftUI's normal cold-launch window one turn to attach first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            windowRequestScheduled = false
            guard (!pendingDirectories.isEmpty || !pendingExternalFiles.isEmpty),
                  !registry.contains(where: { $0.window != nil }),
                  !isOpeningWindow
            else { return }

            isOpeningWindow = true
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue.hasPrefix("main") == true
            }) {
                window.makeKeyAndOrderFront(nil)
            } else if let windowOpener {
                windowOpener()
            } else {
                isOpeningWindow = false
            }
        }
    }

    private func makeProject() -> Project {
        projectCounter += 1
        let project = Project(
            fallbackName: "Project \(projectCounter)",
            workspaceConfiguration: AppSettings.shared.workspaceConfiguration
        )
        project.onSnapshotChange = { [weak self] in self?.requestSave() }
        return project
    }

    /// Losing the window's focus saves its active editor, not every open
    /// file across unrelated projects and remote machines.
    func autoSaveEditedTabs() {
        selectedProject?.selectedTab?.content.autoSaveOnFocusLoss()
    }

    func close(_ project: Project) {
        guard projects.contains(where: { $0 === project }) else { return }
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
            project.terminateAll()
            self.remove(project)
        }
    }

    private func remove(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects.remove(at: index)
        project.onSnapshotChange = nil
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
                project.selectedTabID = tab.id
                return
            }
        }
    }

    private static func location(forSession id: UUID) -> (manager: TerminalManager, project: Project, session: TerminalSession)? {
        for manager in registry {
            for project in manager.projects {
                if let session = project.sessions.first(where: { $0.id == id }) {
                    return (manager, project, session)
                }
            }
        }
        return nil
    }

    static func projectName(forSession id: UUID) -> String? {
        location(forSession: id)?.project.name
    }

    /// Activates Bailey and reveals the session that emitted a desktop
    /// notification. If the session has closed, still bring the app forward.
    static func revealSession(id: UUID) {
        NSApp.activate()
        if let location = location(forSession: id) {
            location.manager.revealSession(location.session)
            location.manager.window?.makeKeyAndOrderFront(nil)
            return
        }
        if let manager = registry.first(where: { $0.window != nil }) {
            manager.window?.makeKeyAndOrderFront(nil)
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

    /// Closes the selected work tab, or the empty project.
    func closeSelectedTab() {
        guard let project = selectedProject else { return }
        if project.tabs.isEmpty {
            close(project)
        } else {
            project.closeSelected()
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
    func openFile(_ path: String) {
        selectedProject?.openFile(path)
    }

    /// Opens a git diff tab in the current project.
    func openDiff(
        repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?
    ) {
        selectedProject?.openDiff(
            repoRoot: repoRoot, path: path, staged: staged,
            untracked: untracked, origPath: origPath
        )
    }

    /// Opens the selected path as changed by one historical commit.
    func openCommitDiff(
        repoRoot: String,
        path: String,
        commitHash: String,
        parentHash: String?,
        status: Character,
        origPath: String?
    ) {
        selectedProject?.openCommitDiff(
            repoRoot: repoRoot,
            path: path,
            commitHash: commitHash,
            parentHash: parentHash,
            status: status,
            origPath: origPath
        )
    }

    var canSaveSelectedFile: Bool { selectedProject?.focusedContent?.isDirty == true }

    /// Saves the focused pane if it holds a file or an editable diff.
    func saveSelectedFile() {
        guard let content = selectedProject?.focusedContent else { return }
        Task { await content.save() }
    }

    /// Keep tabs and pinned sidebar entries in sync on the affected machine,
    /// not in unrelated Mac/SSH projects with the same path.
    func fileRenamed(from oldPath: String, to newPath: String, workspace: String?) {
        for project in projects {
            project.updateFilePaths(from: oldPath, to: newPath, workspace: workspace)
        }
    }

    // MARK: - Panels & appearance

    func toggleFPSCounter() {
        isFPSCounterVisible.toggle()
    }

    func toggleCommandPalette() {
        if isCommandPaletteVisible {
            dismissCommandPalette()
        } else {
            commandPaletteWindow = NSApp.keyWindow
            if let responder = commandPaletteWindow?.firstResponder,
               isStableWorkspaceResponder(responder) {
                commandPalettePreviousResponder = responder
            } else {
                commandPalettePreviousResponder = nil
            }
            isCommandPaletteVisible = true
        }
    }

    func dismissCommandPalette() {
        guard isCommandPaletteVisible else { return }
        isCommandPaletteVisible = false
    }

    /// Called by the palette after SwiftUI has actually removed its focused
    /// search field from the window.
    func restoreFocusAfterCommandPalette() {
        let window = commandPaletteWindow
        let responder = commandPalettePreviousResponder
        commandPaletteWindow = nil
        commandPalettePreviousResponder = nil

        // Let the removal transaction finish before restoring the displaced
        // AppKit responder.
        DispatchQueue.main.async {
            guard let window, let responder else { return }
            // A palette command may already have focused a new terminal or
            // editor. Never let restoration race that newer focus and win.
            if let current = window.firstResponder,
               current !== responder,
               self.isStableWorkspaceResponder(current) {
                return
            }
            window.makeFirstResponder(responder)
        }
    }

    /// Terminal and editor responders are public host views. WebKit instead
    /// makes a private descendant of WKWebView first responder, so walk its
    /// AppKit ancestry before deciding whether palette dismissal can restore
    /// the page's keyboard focus.
    private func isStableWorkspaceResponder(_ responder: NSResponder) -> Bool {
        if responder is any TerminalBackendSurface || responder is FocusReportingTextView {
            return true
        }
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
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

    /// Flushes the complete multi-window snapshot before Settings starts a
    /// replacement app instance for a language change.
    static func saveForRelaunch() {
        saveAll(captureTerminalHistory: true)
    }

    /// After the first window appears, reopen one window per unclaimed
    /// saved snapshot; each new window's manager claims the next one.
    /// Deferred a runloop tick so windows the system itself restores can
    /// claim theirs first.
    static func openRestoredWindows(_ open: @escaping () -> Void) {
        registerWindowOpener(open)
        guard !didReopenWindows else { return }
        didReopenWindows = true
        DispatchQueue.main.async {
            for _ in 0..<pendingRestores.count {
                open()
            }
        }
    }

    /// Called when this manager's window closes: drop it from the
    /// persisted set — except for the last window, whose snapshot is kept
    /// saved and queued so reopening (or relaunching) restores it — and
    /// kill its shells.
    func windowClosed() {
        // A pending async Files error must not bring back the closed window.
        window = nil
        // A drop tied to a closing window must never reappear in another one.
        let abandoned = Self.pendingExternalFiles.filter { $0.preferred === self }
        Self.pendingExternalFiles.removeAll { $0.preferred === self }
        for request in abandoned { request.completion(false) }
        guard !Self.isQuitting else { return }
        pendingSave?.cancel()
        Self.registry.removeAll { $0 === self }
        if Self.registry.isEmpty {
            // These shells are about to be destroyed, so this is their final
            // capture even though the macOS app may remain open with no window.
            let window = makeWindowSnapshot(captureTerminalHistory: true)
            // Last window: keep its snapshot and scrollback saved and queued so
            // reopening (or relaunching) restores them.
            SessionStore.save([window.snapshot])
            TerminalHistoryStore.save(window.histories)
            Self.pendingRestores = [window.snapshot]
            Self.pendingHistories = window.histories
        } else {
            Self.saveAll(captureTerminalHistory: false)
        }
        for project in projects {
            project.terminateAll()
        }
    }

    // MARK: - Persistence

    private static func saveAll(captureTerminalHistory: Bool) {
        guard !registry.isEmpty else { return }
        var snapshots: [SessionSnapshot] = []
        var histories: [String: String] = [:]
        for manager in registry {
            let window = manager.makeWindowSnapshot(
                captureTerminalHistory: captureTerminalHistory
            )
            snapshots.append(window.snapshot)
            histories.merge(window.histories) { _, new in new }
        }
        SessionStore.save(snapshots)
        TerminalHistoryStore.save(histories)
    }

    /// Builds this window's layout snapshot and, alongside it, the scrollback
    /// to persist for its sessions. Each captured session gets a fresh
    /// `historyKey` stored on both sides so restore can pair them; sessions
    /// with no history (feature off, empty, or unserializable) get no key.
    private func makeWindowSnapshot(
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
    private func restore(from snapshot: SessionSnapshot) -> Bool {
        for saved in snapshot.projects {
            let project = makeProject()
            project.customName = Project.normalizedCustomName(saved.customName)
            project.customDirectory = saved.customDirectory
            project.sshHost = saved.sshHost
            project.pinnedFile = saved.pinnedFile
            var restoredContexts: [(tab: PaneTab, sessionIndex: Int)] = []
            for savedTab in saved.tabs {
                let tab = project.restoreTab(from: savedTab, histories: Self.pendingHistories)
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
                project.selectedTabID = project.tabs[index].id
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
