import AppKit
import XCTest
@testable import kero

@MainActor
final class GitStashDialogTests: XCTestCase {
    func testSpecificStashIdentityIndexDefaultsAndBranchInputValidation() {
        let stash = GitStatusModel.Stash(selector: "stash@{2}", oid: String(repeating: "a", count: 40), message: "selected stash")
        let target = GitStatusModel().actionTarget()
        for action in GitStatusModel.StashAction.allCases {
            let dialog = GitStashDialog(action: action, stash: stash, target: target)
            XCTAssertTrue(dialog.alert.informativeText.contains(stash.selector))
            XCTAssertTrue(dialog.alert.informativeText.contains(stash.oid))
            XCTAssertEqual(dialog.alert.buttons.count, 2)
            XCTAssertEqual(dialog.alert.buttons[1].keyEquivalent, "\u{1b}")
            XCTAssertEqual(dialog.reinstateIndex.state, .off)
            if action == .branch {
                XCTAssertFalse(dialog.alert.buttons[0].isEnabled)
                dialog.name.stringValue = "stash/branch"
                dialog.name.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: dialog.name))
                XCTAssertTrue(dialog.alert.buttons[0].isEnabled)
                XCTAssertEqual(dialog.alert.buttons[0].title, String(localized: "Create Branch", table: "Git"))
            }
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testNativePopCancellationAndConfirmationUseCapturedSecondStashAndIndexChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kero-stash-sheet-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) -> String {
            let result = GitCommandExecution.run(arguments, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.name", "Native Stash"])
        _ = git(["config", "user.email", "stash@invalid"])
        _ = git(["config", "commit.gpgsign", "false"])
        let path = root.appendingPathComponent("file.txt")
        try Data("base\n".utf8).write(to: path)
        _ = git(["add", "."]); _ = git(["commit", "-qm", "base"])
        for message in ["first", "second"] {
            try Data((message + "\n").utf8).write(to: path)
            _ = git(["add", "."]); _ = git(["stash", "push", "-qm", message])
        }
        let retained = git(["rev-parse", "stash@{0}"])
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
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
        let selected = model.stashes[1]
        let panel = GitPanel(model: model, manager: manager, project: project, session: nil, sshHost: nil,
                             openFile: { _ in }, openDiff: { _, _ in }, openCommitDiff: { _, _ in })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func button(_ title: String) throws -> NSButton {
            try XCTUnwrap(descendants(try XCTUnwrap(window.attachedSheet?.contentView))
                .compactMap { $0 as? NSButton }.first { $0.title == title })
        }
        panel.presentStashDialog(selected, action: .pop)
        try await wait { window.attachedSheet != nil }
        try button(String(localized: "Cancel", table: "Sidebar")).performClick(nil)
        try await wait { window.attachedSheet == nil }
        XCTAssertEqual(git(["rev-parse", "stash@{0}"]), retained)
        XCTAssertEqual(git(["show", ":file.txt"]), "base")
        panel.presentStashDialog(selected, action: .pop)
        try await wait { window.attachedSheet != nil }
        try button(String(localized: "Reinstate Index", table: "Git")).state = .on
        try button(String(localized: "Yes, Pop Stash", table: "Git")).performClick(nil)
        try await wait { window.attachedSheet == nil && !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.stashes.map(\.oid), [retained])
        XCTAssertEqual(git(["show", ":file.txt"]), "first")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "first\n")
    }
}
