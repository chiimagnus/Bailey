import AppKit
import SwiftUI

// MARK: - Git panel

struct GitPanel: View {
    @ObservedObject private var settings = AppSettings.shared

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

    private struct FileFingerprint: Equatable {
        let exists: Bool
        let size: UInt64
        let modificationDate: Date?
        let fileNumber: UInt64?
        let symbolicLinkDestination: String?
    }

    private struct PendingDiscard {
        let entry: GitStatusModel.Entry
        let fingerprints: [String: FileFingerprint]
        let branch: String?
        let headOID: String?
        let scope: String
    }

    @ObservedObject var model: GitStatusModel
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
    @State private var pendingDiscard: PendingDiscard?
    @State private var pendingDiscardAll: [PendingDiscard] = []
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
    @State private var expandedCommitIDs: Set<String> = []
    @State private var filterText = ""
    @State private var showFilter = false
    @State private var operationExpanded = false
    @State private var operationTrigger: OperationTrigger?
    @Environment(\.panelFontScale) private var panelFontScale

    var body: some View {
        VStack(spacing: 0) {
            header
            operationFailureBanner

            if let statusError = model.statusError {
                statusFailure(statusError)
            } else if !model.isRepo {
                if model.isResolvingInitialStatus {
                    placeholder(icon: "arrow.clockwise", text: String(localized: "Finding repository…", table: "Sidebar"))
                } else {
                    notRepository
                }
            } else {
                trackingBar
                repositoryOperationBanner
                commitBox
                filterBar
                changeList
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
                if let pendingDiscard {
                    if remoteName != nil {
                        Task {
                            if await remoteDiscardSnapshotIsCurrent(pendingDiscard) {
                                performOperation(
                                    .entry(path: pendingDiscard.entry.path, operation: .discard)
                                ) { model.discard(pendingDiscard.entry) }
                            } else { model.cancelStaleDiscard() }
                        }
                    } else if discardSnapshotIsCurrent(pendingDiscard) {
                        performOperation(
                            .entry(path: pendingDiscard.entry.path, operation: .discard)
                        ) { model.discard(pendingDiscard.entry) }
                    } else { model.cancelStaleDiscard() }
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
                        var verified = !snapshot.isEmpty
                        for entry in snapshot where verified {
                            verified = await remoteDiscardSnapshotIsCurrent(entry)
                        }
                        if verified {
                            performOperation(.discardAll) {
                                model.discardChanges(snapshot.map(\.entry))
                            }
                        } else { model.cancelStaleDiscard() }
                    }
                } else if !snapshot.isEmpty && snapshot.allSatisfy(discardSnapshotIsCurrent) {
                    performOperation(.discardAll) {
                        model.discardChanges(snapshot.map(\.entry))
                    }
                } else { model.cancelStaleDiscard() }
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
                        performOperation(.branchMenu) {
                            model.switchBranch(to: branch)
                        }
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
            Button(String(localized: "Stash All Changes", table: "Sidebar")) {
                performOperation(.moreMenu) { model.stash(includeUntracked: true) }
            }
                .disabled(model.isBusy || model.totalChangeCount == 0)
            Button(
                model.stashCount == 1
                    ? String(localized: "Pop Stash", table: "Sidebar")
                    : String(localized: "Pop Stash (\(model.stashCount))", table: "Sidebar")
            ) {
                performOperation(.moreMenu, model.stashPop)
            }
            .disabled(model.isBusy || model.stashCount == 0)
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

    private func presentCreateBranchDialog() {
        guard !model.isBusy else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "Create New Branch", table: "Sidebar")
        alert.informativeText = String(localized: "Enter a name for the new branch.", table: "Sidebar")

        let field = NSTextField(string: "")
        field.placeholderString = String(localized: "Branch name", table: "Sidebar")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field

        let create = alert.addButton(withTitle: String(localized: "Create", table: "Sidebar"))
        create.keyEquivalent = "\r"
        create.isEnabled = false
        let cancel = alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
        cancel.keyEquivalent = "\u{1b}"

        let validator = NonemptyTextFieldValidator(button: create)
        field.delegate = validator
        alert.window.initialFirstResponder = field

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            _ = validator // Keep the field delegate alive until the sheet closes.
            guard response == .alertFirstButtonReturn else { return }
            performOperation(.branchMenu) {
                model.createBranch(named: field.stringValue)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
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
                        actionsDisabled: model.isBusy
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
                        actionsDisabled: model.isBusy
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
                        actionsDisabled: model.isBusy
                    )
                    if !changesCollapsed {
                        changedFileRows(filteredChangedEntries, kind: .unstaged)
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
                            expandedCommitIDs: $expandedCommitIDs,
                            collapsedFolders: collapsedFoldersBinding,
                            viewMode: settings.gitViewMode,
                            fontScale: panelFontScale,
                            hasMoreCommits: model.hasMoreRecentCommits,
                            isLoadingMore: model.isLoadingMoreCommits,
                            loadMore: model.loadMoreCommits,
                            openDiff: openCommitDiff
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
            stage: { performOperation(stageTrigger) { model.stage(entry) } },
            unstage: { performOperation(unstageTrigger) { model.unstage(entry) } },
            discard: {
                if remoteName == nil {
                    pendingDiscard = makePendingDiscard(entry)
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
        guard model.isCurrent(entry) else { return }
        let path = model.absolutePath(for: entry)
        guard remoteName != nil || FileManager.default.fileExists(atPath: path) else { return }
        openFile(path)
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

    private func makePendingDiscard(_ entry: GitStatusModel.Entry) -> PendingDiscard {
        var paths = [entry.path]
        if entry.isWorktreeRename, let original = entry.origPath {
            paths.append(original)
        }
        return PendingDiscard(
            entry: entry,
            fingerprints: Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, fileFingerprint(at: absolutePath(path, for: entry)))
            }),
            branch: model.branch,
            headOID: model.headOID,
            scope: model.currentScope
        )
    }

    private func discardSnapshotIsCurrent(_ pending: PendingDiscard) -> Bool {
        model.isCurrent(pending.entry)
            && model.currentScope == pending.scope
            && model.branch == pending.branch
            && model.headOID == pending.headOID
            && model.changedEntries.contains(pending.entry)
            && pending.fingerprints.allSatisfy { path, fingerprint in
                fileFingerprint(at: absolutePath(path, for: pending.entry)) == fingerprint
            }
    }

    private func absolutePath(_ path: String, for entry: GitStatusModel.Entry) -> String {
        let root = entry.repositoryRoot.isEmpty ? model.repoRoot : entry.repositoryRoot
        return (root as NSString).appendingPathComponent(path)
    }

    private func fileFingerprint(at path: String) -> FileFingerprint {
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

    private func requestDiscardAll() {
        if remoteName != nil {
            prepareRemoteDiscard(model.changedEntries, all: true)
        } else {
            pendingDiscardAll = model.changedEntries.map(makePendingDiscard)
            confirmDiscardAll = !pendingDiscardAll.isEmpty
        }
    }

    private var remoteBackend: WorkspaceBackend? {
        if let sshHost { return SSHHostWorkspaces.backend(for: sshHost) }
        return session?.location.remoteConnection?.workspaceBackend
    }

    private func remoteFingerprint(at path: String, backend: WorkspaceBackend) async throws -> FileFingerprint {
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

    private func remotePendingDiscard(_ entry: GitStatusModel.Entry,
                                      backend: WorkspaceBackend) async throws -> PendingDiscard {
        var paths = [entry.path]
        if entry.isWorktreeRename, let original = entry.origPath { paths.append(original) }
        var fingerprints: [String: FileFingerprint] = [:]
        for path in paths {
            fingerprints[path] = try await remoteFingerprint(
                at: absolutePath(path, for: entry), backend: backend
            )
        }
        return PendingDiscard(
            entry: entry, fingerprints: fingerprints,
            branch: model.branch, headOID: model.headOID,
            scope: model.currentScope
        )
    }

    private func remoteDiscardSnapshotIsCurrent(_ pending: PendingDiscard) async -> Bool {
        guard let backend = remoteBackend,
              model.currentScope == pending.scope,
              model.isCurrent(pending.entry),
              model.branch == pending.branch,
              model.headOID == pending.headOID,
              model.changedEntries.contains(pending.entry)
        else { return false }
        for (path, fingerprint) in pending.fingerprints {
            guard let current = try? await remoteFingerprint(
                at: absolutePath(path, for: pending.entry), backend: backend
            ), current == fingerprint else { return false }
        }
        return model.currentScope == pending.scope && model.isCurrent(pending.entry)
    }

    private func prepareRemoteDiscard(_ entries: [GitStatusModel.Entry], all: Bool) {
        guard !preparingDiscard, let backend = remoteBackend, !entries.isEmpty else { return }
        preparingDiscard = true
        let scope = model.currentScope
        Task {
            defer { preparingDiscard = false }
            do {
                var snapshots: [PendingDiscard] = []
                for entry in entries {
                    snapshots.append(try await remotePendingDiscard(entry, backend: backend))
                }
                guard model.currentScope == scope,
                      entries.allSatisfy(model.isCurrent) else { return }
                if all {
                    pendingDiscardAll = snapshots
                    confirmDiscardAll = true
                } else {
                    pendingDiscard = snapshots.first
                }
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
        expandedCommitIDs.removeAll()
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class NonemptyTextFieldValidator: NSObject, NSTextFieldDelegate {
    private weak var button: NSButton?

    init(button: NSButton) {
        self.button = button
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        button?.isEnabled = !field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
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
