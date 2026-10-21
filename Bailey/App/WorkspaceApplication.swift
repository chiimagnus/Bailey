import AppKit
import Foundation

/// Application-owned window registry, Finder routing and session persistence.
/// A window owns projects and native content; the application only coordinates them.
@MainActor
final class WorkspaceApplication {
    private var windows: [WorkspaceWindowModel] = []
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
