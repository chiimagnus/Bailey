import AppKit
import SwiftUI

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

    struct Record {
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
    var onKeyboardAttached: (TreeKeyboardView) -> Void = { _ in }
    let renameFile: (FileTreeModel.Item, String) async -> String?
    let onCommand: (FileTreeCommand) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool
    let canPasteFiles: () -> Bool
    let canImportFromFinder: Bool
    let importFromFinder: ([NSItemProvider], String) -> Bool
    var beginDrag: (FileTreeModel.Item) -> FileTreeDrag.Record? = { _ in nil }
    var endDrag: (UUID) -> Void = { _ in }
    var receiveInternalDrop: (FileTreeDrag.Record, String, Bool) -> Bool = { _, _, _ in false }

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
                canFocusKeyboard: canFocusKeyboard,
                onKeyboardAttached: onKeyboardAttached, renameFile: renameFile,
                onCommand: onCommand, refreshGitStatus: refreshGitStatus,
                isCurrentTarget: isCurrentTarget,
                canPasteFiles: canPasteFiles,
                canImportFromFinder: canImportFromFinder,
                importFromFinder: importFromFinder,
                beginDrag: beginDrag, endDrag: endDrag,
                receiveInternalDrop: receiveInternalDrop
            )
        }
        .onChange(of: model.settings.filesExclude) { _, _ in
            Task { await model.refreshVisibility() }
        }
        .background {
            FileTreeNativeDragSurface(
                directory: model.rootPath, isCurrent: isCurrentTarget,
                allowsFinder: canImportFromFinder,
                receiveInternal: receiveInternalDrop, importFinder: importFromFinder
            )
        }
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
    let onKeyboardAttached: (TreeKeyboardView) -> Void
    let renameFile: (FileTreeModel.Item, String) async -> String?
    let onCommand: (FileTreeCommand) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool
    let canPasteFiles: () -> Bool
    let canImportFromFinder: Bool
    let importFromFinder: ([NSItemProvider], String) -> Bool
    let beginDrag: (FileTreeModel.Item) -> FileTreeDrag.Record?
    let endDrag: (UUID) -> Void
    let receiveInternalDrop: (FileTreeDrag.Record, String, Bool) -> Bool
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.panelFontScale) private var fontScale
    @State private var keyboardOwner = TreeKeyboardOwner()
    @State private var keyboardFocused = false
    @State private var waitingForFirstRow = false
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.items) { item in
                        FileTreeRow(
                            model: model, git: git, item: item,
                            sshHost: sshHost,
                            openFile: openFile,
                            listFocused: keyboardFocused && isActive && controlActiveState == .key,
                            focusKeyboard: {
                                if canFocusKeyboard() { keyboardOwner.focus() }
                            },
                            renameFile: renameFile, onCommand: onCommand,
                            refreshGitStatus: refreshGitStatus, isCurrentTarget: isCurrentTarget,
                            beginDrag: beginDrag, endDrag: endDrag,
                            canImportFromFinder: canImportFromFinder,
                            importFromFinder: importFromFinder,
                            receiveInternalDrop: receiveInternalDrop
                        )
                        .id(item.path)
                    }
                }
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.height }) { _, height in
                viewportHeight = height
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
        if let tree = keyboardOwner.view { onKeyboardAttached(tree) }
        guard isActive, canFocusKeyboard(), isCurrentTarget(),
              model.renamingPath == nil, model.draft == nil else { return }
        if model.selectedItem == nil {
            let current = model.items.first { !$0.isDraft && $0.path == currentFilePath }
            let item = current ?? model.items.first { !$0.isDraft }
            if let item {
                if current != nil { model.select(item) }
                else { model.focus(item) }
            }
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
              isActive, canFocusKeyboard(), isCurrentTarget(),
              model.renamingPath == nil, model.draft == nil
        else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, event.keyCode == 117 {
            performEdit(.delete)
            return true
        }
        guard modifiers.isEmpty || modifiers == [.shift] else { return false }
        let page = max(1, Int(viewportHeight / TreeRowStyle.rowHeight(fontScale)))
        switch event.keyCode {
        case 125: model.moveSelection(by: 1, extending: modifiers.contains(.shift)) // Down
        case 126: model.moveSelection(by: -1, extending: modifiers.contains(.shift)) // Up
        case 115 where modifiers.isEmpty: model.moveSelection(by: -model.items.count)
        case 119 where modifiers.isEmpty: model.moveSelection(by: model.items.count)
        case 116 where modifiers.isEmpty: model.moveSelection(by: -page)
        case 121 where modifiers.isEmpty: model.moveSelection(by: page)
        case 124 where modifiers.isEmpty: // Right
            guard let row = model.selectedItem, row.isDirectory else { return false }
            if !model.isExpanded(row) { Task { await model.toggle(row) } }
            else if let child = model.nextVisibleChild(of: row) { model.focus(child) }
        case 123 where modifiers.isEmpty: // Left
            guard let row = model.selectedItem else { return false }
            if row.isDirectory, model.isExpanded(row) {
                Task { await model.toggle(row) }
            } else if let parent = model.items
                .filter({ $0.isDirectory && row.path.hasPrefix($0.path + "/") })
                .max(by: { $0.path.count < $1.path.count }) {
                model.focus(parent)
            }
        case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty: // Return and keypad Enter
            guard let row = model.selectedItem else { return false }
            if row.isDirectory { Task { await model.toggle(row) } }
            else { openFile(row.path, true) }
        case 49 where modifiers.isEmpty: // Space explicitly browses the focused file
            guard let row = model.selectedItem else { return false }
            if row.isDirectory { Task { await model.toggle(row) } }
            else {
                model.select(row)
                openFile(row.path, false)
            }
        case 53 where modifiers.isEmpty: model.clearExplicitSelection() // Escape
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
    let openFile: (String, Bool) -> Void
    let listFocused: Bool
    let focusKeyboard: () -> Void
    let renameFile: (FileTreeModel.Item, String) async -> String?
    let onCommand: (FileTreeCommand) -> Void
    let refreshGitStatus: () -> Void
    let isCurrentTarget: () -> Bool
    let beginDrag: (FileTreeModel.Item) -> FileTreeDrag.Record?
    let endDrag: (UUID) -> Void
    let canImportFromFinder: Bool
    let importFromFinder: ([NSItemProvider], String) -> Bool
    let receiveInternalDrop: (FileTreeDrag.Record, String, Bool) -> Bool

    @State private var editingName = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.panelFontScale) private var fontScale

    private var isRenaming: Bool { model.renamingPath == item.path }
    private var contextMenuPath: String? { model.contextMenuTargetPath }
    private var hasContextRing: Bool {
        guard let contextMenuPath else { return false }
        return contextMenuPath == item.path
            || item.compactComponents.contains { $0.path == contextMenuPath }
    }
    private var hasKeyboardCursor: Bool {
        model.contextMenuTargetPath == nil && model.selectedPath == item.path && listFocused
    }

    private var isSelected: Bool { model.selectedPaths.contains(item.path) }

    private func selectForClick(componentPath: String? = nil) -> Bool {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        let extending = modifiers.contains(.shift)
        let toggling = modifiers.contains(.command) && !extending
        model.select(item, extending: extending, toggling: toggling, componentPath: componentPath)
        focusKeyboard()
        return extending || toggling
    }

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
                depth: item.depth, scale: fontScale,
                isSelected: isSelected, listActive: listFocused,
                contextRing: hasContextRing
            ) { _, layout in
                renameRow
                    .modifier(layout)
            }
            .overlay {
                ContextMenuClickTarget(onContextClick: { selectForContextMenu(item) },
                                       onMenuClosed: { model.dismissContextMenu(target: item.path) },
                                       onMenuKeyDown: handleMenuKeyDown,
                                       isExpectedMenu: isMenuForCurrentRow)
                    .contextMenu { rowMenu(for: item) }
            }
        } else if item.isDirectory && !item.compactPrefix.isEmpty {
            semanticRow
                .background {
                    ContextMenuClickTarget(onContextClick: { selectForContextMenu(item) },
                                           onMenuClosed: { model.dismissContextMenu(target: item.path) },
                                           onMenuKeyDown: handleMenuKeyDown,
                                           isExpectedMenu: isMenuForCurrentRow)
                }
                .contextMenu { rowMenu(for: item) }
        } else {
            // Local drags retain public fileURL for Finder; SSH drags publish only
            // the process-private Files type, never a Mac path for a remote file.
            semanticRow
                .overlay {
                    ContextMenuClickTarget(onContextClick: { selectForContextMenu(item) },
                                           onMenuClosed: { model.dismissContextMenu(target: item.path) },
                                           onMenuKeyDown: handleMenuKeyDown,
                                           isExpectedMenu: isMenuForCurrentRow)
                        .contextMenu { rowMenu(for: item) }
                }
                .overlay {
                    nativeDragSurface(for: item, into: item.isDirectory
                        ? item.path : (item.path as NSString).deletingLastPathComponent) { event in
                        guard isCurrentTarget() else { return }
                        if item.isDirectory {
                            if selectForClick() { return }
                            Task { await model.toggle(item) }
                        } else {
                            if !selectForClick() { openFile(item.path, false) }
                            if event.clickCount == 2,
                               !event.modifierFlags.contains(.command),
                               !event.modifierFlags.contains(.shift) {
                                openFile(item.path, true)
                            }
                        }
                    }
                }
        }
    }

    private func nativeDragSurface(
        for target: FileTreeModel.Item, into directory: String,
        onClick: @escaping (NSEvent) -> Void
    ) -> some View {
        FileTreeNativeDragSurface(
            onClick: onClick,
            beginDrag: { isCurrentTarget() ? beginDrag(target) : nil },
            endDrag: endDrag, directory: directory,
            isCurrent: isCurrentTarget, allowsFinder: canImportFromFinder,
            receiveInternal: receiveInternalDrop, importFinder: importFromFinder
        )
    }

    private func selectForContextMenu(_ target: FileTreeModel.Item) {
        guard isCurrentTarget() else { return }
        model.selectForContextMenu(item, componentPath: target.path == item.path ? nil : target.path)
    }

    private func isMenuForCurrentRow(_ menu: NSMenu) -> Bool {
        guard isCurrentTarget(), !item.isDraft,
              model.items.contains(where: { $0.path == item.path }),
              let target = model.contextMenuTargetPath,
              target == item.path || item.compactComponents.contains(where: { $0.path == target })
        else { return false }
        return menu.items.contains {
            $0.accessibilityLabel() == String(localized: "Copy Relative Path", table: "Sidebar")
        }
    }

    private func handleMenuKeyDown(_ menu: NSMenu, _ event: NSEvent) -> Bool {
        guard isMenuForCurrentRow(menu) else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let title: String
        switch (key, modifiers) {
        case (_, []) where event.keyCode == 51 || event.keyCode == 117:
            title = sshHost == nil
                ? String(localized: "Move to Trash", table: "Sidebar")
                : String(localized: "Delete…", table: "Sidebar")
        case ("c", [.command]): title = String(localized: "Copy", table: "Sidebar")
        case ("x", [.command]): title = String(localized: "Cut", table: "Sidebar")
        case ("v", [.command]): title = String(localized: "Paste", table: "Sidebar")
        case ("n", [.command]): title = String(localized: "New File…", table: "Sidebar")
        case ("n", [.option, .command]):
            title = String(localized: "New Folder…", table: "Sidebar")
        default: return false
        }
        guard let index = menu.items.firstIndex(where: {
            $0.isEnabled && $0.accessibilityLabel() == title
        }) else { return false }
        menu.performActionForItem(at: index)
        menu.cancelTracking()
        return true
    }

    @ViewBuilder
    private func rowMenu(for target: FileTreeModel.Item) -> some View {
        let selection = target.path == item.path
            ? model.contextSelection(for: item) : [target.path]
        if target.isDirectory {
            let newFileTitle = String(localized: "New File…", table: "Sidebar")
            Button {
                Task {
                    guard isCurrentTarget() else { return }
                    await model.beginNewFile(in: target.path)
                }
            } label: {
                Text(verbatim: newFileTitle + "\t⌘N")
            }
            .accessibilityLabel(newFileTitle)

            let newFolderTitle = String(localized: "New Folder…", table: "Sidebar")
            Button {
                Task {
                    guard isCurrentTarget() else { return }
                    await model.beginNewFolder(in: target.path)
                }
            } label: {
                Text(verbatim: newFolderTitle + "\t⌥⌘N")
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
            Text(verbatim: cutTitle + "\t⌘X")
        }
        .accessibilityLabel(cutTitle)

        let copyTitle = String(localized: "Copy", table: "Sidebar")
        Button {
            if isCurrentTarget() { onCommand(.copy(selection, cut: false)) }
        } label: {
            Text(verbatim: copyTitle + "\t⌘C")
        }
        .accessibilityLabel(copyTitle)

        if target.isDirectory {
            let pasteTitle = String(localized: "Paste", table: "Sidebar")
            Button {
                if isCurrentTarget() { onCommand(.paste(into: target.path)) }
            } label: {
                Text(verbatim: pasteTitle + "\t⌘V")
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
            Text(verbatim: deleteTitle + "\t⌫")
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

    private func compactSegmentView(_ component: TreeDisplayModel.Row.CompactComponent, index: Int) -> AnyView {
        let target = item.item(for: component)
        return AnyView(
            TreeCompactSegment(component: component, index: index,
                highlighted: hasKeyboardCursor && (model.selectedCompactPath ?? item.path) == component.path,
                isContextTarget: contextMenuPath == component.path,
                onClick: {
                    guard isCurrentTarget() else { return }
                    if selectForClick(componentPath: component.path) { return }
                    Task {
                        guard isCurrentTarget() else { return }
                        await model.toggle(item)
                    }
                },
                onContextClick: { selectForContextMenu(target) },
                onMenuClosed: { model.dismissContextMenu(target: target.path) },
                onMenuKeyDown: handleMenuKeyDown,
                isExpectedMenu: isMenuForCurrentRow,
                menuContent: { rowMenu(for: target) })
                .overlay {
                    nativeDragSurface(for: target, into: component.path) { _ in
                        guard isCurrentTarget() else { return }
                        if selectForClick(componentPath: component.path) { return }
                        Task { await model.toggle(item) }
                    }
                }

        )
    }

    @ViewBuilder
    private var semanticRow: some View {
        if item.isDirectory {
            TreeFolderRow(row: displayRow, scale: fontScale,
                          focusRing: hasKeyboardCursor, contextRing: hasContextRing,
                          isSelected: isSelected,
                          listActive: listFocused,
                          compactSegment: { component, index in compactSegmentView(component, index: index) }) {
                guard isCurrentTarget() else { return }
                if selectForClick() { return }
                Task {
                    guard isCurrentTarget() else { return }
                    await model.toggle(item)
                }
            }
        } else {
            TreeFileRow(
                row: displayRow, scale: fontScale,
                isSelected: isSelected,
                listActive: listFocused,
                focusRing: hasKeyboardCursor, contextRing: hasContextRing,
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
