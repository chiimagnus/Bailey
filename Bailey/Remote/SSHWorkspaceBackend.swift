import Darwin
import Foundation

/// Runs one command on the remote machine and returns what it printed.
///
/// Both an interactive connection and a configured SSH host implement this
/// boundary; the workspace does not own their authentication or lifetime.
nonisolated protocol RemoteCommandRunner: Sendable {
    func run(
        _ argv: [String], stdin: Data?, timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: Data, stderr: Data)
}

/// A remote command that failed, carrying the remote's own message so the
/// panel can show what the remote said rather than a generic failure.
nonisolated struct RemoteCommandFailure: LocalizedError {
    let command: String
    let status: Int32
    let message: String

    var errorDescription: String? {
        message.isEmpty ? "Remote command failed (status \(status))." : message
    }
}

/// Files, Git and Linux process queries reached through an SSH command runner.
///
/// Every method is a single round trip: build the command with
/// `RemoteCommands`, run it, parse the output.
nonisolated final class SSHWorkspaceBackend: WorkspaceBackend {
    private let runner: RemoteCommandRunner
    private let timeout: TimeInterval

    init(runner: RemoteCommandRunner, timeout: TimeInterval = 10) {
        self.runner = runner
        self.timeout = timeout
    }

    /// Exit codes the built commands use to report a condition precisely,
    /// rather than leaving it to be guessed from an error message.
    private enum ExitCode {
        static let missing: Int32 = 44
        static let exists: Int32 = 45
    }

    // MARK: - Running

    @discardableResult
    private func shell(_ command: String, stdin: Data? = nil) async throws -> Data {
        let result = try await runner.run([command], stdin: stdin, timeout: timeout)
        guard result.status == 0 else {
            throw failure(command: command, result: result)
        }
        return result.stdout
    }

    private func failure(
        command: String, result: (status: Int32, stdout: Data, stderr: Data)
    ) -> Error {
        switch result.status {
        case ExitCode.missing: return WorkspaceError.notFound
        case ExitCode.exists: return CocoaError(.fileWriteFileExists)
        default:
            let message = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RemoteCommandFailure(
                command: command, status: result.status, message: message
            )
        }
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// Guards a command so a missing path is reported as `notFound` rather
    /// than as whatever message the tool happened to print.
    private func requiring(_ path: String, _ command: String) -> String {
        "[ -e \(RemoteCommands.quote(path)) ] || exit \(ExitCode.missing); " + command
    }

    // MARK: - Files

    @concurrent func list(directory: String) async throws -> [WorkspaceEntry] {
        let command = requiring(directory, RemoteCommands.listDirectoryCommand(path: directory))
        return RemoteCommands.parseDirectoryListing(try await shell(command))
    }

    /// Re-read visible directories in a single SSH round trip. Failures leave
    /// their keys absent so a disconnected folder keeps its last contents.
    @concurrent func list(directories: [String]) async -> [String: [WorkspaceEntry]] {
        guard !directories.isEmpty else { return [:] }
        let tag = UUID().uuidString
        let commands = directories.enumerated().map { index, directory in
            let quoted = RemoteCommands.quote(directory)
            return (
                name: String(index),
                command: "[ -d \(quoted) ] && "
                    + RemoteCommands.listDirectoryCommand(path: directory) + " 2>/dev/null"
            )
        }
        let script = RemoteCommands.batchCommand(commands, tag: tag)
        guard let response = try? await runner.run(
            ["sh", "-s"], stdin: Data(script.utf8), timeout: timeout
        ), response.status == 0 else { return [:] }
        let parsed = RemoteCommands.parseBatch(response.stdout, tag: tag)
        var result: [String: [WorkspaceEntry]] = [:]
        for (index, directory) in directories.enumerated() {
            guard let entry = parsed[String(index)], entry.status == 0 else { continue }
            result[directory] = RemoteCommands.parseDirectoryListing(entry.stdout)
        }
        return result
    }

    func stat(path: String) async throws -> WorkspaceStat? {
        // A missing path is not an error here: the local backend answers nil.
        let output = try await shell(RemoteCommands.statCommand(path: path) + "; :")
        return RemoteCommands.parseStat(text(output))?.stat
    }

    func readSymlinkDestination(path: String) async throws -> String? {
        let quoted = RemoteCommands.quote(path)
        let output = try await shell("readlink -- \(quoted) 2>/dev/null; :")
        let destination = text(output).trimmingCharacters(in: .newlines)
        return destination.isEmpty ? nil : destination
    }

    /// Reads one byte past the cap so an oversized file can be told apart from
    /// one that happens to be exactly `maxBytes` long.
    func read(path: String, maxBytes: Int) async throws -> Data {
        let quoted = RemoteCommands.quote(path)
        let limit = maxBytes == .max ? nil : maxBytes + 1
        let read = limit.map { "head -c \($0) -- \(quoted)" } ?? "cat -- \(quoted)"
        let data = try await shell(requiring(path, read))
        if let limit, data.count == limit { throw WorkspaceError.tooLarge }
        return data
    }

    func write(path: String, data: Data) async throws {
        try await shell(RemoteCommands.atomicWriteCommand(path: path), stdin: data)
    }

    func createFile(path: String) async throws {
        try await shell(RemoteCommands.createFileCommand(path: path))
    }

    /// No `-p`: the local backend creates one level and fails when the
    /// directory already exists, and the panel's wording depends on that.
    func createDirectory(path: String) async throws {
        try await shell("mkdir -- \(RemoteCommands.quote(path))")
    }

    /// Never overwrite a competing name, including a dangling symlink.
    /// Case-only renames on case-insensitive volumes need a temporary sibling:
    /// equal inodes alone cannot distinguish an alias from two hard links.
    func rename(from: String, to: String) async throws {
        let source = RemoteCommands.quote(from)
        let destination = RemoteCommands.quote(to)
        let nestedDestination = RemoteCommands.quote(
            (to as NSString).appendingPathComponent((from as NSString).lastPathComponent)
        )
        let temporary = RemoteCommands.quote(
            ((from as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(".bailey-rename.XXXXXXXX")
        )
        try await shell("""
            if [ ! -e \(source) ] && [ ! -L \(source) ]; then exit \(ExitCode.missing); fi
            sourceID=$(ls -id -- \(source)) || exit \(ExitCode.missing)
            sourceID=${sourceID%% *}
            restoreNested() {
                if [ ! -e \(source) ] && [ ! -L \(source) ] && [ -d \(destination) ]; then
                    nestedID=$(ls -id -- \(nestedDestination) 2>/dev/null) || return 0
                    nestedID=${nestedID%% *}
                    if [ "$nestedID" = "$sourceID" ]; then
                        mv -n -- \(nestedDestination) \(source) || return 1
                    fi
                fi
            }
            verifyDestination() {
                actualID=$(ls -id -- \(destination)) || return 1
                actualID=${actualID%% *}
                if [ "$actualID" != "$sourceID" ]; then
                    restoreNested || return 1
                    return \(ExitCode.exists)
                fi
            }
            if [ -e \(destination) ] || [ -L \(destination) ]; then
                if [ ! \(source) -ef \(destination) ] && [ ! -L \(source) ]; then
                    exit \(ExitCode.exists)
                fi
                temp=$(mktemp -d \(temporary)) || exit 1
                restoreSource() {
                    if [ -e "$temp/item" ] || [ -L "$temp/item" ]; then
                        if [ ! -e \(source) ] && [ ! -L \(source) ]; then
                            mv -n -- "$temp/item" \(source) || :
                        fi
                    fi
                    rmdir "$temp" 2>/dev/null || :
                    restoreNested || :
                }
                trap 'restoreSource' EXIT
                trap 'exit 1' HUP INT TERM
                mv -- \(source) "$temp/item" || exit 1
                if [ -e \(destination) ] || [ -L \(destination) ]; then
                    exit \(ExitCode.exists)
                fi
                mv -n -- "$temp/item" \(destination) || exit 1
                if [ -e "$temp/item" ] || [ -L "$temp/item" ]; then
                    exit \(ExitCode.exists)
                fi
                verifyDestination || exit "$?"
                trap - EXIT HUP INT TERM
                rmdir "$temp"
            else
                mv -n -- \(source) \(destination) || exit 1
                if [ -e \(source) ] || [ -L \(source) ]; then exit \(ExitCode.exists); fi
                verifyDestination || exit "$?"
            fi
            """)
    }

    /// There is no remote Trash: freedesktop trash semantics vary between
    /// distributions, and a file quietly moved somewhere unexpected is worse
    /// than an explicit delete. The caller confirms first.
    func delete(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let quoted = paths.map(RemoteCommands.quote).joined(separator: " ")
        try await shell("rm -rf -- \(quoted)")
    }

    // MARK: - Git geography

    /// Read-only, and needed before any panel can pick its root.
    @concurrent func gitRoot(containing path: String) async throws -> String? {
        let command = "env LC_ALL=C git -C \(RemoteCommands.quote(path)) rev-parse --show-toplevel"
        let result = try await runner.run([command], stdin: nil, timeout: timeout)
        if result.status == 0 {
            let root = text(result.stdout).trimmingCharacters(in: .newlines)
            guard !root.isEmpty else {
                throw RemoteCommandFailure(command: command, status: 0, message: "Git returned an empty repository path.")
            }
            return root
        }
        let message = text(result.stderr)
        if result.status == 128 && message.localizedCaseInsensitiveContains("not a git repository") {
            return nil
        }
        throw failure(command: command, result: result)
    }

    /// A linked worktree has `.git` as a file pointing into the main
    /// repository, not as a directory.
    func isLinkedWorktree(_ root: String) async throws -> Bool {
        let marker = RemoteCommands.quote((root as NSString).appendingPathComponent(".git"))
        let output = try await shell(
            "[ -f \(marker) ] && grep -c '/worktrees/' \(marker) 2>/dev/null; :"
        )
        return (Int(text(output).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    // MARK: - Processes

    func run(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) async throws -> WorkspaceRunResult {
        guard !argv.isEmpty else { throw WorkspaceError.notFound }
        var command = ""
        if let cwd { command += "cd \(RemoteCommands.doubleQuote(cwd)) && " }
        if let env, !env.isEmpty {
            let assignments = env.keys.sorted().map {
                "\($0)=\(RemoteCommands.doubleQuote(env[$0]!))"
            }
            command += "env " + assignments.joined(separator: " ") + " "
        }
        command += argv.map(RemoteCommands.doubleQuote).joined(separator: " ")

        let result = try await runner.run(
            [command], stdin: stdin, timeout: timeout ?? self.timeout
        )
        return WorkspaceRunResult(
            status: result.status, stdout: result.stdout, stderr: result.stderr
        )
    }

    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot {
        let output = try await shell(RemoteCommands.processListCommand())
        let rows = RemoteCommands.parseProcessList(text(output))
        return RemoteCommands.snapshot(rows: rows, descendantsOf: pid)
    }

    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] {
        let output = try await shell(RemoteCommands.listeningPortsCommand())
        let wanted = Set(pids)
        return RemoteCommands.parseListeningPorts(text(output))
            .filter { wanted.contains($0.pid) }
    }

    func kill(pid: pid_t, force: Bool) async throws {
        try await shell("kill -\(force ? "KILL" : "TERM") \(pid)")
    }

    // MARK: - Where the session is

    /// The interactive shell on this connection and the directory it is in,
    /// or nil when no shell can be identified — a session Bailey is not in front
    /// of, or a remote without `/proc`.
    func remoteWorkingDirectory(
        terminalTag: String? = nil
    ) async throws -> (pid: pid_t, directory: String)? {
        let command = RemoteCommands.shellDiscoveryCommand(terminalTag: terminalTag)
        let output = try await shell(command + "; :")
        return RemoteCommands.parseShellDiscovery(text(output))
    }
}

/// Shared subprocess execution for independent SSH workspace commands.
nonisolated enum ProcessRemoteCommandRunner {

    static func launch(
        sshPath: String, arguments: [String], stdin: Data?, timeout: TimeInterval
    ) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let result = run(sshPath: sshPath, arguments: arguments, stdin: stdin, timeout: timeout)
        if result.status == -2 { throw WorkspaceError.timedOut }
        if result.status == -1 {
            throw RemoteConnectionError.commandFailed(
                status: result.status, message: String(decoding: result.stderr, as: UTF8.self)
            )
        }
        return result
    }

    static func run(
        sshPath: String, arguments: [String], stdin: Data?, timeout: TimeInterval
    ) -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe? = stdin == nil ? nil : Pipe()
        if let stdinPipe, fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != 0 {
            return (-1, Data(), Data(String(cString: strerror(errno)).utf8))
        }
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return (-1, Data(), Data(error.localizedDescription.utf8))
        }
        let writer = stdinPipe.flatMap { pipe in
            stdin.map { ProcessStdinWriter(data: $0, pipe: pipe, timeout: timeout) }
        }
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        for descriptor in [outFD, errFD] {
            let flags = fcntl(descriptor, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        }
        var outData = Data()
        var errData = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        var openDescriptors: Set<Int32> = [outFD, errFD]
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while true {
            if Date() >= deadline {
                timedOut = true
                break
            }
            var fds = openDescriptors.sorted().map { descriptor in
                pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            }
            if fds.isEmpty {
                if exited.wait(timeout: .now() + .milliseconds(200)) == .success { break }
                continue
            }
            let ready = poll(&fds, nfds_t(fds.count), 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            for entry in fds where entry.revents != 0 {
                let count = Darwin.read(entry.fd, &buffer, buffer.count)
                if count > 0 {
                    if entry.fd == outFD {
                        outData.append(buffer, count: count)
                    } else {
                        errData.append(buffer, count: count)
                    }
                } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                    openDescriptors.remove(entry.fd)
                }
            }
        }
        if timedOut {
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + .seconds(1)) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + .seconds(1))
                }
            }
            errData.append(Data("\nssh did not respond in time.\n".utf8))
            return (-2, outData, errData)
        }
        if let error = writer?.finish(), process.terminationStatus == 0 {
            errData.append(Data(error.localizedDescription.utf8))
            return (-1, outData, errData)
        }
        return (process.terminationStatus, outData, errData)
    }
}
