//
//  FileViewerView.swift
//  kero
//

import AppKit
import Observation
import STTextView
import SwiftUI

/// A file opened as a tab in a project. Text content lives here (not in the
/// view) so edits survive tab switches.
@MainActor
@Observable
final class FileTab: nonisolated Identifiable {
    nonisolated let id = UUID()
    /// Mutable so a rename in the file tree can re-point the tab without
    /// tearing it down (the id — hence the editor and its state — is stable).
    private(set) var path: String {
        didSet { if path != oldValue { onSnapshotChange?() } }
    }
    @ObservationIgnored var onSnapshotChange: (() -> Void)?

    enum Content {
        case text
        case image(NSImage)
        case unavailable(String)
        /// Waiting for a consumer to request the first read.
        case loading
    }

    private(set) var content: Content
    /// Current editor text, written back by the editor on every edit. Not
    /// published: the editor owns display, this is only read back for saves.
    @ObservationIgnored var text: String
    /// The content as last loaded from or saved to disk. `isDirty` is the
    /// difference between this and `text`, so undoing edits back to it (or
    /// retyping the same characters) clears the dirty indicator rather than
    /// leaving it stuck on.
    @ObservationIgnored private var savedText = ""
    /// Scroll position and cursor, written back by the editor as they
    /// change. Lives here (not in the view) so the state survives tab
    /// switches, and in the session snapshot so it survives relaunches. Not
    /// published for the same reason as `text`.
    @ObservationIgnored var editorState = EditorState()

    private(set) var isDirty = false
    var saveError: String?
    /// Why this file cannot be written, or nil while it is writable. Set when
    /// the remote machine it lives on is no longer reachable.
    private(set) var readOnlyReason: String?
    /// Changes only when a clean tab picks up different bytes from disk. Text
    /// editors use this as their identity so an already-mounted pane is rebuilt
    /// with the new content while preserving its stored cursor/scroll state.
    private(set) var reloadRevision: UInt = 0

    /// The editor's scroll view while this file is on screen, so a pane-move
    /// drag can snapshot it for the drag thumbnail. Weak — owned by the mounted
    /// editor, nils out when the pane unmounts.
    @ObservationIgnored weak var editorView: NSView?
    @ObservationIgnored var editorCoordinator: SourceTextEditor.Coordinator?

    private nonisolated static let maxTextBytes = 5 << 20
    private nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "icns",
    ]
    @ObservationIgnored private var imageFingerprint: Int?
    @ObservationIgnored private var reloadGeneration: UInt = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// A previously requested read must resume after reconnect; restored tabs
    /// that no consumer has touched must remain lazy.
    @ObservationIgnored private var hasReadDemand = false
    /// Changes when a rename or remote reconnect changes the save target.
    /// An in-flight write must not claim to have saved a different target.
    @ObservationIgnored private var targetGeneration: UInt = 0
    @ObservationIgnored private var lastSaveTask: Task<Void, Never>?
    var isSaving: Bool { lastSaveTask != nil }
    @ObservationIgnored private var saveRequestGeneration: UInt = 0
    @ObservationIgnored var autoSaveSuspendedForClose = false
    /// The workspace this file lives on. The tab keeps its own, so it never
    /// follows the session onto another machine — and re-binds to a new
    /// connection to the same machine when one arrives.
    @ObservationIgnored private var backend: WorkspaceBackend
    /// The workspace this file belongs to: nil for this Mac, else the machine
    /// it was opened from. Part of the tab's identity, so the same path on two
    /// machines is two tabs, and a file opened locally is never read-only.
    let workspaceIdentity: String?

    private struct LoadedContent {
        let content: Content
        let text: String
        let imageFingerprint: Int?
    }

    init(
        path: String,
        backend: WorkspaceBackend,
        workspaceIdentity: String?
    ) {
        self.path = path
        // Files opened from a remote session keep reading and writing over
        // that connection even while the panels follow another session.
        self.backend = backend
        self.workspaceIdentity = workspaceIdentity
        content = .loading
        text = ""
    }

    // MARK: - Remote workspace

    func waitForText() async throws {
        loadIfNeeded()
        let generation = targetGeneration
        var readGeneration: UInt
        repeat {
            readGeneration = reloadGeneration
            await reloadTask?.value
        } while generation == targetGeneration && readOnlyReason == nil && readGeneration != reloadGeneration
        guard generation == targetGeneration, readOnlyReason == nil,
              case .text = content else {
            throw NSError(domain: "Kero.Editor", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "The file is unavailable or its workspace changed. Reopen it and try again.", table: "Editor")])
        }
    }

    func loadIfNeeded() {
        hasReadDemand = true
        guard reloadTask == nil else { return }
        switch content {
        case .loading, .unavailable: reloadFromDiskIfClean()
        case .text, .image: break
        }
    }

    func refreshWhenSelected() {
        hasReadDemand = true
        if readOnlyReason != nil, let workspaceIdentity {
            SSHHostWorkspaces.retryConnection(for: workspaceIdentity, path: path)
            return
        }
        if case .loading = content {
            loadIfNeeded()
        } else {
            reloadFromDiskIfClean()
        }
    }

    func appendText(_ suffix: String) {
        if editorCoordinator?.revision == reloadRevision, let textView {
            textView.breakUndoCoalescing()
            textView.insertText(suffix, replacementRange: NSRange(location: text.utf16.count, length: 0))
            textView.breakUndoCoalescing()
            text = textView.text ?? text
        } else {
            text += suffix
        }
        refreshDirtyState()
    }

    /// Re-checks this tab against the project's connections: adopts a live
    /// workspace for its own machine, or marks it read-only. Driven by the
    /// project rather than by the session the tab was opened from, because a
    /// user who reconnects in another terminal of the same project is
    /// reconnecting to the same machine.
    func reevaluateWorkspace(in project: Project) {
        guard let workspaceIdentity else { return }
        rebindWorkspace(to: project.connectedWorkspace(for: workspaceIdentity))
    }

    func rebindWorkspace(to live: WorkspaceBackend?) {
        guard let workspaceIdentity else { return }
        guard let live else {
            setReadOnly(true, destination: workspaceIdentity)
            return
        }
        guard readOnlyReason != nil || (backend as AnyObject) !== (live as AnyObject) else { return }
        if readOnlyReason == nil {
            targetGeneration &+= 1
            invalidateReload()
        }
        // A reconnection is a new channel; reading or saving over the old one
        // fails, so the tab takes the live one.
        backend = live
        setReadOnly(false, destination: workspaceIdentity)
        // Previously requested content must recover even without a new
        // onAppear; an unconsumed restored tab must not start remote IO.
        if hasReadDemand { reloadFromDiskIfClean() }
    }

    private func setReadOnly(_ isReadOnly: Bool, destination: String) {
        let reason = isReadOnly
            ? String(
                localized: "Disconnected from \(destination) — read-only until reconnected", table: "Workspace",
                comment: "Editor banner. The placeholder is a remote machine as user@host."
            )
            : nil
        guard readOnlyReason != reason else { return }
        targetGeneration &+= 1
        invalidateReload()
        readOnlyReason = reason
        if let reason, case .loading = content { content = .unavailable(reason) }
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    /// Tab strip and switcher label. A remote file says which machine it is
    /// on; a local file reads exactly as it always has.
    var tabTitle: String {
        guard let workspaceIdentity else { return name }
        return "\(workspaceIdentity): \(name)"
    }

    /// Re-points this tab at a new location after the file (or a directory
    /// above it) was renamed on disk. An initial read follows the new path;
    /// loaded buffers and subsequent saves retain their content.
    func updatePath(_ newPath: String) {
        guard newPath != path else { return }
        let wasReading = reloadTask != nil
        invalidateReload()
        targetGeneration &+= 1
        path = newPath
        if wasReading { loadIfNeeded() }
    }

    /// Recompute `isDirty` from the current `text` against the saved
    /// baseline. Called after every editor change (including undo/redo), so
    /// reverting to the saved content clears the dirty state.
    func refreshDirtyState() {
        let dirty: Bool
        if case .text = content {
            dirty = !text.utf8.elementsEqual(savedText.utf8)
        } else {
            dirty = false
        }
        if isDirty != dirty {
            isDirty = dirty
            if dirty {
                // A read started while the buffer was clean must never replace
                // an edit that happened before that read completed.
                invalidateReload()
            }
        }
    }

    /// A focus transition schedules one save, never a timed file-write loop.
    func autoSaveOnFocusLoss() {
        guard isDirty, !autoSaveSuspendedForClose else { return }
        Task { await save() }
    }

    /// Serialize manual and focus-triggered writes. A later edit can never
    /// land on disk before an older in-flight write completes.
    func save() async {
        saveRequestGeneration &+= 1
        let generation = saveRequestGeneration
        let preceding = lastSaveTask
        let task = Task { [weak self] in
            await preceding?.value
            await self?.writeCurrentText()
        }
        lastSaveTask = task
        await task.value
        if saveRequestGeneration == generation { lastSaveTask = nil }
    }

    private func writeCurrentText() async {
        guard case .text = content, isDirty else { return }
        // Refused, not silently dropped: the save-error bar says why.
        if let readOnlyReason {
            saveError = readOnlyReason
            return
        }
        invalidateReload()
        let written = text
        let savedPath = path
        let generation = targetGeneration
        let target = backend
        do {
            try await target.write(path: savedPath, data: Data(written.utf8))
            guard generation == targetGeneration else { return }
            savedText = written
            // An edit landing while the write was in flight stays dirty.
            refreshDirtyState()
            saveError = nil
        } catch {
            guard generation == targetGeneration else { return }
            saveError = error.localizedDescription
        }
    }

    /// Re-read a clean preview when it returns on screen. Disk I/O happens off
    /// the main actor; generation/path/dirty guards keep an older read from
    /// winning over a rename, save, or edit performed while it was in flight.
    func reloadFromDiskIfClean() {
        // While the file's machine is unreachable a read can only fail, and
        // replacing the content with "Could not read file" would throw away
        // what the user was looking at. The banner already says why.
        guard readOnlyReason == nil, !isDirty else { return }
        hasReadDemand = true
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let expectedPath = path

        let backend = self.backend
        reloadTask = Task { [weak self] in
            defer {
                if self?.reloadGeneration == generation { self?.reloadTask = nil }
            }
            let loaded: LoadedContent
            do {
                let (data, decoded) = try await Self.readContent(path: expectedPath, backend: backend)
                loaded = Self.loadedContent(path: expectedPath, data: data, decoded: decoded)
            } catch {
                let reason: String
                if case WorkspaceError.tooLarge = error {
                    reason = String(localized: "File is too large to open", table: "Workspace")
                } else {
                    reason = String(localized: "Could not read file", table: "Workspace")
                }
                loaded = LoadedContent(content: .unavailable(reason), text: "", imageFingerprint: nil)
            }
            guard !Task.isCancelled,
                  let self,
                  self.reloadGeneration == generation,
                  !self.isDirty,
                  // The connection may have dropped while this read was in
                  // flight; its failure must not become the tab's content.
                  self.readOnlyReason == nil
            else { return }

            guard !self.matches(loaded) else { return }
            self.editorCoordinator = nil
            self.content = loaded.content
            self.text = loaded.text
            self.savedText = loaded.text
            self.imageFingerprint = loaded.imageFingerprint
            self.saveError = nil
            self.reloadRevision &+= 1
        }
    }

    private func invalidateReload() {
        reloadTask?.cancel()
        reloadTask = nil
        reloadGeneration &+= 1
    }

    private func matches(_ loaded: LoadedContent) -> Bool {
        switch (content, loaded.content) {
        case (.text, .text):
            return savedText.utf8.elementsEqual(loaded.text.utf8)
        case (.image, .image):
            return imageFingerprint == loaded.imageFingerprint
        case (.unavailable(let current), .unavailable(let new)):
            return current == new
        default:
            return false
        }
    }

    @concurrent private static func readContent(
        path: String, backend: WorkspaceBackend
    ) async throws -> (Data, String?) {
        let isImage = imageExtensions.contains((path as NSString).pathExtension.lowercased())
        let data = try await backend.read(path: path, maxBytes: isImage ? .max : maxTextBytes)
        return (data, data.count <= maxTextBytes ? String(data: data, encoding: .utf8) : nil)
    }

    private static func loadedContent(path: String, data: Data, decoded: String?) -> LoadedContent {
        let url = URL(fileURLWithPath: path)
        if imageExtensions.contains(url.pathExtension.lowercased()),
           let image = NSImage(data: data) {
            return LoadedContent(
                content: .image(image),
                text: "",
                imageFingerprint: data.hashValue
            )
        }
        guard data.count <= maxTextBytes else {
            return LoadedContent(
                content: .unavailable(String(localized: "File is too large to open", table: "Workspace")),
                text: "",
                imageFingerprint: nil
            )
        }
        guard let string = decoded else {
            return LoadedContent(
                content: .unavailable(String(localized: "Binary file", table: "Workspace")),
                text: "",
                imageFingerprint: nil
            )
        }
        return LoadedContent(content: .text, text: string, imageFingerprint: nil)
    }
}

/// Content of a file tab: an STTextView editor (line numbers, system find
/// bar), an image preview, or a placeholder for anything binary or
/// oversized.
struct FileViewerView: View {
    let file: FileTab
    /// Whether this file's work tab is selected.
    var isFocused: Bool = true
    /// Called when the editor takes focus itself (e.g. a click), so the
    /// selected work tab can follow.
    var onFocused: () -> Void = {}

    private let settings = AppSettings.shared
    private let themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = themeChanges.revision
        Group {
            switch file.content {
            case .text:
                VStack(spacing: 0) {
                    if let reason = file.readOnlyReason {
                        RemoteReadOnlyBanner(message: reason)
                            .frame(height: 22)
                    }
                    if let error = file.saveError {
                        saveErrorBar(error)
                    }
                    SourceTextEditor(
                        file: file,
                        font: TerminalFont.current(),
                        palette: .theme(dark: colorScheme == .dark),
                        wrapLines: settings.wrapLines,
                        isFocused: isFocused,
                        onFocused: onFocused
                    )
                    .id(file.reloadRevision)
                }
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .padding(16)
                }
            case .loading:
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let reason):
                VStack(spacing: 8) {
                    MaterialFileIconView(path: file.path, size: 28, opacity: 0.72)
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            file.refreshWhenSelected()
        }
        // The selected file view stays mounted while Kero is inactive, so
        // returning from an external editor does not trigger `onAppear`.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            if file.readOnlyReason == nil { file.refreshWhenSelected() }
        }
        // A window can become key without the app itself transitioning from
        // inactive (for example when moving between Kero windows).
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { _ in
            if file.readOnlyReason == nil { file.refreshWhenSelected() }
        }
    }

    private func saveErrorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(String(localized: "Could not save: \(message)", table: "Editor"))
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(red: 0.82, green: 0.60, blue: 0.13))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
    }
}
