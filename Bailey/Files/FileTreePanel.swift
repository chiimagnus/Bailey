import AppKit
import SwiftUI

struct FileTreePanel: View {
    let model: FileTreeModel
    let git: GitStatusModel
    let session: TerminalSession?
    let sshHost: String?
    /// Set while the tree follows the terminal's foreground job into another
    /// checkout, so the header says why the root moved.
    let rootBadge: (text: String, description: String)?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PanelHeader(title: model.rootName, subtitle: model.rootPath)
                if let rootBadge {
                    Text(verbatim: rootBadge.text)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.09))
                        )
                        .accessibilityLabel(rootBadge.description)
                }
                // Finder can only reach the local disk; while remote this
                // path names a directory on another machine.
                if sshHost == nil && session?.location.remoteConnection == nil {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: model.rootPath)]
                        )
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .panelFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Reveal in Finder", table: "Sidebar"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            FileTreeScrollView(
                model: model, git: git, session: session,
                sshHost: sshHost, currentFilePath: currentFilePath,
                openFile: openFile, onRename: onRename,
                refreshGitStatus: refreshGitStatus, isCurrentTarget: isCurrentTarget
            )
        }
    }
}

/// The same SwiftUI rows, 22 pt layout and hierarchy lines as the Git tree.
/// The tree stays viewport-sized; only long names scroll horizontally.
private struct FileTreeScrollView: View {
    let model: FileTreeModel
    let git: GitStatusModel
    let session: TerminalSession?
    let sshHost: String?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let onRename: (String, String) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool
    @Environment(\.panelFontScale) private var fontScale

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.items) { item in
                        FileTreeRow(
                            model: model, git: git, item: item,
                            session: session, sshHost: sshHost,
                            currentFilePath: currentFilePath,
                            openFile: openFile,
                            onRename: onRename, refreshGitStatus: refreshGitStatus,
                            isCurrentTarget: isCurrentTarget
                        )
                        .id(item.path)
                    }
                }
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: model.items.first(where: \.isDraft)?.path) { _, path in
                if let path { proxy.scrollTo(path, anchor: .top) }
            }
        }
        .id(model.rootPath)
    }
}

private struct FileTreeRow: View {
    private let themeChanges = Theme.changes
    let model: FileTreeModel
    let git: GitStatusModel
    let item: FileTreeModel.Item
    let session: TerminalSession?
    let sshHost: String?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool

    @State private var editingName = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.panelFontScale) private var fontScale

    private var isRenaming: Bool { model.renamingPath == item.path }

    /// The file open in the active tab, so it reads as selected in the tree.
    private var isCurrent: Bool { !item.isDirectory && item.path == currentFilePath }

    private var gitDecoration: GitStatusModel.FileDecoration? {
        git.fileDecoration(for: item.path, isDirectory: item.isDirectory)
    }

    private var displayRow: TreeDisplayModel.Row {
        var row = item
        row.status = gitDecoration
        row.isExpanded = model.isExpanded(item)
        return row
    }

    /// Whether this row names a file on another machine. A connection that has
    /// dropped still counts: the path is remote either way, and handing it to
    /// Finder would open whatever sits at the same path locally.
    private var isRemote: Bool {
        sshHost != nil || session?.location.remoteConnection != nil
    }

    var body: some View {
        let _ = themeChanges.revision
        if item.isDraft {
            // The transient input keeps the same focused fill but has no hover/menu.
            TreeRowSurface(
                depth: item.depth, scale: fontScale,
                focused: true, hoverEnabled: false
            ) { _, layout in
                draftRow
                    .modifier(layout)
            }
        } else if isRenaming {
            TreeRowSurface(
                depth: item.depth, scale: fontScale, selected: isCurrent
            ) { _, layout in
                renameRow
                    .modifier(layout)
            }
            .contextMenu { rowMenu }
        } else {
            semanticRow
                .contextMenu { rowMenu }
                .onDrag {
                    NSItemProvider(object: URL(fileURLWithPath: item.path) as NSURL)
                }
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        if !item.isDirectory {
            Button(String(localized: "Open", table: "Sidebar")) {
                if isCurrentTarget() { openFile(item.path) }
            }
        }
        // Finder and the default app can only reach the local disk.
        if !isRemote {
            Button(String(localized: "Open in Default App", table: "Sidebar")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            }
            Button(String(localized: "Reveal in Finder", table: "Sidebar")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
        Button(String(localized: "Copy Path", table: "Sidebar")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
        if item.isDirectory {
            Button(String(localized: "cd Here", table: "Sidebar")) {
                guard isCurrentTarget() else { return }
                session?.sendCommand("cd " + shellQuote(item.path) + "\n")
            }
            Divider()
            Button(String(localized: "New File…", table: "Sidebar")) {
                Task {
                    guard isCurrentTarget() else { return }
                    await model.beginNewFile(in: item.path)
                }
            }
            Button(String(localized: "New Folder…", table: "Sidebar")) {
                Task {
                    guard isCurrentTarget() else { return }
                    await model.beginNewFolder(in: item.path)
                }
            }
        }
        Divider()
        Button(String(localized: "Rename", table: "Sidebar")) {
            guard isCurrentTarget() else { return }
            model.beginRename(item)
        }
        if isRemote {
            // No Trash on the remote: Freedesktop semantics vary between
            // distributions and a silently misplaced file is worse than an
            // explicit delete the user confirmed.
            Button(String(localized: "Delete…", table: "Sidebar"), role: .destructive) {
                guard isCurrentTarget(), confirmRemoteDelete(), isCurrentTarget() else { return }
                Task {
                    guard isCurrentTarget() else { return }
                    await model.delete(item)
                    refreshGitStatus()
                }
            }
        } else {
            Button(String(localized: "Move to Trash", table: "Sidebar"), role: .destructive) {
                Task {
                    guard isCurrentTarget() else { return }
                    await model.moveToTrash(item)
                    refreshGitStatus()
                }
            }
        }
    }

    /// Names the full remote path, because there is nothing to undo it with.
    private func confirmRemoteDelete() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Delete “\(item.name)” on \(sshHost ?? session?.location.remoteConnection?.displayName ?? "the remote machine")?", table: "Sidebar",
            comment: "Remote delete confirmation. The placeholders are a file name and a remote machine as user@host."
        )
        alert.informativeText = String(
            localized: "\(item.path) will be deleted. This cannot be undone — a remote file does not go to the Trash.", table: "Sidebar",
            comment: "Remote delete confirmation detail. The placeholder is a full path."
        )
        alert.addButton(withTitle: String(localized: "Delete", table: "Sidebar"))
        alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Commits an inline rename and, when the file actually moved, tells the
    /// app to follow it in any open tabs. Guarded by `isRenaming` so the
    /// commit-on-blur that fires right after Enter/Escape is a no-op.
    private func commitRename() {
        guard isCurrentTarget() else { return }
        guard isRenaming else { return }
        let oldPath = item.path
        let newName = editingName
        Task {
            guard isCurrentTarget() else { return }
            if let newPath = await model.rename(item, to: newName) {
                onRename(oldPath, newPath)
                refreshGitStatus()
            }
        }
    }

    /// Commits the inline new-file/folder input, opening a newly created file.
    /// Guarded so the commit-on-blur after Enter/Escape is a no-op.
    private func commitDraft() {
        guard item.isDraft, model.draft != nil else { return }
        let name = editingName
        Task {
            guard isCurrentTarget() else { return }
            if let created = await model.commitDraft(name: name, isCurrentTarget: isCurrentTarget) {
                if isCurrentTarget() { openFile(created) }
            }
            refreshGitStatus()
        }
    }

    @ViewBuilder
    private var semanticRow: some View {
        if item.isDirectory {
            TreeFolderRow(row: displayRow, scale: fontScale) {
                guard isCurrentTarget() else { return }
                Task {
                    guard isCurrentTarget() else { return }
                    await model.toggle(item)
                }
            }
        } else {
            TreeFileRow(row: displayRow, scale: fontScale, selected: isCurrent,
                        open: { if isCurrentTarget() { openFile(item.path) } }) { _ in EmptyView() }
        }
    }

    private var renameRow: some View {
        HStack(spacing: TreeRowStyle.iconSpacing) {
            leadingGlyphs
            if !item.compactPrefix.isEmpty {
                Text(item.compactPrefix.joined(separator: " / ") + " /")
                    .panelFont(size: TreeRowStyle.fontSize)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            nameField(String(localized: "Name", table: "Sidebar"))
                .onSubmit { commitRename() }
                .onKeyPress(.escape) { model.cancelRename(); return .handled }
                .onChange(of: fieldFocused) {
                    // Commit on blur (Finder-style); unchanged names no-op.
                    if !fieldFocused { commitRename() }
                }
        }
        .onAppear {
            editingName = item.name
            focusField()
        }
    }

    private var draftRow: some View {
        HStack(spacing: TreeRowStyle.iconSpacing) {
            leadingGlyphs
            nameField(item.isDirectory
                ? String(localized: "Folder name", table: "Sidebar")
                : String(localized: "File name", table: "Sidebar"))
                .onSubmit { commitDraft() }
                .onKeyPress(.escape) {
                    Task { await model.cancelDraft() }
                    return .handled
                }
                .onChange(of: fieldFocused) {
                    // Blur commits a typed name, cancels an empty one (VS Code).
                    if !fieldFocused { commitDraft() }
                }
        }
        .onAppear {
            editingName = ""
            focusField()
        }
    }

    private func nameField(_ placeholder: String) -> some View {
        TextField(placeholder, text: $editingName)
            .textFieldStyle(.plain)
            .panelFont(size: 11.5)
            .foregroundStyle(.primary)
            .focused($fieldFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: Theme.background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(nsColor: Theme.accent).opacity(0.7), lineWidth: 1)
            )
    }

    /// Grab focus on the next runloop tick — a context menu is still
    /// dismissing when the input row appears, and a synchronous focus can be
    /// stolen back as it tears down.
    private func focusField() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var leadingGlyphs: some View {
        Group {
            if item.isDirectory {
                TreeFolderIcon(expanded: model.isExpanded(item), scale: fontScale)
            } else {
                MaterialFileIconView(path: item.path, size: TreeRowStyle.iconSize)
                    .frame(width: TreeRowStyle.iconSize)
            }
        }
    }
}

private func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
