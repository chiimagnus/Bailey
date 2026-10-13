import Foundation
import Observation
import XCTest
@testable import kero

@MainActor
final class GitStatusModelTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Git model did not settle")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testStageUnstageDiscardCommitAndScopedDrafts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.path
        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: root, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ text: String) throws {
            try Data(text.utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        }
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.name", "Kero Test"])
        _ = try git(["config", "user.email", "test@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        try write("original\n")
        _ = try git(["add", "."])
        _ = try git(["commit", "-m", "initial"])

        let model = GitStatusModel()
        model.sync(root: root)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)

        let draftChanged = expectation(description: "Commit draft is observed")
        withObservationTracking({ _ = model.commitMessage }) { draftChanged.fulfill() }
        model.commitMessage = "local draft"
        await fulfillment(of: [draftChanged], timeout: 1)

        let collapseChanged = expectation(description: "Scoped Git folder state is observed")
        withObservationTracking({ _ = model.collapsedFolders }) { collapseChanged.fulfill() }
        model.toggleCollapsedFolder("docs")
        await fulfillment(of: [collapseChanged], timeout: 1)
        XCTAssertTrue(model.collapsedFolders.contains("docs"))
        model.sync(root: root, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.commitMessage.isEmpty)
        model.commitMessage = "remote draft"
        model.sync(root: root)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.commitMessage, "local draft")

        try write("changed\n")
        let statusChanged = expectation(description: "Git changes list is observed")
        withObservationTracking({ _ = model.changedEntries }) { statusChanged.fulfill() }
        model.refresh()
        try await wait { !model.isRefreshing }
        await fulfillment(of: [statusChanged], timeout: 1)
        let changed = try XCTUnwrap(model.changedEntries.first)
        model.stage(changed)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"]), "tracked.txt")

        let staged = try XCTUnwrap(model.stagedEntries.first)
        model.unstage(staged)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertTrue(try git(["diff", "--cached", "--name-only"]).isEmpty)

        model.discard(try XCTUnwrap(model.changedEntries.first))
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("tracked.txt"), encoding: .utf8), "original\n")

        try write("committed\n")
        model.refresh()
        try await wait { !model.isRefreshing }
        model.commitMessage = "submitted"
        model.commit(message: model.commitMessage, includeAll: true)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "submitted")
        XCTAssertTrue(model.commitMessage.isEmpty)
    }

    func testUnbornRepositoryAndPagedHistorySurviveRepositorySwitch() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = fixture.appendingPathComponent("first")
        let second = fixture.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        func git(_ args: [String], in repository: URL) throws -> String {
            let result = GitCommandExecution.run(args, in: repository.path, timeout: 15)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for repository in [first, second] {
            _ = try git(["init", "-q"], in: repository)
            _ = try git(["config", "user.name", "Git Model Test"], in: repository)
            _ = try git(["config", "user.email", "test@invalid"], in: repository)
            _ = try git(["config", "commit.gpgsign", "false"], in: repository)
        }

        let model = GitStatusModel()
        model.sync(root: first.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertFalse(model.hasHead)
        XCTAssertNil(model.headOID)
        XCTAssertTrue(model.recentCommits.isEmpty)

        try Data("first commit\n".utf8).write(to: first.appendingPathComponent("initial.txt"))
        model.refresh()
        try await wait { !model.isRefreshing }
        let untracked = try XCTUnwrap(model.changedEntries.first { $0.path == "initial.txt" })
        model.stage(untracked)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try git(["diff", "--cached", "--name-only"], in: first), "initial.txt")

        let staged = try XCTUnwrap(model.stagedEntries.first { $0.path == "initial.txt" })
        model.unstage(staged)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertTrue(try git(["diff", "--cached", "--name-only"], in: first).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("initial.txt").path))

        model.stage(try XCTUnwrap(model.changedEntries.first { $0.path == "initial.txt" }))
        try await wait { !model.isBusy && !model.isRefreshing }
        model.commit(message: "first", includeAll: false)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try git(["log", "-1", "--format=%s"], in: first), "first")
        XCTAssertTrue(model.hasHead)

        for index in 1...31 {
            _ = try git(["commit", "--allow-empty", "-qm", "revision-\(index)"], in: first)
        }
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"], in: first), "32")
        model.refresh()
        try await wait { !model.isRefreshing && model.recentCommits.count == 30 }
        XCTAssertTrue(model.hasMoreRecentCommits)
        XCTAssertEqual(model.recentCommits.first?.subject, "revision-31")
        XCTAssertTrue(model.loadMoreCommits())
        try await wait { !model.isRefreshing && !model.isLoadingMoreCommits && model.recentCommits.count == 32 }
        XCTAssertFalse(model.hasMoreRecentCommits)
        XCTAssertEqual(model.recentCommits.last?.subject, "first")

        model.sync(root: second.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertFalse(model.hasHead)
        XCTAssertTrue(model.recentCommits.isEmpty)

        model.sync(root: first.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.hasHead)
        XCTAssertEqual(model.recentCommits.count, 32)
        XCTAssertFalse(model.hasMoreRecentCommits)
        XCTAssertEqual(model.recentCommits.first?.subject, "revision-31")
    }
}
