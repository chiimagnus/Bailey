import Foundation
import XCTest
@testable import Bailey

private actor CountingLiveSSHRunner: RemoteCommandRunner {
    let base: SSHHostCommandRunner
    private(set) var calls = 0

    init(host: String, socket: String) {
        base = SSHHostCommandRunner(host: host, socket: socket)
    }

    func run(_ argv: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> (status: Int32, stdout: Data, stderr: Data)
    {
        calls += 1
        return try await base.run(argv, stdin: stdin, timeout: timeout)
    }

    func runLimited(_ argv: [String], stdin: Data?, timeout: TimeInterval,
                    stdoutLimit: Int, stderrLimit: Int) async throws
        -> (status: Int32, stdout: Data, stderr: Data)
    {
        calls += 1
        return try await base.runLimited(argv, stdin: stdin, timeout: timeout,
                                         stdoutLimit: stdoutLimit, stderrLimit: stderrLimit)
    }
}

@MainActor
final class SSHFileTreeLiveTests: XCTestCase {
    func testAuthorizedWindowsSSHBatchDirectoryListingAndIndependentFailures() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST to an explicitly authorized SSH test host")
        }
        let socket = "/tmp/bailey-files-\(UUID().uuidString.prefix(8)).sock"
        let runner = CountingLiveSSHRunner(host: host, socket: socket)
        let backend = SSHWorkspaceBackend(runner: runner, timeout: 25)
        let result = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-files-batch-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
        let root = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("bailey-files-batch-") else {
            throw WorkspaceError.notFound
        }
        func cleanup() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Could not delete test-owned remote folder: \(error)") }
            do {
                let closed = try await Task.detached {
                    try ProcessRemoteCommandRunner.launch(
                        sshPath: "/usr/bin/ssh", arguments: ["-S", socket, "-O", "exit", host],
                        stdin: nil, timeout: 10
                    )
                }.value
                XCTAssertEqual(closed.status, 0)
            } catch { XCTFail("Could not close test-owned SSH socket: \(error)") }
        }
        do {
            let one = root + "/dir' one"
            let two = root + "/unicode-二"
            try await backend.createDirectory(path: one)
            try await backend.createDirectory(path: two)
            try await backend.createFile(path: one + "/a file.txt")
            try await backend.createFile(path: two + "/b.txt")
            let missing = root + "/missing"
            let initial = try await backend.list(directory: root)
            XCTAssertEqual(Set(initial.map(\.name)), ["dir' one", "unicode-二"])
            let batch = await backend.list(directories: [root, one, missing, two])
            XCTAssertEqual(Set(batch[root]?.map(\.name) ?? []), Set(initial.map(\.name)))
            XCTAssertEqual(batch[one]?.map(\.name), ["a file.txt"])
            XCTAssertEqual(batch[two]?.map(\.name), ["b.txt"])
            XCTAssertNil(batch[missing], "A missing directory must not erase adjacent results")

            // A cold tree must not inspect unopened siblings or compact chains.
            let siblings = (1...12).map { root + "/sibling-\($0)" }
            for directory in siblings { try await backend.createDirectory(path: directory) }
            let deep = root + "/deep"
            let step1 = deep + "/step1"
            let step2 = step1 + "/step2"
            for path in [deep, step1, step2] {
                try await backend.createDirectory(path: path)
            }
            try await backend.createFile(path: step2 + "/leaf.txt")
            let tree = FileTreeModel()
            let beforeCold = await runner.calls
            await tree.sync(root: root, backend: backend, scope: "ssh:windows-live")
            let coldRequests = await runner.calls - beforeCold
            XCTAssertEqual(coldRequests, 1, "Cold tree must only read the root directory")
            XCTAssertNotNil(tree.items.first { $0.path == deep })
            XCTAssertNil(tree.items.first { $0.path == step1 })
            let folder = try XCTUnwrap(tree.items.first { $0.path == one })
            let beforeToggle = await runner.calls
            await tree.toggle(folder)
            XCTAssertTrue(tree.items.contains { $0.path == one + "/a file.txt" })
            await tree.toggle(folder)
            let toggleRequests = await runner.calls
            XCTAssertEqual(toggleRequests, beforeToggle + 1,
                           "First expansion reads exactly one folder; collapse is cached")

            let beforeDeep = await runner.calls
            let first = try XCTUnwrap(tree.items.first { $0.path == deep })
            await tree.toggle(first)
            XCTAssertEqual(tree.items.first { $0.path == deep }?.isExpanded, true)
            XCTAssertEqual(tree.items.first { $0.path == step1 }?.displayName, "step1")
            let afterFirst = await runner.calls
            XCTAssertEqual(afterFirst, beforeDeep + 1)
            let second = try XCTUnwrap(tree.items.first { $0.path == step1 })
            await tree.toggle(second)
            XCTAssertEqual(tree.items.first { $0.path == step1 }?.displayName, "deep / step1")
            XCTAssertEqual(tree.items.first { $0.path == step2 }?.displayName, "step2")
            let afterSecond = await runner.calls
            XCTAssertEqual(afterSecond, afterFirst + 1)
            XCTAssertNil(tree.items.first { $0.path == step2 + "/leaf.txt" })
            let third = try XCTUnwrap(tree.items.first { $0.path == step2 })
            await tree.toggle(third)
            XCTAssertEqual(tree.items.first { $0.path == step2 }?.displayName,
                           "deep / step1 / step2")
            XCTAssertNotNil(tree.items.first { $0.path == step2 + "/leaf.txt" })
            let afterThird = await runner.calls
            XCTAssertEqual(afterThird, afterSecond + 1,
                           "Only the clicked compact path should trigger a new SSH query")

            let beforeRefresh = await runner.calls
            await tree.sync(root: root, backend: backend, scope: "ssh:windows-live")
            let refreshRequests = await runner.calls - beforeRefresh
            XCTAssertEqual(refreshRequests, 1,
                           "Refreshing already visited directories must remain batched")

            // Run only when explicitly requested: 30 hot samples per method,
            // identical folders and test-owned SSH master. This measures the
            // remote read operation, not end-to-end SwiftUI responsiveness.
            if ProcessInfo.processInfo.environment["BAILEY_SSH_BENCHMARK"] == "1" {
                var individualSamples: [Double] = []
                var batchSamples: [Double] = []
                for index in 0..<30 {
                    func measureIndividual() async throws -> Double {
                        let start = ProcessInfo.processInfo.systemUptime
                        _ = try await backend.list(directory: one)
                        _ = try await backend.list(directory: two)
                        return ProcessInfo.processInfo.systemUptime - start
                    }
                    func measureBatch() async -> Double {
                        let start = ProcessInfo.processInfo.systemUptime
                        _ = await backend.list(directories: [one, two])
                        return ProcessInfo.processInfo.systemUptime - start
                    }
                    if index.isMultiple(of: 2) {
                        individualSamples.append(try await measureIndividual())
                        batchSamples.append(await measureBatch())
                    } else {
                        batchSamples.append(await measureBatch())
                        individualSamples.append(try await measureIndividual())
                    }
                }
                func summarize(_ name: String, _ samples: [Double]) {
                    let sorted = samples.sorted()
                    print(String(format: "BAILEY_SSH_BENCHMARK %@ n=%d median=%.3fs p95=%.3fs max=%.3fs",
                                 name, sorted.count, (sorted[14] + sorted[15]) / 2,
                                 sorted[28], sorted[29]))
                }
                summarize("individual-2-dirs", individualSamples)
                summarize("batch-2-dirs", batchSamples)

                // Real Windows directory capacity; fixture creation is one command.
                let capacity = 6_000
                let created = try await backend.run(
                    argv: ["/bin/sh", "-c",
                           "set -e; seq -f 'scale-%06g.txt' 1 6000 | xargs -n 250 touch"],
                    cwd: one, env: nil, stdin: nil, timeout: 120
                )
                XCTAssertEqual(created.status, 0, String(decoding: created.stderr, as: UTF8.self))
                let listing = try await backend.list(directory: one)
                XCTAssertEqual(listing.count, capacity + 1)
                let refreshed = await tree.sync(root: root, backend: backend, scope: "ssh:windows-live")
                XCTAssertTrue(refreshed)
                var coldSamples: [Double] = []
                var toggleSamples: [Double] = []
                var refreshSamples: [Double] = []
                for _ in 0..<5 {
                    let fresh = FileTreeModel()
                    let start = ProcessInfo.processInfo.systemUptime
                    let loaded = await fresh.sync(root: root, backend: backend, scope: "ssh:windows-live")
                    XCTAssertTrue(loaded)
                    let directory = try XCTUnwrap(fresh.items.first { $0.path == one })
                    await fresh.toggle(directory)
                    XCTAssertEqual(fresh.items.filter { $0.path.hasPrefix(one + "/") }.count, capacity + 1)
                    coldSamples.append(ProcessInfo.processInfo.systemUptime - start)
                }
                let beforeWarmToggle = await runner.calls
                for _ in 0..<30 {
                    let start = ProcessInfo.processInfo.systemUptime
                    await tree.toggle(folder)
                    XCTAssertEqual(tree.items.filter { $0.path.hasPrefix(one + "/") }.count, capacity + 1)
                    await tree.toggle(folder)
                    XCTAssertFalse(tree.items.contains { $0.path.hasPrefix(one + "/") })
                    toggleSamples.append(ProcessInfo.processInfo.systemUptime - start)
                }
                let requestsAfterWarmToggle = await runner.calls
                XCTAssertEqual(requestsAfterWarmToggle, beforeWarmToggle)
                for _ in 0..<30 {
                    let start = ProcessInfo.processInfo.systemUptime
                    await tree.sync(root: root, backend: backend, scope: "ssh:windows-live")
                    refreshSamples.append(ProcessInfo.processInfo.systemUptime - start)
                }
                let coldSorted = coldSamples.sorted()
                print(String(format: "BAILEY_SSH_BENCHMARK cold-6001-file-folder n=5 median=%.3fs max=%.3fs",
                             coldSorted[2], coldSorted[4]))
                summarize("warm-6001-file-folder-toggle", toggleSamples)
                summarize("large-tree-refresh", refreshSamples)
            }
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    func testAuthorizedWindowsSSHCopyMoveAndDeletePreserveRealDiskContents() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Requires an explicitly authorized SSH test host")
        }
        let socket = "/tmp/bailey-p1-\(UUID().uuidString.prefix(8)).sock"
        let backend = SSHWorkspaceBackend(
            runner: SSHHostCommandRunner(host: host, socket: socket), timeout: 25
        )
        let created = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-p1-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(created.status, 0, String(decoding: created.stderr, as: UTF8.self))
        let root = String(decoding: created.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("bailey-p1-") else {
            throw WorkspaceError.notFound
        }
        func cleanup() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Could not remove test-owned SSH folder: \(error)") }
            do {
                let closed = try await Task.detached {
                    try ProcessRemoteCommandRunner.launch(
                        sshPath: "/usr/bin/ssh", arguments: ["-S", socket, "-O", "exit", host],
                        stdin: nil, timeout: 10
                    )
                }.value
                XCTAssertEqual(closed.status, 0)
            } catch { XCTFail("Could not close test-owned SSH channel: \(error)") }
        }
        do {
            let source = root + "/源' 文件.bin"
            let destinationDir = root + "/destination"
            let copy = destinationDir + "/copy.bin"
            let moved = destinationDir + "/源' 文件.bin"
            let bytes = Data([0, 255, 10, 0, 128, 39])
            try await backend.createDirectory(path: destinationDir)
            try await backend.write(path: source, data: bytes)
            try await backend.copy(from: source, to: copy)
            let copiedBytes = try await backend.read(path: copy, maxBytes: 64)
            let sourceBytes = try await backend.read(path: source, maxBytes: 64)
            XCTAssertEqual(copiedBytes, bytes)
            XCTAssertEqual(sourceBytes, bytes)
            do {
                try await backend.copy(from: source, to: copy)
                XCTFail("An occupied SSH target must not be overwritten")
            } catch {}
            let preservedBytes = try await backend.read(path: copy, maxBytes: 64)
            XCTAssertEqual(preservedBytes, bytes)

            let tree = FileTreeModel()
            let listed = await tree.sync(root: root, backend: backend, scope: "ssh:windows-live")
            XCTAssertTrue(listed)
            let folder = try XCTUnwrap(tree.items.first { $0.path == destinationDir })
            await tree.toggle(folder)
            tree.select(try XCTUnwrap(tree.items.first { $0.path == source }))
            let move = await tree.performFileOperation(.move, paths: [source], into: destinationDir)
            XCTAssertTrue(move.failures.isEmpty, move.failures.joined(separator: "\n"))
            XCTAssertEqual(move.succeeded.first?.destination, moved)
            XCTAssertEqual(tree.selectedPath, moved)
            XCTAssertEqual(tree.selectedPaths, [moved])
            let oldStat = try await backend.stat(path: source)
            let movedBytes = try await backend.read(path: moved, maxBytes: 64)
            XCTAssertNil(oldStat)
            XCTAssertEqual(movedBytes, bytes)
            let deletion = await tree.performFileOperation(.delete, paths: [moved], into: nil)
            XCTAssertTrue(deletion.failures.isEmpty, deletion.failures.joined(separator: "\n"))
            XCTAssertEqual(deletion.succeeded.map(\.source), [moved])
            XCTAssertEqual(tree.selectedPath, destinationDir)
            XCTAssertTrue(tree.selectedPaths.isEmpty)
            let deletedStat = try await backend.stat(path: moved)
            let remainingBytes = try await backend.read(path: copy, maxBytes: 64)
            XCTAssertNil(deletedStat)
            XCTAssertEqual(remainingBytes, bytes)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    func testAuthorizedWindowsSSHRenamePreservesActualDirectoryEntries() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Requires an explicitly authorized Windows SSH host")
        }
        let socket = "/tmp/bailey-rename-\(UUID().uuidString.prefix(8)).sock"
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket), timeout: 25)
        let created = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-rename-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(created.status, 0, String(decoding: created.stderr, as: UTF8.self))
        let root = String(decoding: created.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("bailey-rename-") else {
            throw WorkspaceError.notFound
        }
        func cleanup() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Could not remove test-owned folder: \(error)") }
            do {
                let closed = try await Task.detached {
                    try ProcessRemoteCommandRunner.launch(
                        sshPath: "/usr/bin/ssh", arguments: ["-S", socket, "-O", "exit", host],
                        stdin: nil, timeout: 10
                    )
                }.value
                XCTAssertEqual(closed.status, 0)
            } catch { XCTFail("Could not close test SSH socket: \(error)") }
        }
        do {
            let source = root + "/source' 中文.txt"
            let moved = root + "/moved' 中文.txt"
            try await backend.createFile(path: source)
            try await backend.write(path: source, data: Data("keep source".utf8))
            try await backend.rename(from: source, to: moved)
            let oldStat = try await backend.stat(path: source)
            XCTAssertNil(oldStat)
            let movedContents = try await backend.read(path: moved, maxBytes: 256)
            XCTAssertEqual(String(decoding: movedContents, as: UTF8.self), "keep source")

            let occupied = root + "/occupied.txt"
            try await backend.createFile(path: occupied)
            try await backend.write(path: occupied, data: Data("keep destination".utf8))
            do {
                try await backend.rename(from: moved, to: occupied)
                XCTFail("Cannot replace an occupied remote destination")
            } catch {}
            let sourceAfterCollision = try await backend.read(path: moved, maxBytes: 256)
            let destinationAfterCollision = try await backend.read(path: occupied, maxBytes: 256)
            XCTAssertEqual(String(decoding: sourceAfterCollision, as: UTF8.self), "keep source")
            XCTAssertEqual(String(decoding: destinationAfterCollision, as: UTF8.self), "keep destination")

            let sourceFolder = root + "/source-folder"
            let occupiedFolder = root + "/occupied-folder"
            try await backend.createDirectory(path: sourceFolder)
            try await backend.createDirectory(path: occupiedFolder)
            try await backend.createFile(path: sourceFolder + "/nested.txt")
            do {
                try await backend.rename(from: sourceFolder, to: occupiedFolder)
                XCTFail("A real remote folder cannot be moved into an occupied target folder")
            } catch {}
            let sourceFolderAfter = try await backend.list(directory: sourceFolder)
            let occupiedFolderAfter = try await backend.list(directory: occupiedFolder)
            XCTAssertEqual(sourceFolderAfter.map(\.name), ["nested.txt"])
            XCTAssertTrue(occupiedFolderAfter.isEmpty)

            let hardlink = root + "/hardlink.txt"
            let hardlinkResult = try await backend.run(argv: ["ln", moved, hardlink],
                                                       cwd: nil, env: nil, stdin: nil, timeout: 25)
            if hardlinkResult.status == 0 {
                do {
                    try await backend.rename(from: moved, to: hardlink)
                    XCTFail("Identical inode does not permit removing a different hard link")
                } catch {}
                let sourceStat = try await backend.stat(path: moved)
                let hardlinkStat = try await backend.stat(path: hardlink)
                XCTAssertNotNil(sourceStat)
                XCTAssertNotNil(hardlinkStat)
            } else {
                print("P4_LIVE_HARDLINK_UNAVAILABLE status=\(hardlinkResult.status)")
            }

            let missing = root + "/nonexistent"
            let dangling = root + "/dangling"
            let symlinkResult = try await backend.run(argv: ["ln", "-s", missing, dangling],
                                                      cwd: nil, env: nil, stdin: nil, timeout: 25)
            if symlinkResult.status == 0 {
                let link = try await backend.stat(path: dangling)
                if link?.isSymlink == true {
                    let renamed = root + "/renamed-dangling"
                    try await backend.rename(from: dangling, to: renamed)
                    let target = try await backend.readSymlinkDestination(path: renamed)
                    XCTAssertEqual(target, missing)
                    let collision = root + "/collision"
                    try await backend.createFile(path: collision)
                    do {
                        try await backend.rename(from: collision, to: renamed)
                        XCTFail("An existing dangling symlink must not be overwritten")
                    } catch {}
                    let afterCollision = try await backend.stat(path: collision)
                    XCTAssertNotNil(afterCollision)
                } else {
                    print("P4_LIVE_SYMLINK_NOT_NATIVE")
                }
            } else {
                print("P4_LIVE_SYMLINK_UNAVAILABLE status=\(symlinkResult.status)")
            }

            let lower = root + "/lower-case.txt"
            let upper = root + "/LOWER-CASE.TXT"
            try await backend.createFile(path: lower)
            if try await backend.stat(path: upper) != nil {
                try await backend.rename(from: lower, to: upper)
                let names = try await backend.list(directory: root).map(\.name)
                XCTAssertTrue(names.contains("LOWER-CASE.TXT"))
                XCTAssertFalse(names.contains("lower-case.txt"))
            } else {
                print("P4_LIVE_CASE_SENSITIVE_VOLUME")
            }
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    func testAuthorizedWindowsCSVRebindConfirmsActualPublishedBytes() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST to an explicitly authorized SSH test host")
        }
        let id = UUID().uuidString.prefix(8)
        let oldSocket = "/tmp/bailey-ack-a-\(id).sock"
        let newSocket = "/tmp/bailey-ack-b-\(id).sock"
        let runner = PublicationAcknowledgementRunner(host: host, socket: oldSocket)
        let backend = SSHWorkspaceBackend(runner: runner, timeout: 25)
        let live = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: newSocket), timeout: 25)
        try await withPublicationSSHFixture(host: host, backend: backend, sockets: [oldSocket, newSocket],
                                            prefix: "bailey-text-ack") { root in
            let path = root + "/数据.csv"
            let initial = try XCTUnwrap(TextFileEncoding.utf8BOM.encoded("Name,Value\r\n中文,000\nOther,\"literal\""))
            try await backend.write(path: path, data: initial)
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: root) }
            let local = URL(fileURLWithPath: path)
            let sentinel = Data("Mac-only sentinel".utf8)
            try sentinel.write(to: local)
            let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:\(host)")
            defer { file.retireContent() }
            try await file.waitForText()
            XCTAssertEqual(file.fileEncoding, .utf8BOM)
            func edit(_ row: Int, _ value: String) async throws {
                let result = try await file.delimitedSnapshot(using: .comma)
                let snapshot = try XCTUnwrap(result)
                try await requireDelimitedEdit(file, .cells([.init(row: row, column: 1): value]), using: snapshot)
            }
            try await edit(1, "111")
            let written = try XCTUnwrap(TextFileEncoding.utf8BOM.encoded(file.text))
            // The underlying SSH command and atomic remote publication are
            // real. Only the acknowledgement is deliberately suppressed.
            await runner.loseNextAcknowledgement {
                await MainActor.run { file.rebindWorkspace(to: nil) }
            }
            await file.save()
            XCTAssertTrue(file.isDirty)
            XCTAssertNotNil(file.readOnlyReason)
            let remote = try await live.read(path: path, maxBytes: written.count)
            XCTAssertEqual(remote, written)
            file.rebindWorkspace(to: live)
            try await edit(2, "next,field")
            let expected = try XCTUnwrap(TextFileEncoding.utf8BOM.encoded(file.text))
            await file.save()
            XCTAssertFalse(file.isDirty)
            XCTAssertNil(file.saveError)
            let saved = try await live.read(path: path, maxBytes: expected.count)
            XCTAssertEqual(saved, expected)
            XCTAssertEqual(file.text, "Name,Value\r\n中文,111\nOther,\"next,field\"")
            XCTAssertEqual(try Data(contentsOf: local), sentinel)
            let reopened = FileTab(path: path, backend: live, workspaceIdentity: "ssh:\(host)")
            defer { reopened.retireContent() }
            try await reopened.waitForText()
            XCTAssertEqual(reopened.fileEncoding, .utf8BOM)
            XCTAssertEqual(reopened.text, file.text)
            let structure = try await file.delimitedSnapshot(using: .comma)
            try await requireDelimitedEdit(file, .columns([1, 0]), using: XCTUnwrap(structure))
            await file.save()
            let moved = try XCTUnwrap(TextFileEncoding.utf8BOM.encoded("Value,Name\r\n111,中文\n\"next,field\",Other"))
            let movedRemote = try await live.read(path: path, maxBytes: moved.count)
            XCTAssertEqual(movedRemote, moved)
            XCTAssertEqual(try Data(contentsOf: local), sentinel)
            file.documentUndoManager.undo()
            await file.save()
            let undoRemote = try await live.read(path: path, maxBytes: expected.count)
            XCTAssertEqual(undoRemote, expected)
            let replacementSnapshot = try await file.delimitedSnapshot(using: .comma)
            let dataFields = DelimitedTablePresentation.FieldScope(rows: nil, firstRecord: 1,
                                                                   columns: IndexSet(integer: 1), selection: nil)
            try await requireDelimitedEdit(file, .replace(dataFields, query: "NEXT", with: "remote", single: nil),
                                           using: XCTUnwrap(replacementSnapshot))
            await file.save()
            let replaced = try XCTUnwrap(TextFileEncoding.utf8BOM.encoded("Name,Value\r\n中文,111\nOther,\"remote,field\""))
            let replacedRemote = try await live.read(path: path, maxBytes: replaced.count)
            XCTAssertEqual(replacedRemote, replaced)
            XCTAssertEqual(try Data(contentsOf: local), sentinel)
        }
    }

    func testAuthorizedWindowsReviewedCSVConflictRejectsExternalRevisionAndOldChannel() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST to an explicitly authorized SSH test host")
        }
        let id = UUID().uuidString.prefix(8)
        let socket = "/tmp/bailey-review-a-\(id).sock"
        let rivalSocket = "/tmp/bailey-review-b-\(id).sock"
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket), timeout: 25)
        let rival = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: rivalSocket), timeout: 25)
        try await withPublicationSSHFixture(host: host, backend: rival, sockets: [socket, rivalSocket],
                                            prefix: "bailey-review-csv") { root in
            let path = root + "/数据.csv"
            let base = "Name,Value\r\n中文,old\n"
            let external = "Name,Value\r\n中文,ext\n"
            let newer = "Name,Value\r\n中文,two\n"
            let draft = "Name,Value\r\n中文,new\n"
            let encoding = TextFileEncoding.utf8BOM
            let baseline = try XCTUnwrap(encoding.encoded(base))
            let externalBytes = try XCTUnwrap(encoding.encoded(external))
            let newerBytes = try XCTUnwrap(encoding.encoded(newer))
            let draftBytes = try XCTUnwrap(encoding.encoded(draft))
            try await backend.write(path: path, data: baseline)
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: root) }
            let local = URL(fileURLWithPath: path)
            let sentinel = Data("Mac-only sentinel".utf8)
            try sentinel.write(to: local)
            let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:\(host)")
            defer { file.retireContent() }
            try await file.waitForText()
            file.autoSaveSuspendedForClose = true
            XCTAssertEqual(file.fileEncoding, encoding)
            let loaded = try await file.delimitedSnapshot(using: .comma)
            try await requireDelimitedEdit(file, .cells([.init(row: 1, column: 1): "new"]), using: XCTUnwrap(loaded))
            XCTAssertEqual(file.text, draft)

            // This shell deliberately does not use Bailey's publication lock.
            // Preserve both length and mtime on the actual Windows file.
            let beforeStat = try await rival.stat(path: path)
            let before = try XCTUnwrap(beforeStat)
            let result = try await rival.run(argv: [
                "sh", "-c", "set -eu; cp -p -- \"$1\" \"$2\"; cat > \"$1\"; touch -r \"$2\" \"$1\"; rm -- \"$2\"",
                "_", path, root + "/mtime"
            ], cwd: nil, env: nil, stdin: externalBytes, timeout: 25)
            XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
            let afterStat = try await rival.stat(path: path)
            let after = try XCTUnwrap(afterStat)
            XCTAssertEqual(before.size, after.size)
            XCTAssertEqual(before.mtime, after.mtime)
            await file.save()
            XCTAssertTrue(file.isDirty)
            XCTAssertTrue(file.canCompareSaveConflict)
            let first = try await file.compareSaveConflict()
            XCTAssertEqual(first.diskVersion, WorkspaceFileVersion(data: externalBytes))
            XCTAssertEqual(first.draftVersion, WorkspaceFileVersion(data: draftBytes))
            XCTAssertTrue(first.review.text.contains("中文,ext"))
            XCTAssertTrue(first.review.text.contains("中文,new"))
            let unchanged = try await rival.read(path: path, maxBytes: externalBytes.count)
            XCTAssertEqual(unchanged, externalBytes, "Comparing without confirming never writes")
            print("REVIEW_CSV_LIVE same-size and mtime conflict verified")
            // An independently launched remote shell publishes a different revision.
            let changed = try await rival.run(argv: ["sh", "-c", "cat > \"$1\"", "_", path],
                                              cwd: nil, env: nil, stdin: newerBytes, timeout: 25)
            XCTAssertEqual(changed.status, 0)
            do {
                try await file.resolveSaveConflict(first)
                XCTFail("Old comparison must not replace a later remote revision")
            } catch WorkspaceError.changedExternally {}
            let retained = try await rival.read(path: path, maxBytes: newerBytes.count)
            XCTAssertEqual(retained, newerBytes)
            XCTAssertTrue(file.isDirty)
            XCTAssertEqual(file.text, draft)
            print("REVIEW_CSV_LIVE stale disk confirmation rejected")
            let oldChannel = try await file.compareSaveConflict()
            let exited = try await Task.detached {
                try ProcessRemoteCommandRunner.launch(sshPath: "/usr/bin/ssh",
                    arguments: ["-S", socket, "-O", "exit", host], stdin: nil, timeout: 10)
            }.value
            XCTAssertEqual(exited.status, 0)
            file.rebindWorkspace(to: nil)
            XCTAssertFalse(file.canCompareSaveConflict)
            file.rebindWorkspace(to: rival)
            do {
                try await file.resolveSaveConflict(oldChannel)
                XCTFail("Approval from the closed channel must expire")
            } catch WorkspaceError.changedExternally {}
            print("REVIEW_CSV_LIVE old channel approval rejected")
            let fresh = try await file.compareSaveConflict()
            XCTAssertEqual(fresh.diskVersion, WorkspaceFileVersion(data: newerBytes))
            try await file.resolveSaveConflict(fresh)
            let stored = try await rival.read(path: path, maxBytes: draftBytes.count)
            XCTAssertEqual(stored, draftBytes)
            XCTAssertFalse(file.isDirty)
            XCTAssertNil(file.saveError)
            XCTAssertEqual(try Data(contentsOf: local), sentinel)
            let reopened = FileTab(path: path, backend: rival, workspaceIdentity: "ssh:\(host)")
            defer { reopened.retireContent() }
            try await reopened.waitForText()
            XCTAssertEqual(reopened.text, draft)
            XCTAssertEqual(reopened.fileEncoding, encoding)
            let remaining = try await rival.list(directory: root)
            XCTAssertEqual(remaining.map(\.name), ["数据.csv"])
        }
    }

    func testAuthorizedWindowsSSHFileTabCapacityAndBytePreservingSave() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST to an explicitly authorized SSH test host")
        }
        let socket = "/tmp/bailey-cap-\(UUID().uuidString.prefix(8)).sock"
        let runner = CountingLiveSSHRunner(host: host, socket: socket)
        let backend = SSHWorkspaceBackend(runner: runner, timeout: 25)
        let created = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-editor-cap-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(created.status, 0, String(decoding: created.stderr, as: UTF8.self))
        let root = String(decoding: created.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("bailey-editor-cap-") else {
            throw WorkspaceError.notFound
        }
        func cleanup() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Could not clean up test-owned remote fixture: \(error)") }
            do {
                let exited = try await Task.detached {
                    try ProcessRemoteCommandRunner.launch(
                        sshPath: "/usr/bin/ssh",
                        arguments: ["-S", socket, "-O", "exit", host], stdin: nil, timeout: 10
                    )
                }.value
                XCTAssertEqual(exited.status, 0)
            } catch { XCTFail("Could not close test-owned SSH socket: \(error)") }
        }
        do {
            let limit = 32 << 20
            let emoji = Data("👋".utf8)
            let exact = Data(repeating: 0x41, count: limit - emoji.count) + emoji
            let path = root + "/代码' boundary.swift"
            print("EDITOR_CAP_LIVE beginning 32 MiB transfer")
            try await backend.write(path: path, data: exact)
            print("EDITOR_CAP_LIVE finished 32 MiB upload")
            let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:\(host)")
            try await file.waitForText()
            print("EDITOR_CAP_LIVE finished 32 MiB download")
            XCTAssertEqual(Data(file.text.utf8), exact)

            var revised = file.text
            revised.replaceSubrange(revised.startIndex...revised.startIndex, with: "Z")
            file.text = revised
            file.refreshDirtyState()
            await file.save()
            XCTAssertFalse(file.isDirty)
            let onDisk = try await backend.read(path: path, maxBytes: limit)
            XCTAssertEqual(onDisk, Data(file.text.utf8))
            let reopened = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:\(host)")
            try await reopened.waitForText()
            XCTAssertEqual(reopened.text, revised)

            let overflowing = root + "/too-large.swift"
            try await backend.write(path: overflowing, data: exact + Data([0x21]))
            let rejected = FileTab(path: overflowing, backend: backend, workspaceIdentity: "ssh:\(host)")
            do { try await rejected.waitForText(); XCTFail("Remote 32 MiB + 1 must be rejected") }
            catch {
                guard case .unavailable = rejected.content else { return XCTFail("Expected capacity placeholder") }
            }
            let binaryPath = root + "/binary.swift"
            try await backend.write(path: binaryPath, data: Data([0x41, 0x00, 0x42]))
            let binary = FileTab(path: binaryPath, backend: backend, workspaceIdentity: "ssh:\(host)")
            do { try await binary.waitForText(); XCTFail("NUL binary must be rejected") }
            catch {
                guard case .unavailable = binary.content else { return XCTFail("Expected binary placeholder") }
            }
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}
