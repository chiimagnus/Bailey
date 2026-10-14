import AppKit
import SwiftUI
import XCTest
@testable import kero

@MainActor
final class GitInteractiveRebaseTests: XCTestCase {
    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while try await !condition() {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testInteractiveRebaseNewPTYUsesRepositoryAndWaitsForRealEditorInput() async throws {
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ arguments: [String]) throws -> String {
            let result = GitCommandExecution.run(arguments, in: directory.path, timeout: 10)
            guard result.status == 0 else {
                XCTFail(result.stderr)
                throw WorkspaceError.notFound
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "PTY Rebase"])
        _ = try git(["config", "user.email", "pty@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["commit", "--allow-empty", "-qm", "root"])
        _ = try git(["switch", "-c", "side"])
        try Data("side".utf8).write(to: directory.appendingPathComponent("side.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "side"])
        let side = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "main"])
        try Data("main".utf8).write(to: directory.appendingPathComponent("main.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "main"])
        let previousHead = try git(["rev-parse", "HEAD"])
        let editorPath = directory.appendingPathComponent("sequence-editor.sh")
        let marker = directory.appendingPathComponent("editor-ready")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$PWD\" > " + RemoteCommands.quote(marker.path)
            + "\n[ -t 0 ] || exit 71\nprintf 'PTY\\n' >> " + RemoteCommands.quote(marker.path)
            + "\nprintf 'KERO_SEQUENCE_EDITOR_READY\\n'\nread -r reply\n"
        try script.write(to: editorPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editorPath.path)
        _ = try git(["config", "sequence.editor", RemoteCommands.quote(editorPath.path)])
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        let project = Project(fallbackName: "PTY Rebase", workspaceConfiguration: .standard)
        project.customDirectory = directory.path
        manager.projects = [project]
        manager.selectedProjectID = project.id
        let context = try XCTUnwrap(project.panelContext)
        let terminal = try project.newInteractiveGitSession(
            repository: directory.path, arguments: ["rebase", "--interactive", side], context: context
        )
        defer { terminal.terminate() }
        let tab = try XCTUnwrap(project.selectedTab)
        XCTAssertEqual(tab.content.id, terminal.id)
        let window = NSWindow(contentRect: .init(x: -1200, y: -1200, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: PanelContentView(
            tab: tab, isSelected: true, onFocused: {}, onNewBrowserTab: { _ in }, onNewFileTab: { _ in }
        ))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await wait { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), directory.path + "\nPTY\n")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), previousHead, "The real sequence editor must still be waiting")
        terminal.sendCommand("\r")
        try await wait {
            let head = GitCommandExecution.run(["rev-parse", "HEAD^"], in: directory.path).stdout
            return head.trimmingCharacters(in: .whitespacesAndNewlines) == side
        }
        XCTAssertEqual(try git(["show", "HEAD:main.txt"]), "main")
        XCTAssertEqual(try git(["show", "HEAD:side.txt"]), "side")
        XCTAssertFalse(terminal.hasExited, "The new terminal must remain available for results and recovery")
    }

    func testAuthorizedSSHInteractiveRebaseUsesIndependentHandshakeForPinnedAndAutomaticProjects() async throws {
        guard let host = ProcessInfo.processInfo.environment["KERO_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set KERO_P4_TEST_SSH_HOST to an explicitly authorized dedicated SSH test host")
        }
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }
        let socket = "/tmp/kp4-src-\(UUID().uuidString.prefix(8)).sock"
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket), timeout: 25)
        let created = try await backend.run(argv: ["mktemp", "-d", "/tmp/kero-p4-ssh-XXXXXX"],
                                            cwd: nil, env: nil, stdin: nil, timeout: 25)
        XCTAssertEqual(created.status, 0, String(decoding: created.stderr, as: UTF8.self))
        let root = String(decoding: created.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("kero-p4-ssh-") else {
            throw WorkspaceError.notFound
        }
        func cleanup() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Could not clean this test's remote directory \(root): \(error)") }
            do {
                let stopped = try await Task.detached {
                    try ProcessRemoteCommandRunner.launch(
                        sshPath: "/usr/bin/ssh", arguments: ["-S", socket, "-O", "exit", host], stdin: nil, timeout: 10
                    )
                }.value
                XCTAssertEqual(stopped.status, 0, String(decoding: stopped.stderr, as: UTF8.self))
            } catch { XCTFail("Could not stop test-owned SSH master \(socket): \(error)") }
        }
        func git(_ arguments: [String]) async throws -> String {
            let result = await GitCommandExecution.run(arguments, in: root, timeout: 25, backend: backend)
            guard result.status == 0 else {
                XCTFail(result.stderr)
                throw WorkspaceError.notFound
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            let setup = """
            set -eu
            git init -q -b main
            git config user.name 'SSH PTY Rebase'
            git config user.email ssh-pty@invalid
            git config commit.gpgsign false
            git config core.hooksPath /dev/null
            git commit --allow-empty -qm root
            git switch -qc side
            printf side > side.txt
            git add side.txt
            git commit -qm side
            git switch -q main
            printf main > main.txt
            git add main.txt
            git commit -qm main
            cat > sequence-editor.sh <<'KERO_EDITOR'
            #!/bin/sh
            [ -t 0 ] || exit 71
            printf '%s\\nPTY\\n' "$PWD" > editor-ready
            printf 'KERO_SSH_SEQUENCE_EDITOR_READY\\n'
            read -r reply
            KERO_EDITOR
            git config sequence.editor 'sh ./sequence-editor.sh'
            """
            let prepared = try await backend.run(argv: ["sh", "-s"], cwd: root, env: nil,
                                                 stdin: Data(setup.utf8), timeout: 25)
            guard prepared.status == 0 else {
                XCTFail(String(decoding: prepared.stderr, as: UTF8.self))
                throw WorkspaceError.notFound
            }
            let side = try await git(["rev-parse", "refs/heads/side"])
            let original = try await git(["rev-parse", "HEAD"])
            let configuration = try XCTUnwrap(KeroSSHPassthrough.resolvedConfiguration(arguments: [host], realSSH: "/usr/bin/ssh"))
            for pinned in [true, false] {
                print("P4 SSH test: pinned=\(pinned), temporary repository=\(root)")
                _ = try await git(["switch", "main"])
                _ = try await git(["reset", "--hard", original])
                let cleared = try await backend.run(argv: ["rm", "-f", "editor-ready"], cwd: root,
                                                    env: nil, stdin: nil, timeout: 25)
                XCTAssertEqual(cleared.status, 0)
                let manager = TerminalManager()
                defer { manager.windowClosed() }
                let project = Project(fallbackName: "SSH PTY Rebase", workspaceConfiguration: .standard)
                manager.projects = [project]
                manager.selectedProjectID = project.id
                let context: PanelContext
                var source: TerminalSession?
                if pinned {
                    project.sshHost = host
                    project.customDirectory = root
                    context = PanelContext(identity: .pinned(project: project.id, workspace: "ssh:" + host, directory: root), backend: backend)
                } else {
                    let session = TerminalSession(launchCommand: "exec /bin/sh -i")
                    source = session
                    let connection = RemoteConnection(user: configuration["user"] ?? "",
                        host: try XCTUnwrap(configuration["hostname"]), port: Int(configuration["port"] ?? "22") ?? 22,
                        controlSocket: URL(fileURLWithPath: socket), sshPID: getpid())
                    connection.workingDirectory = root
                    connection.markConnected()
                    session.location = .remote(connection)
                    let tab = PaneTab(content: .session(session))
                    project.append(tab)
                    project.selectedTabID = tab.id
                    context = try XCTUnwrap(project.panelContext)
                }
                defer { source?.terminate() }
                let terminal = try project.newInteractiveGitSession(repository: root,
                    arguments: ["rebase", "--interactive", side], context: context)
                defer { terminal.terminate() }
                let tab = try XCTUnwrap(project.selectedTab)
                XCTAssertEqual(terminal.workspaceIdentity, context.scope)
                XCTAssertFalse(terminal.workspaceBackend is LocalWorkspaceBackend)
                XCTAssertEqual(terminal.panelDirectoryPath, root)
                let window = NSWindow(contentRect: .init(x: -1200, y: -1200, width: 700, height: 400),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = NSHostingView(rootView: PanelContentView(tab: tab, isSelected: true,
                    onFocused: {}, onNewBrowserTab: { _ in }, onNewFileTab: { _ in }))
                window.orderFront(nil)
                window.contentView?.layoutSubtreeIfNeeded()
                do {
                    try await wait {
                        do { return try await backend.read(path: root + "/editor-ready", maxBytes: 4096).contains(Data("PTY\n".utf8)) }
                        catch WorkspaceError.notFound { return false }
                    }
                } catch {
                    let screen = TerminalHistorySerializer.previewText(from: terminal.surface, maxLines: 60, maxColumns: 160)
                    XCTFail("SSH sequence editor did not become ready: \(String(reflecting: error)); terminal: \(screen ?? "no screen export")")
                    throw error
                }
                let editorCwd = try await backend.read(path: root + "/editor-ready", maxBytes: 4096)
                XCTAssertEqual(String(decoding: editorCwd, as: UTF8.self), root + "\nPTY\n")
                terminal.applyTheme()
                let waitingHead = try await git(["rev-parse", "HEAD"])
                XCTAssertEqual(waitingHead, original)
                try await wait { terminal.location.remoteConnection != nil }
                XCTAssertNotEqual(terminal.location.remoteConnection?.controlSocket.path, socket)
                XCTAssertFalse(terminal.workspaceBackend is LocalWorkspaceBackend)
                terminal.sendCommand("\r")
                try await wait { try await git(["rev-parse", "HEAD^"]) == side }
                let mainBytes = try await git(["show", "HEAD:main.txt"])
                let sideBytes = try await git(["show", "HEAD:side.txt"])
                XCTAssertEqual(mainBytes, "main")
                XCTAssertEqual(sideBytes, "side")
                XCTAssertFalse(terminal.hasExited)
                terminal.terminate()
                try await wait { terminal.hasExited }
                source?.terminate()
            }
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }
}
