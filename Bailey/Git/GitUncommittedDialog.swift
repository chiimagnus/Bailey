import AppKit

@MainActor
final class GitUncommittedDialog {
    enum Action { case stash, reset, clean }
    let alert = NSAlert()
    let message = NSTextField(string: "")
    let includeUntracked = NSButton(checkboxWithTitle: String(localized: "Include Untracked Files", table: "Git"), target: nil, action: nil)
    let directories = NSButton(checkboxWithTitle: String(localized: "Clean Untracked Directories", table: "Git"), target: nil, action: nil)
    let resetMode = NSPopUpButton()

    init(action: Action, target: GitStatusModel.ActionTarget) {
        alert.informativeText = String(localized: "Repository \(target.scope): \(target.repository)", table: "Git")
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        switch action {
        case .stash:
            alert.messageText = String(localized: "Stash…", table: "Git")
            message.placeholderString = String(localized: "Message (optional)", table: "Git")
            message.setAccessibilityLabel(String(localized: "Message (optional)", table: "Git"))
            message.widthAnchor.constraint(equalToConstant: 380).isActive = true
            includeUntracked.state = .on
            controls.addArrangedSubview(message)
            controls.addArrangedSubview(includeUntracked)
            alert.addButton(withTitle: String(localized: "Yes, Stash", table: "Git"))
        case .reset:
            alert.messageText = String(localized: "Reset…", table: "Git")
            for mode in [GitStatusModel.ResetMode.mixed, .hard] { resetMode.addItem(withTitle: mode.title) }
            resetMode.setAccessibilityLabel(String(localized: "Reset Mode", table: "Git"))
            controls.addArrangedSubview(resetMode)
            alert.informativeText += "\n" + String(localized: "Hard permanently overwrites tracked files and may delete untracked paths obstructing their restoration. Ordinary untracked files are kept.", table: "Git")
            alert.addButton(withTitle: String(localized: "Yes, Reset", table: "Git"))
        case .clean:
            alert.messageText = String(localized: "Clean…", table: "Git")
            alert.informativeText += "\n" + String(localized: "Permanently delete untracked files, including directories when selected. Ignored files are kept. This does not move files to the Trash.", table: "Git")
            directories.state = .on
            controls.addArrangedSubview(directories)
            alert.addButton(withTitle: String(localized: "Yes, Clean", table: "Git"))
        }
        alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
        controls.frame = NSRect(x: 0, y: 0, width: 380, height: controls.fittingSize.height)
        alert.accessoryView = controls
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        if action == .stash { alert.window.initialFirstResponder = message }
    }
}
