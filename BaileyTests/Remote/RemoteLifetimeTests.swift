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

        var contextChanges = 0
        connection.onWorkspaceChange = { contextChanges += 1 }
        connection.markDisconnected(reason: "fixture")
        connection.workingDirectory = "/repo/project"
        XCTAssertEqual(connection.state, .disconnected)
        XCTAssertEqual(contextChanges, 2)
        XCTAssertEqual(connection.workspaceIdentity, "fixture@invalid:2222")
    }

    @MainActor
    func testBackendsRetainConnectionAndDisconnectedState() {
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
        var backend: SSHWorkspaceBackend? = connection!.workspaceBackend
        XCTAssertTrue(backend === connection?.workspaceBackend)
        XCTAssertFalse(backend === second.workspaceBackend)
        var liveness: SSHWorkspaceBackend? = connection!.livenessBackend
        connection = nil
        XCTAssertNotNil(releasedConnection)
        backend = nil
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
