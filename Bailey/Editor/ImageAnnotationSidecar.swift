import CoreGraphics
import ImageIO
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

    /// Selecting the image implies its saved annotation; selecting both must not operate twice.
    static func coalescedSelection(_ paths: [String]) -> [String] {
        let selected = Set(paths)
        return paths.filter { !$0.hasSuffix(suffix) || !selected.contains(counterpart(of: $0)) }
    }

    static func protectedPaths(_ paths: [String]) -> [String] {
        Array(Set(paths + paths.filter { !$0.hasSuffix(suffix) }.map { path(for: $0) }))
    }

    @concurrent static func entryExists(_ path: String, backend: WorkspaceBackend) async throws -> Bool {
        if backend is LocalWorkspaceBackend {
            var info = stat()
            if lstat(path, &info) == 0 { return true }
            guard errno == ENOENT || errno == ENOTDIR || errno == ENAMETOOLONG else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return false
        }
        if try await backend.stat(path: path) != nil { return true }
        return try await backend.readSymlinkDestination(path: path) != nil
    }

    /// Trust a pair only when the sidecar decodes against the actual image bytes and dimensions.
    @concurrent static func pair(at image: String, backend: WorkspaceBackend) async throws -> Pair? {
        guard try await entryExists(counterpart(of: image), backend: backend) else { return nil }
        guard !image.hasSuffix(suffix), let info = try await backend.stat(path: image),
              info.isRegular, !info.isSymlink, info.size <= FileTab.maxImageBytes else {
            throw pairedOperationError
        }
        let bytes = try await backend.read(path: image, maxBytes: FileTab.maxImageBytes)
        guard let source = try RasterPreview.source(bytes), RasterPreview.gifFrameCount(source) <= 1,
              let size = RasterPreview.pixelSize(source, at: 0) else { throw pairedOperationError }
        let version = WorkspaceFileVersion(data: bytes)
        let loaded = await load(image: image, backend: backend, version: version, size: size)
        try Task.checkCancellation()
        guard case .existing(_, let annotation) = loaded else { throw pairedOperationError }
        let pair = Pair(image: image, version: version, annotation: annotation)
        try await pair.verify(at: image, backend: backend)
        return pair
    }

    struct Pair: Sendable {
        let image: String
        let version: WorkspaceFileVersion
        let annotation: WorkspaceFileVersion

        @concurrent func verify(at image: String, backend: WorkspaceBackend) async throws {
            try await verifySource(image, backend: backend, version: version)
            try await verifySource(path(for: image), backend: backend, version: annotation)
        }

        @concurrent private func checkDestination(_ destination: String, backend: WorkspaceBackend,
                                                  moving: Bool) async throws {
            guard !destination.hasSuffix(suffix), destination != image else {
                throw CocoaError(.fileWriteFileExists)
            }
            for (source, target) in [(image, destination), (path(for: image), path(for: destination))] {
                guard try await entryExists(target, backend: backend) else { continue }
                // A case-only rename is valid only for the same directory entry.
                guard moving, source.lowercased() == target.lowercased() else {
                    throw CocoaError(.fileWriteFileExists)
                }
                if backend is LocalWorkspaceBackend {
                    guard let old = LocalFileIdentity.read(source), let new = LocalFileIdentity.read(target),
                          old.refersToSameEntry(as: new) else { throw CocoaError(.fileWriteFileExists) }
                } else {
                    let same = try await backend.run(argv: ["test", source, "-ef", target], cwd: nil, env: nil,
                                                     stdin: nil, timeout: 25)
                    guard same.status == 0 else { throw CocoaError(.fileWriteFileExists) }
                }
            }
        }

        @concurrent func copy(to destination: String, backend: WorkspaceBackend) async throws {
            try await checkDestination(destination, backend: backend, moving: false)
            try await verify(at: image, backend: backend)
            do {
                try await backend.copy(from: image, to: destination)
                try await verify(at: image, backend: backend)
                try await backend.copy(from: path(for: image), to: path(for: destination))
                try await verify(at: destination, backend: backend)
            } catch {
                // Keep the originals; never erase a possibly substituted partial output.
                throw failure(error, source: image, destination: destination)
            }
        }

        @concurrent func move(to destination: String, backend: WorkspaceBackend) async throws {
            try await checkDestination(destination, backend: backend, moving: true)
            try await verify(at: image, backend: backend)
            if backend is LocalWorkspaceBackend,
               let source = LocalFileIdentity.read(image),
               let parent = LocalFileIdentity.read((destination as NSString).deletingLastPathComponent),
               source.device != parent.device {
                // Publish and verify both copies before removing either original.
                try await copy(to: destination, backend: backend)
                do { try await remove(backend: backend) }
                catch { throw failure(error, source: image, destination: destination) }
                return
            }
            let sourceSidecar = path(for: image)
            let destinationSidecar = path(for: destination)
            var movedAnnotation = false
            var attemptedImage = false
            var movedImage = false
            do {
                try await backend.rename(from: sourceSidecar, to: destinationSidecar)
                movedAnnotation = true
                try await verifySource(image, backend: backend, version: version)
                try await verifySource(destinationSidecar, backend: backend, version: annotation)
                attemptedImage = true
                try await backend.rename(from: image, to: destination)
                movedImage = true
                try await verify(at: destination, backend: backend)
            } catch {
                if movedAnnotation, !movedImage, !attemptedImage || !WorkspaceError.publicationUncertain(error) {
                    // A definite second-step failure can restore the first entry if both
                    // entries still match. Never overwrite a replacement at the old name.
                    let _ = await Task.detached {
                        do {
                            try await verifySource(image, backend: backend, version: version)
                            try await verifySource(destinationSidecar, backend: backend, version: annotation)
                            let occupied = try await entryExists(sourceSidecar, backend: backend)
                            if sourceSidecar.lowercased() == destinationSidecar.lowercased() || !occupied {
                                try await backend.rename(from: destinationSidecar, to: sourceSidecar)
                            }
                        } catch { /* Report both locations below for manual recovery. */ }
                    }.value
                }
                throw failure(error, source: image, destination: destination)
            }
        }

        @concurrent func remove(backend: WorkspaceBackend) async throws {
            try await verify(at: image, backend: backend)
            let parent = (image as NSString).deletingLastPathComponent
            let stage = (parent as NSString).appendingPathComponent("Bailey Image Recovery " + UUID().uuidString)
            let stored = (stage as NSString).appendingPathComponent((image as NSString).lastPathComponent)
            try await backend.createDirectory(path: stage)
            var staged = false
            do {
                try await move(to: stored, backend: backend)
                staged = true
                try await verify(at: stored, backend: backend)
                let entries = try await backend.list(directory: stage)
                guard Set(entries.map(\.name)) == Set([(stored as NSString).lastPathComponent,
                    (path(for: stored) as NSString).lastPathComponent]) else { throw WorkspaceError.changedExternally }
                // Local Trash retains the pair in one folder. Remote deletion uses the
                // existing explicitly confirmed permanent-delete semantics.
                try await backend.delete(paths: [stage])
            } catch {
                let canRestore = staged && !WorkspaceError.publicationUncertain(error)
                let _ = await Task.detached {
                    if canRestore {
                        // Restore a complete staged pair if the delete failed before removing it.
                        let stagedPair = Pair(image: stored, version: version, annotation: annotation)
                        try? await stagedPair.move(to: image, backend: backend)
                    }
                    if backend is LocalWorkspaceBackend { _ = rmdir(stage) }
                    else { _ = try? await backend.run(argv: ["rmdir", "--", stage], cwd: nil, env: nil, stdin: nil, timeout: 25) }
                }.value
                throw failure(error, source: image, destination: stored)
            }
        }

        private func failure(_ error: Error, source: String, destination: String) -> NSError {
            NSError(domain: "Bailey.ImageAnnotations", code: 2, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "The image and annotation operation did not finish. Check both locations before retrying.", table: "Editor")
                + "\n" + source + "\n" + destination + "\n" + error.localizedDescription])
        }
    }

    /// Unpaired operations must not accidentally split or overwrite a saved annotation pair.
    @concurrent static func requireUnpaired(_ path: String, backend: WorkspaceBackend) async throws {
        guard try await !entryExists(counterpart(of: path), backend: backend) else { throw pairedOperationError }
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
            NSLocalizedDescriptionKey: String(localized: "Select the original image to manage its annotations together. Invalid annotation pairs must be repaired first.", table: "Editor")
        ])
    }
}
