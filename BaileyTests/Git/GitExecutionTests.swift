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
        XCTAssertEqual(GitCommandExecution.runData(["cat-file", "blob", "HEAD:large.txt"], in: directory.path, stdoutLimit: 5).stdout, large.prefix(5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SHOULD_NOT_EXIST").path))

        let channels = GitCommandExecution.run(["-c", "alias.channels=!printf out; printf err >&2; exit 7", "channels"], in: directory.path)
        XCTAssertEqual(channels.status, 7)
        XCTAssertEqual(channels.stdout, "out")
        XCTAssertEqual(channels.stderr, "err")
        let environment = GitCommandExecution.run(["-c", "alias.environment=!printf '%s:%s:%s' \"$GIT_OPTIONAL_LOCKS\" \"$GIT_TERMINAL_PROMPT\" \"$LC_ALL\"", "environment"], in: directory.path)
        XCTAssertEqual(environment.stdout, "0:0:C")
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
