import AppKit
import Foundation
import Observation
import SwiftUI
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
    private func mountedEditor(in view: NSView) -> FocusReportingTextView? {
        if let editor = view as? FocusReportingTextView { return editor }
        return view.subviews.lazy.compactMap { self.mountedEditor(in: $0) }.first
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else { return XCTFail("Editor operation did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testGitPreparationWaitsForWritesAndNeverClosesOrLosesEditedTab() async throws {
        let project = Project(fallbackName: "Git Save", workspaceConfiguration: .standard)
        let path = "/fixture/git/file.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("baseline".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        let tab = PaneTab(content: .file(file))
        project.append(tab)
        try await wait { if case .text = file.content { return true }; return false }
        file.text = "first edit"
        file.refreshDirtyState()
        let saving = Task {
            await project.saveBeforeGitAction(repository: "/fixture/git", scope: "ssh:fixture", isCurrent: { true })
        }
        try await wait { await backend.writingPath == path }
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
        try await wait { await backend.writingPath == path }
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
        let other = FileTab(path: outside.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
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
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let firstProject = try XCTUnwrap(manager.selectedProject)
        let firstURL = root.appendingPathComponent("must-save.txt")
        try "before".write(to: firstURL, atomically: true, encoding: .utf8)
        let local = FileTab(path: firstURL.path, backend: LocalWorkspaceBackend.shared,
                            workspaceIdentity: nil)
        firstProject.append(PaneTab(content: .file(local)))
        local.text = "durably saved"
        local.refreshDirtyState()
        manager.close(firstProject)
        try await wait { !manager.projects.contains(where: { $0 === firstProject }) }
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "durably saved")

        manager.addLocalItems([root])
        let failingProject = try XCTUnwrap(manager.selectedProject)
        let remotePath = root.appendingPathComponent("remote.txt")
        try "local sentinel".write(to: remotePath, atomically: true, encoding: .utf8)
        let backend = EditorWorkspaceFixture(path: remotePath.path, contents: Data("old".utf8))
        let remote = FileTab(path: remotePath.path, backend: backend,
                             workspaceIdentity: "ssh:fixture")
        try await wait { if case .text = remote.content { return true }; return false }
        failingProject.append(PaneTab(content: .file(remote)))
        remote.text = "draft not yet persisted"
        remote.refreshDirtyState()
        manager.close(failingProject)
        try await wait { await backend.writingPath == remotePath.path }
        await backend.finishWrite(failing: true)
        try await wait { remote.saveError != nil }
        XCTAssertTrue(manager.projects.contains(where: { $0 === failingProject }))
        XCTAssertTrue(remote.isDirty)
        XCTAssertEqual(try String(contentsOf: remotePath, encoding: .utf8), "local sentinel")

        XCTAssertTrue(TerminalManager.hasUnsavedEditors)
        let exitAttempt = Task { await TerminalManager.saveBeforeTermination() }
        try await wait { await backend.writingPath == remotePath.path }
        await backend.finishWrite(failing: true)
        let shouldExit = await exitAttempt.value
        XCTAssertFalse(shouldExit, "A failed auto-save must veto application termination")
        XCTAssertTrue(remote.isDirty)
    }

    func testProjectTabSwitchAndCloseAutomaticallySaveBeforeRemoving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("autosave.txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        let project = Project(fallbackName: "autosave", workspaceConfiguration: .standard)
        let filePane = PaneTab(content: .file(file))
        project.append(filePane)

        file.text = "saved when selecting the browser"
        file.refreshDirtyState()
        project.append(PaneTab(content: .browser(BrowserTab(initialFocus: .none))))
        try await wait { !file.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved when selecting the browser")

        file.text = "saved when closing the file"
        file.refreshDirtyState()
        project.close(filePane)
        try await wait { !project.tabs.contains(where: { $0.id == filePane.id }) }
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved when closing the file")
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

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()

        // Same entry point used by a file row in the real Files panel.
        manager.openFile(aPath.path)
        let a = try XCTUnwrap(project.tabs.compactMap {
            if case .file(let file) = $0.content, file.path == aPath.path { return file }
            return nil
        }.first)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host)?.text == a.text
                && a.editorView?.window === window
        }
        let aEditor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertEqual(aEditor.text, "let fileA = \"only A\"\n")

        manager.openFile(bPath.path)
        let b = try XCTUnwrap(project.tabs.compactMap {
            if case .file(let file) = $0.content, file.path == bPath.path { return file }
            return nil
        }.first)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host)?.text == b.text
                && b.editorView?.window === window
        }
        let bEditor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertFalse(aEditor === bEditor)
        XCTAssertEqual(bEditor.text, "let fileB = \"only B\"\n")

        manager.openFile(aPath.path)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) === aEditor
                && a.editorView?.window === window
        }
        XCTAssertEqual(aEditor.text, "let fileA = \"only A\"\n")
        XCTAssertEqual(a.text, aEditor.text)

        // Editing after switching back must never modify B's model or bytes.
        aEditor.insertText("// edited A\n", replacementRange: NSRange(location: 0, length: 0))
        try await wait { a.isDirty }
        XCTAssertEqual(b.text, "let fileB = \"only B\"\n")
        manager.openFile(bPath.path)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) === bEditor && !a.isDirty
        }
        XCTAssertEqual(try String(contentsOf: aPath, encoding: .utf8),
                       "// edited A\nlet fileA = \"only A\"\n")
        XCTAssertEqual(try String(contentsOf: bPath, encoding: .utf8),
                       "let fileB = \"only B\"\n")

        bEditor.insertText("// edited B\n", replacementRange: NSRange(location: 0, length: 0))
        try await wait { b.isDirty }
        manager.openFile(aPath.path)
        try await wait {
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
        try await wait { file.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        XCTAssertTrue(window.makeFirstResponder(nil), "Moving focus away must notify the original editor")
        try await wait { !file.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "中文😀original")
    }

    func testFocusTriggeredSaveSerializesConcurrentEditsAndKeepsFailures() async throws {
        let path = "/fixture/\(UUID().uuidString).txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await wait { if case .text = file.content { return true }; return false }

        file.text = "first🙂"
        file.refreshDirtyState()
        let beforeFocusLoss = await backend.writingPath
        XCTAssertNil(beforeFocusLoss, "Typing must not launch a timed or per-keystroke save")
        file.autoSaveOnFocusLoss()
        try await wait { await backend.writingPath == path }

        file.text = "second🪨"
        file.refreshDirtyState()
        file.autoSaveOnFocusLoss()
        await backend.finishWrite()
        try await wait {
            let stored = await backend.data(at: path)
            let writing = await backend.writingPath
            return stored == Data("first🙂".utf8) && writing == path
        }
        XCTAssertTrue(file.isDirty, "The first completed write cannot mark the newer edit saved")
        await backend.finishWrite()
        try await wait { !file.isDirty }
        let final = await backend.data(at: path)
        XCTAssertEqual(final, Data("second🪨".utf8))

        file.text = "offline edit"
        file.refreshDirtyState()
        file.autoSaveOnFocusLoss()
        try await wait { await backend.writingPath == path }
        await backend.finishWrite(failing: true)
        try await wait { file.saveError != nil }
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
        project.append(PaneTab(content: .file(file)))
        try await wait { if case .text = file.content { return true }; return false }
        file.text = "old channel draft"
        file.refreshDirtyState()
        let save = Task { await file.save() }
        try await wait { await backend.writingPath != nil }
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
