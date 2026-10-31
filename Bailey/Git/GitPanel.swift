import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Git panel

struct GitPanel: View {
    var settings: AppSettings = .shared
    private let themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme

    private var themeAccent: Color {
        Color(nsColor: Theme.terminal(dark: colorScheme == .dark).accentNSColor)
    }

    private func statusColor(_ slot: Int) -> Color {
        let theme = Theme.terminal(dark: colorScheme == .dark)
        return Color(nsColor: theme.paletteNSColor(slot) ?? theme.foregroundNSColor)
    }

    private enum EntryOperation: Equatable {
        case stage
        case unstage
        case discard
    }

    private enum OperationTrigger: Equatable {
        case branchMenu
        case moreMenu
        case primaryAction
        case commitMenu
        case syncButton
        case stageAll
        case unstageAll
        case discardAll
        case entry(path: String, operation: EntryOperation)
        case initializeRepository
    }

    let model: GitStatusModel
    let manager: WorkspaceWindowModel
    let project: Project?
    let session: TerminalSession?
    let sshHost: String?
    let openFile: (String) -> Void
    let openDiff: (_ entry: GitStatusModel.Entry, _ staged: Bool) -> Void
    let openCommitDiff: (
        _ commit: GitStatusModel.RecentCommit,
        _ file: GitStatusModel.RecentCommit.FileChange
    ) -> Void

    private var commitMessage: String { model.commitMessage }
    private var commitMessageBinding: Binding<String> {
        Binding(get: { model.commitMessage }, set: { model.commitMessage = $0 })
    }
    @FocusState private var isCommitFieldFocused: Bool
    @State private var pendingDiscard: GitStatusModel.PendingDiscard?
    @State private var pendingDiscardAll: [GitStatusModel.PendingDiscard] = []
    @State private var pendingDiscardAllTrigger: OperationTrigger = .discardAll
    @State private var preparingDiscard = false
    @State private var confirmDiscardAll = false
    @State private var mergeCollapsed = false
    @State private var stagedCollapsed = false
    @State private var changesCollapsed = false
    private var collapsedFolders: Set<String> { model.collapsedFolders }
    private var collapsedFoldersBinding: Binding<Set<String>> {
        Binding(
            get: { model.collapsedFolders },
            set: { model.collapsedFolders = $0 }
        )
    }
    @State private var historyCollapsed = false
    @State private var remoteURLs: [String: String] = [:]
    private var remoteLookupID: String {
        [model.currentScope, model.repoRoot, model.remotes.joined(separator: ","),
         String(model.canUseCurrentReferences)].joined(separator: "\u{0}")
    }
    private var expandedCommitIDsBinding: Binding<Set<String>> {
        Binding(
            get: { model.expandedCommitIDs },
            set: { model.expandedCommitIDs = $0 }
        )
    }
    @State private var filterText = ""
    @State private var showFilter = false
    @State private var keyboardOwner = TreeKeyboardOwner()
    @State private var graphKeyboardOwner = TreeKeyboardOwner()
    @State private var lastKeyboardRegion: KeyboardRegion = .changes
    @State private var keyboardFocused = false
    private var selectedChange: ChangeSelection? {
        get { model.changeCursor }
        nonmutating set { model.changeCursor = newValue }
    }
    @State private var contextChange: ChangeSelection?
    @State private var waitingForChanges = false
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var operationExpanded = false
    @State private var operationTrigger: OperationTrigger?
    @Environment(\.panelFontScale) private var panelFontScale

    private enum KeyboardRegion { case changes, graph }

    private typealias ChangeSelection = GitStatusModel.ChangeSelection

    private struct VisibleChange {
        let kind: GitEntryRow.Kind
        let row: TreeDisplayModel.Row
        let entry: GitStatusModel.Entry?
    }

    private var isGitActive: Bool {
        guard let project, manager.selectedProject === project,
              let group = project.dock.group(containing: .git) else { return false }
        return project.dock.activeGroupID == group.id && group.selected == .git
    }

    private func selection(for row: VisibleChange) -> ChangeSelection {
        ChangeSelection(scope: model.currentScope, repository: model.repoRoot,
                        section: row.kind.rawValue, path: row.row.path)
    }

    private var hasCurrentPanelTarget: Bool {
        guard let project, manager.selectedProject === project,
              let context = project.panelContext else { return false }
        return model.matchesPanelTarget(context.identity)
    }

    private var displayedDiff: DiffTab? {
        guard let project, case .diff(let diff)? = project.selectedTab?.content,
              diff.workspaceIdentity == project.workspaceIdentity else { return nil }
        return diff
    }

    var body: some View {
        let _ = themeChanges.revision
        VStack(spacing: 0) {
            header.disabled(!hasCurrentPanelTarget)
            operationFailureBanner.disabled(!hasCurrentPanelTarget)

            if !hasCurrentPanelTarget {
                // Never display another project's tree while its Git root is
                // still resolving. Keep the retry actionable after failures.
                if let statusError = model.statusError {
                    statusFailure(statusError)
                } else {
                    placeholder(icon: "arrow.clockwise", text: String(localized: "Finding repository…", table: "Sidebar"))
                }
            } else {
                Group {
                    if !model.isRepo {
                        if let statusError = model.statusError {
                            statusFailure(statusError)
                        } else if model.isResolvingInitialStatus || model.needsCoreVerification {
                            placeholder(icon: "arrow.clockwise", text: String(localized: "Finding repository…", table: "Sidebar"))
                        } else {
                            notRepository
                        }
                    } else {
                        if let statusError = model.statusError {
                            statusWarning(statusError)
                        } else if let detailError = model.detailError {
                            statusWarning(detailError, isDetail: true)
                        }
                        trackingBar
                        repositoryOperationBanner
                        commitBox
                        filterBar
                        changeList
                    }
                }
                .disabled(!hasCurrentPanelTarget)
            }
        }
        .confirmationDialog(
            discardTitle(for: pendingDiscard?.entry),
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(discardActionTitle(for: pendingDiscard?.entry),
                   role: .destructive) {
                if hasCurrentPanelTarget, let pendingDiscard {
                    let trigger = OperationTrigger.entry(
                        path: pendingDiscard.entry.path, operation: .discard
                    )
                    confirmReviewedDiscard([pendingDiscard], trigger: trigger)
                }
                pendingDiscard = nil
            }
            .disabled(model.isBusy || !hasCurrentPanelTarget || !model.canUseCurrentStatus)
        }
        .confirmationDialog(
            discardAllTitle,
            isPresented: Binding(
                get: { confirmDiscardAll },
                set: {
                    confirmDiscardAll = $0
                    if !$0 {
                        pendingDiscardAll = []
                        pendingDiscardAllTrigger = .discardAll
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingDiscardAllTrigger == .discardAll
                   ? String(localized: "Discard All Changes", table: "Sidebar")
                   : String(localized: "Discard Changes", table: "Sidebar"), role: .destructive) {
                guard hasCurrentPanelTarget else {
                    pendingDiscardAll = []
                    confirmDiscardAll = false
                    return
                }
                let snapshot = pendingDiscardAll
                let trigger = pendingDiscardAllTrigger
                confirmReviewedDiscard(snapshot, trigger: trigger)
                pendingDiscardAll = []
                confirmDiscardAll = false
            }
            .disabled(model.isBusy || !hasCurrentPanelTarget || !model.canUseCurrentStatus)
        }
        .onChange(of: model.rootPath) {
            // A dialog must never carry a destructive file target across cwd.
            pendingDiscard = nil
            pendingDiscardAll = []
            pendingDiscardAllTrigger = .discardAll
            confirmDiscardAll = false
        }
        .onChange(of: model.repositoryIdentity) {
            resetRepositoryDrafts()
        }
        .onChange(of: model.currentScope) {
            pendingDiscard = nil
            pendingDiscardAll = []
            pendingDiscardAllTrigger = .discardAll
            confirmDiscardAll = false
        }
        .onChange(of: model.isBusy) {
            if !model.isBusy { operationTrigger = nil }
        }
        .task(id: remoteLookupID) {
            remoteURLs = [:]
            remoteURLs = await model.remoteURLs()
        }
        .tint(themeAccent)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if model.isRepo {
                branchMenu.disabled(!model.canUseCurrentStatus)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .panelFont(size: 11, weight: .medium)
                    .foregroundStyle(themeAccent)
                PanelHeader(title: String(localized: "Git Manager", table: "Sidebar"), subtitle: model.rootPath)
            }
            // User operations surface progress in their initiating control.
            // Keep repository discovery here because it has no trigger button.
            if model.isResolvingInitialStatus || model.needsCoreVerification {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel(String(localized: "Refreshing Git status", table: "Sidebar"))
            }
            if preparingDiscard {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Verifying remote files", table: "Sidebar"))
            }
            if model.isRepo {
                headerButton(
                    "line.3.horizontal.decrease",
                    help: String(localized: "Filter Changed Files", table: "Sidebar"),
                    disabled: false
                ) {
                    showFilter.toggle()
                    if !showFilter { filterText = "" }
                }
                headerButton(
                    "arrow.clockwise",
                    help: String(localized: "Refresh Git Status", table: "Sidebar"),
                    disabled: model.isBusy || model.isResolvingInitialStatus
                ) {
                    model.refresh()
                }
                moreMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var branchMenu: some View {
        Menu {
            if !model.branches.isEmpty {
                ForEach(model.branches, id: \.self) { branch in
                    let expectedOID = model.refsByName["refs/heads/" + branch]?.oid
                    Button {
                        switchBranchSafely(to: branch, expectedOID: expectedOID)
                    } label: {
                        if branch == model.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                    .disabled(branch == model.branch || model.isBusy)
                }
                Divider()
            }
            Button(String(localized: "Create New Branch…", table: "Sidebar")) {
                presentCreateBranchDialog()
            }
            .disabled(model.isBusy)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Image(systemName: "arrow.triangle.branch")
                        .panelFont(size: 11, weight: .medium)
                        .foregroundStyle(themeAccent)
                        .opacity(operationIsLoading(.branchMenu) ? 0 : 1)
                    if operationIsLoading(.branchMenu) {
                        operationProgressView()
                    }
                }
                PanelHeader(
                    title: model.branch ?? String(localized: "Detached HEAD", table: "Sidebar"),
                    subtitle: model.rootPath
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Switch or Create Branch", table: "Sidebar"))
        .disabled(!model.canUseCurrentReferences)
        .accessibilityLabel(
            String(localized: "Current branch, \(model.branch ?? String(localized: "detached HEAD", table: "Sidebar"))", table: "Sidebar")
        )
    }

    private var moreMenu: some View {
        Menu {
            Button(String(localized: "Fetch", table: "Sidebar")) {
                performOperation(.moreMenu, model.fetch)
            }
                .disabled(model.isBusy || !model.canUseCurrentReferences || model.remotes.isEmpty)
            Button(String(localized: "Pull (Fast-forward Only)", table: "Sidebar")) { performOperation(.moreMenu, model.pull) }
                .disabled(model.isBusy || !model.canUseCurrentReferences || !model.hasUpstream)
            if model.hasUpstream {
                Button(String(localized: "Push", table: "Sidebar")) { performOperation(.moreMenu, model.push) }
                    .disabled(model.isBusy || !model.canUseCurrentReferences)
            } else if model.remotes.count > 1 {
                Menu(String(localized: "Publish Branch to", table: "Sidebar")) {
                    ForEach(model.remotes, id: \.self) { remote in
                        Button(remote) {
                            performOperation(.moreMenu) { model.publish(to: remote) }
                        }
                    }
                }
                .disabled(model.isBusy || !model.canUseCurrentReferences || model.branch == "detached HEAD")
            } else {
                Button(String(localized: "Publish Branch", table: "Sidebar")) { performOperation(.moreMenu, model.push) }
                    .disabled(model.isBusy || !model.canUseCurrentReferences
                    || model.remotes.isEmpty || model.branch == "detached HEAD")
            }
            Button(String(localized: "Sync Changes", table: "Sidebar")) { performOperation(.moreMenu, model.syncChanges) }
                .disabled(
                    model.isBusy || !model.canUseCurrentReferences || model.remotes.isEmpty
                        || (!model.hasUpstream && model.remotes.count != 1)
                        || model.branch == "detached HEAD"
                )
            Divider()
            ForEach(uncommittedMenuActions) { action in
                Button(action.title, action: action.perform).disabled(action.disabled)
            }
            if let latest = model.stashes.first {
                Button(String(localized: "Pop Latest Stash…", table: "Git")) {
                    presentStashDialog(latest, action: .pop)
                }.disabled(model.isBusy || !model.canUseCurrentStashes)
            }
            Divider()
            Button(String(localized: "Copy Changed Paths", table: "Sidebar")) { copyChangedPaths() }
                .disabled(model.totalChangeCount == 0)
            Button(String(localized: "Copy Repository Path", table: "Sidebar")) { copyToPasteboard(model.repoRoot) }
            Divider()
            if !model.remotes.isEmpty {
                Menu(String(localized: "Open Remote in Browser", table: "Git")) {
                    ForEach(model.remotes, id: \.self) { remote in
                        let link = remoteURLs[remote].flatMap {
                            GitHostedRemoteURL(remoteURL: $0,
                                               hostProviders: settings.gitHostProviders)
                        }
                        Button(link.map { "\($0.provider.title) · \(remote)" } ?? remote) {
                            model.openInBrowser(remote: remote, hostProviders: settings.gitHostProviders)
                        }
                    }
                }
            }
            // Finder can only show a path on this Mac.
            if remoteName == nil {
                Button(String(localized: "Reveal Repository in Finder", table: "Sidebar")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.repoRoot)])
                }
            }
        } label: {
            ZStack {
                Image(systemName: "ellipsis")
                    .panelFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .opacity(operationIsLoading(.moreMenu) ? 0 : 1)
                if operationIsLoading(.moreMenu) {
                    operationProgressView()
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(String(localized: "More Actions…", table: "Sidebar"))
        .disabled(!model.canUseCurrentStatus)
        .accessibilityLabel(String(localized: "More Git Actions", table: "Sidebar"))
        .accessibilityIdentifier("bailey.git.more-actions")
    }

    private func headerButton(
        _ systemImage: String, help: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .panelFont(size: 10, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var trackingBar: some View {
        if let branch = model.branch {
            HStack(spacing: 5) {
                Image(systemName: model.hasUpstream ? "arrow.triangle.2.circlepath" : "icloud.slash")
                    .panelFont(size: 9, weight: .medium)
                    .foregroundStyle(.secondary)
                Text(verbatim: model.upstream ?? (branch == "detached HEAD"
                    ? String(localized: "Detached HEAD", table: "Sidebar")
                    : String(localized: "Unpublished branch", table: "Sidebar")))
                    .panelFont(size: 9.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if model.behind > 0 {
                    badge(
                        "↓\(model.behind)",
                        label: String(localized: "\(model.behind) incoming commits", table: "Sidebar")
                    )
                }
                if model.ahead > 0 {
                    badge(
                        "↑\(model.ahead)",
                        label: String(localized: "\(model.ahead) outgoing commits", table: "Sidebar")
                    )
                }
            }
            .frame(height: 17)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Repository and operation state

    @ViewBuilder
    private var repositoryOperationBanner: some View {
        if let current = model.repositoryOperation {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.merge")
                    .panelFont(size: 10, weight: .semibold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: current)
                        .panelFont(size: 10.5, weight: .medium)
                    Text(model.mergeEntries.isEmpty
                         ? String(localized: "Finish or abort from the terminal", table: "Sidebar")
                         : String(
                            localized: "Resolve and stage \(model.mergeEntries.count) conflicted files", table: "Sidebar",
                            comment: "Git merge guidance. The placeholder is the number of conflicted files."
                         ))
                        .panelFont(size: 9.5)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(statusColor(5))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(statusColor(5).opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var operationFailureBanner: some View {
        if let operation = model.operation,
           case .failed = operation.state {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .panelFont(size: 10)
                    Text(operation.statusLabel)
                        .panelFont(size: 10.5, weight: .medium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !operation.output.isEmpty {
                        Button {
                            operationExpanded.toggle()
                        } label: {
                            Image(systemName: "chevron.right")
                                .panelFont(size: 8, weight: .semibold)
                                .rotationEffect(.degrees(operationExpanded ? 90 : 0))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(
                            operationExpanded
                                ? String(localized: "Hide Git Output", table: "Sidebar")
                                : String(localized: "Show Git Output", table: "Sidebar")
                        )
                        .accessibilityLabel(
                            operationExpanded
                                ? String(localized: "Hide Git Output", table: "Sidebar")
                                : String(localized: "Show Git Output", table: "Sidebar")
                        )
                    }
                    Button {
                        operationExpanded = false
                        model.dismissOperation()
                    } label: {
                        Image(systemName: "xmark")
                            .panelFont(size: 8, weight: .semibold)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Dismiss", table: "Sidebar"))
                    .accessibilityLabel(String(localized: "Dismiss Git Error", table: "Sidebar"))
                }
                if operationExpanded, !operation.output.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: operation.output)
                            .panelFont(size: 9, design: .monospaced)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .frame(maxHeight: 96)
                    .accessibilityLabel(String(localized: "Git Output", table: "Sidebar"))
                }
            }
            .foregroundStyle(statusColor(1))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(statusColor(1).opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
        }
    }

    private func switchBranchSafely(to name: String, expectedOID: String?) {
        guard let project, let expectedOID else { return }
        performOperation(.branchMenu) {
            manager.switchGitBranch(to: name, expectedOID: expectedOID,
                                    in: project, model: model)
        }
    }

    private func presentCreateBranchDialog() {
        presentBranchCreate(at: nil, initialCheckout: true)
    }

    func presentBranchCreate(
        at commit: GitStatusModel.RecentCommit?, initialName: String = "",
        initialCheckout: Bool
    ) {
        guard let window = manager.attachedWindow, let project,
              manager.selectedProject === project, let context = project.panelContext,
              model.matchesPanelTarget(context.identity), !model.isBusy else { return }
        let target = model.actionTarget()
        let detail = commit.map {
            String(localized: "Repository \(target.scope): \(target.repository)\nCommit \($0.shortHash): \($0.subject)", table: "Git")
        } ?? String(localized: "Enter a name for the new branch.", table: "Sidebar")
        let dialog = GitBranchDialog(kind: .create(checkout: initialCheckout),
            title: commit == nil ? String(localized: "Create New Branch", table: "Sidebar")
                : String(localized: "Create Branch at Commit", table: "Git"),
            detail: detail, initialName: initialName)
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity)
                && model.isCurrent(target, requiresStableHead: dialog.checkout.state == .on)
        }
        dialog.alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, isCurrent() else { return }
            let name = dialog.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let checkout = dialog.checkout.state == .on
            let run: @MainActor () -> Void = {
                performOperation(.branchMenu) {
                    model.createBranch(named: name, at: commit?.hash,
                        checkout: checkout, replacing: nil, target: target,
                        prepare: {
                            if !checkout { return true }
                            return await manager.application.saveBeforeGitAction(repository: target.repository,
                                scope: target.scope, isCurrent: isCurrent)
                        }, isCurrentTarget: {
                            isCurrent() && (!checkout || manager.application.canRunGitAction(
                                repository: target.repository, scope: target.scope))
                        }) { success in
                        if success, checkout {
                            manager.application.reloadAfterGitAction(repository: target.repository, scope: target.scope)
                        }
                        if !success,
                           model.operation?.gitError?.localizedCaseInsensitiveContains("already exists") == true,
                           isCurrent() {
                            presentBranchReplacement(name: name, checkout: checkout,
                                commit: commit, target: target, window: window,
                                isCurrent: isCurrent)
                        }
                    }
                }
            }
            if model.refsByName["refs/heads/" + name] != nil {
                presentBranchReplacement(name: name, checkout: checkout,
                    commit: commit, target: target, window: window, isCurrent: isCurrent)
            } else {
                run()
            }
        }
    }

    private func presentBranchReplacement(
        name: String, checkout: Bool, commit: GitStatusModel.RecentCommit?,
        target: GitStatusModel.ActionTarget, window: NSWindow,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        guard isCurrent() else { return }
        Task { @MainActor in
            guard let oid = await model.referenceOID(named: "refs/heads/" + name, target: target),
                  isCurrent() else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Branch already exists", table: "Git")
            alert.informativeText = name
            alert.addButton(withTitle: String(localized: "Replace Existing Branch", table: "Git"))
            alert.addButton(withTitle: String(localized: "Choose Another Name", table: "Git"))
            alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
            alert.beginSheetModal(for: window) { answer in
                guard isCurrent() else { return }
                switch answer {
                case .alertFirstButtonReturn:
                    performOperation(.branchMenu) {
                        model.createBranch(named: name, at: commit?.hash,
                            checkout: checkout, replacing: oid, target: target,
                            prepare: {
                                if !checkout { return true }
                                return await manager.application.saveBeforeGitAction(repository: target.repository,
                                    scope: target.scope, isCurrent: isCurrent)
                            }, isCurrentTarget: {
                                isCurrent() && (!checkout || manager.application.canRunGitAction(
                                    repository: target.repository, scope: target.scope))
                            }, completion: { success in
                                if success, checkout {
                                    manager.application.reloadAfterGitAction(repository: target.repository, scope: target.scope)
                                }
                            })
                    }
                case .alertSecondButtonReturn:
                    presentBranchCreate(at: commit, initialName: name, initialCheckout: checkout)
                default: break
                }
            }
        }
    }

    func presentTagCreate(
        at commit: GitStatusModel.RecentCommit, initialName: String = "",
        initialType: GitStatusModel.TagType = .annotated,
        initialMessage: String = "", initialRemote: String? = nil
    ) {
        guard let window = manager.attachedWindow, let project,
              manager.selectedProject === project, let context = project.panelContext,
              model.matchesPanelTarget(context.identity), !model.isBusy else { return }
        let target = model.actionTarget()
        let dialog = GitTagDialog(kind: .create(remotes: model.remotes),
            title: String(localized: "Add Tag", table: "Git"),
            detail: String(localized:
                "Repository \(target.scope): \(target.repository)\nCommit \(commit.shortHash): \(commit.subject)",
                table: "Git"),
            initialName: initialName, initialType: initialType,
            initialMessage: initialMessage, initialRemote: initialRemote)
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity)
                && model.isCurrent(target, requiresStableHead: false)
                && model.recentCommits.contains(where: { $0.hash == commit.hash })
        }
        dialog.alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, isCurrent() else { return }
            let name = dialog.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = dialog.selectedType
            let message = dialog.message.string
            let remote = dialog.selectedCreateRemote
            let submit: @MainActor () -> Void = {
                performOperation(.branchMenu) {
                    model.createTag(named: name, at: commit.hash, type: type,
                        message: message, replacing: nil, target: target) { success in
                        guard isCurrent() else { return }
                        if success, let remote {
                            Task { @MainActor in
                                guard let oid = await model.tagOID(
                                    named: name, pointingAt: commit.hash, target: target
                                ), isCurrent() else { return }
                                presentTagPushWarning(name: name, commitOID: commit.hash,
                                    oid: oid, remotes: [remote], target: target,
                                    window: window, isCurrent: isCurrent)
                            }
                        } else if !success,
                                  model.operation?.gitError?.localizedCaseInsensitiveContains(
                                    "already exists") == true {
                            presentTagReplacement(name: name, type: type,
                                message: message, remote: remote, commit: commit,
                                target: target, window: window, isCurrent: isCurrent)
                        }
                    }
                }
            }
            if model.refsByName["refs/tags/" + name] != nil {
                presentTagReplacement(name: name, type: type, message: message,
                    remote: remote, commit: commit, target: target,
                    window: window, isCurrent: isCurrent)
            } else {
                submit()
            }
        }
    }

    private func presentTagReplacement(
        name: String, type: GitStatusModel.TagType, message: String,
        remote: String?, commit: GitStatusModel.RecentCommit,
        target: GitStatusModel.ActionTarget, window: NSWindow,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        guard isCurrent() else { return }
        Task { @MainActor in
            guard let previous = await model.referenceOID(named: "refs/tags/" + name, target: target),
                  isCurrent() else { return }
            let confirm = NSAlert()
            confirm.messageText = String(localized: "Tag already exists", table: "Git")
            confirm.informativeText = name
            confirm.addButton(withTitle: String(localized: "Replace Existing Tag", table: "Git"))
            confirm.addButton(withTitle: String(localized: "Choose Another Name", table: "Git"))
            confirm.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
            confirm.beginSheetModal(for: window) { answer in
                guard isCurrent() else { return }
                switch answer {
                case .alertFirstButtonReturn:
                    performOperation(.branchMenu) {
                        model.createTag(named: name, at: commit.hash, type: type,
                            message: message, replacing: previous, target: target) { success in
                            guard success, let remote, isCurrent() else { return }
                            Task { @MainActor in
                                guard let oid = await model.tagOID(
                                    named: name, pointingAt: commit.hash, target: target
                                ), isCurrent() else { return }
                                presentTagPushWarning(name: name, commitOID: commit.hash,
                                    oid: oid, remotes: [remote], target: target,
                                    window: window, isCurrent: isCurrent)
                            }
                        }
                    }
                case .alertSecondButtonReturn:
                    presentTagCreate(at: commit, initialName: name,
                        initialType: type, initialMessage: message, initialRemote: remote)
                default: break
                }
            }
        }
    }

    private func presentBranchAction(
        _ reference: GitStatusModel.RecentCommit.Reference,
        commit: GitStatusModel.RecentCommit,
        action: RecentCommitsView.BranchAction
    ) {
        guard reference.kind == .currentBranch || reference.kind == .localBranch,
              let window = manager.attachedWindow, let project,
              manager.selectedProject === project, let context = project.panelContext,
              model.matchesPanelTarget(context.identity), !model.isBusy,
              model.refsByName["refs/heads/" + reference.name]?.oid == commit.hash else { return }
        let target = model.actionTarget()
        let name = reference.name
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity)
                && model.isCurrent(target, requiresStableHead: false)
                && model.refsByName["refs/heads/" + name]?.oid == commit.hash
        }
        switch action {
        case .createWorktree:
            guard model.canCreateWorktree(for: name) else { return }
            let parent = (target.repository as NSString).deletingLastPathComponent
            let basename = (target.repository as NSString).lastPathComponent
            let suggested = (parent as NSString).appendingPathComponent(
                basename + "-" + name.replacingOccurrences(of: "/", with: "-")
            )
            let dialog = NSAlert()
            dialog.messageText = String(localized: "Create Worktree…", table: "Git")
            dialog.informativeText = name
            let path = NSTextField(string: suggested)
            path.placeholderString = String(localized: "Absolute Worktree Directory", table: "Git")
            path.frame = NSRect(x: 0, y: 0, width: 410, height: 24)
            dialog.accessoryView = path
            dialog.window.initialFirstResponder = path
            dialog.addButton(withTitle: String(localized: "Create Worktree", table: "Git"))
            dialog.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
            dialog.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn, isCurrent(),
                      model.canCreateWorktree(for: name) else { return }
                performOperation(.branchMenu) {
                    model.createWorktree(
                        for: name, at: path.stringValue, expectedOID: commit.hash,
                        target: target, isCurrentTarget: isCurrent
                    )
                }
            }
        case .merge, .rebase:
            presentCommitDialog(commit, action: action == .merge ? .merge : .rebase,
                                selectedRefName: "refs/heads/" + name)
        case .rename:
            let dialog = GitBranchDialog(kind: .rename,
                title: String(localized: "Rename Branch…", table: "Git"),
                detail: name, initialName: name)
            dialog.alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn, isCurrent() else { return }
                performOperation(.branchMenu) {
                    model.renameBranch(from: name, to: dialog.name.stringValue, target: target)
                }
            }
        case .delete:
            let remotes = model.trackingRemotes(for: name)
            let dialog = GitBranchDialog(kind: .delete(remotes: remotes),
                title: String(localized: "Delete Branch…", table: "Git"), detail: name)
            dialog.alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn, isCurrent() else { return }
                let remoteNames = dialog.deleteRemotes.state == .on ? remotes : []
                let force = dialog.forceDelete.state == .on
                performOperation(.branchMenu) {
                    model.deleteBranch(name, force: force, remoteNames: remoteNames, target: target) { success in
                        guard !success, !force, isCurrent(),
                              model.operation?.gitError?.localizedCaseInsensitiveContains("not fully merged") == true else { return }
                        let confirm = NSAlert()
                        confirm.messageText = String(localized: "Branch is not fully merged", table: "Git")
                        confirm.informativeText = name
                        confirm.addButton(withTitle: String(localized: "Yes, Force Delete Branch", table: "Git"))
                        confirm.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
                        confirm.beginSheetModal(for: window) { answer in
                            guard answer == .alertFirstButtonReturn, isCurrent() else { return }
                            performOperation(.branchMenu) {
                                model.deleteBranch(name, force: true, remoteNames: remoteNames, target: target)
                            }
                        }
                    }
                }
            }
        case .push:
            Task { @MainActor in
                let preferred = await model.preferredPushRemote(for: name)
                guard isCurrent() else { return }
                let dialog = GitBranchDialog(kind: .push(remotes: model.remotes, preferred: preferred),
                    title: String(localized: "Push Branch…", table: "Git"), detail: name)
                dialog.alert.beginSheetModal(for: window) { response in
                    guard response == .alertFirstButtonReturn, isCurrent() else { return }
                    performOperation(.branchMenu) {
                        model.pushBranch(name, remotes: dialog.selectedRemotes,
                            setUpstream: dialog.setUpstream.state == .on,
                            mode: dialog.selectedPushMode, target: target)
                    }
                }
            }
        case .archive:
            presentArchiveDialog(reference: "refs/heads/" + name,
                                 objectOID: commit.hash, target: target,
                                 context: context, window: window, isCurrent: isCurrent)
        }
    }

    private func presentWorktreeAction(
        _ location: GitStatusModel.WorktreeLocation,
        action: RecentCommitsView.WorktreeAction
    ) {
        guard let window = manager.attachedWindow, let project,
              manager.selectedProject === project, let context = project.panelContext,
              model.matchesPanelTarget(context.identity), !model.isBusy,
              model.hasCurrentWorktrees, model.worktreeLocations.contains(location) else { return }
        let target = model.actionTarget()
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity)
                && model.isCurrent(target) && model.worktreeLocations.contains(location)
        }
        guard isCurrent() else { return }
        switch action {
        case .open:
            guard !location.isPrunable else { return }
            if context.isRemote {
                guard target.scope.hasPrefix("ssh:") else { return }
                let host = String(target.scope.dropFirst(4))
                Task { @MainActor in
                    do {
                        try await manager.addSSHItems(
                            host: host, paths: [location.path], isCurrentTarget: isCurrent
                        )
                    } catch {
                        if isCurrent() { WorkspaceNativeDialogs.showError(error, in: window) }
                    }
                }
            } else {
                manager.addLocalFolders([URL(fileURLWithPath: location.path, isDirectory: true)])
            }
        case .revealInFinder:
            guard !context.isRemote, !location.isPrunable else { return }
            NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: location.path, isDirectory: true)
            ])
        case .remove:
            guard !location.isMain, !location.isLocked, !location.isPrunable else { return }
            guard !manager.application.isWorktreeInUse(path: location.path, scope: target.scope) else {
                let warning = NSAlert()
                warning.messageText = String(localized: "Worktree is in use", table: "Git")
                warning.informativeText = String(
                    localized: "Close the Worktree's projects, editors and terminals before removing it.",
                    table: "Git"
                )
                warning.addButton(withTitle: String(localized: "OK", table: "Sidebar"))
                warning.beginSheetModal(for: window)
                return
            }
            let dialog = NSAlert()
            dialog.messageText = String(localized: "Remove Worktree…", table: "Git")
            dialog.informativeText = [
                location.path,
                location.branch ?? String(localized: "Detached HEAD", table: "Git"),
                String(localized: "Only clean Worktrees can be removed. The branch is preserved.", table: "Git")
            ].joined(separator: "\n")
            dialog.addButton(withTitle: String(localized: "Remove Worktree", table: "Git"))
            dialog.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
            dialog.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn, isCurrent() else { return }
                performOperation(.moreMenu) {
                    model.removeWorktree(location, target: target, isCurrentTarget: {
                        isCurrent() && !manager.application.isWorktreeInUse(
                            path: location.path, scope: target.scope
                        )
                    })
                }
            }
        }
    }

    func presentRemoteBranchAction(
        _ reference: GitStatusModel.RecentCommit.Reference,
        commit: GitStatusModel.RecentCommit,
        action: RecentCommitsView.RemoteAction
    ) {
        guard reference.kind == .remoteBranch,
              let window = manager.attachedWindow, let project,
              manager.selectedProject === project, let context = project.panelContext,
              model.matchesPanelTarget(context.identity), !model.isBusy,
              let selected = model.remoteBranch(named: reference.name),
              selected.oid == commit.hash else { return }
        let target = model.actionTarget()
        let referenceName = "refs/remotes/" + reference.name
        let stillSelected: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity)
                && model.isCurrent(target, requiresStableHead: false)
                && model.refsByName[referenceName]?.oid == selected.oid
                && model.remoteBranch(named: reference.name)?.remote == selected.remote
        }
        let saveBeforeChangingWorktree: @MainActor () async -> Bool = {
            await manager.application.saveBeforeGitAction(
                repository: target.repository, scope: target.scope, isCurrent: stillSelected
            )
        }
        let canMutateWorktree: @MainActor () -> Bool = {
            stillSelected() && manager.application.canRunGitAction(
                repository: target.repository, scope: target.scope
            )
        }
        let onFinish: @MainActor (Bool) -> Void = { _ in
            manager.application.reloadAfterGitAction(repository: target.repository, scope: target.scope)
        }

        switch action {
        case .checkout:
            presentRemoteCheckoutDialog(
                selected, localName: selected.branch, window: window,
                target: target, isCurrent: stillSelected,
                prepare: saveBeforeChangingWorktree,
                canMutate: canMutateWorktree, completion: onFinish
            )
        case .fetch:
            guard let destinationOID = model.refsByName["refs/heads/" + selected.branch]?.oid,
                  model.branch != selected.branch else { return }
            let dialog = GitBranchDialog(kind: .remoteFetch,
                title: String(localized: "Fetch into Local Branch…", table: "Git"),
                detail: reference.name)
            dialog.alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn, stillSelected() else { return }
                performOperation(.branchMenu) {
                    model.fetchIntoLocalBranch(
                        selected, force: dialog.forceFetch.state == .on,
                        destinationOID: destinationOID, target: target
                    )
                }
            }
        case .merge:
            presentCommitDialog(commit, action: .merge, selectedRefName: referenceName)
        case .pull:
            let dialog = GitBranchDialog(kind: .remotePull,
                title: String(localized: "Pull into Current Branch…", table: "Git"),
                detail: reference.name)
            dialog.alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn, stillSelected() else { return }
                performOperation(.branchMenu) {
                    model.pullRemoteBranch(selected,
                        noFastForward: dialog.noFastForward.state == .on,
                        squash: dialog.squash.state == .on, target: target,
                        prepare: saveBeforeChangingWorktree,
                        isCurrentTarget: canMutateWorktree, completion: onFinish
                    )
                }
            }
        case .delete:
            let alert = NSAlert()
            alert.messageText = String(localized: "Delete Remote Branch…", table: "Git")
            alert.informativeText = selected.remote + " / " + selected.branch
            alert.addButton(withTitle: String(localized: "Yes, Delete", table: "Git"))
            alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn, stillSelected() else { return }
                performOperation(.branchMenu) {
                    model.deleteRemoteBranch(selected, target: target)
                }
            }
        case .archive:
            presentArchiveDialog(reference: referenceName, objectOID: selected.oid,
                                 target: target, context: context, window: window,
                                 isCurrent: stillSelected)
        }
    }

    private func presentRemoteCheckoutDialog(
        _ selected: GitStatusModel.RemoteBranchTarget, localName: String,
        window: NSWindow, target: GitStatusModel.ActionTarget,
        isCurrent: @escaping @MainActor () -> Bool,
        prepare: @escaping @MainActor () async -> Bool,
        canMutate: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard isCurrent(), !model.isBusy else { return }
        let dialog = GitBranchDialog(kind: .remoteCheckout,
            title: String(localized: "Checkout Remote Branch…", table: "Git"),
            detail: selected.remote + " / " + selected.branch,
            initialName: localName)
        dialog.alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, isCurrent() else { return }
            let name = dialog.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let performCheckout: @MainActor (Bool) -> Void = { useExisting in
                performOperation(.branchMenu) {
                    model.checkoutRemoteBranch(selected, localName: name,
                        checkoutExistingAndPull: useExisting, target: target,
                        prepare: prepare, isCurrentTarget: canMutate,
                        completion: completion
                    )
                }
            }
            if model.refsByName["refs/heads/" + name] == nil {
                performCheckout(false)
                return
            }
            let existing = NSAlert()
            existing.messageText = String(localized: "Branch already exists", table: "Git")
            existing.informativeText = name
            existing.addButton(withTitle: String(localized: "Choose Another Name", table: "Git"))
            existing.addButton(withTitle: String(localized: "Checkout Existing Branch & Pull Changes", table: "Git"))
            existing.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
            existing.beginSheetModal(for: window) { choice in
                guard isCurrent() else { return }
                switch choice {
                case .alertFirstButtonReturn:
                    presentRemoteCheckoutDialog(
                        selected, localName: name, window: window, target: target,
                        isCurrent: isCurrent, prepare: prepare,
                        canMutate: canMutate, completion: completion
                    )
                case .alertSecondButtonReturn:
                    performCheckout(true)
                default: break
                }
            }
        }
    }

    func presentTagAction(
        _ reference: GitStatusModel.RecentCommit.Reference,
        commit: GitStatusModel.RecentCommit,
        action: RecentCommitsView.TagAction
    ) {
        guard reference.kind == .tag, let window = manager.attachedWindow,
              let project, manager.selectedProject === project,
              let context = project.panelContext, model.matchesPanelTarget(context.identity),
              !model.isBusy, let selected = model.refsByName["refs/tags/" + reference.name],
              reference.objectOID == selected.oid,
              model.recentCommits.contains(where: {
                  $0.hash == commit.hash && $0.references.contains(reference)
              })
        else { return }
        let name = reference.name
        let oid = selected.oid
        let target = model.actionTarget()
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity)
                && model.isCurrent(target, requiresStableHead: false)
                && model.refsByName["refs/tags/" + name]?.oid == oid
        }

        switch action {
        case .details:
            guard selected.objectType == "tag" else { return }
            Task { @MainActor in
                guard let details = await model.tagDetails(named: name, target: target),
                      isCurrent() else { return }
                let verification: String
                switch details.verification {
                case .unsigned: verification = String(localized: "Unsigned", table: "Git")
                case .valid: verification = String(localized: "Signature Verified", table: "Git")
                case .unverified: verification = String(localized: "Signature Unverified", table: "Git")
                }
                let alert = NSAlert()
                alert.messageText = String(localized: "Tag Details", table: "Git")
                alert.informativeText = name
                let body = [
                    String(localized: "Tag Object", table: "Git") + ": " + details.objectOID,
                    String(localized: "Commit", table: "Git") + ": " + details.commitOID,
                    String(localized: "Tagger", table: "Git") + ": " + details.tagger,
                    String(localized: "Signature", table: "Git") + ": " + verification,
                    "", details.message
                ].joined(separator: "\n")
                let text = NSTextView()
                text.isEditable = false
                text.isSelectable = true
                text.string = body
                text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                let scroll = NSScrollView()
                scroll.documentView = text
                scroll.hasVerticalScroller = true
                scroll.frame = NSRect(x: 0, y: 0, width: 480, height: 190)
                alert.accessoryView = scroll
                alert.addButton(withTitle: String(localized: "Close", table: "Sidebar"))
                alert.beginSheetModal(for: window) { _ in }
            }
        case .delete:
            let dialog = GitTagDialog(kind: .delete(remotes: model.remotes),
                title: String(localized: "Delete Tag…", table: "Git"), detail: name)
            dialog.alert.beginSheetModal(for: window) { answer in
                guard answer == .alertFirstButtonReturn, isCurrent() else { return }
                performOperation(.branchMenu) {
                    model.deleteTag(name, fromRemote: dialog.selectedDeleteRemote, target: target)
                }
            }
        case .push:
            Task { @MainActor in
                let preferred = await model.preferredPushRemote(for: nil)
                guard isCurrent() else { return }
                let dialog = GitTagDialog(kind: .push(remotes: model.remotes, preferred: preferred),
                    title: String(localized: "Push Tag…", table: "Git"), detail: name)
                dialog.alert.beginSheetModal(for: window) { answer in
                    guard answer == .alertFirstButtonReturn, isCurrent() else { return }
                    presentTagPushWarning(name: name, commitOID: commit.hash, oid: oid,
                        remotes: dialog.selectedPushRemotes, target: target,
                        window: window, isCurrent: isCurrent)
                }
            }
        case .archive:
            presentArchiveDialog(reference: "refs/tags/" + name, objectOID: oid,
                target: target, context: context, window: window, isCurrent: isCurrent)
        }
    }

    private func presentTagPushWarning(
        name: String, commitOID: String, oid: String, remotes: [String],
        target: GitStatusModel.ActionTarget, window: NSWindow,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        guard !remotes.isEmpty, isCurrent() else { return }
        let push: @MainActor () -> Void = {
            guard isCurrent() else { return }
            performOperation(.branchMenu) {
                model.pushTag(name, to: remotes, target: target, selectedOID: oid)
            }
        }
        Task { @MainActor in
            let unknown = await model.tagRemotesWithoutCommit(
                commitOID, selected: remotes, target: target)
            guard isCurrent(), let unknown else { return }
            guard !settings.gitAlwaysProceedPushTag, !unknown.isEmpty else {
                push()
                return
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "Tag Commit May Not Be on the Remote", table: "Git")
            alert.informativeText = String(localized:
                "The selected commit was not found in locally tracked branches of: \(unknown.joined(separator: ", ")). Push the tag anyway?",
                table: "Git")
            let always = NSButton(checkboxWithTitle:
                String(localized: "Always Proceed", table: "Git"), target: nil, action: nil)
            alert.accessoryView = always
            alert.addButton(withTitle: String(localized: "Proceed to Push", table: "Git"))
            alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
            alert.beginSheetModal(for: window) { answer in
                guard answer == .alertFirstButtonReturn, isCurrent() else { return }
                if always.state == .on { settings.gitAlwaysProceedPushTag = true }
                push()
            }
        }
    }

    private func handleHistoricalFile(
        _ commit: GitStatusModel.RecentCommit,
        file: GitStatusModel.RecentCommit.FileChange,
        action: RecentCommitsView.HistoricalFileAction
    ) {
        guard let project, let window = manager.attachedWindow,
              manager.selectedProject === project,
              let context = project.panelContext,
              model.matchesPanelTarget(context.identity),
              commit.files.contains(where: { $0.path == file.path }) else { return }
        let target = model.actionTarget()
        let current: @MainActor () -> Bool = {
            manager.selectedProject === project && manager.attachedWindow === window
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity)
                && model.canBrowse(target)
        }
        switch action {
        case .viewRevision:
            guard file.status != "D", current() else { return }
            project.openHistoricalDiff(repoRoot: target.repository, path: file.path,
                source: .revision(hash: commit.hash), origPath: file.originalPath)
        case .compareWorktree:
            guard file.status != "D", current() else { return }
            project.openHistoricalDiff(repoRoot: target.repository, path: file.path,
                source: .revisionWorktree(hash: commit.hash), origPath: file.originalPath)
        case .openWorkingFile:
            guard file.status != "D", current() else { return }
            Task { @MainActor in
                let result = await GitHistoricalFileLocator.resolve(
                    root: target.repository, path: file.path, revision: commit.hash,
                    backend: context.backend
                )
                guard current() else { return }
                switch result {
                case .found(let path):
                    project.openFile((target.repository as NSString).appendingPathComponent(path))
                case .missing:
                    showHistoricalFileError(String(localized: "Historical file is not present in the working directory", table: "Git"),
                                            window: window)
                case .failed(let reason):
                    showHistoricalFileError(reason, window: window)
                }
            }
        case .resetFile:
            let currentForWrite: @MainActor () -> Bool = {
                current() && model.isCurrent(target)
            }
            guard file.status != "D", !model.isBusy, currentForWrite() else { return }
            Task { @MainActor in
                guard let state = await model.historicalFileState(file.path, target: target),
                      currentForWrite() else { return }
                let alert = NSAlert()
                alert.messageText = String(localized: "Reset File to Revision", table: "Git")
                alert.informativeText = String(localized:
                    "The selected revision will replace this file in both the Git index and working directory. Any local changes to this file will be lost.", table: "Git")
                    + "\n\n" + file.path + "\n" + commit.hash
                alert.addButton(withTitle: String(localized: "Yes, Reset File", table: "Git"))
                alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
                alert.beginSheetModal(for: window) { answer in
                    guard answer == .alertFirstButtonReturn, currentForWrite() else { return }
                    performOperation(.commitMenu) {
                        model.resetHistoricalFile(file.path, at: commit, target: target,
                            expectedFileState: state,
                            prepare: {
                                await manager.application.saveBeforeGitAction(repository: target.repository,
                                    scope: target.scope, isCurrent: currentForWrite)
                            }, isCurrentTarget: {
                                currentForWrite() && manager.application.canRunGitAction(repository: target.repository,
                                    scope: target.scope)
                            }, completion: { success in
                                if success {
                                    manager.application.reloadAfterGitAction(repository: target.repository,
                                        scope: target.scope)
                                }
                            })
                    }
                }
            }
        }
    }

    private func showHistoricalFileError(_ message: String, window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Unable to open historical file", table: "Git")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Close", table: "Sidebar"))
        alert.beginSheetModal(for: window) { _ in }
    }

    private func presentArchiveDialog(
        reference: String, objectOID: String, target: GitStatusModel.ActionTarget,
        context: PanelContext, window: NSWindow,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        guard isCurrent(), model.refsByName[reference]?.oid == objectOID else { return }
        let panel = NSSavePanel()
        panel.prompt = String(localized: "Create Archive", table: "Git")
        panel.message = reference
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = reference.replacingOccurrences(of: "/", with: "-") + ".zip"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, isCurrent(),
                  model.refsByName[reference]?.oid == objectOID,
                  let destination = panel.url,
                  project?.matchesPanelTarget(context.identity) == true else { return }
            Task { @MainActor in
                await model.createArchive(reference: reference, objectOID: objectOID,
                    destination: destination, target: target)
            }
        }
    }

    func presentCommitDialog(
        _ commit: GitStatusModel.RecentCommit, action: GitStatusModel.CommitAction,
        selectedRefName: String? = nil
    ) {
        guard !model.isBusy, model.repositoryOperation == nil,
              let window = manager.attachedWindow, let project,
              manager.selectedProject === project, let context = project.panelContext,
              model.matchesPanelTarget(context.identity) else { return }
        let target = model.actionTarget()
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && context.scope == target.scope
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity) && model.isCurrent(target)
                && (selectedRefName.map { model.refsByName[$0]?.oid == commit.hash } ?? true)
        }
        let execute: @MainActor (GitCommitDialog?) -> Void = { dialog in
            guard isCurrent() else { return }
            let resetMode = GitStatusModel.ResetMode.allCases[max(0, dialog?.resetMode.indexOfSelectedItem ?? 1)]
            let changesWorktree = action != .reset || resetMode == .hard
            var interactiveLaunch: (@MainActor () throws -> Void)?
            if action == .rebase, dialog?.interactive.state == .on {
                interactiveLaunch = {
                    _ = try project.newInteractiveGitSession(
                        repository: target.repository, arguments: ["rebase", "--interactive", commit.hash], context: context
                    )
                }
            }
            if action == .checkout, dialog?.alwaysAccept.state == .on {
                settings.gitAlwaysAcceptCheckout = true
            }
            performOperation(.commitMenu) {
                model.actOnCommit(
                    commit, action: action, target: target,
                    parent: max(1, (dialog?.parent.indexOfSelectedItem ?? 0) + 1),
                    recordOrigin: dialog?.recordOrigin.state == .on,
                    noCommit: dialog?.noCommit.state == .on,
                    noFastForward: dialog?.noFastForward.state == .on,
                    squash: dialog?.squash.state == .on,
                    resetMode: resetMode,
                    ignoreDate: dialog?.ignoreDate.state != .off,
                    interactiveLaunch: interactiveLaunch,
                    selectedRef: selectedRefName.map { ($0, commit.hash) },
                    prepare: {
                        if !changesWorktree { return true }
                        return await manager.application.saveBeforeGitAction(
                            repository: target.repository, scope: target.scope, isCurrent: isCurrent
                        )
                    }, isCurrentTarget: {
                        isCurrent() && (!changesWorktree || manager.application.canRunGitAction(repository: target.repository, scope: target.scope))
                    },
                    completion: { _ in
                        manager.application.reloadAfterGitAction(repository: target.repository, scope: target.scope)
                    }
                )
            }
        }
        if action == .checkout, settings.gitAlwaysAcceptCheckout {
            execute(nil)
            return
        }
        let dialog = GitCommitDialog(action: action, commit: commit, target: target)
        dialog.alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            execute(dialog)
        }
    }

    // MARK: Commit box

    private var commitBox: some View {
        VStack(spacing: 6) {
            TextField(
                "",
                text: commitMessageBinding,
                prompt: Text(commitFieldPlaceholder).foregroundStyle(.tertiary),
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .panelFont(size: 11.5)
                .lineLimit(1...4)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
                .focused($isCommitFieldFocused)
                .focusedValue(\.baileyGitCommit, focusedCommitAction)

            if !showSyncButton || canCommit(includeAll: false) {
                HStack(spacing: 4) {
                    actionButton(
                        icon: "checkmark",
                        title: commitButtonTitle,
                        enabled: canCommit(includeAll: false),
                        isLoading: operationIsLoading(.primaryAction),
                        help: String(localized: "Commit staged changes (⌘Return)", table: "Sidebar"),
                        action: performPrimaryAction
                    )
                    commitMenu
                }
            }

            if showSyncButton {
                actionButton(
                    icon: "arrow.triangle.2.circlepath",
                    title: syncButtonTitle,
                    enabled: !model.isBusy && model.canUseCurrentReferences,
                    isLoading: operationIsLoading(.syncButton),
                    help: String(localized: "Pull remote commits, then push local ones", table: "Sidebar"),
                    action: {
                        performOperation(.syncButton, model.syncChanges)
                    }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var commitMenu: some View {
        Menu {
            let stagedTitle = String(localized: "Commit Staged", table: "Sidebar")
            Button {
                performCommit(includeAll: false, trigger: .commitMenu)
            } label: {
                Text(verbatim: stagedTitle + (isCommitFieldFocused ? "\t⌘↩" : ""))
            }
                .accessibilityLabel(stagedTitle)
                .disabled(!canCommit(includeAll: false))
            Button(String(localized: "Stage All & Commit", table: "Sidebar")) {
                performCommit(includeAll: true, trigger: .commitMenu)
            }
                .disabled(!canCommit(includeAll: true))
            Divider()
            Button(String(localized: "Amend Last Commit", table: "Sidebar")) {
                performCommit(includeAll: false, amend: true, trigger: .commitMenu)
            }
                .disabled(!canAmend(includeAll: false))
            Button(String(localized: "Stage All & Amend", table: "Sidebar")) {
                performCommit(includeAll: true, amend: true, trigger: .commitMenu)
            }
                .disabled(!canAmend(includeAll: true))
        } label: {
            ZStack {
                Image(systemName: "chevron.down")
                    .panelFont(size: 8, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .opacity(operationIsLoading(.commitMenu) ? 0 : 1)
                if operationIsLoading(.commitMenu) {
                    operationProgressView()
                }
            }
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Commit Options", table: "Sidebar"))
        .accessibilityLabel(String(localized: "Commit Options", table: "Sidebar"))
    }

    private func actionButton(
        icon: String, title: String, enabled: Bool, isLoading: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLoading {
                    operationProgressView()
                } else {
                    Image(systemName: icon)
                        .panelFont(size: 10, weight: .semibold)
                }
                Text(title)
                    .panelFont(size: 11, weight: .medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(themeAccent.opacity(enabled || isLoading ? 0.85 : 0.3))
            )
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(
            isLoading ? String(localized: "\(title), in progress", table: "Sidebar") : title
        )
    }

    private var commitFieldPlaceholder: String {
        if model.stagedEntries.isEmpty {
            return !model.hasHead
                ? String(localized: "Message (stage changes to use ⌘⏎)", table: "Sidebar")
                : String(localized: "Message (stage changes to use ⌘⏎, or choose Amend)", table: "Sidebar")
        }
        if let branch = model.branch {
            return String(
                localized: "Message (⌘⏎ to commit on “\(branch)”)", table: "Sidebar",
                comment: "Commit message placeholder. The placeholder is the current branch name."
            )
        }
        return String(localized: "Message (⌘⏎ to commit)", table: "Sidebar")
    }

    private var showSyncButton: Bool {
        model.totalChangeCount == 0 && (model.ahead > 0 || model.behind > 0)
    }

    private var syncButtonTitle: String {
        var title = String(localized: "Sync Changes", table: "Sidebar")
        if model.behind > 0 { title += " \(model.behind)↓" }
        if model.ahead > 0 { title += " \(model.ahead)↑" }
        return title
    }

    private var commitButtonTitle: String {
        guard !model.stagedEntries.isEmpty else {
            return String(localized: "Commit Staged", table: "Sidebar")
        }
        return String(
            localized: "Commit \(model.stagedEntries.count) Staged Files", table: "Sidebar",
            comment: "Commit button title. The placeholder is the number of staged files."
        )
    }

    private func canCommit(includeAll: Bool) -> Bool {
        let hasEligibleChanges = includeAll
            ? (!model.changedEntries.isEmpty || !model.stagedEntries.isEmpty)
            : !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && model.canUseCurrentStatus
            && !model.isBusy
    }

    private func canAmend(includeAll: Bool) -> Bool {
        let hasCommit = model.hasHead
        let hasEligibleChanges = !includeAll
            || !model.changedEntries.isEmpty
            || !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCommit
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && model.canUseCurrentStatus
            && !model.isBusy
    }

    private var focusedCommitAction: (() -> Void)? {
        guard isGitActive, hasCurrentPanelTarget, canCommit(includeAll: false) else { return nil }
        return {
            guard isGitActive, hasCurrentPanelTarget else { return }
            performPrimaryAction()
        }
    }

    private func performPrimaryAction() {
        performCommit(includeAll: false, trigger: .primaryAction)
    }

    private func performCommit(
        includeAll: Bool,
        amend: Bool = false,
        trigger: OperationTrigger
    ) {
        guard amend ? canAmend(includeAll: includeAll) : canCommit(includeAll: includeAll) else { return }
        let submittedMessage = commitMessage
        performOperation(trigger) {
            model.commit(message: submittedMessage, includeAll: includeAll, amend: amend)
        }
    }

    // MARK: Filter

    @ViewBuilder
    private var filterBar: some View {
        if showFilter {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .panelFont(size: 10)
                    .foregroundStyle(.tertiary)
                TextField(String(localized: "Filter changed files", table: "Sidebar"), text: $filterText)
                    .textFieldStyle(.plain)
                    .panelFont(size: 11)
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .panelFont(size: 10)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Clear Filter", table: "Sidebar"))
                    .accessibilityLabel(String(localized: "Clear Git Filter", table: "Sidebar"))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.045))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    // MARK: Change list

    // Only text scrolls horizontally. Section controls and row actions remain
    // anchored to the visible sidebar, even for exceptionally long paths.
    private var changeList: some View {
        let graphCommits = model.graphCommits
        let graphTarget = model.actionTarget()
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.totalChangeCount == 0 {
                    cleanState
                } else if visibleChangeCount == 0 {
                    inlinePlaceholder(
                        icon: "line.3.horizontal.decrease",
                        text: String(localized: "No changed files match “\(filterText)”", table: "Sidebar")
                    )
                }
                if !filteredMergeEntries.isEmpty {
                    PanelSectionHeader(
                        title: String(localized: "MERGE CHANGES", table: "Sidebar"),
                        count: filteredMergeEntries.count,
                        isCollapsed: $mergeCollapsed,
                        actions: [],
                        actionsDisabled: model.isBusy,
                        menuActions: uncommittedMenuActions
                    )
                    if !mergeCollapsed {
                        changedFileRows(filteredMergeEntries, kind: .merge)
                    }
                }
                if !filteredStagedEntries.isEmpty {
                    PanelSectionHeader(
                        title: String(localized: "STAGED CHANGES", table: "Sidebar"),
                        count: filteredStagedEntries.count,
                        isCollapsed: $stagedCollapsed,
                        actions: filterText.isEmpty ? [
                            .init(
                                systemImage: "minus",
                                help: String(localized: "Unstage All Changes", table: "Sidebar"),
                                isLoading: operationIsLoading(.unstageAll)
                            ) {
                                performOperation(.unstageAll, model.unstageAll)
                            }
                        ] : [],
                        actionsDisabled: model.isBusy,
                        menuActions: uncommittedMenuActions
                    )
                    if !stagedCollapsed {
                        changedFileRows(filteredStagedEntries, kind: .staged)
                    }
                }
                if !filteredChangedEntries.isEmpty {
                    PanelSectionHeader(
                        title: String(localized: "CHANGES", table: "Sidebar"),
                        count: filteredChangedEntries.count,
                        isCollapsed: $changesCollapsed,
                        actions: filterText.isEmpty ? [
                            .init(
                                systemImage: "arrow.uturn.backward",
                                help: String(localized: "Discard All Changes", table: "Sidebar"),
                                isLoading: operationIsLoading(.discardAll)
                            ) {
                                requestDiscardAll()
                            },
                            .init(
                                systemImage: "plus",
                                help: String(localized: "Stage All Changes", table: "Sidebar"),
                                isLoading: operationIsLoading(.stageAll)
                            ) {
                                performOperation(.stageAll, model.stageAll)
                            },
                        ] : [],
                        actionsDisabled: model.isBusy,
                        menuActions: uncommittedMenuActions
                    )
                    if !changesCollapsed {
                        changedFileRows(filteredChangedEntries, kind: .unstaged)
                    }
                }
                if filterText.isEmpty, !graphCommits.isEmpty {
                    PanelSectionHeader(
                        title: String(localized: "GIT GRAPH", table: "Git"),
                        count: graphCommits.count,
                        isCollapsed: $historyCollapsed,
                        actions: [],
                        actionsDisabled: model.isBusy
                    )
                    if !historyCollapsed {
                        RecentCommitsView(
                            commits: graphCommits,
                            remotes: model.remotes,
                            remoteURLs: remoteURLs,
                            knownRemotesByCommit: model.knownRemotesByCommit,
                            hostProviders: settings.gitHostProviders,
                            openHosted: { remote, commit in
                                guard hasCurrentPanelTarget, model.canBrowse(graphTarget) else { return }
                                model.openInBrowser(remote: remote, commit: commit,
                                                    hostProviders: settings.gitHostProviders)
                            },
                            stashFilesByOID: model.stashFilesByOID,
                            repoRoot: model.repoRoot,
                            selectionScope: model.currentScope,
                            displayedDiff: displayedDiff,
                            fileAction: { commit, file, action in
                                guard model.canBrowse(graphTarget) else { return }
                                handleHistoricalFile(commit, file: file, action: action)
                            },
                            loadBinaryStatus: { commit in
                                guard hasCurrentPanelTarget, model.canBrowse(graphTarget) else { return }
                                if let stash = commit.stash {
                                    model.loadStashFiles(for: stash)
                                } else {
                                    model.loadHistoricalBinaryPaths(for: commit)
                                }
                            },
                            isBinaryFile: { commit, file in
                                model.isHistoricalBinaryFile(commit: commit, path: file.path)
                            },
                            expandedCommitIDs: expandedCommitIDsBinding,
                            collapsedFolders: collapsedFoldersBinding,
                            viewMode: settings.gitViewMode,
                            fontScale: panelFontScale,
                            hasMoreCommits: model.hasMoreRecentCommits,
                            isLoadingMore: model.isLoadingMoreCommits,
                            loadMore: model.loadMoreCommits,
                            openDiff: { commit, file in
                                guard hasCurrentPanelTarget, model.canBrowse(graphTarget) else { return }
                                openCommitDiff(commit, file)
                            },
                            canSwitchBranch: !model.isBusy && model.canUseCurrentReferences,
                            switchBranch: { name, oid in
                                switchBranchSafely(to: name, expectedOID: oid)
                            },
                            branchAction: { ref, commit, action in
                                presentBranchAction(ref, commit: commit, action: action)
                            },
                            remoteAction: { ref, commit, action in
                                presentRemoteBranchAction(ref, commit: commit, action: action)
                            },
                            tagAction: { ref, commit, action in
                                presentTagAction(ref, commit: commit, action: action)
                            },
                            isAnnotatedTag: model.isAnnotatedTag,
                            canFetchRemoteBranch: { ref in
                                guard let selected = model.remoteBranch(named: ref.name) else { return false }
                                return model.branches.contains(selected.branch)
                                    && model.branch != selected.branch
                            },
                            createBranch: { commit in
                                presentBranchCreate(at: commit, initialCheckout: false)
                            },
                            addTag: { commit in
                                presentTagCreate(at: commit)
                            },
                            canActOnCommit: !model.isBusy && model.canUseCurrentHistory && model.repositoryOperation == nil,
                            canDropCommit: model.canDrop,
                            commitAction: { commit, action in
                                presentCommitDialog(commit, action: action)
                            },
                            canActOnStash: !model.isBusy && model.canUseCurrentStashes,
                            stashAction: { stash, action in
                                presentStashDialog(stash, action: action)
                            },
                            openWorktreeDiff: { worktree, entry, staged in
                                guard let project, manager.selectedProject === project,
                                      let context = project.panelContext,
                                      project.matchesPanelTarget(context.identity),
                                      model.matchesPanelTarget(context.identity),
                                      model.canBrowse(graphTarget),
                                      model.graphCommits.contains(where: {
                                          $0.worktree?.path == worktree.path
                                              && $0.worktree?.entries.contains(entry) == true
                                      })
                                else { return }
                                manager.openDiff(
                                    repoRoot: worktree.path, path: entry.path,
                                    staged: staged, untracked: entry.isUntracked,
                                    origPath: entry.diffOriginalPath(staged: staged),
                                    activating: false
                                )
                            },
                            canActOnWorktrees: !model.isBusy && model.hasCurrentWorktrees
                                && model.canUseCurrentReferences,
                            canRevealWorktreeInFinder: model.actionTarget().scope == "local",
                            worktreeAction: { location, action in
                                presentWorktreeAction(location, action: action)
                            },
                            canCreateWorktree: { ref in
                                model.canCreateWorktree(for: ref.name)
                            },
                            createWorktree: { ref, commit in
                                presentBranchAction(ref, commit: commit, action: .createWorktree)
                            },
                            keyboardOwner: graphKeyboardOwner,
                            isKeyboardActive: isGitActive && hasCurrentPanelTarget,
                            onKeyboardFocused: {
                                lastKeyboardRegion = .graph
                                if let tree = graphKeyboardOwner.view, let project {
                                    manager.registerTreeResponder(tree, for: .git, in: project)
                                }
                            },
                            onKeyboardAttached: focusGitChanges,
                            scrollToKeyboardRow: { target in
                                GitGraphScrollLog.record(
                                    "scroll-request", owner: graphKeyboardOwner, row: target
                                )
                                proxy.scrollTo(target)
                                if GitGraphScrollLog.enabled {
                                    DispatchQueue.main.async {
                                        GitGraphScrollLog.record(
                                            "scroll-next-turn", owner: graphKeyboardOwner, row: target
                                        )
                                    }
                                }
                            }
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) {
                oldOffset, newOffset in
                if GitGraphScrollLog.enabled {
                    GitGraphScrollLog.record(
                        "scroll-offset", owner: graphKeyboardOwner,
                        detail: "previous=\(oldOffset) current=\(newOffset)"
                    )
                }
            }
            .background {
                TreeKeyboardHost(owner: keyboardOwner, onKeyDown: handleGitChangeKey,
                                 onFocusChanged: { focused in
                                     keyboardFocused = focused
                                     if focused {
                                         lastKeyboardRegion = .changes
                                         if let tree = keyboardOwner.view, let project {
                                             manager.registerTreeResponder(tree, for: .git, in: project)
                                         }
                                     }
                                 },
                                 onAttachedToWindow: focusGitChanges,
                                 onEditCommand: { action in
                                     if case .selectAll = action {
                                         model.selectAllChanges(visible: navigableChanges.map(selection))
                                     }
                                 },
                                 canEditCommand: { action in
                                     if case .selectAll = action {
                                         return isGitActive && hasCurrentPanelTarget
                                             && !navigableChanges.isEmpty
                                     }
                                     return false
                                 })
            }
            .onAppear {
                GitGraphScrollLog.record(
                    "panel-appear", owner: graphKeyboardOwner,
                    detail: "active=\(isGitActive) target=\(hasCurrentPanelTarget)"
                )
                focusGitChanges()
                revealActiveChange()
            }
            .onChange(of: project?.dock.activeGroup?.selected) { _, _ in
                revealActiveChange()
            }
            .onChange(of: isGitActive) { _, active in
                GitGraphScrollLog.record(
                    "panel-active", owner: graphKeyboardOwner, detail: "active=\(active)"
                )
                if active {
                    focusGitChanges()
                    revealActiveChange()
                } else {
                    waitingForChanges = false
                }
            }
            .onChange(of: hasCurrentPanelTarget) { _, current in
                if current {
                    focusGitChanges()
                    revealActiveChange()
                }
            }
            .onChange(of: model.repositoryIdentity) { _, _ in
                selectedChange = nil
                model.clearChangeSelection()
                contextChange = nil
                if isGitActive { focusGitChanges() }
            }
            .onChange(of: model.currentScope) { _, _ in
                selectedChange = nil
                model.clearChangeSelection()
                contextChange = nil
                lastKeyboardRegion = .changes
                if isGitActive { focusGitChanges() }
            }
            .onChange(of: historyCollapsed) { _, collapsed in
                if collapsed, lastKeyboardRegion == .graph {
                    lastKeyboardRegion = .changes
                    focusGitChanges()
                }
            }
            .onChange(of: model.graphCommits.map(\.id)) { _, _ in
                if isGitActive && navigableChanges.isEmpty { focusGitChanges() }
            }
            .onChange(of: navigableChanges.map { selection(for: $0) }) { _, choices in
                if waitingForChanges { focusGitChanges() }
                model.reconcileChangeSelection(visible: choices)
                if let contextChange, !choices.contains(contextChange) {
                    self.contextChange = nil
                }
                if !isGitActive { revealActiveChange() }
            }
            .onChange(of: selectedChange) { _, key in
                if let key, keyboardFocused { proxy.scrollTo(key) }
            }
            .onChange(of: keyboardFocused) { _, focused in
                if focused, let selectedChange { proxy.scrollTo(selectedChange) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
                notification in
                if (notification.object as? NSWindow) === keyboardOwner.view?.window {
                    GitGraphScrollLog.record("window-became-key", owner: graphKeyboardOwner)
                    focusGitChanges()
                }
            }
        }
    }

    private func visibleRows(
        _ entries: [GitStatusModel.Entry], kind: GitEntryRow.Kind
    ) -> [VisibleChange] {
        if settings.gitViewMode == .tree {
            let files = entries.map { entry in
                TreeDisplayModel.Row(name: entry.fileName, path: entry.path, isDirectory: false,
                                     status: .init(entryStatus(entry, kind: kind)))
            }
            let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            return TreeDisplayModel.pathRows(
                files, section: kind.rawValue, collapsed: collapsedFolders
            ).compactMap { row in
                if row.isDirectory { return VisibleChange(kind: kind, row: row, entry: nil) }
                guard let entry = byPath[row.path] else { return nil }
                return VisibleChange(kind: kind, row: row, entry: entry)
            }
        }
        return entries.map { entry in
            VisibleChange(kind: kind, row: TreeDisplayModel.Row(
                name: entry.fileName, path: entry.path, isDirectory: false,
                status: .init(entryStatus(entry, kind: kind))
            ), entry: entry)
        }
    }

    private var navigableChanges: [VisibleChange] {
        var rows: [VisibleChange] = []
        if !mergeCollapsed { rows += visibleRows(filteredMergeEntries, kind: .merge) }
        if !stagedCollapsed { rows += visibleRows(filteredStagedEntries, kind: .staged) }
        if !changesCollapsed { rows += visibleRows(filteredChangedEntries, kind: .unstaged) }
        return rows
    }

    private func focusGitChanges() {
        if GitGraphScrollLog.enabled {
            GitGraphScrollLog.record(
                "focus-request", owner: graphKeyboardOwner,
                detail: "region=\(lastKeyboardRegion) active=\(isGitActive) "
                    + "target=\(hasCurrentPanelTarget) changes=\(navigableChanges.count)"
            )
        }
        guard isGitActive, hasCurrentPanelTarget else { return }
        let rows = navigableChanges
        if !rows.isEmpty, !rows.contains(where: { selection(for: $0) == selectedChange }) {
            selectedChange = selection(for: rows[0])
        }
        waitingForChanges = rows.isEmpty
        let tree = (lastKeyboardRegion == .graph || rows.isEmpty)
            ? graphKeyboardOwner.view : keyboardOwner.view
        if let tree, let project {
            manager.registerTreeResponder(tree, for: .git, in: project)
        }
        guard !manager.isCommandPaletteVisible,
              let window = keyboardOwner.view?.window ?? graphKeyboardOwner.view?.window,
              window.isKeyWindow, NSApp.isActive, window.attachedSheet == nil else {
            GitGraphScrollLog.record("focus-deferred", owner: graphKeyboardOwner)
            return
        }
        // An active native input always owns its field editor.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            GitGraphScrollLog.record("focus-native-input", owner: graphKeyboardOwner)
            return
        }
        if (lastKeyboardRegion == .graph || rows.isEmpty),
           graphKeyboardOwner.view?.window === window {
            graphKeyboardOwner.focus()
        } else if !rows.isEmpty {
            keyboardOwner.focus()
        }
        GitGraphScrollLog.record("focus-finished", owner: graphKeyboardOwner)
    }

    /// Dock activation changes the selected SCM resource, not its native keyboard owner.
    /// A Git preview updates its own selection in browseGitChange; background previews
    /// must not masquerade as an active editor change.
    private func revealActiveChange() {
        guard hasCurrentPanelTarget, let project,
              project.dock.group(containing: .git)?.selected == .git
        else { return }
        let content = isGitActive ? project.selectedTab?.content : project.focusedContent
        let change: VisibleChange?
        switch content {
        case .diff(let diff):
            guard diff.workspaceIdentity == project.workspaceIdentity,
                  diff.repoRoot == model.repoRoot else { return }
            let kind: GitEntryRow.Kind
            switch diff.source {
            case .staged: kind = .staged
            case .worktree: kind = .unstaged
            case .commit, .revision, .revisionWorktree: return
            }
            change = navigableChanges.first {
                ($0.kind == kind || (kind == .unstaged && $0.kind == .merge))
                    && $0.entry?.path == diff.path
            }
        case .file(let file):
            guard file.workspaceIdentity == project.workspaceIdentity else { return }
            let matching = navigableChanges.filter {
                guard let entry = $0.entry else { return false }
                return model.absolutePath(for: entry) == file.path
            }
            change = matching.first(where: { $0.kind == .unstaged })
                ?? matching.first(where: { $0.kind == .merge })
                ?? matching.first(where: { $0.kind == .staged })
        case .session, .browser, .none:
            return
        }
        guard let change, let entry = change.entry, model.canBrowse(entry) else { return }
        let key = selection(for: change)
        if !model.selectedChanges.contains(key) || model.selectedChanges.count != 1 {
            model.selectChange(key, visible: navigableChanges.map(selection))
        } else if selectedChange != key {
            selectedChange = key
        }
    }

    /// Modifier click changes only Selection; browsing and folder expansion stay explicit.
    @discardableResult
    private func selectGitChangeForPointer(_ key: ChangeSelection) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let extending = flags.contains(.shift)
        let toggling = flags.contains(.command) && !extending
        model.selectChange(key, visible: navigableChanges.map(selection),
                           extending: extending, toggling: toggling)
        if isGitActive { keyboardOwner.focus() }
        return extending || toggling
    }

    /// Rows and compact directories resolve to current visible entries at action time.
    /// A menu outside the selected set acts only on its own target.
    private func selectedEntries(for target: ChangeSelection, kind: GitEntryRow.Kind) -> [GitStatusModel.Entry] {
        guard hasCurrentPanelTarget, model.canUseCurrentStatus,
              target.scope == model.currentScope, target.repository == model.repoRoot
        else { return [] }
        let keys = model.selectedChanges.contains(target)
            ? model.selectedChanges.filter { $0.section == kind.rawValue }
            : [target]
        guard !keys.isEmpty else { return [] }
        let entries: [GitStatusModel.Entry] = switch kind {
        case .merge: model.mergeEntries
        case .staged: model.stagedEntries
        case .unstaged: model.changedEntries
        }
        return entries.filter { entry in
            matchesFilter(entry) && keys.contains {
                entry.path == $0.path || entry.path.hasPrefix($0.path + "/")
            }
        }
    }

    private func focusContextChange(_ key: ChangeSelection) {
        guard hasCurrentPanelTarget else { return }
        selectedChange = key
        contextChange = key
    }

    private func dismissContextChange(_ key: ChangeSelection) {
        if contextChange == key { contextChange = nil }
    }

    private func browseGitChange(_ change: VisibleChange) {
        guard let entry = change.entry, hasCurrentPanelTarget,
              model.canBrowse(entry) else { return }
        if selectGitChangeForPointer(selection(for: change)) { return }
        var diffEntry = entry
        diffEntry.origPath = entry.diffOriginalPath(staged: change.kind == .staged)
        openDiff(diffEntry, change.kind == .staged)
        if isGitActive, let window = keyboardOwner.view?.window,
           window.isKeyWindow, NSApp.isActive {
            keyboardOwner.focus()
        }
    }

    private func handleGitChangeKey(_ event: NSEvent) -> Bool {
        guard keyboardOwner.view?.window?.firstResponder === keyboardOwner.view,
              isGitActive, hasCurrentPanelTarget,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }
        let rows = navigableChanges
        guard !rows.isEmpty else { return false }
        let current = selectedChange.flatMap { key in
            rows.firstIndex { selection(for: $0) == key }
        }
        let extending = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 125, 126: // Down / Up: Shift expands or contracts without browsing Diff
            model.moveChangeCursor(visible: rows.map(selection),
                                   by: event.keyCode == 125 ? 1 : -1, extending: extending)
        case 124: // Right opens the directory; a second press selects its first child.
            guard !extending else { return false }
            guard let current, rows[current].row.isDirectory else { return false }
            let row = rows[current]
            if !row.row.isExpanded {
                model.toggleCollapsedFolder(row.kind.rawValue + ":" + row.row.path)
            } else if current + 1 < rows.count,
                      rows[current + 1].row.path.hasPrefix(row.row.path + "/") {
                selectedChange = selection(for: rows[current + 1])
            }
        case 123: // Left collapses the directory or moves to its parent.
            guard !extending, let current else { return false }
            let row = rows[current]
            if row.row.isDirectory && row.row.isExpanded {
                model.toggleCollapsedFolder(row.kind.rawValue + ":" + row.row.path)
            } else if let parent = rows[..<current].last(where: {
                $0.kind == row.kind && $0.row.isDirectory
                    && row.row.path.hasPrefix($0.row.path + "/")
            }) {
                selectedChange = selection(for: parent)
            } else { return false }
        case 36, 49, 76: // Return / Space / Enter browse the selected change.
            guard !extending, let current else { return false }
            if rows[current].row.isDirectory {
                let row = rows[current]
                model.toggleCollapsedFolder(row.kind.rawValue + ":" + row.row.path)
            } else {
                browseGitChange(rows[current])
            }
        case 53: // Escape clears selection, not focus
            guard !extending else { return false }
            model.clearChangeSelection()
        default: return false
        }
        return true
    }

    @ViewBuilder
    private func changedFileRows(
        _ entries: [GitStatusModel.Entry], kind: GitEntryRow.Kind
    ) -> some View {
        ForEach(visibleRows(entries, kind: kind), id: \.row.id) { change in
            if change.row.isDirectory {
                directoryRow(change.row, kind: kind)
                    .id(selection(for: change))
            } else if let entry = change.entry {
                row(entry, kind: kind,
                    showDirectory: settings.gitViewMode != .tree, displayRow: change.row)
                    .id(selection(for: change))
            }
        }
    }

    private func directoryRow(
        _ item: TreeDisplayModel.Row, kind: GitEntryRow.Kind
    ) -> some View {
        let stageTrigger = OperationTrigger.entry(path: item.path, operation: .stage)
        let unstageTrigger = OperationTrigger.entry(path: item.path, operation: .unstage)
        let discardTrigger = OperationTrigger.entry(path: item.path, operation: .discard)
        let key = ChangeSelection(scope: model.currentScope, repository: model.repoRoot,
                                  section: kind.rawValue, path: item.path)
        let focused = selectedChange == key && keyboardFocused && isGitActive
            && controlActiveState == .key
        return TreeFolderRow(
            row: item, scale: panelFontScale,
            focusRing: focused, contextRing: item.compactComponents.contains {
                contextChange == ChangeSelection(scope: model.currentScope, repository: model.repoRoot,
                                               section: kind.rawValue, path: $0.path)
            },
            isSelected: model.selectedChanges.contains(key),
            listActive: keyboardFocused && isGitActive && controlActiveState == .key,
            compactSegment: { component, index in
                directorySegment(component, index: index, row: item, kind: kind)
            },
            toggle: {
                guard hasCurrentPanelTarget else { return }
                if selectGitChangeForPointer(key) { return }
                model.toggleCollapsedFolder(kind.rawValue + ":" + item.path)
                if isGitActive { keyboardOwner.focus() }
            }
        ) { active in
            GitChangeRowActions(
                kind: kind, active: active,
                disabled: model.isBusy || !model.canUseCurrentStatus,
                isStageLoading: operationIsLoading(stageTrigger),
                isUnstageLoading: operationIsLoading(unstageTrigger),
                isDiscardLoading: operationIsLoading(discardTrigger),
                stage: {
                    performOperation(stageTrigger) {
                        model.stageEntries(selectedEntries(for: key, kind: kind))
                    }
                },
                unstage: {
                    performOperation(unstageTrigger) {
                        model.unstageEntries(selectedEntries(for: key, kind: kind))
                    }
                },
                discard: {
                    requestDiscard(selectedEntries(for: key, kind: kind), trigger: discardTrigger)
                }
            )
        }
        .background {
            ContextMenuClickTarget(
                onContextClick: { focusContextChange(key) },
                onMenuClosed: { dismissContextChange(key) }
            )
        }
        .contextMenu {
            directoryMenu(path: item.path, target: key, kind: kind,
                          stageTrigger: stageTrigger, unstageTrigger: unstageTrigger)
        }
    }

    private func directorySegment(
        _ component: TreeDisplayModel.Row.CompactComponent, index: Int,
        row: TreeDisplayModel.Row, kind: GitEntryRow.Kind
    ) -> AnyView {
        let cursor = ChangeSelection(scope: model.currentScope, repository: model.repoRoot,
                                     section: kind.rawValue, path: row.path)
        let context = ChangeSelection(scope: model.currentScope, repository: model.repoRoot,
                                      section: kind.rawValue, path: component.path)
        return AnyView(TreeCompactSegment(component: component, index: index,
            isContextTarget: contextChange == context,
            onClick: {
                guard hasCurrentPanelTarget else { return }
                if selectGitChangeForPointer(cursor) { return }
                model.toggleCollapsedFolder(kind.rawValue + ":" + row.path)
                if isGitActive { keyboardOwner.focus() }
            },
            onContextClick: {
                guard hasCurrentPanelTarget else { return }
                selectedChange = cursor
                contextChange = context
            },
            onMenuClosed: { dismissContextChange(context) }) {
                directoryMenu(path: component.path, target: context, kind: kind,
                    stageTrigger: .entry(path: component.path, operation: .stage),
                    unstageTrigger: .entry(path: component.path, operation: .unstage))
            })
    }

    private func entryStatus(_ entry: GitStatusModel.Entry, kind: GitEntryRow.Kind) -> Character {
        switch kind {
        case .merge: "U"
        case .staged: entry.staged
        case .unstaged: entry.unstaged
        }
    }

    private var filteredMergeEntries: [GitStatusModel.Entry] {
        model.mergeEntries.filter(matchesFilter)
    }

    private var filteredStagedEntries: [GitStatusModel.Entry] {
        model.stagedEntries.filter(matchesFilter)
    }

    private var filteredChangedEntries: [GitStatusModel.Entry] {
        model.changedEntries.filter(matchesFilter)
    }

    private var visibleChangeCount: Int {
        filteredMergeEntries.count + filteredStagedEntries.count + filteredChangedEntries.count
    }

    private func matchesFilter(_ entry: GitStatusModel.Entry) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || entry.path.localizedCaseInsensitiveContains(query)
    }

    private var cleanState: some View {
        inlinePlaceholder(
            icon: model.ahead > 0 || model.behind > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle",
            text: model.ahead > 0 || model.behind > 0
                ? String(localized: "Working tree clean, sync is pending", table: "Sidebar")
                : String(localized: "Working tree clean", table: "Sidebar")
        )
    }

    private func row(
        _ entry: GitStatusModel.Entry, kind: GitEntryRow.Kind,
        showDirectory: Bool = true, displayRow: TreeDisplayModel.Row? = nil
    ) -> some View {
        let stageTrigger = OperationTrigger.entry(path: entry.path, operation: .stage)
        let unstageTrigger = OperationTrigger.entry(path: entry.path, operation: .unstage)
        let discardTrigger = OperationTrigger.entry(path: entry.path, operation: .discard)
        let presentation = displayRow ?? TreeDisplayModel.Row(
            name: entry.fileName, path: entry.path, isDirectory: false,
            status: .init(entryStatus(entry, kind: kind))
        )
        let key = ChangeSelection(scope: model.currentScope, repository: model.repoRoot,
                                  section: kind.rawValue, path: entry.path)
        return GitEntryRow(
            entry: entry,
            displayRow: presentation,
            kind: kind,
            showDirectory: showDirectory,
            isSelected: model.selectedChanges.contains(key),
            listActive: keyboardFocused && isGitActive && controlActiveState == .key,
            focusRing: selectedChange == key && keyboardFocused && isGitActive
                && controlActiveState == .key,
            contextRing: contextChange == key,
            onContextClick: { focusContextChange(key) },
            onMenuClosed: { dismissContextChange(key) },
            isRemote: remoteName != nil,
            disabled: model.isBusy || !model.canUseCurrentStatus,
            isStageLoading: operationIsLoading(stageTrigger),
            isUnstageLoading: operationIsLoading(unstageTrigger),
            isDiscardLoading: operationIsLoading(discardTrigger),
            openDiff: {
                browseGitChange(VisibleChange(kind: kind, row: presentation, entry: entry))
            },
            openFile: { openIfPossible(entry) },
            openHead: kind != .merge && model.hasHead && entry.staged != "A" && !entry.isUntracked ? {
                openHeadFile(entry)
            } : nil,
            ignore: kind == .unstaged && entry.staged == "?"
                ? { ignorePaths([entry.path], isDirectory: false) } : nil,
            stage: {
                performOperation(stageTrigger) {
                    model.stageEntries(selectedEntries(for: key, kind: kind))
                }
            },
            unstage: {
                performOperation(unstageTrigger) {
                    model.unstageEntries(selectedEntries(for: key, kind: kind))
                }
            },
            discard: {
                guard hasCurrentPanelTarget else { return }
                let entries = selectedEntries(for: key, kind: kind)
                guard !entries.isEmpty else { return }
                if entries.count > 1 {
                    requestDiscard(entries, trigger: discardTrigger)
                } else if remoteName == nil {
                    pendingDiscard = model.prepareLocalDiscard(entries).first
                } else {
                    prepareRemoteDiscard(entries, all: false)
                }
            },
            absolutePath: model.absolutePath(for: entry),
            copyRelativePath: { copyToPasteboard(entry.path) },
            insertInTerminal: session.map { session in
                { session.sendCommand(shellQuoted(model.absolutePath(for: entry)) + " ") }
            }
        )
    }

    private func openIfPossible(_ entry: GitStatusModel.Entry) {
        guard hasCurrentPanelTarget,
              model.canOpen(entry, isRemote: remoteName != nil) else { return }
        openFile(model.absolutePath(for: entry))
    }

    private var uncommittedMenuActions: [PanelSectionHeader.MenuAction] {
        [
            .init(title: String(localized: "Stash…", table: "Git"),
                  disabled: model.isBusy || !model.canUseCurrentStatus || model.totalChangeCount == 0) { presentUncommittedDialog(.stash) },
            .init(title: String(localized: "Reset…", table: "Git"),
                  disabled: model.isBusy || !model.canUseCurrentStatus || !model.hasHead) { presentUncommittedDialog(.reset) },
            .init(title: String(localized: "Clean…", table: "Git"),
                  disabled: model.isBusy || !model.canUseCurrentStatus) { presentUncommittedDialog(.clean) },
        ]
    }

    func presentStashDialog(_ stash: GitStatusModel.Stash, action: GitStatusModel.StashAction) {
        guard !model.isBusy, model.stashes.contains(stash),
              let window = manager.attachedWindow, let project,
              manager.selectedProject === project, let context = project.panelContext,
              model.matchesPanelTarget(context.identity) else { return }
        let target = model.actionTarget()
        let selectedStashes = model.stashes
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity)
                && model.isCurrent(target, requiresStableHead: action != .drop)
                && model.stashes.contains(stash)
        }
        let dialog = GitStashDialog(action: action, stash: stash, target: target)
        dialog.alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, isCurrent() else { return }
            performOperation(.moreMenu) {
                model.actOnStash(stash, action: action, reinstateIndex: dialog.reinstateIndex.state == .on,
                    branchName: dialog.name.stringValue, target: target,
                    expectedStashes: selectedStashes, prepare: {
                        await manager.application.saveBeforeGitAction(repository: target.repository, scope: target.scope, isCurrent: isCurrent)
                    }, isCurrentTarget: {
                        isCurrent() && (action == .drop || manager.application.canRunGitAction(repository: target.repository, scope: target.scope))
                    }, completion: { _ in
                        if action != .drop { manager.application.reloadAfterGitAction(repository: target.repository, scope: target.scope) }
                    })
            }
        }
    }

    func presentUncommittedDialog(_ action: GitUncommittedDialog.Action) {
        guard !model.isBusy, let window = manager.attachedWindow, let project,
              manager.selectedProject === project, let context = project.panelContext,
              model.matchesPanelTarget(context.identity) else { return }
        let target = model.actionTarget()
        let dialog = GitUncommittedDialog(action: action, target: target)
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity) && model.isCurrent(target)
        }
        dialog.alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, isCurrent() else { return }
            let mode: GitStatusModel.ResetMode = dialog.resetMode.indexOfSelectedItem == 1 ? .hard : .mixed
            let writesWorktree = action != .reset || mode == .hard
            let prepare: @MainActor () async -> Bool = {
                if !writesWorktree { return true }
                return await manager.application.saveBeforeGitAction(
                    repository: target.repository, scope: target.scope, isCurrent: isCurrent)
            }
            let validate: @MainActor () -> Bool = {
                isCurrent() && (!writesWorktree || manager.application.canRunGitAction(repository: target.repository, scope: target.scope))
            }
            let completion: @MainActor (Bool) -> Void = { _ in
                manager.application.reloadAfterGitAction(repository: target.repository, scope: target.scope)
            }
            performOperation(.moreMenu) {
                switch action {
                case .stash:
                    model.stash(message: dialog.message.stringValue,
                        includeUntracked: dialog.includeUntracked.state == .on, target: target,
                        prepare: prepare, isCurrentTarget: validate, completion: completion)
                case .reset:
                    model.resetUncommitted(mode: mode, target: target, prepare: prepare,
                                           isCurrentTarget: validate, completion: completion)
                case .clean:
                    model.cleanUntracked(includeDirectories: dialog.directories.state == .on,
                        target: target, prepare: prepare, isCurrentTarget: validate, completion: completion)
                }
            }
        }
    }

    @ViewBuilder
    private func directoryMenu(
        path: String, target: ChangeSelection, kind: GitEntryRow.Kind,
        stageTrigger: OperationTrigger, unstageTrigger: OperationTrigger
    ) -> some View {
        let available = !selectedEntries(for: target, kind: kind).isEmpty
        if kind == .staged {
            Button(String(localized: "Unstage Changes", table: "Sidebar")) {
                performOperation(unstageTrigger) {
                    model.unstageEntries(selectedEntries(for: target, kind: kind))
                }
            }.disabled(model.isBusy || !model.canUseCurrentStatus || !available)
        } else {
            Button(kind == .merge ? String(localized: "Mark Resolved (Stage)", table: "Sidebar")
                   : String(localized: "Stage Changes", table: "Sidebar")) {
                performOperation(stageTrigger) {
                    model.stageEntries(selectedEntries(for: target, kind: kind))
                }
            }.disabled(model.isBusy || !model.canUseCurrentStatus || !available)
            if kind == .unstaged {
                Button(String(localized: "Discard Changes…", table: "Sidebar")) {
                    requestDiscard(selectedEntries(for: target, kind: kind),
                                   trigger: .entry(path: path, operation: .discard))
                }.disabled(model.isBusy || !model.canUseCurrentStatus || !available)
                if selectedEntries(for: target, kind: kind).contains(where: { $0.staged == "?" }) {
                    Button(String(localized: "Add to .gitignore", table: "Git")) {
                        ignorePaths([path], isDirectory: true)
                    }.disabled(model.isBusy)
                }
            }
        }
    }

    private func confirmReviewedDiscard(
        _ reviews: [GitStatusModel.PendingDiscard], trigger: OperationTrigger
    ) {
        guard let window = manager.attachedWindow, let project,
              manager.selectedProject === project, let context = project.panelContext,
              model.matchesPanelTarget(context.identity), !reviews.isEmpty else { return }
        let target = model.actionTarget()
        let relative = reviews.flatMap { review -> [String] in
            let entry = review.entry
            return [entry.path] + (entry.isWorktreeRename ? entry.origPath.map { [$0] } ?? [] : [])
        }
        let paths = Set(relative).map {
            (target.repository as NSString).appendingPathComponent($0)
        }
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity)
                && model.isCurrent(target)
        }
        let mayDiscard: @MainActor () -> Bool = {
            isCurrent() && manager.application.canRunGitAction(
                repository: target.repository, scope: target.scope, affectedPaths: paths
            )
        }
        Task {
            guard isCurrent() else { return }
            do {
                try await manager.application.withProtectedFiles(
                    paths: paths, workspace: target.scope == "local" ? nil : target.scope
                ) {
                    guard isCurrent() else { throw CancellationError() }
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let completed: @MainActor (Bool) -> Void = { _ in
                            if isCurrent() {
                                manager.application.reloadAfterGitAction(
                                    repository: target.repository, scope: target.scope, affectedPaths: paths
                                )
                            }
                            continuation.resume()
                        }
                        if remoteName != nil {
                            Task {
                                if await model.confirmRemoteDiscard(
                                    reviews, isCurrentTarget: mayDiscard, completion: completed
                                ), model.isBusy {
                                    operationExpanded = false
                                    operationTrigger = trigger
                                }
                            }
                        } else {
                            performOperation(trigger) {
                                _ = model.confirmLocalDiscard(
                                    reviews, isCurrentTarget: mayDiscard, completion: completed
                                )
                            }
                        }
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    WorkspaceNativeDialogs.showError(error, in: window)
                }
            }
        }
    }

    private func requestDiscard(
        _ entries: [GitStatusModel.Entry], trigger: OperationTrigger
    ) {
        guard hasCurrentPanelTarget, !entries.isEmpty else { return }
        if remoteName != nil {
            prepareRemoteDiscard(entries, all: true, trigger: trigger)
        } else {
            let reviews = model.prepareLocalDiscard(entries)
            guard reviews.count == entries.count else {
                model.cancelStaleDiscard()
                return
            }
            pendingDiscardAll = reviews
            pendingDiscardAllTrigger = trigger
            confirmDiscardAll = true
        }
    }

    private func ignorePaths(_ paths: [String], isDirectory: Bool) {
        guard !model.isBusy, let window = manager.attachedWindow,
              let project, let context = project.panelContext else { return }
        let target = model.actionTarget()
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity)
                && model.isCurrent(target, requiresStableHead: false)
        }
        Task {
            do {
                try await project.ignoreGitPaths(paths, isDirectory: isDirectory,
                    repository: target.repository, context: context, isCurrent: isCurrent)
                if isCurrent() { model.refresh() }
            } catch {
                if isCurrent() { model.lastError = error.localizedDescription }
            }
        }
    }

    private func openHeadFile(_ entry: GitStatusModel.Entry) {
        guard hasCurrentPanelTarget, model.canBrowse(entry),
              let project, let hash = model.headOID else { return }
        project.openHistoricalDiff(repoRoot: model.repoRoot,
            path: (entry.staged == "R" || entry.staged == "C") ? entry.origPath ?? entry.path : entry.path,
            source: .revision(hash: hash), origPath: nil)
    }

    /// The project determines the machine, never the selected terminal.
    private var remoteName: String? { sshHost }

    private func discardTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return "" }
        // There is no Trash on the remote: these files are deleted outright,
        // so the confirmation says so and names the full path.
        if let remoteName {
            if entry.isUntracked {
                return String(
                    localized: "Delete \(entry.path) on \(remoteName)? A remote file is deleted outright, not moved to the Trash.", table: "Sidebar",
                    comment: "Remote discard confirmation. The placeholders are a repository-relative path and a remote machine as user@host."
                )
            }
            if entry.isWorktreeRename, let original = entry.origPath {
                return String(
                    localized: "Undo this rename? \(entry.path) is deleted on \(remoteName) and \(original) is restored.", table: "Sidebar",
                    comment: "Remote rename discard confirmation. The placeholders are the new path, a remote machine as user@host, and the old path."
                )
            }
            if entry.isWorktreeCopy {
                return String(
                    localized: "Discard this copy? \(entry.path) is deleted on \(remoteName), not moved to the Trash.", table: "Sidebar",
                    comment: "Remote copy discard confirmation. The placeholders are a path and a remote machine as user@host."
                )
            }
        }
        if entry.isUntracked {
            return String(
                localized: "Delete \(entry.fileName)? Its contents will move to the Trash.", table: "Sidebar",
                comment: "Discard confirmation. The placeholder is an untracked file name."
            )
        }
        if entry.isWorktreeRename, let original = entry.origPath {
            return String(
                localized: "Undo this rename? \(entry.fileName) will move to the Trash and \((original as NSString).lastPathComponent) will be restored.", table: "Sidebar",
                comment: "Rename discard confirmation. The placeholders are the new and old file names."
            )
        }
        if entry.isWorktreeCopy {
            return String(
                localized: "Discard this copy? \(entry.fileName) will move to the Trash.", table: "Sidebar",
                comment: "Copy discard confirmation. The placeholder is a file name."
            )
        }
        return String(
            localized: "Discard changes in \(entry.fileName)?", table: "Sidebar",
            comment: "Discard confirmation. The placeholder is a file name."
        )
    }

    private func discardActionTitle(for entry: GitStatusModel.Entry?) -> String {
        guard let entry else { return String(localized: "Discard Changes", table: "Sidebar") }
        if entry.isUntracked || entry.isWorktreeCopy {
            return remoteName == nil
                ? String(localized: "Move to Trash", table: "Sidebar")
                : String(localized: "Delete", table: "Sidebar")
        }
        if entry.isWorktreeRename { return String(localized: "Undo Rename", table: "Sidebar") }
        return String(localized: "Discard Changes", table: "Sidebar")
    }

    private var discardAllTitle: String {
        guard let remoteName else {
            return String(
                localized: "Discard the \(pendingDiscardAll.count) reviewed changes? Untracked and moved files go to the Trash.", table: "Sidebar",
                comment: "Discard-all confirmation. The placeholder is a number of changes."
            )
        }
        return String(
            localized: "Discard the \(pendingDiscardAll.count) reviewed changes? Untracked and moved files are deleted outright on \(remoteName), not moved to the Trash.", table: "Sidebar",
            comment: "Remote discard-all confirmation. The placeholders are a number of changes and a remote machine as user@host."
        )
    }

    private func requestDiscardAll() {
        guard hasCurrentPanelTarget else { return }
        if remoteName != nil {
            prepareRemoteDiscard(model.changedEntries, all: true)
        } else {
            pendingDiscardAll = model.prepareLocalDiscard(model.changedEntries)
            pendingDiscardAllTrigger = .discardAll
            confirmDiscardAll = !pendingDiscardAll.isEmpty
        }
    }

    private func prepareRemoteDiscard(
        _ entries: [GitStatusModel.Entry], all: Bool,
        trigger: OperationTrigger = .discardAll
    ) {
        guard hasCurrentPanelTarget, !preparingDiscard, !entries.isEmpty,
              model.canUseCurrentStatus else { return }
        preparingDiscard = true
        Task {
            defer { preparingDiscard = false }
            do {
                let snapshots = try await model.prepareRemoteDiscard(entries)
                guard hasCurrentPanelTarget else { return }
                if all {
                    pendingDiscardAll = snapshots
                    pendingDiscardAllTrigger = trigger
                    confirmDiscardAll = true
                } else {
                    pendingDiscard = snapshots.first
                }
            } catch GitStatusModel.DiscardReviewError.stale {
                model.cancelStaleDiscard()
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Could not verify remote files", table: "Sidebar")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: Bits

    private func performOperation(_ trigger: OperationTrigger, _ action: () -> Void) {
        guard hasCurrentPanelTarget else { return }
        operationExpanded = false
        operationTrigger = trigger
        action()
        if !model.isBusy { operationTrigger = nil }
    }

    private func operationIsLoading(_ trigger: OperationTrigger) -> Bool {
        model.isBusy && operationTrigger == trigger
    }

    private func operationProgressView() -> some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 11, height: 11)
            .accessibilityHidden(true)
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .panelFont(size: 24, weight: .light)
                .foregroundStyle(.quaternary)
            Text(verbatim: text)
                .panelFont(size: 11)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func inlinePlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .panelFont(size: 18, weight: .light)
                .foregroundStyle(.quaternary)
            Text(verbatim: text)
                .panelFont(size: 10.5)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
    }

    private var notRepository: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .panelFont(size: 24, weight: .light)
                .foregroundStyle(.quaternary)
            VStack(spacing: 2) {
                Text(String(localized: "No Git Repository", table: "Sidebar"))
                    .panelFont(size: 11.5, weight: .medium)
                Text(String(localized: "Initialize the terminal’s current directory to start tracking changes.", table: "Sidebar"))
                    .panelFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Button {
                performOperation(.initializeRepository) {
                    model.initializeRepository()
                }
            } label: {
                HStack(spacing: 5) {
                    if operationIsLoading(.initializeRepository) {
                        operationProgressView()
                    }
                    Text(String(localized: "Initialize Repository", table: "Sidebar"))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(themeAccent)
            .disabled(model.rootPath.isEmpty || model.isBusy)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private func statusWarning(_ message: String, isDetail: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(isDetail
                     ? String(localized: "Git Details Unavailable", table: "Sidebar")
                     : String(localized: "Git Status Unavailable", table: "Sidebar"))
                    .panelFont(size: 10.5, weight: .medium)
                Spacer(minLength: 4)
                Button(String(localized: "Retry", table: "Sidebar")) { manager.syncGitStatus(model) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(model.isBusy || model.isRefreshing)
            }
            Text(verbatim: message)
                .panelFont(size: 10)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusFailure(_ message: String) -> some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .panelFont(size: 24, weight: .light)
                .foregroundStyle(statusColor(1))
            VStack(spacing: 3) {
                Text(String(localized: "Git Status Unavailable", table: "Sidebar"))
                    .panelFont(size: 11.5, weight: .medium)
                Text(verbatim: message)
                    .panelFont(size: 10, design: .monospaced)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
            Button(String(localized: "Retry", table: "Sidebar")) { manager.syncGitStatus(model) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy || model.isResolvingInitialStatus)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func badge(_ text: String, label: String) -> some View {
        Text(verbatim: text)
            .panelFont(size: 10, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .accessibilityLabel(label)
    }

    private func copyChangedPaths() {
        let paths = Set(
            (model.mergeEntries + model.stagedEntries + model.changedEntries).map(\.path)
        ).sorted()
        copyToPasteboard(paths.joined(separator: "\n"))
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func resetRepositoryDrafts() {
        filterText = ""
        showFilter = false
        operationExpanded = false
        operationTrigger = nil
        pendingDiscard = nil
        pendingDiscardAll = []
        pendingDiscardAllTrigger = .discardAll
        confirmDiscardAll = false
        mergeCollapsed = false
        stagedCollapsed = false
        changesCollapsed = false
        historyCollapsed = false
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct GitEntryRow: View {
    enum Kind: String, Hashable {
        case merge, staged, unstaged
    }

    let entry: GitStatusModel.Entry
    let displayRow: TreeDisplayModel.Row
    let kind: Kind
    let showDirectory: Bool
    let isSelected: Bool
    let listActive: Bool
    let focusRing: Bool
    let contextRing: Bool
    let onContextClick: () -> Void
    let onMenuClosed: () -> Void
    /// Whether this repository is on another machine, where discarding an
    /// untracked or copied file deletes it rather than moving it to the Trash.
    let isRemote: Bool
    let disabled: Bool
    let isStageLoading: Bool
    let isUnstageLoading: Bool
    let isDiscardLoading: Bool
    let openDiff: () -> Void
    let openFile: () -> Void
    let openHead: (() -> Void)?
    let ignore: (() -> Void)?
    let stage: () -> Void
    let unstage: () -> Void
    let discard: () -> Void
    let absolutePath: String
    let copyRelativePath: () -> Void
    let insertInTerminal: (() -> Void)?

    @Environment(\.panelFontScale) private var fontScale

    var body: some View {
        TreeFileRow(
            row: displayRow,
            scale: fontScale, iconPath: absolutePath,
            directory: showDirectory ? entry.directory : nil,
            isSelected: isSelected,
            listActive: listActive,
            focusRing: focusRing, contextRing: contextRing,
            accessibilityHint: kind == .merge
                ? String(localized: "Opens conflict changes", table: "Sidebar")
                : String(localized: "Opens changes", table: "Sidebar"),
            open: openDiff
        ) { active in
            GitChangeRowActions(
                kind: kind, active: active, disabled: disabled,
                isStageLoading: isStageLoading, isUnstageLoading: isUnstageLoading,
                isDiscardLoading: isDiscardLoading,
                stage: stage, unstage: unstage, discard: discard
            )
        }
        .overlay {
            ContextMenuClickTarget(
                onContextClick: onContextClick, onMenuClosed: onMenuClosed
            )
                .contextMenu { menu }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if kind == .merge {
            Button(String(localized: "Open Changes", table: "Sidebar")) { openDiff() }
            Button(String(localized: "Open Conflicted File", table: "Sidebar")) { openFile() }
        } else {
            Button(String(localized: "Open Changes", table: "Sidebar")) { openDiff() }
            Button(String(localized: "Open File", table: "Sidebar")) { openFile() }
        }
        Divider()
        if let openHead {
            Button(String(localized: "Open HEAD File", table: "Git"), action: openHead)
        }
        switch kind {
        case .merge:
            Button(String(localized: "Mark Resolved (Stage)", table: "Sidebar")) { stage() }
                .disabled(disabled)
        case .staged:
            Button(String(localized: "Unstage Changes", table: "Sidebar")) { unstage() }
                .disabled(disabled)
        case .unstaged:
            Button(String(localized: "Stage Changes", table: "Sidebar")) { stage() }
                .disabled(disabled)
            Button(destructiveMenuTitle) { discard() }
                .disabled(disabled)
            if let ignore {
                Button(String(localized: "Add to .gitignore", table: "Git"), action: ignore)
                    .disabled(disabled)
            }
        }
        Divider()
        if !isRemote {
            Button(String(localized: "Reveal in Finder", table: "Sidebar")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
            }
        }
        Button(String(localized: "Copy Path", table: "Sidebar")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(absolutePath, forType: .string)
        }
        Button(String(localized: "Copy Relative Path", table: "Sidebar")) { copyRelativePath() }
        if let insertInTerminal {
            Button(String(localized: "Insert Absolute Path in Terminal", table: "Sidebar")) { insertInTerminal() }
        }
    }

    private var destructiveMenuTitle: String {
        if entry.isUntracked || entry.isWorktreeCopy {
            return isRemote
                ? String(localized: "Delete…", table: "Sidebar")
                : String(localized: "Move to Trash…", table: "Sidebar")
        }
        if entry.isWorktreeRename { return String(localized: "Undo Rename…", table: "Sidebar") }
        return String(localized: "Discard Changes…", table: "Sidebar")
    }
}

private struct GitChangeRowActions: View {
    let kind: GitEntryRow.Kind
    let active: Bool
    let disabled: Bool
    let isStageLoading: Bool
    let isUnstageLoading: Bool
    let isDiscardLoading: Bool
    let stage: () -> Void
    let unstage: () -> Void
    let discard: () -> Void

    @Environment(\.panelFontScale) private var fontScale

    var body: some View {
        if !disabled || isStageLoading || isUnstageLoading || isDiscardLoading {
            HStack(spacing: 0) {
                switch kind {
                case .merge:
                    rowButton(
                        "plus", help: String(localized: "Mark Resolved (Stage)", table: "Sidebar"),
                        isLoading: isStageLoading, action: stage
                    )
                case .staged:
                    rowButton(
                        "minus", help: String(localized: "Unstage Changes", table: "Sidebar"),
                        isLoading: isUnstageLoading, action: unstage
                    )
                case .unstaged:
                    rowButton(
                        "arrow.uturn.backward",
                        help: String(localized: "Discard Changes", table: "Sidebar"),
                        isLoading: isDiscardLoading, action: discard
                    )
                    rowButton(
                        "plus", help: String(localized: "Stage Changes", table: "Sidebar"),
                        isLoading: isStageLoading, action: stage
                    )
                }
            }
            .opacity(isStageLoading || isUnstageLoading || isDiscardLoading
                     ? 1 : (active ? 1 : 0.55))
        }
    }

    private func rowButton(
        _ systemImage: String, help: String,
        isLoading: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: systemImage)
                        .panelFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: TreeRowStyle.rowHeight(fontScale))
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(
            isLoading ? String(localized: "\(help), in progress", table: "Sidebar") : help
        )
    }
}
