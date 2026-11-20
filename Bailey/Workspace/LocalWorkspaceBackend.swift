import CryptoKit
import Darwin
import Foundation

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
        try Task.checkCancellation()
        guard maxBytes >= 0, maxBytes < .max, !path.utf8.contains(0) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        // Nonblocking open is necessary *before* fstat: a FIFO must never wait
        // for an unrelated writer before we can reject its file type.
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw WorkspaceError.notFound }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
        }
        guard info.st_size >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        let length = UInt64(info.st_size)
        guard length <= UInt64(maxBytes) else { throw WorkspaceError.tooLarge }

        var data = Data()
        while UInt64(data.count) < length {
            try Task.checkCancellation()
            let remaining = Int(min(65_536, length - UInt64(data.count)))
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
            data.append(chunk)
        }
        // A changed length invalidates the read; never return a partial or
        // mixed-length file as if it were the accepted full document.
        guard fstat(fd, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_size >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        guard UInt64(info.st_size) <= UInt64(maxBytes) else { throw WorkspaceError.tooLarge }
        guard UInt64(info.st_size) == length else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        }
        return data
    }

    @concurrent func write(path: String, data: Data) async throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// FileTab's conditional save has its own commit contract. POSIX offers
    /// atomic rename, not a universal compare-and-rename against outside writers.
    @concurrent func write(path: String, data: Data,
                           ifUnchanged version: WorkspaceFileVersion) async throws {
        try Task.checkCancellation()
        guard !path.utf8.contains(0) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        _ = try Self.verifyCurrentVersion(path: path, expected: version)
        // Fixed sibling name: a valid 255-byte filename must not overflow NAME_MAX.
        let parent = (path as NSString).deletingLastPathComponent
        var template = Array((parent + "/.bailey-save.XXXXXXXX").utf8CString)
        guard template.withUnsafeMutableBufferPointer({
            Darwin.mkdtemp($0.baseAddress)
        }) != nil else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let stage = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) },
                           as: UTF8.self)
        defer { try? FileManager.default.removeItem(atPath: stage) }
        let item = stage + "/item"
        try data.write(to: URL(fileURLWithPath: item), options: .withoutOverwriting)
        _ = try Self.verifyCurrentVersion(path: item, expected: WorkspaceFileVersion(data: data))
        let originalMode = try Self.verifyCurrentVersion(path: path, expected: version)
        if let originalMode {
            guard chmod(item, mode_t(originalMode)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        let stagedHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: item))
        try stagedHandle.synchronize()
        try stagedHandle.close()
        try Task.checkCancellation()
        let status = item.withCString { from in
            path.withCString { to in Darwin.rename(from, to) }
        }
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Verify bytes through a bounded streaming, nonblocking regular-file FD,
    /// without trusting mtime or a pathname's original inode. An identical-byte
    /// replacement is accepted by policy; a symlink entry is replaced on commit.
    private static func verifyCurrentVersion(
        path: String, expected: WorkspaceFileVersion
    ) throws -> Int? {
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw WorkspaceError.changedExternally }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, UInt64(info.st_size) == UInt64(expected.byteCount) else {
            throw WorkspaceError.changedExternally
        }
        let opened = info
        var digest = SHA256()
        var count = 0
        while count < expected.byteCount {
            try Task.checkCancellation()
            let wanted = min(65_536, expected.byteCount - count)
            guard let chunk = try handle.read(upToCount: wanted), !chunk.isEmpty else {
                throw WorkspaceError.changedExternally
            }
            digest.update(data: chunk)
            count += chunk.count
        }
        guard fstat(fd, &info) == 0, info.st_size >= 0,
              UInt64(info.st_size) == UInt64(expected.byteCount),
              info.st_dev == opened.st_dev, info.st_ino == opened.st_ino,
              info.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
              info.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec else {
            throw WorkspaceError.changedExternally
        }
        // A pathname may be replaced while the open FD is being hashed.
        // Verify that it still resolves to that FD, including through symlinks.
        var current = Darwin.stat()
        guard path.withCString({ fstatat(AT_FDCWD, $0, &current, 0) }) == 0,
              current.st_dev == info.st_dev, current.st_ino == info.st_ino else {
            throw WorkspaceError.changedExternally
        }
        let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == expected.sha256 else { throw WorkspaceError.changedExternally }
        guard lstat(path, &info) == 0 else { throw WorkspaceError.changedExternally }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return Int(info.st_mode & 0o7777)
        case S_IFLNK: return nil
        default: throw WorkspaceError.changedExternally
        }
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
        // Preserve the link's editability type, but expose a regular target's
        // byte length so image previews can enforce their actual read budget.
        let attributes = try? fm.attributesOfItem(atPath: path)
        var linkedFileSize: Int?
        if isSymlink {
            var target = Darwin.stat()
            if path.withCString({ fstatat(AT_FDCWD, $0, &target, 0) }) == 0,
               (target.st_mode & S_IFMT) == S_IFREG {
                linkedFileSize = Int(target.st_size)
            }
        }
        return WorkspaceStat(
            isRegular: (attributes?[.type] as? FileAttributeType) == .typeRegular,
            isDirectory: isDirectory.boolValue,
            isSymlink: isSymlink,
            size: linkedFileSize ?? (attributes?[.size] as? Int) ?? 0,
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
        let command = Task.detached(priority: .utility) {
            try Self.runSync(argv: argv, cwd: cwd, env: env, stdin: stdin, timeout: timeout)
        }
        return try await withTaskCancellationHandler {
            try await command.value
        } onCancel: {
            command.cancel()
        }
    }

    func runLimited(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?, stdoutLimit: Int, stderrLimit: Int
    ) async throws -> WorkspaceRunResult {
        let command = Task.detached(priority: .utility) {
            try Self.runSync(argv: argv, cwd: cwd, env: env, stdin: stdin,
                             timeout: timeout, stdoutLimit: stdoutLimit, stderrLimit: stderrLimit)
        }
        return try await withTaskCancellationHandler {
            try await command.value
        } onCancel: {
            command.cancel()
        }
    }

    /// Shared synchronous pipe owner for workspace and Git commands.
    /// It is always called off the main actor and polls for task cancellation.
    static func runSync(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?, stdoutLimit: Int? = nil, stderrLimit: Int? = nil,
        preservePartialOnTimeout: Bool = false,
        honorTaskCancellation: Bool = true,
        resetTimeoutOnTransferProgress: Bool = false
    ) throws -> WorkspaceRunResult {
        if honorTaskCancellation { try Task.checkCancellation() }
        guard let executable = argv.first else { throw WorkspaceError.notFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        if let env { process.environment = env }

        let stdout = Pipe()
        let stderr = Pipe()
        let input = stdin.map { _ in Pipe() }
        process.standardOutput = stdout
        process.standardError = stderr
        if let input, fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        process.standardInput = input ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGTERM)
                if exited.wait(timeout: .now() + .milliseconds(250)) == .timedOut,
                   process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + .milliseconds(250))
                }
            }
        }

        // One nonblocking owner drains both outputs and feeds stdin. A
        // separate input writer can outlive the process or block its caller.
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        let inFD = input?.fileHandleForWriting.fileDescriptor
        defer {
            if let input { try? input.fileHandleForWriting.close() }
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        for fd in [outFD, errFD] + (inFD.map { [$0] } ?? []) {
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        let inputData = stdin ?? Data()
        var inputOffset = 0
        var inputOpen = inFD != nil
        var inputError: Error?
        func closeInput() {
            guard inputOpen else { return }
            inputOpen = false
            if let input { try? input.fileHandleForWriting.close() }
        }
        if inputData.isEmpty { closeInput() }

        var deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
        var openFDs: Set<Int32> = [outFD, errFD]
        var outData = Data()
        var errData = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        func readAvailableOutput(_ fd: Int32) throws -> Bool {
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    if fd == outFD {
                        if let stdoutLimit, count > stdoutLimit - outData.count {
                            throw WorkspaceError.tooLarge
                        }
                        outData.append(buffer, count: count)
                        if resetTimeoutOnTransferProgress, let timeout {
                            deadline = ProcessInfo.processInfo.systemUptime + timeout
                        }
                    } else {
                        if let stderrLimit, count > stderrLimit - errData.count {
                            throw WorkspaceError.tooLarge
                        }
                        errData.append(buffer, count: count)
                    }
                    return true
                }
                if count == 0 {
                    openFDs.remove(fd)
                    return false
                }
                if errno == EINTR { continue }
                if errno == EAGAIN { return false }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        while !openFDs.isEmpty || process.isRunning {
            if honorTaskCancellation { try Task.checkCancellation() }
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline,
               process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGTERM)
                if exited.wait(timeout: .now() + .milliseconds(250)) == .timedOut,
                   process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + .milliseconds(250))
                }
                if preservePartialOnTimeout {
                    return WorkspaceRunResult(status: -2, stdout: outData, stderr: errData)
                }
                throw WorkspaceError.timedOut
            }
            if inputOpen && !process.isRunning {
                inputError = NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))
                closeInput()
            }
            var fds = openFDs.sorted().map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            if inputOpen, let inFD {
                fds.append(pollfd(fd: inFD, events: Int16(POLLOUT), revents: 0))
            }
            if fds.isEmpty {
                _ = exited.wait(timeout: .now() + .milliseconds(10))
                continue
            }
            let milliseconds = !process.isRunning ? 0 : (deadline.map {
                max(1, min(100, Int(($0 - ProcessInfo.processInfo.systemUptime) * 1_000)))
            } ?? 100)
            let ready = poll(&fds, nfds_t(fds.count), Int32(milliseconds))
            if ready < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            // A short-lived command can finish before poll reports its final
            // bytes. Drain each nonblocking pipe directly before returning;
            // never wait for an unrelated descendant to close an inherited FD.
            if ready == 0 && !process.isRunning {
                for fd in openFDs.sorted() {
                    while try readAvailableOutput(fd) {}
                }
                break
            }
            for entry in fds where entry.revents != 0 {
                if let inFD, entry.fd == inFD {
                    if entry.revents & Int16(POLLOUT) != 0 {
                        let written = inputData.withUnsafeBytes { bytes -> Int in
                            guard let base = bytes.baseAddress else { return 0 }
                            return Darwin.write(inFD, base.advanced(by: inputOffset),
                                                min(64 * 1024, bytes.count - inputOffset))
                        }
                        if written > 0 {
                            inputOffset += written
                            if resetTimeoutOnTransferProgress, let timeout {
                                deadline = ProcessInfo.processInfo.systemUptime + timeout
                            }
                            if inputOffset == inputData.count { closeInput() }
                        } else if written == 0 {
                            inputError = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                            closeInput()
                        } else if errno != EAGAIN && errno != EINTR {
                            inputError = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                            closeInput()
                        }
                    } else if entry.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                        inputError = NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))
                        closeInput()
                    }
                    continue
                }
                _ = try readAvailableOutput(entry.fd)
            }
        }
        if honorTaskCancellation { try Task.checkCancellation() }
        process.waitUntilExit()
        if inputOpen {
            inputError = NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))
            closeInput()
        }
        if let inputError, process.terminationStatus == 0 { throw inputError }
        return WorkspaceRunResult(
            status: process.terminationStatus,
            stdout: outData,
            stderr: errData
        )
    }

}
