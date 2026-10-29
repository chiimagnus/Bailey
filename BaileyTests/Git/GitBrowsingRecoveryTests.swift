import Foundation
import XCTest
@testable import Bailey

@MainActor
final class GitBrowsingRecoveryTests: XCTestCase {
    private var directory: URL!
    private var backend: DiscardRemoteWorkspaceFixture!
    private var model: GitStatusModel!
    private let path = "目录 空格/file '名'.txt"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        backend = DiscardRemoteWorkspaceFixture()
        model = GitStatusModel()
        for arguments in [["init", "-q"], ["config", "user.name", "Browsing Recovery"],
                          ["config", "user.email", "recovery@invalid"],
                          ["config", "commit.gpgsign", "false"],
                          ["config", "core.hooksPath", "/dev/null"]] {
            _ = try git(arguments)
        }
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("HEAD contents\n".utf8).write(to: file)
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "baseline"])
        try Data("INDEX contents\n".utf8).write(to: file)
        _ = try git(["add", "."])
        try Data("WORKTREE contents\n".utf8).write(to: file)
        model.sync(root: directory.path, backend: backend)
        try await settle()
    }

    override func tearDown() async throws {
        model.sync(root: "")
        await backend.releaseGitRequest()
        model = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func git(_ arguments: [String]) throws -> String {
        let result = GitCommandExecution.run(arguments, in: directory.path, timeout: 10)
        guard result.status == 0 else {
            XCTFail(result.stderr)
            throw WorkspaceError.notFound
        }
        return result.stdout
    }

    private func settle() async throws {
        let deadline = Date().addingTimeInterval(10)
        while !model.hasResolvedStatus || model.isRefreshing || model.isBusy {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testCoreFailureKeepsRealFileAndDiffReadableButCannotWriteGit() async throws {
        let entry = try XCTUnwrap(model.changedEntries.first { $0.path == path })
        let staged = try XCTUnwrap(model.stagedEntries.first { $0.path == path })
        let target = model.actionTarget()
        let head = try git(["rev-parse", "HEAD"])
        let status = try git(["status", "--porcelain=v1"])

        for transportFailure in [false, true] {
            await backend.setGitDirectoryUnavailable(!transportFailure)
            await backend.setGitUnavailable(transportFailure)
            model.refresh()
            try await settle()
            XCTAssertNotNil(model.statusError)
            XCTAssertFalse(model.canUseCurrentStatus)
            XCTAssertFalse(model.isCurrent(entry))
            XCTAssertFalse(model.isCurrent(staged))
            XCTAssertFalse(model.isCurrent(model.actionTarget()))
            XCTAssertTrue(model.canBrowse(entry))
            XCTAssertTrue(model.canBrowse(target))
            XCTAssertTrue(model.canOpen(entry, isRemote: false),
                          "A Git query failure must not revoke navigation to this repository's file")
            if model.canOpen(entry, isRemote: false) {
                let file = FileTab(path: model.absolutePath(for: entry),
                                   backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
                try await file.waitForText()
                XCTAssertEqual(file.text, "WORKTREE contents\n")
            }

            for (source, old, new) in [
                (DiffTab.Source.staged, "HEAD contents\n", "INDEX contents\n"),
                (.worktree, "INDEX contents\n", "WORKTREE contents\n")
            ] {
                let diff = DiffTab(repoRoot: model.repoRoot, path: path, source: source,
                                   untracked: false, origPath: nil,
                                   backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
                diff.reload()
                let deadline = Date().addingTimeInterval(10)
                while diff.isLoading, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertFalse(diff.isLoading)
                XCTAssertNil(diff.error)
                XCTAssertEqual(diff.oldContent, old)
                XCTAssertEqual(diff.newContent, new)
            }

            model.stageEntries([entry])
            model.unstageEntries([staged])
            XCTAssertFalse(model.isBusy)
            XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
            XCTAssertEqual(try git(["status", "--porcelain=v1"]), status)
            XCTAssertEqual(try git(["show", ":" + path]), "INDEX contents\n")
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(path)),
                           Data("WORKTREE contents\n".utf8))
        }

        await backend.setGitDirectoryUnavailable(false)
        await backend.setGitUnavailable(false)
        model.refresh()
        try await settle()
        XCTAssertNil(model.statusError)
        model.stageEntries([try XCTUnwrap(model.changedEntries.first { $0.path == path })])
        try await settle()
        XCTAssertEqual(try git(["show", ":" + path]), "WORKTREE contents\n")
    }

    func testCachedBrowsingKeepsTargetIsolationAndChecksFileExistence() async throws {
        let entry = try XCTUnwrap(model.changedEntries.first { $0.path == path })
        let target = model.actionTarget()
        model.sync(root: "", backend: backend)
        XCTAssertFalse(model.canOpen(entry, isRemote: true))
        XCTAssertFalse(model.canBrowse(target))
        await backend.suspendNextGitRequest()
        model.sync(root: directory.path, backend: backend)
        XCTAssertFalse(model.canUseCurrentStatus)
        let restored = try XCTUnwrap(model.changedEntries.first { $0.path == path })
        XCTAssertTrue(model.canOpen(restored, isRemote: false))
        XCTAssertFalse(model.canOpen(entry, isRemote: true), "An old menu cannot reuse a reopened snapshot")
        let deadline = Date().addingTimeInterval(5)
        while await !backend.awaitingGit {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        await backend.releaseGitRequest()
        try await settle()

        model.sync(root: directory.path, backend: backend, scope: "ssh:another-machine")
        XCTAssertFalse(model.canOpen(restored, isRemote: true))
        XCTAssertFalse(model.canBrowse(target))
        try await settle()
        let remote = try XCTUnwrap(model.changedEntries.first { $0.path == path })
        try FileManager.default.removeItem(at: directory.appendingPathComponent(path))
        XCTAssertFalse(model.canOpen(remote, isRemote: false))
        XCTAssertTrue(model.canOpen(remote, isRemote: true))
        model.sync(root: directory.path, backend: DiscardRemoteWorkspaceFixture(),
                   scope: "ssh:another-machine")
        XCTAssertFalse(model.canOpen(remote, isRemote: true), "An old connection's captured row stays invalid")
        try await settle()
    }

    func testIndependentReadFailureIsReportedWithoutReadingTheLocalNamesake() async throws {
        let entry = try XCTUnwrap(model.changedEntries.first { $0.path == path })
        await backend.setGitDirectoryUnavailable(true)
        model.refresh()
        try await settle()
        XCTAssertNotNil(model.statusError)
        XCTAssertTrue(model.canOpen(entry, isRemote: true))
        await backend.setReadUnavailable(true)
        let file = FileTab(path: model.absolutePath(for: entry), backend: backend, workspaceIdentity: nil)
        do {
            try await file.waitForText()
            XCTFail("The selected backend cannot read this file; a local namesake is not a fallback")
        } catch {
            XCTAssertEqual(file.text, "")
            guard case .unavailable = file.content else {
                return XCTFail("A failed read must have an explicit unavailable result")
            }
        }
        let diff = DiffTab(repoRoot: model.repoRoot, path: path, source: .worktree,
                           untracked: false, origPath: nil, backend: backend, workspaceIdentity: nil)
        diff.reload()
        let deadline = Date().addingTimeInterval(10)
        while diff.isLoading, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(diff.isLoading)
        XCTAssertNotNil(diff.error)
        XCTAssertFalse(diff.hasLoadedContent)
        XCTAssertFalse(diff.isEditable)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(path)),
                       Data("WORKTREE contents\n".utf8))
    }

    func testUnreadableLocalFileKeepsNavigationButReportsPermissionFailure() async throws {
        let entry = try XCTUnwrap(model.changedEntries.first { $0.path == path })
        await backend.setGitUnavailable(true)
        model.refresh()
        try await settle()
        XCTAssertNotNil(model.statusError)
        let fileURL = directory.appendingPathComponent(path)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fileURL.path)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: fileURL.path)
                XCTAssertEqual(try Data(contentsOf: fileURL), Data("WORKTREE contents\n".utf8))
            } catch {
                XCTFail("Unable to restore and verify the test-owned file: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: fileURL.path))
        XCTAssertTrue(model.canOpen(entry, isRemote: false))
        let file = FileTab(path: fileURL.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        do {
            try await file.waitForText()
            XCTFail("A permission failure must not be presented as readable content")
        } catch {
            XCTAssertEqual(file.text, "")
            guard case .unavailable = file.content else {
                return XCTFail("The editor must report the failed read")
            }
        }
    }
}
