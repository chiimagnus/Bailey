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
        XCTAssertEqual(model.breadcrumbPaths.last, root.path)
        XCTAssertTrue(model.backHistory.isEmpty)
        XCTAssertTrue(model.canAdd)

        let selected = model.entries.filter { $0.name != ".hidden" }
            .map(model.path(for:))
        model.selection = Set(selected)
        XCTAssertEqual(Set(model.pathsToAdd), Set(selected))
        await model.browse(path: root.path)
        XCTAssertEqual(model.selection, Set(selected), "Reload keeps the existing valid selection")

        await model.browse(path: folder.path)
        XCTAssertEqual(model.currentDirectory, folder.path)
        XCTAssertEqual(model.parentDirectory, root.path)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.entries.map(\.name), ["子目录"])
        XCTAssertEqual(model.pathsToAdd, [folder.path])
        XCTAssertEqual(model.backHistory, [root.path])
        XCTAssertTrue(model.forwardHistory.isEmpty)
        await model.goBack()
        XCTAssertEqual(model.currentDirectory, root.path)
        XCTAssertTrue(model.backHistory.isEmpty)
        XCTAssertEqual(model.forwardHistory, [folder.path])
        await model.goForward()
        XCTAssertEqual(model.currentDirectory, folder.path)
        XCTAssertEqual(model.backHistory, [root.path])

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
        XCTAssertFalse(model.canAdd)
        XCTAssertTrue(model.manualPaths.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testHostSwitchDropsRemoteSelectionAndFailureDoesNotReplaceValidDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-picker-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let child = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
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
        XCTAssertTrue(model.backHistory.isEmpty, "Failed navigation leaves history untouched")
        await model.browse(path: child.path)
        XCTAssertEqual(model.backHistory, [root.path])

        model.host = "first"
        XCTAssertNil(model.currentDirectory)
        XCTAssertNil(model.homeDirectory)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.backHistory.isEmpty)
        XCTAssertTrue(model.forwardHistory.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canAdd)

        await model.browse(path: root.path)
        XCTAssertEqual(model.currentDirectory, root.path)
        model.invalidate()
        XCTAssertFalse(model.isLoading)
    }
}
