import Foundation
import XCTest
@testable import kero

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
            controlSocket: URL(fileURLWithPath: "/tmp/kero-no-such-identity-socket"), sshPID: 0
        )
        connection.workingDirectory = "/fixture"
        connection.markConnected()
        return connection
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

        let remoteBackend = IdentityWorkspaceFixture()
        let remoteFile = FileTab(path: path, backend: remoteBackend, workspaceIdentity: first.workspaceIdentity)
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
            controlSocket: URL(fileURLWithPath: "/tmp/kero-observation-rebind-no-socket"),
            sshPID: 0
        )
        connection.workingDirectory = directory.path
        connection.markConnected()
        XCTAssertTrue(session.beginRemoteConnection(connection))

        let file = FileTab(
            path: path.path, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: connection.workspaceIdentity
        )
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
