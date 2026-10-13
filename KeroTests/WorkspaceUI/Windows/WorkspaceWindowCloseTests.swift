import AppKit
import SwiftUI
import XCTest
@testable import kero

private actor WindowSaveFixture: WorkspaceBackend {
    enum Failure: Error { case writeRejected }
    private var bytes: Data
    private var reject = true
    private var pauseNextWrite = false
    private var resumePendingWrite: CheckedContinuation<Void, Never>?
    private(set) var awaitingWrite = false
    private(set) var writes = 0

    init(_ text: String) { bytes = Data(text.utf8) }
    func permitWrites() { reject = false }
    func pauseOneWrite() { pauseNextWrite = true }
    func releaseWrite() {
        resumePendingWrite?.resume()
        resumePendingWrite = nil
        awaitingWrite = false
    }
    func currentText() -> String { String(decoding: bytes, as: UTF8.self) }

    func read(path: String, maxBytes: Int) async throws -> Data { Data(bytes.prefix(maxBytes)) }
    func write(path: String, data: Data) async throws {
        writes += 1
        if pauseNextWrite {
            pauseNextWrite = false
            awaitingWrite = true
            await withCheckedContinuation { resumePendingWrite = $0 }
        }
        if reject { throw Failure.writeRejected }
        bytes = data
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
private final class WindowCloseDelegateWitness: NSObject, NSWindowDelegate {
    var closed = false
    func windowWillClose(_ notification: Notification) { closed = true }
}

@MainActor
final class WorkspaceWindowCloseTests: XCTestCase {
    private func wait(
        _ check: () async -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !(await check()) {
            guard Date() < deadline else {
                XCTFail("Window close operation did not settle", file: file, line: line)
                throw WorkspaceError.timedOut
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    func testNativeCloseDoesNotDiscardFailedSaveThenClosesAfterRetry() async throws {
        let oldWindows = SessionStore.load()
        let oldHistories = TerminalHistoryStore.load()
        defer { SessionStore.save(oldWindows); TerminalHistoryStore.save(oldHistories) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let backend = WindowSaveFixture("original")
        let tab = FileTab(path: root.appendingPathComponent("case.txt").path,
                          backend: backend, workspaceIdentity: nil)
        try await wait { if case .text = tab.content { return true }; return false }
        project.append(PaneTab(content: .file(tab)))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let witness = WindowCloseDelegateWitness()
        window.delegate = witness
        defer { window.close() }
        var host: NSHostingView<ContentView>? = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await wait {
            host?.layoutSubtreeIfNeeded()
            return manager.attachedWindow === window
        }
        tab.text = "edited, do not discard"
        tab.refreshDirtyState()
        XCTAssertTrue(tab.isDirty)

        window.performClose(nil)
        try await wait { tab.saveError != nil || !window.isVisible }
        XCTAssertTrue(window.isVisible, "Failed write must veto native window close")
        XCTAssertFalse(witness.closed)
        XCTAssertTrue(tab.isDirty)
        let afterFailure = await backend.currentText()
        XCTAssertEqual(afterFailure, "original")
        XCTAssertTrue(manager.projects.contains { $0 === project })

        // Replace the entire SwiftUI host while the dirty window is still
        // alive. It must not accidentally chain its original delegate through
        // a dead WindowChromeAccessor coordinator.
        weak var retiredHost = host
        let replacement = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = replacement
        host = nil
        try await wait {
            replacement.layoutSubtreeIfNeeded()
            return retiredHost == nil
                && window.delegate is WindowChromeAccessor.Coordinator
                && manager.attachedWindow === window
        }

        await backend.permitWrites()
        await backend.pauseOneWrite()
        window.performClose(nil)
        try await wait { await backend.awaitingWrite }
        XCTAssertTrue(window.isVisible, "Native close must await a pending write")
        window.performClose(nil)
        try await Task.sleep(for: .milliseconds(30))
        let writeCount = await backend.writes
        XCTAssertEqual(writeCount, 2, "Repeated close must not start duplicate writes")
        await backend.releaseWrite()
        try await wait { !window.isVisible }
        XCTAssertFalse(tab.isDirty)
        let afterSuccess = await backend.currentText()
        XCTAssertEqual(afterSuccess, "edited, do not discard")
        XCTAssertTrue(witness.closed, "Original NSWindowDelegate must still receive windowWillClose")
    }
}
