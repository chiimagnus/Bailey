import Foundation
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

        model.commitMessage = "local draft"
        model.sync(root: root, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.commitMessage.isEmpty)
        model.commitMessage = "remote draft"
        model.sync(root: root)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.commitMessage, "local draft")

        try write("changed\n")
        model.refresh()
        try await wait { !model.isRefreshing }
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
}
