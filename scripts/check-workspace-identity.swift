import AppKit
import Foundation
@testable import kero

actor IdentityWorkspace: WorkspaceBackend {
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
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        WorkspaceRunResult(status: 0, stdout: Data(), stderr: Data())
    }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot { WorkspaceProcessSnapshot(descendants: [], namesByPid: [:]) }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { [] }
    func kill(pid: pid_t, force: Bool) async throws {}
}

@main
enum WorkspaceIdentityCheck {
    @MainActor
    static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        preconditionFailure("App model did not settle")
    }

    @MainActor
    static func connection(port: Int = 22) -> RemoteConnection {
        let connection = RemoteConnection(user: "fixture", host: "invalid", port: port,
            controlSocket: URL(fileURLWithPath: "/tmp/kero-no-such-identity-socket"), sshPID: 0)
        connection.workingDirectory = "/fixture"
        connection.markConnected()
        return connection
    }

    @MainActor
    static func checkRemote(user: String, host: String, port: Int, socket: String) async throws {
        let directory = "/tmp/kero-identity-" + UUID().uuidString
        let path = directory + "/file.txt"
        let local = LocalWorkspaceBackend.shared
        try await local.createDirectory(path: directory)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try await local.write(path: path, data: Data("local sentinel\n".utf8))
        let first = RemoteConnection(user: user, host: host, port: port,
            controlSocket: URL(fileURLWithPath: socket), sshPID: 0)
        first.workingDirectory = directory
        let connected = await first.check()
        precondition(connected)
        first.markConnected()
        let backend = first.workspaceBackend
        let existing = try await backend.stat(path: directory)
        precondition(existing == nil)
        try await backend.createDirectory(path: directory)
        do {
            try await backend.write(path: path, data: Data("remote baseline\n".utf8))
            let project = Project(fallbackName: "remote identity", workspaceConfiguration: .standard)
            defer { project.terminateAll() }
            let session = project.newSession()
            session.location = .remote(first)
            project.openFile(path)
            let file = project.selectedTab!.allContents.compactMap { if case .file(let file) = $0 { return file }; return nil }.first!
            project.openDiff(repoRoot: directory, path: "file.txt", staged: false, untracked: true, origPath: nil)
            let diff = project.selectedTab!.diffs.first!
            try await wait { if case .text = file.content { return !diff.isLoading }; return false }
            precondition(file.text == "remote baseline\n" && file.workspaceIdentity == first.workspaceIdentity)
            file.text = "remote file saved\n"
            file.refreshDirtyState()
            diff.updateEditedContent(fileID: "file.txt", contents: "remote diff saved\n")
            first.markDisconnected(reason: "controlled regression outage")
            project.rebindRemoteTabs()
            await file.save()
            await diff.save()
            precondition(file.isDirty && file.saveError != nil && diff.isDirty && diff.saveError != nil)
            let blockedBytes = try await backend.read(path: path, maxBytes: 1024)
            precondition(blockedBytes == Data("remote baseline\n".utf8))
            let replacement = RemoteConnection(user: user, host: host, port: port,
                controlSocket: URL(fileURLWithPath: socket), sshPID: 0)
            replacement.workingDirectory = directory
            replacement.markConnected()
            session.location = .remote(replacement)
            project.rebindRemoteTabs()
            await file.save()
            precondition(!file.isDirty && file.saveError == nil)
            let fileBytes = try await replacement.workspaceBackend.read(path: path, maxBytes: 1024)
            precondition(fileBytes == Data("remote file saved\n".utf8))
            await diff.save()
            precondition(!diff.isDirty && diff.saveError == nil)
            let diffBytes = try await replacement.workspaceBackend.read(path: path, maxBytes: 1024)
            precondition(diffBytes == Data("remote diff saved\n".utf8))
            let localBytes = try await local.read(path: path, maxBytes: 1024)
            precondition(localBytes == Data("local sentinel\n".utf8))
        } catch {
            try await backend.delete(paths: [directory])
            throw error
        }
        try await backend.delete(paths: [directory])
        print("PASS: real SSH File/Diff reads, outage write refusal, replacement connection saves verified by remote bytes; identical local path untouched; owned remote fixture removed")
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
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
        let localFile = project.selectedTab!.allContents.compactMap { if case .file(let file) = $0 { return file }; return nil }.first!
        project.openDiff(repoRoot: directory.path, path: "file.txt", staged: false, untracked: true, origPath: nil)
        let localDiff = project.selectedTab!.diffs.first!
        try await wait { !localDiff.isLoading }
        precondition(localFile.workspaceIdentity == nil && localDiff.workspaceIdentity == nil)
        project.openFile(path)
        precondition(project.tabs.count == 3)
        localFile.text = "local save\n"
        localFile.refreshDirtyState()
        await localFile.save()
        precondition(!localFile.isDirty && localFile.saveError == nil)
        localDiff.updateEditedContent(fileID: "file.txt", contents: "local diff save\n")
        await localDiff.save()
        let localBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        precondition(localBytes == Data("local diff save\n".utf8))
        let remote = IdentityWorkspace()
        let remoteFile = FileTab(path: path, backend: remote, workspaceIdentity: first.workspaceIdentity)
        let remoteDiff = DiffTab(repoRoot: directory.path, path: "file.txt", staged: false,
            untracked: true, origPath: nil, backend: remote, workspaceIdentity: first.workspaceIdentity)
        try await wait { if case .text = remoteFile.content { return !remoteDiff.isLoading }; return false }
        project.append(PaneTab(content: .file(remoteFile)))
        project.append(PaneTab(content: .diff(remoteDiff)))
        project.customDirectory = nil
        project.openFile(path)
        precondition(project.tabs.count == 5)
        precondition(project.focusedContent?.id == remoteFile.id)
        session.location = .remote(connection(port: 2222))
        project.openFile(path)
        precondition(project.tabs.count == 6 && project.focusedContent?.id != remoteFile.id)
        remoteFile.text = "remote unsaved\n"
        remoteFile.refreshDirtyState()
        remoteDiff.updateEditedContent(fileID: "file.txt", contents: "remote diff unsaved\n")
        first.markDisconnected(reason: "regression fixture")
        session.location = .remote(first)
        project.rebindRemoteTabs()
        await remoteFile.save()
        await remoteDiff.save()
        precondition(remoteFile.readOnlyReason != nil && remoteFile.isDirty && remoteFile.saveError != nil)
        precondition(remoteDiff.readOnlyReason != nil && remoteDiff.isDirty && remoteDiff.saveError != nil)
        let writeCount = await remote.writes
        precondition(writeCount == 0)
        session.location = .remote(connection())
        project.rebindRemoteTabs()
        precondition(remoteFile.readOnlyReason == nil && remoteDiff.readOnlyReason == nil)
        await remoteFile.save()
        await remoteDiff.save()
        precondition(remoteFile.saveError != nil && remoteFile.text == "remote unsaved\n" && remoteFile.isDirty)
        precondition(remoteDiff.saveError != nil && remoteDiff.isDirty)
        let unchanged = try Data(contentsOf: URL(fileURLWithPath: path))
        precondition(unchanged == localBytes)
        let finalWriteCount = await remote.writes
        precondition(finalWriteCount == 0)
        print("PASS: actual App Project/File/Diff: pinned local+SSH save, same-path machine/port isolation, disconnected write refusal, rebind to replacement channel, failed remote save preserves dirty buffers and never writes local")
        let arguments = CommandLine.arguments
        if arguments.count == 5, let port = Int(arguments[3]) {
            try await checkRemote(user: arguments[1], host: arguments[2], port: port, socket: arguments[4])
        } else {
            precondition(arguments.count == 1, "Expected optional user host port control-socket arguments")
        }
    }
}
