import Darwin
import Foundation


@main
enum RemoteCommandsCheck {
    static func main() throws { try RemoteCommands.checkCurrentCommands() }
}

extension RemoteCommands {
    static func checkCurrentCommands() throws {
        assert(quote("/home/ubuntu/kero probe") == "'/home/ubuntu/kero probe'")
        assert(quote("it's") == #"'it'"'"'s'"#)


        let held = socket(AF_INET, SOCK_STREAM, 0)
        var heldAddress = sockaddr_in()
        heldAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        heldAddress.sin_family = sa_family_t(AF_INET)
        heldAddress.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var heldLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &heldAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(held, $0, heldLength) == 0 && listen(held, 1) == 0
                    && getsockname(held, $0, &heldLength) == 0
            }
        }
        let heldPort = UInt16(bigEndian: heldAddress.sin_port)
        if held >= 0, listening, heldPort != 0 {
            assert(!isLocalPortFree(heldPort))
            close(held)
            assert(isLocalPortFree(heldPort))
        } else {
            close(held)
        }
        assert(!isLocalPortFree(0))

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let created = fixture.appendingPathComponent("quote' space.txt")
        func create(_ path: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", createFileCommand(path: path)]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        let createdStatus = try create(created.path)
        precondition(createdStatus == 0)
        try Data("preserve".utf8).write(to: created)
        let existingStatus = try create(created.path)
        precondition(existingStatus != 0)
        let preserved = try Data(contentsOf: created)
        precondition(preserved == Data("preserve".utf8))
        let dangling = fixture.appendingPathComponent("dangling")
        let missing = fixture.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
        let danglingStatus = try create(dangling.path)
        precondition(danglingStatus != 0)
        precondition(!FileManager.default.fileExists(atPath: missing.path))

        let discovery = shellDiscoveryCommand()
        assert(discovery.contains("$SSH_CONNECTION"))
        assert(discovery.contains("sshd*"))
        assert(discovery.contains("MSYS*|CYGWIN*"))
        assert(discovery.contains("/proc/$p/exe"))
        assert(!discovery.contains("LC_KERO_TERMINAL"))
        let tagged = shellDiscoveryCommand(terminalTag: "test-uuid-1234")
        assert(tagged.contains("'LC_KERO_TERMINAL=test-uuid-1234'"))

        let found = parseShellDiscovery("314134 /home/ubuntu/kero-probe-1788328105/sub\n")
        assert(found?.pid == 314134)
        assert(found?.directory == "/home/ubuntu/kero-probe-1788328105/sub")
        assert(parseShellDiscovery("")  == nil)
        assert(parseShellDiscovery("314134\n") == nil)
        assert(parseShellDiscovery("42 /home/ubuntu/my project")?.directory
            == "/home/ubuntu/my project")

        assert(statCommand(path: "/tmp/x").contains("stat --printf '%F\\t%s\\t%Y\\t%a\\n' -- '/tmp/x'"))
        assert(statCommand(path: "/tmp/x").contains("stat -L --printf"))

        assert(
            listDirectoryCommand(path: "/home/ubuntu/kero-probe-1788328105")
                == "find -H '/home/ubuntu/kero-probe-1788328105' -maxdepth 1 -mindepth 1"
                + " -printf '%y\\t%Y\\t%f\\0'")
        assert(listDirectoryCommand(path: "/tmp/sub-link").hasPrefix("find -H "))
        let listing = Data(
            "f\tf\tscript.sh\0d\td\tsub\0l\td\tlink-to-sub\0l\tL\tbroken\0".utf8)
        let entries = parseDirectoryListing(listing)
        assert(entries.count == 4)
        assert(entries[0] == WorkspaceEntry(name: "script.sh", isDirectory: false, isSymlink: false))
        assert(entries[1] == WorkspaceEntry(name: "sub", isDirectory: true, isSymlink: false))

        assert(entries[2] == WorkspaceEntry(name: "link-to-sub", isDirectory: true, isSymlink: true))
        assert(entries[3] == WorkspaceEntry(name: "broken", isDirectory: false, isSymlink: true))

        let statOutput = "regular file\t29\t1788328250\t755\nregular file\t29\t1788328250\t755"
        let parsed = parseStat(statOutput)
        assert(parsed?.mode == 0o755)
        assert(parsed?.stat.isRegular == true)
        assert(parsed?.stat.isSymlink == false)
        assert(parsed?.stat.size == 29)
        assert(parsed?.stat.mtime == Date(timeIntervalSince1970: 1_788_328_250))
        let symlinkToDirectory = parseStat("symbolic link\t3\t1788328250\t777\ndirectory\t4096\t1788328000\t755")
        assert(symlinkToDirectory?.stat.isSymlink == true)
        assert(symlinkToDirectory?.stat.isDirectory == true)
        assert(symlinkToDirectory?.mode == 0o755)

        let broken = parseStat("symbolic link\t7\t1788328250\t777")
        assert(broken?.stat.isSymlink == true)
        assert(broken?.stat.isDirectory == false)
        assert(parseStat("") == nil)

        assert(atomicWriteCommand(path: "/home/ubuntu/a b.sh").hasSuffix("_ '/home/ubuntu/a b.sh'"))
        assert(atomicWriteCommand(path: "/tmp/x").contains("chmod --reference="))
        assert(atomicWriteCommand(path: "/tmp/x").contains("mv -f"))

        let counts = untrackedLineCountsCommand(totalByteBudget: 32, perFileByteCap: 8)
        assert(counts.hasPrefix("bash -c '") && counts.hasSuffix("'"))

        assert(!counts.dropFirst("bash -c '".count).dropLast().contains("'"))
        assert(counts.contains("budget=32") && counts.contains("cap=8"))
        assert(untrackedLineCountsInput(paths: ["/a b", "/c"]) == Data("/a b\u{0}/c\u{0}".utf8))

        let countOutput = "3\t27\t/repo/a.txt\n1\t0\t/repo/link\n0\t8000\t/repo/blob.bin\n0\t0\t/repo/huge\n"
        let parsedCounts = parseUntrackedLineCounts(countOutput)
        assert(parsedCounts.count == 4)
        assert(parsedCounts[0] == ("/repo/a.txt", 3, 27))
        assert(parsedCounts[1] == ("/repo/link", 1, 0))
        assert(parsedCounts[2] == ("/repo/blob.bin", 0, 8000))
        assert(parsedCounts[3] == ("/repo/huge", 0, 0))
        assert(parsedCounts.reduce(0) { $0 + $1.lines } == 4)

        assert(parseUntrackedLineCounts("2\t4\t/repo/od\td")[0].path == "/repo/od\td")
        assert(parseUntrackedLineCounts("rubbish").isEmpty)

        let operation = repositoryOperationCommand(gitDirectory: "/r/.git")
        assert(operation.contains("'/r/.git'\"/$n\""))
        assert(operation.contains("rebase-merge rebase-apply MERGE_HEAD"))
        let walk = gitMetadataAtOrAboveCommand(path: "/a/b")
        assert(walk.hasPrefix("d='/a/b';") && walk.contains("dirname"))


        let batch = batchCommand(
            [("rev-parse --show-toplevel", "git rev-parse"), ("st", "git status")],
            tag: "TAG-1")
        assert(batch.contains("{ git rev-parse ; }"))
        assert(batch.contains("printf '\\n%s %s %d\\n' 'TAG-1' 'rev-parse --show-toplevel' \"$?\""))

        var batchOut = Data("/repo".utf8)
        batchOut.append(Data("\nTAG-1 rev-parse --show-toplevel 0\n".utf8))
        batchOut.append(Data([0x61, 0x00, 0x62]))
        batchOut.append(Data("\nTAG-1 st 1\n".utf8))
        let parsedBatch = parseBatch(batchOut, tag: "TAG-1")
        assert(parsedBatch["rev-parse --show-toplevel"]?.status == 0)
        assert(parsedBatch["rev-parse --show-toplevel"]
            .map { String(decoding: $0.stdout, as: UTF8.self) } == "/repo")
        assert(parsedBatch["st"]?.status == 1)
        assert(parsedBatch["st"]?.stdout == Data([0x61, 0x00, 0x62]))
        assert(parseBatch(Data(), tag: "TAG-1").isEmpty)

        let psOutput = """
              313852  313851  0.0   6144 sshd: ubuntu@pts/0
              313855  313852  0.1   5632 -bash
              314000  313855  12.5 104448 /usr/bin/node /home/ubuntu/app/server.js
              314001  314000  0.0   2048 [kworker]
            """
        let rows = parseProcessList(psOutput)
        assert(rows.count == 4)
        assert(rows[2].process.pid == 314000)
        assert(rows[2].process.name == "node")
        assert(rows[2].process.executable == "/usr/bin/node")
        assert(rows[2].process.cpu == 12.5)
        assert(rows[2].process.memoryKB == 104448)
        let tree = snapshot(rows: rows, descendantsOf: 313855)
        assert(tree.descendants.map(\.pid) == [314000, 314001])
        assert(tree.namesByPid[313855] == "-bash")

        let ssOutput = """
            LISTEN 0      4096         0.0.0.0:22        0.0.0.0:* users:(("sshd",pid=1234,fd=3))
            LISTEN 0      4096            [::]:22           [::]:* users:(("sshd",pid=1234,fd=4))
            LISTEN 0      511        127.0.0.1:8000       0.0.0.0:* users:(("python3",pid=314000,fd=3))
            """
        let ssPorts = parseListeningPorts(ssOutput)

        assert(ssPorts.count == 2)
        assert(ssPorts.contains(WorkspacePort(port: 22, pid: 1234)))
        assert(ssPorts.contains(WorkspacePort(port: 8000, pid: 314000)))

        let lsofOutput = """
            p1234
            n*:22
            p314000
            n127.0.0.1:8000
            """
        let lsofPorts = parseListeningPorts(lsofOutput)
        assert(lsofPorts == [
            WorkspacePort(port: 22, pid: 1234),
            WorkspacePort(port: 8000, pid: 314000),
        ])
        assert(parseListeningPorts("").isEmpty)
        print("PASS: remote command quoting, discovery, files, Git batch, processes and loopback occupancy")
    }
}
