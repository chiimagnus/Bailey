import AppKit
import Observation
import SwiftUI

struct BaileyApp: App {
    @NSApplicationDelegateAdaptor(BaileyApplicationDelegate.self)
    private var applicationDelegate

    init() {
        TerminalFont.registerBundledFonts()
        applicationDelegate.workspace.connectServices()
        TerminalNotificationService.shared.configure()
        // Saved forwards are for other apps too (an RDP client, a browser),
        // so they open at launch rather than when Settings is first shown.
        if !BaileyInstanceMode.isIsolated { TunnelManager.shared.start() }
    }

    var body: some Scene {
        WindowGroup(AppIdentity.displayName, id: "main") {
            WindowRootView(application: applicationDelegate.workspace)
                .environment(applicationDelegate.menuPresentation)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(BaileyInstanceMode.isIsolated ? .suppressed : .automatic)
        .restorationBehavior(BaileyInstanceMode.isIsolated ? .disabled : .automatic)
        // Keep title-bar dragging away from interactive tabs. The empty
        // header surfaces opt in explicitly through WindowDragArea.
        .windowBackgroundDragBehavior(.disabled)
        .defaultSize(width: 900, height: 600)
        .commands {
            BaileyCommands(
                application: applicationDelegate.workspace,
                menuPresentation: applicationDelegate.menuPresentation
            )
        }

        Settings {
            SettingsView(application: applicationDelegate.workspace)
        }
    }
}

/// Root of one terminal window. Each window owns its own manager, which
/// claims the next unclaimed window snapshot; the first window to appear
/// reopens windows for any snapshots left over.
struct WindowRootView: View {
    let application: WorkspaceApplication
    @State private var manager: WorkspaceWindowModel

    init(application: WorkspaceApplication) {
        self.application = application
        _manager = State(initialValue: WorkspaceWindowModel(application: application))
    }
    private let settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(manager: manager)
            .focusedSceneValue(\.baileyManager, manager)
            // Each field is an actual terminal configuration input. Reading
            // them here lets Observation notify the existing native surface
            // only after the settings' didSet has applied and saved its value.
            .onChange(of: settings.fontFamily) { _, _ in manager.refreshAppearance() }
            .onChange(of: settings.fontSize) { _, _ in manager.refreshAppearance() }
            .onChange(of: settings.fontThicken) { _, _ in manager.refreshAppearance() }
            .onChange(of: settings.theme) { _, _ in manager.refreshAppearance() }
            .onChange(of: settings.themeDark) { _, _ in manager.refreshAppearance() }
            .onChange(of: settings.themeLight) { _, _ in manager.refreshAppearance() }
            .onChange(of: settings.macosOptionAsAlt) { _, _ in manager.refreshAppearance() }
            .onChange(of: settings.cursorShape) { _, _ in manager.refreshAppearance() }
            .onChange(of: settings.cursorBlinking) { _, _ in manager.refreshAppearance() }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didResignKeyNotification
            )) { notification in
                guard let window = notification.object as? NSWindow,
                      window === manager.attachedWindow else { return }
                manager.windowResignedKey()
            }
            .onAppear {
                application.register(manager)
                application.openRestoredWindows {
                    openWindow(id: "main")
                }
            }
            .onDisappear {
                manager.windowClosed()
            }
    }
}

/// A focused command has one identity per Git panel mount; its closure always
/// revalidates the current repository when invoked.
struct FocusedGitCommitAction: Equatable {
    let id: UUID
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct FocusedGitStageAllAction: Equatable {
    let target: PanelContext.Identity
    let repository: String
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target && lhs.repository == rhs.repository
    }
}

struct FocusedPathActions {
    let paths: (Bool) -> [String]
    let revealablePaths: () -> [String]

    static func file(
        _ file: FileTab, in project: Project,
        isValid: @escaping () -> Bool
    ) -> Self {
        let paths: (Bool) -> [String] = { absolute in
            guard isValid() else { return [] }
            if absolute { return [file.path] }
            guard file.workspaceIdentity == project.workspaceIdentity,
                  let root = project.customDirectory.map({ $0 == "/" ? "/" : $0 + "/" }),
                  file.path.hasPrefix(root) else { return [] }
            return [String(file.path.dropFirst(root.count))]
        }
        return Self(paths: paths, revealablePaths: {
            file.workspaceIdentity == nil ? paths(true) : []
        })
    }

    func copy(absolute: Bool) {
        let value = paths(absolute)
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value.joined(separator: "\n"), forType: .string)
    }

    func revealInFinder() {
        let value = revealablePaths()
        guard !value.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(value.map { URL(fileURLWithPath: $0) })
    }
}

extension FocusedValues {
    @Entry var baileyManager: WorkspaceWindowModel?
    @Entry var baileyGitCommit: FocusedGitCommitAction?
    @Entry var baileyGitStageAll: FocusedGitStageAllAction?
    @Entry var baileyPathActions: FocusedPathActions?
}

/// Presentation snapshots live only while AppKit tracks an open system menu.
@MainActor
@Observable
final class MainMenuPresentation {
    private struct ContextTracking {
        weak var menu: NSMenu?
        let isValid: () -> Bool
        var timestamp: TimeInterval?
        var canReplay: (() -> Bool)?
        var posted = false
        var cleanup: (() -> Void)?

        var shouldReplay: Bool { isValid() && canReplay?() == true }
    }

    // Only menu rows refresh during tracking; rebuilding Commands would drop native Window items.
    @ObservationIgnored private(set) var tracked: (panels: [PanelMenuEntry], projects: [ProjectMenuEntry])?
    @ObservationIgnored private var contextTracking: ContextTracking?
    @ObservationIgnored private var replayMonitor: Any?
    private var completedTrackings = 0
    private(set) var trackingEpoch = 0

    func panelEntries(for project: Project?) -> [PanelMenuEntry] {
        _ = completedTrackings
        return tracked?.panels ?? PanelMenuEntry.entries(for: project)
    }

    func projectEntries(for projects: [Project]) -> [ProjectMenuEntry] {
        _ = completedTrackings
        return tracked?.projects ?? ProjectMenuEntry.entries(for: projects)
    }

    func beginTracking(project: Project?, projects: [Project]) {
        tracked = (PanelMenuEntry.entries(for: project, captureDisplay: true),
                   ProjectMenuEntry.entries(for: projects, captureDisplay: true))
        trackingEpoch &+= 1
    }

    func endTracking() {
        tracked = nil
        completedTrackings &+= 1
    }

    func contextMenuStarted(_ menu: NSMenu, isValid: @escaping () -> Bool) {
        clearContextTracking()
        contextTracking = ContextTracking(menu: menu, isValid: isValid)
    }

    func finishContextMenu(_ menu: NSMenu, cleanup: @escaping () -> Void) {
        guard contextTracking?.menu === menu, NSApp.currentEvent?.type == .keyDown else {
            cleanup()
            return
        }
        contextTracking?.cleanup = cleanup
    }

    func contextMenuEnded(_ menu: NSMenu) {
        guard contextTracking?.menu === menu else { return }
        guard let event = NSApp.currentEvent, event.type == .keyDown else {
            clearContextTracking()
            return
        }
        let timestamp = event.timestamp
        contextTracking?.timestamp = timestamp
        nonisolated(unsafe) let deferredEvent = event
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let tracking = self.contextTracking,
                      tracking.timestamp == timestamp else { return }
                guard tracking.shouldReplay else {
                    self.clearContextTracking()
                    return
                }
                self.contextTracking?.posted = true
                if tracking.cleanup != nil {
                    self.replayMonitor = NSEvent.addLocalMonitorForEvents(
                        matching: [.keyDown, .leftMouseDown, .rightMouseDown]
                    ) { [weak self] incoming in
                        let discard = MainActor.assumeIsolated {
                            guard let self, let tracking = self.contextTracking,
                                  tracking.timestamp != nil else { return false }
                            let replay = incoming.timestamp == timestamp
                            if replay, tracking.shouldReplay { return false }
                            self.clearContextTracking()
                            return replay
                        }
                        return discard ? nil : incoming
                    }
                }
                NSApp.postEvent(deferredEvent, atStart: true)
            }
        }
    }

    func command(_ action: @escaping () -> Void) -> () -> Void {
        { self.perform(action) }
    }

    func perform(_ action: () -> Void, canReplay: @escaping () -> Bool = { true }) {
        guard let tracking = contextTracking, let event = NSApp.currentEvent,
              event.type == .keyDown, event.timestamp == tracking.timestamp else {
            if contextTracking?.timestamp != nil { clearContextTracking() }
            action()
            return
        }
        if tracking.posted {
            contextTracking?.timestamp = nil
            defer { clearContextTracking() }
            guard tracking.shouldReplay else { return }
            action()
        } else if tracking.canReplay == nil {
            contextTracking?.canReplay = canReplay
        }
    }

    private func clearContextTracking() {
        let cleanup = contextTracking?.cleanup
        contextTracking = nil
        if let replayMonitor { NSEvent.removeMonitor(replayMonitor) }
        replayMonitor = nil
        cleanup?()
    }
}

/// Menu commands routed to the focused window's manager.
private struct BaileyCommands: Commands {
    let application: WorkspaceApplication
    let menuPresentation: MainMenuPresentation
    @FocusedValue(\.baileyManager) private var focusedManager: WorkspaceWindowModel?
    @FocusedValue(\.baileyGitCommit) private var focusedGitCommit: FocusedGitCommitAction?
    @FocusedValue(\.baileyGitStageAll) private var focusedGitStageAll: FocusedGitStageAllAction?
    @FocusedValue(\.baileyPathActions) private var focusedPathActions: FocusedPathActions?
    @Environment(\.openWindow) private var openWindow
    private var pathActions: FocusedPathActions? {
        guard let manager else { return nil }
        if let project = manager.selectedProject,
           case .tab(let id)? = project.dock.contextTarget,
           project.dock.group(containing: .tab(id)) != nil,
           let tab = project.tabs.first(where: { $0.id == id }),
           case .file(let file) = tab.content {
            return .file(file, in: project, isValid: {
                manager.selectedProject === project && project.dock.contextTarget == .tab(id)
            })
        }
        if let project = manager.selectedProject,
           let context = project.panelContext,
           project.fileTree.syncedTarget(for: context) != nil,
           project.fileTree.contextOperationPaths != nil {
            let tree = project.fileTree
            let paths: (Bool) -> [String] = { absolute in
                guard manager.selectedProject === project,
                      tree.syncedTarget(for: context) != nil,
                      let values = tree.contextOperationPaths else { return [] }
                if absolute { return values }
                let root = tree.rootPath == "/" ? "/" : tree.rootPath + "/"
                return values.filter { $0.hasPrefix(root) }
                    .map { String($0.dropFirst(root.count)) }
            }
            return FocusedPathActions(paths: paths, revealablePaths: {
                guard !context.isRemote else { return [] }
                return paths(true)
            })
        }
        return focusedPathActions
    }
    private var diffLayoutMenuTitle: String {
        guard let style = manager?.diffLayoutTarget?.preferences.diffStyle else {
            return String(localized: "Diff Layout", table: "Git")
        }
        let next = style == .unified
            ? String(localized: "Split", table: "Git")
            : String(localized: "Unified", table: "Git")
        return String(format: String(localized: "Switch to %@", table: "Git"), next)
    }
    private var manager: WorkspaceWindowModel? {
        guard let focusedManager, NSApp.isActive,
              focusedManager.attachedWindow === NSApp.keyWindow else { return nil }
        return focusedManager
    }

    private func commandButton(_ title: String, action: @escaping () -> Void) -> Button<Text> {
        Button(title, action: menuPresentation.command(action))
    }

    var body: some Commands {
        let _ = application.registerWindowOpener {
            openWindow(id: "main")
        }
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {}

        CommandGroup(after: .pasteboard) {
            commandButton(String(localized: "Save", table: "Interface")) {
                manager?.saveSelectedFile()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(manager?.canSaveSelectedFile != true)

            Divider()

            // Find follows the active dock content, not the find bar's first responder.
            if manager?.canFind == true {
                Menu(String(localized: "Find", table: "Interface")) {
                    commandButton(String(localized: "Find…", table: "Interface")) {
                        manager?.performFindAction(.show)
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    commandButton(String(localized: "Find and Replace…", table: "Interface")) {
                        manager?.performFindAction(.replace)
                    }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(manager?.canReplace != true)

                    commandButton(String(localized: "Find Next", table: "Interface")) {
                        manager?.performFindAction(.next)
                    }
                    .keyboardShortcut("g", modifiers: .command)

                    Button(String(localized: "Find Previous", table: "Interface")) {
                        manager?.performFindAction(.previous)
                    }

                    commandButton(String(localized: "Use Selection for Find", table: "Interface")) {
                        manager?.performFindAction(.useSelection)
                    }
                    .keyboardShortcut("e", modifiers: .command)
                }
            } else {
                Button(String(localized: "Find", table: "Interface")) {}
                    .disabled(true)
            }
        }

        // Frees ⌘P from the default Print item for the command palette.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(replacing: .sidebar) {}

        CommandMenu(String(localized: "Panel", table: "Interface")) {
            commandButton(String(localized: "Command Palette…", table: "Interface")) {
                manager?.toggleCommandPalette()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(manager == nil)

            Divider()

            Button {
                manager?.showPanel(.projects)
            } label: {
                Label(String(localized: "Projects", table: "Interface"), systemImage: DockItem.projects.symbol)
                    .labelStyle(.titleAndIcon)
            }
            .disabled(manager?.selectedProject == nil)

            Button(action: menuPresentation.command { manager?.showPanel(.files) }) {
                Label(String(localized: "File Manager", table: "Sidebar"), systemImage: DockItem.files.symbol)
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button(action: menuPresentation.command { manager?.showPanel(.git) }) {
                Label(String(localized: "Git Manager", table: "Sidebar"), systemImage: DockItem.git.symbol)
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Divider()

            commandButton(String(localized: "Next Panel", table: "Interface")) {
                manager?.selectNextPanel()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled((manager?.selectedProject?.dock.tabOrder.count ?? 0) < 2)

            commandButton(String(localized: "Previous Panel", table: "Interface")) {
                manager?.selectPreviousPanel()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled((manager?.selectedProject?.dock.tabOrder.count ?? 0) < 2)

            commandButton(String(localized: "Switch Recent Panel", table: "Interface")) {
                if let manager { manager.tabSwitcher.cycle(in: manager, reverse: false) }
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled((manager?.selectedProject?.tabs.count ?? 0) < 2)

            commandButton(String(localized: "Switch Recent Panel Backward", table: "Interface")) {
                if let manager { manager.tabSwitcher.cycle(in: manager, reverse: true) }
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled((manager?.selectedProject?.tabs.count ?? 0) < 2)

            Button(String(localized: "Close Panel", table: "Interface")) {
                let owner = manager ?? NSApp.keyWindow.flatMap { application.owner(of: $0) }
                let project = owner?.selectedProject
                let target = project?.dock.contextTarget
                menuPresentation.perform({
                    if let owner { owner.closeActivePanelOrWindow() }
                    else { NSApp.keyWindow?.performClose(nil) }
                }, canReplay: {
                    project?.dock.contextTarget == target
                })
            }
            .keyboardShortcut("w", modifiers: .command)

            let entries = menuPresentation.panelEntries(for: manager?.selectedProject)
            if !entries.isEmpty {
                Divider()

                ForEach(entries) { item in
                    Button(action: menuPresentation.command { manager?.selectPanel(item.id) }) {
                        PanelMenuLabel(item: item, presentation: menuPresentation)
                    }
                    .keyboardShortcut(item.index < 9
                        ? KeyboardShortcut(KeyEquivalent(Character("\(item.index + 1)")), modifiers: .control)
                        : nil)
                }
            }
        }

        CommandMenu(String(localized: "Project", table: "Interface")) {
            commandButton(String(localized: "Add Projects…", table: "Interface")) {
                manager?.chooseFolders()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(manager == nil)

            Button(String(localized: "Add SSH Files or Projects…", table: "Interface")) {
                manager?.chooseSSHItems()
            }
            .disabled(manager == nil)

            Divider()

            commandButton(String(localized: "Next Project", table: "Interface")) {
                manager?.selectNextProject()
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled((manager?.projects.count ?? 0) < 2)

            commandButton(String(localized: "Previous Project", table: "Interface")) {
                manager?.selectPreviousProject()
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled((manager?.projects.count ?? 0) < 2)

            Button(String(localized: "Close Project", table: "Sidebar")) {
                if let project = manager?.selectedProject { manager?.close(project) }
            }
            .disabled(manager?.selectedProject == nil)

            let entries = menuPresentation.projectEntries(for: manager?.projects ?? [])
            if !entries.isEmpty {
                Divider()

                ForEach(entries) { item in
                    Button(action: menuPresentation.command {
                        if let index = manager?.projects.firstIndex(where: { $0.id == item.id }) {
                            manager?.selectProject(index: index)
                        }
                    }) {
                        ProjectMenuLabel(item: item, presentation: menuPresentation)
                    }
                    .keyboardShortcut(item.index < 9
                        ? KeyboardShortcut(KeyEquivalent(Character("\(item.index + 1)")), modifiers: .command)
                        : nil)
                }
            }
        }

        CommandMenu(String(localized: "File", table: "Interface")) {
            commandButton(String(localized: "New File…", table: "Sidebar")) {
                let action = manager?.newItemAction(isDirectory: false)
                Task { await action?() }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(manager?.selectedProject?.panelContext == nil)

            commandButton(String(localized: "New Folder…", table: "Sidebar")) {
                let action = manager?.newItemAction(isDirectory: true)
                Task { await action?() }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(manager?.selectedProject?.panelContext == nil)

            Divider()

            commandButton(String(localized: "Open File…", table: "Interface")) {
                manager?.chooseFiles()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(manager?.selectedProject == nil)

            Divider()

            commandButton(String(localized: "Copy Path", table: "Sidebar")) {
                pathActions?.copy(absolute: true)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(pathActions?.paths(true).isEmpty != false)

            commandButton(String(localized: "Copy Relative Path", table: "Sidebar")) {
                pathActions?.copy(absolute: false)
            }
            .keyboardShortcut("c", modifiers: [.command, .option, .shift])
            .disabled(pathActions?.paths(false).isEmpty != false)

            commandButton(String(localized: "Reveal in Finder", table: "Sidebar")) {
                pathActions?.revealInFinder()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(pathActions?.revealablePaths().isEmpty != false)

            Divider()

            commandButton(String(localized: "Stage All Changes", table: "Sidebar")) {
                if manager != nil { focusedGitStageAll?.perform() }
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(manager == nil || focusedGitStageAll == nil)

            commandButton(String(localized: "Commit Staged", table: "Sidebar")) {
                focusedGitCommit?.perform()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(focusedGitCommit == nil)

            Divider()

            commandButton(diffLayoutMenuTitle) {
                manager?.toggleDiffLayout()
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(manager?.diffLayoutTarget == nil)
        }

        CommandMenu(String(localized: "Terminal", table: "Terminal")) {
            commandButton(String(localized: "New Terminal", table: "Interface")) {
                manager?.newSession()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(manager?.selectedProject == nil)

            Divider()

            commandButton(String(localized: "Clear Terminal", table: "Interface")) {
                manager?.clearActiveTerminal()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(manager?.canClearActiveTerminal != true)
        }

        CommandMenu(String(localized: "Browser", table: "Browser")) {
            Button(String(localized: "New Browser Tab", table: "Interface")) {
                manager?.newBrowserTab()
            }
            .disabled(manager?.selectedProject == nil)

            Divider()

            commandButton(String(localized: "Focus Address Bar", table: "Interface")) {
                manager?.focusBrowserAddressBar()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(manager?.hasSelectedBrowser != true)

            commandButton(String(localized: "Reload Page", table: "Interface")) {
                manager?.reloadSelectedBrowser()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(manager?.hasSelectedBrowser != true)

            Button(String(localized: "Stop Loading", table: "Interface")) {
                manager?.stopSelectedBrowser()
            }
            .disabled(manager?.hasSelectedBrowser != true)

            Divider()

            Button(String(localized: "Open in Default Browser", table: "Interface")) {
                manager?.openSelectedPageInDefaultBrowser()
            }
            .disabled(manager?.hasSelectedBrowser != true)
        }

        CommandGroup(before: .windowArrangement) {
            commandButton(String(localized: "New Window", table: "Interface")) {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            commandButton(
                String(localized: NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
                    ? "Exit Full Screen" : "Enter Full Screen", table: "Interface")
            ) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            .disabled(NSApp.keyWindow == nil)
        }
    }
}

private struct PanelMenuLabel: View {
    let item: PanelMenuEntry
    let presentation: MainMenuPresentation

    var body: some View {
        let _ = presentation.trackingEpoch
        let display = presentation.tracked?.panels.first(where: { $0.id == item.id }) ?? item
        Label {
            Text(verbatim: display.title)
        } icon: {
            Image(nsImage: display.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
        }
        .labelStyle(.titleAndIcon)
    }
}

private struct ProjectMenuLabel: View {
    let item: ProjectMenuEntry
    let presentation: MainMenuPresentation

    var body: some View {
        let _ = presentation.trackingEpoch
        let display = presentation.tracked?.projects.first(where: { $0.id == item.id }) ?? item
        Label {
            Text(verbatim: display.title)
        } icon: {
            Image(nsImage: display.icon)
        }
        .labelStyle(.titleAndIcon)
    }
}

struct PanelMenuEntry: Identifiable {
    let id: DockItem
    let index: Int
    private let tab: PaneTab
    private let capturedDisplay: (title: String, icon: NSImage)?

    var title: String { capturedDisplay?.title ?? tab.displayTitle }
    var icon: NSImage { capturedDisplay?.icon ?? Self.icon(for: tab) }

    init(tab: PaneTab, index: Int, captureDisplay: Bool = false) {
        id = .tab(tab.id)
        self.index = index
        self.tab = tab
        capturedDisplay = captureDisplay ? (tab.displayTitle, Self.icon(for: tab)) : nil
    }

    private static func icon(for tab: PaneTab) -> NSImage {
        if let path = tab.content.fileIconPath {
            let fileIconPath = path.lowercased().hasSuffix(".md") ? "file.md" : path
            return MaterialFileIcon.image(forPath: fileIconPath)
        }
        if case .browser(let browser) = tab.content, let favicon = browser.favicon {
            return favicon
        }
        return NSImage(systemSymbolName: tab.content.systemImage, accessibilityDescription: nil) ?? NSImage()
    }

    static func entries(for project: Project?, captureDisplay: Bool = false) -> [Self] {
        guard let project else { return [] }
        let tabsByID = Dictionary(uniqueKeysWithValues: project.tabs.map { ($0.id, $0) })
        return project.dock.tabOrder.compactMap { tabsByID[$0] }.enumerated().map {
            Self(tab: $0.element, index: $0.offset, captureDisplay: captureDisplay)
        }
    }
}

struct ProjectMenuEntry: Identifiable {
    let id: UUID
    let index: Int
    private let project: Project
    private let capturedDisplay: (title: String, icon: NSImage)?

    var title: String { capturedDisplay?.title ?? project.name }
    var icon: NSImage { capturedDisplay?.icon ?? Self.icon(for: project) }

    init(project: Project, index: Int, captureDisplay: Bool = false) {
        id = project.id
        self.index = index
        self.project = project
        capturedDisplay = captureDisplay ? (project.name, Self.icon(for: project)) : nil
    }

    private static func icon(for project: Project) -> NSImage {
        NSImage(
            systemSymbolName: project.sshHost == nil ? "folder" : "network",
            accessibilityDescription: nil
        ) ?? NSImage()
    }

    static func entries(for projects: [Project], captureDisplay: Bool = false) -> [Self] {
        projects.enumerated().map {
            Self(project: $0.element, index: $0.offset, captureDisplay: captureDisplay)
        }
    }
}
