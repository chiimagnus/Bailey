import Darwin
import Foundation
import Observation
import XCTest
@testable import Bailey

final class RemoteLifetimeTests: XCTestCase {
    @MainActor
    func testExhaustedMultiplexBudgetDoesNotStartALivenessCheck() async {
        let connection = RemoteConnection(user: "fixture", host: "invalid", port: 2222,
            controlSocket: URL(fileURLWithPath: "/tmp/bailey-budget-" + UUID().uuidString), sshPID: 0)
        for budget: TimeInterval in [0, -1] {
            do {
                _ = try await connection.run(["true"], timeout: budget)
                XCTFail("Expected exhausted budget")
            } catch {
                guard case WorkspaceError.timedOut = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(connection.state, .connecting)
        }
    }

    func testIndependentCommandRunnerPreservesStreamsAndBoundsPipes() throws {
        let normal = try ProcessRemoteCommandRunner.launch(
            sshPath: "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; cat"],
            stdin: Data("input".utf8),
            timeout: 2
        )
        XCTAssertEqual(normal.status, 0)
        XCTAssertEqual(normal.stdout, Data("outinput".utf8))
        XCTAssertEqual(normal.stderr, Data("err".utf8))

        let failure = try ProcessRemoteCommandRunner.launch(
            sshPath: "/bin/sh", arguments: ["-c", "exit 7"], stdin: nil, timeout: 2
        )
        XCTAssertEqual(failure.status, 7)

        let started = Date()
        XCTAssertThrowsError(try ProcessRemoteCommandRunner.launch(
            sshPath: "/bin/sh",
            arguments: ["-c", "(sleep 0.5) & printf retained"],
            stdin: nil,
            timeout: 0.05
        )) { error in
            guard case WorkspaceError.timedOut = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4)
    }

    func testCancelStopsTheActualRemoteCommandRunnerProcess() async throws {
        let started = Date()
        let command = Task.detached(priority: .utility) {
            try ProcessRemoteCommandRunner.launch(
                sshPath: "/bin/sleep", arguments: ["8"], stdin: nil, timeout: 4,
                stdoutLimit: 32, stderrLimit: 32
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        command.cancel()
        do {
            _ = try await command.value
            XCTFail("Cancelled SSH process must not return a successful result")
        } catch is CancellationError {
        } catch {
            XCTFail("Cancelled SSH process returned the wrong failure: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testCancelledRemoteInputWriterDoesNotWaitForInheritedPipeTimeout() async throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-remote-stdin-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let escaped = "'" + pidURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let started = Date()
        let command = Task.detached(priority: .utility) {
            try ProcessRemoteCommandRunner.launch(
                sshPath: "/bin/sh",
                arguments: ["-c", "exec 3<&0; /bin/sleep 4 0<&3 >/dev/null 2>&1 & echo $! > \(escaped); exit 0"],
                stdin: Data(repeating: 0x62, count: 2 * 1024 * 1024), timeout: 3,
                stdoutLimit: 128, stderrLimit: 128
            )
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGTERM) } }
        command.cancel()
        do {
            _ = try await command.value
            XCTFail("Cancelled remote stdin writer must not report success")
        } catch is CancellationError {
        } catch {
            XCTFail("Cancelled remote stdin writer returned the wrong error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1,
                          "Remote stdout completion cannot conceal a stuck stdin writer")
    }

    func testCancelledRemoteRunnerReapsItsExactPID() async throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-remote-cancel-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let path = "'" + pidURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = Task.detached(priority: .utility) {
            try ProcessRemoteCommandRunner.launch(
                sshPath: "/bin/sh",
                arguments: ["-c", "echo $$ > \(path); exec /bin/sleep 8"],
                stdin: nil, timeout: 5, stdoutLimit: 128, stderrLimit: 128
            )
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(pidText))
        XCTAssertEqual(Darwin.kill(pid, 0), 0)
        command.cancel()
        do {
            _ = try await command.value
            XCTFail("Cancelled child must not succeed")
        } catch is CancellationError {
        }
        var exited = false
        for _ in 0..<50 {
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { exited = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(exited, "An abandoned SSH command must not leave its process running")
    }

    func testBoundedRemotePipeStopsBeforeLargeOutputIsCollected() throws {
        let exact = try ProcessRemoteCommandRunner.launch(
            sshPath: "/bin/sh", arguments: ["-c", "printf abcde; printf err >&2"],
            stdin: nil, timeout: 2, stdoutLimit: 5, stderrLimit: 3
        )
        XCTAssertEqual(exact.status, 0)
        XCTAssertEqual(exact.stdout, Data("abcde".utf8))
        XCTAssertEqual(exact.stderr, Data("err".utf8))

        let scripts = [
            "print STDOUT 'x' x (16 * 1024 * 1024)",
            "print STDERR 'e' x (16 * 1024 * 1024)",
            "$|=1; while (1) { print STDOUT 'a' x 4096; print STDERR 'b' x 4096 }",
        ]
        for script in scripts {
            let start = Date()
            let output = ProcessRemoteCommandRunner.run(
                sshPath: "/usr/bin/perl", arguments: ["-e", script],
                stdin: nil, timeout: 4, stdoutLimit: 4_096, stderrLimit: 4_096
            )
            XCTAssertEqual(output.status, -3, "An oversized stream must not publish success")
            XCTAssertLessThanOrEqual(output.stdout.count, 4_096)
            XCTAssertLessThanOrEqual(output.stderr.count, 4_096)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2,
                              "A rejected command must stop rather than drain the full stream")
            XCTAssertThrowsError(try ProcessRemoteCommandRunner.launch(
                sshPath: "/usr/bin/perl", arguments: ["-e", script],
                stdin: nil, timeout: 4, stdoutLimit: 4_096, stderrLimit: 4_096
            )) { error in
                guard case WorkspaceError.tooLarge = error else {
                    return XCTFail("Expected output limit, got \(error)")
                }
            }
        }

        let abnormal = try ProcessRemoteCommandRunner.launch(
            sshPath: "/bin/sh", arguments: ["-c", "printf abc; printf warning >&2; exit 7"],
            stdin: nil, timeout: 2, stdoutLimit: 8, stderrLimit: 16
        )
        XCTAssertEqual(abnormal.status, 7)
        XCTAssertEqual(abnormal.stdout, Data("abc".utf8))
        XCTAssertEqual(abnormal.stderr, Data("warning".utf8))
    }

    func testPrivateSSHSocketHandoffCompletesAcrossWorkerAndMainActor() async throws {
        let path = "/tmp/bailey-ssh-test-\(UUID().uuidString.prefix(8)).sock"
        let listener = try BaileySSHSocketServer(path: path) { request, reply in
            Task { @MainActor in
                reply(BaileySSHResponse(
                    socket: request.token == "valid" && request.host == "fixture.invalid"
                        ? "/tmp/fixture-master.sock" : nil
                ))
            }
        }
        let valid = BaileySSHRequest(
            token: "valid", terminalID: UUID().uuidString,
            user: "fixture", host: "fixture.invalid", port: 2222, pid: getpid()
        )
        let accepted = try await Task.detached {
            try BaileySSHSocketServer.exchange(path: path, request: valid, timeout: 3)
        }.value
        XCTAssertEqual(accepted.socket, "/tmp/fixture-master.sock")

        let rejected = BaileySSHRequest(
            token: "invalid", terminalID: valid.terminalID,
            user: valid.user, host: valid.host, port: valid.port, pid: valid.pid
        )
        let refused = try await Task.detached {
            try BaileySSHSocketServer.exchange(path: path, request: rejected, timeout: 3)
        }.value
        XCTAssertNil(refused.socket)
        withExtendedLifetime(listener) {}
    }

    @MainActor
    func testSSHStateAndWorkingDirectoryAreObserved() async {
        let connection = RemoteConnection(
            user: "fixture", host: "invalid", port: 2222,
            controlSocket: URL(fileURLWithPath: "/tmp/bailey-observation-fixture-missing"),
            sshPID: 0
        )
        let stateChanged = expectation(description: "SSH state observation")
        withObservationTracking({ _ = connection.state }) { stateChanged.fulfill() }
        connection.markConnected()
        await fulfillment(of: [stateChanged], timeout: 1)
        XCTAssertEqual(connection.state, .connected)

        let directoryChanged = expectation(description: "Remote directory observation")
        withObservationTracking({ _ = connection.workingDirectory }) {
            directoryChanged.fulfill()
        }
        connection.workingDirectory = "/repo"
        await fulfillment(of: [directoryChanged], timeout: 1)
        XCTAssertEqual(connection.workingDirectory, "/repo")

        connection.markDisconnected(reason: "fixture")
        connection.workingDirectory = "/repo/project"
        XCTAssertEqual(connection.state, .disconnected)
        XCTAssertEqual(connection.workspaceIdentity, "fixture@invalid:2222")
    }

    @MainActor
    func testLivenessBackendRetainsConnectionAndDisconnectedState() {
        var connection: RemoteConnection? = RemoteConnection(
            user: "fixture", host: "invalid", port: 22,
            controlSocket: URL(fileURLWithPath: "/tmp/bailey-no-such-control-socket"), sshPID: 0
        )
        XCTAssertEqual(connection?.workspaceIdentity, "fixture@invalid")
        let second = RemoteConnection(
            user: "fixture", host: "invalid", port: 2222,
            controlSocket: URL(fileURLWithPath: "/tmp/bailey-another-socket"), sshPID: 0
        )
        XCTAssertEqual(second.workspaceIdentity, "fixture@invalid:2222")
        XCTAssertNotEqual(connection?.workspaceIdentity, second.workspaceIdentity)

        connection!.markConnected()
        XCTAssertEqual(connection?.state, .connected)
        connection!.markDisconnected(reason: "controlled disconnection")
        XCTAssertEqual(connection?.state, .disconnected)
        connection!.markConnected()
        XCTAssertEqual(connection?.state, .connected)

        weak let releasedConnection = connection
        var liveness: SSHWorkspaceBackend? = connection!.livenessBackend
        connection = nil
        XCTAssertNotNil(releasedConnection)
        liveness = nil
        XCTAssertNil(releasedConnection)
    }

    @MainActor
    func testPrivateSSHServiceHandoffOnlyResolvesSessionsInItsOwningApplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstOwner = WorkspaceApplication()
        let otherOwner = WorkspaceApplication()
        let first = firstOwner.makeWindow()
        let second = otherOwner.makeWindow()
        first.addLocalFolders([root])
        second.addLocalFolders([root])
        let session = try XCTUnwrap(second.selectedProject?.newSession(directory: root.path))

        let service = BaileySSHService.shared
        let previousOwner = service.application
        let previousNotificationOwner = TerminalNotificationService.shared.application
        defer {
            first.windowClosed()
            second.windowClosed()
            service.application = previousOwner
            TerminalNotificationService.shared.application = previousNotificationOwner
        }
        let environment = service.terminalEnvironment(for: session.id)
        let socket = try XCTUnwrap(environment["BAILEY_SSH_SOCKET"])
        let token = try XCTUnwrap(environment["BAILEY_SSH_TOKEN"])
        let request = BaileySSHRequest(
            token: token,
            terminalID: session.id.uuidString,
            user: "fixture", host: "fixture.invalid", port: 2222, pid: getpid()
        )
        func exchange(_ input: BaileySSHRequest) async throws -> BaileySSHResponse {
            try await Task.detached {
                try BaileySSHSocketServer.exchange(path: socket, request: input, timeout: 3)
            }.value
        }

        // Even a genuine token must not find a session in another window owner.
        firstOwner.connectServices()
        let wrongOwnerResponse = try await exchange(request)
        XCTAssertNil(wrongOwnerResponse.socket)
        XCTAssertNil(session.location.remoteConnection)

        otherOwner.connectServices()
        let wrongToken = BaileySSHRequest(
            token: "unrecognized", terminalID: request.terminalID,
            user: request.user, host: request.host, port: request.port, pid: request.pid
        )
        let wrongTokenResponse = try await exchange(wrongToken)
        XCTAssertNil(wrongTokenResponse.socket)
        let accepted = try await exchange(request)
        XCTAssertNotNil(accepted.socket)
        XCTAssertEqual(session.location.remoteConnection?.controlSocket.path, accepted.socket)

        // Closing a window revokes access to its terminal, even when the
        // authenticated token is replayed before the service mapping expires.
        second.windowClosed()
        XCTAssertNil(otherOwner.session(id: session.id))
        let closedWindowResponse = try await exchange(request)
        XCTAssertNil(closedWindowResponse.socket)
    }

}
