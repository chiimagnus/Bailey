import AppKit

@MainActor
final class GitTagDialog: NSObject {
    enum Kind {
        case create(remotes: [String])
        case delete(remotes: [String])
        case push(remotes: [String], preferred: String?)
    }

    let alert = NSAlert()
    let name = NSTextField()
    let tagType = NSPopUpButton()
    let message = NSTextView()
    let pushToRemote = NSButton(checkboxWithTitle:
        String(localized: "Push to Remote", table: "Git"), target: nil, action: nil)
    let deleteOnRemote = NSButton(checkboxWithTitle:
        String(localized: "Also Delete on Remote", table: "Git"), target: nil, action: nil)
    let remoteSelection = NSPopUpButton()
    private(set) var remoteButtons: [(name: String, button: NSButton)] = []
    private var nameValidator: GitNameFieldValidator?
    private var remoteValidator: GitRemoteSelectionValidator?
    private var messageLabel = NSTextField(labelWithString: String(localized: "Tag Message", table: "Git"))

    var selectedType: GitStatusModel.TagType {
        tagType.indexOfSelectedItem == 1 ? .lightweight : .annotated
    }

    var selectedCreateRemote: String? {
        switch createRemotes.count {
        case 0: nil
        case 1: pushToRemote.state == .on ? createRemotes[0] : nil
        default: remoteSelection.indexOfSelectedItem > 0
            ? createRemotes[remoteSelection.indexOfSelectedItem - 1] : nil
        }
    }

    var selectedDeleteRemote: String? {
        switch deleteRemotes.count {
        case 0: nil
        case 1: deleteOnRemote.state == .on ? deleteRemotes[0] : nil
        default: remoteSelection.indexOfSelectedItem > 0
            ? deleteRemotes[remoteSelection.indexOfSelectedItem - 1] : nil
        }
    }

    var selectedPushRemotes: [String] {
        if pushRemotes.count == 1 { return pushRemotes }
        return remoteButtons.compactMap { $0.button.state == .on ? $0.name : nil }
    }

    private var createRemotes: [String] = []
    private var deleteRemotes: [String] = []
    private var pushRemotes: [String] = []

    init(kind: Kind, title: String, detail: String,
         initialName: String = "", initialType: GitStatusModel.TagType = .annotated,
         initialMessage: String = "", initialRemote: String? = nil) {
        super.init()
        alert.messageText = title
        alert.informativeText = detail
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7

        switch kind {
        case .create(let remotes):
            createRemotes = remotes
            name.stringValue = initialName
            name.placeholderString = String(localized: "Tag name", table: "Git")
            stack.addArrangedSubview(NSTextField(labelWithString:
                String(localized: "Tag name", table: "Git")))
            name.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
            stack.addArrangedSubview(name)
            stack.addArrangedSubview(NSTextField(labelWithString:
                String(localized: "Tag Type", table: "Git")))
            tagType.addItems(withTitles: [
                String(localized: "Annotated", table: "Git"),
                String(localized: "Lightweight", table: "Git")
            ])
            tagType.selectItem(at: initialType == .lightweight ? 1 : 0)
            stack.addArrangedSubview(tagType)
            stack.addArrangedSubview(messageLabel)
            message.string = initialMessage
            message.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            message.isRichText = false
            message.isVerticallyResizable = true
            message.minSize = NSSize(width: 0, height: 65)
            let scroll = NSScrollView()
            scroll.documentView = message
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.widthAnchor.constraint(equalToConstant: 350).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 74).isActive = true
            stack.addArrangedSubview(scroll)

            if remotes.count == 1 {
                pushToRemote.state = initialRemote == remotes[0] ? .on : .off
                stack.addArrangedSubview(pushToRemote)
            } else if remotes.count > 1 {
                stack.addArrangedSubview(NSTextField(labelWithString:
                    String(localized: "Push to Remote", table: "Git")))
                remoteSelection.addItems(withTitles: [
                    String(localized: "Don't Push to Any Remote", table: "Git")
                ] + remotes)
                let selected = initialRemote.flatMap(remotes.firstIndex(of:)).map { $0 + 1 } ?? 0
                remoteSelection.selectItem(at: selected)
                stack.addArrangedSubview(remoteSelection)
            }
            alert.addButton(withTitle: String(localized: "Add Tag", table: "Git"))
            tagType.target = self
            tagType.action = #selector(updateType)
            let validator = GitNameFieldValidator(button: alert.buttons[0])
            name.delegate = validator
            nameValidator = validator
            alert.buttons[0].isEnabled = !initialName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            alert.window.initialFirstResponder = name
            updateType()

        case .delete(let remotes):
            deleteRemotes = remotes
            if remotes.count == 1 {
                stack.addArrangedSubview(deleteOnRemote)
            } else if remotes.count > 1 {
                stack.addArrangedSubview(NSTextField(labelWithString:
                    String(localized: "Delete on Remote", table: "Git")))
                remoteSelection.addItems(withTitles: [
                    String(localized: "Don't Delete on Any Remote", table: "Git")
                ] + remotes)
                remoteSelection.selectItem(at: 0)
                stack.addArrangedSubview(remoteSelection)
            }
            alert.addButton(withTitle: String(localized: "Yes, Delete", table: "Git"))

        case .push(let remotes, let preferred):
            pushRemotes = remotes
            if remotes.count > 1 {
                stack.addArrangedSubview(NSTextField(labelWithString:
                    String(localized: "Remotes", table: "Git")))
                for remote in remotes {
                    let button = NSButton(checkboxWithTitle: remote, target: nil, action: nil)
                    button.state = preferred == remote ? .on : .off
                    remoteButtons.append((remote, button))
                    stack.addArrangedSubview(button)
                }
            }
            alert.addButton(withTitle: String(localized: "Yes, Push", table: "Git"))
            if remotes.count != 1 {
                let validator = GitRemoteSelectionValidator(
                    button: alert.buttons[0], options: remoteButtons.map(\.button))
                remoteValidator = validator
                for item in remoteButtons {
                    item.button.target = validator
                    item.button.action = #selector(GitRemoteSelectionValidator.update)
                }
                validator.update()
            }
        }

        let cancel = alert.addButton(withTitle: String(localized: "Cancel", table: "Sidebar"))
        cancel.keyEquivalent = "\u{1b}"
        alert.buttons[0].keyEquivalent = "\r"
        if !stack.arrangedSubviews.isEmpty {
            stack.frame = NSRect(x: 0, y: 0, width: 380, height: stack.fittingSize.height)
            alert.accessoryView = stack
        }
    }

    @objc private func updateType() {
        let enabled = selectedType == .annotated
        message.isEditable = enabled
        message.isSelectable = enabled
        messageLabel.isEnabled = enabled
    }
}
