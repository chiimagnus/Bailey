import AppKit
import SwiftUI
import XCTest
@testable import kero

@MainActor
final class GitExternalRefreshTests: XCTestCase {
    private func wait(
        seconds: TimeInterval = 10, until condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Git snapshot did not settle")
                throw WorkspaceError.timedOut
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    func testVisibleLocalPanelDetectsExternalInitialization() async throws {
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-git-init-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([directory])
        let model = GitStatusModel()
        model.syncSelectedProject(in: manager)
        try await wait { model.hasResolvedStatus && !model.isRefreshing && !model.isRepo }

        let window = NSWindow(
            contentRect: NSRect(x: -1200, y: -1200, width: 420, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            ToolPanelView(manager: manager, git: model, panel: .git)
                .frame(width: 420, height: 560))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(window.isVisible)
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: NSApp
        )
        try await Task.sleep(for: .milliseconds(250))

        let result = GitCommandExecution.run(["init", "-q", "-b", "main"],
                                             in: directory.path, timeout: 10)
        XCTAssertEqual(result.status, 0, result.stderr)
        try await wait(seconds: 9) {
            model.hasResolvedStatus && !model.isRefreshing && model.isRepo
        }
        let actual = try FileManager.default.attributesOfItem(atPath: model.repoRoot)
        let expected = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(actual[.systemFileNumber] as? NSNumber,
                       expected[.systemFileNumber] as? NSNumber)
    }

    func testVisibleGitPanelRefreshesTwoExternalMutationsWithoutActivation() async throws {
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-git-external-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func git(_ arguments: [String]) -> String {
            let result = GitCommandExecution.run(arguments, in: root.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "External Fixture"])
        git(["config", "user.email", "fixture@invalid"])
        git(["config", "commit.gpgsign", "false"])
        let file = root.appendingPathComponent("tracked.txt")
        try "baseline\n".write(to: file, atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-qm", "baseline"])
        git(["switch", "-qc", "feature/ui"])
        try "side\n".write(to: root.appendingPathComponent("side.txt"),
                            atomically: true, encoding: .utf8)
        git(["add", "side.txt"])
        git(["commit", "-qm", "feature change"])
        git(["switch", "-q", "main"])
        try "main\n".write(to: root.appendingPathComponent("main.txt"),
                            atomically: true, encoding: .utf8)
        git(["add", "main.txt"])
        git(["commit", "-qm", "main change"])
        git(["merge", "-q", "--no-ff", "-m", "merge feature", "feature/ui"])
        git(["branch", "stable/0.1"])
        git(["tag", "v0.1"])
        git(["update-ref", "refs/remotes/origin/main", "HEAD"])

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let model = GitStatusModel()
        model.syncSelectedProject(in: manager)
        try await wait { model.hasResolvedStatus && !model.isRefreshing && model.isRepo }
        let oldHead = try XCTUnwrap(model.recentCommits.first?.hash)
        XCTAssertEqual(model.recentCommits.first?.parentHashes.count, 2)
        XCTAssertTrue(model.recentCommits.first?.references.contains {
            $0.kind == .tag && $0.name == "v0.1"
        } == true)

        let window = NSWindow(
            contentRect: NSRect(x: -1200, y: -1200, width: 460, height: 740),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ToolPanelView(manager: manager, git: model, panel: .git)
                .frame(width: 460, height: 740)
        )
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(manager.selectedProject?.panelContext?.isRemote, false)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(250))

        // External process changes the repository without a Kero terminal completion.
        try "first external change\n".write(to: file, atomically: true, encoding: .utf8)
        let worktreeStart = Date()
        XCTAssertFalse(git(["status", "--porcelain"]).isEmpty)
        try await wait(seconds: 6) {
            model.changedEntries.contains { $0.path == "tracked.txt" }
        }
        let worktreeLatency = Date().timeIntervalSince(worktreeStart)
        print("Git external worktree refresh latency: \(worktreeLatency) seconds")
        XCTAssertLessThan(worktreeLatency, 5, "Local visible Git must refresh promptly")

        git(["add", "tracked.txt"])
        let indexStart = Date()
        try await wait(seconds: 6) {
            model.stagedEntries.contains { $0.path == "tracked.txt" }
        }
        let indexLatency = Date().timeIntervalSince(indexStart)
        print("Git external index refresh latency: \(indexLatency) seconds")
        XCTAssertLessThan(indexLatency, 5, "External index changes must appear promptly")

        git(["commit", "-qm", "external commit"])
        let newHead = git(["rev-parse", "HEAD"])
        let historyStart = Date()
        XCTAssertNotEqual(oldHead, newHead)
        do {
            try await wait(seconds: 6) { model.recentCommits.first?.hash == newHead }
        } catch {
            print("Git refresh diagnostic: expected HEAD=\(newHead) actual HEAD=\(model.headOID ?? "nil") "
                + "recent=\(model.recentCommits.first?.hash ?? "nil") "
                + "refreshing=\(model.isRefreshing) repo=\(model.isRepo) "
                + "scope=\(model.currentScope) statusError=\(model.statusError ?? "nil") "
                + "NSApp.isActive=\(NSApp.isActive)")
            throw error
        }
        let historyLatency = Date().timeIntervalSince(historyStart)
        print("Git external commit refresh latency: \(historyLatency) seconds")
        XCTAssertLessThan(historyLatency, 5, "External commits must reach Recent Commits promptly")

        // A background application must not continue issuing Git refreshes.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(150))
        try "second external change\n".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(3.1))
        XCTAssertTrue(model.changedEntries.isEmpty, "Inactive panels must stop polling")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await wait(seconds: 6) {
            model.changedEntries.contains { $0.path == "tracked.txt" }
        }
        model.refresh()
        try await wait { !model.isRefreshing }

        // Replacing the docked Git panel must cancel its view-owned task.
        window.contentView = NSHostingView(rootView: Text("Git panel hidden"))
        try await Task.sleep(for: .milliseconds(250))
        git(["add", "tracked.txt"])
        git(["commit", "-qm", "hidden external commit"])
        let hiddenHead = git(["rev-parse", "HEAD"])
        try await Task.sleep(for: .seconds(3.1))
        XCTAssertNotEqual(model.recentCommits.first?.hash, hiddenHead,
                          "A non-visible Git panel must not keep polling")
        model.refresh()
        try await wait { !model.isRefreshing && model.recentCommits.first?.hash == hiddenHead }

        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-git-next-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: second) }
        @discardableResult
        func secondGit(_ args: [String]) -> String {
            let result = GitCommandExecution.run(args, in: second.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        secondGit(["init", "-q", "-b", "main"])
        secondGit(["config", "user.name", "Next Project"])
        secondGit(["config", "user.email", "next@invalid"])
        secondGit(["config", "commit.gpgsign", "false"])
        try "next\n".write(to: second.appendingPathComponent("other.txt"),
                           atomically: true, encoding: .utf8)
        secondGit(["add", "."])
        secondGit(["commit", "-qm", "other baseline"])
        let secondHead = secondGit(["rev-parse", "HEAD"])

        manager.addLocalItems([second])
        model.syncSelectedProject(in: manager)
        try await wait {
            model.rootPath == second.path && model.hasResolvedStatus
                && !model.isRefreshing && model.recentCommits.first?.hash == secondHead
        }
        window.contentView = NSHostingView(
            rootView: ToolPanelView(manager: manager, git: model, panel: .git)
                .frame(width: 460, height: 740)
        )
        try await Task.sleep(for: .milliseconds(250))
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(150))
        try "old project change\n".write(to: file, atomically: true, encoding: .utf8)
        try "new project change\n".write(to: second.appendingPathComponent("other.txt"),
                                         atomically: true, encoding: .utf8)
        try await wait(seconds: 6) {
            model.changedEntries.contains { $0.path == "other.txt" }
        }
        XCTAssertEqual(model.rootPath, second.path)
        XCTAssertEqual(model.recentCommits.first?.hash, secondHead)
        XCTAssertFalse(model.changedEntries.contains { $0.path == "tracked.txt" })
    }
}
