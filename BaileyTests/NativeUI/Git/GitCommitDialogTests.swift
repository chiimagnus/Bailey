import AppKit
import XCTest
@testable import Bailey

@MainActor
final class GitCommitDialogTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

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
        let rebase = GitCommitDialog(action: .rebase, commit: commit, target: model.actionTarget())
        XCTAssertEqual(rebase.interactive.state, .off)
        XCTAssertEqual(rebase.ignoreDate.state, .on)
        let reset = GitCommitDialog(action: .reset, commit: commit, target: model.actionTarget())
        XCTAssertEqual(reset.resetMode.indexOfSelectedItem, 1)
        XCTAssertEqual(reset.resetMode.numberOfItems, 3)
        let drop = GitCommitDialog(action: .drop, commit: commit, target: model.actionTarget())
        XCTAssertEqual(drop.alert.buttons[0].title, String(localized: "Yes, Drop", table: "Git"))
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
        let manager = self.workspaceApplication.makeWindow()
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
        let projectTarget = try XCTUnwrap(project.panelContext).identity
        model.syncSelectedProject(in: manager)
        try await wait {
            model.hasResolvedStatus && !model.isRefreshing
                && model.matchesPanelTarget(projectTarget)
        }
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
        model.syncSelectedProject(in: manager)
        let staleSheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try XCTUnwrap(buttons(in: staleSheet).first { $0.title == String(localized: "Yes, Checkout", table: "Git") }).performClick(nil)
        try await wait { window.attachedSheet == nil }
        XCTAssertEqual(git(["rev-parse", "HEAD"]), second)

        manager.selectedProjectID = project.id
        model.syncSelectedProject(in: manager)
        try await wait {
            !model.isRefreshing && model.matchesPanelTarget(projectTarget)
        }
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

    func testProjectResolutionCannotAuthorizeOldRepositorySnapshot() async throws {
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        for directory in [firstRoot, secondRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Projection"],
                              ["config", "user.email", "projection@invalid"], ["config", "commit.gpgsign", "false"],
                              ["commit", "--allow-empty", "-qm", directory.lastPathComponent + "-root"],
                              ["commit", "--allow-empty", "-qm", directory.lastPathComponent + "-head"]] {
                let result = GitCommandExecution.run(arguments, in: directory.path)
                XCTAssertEqual(result.status, 0, result.stderr)
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let first = Project(fallbackName: "First", workspaceConfiguration: .standard)
        first.customDirectory = firstRoot.path
        let second = Project(fallbackName: "Second", workspaceConfiguration: .standard)
        second.customDirectory = secondRoot.path
        manager.projects = [first, second]
        manager.selectedProjectID = first.id
        let model = GitStatusModel()
        let firstIdentity = try XCTUnwrap(first.panelContext).identity
        let secondIdentity = try XCTUnwrap(second.panelContext).identity
        model.syncSelectedProject(in: manager)
        try await wait { model.matchesPanelTarget(firstIdentity) && model.hasResolvedStatus && !model.isRefreshing }
        let old = try XCTUnwrap(model.recentCommits.last)
        let oldTarget = model.actionTarget()
        let originalHead = model.headOID
        manager.selectedProjectID = second.id
        model.syncSelectedProject(in: manager)
        XCTAssertFalse(model.matchesPanelTarget(firstIdentity))
        XCTAssertFalse(model.isCurrent(oldTarget))
        model.actOnCommit(old, action: .checkout, target: model.actionTarget())
        XCTAssertFalse(model.isBusy, "An unresolved projection must not acquire a mutation")
        try await wait { model.matchesPanelTarget(secondIdentity) && !model.isRefreshing }
        XCTAssertEqual(GitCommandExecution.run(["rev-parse", "HEAD"], in: firstRoot.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines), originalHead)
        XCTAssertEqual(GitCommandExecution.run(["branch", "--show-current"], in: secondRoot.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines), "main")
        manager.selectedProjectID = first.id
        model.syncSelectedProject(in: manager)
        try await wait { model.matchesPanelTarget(firstIdentity) && !model.isRefreshing }
        XCTAssertFalse(model.isCurrent(oldTarget), "Switching away and back must not revive an old confirmation")
    }
}
