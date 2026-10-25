import CoreServices
import Foundation

/// Native recursive change notifications for a local checkout and its Git metadata.
/// Files also needs paths and loss flags; Git keeps its existing change-only callback.
nonisolated final class GitFileEventWatcher {
    struct Event: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
    }

    private nonisolated final class Listener: Sendable {
        let notify: @Sendable ([Event]) -> Void

        init(_ notify: @escaping @Sendable ([Event]) -> Void) {
            self.notify = notify
        }
    }

    private let listener: Listener
    private let queue = DispatchQueue(label: "chiimagnus.bailey.git.file-events", qos: .utility)
    private let stream: FSEventStreamRef

    convenience init?(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.init(paths: paths, fileEvents: false, onEvents: { _ in onChange() })
    }

    convenience init?(paths: [String], onEvents: @escaping @Sendable ([Event]) -> Void) {
        self.init(paths: paths, fileEvents: true, onEvents: onEvents)
    }

    private init?(
        paths: [String], fileEvents: Bool, onEvents: @escaping @Sendable ([Event]) -> Void
    ) {
        guard !paths.isEmpty else { return nil }
        let listener = Listener(onEvents)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(listener).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard count > 0, let info else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue()
            var events: [Event] = []
            events.reserveCapacity(count)
            for index in 0..<min(count, CFArrayGetCount(paths)) {
                let path = unsafeBitCast(CFArrayGetValueAtIndex(paths, index), to: CFString.self)
                events.append(Event(path: path as String, flags: rawFlags[index]))
            }
            if !events.isEmpty {
                Unmanaged<Listener>.fromOpaque(info).takeUnretainedValue().notify(events)
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes |
            (fileEvents ? kFSEventStreamCreateFlagFileEvents : 0)
        )
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.listener = listener
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // The context does not retain the listener; finish queued callbacks first.
        queue.sync {}
    }

    static func paths(
        root: String, gitDirectory: String?, worktrees: [String] = []
    ) -> [String] {
        var candidates = [root] + worktrees
        if let gitDirectory { candidates += gitMetadataDirectories(gitDirectory) }
        let filesystem = FileManager.default
        var paths: [String] = []
        for path in candidates.map({ ($0 as NSString).standardizingPath })
            .sorted(by: { $0.count < $1.count }) {
            var isDirectory: ObjCBool = false
            guard filesystem.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
            else { continue }
            paths.append(path)
        }
        return paths
    }

    static func gitMetadataDirectories(_ gitDirectory: String) -> [String] {
        var paths = [gitDirectory]
        let commonDirFile = URL(fileURLWithPath: gitDirectory, isDirectory: true)
            .appendingPathComponent("commondir")
        if let relative = try? String(contentsOf: commonDirFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !relative.isEmpty {
            paths.append(URL(fileURLWithPath: relative,
                             relativeTo: commonDirFile.deletingLastPathComponent())
                .standardizedFileURL.path)
        }
        return paths
    }
}
