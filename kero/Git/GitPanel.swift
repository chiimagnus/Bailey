import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Git panel

struct GitPanel: View {
    var settings: AppSettings = .shared
    private let themeChanges = Theme.changes

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
    let manager: TerminalManager
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
    @State private var pendingDiscard: GitStatusModel.PendingDiscard?
    @State private var pendingDiscardAll: [GitStatusModel.PendingDiscard] = []
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
    @State private var stashesCollapsed = false
    @State private var expandedCommitIDs: Set<String> = []
    @State private var filterText = ""
    @State private var showFilter = false
    @State private var operationExpanded = false
    @State private var operationTrigger: OperationTrigger?
    @Environment(\.panelFontScale) private var panelFontScale

    private var hasCurrentPanelTarget: Bool {
        guard let context = project?.panelContext else { return false }
        return model.matchesPanelTarget(context.identity)
    }

    var body: some View {
        let _ = themeChanges.revision
        VStack(spacing: 0) {
            header
            operationFailureBanner

            if !model.isRepo {
                if let statusError = model.statusError {
                    statusFailure(statusError)
                } else if model.isResolvingInitialStatus {
                    placeholder(icon: "arrow.clockwise", text: String(localized: "Finding repository…", table: "Sidebar"))
                } else {
                    notRepository
                }
            } else {
                if let statusError = model.statusError {
                    statusWarning(statusError)
                }
                trackingBar
                repositoryOperationBanner
                commitBox
                filterBar
                changeList
            }
        }
        .disabled(!hasCurrentPanelTarget)
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
                if let pendingDiscard {
                    let trigger = OperationTrigger.entry(
                        path: pendingDiscard.entry.path, operation: .discard
                    )
                    if remoteName != nil {
                        Task {
                            if await model.confirmRemoteDiscard([pendingDiscard]), model.isBusy {
                                operationExpanded = false
                                operationTrigger = trigger
                            }
                        }
                    } else {
                        performOperation(trigger) {
                            _ = model.confirmLocalDiscard([pendingDiscard])
                        }
                    }
                }
                pendingDiscard = nil
            }
            .disabled(model.isBusy)
        }
        .confirmationDialog(
            discardAllTitle,
            isPresented: Binding(
                get: { confirmDiscardAll },
                set: {
                    confirmDiscardAll = $0
                    if !$0 { pendingDiscardAll = [] }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Discard All Changes", table: "Sidebar"), role: .destructive) {
                let snapshot = pendingDiscardAll
                if remoteName != nil {
                    Task {
                        if await model.confirmRemoteDiscard(snapshot), model.isBusy {
                            operationExpanded = false
                            operationTrigger = .discardAll
                        }
                    }
                } else {
                    performOperation(.discardAll) {
                        _ = model.confirmLocalDiscard(snapshot)
                    }
                }
                pendingDiscardAll = []
                confirmDiscardAll = false
            }
            .disabled(model.isBusy)
        }
        .onChange(of: model.rootPath) {
            // A dialog must never carry a destructive file target across cwd.
            pendingDiscard = nil
            pendingDiscardAll = []
            confirmDiscardAll = false
        }
        .onChange(of: model.repositoryIdentity) {
            resetRepositoryDrafts()
        }
        .onChange(of: model.currentScope) {
            pendingDiscard = nil
            pendingDiscardAll = []
            confirmDiscardAll = false
        }
        .onChange(of: model.isBusy) {
            if !model.isBusy { operationTrigger = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if model.isRepo {
                branchMenu
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .panelFont(size: 11, weight: .medium)
                    .foregroundStyle(Color(nsColor: Theme.accent))
                PanelHeader(title: String(localized: "Git Manager", table: "Sidebar"), subtitle: model.rootPath)
            }
            // User operations surface progress in their initiating control.
            // Keep repository discovery here because it has no trigger button.
            if model.isResolvingInitialStatus {
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
                    Button {
                        switchBranchSafely(to: branch)
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
                        .foregroundStyle(Color(nsColor: Theme.accent))
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
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(String(localized: "Switch or Create Branch", table: "Sidebar"))
        .accessibilityLabel(
            String(localized: "Current branch, \(model.branch ?? String(localized: "detached HEAD", table: "Sidebar"))", table: "Sidebar")
        )
    }

    private var moreMenu: some View {
        Menu {
            Button(String(localized: "Fetch", table: "Sidebar")) { performOperation(.moreMenu, model.fetch) }
                .disabled(model.isBusy || model.remotes.isEmpty)
            Button(String(localized: "Pull (Fast-forward Only)", table: "Sidebar")) { performOperation(.moreMenu, model.pull) }
                .disabled(model.isBusy || !model.hasUpstream)
            if model.hasUpstream {
                Button(String(localized: "Push", table: "Sidebar")) { performOperation(.moreMenu, model.push) }
                    .disabled(model.isBusy)
            } else if model.remotes.count > 1 {
                Menu(String(localized: "Publish Branch to", table: "Sidebar")) {
                    ForEach(model.remotes, id: \.self) { remote in
                        Button(remote) {
                            performOperation(.moreMenu) { model.publish(to: remote) }
                        }
                    }
                }
                .disabled(model.isBusy || model.branch == "detached HEAD")
            } else {
                Button(String(localized: "Publish Branch", table: "Sidebar")) { performOperation(.moreMenu, model.push) }
                    .disabled(model.isBusy || model.remotes.isEmpty || model.branch == "detached HEAD")
            }
            Button(String(localized: "Sync Changes", table: "Sidebar")) { performOperation(.moreMenu, model.syncChanges) }
                .disabled(
                    model.isBusy || model.remotes.isEmpty
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
                }.disabled(model.isBusy)
            }
            Divider()
            Button(String(localized: "Copy Changed Paths", table: "Sidebar")) { copyChangedPaths() }
                .disabled(model.totalChangeCount == 0)
            Button(String(localized: "Copy Repository Path", table: "Sidebar")) { copyToPasteboard(model.repoRoot) }
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
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "More Actions…", table: "Sidebar"))
        .accessibilityLabel(String(localized: "More Git Actions", table: "Sidebar"))
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
            .foregroundStyle(Color(red: 0.74, green: 0.55, blue: 1.0))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.74, green: 0.55, blue: 1.0).opacity(0.08))
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
            .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.36))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.88, green: 0.42, blue: 0.36).opacity(0.08))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
        }
    }

    private func switchBranchSafely(to name: String) {
        guard let window = manager.attachedWindow, let project,
              manager.selectedProject === project, let context = project.panelContext,
              model.matchesPanelTarget(context.identity), !model.isBusy else { return }
        let target = model.actionTarget()
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity) && model.isCurrent(target)
        }
        performOperation(.branchMenu) {
            model.switchBranch(to: name,
                prepare: {
                    await project.saveBeforeGitAction(repository: target.repository,
                        scope: target.scope, isCurrent: isCurrent)
                }, isCurrentTarget: {
                    isCurrent() && project.canRunGitAction(repository: target.repository,
                        scope: target.scope)
                }, completion: { success in
                    if success { project.reloadAfterGitAction(repository: target.repository, scope: target.scope) }
                })
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
                            return await project.saveBeforeGitAction(repository: target.repository,
                                scope: target.scope, isCurrent: isCurrent)
                        }, isCurrentTarget: {
                            isCurrent() && (!checkout || project.canRunGitAction(
                                repository: target.repository, scope: target.scope))
                        }) { success in
                        if success, checkout {
                            project.reloadAfterGitAction(repository: target.repository, scope: target.scope)
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
        guard isCurrent(), let project else { return }
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
                                return await project.saveBeforeGitAction(repository: target.repository,
                                    scope: target.scope, isCurrent: isCurrent)
                            }, isCurrentTarget: {
                                isCurrent() && (!checkout || project.canRunGitAction(
                                    repository: target.repository, scope: target.scope))
                            }, completion: { success in
                                if success, checkout {
                                    project.reloadAfterGitAction(repository: target.repository, scope: target.scope)
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
                let detail = model.remotes.isEmpty
                    ? String(localized: "No Git remote is configured", table: "Git") : name
                let dialog = GitBranchDialog(kind: .push(remotes: model.remotes, preferred: preferred),
                    title: String(localized: "Push Branch…", table: "Git"), detail: detail)
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
            await project.saveBeforeGitAction(
                repository: target.repository, scope: target.scope, isCurrent: stillSelected
            )
        }
        let canMutateWorktree: @MainActor () -> Bool = {
            stillSelected() && project.canRunGitAction(
                repository: target.repository, scope: target.scope
            )
        }
        let onFinish: @MainActor (Bool) -> Void = { _ in
            project.reloadAfterGitAction(repository: target.repository, scope: target.scope)
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
              !model.isBusy, let selected = model.refsByName["refs/tags/" + reference.name]
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
                let detail = model.remotes.isEmpty
                    ? String(localized: "No Git remote is configured", table: "Git") : name
                let dialog = GitTagDialog(kind: .push(remotes: model.remotes, preferred: preferred),
                    title: String(localized: "Push Tag…", table: "Git"), detail: detail)
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
                && model.isCurrent(target)
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
            guard file.status != "D", !model.isBusy, current() else { return }
            Task { @MainActor in
                guard let state = await model.historicalFileState(file.path, target: target),
                      current() else { return }
                let alert = NSAlert()
                alert.messageText = String(localized: "Reset File to Revision", table: "Git")
                alert.informativeText = String(localized:
                    "The selected revision will replace this file in both the Git index and working directory. Any local changes to this file will be lost.", table: "Git")
                    + "\n\n" + file.path + "\n" + commit.hash
                alert.addButton(withTitle: String(localized: "Yes, Reset File", table: "Git"))
                alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
                alert.beginSheetModal(for: window) { answer in
                    guard answer == .alertFirstButtonReturn, current() else { return }
                    performOperation(.commitMenu) {
                        model.resetHistoricalFile(file.path, at: commit, target: target,
                            expectedFileState: state,
                            prepare: {
                                await project.saveBeforeGitAction(repository: target.repository,
                                    scope: target.scope, isCurrent: current)
                            }, isCurrentTarget: {
                                current() && project.canRunGitAction(repository: target.repository,
                                    scope: target.scope)
                            }, completion: { success in
                                if success {
                                    project.reloadAfterGitAction(repository: target.repository,
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
        let selector = GitArchiveFormatSelection(panel: panel)
        panel.accessoryView = selector.accessory
        panel.beginSheetModal(for: window) { response in
            _ = selector
            guard response == .OK, isCurrent(),
                  model.refsByName[reference]?.oid == objectOID,
                  let destination = panel.url,
                  project?.matchesPanelTarget(context.identity) == true else { return }
            Task { @MainActor in
                await model.createArchive(reference: reference, objectOID: objectOID,
                    format: selector.format, destination: destination, target: target)
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
                        return await project.saveBeforeGitAction(
                            repository: target.repository, scope: target.scope, isCurrent: isCurrent
                        )
                    }, isCurrentTarget: {
                        isCurrent() && (!changesWorktree || project.canRunGitAction(repository: target.repository, scope: target.scope))
                    },
                    completion: { _ in
                        project.reloadAfterGitAction(repository: target.repository, scope: target.scope)
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
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    performPrimaryAction()
                    return .handled
                }

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
                    enabled: !model.isBusy,
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
            Button(String(localized: "Commit Staged", table: "Sidebar")) {
                performCommit(includeAll: false, trigger: .commitMenu)
            }
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
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
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
                    .fill(Color(nsColor: Theme.accent).opacity(enabled || isLoading ? 0.85 : 0.3))
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
            return model.recentCommits.isEmpty
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
            && !model.isBusy
    }

    private func canAmend(includeAll: Bool) -> Bool {
        let hasCommit = !model.recentCommits.isEmpty
        let hasEligibleChanges = !includeAll
            || !model.changedEntries.isEmpty
            || !model.stagedEntries.isEmpty
        return !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasCommit
            && hasEligibleChanges
            && model.mergeEntries.isEmpty
            && !model.isBusy
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
                if filterText.isEmpty, !model.stashes.isEmpty {
                    PanelSectionHeader(
                        title: String(localized: "STASHES", table: "Git"), count: model.stashCount,
                        isCollapsed: $stashesCollapsed, actions: [], actionsDisabled: model.isBusy
                    )
                    if !stashesCollapsed {
                        ForEach(model.stashes) { stash in stashRow(stash) }
                    }
                }
                if filterText.isEmpty, !model.recentCommits.isEmpty {
                    PanelSectionHeader(
                        title: String(localized: "RECENT COMMITS", table: "Sidebar"),
                        count: model.recentCommits.count,
                        isCollapsed: $historyCollapsed,
                        actions: [],
                        actionsDisabled: model.isBusy
                    )
                    if !historyCollapsed {
                        RecentCommitsView(
                            commits: model.recentCommits,
                            repoRoot: model.repoRoot,
                            fileAction: { commit, file, action in
                                handleHistoricalFile(commit, file: file, action: action)
                            },
                            loadBinaryStatus: model.loadHistoricalBinaryPaths,
                            isBinaryFile: { commit, file in
                                model.isHistoricalBinaryFile(commit: commit, path: file.path)
                            },
                            expandedCommitIDs: $expandedCommitIDs,
                            collapsedFolders: collapsedFoldersBinding,
                            viewMode: settings.gitViewMode,
                            fontScale: panelFontScale,
                            hasMoreCommits: model.hasMoreRecentCommits,
                            isLoadingMore: model.isLoadingMoreCommits,
                            loadMore: model.loadMoreCommits,
                            openDiff: openCommitDiff,
                            canSwitchBranch: !model.isBusy,
                            switchBranch: { name in
                                switchBranchSafely(to: name)
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
                            canActOnCommit: !model.isBusy && model.repositoryOperation == nil,
                            canDropCommit: model.canDrop,
                            commitAction: { commit, action in
                                presentCommitDialog(commit, action: action)
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
    }

    @ViewBuilder
    private func changedFileRows(
        _ entries: [GitStatusModel.Entry], kind: GitEntryRow.Kind
    ) -> some View {
        if settings.gitViewMode == .tree {
            let files = entries.map { entry in
                TreeDisplayModel.Row(name: entry.fileName, path: entry.path, isDirectory: false,
                                     status: .init(entryStatus(entry, kind: kind)))
            }
            let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            ForEach(TreeDisplayModel.pathRows(files, section: kind.rawValue, collapsed: collapsedFolders)) { item in
                if item.isDirectory {
                    TreeFolderRow(row: item, scale: panelFontScale) {
                        model.toggleCollapsedFolder(kind.rawValue + ":" + item.path)
                    }
                    .contextMenu {
                        directoryMenu(path: item.path, kind: kind)
                    }
                } else if let entry = byPath[item.path] {
                    row(entry, kind: kind, showDirectory: false, displayRow: item)
                }
            }
        } else {
            ForEach(entries, id: \.path) { entry in
                row(entry, kind: kind)
            }
        }
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
        return GitEntryRow(
            entry: entry,
            displayRow: displayRow ?? TreeDisplayModel.Row(
                name: entry.fileName, path: entry.path, isDirectory: false,
                status: .init(entryStatus(entry, kind: kind))
            ),
            kind: kind,
            showDirectory: showDirectory,
            isRemote: remoteName != nil,
            disabled: model.isBusy,
            isStageLoading: operationIsLoading(stageTrigger),
            isUnstageLoading: operationIsLoading(unstageTrigger),
            isDiscardLoading: operationIsLoading(discardTrigger),
            openDiff: {
                guard model.isCurrent(entry) else { return }
                var diffEntry = entry
                if kind == .unstaged && (entry.staged == "R" || entry.staged == "C") {
                    // A staged rename/copy's unstaged side compares the
                    // destination in the index with that same worktree path.
                    diffEntry.origPath = nil
                }
                openDiff(diffEntry, kind == .staged)
            },
            openFile: { openIfPossible(entry) },
            openHead: kind != .merge && model.hasHead && entry.staged != "A" && !entry.isUntracked ? {
                openHeadFile(entry)
            } : nil,
            ignore: kind == .unstaged ? { ignorePaths([entry.path], isDirectory: false) } : nil,
            stage: { performOperation(stageTrigger) { model.stage(entry) } },
            unstage: { performOperation(unstageTrigger) { model.unstage(entry) } },
            discard: {
                if remoteName == nil {
                    pendingDiscard = model.prepareLocalDiscard([entry]).first
                } else {
                    prepareRemoteDiscard([entry], all: false)
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
        guard model.canOpen(entry, isRemote: remoteName != nil) else { return }
        openFile(model.absolutePath(for: entry))
    }

    private var uncommittedMenuActions: [PanelSectionHeader.MenuAction] {
        [
            .init(title: String(localized: "Stash…", table: "Git"),
                  disabled: model.isBusy || model.totalChangeCount == 0) { presentUncommittedDialog(.stash) },
            .init(title: String(localized: "Reset…", table: "Git"),
                  disabled: model.isBusy || !model.hasHead) { presentUncommittedDialog(.reset) },
            .init(title: String(localized: "Clean…", table: "Git"),
                  disabled: model.isBusy) { presentUncommittedDialog(.clean) },
        ]
    }

    private func stashRow(_ stash: GitStatusModel.Stash) -> some View {
        TreeRowSurface(depth: 0, scale: panelFontScale, showsGuides: false) { _, layout in
            HStack(spacing: TreeRowStyle.iconSpacing) {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                    .frame(width: TreeRowStyle.iconSize, height: TreeRowStyle.iconSize)
                Text(verbatim: stash.selector + ": " + stash.message)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .panelFont(size: TreeRowStyle.fontSize)
            .modifier(layout)
        }
        .help(stash.selector + ": " + stash.message)
        .focusable()
        .contextMenu {
            ForEach(GitStatusModel.StashAction.allCases, id: \.self) { action in
                Button(action.title) { presentStashDialog(stash, action: action) }
                    .disabled(model.isBusy)
            }
            Divider()
            Button(String(localized: "Copy Stash Name", table: "Git")) { copyToPasteboard(stash.selector) }
            Button(String(localized: "Copy Stash Hash", table: "Git")) { copyToPasteboard(stash.oid) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(GitStatusModel.StashAction.apply.title)) { presentStashDialog(stash, action: .apply) }
        .accessibilityAction(named: Text(GitStatusModel.StashAction.branch.title)) { presentStashDialog(stash, action: .branch) }
        .accessibilityAction(named: Text(GitStatusModel.StashAction.pop.title)) { presentStashDialog(stash, action: .pop) }
        .accessibilityAction(named: Text(GitStatusModel.StashAction.drop.title)) { presentStashDialog(stash, action: .drop) }
    }

    func presentStashDialog(_ stash: GitStatusModel.Stash, action: GitStatusModel.StashAction) {
        guard !model.isBusy, let window = manager.attachedWindow, let project,
              manager.selectedProject === project, let context = project.panelContext,
              model.matchesPanelTarget(context.identity) else { return }
        let target = model.actionTarget()
        let isCurrent: @MainActor () -> Bool = {
            manager.attachedWindow === window && manager.selectedProject === project
                && project.matchesPanelTarget(context.identity)
                && model.matchesPanelTarget(context.identity)
                && model.isCurrent(target, requiresStableHead: action != .drop)
        }
        let dialog = GitStashDialog(action: action, stash: stash, target: target)
        dialog.alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, isCurrent() else { return }
            performOperation(.moreMenu) {
                model.actOnStash(stash, action: action, reinstateIndex: dialog.reinstateIndex.state == .on,
                    branchName: dialog.name.stringValue, target: target,
                    prepare: {
                        await project.saveBeforeGitAction(repository: target.repository, scope: target.scope, isCurrent: isCurrent)
                    }, isCurrentTarget: {
                        isCurrent() && (action == .drop || project.canRunGitAction(repository: target.repository, scope: target.scope))
                    }, completion: { _ in
                        if action != .drop { project.reloadAfterGitAction(repository: target.repository, scope: target.scope) }
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
                return await project.saveBeforeGitAction(
                    repository: target.repository, scope: target.scope, isCurrent: isCurrent)
            }
            let validate: @MainActor () -> Bool = {
                isCurrent() && (!writesWorktree || project.canRunGitAction(repository: target.repository, scope: target.scope))
            }
            let completion: @MainActor (Bool) -> Void = { _ in
                project.reloadAfterGitAction(repository: target.repository, scope: target.scope)
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

    private func entries(for kind: GitEntryRow.Kind) -> [GitStatusModel.Entry] {
        switch kind {
        case .merge: model.mergeEntries
        case .staged: model.stagedEntries
        case .unstaged: model.changedEntries
        }
    }

    @ViewBuilder
    private func directoryMenu(path: String, kind: GitEntryRow.Kind) -> some View {
        let selected = entries(for: kind).filter { $0.path.hasPrefix(path + "/") }
        if kind == .staged {
            Button(String(localized: "Unstage Changes", table: "Sidebar")) {
                performOperation(.unstageAll) { model.unstageEntries(selected) }
            }.disabled(model.isBusy)
        } else {
            Button(kind == .merge ? String(localized: "Mark Resolved (Stage)", table: "Sidebar")
                   : String(localized: "Stage Changes", table: "Sidebar")) {
                performOperation(.stageAll) { model.stageEntries(selected) }
            }.disabled(model.isBusy)
            if kind == .unstaged {
                Button(String(localized: "Discard Changes…", table: "Sidebar")) {
                    requestDiscard(selected)
                }.disabled(model.isBusy)
                Button(String(localized: "Add to .gitignore", table: "Git")) {
                    ignorePaths([path], isDirectory: true)
                }.disabled(model.isBusy)
            }
        }
    }

    private func requestDiscard(_ entries: [GitStatusModel.Entry]) {
        if remoteName != nil {
            prepareRemoteDiscard(entries, all: true)
        } else {
            pendingDiscardAll = model.prepareLocalDiscard(entries)
            confirmDiscardAll = !pendingDiscardAll.isEmpty
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
        guard model.isCurrent(entry), let project, let hash = model.headOID else { return }
        project.openHistoricalDiff(repoRoot: model.repoRoot,
            path: (entry.staged == "R" || entry.staged == "C") ? entry.origPath ?? entry.path : entry.path,
            source: .revision(hash: hash), origPath: nil)
    }

    /// The machine a discard would act on, or nil while local.
    private var remoteName: String? {
        sshHost ?? session?.location.remoteConnection?.displayName
    }

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
        if remoteName != nil {
            prepareRemoteDiscard(model.changedEntries, all: true)
        } else {
            pendingDiscardAll = model.prepareLocalDiscard(model.changedEntries)
            confirmDiscardAll = !pendingDiscardAll.isEmpty
        }
    }

    private func prepareRemoteDiscard(_ entries: [GitStatusModel.Entry], all: Bool) {
        guard !preparingDiscard, !entries.isEmpty else { return }
        preparingDiscard = true
        Task {
            defer { preparingDiscard = false }
            do {
                let snapshots = try await model.prepareRemoteDiscard(entries)
                if all {
                    pendingDiscardAll = snapshots
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
            .tint(Color(nsColor: Theme.accent))
            .disabled(model.rootPath.isEmpty || model.isBusy)
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private func statusWarning(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(String(localized: "Git Status Unavailable", table: "Sidebar"))
                    .panelFont(size: 10.5, weight: .medium)
                Spacer(minLength: 4)
                Button(String(localized: "Retry", table: "Sidebar")) { model.refresh() }
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
                .foregroundStyle(Color(red: 0.88, green: 0.42, blue: 0.36))
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
            Button(String(localized: "Retry", table: "Sidebar")) { model.refresh() }
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
        confirmDiscardAll = false
        mergeCollapsed = false
        stagedCollapsed = false
        changesCollapsed = false
        historyCollapsed = false
        stashesCollapsed = false
        expandedCommitIDs.removeAll()
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
private final class GitArchiveFormatSelection: NSObject {
    let accessory: NSStackView
    private let choice = NSPopUpButton()
    private weak var panel: NSSavePanel?

    var format: GitStatusModel.ArchiveFormat {
        choice.indexOfSelectedItem == 1 ? .tar : .zip
    }

    init(panel: NSSavePanel) {
        self.panel = panel
        choice.addItems(withTitles: ["ZIP (.zip)", "TAR (.tar)"])
        choice.selectItem(at: 0)
        accessory = NSStackView(views: [
            NSTextField(labelWithString: String(localized: "Archive Format", table: "Git")), choice
        ])
        accessory.orientation = .horizontal
        accessory.spacing = 12
        accessory.frame = NSRect(x: 0, y: 0, width: 300, height: 34)
        super.init()
        choice.target = self
        choice.action = #selector(updateFormat)
    }

    @objc private func updateFormat() {
        guard let panel else { return }
        let extensionName = format.rawValue
        let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.allowedContentTypes = [
            format == .zip ? .zip : (UTType(filenameExtension: "tar") ?? UTType(importedAs: "public.tar-archive"))
        ]
        panel.nameFieldStringValue = name + "." + extensionName
    }
}

private struct GitEntryRow: View {
    enum Kind: String {
        case merge, staged, unstaged
    }

    let entry: GitStatusModel.Entry
    let displayRow: TreeDisplayModel.Row
    let kind: Kind
    let showDirectory: Bool
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
            accessibilityHint: kind == .merge
                ? String(localized: "Opens conflict changes", table: "Sidebar")
                : String(localized: "Opens changes", table: "Sidebar"),
            open: openDiff
        ) { active in
            if !disabled || isStageLoading || isUnstageLoading || isDiscardLoading {
                hoverActions
                    .opacity(isStageLoading || isUnstageLoading || isDiscardLoading
                             ? 1 : (active ? 1 : 0.55))
            }
        }
        .contextMenu { menu }
    }

    private var hoverActions: some View {
        HStack(spacing: 0) {
            switch kind {
            case .merge:
                rowButton(
                    "plus",
                    help: String(localized: "Mark Resolved (Stage)", table: "Sidebar"),
                    isLoading: isStageLoading,
                    action: stage
                )
            case .staged:
                rowButton(
                    "minus",
                    help: String(localized: "Unstage Changes", table: "Sidebar"),
                    isLoading: isUnstageLoading,
                    action: unstage
                )
            case .unstaged:
                rowButton(
                    "arrow.uturn.backward",
                    help: String(localized: "Discard Changes", table: "Sidebar"),
                    isLoading: isDiscardLoading,
                    action: discard
                )
                rowButton(
                    "plus",
                    help: String(localized: "Stage Changes", table: "Sidebar"),
                    isLoading: isStageLoading,
                    action: stage
                )
            }
        }
    }

    private func rowButton(
        _ systemImage: String,
        help: String,
        isLoading: Bool,
        action: @escaping () -> Void
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
