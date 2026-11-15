import AppKit
import Darwin
import ImageIO
import Observation
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
    /// The tab owns the one writable native document, even before any view is mounted.
    /// Only explicit full-content consumers materialize its Swift String.
    @ObservationIgnored private(set) var nativeTextStorage = NSTextStorage()
    @ObservationIgnored private(set) var nativeContentStorage = NSTextContentStorage()
    @ObservationIgnored private var nativeCodeUnitDelta: [UInt16: Int]? = [:]
    @ObservationIgnored private var nativeEditObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pendingStorageChange = false
    @ObservationIgnored private var pendingStorageChangeCheck = false
    @ObservationIgnored var text: String {
        get { nativeTextStorage.string }
        set {
            nativeTextStorage.setAttributedString(NSAttributedString(string: newValue))
            nativeCodeUnitDelta = nil
            pendingStorageChange = false
            refreshDirtyState()
        }
    }
    /// The content as last loaded from or saved to disk. `isDirty` is the
    /// difference between this and `text`, so undoing edits back to it (or
    /// retyping the same characters) clears the dirty indicator rather than
    /// leaving it stuck on.
    @ObservationIgnored private var savedText = ""
    /// Actual source bytes, not a re-encoding of decoded or normalized text.
    @ObservationIgnored private var savedSourceVersion: WorkspaceFileVersion?
    /// Scroll position and cursor, written back by the editor as they
    /// change. Lives here (not in the view) so the state survives tab
    /// switches, and in the session snapshot so it survives relaunches. Not
    /// published for the same reason as `text`.
    @ObservationIgnored var editorState = EditorState()

    private(set) var isDirty = false
    private(set) var fileEncoding = TextFileEncoding.utf8
    @ObservationIgnored private var preferredEncoding: TextFileEncoding?
    var saveError: String?
    private(set) var reloadError: String?
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
    @ObservationIgnored var preparedLineWidths: (font: NSFont, widths: NativeMeasuredLineWidths.Prepared)?

    /// A true close or accepted replacement releases the old native document,
    /// independently of any cached SwiftUI/AppKit view lifetime.
    func retireNativeEditor() {
        if let nativeEditObserver {
            NotificationCenter.default.removeObserver(nativeEditObserver)
            self.nativeEditObserver = nil
        }
        let coordinator = editorCoordinator
        editorCoordinator = nil
        editorView = nil
        preparedLineWidths = nil
        coordinator?.retireObsoleteDocument()
        nativeTextStorage.setAttributedString(NSAttributedString(string: ""))
        savedText = ""
        savedSourceVersion = nil
        pendingStorageChange = false
        nativeCodeUnitDelta = [:]
    }

    private func installNativeDocument(_ text: String) {
        let storage = NSTextStorage(string: text)
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = storage
        nativeTextStorage = storage
        nativeContentStorage = contentStorage
        observeNativeEdits()
    }

    private func observeNativeEdits() {
        let identity = ObjectIdentifier(nativeTextStorage)
        nativeEditObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: nativeTextStorage, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, ObjectIdentifier(self.nativeTextStorage) == identity,
                      self.nativeTextStorage.editedMask.contains(.editedCharacters) else { return }
                self.nativeStorageDidChange()
            }
        }
    }

    /// Direct offscreen storage edits must not be invisible to dirty state.
    /// A mounted editor supplies the exact old/new range later in this same
    /// notification; only direct edits require one deferred full reconciliation.
    private func nativeStorageDidChange() {
        guard case .text = content else { return }
        preparedLineWidths = nil
        pendingStorageChange = true
        if !isDirty {
            isDirty = true
            invalidateReload()
        }
        guard !pendingStorageChangeCheck else { return }
        pendingStorageChangeCheck = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingStorageChangeCheck = false
            guard self.pendingStorageChange else { return }
            self.pendingStorageChange = false
            self.nativeCodeUnitDelta = nil
            self.refreshDirtyState()
        }
    }

    isolated deinit {
        if let nativeEditObserver { NotificationCenter.default.removeObserver(nativeEditObserver) }
    }

    private nonisolated static let maxTextBytes = 32 << 20
    private nonisolated static let maxImageBytes = 256 << 20
    private nonisolated static let maxImagePixels = 32_000_000
    private nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "icns",
    ]
    @ObservationIgnored private var imageFingerprint: Int?
    @ObservationIgnored private var reloadGeneration: UInt = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    /// A previously requested read must resume after reconnect; restored tabs
    /// that no consumer has touched must remain lazy.
    @ObservationIgnored private var hasReadDemand = false
    /// Changes when a rename or remote reconnect changes the save target.
    /// An in-flight write must not claim to have saved a different target.
    @ObservationIgnored private var targetGeneration: UInt = 0
    @ObservationIgnored private var lastSaveTask: Task<Void, Never>?
    @ObservationIgnored private var saveLatestRequested = false
    /// Encoding changes are explicit user actions, never merged or silently dropped.
    @ObservationIgnored private var pendingEncodingSaves: [TextFileEncoding] = []
    @ObservationIgnored private var fileMutationHeld = false
    @ObservationIgnored private var saveDeferredUntilMutation = false
    @ObservationIgnored private var deletedFromWorkspace = false
    var isSaving: Bool { lastSaveTask != nil }
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
        let encoding: TextFileEncoding?
        let imageFingerprint: Int?
        let decodingFailed: Bool
        let sourceVersion: WorkspaceFileVersion?
    }

    func reopen(using encoding: TextFileEncoding?) {
        guard !isDirty, !isSaving, !fileMutationHeld else {
            saveError = String(localized: "Save or discard edits before changing encoding.", table: "Editor")
            return
        }
        preferredEncoding = encoding
        reloadFromDiskIfClean()
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
        nativeContentStorage.textStorage = nativeTextStorage
        observeNativeEdits()
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
            throw NSError(domain: "Bailey.Editor", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "The file is unavailable or its workspace changed. Reopen it and try again.", table: "Editor")])
        }
    }

    func waitForTextBeforeAppending() async throws {
        if case .text = content, !isDirty, reloadTask == nil {
            reloadFromDiskIfClean()
        }
        try await waitForText()
        if let reloadError {
            throw NSError(domain: "Bailey.Editor", code: 3, userInfo: [
                NSLocalizedDescriptionKey: reloadError,
            ])
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
        } else if reloadTask != nil {
            refreshPending = true
        } else {
            reloadFromDiskIfClean()
        }
    }

    /// Read only the relevant native characters, never construct a whole
    /// multi-megabyte Swift String just to choose a line-ending separator.
    func lineEndingForAppend() -> (newline: String, separator: String) {
        let source = nativeTextStorage.mutableString
        let newline = source.range(of: "\r\n").location == NSNotFound ? "\n" : "\r\n"
        let separator = source.length == 0 || source.character(at: source.length - 1) == 10
            ? "" : newline
        return (newline, separator)
    }

    /// Sample only a bounded UTF-16 region from the authoritative document.
    func previewExcerpt(aroundUTF16 location: Int?, maxCodeUnits: Int = 7_000)
        -> (text: String, startsInsideLine: Bool) {
        let source = nativeTextStorage.mutableString
        guard source.length > 0 else { return ("", false) }
        let center = min(max(0, location ?? 0), source.length)
        let start = max(0, center - (location == nil ? 0 : 1_200))
        let length = min(maxCodeUnits, source.length - start)
        return (source.substring(with: NSRange(location: start, length: length)), start > 0)
    }

    func appendText(_ suffix: String) {
        guard !suffix.isEmpty else { return }
        if editorCoordinator?.revision == reloadRevision,
           editorCoordinator?.appendText(suffix) == true { return }
        let range = NSRange(location: nativeTextStorage.length, length: 0)
        nativeTextStorage.replaceCharacters(in: range, with: suffix)
        recordNativeReplacement(at: range, removing: "", inserting: suffix)
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
        guard !deletedFromWorkspace, let workspaceIdentity else { return }
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
        editorCoordinator?.updateSyntaxHighlighting(for: newPath)
        if wasReading { loadIfNeeded() }
    }

    /// A changed UTF-16 frequency proves the bytes differ. Equal frequencies
    /// are only a filter: reorders and canonically equivalent text must still
    /// be checked byte-for-byte before clearing the dirty state.
    func recordNativeReplacement(at range: NSRange, removing old: String, inserting new: String) {
        pendingStorageChange = false
        guard nativeCodeUnitDelta != nil else { return }
        adjustNativeDelta(old, by: -1)
        adjustNativeDelta(new, by: 1)
    }

    func nativeTextChangedWithoutReplacement() {
        pendingStorageChange = false
        nativeCodeUnitDelta = nil
    }

    private func adjustNativeDelta(_ string: String, by direction: Int) {
        guard var delta = nativeCodeUnitDelta else { return }
        for unit in string.utf16 {
            let count = (delta[unit] ?? 0) + direction
            if count == 0 { delta.removeValue(forKey: unit) }
            else { delta[unit] = count }
        }
        nativeCodeUnitDelta = delta
    }

    /// Known local edits update the small delta; untracked native Undo/IME
    /// changes require a strict comparison, not a 32 MiB dictionary rebuild.
    func refreshDirtyState() {
        let dirty: Bool
        if case .text = content {
            if nativeTextStorage.length != (savedText as NSString).length
                || nativeCodeUnitDelta?.isEmpty == false {
                dirty = true
            } else {
                dirty = !TextFileEncoding.hasIdenticalCodeUnits(nativeTextStorage.string, savedText)
                if !dirty { nativeCodeUnitDelta = [:] }
            }
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
        if lastSaveTask != nil {
            saveLatestRequested = true
        } else {
            Task { [weak self] in await self?.save() }
        }
    }

    /// Hold the original save target stable until all queued writes have completed.
    func beginFileMutation() async -> Bool {
        guard !fileMutationHeld, !autoSaveSuspendedForClose else { return false }
        fileMutationHeld = true
        await lastSaveTask?.value
        if isDirty { await writeCurrentText() }
        guard !isDirty, saveError == nil else {
            endFileMutation()
            return false
        }
        return true
    }

    func endFileMutation() {
        guard fileMutationHeld else { return }
        fileMutationHeld = false
        let needsSave = saveDeferredUntilMutation
        saveDeferredUntilMutation = false
        if needsSave { Task { await save() } }
    }

    /// Preserve an in-flight edit without allowing late saves to recreate the deleted path.
    func invalidateDeletedFile() {
        deletedFromWorkspace = true
        targetGeneration &+= 1
        invalidateReload()
        readOnlyReason = String(localized: "This file was deleted. Copy your edits before closing.", table: "Editor")
    }

    /// One owned writer drains requests. Repeated ordinary saves only request
    /// the latest edit; explicit encoding changes retain their own intent.
    func save(as encoding: TextFileEncoding? = nil) async {
        if fileMutationHeld {
            if encoding != nil {
                saveError = String(localized: "Cannot change encoding during a file operation.", table: "Editor")
                return
            }
            saveDeferredUntilMutation = true
            return
        }
        if let running = lastSaveTask {
            if let encoding { pendingEncodingSaves.append(encoding) }
            else { saveLatestRequested = true }
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            var intent = encoding
            while true {
                await self.writeCurrentText(as: intent)
                if !self.pendingEncodingSaves.isEmpty {
                    intent = self.pendingEncodingSaves.removeFirst()
                    self.saveLatestRequested = false
                } else if self.saveLatestRequested {
                    self.saveLatestRequested = false
                    intent = nil
                } else {
                    break
                }
            }
            self.lastSaveTask = nil
        }
        lastSaveTask = task
        await task.value
    }

    private func writeCurrentText(as encoding: TextFileEncoding? = nil) async {
        guard case .text = content, isDirty || (encoding != nil && encoding != fileEncoding) else { return }
        if let readOnlyReason {
            saveError = readOnlyReason
            return
        }
        guard reloadError == nil else { return }
        guard let expected = savedSourceVersion else {
            saveError = String(localized: "Original file bytes are unknown. Reopen before saving.",
                               table: "Editor")
            return
        }
        // Freeze one real revision before leaving the main actor. Subsequent
        // edits stay live in NSTextStorage and are rebased after publication.
        let written = text
        let deltaAtWrite = nativeCodeUnitDelta
        let chosen = encoding ?? fileEncoding
        let savedPath = path
        let generation = targetGeneration
        let target = backend
        let prepared = await TextFileEncoding.prepareSave(
            written, as: chosen, checkDeclaration: chosen != fileEncoding
        )
        guard generation == targetGeneration, path == savedPath,
              readOnlyReason == nil else { return }
        let payload: TextFileEncoding.EncodedSave
        switch prepared {
        case .failure(.contradictsDeclaration):
            saveError = String(localized:
                "Update the declared coding header before changing the file encoding.",
                table: "Editor")
            return
        case .failure(.cannotRoundTrip):
            saveError = String(localized:
                "Text cannot be saved in \(chosen.name) without losing characters.", table: "Editor")
            return
        case .success(let encoded):
            payload = encoded
        }
        guard payload.bytes.count <= Self.maxTextBytes else {
            saveError = String(localized:
                "Text exceeds the 32 MiB file limit. Reduce its size before saving.", table: "Editor")
            return
        }
        invalidateReload()
        do {
            try await target.write(path: savedPath, data: payload.bytes, ifUnchanged: expected)
            guard generation == targetGeneration else { return }
            acceptPublishedText(written, encoding: chosen, wasExplicit: encoding != nil,
                                version: payload.version, deltaAtWrite: deltaAtWrite)
        } catch {
            guard generation == targetGeneration else { return }
            if case WorkspaceError.changedExternally = error {
                saveError = String(localized:
                    "The file changed outside Bailey. Your edits remain unsaved.", table: "Editor")
                return
            }
            // A transport error may mean the remote rename completed but its
            // acknowledgement was lost. Resolve the actual bytes once, without
            // attempting another write or destroying the local draft.
            let actual = try? await target.read(path: savedPath, maxBytes: payload.bytes.count)
            guard generation == targetGeneration else { return }
            if let actual, payload.version.matches(actual) {
                acceptPublishedText(written, encoding: chosen, wasExplicit: encoding != nil,
                                    version: payload.version, deltaAtWrite: deltaAtWrite)
            } else {
                saveError = error.localizedDescription
            }
        }
    }

    private func acceptPublishedText(
        _ written: String, encoding: TextFileEncoding, wasExplicit: Bool,
        version: WorkspaceFileVersion, deltaAtWrite: [UInt16: Int]?
    ) {
        fileEncoding = encoding
        if wasExplicit { preferredEncoding = encoding }
        savedText = written
        savedSourceVersion = version
        // Edits landing during I/O still belong to the next revision.
        if let deltaAtWrite, nativeCodeUnitDelta != nil {
            for (unit, count) in deltaAtWrite {
                let updated = (nativeCodeUnitDelta?[unit] ?? 0) - count
                if updated == 0 { nativeCodeUnitDelta?.removeValue(forKey: unit) }
                else { nativeCodeUnitDelta?[unit] = updated }
            }
        }
        refreshDirtyState()
        saveError = nil
        reloadError = nil
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
        refreshPending = false
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let expectedPath = path

        let backend = self.backend
        reloadTask = Task { [weak self] in
            defer {
                if let self, self.reloadGeneration == generation {
                    self.reloadTask = nil
                    if self.refreshPending {
                        self.refreshPending = false
                        self.reloadFromDiskIfClean()
                    }
                }
            }
            let loaded: LoadedContent
            do {
                let (data, decoded, sourceVersion) = try await Self.readContent(
                    path: expectedPath, backend: backend, override: self?.preferredEncoding
                )
                loaded = Self.loadedContent(path: expectedPath, data: data,
                                            decoded: decoded, sourceVersion: sourceVersion)
            } catch {
                let missingOrOversized: Bool
                switch error {
                case WorkspaceError.notFound, WorkspaceError.tooLarge: missingOrOversized = true
                default: missingOrOversized = false
                }
                if !missingOrOversized, let self,
                   self.reloadGeneration == generation, !self.isDirty, self.readOnlyReason == nil {
                    switch self.content {
                    case .text, .image:
                        self.reloadError = String(
                            localized: "Could not refresh file; showing last loaded content.",
                            table: "Editor"
                        )
                        return
                    case .loading, .unavailable: break
                    }
                }
                let reason: String
                if case WorkspaceError.tooLarge = error {
                    reason = String(localized: "File is too large to open", table: "Workspace")
                } else {
                    reason = String(localized: "Could not read file", table: "Workspace")
                }
                loaded = LoadedContent(content: .unavailable(reason), text: "",
                                       encoding: nil, imageFingerprint: nil,
                                       decodingFailed: false, sourceVersion: nil)
            }
            guard !Task.isCancelled,
                  let self,
                  self.reloadGeneration == generation,
                  !self.isDirty,
                  // The connection may have dropped while this read was in
                  // flight; its failure must not become the tab's content.
                  self.readOnlyReason == nil
            else { return }

            if loaded.decodingFailed, case .unavailable(let reason) = loaded.content {
                switch self.content {
                case .text, .image:
                    self.reloadError = reason
                    return
                case .loading, .unavailable:
                    break
                }
            }
            self.reloadError = nil
            self.saveError = nil
            if self.matches(loaded) {
                // Reload can accept changed bytes without changing decoded text.
                self.savedSourceVersion = loaded.sourceVersion
                return
            }
            // First-frame horizontal extent must use the actual font width,
            // but shaping a large document must never block the main actor.
            var prepared: (font: NSFont, widths: NativeMeasuredLineWidths.Prepared)?
            if case .text = loaded.content, !AppSettings.shared.wrapLines {
                let font = TerminalFont.current()
                if let descriptorData = try? NSKeyedArchiver.archivedData(
                    withRootObject: font.fontDescriptor, requiringSecureCoding: true
                ), let widths = await NativeMeasuredLineWidths.prepareAsync(
                    loaded.text, descriptorData: descriptorData, fontSize: font.pointSize,
                    tabInterval: NativeCodeTextView.tabInterval
                ) {
                    prepared = (font, widths)
                }
            }
            guard !Task.isCancelled, self.reloadGeneration == generation,
                  !self.isDirty, self.readOnlyReason == nil else { return }
            self.retireNativeEditor()
            self.content = loaded.content
            if let encoding = loaded.encoding { self.fileEncoding = encoding }
            self.installNativeDocument(loaded.text)
            self.preparedLineWidths = prepared
            self.savedText = loaded.text
            self.savedSourceVersion = loaded.sourceVersion
            self.nativeCodeUnitDelta = [:]
            self.imageFingerprint = loaded.imageFingerprint
            self.reloadRevision &+= 1
        }
    }

    private func invalidateReload() {
        refreshPending = false
        reloadTask?.cancel()
        reloadTask = nil
        reloadGeneration &+= 1
    }

    private func matches(_ loaded: LoadedContent) -> Bool {
        switch (content, loaded.content) {
        case (.text, .text):
            return fileEncoding == loaded.encoding && TextFileEncoding.hasIdenticalCodeUnits(savedText, loaded.text)
        case (.image, .image):
            return imageFingerprint == loaded.imageFingerprint
        case (.unavailable(let current), .unavailable(let new)):
            return current == new
        default:
            return false
        }
    }

    @concurrent private static func readContent(
        path: String, backend: WorkspaceBackend, override: TextFileEncoding?
    ) async throws -> (Data, Result<TextFileEncoding.Document, TextFileEncoding.DecodeFailure>?, WorkspaceFileVersion?) {
        guard !path.utf8.contains(0) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let isImage = imageExtensions.contains((path as NSString).pathExtension.lowercased())
        if isImage, let info = try await backend.stat(path: path), info.size > maxTextBytes {
            guard (info.isRegular || info.isSymlink), info.size <= maxImageBytes else {
                throw WorkspaceError.tooLarge
            }
            // A renamed text file must not make us read hundreds of MiB before
            // discovering it is not an image. Check a bounded real header.
            let probe = try await backend.runLimited(
                argv: ["/usr/bin/head", "-c", "65536", "--", path],
                cwd: nil, env: nil, stdin: nil, timeout: 25,
                stdoutLimit: 65_536, stderrLimit: 16_384)
            guard probe.status == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
            let source = CGImageSourceCreateIncremental(nil)
            CGImageSourceUpdateData(source, probe.stdout as CFData, false)
            guard CGImageSourceGetType(source) != nil else { throw WorkspaceError.tooLarge }
            // Never use .max: the path may grow between stat and the actual read.
            let data = try await backend.read(path: path, maxBytes: info.size)
            guard data.count > maxTextBytes else {
                return (data, await TextFileEncoding.decode(data, backend: backend,
                                                             override: override), WorkspaceFileVersion(data: data))
            }
            return (data, nil, nil)
        }
        let data = try await backend.read(path: path, maxBytes: maxTextBytes)
        return (data, await TextFileEncoding.decode(data, backend: backend, override: override),
                WorkspaceFileVersion(data: data))
    }

    private static func loadedContent(
        path: String, data: Data,
        decoded: Result<TextFileEncoding.Document, TextFileEncoding.DecodeFailure>?,
        sourceVersion: WorkspaceFileVersion?
    ) -> LoadedContent {
        let url = URL(fileURLWithPath: path)
        if imageExtensions.contains(url.pathExtension.lowercased()),
           let source = CGImageSourceCreateWithData(data as CFData,
                                                    [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetType(source) != nil {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            let width = (properties?[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
            ]
            guard width > 0, height > 0, width <= maxImagePixels / height,
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                                      thumbnailOptions as CFDictionary) else {
                return LoadedContent(
                    content: .unavailable(String(localized: "Image is too large or invalid", table: "Workspace")),
                    text: "", encoding: nil, imageFingerprint: nil, decodingFailed: false,
                    sourceVersion: nil
                )
            }
            let image = NSImage(size: NSSize(width: thumbnail.width, height: thumbnail.height))
            image.addRepresentation(NSBitmapImageRep(cgImage: thumbnail))
            return LoadedContent(
                content: .image(image), text: "", encoding: nil,
                imageFingerprint: data.hashValue, decodingFailed: false, sourceVersion: nil
            )
        }
        guard data.count <= maxTextBytes else {
            return LoadedContent(
                content: .unavailable(String(localized: "File is too large to open", table: "Workspace")),
                text: "", encoding: nil,
                imageFingerprint: nil, decodingFailed: false, sourceVersion: nil
            )
        }
        guard let decoded else { preconditionFailure("Text input was not decoded") }
        switch decoded {
        case .success(let document):
            return LoadedContent(content: .text, text: document.text,
                                 encoding: document.encoding, imageFingerprint: nil,
                                 decodingFailed: false, sourceVersion: sourceVersion)
        case .failure(let failure):
            let unknownTextEncoding: Bool
            if case .binary = failure { unknownTextEncoding = false }
            else { unknownTextEncoding = true }
            return LoadedContent(content: .unavailable(failure.message), text: "",
                                 encoding: nil, imageFingerprint: nil,
                                 decodingFailed: unknownTextEncoding, sourceVersion: nil)
        }
    }
}

/// Weakly tracks the actual AppKit window for every file content type,
/// including images that do not mount a native text editor.
@MainActor
private final class FileWindowReference {
    weak var view: NSView?
    var window: NSWindow? { view?.window }
}

private struct FileWindowReader: NSViewRepresentable {
    let reference: FileWindowReference

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        reference.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        reference.view = view
    }
}

/// Content of a file tab: a native NSTextView editor (line numbers, system find
/// bar), an image preview, or a placeholder for anything binary or
/// oversized.
struct FileViewerView: View {
    let file: FileTab
    /// Whether this file is visible in the foreground active Dock group.
    var isFocused: Bool = true
    var canFocus: () -> Bool = { true }
    /// Called when the editor takes focus itself (e.g. a click), so the
    /// selected work tab can follow.
    var onFocused: () -> Void = {}

    private let settings = AppSettings.shared
    private let themeChanges = Theme.changes
    @State private var windowReference = FileWindowReference()
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
                    if let error = file.reloadError {
                        errorBar(error)
                    }
                    if let error = file.saveError {
                        errorBar(String(localized: "Could not save: \(error)", table: "Editor"))
                    }
                    HStack {
                        Spacer()
                        encodingMenu
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 23)
                    SourceTextEditor(
                        file: file,
                        font: TerminalFont.current(),
                        palette: .theme(dark: colorScheme == .dark),
                        wrapLines: settings.wrapLines,
                        longLineDisplayWidth: settings.longLineDisplayWidth,
                        isFocused: isFocused,
                        canFocus: canFocus,
                        onFocused: onFocused
                    )
                    .id(file.reloadRevision)
                }
            case .image(let image):
                VStack(spacing: 0) {
                    if let error = file.reloadError {
                        errorBar(error)
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .padding(16)
                    }
                }
            case .loading:
                Color.clear
            case .unavailable(let reason):
                VStack(spacing: 8) {
                    MaterialFileIconView(path: file.path, size: 28, opacity: 0.72)
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    encodingMenu
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FileWindowReader(reference: windowReference).frame(width: 0, height: 0))
        .onAppear {
            file.refreshWhenSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard notification.object as? NSWindow === windowReference.window,
                  file.readOnlyReason == nil else { return }
            file.refreshWhenSelected()
        }
    }

    private var encodingMenu: some View {
        Menu {
            Menu(String(localized: "Reopen with Encoding", table: "Editor")) {
                Button(String(localized: "Automatic", table: "Editor")) {
                    file.reopen(using: nil)
                }
                ForEach(TextFileEncoding.choices, id: \.self) { encoding in
                    Button(encoding.name) { file.reopen(using: encoding) }
                }
            }
            .disabled(file.isDirty)
            if case .text = file.content {
                Menu(String(localized: "Save with Encoding", table: "Editor")) {
                    ForEach(TextFileEncoding.choices, id: \.self) { encoding in
                        Button(encoding.name) { Task { await file.save(as: encoding) } }
                    }
                }
            }
        } label: {
            if case .text = file.content {
                Text(file.fileEncoding.name).font(.system(size: 11))
            } else {
                Text(String(localized: "Choose Encoding", table: "Editor"))
                    .font(.system(size: 11))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(message)
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
