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
    private var pauseNextRename = false
    private var pausedRename: CheckedContinuation<Void, Never>?
    private(set) var awaitingRename = false
    init(_ name: String) { self.name = name }

    func suspendNextList() { pauseNextList = true }
    func releaseList() {
        pausedList?.resume()
        pausedList = nil
        awaitingList = false
    }
    func suspendNextRename() { pauseNextRename = true }
    func releaseRename() {
        pausedRename?.resume()
        pausedRename = nil
        awaitingRename = false
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
        if path.hasSuffix("created.txt") || path.hasSuffix("moved.txt") { return nil }
        return WorkspaceStat(isRegular: !path.hasSuffix("/root"), isDirectory: path.hasSuffix("/root"), isSymlink: false, size: 0, mtime: .distantPast)
    }
    func readSymlinkDestination(path: String) async throws -> String? { nil }
    func read(path: String, maxBytes: Int) async throws -> Data { Data() }
    func write(path: String, data: Data) async throws {}
    func createFile(path: String) async throws { created.append(path); try await Task.sleep(for: .milliseconds(100)) }
    func createDirectory(path: String) async throws {}
    func copy(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func rename(from: String, to: String) async throws {
        renamed.append((from, to))
        if pauseNextRename {
            pauseNextRename = false
            awaitingRename = true
            await withCheckedContinuation { pausedRename = $0 }
        }
    }
    func delete(paths: [String]) async throws {}
    func run(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) async throws -> WorkspaceRunResult {
        if argv == ["pwd", "-P"], let cwd {
            return .init(status: 0, stdout: Data((cwd + "\n").utf8), stderr: Data())
        }
        return .init(status: 0, stdout: Data(), stderr: Data())
    }
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

    func testNewFileKeepsCurrentFileTreeIdentityAfterSync() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-files-target-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([folder])
        let project = try XCTUnwrap(manager.selectedProject)
        let context = try XCTUnwrap(project.panelContext)
        _ = await project.syncFiles(isCurrent: { true })
        XCTAssertTrue(project.fileTree.matchesIndexTarget(root: folder.path, context: context))
        await manager.newFile()
        XCTAssertTrue(project.fileTree.matchesIndexTarget(root: folder.path, context: context),
                      "Opening the new-file draft must not invalidate the existing Files target")
        XCTAssertNotNil(project.fileTree.draft)
    }

    func testNewFileAndFolderUseFocusedFilesDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-focused-create-" + UUID().uuidString)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let existing = nested.appendingPathComponent("existing.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "existing".write(to: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        _ = await project.syncFiles(isCurrent: { true })
        manager.showPanel(.files)

        let directory = try XCTUnwrap(project.fileTree.items.first { $0.path == nested.path })
        project.fileTree.select(directory)
        await project.fileTree.toggle(directory)
        await manager.newFile()
        XCTAssertEqual(project.fileTree.draft?.parentDir, nested.path,
                       "Creating inside a focused directory must not revert to the root")

        let selectedFile = try XCTUnwrap(project.fileTree.items.first { $0.path == existing.path })
        project.fileTree.select(selectedFile)
        await manager.newFolder()
        XCTAssertEqual(project.fileTree.draft?.parentDir, nested.path,
                       "Creating beside a focused file uses its parent folder")

        manager.showPanel(.git)
        await manager.newFile()
        XCTAssertEqual(project.fileTree.draft?.parentDir, root.path,
                       "An inactive Files selection cannot override another pane")

        manager.openFile(existing.path)
        await manager.newFolder()
        XCTAssertEqual(project.fileTree.draft?.parentDir, nested.path,
                       "Creating from an active editor uses its file's containing directory")

        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-outside-" + UUID().uuidString + ".txt")
        try "outside".write(to: external, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: external) }
        manager.openFile(external.path)
        await manager.newFile()
        XCTAssertEqual(project.fileTree.draft?.parentDir, root.path,
                       "An editor file outside the project cannot create outside its root")
    }

    func testRemountedFilesReusesTrustedTargetDuringPendingRefresh() async throws {
        let backend = DelayedWorkspaceFixture("same-channel")
        let identity = PanelContext.Identity(
            project: UUID(), workspace: "ssh:fixture", directory: "/root"
        )
        let context = PanelContext(identity: identity, backend: backend)
        let tree = FileTreeModel()
        await tree.sync(
            root: "/root", backend: backend, scope: context.scope,
            panelIdentity: identity, connectionRevision: context.connectionRevision
        )
        XCTAssertEqual(tree.syncedTarget(for: context), identity)
        XCTAssertEqual(tree.items.count, 1)

        await backend.suspendNextList()
        let refreshing = Task {
            await tree.sync(
                root: "/root", backend: backend, scope: context.scope,
                panelIdentity: identity, connectionRevision: context.connectionRevision
            )
        }
        try await wait { await backend.awaitingList }
        XCTAssertEqual(tree.syncedTarget(for: context), identity,
                       "A remounted Files panel must accept a trusted tree while IO is pending")
        XCTAssertEqual(tree.items.count, 1)

        let otherRoot = PanelContext(
            identity: .init(project: UUID(), workspace: "ssh:fixture", directory: "/other"),
            backend: backend
        )
        XCTAssertNil(tree.syncedTarget(for: otherRoot),
                     "An older tree must not operate under a different workspace")
        let otherBackend = PanelContext(identity: identity, backend: DelayedWorkspaceFixture("other"))
        XCTAssertNil(tree.syncedTarget(for: otherBackend),
                     "A reconnected backend cannot use a previous channel's tree")
        await backend.releaseList()
        await refreshing.value
    }

    func testClosingAllTabsDoesNotInvalidatePinnedFilesTarget() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-rapid-close-target-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([folder])
        let project = try XCTUnwrap(manager.selectedProject)
        _ = await project.syncFiles(isCurrent: { true })
        let context = try XCTUnwrap(project.panelContext)
        XCTAssertEqual(project.fileTree.syncedTarget(for: context), context.identity)
        for index in 0..<30 {
            project.openFile(folder.appendingPathComponent("file-\(index).swift").path)
        }
        for tab in project.tabs.reversed() { project.close(tab) }
        XCTAssertTrue(project.tabs.isEmpty)
        XCTAssertEqual(project.fileTree.syncedTarget(for: context), context.identity,
                       "Closing the last editor tab must not disable an unchanged Files tree")
    }

    func testCompletedRenameReportsTrueDiskResultAfterFileTreeTargetSwitch() async throws {
        let backend = DelayedWorkspaceFixture("old")
        let tree = FileTreeModel()
        await tree.sync(root: "/project/root", backend: backend, scope: "ssh:old")
        let item = try XCTUnwrap(tree.items.first { !$0.isDirectory && !$0.isDraft })
        await backend.suspendNextRename()
        let operation = Task { await tree.rename(item, to: "moved.txt") }
        try await wait { await backend.awaitingRename }
        await tree.sync(root: "/different/root", backend: backend, scope: "ssh:new")
        await backend.releaseRename()
        let result = await operation.value
        XCTAssertEqual(result, "/project/root/moved.txt",
                       "A completed backend mutation must be reported even if the old tree was replaced")
        XCTAssertEqual(tree.rootPath, "/different/root")
        XCTAssertFalse(tree.items.contains { $0.path == result },
                       "A late success must not publish into the new tree")
    }

    func testLocalProjectCannotBorrowTerminalSSHForInteractiveGitRebase() {
        let project = Project(fallbackName: "Local", workspaceConfiguration: .standard)
        project.customDirectory = "/tmp/fixed-root"
        let remote = PanelContext(
            identity: .init(project: project.id, workspace: "ssh:some-host", directory: "/remote"),
            backend: DelayedWorkspaceFixture("remote")
        )
        XCTAssertThrowsError(try project.newInteractiveGitSession(
            repository: "/remote", arguments: ["rebase", "--interactive", "HEAD~1"],
            context: remote
        ))
        XCTAssertTrue(project.tabs.isEmpty,
                      "A local project must not start a remote Git task from a terminal's SSH state")
    }

    func testIdentityIncludesFixedDirectoryWorkspaceAndProject() {
        let backend = DelayedWorkspaceFixture("first")
        func fixed(_ directory: String, workspace: String? = nil, project: UUID) -> PanelContext {
            PanelContext(identity: .init(
                project: project, workspace: workspace, directory: directory
            ), backend: backend)
        }
        let project = UUID()
        XCTAssertNotEqual(fixed("/old", project: project).identity,
                          fixed("/new", project: project).identity)
        XCTAssertNotEqual(fixed("/new", project: project).identity,
                          fixed("/new", workspace: "ssh:remote", project: project).identity)
        XCTAssertNotEqual(fixed("/new", project: project).identity,
                          fixed("/new", project: UUID()).identity)
        XCTAssertEqual(fixed("/new", project: project).cwd, "/new")
        XCTAssertFalse(fixed("/new", project: project).isRemote)
        XCTAssertTrue(fixed("/new", workspace: "ssh:remote", project: project).isRemote)
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
        manager.syncGitStatus(git)
        manager.addLocalFolders([secondURL])
        let secondProject = try XCTUnwrap(manager.selectedProject)
        manager.syncGitStatus(git)
        try await wait { git.rootPath == secondURL.path && git.hasResolvedStatus && !git.isRefreshing }
        XCTAssertEqual(git.rootPath, secondURL.path)
        XCTAssertEqual(git.currentScope, "local")
        let inactiveResult = await firstProject.syncFiles(isCurrent: { manager.selectedProject === firstProject })
        XCTAssertNil(inactiveResult, "Inactive project must not issue a refresh")

        let secondResult = await secondProject.syncFiles(isCurrent: { manager.selectedProject === secondProject })
        XCTAssertEqual(secondResult, secondProject.panelContext?.identity)
        XCTAssertEqual(secondProject.fileTree.rootPath, secondURL.path)
        XCTAssertTrue(secondProject.fileTree.items.contains { $0.path == secondURL.appendingPathComponent("two.txt").path })
        XCTAssertFalse(secondProject.fileTree.items.contains { $0.path == firstURL.appendingPathComponent("one.txt").path })

        manager.selectedProjectID = firstProject.id
        manager.syncGitStatus(git)
        try await wait { git.rootPath == firstURL.path && git.hasResolvedStatus && !git.isRefreshing }
        let firstResult = await firstProject.syncFiles(isCurrent: { manager.selectedProject === firstProject })
        XCTAssertEqual(firstResult, firstProject.panelContext?.identity)
        XCTAssertEqual(firstProject.fileTree.rootPath, firstURL.path)
        XCTAssertTrue(firstProject.fileTree.items.contains { $0.path == firstURL.appendingPathComponent("one.txt").path })
        XCTAssertEqual(secondProject.fileTree.rootPath, secondURL.path)
    }

    func testGitFixedTargetFollowsOnlyAuthorizedProject() throws {
        let project = Project(fallbackName: "Fixed", workspaceConfiguration: .standard)
        project.customDirectory = "/tmp/bailey-git-fixed"
        let model = GitStatusModel()
        model.syncSelectedProject(project: project) { $0 === project }
        XCTAssertEqual(model.rootPath, "/tmp/bailey-git-fixed")
        XCTAssertTrue(model.matchesPanelTarget(try XCTUnwrap(project.panelContext).identity))

        project.customDirectory = "/tmp/bailey-git-renamed"
        model.syncSelectedProject(project: project) { $0 === project }
        XCTAssertEqual(model.rootPath, "/tmp/bailey-git-renamed")
        XCTAssertTrue(model.matchesPanelTarget(try XCTUnwrap(project.panelContext).identity))

        model.syncSelectedProject(project: project) { _ in false }
        XCTAssertTrue(model.rootPath.isEmpty)
        XCTAssertFalse(model.matchesPanelTarget(try XCTUnwrap(project.panelContext).identity))
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

    func testPinnedSSHReconnectStartsNewPanelSyncBeforeOldRequestCompletes() async throws {
        let oldBackend = DelayedWorkspaceFixture("old-channel")
        let freshBackend = DelayedWorkspaceFixture("new-channel")
        await oldBackend.suspendNextList()
        let tree = FileTreeModel()
        let queue = PanelSyncQueue()
        let identity = PanelContext.Identity(
            project: UUID(), workspace: "ssh:fixture", directory: "/root"
        )
        queue.run(for: identity, connectionRevision: 1) {
            await tree.sync(root: "/root", backend: oldBackend,
                            scope: "ssh:fixture", panelIdentity: identity, connectionRevision: 1)
        }
        try await wait { await oldBackend.awaitingList }
        queue.run(for: identity, connectionRevision: 2) {
            await tree.sync(root: "/root", backend: freshBackend,
                            scope: "ssh:fixture", panelIdentity: identity, connectionRevision: 2)
        }
        try await wait { tree.items.map(\.path) == ["/root/new.txt"] }
        await oldBackend.releaseList()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(tree.items.map(\.path), ["/root/new.txt"],
                       "An old pinned SSH request must not overwrite the reconnected tree")
    }

    func testPanelSyncQueueSwitchesTargetBeforeOldDirectoryCompletes() async throws {
        let oldBackend = DelayedWorkspaceFixture("old-channel")
        let freshBackend = DelayedWorkspaceFixture("new-channel")
        await oldBackend.suspendNextList()
        let tree = FileTreeModel()
        let queue = PanelSyncQueue()
        let project = UUID()
        let oldTarget = PanelContext.Identity(
            project: project, workspace: "ssh:fixture", directory: "/root/old"
        )
        let freshTarget = PanelContext.Identity(
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
        let oldTarget = PanelContext.Identity(
            project: project, workspace: "ssh:fixture", directory: "/root/old"
        )
        let middleTarget = PanelContext.Identity(
            project: project, workspace: "ssh:fixture", directory: "/root/middle"
        )
        let newestTarget = PanelContext.Identity(
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
        let target = PanelContext.Identity(
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
