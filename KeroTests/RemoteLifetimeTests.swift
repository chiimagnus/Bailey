import Darwin
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
    func testConnectionOwnsControllerAndBackendsOwnConnectionLifetime() async throws {
        var connection: RemoteConnection? = RemoteConnection(
            user: "fixture", host: "invalid", port: 22,
            controlSocket: URL(fileURLWithPath: "/tmp/kero-no-such-control-socket"), sshPID: 0
        )
        weak let releasedConnection = connection
        weak let releasedController = connection!.portForwards
        var controller: PortForwardController? = connection!.portForwards
        var backend: SSHWorkspaceBackend? = connection!.workspaceBackend
        var liveness: SSHWorkspaceBackend? = connection!.livenessBackend

        XCTAssertTrue(controller === connection!.portForwards)
        connection = nil
        XCTAssertNotNil(releasedConnection)
        backend = nil
        XCTAssertNotNil(releasedConnection)
        liveness = nil
        XCTAssertNil(releasedConnection)

        do {
            _ = try await controller!.forward(remotePort: 8000)
            XCTFail("Released connection must reject forwarding")
        } catch RemoteConnectionError.notConnected {}
        controller = nil
        XCTAssertNil(releasedController)
        withExtendedLifetime(backend) {}
        withExtendedLifetime(liveness) {}
    }
}
