import Foundation
import XCTest
@testable import Bailey

@MainActor
final class SSHItemPickerTests: XCTestCase {
    func testRemoteBrowserListsFoldersFirstAndCanSelectCurrentOrMultiplePaths() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-picker-" + UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Folder with spaces", isDirectory: true)
        let nested = folder.appendingPathComponent("子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: root.appendingPathComponent("hello world.swift"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        defer { try? FileManager.default.removeItem(at: root) }

        let model = SSHItemPickerModel(
            aliases: ["fixture", "fixture"],
            backendForHost: { _ in LocalWorkspaceBackend.shared }
        )
        XCTAssertEqual(model.aliases, ["fixture"])
        XCTAssertFalse(model.canAdd)

        await model.browse(path: root.path)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.currentDirectory, root.path)
        XCTAssertTrue(model.entries.first?.isDirectory == true)
        XCTAssertEqual(Set(model.entries.map(\.name)),
                       ["Folder with spaces", "hello world.swift", ".hidden"])
        XCTAssertEqual(model.pathsToAdd, [root.path])
        XCTAssertTrue(model.canAdd)

        let selected = model.entries.filter { $0.name != ".hidden" }
            .map(model.path(for:))
        model.selection = Set(selected)
        XCTAssertEqual(Set(model.pathsToAdd), Set(selected))

        await model.browse(path: folder.path)
        XCTAssertEqual(model.currentDirectory, folder.path)
        XCTAssertEqual(model.parentDirectory, root.path)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.entries.map(\.name), ["子目录"])
        XCTAssertEqual(model.pathsToAdd, [folder.path])

        XCTAssertNotNil(model.homeDirectory)
    }

    func testManualPathsNormalizeWindowsDriveAndDoNotImplicitlyAddCurrentFolder() {
        let model = SSHItemPickerModel(aliases: ["fixture"])
        model.manualPaths = "D:\\GitHub\\work\r\n /tmp/hello world \n/d/GitHub/work\n"
        model.selection = ["/tmp/中文 项目"]
        XCTAssertEqual(model.pathsToAdd, [
            "/d/GitHub/work", "/tmp/hello world", "/tmp/中文 项目",
        ])
        XCTAssertTrue(model.canAdd)
        model.manualPaths += "relative/path\n"
        XCTAssertFalse(model.canAdd)
        model.manualPaths = "D:\\GitHub\\work\r\n /tmp/hello world \n/d/GitHub/work\n"

        model.host = "-invalid"
        XCTAssertFalse(model.canAdd)
        model.host = "other"
        XCTAssertTrue(model.canAdd)
        XCTAssertEqual(model.manualPaths.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }.count, 3)
    }

    func testHostSwitchDropsRemoteSelectionAndFailureDoesNotReplaceValidDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-picker-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = SSHItemPickerModel(
            aliases: ["first", "second"], preferredHost: "second",
            backendForHost: { _ in LocalWorkspaceBackend.shared }
        )
        XCTAssertEqual(model.host, "second")
        await model.browse(path: root.path)
        XCTAssertEqual(model.currentDirectory, root.path)
        model.selection = [root.path]
        await model.browse(path: root.appendingPathComponent("missing").path)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.currentDirectory, root.path)
        XCTAssertEqual(model.selection, [root.path])

        model.host = "first"
        XCTAssertNil(model.currentDirectory)
        XCTAssertNil(model.homeDirectory)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canAdd)

        await model.browse(path: root.path)
        XCTAssertEqual(model.currentDirectory, root.path)
        model.invalidate()
        XCTAssertFalse(model.isLoading)
    }
}
