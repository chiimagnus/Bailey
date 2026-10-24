import AppKit

@MainActor
final class GitBranchDialog {
    enum Kind {
        case create(checkout: Bool)
        case rename
        case delete(remotes: [String])
        case push(remotes: [String], preferred: String?)
        case remoteCheckout
        case remoteFetch
        case remotePull
    }

    let alert = NSAlert()
    let name = NSTextField()
    let checkout = NSButton(checkboxWithTitle: String(localized: "Check out", table: "Git"), target: nil, action: nil)
    let forceDelete = NSButton(checkboxWithTitle: String(localized: "Force Delete", table: "Git"), target: nil, action: nil)
    let deleteRemotes = NSButton(checkboxWithTitle: String(localized: "Delete on Remote(s)", table: "Git"), target: nil, action: nil)
    let setUpstream = NSButton(checkboxWithTitle: String(localized: "Set Upstream", table: "Git"), target: nil, action: nil)
    let forceFetch = NSButton(checkboxWithTitle: String(localized: "Force Fetch", table: "Git"), target: nil, action: nil)
    let noFastForward = NSButton(checkboxWithTitle: String(localized: "Create New Commit Even If Fast-Forward", table: "Git"), target: nil, action: nil)
    let squash = NSButton(checkboxWithTitle: String(localized: "Squash", table: "Git"), target: nil, action: nil)
    let pushMode = NSPopUpButton()
    private(set) var remoteButtons: [(name: String, button: NSButton)] = []
    private var validator: GitNameFieldValidator?
    private var remoteValidator: GitRemoteSelectionValidator?

    var selectedRemotes: [String] {
        remoteButtons.compactMap { $0.button.state == .on ? $0.name : nil }
    }

    var selectedPushMode: GitStatusModel.BranchPushMode {
        GitStatusModel.BranchPushMode.allCases[max(0, pushMode.indexOfSelectedItem)]
    }

    init(kind: Kind, title: String, detail: String, initialName: String = "") {
        alert.messageText = title
        alert.informativeText = detail
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        switch kind {
        case .create(let selected):
            addNameField(to: stack, initialName: initialName)
            checkout.state = selected ? .on : .off
            stack.addArrangedSubview(checkout)
            alert.addButton(withTitle: String(localized: "Create Branch", table: "Git"))
        case .rename:
            addNameField(to: stack, initialName: initialName)
            alert.addButton(withTitle: String(localized: "Rename Branch", table: "Git"))
        case .remoteCheckout:
            addNameField(to: stack, initialName: initialName)
            alert.addButton(withTitle: String(localized: "Checkout Branch", table: "Git"))
        case .remoteFetch:
            stack.addArrangedSubview(forceFetch)
            alert.addButton(withTitle: String(localized: "Yes, Fetch", table: "Git"))
        case .remotePull:
            stack.addArrangedSubview(noFastForward)
            stack.addArrangedSubview(squash)
            alert.addButton(withTitle: String(localized: "Yes, Pull", table: "Git"))
        case .delete(let remotes):
            stack.addArrangedSubview(forceDelete)
            if !remotes.isEmpty {
                deleteRemotes.toolTip = remotes.joined(separator: ", ")
                stack.addArrangedSubview(deleteRemotes)
                stack.addArrangedSubview(NSTextField(wrappingLabelWithString: remotes.joined(separator: ", ")))
            }
            alert.addButton(withTitle: String(localized: "Yes, Delete", table: "Git"))
        case .push(let remotes, let preferred):
            if remotes.isEmpty {
                alert.informativeText = String(localized: "No Git remote is configured", table: "Git")
            }
            setUpstream.state = .on
            stack.addArrangedSubview(setUpstream)
            stack.addArrangedSubview(NSTextField(labelWithString: String(localized: "Push Mode", table: "Git")))
            for title in [
                String(localized: "Normal", table: "Git"),
                String(localized: "Force With Lease", table: "Git"),
                String(localized: "Force", table: "Git"),
            ] { pushMode.addItem(withTitle: title) }
            pushMode.selectItem(at: 0)
            stack.addArrangedSubview(pushMode)
            stack.addArrangedSubview(NSTextField(labelWithString: String(localized: "Remotes", table: "Git")))
            for remote in remotes {
                let button = NSButton(checkboxWithTitle: remote, target: nil, action: nil)
                button.state = remote == preferred ? .on : .off
                remoteButtons.append((remote, button))
                stack.addArrangedSubview(button)
            }
            alert.addButton(withTitle: String(localized: "Yes, Push", table: "Git"))
        }

        let cancel = alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
        cancel.keyEquivalent = "\u{1b}"
        alert.buttons[0].keyEquivalent = "\r"
        if !stack.arrangedSubviews.isEmpty {
            stack.frame = NSRect(x: 0, y: 0, width: 375, height: stack.fittingSize.height)
            alert.accessoryView = stack
        }
        if case .create = kind { attachValidator() }
        if case .rename = kind { attachValidator() }
        if case .remoteCheckout = kind { attachValidator() }
        if case .push = kind {
            let validator = GitRemoteSelectionValidator(
                button: alert.buttons[0], options: remoteButtons.map(\.button)
            )
            remoteValidator = validator
            for item in remoteButtons {
                item.button.target = validator
                item.button.action = #selector(GitRemoteSelectionValidator.update)
            }
            validator.update()
        }
    }

    private func addNameField(to stack: NSStackView, initialName: String) {
        stack.addArrangedSubview(NSTextField(labelWithString: String(localized: "Branch name", table: "Sidebar")))
        name.stringValue = initialName
        name.placeholderString = String(localized: "Branch name", table: "Sidebar")
        name.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        name.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        stack.addArrangedSubview(name)
        alert.window.initialFirstResponder = name
    }

    private func attachValidator() {
        let validator = GitNameFieldValidator(button: alert.buttons[0])
        name.delegate = validator
        self.validator = validator
        alert.buttons[0].isEnabled = !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
final class GitRemoteSelectionValidator: NSObject {
    private weak var button: NSButton?
    private let options: [NSButton]

    init(button: NSButton, options: [NSButton]) {
        self.button = button
        self.options = options
    }

    @objc func update() {
        button?.isEnabled = options.contains(where: { $0.state == .on })
    }
}

@MainActor
final class GitNameFieldValidator: NSObject, NSTextFieldDelegate {
    private weak var button: NSButton?

    init(button: NSButton) { self.button = button }

    func controlTextDidChange(_ notification: Notification) {
        guard let text = notification.object as? NSTextField else { return }
        button?.isEnabled = !text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
