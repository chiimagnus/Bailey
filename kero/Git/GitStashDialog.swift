import AppKit

@MainActor
final class GitStashDialog {
    let alert = NSAlert()
    let reinstateIndex = NSButton(checkboxWithTitle: String(localized: "Reinstate Index", table: "Git"), target: nil, action: nil)
    let name = NSTextField()
    private var validator: GitNameFieldValidator?

    init(action: GitStatusModel.StashAction, stash: GitStatusModel.Stash,
         target: GitStatusModel.ActionTarget) {
        alert.messageText = action.title
        alert.informativeText = String(localized: "Repository \(target.scope): \(target.repository)", table: "Git")
            + "\n" + stash.selector + ": " + stash.message + "\n" + stash.oid
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        switch action {
        case .apply, .pop:
            controls.addArrangedSubview(reinstateIndex)
            alert.addButton(withTitle: action == .apply
                ? String(localized: "Yes, Apply Stash", table: "Git")
                : String(localized: "Yes, Pop Stash", table: "Git"))
        case .branch:
            name.placeholderString = String(localized: "Branch Name", table: "Git")
            name.setAccessibilityLabel(String(localized: "Branch Name", table: "Git"))
            name.widthAnchor.constraint(equalToConstant: 380).isActive = true
            controls.addArrangedSubview(name)
            alert.informativeText += "\n" + String(localized: "Checkout a new branch, restore this stash and remove it on success.", table: "Git")
            alert.addButton(withTitle: String(localized: "Create Branch", table: "Git"))
            let validator = GitNameFieldValidator(button: alert.buttons[0])
            name.delegate = validator
            self.validator = validator
            alert.buttons[0].isEnabled = false
            alert.window.initialFirstResponder = name
        case .drop:
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
