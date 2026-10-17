import Foundation
import XCTest
@testable import Bailey

@MainActor
final class TunnelStoreTests: XCTestCase {
    func testLocalAndRemoteTunnelRoundTripPreservesRouting() {
        let local = TunnelDefinition(
            name: "Desktop \"RDP\"", host: "oracle",
            localPort: 13389, remotePort: 3389, isEnabled: true
        )
        let remote = TunnelDefinition(
            name: "Reverse SSH", host: "oracle", direction: .remote,
            localPort: 22, remotePort: 2222, isEnabled: true
        )

        let loaded = TunnelStore.parse(TunnelStore.serialize([local, remote]))
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.name), [local.name, remote.name])
        XCTAssertEqual(loaded.map(\.direction), [.local, .remote])
        XCTAssertTrue(loaded.allSatisfy(\.isEnabled))
        XCTAssertEqual(loaded[0].forwardSpecification, "127.0.0.1:13389:127.0.0.1:3389")
        XCTAssertEqual(loaded[0].listenPort, 13389)
        XCTAssertEqual(loaded[1].forwardSpecification, "127.0.0.1:2222:127.0.0.1:22")
        XCTAssertEqual(loaded[1].listenPort, 2222)
        XCTAssertEqual(loaded[1].listenAddress, "127.0.0.1:2222")
        XCTAssertNil(loaded[0].validationProblem)
        XCTAssertNil(loaded[1].validationProblem)
    }

    func testExistingConfigurationAndMalformedTablesDoNotLoseValidTunnels() {
        let text = """
            # unrelated user-edited settings
            [other]
            host = "ignored"
            [[tunnel]]
            host = "a1"
            local-port = 9292
            remote-port = 9292
            [[tunnel]]
            name = "missing host"
            local-port = 1
            [[tunnel]]
            host = "a1"
            direction = "sideways"
            local-port = 8080
            remote-port = 8080
            """
        let parsed = TunnelStore.parse(text)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.map(\.name), ["a1", "a1"])
        XCTAssertEqual(parsed.map(\.direction), [.local, .local])
        XCTAssertFalse(parsed[0].isEnabled)
        XCTAssertFalse(parsed[1].isEnabled)
    }

    func testMalformedPortsDoNotCrashOrCorruptValidTunnels() {
        let text = """
            [[tunnel]]
            host = "bad-infinite"
            local-port = 1e309
            remote-port = 3389
            [[tunnel]]
            host = "bad-not-a-number"
            local-port = nan
            remote-port = 3389
            [[tunnel]]
            host = "bad-fractional"
            local-port = 1234.5
            remote-port = 3389
            [[tunnel]]
            host = "working"
            local-port = 4444
            remote-port = 8080
            """
        let loaded = TunnelStore.parse(text)
        XCTAssertEqual(loaded.map(\.host), ["working"])
        XCTAssertEqual(loaded.first?.localPort, 4444)
    }

    func testListenerConflictsAndInvalidHostOrPort() {
        let local = TunnelDefinition(
            name: "RDP", host: "oracle", localPort: 13389,
            remotePort: 3389, isEnabled: true
        )
        let reverse = TunnelDefinition(
            name: "SSH", host: "oracle", direction: .remote,
            localPort: 22, remotePort: 2222, isEnabled: true
        )
        XCTAssertTrue(local.listensAlongside(local))
        XCTAssertTrue(reverse.listensAlongside(reverse))
        XCTAssertFalse(local.listensAlongside(reverse))
        var differentHost = reverse
        differentHost.host = "another"
        XCTAssertFalse(reverse.listensAlongside(differentHost))
        var samePort = local
        samePort.localPort = 2222
        XCTAssertFalse(local.listensAlongside(samePort))
        XCTAssertNil(local.validationProblem)

        var invalid = local
        invalid.host = "-oProxyCommand=x"
        XCTAssertNotNil(invalid.validationProblem)
        invalid = local
        invalid.localPort = 80
        XCTAssertNotNil(invalid.validationProblem)

        // Remote forwards do not bind their destination port on this Mac.
        invalid = reverse
        invalid.localPort = 80
        XCTAssertNil(invalid.validationProblem)
        invalid.localHost = ""
        XCTAssertNotNil(invalid.validationProblem)
    }
}
