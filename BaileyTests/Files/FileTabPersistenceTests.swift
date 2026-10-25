import AppKit
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import Bailey

private actor EditorWorkspaceFixture: WorkspaceBackend {
    enum Rejection: Error { case simulated }

    private struct PendingWrite {
        let path: String
        let data: Data
        let finish: CheckedContinuation<Void, Error>
    }

    private var files: [String: Data]
    private var writing: PendingWrite?
    private var reading: [CheckedContinuation<Data, Error>] = []
    private var nextReadPaused = false
    private(set) var readCount = 0
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
        } else {
            files[pending.path] = pending.data
            pending.finish.resume()
        }
    }
    func data(at path: String) -> Data? { files[path] }
    func replace(path: String, with data: Data) { files[path] = data }

    func read(path: String, maxBytes: Int) async throws -> Data {
        readCount += 1
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
        try await withCheckedThrowingContinuation { continuation in
            writingPath = path
            writing = PendingWrite(path: path, data: data, finish: continuation)
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
    func gitRoot(containing path: String) async throws -> String? { nil }
    func isLinkedWorktree(_ root: String) async throws -> Bool { false }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        throw WorkspaceError.notFound
    }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot {
        .init(descendants: [], namesByPid: [:])
    }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { [] }
    func kill(pid: pid_t, force: Bool) async throws { throw WorkspaceError.notFound }
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

    func testLocalTextReadCapacityAndFailureKinds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = 8 << 20
        for count in [0, limit - 1, limit, limit + 1] {
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
        guard case .unavailable(let invalidReason) = truncated.content else { return XCTFail("Expected binary placeholder") }
        XCTAssertEqual(invalidReason, String(localized: "Binary file", table: "Workspace"))

        let missing = FileTab(path: root.appendingPathComponent("missing.txt").path,
                              backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        do { try await missing.waitForText(); XCTFail("Expected missing read failure") } catch {}
        guard case .unavailable(let reason) = missing.content else { return XCTFail("Expected read failure") }
        XCTAssertEqual(reason, String(localized: "Could not read file", table: "Workspace"))
        try Data("recovered".utf8).write(to: URL(fileURLWithPath: missing.path))
        try await missing.waitForText()
        XCTAssertEqual(missing.text, "recovered")
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
            ("oversized.png", Data(repeating: 0xff, count: (8 << 20) + 1), sizeReason),
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
        XCTAssertEqual(preview.representations.first?.pixelsWide, 2)
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
    func testGitPreparationWaitsForWritesAndNeverClosesOrLosesEditedTab() async throws {
        let project = Project(fallbackName: "Git Save", workspaceConfiguration: .standard)
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
            await project.saveBeforeGitAction(repository: "/fixture/git", scope: "ssh:fixture", isCurrent: { true })
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
            await project.saveBeforeGitAction(repository: "/fixture/git", scope: "ssh:fixture", isCurrent: { true })
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside.txt")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("baseline".utf8).write(to: inside)
        try Data("other repository".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let project = Project(fallbackName: "Aliases", workspaceConfiguration: .standard)
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
        let prepared = await project.saveBeforeGitAction(repository: repository, scope: "local", isCurrent: { true })
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

    func testCloseFilesSavesOriginallyCleanTabEditedDuringAnotherTabWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(fallbackName: "Close Files", workspaceConfiguration: .standard)
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
        project.closeFiles()
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

    func testAnotherLiveChannelTakesOverWithoutTransientReadOnlyState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("remote.txt")
        try Data("local sentinel".utf8).write(to: path)
        let project = Project(fallbackName: "channel handoff", workspaceConfiguration: .standard)
        defer { project.terminateAll() }
        func connect(_ session: TerminalSession) -> RemoteConnection {
            let connection = RemoteConnection(
                user: "fixture", host: "invalid", port: 2222,
                controlSocket: directory.appendingPathComponent(UUID().uuidString), sshPID: 0
            )
            connection.workingDirectory = directory.path
            connection.markConnected()
            XCTAssertTrue(session.beginRemoteConnection(connection))
            return connection
        }
        let first = connect(project.newSession())
        let second = connect(project.newSession())
        try await Task.sleep(for: .milliseconds(50))
        let backend = EditorWorkspaceFixture(path: path.path, contents: Data("baseline\n".utf8))
        let file = FileTab(path: path.path, backend: backend, workspaceIdentity: first.workspaceIdentity)
        try await file.waitForText()
        project.append(PaneTab(content: .file(file)))
        try await waitForFileTabState { if case .text = file.content { return true }; return false }
        file.text = "old channel draft"
        file.refreshDirtyState()
        let save = Task { await file.save() }
        try await waitForFileTabState { await backend.writingPath != nil }
        first.markDisconnected(reason: "first channel ended")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(file.readOnlyReason)
        XCTAssertEqual(second.state, .connected)
        await backend.finishWrite()
        await save.value
        XCTAssertTrue(file.isDirty, "Old-channel write cannot establish the new target's baseline")
        XCTAssertEqual(file.text, "old channel draft")
        guard file.isDirty else { return }
        file.text = "new channel draft"
        file.refreshDirtyState()
        await file.save()
        XCTAssertTrue(file.isDirty)
        XCTAssertTrue(file.saveError != nil || file.readOnlyReason != nil,
                      "The new channel has no socket and must fail, not fall back")
        let oldContents = await backend.data(at: path.path)
        XCTAssertEqual(oldContents, Data("old channel draft".utf8))
        XCTAssertEqual(try Data(contentsOf: path), Data("local sentinel".utf8))
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
        await fulfillment(of: [pathObserved], timeout: 1)
        await backend.finishWrite()
        await outdatedWrite.value
        XCTAssertEqual(file.path, renamed)
        XCTAssertTrue(file.isDirty, "Old path write must not claim new path was saved")
        let renamedBeforeSave = await backend.data(at: renamed)
        XCTAssertNil(renamedBeforeSave)

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
            backend: EditorWorkspaceFixture(path: largePath, contents: Data(repeating: 0x41, count: (8 << 20) + 1)),
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
        let ruler = try XCTUnwrap(editor.gutterView)
        let highlight = NSColor(srgbRed: 0.9, green: 0.12, blue: 0.15, alpha: 1)
        editor.backgroundColor = .black
        scroll.backgroundColor = .black
        ruler.backgroundColor = .black
        editor.highlightSelectedLine = true
        editor.selectedLineHighlightColor = highlight
        ruler.selectedLineHighlightColor = highlight
        editor.textSelection = NSRange(location: 0, length: 0)

        func verify(_ stage: String) throws {
            host.layoutSubtreeIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            editor.needsDisplay = true
            ruler.needsDisplay = true
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
        XCTAssertEqual(editor.backgroundColor, ruler.backgroundColor)
        XCTAssertEqual(editor.selectedLineHighlightColor, ruler.selectedLineHighlightColor)
        editor.backgroundColor = .black
        ruler.backgroundColor = .black
        editor.selectedLineHighlightColor = highlight
        ruler.selectedLineHighlightColor = highlight
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
        let project = Project(fallbackName: "native read-only", workspaceConfiguration: .standard)
        defer { project.terminateAll() }
        let connection = RemoteConnection(user: "fixture", host: "invalid", port: 2222,
            controlSocket: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), sshPID: 0)
        connection.workingDirectory = "/fixture"
        connection.markConnected()
        XCTAssertTrue(project.newSession().beginRemoteConnection(connection))
        let backend = EditorWorkspaceFixture(path: "/fixture/file.txt", contents: Data("original".utf8))
        let file = FileTab(path: "/fixture/file.txt", backend: backend, workspaceIdentity: connection.workspaceIdentity)
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
        connection.markDisconnected(reason: "controlled outage")
        try await waitForFileTabState { host.layoutSubtreeIfNeeded(); return !editor.isEditable }
        editor.setAccessibilityValue("must not replace")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        editor.keyDown(with: event)
        XCTAssertEqual(editor.text, "unsaved")
        connection.markConnected()
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
