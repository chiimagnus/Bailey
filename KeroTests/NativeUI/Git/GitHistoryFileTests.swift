import AppKit
import STTextView
import SwiftUI
import XCTest
@testable import kero

@MainActor
final class GitHistoryFileTests: XCTestCase {
    private func repository() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.name", "History"],
            ["config", "user.email", "history@example.invalid"],
            ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", "/dev/null"],
        ] {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        return directory
    }

    @discardableResult
    private func git(_ args: [String], in root: URL) throws -> String {
        let result = GitCommandExecution.run(args, in: root.path, timeout: 20)
        guard result.status == 0 else {
            XCTFail(result.stderr)
            throw WorkspaceError.notFound
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(18))
        }
    }

    private func nativeText(in view: NSView) -> DiffTextView? {
        if let found = view as? DiffTextView { return found }
        return view.subviews.lazy.compactMap { self.nativeText(in: $0) }.first
    }

    func testRevisionIsNativeReadonlyTextOfSelectedCommitEvenWithSharedEditPreference() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("history one\n".utf8).write(to: root.appendingPathComponent("note.txt"))
        try Data().write(to: root.appendingPathComponent("empty.txt"))
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "first revision"], in: root)
        let selected = try git(["rev-parse", "HEAD"], in: root)
        try Data("history two\n".utf8).write(to: root.appendingPathComponent("note.txt"))
        _ = try git(["commit", "-qam", "updated"], in: root)
        let defaults = UserDefaults(suiteName: "kero-history-" + UUID().uuidString)!
        let preferences = DiffViewPreferences(defaults: defaults)
        preferences.prefersEditing = true
        let revision = DiffTab(repoRoot: root.path, path: "note.txt",
            source: .revision(hash: selected), untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil, preferences: preferences)
        let empty = DiffTab(repoRoot: root.path, path: "empty.txt",
            source: .revision(hash: selected), untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil, preferences: preferences)
        try await wait { !revision.isLoading && !empty.isLoading }
        XCTAssertNil(revision.error)
        XCTAssertEqual(revision.newContent, "history one\n")
        XCTAssertEqual(revision.oldContent, "")
        XCTAssertFalse(revision.isEditableNow)
        XCTAssertFalse(revision.isEditing)
        XCTAssertNil(empty.error)
        XCTAssertEqual(empty.newContent, "")
        let window = NSWindow(
            contentRect: .init(x: -1300, y: -1300, width: 680, height: 470),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: revision))
        window.contentView = host
        window.orderFront(nil)
        try await wait { self.nativeText(in: host) != nil }
        let editor = try XCTUnwrap(nativeText(in: host))
        XCTAssertEqual(editor.text, "history one\n")
        XCTAssertFalse(editor.isEditable)
        window.contentView = NSHostingView(rootView: DiffViewerView(diff: empty))
        try await wait { empty.nativeSurface != nil && self.nativeText(in: window.contentView!) != nil }
        XCTAssertFalse(try XCTUnwrap(nativeText(in: window.contentView!)).isEditable)
    }

    func testRevisionToWorktreeFollowsRenameAndRefreshesWithoutWritingHistoricalBlob() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old bytes\n".utf8).write(to: root.appendingPathComponent("old.txt"))
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "old"], in: root)
        let selected = try git(["rev-parse", "HEAD"], in: root)
        _ = try git(["mv", "old.txt", "new.txt"], in: root)
        _ = try git(["commit", "-qm", "rename"], in: root)
        try Data("new bytes\n".utf8).write(to: root.appendingPathComponent("new.txt"))
        let diff = DiffTab(repoRoot: root.path, path: "old.txt",
            source: .revisionWorktree(hash: selected), untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await wait { !diff.isLoading }
        XCTAssertNil(diff.error)
        XCTAssertEqual(diff.oldContent, "old bytes\n")
        XCTAssertEqual(diff.newContent, "new bytes\n")
        XCTAssertEqual(diff.resolvedWorktreePath, "new.txt")
        XCTAssertFalse(diff.isEditableNow)
        try Data("edited again\n".utf8).write(to: root.appendingPathComponent("new.txt"))
        diff.refreshWhenSelected()
        try await wait { diff.newContent == "edited again\n" }
        XCTAssertEqual(try git(["show", selected + ":old.txt"], in: root), "old bytes")
    }

    func testMissingSelectedRevisionReportsErrorButRootAndDeletedSidesMayBeEmpty() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first\n".utf8).write(to: root.appendingPathComponent("note.txt"))
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "first"], in: root)
        let first = try git(["rev-parse", "HEAD"], in: root)
        let missing = DiffTab(repoRoot: root.path, path: "not-in-commit.txt",
            source: .revision(hash: first), untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        let rootAdded = DiffTab(repoRoot: root.path, path: "note.txt",
            source: .commit(hash: first, parent: nil, status: "A"), untracked: false,
            origPath: nil, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await wait { !missing.isLoading && !rootAdded.isLoading }
        XCTAssertNotNil(missing.error, "A failed selected revision is not an empty diff")
        XCTAssertEqual(rootAdded.oldContent, "")
        XCTAssertEqual(rootAdded.newContent, "first\n")
        XCTAssertNil(rootAdded.error)
        _ = try git(["rm", "note.txt"], in: root)
        _ = try git(["commit", "-qm", "deleted"], in: root)
        let removed = try git(["rev-parse", "HEAD"], in: root)
        let deletion = DiffTab(repoRoot: root.path, path: "note.txt",
            source: .commit(hash: removed, parent: first, status: "D"), untracked: false,
            origPath: nil, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await wait { !deletion.isLoading }
        XCTAssertEqual(deletion.oldContent, "first\n")
        XCTAssertEqual(deletion.newContent, "")
        XCTAssertNil(deletion.error)
    }

    func testResetHistoricalBinaryFileUpdatesIndexAndWorktreeWithoutChangingHead() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("binary file.bin")
        let historical = Data([0, 7, 255, 64, 12])
        try historical.write(to: path)
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "binary historical"], in: root)
        let revision = try git(["rev-parse", "HEAD"], in: root)
        try Data([88, 77, 66]).write(to: path)
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "binary new"], in: root)
        let currentHead = try git(["rev-parse", "HEAD"], in: root)
        try Data([22, 11]).write(to: path)
        _ = try git(["add", "."], in: root)
        try Data([33, 44]).write(to: path)

        let model = GitStatusModel()
        model.sync(root: root.path)
        try await wait { model.hasResolvedStatus && !model.isBusy && !model.isRefreshing }
        let commit = try XCTUnwrap(model.recentCommits.first(where: { $0.hash == revision }))
        XCTAssertTrue(commit.files.contains { $0.path == path.lastPathComponent })
        let initialState = await model.historicalFileState(
            path.lastPathComponent, target: model.actionTarget())
        let state = try XCTUnwrap(initialState)
        model.resetHistoricalFile(path.lastPathComponent, at: commit,
                                  target: model.actionTarget(), expectedFileState: state)
        try await wait { !model.isBusy && model.operation != nil && model.operation?.finishedAt != nil }
        XCTAssertNil(model.lastError, model.lastError ?? "Failed to reset")
        XCTAssertEqual(try Data(contentsOf: path), historical)
        let staged = GitCommandExecution.runData(
            ["show", ":binary file.bin"], in: root.path, stdoutLimit: 128
        )
        XCTAssertEqual(staged.status, 0)
        XCTAssertEqual(staged.stdout, historical)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root), currentHead)
    }

    func testResetHistoricalFileRefusesStaleWorkingBytesAfterConfirmation() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("target.txt")
        try Data("original\n".utf8).write(to: path)
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "original"], in: root)
        let oldRevision = try git(["rev-parse", "HEAD"], in: root)
        try Data("new committed\n".utf8).write(to: path)
        _ = try git(["commit", "-qam", "changed"], in: root)
        let model = GitStatusModel()
        model.sync(root: root.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let commit = try XCTUnwrap(model.recentCommits.first { $0.hash == oldRevision })
        let captured = await model.historicalFileState("target.txt", target: model.actionTarget())
        let state = try XCTUnwrap(captured)
        try Data("user changed after opening dialog\n".utf8).write(to: path)
        model.resetHistoricalFile("target.txt", at: commit,
                                  target: model.actionTarget(), expectedFileState: state)
        try await wait { !model.isBusy && model.operation?.finishedAt != nil }
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8),
                       "user changed after opening dialog\n")
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root),
                       try git(["rev-parse", "main"], in: root))
    }

    func testProjectRestoresDistinctNativeTabsForHistoricalDiffModes() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("revision\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "original"], in: root)
        let revision = try git(["rev-parse", "HEAD"], in: root)
        try Data("new\n".utf8).write(to: root.appendingPathComponent("file.txt"))

        let project = Project(fallbackName: "Historical Native Tabs",
                              workspaceConfiguration: .standard)
        let source: [DiffTab.Source] = [
            .commit(hash: revision, parent: nil, status: "A"),
            .revision(hash: revision),
            .revisionWorktree(hash: revision),
        ]
        for kind in source {
            project.openHistoricalDiff(repoRoot: root.path, path: "file.txt",
                                       source: kind, origPath: nil)
        }
        XCTAssertEqual(project.tabs.count, 3)
        project.openHistoricalDiff(repoRoot: root.path, path: "file.txt",
                                   source: source[1], origPath: nil)
        XCTAssertEqual(project.tabs.count, 3, "Only identical source modes may reuse a tab")
        let snapshots: [SessionSnapshot.ProjectSnapshot.ContentSnapshot] = source.map { kind in
            .diff(repoRoot: root.path, path: "file.txt", source: kind,
                  untracked: false, origPath: nil)
        }
        let decoded = try JSONDecoder().decode(
            [SessionSnapshot.ProjectSnapshot.ContentSnapshot].self,
            from: JSONEncoder().encode(snapshots))
        let restored = Project(fallbackName: "restored", workspaceConfiguration: .standard)
        for content in decoded {
            _ = restored.restoreTab(from: .init(
                content: content, historyKey: nil, customName: nil,
                contextSessionIndex: nil))
        }
        XCTAssertEqual(restored.tabs.count, 3)
        for (tab, kind) in zip(restored.tabs, source) {
            guard case .diff(let diff) = tab.content else {
                XCTFail("Historical file restored as non-Diff content")
                continue
            }
            XCTAssertEqual(diff.source, kind)
            try await wait { !diff.isLoading }
            XCTAssertNil(diff.error)
            XCTAssertFalse(diff.isEditableNow)
        }
    }

    func testExpandingCommitLoadsBinaryMetadataOnceAndPreservesGitRenamePaths() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("original binary.bin"))
        try Data("normal text\n".utf8).write(to: root.appendingPathComponent("text.txt"))
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "original"], in: root)
        let first = try git(["rev-parse", "HEAD"], in: root)
        let model = GitStatusModel()
        model.sync(root: root.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let commit = try XCTUnwrap(model.recentCommits.first { $0.hash == first })
        model.loadHistoricalBinaryPaths(for: commit)
        try await wait { model.historicalBinaryPaths[first] != nil }
        XCTAssertTrue(model.isHistoricalBinaryFile(commit: commit, path: "original binary.bin"))
        XCTAssertFalse(model.isHistoricalBinaryFile(commit: commit, path: "text.txt"))
        _ = try git(["mv", "original binary.bin", "renamed binary.bin"], in: root)
        _ = try git(["commit", "-qm", "renamed binary"], in: root)
        let second = try git(["rev-parse", "HEAD"], in: root)
        model.refresh()
        try await wait { !model.isRefreshing && model.recentCommits.first?.hash == second }
        let renamed = try XCTUnwrap(model.recentCommits.first)
        model.loadHistoricalBinaryPaths(for: renamed)
        try await wait { model.historicalBinaryPaths[second] != nil }
        XCTAssertTrue(model.isHistoricalBinaryFile(commit: renamed, path: "renamed binary.bin"))
    }

    func testSelectedBinaryAndLargeRevisionsExplainWhyTheyCannotRenderAsText() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("binary.bin"))
        try Data(repeating: 66, count: (5 << 20) + 1).write(to: root.appendingPathComponent("large.txt"))
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "binary and large"], in: root)
        let selected = try git(["rev-parse", "HEAD"], in: root)
        for (path, message) in [
            ("binary.bin", String(localized: "Binary file", table: "Git")),
            ("large.txt", String(localized: "File is too large to diff", table: "Git"))
        ] {
            let diff = DiffTab(repoRoot: root.path, path: path,
                source: .revision(hash: selected), untracked: false, origPath: nil,
                backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await wait { !diff.isLoading }
            XCTAssertEqual(diff.error, message,
                           "The native text view must not show invalid bytes as empty content: " + path)
        }
    }
}
