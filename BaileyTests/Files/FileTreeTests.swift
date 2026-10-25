import AppKit
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
    func copy(from: String, to: String) async throws { try await base.copy(from: from, to: to) }
    func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    func delete(paths: [String]) async throws { try await base.delete(paths: paths) }
    func gitRoot(containing path: String) async throws -> String? { try await base.gitRoot(containing: path) }
    func isLinkedWorktree(_ root: String) async throws -> Bool { try await base.isLinkedWorktree(root) }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        try await base.run(argv: argv, cwd: cwd, env: env, stdin: stdin, timeout: timeout)
    }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot { try await base.processes(descendantsOf: pid) }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { try await base.listeningPorts(pids: pids) }
    func kill(pid: pid_t, force: Bool) async throws { try await base.kill(pid: pid, force: force) }
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
            model: tree, git: GitStatusModel(), session: nil, sshHost: nil,
            rootBadge: nil, currentFilePath: nil,
            openFile: { _, _ in opened += 1 },
            renameFile: { item, name in await tree.rename(item, to: name) },
            deleteFile: { item in
                let result = await tree.performFileOperation(.delete, paths: [item.path], into: nil)
                return !result.succeeded.isEmpty
            },
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
            model: tree, git: GitStatusModel(), session: nil, sshHost: nil,
            rootBadge: nil, currentFilePath: second.path,
            openFile: { _, _ in opened += 1 },
            renameFile: { item, name in await tree.rename(item, to: name) },
            deleteFile: { item in
                let result = await tree.performFileOperation(.delete, paths: [item.path], into: nil)
                return !result.succeeded.isEmpty
            },
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
        let compact = try XCTUnwrap(tree.items.first { $0.path == nested.path })
        XCTAssertEqual(compact.displayName, "dir / inner")
        await tree.toggle(compact)
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
        await tree.toggle(folder)
        XCTAssertTrue(tree.items.contains { $0.path == sub.appendingPathComponent("child.txt").path })
        let readsAfterExpansion = await counting.requests
        XCTAssertEqual(readsAfterExpansion, readsAfterInitial, "Expansion reuses the compaction lookahead")
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
        await counting.delay(first.path)
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

    func testFirstLoadBatchesSiblingFolderLookahead() async throws {
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
        XCTAssertEqual(Set(batch ?? []), Set(folders.map(\.path)),
                       "Initial directory compression must not perform one SSH request per sibling")
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
