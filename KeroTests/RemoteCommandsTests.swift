import Darwin
import Foundation
import XCTest
@testable import kero

final class RemoteCommandsTests: XCTestCase {
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
        let counts = RemoteCommands.parseUntrackedLineCounts("3\t27\t/repo/a.txt\n1\t0\t/repo/link\n")
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(counts[0].path, "/repo/a.txt")
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
