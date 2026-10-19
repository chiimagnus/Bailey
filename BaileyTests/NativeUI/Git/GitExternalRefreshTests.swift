import AppKit
import SwiftUI
import XCTest
@testable import Bailey

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
            .appendingPathComponent("bailey-git-init-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalFolders([directory])
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
            .appendingPathComponent("bailey-git-external-" + UUID().uuidString)
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
        manager.addLocalFolders([root])
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
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(model.hasLocalFileEvents)

        let unwantedPoll = expectation(description: "Local Git must not poll while files are unchanged")
        unwantedPoll.isInverted = true
        withObservationTracking({ _ = model.isRefreshing }) {
            unwantedPoll.fulfill()
        }
        await fulfillment(of: [unwantedPoll], timeout: 6)

        // External process changes the repository without a Bailey terminal completion.
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

        // The panel has no local Git timer; model-owned FSEvents still keep the
        // bottom toolbar current while the App remains in the foreground.
        window.contentView = NSHostingView(rootView: Text("Git panel hidden"))
        try await Task.sleep(for: .milliseconds(250))
        git(["add", "tracked.txt"])
        git(["commit", "-qm", "hidden external commit"])
        let hiddenHead = git(["rev-parse", "HEAD"])
        try await wait(seconds: 6) {
            !model.isRefreshing && model.recentCommits.first?.hash == hiddenHead
        }
        XCTAssertEqual(model.recentCommits.first?.hash, hiddenHead,
                       "A hidden Git panel must still receive local file events")

        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-git-next-" + UUID().uuidString)
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

        manager.addLocalFolders([second])
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

    func testVisibleSSHPanelRefreshesExternalGitChanges() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Real SSH refresh requires an authorized test host")
        }
        let backend = SSHHostWorkspaces.backend(for: host)
        let externalSocket = "/tmp/bailey-issue2-\(UUID().uuidString.prefix(8)).sock"
        let external = SSHWorkspaceBackend(
            runner: SSHHostCommandRunner(host: host, socket: externalSocket), timeout: 25
        )
        let created = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-issue2-refresh-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(created.status, 0)
        let root = String(decoding: created.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("bailey-issue2-refresh-")
        else { throw WorkspaceError.notFound }

        func remote(_ command: String, via workspace: SSHWorkspaceBackend) async throws {
            let result = try await workspace.run(
                argv: ["sh", "-c", command], cwd: root, env: nil, stdin: nil, timeout: 25
            )
            guard result.status == 0 else {
                XCTFail(String(decoding: result.stderr, as: UTF8.self))
                throw WorkspaceError.notFound
            }
        }
        func cleanup() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Could not delete test-owned SSH fixture: \(error)") }
            if FileManager.default.fileExists(atPath: externalSocket) {
                do {
                    let result = try await Task.detached {
                        try ProcessRemoteCommandRunner.launch(
                            sshPath: "/usr/bin/ssh",
                            arguments: ["-S", externalSocket, "-O", "exit", host],
                            stdin: nil, timeout: 10
                        )
                    }.value
                    XCTAssertEqual(result.status, 0)
                } catch {
                    XCTFail("Could not stop test-owned external SSH connection: \(error)")
                }
            }
        }

        do {
            try await remote("""
                git init -q -b main
                git config user.name 'External SSH Fixture'
                git config user.email fixture@invalid
                git config commit.gpgsign false
                git config core.autocrlf false
                printf 'baseline\\n' > tracked.txt
                git add tracked.txt
                git commit -qm baseline
                """, via: backend)

            let manager = TerminalManager()
            defer { manager.windowClosed() }
            let project = Project(
                fallbackName: "External SSH Fixture", workspaceConfiguration: .standard
            )
            project.sshHost = host
            project.customDirectory = root
            manager.projects = [project]
            manager.selectedProjectID = project.id
            let model = GitStatusModel()
            model.syncSelectedProject(in: manager)
            do {
                try await wait(seconds: 35) {
                    model.hasResolvedStatus && !model.isRefreshing && model.isRepo
                }
            } catch {
                print("SSH initial refresh failed: root=\(model.rootPath) scope=\(model.currentScope) " +
                    "isRepo=\(model.isRepo) resolved=\(model.hasResolvedStatus) " +
                    "refreshing=\(model.isRefreshing) statusError=\(model.statusError ?? "nil")")
                throw error
            }
            XCTAssertEqual(model.currentScope, "ssh:" + host)
            let originalHead = try XCTUnwrap(model.recentCommits.first?.hash)

            let window = NSWindow(
                contentRect: NSRect(x: -1200, y: -1200, width: 460, height: 740),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:
                ToolPanelView(manager: manager, git: model, panel: .git)
                    .frame(width: 460, height: 740))
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(window.isVisible)
            NotificationCenter.default.post(
                name: NSApplication.didBecomeActiveNotification, object: NSApp
            )

            // This SSH connection never reports a Bailey terminal command completion.
            try await remote("printf 'worktree\\n' >> tracked.txt", via: external)
            let worktreeStart = Date()
            try await wait(seconds: 30) {
                model.changedEntries.contains { $0.path == "tracked.txt" }
            }
            print("SSH external worktree refresh: \(Date().timeIntervalSince(worktreeStart)) s")

            try await remote("git add tracked.txt", via: external)
            do {
                try await wait(seconds: 30) {
                    model.stagedEntries.contains { $0.path == "tracked.txt" }
                }
            } catch {
                let truth = await GitCommandExecution.run(
                    ["status", "--short"], in: root, timeout: 25, backend: external
                )
                print("SSH staged timeout: git=\(truth.stdout) staged=\(model.stagedEntries.count) " +
                    "changed=\(model.changedEntries.count) refreshing=\(model.isRefreshing) " +
                    "busy=\(model.isBusy) statusError=\(model.statusError ?? "nil") " +
                    "scope=\(model.currentScope)")
                throw error
            }
            try await remote("git commit -qm 'external SSH change'", via: external)
            let newest = await GitCommandExecution.run(
                ["rev-parse", "HEAD"], in: root, timeout: 25, backend: external
            )
            XCTAssertEqual(newest.status, 0, newest.stderr)
            let newHead = newest.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertNotEqual(originalHead, newHead)
            let historyStart = Date()
            try await wait(seconds: 30) { model.recentCommits.first?.hash == newHead }
            print("SSH external commit refresh: \(Date().timeIntervalSince(historyStart)) s")

            NotificationCenter.default.post(
                name: NSApplication.didResignActiveNotification, object: NSApp
            )
            try await wait(seconds: 15) { !model.isRefreshing }
            try await remote("printf 'background\\n' >> tracked.txt", via: external)
            try await Task.sleep(for: .seconds(7))
            XCTAssertTrue(model.changedEntries.isEmpty, "Background Git must not poll")

            NotificationCenter.default.post(
                name: NSApplication.didBecomeActiveNotification, object: NSApp
            )
            try await wait(seconds: 30) {
                model.changedEntries.contains { $0.path == "tracked.txt" }
            }
            // SSH delivers working-tree status before its Ref/history details.
            // Finish this visible-panel refresh before checking whether hiding
            // the view prevents NEW polling, not completion of an old request.
            try await wait(seconds: 35) {
                !model.isRefreshing && model.recentCommits.first?.hash == newHead
            }

            window.contentView = NSHostingView(rootView: Text("Git panel hidden"))
            try await Task.sleep(for: .milliseconds(350))
            try await remote(
                "git add tracked.txt && git commit -qm 'external while hidden'", via: external
            )
            let hidden = await GitCommandExecution.run(
                ["rev-parse", "HEAD"], in: root, timeout: 25, backend: external
            )
            XCTAssertEqual(hidden.status, 0, hidden.stderr)
            let hiddenHead = hidden.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            try await Task.sleep(for: .seconds(7))
            XCTAssertNotEqual(model.recentCommits.first?.hash, hiddenHead,
                              "Hidden Git panel must not keep polling")
            model.refresh()
            try await wait(seconds: 35) {
                !model.isRefreshing && model.recentCommits.first?.hash == hiddenHead
            }
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}
