import Foundation
import XCTest
@testable import Bailey

@MainActor
final class GitWorkspaceActionTests: XCTestCase {
    private var root: URL!
    private var model: GitStatusModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-workspace-actions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        model = GitStatusModel()
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Workspace Test"])
        try git(["config", "user.email", "workspace@invalid"])
        try git(["config", "commit.gpgsign", "false"])
    }

    override func tearDown() async throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let result = GitCommandExecution.run(args, in: root.path)
        guard result.status == 0 else { XCTFail(result.stderr); throw WorkspaceError.notFound }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func settle() async throws {
        let deadline = Date().addingTimeInterval(15)
        while !model.hasResolvedStatus || model.isBusy || model.isRefreshing {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func refresh() async throws { model.sync(root: root.path); try await settle() }

    func testDirectoryBatchSupportsUnbornHeadAndLiteralPaths() async throws {
        try write("inside/[file]*", "one")
        try write("inside/other", "two")
        try write("outside/keep", "three")
        try await refresh()
        XCTAssertFalse(model.hasHead)
        model.stageEntries(model.changedEntries.filter { $0.path.hasPrefix("inside/") })
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["ls-files"]).split(separator: "\n").count, 2)
        model.unstageEntries(model.stagedEntries)
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["ls-files"]), "")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("inside/[file]*"), encoding: .utf8), "one")
    }

    func testDirectoryUnstageIncludesBothSidesOfRenameAndPreservesOtherStagedPaths() async throws {
        try write("old.txt", "original\n")
        try write("outside.txt", "original\n")
        try git(["add", "."]); try git(["commit", "-qm", "base"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inside"), withIntermediateDirectories: true)
        try git(["mv", "old.txt", "inside/new.txt"])
        try write("outside.txt", "changed\n"); try git(["add", "outside.txt"])
        try await refresh()
        model.unstageEntries(model.stagedEntries.filter { $0.path.hasPrefix("inside/") })
        try await settle()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "outside.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("inside/new.txt").path))
    }

    func testIndexDeletionAndSamePathUntrackedRemainSeparateGitRows() async throws {
        try write("retained.txt", "kept")
        try git(["add", "retained.txt"])
        try git(["commit", "-qm", "baseline"])
        try git(["rm", "--cached", "-q", "retained.txt"])
        try await refresh()
        XCTAssertTrue(model.stagedEntries.contains {
            $0.path == "retained.txt" && $0.staged == "D"
        })
        XCTAssertTrue(model.changedEntries.contains {
            $0.path == "retained.txt" && $0.staged == "?"
        }, "The same disk file must remain selectable as untracked for Ignore")
    }

    func testStaleFileRowFromPreviousBranchCannotStageNewBranchChanges() async throws {
        try write("tracked.txt", "baseline")
        try git(["add", "tracked.txt"])
        try git(["commit", "-qm", "base"])
        try write("tracked.txt", "main edit")
        try await refresh()
        let old = try XCTUnwrap(model.changedEntries.first {
            $0.path == "tracked.txt"
        })
        try git(["reset", "--hard", "HEAD"])
        try git(["switch", "-c", "other"])
        try write("tracked.txt", "other edit")
        try await refresh()
        XCTAssertEqual(model.branch, "other")
        XCTAssertTrue(model.changedEntries.contains { $0.path == old.path })

        model.stage(old)
        try await settle()
        XCTAssertTrue(try git(["diff", "--cached", "--name-only"]).isEmpty,
            "A stale row must not stage another branch's file content")
        XCTAssertNotNil(model.lastError)
    }

    func testFailedPreparationAndStaleTargetDoNotCleanOrStash() async throws {
        try write("tracked", "base"); try git(["add", "."]); try git(["commit", "-qm", "base"])
        try write("tracked", "changed"); try write("untracked", "keep")
        try await refresh()
        let target = model.actionTarget()
        model.cleanUntracked(includeDirectories: true, target: target, prepare: { false })
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("untracked").path))
        model.stash(message: "refused", target: target, prepare: { false })
        try await settle()
        XCTAssertEqual(try git(["stash", "list"]), "")
        try git(["commit", "--allow-empty", "-qm", "moved"])
        model.cleanUntracked(includeDirectories: true, target: target)
        try await settle()
        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("untracked").path))
    }
}
