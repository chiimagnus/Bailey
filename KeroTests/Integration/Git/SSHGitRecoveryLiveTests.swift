import Foundation
import XCTest
@testable import kero

/// A dedicated SSH transport that can fail without disturbing other sessions.
private actor InterruptibleSSHRunner: RemoteCommandRunner {
    let base: SSHHostCommandRunner
    private var unavailable = false

    init(host: String, socket: String) {
        base = SSHHostCommandRunner(host: host, socket: socket)
    }

    func setUnavailable(_ value: Bool) { unavailable = value }

    func run(_ argv: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> (status: Int32, stdout: Data, stderr: Data)
    {
        if unavailable { throw WorkspaceError.timedOut }
        return try await base.run(argv, stdin: stdin, timeout: timeout)
    }
}

@MainActor
final class SSHGitRecoveryLiveTests: XCTestCase {
    func testAuthorizedWindowsGitSnapshotSurvivesTransportFailureAndCanWriteOnlyAfterRecovery() async throws {
        guard let host = ProcessInfo.processInfo.environment["KERO_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set KERO_P4_TEST_SSH_HOST to an explicitly authorized SSH test host")
        }
        let socket = "/tmp/kero-git-recovery-\(UUID().uuidString.prefix(8)).sock"
        let runner = InterruptibleSSHRunner(host: host, socket: socket)
        let backend = SSHWorkspaceBackend(runner: runner, timeout: 25)
        let created = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/kero-git-recovery-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(created.status, 0, String(decoding: created.stderr, as: UTF8.self))
        let root = String(decoding: created.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("kero-git-recovery-") else {
            throw WorkspaceError.notFound
        }
        func cleanup() async {
            await runner.setUnavailable(false)
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Unable to delete test-owned Windows repository: \(error)") }
            do {
                let result = try await Task.detached {
                    try ProcessRemoteCommandRunner.launch(
                        sshPath: "/usr/bin/ssh", arguments: ["-S", socket, "-O", "exit", host],
                        stdin: nil, timeout: 10
                    )
                }.value
                XCTAssertEqual(result.status, 0, "Unable to stop test-owned SSH master")
            } catch { XCTFail("Unable to stop test-owned SSH master: \(error)") }
        }
        do {
            func git(_ arguments: [String]) async throws -> String {
                let result = await GitCommandExecution.run(arguments, in: root, timeout: 25, backend: backend)
                guard result.status == 0 else {
                    XCTFail("Remote Git command failed: \(arguments.first ?? "?")")
                    throw WorkspaceError.notFound
                }
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func wait(_ predicate: () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(30)
                while !predicate() {
                    guard Date() < deadline else {
                        XCTFail("Remote Git recovery did not settle")
                        throw WorkspaceError.timedOut
                    }
                    try await Task.sleep(for: .milliseconds(30))
                }
            }
            for args in [
                ["init", "-q"], ["config", "user.name", "Kero Recovery"],
                ["config", "user.email", "recovery@example.invalid"],
                ["config", "commit.gpgsign", "false"]
            ] { _ = try await git(args) }
            let file = root + "/tracked.txt"
            try await backend.createFile(path: file)
            try await backend.write(path: file, data: Data("base\n".utf8))
            _ = try await git(["add", "--", "tracked.txt"])
            _ = try await git(["commit", "-qm", "baseline"])
            try await backend.write(path: file, data: Data("base\nmodified\n".utf8))

            let model = GitStatusModel()
            let coldStart = ProcessInfo.processInfo.systemUptime
            model.sync(root: root, backend: backend, scope: "ssh:authorized-recovery")
            try await wait { model.hasResolvedStatus }
            let firstCore = ProcessInfo.processInfo.systemUptime - coldStart
            try await wait { !model.isRefreshing }
            let firstDetails = ProcessInfo.processInfo.systemUptime - coldStart
            if ProcessInfo.processInfo.environment["KERO_SSH_BENCHMARK"] == "1" {
                print(String(format: "KERO_GIT_BENCHMARK cold-core=%.3fs cold-complete=%.3fs",
                             firstCore, firstDetails))
            }
            XCTAssertTrue(model.isRepo)
            XCTAssertNil(model.statusError)
            XCTAssertEqual(model.recentCommits.map(\.subject), ["baseline"])
            let pending = try XCTUnwrap(model.changedEntries.first { $0.path == "tracked.txt" })
            XCTAssertTrue(model.isCurrent(pending))

            await runner.setUnavailable(true)
            model.refresh()
            try await wait { model.statusError != nil && !model.isRefreshing }
            XCTAssertTrue(model.isRepo)
            XCTAssertEqual(model.recentCommits.map(\.subject), ["baseline"])
            XCTAssertEqual(model.changedEntries.map(\.path), ["tracked.txt"])
            XCTAssertFalse(model.canUseCurrentStatus)
            XCTAssertFalse(model.isCurrent(pending))
            model.stage(pending)
            XCTAssertFalse(model.isBusy, "Stale SSH status must reject stage before remote IO")

            await runner.setUnavailable(false)
            let indexWhileOffline = try await git(["diff", "--cached", "--name-only"])
            XCTAssertEqual(indexWhileOffline, "")
            model.refresh()
            try await wait { model.statusError == nil && !model.isRefreshing }
            XCTAssertTrue(model.isCurrent(model.actionTarget()))
            XCTAssertEqual(model.recentCommits.map(\.subject), ["baseline"])
            let current = try XCTUnwrap(model.changedEntries.first { $0.path == "tracked.txt" })
            model.stage(current)
            try await wait { !model.isBusy && model.operation?.finishedAt != nil }
            let staged = try await git(["diff", "--cached", "--name-only"])
            XCTAssertEqual(staged, "tracked.txt")
            model.unstageAll()
            try await wait { !model.isBusy && model.stagedEntries.isEmpty }
            let unstaged = try await git(["diff", "--cached", "--name-only"])
            XCTAssertEqual(unstaged, "")

            if ProcessInfo.processInfo.environment["KERO_SSH_BENCHMARK"] == "1" {
                var samples: [Double] = []
                for _ in 0..<30 {
                    let start = ProcessInfo.processInfo.systemUptime
                    model.refresh()
                    try await wait { !model.isRefreshing }
                    XCTAssertNil(model.statusError)
                    XCTAssertNil(model.detailError)
                    samples.append(ProcessInfo.processInfo.systemUptime - start)
                }
                let sorted = samples.sorted()
                print(String(format: "KERO_GIT_BENCHMARK warm-complete n=30 median=%.3fs p95=%.3fs max=%.3fs",
                             (sorted[14] + sorted[15]) / 2, sorted[28], sorted[29]))
            }
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}
