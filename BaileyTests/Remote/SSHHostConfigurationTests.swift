import Foundation
import XCTest
@testable import Bailey

@MainActor
final class SSHHostConfigurationTests: XCTestCase {
    func testExplicitHostsFollowIncludeAndIgnorePatterns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-SSH-Host-Config-\(UUID())", isDirectory: true)
        let includes = root.appendingPathComponent("config.d", isDirectory: true)
        try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        Host main backup
        Include config.d/*.conf
        Host * !disabled
        """.write(to: root.appendingPathComponent("config"),
                   atomically: true, encoding: .utf8)
        try """
        Host backup secondary
        Include config
        """.write(to: includes.appendingPathComponent("a.conf"),
                   atomically: true, encoding: .utf8)

        XCTAssertEqual(
            SSHHostConfiguration.aliases(configURL: root.appendingPathComponent("config")),
            ["main", "backup", "secondary"]
        )
    }

    func testMissingConfigurationHasNoImplicitHost() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-no-ssh-\(UUID())")
        XCTAssertEqual(SSHHostConfiguration.aliases(configURL: missing), [])
    }
}
