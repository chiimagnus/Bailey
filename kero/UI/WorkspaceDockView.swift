import AppKit
import Observation
import SwiftUI

/// Window-wide docking gesture. One hit-tested destination and one preview:
/// the pointer's proximity to a pane edge determines the split, while the
/// title strip and the interior merge into the existing tab group.
@MainActor
@Observable
final class DockTabDragCoordinator {
    struct Position {
        let item: DockItem
        let location: CGPoint
        let destination: UUID?
        let edge: DockEdge?
        let index: Int?
    }

    private(set) var position: Position?
    @ObservationIgnored private var groups: [UUID: CGRect] = [:]
    @ObservationIgnored private var tabs: [DockItem: CGRect] = [:]

    func cancel() {
        // Layout preferences may update before project-switch cancellation;
        // preserve their latest frames so the next drag can still hit a target.
        position = nil
    }

    func setFrames(groups: [UUID: CGRect]) { self.groups = groups }
    func setFrames(tabs: [DockItem: CGRect]) { self.tabs = tabs }

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
            if edge != nil && target.items == [item] { edge = nil }
        }
        position = Position(
            item: item, location: location,
            destination: hit?.key, edge: edge, index: insertIndex
        )
    }

    func finish(project: Project) {
        defer {
            position = nil
            NSCursor.arrow.set()
        }
        guard let position, let destination = position.destination else { return }
        guard project.dock.move(
            position.item, into: destination,
            edge: position.edge, index: position.index
        ) else { return }
        if case .tab(let id) = position.item { project.selectedTabID = id }
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
    @ObservedObject var manager: TerminalManager
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
    @ObservedObject var project: Project
    @ObservedObject var manager: TerminalManager
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
    }
}

private struct DockTabGroupView: View {
    private let themeChanges = Theme.changes
    let group: DockGroup
    @ObservedObject var project: Project
    @ObservedObject var manager: TerminalManager
    let git: GitStatusModel
    let dragging: DockTabDragCoordinator
    private let settings = AppSettings.shared
    @State private var renamingTabID: UUID?
    @State private var showingPanelPicker = false

    private var active: DockItem? { group.selected ?? group.items.first }

    var body: some View {
        let _ = themeChanges.revision
        VStack(spacing: 0) {
            header
                .frame(height: 38)
                .background(Color(nsColor: Theme.background))
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
                    hideToolbar: { settings.toolbarVisibility = .hide }
                )
            }
        }
        .background(Color(nsColor: Theme.background))
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
            HStack(spacing: 4) {
                if isTopLeft { WindowDragArea().frame(width: 76) }
                tabStrip(maxWidth: max(0, geometry.size.width
                    - (isTopLeft ? 120 : 44)
                    - (manager.isFPSCounterVisible ? 42 : 0)))
                panelAddButton
                WindowDragArea().frame(minWidth: 0, maxWidth: .infinity)
                if manager.isFPSCounterVisible { FPSBadge() }
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
                        newItemButton(isDirectory: false)
                        newItemButton(isDirectory: true)
                    }
                    Button {
                        showingPanelPicker = false
                        if let item = action.item { add(item) } else { addSession() }
                    } label: {
                        Label(
                            action.item?.label(project: project)
                                ?? String(localized: "New Terminal", table: "Interface"),
                            systemImage: action.item?.symbol ?? "terminal"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func newItemButton(isDirectory: Bool) -> some View {
        Button {
            showingPanelPicker = false
            Task {
                guard manager.selectedProjectID == project.id else { return }
                if isDirectory { await manager.newFolder() }
                else { await manager.newFile() }
            }
        } label: {
            Label(
                isDirectory ? String(localized: "New Folder…", table: "Sidebar")
                    : String(localized: "New File…", table: "Sidebar"),
                systemImage: isDirectory ? "folder.badge.plus" : "doc.badge.plus"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(project.panelContext == nil)
    }

    private var availableActions: [DockAddAction] {
        project.dock.configuration.addActions.filter { action in
            guard let item = action.item else { return true }
            return !group.items.contains(item)
        }
    }

    private func tabStrip(maxWidth: CGFloat? = nil) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(group.items, id: \.self) { item in
                        tab(item)
                            .id(item)
                            .opacity(dragging.position?.item == item ? 0.6 : 1)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: DockTabFrames.self,
                                        value: [item: geometry.frame(in: .global)]
                                    )
                                }
                            }
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                    .onChanged { value in
                                        dragging.update(item, at: value.location, dock: project.dock)
                                        NSCursor.closedHand.set()
                                    }
                                    .onEnded { value in
                                        dragging.update(item, at: value.location, dock: project.dock)
                                        dragging.finish(project: project)
                                    },
                                including: item.tabID != nil && renamingTabID == item.tabID ? .subviews : .all
                            )
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 2)
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: maxWidth != nil, vertical: false)
            .onChange(of: group.selected) { _, selected in
                if let selected { scrollProxy.scrollTo(selected) }
            }
        }
    }

    @ViewBuilder
    private func tab(_ item: DockItem) -> some View {
        if case .tab(let id) = item,
           let paneTab = project.tabs.first(where: { $0.id == id }) {
            PaneTabItem(
                tab: paneTab, isSelected: active == item,
                select: { select(item) },
                close: { project.close(paneTab) },
                renamingTabID: $renamingTabID
            )
            .contextMenu { projectTabMenu(paneTab) }
        } else {
            TabItemChrome(
                systemImage: item.symbol, title: item.label(project: project),
                isSelected: active == item,
                select: { select(item) },
                close: { closeTool(item) }
            )
            .contextMenu {
                Button(String(localized: "Close Panel", table: "Interface")) { closeTool(item) }
            }
        }
    }

    private func select(_ item: DockItem) {
        project.dock.select(item)
        if case .tab(let id) = item { project.selectedTabID = id }
    }

    private func closeTool(_ item: DockItem) { project.dock.removeTool(item) }

    @ViewBuilder
    private var content: some View {
        switch active {
        case .projects:
            ProjectsPanelView(
                manager: manager,
                bottomBarHeight: BottomToolbarLayout.height
            )
        case .files:
            ToolPanelView(manager: manager, git: git, panel: .files)
        case .git:
            ToolPanelView(manager: manager, git: git, panel: .git)
        case .tab(let id):
            if let tab = project.tabs.first(where: { $0.id == id }) {
                PanelContentView(
                    tab: tab,
                    isSelected: project.selectedTabID == id,
                    onFocused: {
                        if project.selectedTabID != id { project.selectedTabID = id }
                    },
                    onNewBrowserTab: { manager.newBrowserTab(initialURL: $0) },
                    onNewFileTab: { manager.openFile($0) }
                )
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
        Button(String(localized: "Rename…", table: "Interface")) { renamingTabID = tab.id }
        if tab.customName != nil {
            Button(String(localized: "Use Automatic Title", table: "Interface")) { tab.customName = nil }
        }
        Divider()
        if case .file(let file) = tab.content {
            Button(String(localized: "Reveal in Finder", table: "Interface")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
            Button(String(localized: "Copy Absolute Path", table: "Interface")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            Divider()
        }
        if case .browser(let browser) = tab.content, !browser.urlString.isEmpty {
            Button(String(localized: "Open in Default Browser", table: "Interface")) {
                browser.openInDefaultBrowser()
            }
            .disabled(browser.shareURL == nil)
            Button(String(localized: "Copy Address", table: "Interface")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(browser.urlString, forType: .string)
            }
            Divider()
        }
        Button(String(localized: "Close", table: "Interface")) { project.close(tab) }
        Button(String(localized: "Close Others", table: "Interface")) { project.closeOthers(tab) }
            .disabled(group.items.compactMap(\.tabID).count < 2)
        Button(String(localized: "Close Tabs to the Right", table: "Interface")) { project.closeToRight(of: tab) }
            .disabled(group.items.compactMap(\.tabID).last == tab.id)
        Divider()
        Button(String(localized: "Close Files", table: "Interface")) { project.closeFiles() }
        Button(String(localized: "Close Diffs", table: "Interface")) { project.closeDiffs() }
        Button(String(localized: "Close All", table: "Interface")) { project.closeAll() }
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

private extension DockItem {
    var tabID: UUID? {
        if case .tab(let id) = self { return id }
        return nil
    }
}
