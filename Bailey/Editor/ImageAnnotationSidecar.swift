import CoreGraphics
import Foundation
import Darwin

/// JSON is a separate editable document. The image is never rewritten.
nonisolated enum ImageAnnotationSidecar {
    static let suffix = ".bailey-annotations.json"
    static let maximumBytes = 16 << 20

    struct Record: Codable, Sendable {
        let schema: Int
        let sourceSHA256: String
        let sourceBytes: Int
        let pixelSize: CGSize
        let annotations: ImageAnnotationState
    }

    enum Loaded: Sendable, Equatable {
        case missing
        case existing(ImageAnnotationState, WorkspaceFileVersion)
        case unavailable(String)
    }

    static func path(for image: String) -> String { image + suffix }

    @concurrent static func load(image: String, backend: WorkspaceBackend,
                                 version: WorkspaceFileVersion, size: CGSize) async -> Loaded {
        do {
            guard let source = try await backend.stat(path: image), source.isRegular, !source.isSymlink else {
                throw CocoaError(.fileReadNoPermission)
            }
            let target = path(for: image)
            guard let info = try await backend.stat(path: target) else {
                // stat may follow a dangling symbolic link.
                guard try await backend.readSymlinkDestination(path: target) == nil else {
                    throw CocoaError(.fileReadNoPermission)
                }
                return .missing
            }
            guard info.isRegular, !info.isSymlink, info.size <= maximumBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let bytes = try await backend.read(path: target, maxBytes: maximumBytes)
            try Task.checkCancellation()
            let state = try decode(bytes, version: version, size: size)
            return .existing(state, WorkspaceFileVersion(data: bytes))
        } catch {
            return .unavailable(String(localized: "Image annotations could not be loaded. The original image is unchanged.", table: "Editor"))
        }
    }

    static func decode(_ data: Data, version: WorkspaceFileVersion, size: CGSize) throws -> ImageAnnotationState {
        guard data.count <= maximumBytes else { throw WorkspaceError.tooLarge }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.schema == 1, record.sourceSHA256 == version.sha256,
              record.sourceBytes == version.byteCount, record.pixelSize == size else {
            throw WorkspaceError.changedExternally
        }
        return try record.annotations.validated(in: size)
    }

    @concurrent static func encode(_ state: ImageAnnotationState, version: WorkspaceFileVersion, size: CGSize) async throws -> Data {
        try Task.checkCancellation()
        let record = Record(schema: 1, sourceSHA256: version.sha256, sourceBytes: version.byteCount,
                            pixelSize: size, annotations: try state.validated(in: size))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(record)
        guard bytes.count <= maximumBytes else { throw WorkspaceError.tooLarge }
        return bytes
    }

    @concurrent static func verifySource(_ path: String, backend: WorkspaceBackend,
                                         version: WorkspaceFileVersion) async throws {
        guard let info = try await backend.stat(path: path), info.isRegular,
              !info.isSymlink, info.size == version.byteCount else {
            throw WorkspaceError.changedExternally
        }
        let bytes = try await backend.read(path: path, maxBytes: version.byteCount)
        try Task.checkCancellation()
        guard version.matches(bytes) else { throw WorkspaceError.changedExternally }
    }

    @concurrent static func confirmsPublication(image: String, backend: WorkspaceBackend,
                                                version: WorkspaceFileVersion,
                                                written: WorkspaceFileVersion) async throws -> Bool {
        let target = path(for: image)
        guard let info = try await backend.stat(path: target), info.isRegular,
              !info.isSymlink, info.size == written.byteCount else { return false }
        let bytes: Data
        do {
            bytes = try await backend.read(path: target, maxBytes: written.byteCount)
        } catch WorkspaceError.notFound {
            return false
        } catch WorkspaceError.tooLarge {
            return false
        }
        try Task.checkCancellation()
        guard written.matches(bytes) else { return false }
        try await verifySource(image, backend: backend, version: version)
        return true
    }

    @concurrent static func publish(_ data: Data, image: String, backend: WorkspaceBackend,
                                    version: WorkspaceFileVersion, previous: WorkspaceFileVersion?) async throws {
        let target = path(for: image)
        try await verifySource(image, backend: backend, version: version)
        try Task.checkCancellation()
        do {
            if let previous {
                guard let info = try await backend.stat(path: target), info.isRegular, !info.isSymlink else {
                    throw WorkspaceError.changedExternally
                }
                try await backend.write(path: target, data: data, ifUnchanged: previous)
            } else if let local = backend as? LocalWorkspaceBackend {
                try await local.writeNewFile(path: target, data: data)
            } else if let remote = backend as? SSHWorkspaceBackend {
                try await remote.writeNewFile(path: target, data: data)
            } else {
                // The backend's exclusive copy is the publication boundary.
                // A random private sibling owns the only temporary bytes.
                let parent = (target as NSString).deletingLastPathComponent
                let stage = (parent as NSString).appendingPathComponent(".bailey-annotations-" + UUID().uuidString)
                try await backend.createDirectory(path: stage)
                do {
                    let item = (stage as NSString).appendingPathComponent("item")
                    try await backend.write(path: item, data: data)
                    try await verifySource(image, backend: backend, version: version)
                    try Task.checkCancellation()
                    try await backend.copy(from: item, to: target)
                } catch {
                    // Cleanup uses the same machine; it must never delete the destination.
                    _ = await Task.detached { try? await backend.delete(paths: [stage]) }.value
                    throw error
                }
                _ = await Task.detached { try? await backend.delete(paths: [stage]) }.value
            }
            // A different source must not make this revision look saved.
            try await verifySource(image, backend: backend, version: version)
        } catch {
            guard WorkspaceError.publicationUncertain(error) else { throw error }
            let publicationError = error
            // Read back the exact attempted bytes; never retry a mutation
            // whose result is unknown. A failed read leaves it unresolved.
            let confirmed: Bool
            do {
                confirmed = try await confirmsPublication(
                    image: image, backend: backend, version: version,
                    written: WorkspaceFileVersion(data: data))
            } catch WorkspaceError.changedExternally {
                throw WorkspaceError.changedExternally
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw publicationError
            }
            guard confirmed else { throw publicationError }
        }
    }

    /// Two separate directory entries cannot be moved/deleted atomically.
    /// Refuse direct operations on either half of an existing pair; the
    /// containing directory can still be transferred as one tree.
    @concurrent static func requireUnpaired(_ path: String, backend: WorkspaceBackend) async throws {
        if backend is LocalWorkspaceBackend {
            try requireUnpairedLocal(path)
            return
        }
        let other = counterpart(of: path)
        guard try await backend.stat(path: other) == nil,
              try await backend.readSymlinkDestination(path: other) == nil else {
            throw pairedOperationError
        }
    }

    static func requireUnpairedLocal(_ path: String) throws {
        let other = counterpart(of: path)
        var entry = stat()
        if lstat(other, &entry) == 0 { throw pairedOperationError }
        guard errno == ENOENT || errno == ENOTDIR || errno == ENAMETOOLONG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func counterpart(of path: String) -> String {
        path.hasSuffix(suffix) ? String(path.dropLast(suffix.count)) : Self.path(for: path)
    }

    private static var pairedOperationError: NSError {
        NSError(domain: "Bailey.ImageAnnotations", code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "This image and its annotations must stay together. Move, copy, rename or delete their containing folder instead.", table: "Editor")
        ])
    }
}
