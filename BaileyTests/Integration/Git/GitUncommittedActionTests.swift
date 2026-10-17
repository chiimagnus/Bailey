import Foundation
import XCTest
@testable import Bailey

@MainActor
final class GitUncommittedActionTests: XCTestCase {
    private var directory: URL!
    private var model: GitStatusModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-uncommitted-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Uncommitted Test"])
        _ = try git(["config", "user.email", "uncommitted@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["config", "core.hooksPath", "/dev/null"])
        try Data("base\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        _ = try git(["add", "tracked.txt"])
        _ = try git(["commit", "-qm", "base"])
        model = GitStatusModel()
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let result = GitCommandExecution.run(arguments, in: directory.path, timeout: 12)
        guard result.status == 0 else {
            XCTFail(result.stderr)
            throw WorkspaceError.notFound
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func settle() async throws {
        let deadline = Date().addingTimeInterval(16)
        while !model.hasResolvedStatus || model.isBusy || model.isRefreshing {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func refresh() async throws {
        model.sync(root: directory.path)
        try await settle()
    }

    func testStashPreservesMessageAndUntrackedDefaultOrChoice() async throws {
        try Data("first\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        try Data("untracked\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        try await refresh()
        model.stash(message: "message from native alert", includeUntracked: true,
                    target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertTrue(try git(["stash", "list"]).contains("message from native alert"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new.txt").path))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("tracked.txt"), encoding: .utf8),
                       "base\n")

        try Data("second\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        try Data("keep untracked\n".utf8).write(to: directory.appendingPathComponent("keep.txt"))
        model.refresh()
        try await settle()
        model.stash(message: "", includeUntracked: false, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("keep.txt").path))
    }

    func testMixedResetPreservesWorktreeWhileHardResetsTrackedButNotUntracked() async throws {
        try Data("staged\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        _ = try git(["add", "tracked.txt"])
        try Data("new worktree\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        try Data("leave untracked\n".utf8).write(to: directory.appendingPathComponent("untracked.txt"))
        let head = try git(["rev-parse", "HEAD"])
        try await refresh()

        model.resetUncommitted(mode: .mixed, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("tracked.txt"), encoding: .utf8),
                       "new worktree\n")
        _ = try git(["add", "tracked.txt"])
        model.refresh()
        try await settle()
        model.resetUncommitted(mode: .hard, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("tracked.txt"), encoding: .utf8),
                       "base\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("untracked.txt").path))
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
    }

    func testCleanUntrackedHonorsDirectoryChoiceAndIgnoredFiles() async throws {
        try Data("*.keep\n".utf8).write(to: directory.appendingPathComponent(".gitignore"))
        _ = try git(["add", ".gitignore"])
        _ = try git(["commit", "-qm", "ignore"])
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("ignored.keep"))
        try Data("untracked".utf8).write(to: directory.appendingPathComponent("file.txt"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("untracked-folder"),
                                                withIntermediateDirectories: true)
        try Data("folder file".utf8).write(
            to: directory.appendingPathComponent("untracked-folder/one.txt"))
        try await refresh()
        model.cleanUntracked(includeDirectories: false, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("file.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("untracked-folder/one.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ignored.keep").path))
        model.cleanUntracked(includeDirectories: true, target: model.actionTarget())
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("untracked-folder").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ignored.keep").path))
    }

    func testDirectoryStageAndUnstageNeverTouchOtherDirectories() async throws {
        for name in ["a/inside.txt", "b/outside.txt"] {
            let file = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("original".utf8).write(to: file)
        }
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "both directories"])
        try Data("change".utf8).write(to: directory.appendingPathComponent("a/inside.txt"))
        try Data("change".utf8).write(to: directory.appendingPathComponent("b/outside.txt"))
        try await refresh()
        let inside = model.changedEntries.filter { $0.path.hasPrefix("a/") }
        XCTAssertEqual(inside.count, 1)
        model.stageEntries(inside)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "a/inside.txt")
        model.unstageEntries(model.stagedEntries.filter { $0.path.hasPrefix("a/") })
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "")
        XCTAssertEqual(try git(["diff", "--name-only"]).split(separator: "\n").count, 2)
    }
}
