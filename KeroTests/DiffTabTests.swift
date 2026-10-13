import AppKit
import Foundation
import Observation
import PierreDiffsSwift
import SwiftUI
import WebKit
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
    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { self.findWebView(in: $0) }.first
    }

    private func wait(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !(await condition()) {
            if Date() >= deadline {
                XCTFail("Native or backend operation did not settle", file: file, line: line)
                throw WorkspaceError.timedOut
            }
            try await Task.sleep(for: .milliseconds(15))
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
        diff.web.onFileEditChange?(diff.path, "old channel draft")
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
        diff.web.onFileEditChange?(diff.path, "new channel draft")
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
        XCTAssertEqual(worktree.web.oldContent, stagedText)
        XCTAssertEqual(worktree.web.newContent, worktreeText)
        XCTAssertTrue(worktree.isEditable)
        XCTAssertEqual(index.web.oldContent, original)
        XCTAssertEqual(index.web.newContent, stagedText)
        XCTAssertFalse(index.isEditable)
        XCTAssertEqual(history.web.oldContent, "")
        XCTAssertEqual(history.web.newContent, original)
        XCTAssertFalse(history.isEditable)

        let pane = PaneTab(content: .diff(worktree))
        let dirty = expectation(description: "Diff dirty propagates through the existing pane")
        withObservationTracking({ _ = pane.content.isDirty }) { dirty.fulfill() }
        worktree.web.onFileEditChange?("tracked.txt", "saved😀\r\n")
        await fulfillment(of: [dirty], timeout: 1)
        XCTAssertEqual(worktree.web.newContent, worktreeText)
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
        XCTAssertEqual(link.web.newContent, "tracked.txt")
        XCTAssertFalse(link.isEditable)
    }

    func testSaveDuringEditFailureAndDisconnectKeepUnsavedContent() async throws {
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "remote.txt", staged: false,
                           untracked: true, origPath: nil, backend: backend, workspaceIdentity: "ssh:fixture")
        try await wait { !diff.isLoading }
        diff.updateEditedContent(fileID: "remote.txt", contents: "first😀\r\n")
        let saving = Task { await diff.save() }
        try await wait { await backend.writing }
        diff.updateEditedContent(fileID: "remote.txt", contents: "second🪨\r\n")
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
        XCTAssertFalse(diff.web.canEdit)
        await diff.save()
        XCTAssertEqual(diff.saveError, diff.readOnlyReason)
        let count = await backend.writes
        XCTAssertEqual(count, 3)
        diff.completeEditing(fileID: "remote.txt", contents: "second🪨\r\n")
        XCTAssertEqual(diff.web.newContent, "second🪨\r\n")
        XCTAssertTrue(diff.isDirty)
    }

    func testRealDiffWebHostRendersAndRetainsItsWebView() async throws {
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "render.txt", staged: false,
                           untracked: true, origPath: nil, backend: backend, workspaceIdentity: nil)
        try await wait { !diff.isLoading }
        await DiffWebRoot.materialize(for: diff)
        let surface = try XCTUnwrap(diff.nativeSurface)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func mount() -> NSHostingView<DiffWebRoot> {
            let host = NSHostingView(rootView: DiffWebRoot(diff: diff, surface: surface))
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            return host
        }
        let first = mount()
        try await wait { diff.web.isReady }
        let webView = try XCTUnwrap(findWebView(in: first))
        let renderedText = """
        (() => {
          const text = root => Array.from(root.childNodes).map(node =>
            node.nodeType === Node.TEXT_NODE ? node.textContent :
              text(node.shadowRoot || node)).join('');
          return text(document.body);
        })()
        """
        try await wait {
            let text = try? await webView.evaluateJavaScript(renderedText) as? String
            return text?.contains("baseline") == true
        }
        XCTAssertTrue(findWebView(in: first) === webView)
        first.removeFromSuperview()
        let second = mount()
        await DiffWebRoot.materialize(for: diff)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(diff.nativeSurface === surface)
        XCTAssertTrue(diff.webHostView === webView)
        XCTAssertTrue(findWebView(in: second) === webView)
        XCTAssertTrue(diff.web.isReady)
        let after = try await webView.evaluateJavaScript(renderedText) as? String
        XCTAssertTrue(try XCTUnwrap(after).contains("baseline"))
        second.removeFromSuperview()
    }

    func testReadInFlightCannotReplaceEditingOrDisconnectedContent() async throws {
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "stale.txt", staged: false,
                           untracked: true, origPath: nil, backend: backend, workspaceIdentity: "ssh:fixture")
        try await wait { !diff.isLoading }
        let baseline = diff.web.newContent
        await backend.pauseOneRead()
        diff.reload()
        try await wait { await backend.reading }
        diff.updateEditedContent(fileID: "stale.txt", contents: "editing during read")
        await backend.finishRead(with: Data("stale result".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(diff.isDirty)
        XCTAssertEqual(diff.web.newContent, baseline)

        diff.updateEditedContent(fileID: "stale.txt", contents: baseline)
        XCTAssertFalse(diff.isDirty)
        await backend.pauseOneRead()
        diff.reload()
        try await wait { await backend.reading }
        let project = Project(fallbackName: "disconnected", workspaceConfiguration: .standard)
        diff.reevaluateWorkspace(in: project)
        await backend.finishRead(with: Data("outdated before outage".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotNil(diff.readOnlyReason)
        XCTAssertEqual(diff.web.newContent, baseline)
        XCTAssertFalse(diff.web.canEdit)
    }

    func testDiffRendererInputAndScrollSurviveRemountAndResourcesAreReleased() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("editor.txt")
        let original = (0..<180).map { "line \($0) 中文😀\n" }.joined()
        try Data(original.utf8).write(to: path)
        let diff = DiffTab(repoRoot: directory.path, path: "editor.txt", staged: false,
                           untracked: true, origPath: nil, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await wait { !diff.isLoading }
        var surface: PierreMultiDiffSurface? = PierreMultiDiffSurface()
        weak var releasedSurface = surface
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = container
        var mounted: NSHostingView<PierreMultiDiffView>?
        func mount() {
            mounted = NSHostingView(rootView: PierreMultiDiffView(
                files: [.init(id: "editor.txt", name: "editor.txt", oldContents: "", newContents: original, isEditable: true)],
                surface: surface, diffStyle: .constant(.unified), overflowMode: .constant(.scroll),
                onFileEditChange: { [weak diff] fileID, text in diff?.updateEditedContent(fileID: fileID, contents: text) }
            ))
            mounted?.frame = container.bounds
            if let mounted { container.addSubview(mounted) }
            window.orderFront(nil)
            mounted?.layoutSubtreeIfNeeded()
        }
        mount()
        try await wait {
            guard let mounted else { return false }
            return self.findWebView(in: mounted) != nil
        }
        let webView = try XCTUnwrap(findWebView(in: try XCTUnwrap(mounted)))
        let locateEditor = """
        (() => {
          const find = root => {
            for (const node of root.querySelectorAll('*')) {
              if (node.getAttribute('contenteditable') === 'true') return node;
              if (node.shadowRoot) { const result = find(node.shadowRoot); if (result) return result; }
            }
          };
          window.fixtureEditor = find(document);
          return !!window.fixtureEditor;
        })()
        """
        try await wait { (try? await webView.evaluateJavaScript(locateEditor) as? Bool) == true }
        _ = try await webView.evaluateJavaScript("fixtureEditor.focus(); const caret = document.createRange(); caret.setStart(fixtureEditor.querySelector('[data-char]').firstChild, 0); caret.collapse(true); const selection = fixtureEditor.getRootNode().getSelection?.() || window.getSelection(); selection.removeAllRanges(); selection.addRange(caret)")
        _ = try await webView.evaluateJavaScript("fixtureEditor.dispatchEvent(new FocusEvent('focus')); document.dispatchEvent(new Event('selectionchange'))")
        try await Task.sleep(for: .milliseconds(100))
        _ = try await webView.evaluateJavaScript("fixtureEditor.dispatchEvent(new InputEvent('beforeinput', {inputType:'insertText',data:'E',bubbles:true,cancelable:true,composed:true}))")
        try await wait { diff.isDirty }
        _ = try await webView.evaluateJavaScript("const viewport = document.getElementById('diff-container'); viewport.dispatchEvent(new WheelEvent('wheel', {deltaY:700,bubbles:true})); viewport.scrollTop = 700")
        _ = try await webView.callAsyncJavaScript(
            "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
            in: nil, contentWorld: .page
        )
        let scrollBefore = try await webView.evaluateJavaScript("document.getElementById('diff-container').scrollTop") as? Double
        let geometryBefore = try await webView.evaluateJavaScript("JSON.stringify({height:innerHeight,range:document.getElementById('diff-container').scrollHeight,client:document.getElementById('diff-container').clientHeight})") as? String
        XCTAssertGreaterThan(try XCTUnwrap(scrollBefore), 0)
        _ = try await webView.evaluateJavaScript("fixtureEditor.blur(); fixtureEditor.dispatchEvent(new FocusEvent('blur'))")
        mounted?.removeFromSuperview()
        mount()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(findWebView(in: try XCTUnwrap(mounted)) === webView)
        let scrollAfter = try await webView.evaluateJavaScript("document.getElementById('diff-container').scrollTop") as? Double
        let geometryAfter = try await webView.evaluateJavaScript("JSON.stringify({height:innerHeight,range:document.getElementById('diff-container').scrollHeight,client:document.getElementById('diff-container').clientHeight})") as? String
        XCTAssertEqual(scrollAfter, scrollBefore)
        XCTAssertEqual(geometryAfter, geometryBefore)
        _ = try await webView.evaluateJavaScript("const returnedViewport=document.getElementById('diff-container'); returnedViewport.dispatchEvent(new WheelEvent('wheel', {deltaY:-700,bubbles:true})); returnedViewport.scrollTop=0")
        _ = try await webView.callAsyncJavaScript(
            "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
            in: nil, contentWorld: .page
        )
        _ = try await webView.evaluateJavaScript(locateEditor)
        let editorText = try await webView.evaluateJavaScript("fixtureEditor.textContent") as? String
        XCTAssertTrue(try XCTUnwrap(editorText).contains("E"))
        _ = try await webView.evaluateJavaScript("fixtureEditor.dispatchEvent(new FocusEvent('focus')); fixtureEditor.dispatchEvent(new KeyboardEvent('keydown',{key:'z',metaKey:true,bubbles:true,cancelable:true,composed:true}))")
        try await wait { !diff.isDirty }
        _ = try await webView.evaluateJavaScript("fixtureEditor.dispatchEvent(new KeyboardEvent('keydown',{key:'z',metaKey:true,shiftKey:true,bubbles:true,cancelable:true,composed:true}))")
        try await wait { diff.isDirty }
        await diff.save()
        XCTAssertFalse(diff.isDirty)
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains("E"))
        mounted?.removeFromSuperview()
        mounted = nil
        surface = nil
        try await wait { releasedSurface == nil }
        XCTAssertNil(webView.navigationDelegate)
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
        let baseline = diff.web.newContent
        await backend.pauseOneRead()
        diff.reload()
        try await wait { await backend.reading }
        diff.setEditing(true)
        XCTAssertTrue(diff.preferences === preferences)
        XCTAssertEqual(defaults.string(forKey: "diffView.mode"), "edit")
        await backend.finishRead(with: Data("stale before editor appeared".utf8))
        try await wait { !diff.isLoading }
        XCTAssertEqual(diff.web.newContent, baseline)
        XCTAssertFalse(diff.isDirty)
        diff.updateEditedContent(fileID: "editing.txt", contents: "current buffer")
        diff.reload()
        XCTAssertEqual(diff.web.newContent, baseline)
        XCTAssertTrue(diff.isDirty)
        diff.setDiffStyle(.split)
        XCTAssertEqual(defaults.string(forKey: "diffView.layout"), "split")
    }
}
