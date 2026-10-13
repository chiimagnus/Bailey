import Foundation
import Observation
import XCTest
@testable import kero

private actor EditorWorkspaceFixture: WorkspaceBackend {
    enum Rejection: Error { case simulated }

    private struct PendingWrite {
        let path: String
        let data: Data
        let finish: CheckedContinuation<Void, Error>
    }

    private var files: [String: Data]
    private var writing: PendingWrite?
    private var reading: CheckedContinuation<Data, Error>?
    private var nextReadPaused = false
    private(set) var writingPath: String?
    private(set) var readingPath: String?

    init(path: String, contents: Data) { files = [path: contents] }

    func pauseOneRead() { nextReadPaused = true }
    func finishRead(with data: Data) {
        readingPath = nil
        reading?.resume(returning: data)
        reading = nil
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

    func read(path: String, maxBytes: Int) async throws -> Data {
        guard let data = files[path] else { throw WorkspaceError.notFound }
        if nextReadPaused {
            nextReadPaused = false
            readingPath = path
            return try await withCheckedThrowingContinuation { reading = $0 }
        }
        return Data(data.prefix(maxBytes))
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
    func rename(from: String, to: String) async throws { throw WorkspaceError.notFound }
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
final class FileTabTests: XCTestCase {
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else { return XCTFail("Editor operation did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testDirtyUndoSaveDuringEditRenameFailureAndStaleReload() async throws {
        let first = "/fixture/\(UUID().uuidString)-original.txt"
        let renamed = first.replacingOccurrences(of: "-original", with: "-renamed")
        let original = "原文😀\r\n"
        let backend = EditorWorkspaceFixture(path: first, contents: Data(original.utf8))
        let file = FileTab(path: first, backend: backend, workspaceIdentity: "ssh:fixture")
        try await wait { if case .text = file.content { return true }; return false }
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
        try await wait { await backend.writingPath == first }
        file.text = "second draft🪨\r\n"
        file.refreshDirtyState()
        await backend.finishWrite()
        await firstSave.value
        XCTAssertTrue(file.isDirty, "Edits made during save must remain unsaved")
        let firstStored = await backend.data(at: first)
        XCTAssertEqual(try XCTUnwrap(firstStored), Data("first draft\r\n".utf8))

        let secondSave = Task { await file.save() }
        try await wait { await backend.writingPath == first }
        await backend.finishWrite()
        await secondSave.value
        XCTAssertFalse(file.isDirty)
        let secondStored = await backend.data(at: first)
        XCTAssertEqual(try XCTUnwrap(secondStored), Data(file.text.utf8))

        file.text = "third draft"; file.refreshDirtyState()
        let outdatedWrite = Task { await file.save() }
        try await wait { await backend.writingPath == first }
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
        try await wait { await backend.writingPath == renamed }
        await backend.finishWrite()
        await renamedWrite.value
        XCTAssertFalse(file.isDirty)
        let renamedStored = await backend.data(at: renamed)
        XCTAssertEqual(try XCTUnwrap(renamedStored), Data("third draft".utf8))

        file.text = "fourth draft"; file.refreshDirtyState()
        let rejectedWrite = Task { await file.save() }
        try await wait { await backend.writingPath == renamed }
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
        try await wait { await backend.readingPath == renamed }
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
        try await wait { if case .loading = invalid.content { return false }; return true }
        guard case .unavailable = invalid.content else { return XCTFail("Expected binary placeholder") }
        XCTAssertFalse(invalid.isDirty)

        let largePath = "/fixture/\(UUID().uuidString).txt"
        let large = FileTab(
            path: largePath,
            backend: EditorWorkspaceFixture(path: largePath, contents: Data(repeating: 0x41, count: 5 * 1024 * 1024 + 1)),
            workspaceIdentity: "ssh:fixture"
        )
        try await wait { if case .loading = large.content { return false }; return true }
        guard case .unavailable = large.content else { return XCTFail("Expected size placeholder") }
        XCTAssertFalse(large.isDirty)
    }

    func testDisconnectDuringSavePreservesBufferAndBaseline() async throws {
        let path = "/fixture/\(UUID().uuidString).txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("baseline".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await wait { if case .text = file.content { return true }; return false }
        file.text = "unsaved"
        file.refreshDirtyState()
        let saving = Task { await file.save() }
        try await wait { await backend.writingPath == path }
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
        try await wait { if case .text = file.content { return true }; return false }
        let revision = file.reloadRevision
        await backend.pauseOneRead()
        file.reloadFromDiskIfClean()
        try await wait { await backend.readingPath == path }
        await backend.finishRead(with: Data("新内容😀\r\n".utf8))
        try await wait { file.reloadRevision != revision }
        XCTAssertEqual(file.text, "新内容😀\r\n")
        XCTAssertFalse(file.isDirty)

        await backend.pauseOneRead()
        file.reloadFromDiskIfClean()
        try await wait { await backend.readingPath == path }
        let updatedRevision = file.reloadRevision
        file.updatePath(path + ".renamed")
        await backend.finishRead(with: Data("stale bytes".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(file.text, "新内容😀\r\n")
        XCTAssertEqual(file.reloadRevision, updatedRevision)
    }
}
