import XCTest
@testable import Bailey

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testNavigationContainsAllExistingSettingsAreas() {
        XCTAssertEqual(SettingsPage.allCases, [
            .general, .terminal, .workspace, .notifications, .portForwarding,
        ])
        XCTAssertTrue(SettingsPage.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    }

    func testNewLocalForwardUsesRemotePortUntilLocalPortIsSet() {
        var draft = TunnelEditDraft(existing: nil)
        draft.host = "ssh-alias"
        draft.remotePort = "3389"
        let result = draft.build(against: [])
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.tunnel?.name, "ssh-alias:3389")
        XCTAssertEqual(result.tunnel?.localPort, 3389)
        XCTAssertEqual(result.tunnel?.remotePort, 3389)
        XCTAssertEqual(result.tunnel?.remoteHost, "127.0.0.1")
        XCTAssertEqual(result.tunnel?.direction, .local)
        XCTAssertEqual(result.tunnel?.isEnabled, true)

        draft.localPort = "13389"
        XCTAssertEqual(draft.build(against: []).tunnel?.localPort, 13389)
    }

    func testEditingPreservesIdentityAndUnusedDirectionFields() {
        let existing = TunnelDefinition(
            name: "old", host: "host", direction: .remote,
            localHost: "localhost", localPort: 22,
            remoteHost: "somewhere", remotePort: 1222, isEnabled: true
        )
        var draft = TunnelEditDraft(existing: existing)
        draft.name = "new"
        let result = draft.build(against: [existing])
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.tunnel?.id, existing.id)
        XCTAssertEqual(result.tunnel?.remoteHost, existing.remoteHost)
        XCTAssertEqual(result.tunnel?.localHost, "localhost")
        XCTAssertEqual(result.tunnel?.localPort, 22)
        XCTAssertEqual(result.tunnel?.direction, .remote)
    }

    func testPortValidationCoversMalformedAndOutOfRangeInputs() {
        var draft = TunnelEditDraft(existing: nil)
        draft.host = "alias"
        for invalid in ["", "abc", "65536", "99999999999999999999999999", "0", "-1"] {
            draft.remotePort = invalid
            XCTAssertNil(draft.build(against: []).tunnel, "remote port: \(invalid)")
        }
        draft.remotePort = "80"
        XCTAssertNil(draft.build(against: []).tunnel) // auto local 80 is privileged
        draft.localPort = "1080"
        XCTAssertNotNil(draft.build(against: []).tunnel)
        for invalid in ["a", "-1", "65536", "999999999999999999999"] {
            draft.localPort = invalid
            XCTAssertNil(draft.build(against: []).tunnel, "local port: \(invalid)")
        }
        draft.localPort = "1080"
        draft.host = "-oProxyCommand=unsafe"
        XCTAssertNil(draft.build(against: []).tunnel)
    }

    func testConflictChecksListenMachineAndOnlyEnabledRules() {
        var draft = TunnelEditDraft(existing: nil)
        draft.host = "new-host"
        draft.remotePort = "3389"
        draft.localPort = "13389"
        let enabled = TunnelDefinition(
            name: "used", host: "other-host", localPort: 13389,
            remotePort: 22, isEnabled: true
        )
        XCTAssertNil(draft.build(against: [enabled]).tunnel)
        draft.isEnabled = false
        XCTAssertNotNil(draft.build(against: [enabled]).tunnel)

        draft.isEnabled = true
        draft.direction = .remote
        draft.remotePort = "2222"
        draft.localPort = "22"
        XCTAssertNotNil(draft.build(against: [enabled]).tunnel)
        let remoteDifferentHost = TunnelDefinition(
            name: "remote", host: "other-host", direction: .remote,
            localPort: 22, remotePort: 2222, isEnabled: true
        )
        XCTAssertNotNil(draft.build(against: [remoteDifferentHost]).tunnel)
        draft.host = "other-host"
        XCTAssertNil(draft.build(against: [remoteDifferentHost]).tunnel)
    }
}
