import AppKit
import Foundation

/// Application-owned window registry, Finder routing and session persistence.
/// A window owns projects and native content; the application only coordinates them.
@MainActor
final class WorkspaceApplication {
    private var windows: [WorkspaceWindowModel] = []
    /// A process-local capability for Files clipboard and internal drag payloads.
    let fileTransferToken = UUID()
    private var pendingDirectories: [String] = []
    private struct PendingExternalOpen {
        let urls: [URL]
        let preferred: WorkspaceWindowModel?
        let originalProjectID: UUID?
        let destination: (projectID: UUID, groupID: UUID)?
        let completion: (Bool) -> Void
    }
    private var pendingExternalFiles: [PendingExternalOpen] = []
    private var pendingRestores: [SessionSnapshot]
    private var pendingHistories: [String: String]
    private var windowOpener: (() -> Void)?
    private var windowRequestScheduled = false
    private var isOpeningWindow = false
    private var didReopenWindows = false
    private var pendingSave: Task<Void, Never>?
    private(set) var isQuitting = false

    /// GUI launch restores the saved windows; test owners start empty unless
    /// a test explicitly requests persisted state.
    init(loadSavedState: Bool = false) {
        pendingRestores = loadSavedState ? SessionStore.load() : []
        pendingHistories = loadSavedState ? TerminalHistoryStore.load() : [:]
        if BaileyInstanceMode.isIsolated,
           let path = ProcessInfo.processInfo.environment["BAILEY_UI_TEST_PROJECT"],
           URL(fileURLWithPath: path).standardizedFileURL.pathComponents.contains(
               where: { $0.hasPrefix("Bailey-UITest-") }
           ) {
            pendingDirectories = [path]
        }
    }

    func connectServices() {
        BaileySSHService.shared.application = self
        TerminalNotificationService.shared.application = self
    }

    func makeWindow() -> WorkspaceWindowModel {
        let window = WorkspaceWindowModel(application: self)
        register(window)
        return window
    }

    /// Register once when the real SwiftUI scene appears or an NSWindow
    /// actually attaches. View struct evaluation never consumes a snapshot.
    func register(_ manager: WorkspaceWindowModel) {
        guard !isQuitting,
              !windows.contains(where: { $0 === manager }),
              !manager.isClosed
        else { return }
        windows.append(manager)
        if !pendingRestores.isEmpty {
            _ = manager.restore(from: pendingRestores.removeFirst(), histories: pendingHistories)
        }
        if pendingRestores.isEmpty { pendingHistories = [:] }
        let directories = takePendingDirectories()
        manager.addLocalFolders(directories.map { URL(fileURLWithPath: $0, isDirectory: true) })
        manager.finishRegistration(hasNewDirectories: !directories.isEmpty)
        deliverPendingExternalFiles()
    }

    var windowCount: Int { windows.count }

    func containsWindow(_ window: WorkspaceWindowModel) -> Bool {
        windows.contains { $0 === window }
    }

    func owner(of window: NSWindow) -> WorkspaceWindowModel? {
        windows.first { !$0.isClosed && $0.attachedWindow === window }
    }

    func didAttach(_ manager: WorkspaceWindowModel) {
        guard containsWindow(manager) else { return }
        isOpeningWindow = false
        let directories = takePendingDirectories()
        manager.addLocalFolders(directories.map { URL(fileURLWithPath: $0, isDirectory: true) })
        if !directories.isEmpty { manager.attachedWindow?.makeKeyAndOrderFront(nil) }
        deliverPendingExternalFiles()
    }

    func requestSave(from manager: WorkspaceWindowModel) {
        guard !isQuitting, containsWindow(manager) else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard let self, !Task.isCancelled, !self.isQuitting,
                  self.containsWindow(manager) else { return }
            self.saveAll(captureTerminalHistory: false)
        }
    }

    var hasUnsavedEditors: Bool {
        windows.contains { $0.hasUnsavedEditorsInWindow }
    }

    func saveBeforeTermination() async -> Bool {
        for window in windows {
            guard await window.saveBeforeWindowClose() else { return false }
        }
        return !hasUnsavedEditors
    }

    func saveForRelaunch() {
        saveAll(captureTerminalHistory: true)
    }

    /// AppKit delivers willTerminate only once, independent of scene count.
    func willTerminate() {
        guard !isQuitting else { return }
        isQuitting = true
        pendingSave?.cancel()
        saveAll(captureTerminalHistory: true)
    }

    func windowClosed(_ manager: WorkspaceWindowModel) {
        let abandoned = pendingExternalFiles.filter { $0.preferred === manager }
        pendingExternalFiles.removeAll { $0.preferred === manager }
        for request in abandoned { request.completion(false) }
        guard !isQuitting, containsWindow(manager) else { return }
        pendingSave?.cancel()
        windows.removeAll { $0 === manager }
        if windows.isEmpty {
            let snapshot = manager.makeWindowSnapshot(captureTerminalHistory: true)
            pendingRestores.insert(snapshot.snapshot, at: 0)
            pendingHistories.merge(snapshot.histories) { _, new in new }
            SessionStore.save(pendingRestores)
            TerminalHistoryStore.save(pendingHistories)
        } else {
            saveAll(captureTerminalHistory: false)
        }
        // A removed, not-yet-attached window may have held the only copy of
        // a file that a surviving Finder receiver is waiting to reuse.
        deliverPendingExternalFiles()
    }

    private func saveAll(captureTerminalHistory: Bool) {
        guard !windows.isEmpty else { return }
        var snapshots: [SessionSnapshot] = []
        var histories = pendingHistories
        for manager in windows {
            let snapshot = manager.makeWindowSnapshot(
                captureTerminalHistory: captureTerminalHistory
            )
            snapshots.append(snapshot.snapshot)
            histories.merge(snapshot.histories) { _, new in new }
        }
        SessionStore.save(snapshots + pendingRestores)
        TerminalHistoryStore.save(histories)
    }

    private func fileLocation(_ content: PaneContent) -> (path: String, workspace: String?)? {
        switch content {
        case .file(let file): return (file.path, file.workspaceIdentity)
        case .diff(let diff) where diff.source == .worktree:
            return ((diff.repoRoot as NSString).appendingPathComponent(diff.path), diff.workspaceIdentity)
        case .session, .browser, .diff: return nil
        }
    }

    private func matchesFile(_ candidate: String, inside source: String, workspace: String?) -> Bool {
        if workspace == nil {
            let resolvedSource = LocalPathScope.resolvedPath(source)
            let resolvedCandidate = LocalPathScope.resolvedPath(candidate)
            return LocalPathScope.contains(candidate, in: source)
                || LocalPathScope.contains(resolvedCandidate, in: resolvedSource)
        }
        return LocalPathScope.contains(candidate, in: source)
    }

    /// Only editable resources in the actual Git repository can be saved or reloaded.
    private func gitContents(
        repository: String, scope: String, affectedPaths: [String]? = nil
    ) -> [PaneContent] {
        let workspace = scope == "local" ? nil : scope
        return windows.flatMap(\.projects).flatMap(\.tabs).compactMap { tab in
            switch tab.content {
            case .file(let file):
                guard file.workspaceIdentity == workspace,
                      matchesFile(file.path, inside: repository, workspace: workspace)
                else { return nil }
            case .diff(let diff):
                guard diff.workspaceIdentity == workspace,
                      diff.repoRoot == repository,
                      diff.source == .worktree || diff.source == .staged else { return nil }
            case .session, .browser:
                return nil
            }
            if let affectedPaths {
                let path: String?
                if case .diff(let diff) = tab.content, diff.source == .staged {
                    path = (diff.repoRoot as NSString).appendingPathComponent(diff.path)
                } else {
                    path = fileLocation(tab.content)?.path
                }
                guard let path, affectedPaths.contains(where: {
                    matchesFile(path, inside: $0, workspace: workspace)
                }) else { return nil }
            }
            return tab.content
        }
    }

    private func ensureDistinctDirtyFiles(_ affected: [PaneContent], workspace: String?) throws {
        var dirtyPaths = Set<String>()
        for content in affected where content.isDirty {
            guard let location = fileLocation(content) else { continue }
            let path = workspace == nil
                ? LocalPathScope.resolvedPath(location.path)
                : location.path
            guard dirtyPaths.insert(path).inserted else {
                throw NSError(domain: "Bailey.Files", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Two open editors have unsaved changes to the same file.",
                        table: "Workspace")
                ])
            }
        }
    }

    /// Save every registered editor affected by a Git worktree mutation.
    func saveBeforeGitAction(
        repository: String, scope: String, isCurrent: () -> Bool
    ) async -> Bool {
        let contents = gitContents(repository: repository, scope: scope)
        do {
            try ensureDistinctDirtyFiles(contents, workspace: scope == "local" ? nil : scope)
        } catch {
            return false
        }
        for content in contents {
            guard isCurrent() else { return false }
            await content.save()
            guard isCurrent(), !content.isDirty else { return false }
        }
        return isCurrent() && canRunGitAction(repository: repository, scope: scope)
    }

    func canRunGitAction(
        repository: String, scope: String, affectedPaths: [String]? = nil
    ) -> Bool {
        gitContents(repository: repository, scope: scope, affectedPaths: affectedPaths).allSatisfy {
            guard !$0.isDirty else { return false }
            switch $0 {
            case .file(let file): return !file.isSaving
            case .diff(let diff): return !diff.isSaving
            case .session, .browser: return true
            }
        }
    }

    func reloadAfterGitAction(
        repository: String, scope: String, affectedPaths: [String]? = nil
    ) {
        for content in gitContents(repository: repository, scope: scope, affectedPaths: affectedPaths) {
            switch content {
            case .file(let file): file.reloadFromDiskIfClean()
            case .diff(let diff): diff.reload(afterGitAction: true)
            case .session, .browser: break
            }
        }
    }

    /// Coordinate file and editable worktree diff tabs across registered windows.
    func withProtectedFiles<Result>(
        paths: [String], workspace: String?,
        operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        var seen: Set<UUID> = []
        let affected = windows.flatMap(\.projects).flatMap(\.tabs).compactMap { tab -> PaneContent? in
            let content = tab.content
            guard let location = fileLocation(content), location.workspace == workspace,
                  paths.contains(where: { matchesFile(location.path, inside: $0, workspace: workspace) }),
                  seen.insert(content.id).inserted else { return nil }
            return content
        }.sorted { $0.id.uuidString < $1.id.uuidString }

        try ensureDistinctDirtyFiles(affected, workspace: workspace)

        var held: [PaneContent] = []
        for content in affected {
            let ready: Bool
            switch content {
            case .file(let file): ready = await file.beginFileMutation()
            case .diff(let diff): ready = await diff.beginFileMutation()
            case .session, .browser: continue
            }
            guard ready else {
                held.forEach { releaseFileMutation($0) }
                throw NSError(
                    domain: "Bailey.Files", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        String(localized: "Could not save the open file before changing it.", table: "Workspace")]
                )
            }
            held.append(content)
        }
        defer { held.forEach { releaseFileMutation($0) } }
        return try await operation()
    }

    private func releaseFileMutation(_ content: PaneContent) {
        switch content {
        case .file(let file): file.endFileMutation()
        case .diff(let diff): diff.endFileMutation()
        case .session, .browser: break
        }
    }

    /// Use the existing registered window owners, not a second path registry.
    func fileRenamed(from oldPath: String, to newPath: String, workspace: String?) {
        for window in windows {
            for project in window.projects {
                for tab in project.tabs {
                    guard case .diff(let diff) = tab.content,
                          diff.workspaceIdentity == workspace,
                          let location = fileLocation(tab.content),
                          matchesFile(location.path, inside: oldPath, workspace: workspace)
                    else { continue }
                    diff.invalidateMovedFile()
                }
                project.updateFilePaths(from: oldPath, to: newPath, workspace: workspace)
            }
        }
    }

    /// Clean tabs close; an edit made during deletion remains visible but read-only.
    func filesDeleted(paths: [String], workspace: String?) {
        for window in windows {
            for project in window.projects {
                let targets = project.tabs.filter { tab in
                    guard let location = fileLocation(tab.content), location.workspace == workspace
                    else { return false }
                    return paths.contains { matchesFile(location.path, inside: $0, workspace: workspace) }
                }
                for tab in targets {
                    switch tab.content {
                    case .file(let file): file.invalidateDeletedFile()
                    case .diff(let diff): diff.invalidateMovedFile()
                    case .session, .browser: continue
                    }
                    if !tab.content.isDirty { project.close(tab) }
                }
            }
        }
    }

    /// A worktree is protected by any live project or content on its machine.
    func isWorktreeInUse(path: String, scope: String) -> Bool {
        func contains(_ candidate: String) -> Bool {
            let root = scope == "local"
                ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : path
            let value = scope == "local"
                ? URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path : candidate
            return LocalPathScope.contains(value, in: root)
        }
        return windows.contains { manager in
            manager.projects.contains { project in
                if project.panelContext?.scope == scope {
                    if let directory = project.customDirectory, contains(directory) { return true }
                    if project.sessions.contains(where: { contains($0.panelDirectoryPath) }) {
                        return true
                    }
                }
                return project.tabs.contains { tab in
                    switch tab.content {
                    case .file(let file):
                        return (file.workspaceIdentity ?? "local") == scope && contains(file.path)
                    case .diff(let diff):
                        return (diff.workspaceIdentity ?? "local") == scope && contains(diff.repoRoot)
                    case .session, .browser: return false
                    }
                }
            }
        }
    }

    func session(id: UUID) -> TerminalSession? {
        windows.lazy.flatMap(\.projects).flatMap(\.sessions).first { $0.id == id }
    }

    private func location(forSession id: UUID) -> (
        window: WorkspaceWindowModel, project: Project, session: TerminalSession
    )? {
        for window in windows {
            for project in window.projects {
                if let session = project.sessions.first(where: { $0.id == id }) {
                    return (window, project, session)
                }
            }
        }
        return nil
    }

    func projectName(forSession id: UUID) -> String? {
        location(forSession: id)?.project.name
    }

    func revealSession(id: UUID) {
        NSApp.activate()
        if let location = location(forSession: id) {
            location.window.revealSession(location.session)
            location.window.attachedWindow?.makeKeyAndOrderFront(nil)
        } else {
            windows.first(where: { $0.attachedWindow != nil })?
                .attachedWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func takePendingDirectories() -> [String] {
        let directories = pendingDirectories
        pendingDirectories = []
        return directories
    }

    func openDirectories(_ directories: [String]) {
        guard !directories.isEmpty else { return }
        let manager = windows.first { $0.attachedWindow != nil && $0.attachedWindow === NSApp.keyWindow }
            ?? windows.first { $0.attachedWindow != nil && $0.attachedWindow === NSApp.mainWindow }
            ?? windows.last { $0.attachedWindow != nil }
        guard let manager else {
            pendingDirectories.append(contentsOf: directories)
            requestWindowForPendingDirectories()
            return
        }
        manager.addLocalFolders(
            directories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        manager.attachedWindow?.makeKeyAndOrderFront(nil)
    }

    func openExternalFiles(
        _ urls: [URL], preferred: WorkspaceWindowModel? = nil,
        destination: (projectID: UUID, groupID: UUID)? = nil,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard !urls.isEmpty else { completion(false); return }
        guard preferred == nil || (
            preferred?.attachedWindow != nil && preferred?.application === self
        ) else {
            completion(false)
            return
        }
        pendingExternalFiles.append(.init(
            urls: urls, preferred: preferred, originalProjectID: preferred?.selectedProjectID,
            destination: destination, completion: completion
        ))
        deliverPendingExternalFiles()
        requestWindowForPendingDirectories()
    }

    private func deliverPendingExternalFiles() {
        guard !pendingExternalFiles.isEmpty, pendingRestores.isEmpty,
              windows.contains(where: { $0.attachedWindow != nil })
        else { return }

        let requests = pendingExternalFiles
        pendingExternalFiles = []
        for request in requests {
            if let preferred = request.preferred,
               preferred.selectedProjectID != request.originalProjectID {
                request.completion(false)
                continue
            }
            let requestedPaths = Set(request.urls.filter(\.isFileURL).map {
                Self.resolvedLocalPath($0.standardizedFileURL.path)
            })
            let awaitingOwner = windows.contains { manager in
                manager.attachedWindow == nil && manager.projects.contains { project in
                    project.tabs.contains { tab in
                        guard case .file(let file) = tab.content,
                              file.workspaceIdentity == nil else { return false }
                        return requestedPaths.contains(Self.resolvedLocalPath(file.path))
                    }
                }
            }
            if awaitingOwner {
                pendingExternalFiles.append(request)
                continue
            }
            let defaultManager = request.preferred
                ?? windows.first { $0.attachedWindow != nil && $0.attachedWindow === NSApp.keyWindow }
                ?? windows.first { $0.attachedWindow != nil && $0.attachedWindow === NSApp.mainWindow }
                ?? windows.last { $0.attachedWindow != nil }
            guard let defaultManager, defaultManager.attachedWindow != nil else {
                request.completion(false)
                continue
            }
            var groups: [(manager: WorkspaceWindowModel, urls: [URL], lastIndex: Int)] = []
            for (index, url) in request.urls.enumerated() {
                let resolved = url.isFileURL
                    ? Self.resolvedLocalPath(url.standardizedFileURL.path) : nil
                let alreadyOpen = resolved.flatMap { path in
                    windows.first { manager in
                        manager.projects.contains { project in
                            project.tabs.contains { tab in
                                guard case .file(let file) = tab.content,
                                      file.workspaceIdentity == nil else { return false }
                                return Self.resolvedLocalPath(file.path) == path
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
            groups.sort { $0.lastIndex < $1.lastIndex }
            var handled = false
            var lastReceiver: WorkspaceWindowModel?
            for group in groups {
                let groupDestination = group.manager === request.preferred ? request.destination : nil
                let rejected = group.manager.openExternalLocalItems(
                    group.urls, destination: groupDestination
                )
                handled = handled || rejected.count < group.urls.count
                if let owner = group.manager.attachedWindow, !rejected.isEmpty {
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
                lastReceiver?.attachedWindow?.makeKeyAndOrderFront(nil)
            }
            request.completion(handled)
        }
    }

    private static func resolvedLocalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func registerWindowOpener(_ open: @escaping () -> Void) {
        windowOpener = open
        deliverPendingExternalFiles()
        requestWindowForPendingDirectories()
    }

    /// Wait one turn for WindowGroup to create its own initial window before
    /// explicitly requesting another.
    private func requestWindowForPendingDirectories() {
        guard (!pendingDirectories.isEmpty || !pendingExternalFiles.isEmpty),
              !windows.contains(where: { $0.attachedWindow != nil }),
              !windowRequestScheduled, !isOpeningWindow
        else { return }
        windowRequestScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.windowRequestScheduled = false
            guard (!self.pendingDirectories.isEmpty || !self.pendingExternalFiles.isEmpty),
                  !self.windows.contains(where: { $0.attachedWindow != nil }),
                  !self.isOpeningWindow
            else { return }
            self.isOpeningWindow = true
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue.hasPrefix("main") == true
            }) {
                window.makeKeyAndOrderFront(nil)
            } else if let windowOpener = self.windowOpener {
                windowOpener()
            } else {
                self.isOpeningWindow = false
            }
        }
    }

    func openRestoredWindows(_ open: @escaping () -> Void) {
        registerWindowOpener(open)
        guard !didReopenWindows else { return }
        didReopenWindows = true
        DispatchQueue.main.async {
            for _ in 0..<self.pendingRestores.count { open() }
        }
    }
}
