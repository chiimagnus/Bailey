import AppKit
import Darwin
import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Bailey

private actor EditorWorkspaceFixture: WorkspaceBackend {
    enum Rejection: Error { case simulated }

    private struct PendingWrite {
        let path: String
        let data: Data
        let expected: WorkspaceFileVersion?
        let finish: CheckedContinuation<Void, Error>
    }

    private var files: [String: Data]
    private var writing: PendingWrite?
    private var reading: [CheckedContinuation<Data, Error>] = []
    private var nextReadPaused = false
    private(set) var readCount = 0
    private(set) var lastReadLimit: Int?
    private(set) var writingPath: String?
    private(set) var readingPath: String?
    var pendingReadCount: Int { reading.count }

    init(path: String, contents: Data) { files = [path: contents] }

    func pauseOneRead() { nextReadPaused = true }
    func finishRead(with data: Data? = nil) {
        guard !reading.isEmpty else { return }
        let continuation = reading.removeFirst()
        if reading.isEmpty { readingPath = nil }
        if let data { continuation.resume(returning: data) }
        else { continuation.resume(throwing: Rejection.simulated) }
    }
    func finishWrite(failing: Bool = false) {
        guard let pending = writing else { return }
        writing = nil
        writingPath = nil
        if failing {
            pending.finish.resume(throwing: Rejection.simulated)
        } else if let expected = pending.expected,
                  !(files[pending.path].map(expected.matches) ?? false) {
            pending.finish.resume(throwing: WorkspaceError.changedExternally)
        } else {
            files[pending.path] = pending.data
            pending.finish.resume()
        }
    }
    func data(at path: String) -> Data? { files[path] }
    func replace(path: String, with data: Data) { files[path] = data }

    func read(path: String, maxBytes: Int) async throws -> Data {
        readCount += 1
        lastReadLimit = maxBytes
        guard let data = files[path] else { throw WorkspaceError.notFound }
        guard data.count <= maxBytes else { throw WorkspaceError.tooLarge }
        if nextReadPaused {
            nextReadPaused = false
            readingPath = path
            return try await withCheckedThrowingContinuation { reading.append($0) }
        }
        return data
    }
    func write(path: String, data: Data) async throws {
        try await stageWrite(path: path, data: data, expected: nil)
    }
    func write(path: String, data: Data, ifUnchanged version: WorkspaceFileVersion) async throws {
        guard files[path].map(version.matches) ?? false else {
            throw WorkspaceError.changedExternally
        }
        try await stageWrite(path: path, data: data, expected: version)
    }
    private func stageWrite(path: String, data: Data,
                            expected: WorkspaceFileVersion?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writingPath = path
            writing = PendingWrite(path: path, data: data, expected: expected,
                                   finish: continuation)
        }
    }

    func list(directory: String) async throws -> [WorkspaceEntry] { [] }
    func stat(path: String) async throws -> WorkspaceStat? { nil }
    func readSymlinkDestination(path: String) async throws -> String? { nil }
    func createFile(path: String) async throws { throw WorkspaceError.notFound }
    func createDirectory(path: String) async throws { throw WorkspaceError.notFound }
    func copy(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func rename(from: String, to: String) async throws {
        guard let data = files.removeValue(forKey: from) else { throw WorkspaceError.notFound }
        files[to] = data
    }
    func delete(paths: [String]) async throws { throw WorkspaceError.notFound }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        if argv.first == "powershell.exe" {
            return WorkspaceRunResult(status: 0, stdout: Data("936\n".utf8), stderr: Data())
        }
        throw WorkspaceError.notFound
    }
}

@MainActor
private func waitForFileTabState(_ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !(await condition()) {
        guard Date() < deadline else { return XCTFail("Editor operation did not settle") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
final class FileTabPersistenceTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    func testMarkdownPreviewPreservesBOMCRLFAndDefaultSourceMode() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-markdown-encoding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for (name, encoding) in [
            ("UTF8-BOM", TextFileEncoding.utf8BOM),
            ("UTF16LE-BOM", TextFileEncoding.utf16LEBOM)
        ] {
            let path = folder.appendingPathComponent("\(name).md")
            let source = "# 标题 中文\r\n\r\nOriginal paragraph🙂.\r\n"
            let originalBytes = try XCTUnwrap(encoding.encoded(source))
            try originalBytes.write(to: path)

            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                               workspaceIdentity: nil)
            try await file.waitForText()
            file.autoSaveSuspendedForClose = true
            XCTAssertEqual(file.text, source)
            XCTAssertEqual(file.fileEncoding, encoding)
            XCTAssertFalse(file.showsFilePreview)
            file.setFilePreview(true)
            XCTAssertTrue(file.showsFilePreview)
            file.setFilePreview(false)
            file.setFilePreview(true)
            XCTAssertEqual(try Data(contentsOf: path), originalBytes,
                           "Switching Markdown preview cannot re-encode the original file")
            XCTAssertFalse(file.isDirty)

            let edited = source + "\r\nNew unsaved paragraph.\r\n"
            file.text = edited
            XCTAssertTrue(file.isDirty)
            XCTAssertEqual(try Data(contentsOf: path), originalBytes)
            await file.save()
            XCTAssertNil(file.saveError)
            XCTAssertEqual(try Data(contentsOf: path), try XCTUnwrap(encoding.encoded(edited)),
                           "The existing save path must retain BOM, UTF encoding and CRLF")

            let reopened = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                                   workspaceIdentity: nil)
            try await reopened.waitForText()
            XCTAssertFalse(reopened.showsFilePreview,
                           "Reopening a Markdown file defaults to source mode")
            XCTAssertEqual(reopened.text, edited)
            XCTAssertEqual(reopened.fileEncoding, encoding)
        }
    }

    func testDistinctMarkdownTabsCannotShareAStalePreviewRequestIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-markdown-identities-\(UUID().uuidString)")
        let a = root.appendingPathComponent("A/README.md")
        let b = root.appendingPathComponent("B/README.md")
        try FileManager.default.createDirectory(at: a.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# First\n".utf8).write(to: a)
        try Data("# Second\n".utf8).write(to: b)

        let first = FileTab(path: a.path, backend: LocalWorkspaceBackend.shared,
                            workspaceIdentity: nil)
        let second = FileTab(path: b.path, backend: LocalWorkspaceBackend.shared,
                             workspaceIdentity: nil)
        try await first.waitForText()
        try await second.waitForText()
        XCTAssertNotEqual(first.fileContentRevision, second.fileContentRevision,
                          "Two different files may have identical revisions but must not share a preview target")
        XCTAssertNotEqual(first.textPreviewRequestID, second.textPreviewRequestID,
                          "SwiftUI .task(id:) must reparse after a different FileTab becomes visible")
        XCTAssertEqual(first.text, "# First\n")
        XCTAssertEqual(second.text, "# Second\n")
    }

    func testMarkdownLiveEditsParseComplete500To20000LineDocumentsWithoutSaving() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-markdown-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for count in [500, 5_000, 20_000] {
            let url = folder.appendingPathComponent("Document-\(count).md")
            let original = "# Before\n\n" + (0..<count).map { index in
                "Paragraph \(index): 中文🙂 **strong** [link](guide.md)"
            }.joined(separator: "\n\n")
            try Data(original.utf8).write(to: url)
            let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared,
                               workspaceIdentity: nil)
            try await file.waitForText()
            file.autoSaveSuspendedForClose = true
            let oldRequest = file.textPreviewRequestID
            file.nativeTextStorage.replaceCharacters(in: NSRange(location: 2, length: 6),
                                                    with: "After")
            XCTAssertNotEqual(file.textPreviewRequestID, oldRequest)
            let document = try await MarkdownDocument.parse(file.text)
            XCTAssertEqual(document.blocks.count, count + 1,
                           "The newest source must retain every long-document block")
            guard case let .heading(_, heading) = document.blocks.first?.content else {
                return XCTFail("Edited document heading missing for \(count) lines")
            }
            XCTAssertTrue(heading.contains {
                if case .text("After", _) = $0 { return true }
                return false
            })
            guard case .paragraph = document.blocks.last?.content else {
                return XCTFail("Final paragraph disappeared after live Markdown edit")
            }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
            XCTAssertTrue(file.isDirty)
        }
    }

    func testMarkdownLiveRevisionPreservesOneSourceAndReadingPosition() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-markdown-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("Live.md")
        let original = Data("# Before\n\n中文🙂 and code.\n".utf8)
        try original.write(to: path)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        XCTAssertTrue(file.canPreviewMarkdown)
        let resource = file.fileContentRevision
        let firstRequest = file.textPreviewRequestID
        let bodyOffset = (file.text as NSString).range(of: "中文").location
        file.markdownReadingOffset = bodyOffset
        file.setFilePreview(true)
        XCTAssertTrue(file.showsFilePreview)
        XCTAssertEqual(file.textPreviewRequestID, firstRequest)

        file.nativeTextStorage.replaceCharacters(in: NSRange(location: 2, length: 6),
                                                with: "After")
        let secondRequest = file.textPreviewRequestID
        XCTAssertNotEqual(secondRequest, firstRequest)
        XCTAssertEqual(file.fileContentRevision, resource,
                       "Ordinary typing must not invalidate the file's resource identity")
        XCTAssertEqual(file.text, "# After\n\n中文🙂 and code.\n")
        XCTAssertEqual(file.markdownReadingOffset, bodyOffset - 1)
        file.nativeTextStorage.replaceCharacters(in: NSRange(location: 2, length: 5),
                                                with: "Newest")
        XCTAssertNotEqual(file.textPreviewRequestID, secondRequest,
                          "A second edit must supersede a pending asynchronous preview parse")
        XCTAssertEqual(file.text, "# Newest\n\n中文🙂 and code.\n")
        file.setFilePreview(false)
        file.setFilePreview(true)
        XCTAssertEqual(file.markdownReadingOffset, bodyOffset,
                       "Switching source/preview cannot reset the stored reading position")
        XCTAssertEqual(file.fileContentRevision, resource)
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: path), original,
                       "Live preview and unsaved edits must not write the original file")
    }

    func testSaveRefusesExternalSameSizeSameMtimeRewriteAndKeepsDraft() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("document.txt")
        let baseline = Data("alpha 中🙂\n".utf8)
        let external = Data("omega 中🙂\n".utf8)
        XCTAssertEqual(baseline.count, external.count)
        try baseline.write(to: path)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        file.text = "Bailey draft 中文\n"
        try external.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), external)
        XCTAssertEqual(file.text, "Bailey draft 中文\n")
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
    }

    func testLocalConditionalWriteKeepsModeAndDoesNotFollowSymlink() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-cas-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("executable.sh")
        let baseline = Data("echo first\n".utf8)
        let update = Data("echo next\n".utf8)
        try baseline.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o751],
                                              ofItemAtPath: source.path)
        let backend = LocalWorkspaceBackend.shared
        try await backend.write(path: source.path, data: update,
                                ifUnchanged: WorkspaceFileVersion(data: baseline))
        XCTAssertEqual(try Data(contentsOf: source), update)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o751)
        let linked = folder.appendingPathComponent("linked.sh")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
        try await backend.write(path: linked.path, data: baseline,
                                ifUnchanged: WorkspaceFileVersion(data: update))
        XCTAssertEqual(try Data(contentsOf: linked), baseline)
        XCTAssertEqual(try Data(contentsOf: source), update)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path))
        let removed = folder.appendingPathComponent("removed.sh")
        try baseline.write(to: removed)
        try FileManager.default.removeItem(at: removed)
        do {
            try await backend.write(path: removed.path, data: update,
                                    ifUnchanged: WorkspaceFileVersion(data: baseline))
            XCTFail("A removed source must not be resurrected")
        } catch WorkspaceError.changedExternally {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
                       Set([source.lastPathComponent, linked.lastPathComponent]))
    }

    func testLocalConditionalWriteSupportsLongLegalFileName() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-long-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent(String(repeating: "a", count: 240) + ".txt")
        let original = Data("origin".utf8)
        let updated = Data("updated".utf8)
        try original.write(to: target)
        try await LocalWorkspaceBackend.shared.write(
            path: target.path, data: updated,
            ifUnchanged: WorkspaceFileVersion(data: original)
        )
        XCTAssertEqual(try Data(contentsOf: target), updated)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path),
                       [target.lastPathComponent])
    }

    func testTwoIndependentFileTabsCannotOverwriteOneAnothersSavedRevision() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-same-file-cas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("shared.md")
        try Data("shared baseline 中文\r\n".utf8).write(to: target)
        let first = FileTab(path: target.path, backend: LocalWorkspaceBackend.shared,
                            workspaceIdentity: nil)
        let second = FileTab(path: target.path, backend: LocalWorkspaceBackend.shared,
                             workspaceIdentity: nil)
        try await first.waitForText()
        try await second.waitForText()
        first.autoSaveSuspendedForClose = true
        second.autoSaveSuspendedForClose = true
        first.text = "first editor revision\r\n"
        second.text = "second independent draft\r\n"
        await first.save()
        XCTAssertNil(first.saveError)
        XCTAssertFalse(first.isDirty)
        await second.save()
        XCTAssertEqual(try Data(contentsOf: target), Data("first editor revision\r\n".utf8))
        XCTAssertEqual(second.text, "second independent draft\r\n")
        XCTAssertTrue(second.isDirty)
        XCTAssertNotNil(second.saveError)
        XCTAssertEqual(first.text, "first editor revision\r\n")
    }

    func testExplicitEncodingChangeQueuedDuringWriteKeepsNewestDraftAndBothIntents() async throws {
        let path = "/fixture/\(UUID().uuidString)-encoding-queue.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        file.text = "first 中文"
        let firstBytes = try XCTUnwrap(TextFileEncoding.utf8BOM.encoded("first 中文"))
        let first = Task { await file.save(as: .utf8BOM) }
        try await waitForFileTabState { await backend.writingPath == path }
        file.text = "second 中文👋"
        let secondBytes = try XCTUnwrap(TextFileEncoding.utf16LEBOM.encoded("second 中文👋"))
        let second = Task { await file.save(as: .utf16LEBOM) }
        // Ensure the second save has joined the active writer before releasing it.
        await Task.yield()
        await backend.finishWrite()
        try await waitForFileTabState {
            let current = await backend.data(at: path)
            let pending = await backend.writingPath
            return current == firstBytes && pending == path
        }
        await backend.finishWrite()
        await first.value
        await second.value
        let finalBytes = await backend.data(at: path)
        XCTAssertEqual(finalBytes, secondBytes)
        XCTAssertEqual(file.fileEncoding, .utf16LEBOM)
        XCTAssertNil(file.saveError)
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(file.text, "second 中文👋")
    }

    func testSaveAfterExternalRestoreToOriginalBytesCanRecover() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("document.txt")
        let baseline = Data("base\r\n中文🙂".utf8)
        try baseline.write(to: path)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        file.text = "local revision\r\n中文🙂"
        try Data("external".utf8).write(to: path)
        await file.save()
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
        XCTAssertEqual(try Data(contentsOf: path), Data("external".utf8))
        try baseline.write(to: path)
        await file.save()
        XCTAssertFalse(file.isDirty)
        XCTAssertNil(file.saveError)
        XCTAssertEqual(try Data(contentsOf: path), Data("local revision\r\n中文🙂".utf8))
    }

    func testCanonicalEquivalentCleanReloadInstallsNewBytes() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let composed = "café 中文👋\r\n"
        let decomposed = "cafe\u{301} 中文👋\r\n"
        try Data(composed.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        let revision = file.reloadRevision
        try Data(decomposed.utf8).write(to: path)
        file.reloadFromDiskIfClean()
        try await file.waitForText()
        XCTAssertEqual(Data(file.text.utf8), Data(decomposed.utf8))
        XCTAssertEqual(file.reloadRevision, revision + 1)
        let updated = file.reloadRevision
        file.reloadFromDiskIfClean()
        try await file.waitForText()
        XCTAssertEqual(file.reloadRevision, updated, "Identical bytes must not replace the document")
        XCTAssertFalse(file.isDirty)
    }

    func testExactDirtyComparisonRejectsCanonicallyEquivalentReorderingAndChunkBoundaryChange() async throws {
        let cases: [(String, String)] = [
            ("a\u{0301}\u{0323}", "a\u{0323}\u{0301}"),
            (String(repeating: "A", count: 65_535) + "🐈\n",
             String(repeating: "A", count: 65_535) + "🐕\n"),
        ]
        for (original, revised) in cases {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".txt")
            try Data(original.utf8).write(to: path)
            defer { try? FileManager.default.removeItem(at: path) }
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                               workspaceIdentity: nil)
            try await file.waitForText()
            XCTAssertEqual(original.utf16.count, revised.utf16.count)
            file.text = revised
            XCTAssertTrue(file.isDirty, "Equal UTF-16 lengths cannot imply equal source bytes")
            file.text = original
            XCTAssertFalse(file.isDirty)
            file.text = revised
            await file.save()
            XCTAssertNil(file.saveError)
            XCTAssertFalse(file.isDirty)
            XCTAssertEqual(try Data(contentsOf: path), Data(revised.utf8))
        }
    }

    func testCanonicalEquivalentEditDuringWriteRemainsDirty() async throws {
        let path = "/fixture/canonical.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("baseline".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        file.text = "café"
        file.refreshDirtyState()
        let saving = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == path }
        file.text = "cafe\u{301}"
        file.refreshDirtyState()
        await backend.finishWrite()
        await saving.value
        let stored = await backend.data(at: path)
        XCTAssertEqual(stored, Data("café".utf8))
        XCTAssertTrue(file.isDirty, "A completed write must not claim different current bytes were saved")
        XCTAssertEqual(Data(file.text.utf8), Data("cafe\u{301}".utf8))
    }

    func testUnconsumedTabDoesNotReadAndWaitLoadsExactlyOnce() async throws {
        let path = "/fixture/lazy.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        await Task.yield()
        let before = await backend.readCount
        XCTAssertEqual(before, 0)
        try await backend.rename(from: path, to: "/fixture/renamed-lazy.txt")
        file.updatePath("/fixture/renamed-lazy.txt")
        await Task.yield()
        let afterRename = await backend.readCount
        XCTAssertEqual(afterRename, 0)
        try await file.waitForText()
        try await file.waitForText()
        XCTAssertEqual(file.text, "original")
        let after = await backend.readCount
        XCTAssertEqual(after, 1)
    }

    func testInitialReadFollowsRenameAndOldReadCannotWin() async throws {
        let backend = EditorWorkspaceFixture(path: "/fixture/old.txt", contents: Data("original".utf8))
        await backend.pauseOneRead()
        let file = FileTab(path: "/fixture/old.txt", backend: backend, workspaceIdentity: nil)
        file.loadIfNeeded()
        try await waitForFileTabState { await backend.pendingReadCount == 1 }
        try await backend.rename(from: file.path, to: "/fixture/new.txt")
        await backend.pauseOneRead()
        file.updatePath("/fixture/new.txt")
        try await waitForFileTabState { await backend.pendingReadCount == 2 }
        await backend.finishRead(with: Data("stale".utf8))
        XCTAssertEqual(file.text, "")
        await backend.finishRead(with: Data("new path content".utf8))
        try await file.waitForText()
        XCTAssertEqual(file.text, "new path content")
        XCTAssertEqual(file.path, "/fixture/new.txt")
    }

    func testSaveCannotCreateUnreopenableOversizedTextAndKeepsDraft() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: path) }
        let original = Data(repeating: 65, count: 32 << 20)
        try original.write(to: path)

        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        file.text += "👋"
        file.refreshDirtyState()
        XCTAssertTrue(file.isDirty)
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), original,
                       "Saving a file above the readable limit must never publish it")
        XCTAssertTrue(file.isDirty, "A refused write cannot discard the draft")
        XCTAssertNotNil(file.saveError)
        XCTAssertTrue(file.text.hasSuffix("👋"))

        // A smaller revision must still save through the same version-checked path.
        file.text = String(repeating: "A", count: (32 << 20) - 4) + "👋"
        file.refreshDirtyState()
        await file.save()
        let expected = Data(file.text.utf8)
        XCTAssertEqual(expected.count, 32 << 20)
        XCTAssertNil(file.saveError)
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: path), expected)
        let reopened = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                               workspaceIdentity: nil)
        try await reopened.waitForText()
        XCTAssertEqual(Data(reopened.text.utf8), expected)
    }

    func testExplicitEncodingSaveCannotExceedReadableTextCapacity() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: path) }
        let original = Data(repeating: 65, count: 16 << 20)
        try original.write(to: path)

        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        await file.save(as: .utf16LEBOM)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertNotNil(file.saveError)
        XCTAssertEqual(file.fileEncoding, .utf8)
        let reopened = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                               workspaceIdentity: nil)
        try await reopened.waitForText()
        XCTAssertEqual(Data(reopened.text.utf8), original)
    }

    func testLocalTextReadCapacityAndFailureKinds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = 32 << 20
        for count in [0, 1, (8 << 20) - 1, 8 << 20, (8 << 20) + 1,
                      16 << 20, limit - 1, limit, limit + 1, 64 << 20] {
            let path = root.appendingPathComponent("\(count).txt")
            try Data(repeating: 65, count: count).write(to: path)
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            guard case .loading = file.content else { return XCTFail("init must remain lazy") }
            if count <= limit {
                try await file.waitForText()
                XCTAssertEqual(file.text.utf8.count, count)
            } else {
                do { try await file.waitForText(); XCTFail("Expected capacity rejection") } catch {}
                guard case .unavailable(let reason) = file.content else { return XCTFail("Expected capacity placeholder") }
                XCTAssertEqual(reason, String(localized: "File is too large to open", table: "Workspace"))
            }
        }
        let emoji = Data("👋".utf8)
        let exactPath = root.appendingPathComponent("utf8-at-boundary.txt")
        let exactBytes = Data(repeating: 65, count: limit - emoji.count) + emoji
        try exactBytes.write(to: exactPath)
        let exact = FileTab(path: exactPath.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await exact.waitForText()
        XCTAssertEqual(Data(exact.text.utf8), exactBytes)

        let overflowPath = root.appendingPathComponent("utf8-beyond-boundary.txt")
        try (Data(repeating: 65, count: limit - emoji.count + 1) + emoji).write(to: overflowPath)
        let overflow = FileTab(path: overflowPath.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        do { try await overflow.waitForText(); XCTFail("Exceeded UTF-8 byte capacity") } catch {}
        guard case .unavailable = overflow.content else { return XCTFail("Expected size placeholder") }

        let truncatedPath = root.appendingPathComponent("invalid-utf8-boundary.txt")
        try (Data(repeating: 65, count: limit - 2) + emoji.prefix(2)).write(to: truncatedPath)
        let truncated = FileTab(path: truncatedPath.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        do { try await truncated.waitForText(); XCTFail("Truncated UTF-8 cannot be decoded") } catch {}
        guard case .unavailable(let invalidReason) = truncated.content else { return XCTFail("Expected unavailable text") }
        XCTAssertEqual(invalidReason, String(
            localized: "Unknown text encoding. Choose an encoding to reopen.", table: "Workspace"
        ))

        do {
            _ = try await LocalWorkspaceBackend.shared.read(path: exactPath.path, maxBytes: .max)
            XCTFail("Unbounded reads must not bypass byte budgets")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error.code, Int(EINVAL))
        }

        let missing = FileTab(path: root.appendingPathComponent("missing.txt").path,
                              backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        do { try await missing.waitForText(); XCTFail("Expected missing read failure") } catch {}
        guard case .unavailable(let reason) = missing.content else { return XCTFail("Expected read failure") }
        XCTAssertEqual(reason, String(localized: "Could not read file", table: "Workspace"))
        try Data("recovered".utf8).write(to: URL(fileURLWithPath: missing.path))
        try await missing.waitForText()
        XCTAssertEqual(missing.text, "recovered")
    }

    func testLocalBackendRejectsNonregularFilesRatherThanReturningEmptyText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let deviceLink = root.appendingPathComponent("device-link")
        try FileManager.default.createSymbolicLink(atPath: deviceLink.path,
                                                    withDestinationPath: "/dev/null")
        let fifo = root.appendingPathComponent("pipe")
        let fifoLink = root.appendingPathComponent("pipe-link")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        try FileManager.default.createSymbolicLink(atPath: fifoLink.path,
                                                    withDestinationPath: fifo.path)
        for path in ["/dev/null", deviceLink.path, root.path, fifo.path, fifoLink.path] {
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let actual = try await LocalWorkspaceBackend.shared.read(path: path, maxBytes: 128)
                XCTFail("Nonregular file must not be accepted as text: \(path), bytes=\(actual.count)")
            } catch let error as NSError {
                XCTAssertEqual(error.domain, NSPOSIXErrorDomain, path)
                XCTAssertEqual(error.code, Int(ENOTSUP), path)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5,
                              "FIFO and device reads must not block while waiting for input")
        }
    }

    func testLocalSymbolicLinkUsesTargetContents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("link.txt")
        let original = "symlink 中文 👋\r\n"
        try Data(original.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let file = FileTab(path: link.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        XCTAssertEqual(Data(file.text.utf8), Data(original.utf8))
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: target), Data(original.utf8))
    }

    func testImageExtensionNeverAuthorizesUnboundedBackendRead() async throws {
        let path = "/fixture/not-a-picture.png"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("plain text".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        XCTAssertEqual(file.text, "plain text")
        let limit = await backend.lastReadLimit
        XCTAssertEqual(limit, 32 << 20,
                       "An image-looking extension must not bypass the text size limit")
    }

    func testActualLargeImagePreviewKeepsIndependentBoundedRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4096, pixelsHigh: 3072,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let buffer = try XCTUnwrap(bitmap.bitmapData)
        var entropy: UInt32 = 0x1234_5678
        for i in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
            entropy ^= entropy << 13
            entropy ^= entropy >> 17
            entropy ^= entropy << 5
            buffer[i] = UInt8(truncatingIfNeeded: entropy)
        }
        let pixels = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(pixels.count, 32 << 20)
        let path = root.appendingPathComponent("large-image.png")
        try pixels.write(to: path)

        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        file.loadIfNeeded()
        try await waitForFileTabState { if case .image = file.content { return true }; return false }
        guard case .image(let preview) = file.content else {
            return XCTFail("Real PNG larger than text limit must remain previewable")
        }
        XCTAssertEqual(preview.poster.width, 4096)
        XCTAssertEqual(try Data(contentsOf: path), pixels)

        let linked = root.appendingPathComponent("linked-image.png")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: path)
        let linkedFile = FileTab(path: linked.path, backend: LocalWorkspaceBackend.shared,
                                 workspaceIdentity: nil)
        linkedFile.loadIfNeeded()
        try await waitForFileTabState {
            if case .loading = linkedFile.content { return false }
            return true
        }
        guard case .image = linkedFile.content else {
            return XCTFail("A symlink to a large regular image must retain image preview")
        }
    }

    func testOversizedFakeImageCannotBypassTextCapacity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("not-an-image.png")
        let original = Data(repeating: 0x41, count: (32 << 20) + 1)
        try original.write(to: path)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        file.loadIfNeeded()
        try await waitForFileTabState {
            if case .unavailable = file.content { return true }
            return false
        }
        guard case .unavailable = file.content else {
            return XCTFail("An oversized renamed text file must not become editable")
        }
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testFileAndMarkdownImagePreviewsRespectEXIFOrientation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 20, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let quadrantColors = [4, 2, 1, 7]
        for (index, color) in quadrantColors.enumerated() {
            context.setFillColor(CGColor(
                red: color & 4 == 0 ? 0 : 1, green: color & 2 == 0 ? 0 : 1,
                blue: color & 1 == 0 ? 0 : 1, alpha: 1
            ))
            context.fill(CGRect(x: (index % 2) * 10, y: (1 - index / 2) * 6, width: 10, height: 6))
        }
        let original = try XCTUnwrap(context.makeImage())
        let expectedQuadrants = [
            [0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
            [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2],
        ]

        func quadrants(_ image: CGImage) throws -> [Int] {
            let sample = try XCTUnwrap(CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            let pixels = try XCTUnwrap(sample.data).assumingMemoryBound(to: UInt8.self)
            return try (0..<4).map { index in
                let rect = CGRect(x: (1 + 2 * (index % 2)) * image.width / 4,
                                  y: (1 + 2 * (index / 2)) * image.height / 4, width: 1, height: 1)
                let pixel = try XCTUnwrap(image.cropping(to: rect))
                sample.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return (pixels[0] >= 128 ? 4 : 0) + (pixels[1] >= 128 ? 2 : 0) + (pixels[2] >= 128 ? 1 : 0)
            }
        }

        for orientation in 1...8 {
            let bytes = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
                bytes, UTType.jpeg.identifier as CFString, 1, nil
            ))
            CGImageDestinationAddImage(destination, original, [
                kCGImagePropertyOrientation: orientation,
            ] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let data = bytes as Data
            let path = directory.appendingPathComponent("orientation-\(orientation).JPG")
            try data.write(to: path)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            XCTAssertEqual(properties?[kCGImagePropertyOrientation] as? Int, orientation)
            let expected = orientation >= 5 ? CGSize(width: 12, height: 20) : CGSize(width: 20, height: 12)

            let picture = try MarkdownPicture.decode(data)
            XCTAssertEqual(CGSize(width: picture.poster.width, height: picture.poster.height), expected)
            let expectedColors = expectedQuadrants[orientation - 1].map { quadrantColors[$0] }
            XCTAssertEqual(try quadrants(picture.poster), expectedColors, "EXIF \(orientation) in Markdown")
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            file.loadIfNeeded()
            try await waitForFileTabState { if case .image = file.content { return true }; return false }
            guard case .image(let image) = file.content else { return XCTFail("Expected JPEG preview") }
            XCTAssertEqual(image.pixelSize, expected)
            XCTAssertEqual(CGSize(width: image.poster.width, height: image.poster.height), expected)
            XCTAssertEqual(try quadrants(image.poster), expectedColors, "EXIF \(orientation) in FileTab")
            XCTAssertEqual(try Data(contentsOf: path), data)
        }
    }

    func testLargeImagePreviewUsesBoundedDecodedDimensions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 5000, pixelsHigh: 2500,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let imageBytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let path = root.appendingPathComponent("wide-preview.png")
        try imageBytes.write(to: path)

        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        file.loadIfNeeded()
        try await waitForFileTabState { if case .image = file.content { return true }; return false }
        guard case .image(let image) = file.content else {
            return XCTFail("Valid image must remain previewable")
        }
        XCTAssertEqual(image.pixelSize, CGSize(width: 5000, height: 2500))
        XCTAssertLessThanOrEqual(image.poster.width, 4096)
        XCTAssertLessThanOrEqual(image.poster.height, 4096)
        let request = try XCTUnwrap(file.originalImageRequest())
        let original = try await request()
        guard case .whole = original else { return XCTFail("PNG still uses the bounded full ImageIO decode") }
        let pixels = try await original.render(CGRect(x: 1000, y: 1000, width: 120, height: 120))
        XCTAssertEqual(pixels.image.width, 5000)
        XCTAssertEqual(pixels.image.height, 2500)
        XCTAssertEqual(try Data(contentsOf: path), imageBytes)

        var changed = imageBytes
        changed[changed.count - 1] ^= 1
        try changed.write(to: path)
        do {
            _ = try await request()
            XCTFail("A detail request must not render bytes other than the accepted original")
        } catch WorkspaceError.changedExternally {}
        XCTAssertEqual(try Data(contentsOf: path), changed)
    }

    func testOriginalImageReadCannotPublishAfterRenameDisconnectOrClose() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4300, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let path = "/fixture/detail.png"
        let actions: [(FileTab) -> Void] = [
            { $0.updatePath("/fixture/renamed.png") },
            { $0.rebindWorkspace(to: nil) },
            { $0.retireContent() },
        ]
        for action in actions {
            let backend = EditorWorkspaceFixture(path: path, contents: bytes)
            let file = FileTab(path: path, backend: backend, workspaceIdentity: "fixture-remote")
            file.loadIfNeeded()
            try await waitForFileTabState { if case .image = file.content { return true }; return false }
            let request = try XCTUnwrap(file.originalImageRequest())
            await backend.pauseOneRead()
            let pending = Task { try await request() }
            try await waitForFileTabState { await backend.pendingReadCount == 1 }
            let originalPath = await backend.readingPath
            XCTAssertEqual(originalPath, path)
            action(file)
            await backend.finishRead(with: bytes)
            do {
                _ = try await pending.value
                XCTFail("Canceled image decoding must not deliver pixels")
            } catch is CancellationError {}
            do {
                _ = try await request()
                XCTFail("A stale request must not start new reads")
            } catch WorkspaceError.changedExternally {}
            let reads = await backend.readCount
            let onDisk = await backend.data(at: path)
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(onDisk, bytes)
        }
    }

    func testMountedOriginalImageRecoversFromRenameDuringDetailRead() async throws {
        let size = CGSize(width: 5001, height: 101)
        let sample = CGRect(x: 2500, y: 50, width: 1, height: 1)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(NSColor.green.cgColor)
        context.fill(sample)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage()))
            .representation(using: .png, properties: [:]))
        let oldPath = "/fixture/detail.png"
        let newPath = "/fixture/renamed.png"
        let backend = EditorWorkspaceFixture(path: oldPath, contents: png)
        let file = FileTab(path: oldPath, backend: backend, workspaceIdentity: "fixture-remote")
        let host = NSHostingView(rootView: FileViewerView(file: file))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            file.retireContent()
            window.close()
            Task { await backend.finishRead() }
        }
        window.contentView = host
        window.orderFront(nil)
        func scrollView(in view: NSView) -> PreviewScrollView? {
            (view as? PreviewScrollView) ?? view.subviews.lazy.compactMap(scrollView(in:)).first
        }
        try await waitForFileTabState { scrollView(in: host) != nil }
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(scrollView(in: host))
        let canvas = try XCTUnwrap(scroll.documentView)
        func paintedGreen() -> CGFloat {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0),
                  let painting = NSGraphicsContext(bitmapImageRep: bitmap) else { return -1 }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = painting
            painting.cgContext.translateBy(x: -sample.minX, y: -sample.minY)
            canvas.draw(sample)
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)?.greenComponent ?? -1
        }
        XCTAssertLessThan(paintedGreen(), 0.9, "The thumbnail cannot retain the original one-pixel detail")
        await backend.pauseOneRead()
        scroll.actualSize()
        try await waitForFileTabState { await backend.readingPath == oldPath }
        let center = scroll.contentView.bounds.midX

        try await backend.rename(from: oldPath, to: newPath)
        file.updatePath(newPath)
        await backend.finishRead(with: png)
        try await waitForFileTabState { paintedGreen() > 0.95 }
        XCTAssertTrue(scrollView(in: host) === scroll)
        XCTAssertEqual(scroll.pixelScale, 1, accuracy: 0.001)
        XCTAssertEqual(scroll.contentView.bounds.midX, center, accuracy: 1)
        let reads = await backend.readCount
        let moved = await backend.data(at: newPath)
        XCTAssertEqual(reads, 3, "Read the poster, cancel the original, and request the renamed original exactly once")
        XCTAssertEqual(moved, png)
    }

    func testInvalidUTF8AndImageFallbackRespectTextCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binaryReason = String(localized: "Binary file", table: "Workspace")
        let sizeReason = String(localized: "File is too large to open", table: "Workspace")
        for (name, data, expected) in [
            ("invalid.txt", Data([0xff, 0xfe, 0x00]), binaryReason),
            ("embedded-nul.txt", Data([0x61, 0x00, 0x62]), binaryReason),
            ("invalid.png", Data([0xff, 0xfe, 0x00]), binaryReason),
            ("oversized.png", Data(repeating: 0xff, count: (32 << 20) + 1), sizeReason),
        ] {
            let path = directory.appendingPathComponent(name)
            try data.write(to: path)
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            do {
                try await file.waitForText()
                XCTFail("Expected unavailable content for \(name)")
            } catch {}
            guard case .unavailable(let reason) = file.content else {
                return XCTFail("Expected unavailable content for \(name)")
            }
            XCTAssertEqual(reason, expected)
            XCTAssertFalse(file.isDirty)
        }
        let imageNamedText = directory.appendingPathComponent("plain.png")
        try Data("not an image; valid UTF-8".utf8).write(to: imageNamedText)
        let file = FileTab(path: imageNamedText.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        XCTAssertEqual(file.text, "not an image; valid UTF-8")

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let imagePath = directory.appendingPathComponent("valid.png")
        try png.write(to: imagePath)
        let image = FileTab(path: imagePath.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        image.loadIfNeeded()
        try await waitForFileTabState { if case .image = image.content { return true }; return false }
        guard case .image(let preview) = image.content else { return XCTFail("Expected actual image preview") }
        XCTAssertEqual(preview.poster.width, 2)
    }

    func testFixedHostDisconnectRebindsDirtyFileWithoutLosingDraft() async throws {
        let host = "fixture-\(UUID().uuidString)"
        let project = Project(fallbackName: "fixed host", workspaceConfiguration: .standard)
        project.sshHost = host
        let path = "/fixture/file.txt"
        let file = FileTab(path: path, backend: EditorWorkspaceFixture(path: path, contents: Data("original".utf8)),
                           workspaceIdentity: "ssh:" + host)
        try await file.waitForText()
        file.text = "unsaved"
        file.refreshDirtyState()
        project.append(PaneTab(content: .file(file)))
        SSHHostWorkspaces.setConnected(false, for: host)
        XCTAssertNil(project.connectedWorkspace(for: "ssh:" + host))
        try await waitForFileTabState { file.readOnlyReason != nil }
        guard file.readOnlyReason != nil else { return }
        await file.save()
        XCTAssertEqual(file.text, "unsaved")
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
        SSHHostWorkspaces.setConnected(true, for: host)
        XCTAssertNil(file.readOnlyReason)
        XCTAssertEqual(file.text, "unsaved")
        XCTAssertTrue(file.isDirty)
    }

    func testUnconsumedRemoteTabRemainsLazyAcrossReconnect() async throws {
        let path = "/fixture/restored.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("restored".utf8))
        let identity = "ssh:p2-\(UUID().uuidString)"
        let file = FileTab(path: path, backend: backend, workspaceIdentity: identity)
        file.rebindWorkspace(to: nil)
        file.rebindWorkspace(to: backend)
        try await Task.sleep(for: .milliseconds(80))
        let unreadCount = await backend.readCount
        XCTAssertEqual(unreadCount, 0, "Reconnect must not read an unconsumed restored tab")
        try await file.waitForText()
        let loadedCount = await backend.readCount
        XCTAssertEqual(loadedCount, 1)
        XCTAssertEqual(file.text, "restored")
    }

    func testVisibleRemoteTabRecoversWhenConnectionReturns() async throws {
        let path = "/fixture/visible.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("visible".utf8))
        let identity = "ssh:p2-\(UUID().uuidString)"
        let file = FileTab(path: path, backend: backend, workspaceIdentity: identity)
        file.rebindWorkspace(to: nil)
        file.refreshWhenSelected()
        file.rebindWorkspace(to: backend)
        try await waitForFileTabState { if case .text = file.content { return true }; return false }
        XCTAssertEqual(file.text, "visible")
        let readCount = await backend.readCount
        XCTAssertEqual(readCount, 1)
    }

    func testRepeatedWindowFocusCoalescesInFlightCleanRefresh() async throws {
        let path = "/fixture/\(UUID().uuidString)-focus.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await waitForFileTabState { await backend.pendingReadCount == 1 }
        await backend.replace(path: path, with: Data("updated".utf8))
        for _ in 0..<12 { file.refreshWhenSelected() }
        try await Task.sleep(for: .milliseconds(100))
        let reads = await backend.readCount
        await backend.finishRead(with: Data("original".utf8))
        try await waitForFileTabState { file.text == "updated" }
        let total = await backend.readCount
        XCTAssertEqual(reads, 2, "Repeated activation must reuse the pending disk read")
        XCTAssertEqual(total, 3, "One follow-up read must observe later changes without a refresh storm")
        XCTAssertEqual(file.text, "updated")
    }

    func testQueuedRefreshCannotResurrectAfterDirtyEdit() async throws {
        let path = "/fixture/\(UUID().uuidString)-edit.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await waitForFileTabState { await backend.pendingReadCount == 1 }
        file.refreshWhenSelected()
        file.text = "user draft"
        file.refreshDirtyState()
        await backend.finishRead(with: Data("late disk snapshot".utf8))
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(file.text, "user draft")
        XCTAssertTrue(file.isDirty)
        let reads = await backend.readCount
        XCTAssertEqual(reads, 2)
    }

    func testQueuedRefreshCannotResurrectAfterSSHDisconnect() async throws {
        let path = "/fixture/\(UUID().uuidString)-ssh.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend,
                           workspaceIdentity: "ssh:fixture-\(UUID().uuidString)")
        try await file.waitForText()
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await waitForFileTabState { await backend.pendingReadCount == 1 }
        file.refreshWhenSelected()
        file.rebindWorkspace(to: nil)
        await backend.finishRead(with: Data("late disconnected data".utf8))
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(file.text, "original")
        XCTAssertNotNil(file.readOnlyReason)
        let reads = await backend.readCount
        XCTAssertEqual(reads, 2, "Old pending focus must not retry over a disconnected channel")
        file.rebindWorkspace(to: backend)
        try await file.waitForText()
        XCTAssertNil(file.readOnlyReason)
        XCTAssertEqual(file.text, "original")
        let recoveredCount = await backend.readCount
        XCTAssertEqual(recoveredCount, 3)
    }

    func testTransientCleanRefreshErrorPreservesLoadedTextAndRecovers() async throws {
        let path = "/fixture/\(UUID().uuidString)-transient.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        let revision = file.reloadRevision
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await waitForFileTabState { await backend.pendingReadCount == 1 }
        await backend.finishRead()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(file.text, "original", "A transient refresh failure cannot erase a loaded preview")
        if case .text = file.content {} else { XCTFail("A loaded document must survive a transient read error") }
        XCTAssertEqual(file.reloadRevision, revision)
        XCTAssertNotNil(file.reloadError, "Stale cached content must be visibly identified")
        await backend.replace(path: path, with: Data("recovered".utf8))
        file.refreshWhenSelected()
        try await file.waitForText()
        XCTAssertEqual(file.text, "recovered")
        XCTAssertNil(file.reloadError)
        try await backend.rename(from: path, to: path + ".gone")
        file.refreshWhenSelected()
        try await waitForFileTabState { if case .unavailable = file.content { return true }; return false }
        XCTAssertEqual(file.text, "", "A genuinely removed file must not masquerade as loaded data")
        XCTAssertNil(file.reloadError)
    }

    func testAppendRejectsStaleCachedTextWhenFreshReadFails() async throws {
        let path = "/fixture/\(UUID().uuidString)-ignore.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("old-rule\n".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        await backend.pauseOneRead()
        let append = Task {
            try await file.waitForTextBeforeAppending()
            file.appendText("/unsafe\n")
        }
        try await waitForFileTabState { await backend.pendingReadCount == 1 }
        await backend.finishRead()
        do {
            try await append.value
            XCTFail("A failed freshness check must not silently save stale .gitignore rules")
        } catch {}
        XCTAssertEqual(file.text, "old-rule\n")
        XCTAssertFalse(file.isDirty)
        let unchanged = await backend.data(at: path)
        XCTAssertEqual(unchanged, Data("old-rule\n".utf8))
        await backend.replace(path: path, with: Data("external-rule\n".utf8))
        try await file.waitForTextBeforeAppending()
        file.appendText("/safe\n")
        XCTAssertEqual(file.text, "external-rule\n/safe\n")
        XCTAssertTrue(file.isDirty)
    }

    func testFailedRefreshBlocksStaleWritesUntilSuccessfulRetry() async throws {
        let path = "/fixture/\(UUID().uuidString)-protected.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await waitForFileTabState { await backend.pendingReadCount == 1 }
        await backend.finishRead()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotNil(file.reloadError)
        file.text = "stale edit"
        file.refreshDirtyState()
        let attempted = Task { await file.save() }
        try await Task.sleep(for: .milliseconds(100))
        let unexpectedWrite = await backend.writingPath
        if unexpectedWrite != nil { await backend.finishWrite(failing: true) }
        await attempted.value
        XCTAssertNil(unexpectedWrite, "A stale preview must not initiate a disk write")
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.reloadError)
        let unchanged = await backend.data(at: path)
        XCTAssertEqual(unchanged, Data("original".utf8), "Refresh failure must block a stale write")
        file.text = "original"
        file.refreshDirtyState()
        file.refreshWhenSelected()
        try await file.waitForText()
        XCTAssertNil(file.reloadError)
        file.text = "new edit"
        file.refreshDirtyState()
        let saved = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == path }
        await backend.finishWrite()
        await saved.value
        XCTAssertFalse(file.isDirty)
        let result = await backend.data(at: path)
        XCTAssertEqual(result, Data("new edit".utf8))
    }

    func testFixedHostDisconnectBeforeLoadShowsReasonWithoutReading() async throws {
        let host = "fixture-\(UUID().uuidString)"
        let project = Project(fallbackName: "offline", workspaceConfiguration: .standard)
        project.sshHost = host
        let backend = EditorWorkspaceFixture(path: "/fixture/file.txt", contents: Data("original".utf8))
        let file = FileTab(path: "/fixture/file.txt", backend: backend, workspaceIdentity: "ssh:" + host)
        project.append(PaneTab(content: .file(file)))
        SSHHostWorkspaces.setConnected(false, for: host)
        guard case .unavailable(let reason) = file.content else { return XCTFail("Must not remain blank/loading") }
        XCTAssertEqual(reason, file.readOnlyReason)
        let reads = await backend.readCount
        XCTAssertEqual(reads, 0)
    }

    func testAppendWaitsForReplacementReadWithoutUsingLoadingOrCachedText() async throws {
        for initiallyLoading in [true, false] {
            let path = "/fixture/.gitignore"
            let backend = EditorWorkspaceFixture(path: path, contents: Data("cached\n".utf8))
            if initiallyLoading { await backend.pauseOneRead() }
            let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
            file.loadIfNeeded()
            file.autoSaveSuspendedForClose = true
            if !initiallyLoading {
                try await waitForFileTabState { if case .text = file.content { return true }; return false }
                await backend.pauseOneRead()
                file.reloadFromDiskIfClean()
            }
            try await waitForFileTabState { await backend.pendingReadCount == 1 }
            let premature = expectation(description: "Wait must follow the replacement read")
            premature.isInverted = true
            let waiting = expectation(description: "Append began waiting for the first read")
            var checkingEarlyCompletion = true
            let append = Task {
                defer { if checkingEarlyCompletion { premature.fulfill() } }
                waiting.fulfill()
                try await file.waitForText()
                file.appendText("/new\n")
            }
            await fulfillment(of: [waiting], timeout: 1)
            await backend.pauseOneRead()
            file.reloadFromDiskIfClean()
            try await waitForFileTabState { await backend.pendingReadCount == 2 }
            await backend.finishRead(with: Data("superseded\n".utf8))
            await fulfillment(of: [premature], timeout: 0.1)
            checkingEarlyCompletion = false
            await backend.finishRead(with: Data("latest rules\n".utf8))
            do { try await append.value } catch { XCTFail(error.localizedDescription) }
            XCTAssertEqual(file.text, "latest rules\n/new\n")
            XCTAssertTrue(file.isDirty)
        }
    }

    func testAppendWaitsForRemoteReadAndRetainsTextOnSaveFailure() async throws {
        let path = "/fixture/.gitignore"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("existing\n".utf8))
        await backend.pauseOneRead()
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        file.loadIfNeeded()
        try await waitForFileTabState { await backend.readingPath == path }
        let append = Task {
            try await file.waitForText()
            file.appendText("/new\n")
            await file.save()
        }
        await Task.yield()
        XCTAssertEqual(file.text, "")
        await backend.finishRead(with: Data("existing\n".utf8))
        try await waitForFileTabState { await backend.writingPath == path }
        await backend.finishWrite(failing: true)
        try await append.value
        XCTAssertEqual(file.text, "existing\n/new\n")
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
        let stored = await backend.data(at: path)
        XCTAssertEqual(stored, Data("existing\n".utf8))
        file.autoSaveSuspendedForClose = true
    }
    func testFailedCleanEncodingSaveBlocksGitAndProtectedFileMutation() async throws {
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let project = Project(fallbackName: "save safety", workspaceConfiguration: .standard)
        manager.projects = [project]
        manager.selectedProjectID = project.id
        let repository = "/fixture/git"
        let path = repository + "/failed-encoding.txt"
        let original = Data("original".utf8)
        let backend = EditorWorkspaceFixture(path: path, contents: original)
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()
        project.append(PaneTab(content: .file(file)))

        let converting = Task { await file.save(as: .utf8BOM) }
        try await waitForFileTabState { await backend.writingPath == path }
        await backend.finishWrite(failing: true)
        await converting.value
        XCTAssertFalse(file.isDirty)
        XCTAssertFalse(file.isSaving)
        XCTAssertNotNil(file.saveError)

        XCTAssertFalse(workspaceApplication.canRunGitAction(repository: repository, scope: "ssh:fixture"))
        let gitReady = await workspaceApplication.saveBeforeGitAction(
            repository: repository, scope: "ssh:fixture", isCurrent: { true }
        )
        XCTAssertFalse(gitReady, "A Git action cannot supersede a failed clean encoding conversion")

        var mutated = false
        do {
            try await workspaceApplication.withProtectedFiles(
                paths: [path], workspace: "ssh:fixture"
            ) {
                mutated = true
            }
            XCTFail("A file rename/delete cannot run while an encoding conversion is unresolved")
        } catch {}
        XCTAssertFalse(mutated)
        XCTAssertFalse(file.isDirty)
        XCTAssertNotNil(file.saveError)
        let persisted = await backend.data(at: path)
        XCTAssertEqual(persisted, original)

        let retry = Task { await file.save(as: .utf8BOM) }
        try await waitForFileTabState { await backend.writingPath == path }
        await backend.finishWrite()
        await retry.value
        XCTAssertNil(file.saveError)
        XCTAssertTrue(workspaceApplication.canRunGitAction(repository: repository, scope: "ssh:fixture"))
        let gitReadyAfterSave = await workspaceApplication.saveBeforeGitAction(
            repository: repository, scope: "ssh:fixture", isCurrent: { true }
        )
        XCTAssertTrue(gitReadyAfterSave)
        try await workspaceApplication.withProtectedFiles(paths: [path], workspace: "ssh:fixture") {
            mutated = true
        }
        XCTAssertTrue(mutated, "A successful conversion must restore file mutation eligibility")
        let saved = await backend.data(at: path)
        XCTAssertEqual(saved, TextFileEncoding.utf8BOM.encoded("original"))
    }

    func testGitPreparationWaitsForWritesAndNeverClosesOrLosesEditedTab() async throws {
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let project = Project(fallbackName: "Git Save", workspaceConfiguration: .standard)
        manager.projects = [project]
        manager.selectedProjectID = project.id
        let path = "/fixture/git/file.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("baseline".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()
        let tab = PaneTab(content: .file(file))
        project.append(tab)
        try await waitForFileTabState { if case .text = file.content { return true }; return false }
        file.text = "first edit"
        file.refreshDirtyState()
        let saving = Task {
            await self.workspaceApplication.saveBeforeGitAction(repository: "/fixture/git", scope: "ssh:fixture", isCurrent: { true })
        }
        try await waitForFileTabState { await backend.writingPath == path }
        file.text = "new edit while saving"
        file.refreshDirtyState()
        await backend.finishWrite()
        let prepared = await saving.value
        XCTAssertFalse(prepared)
        XCTAssertTrue(project.tabs.contains { $0 === tab })
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, "new edit while saving")
        let persisted = await backend.data(at: path)
        XCTAssertEqual(persisted, Data("first edit".utf8))

        let failed = Task {
            await self.workspaceApplication.saveBeforeGitAction(repository: "/fixture/git", scope: "ssh:fixture", isCurrent: { true })
        }
        try await waitForFileTabState { await backend.writingPath == path }
        await backend.finishWrite(failing: true)
        let readyAfterFailure = await failed.value
        XCTAssertFalse(readyAfterFailure)
        XCTAssertTrue(project.tabs.contains { $0 === tab })
        XCTAssertEqual(file.text, "new edit while saving")
        XCTAssertNotNil(file.saveError)
    }

    func testGitPreparationMatchesNativePrivatePathAliasWithoutSavingOtherRepository() async throws {
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside.txt")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("baseline".utf8).write(to: inside)
        try Data("other repository".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let project = Project(fallbackName: "Aliases", workspaceConfiguration: .standard)
        manager.projects = [project]
        manager.selectedProjectID = project.id
        let selected = FileTab(path: inside.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await selected.waitForText()
        let other = FileTab(path: outside.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await other.waitForText()
        project.append(PaneTab(content: .file(selected)))
        project.append(PaneTab(content: .file(other)))
        selected.text = "save selected"
        selected.refreshDirtyState()
        other.text = "keep unsaved elsewhere"
        other.refreshDirtyState()
        let repository = root.path.hasPrefix("/var/") ? "/private" + root.path : root.path
        let prepared = await workspaceApplication.saveBeforeGitAction(repository: repository, scope: "local", isCurrent: { true })
        XCTAssertTrue(prepared)
        XCTAssertEqual(try String(contentsOf: inside, encoding: .utf8), "save selected")
        XCTAssertFalse(selected.isDirty)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "other repository")
        XCTAssertTrue(other.isDirty)
    }

    func testProjectCloseWaitsForFileSaveAndRetainsUnsavedOnFailure() async throws {
        let prior = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(prior); TerminalHistoryStore.save(histories) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let firstProject = try XCTUnwrap(manager.selectedProject)
        let firstURL = root.appendingPathComponent("must-save.txt")
        try "before".write(to: firstURL, atomically: true, encoding: .utf8)
        let local = FileTab(path: firstURL.path, backend: LocalWorkspaceBackend.shared,
                            workspaceIdentity: nil)
        try await local.waitForText()
        firstProject.append(PaneTab(content: .file(local)))
        local.text = "durably saved"
        local.refreshDirtyState()
        manager.close(firstProject)
        try await waitForFileTabState { !manager.projects.contains(where: { $0 === firstProject }) }
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "durably saved")

        manager.addLocalFolders([root])
        let failingProject = try XCTUnwrap(manager.selectedProject)
        let activeRoot = root.appendingPathComponent("still-open", isDirectory: true)
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        manager.addLocalFolders([activeRoot])
        let activeProject = try XCTUnwrap(manager.selectedProject)
        let remotePath = root.appendingPathComponent("remote.txt")
        try "local sentinel".write(to: remotePath, atomically: true, encoding: .utf8)
        let backend = EditorWorkspaceFixture(path: remotePath.path, contents: Data("old".utf8))
        let remote = FileTab(path: remotePath.path, backend: backend,
                             workspaceIdentity: "ssh:fixture")
        try await remote.waitForText()
        failingProject.append(PaneTab(content: .file(remote)))
        remote.text = "draft not yet persisted"
        remote.refreshDirtyState()
        manager.close(failingProject)
        try await waitForFileTabState { await backend.writingPath == remotePath.path }
        await backend.finishWrite(failing: true)
        try await waitForFileTabState { remote.saveError != nil }
        XCTAssertTrue(manager.projects.contains(where: { $0 === failingProject }))
        XCTAssertTrue(manager.projects.contains(where: { $0 === activeProject }))
        XCTAssertEqual(manager.selectedProjectID, activeProject.id,
                       "A failed background project close cannot switch the active project")
        XCTAssertTrue(remote.isDirty)
        XCTAssertEqual(try String(contentsOf: remotePath, encoding: .utf8), "local sentinel")

        XCTAssertTrue(self.workspaceApplication.hasUnsavedEditors)
        let exitAttempt = Task { await self.workspaceApplication.saveBeforeTermination() }
        try await waitForFileTabState { await backend.writingPath == remotePath.path }
        await backend.finishWrite(failing: true)
        let shouldExit = await exitAttempt.value
        XCTAssertFalse(shouldExit, "A failed auto-save must veto application termination")
        XCTAssertTrue(remote.isDirty)
    }

    func testCloseAllSavesOriginallyCleanTabEditedDuringAnotherTabWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(fallbackName: "Close All", workspaceConfiguration: .standard)
        let remotePath = root.appendingPathComponent("blocked-remote.txt").path
        let backend = EditorWorkspaceFixture(path: remotePath, contents: Data("remote original".utf8))
        let remote = FileTab(path: remotePath, backend: backend, workspaceIdentity: "ssh:fixture")
        try await remote.waitForText()
        let localURL = root.appendingPathComponent("newly-edited.txt")
        try "local original".write(to: localURL, atomically: true, encoding: .utf8)
        let local = FileTab(path: localURL.path, backend: LocalWorkspaceBackend.shared,
                            workspaceIdentity: nil)
        try await local.waitForText()
        project.append(PaneTab(content: .file(remote)))
        project.append(PaneTab(content: .file(local)))
        remote.text = "remote saved"
        remote.refreshDirtyState()
        project.closeAll()
        try await waitForFileTabState { await backend.writingPath == remotePath }

        local.text = "new draft before close finishes"
        local.refreshDirtyState()
        await backend.finishWrite()
        try await waitForFileTabState { project.tabs.isEmpty }

        XCTAssertFalse(local.isDirty)
        XCTAssertEqual(try String(contentsOf: localURL, encoding: .utf8),
                       "new draft before close finishes")
        let persistedRemote = await backend.data(at: remotePath)
        XCTAssertEqual(persistedRemote, Data("remote saved".utf8))
    }

    func testProjectCloseKeepsNewDraftCreatedInAnotherTabDuringPendingSave() async throws {
        let previous = SessionStore.load()
        let previousHistory = TerminalHistoryStore.load()
        defer { SessionStore.save(previous); TerminalHistoryStore.save(previousHistory) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let remotePath = root.appendingPathComponent("blocked-remote.txt").path
        let backend = EditorWorkspaceFixture(path: remotePath, contents: Data("original".utf8))
        let remote = FileTab(path: remotePath, backend: backend, workspaceIdentity: "ssh:fixture")
        try await remote.waitForText()
        let localURL = root.appendingPathComponent("newly-edited.txt")
        try "local original".write(to: localURL, atomically: true, encoding: .utf8)
        let local = FileTab(path: localURL.path, backend: LocalWorkspaceBackend.shared,
                            workspaceIdentity: nil)
        try await local.waitForText()
        project.append(PaneTab(content: .file(remote)))
        project.append(PaneTab(content: .file(local)))
        remote.text = "remote saved"
        remote.refreshDirtyState()
        manager.close(project)
        try await waitForFileTabState { await backend.writingPath == remotePath }

        local.text = "new draft while remote save is pending"
        local.refreshDirtyState()
        XCTAssertTrue(local.isDirty)
        await backend.finishWrite()
        try await waitForFileTabState { !remote.isDirty }
        for _ in 0..<5 { await Task.yield() }

        XCTAssertTrue(manager.projects.contains { $0 === project },
                      "A new draft in another tab must not disappear during project close")
        XCTAssertTrue(local.isDirty)
        XCTAssertEqual(local.text, "new draft while remote save is pending")
        XCTAssertEqual(try String(contentsOf: localURL, encoding: .utf8), "local original")
        let persistedRemote = await backend.data(at: remotePath)
        XCTAssertEqual(persistedRemote, Data("remote saved".utf8))
        XCTAssertFalse(remote.autoSaveSuspendedForClose)

        // Retrying close should persist the new draft rather than strand it.
        manager.close(project)
        try await waitForFileTabState { !manager.projects.contains(where: { $0 === project }) }
        XCTAssertEqual(try String(contentsOf: localURL, encoding: .utf8),
                       "new draft while remote save is pending")
    }

    func testCleanEncodingWriteCannotBeSkippedByAnyCloseRoute() async throws {
        enum CloseRoute: CaseIterable { case tab, batch, project, window, application }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try XCTUnwrap(TextFileEncoding.utf8BOM.encoded("original"))

        for route in CloseRoute.allCases {
            let manager = workspaceApplication.makeWindow()
            defer { manager.windowClosed() }
            manager.addLocalFolders([root])
            let project = try XCTUnwrap(manager.selectedProject)
            let path = root.appendingPathComponent(UUID().uuidString + ".txt").path
            let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
            let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
            try await file.waitForText()
            let tab = PaneTab(content: .file(file))
            project.append(tab)

            let writing = Task { await file.save(as: .utf8BOM) }
            try await waitForFileTabState { await backend.writingPath == path }
            XCTAssertFalse(file.isDirty, "Encoding-only save must keep the text clean")
            XCTAssertTrue(file.isSaving)
            XCTAssertTrue(manager.hasUnsavedEditorsInWindow,
                          "An active write must protect its window even without text edits")
            XCTAssertTrue(workspaceApplication.hasUnsavedEditors,
                          "An active write must protect application termination")

            let closing: Task<Bool, Never>?
            switch route {
            case .tab:
                project.close(tab)
                XCTAssertTrue(project.tabs.contains { $0 === tab },
                              "Single-tab close must not retire an active writer")
                closing = nil
            case .batch:
                project.closeAll()
                XCTAssertTrue(project.tabs.contains { $0 === tab },
                              "Batch close must not retire an active writer")
                closing = nil
            case .project:
                manager.close(project)
                XCTAssertTrue(manager.projects.contains { $0 === project },
                              "Project close must not retire an active writer")
                closing = nil
            case .window:
                closing = Task { await manager.saveBeforeWindowClose() }
            case .application:
                closing = Task { await workspaceApplication.saveBeforeTermination() }
            }

            await backend.finishWrite()
            await writing.value
            if let closing {
                let approved = await closing.value
                XCTAssertTrue(approved, "A completed successful write must permit close")
            } else if route == .project {
                try await waitForFileTabState { !manager.projects.contains { $0 === project } }
            } else {
                try await waitForFileTabState { project.tabs.isEmpty }
            }
            let persisted = await backend.data(at: path)
            XCTAssertEqual(persisted, expected)
        }
    }

    func testFailedCleanEncodingWriteVetoesAllCloseRoutes() async throws {
        enum CloseRoute: CaseIterable { case tab, batch, project, window, application }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for route in CloseRoute.allCases {
            let manager = workspaceApplication.makeWindow()
            defer { manager.windowClosed() }
            manager.addLocalFolders([root])
            let project = try XCTUnwrap(manager.selectedProject)
            let path = root.appendingPathComponent(UUID().uuidString + ".txt").path
            let original = Data("original".utf8)
            let backend = EditorWorkspaceFixture(path: path, contents: original)
            let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
            try await file.waitForText()
            let tab = PaneTab(content: .file(file))
            project.append(tab)

            let writing = Task { await file.save(as: .utf8BOM) }
            try await waitForFileTabState { await backend.writingPath == path }
            XCTAssertTrue(file.isSaving)
            XCTAssertFalse(file.isDirty)

            let closing: Task<Bool, Never>?
            var closeStarted = false
            switch route {
            case .tab:
                project.close(tab)
                closing = nil
            case .batch:
                project.closeAll()
                closing = nil
            case .project:
                manager.close(project)
                closing = nil
            case .window:
                closing = Task {
                    closeStarted = true
                    return await manager.saveBeforeWindowClose()
                }
            case .application:
                closing = Task {
                    closeStarted = true
                    return await workspaceApplication.saveBeforeTermination()
                }
            }
            if closing != nil {
                try await waitForFileTabState { closeStarted }
            } else {
                XCTAssertTrue(project.tabs.contains { $0 === tab },
                              "An active writer must remain open while its close is pending")
                XCTAssertTrue(manager.projects.contains { $0 === project })
            }

            // Complete the write immediately, even if a close Task has not been scheduled yet.
            await backend.finishWrite(failing: true)
            await writing.value
            if let closing {
                let mayClose = await closing.value
                XCTAssertFalse(mayClose, "A failed encoding write must veto this close attempt")
            } else {
                try await waitForFileTabState { !file.autoSaveSuspendedForClose }
            }

            XCTAssertTrue(manager.projects.contains { $0 === project },
                          "A failed encoding write must preserve its project")
            XCTAssertTrue(project.tabs.contains { $0 === tab },
                          "A failed encoding write must preserve the file tab")
            XCTAssertFalse(file.isDirty)
            XCTAssertNotNil(file.saveError)
            let persisted = await backend.data(at: path)
            XCTAssertEqual(persisted, original)
        }
    }

    func testFailedEncodingConversionStillProtectsASecondCloseAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let path = root.appendingPathComponent("failed-encoding.txt").path
        let original = Data("original".utf8)
        let backend = EditorWorkspaceFixture(path: path, contents: original)
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        project.append(PaneTab(content: .file(file)))

        let writing = Task { await file.save(as: .utf8BOM) }
        try await waitForFileTabState { await backend.writingPath == path }
        await backend.finishWrite(failing: true)
        await writing.value
        XCTAssertFalse(file.isDirty)
        XCTAssertFalse(file.isSaving)
        XCTAssertNotNil(file.saveError)

        XCTAssertTrue(project.tabs[0].content.hasUnresolvedSave,
                      "A failed encoding conversion still represents an unresolved save intent")
        XCTAssertTrue(manager.hasUnsavedEditorsInWindow)
        XCTAssertTrue(workspaceApplication.hasUnsavedEditors)
        let mayClose = await manager.saveBeforeWindowClose()
        XCTAssertFalse(mayClose, "Retrying window close cannot discard the failed conversion")
        let mayQuit = await workspaceApplication.saveBeforeTermination()
        XCTAssertFalse(mayQuit, "Retrying Quit cannot silently discard the failed conversion")

        manager.close(project)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(manager.projects.contains { $0 === project })
        XCTAssertTrue(project.tabs.contains { $0.content.id == file.id })
        let persisted = await backend.data(at: path)
        XCTAssertEqual(persisted, original)
    }

    func testWindowCloseDetectsEncodingFailureAfterAnotherTabFinishesSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)

        let firstPath = root.appendingPathComponent("first.txt").path
        let firstBackend = EditorWorkspaceFixture(path: firstPath, contents: Data("first original".utf8))
        let first = FileTab(path: firstPath, backend: firstBackend, workspaceIdentity: nil)
        try await first.waitForText()
        project.append(PaneTab(content: .file(first)))
        first.text = "first saved"
        first.refreshDirtyState()

        let secondPath = root.appendingPathComponent("encoding.txt").path
        let original = Data("second original".utf8)
        let secondBackend = EditorWorkspaceFixture(path: secondPath, contents: original)
        let second = FileTab(path: secondPath, backend: secondBackend, workspaceIdentity: nil)
        try await second.waitForText()
        project.append(PaneTab(content: .file(second)))
        let encoding = Task { await second.save(as: .utf8BOM) }
        try await waitForFileTabState { await secondBackend.writingPath == secondPath }

        let closing = Task { await manager.saveBeforeWindowClose() }
        try await waitForFileTabState { await firstBackend.writingPath == firstPath }
        await secondBackend.finishWrite(failing: true)
        await encoding.value
        XCTAssertNotNil(second.saveError)
        XCTAssertFalse(second.isDirty)
        await firstBackend.finishWrite()
        let mayClose = await closing.value

        XCTAssertFalse(mayClose, "Close must remember an encoding write pending at the start")
        XCTAssertTrue(project.tabs.contains { $0.content.id == second.id })
        let firstStored = await firstBackend.data(at: firstPath)
        let secondStored = await secondBackend.data(at: secondPath)
        XCTAssertEqual(firstStored, Data("first saved".utf8))
        XCTAssertEqual(secondStored, original)
    }

    func testApplicationTerminationDetectsEncodingFailureInLaterWindow() async throws {
        let previous = SessionStore.load()
        let previousHistory = TerminalHistoryStore.load()
        defer { SessionStore.save(previous); TerminalHistoryStore.save(previousHistory) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstWindow = workspaceApplication.makeWindow()
        let secondWindow = workspaceApplication.makeWindow()
        defer { firstWindow.windowClosed(); secondWindow.windowClosed() }
        firstWindow.addLocalFolders([root])
        secondWindow.addLocalFolders([root])
        let firstProject = try XCTUnwrap(firstWindow.selectedProject)
        let secondProject = try XCTUnwrap(secondWindow.selectedProject)

        let firstPath = root.appendingPathComponent("blocking.txt").path
        let firstBackend = EditorWorkspaceFixture(path: firstPath, contents: Data("old first".utf8))
        let first = FileTab(path: firstPath, backend: firstBackend, workspaceIdentity: nil)
        try await first.waitForText()
        firstProject.append(PaneTab(content: .file(first)))
        first.text = "new first"
        first.refreshDirtyState()

        let secondPath = root.appendingPathComponent("conversion.txt").path
        let original = Data("old encoding".utf8)
        let secondBackend = EditorWorkspaceFixture(path: secondPath, contents: original)
        let second = FileTab(path: secondPath, backend: secondBackend, workspaceIdentity: nil)
        try await second.waitForText()
        secondProject.append(PaneTab(content: .file(second)))
        let encoding = Task { await second.save(as: .utf8BOM) }
        try await waitForFileTabState { await secondBackend.writingPath == secondPath }

        let terminating = Task { await workspaceApplication.saveBeforeTermination() }
        try await waitForFileTabState { await firstBackend.writingPath == firstPath }
        await secondBackend.finishWrite(failing: true)
        await encoding.value
        XCTAssertFalse(second.isDirty)
        XCTAssertNotNil(second.saveError)
        await firstBackend.finishWrite()
        let mayQuit = await terminating.value

        XCTAssertFalse(mayQuit, "An earlier window save must not hide a failed encoding write elsewhere")
        XCTAssertTrue(secondProject.tabs.contains { $0.content.id == second.id })
        let firstStored = await firstBackend.data(at: firstPath)
        let secondStored = await secondBackend.data(at: secondPath)
        XCTAssertEqual(firstStored, Data("new first".utf8))
        XCTAssertEqual(secondStored, original)
    }

    func testWindowCloseVetoesNewDraftCreatedInAnotherTabDuringPendingSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let remotePath = root.appendingPathComponent("blocked-remote.txt").path
        let backend = EditorWorkspaceFixture(path: remotePath, contents: Data("original".utf8))
        let remote = FileTab(path: remotePath, backend: backend, workspaceIdentity: "ssh:fixture")
        try await remote.waitForText()
        let localURL = root.appendingPathComponent("newly-edited.txt")
        try "local original".write(to: localURL, atomically: true, encoding: .utf8)
        let local = FileTab(path: localURL.path, backend: LocalWorkspaceBackend.shared,
                            workspaceIdentity: nil)
        try await local.waitForText()
        // The clean tab is visited before the pending remote write. It can
        // become dirty after the close flow has already skipped it.
        project.append(PaneTab(content: .file(local)))
        project.append(PaneTab(content: .file(remote)))
        remote.text = "remote saved"
        remote.refreshDirtyState()
        let closing = Task { await manager.saveBeforeWindowClose() }
        try await waitForFileTabState { await backend.writingPath == remotePath }

        local.text = "new draft while window close is pending"
        local.refreshDirtyState()
        await backend.finishWrite()
        let mayClose = await closing.value

        XCTAssertFalse(mayClose, "A new draft must veto window closure until it is saved")
        XCTAssertTrue(manager.projects.contains { $0 === project })
        XCTAssertTrue(local.isDirty)
        XCTAssertEqual(local.text, "new draft while window close is pending")
        XCTAssertEqual(try String(contentsOf: localURL, encoding: .utf8), "local original")
        let persistedRemote = await backend.data(at: remotePath)
        XCTAssertEqual(persistedRemote, Data("remote saved".utf8))

        let mayCloseOnRetry = await manager.saveBeforeWindowClose()
        XCTAssertTrue(mayCloseOnRetry,
                      "A second close must successfully save the newly edited tab")
        XCTAssertEqual(try String(contentsOf: localURL, encoding: .utf8),
                       "new draft while window close is pending")
    }

    func testApplicationTerminationRechecksEarlierWindowAfterAnotherWindowSave() async throws {
        let previous = SessionStore.load()
        let previousHistory = TerminalHistoryStore.load()
        defer { SessionStore.save(previous); TerminalHistoryStore.save(previousHistory) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = self.workspaceApplication.makeWindow()
        let second = self.workspaceApplication.makeWindow()
        defer { first.windowClosed(); second.windowClosed() }
        first.addLocalFolders([root])
        second.addLocalFolders([root])
        let firstProject = try XCTUnwrap(first.selectedProject)
        let secondProject = try XCTUnwrap(second.selectedProject)

        let localURL = root.appendingPathComponent("earlier-window.txt")
        try "original".write(to: localURL, atomically: true, encoding: .utf8)
        let local = FileTab(path: localURL.path, backend: LocalWorkspaceBackend.shared,
                            workspaceIdentity: nil)
        try await local.waitForText()
        firstProject.append(PaneTab(content: .file(local)))
        let remotePath = root.appendingPathComponent("later-window.txt").path
        let backend = EditorWorkspaceFixture(path: remotePath, contents: Data("remote original".utf8))
        let remote = FileTab(path: remotePath, backend: backend, workspaceIdentity: "ssh:fixture")
        try await remote.waitForText()
        secondProject.append(PaneTab(content: .file(remote)))
        remote.text = "remote saved"
        remote.refreshDirtyState()

        let terminating = Task { await self.workspaceApplication.saveBeforeTermination() }
        try await waitForFileTabState { await backend.writingPath == remotePath }
        local.text = "new draft in the already checked window"
        local.refreshDirtyState()
        await backend.finishWrite()
        let mayQuit = await terminating.value

        XCTAssertFalse(mayQuit, "Quit must recheck other windows edited during a pending save")
        XCTAssertTrue(local.isDirty)
        XCTAssertEqual(local.text, "new draft in the already checked window")
        XCTAssertEqual(try String(contentsOf: localURL, encoding: .utf8), "original")
        let persistedRemote = await backend.data(at: remotePath)
        XCTAssertEqual(persistedRemote, Data("remote saved".utf8))

        let retryMayQuit = await self.workspaceApplication.saveBeforeTermination()
        XCTAssertTrue(retryMayQuit, "The next quit must save drafts in all windows")
        XCTAssertEqual(try String(contentsOf: localURL, encoding: .utf8),
                       "new draft in the already checked window")
    }

    func testProjectTabSwitchAndCloseAutomaticallySaveBeforeRemoving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("autosave.txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        let project = Project(fallbackName: "autosave", workspaceConfiguration: .standard)
        let filePane = PaneTab(content: .file(file))
        project.append(filePane)

        file.text = "saved when selecting the browser"
        file.refreshDirtyState()
        project.append(PaneTab(content: .browser(BrowserTab(initialFocus: .none))))
        try await waitForFileTabState { !file.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved when selecting the browser")

        file.text = "saved when closing the file"
        file.refreshDirtyState()
        project.close(filePane)
        try await waitForFileTabState { !project.tabs.contains(where: { $0.id == filePane.id }) }
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved when closing the file")
    }

    func testFocusTriggeredSaveSerializesConcurrentEditsAndKeepsFailures() async throws {
        let path = "/fixture/\(UUID().uuidString).txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()

        file.text = "first🙂"
        file.refreshDirtyState()
        let beforeFocusLoss = await backend.writingPath
        XCTAssertNil(beforeFocusLoss, "Typing must not launch a timed or per-keystroke save")
        file.autoSaveOnFocusLoss()
        try await waitForFileTabState { await backend.writingPath == path }

        file.text = "second🪨"
        file.refreshDirtyState()
        file.autoSaveOnFocusLoss()
        await backend.finishWrite()
        try await waitForFileTabState {
            let stored = await backend.data(at: path)
            let writing = await backend.writingPath
            return stored == Data("first🙂".utf8) && writing == path
        }
        XCTAssertTrue(file.isDirty, "The first completed write cannot mark the newer edit saved")
        await backend.finishWrite()
        try await waitForFileTabState { !file.isDirty }
        let final = await backend.data(at: path)
        XCTAssertEqual(final, Data("second🪨".utf8))

        file.text = "offline edit"
        file.refreshDirtyState()
        file.autoSaveOnFocusLoss()
        try await waitForFileTabState { await backend.writingPath == path }
        await backend.finishWrite(failing: true)
        try await waitForFileTabState { file.saveError != nil }
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, "offline edit")
        let retained = await backend.data(at: path)
        XCTAssertEqual(retained, Data("second🪨".utf8))
    }

    func testFileMutationWaitsForInFlightSaveAndDefersNewWritesUntilMoved() async throws {
        let oldPath = "/fixture/\(UUID().uuidString)-source.txt"
        let newPath = oldPath.replacingOccurrences(of: "-source", with: "-moved")
        let backend = EditorWorkspaceFixture(path: oldPath, contents: Data("original".utf8))
        let file = FileTab(path: oldPath, backend: backend, workspaceIdentity: "ssh:test")
        try await file.waitForText()
        file.text = "before move"; file.refreshDirtyState()
        let prior = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == oldPath }

        let lock = Task { await file.beginFileMutation() }
        // The mutation must not claim the old write completed before the backend does.
        await backend.finishWrite()
        await prior.value
        let accepted = await lock.value
        XCTAssertTrue(accepted)
        file.text = "editing during move"; file.refreshDirtyState()
        file.autoSaveOnFocusLoss()
        await Task.yield()
        let writingDuringMove = await backend.writingPath
        XCTAssertNil(writingDuringMove, "A save triggered during a move cannot write the old path")
        try await backend.rename(from: oldPath, to: newPath)
        file.updatePath(newPath)
        file.endFileMutation()
        try await waitForFileTabState { await backend.writingPath == newPath }
        await backend.finishWrite()
        try await waitForFileTabState { !file.isDirty }
        let oldStored = await backend.data(at: oldPath)
        XCTAssertNil(oldStored, "Pending saves must not recreate the original path")
        let newStored = await backend.data(at: newPath)
        XCTAssertEqual(newStored, Data("editing during move".utf8))
        XCTAssertEqual(file.path, newPath)
    }

    func testDeletedFileKeepsNewDraftWithoutResurrectingRemovedTarget() async throws {
        let path = "/fixture/\(UUID().uuidString)-removed.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:test")
        try await file.waitForText()
        let protected = await file.beginFileMutation()
        XCTAssertTrue(protected)
        file.text = "edit during deletion"; file.refreshDirtyState()
        file.autoSaveOnFocusLoss()
        await Task.yield()
        file.invalidateDeletedFile()
        file.endFileMutation()
        try await Task.sleep(for: .milliseconds(70))
        let pending = await backend.writingPath
        XCTAssertNil(pending, "Delayed auto save must not start an IO write on a deleted path")
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, "edit during deletion")
        XCTAssertNotNil(file.readOnlyReason)
        file.rebindWorkspace(to: backend)
        XCTAssertNotNil(file.readOnlyReason, "Reconnect must not make a deleted file writable")
    }

    func testFailedFileSaveRefusesMutationWithoutLosingDirtyText() async throws {
        let path = "/fixture/\(UUID().uuidString)-unsaved.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("baseline".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:test")
        try await file.waitForText()
        file.text = "unsaved buffer"; file.refreshDirtyState()
        let mutation = Task { await file.beginFileMutation() }
        try await waitForFileTabState { await backend.writingPath == path }
        await backend.finishWrite(failing: true)
        let accepted = await mutation.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(file.text, "unsaved buffer")
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
        let stored = await backend.data(at: path)
        XCTAssertEqual(stored, Data("baseline".utf8))
    }

    func testDirtyUndoSaveDuringEditRenameFailureAndStaleReload() async throws {
        let first = "/fixture/\(UUID().uuidString)-original.txt"
        let renamed = first.replacingOccurrences(of: "-original", with: "-renamed")
        let original = "原文😀\r\n"
        let backend = EditorWorkspaceFixture(path: first, contents: Data(original.utf8))
        let file = FileTab(path: first, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()
        XCTAssertEqual(file.text, original)
        let pane = PaneTab(content: .file(file))

        let dirtyObserved = expectation(description: "Pane sees FileTab dirty via Observation")
        withObservationTracking({ _ = pane.content.isDirty }) { dirtyObserved.fulfill() }
        file.text = "改稿🪨\r\n"
        file.refreshDirtyState()
        await fulfillment(of: [dirtyObserved], timeout: 1)
        XCTAssertTrue(pane.content.isDirty)
        file.text = original
        file.refreshDirtyState()
        XCTAssertFalse(pane.content.isDirty, "Undo to baseline clears dirty state")

        file.text = "first draft\r\n"
        file.refreshDirtyState()
        let firstSave = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == first }
        file.text = "second draft🪨\r\n"
        file.refreshDirtyState()
        await backend.finishWrite()
        await firstSave.value
        XCTAssertTrue(file.isDirty, "Edits made during save must remain unsaved")
        let firstStored = await backend.data(at: first)
        XCTAssertEqual(try XCTUnwrap(firstStored), Data("first draft\r\n".utf8))

        let secondSave = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == first }
        await backend.finishWrite()
        await secondSave.value
        XCTAssertFalse(file.isDirty)
        let secondStored = await backend.data(at: first)
        XCTAssertEqual(try XCTUnwrap(secondStored), Data(file.text.utf8))

        file.text = "third draft"; file.refreshDirtyState()
        let outdatedWrite = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == first }
        let pathObserved = expectation(description: "FileTab rename updates its path")
        withObservationTracking({ _ = file.path }) { pathObserved.fulfill() }
        file.updatePath(renamed)
        // A real rename moves the already accepted source entry. A write still
        // aimed at the old path must fail, never recreate or overwrite it.
        try await backend.rename(from: first, to: renamed)
        await fulfillment(of: [pathObserved], timeout: 1)
        await backend.finishWrite()
        await outdatedWrite.value
        XCTAssertEqual(file.path, renamed)
        XCTAssertTrue(file.isDirty, "Old path write must not claim new path was saved")
        let staleOldPath = await backend.data(at: first)
        XCTAssertNil(staleOldPath, "Stale in-flight save must not resurrect old path")
        let renamedBeforeSave = await backend.data(at: renamed)
        XCTAssertEqual(renamedBeforeSave, Data("second draft🪨\r\n".utf8),
                       "Rename must preserve the actual previous source version")

        let renamedWrite = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == renamed }
        await backend.finishWrite()
        await renamedWrite.value
        XCTAssertFalse(file.isDirty)
        let renamedStored = await backend.data(at: renamed)
        XCTAssertEqual(try XCTUnwrap(renamedStored), Data("third draft".utf8))

        file.text = "fourth draft"; file.refreshDirtyState()
        let rejectedWrite = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == renamed }
        await backend.finishWrite(failing: true)
        await rejectedWrite.value
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
        XCTAssertEqual(file.text, "fourth draft")
        let retainedAfterFailure = await backend.data(at: renamed)
        XCTAssertEqual(try XCTUnwrap(retainedAfterFailure), Data("third draft".utf8))

        file.text = "third draft"; file.refreshDirtyState()
        XCTAssertFalse(file.isDirty)
        await backend.pauseOneRead()
        file.reloadFromDiskIfClean()
        try await waitForFileTabState { await backend.readingPath == renamed }
        file.text = "local edit while old read awaits"; file.refreshDirtyState()
        await backend.finishRead(with: Data("stale remote read".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(file.text, "local edit while old read awaits")
        XCTAssertTrue(file.isDirty)
    }

    func testFailedEncodingRefreshPreservesLastReadableFileUntilRecovery() async throws {
        let path = "/fixture/encoding-reload.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("first\n".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()
        let initialRevision = file.reloadRevision

        await backend.replace(path: path, with: Data([0xFF, 0x80]))
        file.reloadFromDiskIfClean()
        try await waitForFileTabState { file.reloadError != nil }
        guard case .text = file.content else {
            return XCTFail("A failed reload must not destroy the previous document")
        }
        XCTAssertEqual(file.text, "first\n")
        XCTAssertEqual(file.reloadRevision, initialRevision)
        XCTAssertFalse(file.isDirty)

        await backend.replace(path: path, with: Data("restored\n".utf8))
        file.reloadFromDiskIfClean()
        try await waitForFileTabState {
            file.reloadError == nil && file.text == "restored\n"
        }
        XCTAssertEqual(file.text, "restored\n")
        XCTAssertEqual(file.fileEncoding, .utf8)
        XCTAssertEqual(file.reloadRevision, initialRevision + 1)

        await backend.replace(path: path, with: Data([0x61, 0x00, 0x62]))
        file.reloadFromDiskIfClean()
        try await waitForFileTabState {
            if case .unavailable = file.content { return true }
            return false
        }
        guard case .unavailable(let reason) = file.content else {
            return XCTFail("True binary replacement must invalidate a text document")
        }
        XCTAssertEqual(reason, String(localized: "Binary file", table: "Workspace"))
        XCTAssertEqual(file.text, "")
        XCTAssertNil(file.reloadError)
    }

    func testExplicitLegacyEncodingsOnlyAcceptLosslessRoundTrips() throws {
        for (encoding, text) in [
            (TextFileEncoding.gbk, "模型装配件"),
            (.gb18030, "字符𠮷😀"),
            (.shiftJIS, "日本語かな"),
            (.windows1252, "Café résumé"),
        ] {
            let bytes = try XCTUnwrap(encoding.encoded(text), encoding.name)
            XCTAssertEqual(encoding.decoded(bytes), text, encoding.name)
            XCTAssertEqual(encoding.encoded(try XCTUnwrap(encoding.decoded(bytes))), bytes)
        }
        XCTAssertNil(TextFileEncoding.gbk.encoded("😀"))
        XCTAssertNil(TextFileEncoding.windows1252.encoded("中文"))
    }

    func testWindowsMBCSFileUsesActualCodePageAndSavesExactlyInOriginalEncoding() async throws {
        let path = "/fixture/abaqus.rpy"
        let original = "# -*- coding: mbcs -*-\n# 模型装配件个数：二\n"
        let encoded = try XCTUnwrap(TextFileEncoding.gbk.encoded(original))
        let backend = EditorWorkspaceFixture(path: path, contents: encoded)
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:windows")
        try await file.waitForText()
        XCTAssertEqual(file.text, original)
        XCTAssertEqual(file.fileEncoding, .gbk)
        XCTAssertFalse(file.isDirty)

        let edited = original + "# 新增模型\n"
        file.text = edited
        file.refreshDirtyState()
        let saving = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == path }
        await backend.finishWrite()
        await saving.value
        XCTAssertNil(file.saveError)
        XCTAssertFalse(file.isDirty)
        let firstSaved = await backend.data(at: path)
        XCTAssertEqual(firstSaved, TextFileEncoding.gbk.encoded(edited))

        await file.save(as: .utf8)
        XCTAssertNotNil(file.saveError, "The declared mbcs header must block implicit transcoding")
        let stillGBK = await backend.data(at: path)
        XCTAssertEqual(stillGBK, firstSaved)
        file.reopen(using: .gbk)
        try await file.waitForText()
        XCTAssertNil(file.saveError)
        XCTAssertEqual(file.fileEncoding, .gbk)

        file.text = edited + "# 😀 cannot fit in CP936\n"
        file.refreshDirtyState()
        await file.save()
        XCTAssertNotNil(file.saveError)
        XCTAssertTrue(file.isDirty)
        let afterRejectedSave = await backend.data(at: path)
        XCTAssertEqual(afterRejectedSave, TextFileEncoding.gbk.encoded(edited))
    }

    func testUnmarkedLegacyTextCanReopenAndConvertOnlyWhenExplicitlySelected() async throws {
        let path = "/fixture/legacy.txt"
        let original = "中文内容\n"
        let source = try XCTUnwrap(TextFileEncoding.gbk.encoded(original))
        let backend = EditorWorkspaceFixture(path: path, contents: source)
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:windows")
        file.loadIfNeeded()
        try await waitForFileTabState { if case .loading = file.content { return false }; return true }
        guard case .unavailable(let message) = file.content else {
            return XCTFail("Unmarked non-UTF8 bytes must require an explicit encoding")
        }
        XCTAssertEqual(message, String(
            localized: "Unknown text encoding. Choose an encoding to reopen.", table: "Workspace"
        ))

        file.reopen(using: .gbk)
        try await file.waitForText()
        XCTAssertEqual(file.text, original)
        XCTAssertEqual(file.fileEncoding, .gbk)
        let originalBytes = await backend.data(at: path)
        XCTAssertEqual(originalBytes, source)

        let converting = Task { await file.save(as: .utf8) }
        try await waitForFileTabState { await backend.writingPath == path }
        await backend.finishWrite()
        await converting.value
        let convertedBytes = await backend.data(at: path)
        XCTAssertEqual(convertedBytes, Data(original.utf8))
        XCTAssertEqual(file.fileEncoding, .utf8)
        XCTAssertFalse(file.isDirty)

        file.reopen(using: nil)
        try await file.waitForText()
        XCTAssertEqual(file.text, original)
        XCTAssertEqual(file.fileEncoding, .utf8)
    }

    func testCodingWordInsideOrdinaryTextDoesNotOverrideUTF8() async throws {
        let path = "/fixture/source.py"
        let contents = "message = \"coding: mbcs\"\n# 合法 UTF-8 内容\n"
        let backend = EditorWorkspaceFixture(path: path, contents: Data(contents.utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:windows")
        try await file.waitForText()
        XCTAssertEqual(file.text, contents)
        XCTAssertEqual(file.fileEncoding, .utf8)
    }

    func testDelimitedDataKeepsUTF8CellsRatherThanApplyingCodingCookies() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (extensionName, separator) in [("CSV", ","), ("tSv", "\t")] {
            for label in ["GBK", "mbcs", "unsupported"] {
                let path = folder.appendingPathComponent("\(label).\(extensionName)")
                let original = "# coding: \(label)\(separator)模型🧪\r\n=1\(separator)é\r"
                let bytes = Data(original.utf8)
                try bytes.write(to: path)
                let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
                do {
                    try await file.waitForText()
                } catch {
                    XCTFail("A UTF-8 data field must not be interpreted as a \(label) declaration: \(error)")
                    continue
                }
                XCTAssertEqual(file.text, original)
                XCTAssertEqual(file.fileEncoding, .utf8)
                XCTAssertEqual(try Data(contentsOf: path), bytes)
                await file.save(as: .utf16LEBOM)
                XCTAssertNil(file.saveError)
                XCTAssertEqual(try Data(contentsOf: path), TextFileEncoding.utf16LEBOM.encoded(original))
                let reopened = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
                try await reopened.waitForText()
                XCTAssertEqual(reopened.fileEncoding, .utf16LEBOM)
                XCTAssertEqual(reopened.text, original)
            }
        }
    }

    func testUTF8AndUTF16ByteOrderMarksRemainByteExact() async throws {
        for encoding in [TextFileEncoding.utf8BOM, .utf16LEBOM, .utf16BEBOM] {
            let path = "/fixture/bom-\(encoding.name).txt"
            let original = "你好 123\n"
            let bytes = try XCTUnwrap(encoding.encoded(original))
            let backend = EditorWorkspaceFixture(path: path, contents: bytes)
            let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
            try await file.waitForText()
            XCTAssertEqual(file.text, original)
            XCTAssertEqual(file.fileEncoding, encoding)
            let actual = await backend.data(at: path)
            XCTAssertEqual(actual, bytes)
        }
    }

    func testBinaryAndLargeTextAreNotTreatedAsEditable() async throws {
        let invalidPath = "/fixture/\(UUID().uuidString).bin"
        let invalid = FileTab(
            path: invalidPath,
            backend: EditorWorkspaceFixture(path: invalidPath, contents: Data([0xFF, 0x00, 0x80])),
            workspaceIdentity: "ssh:fixture"
        )
        invalid.loadIfNeeded()
        try await waitForFileTabState { if case .loading = invalid.content { return false }; return true }
        guard case .unavailable = invalid.content else { return XCTFail("Expected binary placeholder") }
        XCTAssertFalse(invalid.isDirty)

        let largePath = "/fixture/\(UUID().uuidString).txt"
        let large = FileTab(
            path: largePath,
            backend: EditorWorkspaceFixture(path: largePath, contents: Data(repeating: 0x41, count: (32 << 20) + 1)),
            workspaceIdentity: "ssh:fixture"
        )
        large.loadIfNeeded()
        try await waitForFileTabState { if case .loading = large.content { return false }; return true }
        guard case .unavailable = large.content else { return XCTFail("Expected size placeholder") }
        XCTAssertFalse(large.isDirty)
    }

    func testDisconnectDuringSavePreservesBufferAndBaseline() async throws {
        let path = "/fixture/\(UUID().uuidString).txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("baseline".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()
        file.text = "unsaved"
        file.refreshDirtyState()
        let saving = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == path }
        let project = Project(fallbackName: "disconnected", workspaceConfiguration: .standard)
        file.reevaluateWorkspace(in: project)
        await backend.finishWrite()
        await saving.value
        XCTAssertNotNil(file.readOnlyReason)
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, "unsaved")
        await file.save()
        XCTAssertEqual(file.saveError, file.readOnlyReason)
        file.text = "baseline"
        file.refreshDirtyState()
        XCTAssertFalse(file.isDirty)
    }

    func testCleanReloadPublishesOnlyNewBytesAndDropsRenamedRead() async throws {
        let path = "/fixture/\(UUID().uuidString).txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("baseline".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()
        let revision = file.reloadRevision
        await backend.pauseOneRead()
        file.reloadFromDiskIfClean()
        try await waitForFileTabState { await backend.readingPath == path }
        await backend.finishRead(with: Data("新内容😀\r\n".utf8))
        try await waitForFileTabState { file.reloadRevision != revision }
        XCTAssertEqual(file.text, "新内容😀\r\n")
        XCTAssertFalse(file.isDirty)

        await backend.pauseOneRead()
        file.reloadFromDiskIfClean()
        try await waitForFileTabState { await backend.readingPath == path }
        let updatedRevision = file.reloadRevision
        file.updatePath(path + ".renamed")
        await backend.finishRead(with: Data("stale bytes".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(file.text, "新内容😀\r\n")
        XCTAssertEqual(file.reloadRevision, updatedRevision)
    }
}

@MainActor
final class NativeFileTabTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    func testTruncatedLongLineEditSavesAllHiddenBytesAndSurvivesReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".svg")
        let original = String(repeating: "M 123.45,678.90 ", count: 1_500) + "\n"
        try Data(original.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let host = NSHostingView(rootView: SourceTextEditor(
            file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            palette: .theme(dark: false), wrapLines: false, isFocused: false
        ))
        let window = NSWindow(contentRect: NSRect(x: -980, y: -980, width: 800, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()

        let editor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertTrue(editor.truncatesLongLines)
        let range = NSRange(location: 20_000, length: 4)
        let expected = (original as NSString).replacingCharacters(in: range, with: "EDIT")
        editor.insertText("EDIT", replacementRange: range)
        XCTAssertEqual(file.text, expected)
        XCTAssertTrue(file.isDirty)
        await file.save()
        XCTAssertNil(file.saveError)
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: url), Data(expected.utf8))
        XCTAssertEqual(editor.text, expected)
        XCTAssertTrue(editor.truncatesLongLines)

        let reopened = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared,
                               workspaceIdentity: nil)
        try await reopened.waitForText()
        XCTAssertEqual(reopened.text, expected)
    }

    func testFullDisplayLongLineEditUndoAndSavePersistsEveryByte() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".svg")
        let original = String(repeating: "M 123.45,678.90 ", count: 8_000) + "\nend\n"
        try Data(original.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let host = NSHostingView(rootView: SourceTextEditor(
            file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            palette: .theme(dark: false), wrapLines: false,
            longLineDisplayWidth: .showAll, isFocused: false
        ))
        let window = NSWindow(contentRect: NSRect(x: -980, y: -980, width: 800, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertTrue(editor.wrapsLines)
        XCTAssertFalse(editor.truncatesLongLines)
        XCTAssertEqual(editor.frame.width, 24_576, accuracy: 1)
        let range = NSRange(location: 105_000, length: 4)
        let expected = (original as NSString).replacingCharacters(in: range, with: "EDIT")
        editor.insertText("EDIT", replacementRange: range)
        XCTAssertEqual(file.text, expected)
        editor.undoManager?.undo()
        XCTAssertEqual(file.text, original)
        editor.undoManager?.redo()
        XCTAssertEqual(file.text, expected)
        await file.save()
        XCTAssertNil(file.saveError)
        XCTAssertEqual(try Data(contentsOf: url), Data(expected.utf8))
        XCTAssertFalse(file.isDirty)
        let reopened = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared,
                               workspaceIdentity: nil)
        try await reopened.waitForText()
        XCTAssertEqual(reopened.text, expected)
    }

    func testMountedNativeMultipleSelectionsPreserveBytesDirtyStateAndUndo() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        let original = "中文👋 + 中文👋\r\n"
        try Data(original.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let host = NSHostingView(rootView: AnyView(FileViewerView(file: file)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        let nsOriginal = original as NSString
        let first = nsOriginal.range(of: "中文👋")
        let tail = NSRange(location: NSMaxRange(first), length: nsOriginal.length - NSMaxRange(first))
        let second = nsOriginal.range(of: "中文👋", range: tail)
        XCTAssertNotEqual(second.location, NSNotFound)
        editor.selectedRanges = [NSValue(range: first), NSValue(range: second)]
        editor.insertText("🪨", replacementRange: .notFound)
        editor.breakUndoCoalescing()
        let edited = "🪨 + 🪨\r\n"
        XCTAssertEqual(editor.string, edited)
        XCTAssertEqual(file.text, edited)
        XCTAssertTrue(file.isDirty)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(file.text, original)
        XCTAssertFalse(file.isDirty)
        editor.undoManager?.redo()
        XCTAssertEqual(file.text, edited)
        XCTAssertTrue(file.isDirty)
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), Data(edited.utf8))
        XCTAssertFalse(file.isDirty)
    }

    func testNativeFindBarRoutesThroughMountedFileEditor() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try Data("first keyword\nsecond keyword\n".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        let host = NSHostingView(rootView: AnyView(FileViewerView(file: file)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertTrue(editor.usesFindBar)
        XCTAssertTrue(editor.isIncrementalSearchingEnabled)
        XCTAssertTrue(window.makeFirstResponder(editor))
        file.performFindAction(.show)
        try await waitForFileTabState { (scroll as NSTextFinderBarContainer).isFindBarVisible }
        file.performFindAction(.hide)
        try await waitForFileTabState { !(scroll as NSTextFinderBarContainer).isFindBarVisible }
        XCTAssertEqual(editor.string, "first keyword\nsecond keyword\n")
        XCTAssertFalse(file.isDirty)
    }

    func testNativeFindBarKeepsSelectedGutterAndTextRowsPixelAligned() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        let original = String(repeating: "keyword visible 中文\n", count: 35)
        try Data(original.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        let host = NSHostingView(rootView: AnyView(FileViewerView(file: file)))
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let gutter = try XCTUnwrap(editor.gutterView)
        let highlight = NSColor(srgbRed: 0.9, green: 0.12, blue: 0.15, alpha: 1)
        editor.backgroundColor = .black
        scroll.backgroundColor = .black
        gutter.backgroundColor = .black
        editor.highlightSelectedLine = true
        editor.selectedLineHighlightColor = highlight
        gutter.selectedLineHighlightColor = highlight
        editor.textSelection = NSRange(location: 0, length: 0)

        func verify(_ stage: String) throws {
            host.layoutSubtreeIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            editor.needsDisplay = true
            gutter.needsDisplay = true
            window.displayIfNeeded()
            let image = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: image)
            let scale = CGFloat(image.pixelsWide) / scroll.bounds.width
            func tintedY(at x: Int) -> [Int] {
                (0..<image.pixelsHigh).filter { y in
                    guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    else { return false }
                    return c.redComponent - c.greenComponent > 0.45
                        && c.redComponent - c.blueComponent > 0.45
                }
            }
            let gutter = tintedY(at: min(image.pixelsWide - 1, Int(2 * scale)))
            let text = tintedY(at: max(0, Int((scroll.bounds.width - 80) * scale)))
            XCTAssertGreaterThan(gutter.count, 8, "\(stage): gutter must draw the caret row")
            XCTAssertGreaterThan(text.count, 8, "\(stage): editor must draw the caret row")
            if let firstGutter = gutter.first, let firstText = text.first {
                XCTAssertLessThanOrEqual(abs(firstGutter - firstText), Int(2 * scale),
                    "\(stage): native gutter must align with the text after find-bar layout")
            }
        }

        try verify("before find")
        XCTAssertTrue(window.makeFirstResponder(editor))
        file.performFindAction(.show)
        try await waitForFileTabState {
            scroll.layoutSubtreeIfNeeded()
            return (scroll as NSTextFinderBarContainer).isFindBarVisible
                && scroll.contentView.contentInsets.top > 0
        }
        let findHeight = try XCTUnwrap(scroll.findBarView).bounds.height
        XCTAssertEqual(scroll.contentView.contentInsets.top, findHeight, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, -findHeight, accuracy: 1)
        try verify("find bar shown")
        // Switching directly between Find and Replace changes overlay height
        // without hiding the find bar or changing the current document.
        file.performFindAction(.replace)
        try await waitForFileTabState {
            scroll.layoutSubtreeIfNeeded()
            return (scroll.findBarView?.bounds.height ?? 0) > findHeight
        }
        let expandedHeight = try XCTUnwrap(scroll.findBarView).bounds.height
        XCTAssertEqual(scroll.contentView.bounds.origin.y, -expandedHeight, accuracy: 1)
        try verify("replace expanded in place")
        file.performFindAction(.show)
        scroll.layoutSubtreeIfNeeded()
        let heightAfterShow = try XCTUnwrap(scroll.findBarView).bounds.height
        XCTAssertTrue((scroll as NSTextFinderBarContainer).isFindBarVisible)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, -heightAfterShow, accuracy: 1)
        try verify("find command during replace")
        file.performFindAction(.hide)
        try await waitForFileTabState {
            scroll.layoutSubtreeIfNeeded()
            return !(scroll as NSTextFinderBarContainer).isFindBarVisible
                && scroll.contentView.contentInsets.top == 0
        }
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        try verify("find bar hidden")

        // Repeat with a previously scrolled document: neither opening nor
        // dismissing Find may jump the reader to a different text row.
        let middleY: CGFloat = 80
        let lineUnits = ("keyword visible 中文\n" as NSString).length
        editor.textSelection = NSRange(location: lineUnits * 10, length: 0)
        XCTAssertTrue(window.makeFirstResponder(editor))
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: middleY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try verify("middle before find")
        file.performFindAction(.show)
        try await waitForFileTabState {
            scroll.layoutSubtreeIfNeeded()
            return (scroll as NSTextFinderBarContainer).isFindBarVisible
                && scroll.contentView.contentInsets.top > 0
        }
        XCTAssertEqual(scroll.contentView.bounds.origin.y, middleY - findHeight, accuracy: 1)
        XCTAssertEqual(file.editorState.scrollY ?? .nan, Double(middleY), accuracy: 1,
            "Find must not alter the scroll position persisted for session restoration")
        try verify("middle find shown")
        window.setContentSize(NSSize(width: 620, height: 380))
        host.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, middleY - findHeight, accuracy: 1,
            "Resizing a window while Find is open must keep the same reading position")
        try verify("middle find after resize")
        file.performFindAction(.hide)
        try await waitForFileTabState {
            scroll.layoutSubtreeIfNeeded()
            return !(scroll as NSTextFinderBarContainer).isFindBarVisible
                && scroll.contentView.contentInsets.top == 0
        }
        XCTAssertEqual(scroll.contentView.bounds.origin.y, middleY, accuracy: 1)
        XCTAssertEqual(file.editorState.scrollY ?? .nan, Double(middleY), accuracy: 1)
        try verify("middle find hidden")

        XCTAssertTrue(window.makeFirstResponder(editor))
        file.performFindAction(.replace)
        try await waitForFileTabState {
            scroll.layoutSubtreeIfNeeded()
            return (scroll as NSTextFinderBarContainer).isFindBarVisible
                && scroll.contentView.contentInsets.top > 0
        }
        let replaceHeight = try XCTUnwrap(scroll.findBarView).bounds.height
        XCTAssertGreaterThanOrEqual(replaceHeight, findHeight)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, middleY - replaceHeight, accuracy: 1)
        try verify("find replace shown")
        file.performFindAction(.hide)
        try await waitForFileTabState {
            scroll.layoutSubtreeIfNeeded()
            return !(scroll as NSTextFinderBarContainer).isFindBarVisible
                && scroll.contentView.contentInsets.top == 0
        }
        XCTAssertEqual(scroll.contentView.bounds.origin.y, middleY, accuracy: 1)
        try verify("find replace hidden")

        XCTAssertTrue(window.makeFirstResponder(editor))
        file.performFindAction(.show)
        try await waitForFileTabState {
            scroll.layoutSubtreeIfNeeded()
            return (scroll as NSTextFinderBarContainer).isFindBarVisible
                && scroll.contentView.contentInsets.top > 0
        }
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 32))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(file.editorState.scrollY ?? .nan, Double(32 + findHeight), accuracy: 1)
        try verify("user scrolls while find shown")
        let offsetBeforeDockMove = scroll.contentView.bounds.origin
        host.rootView = AnyView(Color.clear)
        try await waitForFileTabState {
            host.layoutSubtreeIfNeeded()
            return file.editorView == nil
        }
        host.rootView = AnyView(FileViewerView(file: file))
        try await waitForFileTabState {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) === editor
        }
        scroll.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, offsetBeforeDockMove.y, accuracy: 1,
            "Dock reattachment with Find active must keep the reading position")
        XCTAssertTrue((scroll as NSTextFinderBarContainer).isFindBarVisible)
        // Remounting reapplies the user's theme, which replaces the synthetic
        // bright-red diagnostic palette used by this test before detachment.
        XCTAssertEqual(editor.backgroundColor, gutter.backgroundColor)
        XCTAssertEqual(editor.selectedLineHighlightColor, gutter.selectedLineHighlightColor)
        editor.backgroundColor = .black
        gutter.backgroundColor = .black
        editor.selectedLineHighlightColor = highlight
        gutter.selectedLineHighlightColor = highlight
        try verify("find after dock reattachment")
        file.performFindAction(.hide)
        try await waitForFileTabState {
            scroll.layoutSubtreeIfNeeded()
            return !(scroll as NSTextFinderBarContainer).isFindBarVisible
                && scroll.contentView.contentInsets.top == 0
        }
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 32 + findHeight, accuracy: 1,
            "Find dismissal must preserve user scrolling performed while the bar was open")
        XCTAssertEqual(file.editorState.scrollY ?? .nan, Double(32 + findHeight), accuracy: 1)
        try verify("find hidden after user scroll")
        XCTAssertEqual(try Data(contentsOf: path), Data(original.utf8))
        XCTAssertFalse(file.isDirty)
    }

    func testHundredThousandLineDirtyStateDoesNotRescanOnEachNativeKeystroke() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift")
        defer { try? FileManager.default.removeItem(at: path) }
        let original = String(repeating: "let word = \"中文 👋\"\n", count: 100_000)
        try original.write(to: path, atomically: true, encoding: .utf8)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let host = NSHostingView(rootView: AnyView(FileViewerView(file: file)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        var costs: [Double] = []
        for _ in 0..<4 {
            let start = CFAbsoluteTimeGetCurrent()
            editor.insertText("X", replacementRange: NSRange(location: 0, length: 0))
            costs.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            editor.insertText("", replacementRange: NSRange(location: 0, length: 1))
        }
        costs.sort()
        print("P2_NATIVE_DIRTY_HOT_INPUT median_ms=\(costs[2]) max_ms=\(costs[3])")
        XCTAssertLessThan(costs[2], 32, "One inserted code unit must not rebuild the whole UTF-16 count map")
        XCTAssertEqual(editor.string, original)
        XCTAssertFalse(file.isDirty)
    }

    func testOffscreenNativeAppendAndPreviewStayBoundedAtTextCapacity() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: path) }
        let content = "head 中文👋\r\n" + String(repeating: "q", count: (8 << 20) - 1_000)
        let original = Data(content.utf8)
        XCTAssertLessThan(original.count, 8 << 20)
        try original.write(to: path)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        XCTAssertNil(file.editorCoordinator)
        let storage = file.nativeTextStorage
        let atStart = file.previewExcerpt(aroundUTF16: nil)
        XCTAssertLessThanOrEqual(atStart.text.utf16.count, 7_000)
        XCTAssertTrue(atStart.text.hasPrefix("head 中文👋\r\n"))
        let inMiddle = file.previewExcerpt(aroundUTF16: 1_000_000)
        XCTAssertLessThanOrEqual(inMiddle.text.utf16.count, 7_000)
        XCTAssertTrue(inMiddle.startsInsideLine)
        XCTAssertEqual(file.lineEndingForAppend().newline, "\r\n")
        XCTAssertEqual(file.lineEndingForAppend().separator, "\r\n")
        file.appendText("\r\nignored\r\n")
        XCTAssertTrue(file.nativeTextStorage === storage)
        XCTAssertTrue(file.isDirty)
        await file.save()
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: path), original + Data("\r\nignored\r\n".utf8))
    }

    func testNativeDocumentHasOneFileTabOwnerBeforeMountAndAfterClose() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let original = "中文👋 first\r\nsecond\n"
        try Data(original.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let storage = file.nativeTextStorage
        XCTAssertTrue(file.nativeContentStorage.textStorage === storage)
        XCTAssertNil(file.editorCoordinator)
        XCTAssertEqual(storage.string, original)

        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0),
                                  with: "offline addition\n")
        try await waitForFileTabState { file.isDirty }
        XCTAssertEqual(file.text, original + "offline addition\n")
        let host = NSHostingView(rootView: AnyView(FileViewerView(file: file)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertTrue(editor.textStorage === storage)
        XCTAssertTrue(editor.nativeContentManager === file.nativeContentStorage)
        editor.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(file.text.hasPrefix("X"))
        XCTAssertTrue(storage.string.hasPrefix("X"))

        host.rootView = AnyView(Color.clear)
        try await waitForFileTabState { host.layoutSubtreeIfNeeded(); return file.editorView == nil }
        XCTAssertTrue(file.nativeTextStorage === storage)
        host.rootView = AnyView(FileViewerView(file: file))
        try await waitForFileTabState {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) === editor
        }
        XCTAssertTrue(editor.textStorage === file.nativeTextStorage)
        file.retireNativeEditor()
        XCTAssertEqual(storage.length, 0, "Closing must release the original native buffer")
        XCTAssertFalse(editor.undoManager?.canUndo ?? true)
    }

    func testDetachedEditorAppendKeepsSameNativeDocumentAndUndo() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let original = "first 中文👋\n"
        try Data(original.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let host = NSHostingView(rootView: AnyView(FileViewerView(file: file)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        editor.insertText("// prior\n", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        XCTAssertTrue(file.isDirty)

        host.rootView = AnyView(Color.clear)
        try await waitForFileTabState { host.layoutSubtreeIfNeeded(); return file.editorView == nil }
        file.appendText("// appended\n")
        let expected = "// prior\n" + original + "// appended\n"
        XCTAssertEqual(file.text, expected)
        XCTAssertEqual(editor.text, expected, "An unmounted retained editor is still the document owner")
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), Data(expected.utf8))
        XCTAssertFalse(file.isDirty)

        host.rootView = AnyView(FileViewerView(file: file))
        try await waitForFileTabState {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) === editor
        }
        editor.undoManager?.undo()
        XCTAssertEqual(editor.text, "// prior\n" + original)
        XCTAssertEqual(file.text, editor.text)
        XCTAssertTrue(file.isDirty)
    }

    func testNativeReorderAndInFlightSaveKeepExactDirtyBytes() async throws {
        let path = "/fixture/\(UUID().uuidString)-permutation.txt"
        let original = "abc 中文👋\r\n"
        let backend = EditorWorkspaceFixture(path: path, contents: Data(original.utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true

        let host = NSHostingView(rootView: FileViewerView(file: file))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        editor.insertText("ba", replacementRange: NSRange(location: 0, length: 2))
        editor.breakUndoCoalescing()
        XCTAssertEqual(file.text, "bac 中文👋\r\n")
        XCTAssertTrue(file.isDirty, "Equal code-unit frequencies do not prove equal bytes")

        let saving = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == path }
        editor.insertText("ab", replacementRange: NSRange(location: 0, length: 2))
        editor.breakUndoCoalescing()
        XCTAssertEqual(Data(file.text.utf8), Data(original.utf8))
        XCTAssertFalse(file.isDirty, "Exact inverse edit returns to the original baseline")
        await backend.finishWrite()
        await saving.value
        XCTAssertTrue(file.isDirty, "An in-flight write establishes a new baseline")
        let stale = await backend.data(at: path)
        XCTAssertEqual(stale, Data("bac 中文👋\r\n".utf8))

        let secondSave = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath == path }
        await backend.finishWrite()
        await secondSave.value
        XCTAssertFalse(file.isDirty)
        let final = await backend.data(at: path)
        XCTAssertEqual(final, Data(original.utf8))
    }

    func testCanonicalEquivalentNativeReplacementUndoAndSavePreserveBytes() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let composed = "café 中文👋\r\n"
        let decomposed = "cafe\u{301} 中文👋\r\n"
        try Data(composed.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let host = NSHostingView(rootView: FileViewerView(file: file))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        editor.insertText(decomposed, replacementRange: NSRange(location: 0, length: composed.utf16.count))
        editor.breakUndoCoalescing()
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(decomposed.utf8))
        XCTAssertEqual(Data(file.text.utf8), Data(decomposed.utf8))
        XCTAssertTrue(file.isDirty)
        editor.undoManager?.undo()
        XCTAssertEqual(Data(file.text.utf8), Data(composed.utf8))
        XCTAssertFalse(file.isDirty)
        editor.undoManager?.redo()
        XCTAssertTrue(file.isDirty)
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), Data(decomposed.utf8))
        XCTAssertFalse(file.isDirty)
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: decomposed.utf16.count))
        editor.setMarkedText("中文👋", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("中文👋", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(Data(file.text.utf8), Data("中文👋".utf8))
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), Data("中文👋".utf8))
    }

    func testHundredThousandLineSwiftFileCanLoadAbovePreviousCapacity() async throws {
        let source = (0..<100_000).map { row in
            "let value_\(row) = \(row) // 中文 👋 edit undo find verify\n"
        }.joined()
        let data = Data(source.utf8)
        XCTAssertGreaterThan(data.count, 5 << 20)
        XCTAssertLessThan(data.count, 8 << 20)

        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift")
        try data.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        XCTAssertEqual(Data(file.text.utf8), data)
        file.autoSaveSuspendedForClose = true

        let host = NSHostingView(rootView: FileViewerView(file: file))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        let deadline = Date().addingTimeInterval(10)
        while mountedEditor(in: host) == nil, Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try XCTUnwrap(mountedEditor(in: host))
        for position in [0, source.utf16.count / 2, source.utf16.count - 1, 0] {
            editor.scrollRangeToVisible(NSRange(location: position, length: 0))
            editor.layoutSubtreeIfNeeded()
            let visible = try XCTUnwrap(editor.nativeLayoutManager.textViewportLayoutController.viewportRange)
            let range = NSRange(visible, in: editor.nativeContentManager)
            XCTAssertLessThanOrEqual(range.location, position)
            XCTAssertGreaterThanOrEqual(NSMaxRange(range), position)
        }

        let appended = "let appended = \"中文 👋\"\n"
        editor.insertText(appended, replacementRange: NSRange(location: source.utf16.count, length: 0))
        editor.breakUndoCoalescing()
        XCTAssertEqual(Data(file.text.utf8), data + Data(appended.utf8))
        XCTAssertTrue(file.isDirty)
        editor.undoManager?.undo()
        XCTAssertEqual(Data(file.text.utf8), data)
        XCTAssertFalse(file.isDirty)
        editor.undoManager?.redo()
        XCTAssertEqual(Data(file.text.utf8), data + Data(appended.utf8))
        XCTAssertTrue(file.isDirty)
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), data + Data(appended.utf8))
        XCTAssertFalse(file.isDirty)
    }

    func testSixtyFourMiBFileTabRemainsRejectedAfterIndependentCapacityTrial() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-64m-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("rejected.swift")
        let original = Data(repeating: 0x41, count: 64 << 20)
        try original.write(to: path)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        do {
            try await file.waitForText()
            XCTFail("64 MiB must not be opened as a partial writable file")
        } catch {}
        guard case .unavailable(let reason) = file.content else {
            return XCTFail("Expected a capacity error")
        }
        XCTAssertEqual(reason, String(localized: "File is too large to open", table: "Workspace"))
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertFalse(file.isDirty)
    }

    func testThirtyTwoMiBFileTabActuallyEditsAndPublishesExactLocalBytes() async throws {
        let limit = 32 << 20
        let settings = AppSettings.shared
        let previousWrap = settings.wrapLines
        settings.wrapLines = false
        defer { settings.wrapLines = previousWrap }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-filetab-32m-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("unicode.swift")
        let row = "let row = \"中文👋\" // "
            + String(repeating: "abc_DEF01", count: 32) + "\r\n"
        // Leave room for a real save, so the new bytes remain reopenable.
        let baselineBytes = limit - 64
        let prefix = String(repeating: row, count: baselineBytes / row.utf8.count)
        let source = prefix + String(repeating: "x", count: baselineBytes - prefix.utf8.count)
        XCTAssertEqual(source.utf8.count, baselineBytes)
        let originalBytes = Data(source.utf8)
        try originalBytes.write(to: path)

        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        let readStarted = CFAbsoluteTimeGetCurrent()
        try await file.waitForText()
        let loadMs = (CFAbsoluteTimeGetCurrent() - readStarted) * 1_000
        XCTAssertEqual(Data(file.text.utf8), originalBytes)
        file.autoSaveSuspendedForClose = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file, isFocused: false))
        let mountStarted = CFAbsoluteTimeGetCurrent()
        window.contentView = host
        window.orderFront(nil)
        let deadline = Date().addingTimeInterval(20)
        while mountedEditor(in: host) == nil, Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try XCTUnwrap(mountedEditor(in: host))
        let mountedMs = (CFAbsoluteTimeGetCurrent() - mountStarted) * 1_000
        XCTAssertEqual(editor.textStorage?.length, source.utf16.count)
        print("P2_FILETAB_CAPACITY bytes=\(limit) load_ms=\(loadMs) mount_ms=\(mountedMs)")

        let length = try XCTUnwrap(editor.textStorage).length
        let navigationStarted = CFAbsoluteTimeGetCurrent()
        for visit in 0..<17 {
            let position = length * ((visit * 7) % 17) / 17
            editor.scrollRangeToVisible(NSRange(location: position, length: 0))
            editor.layoutSubtreeIfNeeded()
            let visible = try XCTUnwrap(editor.nativeLayoutManager.textViewportLayoutController.viewportRange)
            let range = NSRange(visible, in: editor.nativeContentManager)
            XCTAssertLessThanOrEqual(range.location, position)
            XCTAssertGreaterThanOrEqual(NSMaxRange(range), position)
        }
        print("P2_FILETAB_32M_PHASE navigation17_ms=\((CFAbsoluteTimeGetCurrent() - navigationStarted) * 1_000)")
        let findStarted = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(editor.usesFindBar)
        XCTAssertTrue(window.makeFirstResponder(editor))
        file.performFindAction(.show)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        try await waitForFileTabState {
            (scroll as NSTextFinderBarContainer).isFindBarVisible
        }
        let findHeight = scroll.findBarView?.bounds.height ?? 0
        file.performFindAction(.replace)
        try await waitForFileTabState {
            (scroll as NSTextFinderBarContainer).isFindBarVisible
        }
        XCTAssertGreaterThanOrEqual(scroll.findBarView?.bounds.height ?? 0, findHeight)
        file.performFindAction(.hide)
        try await waitForFileTabState {
            !(scroll as NSTextFinderBarContainer).isFindBarVisible
        }
        XCTAssertFalse(file.isDirty)
        print("P2_FILETAB_32M_PHASE find_ms=\((CFAbsoluteTimeGetCurrent() - findStarted) * 1_000)")
        let multiStarted = CFAbsoluteTimeGetCurrent()

        // Two disjoint real selections must keep one undo transaction.
        let originalText = source as NSString
        let first = originalText.range(of: "中文👋")
        let second = originalText.range(of: "中文👋", range: NSRange(
            location: NSMaxRange(first), length: originalText.length - NSMaxRange(first)
        ))
        XCTAssertNotEqual(first.location, NSNotFound)
        XCTAssertNotEqual(second.location, NSNotFound)
        editor.selectedRanges = [NSValue(range: first), NSValue(range: second)]
        editor.insertText("🪨", replacementRange: .notFound)
        editor.breakUndoCoalescing()
        XCTAssertTrue(file.isDirty)
        editor.undoManager?.undo()
        XCTAssertFalse(file.isDirty)
        let multiMs = (CFAbsoluteTimeGetCurrent() - multiStarted) * 1_000
        print("P2_FILETAB_32M_PHASE multi_ms=\(multiMs)")
        XCTAssertEqual(file.text, source)
        XCTAssertLessThan(multiMs, 3_000, "Multi-cursor undo must not rebuild the whole file on the main actor")
        let imeStarted = CFAbsoluteTimeGetCurrent()

        // Real marked-text composition must not copy or corrupt a large buffer.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: .notFound)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: .notFound)
        editor.insertText("你🐈", replacementRange: .notFound)
        editor.breakUndoCoalescing()
        XCTAssertTrue(file.isDirty)
        editor.undoManager?.undo()
        XCTAssertFalse(file.isDirty)
        let imeMs = (CFAbsoluteTimeGetCurrent() - imeStarted) * 1_000
        print("P2_FILETAB_32M_PHASE ime_ms=\(imeMs)")
        XCTAssertEqual(file.text, source)
        XCTAssertLessThan(imeMs, 3_000, "IME undo must not rebuild the whole file on the main actor")

        let wrapStarted = CFAbsoluteTimeGetCurrent()
        editor.configureWrapping(true, viewportWidth: scroll.contentView.bounds.width)
        editor.configureWrapping(false, viewportWidth: scroll.contentView.bounds.width)
        let wrapMs = (CFAbsoluteTimeGetCurrent() - wrapStarted) * 1_000
        print("P2_FILETAB_32M_PHASE wrap_roundtrip_ms=\(wrapMs)")
        XCTAssertEqual(editor.string, source)
        XCTAssertFalse(file.isDirty)
        XCTAssertLessThan(wrapMs, 1_500, "Toggling wrap must not reshape every cached line again")
        let originalAppearance = window.appearance
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(editor.textStorage === file.nativeTextStorage)
            XCTAssertFalse(file.isDirty)
        }
        window.appearance = originalAppearance

        // Each distant edit starts on a real logical row boundary, never in
        // the middle of a UTF-16 surrogate pair. No full-text assertion per key.
        let rowUnits = row.utf16.count
        let rowCount = prefix.utf16.count / rowUnits
        let distantStarted = CFAbsoluteTimeGetCurrent()
        for visit in 0..<17 {
            let rowIndex = rowCount * ((visit * 7) % 17) / 17
            let offset = rowIndex * rowUnits
            editor.insertText("Q", replacementRange: NSRange(location: offset, length: 0))
            XCTAssertTrue(file.isDirty)
            editor.insertText("", replacementRange: NSRange(location: offset, length: 1))
            XCTAssertFalse(file.isDirty)
        }
        print("P2_FILETAB_32M_PHASE distant17_edits_ms=\((CFAbsoluteTimeGetCurrent() - distantStarted) * 1_000)")
        XCTAssertEqual(Data(file.text.utf8), originalBytes)

        for (label, offset) in [("head", 0), ("tail", source.utf16.count)] {
            let insertedAt = CFAbsoluteTimeGetCurrent()
            editor.insertText("Q", replacementRange: NSRange(location: offset, length: 0))
            let insertedMs = (CFAbsoluteTimeGetCurrent() - insertedAt) * 1_000
            let deletedAt = CFAbsoluteTimeGetCurrent()
            editor.insertText("", replacementRange: NSRange(location: offset, length: 1))
            let deletedMs = (CFAbsoluteTimeGetCurrent() - deletedAt) * 1_000
            print("P2_FILETAB_32M_NATIVE_EDIT position=\(label) insert_ms=\(insertedMs) delete_ms=\(deletedMs)")
            XCTAssertLessThan(deletedMs, 200, "Deleting the last typed character must not encode 32 MiB on the main actor")
            XCTAssertEqual(file.text, source)
        }
        let before = "前缀👋\r\n"
        editor.insertText(before, replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        let after = "\r\n末尾中文👋"
        editor.insertText(after, replacementRange: NSRange(
            location: try XCTUnwrap(editor.textStorage).length, length: 0
        ))
        editor.breakUndoCoalescing()
        XCTAssertTrue(file.isDirty)
        editor.undoManager?.undo()
        editor.undoManager?.redo()
        XCTAssertTrue(file.isDirty)

        let expected = Data((before + source + after).utf8)
        XCTAssertLessThanOrEqual(expected.count, limit)
        XCTAssertEqual(Data(file.text.utf8), expected)
        let saveStarted = CFAbsoluteTimeGetCurrent()
        await file.save()
        let saveMs = (CFAbsoluteTimeGetCurrent() - saveStarted) * 1_000
        print("P2_FILETAB_CAPACITY_SAVE bytes=\(expected.count) save_ms=\(saveMs)")
        XCTAssertNil(file.saveError)
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: path), expected)

        // Closing releases the single native owner even if an AppKit host
        // still retains its old view until the next run loop.
        let originalStorage = file.nativeTextStorage
        file.retireNativeEditor()
        XCTAssertEqual(originalStorage.length, 0)
        XCTAssertNil(file.editorCoordinator)
        XCTAssertNil(file.preparedLineWidths)
        let reopened = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                               workspaceIdentity: nil)
        try await reopened.waitForText()
        XCTAssertEqual(Data(reopened.text.utf8), expected)
    }

    func testNativeReadOnlyRejectsAXValueAndSelectionReplacement() {
        let editor = FocusReportingTextView()
        editor.text = "original"
        editor.isEditable = false
        editor.textSelection = NSRange(location: 0, length: 8)
        XCTAssertFalse(editor.isAccessibilitySelectorAllowed(#selector(editor.setAccessibilityValue(_:))))
        editor.setAccessibilityValue("overwritten")
        XCTAssertEqual(editor.text, "original")
        editor.setAccessibilitySelectedText("overwritten selection")
        XCTAssertEqual(editor.text, "original")
        XCTAssertEqual(editor.accessibilityValue() as? String, "original")
    }

    func testWritableNativeAXValueReplacementUpdatesDirtyStateAndDisk() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try Data("original\n".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let host = NSHostingView(rootView: AnyView(FileViewerView(file: file)))
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertTrue(editor.isEditable)
        editor.setAccessibilityValue("updated via AX\n")
        XCTAssertEqual(editor.string, "updated via AX\n")
        XCTAssertEqual(file.text, "updated via AX\n",
                       "Native AX input must update the file model before Save")
        XCTAssertTrue(file.isDirty)
        await file.save()
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "updated via AX\n")
        XCTAssertFalse(file.isDirty)
    }

    func testMountedEditorDisconnectReconnectKeepsNativeBufferAndUndo() async throws {
        let sshHost = "editor-" + UUID().uuidString
        let project = Project(fallbackName: "native read-only", workspaceConfiguration: .standard)
        project.sshHost = sshHost
        defer { project.terminateAll() }
        SSHHostWorkspaces.setConnected(true, for: sshHost)
        let backend = EditorWorkspaceFixture(path: "/fixture/file.txt", contents: Data("original".utf8))
        let file = FileTab(path: "/fixture/file.txt", backend: backend,
                           workspaceIdentity: "ssh:" + sshHost)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        file.text = "unsaved"
        file.refreshDirtyState()
        project.append(PaneTab(content: .file(file)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = host
        window.orderFront(nil)
        try await waitForFileTabState { host.layoutSubtreeIfNeeded(); return self.mountedEditor(in: host) != nil }
        let editor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertTrue(editor.isEditable)

        SSHHostWorkspaces.setConnected(false, for: "another-" + UUID().uuidString)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(file.readOnlyReason)
        XCTAssertTrue(editor.isEditable)

        SSHHostWorkspaces.setConnected(false, for: sshHost)
        XCTAssertNotNil(file.readOnlyReason)
        try await waitForFileTabState { host.layoutSubtreeIfNeeded(); return !editor.isEditable }
        editor.setAccessibilityValue("must not replace")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        editor.keyDown(with: event)
        XCTAssertEqual(editor.text, "unsaved")
        XCTAssertEqual(file.text, "unsaved")
        XCTAssertTrue(file.isDirty)

        SSHHostWorkspaces.setConnected(true, for: sshHost)
        XCTAssertNil(file.readOnlyReason)
        try await waitForFileTabState { host.layoutSubtreeIfNeeded(); return editor.isEditable }
        XCTAssertTrue(mountedEditor(in: host) === editor)
        editor.insertText("new ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(file.text, "new unsaved")
        editor.breakUndoCoalescing()
        editor.undoManager?.undo()
        XCTAssertEqual(file.text, "unsaved")
        XCTAssertTrue(file.isDirty)
    }

    func testWindowFocusRefreshesOnlyItsMountedFile() async throws {
        let pathA = "/fixture/\(UUID().uuidString)-A.txt"
        let pathB = "/fixture/\(UUID().uuidString)-B.txt"
        let backendA = EditorWorkspaceFixture(path: pathA, contents: Data("original A".utf8))
        let backendB = EditorWorkspaceFixture(path: pathB, contents: Data("original B".utf8))
        let fileA = FileTab(path: pathA, backend: backendA, workspaceIdentity: nil)
        let fileB = FileTab(path: pathB, backend: backendB, workspaceIdentity: nil)
        let windowA = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let windowB = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                               styleMask: [.titled], backing: .buffered, defer: false)
        windowA.isReleasedWhenClosed = false
        windowB.isReleasedWhenClosed = false
        defer { windowA.close(); windowB.close() }
        let hostA = NSHostingView(rootView: FileViewerView(file: fileA))
        let hostB = NSHostingView(rootView: FileViewerView(file: fileB))
        windowA.contentView = hostA
        windowB.contentView = hostB
        windowA.orderFront(nil)
        windowB.orderFront(nil)
        try await fileA.waitForText()
        try await fileB.waitForText()
        try await waitForFileTabState {
            hostA.layoutSubtreeIfNeeded()
            hostB.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: hostA) != nil && self.mountedEditor(in: hostB) != nil
        }
        let beforeB = await backendB.readCount
        await backendA.replace(path: pathA, with: Data("external A".utf8))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: windowA)
        try await waitForFileTabState { fileA.text == "external A" }
        try await Task.sleep(for: .milliseconds(40))
        let afterB = await backendB.readCount
        XCTAssertEqual(afterB, beforeB, "Switching to A must not re-read the mounted file in window B")
        XCTAssertEqual(fileB.text, "original B")
    }

    func testImagePreviewReloadIsScopedToItsWindow() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let path = "/fixture/\(UUID().uuidString).png"
        let backend = EditorWorkspaceFixture(path: path, contents: png)
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = host
        window.orderFront(nil)
        try await waitForFileTabState {
            host.layoutSubtreeIfNeeded()
            if case .image = file.content { return true }
            return false
        }
        let before = await backend.readCount
        let revision = file.reloadRevision
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await waitForFileTabState { await backend.pendingReadCount == 1 }
        await backend.finishRead()
        try await Task.sleep(for: .milliseconds(60))
        if case .image = file.content {} else { XCTFail("Transient read failure must keep preview") }
        XCTAssertNotNil(file.reloadError)
        XCTAssertEqual(file.reloadRevision, revision)
        await backend.replace(path: path, with: Data("external text".utf8))
        let unrelated = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        defer { unrelated.close() }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: unrelated)
        try await Task.sleep(for: .milliseconds(30))
        let afterUnrelated = await backend.readCount
        XCTAssertEqual(afterUnrelated, before + 1, "Other windows must not reload this image")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await waitForFileTabState { file.text == "external text" }
        let afterOwn = await backend.readCount
        XCTAssertEqual(afterOwn, before + 2)
        XCTAssertNil(file.reloadError)
    }

    func testNativeEditorSurvivesTransientRefreshFailureWithUndo() async throws {
        let path = "/fixture/\(UUID().uuidString)-native.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = host
        window.orderFront(nil)
        try await waitForFileTabState {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) != nil
        }
        let editor = try XCTUnwrap(mountedEditor(in: host))
        try await Task.sleep(for: .milliseconds(50))
        let revision = file.reloadRevision
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await waitForFileTabState { await backend.pendingReadCount == 1 }
        await backend.finishRead()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(file.reloadRevision, revision)
        XCTAssertTrue(mountedEditor(in: host) === editor)
        XCTAssertEqual(editor.text, "original")
        XCTAssertNotNil(file.reloadError)
        guard !editor.isEditable else {
            return XCTFail("A stale cached editor must stay read-only until a successful refresh")
        }
        editor.setAccessibilityValue("attempt overwrite")
        XCTAssertEqual(file.text, "original")
        file.refreshWhenSelected()
        try await file.waitForText()
        try await waitForFileTabState { host.layoutSubtreeIfNeeded(); return file.reloadError == nil && editor.isEditable }
        XCTAssertTrue(mountedEditor(in: host) === editor)
        editor.insertText("hello ", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        XCTAssertEqual(file.text, "hello original")
        editor.undoManager?.undo()
        XCTAssertEqual(file.text, "original")
        XCTAssertFalse(file.isDirty)
        file.autoSaveSuspendedForClose = true
    }

    func testWindowActivationDoesNotRestartInFlightInitialRead() async throws {
        let path = "/fixture/initial.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("initial".utf8))
        await backend.pauseOneRead()
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        let host = NSHostingView(rootView: FileViewerView(file: file))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await waitForFileTabState { await backend.pendingReadCount == 1 }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await Task.sleep(for: .milliseconds(80))
        let readsDuringLoad = await backend.readCount
        XCTAssertEqual(readsDuringLoad, 1, "Window focus must reuse the pending initial read")
        await backend.finishRead(with: Data("initial".utf8))
        try await file.waitForText()
        XCTAssertEqual(file.text, "initial")
    }

    func testFilesPanelABATabSwitchKeepsEachNativeEditorAndCorrectSaveTarget() async throws {
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(snapshots)
            TerminalHistoryStore.save(histories)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aPath = root.appendingPathComponent("A.swift")
        let bPath = root.appendingPathComponent("B.swift")
        try "let fileA = \"only A\"\n".write(to: aPath, atomically: true, encoding: .utf8)
        try "let fileB = \"only B\"\n".write(to: bPath, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        func panel(for tab: PaneTab) -> some View {
            PanelContentView(tab: tab, isFocused: false,
                             onFocused: {}, onNewBrowserTab: { _ in }, onNewFileTab: { _ in })
                .id(tab.id)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // The App's file selection model stays real; the host only mounts the
        // native pane under test, not an entire user-facing workspace.
        manager.openFile(aPath.path)
        let host = NSHostingView(rootView: panel(for: try XCTUnwrap(project.selectedTab)))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let a = try XCTUnwrap(project.tabs.compactMap {
            if case .file(let file) = $0.content, file.path == aPath.path { return file }
            return nil
        }.first)
        try await waitForFileTabState {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host)?.text == a.text
                && a.editorView?.window === window
        }
        let aEditor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertEqual(aEditor.text, "let fileA = \"only A\"\n")

        manager.openFile(bPath.path)
        host.rootView = panel(for: try XCTUnwrap(project.selectedTab))
        let b = try XCTUnwrap(project.tabs.compactMap {
            if case .file(let file) = $0.content, file.path == bPath.path { return file }
            return nil
        }.first)
        try await waitForFileTabState {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host)?.text == b.text
                && b.editorView?.window === window
        }
        let bEditor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertFalse(aEditor === bEditor)
        XCTAssertEqual(bEditor.text, "let fileB = \"only B\"\n")

        manager.openFile(aPath.path)
        host.rootView = panel(for: try XCTUnwrap(project.selectedTab))
        try await waitForFileTabState {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) === aEditor
                && a.editorView?.window === window
        }
        XCTAssertEqual(aEditor.text, "let fileA = \"only A\"\n")
        XCTAssertEqual(a.text, aEditor.text)

        // Editing after switching back must never modify B's model or bytes.
        aEditor.insertText("// edited A\n", replacementRange: NSRange(location: 0, length: 0))
        try await waitForFileTabState { a.isDirty }
        XCTAssertEqual(b.text, "let fileB = \"only B\"\n")
        manager.openFile(bPath.path)
        host.rootView = panel(for: try XCTUnwrap(project.selectedTab))
        try await waitForFileTabState {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) === bEditor && !a.isDirty
        }
        XCTAssertEqual(try String(contentsOf: aPath, encoding: .utf8),
                       "// edited A\nlet fileA = \"only A\"\n")
        XCTAssertEqual(try String(contentsOf: bPath, encoding: .utf8),
                       "let fileB = \"only B\"\n")

        bEditor.insertText("// edited B\n", replacementRange: NSRange(location: 0, length: 0))
        try await waitForFileTabState { b.isDirty }
        manager.openFile(aPath.path)
        host.rootView = panel(for: try XCTUnwrap(project.selectedTab))
        try await waitForFileTabState {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) === aEditor && !b.isDirty
        }
        XCTAssertEqual(try String(contentsOf: aPath, encoding: .utf8),
                       "// edited A\nlet fileA = \"only A\"\n")
        XCTAssertEqual(try String(contentsOf: bPath, encoding: .utf8),
                       "// edited B\nlet fileB = \"only B\"\n")
    }

    func testCanceledWidthPreparationCannotPublishObsoleteFileAfterRename() async throws {
        let settings = AppSettings.shared
        let oldWrap = settings.wrapLines
        settings.wrapLines = false
        defer { settings.wrapLines = oldWrap }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-width-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("large.txt")
        let next = root.appendingPathComponent("small.txt")
        let largeText = (0..<100_000).map { row -> String in
            "语言\(String(UnicodeScalar(0x4E00 + row % 20_000)!))👋\t// \(String(UnicodeScalar(0x4E00 + row / 20_000)!))\r\n"
        }.joined()
        try largeText.write(to: old, atomically: true, encoding: .utf8)
        try "new target 中文👋\n".write(to: next, atomically: true, encoding: .utf8)
        let file = FileTab(path: old.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        file.loadIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        file.updatePath(next.path)
        try await file.waitForText()
        XCTAssertEqual(file.text, "new target 中文👋\n")
        XCTAssertEqual(file.path, next.path)
        XCTAssertEqual(file.preparedLineWidths?.widths.widths.count, 2)
        // A canceled old worker must not publish a second, obsolete document.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(file.text, "new target 中文👋\n")
        XCTAssertNil(file.reloadError)
    }

    func testPreparedNativeWidthsInvalidateOnUnshownEditsAndFontMismatch() async throws {
        let settings = AppSettings.shared
        let oldWrap = settings.wrapLines
        settings.wrapLines = false
        defer { settings.wrapLines = oldWrap }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-prepared-width-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("unicode.txt")
        try "短文字\n".write(to: target, atomically: true, encoding: .utf8)
        let file = FileTab(path: target.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        XCTAssertNotNil(file.preparedLineWidths)
        file.text = String(repeating: "中文👋\t", count: 50)
        XCTAssertNil(file.preparedLineWidths,
                     "Editing before mounting must discard the old bytes' width snapshot")
        let font = TerminalFont.current()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SourceTextEditor(
            file: file, font: font, palette: .theme(dark: false),
            wrapLines: false, isFocused: false
        ))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertEqual(editor.string, file.text)
        XCTAssertGreaterThan(editor.frame.width, editor.enclosingScrollView!.contentView.bounds.width)

        let another = FileTab(path: target.path, backend: LocalWorkspaceBackend.shared,
                              workspaceIdentity: nil)
        try await another.waitForText()
        XCTAssertNotNil(another.preparedLineWidths)
        let larger = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        XCTAssertFalse(another.preparedLineWidths!.font.isEqual(larger))
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        let otherHost = NSHostingView(rootView: SourceTextEditor(
            file: another, font: larger, palette: .theme(dark: false),
            wrapLines: false, isFocused: false
        ))
        otherWindow.contentView = otherHost
        otherWindow.orderFront(nil)
        otherHost.layoutSubtreeIfNeeded()
        let otherEditor = try XCTUnwrap(mountedEditor(in: otherHost))
        XCTAssertEqual(otherEditor.font, larger)
        XCTAssertNil(another.preparedLineWidths,
                     "A mismatched typography snapshot must not persist after mounting")
    }

    func testFileTabColdUniqueUnicodeMountDoesNotBlockMainActorWithFullWidthShaping() async throws {
        let settings = AppSettings.shared
        let oldWrap = settings.wrapLines
        settings.wrapLines = false
        defer { settings.wrapLines = oldWrap }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-width-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("non-repeating.txt")
        let source = (0..<100_000).map { row -> String in
            let first = String(UnicodeScalar(0x4E00 + row % 20_000)!)
            let second = String(UnicodeScalar(0x4E00 + row / 20_000)!)
            return "语言\(second)\(first)👋\t// 中文\r\n"
        }.joined() + String(repeating: "中文👋\t", count: 80)
        try source.write(to: url, atomically: true, encoding: .utf8)
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        let heartbeat = Task { @MainActor in
            var last = CFAbsoluteTimeGetCurrent()
            var longest = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                let current = CFAbsoluteTimeGetCurrent()
                longest = max(longest, (current - last) * 1_000)
                last = current
            }
            return longest
        }
        await Task.yield()
        let loadStarted = CFAbsoluteTimeGetCurrent()
        try await file.waitForText()
        let loadedMs = (CFAbsoluteTimeGetCurrent() - loadStarted) * 1_000
        heartbeat.cancel()
        let longestMainGap = await heartbeat.value
        print("P2_FILETAB_BACKGROUND_UNIQUE rows=100000 load_ms=\(loadedMs) main_tick_max_ms=\(longestMainGap)")
        XCTAssertLessThan(longestMainGap, 500, "Full font shaping must not monopolize the main actor")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: SourceTextEditor(
            file: file, font: TerminalFont.current(),
            palette: .theme(dark: false), wrapLines: false, isFocused: false
        ))
        let started = CFAbsoluteTimeGetCurrent()
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        print("P2_FILETAB_FIRST_NATIVE_UNIQUE rows=100000 mounted_ms=\(elapsedMs)")
        XCTAssertEqual(editor.string, source)
        let font = TerminalFont.current()
        let style = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        style.defaultTabInterval = NativeCodeTextView.tabInterval
        let tail = String(repeating: "中文👋\t", count: 80)
        let exactWidth = (tail as NSString).size(withAttributes: [
            .font: font, .paragraphStyle: style
        ]).width
        let clipWidth = try XCTUnwrap(editor.enclosingScrollView).contentView.bounds.width
        let padding = (editor.textContainer?.lineFragmentPadding ?? 5) * 2
        XCTAssertEqual(editor.frame.width, max(clipWidth, ceil(exactWidth + padding)),
                       accuracy: 1, "The background font must match exact on-screen glyph widths")
        XCTAssertLessThan(elapsedMs, 3_000,
                          "Full-document font shaping must not block the actual file view")
    }

    func testNativeEditorResignFirstResponderWritesRealFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("focus.txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()

        func findEditor(in view: NSView) -> FocusReportingTextView? {
            if let editor = view as? FocusReportingTextView { return editor }
            return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
        }
        let editor = try XCTUnwrap(findEditor(in: host))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("中文😀", replacementRange: NSRange(location: 0, length: 0))
        try await waitForFileTabState { file.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        XCTAssertTrue(window.makeFirstResponder(nil), "Moving focus away must notify the original editor")
        try await waitForFileTabState { !file.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "中文😀original")
    }

    private func mountedEditor(in view: NSView) -> FocusReportingTextView? {
        if let editor = view as? FocusReportingTextView { return editor }
        return view.subviews.lazy.compactMap { self.mountedEditor(in: $0) }.first
    }
}
