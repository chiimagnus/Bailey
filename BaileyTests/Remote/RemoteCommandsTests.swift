import Darwin
import Foundation
import XCTest
@testable import Bailey

private actor BatchDirectoryRunnerFixture: RemoteCommandRunner {
    private(set) var calls = 0
    private var expectedPaths: [String] = []
    private var entries: [[WorkspaceEntry]?] = []

    func configure(paths: [String], entries: [[WorkspaceEntry]?]) {
        expectedPaths = paths
        self.entries = entries
    }

    func run(_ argv: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> (status: Int32, stdout: Data, stderr: Data)
    {
        calls += 1
        let script = String(decoding: stdin ?? Data(), as: UTF8.self)
        guard argv == ["sh", "-s"],
              expectedPaths.allSatisfy({ script.contains(RemoteCommands.quote($0)) }),
              let tag = script.components(separatedBy: "'").first(where: {
                  $0.count == 36 && $0.filter({ $0 == "-" }).count == 4
              })
        else { return (1, Data(), Data("bad batch".utf8)) }
        var output = Data()
        for (index, directoryEntries) in entries.enumerated() {
            for entry in directoryEntries ?? [] {
                output.append(Data("\(entry.isSymlink ? "l" : entry.isDirectory ? "d" : "f")\t\(entry.isDirectory ? "d" : "f")\t\(entry.name)\0".utf8))
            }
            output.append(Data("\n\(tag) \(index) \(directoryEntries == nil ? 44 : 0)\n".utf8))
        }
        return (0, output, Data())
    }
}

private actor GitRootRunnerFixture: RemoteCommandRunner {
    private(set) var result: (status: Int32, stdout: Data, stderr: Data) = (128, Data(), Data())
    func set(_ status: Int32, output: String, error: String) {
        result = (status, Data(output.utf8), Data(error.utf8))
    }
    func run(_ argv: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> (status: Int32, stdout: Data, stderr: Data) { result }
}

private actor LocalShellRunnerFixture: RemoteCommandRunner {
    private var raceDestination: (path: String, directory: Bool)?
    private var stageInterruption: String?

    func insertDestinationImmediatelyBeforeMove(_ path: String, asDirectory: Bool = false) {
        raceDestination = (path, asDirectory)
    }
    func interruptDuringCaseOnlyRename(signal: Bool = false) {
        stageInterruption = signal ? "kill -TERM $$" : "exit 70"
    }

    func run(_ argv: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> (status: Int32, stdout: Data, stderr: Data)
    {
        guard argv.count == 1 else { return (1, Data(), Data("unexpected argv".utf8)) }
        var command = argv[0]
        if let stageInterruption {
            self.stageInterruption = nil
            command = command.replacingOccurrences(
                of: "\"$temp/item\" || exit 1",
                with: "\"$temp/item\" || exit 1; " + stageInterruption
            )
        }
        if let raceDestination {
            self.raceDestination = nil
            let marker = command.contains("mv -n -- ") ? "mv -n -- " : "mv -- "
            let mutation = raceDestination.directory
                ? "mkdir -- \(RemoteCommands.quote(raceDestination.path)); "
                : "printf 'concurrent target' > \(RemoteCommands.quote(raceDestination.path)); "
            command = command.replacingOccurrences(of: marker, with: mutation + marker)
        }
        let result = try await LocalWorkspaceBackend.shared.run(
            argv: ["/bin/sh", "-c", command], cwd: nil, env: nil,
            stdin: stdin, timeout: timeout
        )
        return (result.status, result.stdout, result.stderr)
    }
}

final class RemoteCommandsTests: XCTestCase {
    func testLocalCommandTimeoutDoesNotWaitForInheritedOutputPipe() async throws {
        for descriptor in [1, 2] {
            for parentExitsImmediately in [false, true] {
                let fixture = """
                    import os, time
                    if os.fork() == 0:
                        os.setsid()
                        time.sleep(1.5)
                        os.write(\(descriptor), b"inherited pipe still open\\n")
                        os._exit(0)
                    \(parentExitsImmediately ? "os._exit(0)" : "time.sleep(0.6)")
                    """
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    _ = try await LocalWorkspaceBackend.shared.run(
                        argv: ["/usr/bin/python3", "-c", fixture], cwd: nil, env: nil,
                        stdin: nil, timeout: 0.2
                    )
                    XCTFail("Inherited output pipe must not bypass the command deadline")
                } catch WorkspaceError.timedOut {}
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.85,
                                  "Descendant-held pipes cannot extend the command timeout")
            }
        }
    }

    func testLocalCommandDrainsLargeStdoutAndStderrWithoutDataLoss() async throws {
        let fixture = """
            import sys
            sys.stdout.buffer.write(b"A" * 262144)
            sys.stdout.flush()
            sys.stderr.buffer.write(b"B" * 262144)
            sys.stderr.flush()
            """
        let result = try await LocalWorkspaceBackend.shared.run(
            argv: ["/usr/bin/python3", "-c", fixture], cwd: nil, env: nil,
            stdin: nil, timeout: 5
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, Data(repeating: 65, count: 262144))
        XCTAssertEqual(result.stderr, Data(repeating: 66, count: 262144))
    }

    func testSuccessfulParentExitCannotHideStalledStdinDescendant() async throws {
        let command = "sleep 2 <&0 >/dev/null 2>&1 & exit 0"
        let payload = Data(repeating: 0x41, count: 1 << 20)

        let localStart = ProcessInfo.processInfo.systemUptime
        do {
            let result = try await LocalWorkspaceBackend.shared.run(
                argv: ["/bin/sh", "-c", command], cwd: nil, env: nil,
                stdin: payload, timeout: 0.25
            )
            XCTAssertNotEqual(result.status, 0, "Unconsumed stdin cannot be considered successful")
        } catch {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - localStart, 1.5,
                          "Local process timeout must include outstanding stdin")

        let remoteStart = ProcessInfo.processInfo.systemUptime
        let remote = ProcessRemoteCommandRunner.run(
            sshPath: "/bin/sh", arguments: ["-c", command],
            stdin: payload, timeout: 0.25
        )
        XCTAssertNotEqual(remote.status, 0, "Unconsumed stdin cannot be considered successful")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - remoteStart, 1.5,
                          "Remote process timeout must include outstanding stdin")
    }

    func testLocalProcessClosedStdinReturnsStatusWithoutTerminatingHost() async throws {
        let result = try await LocalWorkspaceBackend.shared.run(
            argv: ["/bin/sh", "-c", "exit 52"], cwd: nil, env: nil,
            stdin: Data(repeating: 0x41, count: 1 << 20), timeout: 5
        )
        XCTAssertEqual(result.status, 52)
        do {
            let ignored = try await LocalWorkspaceBackend.shared.run(
                argv: ["/bin/sh", "-c", "exit 0"], cwd: nil, env: nil,
                stdin: Data(repeating: 0x41, count: 1 << 20), timeout: 5
            )
            XCTAssertNotEqual(ignored.status, 0, "A successful exit cannot excuse dropped stdin bytes")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testRemoteProcessClosedStdinReturnsErrorWithoutTerminatingHost() {
        let result = ProcessRemoteCommandRunner.run(
            sshPath: "/bin/sh", arguments: ["-c", "exit 52"],
            stdin: Data(repeating: 0x41, count: 1 << 20), timeout: 5
        )
        XCTAssertEqual(result.status, 52)
        let ignored = ProcessRemoteCommandRunner.run(
            sshPath: "/bin/sh", arguments: ["-c", "exit 0"],
            stdin: Data(repeating: 0x41, count: 1 << 20), timeout: 5
        )
        XCTAssertNotEqual(ignored.status, 0, "A successful exit cannot excuse dropped stdin bytes")
    }

    func testSSHBackendEnforcesByteLimitAndPreservesBinaryWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = SSHWorkspaceBackend(runner: LocalShellRunnerFixture())
        let limit = 8 << 20
        for length in [0, limit - 1, limit, limit + 1] {
            let path = root.appendingPathComponent("file' 中文 \(length).bin")
            let bytes = Data(repeating: 0x41, count: length)
            try bytes.write(to: path)
            if length <= limit {
                let received = try await backend.read(path: path.path, maxBytes: limit)
                XCTAssertEqual(received, bytes)
            } else {
                do {
                    _ = try await backend.read(path: path.path, maxBytes: limit)
                    XCTFail("Remote read must reject maxBytes + 1")
                } catch WorkspaceError.tooLarge {}
            }
        }
        let target = root.appendingPathComponent("atomic' 二进制.bin")
        try Data("old".utf8).write(to: target)
        let replacement = Data([0x00, 0xFF, 0x0A, 0x80, 0x22, 0x27])
        try await backend.write(path: target.path, data: replacement)
        XCTAssertEqual(try Data(contentsOf: target), replacement)
        let reloaded = try await backend.read(path: target.path, maxBytes: 6)
        XCTAssertEqual(reloaded, replacement)
        do {
            _ = try await backend.read(path: root.appendingPathComponent("missing").path, maxBytes: limit)
            XCTFail("Expected remote not-found failure")
        } catch WorkspaceError.notFound {}

        let failing = GitRootRunnerFixture()
        let disconnected = SSHWorkspaceBackend(runner: failing)
        await failing.set(255, output: "", error: "Disconnected")
        do {
            _ = try await disconnected.read(path: target.path, maxBytes: limit)
            XCTFail("Connection loss must propagate")
        } catch let error as RemoteCommandFailure {
            XCTAssertEqual(error.status, 255)
        }
    }

    func testRemoteWorkspaceCopyStagesAndRejectsOccupiedTargets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source '中文")
        let target = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("a.txt")
        let payload = Data([0, 255, 10, 64, 128])
        try payload.write(to: file)
        let nested = source.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try payload.write(to: nested.appendingPathComponent("child"))
        let link = source.appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
        let backend = SSHWorkspaceBackend(runner: LocalShellRunnerFixture())

        try await backend.copy(from: file.path, to: target.appendingPathComponent("copy.txt").path)
        try await backend.copy(from: nested.path, to: target.appendingPathComponent("copied-folder").path)
        try await backend.copy(from: link.path, to: target.appendingPathComponent("copied-link").path)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("copy.txt")), payload)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("copied-folder/child")), payload)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: target.appendingPathComponent("copied-link").path
        ), "missing")
        let occupied = target.appendingPathComponent("copy.txt")
        do {
            try await backend.copy(from: file.path, to: occupied.path)
            XCTFail("Remote copy must never silently skip or replace an occupied destination")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: occupied), payload)
        do {
            try await backend.copy(from: root.appendingPathComponent("absent").path,
                                   to: target.appendingPathComponent("absent").path)
            XCTFail("A missing remote source must not silently create a copy")
        } catch WorkspaceError.notFound {}
        let dangling = target.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "absent")
        do {
            try await backend.copy(from: file.path, to: dangling.path)
            XCTFail("A dangling destination symlink is still an occupied name")
        } catch {}
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path), "absent")
        do {
            try await backend.copy(from: nested.path, to: nested.appendingPathComponent("child-copy").path)
            XCTFail("Remote recursive self-copy must be rejected")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.appendingPathComponent("child-copy").path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: target.path)),
                       Set(["copy.txt", "copied-folder", "copied-link", "dangling"]))
    }

    func testRemoteGitRootDistinguishesNonRepositoryAndSSHOrGitFailure() async throws {
        let runner = GitRootRunnerFixture()
        let backend = SSHWorkspaceBackend(runner: runner)
        await runner.set(128, output: "", error: "fatal: not a git repository")
        let missing = try await backend.gitRoot(containing: "/remote/plain")
        XCTAssertNil(missing)
        await runner.set(128, output: "", error: "fatal: detected dubious ownership")
        do {
            _ = try await backend.gitRoot(containing: "/remote/repo")
            XCTFail("Git ownership failure cannot masquerade as a plain directory")
        } catch let error as RemoteCommandFailure {
            XCTAssertEqual(error.status, 128)
        }
        await runner.set(255, output: "", error: "Connection closed")
        do {
            _ = try await backend.gitRoot(containing: "/remote/repo")
            XCTFail("SSH connection failure must propagate")
        } catch let error as RemoteCommandFailure {
            XCTAssertEqual(error.status, 255)
        }
        await runner.set(0, output: "/remote/repo\n", error: "")
        let resolved = try await backend.gitRoot(containing: "/remote/repo")
        XCTAssertEqual(resolved, "/remote/repo")
    }


    func testSSHStartupDestinationSeparatorKeepsRemoteCommandsUnfollowable() {
        XCTAssertEqual(BaileySSHPassthrough.classify(["-tt", "--", "windows"]), .interactiveSession)
        XCTAssertEqual(BaileySSHPassthrough.classify(["--", "windows", "git", "status"]), .notFollowable)
        XCTAssertEqual(BaileySSHPassthrough.classify(["--"]), .notFollowable)
        XCTAssertEqual(BaileySSHPassthrough.classify(["-tt", "windows", "git status"]), .notFollowable)
        XCTAssertEqual(BaileySSHPassthrough.classify(["-S", "/tmp/user-master", "windows"]), .notFollowable)
    }

    func testShellQuotingAndFileCommands() throws {
        XCTAssertEqual(RemoteCommands.quote("/home/ubuntu/bailey probe"), "'/home/ubuntu/bailey probe'")
        XCTAssertEqual(RemoteCommands.quote("it's"), #"'it'"'"'s'"#)

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("quote' space.txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteCommands.createFileCommand(path: file.path)]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(RemoteCommands.atomicWriteCommand(path: "/tmp/x").contains("chmod --reference="))
        XCTAssertTrue(RemoteCommands.atomicWriteCommand(path: "/tmp/x").contains("mv -f"))
    }

    func testSSHFileRenamePreservesDanglingSymlinksAndRejectsOccupiedDestinations() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runner = LocalShellRunnerFixture()
        let backend = SSHWorkspaceBackend(runner: runner)
        let missing = fixture.appendingPathComponent("missing")
        let broken = fixture.appendingPathComponent("broken")
        let moved = fixture.appendingPathComponent("moved")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: missing)
        try await backend.rename(from: broken.path, to: moved.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: moved.path), missing.path)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: broken.path))

        let source = fixture.appendingPathComponent("source")
        let occupied = fixture.appendingPathComponent("occupied")
        try Data("preserve".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: missing)
        do {
            try await backend.rename(from: source.path, to: occupied.path)
            XCTFail("A dangling destination is still occupied and must not be overwritten")
        } catch {}
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "preserve")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: occupied.path), missing.path)

        // Two hard links share an inode but are different directory entries.
        // Treating equal inode numbers as permission to overwrite loses a name.
        let hardSource = fixture.appendingPathComponent("hard-source")
        let hardDestination = fixture.appendingPathComponent("hard-destination")
        try Data("shared payload".utf8).write(to: hardSource)
        try FileManager.default.linkItem(at: hardSource, to: hardDestination)
        do {
            try await backend.rename(from: hardSource.path, to: hardDestination.path)
            XCTFail("Identical inode does not authorize replacing a separate hard-link entry")
        } catch {}
        XCTAssertEqual(try String(contentsOf: hardSource, encoding: .utf8), "shared payload")
        XCTAssertEqual(try String(contentsOf: hardDestination, encoding: .utf8), "shared payload")

        // Another process can create the destination after the shell check.
        let racingSource = fixture.appendingPathComponent("racing-source")
        let racingTarget = fixture.appendingPathComponent("racing-target")
        try Data("original source".utf8).write(to: racingSource)
        await runner.insertDestinationImmediatelyBeforeMove(racingTarget.path)
        do {
            try await backend.rename(from: racingSource.path, to: racingTarget.path)
            XCTFail("A destination created during rename may not be overwritten")
        } catch {}
        XCTAssertEqual(try String(contentsOf: racingSource, encoding: .utf8), "original source")
        XCTAssertEqual(try String(contentsOf: racingTarget, encoding: .utf8), "concurrent target")

        let directoryRaceSource = fixture.appendingPathComponent("race-directory-source")
        let directoryRaceDestination = fixture.appendingPathComponent("race-directory-destination")
        try Data("must not move into folder".utf8).write(to: directoryRaceSource)
        await runner.insertDestinationImmediatelyBeforeMove(directoryRaceDestination.path, asDirectory: true)
        do {
            try await backend.rename(from: directoryRaceSource.path, to: directoryRaceDestination.path)
            XCTFail("Concurrent directory creation cannot convert rename into move-inside-directory")
        } catch {}
        XCTAssertEqual(try String(contentsOf: directoryRaceSource, encoding: .utf8), "must not move into folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directoryRaceDestination.path), [])

        let directorySource = fixture.appendingPathComponent("race-source-folder")
        let destinationDirectory = fixture.appendingPathComponent("race-target-folder")
        try FileManager.default.createDirectory(at: directorySource, withIntermediateDirectories: true)
        try Data("nested content".utf8).write(to: directorySource.appendingPathComponent("nested.txt"))
        await runner.insertDestinationImmediatelyBeforeMove(destinationDirectory.path, asDirectory: true)
        do {
            try await backend.rename(from: directorySource.path, to: destinationDirectory.path)
            XCTFail("Concurrent directory creation cannot move a source directory into another directory")
        } catch {}
        XCTAssertEqual(try String(contentsOf: directorySource.appendingPathComponent("nested.txt"), encoding: .utf8),
                       "nested content")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path), [])

        for signal in [false, true] {
            let interruptedSource = fixture.appendingPathComponent("interrupted-source-\(signal)")
            let interruptedTarget = fixture.appendingPathComponent("interrupted-hardlink-\(signal)")
            try Data("interrupt-safe".utf8).write(to: interruptedSource)
            try FileManager.default.linkItem(at: interruptedSource, to: interruptedTarget)
            await runner.interruptDuringCaseOnlyRename(signal: signal)
            do {
                try await backend.rename(from: interruptedSource.path, to: interruptedTarget.path)
                XCTFail("An interrupted staged rename must fail")
            } catch {}
            XCTAssertEqual(try String(contentsOf: interruptedSource, encoding: .utf8), "interrupt-safe")
            XCTAssertEqual(try String(contentsOf: interruptedTarget, encoding: .utf8), "interrupt-safe")
            let residual = try FileManager.default.contentsOfDirectory(atPath: fixture.path)
            XCTAssertFalse(residual.contains { $0.hasPrefix(".bailey-rename.") })
        }

        let escaped = fixture.appendingPathComponent("-quotes'\tnewline\n😀")
        let escapedTarget = fixture.appendingPathComponent("-renamed'\n😀")
        try Data("special path payload".utf8).write(to: escaped)
        try await backend.rename(from: escaped.path, to: escapedTarget.path)
        XCTAssertEqual(try String(contentsOf: escapedTarget, encoding: .utf8), "special path payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))

        let missingSource = fixture.appendingPathComponent("absent-source")
        do {
            try await backend.rename(from: missingSource.path, to: fixture.appendingPathComponent("absent-target").path)
            XCTFail("A nonexistent remote source must fail")
        } catch WorkspaceError.notFound {}

        let lowerLink = fixture.appendingPathComponent("dangling-lower")
        let upperLink = fixture.appendingPathComponent("DANGLING-LOWER")
        try FileManager.default.createSymbolicLink(at: lowerLink, withDestinationURL: missing)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: upperLink.path)) == missing.path {
            try await backend.rename(from: lowerLink.path, to: upperLink.path)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: upperLink.path), missing.path)
            let present = try FileManager.default.contentsOfDirectory(atPath: fixture.path)
            XCTAssertTrue(present.contains("DANGLING-LOWER"))
            XCTAssertFalse(present.contains("dangling-lower"))
        }

        let lower = fixture.appendingPathComponent("case.txt")
        let upper = fixture.appendingPathComponent("Case.txt")
        try Data("case preserved".utf8).write(to: lower)
        if FileManager.default.fileExists(atPath: upper.path) {
            try await backend.rename(from: lower.path, to: upper.path)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.path).filter {
                $0.lowercased() == "case.txt"
            }, ["Case.txt"])
        }
    }

    func testDirectoryStatAndProcessParsers() {
        let listing = Data("f\tf\tscript.sh\0d\td\tsub\0l\td\tlink-to-sub\0l\tL\tbroken\0".utf8)
        let entries = RemoteCommands.parseDirectoryListing(listing)
        XCTAssertEqual(entries, [
            WorkspaceEntry(name: "script.sh", isDirectory: false, isSymlink: false),
            WorkspaceEntry(name: "sub", isDirectory: true, isSymlink: false),
            WorkspaceEntry(name: "link-to-sub", isDirectory: true, isSymlink: true),
            WorkspaceEntry(name: "broken", isDirectory: false, isSymlink: true),
        ])

        let stat = RemoteCommands.parseStat("regular file\t29\t1788328250\t755\nregular file\t29\t1788328250\t755")
        XCTAssertEqual(stat?.mode, 0o755)
        XCTAssertEqual(stat?.stat.size, 29)
        XCTAssertEqual(stat?.stat.isRegular, true)
        XCTAssertEqual(stat?.stat.isSymlink, false)

        let ps = """
              313852  313851  0.0   6144 sshd: ubuntu@pts/0
              313855  313852  0.1   5632 -bash
              314000  313855  12.5 104448 /usr/bin/node /home/ubuntu/app/server.js
              314001  314000  0.0   2048 [kworker]
            """
        let rows = RemoteCommands.parseProcessList(ps)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[2].process.pid, 314000)
        XCTAssertEqual(rows[2].process.name, "node")
        let snapshot = RemoteCommands.snapshot(rows: rows, descendantsOf: 313855)
        XCTAssertEqual(snapshot.descendants.map(\.pid), [314000, 314001])
    }

    func testGitBatchAndPortParsers() {
        let input = RemoteCommands.untrackedLineCountsInput(paths: ["/a b", "/c"])
        XCTAssertEqual(input, Data("/a b\u{0}/c\u{0}".utf8))
        let counts = RemoteCommands.parseUntrackedLineCounts("3\t27\t1\n1\t0\t1\n",
            maximumFiles: 2, totalByteBudget: 27, perFileByteCap: 27)!
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(counts[0].bytesRead, 27)
        XCTAssertEqual(counts[0].lines, 3)

        var batch = Data("/repo".utf8)
        batch.append(Data("\nTAG-1 root 0\n".utf8))
        batch.append(Data([0x61, 0x00, 0x62]))
        batch.append(Data("\nTAG-1 st 1\n".utf8))
        let parsed = RemoteCommands.parseBatch(batch, tag: "TAG-1")
        XCTAssertEqual(parsed["root"]?.status, 0)
        XCTAssertEqual(parsed["st"]?.stdout, Data([0x61, 0x00, 0x62]))

        let ports = RemoteCommands.parseListeningPorts("""
            LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1234,fd=3))
            LISTEN 0 511 127.0.0.1:8000 0.0.0.0:* users:(("python3",pid=314000,fd=3))
            """)
        XCTAssertEqual(ports.count, 2)
        XCTAssertTrue(ports.contains(WorkspacePort(port: 22, pid: 1234)))
        XCTAssertTrue(ports.contains(WorkspacePort(port: 8000, pid: 314000)))
    }

    func testUntrackedCountsRejectForgedFilenameRecordsAndNegativeCounts() {
        for output in ["-1\t-1\t/repo/file\n", "0\t0\t/repo/file\n99999999\t0\tforged\n",
                       "99999999\t0\t1\n", "1\t20\t1\n", "0\t0\t0", "0\t0\t2\n",
                       "0\t8\t1\n0\t8\t1\n", "1\t1\t1\n\n"] {
            XCTAssertNil(RemoteCommands.parseUntrackedLineCounts(output,
                maximumFiles: 2, totalByteBudget: 10, perFileByteCap: 8), output)
        }
    }

    func testUntrackedCountScriptPreservesUnusualNamesAndBoundsRealReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("name\n99999999\t0\t1")
        let empty = directory.appendingPathComponent("empty")
        let binary = directory.appendingPathComponent("binary")
        let lateNul = directory.appendingPathComponent("late-nul")
        let link = directory.appendingPathComponent("link")
        let large = directory.appendingPathComponent("large")
        try Data("one\ntwo".utf8).write(to: source)
        try Data().write(to: empty)
        try Data(repeating: 0, count: 20_000).write(to: binary)
        try (Data(repeating: 65, count: 8_000) + Data([0, 10])).write(to: lateNul)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        try Data(repeating: 65, count: 20_001).write(to: large)
        let paths = [source, empty, binary, lateNul, link, large].map(\.path)
        let script = RemoteCommands.untrackedLineCountsCommand(totalByteBudget: 40_000, perFileByteCap: 20_000)
            .replacingOccurrences(of: "stat -c %s --", with: "stat -f %z --")
        let result = try await LocalWorkspaceBackend.shared.run(
            argv: ["/bin/sh", "-c", script], cwd: nil, env: nil,
            stdin: RemoteCommands.untrackedLineCountsInput(paths: paths), timeout: 10
        )
        XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
        let output = String(decoding: result.stdout, as: UTF8.self)
        let counts = try XCTUnwrap(RemoteCommands.parseUntrackedLineCounts(output,
            maximumFiles: paths.count, totalByteBudget: 40_000, perFileByteCap: 20_000))
        XCTAssertEqual(counts.map(\.lines), [2, 0, 0, 1, 1, 0])
        XCTAssertEqual(counts.map(\.bytesRead), [7, 0, 8_000, 8_002, 0, 0])
        XCTAssertEqual(counts.map(\.complete), [true, true, true, true, true, false])
        for (index, url) in [source, empty, binary, lateNul, link, large].enumerated() {
            let local = try GitStatusModel.textLineCount(at: url, maximumBytes: 20_000,
                deadline: Date().addingTimeInterval(10))
            XCTAssertEqual(local.lines, counts[index].lines)
            XCTAssertEqual(local.bytesRead, counts[index].bytesRead)
            XCTAssertEqual(local.complete, counts[index].complete)
        }
        XCTAssertFalse(output.contains(source.path))
    }

    func testLocalLineReaderNeverReadsPastRemainingBudgetAndPropagatesFailure() throws {
        for cap in [0, 3, 7_999, 8_000, 8_001, 100_001] {
            var offset = 0
            let count = try GitStatusModel.countTextLines(maximumBytes: cap) { requested in
                XCTAssertLessThanOrEqual(requested, cap - offset)
                XCTAssertGreaterThan(requested, 0)
                offset += requested
                return Data(repeating: 10, count: requested)
            }
            XCTAssertEqual(count.lines, cap)
            XCTAssertEqual(count.bytesRead, cap)
            XCTAssertEqual(offset, cap)
        }
        var reads = 0
        XCTAssertThrowsError(try GitStatusModel.countTextLines(maximumBytes: 9_000) { requested in
            reads += 1
            if reads == 2 { throw WorkspaceError.notFound }
            return Data(repeating: 65, count: requested)
        })
    }

    func testRemoteCountBudgetSurvivesGrowthAfterStatAndCapsTheProbe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("growing")
        let next = directory.appendingPathComponent("next")
        let marker = directory.appendingPathComponent("grow-once")
        try Data("a".utf8).write(to: file)
        try Data("b".utf8).write(to: next)
        try Data().write(to: marker)
        let growing = """
            stat() {
            /usr/bin/stat -f %z -- "$4"
            if [ -e "\(marker.path)" ]; then
            /bin/rm "\(marker.path)"; printf "0123456789" >> "$4"
            fi
            }
            """
        let command = RemoteCommands.untrackedLineCountsCommand(totalByteBudget: 3, perFileByteCap: 3)
        let script = command.replacingOccurrences(of: "set -o pipefail", with: growing + "\nset -o pipefail")
        let result = try await LocalWorkspaceBackend.shared.run(
            argv: ["/bin/sh", "-c", script], cwd: nil, env: nil,
            stdin: RemoteCommands.untrackedLineCountsInput(paths: [file.path, next.path]), timeout: 10
        )
        XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
        let counts = try XCTUnwrap(RemoteCommands.parseUntrackedLineCounts(
            String(decoding: result.stdout, as: UTF8.self), maximumFiles: 2,
            totalByteBudget: 3, perFileByteCap: 3))
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts.first?.bytesRead, 3)
        XCTAssertEqual(counts.first?.lines, 0)
        XCTAssertEqual(counts.first?.complete, false)
        XCTAssertEqual(try Data(contentsOf: file).count, 11)
    }

    func testUntrackedDirectoryDoesNotFailTheRemoteSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await LocalWorkspaceBackend.shared.run(
            argv: ["/bin/sh", "-c", RemoteCommands.untrackedLineCountsCommand(
                totalByteBudget: 10, perFileByteCap: 10)], cwd: nil, env: nil,
            stdin: RemoteCommands.untrackedLineCountsInput(paths: [directory.path]), timeout: 10)
        XCTAssertEqual(result.status, 0)
        let counts = try XCTUnwrap(RemoteCommands.parseUntrackedLineCounts(
            String(decoding: result.stdout, as: UTF8.self), maximumFiles: 1,
            totalByteBudget: 10, perFileByteCap: 10))
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts.first?.lines, 0)
        XCTAssertEqual(counts.first?.bytesRead, 0)
        XCTAssertEqual(counts.first?.complete, false)
    }

    func testBatchDirectoryListingKeepsFailuresIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("dir' one")
        let two = root.appendingPathComponent("二")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
        try Data().write(to: one.appendingPathComponent("a\nline.txt"))
        try Data().write(to: two.appendingPathComponent("b.txt"))

        let runner = BatchDirectoryRunnerFixture()
        let paths = [one.path, root.appendingPathComponent("missing").path, two.path]
        await runner.configure(paths: paths, entries: [
            [WorkspaceEntry(name: "a\nline.txt", isDirectory: false, isSymlink: false)],
            nil,
            [WorkspaceEntry(name: "b.txt", isDirectory: false, isSymlink: false)],
        ])
        let backend = SSHWorkspaceBackend(runner: runner)
        let result = await backend.list(directories: paths)
        XCTAssertEqual(result[one.path]?.map(\.name), ["a\nline.txt"])
        XCTAssertEqual(result[two.path]?.map(\.name), ["b.txt"])
        XCTAssertNil(result[root.appendingPathComponent("missing").path])
        let calls = await runner.calls
        XCTAssertEqual(calls, 1)
    }

    func testLocalPortProbe() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketFD, 0)
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, length) == 0 && listen(socketFD, 1) == 0
                    && getsockname(socketFD, $0, &length) == 0
            }
        }
        guard listening else { return XCTFail("Could not bind loopback fixture") }
        let port = UInt16(bigEndian: address.sin_port)
        XCTAssertFalse(RemoteCommands.isLocalPortFree(port))
        XCTAssertFalse(RemoteCommands.isLocalPortFree(0))
    }
}
