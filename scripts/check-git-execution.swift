import Darwin
import Foundation

actor CommandWorkspace: WorkspaceBackend {
    var result = WorkspaceRunResult(status: 7, stdout: Data([0, 255, 10]), stderr: Data("remote error".utf8))
    var failure: WorkspaceError?
    private(set) var arguments: [String] = []
    private(set) var directory: String?
    private(set) var environment: [String: String]?
    private(set) var deadline: TimeInterval?
    func configure(failure: WorkspaceError?) { self.failure = failure }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        precondition(stdin == nil)
        arguments = argv
        directory = cwd
        environment = env
        deadline = timeout
        if let failure { throw failure }
        return result
    }
    func list(directory: String) async throws -> [WorkspaceEntry] { [] }
    func stat(path: String) async throws -> WorkspaceStat? { nil }
    func readSymlinkDestination(path: String) async throws -> String? { nil }
    func read(path: String, maxBytes: Int) async throws -> Data { Data() }
    func write(path: String, data: Data) async throws {}
    func createFile(path: String) async throws {}
    func createDirectory(path: String) async throws {}
    func rename(from: String, to: String) async throws {}
    func delete(paths: [String]) async throws {}
    func gitRoot(containing path: String) async throws -> String? { nil }
    func isLinkedWorktree(_ root: String) async throws -> Bool { false }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot { WorkspaceProcessSnapshot(descendants: [], namesByPid: [:]) }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { [] }
    func kill(pid: pid_t, force: Bool) async throws {}
}

@main
enum GitExecutionCheck {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.path
        let notRepository = GitCommandExecution.run(["rev-parse", "--show-toplevel"], in: root)
        precondition(notRepository.status == 128 && notRepository.stderr.contains("not a git repository"))
        let missing = GitCommandExecution.run(["status"], in: directory.appendingPathComponent("missing").path)
        precondition(missing.status == -1 && !missing.stderr.isEmpty)
        for arguments in [["init", "-q"], ["config", "user.name", "Execution Check"], ["config", "user.email", "check@invalid"], ["config", "commit.gpgsign", "false"], ["config", "core.hooksPath", "/dev/null"]] {
            precondition(GitCommandExecution.run(arguments, in: root).status == 0)
        }
        let name = "space 'quote'; $(touch SHOULD_NOT_EXIST).bin"
        let binary = Data([0, 255, 1, 10])
        try binary.write(to: directory.appendingPathComponent(name))
        let large = Data(repeating: 65, count: 256 * 1024)
        try large.write(to: directory.appendingPathComponent("large.txt"))
        try Data("text\n".utf8).write(to: directory.appendingPathComponent("text.txt"))
        precondition(GitCommandExecution.run(["--literal-pathspecs", "add", "--", name, "large.txt", "text.txt"], in: root).status == 0)
        precondition(GitCommandExecution.run(["commit", "-qm", "fixture"], in: root).status == 0)
        let bytes = GitCommandExecution.runData(["cat-file", "blob", "HEAD:" + name], in: root)
        precondition(bytes.status == 0 && bytes.stdout == binary)
        let invalidText = GitCommandExecution.run(["cat-file", "blob", "HEAD:" + name], in: root)
        precondition(invalidText.status == 0 && invalidText.stdout.isEmpty)
        let text = GitCommandExecution.run(["cat-file", "blob", "HEAD:text.txt"], in: root)
        precondition(text.stdout == "text\n")
        for limit in [0, 5, 6, large.count, large.count + 1] {
            let bounded = GitCommandExecution.runData(["cat-file", "blob", "HEAD:large.txt"], in: root, stdoutLimit: limit)
            precondition(bounded.status == 0 && bounded.stdout == large.prefix(limit))
        }
        let exact = GitCommandExecution.runData(["cat-file", "blob", "HEAD:text.txt"], in: root, stdoutLimit: 5)
        precondition(exact.stdout == Data("text\n".utf8))
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("SHOULD_NOT_EXIST").path))
        let channels = GitCommandExecution.run(["-c", "alias.channels=!printf out; printf err >&2; exit 7", "channels"], in: root)
        precondition(channels.status == 7 && channels.stdout == "out" && channels.stderr == "err")
        let environment = GitCommandExecution.run(["-c", "alias.environment=!printf '%s:%s:%s' \"$GIT_OPTIONAL_LOCKS\" \"$GIT_TERMINAL_PROMPT\" \"$LC_ALL\"", "environment"], in: root)
        precondition(environment.status == 0 && environment.stdout == "0:0:C")
        let started = Date()
        let timeout = GitCommandExecution.run(["-c", "alias.pause=!printf partial; printf warning >&2; exec /bin/sleep 5", "pause"], in: root, timeout: 0.1)
        print("timeout elapsed: \(Date().timeIntervalSince(started))")
        precondition(timeout.status == -2 && timeout.stdout == "partial" && timeout.stderr.contains("warning") && timeout.stderr.contains("Git did not respond in time."))
        precondition(Date().timeIntervalSince(started) < 3)
        let stubbornStarted = Date()
        let stubborn = GitCommandExecution.run(["-c", "alias.stubborn=!trap '' TERM; printf stubborn; exec /bin/sleep 5", "stubborn"], in: root, timeout: 0.1)
        print("stubborn helper elapsed: \(Date().timeIntervalSince(stubbornStarted))")
        precondition(stubborn.status == -2 && stubborn.stdout == "stubborn")
        precondition(Date().timeIntervalSince(stubbornStarted) < 3)
        let orphanStarted = Date()
        let orphan = GitCommandExecution.run(["-c", "alias.orphan=! (trap '' TERM; sleep 5) & printf orphan", "orphan"], in: root, timeout: 0.1)
        print("exited Git with open helper pipes elapsed: \(Date().timeIntervalSince(orphanStarted))")
        precondition(orphan.status == -2 && orphan.stdout == "orphan")
        precondition(Date().timeIntervalSince(orphanStarted) < 3)
        let backend = CommandWorkspace()
        let remote = await GitCommandExecution.runData(["status", "-z"], in: root, timeout: 3, backend: backend)
        precondition(remote.status == 7 && remote.stdout == Data([0, 255, 10]) && remote.stderr == "remote error")
        let captured = await (backend.arguments, backend.directory, backend.environment, backend.deadline)
        precondition(captured.0 == ["git", "status", "-z"] && captured.1 == root && captured.3 == 3)
        precondition(captured.2 == ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"])
        let boundedRemote = await GitCommandExecution.runData(["status"], in: root, stdoutLimit: 1, backend: backend)
        precondition(boundedRemote.stdout == Data([0]))
        let remoteText = await GitCommandExecution.run(["status"], in: root, backend: backend)
        precondition(remoteText.stdout.isEmpty && remoteText.stderr == "remote error")
        await backend.configure(failure: .timedOut)
        let remoteTimeout = await GitCommandExecution.runData(["status"], in: root, backend: backend)
        precondition(remoteTimeout.status == -2 && !remoteTimeout.stderr.isEmpty)
        await backend.configure(failure: .notFound)
        let remoteMissing = await GitCommandExecution.run(["status"], in: root, backend: backend)
        precondition(remoteMissing.status == -1 && !remoteMissing.stderr.isEmpty)
        let localAsync = await GitCommandExecution.run(["cat-file", "blob", "HEAD:text.txt"], in: root, backend: LocalWorkspaceBackend.shared)
        precondition(localAsync.stdout == text.stdout)
        print("PASS: real Git bytes/text/literal paths, NUL/invalid UTF-8, bounded drain, stdout/stderr/environment, launch failure/non-repo, timeout partial output; remote mapping and local async entry")
    }
}
