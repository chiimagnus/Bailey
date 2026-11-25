import Foundation
import XCTest
@testable import Bailey

/// Drops the response only after the real remote command has succeeded.
actor PublicationAcknowledgementRunner: RemoteCommandRunner {
    let base: SSHHostCommandRunner
    private var dropNextPublication: (@Sendable () async -> Void)?

    init(host: String, socket: String) { base = SSHHostCommandRunner(host: host, socket: socket) }

    func loseNextAcknowledgement(afterPublish: @escaping @Sendable () async -> Void = {}) {
        dropNextPublication = afterPublish
    }

    func run(_ argv: [String], stdin: Data?, timeout: TimeInterval) async throws
        -> (status: Int32, stdout: Data, stderr: Data) {
        let result = try await base.run(argv, stdin: stdin, timeout: timeout)
        if let afterPublish = dropNextPublication, stdin != nil, result.status == 0,
           argv.first?.contains(#"cat > "$stage/item""#) == true {
            dropNextPublication = nil
            await afterPublish()
            return (255, Data(), Data("SSH publication acknowledgement lost".utf8))
        }
        return result
    }

    func runLimited(_ argv: [String], stdin: Data?, timeout: TimeInterval,
                    stdoutLimit: Int, stderrLimit: Int) async throws
        -> (status: Int32, stdout: Data, stderr: Data) {
        try await base.runLimited(argv, stdin: stdin, timeout: timeout,
                                  stdoutLimit: stdoutLimit, stderrLimit: stderrLimit)
    }
}

/// A locally named, exclusively owned remote fixture also permits cleanup when
/// directory creation succeeded but its acknowledgement was lost.
@MainActor
func withPublicationSSHFixture(host: String, backend: SSHWorkspaceBackend, sockets: [String],
                               prefix: String, body: (String) async throws -> Void) async throws {
    let root = "/tmp/\(prefix)-\(UUID().uuidString.lowercased())"
    print("PUBLICATION_SSH_FIXTURE \(root)")
    var created = false
    var uncertain = false
    func cleanup() async {
        do {
            if created {
                try await backend.delete(paths: [root])
            } else if uncertain {
                let result = try await backend.run(
                    argv: ["sh", "-c", "if [ -e \"$1\" ] || [ -L \"$1\" ]; then rmdir -- \"$1\"; fi",
                           "cleanup", root], cwd: nil, env: nil, stdin: nil, timeout: 25)
                XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
            }
        } catch { XCTFail("Could not clean up the publication fixture \(root): \(error)") }
        for socket in sockets where FileManager.default.fileExists(atPath: socket) {
            let result = await Task.detached {
                ProcessRemoteCommandRunner.run(sshPath: "/usr/bin/ssh",
                    arguments: ["-S", socket, "-O", "exit", host], stdin: nil, timeout: 10)
            }.value
            XCTAssertEqual(result.status, 0, "Could not close the test-owned SSH connection")
        }
    }
    do {
        uncertain = true
        let result = try await backend.run(argv: ["mkdir", "--", root], cwd: nil,
                                           env: nil, stdin: nil, timeout: 25)
        uncertain = result.status == 255
        guard result.status == 0 else {
            XCTFail("Could not create the publication fixture: \(String(decoding: result.stderr, as: UTF8.self))")
            throw WorkspaceError.notFound
        }
        created = true
        try await body(root)
    } catch {
        if !created { XCTFail("Publication fixture creation failed before testing writes: \(error)") }
        await cleanup()
        throw error
    }
    await cleanup()
}
