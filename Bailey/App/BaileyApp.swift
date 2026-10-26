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

    private var closeMenuTitle: String {
        guard let project = manager?.selectedProject else {
            return String(localized: "Close Window", table: "Interface")
        }
        switch project.dock.activeGroup?.selected {
        case .tab?: return String(localized: "Close Tab", table: "Interface")
        case .projects?, .files?, .git?:
            return String(localized: "Close Panel", table: "Interface")
        case nil:
            return project.tabs.isEmpty
                ? String(localized: "Close Project", table: "Sidebar")
                : String(localized: "Close Window", table: "Interface")
        }
    }

    var body: some Commands {
        let _ = application.registerWindowOpener {
            openWindow(id: "main")
        }

        CommandGroup(replacing: .newItem) {
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

        }

        CommandGroup(replacing: .saveItem) {
            Button(String(localized: "Save", table: "Interface")) {
                manager?.saveSelectedFile()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(manager?.canSaveSelectedFile != true)

            Divider()

            Button(closeMenuTitle) {
                if let manager, let project = manager.selectedProject,
                   project.dock.activeGroup?.selected != nil || project.tabs.isEmpty {
                    manager.closeSelectedTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
        }

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

        CommandMenu(String(localized: "Project", table: "Interface")) {
            Button(String(localized: "Add Folder…", table: "Interface")) {
                manager?.chooseFolders()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(manager == nil)

            Button(String(localized: "Add SSH Files or Folders…", table: "Interface")) {
                manager?.chooseSSHItems()
            }
            .disabled(manager == nil)

            Divider()

            Button(String(localized: "Close Project", table: "Sidebar")) {
                if let project = manager?.selectedProject { manager?.close(project) }
            }
            .disabled(manager?.selectedProject == nil)

            if (manager?.projects.count ?? 0) < 2 {
                Button(String(localized: "Switch Project", table: "Interface")) {}
                    .disabled(true)
            } else {
                Menu(String(localized: "Switch Project", table: "Interface")) {
                    Button(String(localized: "Next Project", table: "Interface")) {
                        manager?.selectNextProject()
                    }
                    .keyboardShortcut("]", modifiers: [.command, .option])

                    Button(String(localized: "Previous Project", table: "Interface")) {
                        manager?.selectPreviousProject()
                    }
                    .keyboardShortcut("[", modifiers: [.command, .option])

                    Divider()

                    ForEach(Array((manager?.projects ?? []).prefix(9).enumerated()).map {
                        WindowMenuItem(id: $0.element.id, index: $0.offset, title: $0.element.name)
                    }) { item in
                        Button(item.title) {
                            manager?.selectProject(index: item.index)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(item.index + 1)")), modifiers: .command)
                    }
                }
            }
        }

        CommandMenu(String(localized: "Panel", table: "Interface")) {
            Button(String(localized: "Command Palette…", table: "Interface")) {
                manager?.toggleCommandPalette()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(manager == nil)

            Divider()

            Button(String(localized: "Projects", table: "Interface")) {
                manager?.showPanel(.projects)
            }
            .disabled(manager?.selectedProject == nil)

            Button(String(localized: "File Manager", table: "Sidebar")) {
                manager?.showPanel(.files)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Button(String(localized: "Git Manager", table: "Sidebar")) {
                manager?.showPanel(.git)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(manager?.selectedProject == nil)

            Divider()

            if manager?.selectedProject?.tabs.isEmpty != false {
                Button(String(localized: "Tabs", table: "Interface")) {}
                    .disabled(true)
            } else {
                Menu(String(localized: "Tabs", table: "Interface")) {
                    Button(String(localized: "Next Tab", table: "Interface")) {
                        manager?.selectNextTab()
                    }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled((manager?.selectedProject?.tabs.count ?? 0) < 2)

                    Button(String(localized: "Previous Tab", table: "Interface")) {
                        manager?.selectPreviousTab()
                    }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled((manager?.selectedProject?.tabs.count ?? 0) < 2)

                    Divider()

                    ForEach(Array((manager?.selectedProject?.tabs ?? []).prefix(9).enumerated()).map {
                        WindowMenuItem(id: $0.element.id, index: $0.offset, title: $0.element.displayTitle)
                    }) { item in
                        Button(item.title) {
                            manager?.selectTab(index: item.index)
                        }
                    }
                }
            }
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

private struct WindowMenuItem: Identifiable {
    let id: UUID
    let index: Int
    let title: String
}
