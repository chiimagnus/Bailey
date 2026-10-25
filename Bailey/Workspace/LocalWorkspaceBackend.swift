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

/// Completed paths and independent failures from one Finder copy batch.
nonisolated struct LocalFileImportResult: Sendable {
    let copied: [String]
    let failures: [String]
}

/// Absolute, normalized POSIX paths; the filesystem root is its own separator.
nonisolated enum LocalPathScope {
    static func contains(_ path: String, in directory: String) -> Bool {
        guard !directory.isEmpty else { return false }
        return path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    /// After a move, resolve surviving ancestors rather than the now-missing old leaf.
    static func resolvedPath(_ path: String) -> String {
        var url = URL(fileURLWithPath: path)
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            guard parent != url else { break }
            missing.append(url.lastPathComponent)
            url = parent
        }
        return missing.reversed().reduce(url.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.path
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

    /// The Finder-to-Files action copies on a background executor and never
    /// replaces a destination, removes a source, or uploads to a remote host.
    @concurrent func copyFromFinder(_ sources: [URL], into directory: String) async -> LocalFileImportResult {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let targetReal = target.resolvingSymlinksInPath().path
        var copied: [String] = []
        var failures: [String] = []
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return LocalFileImportResult(copied: [], failures: [
                String(localized: "Target folder no longer exists: \(directory)", table: "Workspace")
            ])
        }
        var seen = Set<String>()
        for source in sources {
            guard source.isFileURL, source.host == nil || source.host == "localhost" else {
                failures.append(String(
                    localized: "Not a local Finder file: \(source.lastPathComponent)", table: "Workspace"
                ))
                continue
            }
            let original = source.standardizedFileURL
            guard seen.insert(original.path).inserted else { continue }
            // Copy the directory entry, not the symlink's resolved destination.
            // fileExists follows links and incorrectly rejects dangling links;
            // treating a directory link as a real folder also falsely blocks
            // copying the link when it points to an ancestor of the target.
            var sourceInfo = Darwin.stat()
            guard lstat(original.path, &sourceInfo) == 0 else {
                failures.append(String(
                    localized: "Source no longer exists: \(original.lastPathComponent)", table: "Workspace"
                ))
                continue
            }
            let sourceType = sourceInfo.st_mode & S_IFMT
            guard sourceType == S_IFREG || sourceType == S_IFDIR || sourceType == S_IFLNK else {
                let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
                failures.append(String(
                    localized: "Couldn’t copy \(original.lastPathComponent): \(error.localizedDescription)",
                    table: "Workspace"
                ))
                continue
            }
            let isRealDirectory = sourceType == S_IFDIR
            let destination = target.appendingPathComponent(
                original.lastPathComponent, isDirectory: isRealDirectory
            )
            if isRealDirectory,
               LocalPathScope.contains(targetReal, in: original.resolvingSymlinksInPath().path) {
                failures.append(String(
                    localized: "Cannot copy \(original.lastPathComponent) into itself or a subfolder.",
                    table: "Workspace"
                ))
                continue
            }
            var existing = Darwin.stat()
            if lstat(destination.path, &existing) == 0 {
                failures.append(String(
                    localized: "Already exists: \(destination.lastPathComponent)", table: "Workspace"
                ))
                continue
            }
            do {
                try Self.copyExclusive(from: original, to: destination)
                copied.append(destination.path)
            } catch {
                failures.append(String(
                    localized: "Couldn’t copy \(original.lastPathComponent): \(error.localizedDescription)",
                    table: "Workspace"
                ))
            }
        }
        return LocalFileImportResult(copied: copied, failures: failures)
    }

    @concurrent func copy(from: String, to: String) async throws {
        try Self.copyExclusive(
            from: URL(fileURLWithPath: from).standardizedFileURL,
            to: URL(fileURLWithPath: to).standardizedFileURL
        )
    }

    private static func copyExclusive(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        var sourceInfo = Darwin.stat()
        guard lstat(source.path, &sourceInfo) == 0 else { throw WorkspaceError.notFound }
        let type = sourceInfo.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR || type == S_IFLNK else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
        }
        let parent = destination.deletingLastPathComponent()
        let parentReal = parent.resolvingSymlinksInPath().path
        if type == S_IFDIR,
           LocalPathScope.contains(parentReal, in: source.resolvingSymlinksInPath().path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        var occupied = Darwin.stat()
        if lstat(destination.path, &occupied) == 0 {
            throw CocoaError(.fileWriteFileExists)
        }
        // Copy privately on the destination volume, then atomically publish without clobbering.
        let stagingDirectory = try fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: parent, create: true
        )
        defer { try? fm.removeItem(at: stagingDirectory) }
        let staged = stagingDirectory.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: staged)
        let status = staged.path.withCString { from in
            destination.path.withCString { to in
                renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
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

    /// The synchronous file metadata path used by local workspace operations.
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

    // MARK: - Commands

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

}
