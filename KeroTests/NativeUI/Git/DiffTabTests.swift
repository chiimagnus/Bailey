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
@Observable
private final class DiffSelectionFixture {
    var selected: DiffTab
    init(_ selected: DiffTab) { self.selected = selected }
}

private struct DiffSelectionFixtureView: View {
    let selection: DiffSelectionFixture
    var body: some View { DiffViewerView(diff: selection.selected) }
}

@MainActor
final class DiffTabTests: XCTestCase {
    private func findNativeSurface(in view: NSView) -> DiffNativeSurface? {
        if let surface = view as? DiffNativeSurface { return surface }
        return view.subviews.lazy.compactMap { self.findNativeSurface(in: $0) }.first
    }

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

    func testSwitchingLoadedDiffTabsKeepsEachNativeDocument() async throws {
        let suite = "kero-diff-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let aBackend = DiffWorkspaceFixture()
        let bBackend = DiffWorkspaceFixture()
        let a = DiffTab(repoRoot: "/fixture", path: "A.txt", staged: false,
                        untracked: true, origPath: nil, backend: aBackend,
                        workspaceIdentity: nil, preferences: preferences)
        try await wait { a.display != nil }

        let selection = DiffSelectionFixture(a)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 570),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffSelectionFixtureView(selection: selection))
        window.contentView = host
        window.orderFront(nil)
        try await wait { self.findNativeSurface(in: host) === a.nativeSurface && a.nativeSurface != nil }

        await bBackend.pauseOneRead()
        let b = DiffTab(repoRoot: "/fixture", path: "B.txt", staged: false,
                        untracked: true, origPath: nil, backend: bBackend,
                        workspaceIdentity: nil, preferences: preferences)
        selection.selected = b
        try await wait { await bBackend.reading }
        await bBackend.finishRead(with: Data("different B document".utf8))
        try await wait { b.display != nil && self.findNativeSurface(in: host) === b.nativeSurface && b.nativeSurface != nil }
        XCTAssertNotEqual(a.newContent, b.newContent)

        selection.selected = a
        try await wait { self.findNativeSurface(in: host)?.diff === a }
        XCTAssertTrue(findNativeSurface(in: host) === a.nativeSurface,
                      "Returning A must mount A's own TextKit document, not B's")
        selection.selected = b
        try await wait { self.findNativeSurface(in: host)?.diff === b }
        XCTAssertTrue(findNativeSurface(in: host) === b.nativeSurface)
    }

    func testNativeDiffEditorFocusLossSavesThroughBackend() async throws {
        let suite = "kero-diff-focus-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DiffViewPreferences(defaults: defaults)
        preferences.prefersEditing = true
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "editable.txt", staged: false,
                           untracked: true, origPath: nil, backend: backend,
                           workspaceIdentity: nil, preferences: preferences)
        try await wait { !diff.isLoading && diff.isEditable }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 570),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await wait { diff.nativeSurface != nil }
        let surface = try XCTUnwrap(diff.nativeSurface)
        let editor = try XCTUnwrap(findNativeTextView(in: surface, editable: true))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("new🙂", replacementRange: NSRange(location: 0, length: 0))
        try await wait { diff.isDirty }
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await wait { await backend.writing }
        await backend.finishWrite()
        try await wait { !diff.isDirty }
        let saved = await backend.stored()
        XCTAssertEqual(saved, Data("new🙂baseline😀\r\n".utf8))
    }

    func testFocusTriggeredDiffSavePreservesNewestBufferAndFailure() async throws {
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "editable.txt", staged: false,
                           untracked: true, origPath: nil, backend: backend,
                           workspaceIdentity: "ssh:fixture")
        try await wait { !diff.isLoading && diff.isEditable }
        diff.updateEditedContent("first 中文😀")
        let writesBeforeFocusLoss = await backend.writes
        XCTAssertEqual(writesBeforeFocusLoss, 0, "Editing alone must not automatically write")
        diff.autoSaveOnFocusLoss()
        try await wait { await backend.writing }
        diff.updateEditedContent("second 中文🪨")
        diff.autoSaveOnFocusLoss()
        await backend.finishWrite()
        try await wait {
            let stored = await backend.stored()
            let writes = await backend.writes
            return stored == Data("first 中文😀".utf8) && writes == 2
        }
        XCTAssertTrue(diff.isDirty)
        await backend.finishWrite()
        try await wait { !diff.isDirty }
        let latest = await backend.stored()
        XCTAssertEqual(latest, Data("second 中文🪨".utf8))

        diff.updateEditedContent("unsaved during outage")
        diff.autoSaveOnFocusLoss()
        try await wait { await backend.writing }
        await backend.finishWrite(failing: true)
        try await wait { diff.saveError != nil }
        XCTAssertTrue(diff.isDirty)
        XCTAssertEqual(diff.editedNewContent, "unsaved during outage")
        let retained = await backend.stored()
        XCTAssertEqual(retained, Data("second 中文🪨".utf8))
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
        let domain = "kero-native-render-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        preferences.prefersEditing = false
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "render.txt", staged: false,
                           untracked: true, origPath: nil, backend: backend,
                           workspaceIdentity: nil, preferences: preferences)
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


    func testBackgroundSyntaxCapturesReachNativeDiffColors() async throws {
        for (path, source) in [
            ("sample.swift", "let answer = 42\n"),
            ("View.tsx", "const View = () => <main title=\"hi\">Hello</main>;\n"),
        ] {
            let resolved = await DiffSyntaxHighlighter.context(for: path)
            let context = try XCTUnwrap(resolved, "Missing grammar for \(path)")
            let captures = await Task.detached(priority: .userInitiated) {
                DiffSyntaxHighlighter.captures(text: source, context: context)
            }.value
            XCTAssertFalse(captures.isEmpty, "Syntax parser returned no highlights for \(path)")
            XCTAssertTrue(captures.allSatisfy {
                $0.range.length > 0 && NSMaxRange($0.range) <= source.utf16.count
            })
            let colored = DiffSyntaxHighlighter.colors(for: captures)
            XCTAssertEqual(colored.count, captures.count)
            let computed = DiffComputation.compute(oldText: "", newText: source)
            let rendered = DiffSyntaxHighlighter.attributedDocument(
                computed.unified, oldRuns: [], newRuns: colored,
                baseAttributes: [.foregroundColor: NSColor.textColor]
            )
            XCTAssertEqual(rendered.string, computed.unified.text)
            XCTAssertFalse(colored.isEmpty, "No native foreground colors for \(path)")
        }
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

    func testCollapsedDiffAccessibilityPressReachesNativeExpansion() async throws {
        let oldLines = (0..<240).map { "line \($0)" }
        var newLines = oldLines
        newLines[120] = "line 120 changed"
        let old = oldLines.joined(separator: "\n") + "\n"
        let new = newLines.joined(separator: "\n") + "\n"
        let compared = DiffComputation.build(
            core: DiffCore.compute(oldText: old, newText: new), expansions: [:]
        )
        XCTAssertTrue(compared.unified.rows.contains { $0.collapsed != nil })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        window.contentView = pane
        window.orderFront(nil)
        pane.setReviewDocument(
            NSAttributedString(string: compared.unified.text),
            decorations: DiffDecorations.review(compared.unified)
        )
        pane.layoutSubtreeIfNeeded()
        let gutter = try XCTUnwrap(pane.subviews.compactMap { $0 as? DiffGutterView }.first)
        var expanded: DiffCollapsedRun?
        pane.onExpandCollapsedRun = { expanded = $0 }
        try await wait {
            pane.layoutSubtreeIfNeeded()
            return (gutter.accessibilityChildren()?.count ?? 0) > 0
        }
        let controls = try XCTUnwrap(gutter.accessibilityChildren())
        let first = try XCTUnwrap(controls.first as? NSAccessibilityElement)
        XCTAssertTrue(first.accessibilityPerformPress())
        let activated = try XCTUnwrap(expanded)
        XCTAssertTrue(compared.unified.rows.contains {
            $0.collapsed?.runIndex == activated.runIndex
        })
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

        // The toolbar can update independently of the native surface. Its
        // Observation change must still switch the actual visible TextKit pane.
        diff.setEditing(true)
        try await wait {
            let visible = surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }
            return visible.count == 1 && visible[0].textView.isEditable
        }
        let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? DiffCodePaneView }
            .first { !$0.isHidden && $0.textView.isEditable })
        XCTAssertEqual(editor.textView.text, diff.newContent)

        diff.setEditing(false)
        try await wait {
            let visible = surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }
            return visible.count == 1 && !visible[0].textView.isEditable
        }
        XCTAssertFalse(firstUnified.isHidden)
    }

    func testSplitDiffSynchronizesHorizontalAndVerticalScrolling() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wide.txt")
        let oldText = ([String(repeating: "a", count: 1100)]
            + (0..<150).map { "before \($0)" }).joined(separator: "\n") + "\n"
        let newText = ([String(repeating: "b", count: 1400)]
            + (0..<150).map { "after \($0)" }).joined(separator: "\n") + "\n"
        try Data(oldText.utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["add", "wide.txt"], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: directory.path).status, 0)
        try Data(newText.utf8).write(to: file)

        let suite = "kero-diff-scroll-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DiffViewPreferences(defaults: defaults)
        preferences.diffStyle = .split
        preferences.prefersEditing = false
        let diff = DiffTab(
            repoRoot: directory.path, path: "wide.txt", staged: false,
            untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: nil, preferences: preferences
        )
        try await wait { !diff.isLoading && diff.display != nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.contentView = host
        window.orderFront(nil)

        try await wait {
            host.layoutSubtreeIfNeeded()
            guard let surface = diff.nativeSurface else { return false }
            surface.layoutSubtreeIfNeeded()
            let panes = surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }
            guard panes.count == 2 else { return false }
            return panes.allSatisfy { pane in
                pane.layoutSubtreeIfNeeded()
                return (pane.scrollView.documentView?.frame.width ?? 0)
                    > pane.scrollView.contentView.bounds.width + 300
            }
        }
        let surface = try XCTUnwrap(diff.nativeSurface)
        let panes = surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }
        let left = try XCTUnwrap(panes.first)
        let right = try XCTUnwrap(panes.last)
        XCTAssertFalse(left === right)

        let leftClip = left.scrollView.contentView
        let rightClip = right.scrollView.contentView
        leftClip.scroll(to: NSPoint(x: 120, y: 60))
        left.scrollView.reflectScrolledClipView(leftClip)
        XCTAssertEqual(leftClip.bounds.origin.x, 120, accuracy: 1)
        XCTAssertEqual(rightClip.bounds.origin.x, leftClip.bounds.origin.x, accuracy: 1)
        XCTAssertEqual(rightClip.bounds.origin.y, leftClip.bounds.origin.y, accuracy: 1)

        rightClip.scroll(to: NSPoint(x: 240, y: 100))
        right.scrollView.reflectScrolledClipView(rightClip)
        XCTAssertEqual(rightClip.bounds.origin.x, 240, accuracy: 1)
        XCTAssertEqual(leftClip.bounds.origin.x, rightClip.bounds.origin.x, accuracy: 1)
        XCTAssertEqual(leftClip.bounds.origin.y, rightClip.bounds.origin.y, accuracy: 1)

        // A longer right-hand line can scroll farther without being pulled
        // back by the shorter left-hand document.
        let leftEnd = (left.scrollView.documentView?.frame.width ?? 0) - leftClip.bounds.width
        let rightEnd = (right.scrollView.documentView?.frame.width ?? 0) - rightClip.bounds.width
        XCTAssertGreaterThan(rightEnd, leftEnd + 200)
        rightClip.scroll(to: NSPoint(x: leftEnd + 120, y: 100))
        right.scrollView.reflectScrolledClipView(rightClip)
        XCTAssertEqual(leftClip.bounds.origin.x, leftEnd, accuracy: 2)
        XCTAssertEqual(rightClip.bounds.origin.x, leftEnd + 120, accuracy: 2)

        diff.setDiffStyle(.unified)
        try await wait { surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }.count == 1 }
        diff.setDiffStyle(.split)
        try await wait { surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }.count == 2 }
        XCTAssertEqual(leftClip.bounds.origin.x, leftEnd, accuracy: 2)
        XCTAssertEqual(rightClip.bounds.origin.x, leftEnd + 120, accuracy: 2)
        leftClip.scroll(to: NSPoint(x: 30, y: 0))
        left.scrollView.reflectScrolledClipView(leftClip)
        XCTAssertEqual(rightClip.bounds.origin.x, 30, accuracy: 1)
    }

    func testReadInFlightCannotReplaceEditingOrDisconnectedContent() async throws {
        let domain = "kero-native-stale-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        preferences.prefersEditing = false
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "stale.txt", staged: false,
                           untracked: true, origPath: nil, backend: backend,
                           workspaceIdentity: "ssh:fixture", preferences: preferences)
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

    func testGitReloadUpdatesCleanMountedEditSurfaceWithoutLosingDirtyText() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("reload.txt")
        try Data("before\n".utf8).write(to: file)
        let domain = "kero-git-reload-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        preferences.prefersEditing = true
        let diff = DiffTab(repoRoot: directory.path, path: "reload.txt", staged: false,
                           untracked: true, origPath: nil, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil, preferences: preferences)
        try await wait { !diff.isLoading && diff.isEditable }
        let window = NSWindow(contentRect: .init(x: -1200, y: -1200, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.orderFront(nil)
        try await wait { self.findNativeTextView(in: window.contentView!, editable: true) != nil }
        let editor = try XCTUnwrap(findNativeTextView(in: window.contentView!, editable: true))
        try Data("after Git\n".utf8).write(to: file)
        diff.reload(afterGitAction: true)
        try await wait { !diff.isLoading && editor.text == "after Git\n" }
        XCTAssertTrue(findNativeTextView(in: window.contentView!, editable: true) === editor)
        editor.insertText("draft ", replacementRange: .init(location: 0, length: 0))
        try await wait { diff.isDirty }
        try Data("external\n".utf8).write(to: file)
        diff.reload(afterGitAction: true)
        XCTAssertEqual(editor.text, "draft after Git\n")
        XCTAssertTrue(diff.isDirty)
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
