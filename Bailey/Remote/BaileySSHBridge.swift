// Private handshake for the in-app SSH helper, not a general command API.

import Darwin
import Foundation

nonisolated struct BaileySSHRequest: Codable, Sendable {
    let token: String
    let terminalID: String
    let user: String
    let host: String
    let port: Int
    let pid: Int32
}

nonisolated struct BaileySSHResponse: Codable, Sendable {
    let socket: String?
}

enum BaileySSHWireError: Error {
    case message(String)
}

/// A private, one-shot SSH handoff socket. This is only for an interactive
/// `ssh` started inside a Bailey terminal; it cannot run commands or inspect panes.
nonisolated final class BaileySSHSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (
        BaileySSHRequest,
        @escaping @Sendable (BaileySSHResponse) -> Void
    ) -> Void

    private static let maximumMessageBytes = 4_096

    let path: String
    private let listener: Int32
    private let queue = DispatchQueue(label: "sh.bailey.ssh.socket")
    private let workers = DispatchQueue(
        label: "sh.bailey.ssh.clients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let handler: Handler
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping Handler) throws {
        self.path = path
        self.handler = handler

        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw BaileySSHWireError.message("socket: \(String(cString: strerror(errno)))")
        }
        self.listener = listener

        do {
            try Self.configureSocket(listener)
            var address = try Self.address(for: path)
            unlink(path)
            let result = withUnsafePointer(to: &address.value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, address.length)
                }
            }
            guard result == 0 else {
                throw BaileySSHWireError.message(
                    "bind: \(String(cString: strerror(errno)))"
                )
            }
            guard Darwin.chmod(path, 0o600) == 0 else {
                throw BaileySSHWireError.message(
                    "chmod: \(String(cString: strerror(errno)))"
                )
            }
            guard Darwin.listen(listener, 16) == 0 else {
                throw BaileySSHWireError.message(
                    "listen: \(String(cString: strerror(errno)))"
                )
            }
            let flags = fcntl(listener, F_GETFL, 0)
            guard flags >= 0, fcntl(listener, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw BaileySSHWireError.message(
                    "fcntl: \(String(cString: strerror(errno)))"
                )
            }
        } catch {
            Darwin.close(listener)
            unlink(path)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAvailableClients() }
        source.setCancelHandler { Darwin.close(listener) }
        self.source = source
        source.resume()
    }

    deinit {
        source?.cancel()
        unlink(path)
    }

    private func acceptAvailableClients() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    NSLog("bailey: ssh accept failed: %s", strerror(errno))
                }
                return
            }
            do {
                try Self.configureSocket(client)
                // Darwin can propagate O_NONBLOCK from the listening socket
                // to accepted descriptors. Client workers use a bounded,
                // blocking request read; leaving this set races the writer
                // and can close a healthy connection with EAGAIN.
                let flags = fcntl(client, F_GETFL, 0)
                guard flags >= 0,
                      fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0
                else {
                    throw BaileySSHWireError.message(
                        "fcntl: \(String(cString: strerror(errno)))"
                    )
                }
            } catch {
                Darwin.close(client)
                continue
            }
            workers.async { [weak self] in
                guard let self else {
                    Darwin.close(client)
                    return
                }
                self.readRequest(from: client)
            }
        }
    }

    private func readRequest(from client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)

        while data.count <= Self.maximumMessageBytes {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                if data.contains(0x0A) { break }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                respond(
                    BaileySSHResponse(socket: nil),
                    to: client
                )
                return
            }
        }

        guard data.count <= Self.maximumMessageBytes else {
            respond(
                BaileySSHResponse(socket: nil),
                to: client
            )
            return
        }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data[..<newline]
        }

        let request: BaileySSHRequest
        do {
            request = try JSONDecoder().decode(BaileySSHRequest.self, from: data)
        } catch {
            respond(
                BaileySSHResponse(socket: nil),
                to: client
            )
            return
        }

        handler(request) { [weak self] response in
            guard let self else {
                Darwin.close(client)
                return
            }
            self.workers.async { self.respond(response, to: client) }
        }
    }

    private func respond(_ response: BaileySSHResponse, to client: Int32) {
        defer { Darwin.close(client) }
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    client,
                    raw.baseAddress!.advanced(by: offset),
                    raw.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    static func exchange(
        path: String,
        request: BaileySSHRequest,
        timeout: TimeInterval = 5
    ) throws -> BaileySSHResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw BaileySSHWireError.message(
                "Could not create the SSH socket: \(String(cString: strerror(errno)))."
            )
        }
        defer { Darwin.close(descriptor) }
        try configureSocket(descriptor, timeout: timeout)

        var address = try Self.address(for: path)
        let connected = withUnsafePointer(to: &address.value) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, address.length)
            }
        }
        guard connected == 0 else {
            throw BaileySSHWireError.message(
                "Could not connect to Bailey SSH: \(String(cString: strerror(errno)))."
            )
        }

        var encoded = try JSONEncoder().encode(request)
        encoded.append(0x0A)
        try encoded.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    descriptor,
                    raw.baseAddress!.advanced(by: offset),
                    raw.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw BaileySSHWireError.message(
                        "Could not send the SSH request: \(String(cString: strerror(errno)))."
                    )
                }
            }
        }
        Darwin.shutdown(descriptor, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while responseData.count <= maximumMessageBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                responseData.append(buffer, count: count)
                if responseData.contains(0x0A) { break }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw BaileySSHWireError.message(
                    "Could not read Bailey's SSH response: \(String(cString: strerror(errno)))."
                )
            }
        }
        guard responseData.count <= maximumMessageBytes else {
            throw BaileySSHWireError.message("Bailey returned an oversized SSH response.")
        }
        if let newline = responseData.firstIndex(of: 0x0A) {
            responseData = responseData[..<newline]
        }
        guard !responseData.isEmpty else {
            throw BaileySSHWireError.message("Bailey closed the SSH connection without a response.")
        }
        return try JSONDecoder().decode(BaileySSHResponse.self, from: responseData)
    }

    private static func configureSocket(
        _ descriptor: Int32,
        timeout: TimeInterval = 2
    ) throws {
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE,
            &enabled, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw BaileySSHWireError.message(
                "setsockopt: \(String(cString: strerror(errno)))"
            )
        }

        let wholeSeconds = floor(timeout)
        var value = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((timeout - wholeSeconds) * 1_000_000)
        )
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO,
            &value, socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw BaileySSHWireError.message(
                "setsockopt: \(String(cString: strerror(errno)))"
            )
        }
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO,
            &value, socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw BaileySSHWireError.message(
                "setsockopt: \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func address(
        for path: String
    ) throws -> (value: sockaddr_un, length: socklen_t) {
        let bytes = Array(path.utf8CString)
        var value = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: value.sun_path)
        guard bytes.count <= capacity else {
            throw BaileySSHWireError.message(
                "SSH socket path is too long for macOS: \(path)"
            )
        }

        let length = MemoryLayout<sa_family_t>.size + bytes.count
        value.sun_len = UInt8(length)
        value.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &value.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in bytes.indices {
                    destination[index] = bytes[index]
                }
            }
        }
        return (value, socklen_t(length))
    }
}

@MainActor
final class BaileySSHService {
    static let shared = BaileySSHService()

    private var tokens: [String: UUID] = [:]
    private var listener: BaileySSHSocketServer?

    private init() {
        let path = "/tmp/bailey-ssh-\(getuid())-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        do {
            listener = try BaileySSHSocketServer(path: path) { request, reply in
                Task { @MainActor in
                    reply(BaileySSHService.shared.handle(request))
                }
            }
        } catch {
            NSLog("bailey: failed to start SSH handoff: \(error)")
        }
    }

    func terminalEnvironment(for id: UUID) -> [String: String] {
        guard let listener else { return [:] }
        let token = UUID().uuidString + UUID().uuidString
        tokens[token] = id
        return [
            "BAILEY_SSH_SOCKET": listener.path,
            "BAILEY_SSH_TOKEN": token,
            "BAILEY_SSH_SESSION": id.uuidString,
        ]
    }

    func revokeTerminal(id: UUID) {
        tokens = tokens.filter { $0.value != id }
    }

    private func handle(_ request: BaileySSHRequest) -> BaileySSHResponse {
        let refused = BaileySSHResponse(socket: nil)
        guard let id = UUID(uuidString: request.terminalID),
              tokens[request.token] == id,
              !request.host.isEmpty,
              request.port > 0, request.port <= 65_535,
              request.pid > 1
        else { return refused }

        let session = TerminalManager.activeManagers
            .flatMap(\.projects)
            .flatMap(\.sessions)
            .first { $0.id == id }
        guard let session else { return refused }

        do {
            let socket = try RemoteConnection.allocateControlSocket()
            let connection = RemoteConnection(
                user: request.user, host: request.host, port: request.port,
                controlSocket: socket, sshPID: pid_t(request.pid)
            )
            guard session.beginRemoteConnection(connection) else { return refused }
            return BaileySSHResponse(socket: socket.path)
        } catch {
            NSLog("bailey: could not allocate remote SSH socket: \(error)")
            return refused
        }
    }
}
