import Darwin
import Foundation

/// A comparison belongs to one failed save, not a reusable permission to write.
nonisolated struct WorkspaceSaveFailure {
    struct Conflict: Equatable, Sendable {
        let id = UUID()
        let encoding: TextFileEncoding?
    }

    private var latest: String?
    private var recoveries: [DisplacedSaveError] = []
    private(set) var conflict: Conflict?

    var message: String? {
        get {
            let messages = [latest].compactMap { $0 } + recoveries.map(\.localizedDescription)
            return messages.isEmpty ? nil : messages.joined(separator: "\n")
        }
        set {
            latest = newValue
            conflict = nil
            if newValue == nil { recoveries.removeAll() }
        }
    }

    mutating func record(_ error: Error, message: String, encoding: TextFileEncoding? = nil) {
        let isConflict: Bool
        switch error {
        case WorkspaceError.changedExternally, is DisplacedSaveError:
            isConflict = true
        default:
            let system = error as NSError
            isConflict = (system.domain == NSCocoaErrorDomain && system.code == CocoaError.fileWriteFileExists.rawValue)
                || (system.domain == NSPOSIXErrorDomain && system.code == Int(EEXIST))
        }
        conflict = isConflict ? Conflict(encoding: encoding) : nil
        if let recovery = error as? DisplacedSaveError {
            if !recoveries.contains(recovery) { recoveries.append(recovery) }
            latest = nil
        } else {
            latest = message
        }
    }
}

/// Immutable review of the exact bytes the user is being asked to replace.
/// The caller still uses the existing conditional write and save queue.
nonisolated struct WorkspaceSaveConflict: Sendable {
    struct Context: Equatable, Sendable {
        let owner: UUID
        let generation: UInt
        let failure: WorkspaceSaveFailure.Conflict
        let path: String
        let baseline: WorkspaceFileVersion?
    }

    let context: Context
    let diskVersion: WorkspaceFileVersion
    let draftVersion: WorkspaceFileVersion
    let diskEncoding: String
    let draftEncoding: String
    let review: DiffSideDocument

    func authorizes(context current: Context?, draft: WorkspaceFileVersion) -> Bool {
        context == current && draftVersion == draft
    }

    @concurrent static func text(context: Context, backend: WorkspaceBackend, draft: String,
                                 encoding: TextFileEncoding, preferred: TextFileEncoding?,
                                 maxBytes: Int) async throws -> Self {
        let chosen = context.failure.encoding ?? encoding
        let payload = try await TextFileEncoding.prepareSave(draft, as: chosen, path: context.path,
                                                              checkDeclaration: chosen != encoding).get()
        guard payload.bytes.count <= maxBytes else { throw WorkspaceError.tooLarge }
        let bytes = try await backend.read(path: context.path, maxBytes: maxBytes)
        let decoded = await TextFileEncoding.decode(bytes, path: context.path, backend: backend, override: preferred)
        let disk: TextFileEncoding.Document
        switch decoded {
        case .success(let document) where document.encoding.encoded(document.text) == bytes:
            disk = document
        default:
            disk = try await TextFileEncoding.decode(bytes, path: context.path, backend: backend,
                                                     override: preferred == nil ? encoding : nil).get()
            guard disk.encoding.encoded(disk.text) == bytes else { throw CocoaError(.fileReadCorruptFile) }
        }
        return try compare(context: context, disk: bytes, diskText: disk.text, diskEncoding: disk.encoding.name,
                           draft: payload.version, draftText: draft, draftEncoding: chosen.name)
    }

    @concurrent static func annotations(context: Context, image: String, backend: WorkspaceBackend,
                                        version: WorkspaceFileVersion, size: CGSize,
                                        draft: ImageAnnotationState) async throws -> Self {
        try await ImageAnnotationSidecar.verifySource(image, backend: backend, version: version)
        guard let info = try await backend.stat(path: context.path), info.isRegular, !info.isSymlink else {
            throw WorkspaceError.changedExternally
        }
        let bytes = try await backend.read(path: context.path, maxBytes: ImageAnnotationSidecar.maximumBytes)
        _ = try ImageAnnotationSidecar.decode(bytes, version: version, size: size)
        let payload = try await ImageAnnotationSidecar.encode(draft, version: version, size: size)
        func pretty(_ data: Data) throws -> String {
            let object = try JSONSerialization.jsonObject(with: data)
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        }
        return try compare(context: context, disk: bytes, diskText: pretty(bytes), diskEncoding: "JSON",
                           draft: WorkspaceFileVersion(data: payload), draftText: pretty(payload), draftEncoding: "JSON")
    }

    private static func compare(context: Context, disk: Data, diskText: String, diskEncoding: String,
                                draft: WorkspaceFileVersion, draftText: String, draftEncoding: String) throws -> Self {
        // The byte cap alone permits tens of millions of empty lines. Bound
        // the native row model before allocating either diff's line arrays.
        var rows = 2
        for text in [diskText, draftText] {
            for byte in text.utf8 where byte == 10 {
                rows += 1
                guard rows <= 500_000 else { throw WorkspaceError.tooLarge }
                if rows.isMultiple(of: 4096) { try Task.checkCancellation() }
            }
        }
        guard let core = DiffCore.computeIfActive(oldText: diskText, newText: draftText, cancellation: { Task.isCancelled }) else {
            throw CancellationError()
        }
        let review = DiffComputation.unifiedReview(core: core)
        try Task.checkCancellation()
        return Self(context: context, diskVersion: WorkspaceFileVersion(data: disk), draftVersion: draft,
                    diskEncoding: diskEncoding, draftEncoding: draftEncoding, review: review)
    }
}
