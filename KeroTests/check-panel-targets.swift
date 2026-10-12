import Foundation


actor DelayedWorkspace: WorkspaceBackend {
    let name: String
    private(set) var created: [String] = []
    private(set) var deleted: [String] = []
    private(set) var statRequests = 0

    init(_ name: String) { self.name = name }

    func list(directory: String) async throws -> [WorkspaceEntry] {
        [WorkspaceEntry(name: "tracked.txt", isDirectory: false, isSymlink: false)]
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
    func createFile(path: String) async throws {
        created.append(path)
        try await Task.sleep(for: .milliseconds(100))
    }
    func createDirectory(path: String) async throws {}
    func rename(from: String, to: String) async throws {}
    func delete(paths: [String]) async throws { deleted += paths }
    func gitRoot(containing path: String) async throws -> String? {
        try await Task.sleep(for: .milliseconds(path == "/old" ? 100 : 5))
        return path + "-repo"
    }
    func isLinkedWorktree(_ root: String) async throws -> Bool { true }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        WorkspaceRunResult(status: 0, stdout: Data(), stderr: Data())
    }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot {
        try await Task.sleep(for: .milliseconds(100))
        return WorkspaceProcessSnapshot(
            descendants: [WorkspaceProcess(pid: 42, name: name, executable: "/" + name, cpu: 1, memoryKB: 1)],
            namesByPid: [pid: "-" + name, 42: name]
        )
    }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { [WorkspacePort(port: 8080, pid: 42)] }
    func kill(pid: pid_t, force: Bool) async throws {}
}

@main
enum PanelTargetsCheck {
    @MainActor
    static func wait(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()) {
            precondition(Date() < deadline, "Delayed fixture did not settle")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    static func main() async throws {
        let project = UUID(), session = UUID(), firstConnection = UUID(), secondConnection = UUID()
        let first = DelayedWorkspace("first"), second = DelayedWorkspace("second")
        func automatic(_ cwd: String, foreground: String? = nil, workspace: String? = nil, connection: UUID? = nil) -> PanelContext {
            PanelContext(identity: .automatic(
                project: project, workspace: workspace, directory: cwd, foreground: foreground,
                session: session, connection: connection, state: connection == nil ? nil : .connected
            ), backend: first)
        }
        let old = automatic("/old")
        let current = automatic("/new")
        precondition(old.identity != current.identity)
        precondition(current.identity != automatic("/new", foreground: "/worktree").identity)
        precondition(current.identity != automatic("/new", workspace: "remote", connection: firstConnection).identity)
        precondition(automatic("/new", workspace: "remote", connection: firstConnection).identity
            != automatic("/new", workspace: "remote", connection: secondConnection).identity)
        var active = old.identity
        var published: String?
        let oldRequest = Task {
            let result = await old.resolvedRoot()
            if active == old.identity { published = result.root }
        }
        active = current.identity
        let currentResult = await current.resolvedRoot()
        if active == current.identity { published = currentResult.root }
        await oldRequest.value
        precondition(published == "/new-repo")
        let foreground = await automatic("/new", foreground: "/worktree").resolvedRoot()
        precondition(foreground.root == "/worktree-repo" && foreground.source == .foreground(isWorktree: true))
        let pinned = PanelContext(identity: .pinned(project: project, workspace: nil, directory: "/pinned"), backend: first)
        let pinnedResult = await pinned.resolvedRoot()
        precondition(pinnedResult.root == "/pinned" && pinnedResult.source == .pinned)
        precondition(pinned.foreground == nil && !pinned.isRemote)
        let remotePin = PanelContext(identity: .pinned(project: project, workspace: "remote", directory: "/pinned"), backend: second)
        precondition(pinned.identity != remotePin.identity && remotePin.isRemote)
        let disconnected = PanelContext(identity: .automatic(
            project: project, workspace: "remote", directory: "/new", foreground: nil,
            session: session, connection: firstConnection, state: .disconnected
        ), backend: first)
        precondition(disconnected.identity != automatic("/new", workspace: "remote", connection: firstConnection).identity)

        let staleTree = FileTreeModel()
        await staleTree.sync(root: "/root", backend: first)
        await staleTree.beginNewFile(in: "/root")
        var targetIsCurrent = true
        let staleCreate = Task {
            await staleTree.commitDraft(name: "stale.txt", isCurrentTarget: { targetIsCurrent })
        }
        try await wait { await first.statRequests > 0 }
        targetIsCurrent = false
        let staleCreated = await staleCreate.value
        let staleWrites = await first.created
        precondition(staleCreated == nil && staleWrites.isEmpty)

        let tree = FileTreeModel()
        await tree.sync(root: "/root", backend: first)
        await tree.beginNewFile(in: "/root")
        var opened: [String] = []
        active = pinned.identity
        let create = Task {
            if let created = await tree.commitDraft(name: "created.txt"), active == pinned.identity {
                opened.append(created)
            }
        }
        try await wait { !(await first.created).isEmpty }
        active = .pinned(project: UUID(), workspace: "remote", directory: "/root")
        await create.value
        precondition(opened.isEmpty)
        let item = tree.items.first!
        let deleteTarget = active
        active = current.identity
        if active == deleteTarget { await tree.delete(item) }
        let deletions = await second.deleted
        let originalDeletions = await first.deleted
        precondition(deletions.isEmpty && originalDeletions.isEmpty)
        print("PASS: delayed root/foreground/machine/connection identity, Files delayed-create/confirmation boundaries")
    }
}
