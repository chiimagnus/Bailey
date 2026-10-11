//
//  TerminalManager.swift
//  kero
//

import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

/// Panels available in the right sidebar. Raw values are stable names
/// persisted in `SessionSnapshot`.
enum RightPanel: String, Codable {
    case files
    case git
    case info
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
final class TerminalManager: nonisolated ObservableObject {
    @Published var projects: [Project] = []
    @Published var selectedProjectID: UUID? {
        willSet {
            // Diff hosts are expensive WebKit trees. Once a project has put
            // them in this window, keep that project's stack mounted across
            // project switches just as ContentView already does across tab
            // switches. Reattaching every open diff can otherwise block the
            // main thread while AppKit rebuilds the window/view hierarchy.
            if let selectedProjectID, selectedProjectID != newValue {
                retainedDiffProjectIDs.insert(selectedProjectID)
            }
        }
    }
    @Published var isPanelVisible = false
    @Published var panelTab: RightPanel = .files
    /// Visibility of the left project sidebar (⌘B). `isPanelVisible` above is
    /// the separate right panel.
    @Published var isLeftSidebarVisible = true
    /// Debug FPS badge in the sidebar header. Deliberately not persisted:
    /// every launch starts with it hidden.
    @Published var isFPSCounterVisible = false
    @Published private(set) var isCommandPaletteVisible = false

    /// Projects publish their own changes (session list, session selection);
    /// re-publish them so views observing the manager stay current.
    private var projectObservations: [UUID: AnyCancellable] = [:]
    /// Projects whose diff stacks have already been mounted in this window.
    /// Unvisited restored projects stay lazy so launch does not instantiate all
    /// of their WKWebViews at once.
    private var retainedDiffProjectIDs: Set<UUID> = []
    private var projectCounter = 0
    private var settingsObservation: AnyCancellable?
    private var autosaveObservation: AnyCancellable?
    private var terminationObservation: AnyCancellable?
    /// The stable terminal/editor responder displaced by the command palette's
    /// search field. AppKit field editors are deliberately excluded because a
    /// SwiftUI TextField can reuse the same responder for the palette itself.
    private weak var commandPalettePreviousResponder: NSResponder?
    private weak var commandPaletteWindow: NSWindow?
    /// Window hosting this manager, once SwiftUI has attached its content.
    /// Finder service requests use it to target the active Kero window.
    private weak var window: NSWindow?

    /// Live managers in window-creation order; the persisted snapshot is
    /// one entry per registered manager.
    private static var registry: [TerminalManager] = []
    /// Read-only access for the private, authenticated SSH handoff.
    static var activeManagers: [TerminalManager] { registry }
    /// Folder requests can arrive while macOS is still launching Kero, before
    /// a WindowGroup has produced a manager/window to receive them.
    private static var pendingDirectories: [String] = []
    /// Captured from SwiftUI's openWindow environment so a Finder request can
    /// reopen Kero after the user has closed its last window.
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
        // Reconfigure live sessions only when font, appearance, theme, or
        // terminal input settings change. Delivery is scheduled onto the main
        // queue because @Published emits in willSet — by then `didSet` has
        // pushed the theme onto NSApp (and the selection into `Theme`), so
        // `refreshAppearance` reads the new state.
        settingsObservation = Publishers.CombineLatest4(
            Publishers.CombineLatest4(
                AppSettings.shared.$fontFamily.removeDuplicates(),
                AppSettings.shared.$fontSize.removeDuplicates(),
                AppSettings.shared.$fontThicken.removeDuplicates(),
                AppSettings.shared.$theme.removeDuplicates()
            ),
            Publishers.CombineLatest(
                AppSettings.shared.$themeDark.removeDuplicates(),
                AppSettings.shared.$themeLight.removeDuplicates()
            ),
            AppSettings.shared.$macosOptionAsAlt.removeDuplicates(),
            Publishers.CombineLatest(
                AppSettings.shared.$cursorShape.removeDuplicates(),
                AppSettings.shared.$cursorBlinking.removeDuplicates()
            )
        )
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAppearance()
            }
        // Every project/tab/selection change re-publishes through the manager,
        // so a debounced sink snapshots layout after mutations settle without
        // reading live terminal contents.
        autosaveObservation = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { _ in
                TerminalManager.saveAll(captureTerminalHistory: false)
            }
        // The debounce can swallow changes made just before quitting;
        // capture a final snapshot while the shells are still alive.
        terminationObservation = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { _ in
                guard !TerminalManager.isQuitting else { return }
                TerminalManager.isQuitting = true
                TerminalManager.saveAll(captureTerminalHistory: true)
            }
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedSession: TerminalSession? {
        selectedProject?.selectedSession
    }

    /// Diff stacks that should remain in the window hierarchy. The selected
    /// project is included immediately; previously selected projects remain
    /// only when they actually own a diff.
    var projectsWithMountedDiffs: [Project] {
        projects.filter {
            $0.id == selectedProjectID
                || (retainedDiffProjectIDs.contains($0.id) && $0.hasDiffs)
        }
    }

    // MARK: - Projects

    /// Finder, the sidebar and the keyboard shortcut all add entries to the
    /// same project list. A selected file opens in an editor; its parent is
    /// the Files/Git root and initial terminal directory.
    func addLocalItems(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else {
                continue
            }
            let root = directory.boolValue
                ? path : (path as NSString).deletingLastPathComponent
            let file = directory.boolValue ? nil : path
            if let existing = projects.first(where: {
                $0.sshHost == nil && $0.customDirectory == root
                    && $0.pinnedFile == file
            }) {
                selectedProjectID = existing.id
                continue
            }
            let project = makeProject()
            project.customName = url.lastPathComponent
            project.customDirectory = root
            project.pinnedFile = file
            if let file { project.openFile(file) }
            insert(project)
        }
    }

    func chooseLocalItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", table: "Terminal")
        panel.message = String(localized: "Add files and folders to Kero", table: "Terminal")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.addLocalItems(panel.urls)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
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
        let alert = NSAlert()
        alert.messageText = String(localized: "Add SSH Files or Folders", table: "Terminal")
        alert.informativeText = String(localized:
            "Use an SSH host from ~/.ssh/config and one remote path per line. Windows paths such as D:\\GitHub\\project are accepted.", table: "Terminal")
        alert.addButton(withTitle: String(localized: "Add", table: "Terminal"))
        alert.addButton(withTitle: String(localized: "Cancel", table: "Terminal"))

        let hosts = NSComboBox()
        hosts.usesDataSource = false
        hosts.addItems(withObjectValues: Self.sshHostAliases())
        hosts.placeholderString = String(localized: "SSH host", table: "Terminal")
        if let first = hosts.objectValues.first as? String {
            hosts.stringValue = first
        }

        let scroll = NSTextView.scrollableTextView()
        let paths = scroll.documentView as! NSTextView
        paths.isRichText = false
        paths.isAutomaticQuoteSubstitutionEnabled = false
        paths.isAutomaticDashSubstitutionEnabled = false
        paths.isAutomaticTextReplacementEnabled = false
        paths.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true

        let stack = NSStackView(views: [
            NSTextField(labelWithString: String(localized: "SSH host", table: "Terminal")),
            hosts,
            NSTextField(labelWithString: String(localized: "Remote paths (one per line)", table: "Terminal")),
            scroll,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: hosts)

        // NSAlert sizes an accessory from its frame, not the constraints on its children.
        // A zero-sized stack lets the form overlap the alert's title and description.
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 214))
        accessory.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor, constant: -8),
            hosts.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        alert.accessoryView = accessory

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let host = hosts.stringValue
            let values = paths.string.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            Task {
                do {
                    try await self.addSSHItems(host: host, paths: values)
                } catch {
                    let failure = NSAlert(error: error)
                    if let window = self.window {
                        failure.beginSheetModal(for: window, completionHandler: { _ in })
                    } else {
                        failure.runModal()
                    }
                }
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
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

    /// Routes folders from the Finder service into the active Kero window.
    /// If no window exists yet, the next WindowGroup manager claims them.
    static func openDirectories(_ directories: [String]) {
        guard !directories.isEmpty else { return }
        let manager = registry.first { $0.window === NSApp.keyWindow }
            ?? registry.first { $0.window === NSApp.mainWindow }
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
    }

    private static func takePendingDirectories() -> [String] {
        let directories = pendingDirectories
        pendingDirectories = []
        return directories
    }

    /// Installs SwiftUI's WindowGroup opener before any window needs to appear.
    /// Commands are constructed during app launch even when macOS starts Kero
    /// solely to handle a service request.
    static func registerWindowOpener(_ open: @escaping () -> Void) {
        windowOpener = open
        requestWindowForPendingDirectories()
    }

    private static func requestWindowForPendingDirectories() {
        guard !pendingDirectories.isEmpty,
              !registry.contains(where: { $0.window != nil }),
              !windowRequestScheduled,
              !isOpeningWindow
        else { return }

        windowRequestScheduled = true
        // Give SwiftUI's normal cold-launch window one turn to attach first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            windowRequestScheduled = false
            guard !pendingDirectories.isEmpty,
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
        let project = Project(fallbackName: "Project \(projectCounter)")
        projectObservations[project.id] = project.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return project
    }

    func close(_ project: Project) {
        project.terminateAll()
        remove(project)
    }

    private func remove(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects.remove(at: index)
        projectObservations[project.id] = nil
        if selectedProjectID == project.id {
            let neighbor = min(index, projects.count - 1)
            selectedProjectID = neighbor >= 0 ? projects[neighbor].id : nil
        }
        retainedDiffProjectIDs.remove(project.id)
        // Only an explicit project closure removes the Files/Git workspace.
        // Closing its last terminal never collapses the right sidebar.
        if projects.isEmpty {
            isPanelVisible = false
        }
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

    /// New sessions and browser tabs belong to the selected sidebar item.
    func newSession() {
        selectedProject?.newSession()
    }

    func newBrowserTab(initialURL: String? = nil) {
        selectedProject?.newBrowserTab(
            initialURL: initialURL,
            initialFocus: initialURL == nil ? .addressBar : .webContent
        )
    }

    /// Opens a browser beside the focused pane in the current tab.
    func newBrowserPane(
        toward edge: PaneDropEdge = .right,
        initialURL: String? = nil
    ) {
        selectedProject?.newBrowserPane(
            toward: edge,
            initialURL: initialURL,
            initialFocus: initialURL == nil ? .addressBar : .webContent
        )
    }

    /// Brings `session` to the foreground: selects its project and tab, then
    /// focuses its pane. Backs the command palette's session switcher; a no-op
    /// if the session is no longer open anywhere.
    func revealSession(_ session: TerminalSession) {
        for project in projects {
            for tab in project.tabs {
                guard let paneID = tab.paneID(forContent: session.id) else { continue }
                selectedProjectID = project.id
                project.selectedTabID = tab.id
                tab.focusedPaneID = paneID
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

    /// Activates Kero and reveals the session that emitted a desktop
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

    /// Closes the focused pane (⌘W). When it's the last pane in its tab the
    /// tab closes too — matching the old single-content-tab behavior. Once the
    /// project has no tabs left, ⌘W closes the project itself.
    func closeSelectedTab() {
        guard let project = selectedProject else { return }
        if project.tabs.isEmpty {
            close(project)
        } else {
            project.closeFocusedPane()
        }
    }

    // MARK: - Panes

    func splitRight() { selectedProject?.splitRight() }
    func splitLeft() { selectedProject?.splitLeft() }
    func splitDown() { selectedProject?.splitDown() }
    func splitUp() { selectedProject?.splitUp() }
    func split(toward edge: PaneDropEdge) { selectedProject?.split(toward: edge) }
    func focusPaneLeft() { selectedProject?.focusLeft() }
    func focusPaneRight() { selectedProject?.focusRight() }
    func focusPaneUp() { selectedProject?.focusUp() }
    func focusPaneDown() { selectedProject?.focusDown() }
    func focusNextPane() { selectedProject?.focusNextPane() }
    func focusPreviousPane() { selectedProject?.focusPreviousPane() }

    func togglePaneZoom() { selectedProject?.togglePaneZoom() }
    func equalizePanes() { selectedProject?.equalizePanes() }
    func resizePaneUp() { selectedProject?.resizePaneUp() }
    func resizePaneDown() { selectedProject?.resizePaneDown() }
    func resizePaneLeft() { selectedProject?.resizePaneLeft() }
    func resizePaneRight() { selectedProject?.resizePaneRight() }

    /// Whether the focused pane can be split right now (false for diffs / no
    /// project).
    var canSplit: Bool { selectedProject?.canSplit ?? false }

    /// Whether the selected tab holds more than one pane — gates the zoom,
    /// resize and equalize commands.
    var hasSplitPanes: Bool { selectedProject?.hasSplitPanes ?? false }

    /// Whether the selected tab is showing a zoomed pane — drives the header's
    /// exit-zoom indicator.
    var isPaneZoomed: Bool { selectedProject?.isPaneZoomed ?? false }

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

    /// Opens `path` as a file tab in the current project.
    func openFile(_ path: String) {
        selectedProject?.openFile(path)
    }

    /// Opens `path` as a pane beside the focused one in the current tab.
    func openFileToSide(_ path: String) {
        selectedProject?.openFileToSide(path)
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

    func toggleSidebar() {
        isPanelVisible.toggle()
    }

    func toggleLeftSidebar() {
        isLeftSidebarVisible.toggle()
    }

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

    /// Reveal an existing tool wherever it was docked. The shortcut must not
    /// clone or move a panel back to the right after the user relocated it.
    func togglePanel(_ panel: RightPanel) {
        let dockItem: DockItem = switch panel {
        case .info: .info
        case .files: .files
        case .git: .git
        }
        let previousPanel = panelTab
        panelTab = panel
        guard let project = selectedProject else { return }
        if let owner = project.dock.group(containing: dockItem) {
            let alreadySelected = owner.selected == dockItem
            project.dock.select(dockItem)
            switch owner.region {
            case .left: isLeftSidebarVisible = true
            case .right:
                isPanelVisible = !(isPanelVisible && alreadySelected && previousPanel == panel)
            case .main, .extra: break
            }
        } else {
            project.dock.place(dockItem, in: .right)
            isPanelVisible = true
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

    /// Re-themes every open window for app-wide changes that do not mutate an
    /// `AppSettings` publisher, such as a transient CLI theme preview.
    static func refreshAllAppearances() {
        for manager in registry {
            manager.refreshAppearance()
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
        guard !Self.isQuitting else { return }
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
                    guard let layout = Self.layoutSnapshot(
                        tab.layout,
                        sshHost: project.sshHost,
                        captureTerminalHistory: captureTerminalHistory,
                        histories: &histories
                    ) else { return nil }
                    // Restore rebuilds panes from the layout that was written,
                    // so focus is an index into the panes that survived it.
                    let focusedPaneIndex = tab.allPanes
                        .filter { Self.isSnapshotable($0.content, sshHost: project.sshHost) }
                        .firstIndex { $0.id == tab.focusedPaneID } ?? 0
                    return (tab, ProjectSnapshot.TabSnapshot(
                        layout: layout, focusedPaneIndex: focusedPaneIndex,
                        customName: tab.customName,
                        contextSessionIndex: tab.contextSession.flatMap { context in
                            projectSessions.firstIndex { $0.id == context.id }
                        }
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
            selectedProjectIndex: projects.firstIndex { $0.id == selectedProjectID },
            isLeftSidebarVisible: isLeftSidebarVisible,
            isRightPanelVisible: isPanelVisible,
            rightPanelTab: panelTab
        )
        return (snapshot, histories)
    }

    /// Unmanaged SSH panes are not persisted without a machine identity.
    /// Explicit SSH roots do persist remote tabs because their host is saved.
    private static func layoutSnapshot(
        _ layout: PaneNode,
        sshHost: String?,
        captureTerminalHistory: Bool,
        histories: inout [String: String]
    ) -> SessionSnapshot.ProjectSnapshot.LayoutSnapshot? {
        typealias ProjectSnapshot = SessionSnapshot.ProjectSnapshot
        switch layout {
        case .pane(let pane):
            guard let content = contentSnapshot(pane.content, sshHost: sshHost) else { return nil }
            var historyKey: String?
            if case .session(let session) = pane.content,
               let history = session.serializedHistory(
                   captureLive: captureTerminalHistory
               ), !history.isEmpty {
                let key = UUID().uuidString
                histories[key] = history
                historyKey = key
            }
            return .pane(ProjectSnapshot.PaneSnapshot(
                content: content,
                weight: 1,
                historyKey: historyKey
            ))
        case .split(let split):
            let first = layoutSnapshot(
                split.first,
                sshHost: sshHost,
                captureTerminalHistory: captureTerminalHistory,
                histories: &histories
            )
            let second = layoutSnapshot(
                split.second,
                sshHost: sshHost,
                captureTerminalHistory: captureTerminalHistory,
                histories: &histories
            )
            switch (first, second) {
            case (nil, nil):
                return nil
            case (let onlyOne?, nil), (nil, let onlyOne?):
                return onlyOne
            case (let first?, let second?):
                return .split(
                    axis: split.axis,
                    fraction: Double(split.fraction),
                    first: first,
                    second: second
                )
            }
        }
    }

    /// A remote path can be saved only when its SSH host is pinned on the
    /// sidebar item. Otherwise relaunch could read a same-named Mac file.
    private static func isSnapshotable(_ content: PaneContent, sshHost: String?) -> Bool {
        let identity = sshHost.map { "ssh:" + $0 }
        switch content {
        case .file(let file): return file.workspaceIdentity == identity
        case .diff(let diff): return diff.workspaceIdentity == identity
        case .session, .browser: return true
        }
    }

    private static func contentSnapshot(
        _ content: PaneContent, sshHost: String?
    ) -> SessionSnapshot.ProjectSnapshot.PaneContentSnapshot? {
        guard isSnapshotable(content, sshHost: sshHost) else { return nil }
        switch content {
        case .session(let session):
            return .session(workingDirectory: session.currentDirectoryPath)
        case .file(let file):
            return .file(path: file.path, editorState: file.editorState)
        case .browser(let browser):
            return .browser(url: browser.snapshotURL)
        case .diff(let diff):
            if let commitHash = diff.commitHash {
                return .commitDiff(
                    repoRoot: diff.repoRoot,
                    path: diff.path,
                    commitHash: commitHash,
                    parentHash: diff.commitParentHash,
                    status: diff.commitStatus.map(String.init) ?? "M",
                    origPath: diff.origPath
                )
            }
            return .diff(
                repoRoot: diff.repoRoot, path: diff.path, staged: diff.staged,
                untracked: diff.untracked, origPath: diff.origPath
            )
        }
    }

    /// Rebuilds projects and tabs from a saved window snapshot. Returns
    /// false when the snapshot holds nothing restorable. Sidebar state is
    /// applied even then — the window claimed this snapshot's layout.
    private func restore(from snapshot: SessionSnapshot) -> Bool {
        if let visible = snapshot.isLeftSidebarVisible { isLeftSidebarVisible = visible }
        if let visible = snapshot.isRightPanelVisible { isPanelVisible = visible }
        if let tab = snapshot.rightPanelTab { panelTab = tab }
        for saved in snapshot.projects {
            let project = makeProject()
            project.customName = Project.normalizedCustomName(saved.customName)
            project.customDirectory = saved.customDirectory
            project.sshHost = saved.sshHost
            project.pinnedFile = saved.pinnedFile
            var restoredContexts: [(tab: PaneTab, sessionIndex: Int)] = []
            for savedTab in saved.tabs {
                guard let tab = project.restoreTab(
                    from: savedTab, histories: Self.pendingHistories
                ) else { continue }
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
            if let dock = saved.dock {
                project.dock.restore(dock, tabIDs: project.tabs.map(\.id))
            } else if let legacyPanel = snapshot.rightPanelTab {
                let item: DockItem = switch legacyPanel {
                case .info: .info
                case .files: .files
                case .git: .git
                }
                project.dock.select(item)
            }
            project.resetRecency()
            if let pinnedFile = project.pinnedFile,
               !project.tabs.flatMap(\.allContents).contains(where: { content in
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
