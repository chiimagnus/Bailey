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

            // Cold tree traversal must batch the root and its entire sibling
            // lookahead; expanding a cached folder must not contact SSH.
            let siblings = (1...12).map { root + "/sibling-\($0)" }
            for directory in siblings { try await backend.createDirectory(path: directory) }
            let tree = FileTreeModel()
            let beforeCold = await runner.calls
            await tree.sync(root: root, backend: backend, scope: "ssh:windows-live")
            let coldRequests = await runner.calls - beforeCold
            XCTAssertEqual(coldRequests, 2,
                           "Cold tree must use one root read and one sibling batch")
            let folder = try XCTUnwrap(tree.items.first { $0.path == one })
            let beforeToggle = await runner.calls
            await tree.toggle(folder)
            XCTAssertTrue(tree.items.contains { $0.path == one + "/a file.txt" })
            await tree.toggle(folder)
            let toggleRequests = await runner.calls
            XCTAssertEqual(toggleRequests, beforeToggle,
                           "Warm folder expansion and collapse must make zero SSH requests")
            let beforeRefresh = await runner.calls
            await tree.sync(root: root, backend: backend, scope: "ssh:windows-live")
            let refreshRequests = await runner.calls - beforeRefresh
            XCTAssertEqual(refreshRequests, 1,
                           "Refreshing the visible tree must batch every cached directory")

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

                var coldSamples: [Double] = []
                var toggleSamples: [Double] = []
                var refreshSamples: [Double] = []
                for _ in 0..<5 {
                    let fresh = FileTreeModel()
                    let start = ProcessInfo.processInfo.systemUptime
                    await fresh.sync(root: root, backend: backend, scope: "ssh:windows-live")
                    coldSamples.append(ProcessInfo.processInfo.systemUptime - start)
                }
                let beforeWarmToggle = await runner.calls
                for _ in 0..<30 {
                    let start = ProcessInfo.processInfo.systemUptime
                    await tree.toggle(folder)
                    await tree.toggle(folder)
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
                print(String(format: "BAILEY_SSH_BENCHMARK cold-tree n=5 median=%.3fs max=%.3fs",
                             coldSorted[2], coldSorted[4]))
                summarize("warm-folder-toggle", toggleSamples)
                summarize("tree-refresh-14-folders", refreshSamples)
            }
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
            let limit = 8 << 20
            let emoji = Data("👋".utf8)
            let exact = Data(repeating: 0x41, count: limit - emoji.count) + emoji
            let path = root + "/代码' boundary.swift"
            print("EDITOR_CAP_LIVE beginning 8 MiB transfer")
            try await backend.write(path: path, data: exact)
            print("EDITOR_CAP_LIVE finished 8 MiB upload")
            let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:\(host)")
            try await file.waitForText()
            print("EDITOR_CAP_LIVE finished 8 MiB download")
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
            do { try await rejected.waitForText(); XCTFail("Remote 8 MiB + 1 must be rejected") }
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
