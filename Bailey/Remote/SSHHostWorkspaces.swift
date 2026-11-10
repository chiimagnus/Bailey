
import Darwin
import Foundation

/// %C hashes the effective SSH host, user, port and jump path instead of an
/// alias; both terminals and workspace commands share only compatible targets.
nonisolated enum SSHMultiplexing {
    static let options = [
        "-o", "ControlMaster=auto",
        "-o", "ControlPersist=180",
        "-o", "ControlPath=/tmp/bailey-\(getuid())-\(getpid())-%C.sock",
    ]
}

/// Executes independent workspace commands through the user's OpenSSH configuration.
/// A multiplexed master avoids a full handshake for every directory and terminal.
/// OpenSSH persists the master independently of any single terminal tab.
nonisolated struct SSHHostCommandRunner: RemoteCommandRunner {
    let host: String
    private let multiplexOptions: [String]
    private let reportsConnectionState: Bool

    init(host: String, socket: String? = nil) {
        self.host = host
        reportsConnectionState = socket == nil
        // Real SSH tests keep their own disposable master, never the user's.
        multiplexOptions = socket.map {
            ["-o", "ControlMaster=auto", "-o", "ControlPersist=180", "-o", "ControlPath=\($0)"]
        } ?? SSHMultiplexing.options
    }

    func run(
        _ argv: [String], stdin: Data?, timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        try await execute(argv, stdin: stdin, timeout: timeout, limits: nil)
    }

    func runLimited(
        _ argv: [String], stdin: Data?, timeout: TimeInterval,
        stdoutLimit: Int, stderrLimit: Int
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        try await execute(argv, stdin: stdin, timeout: timeout,
                          limits: (stdout: stdoutLimit, stderr: stderrLimit))
    }

    private func execute(
        _ argv: [String], stdin: Data?, timeout: TimeInterval,
        limits: (stdout: Int, stderr: Int)?
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        let arguments = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "Compression=yes",
        ] + multiplexOptions + ["-T", "--", host] + argv
        let command = Task.detached(priority: .utility) {
            try ProcessRemoteCommandRunner.launch(
                sshPath: "/usr/bin/ssh", arguments: arguments,
                stdin: stdin, timeout: timeout,
                stdoutLimit: limits?.stdout, stderrLimit: limits?.stderr
            )
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await command.value
            } onCancel: {
                command.cancel()
            }
            if reportsConnectionState {
                await MainActor.run {
                    SSHHostWorkspaces.setConnected(result.status != 255, for: host)
                }
            }
            return result
        } catch WorkspaceError.tooLarge {
            throw WorkspaceError.tooLarge
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if reportsConnectionState {
                await MainActor.run { SSHHostWorkspaces.setConnected(false, for: host) }
            }
            throw error
        }
    }
}


/// Only explicit OpenSSH aliases can appear in the picker. OpenSSH still owns
/// authentication, HostName, ProxyJump and the effective configuration.
@MainActor
enum SSHHostConfiguration {
    static func aliases(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    ) -> [String] {
        let configDirectory = configURL.deletingLastPathComponent()
        var names: [String] = []
        var seen = Set<String>()
        var visited = Set<URL>()

        func includedFiles(_ pattern: String) -> [URL] {
            let expanded: String
            if pattern.hasPrefix("~/") {
                expanded = FileManager.default.homeDirectoryForCurrentUser.path
                    + String(pattern.dropFirst(1))
            } else if pattern.hasPrefix("/") {
                expanded = pattern
            } else {
                expanded = configDirectory.appendingPathComponent(pattern).path
            }
            var matches = glob_t()
            defer { globfree(&matches) }
            guard glob(expanded, 0, nil, &matches) == 0 else { return [] }
            return (0..<Int(matches.gl_pathc)).compactMap { index in
                guard let path = matches.gl_pathv[index] else { return nil }
                return URL(fileURLWithPath: String(cString: path))
            }
        }

        func read(_ file: URL) {
            guard visited.insert(file.standardizedFileURL.resolvingSymlinksInPath()).inserted,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let words = line.split(whereSeparator: \.isWhitespace)
                    .prefix { !$0.hasPrefix("#") }
                guard let directive = words.first?.lowercased() else { continue }
                switch directive {
                case "include":
                    for pattern in words.dropFirst() {
                        for included in includedFiles(String(pattern)) {
                            read(included)
                        }
                    }
                case "host":
                    for value in words.dropFirst() {
                        let alias = String(value)
                        guard !alias.contains(where: { "*?!".contains($0) }),
                              SSHHostWorkspaces.validHost(alias),
                              seen.insert(alias.lowercased()).inserted else { continue }
                        names.append(alias)
                    }
                default:
                    break
                }
            }
        }

        read(configURL)
        return names
    }
}

/// Cached per SSH host, not per terminal; a folder stays reachable when the
/// user changes terminal tabs, and separate hosts cannot share the same path.
@MainActor
enum SSHHostWorkspaces {
    static let connectionChanged = Notification.Name("Bailey.SSHHostConnectionChanged")
    private static var workspaces: [String: SSHWorkspaceBackend] = [:]
    private static var connected: [String: Bool] = [:]
    private static var connectionRevisions: [String: UInt64] = [:]

    static func connectionState(for host: String) -> Bool? { connected[host] }
    static func connectionRevision(for host: String) -> UInt64 { connectionRevisions[host] ?? 0 }

    static func setConnected(_ value: Bool, for host: String) {
        guard connected[host] != value else { return }
        connected[host] = value
        connectionRevisions[host, default: 0] &+= 1
        NotificationCenter.default.post(name: connectionChanged, object: host)
    }

    static func retryConnection(for identity: String, path: String) {
        guard identity.hasPrefix("ssh:") else { return }
        let host = String(identity.dropFirst(4))
        guard connected[host] == false else { return }
        let workspace = backend(for: host)
        Task { _ = try? await workspace.stat(path: path) }
    }

    static func backend(for host: String) -> SSHWorkspaceBackend {
        if let existing = workspaces[host] { return existing }
        let workspace = SSHWorkspaceBackend(
            runner: SSHHostCommandRunner(host: host),
            timeout: 25
        )
        workspaces[host] = workspace
        return workspace
    }

    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-")
            && !host.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    /// A Windows OpenSSH host running MSYS2 zsh accepts POSIX /d/... paths.
    /// Keep every path slash-separated so existing file and Git views work.
    static func normalizedPath(_ input: String) -> String {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 3 {
            let chars = Array(path)
            if chars[1] == ":", chars[2] == "\\" || chars[2] == "/" {
                let drive = String(chars[0]).lowercased()
                return "/" + drive + "/" + String(chars.dropFirst(3))
                    .replacingOccurrences(of: "\\", with: "/")
            }
        }
        return path.replacingOccurrences(of: "\\", with: "/")
    }
}
