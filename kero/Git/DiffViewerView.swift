//
//  DiffViewerView.swift
//  kero
//

import AppKit
import Foundation
import Observation
import SwiftUI

/// Lightweight UI state that should follow Kero across launches without
/// becoming a user-facing TOML setting.
@MainActor
@Observable
final class DiffViewPreferences {
    static let shared = DiffViewPreferences()

    private static let layoutKey = "diffView.layout"
    private static let modeKey = "diffView.mode"
    @ObservationIgnored private let defaults: UserDefaults

    var diffStyle: DiffLayoutStyle {
        didSet {
            defaults.set(diffStyle.rawValue, forKey: Self.layoutKey)
        }
    }

    var prefersEditing: Bool {
        didSet {
            defaults.set(
                prefersEditing ? "edit" : "review",
                forKey: Self.modeKey
            )
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rawValue = defaults.string(forKey: Self.layoutKey),
           let style = DiffLayoutStyle(rawValue: rawValue) {
            diffStyle = style
        } else {
            diffStyle = .unified
        }
        prefersEditing = defaults.string(forKey: Self.modeKey) == "edit"
    }
}

/// Values match the existing persisted unified/split preference.
enum DiffLayoutStyle: String {
    case unified
    case split
}

/// One native review artifact shared across the unified and split layouts.
nonisolated struct DiffDisplay {
    let id = UUID()
    let computation: DiffComputation
    let unifiedText: NSAttributedString
    let leftText: NSAttributedString
    let rightText: NSAttributedString
}

private nonisolated struct DiffDisplayInputs {
    let core: DiffCore
    let oldRuns: [DiffHighlightRun]
    let newRuns: [DiffHighlightRun]
}

/// A git diff opened as a tab from the git panel. Loads both sides of the
/// change (via `git show` / the worktree) so they survive tab switches;
/// reloads when the view reappears.
@MainActor
@Observable
final class DiffTab: nonisolated Identifiable {
    nonisolated let id = UUID()

    /// Absolute repository root the diff runs in.
    let repoRoot: String
    /// Repo-relative path, as porcelain reports it.
    let path: String
    /// Diffs HEAD → index instead of index → worktree.
    let staged: Bool
    var untracked: Bool {
        didSet { if untracked != oldValue { onSnapshotChange?() } }
    }
    @ObservationIgnored var onSnapshotChange: (() -> Void)?
    /// Historical commit shown by this tab. Nil keeps the existing
    /// index/worktree behavior.
    let commitHash: String?
    /// First parent and name-status metadata used to describe a historical
    /// comparison in the tab strip.
    let commitParentHash: String?
    let commitStatus: Character?
    /// Previous path when the change is a rename/copy; the "before" side
    /// reads from here so renames diff old file → new file like VS Code.
    var origPath: String? {
        didSet { if origPath != oldValue { onSnapshotChange?() } }
    }

    private(set) var error: String?
    private(set) var isLoading = true
    private(set) var isUnmerged = false
    private(set) var isEditable = false
    private(set) var isDirty = false
    var saveError: String?
    /// Why this file cannot be written, or nil while it is writable. Set when
    /// the remote machine it lives on is no longer reachable.
    private(set) var readOnlyReason: String?

    let preferences: DiffViewPreferences
    private(set) var oldContent = ""
    private(set) var newContent = ""
    private(set) var display: DiffDisplay?
    private(set) var editDecorations = DiffDecorations.empty
    /// Owned by the tab, never by a transient SwiftUI mount.
    @ObservationIgnored var nativeSurface: DiffNativeSurface?
    var hasChanges: Bool { oldContent != newContent }
    var isEditing: Bool { isEditableNow && preferences.prefersEditing }

    private nonisolated static let maxBytes = 5 << 20
    @ObservationIgnored private var savedNewContent = ""
    @ObservationIgnored private(set) var editedNewContent = ""
    @ObservationIgnored private(set) var editBufferRevision: UInt = 0
    @ObservationIgnored private var displayGeneration: UInt = 0
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var displayInputs: DiffDisplayInputs?
    @ObservationIgnored private var runExpansions: [Int: DiffRunExpansion] = [:]
    @ObservationIgnored private var editGeneration: UInt = 0
    @ObservationIgnored private var editTask: Task<Void, Never>?
    @ObservationIgnored private var reloadGeneration: UInt = 0
    @ObservationIgnored private var targetGeneration: UInt = 0
    /// The workspace this diff reads. The tab keeps its own, so it never
    /// follows the session onto another machine — and re-binds to a new
    /// connection to the same machine when one arrives.
    @ObservationIgnored private var backend: WorkspaceBackend
    /// The workspace this diff belongs to: nil for this Mac, else the machine
    /// it was opened from. Part of the tab's identity, so the same path on two
    /// machines is two tabs, and a diff opened locally is never read-only.
    let workspaceIdentity: String?

    init(
        repoRoot: String,
        path: String,
        staged: Bool,
        untracked: Bool,
        origPath: String?,
        commitHash: String? = nil,
        commitParentHash: String? = nil,
        commitStatus: Character? = nil,
        backend: WorkspaceBackend,
        workspaceIdentity: String?,
        preferences: DiffViewPreferences = .shared
    ) {
        self.backend = backend
        self.workspaceIdentity = workspaceIdentity
        self.preferences = preferences
        self.repoRoot = repoRoot
        self.path = path
        self.staged = staged
        self.untracked = untracked
        self.origPath = origPath
        self.commitHash = commitHash
        self.commitParentHash = commitParentHash
        self.commitStatus = commitStatus
        reload()
    }

    /// Whether the file can be edited right now: a regular worktree file whose
    /// machine is still reachable.
    var isEditableNow: Bool {
        isEditable && readOnlyReason == nil
    }

    // MARK: - Remote workspace

    /// Re-checks this tab against the project's connections: adopts a live
    /// workspace for its own machine, or marks it read-only. Driven by the
    /// project rather than by the session the tab was opened from, because a
    /// user who reconnects in another terminal of the same project is
    /// reconnecting to the same machine.
    func reevaluateWorkspace(in project: Project) {
        guard let workspaceIdentity else { return }
        guard let live = project.connectedWorkspace(for: workspaceIdentity) else {
            setReadOnly(true, destination: workspaceIdentity)
            return
        }
        guard readOnlyReason != nil || (backend as AnyObject) !== (live as AnyObject) else { return }
        if readOnlyReason == nil {
            targetGeneration &+= 1
            reloadGeneration &+= 1
        }
        // A reconnection is a new channel; reading or saving over the old one
        // fails, so the tab takes the live one.
        backend = live
        setReadOnly(false, destination: workspaceIdentity)
        // No-op while the buffer is dirty, so edits made during the outage
        // survive and can now be saved.
        reload()
    }

    private func setReadOnly(_ isReadOnly: Bool, destination: String) {
        let reason = isReadOnly
            ? String(
                localized: "Disconnected from \(destination) — read-only until reconnected", table: "Git",
                comment: "Diff banner. The placeholder is a remote machine as user@host."
            )
            : nil
        guard readOnlyReason != reason else { return }
        targetGeneration &+= 1
        reloadGeneration &+= 1
        readOnlyReason = reason
        // Going offline hides the editable pane; publish its unsaved text to
        // the read-only diff instead of making the draft disappear on screen.
        if isReadOnly, isDirty, newContent != editedNewContent {
            newContent = editedNewContent
            runExpansions.removeAll()
            recomputeDisplay()
        }
        // An edit made before the connection dropped remains saveable once
        // the original machine is reachable again.
        if isEditing { refreshEditDecorations(immediate: true) }
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    var title: String {
        if let commitHash {
            let after = "\(name) (\(commitHash.prefix(7)))"
            guard let commitParentHash else { return after }
            let beforeName = ((origPath ?? path) as NSString).lastPathComponent
            let before = "\(beforeName) (\(commitParentHash.prefix(7)))"
            switch commitStatus {
            case "A": return after
            case "D": return before
            default: return "\(before) ↔ \(after)"
            }
        }
        return staged
            ? String(localized: "\(name) (Staged)", table: "Git", comment: "Tab title for the staged diff of a file.")
            : name
    }

    /// Tab strip and switcher label. A remote diff says which machine it is
    /// on; a local diff reads exactly as it always has.
    var tabTitle: String {
        guard let workspaceIdentity else { return title }
        return "\(workspaceIdentity): \(title)"
    }

    func reload() {
        // Keep the editor's document and undo history stable until the user
        // leaves edit mode, and never replace an unsaved buffer from disk.
        // While the machine is unreachable both sides can only fail to load,
        // and an error would replace the diff the user was reading.
        guard readOnlyReason == nil, !isEditing, !isDirty else { return }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        error = nil
        let root = repoRoot
        let path = path
        let oldPath = origPath ?? path
        let staged = staged
        let untracked = untracked
        let commitHash = commitHash

        let backend = self.backend

        Task { [weak self] in
            // Git first, on its own thread, exactly as before.
            let git = await Task.detached(priority: .userInitiated) {
                var failureVar: String?
                // Only a live worktree diff can be unmerged, and the check is
                // a Git call, so it stays behind that test rather than inside
                // a short-circuit that cannot await.
                var unmerged = false
                if commitHash == nil, !staged {
                    unmerged = await Self.isUnmerged(
                        path: path, in: root, backend: backend
                    )
                }
                // A later side must not clear an earlier side's failure, so
                // each result only overwrites it when it carries one.
                func take(_ result: (text: String, error: String?)) -> String {
                    if let error = result.error { failureVar = error }
                    return result.text
                }
                let old: String
                // Non-nil only when git supplies the "after" side too; a live
                // worktree diff reads that side from the workspace below.
                var newFromGit: String?
                if let commitHash {
                    old = take(await Self.firstGitContent(
                        ["\(commitHash)^:\(oldPath)"], in: root, backend: backend
                    ))
                    newFromGit = take(await Self.firstGitContent(
                        ["\(commitHash):\(path)"], in: root, backend: backend
                    ))
                } else if staged {
                    old = take(await Self.firstGitContent(
                        ["HEAD:\(oldPath)"], in: root, backend: backend
                    ))
                    newFromGit = take(await Self.firstGitContent(
                        [":\(path)"], in: root, backend: backend
                    ))
                } else if untracked {
                    old = ""
                } else {
                    // An unmerged index has no stage-0 `:path`. Prefer our
                    // side, then the merge base, so conflict rows show a
                    // meaningful before-side instead of the whole file as new.
                    old = take(await Self.firstGitContent(
                        [":\(oldPath)", ":2:\(oldPath)", ":1:\(oldPath)", "HEAD:\(oldPath)"],
                        in: root,
                        backend: backend
                    ))
                }
                return (
                    old: old,
                    newFromGit: newFromGit,
                    failure: failureVar,
                    unmerged: unmerged
                )
            }.value

            var failure = git.failure
            let new: String
            let editable: Bool
            if let newFromGit = git.newFromGit {
                new = newFromGit
                editable = false
            } else {
                let worktree = await Self.readWorktreeFile(
                    root: root, path: path, backend: backend
                )
                new = worktree.text
                if let error = worktree.error { failure = error }
                editable = await Self.isEditableWorktreeFile(
                    root: root, path: path, backend: backend
                )
            }
            let result = (
                old: git.old,
                new: new,
                failure: failure,
                unmerged: git.unmerged,
                editable: editable
            )
            // The connection may have dropped while these reads were in
            // flight; their failure must not become the tab's content.
            guard let self, self.reloadGeneration == generation,
                  self.readOnlyReason == nil
            else { return }
            self.isLoading = false
            guard !self.isEditing, !self.isDirty else { return }
            self.error = result.failure
            self.isUnmerged = result.unmerged
            self.isEditable = result.editable && result.failure == nil
            let changed = self.oldContent != result.old || self.newContent != result.new
            self.oldContent = result.old
            self.newContent = result.new
            if changed { self.runExpansions.removeAll() }
            if changed || (self.hasChanges && self.display == nil) {
                self.recomputeDisplay()
            }
            self.editBufferRevision &+= 1
            self.savedNewContent = result.new
            self.editedNewContent = result.new
            if self.isEditing { self.refreshEditDecorations(immediate: true) }
            self.isDirty = false
            self.saveError = nil
        }
    }

    /// Refreshes a live diff when navigation brings it back on screen.
    /// Historical blobs are immutable and already loaded by `init`; rerunning
    /// Git operations and recomputing native rows on every project switch
    /// would waste work without changing the visible diff. An initial live load also
    /// stays in flight rather than being duplicated by the view's first mount.
    func refreshWhenSelected() {
        guard commitHash == nil, !isLoading else { return }
        reload()
    }

    /// Keep the native TextKit buffer as the editing source of truth.
    func updateEditedContent(_ contents: String) {
        guard isEditable else { return }
        editedNewContent = contents
        isDirty = contents != savedNewContent
        if isDirty { reloadGeneration &+= 1 }
        refreshEditDecorations()
    }

    func setDiffStyle(_ style: DiffLayoutStyle) {
        guard preferences.diffStyle != style else { return }
        nativeSurface?.rememberScrollAnchor()
        preferences.diffStyle = style
    }

    func setEditing(_ editing: Bool) {
        guard isEditableNow, editing != isEditing else { return }
        nativeSurface?.rememberScrollAnchor()
        if !editing && newContent != editedNewContent {
            newContent = editedNewContent
            runExpansions.removeAll()
            recomputeDisplay()
        }
        preferences.prefersEditing = editing
        if editing { refreshEditDecorations(immediate: true) }
    }


    /// Generate review rows and syntax tokens off the main actor. Superseded
    /// results never overwrite a newer local/remote target or edit.
    func recomputeDisplay() {
        displayGeneration &+= 1
        let generation = displayGeneration
        guard hasChanges, error == nil else {
            display = nil
            displayInputs = nil
            return
        }
        let before = oldContent
        let after = newContent
        let path = path
        let expansions = runExpansions
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let font = TerminalFont.current()
        let paragraphStyle = DiffTypography.paragraphStyle(for: font)
        let textColor = Theme.terminal(dark: dark).foregroundNSColor
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            let context = await DiffSyntaxHighlighter.context(for: path)
            let result = await Task.detached(priority: .userInitiated) {
                let inputs = DiffDisplayInputs(
                    core: DiffCore.compute(oldText: before, newText: after),
                    oldRuns: context.map { DiffSyntaxHighlighter.runs(text: before, context: $0) } ?? [],
                    newRuns: context.map { DiffSyntaxHighlighter.runs(text: after, context: $0) } ?? []
                )
                return (inputs, Self.makeDisplay(
                    inputs: inputs, expansions: expansions,
                    font: font, paragraphStyle: paragraphStyle, textColor: textColor
                ))
            }.value
            guard let self, !Task.isCancelled, self.displayGeneration == generation else { return }
            self.displayInputs = result.0
            self.display = result.1
        }
    }

    private nonisolated static func makeDisplay(
        inputs: DiffDisplayInputs, expansions: [Int: DiffRunExpansion],
        font: NSFont, paragraphStyle: NSParagraphStyle, textColor: NSColor
    ) -> DiffDisplay {
        let computation = DiffComputation.build(core: inputs.core, expansions: expansions)
        let base: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor, .paragraphStyle: paragraphStyle,
        ]
        return DiffDisplay(
            computation: computation,
            unifiedText: DiffSyntaxHighlighter.attributedDocument(
                computation.unified, oldRuns: inputs.oldRuns, newRuns: inputs.newRuns,
                baseAttributes: base
            ),
            leftText: DiffSyntaxHighlighter.attributedDocument(
                computation.splitLeft, oldRuns: inputs.oldRuns, newRuns: inputs.newRuns,
                baseAttributes: base
            ),
            rightText: DiffSyntaxHighlighter.attributedDocument(
                computation.splitRight, oldRuns: inputs.oldRuns, newRuns: inputs.newRuns,
                baseAttributes: base
            )
        )
    }

    func expandRun(_ fold: DiffCollapsedRun) {
        guard hasChanges else { return }
        var expansion = runExpansions[fold.runIndex] ?? DiffRunExpansion()
        switch fold.direction {
        case .revealUp: expansion.fromEnd += DiffCollapse.expansionLineCount
        case .revealDown: expansion.fromStart += DiffCollapse.expansionLineCount
        case .both:
            expansion.fromStart += DiffCollapse.expansionLineCount
            expansion.fromEnd += DiffCollapse.expansionLineCount
        }
        runExpansions[fold.runIndex] = expansion
        // Reuse the parsed diff and syntax runs; only the folded document changes.
        guard let inputs = displayInputs else {
            recomputeDisplay()
            return
        }
        displayGeneration &+= 1
        let generation = displayGeneration
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let font = TerminalFont.current()
        let style = DiffTypography.paragraphStyle(for: font)
        let color = Theme.terminal(dark: dark).foregroundNSColor
        let expansions = runExpansions
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            let display = await Task.detached(priority: .userInitiated) {
                Self.makeDisplay(
                    inputs: inputs, expansions: expansions, font: font,
                    paragraphStyle: style, textColor: color
                )
            }.value
            guard let self, !Task.isCancelled, self.displayGeneration == generation else { return }
            self.display = display
        }
    }

    func refreshEditDecorations(immediate: Bool = false) {
        editGeneration &+= 1
        let generation = editGeneration
        let before = oldContent
        let after = editedNewContent
        let oldRuns = displayInputs?.oldRuns ?? []
        let font = TerminalFont.current()
        let style = DiffTypography.paragraphStyle(for: font)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = Theme.terminal(dark: dark)
        let color = theme.foregroundNSColor
        let emphasis = theme.backgroundNSColor.blended(
            withFraction: 0.38, of: theme.paletteNSColor(1) ?? .systemRed
        ) ?? .systemRed
        editTask?.cancel()
        editTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let decoration = await Task.detached(priority: .userInitiated) {
                let (oldLines, _) = DiffLineSplitter.lines(of: before)
                let (newLines, _) = DiffLineSplitter.lines(of: after)
                let ops = DiffEngine.lineOps(old: oldLines, new: newLines)
                let state = DiffComputation.editState(
                    ops: ops, oldLines: oldLines, newLines: newLines
                )
                let base: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: color, .paragraphStyle: style,
                ]
                let ghosts = state.ghosts.map { block in
                    DiffDecorations.GhostBlock(
                        anchorLine: block.anchorLine,
                        firstOldLine: block.firstOldLine,
                        lines: DiffSyntaxHighlighter.attributedGhostLines(
                            oldText: before as NSString, block: block, runs: oldRuns,
                            baseAttributes: base, emphasisColor: emphasis
                        )
                    )
                }
                return DiffDecorations.edit(
                    state: state, snapshotOffsets: newLines.map(\.utf16Range.location),
                    lineCount: newLines.count, ghostBlocks: ghosts
                )
            }.value
            guard let self, !Task.isCancelled, self.editGeneration == generation else { return }
            self.editDecorations = decoration
        }
    }

    /// No parallel editor state: the native STTextView keeps selection and undo.
    func refreshNativeAppearance() {
        recomputeDisplay()
        if isEditing { refreshEditDecorations(immediate: true) }
    }

    func save() async {
        guard isEditable, isDirty else { return }
        // Refused, not silently dropped: the save-error bar says why.
        if let readOnlyReason {
            saveError = readOnlyReason
            return
        }
        let filePath = (repoRoot as NSString).appendingPathComponent(path)
        let written = editedNewContent
        let target = backend
        let generation = targetGeneration
        reloadGeneration &+= 1
        do {
            try await target.write(path: filePath, data: Data(written.utf8))
            guard generation == targetGeneration, readOnlyReason == nil else { return }
            savedNewContent = written
            // An edit landing while the write was in flight stays dirty.
            isDirty = editedNewContent != savedNewContent
            saveError = nil
        } catch {
            guard generation == targetGeneration else { return }
            saveError = error.localizedDescription
        }
    }

    private nonisolated enum GitContent {
        case missing
        case content(String)
        case binary
        case tooLarge
    }

    /// The first spec that exists, and the reason the diff cannot be shown if
    /// one of them is unusable. The error is returned rather than written
    /// through `inout` so it cannot cross a suspension point, and so a caller
    /// reading two sides only overwrites its failure on a real one.
    private nonisolated static func firstGitContent(
        _ specs: [String], in root: String, backend: WorkspaceBackend
    ) async -> (text: String, error: String?) {
        for spec in specs {
            switch await gitContent(spec, in: root, backend: backend) {
            case .missing:
                continue
            case .content(let content):
                return (content, nil)
            case .binary:
                return ("", String(localized: "Binary file", table: "Git"))
            case .tooLarge:
                return ("", String(localized: "File is too large to diff", table: "Git"))
            }
        }
        return ("", nil)
    }

    private nonisolated static func gitContent(
        _ spec: String, in root: String, backend: WorkspaceBackend
    ) async -> GitContent {
        let size = await GitCommandExecution.run(
            ["cat-file", "-s", spec], in: root, backend: backend
        )
        guard size.status == 0 else { return .missing }
        let byteCount = Int(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard byteCount <= maxBytes else { return .tooLarge }
        let run = await GitCommandExecution.runData(
            ["cat-file", "blob", spec], in: root, stdoutLimit: maxBytes + 1, backend: backend
        )
        guard run.status == 0 else { return .missing }
        guard run.stdout.count <= maxBytes else { return .tooLarge }
        guard !run.stdout.contains(0),
              let content = String(data: run.stdout, encoding: .utf8)
        else {
            return .binary
        }
        return .content(content)
    }

    private nonisolated static func isUnmerged(
        path: String, in root: String, backend: WorkspaceBackend
    ) async -> Bool {
        let run = await GitCommandExecution.run(
            ["--literal-pathspecs", "ls-files", "--unmerged", "--", path],
            in: root, backend: backend
        )
        return run.status == 0 && !run.stdout.isEmpty
    }

    /// Editing is limited to regular worktree files. In particular, writing a
    /// symlink atomically would replace the link itself with a regular file.
    private nonisolated static func isEditableWorktreeFile(
        root: String, path: String, backend: WorkspaceBackend
    ) async -> Bool {
        let filePath = (root as NSString).appendingPathComponent(path)
        guard let stat = try? await backend.stat(path: filePath) else { return false }
        return !stat.isSymlink && stat.isRegular
    }

    private nonisolated static func readWorktreeFile(
        root: String, path: String, backend: WorkspaceBackend
    ) async -> (text: String, error: String?) {
        let filePath = (root as NSString).appendingPathComponent(path)
        let symlink = (try? await backend.readSymlinkDestination(path: filePath)) ?? nil
        if let symlink {
            guard symlink.utf8.count <= maxBytes else {
                return ("", String(localized: "File is too large to diff", table: "Git"))
            }
            return (symlink, nil)
        }
        do {
            let data = try await backend.read(path: filePath, maxBytes: maxBytes)
            guard !data.contains(0),
                  let text = String(data: data, encoding: .utf8)
            else {
                return ("", String(localized: "Binary file", table: "Git"))
            }
            return (text, nil)
        } catch WorkspaceError.tooLarge {
            return ("", String(localized: "File is too large to diff", table: "Git"))
        } catch WorkspaceError.notFound {
            // Deleted from the worktree: an empty "after" side is the diff.
            return ("", nil)
        } catch {
            return ("", String(
                localized: "Unable to read file: \(error.localizedDescription)", table: "Git",
                comment: "Diff error followed by a system-provided error description."
            ))
        }
    }
}

/// Native TextKit-backed diff with a tab-retained editor and scroll state.
struct DiffViewerView: View {
    let diff: DiffTab
    private let themeChanges = Theme.changes
    private let settings = AppSettings.shared
    private let preferences: DiffViewPreferences
    /// The view stays mounted while other tabs are selected (see
    /// ContentView); this flags when it is the frontmost tab so content
    /// refreshes on each re-visit, not just on first mount.
    let isSelected: Bool

    init(diff: DiffTab, isSelected: Bool = true) {
        self.diff = diff
        preferences = diff.preferences
        self.isSelected = isSelected
    }

    var body: some View {
        let _ = themeChanges.revision
        let _ = preferences.prefersEditing
        let _ = preferences.diffStyle
        let _ = diff.editDecorations
        VStack(spacing: 0) {
            if let reason = diff.readOnlyReason {
                RemoteReadOnlyBanner(message: reason)
                    .frame(height: 22)
            }
            if diff.isUnmerged {
                conflictBanner
            }
            if let saveError = diff.saveError {
                saveErrorBar(saveError)
            }
            Group {
                if let error = diff.error {
                    placeholder(icon: "exclamationmark.triangle", text: error)
                } else if !diff.hasChanges {
                    if diff.isLoading {
                        initialLoadingSkeleton
                    } else if diff.isUnmerged {
                        placeholder(
                            icon: "arrow.triangle.merge",
                            text: String(localized: "Conflict is still unresolved", table: "Git")
                        )
                    } else {
                        placeholder(icon: "checkmark.circle", text: String(localized: "No changes", table: "Git"))
                    }
                } else {
                    VStack(spacing: 0) {
                        controlBar
                        if diff.display != nil {
                            DiffNativeRoot(diff: diff)
                        } else {
                            DiffSkeletonView()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if isSelected {
                diff.refreshWhenSelected()
            }
        }
        .onChange(of: isSelected) {
            if isSelected { diff.refreshWhenSelected() }
        }
        .onChange(of: settings.fontFamily) { _, _ in diff.refreshNativeAppearance() }
        .onChange(of: settings.fontSize) { _, _ in diff.refreshNativeAppearance() }
        .onChange(of: themeChanges.revision) { _, _ in diff.refreshNativeAppearance() }
    }

    private var conflictBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.merge")
            Text(String(localized: "Unresolved merge conflict", table: "Git"))
                .fontWeight(.medium)
            Spacer(minLength: 0)
            Text(String(localized: "Resolve before committing", table: "Git"))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.orange.opacity(0.22))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var controlBar: some View {
        DiffControlsBar(
            diffStyle: Binding(
                get: { preferences.diffStyle },
                set: { diff.setDiffStyle($0) }
            ),
            isEditing: Binding(
                get: { diff.isEditableNow && preferences.prefersEditing },
                set: { diff.setEditing($0) }
            ),
            canEdit: diff.isEditableNow
        )
        .frame(height: DiffViewerLayout.controlsHeight)
    }

    /// Reserve the toolbar row while the native diff is computing so its
    /// layout never jumps when the text panes become available.
    private var initialLoadingSkeleton: some View {
        VStack(spacing: 0) {
            DiffControlsSkeletonBar(
                showsModePlaceholder: diff.commitHash == nil && !diff.staged
            )
            .frame(height: DiffViewerLayout.controlsHeight)
            DiffSkeletonView()
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveErrorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(String(localized: "Could not save: \(message)", table: "Git"))
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

private enum DiffViewerLayout {
    static let controlsHeight: CGFloat = 37
}

/// Native controls for the materially changed diff toolbar. The surrounding
/// diff view is legacy SwiftUI, but new interaction stays in AppKit.
private struct DiffControlsBar: NSViewRepresentable {
    @Binding var diffStyle: DiffLayoutStyle
    @Binding var isEditing: Bool
    let canEdit: Bool

    func makeNSView(context: Context) -> DiffControlsNSView {
        DiffControlsNSView()
    }

    func updateNSView(_ view: DiffControlsNSView, context: Context) {
        view.update(
            diffStyle: diffStyle,
            isEditing: isEditing,
            canEdit: canEdit,
            onDiffStyleChange: { diffStyle = $0 },
            onEditingChange: { isEditing = $0 }
        )
    }
}

/// Matches the native controls row while the diff metadata is still loading.
/// Keeping this in AppKit gives the placeholder the same sizing and divider
/// behavior as the toolbar that replaces it.
private struct DiffControlsSkeletonBar: NSViewRepresentable {
    let showsModePlaceholder: Bool

    func makeNSView(context: Context) -> DiffControlsSkeletonNSView {
        DiffControlsSkeletonNSView()
    }

    func updateNSView(_ view: DiffControlsSkeletonNSView, context: Context) {
        view.update(showsModePlaceholder: showsModePlaceholder)
    }
}

private final class DiffControlsSkeletonNSView: NSView {
    private let modePlaceholder = NSView()
    private let layoutPlaceholder = NSView()
    private let divider = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)

        for placeholder in [modePlaceholder, layoutPlaceholder] {
            placeholder.wantsLayer = true
            placeholder.layer?.cornerRadius = 5
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            addSubview(placeholder)
        }

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            layoutPlaceholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            layoutPlaceholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            layoutPlaceholder.widthAnchor.constraint(equalToConstant: 111),
            layoutPlaceholder.heightAnchor.constraint(equalToConstant: 20),
            modePlaceholder.trailingAnchor.constraint(
                equalTo: layoutPlaceholder.leadingAnchor, constant: -8
            ),
            modePlaceholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            modePlaceholder.widthAnchor.constraint(equalToConstant: 93),
            modePlaceholder.heightAnchor.constraint(equalToConstant: 20),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(showsModePlaceholder: Bool) {
        updateAppearanceColors()
        modePlaceholder.isHidden = !showsModePlaceholder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.background.cgColor
            divider.layer?.backgroundColor = Theme.divider.cgColor
            let fill = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            modePlaceholder.layer?.backgroundColor = fill
            layoutPlaceholder.layer?.backgroundColor = fill
        }
    }
}

private final class DiffControlsNSView: NSView {
    private let modeControl = NSSegmentedControl(
        labels: [
            String(localized: "Review", table: "Git", comment: "Read-only mode for a diff."),
            String(localized: "Edit", table: "Git", comment: "Editable mode for a diff."),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let layoutControl = NSSegmentedControl(
        labels: [
            String(localized: "Unified", table: "Git", comment: "A single-column diff layout."),
            String(localized: "Split", table: "Git", comment: "A side-by-side diff layout."),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let divider = NSView()
    private var onDiffStyleChange: ((DiffLayoutStyle) -> Void)?
    private var onEditingChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        for control in [modeControl, layoutControl] {
            control.controlSize = .small
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
        }
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel(String(localized: "Diff Mode", table: "Git"))
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)
        layoutControl.setAccessibilityLabel(String(localized: "Diff Layout", table: "Git"))

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)

        NSLayoutConstraint.activate([
            layoutControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            layoutControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            modeControl.trailingAnchor.constraint(equalTo: layoutControl.leadingAnchor, constant: -8),
            modeControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        diffStyle: DiffLayoutStyle,
        isEditing: Bool,
        canEdit: Bool,
        onDiffStyleChange: @escaping (DiffLayoutStyle) -> Void,
        onEditingChange: @escaping (Bool) -> Void
    ) {
        self.onDiffStyleChange = onDiffStyleChange
        self.onEditingChange = onEditingChange
        updateAppearanceColors()

        layoutControl.selectedSegment = diffStyle == .split ? 1 : 0
        modeControl.isHidden = !canEdit
        modeControl.setEnabled(canEdit, forSegment: 1)
        modeControl.selectedSegment = canEdit && isEditing ? 1 : 0
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
        modeControl.needsDisplay = true
        layoutControl.needsDisplay = true
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.background.cgColor
            divider.layer?.backgroundColor = Theme.divider.cgColor
        }
    }

    @objc private func modeChanged() {
        onEditingChange?(modeControl.selectedSegment == 1)
    }

    @objc private func layoutChanged() {
        onDiffStyleChange?(layoutControl.selectedSegment == 1 ? .split : .unified)
    }
}

/// Code-shaped gray bars shown while native diff computation completes.
private struct DiffSkeletonView: View {
    /// (indent level, width fraction) per line, repeated to fill the pane.
    private static let pattern: [(indent: CGFloat, width: CGFloat)] = [
        (0, 0.42), (1, 0.62), (1, 0.30), (1, 0.55),
        (2, 0.38), (2, 0.50), (1, 0.24), (0, 0.16),
    ]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<24, id: \.self) { index in
                    let line = Self.pattern[index % Self.pattern.count]
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: geo.size.width * line.width * 0.55, height: 9)
                        .padding(.leading, line.indent * 18)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}
