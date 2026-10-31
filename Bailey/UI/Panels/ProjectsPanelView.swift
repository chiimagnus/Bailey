import AppKit
import SwiftUI

/// Movable project-list panel; its workspace tab is the normal dock tab.
struct ProjectsPanelView: View {
    let manager: WorkspaceWindowModel
    let bottomBarHeight: CGFloat
    private let settings = AppSettings.shared
    private let themeChanges = Theme.changes
    @Environment(\.openSettings) private var openSettings
    @State private var showingProjectPicker = false
    @State private var draggedProjectID: UUID?
    @State private var contextProjectID: UUID?
    @State private var projectFrames: [UUID: CGRect] = [:]
    @State private var keyboardOwner = TreeKeyboardOwner()
    @State private var keyboardFocused = false
    @State private var cursorProjectID: UUID?
    @Environment(\.controlActiveState) private var controlActiveState

    private var isListActive: Bool {
        guard let project = manager.selectedProject,
              let group = project.dock.group(containing: .projects) else { return false }
        return project.dock.activeGroupID == group.id && group.selected == .projects
            && manager.attachedWindow?.isKeyWindow == true && NSApp.isActive
            && controlActiveState == .key && !manager.isCommandPaletteVisible
            && manager.attachedWindow?.attachedSheet == nil
    }

    var body: some View {
        let _ = themeChanges.revision
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(manager.projects.enumerated()), id: \.element.id) { index, project in
                        SidebarProjectRow(
                            project: project,
                            index: index,
                            isSelected: project.id == manager.selectedProjectID,
                            listActive: isListActive,
                            focusRing: keyboardFocused && isListActive
                                && cursorProjectID == project.id,
                            isContextTarget: contextProjectID == project.id,
                            onContextClick: { contextProjectID = project.id },
                            onMenuClosed: {
                                if contextProjectID == project.id { contextProjectID = nil }
                            },
                            select: {
                                contextProjectID = nil
                                cursorProjectID = project.id
                                manager.selectedProjectID = project.id
                                keyboardOwner.focus()
                            },
                            close: { manager.close(project) },
                            isDragging: draggedProjectID == project.id,
                            onDrag: { updateProjectDrag(source: project.id, location: $0) },
                            onDragEnded: endProjectDrag,
                            fontSize: settings.panelFontSize
                        )
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ProjectFramePreferenceKey.self,
                                    value: [project.id: proxy.frame(in: .global)]
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .background {
                TreeKeyboardHost(
                    owner: keyboardOwner, onKeyDown: handleProjectKey,
                    onFocusChanged: { keyboardFocused = $0 },
                    onAttachedToWindow: focusProjectList
                )
            }
            .onAppear { focusProjectList() }
            .onChange(of: isListActive) { _, active in
                if active { focusProjectList() }
            }

            HStack(spacing: 2) {
                ChromeIconButton(
                    systemImage: "plus",
                    tooltip: String(localized: "Add projects or SSH files", table: "Sidebar")
                ) { showingProjectPicker.toggle() }
                .accessibilityIdentifier("bailey.projects.addPicker")
                .popover(isPresented: $showingProjectPicker, arrowEdge: .top) {
                    VStack(spacing: 2) {
                        let addTitle = String(localized: "Add Projects…", table: "Sidebar")
                        Button {
                            showingProjectPicker = false
                            manager.chooseFolders()
                        } label: {
                            HStack {
                                Text(addTitle)
                                Spacer(minLength: 0)
                                Text(verbatim: "⇧⌘A").foregroundStyle(.secondary)
                            }
                            .padding(7)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel(addTitle)
                        Button {
                            showingProjectPicker = false
                            manager.chooseSSHItems()
                        } label: {
                            Text(String(localized: "Add SSH Files or Projects…", table: "Sidebar"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(7)
                                .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
                Spacer()
                ChromeIconButton(
                    systemImage: "exclamationmark.bubble",
                    tooltip: String(localized: "Send Feedback", table: "Sidebar"),
                    tooltipEdge: .above,
                    tooltipAlignment: .trailing
                ) {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/chiimagnus/Bailey/issues/new")!
                    )
                }
                ChromeIconButton(
                    systemImage: "gearshape",
                    tooltip: String(localized: "Settings (⌘,)", table: "Sidebar"),
                    tooltipEdge: .above,
                    tooltipAlignment: .trailing
                ) { openSettings() }
            }
            .padding(.horizontal, 8)
            .frame(height: bottomBarHeight)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(nsColor: Theme.divider))
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(ProjectFramePreferenceKey.self) { projectFrames = $0 }
        .onChange(of: manager.selectedProjectID) { _, id in
            contextProjectID = nil
            if keyboardFocused { cursorProjectID = id }
        }
        .onChange(of: manager.projects.map(\.id)) { _, ids in
            let valid = Set(ids)
            if let cursorProjectID, !valid.contains(cursorProjectID) {
                self.cursorProjectID = manager.selectedProjectID.flatMap {
                    valid.contains($0) ? $0 : nil
                } ?? ids.first
            }
            if let contextProjectID, !valid.contains(contextProjectID) {
                self.contextProjectID = nil
            }
            if let draggedProjectID, !valid.contains(draggedProjectID) {
                endProjectDrag()
            }
            projectFrames = projectFrames.filter { valid.contains($0.key) }
        }
        .onDisappear {
            if draggedProjectID != nil { endProjectDrag() }
        }
    }

    private func focusProjectList() {
        guard isListActive else { return }
        if cursorProjectID == nil { cursorProjectID = manager.selectedProjectID }
        keyboardOwner.focus()
    }

    private func handleProjectKey(_ event: NSEvent) -> Bool {
        guard keyboardOwner.view?.window?.firstResponder === keyboardOwner.view,
              isListActive, !manager.projects.isEmpty,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        else { return false }
        let projects = manager.projects
        let index = cursorProjectID.flatMap { id in projects.firstIndex { $0.id == id } }
            ?? projects.firstIndex { $0.id == manager.selectedProjectID } ?? 0
        switch event.keyCode {
        case 125, 126: // Down / Up
            let offset = event.keyCode == 125 ? 1 : -1
            cursorProjectID = projects[max(0, min(projects.count - 1, index + offset))].id
        case 36, 49, 76: // Return / Space
            let targetID = projects[index].id
            cursorProjectID = targetID
            manager.selectedProjectID = targetID
        case 53: break // Escape leaves the keyboard cursor in place
        default: return false
        }
        return true
    }

    private func updateProjectDrag(source: UUID, location: CGPoint) {
        guard manager.projects.contains(where: { $0.id == source }) else {
            endProjectDrag()
            return
        }
        draggedProjectID = source
        NSCursor.closedHand.set()
        guard let target = projectFrames.first(where: {
            $0.key != source && $0.value.contains(location)
        })?.key else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            manager.moveProject(source, to: target)
        }
    }

    private func endProjectDrag() {
        draggedProjectID = nil
        NSCursor.arrow.set()
    }
}

private struct ProjectFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SidebarProjectRow: View {
    let project: Project
    let index: Int
    let isSelected: Bool
    let listActive: Bool
    let focusRing: Bool
    let isContextTarget: Bool
    let onContextClick: () -> Void
    let onMenuClosed: () -> Void
    let select: () -> Void
    let close: () -> Void
    let isDragging: Bool
    let onDrag: (CGPoint) -> Void
    let onDragEnded: () -> Void
    let fontSize: Double

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            rowContent
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bailey.project.row")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .highPriorityGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDrag($0.location) }
                .onEnded { _ in onDragEnded() }
        )
        .opacity(isDragging ? 0.65 : 1)
        .modifier(RowHighlightStyle(
            isSelected: isSelected, listActive: listActive,
            focusRing: focusRing, contextRing: isContextTarget,
            hovering: isHovering, cornerRadius: 6
        ))
        .onHover { isHovering = $0 }
        .background {
            ContextMenuClickTarget(
                onContextClick: onContextClick,
                onMenuClosed: onMenuClosed
            )
        }
        .contextMenu {
            Button(String(localized: "Close Project", table: "Sidebar")) {
                close()
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: project.sshHost == nil ? "folder" : "network")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color(nsColor: Theme.accent) : .secondary)
                .frame(width: max(14, fontSize))

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: projectTitleFontSize))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                subtitle
            }

            Spacer(minLength: 0)

            // Fixed trailing slot: close and the ⌘1–9 hint share the same
            // width so hover does not reflow the row.
            ZStack(alignment: .trailing) {
                if isHovering {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if index < 9 {
                    Text(verbatim: "⌘\(index + 1)")
                        .font(.system(size: supportingFontSize))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 24, height: 16, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var subtitle: some View {
        if let host = project.sshHost {
            Text(String(localized: "SSH · \(host)", table: "Sidebar"))
                .font(.system(size: supportingFontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if let directory = project.customDirectory {
            Text(directory)
                .font(.system(size: supportingFontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private var supportingFontSize: Double {
        10 * panelFontScale
    }

    /// Match the file-tree label's designed 11.5 pt size while following the
    /// shared panel font-size setting.
    private var projectTitleFontSize: Double {
        11.5 * panelFontScale
    }

    private var panelFontScale: Double {
        fontSize / AppSettings.defaultPanelFontSize
    }
}
