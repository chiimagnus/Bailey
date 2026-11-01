import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private let themeChanges = Theme.changes
    let manager: WorkspaceWindowModel
    @Environment(\.colorScheme) private var colorScheme
    private var tabSwitcher: TabSwitcherController { manager.tabSwitcher }
    @State private var git = GitStatusModel()

    /// Every terminal in the selected project can change the same repository.
    /// Watching command completion keeps the toolbar current without polling.
    private var commandCompletionSequences: [UUID: UInt64] {
        Dictionary(uniqueKeysWithValues:
            manager.selectedProject?.sessions.map {
                ($0.id, $0.commandLifecycle.completionSequence)
            } ?? []
        )
    }

    var body: some View {
        let _ = themeChanges.revision
        Group {
            if manager.selectedProject != nil {
                WorkspaceDockView(manager: manager, git: git)
            } else {
                VStack(spacing: 0) {
                    WindowDragArea()
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onDrop(of: [UTType.fileURL.identifier], delegate: FinderWindowDrop(manager: manager))
                }
                .background(Color(nsColor: Theme.background))
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            TerminalParkingView(sessions: parkedTerminalSessions)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            if manager.isCommandPaletteVisible {
                CommandPaletteView(manager: manager)
            }
        }
        .overlay {
            if tabSwitcher.isPresented, let project = manager.selectedProject,
               tabSwitcher.isPreviewing(project) {
                TabSwitcherOverlay(project: project, controller: tabSwitcher)
                    .zIndex(10)
            }
        }
        .background {
            TabSwitcherEventMonitor(controller: tabSwitcher)
                .frame(width: 0, height: 0)
        }
        .background(WindowChromeAccessor(
            onAttach: { manager.attach(to: $0) },
            hasUnsavedEdits: { manager.hasUnsavedEditorsInWindow },
            saveBeforeClose: { await manager.saveBeforeWindowClose() }
        ))
        .onAppear {
            installFileErrorPresentation()
            git.setLocalFileEventsForeground(NSApp.isActive)
            syncGit()
        }
        .onChange(of: manager.projects.map(\.id)) { installFileErrorPresentation() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            syncGit()
        }
        .onChange(of: commandCompletionSequences) { syncGit() }
        .onChange(of: manager.selectedProject?.panelContext?.identity) { syncGit() }
        .onChange(of: colorScheme) {
            manager.refreshAppearance()
        }
    }

    /// Sessions in the visible tab are owned by `TerminalHostView`; every
    /// other session stays window-attached in the invisible parking host.
    private var parkedTerminalSessions: [TerminalSession] {
        let visibleIDs = Set(
            manager.selectedProject?.dock.root.groups
                .compactMap { group -> PaneTab? in
                    guard case .tab(let id)? = group.selected else { return nil }
                    return manager.selectedProject?.tabs.first { $0.id == id }
                }
                .compactMap { tab -> UUID? in
                    if case .session(let session) = tab.content { return session.id }
                    return nil
                } ?? []
        )
        return manager.projects
            .flatMap(\.sessions)
            .filter { !visibleIDs.contains($0.id) }
    }

    /// Files may have been opened from a shortcut or another tool tab; the
    /// error is attached to its original window rather than a transient pane.
    private func installFileErrorPresentation() {
        for project in manager.projects {
            project.fileTree.onError = { [weak manager] title, detail in
                guard let window = manager?.attachedWindow, window.isVisible else { return }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = detail
                alert.alertStyle = .warning
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                alert.beginSheetModal(for: window, completionHandler: { _ in })
            }
        }
    }

    private func syncGit() {
        manager.syncGitStatus(git)
    }

    private var emptyState: some View {
        emptyStatePrompt(
            title: String(localized: "No open projects", table: "Interface"),
            buttonTitle: String(localized: "Add Projects…", table: "Interface"),
            action: { manager.chooseFolders() }
        )
    }

    private func emptyStatePrompt(
        title: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(verbatim: title)
                .foregroundStyle(.secondary)
            Button(action: action) { Text(verbatim: buttonTitle) }
                .accessibilityIdentifier("bailey.emptyState.addFolder")
        }
    }
}

/// Shared Finder URL conversion for ordinary SwiftUI drop regions. Never
/// mount this delegate above a native Ghostty terminal or WKWebView: those
/// surfaces own their own drag events.
@MainActor
struct FinderWindowDrop: DropDelegate {
    let manager: WorkspaceWindowModel
    var destination: (projectID: UUID, groupID: UUID)? = nil

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }

    func performDrop(info: DropInfo) -> Bool {
        Self.receive(
            info.itemProviders(for: [UTType.fileURL.identifier]),
            preferred: manager, destination: destination
        )
    }

    static func receive(
        _ providers: [NSItemProvider], preferred manager: WorkspaceWindowModel,
        destination: (projectID: UUID, groupID: UUID)? = nil
    ) -> Bool {
        let projectID = manager.selectedProjectID
        return receive(providers, preferred: manager) { urls, owner in
            guard owner.selectedProjectID == projectID else { return }
            if let destination {
                guard owner.selectedProjectID == destination.projectID,
                      owner.selectedProject?.dock.root.group(id: destination.groupID) != nil
                else { return }
            }
            manager.application.openExternalFiles(
                urls, preferred: owner, destination: destination
            )
        }
    }

    static func receive(
        _ providers: [NSItemProvider], preferred manager: WorkspaceWindowModel,
        action: @escaping @MainActor ([URL], WorkspaceWindowModel) -> Void
    ) -> Bool {
        guard let receivingWindow = manager.attachedWindow else { return false }
        let providers = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                && $0.canLoadObject(ofClass: NSURL.self)
        }
        guard !providers.isEmpty else { return false }
        Task { @MainActor [weak manager, weak receivingWindow] in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                        continuation.resume(returning: (object as? NSURL).map { $0 as URL })
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            guard let manager, let receivingWindow,
                  manager.attachedWindow === receivingWindow, !urls.isEmpty else { return }
            action(urls, manager)
        }
        return true
    }
}

/// Native presentation only. Project handles the save and tab-removal decision.
@MainActor
enum ProjectCloseConfirmation {
    static func alert(title: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Do you want to save the changes you made to \(title)?", table: "Workspace",
            comment: "Unsaved file or diff confirmation. The placeholder is a file name."
        )
        alert.informativeText = String(
            localized: "Your changes will be lost if you don't save them.", table: "Workspace"
        )
        alert.addButton(withTitle: String(localized: "Save", table: "Workspace"))
        alert.addButton(withTitle: String(localized: "Don’t Save", table: "Workspace")).keyEquivalent = ""
        alert.addButton(withTitle: String(localized: "Cancel", table: "Workspace")).keyEquivalent = "\u{1b}"
        return alert
    }

    static func present(title: String, in window: NSWindow?) async -> NSApplication.ModalResponse {
        let alert = alert(title: title)
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }
}

/// AppKit dialogs for the currently owned Bailey window. Business-side
/// validation and project mutations remain on WorkspaceWindowModel.
@MainActor
enum WorkspaceNativeDialogs {
    static func folderPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", table: "Terminal")
        panel.message = String(localized: "Add projects to Bailey", table: "Terminal")
        return panel
    }

    static func filePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Open", table: "Sidebar")
        panel.message = String(localized: "Open files in Bailey", table: "Terminal")
        return panel
    }

    static func chooseFolders(in window: NSWindow, onSelection: @escaping ([URL]) -> Void) {
        choose(folderPanel(), in: window, onSelection: onSelection)
    }

    static func chooseFiles(in window: NSWindow, onSelection: @escaping ([URL]) -> Void) {
        choose(filePanel(), in: window, onSelection: onSelection)
    }

    private static func choose(
        _ panel: NSOpenPanel, in window: NSWindow,
        onSelection: @escaping ([URL]) -> Void
    ) {
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            onSelection(panel.urls)
        }
    }

    static func chooseSSHItems(
        in window: NSWindow, aliases: [String], preferredHost: String?,
        onSelection: @escaping (String, [String]) -> Void
    ) {
        var submitted: (host: String, paths: [String])?
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        sheet.title = String(localized: "Add SSH Files or Projects", table: "Terminal")
        sheet.contentViewController = NSHostingController(rootView: SSHItemPickerView(
            aliases: aliases, preferredHost: preferredHost,
            onCancel: { [weak window, weak sheet] in
                guard let window, let sheet else { return }
                window.endSheet(sheet, returnCode: .cancel)
            },
            onSelection: { [weak window, weak sheet] host, paths in
                guard let window, let sheet else { return }
                submitted = (host, paths)
                window.endSheet(sheet, returnCode: .OK)
            }
        ))
        window.beginSheet(sheet) { response in
            guard response == .OK, let submitted else { return }
            onSelection(submitted.host, submitted.paths)
        }
    }

    static func showError(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window, completionHandler: { _ in })
        } else {
            alert.runModal()
        }
    }
}
