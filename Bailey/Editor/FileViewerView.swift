import AppKit
import AVFoundation
import Darwin
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum FilePreviewMode: CaseIterable {
    case source, preview, sideBySide

    var title: String {
        switch self {
        case .source: String(localized: "Show Source", table: "Editor")
        case .preview: String(localized: "Show Preview", table: "Editor")
        case .sideBySide: String(localized: "Show Side by Side", table: "Editor")
        }
    }

    func title(for kind: FilePreviewKind?) -> String {
        if self == .preview, kind == .delimited {
            return String(localized: "Show Table", table: "Editor")
        }
        return title
    }
}

enum FilePreviewKind: Equatable {
    case markdown
    case delimited
    case svg
    case html

    init?(path: String) {
        if MarkdownDocument.supports(path) {
            self = .markdown
        } else if DelimitedTableIndex.Separator.preferred(for: path) != nil {
            self = .delimited
        } else if (path as NSString).pathExtension.lowercased() == "svg" {
            self = .svg
        } else if ["html", "htm"].contains((path as NSString).pathExtension.lowercased()) {
            self = .html
        } else {
            return nil
        }
    }
}

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

    nonisolated enum Content: Sendable {
        case text
        case image(RasterPreview)
        case media(NativeMedia)
        case unavailable(String)
        /// Waiting for a consumer to request the first read.
        case loading
    }

    private(set) var content: Content
    private(set) var mediaPlayer: AVPlayer?
    private(set) var mediaSleeping = false
    @ObservationIgnored private var mediaEnvironmentObservation: NativeMediaEnvironmentObservation?
    private(set) var htmlPreview: HTMLPreview? {
        didSet {
            if let oldValue, oldValue !== htmlPreview { oldValue.retire() }
        }
    }
    private(set) var gifPlayback: GIFPlayback?
    private(set) var svgPreview: SVGPreviewSnapshot?
    private(set) var imageAnnotations: ImageAnnotationDocument?
    /// A publication may have reached the same machine even if its response
    /// or connection was lost. Keep the attempted snapshot until read-back.
    private struct AnnotationPublication {
        let state: ImageAnnotationState
        let version: WorkspaceFileVersion
    }
    @ObservationIgnored private var pendingAnnotationPublication: AnnotationPublication?
    private(set) var annotationError: String?
    @ObservationIgnored var graphicViewportPosition: PreviewScrollView.Position?
    /// The tab owns the one writable native document, even before any view is mounted.
    /// Only explicit full-content consumers materialize its Swift String.
    @ObservationIgnored private(set) var nativeTextStorage = NSTextStorage()
    @ObservationIgnored private(set) var nativeContentStorage = NSTextContentStorage()
    @ObservationIgnored let documentUndoManager = UndoManager()
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
    /// Proof about the accepted disk baseline, not the derived table index.
    private(set) var savedTextPreservesOriginalBytes = false
    @ObservationIgnored private var pendingTextPublication: (
        snapshot: TextFileEncoding.Publication, delta: [UInt16: Int]?
    )?
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
        delimitedEditingGrid?.cancelEditing()
        delimitedEditTask?.cancel()
        svgPreview = nil
        retireImageAnnotations()
        originalImageTask?.cancel()
        originalImageTask = nil
        if let nativeEditObserver {
            NotificationCenter.default.removeObserver(nativeEditObserver)
            self.nativeEditObserver = nil
        }
        let coordinator = editorCoordinator
        editorCoordinator = nil
        editorView = nil
        preparedLineWidths = nil
        coordinator?.retireObsoleteDocument()
        documentUndoManager.removeAllActions()
        nativeTextStorage.setAttributedString(NSAttributedString(string: ""))
        savedText = ""
        savedSourceVersion = nil
        savedTextPreservesOriginalBytes = false
        pendingTextPublication = nil
        pendingStorageChange = false
        nativeCodeUnitDelta = [:]
    }

    func retireContent() {
        isRetired = true
        htmlPreview = nil
        targetGeneration &+= 1
        gifPlayback = nil
        graphicViewportPosition = nil
        invalidateReload()
        retireMedia()
        content = .loading
        retireNativeEditor()
    }

    func deactivate() {
        mediaPlayer?.pause()
        autoSaveOnFocusLoss()
    }

    func handleMediaEnvironmentEvent(_ event: NativeMediaEnvironmentObservation.Event) {
        guard !isRetired, let player = mediaPlayer else { return }
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        switch event {
        case .sleep:
            mediaSleeping = true
        case .wake:
            mediaSleeping = false
            reloadFromDiskIfClean()
        case .outputChanged:
            if !mediaSleeping { reloadFromDiskIfClean() }
        }
    }

    private func installMedia(_ media: NativeMedia) {
        let player = AVPlayer(playerItem: AVPlayerItem(asset: media.asset))
        mediaPlayer = player
        mediaEnvironmentObservation = NativeMediaEnvironmentObservation { [weak self, weak player] event in
            guard let self, let player, self.mediaPlayer === player else { return }
            self.handleMediaEnvironmentEvent(event)
        }
    }

    private func retireMedia() {
        mediaEnvironmentObservation?.invalidate()
        mediaEnvironmentObservation = nil
        mediaSleeping = false
        if case .media(let media) = content { media.asset.cancelLoading() }
        mediaPlayer?.pause()
        mediaPlayer?.currentItem?.cancelPendingSeeks()
        mediaPlayer?.replaceCurrentItem(with: nil)
        mediaPlayer = nil
    }

    private func installNativeDocument(_ text: String) {
        markdownCollapsedHeadings.removeAll()
        markdownHeadingOutline.removeAll()
        markdownOutlineRequest = nil
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
        let edited = nativeTextStorage.editedRange
        let delta = nativeTextStorage.changeInLength
        if let offset = markdownReadingOffset {
            if offset >= NSMaxRange(edited) - delta {
                markdownReadingOffset = offset + delta
            } else if offset >= edited.location {
                markdownReadingOffset = min(offset, NSMaxRange(edited))
            }
        }
        if !markdownCollapsedHeadings.isEmpty {
            markdownCollapsedHeadings = Set(markdownCollapsedHeadings.compactMap {
                $0.moved(by: edited, delta: delta)
            })
        }
        textEditRevision &+= 1
        markdownSourceOffset = nil
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
        htmlPreview?.retire()
        if let nativeEditObserver { NotificationCenter.default.removeObserver(nativeEditObserver) }
    }

    nonisolated static let maxTextBytes = 32 << 20
    nonisolated static let maxImageBytes = 256 << 20
    private nonisolated static let imageExtensionHints: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "icns",
    ]

    @ObservationIgnored private var reloadGeneration: UInt = 0
    @ObservationIgnored private var isRetired = false
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var originalImageTask: (id: UUID, cancel: () -> Void)?
    @ObservationIgnored private var refreshPending = false
    /// A previously requested read must resume after reconnect; restored tabs
    /// that no consumer has touched must remain lazy.
    @ObservationIgnored private var hasReadDemand = false
    /// Changes when a rename or remote reconnect changes the save target.
    /// An in-flight write must not claim to have saved a different target.
    private var targetGeneration: UInt = 0 {
        didSet {
            htmlPreview?.invalidate()
            svgPreview = nil
            gifPlayback?.reset()
        }
    }
    @ObservationIgnored private var lastSaveTask: Task<Void, Never>?
    @ObservationIgnored private var saveLatestRequested = false
    /// Encoding changes are explicit user actions, never merged or silently dropped.
    @ObservationIgnored private var pendingEncodingSaves: [TextFileEncoding] = []
    private var fileMutationHeld = false
    @ObservationIgnored private var saveDeferredUntilMutation = false
    @ObservationIgnored private var deletedFromWorkspace = false
    var isSaving: Bool { lastSaveTask != nil }
    var autoSaveSuspendedForClose = false
    @ObservationIgnored private var openingSavedHTML = false
    /// The workspace this file lives on. The tab keeps its own, so it never
    /// follows the session onto another machine — and re-binds to a new
    /// connection to the same machine when one arrives.
    @ObservationIgnored private var backend: WorkspaceBackend
    /// The workspace this file belongs to: nil for this Mac, else the machine
    /// it was opened from. Part of the tab's identity, so the same path on two
    /// machines is two tabs, and a file opened locally is never read-only.
    let workspaceIdentity: String?
    private var previewOverride: Bool?
    @ObservationIgnored lazy var delimitedTable = DelimitedTableControls()
    private weak var delimitedEditingGrid: DelimitedGrid?
    private(set) var delimitedEditTask: Task<Bool, Never>?
    var hasPendingDelimitedEdit: Bool { delimitedEditingGrid != nil || delimitedEditTask != nil }
    private var textEditRevision: UInt = 0
    @ObservationIgnored var markdownReadingOffset: Int?
    @ObservationIgnored var markdownReadingViewportY: CGFloat = 0
    var markdownScrollSyncEnabled = true
    var markdownSourceOffset: Int?
    @ObservationIgnored var markdownSourceIndex: (request: String, index: MarkdownBlockIndex)?
    @ObservationIgnored var pendingMarkdownSource: (request: String, offset: Int, focus: Bool)?
    var pendingMarkdownFragment: String?
    var markdownCollapsedHeadings: Set<MarkdownDocument.HeadingIdentity> = []
    var markdownHeadingOutline: [MarkdownDocument.OutlineHeading] = []
    @ObservationIgnored var markdownOutlineRequest: String?

    func installMarkdownOutline(_ headings: [MarkdownDocument.OutlineHeading], request: String) {
        guard request == textPreviewRequestID else { return }
        markdownCollapsedHeadings.formIntersection(Set(headings.map(\.identity)))
        markdownHeadingOutline = headings
        markdownOutlineRequest = request
    }

    var previewKind: FilePreviewKind? { FilePreviewKind(path: path) }

    var isMediaFile: Bool { NativeMedia.candidate((path as NSString).pathExtension) != nil }

    var canPreviewFile: Bool {
        guard case .text = content else { return false }
        return previewKind != nil
    }

    var canPreviewMarkdown: Bool { canPreviewFile && previewKind == .markdown }

    var showsFilePreview: Bool {
        guard let previewKind else { return false }
        if let previewOverride { return previewOverride }
        switch previewKind {
        case .markdown, .html: return false
        case .delimited, .svg: return true
        }
    }

    var fileContentRevision: String { "\(id)-\(targetGeneration)-\(reloadRevision)" }
    var textPreviewRequestID: String { "\(fileContentRevision)-\(textEditRevision)" }
    private(set) var previewAssetRevision: UInt = 0

    private var documentEditRevision: String { "\(id)-\(reloadRevision)-\(textEditRevision)" }

    struct DelimitedSnapshot {
        let index: DelimitedTableIndex
        let source: String
        let requestID: String
        let documentRevision: String
    }

    func delimitedSnapshot(using selected: DelimitedTableIndex.Separator? = nil) async throws -> DelimitedSnapshot? {
        guard case .text = content, savedSourceVersion != nil,
              let preferred = DelimitedTableIndex.Separator.preferred(for: path) else { return nil }
        let request = textPreviewRequestID
        let source = text
        let index = try await DelimitedTableIndex.parse(source, preferred: preferred, selected: selected)
        try Task.checkCancellation()
        guard request == textPreviewRequestID else { return nil }
        return DelimitedSnapshot(index: index, source: source, requestID: request,
                                 documentRevision: documentEditRevision)
    }

    private func matchesDelimitedDocument(_ snapshot: DelimitedSnapshot) -> Bool {
        guard !isRetired, case .text = content else { return false }
        return snapshot.documentRevision == documentEditRevision && savedTextPreservesOriginalBytes &&
            snapshot.index.issue == nil && !snapshot.index.needsSeparatorChoice
    }

    func canEditDelimited(_ snapshot: DelimitedSnapshot) -> Bool {
        matchesDelimitedDocument(snapshot) && previewKind == .delimited &&
            readOnlyReason == nil && reloadError == nil && !fileMutationHeld &&
            snapshot.requestID == textPreviewRequestID
    }

    func beginDelimitedEditing(in grid: DelimitedGrid, using snapshot: DelimitedSnapshot) -> Bool {
        guard !hasPendingDelimitedEdit, canEditDelimited(snapshot) else { return false }
        delimitedEditingGrid = grid
        invalidateReload()
        return true
    }

    func endDelimitedEditing(in grid: DelimitedGrid) {
        if delimitedEditingGrid === grid { delimitedEditingGrid = nil }
    }

    func commitDelimitedEditing(in grid: DelimitedGrid, change: DelimitedTableMutation.Change,
                                using snapshot: DelimitedSnapshot, selecting cell: DelimitedTablePresentation.Cell) {
        guard delimitedEditingGrid === grid else { return }
        delimitedEditingGrid = nil
        enqueueDelimitedEdit(change, using: snapshot, selecting: cell)
    }

    func submitDelimitedEdit(_ change: DelimitedTableMutation.Change, using snapshot: DelimitedSnapshot,
                             selecting cell: DelimitedTablePresentation.Cell?) {
        guard !hasPendingDelimitedEdit, canEditDelimited(snapshot) else { return }
        enqueueDelimitedEdit(change, using: snapshot, selecting: cell)
    }

    /// An accepted native input belongs to the document, not to the view or
    /// connection. Transport loss prevents new input and writes, but cannot
    /// discard an input transaction already accepted by this document.
    private func enqueueDelimitedEdit(_ change: DelimitedTableMutation.Change, using snapshot: DelimitedSnapshot,
                                      selecting cell: DelimitedTablePresentation.Cell?) {
        let message = if case .paste = change {
            String(localized: "Could not paste into the table.", table: "Editor")
        } else {
            String(localized: "Could not edit the table.", table: "Editor")
        }
        let encoding = fileEncoding
        invalidateReload()
        delimitedEditTask = Task { [weak self] in
            guard let self else { return false }
            defer { delimitedEditTask = nil }
            do {
                delimitedTable.pendingCell = cell
                try await applyAcceptedDelimitedEdit(change, using: snapshot, encoding: encoding)
                if documentEditRevision == snapshot.documentRevision { delimitedTable.pendingCell = nil }
                if case .insertRows = change, snapshot.index.records.isEmpty {
                    delimitedTable.configuration.header = false
                }
                delimitedTable.editError = nil
                return true
            } catch {
                delimitedTable.pendingCell = nil
                if !Task.isCancelled { delimitedTable.editError = message }
                return false
            }
        }
    }

    private func finishPendingDelimitedEdit() async -> Bool {
        delimitedEditingGrid?.finishEditing()
        if let task = delimitedEditTask, !(await task.value) {
            saveError = delimitedTable.editError
            return false
        }
        return !hasPendingDelimitedEdit
    }

    /// Prepare and check encoding away from the main actor, then commit one
    /// transaction to the very same NSTextStorage and UndoManager as typing.
    func editDelimited(_ change: DelimitedTableMutation.Change, using snapshot: DelimitedSnapshot) async throws {
        guard canEditDelimited(snapshot) else { throw WorkspaceError.changedExternally }
        try await applyAcceptedDelimitedEdit(change, using: snapshot, encoding: fileEncoding)
    }

    private func applyAcceptedDelimitedEdit(_ change: DelimitedTableMutation.Change,
                                            using snapshot: DelimitedSnapshot,
                                            encoding: TextFileEncoding) async throws {
        guard matchesDelimitedDocument(snapshot) else { throw WorkspaceError.changedExternally }
        let replacements = try await DelimitedTableMutation.prepare(
            change, source: snapshot.source, index: snapshot.index, encoding: encoding
        )
        try Task.checkCancellation()
        // Publishing an encoding changes the saved baseline, not the accepted draft.
        // A subsequent save validates the draft against the newly selected encoding.
        guard matchesDelimitedDocument(snapshot) else { throw WorkspaceError.changedExternally }
        guard !replacements.isEmpty else { return }
        if let editor = editorCoordinator?.scrollView?.documentView as? NativeCodeTextView {
            guard !editor.hasMarkedText() else { throw WorkspaceError.changedExternally }
            editor.breakUndoCoalescing()
        }
        while documentUndoManager.groupingLevel > 0 {
            documentUndoManager.endUndoGrouping()
        }
        documentUndoManager.beginUndoGrouping()
        let applied = applyDocumentReplacements(replacements)
        documentUndoManager.endUndoGrouping()
        guard applied else { throw WorkspaceError.changedExternally }
    }

    @discardableResult
    private func applyDocumentReplacements(_ replacements: [DelimitedTableMutation.Replacement]) -> Bool {
        let storage = nativeTextStorage
        // Validate every original range before making any change.
        guard replacements.allSatisfy({ edit in
            NSMaxRange(edit.range) <= storage.length &&
                storage.attributedSubstring(from: edit.range).string.utf16.elementsEqual(edit.old.utf16)
        }) else { return false }

        // Compute inverse ranges in the final document, so Undo and Redo
        // also apply all replacements in descending order.
        var shift = 0
        let undo = replacements.reversed().map { edit in
            let inverse = DelimitedTableMutation.Replacement(
                range: NSRange(location: edit.range.location + shift, length: edit.new.utf16.count),
                old: edit.new, new: edit.old
            )
            shift += edit.new.utf16.count - edit.range.length
            return inverse
        }.reversed()

        storage.beginEditing()
        for edit in replacements {
            storage.replaceCharacters(in: edit.range, with: edit.new)
        }
        storage.endEditing()
        let inverse = Array(undo)
        documentUndoManager.registerUndo(withTarget: storage) { [weak self] target in
            MainActor.assumeIsolated {
                guard let self, self.nativeTextStorage === target, !self.isRetired else { return }
                self.applyDocumentReplacements(inverse)
            }
        }
        nativeTextChangedWithoutReplacement()
        refreshDirtyState()
        return true
    }

    func setFilePreview(_ enabled: Bool) {
        guard previewKind != nil else { return }
        delimitedEditingGrid?.finishEditing()
        switch content {
        case .text, .loading: previewOverride = enabled
        case .image, .media, .unavailable: break
        }
    }

    func previewResource(in directory: String?) -> PreviewResource {
        // A Finder-opened document may be outside the active project's root.
        // Its own parent is the narrowest authorized scope for relative assets.
        let scope = directory.flatMap { LocalPathScope.contains(path, in: $0) ? $0 : nil }
            ?? (path as NSString).deletingLastPathComponent
        return PreviewResource(path: path, directory: readOnlyReason == nil ? scope : nil, backend: backend)
    }

    func showSVGPreview(request: String) async {
        guard !Task.isCancelled, !isRetired, canPreviewFile, previewKind == .svg,
              request == textPreviewRequestID, svgPreview?.request != request else { return }
        do {
            if svgPreview != nil { try await Task.sleep(for: .milliseconds(120)) }
            guard !isRetired, request == textPreviewRequestID else { return }
            let artwork = try await SVGPreviewSnapshot.parse(text)
            try Task.checkCancellation()
            guard !isRetired, previewKind == .svg, request == textPreviewRequestID else { return }
            svgPreview = SVGPreviewSnapshot(request: request,
                                            drawing: .init(request: request, artwork: artwork), error: nil)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, !isRetired, previewKind == .svg, request == textPreviewRequestID else { return }
            let message: String
            if case WorkspaceError.tooLarge = error {
                message = String(localized: "SVG is too large to preview. You can still edit the source.", table: "Editor")
            } else {
                let description = String(localized: "Could not display this SVG.", table: "Editor")
                let diagnostic = error as NSError
                message = diagnostic.domain == XMLParser.errorDomain
                    ? description + " " + diagnostic.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    : description
            }
            svgPreview = SVGPreviewSnapshot(request: request, drawing: svgPreview?.drawing, error: message)
        }
    }

    func svgOutputDrawing(request: String) -> SVGArtwork.Vector? {
        guard !isRetired, canPreviewFile, previewKind == .svg, reloadError == nil,
              readOnlyReason == nil, request == textPreviewRequestID,
              let drawing = svgPreview?.drawing, drawing.request == request else { return nil }
        return drawing.artwork
    }

    private func svgPNG(request: String, options: SVGArtwork.PNGOptions) async throws -> Data {
        guard let artwork = svgOutputDrawing(request: request) else { throw WorkspaceError.changedExternally }
        let png = try await SVGArtwork.png(artwork, options: options)
        try Task.checkCancellation()
        guard svgOutputDrawing(request: request) != nil else { throw WorkspaceError.changedExternally }
        return png
    }

    func copySVGPNG(request: String, options: SVGArtwork.PNGOptions, to pasteboard: NSPasteboard = .general) async throws {
        let png = try await svgPNG(request: request, options: options)
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else { throw CocoaError(.fileWriteUnknown) }
    }

    func exportSVGPNG(request: String, options: SVGArtwork.PNGOptions, to destination: URL) async throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "png" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let png = try await svgPNG(request: request, options: options)
        try await LocalWorkspaceBackend.shared.writeNewFile(path: destination.path, data: png)
    }

    var canRunLocalHTML: Bool {
        canPreviewFile && previewKind == .html && workspaceIdentity == nil &&
            backend is LocalWorkspaceBackend && !isRetired && readOnlyReason == nil &&
            reloadError == nil && !fileMutationHeld && !autoSaveSuspendedForClose
    }

    /// Never stage or execute the editor's in-memory draft. Verify that the
    /// real local file still has the accepted saved bytes before granting WebKit access.
    func savedHTMLForBrowser(request: String) async throws -> URL {
        guard canRunLocalHTML, request == textPreviewRequestID,
              lastSaveTask == nil, let version = savedSourceVersion else {
            throw WorkspaceError.changedExternally
        }
        let path = self.path
        let resolved = try await Self.checkSavedHTML(path: path, version: version)
        try Task.checkCancellation()
        guard canRunLocalHTML, request == textPreviewRequestID,
              lastSaveTask == nil, version == savedSourceVersion,
              LocalPathScope.physicalPath(path) == resolved.path,
              LocalFileIdentity.read(resolved.path) == resolved.identity else {
            throw WorkspaceError.changedExternally
        }
        return URL(fileURLWithPath: resolved.path)
    }

    @concurrent private static func checkSavedHTML(
        path: String, version: WorkspaceFileVersion
    ) async throws -> (path: String, identity: LocalFileIdentity) {
        let resolved = try LocalWorkspaceBackend.readableFile(at: path)
        let bytes = try await LocalWorkspaceBackend.shared.read(path: resolved.path, maxBytes: version.byteCount)
        guard version.matches(bytes), LocalFileIdentity.read(resolved.path) == resolved.identity else {
            throw WorkspaceError.changedExternally
        }
        return (resolved.path, resolved.identity)
    }

    /// The explicit "open saved version" action is not an ordinary focus-save
    /// request. Resign the actual native editor synchronously while suppression
    /// is active; Dock deactivation then uses the same boundary. Later genuine
    /// focus transitions and explicit Save retain their usual behavior.
    func openSavedHTMLWithoutAutoSave<T>(_ open: () -> T) throws -> T {
        guard canRunLocalHTML, lastSaveTask == nil else { throw WorkspaceError.changedExternally }
        openingSavedHTML = true
        defer { openingSavedHTML = false }
        if let editor = editorCoordinator?.scrollView?.documentView as? NativeCodeTextView,
           let window = editor.window, window.firstResponder === editor {
            guard !editor.hasMarkedText(), window.makeFirstResponder(nil) else {
                throw WorkspaceError.changedExternally
            }
        }
        return open()
    }

    func showHTMLPreview(request: String, in directory: String?) async {
        guard !Task.isCancelled, !isRetired, canPreviewFile, previewKind == .html,
              request == textPreviewRequestID else { return }
        let assets = previewAssetRevision
        let preview = htmlPreview ?? HTMLPreview()
        htmlPreview = preview
        await preview.display(text, resource: previewResource(in: directory), target: fileContentRevision,
                              request: request, assets: assets) {
            !isRetired && request == textPreviewRequestID && assets == previewAssetRevision
        }
    }

    func refreshPreviewAssets() {
        guard !isRetired, readOnlyReason == nil else { return }
        switch previewKind {
        case .markdown:
            previewAssetRevision &+= 1
        case .html where htmlPreview?.hasRefreshableAssets == true:
            previewAssetRevision &+= 1
        default:
            break
        }
    }

    private nonisolated struct LoadedContent: Sendable {
        let content: Content
        let text: String
        let encoding: TextFileEncoding?
        let decodingFailed: Bool
        let sourceVersion: WorkspaceFileVersion?
        var annotations: ImageAnnotationSidecar.Loaded? = nil
        var textPreservesOriginalBytes = false
    }

    func reopen(using encoding: TextFileEncoding?) {
        guard !isMediaFile else { return }
        guard !isDirty, !isSaving, !hasPendingDelimitedEdit, !fileMutationHeld, pendingTextPublication == nil else {
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
        case .text, .image, .media: break
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
        if isReadOnly { delimitedEditingGrid?.finishEditing() }
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
        let wasMedia = isMediaFile
        invalidateReload()
        targetGeneration &+= 1
        let previousKind = previewKind
        path = newPath
        if previewKind != previousKind {
            previewOverride = nil
            if previousKind == .svg || previewKind == .svg { graphicViewportPosition = nil }
        }
        if previewKind != .html { htmlPreview = nil }
        editorCoordinator?.updateSyntaxHighlighting(for: newPath)
        if hasReadDemand, !isDirty, wasMedia || isMediaFile {
            if case .media = content {
                retireMedia()
                content = .loading
            }
            reloadFromDiskIfClean()
        } else if wasReading {
            loadIfNeeded()
        }
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
            let textDirty: Bool
            if nativeTextStorage.length != (savedText as NSString).length
                || nativeCodeUnitDelta?.isEmpty == false {
                textDirty = true
            } else {
                textDirty = !TextFileEncoding.hasIdenticalCodeUnits(nativeTextStorage.string, savedText)
                if !textDirty { nativeCodeUnitDelta = [:] }
            }
            // Undo to the old base is not clean if a different revision may
            // already be on disk. Encoding-only saves still use isSaving/error.
            dirty = textDirty || pendingTextPublication?.snapshot.changesText == true
        } else if case .image = content {
            dirty = imageAnnotations?.isDirty == true || pendingAnnotationPublication != nil
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
        guard !autoSaveSuspendedForClose, !openingSavedHTML else { return }
        delimitedEditingGrid?.finishEditing()
        guard isDirty || hasPendingDelimitedEdit else { return }
        if lastSaveTask != nil {
            saveLatestRequested = true
        } else {
            Task { [weak self] in await self?.save() }
        }
    }

    /// Hold the original save target stable until all queued writes have completed.
    func beginFileMutation() async -> Bool {
        guard !fileMutationHeld, !autoSaveSuspendedForClose else { return false }
        if hasPendingDelimitedEdit, !(await finishPendingDelimitedEdit()) { return false }
        guard !fileMutationHeld, !autoSaveSuspendedForClose else { return false }
        fileMutationHeld = true
        await lastSaveTask?.value
        if isDirty || pendingTextPublication != nil { await writeCurrentContent() }
        guard !isDirty, pendingTextPublication == nil, saveError == nil else {
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
        let reason = String(localized: "This file was deleted. Copy your edits before closing.", table: "Editor")
        readOnlyReason = reason
        delimitedEditingGrid?.finishEditing()
        if case .media = content {
            retireMedia()
            content = .unavailable(reason)
        }
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
                await self.writeCurrentContent(as: intent)
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

    private func writeCurrentContent(as encoding: TextFileEncoding? = nil) async {
        if hasPendingDelimitedEdit, !(await finishPendingDelimitedEdit()) { return }
        if case .image = content, encoding == nil {
            await writeCurrentAnnotations()
        } else {
            await writeCurrentText(as: encoding)
        }
    }

    var canAnnotateImage: Bool {
        imageAnnotations != nil && annotationError == nil && !isRetired &&
            readOnlyReason == nil && reloadError == nil && !fileMutationHeld &&
            !autoSaveSuspendedForClose
    }

    private func retireImageAnnotations() {
        pendingAnnotationPublication = nil
        imageAnnotations?.permitsMutation = { false }
        imageAnnotations?.onChange = nil
        imageAnnotations?.undoManager.removeAllActions()
        imageAnnotations = nil
        annotationError = nil
    }

    private func installImageAnnotations(_ loaded: LoadedContent) {
        guard case .image(let preview) = loaded.content, let annotations = loaded.annotations else {
            retireImageAnnotations()
            return
        }
        let state: ImageAnnotationState
        let version: WorkspaceFileVersion?
        switch annotations {
        case .missing: state = .init(); version = nil
        case .existing(let value, let accepted): state = value; version = accepted
        case .unavailable(let message):
            retireImageAnnotations()
            annotationError = message
            return
        }
        annotationError = nil
        if let current = imageAnnotations, current.size == preview.pixelSize,
           current.savedState == state, current.sidecarVersion == version { return }
        retireImageAnnotations()
        let document = ImageAnnotationDocument(size: preview.pixelSize, state: state, version: version)
        document.onChange = { [weak self] in self?.refreshDirtyState() }
        document.permitsMutation = { [weak self, weak document] in
            guard let self, let document else { return false }
            return self.imageAnnotations === document && self.canAnnotateImage
        }
        imageAnnotations = document
    }

    private func writeCurrentAnnotations() async {
        guard let document = imageAnnotations, isDirty else { return }
        guard !isRetired, readOnlyReason == nil, reloadError == nil,
              let version = savedSourceVersion else {
            saveError = readOnlyReason ?? String(localized: "The original image is unavailable.", table: "Editor")
            return
        }
        let target = backend
        let savedPath = path
        let generation = targetGeneration
        invalidateReload()
        do {
            if let pending = pendingAnnotationPublication {
                let confirmed = try await ImageAnnotationSidecar.confirmsPublication(
                    image: savedPath, backend: target, version: version, written: pending.version)
                guard generation == targetGeneration, imageAnnotations === document,
                      path == savedPath, readOnlyReason == nil else { return }
                pendingAnnotationPublication = nil
                if confirmed {
                    document.markSaved(pending.state, version: pending.version)
                } else {
                    refreshDirtyState()
                }
                saveError = nil
            }
            guard document.isDirty else { return }
            let snapshot = document.state
            let previous = document.sidecarVersion
            let bytes = try await ImageAnnotationSidecar.encode(snapshot, version: version, size: document.size)
            guard generation == targetGeneration, imageAnnotations === document, path == savedPath,
                  readOnlyReason == nil else { throw WorkspaceError.changedExternally }
            let written = WorkspaceFileVersion(data: bytes)
            pendingAnnotationPublication = AnnotationPublication(state: snapshot, version: written)
            do {
                try await ImageAnnotationSidecar.publish(bytes, image: savedPath, backend: target,
                                                         version: version, previous: previous)
            } catch {
                if imageAnnotations === document, !WorkspaceError.publicationUncertain(error) {
                    pendingAnnotationPublication = nil
                    refreshDirtyState()
                }
                throw error
            }
            guard generation == targetGeneration, imageAnnotations === document, path == savedPath else { return }
            pendingAnnotationPublication = nil
            document.markSaved(snapshot, version: written)
            saveError = nil
        } catch {
            guard generation == targetGeneration, imageAnnotations === document else { return }
            saveError = String(localized: "Could not save image annotations.", table: "Editor") + " " + error.localizedDescription
        }
    }

    func annotatedImageData(request: String, options: ImageAnnotationDrawing.Options) async throws -> Data {
        guard canAnnotateImage, request == fileContentRevision, let document = imageAnnotations,
              let version = savedSourceVersion, case .image(let preview) = content else {
            throw WorkspaceError.changedExternally
        }
        let snapshot = document.state
        let target = backend
        let sourcePath = path
        let size = preview.pixelSize
        let original = try await Self.readOriginalImage(sourcePath, backend: target, version: version) { bytes, source in
            try RasterPreview.original(bytes, source: source, size: size)
        }
        let bytes = try await ImageAnnotationDrawing.export(snapshot, source: original, options: options)
        try await ImageAnnotationSidecar.verifySource(sourcePath, backend: target, version: version)
        guard !Task.isCancelled, request == fileContentRevision, imageAnnotations === document,
              snapshot == document.state, canAnnotateImage else { throw WorkspaceError.changedExternally }
        return bytes
    }

    func copyAnnotatedImage(request: String, to pasteboard: NSPasteboard = .general) async throws {
        guard let document = imageAnnotations, canAnnotateImage, request == fileContentRevision else {
            throw WorkspaceError.changedExternally
        }
        let size = document.state.crop?.size ?? document.size
        let options = ImageAnnotationDrawing.Options(width: Int(size.width), height: Int(size.height))
        let png = try await annotatedImageData(request: request, options: options)
        try Task.checkCancellation()
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else { throw CocoaError(.fileWriteUnknown) }
    }

    func prepareAnnotationExport(request: String, options: ImageAnnotationDrawing.Options,
                                 to destination: URL) async throws -> LocalWorkspaceBackend.ImageExportTarget {
        try Task.checkCancellation()
        guard destination.isFileURL, UTType(filenameExtension: destination.pathExtension)?.conforms(to: options.format.type) == true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard canAnnotateImage, request == fileContentRevision else { throw WorkspaceError.changedExternally }
        let target = try await LocalWorkspaceBackend.shared.prepareImageExport(
            path: destination.path, protecting: workspaceIdentity == nil ? path : nil
        )
        try Task.checkCancellation()
        guard canAnnotateImage, request == fileContentRevision else {
            throw WorkspaceError.changedExternally
        }
        return target
    }

    func exportAnnotatedImage(request: String, options: ImageAnnotationDrawing.Options, to destination: URL,
                              confirmedTarget: LocalWorkspaceBackend.ImageExportTarget? = nil) async throws {
        let target: LocalWorkspaceBackend.ImageExportTarget
        if let confirmedTarget {
            target = confirmedTarget
            guard destination.isFileURL,
                  UTType(filenameExtension: destination.pathExtension)?.conforms(to: options.format.type) == true else {
                throw WorkspaceError.changedExternally
            }
        } else {
            target = try await prepareAnnotationExport(request: request, options: options, to: destination)
            guard !target.replacesExistingFile else { throw CocoaError(.fileWriteFileExists) }
        }
        let bytes = try await annotatedImageData(request: request, options: options)
        try await LocalWorkspaceBackend.shared.writeImageExport(target, to: destination.path, data: bytes)
    }

    private func resolveTextPublication(path: String, target: WorkspaceBackend, generation: UInt,
                                        replacingEncodingIntent: Bool = false)
        async throws -> WorkspaceFileVersion.PublicationStatus? {
        guard let pending = pendingTextPublication else { return nil }
        let snapshot = pending.snapshot
        guard snapshot.path == path else { throw WorkspaceError.changedExternally }
        let status = try await snapshot.version.publicationStatus(
            at: path, previous: snapshot.previous, backend: target)
        guard generation == targetGeneration, !isRetired else { return nil }
        // A confirmed unchanged file still has an unresolved explicit encoding
        // request. Only another explicit encoding choice can supersede it.
        if status == .unchanged, snapshot.explicit, !replacingEncodingIntent { return status }
        pendingTextPublication = nil
        if status == .published {
            acceptPublishedText(snapshot.text, encoding: snapshot.encoding, wasExplicit: snapshot.explicit,
                                version: snapshot.version, deltaAtWrite: pending.delta)
        } else {
            refreshDirtyState()
            if !isDirty && !snapshot.explicit { saveError = nil }
        }
        return status
    }

    private func reportTextPublicationError(_ error: Error, generation: UInt) {
        guard !isRetired else { return }
        if generation != targetGeneration {
            if pendingTextPublication != nil {
                saveError = readOnlyReason ?? String(localized: "Save result could not be confirmed.", table: "Workspace")
            }
            return
        }
        if case WorkspaceError.changedExternally = error {
            saveError = String(localized: "The file changed outside Bailey. Your edits remain unsaved.",
                               table: "Editor")
        } else {
            saveError = error.localizedDescription
        }
    }

    private func writeCurrentText(as encoding: TextFileEncoding? = nil) async {
        guard case .text = content, !isRetired,
              pendingTextPublication != nil || isDirty || (encoding != nil && encoding != fileEncoding) else { return }
        if let readOnlyReason {
            saveError = readOnlyReason
            return
        }
        guard reloadError == nil else { return }
        let target = backend
        let generation = targetGeneration
        let savedPath = path
        // Reconnect does not change the document's accepted version. Resolve
        // the actual previous attempt on this machine before any new write.
        if pendingTextPublication != nil {
            do {
                guard let status = try await resolveTextPublication(
                    path: savedPath, target: target, generation: generation,
                    replacingEncodingIntent: encoding != nil), pendingTextPublication == nil else { return }
                if status == .unchanged, encoding == fileEncoding, !isDirty {
                    saveError = nil
                    return
                }
            } catch {
                reportTextPublicationError(error, generation: generation)
                return
            }
        }
        guard isDirty || (encoding != nil && encoding != fileEncoding) else { return }
        guard let expected = savedSourceVersion else {
            saveError = String(localized: "Original file bytes are unknown. Reopen before saving.",
                               table: "Editor")
            return
        }
        invalidateReload()
        let written = text
        let deltaAtWrite = nativeCodeUnitDelta
        let changedText = isDirty
        let chosen = encoding ?? fileEncoding
        let prepared = await TextFileEncoding.prepareSave(
            written, as: chosen, path: savedPath, checkDeclaration: chosen != fileEncoding
        )
        guard generation == targetGeneration, path == savedPath, !isRetired,
              readOnlyReason == nil else { return }
        guard savedSourceVersion == expected else {
            reportTextPublicationError(WorkspaceError.changedExternally, generation: generation)
            return
        }
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
        pendingTextPublication = (.init(path: savedPath, text: written, encoding: chosen, explicit: encoding != nil,
                                        changesText: changedText, previous: expected, version: payload.version),
                                  deltaAtWrite)
        refreshDirtyState()
        do {
            try await target.write(path: savedPath, data: payload.bytes, ifUnchanged: expected)
        } catch {
            // Retirement releases the attempted snapshot; there is no
            // document left to update with a late response.
            guard pendingTextPublication != nil else { return }
            if !WorkspaceError.publicationUncertain(error) {
                pendingTextPublication = nil
                refreshDirtyState()
                reportTextPublicationError(error, generation: targetGeneration)
                return
            }
            if generation == targetGeneration {
                do {
                    let status = try await resolveTextPublication(
                        path: savedPath, target: target, generation: generation)
                    if status == .published || (status == .unchanged && !isDirty && encoding == nil) {
                        return
                    }
                } catch {
                    reportTextPublicationError(error, generation: generation)
                    return
                }
            }
            reportTextPublicationError(error, generation: generation)
            return
        }
        guard generation == targetGeneration, !isRetired else {
            if !isRetired, pendingTextPublication != nil {
                saveError = readOnlyReason ?? String(localized: "Save result could not be confirmed.", table: "Workspace")
            }
            return
        }
        pendingTextPublication = nil
        acceptPublishedText(written, encoding: chosen, wasExplicit: encoding != nil,
                            version: payload.version, deltaAtWrite: deltaAtWrite)
    }

    private func acceptPublishedText(
        _ written: String, encoding: TextFileEncoding, wasExplicit: Bool,
        version: WorkspaceFileVersion, deltaAtWrite: [UInt16: Int]?
    ) {
        fileEncoding = encoding
        if wasExplicit { preferredEncoding = encoding }
        savedText = written
        savedSourceVersion = version
        // The acknowledged bytes were produced by strict prepareSave.
        savedTextPreservesOriginalBytes = true
        // Edits landing during I/O still belong to the next revision.
        if let deltaAtWrite, nativeCodeUnitDelta != nil {
            for (unit, count) in deltaAtWrite {
                let updated = (nativeCodeUnitDelta?[unit] ?? 0) - count
                if updated == 0 { nativeCodeUnitDelta?.removeValue(forKey: unit) }
                else { nativeCodeUnitDelta?[unit] = updated }
            }
        } else {
            nativeCodeUnitDelta = nil
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
        guard !isRetired, readOnlyReason == nil, !isDirty, !hasPendingDelimitedEdit,
              pendingTextPublication == nil else { return }
        hasReadDemand = true
        refreshPending = false
        reloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let expectedPath = path
        let isLocal = workspaceIdentity == nil
        let currentMedia: NativeMedia? = if case .media(let media) = content { media } else { nil }

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
            // Reject a known replaced source before loading or decoding the
            // new asset, not after that potentially slow validation finishes.
            var reusableMedia = currentMedia
            if let currentMedia, !(await NativeMedia.stillIdentifies(expectedPath, media: currentMedia)) {
                guard !Task.isCancelled, let self, self.reloadGeneration == generation,
                      !self.isDirty, self.readOnlyReason == nil else { return }
                self.retireMedia()
                self.content = .loading
                self.reloadRevision &+= 1
                reusableMedia = nil
            }
            let loaded: LoadedContent
            do {
                loaded = try await Self.readContent(
                    path: expectedPath, backend: backend, override: self?.preferredEncoding,
                    isLocal: isLocal, currentMedia: reusableMedia
                )
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
                    case .loading, .media, .unavailable: break
                    }
                }
                let reason: String
                if case WorkspaceError.tooLarge = error {
                    reason = String(localized: "File is too large to open", table: "Workspace")
                } else {
                    reason = String(localized: "Could not read file", table: "Workspace")
                }
                loaded = LoadedContent(content: .unavailable(reason), text: "",
                                       encoding: nil,
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
                case .loading, .media, .unavailable:
                    break
                }
            }
            self.reloadError = nil
            self.saveError = nil
            if self.matches(loaded) {
                // Reload can accept changed bytes without changing decoded text.
                self.savedSourceVersion = loaded.sourceVersion
                self.savedTextPreservesOriginalBytes = loaded.textPreservesOriginalBytes
                self.installImageAnnotations(loaded)
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
            self.retireMedia()
            self.retireNativeEditor()
            self.graphicViewportPosition = nil
            self.content = loaded.content
            self.gifPlayback?.reset()
            if case .image(let image) = loaded.content, image.animationFrameCount > 1 {
                self.gifPlayback = GIFPlayback()
            } else {
                self.gifPlayback = nil
            }
            if case .media(let media) = loaded.content {
                self.installMedia(media)
            }
            if let encoding = loaded.encoding { self.fileEncoding = encoding }
            self.installNativeDocument(loaded.text)
            self.preparedLineWidths = prepared
            self.savedText = loaded.text
            self.savedSourceVersion = loaded.sourceVersion
            self.savedTextPreservesOriginalBytes = loaded.textPreservesOriginalBytes
            self.installImageAnnotations(loaded)
            self.nativeCodeUnitDelta = [:]
            self.reloadRevision &+= 1
        }
    }

    private func invalidateReload() {
        refreshPending = false
        reloadTask?.cancel()
        reloadTask = nil
        reloadGeneration &+= 1
        originalImageTask?.cancel()
        originalImageTask = nil
    }

    private func matches(_ loaded: LoadedContent) -> Bool {
        switch (content, loaded.content) {
        case (.text, .text):
            return fileEncoding == loaded.encoding && TextFileEncoding.hasIdenticalCodeUnits(savedText, loaded.text)
        case (.image, .image):
            return savedSourceVersion == loaded.sourceVersion
        case (.media(let current), .media(let new)):
            return current.asset === new.asset
        case (.unavailable(let current), .unavailable(let new)):
            return current == new
        default:
            return false
        }
    }

    func originalImageRequest() -> (() async throws -> RasterDetail)? {
        guard case .image(let preview) = content, preview.animationFrameCount < 2,
              preview.poster.width < Int(preview.pixelSize.width) ||
                preview.poster.height < Int(preview.pixelSize.height) else { return nil }
        let size = preview.pixelSize
        return imageRequest { bytes, source in try RasterPreview.original(bytes, source: source, size: size) }
    }

    func gifFramesRequest() -> (() async throws -> GIFPlayback.Frames)? {
        guard case .image(let preview) = content, preview.animationFrameCount > 1 else { return nil }
        let count = preview.animationFrameCount
        let maximumDimension = Int(max(preview.pixelSize.width, preview.pixelSize.height))
        return imageRequest { bytes, source in
            guard !RasterPreview.hasEmptyGIFFrame(bytes) else { throw CocoaError(.fileReadCorruptFile) }
            let frames = GIFFrameSource(source: source, maximumDimension: maximumDimension)
            return GIFPlayback.Frames(count: count) { index in try await frames.frame(at: index) }
        }
    }

    private func imageRequest<Output: Sendable>(
        _ decode: @escaping @Sendable (Data, sending CGImageSource) throws -> Output
    ) -> (() async throws -> Output)? {
        guard readOnlyReason == nil, let version = savedSourceVersion else { return nil }
        let backend = self.backend
        let path = self.path
        let target = targetGeneration
        let revision = reloadRevision
        return { [weak self] in
            guard self?.targetGeneration == target, self?.reloadRevision == revision,
                  self?.savedSourceVersion == version else { throw WorkspaceError.changedExternally }
            try Task.checkCancellation()
            let id = UUID()
            let task = Task {
                try await Self.readOriginalImage(path, backend: backend, version: version, decode: decode)
            }
            self?.originalImageTask?.cancel()
            self?.originalImageTask = (id, { task.cancel() })
            defer {
                if self?.originalImageTask?.id == id { self?.originalImageTask = nil }
            }
            let image = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard let self, self.targetGeneration == target, self.reloadRevision == revision,
                  self.savedSourceVersion == version else { throw WorkspaceError.changedExternally }
            return image
        }
    }

    @concurrent private static func readOriginalImage<Output: Sendable>(
        _ path: String, backend: WorkspaceBackend, version: WorkspaceFileVersion,
        decode: @Sendable (Data, sending CGImageSource) throws -> Output
    ) async throws -> Output {
        let bytes = try await backend.read(path: path, maxBytes: version.byteCount)
        try Task.checkCancellation()
        guard version.matches(bytes) else { throw WorkspaceError.changedExternally }
        try Task.checkCancellation()
        guard let source = try RasterPreview.source(bytes) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try decode(bytes, source)
    }

    @concurrent private static func readLargeRaster(
        _ path: String, backend: WorkspaceBackend, info: WorkspaceStat
    ) async throws -> Data {
        guard (info.isRegular || info.isSymlink), info.size > maxTextBytes, info.size <= maxImageBytes else {
            throw WorkspaceError.tooLarge
        }
        let prefix = try await backend.readPrefix(path: path, maxBytes: 65_536)
        guard RasterPreview.recognizesHeader(prefix) else { throw WorkspaceError.tooLarge }
        // Use the observed length, not the image ceiling, in case the path grows.
        return try await backend.read(path: path, maxBytes: info.size)
    }

    @concurrent private static func readContent(
        path: String, backend: WorkspaceBackend, override: TextFileEncoding?,
        isLocal: Bool, currentMedia: NativeMedia?
    ) async throws -> LoadedContent {
        guard !path.utf8.contains(0) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let suffix = (path as NSString).pathExtension.lowercased()
        if NativeMedia.candidate(suffix) != nil {
            let content: Content
            if isLocal, backend is LocalWorkspaceBackend {
                do {
                    content = .media(try await NativeMedia.open(path, reusing: currentMedia))
                } catch NativeMedia.Failure.unsupported {
                    content = .unavailable(String(localized: "This media file is damaged or uses an unsupported format.", table: "Editor"))
                } catch WorkspaceError.changedExternally {
                    content = .unavailable(String(localized: "The media file changed while opening. Reopen the file to try again.", table: "Editor"))
                }
            } else {
                content = .unavailable(String(localized: "Media playback is only available for files on this Mac.", table: "Editor"))
            }
            return LoadedContent(content: content, text: "", encoding: nil, decodingFailed: false, sourceVersion: nil)
        }
        let data: Data
        // The suffix is only a size-probe hint, not the format decision. Avoid
        // transferring the first 32 MiB twice for ordinary large SSH images.
        if imageExtensionHints.contains(suffix), let info = try await backend.stat(path: path),
           info.size > maxTextBytes {
            data = try await readLargeRaster(path, backend: backend, info: info)
        } else {
            do {
                data = try await backend.read(path: path, maxBytes: maxTextBytes)
            } catch WorkspaceError.tooLarge {
                guard let info = try await backend.stat(path: path) else { throw WorkspaceError.tooLarge }
                data = try await readLargeRaster(path, backend: backend, info: info)
            }
        }
        try Task.checkCancellation()
        if (suffix == "svg" || suffix == "svgz"), data.starts(with: [0x1f, 0x8b, 0x08]) {
            return LoadedContent(
                content: .unavailable(String(localized: "Compressed SVG is not supported. Open an uncompressed SVG file.",
                                             table: "Workspace")),
                text: "", encoding: nil, decodingFailed: false, sourceVersion: nil
            )
        }
        let invalidRaster: Bool
        do {
            if let source = try RasterPreview.source(data) {
                guard let preview = RasterPreview.decode(source, maximumDimension: 4096) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let version = WorkspaceFileVersion(data: data)
                let annotations = preview.animationFrameCount <= 1
                    ? await ImageAnnotationSidecar.load(image: path, backend: backend, version: version, size: preview.pixelSize)
                    : nil
                return LoadedContent(
                    content: .image(preview), text: "", encoding: nil,
                    decodingFailed: false, sourceVersion: version, annotations: annotations
                )
            }
            invalidRaster = false
        } catch {
            try Task.checkCancellation()
            // A recognized magic prefix is only a candidate (e.g. a plain
            // text file starting with GIF89a). Preserve genuinely valid text.
            invalidRaster = true
        }
        if data.count <= maxTextBytes {
            let decoded = await TextFileEncoding.decode(data, path: path, backend: backend, override: override)
            switch decoded {
            case .success(let document):
                return LoadedContent(content: .text, text: document.text,
                                     encoding: document.encoding, decodingFailed: false,
                                     sourceVersion: WorkspaceFileVersion(data: data),
                                     textPreservesOriginalBytes: document.encoding.encoded(document.text) == data)
            case .failure(let failure) where !invalidRaster:
                let unknownTextEncoding: Bool
                if case .binary = failure { unknownTextEncoding = false }
                else { unknownTextEncoding = true }
                return LoadedContent(content: .unavailable(failure.message), text: "",
                                     encoding: nil, decodingFailed: unknownTextEncoding, sourceVersion: nil)
            case .failure: break
            }
        } else if !invalidRaster {
            throw WorkspaceError.tooLarge
        }
        return LoadedContent(
            content: .unavailable(String(localized: "Image is too large or invalid", table: "Workspace")),
            text: "", encoding: nil, decodingFailed: false, sourceVersion: nil
        )
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
    var resourceDirectory: String?
    var rendersOnlyPreview = false
    var onMarkdownLink: (URL) async -> Bool = { _ in false }
    var onRevealFileSource: () -> Void = {}

    private let settings = AppSettings.shared
    private let themeChanges = Theme.changes
    @State private var windowReference = FileWindowReference()
    @Environment(\.appearsActive) private var appearsActive
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
                    } else if let error = file.delimitedTable.editError {
                        errorBar(error)
                    }
                    if (file.showsFilePreview || rendersOnlyPreview), let kind = file.previewKind {
                        switch kind {
                        case .markdown:
                            MarkdownFilePreview(
                                file: file, directory: resourceDirectory, assetRefresh: file.previewAssetRevision,
                                onOpenLink: onMarkdownLink,
                                onLocateSource: { offset in
                                    file.pendingMarkdownSource = (
                                        request: file.textPreviewRequestID, offset: offset, focus: true
                                    )
                                    revealSource()
                                    if file.editorCoordinator?.locateMarkdownSource(
                                        atUTF16Offset: offset
                                    ) == true {
                                        file.pendingMarkdownSource = nil
                                    }
                                }
                            )
                        case .delimited:
                            CSVTableView(file: file, canFocus: canFocus, onFocused: onFocused,
                                         onShowSource: revealSource)
                        case .svg:
                            SVGFilePreview(file: file, onFocused: onFocused, onShowSource: revealSource)
                        case .html:
                            HTMLFilePreview(file: file, directory: resourceDirectory, canFocus: canFocus,
                                            onFocused: onFocused, onShowSource: revealSource)
                        }
                    } else if !rendersOnlyPreview {
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
                }
            case .image(let image):
                let revision = file.reloadRevision
                VStack(spacing: 0) {
                    if let error = file.reloadError {
                        errorBar(error)
                    }
                    if let error = file.annotationError { errorBar(error) }
                    if let error = file.saveError { errorBar(error) }
                    ImageInspector(image: image, loadOriginal: file.originalImageRequest(),
                                   playback: file.gifPlayback, loadAnimation: file.gifFramesRequest(),
                                   resourceRevision: file.fileContentRevision,
                                   annotationFile: file, onFocused: onFocused,
                                   viewportPosition: file.graphicViewportPosition,
                                   onViewportPositionChange: { position in
                        guard case .image = file.content, file.reloadRevision == revision else { return }
                        file.graphicViewportPosition = position
                    })
                        .id(revision)
                }
            case .media(let media):
                if let player = file.mediaPlayer {
                    let active = isFocused && appearsActive && !file.mediaSleeping
                    Group {
                        if media.kind == .audio {
                            FileAudioControls(player: player)
                                .frame(maxWidth: 520).frame(height: 32)
                                .padding(.horizontal, 12)
                                .onChange(of: active, initial: true) { _, active in
                                    if !active { player.pause() }
                                }
                        } else {
                            let surface = NativePlayerView(player: player, allowsFullScreen: true, isDockActive: active)
                            if let aspectRatio = media.videoAspectRatio {
                                surface.aspectRatio(aspectRatio, contentMode: .fit)
                            } else {
                                surface
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(ObjectIdentifier(player))
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { [weak player] _ in
                        player?.pause()
                    }
                    .onDisappear { [weak player] in player?.pause() }
                }
            case .loading:
                Color.clear
            case .unavailable(let reason):
                VStack(spacing: 8) {
                    MaterialFileIconView(path: file.path, size: 28, opacity: 0.72)
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if !file.isMediaFile { encodingMenu }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FileWindowReader(reference: windowReference).frame(width: 0, height: 0))
        .onAppear {
            if rendersOnlyPreview { file.loadIfNeeded() }
            else { file.refreshWhenSelected() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard notification.object as? NSWindow === windowReference.window else { return }
            if rendersOnlyPreview || file.showsFilePreview { file.refreshPreviewAssets() }
            if !rendersOnlyPreview, file.readOnlyReason == nil { file.refreshWhenSelected() }
        }
    }

    private func revealSource() {
        if rendersOnlyPreview { onRevealFileSource() }
        else { file.setFilePreview(false) }
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
            .disabled(file.isDirty || file.hasPendingDelimitedEdit)
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
