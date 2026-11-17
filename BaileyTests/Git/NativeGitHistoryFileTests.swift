import XCTest
@testable import Bailey

@MainActor
final class NativeGitHistoryFileTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    private func repository(objectFormat: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [
            ["init", "-q", "-b", "main"] + (objectFormat.map { ["--object-format=" + $0] } ?? []),
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

    private func lfsRepository(customStorage: Bool = false, objectFormat: String? = nil) throws -> URL {
        guard GitCommandExecution.run(["lfs", "version"],
                                      in: FileManager.default.temporaryDirectory.path).status == 0 else {
            throw XCTSkip("Real Git LFS is unavailable on this test machine")
        }
        let root = try repository(objectFormat: objectFormat)
        // The isolated repository disables hooks. LFS installs its own hooks
        // locally, after which the fixture restores hook isolation.
        _ = try git(["config", "--local", "core.hooksPath", ".git/hooks"], in: root)
        _ = try git(["lfs", "install", "--local"], in: root)
        _ = try git(["config", "--local", "core.hooksPath", "/dev/null"], in: root)
        if customStorage {
            _ = try git(["config", "--local", "lfs.storage",
                         root.appendingPathComponent(".git/custom-lfs-storage").path], in: root)
        }
        _ = try git(["lfs", "track", "*.csv"], in: root)
        return root
    }

    private func lfsMedia(path: String, revision: String, in root: URL) throws -> URL {
        let pointer = try git(["show", "\(revision):\(path)"], in: root)
        let environment = try git(["lfs", "env"], in: root)
        guard let object = pointer.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("oid sha256:") }),
              let directory = environment.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("LocalMediaDir=") }) else {
            throw WorkspaceError.notFound
        }
        let sha = String(object.dropFirst("oid sha256:".count))
        let path = String(directory.dropFirst("LocalMediaDir=".count))
        let media = URL(fileURLWithPath: path).appendingPathComponent(
            "\(sha.prefix(2))/\(sha.dropFirst(2).prefix(2))/\(sha)"
        ).standardizedFileURL
        guard media.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw WorkspaceError.notFound
        }
        return media
    }

    private func cachedLFSObjectNames(in root: URL) -> Set<String> {
        let objects = root.appendingPathComponent(".git/lfs/objects")
        let enumerator = FileManager.default.enumerator(at: objects,
                                                       includingPropertiesForKeys: [.isRegularFileKey])
        return Set((enumerator?.allObjects as? [URL] ?? []).map(\.lastPathComponent)
            .filter { $0.utf8.count == 64 })
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

    func testRevisionRemainsReadonlyWhenSharedPreferencesEnableEditing() async throws {
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
        XCTAssertFalse(revision.isEditableNow)
        XCTAssertFalse(empty.isEditableNow)
        XCTAssertEqual(revision.newContent, "history one\n")
        XCTAssertEqual(empty.newContent, "")
        // The cross-process readonly text surface and keyboard/AX behavior
        // belong to GitHistoryUITests, not a synthetic NSWindow in BaileyTests.
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

    func testLFSRevisionToRenamedWorktreeUsesRealMediaWithoutCacheWrites() async throws {
        let root = try lfsRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "old-曲线.csv"
        let renamed = "new-曲线.csv"
        let initial = "strain,stress\n0,20\n1,40\n"
        let modified = "strain,stress\n0,20\n1,65\n"
        try Data(initial.utf8).write(to: root.appendingPathComponent(original))
        _ = try git(["add", "-A"], in: root)
        _ = try git(["commit", "-qm", "original LFS media"], in: root)
        let revision = try git(["rev-parse", "HEAD"], in: root)
        _ = try git(["mv", original, renamed], in: root)
        _ = try git(["commit", "-qm", "LFS file rename"], in: root)
        try Data(modified.utf8).write(to: root.appendingPathComponent(renamed))
        let before = cachedLFSObjectNames(in: root)
        let index = try git(["rev-parse", ":" + renamed], in: root)
        let head = try git(["rev-parse", "HEAD"], in: root)
        let comparison = DiffTab(
            repoRoot: root.path, path: original, source: .revisionWorktree(hash: revision),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !comparison.isLoading && comparison.display != nil }
        XCTAssertNil(comparison.error)
        XCTAssertEqual(comparison.oldContent, initial)
        XCTAssertEqual(comparison.newContent, modified)
        XCTAssertEqual(comparison.resolvedWorktreePath, renamed)
        XCTAssertFalse(comparison.isEditableNow)
        XCTAssertEqual(cachedLFSObjectNames(in: root), before,
                       "Navigating a historical LFS rename must not create new LFS media")
        XCTAssertEqual(try git(["rev-parse", ":" + renamed], in: root), index)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root), head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(renamed)),
                       Data(modified.utf8))

        // A staged rewrite may make the old->Index similarity too low.
        // The unchanged HEAD rename must still resolve the real working file.
        let rewritten = "completely,different\n1,123456\n2,222222\n3,999999\n"
        try Data(rewritten.utf8).write(to: root.appendingPathComponent(renamed))
        _ = try git(["add", "--", renamed], in: root)
        let lostInIndex = try git(
            ["diff", "--cached", "--name-status", "--find-renames",
             "--diff-filter=R", revision, "--"], in: root
        )
        XCTAssertEqual(lostInIndex, "", "The fixture must defeat direct index rename matching")
        let inHEAD = try git(
            ["diff", "--name-status", "--find-renames", "--diff-filter=R",
             revision, "HEAD", "--"], in: root
        )
        XCTAssertTrue(inHEAD.hasPrefix("R100\t"))
        let stagedCache = cachedLFSObjectNames(in: root)
        let fallback = DiffTab(
            repoRoot: root.path, path: original, source: .revisionWorktree(hash: revision),
            untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: nil
        )
        try await wait { !fallback.isLoading && fallback.display != nil }
        XCTAssertNil(fallback.error)
        XCTAssertEqual(fallback.oldContent, initial)
        XCTAssertEqual(fallback.newContent, rewritten)
        XCTAssertEqual(fallback.resolvedWorktreePath, renamed)
        XCTAssertEqual(cachedLFSObjectNames(in: root), stagedCache)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(renamed)),
                       Data(rewritten.utf8))
    }

    func testLFSStagedRenameResolvesViaIndexWithoutWorktreeClean() async throws {
        let root = try lfsRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "prior.csv"
        let renamed = "renamed.csv"
        let body = "strain,stress\n0,0\n1,4\n"
        let modified = "strain,stress\n0,0\n1,9\n"
        try Data(body.utf8).write(to: root.appendingPathComponent(original))
        _ = try git(["add", "-A"], in: root)
        _ = try git(["commit", "-qm", "staged rename initial"], in: root)
        let revision = try git(["rev-parse", "HEAD"], in: root)
        _ = try git(["mv", original, renamed], in: root)
        let index = try git(["rev-parse", ":" + renamed], in: root)
        try Data(modified.utf8).write(to: root.appendingPathComponent(renamed))
        let before = cachedLFSObjectNames(in: root)
        let comparison = DiffTab(
            repoRoot: root.path, path: original,
            source: .revisionWorktree(hash: revision), untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !comparison.isLoading && comparison.display != nil }
        XCTAssertNil(comparison.error)
        XCTAssertEqual(comparison.oldContent, body)
        XCTAssertEqual(comparison.newContent, modified)
        XCTAssertEqual(comparison.resolvedWorktreePath, renamed)
        XCTAssertEqual(cachedLFSObjectNames(in: root), before)
        XCTAssertEqual(try git(["rev-parse", ":" + renamed], in: root), index)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root), revision)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(renamed)),
                       Data(modified.utf8))
    }

    func testLFSStashHistoryShowsRealMediaWithoutWritingWorktree() async throws {
        let root = try lfsRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "sample.csv"
        let file = root.appendingPathComponent(path)
        let before = "strain,stress\n0,12\n1,22\n"
        let stashed = "strain,stress\n0,12\n1,82\n"
        try Data(before.utf8).write(to: file)
        _ = try git(["add", "-A"], in: root)
        _ = try git(["commit", "-qm", "LFS stash base"], in: root)
        let head = try git(["rev-parse", "HEAD"], in: root)
        try Data(stashed.utf8).write(to: file)
        _ = try git(["stash", "push", "-m", "LFS media stash"], in: root)
        let stash = try git(["rev-parse", "stash@{0}"], in: root)
        XCTAssertEqual(try Data(contentsOf: file), Data(before.utf8))
        let media = cachedLFSObjectNames(in: root)
        let diff = DiffTab(
            repoRoot: root.path, path: path,
            source: .commit(hash: stash, parent: head, status: "M"),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !diff.isLoading && diff.display != nil }
        XCTAssertNil(diff.error)
        XCTAssertEqual(diff.oldContent, before)
        XCTAssertEqual(diff.newContent, stashed)
        XCTAssertEqual(diff.display?.computation.unified.rows.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(diff.display?.computation.unified.rows.filter { $0.kind == .removed }.count, 1)
        XCTAssertEqual(cachedLFSObjectNames(in: root), media)
        XCTAssertEqual(try Data(contentsOf: file), Data(before.utf8))
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root), head)
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

    func testAuthorizedWindowsSSHLFSReadsVerifiedMediaAcrossGitSources() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Real Windows LFS requires an explicitly authorized SSH test host")
        }
        let socket = "/tmp/bailey-remote-lfs-" + UUID().uuidString + ".sock"
        let backend = SSHWorkspaceBackend(
            runner: SSHHostCommandRunner(host: host, socket: socket), timeout: 60
        )
        let created = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-remote-lfs-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 60
        )
        XCTAssertEqual(created.status, 0, String(decoding: created.stderr, as: UTF8.self))
        let root = String(decoding: created.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.range(of: #"^/tmp/bailey-remote-lfs-[A-Za-z0-9]{6}$"#,
                         options: .regularExpression).map({
                             $0.lowerBound == root.startIndex && $0.upperBound == root.endIndex
                         }) == true else {
            throw WorkspaceError.notFound
        }
        func cleanup() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Could not clean test-owned remote LFS repository: \(error)") }
            if FileManager.default.fileExists(atPath: socket) {
                do {
                    let closed = try await Task.detached {
                        try ProcessRemoteCommandRunner.launch(
                            sshPath: "/usr/bin/ssh",
                            arguments: ["-S", socket, "-O", "exit", host],
                            stdin: nil, timeout: 15
                        )
                    }.value
                    XCTAssertEqual(closed.status, 0)
                } catch { XCTFail("Could not close test-owned SSH master: \(error)") }
            }
        }
        func command(_ argv: [String]) async throws -> Data {
            let result = try await backend.run(
                argv: argv, cwd: root, env: nil, stdin: nil, timeout: 60
            )
            XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
            guard result.status == 0 else { throw WorkspaceError.notFound }
            return result.stdout
        }

        do {
            let setup = """
            set -eu
            git init -q -b main
            git config user.name 'Bailey Windows LFS'
            git config user.email fixture@invalid
            git config commit.gpgsign false
            git config core.hooksPath .git/hooks
            git config filter.lfs.clean 'git-lfs clean -- %f'
            git config filter.lfs.smudge 'git-lfs smudge -- %f'
            git config filter.lfs.process 'git-lfs filter-process'
            git config filter.lfs.required true
            git config lfs.storage "$(cygpath -w "$PWD/.git/custom-lfs")"
            """
            let prepared = try await backend.run(
                argv: ["sh", "-s"], cwd: root, env: nil,
                stdin: Data(setup.utf8), timeout: 60
            )
            XCTAssertEqual(prepared.status, 0, String(decoding: prepared.stderr, as: UTF8.self))
            guard prepared.status == 0 else { throw WorkspaceError.notFound }

            let path = "试验 curve.csv"
            let initial = "strain,stress\n0,12\n1,44\n"
            let stagedText = "strain,stress\n0,12\n1,55\n"
            let worktreeText = "strain,stress\n0,12\n1,66\n"
            try await backend.write(
                path: root + "/.gitattributes",
                data: Data("*.csv filter=lfs diff=lfs merge=lfs -text\n".utf8)
            )
            try await backend.write(path: root + "/" + path, data: Data(initial.utf8))
            _ = try await command(["git", "add", "-A"])
            _ = try await command(["git", "commit", "-qm", "LFS historical CSV"])
            let revision = String(decoding: try await command(
                ["git", "rev-parse", "HEAD"]), as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let pointer = String(decoding: try await command(
                ["git", "show", "HEAD:" + path]), as: UTF8.self
            )
            XCTAssertTrue(pointer.hasPrefix("version https://git-lfs.github.com/spec/v1\n"))
            XCTAssertFalse(pointer.contains("strain,stress"))
            let lfsEnv = String(decoding: try await command(
                ["git", "lfs", "env"]), as: UTF8.self
            )
            XCTAssertTrue(lfsEnv.contains("LocalMediaDir="))
            XCTAssertTrue(lfsEnv.contains("custom-lfs"))

            try await backend.write(path: root + "/" + path, data: Data(stagedText.utf8))
            _ = try await command(["git", "add", "--", path])
            let stagedOID = try await command(["git", "rev-parse", ":" + path])
            try await backend.write(path: root + "/" + path, data: Data(worktreeText.utf8))
            let cached = try await command(
                ["sh", "-c", "find .git/custom-lfs/objects -type f | sort"]
            )
            let tabs: [DiffTab] = [
                DiffTab(repoRoot: root, path: path, source: .revision(hash: revision),
                        untracked: false, origPath: nil, backend: backend, workspaceIdentity: nil),
                DiffTab(repoRoot: root, path: path, source: .staged,
                        untracked: false, origPath: nil, backend: backend, workspaceIdentity: nil),
                DiffTab(repoRoot: root, path: path, source: .worktree,
                        untracked: false, origPath: nil, backend: backend, workspaceIdentity: nil),
                DiffTab(repoRoot: root, path: path, source: .revisionWorktree(hash: revision),
                        untracked: false, origPath: nil, backend: backend, workspaceIdentity: nil),
            ]
            let deadline = Date().addingTimeInterval(180)
            while tabs.contains(where: \.isLoading) {
                guard Date() < deadline else { throw WorkspaceError.timedOut }
                try await Task.sleep(for: .milliseconds(75))
            }
            for tab in tabs { XCTAssertNil(tab.error, tab.error ?? "") }
            XCTAssertEqual(tabs[0].newContent, initial)
            XCTAssertEqual(tabs[1].oldContent, initial)
            XCTAssertEqual(tabs[1].newContent, stagedText)
            XCTAssertEqual(tabs[2].oldContent, stagedText)
            XCTAssertEqual(tabs[2].newContent, worktreeText)
            XCTAssertEqual(tabs[3].oldContent, initial)
            XCTAssertEqual(tabs[3].newContent, worktreeText)
            XCTAssertTrue(tabs[2].isEditableNow)
            XCTAssertFalse(tabs[0].isEditableNow)
            let cachedAfter = try await command(
                ["sh", "-c", "find .git/custom-lfs/objects -type f | sort"]
            )
            let fileAfter = try await backend.read(path: root + "/" + path, maxBytes: 4096)
            let indexedAfter = try await command(["git", "rev-parse", ":" + path])
            let headAfter = try await command(["git", "rev-parse", "HEAD"])
            XCTAssertEqual(cachedAfter, cached, "Diff must not create new LFS media")
            XCTAssertEqual(fileAfter, Data(worktreeText.utf8))
            XCTAssertEqual(indexedAfter, stagedOID)
            XCTAssertEqual(String(decoding: headAfter, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines), revision)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    func testLFSRevisionCommitAndStagedUseRealCachedContentAfterAttributesChange() async throws {
        let root = try lfsRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "fig/中 文.csv"
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let first = "strain,stress\n0,1\n1,5\n"
        let second = "strain,stress\n0,1\n1,9\n2,12\n"
        try Data(first.utf8).write(to: url)
        _ = try git(["add", "-A"], in: root)
        _ = try git(["commit", "-qm", "LFS initial CSV"], in: root)
        let initial = try git(["rev-parse", "HEAD"], in: root)
        let pointer = try git(["show", "\(initial):\(path)"], in: root)
        XCTAssertTrue(pointer.hasPrefix("version https://git-lfs.github.com/spec/v1\n"))
        XCTAssertFalse(pointer.contains("strain,stress"),
                       "Git must store an actual LFS pointer for the fixture")
        try Data(second.utf8).write(to: url)
        _ = try git(["add", path], in: root)

        let revision = DiffTab(
            repoRoot: root.path, path: path, source: .revision(hash: initial),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        let staged = DiffTab(
            repoRoot: root.path, path: path, source: .staged,
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !revision.isLoading && !staged.isLoading }
        XCTAssertNil(revision.error)
        XCTAssertEqual(revision.newContent, first)
        XCTAssertNil(staged.error)
        XCTAssertEqual(staged.oldContent, first)
        XCTAssertEqual(staged.newContent, second)
        XCTAssertFalse(staged.isEditableNow)

        _ = try git(["rm", ".gitattributes"], in: root)
        _ = try git(["commit", "-qm", "remove current LFS attributes"], in: root)
        let updated = try git(["rev-parse", "HEAD"], in: root)
        let history = DiffTab(
            repoRoot: root.path, path: path,
            source: .commit(hash: updated, parent: initial, status: "M"),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        let historical = DiffTab(
            repoRoot: root.path, path: path, source: .revision(hash: initial),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !history.isLoading && !historical.isLoading }
        XCTAssertNil(history.error)
        XCTAssertNil(historical.error)
        XCTAssertEqual(history.oldContent, first)
        XCTAssertEqual(history.newContent, second)
        XCTAssertEqual(historical.newContent, first,
                       "A historical pointer must not depend on current .gitattributes")
        XCTAssertEqual(try Data(contentsOf: url), Data(second.utf8))
    }

    func testLFSCustomStorageAndSHA256RepositoryResolveSelectedHistoricalMedia() async throws {
        for format in ["sha1", "sha256"] {
            let root = try lfsRepository(customStorage: true, objectFormat: format)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = "data with space/试验.csv"
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let body = "sample,pressure\n0,20\n1,42\n"
            try Data(body.utf8).write(to: url)
            _ = try git(["add", "-A"], in: root)
            _ = try git(["commit", "-qm", "custom LFS storage"], in: root)
            let revision = try git(["rev-parse", "HEAD"], in: root)
            XCTAssertEqual(revision.utf8.count, format == "sha256" ? 64 : 40)
            let media = try lfsMedia(path: path, revision: revision, in: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
            XCTAssertTrue(media.path.contains("custom-lfs-storage"))
            let diff = DiffTab(
                repoRoot: root.path, path: path, source: .revision(hash: revision),
                untracked: false, origPath: nil,
                backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
            )
            try await wait { !diff.isLoading }
            XCTAssertNil(diff.error)
            XCTAssertEqual(diff.newContent, body)
            XCTAssertTrue(try git(["status", "--porcelain=v1"], in: root).isEmpty)
        }
    }

    func testLFSUncachedOrDamagedMediaNeverFallsBackToPointer() async throws {
        for removed in [true, false] {
            let root = try lfsRepository()
            defer { try? FileManager.default.removeItem(at: root) }
            let path = "test.csv"
            let url = root.appendingPathComponent(path)
            let body = "one,two\n3,4\n"
            try Data(body.utf8).write(to: url)
            _ = try git(["add", "-A"], in: root)
            _ = try git(["commit", "-qm", "cached LFS media"], in: root)
            let revision = try git(["rev-parse", "HEAD"], in: root)
            let media = try lfsMedia(path: path, revision: revision, in: root)
            if removed {
                try FileManager.default.removeItem(at: media)
            } else {
                try Data("corrupted media\n".utf8).write(to: media)
            }
            let diff = DiffTab(
                repoRoot: root.path, path: path, source: .revision(hash: revision),
                untracked: false, origPath: nil,
                backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
            )
            try await wait { !diff.isLoading }
            let issue = try XCTUnwrap(diff.error)
            XCTAssertTrue(issue.contains("Git LFS"), issue)
            XCTAssertFalse(diff.hasLoadedContent)
            XCTAssertFalse(diff.newContent.contains("version https://git-lfs"))
            XCTAssertEqual(FileManager.default.fileExists(atPath: media.path), !removed,
                           "Diff browsing must not download or regenerate local LFS media")
            XCTAssertEqual(try Data(contentsOf: url), Data(body.utf8))
        }
    }

    func testLFSEncodedMediaAndNewlinePathRoundTripOriginalBytes() async throws {
        let root = try lfsRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let unicodePath = "资料/图\n图.csv"
        let bomPath = "bom.csv"
        let unicode = "# coding: gbk\n页岩,峰值\n0,12\n"
        let gbk = try XCTUnwrap(TextFileEncoding.gbk.encoded(unicode))
        let bom = try XCTUnwrap(TextFileEncoding.utf8BOM.encoded("force,value\n1,2\n"))
        let unicodeURL = root.appendingPathComponent(unicodePath)
        try FileManager.default.createDirectory(at: unicodeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try gbk.write(to: unicodeURL)
        try bom.write(to: root.appendingPathComponent(bomPath))
        _ = try git(["add", "-A"], in: root)
        _ = try git(["commit", "-qm", "encoded LFS data"], in: root)
        let oid = try git(["rev-parse", "HEAD"], in: root)
        let decoded = [
            (unicodePath, unicode, "GBK (CP936)"),
            (bomPath, "force,value\n1,2\n", "UTF-8 BOM"),
        ]
        for (path, original, encoding) in decoded {
            let tab = DiffTab(
                repoRoot: root.path, path: path, source: .revision(hash: oid),
                untracked: false, origPath: nil,
                backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
            )
            try await wait { !tab.isLoading }
            XCTAssertNil(tab.error)
            XCTAssertEqual(tab.newContent, original)
            XCTAssertEqual(tab.fileEncoding.name, encoding)
        }
        XCTAssertEqual(try Data(contentsOf: unicodeURL), gbk)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(bomPath)), bom)
    }

    func testLFSPointerSizeMismatchIsRejectedWithoutMutatingMedia() async throws {
        let root = try lfsRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "valid.csv"
        try Data("one,two\n1,2\n".utf8).write(to: root.appendingPathComponent(source))
        _ = try git(["add", "-A"], in: root)
        _ = try git(["commit", "-qm", "cache valid media"], in: root)
        let before = try git(["rev-parse", "HEAD"], in: root)
        let media = try lfsMedia(path: source, revision: before, in: root)
        let trueBytes = try Data(contentsOf: media)
        let pointer = try git(["show", "\(before):\(source)"], in: root)
        let altered = pointer.replacingOccurrences(of: "size \(trueBytes.count)",
                                                    with: "size \(trueBytes.count + 1)") + "\n"
        XCTAssertNotEqual(altered, pointer)
        try Data(altered.utf8).write(to: root.appendingPathComponent("mismatch.txt"))
        _ = try git(["add", "mismatch.txt"], in: root)
        _ = try git(["commit", "-qm", "mismatch pointer metadata"], in: root)
        let commit = try git(["rev-parse", "HEAD"], in: root)
        let tab = DiffTab(
            repoRoot: root.path, path: "mismatch.txt", source: .revision(hash: commit),
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil
        )
        try await wait { !tab.isLoading }
        XCTAssertTrue(tab.error?.contains("SHA-256") ?? false)
        XCTAssertFalse(tab.hasLoadedContent)
        XCTAssertEqual(try Data(contentsOf: media), trueBytes)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root), commit)
    }

    func testLFSActualMediaSizeBoundaryAndBinaryDecoding() async throws {
        let root = try lfsRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = 5 << 20
        let exactPath = "exact.csv"
        let largePath = "large.csv"
        let binaryPath = "binary.csv"
        try Data(repeating: 65, count: limit).write(to: root.appendingPathComponent(exactPath))
        try Data(repeating: 66, count: limit + 1).write(to: root.appendingPathComponent(largePath))
        try Data([0, 1, 2, 255]).write(to: root.appendingPathComponent(binaryPath))
        _ = try git(["add", "-A"], in: root)
        _ = try git(["commit", "-qm", "LFS size and binary"], in: root)
        let revision = try git(["rev-parse", "HEAD"], in: root)
        let diffs = [exactPath, largePath, binaryPath].map { path in
            DiffTab(repoRoot: root.path, path: path, source: .revision(hash: revision),
                    untracked: false, origPath: nil,
                    backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        }
        try await wait { diffs.allSatisfy { !$0.isLoading } }
        XCTAssertNil(diffs[0].error)
        XCTAssertEqual(diffs[0].newContent.utf8.count, limit)
        XCTAssertNotNil(diffs[1].error)
        XCTAssertFalse(diffs[1].hasLoadedContent)
        XCTAssertNotNil(diffs[2].error)
        XCTAssertEqual(diffs[2].error, String(localized: "Binary file", table: "Git"))
        XCTAssertFalse(diffs[2].hasLoadedContent)
    }

    func testMalformedLFSPointerFailsExplicitlyWithoutExposingItsText() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let pointer = "version https://git-lfs.github.com/spec/v1\n"
            + "oid sha256:wrong\nsize 12\n"
        try Data(pointer.utf8).write(to: root.appendingPathComponent("raw.txt"))
        _ = try git(["add", "-A"], in: root)
        _ = try git(["commit", "-qm", "malformed pointer"], in: root)
        let revision = try git(["rev-parse", "HEAD"], in: root)
        let diff = DiffTab(repoRoot: root.path, path: "raw.txt", source: .revision(hash: revision),
                           untracked: false, origPath: nil,
                           backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await wait { !diff.isLoading }
        XCTAssertEqual(diff.error, String(localized: "Invalid Git LFS pointer", table: "Git"))
        XCTAssertFalse(diff.hasLoadedContent)
        XCTAssertFalse(diff.newContent.contains("version https://git-lfs"))
    }

    func testLFSWorktreeAndRevisionCompareActualRowsWithoutCreatingNewMedia() async throws {
        let root = try lfsRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "strain.csv"
        let url = root.appendingPathComponent(path)
        let initial = "strain,stress\n0,0\n1,1\n2,4\n"
        let modified = "strain,stress\n0,0\n1,9\n2,4\n"
        let edited = "strain,stress\n0,0\n1,9\n2,16\n"
        try Data(initial.utf8).write(to: url)
        _ = try git(["add", "-A"], in: root)
        _ = try git(["commit", "-qm", "initial strain"], in: root)
        let initialRevision = try git(["rev-parse", "HEAD"] , in: root)
        let indexBefore = try git(["rev-parse", ":\(path)"], in: root)
        let mediaBefore = cachedLFSObjectNames(in: root)
        XCTAssertEqual(mediaBefore.count, 1)
        try Data(modified.utf8).write(to: url)

        let worktree = DiffTab(repoRoot: root.path, path: path, source: .worktree,
                               untracked: false, origPath: nil,
                               backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        let historical = DiffTab(repoRoot: root.path, path: path,
                                 source: .revisionWorktree(hash: initialRevision),
                                 untracked: false, origPath: nil,
                                 backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await wait { !worktree.isLoading && !historical.isLoading }
        XCTAssertNil(worktree.error)
        XCTAssertNil(historical.error)
        XCTAssertEqual(worktree.oldContent, initial)
        XCTAssertEqual(worktree.newContent, modified)
        XCTAssertEqual(historical.oldContent, initial)
        XCTAssertEqual(historical.newContent, modified)
        try await wait { worktree.display != nil && historical.display != nil }
        for tab in [worktree, historical] {
            XCTAssertEqual(tab.display?.computation.unified.rows.filter { $0.kind == .removed }.count, 1)
            XCTAssertEqual(tab.display?.computation.unified.rows.filter { $0.kind == .added }.count, 1)
        }
        XCTAssertEqual(cachedLFSObjectNames(in: root), mediaBefore,
                       "Reading Git LFS Diff must not run clean filters that create new objects")
        XCTAssertEqual(try git(["rev-parse", ":\(path)"], in: root), indexBefore)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root), initialRevision)
        XCTAssertEqual(try Data(contentsOf: url), Data(modified.utf8))

        _ = try git(["add", "--", path], in: root)
        let stagedOID = try git(["rev-parse", ":\(path)"], in: root)
        let newMedia = cachedLFSObjectNames(in: root)
        XCTAssertNotEqual(stagedOID, indexBefore)
        try Data(edited.utf8).write(to: url)
        let unstaged = DiffTab(repoRoot: root.path, path: path, source: .worktree,
                               untracked: false, origPath: nil,
                               backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await wait { !unstaged.isLoading }
        XCTAssertNil(unstaged.error)
        XCTAssertEqual(unstaged.oldContent, modified)
        XCTAssertEqual(unstaged.newContent, edited)
        try await wait { unstaged.display != nil }
        XCTAssertEqual(unstaged.display?.computation.unified.rows.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(unstaged.display?.computation.unified.rows.filter { $0.kind == .removed }.count, 1)
        XCTAssertEqual(cachedLFSObjectNames(in: root), newMedia)
        XCTAssertEqual(try git(["rev-parse", ":\(path)"], in: root), stagedOID)
        XCTAssertEqual(try Data(contentsOf: url), Data(edited.utf8))
    }

    func testActivatingLFSAfterPlainCommitDoesNotCreatePointerPatchOrMedia() async throws {
        let root = try lfsRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "transition.csv"
        let file = root.appendingPathComponent(path)
        let baseline = "name,stress\nA,10\nB,25\n"
        let edited = "name,stress\nA,10\nB,50\n"
        try FileManager.default.removeItem(at: root.appendingPathComponent(".gitattributes"))
        try Data(baseline.utf8).write(to: file)
        _ = try git(["add", "--", path], in: root)
        _ = try git(["commit", "-qm", "plain Git blob before LFS"], in: root)
        let plainOID = try git(["rev-parse", ":\(path)"], in: root)
        XCTAssertTrue(try git(["show", "HEAD:\(path)"], in: root).contains("name,stress"))
        _ = try git(["lfs", "track", "*.csv"], in: root)
        _ = try git(["add", ".gitattributes"], in: root)
        _ = try git(["commit", "-qm", "activate LFS for existing file"], in: root)
        let initialMedia = cachedLFSObjectNames(in: root)
        let unchanged = DiffTab(repoRoot: root.path, path: path, source: .worktree,
                                untracked: false, origPath: nil,
                                backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await wait { !unchanged.isLoading }
        XCTAssertNil(unchanged.error)
        XCTAssertEqual(unchanged.oldContent, baseline)
        XCTAssertEqual(unchanged.newContent, baseline)
        XCTAssertFalse(unchanged.hasChanges, "An LFS attribute transition must not invent content edits")
        XCTAssertEqual(cachedLFSObjectNames(in: root), initialMedia)

        try Data(edited.utf8).write(to: file)
        let updated = DiffTab(repoRoot: root.path, path: path, source: .worktree,
                              untracked: false, origPath: nil,
                              backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await wait { !updated.isLoading }
        XCTAssertNil(updated.error)
        XCTAssertEqual(updated.oldContent, baseline)
        XCTAssertEqual(updated.newContent, edited)
        try await wait { updated.display != nil }
        XCTAssertEqual(updated.display?.computation.unified.rows.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(updated.display?.computation.unified.rows.filter { $0.kind == .removed }.count, 1)
        XCTAssertEqual(cachedLFSObjectNames(in: root), initialMedia,
                       "Read-only Diff must not create new LFS media through git hash-object")
        XCTAssertEqual(try git(["rev-parse", ":\(path)"], in: root), plainOID)
        XCTAssertEqual(try Data(contentsOf: file), Data(edited.utf8))
    }

    func testLFSPointerOnlyCheckoutIsNotEditableOrMisrepresentedAsCSV() async throws {
        let root = try lfsRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "placeholder.csv"
        let file = root.appendingPathComponent(path)
        let csv = "stress,value\n0,10\n1,20\n"
        try Data(csv.utf8).write(to: file)
        _ = try git(["add", "-A"], in: root)
        _ = try git(["commit", "-qm", "LFS fixture with media"], in: root)
        let revision = try git(["rev-parse", "HEAD"], in: root)
        let pointer = try git(["show", "\(revision):\(path)"], in: root) + "\n"
        XCTAssertTrue(pointer.hasPrefix("version https://git-lfs.github.com/spec/v1\n"))
        try Data(pointer.utf8).write(to: file)
        let files = [
            DiffTab(repoRoot: root.path, path: path, source: .worktree,
                    untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
                    workspaceIdentity: nil),
            DiffTab(repoRoot: root.path, path: path,
                    source: .revisionWorktree(hash: revision),
                    untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
                    workspaceIdentity: nil),
        ]
        try await wait { files.allSatisfy { !$0.isLoading } }
        for tab in files {
            XCTAssertEqual(tab.error, String(
                localized: "Git LFS worktree is still a pointer; restore its actual content before editing",
                table: "Git"
            ))
            XCTAssertFalse(tab.isEditableNow)
            XCTAssertFalse(tab.hasLoadedContent)
            XCTAssertFalse(tab.newContent.contains("version https://git-lfs"))
        }
        XCTAssertEqual(try Data(contentsOf: file), Data(pointer.utf8))
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: root), revision)
    }

    func testDisablingLFSAtributesAfterPointerCommitRetainsActualWorktreeDiff() async throws {
        let root = try lfsRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "after-attributes.csv"
        let file = root.appendingPathComponent(path)
        let baseline = "time,force\n0,20\n1,30\n"
        let modified = "time,force\n0,20\n1,60\n"
        try Data(baseline.utf8).write(to: file)
        _ = try git(["add", "-A"], in: root)
        _ = try git(["commit", "-qm", "LFS before attributes removed"], in: root)
        let original = try git(["rev-parse", "HEAD"], in: root)
        let pointer = try git(["show", "\(original):\(path)"], in: root)
        XCTAssertFalse(pointer.contains("time,force"))
        _ = try git(["rm", ".gitattributes"], in: root)
        _ = try git(["commit", "-qm", "remove LFS attributes"], in: root)
        let media = cachedLFSObjectNames(in: root)

        let clean = DiffTab(repoRoot: root.path, path: path, source: .worktree,
                            untracked: false, origPath: nil,
                            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await wait { !clean.isLoading }
        XCTAssertNil(clean.error)
        XCTAssertEqual(clean.oldContent, baseline)
        XCTAssertEqual(clean.newContent, baseline)
        XCTAssertFalse(clean.hasChanges)
        try Data(modified.utf8).write(to: file)
        let changed = DiffTab(repoRoot: root.path, path: path,
                              source: .revisionWorktree(hash: original),
                              untracked: false, origPath: nil,
                              backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await wait { !changed.isLoading && changed.display != nil }
        XCTAssertNil(changed.error)
        XCTAssertEqual(changed.oldContent, baseline)
        XCTAssertEqual(changed.newContent, modified)
        XCTAssertEqual(changed.display?.computation.unified.rows.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(changed.display?.computation.unified.rows.filter { $0.kind == .removed }.count, 1)
        XCTAssertEqual(cachedLFSObjectNames(in: root), media)
        XCTAssertEqual(try Data(contentsOf: file), Data(modified.utf8))
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
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let project = Project(fallbackName: "Reset dirty tab", workspaceConfiguration: .standard)
        manager.projects = [project]
        manager.selectedProjectID = project.id
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
            prepare: { await self.workspaceApplication.saveBeforeGitAction(repository: root.path, scope: "local", isCurrent: { true }) },
            isCurrentTarget: { self.workspaceApplication.canRunGitAction(repository: root.path, scope: "local") },
            completion: { success in
                if success { self.workspaceApplication.reloadAfterGitAction(repository: root.path, scope: "local") }
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
