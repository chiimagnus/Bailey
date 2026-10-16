import Foundation
import XCTest
@testable import kero

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
        guard let host = ProcessInfo.processInfo.environment["KERO_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set KERO_P4_TEST_SSH_HOST to an explicitly authorized SSH test host")
        }
        let socket = "/tmp/kero-files-\(UUID().uuidString.prefix(8)).sock"
        let runner = CountingLiveSSHRunner(host: host, socket: socket)
        let backend = SSHWorkspaceBackend(runner: runner, timeout: 25)
        let result = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/kero-files-batch-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
        let root = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("kero-files-batch-") else {
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
            if ProcessInfo.processInfo.environment["KERO_SSH_BENCHMARK"] == "1" {
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
                    print(String(format: "KERO_SSH_BENCHMARK %@ n=%d median=%.3fs p95=%.3fs max=%.3fs",
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
                print(String(format: "KERO_SSH_BENCHMARK cold-tree n=5 median=%.3fs max=%.3fs",
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
}
