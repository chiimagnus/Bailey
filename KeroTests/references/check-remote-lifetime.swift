import Darwin
import Foundation


@main
enum RemoteLifetimeCheck {
    static func words(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { data, value in
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
        }
    }

    static func readPacketData(_ handle: FileHandle) throws -> Data {
        func readExactly(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                data.append(chunk)
            }
            return data
        }
        let header = try readExactly(4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        precondition(length <= 1024)
        return try readExactly(Int(length))
    }

    static func readPacket(_ handle: FileHandle) throws -> [UInt32] {
        let body = [UInt8](try readPacketData(handle))
        precondition(body.count.isMultiple(of: 4))
        return stride(from: 0, to: body.count, by: 4).map { index in
            body[index..<index + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
    }

    static func checkIndependentCommandDeadline() throws {
        let normal = try ProcessRemoteCommandRunner.launch(sshPath: "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; cat"],
            stdin: Data("input".utf8), timeout: 2)
        precondition(normal.status == 0 && normal.stdout == Data("outinput".utf8)
            && normal.stderr == Data("err".utf8))
        let failure = try ProcessRemoteCommandRunner.launch(sshPath: "/bin/sh",
            arguments: ["-c", "exit 7"], stdin: nil, timeout: 2)
        precondition(failure.status == 7)
        let started = Date()
        do {
            _ = try ProcessRemoteCommandRunner.launch(sshPath: "/bin/sh",
                arguments: ["-c", "(sleep 0.5) & printf retained"], stdin: nil, timeout: 0.05)
            preconditionFailure("Client exit must not cancel the pipe deadline")
        } catch WorkspaceError.timedOut {}
        precondition(Date().timeIntervalSince(started) < 0.4)
        print("PASS: independent SSH command helper preserves input/streams/status and bounds pipes after client exit")
    }

    @MainActor
    static func checkMasterExitRace() async throws {
        let directory = URL(fileURLWithPath: "/tmp/kero-mux-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control").path
        let master = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(master >= 0)
        defer { close(master) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8) + [0]
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(master, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0 && listen(master, 1) == 0)
        let transport = socket(AF_INET, SOCK_STREAM, 0)
        precondition(transport >= 0)
        defer { close(transport) }
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_addr.s_addr = inet_addr("127.0.0.1")
        var targetLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(transport, $0, targetLength) == 0 && listen(transport, 1) == 0
                    && getsockname(transport, $0, &targetLength) == 0
            }
        }
        precondition(listening)
        let completed = DispatchSemaphore(value: 0)
        Thread {
            let client = accept(master, nil, nil)
            precondition(client >= 0)
            let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
            do {
                let hello = try readPacket(handle)
                precondition(hello == [1, 4])
                try handle.write(contentsOf: words([8, 1, 4]))
                let request = try readPacket(handle)
                precondition(request.count == 2 && request[0] == 0x10000004)
                precondition(unlink(path) == 0)
                try handle.write(contentsOf: words([12, 0x80000005, request[1], UInt32(getpid())]))
                try handle.close()
                completed.signal()
            } catch { preconditionFailure("Controlled mux failed: \(error)") }
        }.start()
        let connection = RemoteConnection(user: "fixture", host: "127.0.0.1",
            port: Int(UInt16(bigEndian: target.sin_port)), controlSocket: URL(fileURLWithPath: path), sshPID: 0)
        connection.markConnected()
        let result = try await connection.run(["true"], timeout: 0.5)
        precondition(completed.wait(timeout: .now() + 1) == .success)
        precondition(result.status != 0 && !FileManager.default.fileExists(atPath: path))
        var incoming = pollfd(fd: transport, events: Int16(POLLIN), revents: 0)
        let connected = poll(&incoming, 1, 200) > 0
        precondition(!connected, "SSH opened a fresh TCP transport after the successful master check")
        print("PASS: real OpenSSH mux check succeeds then socket disappears; no fresh TCP/auth transport is opened")
    }

    @MainActor
    static func main() async throws {
        try await Task.detached { try checkIndependentCommandDeadline() }.value
        var connection: RemoteConnection? = RemoteConnection(
            user: "fixture", host: "invalid", port: 22,
            controlSocket: URL(fileURLWithPath: "/tmp/kero-no-such-control-socket"), sshPID: 0
        )
        weak let released = connection
        var backend: SSHWorkspaceBackend? = connection!.workspaceBackend
        var liveness: SSHWorkspaceBackend? = connection!.livenessBackend
        connection = nil
        precondition(released != nil)
        backend = nil
        precondition(released != nil)
        liveness = nil
        precondition(released == nil)
        withExtendedLifetime(backend) {}
        withExtendedLifetime(liveness) {}
        print("PASS: SSH backend references own the connection until release")
        try await checkMasterExitRace()
    }
}
