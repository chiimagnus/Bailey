import Darwin
import Foundation

/// The `ssh` the user actually types inside a Bailey terminal.
///
/// A symlink named `ssh` beside the app executable points at its binary;
/// Bailey's interactive zsh integration invokes it for ordinary SSH sessions. When the binary is
/// invoked under that name it either tells Bailey a session is going remote and
/// hands control to the real ssh with a shared control socket, or — far more
/// often — gets out of the way entirely.
///
/// Every uncertain case passes through untouched. An unrecognized invocation
/// must retain its original SSH behavior.
nonisolated enum BaileySSHPassthrough {
    /// Options OpenSSH accepts with no value.
    private static let flagOptions = Set("46AaCfGgKkMNnqsTtVvXxYy")
    /// Options OpenSSH accepts with a value, attached or as the next argument.
    private static let valueOptions = Set("BbcDEeFIiJLlmOoPpRSWw")
    /// Options that mean this invocation is not an interactive session Bailey
    /// can follow: config dumps, version and query output, control-socket
    /// commands, forwarding-only and no-shell modes, and subsystems.
    private static let disqualifyingFlags = Set("GQVONWTs")
    /// Options that take over the control socket itself. `-S` and `-M` are
    /// handled by ssh's own argument parser and would override anything Bailey
    /// passes, so a session using them is left alone.
    private static let disqualifyingValueOptions = Set("SM")

    /// True when the binary was invoked through the `ssh` symlink.
    static var isInvokedAsSSH: Bool {
        guard let first = CommandLine.arguments.first else { return false }
        return (first as NSString).lastPathComponent == "ssh"
    }

    static func main() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let realSSH = locateSystemSSH()

        guard let plan = interceptionPlan(arguments: arguments, realSSH: realSSH) else {
            execute(realSSH, [realSSH] + arguments)
        }

        // A failed hand-off must never cost the user their connection: fall
        // back to an ordinary ssh with none of Bailey's options.
        guard let socket = announceConnecting(plan) else {
            execute(realSSH, [realSSH] + arguments)
        }

        setenv("LC_BAILEY_TERMINAL", plan.terminalID, 1)
        let baileyOptions = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(socket)",
            "-o", "ControlPersist=no",
            "-o", "SendEnv=LC_BAILEY_TERMINAL",
        ]
        // Bailey's options go first because OpenSSH keeps the first value it
        // obtains for a parameter. The decision to intercept already
        // established that the user set none of these themselves.
        execute(realSSH, [realSSH] + baileyOptions + arguments)
    }

    // MARK: - Locating the real client

    /// First `ssh` on `PATH` that is not this bundle's own symlink. The
    /// candidate must still resolve to something named `ssh`, which rules out
    /// a second Bailey installation whose symlink resolves to `bailey`.
    static func locateSystemSSH() -> String {
        let ownDirectory = (Bundle.main.executableURL?.deletingLastPathComponent().path)
            .flatMap(resolved)
            ?? resolved((CommandLine.arguments.first ?? "") as NSString)
                .flatMap { ($0 as NSString).deletingLastPathComponent }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(directory)/ssh"
            guard access(candidate, X_OK) == 0, let target = resolved(candidate) else { continue }
            guard (target as NSString).lastPathComponent == "ssh" else { continue }
            if let ownDirectory,
               resolved((candidate as NSString).deletingLastPathComponent) == ownDirectory {
                continue
            }
            return candidate
        }
        return "/usr/bin/ssh"
    }

    private static func resolved(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func resolved(_ path: NSString) -> String? {
        resolved(path as String)
    }

    // MARK: - Interception decision

    struct Plan {
        let user: String
        let host: String
        let port: Int
        let socketPath: String
        let token: String
        let terminalID: String
    }

    /// Everything that must hold before Bailey touches an ssh invocation.
    static func interceptionPlan(arguments: [String], realSSH: String) -> Plan? {
        let environment = ProcessInfo.processInfo.environment
        guard let socketPath = environment["BAILEY_SSH_SOCKET"], !socketPath.isEmpty,
              let token = environment["BAILEY_SSH_TOKEN"], !token.isEmpty,
              let terminalID = environment["BAILEY_SSH_SESSION"], !terminalID.isEmpty
        else { return nil }

        // Only a session a person is sitting in front of. A pipeline, an agent
        // running `ssh host cmd`, rsync and scp all fail this.
        guard isatty(0) == 1, isatty(1) == 1 else { return nil }

        guard case .interactiveSession = classify(arguments) else { return nil }

        guard let configuration = resolvedConfiguration(arguments: arguments, realSSH: realSSH),
              let host = configuration["hostname"], !host.isEmpty
        else { return nil }

        // A user who already multiplexes this host keeps their own socket.
        // Bailey would otherwise silently override it, because its prepended
        // options win over both the command line and ~/.ssh/config.
        let controlMaster = configuration["controlmaster"] ?? "false"
        let controlPath = configuration["controlpath"] ?? "none"
        guard controlMaster == "false" || controlMaster == "no" else { return nil }
        guard controlPath == "none" else { return nil }

        return Plan(
            user: configuration["user"] ?? "",
            host: host,
            port: Int(configuration["port"] ?? "22") ?? 22,
            socketPath: socketPath,
            token: token,
            terminalID: terminalID
        )
    }

    enum Classification: Equatable {
        /// A destination and nothing after it.
        case interactiveSession
        /// Anything Bailey declines to reason about.
        case notFollowable
    }

    /// Walks argv the way OpenSSH's own `getopt` string does, looking for a
    /// destination with no command after it.
    ///
    /// OpenSSH also accepts options *after* the destination (`ssh host -p 22`).
    /// Bailey deliberately does not: treating any trailing argument as a remote
    /// command keeps the parser small and errs towards passing through.
    static func classify(_ arguments: [String]) -> Classification {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]

            if argument == "-" { return .notFollowable }
            if argument == "--" {
                let destination = arguments.index(after: index)
                return destination == arguments.index(before: arguments.endIndex)
                    && !arguments[destination].isEmpty && arguments[destination] != "-"
                    ? .interactiveSession : .notFollowable
            }

            guard argument.hasPrefix("-") else {
                // The destination. Anything after it is a remote command.
                return index == arguments.index(before: arguments.endIndex)
                    ? .interactiveSession
                    : .notFollowable
            }

            let characters = Array(argument.dropFirst())
            var cursor = 0
            while cursor < characters.count {
                let flag = characters[cursor]
                if disqualifyingFlags.contains(flag) { return .notFollowable }
                // Checked before the flag branch: `-M` takes no value and so
                // also appears in the flag set, but it still means the user is
                // running their own multiplexing master.
                if disqualifyingValueOptions.contains(flag) { return .notFollowable }
                if flagOptions.contains(flag) {
                    cursor += 1
                    continue
                }
                if valueOptions.contains(flag) {
                    let attached = String(characters[(cursor + 1)...])
                    if attached.isEmpty {
                        // The value is the next argument, so skip it.
                        index = arguments.index(after: index)
                        guard index < arguments.endIndex else { return .notFollowable }
                    }
                    cursor = characters.count
                    continue
                }
                // An option this parser does not know. Never guess.
                return .notFollowable
            }
            index = arguments.index(after: index)
        }
        // Options only, no destination.
        return .notFollowable
    }

    /// `ssh -G` resolves the effective configuration without connecting.
    /// Returns the lowercased keyword to first-value map, or nil if ssh
    /// refused the arguments.
    static func resolvedConfiguration(
        arguments: [String],
        realSSH: String
    ) -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: realSSH)
        process.arguments = ["-G"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        var configuration: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let key = fields[0].lowercased()
            // ssh -G repeats multi-valued keywords; keep the first, which is
            // the value it would actually use.
            if configuration[key] == nil {
                configuration[key] = String(fields[1])
            }
        }
        return configuration
    }

    // MARK: - Telling Bailey

    /// Announces the pending connection and returns the control socket path
    /// Bailey allocated for it, or nil if Bailey did not answer.
    private static func announceConnecting(_ plan: Plan) -> String? {
        let request = BaileySSHRequest(
            token: plan.token, terminalID: plan.terminalID,
            user: plan.user, host: plan.host, port: plan.port,
            // The helper execs ssh in place, keeping this pid for the session.
            pid: getpid()
        )
        guard let socket = try? BaileySSHSocketServer.exchange(
            path: plan.socketPath, request: request, timeout: 1
        ).socket, !socket.isEmpty else { return nil }
        return socket
    }

    // MARK: - Handing over

    private static func execute(_ path: String, _ arguments: [String]) -> Never {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        execv(path, &argv)
        fputs("bailey: could not run \(path): \(String(cString: strerror(errno)))\n", stderr)
        exit(127)
    }
}
