import Foundation
import XCTest
@testable import kero

private actor DelayedWorkspaceFixture: WorkspaceBackend {
    let name: String
    private(set) var created: [String] = []
    private(set) var statRequests = 0
    init(_ name: String) { self.name = name }

    func list(directory: String) async throws -> [WorkspaceEntry] { [WorkspaceEntry(name: "tracked.txt", isDirectory: false, isSymlink: false)] }
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
    func rename(from: String, to: String) async throws {}
    func delete(paths: [String]) async throws {}
    func gitRoot(containing path: String) async throws -> String? {
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

        let foreground = await automatic("/new", foreground: "/worktree").resolvedRoot()
        XCTAssertEqual(foreground.root, "/worktree-repo")
        XCTAssertEqual(foreground.source, .foreground(isWorktree: true))

        let pinned = PanelContext(identity: .pinned(project: project, workspace: nil, directory: "/pinned"), backend: backend)
        let pinnedResult = await pinned.resolvedRoot()
        XCTAssertEqual(pinnedResult.root, "/pinned")
        XCTAssertEqual(pinnedResult.source, .pinned)
        XCTAssertFalse(pinned.isRemote)
    }

    func testSelectedProjectOwnsGitAndFilesRefreshAcrossRapidSwitches() async throws {
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-panel-sync-\(UUID().uuidString)")
        let firstURL = base.appendingPathComponent("first")
        let secondURL = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("first".utf8).write(to: firstURL.appendingPathComponent("one.txt"))
        try Data("second".utf8).write(to: secondURL.appendingPathComponent("two.txt"))

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        let git = GitStatusModel()
        manager.addLocalItems([firstURL])
        let firstProject = try XCTUnwrap(manager.selectedProject)
        git.syncSelectedProject(in: manager)
        manager.addLocalItems([secondURL])
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
