import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Window-wide docking gesture. One hit-tested destination and one preview:
/// the pointer's proximity to a pane edge determines the split, while the
/// title strip and the interior merge into the existing tab group.
@MainActor
@Observable
final class DockTabDragCoordinator {
    struct Source {
        let item: DockItem
        let items: [DockItem]
        let sourceGroupID: UUID
        let sourceLayout: DockNode
    }

    struct Position {
        let source: Source
        var item: DockItem { source.item }
        var items: [DockItem] { source.items }
        let location: CGPoint
        let destination: UUID?
        let edge: DockEdge?
        let index: Int?
    }

    private(set) var position: Position?
    @ObservationIgnored private var source: Source?
    @ObservationIgnored private weak var sourceDock: DockWorkspaceModel?
    @ObservationIgnored private var groups: [UUID: CGRect] = [:]
    @ObservationIgnored private var tabs: [DockItem: CGRect] = [:]

    func cancel(_ item: DockItem? = nil) {
        if let item, source?.item != item { return }
        // Layout preferences may update before project-switch cancellation;
        // preserve their latest frames so the next drag can still hit a target.
        position = nil
        source = nil
        sourceDock = nil
        NSCursor.arrow.set()
    }

    func setFrames(groups: [UUID: CGRect]) {
        if source != nil, self.groups != groups { cancel() }
        self.groups = groups
    }
    func setFrames(tabs: [DockItem: CGRect]) {
        if source != nil, self.tabs != tabs { cancel() }
        self.tabs = tabs
    }

    func begin(_ item: DockItem, dock: DockWorkspaceModel) {
        cancel()
        guard let group = dock.group(containing: item) else { return }
        sourceDock = dock
        source = Source(item: item, items: dock.commandTargets(for: item),
                        sourceGroupID: group.id, sourceLayout: dock.root)
    }

    func insertionX(in group: DockGroup) -> CGFloat? {
        guard let position, position.destination == group.id, position.edge == nil,
              let frame = groups[group.id],
              position.location.y >= frame.minY, position.location.y < frame.minY + 38,
              let index = position.index, !group.items.isEmpty else { return nil }
        let item = index < group.items.count ? group.items[index] : group.items[group.items.count - 1]
        guard let bounds = tabs[item] else { return nil }
        return index < group.items.count ? bounds.minX : bounds.maxX
    }

    func update(_ item: DockItem, at location: CGPoint, dock: DockWorkspaceModel) {
        guard let source, sourceDock === dock, source.item == item,
              source.sourceLayout == dock.root else { cancel(); return }
        let hit = groups.first { $0.value.contains(location) }
        var edge: DockEdge?
        var insertIndex: Int?
        if let hit, let target = dock.root.group(id: hit.key) {
            let frame = hit.value
            edge = DockDropHitTest.edge(
                at: location, in: frame,
                threshold: CGFloat(dock.configuration.edgeThreshold)
            )
            if edge == nil {
                insertIndex = target.items.firstIndex { tab in
                    guard let bounds = tabs[tab] else { return false }
                    return location.x < bounds.midX && location.y <= frame.minY + 38
                } ?? target.items.count
            }
        }
        position = Position(
            source: source, location: location,
            destination: hit?.key, edge: edge, index: insertIndex
        )
    }

    func finish(project: Project) {
        defer { cancel() }
        guard let position, sourceDock === project.dock, project.dock.root == position.source.sourceLayout,
              let destination = position.destination else { return }
        project.movePanels(
            position.item, into: destination,
            edge: position.edge, index: position.index, items: position.items,
            sourceGroupID: position.source.sourceGroupID
        )
    }
}

private struct DockGroupFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct DockTabFrames: PreferenceKey {
    static let defaultValue: [DockItem: CGRect] = [:]
    static func reduce(value: inout [DockItem: CGRect], nextValue: () -> [DockItem: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct WorkspaceDockView: View {
    private let themeChanges = Theme.changes
    let manager: WorkspaceWindowModel
    let git: GitStatusModel
    @State private var dragging = DockTabDragCoordinator()

    var body: some View {
        let _ = themeChanges.revision
        GeometryReader { rootGeometry in
            if let project = manager.selectedProject {
                let layout = project.dock.root
                DockTreeView(
                    node: layout, project: project, manager: manager,
                    git: git, dragging: dragging
                )
                .frame(width: rootGeometry.size.width, height: rootGeometry.size.height)
                .background(Color(nsColor: Theme.background))
                .onPreferenceChange(DockGroupFrames.self) {
                    dragging.setFrames(groups: $0)
                }
                .onPreferenceChange(DockTabFrames.self) {
                    dragging.setFrames(tabs: $0)
                }
                .onChange(of: manager.selectedProjectID) { dragging.cancel() }
                .overlay(alignment: .topLeading) {
                    if let position = dragging.position, position.destination != nil {
                        let origin = rootGeometry.frame(in: .global).origin
                        HStack(spacing: 6) {
                            Image(systemName: position.item.symbol)
                            Text(position.item.label(project: project))
                                .lineLimit(1)
                            if position.items.count > 1 { Text(verbatim: "+\(position.items.count - 1)") }
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 11)
                        .frame(height: 27)
                        .foregroundStyle(Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: Theme.background))
                                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: Theme.accent).opacity(0.5), lineWidth: 1))
                        .offset(
                            x: position.location.x - origin.x + 14,
                            y: position.location.y - origin.y + 14
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .coordinateSpace(name: "workspaceDock")
    }
}

extension DockItem {
    var symbol: String {
        switch self {
        case .projects: "square.grid.2x2"
        case .files: "folder"
        case .git: "arrow.triangle.branch"
        case .tab: "terminal"
        }
    }

    func label(project: Project) -> String {
        switch self {
        case .projects: String(localized: "Projects", table: "Interface")
        case .files: String(localized: "File Manager", table: "Sidebar")
        case .git: String(localized: "Git Manager", table: "Sidebar")
        case .tab(let id): project.tabs.first { $0.id == id }?.displayTitle ?? String(localized: "Tab", table: "Workspace")
        }
    }
}

/// The recursive window layout positions independent work and tool tabs.
private struct DockTreeView: View {
    private let themeChanges = Theme.changes
    let node: DockNode
    let project: Project
    let manager: WorkspaceWindowModel
    let git: GitStatusModel
    let dragging: DockTabDragCoordinator

    @State private var liveFraction: Double?

    var body: some View {
        let _ = themeChanges.revision
        switch node {
        case .group(let group):
            DockTabGroupView(
                group: group, project: project, manager: manager,
                git: git, dragging: dragging
            )
        case .split(let split):
            GeometryReader { geometry in
                let size = geometry.size
                let fraction = liveFraction ?? split.fraction
                let horizontal = split.axis == .horizontal
                let available = max(0, (horizontal ? size.width : size.height) - 1)
                let firstLength = available * fraction
                let secondLength = max(0, available - firstLength)
                Group {
                    if horizontal {
                        HStack(spacing: 0) {
                            child(split.first)
                                .frame(width: firstLength, height: size.height)
                            divider(split, available: available)
                                .frame(width: 1, height: size.height)
                            child(split.second)
                                .frame(width: secondLength, height: size.height)
                        }
                    } else {
                        VStack(spacing: 0) {
                            child(split.first)
                                .frame(width: size.width, height: firstLength)
                            divider(split, available: available)
                                .frame(width: size.width, height: 1)
                            child(split.second)
                                .frame(width: size.width, height: secondLength)
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
            }
        }
    }

    private func child(_ node: DockNode) -> some View {
        DockTreeView(
            node: node, project: project, manager: manager,
            git: git, dragging: dragging
        )
    }

    private func divider(_ split: DockSplit, available: CGFloat) -> some View {
        // A thin divider with a wider invisible drag target.
        Rectangle()
            .fill(Color(nsColor: Theme.divider))
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: split.axis == .horizontal ? 7 : nil,
                        height: split.axis == .vertical ? 7 : nil
                    )
                    .contentShape(Rectangle())
                    .pointerStyle(split.axis == .horizontal ? .columnResize : .rowResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            guard available > 0 else { return }
                            let delta = split.axis == .horizontal
                                ? value.translation.width : value.translation.height
                            let minimumLength: CGFloat = split.axis == .horizontal ? 150 : 90
                            let minimum = min(0.48, max(0.1, Double(minimumLength / available)))
                            liveFraction = min(max(
                                split.fraction + Double(delta / available), minimum
                            ), 1 - minimum)
                        }
                        .onEnded { _ in
                            if let liveFraction { project.dock.resize(split.id, to: liveFraction) }
                            liveFraction = nil
                        }
                    )
            }
            .accessibilityIdentifier("bailey.dock.divider")
    }
}

struct DockTabGroupView: View {
    private let themeChanges = Theme.changes
    let group: DockGroup
    let project: Project
    let manager: WorkspaceWindowModel
    let git: GitStatusModel
    let dragging: DockTabDragCoordinator
    private let settings = AppSettings.shared
    @State private var renamingTabID: UUID?
    @State private var showingPanelPicker = false
    @State private var tabKeyboard = TreeKeyboardOwner()
    @State private var tabCursor: DockItem?
    @State private var tabKeyboardFocused = false
    @Environment(\.appearsActive) private var windowAppearsActive

    private var active: DockItem? { group.selected }
    private var isFocused: Bool {
        windowAppearsActive && canFocusGroup()
    }

    private func canFocusGroup() -> Bool {
        manager.selectedProject === project && project.dock.activeGroupID == group.id
            && manager.attachedWindow?.isKeyWindow == true && NSApp.isActive
            && !manager.isCommandPaletteVisible && manager.attachedWindow?.attachedSheet == nil
    }

    private func focusGroup() {
        guard manager.selectedProject === project, !manager.isCommandPaletteVisible,
              manager.attachedWindow?.attachedSheet == nil else { return }
        project.dock.activate(group.id)
        if case .tab(let id)? = project.dock.root.group(id: group.id)?.selected,
           project.selectedTabID != id {
            project.selectTab(id, extending: .preserve)
        }
    }

    var body: some View {
        let _ = themeChanges.revision
        VStack(spacing: 0) {
            header
                .frame(height: 38)
                .onDrop(of: [UTType.fileURL.identifier], delegate: FinderWindowDrop(
                    manager: manager,
                    destination: (projectID: project.id, groupID: group.id)
                ))
                .overlay(alignment: .bottom) {
                    Color(nsColor: Theme.divider).frame(height: 1)
                }
                .overlay {
                    GeometryReader { geometry in
                        if let x = dragging.insertionX(in: group) {
                            Capsule()
                                .fill(Color(nsColor: Theme.accent))
                                .frame(width: 2, height: 19)
                                .shadow(color: Color(nsColor: Theme.accent).opacity(0.6), radius: 3)
                                .position(x: x - geometry.frame(in: .global).minX, y: 19)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .zIndex(1)
            ZStack {
                content
                dropPreview
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if active?.tabID != nil,
               settings.toolbarVisibility != .hide,
               (git.isRepo || settings.toolbarVisibility == .always) {
                BottomToolbarView(
                    model: git,
                    height: BottomToolbarLayout.height,
                    toggleGitPanel: { manager.showPanel(.git) },
                    switchBranch: { name, oid in
                        manager.switchGitBranch(to: name, expectedOID: oid,
                                                in: project, model: git)
                    },
                    hideToolbar: { settings.toolbarVisibility = .hide }
                )
            }
        }
        .background(DockGroupFocusReader(
            groupID: group.id,
            isActive: isFocused,
            focusesEmptySpace: active?.tabID == nil,
            canFocus: { canFocusGroup() && dragging.position == nil && !tabKeyboardFocused },
            onFocused: { if dragging.position == nil && !tabKeyboardFocused { focusGroup() } },
            onPrimaryClick: { project.dock.clearContextTarget() }
        ).id(group.id))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: DockGroupFrames.self,
                    value: [group.id: geometry.frame(in: .global)]
                )
            }
        }
    }

    private var header: some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .named("workspaceDock")).origin
            let isTopLeft = origin.x < 1 && origin.y < 1
            let dragWidth = isTopLeft ? min(76, max(0, geometry.size.width - 124)) : 0
            HStack(spacing: 4) {
                if dragWidth > 0 { WindowDragArea().frame(width: dragWidth) }
                tabStrip(maxWidth: max(0, geometry.size.width - dragWidth - 44))
                panelAddButton
                WindowDragArea().frame(minWidth: 0, maxWidth: .infinity)
            }
            .padding(.trailing, 8)
            .frame(height: geometry.size.height)
        }
    }

    private var panelAddButton: some View {
        ChromeIconButton(
            systemImage: "plus",
            tooltip: String(localized: "Add Panel", table: "Interface"),
            font: .system(size: 10, weight: .semibold),
            iconSize: 14
        ) { showingPanelPicker.toggle() }
        .popover(isPresented: $showingPanelPicker, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(availableActions.indices, id: \.self) { index in
                    let action = availableActions[index]
                    if index > 0 && (availableActions[index - 1].item == nil) != (action.item == nil) {
                        Divider()
                    }
                    if action.item == nil {
                        openFileButton
                        newItemButton(isDirectory: false)
                        newItemButton(isDirectory: true)
                    }
                    Button {
                        showingPanelPicker = false
                        if let item = action.item { add(item) } else { addSession() }
                    } label: {
                        HStack {
                            Label(
                                action.item?.label(project: project)
                                    ?? String(localized: "New Terminal", table: "Interface"),
                                systemImage: action.item?.symbol ?? "terminal"
                            )
                            Spacer(minLength: 0)
                            if action.item == nil, isFocused {
                                Text(verbatim: "⌘T").foregroundStyle(.secondary)
                            }
                        }
                        .padding(7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 170)
        }
    }

    private var openFileButton: some View {
        Button {
            showingPanelPicker = false
            manager.chooseFiles(inGroup: (projectID: project.id, groupID: group.id))
        } label: {
            HStack {
                Label(String(localized: "Open File…", table: "Interface"), systemImage: "doc")
                Spacer(minLength: 0)
                if isFocused { Text(verbatim: "⌘O").foregroundStyle(.secondary) }
            }
            .padding(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func newItemButton(isDirectory: Bool) -> some View {
        Button {
            showingPanelPicker = false
            Task {
                guard manager.selectedProjectID == project.id else { return }
                if isDirectory { await manager.newFolder() }
                else { await manager.newFile() }
            }
        } label: {
            HStack {
                Label(
                    isDirectory ? String(localized: "New Folder…", table: "Sidebar")
                        : String(localized: "New File…", table: "Sidebar"),
                    systemImage: isDirectory ? "folder.badge.plus" : "doc.badge.plus"
                )
                Spacer(minLength: 0)
                if isFocused {
                    Text(verbatim: isDirectory ? "⌥⌘N" : "⌘N")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(project.panelContext == nil)
    }

    private var availableActions: [DockAddAction] {
        project.dock.availableAddActions()
    }

    private func tabStrip(maxWidth: CGFloat? = nil) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(group.items, id: \.self) { item in
                        tab(item)
                            .id(item)
                            .opacity(dragging.position?.items.contains(item) == true ? 0.6 : 1)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: DockTabFrames.self,
                                        value: [item: geometry.frame(in: .global)]
                                    )
                                }
                            }
                            .overlay {
                                if item.tabID == nil || renamingTabID != item.tabID {
                                    DockTabPointerInput(
                                        press: { modifiers in
                                            select(item, extending: selectionChange(modifiers))
                                            dragging.begin(item, dock: project.dock)
                                        },
                                        release: { modifiers in
                                            dragging.cancel()
                                            if modifiers.intersection([.command, .shift]).isEmpty { select(item) }
                                        },
                                        drag: { point, finished in
                                            dragging.update(item, at: point, dock: project.dock)
                                            if finished { dragging.finish(project: project) }
                                            else { NSCursor.closedHand.set() }
                                        },
                                        close: { manager.closePanel(item, in: project) },
                                        cancel: { dragging.cancel(item) }
                                    )
                                    .padding(.leading, 22)
                                }
                            }
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(width: maxWidth, alignment: .leading)
            .clipped()
            .background(TreeKeyboardHost(
                owner: tabKeyboard, onKeyDown: handleTabKey,
                onFocusChanged: { focused in
                    tabKeyboardFocused = focused
                    if focused, tabCursor.map({ !group.items.contains($0) }) ?? true { tabCursor = active }
                }, onAttachedToWindow: { tabKeyboard.view?.setAccessibilityIdentifier("bailey.dock.tabstrip") }
            ))
            .onChange(of: group.selected) { _, selected in
                if let selected { scrollProxy.scrollTo(selected) }
            }
            .onChange(of: tabCursor) { _, cursor in
                if let cursor { scrollProxy.scrollTo(cursor) }
            }
            .onChange(of: group.items) { _, items in
                if tabCursor.map({ !items.contains($0) }) ?? false { tabCursor = active }
            }
        }
    }

    @ViewBuilder
    private func tab(_ item: DockItem) -> some View {
        if case .tab(let id) = item,
           let paneTab = project.tabs.first(where: { $0.id == id }) {
            PaneTabItem(
                tab: paneTab, isDisplayed: active == item,
                isSelected: project.dock.selection(in: group.id).contains(item),
                isKeyboardFocused: tabKeyboardFocused && tabCursor == item, isPaneFocused: isFocused,
                isContextTarget: project.dock.contextTarget == item,
                select: { select(item) },
                close: { close(item) },
                renamingTabID: $renamingTabID
            )
            .overlay {
                ContextMenuClickTarget(
                    onContextClick: { project.dock.selectForContextMenu(item) },
                    onMenuClosed: { finishTabContextMenu(for: item) },
                    onMenuKeyDown: { menu, event in
                        handleMenuKeyDown(menu, event, for: item)
                    },
                    isExpectedMenu: { isMenuForTab($0, item: item) }
                )
                .contextMenu {
                    if let current = project.tabs.first(where: { $0.id == id }) {
                        projectTabMenu(current)
                    }
                }
            }
        } else {
            TabItemChrome(
                systemImage: item.symbol, title: item.label(project: project),
                isDisplayed: active == item,
                isSelected: project.dock.selection(in: group.id).contains(item),
                isKeyboardFocused: tabKeyboardFocused && tabCursor == item, isPaneFocused: isFocused,
                isContextTarget: project.dock.contextTarget == item,
                select: { select(item) },
                close: { close(item) }
            )
            .accessibilityIdentifier("bailey.dock.\(item.configurationName ?? "unknown")")
            .overlay {
                ContextMenuClickTarget(
                    onContextClick: { project.dock.selectForContextMenu(item) },
                    onMenuClosed: { finishTabContextMenu(for: item) },
                    onMenuKeyDown: { menu, event in
                        handleMenuKeyDown(menu, event, for: item)
                    },
                    isExpectedMenu: { isMenuForTab($0, item: item) }
                )
                .contextMenu {
                    let closeTitle = closeTitle(for: item)
                    Button {
                        guard isValidMenuTarget(item) else { return }
                        close(item)
                    } label: {
                        Text(verbatim: closeTitle + "\t⌘W")
                    }
                    .accessibilityLabel(closeTitle)
                    .disabled(project.isClosingPanels)
                }
            }
        }
    }

    private func finishTabContextMenu(for item: DockItem) {
        guard project.dock.contextTarget == item else { return }
        // AppKit 可能先结束右键菜单跟踪，再让系统主菜单处理 ⌘W。
        // 保留本次右键目标，直到 Close 消费它。
        if let event = NSApp.currentEvent,
           event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            return
        }
        project.dock.clearContextTarget()
    }

    private func isMenuForTab(_ menu: NSMenu, item: DockItem) -> Bool {
        guard isValidMenuTarget(item), project.dock.contextTarget == item else { return false }
        let title = closeTitle(for: item)
        return menu.items.contains { $0.accessibilityLabel() == title }
    }

    private func handleMenuKeyDown(_ menu: NSMenu, _ event: NSEvent, for item: DockItem) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "w",
              isMenuForTab(menu, item: item) else { return false }
        let title = closeTitle(for: item)
        guard let index = menu.items.firstIndex(where: {
            $0.isEnabled && $0.accessibilityLabel() == title
        }) else { return false }
        menu.performActionForItem(at: index)
        menu.cancelTracking()
        return true
    }

    private func selectionChange(_ modifiers: NSEvent.ModifierFlags) -> DockWorkspaceModel.SelectionChange {
        if modifiers.contains(.shift) { return .range }
        if modifiers.contains(.command) { return .toggle }
        return .preserve
    }

    private func select(_ item: DockItem, extending change: DockWorkspaceModel.SelectionChange = .replace) {
        guard manager.selectedProject === project else { return }
        tabCursor = item
        if case .tab(let id) = item { project.selectTab(id, extending: change) }
        else { project.dock.select(item, extending: change, preferred: project.tabsByRecency.map { .tab($0.id) }) }
    }

    private func handleTabKey(_ event: NSEvent) -> Bool {
        guard manager.selectedProject === project,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let current = project.dock.root.group(id: group.id), !current.items.isEmpty else { return false }
        let cursor = tabCursor.flatMap { current.items.contains($0) ? $0 : nil } ?? current.selected
        let index = cursor.flatMap { current.items.firstIndex(of: $0) } ?? 0
        switch event.keyCode {
        case 123: tabCursor = current.items[max(0, index - 1)]
        case 124: tabCursor = current.items[min(current.items.count - 1, index + 1)]
        case 115: tabCursor = current.items.first
        case 119: tabCursor = current.items.last
        case 36, 49:
            if let cursor { select(cursor) }
        default: return false
        }
        return true
    }

    private func closeTitle(for item: DockItem) -> String {
        if project.dock.commandTargets(for: item).count > 1 {
            return String(localized: "Close Selected Panels", table: "Interface")
        }
        return item.tabID == nil ? String(localized: "Close Panel", table: "Interface")
            : String(localized: "Close", table: "Interface")
    }

    private func isValidMenuTarget(_ item: DockItem) -> Bool {
        manager.selectedProject === project && project.dock.group(containing: item)?.id == group.id
            && manager.attachedWindow?.isKeyWindow == true && NSApp.keyWindow === manager.attachedWindow
    }

    private func currentMenuTab(_ id: UUID) -> PaneTab? {
        guard isValidMenuTarget(.tab(id)) else { return nil }
        return project.tabs.first { $0.id == id }
    }

    private func close(_ item: DockItem) {
        guard project.dock.group(containing: item)?.id == group.id else { return }
        manager.closePanel(item, in: project)
    }

    @ViewBuilder
    private var content: some View {
        switch active {
        case .projects:
            ProjectsPanelView(
                manager: manager,
                bottomBarHeight: BottomToolbarLayout.height
            )
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                FinderWindowDrop.receive(providers, preferred: manager)
            }
        case .files:
            ToolPanelView(manager: manager, git: git, panel: .files)
        case .git:
            ToolPanelView(manager: manager, git: git, panel: .git)
                .onDrop(of: [UTType.fileURL.identifier], delegate: FinderWindowDrop(
                    manager: manager,
                    destination: (projectID: project.id, groupID: group.id)
                ))
        case .tab(let id):
            if let tab = project.tabs.first(where: { $0.id == id }) {
                PanelContentView(
                    tab: tab,
                    isFocused: isFocused,
                    canFocus: canFocusGroup,
                    onFocused: focusGroup,
                    onNewBrowserTab: { manager.newBrowserTab(initialURL: $0) },
                    onNewFileTab: { manager.openFile($0) },
                    onExternalFilesDropped: { FinderWindowDrop.receive(
                        $0, preferred: manager,
                        destination: (projectID: project.id, groupID: group.id)
                    ) }
                )
                .id(tab.id)
            }
        case nil:
            emptyGroup
        }
    }

    private var emptyGroup: some View {
        VStack(spacing: 10) {
            Text(String(localized: "Drag a Tab Here or Add a Panel", table: "Interface"))
                .foregroundStyle(.secondary)
            Button(String(localized: "Add Panel", table: "Interface")) {
                showingPanelPicker = true
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.background))
        .onDrop(of: [UTType.fileURL.identifier], delegate: FinderWindowDrop(
            manager: manager,
            destination: (projectID: project.id, groupID: group.id)
        ))
    }

    private func add(_ item: DockItem) { _ = project.dock.place(item, in: group.id) }

    private func addSession() {
        project.newSession()
        if let id = project.selectedTabID {
            _ = project.dock.move(.tab(id), into: group.id)
        }
    }

    @ViewBuilder
    private func projectTabMenu(_ tab: PaneTab) -> some View {
        let tabID = tab.id
        Button(String(localized: "Rename…", table: "Interface")) {
            if currentMenuTab(tabID) != nil { renamingTabID = tabID }
        }
        if tab.customName != nil {
            Button(String(localized: "Use Automatic Title", table: "Interface")) {
                currentMenuTab(tabID)?.customName = nil
            }
        }
        Divider()
        if case .file(let file) = tab.content {
            Button(String(localized: "Reveal in File Manager", table: "Interface")) {
                guard currentMenuTab(tabID) != nil else { return }
                manager.revealFileInFileManager(tabID: tabID, in: project)
            }
            if file.workspaceIdentity == nil {
                Button(String(localized: "Reveal in Finder", table: "Interface")) {
                    guard case .file(let current)? = currentMenuTab(tabID)?.content,
                          current.workspaceIdentity == nil else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: current.path)])
                }
            }
            Button(String(localized: "Copy Absolute Path", table: "Interface")) {
                guard case .file(let current)? = currentMenuTab(tabID)?.content else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(current.path, forType: .string)
            }
            Divider()
        }
        if case .browser(let browser) = tab.content, !browser.urlString.isEmpty {
            Button(String(localized: "Open in Default Browser", table: "Interface")) {
                if let current = currentMenuTab(tabID),
                   case .browser(let currentBrowser) = current.content {
                    currentBrowser.openInDefaultBrowser()
                }
            }
            .disabled(browser.shareURL == nil)
            Button(String(localized: "Copy Address", table: "Interface")) {
                guard case .browser(let current)? = currentMenuTab(tabID)?.content else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(current.urlString, forType: .string)
            }
            Divider()
        }
        let closeTitle = closeTitle(for: .tab(tabID))
        Button {
            guard currentMenuTab(tabID) != nil else { return }
            close(.tab(tabID))
        } label: {
            Text(verbatim: closeTitle + "\t⌘W")
        }
        .accessibilityLabel(closeTitle)
        .disabled(project.isClosingPanels || tab.content.isClosing)
        Button(String(localized: "Close Others", table: "Interface")) {
            if let current = currentMenuTab(tabID) { project.closeOthers(current) }
        }
        .disabled(project.isClosingPanels || project.dock.commandTargets(for: .tab(tabID), scope: .otherTabs).isEmpty)
        Button(String(localized: "Close Tabs to the Right", table: "Interface")) {
            if let current = currentMenuTab(tabID) { project.closeToRight(of: current) }
        }
        .disabled(project.isClosingPanels || project.dock.commandTargets(for: .tab(tabID), scope: .tabsToRight).isEmpty)
        Divider()
        Button(String(localized: "Close Files", table: "Interface")) {
            if currentMenuTab(tabID) != nil { project.closeFiles() }
        }
        .disabled(project.isClosingPanels || !project.tabs.contains { $0.content.isFile })
        Button(String(localized: "Close Diffs", table: "Interface")) {
            if currentMenuTab(tabID) != nil { project.closeDiffs() }
        }
        .disabled(project.isClosingPanels || !project.tabs.contains { $0.content.isDiff })
        Button(String(localized: "Close All", table: "Interface")) {
            if currentMenuTab(tabID) != nil { project.closeAll() }
        }
        .disabled(project.isClosingPanels)
    }

    @ViewBuilder
    private var dropPreview: some View {
        if let drag = dragging.position, drag.destination == group.id,
           dragging.insertionX(in: group) == nil {
            GeometryReader { geometry in
                let size = geometry.size
                let previewWidth = (drag.edge == .left || drag.edge == .right)
                    ? size.width * 0.5 : size.width
                let previewHeight = (drag.edge == .top || drag.edge == .bottom)
                    ? size.height * 0.5 : size.height
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: Theme.accent).opacity(0.17))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color(nsColor: Theme.accent).opacity(0.68), lineWidth: 1))
                    .frame(width: previewWidth, height: previewHeight)
                    .offset(
                        x: drag.edge == .right ? size.width - previewWidth : 0,
                        y: drag.edge == .bottom ? size.height - previewHeight : 0
                    )
                    .padding(1)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct DockTabPointerInput: NSViewRepresentable {
    let press: (NSEvent.ModifierFlags) -> Void
    let release: (NSEvent.ModifierFlags) -> Void
    let drag: (CGPoint, Bool) -> Void
    let close: () -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> DockTabPointerView { DockTabPointerView() }
    func updateNSView(_ view: DockTabPointerView, context: Context) {
        view.press = press
        view.release = release
        view.drag = drag
        view.close = close
        view.cancel = cancel
    }
    static func dismantleNSView(_ view: DockTabPointerView, coordinator: ()) {
        view.cancelOperation(nil)
        view.press = nil
        view.release = nil
        view.drag = nil
        view.close = nil
        view.cancel = nil
    }
}

final class DockTabPointerView: NSView {
    var press: ((NSEvent.ModifierFlags) -> Void)?
    var release: ((NSEvent.ModifierFlags) -> Void)?
    var drag: ((CGPoint, Bool) -> Void)?
    var close: (() -> Void)?
    var cancel: (() -> Void)?
    private var dragKeyMonitor: Any?
    private var origin: CGPoint?
    private var dragged = false
    private var modifiers: NSEvent.ModifierFlags = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown || (event.type == .leftMouseDown && !event.modifierFlags.contains(.control))
        else { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        origin = event.locationInWindow
        dragged = false
        modifiers = event.modifierFlags
        press?(modifiers)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        if !dragged, hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4 {
            dragged = true
            dragKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] key in
                guard let self, key.window === self.window, self.window?.isKeyWindow == true,
                      key.keyCode == 53, key.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                else { return key }
                self.cancelOperation(nil)
                return nil
            }
        }
        if dragged { drag?(location(event), false) }
    }
    override func mouseUp(with event: NSEvent) {
        guard origin != nil else { return }
        if let window, !window.isKeyWindow { cancelOperation(nil); return }
        origin = nil
        stopMonitoring()
        if dragged { drag?(location(event), true) }
        else { release?(modifiers) }
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { close?() }
    }
    override func cancelOperation(_ sender: Any?) {
        origin = nil
        dragged = false
        stopMonitoring()
        cancel?()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelOperation(nil) }
    }
    private func stopMonitoring() {
        if let dragKeyMonitor { NSEvent.removeMonitor(dragKeyMonitor) }
        dragKeyMonitor = nil
    }
    private func location(_ event: NSEvent) -> CGPoint {
        guard let content = window?.contentView else { return event.locationInWindow }
        let point = content.convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
    }
}

private struct DockGroupFocusReader: NSViewRepresentable {
    let groupID: UUID
    let isActive: Bool
    let focusesEmptySpace: Bool
    let canFocus: () -> Bool
    let onFocused: () -> Void
    let onPrimaryClick: () -> Void

    func makeNSView(context: Context) -> DockGroupFocusView {
        DockGroupFocusView(groupID: groupID)
    }

    func updateNSView(_ view: DockGroupFocusView, context: Context) {
        view.canFocus = canFocus
        view.onFocused = onFocused
        view.onPrimaryClick = onPrimaryClick
        let becameActive = isActive && !view.isActive
        view.isActive = isActive
        view.focusesEmptySpace = focusesEmptySpace
        if becameActive && focusesEmptySpace { view.requestFocusAfterClick() }
    }

    static func dismantleNSView(_ view: DockGroupFocusView, coordinator: ()) {
        view.stopMonitoring()
        view.onFocused = nil
        view.onPrimaryClick = nil
        view.canFocus = nil
    }
}

final class DockGroupFocusView: NSView {
    let groupID: UUID
    var isActive = false
    var focusesEmptySpace = true
    var canFocus: (() -> Bool)?
    var onFocused: (() -> Void)?
    var onPrimaryClick: (() -> Void)?
    private var monitor: Any?
    private var leftMousePressedHere = false

    init(groupID: UUID) {
        self.groupID = groupID
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocused?() }
        return became
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  !self.isHiddenOrHasHiddenAncestor else { return event }
            if event.type == .rightMouseDown ||
               (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
                self.leftMousePressedHere = false
            } else if event.type == .leftMouseDown {
                self.leftMousePressedHere = self.bounds.contains(
                    self.convert(event.locationInWindow, from: nil))
            } else if event.type == .keyDown {
                if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                   self.containsResponder(window.firstResponder) { self.onFocused?() }
            } else {
                if event.type == .leftMouseUp {
                    let pressedHere = self.leftMousePressedHere
                    self.leftMousePressedHere = false
                    guard pressedHere else { return event }
                }
                if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onPrimaryClick?()
                    let location = self.convert(event.locationInWindow, from: nil)
                    guard location.y < self.bounds.maxY - 38 else { return event }
                    self.onFocused?()
                    if self.focusesEmptySpace { self.requestFocusAfterClick() }
                }
            }
            return event
        }
        if isActive && focusesEmptySpace { requestFocusAfterClick() }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        leftMousePressedHere = false
    }

    func requestFocusAfterClick() {
        // Allow the clicked native control to become first responder before
        // empty space in a tool pane can release the previous editor.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.focusesEmptySpace else { return }
            self.focusIfNeeded()
        }
    }

    private func focusIfNeeded() {
        guard canFocus?() == true, let window,
              !containsResponder(window.firstResponder) else { return }
        window.makeFirstResponder(self)
    }

    func containsResponder(_ responder: NSResponder?) -> Bool {
        guard var view = responder as? NSView, view.window === window else { return false }
        // The window's hosting root spans every Dock group, so its midpoint
        // cannot establish ownership of a particular group.
        if view === window?.contentView { return false }
        if let editor = view as? NSTextView, editor.isFieldEditor,
           let control = editor.delegate as? NSView { view = control }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current is TerminalParkingContainerView { return false }
            ancestor = current.superview
        }
        let visible = view.visibleRect.intersection(view.bounds)
        guard !view.isHiddenOrHasHiddenAncestor, !visible.isEmpty else { return false }
        return bounds.contains(convert(NSPoint(x: visible.midX, y: visible.midY), from: view))
    }
}
