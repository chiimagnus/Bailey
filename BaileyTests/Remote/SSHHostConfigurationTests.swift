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

    func testDeepIncludesAndSymlinkCycleUseFileIdentityInsteadOfArbitraryDepthLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-SSH-Include-\(UUID())", isDirectory: true)
        let includes = root.appendingPathComponent("config.d", isDirectory: true)
        try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = root.appendingPathComponent("config")
        try "Host first\nInclude config.d/level0.conf\n"
            .write(to: config, atomically: true, encoding: .utf8)
        for index in 0..<15 {
            let next = index == 14
                ? "Host deep\nInclude config.d/loop.conf\n"
                : "Include config.d/level\(index + 1).conf\n"
            try next.write(
                to: includes.appendingPathComponent("level\(index).conf"),
                atomically: true, encoding: .utf8
            )
        }
        try FileManager.default.createSymbolicLink(
            at: includes.appendingPathComponent("loop.conf"),
            withDestinationURL: config
        )

        XCTAssertEqual(
            SSHHostConfiguration.aliases(configURL: config),
            ["first", "deep"],
            "Deep but finite includes must work; symlink cycles must not recur"
        )
    }

    func testMissingConfigurationHasNoImplicitHost() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-no-ssh-\(UUID())")
        XCTAssertEqual(SSHHostConfiguration.aliases(configURL: missing), [])
    }
}
