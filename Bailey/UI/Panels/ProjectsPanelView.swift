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
                            isContextTarget: contextProjectID == project.id,
                            onContextClick: { contextProjectID = project.id },
                            select: {
                                contextProjectID = nil
                                manager.selectedProjectID = project.id
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

            HStack(spacing: 2) {
                ChromeIconButton(
                    systemImage: "plus",
                    tooltip: String(localized: "Add projects or SSH files", table: "Sidebar")
                ) { showingProjectPicker.toggle() }
                .popover(isPresented: $showingProjectPicker, arrowEdge: .top) {
                    VStack(spacing: 2) {
                        let addTitle = String(localized: "Add Projects…", table: "Sidebar")
                        Button {
                            showingProjectPicker = false
                            manager.chooseFolders()
                        } label: {
                            HStack(spacing: 8) {
                                Text(addTitle)
                                Spacer(minLength: 0)
                                Text(verbatim: "⇧⌘A").foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel(addTitle)
                        Button(String(localized: "Add SSH Files or Projects…", table: "Sidebar")) {
                            showingProjectPicker = false
                            manager.chooseSSHItems()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .frame(width: 220, alignment: .leading)
                }
                .frame(width: 24, height: 24)
                Spacer()
                SidebarFooterButton(
                    systemImage: "exclamationmark.bubble",
                    tooltip: String(localized: "Send Feedback", table: "Sidebar"),
                    tooltipAlignment: .trailing
                ) {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/chiimagnus/Bailey/issues/new")!
                    )
                }
                SidebarFooterButton(
                    systemImage: "gearshape",
                    tooltip: String(localized: "Settings (⌘,)", table: "Sidebar"),
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
        .background(Color(nsColor: Theme.background))
        .onPreferenceChange(ProjectFramePreferenceKey.self) { projectFrames = $0 }
        .onChange(of: manager.selectedProjectID) { _, _ in contextProjectID = nil }
    }

    private func updateProjectDrag(source: UUID, location: CGPoint) {
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

private struct SidebarFooterButton: View {
    let systemImage: String
    let tooltip: String
    /// Buttons near the sidebar's right edge anchor `.trailing` so the label
    /// grows inward instead of off-panel.
    var tooltipAlignment: HorizontalAlignment = .leading
    let action: () -> Void

    var body: some View {
        ChromeIconButton(
            systemImage: systemImage,
            tooltip: tooltip,
            tooltipEdge: .above,
            tooltipAlignment: tooltipAlignment,
            action: action
        )
    }
}

private struct ProjectFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SidebarProjectRow: View {
    private let themeChanges = Theme.changes
    let project: Project
    let index: Int
    let isSelected: Bool
    let isContextTarget: Bool
    let onContextClick: () -> Void
    let select: () -> Void
    let close: () -> Void
    let isDragging: Bool
    let onDrag: (CGPoint) -> Void
    let onDragEnded: () -> Void
    let fontSize: Double

    @State private var isHovering = false

    var body: some View {
        let _ = themeChanges.revision
        Button(action: select) {
            rowContent
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bailey.project.row")
        .highPriorityGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDrag($0.location) }
                .onEnded { _ in onDragEnded() }
        )
        .opacity(isDragging ? 0.65 : 1)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isContextTarget ? Color(nsColor: Theme.accent) : .clear,
                              lineWidth: 1)
                .allowsHitTesting(false)
        }
        .background {
            TreeContextClickTarget(onContextClick: onContextClick)
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
                .frame(width: max(14, fontSize), alignment: .center)

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
