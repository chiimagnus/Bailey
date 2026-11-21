import Foundation
import XCTest
@testable import Bailey

@MainActor
final class MarkdownResourceScopeTests: XCTestCase {
    func testFinderMarkdownOutsideCurrentProjectCanReadOwnAssetsAndLinksOnlyInsideItsFolder() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectRoot = temporary.appending(path: "Workspace")
        let importedFolder = temporary.appending(path: "External")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let document = importedFolder.appending(path: "Readme.md")
        let linked = importedFolder.appending(path: "Guide.md")
        let asset = importedFolder.appending(path: "asset.txt")
        let outside = temporary.appending(path: "secret.md")
        try Data("# Readme".utf8).write(to: document)
        try Data("# Guide".utf8).write(to: linked)
        try Data("safe resource".utf8).write(to: asset)
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: importedFolder.appending(path: "escaped.md"), withDestinationURL: outside
        )

        let project = Project(fallbackName: "Workspace", workspaceConfiguration: .standard)
        project.customDirectory = projectRoot.path
        project.openLocalFile(document.path)
        guard case .file(let source)? = project.focusedContent else {
            return XCTFail("Finder must deliver one local Markdown file tab")
        }
        try await source.waitForText()
        let resource = source.markdownResource(in: project.customDirectory)
        let bytes = try await resource.read(try XCTUnwrap(URL(string: "asset.txt")), maxBytes: 128)
        XCTAssertEqual(bytes, Data("safe resource".utf8))
        let opened = await project.openMarkdownLink(try XCTUnwrap(URL(string: "Guide.md")), from: source) { true }
        XCTAssertTrue(opened)
        XCTAssertEqual(project.tabs.count, 2)
        guard case .file(let target)? = project.focusedContent else {
            return XCTFail("Opening a sibling link should reuse native FileTab")
        }
        try await target.waitForText()
        XCTAssertEqual(target.path, linked.path)
        XCTAssertNil(target.workspaceIdentity)
        let escaped = await project.openMarkdownLink(try XCTUnwrap(URL(string: "../secret.md")), from: source) { true }
        XCTAssertFalse(escaped)
        let symlinkEscape = await project.openMarkdownLink(
            try XCTUnwrap(URL(string: "escaped.md")), from: source
        ) { true }
        XCTAssertFalse(symlinkEscape)
        XCTAssertEqual(project.tabs.count, 2)
    }

    func testFinderFileInSSHProjectCannotBorrowTheRemoteRootByTextualPathCoincidence() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let docs = temporary.appending(path: "docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let document = docs.appending(path: "Readme.md")
        try Data("# Finder file".utf8).write(to: document)
        try Data("private".utf8).write(to: temporary.appending(path: "secret.md"))
        try Data("# Guide".utf8).write(to: docs.appending(path: "Guide.md"))

        let project = Project(fallbackName: "SSH", workspaceConfiguration: .standard)
        project.sshHost = "unreachable-ssh-fixture"
        // Remote and local paths are strings, so they can coincide without
        // representing files on the same machine.
        project.customDirectory = temporary.path
        project.openLocalFile(document.path)
        guard case .file(let source)? = project.focusedContent else {
            return XCTFail("Finder file must remain local even in an SSH project")
        }
        try await source.waitForText()
        XCTAssertNil(source.workspaceIdentity)
        XCTAssertNotNil(project.workspaceIdentity)

        let escaped = await project.openMarkdownLink(try XCTUnwrap(URL(string: "../secret.md")), from: source) { true }
        XCTAssertFalse(escaped, "The unrelated SSH project root must not authorize reading local parent files")
        XCTAssertEqual(project.tabs.count, 1)

        let sibling = await project.openMarkdownLink(try XCTUnwrap(URL(string: "Guide.md")), from: source) { true }
        XCTAssertTrue(sibling, "An explicitly Finder-opened local file should still open local sibling links")
        guard case .file(let target)? = project.focusedContent else {
            return XCTFail("Expected a local native file tab")
        }
        XCTAssertNil(target.workspaceIdentity)
    }

    func testMarkdownInsideProjectKeepsCrossFolderRelativeResources() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let docs = temporary.appending(path: "docs")
        let assets = temporary.appending(path: "assets")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let document = docs.appending(path: "Readme.md")
        try Data("# Readme".utf8).write(to: document)
        try Data("safe".utf8).write(to: assets.appending(path: "image.dat"))
        let project = Project(fallbackName: "Workspace", workspaceConfiguration: .standard)
        project.customDirectory = temporary.path
        project.openFile(document.path)
        guard case .file(let source)? = project.focusedContent else {
            return XCTFail("Project file must be a native FileTab")
        }
        try await source.waitForText()
        let bytes = try await source.markdownResource(in: project.customDirectory)
            .read(try XCTUnwrap(URL(string: "../assets/image.dat")), maxBytes: 128)
        XCTAssertEqual(bytes, Data("safe".utf8))
    }
}
