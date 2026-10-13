//
//  RemoteConnection.swift
//  kero
//

import Combine
import Darwin
import Foundation

/// Where a session's right pane looks for files, processes and git state.
///
/// A session is `.local` until Kero's own `ssh` helper reports that the user
/// typed an interactive `ssh` in that terminal. Nested or unmanaged `ssh`
/// invocations never produce a `.remote` location, so the pane can say the
/// remote tools are unavailable rather than showing local paths under a
/// remote heading.
enum WorkspaceLocation {
    case local
    case remote(RemoteConnection)

    var remoteConnection: RemoteConnection? {
        guard case .remote(let connection) = self else { return nil }
        return connection
    }
}

enum RemoteConnectionError: Error, LocalizedError {
    case notConnected
    case commandFailed(status: Int32, message: String)
    case socketPathTooLong(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "The remote connection is not available.", table: "Workspace")
        case .commandFailed(let status, let message):
            return message.isEmpty
                ? String(localized: "The remote command failed with status \(status).", table: "Workspace")
                : message
        case .socketPathTooLong(let path):
            return String(localized: "The control socket path is too long: \(path)", table: "Workspace")
        }
    }
}

/// One multiplexed ssh session, shared with the interactive `ssh` the user
/// typed. Kero never authenticates: the control socket is created by that
/// process, and every command here rides the existing channel.
@MainActor
final class RemoteConnection: ObservableObject, Identifiable, RemoteCommandRunner {
    nonisolated enum State: Hashable, Sendable {
        case connecting
        case connected
        case disconnected
    }

    nonisolated let id = UUID()
    nonisolated let user: String
    nonisolated let host: String
    nonisolated let port: Int
    /// Created and owned by the user's ssh process; Kero only names it.
    nonisolated let controlSocket: URL
    /// The interactive ssh itself. The helper `exec`s ssh over its own
    /// process, so the pid it reports stays valid for the session's life.
    nonisolated let sshPID: pid_t

    @Published private(set) var state: State = .connecting
    var workspaceBackend: SSHWorkspaceBackend { SSHWorkspaceBackend(runner: self) }
    /// The same channel with a short deadline, used only for the liveness
    /// probe. Panel work can afford to wait; a probe that waits is a drop
    /// this session has not noticed yet.
    var livenessBackend: SSHWorkspaceBackend {
        SSHWorkspaceBackend(runner: self, timeout: 3)
    }
    /// Remote working directory, filled in by the cwd probe.
    @Published var workingDirectory: String?
    /// The remote login shell's process id, found by the same probe. The Info
    /// panel needs it to describe the shell on the other machine rather than
    /// the local ssh client.
    @Published var shellProcessID: pid_t?

    /// Unix socket paths are capped at 104 bytes by `sockaddr_un`, which rules
    /// out Application Support. Same `/tmp` convention as the automation
    /// socket, one directory per app process at 0700.
    private static let maximumSocketPathBytes = 104

    nonisolated var destination: String {
        user.isEmpty ? host : "\(user)@\(host)"
    }

    nonisolated var displayName: String {
        destination
    }

    init(user: String, host: String, port: Int, controlSocket: URL, sshPID: pid_t) {
        self.user = user
        self.host = host
        self.port = port
        self.controlSocket = controlSocket
        self.sshPID = sshPID
        NSLog(
            "kero: remote connection %@ state connecting (socket %@, ssh pid %d)",
            destination, controlSocket.path, sshPID
        )
    }

    // MARK: - Control socket allocation

    /// Directory holding this app process's control sockets, created 0700.
    static func controlSocketDirectory() throws -> URL {
        let url = URL(
            fileURLWithPath:
                "/tmp/kero-\(getuid())-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    /// A fresh control socket path, short enough for `sockaddr_un`.
    static func allocateControlSocket() throws -> URL {
        let directory = try controlSocketDirectory()
        let nonce = UUID().uuidString.prefix(8).lowercased()
        let url = directory.appendingPathComponent("ssh-\(nonce).sock")
        guard url.path.utf8.count <= maximumSocketPathBytes else {
            throw RemoteConnectionError.socketPathTooLong(url.path)
        }
        return url
    }

    // MARK: - State

    func markConnected() {
        guard state != .connected else { return }
        state = .connected
        NSLog("kero: remote connection %@ state connected", destination)
    }

    func markDisconnected(reason: String) {
        guard state != .disconnected else { return }
        state = .disconnected
        NSLog(
            "kero: remote connection %@ state disconnected (%@)",
            destination, reason
        )
    }

    /// True while the interactive ssh process still exists. `kill(pid, 0)`
    /// reports `EPERM` for a live process we do not own, which still means
    /// alive; only `ESRCH` means gone.
    nonisolated var isSSHProcessAlive: Bool {
        guard sshPID > 1 else { return false }
        if Darwin.kill(sshPID, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// The master removes its socket when the session ends, so a missing
    /// file is a disconnect Kero can see without running ssh at all.
    nonisolated var controlSocketExists: Bool {
        FileManager.default.fileExists(atPath: controlSocket.path)
    }

    // MARK: - Multiplex commands

    /// `ssh -S <socket> -O check <destination>`: does the master still answer?
    nonisolated func check() async -> Bool {
        let result = await Self.runSSH(
            arguments: controlArguments + ["-O", "check", destination],
            stdin: nil,
            timeout: 5
        )
        return result.status == 0
    }

    /// Runs one command on the remote over the shared channel.
    ///
    /// `argv` is handed to ssh as the remote command words, which ssh joins
    /// with spaces for the remote login shell to interpret. Callers that have
    /// already built a shell command pass it as a single element.
    ///
    /// A missing master fails the liveness check immediately. The channel
    /// options also forbid a new transport, so a master exiting after that
    /// check cannot make ssh authenticate behind the user's back.
    nonisolated func run(
        _ argv: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = 20
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        // Deliberately not gated on `.connected`: the liveness probe has to
        // keep running while the connection is disconnected, or nothing could
        // ever notice it coming back.
        //
        // `-O check` only asks the LOCAL multiplexing master, which answers
        // happily with the network down, so it proves the socket is ours and
        // nothing more. It is kept as the cheap fast-fail; the channel options
        // below prevent a new transport even if the master exits next.
        guard controlSocketExists, await check() else {
            await MainActor.run {
                markDisconnected(reason: "control socket is gone")
            }
            throw RemoteConnectionError.notConnected
        }
        return await Self.runSSH(
            arguments: controlArguments + ["-o", "BatchMode=yes", destination, "--"] + argv,
            stdin: stdin,
            timeout: timeout
        )
    }


    /// Options naming the shared channel. `-S` is ssh's own "use this control
    /// socket" switch and overrides any ControlPath from a config file.
    nonisolated private var controlArguments: [String] {
        [
            "-S", controlSocket.path, "-p", String(port),
            "-o", "ControlMaster=no", "-o", "ProxyCommand=/usr/bin/false",
        ]
    }


    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Process

    /// Runs `/usr/bin/ssh` off the main actor. Kero always uses the system
    /// client here, never the bundle's helper symlink, which would recurse.
    nonisolated static func runSSH(
        arguments: [String],
        stdin: Data?,
        timeout: TimeInterval
    ) async -> (status: Int32, stdout: Data, stderr: Data) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: ProcessRemoteCommandRunner.run(
                        sshPath: "/usr/bin/ssh", arguments: arguments,
                        stdin: stdin, timeout: timeout
                    )
                )
            }
        }
    }

}

extension RemoteConnection {
    /// Names the machine a file or diff belongs to. The port appears only when
    /// it is not the default, so the common case reads as `user@host`.
    var workspaceIdentity: String {
        port == 22 ? destination : "\(destination):\(port)"
    }
}
