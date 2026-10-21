import AppKit
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
final class GitHistoryFileTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    private func repository() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-history-" + UUID().uuidString)
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
        let defaults = UserDefaults(suiteName: "bailey-history-" + UUID().uuidString)!
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
        XCTAssertFalse(editor.isAccessibilitySelectorAllowed(#selector(editor.setAccessibilityValue(_:))))
        editor.setAccessibilityValue("unexpected accessibility edit")
        XCTAssertEqual(editor.text, "history one\n")
        window.contentView = NSHostingView(rootView: DiffViewerView(diff: empty))
        try await wait { empty.nativeSurface != nil && self.nativeText(in: window.contentView!) != nil }
        XCTAssertFalse(try XCTUnwrap(nativeText(in: window.contentView!)).isEditable)
    }

    func testNativeDiffAccessibilityAllowsOnlyEditableTextChanges() {
        let editor = DiffTextView()
        editor.frame = .init(x: 0, y: 0, width: 300, height: 150)
        editor.text = "original"
        for editable in [false, true, false] {
            editor.isEditable = editable
            XCTAssertEqual(editor.isAccessibilitySelectorAllowed(#selector(editor.setAccessibilityValue(_:))), editable)
            let previous = editor.text
            let replacement = editable ? "editable change" : "readonly change"
            editor.setAccessibilityValue(replacement)
            XCTAssertEqual(editor.text, editable ? replacement : previous)
            XCTAssertTrue(editor.isSelectable)
        }
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

    func testHistoricalDiffPreviewKeepsGitActiveAndExplicitActivationStillWorks() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.txt")
        try Data("baseline\n".utf8).write(to: file)
        _ = try git(["add", "history.txt"], in: root)
        _ = try git(["commit", "-qm", "base"], in: root)
        let base = try git(["rev-parse", "HEAD"], in: root)
        try Data("updated\n".utf8).write(to: file)
        _ = try git(["commit", "-qam", "update"], in: root)
        let update = try git(["rev-parse", "HEAD"], in: root)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        project.dock.select(.git)
        let gitGroup = try XCTUnwrap(project.dock.group(containing: .git))
        let initialGroup = project.dock.activeGroupID

        func open(activating: Bool) {
            manager.openCommitDiff(
                repoRoot: root.path, path: "history.txt", commitHash: update,
                parentHash: base, status: "M", origPath: nil,
                activating: activating
            )
        }
        open(activating: false)
        XCTAssertEqual(project.dock.activeGroupID, initialGroup)
        guard case .diff(let diff)? = project.selectedTab?.content else {
            return XCTFail("Historical preview must create a DiffTab")
        }
        try await wait { diff.hasLoadedContent }
        XCTAssertEqual(diff.oldContent, "baseline\n")
        XCTAssertEqual(diff.newContent, "updated\n")
        XCTAssertEqual(diff.source, .commit(hash: update, parent: base, status: "M"))
        XCTAssertEqual(project.dock.activeGroupID, gitGroup.id)
        open(activating: false)
        XCTAssertEqual(project.tabs.count, 1, "Reopening identical history must reuse the Diff")
        guard case .diff(let same)? = project.selectedTab?.content else {
            return XCTFail("Expected reused DiffTab")
        }
        XCTAssertTrue(same === diff)
        XCTAssertEqual(project.dock.activeGroupID, gitGroup.id)
        open(activating: true)
        XCTAssertNotEqual(project.dock.activeGroupID, gitGroup.id,
                          "Explicit activation must focus the Diff's visible group")
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root), update)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "updated\n")
    }

    func testReopeningLoadedImmutableRevisionDoesNotRepeatGitRead() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("immutable text\n".utf8).write(to: root.appendingPathComponent("note.txt"))
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "first"], in: root)
        let hash = try git(["rev-parse", "HEAD"], in: root)
        let project = Project(fallbackName: "Historical reuse", workspaceConfiguration: .standard)
        project.customDirectory = root.path
        project.openHistoricalDiff(
            repoRoot: root.path, path: "note.txt", source: .revision(hash: hash), origPath: nil
        )
        guard case .diff(let old)? = project.selectedTab?.content else {
            return XCTFail("Missing revision tab")
        }
        try await wait { !old.isLoading && old.newContent == "immutable text\n" }
        let gitFolder = root.appendingPathComponent(".git")
        let suspended = root.appendingPathComponent(".git-suspended")
        try FileManager.default.moveItem(at: gitFolder, to: suspended)
        defer { try? FileManager.default.moveItem(at: suspended, to: gitFolder) }
        project.openHistoricalDiff(
            repoRoot: root.path, path: "note.txt", source: .revision(hash: hash), origPath: nil
        )
        guard case .diff(let selected)? = project.selectedTab?.content else {
            return XCTFail("Missing reused revision tab")
        }
        XCTAssertTrue(selected === old)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(old.error, "Immutable content already loaded must not be requeried on another click")
        XCTAssertEqual(old.newContent, "immutable text\n")
    }

    func testUnmergedWorktreeUsesStageTwoAndPreservesConflictStatus() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conflict.txt")
        try Data("base\n".utf8).write(to: file)
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "base"], in: root)
        _ = try git(["checkout", "-qb", "other"], in: root)
        try Data("theirs\n".utf8).write(to: file)
        _ = try git(["commit", "-qam", "other"], in: root)
        _ = try git(["checkout", "-q", "main"], in: root)
        try Data("ours\n".utf8).write(to: file)
        _ = try git(["commit", "-qam", "ours"], in: root)
        let merge = GitCommandExecution.run(["merge", "other"], in: root.path)
        XCTAssertNotEqual(merge.status, 0)
        let conflict = DiffTab(
            repoRoot: root.path, path: "conflict.txt", source: .worktree,
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !conflict.isLoading }
        XCTAssertNil(conflict.error)
        XCTAssertTrue(conflict.isUnmerged)
        XCTAssertEqual(conflict.oldContent, "ours\n")
        XCTAssertTrue(conflict.newContent.contains("<<<<<<<"))
    }

    func testUnbornIndexAndLiteralSpecialPathResolveCorrectBlobs() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "folder/odd\tline\nname:colon.txt"
        let directory = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(name)
        let first = "内容👋\r\n"
        try Data(first.utf8).write(to: file)
        _ = try git(["add", "--", name], in: root)
        let unborn = DiffTab(
            repoRoot: root.path, path: name, source: .staged,
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !unborn.isLoading }
        XCTAssertNil(unborn.error)
        XCTAssertEqual(unborn.oldContent, "")
        XCTAssertEqual(Data(unborn.newContent.utf8), Data(first.utf8))
        _ = try git(["commit", "-qm", "first"], in: root)
        let hash = try git(["rev-parse", "HEAD"], in: root)
        let historical = DiffTab(
            repoRoot: root.path, path: name, source: .revision(hash: hash),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !historical.isLoading }
        XCTAssertNil(historical.error)
        XCTAssertEqual(Data(historical.newContent.utf8), Data(first.utf8))
        let updated = "新的行🪨\r\n"
        try Data(updated.utf8).write(to: file)
        _ = try git(["add", "--", name], in: root)
        let staged = DiffTab(
            repoRoot: root.path, path: name, source: .staged,
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !staged.isLoading }
        XCTAssertNil(staged.error)
        XCTAssertEqual(Data(staged.oldContent.utf8), Data(first.utf8))
        XCTAssertEqual(Data(staged.newContent.utf8), Data(updated.utf8))
    }

    func testReadFailureDoesNotEraseAlreadyLoadedHistoricalText() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("historical text\n".utf8).write(to: root.appendingPathComponent("note.txt"))
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "baseline"], in: root)
        let hash = try git(["rev-parse", "HEAD"], in: root)
        let tab = DiffTab(
            repoRoot: root.path, path: "note.txt",
            source: .revision(hash: hash), untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !tab.isLoading && tab.newContent == "historical text\n" }
        let gitFolder = root.appendingPathComponent(".git")
        let suspended = root.appendingPathComponent(".git-suspended")
        try FileManager.default.moveItem(at: gitFolder, to: suspended)
        defer { try? FileManager.default.moveItem(at: suspended, to: gitFolder) }
        tab.reload()
        try await wait { !tab.isLoading }
        XCTAssertNotNil(tab.error)
        XCTAssertEqual(tab.newContent, "historical text\n")
        XCTAssertEqual(tab.display?.computation.unified.text, nil,
                       "Plain revision uses its native text rather than a synthetic diff")
    }

    func testSHA256RepositoryResolvesImmutableBlobsForHistoryIndexAndWorktree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-history-sha256-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try git(["init", "-q", "-b", "main", "--object-format=sha256"], in: root)
        _ = try git(["config", "user.name", "History"], in: root)
        _ = try git(["config", "user.email", "history@example.invalid"], in: root)
        _ = try git(["config", "commit.gpgsign", "false"], in: root)
        _ = try git(["config", "core.hooksPath", "/dev/null"], in: root)

        let path = "unicode-甲😀.txt"
        let file = root.appendingPathComponent(path)
        try Data("base\r\n".utf8).write(to: file)
        _ = try git(["add", path], in: root)
        _ = try git(["commit", "-qm", "base"], in: root)
        let revision = try git(["rev-parse", "HEAD"], in: root)
        XCTAssertEqual(revision.utf8.count, 64)

        try Data("staged\r\n".utf8).write(to: file)
        _ = try git(["add", path], in: root)
        try Data("worktree\r\n".utf8).write(to: file)
        let history = DiffTab(
            repoRoot: root.path, path: path, source: .revision(hash: revision),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        let staged = DiffTab(
            repoRoot: root.path, path: path, source: .staged,
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        let worktree = DiffTab(
            repoRoot: root.path, path: path, source: .worktree,
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !history.isLoading && !staged.isLoading && !worktree.isLoading }
        for tab in [history, staged, worktree] {
            XCTAssertNil(tab.error, tab.error ?? "64-byte OID should be supported")
        }
        XCTAssertEqual(history.newContent, "base\r\n")
        XCTAssertEqual(staged.oldContent, "base\r\n")
        XCTAssertEqual(staged.newContent, "staged\r\n")
        XCTAssertEqual(worktree.oldContent, "staged\r\n")
        XCTAssertEqual(worktree.newContent, "worktree\r\n")
    }

    func testGitBlobAtExactFiveMiBIsReadableWhileNextByteIsRejected() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let cap = 5 << 20
        try Data(repeating: 65, count: cap).write(to: root.appendingPathComponent("exact.txt"))
        try Data(repeating: 66, count: cap + 1).write(to: root.appendingPathComponent("oversize.txt"))
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "byte limit"], in: root)
        let hash = try git(["rev-parse", "HEAD"], in: root)
        let exact = DiffTab(
            repoRoot: root.path, path: "exact.txt", source: .revision(hash: hash),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        let oversize = DiffTab(
            repoRoot: root.path, path: "oversize.txt", source: .revision(hash: hash),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !exact.isLoading && !oversize.isLoading }
        XCTAssertNil(exact.error)
        XCTAssertEqual(exact.newContent.utf8.count, cap)
        XCTAssertNotNil(oversize.error)
        XCTAssertFalse(oversize.hasLoadedContent)
    }

    func testInvalidRevisionIsNotMisreportedAsAFileMissingFromValidCommit() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("valid\n".utf8).write(to: root.appendingPathComponent("note.txt"))
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "baseline"], in: root)
        let invalid = DiffTab(
            repoRoot: root.path, path: "note.txt",
            source: .revision(hash: "0000000000000000000000000000000000000001"),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !invalid.isLoading }
        let failure = try XCTUnwrap(invalid.error)
        XCTAssertFalse(failure.contains("does not contain"), "An invalid Git object is not an absent path in a valid commit")
    }

    func testDanglingHeadRefIsNotMistakenForUnbornStagedDiff() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("baseline\n".utf8).write(to: root.appendingPathComponent("base.txt"))
        _ = try git(["add", "base.txt"], in: root)
        _ = try git(["commit", "-qm", "baseline"], in: root)
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("new.txt"))
        _ = try git(["add", "new.txt"], in: root)

        // Both unborn and a dangling branch report HEAD^{commit} status 1.
        // Only the former has no refs/heads/main value at all.
        let branchRef = root.appendingPathComponent(".git/refs/heads/main")
        try Data((String(repeating: "1", count: 40) + "\n").utf8).write(to: branchRef)
        let tab = DiffTab(
            repoRoot: root.path, path: "new.txt", source: .staged,
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !tab.isLoading }
        XCTAssertNotNil(tab.error, "Broken HEAD must fail rather than turn the staged diff into an addition")
        XCTAssertFalse(tab.hasLoadedContent)
    }

    func testDeletedHistoricalDiffValidatesTheSelectedCommit() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("previous version\n".utf8).write(to: root.appendingPathComponent("removed.txt"))
        _ = try git(["add", "removed.txt"], in: root)
        _ = try git(["commit", "-qm", "baseline"], in: root)
        let parent = try git(["rev-parse", "HEAD"], in: root)
        _ = try git(["rm", "removed.txt"], in: root)
        _ = try git(["commit", "-qm", "remove"], in: root)
        let actual = try git(["rev-parse", "HEAD"], in: root)
        let valid = DiffTab(
            repoRoot: root.path, path: "removed.txt",
            source: .commit(hash: actual, parent: parent, status: "D"),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        let invalid = DiffTab(
            repoRoot: root.path, path: "removed.txt",
            source: .commit(hash: String(repeating: "1", count: 40), parent: parent, status: "D"),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !valid.isLoading && !invalid.isLoading }
        XCTAssertNil(valid.error)
        XCTAssertEqual(valid.oldContent, "previous version\n")
        XCTAssertEqual(valid.newContent, "")
        XCTAssertNotNil(invalid.error, "A missing selected commit cannot be a successful file deletion")
        XCTAssertFalse(invalid.hasLoadedContent)
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
        var prepared = false
        model.resetHistoricalFile("target.txt", at: commit,
                                  target: model.actionTarget(), expectedFileState: state,
                                  prepare: { prepared = true; return true })
        try await wait { !model.isBusy && model.operation?.finishedAt != nil }
        XCTAssertNotNil(model.lastError)
        XCTAssertFalse(prepared, "A stale confirmation must not even save pending editor text")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8),
                       "user changed after opening dialog\n")
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root),
                       try git(["rev-parse", "main"], in: root))
    }

    func testResetFileSavesDirtyTabThenOverwritesIndexDiskAndReloadsSameTab() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("note.txt")
        try Data("historical\n".utf8).write(to: path)
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "original"], in: root)
        let revision = try git(["rev-parse", "HEAD"], in: root)
        try Data("current\n".utf8).write(to: path)
        _ = try git(["commit", "-qam", "updated"], in: root)
        let head = try git(["rev-parse", "HEAD"], in: root)
        let project = Project(fallbackName: "Reset dirty tab", workspaceConfiguration: .standard)
        project.customDirectory = root.path
        project.openFile(path.path)
        guard case .file(let file) = project.selectedTab?.content else { return XCTFail("FileTab missing") }
        try await file.waitForText()
        let tabID = project.selectedTabID
        file.autoSaveSuspendedForClose = true
        file.appendText("unsaved\n")
        XCTAssertTrue(file.isDirty)
        let model = GitStatusModel()
        model.sync(root: root.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let target = model.actionTarget()
        let commit = try XCTUnwrap(model.recentCommits.first { $0.hash == revision })
        let captured = await model.historicalFileState("note.txt", target: target)
        let state = try XCTUnwrap(captured)
        model.resetHistoricalFile("note.txt", at: commit, target: target, expectedFileState: state,
            prepare: { false })
        try await wait { !model.isBusy && model.operation?.finishedAt != nil }
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, "current\nunsaved\n")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "current\n")
        model.resetHistoricalFile("note.txt", at: commit, target: target, expectedFileState: state,
            prepare: { await project.saveBeforeGitAction(repository: root.path, scope: "local", isCurrent: { true }) },
            isCurrentTarget: { project.canRunGitAction(repository: root.path, scope: "local") },
            completion: { success in
                if success { project.reloadAfterGitAction(repository: root.path, scope: "local") }
            })
        try await wait { !model.isBusy && model.operation?.finishedAt != nil }
        XCTAssertNil(model.lastError, model.lastError ?? "")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "historical\n")
        XCTAssertEqual(try git(["show", ":note.txt"], in: root), "historical")
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root), head)
        try await wait { file.text == "historical\n" }
        XCTAssertEqual(project.selectedTabID, tabID)
        XCTAssertFalse(file.isDirty)
    }

    func testResetFileRejectsIndexChangeDuringPreparation() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("note.txt")
        try Data("historical\n".utf8).write(to: path)
        _ = try git(["add", "."], in: root)
        _ = try git(["commit", "-qm", "original"], in: root)
        let model = GitStatusModel()
        model.sync(root: root.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let commit = try XCTUnwrap(model.recentCommits.first)
        let captured = await model.historicalFileState("note.txt", target: model.actionTarget())
        let state = try XCTUnwrap(captured)
        model.resetHistoricalFile("note.txt", at: commit, target: model.actionTarget(),
            expectedFileState: state, prepare: {
                do {
                    try Data("external staged update\n".utf8).write(to: path)
                    _ = try self.git(["add", "note.txt"], in: root)
                    return true
                } catch { return false }
            })
        try await wait { !model.isBusy && model.operation?.finishedAt != nil }
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try git(["show", ":note.txt"], in: root), "external staged update")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "external staged update\n")
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
