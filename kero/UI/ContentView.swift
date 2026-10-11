//
//  ContentView.swift
//  kero
//

import Combine
import SwiftUI

enum BottomToolbarLayout {
    static let height: CGFloat = 24
}

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
                HStack(spacing: 0) {
                    if manager.isLeftSidebarVisible {
                        SidebarView(
                            manager: manager,
                            bottomBarHeight: BottomToolbarLayout.height
                        )
                    }
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            if !manager.isLeftSidebarVisible {
                                ChromeIconButton(
                                    systemImage: "sidebar.left",
                                    tooltip: String(localized: "Toggle Left Sidebar (⌘B)", table: "Interface")
                                ) { manager.toggleLeftSidebar() }
                                .padding(.leading, 76)
                            }
                            WindowDragArea().frame(maxWidth: .infinity)
                        }
                        .frame(height: 38)
                        .overlay(alignment: .bottom) {
                            Color(nsColor: Theme.divider).frame(height: 1)
                        }
                        emptyState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Color(nsColor: Theme.background))
                }
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
        .onChange(of: manager.selectedProjectID) { syncGit() }
        .onChange(of: manager.selectedSession?.id) { syncGit() }
        .onChange(of: manager.selectedSession?.workingDirectory) { syncGit() }
        // The panel directory, not the session's own: a `cd` on a remote
        // machine moves that and leaves `workingDirectory` alone, so without
        // this the Git panel kept its old repository until something unrelated
        // happened to trigger a sync. Files re-roots from the right pane's own
        // poll, which is why only Git looked stuck.
        .onChange(of: manager.selectedSession?.panelDirectoryPath) { syncGit() }
        // A connection going up or down changes which machine the panel should
        // be reading, even when the directory string happens to be unchanged.
        .onChange(of: manager.selectedSession?.remoteHeaderState) { syncGit() }
        .onChange(of: manager.selectedSession?.foregroundDirectoryPath) { syncGit() }
        .onChange(of: manager.selectedProject?.customDirectory) { syncGit() }
        .onChange(of: colorScheme) {
            manager.refreshAppearance()
        }
    }

    /// Sessions in the visible tab are owned by `TerminalHostView`; every
    /// other session stays window-attached in the invisible parking host.
    private var parkedTerminalSessions: [TerminalSession] {
        let visibleIDs = Set(
            manager.selectedProject?.dock.root.groups
                .filter { group in
                    (group.region != .left || manager.isLeftSidebarVisible)
                        && (group.region != .right || manager.isPanelVisible)
                }
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
        let selectedID = project.id
        Task {
            let root = await project.panelRoot(
                followingSessionAt: context.cwd,
                foregroundAt: context.foreground,
                backend: context.backend
            ).root
            guard manager.selectedProjectID == selectedID else { return }
            git.sync(root: root, backend: context.backend, scope: context.scope)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if manager.selectedProject == nil {
            emptyStatePrompt(
                title: String(localized: "No open projects", table: "Interface"),
                buttonTitle: String(localized: "Add Files or Folders…", table: "Interface"),
                action: { manager.chooseLocalItems() }
            )
        } else {
            // A project whose tabs were all closed stays open; offer to reopen
            // a session rather than showing the no-projects prompt.
            emptyStatePrompt(
                title: String(localized: "No open sessions", table: "Interface"),
                buttonTitle: String(localized: "New Session  ⌘T", table: "Interface"),
                action: { manager.newSession() }
            )
        }
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

/// Project context for the active workspace. It stays deliberately compact so
/// terminal content remains the center of gravity below the tab strip.
struct BottomToolbarView: View {
    @ObservedObject var model: GitStatusModel
    @ObservedObject private var themeChanges = Theme.changes
    let height: CGFloat
    let toggleGitPanel: () -> Void
    let hideToolbar: () -> Void

    @State private var isShowingBranches = false
    @State private var branchFilter = ""
    @State private var branchSearchFocusRequest: UInt = 0
    @State private var branchScrollRequest: UInt = 0
    @State private var isBranchButtonHovered = false
    @State private var isChangesButtonHovered = false
    @State private var isNoRepositoryButtonHovered = false
    @State private var hoveredBranch: String?

    private var filteredBranches: [String] {
        let query = branchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        var branches = query.isEmpty ? model.branches : model.branches.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
        if let current = model.branch,
           let index = branches.firstIndex(of: current), index != branches.startIndex {
            branches.remove(at: index)
            branches.insert(current, at: branches.startIndex)
        }
        return branches
    }

    private var changesAccessibilityValue: String {
        guard model.totalChangeCount > 0 else { return String(localized: "Clean", table: "Workspace") }
        return String(localized: "+\(model.lineAdditions), −\(model.lineDeletions)", table: "Workspace")
    }

    var body: some View {
        HStack(spacing: 9) {
            if model.isRepo {
                branchButton
                changesButton
            } else {
                noRepositoryButton
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: height)
        .contentShape(Rectangle())
        .background {
            ToolbarContextMenuMonitor(hideToolbar: hideToolbar)
        }
        .background(Color(nsColor: Theme.background))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
        }
    }

    private var noRepositoryButton: some View {
        Button(action: toggleGitPanel) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(String(localized: "No Git Repository", table: "Interface"))
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        isNoRepositoryButtonHovered
                            ? Color.primary.opacity(0.08)
                            : Color.clear
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isNoRepositoryButtonHovered = $0 }
    }

    private var branchButton: some View {
        Button {
            toggleBranchPicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.accent))
                Text(verbatim: model.branch ?? "detached HEAD")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isBranchButtonHovered ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isBranchButtonHovered = $0 }
        .background {
            InstantPopoverPresenter(
                isPresented: $isShowingBranches,
                preferredEdge: .maxY,
                onPresent: {
                    guard isShowingBranches else { return }
                    branchSearchFocusRequest &+= 1
                    branchScrollRequest &+= 1
                },
                onDismiss: {
                    hoveredBranch = nil
                }
            ) {
                branchPicker
            }
        }
        .disabled(model.isBusy)
        .help(String(localized: "Switch Branch", table: "Interface"))
        .accessibilityLabel(
            String(localized: "Current branch, \(model.branch ?? String(localized: "detached HEAD", table: "Workspace"))", table: "Workspace")
        )
    }

    private var changesButton: some View {
        Button(action: toggleGitPanel) {
            HStack(spacing: 8) {
                if model.totalChangeCount == 0 {
                    Circle()
                        .fill(Color(red: 0.25, green: 0.73, blue: 0.31))
                        .frame(width: 6, height: 6)
                    Text(String(localized: "Clean", table: "Interface"))
                } else {
                    Text(verbatim: "+\(model.lineAdditions)")
                        .foregroundStyle(Color(red: 0.25, green: 0.73, blue: 0.31))
                        .monospacedDigit()
                    Text(verbatim: "−\(model.lineDeletions)")
                        .foregroundStyle(Color(red: 1.0, green: 0.48, blue: 0.45))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isChangesButtonHovered ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isChangesButtonHovered = $0 }
        .help(String(localized: "Open Changes", table: "Interface"))
        .accessibilityLabel(String(localized: "Open Changes", table: "Interface"))
        .accessibilityValue(changesAccessibilityValue)
    }

    private var branchPicker: some View {
        VStack(spacing: 0) {
            BranchSearchField(
                text: $branchFilter,
                focusRequest: branchSearchFocusRequest
            ) {
                if filteredBranches.count == 1,
                   let branch = filteredBranches.first,
                   branch != model.branch {
                    selectBranch(branch)
                }
            }
            .frame(height: 22)
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filteredBranches.isEmpty {
                            Text(String(localized: "No matches", table: "Interface"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(filteredBranches, id: \.self) { branch in
                                let isHovered = hoveredBranch == branch
                                Button {
                                    selectBranch(branch)
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .semibold))
                                            .opacity(branch == model.branch ? 1 : 0)
                                        Text(verbatim: branch)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        if branch == model.defaultBranch {
                                            Text(String(
                                                localized: "default", table: "Interface",
                                                comment: "Badge for the repository's default branch."
                                            ))
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(
                                                isHovered
                                                    ? Color.white.opacity(0.85)
                                                    : Color(nsColor: .secondaryLabelColor)
                                            )
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(
                                                Capsule().fill(
                                                    isHovered
                                                        ? Color.white.opacity(0.18)
                                                        : Color.primary.opacity(0.07)
                                                )
                                            )
                                            .fixedSize()
                                        }
                                    }
                                    .foregroundStyle(isHovered ? Color.white : Color.primary)
                                    .padding(.horizontal, 9)
                                    .frame(height: 26)
                                    .background {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(
                                                isHovered
                                                    ? Color(nsColor: .selectedContentBackgroundColor)
                                                    : Color.clear
                                            )
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { isHovered in
                                    if isHovered {
                                        hoveredBranch = branch
                                    } else if hoveredBranch == branch {
                                        hoveredBranch = nil
                                    }
                                }
                                .disabled(branch == model.branch || model.isBusy)
                                .id(branch)
                            }
                        }
                    }
                    .padding(5)
                }
                .onChange(of: branchScrollRequest) {
                    guard let branch = model.branch else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(branch, anchor: .top)
                    }
                }
            }
        }
        .font(.system(size: 11))
        .frame(width: 260, height: 250)
        .background {
            VisualEffectView(material: .popover)
                .ignoresSafeArea()
        }
    }

    private func toggleBranchPicker() {
        if !isShowingBranches { branchFilter = "" }
        isShowingBranches.toggle()
    }

    private func selectBranch(_ branch: String) {
        isShowingBranches = false
        model.switchBranch(to: branch)
    }
}

/// NSSearchField supplies the standard macOS bezel, magnifier, clear button,
/// focus ring, and vibrancy-aware colors inside the native popover.
private struct BranchSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UInt
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.placeholderString = String(localized: "Filter branches", table: "Workspace")
        field.setAccessibilityLabel(String(localized: "Filter branches", table: "Workspace"))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
        guard context.coordinator.handledFocusRequest != focusRequest else { return }
        context.coordinator.handledFocusRequest = focusRequest
        context.coordinator.focus(field)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: BranchSearchField
        var handledFocusRequest: UInt?

        init(parent: BranchSearchField) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest == 0 ? 0 : nil
        }

        func focus(_ field: NSSearchField, attemptsRemaining: Int = 6) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                if let window = field.window, window.makeFirstResponder(field) { return }
                guard attemptsRemaining > 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.focus(field, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            parent.text = textView.string
            parent.onSubmit()
            return true
        }
    }
}

/// SwiftUI anchors a context menu to this full-width toolbar view. A local
/// AppKit monitor retains the same hit area while presenting from the actual
/// right-click event, so the menu appears at the pointer instead.
private struct ToolbarContextMenuMonitor: NSViewRepresentable {
    let hideToolbar: () -> Void

    func makeNSView(context: Context) -> ToolbarContextMenuMonitorView {
        let view = ToolbarContextMenuMonitorView()
        view.hideToolbar = hideToolbar
        return view
    }

    func updateNSView(_ nsView: ToolbarContextMenuMonitorView, context: Context) {
        nsView.hideToolbar = hideToolbar
    }

    static func dismantleNSView(
        _ nsView: ToolbarContextMenuMonitorView,
        coordinator: ()
    ) {
        nsView.detach()
    }
}

@MainActor
private final class ToolbarContextMenuMonitorView: NSView {
    var hideToolbar: () -> Void = {}
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
            [weak self, weak window] event in
            let input = ToolbarContextMenuEvent(event)
            let output: ToolbarContextMenuEvent = MainActor.assumeIsolated {
                guard let self,
                      let window,
                      let event = input.value,
                      event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return input }

                let menu = NSMenu()
                let hideItem = NSMenuItem(
                    title: String(localized: "Hide", table: "Workspace"),
                    action: #selector(self.hideToolbarFromMenu),
                    keyEquivalent: ""
                )
                hideItem.target = self
                menu.addItem(hideItem)
                menu.update()
                var screenPoint = window.convertPoint(toScreen: event.locationInWindow)
                // The toolbar sits at the screen's lower edge. Position the
                // menu upward so its bottom edge, rather than its top edge,
                // meets the pointer without AppKit relocating the whole menu.
                screenPoint.y += menu.size.height
                _ = menu.popUp(positioning: nil, at: screenPoint, in: nil)
                return ToolbarContextMenuEvent(nil)
            }
            return output.value
        }
    }

    @objc private func hideToolbarFromMenu() {
        hideToolbar()
    }

    func detach() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}

/// Local event monitors run synchronously on AppKit's main event thread.
private struct ToolbarContextMenuEvent: @unchecked Sendable {
    let value: NSEvent?

    init(_ value: NSEvent?) {
        self.value = value
    }
}

/// A single AppKit-owned popover avoids SwiftUI's re-entrant presentation path:
/// rapid binding changes reconcile against `isShown`, and generation checks
/// prevent a stale close callback from dismissing a newer presentation.
private struct InstantPopoverPresenter<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let onPresent: () -> Void
    let onDismiss: () -> Void
    let content: () -> PopoverContent

    init(
        isPresented: Binding<Bool>,
        preferredEdge: NSRectEdge,
        onPresent: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) {
        _isPresented = isPresented
        self.preferredEdge = preferredEdge
        self.onPresent = onPresent
        self.onDismiss = onDismiss
        self.content = content
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: InstantPopoverPresenter
        let popover: NSPopover
        let hostingController: NSHostingController<PopoverContent>
        private var presentationGeneration: UInt = 0

        init(parent: InstantPopoverPresenter) {
            self.parent = parent
            popover = NSPopover()
            hostingController = NSHostingController(rootView: parent.content())
            super.init()
            popover.animates = false
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = hostingController
        }

        func reconcile(parent: InstantPopoverPresenter, anchor: NSView) {
            self.parent = parent
            hostingController.rootView = parent.content()
            popover.animates = false

            if parent.isPresented {
                guard !popover.isShown, anchor.window != nil else { return }
                presentationGeneration &+= 1
                hostingController.view.layoutSubtreeIfNeeded()
                let fittingSize = hostingController.view.fittingSize
                if fittingSize.width > 0, fittingSize.height > 0 {
                    popover.contentSize = fittingSize
                }
                popover.show(
                    relativeTo: anchor.bounds,
                    of: anchor,
                    preferredEdge: parent.preferredEdge
                )
            } else if popover.isShown {
                popover.close()
            }
        }

        func popoverWillShow(_ notification: Notification) {
            popover.animates = false
        }

        func popoverDidShow(_ notification: Notification) {
            let generation = presentationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      self.popover.isShown,
                      self.parent.isPresented else { return }
                self.parent.onPresent()
            }
        }

        func popoverWillClose(_ notification: Notification) {
            popover.animates = false
        }

        func popoverDidClose(_ notification: Notification) {
            let generation = presentationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      !self.popover.isShown else { return }
                self.parent.onDismiss()
                if self.parent.isPresented {
                    self.parent.isPresented = false
                }
            }
        }

        func dismantle() {
            popover.delegate = nil
            popover.animates = false
            popover.close()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.reconcile(parent: self, anchor: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismantle()
    }
}

/// A tab in the strip. Shows the focused pane's title/icon, with a small
/// counter when the tab holds more than one pane. Observes the tab so focus
/// and layout changes refresh it; the focused content is observed by the
/// per-kind label below so its live title/dirty state shows.
struct PaneTabItem: View {
    @ObservedObject var tab: PaneTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @Binding var renamingTabID: UUID?

    var body: some View {
        let paneCount = tab.allPanes.count
        if renamingTabID == tab.id {
            TabRenameChrome(
                systemImage: tab.focusedContent?.systemImage ?? "terminal",
                browserIcon: focusedBrowser,
                fileIconPath: focusedFileIconPath,
                initialValue: tab.displayTitle ?? "",
                commit: { name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    tab.customName = trimmed.isEmpty ? nil : trimmed
                },
                end: { renamingTabID = nil }
            )
        } else {
            switch tab.focusedContent {
            case .session(let session):
                SessionTabLabel(session: session, customTitle: tab.customName, paneCount: paneCount, isSelected: isSelected, select: select, close: close)
            case .file(let file):
                FileTabLabel(file: file, customTitle: tab.customName, paneCount: paneCount, isSelected: isSelected, select: select, close: close)
            case .browser(let browser):
                BrowserTabLabel(browser: browser, customTitle: tab.customName, paneCount: paneCount, isSelected: isSelected, select: select, close: close)
            case .diff(let diff):
                DiffTabLabel(
                    diff: diff,
                    customTitle: tab.customName,
                    paneCount: paneCount,
                    isSelected: isSelected,
                    select: select,
                    close: close
                )
            case nil:
                EmptyView()
            }
        }
    }

    private var focusedBrowser: BrowserTab? {
        if case .browser(let browser) = tab.focusedContent {
            browser
        } else {
            nil
        }
    }

    private var focusedFileIconPath: String? {
        tab.focusedContent?.fileIconPath
    }
}

/// Inline editor shown in place of a tab while it's renamed — the same
/// affordance as the project row's rename. Commits on Return or focus loss,
/// cancels on Escape; an empty name returns the tab to its automatic title.
private struct TabRenameChrome: View {
    @ObservedObject private var themeChanges = Theme.changes
    let systemImage: String
    let browserIcon: BrowserTab?
    let fileIconPath: String?
    let commit: (String) -> Void
    let end: () -> Void

    @State private var draft: String
    /// Set by the first commit/cancel so the focus-loss handler that fires
    /// while the field is being torn down doesn't commit a second time.
    @State private var finished = false
    @FocusState private var focused: Bool

    init(
        systemImage: String,
        browserIcon: BrowserTab?,
        fileIconPath: String?,
        initialValue: String,
        commit: @escaping (String) -> Void,
        end: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.browserIcon = browserIcon
        self.fileIconPath = fileIconPath
        self.commit = commit
        self.end = end
        _draft = State(initialValue: initialValue)
    }

    var body: some View {
        HStack(spacing: 5) {
            if let browserIcon {
                BrowserFaviconView(browser: browserIcon, size: 11)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.accent))
            } else if let fileIconPath {
                MaterialFileIconView(path: fileIconPath, size: 12)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.accent))
            }
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .frame(width: 110)
                .focused($focused)
                .onSubmit { finish(apply: true) }
                .onExitCommand { finish(apply: false) }
                .onChange(of: focused) {
                    if !focused { finish(apply: true) }
                }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.09))
        )
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }

    private func finish(apply: Bool) {
        guard !finished else { return }
        finished = true
        if apply { commit(draft) }
        end()
    }
}

private struct SessionTabLabel: View {
    @ObservedObject var session: TerminalSession
    /// User-assigned tab name overriding the live terminal title.
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "terminal",
            title: customTitle ?? session.title,
            paneCount: paneCount,
            isSelected: isSelected,
            select: select,
            close: close
        )
    }
}

private struct FileTabLabel: View {
    @ObservedObject var file: FileTab
    /// User-assigned tab name overriding the file name.
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "doc.text",
            fileIconPath: file.path,
            title: customTitle ?? file.name,
            paneCount: paneCount,
            isSelected: isSelected,
            isDirty: file.isDirty,
            select: select,
            close: close
        )
        .help(file.path)
    }
}

private struct BrowserTabLabel: View {
    @ObservedObject var browser: BrowserTab
    /// User-assigned tab name overriding the webpage title.
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "globe",
            browserIcon: browser,
            title: customTitle ?? browser.title,
            paneCount: paneCount,
            isSelected: isSelected,
            select: select,
            close: close
        )
        .help(browser.urlString)
    }
}

private struct DiffTabLabel: View {
    @ObservedObject var diff: DiffTab
    var customTitle: String?
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "plus.forwardslash.minus",
            fileIconPath: diff.path,
            title: customTitle ?? diff.title,
            paneCount: paneCount,
            isSelected: isSelected,
            isDirty: diff.isDirty,
            select: select,
            close: close
        )
        .help(diff.path)
    }
}

struct TabItemChrome: View {
    @ObservedObject private var themeChanges = Theme.changes
    let systemImage: String
    var browserIcon: BrowserTab? = nil
    var fileIconPath: String? = nil
    let title: String
    var paneCount: Int = 1
    let isSelected: Bool
    var isDirty = false
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                ZStack {
                    if isHovering {
                        Button(action: close) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Close Tab", table: "Interface"))
                    } else if let browserIcon {
                        BrowserFaviconView(browser: browserIcon, size: 11)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(
                                isSelected
                                    ? AnyShapeStyle(Color(nsColor: Theme.accent))
                                    : AnyShapeStyle(.tertiary)
                            )
                            .opacity(isSelected ? 1 : 0.78)
                    } else if let fileIconPath {
                        MaterialFileIconView(
                            path: fileIconPath,
                            size: 12,
                            opacity: isSelected ? 1 : 0.82
                        )
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(
                                isSelected
                                    ? AnyShapeStyle(Color(nsColor: Theme.accent))
                                    : AnyShapeStyle(.tertiary)
                            )
                    }
                }
                .frame(width: 14, height: 14)
                Text(verbatim: title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                if paneCount > 1 {
                    HStack(spacing: 2) {
                        Image(systemName: "square.split.2x1")
                            .font(.system(size: 7.5, weight: .semibold))
                        Text(verbatim: "\(paneCount)")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.tertiary)
                }
                if isDirty {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        // Cap tab width so a long title truncates instead of stretching the
        // tab; short titles still shrink to fit (maxWidth is an upper bound).
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
    }
}
