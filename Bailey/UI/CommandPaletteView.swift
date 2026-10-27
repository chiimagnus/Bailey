import AppKit
import FuzzyMatch
import SwiftUI

/// Groups palette rows under a header — built-in actions, project files, and
/// open sessions.
enum PaletteSection: Hashable {
    case command
    case file
    case session

    var title: String {
        switch self {
        case .command: return String(localized: "Commands", table: "Workspace", comment: "Command palette section title.")
        case .file: return String(localized: "Files", table: "Workspace", comment: "Command palette section title.")
        case .session: return String(localized: "Sessions", table: "Workspace", comment: "Command palette section title.")
        }
    }
}

/// One selectable entry in the ⌘P palette: a built-in action, project file, or
/// jump to an open terminal session.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var fileIconPath: String? = nil
    /// Secondary text shown after the title — a file or session directory.
    var subtitle: String? = nil
    var shortcut: String? = nil
    var section: PaletteSection = .command
    /// Text the fuzzy filter matches against; defaults to `title`, widened for
    /// files and sessions to also cover their directories.
    var searchText: String? = nil
    let action: () -> Void

    /// Built-in command copy is a localized resource. Runtime content such as
    /// shell-provided session titles uses the explicitly verbatim initializer.
    init(
        id: String,
        title: LocalizedStringResource,
        systemImage: String,
        fileIconPath: String? = nil,
        subtitle: String? = nil,
        shortcut: String? = nil,
        section: PaletteSection = .command,
        searchText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = String(localized: title)
        self.systemImage = systemImage
        self.fileIconPath = fileIconPath
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.section = section
        self.searchText = searchText
        self.action = action
    }

    init(
        id: String,
        verbatimTitle: String,
        systemImage: String,
        fileIconPath: String? = nil,
        subtitle: String? = nil,
        shortcut: String? = nil,
        section: PaletteSection = .command,
        searchText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = verbatimTitle
        self.systemImage = systemImage
        self.fileIconPath = fileIconPath
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.section = section
        self.searchText = searchText
        self.action = action
    }
}

@MainActor
private final class PalettePointerSelectionController {
    private(set) var acceptsPointerSelection = false

    func reset() {
        acceptsPointerSelection = false
    }

    func notePointerMoved() {
        acceptsPointerSelection = true
    }
}

/// Centered ⌘P overlay: fuzzy-searchable list of app actions. Arrow keys
/// move the selection, Return runs it, and Escape clears a query before
/// dismissing an already-empty palette.
struct CommandPaletteView: View {
    private struct FileIndexKey: Hashable {
        let identity: PanelContext.Identity
        let revision: UInt64
        let filesRevision: UInt64
        let changeEvent: Int
    }

    private struct ScoredProjectFile {
        let file: ProjectFile
        let score: Double
    }

    private typealias ProjectFile = ProjectFileIndex.File

    let manager: WorkspaceWindowModel
    private let themeChanges = Theme.changes
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var selection = 0
    @State private var projectFiles: [ProjectFile] = []
    @State private var indexedTarget: FileIndexKey?
    @State private var indexedRoot: String?
    @State private var indexIssue: String?
    @State private var indexLimited = false
    @State private var connectionChangeEvent = 0
    @State private var applicationIsActive = NSApp.isActive
    @State private var watchedIndexTree: FileTreeModel?
    @State private var indexWatcherMemberID = UUID()
    @State private var pointerSelectionController = PalettePointerSelectionController()
    @FocusState private var searchFocused: Bool

    /// Smith-Waterman uses fzf/nucleo-style boundary and gap scoring while
    /// remaining fast enough to scan a large project on every keystroke.
    private static let fuzzyMatcher = FuzzyMatcher(config: .smithWaterman)
    private static let maxFileResults = 50

    var body: some View {
        let _ = themeChanges.revision
        ZStack(alignment: .top) {
            // The palette floats over the terminal surface, whose AppKit cursor
            // rect would otherwise show through as an I-beam across the whole
            // backdrop. Each region of the palette states its own pointer.
            Color.black.opacity(0.15)
                .onTapGesture { dismiss() }
                .pointerStyle(.default)

            panel
                .padding(.top, 110)
        }
        .ignoresSafeArea()
        .background(
            PalettePointerEventMonitor(controller: pointerSelectionController)
        )
        .onExitCommand { handleEscapeFromKeyboard() }
        .onDisappear {
            stopLocalIndexWatcher()
            manager.restoreFocusAfterCommandPalette()
        }
        .onChange(of: manager.selectedProject?.panelContext?.identity) {
            updateLocalIndexWatcher()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            applicationIsActive = false
            updateLocalIndexWatcher()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            applicationIsActive = true
            updateLocalIndexWatcher()
            if fileIndexContext != nil { connectionChangeEvent &+= 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: SSHHostWorkspaces.connectionChanged)) { note in
            guard let host = note.object as? String,
                  fileIndexContext?.identity.workspace == "ssh:" + host else { return }
            connectionChangeEvent &+= 1
        }
        .task(id: fileIndexKey) {
            projectFiles = []
            indexedTarget = nil
            indexedRoot = nil
            indexIssue = nil
            indexLimited = false
            guard let context = fileIndexContext,
                  let key = fileIndexKey,
                  let project = manager.selectedProject else { return }
            do {
                let root = context.cwd
                let files: [ProjectFile]
                let limited: Bool
                if context.isRemote {
                    if let scope = context.identity.workspace, scope.hasPrefix("ssh:"),
                       SSHHostWorkspaces.connectionState(for: String(scope.dropFirst(4))) == false {
                        throw ProjectFileIndex.RemoteIndexError.unavailable(String(localized: "Remote host is disconnected.", table: "Interface"))
                    }
                    let remote = try await ProjectFileIndex.loadRemote(
                        in: root, backend: context.backend
                    )
                    files = remote.files
                    limited = remote.limited
                } else {
                    let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL
                    guard standardizedRoot != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
                    else { return }
                    let tree = project.fileTree
                    if !tree.matchesIndexTarget(root: root, context: context) {
                        _ = await tree.sync(
                            root: root, backend: context.backend, scope: context.scope,
                            panelIdentity: context.identity, connectionRevision: context.connectionRevision
                        )
                    }
                    guard !Task.isCancelled, fileIndexKey == key,
                          manager.selectedProjectID == project.id,
                          project.matchesPanelTarget(context.identity) else { return }
                    // The existing Files stream also watches linked-worktree Git metadata
                    // while a file search is open; there is no second background watcher.
                    let gitDirectoryTask = Task.detached(priority: .userInitiated) {
                        ProjectFileIndex.gitDirectory(in: root)
                    }
                    let gitDirectory = await withTaskCancellationHandler {
                        await gitDirectoryTask.value
                    } onCancel: {
                        gitDirectoryTask.cancel()
                    }
                    guard !Task.isCancelled, fileIndexKey == key,
                          manager.selectedProjectID == project.id,
                          project.matchesPanelTarget(context.identity) else { return }
                    tree.setLocalFileIndexGitDirectory(gitDirectory)
                    let indexingTask = Task.detached(priority: .userInitiated) {
                        ProjectFileIndex.load(in: root)
                    }
                    files = await withTaskCancellationHandler {
                        await indexingTask.value
                    } onCancel: {
                        indexingTask.cancel()
                    }
                    limited = false
                }
                guard !Task.isCancelled, fileIndexKey == key,
                      manager.selectedProjectID == project.id,
                      project.matchesPanelTarget(context.identity) else { return }
                indexedTarget = key
                indexedRoot = root
                projectFiles = files
                indexLimited = limited
            } catch {
                guard !(error is CancellationError), !Task.isCancelled,
                      fileIndexKey == key else { return }
                indexIssue = error.localizedDescription
            }
        }
    }

    // MARK: - Commands

    private var commands: [PaletteCommand] {
        var items: [PaletteCommand] = [
            PaletteCommand(id: "new-file", title: LocalizedStringResource("New File…", table: "Sidebar"), systemImage: "doc.badge.plus", shortcut: "⌘N") {
                Task { await manager.newFile() }
            },
            PaletteCommand(id: "new-folder", title: LocalizedStringResource("New Folder…", table: "Sidebar"), systemImage: "folder.badge.plus", shortcut: "⌥⌘N") {
                Task { await manager.newFolder() }
            },
            PaletteCommand(id: "new-session", title: LocalizedStringResource("New Terminal", table: "Interface"), systemImage: "terminal", shortcut: "⌘T") {
                manager.newSession()
            },
            PaletteCommand(id: "new-browser-tab", title: LocalizedStringResource("New Browser Tab", table: "Interface"), systemImage: "globe") {
                manager.newBrowserTab()
            },
            PaletteCommand(id: "clear-terminal", title: LocalizedStringResource("Clear Terminal", table: "Interface"), systemImage: "eraser", shortcut: "⌘K") {
                manager.clearActiveTerminal()
            },
            PaletteCommand(id: "add-folder", title: LocalizedStringResource("Add Projects", table: "Interface"), systemImage: "folder.badge.plus", shortcut: "⇧⌘A") {
                manager.chooseFolders()
            },
            PaletteCommand(id: "add-ssh-items", title: LocalizedStringResource("Add SSH Files or Projects", table: "Interface"), systemImage: "network", shortcut: nil) {
                manager.chooseSSHItems()
            },
            PaletteCommand(id: "close-panel", title: LocalizedStringResource("Close Panel", table: "Interface"), systemImage: "xmark.square", shortcut: "⌘W") {
                manager.closeActivePanelOrWindow()
            },
            PaletteCommand(id: "save-file", title: LocalizedStringResource("Save File", table: "Interface"), systemImage: "square.and.arrow.down", shortcut: "⌘S") {
                manager.saveSelectedFile()
            },
            PaletteCommand(id: "show-files", title: LocalizedStringResource("File Manager", table: "Sidebar"), systemImage: "doc.text", shortcut: "⇧⌘E") {
                manager.showPanel(.files)
            },
            PaletteCommand(id: "show-git", title: LocalizedStringResource("Git Manager", table: "Sidebar"), systemImage: "arrow.triangle.branch", shortcut: "⇧⌘G") {
                manager.showPanel(.git)
            },
            PaletteCommand(id: "next-panel", title: LocalizedStringResource("Next Panel", table: "Interface"), systemImage: "arrow.right", shortcut: "⇧⌘]") {
                manager.selectNextPanel()
            },
            PaletteCommand(id: "prev-panel", title: LocalizedStringResource("Previous Panel", table: "Interface"), systemImage: "arrow.left", shortcut: "⇧⌘[") {
                manager.selectPreviousPanel()
            },
            PaletteCommand(id: "next-project", title: LocalizedStringResource("Next Project", table: "Interface"), systemImage: "arrow.right.square", shortcut: "⌥⌘]") {
                manager.selectNextProject()
            },
            PaletteCommand(id: "prev-project", title: LocalizedStringResource("Previous Project", table: "Interface"), systemImage: "arrow.left.square", shortcut: "⌥⌘[") {
                manager.selectPreviousProject()
            },
        ]

        if manager.selectedProject != nil {
            items.append(PaletteCommand(id: "show-projects", title: LocalizedStringResource("Projects", table: "Interface"), systemImage: DockItem.projects.symbol) {
                manager.showPanel(.projects)
            })
        }
        if !manager.canSaveSelectedFile { items.removeAll { $0.id == "save-file" } }

        if let project = manager.selectedProject {
            items.append(
                PaletteCommand(id: "close-project", title: LocalizedStringResource("Close Project: \(project.name)", table: "Interface"), systemImage: "folder.badge.minus") {
                    manager.close(project)
                }
            )
        }

        for (index, project) in manager.projects.enumerated() where project.id != manager.selectedProjectID {
            items.append(
                PaletteCommand(
                    id: "switch-project-\(project.id)",
                    title: LocalizedStringResource("Switch to Project: \(project.name)", table: "Interface"),
                    systemImage: "folder",
                    shortcut: index < 9 ? "⌘\(index + 1)" : nil
                ) {
                    manager.selectProject(index: index)
                }
            )
        }

        items.append(
            PaletteCommand(id: "settings", title: LocalizedStringResource("Settings…", table: "Interface"), systemImage: "gearshape", shortcut: "⌘,") {
                openSettings()
            }
        )
        return items
    }

    /// Every open terminal session across all projects, as a jump-to entry.
    /// The directory shows as a subtitle and the project name folds into the
    /// searchable text, so typing a repo or folder name finds its sessions.
    private var sessionCommands: [PaletteCommand] {
        manager.projects.flatMap { project in
            project.sessions.map { session in
                let directory = sessionDirectory(session)
                let search = [session.title, project.name, directory]
                    .compactMap { $0 }
                    .joined(separator: " ")
                return PaletteCommand(
                    id: "session-\(session.id)",
                    verbatimTitle: session.title,
                    systemImage: "terminal",
                    subtitle: directory,
                    section: .session,
                    searchText: search
                ) {
                    manager.revealSession(session)
                }
            }
        }
    }

    /// Tilde-abbreviated working directory for a session's subtitle, or nil
    /// when the shell hasn't reported one yet.
    private func sessionDirectory(_ session: TerminalSession) -> String? {
        guard let dir = session.workingDirectory else { return nil }
        let path = URL(string: dir)?.path ?? dir
        guard !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    /// The current project's pinned/automatic panel root. Indexing starts only
    /// after the user types, so opening ⌘P for a command stays filesystem-free.
    /// Home is excluded because it is an account boundary, not a project root.
    private var fileIndexContext: PanelContext? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let context = manager.selectedProject?.panelContext
        else { return nil }
        return context
    }

    private func stopLocalIndexWatcher() {
        watchedIndexTree?.setLocalFileEventsEnabled(false, member: indexWatcherMemberID)
        watchedIndexTree?.setLocalFileIndexGitDirectory(nil)
        watchedIndexTree = nil
    }

    private func updateLocalIndexWatcher() {
        let nextTree: FileTreeModel? = applicationIsActive && fileIndexContext?.isRemote == false
            ? manager.selectedProject?.fileTree : nil
        guard watchedIndexTree !== nextTree else { return }
        stopLocalIndexWatcher()
        watchedIndexTree = nextTree
        nextTree?.setLocalFileEventsEnabled(true, member: indexWatcherMemberID)
    }

    private var fileIndexKey: FileIndexKey? {
        guard let context = fileIndexContext else { return nil }
        return FileIndexKey(
            identity: context.identity,
            revision: context.connectionRevision,
            filesRevision: manager.selectedProject?.fileTree.contentRevision ?? 0,
            changeEvent: connectionChangeEvent
        )
    }

    private var filtered: [PaletteCommand] {
        let pattern = query.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return commands + sessionCommands }
        let fuzzyQuery = Self.fuzzyMatcher.prepare(pattern)
        var buffer = Self.fuzzyMatcher.makeBuffer()
        var items = matching(commands, fuzzyQuery, buffer: &buffer)
        items.append(contentsOf: matchingFiles(fuzzyQuery, buffer: &buffer))
        items.append(contentsOf: matching(sessionCommands, fuzzyQuery, buffer: &buffer))
        return items
    }

    /// Rank matches within one section. Concatenating the independently ranked
    /// sections above keeps their layout stable as the query changes.
    private func matching(
        _ commands: [PaletteCommand],
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> [PaletteCommand] {
        var matches: [(command: PaletteCommand, score: Double, order: Int)] = []
        matches.reserveCapacity(commands.count)
        for (order, command) in commands.enumerated() {
            guard let score = fuzzyScore(
                command.searchText ?? command.title,
                query,
                buffer: &buffer
            ) else { continue }
            matches.append((command, score, order))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.order < $1.order
        }
        return matches.map(\.command)
    }

    /// Search every indexed file but materialize only the strongest rows. This
    /// keeps a broad query responsive even in a large project.
    private func matchingFiles(
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> [PaletteCommand] {
        guard let indexedTarget, let indexedRoot, fileIndexKey == indexedTarget else { return [] }
        var best: [ScoredProjectFile] = []
        best.reserveCapacity(Self.maxFileResults)
        for file in projectFiles {
            guard let score = fileScore(file, query, buffer: &buffer) else {
                continue
            }
            let match = ScoredProjectFile(file: file, score: score)
            if best.count == Self.maxFileResults,
               let weakest = best.last,
               !ranksBefore(match, weakest) {
                continue
            }
            let index = insertionIndex(for: match, in: best)
            best.insert(match, at: index)
            if best.count > Self.maxFileResults {
                best.removeLast()
            }
        }
        return best.map { match in
            let file = match.file
            return PaletteCommand(
                id: "file-\(file.absolutePath)",
                verbatimTitle: file.name,
                systemImage: "doc",
                fileIconPath: file.absolutePath,
                subtitle: file.parentPath,
                section: .file,
                searchText: file.relativePath
            ) {
                guard let project = manager.selectedProject,
                      let context = project.panelContext,
                      project.matchesPanelTarget(indexedTarget.identity),
                      fileIndexKey == indexedTarget else { return }
                if context.isRemote {
                    guard let scope = indexedTarget.identity.workspace,
                          scope.hasPrefix("ssh:") else { return }
                    let host = String(scope.dropFirst(4))
                    Task { @MainActor in
                        guard context.cwd == indexedRoot,
                              !manager.isClosed,
                              manager.selectedProjectID == project.id,
                              project.matchesPanelTarget(indexedTarget.identity),
                              let stat = try? await context.backend.stat(path: file.absolutePath),
                              stat.isRegular,
                              !manager.isClosed,
                              manager.selectedProjectID == project.id,
                              project.matchesPanelTarget(indexedTarget.identity),
                              SSHHostWorkspaces.connectionRevision(for: host) == indexedTarget.revision
                        else { return }
                        project.openFile(file.absolutePath)
                    }
                } else {
                    project.openFile(file.absolutePath)
                }
            }
        }
    }

    /// Like editor file pickers, a basename match always outranks a match found
    /// only in the directory. Directory-qualified queries still fall back to
    /// scoring the complete project-relative path.
    private func fileScore(
        _ file: ProjectFile,
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> Double? {
        if let basenameScore = fuzzyScore(file.name, query, buffer: &buffer) {
            return 1 + basenameScore
        }
        return fuzzyScore(file.relativePath, query, buffer: &buffer)
    }

    private func insertionIndex(
        for match: ScoredProjectFile,
        in matches: [ScoredProjectFile]
    ) -> Int {
        var lowerBound = 0
        var upperBound = matches.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if ranksBefore(match, matches[middle]) {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }
        return lowerBound
    }

    private func ranksBefore(_ lhs: ScoredProjectFile, _ rhs: ScoredProjectFile) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.file.relativePath.localizedStandardCompare(rhs.file.relativePath)
            == .orderedAscending
    }

    /// Score via the library's prepared-query, reusable-buffer UTF-8 API. This
    /// avoids per-candidate lowercasing and heap allocation in the hot path.
    @inline(__always)
    private func fuzzyScore(
        _ candidate: String,
        _ query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> Double? {
        var candidate = candidate
        return candidate.withUTF8 { bytes in
            Self.fuzzyMatcher.score(
                utf8: bytes,
                against: query,
                buffer: &buffer
            )?.score
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Search commands, files, and sessions…", table: "Interface"), text: $query)
                    .accessibilityIdentifier("bailey.commandPalette.search")
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { handleEscapeFromKeyboard(); return .handled }
                    .onSubmit { runSelected() }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            // The field itself only claims its text-height slice of the row,
            // so the rest of the 44pt search bar would fall back to the arrow.
            .contentShape(.rect)
            .pointerStyle(.horizontalText)

            Divider()
                .opacity(0.5)

            if let indexIssue {
                Text(verbatim: indexIssue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            } else if indexLimited {
                Text(String(localized: "File index is incomplete; narrow the project to see more results.", table: "Interface"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
            results
                .pointerStyle(.default)
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: Theme.background))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
        .onAppear {
            query = ""
            selection = 0
            pointerSelectionController.reset()
            // Defer to the next runloop tick: assigning focus synchronously
            // inside the appearance pass can be dropped before the field
            // editor is ready, which left the palette opening unfocused.
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onChange(of: query) {
            updateLocalIndexWatcher()
            selection = 0
            // Filtering can rebuild a row under a stationary cursor and emit
            // mouseEntered even though the user never moved the pointer.
            pointerSelectionController.reset()
        }
    }

    /// Result list, computing `filtered` once per render. Headers remain
    /// present even when only one section matches, so the asynchronous file
    /// index cannot shift the rows by adding section chrome later.
    @ViewBuilder
    private var results: some View {
        let items = filtered
        let pattern = query.trimmingCharacters(in: .whitespaces)
        let highlightQuery = pattern.isEmpty ? nil : Self.fuzzyMatcher.prepare(pattern)
        if items.isEmpty {
            Text(String(localized: "No matches", table: "Interface"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, command in
                            if index == 0 || items[index - 1].section != command.section {
                                sectionHeader(command.section, isFirst: index == 0)
                            }
                            row(command, index: index, highlightQuery: highlightQuery)
                                .id(command.id)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 322)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selection) {
                    if items.indices.contains(selection) {
                        proxy.scrollTo(items[selection].id)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ section: PaletteSection, isFirst: Bool) -> some View {
        Text(section.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.top, isFirst ? 4 : 10)
            .padding(.bottom, 3)
    }

    private func row(
        _ command: PaletteCommand,
        index: Int,
        highlightQuery: FuzzyQuery?
    ) -> some View {
        let isSelected = index == selection
        return Button {
            run(command)
        } label: {
            HStack(spacing: 9) {
                if let fileIconPath = command.fileIconPath {
                    MaterialFileIconView(
                        path: fileIconPath,
                        size: 15,
                        opacity: isSelected ? 1 : 0.86
                    )
                    .frame(width: 16)
                } else {
                    Image(systemName: command.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color(nsColor: Theme.accent)) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                }
                Text(attributedTitle(command, highlightQuery: highlightQuery, isSelected: isSelected))
                    .lineLimit(1)
                if let subtitle = command.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 12)
                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bailey.commandPalette.result")
        .accessibilityValue(command.id)
        .modifier(RowHighlightStyle(
            isSelected: isSelected, listActive: searchFocused, cornerRadius: 6
        ))
        .background(
            PaletteRowPointerView(
                onEntered: {
                    if pointerSelectionController.acceptsPointerSelection {
                        selection = index
                    }
                },
                onMoved: {
                    if pointerSelectionController.acceptsPointerSelection {
                        selection = index
                    }
                }
            )
        )
    }

    /// Build title styling only for the visible rows. FuzzyMatch's traceback is
    /// intentionally separate from its allocation-free scorer, so running it
    /// here avoids paying that cost across the entire project index.
    private func attributedTitle(
        _ command: PaletteCommand,
        highlightQuery: FuzzyQuery?,
        isSelected: Bool
    ) -> AttributedString {
        var title = AttributedString(command.title)
        title.font = .system(size: 12.5)
        title.foregroundColor = isSelected ? .primary : .secondary
        guard command.section == .file,
              let highlightQuery
        else { return title }

        let ranges = filenameMatchRanges(for: command, query: highlightQuery)
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: title),
                  let upper = AttributedString.Index(range.upperBound, within: title)
            else { continue }
            title[lower..<upper].font = .system(size: 12.5, weight: .semibold)
            title[lower..<upper].foregroundColor = Color(nsColor: Theme.accent)
        }
        return title
    }

    /// Prefer a direct basename traceback. For a directory-qualified query,
    /// trace against the relative path and translate only the ranges that land
    /// inside its filename suffix.
    private func filenameMatchRanges(
        for command: PaletteCommand,
        query: FuzzyQuery
    ) -> [Range<String.Index>] {
        if let ranges = Self.fuzzyMatcher.highlight(command.title, against: query) {
            return ranges
        }
        guard let relativePath = command.searchText,
              relativePath.hasSuffix(command.title),
              let pathRanges = Self.fuzzyMatcher.highlight(relativePath, against: query)
        else { return [] }

        let filenameStart = relativePath.index(
            relativePath.endIndex,
            offsetBy: -command.title.count
        )
        return pathRanges.compactMap { pathRange in
            guard pathRange.upperBound > filenameStart else { return nil }
            let clippedLower = max(pathRange.lowerBound, filenameStart)
            let lowerOffset = relativePath.distance(from: filenameStart, to: clippedLower)
            let upperOffset = relativePath.distance(from: filenameStart, to: pathRange.upperBound)
            guard let lower = command.title.index(
                command.title.startIndex,
                offsetBy: lowerOffset,
                limitedBy: command.title.endIndex
            ),
            let upper = command.title.index(
                command.title.startIndex,
                offsetBy: upperOffset,
                limitedBy: command.title.endIndex
            ) else { return nil }
            return lower..<upper
        }
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func runSelected() {
        let items = filtered
        guard items.indices.contains(selection) else { return }
        run(items[selection])
    }

    private func run(_ command: PaletteCommand) {
        manager.dismissCommandPalette()
        command.action()
    }

    private func dismiss() {
        manager.dismissCommandPalette()
    }

    private func handleEscapeFromKeyboard() {
        if query.isEmpty {
            dismissFromKeyboard()
        } else {
            query = ""
        }
    }

    /// Escape reaches us as AppKit's `cancelOperation:`, which SwiftUI can
    /// dispatch inside a view-update pass — flipping the manager's published
    /// `isCommandPaletteVisible` there logs "Publishing changes from within
    /// view updates". Hop to the next runloop so the removal lands cleanly.
    /// (Return and backdrop taps arrive during normal event handling and can
    /// dismiss synchronously.)
    private func dismissFromKeyboard() {
        DispatchQueue.main.async { dismiss() }
    }

}

private struct PalettePointerEventMonitor: NSViewRepresentable {
    let controller: PalettePointerSelectionController

    func makeNSView(context: Context) -> PalettePointerMonitorNSView {
        let view = PalettePointerMonitorNSView()
        view.controller = controller
        return view
    }

    func updateNSView(_ nsView: PalettePointerMonitorNSView, context: Context) {
        nsView.controller = controller
    }

    static func dismantleNSView(
        _ nsView: PalettePointerMonitorNSView,
        coordinator: ()
    ) {
        nsView.detach()
    }
}

@MainActor
private final class PalettePointerMonitorNSView: NSView {
    weak var controller: PalettePointerSelectionController?
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
            [weak self, weak window] event in
            MainActor.assumeIsolated {
                guard window?.isKeyWindow == true else { return }
                self?.controller?.notePointerMoved()
            }
            return event
        }
    }

    func detach() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

/// AppKit distinguishes a genuine pointer move from the synthetic
/// `mouseEntered` generated when filtering places a new row under the cursor.
private struct PaletteRowPointerView: NSViewRepresentable {
    let onEntered: () -> Void
    let onMoved: () -> Void

    func makeNSView(context: Context) -> PaletteRowPointerNSView {
        let view = PaletteRowPointerNSView()
        view.onEntered = onEntered
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ nsView: PaletteRowPointerNSView, context: Context) {
        nsView.onEntered = onEntered
        nsView.onMoved = onMoved
    }
}

private final class PaletteRowPointerNSView: NSView {
    var onEntered: (() -> Void)?
    var onMoved: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .activeInKeyWindow,
                    .inVisibleRect,
                ],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        onEntered?()
    }

    override func mouseMoved(with event: NSEvent) {
        onMoved?()
    }
}
