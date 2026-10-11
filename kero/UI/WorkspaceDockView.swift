import AppKit
import Combine
import SwiftUI

/// Window-wide docking gesture. One hit-tested destination and one preview:
/// the pointer's proximity to a pane edge determines the split, while the
/// title strip and the interior merge into the existing tab group.
@MainActor
final class DockTabDragCoordinator: ObservableObject {
    struct Position {
        let item: DockItem
        let location: CGPoint
        let destination: UUID?
        let edge: DockEdge?
        let index: Int?
    }

    @Published private(set) var position: Position?
    private var groups: [UUID: CGRect] = [:]
    private var tabs: [DockItem: CGRect] = [:]

    func cancel() {
        position = nil
        groups = [:]
        tabs = [:]
    }

    func setFrames(groups: [UUID: CGRect]) { self.groups = groups }
    func setFrames(tabs: [DockItem: CGRect]) { self.tabs = tabs }

    func update(_ item: DockItem, at location: CGPoint, dock: DockWorkspaceModel) {
        let hit = groups.first { $0.value.contains(location) }
        var edge: DockEdge?
        var insertIndex: Int?
        if let hit, let target = dock.root.group(id: hit.key) {
            let frame = hit.value
            edge = DockDropHitTest.edge(at: location, in: frame)
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

    func finish(project: Project, manager: TerminalManager) {
        defer {
            position = nil
            NSCursor.arrow.set()
        }
        guard let position, let destination = position.destination else { return }
        let original = project.dock.group(containing: position.item)
        guard project.dock.move(
            position.item, into: destination,
            edge: position.edge, index: position.index
        ) else { return }
        if case .tab(let id) = position.item {
            project.selectedTabID = id
        }
        // A sidebar whose last tab was moved away collapses automatically;
        // it remains in the saved tree and the original button reopens it.
        if let original, original.region == .left,
           project.dock.group(region: .left)?.items.isEmpty == true {
            manager.isLeftSidebarVisible = false
        }
        if let original, original.region == .right,
           project.dock.group(region: .right)?.items.isEmpty == true {
            manager.isPanelVisible = false
        }
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
    @ObservedObject var manager: TerminalManager
    @ObservedObject var git: GitStatusModel
    @StateObject private var dragging = DockTabDragCoordinator()
    @AppStorage("leftSidebarWidth") private var legacyLeftWidth: Double = 220
    @AppStorage("rightSidebarWidth") private var legacyRightWidth: Double = 240

    var body: some View {
        GeometryReader { rootGeometry in
            if let project = manager.selectedProject,
               let layout = project.dock.root.visible(
                left: manager.isLeftSidebarVisible,
                right: manager.isPanelVisible
               ) {
                DockTreeView(
                    node: layout, project: project, manager: manager,
                    git: git, dragging: dragging
                )
                .frame(width: rootGeometry.size.width, height: rootGeometry.size.height)
                .background(Color(nsColor: Theme.background))
                .onAppear {
                    project.dock.applyExistingSidebarWidths(
                        windowWidth: rootGeometry.size.width,
                        left: legacyLeftWidth, right: legacyRightWidth
                    )
                }
                .onChange(of: rootGeometry.size.width) {
                    project.dock.applyExistingSidebarWidths(
                        windowWidth: rootGeometry.size.width,
                        left: legacyLeftWidth, right: legacyRightWidth
                    )
                }
                .onPreferenceChange(DockGroupFrames.self) {
                    dragging.setFrames(groups: $0)
                }
                .onPreferenceChange(DockTabFrames.self) {
                    dragging.setFrames(tabs: $0)
                }
                .onChange(of: manager.selectedProjectID) { dragging.cancel() }
                .onChange(of: project.selectedTabID) {
                    guard let id = project.selectedTabID,
                          let group = project.dock.group(containing: .tab(id)) else { return }
                    if group.region == .left { manager.isLeftSidebarVisible = true }
                    if group.region == .right { manager.isPanelVisible = true }
                }
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
    }
}

extension DockItem {
    var symbol: String {
        switch self {
        case .projects: "folder"
        case .info: "info.circle"
        case .files: "folder"
        case .git: "arrow.triangle.branch"
        case .tab: "terminal"
        }
    }

    func label(project: Project) -> String {
        switch self {
        case .projects: String(localized: "Projects", table: "Interface")
        case .info: String(localized: "Info", table: "Sidebar")
        case .files: String(localized: "Files", table: "Sidebar")
        case .git: "Git"
        case .tab(let id): project.tabs.first { $0.id == id }?.displayTitle ?? String(localized: "Tab", table: "Workspace")
        }
    }
}

/// The only recursive window layout. The inner PaneLayoutView remains
/// responsible for splits *inside* a terminal/editor tab.
private struct DockTreeView: View {
    let node: DockNode
    @ObservedObject var project: Project
    @ObservedObject var manager: TerminalManager
    @ObservedObject var git: GitStatusModel
    @ObservedObject var dragging: DockTabDragCoordinator

    @State private var liveFraction: Double?

    var body: some View {
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
                let available = max(0, (horizontal ? size.width : size.height) - 4)
                let firstLength = available * fraction
                let secondLength = max(0, available - firstLength)
                Group {
                    if horizontal {
                        HStack(spacing: 0) {
                            child(split.first)
                                .frame(width: firstLength, height: size.height)
                            divider(split, available: available)
                                .frame(width: 4, height: size.height)
                            child(split.second)
                                .frame(width: secondLength, height: size.height)
                        }
                    } else {
                        VStack(spacing: 0) {
                            child(split.first)
                                .frame(width: size.width, height: firstLength)
                            divider(split, available: available)
                                .frame(width: size.width, height: 4)
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
        Rectangle()
            .fill(Color(nsColor: Theme.divider))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (split.axis == .horizontal
                     ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .onTapGesture(count: 2) { project.dock.resize(split.id, to: 0.5) }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard available > 0 else { return }
                    let delta = split.axis == .horizontal
                        ? value.translation.width : value.translation.height
                    // Narrow panes may shrink only as far as the available
                    // window permits, keeping their tab strips reachable.
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

private struct DockTabGroupView: View {
    let group: DockGroup
    @ObservedObject var project: Project
    @ObservedObject var manager: TerminalManager
    @ObservedObject var git: GitStatusModel
    @ObservedObject var dragging: DockTabDragCoordinator
    @ObservedObject private var settings = AppSettings.shared
    @State private var renamingTabID: UUID?

    private var active: DockItem? { group.selected ?? group.items.first }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 38)
                .background(Color(nsColor: group.region == .left || group.region == .right
                    ? Theme.sidebar : Theme.background))
                .overlay(alignment: .bottom) {
                    Color(nsColor: Theme.divider).frame(height: 1)
                }
                .zIndex(1)
            ZStack {
                content
                dropPreview
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if group.region == .main,
               settings.toolbarVisibility != .hide,
               (git.isRepo || settings.toolbarVisibility == .always) {
                BottomToolbarView(
                    model: git,
                    height: BottomToolbarLayout.height,
                    toggleGitPanel: { manager.togglePanel(.git) },
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
        HStack(spacing: 4) {
            if group.region == .left {
                WindowDragArea().frame(width: 76)
                tabStrip
                if manager.isFPSCounterVisible { FPSBadge() }
                ChromeIconButton(
                    systemImage: "sidebar.left",
                    tooltip: String(localized: "Toggle Left Sidebar (⌘B)", table: "Interface")
                ) { manager.toggleLeftSidebar() }
            } else {
                if group.region == .main && !manager.isLeftSidebarVisible {
                    ChromeIconButton(
                        systemImage: "sidebar.left",
                        tooltip: String(localized: "Toggle Left Sidebar (⌘B)", table: "Interface")
                    ) { manager.toggleLeftSidebar() }
                    .padding(.leading, 76)
                }
                tabStrip
                if group.region == .main {
                    ChromeIconButton(
                        systemImage: "plus",
                        tooltip: String(localized: "New Session (⌘T)", table: "Interface"),
                        font: .system(size: 10, weight: .semibold),
                        iconSize: 14
                    ) {
                        project.newSession()
                        if let id = project.selectedTabID {
                            project.dock.place(.tab(id), in: .main)
                        }
                    }
                    WindowDragArea().frame(minWidth: 100, maxWidth: .infinity)
                    if manager.isPaneZoomed {
                        ChromeIconButton(
                            systemImage: "arrow.down.forward.and.arrow.up.backward",
                            tooltip: String(localized: "Exit Pane Zoom (⇧⌘↩)", table: "Interface")
                        ) { manager.togglePaneZoom() }
                    }
                    ChromeIconButton(
                        systemImage: "sidebar.right",
                        tooltip: String(localized: "Toggle Right Sidebar (⇧⌘B)", table: "Interface")
                    ) { manager.toggleSidebar() }
                } else {
                    Spacer(minLength: 0)
                    if group.region == .right {
                        ChromeIconButton(
                            systemImage: "sidebar.right",
                            tooltip: String(localized: "Toggle Right Sidebar (⇧⌘B)", table: "Interface")
                        ) { manager.toggleSidebar() }
                    }
                }
            }
        }
        .padding(.trailing, 8)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(group.items, id: \.self) { item in
                    tab(item)
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
                                    dragging.finish(project: project, manager: manager)
                                },
                            including: item.tabID != nil && renamingTabID == item.tabID ? .subviews : .all
                        )
                }
            }
            .padding(.leading, group.region == .main ? 8 : 4)
            .padding(.trailing, 2)
        }
        .fixedSize(horizontal: false, vertical: false)
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
                Button(String(localized: "Move to Left Sidebar", table: "Interface")) { project.dock.place(item, in: .left); manager.isLeftSidebarVisible = true }
                Button(String(localized: "Move to Right Sidebar", table: "Interface")) { project.dock.place(item, in: .right); manager.isPanelVisible = true }
                Divider()
                Button(String(localized: "Close Panel", table: "Interface")) { closeTool(item) }
            }
        }
    }

    private func select(_ item: DockItem) {
        project.dock.select(item)
        if case .tab(let id) = item { project.selectedTabID = id }
        switch item {
        case .info: manager.panelTab = .info
        case .files: manager.panelTab = .files
        case .git: manager.panelTab = .git
        default: break
        }
    }

    private func closeTool(_ item: DockItem) {
        guard case .tab = item else {
            project.dock.removeTool(item)
            if group.region == .left,
               project.dock.group(region: .left)?.items.isEmpty == true {
                manager.isLeftSidebarVisible = false
            }
            if group.region == .right,
               project.dock.group(region: .right)?.items.isEmpty == true {
                manager.isPanelVisible = false
            }
            return
        }
    }

    @ViewBuilder
    private var content: some View {
        switch active {
        case .projects:
            SidebarView(
                manager: manager,
                bottomBarHeight: BottomToolbarLayout.height,
                docked: true
            )
        case .info:
            RightSidebarView(manager: manager, git: git, panel: .info)
        case .files:
            RightSidebarView(manager: manager, git: git, panel: .files)
        case .git:
            RightSidebarView(manager: manager, git: git, panel: .git)
        case .tab(let id):
            if let tab = project.tabs.first(where: { $0.id == id }) {
                if let diff = tab.diffs.first, tab.allPanes.count == 1 {
                    DiffViewerView(diff: diff, isSelected: true)
                } else {
                    PaneLayoutView(
                        tab: tab,
                        isWorkspaceTabSelected: project.selectedTabID == id,
                        onFocused: {
                            if project.selectedTabID != id { project.selectedTabID = id }
                        },
                        onSplit: {
                            project.selectedTabID = id
                            manager.split(toward: $0)
                        },
                        onNewBrowserTab: { manager.newBrowserTab(initialURL: $0) },
                        onNewBrowserPane: { manager.newBrowserPane(initialURL: $0) },
                        onNewFileTab: { manager.openFile($0) },
                        onNewFilePane: { manager.openFileToSide($0) }
                    )
                }
            }
        case nil:
            emptyGroup
        }
    }

    private var emptyGroup: some View {
        VStack(spacing: 10) {
            if group.region == .main {
                Text(String(localized: "No Open Tabs", table: "Interface")).foregroundStyle(.secondary)
                Button(String(localized: "New Session", table: "Interface")) { project.newSession() }
            } else {
                Text(String(localized: "Drag a Tab Here or Add a Panel", table: "Interface")).foregroundStyle(.secondary)
                Menu(String(localized: "Add Panel", table: "Interface")) {
                    Button(String(localized: "Projects", table: "Interface")) { add(.projects) }
                    Button(String(localized: "Info", table: "Sidebar")) { add(.info) }
                    Button(String(localized: "Files", table: "Sidebar")) { add(.files) }
                    Button(String(localized: "Git", table: "Sidebar")) { add(.git) }
                }
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Theme.background))
    }

    private func add(_ item: DockItem) {
        if let original = project.dock.group(containing: item), original.region == .left,
           original.items.count == 1 { manager.isLeftSidebarVisible = false }
        if let original = project.dock.group(containing: item), original.region == .right,
           original.items.count == 1 { manager.isPanelVisible = false }
        _ = project.dock.move(item, into: group.id)
        // When a tool was explicitly closed, it has no owner yet.
        if project.dock.group(containing: item) == nil {
            project.dock.place(item, in: group.region)
        }
    }

    @ViewBuilder
    private func projectTabMenu(_ tab: PaneTab) -> some View {
        Button(String(localized: "Rename…", table: "Interface")) { renamingTabID = tab.id }
        if tab.customName != nil {
            Button(String(localized: "Use Automatic Title", table: "Interface")) { tab.customName = nil }
        }
        Divider()
        if case .file(let file) = tab.focusedContent {
            Button(String(localized: "Reveal in Finder", table: "Interface")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
            Button(String(localized: "Copy Absolute Path", table: "Interface")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            Divider()
        }
        if case .browser(let browser) = tab.focusedContent, !browser.urlString.isEmpty {
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
        if let drag = dragging.position, drag.destination == group.id {
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
