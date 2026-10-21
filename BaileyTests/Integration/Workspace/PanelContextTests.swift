import Foundation
import XCTest
@testable import Bailey

private actor DelayedWorkspaceFixture: WorkspaceBackend {
    let name: String
    private(set) var created: [String] = []
    private(set) var renamed: [(String, String)] = []
    private(set) var statRequests = 0
    private var pauseNextList = false
    private var pausedList: CheckedContinuation<Void, Never>?
    private(set) var awaitingList = false
    private var gitProbeUnavailable = false
    func setGitProbeUnavailable(_ value: Bool) { gitProbeUnavailable = value }
    init(_ name: String) { self.name = name }

    func suspendNextList() { pauseNextList = true }
    func releaseList() {
        pausedList?.resume()
        pausedList = nil
        awaitingList = false
    }
    func list(directory: String) async throws -> [WorkspaceEntry] {
        if pauseNextList {
            pauseNextList = false
            awaitingList = true
            await withCheckedContinuation { pausedList = $0 }
        }
        let filename = name == "old-channel" ? "old.txt" : name == "new-channel" ? "new.txt" : "tracked.txt"
        return [WorkspaceEntry(name: filename, isDirectory: false, isSymlink: false)]
    }
    func stat(path: String) async throws -> WorkspaceStat? {
        if path.hasSuffix("stale.txt") {
            statRequests += 1
            try await Task.sleep(for: .milliseconds(100))
            return nil
        }
        if path.hasSuffix("created.txt") { return nil }
        return WorkspaceStat(isRegular: !path.hasSuffix("/root"), isDirectory: path.hasSuffix("/root"), isSymlink: false, size: 0, mtime: .distantPast)
    }
    func readSymlinkDestination(path: String) async throws -> String? { nil }
    func read(path: String, maxBytes: Int) async throws -> Data { Data() }
    func write(path: String, data: Data) async throws {}
    func createFile(path: String) async throws { created.append(path); try await Task.sleep(for: .milliseconds(100)) }
    func createDirectory(path: String) async throws {}
    func rename(from: String, to: String) async throws { renamed.append((from, to)) }
    func delete(paths: [String]) async throws {}
    func gitRoot(containing path: String) async throws -> String? {
        if gitProbeUnavailable { throw WorkspaceError.timedOut }
        try await Task.sleep(for: .milliseconds(path == "/old" ? 100 : 5))
        return path + "-repo"
    }
    func isLinkedWorktree(_ root: String) async throws -> Bool { true }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult { .init(status: 0, stdout: Data(), stderr: Data()) }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot { .init(descendants: [], namesByPid: [:]) }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { [] }
    func kill(pid: pid_t, force: Bool) async throws {}
}

@MainActor
final class PanelContextTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()) {
            guard Date() < deadline else { return XCTFail("Fixture did not settle") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testIdentityIncludesDirectoryForegroundWorkspaceConnectionAndState() async {
        let project = UUID(), session = UUID(), firstConnection = UUID(), secondConnection = UUID()
        let backend = DelayedWorkspaceFixture("first")
        func automatic(_ cwd: String, foreground: String? = nil, workspace: String? = nil, connection: UUID? = nil) -> PanelContext {
            PanelContext(identity: .automatic(
                project: project, workspace: workspace, directory: cwd, foreground: foreground,
                session: session, connection: connection, state: connection == nil ? nil : .connected
            ), backend: backend)
        }
        XCTAssertNotEqual(automatic("/old").identity, automatic("/new").identity)
        XCTAssertNotEqual(automatic("/new").identity, automatic("/new", foreground: "/worktree").identity)
        XCTAssertNotEqual(
            automatic("/new", workspace: "remote", connection: firstConnection).identity,
            automatic("/new", workspace: "remote", connection: secondConnection).identity
        )

        let foreground = try? await automatic("/new", foreground: "/worktree").resolvedRoot()
        XCTAssertEqual(foreground?.root, "/worktree-repo")
        XCTAssertEqual(foreground?.source, .foreground(isWorktree: true))

        let pinned = PanelContext(identity: .pinned(project: project, workspace: nil, directory: "/pinned"), backend: backend)
        let pinnedResult = try? await pinned.resolvedRoot()
        XCTAssertEqual(pinnedResult?.root, "/pinned")
        XCTAssertEqual(pinnedResult?.source, .pinned)
        XCTAssertFalse(pinned.isRemote)
    }

    func testFailedSSHRepositoryProbeNeverLooksLikeAValidLocalDirectory() async throws {
        let backend = DelayedWorkspaceFixture("disconnected")
        await backend.setGitProbeUnavailable(true)
        let context = PanelContext(identity: .automatic(
            project: UUID(), workspace: "ssh:remote", directory: "/remote/work",
            foreground: "/remote/another", session: UUID(), connection: UUID(), state: .disconnected
        ), backend: backend)
        do {
            _ = try await context.resolvedRoot()
            XCTFail("SSH failure must not silently resolve /remote/work as a repository")
        } catch WorkspaceError.timedOut {
            // Only confirmed non-repositories are allowed to fall back to cwd.
        }
    }

    func testSelectedProjectOwnsGitAndFilesRefreshAcrossRapidSwitches() async throws {
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-panel-sync-\(UUID().uuidString)")
        let firstURL = base.appendingPathComponent("first")
        let secondURL = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("first".utf8).write(to: firstURL.appendingPathComponent("one.txt"))
        try Data("second".utf8).write(to: secondURL.appendingPathComponent("two.txt"))

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let git = GitStatusModel()
        manager.addLocalFolders([firstURL])
        let firstProject = try XCTUnwrap(manager.selectedProject)
        git.syncSelectedProject(in: manager)
        manager.addLocalFolders([secondURL])
        let secondProject = try XCTUnwrap(manager.selectedProject)
        git.syncSelectedProject(in: manager)
        try await wait { git.rootPath == secondURL.path && git.hasResolvedStatus && !git.isRefreshing }
        XCTAssertEqual(git.rootPath, secondURL.path)
        XCTAssertEqual(git.currentScope, "local")
        let inactiveResult = await firstProject.syncFiles(in: manager)
        XCTAssertNil(inactiveResult, "Inactive project must not issue a refresh")

        let secondResult = await secondProject.syncFiles(in: manager)
        XCTAssertEqual(secondResult?.0, .pinned)
        XCTAssertEqual(secondProject.fileTree.rootPath, secondURL.path)
        XCTAssertTrue(secondProject.fileTree.items.contains { $0.path == secondURL.appendingPathComponent("two.txt").path })
        XCTAssertFalse(secondProject.fileTree.items.contains { $0.path == firstURL.appendingPathComponent("one.txt").path })

        manager.selectedProjectID = firstProject.id
        git.syncSelectedProject(in: manager)
        try await wait { git.rootPath == firstURL.path && git.hasResolvedStatus && !git.isRefreshing }
        let firstResult = await firstProject.syncFiles(in: manager)
        XCTAssertEqual(firstResult?.0, .pinned)
        XCTAssertEqual(firstProject.fileTree.rootPath, firstURL.path)
        XCTAssertTrue(firstProject.fileTree.items.contains { $0.path == firstURL.appendingPathComponent("one.txt").path })
        XCTAssertEqual(secondProject.fileTree.rootPath, secondURL.path)
    }

    func testFileTreeDoesNotPublishOldChannelAtSameRootAndScope() async throws {
        let old = DelayedWorkspaceFixture("old-channel")
        let replacement = DelayedWorkspaceFixture("new-channel")
        await old.suspendNextList()
        await replacement.suspendNextList()
        let tree = FileTreeModel()
        let first = Task { await tree.sync(root: "/root", backend: old, scope: "ssh:stable") }
        try await wait { await old.awaitingList }
        let second = Task { await tree.sync(root: "/root", backend: replacement, scope: "ssh:stable") }
        try await wait { await replacement.awaitingList }
        XCTAssertTrue(tree.items.isEmpty, "An old channel cannot publish while replacement is loading")
        await replacement.releaseList()
        await second.value
        XCTAssertEqual(tree.items.map(\.path), ["/root/new.txt"],
                       "The replacement must not wait for the stalled old channel")
        await old.releaseList()
        await first.value
        XCTAssertEqual(tree.items.map(\.path), ["/root/new.txt"],
                       "A late old channel must not overwrite the replacement")
    }

    func testPanelSyncQueueSwitchesTargetBeforeOldDirectoryCompletes() async throws {
        let oldBackend = DelayedWorkspaceFixture("old-channel")
        let freshBackend = DelayedWorkspaceFixture("new-channel")
        await oldBackend.suspendNextList()
        let tree = FileTreeModel()
        let queue = PanelSyncQueue()
        let project = UUID()
        let oldTarget = PanelContext.Identity.pinned(
            project: project, workspace: "ssh:fixture", directory: "/root/old"
        )
        let freshTarget = PanelContext.Identity.pinned(
            project: project, workspace: "ssh:fixture", directory: "/root/new"
        )
        queue.run(for: oldTarget) {
            await tree.sync(root: "/root", backend: oldBackend, scope: "ssh:fixture")
        }
        try await wait { await oldBackend.awaitingList }
        queue.run(for: freshTarget) {
            await tree.sync(root: "/root", backend: freshBackend, scope: "ssh:fixture")
        }
        let deadline = Date().addingTimeInterval(1)
        while !tree.items.contains(where: { $0.path == "/root/new.txt" }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let publishedWhileOldBlocked = tree.items.map(\.path) == ["/root/new.txt"]
        await oldBackend.releaseList()
        XCTAssertTrue(publishedWhileOldBlocked, "A changed panel target must not wait for the old SSH request")
        try await wait { tree.items.map(\.path) == ["/root/new.txt"] }
    }

    func testPanelSyncQueueRapidThreeTargetSwitchesPublishOnlyNewestTree() async throws {
        let oldBackend = DelayedWorkspaceFixture("old-channel")
        let middleBackend = DelayedWorkspaceFixture("old-channel")
        let newestBackend = DelayedWorkspaceFixture("new-channel")
        await oldBackend.suspendNextList()
        await middleBackend.suspendNextList()
        let tree = FileTreeModel()
        let queue = PanelSyncQueue()
        let project = UUID()
        let oldTarget = PanelContext.Identity.pinned(
            project: project, workspace: "ssh:fixture", directory: "/root/old"
        )
        let middleTarget = PanelContext.Identity.pinned(
            project: project, workspace: "ssh:fixture", directory: "/root/middle"
        )
        let newestTarget = PanelContext.Identity.pinned(
            project: project, workspace: "ssh:fixture", directory: "/root/new"
        )
        queue.run(for: oldTarget) {
            await tree.sync(root: "/root/old", backend: oldBackend, scope: "ssh:fixture")
        }
        try await wait { await oldBackend.awaitingList }
        queue.run(for: middleTarget) {
            await tree.sync(root: "/root/middle", backend: middleBackend, scope: "ssh:fixture")
        }
        try await wait { await middleBackend.awaitingList }
        queue.run(for: newestTarget) {
            await tree.sync(root: "/root/new", backend: newestBackend, scope: "ssh:fixture")
        }
        try await wait { tree.items.map(\.path) == ["/root/new/new.txt"] }
        await middleBackend.releaseList()
        await oldBackend.releaseList()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(tree.rootPath, "/root/new")
        XCTAssertEqual(tree.items.map(\.path), ["/root/new/new.txt"])
    }

    func testBackendSwitchClearsOldRowsAndDraftWithoutChangingPath() async throws {
        let old = DelayedWorkspaceFixture("old-channel")
        let fresh = DelayedWorkspaceFixture("new-channel")
        let tree = FileTreeModel()
        await tree.sync(root: "/root", backend: old, scope: "ssh:fixture")
        XCTAssertEqual(tree.items.map(\.path), ["/root/old.txt"])
        await tree.beginNewFile(in: "/root")
        XCTAssertNotNil(tree.draft)
        await fresh.suspendNextList()
        let replace = Task { await tree.sync(root: "/root", backend: fresh, scope: "ssh:fixture") }
        try await wait { await fresh.awaitingList }
        XCTAssertTrue(tree.items.isEmpty, "Previous connection rows must not remain visible on the new channel")
        XCTAssertNil(tree.draft, "A draft from the old connection must not target a new backend")
        await fresh.releaseList()
        await replace.value
        XCTAssertEqual(tree.items.map(\.path), ["/root/new.txt"])
    }

    func testBackendSwitchDuringFileCreationAndRenameRejectsOldOperations() async throws {
        let old = DelayedWorkspaceFixture("old-channel")
        let fresh = DelayedWorkspaceFixture("new-channel")
        let tree = FileTreeModel()
        await tree.sync(root: "/root", backend: old, scope: "ssh:fixture")
        await tree.beginNewFile(in: "/root")
        let create = Task { await tree.commitDraft(name: "stale.txt") }
        try await wait { await old.statRequests == 1 }
        await tree.sync(root: "/root", backend: fresh, scope: "ssh:fixture")
        let createdPath = await create.value
        let createdByOldChannel = await old.created
        XCTAssertNil(createdPath)
        XCTAssertTrue(createdByOldChannel.isEmpty, "A stale channel must not create a file after replacement")

        await tree.sync(root: "/root", backend: old, scope: "ssh:fixture")
        let original = try XCTUnwrap(tree.items.first { $0.path == "/root/old.txt" })
        let rename = Task { await tree.rename(original, to: "stale.txt") }
        try await wait { await old.statRequests == 2 }
        await tree.sync(root: "/root", backend: fresh, scope: "ssh:fixture")
        let renamedPath = await rename.value
        let renamedByOldChannel = await old.renamed
        XCTAssertNil(renamedPath)
        XCTAssertTrue(renamedByOldChannel.isEmpty, "A stale channel must not rename a file after replacement")
    }

    func testPanelSyncQueueCoalescesSameTargetWithLatestRequest() async throws {
        let backend = DelayedWorkspaceFixture("old-channel")
        await backend.suspendNextList()
        let queue = PanelSyncQueue()
        let target = PanelContext.Identity.pinned(
            project: UUID(), workspace: "ssh:fixture", directory: "/root"
        )
        var completed: [String] = []
        queue.run(for: target) {
            _ = try? await backend.list(directory: "/root")
            completed.append("first")
        }
        try await wait { await backend.awaitingList }
        queue.run(for: target) { completed.append("superseded") }
        queue.run(for: target) { completed.append("latest") }
        await backend.releaseList()
        try await wait { completed.count == 2 }
        XCTAssertEqual(completed, ["first", "latest"])
    }

    func testOldTraversalCannotPublishAfterSwitchingRootOnSameBackend() async throws {
        let backend = DelayedWorkspaceFixture("same-channel")
        await backend.suspendNextList()
        let tree = FileTreeModel()
        let old = Task { await tree.sync(root: "/old", backend: backend, scope: "ssh:stable") }
        try await wait { await backend.awaitingList }
        await tree.sync(root: "/new", backend: backend, scope: "ssh:stable")
        XCTAssertEqual(tree.items.map(\.path), ["/new/tracked.txt"])
        await backend.releaseList()
        await old.value
        XCTAssertEqual(tree.items.map(\.path), ["/new/tracked.txt"])
    }

    func testLateFileCreationDoesNotPublishAfterTargetChanges() async throws {
        let backend = DelayedWorkspaceFixture("first")
        let tree = FileTreeModel()
        await tree.sync(root: "/root", backend: backend)
        await tree.beginNewFile(in: "/root")
        var current = true
        let creation = Task { await tree.commitDraft(name: "stale.txt", isCurrentTarget: { current }) }
        try await wait { await backend.statRequests > 0 }
        current = false
        let result = await creation.value
        let created = await backend.created
        XCTAssertNil(result)
        XCTAssertTrue(created.isEmpty)
    }
}
