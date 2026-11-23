import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Bailey

@MainActor
final class MarkdownResourceScopeTests: XCTestCase {
    func testAuthorizedSSHMarkdownKeepsScopedResourcesAndOriginalBytes() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST to an explicitly authorized SSH test host")
        }
        let socket = "/tmp/bailey-md-\(UUID().uuidString.prefix(12)).sock"
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket))
        var verifiedFixture: String?

        func stopMaster() async throws {
            guard FileManager.default.fileExists(atPath: socket) else { return }
            let exited = try await Task.detached {
                try ProcessRemoteCommandRunner.launch(
                    sshPath: "/usr/bin/ssh", arguments: ["-S", socket, "-O", "exit", host],
                    stdin: nil, timeout: 10
                )
            }.value
            XCTAssertEqual(exited.status, 0)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while FileManager.default.fileExists(atPath: socket) {
                guard ContinuousClock.now < deadline else { throw WorkspaceError.timedOut }
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        func cleanup() async {
            if let verifiedFixture {
                do { try await backend.delete(paths: [verifiedFixture]) }
                catch { XCTFail("Could not remove the isolated remote Markdown fixture: \(error)") }
            }
            do { try await stopMaster() }
            catch { XCTFail("Could not stop the test-owned SSH master: \(error)") }
        }

        do {
            let prefix = "/tmp/bailey-markdown-"
            let created = try await backend.run(argv: ["mktemp", "-d", prefix + "XXXXXX"],
                                                cwd: nil, env: nil, stdin: nil, timeout: 25)
            let fixture = String(decoding: created.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard created.status == 0, fixture.hasPrefix(prefix),
                  fixture.utf8.count == prefix.utf8.count + 6,
                  fixture.utf8.dropFirst(prefix.utf8.count).allSatisfy({
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                  })
            else { throw WorkspaceError.notFound }
            verifiedFixture = fixture
            let directory = fixture + "/Project"
            let path = directory + "/Readme.md"
            let asset = directory + "/asset.svg"
            let rasterPath = directory + "/wide.png"
            let outside = fixture + "/outside.svg"
            let original = Data("\u{feff}# 测试 🧪\r\n\r\n![Scoped asset](asset.svg)\r\n".utf8)
            let svg = Data("""
                <svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="#1a7f37"/></svg>
                """.utf8)
            let made = try await backend.run(argv: ["mkdir", "--", directory],
                                             cwd: nil, env: nil, stdin: nil, timeout: 20)
            XCTAssertEqual(made.status, 0)
            try await backend.write(path: path, data: original)
            try await backend.write(path: asset, data: svg)
            try await backend.write(path: outside, data: svg)
            let canvas = try XCTUnwrap(CGContext(
                data: nil, width: 5000, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            let pngData = NSMutableData()
            let png = try XCTUnwrap(CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(png, try XCTUnwrap(canvas.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(png))
            let rasterBytes = pngData as Data
            try await backend.write(path: rasterPath, data: rasterBytes)

            let connection = RemoteConnection(user: "", host: host, port: 22,
                                              controlSocket: URL(fileURLWithPath: socket), sshPID: 0)
            guard await connection.check() else { throw RemoteConnectionError.notConnected }
            let channel = SSHWorkspaceBackend(runner: connection)
            let tab = FileTab(path: path, backend: channel, workspaceIdentity: "ssh:\(host)")
            try await tab.waitForText()
            let document = try await MarkdownDocument.parse(tab.text)
            XCTAssertEqual(document.headingOutline.first?.title, "测试 🧪")
            let resource = tab.markdownResource(in: directory)
            let rasterURL = try XCTUnwrap(URL(string: "wide.png"))
            let rasterTab = FileTab(path: rasterPath, backend: channel, workspaceIdentity: "ssh:\(host)")
            rasterTab.loadIfNeeded()
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while case .loading = rasterTab.content {
                guard ContinuousClock.now < deadline else { throw WorkspaceError.timedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard case .image(let raster) = rasterTab.content else { throw CocoaError(.fileReadCorruptFile) }
            XCTAssertEqual(raster.poster.width, 4096)
            let embedded = try await resource.picture(rasterURL)
            XCTAssertEqual(embedded.poster.width, 2048)
            let originalImage = try XCTUnwrap(rasterTab.originalImageRequest())
            let originalRaster = try await originalImage()
            XCTAssertEqual(originalRaster.width, 5000)
            XCTAssertEqual(originalRaster.height, 20)
            let relative = try XCTUnwrap(URL(string: "asset.svg"))
            let picture = try await resource.picture(relative)
            XCTAssertEqual(picture.pointSize?.width, 40)
            let resolved = try await resource.resolvedFile(relative)
            XCTAssertEqual(resolved, asset)
            do {
                _ = try await resource.read(relative, maxBytes: svg.count - 1)
                XCTFail("A real remote read must enforce its byte budget")
            } catch WorkspaceError.tooLarge {}
            do {
                _ = try await resource.read(try XCTUnwrap(URL(string: "../outside.svg")), maxBytes: 1024)
                XCTFail("A relative resource must not escape the authorized remote project")
            } catch let failure as CocoaError {
                XCTAssertEqual(failure.code, .fileReadNoPermission)
            }
            let stillOnDisk = try await backend.read(path: path, maxBytes: original.count)
            XCTAssertEqual(stillOnDisk, original, "Reading and parsing must preserve remote source bytes")

            guard mkdir(fixture, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { try? FileManager.default.removeItem(atPath: fixture) }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            let localTwin = Data("local twin must not be read or overwritten".utf8)
            try localTwin.write(to: URL(fileURLWithPath: path))
            try localTwin.write(to: URL(fileURLWithPath: asset))
            try localTwin.write(to: URL(fileURLWithPath: rasterPath))

            try await stopMaster()
            do {
                _ = try await resource.read(relative, maxBytes: 1024)
                XCTFail("A real disconnected channel must not read the same path on the Mac")
            } catch RemoteConnectionError.notConnected {}
            do {
                _ = try await originalImage()
                XCTFail("Original-size decoding must not read the local namesake after disconnect")
            } catch RemoteConnectionError.notConnected {}
            XCTAssertEqual(connection.state, .disconnected)
            tab.autoSaveSuspendedForClose = true
            let draft = "\r\nDraft after disconnect"
            tab.nativeTextStorage.replaceCharacters(in: NSRange(location: tab.text.utf16.count, length: 0),
                                                    with: draft)
            await tab.save()
            XCTAssertTrue(tab.isDirty)
            XCTAssertNotNil(tab.saveError)
            XCTAssertTrue(tab.text.hasSuffix(draft))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), localTwin)

            let reopened = try await backend.read(path: path, maxBytes: original.count)
            XCTAssertEqual(reopened, original, "Reconnecting before retry must show the original remote bytes")
            let revisedSVG = Data(String(decoding: svg, as: UTF8.self)
                .replacingOccurrences(of: "width=\"40\"", with: "width=\"52\"").utf8)
            try await backend.write(path: asset, data: revisedSVG)
            let refreshed = try await resource.picture(relative)
            XCTAssertEqual(refreshed.pointSize?.width, 52, "Recovery must render the revised remote image")
            await tab.save()
            XCTAssertFalse(tab.isDirty)
            XCTAssertNil(tab.saveError)
            let updated = try await backend.read(path: path, maxBytes: original.count + draft.utf8.count)
            XCTAssertEqual(updated, original + Data(draft.utf8), "Retry saves only the remote BOM/CRLF Markdown")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), localTwin)
            let unchangedRaster = try await backend.read(path: rasterPath, maxBytes: rasterBytes.count)
            XCTAssertEqual(unchangedRaster, rasterBytes)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: rasterPath)), localTwin)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

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

    func testAsyncMarkdownLinkCannotOpenOldTargetAfterSourceEdit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-link-revision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let document = root.appendingPathComponent("Index.md")
        let target = root.appendingPathComponent("Guide.md")
        let original = Data("# Index\n\n[Open Guide](Guide.md)\n".utf8)
        try original.write(to: document)
        try Data("# Guide\n".utf8).write(to: target)

        let project = Project(fallbackName: "Markdown", workspaceConfiguration: .standard)
        project.customDirectory = root.path
        project.openFile(document.path)
        guard case .file(let source)? = project.focusedContent else {
            return XCTFail("Project must open the native Markdown source")
        }
        try await source.waitForText()
        source.autoSaveSuspendedForClose = true
        let previousRequest = source.markdownRequestID
        var identityChecks = 0

        let opened = await project.openMarkdownLink(try XCTUnwrap(URL(string: "Guide.md")),
                                                    from: source) {
            identityChecks += 1
            if identityChecks == 2 {
                source.nativeTextStorage.replaceCharacters(
                    in: NSRange(location: source.text.utf16.count, length: 0),
                    with: "\nNew unsaved edit"
                )
            }
            return true
        }
        XCTAssertEqual(identityChecks, 2, "The link must recheck its source after authorization")
        XCTAssertNotEqual(source.markdownRequestID, previousRequest)
        XCTAssertFalse(opened, "An old link must not open after its source content changes")
        XCTAssertEqual(project.tabs.count, 1, "A stale async result cannot create a destination tab")
        XCTAssertTrue(source.isDirty)
        XCTAssertEqual(try Data(contentsOf: document), original)
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
