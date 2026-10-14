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
