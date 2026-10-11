
import CryptoKit
import Darwin
import Foundation

/// Executes independent workspace commands through the user's OpenSSH configuration.
/// A multiplexed master avoids a full handshake for every directory in the tree.
/// It is separate from the interactive terminal's SSH lifecycle.
nonisolated struct SSHHostCommandRunner: RemoteCommandRunner {
    let host: String
    let socket: String

    func run(
        _ argv: [String], stdin: Data?, timeout: TimeInterval
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        let arguments = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=180",
            "-o", "ControlPath=\(socket)",
            "-T", "--", host,
        ] + argv
        do {
            let result = try await Task.detached(priority: .utility) {
                try ProcessRemoteCommandRunner.launch(
                    sshPath: "/usr/bin/ssh", arguments: arguments,
                    stdin: stdin, timeout: timeout
                )
            }.value
            await MainActor.run {
                SSHHostWorkspaces.setConnected(result.status != 255, for: host)
            }
            return result
        } catch {
            await MainActor.run { SSHHostWorkspaces.setConnected(false, for: host) }
            throw error
        }
    }
}

/// Cached per SSH host, not per terminal; a folder stays reachable when the
/// user changes terminal tabs, and separate hosts cannot share the same path.
@MainActor
enum SSHHostWorkspaces {
    private static var workspaces: [String: SSHWorkspaceBackend] = [:]
    private static var connected: [String: Bool] = [:]

    static func connectionState(for host: String) -> Bool? { connected[host] }

    static func setConnected(_ value: Bool, for host: String) {
        connected[host] = value
    }

    static func backend(for host: String) -> SSHWorkspaceBackend {
        if let existing = workspaces[host] { return existing }
        let digest = SHA256.hash(data: Data(host.utf8))
            .prefix(7).map { String(format: "%02x", $0) }.joined()
        let socket = "/tmp/kero-\(getuid())-\(getpid())-\(digest).sock"
        let workspace = SSHWorkspaceBackend(
            runner: SSHHostCommandRunner(host: host, socket: socket),
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
