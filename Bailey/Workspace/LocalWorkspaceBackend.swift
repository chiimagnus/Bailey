import Darwin
import Foundation

/// Writes complete stdin or returns an error. Nonblocking IO lets the writer
/// honor a deadline even when a child exits but its descendant keeps the
/// read end of the pipe open without consuming bytes.
nonisolated final class ProcessStdinWriter: @unchecked Sendable {
    private let completion = DispatchGroup()
    private var writeError: Error?

    init(data: Data, pipe: Pipe, timeout: TimeInterval?) {
        completion.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? pipe.fileHandleForWriting.close()
                self.completion.leave()
            }
            do {
                let fd = pipe.fileHandleForWriting.fileDescriptor
                let flags = fcntl(fd, F_GETFL, 0)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
                try data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    var offset = 0
                    while offset < bytes.count {
                        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
                            throw WorkspaceError.timedOut
                        }
                        var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let count = poll(&ready, 1, 100)
                        if count == 0 || (count < 0 && errno == EINTR) { continue }
                        if count < 0 {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                        let written = Darwin.write(fd, base.advanced(by: offset),
                                                   min(64 * 1024, bytes.count - offset))
                        if written > 0 {
                            offset += written
                        } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                            continue
                        } else {
                            throw NSError(domain: NSPOSIXErrorDomain,
                                          code: Int(written == 0 ? EIO : errno))
                        }
                    }
                }
            } catch {
                self.writeError = error
            }
        }
    }

    func finish() -> Error? {
        completion.wait()
        return writeError
    }
}

/// The Mac's own disk and process table. Wraps exactly the calls the panels
/// made inline before the seam existed.
///
/// Nothing is stored, so the type is `Sendable` and its `@concurrent`
/// methods run off the main actor even when a main-actor model awaits them.
nonisolated final class LocalWorkspaceBackend: WorkspaceBackend {
    static let shared = LocalWorkspaceBackend()

    // MARK: - Files

    @concurrent func list(directory: String) async throws -> [WorkspaceEntry] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        return names.map { name in
            let path = (directory as NSString).appendingPathComponent(name)
            var info = Darwin.stat()
            // lstat describes the link itself, and its mode already answers
            // "directory?" for everything that is not a link. Only a link
            // needs the second, symlink-following call.
            guard lstat(path, &info) == 0 else {
                return WorkspaceEntry(name: name, isDirectory: false, isSymlink: false)
            }
            guard (info.st_mode & S_IFMT) == S_IFLNK else {
                return WorkspaceEntry(
                    name: name,
                    isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
                    isSymlink: false
                )
            }
            var isDirectory: ObjCBool = false
            let resolved = FileManager.default.fileExists(
                atPath: path, isDirectory: &isDirectory
            )
            return WorkspaceEntry(
                name: name,
                isDirectory: resolved && isDirectory.boolValue,
                isSymlink: true
            )
        }
    }

    @concurrent func stat(path: String) async throws -> WorkspaceStat? {
        Self.statSync(path)
    }

    @concurrent func readSymlinkDestination(path: String) async throws -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    @concurrent func read(path: String, maxBytes: Int) async throws -> Data {
        try Self.readSync(path: path, maxBytes: maxBytes)
    }

    private static func readSync(path: String, maxBytes: Int) throws -> Data {
        do {
            // Keep one descriptor for the whole read: replacing the path while
            // an agent writes cannot redirect us to a different, larger file.
            // Seek checks catch growth without ever loading more than maxBytes.
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let initialSize = try handle.seekToEnd()
            guard initialSize <= UInt64(maxBytes) else { throw WorkspaceError.tooLarge }
            try handle.seek(toOffset: 0)

            var data = Data()
            while data.count < maxBytes {
                let remaining = min(64 * 1024, maxBytes - data.count)
                guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
            let finalSize = try handle.seekToEnd()
            guard finalSize <= UInt64(maxBytes) else { throw WorkspaceError.tooLarge }
            return data
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            throw WorkspaceError.notFound
        }
    }

    @concurrent func write(path: String, data: Data) async throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    @concurrent func createFile(path: String) async throws {
        try Data().write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }

    @concurrent func createDirectory(path: String) async throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: false
        )
    }

    @concurrent func rename(from: String, to: String) async throws {
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }

    @concurrent func delete(paths: [String]) async throws {
        for path in paths {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: path), resultingItemURL: nil
            )
        }
    }

    // MARK: - Git geography

    @concurrent func gitRoot(containing path: String) async throws -> String? {
        Self.gitRootSync(containing: path)
    }

    @concurrent func isLinkedWorktree(_ root: String) async throws -> Bool {
        Self.isLinkedWorktreeSync(root)
    }

    /// Shared with `Project.panelRoot`, which still has a synchronous form for
    /// callers that cannot await (the command palette and the Git panel).
    static func statSync(_ path: String) -> WorkspaceStat? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        // Following symlinks matches `FileManager.fileExists`, so a dangling
        // link reads as "does not exist" here as it did inline.
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
        // Attributes describe the link rather than its target, so a symlink is
        // never reported as a regular file — the editability gate this
        // replaces drew the same conclusion the same way.
        let attributes = try? fm.attributesOfItem(atPath: path)
        return WorkspaceStat(
            isRegular: (attributes?[.type] as? FileAttributeType) == .typeRegular,
            isDirectory: isDirectory.boolValue,
            isSymlink: isSymlink,
            size: (attributes?[.size] as? Int) ?? 0,
            mtime: (attributes?[.modificationDate] as? Date) ?? .distantPast
        )
    }

    /// Walks up from `path` looking for a `.git` entry — a directory in normal
    /// checkouts, a file in worktrees and submodules.
    static func gitRootSync(containing path: String) -> String? {
        var dir = (path as NSString).standardizingPath
        guard dir.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { return nil }
            dir = parent
        }
    }

    /// A linked worktree's `.git` is a file pointing into the main
    /// repository's `worktrees` directory (a submodule's points into
    /// `modules` instead).
    static func isLinkedWorktreeSync(_ root: String) -> Bool {
        let gitPath = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let contents = try? String(contentsOfFile: gitPath, encoding: .utf8)
        else { return false }
        return contents.contains("/worktrees/")
    }

    // MARK: - Processes

    static let loginShell: String = {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()

    func run(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) async throws -> WorkspaceRunResult {
        // Waiting on pipe readers blocks, which an async function may not do,
        // so the whole launch runs on a background thread — where the panels
        // ran their `ps` and `lsof` calls before the seam existed.
        try await Task.detached(priority: .utility) {
            try Self.runSync(
                argv: argv, cwd: cwd, env: env, stdin: stdin, timeout: timeout
            )
        }.value
    }

    private static func runSync(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) throws -> WorkspaceRunResult {
        guard let executable = argv.first else { throw WorkspaceError.notFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        if let env {
            process.environment = env
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let input: Pipe? = stdin == nil ? nil : Pipe()
        if let input, fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        process.standardInput = input ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let writer = input.flatMap { pipe in
            stdin.map { ProcessStdinWriter(data: $0, pipe: pipe, timeout: timeout) }
        }

        // Drain stdout and stderr concurrently without waiting for inherited
        // pipe handles to reach EOF after the direct child has exited.
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        for fd in [outFD, errFD] {
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
        var openFDs: Set<Int32> = [outFD, errFD]
        var outData = Data()
        var errData = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while !openFDs.isEmpty || process.isRunning {
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGTERM)
                    if exited.wait(timeout: .now() + .milliseconds(250)) == .timedOut,
                       process.isRunning {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL)
                        _ = exited.wait(timeout: .now() + .milliseconds(250))
                    }
                }
                throw WorkspaceError.timedOut
            }
            if openFDs.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            var fds = openFDs.sorted().map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let milliseconds = deadline.map {
                max(1, min(100, Int(($0 - ProcessInfo.processInfo.systemUptime) * 1_000)))
            } ?? 100
            let ready = poll(&fds, nfds_t(fds.count), Int32(milliseconds))
            if ready < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            for entry in fds where entry.revents != 0 {
                let count = Darwin.read(entry.fd, &buffer, buffer.count)
                if count > 0 {
                    if entry.fd == outFD { outData.append(buffer, count: count) }
                    else { errData.append(buffer, count: count) }
                } else if count == 0 {
                    openFDs.remove(entry.fd)
                } else if errno != EAGAIN && errno != EINTR {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        }
        process.waitUntilExit()
        if let error = writer?.finish(), process.terminationStatus == 0 { throw error }
        return WorkspaceRunResult(
            status: process.terminationStatus,
            stdout: outData,
            stderr: errData
        )
    }

    @concurrent func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot {
        // `comm` is the executable path with no arguments, so the only
        // free-form field is the last one and column parsing stays safe.
        let psOut = try await text(
            argv: ["/bin/ps", "-axo", "pid=,ppid=,stat=,pcpu=,rss=,comm="]
        )
        var itemsByPid: [pid_t: WorkspaceProcess] = [:]
        var names: [pid_t: String] = [:]
        var childPids: [pid_t: [pid_t]] = [:]
        for line in psOut.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6,
                  let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1]) else { continue }
            // Recorded before the zombie check so the descendant walk below
            // still traverses the tree through anything we skip.
            childPids[ppid, default: []].append(pid)
            // Zombies are children that already exited and are waiting to be
            // reaped: `ps` names them "<defunct>", they hold no CPU or memory,
            // and no signal can touch them. Nothing to show or act on.
            guard !fields[2].hasPrefix("Z") else { continue }
            let executable = String(fields[5])
            let name = (executable as NSString).lastPathComponent
            names[pid] = name
            itemsByPid[pid] = WorkspaceProcess(
                pid: pid,
                name: name,
                executable: executable,
                cpu: Double(fields[3]) ?? 0,
                memoryKB: Int(fields[4]) ?? 0
            )
        }

        // Descendants breadth-first: the commands the user ran come before
        // the workers they spawned.
        var descendants: [WorkspaceProcess] = []
        var queue = childPids[pid] ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let item = itemsByPid[next] {
                descendants.append(item)
            }
            queue.append(contentsOf: childPids[next] ?? [])
        }
        return WorkspaceProcessSnapshot(descendants: descendants, namesByPid: names)
    }

    @concurrent func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] {
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        // -a ANDs the selectors, so this only inspects the session's own
        // processes instead of walking every fd on the machine.
        let out = try await text(
            argv: [
                "/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", list, "-Fpn",
            ]
        )

        var ports: [WorkspacePort] = []
        var seen = Set<String>()
        var currentPid: pid_t = 0
        for line in out.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p":
                currentPid = pid_t(value) ?? 0
            case "n":
                // Addresses look like "*:3000", "127.0.0.1:3000", "[::1]:3000".
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                // The same socket shows once for IPv4 and once for IPv6.
                if seen.insert("\(currentPid):\(port)").inserted {
                    ports.append(WorkspacePort(port: port, pid: currentPid))
                }
            default:
                break
            }
        }
        return ports.sorted { $0.port < $1.port }
    }

    func kill(pid: pid_t, force: Bool) async throws {
        Darwin.kill(pid, force ? SIGKILL : SIGTERM)
    }

    /// Decoded stdout, empty when the tool could not be launched — the
    /// tolerance `ps` and `lsof` parsing has always had.
    private func text(argv: [String]) async throws -> String {
        guard let result = try? await run(
            argv: argv, cwd: nil, env: nil, stdin: nil, timeout: nil
        ) else { return "" }
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }
}
