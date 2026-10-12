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
    static func checkShellFixture(root: String) throws {
        let directory = URL(fileURLWithPath: root)
        func git(_ arguments: [String], in path: String? = nil) -> String {
            let result = GitCommandExecution.run(arguments, in: path ?? root, timeout: 10)
            precondition(result.status == 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for arguments in [["init", "-q", "-b", "fixture"], ["config", "user.name", "Shell Check"], ["config", "user.email", "check@invalid"], ["config", "commit.gpgsign", "false"], ["config", "core.hooksPath", ".git/hooks"]] {
            _ = git(arguments)
        }
        precondition(git(["-c", "alias.environment=!printf '%s' \"$KERO_CHECK_EXPORTED\"", "environment"]) == "line one\nline=two")
        precondition(git(["-c", "alias.proxy=!printf '%s' \"$https_proxy\"", "proxy"]) == "http://127.0.0.1:9")
        let credential = GitCommandExecution.run(["-c", "alias.credentialcheck=!printf 'protocol=https\\nhost=fixture.invalid\\n\\n' | git -c credential.helper= -c credential.helper=kero-check credential fill", "credentialcheck"], in: root)
        precondition(credential.status != 0 && credential.stderr.contains("terminal prompts disabled"))
        precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("credential-used").path))
        try Data("fixture\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        _ = git(["add", "tracked.txt"])
        _ = git(["commit", "-qm", "fixture"])
        let hook = directory.appendingPathComponent(".git/hooks/pre-push")
        try Data("#!/bin/sh\n[ \"$KERO_CHECK_EXPORTED\" = 'line one\nline=two' ] || exit 1\nkero-hook-helper\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let receiver = directory.appendingPathComponent("receiver.git")
        _ = git(["init", "--bare", "-q", receiver.path])
        _ = git(["remote", "add", "origin", receiver.path])
        _ = git(["push", "-u", "origin", "HEAD:refs/heads/fixture"])
        precondition(git(["rev-parse", "HEAD"]) == git(["rev-parse", "refs/heads/fixture"], in: receiver.path))
        precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("hook-used").path))
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("tools/git-lfs").path) {
            try FileManager.default.removeItem(at: hook)
            _ = git(["lfs", "install", "--local"])
            _ = git(["lfs", "track", "*.dat"])
            let payload = Data(repeating: 87, count: 8192)
            try payload.write(to: directory.appendingPathComponent("payload.dat"))
            _ = git(["add", ".gitattributes", "payload.dat"])
            _ = git(["commit", "-qm", "LFS fixture"])
            let pointer = git(["show", "HEAD:payload.dat"])
            precondition(pointer.hasPrefix("version https://git-lfs.github.com/spec/v1"))
            let oid = pointer.components(separatedBy: "\n").first { $0.hasPrefix("oid sha256:") }!.dropFirst("oid sha256:".count)
            _ = git(["push"])
            precondition(git(["rev-parse", "HEAD"]) == git(["rev-parse", "refs/heads/fixture"], in: receiver.path))
            let object = receiver.appendingPathComponent("lfs/objects/\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))/\(oid)")
            let received = try Data(contentsOf: object)
            precondition(received == payload)
            print("PASS: real Git LFS push delivered pointer and payload to local receiver")
        } else {
            print("SKIP: real LFS transfer (git-lfs is not installed)")
        }
        let startups = try String(contentsOf: directory.appendingPathComponent("shell-starts"), encoding: .utf8)
        precondition(startups == "startup\n")
        precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("git-used").path))
        print("PASS: GUI-like PATH, login/interactive startup, noise isolation, cached environment, proxy exports, PATH Git/credential/hook tools and received push commit")
    }

    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--shell-fixture" {
            try checkShellFixture(root: CommandLine.arguments[2])
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--shell-failure" {
            let root = CommandLine.arguments[2]
            let result = GitCommandExecution.run(["-c", "alias.mutation=!touch SHOULD_NOT_EXIST", "mutation"], in: root)
            precondition(result.status != 0 && result.stderr.contains("Could not load the login shell environment"))
            precondition(!FileManager.default.fileExists(atPath: root + "/SHOULD_NOT_EXIST"))
            print("PASS: failed startup blocks Git mutations instead of falling back")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.path
        let fixture = directory.appendingPathComponent("shell fixture 'quoted'")
        let tools = fixture.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        var shellEnvironment = ProcessInfo.processInfo.environment
        shellEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        shellEnvironment["ZDOTDIR"] = fixture.path
        shellEnvironment["KERO_CHECK_ROOT"] = fixture.path
        shellEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        shellEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
        try Data("export PATH=\"$KERO_CHECK_ROOT/tools:/usr/bin:/bin:/usr/sbin:/sbin\"\nprintf startup >> \"$KERO_CHECK_ROOT/shell-starts\"\nprintf '\\n' >> \"$KERO_CHECK_ROOT/shell-starts\"\nprintf 'startup noise\\n'\n".utf8).write(to: fixture.appendingPathComponent(".zprofile"))
        try Data("export KERO_CHECK_EXPORTED='line one\nline=two'\nexport https_proxy=http://127.0.0.1:9\nprintf 'interactive noise\\n'\n".utf8).write(to: fixture.appendingPathComponent(".zshrc"))
        for (name, source) in [
            "git": "#!/bin/sh\n: > \"$KERO_CHECK_ROOT/git-used\"\nexec /usr/bin/git \"$@\"\n",
            "git-credential-kero-check": "#!/bin/sh\n: > \"$KERO_CHECK_ROOT/credential-used\"\ncat >/dev/null\n",
            "kero-hook-helper": "#!/bin/sh\n: > \"$KERO_CHECK_ROOT/hook-used\"\n",
        ] {
            let file = tools.appendingPathComponent(name)
            try Data(source.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let userEnvironment = GitCommandExecution.loadLoginEnvironment()
        if let lfs = userEnvironment.values["PATH"]?.split(separator: ":").map({ String($0) + "/git-lfs" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            try FileManager.default.createSymbolicLink(atPath: tools.appendingPathComponent("git-lfs").path, withDestinationPath: lfs)
        }
        let child = try await LocalWorkspaceBackend.shared.run(
            argv: [URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path, "--shell-fixture", fixture.path],
            cwd: root, env: shellEnvironment, stdin: nil, timeout: 30
        )
        print(String(decoding: child.stdout, as: UTF8.self))
        precondition(child.status == 0, String(decoding: child.stderr, as: UTF8.self))
        try Data("exit 9\n".utf8).write(to: fixture.appendingPathComponent(".zshrc"))
        let blocked = try await LocalWorkspaceBackend.shared.run(
            argv: [URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path, "--shell-failure", fixture.path],
            cwd: root, env: shellEnvironment, stdin: nil, timeout: 10
        )
        print(String(decoding: blocked.stdout, as: UTF8.self))
        precondition(blocked.status == 0, String(decoding: blocked.stderr, as: UTF8.self))
        try Data("export PATH=''\n".utf8).write(to: fixture.appendingPathComponent(".zshrc"))
        let noPath = GitCommandExecution.loadLoginEnvironment(shell: "/bin/zsh", environment: shellEnvironment)
        precondition(noPath.status == -1 && noPath.values.isEmpty)
        try Data("/bin/sleep 5\n".utf8).write(to: fixture.appendingPathComponent(".zshrc"))
        let startupStarted = Date()
        let startupTimeout = GitCommandExecution.loadLoginEnvironment(shell: "/bin/zsh", environment: shellEnvironment, timeout: 0.1)
        precondition(startupTimeout.status == -2 && startupTimeout.values.isEmpty && Date().timeIntervalSince(startupStarted) < 3)
        let shellFailure = GitCommandExecution.loadLoginEnvironment(shell: "/usr/bin/false")
        precondition(shellFailure.status != 0 && shellFailure.values.isEmpty && !shellFailure.stderr.isEmpty)
        let shellMissing = GitCommandExecution.loadLoginEnvironment(shell: "/kero-missing-shell")
        precondition(shellMissing.status == -1 && shellMissing.values.isEmpty)
        let slowShell = directory.appendingPathComponent("slow-shell")
        try Data("#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 5\n".utf8).write(to: slowShell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowShell.path)
        let shellStarted = Date()
        let shellTimeout = GitCommandExecution.loadLoginEnvironment(shell: slowShell.path, timeout: 0.1)
        precondition(shellTimeout.status == -2 && shellTimeout.values.isEmpty && Date().timeIntervalSince(shellStarted) < 3)
        let invalidShell = GitCommandExecution.loadLoginEnvironment(shell: "/bin/echo")
        precondition(invalidShell.status == -1 && invalidShell.values.isEmpty)
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
