import Darwin
import Foundation
import XCTest
@testable import kero

final class RemoteCommandsTests: XCTestCase {
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
