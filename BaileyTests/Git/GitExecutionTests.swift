import Darwin
import Foundation
import XCTest
@testable import Bailey

private actor GitBackendFixture: WorkspaceBackend {
    var result = WorkspaceRunResult(status: 7, stdout: Data([0, 255, 10]), stderr: Data("remote error".utf8))
    var failure: WorkspaceError?
    private(set) var arguments: [String] = []
    private(set) var directory: String?
    private(set) var environment: [String: String]?
    private(set) var deadline: TimeInterval?

    func configure(failure: WorkspaceError?) { self.failure = failure }
    func configure(result: WorkspaceRunResult) { self.result = result }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        arguments = argv
        directory = cwd
        environment = env
        deadline = timeout
        if let failure { throw failure }
        return result
    }
    func list(directory: String) async throws -> [WorkspaceEntry] { [] }
    func stat(path: String) async throws -> WorkspaceStat? { nil }
    func readSymlinkDestination(path: String) async throws -> String? { nil }
    func read(path: String, maxBytes: Int) async throws -> Data { Data() }
    func write(path: String, data: Data) async throws {}
    func createFile(path: String) async throws {}
    func createDirectory(path: String) async throws {}
    func copy(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func rename(from: String, to: String) async throws {}
    func delete(paths: [String]) async throws {}
}

final class GitExecutionTests: XCTestCase {
    func testFirstLoginEnvironmentLoadCannotCacheCancelledRequest() async {
        let result = await Task.detached(priority: .utility) {
            withUnsafeCurrentTask { $0?.cancel() }
            return GitCommandExecution.loadLoginEnvironment()
        }.value
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse((result.values["PATH"] ?? "").isEmpty)
    }

    func testGitObjectReadPhaseLatencyAndBatchCompleteness() async throws {
        for lineCount in [1_000, 24_000] {
            let directory = try makeRepository()
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = "object-cost.swift"
            let bytes = Data((0..<lineCount).map { "let row\($0) = \($0)\n" }.joined().utf8)
            try bytes.write(to: directory.appendingPathComponent(name))
            XCTAssertEqual(GitCommandExecution.run(["add", "--", name], in: directory.path).status, 0)
            XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: directory.path).status, 0)
            let selected = GitCommandExecution.run(["rev-parse", "HEAD:" + name], in: directory.path)
            XCTAssertEqual(selected.status, 0, selected.stderr)
            let oid = selected.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            var durations: [String: [Double]] = [:]
            for _ in 0..<30 {
                for (phase, arguments) in [
                    ("metadata", ["--literal-pathspecs", "ls-files", "--stage", "-z", "--", name]),
                    ("size", ["cat-file", "-s", oid]),
                    ("blob", ["cat-file", "blob", oid])
                ] {
                    let start = CFAbsoluteTimeGetCurrent()
                    let result = GitCommandExecution.runData(arguments, in: directory.path)
                    durations[phase, default: []].append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
                    XCTAssertEqual(result.status, 0, result.stderr)
                    if phase == "blob" { XCTAssertEqual(result.stdout, bytes) }
                    if phase == "size" {
                        XCTAssertEqual(Int(String(decoding: result.stdout, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)), bytes.count)
                    }
                }
                let start = CFAbsoluteTimeGetCurrent()
                let result = try await LocalWorkspaceBackend.shared.run(
                    argv: ["/usr/bin/env", "git", "cat-file", "--batch"], cwd: directory.path,
                    env: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"],
                    stdin: Data((oid + "\n").utf8), timeout: 10)
                durations["batchViaBackend", default: []].append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
                XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
                let header = Data("\(oid) blob \(bytes.count)\n".utf8)
                XCTAssertEqual(result.stdout, header + bytes + Data([10]))
            }
            for phase in durations.keys.sorted() {
                let samples = try XCTUnwrap(durations[phase]).sorted()
                print("AUDIT_GIT_OBJECT_PHASE rows=\(lineCount) phase=\(phase) samples=30 median=\(samples[15]) p95=\(samples[28]) worst=\(samples[29])")
            }
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), bytes)
        }
    }

    func testInterleavedStagedMetadataCanDescribeNoCoherentGitSnapshot() throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "staged-snapshot.txt"
        let path = directory.appendingPathComponent(name)
        try Data("before\n".utf8).write(to: path)
        func git(_ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
            GitCommandExecution.run(arguments, in: directory.path)
        }
        XCTAssertEqual(git(["add", "--", name]).status, 0)
        XCTAssertEqual(git(["commit", "-qm", "before"]).status, 0)
        let beforeHead = git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("after\n".utf8).write(to: path)
        XCTAssertEqual(git(["add", "--", name]).status, 0)
        XCTAssertEqual(git(["commit", "-qm", "after"]).status, 0)
        let afterHead = git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(git(["reset", "--hard", beforeHead]).status, 0)
        XCTAssertEqual(git(["diff", "--cached", "--quiet"]).status, 0)

        // These are the two independent metadata calls made by a Staged Diff.
        let tree = GitCommandExecution.runData(
            ["--literal-pathspecs", "ls-tree", "-rz", "--full-tree", "HEAD", "--", name],
            in: directory.path)
        XCTAssertEqual(tree.status, 0)
        XCTAssertEqual(git(["reset", "--hard", afterHead]).status, 0)
        let index = GitCommandExecution.runData(
            ["--literal-pathspecs", "ls-files", "--stage", "-z", "--", name],
            in: directory.path)
        XCTAssertEqual(index.status, 0)
        XCTAssertEqual(git(["diff", "--cached", "--quiet"]).status, 0)

        let treeRecord = String(decoding: tree.stdout.dropLast(), as: UTF8.self)
        let indexRecord = String(decoding: index.stdout.dropLast(), as: UTF8.self)
        let treeOID = try XCTUnwrap(treeRecord.split(separator: "\t").first?.split(separator: " ").last)
        let indexOID = try XCTUnwrap(indexRecord.split(separator: "\t").first?.split(separator: " ").dropLast().last)
        XCTAssertNotEqual(treeOID, indexOID)
        let oldBlob = GitCommandExecution.runData(["cat-file", "blob", String(treeOID)], in: directory.path)
        let newBlob = GitCommandExecution.runData(["cat-file", "blob", String(indexOID)], in: directory.path)
        XCTAssertEqual(oldBlob.stdout, Data("before\n".utf8))
        XCTAssertEqual(newBlob.stdout, Data("after\n".utf8))
        XCTAssertNotEqual(oldBlob.stdout, newBlob.stdout)
        XCTAssertEqual(try Data(contentsOf: path), Data("after\n".utf8))
        print("AUDIT_GIT_STAGED_CROSS_SNAPSHOT heads=2 stages=2 bothClean=true hybridDiff=true")
    }

    private func makeRepository() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [
            ["init", "-q"],
            ["config", "user.name", "Execution Test"],
            ["config", "user.email", "test@invalid"],
            ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", "/dev/null"],
        ] {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        return directory
    }

    func testLiteralPathsBinaryDataLimitsAndEnvironment() throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "space 'quote'; $(touch SHOULD_NOT_EXIST).bin"
        let binary = Data([0, 255, 1, 10])
        try binary.write(to: directory.appendingPathComponent(name))
        let large = Data(repeating: 65, count: 256 * 1024)
        try large.write(to: directory.appendingPathComponent("large.txt"))
        try Data("text\n".utf8).write(to: directory.appendingPathComponent("text.txt"))
        XCTAssertEqual(GitCommandExecution.run(["--literal-pathspecs", "add", "--", name, "large.txt", "text.txt"], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "fixture"], in: directory.path).status, 0)

        let bytes = GitCommandExecution.runData(["cat-file", "blob", "HEAD:" + name], in: directory.path)
        XCTAssertEqual(bytes.status, 0)
        XCTAssertEqual(bytes.stdout, binary)
        let limited = GitCommandExecution.runData(["cat-file", "blob", "HEAD:large.txt"], in: directory.path, stdoutLimit: 5)
        XCTAssertEqual(limited.status, -3, "Truncated stdout cannot be a successful Git object")
        XCTAssertLessThanOrEqual(limited.stdout.count, 5)
        XCTAssertEqual(limited.stderr, String(localized: "Git output exceeded the allowed size.", table: "Git"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SHOULD_NOT_EXIST").path))

        let channels = GitCommandExecution.run(["-c", "alias.channels=!printf out; printf err >&2; exit 7", "channels"], in: directory.path)
        XCTAssertEqual(channels.status, 7)
        XCTAssertEqual(channels.stdout, "out")
        XCTAssertEqual(channels.stderr, "err")
        let environment = GitCommandExecution.run(["-c", "alias.environment=!printf '%s:%s:%s' \"$GIT_OPTIONAL_LOCKS\" \"$GIT_TERMINAL_PROMPT\" \"$LC_ALL\"", "environment"], in: directory.path)
        XCTAssertEqual(environment.stdout, "0:0:C")
    }

    func testCancelActuallyStopsInFlightLocalWorkspaceAndGitCommands() async throws {
        let started = Date()
        let workspace = Task.detached(priority: .utility) {
            try await LocalWorkspaceBackend.shared.runLimited(
                argv: ["/bin/sleep", "8"], cwd: nil, env: nil, stdin: nil,
                timeout: 4, stdoutLimit: 32, stderrLimit: 32
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        workspace.cancel()
        do {
            _ = try await workspace.value
            XCTFail("Cancelled workspace command must throw cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Cancellation must not become a timeout: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1,
                          "Cancellation must release the actual process within one second")

        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gitStarted = Date()
        let git = Task.detached(priority: .utility) {
            await GitCommandExecution.runData(
                ["-c", "alias.pause=!exec /bin/sleep 8", "pause"],
                in: directory.path, timeout: 4, stdoutLimit: 32,
                backend: LocalWorkspaceBackend.shared
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        git.cancel()
        let response = await git.value
        XCTAssertEqual(response.status, -4, "Cancelled Git must not report a timeout or success")
        XCTAssertLessThan(Date().timeIntervalSince(gitStarted), 1)
    }

    func testCancellingLocalProcessReapsItsExactPID() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let pidURL = repository.appendingPathComponent("cancelled-local.pid")
        let path = "'" + pidURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let child = Task.detached(priority: .utility) {
            try await LocalWorkspaceBackend.shared.runLimited(
                argv: ["/bin/sh", "-c", "echo $$ > \(path); exec /bin/sleep 8"],
                cwd: repository.path, env: nil, stdin: nil, timeout: 5,
                stdoutLimit: 128, stderrLimit: 128
            )
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(pidText))
        XCTAssertEqual(Darwin.kill(pid, 0), 0)
        child.cancel()
        do {
            _ = try await child.value
            XCTFail("Cancelled child must not succeed")
        } catch is CancellationError {
        }
        var exited = false
        for _ in 0..<50 {
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { exited = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(exited, "The owned PID must be reaped; cancelling its Task is insufficient")
    }

    func testExactGitStdoutBudgetAndLocalWorkspacePipeBoundary() async throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let args = ["-c", "alias.bytes=!printf 12345", "bytes"]
        let exact = GitCommandExecution.runData(args, in: directory.path, stdoutLimit: 5)
        XCTAssertEqual(exact.status, 0, exact.stderr)
        XCTAssertEqual(exact.stdout, Data("12345".utf8))
        for limit in [0, 4] {
            let exceeded = GitCommandExecution.runData(args, in: directory.path, stdoutLimit: limit)
            XCTAssertEqual(exceeded.status, -3)
            XCTAssertLessThanOrEqual(exceeded.stdout.count, limit)
            XCTAssertEqual(exceeded.stderr, String(localized: "Git output exceeded the allowed size.", table: "Git"))
        }
        let stdout = try await LocalWorkspaceBackend.shared.runLimited(
            argv: ["/bin/sh", "-c", "printf out; printf err >&2"],
            cwd: nil, env: nil, stdin: nil, timeout: 2,
            stdoutLimit: 3, stderrLimit: 3
        )
        XCTAssertEqual(stdout.status, 0)
        XCTAssertEqual(stdout.stdout, Data("out".utf8))
        XCTAssertEqual(stdout.stderr, Data("err".utf8))
        for (outLimit, errLimit) in [(2, 3), (3, 2)] {
            do {
                _ = try await LocalWorkspaceBackend.shared.runLimited(
                    argv: ["/bin/sh", "-c", "printf out; printf err >&2"],
                    cwd: nil, env: nil, stdin: nil, timeout: 2,
                    stdoutLimit: outLimit, stderrLimit: errLimit
                )
                XCTFail("Output over the exact boundary must fail")
            } catch WorkspaceError.tooLarge {
            }
        }
    }

    func testNativeGitBatchReceiverChecksFiveMiBBoundaryBeforeAllocating() async throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let maxBytes = 5 * 1024 * 1024
        for count in [maxBytes, maxBytes + 1] {
            let data = Data(repeating: 0x41, count: count)
            let name = "batch-\(count).txt"
            try data.write(to: directory.appendingPathComponent(name))
            let hashed = GitCommandExecution.run(["hash-object", "-w", "--", name], in: directory.path)
            XCTAssertEqual(hashed.status, 0, hashed.stderr)
            let oid = hashed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(oid.count, 40)
            let budget = maxBytes + Data("\(oid) blob \(maxBytes)\n".utf8).count + 1
            let batch = await GitCommandExecution.runData(
                ["cat-file", "--batch"], in: directory.path, timeout: 10,
                stdoutLimit: budget, stdin: Data((oid + "\n").utf8),
                backend: LocalWorkspaceBackend.shared
            )
            if count == maxBytes {
                XCTAssertEqual(batch.status, 0, batch.stderr)
                XCTAssertEqual(batch.stdout, Data("\(oid) blob \(count)\n".utf8) + data + Data([10]))
            } else {
                XCTAssertEqual(batch.status, -3, "One byte beyond the pipe budget must fail")
                XCTAssertLessThanOrEqual(batch.stdout.count, budget)
            }
        }
    }

    func testLocalBoundedGitReaderEndsEndlessStdoutAndStderr() throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (alias, stream) in [
            ("streamout", "printf 0123456789"),
            ("streamerr", "printf 0123456789 >&2"),
        ] {
            let started = Date()
            let result = GitCommandExecution.runData(
                ["-c", "alias.\(alias)=!while :; do \(stream); done", alias],
                in: directory.path, timeout: 3, stdoutLimit: 512
            )
            XCTAssertEqual(result.status, -3, "Limit violations must stop Git, not time out")
            XCTAssertLessThanOrEqual(result.stdout.count, 512)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        }
    }

    func testLocalBackendHashStdinLatencyAndSnapshot() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "latency.swift"
        let content = Data((0..<24_000).map { "let value\($0) = \($0)\n" }.joined().utf8)
        try content.write(to: root.appendingPathComponent(name))
        let expected = GitCommandExecution.run(["hash-object", "--", name], in: root.path)
        XCTAssertEqual(expected.status, 0)
        let backend = LocalWorkspaceBackend.shared
        var times: [Double] = []
        for _ in 0..<17 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try await backend.run(
                argv: ["/usr/bin/env", "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0",
                       "LC_ALL=C", "git", "hash-object", "--path=" + name, "--stdin"],
                cwd: root.path, env: nil, stdin: content, timeout: 60
            )
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(String(data: result.stdout, encoding: .utf8), expected.stdout)
        }
        times.sort()
        print("AUDIT_GIT_BACKEND_HASH_STDIN rows=24000 medianMs=\(times[8]) p95Ms=\(times[15])")
    }

    func testTimeoutReturnsPartialOutputWithoutHanging() throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = Date()
        let result = GitCommandExecution.run(
            ["-c", "alias.pause=!printf partial; printf warning >&2; exec /bin/sleep 5", "pause"],
            in: directory.path,
            timeout: 0.5
        )
        XCTAssertEqual(result.status, -2)
        XCTAssertEqual(result.stdout, "partial")
        XCTAssertTrue(result.stderr.contains("warning"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testRemoteOutputLimitNeverReturnsPartialSuccess() async {
        let backend = GitBackendFixture()
        let payload = Data(repeating: 65, count: 8 * 1_024 * 1_024)
        let errorOutput = Data(repeating: 66, count: 1_024 * 1_024)
        await backend.configure(result: WorkspaceRunResult(
            status: 7, stdout: payload, stderr: errorOutput
        ))
        let limit = 1_024
        let result = await GitCommandExecution.runData(
            ["cat-file", "blob", "012345"], in: "/repo", stdoutLimit: limit,
            backend: backend
        )
        XCTAssertEqual(result.status, -3)
        XCTAssertLessThanOrEqual(result.stdout.count, limit)
        XCTAssertEqual(result.stderr, String(localized: "Git output exceeded the allowed size.", table: "Git"))
    }

    func testRemoteBackendMapping() async {
        let backend = GitBackendFixture()
        let result = await GitCommandExecution.runData(["status", "-z"], in: "/repo", timeout: 3, backend: backend)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.stdout, Data([0, 255, 10]))
        XCTAssertEqual(result.stderr, "remote error")
        let captured = await (backend.arguments, backend.directory, backend.environment, backend.deadline)
        XCTAssertEqual(captured.0, ["git", "status", "-z"])
        XCTAssertEqual(captured.1, "/repo")
        XCTAssertEqual(captured.2, ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"])
        XCTAssertEqual(captured.3, 3)

        await backend.configure(failure: .timedOut)
        let timeout = await GitCommandExecution.runData(["status"], in: "/repo", backend: backend)
        XCTAssertEqual(timeout.status, -2)
        await backend.configure(failure: .notFound)
        let missing = await GitCommandExecution.run(["status"], in: "/repo", backend: backend)
        XCTAssertEqual(missing.status, -1)
    }

    func testLoginShellEnvironmentValidation() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        var environment = ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = fixture.path
        environment["BAILEY_TEST_VALUE"] = "fixture"
        try "export PATH='/usr/bin:/bin:/usr/sbin:/sbin'\nexport BAILEY_FROM_LOGIN=ok\n".write(
            to: fixture.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8
        )
        let loaded = GitCommandExecution.loadLoginEnvironment(shell: "/bin/zsh", environment: environment, timeout: 2)
        XCTAssertEqual(loaded.status, 0, loaded.stderr)
        XCTAssertEqual(loaded.values["BAILEY_FROM_LOGIN"], "ok")
        XCTAssertNotNil(loaded.values["PATH"])

        try "/bin/sleep 5\n".write(to: fixture.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitCommandExecution.loadLoginEnvironment(shell: "/bin/zsh", environment: environment, timeout: 0.1).status, -2)
    }
}
