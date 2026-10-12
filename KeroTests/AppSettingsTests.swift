import Foundation
import XCTest
@testable import kero

@MainActor
final class AppSettingsTests: XCTestCase {
    private var directory: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configURL = directory.appendingPathComponent("config.toml")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultsAndRoundTrip() throws {
        let defaults = AppSettings(configURL: configURL)
        XCTAssertTrue(defaults.fontFamily.isEmpty)
        XCTAssertEqual(defaults.fontSize, 13)
        XCTAssertFalse(defaults.fontThicken)
        XCTAssertEqual(defaults.workspaceConfiguration.groupNames, DockWorkspaceConfiguration.standard.groupNames)
        XCTAssertEqual(TOML.parse(at: configURL)?["font-size"]?.double, 13)

        try """
        font-family = "Fixture\\\"Font"
        font-size = 18
        panel.font-size = 16
        terminal.font-thicken = true
        workspace.groups = ["projects,files", "git,info"]
        workspace.selected = ["files", "git"]
        workspace.weights = [2, 3]
        workspace.add-actions = ["projects", "session", "files", "git", "info"]
        workspace.edge-threshold = 0.3
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let customized = AppSettings(configURL: configURL)
        XCTAssertEqual(customized.fontFamily, "Fixture\"Font")
        XCTAssertEqual(customized.fontSize, 18)
        XCTAssertEqual(customized.panelFontSize, 16)
        XCTAssertTrue(customized.fontThicken)
        XCTAssertEqual(customized.workspaceConfiguration.groupNames, ["projects,files", "git"])
        XCTAssertFalse(customized.workspaceConfiguration.addActions.map(\.rawValue).contains("info"))

        customized.fontSize = 19
        XCTAssertEqual(AppSettings(configURL: configURL).fontSize, 19)
    }

    func testInvalidValuesFallBackAndFailedWritePreservesExistingFile() throws {
        try "font-thicken = true\nfont-size = 100\nworkspace.groups = [1]\n".write(
            to: configURL, atomically: true, encoding: .utf8
        )
        let invalid = AppSettings(configURL: configURL)
        XCTAssertFalse(invalid.fontThicken)
        XCTAssertEqual(invalid.fontSize, 13)
        XCTAssertEqual(invalid.workspaceConfiguration.groupNames, DockWorkspaceConfiguration.standard.groupNames)

        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("preserve".utf8).write(to: blocked)
        let unwritable = AppSettings(configURL: blocked.appendingPathComponent("config.toml"))
        unwritable.fontSize = 20
        XCTAssertEqual(try String(contentsOf: blocked, encoding: .utf8), "preserve")
    }
}
