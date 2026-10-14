//
//  GitStatusModel.swift
//  kero
//

import Dispatch
import Foundation
import Observation

/// Loads repository state in response to explicit UI events and performs
/// source-control operations without blocking the UI.
@MainActor
@Observable
final class GitStatusModel {
    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        var id: String { path }
        /// Relative to the repository root, as porcelain v2 reports it.
        let path: String
        /// Index (staged) status letter, "." when clean, "?" for untracked.
        let staged: Character
        /// Worktree (unstaged) status letter.
        let unstaged: Character
        var isConflict = false
        /// Previous path for renames/copies (porcelain "2" entries).
        var origPath: String?
        /// Canonical repo that produced this snapshot. Mutations reject stale
        /// rows after the active terminal moves to another repository.
        var repositoryRoot = ""

        var fileName: String { (path as NSString).lastPathComponent }
        var directory: String {
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir
        }
        /// Intent-to-add (`git add -N`) is represented as `.A`; restoring it
        /// from the empty index blob would truncate user content, so destructive
        /// handling treats it like an untracked file and uses the Trash.
        var isIntentToAdd: Bool { staged == "." && unstaged == "A" }
        var isUntracked: Bool { staged == "?" || isIntentToAdd }
        var isWorktreeRename: Bool { unstaged == "R" && origPath != nil }
        var isWorktreeCopy: Bool { unstaged == "C" && origPath != nil }

    }

    typealias FileDecoration = TreeDisplayModel.Status

    nonisolated enum CommitAction: CaseIterable, Sendable {
        case checkout, cherryPick, revert, merge, rebase, reset, drop

        var title: String {
            switch self {
            case .checkout: String(localized: "Checkout Commit…", table: "Git")
            case .cherryPick: String(localized: "Cherry Pick Commit…", table: "Git")
            case .revert: String(localized: "Revert Commit…", table: "Git")
            case .merge: String(localized: "Merge Commit into Current Branch…", table: "Git")
            case .rebase: String(localized: "Rebase Current Branch onto Commit…", table: "Git")
            case .reset: String(localized: "Reset Current Branch to Commit…", table: "Git")
            case .drop: String(localized: "Drop Commit…", table: "Git")
            }
        }
    }

    nonisolated enum ResetMode: String, CaseIterable, Sendable {
        case soft, mixed, hard

        var title: String {
            switch self {
            case .soft: String(localized: "Soft — keep index and working files", table: "Git")
            case .mixed: String(localized: "Mixed — reset index, keep working files", table: "Git")
            case .hard: String(localized: "Hard — overwrite index and working files", table: "Git")
            }
        }
    }

    nonisolated struct ActionTarget: Sendable {
        fileprivate let generation: UInt
        let repository: String
        let scope: String
        fileprivate let head: String?
        fileprivate let branch: String?
    }

    func actionTarget() -> ActionTarget {
        .init(generation: contextGeneration, repository: repoRoot, scope: currentScope,
              head: headOID, branch: branch)
    }

    func isCurrent(_ target: ActionTarget, requiresStableHead: Bool = true) -> Bool {
        hasResolvedPanelTarget && isRepo && target.generation == contextGeneration && target.repository == repoRoot
            && target.scope == currentScope
            && (!requiresStableHead || (target.head == headOID && target.branch == branch))
    }

    nonisolated static func dropCommitPossible(
        _ selected: String, head: String?, parents: [String: [String]]
    ) -> Bool {
        guard let head, let selectedParents = parents[selected], !selectedParents.isEmpty else { return false }
        var children: [String: [String]] = [:]
        for (commit, ancestors) in parents {
            for ancestor in ancestors { children[ancestor, default: []].append(commit) }
        }
        var current = selected
        var containsHead = false
        while let ancestors = parents[current] {
            guard ancestors.count <= 1 else { return false }
            let descendants = children[current] ?? []
            guard descendants.count <= 1 else { return false }
            containsHead = containsHead || current == head
            guard let child = descendants.first else { return containsHead }
            current = child
        }
        return false
    }

    func canDrop(_ commit: RecentCommit) -> Bool {
        Self.dropCommitPossible(commit.hash, head: headOID,
                                parents: Dictionary(uniqueKeysWithValues: recentCommits.map { ($0.hash, $0.parentHashes) }))
    }

    nonisolated static func parseCommitTopology(_ output: String) -> [String: [String]]? {
        var parents: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            guard let hash = fields.first, parents[hash] == nil,
                  fields.allSatisfy({ ($0.count == 40 || $0.count == 64) && $0.allSatisfy(\.isHexDigit) }) else { return nil }
            parents[hash] = Array(fields.dropFirst())
        }
        return parents
    }

    func actOnCommit(
        _ commit: RecentCommit, action: CommitAction, target: ActionTarget,
        parent: Int = 1, recordOrigin: Bool = false, noCommit: Bool = false,
        noFastForward: Bool = true, squash: Bool = false,
        resetMode: ResetMode = .mixed, ignoreDate: Bool = true,
        interactiveLaunch: (@MainActor () throws -> Void)? = nil,
        selectedRef: (name: String, oid: String)? = nil,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isCurrent(target), repositoryOperation == nil,
              commit.hash.count == 40 || commit.hash.count == 64,
              commit.hash.allSatisfy({ $0.isHexDigit }),
              commit.parentHashes.count < 2 || (1...commit.parentHashes.count).contains(parent)
        else {
            failImmediately(String(localized: "The Git action target changed. Reopen the menu and try again.", table: "Git"), completion: completion)
            return
        }
        var arguments: [String]
        switch action {
        case .checkout:
            arguments = ["switch", "--detach", commit.hash]
        case .cherryPick:
            arguments = ["cherry-pick"]
            if commit.parentHashes.count > 1 { arguments += ["-m", String(parent)] }
            if recordOrigin { arguments.append("-x") }
            if noCommit { arguments.append("--no-commit") }
            arguments.append(commit.hash)
        case .revert:
            arguments = ["revert", "--no-edit"]
            if commit.parentHashes.count > 1 { arguments += ["-m", String(parent)] }
            arguments.append(commit.hash)
        case .merge:
            arguments = ["merge", "--no-edit"]
            if squash { arguments.append("--squash") }
            else if noFastForward { arguments.append("--no-ff") }
            if noCommit { arguments.append("--no-commit") }
            arguments.append(commit.hash)
        case .rebase:
            arguments = ["rebase"]
            if ignoreDate { arguments.append("--ignore-date") }
            arguments.append(commit.hash)
        case .reset:
            arguments = ["reset", "--" + resetMode.rawValue, commit.hash]
        case .drop:
            guard canDrop(commit) else {
                failImmediately(String(localized: "This commit cannot be dropped from the current HEAD without crossing a merge or fork.", table: "Git"), completion: completion)
                return
            }
            arguments = ["rebase", "--onto", commit.hash + "^", commit.hash]
        }
        perform(
            label: action == .rebase && interactiveLaunch != nil
                ? String(localized: "Launch Interactive Rebase", table: "Git") : action.title,
            commands: action == .rebase && interactiveLaunch != nil ? [] : [arguments],
            squashMessage: action == .merge && squash && !noCommit
                ? "Merge commit '\(commit.hash)'" : nil,
            dropCommit: action == .drop ? commit.hash : nil,
            terminalAction: action == .rebase ? interactiveLaunch : nil,
            expectedRef: selectedRef,
            prepare: prepare,
            isCurrentTarget: {
                self.isCurrent(target) && (isCurrentTarget?() ?? true)
            }, completion: completion
        )
    }

    nonisolated struct RecentCommit: Identifiable, Equatable, Sendable {
        nonisolated struct Reference: Identifiable, Hashable, Sendable {
            enum Kind: String, Sendable {
                case currentBranch, localBranch, remoteBranch, tag, detachedHead
            }

            let kind: Kind
            let name: String
            var id: String { kind.rawValue + ":" + name }
        }

        nonisolated struct FileChange: Identifiable, Equatable, Sendable {
            let status: Character
            let path: String
            let originalPath: String?

            var id: String {
                "\(status)\u{0}\(originalPath ?? "")\u{0}\(path)"
            }
            var fileName: String { (path as NSString).lastPathComponent }
            var directory: String {
                let dir = (path as NSString).deletingLastPathComponent
                return dir.isEmpty ? "" : dir
            }
        }

        var id: String { hash }
        let hash: String
        let shortHash: String
        let subject: String
        let author: String
        let date: Date
        let parentHashes: [String]
        let references: [Reference]
        let files: [FileChange]

        var relativeDate: String {
            date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        }
    }

    nonisolated struct Operation: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            case running
            case succeeded
            case failed(exitCode: Int32)
        }

        let id: UUID
        let label: String
        var state: State
        var output: String
        var failedCommand: [String]? = nil
        var gitError: String? = nil
        let startedAt: Date
        var finishedAt: Date?

        var isRunning: Bool { state == .running }

        var statusLabel: String {
            switch state {
            case .running:
                return String(localized: "\(label)…", table: "Git", comment: "A Git operation that is still running.")
            case .succeeded:
                return String(localized: "\(label) completed", table: "Git", comment: "A Git operation that completed successfully.")
            case .failed:
                return String(localized: "\(label) failed", table: "Git", comment: "A Git operation that failed.")
            }
        }
    }

    private(set) var rootPath = ""
    /// Stable canonical repository root, used by the UI to key drafts. It is
    /// preserved while a cwd change is being resolved inside the same repo.
    private(set) var repositoryIdentity = ""
    private(set) var isRepo = false
    private(set) var fileDecorations: [String: FileDecoration] = [:]
    /// Relative porcelain paths. Directory records retain their trailing slash
    /// so expanded descendants can inherit the ignored state.
    private(set) var ignoredPaths: Set<String> = []
    private(set) var branch: String?
    private(set) var headOID: String?
    private(set) var hasHead = true
    private(set) var upstream: String?
    private(set) var ahead = 0
    private(set) var behind = 0
    private(set) var hasUpstream = false
    private(set) var lineAdditions = 0
    private(set) var lineDeletions = 0
    private(set) var mergeEntries: [Entry] = []
    private(set) var stagedEntries: [Entry] = []
    private(set) var changedEntries: [Entry] = []
    nonisolated struct GitRef: Equatable, Sendable {
        let oid: String
        let symbolic: String?
        let objectType: String
    }

    nonisolated enum TagType: Sendable { case annotated, lightweight }

    nonisolated struct TagDetails: Sendable {
        nonisolated enum Verification: Sendable { case unsigned, valid, unverified }
        let name: String
        let objectOID: String
        let commitOID: String
        let tagger: String
        let message: String
        let verification: Verification
    }

    /// Each expanded commit is queried once, not each file or each hover.
    func loadHistoricalBinaryPaths(for commit: RecentCommit) {
        guard isRepo, recentCommits.contains(where: { $0.hash == commit.hash }),
              historicalBinaryPaths[commit.hash] == nil,
              pendingBinaryCommits.insert(commit.hash).inserted else { return }
        let generation = contextGeneration
        let selectedRoot = repoRoot
        let selectedBackend = backend
        Task { [weak self] in
            let binary = await Task.detached(priority: .utility) {
                let result = await GitCommandExecution.runData(
                    ["show", "--format=", "--numstat", "-z",
                     "--diff-merges=first-parent", commit.hash],
                    in: selectedRoot, stdoutLimit: (2 << 20) + 1,
                    backend: selectedBackend
                )
                guard result.status == 0, result.stdout.count <= (2 << 20),
                      let binary = Self.parseHistoricalBinaryPaths(result.stdout)
                else { return Optional<Set<String>>.none }
                return binary
            }.value
            guard let self, self.contextGeneration == generation,
                  self.repoRoot == selectedRoot else { return }
            self.pendingBinaryCommits.remove(commit.hash)
            if let binary { self.historicalBinaryPaths[commit.hash] = binary }
        }
    }

    nonisolated static func parseHistoricalBinaryPaths(_ output: Data) -> Set<String>? {
        let entries = output.split(separator: 0, omittingEmptySubsequences: true)
        var binary: Set<String> = []
        var i = 0
        while i < entries.count {
            let fields = entries[i].split(separator: 9, maxSplits: 2,
                                          omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            let isBinary = fields[0] == Data("-".utf8) && fields[1] == Data("-".utf8)
            let filename: Data
            if fields[2].isEmpty {
                guard i + 2 < entries.count else { return nil }
                filename = Data(entries[i + 2])
                i += 3
            } else {
                filename = Data(fields[2])
                i += 1
            }
            guard let path = String(data: filename, encoding: .utf8) else { return nil }
            if isBinary { binary.insert(path) }
        }
        return binary
    }

    func isHistoricalBinaryFile(commit: RecentCommit, path: String) -> Bool {
        historicalBinaryPaths[commit.hash]?.contains(path) == true
    }

    func isAnnotatedTag(named name: String) -> Bool {
        refsByName["refs/tags/" + name]?.objectType == "tag"
    }

    private(set) var refsByName: [String: GitRef] = [:]
    /// Loaded only when a historical commit's files are expanded. No per-row
    /// SSH queries or eager binary inspection during regular status refresh.
    private(set) var historicalBinaryPaths: [String: Set<String>] = [:]
    @ObservationIgnored private var pendingBinaryCommits = Set<String>()

    nonisolated struct RemoteBranchTarget: Sendable {
        let remote: String
        let branch: String
        let oid: String
    }

    func remoteBranch(named displayName: String) -> RemoteBranchTarget? {
        // Names such as `origin/team/topic` may fit more than one configured
        // remote. The longest configured prefix owns the selected ref.
        let matched = remotes
            .filter { displayName.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        guard let remote = matched,
              let ref = refsByName["refs/remotes/" + displayName],
              ref.symbolic == nil else { return nil }
        return RemoteBranchTarget(
            remote: remote,
            branch: String(displayName.dropFirst(remote.count + 1)),
            oid: ref.oid
        )
    }

    private(set) var branches: [String] = []
    private(set) var defaultBranch: String?
    private(set) var remotes: [String] = []
    private(set) var recentCommits: [RecentCommit] = []
    private(set) var hasMoreRecentCommits = false
    private(set) var isLoadingMoreCommits = false
    private(set) var repositoryOperation: String?
    private(set) var stashCount = 0
    private(set) var isRefreshing = false
    /// True once a status load has completed for the current `rootPath`. The
    /// UI keeps showing resolved content during later event-driven refreshes
    /// instead of flashing a loading placeholder.
    private(set) var hasResolvedStatus = false
    private(set) var statusError: String?
    /// True while a user-initiated Git operation runs.
    private(set) var isBusy = false
    private(set) var operation: Operation?
    var lastError: String?

    /// Absolute repository root. Porcelain paths are relative to this path,
    /// not necessarily to the terminal's current working directory.
    private var topLevel = ""
    /// Invalidates async refreshes and operations after the terminal changes cwd.
    private var contextGeneration: UInt = 0
    private var workspaceScope = "local"
    var currentScope: String { workspaceScope }
    private var scopedRoot: String { workspaceScope + "\u{0}" + rootPath }
    private var commitMessagesByRepository: [String: String] = [:]

    private var commitDraftKey: String? {
        guard isRepo, !repositoryIdentity.isEmpty else { return nil }
        return workspaceScope + "\u{0}" + repositoryIdentity
    }

    var commitMessage: String {
        get { commitDraftKey.flatMap { commitMessagesByRepository[$0] } ?? "" }
        set {
            guard let key = commitDraftKey else { return }
            commitMessagesByRepository[key] = newValue
        }
    }
    /// Restores a previously resolved directory immediately when switching
    /// tabs. Without this, every return to a repository clears `isRepo` until
    /// the asynchronous Git refresh finishes, briefly removing the toolbar
    /// and resizing the terminal through the wrong height.
    private var cachedStatusByRoot: [String: StatusLoadResult] = [:]
    /// Invalidates an in-flight status refresh when a mutation begins, so its
    /// pre-operation snapshot cannot overwrite the post-operation state.
    private var statusRequestID: UInt = 0
    /// Coalesces an event that arrives while another refresh or mutation is
    /// running. Without polling, dropping that event could leave the snapshot
    /// stale indefinitely.
    private var refreshPending = false
    private static let recentCommitPageSize = 30
    private var recentCommitLimit = recentCommitPageSize
    private var recentCommitLimitByRoot: [String: Int] = [:]
    /// Folding a Git directory is navigation state, not part of a status
    /// refresh. Key by machine and root so different repositories stay apart.
    private var collapsedFoldersByRoot: [String: Set<String>] = [:]

    var collapsedFolders: Set<String> {
        get { collapsedFoldersByRoot[scopedRoot] ?? [] }
        set { collapsedFoldersByRoot[scopedRoot] = newValue }
    }

    func toggleCollapsedFolder(_ key: String) {
        var folders = collapsedFolders
        if !folders.insert(key).inserted { folders.remove(key) }
        collapsedFolders = folders
    }

    /// Keeps a mutation globally exclusive even if the terminal changes cwd
    /// while its Git process is still running.
    private var runningOperationID: UUID?
    var totalChangeCount: Int {
        mergeEntries.count + stagedEntries.count + changedEntries.count
    }

    /// True while the first status load for the current directory is still in
    /// flight, so later event-driven refreshes do not replace resolved content
    /// with a loading state.
    var isResolvingInitialStatus: Bool {
        isRefreshing && !hasResolvedStatus
    }

    var repoRoot: String {
        topLevel.isEmpty ? rootPath : topLevel
    }

    func absolutePath(for entry: Entry) -> String {
        let base = entry.repositoryRoot.isEmpty ? repoRoot : entry.repositoryRoot
        return (base as NSString).appendingPathComponent(entry.path)
    }

    func isCurrent(_ entry: Entry) -> Bool {
        hasResolvedPanelTarget && (entry.repositoryRoot.isEmpty || entry.repositoryRoot == repoRoot)
    }

    /// Returns a Git decoration only when `absolutePath` belongs to the
    /// currently resolved repository. Plain folders therefore keep the normal
    /// file-tree appearance, even when their names resemble ignored paths.
    func fileDecoration(for absolutePath: String, isDirectory: Bool) -> FileDecoration? {
        guard isRepo, !topLevel.isEmpty else { return nil }
        let repositoryPath = (topLevel as NSString).standardizingPath
        let itemPath = (absolutePath as NSString).standardizingPath
        let relativePath: String
        if itemPath == repositoryPath {
            relativePath = ""
        } else {
            let prefix = repositoryPath + "/"
            guard itemPath.hasPrefix(prefix) else { return nil }
            relativePath = String(itemPath.dropFirst(prefix.count))
        }

        if let decoration = fileDecorations[relativePath] {
            return decoration
        }
        if ignoredPaths.contains(where: { ignoredPath in
            if ignoredPath.hasSuffix("/") {
                let directory = String(ignoredPath.dropLast())
                return relativePath == directory || relativePath.hasPrefix(directory + "/")
            }
            return relativePath == ignoredPath
        }) {
            return .ignored
        }
        guard isDirectory, !relativePath.isEmpty else { return nil }

        let descendantPrefix = relativePath + "/"
        return fileDecorations
            .filter { $0.key.hasPrefix(descendantPrefix) }
            .map(\.value)
            .max { $0.directoryPriority < $1.directoryPriority }
    }

    /// The workspace selected by the project's current panel context.
    private var backend: WorkspaceBackend = LocalWorkspaceBackend.shared
    @ObservationIgnored private var panelResolveGeneration: UInt64 = 0
    private var panelTargetIdentity: PanelContext.Identity?
    private var isResolvingPanelTarget = false
    private var hasResolvedPanelTarget: Bool { !isResolvingPanelTarget }

    func matchesPanelTarget(_ identity: PanelContext.Identity) -> Bool {
        panelTargetIdentity == identity
    }

    /// Only the focused project's latest directory resolution may select a
    /// repository. Its backend can complete after the user switches projects.
    func syncSelectedProject(in manager: TerminalManager) {
        panelResolveGeneration &+= 1
        let generation = panelResolveGeneration
        guard let project = manager.selectedProject,
              let context = project.panelContext else {
            sync(root: "")
            return
        }
        if panelTargetIdentity != context.identity {
            contextGeneration &+= 1
            invalidateStatusRefresh()
            panelTargetIdentity = nil
            isResolvingPanelTarget = true
        }
        Task { [weak self, weak manager, weak project] in
            let root = await context.resolvedRoot().root
            guard let self, let manager, let project,
                  self.panelResolveGeneration == generation,
                  manager.selectedProject === project,
                  project.matchesPanelTarget(context.identity) else { return }
            self.sync(root: root, backend: context.backend, scope: context.scope)
            self.panelTargetIdentity = context.identity
        }
    }

    /// Omitting the backend selects the Mac; scope keeps cached state and
    /// drafts distinct when the same path exists on another machine.
    func sync(root: String, backend: WorkspaceBackend? = nil, scope: String = "local") {
        panelTargetIdentity = nil
        isResolvingPanelTarget = false
        let targetBackend = backend ?? LocalWorkspaceBackend.shared
        let channelChanged = (self.backend as AnyObject) !== (targetBackend as AnyObject)
        self.backend = targetBackend
        if root != rootPath || workspaceScope != scope {
            workspaceScope = scope
            contextGeneration &+= 1
            rootPath = root
            recentCommitLimit = recentCommitLimitByRoot[scopedRoot]
                ?? Self.recentCommitPageSize
            hasResolvedStatus = false
            clearRepositoryState(preserveIdentity: true)
            if let cachedStatus = cachedStatusByRoot[scopedRoot] {
                apply(cachedStatus)
                hasResolvedStatus = true
            }
        } else if channelChanged {
            // A new SSH channel must not queue behind a worker stalled on the
            // previous connection, even when the host and repository match.
            contextGeneration &+= 1
            invalidateStatusRefresh()
        }
        refresh()
    }

    func refresh() {
        let root = rootPath
        let generation = contextGeneration
        let commitLimit = recentCommitLimit
        guard !root.isEmpty else { return }
        guard !isRefreshing, !isBusy else {
            refreshPending = true
            return
        }
        refreshPending = false
        statusRequestID &+= 1
        let requestID = statusRequestID
        isRefreshing = true

        // This is deliberately independent of the worker. Even filesystem
        // metadata calls can become uninterruptible on a disconnected volume;
        // the sidebar must still leave its initial loading state and offer a
        // retry while the stale worker winds down in the background.
        let refreshTimeout: Duration = backend is LocalWorkspaceBackend
            ? .seconds(12) : .seconds(30)
        Task { [weak self] in
            try? await Task.sleep(for: refreshTimeout)
            guard let self,
                  self.isRefreshing,
                  self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.rootPath == root else { return }
            self.statusRequestID &+= 1
            self.isRefreshing = false
            self.isLoadingMoreCommits = false
            self.refreshPending = false
            self.apply(.failed(String(localized: "Git did not respond in time.", table: "Git")))
            self.hasResolvedStatus = true
        }

        let backend = backend
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await Self.runGitStatus(
                    in: root, recentCommitLimit: commitLimit, backend: backend
                )
            }.value
            guard let self, self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.rootPath == root else { return }
            self.isRefreshing = false
            // A pagination request may have arrived while this older snapshot
            // was already running. Keep its loading state latched until the
            // queued refresh using the larger limit finishes.
            self.isLoadingMoreCommits = commitLimit < self.recentCommitLimit
            switch result {
            case .repository, .notRepository:
                self.cachedStatusByRoot[self.scopedRoot] = result
            case .failed:
                break
            }
            self.apply(result)
            self.hasResolvedStatus = true
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    @discardableResult
    func loadMoreCommits() -> Bool {
        guard isRepo, hasMoreRecentCommits,
              !isLoadingMoreCommits, !isBusy else { return false }
        recentCommitLimit += Self.recentCommitPageSize
        recentCommitLimitByRoot[scopedRoot] = recentCommitLimit
        isLoadingMoreCommits = true
        if isRefreshing {
            // The active worker captured the previous limit. Queue a second
            // refresh instead of dropping the request made as the section is
            // opened near the end of the viewport.
            refreshPending = true
        } else {
            refresh()
        }
        return true
    }

    func dismissOperation() {
        guard operation?.isRunning != true else { return }
        operation = nil
        lastError = nil
    }

    /// A local item must still exist before opening the file editor. Remote
    /// tabs can be opened while disconnected and will remain read-only.
    func canOpen(_ entry: Entry, isRemote: Bool) -> Bool {
        guard isCurrent(entry) else { return false }
        return isRemote || FileManager.default.fileExists(atPath: absolutePath(for: entry))
    }

    // MARK: - Discard review

    /// Identity captured when the confirmation is prepared, before remote IO.
    /// A reconnect can replace the backend without changing its filesystem path.
    struct DiscardContext: Equatable {
        let repositoryRoot: String
        let scope: String
        let branch: String?
        let headOID: String?
        let generation: UInt
        let backendID: ObjectIdentifier
    }

    struct FileFingerprint: Equatable {
        let exists: Bool
        let size: UInt64
        let modificationDate: Date?
        let fileNumber: UInt64?
        let symbolicLinkDestination: String?
    }

    struct PendingDiscard {
        let entry: Entry
        let fingerprints: [String: FileFingerprint]
        let context: DiscardContext
    }

    enum DiscardReviewError: Error {
        case stale
    }

    private var discardContext: DiscardContext {
        DiscardContext(
            repositoryRoot: repoRoot, scope: workspaceScope, branch: branch,
            headOID: headOID, generation: contextGeneration,
            backendID: ObjectIdentifier(backend as AnyObject)
        )
    }

    private func discardPaths(for entry: Entry) -> [String] {
        var paths = [entry.path]
        if entry.isWorktreeRename, let original = entry.origPath {
            paths.append(original)
        }
        return paths
    }

    private func absoluteDiscardPath(_ path: String, for entry: Entry) -> String {
        let root = entry.repositoryRoot.isEmpty ? repoRoot : entry.repositoryRoot
        return (root as NSString).appendingPathComponent(path)
    }

    /// Keep the original local metadata, including inode and symlink target:
    /// WorkspaceStat cannot represent the inode used by this confirmation.
    private func localFingerprint(at path: String) -> FileFingerprint {
        let fm = FileManager.default
        let linkDestination = try? fm.destinationOfSymbolicLink(atPath: path)
        guard linkDestination != nil || fm.fileExists(atPath: path) else {
            return FileFingerprint(
                exists: false, size: 0, modificationDate: nil,
                fileNumber: nil, symbolicLinkDestination: nil
            )
        }
        let attributes = try? fm.attributesOfItem(atPath: path)
        return FileFingerprint(
            exists: true,
            size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes?[.modificationDate] as? Date,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
            symbolicLinkDestination: linkDestination
        )
    }

    private func remoteFingerprint(
        at path: String, backend: WorkspaceBackend
    ) async throws -> FileFingerprint {
        guard let stat = try await backend.stat(path: path) else {
            return FileFingerprint(
                exists: false, size: 0, modificationDate: nil,
                fileNumber: nil, symbolicLinkDestination: nil
            )
        }
        let target = stat.isSymlink
            ? try await backend.readSymlinkDestination(path: path) : nil
        return FileFingerprint(
            exists: true, size: UInt64(max(0, stat.size)), modificationDate: stat.mtime,
            fileNumber: nil, symbolicLinkDestination: target
        )
    }

    /// Native local confirmation opens immediately, with no new loading state.
    func prepareLocalDiscard(_ entries: [Entry]) -> [PendingDiscard] {
        guard backend is LocalWorkspaceBackend, isRepo else { return [] }
        let context = discardContext
        return entries.filter { isCurrent($0) && changedEntries.contains($0) }.map { entry in
            let fingerprints = Dictionary(uniqueKeysWithValues: discardPaths(for: entry).map {
                ($0, localFingerprint(at: absoluteDiscardPath($0, for: entry)))
            })
            return PendingDiscard(entry: entry, fingerprints: fingerprints, context: context)
        }
    }

    /// Remote metadata is gathered on the selected WorkspaceBackend, never on
    /// the Mac. The context must still match the identity held before awaits.
    func prepareRemoteDiscard(_ entries: [Entry]) async throws -> [PendingDiscard] {
        let selectedBackend = backend
        guard !(selectedBackend is LocalWorkspaceBackend), isRepo, !entries.isEmpty else {
            throw DiscardReviewError.stale
        }
        let context = discardContext
        guard entries.allSatisfy({ isCurrent($0) && changedEntries.contains($0) }) else {
            throw DiscardReviewError.stale
        }
        var reviews: [PendingDiscard] = []
        for entry in entries {
            var fingerprints: [String: FileFingerprint] = [:]
            for path in discardPaths(for: entry) {
                fingerprints[path] = try await remoteFingerprint(
                    at: absoluteDiscardPath(path, for: entry), backend: selectedBackend
                )
            }
            reviews.append(PendingDiscard(entry: entry, fingerprints: fingerprints, context: context))
        }
        guard reviews.allSatisfy(isReviewedDiscardCurrent) else {
            throw DiscardReviewError.stale
        }
        return reviews
    }

    private func isReviewedDiscardCurrent(_ review: PendingDiscard) -> Bool {
        isRepo && !isBusy && discardContext == review.context
            && isCurrent(review.entry) && changedEntries.contains(review.entry)
    }

    private func executeReviewedDiscard(_ reviews: [PendingDiscard]) {
        if reviews.count == 1 {
            discard(reviews[0].entry)
        } else {
            discardChanges(reviews.map(\.entry))
        }
    }

    /// Called on the destructive confirmation button, not on dialog opening.
    @discardableResult
    func confirmLocalDiscard(_ reviews: [PendingDiscard]) -> Bool {
        guard backend is LocalWorkspaceBackend, !reviews.isEmpty,
              reviews.allSatisfy(isReviewedDiscardCurrent),
              reviews.allSatisfy({ review in
                  review.fingerprints.allSatisfy { path, fingerprint in
                      localFingerprint(at: absoluteDiscardPath(path, for: review.entry)) == fingerprint
                  }
              }) else {
            cancelStaleDiscard()
            return false
        }
        executeReviewedDiscard(reviews)
        return true
    }

    /// Rechecks both the remote files and their original repository identity
    /// after each await, then starts the existing Git/Trash operation in place.
    @discardableResult
    func confirmRemoteDiscard(_ reviews: [PendingDiscard]) async -> Bool {
        let selectedBackend = backend
        guard !(selectedBackend is LocalWorkspaceBackend), !reviews.isEmpty,
              reviews.allSatisfy(isReviewedDiscardCurrent) else {
            cancelStaleDiscard()
            return false
        }
        for review in reviews {
            for (path, fingerprint) in review.fingerprints {
                guard let current = try? await remoteFingerprint(
                    at: absoluteDiscardPath(path, for: review.entry), backend: selectedBackend
                ), current == fingerprint, isReviewedDiscardCurrent(review) else {
                    cancelStaleDiscard()
                    return false
                }
            }
        }
        guard reviews.allSatisfy(isReviewedDiscardCurrent) else {
            cancelStaleDiscard()
            return false
        }
        executeReviewedDiscard(reviews)
        return true
    }

    // MARK: - File operations

    func stage(_ entry: Entry) {
        guard validate(entry) else { return }
        let original = entry.unstaged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        perform(
            label: String(localized: "Stage \(entry.fileName)", table: "Git"),
            commands: [["--literal-pathspecs", "add", "--"] + paths]
        )
    }

    func unstage(_ entry: Entry) {
        guard validate(entry) else { return }
        let original = entry.staged == "R" ? entry.origPath.map { [$0] } ?? [] : []
        let paths = [entry.path] + original
        let args = hasHead
            ? ["--literal-pathspecs", "restore", "--staged", "--"] + paths
            : ["--literal-pathspecs", "rm", "--cached", "-f", "--"] + paths
        perform(label: String(localized: "Unstage \(entry.fileName)", table: "Git"), commands: [args])
    }

    func stageAll() {
        perform(label: String(localized: "Stage all changes", table: "Git"), commands: [["add", "-A"]])
    }

    func unstageAll() {
        let args = hasHead
            ? ["restore", "--staged", "--", "."]
            : ["rm", "--cached", "-r", "-f", "--", "."]
        perform(label: String(localized: "Unstage all changes", table: "Git"), commands: [args])
    }

    /// Restores a tracked file from the index, or moves an untracked file to
    /// the Trash. The UI confirms before calling this.
    func discard(_ entry: Entry) {
        guard validate(entry) else { return }
        if entry.isIntentToAdd {
            perform(
                label: String(localized: "Remove intent-to-add for \(entry.fileName)", table: "Git"),
                commands: [[
                    "--literal-pathspecs", "rm", "--cached", "-f", "--", entry.path,
                ]], completion: { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: String(localized: "Move \(entry.fileName) to Trash", table: "Git"),
                    completedBefore: String(localized: "Removed the intent-to-add index entry.", table: "Git")
                )
            })
        } else if entry.isUntracked || entry.isWorktreeCopy {
            trash(
                paths: [entry.path],
                label: String(localized: "Move \(entry.fileName) to Trash", table: "Git")
            )
        } else if entry.isWorktreeRename, let original = entry.origPath {
            perform(
                label: String(localized: "Restore \((original as NSString).lastPathComponent)", table: "Git"),
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", original]],
                completion: { [weak self] success in
                guard success else { return }
                self?.trash(
                    paths: [entry.path],
                    label: String(localized: "Move \(entry.fileName) to Trash", table: "Git"),
                    completedBefore: String(localized: "Restored \((original as NSString).lastPathComponent).", table: "Git")
                )
            })
        } else {
            perform(
                label: String(localized: "Discard changes in \(entry.fileName)", table: "Git"),
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", entry.path]]
            )
        }
    }

    /// Discards only the confirmed snapshot. This prevents new files written
    /// by an agent while the dialog is open from joining a bulk destructive action.
    func discardChanges(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        guard entries.allSatisfy(isCurrent) else {
            cancelStaleDiscard()
            return
        }
        let intentToAdd = entries.filter(\.isIntentToAdd)
        let moved = entries.filter { $0.isWorktreeRename || $0.isWorktreeCopy }
        let untracked = entries.filter(\.isUntracked).map(\.path) + moved.map(\.path)
        let renamedOriginals = moved.filter(\.isWorktreeRename).compactMap(\.origPath)
        let tracked = entries.filter {
            !$0.isUntracked && !$0.isWorktreeRename && !$0.isWorktreeCopy
        }.map(\.path) + renamedOriginals
        var commands: [[String]] = []
        if !tracked.isEmpty {
            commands.append(["--literal-pathspecs", "restore", "--worktree", "--"] + tracked)
        }
        if !intentToAdd.isEmpty {
            commands.append(
                ["--literal-pathspecs", "rm", "--cached", "-f", "--"]
                    + intentToAdd.map(\.path)
            )
        }
        guard !commands.isEmpty || !untracked.isEmpty else { return }

        if commands.isEmpty {
            trash(paths: untracked, label: String(localized: "Move untracked files to Trash", table: "Git"))
        } else {
            var completedSteps: [String] = []
            if !tracked.isEmpty {
                completedSteps.append(
                    String(localized: "Restored \(tracked.count) tracked paths.", table: "Git")
                )
            }
            if !intentToAdd.isEmpty {
                completedSteps.append(
                    String(localized: "Removed \(intentToAdd.count) intent-to-add index entries.", table: "Git")
                )
            }
            perform(label: String(localized: "Discard all changes", table: "Git"), commands: commands, completion: { [weak self] success in
                guard success, !untracked.isEmpty else { return }
                self?.trash(
                    paths: untracked,
                    label: String(localized: "Finish discarding all changes", table: "Git"),
                    completedBefore: completedSteps.joined(separator: "\n")
                )
            })
        }
    }

    func cancelStaleDiscard() {
        failImmediately(String(localized: "Files changed while the confirmation was open. Review them and try again.", table: "Git"))
    }

    // MARK: - Commit and remote operations

    /// Commits only the index unless `includeAll` explicitly requests `git add -A`.
    func commit(
        message: String,
        includeAll: Bool,
        amend: Bool = false
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failImmediately(String(localized: "Enter a commit message", table: "Git"))
            return
        }
        guard includeAll || !stagedEntries.isEmpty || amend else {
            failImmediately(String(localized: "Stage changes before committing", table: "Git"))
            return
        }

        var commands: [[String]] = []
        if includeAll { commands.append(["add", "-A"]) }
        var commitArgs = ["commit"]
        if amend { commitArgs.append("--amend") }
        commitArgs += ["-m", trimmed]
        commands.append(commitArgs)
        let label = amend
            ? String(localized: "Amend commit", table: "Git")
            : (includeAll
                ? String(localized: "Stage all and commit", table: "Git")
                : String(localized: "Commit staged changes", table: "Git"))
        let draftKey = commitDraftKey
        perform(label: label, commands: commands, completion: { [weak self] success in
            if success, let self, let draftKey,
               self.commitMessagesByRepository[draftKey] == message {
                self.commitMessagesByRepository[draftKey] = ""
            }
        })
    }

    func fetch() {
        guard !remotes.isEmpty else {
            failImmediately(String(localized: "No Git remote is configured", table: "Git"))
            return
        }
        perform(
            label: String(localized: "Fetch", table: "Git"),
            commands: [["fetch", "--all", "--prune"]],
            requiresStableHead: false
        )
    }

    func pull() {
        guard hasUpstream else {
            failImmediately(String(localized: "This branch has no upstream to pull from", table: "Git"))
            return
        }
        perform(
            label: String(localized: "Pull", table: "Git"),
            commands: [["pull", "--ff-only"]],
            requiresStableUpstream: true
        )
    }

    func push() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD", table: "Git"))
            return
        }
        if hasUpstream {
            perform(label: String(localized: "Push", table: "Git"), commands: [["push"]], requiresStableUpstream: true)
            return
        }
        guard let remote = unambiguousRemote else {
            failImmediately(remotes.isEmpty
                ? String(localized: "Add a Git remote before publishing this branch", table: "Git")
                : String(localized: "Choose which remote should receive this branch", table: "Git"))
            return
        }
        perform(label: String(localized: "Publish branch", table: "Git"), commands: [["push", "-u", remote, "HEAD"]])
    }

    func publish(to remote: String) {
        guard branch != "detached HEAD" else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD", table: "Git"))
            return
        }
        guard remotes.contains(remote) else {
            failImmediately(String(localized: "The selected Git remote is no longer available", table: "Git"))
            return
        }
        perform(
            label: String(localized: "Publish branch to \(remote)", table: "Git"),
            commands: [["push", "-u", remote, "HEAD"]]
        )
    }

    func syncChanges() {
        guard branch != "detached HEAD" || hasUpstream else {
            failImmediately(String(localized: "Create or switch to a branch before publishing detached HEAD", table: "Git"))
            return
        }
        if hasUpstream {
            perform(
                label: String(localized: "Sync changes", table: "Git"),
                commands: [["pull", "--ff-only"], ["push"]],
                requiresStableUpstream: true
            )
        } else {
            guard let remote = unambiguousRemote else {
                failImmediately(remotes.isEmpty
                    ? String(localized: "Add a Git remote before publishing this branch", table: "Git")
                    : String(localized: "Choose which remote should receive this branch", table: "Git"))
                return
            }
            perform(label: String(localized: "Publish branch", table: "Git"), commands: [["push", "-u", remote, "HEAD"]])
        }
    }

    // MARK: - Branches, stash, and repository setup

    func switchBranch(
        to name: String,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !name.isEmpty, name != branch else {
            completion?(name == branch)
            return
        }
        perform(
            label: String(localized: "Switch to \(name)", table: "Git"),
            commands: [["switch", name]],
            prepare: prepare, isCurrentTarget: isCurrentTarget,
            completion: completion
        )
    }

    nonisolated enum BranchPushMode: String, CaseIterable, Sendable {
        case normal, forceWithLease, force
    }

    func preferredPushRemote(for name: String?) async -> String? {
        let available = remotes
        guard !available.isEmpty else { return nil }
        let generation = contextGeneration
        let result = await GitCommandExecution.run(
            ["config", "--null", "--get-regexp", "^(branch\\..*\\.(pushremote|remote)|remote\\.pushdefault)$"],
            in: repoRoot, backend: backend
        )
        guard generation == contextGeneration else { return nil }
        var config: [String: String] = [:]
        if result.status == 0 {
            for pair in result.stdout.split(separator: "\0") {
                guard let boundary = pair.firstIndex(of: "\n") else { continue }
                config[String(pair[..<boundary])] = String(pair[pair.index(after: boundary)...])
            }
        }
        let keys: [String] = name.map { ["branch.\($0).pushremote", "branch.\($0).remote"] } ?? []
        return (keys + ["remote.pushdefault"]).compactMap { config[$0] }
            .first(where: available.contains)
            ?? (available.contains("origin") ? "origin" : available.first)
    }

    func trackingRemotes(for name: String) -> [String] {
        remotes.filter { remote in
            let ref = refsByName["refs/remotes/\(remote)/\(name)"]
            return ref != nil && ref?.symbolic == nil
        }
    }

    func createBranch(
        named name: String, at hash: String?, checkout: Bool, replace: Bool,
        target: ActionTarget,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isCurrent(target, requiresStableHead: checkout) else {
            failImmediately(String(localized: "The Git action target changed. Reopen the menu and try again.", table: "Git"), completion: completion)
            return
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            failImmediately(String(localized: "Enter a branch name", table: "Git"), completion: completion)
            return
        }
        let existing = refsByName["refs/heads/" + name]
        guard !replace || existing != nil else {
            failImmediately(String(localized: "The selected branch no longer exists.", table: "Git"), completion: completion)
            return
        }
        let start = hash ?? "HEAD"
        let commands: [[String]]
        if replace {
            commands = [["branch", "-f", "--", name, start]]
                + (checkout ? [["switch", "--", name]] : [])
        } else if checkout {
            commands = [["switch", "-c", name, "--", start]]
        } else {
            commands = [["branch", "--", name, start]]
        }
        perform(label: String(localized: "Create branch \(name)", table: "Git"),
                commands: commands, requiresStableHead: checkout,
                preflight: [["check-ref-format", "--branch", name]],
                expectedRef: existing.map { (name: "refs/heads/" + name, oid: $0.oid) }.flatMap { replace ? $0 : nil },
                prepare: prepare, isCurrentTarget: isCurrentTarget, completion: completion)
    }

    func renameBranch(
        from oldName: String, to newName: String, target: ActionTarget,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let name = "refs/heads/" + oldName
        guard isCurrent(target, requiresStableHead: false), let ref = refsByName[name] else {
            failImmediately(String(localized: "The selected branch no longer exists.", table: "Git"), completion: completion)
            return
        }
        perform(label: String(localized: "Rename branch \(oldName)", table: "Git"),
                commands: [["branch", "-m", "--", oldName, newName]], requiresStableHead: false,
                preflight: [["check-ref-format", "--branch", newName]],
                expectedRef: (name, ref.oid), completion: completion)
    }

    func deleteBranch(
        _ name: String, force: Bool, remoteNames: [String], target: ActionTarget,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let full = "refs/heads/" + name
        guard isCurrent(target, requiresStableHead: false), let ref = refsByName[full],
              name != branch, remoteNames.allSatisfy({ trackingRemotes(for: name).contains($0) }) else {
            failImmediately(String(localized: "The selected branch no longer exists.", table: "Git"), completion: completion)
            return
        }
        let commands = [["branch", force ? "-D" : "-d", "--", name]]
            + remoteNames.map { ["push", $0, "--delete", full] }
        perform(label: String(localized: "Delete branch \(name)", table: "Git"),
                commands: commands, requiresStableHead: false,
                expectedRef: (full, ref.oid), continueAfterFirstSuccess: true,
                completion: completion)
    }

    func pushBranch(
        _ name: String, remotes selected: [String], setUpstream: Bool,
        mode: BranchPushMode, target: ActionTarget,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let full = "refs/heads/" + name
        guard isCurrent(target, requiresStableHead: false), let ref = refsByName[full],
              !selected.isEmpty, selected.allSatisfy(remotes.contains) else {
            failImmediately(String(localized: "The selected branch or remote is no longer available.", table: "Git"), completion: completion)
            return
        }
        let commands = selected.map { remote in
            var args = ["push"]
            if setUpstream { args.append("-u") }
            switch mode {
            case .normal: break
            case .forceWithLease: args.append("--force-with-lease")
            case .force: args.append("--force")
            }
            args += [remote, full + ":" + full]
            return args
        }
        perform(label: String(localized: "Push branch \(name)", table: "Git"),
                commands: commands, requiresStableHead: false,
                expectedRef: (full, ref.oid), completion: completion)
    }


    private func isSelectedRemoteBranchCurrent(
        _ selected: RemoteBranchTarget, target: ActionTarget
    ) -> Bool {
        guard isCurrent(target, requiresStableHead: false),
              let actual = remoteBranch(named: selected.remote + "/" + selected.branch)
        else { return false }
        return actual.remote == selected.remote && actual.branch == selected.branch
            && actual.oid == selected.oid
    }

    func checkoutRemoteBranch(
        _ selected: RemoteBranchTarget, localName: String,
        checkoutExistingAndPull: Bool, target: ActionTarget,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isSelectedRemoteBranchCurrent(selected, target: target) else {
            failImmediately(String(localized: "The selected Git reference changed. Reopen the menu and try again.", table: "Git"),
                            completion: completion)
            return
        }
        let localName = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localName.isEmpty else {
            failImmediately(String(localized: "Enter a branch name", table: "Git"), completion: completion)
            return
        }
        let trackingRef = "refs/remotes/" + selected.remote + "/" + selected.branch
        let serverRef = "refs/heads/" + selected.branch
        let commands: [[String]]
        if checkoutExistingAndPull {
            commands = [["switch", "--", localName],
                        ["pull", "--no-edit", selected.remote, serverRef]]
        } else {
            commands = [["switch", "-c", localName, "--track", trackingRef]]
        }
        perform(label: String(localized: "Checkout Remote Branch", table: "Git"),
                commands: commands,
                preflight: checkoutExistingAndPull ? [] : [["check-ref-format", "--branch", localName]],
                expectedRef: (trackingRef, selected.oid),
                prepare: prepare, isCurrentTarget: isCurrentTarget, completion: completion)
    }

    func fetchIntoLocalBranch(
        _ selected: RemoteBranchTarget, force: Bool, target: ActionTarget,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let localRef = "refs/heads/" + selected.branch
        guard isSelectedRemoteBranchCurrent(selected, target: target),
              refsByName[localRef] != nil, selected.branch != branch else {
            failImmediately(String(localized: "The selected branch or remote is no longer available.", table: "Git"),
                            completion: completion)
            return
        }
        let commands = [["fetch"] + (force ? ["-f"] : [])
                        + [selected.remote, "refs/heads/" + selected.branch + ":" + localRef]]
        perform(label: String(localized: "Fetch into Local Branch", table: "Git"),
                commands: commands, requiresStableHead: false,
                expectedRef: ("refs/remotes/" + selected.remote + "/" + selected.branch, selected.oid),
                completion: completion)
    }

    func pullRemoteBranch(
        _ selected: RemoteBranchTarget, noFastForward: Bool, squash: Bool,
        target: ActionTarget,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isSelectedRemoteBranchCurrent(selected, target: target) else {
            failImmediately(String(localized: "The selected Git reference changed. Reopen the menu and try again.", table: "Git"),
                            completion: completion)
            return
        }
        let options = squash ? ["--squash"] : (noFastForward ? ["--no-ff"] : [])
        perform(label: String(localized: "Pull Remote Branch", table: "Git"),
                commands: [["pull", "--no-edit"] + options
                           + [selected.remote, "refs/heads/" + selected.branch]],
                squashMessage: squash ? "Merge branch '\(selected.remote)/\(selected.branch)'" : nil,
                expectedRef: ("refs/remotes/" + selected.remote + "/" + selected.branch, selected.oid),
                prepare: prepare, isCurrentTarget: isCurrentTarget, completion: completion)
    }

    func deleteRemoteBranch(
        _ selected: RemoteBranchTarget, target: ActionTarget,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isSelectedRemoteBranchCurrent(selected, target: target) else {
            failImmediately(String(localized: "The selected Git reference changed. Reopen the menu and try again.", table: "Git"),
                            completion: completion)
            return
        }
        perform(label: String(localized: "Delete Remote Branch", table: "Git"),
                commands: [["push", selected.remote, "--delete", "refs/heads/" + selected.branch]],
                requiresStableHead: false,
                expectedRef: ("refs/remotes/" + selected.remote + "/" + selected.branch, selected.oid),
                completion: completion)
    }

    nonisolated enum ArchiveFormat: String, CaseIterable, Sendable {
        case zip, tar
    }

    /// The Git object is captured before the save sheet opens, so a later
    /// branch movement cannot quietly change the downloaded archive.
    func createArchive(
        reference: String, objectOID: String, format: ArchiveFormat,
        destination: URL, target: ActionTarget
    ) async {
        guard isCurrent(target, requiresStableHead: false),
              refsByName[reference]?.oid == objectOID, !isBusy,
              destination.isFileURL else {
            failImmediately(String(localized: "The selected Git reference changed. Reopen the menu and try again.", table: "Git"))
            return
        }
        let operationID = UUID()
        let generation = contextGeneration
        let panelIdentity = panelTargetIdentity
        let root = repoRoot
        let backend = backend
        runningOperationID = operationID
        isBusy = true
        lastError = nil
        operation = Operation(id: operationID,
                              label: String(localized: "Create Archive", table: "Git"),
                              state: .running, output: "", startedAt: Date(), finishedAt: nil)
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.contextGeneration == generation
                && self.panelTargetIdentity == panelIdentity
                && self.runningOperationID == operationID
                && self.isCurrent(target, requiresStableHead: false)
        }
        let result = await Task.detached(priority: .userInitiated) { () async -> (error: String?, output: String) in
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".kero-archive-" + UUID().uuidString + "." + format.rawValue)
            var remoteFolder: String?
            var output = ""
            var error: String?
            var destinationSaved = false
            do {
                guard await current() else {
                    throw NSError(domain: "KeroGitArchive", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "The Git action target changed. Reopen the menu and try again.", table: "Git")
                    ])
                }
                let live = await GitCommandExecution.run(
                    ["show-ref", "--verify", "--hash", reference], in: root, backend: backend
                )
                guard live.status == 0,
                      live.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == objectOID else {
                    throw NSError(domain: "KeroGitArchive", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "The selected Git reference changed. Reopen the menu and try again.", table: "Git")
                    ])
                }

                var archiveOutput = temporary.path
                if !(backend is LocalWorkspaceBackend) {
                    let created = try await backend.run(
                        argv: ["mktemp", "-d", "/tmp/kero-archive-XXXXXXXX"],
                        cwd: nil, env: nil, stdin: nil, timeout: 25
                    )
                    let folder = String(decoding: created.stdout, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard created.status == 0, folder.hasPrefix("/tmp/kero-archive-"),
                          !folder.contains("\n"), !folder.contains("\r") else {
                        throw NSError(domain: "KeroGitArchive", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: String(decoding: created.stderr, as: UTF8.self)
                        ])
                    }
                    remoteFolder = folder
                    archiveOutput = folder + "/archive." + format.rawValue
                }
                guard await current() else {
                    throw NSError(domain: "KeroGitArchive", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "The Git action target changed. Reopen the menu and try again.", table: "Git")
                    ])
                }
                let archived = await GitCommandExecution.run(
                    ["archive", "--format=" + format.rawValue, "-o", archiveOutput, objectOID],
                    in: root, backend: backend
                )
                guard archived.status == 0 else {
                    throw NSError(domain: "KeroGitArchive", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: archived.stderr
                    ])
                }
                output = "$ git archive --format=" + format.rawValue + " " + reference
                if remoteFolder != nil {
                    let maximumSize = 64 * 1024 * 1024
                    let data = try await backend.read(path: archiveOutput, maxBytes: maximumSize)
                    try data.write(to: temporary, options: .atomic)
                }
                guard await current() else {
                    throw NSError(domain: "KeroGitArchive", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "The Git action target changed. Reopen the menu and try again.", table: "Git")
                    ])
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                destinationSaved = true
            } catch WorkspaceError.tooLarge {
                error = String(localized: "Remote archive exceeds the 64 MiB transfer limit.", table: "Git")
            } catch let failure {
                error = failure.localizedDescription
            }
            if let remoteFolder {
                do { try await backend.delete(paths: [remoteFolder]) }
                catch let cleanupFailure {
                    let cleanup = String(localized: "Remote temporary archive could not be removed:", table: "Git")
                        + " " + remoteFolder + " (" + cleanupFailure.localizedDescription + ")"
                    let detail = destinationSaved
                        ? String(localized: "Archive saved to:", table: "Git") + " " + destination.path + "\n" + cleanup
                        : cleanup
                    error = [error, detail].compactMap { $0 }.joined(separator: "\n")
                }
            }
            try? FileManager.default.removeItem(at: temporary)
            return (error, output)
        }.value
        guard runningOperationID == operationID else { return }
        runningOperationID = nil
        isBusy = false
        guard contextGeneration == generation, panelTargetIdentity == panelIdentity else {
            refresh()
            return
        }
        let finished = Date()
        if let error = result.error {
            lastError = error
            operation = Operation(id: operationID,
                label: String(localized: "Create Archive", table: "Git"),
                state: .failed(exitCode: -1), output: error,
                startedAt: operation?.startedAt ?? finished, finishedAt: finished)
        } else {
            operation = Operation(id: operationID,
                label: String(localized: "Create Archive", table: "Git"),
                state: .succeeded, output: result.output,
                startedAt: operation?.startedAt ?? finished, finishedAt: finished)
        }
        refresh()
    }

    func createTag(
        named name: String, at commitOID: String, type: TagType, message: String,
        replace: Bool, target: ActionTarget,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isCurrent(target, requiresStableHead: false),
              recentCommits.contains(where: { $0.hash == commitOID }) else {
            failImmediately(String(
                localized: "Repository or commit changed; reopen the history menu and try again.",
                table: "Git"
            ), completion: completion)
            return
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            failImmediately(String(localized: "Enter a tag name", table: "Git"), completion: completion)
            return
        }
        let refName = "refs/tags/" + name
        let previous = refsByName[refName]
        if replace && previous == nil {
            failImmediately(String(
                localized: "The selected Git reference changed. Reopen the menu and try again.", table: "Git"
            ), completion: completion)
            return
        }
        var args = ["tag"]
        if replace { args.append("-f") }
        if type == .annotated { args += ["-a", "-m", message] }
        args += ["--", name, commitOID]
        perform(
            label: String(localized: "Create tag \(name)", table: "Git"),
            commands: [args], requiresStableHead: false,
            preflight: [["check-ref-format", refName]],
            expectedRef: replace ? previous.map { (name: refName, oid: $0.oid) } : nil,
            completion: completion
        )
    }

    func deleteTag(
        _ name: String, fromRemote selectedRemote: String?, target: ActionTarget,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let refName = "refs/tags/" + name
        guard isCurrent(target, requiresStableHead: false),
              let ref = refsByName[refName],
              selectedRemote.map(remotes.contains) ?? true else {
            failImmediately(String(
                localized: "The selected Git reference changed. Reopen the menu and try again.", table: "Git"
            ), completion: completion)
            return
        }
        // Delete on the selected remote first, as Git Graph does. The local
        // compare-and-delete protects a tag changed while that network call ran.
        var commands: [[String]] = []
        if let selectedRemote {
            commands.append(["push", selectedRemote, "--delete", refName])
        }
        commands.append(["update-ref", "-d", refName, ref.oid])
        perform(
            label: String(localized: "Delete tag \(name)", table: "Git"),
            commands: commands, requiresStableHead: false,
            expectedRef: (name: refName, oid: ref.oid),
            completion: completion
        )
    }

    func pushTag(
        _ name: String, to selectedRemotes: [String], target: ActionTarget,
        selectedOID: String? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let refName = "refs/tags/" + name
        guard isCurrent(target, requiresStableHead: false),
              let oid = selectedOID ?? refsByName[refName]?.oid, !selectedRemotes.isEmpty,
              selectedRemotes.allSatisfy(remotes.contains) else {
            failImmediately(String(
                localized: "The selected tag or remote is no longer available.", table: "Git"
            ), completion: completion)
            return
        }
        let commands = selectedRemotes.map {
            ["push", $0, refName + ":" + refName]
        }
        perform(
            label: String(localized: "Push tag \(name)", table: "Git"),
            commands: commands, requiresStableHead: false,
            expectedRef: (name: refName, oid: oid),
            completion: completion
        )
    }

    /// Resolve a just-created Tag before the asynchronous status refresh finishes.
    /// The peeled target must still be the Commit chosen in the original dialog.
    func tagOID(named name: String, pointingAt commitOID: String, target: ActionTarget) async -> String? {
        guard isCurrent(target, requiresStableHead: false) else { return nil }
        let generation = contextGeneration
        let reference = "refs/tags/" + name
        let peeled = await GitCommandExecution.run(
            ["rev-parse", "--verify", reference + "^{commit}"], in: repoRoot, backend: backend
        )
        let object = await GitCommandExecution.run(
            ["show-ref", "--verify", "--hash", reference], in: repoRoot, backend: backend
        )
        guard generation == contextGeneration, isCurrent(target, requiresStableHead: false),
              peeled.status == 0, object.status == 0,
              peeled.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == commitOID else {
            return nil
        }
        return object.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Git Graph's warning is about *known local tracking refs*, not a query
    /// of server-side history. Nil means Git could not evaluate that heuristic.
    func tagRemotesWithoutCommit(
        _ commitOID: String, selected: [String], target: ActionTarget
    ) async -> [String]? {
        guard isCurrent(target, requiresStableHead: false),
              selected.allSatisfy(remotes.contains) else { return nil }
        let currentScope = contextGeneration
        let result = await GitCommandExecution.run([
            "for-each-ref", "--contains=" + commitOID, "--format=%(refname)", "refs/remotes"
        ], in: repoRoot, backend: backend)
        guard currentScope == contextGeneration,
              isCurrent(target, requiresStableHead: false), result.status == 0 else { return nil }
        let containing = Set(result.stdout.split(separator: "\n").compactMap { raw -> String? in
            let name = String(raw)
            guard refsByName[name]?.symbolic == nil,
                  name.hasPrefix("refs/remotes/") else { return nil }
            return name
        })
        return selected.filter { remote in
            !containing.contains(where: { $0.hasPrefix("refs/remotes/" + remote + "/") })
        }
    }

    /// Reads details only when selected, not on every status or remote SSH poll.
    func tagDetails(named name: String, target: ActionTarget) async -> TagDetails? {
        let refName = "refs/tags/" + name
        guard isCurrent(target, requiresStableHead: false),
              let selected = refsByName[refName], selected.objectType == "tag" else {
            return nil
        }
        let generation = contextGeneration
        let object = await GitCommandExecution.run(
            ["cat-file", "-p", selected.oid], in: repoRoot, backend: backend
        )
        let commit = await GitCommandExecution.run(
            ["rev-parse", refName + "^{commit}"], in: repoRoot, backend: backend
        )
        guard generation == contextGeneration, isCurrent(target, requiresStableHead: false),
              refsByName[refName]?.oid == selected.oid else { return nil }
        guard object.status == 0, commit.status == 0,
              let boundary = object.stdout.range(of: "\n\n") else {
            failImmediately(String(localized: "Unable to read the selected annotated tag.", table: "Git"))
            return nil
        }
        let header = String(object.stdout[..<boundary.lowerBound])
        let body = String(object.stdout[boundary.upperBound...])
        let tagger = header.split(separator: "\n").first(where: { $0.hasPrefix("tagger ") })
            .map { String($0.dropFirst("tagger ".count)) } ?? ""
        let signatureRange = body.range(of: "-----BEGIN PGP SIGNATURE-----")
            ?? body.range(of: "-----BEGIN SSH SIGNATURE-----")
        let message = signatureRange
            .map { String(body[..<$0.lowerBound]) } ?? body
        let verification: TagDetails.Verification
        if signatureRange != nil {
            let check = await GitCommandExecution.run(
                ["verify-tag", refName], in: repoRoot, backend: backend
            )
            guard generation == contextGeneration, isCurrent(target, requiresStableHead: false),
                  refsByName[refName]?.oid == selected.oid else { return nil }
            verification = check.status == 0 ? .valid : .unverified
        } else {
            verification = .unsigned
        }
        return TagDetails(
            name: name, objectOID: selected.oid,
            commitOID: commit.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            tagger: tagger,
            message: message.trimmingCharacters(in: .newlines),
            verification: verification
        )
    }

    nonisolated struct FileState: Equatable, Sendable {
        let worktreeOID: String?
        let indexOID: String?
    }

    private nonisolated static func readHistoricalFileState(
        path: String, root: String, backend: WorkspaceBackend
    ) async -> FileState? {
        let index = await GitCommandExecution.run(
            ["rev-parse", "--verify", ":" + path], in: root, backend: backend
        )
        let worktree = await GitCommandExecution.run(
            ["hash-object", "--", path], in: root, backend: backend
        )
        guard [0, 128].contains(index.status), [0, 128].contains(worktree.status),
              worktree.status == 0 || worktree.stderr.contains("No such file") else { return nil }
        return FileState(
            worktreeOID: worktree.status == 0
                ? worktree.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            indexOID: index.status == 0
                ? index.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )
    }

    func historicalFileState(_ path: String, target: ActionTarget) async -> FileState? {
        guard isCurrent(target), !isBusy else { return nil }
        let generation = contextGeneration
        let snapshot = await Self.readHistoricalFileState(
            path: path, root: target.repository, backend: backend
        )
        guard generation == contextGeneration, isCurrent(target), !isBusy else { return nil }
        return snapshot
    }

    func resetHistoricalFile(
        _ path: String, at commit: RecentCommit, target: ActionTarget,
        expectedFileState: FileState,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isCurrent(target), !path.isEmpty,
              recentCommits.contains(where: { $0.hash == commit.hash }),
              commit.files.contains(where: { $0.path == path && $0.status != "D" }) else {
            failImmediately(String(localized: "The Git action target changed. Reopen the menu and try again.", table: "Git"),
                            completion: completion)
            return
        }
        perform(label: String(localized: "Reset File to Revision", table: "Git"),
                commands: [["--literal-pathspecs", "checkout", commit.hash, "--", path]],
                preflight: [["cat-file", "-e", commit.hash + ":" + path]],
                expectedFileState: (path, expectedFileState),
                prepare: prepare, isCurrentTarget: isCurrentTarget, completion: completion)
    }

    func stash(includeUntracked: Bool = true) {
        guard totalChangeCount > 0 else {
            failImmediately(String(localized: "There are no changes to stash", table: "Git"))
            return
        }
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        perform(label: String(localized: "Stash changes", table: "Git"), commands: [args])
    }

    func stashPop() {
        guard stashCount > 0 else {
            failImmediately(String(localized: "There are no stashes to pop", table: "Git"))
            return
        }
        perform(label: String(localized: "Pop stash", table: "Git"), commands: [["stash", "pop"]])
    }

    func initializeRepository(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !rootPath.isEmpty else {
            failImmediately(String(localized: "Open a terminal directory first", table: "Git"), completion: completion)
            return
        }
        perform(
            label: String(localized: "Initialize repository", table: "Git"),
            commands: [["init"]],
            directory: rootPath,
            completion: completion
        )
    }

    // MARK: - Operation runner

    private var unambiguousRemote: String? {
        remotes.count == 1 ? remotes[0] : nil
    }

    private func validate(_ entry: Entry) -> Bool {
        guard isCurrent(entry) else {
            failImmediately(String(localized: "Repository changed; refresh and try the Git action again", table: "Git"))
            return false
        }
        return true
    }

    private func perform(
        label: String,
        commands: [[String]],
        directory: String? = nil,
        requiresStableHead: Bool = true,
        requiresStableUpstream: Bool = false,
        squashMessage: String? = nil,
        dropCommit: String? = nil,
        terminalAction: (@MainActor () throws -> Void)? = nil,
        preflight: [[String]] = [], expectedRef: (name: String, oid: String)? = nil,
        expectedFileState: (path: String, state: FileState)? = nil,
        continueAfterFirstSuccess: Bool = false,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        if !hasResolvedPanelTarget || (directory == nil && !isRepo) {
            failImmediately(
                String(localized: "Repository changed; review the current directory and try the Git action again.", table: "Git"),
                completion: completion
            )
            return
        }
        let dir = directory ?? repoRoot
        let generation = contextGeneration
        let expectedPanelTarget = panelTargetIdentity
        let validationRoot = rootPath
        let expectedRepositoryRoot = directory == nil && isRepo ? repoRoot : nil
        let expectedHeadOID = headOID
        let expectedBranch = branch
        let expectedUpstream = upstream
        guard !dir.isEmpty, !isBusy, (!commands.isEmpty || terminalAction != nil) else {
            completion?(false)
            return
        }

        let operationID = UUID()
        invalidateStatusRefresh()
        runningOperationID = operationID
        isBusy = true
        lastError = nil
        operation = Operation(
            id: operationID,
            label: label,
            state: .running,
            output: "",
            startedAt: Date(),
            finishedAt: nil
        )

        let backend = backend
        Task { [weak self] in
            let isCurrent: @MainActor () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.contextGeneration == generation
                    && self.panelTargetIdentity == expectedPanelTarget
                    && self.runningOperationID == operationID
                    && (isCurrentTarget?() ?? true)
            }
            let prepared = await prepare?() ?? true
            let batch = await Task.detached(priority: .userInitiated) {
                var transcript: [String] = []
                var failureCode: Int32?
                var failureMessage: String?
                var failedCommand: [String]?
                var gitError: String?
                let staleMessage = String(localized: "The Git action target changed or edits could not be saved. No further Git commands were run.", table: "Git")
                guard prepared, await isCurrent() else {
                    return CommandBatchResult(output: staleMessage, failureCode: -1, failureMessage: staleMessage)
                }

                if let expectedRepositoryRoot {
                    guard await Self.resolveRepositoryRoot(
                        in: validationRoot, backend: backend
                    ) == expectedRepositoryRoot else {
                        let message = String(localized: "Repository changed before the Git action could run. Review the current changes and try again.", table: "Git")
                        return CommandBatchResult(
                            output: message, failureCode: -1, failureMessage: message
                        )
                    }
                    if requiresStableHead {
                        let liveStatus = await GitCommandExecution.run(
                            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                            in: expectedRepositoryRoot,
                            backend: backend
                        )
                        let live = liveStatus.status == 0
                            ? Self.parseStatus(liveStatus.stdout)
                            : nil
                        guard let live,
                              live.headOID == expectedHeadOID,
                              live.branch == expectedBranch,
                              !requiresStableUpstream || live.upstream == expectedUpstream else {
                            let message = requiresStableUpstream
                                ? String(localized: "Branch, HEAD, or upstream changed before the Git action could run. Review the current changes and try again.", table: "Git")
                                : String(localized: "Branch or HEAD changed before the Git action could run. Review the current changes and try again.", table: "Git")
                            return CommandBatchResult(
                                output: message, failureCode: -1, failureMessage: message
                            )
                        }
                    }
                }

                if let expectedRef {
                    let actual = await GitCommandExecution.run(
                        ["show-ref", "--verify", "--hash", expectedRef.name], in: dir, backend: backend
                    )
                    guard actual.status == 0,
                          actual.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expectedRef.oid else {
                        let message = String(localized: "The selected Git reference changed. Reopen the menu and try again.", table: "Git")
                        return CommandBatchResult(output: message, failureCode: -1, failureMessage: message)
                    }
                }
                if let expectedFileState {
                    guard await isCurrent(),
                          await Self.readHistoricalFileState(
                            path: expectedFileState.path, root: dir, backend: backend
                          ) == expectedFileState.state else {
                        let message = String(localized:
                            "The selected file changed since the confirmation opened. Review it and try again.", table: "Git")
                        return CommandBatchResult(output: message, failureCode: -1,
                                                  failureMessage: message)
                    }
                }
                for args in preflight {
                    guard await isCurrent() else {
                        return CommandBatchResult(output: staleMessage, failureCode: -1, failureMessage: staleMessage)
                    }
                    let validation = await GitCommandExecution.run(args, in: dir, backend: backend)
                    if validation.status != 0 {
                        let message = [validation.stderr, validation.stdout].filter { !$0.isEmpty }.joined(separator: "\n")
                        return CommandBatchResult(output: message, failureCode: validation.status,
                                                  failureMessage: message, failedCommand: args, gitError: validation.stderr)
                    }
                }
                if let dropCommit {
                    let topology = await GitCommandExecution.run(["rev-list", "--parents", "--all", "HEAD"], in: dir, backend: backend)
                    guard topology.status == 0,
                          let parents = Self.parseCommitTopology(topology.stdout),
                          Self.dropCommitPossible(dropCommit, head: expectedHeadOID, parents: parents) else {
                        let message = topology.status == 0
                            ? String(localized: "This commit cannot be dropped from the current HEAD without crossing a merge or fork.", table: "Git")
                            : topology.stderr
                        return CommandBatchResult(output: message, failureCode: topology.status == 0 ? -1 : topology.status,
                                                  failureMessage: message)
                    }
                }
                for (index, args) in commands.enumerated() {
                    guard await isCurrent() else {
                        return CommandBatchResult(output: transcript.joined(separator: "\n") + "\n" + staleMessage,
                                                  failureCode: -1, failureMessage: staleMessage)
                    }
                    transcript.append("$ git " + Self.displayCommand(args))
                    let run = await GitCommandExecution.run(args, in: dir, backend: backend)
                    let text = [run.stdout, run.stderr]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    if !text.isEmpty { transcript.append(text) }
                    if run.status != 0 {
                        let fallback = String(localized: "Git command failed", table: "Git")
                        if failureCode == nil {
                            failureCode = run.status
                            failureMessage = text.isEmpty ? fallback : text
                            failedCommand = args
                            gitError = run.stderr
                        }
                        if !continueAfterFirstSuccess || index == 0 {
                            let remaining = commands.dropFirst(index + 1)
                            if !remaining.isEmpty {
                                transcript.append(String(localized: "Not attempted after failure:", table: "Git")
                                    + "\n" + remaining.map { "$ git " + Self.displayCommand($0) }.joined(separator: "\n"))
                            }
                            break
                        }
                    }
                }
                if failureCode == nil, let squashMessage {
                    guard await isCurrent() else {
                        return CommandBatchResult(output: transcript.joined(separator: "\n") + "\n" + staleMessage,
                                                  failureCode: -1, failureMessage: staleMessage)
                    }
                    let staged = await GitCommandExecution.run(["diff", "--cached", "--quiet"], in: dir, backend: backend)
                    if staged.status == 1 {
                        guard await isCurrent() else {
                            return CommandBatchResult(output: transcript.joined(separator: "\n") + "\n" + staleMessage,
                                                      failureCode: -1, failureMessage: staleMessage)
                        }
                        let args = ["commit", "-m", squashMessage]
                        transcript.append("$ git " + Self.displayCommand(args))
                        let commit = await GitCommandExecution.run(args, in: dir, backend: backend)
                        let text = [commit.stdout, commit.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                        transcript.append(text)
                        if commit.status != 0 {
                            failureCode = commit.status
                            failureMessage = text
                            failedCommand = args
                            gitError = commit.stderr
                        }
                    } else if staged.status != 0 {
                        failureCode = staged.status
                        failureMessage = staged.stderr
                        failedCommand = ["diff", "--cached", "--quiet"]
                        gitError = staged.stderr
                        transcript.append(staged.stderr)
                    }
                }
                return CommandBatchResult(
                    output: transcript.joined(separator: "\n"),
                    failureCode: failureCode,
                    failureMessage: failureMessage,
                    failedCommand: failedCommand, gitError: gitError
                )
            }.value

            guard let self, self.runningOperationID == operationID else { return }
            self.runningOperationID = nil
            self.isBusy = false
            guard self.contextGeneration == generation,
                  self.panelTargetIdentity == expectedPanelTarget,
                  self.operation?.id == operationID else {
                // The command may have completed in the old repository, but
                // success-only follow-ups (for example moving a renamed file
                // to Trash) must never continue in the newly selected context.
                completion?(false)
                if self.operation?.id == operationID { self.operation = nil }
                self.refresh()
                return
            }
            let finishedAt = Date()
            if let failureCode = batch.failureCode {
                self.lastError = batch.failureMessage
                self.operation = Operation(
                    id: operationID,
                    label: label,
                    state: .failed(exitCode: failureCode),
                    output: batch.output,
                    failedCommand: batch.failedCommand, gitError: batch.gitError,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
                completion?(false)
            } else {
                if let terminalAction {
                    guard isCurrentTarget?() ?? true else {
                        self.failImmediately(String(localized: "The Git action target changed. Reopen the menu and try again.", table: "Git"), completion: completion)
                        self.refresh()
                        return
                    }
                    do {
                        try terminalAction()
                    } catch {
                        self.failImmediately(error.localizedDescription, completion: completion)
                        self.refresh()
                        return
                    }
                }
                self.lastError = nil
                self.operation = Operation(
                    id: operationID,
                    label: label,
                    state: .succeeded,
                    output: batch.output.isEmpty
                        ? String(localized: "Completed successfully.", table: "Git")
                        : batch.output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
                completion?(true)
            }
            self.refresh()
        }
    }

    private func failImmediately(
        _ message: String,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !isBusy else {
            completion?(false)
            return
        }
        lastError = message
        operation = Operation(
            id: UUID(),
            label: String(localized: "Git action", table: "Git"),
            state: .failed(exitCode: -1),
            output: message,
            startedAt: Date(),
            finishedAt: Date()
        )
        completion?(false)
    }

    private func trash(paths: [String], label: String, completedBefore: String? = nil) {
        guard !paths.isEmpty, !isBusy else { return }
        let base = URL(fileURLWithPath: repoRoot, isDirectory: true)
        let expectedRepositoryRoot = repoRoot
        let expectedHeadOID = headOID
        let expectedBranch = branch
        let validationRoot = rootPath
        let generation = contextGeneration
        let operationID = UUID()
        invalidateStatusRefresh()
        runningOperationID = operationID
        isBusy = true
        lastError = nil
        operation = Operation(
            id: operationID, label: label, state: .running, output: "",
            startedAt: Date(), finishedAt: nil
        )

        let backend = backend
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                guard await Self.resolveRepositoryRoot(
                    in: validationRoot, backend: backend
                ) == expectedRepositoryRoot else {
                    return TrashResult(
                        moved: [],
                        failure: String(localized: "Repository changed before the file action could run. Review the current changes and try again.", table: "Git")
                    )
                }
                let liveStatus = await GitCommandExecution.run(
                    ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                    in: expectedRepositoryRoot,
                    backend: backend
                )
                let live = liveStatus.status == 0 ? Self.parseStatus(liveStatus.stdout) : nil
                guard let live,
                      live.headOID == expectedHeadOID,
                      live.branch == expectedBranch else {
                    return TrashResult(
                        moved: [],
                        failure: String(localized: "Branch or HEAD changed before the file action could run. Review the current changes and try again.", table: "Git")
                    )
                }
                var moved: [String] = []
                var failure: String?
                for path in paths {
                    do {
                        // One path per call: the local backend moves it to the
                        // Trash exactly as before, and stopping at the first
                        // failure still reports which files were moved.
                        try await backend.delete(
                            paths: [base.appendingPathComponent(path).path]
                        )
                        moved.append(path)
                    } catch {
                        failure = error.localizedDescription
                        break
                    }
                }
                return TrashResult(moved: moved, failure: failure)
            }.value

            guard let self, self.runningOperationID == operationID else { return }
            self.runningOperationID = nil
            self.isBusy = false
            guard self.contextGeneration == generation,
                  self.operation?.id == operationID else {
                self.refresh()
                return
            }
            let finishedAt = Date()
            if let failure = result.failure {
                let completedResult = completedBefore.map { $0 + "\n" } ?? ""
                let partialResult = result.moved.isEmpty
                    ? ""
                    : "\n\n" + String(localized: "Moved to Trash before the failure:", table: "Git") + "\n"
                        + result.moved.joined(separator: "\n")
                let output = completedResult + failure + partialResult
                self.lastError = result.moved.isEmpty
                    ? completedResult + failure
                    : completedResult + String(
                        localized: "\(failure) (\(result.moved.count) items were already moved to Trash.)", table: "Git"
                    )
                self.operation = Operation(
                    id: operationID, label: label, state: .failed(exitCode: -1),
                    output: output, startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
            } else {
                let output = [
                    completedBefore,
                    String(localized: "Moved to Trash:", table: "Git") + "\n"
                        + result.moved.joined(separator: "\n"),
                ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                self.operation = Operation(
                    id: operationID, label: label, state: .succeeded,
                    output: output,
                    startedAt: self.operation?.startedAt ?? finishedAt,
                    finishedAt: finishedAt
                )
            }
            self.refresh()
        }
    }

    private nonisolated struct CommandBatchResult: Sendable {
        let output: String
        let failureCode: Int32?
        let failureMessage: String?
        var failedCommand: [String]? = nil
        var gitError: String? = nil
    }

    private nonisolated struct TrashResult: Sendable {
        let moved: [String]
        let failure: String?
    }

    private func invalidateStatusRefresh() {
        statusRequestID &+= 1
        isRefreshing = false
        isLoadingMoreCommits = false
        refreshPending = false
    }

    private nonisolated static func displayCommand(_ args: [String]) -> String {
        let safeCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_@%+=:,./-")
        )
        return args.map { arg in
            guard arg.isEmpty || arg.unicodeScalars.contains(where: { !safeCharacters.contains($0) }) else {
                return arg
            }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    // MARK: - Status

    private func clearRepositoryState(
        preserveIdentity: Bool = false,
        preserveFailedOperation: Bool = false
    ) {
        let failedOperation = preserveFailedOperation ? operation : nil
        let failedError = preserveFailedOperation ? lastError : nil
        topLevel = ""
        isRepo = false
        branch = nil
        headOID = nil
        hasHead = true
        upstream = nil
        ahead = 0
        behind = 0
        hasUpstream = false
        lineAdditions = 0
        lineDeletions = 0
        mergeEntries = []
        stagedEntries = []
        changedEntries = []
        fileDecorations = [:]
        ignoredPaths = []
        branches = []
        refsByName = [:]
        defaultBranch = nil
        remotes = []
        recentCommits = []
        historicalBinaryPaths = [:]
        pendingBinaryCommits.removeAll()
        hasMoreRecentCommits = false
        isLoadingMoreCommits = false
        repositoryOperation = nil
        stashCount = 0
        isRefreshing = false
        isBusy = runningOperationID != nil
        operation = failedOperation
        lastError = failedError
        statusError = nil
        statusRequestID &+= 1
        if !preserveIdentity { repositoryIdentity = "" }
    }

    private func apply(_ loadResult: StatusLoadResult) {
        switch loadResult {
        case .notRepository:
            // A refresh can finish after a user action starts. Do not let a
            // transient status failure erase the active operation/result.
            if isBusy { return }
            let preserveFailure: Bool
            if let operation, case .failed = operation.state {
                preserveFailure = true
            } else {
                preserveFailure = false
            }
            clearRepositoryState(preserveFailedOperation: preserveFailure)
            return
        case .failed(let message):
            if isBusy { return }
            // A failed refresh is not evidence that the repository disappeared.
            // Keep its last successful snapshot until a refresh succeeds or the
            // selected workspace is proven to be a different/non-Git root.
            statusError = message
            return
        case .repository(let result):
            statusError = nil
            applyRepository(result)
        }
    }

    private func applyRepository(_ result: StatusResult) {
        isRepo = true
        branch = result.branch
        headOID = result.headOID
        hasHead = result.hasHead
        upstream = result.upstream
        ahead = result.ahead
        behind = result.behind
        hasUpstream = result.upstream != nil
        lineAdditions = result.lineAdditions
        lineDeletions = result.lineDeletions
        topLevel = result.topLevel
        repositoryIdentity = result.topLevel
        branches = result.branches
        refsByName = result.refsByName
        defaultBranch = result.defaultBranch
        remotes = result.remotes
        recentCommits = result.recentCommits
        hasMoreRecentCommits = result.hasMoreRecentCommits
        repositoryOperation = result.repositoryOperation
        stashCount = result.stashCount

        let entries = result.entries.map { entry in
            var entry = entry
            entry.repositoryRoot = result.topLevel
            return entry
        }
        // parseStatus already guarantees entries are unique per path, but a
        // stray duplicate must degrade to a deterministic decoration instead of
        // trapping the whole app on duplicate keys.
        fileDecorations = Dictionary(
            entries.map {
                ($0.path, FileDecoration(staged: $0.staged, unstaged: $0.unstaged, isConflict: $0.isConflict))
            },
            uniquingKeysWith: { first, _ in first }
        )
        ignoredPaths = result.ignoredPaths
        mergeEntries = entries.filter(\.isConflict)
        stagedEntries = entries.filter {
            !$0.isConflict && $0.staged != "." && $0.staged != "?"
        }
        changedEntries = entries.filter {
            !$0.isConflict && $0.unstaged != "."
        }
    }

    nonisolated enum StatusLoadResult: Equatable, Sendable {
        case repository(StatusResult)
        case notRepository
        case failed(String)
    }

    nonisolated struct StatusResult: Equatable, Sendable {
        var branch: String?
        var headOID: String?
        var hasHead = true
        var upstream: String?
        var ahead = 0
        var behind = 0
        var lineAdditions = 0
        var lineDeletions = 0
        var topLevel = ""
        var entries: [Entry] = []
        var ignoredPaths: Set<String> = []
        var branches: [String] = []
        var refsByName: [String: GitRef] = [:]
        var defaultBranch: String?
        var remotes: [String] = []
        var recentCommits: [RecentCommit] = []
        var hasMoreRecentCommits = false
        var repositoryOperation: String?
        var stashCount = 0
    }

    /// Resolves the active repository and distinguishes a normal non-repo
    /// directory from an actual Git failure that the UI should surface.
    private nonisolated static func runGitStatus(
        in root: String,
        recentCommitLimit: Int,
        backend: WorkspaceBackend
    ) async -> StatusLoadResult {
        // A filesystem, Git helper, or corrupt repository must not leave the
        // initial sidebar spinner running forever. Share one deadline across
        // the full snapshot instead of allowing every detail command its own
        // timeout.
        // A first SSH connection on Windows can spend several seconds in
        // authentication before the already-batched Git commands begin.
        let deadline = Date().addingTimeInterval(
            backend is LocalWorkspaceBackend ? 10 : 24
        )
        let timeoutMessage = String(localized: "Git did not respond in time.", table: "Git")
        // On a remote workspace the commands that do not depend on each
        // other's output are fetched together first, because a round trip
        // costs far more than the command does. `statusGit` then answers
        // from that batch, so the snapshot below reads exactly as it does
        // locally and parses exactly the same text.
        let prefetched = await prefetchedSnapshotCommands(
            in: root, recentCommitLimit: recentCommitLimit, backend: backend,
            deadline: deadline
        )
        func statusGit(
            _ args: [String], in directory: String
        ) async -> (status: Int32, stdout: String, stderr: String) {
            if let batched = prefetched[args.joined(separator: " ")] {
                return batched
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return (-2, "", timeoutMessage) }
            return await GitCommandExecution.run(args, in: directory, timeout: remaining, backend: backend)
        }

        let top = await statusGit(["rev-parse", "--show-toplevel"], in: root)
        guard top.status == 0 else {
            let failure = gitFailureMessage(
                top,
                fallback: String(localized: "Unable to locate the Git repository.", table: "Git")
            )
            if top.status == 128,
               failure.localizedCaseInsensitiveContains("not a git repository"),
               !(await containsGitMetadata(atOrAbove: root, backend: backend)) {
                return .notRepository
            }
            return .failed(failure)
        }
        let resolvedRoot = strippingTrailingLineEnding(top.stdout)
        guard !resolvedRoot.isEmpty else {
            return .failed(String(localized: "Git returned an empty repository path.", table: "Git"))
        }
        let status = await statusGit(
            [
                "status", "--porcelain=v2", "--branch", "-z",
                "--untracked-files=all", "--ignored=matching",
            ],
            in: resolvedRoot
        )
        guard status.status == 0 else {
            return .failed(
                gitFailureMessage(
                    status,
                    fallback: String(localized: "Unable to read Git status.", table: "Git")
                )
            )
        }
        var result = parseStatus(status.stdout)
        result.topLevel = resolvedRoot

        let diff = await statusGit(
            result.hasHead
                ? ["diff", "--numstat", "HEAD", "--"]
                : ["diff", "--numstat", "--cached", "--"],
            in: resolvedRoot
        )
        if diff.status == 0 {
            let totals = parseNumstat(diff.stdout)
            result.lineAdditions = totals.additions
            result.lineDeletions = totals.deletions
        }
        // An unborn branch has no HEAD to compare against. Its cached diff is
        // the initial snapshot; add any edits made after staging as a second
        // layer so the toolbar still reflects all pending work.
        if !result.hasHead {
            let unstaged = await statusGit(["diff", "--numstat", "--"], in: resolvedRoot)
            if unstaged.status == 0 {
                let totals = parseNumstat(unstaged.stdout)
                result.lineAdditions += totals.additions
                result.lineDeletions += totals.deletions
            }
        }
        // `git diff` intentionally omits untracked files. Count their text
        // lines as additions so the compact toolbar totals cover all pending
        // work reported by the porcelain snapshot.
        result.lineAdditions += await untrackedLineAdditions(
            for: result.entries,
            in: resolvedRoot,
            backend: backend
        )

        let repoRoot = resolvedRoot

        let refs = await statusGit(Self.refSnapshotArguments, in: repoRoot)
        if refs.status == 0 {
            result.refsByName = parseRefSnapshot(refs.stdout)
            result.branches = result.refsByName.keys.compactMap { name in
                name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : nil
            }.sorted()
        }

        let remoteRun = await statusGit(["remote"], in: repoRoot)
        if remoteRun.status == 0 {
            result.remotes = remoteRun.stdout.split(separator: "\n").map(String.init).sorted()
        }

        // A clone records its remote's default branch as a symbolic HEAD.
        // Prefer origin when more than one remote is present because that is
        // the repository the local branch list conventionally belongs to.
        if let remote = result.remotes.contains("origin") ? "origin" : result.remotes.first {
            let remoteHead = await statusGit(
                ["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"],
                in: repoRoot
            )
            let prefix = "\(remote)/"
            let ref = strippingTrailingLineEnding(remoteHead.stdout)
            if remoteHead.status == 0, ref.hasPrefix(prefix) {
                let branch = String(ref.dropFirst(prefix.count))
                if result.branches.contains(branch) {
                    result.defaultBranch = branch
                }
            }
        }

        // NUL-delimited name-status records preserve every valid path while
        // supplying the nested file rows used by the native commit graph.
        let log = await statusGit(recentCommitLogArguments(limit: recentCommitLimit), in: repoRoot)
        if log.status == 0 {
            let commits = parseRecentCommits(log.stdout, refsByName: result.refsByName)
            result.hasMoreRecentCommits = commits.count > recentCommitLimit
            result.recentCommits = Array(commits.prefix(recentCommitLimit))
        } else if result.hasHead {
            // A failed history query is not an empty history. Publishing a
            // partial success here would erase the already loaded Git Graph.
            return .failed(gitFailureMessage(
                log, fallback: String(localized: "Unable to read Git status.", table: "Git")
            ))
        }

        let stash = await statusGit(
            ["rev-list", "--walk-reflogs", "--count", "refs/stash"], in: repoRoot
        )
        if stash.status == 0 {
            result.stashCount = Int(stash.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        let gitDir = await statusGit(["rev-parse", "--absolute-git-dir"], in: repoRoot)
        if gitDir.status == 0 {
            let path = strippingTrailingLineEnding(gitDir.stdout)
            result.repositoryOperation = await detectRepositoryOperation(
                gitDirectory: path, backend: backend
            )
        }
        return .repository(result)
    }

    /// The snapshot commands that need nothing from each other, fetched in one
    /// round trip. Empty for a local workspace, where a command costs almost
    /// nothing and the existing path is left exactly as it was.
    ///
    /// Each command merges its standard error into its output, because the
    /// failure text is the message the panel shows and `gitFailureMessage`
    /// already prefers whichever stream carries it.
    private nonisolated static func prefetchedSnapshotCommands(
        in root: String, recentCommitLimit: Int, backend: WorkspaceBackend,
        deadline: Date
    ) async -> [String: (status: Int32, stdout: String, stderr: String)] {
        guard !(backend is LocalWorkspaceBackend) else { return [:] }
        let argumentSets: [[String]] = [
            ["rev-parse", "--show-toplevel"],
            [
                "status", "--porcelain=v2", "--branch", "-z",
                "--untracked-files=all", "--ignored=matching",
            ],
            refSnapshotArguments,
            ["remote"],
            recentCommitLogArguments(limit: recentCommitLimit),
            ["rev-list", "--walk-reflogs", "--count", "refs/stash"],
            ["rev-parse", "--absolute-git-dir"],
        ]
        let tag = UUID().uuidString
        let commands = argumentSets.map { args in
            (
                name: args.joined(separator: " "),
                command: "env GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 LC_ALL=C git "
                    + args.map(RemoteCommands.quote).joined(separator: " ") + " 2>&1"
            )
        }
        // Every batched command runs at the repository top level, which is
        // where the snapshot runs them one by one. A directory that is not a
        // repository answers with the first command alone, so leaving a
        // repository does not pay for six commands that are all going to fail.
        let toplevel = RemoteCommands.batchCommand([commands[0]], tag: tag)
        let script = "cd \(RemoteCommands.quote(root)) || exit 1; "
            + "t=$(git rev-parse --show-toplevel 2>/dev/null); "
            + "if [ -z \"$t\" ]; then \(toplevel); else cd \"$t\" || exit 1; "
            + RemoteCommands.batchCommand(commands, tag: tag) + "; fi"

        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0,
            let result = try? await backend.run(
                argv: ["sh", "-s"], cwd: nil, env: nil,
                stdin: Data(script.utf8), timeout: remaining
            )
        else { return [:] }

        var answers: [String: (status: Int32, stdout: String, stderr: String)] = [:]
        for (name, batched) in RemoteCommands.parseBatch(result.stdout, tag: tag) {
            answers[name] = (
                batched.status, String(decoding: batched.stdout, as: UTF8.self), ""
            )
        }
        return answers
    }

    private nonisolated static func resolveRepositoryRoot(
        in root: String, backend: WorkspaceBackend
    ) async -> String? {
        let top = await GitCommandExecution.run(["rev-parse", "--show-toplevel"], in: root, backend: backend)
        guard top.status == 0 else { return nil }
        let path = strippingTrailingLineEnding(top.stdout)
        return path.isEmpty ? nil : path
    }

    /// A malformed `.git` directory/file can produce the same rev-parse text
    /// as a plain folder. Preserve that as an actionable status error instead
    /// of offering to initialize a nested repository on top of broken metadata.
    private nonisolated static func containsGitMetadata(
        atOrAbove root: String, backend: WorkspaceBackend
    ) async -> Bool {
        if !(backend is LocalWorkspaceBackend) {
            // The ancestor walk is one round trip per level otherwise, and it
            // runs every time the panel leaves a repository.
            guard let result = try? await backend.run(
                argv: [
                    "sh", "-c",
                    RemoteCommands.gitMetadataAtOrAboveCommand(path: root),
                ],
                cwd: nil, env: nil, stdin: nil, timeout: nil
            ) else { return false }
            return String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
        }
        // Walk path strings, not URLs: `URL.deletingLastPathComponent()` keeps
        // appending ".." at the filesystem root, so a URL ascent never
        // reaches its fixed point and spins forever. The NSString walk
        // terminates at "/".
        var directory = URL(fileURLWithPath: root, isDirectory: true)
            .standardizedFileURL.path as NSString
        while true {
            let marker = directory.appendingPathComponent(".git")
            if (try? await backend.stat(path: marker)) != nil {
                return true
            }
            let parent = directory.deletingLastPathComponent as NSString
            if parent.isEqual(to: directory as String) { return false }
            directory = parent
        }
    }

    /// One round trip instead of one per marker.
    private nonisolated static func remoteRepositoryOperation(
        gitDirectory: String, backend: WorkspaceBackend
    ) async -> String? {
        guard let result = try? await backend.run(
            argv: ["sh", "-c", RemoteCommands.repositoryOperationCommand(gitDirectory: gitDirectory)],
            cwd: nil, env: nil, stdin: nil, timeout: nil
        ), result.status == 0 else { return nil }
        let marker = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch marker {
        case "rebase-merge", "rebase-apply": return String(localized: "Rebase in progress", table: "Git")
        case "MERGE_HEAD": return String(localized: "Merge in progress", table: "Git")
        case "CHERRY_PICK_HEAD": return String(localized: "Cherry-pick in progress", table: "Git")
        case "REVERT_HEAD": return String(localized: "Revert in progress", table: "Git")
        case "BISECT_LOG": return String(localized: "Bisect in progress", table: "Git")
        default: return nil
        }
    }

    private nonisolated static func strippingTrailingLineEnding(_ value: String) -> String {
        var value = value
        if value.hasSuffix("\n") { value.removeLast() }
        if value.hasSuffix("\r") { value.removeLast() }
        return value
    }

    private nonisolated static func gitFailureMessage(
        _ run: (status: Int32, stdout: String, stderr: String), fallback: String
    ) -> String {
        let message = [run.stderr, run.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return message ?? fallback
    }

    /// Parses NUL-delimited porcelain v2. Unlike Git's default quoted output,
    /// this preserves spaces, quotes, tabs, and newlines in file names.
    nonisolated static func parseStatus(_ output: String) -> StatusResult {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result = StatusResult()
        var index = 0
        // Porcelain v2 can report the same path twice: when a file was removed
        // from the index (`git rm --cached`, `git update-index --force-remove`)
        // but still exists in the worktree, git lists it as a staged deletion
        // ("1 D.") and again as untracked ("? "). Git's own v1 short format
        // shows only the deletion, and every consumer keys rows by path
        // (Entry.id == path), so the first record for a path wins.
        var parsedPaths: Set<String> = []
        func addEntry(_ entry: Entry) {
            guard parsedPaths.insert(entry.path).inserted else { return }
            result.entries.append(entry)
        }
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("# branch.oid ") {
                let oid = String(record.dropFirst("# branch.oid ".count))
                result.hasHead = oid != "(initial)"
                result.headOID = result.hasHead ? oid : nil
            } else if record.hasPrefix("# branch.head ") {
                let name = String(record.dropFirst("# branch.head ".count))
                result.branch = name == "(detached)" ? "detached HEAD" : name
            } else if record.hasPrefix("# branch.upstream ") {
                result.upstream = String(record.dropFirst("# branch.upstream ".count))
            } else if record.hasPrefix("# branch.ab ") {
                let parts = record.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") { result.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { result.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if record.hasPrefix("1 ") {
                let fields = record.split(separator: " ", maxSplits: 8)
                if fields.count == 9, fields[1].count == 2 {
                    let xy = Array(fields[1])
                    addEntry(
                        Entry(path: String(fields[8]), staged: xy[0], unstaged: xy[1])
                    )
                }
            } else if record.hasPrefix("2 ") {
                let fields = record.split(separator: " ", maxSplits: 9)
                if fields.count == 10, fields[1].count == 2, index + 1 < records.count {
                    let xy = Array(fields[1])
                    // With -z, the destination is in this record and the
                    // original path is the following NUL-delimited token.
                    addEntry(
                        Entry(
                            path: String(fields[9]), staged: xy[0], unstaged: xy[1],
                            origPath: records[index + 1]
                        )
                    )
                    index += 1
                }
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10)
                if fields.count == 11, fields[1].count == 2 {
                    let xy = Array(fields[1])
                    addEntry(
                        Entry(
                            path: String(fields[10]), staged: xy[0], unstaged: xy[1],
                            isConflict: true
                        )
                    )
                }
            } else if record.hasPrefix("? ") {
                addEntry(
                    Entry(path: String(record.dropFirst(2)), staged: "?", unstaged: "?")
                )
            } else if record.hasPrefix("! ") {
                result.ignoredPaths.insert(String(record.dropFirst(2)))
            }
            index += 1
        }
        return result
    }

    /// Adds the numeric columns from `git diff --numstat`. Binary-file rows
    /// use `-` instead of a count and therefore contribute zero lines.
    nonisolated static func parseNumstat(_ output: String) -> (additions: Int, deletions: Int) {
        output.split(separator: "\n").reduce(into: (additions: 0, deletions: 0)) { total, row in
            let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return }
            total.additions += Int(fields[0]) ?? 0
            total.deletions += Int(fields[1]) ?? 0
        }
    }

    /// Git's numstat output has no representation for untracked files. Mirror
    /// its new-text-file behavior without spawning one Git process per path.
    private nonisolated static func untrackedLineAdditions(
        for entries: [Entry], in root: String, backend: WorkspaceBackend
    ) async -> Int {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"

        // Line totals are secondary metadata. Keep generated or accidentally
        // enormous untracked trees from delaying the repository itself.
        let maximumFiles = 2_048
        let maximumFileBytes = 8 * 1_024 * 1_024
        var remainingBytes = 32 * 1_024 * 1_024
        var visitedFiles = 0
        var total = 0

        // Remotely these are one round trip for the whole set rather than two
        // per file, which is the difference between a snapshot inside its
        // deadline and one over it on a repository with untracked files.
        if !(backend is LocalWorkspaceBackend) {
            var paths: [String] = []
            for entry in entries where entry.staged == "?" {
                guard paths.count < maximumFiles else { break }
                let fileURL = rootURL.appendingPathComponent(entry.path).standardizedFileURL
                guard fileURL.path.hasPrefix(rootPrefix) else { continue }
                paths.append(fileURL.path)
            }
            guard !paths.isEmpty else { return 0 }
            let result = try? await backend.run(
                argv: [
                    "sh", "-c",
                    RemoteCommands.untrackedLineCountsCommand(
                        totalByteBudget: remainingBytes,
                        perFileByteCap: maximumFileBytes
                    ),
                ],
                cwd: root,
                env: nil,
                stdin: RemoteCommands.untrackedLineCountsInput(paths: paths),
                timeout: nil
            )
            guard let result, result.status == 0 else { return 0 }
            let counts = RemoteCommands.parseUntrackedLineCounts(
                String(data: result.stdout, encoding: .utf8) ?? ""
            )
            return counts.reduce(0) { $0 + $1.lines }
        }
        for entry in entries where entry.staged == "?" {
            guard visitedFiles < maximumFiles, remainingBytes > 0 else { break }
            visitedFiles += 1
            let fileURL = rootURL.appendingPathComponent(entry.path).standardizedFileURL
            guard fileURL.path.hasPrefix(rootPrefix) else { continue }
            let count = textLineCount(
                at: fileURL,
                maximumBytes: min(maximumFileBytes, remainingBytes)
            )
            total += count.lines
            remainingBytes -= count.bytesRead
        }
        return total
    }

    /// Counts logical lines while using Git's usual NUL-byte binary heuristic.
    /// Symlink content is its destination path, which is one added line.
    private nonisolated static func textLineCount(
        at url: URL,
        maximumBytes: Int
    ) -> (lines: Int, bytesRead: Int) {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else { return (0, 0) }
        if values.isSymbolicLink == true { return (1, 0) }
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= maximumBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return (0, 0) }
        defer { try? handle.close() }

        let binaryProbeSize = 8_000
        guard let probe = try? handle.read(upToCount: binaryProbeSize) else {
            return (0, 0)
        }
        guard !probe.contains(0) else { return (0, probe.count) }

        var byteCount = probe.count
        var newlineCount = probe.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        var lastByte = probe.last

        while let chunk = try? handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            byteCount += chunk.count
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            lastByte = chunk.last
        }

        guard byteCount > 0 else { return (0, 0) }
        return (newlineCount + (lastByte == 0x0A ? 0 : 1), byteCount)
    }

    private nonisolated static let refSnapshotArguments = [
        "for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)%00%(objecttype)",
        "refs/heads", "refs/remotes", "refs/tags",
    ]

    nonisolated static func parseRefSnapshot(_ output: String) -> [String: GitRef] {
        var refs: [String: GitRef] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 4, fields[0].hasPrefix("refs/"), !fields[1].isEmpty else { continue }
            let name = String(fields[0])
            refs[name] = GitRef(
                oid: String(fields[1]),
                symbolic: fields[2].isEmpty ? nil : String(fields[2]),
                objectType: String(fields[3])
            )
        }
        return refs
    }

    private nonisolated static func recentCommitLogArguments(limit: Int) -> [String] {
        [
            "log", "-n", "\(limit + 1)", "--branches", "--remotes", "--tags", "HEAD",
            "--topo-order", "--diff-merges=first-parent", "--decorate=full",
            "--pretty=format:%x1e%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1f%P%x1f%(decorate:prefix=,suffix=,separator=%x1d)",
            "--name-status", "-z",
        ]
    }

    private nonisolated static func parseCommitReferences(
        _ decorations: String
    ) -> [RecentCommit.Reference] {
        typealias Reference = RecentCommit.Reference
        // Git refs can contain commas, but never ASCII control separators.
        return decorations.split(separator: "\u{1d}").compactMap { item in
            let value = item.trimmingCharacters(in: .whitespaces)
            func named(_ prefix: String, as kind: Reference.Kind) -> Reference? {
                guard value.hasPrefix(prefix) else { return nil }
                let name = String(value.dropFirst(prefix.count))
                return name.isEmpty ? nil : Reference(kind: kind, name: name)
            }
            if value == "HEAD" { return Reference(kind: .detachedHead, name: "HEAD") }
            if let current = named("HEAD -> refs/heads/", as: .currentBranch) {
                return current
            }
            if let branch = named("refs/heads/", as: .localBranch) {
                return branch
            }
            if let remote = named("refs/remotes/", as: .remoteBranch) {
                let name = String(remote.name.components(separatedBy: " -> ").first ?? "")
                return name.isEmpty ? nil : Reference(kind: .remoteBranch, name: name)
            }
            return named("tag: refs/tags/", as: .tag)
        }
    }

    nonisolated static func parseRecentCommits(
        _ output: String, refsByName: [String: GitRef] = [:]
    ) -> [RecentCommit] {
        output.split(separator: "\u{1e}").compactMap { record in
            var chunks = record.split(separator: "\u{0}", omittingEmptySubsequences: false)
                .map(String.init)
            guard !chunks.isEmpty else { return nil }

            // With --name-status -z, the first status follows the pretty
            // header after a newline; subsequent statuses are their own NUL
            // fields. Rename/copy records carry both old and new paths.
            let headerAndStatus = chunks.removeFirst()
            let boundary = headerAndStatus.lastIndex(of: "\n")
            let header = boundary.map { String(headerAndStatus[..<$0]) } ?? headerAndStatus
            var statusToken = boundary.map {
                String(headerAndStatus[headerAndStatus.index(after: $0)...])
            } ?? ""
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 7, let timestamp = TimeInterval(fields[4]) else {
                return nil
            }

            var files: [RecentCommit.FileChange] = []
            var index = 0
            while !statusToken.isEmpty, index < chunks.count {
                guard let status = statusToken.first else { break }
                if status == "R" || status == "C" {
                    guard index + 1 < chunks.count else { break }
                    files.append(.init(
                        status: status,
                        path: chunks[index + 1],
                        originalPath: chunks[index]
                    ))
                    index += 2
                } else {
                    files.append(.init(
                        status: status,
                        path: chunks[index],
                        originalPath: nil
                    ))
                    index += 1
                }
                guard index < chunks.count else { break }
                statusToken = chunks[index]
                index += 1
            }

            return RecentCommit(
                hash: String(fields[0]), shortHash: String(fields[1]),
                subject: String(fields[2]), author: String(fields[3]),
                date: Date(timeIntervalSince1970: timestamp),
                parentHashes: fields[5].split(separator: " ").map(String.init),
                references: parseCommitReferences(String(fields[6])).filter { reference in
                    reference.kind != .remoteBranch
                        || refsByName["refs/remotes/" + reference.name]?.symbolic == nil
                },
                files: files
            )
        }
    }

    nonisolated static func detectRepositoryOperation(
        gitDirectory: String, backend: WorkspaceBackend
    ) async -> String? {
        let git = URL(fileURLWithPath: gitDirectory, isDirectory: true)
        if !(backend is LocalWorkspaceBackend) {
            return await remoteRepositoryOperation(gitDirectory: gitDirectory, backend: backend)
        }
        func exists(_ name: String) async -> Bool {
            let path = git.appendingPathComponent(name).path
            return (try? await backend.stat(path: path)) != nil
        }

        let merging = await exists("rebase-merge")
        let applying = await exists("rebase-apply")
        if merging || applying {
            return String(localized: "Rebase in progress", table: "Git")
        }
        if await exists("MERGE_HEAD") {
            return String(localized: "Merge in progress", table: "Git")
        }
        if await exists("CHERRY_PICK_HEAD") {
            return String(localized: "Cherry-pick in progress", table: "Git")
        }
        if await exists("REVERT_HEAD") {
            return String(localized: "Revert in progress", table: "Git")
        }
        if await exists("BISECT_LOG") {
            return String(localized: "Bisect in progress", table: "Git")
        }
        return nil
    }
}
