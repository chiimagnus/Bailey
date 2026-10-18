import Foundation
import XCTest
@testable import Bailey

private actor IdentityWorkspaceFixture: WorkspaceBackend {
    private(set) var writes = 0
    func list(directory: String) async throws -> [WorkspaceEntry] { [] }
    func stat(path: String) async throws -> WorkspaceStat? {
        WorkspaceStat(isRegular: true, isDirectory: false, isSymlink: false, size: 7, mtime: .distantPast)
    }
    func readSymlinkDestination(path: String) async throws -> String? { nil }
    func read(path: String, maxBytes: Int) async throws -> Data { Data("remote\n".utf8) }
    func write(path: String, data: Data) async throws { writes += 1 }
    func createFile(path: String) async throws {}
    func createDirectory(path: String) async throws {}
    func rename(from: String, to: String) async throws {}
    func delete(paths: [String]) async throws {}
    func gitRoot(containing path: String) async throws -> String? { nil }
    func isLinkedWorktree(_ root: String) async throws -> Bool { false }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult { .init(status: 0, stdout: Data(), stderr: Data()) }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot { .init(descendants: [], namesByPid: [:]) }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { [] }
    func kill(pid: pid_t, force: Bool) async throws {}
}

private actor FailingCreateRunnerFixture: RemoteCommandRunner {
    private(set) var commands: [[String]] = []
    func run(_ argv: [String], stdin: Data?, timeout: TimeInterval) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        commands.append(argv)
        return (1, Data(), Data("controlled creation failure".utf8))
    }
}

@MainActor
final class WorkspaceIdentityTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { return XCTFail("App model did not settle") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func connection(port: Int = 22) -> RemoteConnection {
        let connection = RemoteConnection(
            user: "fixture", host: "invalid", port: port,
            controlSocket: URL(fileURLWithPath: "/tmp/bailey-no-such-identity-socket"), sshPID: 0
        )
        connection.workingDirectory = "/fixture"
        connection.markConnected()
        return connection
    }

    func testFinderTerminalDropDoesNotInjectControlCharactersOrExecute() {
        let simple = URL(fileURLWithPath: "/tmp/simple.txt")
        let quoted = URL(fileURLWithPath: "/tmp/it's a $cost; 🚀.md")
        XCTAssertEqual(
            BaileyTerminalView.fileDropText(for: [simple, quoted]),
            "/tmp/simple.txt '/tmp/it'\\''s a $cost; 🚀.md' "
        )
        XCTAssertNil(BaileyTerminalView.fileDropText(for: []))
        XCTAssertNil(BaileyTerminalView.fileDropText(for: [URL(string: "https://example.com")!]))
        for unsafe in ["new\nline", "return\rname", "escape\u{001B}name", "bell\u{0007}name", "tab\tname"] {
            let unsafeURL = URL(fileURLWithPath: "/tmp/" + unsafe)
            XCTAssertNil(
                BaileyTerminalView.fileDropText(for: [simple, unsafeURL]),
                "Reject the entire batch before any control byte reaches the PTY"
            )
        }
    }

    func testFinderTerminalDropRespectsFixedSSHLaunchAndDynamicConnection() {
        let local = TerminalSession(launchCommand: "exec /bin/sh -i")
        XCTAssertTrue(local.acceptsLocalFileDrop)
        let activeRemote = connection()
        local.location = .remote(activeRemote)
        XCTAssertFalse(local.acceptsLocalFileDrop)
        activeRemote.markDisconnected(reason: "fixture disconnect")
        XCTAssertFalse(local.acceptsLocalFileDrop, "Disconnected ssh is not a Mac shell")
        local.location = .local
        XCTAssertTrue(local.acceptsLocalFileDrop, "A dynamic ssh session can return to its local shell")

        let fixed = Project(fallbackName: "remote", workspaceConfiguration: .standard)
        fixed.sshHost = "fixture-ssh-host"
        let waiting = fixed.newSession()
        defer { fixed.terminateAll() }
        XCTAssertNil(waiting.workspaceIdentity, "Before SSH handoff the remote identity is not populated")
        XCTAssertFalse(waiting.acceptsLocalFileDrop, "Fixed SSH launch intent is already remote")
        waiting.location = .remote(connection())
        XCTAssertFalse(waiting.acceptsLocalFileDrop)
        waiting.location = .local
        XCTAssertFalse(waiting.acceptsLocalFileDrop, "A fixed SSH terminal never accepts a Mac path")
    }

    func testProjectSSHAndWorkspaceCommandsUseTheSameScopedControlSocket() {
        let options = SSHMultiplexing.options
        XCTAssertTrue(options.contains("ControlMaster=auto"))
        XCTAssertTrue(options.contains("ControlPersist=180"))
        XCTAssertTrue(options.contains(where: { $0.hasPrefix("ControlPath=") && $0.contains("%C") }))
        let command = Project.remoteTerminalCommand(host: "alias", directory: "/d/my files")
        for option in options { XCTAssertTrue(command.contains(option)) }
        XCTAssertTrue(command.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(command.contains("BatchMode=yes"))
    }

    func testLocalAndRemoteSamePathRemainDifferentTargets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("file.txt").path
        try Data("local\n".utf8).write(to: URL(fileURLWithPath: path))

        let project = Project(fallbackName: "identity", workspaceConfiguration: .standard)
        project.customDirectory = directory.path
        let session = project.newSession()
        defer { project.terminateAll() }
        let first = connection()
        session.location = .remote(first)

        project.openFile(path)
        guard case .file(let localFile) = try XCTUnwrap(project.selectedTab).content else {
            return XCTFail("Expected local file")
        }
        XCTAssertNil(localFile.workspaceIdentity)
        try await localFile.waitForText()

        let remoteBackend = IdentityWorkspaceFixture()
        let remoteFile = FileTab(path: path, backend: remoteBackend, workspaceIdentity: first.workspaceIdentity)
        try await remoteFile.waitForText()
        project.append(PaneTab(content: .file(remoteFile)))
        try await wait { if case .text = remoteFile.content { return true }; return false }
        XCTAssertNotNil(remoteFile.workspaceIdentity)

        localFile.text = "local save\n"
        localFile.refreshDirtyState()
        await localFile.save()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("local save\n".utf8))

        remoteFile.text = "remote unsaved\n"
        remoteFile.refreshDirtyState()
        first.markDisconnected(reason: "fixture")
        session.location = .remote(first)
        project.rebindRemoteTabs()
        await remoteFile.save()
        XCTAssertTrue(remoteFile.isDirty)
        XCTAssertNotNil(remoteFile.saveError)
        let writeCount = await remoteBackend.writes
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("local save\n".utf8))
    }

    func testSSHStateChangeRebindsRemoteFileWithoutPublisherRelay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("remote-owned.txt")
        try Data("local sentinel".utf8).write(to: path)

        let project = Project(fallbackName: "remote observer", workspaceConfiguration: .standard)
        let session = project.newSession()
        defer { project.terminateAll() }
        let connection = RemoteConnection(
            user: "fixture", host: "invalid", port: 2222,
            controlSocket: URL(fileURLWithPath: "/tmp/bailey-observation-rebind-no-socket"),
            sshPID: 0
        )
        connection.workingDirectory = directory.path
        connection.markConnected()
        XCTAssertTrue(session.beginRemoteConnection(connection))

        let file = FileTab(
            path: path.path, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: connection.workspaceIdentity
        )
        try await file.waitForText()
        project.append(PaneTab(content: .file(file)))
        XCTAssertEqual(file.text, "local sentinel")
        file.text = "unsaved on remote"
        file.refreshDirtyState()
        XCTAssertTrue(file.isDirty)
        XCTAssertNil(file.readOnlyReason)

        // The only trigger is RemoteConnection.state's semantic event: no
        // manual rebindRemoteTabs() or extra publisher notification.
        connection.markDisconnected(reason: "controlled remote outage")
        try await wait { file.readOnlyReason != nil }
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, "unsaved on remote")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "local sentinel")

        connection.markConnected()
        try await wait { file.readOnlyReason == nil }
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, "unsaved on remote")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "local sentinel")
    }

    func testRemoteCreateFailureNeverFallsBackToLocalDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("remote-failure.txt")
        try Data("local sentinel".utf8).write(to: sentinel)

        let runner = FailingCreateRunnerFixture()
        let remote = SSHWorkspaceBackend(runner: runner)
        do {
            try await remote.createFile(path: sentinel.path)
            XCTFail("Expected remote creation failure")
        } catch let failure as RemoteCommandFailure {
            XCTAssertEqual(failure.status, 1)
            XCTAssertTrue(failure.message.contains("controlled creation failure"))
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("local sentinel".utf8))
        let commandCount = await runner.commands.count
        XCTAssertEqual(commandCount, 1)
    }

    func testFinderOpenReusesExistingFileTabButNotPinnedFileProjectForSiblings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.txt")
        let sibling = folder.appendingPathComponent("sibling.txt")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "sibling".write(to: sibling, atomically: true, encoding: .utf8)
        let manager = TerminalManager()
        defer { manager.windowClosed() }

        manager.addLocalItems([first])
        let pinned = try XCTUnwrap(manager.selectedProject)
        guard case .file(let originalFile) = try XCTUnwrap(pinned.selectedTab).content else {
            return XCTFail("Manual file should already be open")
        }
        XCTAssertEqual(pinned.pinnedFile, first.path)
        XCTAssertEqual(pinned.customName, "first.txt")
        XCTAssertTrue(manager.openExternalLocalItems([first]).isEmpty)
        XCTAssertTrue(manager.selectedProject === pinned)
        guard case .file(let reused) = try XCTUnwrap(pinned.selectedTab).content else {
            return XCTFail("Finder should return to original file")
        }
        XCTAssertTrue(reused === originalFile)

        XCTAssertTrue(manager.openExternalLocalItems([sibling]).isEmpty)
        XCTAssertTrue(manager.selectedProject === pinned)
        XCTAssertEqual(pinned.pinnedFile, first.path)
        XCTAssertEqual(pinned.customName, "first.txt")
        XCTAssertEqual(pinned.tabs.filter { $0.content.isFile }.count, 2)
        XCTAssertEqual(pinned.selectedTab?.content.title, "sibling.txt")
        XCTAssertEqual(manager.projects.count, 1)
    }

    func testFinderBatchOpensSameDirectoryIntoOneProjectAndKeepsLocalScope() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("a.swift")
        let second = folder.appendingPathComponent("b.swift")
        try "a".write(to: first, atomically: true, encoding: .utf8)
        try "b".write(to: second, atomically: true, encoding: .utf8)
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([folder])
        XCTAssertTrue(manager.openExternalLocalItems([first, second]).isEmpty)
        XCTAssertEqual(manager.projects.count, 1)
        let project = try XCTUnwrap(manager.selectedProject)
        XCTAssertEqual(project.customDirectory, folder.path)
        XCTAssertNil(project.pinnedFile)
        XCTAssertNil(project.sshHost)
        XCTAssertEqual(project.tabs.filter { $0.content.isFile }.count, 2)
        XCTAssertEqual(project.selectedTab?.content.title, "b.swift")
        guard case .file(let openedFile) = try XCTUnwrap(project.selectedTab).content else {
            return XCTFail("File should be opened in the native file model")
        }
        try await openedFile.waitForText()
        XCTAssertEqual(openedFile.text, "b")
        XCTAssertTrue(manager.openExternalLocalItems([first, first, second]).isEmpty)
        XCTAssertEqual(project.tabs.filter { $0.content.isFile }.count, 2)
        XCTAssertEqual(manager.projects.count, 1)
    }

    func testFinderOpenUsesDeepestLocalDirectoryAndRejectsInvalidBatchMembers() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inner = parent.appendingPathComponent("app")
        let similar = parent.appendingPathComponent("apple")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: similar, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let actual = inner.appendingPathComponent("测试 🚀.md")
        let other = similar.appendingPathComponent("other.md")
        try "hello".write(to: actual, atomically: true, encoding: .utf8)
        try "other".write(to: other, atomically: true, encoding: .utf8)
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([parent, inner])
        let selected = try XCTUnwrap(manager.selectedProject)
        let invalid = URL(string: "https://example.com/not-a-local-file")!
        let missing = inner.appendingPathComponent("absent.md")
        let rejects = manager.openExternalLocalItems([invalid, actual, missing])
        XCTAssertEqual(rejects, [invalid, missing])
        XCTAssertTrue(manager.selectedProject === selected)
        XCTAssertEqual(selected.tabs.filter { $0.content.isFile }.count, 1)
        XCTAssertEqual(selected.selectedTab?.content.title, actual.lastPathComponent)

        XCTAssertTrue(manager.openExternalLocalItems([other]).isEmpty)
        XCTAssertTrue(manager.selectedProject === selected,
                      "External paths cannot change which project was selected")
        XCTAssertEqual(manager.selectedProject?.customDirectory, inner.path)
        XCTAssertEqual(manager.projects.count, 2)
    }

    func testFinderSymlinkReusesOriginalNativeFileAndRejectsBrokenLink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let actual = folder.appendingPathComponent("actual.md")
        let link = folder.appendingPathComponent("alias.md")
        let broken = folder.appendingPathComponent("broken.md")
        try "keep content".write(to: actual, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        try FileManager.default.createSymbolicLink(
            at: broken, withDestinationURL: folder.appendingPathComponent("not-there")
        )
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([actual])
        let originalProject = try XCTUnwrap(manager.selectedProject)
        guard case .file(let file) = try XCTUnwrap(originalProject.selectedTab).content else {
            return XCTFail("Original file must be open")
        }
        XCTAssertTrue(manager.openExternalLocalItems([link]).isEmpty)
        XCTAssertTrue(manager.selectedProject === originalProject)
        guard case .file(let reused) = try XCTUnwrap(originalProject.selectedTab).content else {
            return XCTFail("Finder alias should return to existing buffer")
        }
        XCTAssertTrue(file === reused)
        XCTAssertEqual(originalProject.tabs.count, 1)
        XCTAssertEqual(manager.openExternalLocalItems([broken]), [broken])
        XCTAssertEqual(originalProject.tabs.count, 1)
        XCTAssertEqual(try String(contentsOf: actual, encoding: .utf8), "keep content")
    }

    func testFinderMixedFolderAndFileBatchUsesExplicitDirectoryWithoutStartingShell() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = parent.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = nested.appendingPathComponent("one.swift")
        let second = nested.appendingPathComponent("two.swift")
        try "one".write(to: first, atomically: true, encoding: .utf8)
        try "two".write(to: second, atomically: true, encoding: .utf8)
        let manager = TerminalManager()
        defer { manager.windowClosed() }

        let rejected = manager.openExternalLocalItems([first, nested, second, first])
        XCTAssertTrue(rejected.isEmpty)
        XCTAssertEqual(manager.projects.count, 1)
        let project = try XCTUnwrap(manager.selectedProject)
        XCTAssertEqual(project.customDirectory, nested.path)
        XCTAssertNil(project.pinnedFile)
        XCTAssertTrue(project.sessions.isEmpty, "Opening Finder documents must never start Shell")
        XCTAssertEqual(project.tabs.count, 2)
        XCTAssertEqual(project.selectedTab?.content.title, "one.swift")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "two")
    }

    func testFinderOpenNeverTreatsSSHFileTabWithSamePathAsLocal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("same.txt")
        try "mac".write(to: file, atomically: true, encoding: .utf8)
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        let remote = Project(fallbackName: "remote", workspaceConfiguration: .standard)
        remote.sshHost = "invalid-finder-remote"
        remote.customDirectory = folder.path
        remote.openFile(file.path)
        manager.projects.append(remote)
        manager.selectedProjectID = remote.id

        XCTAssertTrue(manager.openExternalLocalItems([file]).isEmpty)
        XCTAssertTrue(manager.selectedProject === remote)
        guard case .file(let openedFile) = try XCTUnwrap(remote.selectedTab).content,
              case .file(let remoteFile) = try XCTUnwrap(remote.tabs.first).content
        else { return XCTFail("Both targets must stay separate") }
        XCTAssertNil(openedFile.workspaceIdentity)
        XCTAssertNotNil(remoteFile.workspaceIdentity)
        XCTAssertEqual(remote.tabs.count, 2)
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mac")
    }

    func testFinderNewFileUsesSelectedProjectEvenOutsideItsRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let aRoot = root.appendingPathComponent("A")
        let bRoot = root.appendingPathComponent("B")
        let outside = root.appendingPathComponent("outside")
        for directory in [aRoot, bRoot, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let fromA = aRoot.appendingPathComponent("source.swift")
        let fromOutside = outside.appendingPathComponent("other.swift")
        let ownedByA = outside.appendingPathComponent("owned-by-a.swift")
        try "in A".write(to: fromA, atomically: true, encoding: .utf8)
        try "outside".write(to: fromOutside, atomically: true, encoding: .utf8)
        try "A buffer".write(to: ownedByA, atomically: true, encoding: .utf8)

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([aRoot, bRoot])
        let selected = try XCTUnwrap(manager.selectedProject)
        XCTAssertEqual(selected.customDirectory, bRoot.path)
        XCTAssertTrue(manager.openExternalLocalItems([fromA, fromOutside]).isEmpty)
        XCTAssertTrue(manager.selectedProject === selected)
        XCTAssertEqual(manager.projects.count, 2)
        XCTAssertEqual(selected.customDirectory, bRoot.path)
        XCTAssertNil(selected.pinnedFile)
        XCTAssertEqual(selected.tabs.filter { $0.content.isFile }.count, 2)
        guard case .file(let file) = try XCTUnwrap(selected.selectedTab).content else {
            return XCTFail("Expected the second file in the selected project")
        }
        try await file.waitForText()
        XCTAssertEqual(file.text, "outside")

        // A owns the already-open file regardless of its location, even while B is selected.
        let a = try XCTUnwrap(manager.projects.first { $0.customDirectory == aRoot.path })
        a.openFile(ownedByA.path)
        let original = try XCTUnwrap(a.selectedTab)
        manager.selectedProjectID = selected.id
        XCTAssertTrue(manager.openExternalLocalItems([ownedByA]).isEmpty)
        XCTAssertTrue(manager.selectedProject === a)
        XCTAssertTrue(a.selectedTab === original)
        XCTAssertEqual(selected.tabs.count, 2)
    }

    func testFinderFileDoesNotCreateProjectWithoutExplicitFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("untitled.swift")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let manager = TerminalManager()
        defer { manager.windowClosed() }

        XCTAssertEqual(manager.openExternalLocalItems([file]), [file])
        XCTAssertTrue(manager.projects.isEmpty)
        XCTAssertNil(manager.selectedProject)
    }

    func testFinderMacFileInSSHProjectUsesLocalBackend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("same.swift")
        try "mac disk".write(to: file, atomically: true, encoding: .utf8)
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        let remote = Project(fallbackName: "remote", workspaceConfiguration: .standard)
        remote.sshHost = "invalid-p4-fixture"
        remote.customDirectory = "/remote/source"
        remote.openFile(file.path)
        manager.projects.append(remote)
        manager.selectedProjectID = remote.id
        XCTAssertTrue(manager.openExternalLocalItems([file]).isEmpty)
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertTrue(manager.selectedProject === remote)
        let macTabs = remote.tabs.compactMap { tab -> FileTab? in
            guard case .file(let file) = tab.content, file.workspaceIdentity == nil else { return nil }
            return file
        }
        let local = try XCTUnwrap(macTabs.first)
        try await local.waitForText()
        XCTAssertEqual(local.text, "mac disk")
        XCTAssertEqual(macTabs.count, 1)
    }

    func testTerminalManagerCreatesFileInSelectedLocalProject() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = TerminalManager()
        manager.addLocalItems([directory])
        let project = try XCTUnwrap(manager.selectedProject)
        await manager.newFile()
        XCTAssertEqual(project.fileTree.draft?.parentDir, directory.path)
        let created = await project.fileTree.commitDraft(name: "new.txt")
        XCTAssertEqual(created, directory.appendingPathComponent("new.txt").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: created!)), Data())
    }
}
