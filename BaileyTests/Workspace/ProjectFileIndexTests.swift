import Foundation
import XCTest
@testable import Bailey

private actor IndexFailureRunner: RemoteCommandRunner {
    enum Scenario: Sendable { case permissionDenied, disconnected, oversized, oversizedDirectory }
    let scenario: Scenario
    private(set) var commands: [String] = []

    init(_ scenario: Scenario) { self.scenario = scenario }

    func run(
        _ argv: [String], stdin: Data?, timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        let command = argv.joined(separator: " ")
        commands.append(command)
        if command.contains("printf") && command.contains("HOME") {
            return (0, Data("/remote/project\0/remote/home\0".utf8), Data())
        }
        if case .disconnected = scenario { throw WorkspaceError.timedOut }
        if case .oversized = scenario {
            return (0, Data(repeating: 0x41, count: 4 * 1024 * 1024 + 128), Data())
        }
        if case .oversizedDirectory = scenario, command.contains("find -H") {
            return (0, Data(repeating: 0x41, count: 4 * 1024 * 1024 + 128), Data())
        }
        guard let tagStart = command.range(of: "bailey-index-")?.lowerBound else {
            return (1, Data(), Data("Unexpected command".utf8))
        }
        let tag = String(command[tagStart...].prefix(49))
        let error = if case .oversizedDirectory = scenario {
            "fatal: not a git repository"
        } else {
            "fatal: permission denied"
        }
        return (0, Data(("\n" + tag + "128\n").utf8), Data(error.utf8))
    }
}

private actor IndexAliasRunner: RemoteCommandRunner {
    let physicalDirectory: String
    let physicalHome: String
    private(set) var commands: [String] = []

    init(physicalDirectory: String, physicalHome: String) {
        self.physicalDirectory = physicalDirectory
        self.physicalHome = physicalHome
    }

    func run(
        _ argv: [String], stdin: Data?, timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        let command = argv.joined(separator: " ")
        commands.append(command)
        if command.contains("HOME") {
            return (0, Data("\(physicalDirectory)\0\(physicalHome)\0".utf8), Data())
        }
        guard let markerStart = command.range(of: "bailey-index-")?.lowerBound else {
            return (1, Data(), Data("Unexpected indexing command".utf8))
        }
        let marker = String(command[markerStart...].prefix(49))
        if command.contains("rev-parse") {
            return (0, Data(("\n" + marker + "128\n").utf8),
                    Data("fatal: not a git repository".utf8))
        }
        if command.contains("find -H"),
           let tagRange = command.range(
               of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
               options: .regularExpression
           ) {
            let tag = String(command[tagRange])
            let output = "f\tf\t中文😀.swift\0l\tf\talias.swift\0\n\(tag) 0 0\n\n\(marker)0\n"
            return (0, Data(output.utf8), Data())
        }
        return (1, Data(), Data("Unexpected indexing command".utf8))
    }
}

final class ProjectFileIndexTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-palette-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ name: String, in root: URL) throws {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: file)
    }

    func testGitIndexIncludesTrackedAndNonignoredUntrackedWithExactUTF8Paths() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) {
            let result = GitCommandExecution.run(args, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        git(["init", "-q"])
        try write("ignored.tmp\n", ".gitignore", in: root)
        try write("tracked", "tracked.swift", in: root)
        let unicode = "nested/中文😀\nname.swift"
        try write("unicode", unicode, in: root)
        try write("hidden", "ignored.tmp", in: root)
        try write("new", "untracked.js", in: root)
        git(["add", "--", "tracked.swift", unicode, ".gitignore"])

        let files = ProjectFileIndex.load(in: root.path)
        let paths = Set(files.map(\.relativePath))
        XCTAssertTrue(paths.contains("tracked.swift"))
        XCTAssertTrue(paths.contains(unicode))
        XCTAssertTrue(paths.contains("untracked.js"))
        XCTAssertTrue(paths.contains(".gitignore"))
        XCTAssertFalse(paths.contains("ignored.tmp"))
        XCTAssertFalse(paths.contains { $0.hasPrefix(".git/") })
        XCTAssertEqual(files.first { $0.relativePath == unicode }?.name, "中文😀\nname.swift")
        XCTAssertEqual(
            files.first { $0.relativePath == unicode }?.parentPath, "nested"
        )

        try FileManager.default.removeItem(at: root.appendingPathComponent("tracked.swift"))
        XCTAssertFalse(ProjectFileIndex.load(in: root.path).contains {
            $0.relativePath == "tracked.swift"
        })
    }


    func testBoundedRemoteGitUsesActualWorkspaceBackendAndNULPaths() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initialized = GitCommandExecution.run(["init", "-q"], in: root.path)
        XCTAssertEqual(initialized.status, 0, initialized.stderr)
        try write("tracked", "nested/中文😀\nname.swift", in: root)
        try write("new", "new.swift", in: root)
        try write("ignored", "ignored.log", in: root)
        try write("*.log\n", ".gitignore", in: root)
        XCTAssertEqual(GitCommandExecution.run(
            ["add", "--", "nested/中文😀\nname.swift", ".gitignore"], in: root.path
        ).status, 0)
        let result = try await ProjectFileIndex.loadRemote(
            in: root.path, backend: LocalWorkspaceBackend.shared
        )
        XCTAssertFalse(result.limited)
        let paths = Set(result.files.map(\.relativePath))
        XCTAssertTrue(paths.contains("nested/中文😀\nname.swift"))
        XCTAssertTrue(paths.contains("new.swift"))
        XCTAssertTrue(paths.contains(".gitignore"))
        XCTAssertFalse(paths.contains("ignored.log"))
        XCTAssertFalse(paths.contains { $0.hasPrefix(".git/") })
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("nested/中文😀\nname.swift")
        )
        let after = try await ProjectFileIndex.loadRemote(
            in: root.path, backend: LocalWorkspaceBackend.shared
        )
        XCTAssertFalse(after.files.contains { $0.relativePath == "nested/中文😀\nname.swift" })
    }

    func testRemotePlainDirectoryListingAvoidsGitObjectsAndDirectorySymlinkCycles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", "src/code.swift", in: root)
        try write("two", "top.txt", in: root)
        try write("private", ".git/objects/abc", in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("src/loop"),
            withDestinationURL: root
        )
        let result = try await ProjectFileIndex.loadRemote(
            in: root.path, backend: LocalWorkspaceBackend.shared
        )
        XCTAssertFalse(result.limited)
        XCTAssertEqual(result.files.map(\.relativePath), ["src/code.swift", "top.txt"])
    }

    func testRemoteRootAndHomeAreNotIndexed() async throws {
        for root in ["/", NSHomeDirectory()] {
            do {
                _ = try await ProjectFileIndex.loadRemote(
                    in: root, backend: LocalWorkspaceBackend.shared
                )
                XCTFail("Root should have been restricted: \(root)")
            } catch ProjectFileIndex.RemoteIndexError.restrictedRoot {
                // Expected: no remote-home or whole-filesystem scan.
            } catch {
                XCTFail("Wrong error for restricted root: \(error)")
            }
        }
    }

    func testAuthorizedWindowsSSHProjectIndexGitAndPlainRealFiles() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"],
              !host.isEmpty else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST to the approved isolated Windows SSH target")
        }
        let socket = "/tmp/bailey-p3-index-\(UUID().uuidString.prefix(8)).sock"
        let backend = SSHWorkspaceBackend(
            runner: SSHHostCommandRunner(host: host, socket: socket), timeout: 25
        )
        let temporary = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-p3-index-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25
        )
        XCTAssertEqual(temporary.status, 0, String(decoding: temporary.stderr, as: UTF8.self))
        let root = String(decoding: temporary.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("bailey-p3-index-") else {
            throw WorkspaceError.notFound
        }
        func run(_ argv: [String], in directory: String? = nil) async throws {
            let result = try await backend.run(
                argv: argv, cwd: directory, env: nil, stdin: nil, timeout: 25
            )
            XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
        }
        do {
            let gitRoot = root + "/git-repository"
            let plainRoot = root + "/plain-folder"
            try await backend.createDirectory(path: gitRoot)
            try await backend.createDirectory(path: plainRoot)
            try await backend.createDirectory(path: gitRoot + "/nested")
            try await backend.createDirectory(path: plainRoot + "/child")
            try await run(["git", "init", "-q", "-b", "main"], in: gitRoot)
            let special = "nested/中文 😀 file.swift"
            try await backend.write(path: gitRoot + "/" + special, data: Data("remote tracked\n".utf8))
            try await backend.write(path: gitRoot + "/new.swift", data: Data("remote untracked\n".utf8))
            try await backend.write(path: gitRoot + "/ignored.log", data: Data("ignored\n".utf8))
            try await backend.write(path: gitRoot + "/.gitignore", data: Data("*.log\n".utf8))
            try await run(["git", "add", "--", special, ".gitignore"], in: gitRoot)
            try await backend.write(path: plainRoot + "/child/远端目录.txt", data: Data("plain remote\n".utf8))

            let gitIndex = try await ProjectFileIndex.loadRemote(in: gitRoot, backend: backend)
            XCTAssertFalse(gitIndex.limited)
            XCTAssertEqual(Set(gitIndex.files.map(\.relativePath)),
                           Set([special, ".gitignore", "new.swift"]))
            XCTAssertEqual(gitIndex.files.first(where: { $0.relativePath == special })?.absolutePath,
                           gitRoot + "/" + special)
            let plainIndex = try await ProjectFileIndex.loadRemote(in: plainRoot, backend: backend)
            XCTAssertFalse(plainIndex.limited)
            XCTAssertEqual(plainIndex.files.map(\.relativePath), ["child/远端目录.txt"])
            // Recreate only this test's multiplexed SSH master; user sessions
            // and the Windows SSH service remain untouched.
            let closedForReconnect = try await Task.detached {
                try ProcessRemoteCommandRunner.launch(
                    sshPath: "/usr/bin/ssh", arguments: ["-S", socket, "-O", "exit", host],
                    stdin: nil, timeout: 10
                )
            }.value
            XCTAssertEqual(closedForReconnect.status, 0)
            let reconnected = try await ProjectFileIndex.loadRemote(in: plainRoot, backend: backend)
            XCTAssertEqual(reconnected.files.map(\.relativePath), ["child/远端目录.txt"],
                           "A fresh SSH connection must provide the same remote files")
            let actualBytes = try await backend.read(path: gitRoot + "/" + special, maxBytes: 256)
            XCTAssertEqual(actualBytes, Data("remote tracked\n".utf8))
            try await backend.delete(paths: [gitRoot + "/" + special])
            let afterDelete = try await ProjectFileIndex.loadRemote(in: gitRoot, backend: backend)
            XCTAssertFalse(afterDelete.files.contains { $0.relativePath == special })
            let home = try await backend.run(
                argv: ["/bin/sh", "-c", "printf '%s' \"$HOME\""],
                cwd: nil, env: nil, stdin: nil, timeout: 25
            )
            XCTAssertEqual(home.status, 0)
            let homePath = String(decoding: home.stdout, as: UTF8.self)
            do {
                _ = try await ProjectFileIndex.loadRemote(in: homePath + "/.", backend: backend)
                XCTFail("A normalized spelling of remote HOME must not be indexed")
            } catch ProjectFileIndex.RemoteIndexError.restrictedRoot {
                // Expected, without traversing the user's actual HOME.
            }
        } catch {
            try? await backend.delete(paths: [root])
            throw error
        }
        try await backend.delete(paths: [root])
        let deleted = try await backend.stat(path: root)
        XCTAssertNil(deleted, "Only the owned remote fixture may be removed")
        let disconnected = try await Task.detached {
            try ProcessRemoteCommandRunner.launch(
                sshPath: "/usr/bin/ssh", arguments: ["-S", socket, "-O", "exit", host],
                stdin: nil, timeout: 10
            )
        }.value
        XCTAssertEqual(disconnected.status, 0,
                       "Close only this test's private SSH master, not any user connection")
    }

    func testRemoteNongitBoundedDirectoryListingReturnsActualFiles() async throws {
        let runner = IndexAliasRunner(
            physicalDirectory: "/remote/project", physicalHome: "/remote/home"
        )
        let result = try await ProjectFileIndex.loadRemote(
            in: "/remote/project", backend: SSHWorkspaceBackend(runner: runner)
        )
        XCTAssertFalse(result.limited)
        XCTAssertEqual(result.files.map(\.relativePath), ["中文😀.swift"])
        XCTAssertEqual(result.files.first?.absolutePath, "/remote/project/中文😀.swift")
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 3)
        XCTAssertTrue(commands.last?.contains("head -c") == true)
    }

    func testRemotePhysicalRootRejectsHomeAndFilesystemAliasesBeforeIndexing() async throws {
        let aliases = [
            (root: "/remote/home/.", physical: "/remote/home"),
            (root: "/remote/home-alias", physical: "/remote/home"),
            (root: "//", physical: "//"),
        ]
        for alias in aliases {
            let runner = IndexAliasRunner(
                physicalDirectory: alias.physical, physicalHome: "/remote/home"
            )
            do {
                _ = try await ProjectFileIndex.loadRemote(
                    in: alias.root, backend: SSHWorkspaceBackend(runner: runner)
                )
                XCTFail("Root alias should not be indexed: \(alias.root)")
            } catch ProjectFileIndex.RemoteIndexError.restrictedRoot {
                let commands = await runner.commands
                XCTAssertEqual(commands.count, 1, "Do not run Git or enumeration on a restricted root")
            } catch {
                XCTFail("Wrong error for restricted alias \(alias.root): \(error)")
            }
        }
    }

    func testRemoteGitPermissionAndDisconnectionNeverFallbackToLocal() async throws {
        for scenario: IndexFailureRunner.Scenario in [.permissionDenied, .disconnected] {
            let runner = IndexFailureRunner(scenario)
            let backend = SSHWorkspaceBackend(runner: runner)
            do {
                _ = try await ProjectFileIndex.loadRemote(in: "/remote/project", backend: backend)
                XCTFail("Expected remote failure")
            } catch ProjectFileIndex.RemoteIndexError.unavailable {
                guard case .permissionDenied = scenario else {
                    return XCTFail("A dropped connection cannot be Git permission failure")
                }
            } catch WorkspaceError.timedOut {
                guard case .disconnected = scenario else {
                    return XCTFail("Git permission failure cannot be a connection timeout")
                }
            }
            let commands = await runner.commands
            XCTAssertEqual(commands.count, 2, "Only remote HOME and Git probe may execute")
        }
    }

    func testRemoteGitOutputCapRejectsTruncation() async throws {
        let runner = IndexFailureRunner(.oversized)
        let backend = SSHWorkspaceBackend(runner: runner)
        do {
            _ = try await ProjectFileIndex.loadRemote(in: "/remote/project", backend: backend)
            XCTFail("Oversized Git output must not be interpreted as a complete index")
        } catch ProjectFileIndex.RemoteIndexError.tooLarge {
            let commands = await runner.commands
            XCTAssertEqual(commands.count, 2)
        }
    }

    func testRemoteNongitDirectoryListingIsBoundedBeforeTransport() async throws {
        let runner = IndexFailureRunner(.oversizedDirectory)
        let backend = SSHWorkspaceBackend(runner: runner)
        do {
            _ = try await ProjectFileIndex.loadRemote(in: "/remote/project", backend: backend)
            XCTFail("An oversized single directory must not be accepted")
        } catch ProjectFileIndex.RemoteIndexError.tooLarge {
            let commands = await runner.commands
            XCTAssertEqual(commands.count, 3)
            XCTAssertTrue(commands.last?.contains("find -H") == true)
            XCTAssertTrue(commands.last?.contains("head -c") == true,
                          "The byte cap must run before the SSH transport reads the listing")
        }
    }

    func testRemoteFallbackLimitsDirectoryBudgetWithoutRecursingForever() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<420 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("folder-\(index)"),
                withIntermediateDirectories: true
            )
        }
        let result = try await ProjectFileIndex.loadRemote(
            in: root.path, backend: LocalWorkspaceBackend.shared
        )
        XCTAssertTrue(result.limited, "Plain-directory fallback must report incomplete results")
        XCTAssertTrue(result.files.isEmpty)
    }

    func testPlainDirectoryFallbackSkipsVCSMetadataAndHonorsCancellation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("alpha", "nested/a.swift", in: root)
        try write("bravo", "b.swift", in: root)
        try write("internal", ".git/objects/private", in: root)

        let files = ProjectFileIndex.load(in: root.path)
        XCTAssertEqual(files.map(\.relativePath), ["b.swift", "nested/a.swift"])
        XCTAssertEqual(files.first?.absolutePath, root.appendingPathComponent("b.swift").path)

        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ProjectFileIndex.load(in: root.path)
        }.value
        XCTAssertTrue(cancelled.isEmpty, "A canceled index must not publish stale files")
    }
}
