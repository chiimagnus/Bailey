import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileTreePanel: View {
    let model: FileTreeModel
    let git: GitStatusModel
    let session: TerminalSession?
    let sshHost: String?
    /// Set while the tree follows the terminal's foreground job into another
    /// checkout, so the header says why the root moved.
    let rootBadge: (text: String, description: String)?
    let currentFilePath: String?
    let openFile: (String, Bool) -> Void
    var isActive = true
    var canFocusKeyboard: () -> Bool = { true }
    let onRename: (_ oldPath: String, _ newPath: String) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool
    let canImportFromFinder: Bool
    let importFromFinder: ([NSItemProvider], String) -> Bool

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
                openFile: openFile, isActive: isActive,
                canFocusKeyboard: canFocusKeyboard, onRename: onRename,
                refreshGitStatus: refreshGitStatus, isCurrentTarget: isCurrentTarget,
                canImportFromFinder: canImportFromFinder,
                importFromFinder: importFromFinder
            )
        }
        .onDrop(of: [UTType.fileURL.identifier], delegate: FileTreeImportDrop(
            directory: model.rootPath,
            enabled: canImportFromFinder && isCurrentTarget(),
            importFromFinder: importFromFinder
        ))
    }
}

/// File Manager has a different drop action from the surrounding workspace:
/// copy into its actual directory, never open an editor or move the source.
private struct FileTreeImportDrop: DropDelegate {
    let directory: String
    let enabled: Bool
    let importFromFinder: ([NSItemProvider], String) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        enabled && !directory.isEmpty && info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        return importFromFinder(info.itemProviders(for: [UTType.fileURL.identifier]), directory)
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
    let openFile: (String, Bool) -> Void
    let isActive: Bool
    let canFocusKeyboard: () -> Bool
    let onRename: (String, String) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool
    let canImportFromFinder: Bool
    let importFromFinder: ([NSItemProvider], String) -> Bool
    @Environment(\.panelFontScale) private var fontScale
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var keyboardOwner = TreeKeyboardOwner()
    @State private var keyboardFocused = false
    @State private var waitingForFirstRow = false

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
                            listFocused: keyboardFocused && isActive && controlActiveState == .key,
                            focusKeyboard: {
                                if canFocusKeyboard() { keyboardOwner.focus() }
                            },
                            onRename: onRename, refreshGitStatus: refreshGitStatus,
                            isCurrentTarget: isCurrentTarget
                        )
                        .id(item.path)
                        .onDrop(of: [UTType.fileURL.identifier], delegate: FileTreeImportDrop(
                            directory: item.isDirectory ? item.path
                                : (item.path as NSString).deletingLastPathComponent,
                            enabled: canImportFromFinder && !item.isDraft && isCurrentTarget(),
                            importFromFinder: importFromFinder
                        ))
                    }
                }
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background {
                TreeKeyboardHost(owner: keyboardOwner, onKeyDown: handleKey,
                                     onFocusChanged: { keyboardFocused = $0 },
                                     onAttachedToWindow: focusSelectedRow)
            }
            .onAppear { if isActive { focusSelectedRow() } }
            .onChange(of: isActive) { _, active in
                if active { focusSelectedRow() }
                else { waitingForFirstRow = false }
            }
            .onChange(of: isCurrentTarget()) { _, current in
                if current { focusSelectedRow() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
                notification in
                if (notification.object as? NSWindow) === keyboardOwner.view?.window, isActive {
                    focusSelectedRow()
                }
            }
            .onChange(of: model.items.first(where: { !$0.isDraft })?.path) { _, _ in
                if waitingForFirstRow { focusSelectedRow() }
            }
            .onChange(of: model.rootPath) { _, _ in keyboardFocused = false }
            .onChange(of: model.renamingPath == nil && model.draft == nil) { _, ready in
                if ready { DispatchQueue.main.async { focusSelectedRow() } }
            }
            .onChange(of: keyboardFocused) { _, focused in
                if focused, let path = model.selectedPath { proxy.scrollTo(path) }
            }
            .onChange(of: model.selectedPath) { _, path in
                if let path { proxy.scrollTo(path) }
            }
            .onChange(of: model.items.first(where: \.isDraft)?.path) { _, path in
                if let path { proxy.scrollTo(path, anchor: .top) }
            }
        }
        .id(model.rootPath)
    }

    private func focusSelectedRow() {
        guard isActive, canFocusKeyboard(), isCurrentTarget(),
              model.renamingPath == nil, model.draft == nil else { return }
        if model.selectedItem == nil {
            let item = model.items.first { !$0.isDraft && $0.path == currentFilePath }
                ?? model.items.first { !$0.isDraft }
            if let item { model.select(item) }
            waitingForFirstRow = item == nil
        } else {
            waitingForFirstRow = false
        }
        guard let window = keyboardOwner.view?.window,
              window.isKeyWindow, NSApp.isActive else { return }
        // A visible command palette or another native text field owns its input.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return }
        keyboardOwner.focus()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard keyboardOwner.view?.window?.firstResponder === keyboardOwner.view,
              isActive, canFocusKeyboard(), isCurrentTarget(),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { return false }
        switch event.keyCode {
        case 125: model.moveSelection(by: 1) // Down
        case 126: model.moveSelection(by: -1) // Up
        case 124: // Right
            guard let row = model.selectedItem, row.isDirectory else { return false }
            if !model.isExpanded(row) { Task { await model.toggle(row) } }
            else if let child = model.nextVisibleChild(of: row) { model.select(child) }
        case 123: // Left
            guard let row = model.selectedItem else { return false }
            if row.isDirectory, model.isExpanded(row) {
                Task { await model.toggle(row) }
            } else if let parent = model.items
                .filter({ $0.isDirectory && row.path.hasPrefix($0.path + "/") })
                .max(by: { $0.path.count < $1.path.count }) {
                model.select(parent)
            }
        case 36, 76: // Return and keypad Enter
            guard let row = model.selectedItem else { return false }
            if row.isDirectory { Task { await model.toggle(row) } }
            else { openFile(row.path, true) }
        case 49: // Space previews without moving keyboard focus
            guard let row = model.selectedItem else { return false }
            if row.isDirectory { Task { await model.toggle(row) } }
            else { openFile(row.path, false) }
        case 53: model.clearSelection() // Escape
        default: return false
        }
        return true
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
    let openFile: (String, Bool) -> Void
    let listFocused: Bool
    let focusKeyboard: () -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool

    @State private var editingName = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.panelFontScale) private var fontScale

    private var isRenaming: Bool { model.renamingPath == item.path }
    private var hasKeyboardCursor: Bool {
        model.selectedPath == item.path && listFocused
    }

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
            // Draft editing keeps its existing subtle fill independently of keyboard focus.
            TreeRowSurface(depth: item.depth, scale: fontScale, hoverEnabled: false) { _, layout in
                draftRow
                    .modifier(layout)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.05)))
            }
        } else if isRenaming {
            TreeRowSurface(
                depth: item.depth, scale: fontScale, selected: isCurrent
            ) { _, layout in
                renameRow
                    .modifier(layout)
            }
            .contextMenu { rowMenu }
        } else if isRemote {
            // A remote POSIX path is not a Mac file URL, even when the same
            // spelling happens to exist on disk here. Keep Copy Path only.
            semanticRow.contextMenu { rowMenu }
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
                if isCurrentTarget() { openFile(item.path, true) }
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
                if isCurrentTarget() { openFile(created, true) }
            }
            refreshGitStatus()
        }
    }

    @ViewBuilder
    private var semanticRow: some View {
        if item.isDirectory {
            TreeFolderRow(row: displayRow, scale: fontScale,
                          focusRing: hasKeyboardCursor) {
                guard isCurrentTarget() else { return }
                model.select(item)
                focusKeyboard()
                Task {
                    guard isCurrentTarget() else { return }
                    await model.toggle(item)
                }
            }
        } else {
            TreeFileRow(
                row: displayRow, scale: fontScale, selected: isCurrent,
                focusRing: hasKeyboardCursor,
                open: {
                    guard isCurrentTarget() else { return }
                    model.select(item)
                    openFile(item.path, false)
                    focusKeyboard()
                },
                activate: {
                    guard isCurrentTarget() else { return }
                    openFile(item.path, true)
                }
            ) { _ in EmptyView() }
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
