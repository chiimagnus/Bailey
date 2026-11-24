import CryptoKit
import Darwin
import Foundation

/// Completed paths and independent failures from one local file transfer batch.
nonisolated struct LocalFileTransferResult: Sendable {
    var copied: [String] = []
    var moved: [(source: String, destination: String)] = []
    var copiedWithoutRemoval: [(source: String, destination: String, retainedAt: String)] = []
    var failures: [String] = []
}

nonisolated enum LocalFileTransferOutcome: Sendable {
    case copied(String)
    case moved(String)
    case copiedWithoutRemoval(destination: String, retainedAt: String)
    case unchanged
}

/// Absolute, normalized POSIX paths; the filesystem root is its own separator.
nonisolated enum LocalPathScope {
    static func contains(_ path: String, in directory: String) -> Bool {
        guard !directory.isEmpty else { return false }
        return path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    // FSEvents uses physical paths, including /private/var, which Foundation
    // may shorten to /var even when resolving symbolic links.
    static func physicalPath(_ root: String) -> String {
        root.withCString { source in
            guard let resolved = Darwin.realpath(source, nil) else { return root }
            defer { free(resolved) }
            return String(cString: resolved)
        }
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


/// The directory entry's identity at a specific point in time, without following links.
nonisolated struct LocalFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    func refersToSameEntry(as other: Self) -> Bool {
        device == other.device && inode == other.inode && (mode & UInt16(S_IFMT)) == (other.mode & UInt16(S_IFMT))
    }

    static func read(_ path: String) -> Self? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Self(info)
    }

    fileprivate init(_ info: Darwin.stat) {
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(truncatingIfNeeded: info.st_ino)
        mode = UInt16(info.st_mode)
        size = Int64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
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

    @concurrent func readPrefix(path: String, maxBytes: Int) async throws -> Data {
        try Self.readSync(path: path, maxBytes: maxBytes, prefixOnly: true)
    }

    @concurrent func read(path: String, maxBytes: Int, confinedTo directory: String) async throws -> Data {
        try Self.readSync(path: path, maxBytes: maxBytes, confinedTo: Self.canonicalPath(directory))
    }

    @concurrent func checkConfinedFile(_ path: String, in directory: String) async throws {
        let root = try Self.canonicalPath(directory)
        let resolved = try Self.canonicalPath(path)
        guard LocalPathScope.contains(resolved, in: root),
              Self.statSync(resolved)?.isRegular == true else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private static func canonicalPath(_ path: String) throws -> String {
        guard !path.utf8.contains(0), let resolved = realpath(path, nil) else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func readableFile(at path: String) throws -> (path: String, identity: LocalFileIdentity) {
        try Task.checkCancellation()
        let handle = try openForReading(path)
        defer { try? handle.close() }
        let info = try regularFileStat(handle)
        return (try pathOfOpenFile(handle), LocalFileIdentity(info))
    }

    private static func openForReading(_ path: String) throws -> FileHandle {
        guard !path.utf8.contains(0) else {
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
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func pathOfOpenFile(_ handle: FileHandle) throws -> String {
        var resolved = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(handle.fileDescriptor, F_GETPATH, &resolved) != -1 else {
            throw CocoaError(.fileReadNoPermission)
        }
        return String(decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func regularFileStat(_ handle: FileHandle) throws -> Darwin.stat {
        var info = Darwin.stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
        }
        guard info.st_size >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return info
    }

    private static func readSync(path: String, maxBytes: Int, confinedTo root: String? = nil,
                                 prefixOnly: Bool = false) throws -> Data {
        try Task.checkCancellation()
        guard maxBytes >= 0, maxBytes < .max else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let handle = try openForReading(path)
        defer { try? handle.close() }
        if let root, try !LocalPathScope.contains(pathOfOpenFile(handle), in: root) {
            throw CocoaError(.fileReadNoPermission)
        }
        let info = try regularFileStat(handle)
        let fileLength = UInt64(info.st_size)
        guard prefixOnly || fileLength <= UInt64(maxBytes) else { throw WorkspaceError.tooLarge }
        let length = min(fileLength, UInt64(maxBytes))

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
        let after = try regularFileStat(handle)
        guard prefixOnly || UInt64(after.st_size) <= UInt64(maxBytes) else { throw WorkspaceError.tooLarge }
        guard UInt64(after.st_size) == fileLength else {
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
        try Self.writeStaged(path: path, data: data, ifUnchanged: version)
    }

    @concurrent func writeNewFile(path: String, data: Data) async throws {
        try Self.writeStaged(path: path, data: data, ifUnchanged: nil)
    }

    private static func writeStaged(path: String, data: Data, ifUnchanged version: WorkspaceFileVersion?) throws {
        try Task.checkCancellation()
        guard !path.utf8.contains(0) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        if let version { _ = try Self.verifyCurrentVersion(path: path, expected: version) }
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
        if let version, let originalMode = try Self.verifyCurrentVersion(path: path, expected: version) {
            guard chmod(item, mode_t(originalMode)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        let stagedHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: item))
        try stagedHandle.synchronize()
        try stagedHandle.close()
        try Task.checkCancellation()
        let status: Int32
        if version != nil {
            status = item.withCString { from in path.withCString { to in Darwin.rename(from, to) } }
        } else {
            status = exclusiveRename(from: URL(fileURLWithPath: item), to: URL(fileURLWithPath: path))
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

    /// Finder drop and local Files paste share the exact same transfer rules.
    @concurrent func transferLocalFiles(
        _ sources: [URL], into directory: String, move: Bool = false,
        authorizedRoot: String? = nil,
        expectedIdentities: [String: LocalFileIdentity]? = nil
    ) async -> LocalFileTransferResult {
        var result = LocalFileTransferResult()
        var seen = Set<URL>()
        let unique = sources.filter { seen.insert($0.standardizedFileURL).inserted }
        let selectedDirectories = Set(unique.compactMap { source -> String? in
            guard source.isFileURL,
                  let identity = LocalFileIdentity.read(source.standardizedFileURL.path),
                  identity.mode & UInt16(S_IFMT) == UInt16(S_IFDIR) else { return nil }
            return source.standardizedFileURL.path
        })
        for source in unique {
            guard source.isFileURL else {
                result.failures.append("Not a local file URL: \(source.absoluteString)")
                continue
            }
            let path = source.standardizedFileURL.path
            var ancestor = (path as NSString).deletingLastPathComponent
            var includedByParent = false
            while ancestor != path {
                if selectedDirectories.contains(ancestor) {
                    includedByParent = true
                    break
                }
                let next = (ancestor as NSString).deletingLastPathComponent
                if next == ancestor { break }
                ancestor = next
            }
            if includedByParent { continue }
            if let expectedIdentities, expectedIdentities[path] == nil {
                result.failures.append("Source was missing when the transfer began: \(path)")
                continue
            }
            do {
                let outcome = try Self.transferLocalSync(
                    from: source, into: URL(fileURLWithPath: directory), move: move,
                    expectedIdentity: expectedIdentities?[path], authorizedRoot: authorizedRoot
                )
                switch outcome {
                case .copied(let destination):
                    result.copied.append(destination)
                case .moved(let destination):
                    result.moved.append((path, destination))
                case .copiedWithoutRemoval(let destination, let retainedAt):
                    result.copied.append(destination)
                    result.copiedWithoutRemoval.append((path, destination, retainedAt))
                    result.failures.append(
                        "Copied \(path) to \(destination), but the source remains at \(retainedAt)."
                    )
                case .unchanged: break
                }
            } catch {
                result.failures.append("\(source.path): \(error.localizedDescription)")
            }
        }
        return result
    }

    @concurrent func transferLocalFile(
        from source: String, into directory: String, move: Bool,
        expectedIdentity: LocalFileIdentity? = nil, authorizedRoot: String? = nil
    ) async throws -> LocalFileTransferOutcome {
        try Self.transferLocalSync(
            from: URL(fileURLWithPath: source), into: URL(fileURLWithPath: directory),
            move: move, expectedIdentity: expectedIdentity, authorizedRoot: authorizedRoot
        )
    }

    private static func transferLocalSync(
        from source: URL, into directory: URL, move: Bool,
        expectedIdentity: LocalFileIdentity?, authorizedRoot: String?
    ) throws -> LocalFileTransferOutcome {
        guard source.isFileURL, source.host == nil || source.host == "localhost" else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let original = source.standardizedFileURL
        let parent = original.deletingLastPathComponent().resolvingSymlinksInPath()
        let physicalSource = parent.appendingPathComponent(original.lastPathComponent)
        guard let identity = LocalFileIdentity.read(physicalSource.path) else {
            throw WorkspaceError.notFound
        }
        guard expectedIdentity == nil || expectedIdentity == identity else {
            throw WorkspaceError.changedExternally
        }
        let type = identity.mode & UInt16(S_IFMT)
        guard type == UInt16(S_IFREG) || type == UInt16(S_IFDIR) || type == UInt16(S_IFLNK) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
        }
        let target = directory.standardizedFileURL.resolvingSymlinksInPath()
        if let authorizedRoot {
            // The caller already pinned a physical root. Never resolve it again:
            // otherwise a replaced root symlink could redefine the authorization.
            let pinnedRoot = URL(fileURLWithPath: authorizedRoot).standardizedFileURL.path
            guard LocalPathScope.contains(target.path, in: pinnedRoot) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw WorkspaceError.notFound }
        if type == UInt16(S_IFDIR), LocalPathScope.contains(target.path, in: physicalSource.path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        if parent.path == target.path {
            if move { return .unchanged }
            let name = original.lastPathComponent
            let ext = (name as NSString).pathExtension
            let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
            let extensionSuffix = ext.isEmpty ? "" : "." + ext
            let allowed = pathconf(target.path, _PC_NAME_MAX)
            let maxNameBytes = allowed > 0 ? Int(allowed) : 255
            for number in 1...Int.max {
                let suffix = number == 1 ? " copy" : " copy \(number)"
                let budget = maxNameBytes - suffix.utf8.count - extensionSuffix.utf8.count
                guard budget > 0 else { throw CocoaError(.fileWriteInvalidFileName) }
                var truncatedStem = stem
                while truncatedStem.utf8.count > budget { truncatedStem.removeLast() }
                let candidate = target.appendingPathComponent(
                    truncatedStem + suffix + extensionSuffix
                )
                var existing = Darwin.stat()
                if lstat(candidate.path, &existing) == 0 { continue }
                do {
                    try copyExclusive(from: physicalSource, to: candidate)
                    return .copied(candidate.path)
                } catch {
                    if lstat(candidate.path, &existing) == 0 { continue }
                    throw error
                }
            }
            throw CocoaError(.fileWriteFileExists)
        }
        let destination = target.appendingPathComponent(original.lastPathComponent)
        if move {
            return try moveExclusive(from: physicalSource, to: destination, identity: identity)
        }
        try copyExclusive(from: physicalSource, to: destination)
        return .copied(destination.path)
    }

    private struct FileSnapshotEntry: Equatable {
        let kind: UInt16
        let permissions: UInt16
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let checksum: String?
        let linkDestination: String?
        let attributes: [String: Data]
    }

    /// Read only real directory entries. Symlinks never expand into other trees.
    private static func fileSnapshot(_ root: URL) throws -> [String: FileSnapshotEntry] {
        var entries: [String: FileSnapshotEntry] = [:]
        func walk(_ relative: String) throws {
            try Task.checkCancellation()
            let path = relative.isEmpty ? root.path :
                (root.path as NSString).appendingPathComponent(relative)
            guard let entry = LocalFileIdentity.read(path) else { throw WorkspaceError.changedExternally }
            let kind = entry.mode & UInt16(S_IFMT)
            guard kind == UInt16(S_IFREG) || kind == UInt16(S_IFDIR) || kind == UInt16(S_IFLNK) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
            }
            var checksum: String?
            var link: String?
            if kind == UInt16(S_IFREG) {
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? file.close() }
                var digest = SHA256()
                while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
                    try Task.checkCancellation()
                    digest.update(data: bytes)
                }
                checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
            } else if kind == UInt16(S_IFLNK) {
                link = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            }
            entries[relative] = FileSnapshotEntry(
                kind: kind, permissions: entry.mode & 0o7777,
                size: kind == UInt16(S_IFREG) ? entry.size : 0,
                modifiedSeconds: entry.modifiedSeconds,
                modifiedNanoseconds: entry.modifiedNanoseconds,
                checksum: checksum, linkDestination: link,
                attributes: try extendedAttributes(of: path)
            )
            if kind == UInt16(S_IFDIR) {
                for child in try FileManager.default.contentsOfDirectory(atPath: path).sorted() {
                    try walk(relative.isEmpty ? child : relative + "/" + child)
                }
            }
        }
        try walk("")
        return entries
    }

    private static func extendedAttributes(of path: String) throws -> [String: Data] {
        let size = path.withCString { listxattr($0, nil, 0, XATTR_NOFOLLOW) }
        guard size >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard size > 0 else { return [:] }
        var buffer = [CChar](repeating: 0, count: Int(size))
        let read = buffer.withUnsafeMutableBufferPointer { pointer in
            path.withCString { listxattr($0, pointer.baseAddress, size_t(size), XATTR_NOFOLLOW) }
        }
        guard read == size else { throw WorkspaceError.changedExternally }
        let names = buffer.split(separator: 0).map {
            String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        var result: [String: Data] = [:]
        for name in names {
            let count = path.withCString { pathPointer in
                name.withCString { namePointer in
                    getxattr(pathPointer, namePointer, nil, 0, 0, XATTR_NOFOLLOW)
                }
            }
            guard count >= 0 else { throw WorkspaceError.changedExternally }
            var data = [UInt8](repeating: 0, count: Int(count))
            let actual = data.withUnsafeMutableBufferPointer { bytes in
                path.withCString { pathPointer in
                    name.withCString { namePointer in
                        getxattr(pathPointer, namePointer, bytes.baseAddress, count, 0, XATTR_NOFOLLOW)
                    }
                }
            }
            guard actual == count else { throw WorkspaceError.changedExternally }
            result[name] = Data(data)
        }
        return result
    }

    private static func exclusiveRename(from source: URL, to destination: URL) -> Int32 {
        source.path.withCString { from in
            destination.path.withCString { to in
                renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
    }

    private static func moveExclusive(
        from source: URL, to destination: URL, identity: LocalFileIdentity
    ) throws -> LocalFileTransferOutcome {
        guard LocalFileIdentity.read(source.path) == identity else {
            throw WorkspaceError.changedExternally
        }
        if exclusiveRename(from: source, to: destination) == 0 {
            guard let moved = LocalFileIdentity.read(destination.path),
                  moved.refersToSameEntry(as: identity) else {
                _ = exclusiveRename(from: destination, to: source)
                throw WorkspaceError.changedExternally
            }
            return .moved(destination.path)
        }
        let reason = errno
        guard reason == EXDEV else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(reason))
        }

        let sourceSnapshot = try fileSnapshot(source)
        try copyExclusive(from: source, to: destination)
        // A different disk cannot preserve the source inode; verify bytes, links and metadata.
        guard LocalFileIdentity.read(source.path) == identity,
              try fileSnapshot(source) == sourceSnapshot,
              try fileSnapshot(destination) == sourceSnapshot else {
            return .copiedWithoutRemoval(destination: destination.path, retainedAt: source.path)
        }

        // Move the original entry to a private name on its own volume before
        // removing it; a substituted path can never be mistaken for the copied source.
        let holding = source.deletingLastPathComponent()
            .appendingPathComponent(".bailey-move-" + UUID().uuidString)
        guard exclusiveRename(from: source, to: holding) == 0 else {
            return .copiedWithoutRemoval(destination: destination.path, retainedAt: source.path)
        }
        func retainedLocation() -> String {
            exclusiveRename(from: holding, to: source) == 0 ? source.path : holding.path
        }
        guard let held = LocalFileIdentity.read(holding.path),
              held.refersToSameEntry(as: identity),
              (try? fileSnapshot(holding)) == sourceSnapshot else {
            return .copiedWithoutRemoval(
                destination: destination.path, retainedAt: retainedLocation()
            )
        }
        let type = held.mode & UInt16(S_IFMT)
        if type == UInt16(S_IFDIR) {
            // Trash uses a directory move, not a potentially partial recursive delete.
            do {
                try FileManager.default.trashItem(at: holding, resultingItemURL: nil)
            } catch {
                return .copiedWithoutRemoval(
                    destination: destination.path, retainedAt: retainedLocation()
                )
            }
        } else if unlink(holding.path) != 0 {
            return .copiedWithoutRemoval(
                destination: destination.path, retainedAt: retainedLocation()
            )
        }
        return .moved(destination.path)
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
        // Verify bytes, links and supported metadata before publishing the staged entry.
        let originalContents = try fileSnapshot(source)
        let stagingDirectory = try fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: parent, create: true
        )
        defer { try? fm.removeItem(at: stagingDirectory) }
        let staged = stagingDirectory.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: staged)
        guard try fileSnapshot(staged) == originalContents,
              try fileSnapshot(source) == originalContents else {
            throw WorkspaceError.changedExternally
        }
        let status = exclusiveRename(from: staged, to: destination)
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
