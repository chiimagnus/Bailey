import Foundation
import XCTest
@testable import kero

@MainActor
final class GitWorkspaceSSHTests: XCTestCase {
    private func settle(_ model: GitStatusModel) async throws {
        let deadline = Date().addingTimeInterval(40)
        while !model.hasResolvedStatus || model.isBusy || model.isRefreshing {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.lastError, model.lastError ?? "")
    }

    func testAuthorizedSSHRefArchiveBinaryResetStashCleanAndIgnorePersistOnWindows() async throws {
        guard let host = ProcessInfo.processInfo.environment["KERO_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set KERO_P4_TEST_SSH_HOST to an explicitly authorized dedicated SSH test host")
        }
        let socket = "/tmp/kp4-git-\(UUID().uuidString.prefix(8)).sock"
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket), timeout: 25)
        let created = try await backend.run(argv: ["mktemp", "-d", "/tmp/kero-p4-git-XXXXXX"],
                                            cwd: nil, env: nil, stdin: nil, timeout: 25)
        XCTAssertEqual(created.status, 0, String(decoding: created.stderr, as: UTF8.self))
        let root = String(decoding: created.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("kero-p4-git-") else {
            throw WorkspaceError.notFound
        }
        let repo = root + "/workspace"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("kero-p4-download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        func cleanup() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Could not remove test-owned remote directory \(root): \(error)") }
            do {
                let stopped = try await Task.detached {
                    try ProcessRemoteCommandRunner.launch(sshPath: "/usr/bin/ssh",
                        arguments: ["-S", socket, "-O", "exit", host], stdin: nil, timeout: 10)
                }.value
                XCTAssertEqual(stopped.status, 0)
            } catch { XCTFail("Could not stop test-owned master \(socket): \(error)") }
        }
        func git(_ args: [String]) async throws -> String {
            let result = await GitCommandExecution.run(args, in: repo, timeout: 25, backend: backend)
            guard result.status == 0 else { XCTFail(result.stderr); throw WorkspaceError.notFound }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            let setup = """
            set -eu
            git init --bare -q origin.git
            git init -q -b main workspace
            cd workspace
            git config user.name 'P4 SSH Git'
            git config user.email ssh-git@invalid
            git config commit.gpgsign false
            git config core.hooksPath /dev/null
            git config core.autocrlf false
            git remote add origin ../origin.git
            """
            let result = try await backend.run(argv: ["sh", "-s"], cwd: root, env: nil,
                                               stdin: Data(setup.utf8), timeout: 25)
            XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
            let historical = Data([0, 255, 13, 10, 128, 7])
            try await backend.write(path: repo + "/literal[1].bin", data: historical)
            _ = try await git(["add", "."])
            _ = try await git(["commit", "-qm", "historical binary"])
            let revision = try await git(["rev-parse", "HEAD"])
            _ = try await git(["branch", "export/history"])
            try await backend.write(path: repo + "/literal[1].bin", data: Data([22, 33, 44]))
            _ = try await git(["commit", "-qam", "new binary"])
            let head = try await git(["rev-parse", "HEAD"])
            let model = GitStatusModel()
            model.sync(root: repo, backend: backend, scope: "ssh:" + host)
            try await settle(model)
            XCTAssertEqual(model.repoRoot, repo)
            model.pushBranch("export/history", remotes: ["origin"], setUpstream: true,
                             mode: .normal, target: model.actionTarget())
            try await settle(model)
            let server = try await git(["ls-remote", "origin", "refs/heads/export/history"])
            XCTAssertTrue(server.hasPrefix(revision + "\t"))
            let destination = local.appendingPathComponent("download.zip")
            await model.createArchive(reference: "refs/heads/export/history", objectOID: revision,
                destination: destination, target: model.actionTarget())
            try await settle(model)
            XCTAssertTrue(try Data(contentsOf: destination).starts(with: Data("PK".utf8)))
            let extracted = try await LocalWorkspaceBackend.shared.run(
                argv: ["/usr/bin/unzip", "-p", destination.path, "literal[[]1].bin"],
                cwd: local.path, env: nil, stdin: nil, timeout: 10)
            XCTAssertEqual(extracted.status, 0, String(decoding: extracted.stderr, as: UTF8.self))
            XCTAssertEqual(extracted.stdout, historical, "Remote ZIP must contain selected Ref, not HEAD")
            let remote = try XCTUnwrap(model.remoteBranch(named: "origin/export/history"))
            model.deleteRemoteBranch(remote, target: model.actionTarget())
            try await settle(model)
            let remaining = try await git(["ls-remote", "origin", "refs/heads/export/history"])
            XCTAssertEqual(remaining, "")
            let commit = try XCTUnwrap(model.recentCommits.first { $0.hash == revision })
            let captured = await model.historicalFileState("literal[1].bin", target: model.actionTarget())
            let state = try XCTUnwrap(captured)
            model.resetHistoricalFile("literal[1].bin", at: commit,
                target: model.actionTarget(), expectedFileState: state)
            try await settle(model)
            let worktree = try await backend.read(path: repo + "/literal[1].bin", maxBytes: 100)
            let index = await GitCommandExecution.runData(["show", ":literal[1].bin"],
                in: repo, timeout: 25, backend: backend)
            XCTAssertEqual(worktree, historical)
            XCTAssertEqual(index.stdout, historical)
            let unchangedHead = try await git(["rev-parse", "HEAD"])
            XCTAssertEqual(unchangedHead, head)
            model.stash(message: "SSH selected stash", target: model.actionTarget())
            try await settle(model)
            let selected = try XCTUnwrap(model.stashes.first)
            XCTAssertTrue(selected.message.contains("SSH selected stash"))
            model.actOnStash(selected, action: .pop, reinstateIndex: true,
                             target: model.actionTarget())
            try await settle(model)
            XCTAssertTrue(model.stashes.isEmpty)
            let restored = try await backend.read(path: repo + "/literal[1].bin", maxBytes: 100)
            XCTAssertEqual(restored, historical)
            let restoredIndex = await GitCommandExecution.runData(["show", ":literal[1].bin"],
                in: repo, timeout: 25, backend: backend)
            XCTAssertEqual(restoredIndex.stdout, historical)
            try await backend.createDirectory(path: repo + "/untracked-dir")
            try await backend.write(path: repo + "/untracked-dir/keep.txt", data: Data("keep".utf8))
            try await backend.write(path: repo + "/remove.txt", data: Data("remove".utf8))
            model.refresh()
            try await settle(model)
            model.cleanUntracked(includeDirectories: false, target: model.actionTarget())
            try await settle(model)
            let removed = try await backend.stat(path: repo + "/remove.txt")
            let kept = try await backend.stat(path: repo + "/untracked-dir/keep.txt")
            XCTAssertNil(removed)
            XCTAssertNotNil(kept)
            model.cleanUntracked(includeDirectories: true, target: model.actionTarget())
            try await settle(model)
            let removedDirectory = try await backend.stat(path: repo + "/untracked-dir")
            XCTAssertNil(removedDirectory)
            let project = Project(fallbackName: "SSH Ignore", workspaceConfiguration: .standard)
            project.sshHost = host
            project.customDirectory = repo
            let context = try XCTUnwrap(project.panelContext)
            try await project.ignoreGitPaths(["literal[2].txt"], isDirectory: false,
                repository: repo, context: context, isCurrent: { true })
            let rules = try await backend.read(path: repo + "/.gitignore", maxBytes: 1024)
            XCTAssertEqual(String(decoding: rules, as: UTF8.self), "/literal\\[2\\].txt\n")
            let ignored = try await git(["check-ignore", "--no-index", "--", "literal[2].txt"])
            XCTAssertEqual(ignored, "literal[2].txt")
            guard case .file(let file) = project.selectedTab?.content else {
                XCTFail("SSH Ignore must use an ordinary FileTab")
                throw WorkspaceError.notFound
            }
            XCTAssertFalse(file.isDirty)
            XCTAssertEqual(file.workspaceIdentity, "ssh:" + host)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}
