//
//  RemoteCommands.swift
//  kero
//

import Darwin
import Foundation

/// Builds the shell command lines Kero runs on a Linux remote over the ssh
/// multiplexing channel, and parses what they print back.
///
/// Pure string work, so every command can be read and tested without a network.
/// The strings themselves were proven against Ubuntu 24.04 with OpenSSH 9.6;
/// the notes in each builder record what the probe found.
nonisolated enum RemoteCommands {
    static func createFileCommand(path: String) -> String {
        let destination = quote(path)
        return "[ ! -e \(destination) ] && [ ! -L \(destination) ] && (set -C; : > \(destination))"
    }

    // MARK: - Quoting

    /// Wraps a path in single quotes for `sh`, which has no escape character
    /// inside them — a literal quote has to close, escape, and reopen.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Double quotes survive both POSIX shells and Windows' OpenSSH zsh
    /// wrapper, which can treat single quotes in argv as literal characters.
    static func doubleQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`") + "\""
    }

    // MARK: - Port forwarding


    /// Whether nothing on this Mac is listening on `port` where `localhost`
    /// could reach it, so a forward on that number would be the only thing
    /// answering there.
    ///
    /// Probes four binds, each with `SO_REUSEADDR`: `127.0.0.1`, `0.0.0.0`,
    /// `::1` and `::`. The option is what ssh sets on its own listener, and it
    /// makes the probe ignore connections lingering in TIME_WAIT (30 s on
    /// macOS), which follow every forward whose side closed first. Without it
    /// a forward that was just dropped, after a wake or a reconnect, would
    /// read as busy and move to a different port. The cost is that on macOS a
    /// reusable bind to `127.0.0.1:N` succeeds beside a server on `*:N`, so
    /// the wildcard addresses are probed too: binding the exact address a live
    /// listener holds fails even with the option.
    ///
    /// Both families matter because `localhost` can resolve to `::1` first on
    /// macOS: a local process on `[::1]:N` would win over an IPv4 forward.
    /// A Mac with no IPv6 just skips those two.
    static func isLocalPortFree(_ port: UInt16) -> Bool {
        guard port != 0 else { return false }
        return canBind(family: AF_INET, loopback: true, port: port)
            && canBind(family: AF_INET, loopback: false, port: port)
            && canBind(family: AF_INET6, loopback: true, port: port)
            && canBind(family: AF_INET6, loopback: false, port: port)
    }

    private static func canBind(family: Int32, loopback: Bool, port: UInt16) -> Bool {
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return family == AF_INET6 && errno == EAFNOSUPPORT }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let bound: Int32
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = loopback ? in6addr_loopback : in6addr_any
            bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = (loopback ? INADDR_LOOPBACK : INADDR_ANY).bigEndian
            bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if bound == 0 { return true }
        // No IPv6 loopback configured: nothing can be listening there either.
        return family == AF_INET6 && errno == EADDRNOTAVAIL
    }


    // MARK: - Finding the interactive shell

    /// Finds the interactive shell on this ssh connection and reports where it
    /// is, as one line: `<pid> <directory>`.
    ///
    /// Every process on one ssh connection is given the same `SSH_CONNECTION`,
    /// so the session identifies itself with no environment variable sent from
    /// the Mac and nothing required of the remote's `AcceptEnv`. The string
    /// must expand on the remote, so `$SSH_CONNECTION` is deliberately left
    /// unexpanded here — never interpolate a local value into it.
    ///
    /// Two filters narrow the candidates, both needed: the multiplexed command
    /// running this very lookup shares the connection and therefore matches,
    /// and so may other non-interactive processes.
    /// - a controlling terminal, which `ps` reports as `?` when absent
    /// - a parent named `sshd`, or `sshd-session` on OpenSSH 9.8 and later
    ///
    /// `terminalTag` additionally requires `LC_KERO_TERMINAL`, which tells two
    /// Kero sessions to the same host over separate connections apart.
    static func shellDiscoveryCommand(terminalTag: String? = nil) -> String {
        var lines = [
            "grep -lz \"SSH_CONNECTION=$SSH_CONNECTION\" /proc/[0-9]*/environ 2>/dev/null",
            "| cut -d/ -f3 | while read -r p; do",
            "t=$(ps -o tty= -p \"$p\" 2>/dev/null | tr -d ' ');",
            "case \"$t\" in ''|'?') continue;; esac;",
            "pp=$(ps -o ppid= -p \"$p\" 2>/dev/null | tr -d ' ');",
            "c=$(ps -o comm= -p \"$pp\" 2>/dev/null);",
            "case \"$c\" in sshd*) ;; *) continue;; esac;",
        ]
        if let terminalTag, !terminalTag.isEmpty {
            lines.append(
                "grep -qz \(quote("LC_KERO_TERMINAL=" + terminalTag)) "
                    + "\"/proc/$p/environ\" 2>/dev/null || continue;"
            )
        }
        lines.append("d=$(readlink \"/proc/$p/cwd\" 2>/dev/null) || continue;")
        lines.append("printf '%s %s\\n' \"$p\" \"$d\"; break; done")
        let linux = lines.joined(separator: " ")

        // MSYS/Cygwin ps has no -o format or visible sshd parent; its
        // interactive shell still exposes SSH_CONNECTION and cwd in /proc.
        // Filter by the connection first, never by a guessed process name alone.
        var windows = [
            "ps -ef 2>/dev/null | awk 'NR>1 && $4 != \"?\" {print $2}'",
            "| while read -r p; do",
            // In MSYS the STIME column can be one or two fields, so inspect
            // the executable via /proc rather than parsing ps's COMMAND field.
            "exe=$(readlink \"/proc/$p/exe\" 2>/dev/null) || continue;",
            "case \"${exe##*/}\" in sh|bash|zsh|fish|ksh|sh.exe|bash.exe|zsh.exe|fish.exe|ksh.exe) ;; *) continue;; esac;",
            "grep -qz \"SSH_CONNECTION=$SSH_CONNECTION\" \"/proc/$p/environ\" 2>/dev/null || continue;",
        ]
        if let terminalTag, !terminalTag.isEmpty {
            // Windows OpenSSH often ignores SendEnv. An absent tag is fine:
            // this connection's SSH_CONNECTION is already unique. If a tag
            // was accepted, it must belong to this pane.
            windows.append("if grep -qz 'LC_KERO_TERMINAL=' \"/proc/$p/environ\" 2>/dev/null; then")
            windows.append(
                "grep -qz \(quote("LC_KERO_TERMINAL=" + terminalTag)) "
                    + "\"/proc/$p/environ\" 2>/dev/null || continue; fi;"
            )
        }
        windows.append("d=$(readlink \"/proc/$p/cwd\" 2>/dev/null) || continue;")
        windows.append("printf '%s %s\\n' \"$p\" \"$d\"; break; done")
        return "case \"$(uname -s)\" in MSYS*|CYGWIN*) "
            + windows.joined(separator: " ") + " ;; *) " + linux + " ;; esac"
    }

    /// A directory may contain spaces, so only the first space is a separator.
    static func parseShellDiscovery(_ output: String) -> (pid: pid_t, directory: String)? {
        guard let line = output.split(separator: "\n").first.map(String.init) else {
            return nil
        }
        guard let space = line.firstIndex(of: " ") else { return nil }
        guard let pid = pid_t(line[line.startIndex..<space]) else { return nil }
        let directory = String(line[line.index(after: space)...])
        return directory.isEmpty ? nil : (pid, directory)
    }

    // MARK: - Files

    /// `%y` is the entry's own type, `%Y` the type after following symlinks —
    /// both are needed because a symlinked directory has to report as a
    /// directory *and* as a symlink, matching the local backend. NUL
    /// separators keep newlines in filenames from splitting a record.
    ///
    /// `-H` follows the starting point, and only the starting point. Without
    /// it, listing a symlink that points at a directory returns nothing at all
    /// and the file tree shows an empty folder that will not expand, where the
    /// local backend follows it. Entries below are unaffected, so a symlink
    /// inside the directory still reports as a symlink.
    static func listDirectoryCommand(path: String) -> String {
        "find -H \(quote(path)) -maxdepth 1 -mindepth 1 -printf '%y\\t%Y\\t%f\\0'"
    }

    static func parseDirectoryListing(_ output: Data) -> [WorkspaceEntry] {
        output.split(separator: 0).compactMap { record in
            guard let text = String(data: Data(record), encoding: .utf8) else { return nil }
            let fields = text.components(separatedBy: "\t")
            guard fields.count >= 3 else { return nil }
            let name = fields[2...].joined(separator: "\t")
            guard !name.isEmpty else { return nil }
            return WorkspaceEntry(
                name: name,
                isDirectory: fields[1] == "d",
                isSymlink: fields[0] == "l"
            )
        }
    }

    /// Two lines: the path itself, then the path with symlinks followed. The
    /// first says whether it is a symlink, the second describes what it
    /// resolves to, which is what the editor and file tree care about. A
    /// broken symlink fails the second `stat`, leaving one line.
    static func statCommand(path: String) -> String {
        let quoted = quote(path)
        // `--printf`, not `-c`: only the former interprets the tab and newline
        // escapes, and `-c` would return the format string with them intact.
        let format = "'%F\\t%s\\t%Y\\t%a\\n'"
        return "stat --printf \(format) -- \(quoted) 2>/dev/null; "
            + "stat -L --printf \(format) -- \(quoted) 2>/dev/null"
    }

    struct RemoteStat: Equatable {
        let stat: WorkspaceStat
        /// Permission bits as `stat -c %a` prints them, e.g. 0o755.
        let mode: UInt16
    }

    static func parseStat(_ output: String) -> RemoteStat? {
        let rows = output.split(separator: "\n").compactMap(parseStatRow)
        guard let own = rows.first else { return nil }
        // A broken symlink has no resolved row; it is still a symlink.
        let resolved = rows.count > 1 ? rows[1] : own
        return RemoteStat(
            stat: WorkspaceStat(
                isRegular: resolved.kind == "regular file" || resolved.kind == "regular empty file",
                isDirectory: resolved.kind == "directory",
                isSymlink: own.kind == "symbolic link",
                size: resolved.size,
                mtime: Date(timeIntervalSince1970: TimeInterval(resolved.mtime))
            ),
            mode: resolved.mode
        )
    }

    private static func parseStatRow(
        _ line: Substring
    ) -> (kind: String, size: Int, mtime: Int, mode: UInt16)? {
        let fields = line.components(separatedBy: "\t")
        guard fields.count >= 4,
            let size = Int(fields[1]),
            let mtime = Int(fields[2]),
            let mode = UInt16(fields[3], radix: 8)
        else { return nil }
        return (fields[0], size, mtime, mode)
    }

    /// Replaces a file's contents from standard input without ever leaving it
    /// half-written: the temporary file is renamed over the original, which is
    /// atomic within a directory. The mode is copied from the original when
    /// there is one, so an executable script stays executable.
    ///
    /// `chmod --reference` is GNU coreutils, so this is Linux-only, as the
    /// remote workspace is generally.
    static func atomicWriteCommand(path: String) -> String {
        "sh -c 'cat > \"$1.kero-tmp\" && "
            + "{ [ -e \"$1\" ] && chmod --reference=\"$1\" \"$1.kero-tmp\" || :; } && "
            + "mv -f \"$1.kero-tmp\" \"$1\"' _ \(quote(path))"
    }

    /// Counts the text lines of many files in ONE round trip.
    ///
    /// Asking per file costs two round trips each, which on a repository with a
    /// few dozen untracked files is what pushes the Git snapshot past its
    /// deadline. Paths arrive NUL-separated on standard input, so any filename
    /// survives; one line comes back per path, `lines`, `bytesRead` and the
    /// path itself, tab-separated with the path last because it is the only
    /// field that may contain a tab.
    ///
    /// The rules match the local reader exactly: a symlink counts as one line
    /// and no bytes, a file over the cap counts as nothing, a file whose first
    /// 8 KB contain a NUL is binary and charges only that probe to the budget,
    /// and a final line without a newline still counts.
    ///
    /// The script deliberately contains no single quote so it can be wrapped in
    /// one, and runs under `bash` for its NUL-separated `read`.
    static func untrackedLineCountsCommand(
        totalByteBudget: Int, perFileByteCap: Int
    ) -> String {
        let script = """
            budget=\(totalByteBudget); cap=\(perFileByteCap)
            while IFS= read -r -d "" p; do
            if [ "$budget" -le 0 ]; then break; fi
            if [ -L "$p" ]; then printf "1\\t0\\t%s\\n" "$p"; continue; fi
            if [ ! -f "$p" ]; then printf "0\\t0\\t%s\\n" "$p"; continue; fi
            sz=$(stat -c %s -- "$p" 2>/dev/null || echo 0)
            lim=$cap; if [ "$budget" -lt "$lim" ]; then lim=$budget; fi
            if [ "$sz" -gt "$lim" ]; then printf "0\\t0\\t%s\\n" "$p"; continue; fi
            if [ "$sz" -eq 0 ]; then printf "0\\t0\\t%s\\n" "$p"; continue; fi
            probe=$(head -c 8000 -- "$p" | wc -c)
            kept=$(head -c 8000 -- "$p" | LC_ALL=C tr -d "\\000" | wc -c)
            if [ "$probe" -ne "$kept" ]; then
            budget=$((budget - probe)); printf "0\\t%s\\t%s\\n" "$probe" "$p"; continue
            fi
            n=$(LC_ALL=C wc -l < "$p"); t=$(tail -c 1 -- "$p" | LC_ALL=C wc -l)
            budget=$((budget - sz)); printf "%s\\t%s\\t%s\\n" "$((n + 1 - t))" "$sz" "$p"
            done
            """
        // The newlines stay: they are the statement separators, and they
        // survive quoting on the way to the remote shell.
        return "bash -c '" + script + "'"
    }

    /// Paths for ``untrackedLineCountsCommand(totalByteBudget:perFileByteCap:)``
    /// to read on standard input.
    static func untrackedLineCountsInput(paths: [String]) -> Data {
        var data = Data()
        for path in paths {
            data.append(contentsOf: Array(path.utf8))
            data.append(0)
        }
        return data
    }

    static func parseUntrackedLineCounts(
        _ output: String
    ) -> [(path: String, lines: Int, bytesRead: Int)] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                let lines = Int(fields[0]),
                let bytes = Int(fields[1]),
                !fields[2].isEmpty
            else { return nil }
            return (String(fields[2]), lines, bytes)
        }
    }

    /// Which in-progress operation a repository is in, in one round trip.
    ///
    /// Asking about each marker separately is six round trips for a question
    /// answered by six `test` calls, and it is asked on every snapshot.
    /// Prints the first marker that exists, in the caller's priority order.
    static func repositoryOperationCommand(gitDirectory: String) -> String {
        let quoted = quote(gitDirectory)
        return "for n in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD "
            + "REVERT_HEAD BISECT_LOG; do if [ -e \(quoted)\"/$n\" ]; then "
            + "printf '%s\\n' \"$n\"; break; fi; done; :"
    }

    /// Whether any directory at or above `path` holds a `.git`, in one round
    /// trip rather than one per ancestor. Prints `yes` or nothing.
    ///
    /// This is what tells a plain directory apart from a repository whose
    /// metadata is broken, so it runs every time the panel leaves a repository.
    static func gitMetadataAtOrAboveCommand(path: String) -> String {
        "d=\(quote(path)); while :; do if [ -e \"$d/.git\" ]; then printf 'yes\\n'; "
            + "break; fi; if [ \"$d\" = \"/\" ]; then break; fi; "
            + "d=$(dirname \"$d\"); done; :"
    }

    /// Runs several commands in one round trip, tagging each result so the
    /// Mac can tell them apart.
    ///
    /// A remote round trip costs about 60 ms before any work happens, so a
    /// snapshot built from a dozen sequential commands spends most of its time
    /// waiting. The tag is a fresh UUID per request, which cannot appear in
    /// any command's output, and the marker is preceded by a newline so it is
    /// always at the start of a line even when the output has no trailing one.
    static func batchCommand(_ commands: [(name: String, command: String)], tag: String) -> String {
        commands
            .map { "{ \($0.command) ; }; printf '\\n%s %s %d\\n' \(quote(tag)) \(quote($0.name)) \"$?\"" }
            .joined(separator: "; ")
    }

    struct BatchResult {
        let status: Int32
        let stdout: Data
    }

    /// Splits a batch's output back into one result per command. Works on
    /// bytes, because `git log -z` and `git status -z` embed NULs.
    static func parseBatch(_ output: Data, tag: String) -> [String: BatchResult] {
        let separator = Data(("\n" + tag + " ").utf8)
        var results: [String: BatchResult] = [:]
        var chunks: [Data] = []
        var rest = output
        while let found = rest.range(of: separator) {
            chunks.append(rest[rest.startIndex..<found.lowerBound])
            rest = rest[found.upperBound...]
        }
        chunks.append(rest)

        // Each chunk after the first opens with the previous command's marker
        // line, "<name> <status>", and the rest of it is the next output.
        var pendingOutput = chunks.first ?? Data()
        for chunk in chunks.dropFirst() {
            guard let newline = chunk.firstIndex(of: 0x0A) else { break }
            let marker = String(decoding: chunk[chunk.startIndex..<newline], as: UTF8.self)
            // The name may contain spaces (they are command lines), so the
            // status is the LAST field and the name is everything before it.
            let fields = marker.split(separator: " ")
            if fields.count >= 2, let status = Int32(fields[fields.count - 1]) {
                let name = fields.dropLast().joined(separator: " ")
                results[name] = BatchResult(status: status, stdout: pendingOutput)
            }
            pendingOutput = chunk[chunk.index(after: newline)...]
        }
        return results
    }

    // MARK: - Processes and ports

    /// `args` last, because it is the only column that contains spaces.
    /// It carries the command line rather than `comm`, so the panel can show
    /// the full path a process was started with; a process started by a bare
    /// name reports that bare name, which is all the remote knows.
    static func processListCommand() -> String {
        "ps -eo pid=,ppid=,pcpu=,rss=,args="
    }

    struct RemoteProcessRow: Equatable {
        let ppid: pid_t
        let process: WorkspaceProcess
    }

    static func parseProcessList(_ output: String) -> [RemoteProcessRow] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(
                separator: " ", maxSplits: 4, omittingEmptySubsequences: true
            )
            guard fields.count == 5,
                let pid = pid_t(fields[0]),
                let ppid = pid_t(fields[1]),
                let cpu = Double(fields[2]),
                let memoryKB = Int(fields[3])
            else { return nil }
            let commandLine = String(fields[4])
            let executable = commandLine.split(separator: " ").first.map(String.init) ?? commandLine
            return RemoteProcessRow(
                ppid: ppid,
                process: WorkspaceProcess(
                    pid: pid,
                    name: (executable as NSString).lastPathComponent,
                    executable: executable,
                    cpu: cpu,
                    memoryKB: memoryKB
                )
            )
        }
    }

    /// Breadth-first, so commands the user ran come before their workers —
    /// the order the panel already shows locally.
    static func snapshot(rows: [RemoteProcessRow], descendantsOf pid: pid_t)
        -> WorkspaceProcessSnapshot
    {
        var children: [pid_t: [WorkspaceProcess]] = [:]
        var namesByPid: [pid_t: String] = [:]
        for row in rows {
            children[row.ppid, default: []].append(row.process)
            namesByPid[row.process.pid] = row.process.name
        }

        var descendants: [WorkspaceProcess] = []
        var queue = children[pid] ?? []
        var seen: Set<pid_t> = [pid]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard seen.insert(next.pid).inserted else { continue }
            descendants.append(next)
            queue.append(contentsOf: children[next.pid] ?? [])
        }
        return WorkspaceProcessSnapshot(descendants: descendants, namesByPid: namesByPid)
    }

    /// `ss` is present on any current Linux; `lsof` is the fallback for hosts
    /// without iproute2. `-H` drops the header, `-n` keeps ports numeric.
    static func listeningPortsCommand() -> String {
        "ss -ltnpH 2>/dev/null || lsof -nP -iTCP -sTCP:LISTEN -Fpn 2>/dev/null"
    }

    /// Accepts either tool's output; they are told apart by shape.
    static func parseListeningPorts(_ output: String) -> [WorkspacePort] {
        let lines = output.split(separator: "\n")
        let isLsof = lines.first?.first.map { $0 == "p" || $0 == "n" } ?? false
        let ports = isLsof ? parseLsofPorts(lines) : parseSsPorts(lines)
        // One socket bound on both IPv4 and IPv6 is two rows for one port.
        var seen = Set<String>()
        return ports.filter { seen.insert("\($0.pid):\($0.port)").inserted }
    }

    /// `LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1234,fd=3))`
    private static func parseSsPorts(_ lines: [Substring]) -> [WorkspacePort] {
        var ports: [WorkspacePort] = []
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let port = trailingPort(fields[3]) else { continue }
            // A socket may be shared, so every pid= in the row counts.
            for pid in pidValues(in: line) {
                ports.append(WorkspacePort(port: port, pid: pid))
            }
        }
        return ports
    }

    /// `lsof -F` prints one field per line, `p` starting a process's block and
    /// `n` naming each of its sockets.
    private static func parseLsofPorts(_ lines: [Substring]) -> [WorkspacePort] {
        var ports: [WorkspacePort] = []
        var current: pid_t?
        for line in lines {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p": current = pid_t(value)
            case "n":
                if let pid = current, let port = trailingPort(value) {
                    ports.append(WorkspacePort(port: port, pid: pid))
                }
            default: break
            }
        }
        return ports
    }

    /// The port after the last colon, which is what both tools print and what
    /// keeps an IPv6 address such as `[::]:8000` from being misread.
    private static func trailingPort(_ value: Substring) -> Int? {
        guard let colon = value.lastIndex(of: ":") else { return nil }
        return Int(value[value.index(after: colon)...])
    }

    private static func pidValues(in line: Substring) -> [pid_t] {
        line.components(separatedBy: "pid=").dropFirst().compactMap { part in
            pid_t(part.prefix { $0.isNumber })
        }
    }
}
