import AppKit
import XCTest
@testable import kero

@MainActor
final class GitTagDialogTests: XCTestCase {
    func testCreationDefaultsAndEditedFieldsSurviveTypeChanges() {
        let dialog = GitTagDialog(kind: .create(remotes: ["origin", "backup"]),
            title: "Add Tag", detail: "commit", initialName: "v1",
            initialType: .annotated, initialMessage: "release notes")
        XCTAssertEqual(dialog.name.stringValue, "v1")
        XCTAssertEqual(dialog.selectedType, .annotated)
        XCTAssertEqual(dialog.message.string, "release notes")
        XCTAssertNil(dialog.selectedCreateRemote)
        XCTAssertTrue(dialog.message.isEditable)
        XCTAssertTrue(dialog.alert.buttons[0].isEnabled)
        XCTAssertEqual(dialog.alert.buttons[0].title, String(localized: "Add Tag", table: "Git"))
        dialog.tagType.selectItem(at: 1)
        dialog.tagType.performClick(nil)
        XCTAssertEqual(dialog.message.string, "release notes", "Do not discard the annotation while switching type")
        let retry = GitTagDialog(kind: .create(remotes: ["origin"]), title: "Retry",
            detail: "commit", initialName: "v1", initialType: .lightweight,
            initialMessage: "retained", initialRemote: "origin")
        XCTAssertEqual(retry.selectedType, .lightweight)
        XCTAssertEqual(retry.selectedCreateRemote, "origin")
        XCTAssertFalse(retry.message.isEditable)
    }

    func testDeleteRemoteChoicesAreExplicitAndInitiallyLocalOnly() {
        let single = GitTagDialog(kind: .delete(remotes: ["origin"]), title: "Delete", detail: "v1")
        XCTAssertNil(single.selectedDeleteRemote)
        single.deleteOnRemote.state = .on
        XCTAssertEqual(single.selectedDeleteRemote, "origin")
        let many = GitTagDialog(kind: .delete(remotes: ["origin", "backup"]),
            title: "Delete", detail: "v1")
        XCTAssertNil(many.selectedDeleteRemote)
        many.remoteSelection.selectItem(at: 2)
        XCTAssertEqual(many.selectedDeleteRemote, "backup")
        XCTAssertEqual(many.alert.buttons[0].title, String(localized: "Yes, Delete", table: "Git"))
    }

    func testPushSelectionAndNoRemoteSafety() {
        let many = GitTagDialog(kind: .push(remotes: ["origin", "backup"], preferred: "backup"),
            title: "Push", detail: "v1")
        XCTAssertEqual(many.selectedPushRemotes, ["backup"])
        let none = GitTagDialog(kind: .push(remotes: [], preferred: nil), title: "Push", detail: "v1")
        XCTAssertFalse(none.alert.buttons[0].isEnabled)
        let single = GitTagDialog(kind: .push(remotes: ["origin"], preferred: nil),
            title: "Push", detail: "v1")
        XCTAssertEqual(single.selectedPushRemotes, ["origin"])
    }
}
