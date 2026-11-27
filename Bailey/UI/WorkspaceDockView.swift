import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The same partition is used to lay out panes and to locate a drop.
struct DockLayout {
    struct Pane: Identifiable {
        let group: DockGroup
        let frame: CGRect
        var id: UUID { group.id }
    }

    struct Divider: Identifiable {
        let split: DockSplit
        let frame: CGRect
        let available: CGFloat
        var id: UUID { split.id }
    }

    private(set) var panes: [Pane] = []
    private(set) var dividers: [Divider] = []

    init(_ node: DockNode, in bounds: CGRect, resizing: (id: UUID, fraction: Double)? = nil) {
        append(node, in: bounds, resizing: resizing)
    }

    private mutating func append(_ node: DockNode, in bounds: CGRect,
                                 resizing: (id: UUID, fraction: Double)?) {
        switch node {
        case .group(let group):
            panes.append(Pane(group: group, frame: bounds))
        case .split(let split):
            let horizontal = split.axis == .horizontal
            let available = max(0, (horizontal ? bounds.width : bounds.height) - 1)
            let fraction = resizing.flatMap { $0.id == split.id ? $0.fraction : nil } ?? split.fraction
            let firstLength = available * fraction
            let secondLength = max(0, available - firstLength)
            let first: CGRect
            let divider: CGRect
            let second: CGRect
            if horizontal {
                first = CGRect(x: bounds.minX, y: bounds.minY, width: firstLength, height: bounds.height)
                divider = CGRect(x: first.maxX, y: bounds.minY, width: 1, height: bounds.height)
                second = CGRect(x: divider.maxX, y: bounds.minY, width: secondLength, height: bounds.height)
            } else {
                first = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: firstLength)
                divider = CGRect(x: bounds.minX, y: first.maxY, width: bounds.width, height: 1)
                second = CGRect(x: bounds.minX, y: divider.maxY, width: bounds.width, height: secondLength)
            }
            append(split.first, in: first, resizing: resizing)
            dividers.append(Divider(split: split, frame: divider, available: available))
            append(split.second, in: second, resizing: resizing)
        }
    }
}

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
        let destinationFrame: CGRect?
        let edge: DockEdge?
        let index: Int?
    }

    private(set) var position: Position?
    @ObservationIgnored private var source: Source?
    @ObservationIgnored private weak var sourceDock: DockWorkspaceModel?
    @ObservationIgnored private var rootFrame = CGRect.zero
    @ObservationIgnored private var tabs: [UUID: [DockItem: CGRect]] = [:]
    @ObservationIgnored private weak var frameOwner: DockWorkspaceModel?
    @ObservationIgnored private var escapeMonitor: Any?

    isolated deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    func cancel(_ item: DockItem? = nil) {
        if let item, source?.item != item { return }
        guard source != nil || position != nil || escapeMonitor != nil else { return }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        // Ending a gesture does not invalidate the visible tab geometry.
        if position != nil { position = nil }
        source = nil
        sourceDock = nil
        NSCursor.arrow.set()
    }

    func setRootFrame(_ frame: CGRect) {
        guard rootFrame != frame else { return }
        cancel()
        rootFrame = frame
    }

    func useTabFrames(for dock: DockWorkspaceModel?) {
        if frameOwner !== dock { tabs.removeAll(); frameOwner = dock }
    }

    func setTabFrame(_ frame: CGRect?, for item: DockItem, in group: UUID, dock: DockWorkspaceModel) {
        useTabFrames(for: dock)
        guard tabs[group]?[item] != frame else { return }
        if let frame {
            tabs[group, default: [:]][item] = frame
        } else {
            tabs[group]?[item] = nil
            if tabs[group]?.isEmpty == true { tabs[group] = nil }
        }
        if let position, let dock = sourceDock {
            update(position.item, at: position.location, dock: dock)
        }
    }

    func begin(_ item: DockItem, dock: DockWorkspaceModel) {
        cancel()
        let current = dock.root
        guard let group = current.group(containing: item) else { return }
        sourceDock = dock
        source = Source(item: item, items: dock.commandTargets(for: item),
                        sourceGroupID: group.id, sourceLayout: current.mappingGroups { $0.selected = nil })
        let window = NSApp.keyWindow
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard event.window === window, window?.isKeyWindow == true,
                  event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            else { return event }
            self?.cancel()
            return nil
        }
    }

    func insertionX(in group: DockGroup) -> CGFloat? {
        guard let position, position.destination == group.id, position.edge == nil,
              let frame = position.destinationFrame,
              position.location.y >= frame.minY, position.location.y < frame.minY + 38,
              let index = position.index, !group.items.isEmpty else { return nil }
        if index < group.items.count, let bounds = tabs[group.id]?[group.items[index]] {
            return bounds.minX
        }
        // The adjacent tab can be outside the lazy strip's mounted range.
        if index > 0, let bounds = tabs[group.id]?[group.items[index - 1]] {
            return bounds.maxX
        }
        return nil
    }

    func update(_ item: DockItem, at location: CGPoint, dock: DockWorkspaceModel) {
        guard let source, sourceDock === dock, source.item == item else { cancel(); return }
        let current = dock.root
        guard source.sourceLayout == current.mappingGroups({ $0.selected = nil }) else { cancel(); return }
        let hit = DockLayout(current, in: rootFrame).panes.first { $0.frame.contains(location) }
        var edge: DockEdge?
        var insertIndex: Int?
        if let hit {
            let target = hit.group
            let frame = hit.frame
            edge = DockDropHitTest.edge(at: location, in: frame)
            if edge == nil {
                if location.y <= frame.minY + 38 {
                    let mounted = tabs[target.id] ?? [:]
                    insertIndex = target.items.firstIndex { tab in
                        mounted[tab].map { location.x < $0.midX } ?? false
                    } ?? target.items.lastIndex { mounted[$0] != nil }.map { $0 + 1 }
                        ?? target.items.count
                } else {
                    insertIndex = target.items.count
                }
            }
        }
        position = Position(
            source: source, location: location,
            destination: hit?.id, destinationFrame: hit?.frame, edge: edge, index: insertIndex
        )
    }

    func finish(project: Project) {
        defer { cancel() }
        guard let position, sourceDock === project.dock, project.dock.root.mappingGroups({ $0.selected = nil }) == position.source.sourceLayout,
              let destination = position.destination else { return }
        project.movePanels(
            position.item, into: destination,
            edge: position.edge, index: position.index, items: position.items,
            sourceGroupID: position.source.sourceGroupID
        )
    }
}

struct WorkspaceDockView: View {
    private let themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    let manager: WorkspaceWindowModel
    let git: GitStatusModel
    @State private var dragging = DockTabDragCoordinator()

    var body: some View {
        GeometryReader { rootGeometry in
            if let project = manager.selectedProject {
                let layout = project.dock.root
                DockTreeView(
                    node: layout, project: project, manager: manager,
                    git: git, dragging: dragging
                )
                .frame(width: rootGeometry.size.width, height: rootGeometry.size.height)
                .background {
                    let _ = themeChanges.revision
                    Color(nsColor: Theme.terminal(dark: colorScheme == .dark).backgroundNSColor)
                }
                .onDisappear { manager.attachedWindow?.isMovable = true }
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
        .onChange(of: manager.selectedProjectID) {
            dragging.cancel()
            dragging.useTabFrames(for: manager.selectedProject?.dock)
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
            dragging.setRootFrame($0)
        }
    }
}

extension DockItem {
    var symbol: String {
        switch self {
        case .projects: "square.grid.2x2"
        case .files: "folder"
        case .git: "arrow.triangle.branch"
        case .tab: "terminal"
        case .filePreview: "doc.richtext"
        }
    }

    var accessibilityName: String {
        switch self {
        case .projects: "projects"
        case .files: "files"
        case .git: "git"
        case .filePreview: "markdown-preview"
        case .tab: "tab"
        }
    }

    func label(project: Project) -> String {
        switch self {
        case .projects: String(localized: "Projects", table: "Interface")
        case .files: String(localized: "File Manager", table: "Sidebar")
        case .git: String(localized: "Git Manager", table: "Sidebar")
        case .tab(let id): project.tabs.first { $0.id == id }?.displayTitle ?? String(localized: "Tab", table: "Workspace")
        case .filePreview: String(localized: "Preview", table: "Editor")
        }
    }
}

/// A group keeps its SwiftUI identity when a neighboring split is inserted
/// or collapsed. Only its rectangle changes.
private struct DockTreeView: View {
    private let themeChanges = Theme.changes
    let node: DockNode
    let project: Project
    let manager: WorkspaceWindowModel
    let git: GitStatusModel
    let dragging: DockTabDragCoordinator
    @GestureState private var resizing: (id: UUID, fraction: Double)?

    var body: some View {
        let _ = themeChanges.revision
        GeometryReader { geometry in
            let layout = DockLayout(node, in: CGRect(origin: .zero, size: geometry.size), resizing: resizing)
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes) { pane in
                    DockTabGroupView(
                        group: pane.group, project: project, manager: manager,
                        git: git, dragging: dragging, isTopLeft: pane.id == layout.panes.first?.id
                    )
                    .id(project.id)
                    .frame(width: pane.frame.width, height: pane.frame.height)
                    .position(x: pane.frame.midX, y: pane.frame.midY)
                }
                ForEach(layout.dividers) { entry in
                    divider(entry)
                        .frame(width: entry.frame.width, height: entry.frame.height)
                        .position(x: entry.frame.midX, y: entry.frame.midY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func divider(_ entry: DockLayout.Divider) -> some View {
        let split = entry.split
        let available = entry.available
        let horizontal = split.axis == .horizontal
        func fraction(_ translation: CGSize) -> Double {
            guard available > 0 else { return split.fraction }
            let delta = horizontal ? translation.width : translation.height
            let minimumLength: CGFloat = horizontal ? 150 : 90
            let minimum = min(0.48, max(0.1, Double(minimumLength / available)))
            return min(max(split.fraction + Double(delta / available), minimum), 1 - minimum)
        }
        return Rectangle()
            .fill(Color(nsColor: Theme.divider))
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: horizontal ? 7 : nil, height: horizontal ? nil : 7)
                    .contentShape(Rectangle())
                    .pointerStyle(horizontal ? .columnResize : .rowResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .updating($resizing) { value, state, _ in
                            state = (split.id, fraction(value.translation))
                        }
                        .onEnded { value in
                            manager.resizeDock(split.id, to: fraction(value.translation))
                        })
            }
            .accessibilityIdentifier("bailey.dock.divider")
            .onHover { manager.attachedWindow?.isMovable = !$0 }
    }
}

struct DockTabGroupView: View {
    private enum MarkdownPopover: Equatable {
        case metadata(UUID)
        case outline(UUID)
    }

    private let themeChanges = Theme.changes
    let group: DockGroup
    let project: Project
    let manager: WorkspaceWindowModel
    let git: GitStatusModel
    let dragging: DockTabDragCoordinator
    var isTopLeft = false
    private let settings = AppSettings.shared
    @State private var showingPanelPicker = false
    @State private var tabKeyboard = TreeKeyboardOwner()
    @State private var tabCursor: DockItem?
    @State private var tabKeyboardFocused = false
    @State private var tabStripContentWidth: CGFloat = 0
    @State private var mountedTabItems: Set<DockItem> = []
    @State private var dragGestureItem: DockItem?
    @State private var markdownPopover: MarkdownPopover?
    @GestureState private var isTabDragging = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var active: DockItem? { group.selected }
    // Appearance follows reactive window and Dock state; permission to take
    // native input is checked independently by canFocusGroup at execution.
    private var isFocused: Bool {
        controlActiveState == .key && manager.selectedProject === project
            && project.dock.activeGroupID == group.id
            && !manager.isCommandPaletteVisible && !manager.isSSHFolderPickerVisible
    }

    private var canFocusGroup: () -> Bool {
        { [weak manager, weak project, groupID = group.id] in
            guard let manager, let project else { return false }
            return manager.selectedProject === project && project.dock.activeGroupID == groupID
                && manager.attachedWindow?.isKeyWindow == true && NSApp.isActive
                && !manager.isCommandPaletteVisible && !manager.isSSHFolderPickerVisible
                && manager.attachedWindow?.attachedSheet == nil
        }
    }

    private func focusGroup() {
        guard manager.selectedProject === project, !manager.isCommandPaletteVisible,
              !manager.isSSHFolderPickerVisible, manager.attachedWindow?.attachedSheet == nil else { return }
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
        .popover(isPresented: Binding(
            get: { markdownPopover != nil },
            set: { if !$0 { markdownPopover = nil } }
        )) {
            switch markdownPopover {
            case .metadata(let id):
                if case .file(let file)? = currentMenuTab(id)?.content {
                    MarkdownMetadataView(file: file)
                }
            case .outline(let id):
                if let tab = currentMenuTab(id), case .file(let file) = tab.content {
                    MarkdownOutlineView(file: file) { heading in
                        guard let current = currentMenuTab(id) else { return }
                        file.pendingMarkdownFragment = heading.anchor
                        if project.filePreviewMode(for: current) == .source {
                            project.setFilePreviewMode(.preview, for: current)
                        }
                        markdownPopover = nil
                    } onDismiss: {
                        markdownPopover = nil
                    }
                }
            case nil:
                EmptyView()
            }
        }
    }

    private var header: some View {
        GeometryReader { geometry in
            let dragWidth = isTopLeft ? min(76, max(0, geometry.size.width - 124)) : 0
            HStack(spacing: 4) {
                if dragWidth > 0 { WindowDragArea().frame(width: dragWidth) }
                tabStrip(maxWidth: max(0, geometry.size.width - dragWidth - 44))
                panelAddButton
                    .onHover { manager.attachedWindow?.isMovable = !$0 }
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
        .accessibilityIdentifier("bailey.dock.addPanel")
        .popover(isPresented: $showingPanelPicker, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                openFileButton
                newItemButton(isDirectory: false)
                newItemButton(isDirectory: true)
                Button {
                    showingPanelPicker = false
                    project.newSession(inGroup: group.id)
                } label: {
                    HStack {
                        Label(String(localized: "New Terminal", table: "Interface"), systemImage: "terminal")
                        Spacer(minLength: 0)
                        if isFocused {
                            Text(verbatim: "⌘T").foregroundStyle(.secondary)
                        }
                    }
                    .padding(7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                let tools = manager.dockLayout.availableTools
                if !tools.isEmpty { Divider() }
                ForEach(tools, id: \.self) { item in
                    Button {
                        showingPanelPicker = false
                        project.dock.place(item, in: group.id)
                    } label: {
                        HStack {
                            Label(item.label(project: project), systemImage: item.symbol)
                            Spacer(minLength: 0)
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
    }

    private func tabStrip(maxWidth: CGFloat) -> some View {
        let tabsByID = Dictionary(uniqueKeysWithValues: project.tabs.map { ($0.id, $0) })
        let selectedItems = Set(project.dock.selection(in: group.id))
        let draggedItems = Set(dragging.position?.items ?? [])
        return ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(group.items, id: \.self) { item in
                        let mounted = mountedTabItems.contains(item)
                        tab(item, paneTab: item.tabID.flatMap { tabsByID[$0] },
                            isSelected: selectedItems.contains(item), isMounted: mounted)
                            .onHover { manager.attachedWindow?.isMovable = !$0 }
                            .opacity(draggedItems.contains(item) ? 0.6 : 1)
                            .onGeometryChange(for: CGRect?.self, of: { geometry in
                                guard let viewport = geometry.bounds(of: .scrollView(axis: .horizontal)) else { return nil }
                                let visible = CGRect(origin: .zero, size: geometry.size).intersection(viewport)
                                guard !visible.isEmpty else { return nil }
                                let frame = geometry.frame(in: .global)
                                return visible.offsetBy(dx: frame.minX, dy: frame.minY)
                            }) { frame in
                                guard manager.selectedProject === project,
                                      project.dock.group(containing: item)?.id == group.id else { return }
                                dragging.setTabFrame(frame, for: item, in: group.id, dock: project.dock)
                            }
                            .onDisappear {
                                if manager.selectedProject === project && project.dock.group(containing: item)?.id != group.id {
                                    dragging.setTabFrame(nil, for: item, in: group.id, dock: project.dock)
                                }
                            }
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                    .updating($isTabDragging) { _, active, _ in active = true }
                                    .onChanged { value in
                                        guard manager.selectedProject === project else { return }
                                        if dragGestureItem != item {
                                            dragGestureItem = item
                                            dragging.begin(item, dock: project.dock)
                                        }
                                        dragging.update(item, at: value.location, dock: project.dock)
                                        if dragging.position != nil { NSCursor.closedHand.set() }
                                    }
                                    .onEnded { value in
                                        if manager.selectedProject === project, dragGestureItem == item {
                                            dragging.update(item, at: value.location, dock: project.dock)
                                            dragging.finish(project: project)
                                        }
                                        dragGestureItem = nil
                                    }
                            )
                            .id(item)
                    }
                }
                .scrollTargetLayout()
                .padding(.leading, 4)
                .padding(.trailing, 2)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    tabStripContentWidth = $0
                }
            }
            // Use actual laid-out tab widths, not estimates from a lazy stack.
            // The same strip can reveal any item, but offscreen items do not
            // instantiate AppKit context menus or register drag hit targets.
            .onScrollTargetVisibilityChange(idType: DockItem.self, threshold: 0.001) { visible in
                let items = Set(visible)
                if items != mountedTabItems { mountedTabItems = items }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(width: maxWidth, alignment: .leading)
            .clipped()
            .overlay(alignment: .trailing) {
                if tabStripContentWidth > 0 && tabStripContentWidth < maxWidth {
                    WindowDragArea().frame(width: maxWidth - tabStripContentWidth, height: 38)
                }
            }
            .background(TreeKeyboardHost(
                owner: tabKeyboard, onKeyDown: handleTabKey,
                onFocusChanged: { focused in
                    tabKeyboardFocused = focused
                    if focused, tabCursor.map({ !group.items.contains($0) }) ?? true { tabCursor = active }
                }, onAttachedToWindow: { tabKeyboard.view?.setAccessibilityIdentifier("bailey.dock.tabstrip") }
            ).focusedValue(\.baileyPathActions, focusedTabPathActions))
            .onChange(of: group.selected, initial: true) { _, selected in
                if let selected { scrollProxy.scrollTo(selected) }
            }
            .onChange(of: tabCursor) { _, cursor in
                if let cursor { scrollProxy.scrollTo(cursor) }
            }
            .onChange(of: group.items) { _, items in
                if tabCursor.map({ !items.contains($0) }) ?? false { tabCursor = active }
            }
            .onChange(of: isTabDragging) { _, active in
                if !active {
                    if let item = dragGestureItem { dragging.cancel(item) }
                    dragGestureItem = nil
                }
            }
        }
    }

    private func tab(_ item: DockItem, paneTab: PaneTab?, isSelected: Bool, isMounted: Bool) -> some View {
        Group {
            if let paneTab {
                PaneTabItem(
                    tab: paneTab, isDisplayed: active == item,
                    isSelected: isSelected,
                    isKeyboardFocused: tabKeyboardFocused && tabCursor == item, isPaneFocused: isFocused,
                    isContextTarget: project.dock.contextTarget == item,
                    select: { select(item, extending: selectionChange(NSEvent.modifierFlags)) },
                    close: { close(item) }
                )
            } else {
                TabItemChrome(
                    systemImage: item.symbol, title: item.label(project: project),
                    isDisplayed: active == item,
                    isSelected: isSelected,
                    isKeyboardFocused: tabKeyboardFocused && tabCursor == item, isPaneFocused: isFocused,
                    isContextTarget: project.dock.contextTarget == item,
                    select: { select(item, extending: selectionChange(NSEvent.modifierFlags)) },
                    close: { close(item) }
                )
                .accessibilityIdentifier("bailey.dock.\(item.accessibilityName)")
            }
        }
        .overlay {
            if isMounted {
                ContextMenuClickTarget(
                    onContextClick: { project.dock.selectForContextMenu(item) },
                    onMenuClosed: { finishTabContextMenu(for: item) },
                    isExpectedMenu: { isMenuForTab($0, item: item) },
                    onMiddleClick: { manager.closePanel(item, in: project) }
                )
                .contextMenu {
                    if let paneTab {
                        if let current = project.tabs.first(where: { $0.id == paneTab.id }) {
                            projectTabMenu(current)
                        }
                    } else {
                        Button(closeTitle(for: item)) {
                            guard isValidMenuTarget(item) else { return }
                            close(item)
                        }
                        .keyboardShortcut("w", modifiers: .command)
                        .disabled(project.isClosingPanels)
                    }
                }
            }
        }
    }

    private func finishTabContextMenu(for item: DockItem) {
        guard project.dock.contextTarget == item else { return }
        project.dock.clearContextTarget()
    }

    private var focusedTabPathActions: FocusedPathActions? {
        guard tabKeyboardFocused, isFocused,
              case .tab(let id)? = tabCursor ?? active,
              let tab = project.tabs.first(where: { $0.id == id }),
              case .file(let file) = tab.content else { return nil }
        return FocusedPathActions.file(file, in: project, isValid: canFocusGroup)
    }

    private func contentPathActions(for tab: PaneTab) -> FocusedPathActions? {
        guard case .file(let file) = tab.content else { return nil }
        return FocusedPathActions.file(file, in: project, isValid: canFocusGroup)
    }

    private func isMenuForTab(_ menu: NSMenu, item: DockItem) -> Bool {
        guard isValidMenuTarget(item), project.dock.contextTarget == item else { return false }
        let title = closeTitle(for: item)
        let alternate = String(localized: "Close Others", table: "Interface")
        return menu.items.contains { $0.title == title || (item.tabID != nil && $0.title == alternate) }
    }

    private func selectionChange(_ modifiers: NSEvent.ModifierFlags) -> DockWorkspaceModel.SelectionChange {
        if modifiers.contains(.shift) { return .range }
        if modifiers.contains(.command) { return .toggle }
        return .replace
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
            && manager.attachedWindow?.isKeyWindow == true
    }

    private func currentMenuTab(_ id: UUID) -> PaneTab? {
        guard isValidMenuTarget(.tab(id)) else { return nil }
        return project.tabs.first { $0.id == id }
    }

    private func openHTML(_ tabID: UUID, saveFirst: Bool) {
        guard case .file(let file)? = currentMenuTab(tabID)?.content else { return }
        Task { @MainActor in
            do {
                try await project.openHTMLInBrowser(file, saveFirst: saveFirst) {
                    currentMenuTab(tabID)?.content.id == file.id
                }
            } catch is CancellationError {
                return
            } catch {
                guard currentMenuTab(tabID)?.content.id == file.id,
                      let window = manager.attachedWindow else { return }
                let alert = NSAlert()
                alert.messageText = String(localized: "Could not open the saved HTML.", table: "Editor")
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window) { _ in }
            }
        }
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
        case .tab(let id), .filePreview(let id):
            if let tab = project.tabs.first(where: { $0.id == id }) {
                PanelContentView(
                    tab: tab,
                    isFocused: isFocused,
                    canFocus: canFocusGroup,
                    onFocused: focusGroup,
                    onNewBrowserTab: {
                        guard manager.selectedProject === project else { return }
                        manager.newBrowserTab(initialURL: $0)
                    },
                    onNewFileTab: {
                        guard manager.selectedProject === project,
                              project.dock.root.group(id: group.id)?.selected == .tab(tab.id)
                        else { return }
                        project.openLocalFile($0, inGroup: group.id)
                    },
                    resourceDirectory: resourceDirectory(for: tab),
                    rendersOnlyPreview: active == .filePreview(id),
                    onMarkdownLink: { file, url in
                        await project.openMarkdownLink(url, from: file) {
                            manager.selectedProject === project && manager.attachedWindow?.isKeyWindow == true
                        }
                    },
                    onRevealFileSource: {
                        guard manager.selectedProject === project,
                              project.tabs.contains(where: { $0 === tab }) else { return }
                        project.dock.select(.tab(id))
                    },
                    onExternalFilesDropped: { FinderWindowDrop.receive(
                        $0, preferred: manager,
                        destination: (projectID: project.id, groupID: group.id)
                    ) }
                )
                .focusedValue(\.baileyPathActions, contentPathActions(for: tab))
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

    private func resourceDirectory(for tab: PaneTab) -> String? {
        guard case .file(let file) = tab.content,
              file.workspaceIdentity == project.workspaceIdentity else { return nil }
        return project.customDirectory
    }

    @ViewBuilder
    private func projectTabMenu(_ tab: PaneTab) -> some View {
        let tabID = tab.id
        if case .file(let file) = tab.content {
            if file.canPreviewFile {
                ForEach(FilePreviewMode.allCases, id: \.self) { mode in
                    Button(mode.title(for: file.previewKind)) {
                        if let current = currentMenuTab(tabID) {
                            project.setFilePreviewMode(mode, for: current)
                        }
                    }
                    .disabled(project.filePreviewMode(for: tab) == mode)
                }
            }
            if file.canPreviewFile, file.previewKind == .html {
                if file.workspaceIdentity != nil {
                    Text("Remote HTML cannot run in the local browser.", tableName: "Editor")
                } else {
                    Button(file.isDirty ? String(localized: "Open Saved HTML in Browser", table: "Editor")
                           : String(localized: "Open HTML in Browser", table: "Editor")) {
                        openHTML(tabID, saveFirst: false)
                    }
                    .disabled(!file.canRunLocalHTML || file.isSaving)
                    if file.isDirty {
                        Button(String(localized: "Save and Open HTML in Browser", table: "Editor")) {
                            openHTML(tabID, saveFirst: true)
                        }
                        .disabled(!file.canRunLocalHTML || file.isSaving)
                    }
                }
            }
            if file.canPreviewMarkdown {
                Toggle(String(localized: "Synchronize Scrolling", table: "Editor"), isOn: Binding(
                    get: { file.markdownScrollSyncEnabled },
                    set: { value in
                        guard case .file(let current)? = currentMenuTab(tabID)?.content else { return }
                        current.markdownScrollSyncEnabled = value
                        if value { current.editorCoordinator?.refreshMarkdownViewport() }
                    }
                ))
                Button(String(localized: "Outline…", table: "Editor")) {
                    if currentMenuTab(tabID) != nil { markdownPopover = .outline(tabID) }
                }
                Button(String(localized: "Front Matter…", table: "Editor")) {
                    if currentMenuTab(tabID) != nil { markdownPopover = .metadata(tabID) }
                }
                Divider()
            } else if file.canPreviewFile {
                Divider()
            }
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
                .keyboardShortcut(PathMenuShortcut.reveal)
            }
            Button(String(localized: "Copy Path", table: "Sidebar")) {
                guard case .file(let current)? = currentMenuTab(tabID)?.content else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(current.path, forType: .string)
            }
            .keyboardShortcut(PathMenuShortcut.copyAbsolute)
            let relativeRoot = project.customDirectory == "/" ? "/" : project.customDirectory + "/"
            let relativePath = file.workspaceIdentity == project.workspaceIdentity && file.path.hasPrefix(relativeRoot)
                ? String(file.path.dropFirst(relativeRoot.count)) : nil
            Button(String(localized: "Copy Relative Path", table: "Sidebar")) {
                guard case .file(let current)? = currentMenuTab(tabID)?.content,
                      current.workspaceIdentity == project.workspaceIdentity else { return }
                let root = project.customDirectory == "/" ? "/" : project.customDirectory + "/"
                guard current.path.hasPrefix(root) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(current.path.dropFirst(root.count)), forType: .string)
            }
            .keyboardShortcut(PathMenuShortcut.copyRelative)
            .disabled(relativePath == nil)
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
        Button(closeTitle) {
            guard currentMenuTab(tabID) != nil else { return }
            close(.tab(tabID))
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(project.isClosingPanels || tab.content.isClosing)
        .modifierKeyAlternate(.option) {
            Button(String(localized: "Close Others", table: "Interface")) {
                if let current = currentMenuTab(tabID) { project.closeOthers(current) }
            }
            .disabled(project.isClosingPanels || project.dock.commandTargets(for: .tab(tabID), scope: .otherTabs).isEmpty)
        }
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
