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
