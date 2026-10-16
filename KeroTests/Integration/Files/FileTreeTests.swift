import Foundation
import Observation
import XCTest
@testable import kero

private actor CountingFileBackend: WorkspaceBackend {
    private(set) var requests: [String: Int] = [:]
    private(set) var lastBatch: [String]?
    private var unavailable = false
    private var delayedPath: String?
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var awaitingDirectory = false
    private let base = LocalWorkspaceBackend.shared

    func setUnavailable(_ value: Bool) { unavailable = value }
    func delay(_ path: String) { delayedPath = path }
    func release() {
        gate?.resume()
        gate = nil
        awaitingDirectory = false
    }
    func list(directory: String) async throws -> [WorkspaceEntry] {
        requests[directory, default: 0] += 1
        if delayedPath == directory {
            delayedPath = nil
            awaitingDirectory = true
            await withCheckedContinuation { gate = $0 }
        }
        if unavailable { throw WorkspaceError.timedOut }
        return try await base.list(directory: directory)
    }
    func list(directories: [String]) async -> [String: [WorkspaceEntry]] {
        lastBatch = directories
        var result: [String: [WorkspaceEntry]] = [:]
        for directory in directories {
            result[directory] = try? await list(directory: directory)
        }
        return result
    }
    func stat(path: String) async throws -> WorkspaceStat? { try await base.stat(path: path) }
    func readSymlinkDestination(path: String) async throws -> String? { try await base.readSymlinkDestination(path: path) }
    func read(path: String, maxBytes: Int) async throws -> Data { try await base.read(path: path, maxBytes: maxBytes) }
    func write(path: String, data: Data) async throws { try await base.write(path: path, data: data) }
    func createFile(path: String) async throws { try await base.createFile(path: path) }
    func createDirectory(path: String) async throws { try await base.createDirectory(path: path) }
    func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    func delete(paths: [String]) async throws { try await base.delete(paths: paths) }
    func gitRoot(containing path: String) async throws -> String? { try await base.gitRoot(containing: path) }
    func isLinkedWorktree(_ root: String) async throws -> Bool { try await base.isLinkedWorktree(root) }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        try await base.run(argv: argv, cwd: cwd, env: env, stdin: stdin, timeout: timeout)
    }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot { try await base.processes(descendantsOf: pid) }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { try await base.listeningPorts(pids: pids) }
    func kill(pid: pid_t, force: Bool) async throws { try await base.kill(pid: pid, force: force) }
}

@MainActor
final class FileTreeTests: XCTestCase {
    private var fixture: URL!
    private let backend = LocalWorkspaceBackend.shared

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture)
    }

    func testExclusiveCreationAndConcurrentRace() async throws {
        let file = fixture.appendingPathComponent("exclusive.txt")
        try await backend.createFile(path: file.path)
        XCTAssertEqual(try Data(contentsOf: file), Data())
        try Data("preserve".utf8).write(to: file)
        do {
            try await backend.createFile(path: file.path)
            XCTFail("Existing file must not be overwritten")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("preserve".utf8))

        let race = fixture.appendingPathComponent("race.txt").path
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do { try await LocalWorkspaceBackend.shared.createFile(path: race); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        XCTAssertEqual(winners, 1)
    }

    func testTreeExpansionDraftAndRename() async throws {
        let root = fixture.appendingPathComponent("root")
        let nested = root.appendingPathComponent("dir/inner")
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let original = nested.appendingPathComponent("a.swift")
        try Data().write(to: original)

        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        let compact = try XCTUnwrap(tree.items.first { $0.path == nested.path })
        XCTAssertEqual(compact.displayName, "dir / inner")
        await tree.toggle(compact)
        XCTAssertTrue(tree.items.contains { $0.path == original.path })

        await tree.beginNewFile(in: nested.path)
        XCTAssertTrue(tree.items.contains { $0.isDraft && $0.depth == 1 })
        let created = await tree.commitDraft(name: "draft.swift")
        XCTAssertEqual(created, nested.appendingPathComponent("draft.swift").path)
        XCTAssertTrue(tree.items.contains { $0.path == created }, "Created item must appear immediately")

        let renamed = await tree.rename(compact, to: "renamed")
        XCTAssertEqual(renamed, root.appendingPathComponent("dir/renamed").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed! + "/draft.swift"))
        XCTAssertEqual(tree.items.first { $0.path == renamed }?.displayName, "dir / renamed")
    }

    func testExpansionIsScopedByRootAndWorkspaceIdentity() async throws {
        let firstRoot = fixture.appendingPathComponent("a")
        let secondRoot = fixture.appendingPathComponent("b")
        let firstNested = firstRoot.appendingPathComponent("dir/inner")
        let secondNested = secondRoot.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: firstNested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondNested, withIntermediateDirectories: true)
        try Data().write(to: firstNested.appendingPathComponent("a.swift"))
        try Data().write(to: secondNested.appendingPathComponent("b.swift"))

        let tree = FileTreeModel()
        await tree.sync(root: firstRoot.path, backend: backend)
        let compact = try XCTUnwrap(tree.items.first { $0.path == firstNested.path })
        await tree.toggle(compact)
        XCTAssertTrue(tree.isExpanded(compact))

        await tree.sync(root: secondRoot.path, backend: backend)
        XCTAssertFalse(tree.isExpanded(compact))
        await tree.sync(root: firstRoot.path, backend: backend)
        XCTAssertTrue(tree.isExpanded(compact))
        await tree.sync(root: firstRoot.path, backend: backend, scope: "ssh:fixture")
        XCTAssertFalse(tree.isExpanded(compact))
        await tree.sync(root: firstRoot.path, backend: backend, scope: "local")
        XCTAssertTrue(tree.isExpanded(compact))
    }

    func testObservableTreeKeepsRealFileOperationsAndErrorsOutsideModelUI() async throws {
        let existing = fixture.appendingPathComponent("existing.txt")
        let candidate = fixture.appendingPathComponent("candidate.txt")
        try Data("preserved".utf8).write(to: existing)
        try Data("source".utf8).write(to: candidate)

        let tree = FileTreeModel()
        let changed = expectation(description: "File tree entries became observable")
        withObservationTracking({ _ = tree.items }) { changed.fulfill() }
        await tree.sync(root: fixture.path, backend: backend)
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertTrue(tree.items.contains { $0.path == existing.path })

        // There is no FileTreePanel here: an outer window still receives
        // operation errors through the model's presentation callback.
        var failures: [(title: String, detail: String)] = []
        tree.onError = { title, detail in failures.append((title, detail)) }

        await tree.beginNewFile(in: fixture.path)
        let rejected = await tree.commitDraft(name: "invalid/name")
        XCTAssertNil(rejected)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].title.contains("invalid/name"))
        XCTAssertTrue(failures[0].detail.contains("/"))
        XCTAssertNil(tree.draft)

        await tree.beginNewFile(in: fixture.path)
        let duplicate = await tree.commitDraft(name: "existing.txt")
        XCTAssertNil(duplicate)
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "preserved")

        // Normal creation uses a new name. Verify the actual file instead of
        // treating an error dialog or a visible draft row as success.
        let unique = fixture.appendingPathComponent("unique-smoke.txt")
        await tree.beginNewFile(in: fixture.path)
        let created = await tree.commitDraft(name: unique.lastPathComponent)
        XCTAssertEqual(created, unique.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unique.path))
        XCTAssertEqual(failures.count, 2)

        let source = try XCTUnwrap(tree.items.first { $0.path == candidate.path })
        let collision = await tree.rename(source, to: "existing.txt")
        XCTAssertNil(collision)
        XCTAssertEqual(failures.count, 3)
        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "preserved")

        // Cancelling an inline new-file row cannot create anything on disk.
        await tree.beginNewFolder(in: fixture.path)
        await tree.cancelDraft()
        XCTAssertNil(tree.draft)
        XCTAssertEqual(failures.count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.path).sorted(),
                       ["candidate.txt", "existing.txt", "unique-smoke.txt"])
    }

    func testExternalRefreshAndUnreadableRootPreservesDisplayedEntries() async throws {
        let root = fixture.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        XCTAssertTrue(tree.items.isEmpty)

        let created = root.appendingPathComponent("created.txt")
        try Data("created\n".utf8).write(to: created)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertEqual(tree.items.map(\.path), [created.path])

        let renamed = root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: created, to: renamed)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertEqual(tree.items.map(\.path), [renamed.path])

        let savedRoot = fixture.appendingPathComponent("temporarily-unreachable")
        try FileManager.default.moveItem(at: root, to: savedRoot)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertEqual(tree.items.map(\.path), [renamed.path],
                       "A failed directory read must not report an empty folder")
        try FileManager.default.moveItem(at: savedRoot, to: root)
        try FileManager.default.removeItem(at: renamed)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertTrue(tree.items.isEmpty)
    }

    func testSymlinkDirectoryBrokenLinkAndCycleRemainBounded() async throws {
        let root = fixture.appendingPathComponent("symlinks")
        let nested = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: nested.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: nested.appendingPathComponent("b.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"),
                                                    withDestinationURL: nested)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("broken"),
                                                    withDestinationURL: root.appendingPathComponent("absent"))
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("loop"),
                                                    withDestinationURL: nested)

        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        let alias = try XCTUnwrap(tree.items.first { $0.path == root.appendingPathComponent("alias").path })
        XCTAssertTrue(alias.isDirectory)
        let broken = try XCTUnwrap(tree.items.first { $0.path == root.appendingPathComponent("broken").path })
        XCTAssertFalse(broken.isDirectory)
        await tree.toggle(alias)
        XCTAssertTrue(tree.items.contains { $0.path == alias.path + "/a.txt" })
        XCTAssertTrue(tree.items.contains { $0.path == alias.path + "/loop" })
        let nestedCycle = try XCTUnwrap(tree.items.first { $0.path == alias.path + "/loop" })
        await tree.toggle(nestedCycle)
        XCTAssertLessThan(tree.items.count, 75, "Symlink loops cannot generate an unbounded tree")
    }

    func testCollapsedAndExpandedFoldersDoNotRereadUnchangedDirectories() async throws {
        let root = fixture.appendingPathComponent("cached")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("initial".utf8).write(to: root.appendingPathComponent("root.txt"))
        try Data("child".utf8).write(to: sub.appendingPathComponent("child.txt"))
        let counting = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: counting)
        let folder = try XCTUnwrap(tree.items.first { $0.path == sub.path })
        let readsAfterInitial = await counting.requests
        await tree.toggle(folder)
        XCTAssertTrue(tree.items.contains { $0.path == sub.appendingPathComponent("child.txt").path })
        let readsAfterExpansion = await counting.requests
        XCTAssertEqual(readsAfterExpansion, readsAfterInitial, "Expansion reuses the compaction lookahead")
        await tree.toggle(folder)
        await tree.toggle(folder)
        let readsAfterRepeat = await counting.requests
        XCTAssertEqual(readsAfterRepeat, readsAfterExpansion)
        await tree.sync(root: root.path, backend: counting)
        let batch = await counting.lastBatch
        XCTAssertEqual(batch?.contains(sub.path), true)
    }

    func testFolderIconChangesBeforeRemoteContentsArrive() async throws {
        let root = fixture.appendingPathComponent("slow")
        let parent = root.appendingPathComponent("parent")
        let first = parent.appendingPathComponent("first")
        let second = parent.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data().write(to: first.appendingPathComponent("a.txt"))
        try Data().write(to: second.appendingPathComponent("b.txt"))

        let counting = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: counting)
        let folder = try XCTUnwrap(tree.items.first { $0.path == parent.path })
        XCTAssertFalse(folder.isExpanded)
        await counting.delay(first.path)
        defer { Task { await counting.release() } }
        let opening = Task { await tree.toggle(folder) }
        let deadline = Date().addingTimeInterval(5)
        while await !counting.awaitingDirectory && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(tree.items.first(where: { $0.path == parent.path })?.isExpanded == true,
                      "The open icon must not wait for the SSH reply")
        await counting.release()
        await opening.value
        XCTAssertTrue(tree.items.contains { $0.path == first.path })
    }

    func testOfflineRefreshRetainsExistingTreeWithoutCrossWorkspaceLeak() async throws {
        let root = fixture.appendingPathComponent("offline")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("keep.txt"))
        let counting = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: counting, scope: "ssh:one")
        let previous = tree.items
        XCTAssertFalse(previous.isEmpty)
        await counting.setUnavailable(true)
        await tree.sync(root: root.path, backend: counting, scope: "ssh:one")
        XCTAssertEqual(tree.items, previous)
        await tree.sync(root: root.path, backend: counting, scope: "ssh:two")
        XCTAssertTrue(tree.items.isEmpty, "A different SSH target cannot inherit the old tree")
    }

    func testFirstLoadBatchesSiblingFolderLookahead() async throws {
        let root = fixture.appendingPathComponent("siblings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = (0..<12).map { root.appendingPathComponent("dir\($0)") }
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("content.txt"))
        }
        let counting = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: counting)
        XCTAssertEqual(tree.items.filter(\.isDirectory).count, folders.count)
        let batch = await counting.lastBatch
        XCTAssertEqual(Set(batch ?? []), Set(folders.map(\.path)),
                       "Initial directory compression must not perform one SSH request per sibling")
    }

    func testSharedTreeStatusAndCompaction() {
        let statuses: [(Character, TreeDisplayModel.Status)] = [
            ("M", .modified), ("A", .added), ("?", .untracked), ("D", .deleted),
            ("R", .renamed), ("C", .copied), ("U", .conflict), ("!", .ignored), ("T", .changed),
        ]
        let rows = statuses.map { character, status -> TreeDisplayModel.Row in
            XCTAssertEqual(TreeDisplayModel.Status(character), status)
            return TreeDisplayModel.Row(
                name: "\(character).swift",
                path: "dir/renamed/\(character).swift",
                isDirectory: false,
                status: status
            )
        }
        let display = TreeDisplayModel.pathRows(rows, section: "unstaged", collapsed: [])
        XCTAssertEqual(display.first?.displayName, "dir / renamed")
        XCTAssertEqual(display.first?.depth, 0)
        XCTAssertTrue(display.dropFirst().allSatisfy { !$0.isDirectory && $0.depth == 1 })

        let boundary = ["dir/a.swift", "dir/sub/deep/b.swift", "file10.swift", "file2.swift"].map {
            TreeDisplayModel.Row(name: ($0 as NSString).lastPathComponent, path: $0, isDirectory: false)
        }
        XCTAssertEqual(
            TreeDisplayModel.pathRows(boundary, section: "boundary", collapsed: []).map(\.displayName),
            ["dir", "sub / deep", "b.swift", "a.swift", "file2.swift", "file10.swift"]
        )
    }
}
