import AppKit
import XCTest
@testable import Bailey

@MainActor
final class GitRefReplacementTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

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

    func testBranchAndTagReplacementPreserveRetryInputAndRejectRefMovedDuringConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-replace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: root.path, timeout: 10)
            guard result.status == 0 else { XCTFail(result.stderr); throw WorkspaceError.notFound }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Replacement"])
        _ = try git(["config", "user.email", "replacement@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["config", "core.hooksPath", "/dev/null"])
        _ = try git(["commit", "--allow-empty", "-qm", "selected"])
        let selected = try git(["rev-parse", "HEAD"])
        _ = try git(["commit", "--allow-empty", "-qm", "existing"])
        let existing = try git(["rev-parse", "HEAD"])
        _ = try git(["commit", "--allow-empty", "-qm", "external update"])
        let moved = try git(["rev-parse", "HEAD"])
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let window = NSWindow(contentRect: .init(x: -1200, y: -1200, width: 540, height: 440),
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
        func button(_ title: String) -> NSButton? {
            window.attachedSheet?.contentView.flatMap { buttons(in: $0).first { $0.title == title } }
        }
        func click(_ title: String) async throws {
            try await wait { button(title) != nil }
            try XCTUnwrap(button(title)).performClick(nil)
        }
        for isTag in [false, true] {
            let name = isTag ? "existing-tag" : "existing-branch"
            let ref = (isTag ? "refs/tags/" : "refs/heads/") + name
            model.refresh()
            try await wait { !model.isRefreshing }
            let commit = try XCTUnwrap(model.recentCommits.first { $0.hash == selected })
            let create = String(localized: isTag ? "Add Tag" : "Create Branch", table: "Git")
            let replace = String(localized: isTag ? "Replace Existing Tag" : "Replace Existing Branch", table: "Git")
            func showCreate() {
                if isTag {
                    panel.presentTagCreate(at: commit, initialName: name,
                                           initialMessage: "retained\nannotation")
                } else {
                    panel.presentBranchCreate(at: commit, initialName: name, initialCheckout: false)
                }
            }
            showCreate()
            try await wait { button(create) != nil }
            _ = try git(["update-ref", ref, existing])
            XCTAssertNil(model.refsByName[ref], "Exercise the already-exists Git error, not only the cached collision")
            try await click(create)
            try await click(String(localized: "Choose Another Name", table: "Git"))
            try await wait { button(create) != nil }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let fields = descendants(try XCTUnwrap(window.attachedSheet?.contentView))
            XCTAssertTrue(fields.compactMap { $0 as? NSTextField }.contains { $0.stringValue == name })
            if isTag {
                XCTAssertTrue(fields.compactMap { $0 as? NSTextView }.contains { $0.string == "retained\nannotation" })
            } else {
                XCTAssertEqual(button(String(localized: "Check out", table: "Git"))?.state, .off)
            }
            try await click(String(localized: "Cancel", table: "Sidebar"))
            try await wait { window.attachedSheet == nil }
            XCTAssertEqual(try git(["rev-parse", ref]), existing)

            showCreate()
            try await click(create)
            try await wait { button(replace) != nil }
            _ = try git(["update-ref", ref, moved])
            model.refresh()
            try await wait { !model.isRefreshing }
            XCTAssertEqual(model.refsByName[ref]?.oid, moved, "The new snapshot must not re-authorize the old confirmation")
            try await click(replace)
            try await wait { window.attachedSheet == nil && !model.isBusy && !model.isRefreshing }
            XCTAssertNotNil(model.lastError)
            XCTAssertEqual(try git(["rev-parse", ref]), moved)
            XCTAssertEqual(try git(["rev-parse", "HEAD"]), moved)

            showCreate()
            try await click(create)
            try await click(replace)
            try await wait { window.attachedSheet == nil && !model.isBusy && !model.isRefreshing }
            XCTAssertNil(model.lastError)
            XCTAssertEqual(try git(["rev-parse", ref + "^{commit}"]), selected)
            XCTAssertEqual(try git(["rev-parse", "HEAD"]), moved)
            if isTag { XCTAssertTrue(try git(["cat-file", "-p", ref]).contains("retained\nannotation")) }
        }
    }
}
