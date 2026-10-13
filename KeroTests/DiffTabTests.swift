import AppKit
import Foundation
import Observation
import STTextView
import SwiftUI
import XCTest
@testable import kero

private actor DiffWorkspaceFixture: WorkspaceBackend {
    private var contents = Data("baseline😀\r\n".utf8)
    private var pendingWrite: (Data, CheckedContinuation<Void, Error>)?
    private var pendingRead: CheckedContinuation<Data, Error>?
    private var pauseRead = false
    private(set) var writing = false
    private(set) var reading = false
    private(set) var writes = 0

    func finishWrite(failing: Bool = false) {
        guard let (data, continuation) = pendingWrite else { return }
        pendingWrite = nil
        writing = false
        if failing {
            continuation.resume(throwing: WorkspaceError.timedOut)
        } else {
            contents = data
            continuation.resume()
        }
    }
    func stored() -> Data { contents }
    func pauseOneRead() { pauseRead = true }
    func finishRead(with data: Data) {
        let continuation = pendingRead
        pendingRead = nil
        reading = false
        continuation?.resume(returning: data)
    }
    func write(path: String, data: Data) async throws {
        writes += 1
        try await withCheckedThrowingContinuation { continuation in
            writing = true
            pendingWrite = (data, continuation)
        }
    }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        .init(status: 0, stdout: Data(), stderr: Data())
    }
    func stat(path: String) async throws -> WorkspaceStat? {
        .init(isRegular: true, isDirectory: false, isSymlink: false, size: contents.count, mtime: .distantPast)
    }
    func read(path: String, maxBytes: Int) async throws -> Data {
        if pauseRead {
            pauseRead = false
            reading = true
            return try await withCheckedThrowingContinuation { pendingRead = $0 }
        }
        return contents
    }
    func readSymlinkDestination(path: String) async throws -> String? { nil }
    func list(directory: String) async throws -> [WorkspaceEntry] { [] }
    func createFile(path: String) async throws { throw WorkspaceError.notFound }
    func createDirectory(path: String) async throws { throw WorkspaceError.notFound }
    func rename(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func delete(paths: [String]) async throws { throw WorkspaceError.notFound }
    func gitRoot(containing path: String) async throws -> String? { nil }
    func isLinkedWorktree(_ root: String) async throws -> Bool { false }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot { .init(descendants: [], namesByPid: [:]) }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { [] }
    func kill(pid: pid_t, force: Bool) async throws { throw WorkspaceError.notFound }
}

@MainActor
final class DiffTabTests: XCTestCase {
    private func findNativeTextView(in view: NSView, editable: Bool? = nil) -> DiffTextView? {
        if let textView = view as? DiffTextView,
           editable == nil || textView.isEditable == editable { return textView }
        return view.subviews.lazy.compactMap { self.findNativeTextView(in: $0, editable: editable) }.first
    }

    private func wait(
        _ condition: () async -> Bool,
        pollingInterval: Duration = .milliseconds(15),
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline {
                XCTFail("Native or backend operation did not settle", file: file, line: line)
                throw WorkspaceError.timedOut
            }
            try await Task.sleep(for: pollingInterval)
        }
    }

    private func repository() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for arguments in [
            ["init", "-q"], ["config", "user.name", "Diff Test"],
            ["config", "user.email", "test@invalid"], ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", "/dev/null"],
        ] {
            let result = GitCommandExecution.run(arguments, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        return directory
    }

    func testAnotherLiveChannelInvalidatesInFlightDiffSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("remote.txt")
        try Data("local sentinel".utf8).write(to: path)
        let project = Project(fallbackName: "diff channel handoff", workspaceConfiguration: .standard)
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
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(
            repoRoot: directory.path, path: "remote.txt", staged: false, untracked: true,
            origPath: nil, backend: backend, workspaceIdentity: first.workspaceIdentity
        )
        project.append(PaneTab(content: .diff(diff)))
        try await wait { !diff.isLoading }
        XCTAssertTrue(diff.isEditableNow)
        diff.updateEditedContent("old channel draft")
        let save = Task { await diff.save() }
        try await wait { await backend.writing }
        first.markDisconnected(reason: "first channel ended")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(diff.readOnlyReason)
        XCTAssertEqual(second.state, .connected)
        await backend.finishWrite()
        await save.value
        XCTAssertTrue(diff.isDirty, "Old-channel write cannot establish the new target's baseline")
        guard diff.isDirty else { return }
        diff.updateEditedContent("new channel draft")
        await diff.save()
        XCTAssertTrue(diff.isDirty)
        XCTAssertTrue(diff.saveError != nil || diff.readOnlyReason != nil)
        let oldContents = await backend.stored()
        XCTAssertEqual(oldContents, Data("old channel draft".utf8))
        XCTAssertEqual(try Data(contentsOf: path), Data("local sentinel".utf8))
    }

    func testWorktreeStagedHistoryBinarySizeAndSymlink() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = "原文😀\r\n"
        let stagedText = "暂存🪨\r\n"
        let worktreeText = "工作区🙂\r\n"
        let file = directory.appendingPathComponent("tracked.txt")
        try Data(original.utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["add", "."], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "initial"], in: directory.path).status, 0)
        let hash = GitCommandExecution.run(["rev-parse", "HEAD"], in: directory.path).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try Data(stagedText.utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["add", "tracked.txt"], in: directory.path).status, 0)
        try Data(worktreeText.utf8).write(to: file)

        func diff(_ path: String = "tracked.txt", staged: Bool = false, commit: String? = nil) -> DiffTab {
            DiffTab(repoRoot: directory.path, path: path, staged: staged, untracked: false,
                    origPath: nil, commitHash: commit, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        }
        let worktree = diff()
        let index = diff(staged: true)
        let history = diff(commit: hash)
        try await wait { !worktree.isLoading && !index.isLoading && !history.isLoading }
        XCTAssertEqual(worktree.oldContent, stagedText)
        XCTAssertEqual(worktree.newContent, worktreeText)
        XCTAssertTrue(worktree.isEditable)
        XCTAssertEqual(index.oldContent, original)
        XCTAssertEqual(index.newContent, stagedText)
        XCTAssertFalse(index.isEditable)
        XCTAssertEqual(history.oldContent, "")
        XCTAssertEqual(history.newContent, original)
        XCTAssertFalse(history.isEditable)

        let pane = PaneTab(content: .diff(worktree))
        let dirty = expectation(description: "Diff dirty propagates through the existing pane")
        withObservationTracking({ _ = pane.content.isDirty }) { dirty.fulfill() }
        worktree.updateEditedContent("saved😀\r\n")
        await fulfillment(of: [dirty], timeout: 1)
        XCTAssertEqual(worktree.newContent, worktreeText)
        await worktree.save()
        XCTAssertFalse(worktree.isDirty)
        XCTAssertEqual(try Data(contentsOf: file), Data("saved😀\r\n".utf8))

        try Data([0x41, 0x00, 0x42]).write(to: directory.appendingPathComponent("binary.bin"))
        try Data(repeating: 0x41, count: 5 * 1024 * 1024 + 1).write(to: directory.appendingPathComponent("large.txt"))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path, withDestinationPath: "tracked.txt")
        let binary = diff("binary.bin")
        let large = diff("large.txt")
        let link = diff("link")
        try await wait { !binary.isLoading && !large.isLoading && !link.isLoading }
        XCTAssertNotNil(binary.error)
        XCTAssertFalse(binary.isEditable)
        XCTAssertNotNil(large.error)
        XCTAssertFalse(large.isEditable)
        XCTAssertEqual(link.newContent, "tracked.txt")
        XCTAssertFalse(link.isEditable)
    }

    func testSaveDuringEditFailureAndDisconnectKeepUnsavedContent() async throws {
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "remote.txt", staged: false,
                           untracked: true, origPath: nil, backend: backend, workspaceIdentity: "ssh:fixture")
        try await wait { !diff.isLoading }
        diff.updateEditedContent("first😀\r\n")
        let saving = Task { await diff.save() }
        try await wait { await backend.writing }
        diff.updateEditedContent("second🪨\r\n")
        await backend.finishWrite()
        await saving.value
        XCTAssertTrue(diff.isDirty)
        let firstStored = await backend.stored()
        XCTAssertEqual(firstStored, Data("first😀\r\n".utf8))

        let failing = Task { await diff.save() }
        try await wait { await backend.writing }
        await backend.finishWrite(failing: true)
        await failing.value
        XCTAssertTrue(diff.isDirty)
        XCTAssertNotNil(diff.saveError)

        let outdated = Task { await diff.save() }
        try await wait { await backend.writing }
        let project = Project(fallbackName: "offline", workspaceConfiguration: .standard)
        diff.reevaluateWorkspace(in: project)
        await backend.finishWrite()
        await outdated.value
        XCTAssertTrue(diff.isDirty)
        XCTAssertNotNil(diff.readOnlyReason)
        XCTAssertFalse(diff.isEditableNow)
        XCTAssertEqual(diff.newContent, "second🪨\r\n", "Disconnected native review must still display unsaved edits")
        await diff.save()
        XCTAssertEqual(diff.saveError, diff.readOnlyReason)
        let count = await backend.writes
        XCTAssertEqual(count, 3)
        XCTAssertEqual(diff.editedNewContent, "second🪨\r\n")
        XCTAssertTrue(diff.isDirty)
    }

    func testNativeDiffRendersAndRetainsTextKitSurface() async throws {
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "render.txt", staged: false,
                           untracked: true, origPath: nil, backend: backend, workspaceIdentity: nil)
        try await wait { !diff.isLoading && diff.display != nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        func mount() -> NSHostingView<DiffViewerView> {
            let host = NSHostingView(rootView: DiffViewerView(diff: diff))
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            return host
        }

        let first = mount()
        try await wait { diff.nativeSurface != nil && self.findNativeTextView(in: first) != nil }
        let surface = try XCTUnwrap(diff.nativeSurface)
        let textView = try XCTUnwrap(findNativeTextView(in: surface))
        XCTAssertTrue(textView.attributedText?.string.contains("baseline") == true)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.window === window)

        first.removeFromSuperview()
        let second = mount()
        try await wait { self.findNativeTextView(in: second) === textView }
        XCTAssertTrue(diff.nativeSurface === surface)
        XCTAssertTrue(findNativeTextView(in: second) === textView)
        XCTAssertTrue(textView.attributedText?.string.contains("baseline") == true)
        second.removeFromSuperview()
    }


    func testNativeDiffUnicodeAndSplitAlignmentWithFoldExpansion() {
        let old = "one\r\n中文😀\r\nlast\n"
        let new = "one\r\n中文🪨\r\nlast"
        let compared = DiffComputation.compute(oldText: old, newText: new)
        XCTAssertEqual(compared.splitLeft.rows.count, compared.splitRight.rows.count)
        XCTAssertEqual(compared.unified.rows.count, compared.unified.lineStartOffsets.count)
        XCTAssertTrue(compared.unified.rows.contains { if case .removed = $0.kind { true } else { false } })
        XCTAssertTrue(compared.unified.rows.contains { if case .added = $0.kind { true } else { false } })
        XCTAssertTrue(compared.unified.rows.contains { $0.missingNewline })
        XCTAssertTrue(compared.unified.text.contains("中文"))

        let oldLines = (0..<240).map { "line \($0)" }
        var newLines = oldLines
        newLines[120] = "line 120 changed"
        let oldText = oldLines.joined(separator: "\n") + "\n"
        let newText = newLines.joined(separator: "\n") + "\n"
        let core = DiffCore.compute(oldText: oldText, newText: newText)
        let folded = DiffComputation.build(core: core, expansions: [:])
        let folds = folded.unified.rows.compactMap(\.collapsed)
        XCTAssertFalse(folds.isEmpty)
        XCTAssertEqual(folded.splitLeft.rows.count, folded.splitRight.rows.count)
        let expanded = DiffComputation.build(
            core: core,
            expansions: [folds[0].runIndex: DiffRunExpansion(fromStart: 100, fromEnd: 0)]
        )
        XCTAssertGreaterThan(expanded.unified.rows.count, folded.unified.rows.count)
        XCTAssertEqual(expanded.splitLeft.rows.count, expanded.splitRight.rows.count)
    }

    func testNativeDiffSplitLayoutPreservesPaneIdentity() async throws {
        let domain = "kero-native-layout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        preferences.prefersEditing = false
        preferences.diffStyle = .unified
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(
            repoRoot: "/fixture", path: "split.txt", staged: false,
            untracked: true, origPath: nil, backend: backend,
            workspaceIdentity: nil, preferences: preferences
        )
        try await wait { !diff.isLoading && diff.display != nil }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await wait { diff.nativeSurface != nil && self.findNativeTextView(in: host) != nil }
        let surface = try XCTUnwrap(diff.nativeSurface)
        let firstUnified = try XCTUnwrap(findNativeTextView(in: surface))
        XCTAssertTrue(firstUnified.attributedText?.string.contains("baseline") == true)

        diff.setDiffStyle(.split)
        try await wait {
            surface.subviews.filter { ($0 as? DiffCodePaneView)?.isHidden == false }.count == 2
        }
        let visible = surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }
        XCTAssertEqual(visible.count, 2)
        XCTAssertTrue(visible.allSatisfy { !$0.textView.isEditable })
        XCTAssertTrue(visible.contains { $0.textView.attributedText?.string.contains("baseline") == true })
        XCTAssertEqual(visible[0].scrollView.contentView.bounds.height, visible[1].scrollView.contentView.bounds.height)

        diff.setDiffStyle(.unified)
        try await wait { surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }.count == 1 }
        XCTAssertTrue(findNativeTextView(in: surface) === firstUnified)
    }

    func testReadInFlightCannotReplaceEditingOrDisconnectedContent() async throws {
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "stale.txt", staged: false,
                           untracked: true, origPath: nil, backend: backend, workspaceIdentity: "ssh:fixture")
        try await wait { !diff.isLoading }
        let baseline = diff.newContent
        await backend.pauseOneRead()
        diff.reload()
        try await wait { await backend.reading }
        diff.updateEditedContent("editing during read")
        await backend.finishRead(with: Data("stale result".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(diff.isDirty)
        XCTAssertEqual(diff.newContent, baseline)

        diff.updateEditedContent(baseline)
        XCTAssertFalse(diff.isDirty)
        await backend.pauseOneRead()
        diff.reload()
        try await wait { await backend.reading }
        let project = Project(fallbackName: "disconnected", workspaceConfiguration: .standard)
        diff.reevaluateWorkspace(in: project)
        await backend.finishRead(with: Data("outdated before outage".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotNil(diff.readOnlyReason)
        XCTAssertEqual(diff.newContent, baseline)
        XCTAssertFalse(diff.isEditableNow)
    }

    func testNativeDiffEditUndoScrollSaveAndReparent() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("editor.txt")
        let original = (0..<180).map { "line \($0) 中文😀\n" }.joined()
        try Data(original.utf8).write(to: file)
        let domain = "kero-native-diff-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        preferences.prefersEditing = true
        let diff = DiffTab(repoRoot: directory.path, path: "editor.txt", staged: false,
                           untracked: true, origPath: nil, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil, preferences: preferences)
        try await wait { !diff.isLoading && diff.isEditable && diff.display != nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = container
        var host: NSHostingView<DiffViewerView>?
        func mount() {
            let root = NSHostingView(rootView: DiffViewerView(diff: diff))
            root.frame = container.bounds
            host = root
            container.addSubview(root)
            window.orderFront(nil)
            root.layoutSubtreeIfNeeded()
        }
        mount()
        try await wait { diff.nativeSurface != nil && self.findNativeTextView(in: container, editable: true) != nil }
        let surface = try XCTUnwrap(diff.nativeSurface)
        let editor = try XCTUnwrap(findNativeTextView(in: surface, editable: true))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("E", replacementRange: NSRange(location: 0, length: 0))
        try await wait { diff.isDirty }
        XCTAssertEqual(editor.text, "E" + original)
        // Keep the native insertion point inside the viewport before
        // checking that reparenting preserves the reader's scroll offset.
        editor.textSelection = NSRange(
            location: (editor.text! as NSString).range(of: "line 45").location,
            length: 0
        )
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 700))
        scroll.reflectScrolledClipView(scroll.contentView)
        let previousOffset = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(previousOffset.y, 0)
        let undoManager = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undoManager.canUndo)

        host?.removeFromSuperview()
        host = nil
        mount()
        try await wait { self.findNativeTextView(in: container, editable: true) === editor }
        XCTAssertTrue(diff.nativeSurface === surface)
        XCTAssertTrue(findNativeTextView(in: container, editable: true) === editor)
        XCTAssertEqual(scroll.contentView.bounds.origin, previousOffset)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        try await wait { !diff.isDirty }
        XCTAssertEqual(editor.text, original)
        undoManager.redo()
        try await wait { diff.isDirty }
        XCTAssertEqual(editor.text, "E" + original)
        await diff.save()
        XCTAssertFalse(diff.isDirty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "E" + original)

        // A mode switch must expose the saved buffer as the review document.
        diff.setEditing(false)
        try await wait { diff.newContent == "E" + original && diff.display != nil }
        XCTAssertEqual(diff.newContent, "E" + original)
        host?.removeFromSuperview()
    }

    func testEnteringEditModeDiscardsInFlightReadAndKeepsSharedPreferenceIdentity() async throws {
        let domain = "kero-diff-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "editing.txt", staged: false,
                           untracked: true, origPath: nil, backend: backend, workspaceIdentity: nil,
                           preferences: preferences)
        try await wait { !diff.isLoading }
        let baseline = diff.newContent
        await backend.pauseOneRead()
        diff.reload()
        try await wait { await backend.reading }
        diff.setEditing(true)
        XCTAssertTrue(diff.preferences === preferences)
        XCTAssertEqual(defaults.string(forKey: "diffView.mode"), "edit")
        await backend.finishRead(with: Data("stale before editor appeared".utf8))
        try await wait { !diff.isLoading }
        XCTAssertEqual(diff.newContent, baseline)
        XCTAssertFalse(diff.isDirty)
        diff.updateEditedContent("current buffer")
        diff.reload()
        XCTAssertEqual(diff.newContent, baseline)
        XCTAssertTrue(diff.isDirty)
        diff.setDiffStyle(.split)
        XCTAssertEqual(defaults.string(forKey: "diffView.layout"), "split")
    }
}
