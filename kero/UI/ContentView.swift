//
//  ContentView.swift
//  kero
//

import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: TerminalManager
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var tabSwitcher = TabSwitcherController()
    @StateObject private var git = GitStatusModel()

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
        Group {
            if manager.selectedProject != nil {
                WorkspaceDockView(manager: manager, git: git)
            } else {
                VStack(spacing: 0) {
                    HStack { WindowDragArea().frame(maxWidth: .infinity) }
                        .frame(height: 38)
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if tabSwitcher.isPresented, let project = manager.selectedProject {
                TabSwitcherOverlay(project: project, controller: tabSwitcher)
                    .zIndex(10)
            }
        }
        .background {
            TabSwitcherEventMonitor(manager: manager, controller: tabSwitcher)
                .frame(width: 0, height: 0)
        }
        .background(WindowChromeAccessor { manager.attach(to: $0) })
        .onAppear { syncGit() }
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
                .flatMap(\.sessions).map(\.id) ?? []
        )
        return manager.projects
            .flatMap(\.sessions)
            .filter { !visibleIDs.contains($0.id) }
    }

    private func syncGit() {
        guard let project = manager.selectedProject,
              let context = project.panelContext else {
            git.sync(root: "")
            return
        }
        // Files and Git belong to the selected project, not to its terminals.
        // Resolving an automatic remote root can involve a round trip.
        Task {
            let root = await context.resolvedRoot().root
            guard manager.selectedProjectID == project.id,
                  project.matchesPanelTarget(context.identity) else { return }
            git.sync(root: root, backend: context.backend, scope: context.scope)
        }
    }

    private var emptyState: some View {
        emptyStatePrompt(
            title: String(localized: "No open projects", table: "Interface"),
            buttonTitle: String(localized: "Add Files or Folders…", table: "Interface"),
            action: { manager.chooseLocalItems() }
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
        }
    }
}
