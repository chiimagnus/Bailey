import AppKit
import XCTest
@testable import Bailey

@MainActor
final class GitRemoteBranchDialogTests: XCTestCase {
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

    func testFetchBindsLocalDestinationAcrossExternalChangesAndStillAllowsFreshForceAndFastForward() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-fetch-dialog-" + UUID().uuidString)
        let repo = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: repo.path, timeout: 10)
            guard result.status == 0 else { XCTFail(result.stderr); throw WorkspaceError.notFound }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Fetch Dialog"])
        _ = try git(["config", "user.email", "fetch-dialog@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["config", "core.hooksPath", "/dev/null"])
        _ = try git(["commit", "--allow-empty", "-qm", "base"])
        let base = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "side"])
        _ = try git(["commit", "--allow-empty", "-qm", "server"])
        let server = try git(["rev-parse", "HEAD"])
        _ = try git(["commit", "--allow-empty", "-qm", "external"])
        let head = try git(["rev-parse", "HEAD"])
        _ = try git(["init", "--bare", "-q", root.appendingPathComponent("origin.git").path])
        _ = try git(["remote", "add", "origin", root.appendingPathComponent("origin.git").path])
        _ = try git(["push", "origin", server + ":refs/heads/side"])
        _ = try git(["fetch", "origin"])
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([repo])
        let project = try XCTUnwrap(manager.selectedProject)
        let window = NSWindow(contentRect: .init(x: -1200, y: -1200, width: 520, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        window.orderFront(nil)
        defer { window.close() }
        let model = GitStatusModel()
        model.syncSelectedProject(in: manager)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let panel = GitPanel(settings: AppSettings(configURL: root.appendingPathComponent("settings.toml")),
            model: model, manager: manager, project: project, session: nil, sshHost: nil,
            openFile: { _ in }, openDiff: { _, _ in }, openCommitDiff: { _, _ in })
        func showFetch() async throws -> (force: NSButton, confirm: NSButton) {
            let commit = try XCTUnwrap(model.recentCommits.first { $0.hash == server })
            let reference = try XCTUnwrap(commit.references.first { $0.name == "origin/side" })
            panel.presentRemoteBranchAction(reference, commit: commit, action: .fetch)
            let confirmTitle = String(localized: "Yes, Fetch", table: "Git")
            try await wait {
                window.attachedSheet?.contentView.map { self.buttons(in: $0).contains { $0.title == confirmTitle } } == true
            }
            let controls = buttons(in: try XCTUnwrap(window.attachedSheet?.contentView))
            let force = try XCTUnwrap(controls.first { $0.title == String(localized: "Force Fetch", table: "Git") })
            XCTAssertEqual(force.state, .off)
            return (force, try XCTUnwrap(controls.first { $0.title == confirmTitle }))
        }
        let stale = try await showFetch()
        stale.force.performClick(nil)
        _ = try git(["update-ref", "refs/heads/side", head])
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertEqual(model.refsByName["refs/heads/side"]?.oid, head)
        stale.confirm.performClick(nil)
        try await wait { window.attachedSheet == nil && !model.isBusy && !model.isRefreshing }
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/side"]), head)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)

        let fresh = try await showFetch()
        fresh.force.performClick(nil)
        fresh.confirm.performClick(nil)
        try await wait { window.attachedSheet == nil && !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/side"]), server)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)

        _ = try git(["update-ref", "refs/heads/side", base])
        model.refresh()
        try await wait { !model.isRefreshing }
        let fastForward = try await showFetch()
        fastForward.confirm.performClick(nil)
        try await wait { window.attachedSheet == nil && !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/side"]), server)
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"]), "refs/heads/main")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
    }
}
