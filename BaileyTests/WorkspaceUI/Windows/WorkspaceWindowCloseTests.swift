import AppKit
import SwiftUI
import XCTest
@testable import Bailey

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

    func read(path: String, maxBytes: Int) async throws -> Data {
        guard bytes.count <= maxBytes else { throw WorkspaceError.tooLarge }
        return bytes
    }
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

    func testEmptyWorkspaceAttachesToWindowWhenHostingViewWasRenderedOffscreen() async throws {
        let oldSnapshots = SessionStore.load()
        let oldHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(oldSnapshots)
            TerminalHistoryStore.save(oldHistories)
        }
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        XCTAssertTrue(manager.projects.isEmpty)
        let host = NSHostingView(rootView: ContentView(manager: manager))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 410)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(manager.attachedWindow)

        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 620, height: 410),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.attachedWindow === window
        }
        XCTAssertTrue(window.delegate is WindowChromeAccessor.Coordinator)
        manager.chooseFolders()
        try await wait { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .cancel)
        try await wait { window.attachedSheet == nil }
        XCTAssertTrue(manager.projects.isEmpty)
    }

    func testTwoNativeWorkspacesAttachOwnWindowsAndKeepFolderPickerIsolated() async throws {
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(snapshots)
            TerminalHistoryStore.save(histories)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = TerminalManager()
        let second = TerminalManager()
        defer {
            first.windowClosed()
            second.windowClosed()
        }
        first.addLocalFolders([root])
        XCTAssertTrue(second.projects.isEmpty)

        let firstWindow = NSWindow(
            contentRect: NSRect(x: 10, y: 10, width: 570, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 600, y: 10, width: 570, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        defer { firstWindow.close(); secondWindow.close() }
        let firstView = NSHostingView(rootView: ContentView(manager: first))
        let secondView = NSHostingView(rootView: ContentView(manager: second))
        firstWindow.contentView = firstView
        secondView.frame = NSRect(x: 0, y: 0, width: 570, height: 400)
        secondView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(second.attachedWindow)
        secondWindow.contentView = secondView
        firstWindow.orderFront(nil)
        secondWindow.makeKeyAndOrderFront(nil)
        try await wait {
            firstView.layoutSubtreeIfNeeded()
            secondView.layoutSubtreeIfNeeded()
            return first.attachedWindow === firstWindow && second.attachedWindow === secondWindow
        }
        XCTAssertTrue(firstWindow.delegate is WindowChromeAccessor.Coordinator)
        XCTAssertTrue(secondWindow.delegate is WindowChromeAccessor.Coordinator)
        second.chooseFolders()
        try await wait { secondWindow.attachedSheet != nil }
        XCTAssertNil(firstWindow.attachedSheet)
        secondWindow.endSheet(try XCTUnwrap(secondWindow.attachedSheet), returnCode: .cancel)
        try await wait { secondWindow.attachedSheet == nil }
        XCTAssertTrue(second.projects.isEmpty)
        XCTAssertEqual(first.projects.count, 1)
        first.chooseFolders()
        try await wait { firstWindow.attachedSheet != nil }
        XCTAssertNil(secondWindow.attachedSheet)
        firstWindow.endSheet(try XCTUnwrap(firstWindow.attachedSheet), returnCode: .cancel)
        try await wait { firstWindow.attachedSheet == nil }
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
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let backend = WindowSaveFixture("original")
        let tab = FileTab(path: root.appendingPathComponent("case.txt").path,
                          backend: backend, workspaceIdentity: nil)
        try await tab.waitForText()
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

        // Replacing the SwiftUI host must install a live coordinator without
        // losing the original window delegate. SwiftUI owns when the retired
        // host is released; deallocation is not a prerequisite for close.
        let replacement = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = replacement
        host = nil
        try await wait {
            replacement.layoutSubtreeIfNeeded()
            return window.contentView === replacement
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
