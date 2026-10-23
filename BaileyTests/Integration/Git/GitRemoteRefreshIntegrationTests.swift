import Foundation
import XCTest
@testable import Bailey

@MainActor
final class GitRemoteRefreshIntegrationTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

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

    func testRemotePollQueuesSlowDetailRefreshAndStopsOnCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-git-slow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func git(_ args: [String]) {
            let result = GitCommandExecution.run(args, in: directory.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "Slow Refresh Test"])
        git(["config", "user.email", "fixture@invalid"])
        git(["config", "commit.gpgsign", "false"])
        let file = directory.appendingPathComponent("tracked.txt")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        git(["add", "tracked.txt"])
        git(["commit", "-qm", "baseline"])

        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:slow-details")
        try await wait { model.hasResolvedStatus && !model.isRefreshing && model.isRepo }
        let polling = Task { await model.runRemoteRefreshLoop() }
        defer { polling.cancel() }

        await backend.suspendHistoryRequest()
        model.refresh()
        let pendingDeadline = Date().addingTimeInterval(10)
        while !(await backend.awaitingGit), Date() < pendingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let awaitingDetails = await backend.awaitingGit
        XCTAssertTrue(awaitingDetails, "The original status snapshot must be in flight")
        try "external change\n".write(to: file, atomically: true, encoding: .utf8)
        git(["add", "tracked.txt"])
        XCTAssertTrue(model.stagedEntries.isEmpty)

        // The active SSH poll must queue the new observation despite an older detail read.
        try await Task.sleep(for: .seconds(6.2))
        await backend.releaseGitRequest()
        try await wait(seconds: 3) {
            model.stagedEntries.contains { $0.path == "tracked.txt" }
                && !model.changedEntries.contains { $0.path == "tracked.txt" }
        }
        let staged = GitCommandExecution.run(["diff", "--cached", "--name-only"], in: directory.path)
        XCTAssertEqual(staged.status, 0)
        XCTAssertEqual(staged.stdout, "tracked.txt\n")

        // Cancelling the owning task must prevent a queued poll from starting.
        try await wait { !model.isRefreshing }
        await backend.suspendHistoryRequest()
        model.refresh()
        let hidingDeadline = Date().addingTimeInterval(10)
        while !(await backend.awaitingGit), Date() < hidingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let hidingDetails = await backend.awaitingGit
        XCTAssertTrue(hidingDetails)
        let coreReadsBeforeHide = await backend.commands.filter {
            $0.contains("'--show-toplevel'")
        }.count
        XCTAssertGreaterThan(coreReadsBeforeHide, 0)
        try await Task.sleep(for: .seconds(6.2))
        polling.cancel()
        await polling.value
        try "modified after hiding\n".write(to: file, atomically: true, encoding: .utf8)
        await backend.releaseGitRequest()
        try await wait(seconds: 8) { !model.isRefreshing }
        let coreReadsAfterHide = await backend.commands.filter {
            $0.contains("'--show-toplevel'")
        }.count
        XCTAssertEqual(coreReadsAfterHide, coreReadsBeforeHide,
                       "Cancellation must not start the remote poll that was waiting on details")
        XCTAssertTrue(model.changedEntries.isEmpty,
                      "A cancelled remote polling task must not read new external changes")
        let truth = GitCommandExecution.run(["status", "--short"], in: directory.path)
        XCTAssertEqual(truth.status, 0)
        XCTAssertTrue(truth.stdout.hasPrefix("MM "), truth.stdout)
    }

    func testAuthorizedSSHRemotePollDetectsExternalChangesAndStopsWhenCancelled() async throws {
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

            let manager = self.workspaceApplication.makeWindow()
            defer { manager.windowClosed() }
            let project = Project(
                fallbackName: "External SSH Fixture", workspaceConfiguration: .standard
            )
            project.sshHost = host
            project.customDirectory = root
            manager.projects = [project]
            manager.selectedProjectID = project.id
            let model = GitStatusModel()
            manager.syncGitStatus(model)
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

            var polling = Task { await model.runRemoteRefreshLoop() }
            defer { polling.cancel() }

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

            polling.cancel()
            await polling.value
            try await wait(seconds: 15) { !model.isRefreshing }
            try await remote("printf 'background\\n' >> tracked.txt", via: external)
            try await Task.sleep(for: .seconds(7))
            XCTAssertTrue(model.changedEntries.isEmpty, "A cancelled remote Git loop must not poll")

            polling = Task { await model.runRemoteRefreshLoop() }
            try await wait(seconds: 30) {
                model.changedEntries.contains { $0.path == "tracked.txt" }
            }
            // SSH delivers working-tree status before its Ref/history details.
            // Finish this visible-panel refresh before checking whether hiding
            // the view prevents NEW polling, not completion of an old request.
            try await wait(seconds: 35) {
                !model.isRefreshing && model.recentCommits.first?.hash == newHead
            }

            polling.cancel()
            await polling.value
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
                              "Cancelled remote Git loop must not keep polling")
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
