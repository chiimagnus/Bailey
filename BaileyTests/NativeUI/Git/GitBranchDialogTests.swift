import AppKit
import XCTest
@testable import Bailey

@MainActor
final class GitBranchDialogTests: XCTestCase {
    func testBranchCreateAndRenameUseNativeFieldsAndPreserveRetryInput() {
        let history = GitBranchDialog(kind: .create(checkout: false),
            title: "Create Branch at Commit", detail: "commit", initialName: "feature/name")
        XCTAssertEqual(history.checkout.state, .off)
        XCTAssertEqual(history.name.stringValue, "feature/name")
        XCTAssertEqual(history.alert.buttons[0].title, String(localized: "Create Branch", table: "Git"))
        XCTAssertEqual(history.alert.buttons[1].title, String(localized: "Cancel", table: "Sidebar"))

        let fromHead = GitBranchDialog(kind: .create(checkout: true),
            title: "Create New Branch", detail: "current HEAD")
        XCTAssertEqual(fromHead.checkout.state, .on)
        XCTAssertFalse(fromHead.alert.buttons[0].isEnabled, "An empty branch name cannot submit")

        let renamed = GitBranchDialog(kind: .rename, title: "Rename",
            detail: "old", initialName: "topic/old")
        XCTAssertEqual(renamed.name.stringValue, "topic/old")
        XCTAssertTrue(renamed.alert.buttons[0].isEnabled)
        XCTAssertEqual(renamed.alert.buttons[0].title, String(localized: "Rename Branch", table: "Git"))
    }

    func testRemoteCheckoutFetchAndPullExposeNativeDefaults() {
        let checkout = GitBranchDialog(kind: .remoteCheckout,
            title: "Checkout Remote Branch", detail: "origin/topic/nested",
            initialName: "topic/nested")
        XCTAssertEqual(checkout.name.stringValue, "topic/nested")
        XCTAssertEqual(checkout.alert.buttons[0].title,
                       String(localized: "Checkout Branch", table: "Git"))
        XCTAssertTrue(checkout.alert.buttons[0].isEnabled)

        let fetch = GitBranchDialog(kind: .remoteFetch,
            title: "Fetch into Local Branch", detail: "origin/topic/nested")
        XCTAssertEqual(fetch.forceFetch.state, .off)
        XCTAssertEqual(fetch.alert.buttons[0].title,
                       String(localized: "Yes, Fetch", table: "Git"))

        let pull = GitBranchDialog(kind: .remotePull,
            title: "Pull into Current Branch", detail: "origin/topic/nested")
        XCTAssertEqual(pull.noFastForward.state, .off,
                       "Fast-forward should be allowed by default")
        XCTAssertEqual(pull.squash.state, .off)
        XCTAssertEqual(pull.alert.buttons[0].title,
                       String(localized: "Yes, Pull", table: "Git"))
        XCTAssertEqual(pull.alert.buttons[1].title,
                       String(localized: "Cancel", table: "Sidebar"))
    }

    func testPushWithoutConfiguredRemotesHasNoPossibleSubmit() {
        let dialog = GitBranchDialog(kind: .push(remotes: [], preferred: nil),
            title: "Push Branch", detail: String(localized: "No Git remote is configured", table: "Git"))
        XCTAssertTrue(dialog.selectedRemotes.isEmpty)
        XCTAssertFalse(dialog.alert.buttons[0].isEnabled,
                       "Without remotes the user must see the reason, not trigger a silent no-op")
        XCTAssertEqual(dialog.alert.informativeText,
                       String(localized: "No Git remote is configured", table: "Git"))
    }

    func testDeleteAndPushHaveGitGraphDefaultsWithExplicitDangerousChoices() {
        let deletion = GitBranchDialog(kind: .delete(remotes: ["origin", "backup"]),
            title: "Delete Branch", detail: "branch")
        XCTAssertEqual(deletion.forceDelete.state, .off)
        XCTAssertEqual(deletion.deleteRemotes.state, .off)
        XCTAssertEqual(deletion.alert.buttons[0].title, String(localized: "Yes, Delete", table: "Git"))
        XCTAssertTrue(deletion.alert.accessoryView != nil)

        let pushing = GitBranchDialog(kind: .push(
            remotes: ["origin", "backup", "third"], preferred: "backup"
        ), title: "Push", detail: "branch")
        XCTAssertEqual(pushing.setUpstream.state, .on)
        XCTAssertEqual(pushing.selectedPushMode, .normal)
        XCTAssertEqual(pushing.selectedRemotes, ["backup"])
        pushing.remoteButtons[1].button.state = .off
        pushing.remoteButtons[0].button.state = .on
        XCTAssertEqual(pushing.selectedRemotes, ["origin"])
        for option in pushing.remoteButtons { option.button.state = .off }
        // A native click triggers the validator; directly re-run it here
        // to cover the enabled state without posting an artificial mouse event.
        pushing.remoteButtons[0].button.performClick(nil)
        XCTAssertEqual(pushing.selectedRemotes, ["origin"])
        pushing.remoteButtons[0].button.performClick(nil)
        XCTAssertTrue(pushing.selectedRemotes.isEmpty)
        XCTAssertFalse(pushing.alert.buttons[0].isEnabled, "No remote selected must disable Push")
    }
}
