import Foundation
import Darwin
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
    func copy(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func rename(from: String, to: String) async throws {}
    func delete(paths: [String]) async throws {}
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult { .init(status: 0, stdout: Data(), stderr: Data()) }
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
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

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

    func testProjectNameAndRootStayFixedAcrossTerminalChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey 固定项目 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let initial = try XCTUnwrap(project.panelContext)
        XCTAssertEqual(project.name, root.lastPathComponent)
        XCTAssertEqual(initial.cwd, root.path)
        XCTAssertNil(initial.identity.workspace)

        let terminal = project.newSession(directory: "/tmp/a-different-directory")
        XCTAssertEqual(project.name, root.lastPathComponent,
                       "Project names cannot follow a terminal title or working directory")
        XCTAssertEqual(project.panelContext?.identity, initial.identity)
        project.close(try XCTUnwrap(project.tabs.first { $0.content.id == terminal.id }))
        XCTAssertTrue(project.tabs.isEmpty)
        XCTAssertEqual(project.panelContext?.identity, initial.identity,
                       "Closing the final terminal cannot detach a fixed Files or Git root")

        let ssh = Project(fallbackName: "SSH", workspaceConfiguration: .standard)
        ssh.sshHost = "fixture-remote"
        ssh.customDirectory = "/d/projects"
        ssh.pinnedFile = "/d/projects/source.swift"
        XCTAssertEqual(ssh.name, "source.swift",
                       "An explicitly added SSH file keeps its file-based project title")

        let rootless = Project(fallbackName: "Unsupported", workspaceConfiguration: .standard)
        rootless.newSession(directory: "/tmp/old-terminal-scope")
        XCTAssertNil(rootless.panelContext,
                     "A terminal cannot implicitly create or redirect a project root")
    }

    func testReorderAndCloseBackgroundProjectsPreserveSelectedProjectIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-Projects-" + UUID().uuidString)
        let folders = (0..<3).map { root.appendingPathComponent("project-\($0)") }
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders(folders)
        let first = try XCTUnwrap(manager.projects.first { $0.customDirectory == folders[0].path })
        let background = try XCTUnwrap(manager.projects.first { $0.customDirectory == folders[1].path })
        let last = try XCTUnwrap(manager.projects.first { $0.customDirectory == folders[2].path })
        manager.selectedProjectID = first.id

        manager.moveProject(last.id, to: first.id)
        XCTAssertEqual(manager.projects.map(\.id), [last.id, first.id, background.id])
        XCTAssertEqual(manager.selectedProjectID, first.id)
        manager.close(background)
        XCTAssertEqual(manager.projects.map(\.id), [last.id, first.id])
        XCTAssertEqual(manager.selectedProjectID, first.id,
                       "Closing an inactive project must not switch the active project")
        XCTAssertEqual(manager.selectedProject?.customDirectory, folders[0].path)
        manager.close(first)
        XCTAssertEqual(manager.selectedProjectID, last.id)
        XCTAssertEqual(manager.selectedProject?.customDirectory, folders[2].path)
        manager.close(last)
        XCTAssertTrue(manager.projects.isEmpty)
        XCTAssertNil(manager.selectedProjectID)
    }

    func testProjectCommandIdentitySurvivesReorderAndRefusesRemovedTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-Command-Projects-" + UUID().uuidString)
        let folders = (0..<3).map { root.appendingPathComponent("workspace-\($0)") }
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders(folders)
        let first = try XCTUnwrap(manager.projects.first { $0.customDirectory == folders[0].path })
        let second = try XCTUnwrap(manager.projects.first { $0.customDirectory == folders[1].path })
        let third = try XCTUnwrap(manager.projects.first { $0.customDirectory == folders[2].path })
        manager.selectedProjectID = first.id
        manager.moveProject(third.id, to: first.id)
        manager.selectProject(id: third.id)
        XCTAssertEqual(manager.selectedProjectID, third.id,
                       "A command must target the original project, not the previous row index")
        manager.selectProject(id: first.id)
        manager.close(second)
        XCTAssertFalse(manager.projects.contains { $0 === second })
        manager.selectProject(id: second.id)
        XCTAssertEqual(manager.selectedProjectID, first.id,
                       "An expired command cannot target a new occupant of its former index")
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
        XCTAssertNil(project.connectedWorkspace(for: first.workspaceIdentity),
                     "An SSH session in a local project cannot turn it into a remote file workspace")

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

    func testFinderBatchOpensSameDirectoryIntoOneProjectAndKeepsLocalScope() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("a.swift")
        let second = folder.appendingPathComponent("b.swift")
        try "a".write(to: first, atomically: true, encoding: .utf8)
        try "b".write(to: second, atomically: true, encoding: .utf8)
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([folder])
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

    func testFinderOpenKeepsSelectedProjectAcrossSiblingRootsAndRejectsInvalidBatchMembers() throws {
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
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([parent, inner])
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

    func testFinderUnreadableFileRejectsNewTabButOpensValidNeighbor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let denied = root.appendingPathComponent("denied.txt")
        let valid = root.appendingPathComponent("valid.txt")
        try "unreadable".write(to: denied, atomically: true, encoding: .utf8)
        try "valid text".write(to: valid, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path) }
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: denied.path))
        if (try? Data(contentsOf: denied)) != nil {
            throw XCTSkip("Test host bypasses source-read protection")
        }

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([projectRoot])
        let project = try XCTUnwrap(manager.selectedProject)
        XCTAssertEqual(manager.openExternalLocalItems([denied, valid]), [denied])
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(project.tabs.count, 1, "Unreadable Finder files must not create empty editor tabs")
        guard case .file(let file) = try XCTUnwrap(project.selectedTab).content else {
            return XCTFail("The valid sibling should open as a file")
        }
        XCTAssertEqual(file.path, valid.path)
        try await file.waitForText()
        XCTAssertEqual(file.text, "valid text")
        XCTAssertEqual(try String(contentsOf: valid, encoding: .utf8), "valid text")

        // 已打开的文件仍复用原缓冲，不能因权限变化丢失编辑状态。
        let originalTab = project.selectedTab
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: valid.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: valid.path) }
        XCTAssertTrue(manager.openExternalLocalItems([valid]).isEmpty)
        XCTAssertTrue(project.selectedTab === originalTab)
        XCTAssertEqual(project.tabs.count, 1)
    }

    func testFinderReadableButReadOnlyFileCanOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("read-only.swift")
        try "let readOnly = true".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path) }
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: fileURL.path))
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([projectRoot])
        XCTAssertTrue(manager.openExternalLocalItems([fileURL]).isEmpty)
        let project = try XCTUnwrap(manager.selectedProject)
        guard case .file(let file) = try XCTUnwrap(project.selectedTab).content else {
            return XCTFail("A readable file must open even when saving requires permission")
        }
        try await file.waitForText()
        XCTAssertEqual(file.text, "let readOnly = true")
    }

    func testFinderUnreadableFolderCannotBecomeProjectOrMaskValidFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let denied = root.appendingPathComponent("denied-folder")
        let valid = root.appendingPathComponent("valid-folder")
        for folder in [denied, valid] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: denied.path))
        if (try? FileManager.default.contentsOfDirectory(atPath: denied.path)) != nil {
            throw XCTSkip("Test host bypasses directory-read protection")
        }

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([denied])
        XCTAssertTrue(manager.projects.isEmpty, "Unreadable folders must not be added as projects")
        XCTAssertEqual(manager.openExternalLocalItems([denied, valid]), [denied])
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(manager.selectedProject?.customDirectory, valid.path)
    }

    func testFinderNamedPipeDoesNotCreateEditorThatCouldBlockOnRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("stream.fifo")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fifo.path))
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([projectRoot])
        XCTAssertEqual(manager.openExternalLocalItems([fifo]), [fifo])
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertTrue(manager.selectedProject?.tabs.isEmpty == true)
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
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([folder])
        manager.openFile(actual.path)
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
        let manager = self.workspaceApplication.makeWindow()
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
        let manager = self.workspaceApplication.makeWindow()
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

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([aRoot, bRoot])
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

    func testExplicitGroupNeverFallsThroughToAnotherSelectedProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let aRoot = root.appendingPathComponent("A")
        let bRoot = root.appendingPathComponent("B")
        for directory in [aRoot, bRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("delayed.swift")
        try "should not open in B".write(to: file, atomically: true, encoding: .utf8)
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([aRoot])
        let a = try XCTUnwrap(manager.selectedProject)
        let targetGroup = try XCTUnwrap(a.dock.root.groups.first)
        manager.addLocalFolders([bRoot])
        let b = try XCTUnwrap(manager.selectedProject)

        // The group was selected when a Finder provider began loading, but
        // the user switched to B before its local file URL was delivered.
        let destination = (projectID: a.id, groupID: targetGroup.id)
        XCTAssertEqual(manager.openExternalLocalItems([file], destination: destination), [file])
        XCTAssertTrue(manager.selectedProject === b)
        XCTAssertTrue(a.tabs.isEmpty)
        XCTAssertTrue(b.tabs.isEmpty)
        manager.selectedProjectID = a.id
        let invalidGroup = (projectID: a.id, groupID: UUID())
        XCTAssertEqual(manager.openExternalLocalItems([file], destination: invalidGroup), [file])
        XCTAssertTrue(a.tabs.isEmpty)
    }

    func testFinderReopensFileOwnedByProjectAAfterSwitchingToB() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let aRoot = root.appendingPathComponent("A")
        let bRoot = root.appendingPathComponent("B")
        for directory in [aRoot, bRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = aRoot.appendingPathComponent("A-owned.swift")
        try "owned A".write(to: file, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([aRoot])
        let a = try XCTUnwrap(manager.selectedProject)
        a.openFile(file.path)
        let original = try XCTUnwrap(a.selectedTab)
        manager.addLocalFolders([bRoot])
        let b = try XCTUnwrap(manager.selectedProject)
        XCTAssertTrue(manager.openExternalLocalItems([file]).isEmpty)
        XCTAssertTrue(manager.selectedProject === a)
        XCTAssertTrue(a.selectedTab === original)
        XCTAssertTrue(b.tabs.isEmpty)
        XCTAssertEqual(manager.projects.count, 2)
    }

    func testFinderLargeRepeatedBatchDoesNotCreateProjectOrDuplicateTabs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("project")
        let externalRoot = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = (0..<52).map { index in
            externalRoot.appendingPathComponent("测试 文件 \(index) – a b.swift")
        }
        for url in urls {
            try "same content".write(to: url, atomically: true, encoding: .utf8)
        }
        let alias = externalRoot.appendingPathComponent("symlink.swift")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: urls[5])
        let missing = externalRoot.appendingPathComponent("missing.swift")
        let input = urls + Array(urls.reversed().prefix(9)) + [alias, missing]
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([projectRoot])
        let project = try XCTUnwrap(manager.selectedProject)
        XCTAssertEqual(manager.openExternalLocalItems(input), [missing])
        XCTAssertTrue(manager.selectedProject === project)
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(project.tabs.filter { $0.content.isFile }.count, urls.count)
        XCTAssertEqual(project.customDirectory, projectRoot.path)
        XCTAssertNil(project.pinnedFile)
    }

    func testFinderFileDoesNotCreateProjectWithoutExplicitFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("untitled.swift")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let manager = self.workspaceApplication.makeWindow()
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
        let manager = self.workspaceApplication.makeWindow()
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
        local.text = "Mac edit from an SSH project 🪨"
        local.refreshDirtyState()
        XCTAssertTrue(local.isDirty)
        await local.save()
        XCTAssertFalse(local.isDirty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Mac edit from an SSH project 🪨")
    }

    func testExplicitLocalAddOnlyCreatesFolderProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("do-not-pin.swift")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }

        manager.addLocalFolders([file])
        XCTAssertTrue(manager.projects.isEmpty, "Mac files are not project entries")
        manager.addLocalFolders([root])
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(manager.selectedProject?.customDirectory, root.path)
        XCTAssertNil(manager.selectedProject?.pinnedFile)
        XCTAssertTrue(manager.selectedProject?.tabs.isEmpty == true)
        manager.addLocalFolders([root])
        XCTAssertEqual(manager.projects.count, 1)
    }

    func testWorkspaceWindowModelCreatesFileInSelectedLocalProject() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = self.workspaceApplication.makeWindow()
        manager.addLocalFolders([directory])
        let project = try XCTUnwrap(manager.selectedProject)
        await manager.newFile()
        XCTAssertEqual(project.fileTree.draft?.parentDir, directory.path)
        let created = await project.fileTree.commitDraft(name: "new.txt")
        XCTAssertEqual(created, directory.appendingPathComponent("new.txt").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: created!)), Data())
    }
}
