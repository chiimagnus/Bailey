//
//  keroApp.swift
//  kero
//

import SwiftUI

struct keroApp: App {
    @NSApplicationDelegateAdaptor(KeroApplicationDelegate.self)
    private var applicationDelegate

    init() {
        TerminalFont.registerBundledFonts()
        TerminalNotificationService.shared.configure()
        // Saved forwards are for other apps too (an RDP client, a browser),
        // so they open at launch rather than when Settings is first shown.
        if !KeroInstanceMode.isIsolated { TunnelManager.shared.start() }
    }

    var body: some Scene {
        WindowGroup(AppIdentity.displayName, id: "main") {
            WindowRootView()
        }
        .windowStyle(.hiddenTitleBar)
        // Keep title-bar dragging away from interactive tabs. The empty
        // header surfaces opt in explicitly through WindowDragArea.
        .windowBackgroundDragBehavior(.disabled)
        .defaultSize(width: 900, height: 600)
        .commands {
            KeroCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Root of one terminal window. Each window owns its own manager, which
/// claims the next unclaimed window snapshot; the first window to appear
/// reopens windows for any snapshots left over.
private struct WindowRootView: View {
    @StateObject private var manager = TerminalManager()
    private let settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(manager: manager)
            .focusedSceneObject(manager)
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
            .onAppear {
                TerminalManager.openRestoredWindows {
                    openWindow(id: "main")
                }
            }
            .onDisappear {
                manager.windowClosed()
            }
    }
}

/// Menu commands routed to the focused window's manager.
private struct KeroCommands: Commands {
    @FocusedObject private var manager: TerminalManager?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = TerminalManager.registerWindowOpener {
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

            Button(String(localized: "New Terminal", table: "Interface")) {
                manager?.newSession()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(manager?.selectedProject == nil)

            Button(String(localized: "New Browser Tab", table: "Interface")) {
                manager?.newBrowserTab()
            }
            .disabled(manager?.selectedProject == nil)

            Button(String(localized: "New Window", table: "Interface")) {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button(String(localized: "Add Files or Folders…", table: "Interface")) {
                manager?.chooseLocalItems()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(manager == nil)

            Button(String(localized: "Add SSH Files or Folders…", table: "Interface")) {
                manager?.chooseSSHItems()
            }
            .disabled(manager == nil)

        }

        CommandGroup(replacing: .saveItem) {
            Button(String(localized: "Save", table: "Interface")) {
                manager?.saveSelectedFile()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(manager?.canSaveSelectedFile != true)

            Divider()

            Button(String(localized: "Close Tab", table: "Interface")) {
                // Cmd-W is app-wide: close a tab only when a main window with
                // an open project is key. Otherwise close the key window
                // itself — a non-main window (e.g. Settings), or a main window
                // showing the empty "No open projects" state with no tab left.
                if let manager, manager.selectedProject != nil,
                   NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true {
                    manager.closeSelectedTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(after: .pasteboard) {
            // SwiftUI's Edit menu ships no Find submenu, so Kero owns these
            // outright. They act on the focused pane — Ghostty's search in a
            // terminal, STTextView's find bar in a file editor — rather than on
            // the first responder, which keeps them live while the find bar's
            // text field has keyboard focus. ⇧⌘G is already Toggle Git Panel,
            // so Find Previous is reachable by ⇧↩ in the bar instead.
            Menu(String(localized: "Find", table: "Interface")) {
                Button(String(localized: "Find…", table: "Interface")) {
                    manager?.performFindAction(.show)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(manager?.canFind != true)

                Button(String(localized: "Find and Replace…", table: "Interface")) {
                    manager?.performFindAction(.replace)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(manager?.canReplace != true)

                Button(String(localized: "Find Next", table: "Interface")) {
                    manager?.performFindAction(.next)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(manager?.canFind != true)

                Button(String(localized: "Find Previous", table: "Interface")) {
                    manager?.performFindAction(.previous)
                }
                .disabled(manager?.canFind != true)

                Button(String(localized: "Use Selection for Find", table: "Interface")) {
                    manager?.performFindAction(.useSelection)
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(manager?.canFind != true)
            }

            Divider()

            Button(String(localized: "Clear Terminal", table: "Interface")) {
                manager?.clearActiveTerminal()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(manager?.canClearActiveTerminal != true)
        }

        // Frees ⌘P from the default Print item for the command palette.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .sidebar) {
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

        }

        CommandGroup(after: .toolbar) {
            Menu(String(localized: "Switch Project", table: "Interface")) {
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

                Divider()

                ForEach(Array((manager?.projects ?? []).prefix(9).enumerated()), id: \.element.id) { index, project in
                    Button(project.name) {
                        manager?.selectProject(index: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .disabled(manager?.projects.isEmpty != false)
        }

        CommandMenu(String(localized: "Browser", table: "Browser")) {
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

        CommandGroup(after: .toolbar) {
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

                ForEach(Array((manager?.selectedProject?.tabs ?? []).prefix(9).enumerated()), id: \.element.id) { index, tab in
                    Button(tab.displayTitle) {
                        manager?.selectTab(index: index)
                    }
                }
            }
            .disabled(manager?.selectedProject?.tabs.isEmpty != false)
        }
    }
}
