import AppKit
import Combine
import Dispatch
import Foundation
import Observation
import OSLog

/// Loads repository state in response to explicit UI events and performs
/// source-control operations without blocking the UI.
@MainActor
@Observable
final class GitStatusModel {
    private nonisolated static let statusLogger = Logger(subsystem: "chiimagnus.bailey", category: "GitStatus")

    @ObservationIgnored private var activeObserver: AnyCancellable?
    @ObservationIgnored private var inactiveObserver: AnyCancellable?

    init() {
        activeObserver = NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.setLocalFileEventsForeground(true) }
        }
        inactiveObserver = NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.setLocalFileEventsForeground(false) }
        }
    }

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
        var snapshotGeneration: UInt = 0
        var snapshotBranch: String?
        var snapshotHeadOID: String?

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

        /// The unstaged half of an indexed rename/copy compares the index
        /// destination with the working destination, not the pre-rename path.
        func diffOriginalPath(staged: Bool) -> String? {
            !staged && (self.staged == "R" || self.staged == "C") ? nil : origPath
        }
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

    nonisolated struct Stash: Identifiable, Equatable, Sendable {
        var id: String { selector + "\0" + oid }
        let selector: String
        let oid: String
        let message: String
        let baseHash: String
        let untrackedFilesHash: String?
        let author: String
        let date: Date
    }

    nonisolated enum StashAction: CaseIterable, Sendable {
        case apply, branch, pop, drop

        var title: String {
            switch self {
            case .apply: String(localized: "Apply Stash…", table: "Git")
            case .branch: String(localized: "Create Branch from Stash…", table: "Git")
            case .pop: String(localized: "Pop Stash…", table: "Git")
            case .drop: String(localized: "Drop Stash…", table: "Git")
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
        canUseCurrentStatus && isRepo
            && target.generation == contextGeneration && target.repository == repoRoot
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
            requiredStatus: .history,
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

    /// Working-tree state is not a Git object. Its identity is the checkout
    /// path, never a branch name or a fabricated commit hash.
    nonisolated struct WorktreeChanges: Equatable, Sendable {
        let path: String
        let branch: String?
        let headOID: String?
        let entries: [Entry]
        let isCurrent: Bool
    }

    nonisolated struct RecentCommit: Identifiable, Equatable, Sendable {
        nonisolated struct Reference: Identifiable, Hashable, Sendable {
            enum Kind: String, Sendable {
                case currentBranch, localBranch, remoteBranch, remoteAlias, tag, detachedHead
            }

            let kind: Kind
            let name: String
            var id: String { kind.rawValue + ":" + name }
        }

        nonisolated struct FileChange: Identifiable, Equatable, Sendable {
            let status: Character
            let path: String
            let originalPath: String?
            var fromStashUntracked = false

            var id: String {
                "\(status)\u{0}\(originalPath ?? "")\u{0}\(path)\u{0}\(fromStashUntracked)"
            }
            var fileName: String { (path as NSString).lastPathComponent }
            var directory: String {
                let dir = (path as NSString).deletingLastPathComponent
                return dir.isEmpty ? "" : dir
            }
        }

        var id: String { worktree.map { "worktree:" + $0.path } ?? stash?.id ?? hash }
        let hash: String
        let shortHash: String
        let subject: String
        let author: String
        let date: Date
        let parentHashes: [String]
        let references: [Reference]
        let files: [FileChange]
        var stash: Stash? = nil
        var worktree: WorktreeChanges? = nil
        var checkedOutWorktrees: [WorktreeLocation] = []

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
    @ObservationIgnored private var directoryDecorations: [String: FileDecoration] = [:]
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
    private(set) var stashes: [Stash] = []
    private(set) var currentWorktree: WorktreeChanges?
    private(set) var otherWorktrees: [WorktreeChanges] = []
    private(set) var worktreeLocations: [WorktreeLocation] = []
    private(set) var hasCurrentWorktrees = false

    func canCreateWorktree(for branchName: String) -> Bool {
        hasCurrentWorktrees && canUseCurrentReferences
            && refsByName["refs/heads/" + branchName] != nil
            && !worktreeLocations.contains { $0.branch == branchName }
    }

    nonisolated enum StashFilesState: Equatable, Sendable {
        case loading
        case loaded([RecentCommit.FileChange])
        case failed(String)
    }

    private(set) var stashFilesByOID: [String: StashFilesState] = [:]
    var graphCommits: [RecentCommit] {
        Self.graphCommits(
            recentCommits, stashes: stashes,
            worktrees: ([currentWorktree].compactMap { $0 } + otherWorktrees),
            locations: worktreeLocations
        )
    }

    /// A stash follows its base commit; each dirty checkout follows its own
    /// HEAD, not another checkout's current branch.
    nonisolated static func graphCommits(
        _ commits: [RecentCommit], stashes: [Stash],
        worktrees: [WorktreeChanges] = [], locations: [WorktreeLocation] = []
    ) -> [RecentCommit] {
        let locationsByHead = Dictionary(grouping: locations.compactMap { location -> (String, WorktreeLocation)? in
            location.headOID.map { ($0, location) }
        }, by: { $0.0 })
        let commits = commits.map { commit -> RecentCommit in
            var annotated = commit
            annotated.checkedOutWorktrees = (locationsByHead[commit.hash] ?? []).map(\.1)
            return annotated
        }
        let positions = Dictionary(uniqueKeysWithValues: commits.enumerated().map {
            ($0.element.hash, $0.offset)
        })
        let sorted = stashes.enumerated().map { index, stash in
            (position: positions[stash.baseHash] ?? commits.count, order: index, stash: stash)
        }.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            if $0.stash.date != $1.stash.date { return $0.stash.date > $1.stash.date }
            return $0.order < $1.order
        }
        var graph = commits
        for entry in sorted.reversed() {
            let stash = entry.stash
            graph.insert(RecentCommit(
                hash: stash.oid, shortHash: String(stash.oid.prefix(7)),
                subject: stash.message, author: stash.author, date: stash.date,
                parentHashes: [stash.baseHash], references: [], files: [], stash: stash
            ), at: entry.position)
        }
        for worktree in worktrees.filter({ !$0.entries.isEmpty })
            .sorted(by: { $0.path > $1.path }) {
            let at = worktree.headOID.flatMap { oid in
                graph.firstIndex { $0.hash == oid && $0.stash == nil && $0.worktree == nil }
            } ?? 0
            graph.insert(RecentCommit(
                hash: "worktree:" + worktree.path, shortHash: "",
                subject: String(localized: "Uncommitted Changes", table: "Git"),
                author: "", date: .distantPast,
                parentHashes: worktree.headOID.map { [$0] } ?? [],
                references: [], files: [], worktree: worktree
            ), at: at)
        }
        return graph
    }
    private(set) var isRefreshing = false
    /// True once a status load has completed for the current `rootPath`. The
    /// UI keeps showing resolved content during later event-driven refreshes
    /// instead of flashing a loading placeholder.
    private(set) var hasResolvedStatus = false
    private(set) var statusError: String?
    private(set) var hasCurrentReferences = false
    private(set) var hasCurrentHistory = false
    private(set) var hasCurrentStashes = false
    var canUseCurrentReferences: Bool { canUseCurrentStatus && hasCurrentReferences }
    var canUseCurrentHistory: Bool { canUseCurrentReferences && hasCurrentHistory }
    var canUseCurrentStashes: Bool { canUseCurrentStatus && hasCurrentStashes }
    private(set) var hasCurrentLineTotals = false
    /// A restored cache or a replaced SSH channel is display-only until
    /// the current core status verifies the active repository and HEAD.
    private(set) var needsCoreVerification = false
    var canUseCurrentStatus: Bool {
        hasResolvedPanelTarget && !needsCoreVerification && statusError == nil
    }
    /// Optional history, stash, ignored paths or line-count metadata failed.
    /// The independently verified core status remains usable.
    private var fullDetailError: String?
    private var historyPageError: String?
    var detailError: String? { historyPageError ?? fullDetailError }
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
    @ObservationIgnored private var coreCompletedRequestID: UInt?
    /// Coalesces an event that arrives while another refresh or mutation is
    /// running. Without polling, dropping that event could leave the snapshot
    /// stale indefinitely.
    nonisolated enum RefreshKind: Sendable { case full, indexOnly, historyOnly }
    private var pendingRefresh: RefreshKind?
    @ObservationIgnored private var localWatcher: GitFileEventWatcher?
    @ObservationIgnored private var localWatcherPaths: [String] = []
    @ObservationIgnored private var pendingFileEvent: Task<Void, Never>?
    @ObservationIgnored private var localWatcherForeground = true
    var hasLocalFileEvents: Bool { localWatcher != nil }
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
        canUseCurrentStatus && entry.repositoryRoot == repoRoot
            && entry.snapshotGeneration == contextGeneration
            && entry.snapshotBranch == branch && entry.snapshotHeadOID == headOID
    }

    /// Returns a Git decoration only when `absolutePath` belongs to the
    /// currently resolved repository. Plain folders therefore keep the normal
    /// file-tree appearance, even when their names resemble ignored paths.
    func fileDecoration(for absolutePath: String, isDirectory: Bool) -> FileDecoration? {
        guard isRepo, !topLevel.isEmpty else { return nil }
        let relativePath: String
        let literalPrefix = topLevel + "/"
        if absolutePath == topLevel {
            relativePath = ""
        } else if absolutePath.hasPrefix(literalPrefix),
                  !absolutePath.dropFirst(literalPrefix.count).split(separator: "/")
                    .contains(where: { $0 == "." || $0 == ".." }) {
            // Git paths are lexical; standardizing a deleted leaf can resolve
            // /private/var differently from its existing repository root.
            relativePath = String(absolutePath.dropFirst(literalPrefix.count))
        } else {
            let repositoryPath = (topLevel as NSString).standardizingPath
            let itemPath = (absolutePath as NSString).standardizingPath
            if itemPath == repositoryPath {
                relativePath = ""
            } else {
                let prefix = repositoryPath + "/"
                guard itemPath.hasPrefix(prefix) else { return nil }
                relativePath = String(itemPath.dropFirst(prefix.count))
            }
        }

        if let decoration = fileDecorations[relativePath] {
            return decoration
        }
        if ignoredPaths.contains(relativePath) || ignoredPaths.contains(relativePath + "/") {
            return .ignored
        }
        var parent = relativePath
        while let slash = parent.lastIndex(of: "/") {
            parent = String(parent[..<slash])
            if ignoredPaths.contains(parent + "/") { return .ignored }
        }
        return isDirectory ? directoryDecorations[relativePath] : nil
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
            stashFilesByOID = [:]
            invalidateStatusRefresh()
            panelTargetIdentity = nil
            isResolvingPanelTarget = true
        }
        Task { [weak self, weak manager, weak project] in
            let resolved: (root: String, source: PanelContext.RootSource)
            do {
                resolved = try await context.resolvedRoot()
            } catch {
                guard let self, let manager, let project,
                      self.panelResolveGeneration == generation,
                      manager.selectedProject === project,
                      project.matchesPanelTarget(context.identity) else { return }
                self.apply(.failed(error.localizedDescription))
                self.hasResolvedStatus = true
                return
            }
            guard let self, let manager, let project,
                  self.panelResolveGeneration == generation,
                  manager.selectedProject === project,
                  project.matchesPanelTarget(context.identity) else { return }
            self.sync(root: resolved.root, backend: context.backend, scope: context.scope)
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
        let targetChanged = root != rootPath || workspaceScope != scope || channelChanged
        self.backend = targetBackend
        if targetChanged {
            pendingFileEvent?.cancel()
            localWatcher = nil
            localWatcherPaths = []
        }
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
                hasCurrentReferences = false
                hasCurrentHistory = false
                hasCurrentStashes = false
                hasCurrentWorktrees = false
                hasCurrentLineTotals = false
                needsCoreVerification = true
            }
        } else if channelChanged {
            // A new SSH channel must not queue behind a worker stalled on the
            // previous connection, even when the host and repository match.
            contextGeneration &+= 1
            hasCurrentReferences = false
            hasCurrentHistory = false
            hasCurrentStashes = false
            hasCurrentWorktrees = false
            stashFilesByOID = [:]
            invalidateStatusRefresh()
            needsCoreVerification = true
        }
        if self.backend is LocalWorkspaceBackend, targetChanged || localWatcher == nil {
            configureLocalWatcher(root: root, gitDirectory: nil)
        }
        refresh()
    }

    func setLocalFileEventsForeground(_ foreground: Bool) {
        guard localWatcherForeground != foreground else { return }
        localWatcherForeground = foreground
        if !foreground {
            pendingFileEvent?.cancel()
            localWatcher = nil
            localWatcherPaths = []
        } else {
            if case .repository(let previous) = cachedStatusByRoot[scopedRoot] {
                configureLocalWatcher(root: previous.topLevel, gitDirectory: previous.gitDirectory)
            } else {
                configureLocalWatcher(root: rootPath, gitDirectory: nil)
            }
            if !rootPath.isEmpty { refresh() }
        }
    }

    private func configureLocalWatcher(root: String, gitDirectory: String?) {
        guard localWatcherForeground else { return }
        let paths = backend is LocalWorkspaceBackend
            ? GitFileEventWatcher.paths(
                root: root, gitDirectory: gitDirectory,
                worktrees: worktreeLocations.map(\.path)
            ) : []
        guard paths != localWatcherPaths || localWatcher == nil else { return }
        pendingFileEvent?.cancel()
        localWatcher = nil
        localWatcherPaths = paths
        let generation = contextGeneration
        localWatcher = GitFileEventWatcher(paths: paths) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.localWatcherForeground,
                      self.contextGeneration == generation else { return }
                self.pendingFileEvent?.cancel()
                self.pendingFileEvent = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(400)) }
                    catch { return }
                    guard let self, self.localWatcherForeground,
                          self.contextGeneration == generation else { return }
                    self.refresh()
                }
            }
        }
    }

    private func queueRefresh(_ kind: RefreshKind) {
        if let pendingRefresh {
            self.pendingRefresh = pendingRefresh == kind ? kind : .full
        } else {
            pendingRefresh = kind
        }
    }

    func refresh(kind: RefreshKind = .full) {
        let root = rootPath
        let generation = contextGeneration
        let commitLimit = recentCommitLimit
        guard !root.isEmpty else { return }
        guard !isRefreshing, !isBusy else {
            queueRefresh(kind)
            return
        }
        let requestKind = pendingRefresh.map { $0 == kind ? kind : .full } ?? kind
        pendingRefresh = nil
        let expectedCore: StatusResult?
        if requestKind == .historyOnly,
           case .repository(let previous) = cachedStatusByRoot[scopedRoot] {
            expectedCore = previous
        } else {
            expectedCore = nil
        }
        statusRequestID &+= 1
        let requestID = statusRequestID
        coreCompletedRequestID = nil
        isRefreshing = true

        // A blocked filesystem may outlive the Git command timeout.
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
            let pending = self.pendingRefresh
            self.pendingRefresh = nil
            let timeout = String(localized: "Git did not respond in time.", table: "Git")
            if self.coreCompletedRequestID == requestID {
                if requestKind == .historyOnly {
                    self.historyPageError = timeout
                } else {
                    self.fullDetailError = timeout
                    self.historyPageError = nil
                    if requestKind == .full {
                        self.hasCurrentReferences = false
                        self.hasCurrentHistory = false
                        self.hasCurrentStashes = false
                        self.hasCurrentWorktrees = false
                    }
                }
            } else {
                self.apply(.failed(timeout))
            }
            self.hasResolvedStatus = true
            if let pending { self.refresh(kind: pending) }
        }

        let backend = backend
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await Self.runGitStatus(
                    in: root, recentCommitLimit: commitLimit, backend: backend,
                    kind: requestKind, requestID: requestID
                ) { [weak self] core in
                    guard let self, self.contextGeneration == generation,
                          self.statusRequestID == requestID, self.rootPath == root else { return false }
                    self.apply(.repository(core))
                    if self.backend is LocalWorkspaceBackend {
                        self.configureLocalWatcher(
                            root: core.topLevel, gitDirectory: core.gitDirectory
                        )
                    }
                    self.coreCompletedRequestID = requestID
                    let previous: StatusResult?
                    if case .repository(let saved) = self.cachedStatusByRoot[self.scopedRoot] {
                        previous = saved
                    } else {
                        previous = nil
                    }
                    self.cachedStatusByRoot[self.scopedRoot] = .repository(
                        core.retainingDisplayMetadata(from: previous)
                    )
                    if !self.hasResolvedStatus { self.hasResolvedStatus = true }
                    return true
                }
            }.value
            guard let self, self.contextGeneration == generation,
                  self.statusRequestID == requestID,
                  self.rootPath == root else { return }
            self.isRefreshing = false
            let loadingMore = commitLimit < self.recentCommitLimit
            if self.isLoadingMoreCommits != loadingMore { self.isLoadingMoreCommits = loadingMore }
            switch result {
            case .repository(let latest):
                if requestKind == .historyOnly {
                    // A page failure does not mean the verified repository changed.
                    // Only a changed core/ref snapshot requires a new full query.
                    if expectedCore?.matchesCore(latest) == true,
                       let history = latest.history,
                       history.refsByName == self.refsByName,
                       self.canUseCurrentReferences {
                        if self.recentCommits != history.commits { self.recentCommits = history.commits }
                        if self.hasMoreRecentCommits != history.hasMore {
                            self.hasMoreRecentCommits = history.hasMore
                        }
                        if !self.hasCurrentHistory { self.hasCurrentHistory = true }
                        self.historyPageError = nil
                        if case .repository(let cached) = self.cachedStatusByRoot[self.scopedRoot] {
                            var updated = cached
                            updated.history = history
                            self.cachedStatusByRoot[self.scopedRoot] = .repository(updated)
                        }
                    } else if expectedCore?.matchesCore(latest) != true
                                || !self.canUseCurrentReferences
                                || (latest.history != nil && latest.history?.refsByName != self.refsByName) {
                        self.hasCurrentLineTotals = false
                        self.queueRefresh(.full)
                    } else if let error = latest.detailError {
                        self.historyPageError = error
                    }
                } else {
                    let previous: StatusResult?
                    if case .repository(let cached) = self.cachedStatusByRoot[self.scopedRoot] {
                        previous = cached
                    } else {
                        previous = nil
                    }
                    self.cachedStatusByRoot[self.scopedRoot] = .repository(
                        latest.retainingDisplayMetadata(from: previous)
                    )
                    // Readable cached details are not evidence that this query
                    // verified them. Only the raw result can authorize actions.
                    self.apply(.repository(latest))
                    if requestKind == .indexOnly, !self.hasCurrentReferences {
                        self.queueRefresh(.full)
                    }
                }
            case .notRepository:
                self.cachedStatusByRoot[self.scopedRoot] = result
                self.apply(result)
            case .failed:
                self.apply(result)
            }
            if !self.hasResolvedStatus { self.hasResolvedStatus = true }
            if let pending = self.pendingRefresh {
                self.pendingRefresh = nil
                self.refresh(kind: pending)
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
            // Recheck the larger limit after the in-flight snapshot finishes.
            queueRefresh(.historyOnly)
        } else {
            refresh(kind: canUseCurrentHistory ? .historyOnly : .full)
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
        guard backend is LocalWorkspaceBackend, isRepo, canUseCurrentStatus else { return [] }
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
        guard !(selectedBackend is LocalWorkspaceBackend), isRepo, canUseCurrentStatus, !entries.isEmpty else {
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
        isRepo && canUseCurrentStatus && !isBusy && discardContext == review.context
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

    nonisolated static func ignorePatterns(_ paths: [String], isDirectory: Bool) throws -> [String] {
        try paths.map { path in
            guard !path.isEmpty, !path.hasPrefix("/"),
                  !path.contains("\n"), !path.contains("\r"), !path.contains("\0"),
                  !path.split(separator: "/").contains("..") else {
                throw NSError(domain: "Bailey.Git", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    String(localized: "This path cannot be safely added to .gitignore.", table: "Git")])
            }
            let escaped = path.map { character -> String in
                "\\*?[]#! ".contains(character) ? "\\" + String(character) : String(character)
            }.joined()
            return "/" + escaped + (isDirectory ? "/" : "")
        }
    }

    func stage(_ entry: Entry) {
        stageEntries([entry])
    }

    func stageEntries(_ entries: [Entry]) {
        guard !entries.isEmpty, entries.allSatisfy(validate) else { return }
        let paths = entries.flatMap { entry in
            [entry.path] + (entry.unstaged == "R" ? entry.origPath.map { [$0] } ?? [] : [])
        }
        perform(
            label: entries.count == 1
                ? String(localized: "Stage \(entries[0].fileName)", table: "Git")
                : String(localized: "Stage Changes", table: "Sidebar"),
            commands: [["--literal-pathspecs", "add", "--"] + paths],
            requiredStatus: .core, refreshKind: .indexOnly
        )
    }

    func unstage(_ entry: Entry) {
        unstageEntries([entry])
    }

    func unstageEntries(_ entries: [Entry]) {
        guard !entries.isEmpty, entries.allSatisfy(validate) else { return }
        let paths = entries.flatMap { entry in
            [entry.path] + (entry.staged == "R" ? entry.origPath.map { [$0] } ?? [] : [])
        }
        let args = hasHead
            ? ["--literal-pathspecs", "restore", "--staged", "--"] + paths
            : ["--literal-pathspecs", "rm", "--cached", "-f", "--"] + paths
        perform(label: entries.count == 1
                ? String(localized: "Unstage \(entries[0].fileName)", table: "Git")
                : String(localized: "Unstage Changes", table: "Sidebar"), commands: [args],
                requiredStatus: .core, refreshKind: .indexOnly)
    }

    func stageAll() {
        perform(label: String(localized: "Stage all changes", table: "Git"), commands: [["add", "-A"]],
                requiredStatus: .core, refreshKind: .indexOnly)
    }

    func unstageAll() {
        let args = hasHead
            ? ["restore", "--staged", "--", "."]
            : ["rm", "--cached", "-r", "-f", "--", "."]
        perform(label: String(localized: "Unstage all changes", table: "Git"), commands: [args],
                requiredStatus: .core, refreshKind: .indexOnly)
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
                ]], requiredStatus: .core, completion: { [weak self] success in
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
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", original]], requiredStatus: .core,
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
                commands: [["--literal-pathspecs", "restore", "--worktree", "--", entry.path]], requiredStatus: .core
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
            perform(label: String(localized: "Discard all changes", table: "Git"), commands: commands, requiredStatus: .core, completion: { [weak self] success in
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

    private enum RequiredStatus { case core, references, history, stashes }

    private func requireStatus(
        _ requirement: RequiredStatus, completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        let verified: Bool = switch requirement {
        case .core: canUseCurrentStatus
        case .references: canUseCurrentReferences
        case .history: canUseCurrentHistory
        case .stashes: canUseCurrentStashes
        }
        guard verified else {
            failImmediately(String(localized: "The Git action target changed. Reopen the menu and try again.", table: "Git"), completion: completion)
            return false
        }
        return true
    }

    /// Commits only the index unless `includeAll` explicitly requests `git add -A`.
    func commit(
        message: String,
        includeAll: Bool,
        amend: Bool = false
    ) {
        guard !amend || hasHead else {
            failImmediately(String(localized: "There is nothing staged to commit", table: "Git"))
            return
        }
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
        perform(label: label, commands: commands, requiredStatus: .core, completion: { [weak self] success in
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
            commands: [["switch", "--", name]],
            preflight: [["check-ref-format", "--branch", name]],
            prepare: prepare, isCurrentTarget: isCurrentTarget,
            completion: completion
        )
    }

    nonisolated enum BranchPushMode: String, CaseIterable, Sendable {
        case normal, forceWithLease, force
    }

    func preferredPushRemote(for name: String?) async -> String? {
        guard canUseCurrentReferences else { return nil }
        let available = remotes
        guard !available.isEmpty else { return nil }
        let generation = contextGeneration
        let result = await GitCommandExecution.run(
            ["config", "--null", "--get-regexp", "^(branch\\..*\\.(pushremote|remote)|remote\\.pushdefault)$"],
            in: repoRoot, backend: backend
        )
        guard generation == contextGeneration, canUseCurrentReferences else { return nil }
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

    func referenceOID(named reference: String, target: ActionTarget) async -> String? {
        guard isCurrent(target, requiresStableHead: false) else { return nil }
        let generation = contextGeneration
        let result = await GitCommandExecution.run(
            ["show-ref", "--verify", "--hash", reference], in: repoRoot, backend: backend
        )
        guard generation == contextGeneration,
              isCurrent(target, requiresStableHead: false) else { return nil }
        guard result.status == 0 else {
            failImmediately(result.stderr.isEmpty
                ? String(localized: "The selected Git reference changed. Reopen the menu and try again.", table: "Git")
                : result.stderr)
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func trackingRemotes(for name: String) -> [String] {
        remotes.filter { remote in
            let ref = refsByName["refs/remotes/\(remote)/\(name)"]
            return ref != nil && ref?.symbolic == nil
        }
    }

    func createBranch(
        named name: String, at hash: String?, checkout: Bool, replacing expectedOID: String?,
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
        let start = hash ?? "HEAD"
        let commands: [[String]]
        if expectedOID != nil {
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
                expectedRef: expectedOID.map { (name: "refs/heads/" + name, oid: $0) },
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

    func createWorktree(
        for branchName: String, at path: String, expectedOID: String, target: ActionTarget,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let validPath = path.hasPrefix("/") || (
            path.count >= 3 && path.first?.isLetter == true && path.dropFirst().hasPrefix(":/")
        )
        guard isCurrent(target), canCreateWorktree(for: branchName),
              refsByName["refs/heads/" + branchName]?.oid == expectedOID,
              validPath, !path.contains("\0"), path != repoRoot else {
            failImmediately(String(localized: "The branch, repository, or worktree path changed. Review and try again.", table: "Git"),
                            completion: completion)
            return
        }
        perform(label: String(localized: "Create Worktree", table: "Git"),
                commands: [["worktree", "add", "--", path, branchName]],
                expectedRef: ("refs/heads/" + branchName, expectedOID),
                expectedVacantWorktreeBranch: branchName,
                isCurrentTarget: isCurrentTarget, completion: completion)
    }

    func removeWorktree(
        _ selected: WorktreeLocation, target: ActionTarget,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isCurrent(target), hasCurrentWorktrees, canUseCurrentReferences,
              !selected.isMain, !selected.isLocked, !selected.isPrunable,
              worktreeLocations.contains(selected) else {
            failImmediately(String(localized: "The selected Worktree is unavailable or protected. Refresh and try again.", table: "Git"),
                            completion: completion)
            return
        }
        perform(label: String(localized: "Remove Worktree", table: "Git"),
                commands: [["worktree", "remove", "--", selected.path]],
                expectedWorktree: selected,
                isCurrentTarget: isCurrentTarget, completion: completion)
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
                preflight: [["check-ref-format", "--branch", localName]],
                expectedRef: (trackingRef, selected.oid),
                prepare: prepare, isCurrentTarget: isCurrentTarget, completion: completion)
    }

    func fetchIntoLocalBranch(
        _ selected: RemoteBranchTarget, force: Bool, destinationOID: String, target: ActionTarget,
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
                expectedRef: (localRef, destinationOID),
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

    /// The Git object is captured before the save sheet opens, so a later
    /// branch movement cannot quietly change the downloaded archive.
    func createArchive(
        reference: String, objectOID: String,
        destination: URL, target: ActionTarget
    ) async {
        guard requireStatus(.references) else { return }
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
                .appendingPathComponent(".bailey-archive-" + UUID().uuidString + ".zip")
            var remoteFolder: String?
            var output = ""
            var error: String?
            var destinationSaved = false
            do {
                guard await current() else {
                    throw NSError(domain: "BaileyGitArchive", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "The Git action target changed. Reopen the menu and try again.", table: "Git")
                    ])
                }
                let live = await GitCommandExecution.run(
                    ["show-ref", "--verify", "--hash", reference], in: root, backend: backend
                )
                guard live.status == 0,
                      live.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == objectOID else {
                    throw NSError(domain: "BaileyGitArchive", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "The selected Git reference changed. Reopen the menu and try again.", table: "Git")
                    ])
                }

                var archiveOutput = temporary.path
                if !(backend is LocalWorkspaceBackend) {
                    let created = try await backend.run(
                        argv: ["mktemp", "-d", "/tmp/bailey-archive-XXXXXXXX"],
                        cwd: nil, env: nil, stdin: nil, timeout: 25
                    )
                    let folder = String(decoding: created.stdout, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard created.status == 0, folder.hasPrefix("/tmp/bailey-archive-"),
                          !folder.contains("\n"), !folder.contains("\r") else {
                        throw NSError(domain: "BaileyGitArchive", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: String(decoding: created.stderr, as: UTF8.self)
                        ])
                    }
                    remoteFolder = folder
                    archiveOutput = folder + "/archive.zip"
                }
                guard await current() else {
                    throw NSError(domain: "BaileyGitArchive", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: String(localized: "The Git action target changed. Reopen the menu and try again.", table: "Git")
                    ])
                }
                let archived = await GitCommandExecution.run(
                    ["archive", "--format=zip", "-o", archiveOutput, objectOID],
                    in: root, backend: backend
                )
                guard archived.status == 0 else {
                    throw NSError(domain: "BaileyGitArchive", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: archived.stderr
                    ])
                }
                output = "$ git archive --format=zip " + reference
                if remoteFolder != nil {
                    let maximumSize = 64 * 1024 * 1024
                    let data = try await backend.read(path: archiveOutput, maxBytes: maximumSize)
                    try data.write(to: temporary, options: .atomic)
                }
                guard await current() else {
                    throw NSError(domain: "BaileyGitArchive", code: 4, userInfo: [
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
        replacing expectedOID: String?, target: ActionTarget,
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
        var args = ["tag"]
        if expectedOID != nil { args.append("-f") }
        if type == .annotated { args += ["-a", "-m", message] }
        args += ["--", name, commitOID]
        perform(
            label: String(localized: "Create tag \(name)", table: "Git"),
            commands: [args], requiresStableHead: false,
            preflight: [["check-ref-format", refName]],
            expectedRef: expectedOID.map { (name: refName, oid: $0) },
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
            commands: commands, requiredStatus: selectedOID == nil ? .references : .core,
            requiresStableHead: false,
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
        let object = await referenceOID(named: reference, target: target)
        guard generation == contextGeneration, isCurrent(target, requiresStableHead: false),
              peeled.status == 0, let object,
              peeled.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == commitOID else {
            return nil
        }
        return object
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
              isCurrent(target, requiresStableHead: false) else { return nil }
        guard result.status == 0 else {
            let message = String(localized: "Unable to check whether the tag commit is on the selected remotes.", table: "Git")
            failImmediately(message + (result.stderr.isEmpty ? "" : "\n" + result.stderr))
            return nil
        }
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
                requiredStatus: .history,
                preflight: [["cat-file", "-e", commit.hash + ":" + path]],
                expectedFileState: (path, expectedFileState),
                prepare: prepare, isCurrentTarget: isCurrentTarget, completion: completion)
    }

    func stash(
        message: String = "", includeUntracked: Bool = true, target: ActionTarget,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isCurrent(target), totalChangeCount > 0 else {
            failImmediately(String(localized: "There are no changes to stash", table: "Git"))
            return
        }
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if !message.isEmpty { args += ["--message", message] }
        perform(label: String(localized: "Stash changes", table: "Git"), commands: [args],
                requiredStatus: .core,
                prepare: prepare, isCurrentTarget: isCurrentTarget, completion: completion)
    }

    func resetUncommitted(
        mode: ResetMode, target: ActionTarget,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isCurrent(target), hasHead, mode != .soft else { return }
        perform(label: String(localized: "Reset…", table: "Git"),
                commands: [["reset", "--" + mode.rawValue, "HEAD"]],
                requiredStatus: .core,
                prepare: prepare, isCurrentTarget: isCurrentTarget, completion: completion)
    }

    func cleanUntracked(
        includeDirectories: Bool, target: ActionTarget,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isCurrent(target) else { return }
        perform(label: String(localized: "Clean…", table: "Git"),
                commands: [["clean", includeDirectories ? "-fd" : "-f"]],
                requiredStatus: .core,
                prepare: prepare, isCurrentTarget: isCurrentTarget, completion: completion)
    }

    func actOnStash(
        _ stash: Stash, action: StashAction, reinstateIndex: Bool = false,
        branchName: String = "", target: ActionTarget,
        expectedStashes: [Stash]? = nil,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard isCurrent(target, requiresStableHead: action != .drop),
              (stash.oid.count == 40 || stash.oid.count == 64), stash.oid.allSatisfy(\.isHexDigit),
              stash.selector.hasPrefix("stash@{"), stash.selector.hasSuffix("}"),
              Int(stash.selector.dropFirst(7).dropLast()) != nil else {
            failImmediately(String(localized: "The selected stash changed. Reopen the menu and select it again.", table: "Git"), completion: completion)
            return
        }
        let commands: [[String]]
        let preflight: [[String]]
        switch action {
        case .apply, .pop:
            commands = [["stash", action == .apply ? "apply" : "pop"]
                + (reinstateIndex ? ["--index"] : []) + [action == .apply ? stash.oid : stash.selector]]
            preflight = []
        case .drop:
            commands = [["stash", "drop", stash.selector]]
            preflight = []
        case .branch:
            let name = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.hasPrefix("-") else {
                failImmediately(String(localized: "Enter a branch name", table: "Git"), completion: completion)
                return
            }
            commands = [["stash", "branch", name, stash.selector]]
            preflight = [["check-ref-format", "--branch", name]]
        }
        let originalStashes = expectedStashes ?? stashes
        guard action == .apply || originalStashes.contains(stash) else {
            failImmediately(String(localized: "The selected stash changed. Reopen the menu and select it again.", table: "Git"),
                            completion: completion)
            return
        }
        perform(label: action.title, commands: commands,
                requiredStatus: .stashes,
                requiresStableHead: action != .drop, preflight: preflight,
                expectedStashes: action == .apply ? nil : originalStashes,
                prepare: action == .drop ? nil : prepare,
                isCurrentTarget: isCurrentTarget, completion: completion)
    }

    func initializeRepository(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !rootPath.isEmpty else {
            failImmediately(String(localized: "Open a terminal directory first", table: "Git"), completion: completion)
            return
        }
        perform(
            label: String(localized: "Initialize repository", table: "Git"),
            commands: [["init"]],
            directory: rootPath, requiredStatus: .core,
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
        requiredStatus: RequiredStatus = .references,
        refreshKind: RefreshKind = .full,
        requiresStableHead: Bool = true,
        requiresStableUpstream: Bool = false,
        squashMessage: String? = nil,
        dropCommit: String? = nil,
        terminalAction: (@MainActor () throws -> Void)? = nil,
        preflight: [[String]] = [], expectedRef: (name: String, oid: String)? = nil,
        expectedWorktree: WorktreeLocation? = nil, expectedVacantWorktreeBranch: String? = nil,
        expectedFileState: (path: String, state: FileState)? = nil,
        expectedStashes: [Stash]? = nil,
        continueAfterFirstSuccess: Bool = false,
        prepare: (@MainActor () async -> Bool)? = nil,
        isCurrentTarget: (@MainActor () -> Bool)? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard requireStatus(requiredStatus, completion: completion) else { return }
        if !canUseCurrentStatus || (directory == nil && !isRepo) {
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
            let fileUnchanged: Bool
            if let expectedFileState {
                fileUnchanged = await Self.readHistoricalFileState(
                    path: expectedFileState.path, root: dir, backend: backend
                ) == expectedFileState.state
            } else {
                fileUnchanged = true
            }
            let prepared: Bool
            if fileUnchanged {
                prepared = await prepare?() ?? true
            } else {
                prepared = false
            }
            let preparedFileState: FileState?
            if let expectedFileState, prepared {
                preparedFileState = await Self.readHistoricalFileState(
                    path: expectedFileState.path, root: dir, backend: backend
                )
            } else {
                preparedFileState = nil
            }
            let batch = await Task.detached(priority: .userInitiated) {
                var transcript: [String] = []
                var failureCode: Int32?
                var failureMessage: String?
                var failedCommand: [String]?
                var gitError: String?
                let staleMessage = String(localized: "The Git action target changed or edits could not be saved. No further Git commands were run.", table: "Git")
                let fileChangedMessage = String(localized:
                    "The selected file changed since the confirmation opened. Review it and try again.", table: "Git")
                guard fileUnchanged else {
                    return CommandBatchResult(output: fileChangedMessage, failureCode: -1,
                                              failureMessage: fileChangedMessage)
                }
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
                if expectedWorktree != nil || expectedVacantWorktreeBranch != nil {
                    let list = await GitCommandExecution.run(
                        ["worktree", "list", "--porcelain", "-z"], in: dir, backend: backend
                    )
                    guard list.status == 0, let locations = Self.parseWorktreeList(list.stdout) else {
                        let message = String(localized: "Could not verify the current Worktree list. Nothing was changed.", table: "Git")
                        return CommandBatchResult(output: message, failureCode: -1, failureMessage: message)
                    }
                    if let branch = expectedVacantWorktreeBranch,
                       locations.contains(where: { $0.branch == branch }) {
                        let message = String(localized: "The branch is already checked out in another Worktree.", table: "Git")
                        return CommandBatchResult(output: message, failureCode: -1, failureMessage: message)
                    }
                    if let expectedWorktree {
                        guard !expectedWorktree.isMain, !expectedWorktree.isLocked,
                              !expectedWorktree.isPrunable,
                              locations.contains(expectedWorktree) else {
                            let message = String(localized: "The selected Worktree changed, is locked, or is the main Worktree.", table: "Git")
                            return CommandBatchResult(output: message, failureCode: -1, failureMessage: message)
                        }
                        let status = await GitCommandExecution.run(
                            ["-C", expectedWorktree.path, "status", "--porcelain=v2",
                             "--branch", "-z", "--untracked-files=all"],
                            in: dir, backend: backend
                        )
                        let live = status.status == 0 ? Self.parseStatus(status.stdout) : nil
                        guard let live, live.headOID == expectedWorktree.headOID,
                              (live.branch == "detached HEAD" ? nil : live.branch) == expectedWorktree.branch,
                              live.entries.isEmpty else {
                            let message = String(localized: "The Worktree changed or contains uncommitted files. Nothing was removed.", table: "Git")
                            return CommandBatchResult(output: message, failureCode: -1, failureMessage: message)
                        }
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
                if let expectedStashes {
                    let actual = await GitCommandExecution.run(
                        Self.stashListArguments, in: dir, backend: backend
                    )
                    guard actual.status == 0,
                          Self.parseStashes(actual.stdout) == expectedStashes else {
                        let message = String(localized: "The selected stash changed. Reopen the menu and select it again.", table: "Git")
                        return CommandBatchResult(output: message, failureCode: -1, failureMessage: message)
                    }
                }
                if let expectedFileState {
                    guard let preparedFileState,
                          preparedFileState.indexOID == expectedFileState.state.indexOID,
                          await isCurrent(),
                          await Self.readHistoricalFileState(
                            path: expectedFileState.path, root: dir, backend: backend
                          ) == preparedFileState else {
                        return CommandBatchResult(output: fileChangedMessage, failureCode: -1,
                                                  failureMessage: fileChangedMessage)
                    }
                }
                if squashMessage != nil {
                    guard await isCurrent() else {
                        return CommandBatchResult(output: staleMessage, failureCode: -1,
                                                  failureMessage: staleMessage)
                    }
                    let baseline = await GitCommandExecution.run(
                        ["diff", "--cached", "--quiet"], in: dir, backend: backend
                    )
                    guard baseline.status == 0 else {
                        let message = baseline.status == 1
                            ? String(localized: "Commit or unstage existing staged changes before automatic Squash Merge.", table: "Git")
                            : (baseline.stderr.isEmpty
                               ? String(localized: "Unable to inspect staged changes.", table: "Git")
                               : baseline.stderr)
                        return CommandBatchResult(output: message, failureCode: baseline.status,
                                                  failureMessage: message,
                                                  failedCommand: ["diff", "--cached", "--quiet"],
                                                  gitError: baseline.stderr)
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
            self.refresh(kind: refreshKind)
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
        guard !paths.isEmpty, !isBusy, canUseCurrentStatus else { return }
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
        pendingRefresh = nil
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

    private nonisolated static let stashListArguments = [
        "stash", "list", "-z", "--format=%gd%x00%H%x00%gs%x00%P%x00%an%x00%ct"
    ]

    nonisolated static func parseStashes(_ output: String) -> [Stash]? {
        if output.isEmpty { return [] }
        var fields = output.components(separatedBy: "\0")
        guard fields.removeLast() == "", fields.count.isMultiple(of: 6) else { return nil }
        var stashes: [Stash] = []
        for index in stride(from: 0, to: fields.count, by: 6) {
            let selector = fields[index]
            let oid = fields[index + 1]
            let parents = fields[index + 3].split(separator: " ").map(String.init)
            guard selector == "stash@{\(stashes.count)}",
                  (oid.count == 40 || oid.count == 64), oid.allSatisfy(\.isHexDigit),
                  (2...3).contains(parents.count),
                  parents.allSatisfy({ $0.count == oid.count && $0.allSatisfy(\.isHexDigit) }),
                  let timestamp = TimeInterval(fields[index + 5]) else { return nil }
            stashes.append(Stash(
                selector: selector, oid: oid, message: fields[index + 2],
                baseHash: parents[0], untrackedFilesHash: parents.count == 3 ? parents[2] : nil,
                author: fields[index + 4], date: Date(timeIntervalSince1970: timestamp)
            ))
        }
        return stashes
    }

    nonisolated static func parseStashFileChanges(
        _ output: String, fromUntracked: Bool = false
    ) -> [RecentCommit.FileChange]? {
        if output.isEmpty { return [] }
        var tokens = output.components(separatedBy: "\0")
        guard tokens.removeLast() == "" else { return nil }
        var changes: [RecentCommit.FileChange] = []
        var index = 0
        while index < tokens.count {
            let code = tokens[index]
            guard let status = code.first, "ACDMRT".contains(status) else { return nil }
            index += 1
            let original: String?
            if status == "R" || status == "C" {
                guard index < tokens.count, !tokens[index].isEmpty else { return nil }
                original = tokens[index]
                index += 1
            } else {
                original = nil
            }
            guard index < tokens.count, !tokens[index].isEmpty else { return nil }
            changes.append(.init(
                status: status, path: tokens[index], originalPath: original,
                fromStashUntracked: fromUntracked
            ))
            index += 1
        }
        return changes
    }

    /// File details are fetched only for an expanded stash, never per status poll.
    func loadStashFiles(for stash: Stash) {
        guard isRepo, stashes.contains(stash) else { return }
        if let cached = stashFilesByOID[stash.oid] {
            switch cached {
            case .loading, .loaded: return
            case .failed: break
            }
        }
        stashFilesByOID[stash.oid] = .loading
        let generation = contextGeneration
        let root = repoRoot
        let backend = backend
        Task { [weak self] in
            let state = await Task.detached(priority: .utility) { () async -> StashFilesState in
                let tracked = await GitCommandExecution.run([
                    "diff", "--name-status", "-z", "--no-ext-diff",
                    stash.baseHash, stash.oid, "--"
                ], in: root, backend: backend)
                guard tracked.status == 0,
                      let trackedFiles = Self.parseStashFileChanges(tracked.stdout) else {
                    return .failed(tracked.stderr.isEmpty
                        ? String(localized: "Unable to read stash changes", table: "Git")
                        : tracked.stderr)
                }
                guard let untracked = stash.untrackedFilesHash else { return .loaded(trackedFiles) }
                let extra = await GitCommandExecution.run([
                    "diff-tree", "--root", "-r", "--name-status", "-z",
                    "--no-commit-id", untracked, "--"
                ], in: root, backend: backend)
                guard extra.status == 0,
                      let extraFiles = Self.parseStashFileChanges(extra.stdout, fromUntracked: true) else {
                    return .failed(extra.stderr.isEmpty
                        ? String(localized: "Unable to read stash changes", table: "Git")
                        : extra.stderr)
                }
                return .loaded(trackedFiles + extraFiles)
            }.value
            guard let self, self.contextGeneration == generation, self.repoRoot == root,
                  self.stashes.contains(where: { $0.oid == stash.oid }) else { return }
            self.stashFilesByOID[stash.oid] = state
        }
    }

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
        clearDetails()
        mergeEntries = []
        stagedEntries = []
        changedEntries = []
        directoryDecorations = [:]
        fileDecorations = [:]
        ignoredPaths = []
        repositoryOperation = nil
        isRefreshing = false
        isBusy = runningOperationID != nil
        operation = failedOperation
        lastError = failedError
        statusError = nil
        fullDetailError = nil
        historyPageError = nil
        needsCoreVerification = false
        coreCompletedRequestID = nil
        statusRequestID &+= 1
        pendingRefresh = nil
        if !preserveIdentity { repositoryIdentity = "" }
    }

    private func clearDetails() {
        lineAdditions = 0
        lineDeletions = 0
        hasCurrentReferences = false
        hasCurrentHistory = false
        hasCurrentStashes = false
        hasCurrentLineTotals = false
        branches = []
        refsByName = [:]
        defaultBranch = nil
        remotes = []
        recentCommits = []
        stashFilesByOID = [:]
        historicalBinaryPaths = [:]
        pendingBinaryCommits.removeAll()
        hasMoreRecentCommits = false
        isLoadingMoreCommits = false
        stashes = []
        currentWorktree = nil
        otherWorktrees = []
        worktreeLocations = []
        hasCurrentWorktrees = false
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
            if statusError != message { statusError = message }
            if hasCurrentReferences { hasCurrentReferences = false }
            if hasCurrentHistory { hasCurrentHistory = false }
            if hasCurrentStashes { hasCurrentStashes = false }
            if hasCurrentWorktrees { hasCurrentWorktrees = false }
            return
        case .repository(let result):
            if statusError != nil { statusError = nil }
            applyRepository(result)
        }
    }

    private func applyRepository(_ result: StatusResult) {
        if needsCoreVerification { needsCoreVerification = false }
        if result.detailsCompleted {
            if fullDetailError != result.detailError { fullDetailError = result.detailError }
            if historyPageError != nil { historyPageError = nil }
            if result.coreMetadata == nil, hasCurrentReferences { hasCurrentReferences = false }
        }
        let changed = repositoryIdentity != result.topLevel || headOID != result.headOID
            || branch != result.branch || repositoryOperation != result.repositoryOperation
            || (result.coreMetadata.map { $0.refsByName != refsByName || $0.remotes != remotes } ?? false)
        if changed {
            hasCurrentReferences = false
            hasCurrentHistory = false
            hasCurrentStashes = false
            hasCurrentWorktrees = false
            hasCurrentLineTotals = false
        }
        if repositoryIdentity != result.topLevel {
            clearDetails()
            ignoredPaths = []
        }
        if !isRepo { isRepo = true }
        if branch != result.branch { branch = result.branch }
        if headOID != result.headOID { headOID = result.headOID }
        if hasHead != result.hasHead { hasHead = result.hasHead }
        if upstream != result.upstream { upstream = result.upstream }
        if ahead != result.ahead { ahead = result.ahead }
        if behind != result.behind { behind = result.behind }
        if hasUpstream != (result.upstream != nil) { hasUpstream = result.upstream != nil }
        if repositoryOperation != result.repositoryOperation { repositoryOperation = result.repositoryOperation }
        if topLevel != result.topLevel { topLevel = result.topLevel }
        if repositoryIdentity != result.topLevel { repositoryIdentity = result.topLevel }
        let current = WorktreeChanges(
            path: result.topLevel,
            branch: result.branch == "detached HEAD" ? nil : result.branch,
            headOID: result.headOID, entries: result.entries, isCurrent: true
        )
        if currentWorktree != current { currentWorktree = current }
        if let worktrees = result.worktrees, otherWorktrees != worktrees {
            otherWorktrees = worktrees
        }
        if let locations = result.worktreeLocations {
            if worktreeLocations != locations { worktreeLocations = locations }
            if !hasCurrentWorktrees { hasCurrentWorktrees = true }
            if backend is LocalWorkspaceBackend {
                configureLocalWatcher(root: result.topLevel, gitDirectory: result.gitDirectory)
            }
        } else if result.detailsCompleted, hasCurrentWorktrees {
            hasCurrentWorktrees = false
        }
        if let core = result.coreMetadata {
            if branches != core.branches { branches = core.branches }
            if refsByName != core.refsByName { refsByName = core.refsByName }
            if remotes != core.remotes { remotes = core.remotes }
            if defaultBranch != core.defaultBranch { defaultBranch = core.defaultBranch }
            if !hasCurrentReferences { hasCurrentReferences = true }
        }
        if let history = result.history {
            if recentCommits != history.commits { recentCommits = history.commits }
            if hasMoreRecentCommits != history.hasMore { hasMoreRecentCommits = history.hasMore }
            if !hasCurrentHistory { hasCurrentHistory = true }
        }
        if let freshStashes = result.stashes {
            if stashes != freshStashes { stashes = freshStashes }
            if !hasCurrentStashes { hasCurrentStashes = true }
            let liveStashOIDs = Set(freshStashes.map(\.oid))
            let surviving = stashFilesByOID.filter { liveStashOIDs.contains($0.key) }
            if stashFilesByOID != surviving { stashFilesByOID = surviving }
        }
        if result.detailsCompleted {
            if hasCurrentHistory != (result.history != nil) {
                hasCurrentHistory = result.history != nil
            }
            if hasCurrentStashes != (result.stashes != nil) {
                hasCurrentStashes = result.stashes != nil
            }
        }
        if let totals = result.lineTotals {
            switch totals {
            case .available(let additions, let deletions):
                if lineAdditions != additions { lineAdditions = additions }
                if lineDeletions != deletions { lineDeletions = deletions }
                if !hasCurrentLineTotals { hasCurrentLineTotals = true }
            case .unavailable:
                if hasCurrentLineTotals { hasCurrentLineTotals = false }
            }
        }
        let entries = result.entries.map { entry in
            var entry = entry
            entry.repositoryRoot = result.topLevel
            entry.snapshotGeneration = contextGeneration
            entry.snapshotBranch = result.branch
            entry.snapshotHeadOID = result.headOID
            return entry
        }
        // A staged deletion and untracked file can legitimately share one path.
        let decorations = Dictionary(
            entries.map {
                ($0.path, FileDecoration(staged: $0.staged, unstaged: $0.unstaged, isConflict: $0.isConflict))
            },
            uniquingKeysWith: { first, _ in first }
        )
        if decorations != fileDecorations {
            var ancestors: [String: FileDecoration] = [:]
            for (path, decoration) in decorations {
                var parent = path
                while let slash = parent.lastIndex(of: "/") {
                    parent = String(parent[..<slash])
                    if let current = ancestors[parent],
                       current.directoryPriority >= decoration.directoryPriority { continue }
                    ancestors[parent] = decoration
                }
            }
            directoryDecorations = ancestors
            fileDecorations = decorations
        }
        if result.ignoredLoaded {
            if ignoredPaths != result.ignoredPaths { ignoredPaths = result.ignoredPaths }
        }
        let conflicts = entries.filter(\.isConflict)
        let staged = entries.filter {
            !$0.isConflict && $0.staged != "." && $0.staged != "?"
        }
        let changedFiles = entries.filter {
            !$0.isConflict && $0.unstaged != "."
        }
        if mergeEntries != conflicts { mergeEntries = conflicts }
        if stagedEntries != staged { stagedEntries = staged }
        if changedEntries != changedFiles { changedEntries = changedFiles }
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
        var topLevel = ""
        var gitDirectory: String?
        var entries: [Entry] = []
        var ignoredPaths: Set<String> = []
        var ignoredLoaded = false
        var repositoryOperation: String?
        var coreMetadata: StatusCoreMetadata?
        var detailsCompleted = false
        var detailError: String?
        var lineTotals: StatusLineTotals?
        var history: StatusHistory?
        var stashes: [Stash]?
        var worktrees: [WorktreeChanges]?
        var worktreeLocations: [WorktreeLocation]?

        // A missing optional query must preserve its last readable result in
        // the tab cache, without treating that copy as freshly verified.
        nonisolated func retainingDisplayMetadata(from previous: StatusResult?) -> StatusResult {
            guard let previous, topLevel == previous.topLevel else { return self }
            var snapshot = self
            if snapshot.coreMetadata == nil { snapshot.coreMetadata = previous.coreMetadata }
            if snapshot.history == nil { snapshot.history = previous.history }
            if snapshot.stashes == nil { snapshot.stashes = previous.stashes }
            if snapshot.worktrees == nil { snapshot.worktrees = previous.worktrees }
            if snapshot.worktreeLocations == nil { snapshot.worktreeLocations = previous.worktreeLocations }
            if !snapshot.ignoredLoaded, previous.ignoredLoaded {
                snapshot.ignoredLoaded = true
                snapshot.ignoredPaths = previous.ignoredPaths
            }
            if snapshot.lineTotals == nil { snapshot.lineTotals = previous.lineTotals }
            return snapshot
        }

        nonisolated func matchesCore(_ other: StatusResult) -> Bool {
            topLevel == other.topLevel && branch == other.branch
                && headOID == other.headOID && hasHead == other.hasHead
                && upstream == other.upstream && ahead == other.ahead && behind == other.behind
                && repositoryOperation == other.repositoryOperation
                && entries == other.entries
        }
    }

    nonisolated struct StatusCoreMetadata: Equatable, Sendable {
        var branches: [String] = []
        var refsByName: [String: GitRef] = [:]
        var remotes: [String] = []
        var defaultBranch: String?
    }

    nonisolated enum StatusLineTotals: Equatable, Sendable {
        case available(additions: Int, deletions: Int)
        case unavailable
    }

    nonisolated struct StatusHistory: Equatable, Sendable {
        let refsByName: [String: GitRef]
        let commits: [RecentCommit]
        let hasMore: Bool
    }

    /// Resolves the active repository and distinguishes a normal non-repo
    /// directory from an actual Git failure that the UI should surface.
    private nonisolated static func runGitStatus(
        in root: String,
        recentCommitLimit: Int,
        backend: WorkspaceBackend,
        kind: RefreshKind,
        requestID: UInt,
        onCore: @MainActor @Sendable (StatusResult) -> Bool
    ) async -> StatusLoadResult {
        let started = ProcessInfo.processInfo.systemUptime
        let remote = !(backend is LocalWorkspaceBackend)
        var phase = "core"
        var outcome = "failed"
        defer {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            Self.statusLogger.debug("refresh id=\(requestID, privacy: .public) remote=\(remote, privacy: .public) phase=\(phase, privacy: .public) result=\(outcome, privacy: .public) elapsed_ms=\(elapsed, privacy: .public)")
        }
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
        let statusArguments = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]
        let coreArguments = [["rev-parse", "--show-toplevel"], statusArguments,
                             ["rev-parse", "--absolute-git-dir"]]
        var prefetched = await prefetchedSnapshotCommands(
            in: root, argumentSets: coreArguments, discoverRoot: true,
            backend: backend, deadline: deadline
        )
        func statusGit(
            _ args: [String], in directory: String, batched: Bool = true
        ) async -> (status: Int32, stdout: String, stderr: String) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return (-2, "", timeoutMessage) }
            if !(backend is LocalWorkspaceBackend), batched {
                return prefetched[args.joined(separator: " ")]
                    ?? (-1, "", String(localized: "Unable to read Git status.", table: "Git"))
            }
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
               (await containsGitMetadata(atOrAbove: root, backend: backend, deadline: deadline)) == false {
                return .notRepository
            }
            return .failed(failure)
        }
        let resolvedRoot = strippingTrailingLineEnding(top.stdout)
        guard !resolvedRoot.isEmpty else {
            return .failed(String(localized: "Git returned an empty repository path.", table: "Git"))
        }
        let status = await statusGit(statusArguments, in: resolvedRoot)
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

        let gitDir = await statusGit(["rev-parse", "--absolute-git-dir"], in: resolvedRoot)
        guard gitDir.status == 0 else {
            return .failed(gitFailureMessage(
                gitDir, fallback: String(localized: "Unable to read Git status.", table: "Git")
            ))
        }
        let path = strippingTrailingLineEnding(gitDir.stdout)
        result.gitDirectory = path
        do {
            result.repositoryOperation = try await detectRepositoryOperation(
                gitDirectory: path, backend: backend, deadline: deadline
            )
        } catch WorkspaceError.timedOut {
            return .failed(timeoutMessage)
        } catch {
            return .failed(error.localizedDescription)
        }

        phase = "details"
        outcome = "partial"
        let coreMilliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        Self.statusLogger.debug("core ready id=\(requestID, privacy: .public) remote=\(remote, privacy: .public) elapsed_ms=\(coreMilliseconds, privacy: .public)")
        guard await onCore(result) else { return .repository(result) }
        if kind == .historyOnly {
            prefetched = await prefetchedSnapshotCommands(
                in: resolvedRoot,
                argumentSets: [Self.refSnapshotArguments, recentCommitLogArguments(limit: recentCommitLimit)],
                discoverRoot: false, backend: backend, deadline: deadline
            )
            let refs = await statusGit(Self.refSnapshotArguments, in: resolvedRoot)
            guard refs.status == 0 else {
                result.detailError = gitFailureMessage(refs, fallback: timeoutMessage)
                return .repository(result)
            }
            let names = parseRefSnapshot(refs.stdout)
            let log = await statusGit(recentCommitLogArguments(limit: recentCommitLimit), in: resolvedRoot)
            guard log.status == 0 else {
                result.detailError = gitFailureMessage(log, fallback: timeoutMessage)
                return .repository(result)
            }
            let commits = parseRecentCommits(log.stdout, refsByName: names)
            result.history = StatusHistory(
                refsByName: names,
                commits: Array(commits.prefix(recentCommitLimit)),
                hasMore: commits.count > recentCommitLimit
            )
            outcome = "complete"
            return .repository(result)
        }

        if kind == .full {
            result.detailsCompleted = true
            let optionalArguments = [
                Self.refSnapshotArguments, ["remote"],
                recentCommitLogArguments(limit: recentCommitLimit), stashListArguments,
                ["status", "--porcelain=v2", "-z", "--untracked-files=normal", "--ignored=matching"],
            ]
            prefetched = await prefetchedSnapshotCommands(
                in: resolvedRoot, argumentSets: optionalArguments,
                discoverRoot: false, backend: backend, deadline: deadline
            )
            let refs = await statusGit(Self.refSnapshotArguments, in: resolvedRoot)
            let remoteRun = await statusGit(["remote"], in: resolvedRoot)
            if refs.status == 0, remoteRun.status == 0 {
                var metadata = StatusCoreMetadata()
                metadata.refsByName = parseRefSnapshot(refs.stdout)
                metadata.branches = metadata.refsByName.keys.compactMap { name in
                    name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : nil
                }.sorted()
                metadata.remotes = remoteRun.stdout.split(separator: "\n").map(String.init).sorted()
                if let remote = metadata.remotes.contains("origin") ? "origin" : metadata.remotes.first,
                   let ref = metadata.refsByName["refs/remotes/\(remote)/HEAD"]?.symbolic,
                   ref.hasPrefix("refs/remotes/\(remote)/") {
                    let name = String(ref.dropFirst("refs/remotes/\(remote)/".count))
                    if metadata.branches.contains(name) { metadata.defaultBranch = name }
                }
                result.coreMetadata = metadata
            } else {
                result.detailError = gitFailureMessage(
                    refs.status != 0 ? refs : remoteRun,
                    fallback: String(localized: "Unable to read Git references.", table: "Git")
                )
            }
            if let verified = result.coreMetadata {
                let log = await statusGit(recentCommitLogArguments(limit: recentCommitLimit), in: resolvedRoot)
                if log.status == 0 {
                    let commits = parseRecentCommits(log.stdout, refsByName: verified.refsByName)
                    if !result.hasHead || !commits.isEmpty {
                        result.history = StatusHistory(
                            refsByName: verified.refsByName,
                            commits: Array(commits.prefix(recentCommitLimit)),
                            hasMore: commits.count > recentCommitLimit
                        )
                    } else {
                        result.detailError = String(localized: "Unable to read Git history.", table: "Git")
                    }
                } else if result.hasHead {
                    result.detailError = gitFailureMessage(log,
                        fallback: String(localized: "Unable to read Git history.", table: "Git"))
                } else {
                    // Unborn repositories have no commit history to fetch.
                    result.history = StatusHistory(refsByName: verified.refsByName, commits: [], hasMore: false)
                }
            }

            let stash = await statusGit(stashListArguments, in: resolvedRoot)
            if stash.status == 0, let values = parseStashes(stash.stdout) {
                result.stashes = values
            } else if result.detailError == nil {
                result.detailError = gitFailureMessage(stash,
                    fallback: String(localized: "Unable to read the stash list.", table: "Git"))
            }
            let ignored = await statusGit(
                ["status", "--porcelain=v2", "-z", "--untracked-files=normal", "--ignored=matching"],
                in: resolvedRoot
            )
            if ignored.status == 0 {
                result.ignoredPaths = parseStatus(ignored.stdout).ignoredPaths
                result.ignoredLoaded = true
            } else if result.detailError == nil {
                result.detailError = gitFailureMessage(ignored,
                    fallback: String(localized: "Unable to read ignored files.", table: "Git"))
            }
        }

        let diff = await statusGit(
            result.hasHead ? ["diff", "--numstat", "HEAD", "--"] : ["diff", "--numstat", "--cached", "--"],
            in: resolvedRoot, batched: false
        )
        if diff.status == 0 {
            var totals = parseNumstat(diff.stdout)
            var totalsReadable = true
            if !result.hasHead {
                let unstaged = await statusGit(["diff", "--numstat", "--"], in: resolvedRoot, batched: false)
                if unstaged.status == 0 {
                    let extra = parseNumstat(unstaged.stdout)
                    totals.additions += extra.additions
                    totals.deletions += extra.deletions
                } else { totalsReadable = false }
            }
            if totalsReadable {
                do {
                    let untracked = try await untrackedLineAdditions(
                        for: result.entries, in: resolvedRoot, backend: backend, deadline: deadline
                    )
                    result.lineTotals = untracked.complete
                        ? .available(additions: totals.additions + untracked.lines, deletions: totals.deletions)
                        : .unavailable
                } catch {
                    result.lineTotals = .unavailable
                }
            } else { result.lineTotals = .unavailable }
        } else {
            result.lineTotals = .unavailable
        }
        if kind == .full {
            let worktrees = await loadOtherWorktrees(
                in: resolvedRoot, backend: backend, deadline: deadline
            )
            result.worktreeLocations = worktrees.locations
            if worktrees.complete { result.worktrees = worktrees.worktrees }
            if !worktrees.complete, result.detailError == nil {
                result.detailError = String(
                    localized: "Unable to read every worktree status.", table: "Git"
                )
            }
        }
        outcome = result.detailError == nil ? "complete" : "degraded"
        return .repository(result)
    }


    /// A checkout path may contain spaces, Unicode or newlines. Porcelain -z
    /// separates fields and records without quoting any path contents.
    nonisolated struct WorktreeLocation: Equatable, Sendable {
        let path: String
        let headOID: String?
        let branch: String?
        var isMain = false
        var isLocked = false
        var isPrunable = false
    }

    nonisolated static func parseWorktreeList(_ output: String) -> [WorktreeLocation]? {
        guard output.hasSuffix("\0\0") else { return nil }
        var worktrees: [WorktreeLocation] = []
        var path: String?
        var headOID: String?
        var branch: String?
        var hasHead = false
        var isLocked = false
        var isPrunable = false
        var bare = false
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let path, hasHead, !bare,
                   path.hasPrefix("/") || (path.count >= 3 && path.first?.isLetter == true
                                           && path.dropFirst().hasPrefix(":/")) {
                    worktrees.append(WorktreeLocation(
                        path: path, headOID: headOID, branch: branch,
                        isMain: worktrees.isEmpty, isLocked: isLocked, isPrunable: isPrunable
                    ))
                }
                path = nil
                headOID = nil
                branch = nil
                hasHead = false
                isLocked = false
                isPrunable = false
                bare = false
            } else if field.hasPrefix("worktree ") {
                path = String(field.dropFirst("worktree ".count))
            } else if field.hasPrefix("HEAD ") {
                let oid = String(field.dropFirst("HEAD ".count))
                guard (oid.count == 40 || oid.count == 64),
                      oid.allSatisfy(\.isHexDigit) else { return nil }
                headOID = oid.allSatisfy { $0 == "0" } ? nil : oid
                hasHead = true
            } else if field.hasPrefix("branch refs/heads/") {
                branch = String(field.dropFirst("branch refs/heads/".count))
            } else if field == "bare" {
                bare = true
            } else if field == "locked" || field.hasPrefix("locked ") {
                isLocked = true
            } else if field == "prunable" || field.hasPrefix("prunable ") {
                isPrunable = true
            }
        }
        return worktrees
    }

    /// An optional detail read, never a source of Git actions. Read external
    /// worktrees through the selected workspace backend (including SSH).
    private nonisolated static func loadOtherWorktrees(
        in root: String, backend: WorkspaceBackend, deadline: Date
    ) async -> (worktrees: [WorktreeChanges], locations: [WorktreeLocation]?, complete: Bool) {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return ([], nil, false) }
        let list = await GitCommandExecution.run(
            ["worktree", "list", "--porcelain", "-z"],
            in: root, timeout: remaining, backend: backend
        )
        guard list.status == 0,
              let locations = parseWorktreeList(list.stdout) else { return ([], nil, false) }
        let current = (root as NSString).standardizingPath
        let others = locations.filter {
            !($0.isPrunable) && ($0.path as NSString).standardizingPath != current
        }
        let statusArguments = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]
        let commandSets = others.map { ["-C", $0.path] + statusArguments }
        let batched = await prefetchedSnapshotCommands(
            in: root, argumentSets: commandSets, discoverRoot: false,
            backend: backend, deadline: deadline
        )
        var loaded: [WorktreeChanges] = []
        var complete = true
        for (location, args) in zip(others, commandSets) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { complete = false; break }
            let run: (status: Int32, stdout: String, stderr: String)
            if backend is LocalWorkspaceBackend {
                run = await GitCommandExecution.run(
                    args, in: root, timeout: remaining, backend: backend
                )
            } else {
                run = batched[args.joined(separator: " ")] ?? (-1, "", "")
            }
            guard run.status == 0 else {
                complete = false
                continue
            }
            let state = parseStatus(run.stdout)
            let branch = state.branch == "detached HEAD" ? nil : state.branch
            // A checkout may have moved its HEAD during this read; never
            // connect its changes to an out-of-date ref from the first query.
            guard state.headOID == location.headOID, branch == location.branch else {
                complete = false
                continue
            }
            if !state.entries.isEmpty {
                loaded.append(WorktreeChanges(
                    path: location.path, branch: branch, headOID: state.headOID,
                    entries: state.entries, isCurrent: false
                ))
            }
        }
        return (loaded, locations, complete)
    }

    private nonisolated static func prefetchedSnapshotCommands(
        in root: String, argumentSets: [[String]], discoverRoot: Bool,
        backend: WorkspaceBackend, deadline: Date
    ) async -> [String: (status: Int32, stdout: String, stderr: String)] {
        guard !(backend is LocalWorkspaceBackend), !argumentSets.isEmpty else { return [:] }
        let tag = UUID().uuidString
        let commands = argumentSets.enumerated().map { index, args in
            (
                name: "command-\(index)",
                command: "env GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 LC_ALL=C git "
                    + args.map(RemoteCommands.quote).joined(separator: " ") + " 2>&1"
            )
        }
        // The first batch resolves an arbitrary cwd; detail batches already
        // have the verified repository root and avoid rediscovering it.
        let script: String
        if discoverRoot {
            let toplevel = RemoteCommands.batchCommand([commands[0]], tag: tag)
            script = "cd \(RemoteCommands.quote(root)) || exit 1; "
                + "t=$(git rev-parse --show-toplevel 2>/dev/null); "
                + "if [ -z \"$t\" ]; then \(toplevel); else cd \"$t\" || exit 1; "
                + RemoteCommands.batchCommand(commands, tag: tag) + "; fi"
        } else {
            script = "cd \(RemoteCommands.quote(root)) || exit 1; "
                + RemoteCommands.batchCommand(commands, tag: tag)
        }

        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0,
            let result = try? await backend.run(
                argv: ["sh", "-s"], cwd: nil, env: nil,
                stdin: Data(script.utf8), timeout: remaining
            )
        else { return [:] }

        var answers: [String: (status: Int32, stdout: String, stderr: String)] = [:]
        let parsed = RemoteCommands.parseBatch(result.stdout, tag: tag)
        for (index, args) in argumentSets.enumerated() {
            guard let batched = parsed["command-\(index)"] else { continue }
            answers[args.joined(separator: " ")] = (
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
        atOrAbove root: String, backend: WorkspaceBackend, deadline: Date
    ) async -> Bool? {
        if !(backend is LocalWorkspaceBackend) {
            // The ancestor walk is one round trip per level otherwise, and it
            // runs every time the panel leaves a repository.
            guard let result = try? await backend.run(
                argv: [
                    "sh", "-c",
                    RemoteCommands.gitMetadataAtOrAboveCommand(path: root),
                ],
                cwd: nil, env: nil, stdin: nil, timeout: max(0.001, deadline.timeIntervalSinceNow)
            ), result.status == 0 else { return nil }
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
            do {
                if try await backend.stat(path: marker) != nil { return true }
            } catch { return nil }
            let parent = directory.deletingLastPathComponent as NSString
            if parent.isEqual(to: directory as String) { return false }
            directory = parent
        }
    }

    /// One round trip instead of one per marker.
    private nonisolated static func remoteRepositoryOperation(
        gitDirectory: String, backend: WorkspaceBackend, deadline: Date?
    ) async throws -> String? {
        let remaining = deadline?.timeIntervalSinceNow
        if let remaining, remaining <= 0 { throw WorkspaceError.timedOut }
        let result = try await backend.run(
            argv: ["sh", "-c", RemoteCommands.repositoryOperationCommand(gitDirectory: gitDirectory)],
            cwd: nil, env: nil, stdin: nil, timeout: remaining
        )
        guard result.status == 0 else {
            throw RemoteConnectionError.commandFailed(
                status: result.status, message: String(decoding: result.stderr, as: UTF8.self)
            )
        }
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
        // After `git rm --cached`, Git reports both staged deletion and
        // untracked content at the same path. Those belong to different
        // sections; keep each while deduplicating within its own section.
        var parsedPaths: Set<String> = []
        func addEntry(_ entry: Entry) {
            let key = entry.path + "\0" + (entry.staged == "?" ? "untracked" : "tracked")
            guard parsedPaths.insert(key).inserted else { return }
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

    private nonisolated static func untrackedLineAdditions(
        for entries: [Entry], in root: String, backend: WorkspaceBackend, deadline: Date
    ) async throws -> (lines: Int, complete: Bool) {
        let maximumFiles = 2_048
        let maximumFileBytes = 8 * 1_024 * 1_024
        var remainingBytes = 32 * 1_024 * 1_024
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let untracked = entries.filter { $0.staged == "?" }
        let paths = untracked.prefix(maximumFiles).compactMap { entry -> URL? in
            let url = rootURL.appendingPathComponent(entry.path).standardizedFileURL
            return url.path.hasPrefix(rootPrefix) ? url : nil
        }
        var complete = paths.count == untracked.count
        guard !paths.isEmpty else { return (0, complete) }
        if !(backend is LocalWorkspaceBackend) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw WorkspaceError.timedOut }
            let result = try await backend.run(
                argv: ["sh", "-c", RemoteCommands.untrackedLineCountsCommand(
                    totalByteBudget: remainingBytes, perFileByteCap: maximumFileBytes)],
                cwd: root, env: nil,
                stdin: RemoteCommands.untrackedLineCountsInput(paths: paths.map(\.path)),
                timeout: remaining
            )
            guard result.status == 0,
                  let output = String(data: result.stdout, encoding: .utf8),
                  let counts = RemoteCommands.parseUntrackedLineCounts(
                    output, maximumFiles: paths.count, totalByteBudget: remainingBytes,
                    perFileByteCap: maximumFileBytes
                  ) else {
                throw RemoteConnectionError.commandFailed(status: result.status,
                    message: String(localized: "Unable to read Git status.", table: "Git"))
            }
            complete = complete && counts.count == paths.count && counts.allSatisfy(\.complete)
            return (counts.reduce(0) { $0 + $1.lines }, complete)
        }
        var total = 0
        for url in paths {
            guard deadline.timeIntervalSinceNow > 0 else { throw WorkspaceError.timedOut }
            guard remainingBytes > 0 else { return (total, false) }
            let count = try textLineCount(
                at: url, maximumBytes: min(maximumFileBytes, remainingBytes), deadline: deadline
            )
            total += count.lines
            remainingBytes -= count.bytesRead
            complete = complete && count.complete
        }
        return (total, complete)
    }

    nonisolated static func textLineCount(
        at url: URL, maximumBytes: Int, deadline: Date
    ) throws -> (lines: Int, bytesRead: Int, complete: Bool) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { return (1, 0, true) }
        guard values.isRegularFile == true,
              let fileSize = values.fileSize, fileSize <= maximumBytes else { return (0, 0, false) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let count = try countTextLines(maximumBytes: maximumBytes) { limit in
            guard deadline.timeIntervalSinceNow > 0 else { throw WorkspaceError.timedOut }
            return try handle.read(upToCount: limit)
        }
        if count.binary { return (0, count.bytesRead, true) }
        let complete = try handle.seekToEnd() == UInt64(count.bytesRead)
        return (complete ? count.lines : 0, count.bytesRead, complete)
    }

    nonisolated static func countTextLines(
        maximumBytes: Int, read: (Int) throws -> Data?
    ) throws -> (lines: Int, bytesRead: Int, binary: Bool) {
        guard maximumBytes > 0 else { return (0, 0, false) }
        let probe = try read(min(8_000, maximumBytes)) ?? Data()
        if probe.contains(0) { return (0, probe.count, true) }
        var bytesRead = probe.count
        var lines = probe.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        var lastByte = probe.last
        while bytesRead < maximumBytes {
            guard let chunk = try read(min(64 * 1_024, maximumBytes - bytesRead)),
                  !chunk.isEmpty else { break }
            bytesRead += chunk.count
            lines += chunk.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            lastByte = chunk.last
        }
        return (lines + (lastByte == nil || lastByte == 10 ? 0 : 1), bytesRead, false)
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
            "--date-order", "--diff-merges=first-parent", "--decorate=full",
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
                references: parseCommitReferences(String(fields[6])).map { reference in
                    guard reference.kind == .remoteBranch,
                          refsByName["refs/remotes/" + reference.name]?.symbolic != nil else {
                        return reference
                    }
                    return .init(kind: .remoteAlias, name: reference.name)
                },
                files: files
            )
        }
    }

    nonisolated static func detectRepositoryOperation(
        gitDirectory: String, backend: WorkspaceBackend, deadline: Date? = nil
    ) async throws -> String? {
        let git = URL(fileURLWithPath: gitDirectory, isDirectory: true)
        if !(backend is LocalWorkspaceBackend) {
            return try await remoteRepositoryOperation(gitDirectory: gitDirectory, backend: backend, deadline: deadline)
        }
        func exists(_ name: String) async throws -> Bool {
            if let deadline, deadline.timeIntervalSinceNow <= 0 { throw WorkspaceError.timedOut }
            let path = git.appendingPathComponent(name).path
            return try await backend.stat(path: path) != nil
        }

        let merging = try await exists("rebase-merge")
        let applying = try await exists("rebase-apply")
        if merging || applying {
            return String(localized: "Rebase in progress", table: "Git")
        }
        if try await exists("MERGE_HEAD") {
            return String(localized: "Merge in progress", table: "Git")
        }
        if try await exists("CHERRY_PICK_HEAD") {
            return String(localized: "Cherry-pick in progress", table: "Git")
        }
        if try await exists("REVERT_HEAD") {
            return String(localized: "Revert in progress", table: "Git")
        }
        if try await exists("BISECT_LOG") {
            return String(localized: "Bisect in progress", table: "Git")
        }
        return nil
    }
}
