//
//  ProjectsPanelView.swift
//  kero
//

import AppKit
import SwiftUI

/// Movable project-list panel; its workspace tab is the normal dock tab.
struct ProjectsPanelView: View {
    let manager: TerminalManager
    let bottomBarHeight: CGFloat
    private let settings = AppSettings.shared
    private let themeChanges = Theme.changes
    @Environment(\.openSettings) private var openSettings
    @State private var showingProjectPicker = false
    @State private var draggedProjectID: UUID?
    @State private var projectFrames: [UUID: CGRect] = [:]

    var body: some View {
        let _ = themeChanges.revision
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(manager.projects.enumerated()), id: \.element.id) { index, project in
                        SidebarProjectRow(
                            project: project,
                            owningWindow: { manager.attachedWindow },
                            index: index,
                            isSelected: project.id == manager.selectedProjectID,
                            select: { manager.selectedProjectID = project.id },
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
                    tooltip: String(localized: "Add files, folders, or SSH paths", table: "Sidebar")
                ) { showingProjectPicker.toggle() }
                .popover(isPresented: $showingProjectPicker, arrowEdge: .top) {
                    VStack(spacing: 2) {
                        Button(String(localized: "Add Files or Folders…", table: "Sidebar")) {
                            showingProjectPicker = false
                            manager.chooseLocalItems()
                        }
                        Button(String(localized: "Add SSH Files or Folders…", table: "Sidebar")) {
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
                        URL(string: "https://github.com/chiimagnus/kero/issues/new")!
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
    let project: Project
    let owningWindow: () -> NSWindow?
    private let themeChanges = Theme.changes
    let index: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let isDragging: Bool
    let onDrag: (CGPoint) -> Void
    let onDragEnded: () -> Void
    let fontSize: Double

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let _ = themeChanges.revision
        Group {
            if isRenaming {
                rowContent
            } else {
                Button(action: select) {
                    rowContent
                }
                .buttonStyle(.plain)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { onDrag($0.location) }
                        .onEnded { _ in onDragEnded() }
                )
            }
        }
        .opacity(isDragging ? 0.65 : 1)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(String(localized: "Rename…", table: "Sidebar")) {
                beginRename()
            }
            if project.customName != nil {
                Button(String(localized: "Use Automatic Title", table: "Sidebar")) {
                    project.customName = nil
                }
            }
            Divider()
            if project.sshHost == nil {
                Button(String(localized: "Set Project Directory…", table: "Sidebar")) {
                    pickProjectDirectory()
                }
                if project.customDirectory != nil {
                    Button(String(localized: "Use Automatic Directory", table: "Sidebar")) {
                        project.customDirectory = nil
                        project.pinnedFile = nil
                    }
                }
            }
            Divider()
            Button(String(localized: "Close Project", table: "Sidebar")) {
                close()
            }
        }
    }

    /// Lets the user pin the project's directory — the root the file tree
    /// and git panels anchor to instead of the automatic closest-git-repo.
    private func pickProjectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", table: "Sidebar", comment: "Button in the project directory picker.")
        panel.message = String(
            localized: "Choose the directory for “\(project.name)”.", table: "Sidebar",
            comment: "Message in the project directory picker. The placeholder is a project name."
        )
        if let current = project.customDirectory
            ?? project.selectedSession?.currentDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            project.customDirectory = url.path
        }
        if let window = owningWindow() {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: project.sshHost != nil ? "network"
                : project.pinnedFile != nil ? "doc.text" : "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color(nsColor: Theme.accent) : .secondary)
                .frame(width: max(14, fontSize), alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: projectTitleFontSize, weight: .medium))
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: renameFocused) {
                            if !renameFocused, isRenaming {
                                commitRename()
                            }
                        }
                } else {
                    Text(project.name)
                        .font(.system(size: projectTitleFontSize))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                }
                subtitle
            }

            Spacer(minLength: 0)

            // Fixed trailing slot: close and the ⌘1–9 hint share the same
            // width so hover does not reflow the row. Continuous title
            // updates from the terminal re-render the strip; without a
            // stable slot that reflow reads as jitter under the pointer.
            ZStack(alignment: .trailing) {
                if isHovering, !isRenaming {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if index < 9, !isRenaming {
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

    private func beginRename() {
        renameDraft = project.name
        isRenaming = true
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func commitRename() {
        project.customName = Project.normalizedCustomName(renameDraft)
        isRenaming = false
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
        } else if project.sessions.count > 1 {
            Text(String(localized: "\(project.sessions.count) sessions", table: "Sidebar"))
                .font(.system(size: supportingFontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if let session = project.selectedSession {
            SessionDirectoryLabel(session: session, fontSize: supportingFontSize)
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

/// Small subtitle observing the session's live working directory.
private struct SessionDirectoryLabel: View {
    let session: TerminalSession
    let fontSize: Double

    var body: some View {
        if let dir = session.directoryLabel {
            Text(dir)
                .font(.system(size: fontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}
