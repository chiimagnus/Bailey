import AppKit

@MainActor
final class GitCommitDialog {
    let alert = NSAlert()
    let parent = NSPopUpButton()
    let recordOrigin = NSButton(checkboxWithTitle: String(localized: "Record Origin", table: "Git"), target: nil, action: nil)
    let noCommit = NSButton(checkboxWithTitle: String(localized: "No Commit", table: "Git"), target: nil, action: nil)
    let noFastForward = NSButton(checkboxWithTitle: String(localized: "Create Commit Even If Fast-forward Is Possible", table: "Git"), target: nil, action: nil)
    let squash = NSButton(checkboxWithTitle: String(localized: "Squash Commits", table: "Git"), target: nil, action: nil)
    let alwaysAccept = NSButton(checkboxWithTitle: String(localized: "Always Accept", table: "Git"), target: nil, action: nil)
    let interactive = NSButton(checkboxWithTitle: String(localized: "Launch Interactive Rebase in New Terminal", table: "Git"), target: nil, action: nil)
    let ignoreDate = NSButton(checkboxWithTitle: String(localized: "Ignore Date", table: "Git"), target: nil, action: nil)
    let resetMode = NSPopUpButton()

    init(action: GitStatusModel.CommitAction, commit: GitStatusModel.RecentCommit,
         target: GitStatusModel.ActionTarget) {
        alert.messageText = action.title
        alert.informativeText = String(localized: "Repository \(target.scope): \(target.repository)\nCommit \(commit.shortHash): \(commit.subject)", table: "Git")
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        switch action {
        case .checkout:
            alert.informativeText += "\n" + String(localized: "Checkout leaves you in detached HEAD. Create a branch to keep new commits.", table: "Git")
            controls.addArrangedSubview(alwaysAccept)
            alert.addButton(withTitle: String(localized: "Yes, Checkout", table: "Git"))
        case .cherryPick, .revert:
            if commit.parentHashes.count > 1 {
                controls.addArrangedSubview(NSTextField(labelWithString: String(localized: "Mainline Parent", table: "Git")))
                for (index, hash) in commit.parentHashes.enumerated() {
                    parent.addItem(withTitle: "\(index + 1): \(hash.prefix(8))")
                }
                controls.addArrangedSubview(parent)
            }
            if action == .cherryPick {
                controls.addArrangedSubview(recordOrigin)
                controls.addArrangedSubview(noCommit)
                alert.addButton(withTitle: String(localized: "Yes, Cherry Pick", table: "Git"))
            } else {
                alert.addButton(withTitle: String(localized: "Yes, Revert", table: "Git"))
            }
        case .merge:
            noFastForward.state = .on
            controls.addArrangedSubview(noFastForward)
            controls.addArrangedSubview(squash)
            controls.addArrangedSubview(noCommit)
            alert.informativeText += "\n" + String(localized: "No Commit does not prevent a fast-forward when that is allowed.", table: "Git")
            alert.addButton(withTitle: String(localized: "Yes, Merge", table: "Git"))
        case .rebase:
            ignoreDate.state = .on
            controls.addArrangedSubview(interactive)
            controls.addArrangedSubview(ignoreDate)
            alert.informativeText += "\n" + String(localized: "Ignore Date applies only to non-interactive rebase.", table: "Git")
            alert.addButton(withTitle: String(localized: "Yes, Rebase", table: "Git"))
        case .reset:
            for mode in GitStatusModel.ResetMode.allCases { resetMode.addItem(withTitle: mode.title) }
            resetMode.selectItem(at: 1)
            controls.addArrangedSubview(resetMode)
            alert.informativeText += "\n" + String(localized: "Hard permanently overwrites tracked files and may delete untracked paths obstructing their restoration. Ordinary untracked files are kept.", table: "Git")
            alert.addButton(withTitle: String(localized: "Yes, Reset", table: "Git"))
        case .drop:
            alert.informativeText += "\n" + String(localized: "This rewrites the current HEAD history to remove the selected commit. Your Git rebase configuration still applies.", table: "Git")
            alert.addButton(withTitle: String(localized: "Yes, Drop", table: "Git"))
        }
        alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        if !controls.arrangedSubviews.isEmpty {
            controls.frame = NSRect(x: 0, y: 0, width: 380, height: controls.fittingSize.height)
            alert.accessoryView = controls
        }
    }
}

@MainActor
final class GitBatchCommitDialog {
    let alert = NSAlert()
    let recordOrigin = NSButton(
        checkboxWithTitle: String(localized: "Record Origin", table: "Git"),
        target: nil, action: nil
    )
    let noCommit = NSButton(
        checkboxWithTitle: String(localized: "No Commit", table: "Git"),
        target: nil, action: nil
    )

    init(action: GitStatusModel.CommitBatchAction, commits: [GitStatusModel.RecentCommit],
         target: GitStatusModel.ActionTarget) {
        precondition(commits.count >= 2)
        alert.messageText = action.title
        let summary = commits.prefix(5).map { "\($0.shortHash)  \($0.subject)" }
            .joined(separator: "\n")
        let remaining = commits.count > 5 ? "\n…" : ""
        alert.informativeText = String(
            localized: "Repository \(target.scope): \(target.repository)", table: "Git"
        ) + "\n" + String(
            localized: "Selected \(commits.count) commits", table: "Git"
        ) + "\n" + summary + remaining
        switch action {
        case .cherryPick:
            let controls = NSStackView(views: [recordOrigin, noCommit])
            controls.orientation = .vertical
            controls.alignment = .leading
            controls.spacing = 8
            controls.frame = NSRect(x: 0, y: 0, width: 350, height: controls.fittingSize.height)
            alert.accessoryView = controls
            alert.addButton(withTitle: String(localized: "Yes, Cherry Pick Selected", table: "Git"))
        case .revert:
            alert.addButton(withTitle: String(localized: "Yes, Revert Selected", table: "Git"))
        case .drop:
            alert.informativeText += "\n" + String(localized:
                "This rewrites local history. Remote branches and tags are not force-pushed.", table: "Git")
            alert.addButton(withTitle: String(localized: "Yes, Drop Selected", table: "Git"))
        }
        alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
    }
}

@MainActor
final class GitSquashDialog: NSObject, NSTextViewDelegate {
    let alert = NSAlert()
    let message = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 112))

    var commitMessage: String {
        message.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(count: Int, suggestedMessage: String, branch: String?) {
        precondition(count >= 2)
        super.init()
        alert.messageText = String(localized: "Squash Selected Commits…", table: "Git")
        let countLabel = String(localized: "Combine \(count) selected commits into one.", table: "Git",
                                comment: "Number of commits to rewrite.")
        let risk = String(localized:
            "This rewrites local history. Remote branches and tags are not force-pushed.", table: "Git")
        let branchName = branch ?? String(localized: "Detached HEAD", table: "Git")
        alert.informativeText = branchName + "\n" + countLabel + "\n" + risk
        alert.addButton(withTitle: String(localized: "Yes, Squash", table: "Git"))
        alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))

        let label = NSTextField(labelWithString: String(localized: "New Commit Message", table: "Git"))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 112).isActive = true

        message.isRichText = false
        message.isAutomaticQuoteSubstitutionEnabled = false
        message.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        message.textContainer?.widthTracksTextView = true
        message.isVerticallyResizable = true
        message.autoresizingMask = [.width]
        message.string = suggestedMessage
        message.delegate = self
        message.setAccessibilityIdentifier("bailey.git.squash.message")
        scroll.documentView = message

        let content = NSStackView(views: [label, scroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.frame = NSRect(x: 0, y: 0, width: 380, height: 140)
        alert.accessoryView = content
        alert.buttons[0].isEnabled = !commitMessage.isEmpty
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = message
    }

    func textDidChange(_ notification: Notification) {
        alert.buttons[0].isEnabled = !commitMessage.isEmpty
    }
}
