import AppKit
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
        }
        .windowStyle(.hiddenTitleBar)
        // Keep title-bar dragging away from interactive tabs. The empty
        // header surfaces opt in explicitly through WindowDragArea.
        .windowBackgroundDragBehavior(.disabled)
        .defaultSize(width: 900, height: 600)
        .commands {
            BaileyCommands(application: applicationDelegate.workspace)
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
                manager.autoSaveEditedTabs()
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

extension FocusedValues {
    @Entry var baileyManager: WorkspaceWindowModel?
}

/// Menu commands routed to the focused window's manager.
private struct BaileyCommands: Commands {
    let application: WorkspaceApplication
    @FocusedValue(\.baileyManager) private var focusedManager: WorkspaceWindowModel?
    private var manager: WorkspaceWindowModel? {
        guard let focusedManager, NSApp.isActive,
              focusedManager.attachedWindow === NSApp.keyWindow else { return nil }
        return focusedManager
    }
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = application.registerWindowOpener {
            openWindow(id: "main")
        }

        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {}

        CommandGroup(after: .pasteboard) {
            // Find follows the active dock content, not the find bar's first responder.
            if manager?.canFind == true {
                Menu(String(localized: "Find", table: "Interface")) {
                    Button(String(localized: "Find…", table: "Interface")) {
                        manager?.performFindAction(.show)
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    Button(String(localized: "Find and Replace…", table: "Interface")) {
                        manager?.performFindAction(.replace)
                    }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(manager?.canReplace != true)

                    Button(String(localized: "Find Next", table: "Interface")) {
                        manager?.performFindAction(.next)
                    }
                    .keyboardShortcut("g", modifiers: .command)

                    Button(String(localized: "Find Previous", table: "Interface")) {
                        manager?.performFindAction(.previous)
                    }

                    Button(String(localized: "Use Selection for Find", table: "Interface")) {
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
            Button(String(localized: "Command Palette…", table: "Interface")) {
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

            Button {
                manager?.showPanel(.files)
            } label: {
                Label(String(localized: "File Manager", table: "Sidebar"), systemImage: DockItem.files.symbol)
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button {
                manager?.showPanel(.git)
            } label: {
                Label(String(localized: "Git Manager", table: "Sidebar"), systemImage: DockItem.git.symbol)
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Divider()

            Button(String(localized: "Next Panel", table: "Interface")) {
                manager?.selectNextPanel()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled((manager?.selectedProject?.dock.tabOrder.count ?? 0) < 2)

            Button(String(localized: "Previous Panel", table: "Interface")) {
                manager?.selectPreviousPanel()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled((manager?.selectedProject?.dock.tabOrder.count ?? 0) < 2)

            Button(String(localized: "Close Panel", table: "Interface")) {
                if let manager, let project = manager.selectedProject,
                   project.dock.activeGroup?.selected != nil || project.tabs.isEmpty {
                    manager.closeSelectedTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            if let project = manager?.selectedProject, !project.dock.tabOrder.isEmpty {
                Divider()

                let tabsByID = Dictionary(uniqueKeysWithValues: project.tabs.map { ($0.id, $0) })
                ForEach(Array(project.dock.tabOrder.compactMap { tabsByID[$0] }.enumerated()).map {
                    PanelMenuEntry(tab: $0.element, index: $0.offset)
                }) { item in
                    Button {
                        manager?.selectPanel(item.id)
                    } label: {
                        Label {
                            Text(verbatim: item.title)
                        } icon: {
                            Image(nsImage: item.icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 16, height: 16)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                    .keyboardShortcut(item.index < 9
                        ? KeyboardShortcut(KeyEquivalent(Character("\(item.index + 1)")), modifiers: .control)
                        : nil)
                }
            }
        }

        CommandMenu(String(localized: "Project", table: "Interface")) {
            Button(String(localized: "Add Projects…", table: "Interface")) {
                manager?.chooseFolders()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(manager == nil)

            Button(String(localized: "Add SSH Files or Projects…", table: "Interface")) {
                manager?.chooseSSHItems()
            }
            .disabled(manager == nil)

            Divider()

            Button(String(localized: "Next Project", table: "Interface")) {
                manager?.selectNextProject()
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled((manager?.projects.count ?? 0) < 2)

            Button(String(localized: "Previous Project", table: "Interface")) {
                manager?.selectPreviousProject()
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled((manager?.projects.count ?? 0) < 2)

            Button(String(localized: "Close Project", table: "Sidebar")) {
                if let project = manager?.selectedProject { manager?.close(project) }
            }
            .disabled(manager?.selectedProject == nil)

            if manager?.projects.isEmpty == false {
                Divider()

                ForEach(Array((manager?.projects ?? []).enumerated()).map {
                    ProjectMenuEntry(project: $0.element, index: $0.offset)
                }) { item in
                    Button {
                        manager?.selectProject(index: item.index)
                    } label: {
                        Label {
                            Text(verbatim: item.title)
                        } icon: {
                            Image(nsImage: item.icon)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                    .keyboardShortcut(item.index < 9
                        ? KeyboardShortcut(KeyEquivalent(Character("\(item.index + 1)")), modifiers: .command)
                        : nil)
                }
            }
        }

        CommandMenu(String(localized: "File", table: "Interface")) {
            Button(String(localized: "New File…", table: "Sidebar")) {
                Task { await manager?.newFile() }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(manager?.selectedProject?.panelContext == nil)

            Button(String(localized: "New Folder…", table: "Sidebar")) {
                Task { await manager?.newFolder() }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(manager?.selectedProject?.panelContext == nil)

            Divider()

            Button(String(localized: "Open File…", table: "Interface")) {
                manager?.chooseFiles()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(manager?.selectedProject == nil)

            Divider()

            Button(String(localized: "Save", table: "Interface")) {
                manager?.saveSelectedFile()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(manager?.canSaveSelectedFile != true)
        }

        CommandMenu(String(localized: "Terminal", table: "Terminal")) {
            Button(String(localized: "New Terminal", table: "Interface")) {
                manager?.newSession()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(manager?.selectedProject == nil)

            Divider()

            Button(String(localized: "Clear Terminal", table: "Interface")) {
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

            Button(String(localized: "Focus Address Bar", table: "Interface")) {
                manager?.focusBrowserAddressBar()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(manager?.hasSelectedBrowser != true)

            Button(String(localized: "Reload Page", table: "Interface")) {
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
            Button(String(localized: "New Window", table: "Interface")) {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button(
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

private struct PanelMenuEntry: Identifiable {
    let id: DockItem
    let index: Int
    let title: String
    let icon: NSImage

    init(tab: PaneTab, index: Int) {
        id = .tab(tab.id)
        self.index = index
        title = tab.displayTitle
        if let path = tab.content.fileIconPath {
            let fileIconPath = path.lowercased().hasSuffix(".md") ? "file.md" : path
            icon = MaterialFileIcon.image(forPath: fileIconPath)
        } else if case .browser(let browser) = tab.content, let favicon = browser.favicon {
            icon = favicon
        } else {
            icon = NSImage(systemSymbolName: tab.content.systemImage, accessibilityDescription: nil) ?? NSImage()
        }
    }
}

private struct ProjectMenuEntry: Identifiable {
    let id: UUID
    let index: Int
    let title: String
    let icon: NSImage

    init(project: Project, index: Int) {
        id = project.id
        self.index = index
        title = project.name
        icon = NSImage(
            systemSymbolName: project.sshHost == nil ? "folder" : "network",
            accessibilityDescription: nil
        ) ?? NSImage()
    }
}
