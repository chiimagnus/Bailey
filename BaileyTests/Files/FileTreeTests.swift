import AppKit
import CoreServices
import Darwin
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import Bailey

private actor CountingFileBackend: WorkspaceBackend {
    private(set) var requests: [String: Int] = [:]
    private(set) var lastBatch: [String]?
    private var unavailable = false
    private var delayedPath: String?
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var awaitingDirectory = false
    private let base = LocalWorkspaceBackend.shared
    private var beforeCopy: (@Sendable () throws -> Void)?

    func onNextCopy(_ action: @escaping @Sendable () throws -> Void) { beforeCopy = action }

    func setUnavailable(_ value: Bool) { unavailable = value }
    func delay(_ path: String) { delayedPath = path }
    func release() {
        gate?.resume()
        gate = nil
        awaitingDirectory = false
    }
    func list(directory: String) async throws -> [WorkspaceEntry] {
        requests[directory, default: 0] += 1
        if delayedPath == directory {
            delayedPath = nil
            awaitingDirectory = true
            await withCheckedContinuation { gate = $0 }
        }
        if unavailable { throw WorkspaceError.timedOut }
        return try await base.list(directory: directory)
    }
    func list(directories: [String]) async -> [String: [WorkspaceEntry]] {
        lastBatch = directories
        var result: [String: [WorkspaceEntry]] = [:]
        for directory in directories {
            result[directory] = try? await list(directory: directory)
        }
        return result
    }
    func stat(path: String) async throws -> WorkspaceStat? { try await base.stat(path: path) }
    func readSymlinkDestination(path: String) async throws -> String? { try await base.readSymlinkDestination(path: path) }
    func read(path: String, maxBytes: Int) async throws -> Data { try await base.read(path: path, maxBytes: maxBytes) }
    func write(path: String, data: Data) async throws { try await base.write(path: path, data: data) }
    func createFile(path: String) async throws { try await base.createFile(path: path) }
    func createDirectory(path: String) async throws { try await base.createDirectory(path: path) }
    func copy(from: String, to: String) async throws {
        if let hook = beforeCopy {
            beforeCopy = nil
            try hook()
        }
        try await base.copy(from: from, to: to)
    }
    func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    func delete(paths: [String]) async throws { try await base.delete(paths: paths) }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        try await base.run(argv: argv, cwd: cwd, env: env, stdin: stdin, timeout: timeout)
    }
}

@MainActor
@Observable
private final class FileTreeTargetGate {
    var ready = false
}

@MainActor
final class FileTreeTests: XCTestCase {
    private func waitForCondition(
        _ description: String,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(description)
    }

    func testFailedDirectoryRefreshReportsFailureWithoutDiscardingTrustedRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        let added = root.appendingPathComponent("added.txt")
        try Data("old".utf8).write(to: original)
        let backend = CountingFileBackend()
        let tree = FileTreeModel()

        let initial = await tree.sync(root: root.path, backend: backend)
        XCTAssertTrue(initial)
        XCTAssertTrue(tree.items.contains { $0.path == original.path })

        try Data("new".utf8).write(to: added)
        await backend.setUnavailable(true)
        let failed = await tree.sync(root: root.path, backend: backend)
        XCTAssertFalse(failed, "A missing remote batch response must restore watcher fallback polling")
        XCTAssertTrue(tree.items.contains { $0.path == original.path })
        XCTAssertFalse(tree.items.contains { $0.path == added.path })

        await backend.setUnavailable(false)
        let recovered = await tree.sync(root: root.path, backend: backend)
        XCTAssertTrue(recovered)
        XCTAssertTrue(tree.items.contains { $0.path == added.path })
    }

    func testLocalFileEventsRefreshRealDiskChangesWithoutIdleListing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        tree.setLocalFileEventsEnabled(true)
        defer { tree.setLocalFileEventsEnabled(false) }
        await tree.sync(root: root.path, backend: backend)

        let file = root.appendingPathComponent("外部 文件.swift")
        try Data("hello".utf8).write(to: file)
        try await waitForCondition("External create must update the tree without a polling call") {
            tree.items.contains { $0.path == file.path }
        }
        let createdRevision = tree.contentRevision
        let createdReadCount = await backend.requests[root.path, default: 0]
        try await Task.sleep(for: .seconds(10.2))
        let idleReadCount = await backend.requests[root.path, default: 0]
        XCTAssertEqual(idleReadCount, createdReadCount, "Idle local Files must not query directories")

        try FileManager.default.removeItem(at: file)
        try await waitForCondition("External delete must remove the real disk entry") {
            !tree.items.contains { $0.path == file.path }
        }
        XCTAssertGreaterThan(tree.contentRevision, createdRevision)
    }

    func testNativeLocalWatcherObservesAtomicRetargetOfSymlinkedProjectRoot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        let linkParent = base.appendingPathComponent("links")
        let alias = linkParent.appendingPathComponent("project-link")
        let staged = linkParent.appendingPathComponent("staged-link")
        try FileManager.default.createDirectory(at: linkParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("old".utf8).write(to: first.appendingPathComponent("old.swift"))
        try Data("new".utf8).write(to: second.appendingPathComponent("new.swift"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let tree = FileTreeModel()
        let backend = CountingFileBackend()
        tree.setLocalFileEventsEnabled(true)
        defer { tree.setLocalFileEventsEnabled(false) }
        await tree.sync(root: alias.path, backend: backend)
        XCTAssertTrue(tree.items.contains { $0.path == alias.appendingPathComponent("old.swift").path })
        try await Task.sleep(for: .seconds(1.2)) // Quiesce initial registration/scan events.
        XCTAssertFalse(tree.items.contains { $0.path == alias.appendingPathComponent("new.swift").path })

        // Changing only the link's inode cannot generate an event inside its
        // previously resolved target. The watcher must also observe that link.
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: second)
        let renamed = staged.path.withCString { source in
            alias.path.withCString { destination in Darwin.rename(source, destination) }
        }
        XCTAssertEqual(renamed, 0)
        try await waitForCondition("Replacing a symlinked root must refresh to the new physical target") {
            tree.items.contains { $0.path == alias.appendingPathComponent("new.swift").path }
                && !tree.items.contains { $0.path == alias.appendingPathComponent("old.swift").path }
        }
        XCTAssertEqual(try String(contentsOf: alias.appendingPathComponent("new.swift"), encoding: .utf8),
                       "new")
        try Data().write(to: second.appendingPathComponent("after-rebinding.swift"))
        try await waitForCondition("After retargeting, the watcher must follow the new physical root") {
            tree.items.contains { $0.path == alias.appendingPathComponent("after-rebinding.swift").path }
        }
        try await Task.sleep(for: .milliseconds(700))
        let beforeUnrelatedEvent = await backend.requests[alias.path, default: 0]
        try Data().write(to: base.appendingPathComponent("unrelated-sibling.txt"))
        try await Task.sleep(for: .milliseconds(900))
        let afterUnrelatedEvent = await backend.requests[alias.path, default: 0]
        XCTAssertEqual(afterUnrelatedEvent, beforeUnrelatedEvent,
                       "Watching the link parent must not rescan Files for unrelated siblings")
        tree.setLocalFileEventsEnabled(false)
        try Data().write(to: second.appendingPathComponent("while-hidden.swift"))
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertFalse(tree.items.contains { $0.path == alias.appendingPathComponent("while-hidden.swift").path },
                       "A hidden symlinked root must release its parent watcher")
    }

    func testTopLevelRootSymlinksNeverWatchFilesystemRootRecursively() throws {
        for path in ["/tmp", "/var", "/etc"] {
            XCTAssertNil(FileTreeModel.watchedRootSymlinkPath(path),
                         "Top-level aliases cannot expand FSEvents to the entire filesystem")
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let actual = base.appendingPathComponent("real")
        let links = base.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let alias = links.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let watchPath = try XCTUnwrap(FileTreeModel.watchedRootSymlinkPath(alias.path))
        XCTAssertTrue(watchPath.hasSuffix("/links/alias"))
        XCTAssertNotEqual((watchPath as NSString).deletingLastPathComponent, "/")
    }

    func testContentOnlyLocalFileEventDoesNotEnumerateUnchangedParent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("content.swift")
        try Data("initial".utf8).write(to: file)
        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        let oldRows = tree.items
        let oldRevision = tree.contentRevision
        let before = await backend.requests[root.path, default: 0]
        try Data("edited".utf8).write(to: file)
        await tree.refreshForLocalEvents([
            .init(path: file.path, flags: UInt32(
                kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile
            ))
        ])
        let after = await backend.requests[root.path, default: 0]
        XCTAssertEqual(after, before, "File bytes changed, but its parent's filename listing did not")
        XCTAssertEqual(tree.items, oldRows)
        XCTAssertEqual(tree.contentRevision, oldRevision)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "edited")
    }

    func testNativeAtomicReplacementOfFileByDirectorySymlinkUpdatesItsRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let replaced = root.appendingPathComponent("replaced")
        let staged = root.appendingPathComponent("staged-link")
        try Data("original file".utf8).write(to: replaced)
        let tree = FileTreeModel()
        tree.setLocalFileEventsEnabled(true)
        defer { tree.setLocalFileEventsEnabled(false) }
        await tree.sync(root: root.path, backend: CountingFileBackend())
        XCTAssertFalse(try XCTUnwrap(tree.items.first { $0.path == replaced.path }).isDirectory)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: target)
        let status = staged.path.withCString { source in
            replaced.path.withCString { destination in Darwin.rename(source, destination) }
        }
        XCTAssertEqual(status, 0)
        try await waitForCondition("Atomic replacement of a file by a directory symlink must change the row") {
            tree.items.contains { $0.path == replaced.path && $0.isDirectory }
        }
    }

    func testNativeLocalEventsFollowSymlinkedProjectRoot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let physical = base.appendingPathComponent("actual")
        let alias = base.appendingPathComponent("project-link")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        defer { try? FileManager.default.removeItem(at: base) }
        let tree = FileTreeModel()
        tree.setLocalFileEventsEnabled(true)
        defer { tree.setLocalFileEventsEnabled(false) }
        await tree.sync(root: alias.path, backend: CountingFileBackend())

        let physicalFile = physical.appendingPathComponent("external.swift")
        try Data("test".utf8).write(to: physicalFile)
        let logicalFile = alias.appendingPathComponent("external.swift")
        try await waitForCondition("A symlinked project root must see its physical target") {
            tree.items.contains { $0.path == logicalFile.path }
        }
    }

    func testNativeLocalEventsRefreshExpandedExternalDirectorySymlink() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let physical = base.appendingPathComponent("outside")
        let root = base.appendingPathComponent("project")
        let alias = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        defer { try? FileManager.default.removeItem(at: base) }
        let tree = FileTreeModel()
        tree.setLocalFileEventsEnabled(true)
        defer { tree.setLocalFileEventsEnabled(false) }
        await tree.sync(root: root.path, backend: CountingFileBackend())
        let row = try XCTUnwrap(tree.items.first { $0.path == alias.path })
        await tree.toggle(row)
        try await Task.sleep(for: .milliseconds(800)) // Allow initial symlink setup events to drain.
        XCTAssertFalse(tree.items.contains { $0.path == alias.appendingPathComponent("external.swift").path })

        try Data().write(to: physical.appendingPathComponent("external.swift"))
        let logicalFile = alias.appendingPathComponent("external.swift")
        try await waitForCondition("An expanded link should follow changes in the viewed directory") {
            tree.items.contains { $0.path == logicalFile.path }
        }
    }

    func testNativeLocalEventsRefreshCompressedExternalDirectorySymlink() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("project")
        let outside = base.appendingPathComponent("outside")
        let nested = outside.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("a.swift"))
        try Data().write(to: nested.appendingPathComponent("b.swift"))
        let alias = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: base) }

        let tree = FileTreeModel()
        tree.setLocalFileEventsEnabled(true)
        defer { tree.setLocalFileEventsEnabled(false) }
        await tree.sync(root: root.path, backend: CountingFileBackend())
        let collapsed = try XCTUnwrap(tree.items.first { $0.path == alias.path })
        XCTAssertEqual(collapsed.displayName, "linked")
        await tree.toggle(collapsed)
        let child = try XCTUnwrap(tree.items.first {
            $0.path == alias.appendingPathComponent("child").path
        })
        XCTAssertEqual(child.displayName, "child")
        await tree.toggle(child)
        let compacted = try XCTUnwrap(tree.items.first)
        XCTAssertEqual(compacted.path, child.path)
        XCTAssertEqual(compacted.displayName, "linked / child")
        XCTAssertTrue(tree.hasVisibleDirectorySymlinks,
                      "Compacted symlink paths must preserve Windows fallback polling")
        try await Task.sleep(for: .milliseconds(800))

        try Data().write(to: outside.appendingPathComponent("new.txt"))
        try await waitForCondition("A collapsed external symlink must refresh its compacted row") {
            tree.items.contains { $0.path == alias.path && $0.displayName == "linked" }
        }
    }

    func testNativeLocalEventsSupportUnicodeAndNewlineFileNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + "-中文 café"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = FileTreeModel()
        tree.setLocalFileEventsEnabled(true)
        defer { tree.setLocalFileEventsEnabled(false) }
        await tree.sync(root: root.path, backend: CountingFileBackend())

        for name in ["e\u{301} filename.swift", "line\nwrapped.swift"] {
            let file = root.appendingPathComponent(name)
            try Data().write(to: file)
            try await waitForCondition("FSEvents must refresh a path with canonical Unicode or newlines") {
                tree.items.contains { $0.path == file.path }
            }
            try FileManager.default.removeItem(at: file)
            try await waitForCondition("Deleting unusual names must remove their displayed rows") {
                !tree.items.contains { $0.path == file.path }
            }
        }
    }

    func testNativeLocalWatcherRecoversAfterRootMoveWhenReopened() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("working")
        let moved = base.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let original = root.appendingPathComponent("original.swift")
        try Data().write(to: original)
        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        tree.setLocalFileEventsEnabled(true)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertTrue(tree.items.contains { $0.path == original.path })
        try FileManager.default.moveItem(at: root, to: moved)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(tree.items.contains { $0.path == original.path },
                      "A vanished root must not erase the previous verified snapshot")

        tree.setLocalFileEventsEnabled(false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let replacement = root.appendingPathComponent("replacement.swift")
        try Data().write(to: replacement)
        tree.setLocalFileEventsEnabled(true)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertTrue(tree.items.contains { $0.path == replacement.path },
                      "Reopening Files must reconcile the recreated root")
        XCTAssertFalse(tree.items.contains { $0.path == original.path },
                       "The moved-away root cannot override the replacement")
        tree.setLocalFileEventsEnabled(false)
    }

    func testNativeLocalEventsTrackMoveAcrossExpandedDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let left = root.appendingPathComponent("left")
        let right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = left.appendingPathComponent("before.swift")
        let moved = right.appendingPathComponent("after.swift")
        try Data("moved".utf8).write(to: old)
        let tree = FileTreeModel()
        tree.setLocalFileEventsEnabled(true)
        defer { tree.setLocalFileEventsEnabled(false) }
        await tree.sync(root: root.path, backend: CountingFileBackend())
        for directory in [left.path, right.path] {
            await tree.toggle(try XCTUnwrap(tree.items.first { $0.path == directory }))
        }
        try FileManager.default.moveItem(at: old, to: moved)
        try await waitForCondition("External move must refresh source and destination") {
            tree.items.contains { $0.path == moved.path }
                && !tree.items.contains { $0.path == old.path }
        }
    }

    func testNativeLocalWatcherReleasesOnDisableAndRootSwitch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        tree.setLocalFileEventsEnabled(true)
        await tree.sync(root: first.path, backend: backend)
        await tree.sync(root: second.path, backend: backend)

        let old = first.appendingPathComponent("old.swift")
        let current = second.appendingPathComponent("current.swift")
        try Data().write(to: old)
        try Data().write(to: current)
        try await waitForCondition("Only the new root must follow external changes") {
            tree.items.contains { $0.path == current.path }
        }
        XCTAssertFalse(tree.items.contains { $0.path == old.path })
        tree.setLocalFileEventsEnabled(false)
        let stopped = second.appendingPathComponent("stopped.swift")
        try Data().write(to: stopped)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertFalse(tree.items.contains { $0.path == stopped.path },
                       "A hidden Files panel must release its watcher")
        tree.setLocalFileEventsEnabled(true)
        await tree.sync(root: second.path, backend: backend)
        XCTAssertTrue(tree.items.contains { $0.path == stopped.path },
                      "Reactivation must reconcile changes missed while hidden")
        tree.setLocalFileEventsEnabled(false)
    }

    func testNativeLocalEventsCoalesceBurstAndConvergeToDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = FileTreeModel()
        let backend = CountingFileBackend()
        tree.setLocalFileEventsEnabled(true)
        defer { tree.setLocalFileEventsEnabled(false) }
        await tree.sync(root: root.path, backend: backend)
        for index in 0..<160 {
            try Data().write(to: root.appendingPathComponent("burst-\(index).txt"))
        }
        try await waitForCondition("A burst must converge to the real directory contents") {
            tree.items.filter { $0.name.hasPrefix("burst-") }.count == 160
        }
        let reads = await backend.requests[root.path, default: 0]
        XCTAssertLessThan(reads, 30, "One burst must not read the directory per FSEvent")
    }

    func testMustScanSubDirsWithoutRenameFlagDetectsMovedDirectoryFromParent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = root.appendingPathComponent("old")
        let renamed = root.appendingPathComponent("renamed")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data().write(to: old.appendingPathComponent("inside.swift"))
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        XCTAssertTrue(tree.items.contains { $0.path == old.path })

        try FileManager.default.moveItem(at: old, to: renamed)
        await tree.refreshForLocalEvents([
            .init(path: old.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        ])
        XCTAssertTrue(tree.items.contains { $0.path == renamed.path },
                      "A missing event batch must re-read the moved directory's parent")
        XCTAssertFalse(tree.items.contains { $0.path == old.path })
    }

    func testMustScanSubDirsRescansLoadedSubtreeWithoutQueryingSiblings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let branch = root.appendingPathComponent("branch")
        let nested = branch.appendingPathComponent("nested")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("one.swift"))
        try Data().write(to: nested.appendingPathComponent("two.swift"))
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        let branchRow = try XCTUnwrap(tree.items.first { $0.path == branch.path })
        await tree.toggle(branchRow)
        let nestedRow = try XCTUnwrap(tree.items.first { $0.path == nested.path })
        await tree.toggle(nestedRow)
        let siblingRow = try XCTUnwrap(tree.items.first { $0.path == other.path })
        await tree.toggle(siblingRow)
        let loaded = await backend.requests
        XCTAssertNotNil(loaded[nested.path])
        XCTAssertNotNil(loaded[other.path])

        try Data().write(to: branch.appendingPathComponent("new.swift"))
        await tree.refreshForLocalEvents([
            .init(path: branch.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        ])
        XCTAssertTrue(tree.items.contains { $0.path == branch.path },
                      "Subtree rescan must reproject a formerly compressed directory")
        let after = await backend.requests
        XCTAssertGreaterThan(after[branch.path, default: 0], loaded[branch.path, default: 0])
        XCTAssertGreaterThan(after[nested.path, default: 0], loaded[nested.path, default: 0])
        XCTAssertEqual(after[other.path], loaded[other.path],
                       "MustScanSubDirs must not requery an unaffected sibling")
        XCTAssertGreaterThan(after[root.path, default: 0], loaded[root.path, default: 0],
                             "A lost event may also hide the moved directory's old name")
    }

    func testLocalFileEventsRefreshOnlyAffectedCachedDirectoryAndRecoverDroppedEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        for directory in [first.path, second.path] {
            let item = try XCTUnwrap(tree.items.first { $0.path == directory })
            await tree.toggle(item)
        }
        let firstReads = await backend.requests[first.path, default: 0]
        let secondReads = await backend.requests[second.path, default: 0]
        let rootReads = await backend.requests[root.path, default: 0]
        let newFile = first.appendingPathComponent("new.swift")
        try Data().write(to: newFile)
        await tree.refreshForLocalEvents([
            .init(path: newFile.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        ])
        XCTAssertTrue(tree.items.contains { $0.path == newFile.path })
        let refreshedFirst = await backend.requests[first.path, default: 0]
        let untouchedSecond = await backend.requests[second.path, default: 0]
        let untouchedRoot = await backend.requests[root.path, default: 0]
        XCTAssertGreaterThan(refreshedFirst, firstReads)
        XCTAssertEqual(untouchedSecond, secondReads)
        XCTAssertEqual(untouchedRoot, rootReads)
        let revision = tree.contentRevision
        await tree.refreshForLocalEvents([
            .init(path: newFile.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        ])
        XCTAssertEqual(tree.contentRevision, revision, "The same disk snapshot must not republish")

        let missedFile = second.appendingPathComponent("missed.swift")
        try Data().write(to: missedFile)
        await tree.refreshForLocalEvents([
            .init(path: first.path, flags: UInt32(kFSEventStreamEventFlagKernelDropped))
        ])
        XCTAssertTrue(tree.items.contains { $0.path == missedFile.path },
                      "A dropped event must recheck every loaded directory")
        let recoveredReads = await backend.requests[second.path, default: 0]
        XCTAssertGreaterThan(recoveredReads, untouchedSecond)
    }

    func testLocalFileEventsRejectOldRootAndPreserveTrustworthyRowsWhenRootDisappears() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let oldFile = first.appendingPathComponent("old.swift")
        let currentFile = second.appendingPathComponent("current.swift")
        try Data().write(to: oldFile)
        try Data().write(to: currentFile)
        let tree = FileTreeModel()
        let backend = CountingFileBackend()
        await tree.sync(root: first.path, backend: backend)
        await tree.sync(root: second.path, backend: backend)
        await tree.refreshForLocalEvents([
            .init(path: oldFile.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved))
        ])
        XCTAssertTrue(tree.items.contains { $0.path == currentFile.path })
        XCTAssertFalse(tree.items.contains { $0.path == oldFile.path })

        try FileManager.default.removeItem(at: second)
        await tree.refreshForLocalEvents([
            .init(path: second.path, flags: UInt32(kFSEventStreamEventFlagRootChanged))
        ])
        XCTAssertTrue(tree.items.contains { $0.path == currentFile.path },
                      "A missing root is not proof that a previous verified list was deleted")
    }

    func testExcludedButCachedSubtreeStructuralEventInvalidatesQuickOpen() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("project")
        let hidden = root.appendingPathComponent("hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data().write(to: hidden.appendingPathComponent("before.swift"))
        defer { try? FileManager.default.removeItem(at: base) }
        let settings = AppSettings(configURL: base.appendingPathComponent("settings.toml"))
        try settings.applyFilesExclude([])
        let backend = CountingFileBackend()
        let tree = FileTreeModel(settings: settings)
        await tree.sync(root: root.path, backend: backend)
        await tree.toggle(try XCTUnwrap(tree.items.first { $0.path == hidden.path }))
        try settings.applyFilesExclude(["hidden"])
        await tree.refreshVisibility()
        XCTAssertFalse(tree.items.contains { $0.path == hidden.path })
        let revision = tree.contentRevision
        let reads = await backend.requests[hidden.path, default: 0]

        let addition = hidden.appendingPathComponent("after.swift")
        try Data().write(to: addition)
        await tree.refreshForLocalEvents([
            .init(path: addition.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        ])
        XCTAssertGreaterThan(tree.contentRevision, revision,
                             "Files exclude cannot hide file changes from Cmd+P")
        XCTAssertFalse(tree.items.contains { $0.path == hidden.path })
        let afterReads = await backend.requests[hidden.path, default: 0]
        XCTAssertEqual(afterReads, reads, "The invisible folder must not be listed only for Cmd+P")
    }

    func testPaletteRootMatchingRejectsSamePathFromAnotherMachine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let local = PanelContext(
            identity: .init(project: id, workspace: nil, directory: root.path),
            backend: LocalWorkspaceBackend.shared
        )
        let remote = PanelContext(
            identity: .init(project: id, workspace: "ssh:fixture", directory: root.path),
            backend: CountingFileBackend()
        )
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: local.backend, scope: local.scope,
                        panelIdentity: local.identity, connectionRevision: local.connectionRevision)
        XCTAssertTrue(tree.matchesIndexTarget(root: root.path, context: local))
        XCTAssertFalse(tree.matchesIndexTarget(root: root.path, context: remote),
                       "Equal path strings on different machines are never the same file-index root")
        await tree.sync(root: root.path, backend: remote.backend, scope: remote.scope,
                        panelIdentity: remote.identity, connectionRevision: remote.connectionRevision)
        XCTAssertTrue(tree.matchesIndexTarget(root: root.path, context: remote))
        XCTAssertFalse(tree.matchesIndexTarget(root: root.path, context: local))
    }

    func testSeparateFileEventsConsumersKeepOneWatcherAliveUntilLastUnsubscribes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = FileTreeModel()
        let filesPanel = UUID()
        let palette = UUID()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        tree.setLocalFileEventsEnabled(true, member: filesPanel)
        tree.setLocalFileEventsEnabled(true, member: palette)
        defer {
            tree.setLocalFileEventsEnabled(false, member: filesPanel)
            tree.setLocalFileEventsEnabled(false, member: palette)
        }

        tree.setLocalFileEventsEnabled(false, member: filesPanel)
        let created = root.appendingPathComponent("palette-only.swift")
        try Data("changed".utf8).write(to: created)
        try await waitForCondition("Palette must retain file notifications after Files closes") {
            tree.items.contains { $0.path == created.path }
        }
        XCTAssertTrue(ProjectFileIndex.load(in: root.path).contains { $0.absolutePath == created.path })

        tree.setLocalFileEventsEnabled(false, member: palette)
        let invisible = root.appendingPathComponent("after-palette-closes.swift")
        try Data("new".utf8).write(to: invisible)
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(tree.items.contains { $0.path == invisible.path },
                       "A hidden Files tree without a palette must not keep polling or watching")
    }

    func testRootMustScanSubDirsInvalidatesUnloadedProjectFileIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let deep = root.appendingPathComponent("unexpanded/deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        let initialRevision = tree.contentRevision
        let oldRows = tree.items
        let oldDeepReads = await backend.requests[deep.path, default: 0]

        let created = deep.appendingPathComponent("from-external-process.swift")
        try Data("real file".utf8).write(to: created)
        await tree.refreshForLocalEvents([
            .init(path: root.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        ])
        XCTAssertGreaterThan(tree.contentRevision, initialRevision,
                             "Coalesced root events must invalidate Cmd+P beyond the cached frontier")
        XCTAssertEqual(tree.items, oldRows, "A root event must not expand an unopened folder")
        let deepReads = await backend.requests[deep.path, default: 0]
        XCTAssertEqual(deepReads, oldDeepReads, "Do not enumerate deep Files folders for Cmd+P")
        XCTAssertTrue(ProjectFileIndex.load(in: root.path).contains { $0.absolutePath == created.path })
    }

    func testNativeLinkedWorktreeGitIndexOutsideProjectInvalidatesQuickOpen() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = base.appendingPathComponent("repository")
        let linked = base.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(GitCommandExecution.run(["init", "-q", "-b", "main"], in: repository.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["config", "user.name", "BaileyTest"], in: repository.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["config", "user.email", "test@example.invalid"], in: repository.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["config", "commit.gpgsign", "false"], in: repository.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["config", "core.hooksPath", "/dev/null"], in: repository.path).status, 0)
        try Data("seed".utf8).write(to: repository.appendingPathComponent("seed.txt"))
        XCTAssertEqual(GitCommandExecution.run(["add", "seed.txt"], in: repository.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "fixture"], in: repository.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(
            ["worktree", "add", "-q", "-b", "feature", linked.path], in: repository.path
        ).status, 0)
        let ignored = linked.appendingPathComponent("untracked.tmp")
        try Data("*.tmp\n".utf8).write(to: linked.appendingPathComponent(".gitignore"))
        try Data("linked bytes".utf8).write(to: ignored)
        let tree = FileTreeModel()
        await tree.sync(root: linked.path, backend: LocalWorkspaceBackend.shared)
        XCTAssertFalse(ProjectFileIndex.load(in: linked.path).contains { $0.absolutePath == ignored.path })
        let gitDirectory = try XCTUnwrap(ProjectFileIndex.gitDirectory(in: linked.path))
        XCTAssertFalse(LocalPathScope.contains(gitDirectory, in: linked.path),
                       "A linked worktree stores its index outside the visible project")
        let owner = UUID()
        tree.setLocalFileEventsEnabled(true, member: owner)
        tree.setLocalFileIndexGitDirectory(gitDirectory)
        defer {
            tree.setLocalFileIndexGitDirectory(nil)
            tree.setLocalFileEventsEnabled(false, member: owner)
        }
        let revision = tree.contentRevision
        XCTAssertEqual(GitCommandExecution.run(["add", "-f", "untracked.tmp"], in: linked.path).status, 0)
        try await waitForCondition("Real worktree index changes must reach the single Files watcher") {
            tree.contentRevision > revision
        }
        XCTAssertTrue(ProjectFileIndex.load(in: linked.path).contains { $0.absolutePath == ignored.path },
                      "An ignored file staged in a linked worktree must appear in ⌘P")
    }

    func testGitIgnoreAndIndexMetadataChangesInvalidateQuickOpenWithoutTreeChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initialized = GitCommandExecution.run(["init", "-q", "-b", "main"], in: root.path)
        XCTAssertEqual(initialized.status, 0)
        let ignored = root.appendingPathComponent("ignored.tmp")
        let rules = root.appendingPathComponent(".gitignore")
        try Data().write(to: rules)
        try Data("real bytes".utf8).write(to: ignored)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        XCTAssertTrue(ProjectFileIndex.load(in: root.path).contains { $0.absolutePath == ignored.path })
        let initialRevision = tree.contentRevision
        let displayed = tree.items

        try Data("*.tmp\n".utf8).write(to: rules)
        await tree.refreshForLocalEvents([
            .init(path: rules.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        ])
        XCTAssertGreaterThan(tree.contentRevision, initialRevision)
        XCTAssertEqual(tree.items, displayed, "Editing .gitignore content does not add/remove Files rows")
        XCTAssertFalse(ProjectFileIndex.load(in: root.path).contains { $0.absolutePath == ignored.path })

        let ignoredRevision = tree.contentRevision
        XCTAssertEqual(GitCommandExecution.run(["add", "-f", "--", "ignored.tmp"], in: root.path).status, 0)
        let indexPath = root.appendingPathComponent(".git/index").path
        await tree.refreshForLocalEvents([
            .init(path: indexPath, flags: UInt32(kFSEventStreamEventFlagItemModified))
        ])
        XCTAssertGreaterThan(tree.contentRevision, ignoredRevision)
        XCTAssertTrue(ProjectFileIndex.load(in: root.path).contains { $0.absolutePath == ignored.path },
                      "A file staged by -f must become searchable without a directory change")

        let afterIndex = tree.contentRevision
        await tree.refreshForLocalEvents([
            .init(path: ignored.path, flags: UInt32(kFSEventStreamEventFlagItemModified)),
            .init(path: root.appendingPathComponent(".git/index.lock").path,
                  flags: UInt32(kFSEventStreamEventFlagItemCreated))
        ])
        XCTAssertEqual(tree.contentRevision, afterIndex,
                       "File bytes and temporary Git lock files are not filename-index changes")
    }

    func testUnloadedSubtreeStructuralEventInvalidatesQuickOpenWithoutTreeScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let src = root.appendingPathComponent("src")
        let deep = src.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data().write(to: src.appendingPathComponent("sibling.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("other"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        let initial = tree.contentRevision
        let displayed = tree.items
        let beforeReads = await backend.requests[deep.path, default: 0]
        XCTAssertEqual(beforeReads, 0, "Unexpanded deep directories should remain unloaded")

        let newFile = deep.appendingPathComponent("outside.swift")
        try Data().write(to: newFile)
        await tree.refreshForLocalEvents([
            .init(path: newFile.path, flags: UInt32(kFSEventStreamEventFlagItemCreated))
        ])
        XCTAssertEqual(tree.items, displayed, "Unexpanded directory events must not scan the whole tree")
        let afterReads = await backend.requests[deep.path, default: 0]
        XCTAssertEqual(afterReads, beforeReads)
        XCTAssertGreaterThan(tree.contentRevision, initial,
                             "An open Cmd+P index must be invalidated for deep file additions")

        let afterCreate = tree.contentRevision
        await tree.refreshForLocalEvents([
            .init(path: newFile.path, flags: UInt32(kFSEventStreamEventFlagItemModified))
        ])
        XCTAssertEqual(tree.contentRevision, afterCreate,
                       "A content-only event must not rebuild the filename index")
    }

    func testExternalRefreshOnlyChangesFileIndexRevisionOnNewDiskContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.swift")
        let second = root.appendingPathComponent("second.swift")
        try Data("first".utf8).write(to: first)
        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        let initial = tree.contentRevision
        await tree.sync(root: root.path, backend: backend)
        XCTAssertEqual(tree.contentRevision, initial,
                       "Unchanged refresh must not reindex an open Command Palette")

        try Data("second".utf8).write(to: second)
        await backend.setUnavailable(true)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertEqual(tree.contentRevision, initial,
                       "A missing remote listing is not a directory deletion")
        XCTAssertFalse(tree.items.contains { $0.path == second.path })
        await backend.setUnavailable(false)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertGreaterThan(tree.contentRevision, initial)
        XCTAssertTrue(tree.items.contains { $0.path == second.path })
        let afterCreation = tree.contentRevision
        await tree.sync(root: root.path, backend: backend)
        XCTAssertEqual(tree.contentRevision, afterCreation)
        try FileManager.default.removeItem(at: first)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertGreaterThan(tree.contentRevision, afterCreation)
        XCTAssertFalse(tree.items.contains { $0.path == first.path })
    }

    func testPinnedSSHReconnectKeepsTrustedRowsIfNewChannelCannotListRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFile = root.appendingPathComponent("old.swift")
        let newFile = root.appendingPathComponent("new.swift")
        try Data("original".utf8).write(to: oldFile)

        let backend = CountingFileBackend()
        let identity = PanelContext.Identity(
            project: UUID(), workspace: "ssh:fixture", directory: root.path
        )
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend,
                        scope: "ssh:fixture", panelIdentity: identity, connectionRevision: 1)
        let row = try XCTUnwrap(tree.items.first { $0.path == oldFile.path })
        tree.select(row)
        await backend.setUnavailable(true)
        await tree.sync(root: root.path, backend: backend,
                        scope: "ssh:fixture", panelIdentity: identity, connectionRevision: 2)
        XCTAssertEqual(tree.items.map(\.path), [oldFile.path],
                       "An unreadable new SSH channel must preserve the last trustworthy tree")
        XCTAssertEqual(tree.selectedPath, oldFile.path,
                       "Reconnection alone must not discard the current cursor")
        let destination = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let denied = await tree.performFileOperation(
            .move, paths: [oldFile.path], into: destination.path
        )
        XCTAssertTrue(denied.succeeded.isEmpty)
        XCTAssertFalse(denied.failures.isEmpty,
                       "Old rows must remain visible but not editable on an unverified connection")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("old.swift").path))
        let deniedRename = await tree.rename(row, to: "unsafe.swift")
        XCTAssertNil(deniedRename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("unsafe.swift").path))

        await backend.setUnavailable(false)
        try FileManager.default.removeItem(at: oldFile)
        try Data("replacement".utf8).write(to: newFile)
        await tree.sync(root: root.path, backend: backend,
                        scope: "ssh:fixture", panelIdentity: identity, connectionRevision: 2)
        XCTAssertEqual(tree.items.map(\.path), [destination.path, newFile.path],
                       "Only a successful new listing may replace preserved rows")
        XCTAssertFalse(tree.selectedPaths.contains(oldFile.path))
    }

    func testSamePinnedSSHIdentityNewConnectionRefreshDoesNotWaitForOldBackend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFile = root.appendingPathComponent("old.swift")
        let newFile = root.appendingPathComponent("new.swift")
        try Data("old".utf8).write(to: oldFile)
        let backend = CountingFileBackend()
        let identity = PanelContext.Identity(
            project: UUID(), workspace: "ssh:fixture", directory: root.path
        )
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend,
                        scope: "ssh:fixture", panelIdentity: identity, connectionRevision: 1)
        await backend.delay(root.path)
        let oldRefresh = Task {
            await tree.sync(root: root.path, backend: backend,
                            scope: "ssh:fixture", panelIdentity: identity, connectionRevision: 1)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await backend.awaitingDirectory { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let blocked = await backend.awaitingDirectory
        XCTAssertTrue(blocked)
        try FileManager.default.removeItem(at: oldFile)
        try Data("new".utf8).write(to: newFile)

        await tree.sync(root: root.path, backend: backend,
                        scope: "ssh:fixture", panelIdentity: identity, connectionRevision: 2)
        XCTAssertTrue(tree.items.contains { $0.path == newFile.path },
                      "Fresh connection must not wait for previous SSH request to time out")
        XCTAssertFalse(tree.items.contains { $0.path == oldFile.path })
        await backend.release()
        await oldRefresh.value
        XCTAssertTrue(tree.items.contains { $0.path == newFile.path },
                      "Late data from the old channel must not replace new results")
        XCTAssertFalse(tree.items.contains { $0.path == oldFile.path })
    }

    func testFilesExcludeGlobAnchoringUnicodeAndInvalidRules() throws {
        let patterns = ["**/.git", "**/node_modules", "src/**/build?.log"]
        XCTAssertTrue(FilesExcludeGlob.excludes(".git", patterns: patterns))
        XCTAssertTrue(FilesExcludeGlob.excludes("src/inner/.git", patterns: patterns))
        XCTAssertTrue(FilesExcludeGlob.excludes("node_modules", patterns: patterns))
        XCTAssertTrue(FilesExcludeGlob.excludes("src/x/node_modules", patterns: patterns))
        XCTAssertTrue(FilesExcludeGlob.excludes("src/build1.log", patterns: patterns))
        XCTAssertTrue(FilesExcludeGlob.excludes("src/a/b/buildZ.log", patterns: patterns))
        XCTAssertFalse(FilesExcludeGlob.excludes("build1.log", patterns: patterns))
        XCTAssertFalse(FilesExcludeGlob.excludes("src/build11.log", patterns: patterns))
        XCTAssertFalse(FilesExcludeGlob.excludes(".gitignore", patterns: patterns))
        XCTAssertTrue(FilesExcludeGlob.excludes("notes/rapport.log", patterns: ["*.log"]))
        XCTAssertTrue(FilesExcludeGlob.excludes("notes/café.txt", patterns: ["cafe\u{301}.txt"]))
        XCTAssertTrue(FilesExcludeGlob.excludes("folder/a b.swift", patterns: ["a b.swift"]))
        XCTAssertFalse(FilesExcludeGlob.excludes("folder/a b.swift", patterns: [" a b.swift"]))
        XCTAssertFalse(FilesExcludeGlob.excludes("folder/readme.md", patterns: []))
        for invalid in ["", "/tmp", "../a", "foo/../bar", "foo//bar",
                        "folder/", "./foo", "bar[0-9]", "{foo,bar}", "a\\b", "ab**cd"] {
            XCTAssertThrowsError(try FilesExcludeGlob.validate([invalid]), "Accepted: \(invalid)")
        }
        XCTAssertNoThrow(try FilesExcludeGlob.validate(["**/.git", "src/**/foo?.log", " a "]))
    }

    func testFilesExcludeVisibilityTogglePreservesCachedDirectoryListings() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = fixture.appendingPathComponent("settings/config.toml")
        let root = fixture.appendingPathComponent("tree")
        for dir in [".git", ".visible", "node_modules", "folder", "folder/nested"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(dir), withIntermediateDirectories: true
            )
        }
        for file in ["folder/readme.md", "folder/nested/check.log"] {
            try Data("content".utf8).write(to: root.appendingPathComponent(file))
        }
        defer { try? FileManager.default.removeItem(at: fixture) }

        let settings = AppSettings(configURL: config)
        let backend = CountingFileBackend()
        let tree = FileTreeModel(settings: settings)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertFalse(tree.items.contains { $0.name == ".git" })
        XCTAssertTrue(tree.items.contains { $0.name == ".visible" })
        XCTAssertTrue(tree.items.contains { $0.name == "node_modules" })
        let folder = try XCTUnwrap(tree.items.first { $0.path == root.appendingPathComponent("folder").path })
        await tree.toggle(folder)
        XCTAssertTrue(tree.items.contains { $0.path == root.appendingPathComponent("folder/readme.md").path })
        let initialRequests = await backend.requests

        try settings.applyFilesExclude(["**/.git", "folder", "node_modules"])
        await tree.refreshVisibility()
        XCTAssertFalse(tree.items.contains { $0.path == folder.path })
        XCTAssertFalse(tree.items.contains { $0.name == "node_modules" })
        let hiddenRequests = await backend.requests
        XCTAssertEqual(hiddenRequests, initialRequests,
                       "Visibility changes must reproject raw cached directory entries")

        try settings.applyFilesExclude(["**/.git"])
        await tree.refreshVisibility()
        XCTAssertTrue(tree.items.contains { $0.path == folder.path })
        XCTAssertTrue(tree.items.contains { $0.path == root.appendingPathComponent("folder/readme.md").path })
        XCTAssertTrue(tree.items.contains { $0.name == "node_modules" })
        let unhiddenRequests = await backend.requests
        XCTAssertEqual(unhiddenRequests, initialRequests,
                       "Unhiding an expanded directory must not list it again")

        await tree.setShowExcluded(true)
        let gitFolder = try XCTUnwrap(tree.items.first { $0.name == ".git" })
        let beforeOpening = await backend.requests
        XCTAssertNil(beforeOpening[gitFolder.path], "Revealing a collapsed folder must not read it")
        await tree.toggle(gitFolder)
        XCTAssertEqual(settings.filesExclude, ["**/.git"])
        await tree.setShowExcluded(false)
        XCTAssertFalse(tree.items.contains { $0.name == ".git" })
        var expectedRequests = initialRequests
        expectedRequests[root.appendingPathComponent(".git").path] = 1
        let finalRequests = await backend.requests
        XCTAssertEqual(finalRequests, expectedRequests,
                       "A newly revealed directory may be listed once; cached ones must not re-list")
    }

    func testFilesExcludeChangedWhileDirectoryReadIsPendingUsesLatestProjection() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("logs"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = AppSettings(configURL: fixture.appendingPathComponent("settings.toml"))
        let backend = CountingFileBackend()
        await backend.delay(root.path)
        let tree = FileTreeModel(settings: settings)
        let read = Task { await tree.sync(root: root.path, backend: backend) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await backend.awaitingDirectory { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let awaiting = await backend.awaitingDirectory
        XCTAssertTrue(awaiting, "The original tree query must still be in flight")
        try settings.applyFilesExclude([])
        await tree.refreshVisibility()
        await backend.release()
        await read.value
        XCTAssertTrue(tree.items.contains { $0.name == ".git" },
                      "An old query must not overwrite the newer visibility rules")
        XCTAssertTrue(tree.items.contains { $0.name == "logs" })
    }

    func testRevealFileExpandsHiddenAncestorsWithoutPersistingShowExcluded() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("project")
        let nested = root.appendingPathComponent("hidden/a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let target = nested.appendingPathComponent("code.swift")
        try Data("let x = 1".utf8).write(to: target)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = AppSettings(configURL: fixture.appendingPathComponent("settings.toml"))
        try settings.applyFilesExclude(["hidden"])
        let tree = FileTreeModel(settings: settings)
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        XCTAssertFalse(tree.items.contains { $0.path == target.path })
        XCTAssertFalse(tree.showExcluded)

        let revealed = await tree.revealFile(target.path)
        XCTAssertTrue(revealed)
        XCTAssertEqual(tree.selectedPath, target.path)
        XCTAssertTrue(tree.items.contains { $0.path == target.path })
        XCTAssertTrue(tree.showExcluded)
        XCTAssertEqual(settings.filesExclude, ["hidden"])
        XCTAssertTrue(tree.items.contains { $0.path == nested.path })

        await tree.setShowExcluded(false)
        XCTAssertFalse(tree.items.contains { $0.path == target.path })
        XCTAssertEqual(settings.filesExclude, ["hidden"], "Reveal must never change persisted rules")
    }

    func testRevealFileRejectsMissingOutsideAndEscapingDirectorySymlinks() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("project")
        let outside = fixture.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.swift"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let outsideResult = await tree.revealFile(outside.appendingPathComponent("secret.swift").path)
        let missingResult = await tree.revealFile(root.appendingPathComponent("missing.swift").path)
        let rootResult = await tree.revealFile(root.path)
        let escapingLinkResult = await tree.revealFile(
            root.appendingPathComponent("link/secret.swift").path
        )
        XCTAssertFalse(outsideResult)
        XCTAssertFalse(missingResult)
        XCTAssertFalse(rootResult)
        XCTAssertFalse(escapingLinkResult,
                       "A directory symlink must not reveal a file outside the workspace")
        XCTAssertNil(tree.selectedPath)
    }

    func testRevealLocalFileSymlinkSelectsItsOwnRowAndRejectsInvalidTargets() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("project")
        let folder = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let target = folder.appendingPathComponent("actual.swift")
        try Data("let value = 1".utf8).write(to: target)
        let link = folder.appendingPathComponent("alias.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let broken = folder.appendingPathComponent("missing.swift")
        try FileManager.default.createSymbolicLink(
            at: broken, withDestinationURL: folder.appendingPathComponent("absent.swift")
        )
        let folderLink = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folder)
        let outside = fixture.appendingPathComponent("outside.swift")
        try Data("outside".utf8).write(to: outside)
        let escaping = folder.appendingPathComponent("external.swift")
        try FileManager.default.createSymbolicLink(at: escaping, withDestinationURL: outside)

        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let selected = await tree.revealFile(link.path)
        XCTAssertTrue(selected, "An open local symlink to a file should reveal the link's own row")
        XCTAssertEqual(tree.selectedPath, link.path)
        XCTAssertTrue(tree.items.contains { $0.path == link.path })
        let missing = await tree.revealFile(broken.path)
        let directory = await tree.revealFile(folderLink.path)
        let outsideTarget = await tree.revealFile(escaping.path)
        XCTAssertFalse(missing)
        XCTAssertFalse(directory)
        XCTAssertFalse(outsideTarget, "File symlinks may not escape the current workspace")
    }

    func testRevealWaitsForExistingRefreshAndSelectsTheRightFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("target.swift")
        try Data("target".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        await backend.delay(root.path)
        let refresh = Task { await tree.sync(root: root.path, backend: backend) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await backend.awaitingDirectory { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let wasAwaiting = await backend.awaitingDirectory
        XCTAssertTrue(wasAwaiting)
        let reveal = Task { await tree.revealFile(file.path) }
        try await Task.sleep(for: .milliseconds(20))
        await backend.release()
        await refresh.value
        let succeeded = await reveal.value
        XCTAssertTrue(succeeded)
        XCTAssertEqual(tree.selectedPath, file.path)
    }

    func testFilesPanelSelectsFirstVisibleRowAfterAsyncListingWithoutOpeningIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("alpha.swift")
        let second = root.appendingPathComponent("beta.swift")
        for file in [first, second] {
            try "original\n".write(to: file, atomically: true, encoding: .utf8)
        }

        let tree = FileTreeModel()
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 380, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var opened = 0
        let host = NSHostingView(rootView: FileTreePanel(
            model: tree, git: GitStatusModel(), sshHost: nil,
            currentFilePath: nil,
            openFile: { _, _ in opened += 1 },
            renameFile: { item, name in await tree.rename(item, to: name) },
            onCommand: { _ in },
            refreshGitStatus: {}, isCurrentTarget: { true },
            canImportFromFinder: false, importFromFinder: { _, _ in false }
        ))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(tree.selectedPath)

        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        try await waitForCondition("The first visible row should become selected after listing") {
            host.layoutSubtreeIfNeeded()
            return tree.selectedPath == first.path
        }
        XCTAssertEqual(opened, 0, "Focusing Files must not open a file automatically")
        XCTAssertEqual(tree.items.count, 2)
    }

    func testFilesPanelWaitsForCurrentTargetBeforeSelectingCurrentFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("alpha.swift")
        let second = root.appendingPathComponent("beta.swift")
        for file in [first, second] {
            try "unchanged\n".write(to: file, atomically: true, encoding: .utf8)
        }

        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let gate = FileTreeTargetGate()
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 440, height: 250),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var opened = 0
        let host = NSHostingView(rootView: FileTreePanel(
            model: tree, git: GitStatusModel(), sshHost: nil,
            currentFilePath: second.path,
            openFile: { _, _ in opened += 1 },
            renameFile: { item, name in await tree.rename(item, to: name) },
            onCommand: { _ in },
            refreshGitStatus: {}, isCurrentTarget: { gate.ready },
            canImportFromFinder: false, importFromFinder: { _, _ in false }
        ))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(tree.selectedPath, "A stale Files target must not select a row")

        gate.ready = true
        try await waitForCondition("The current file should be selected after target readiness") {
            host.layoutSubtreeIfNeeded()
            return tree.selectedPath == second.path
        }
        XCTAssertEqual(opened, 0, "Target readiness must not open a FileTab")
    }
    func testLargeDirectoryCursorClampsToVisibleBoundsAndPreservesUnicodeIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<1_024 {
            let path = root.appendingPathComponent(String(format: "entry-%04d.swift", index))
            XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: Data()))
        }
        let unicode = ["空格 名字.swift", "emoji-😀.swift", String(repeating: "长", count: 48) + ".swift"]
        for name in unicode {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        XCTAssertEqual(tree.items.count, 1_024 + unicode.count)
        let first = try XCTUnwrap(tree.items.first)
        let last = try XCTUnwrap(tree.items.last)
        XCTAssertEqual(tree.moveSelection(by: tree.items.count + 10)?.path, last.path)
        XCTAssertEqual(tree.moveSelection(by: 1)?.path, last.path)
        XCTAssertEqual(tree.moveSelection(by: -(tree.items.count + 10))?.path, first.path)
        XCTAssertEqual(tree.moveSelection(by: -1)?.path, first.path)
        for name in unicode {
            let path = root.appendingPathComponent(name).path
            let item = try XCTUnwrap(tree.items.first { $0.path == path })
            tree.select(item)
            XCTAssertEqual(tree.selectedPath, path)
        }
        tree.clearSelection()
        XCTAssertNil(tree.selectedPath)
    }

    func testFocusedRowNavigationTracksVisibleItemsAndResetsOnRootChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        for name in ["alpha.swift", "beta.swift"] {
            try "let x = 1\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let folder = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "let nested = 1\n".write(to: folder.appendingPathComponent("child.swift"),
                                       atomically: true, encoding: .utf8)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        XCTAssertNil(tree.selectedPath)
        let first = try XCTUnwrap(tree.items.first { !$0.isDraft })
        tree.select(first)
        XCTAssertEqual(tree.selectedPath, first.path)
        let next = try XCTUnwrap(tree.moveSelection(by: 1))
        XCTAssertEqual(tree.selectedPath, next.path)
        XCTAssertEqual(tree.moveSelection(by: -1)?.path, first.path)
        XCTAssertEqual(tree.selectedPath, first.path)

        let directory = try XCTUnwrap(tree.items.first { $0.path == folder.path })
        XCTAssertNil(tree.nextVisibleChild(of: directory),
                     "Right Arrow on a collapsed directory must not jump to a sibling")
        await tree.toggle(directory)
        let child = try XCTUnwrap(tree.items.first { $0.path == folder.appendingPathComponent("child.swift").path })
        XCTAssertEqual(tree.nextVisibleChild(of: directory)?.path, child.path)
        tree.select(child)
        XCTAssertEqual(tree.selectedPath, child.path)
        await tree.toggle(directory)
        XCTAssertEqual(tree.selectedPath, folder.path,
                       "Collapsing a selected descendant should focus the visible ancestor")
        XCTAssertNil(tree.nextVisibleChild(of: directory),
                     "Right Arrow on a collapsed tree must not choose another directory")
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared,
                        scope: "remote-workspace-with-same-directory-string")
        XCTAssertNil(tree.selectedPath, "A machine change with the same pathname must clear selection")
        tree.select(try XCTUnwrap(tree.items.first { !$0.isDraft }))
        await tree.sync(root: otherRoot.path, backend: LocalWorkspaceBackend.shared)
        XCTAssertNil(tree.selectedPath, "A new root must never inherit the old selection")
    }

    func testFileTreeMultiSelectionRespectsVisibleOrderAndKeepsSingleCursor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha", "beta", "gamma", "delta"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let rows = tree.items
        XCTAssertEqual(rows.count, 4)

        tree.select(rows[0])
        XCTAssertEqual(tree.selectedPaths, [rows[0].path])
        tree.select(rows[2], extending: true)
        XCTAssertEqual(tree.selectedPaths, Set(rows[0...2].map(\.path)))
        XCTAssertEqual(tree.selectedPath, rows[2].path)
        tree.select(rows[1], toggling: true)
        XCTAssertEqual(tree.selectedPaths, [rows[0].path, rows[2].path])
        XCTAssertEqual(tree.selectedPath, rows[1].path)
        XCTAssertEqual(tree.contextSelection(for: rows[2]), [rows[0].path, rows[2].path])
        XCTAssertEqual(tree.contextSelection(for: rows[3]), [rows[3].path])

        tree.select(rows[1])
        _ = tree.moveSelection(by: 2, extending: true)
        XCTAssertEqual(tree.selectedPaths, Set(rows[1...3].map(\.path)))
        _ = tree.moveSelection(by: -1, extending: true)
        XCTAssertEqual(tree.selectedPaths, Set(rows[1...2].map(\.path)))
        tree.selectAllVisible()
        XCTAssertEqual(tree.selectedPaths, Set(rows.map(\.path)))
        tree.clearSelection()
        XCTAssertNil(tree.selectedPath)
        XCTAssertTrue(tree.selectedPaths.isEmpty)
        _ = tree.moveSelection(by: 1)
        XCTAssertEqual(tree.selectedPaths, [rows[0].path])
    }

    func testCommandDeselectionStaysEmptyAfterDirectoryRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selected.txt")
        try Data("unchanged".utf8).write(to: file)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let row = try XCTUnwrap(tree.items.first { $0.path == file.path })
        tree.select(row)
        tree.select(row, toggling: true)
        XCTAssertEqual(tree.selectedPath, file.path, "Keyboard cursor must remain independent")
        XCTAssertTrue(tree.selectedPaths.isEmpty)
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        XCTAssertEqual(tree.selectedPath, file.path)
        XCTAssertTrue(tree.selectedPaths.isEmpty,
                      "Refresh must not reselect an explicitly deselected row")
        XCTAssertTrue(tree.selectedOperationPaths.isEmpty)
    }

    func testFileTreeMultiSelectionTracksCollapseRenameAndWorkspaceSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("child.swift")
        try Data().write(to: child)
        let sibling = root.appendingPathComponent("z.swift")
        try Data().write(to: sibling)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let dir = try XCTUnwrap(tree.items.first { $0.path == folder.path })
        await tree.toggle(dir)
        let childRow = try XCTUnwrap(tree.items.first { $0.path == child.path })
        let siblingRow = try XCTUnwrap(tree.items.first { $0.path == sibling.path })
        tree.select(childRow)
        tree.select(siblingRow, toggling: true)
        XCTAssertEqual(tree.selectedPaths.count, 2)

        let newFolder = root.appendingPathComponent("renamed")
        let moved = await tree.rename(dir, to: newFolder.lastPathComponent)
        XCTAssertEqual(moved, newFolder.path)
        XCTAssertTrue(tree.selectedPaths.contains(newFolder.appendingPathComponent("child.swift").path))
        XCTAssertTrue(tree.selectedPaths.contains(sibling.path))
        let renamedDir = try XCTUnwrap(tree.items.first { $0.path == newFolder.path })
        await tree.toggle(renamedDir)
        XCTAssertFalse(tree.selectedPaths.contains(newFolder.appendingPathComponent("child.swift").path))
        XCTAssertTrue(tree.selectedPaths.contains(sibling.path))

        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared, scope: "ssh:another-machine")
        XCTAssertTrue(tree.selectedPaths.isEmpty)
        XCTAssertNil(tree.selectedPath)
    }

    func testRenameKeepsFilesCursorOnRenamedFileAndDirectoryDescendant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("old-file.swift")
        try "unchanged\n".write(to: file, atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("old-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("child.swift")
        try "child\n".write(to: child, atomically: true, encoding: .utf8)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)

        let originalFile = try XCTUnwrap(tree.items.first { $0.path == file.path })
        tree.select(originalFile)
        let renamedFile = root.appendingPathComponent("new-file.swift")
        let movedFilePath = await tree.rename(originalFile, to: renamedFile.lastPathComponent)
        XCTAssertEqual(movedFilePath, renamedFile.path)
        XCTAssertEqual(tree.selectedPath, renamedFile.path)
        XCTAssertEqual(try String(contentsOf: renamedFile, encoding: .utf8), "unchanged\n")

        let originalFolder = try XCTUnwrap(tree.items.first { $0.path == folder.path })
        await tree.toggle(originalFolder)
        let descendant = try XCTUnwrap(tree.items.first { $0.path == child.path })
        tree.select(descendant)
        let renamedFolder = root.appendingPathComponent("new-folder")
        let movedFolderPath = await tree.rename(originalFolder, to: renamedFolder.lastPathComponent)
        XCTAssertEqual(movedFolderPath, renamedFolder.path)
        XCTAssertEqual(tree.selectedPath, renamedFolder.appendingPathComponent("child.swift").path)
        XCTAssertNotNil(tree.selectedItem)
        XCTAssertEqual(try String(contentsOf: renamedFolder.appendingPathComponent("child.swift"),
                                  encoding: .utf8), "child\n")
    }

    private var fixture: URL!
    private let backend = LocalWorkspaceBackend.shared

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture)
    }

    func testLocalWorkspaceCopyPreservesFilesDirectoriesAndLinksWithoutOverwriting() async throws {
        let source = fixture.appendingPathComponent("source '中文")
        let destination = fixture.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("hello.txt")
        let bytes = Data([0, 255, 10, 0, 128])
        try bytes.write(to: file)
        let linked = source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: "missing")
        let folder = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("child.txt"))

        let backend = LocalWorkspaceBackend.shared
        try await backend.copy(from: file.path, to: destination.appendingPathComponent("file-copy.txt").path)
        try await backend.copy(from: linked.path, to: destination.appendingPathComponent("link-copy").path)
        try await backend.copy(from: folder.path, to: destination.appendingPathComponent("folder-copy").path)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("file-copy.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("folder-copy/child.txt")), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.appendingPathComponent("link-copy").path
        ), "missing")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let occupied = destination.appendingPathComponent("file-copy.txt")
        do {
            try await backend.copy(from: folder.path, to: occupied.path)
            XCTFail("Copy must not overwrite a competing file")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: occupied), bytes)
        do {
            try await backend.copy(from: folder.path, to: folder.appendingPathComponent("subfolder").path)
            XCTFail("Cannot publish a recursive self-copy")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("subfolder").path))
        let alternate = source.appendingPathComponent("alternate.bin")
        try Data("other".utf8).write(to: alternate)
        let racing = destination.appendingPathComponent("winner.bin")
        let won = await withTaskGroup(of: Bool.self) { group in
            for path in [file.path, alternate.path] {
                group.addTask {
                    do { try await backend.copy(from: path, to: racing.path); return true }
                    catch { return false }
                }
            }
            var results: [Bool] = []
            for await value in group { results.append(value) }
            return results
        }
        XCTAssertEqual(won.filter { $0 }.count, 1)
        XCTAssertTrue([bytes, Data("other".utf8)].contains(try Data(contentsOf: racing)))
    }

    func testCopyPastedIntoSameFolderCreatesNumberedCopiesWithoutOverwriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("hello.txt")
        try Data("original".utf8).write(to: source)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let first = await tree.performFileOperation(.copy, paths: [source.path], into: root.path)
        XCTAssertTrue(first.failures.isEmpty)
        XCTAssertEqual(first.succeeded.first?.destination, root.appendingPathComponent("hello copy.txt").path)
        let second = await tree.performFileOperation(.copy, paths: [source.path], into: root.path)
        XCTAssertTrue(second.failures.isEmpty)
        XCTAssertEqual(second.succeeded.first?.destination, root.appendingPathComponent("hello copy 2.txt").path)
        for name in ["hello.txt", "hello copy.txt", "hello copy 2.txt"] {
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8),
                           "original")
        }

        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("child.txt"))
        let folderCopy = await tree.performFileOperation(.copy, paths: [folder.path], into: root.path)
        XCTAssertEqual(folderCopy.succeeded.first?.destination,
                       root.appendingPathComponent("folder copy").path)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("folder copy/child.txt")),
                       Data("nested".utf8))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("child.txt")),
                       Data("nested".utf8))
        let again = await tree.performFileOperation(.copy, paths: [folder.path], into: folder.path)
        XCTAssertEqual(again.succeeded.first?.destination,
                       root.appendingPathComponent("folder copy 2").path,
                       "Copying a selected folder and immediately pasting must create a sibling")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("folder copy 2/child.txt")),
                       Data("nested".utf8))
    }

    func testFileTreeBatchCopyMoveAndDeleteReportRealPartialResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("target")
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        try Data("occupied".utf8).write(to: target.appendingPathComponent("b.txt"))
        try Data("nested".utf8).write(to: folder.appendingPathComponent("child.txt"))
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)

        let copy = await tree.performFileOperation(.copy, paths: [a.path, b.path], into: target.path)
        XCTAssertEqual(copy.succeeded.map(\.source), [a.path])
        XCTAssertEqual(copy.failures.count, 1)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a.txt"), encoding: .utf8), "a")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("b.txt"), encoding: .utf8), "occupied")
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b")

        let move = await tree.performFileOperation(
            .move, paths: [folder.appendingPathComponent("child.txt").path, folder.path],
            into: target.path
        )
        XCTAssertEqual(move.succeeded.count, 1, "Parent/child selection must move once")
        XCTAssertEqual(move.succeeded.first?.source, folder.path)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("folder/child.txt"),
                                  encoding: .utf8), "nested")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        let deleted = await tree.performFileOperation(.delete, paths: [a.path], into: nil)
        XCTAssertEqual(deleted.succeeded.map(\.source), [a.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a.txt"), encoding: .utf8), "a")
    }

    func testTreeKeyEquivalentIsScopedToItsRealFirstResponder() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tree = TreeKeyboardView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = tree
        var handled = 0
        tree.onKeyDown = { event in
            guard event.keyCode == 9 else { return false }
            handled += 1
            return true
        }
        let commandV = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9
        ))
        XCTAssertTrue(window.makeFirstResponder(tree))
        XCTAssertTrue(tree.performKeyEquivalent(with: commandV))
        XCTAssertEqual(handled, 1)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(tree.performKeyEquivalent(with: commandV))
        XCTAssertEqual(handled, 1, "An unfocused Files/Git tree must never steal a command")
    }

    func testRenameAndCreateCannotEscapeProjectThroughDirectorySymlink() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("project")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = outside.appendingPathComponent("external.txt")
        try Data("untouched".utf8).write(to: source)
        let alias = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let directory = try XCTUnwrap(tree.items.first { $0.path == alias.path })
        await tree.toggle(directory)
        let externalRow = try XCTUnwrap(tree.items.first {
            $0.path == alias.appendingPathComponent("external.txt").path
        })
        let renamed = await tree.rename(externalRow, to: "renamed.txt")
        XCTAssertNil(renamed)
        XCTAssertEqual(try Data(contentsOf: source), Data("untouched".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("renamed.txt").path
        ))
        await tree.beginNewFile(in: alias.path)
        let created = await tree.commitDraft(name: "unauthorized.txt")
        XCTAssertNil(created)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("unauthorized.txt").path
        ))
        await tree.beginNewFolder(in: alias.path)
        _ = await tree.commitDraft(name: "unauthorized-folder")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("unauthorized-folder").path
        ))
    }

    func testFileTreeCopyUsesResolvedParentWhenDirectorySymlinkChangesDuringIO() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("project")
        let inside = root.appendingPathComponent("inside")
        let outside = base.appendingPathComponent("outside")
        let target = root.appendingPathComponent("target")
        for folder in [inside, outside, target] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        let alias = root.appendingPathComponent("alias")
        let source = alias.appendingPathComponent("a.txt")
        try Data("inside".utf8).write(to: inside.appendingPathComponent("a.txt"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inside)
        let backend = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        await backend.onNextCopy {
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        }
        let result = await tree.performFileOperation(
            .copy, paths: [source.path], into: target.path
        )
        XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: "\n"))
        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("a.txt")), Data("inside".utf8))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("a.txt")), Data("outside".utf8))
    }

    func testFileTreeBatchCannotWriteThroughOutsideRootSymlinkOrDeleteRoot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = root.appendingPathComponent("source.txt")
        try Data("safe".utf8).write(to: source)
        let symlink = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: outside.path)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)

        let blocked = await tree.performFileOperation(.copy, paths: [source.path], into: symlink.path)
        XCTAssertTrue(blocked.succeeded.isEmpty)
        XCTAssertEqual(blocked.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("source.txt").path))

        let outsideFile = outside.appendingPathComponent("untouched.txt")
        try Data("outside content".utf8).write(to: outsideFile)
        let deleteOutside = await tree.performFileOperation(
            .delete, paths: [symlink.appendingPathComponent("untouched.txt").path], into: nil
        )
        XCTAssertTrue(deleteOutside.succeeded.isEmpty)
        XCTAssertEqual(deleteOutside.failures.count, 1)
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "outside content")
        let moveOutside = await tree.performFileOperation(
            .move, paths: [symlink.appendingPathComponent("untouched.txt").path], into: root.path
        )
        XCTAssertTrue(moveOutside.succeeded.isEmpty)
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "outside content")

        let rootDelete = await tree.performFileOperation(.delete, paths: [root.path], into: nil)
        XCTAssertTrue(rootDelete.succeeded.isEmpty)
        XCTAssertEqual(rootDelete.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testFilenameWhitespaceIsPreservedForRenameAndDraftCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(" original ")
        try Data("kept".utf8).write(to: source)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let item = try XCTUnwrap(tree.items.first { $0.path == source.path })
        let renamed = await tree.rename(item, to: " renamed ")
        XCTAssertEqual(renamed, root.appendingPathComponent(" renamed ").path)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(" renamed "), encoding: .utf8), "kept")
        await tree.beginNewFile(in: root.path)
        _ = await tree.commitDraft(name: " new file ")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(" new file ").path))
        await tree.beginNewFolder(in: root.path)
        _ = await tree.commitDraft(name: " dir ")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(" dir ").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testFinderImportDirectoryBoundaryIncludesRootButNotSiblingNames() {
        let root = "/"
        XCTAssertTrue(LocalPathScope.contains(root, in: root))
        XCTAssertTrue(LocalPathScope.contains("/tmp", in: root))
        XCTAssertTrue(LocalPathScope.contains("/private/tmp/child.txt", in: root))
        XCTAssertTrue(LocalPathScope.contains("/tmp/child", in: "/tmp"))
        XCTAssertTrue(LocalPathScope.contains("/tmp", in: "/tmp"))
        XCTAssertFalse(LocalPathScope.contains("/tmp-other", in: "/tmp"))
        XCTAssertFalse(LocalPathScope.contains("/tmp/child", in: "/tmp/children"))
        XCTAssertFalse(LocalPathScope.contains("/tmp", in: "/tmp/child"))
        XCTAssertFalse(LocalPathScope.contains("tmp/child", in: "/"))
        XCTAssertFalse(LocalPathScope.contains("/", in: "/tmp"))
        XCTAssertFalse(LocalPathScope.contains("/tmp", in: ""))
    }

    func testFinderImportIntoSubdirectoryWhenWorkspaceRootIsSlash() async throws {
        let sourceDir = fixture.appendingPathComponent("source")
        let targetDir = fixture.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("root-scope.txt")
        let destination = targetDir.appendingPathComponent(source.lastPathComponent)
        let data = Data("root-project-import".utf8)
        try data.write(to: source)

        let tree = FileTreeModel()
        await tree.sync(root: "/", backend: backend)
        let result = await tree.importFromFinder(
            [source], into: targetDir.path, isCurrentTarget: { true }
        )
        XCTAssertEqual(result?.copied, [destination.path])
        XCTAssertEqual(result?.failures, [])
        XCTAssertEqual(try Data(contentsOf: destination), data)
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    func testFinderDropCopiesFilesAndDirectoriesIntoExactLocalTargetAndRefreshesTree() async throws {
        let sources = fixture.appendingPathComponent("source")
        let workspace = fixture.appendingPathComponent("workspace")
        let nested = workspace.appendingPathComponent("nested")
        let package = sources.appendingPathComponent("folder")
        for folder in [sources, nested, package] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let sourceFile = sources.appendingPathComponent("文件 with spaces.txt")
        let nestedSource = package.appendingPathComponent("inner.md")
        try Data("source-content".utf8).write(to: sourceFile)
        try Data("nested-content".utf8).write(to: nestedSource)

        let tree = FileTreeModel()
        await tree.sync(root: workspace.path, backend: backend)
        let folderRow = try XCTUnwrap(tree.items.first { $0.path == nested.path })
        await tree.toggle(folderRow)
        let dropped = await tree.importFromFinder(
            [sourceFile, package], into: nested.path, isCurrentTarget: { true }
        )
        let report = try XCTUnwrap(dropped)
        XCTAssertEqual(report.copied.count, 2)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent(sourceFile.lastPathComponent)),
                       Data("source-content".utf8))
        XCTAssertEqual(try Data(contentsOf: nested.appendingPathComponent("folder/inner.md")),
                       Data("nested-content".utf8))
        XCTAssertEqual(try Data(contentsOf: sourceFile), Data("source-content".utf8))
        XCTAssertEqual(try Data(contentsOf: nestedSource), Data("nested-content".utf8))
        XCTAssertTrue(tree.items.contains { $0.path == nested.appendingPathComponent("folder").path },
                      "Visible Files tree must refresh after the copy")
    }

    func testFinderDropNeverOverwritesAndReportsPartialConflictsAndSelfCopy() async throws {
        let sources = fixture.appendingPathComponent("origin")
        let target = fixture.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let duplicate = sources.appendingPathComponent("duplicate.txt")
        let unique = sources.appendingPathComponent("unique.txt")
        try Data("source-value".utf8).write(to: duplicate)
        try Data("unique-value".utf8).write(to: unique)
        try Data("keep-original".utf8).write(to: target.appendingPathComponent("duplicate.txt"))

        let tree = FileTreeModel()
        await tree.sync(root: target.path, backend: backend)
        var shownErrors: [String] = []
        tree.onError = { _, detail in shownErrors.append(detail) }
        let dropped = await tree.importFromFinder(
            [duplicate, unique], into: target.path, isCurrentTarget: { true }
        )
        let report = try XCTUnwrap(dropped)
        XCTAssertEqual(report.copied.count, 1)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(shownErrors.count, 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("duplicate.txt")),
                       Data("keep-original".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("unique.txt")),
                       Data("unique-value".utf8))
        XCTAssertEqual(try Data(contentsOf: duplicate), Data("source-value".utf8))
        XCTAssertEqual(try Data(contentsOf: unique), Data("unique-value".utf8))

        let sub = target.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let recursive = await tree.importFromFinder(
            [target], into: sub.path, isCurrentTarget: { true }
        )
        let selfReport = try XCTUnwrap(recursive)
        XCTAssertTrue(selfReport.copied.isEmpty)
        XCTAssertEqual(selfReport.failures.count, 1, "A folder cannot be copied into its descendant")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sub.appendingPathComponent("dest").path))
    }

    func testFinderCopyFailureDoesNotPublishPartiallyCopiedDirectory() async throws {
        let source = fixture.appendingPathComponent("incomplete-folder")
        let target = fixture.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let readable = source.appendingPathComponent("a-allowed.txt")
        let blocked = source.appendingPathComponent("z-unreadable.txt")
        try Data("allowed".utf8).write(to: readable)
        try Data("blocked".utf8).write(to: blocked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked.path) }
        if (try? Data(contentsOf: blocked)) != nil {
            throw XCTSkip("Test host bypasses POSIX source-read protection")
        }

        let result = await backend.copyFromFinder([source], into: target.path)
        XCTAssertTrue(result.copied.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(source.lastPathComponent).path),
                       "A failed recursive import must not leave a partial visible folder")
        XCTAssertEqual(try Data(contentsOf: readable), Data("allowed".utf8))
    }

    func testConcurrentFinderCopySameDestinationHasOneWinnerWithoutOverwrite() async throws {
        let sourceDirectory = fixture.appendingPathComponent("source")
        let target = fixture.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("same.txt")
        let content = Data("concurrent-copy-source".utf8)
        try content.write(to: source)

        let reports = await withTaskGroup(of: LocalFileImportResult.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await LocalWorkspaceBackend.shared.copyFromFinder([source], into: target.path)
                }
            }
            var reports: [LocalFileImportResult] = []
            for await report in group { reports.append(report) }
            return reports
        }
        XCTAssertEqual(reports.flatMap(\.copied).count, 1,
                       "Atomic no-overwrite publish admits only one concurrent importer")
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(source.lastPathComponent)), content)
        XCTAssertEqual(try Data(contentsOf: source), content)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [source.lastPathComponent],
                       "Failed imports leave no partial or temporary workspace entries")
    }

    func testFinderCopyRefusesOutsideSymlinkTargetsAndExistingDanglingDestinations() async throws {
        let workspace = fixture.appendingPathComponent("root")
        let outside = fixture.appendingPathComponent("outside")
        let sourceFolder = fixture.appendingPathComponent("source")
        for folder in [workspace, outside, sourceFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let source = sourceFolder.appendingPathComponent("dangling.txt")
        try Data("safe".utf8).write(to: source)
        let link = workspace.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let tree = FileTreeModel()
        await tree.sync(root: workspace.path, backend: backend)
        var errors: [(title: String, detail: String)] = []
        tree.onError = { title, detail in errors.append((title, detail)) }
        let rejected = await tree.importFromFinder([source], into: link.path, isCurrentTarget: { true })
        XCTAssertNil(rejected, "A symlink row must not redirect Finder import beyond project root")
        XCTAssertEqual(errors.count, 1, "The accepted drop must explain why its visible target was rejected")
        XCTAssertTrue(errors.first?.detail.contains(link.lastPathComponent) == true)
        let outsideRoot = await tree.importFromFinder([source], into: outside.path, isCurrentTarget: { true })
        XCTAssertNil(outsideRoot)
        XCTAssertEqual(errors.count, 2, "An out-of-root folder also needs an explicit error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent(source.lastPathComponent).path))

        let destination = workspace.appendingPathComponent("dangling.txt")
        try FileManager.default.createSymbolicLink(
            at: destination, withDestinationURL: fixture.appendingPathComponent("missing.txt")
        )
        let attempted = await tree.importFromFinder(
            [source], into: workspace.path, isCurrentTarget: { true }
        )
        let report = try XCTUnwrap(attempted)
        XCTAssertTrue(report.copied.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
                       fixture.appendingPathComponent("missing.txt").path)
        XCTAssertEqual(try Data(contentsOf: source), Data("safe".utf8))
    }

    func testFinderImportUsesValidatedPhysicalDestinationForInRootDirectoryAlias() async throws {
        let workspace = fixture.appendingPathComponent("workspace")
        let sourceDir = fixture.appendingPathComponent("origin")
        let realDestination = workspace.appendingPathComponent("real")
        let outside = fixture.appendingPathComponent("outside")
        for directory in [sourceDir, realDestination, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let source = sourceDir.appendingPathComponent("safe.txt")
        let bytes = Data([0, 255, 10, 128])
        try bytes.write(to: source)
        let alias = workspace.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realDestination)
        let tree = FileTreeModel()
        await tree.sync(root: workspace.path, backend: backend)

        let result = await tree.importFromFinder([source], into: alias.path, isCurrentTarget: { true })
        XCTAssertEqual(result?.failures, [])
        XCTAssertEqual(result?.copied, [realDestination.appendingPathComponent("safe.txt").path],
                       "Import must pin the physical directory validated before asynchronous I/O")
        XCTAssertEqual(try Data(contentsOf: realDestination.appendingPathComponent("safe.txt")), bytes)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("safe.txt").path))
        XCTAssertEqual(try Data(contentsOf: realDestination.appendingPathComponent("safe.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testFinderCopyPreservesSymlinksInsteadOfDereferencingOrRejectingThem() async throws {
        let fm = FileManager.default
        let origin = fixture.appendingPathComponent("origin")
        let workspace = fixture.appendingPathComponent("workspace")
        let target = workspace.appendingPathComponent("target")
        for directory in [origin, target] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let missing = origin.appendingPathComponent("no-longer-here")
        let brokenLink = origin.appendingPathComponent("dangling-link")
        let directoryLink = origin.appendingPathComponent("workspace-link")
        let regular = origin.appendingPathComponent("good.txt")
        try fm.createSymbolicLink(at: brokenLink, withDestinationURL: missing)
        try fm.createSymbolicLink(at: directoryLink, withDestinationURL: workspace)
        try Data("still good".utf8).write(to: regular)

        let tree = FileTreeModel()
        await tree.sync(root: workspace.path, backend: backend)
        let result = await tree.importFromFinder(
            [brokenLink, directoryLink, regular], into: target.path, isCurrentTarget: { true }
        )
        let report = try XCTUnwrap(result)
        XCTAssertEqual(Set(report.copied), Set([
            target.appendingPathComponent("dangling-link").path,
            target.appendingPathComponent("workspace-link").path,
            target.appendingPathComponent("good.txt").path,
        ]), "Copy the links themselves, not a recursive copy of their destinations")
        XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: "\n"))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("dangling-link").path), missing.path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("workspace-link").path), workspace.path)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("good.txt")), Data("still good".utf8))
        XCTAssertEqual(try Data(contentsOf: regular), Data("still good".utf8))
    }

    func testFinderCopyRejectsSpecialFilesWithoutReadingPipesOrDevices() async throws {
        let origin = fixture.appendingPathComponent("specials")
        let target = fixture.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let pipe = origin.appendingPathComponent("blocking.fifo")
        XCTAssertEqual(Darwin.mkfifo(pipe.path, 0o600), 0)
        let report = await backend.copyFromFinder([pipe, URL(fileURLWithPath: "/dev/null")], into: target.path)
        XCTAssertTrue(report.copied.isEmpty)
        XCTAssertEqual(report.failures.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("blocking.fifo").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("null").path))
    }

    func testFinderCopyLargeMixedBatchKeepsDuplicatesAndCollisionsIsolated() async throws {
        let origin = fixture.appendingPathComponent("origin")
        let other = fixture.appendingPathComponent("other")
        let target = fixture.appendingPathComponent("target")
        for directory in [origin, other, target] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var inputs: [URL] = []
        for index in 0..<55 {
            let file = origin.appendingPathComponent(String(format: "item-%03d.txt", index))
            try Data("payload-\(index)".utf8).write(to: file)
            inputs.append(file)
        }
        let collision = other.appendingPathComponent("item-022.txt")
        try Data("must stay separate".utf8).write(to: collision)
        let report = await backend.copyFromFinder(inputs + [inputs[0], collision], into: target.path)
        XCTAssertEqual(report.copied.count, 55, "Same URL is idempotent; unique files keep copying")
        XCTAssertEqual(report.failures.count, 1, "Different source with an already used name cannot overwrite")
        for index in 0..<55 {
            let filename = String(format: "item-%03d.txt", index)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(filename)), Data("payload-\(index)".utf8))
            XCTAssertEqual(try Data(contentsOf: origin.appendingPathComponent(filename)), Data("payload-\(index)".utf8))
        }
        XCTAssertEqual(try Data(contentsOf: collision), Data("must stay separate".utf8))
    }

    func testFinderDropRejectsRemoteOrStaleTreeAndOutsideRoot() async throws {
        let root = fixture.appendingPathComponent("root")
        let external = fixture.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("remain outside".utf8).write(to: external)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend, scope: "ssh:remote")
        let remote = await tree.importFromFinder([external], into: root.path, isCurrentTarget: { true })
        XCTAssertNil(remote)
        await tree.sync(root: root.path, backend: backend)
        let stale = await tree.importFromFinder([external], into: root.path, isCurrentTarget: { false })
        XCTAssertNil(stale)
        let outside = await tree.importFromFinder([external], into: fixture.path, isCurrentTarget: { true })
        XCTAssertNil(outside)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path))
    }

    func testExclusiveCreationAndConcurrentRace() async throws {
        let file = fixture.appendingPathComponent("exclusive.txt")
        try await backend.createFile(path: file.path)
        XCTAssertEqual(try Data(contentsOf: file), Data())
        try Data("preserve".utf8).write(to: file)
        do {
            try await backend.createFile(path: file.path)
            XCTFail("Existing file must not be overwritten")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("preserve".utf8))

        let race = fixture.appendingPathComponent("race.txt").path
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do { try await LocalWorkspaceBackend.shared.createFile(path: race); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        XCTAssertEqual(winners, 1)
    }

    func testTreeExpansionDraftAndRename() async throws {
        let root = fixture.appendingPathComponent("root")
        let nested = root.appendingPathComponent("dir/inner")
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let original = nested.appendingPathComponent("a.swift")
        try Data().write(to: original)

        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        let dir = try XCTUnwrap(tree.items.first { $0.path == root.appendingPathComponent("dir").path })
        await tree.toggle(dir)
        let inner = try XCTUnwrap(tree.items.first { $0.path == nested.path })
        XCTAssertEqual(inner.displayName, "inner")
        await tree.toggle(inner)
        let compact = try XCTUnwrap(tree.items.first { $0.path == nested.path })
        XCTAssertEqual(compact.displayName, "dir / inner")
        XCTAssertTrue(tree.items.contains { $0.path == original.path })

        await tree.beginNewFile(in: nested.path)
        XCTAssertTrue(tree.items.contains { $0.isDraft && $0.depth == 1 })
        let created = await tree.commitDraft(name: "draft.swift")
        XCTAssertEqual(created, nested.appendingPathComponent("draft.swift").path)
        XCTAssertTrue(tree.items.contains { $0.path == created }, "Created item must appear immediately")

        let renamed = await tree.rename(compact, to: "renamed")
        XCTAssertEqual(renamed, root.appendingPathComponent("dir/renamed").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed! + "/draft.swift"))
        XCTAssertEqual(tree.items.first { $0.path == renamed }?.displayName, "dir / renamed")
    }

    func testExpansionIsScopedByRootAndWorkspaceIdentity() async throws {
        let firstRoot = fixture.appendingPathComponent("a")
        let secondRoot = fixture.appendingPathComponent("b")
        let firstNested = firstRoot.appendingPathComponent("dir/inner")
        let secondNested = secondRoot.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: firstNested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondNested, withIntermediateDirectories: true)
        try Data().write(to: firstNested.appendingPathComponent("a.swift"))
        try Data().write(to: secondNested.appendingPathComponent("b.swift"))

        let tree = FileTreeModel()
        await tree.sync(root: firstRoot.path, backend: backend)
        let dir = try XCTUnwrap(tree.items.first { $0.path == firstRoot.appendingPathComponent("dir").path })
        await tree.toggle(dir)
        let compact = try XCTUnwrap(tree.items.first { $0.path == firstNested.path })
        await tree.toggle(compact)
        XCTAssertTrue(tree.isExpanded(compact))

        await tree.sync(root: secondRoot.path, backend: backend)
        XCTAssertFalse(tree.isExpanded(compact))
        await tree.sync(root: firstRoot.path, backend: backend)
        XCTAssertTrue(tree.isExpanded(compact))
        await tree.sync(root: firstRoot.path, backend: backend, scope: "ssh:fixture")
        XCTAssertFalse(tree.isExpanded(compact))
        await tree.sync(root: firstRoot.path, backend: backend, scope: "local")
        XCTAssertTrue(tree.isExpanded(compact))
    }

    func testObservableTreeKeepsRealFileOperationsAndErrorsOutsideModelUI() async throws {
        let existing = fixture.appendingPathComponent("existing.txt")
        let candidate = fixture.appendingPathComponent("candidate.txt")
        try Data("preserved".utf8).write(to: existing)
        try Data("source".utf8).write(to: candidate)

        let tree = FileTreeModel()
        let changed = expectation(description: "File tree entries became observable")
        withObservationTracking({ _ = tree.items }) { changed.fulfill() }
        await tree.sync(root: fixture.path, backend: backend)
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertTrue(tree.items.contains { $0.path == existing.path })

        // There is no FileTreePanel here: an outer window still receives
        // operation errors through the model's presentation callback.
        var failures: [(title: String, detail: String)] = []
        tree.onError = { title, detail in failures.append((title, detail)) }

        await tree.beginNewFile(in: fixture.path)
        let rejected = await tree.commitDraft(name: "invalid/name")
        XCTAssertNil(rejected)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].title.contains("invalid/name"))
        XCTAssertTrue(failures[0].detail.contains("/"))
        XCTAssertNil(tree.draft)

        await tree.beginNewFile(in: fixture.path)
        let duplicate = await tree.commitDraft(name: "existing.txt")
        XCTAssertNil(duplicate)
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "preserved")

        // Normal creation uses a new name. Verify the actual file instead of
        // treating an error dialog or a visible draft row as success.
        let unique = fixture.appendingPathComponent("unique-smoke.txt")
        await tree.beginNewFile(in: fixture.path)
        let created = await tree.commitDraft(name: unique.lastPathComponent)
        XCTAssertEqual(created, unique.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unique.path))
        XCTAssertEqual(failures.count, 2)

        let source = try XCTUnwrap(tree.items.first { $0.path == candidate.path })
        let collision = await tree.rename(source, to: "existing.txt")
        XCTAssertNil(collision)
        XCTAssertEqual(failures.count, 3)
        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8), "source")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "preserved")

        // Cancelling an inline new-file row cannot create anything on disk.
        await tree.beginNewFolder(in: fixture.path)
        await tree.cancelDraft()
        XCTAssertNil(tree.draft)
        XCTAssertEqual(failures.count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.path).sorted(),
                       ["candidate.txt", "existing.txt", "unique-smoke.txt"])
    }

    func testExternalRefreshAndUnreadableRootPreservesDisplayedEntries() async throws {
        let root = fixture.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        XCTAssertTrue(tree.items.isEmpty)

        let created = root.appendingPathComponent("created.txt")
        try Data("created\n".utf8).write(to: created)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertEqual(tree.items.map(\.path), [created.path])

        let renamed = root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: created, to: renamed)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertEqual(tree.items.map(\.path), [renamed.path])

        let savedRoot = fixture.appendingPathComponent("temporarily-unreachable")
        try FileManager.default.moveItem(at: root, to: savedRoot)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertEqual(tree.items.map(\.path), [renamed.path],
                       "A failed directory read must not report an empty folder")
        try FileManager.default.moveItem(at: savedRoot, to: root)
        try FileManager.default.removeItem(at: renamed)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertTrue(tree.items.isEmpty)
    }

    func testSymlinkDirectoryBrokenLinkAndCycleRemainBounded() async throws {
        let root = fixture.appendingPathComponent("symlinks")
        let nested = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: nested.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: nested.appendingPathComponent("b.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"),
                                                    withDestinationURL: nested)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("broken"),
                                                    withDestinationURL: root.appendingPathComponent("absent"))
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("loop"),
                                                    withDestinationURL: nested)

        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        let alias = try XCTUnwrap(tree.items.first { $0.path == root.appendingPathComponent("alias").path })
        XCTAssertTrue(alias.isDirectory)
        XCTAssertTrue(tree.hasVisibleDirectorySymlinks,
                      "Windows event streams do not follow external symlink targets")
        let broken = try XCTUnwrap(tree.items.first { $0.path == root.appendingPathComponent("broken").path })
        XCTAssertFalse(broken.isDirectory)
        await tree.toggle(alias)
        XCTAssertTrue(tree.items.contains { $0.path == alias.path + "/a.txt" })
        XCTAssertTrue(tree.items.contains { $0.path == alias.path + "/loop" })
        let nestedCycle = try XCTUnwrap(tree.items.first { $0.path == alias.path + "/loop" })
        await tree.toggle(nestedCycle)
        XCTAssertLessThan(tree.items.count, 75, "Symlink loops cannot generate an unbounded tree")
    }

    func testCollapsedAndExpandedFoldersDoNotRereadUnchangedDirectories() async throws {
        let root = fixture.appendingPathComponent("cached")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("initial".utf8).write(to: root.appendingPathComponent("root.txt"))
        try Data("child".utf8).write(to: sub.appendingPathComponent("child.txt"))
        let counting = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: counting)
        let folder = try XCTUnwrap(tree.items.first { $0.path == sub.path })
        let readsAfterInitial = await counting.requests
        XCTAssertNil(readsAfterInitial[sub.path], "Cold tree must not read a collapsed directory")
        await tree.toggle(folder)
        XCTAssertTrue(tree.items.contains { $0.path == sub.appendingPathComponent("child.txt").path })
        let readsAfterExpansion = await counting.requests
        XCTAssertEqual(readsAfterExpansion[sub.path], 1, "Only the clicked folder should be fetched")
        await tree.toggle(folder)
        await tree.toggle(folder)
        let readsAfterRepeat = await counting.requests
        XCTAssertEqual(readsAfterRepeat, readsAfterExpansion)
        await tree.sync(root: root.path, backend: counting)
        let batch = await counting.lastBatch
        XCTAssertEqual(batch?.contains(sub.path), true)
    }

    func testFolderIconChangesBeforeRemoteContentsArrive() async throws {
        let root = fixture.appendingPathComponent("slow")
        let parent = root.appendingPathComponent("parent")
        let first = parent.appendingPathComponent("first")
        let second = parent.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data().write(to: first.appendingPathComponent("a.txt"))
        try Data().write(to: second.appendingPathComponent("b.txt"))

        let counting = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: counting)
        let folder = try XCTUnwrap(tree.items.first { $0.path == parent.path })
        XCTAssertFalse(folder.isExpanded)
        await counting.delay(parent.path)
        defer { Task { await counting.release() } }
        let opening = Task { await tree.toggle(folder) }
        let deadline = Date().addingTimeInterval(5)
        while await !counting.awaitingDirectory && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(tree.items.first(where: { $0.path == parent.path })?.isExpanded == true,
                      "The open icon must not wait for the SSH reply")
        await counting.release()
        await opening.value
        XCTAssertTrue(tree.items.contains { $0.path == first.path })
    }

    func testOfflineRefreshRetainsExistingTreeWithoutCrossWorkspaceLeak() async throws {
        let root = fixture.appendingPathComponent("offline")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("keep.txt"))
        let counting = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: counting, scope: "ssh:one")
        let previous = tree.items
        XCTAssertFalse(previous.isEmpty)
        await counting.setUnavailable(true)
        await tree.sync(root: root.path, backend: counting, scope: "ssh:one")
        XCTAssertEqual(tree.items, previous)
        await tree.sync(root: root.path, backend: counting, scope: "ssh:two")
        XCTAssertTrue(tree.items.isEmpty, "A different SSH target cannot inherit the old tree")
    }

    func testCompactFoldersReadOnlyTheClickedLevel() async throws {
        let root = fixture.appendingPathComponent("lazy-compact")
        let a = root.appendingPathComponent("A")
        let b = a.appendingPathComponent("B")
        let c = b.appendingPathComponent("C")
        let sibling = root.appendingPathComponent("unopened")
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data().write(to: c.appendingPathComponent("leaf.swift"))

        let counting = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: counting, scope: "ssh:lazy-test")
        XCTAssertEqual(Set(tree.items.map(\.path)), [a.path, sibling.path])
        let initialReads = await counting.requests
        XCTAssertEqual(initialReads, [root.path: 1],
                       "An unopened folder must not be queried to compute compact names")

        let first = try XCTUnwrap(tree.items.first { $0.path == a.path })
        tree.select(first)
        await tree.toggle(first)
        XCTAssertEqual(tree.selectedPath, a.path)
        XCTAssertEqual(tree.items.first(where: { $0.path == a.path })?.isExpanded, true,
                       "Clicking a folder must visibly expand it, not only rename its row")
        XCTAssertEqual(tree.items.first(where: { $0.path == b.path })?.displayName, "B")
        let afterA = await counting.requests
        XCTAssertEqual(afterA[a.path], 1)
        XCTAssertNil(afterA[b.path], "Compaction may use A's entry metadata but must not read B")
        XCTAssertNil(afterA[c.path])
        XCTAssertNil(afterA[sibling.path])

        let second = try XCTUnwrap(tree.items.first { $0.path == b.path })
        tree.select(second)
        await tree.toggle(second)
        XCTAssertEqual(tree.selectedPath, b.path)
        XCTAssertEqual(tree.items.first(where: { $0.path == b.path })?.displayName, "A / B")
        XCTAssertEqual(tree.items.first(where: { $0.path == b.path })?.isExpanded, true)
        XCTAssertEqual(tree.items.first(where: { $0.path == c.path })?.displayName, "C")
        let afterB = await counting.requests
        XCTAssertEqual(afterB[b.path], 1)
        XCTAssertNil(afterB[c.path], "Do not inspect C until its row is opened")

        let third = try XCTUnwrap(tree.items.first { $0.path == c.path })
        tree.select(third)
        await tree.toggle(third)
        XCTAssertEqual(tree.selectedPath, c.path)
        XCTAssertEqual(tree.items.first(where: { $0.path == c.path })?.displayName, "A / B / C")
        XCTAssertTrue(tree.items.contains { $0.path == c.appendingPathComponent("leaf.swift").path })
        let afterC = await counting.requests
        XCTAssertEqual(afterC[c.path], 1)
        XCTAssertNil(afterC[sibling.path])
    }

    func testCompactedRowTargetsEachRealDirectoryAndCreatesAtSelectedLevel() async throws {
        let root = fixture.appendingPathComponent("compact-actions")
        let a = root.appendingPathComponent("a1")
        let b = a.appendingPathComponent("b1")
        let c = b.appendingPathComponent("c1")
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        try Data().write(to: c.appendingPathComponent("existing.swift"))
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        for path in [a.path, b.path, c.path] {
            let row = try XCTUnwrap(tree.items.first { $0.path == path })
            await tree.toggle(row)
        }
        let compact = try XCTUnwrap(tree.items.first { $0.path == c.path })
        XCTAssertEqual(compact.displayName, "a1 / b1 / c1")
        XCTAssertEqual(compact.compactComponents.map(\.path), [a.path, b.path, c.path])

        tree.select(compact, componentPath: a.path)
        XCTAssertEqual(tree.selectedDirectoryPath, a.path)
        XCTAssertEqual(tree.selectedOperationPaths, [a.path])
        tree.select(compact, componentPath: b.path)
        XCTAssertEqual(tree.selectedDirectoryPath, b.path)
        XCTAssertEqual(tree.selectedOperationPaths, [b.path])
        tree.select(compact, componentPath: c.path)
        XCTAssertEqual(tree.selectedDirectoryPath, c.path)

        for (dir, name) in [(c.path, "in-c.swift"), (b.path, "in-b.swift"), (a.path, "in-a.swift")] {
            await tree.beginNewFile(in: dir)
            let result = await tree.commitDraft(name: name)
            XCTAssertEqual(result, (dir as NSString).appendingPathComponent(name))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result!))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.appendingPathComponent("in-a.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.appendingPathComponent("in-b.swift").path))
    }

    func testCompactFolderRenameAndDragTargetAncestorsWithoutUnfoldState() async throws {
        let root = fixture.appendingPathComponent("compact-edit")
        let a = root.appendingPathComponent("a1")
        let b = a.appendingPathComponent("b1")
        let c = b.appendingPathComponent("c1")
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        try Data().write(to: c.appendingPathComponent("leaf.swift"))
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        for path in [a.path, b.path, c.path] {
            await tree.toggle(try XCTUnwrap(tree.items.first { $0.path == path }))
        }
        let compact = try XCTUnwrap(tree.items.first { $0.path == c.path })
        let ancestor = compact.item(for: compact.compactComponents[0])
        let drag = try XCTUnwrap(tree.beginDrag(for: ancestor))
        XCTAssertEqual(drag.paths, [a.path])
        XCTAssertTrue(tree.consumeDrag(nonce: drag.nonce, paths: drag.paths))

        let other = fixture.appendingPathComponent("compact-other-root")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        await tree.sync(root: other.path, backend: backend)
        await tree.sync(root: root.path, backend: backend)
        XCTAssertEqual(tree.items.filter(\.isDirectory).map(\.displayName),
                       ["a1 / b1 / c1"], "Compaction must survive switching back to the project")

        tree.beginRename(ancestor)
        try await waitForCondition("Renaming an intermediate folder must reveal the real row") {
            tree.items.contains { $0.path == a.path }
        }
        let renamed = await tree.rename(ancestor, to: "renamed-a1")
        let destination = root.appendingPathComponent("renamed-a1")
        XCTAssertEqual(renamed, destination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("b1/c1/leaf.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }

    func testFirstLoadDoesNotReadCollapsedSiblingFolders() async throws {
        let root = fixture.appendingPathComponent("siblings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = (0..<12).map { root.appendingPathComponent("dir\($0)") }
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("content.txt"))
        }
        let counting = CountingFileBackend()
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: counting)
        XCTAssertEqual(tree.items.filter(\.isDirectory).count, folders.count)
        let batch = await counting.lastBatch
        XCTAssertEqual(batch, [root.path], "Cold tree must query only the root")
        let initialReads = await counting.requests
        XCTAssertEqual(initialReads, [root.path: 1])
        let first = try XCTUnwrap(tree.items.first { $0.path == folders[0].path })
        await tree.toggle(first)
        let afterClick = await counting.requests
        XCTAssertEqual(afterClick[folders[0].path], 1)
        XCTAssertTrue(folders.dropFirst().allSatisfy { afterClick[$0.path] == nil },
                      "Siblings remain unloaded until clicked")
    }

    func testSharedTreeStatusAndCompaction() {
        let statuses: [(Character, TreeDisplayModel.Status)] = [
            ("M", .modified), ("A", .added), ("?", .untracked), ("D", .deleted),
            ("R", .renamed), ("C", .copied), ("U", .conflict), ("!", .ignored), ("T", .changed),
        ]
        let rows = statuses.map { character, status -> TreeDisplayModel.Row in
            XCTAssertEqual(TreeDisplayModel.Status(character), status)
            return TreeDisplayModel.Row(
                name: "\(character).swift",
                path: "dir/renamed/\(character).swift",
                isDirectory: false,
                status: status
            )
        }
        let display = TreeDisplayModel.pathRows(rows, section: "unstaged", collapsed: [])
        XCTAssertEqual(display.first?.displayName, "dir / renamed")
        XCTAssertEqual(display.first?.depth, 0)
        XCTAssertTrue(display.dropFirst().allSatisfy { !$0.isDirectory && $0.depth == 1 })

        let boundary = ["dir/a.swift", "dir/sub/deep/b.swift", "file10.swift", "file2.swift"].map {
            TreeDisplayModel.Row(name: ($0 as NSString).lastPathComponent, path: $0, isDirectory: false)
        }
        XCTAssertEqual(
            TreeDisplayModel.pathRows(boundary, section: "boundary", collapsed: []).map(\.displayName),
            ["dir", "sub / deep", "b.swift", "a.swift", "file2.swift", "file10.swift"]
        )
    }
}
