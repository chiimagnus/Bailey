import Foundation
import XCTest
@testable import Bailey

@MainActor
final class SSHWindowsFileEventsTests: XCTestCase {
    func testPTYProtocolRecognizesOnlyOwnedFramedEvents() {
        let token = "probe-52"
        XCTAssertEqual(SSHWindowsFileEvents.parse("\u{1B}[1mBAILEY:\(token):READY\r", token: token), .ready)
        XCTAssertEqual(SSHWindowsFileEvents.parse("BAILEY:\(token):DIRTY\r", token: token), .dirty)
        XCTAssertEqual(SSHWindowsFileEvents.parse("BAILEY:\(token):LOST\r", token: token), .lost)
        XCTAssertEqual(SSHWindowsFileEvents.parse("BAILEY:\(token):END\r", token: token), .ended)
        XCTAssertNil(SSHWindowsFileEvents.parse("BAILEY:other:DIRTY", token: token))
        XCTAssertNil(SSHWindowsFileEvents.parse("unrelated PowerShell output", token: token))
    }

    func testAuthorizedWindowsCancellationReapsOnlyItsOwnWatcher() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Requires an authorized isolated Windows SSH host")
        }
        let socket = "/tmp/bailey-p2-reap-\(UUID().uuidString.prefix(8)).sock"
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket))
        let created = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-p2-reap-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(created.status, 0)
        let root = String(decoding: created.stdout, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("bailey-p2-reap-") else {
            throw WorkspaceError.notFound
        }
        func cleanUp() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Cannot remove only test-owned watcher directory: \(error)") }
            let exit = ProcessRemoteCommandRunner.run(
                sshPath: "/usr/bin/ssh",
                arguments: ["-S", socket, "-O", "exit", host],
                stdin: nil, timeout: 10
            )
            XCTAssertEqual(exit.status, 0)
        }
        do {
            let native = try await backend.run(
                argv: ["cygpath", "-w", root], cwd: nil, env: nil,
                stdin: nil, timeout: 15
            )
            XCTAssertEqual(native.status, 0)
            let windowsRoot = String(decoding: native.stdout, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            let needle = Data(windowsRoot.utf16.flatMap {
                [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]
            }).base64EncodedString()
            func countOwnedPowerShellWatchers() async throws -> Int {
                let ps = """
                $needle='\(needle)'
                $signature='[IO.FileSystem'+'Watcher]'
                $matches=@(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
                  $match=[regex]::Match($_.CommandLine,'(?i)-EncodedCommand\\s+([A-Za-z0-9+/=]+)')
                  if(!$match.Success) { return $false }
                  try {
                    $body=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($match.Groups[1].Value))
                    return $body.Contains($needle) -and $body.Contains($signature)
                  } catch { return $false }
                })
                [Console]::WriteLine($matches.Count)
                """
                let encoded = Data(ps.utf16.flatMap {
                    [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]
                }).base64EncodedString()
                let response = try await backend.run(
                    argv: ["powershell.exe", "-NoProfile", "-NonInteractive",
                           "-EncodedCommand", encoded],
                    cwd: nil, env: nil, stdin: nil, timeout: 20
                )
                XCTAssertEqual(response.status, 0)
                return Int(String(decoding: response.stdout, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            }
            let subscription = SSHWindowsFileEvents.subscribe(
                host: host, windowsRoot: windowsRoot, leaseSeconds: 30
            )
            defer { subscription.cancel() }
            let ready = expectation(description: "Windows watcher READY")
            let consumer = Task {
                for await event in subscription.events {
                    if event == .ready { ready.fulfill() }
                }
            }
            await fulfillment(of: [ready], timeout: 18)
            let active = try await countOwnedPowerShellWatchers()
            XCTAssertEqual(active, 1,
                           "Exactly one live PowerShell watcher must own this isolated test root")
            subscription.cancel()
            consumer.cancel()
            let deadline = Date().addingTimeInterval(12)
            var count = -1
            repeat {
                count = try await countOwnedPowerShellWatchers()
                if count == 0 { break }
                try await Task.sleep(for: .milliseconds(350))
            } while Date() < deadline
            XCTAssertEqual(count, 0,
                           "Cancelling the PTY stream must reap the remote PowerShell before its lease")
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    func testAuthorizedWindowsWatcherReportsLostWhenRootMoves() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST=windows for an authorized SSH test")
        }
        let socket = "/tmp/bailey-p2-vanish-\(UUID().uuidString.prefix(8)).sock"
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket))
        let result = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-p2-vanish-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(result.status, 0)
        let root = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.hasPrefix("/tmp/bailey-p2-vanish-"),
              !root.dropFirst("/tmp/bailey-p2-vanish-".count).contains("/") else {
            throw WorkspaceError.notFound
        }
        let moved = root + "-moved"
        let remote = try await backend.run(
            argv: ["cygpath", "-w", root], cwd: nil, env: nil,
            stdin: nil, timeout: 25
        )
        XCTAssertEqual(remote.status, 0)
        let native = String(decoding: remote.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func cleanup() async {
            if (try? await backend.stat(path: moved)) != nil {
                do { try await backend.delete(paths: [moved]) }
                catch { XCTFail("Cannot remove test-owned moved directory: \(error)") }
            } else {
                try? await backend.delete(paths: [root])
            }
            let closed = ProcessRemoteCommandRunner.run(
                sshPath: "/usr/bin/ssh", arguments: ["-S", socket, "-O", "exit", host],
                stdin: nil, timeout: 10
            )
            XCTAssertEqual(closed.status, 0)
        }
        do {
            let subscription = SSHWindowsFileEvents.subscribe(
                host: host, windowsRoot: native, leaseSeconds: 25
            )
            defer { subscription.cancel() }
            let stream = subscription.events
            let consumer = Task {
                for await event in stream {
                    switch event {
                    case .ready:
                        try await backend.rename(from: root, to: moved)
                    case .lost:
                        return true
                    case .ended:
                        return false
                    case .dirty:
                        continue
                    }
                }
                return false
            }
            let deadline = Task {
                try? await Task.sleep(for: .seconds(16))
                consumer.cancel()
            }
            let lost = try await consumer.value
            deadline.cancel()
            XCTAssertTrue(lost, "Moving an active Windows watch root must restore the polling fallback")
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    func testAuthorizedWindowsSymlinkedRootKeepsFallbackPolling() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST=windows for an authorized SSH test")
        }
        let socket = "/tmp/bailey-p2-symlink-\(UUID().uuidString.prefix(8)).sock"
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket))
        let created = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-p2-symlink-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(created.status, 0)
        let root = String(decoding: created.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.hasPrefix("/tmp/bailey-p2-symlink-"),
              !root.dropFirst("/tmp/bailey-p2-symlink-".count).contains("/") else {
            throw WorkspaceError.notFound
        }
        let link = root + "/alias"
        let actual = root + "/actual"
        let member = UUID()
        let project = Project(fallbackName: "Symlink Root", workspaceConfiguration: .standard)
        project.sshHost = host
        project.customDirectory = link
        func cleanup() async {
            project.remoteFileEvents.unsubscribe(id: member)
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Cannot remove test symlink fixture: \(error)") }
            let process = ProcessRemoteCommandRunner.run(
                sshPath: "/usr/bin/ssh",
                arguments: ["-S", socket, "-O", "exit", host], stdin: nil, timeout: 10
            )
            XCTAssertEqual(process.status, 0)
        }
        do {
            try await backend.createDirectory(path: actual)
            let result = try await backend.run(
                argv: ["ln", "-s", actual, link], cwd: nil, env: nil,
                stdin: nil, timeout: 25
            )
            XCTAssertEqual(result.status, 0)
            let context = try XCTUnwrap(project.panelContext)
            project.remoteFileEvents.subscribe(
                id: member, project: project, host: host, root: link, context: context
            )
            try await Task.sleep(for: .seconds(3))
            XCTAssertFalse(project.remoteFileEvents.healthy,
                           "FileSystemWatcher cannot reliably follow a symlinked root")
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    func testAuthorizedWindowsPinnedProjectUsesEventsAndSharesOneSubscription() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST=windows for an authorized SSH test")
        }
        let socket = "/tmp/bailey-p2-owner-\(UUID().uuidString.prefix(8)).sock"
        let remote = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket))
        let created = try await remote.run(
            argv: ["mktemp", "-d", "/tmp/bailey-p2-owner-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(created.status, 0)
        let root = String(decoding: created.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.hasPrefix("/tmp/bailey-p2-owner-"),
              !root.dropFirst("/tmp/bailey-p2-owner-".count).contains("/") else {
            throw WorkspaceError.notFound
        }
        let project = Project(fallbackName: "SSH File Events", workspaceConfiguration: .standard)
        project.sshHost = host
        project.customDirectory = root
        let first = UUID()
        let second = UUID()
        func cleanup() async {
            project.remoteFileEvents.unsubscribe(id: first)
            project.remoteFileEvents.unsubscribe(id: second)
            do { try await remote.delete(paths: [root]) }
            catch { XCTFail("Could not remove the test-owned remote directory: \(error)") }
            let output = ProcessRemoteCommandRunner.run(
                sshPath: "/usr/bin/ssh",
                arguments: ["-S", socket, "-O", "exit", host], stdin: nil, timeout: 10
            )
            XCTAssertEqual(output.status, 0, "Dedicated SSH test master must exit")
        }
        do {
            let context = try XCTUnwrap(project.panelContext)
            let initial = await project.syncFiles(isCurrent: { true })
            XCTAssertNotNil(initial)
            project.remoteFileEvents.subscribe(
                id: first, project: project, host: host, root: root, context: context
            )
            project.remoteFileEvents.subscribe(
                id: second, project: project, host: host, root: root, context: context
            )
            let deadline = Date().addingTimeInterval(16)
            while !project.remoteFileEvents.healthy, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(project.remoteFileEvents.healthy, "Only a ready watcher with an initial disk read may disable polling")
            project.remoteFileEvents.unsubscribe(id: first)
            XCTAssertTrue(project.remoteFileEvents.healthy, "A second Files panel must retain the shared watcher")

            let filename = "external from independent SSH.txt"
            let path = root + "/" + filename
            try await remote.createFile(path: path)
            let changedDeadline = Date().addingTimeInterval(12)
            while !project.fileTree.items.contains(where: { $0.path == path }), Date() < changedDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(project.fileTree.items.contains { $0.path == path },
                          "Events must drive Project.syncFiles without any explicit test poll")

            let burst = """
            i=0
            while [ "$i" -lt 400 ]; do
              : > \(RemoteCommands.quote(root))/"burst-$i.txt"
              i=$((i+1))
            done
            i=0
            while [ "$i" -lt 150 ]; do
              rm -- \(RemoteCommands.quote(root))/"burst-$i.txt"
              i=$((i+1))
            done
            """
            let batch = try await remote.run(
                argv: ["sh", "-c", burst], cwd: nil, env: nil, stdin: nil, timeout: 40
            )
            XCTAssertEqual(batch.status, 0, String(decoding: batch.stderr, as: UTF8.self))
            let expected = Set((150..<400).map { "burst-\($0).txt" })
            let burstDeadline = Date().addingTimeInterval(15)
            var observed: Set<String> = []
            repeat {
                observed = Set(project.fileTree.items.map(\.name).filter {
                    $0.hasPrefix("burst-")
                })
                if observed == expected || !project.remoteFileEvents.healthy { break }
                try await Task.sleep(for: .milliseconds(200))
            } while Date() < burstDeadline
            let recoveredByEvents = observed == expected
            if !recoveredByEvents && !project.remoteFileEvents.healthy {
                // A lost/failed stream must restore the same 2-second Files
                // refresh path used by ToolPanelView, not leave a stale tree.
                try await Task.sleep(for: .seconds(2))
                let fallback = await project.syncFiles(isCurrent: { true })
                XCTAssertNotNil(fallback, "Polling fallback must read the actual remote disk")
                observed = Set(project.fileTree.items.map(\.name).filter {
                    $0.hasPrefix("burst-")
                })
            }
            XCTAssertEqual(observed, expected,
                           "550 operations must converge, via events or the mandatory polling fallback")
            print("BAILEY_P2_STORM operations=550 remaining=250 eventConverged=\(recoveredByEvents)")

            let nextRoot = root + "/next"
            try await remote.createDirectory(path: nextRoot)
            project.customDirectory = nextRoot
            let nextContext = try XCTUnwrap(project.panelContext)
            project.remoteFileEvents.subscribe(
                id: second, project: project, host: host,
                root: nextRoot, context: nextContext
            )
            let reconnectDeadline = Date().addingTimeInterval(24)
            while !project.remoteFileEvents.healthy, Date() < reconnectDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(project.remoteFileEvents.healthy,
                          "A new root must establish a new independent subscription")
            let nextFile = nextRoot + "/new-scope.txt"
            try await remote.createFile(path: nextFile)
            let nextDeadline = Date().addingTimeInterval(12)
            while !project.fileTree.items.contains(where: { $0.path == nextFile }),
                  Date() < nextDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(project.fileTree.rootPath, nextRoot)
            XCTAssertTrue(project.fileTree.items.contains { $0.path == nextFile })
            XCTAssertFalse(project.fileTree.items.contains { $0.path == path },
                           "Late events from the old root must not publish old Files rows")

            project.remoteFileEvents.unsubscribe(id: second)
            XCTAssertFalse(project.remoteFileEvents.healthy, "Last visible Files panel must restore polling immediately")
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    func testAuthorizedWindowsSSHExternalEventUpdatesRealFileTreeWithoutPolling() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST=windows for an authorized SSH test")
        }
        let socket = "/tmp/bailey-p2-files-\(UUID().uuidString.prefix(8)).sock"
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket))
        let directory = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-p2-live-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(directory.status, 0)
        let root = String(decoding: directory.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.hasPrefix("/tmp/bailey-p2-live-"), !root.dropFirst(20).contains("/") else {
            throw WorkspaceError.notFound
        }
        func cleanup() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Could not delete the isolated remote test folder: \(error)") }
            let result = ProcessRemoteCommandRunner.run(
                sshPath: "/usr/bin/ssh",
                arguments: ["-S", socket, "-O", "exit", host], stdin: nil, timeout: 10
            )
            XCTAssertEqual(result.status, 0, "Could not close the test-owned SSH master")
        }
        do {
            let watchedRoot = root + "/事件 中文 space"
            try await backend.createDirectory(path: watchedRoot)
            let windowsPath = try await backend.run(
                argv: ["cygpath", "-w", watchedRoot], cwd: nil, env: nil, stdin: nil, timeout: 25
            )
            XCTAssertEqual(windowsPath.status, 0)
            let native = String(decoding: windowsPath.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tree = FileTreeModel()
            await tree.sync(root: watchedRoot, backend: backend, scope: "ssh:windows-live")
            let target = watchedRoot + "/外部 new from outside.txt"
            XCTAssertFalse(tree.items.contains { $0.path == target })

            let subscription = SSHWindowsFileEvents.subscribe(
                host: host, windowsRoot: native, leaseSeconds: 22
            )
            defer { subscription.cancel() }
            let stream = subscription.events
            let consumer = Task {
                for await event in stream {
                    switch event {
                    case .ready:
                        try await backend.createFile(path: target)
                    case .dirty:
                        await tree.sync(root: watchedRoot, backend: backend, scope: "ssh:windows-live")
                        if tree.items.contains(where: { $0.path == target }) { return true }
                    case .lost, .ended:
                        return false
                    }
                }
                return false
            }
            let deadline = Task {
                try? await Task.sleep(for: .seconds(16))
                consumer.cancel()
            }
            let observed = try await consumer.value
            deadline.cancel()
            XCTAssertTrue(observed, "A real remote external write must reach Files through the event stream")
            XCTAssertTrue(tree.items.contains { $0.path == target })
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}
