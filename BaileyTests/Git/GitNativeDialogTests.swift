import AppKit
import XCTest
@testable import Bailey

@MainActor
final class GitNativeDialogTests: XCTestCase {
    private var target: GitStatusModel.ActionTarget { GitStatusModel().actionTarget() }

    private func changed(_ field: NSTextField) {
        field.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
    }

    func testBranchNameFieldsUseRealNativeValidationAndKeepCheckoutDefaults() {
        let current = GitBranchDialog(kind: .create(checkout: true),
            title: "Create", detail: "HEAD")
        XCTAssertEqual(current.checkout.state, .on)
        XCTAssertFalse(current.alert.buttons[0].isEnabled)
        XCTAssertTrue(current.alert.window.initialFirstResponder === current.name)
        XCTAssertEqual(current.alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(current.alert.buttons[1].keyEquivalent, "\u{1b}")
        current.name.stringValue = "   "
        changed(current.name)
        XCTAssertFalse(current.alert.buttons[0].isEnabled)
        current.name.stringValue = "修复/feature-β"
        changed(current.name)
        XCTAssertTrue(current.alert.buttons[0].isEnabled)

        let historical = GitBranchDialog(kind: .create(checkout: false),
            title: "Historical", detail: "Selected commit", initialName: "retry-name")
        XCTAssertEqual(historical.checkout.state, .off)
        XCTAssertEqual(historical.name.stringValue, "retry-name")
        XCTAssertTrue(historical.alert.buttons[0].isEnabled)

        let rename = GitBranchDialog(kind: .rename,
            title: "Rename", detail: "main", initialName: "main")
        XCTAssertTrue(rename.alert.buttons[0].isEnabled)
        rename.name.stringValue = " \t "
        changed(rename.name)
        XCTAssertFalse(rename.alert.buttons[0].isEnabled)
        let checkout = GitBranchDialog(kind: .remoteCheckout,
            title: "Remote", detail: "origin/topic", initialName: "topic")
        XCTAssertEqual(checkout.name.stringValue, "topic")
        XCTAssertTrue(checkout.alert.buttons[0].isEnabled)
        checkout.name.stringValue = ""
        changed(checkout.name)
        XCTAssertFalse(checkout.alert.buttons[0].isEnabled)
    }

    func testBranchPushUsesActualRemoteButtonTargetsAndSelectedMode() {
        let offline = GitBranchDialog(kind: .push(remotes: [], preferred: nil),
            title: "Push", detail: "No remote")
        XCTAssertFalse(offline.alert.buttons[0].isEnabled)
        XCTAssertEqual(offline.alert.informativeText,
                       String(localized: "No Git remote is configured", table: "Git"))
        XCTAssertTrue(offline.selectedRemotes.isEmpty)

        let dialog = GitBranchDialog(kind: .push(
            remotes: ["origin", "backup"], preferred: "backup"
        ), title: "Push", detail: "main")
        XCTAssertTrue(dialog.alert.buttons[0].isEnabled)
        XCTAssertEqual(dialog.selectedRemotes, ["backup"])
        XCTAssertEqual(dialog.setUpstream.state, .on)
        XCTAssertEqual(dialog.selectedPushMode, .normal)
        dialog.pushMode.selectItem(at: 1)
        XCTAssertEqual(dialog.selectedPushMode, .forceWithLease)
        dialog.pushMode.selectItem(at: 2)
        XCTAssertEqual(dialog.selectedPushMode, .force)
        for option in dialog.remoteButtons {
            option.button.state = .off
            XCTAssertTrue(option.button.sendAction(option.button.action, to: option.button.target))
        }
        XCTAssertFalse(dialog.alert.buttons[0].isEnabled)
        XCTAssertTrue(dialog.selectedRemotes.isEmpty)
        dialog.remoteButtons[0].button.state = .on
        XCTAssertTrue(dialog.remoteButtons[0].button.sendAction(
            dialog.remoteButtons[0].button.action, to: dialog.remoteButtons[0].button.target
        ))
        XCTAssertEqual(dialog.selectedRemotes, ["origin"])
        XCTAssertTrue(dialog.alert.buttons[0].isEnabled)
    }

    func testBranchDeleteFetchAndPullKeepNonDestructiveNativeDefaults() {
        let delete = GitBranchDialog(kind: .delete(remotes: ["origin"]),
            title: "Delete", detail: "topic")
        XCTAssertEqual(delete.forceDelete.state, .off)
        XCTAssertEqual(delete.deleteRemotes.state, .off)
        delete.deleteRemotes.state = .on
        XCTAssertEqual(delete.deleteRemotes.state, .on)

        let fetch = GitBranchDialog(kind: .remoteFetch,
            title: "Fetch", detail: "origin/topic")
        XCTAssertEqual(fetch.forceFetch.state, .off)
        let pull = GitBranchDialog(kind: .remotePull,
            title: "Pull", detail: "origin/topic")
        XCTAssertEqual(pull.noFastForward.state, .off)
        XCTAssertEqual(pull.squash.state, .off)
        XCTAssertEqual(pull.alert.buttons[1].keyEquivalent, "\u{1b}")
    }

    func testTagCreatePreservesAnnotationAndChoosesOnlyExplicitRemote() {
        let noRemote = GitTagDialog(kind: .create(remotes: []),
            title: "Add", detail: "HEAD")
        XCTAssertFalse(noRemote.alert.buttons[0].isEnabled)
        XCTAssertNil(noRemote.selectedCreateRemote)

        let single = GitTagDialog(kind: .create(remotes: ["origin"]),
            title: "Add", detail: "HEAD",
            initialName: "v1", initialRemote: "origin")
        XCTAssertTrue(single.alert.buttons[0].isEnabled)
        XCTAssertEqual(single.pushToRemote.state, .on)
        XCTAssertEqual(single.selectedCreateRemote, "origin")
        single.pushToRemote.state = .off
        XCTAssertNil(single.selectedCreateRemote)

        let retry = GitTagDialog(kind: .create(remotes: ["origin", "backup"]),
            title: "Add", detail: "historical",
            initialName: "修复-v2", initialType: .annotated,
            initialMessage: "中文\n说明", initialRemote: "backup")
        XCTAssertEqual(retry.name.stringValue, "修复-v2")
        XCTAssertEqual(retry.selectedType, .annotated)
        XCTAssertEqual(retry.message.string, "中文\n说明")
        XCTAssertEqual(retry.selectedCreateRemote, "backup")
        XCTAssertTrue(retry.message.isEditable)
        XCTAssertTrue(retry.alert.buttons[0].isEnabled)
        retry.tagType.selectItem(at: 1)
        XCTAssertTrue(retry.tagType.sendAction(retry.tagType.action, to: retry.tagType.target))
        XCTAssertEqual(retry.selectedType, .lightweight)
        XCTAssertFalse(retry.message.isEditable)
        retry.tagType.selectItem(at: 0)
        XCTAssertTrue(retry.tagType.sendAction(retry.tagType.action, to: retry.tagType.target))
        XCTAssertTrue(retry.message.isEditable)
        retry.remoteSelection.selectItem(at: 0)
        XCTAssertNil(retry.selectedCreateRemote)
        retry.name.stringValue = "\n  "
        changed(retry.name)
        XCTAssertFalse(retry.alert.buttons[0].isEnabled)
        retry.name.stringValue = "next"
        changed(retry.name)
        XCTAssertTrue(retry.alert.buttons[0].isEnabled)
    }

    func testTagDeleteAndPushNeverSelectAnImplicitOtherRemote() {
        let local = GitTagDialog(kind: .delete(remotes: ["origin", "backup"]),
            title: "Delete", detail: "v1")
        XCTAssertNil(local.selectedDeleteRemote)
        local.remoteSelection.selectItem(at: 2)
        XCTAssertEqual(local.selectedDeleteRemote, "backup")
        local.remoteSelection.selectItem(at: 0)
        XCTAssertNil(local.selectedDeleteRemote)

        let single = GitTagDialog(kind: .delete(remotes: ["origin"]),
            title: "Delete", detail: "v1")
        XCTAssertNil(single.selectedDeleteRemote)
        single.deleteOnRemote.state = .on
        XCTAssertEqual(single.selectedDeleteRemote, "origin")

        let offline = GitTagDialog(kind: .push(remotes: [], preferred: nil),
            title: "Push", detail: "offline-tag")
        XCTAssertFalse(offline.alert.buttons[0].isEnabled)
        XCTAssertEqual(offline.selectedPushRemotes, [])
        XCTAssertEqual(offline.alert.informativeText,
                       String(localized: "No Git remote is configured", table: "Git"))

        let oneRemote = GitTagDialog(kind: .push(remotes: ["origin"], preferred: nil),
            title: "Push", detail: "v1")
        XCTAssertTrue(oneRemote.alert.buttons[0].isEnabled)
        XCTAssertEqual(oneRemote.selectedPushRemotes, ["origin"])

        let many = GitTagDialog(kind: .push(
            remotes: ["origin", "backup"], preferred: "backup"
        ), title: "Push", detail: "v1")
        XCTAssertEqual(many.selectedPushRemotes, ["backup"])
        for option in many.remoteButtons {
            option.button.state = .off
            XCTAssertTrue(option.button.sendAction(option.button.action, to: option.button.target))
        }
        XCTAssertFalse(many.alert.buttons[0].isEnabled)
        many.remoteButtons[0].button.state = .on
        XCTAssertTrue(many.remoteButtons[0].button.sendAction(
            many.remoteButtons[0].button.action, to: many.remoteButtons[0].button.target
        ))
        XCTAssertEqual(many.selectedPushRemotes, ["origin"])
        XCTAssertTrue(many.alert.buttons[0].isEnabled)
    }

    func testCommitActionsExposeNativeSafeDefaultsAndMergeParentSelection() {
        let commit = GitStatusModel.RecentCommit(
            hash: String(repeating: "a", count: 40), shortHash: "aaaaaaa",
            subject: "Merged", author: "Tester", date: .now,
            parentHashes: [String(repeating: "b", count: 40),
                           String(repeating: "c", count: 40)], references: [], files: []
        )
        for action in GitStatusModel.CommitAction.allCases {
            let dialog = GitCommitDialog(action: action, commit: commit, target: target)
            XCTAssertEqual(dialog.alert.buttons.count, 2, "\(action)")
            XCTAssertEqual(dialog.alert.buttons[0].keyEquivalent, "\r")
            XCTAssertEqual(dialog.alert.buttons[1].keyEquivalent, "\u{1b}")
            XCTAssertTrue(dialog.alert.informativeText.contains(commit.shortHash))
            switch action {
            case .checkout:
                XCTAssertEqual(dialog.alwaysAccept.state, .off)
            case .cherryPick:
                XCTAssertEqual(dialog.parent.numberOfItems, 2)
                XCTAssertEqual(dialog.parent.indexOfSelectedItem, 0)
                XCTAssertEqual(dialog.recordOrigin.state, .off)
                XCTAssertEqual(dialog.noCommit.state, .off)
            case .revert:
                XCTAssertEqual(dialog.parent.numberOfItems, 2)
                XCTAssertEqual(dialog.parent.indexOfSelectedItem, 0)
            case .merge:
                XCTAssertEqual(dialog.noFastForward.state, .on)
                XCTAssertEqual(dialog.squash.state, .off)
                XCTAssertEqual(dialog.noCommit.state, .off)
            case .rebase:
                XCTAssertEqual(dialog.interactive.state, .off)
                XCTAssertEqual(dialog.ignoreDate.state, .on)
            case .reset:
                XCTAssertEqual(dialog.resetMode.indexOfSelectedItem, 1)
                XCTAssertEqual(dialog.resetMode.numberOfItems,
                               GitStatusModel.ResetMode.allCases.count)
            case .drop:
                XCTAssertTrue(dialog.alert.informativeText.contains("HEAD"))
            }
        }
    }

    func testStashDialogsUseCapturedEntryAndOptInIndexRestore() {
        let stash = GitStatusModel.Stash(
            selector: "stash@{1}", oid: String(repeating: "f", count: 40),
            message: "older", baseHash: String(repeating: "a", count: 40),
            untrackedFilesHash: nil, author: "Tester", date: .now
        )
        for action in GitStatusModel.StashAction.allCases {
            let dialog = GitStashDialog(action: action, stash: stash, target: target)
            XCTAssertTrue(dialog.alert.informativeText.contains(stash.selector))
            XCTAssertTrue(dialog.alert.informativeText.contains(stash.oid))
            XCTAssertEqual(dialog.alert.buttons[1].keyEquivalent, "\u{1b}")
            switch action {
            case .apply, .pop:
                XCTAssertEqual(dialog.reinstateIndex.state, .off)
                dialog.reinstateIndex.state = .on
                XCTAssertEqual(dialog.reinstateIndex.state, .on)
            case .branch:
                XCTAssertFalse(dialog.alert.buttons[0].isEnabled)
                XCTAssertTrue(dialog.alert.window.initialFirstResponder === dialog.name)
                dialog.name.stringValue = "  "
                changed(dialog.name)
                XCTAssertFalse(dialog.alert.buttons[0].isEnabled)
                dialog.name.stringValue = "old-stash-branch"
                changed(dialog.name)
                XCTAssertTrue(dialog.alert.buttons[0].isEnabled)
            case .drop:
                XCTAssertTrue(dialog.alert.buttons[0].isEnabled)
            }
        }
    }

    func testUncommittedDangerousDialogsExposeTheirActualDefaults() {
        let stash = GitUncommittedDialog(action: .stash, target: target)
        XCTAssertEqual(stash.includeUntracked.state, .on)
        XCTAssertTrue(stash.alert.window.initialFirstResponder === stash.message)
        let reset = GitUncommittedDialog(action: .reset, target: target)
        XCTAssertEqual(reset.resetMode.numberOfItems, 2)
        XCTAssertEqual(reset.resetMode.indexOfSelectedItem, 0)
        let clean = GitUncommittedDialog(action: .clean, target: target)
        XCTAssertEqual(clean.directories.state, .on)
        for alert in [stash.alert, reset.alert, clean.alert] {
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        }
    }
}
