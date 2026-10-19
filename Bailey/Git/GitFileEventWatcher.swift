import CoreServices
import Foundation

/// Native recursive change notifications for a local checkout and its Git metadata.
nonisolated final class GitFileEventWatcher {
    private nonisolated final class Listener: Sendable {
        let notify: @Sendable () -> Void

        init(_ notify: @escaping @Sendable () -> Void) {
            self.notify = notify
        }
    }

    private let listener: Listener
    private let queue = DispatchQueue(label: "chiimagnus.bailey.git.file-events", qos: .utility)
    private let stream: FSEventStreamRef

    init?(paths: [String], onChange: @escaping @Sendable () -> Void) {
        guard !paths.isEmpty else { return nil }
        let listener = Listener(onChange)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(listener).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, _, _, _ in
            guard count > 0, let info else { return }
            Unmanaged<Listener>.fromOpaque(info).takeUnretainedValue().notify()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
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
        if let gitDirectory {
            candidates.append(gitDirectory)
            let commonDirFile = URL(fileURLWithPath: gitDirectory, isDirectory: true)
                .appendingPathComponent("commondir")
            if let relative = try? String(contentsOf: commonDirFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !relative.isEmpty {
                candidates.append(
                    URL(fileURLWithPath: relative, relativeTo: commonDirFile.deletingLastPathComponent())
                        .standardizedFileURL.path
                )
            }
        }
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
}
