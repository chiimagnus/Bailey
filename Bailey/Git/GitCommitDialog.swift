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
