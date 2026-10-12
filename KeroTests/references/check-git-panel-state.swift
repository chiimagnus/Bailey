import Foundation


@main
enum GitPanelStateCheck {
    @MainActor
    static func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() {
            guard Date() < deadline else { fatalError("Git state did not settle") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.path
        func git(_ arguments: [String]) -> String {
            let result = GitCommandExecution.run(arguments, in: root, timeout: 10)
            precondition(result.status == 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ value: String) throws {
            try Data(value.utf8).write(to: directory.appendingPathComponent("tracked.txt"))
        }
        _ = git(["init"])
        _ = git(["config", "user.name", "Kero Check"])
        _ = git(["config", "user.email", "check@example.invalid"])
        _ = git(["config", "commit.gpgsign", "false"])
        try write("original\n")
        _ = git(["add", "."])
        _ = git(["commit", "-m", "initial"])
        let model = GitStatusModel()
        model.sync(root: root)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        precondition(model.isRepo)
        model.commitMessage = "local draft"
        model.sync(root: root, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        precondition(model.commitMessage.isEmpty)
        model.commitMessage = "remote draft"
        model.sync(root: root)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        precondition(model.commitMessage == "local draft")
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        model.sync(root: nested.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        precondition(model.commitMessage == "local draft")
        model.sync(root: root)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        try write("changed\n")
        model.refresh()
        try await wait { !model.isRefreshing }
        model.stage(model.changedEntries.first!)
        try await wait { !model.isBusy && !model.isRefreshing }
        precondition(git(["diff", "--cached", "--name-only"]) == "tracked.txt")
        model.unstage(model.stagedEntries.first!)
        try await wait { !model.isBusy && !model.isRefreshing }
        precondition(git(["diff", "--cached", "--name-only"]).isEmpty)
        model.discard(model.changedEntries.first!)
        try await wait { !model.isBusy && !model.isRefreshing }
        let restored = try String(contentsOf: directory.appendingPathComponent("tracked.txt"), encoding: .utf8)
        precondition(restored == "original\n")
        try write("committed\n")
        model.refresh()
        try await wait { !model.isRefreshing }
        let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        model.commitMessage = "failed draft"
        model.commit(message: model.commitMessage, includeAll: true)
        try await wait { !model.isBusy && !model.isRefreshing }
        precondition(model.commitMessage == "failed draft")
        precondition(git(["log", "-1", "--format=%s"]) == "initial")
        try Data("#!/bin/sh\nsleep 1\n".utf8).write(to: hook)
        model.commitMessage = "submitted"
        model.commit(message: model.commitMessage, includeAll: true)
        precondition(model.isBusy)
        model.commitMessage = "edited during commit"
        try await wait { !model.isBusy && !model.isRefreshing }
        precondition(model.commitMessage == "edited during commit")
        precondition(git(["log", "-1", "--format=%s"]) == "submitted")
        model.commit(message: model.commitMessage, includeAll: false, amend: true)
        try await wait { !model.isBusy && !model.isRefreshing }
        precondition(model.commitMessage.isEmpty)
        precondition(git(["log", "-1", "--format=%s"]) == "edited during commit")
        model.commitMessage = "old target"
        model.commit(message: model.commitMessage, includeAll: false, amend: true)
        model.sync(root: root, scope: "ssh:fixture")
        try await wait { !model.isBusy && !model.isRefreshing && model.hasResolvedStatus }
        precondition(model.commitMessage == "remote draft")
        precondition(git(["log", "-1", "--format=%s"]) == "old target")
        model.sync(root: root)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        precondition(model.commitMessage == "old target")
        print("PASS: real Git stage/unstage/discard/commit; draft failure/edit/success/scope/root isolation")
    }
}
