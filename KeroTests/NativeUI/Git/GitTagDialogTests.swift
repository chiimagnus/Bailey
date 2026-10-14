import AppKit
import XCTest
@testable import kero

@MainActor
final class GitTagDialogTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    func testPanelTagPushUsesConfiguredDefaultAndRejectsFailedContainmentQuery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kero-tag-panel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: repo.path, timeout: 10)
            guard result.status == 0 else { XCTFail(result.stderr); throw WorkspaceError.notFound }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Tag Panel"])
        _ = try git(["config", "user.email", "tag-panel@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["config", "core.hooksPath", "/dev/null"])
        _ = try git(["commit", "--allow-empty", "-qm", "tagged commit"])
        for name in ["origin", "backup"] {
            let bare = root.appendingPathComponent(name + ".git")
            _ = try git(["init", "--bare", "-q", bare.path])
            _ = try git(["remote", "add", name, bare.path])
            _ = try git(["push", name, "main"])
        }
        _ = try git(["config", "remote.pushDefault", "backup"])
        _ = try git(["config", "branch.main.pushRemote", "origin"])
        _ = try git(["tag", "allowed"])
        _ = try git(["tag", "blocked"])
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([repo])
        let project = try XCTUnwrap(manager.selectedProject)
        let window = NSWindow(contentRect: .init(x: -1200, y: -1200, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        window.orderFront(nil)
        defer { window.close() }
        let model = GitStatusModel()
        model.syncSelectedProject(in: manager)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let settings = AppSettings(configURL: root.appendingPathComponent("settings.toml"))
        let panel = GitPanel(settings: settings, model: model, manager: manager, project: project,
            session: nil, sshHost: nil, openFile: { _ in }, openDiff: { _, _ in }, openCommitDiff: { _, _ in })
        func showPush(_ name: String) async throws -> [NSButton] {
            let commit = try XCTUnwrap(model.recentCommits.first { $0.references.contains { $0.name == name && $0.kind == .tag } })
            let reference = try XCTUnwrap(commit.references.first { $0.name == name && $0.kind == .tag })
            panel.presentTagAction(reference, commit: commit, action: .push)
            try await wait { window.attachedSheet != nil }
            let controls = buttons(in: try XCTUnwrap(window.attachedSheet?.contentView))
            XCTAssertEqual(controls.first { $0.title == "backup" }?.state, .on)
            XCTAssertEqual(controls.first { $0.title == "origin" }?.state, .off,
                           "Tag must ignore branch.main.pushRemote and use remote.pushDefault")
            return controls
        }
        let controls = try await showPush("allowed")
        try XCTUnwrap(controls.first { $0.title == String(localized: "Yes, Push", table: "Git") }).performClick(nil)
        try await wait { window.attachedSheet == nil && model.operation?.finishedAt != nil && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertTrue(try git(["ls-remote", "backup", "refs/tags/allowed"]).contains("refs/tags/allowed"))
        XCTAssertEqual(try git(["ls-remote", "origin", "refs/tags/allowed"]), "")

        let blocked = try await showPush("blocked")
        let gitDirectory = repo.appendingPathComponent(".git")
        let paused = root.appendingPathComponent("git-paused")
        try FileManager.default.moveItem(at: gitDirectory, to: paused)
        defer {
            if FileManager.default.fileExists(atPath: paused.path) {
                try? FileManager.default.moveItem(at: paused, to: gitDirectory)
            }
        }
        let failedQuery = GitCommandExecution.run(["for-each-ref", "--contains=HEAD", "refs/remotes"], in: repo.path)
        XCTAssertNotEqual(failedQuery.status, 0, "The fixture must fail the real containment query")
        try XCTUnwrap(blocked.first { $0.title == String(localized: "Yes, Push", table: "Git") }).performClick(nil)
        try await wait { window.attachedSheet == nil && (model.lastError != nil || model.operation?.label.contains("blocked") == true) }
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNotNil(model.lastError, "A failed check must not bypass user confirmation")
        XCTAssertTrue(model.lastError?.contains(String(localized: "Unable to check whether the tag commit is on the selected remotes.", table: "Git")) == true)
        XCTAssertFalse(model.operation?.label.contains("blocked") == true, "No Push operation may start after a failed check")
        try FileManager.default.moveItem(at: paused, to: gitDirectory)
        XCTAssertEqual(try git(["ls-remote", "backup", "refs/tags/blocked"]), "")
        _ = try git(["push", "backup", "refs/tags/blocked:refs/tags/blocked"])
        XCTAssertTrue(try git(["ls-remote", "backup", "refs/tags/blocked"]).contains("refs/tags/blocked"))
    }

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
