import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FileTreeCommand {
    case copy([String], cut: Bool)
    case paste(into: String)
    case delete([String])
    case drop([String], into: String, copy: Bool)
}

@MainActor
enum FileTreeClipboard {
    struct Record: Codable, Equatable {
        let token: UUID
        let project: UUID
        let identity: String
        let root: String
        let connectionRevision: UInt64?
        let paths: [String]
        let cut: Bool
    }

    static let type = NSPasteboard.PasteboardType("com.chiimagnus.bailey.files.transfer")

    @discardableResult
    static func write(_ record: Record, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        pasteboard.declareTypes([type, .string], owner: nil)
        guard pasteboard.setData(data, forType: type) else { return false }
        pasteboard.setString(record.paths.joined(separator: "\n"), forType: .string)
        return true
    }

    static func read(from pasteboard: NSPasteboard = .general) -> Record? {
        guard let data = pasteboard.data(forType: type) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
}

@MainActor
enum FileTreeDrag {
    static let type = "com.chiimagnus.bailey.files.internal-drag"

    struct Record: Codable {
        let source: FileTreeClipboard.Record
        let window: String
        let nonce: UUID
    }
}

struct FileTreePanel: View {
    let model: FileTreeModel
    let git: GitStatusModel
    let sshHost: String?
    let currentFilePath: String?
    let openFile: (String, Bool) -> Void
    var isActive = true
    var canFocusKeyboard: () -> Bool = { true }
    let renameFile: (FileTreeModel.Item, String) async -> String?
    let onCommand: (FileTreeCommand) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool
    let canPasteFiles: () -> Bool
    let canImportFromFinder: Bool
    let importFromFinder: ([NSItemProvider], String) -> Bool
    var makeDragProvider: (FileTreeModel.Item) -> NSItemProvider = { _ in NSItemProvider() }
    var receiveInternalDrop: (NSItemProvider, String, Bool) -> Bool = { _, _, _ in false }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PanelHeader(title: model.rootName, subtitle: model.rootPath)
                // Finder can only reach the local disk; while remote this
                // path names a directory on another machine.
                if sshHost == nil {
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
                Menu {
                    Toggle(String(localized: "Show Excluded Files", table: "Sidebar"),
                           isOn: Binding(
                            get: { model.showExcluded },
                            set: { visible in
                                if isCurrentTarget() { Task { await model.setShowExcluded(visible) } }
                            }
                           ))
                } label: {
                    Image(systemName: "ellipsis")
                        .panelFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("bailey.files.showExcludedMenu")
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            FileTreeScrollView(
                model: model, git: git,
                sshHost: sshHost, currentFilePath: currentFilePath,
                openFile: openFile, isActive: isActive,
                canFocusKeyboard: canFocusKeyboard, renameFile: renameFile,
                onCommand: onCommand, refreshGitStatus: refreshGitStatus,
                isCurrentTarget: isCurrentTarget,
                canPasteFiles: canPasteFiles,
                canImportFromFinder: canImportFromFinder,
                importFromFinder: importFromFinder,
                makeDragProvider: makeDragProvider,
                receiveInternalDrop: receiveInternalDrop
            )
        }
        .onChange(of: model.settings.filesExclude) { _, _ in
            Task { await model.refreshVisibility() }
        }
        .onDrop(of: [FileTreeDrag.type, UTType.fileURL.identifier], delegate: FileTreeImportDrop(
            directory: model.rootPath,
            enabled: canImportFromFinder && isCurrentTarget(),
            canAcceptInternal: isCurrentTarget(),
            importFromFinder: importFromFinder,
            receiveInternalDrop: receiveInternalDrop
        ))
    }
}

/// File Manager has a different drop action from the surrounding workspace:
/// copy into its actual directory, never open an editor or move the source.
private struct FileTreeImportDrop: DropDelegate {
    let directory: String
    let enabled: Bool
    let canAcceptInternal: Bool
    let importFromFinder: ([NSItemProvider], String) -> Bool
    let receiveInternalDrop: (NSItemProvider, String, Bool) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard !directory.isEmpty else { return false }
        if info.hasItemsConforming(to: [FileTreeDrag.type]) { return true }
        return enabled && info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        if info.hasItemsConforming(to: [FileTreeDrag.type]) {
            return DropProposal(operation: canAcceptInternal
                ? (NSEvent.modifierFlags.contains(.option) ? .copy : .move) : .forbidden)
        }
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        if info.hasItemsConforming(to: [FileTreeDrag.type]) {
            // Consume even a foreign private drag so its public fileURL never
            // falls through to Finder import in this Files panel.
            if canAcceptInternal,
               let provider = info.itemProviders(for: [FileTreeDrag.type]).first {
                _ = receiveInternalDrop(provider, directory, NSEvent.modifierFlags.contains(.option))
            }
            return true
        }
        return importFromFinder(info.itemProviders(for: [UTType.fileURL.identifier]), directory)
    }
}

/// The same SwiftUI rows, 22 pt layout and hierarchy lines as the Git tree.
/// The tree stays viewport-sized; only long names scroll horizontally.
private struct FileTreeScrollView: View {
    let model: FileTreeModel
    let git: GitStatusModel
    let sshHost: String?
    let currentFilePath: String?
    let openFile: (String, Bool) -> Void
    let isActive: Bool
    let canFocusKeyboard: () -> Bool
    let renameFile: (FileTreeModel.Item, String) async -> String?
    let onCommand: (FileTreeCommand) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool
    let canPasteFiles: () -> Bool
    let canImportFromFinder: Bool
    let importFromFinder: ([NSItemProvider], String) -> Bool
    let makeDragProvider: (FileTreeModel.Item) -> NSItemProvider
    let receiveInternalDrop: (NSItemProvider, String, Bool) -> Bool
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
                            sshHost: sshHost,
                            currentFilePath: currentFilePath,
                            openFile: openFile,
                            listFocused: keyboardFocused && isActive && controlActiveState == .key,
                            focusKeyboard: {
                                if canFocusKeyboard() { keyboardOwner.focus() }
                            },
                            renameFile: renameFile, onCommand: onCommand,
                            refreshGitStatus: refreshGitStatus, isCurrentTarget: isCurrentTarget,
                            makeDragProvider: makeDragProvider,
                            canImportFromFinder: canImportFromFinder,
                            importFromFinder: importFromFinder,
                            receiveInternalDrop: receiveInternalDrop
                        )
                        .id(item.path)
                        .onDrop(of: [FileTreeDrag.type, UTType.fileURL.identifier], delegate: FileTreeImportDrop(
                            directory: item.isDirectory ? item.path
                                : (item.path as NSString).deletingLastPathComponent,
                            enabled: canImportFromFinder && !item.isDraft && isCurrentTarget(),
                            canAcceptInternal: !item.isDraft && isCurrentTarget(),
                            importFromFinder: importFromFinder,
                            receiveInternalDrop: receiveInternalDrop
                        ))
                    }
                }
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background {
                TreeKeyboardHost(owner: keyboardOwner, onKeyDown: handleKey,
                                 onFocusChanged: { keyboardFocused = $0 },
                                 onAttachedToWindow: focusSelectedRow,
                                 onEditCommand: performEdit,
                                 canEditCommand: canPerformEdit)
            }
            .onAppear { if isActive { focusSelectedRow() } }
            .onChange(of: isActive) { _, active in
                if active { focusSelectedRow() }
                else { waitingForFirstRow = false }
            }
            .onChange(of: isCurrentTarget()) { _, current in
                if current { focusSelectedRow() }
            }
            .onChange(of: canFocusKeyboard()) { _, available in
                if available { focusSelectedRow() }
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
              window.isKeyWindow, NSApp.isActive, window.attachedSheet == nil else { return }
        // A visible command palette or another native text field owns its input.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return }
        keyboardOwner.focus()
    }

    private func canPerformEdit(_ action: TreeEditAction) -> Bool {
        guard isActive, canFocusKeyboard(), isCurrentTarget(),
              model.renamingPath == nil, model.draft == nil else { return false }
        switch action {
        case .cut, .copy, .delete: return !model.selectedOperationPaths.isEmpty
        case .paste: return canPasteFiles()
        case .selectAll: return model.items.contains { !$0.isDraft }
        }
    }

    private func performEdit(_ action: TreeEditAction) {
        guard canPerformEdit(action) else { return }
        switch action {
        case .cut: onCommand(.copy(model.selectedOperationPaths, cut: true))
        case .copy: onCommand(.copy(model.selectedOperationPaths, cut: false))
        case .paste: onCommand(.paste(into: model.selectedDirectoryPath ?? model.rootPath))
        case .delete: onCommand(.delete(model.selectedOperationPaths))
        case .selectAll: model.selectAllVisible()
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard keyboardOwner.view?.window?.firstResponder === keyboardOwner.view,
              isActive, canFocusKeyboard(), isCurrentTarget()
        else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, event.keyCode == 117 {
            performEdit(.delete)
            return true
        }
        guard modifiers.isEmpty || modifiers == [.shift] else { return false }
        switch event.keyCode {
        case 125: model.moveSelection(by: 1, extending: modifiers.contains(.shift)) // Down
        case 126: model.moveSelection(by: -1, extending: modifiers.contains(.shift)) // Up
        case 124 where modifiers.isEmpty: // Right
            guard let row = model.selectedItem, row.isDirectory else { return false }
            if !model.isExpanded(row) { Task { await model.toggle(row) } }
            else if let child = model.nextVisibleChild(of: row) { model.select(child) }
        case 123 where modifiers.isEmpty: // Left
            guard let row = model.selectedItem else { return false }
            if row.isDirectory, model.isExpanded(row) {
                Task { await model.toggle(row) }
            } else if let parent = model.items
                .filter({ $0.isDirectory && row.path.hasPrefix($0.path + "/") })
                .max(by: { $0.path.count < $1.path.count }) {
                model.select(parent)
            }
        case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty: // Return and keypad Enter
            guard let row = model.selectedItem else { return false }
            if row.isDirectory { Task { await model.toggle(row) } }
            else { openFile(row.path, true) }
        case 49 where modifiers.isEmpty: // Space previews without moving keyboard focus
            guard let row = model.selectedItem else { return false }
            if row.isDirectory { Task { await model.toggle(row) } }
            else { openFile(row.path, false) }
        case 53 where modifiers.isEmpty: model.clearSelection() // Escape
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
    let sshHost: String?
    let currentFilePath: String?
    let openFile: (String, Bool) -> Void
    let listFocused: Bool
    let focusKeyboard: () -> Void
    let renameFile: (FileTreeModel.Item, String) async -> String?
    let onCommand: (FileTreeCommand) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool
    let makeDragProvider: (FileTreeModel.Item) -> NSItemProvider
    let canImportFromFinder: Bool
    let importFromFinder: ([NSItemProvider], String) -> Bool
    let receiveInternalDrop: (NSItemProvider, String, Bool) -> Bool

    @State private var editingName = ""
    @State private var hoveredCompactPath: String?
    @FocusState private var fieldFocused: Bool
    @Environment(\.panelFontScale) private var fontScale

    private var isRenaming: Bool { model.renamingPath == item.path }
    private var hasKeyboardCursor: Bool {
        model.selectedPath == item.path && listFocused
    }

    private var isMultiSelected: Bool { model.selectedPaths.contains(item.path) }

    private func selectForClick(componentPath: String? = nil) -> Bool {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        let extending = modifiers.contains(.shift)
        let toggling = modifiers.contains(.command) && !extending
        model.select(item, extending: extending, toggling: toggling, componentPath: componentPath)
        focusKeyboard()
        return extending || toggling
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

    /// Remote project paths must never be interpreted as Mac file URLs.
    private var isRemote: Bool { sshHost != nil }

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
            .contextMenu { rowMenu(for: item) }
        } else {
            // Local drags retain public fileURL for Finder; SSH drags publish only
            // the process-private Files type, never a Mac path for a remote file.
            semanticRow
                .contextMenu { rowMenu(for: activeMenuTarget) }
                .onDrag { makeDragProvider(item) }
        }
    }

    private var activeMenuTarget: FileTreeModel.Item {
        guard model.selectedPath == item.path,
              let path = model.selectedCompactPath,
              let component = item.compactComponents.first(where: { $0.path == path })
        else { return item }
        return item.item(for: component)
    }

    @ViewBuilder
    private func rowMenu(for target: FileTreeModel.Item) -> some View {
        let selection = target.path == item.path
            ? model.contextSelection(for: item) : [target.path]
        let matchesKeyboardSelection = listFocused
            && Set(selection) == Set(model.selectedOperationPaths)
        if target.isDirectory {
            let matchesNewItemTarget = listFocused
                && model.selectedDirectoryPath == target.path
            let newFileTitle = String(localized: "New File…", table: "Sidebar")
            Button {
                Task {
                    guard isCurrentTarget() else { return }
                    await model.beginNewFile(in: target.path)
                }
            } label: {
                if matchesNewItemTarget {
                    Text(verbatim: newFileTitle + "\t⌘N")
                } else {
                    Text(newFileTitle)
                }
            }
            .accessibilityLabel(newFileTitle)

            let newFolderTitle = String(localized: "New Folder…", table: "Sidebar")
            Button {
                Task {
                    guard isCurrentTarget() else { return }
                    await model.beginNewFolder(in: target.path)
                }
            } label: {
                if matchesNewItemTarget {
                    Text(verbatim: newFolderTitle + "\t⌥⌘N")
                } else {
                    Text(newFolderTitle)
                }
            }
            .accessibilityLabel(newFolderTitle)
        } else {
            Button(String(localized: "Open", table: "Sidebar")) {
                if isCurrentTarget() { openFile(target.path, true) }
            }
        }
        if !isRemote {
            Button(String(localized: "Open in Default App", table: "Sidebar")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: target.path))
            }
            Button(String(localized: "Reveal in Finder", table: "Sidebar")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.path)])
            }
        }
        Divider()
        let cutTitle = String(localized: "Cut", table: "Sidebar")
        Button {
            if isCurrentTarget() { onCommand(.copy(selection, cut: true)) }
        } label: {
            Text(verbatim: cutTitle + (matchesKeyboardSelection ? "\t⌘X" : ""))
        }
        .accessibilityLabel(cutTitle)

        let copyTitle = String(localized: "Copy", table: "Sidebar")
        Button {
            if isCurrentTarget() { onCommand(.copy(selection, cut: false)) }
        } label: {
            Text(verbatim: copyTitle + (matchesKeyboardSelection ? "\t⌘C" : ""))
        }
        .accessibilityLabel(copyTitle)

        if target.isDirectory {
            let pasteTitle = String(localized: "Paste", table: "Sidebar")
            Button {
                if isCurrentTarget() { onCommand(.paste(into: target.path)) }
            } label: {
                Text(verbatim: pasteTitle + (listFocused
                    && (model.selectedDirectoryPath ?? model.rootPath) == target.path
                        ? "\t⌘V" : ""))
            }
            .accessibilityLabel(pasteTitle)
        }
        Divider()
        Button(String(localized: "Copy Path", table: "Sidebar")) {
            guard isCurrentTarget() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selection.joined(separator: "\n"), forType: .string)
        }
        Button(String(localized: "Copy Relative Path", table: "Sidebar")) {
            guard isCurrentTarget() else { return }
            let root = model.rootPath == "/" ? "/" : model.rootPath + "/"
            let paths = selection.filter { $0.hasPrefix(root) }
                .map { String($0.dropFirst(root.count)) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button(String(localized: "Rename", table: "Sidebar")) {
            guard isCurrentTarget() else { return }
            model.beginRename(target)
        }
        let deleteTitle = isRemote ? String(localized: "Delete…", table: "Sidebar")
            : String(localized: "Move to Trash", table: "Sidebar")
        Button(role: .destructive) {
            if isCurrentTarget() { onCommand(.delete(selection)) }
        } label: {
            Text(verbatim: deleteTitle + (matchesKeyboardSelection ? "\t⌫" : ""))
        }
        .accessibilityLabel(deleteTitle)
    }

    /// Commits an inline rename and, when the file actually moved, tells the
    /// app to follow it in any open tabs. Guarded by `isRenaming` so the
    /// commit-on-blur that fires right after Enter/Escape is a no-op.
    private func commitRename() {
        guard isCurrentTarget() else { return }
        guard isRenaming else { return }
        let newName = editingName
        Task {
            guard isCurrentTarget() else { return }
            if await renameFile(item, newName) != nil { refreshGitStatus() }
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

    private func compactSegmentView(_ component: TreeDisplayModel.Row.CompactComponent) -> AnyView {
        let target = item.item(for: component)
        return AnyView(
            Text(component.name)
                .underline(model.selectedPath == item.path
                    && (model.selectedCompactPath ?? item.path) == component.path)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hoveredCompactPath == component.path
                            ? Color.primary.opacity(0.09) : .clear)
                )
                .onHover { hovered in
                    hoveredCompactPath = hovered ? component.path : nil
                }
                .highPriorityGesture(TapGesture().onEnded {
                    guard isCurrentTarget() else { return }
                    if selectForClick(componentPath: component.path) { return }
                    Task {
                        guard isCurrentTarget() else { return }
                        await model.toggle(item)
                    }
                })
                .contextMenu { rowMenu(for: target) }
                .onDrag { makeDragProvider(target) }
                .onDrop(
                    of: [FileTreeDrag.type, UTType.fileURL.identifier],
                    delegate: FileTreeImportDrop(
                        directory: component.path,
                        enabled: canImportFromFinder && isCurrentTarget(),
                        canAcceptInternal: isCurrentTarget(),
                        importFromFinder: importFromFinder,
                        receiveInternalDrop: receiveInternalDrop
                    )
                )
                .accessibilityLabel(component.name)
                .accessibilityIdentifier(
                    "bailey.tree.folder.component.\(item.compactComponents.firstIndex(of: component) ?? 0)"
                )
        )
    }

    @ViewBuilder
    private var semanticRow: some View {
        if item.isDirectory {
            TreeFolderRow(row: displayRow, scale: fontScale,
                          focusRing: hasKeyboardCursor, multiSelected: isMultiSelected,
                          multiSelectionEnabled: true,
                          compactSegment: { component in compactSegmentView(component) }) {
                guard isCurrentTarget() else { return }
                if selectForClick() { return }
                Task {
                    guard isCurrentTarget() else { return }
                    await model.toggle(item)
                }
            }
        } else {
            TreeFileRow(
                row: displayRow, scale: fontScale, selected: isCurrent,
                multiSelected: isMultiSelected, multiSelectionEnabled: true,
                focusRing: hasKeyboardCursor,
                open: {
                    guard isCurrentTarget() else { return }
                    if !selectForClick() { openFile(item.path, false) }
                },
                activate: {
                    let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                    guard isCurrentTarget(), !modifiers.contains(.command),
                          !modifiers.contains(.shift) else { return }
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
