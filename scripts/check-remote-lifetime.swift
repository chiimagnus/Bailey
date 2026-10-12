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

    static func waitForRequest(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
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

    @MainActor
    static func checkConcurrentForward(disconnect: Bool) async throws {
        let directory = URL(fileURLWithPath: "/tmp/kero-forward-" + UUID().uuidString.prefix(8))
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
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(master, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0 && listen(master, 2) == 0)
        let requested = DispatchSemaphore(value: 0)
        let respond = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        Thread {
            let client = accept(master, nil, nil)
            precondition(client >= 0)
            let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
            do {
                let hello = try readPacket(handle)
                precondition(hello == [1, 4])
                try handle.write(contentsOf: words([8, 1, 4]))
                let request = [UInt8](try readPacketData(handle))
                precondition(request.count >= 12)
                let type = request[0..<4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let requestID = request[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                precondition(type == 0x10000006)
                requested.signal()
                precondition(respond.wait(timeout: .now() + 5) == .success)
                try handle.write(contentsOf: words([8, 0x80000001, requestID]))
                try handle.close()
                completed.signal()
            } catch { preconditionFailure("Controlled forward mux failed: \(error)") }
        }.start()
        let connection = RemoteConnection(user: "fixture", host: "invalid", port: 22,
            controlSocket: URL(fileURLWithPath: path), sshPID: 0)
        connection.markConnected()
        let controller = connection.portForwards
        let remotePort = try RemoteConnection.freeLocalPort()
        let first = Task { try await controller.forward(remotePort: remotePort) }
        let requestArrived = await Task.detached {
            waitForRequest(requested)
        }.value
        precondition(requestArrived)
        var repeated: Task<Int, Error>?
        await withCheckedContinuation { continuation in
            repeated = Task {
                continuation.resume()
                return try await controller.forward(remotePort: remotePort)
            }
        }
        if disconnect { connection.markDisconnected(reason: "controlled pending forward") }
        respond.signal()
        let results = await (first.result, repeated!.result)
        if disconnect {
            for result in [results.0, results.1] {
                guard case .failure(RemoteConnectionError.notConnected) = result else {
                    preconditionFailure("Every pending waiter must reject a disconnected forward: \(result)")
                }
            }
            precondition(controller.localPortsByRemote.isEmpty)
        } else {
            let firstPort = try results.0.get()
            let repeatedPort = try results.1.get()
            precondition(firstPort == remotePort && repeatedPort == remotePort)
            precondition(controller.localPortsByRemote[remotePort] == remotePort)
            let cachedPort = try await controller.forward(remotePort: remotePort)
            precondition(cachedPort == remotePort)
        }
        precondition(completed.wait(timeout: .now() + 1) == .success)
        var incoming = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        precondition(poll(&incoming, 1, 100) == 0, "Concurrent forwarding must share one mux request")
        print("PASS: concurrent forward waiters share one request and \(disconnect ? "all reject disconnect" : "reuse the published port")")
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
        weak let releasedConnection = connection
        weak let releasedController = connection!.portForwards
        var controller: PortForwardController? = connection!.portForwards
        precondition(controller === connection!.portForwards)
        var backend: SSHWorkspaceBackend? = connection!.workspaceBackend
        var liveness: SSHWorkspaceBackend? = connection!.livenessBackend
        connection = nil
        precondition(releasedConnection != nil)
        backend = nil
        precondition(releasedConnection != nil)
        liveness = nil
        precondition(releasedConnection == nil)
        do {
            _ = try await controller!.forward(remotePort: 8000)
            fatalError("Released connection must not forward")
        } catch RemoteConnectionError.notConnected {}
        controller = nil
        precondition(releasedController == nil)
        var second: RemoteConnection? = RemoteConnection(
            user: "fixture", host: "invalid", port: 22,
            controlSocket: URL(fileURLWithPath: "/tmp/kero-no-such-control-socket"), sshPID: 0
        )
        weak let secondConnection = second
        weak let secondController = second!.portForwards
        second!.markConnected()
        second!.markDisconnected(reason: "lifetime check without network")
        precondition(second!.portForwards.localPortsByRemote.isEmpty)
        second = nil
        precondition(secondConnection == nil && secondController == nil)
        withExtendedLifetime(backend) {}
        withExtendedLifetime(liveness) {}
        print("PASS: connection-owned controller, request-owned backends, weak release and unavailable forwarding")
        try await checkMasterExitRace()
        try await checkConcurrentForward(disconnect: false)
        try await checkConcurrentForward(disconnect: true)
        let arguments = CommandLine.arguments
        if arguments.count == 4, let remotePort = Int(arguments[3]) {
            let live = RemoteConnection(
                user: "", host: arguments[2], port: 22,
                controlSocket: URL(fileURLWithPath: arguments[1]), sshPID: 0
            )
            live.markConnected()
            async let first = live.portForwards.forward(remotePort: remotePort)
            async let repeated = live.portForwards.forward(remotePort: remotePort)
            let (firstPort, repeatedPort) = try await (first, repeated)
            precondition(firstPort == repeatedPort)
            precondition(live.portForwards.localPortsByRemote[remotePort] == firstPort)
            let url = URL(string: "http://127.0.0.1:\(firstPort)/kero-lifetime-fixture-does-not-exist")!
            let (_, response) = try await URLSession.shared.data(from: url)
            precondition((response as? HTTPURLResponse)?.statusCode == 404)
            live.markDisconnected(reason: "records check; master still alive")
            precondition(live.portForwards.localPortsByRemote.isEmpty)
            print("PASS: concurrent forwarding reused actual loopback port \(firstPort), HTTP fixture reached; disconnect cleared records only")
        }
    }
}
