import Darwin
import Foundation
import XCTest
@testable import kero

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
    func run(_ argv: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> (status: Int32, stdout: Data, stderr: Data)
    {
        guard argv.count == 1 else { return (1, Data(), Data("unexpected argv".utf8)) }
        let command = argv[0].replacingOccurrences(of: "stat -c '%d:%i' --", with: "stat -f '%d:%i' --")
        let result = try await LocalWorkspaceBackend.shared.run(
            argv: ["/bin/sh", "-c", command], cwd: nil, env: nil,
            stdin: stdin, timeout: timeout
        )
        return (result.status, result.stdout, result.stderr)
    }
}

final class RemoteCommandsTests: XCTestCase {
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
        XCTAssertEqual(KeroSSHPassthrough.classify(["-tt", "--", "windows"]), .interactiveSession)
        XCTAssertEqual(KeroSSHPassthrough.classify(["--", "windows", "git", "status"]), .notFollowable)
        XCTAssertEqual(KeroSSHPassthrough.classify(["--"]), .notFollowable)
        XCTAssertEqual(KeroSSHPassthrough.classify(["-tt", "windows", "git status"]), .notFollowable)
        XCTAssertEqual(KeroSSHPassthrough.classify(["-S", "/tmp/user-master", "windows"]), .notFollowable)
    }

    func testShellQuotingAndFileCommands() throws {
        XCTAssertEqual(RemoteCommands.quote("/home/ubuntu/kero probe"), "'/home/ubuntu/kero probe'")
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
        let backend = SSHWorkspaceBackend(runner: LocalShellRunnerFixture())
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
