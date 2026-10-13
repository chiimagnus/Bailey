import Foundation
import XCTest
@testable import kero

final class RemoteLifetimeTests: XCTestCase {
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

    @MainActor
    func testBackendsRetainConnectionAndDisconnectedState() {
        var connection: RemoteConnection? = RemoteConnection(
            user: "fixture", host: "invalid", port: 22,
            controlSocket: URL(fileURLWithPath: "/tmp/kero-no-such-control-socket"), sshPID: 0
        )
        XCTAssertEqual(connection?.workspaceIdentity, "fixture@invalid")
        let second = RemoteConnection(
            user: "fixture", host: "invalid", port: 2222,
            controlSocket: URL(fileURLWithPath: "/tmp/kero-another-socket"), sshPID: 0
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
        var liveness: SSHWorkspaceBackend? = connection!.livenessBackend
        connection = nil
        XCTAssertNotNil(releasedConnection)
        backend = nil
        XCTAssertNotNil(releasedConnection)
        liveness = nil
        XCTAssertNil(releasedConnection)
    }
}
