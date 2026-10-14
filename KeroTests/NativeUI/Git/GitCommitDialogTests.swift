import AppKit
import XCTest
@testable import kero

@MainActor
final class GitCommitDialogTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    func testNativeFieldsAndMainlineDefaults() {
        let model = GitStatusModel()
        let commit = GitStatusModel.RecentCommit(
            hash: String(repeating: "a", count: 40), shortHash: "aaaaaaa", subject: "merge",
            author: "Developer", date: .now, parentHashes: ["first", "second"], references: [], files: []
        )
        let checkout = GitCommitDialog(action: .checkout, commit: commit, target: model.actionTarget())
        XCTAssertEqual(checkout.alwaysAccept.state, .off)
        XCTAssertEqual(checkout.alert.buttons[0].title, String(localized: "Yes, Checkout", table: "Git"))
        XCTAssertEqual(checkout.alert.buttons[1].keyEquivalent, "\u{1b}")
        let cherry = GitCommitDialog(action: .cherryPick, commit: commit, target: model.actionTarget())
        XCTAssertEqual(cherry.parent.numberOfItems, 2)
        XCTAssertEqual(cherry.parent.indexOfSelectedItem, 0)
        XCTAssertEqual(cherry.recordOrigin.state, .off)
        XCTAssertEqual(cherry.noCommit.state, .off)
        let merge = GitCommitDialog(action: .merge, commit: commit, target: model.actionTarget())
        XCTAssertEqual(merge.noFastForward.state, .on)
        XCTAssertEqual(merge.squash.state, .off)
        XCTAssertEqual(merge.noCommit.state, .off)
        let revert = GitCommitDialog(action: .revert, commit: commit, target: model.actionTarget())
        XCTAssertEqual(revert.parent.numberOfItems, 2)
        XCTAssertEqual(revert.alert.buttons[0].title, String(localized: "Yes, Revert", table: "Git"))
    }

    func testSheetStaysInInitiatingWindowAndRejectsSameRepositoryProjectSwitch() async throws {
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) -> String {
            let result = GitCommandExecution.run(args, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.name", "Native Dialog"])
        _ = git(["config", "user.email", "native@invalid"])
        _ = git(["config", "commit.gpgsign", "false"])
        _ = git(["commit", "--allow-empty", "-qm", "first"])
        let first = git(["rev-parse", "HEAD"])
        _ = git(["commit", "--allow-empty", "-qm", "second"])
        let second = git(["rev-parse", "HEAD"])
        let manager = TerminalManager()
        let project = Project(fallbackName: "First", workspaceConfiguration: .standard)
        project.customDirectory = root.path
        let other = Project(fallbackName: "Other", workspaceConfiguration: .standard)
        other.customDirectory = root.path
        manager.projects = [project, other]
        manager.selectedProjectID = project.id
        let window = NSWindow(contentRect: .init(x: -1200, y: -1200, width: 600, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let anotherWindow = NSWindow(contentRect: .init(x: -1200, y: -1200, width: 500, height: 350),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        anotherWindow.isReleasedWhenClosed = false
        defer { window.close(); anotherWindow.close(); manager.windowClosed() }
        manager.attach(to: window)
        window.orderFront(nil)
        anotherWindow.makeKeyAndOrderFront(nil)
        let model = GitStatusModel()
        model.sync(root: root.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let commit = try XCTUnwrap(model.recentCommits.first { $0.hash == first })
        let panel = GitPanel(settings: AppSettings(configURL: root.appendingPathComponent("settings.toml")),
                             model: model, manager: manager, project: project, session: nil, sshHost: nil,
                             openFile: { _ in }, openDiff: { _, _ in }, openCommitDiff: { _, _ in })
        panel.presentCommitDialog(commit, action: .checkout)
        try await wait {
            guard let content = window.attachedSheet?.contentView else { return false }
            return self.buttons(in: content).contains { $0.title == String(localized: "Cancel", table: "Sidebar") }
        }
        XCTAssertNil(anotherWindow.attachedSheet)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let cancel = try XCTUnwrap(buttons(in: try XCTUnwrap(sheet.contentView)).first { $0.title == String(localized: "Cancel", table: "Sidebar") })
        cancel.performClick(nil)
        try await wait { window.attachedSheet == nil }
        XCTAssertEqual(git(["rev-parse", "HEAD"]), second)

        panel.presentCommitDialog(commit, action: .checkout)
        try await wait { window.attachedSheet != nil }
        manager.selectedProjectID = other.id
        let staleSheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try XCTUnwrap(buttons(in: staleSheet).first { $0.title == String(localized: "Yes, Checkout", table: "Git") }).performClick(nil)
        try await wait { window.attachedSheet == nil }
        XCTAssertEqual(git(["rev-parse", "HEAD"]), second)

        manager.selectedProjectID = project.id
        panel.presentCommitDialog(commit, action: .checkout)
        try await wait { window.attachedSheet != nil }
        let validSheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try XCTUnwrap(buttons(in: validSheet).first {
            $0.title == String(localized: "Always Accept", table: "Git")
        }).performClick(nil)
        try XCTUnwrap(buttons(in: validSheet).first { $0.title == String(localized: "Yes, Checkout", table: "Git") }).performClick(nil)
        try await wait { window.attachedSheet == nil && !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(git(["rev-parse", "HEAD"]), first)
        XCTAssertEqual(git(["branch", "--show-current"]), "")
        XCTAssertTrue(panel.settings.gitAlwaysAcceptCheckout)

        _ = git(["switch", "main"])
        model.refresh()
        try await wait { !model.isRefreshing }
        panel.presentCommitDialog(commit, action: .checkout)
        XCTAssertNil(window.attachedSheet)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(git(["rev-parse", "HEAD"]), first)

        panel.settings.gitAlwaysAcceptCheckout = false
        _ = git(["switch", "main"])
        model.refresh()
        try await wait { !model.isRefreshing }
        panel.presentCommitDialog(commit, action: .checkout)
        try await wait { window.attachedSheet != nil }
        let closedWindowSheet = try XCTUnwrap(window.attachedSheet?.contentView)
        window.close()
        manager.windowClosed()
        buttons(in: closedWindowSheet).first {
            $0.title == String(localized: "Yes, Checkout", table: "Git")
        }?.performClick(nil)
        XCTAssertEqual(git(["rev-parse", "HEAD"]), second)
        XCTAssertNil(manager.attachedWindow)
    }
}
