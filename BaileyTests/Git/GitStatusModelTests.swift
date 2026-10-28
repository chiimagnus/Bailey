import Foundation
import Observation
import XCTest
@testable import Bailey

@MainActor
final class GitStatusModelTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

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

    func testGitNavigationSurvivesPanelRemountButNotDifferentProjectOrRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-Git-Nav-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Project(fallbackName: "first", workspaceConfiguration: .standard)
        let second = Project(fallbackName: "second", workspaceConfiguration: .standard)
        first.customDirectory = directory.path
        second.customDirectory = directory.path
        XCTAssertNotEqual(first.id, second.id)
        let git = GitStatusModel()
        git.syncSelectedProject(project: first, isCurrent: { _ in true })
        let selection = GitStatusModel.ChangeSelection(
            scope: "local", repository: directory.path,
            section: "unstaged", path: "same-name.txt"
        )
        let commit = String(repeating: "a", count: 40)
        git.changeCursor = selection
        git.changeSelection = selection
        git.expandedCommitIDs = [commit]

        git.syncSelectedProject(project: first, isCurrent: { _ in true })
        XCTAssertEqual(git.changeCursor, selection)
        XCTAssertEqual(git.changeSelection, selection)
        XCTAssertEqual(git.expandedCommitIDs, [commit],
                       "Rebinding the same panel target must preserve valid disclosure")

        git.syncSelectedProject(project: second, isCurrent: { _ in true })
        XCTAssertNil(git.changeCursor,
                     "Two different projects sharing the same Git root must not share the cursor")
        XCTAssertNil(git.changeSelection)
        XCTAssertTrue(git.expandedCommitIDs.isEmpty,
                      "The previous project's Graph must not appear in the new project")

        git.changeCursor = selection
        git.changeSelection = selection
        git.expandedCommitIDs = [commit]
        git.sync(root: directory.appendingPathComponent("other").path)
        XCTAssertNil(git.changeCursor)
        XCTAssertNil(git.changeSelection)
        XCTAssertTrue(git.expandedCommitIDs.isEmpty)
    }

    func testBackgroundRefreshPreservesUnchangedToolbarAndGraphData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["config", "user.name", "Event Test"],
            ["config", "user.email", "event@invalid"],
            ["config", "commit.gpgsign", "false"],
        ] {
            XCTAssertEqual(GitCommandExecution.run(arguments, in: directory.path).status, 0)
        }
        let file = directory.appendingPathComponent("tracked.txt")
        try Data("one\n".utf8).write(to: file)
        for arguments in [["add", "."], ["commit", "-qm", "initial"]] {
            XCTAssertEqual(GitCommandExecution.run(arguments, in: directory.path).status, 0)
        }
        try Data("one\ntwo\n".utf8).write(to: file)

        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:poll-test")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.lineAdditions, 1)
        XCTAssertTrue(model.hasCurrentLineTotals)
        let originalCommits = model.recentCommits

        let toolbarChanged = expectation(description: "Unchanged refresh does not invalidate status bar")
        toolbarChanged.isInverted = true
        withObservationTracking({
            _ = model.hasCurrentLineTotals
            _ = model.lineAdditions
            _ = model.lineDeletions
            _ = model.branch
            _ = model.changedEntries
        }) { toolbarChanged.fulfill() }
        let menuChanged = expectation(description: "Unchanged refresh does not rebuild graph menu")
        menuChanged.isInverted = true
        withObservationTracking({
            _ = model.recentCommits
            _ = model.stashes
            _ = model.refsByName
            _ = model.worktreeLocations
            _ = model.statusError
            _ = model.hasResolvedStatus
            _ = model.isResolvingInitialStatus
        }) { menuChanged.fulfill() }

        await backend.suspendNextGitRequest()
        model.refresh()
        let deadline = Date().addingTimeInterval(10)
        while !(await backend.awaitingGit), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let suspended = await backend.awaitingGit
        XCTAssertTrue(suspended, "The test must observe an actual in-flight refresh")
        XCTAssertTrue(model.hasCurrentLineTotals, "In-flight refresh must preserve confirmed totals")
        XCTAssertEqual(model.lineAdditions, 1)
        await backend.releaseGitRequest()
        try await wait { !model.isRefreshing }
        XCTAssertEqual(model.recentCommits, originalCommits)
        await fulfillment(of: [toolbarChanged, menuChanged], timeout: 0.2)

        try Data("one\ntwo\nthree\n".utf8).write(to: file)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertEqual(model.lineAdditions, 2, "Real changes must still update the status bar")
    }

    func testLocalFileChangesRefreshWithoutPollingOrManualRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["config", "user.name", "Event Test"],
            ["config", "user.email", "event@invalid"],
            ["config", "commit.gpgsign", "false"],
            ["commit", "--allow-empty", "-qm", "initial"],
        ] {
            XCTAssertEqual(GitCommandExecution.run(arguments, in: directory.path).status, 0)
        }
        let tracked = directory.appendingPathComponent("tracked.txt")
        try Data("initial\n".utf8).write(to: tracked)
        for arguments in [["add", "tracked.txt"], ["commit", "-qm", "tracked"]] {
            XCTAssertEqual(GitCommandExecution.run(arguments, in: directory.path).status, 0)
        }
        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)

        try Data("modified\n".utf8).write(to: tracked)
        try await wait { model.changedEntries.contains { $0.path == "tracked.txt" } }
        XCTAssertTrue(model.changedEntries.contains { $0.path == "tracked.txt" })

        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("external edit\n".utf8).write(to: nested.appendingPathComponent("external.txt"))
        try await wait {
            model.changedEntries.contains { $0.path == "nested/external.txt" }
        }
        XCTAssertTrue(model.changedEntries.contains { $0.path == "nested/external.txt" })

        XCTAssertEqual(GitCommandExecution.run(["tag", "external-tag"], in: directory.path).status, 0)
        try await wait { model.refsByName["refs/tags/external-tag"] != nil }
        XCTAssertNotNil(model.refsByName["refs/tags/external-tag"])
    }

    func testLinkedWorktreeWatchesCommonGitMetadata() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let primary = base.appendingPathComponent("primary", isDirectory: true)
        let linked = base.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func git(_ args: [String]) {
            let run = GitCommandExecution.run(args, in: primary.path)
            XCTAssertEqual(run.status, 0, "\(args): \(run.stderr)")
        }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "Worktree Watch Test"])
        git(["config", "user.email", "watch@invalid"])
        git(["config", "commit.gpgsign", "false"])
        git(["commit", "--allow-empty", "-qm", "initial"])
        git(["worktree", "add", "-qb", "feature", linked.path])

        let model = GitStatusModel()
        model.sync(root: linked.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let gitDir = GitCommandExecution.run(["rev-parse", "--absolute-git-dir"], in: linked.path)
        XCTAssertEqual(gitDir.status, 0)
        let watched = GitFileEventWatcher.paths(
            root: linked.path,
            gitDirectory: gitDir.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        XCTAssertTrue(watched.contains(linked.path))
        XCTAssertTrue(watched.contains(primary.appendingPathComponent(".git").path),
                      "Linked worktree must watch the shared refs directory")

        git(["branch", "another-from-primary"])
        try await wait { model.refsByName["refs/heads/another-from-primary"] != nil }
        XCTAssertNotNil(model.refsByName["refs/heads/another-from-primary"])

        let nested = linked.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("from outside Bailey\n".utf8).write(to: nested.appendingPathComponent("new.swift"))
        try await wait { model.changedEntries.contains(where: { $0.path == "src/new.swift" }) }
        XCTAssertTrue(model.changedEntries.contains(where: { $0.path == "src/new.swift" }))
    }

    func testPrimaryWorktreeDetectsUncommittedChangesInAnotherWorktree() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let primary = base.appendingPathComponent("main", isDirectory: true)
        let linked = base.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.name", "Linked Changes"],
            ["config", "user.email", "worktrees@invalid"],
            ["config", "commit.gpgsign", "false"],
            ["commit", "--allow-empty", "-qm", "initial"],
        ] {
            XCTAssertEqual(GitCommandExecution.run(args, in: primary.path).status, 0)
        }
        XCTAssertEqual(GitCommandExecution.run(
            ["worktree", "add", "-qb", "linked", linked.path], in: primary.path
        ).status, 0)
        let model = GitStatusModel()
        model.sync(root: primary.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing
            && model.worktreeLocations.count == 2 }
        XCTAssertTrue(model.otherWorktrees.allSatisfy { $0.entries.isEmpty })
        let linkedRoot = GitCommandExecution.run(
            ["rev-parse", "--show-toplevel"], in: linked.path
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(model.worktreeLocations.contains { $0.path == linkedRoot })

        try Data("from another working tree\n".utf8)
            .write(to: linked.appendingPathComponent("external.txt"))
        try await wait {
            model.otherWorktrees.contains {
                $0.path == linkedRoot && $0.entries.contains { $0.path == "external.txt" }
            }
        }
        XCTAssertTrue(model.otherWorktrees.contains {
            $0.path == linkedRoot && $0.entries.contains { $0.path == "external.txt" }
        })
    }

    func testLocalWatcherStopsFollowingPreviousWorkspace() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("first", isDirectory: true)
        let second = base.appendingPathComponent("second", isDirectory: true)
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for args in [
                ["init", "-q", "-b", "main"],
                ["config", "user.name", "Switch Test"],
                ["config", "user.email", "switch@invalid"],
                ["config", "commit.gpgsign", "false"],
                ["commit", "--allow-empty", "-qm", "initial"],
            ] {
                XCTAssertEqual(GitCommandExecution.run(args, in: folder.path).status, 0)
            }
        }
        let model = GitStatusModel()
        model.sync(root: first.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        model.sync(root: second.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let resolvedSecond = GitCommandExecution.run(
            ["rev-parse", "--show-toplevel"], in: second.path
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(model.repoRoot, resolvedSecond)

        let unexpected = expectation(description: "Old worktree events do not query the new repository")
        unexpected.isInverted = true
        withObservationTracking({ _ = model.isRefreshing }) { unexpected.fulfill() }
        try Data("old worktree only\n".utf8).write(to: first.appendingPathComponent("external.txt"))
        await fulfillment(of: [unexpected], timeout: 1)
        XCTAssertEqual(model.repoRoot, resolvedSecond)
        XCTAssertTrue(model.changedEntries.isEmpty)

        try Data("new worktree\n".utf8).write(to: second.appendingPathComponent("external.txt"))
        try await wait { model.changedEntries.contains(where: { $0.path == "external.txt" }) }
    }

    func testCreatingLocalGitRepositoryIsObservedWithoutPolling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertFalse(model.isRepo)
        XCTAssertEqual(GitCommandExecution.run(["init", "-q", "-b", "main"], in: directory.path).status, 0)
        try await wait { model.isRepo && model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
    }

    func testLocalFileEventsPauseInBackgroundAndRestoreOnActivation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [
            ["init", "-q", "-b", "main"], ["config", "user.name", "App State Test"],
            ["config", "user.email", "app@invalid"],
            ["config", "commit.gpgsign", "false"],
            ["commit", "--allow-empty", "-qm", "initial"],
        ] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }

        model.setLocalFileEventsForeground(false)
        try Data("background edit\n".utf8).write(to: directory.appendingPathComponent("background.txt"))
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(model.changedEntries.isEmpty,
                      "Background filesystem events must not start Git queries")

        model.setLocalFileEventsForeground(true)
        try await wait { model.changedEntries.contains(where: { $0.path == "background.txt" }) }
        XCTAssertTrue(model.changedEntries.contains(where: { $0.path == "background.txt" }))

        try Data("foreground edit\n".utf8).write(to: directory.appendingPathComponent("active.txt"))
        try await wait { model.changedEntries.contains(where: { $0.path == "active.txt" }) }
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
        _ = try git(["config", "user.name", "Bailey Test"])
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

    func testDiscardReviewGuardsContentSymlinkAndRepositoryScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func git(_ args: [String]) throws {
            let result = GitCommandExecution.run(args, in: directory.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Discard Review Test"])
        try git(["config", "user.email", "test@invalid"])
        try git(["config", "commit.gpgsign", "false"])
        let tracked = directory.appendingPathComponent("tracked.txt")
        try Data("original\n".utf8).write(to: tracked)
        try git(["add", "."])
        try git(["commit", "-qm", "baseline"])

        let untracked = directory.appendingPathComponent("untracked.txt")
        let firstTarget = directory.appendingPathComponent("first.txt")
        let secondTarget = directory.appendingPathComponent("second.txt")
        let link = directory.appendingPathComponent("alias.txt")
        try Data("new".utf8).write(to: untracked)
        try Data("first".utf8).write(to: firstTarget)
        try Data("second".utf8).write(to: secondTarget)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: firstTarget
        )
        try Data("modified\n".utf8).write(to: tracked)

        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let trackedEntry = try XCTUnwrap(model.changedEntries.first { $0.path == "tracked.txt" })
        let untrackedEntry = try XCTUnwrap(model.changedEntries.first { $0.path == "untracked.txt" })
        let linkEntry = try XCTUnwrap(model.changedEntries.first { $0.path == "alias.txt" })

        // A new edit or a symlink retargeted while the confirmation is open
        // must not delete anything from the reviewed set.
        let originalReviews = model.prepareLocalDiscard([trackedEntry, untrackedEntry, linkEntry])
        XCTAssertEqual(originalReviews.count, 3)
        try Data("modified again (longer)\n".utf8).write(to: tracked)
        XCTAssertFalse(model.confirmLocalDiscard(originalReviews))
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "modified again (longer)\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: untracked.path))

        let linkReview = try XCTUnwrap(model.prepareLocalDiscard([linkEntry]).first)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: secondTarget
        )
        XCTAssertFalse(model.confirmLocalDiscard([linkReview]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       secondTarget.path)

        // Dismissing a valid confirmation never invokes a Git or delete action.
        let cancelled = model.prepareLocalDiscard([untrackedEntry])
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertEqual(try String(contentsOf: untracked, encoding: .utf8), "new")

        let oldScope = try XCTUnwrap(model.prepareLocalDiscard([trackedEntry]).first)
        model.sync(root: directory.path, scope: "ssh:unrelated-host")
        XCTAssertFalse(model.confirmLocalDiscard([oldScope]))
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "modified again (longer)\n")

        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let current = try XCTUnwrap(model.changedEntries.first { $0.path == "tracked.txt" })
        let reviewed = model.prepareLocalDiscard([current])
        XCTAssertTrue(model.confirmLocalDiscard(reviewed))
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "original\n")
        XCTAssertEqual(try String(contentsOf: untracked, encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       secondTarget.path)

        XCTAssertFalse(model.canOpen(untrackedEntry, isRemote: false),
                       "An old file row cannot be reused after switching repository scope")
        let currentUntracked = try XCTUnwrap(model.changedEntries.first {
            $0.path == "untracked.txt"
        })
        XCTAssertTrue(model.canOpen(currentUntracked, isRemote: false))
        try FileManager.default.removeItem(at: untracked)
        XCTAssertFalse(model.canOpen(currentUntracked, isRemote: false))
        XCTAssertTrue(model.canOpen(currentUntracked, isRemote: true))
    }

    func testRemoteDiscardReviewRejectsDisconnectionAndInFlightScopeChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func git(_ args: [String]) throws {
            let result = GitCommandExecution.run(args, in: directory.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Remote Review Test"])
        try git(["config", "user.email", "test@invalid"])
        try git(["config", "commit.gpgsign", "false"])
        let tracked = directory.appendingPathComponent("tracked.txt")
        try Data("baseline".utf8).write(to: tracked)
        try git(["add", "."])
        try git(["commit", "-qm", "baseline"])
        let candidate = directory.appendingPathComponent("remote-only.txt")
        try Data("preserved remote fixture".utf8).write(to: candidate)

        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo, model.statusError ?? "Remote fixture must resolve Git")
        let entry = try XCTUnwrap(model.changedEntries.first { $0.path == "remote-only.txt" })

        let reviewed = try await model.prepareRemoteDiscard([entry])
        XCTAssertEqual(reviewed.count, 1)
        await backend.setOnline(false)
        let disconnected = await model.confirmRemoteDiscard(reviewed)
        XCTAssertFalse(disconnected)
        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8),
                       "preserved remote fixture")
        let attemptsAfterDisconnect = await backend.deleteAttempts
        XCTAssertEqual(attemptsAfterDisconnect, 0)

        await backend.setOnline(true)
        let oldReview = try await model.prepareRemoteDiscard([entry])
        try Data("changed after review".utf8).write(to: candidate)
        let contentChanged = await model.confirmRemoteDiscard(oldReview)
        XCTAssertFalse(contentChanged)
        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8),
                       "changed after review")
        let attemptsAfterChange = await backend.deleteAttempts
        XCTAssertEqual(attemptsAfterChange, 0)

        await backend.setPauseMetadata(true)
        let previousReads = await backend.metadataReads
        let reviewing = Task {
            try await model.prepareRemoteDiscard([entry])
        }
        let deadline = Date().addingTimeInterval(5)
        while await backend.metadataReads == previousReads, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let readsAfterStart = await backend.metadataReads
        XCTAssertGreaterThan(readsAfterStart, previousReads)
        model.sync(root: directory.path, backend: backend, scope: "ssh:another-host")
        do {
            _ = try await reviewing.value
            XCTFail("Metadata gathered in the old SSH context must be rejected")
        } catch GitStatusModel.DiscardReviewError.stale {
            // Expected: context changed before async preflight completed.
        }
        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8),
                       "changed after review")
        let attemptsAfterSwitch = await backend.deleteAttempts
        XCTAssertEqual(attemptsAfterSwitch, 0)
    }

    func testIndexMutationAndPaginationAvoidUnrelatedGitQueries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Refresh Test"],
                     ["config", "user.email", "refresh@invalid"], ["config", "commit.gpgsign", "false"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        for number in 0..<34 {
            XCTAssertEqual(GitCommandExecution.run(["commit", "--allow-empty", "-qm", "change \(number)"],
                in: directory.path).status, 0)
        }
        try Data("one\ntwo\n".utf8).write(to: directory.appendingPathComponent("fresh.txt"))
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:scoped-refresh")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.canUseCurrentHistory)
        XCTAssertEqual(model.recentCommits.count, 30)
        XCTAssertTrue(model.hasMoreRecentCommits)
        let initialHead = model.headOID
        let initialHistory = model.recentCommits

        let beforeStage = await backend.commands.count
        model.stageAll()
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(model.headOID, initialHead)
        XCTAssertEqual(model.recentCommits, initialHistory)
        XCTAssertTrue(model.canUseCurrentHistory)
        XCTAssertTrue(model.hasCurrentLineTotals)
        XCTAssertEqual(model.lineAdditions, 2)
        XCTAssertEqual(GitCommandExecution.run(["diff", "--cached", "--name-only"], in: directory.path).stdout,
            "fresh.txt\n")
        let stagedCommands = Array((await backend.commands).dropFirst(beforeStage)).joined(separator: "\n")
        XCTAssertFalse(stagedCommands.contains("git 'log' "), stagedCommands)
        XCTAssertFalse(stagedCommands.contains("git 'for-each-ref' "), stagedCommands)
        XCTAssertFalse(stagedCommands.contains("git 'stash' 'list' "), stagedCommands)

        try Data("three\n".utf8).write(to: directory.appendingPathComponent("untracked.txt"))
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertEqual(model.lineAdditions, 3)

        let beforePage = await backend.commands.count
        XCTAssertTrue(model.loadMoreCommits())
        try await wait { !model.isLoadingMoreCommits && !model.isRefreshing }
        XCTAssertEqual(model.recentCommits.count, 34)
        XCTAssertFalse(model.hasMoreRecentCommits)
        let pageCommands = Array((await backend.commands).dropFirst(beforePage)).joined(separator: "\n")
        XCTAssertTrue(pageCommands.contains("git 'log' "), pageCommands)
        XCTAssertFalse(pageCommands.contains("git 'diff' '--numstat' "), pageCommands)
        XCTAssertFalse(pageCommands.contains("count_bytes()"), pageCommands)
        XCTAssertFalse(pageCommands.contains("git 'stash' 'list' "), pageCommands)
        XCTAssertTrue(model.canUseCurrentHistory)
        XCTAssertEqual(model.lineAdditions, 3)

        XCTAssertEqual(GitCommandExecution.run(["tag", "outside"], in: directory.path).status, 0)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNotNil(model.refsByName["refs/tags/outside"])
    }

    func testIndexMutationDoesNotDowngradeQueuedFullRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Pending Test"],
                     ["config", "user.email", "pending@invalid"], ["config", "commit.gpgsign", "false"],
                     ["commit", "--allow-empty", "-qm", "initial"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:pending")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertNil(model.refsByName["refs/tags/new-external"])
        XCTAssertEqual(GitCommandExecution.run(["tag", "new-external"], in: directory.path).status, 0)
        try Data("new\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        model.stageAll()
        model.refresh()
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNotNil(model.refsByName["refs/tags/new-external"])
        XCTAssertEqual(model.stagedEntries.map(\.path), ["new.txt"])
        XCTAssertTrue(model.hasCurrentLineTotals)
    }

    func testHistoryPageEscalatesWhenExternalReferenceChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Page Test"],
                     ["config", "user.email", "page@invalid"], ["config", "commit.gpgsign", "false"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        for number in 0..<35 {
            XCTAssertEqual(GitCommandExecution.run(["commit", "--allow-empty", "-qm", "page \(number)"],
                in: directory.path).status, 0)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:page")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        await backend.suspendHistoryRequest()
        XCTAssertTrue(model.loadMoreCommits())
        let deadline = Date().addingTimeInterval(10)
        while !(await backend.awaitingGit), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let suspended = await backend.awaitingGit
        XCTAssertTrue(suspended)
        XCTAssertEqual(GitCommandExecution.run(["tag", "external-in-flight"], in: directory.path).status, 0)
        await backend.releaseGitRequest()
        try await wait { !model.isRefreshing && !model.isLoadingMoreCommits }
        XCTAssertEqual(model.recentCommits.count, 35)
        XCTAssertNotNil(model.refsByName["refs/tags/external-in-flight"])
        XCTAssertTrue(model.canUseCurrentHistory)
    }

    func testFailedHistoryPageRetainsLastPageWithoutRequeryingStashOrNumstat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Page Failure Test"],
                     ["config", "user.email", "page-failure@invalid"],
                     ["config", "commit.gpgsign", "false"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        for number in 0..<32 {
            XCTAssertEqual(GitCommandExecution.run(["commit", "--allow-empty", "-qm", "page \(number)"],
                in: directory.path).status, 0)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:page-error")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.recentCommits.count, 30)
        await backend.setHistoryLogUnavailable(true)
        let before = await backend.commands.count
        XCTAssertTrue(model.loadMoreCommits())
        try await wait { !model.isRefreshing && !model.isLoadingMoreCommits }
        XCTAssertNotNil(model.detailError)
        XCTAssertEqual(model.recentCommits.count, 30)
        XCTAssertTrue(model.canUseCurrentHistory, "The previously loaded page remains verified")
        let commands = Array((await backend.commands).dropFirst(before)).joined(separator: "\n")
        XCTAssertFalse(commands.contains("git 'stash' 'list' "), commands)
        XCTAssertFalse(commands.contains("git 'diff' '--numstat' "), commands)
        await backend.setHistoryLogUnavailable(false)
        model.refresh(kind: .historyOnly)
        try await wait { !model.isRefreshing }
        XCTAssertNil(model.detailError)
        XCTAssertEqual(model.recentCommits.count, 32)
    }

    func testHistoryPageDoesNotLoseFullRefreshForConcurrentFileChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Page Change Test"],
                     ["config", "user.email", "page-change@invalid"], ["config", "commit.gpgsign", "false"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        for number in 0..<32 {
            XCTAssertEqual(GitCommandExecution.run(["commit", "--allow-empty", "-qm", "page \(number)"],
                in: directory.path).status, 0)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:page-files")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.lineAdditions, 0)
        await backend.suspendHistoryRequest()
        XCTAssertTrue(model.loadMoreCommits())
        let deadline = Date().addingTimeInterval(10)
        while !(await backend.awaitingGit), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let suspended = await backend.awaitingGit
        XCTAssertTrue(suspended)
        try Data("fresh\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        // A change occurring after the page's core scan requires the normal
        // full-refresh event; the history query cannot infer an unseen write.
        model.refresh()
        await backend.releaseGitRequest()
        try await wait { !model.isRefreshing && !model.isLoadingMoreCommits }
        XCTAssertEqual(model.recentCommits.count, 32)
        XCTAssertEqual(model.changedEntries.map(\.path), ["new.txt"])
        XCTAssertEqual(model.lineAdditions, 1)
        XCTAssertTrue(model.hasCurrentLineTotals)
    }

    func testFileDecorationsMatchFullScanForModifiedRenamedIgnoredAndDuplicatePath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ args: [String]) {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, "\(args): \(result.stderr)")
        }
        func write(_ path: String, _ content: String) throws {
            let file = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file)
        }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "Decoration Test"])
        git(["config", "user.email", "decor@invalid"])
        git(["config", "commit.gpgsign", "false"])
        try write(".gitignore", "ignored/\nfoo/ignored.log\n")
        for path in ["foo/file.swift", "foobar/file.swift", "tracked/nested/first.swift",
                     "tracked/nested/second.swift", "tracked/dupe.swift", "tracked/delete.swift"] {
            try write(path, "distinct baseline for \(path)\n")
        }
        git(["add", "-A"])
        git(["commit", "-qm", "baseline"])
        try write("foo/file.swift", "modified\n")
        try write("tracked/nested/first.swift", "staged\n")
        git(["add", "tracked/nested/first.swift"])
        try write("tracked/nested/first.swift", "staged\nagain\n")
        git(["mv", "tracked/nested/second.swift", "tracked/nested/renamed.swift"])
        git(["rm", "--cached", "--", "tracked/dupe.swift"])
        git(["rm", "--", "tracked/delete.swift"])
        try write("ignored/deeper/cache", "ignored\n")
        try write("foo/ignored.log", "ignored\n")
        try write("foo/untracked.swift", "new\n")
        try write("foo/added.swift", "added\n")
        git(["add", "foo/added.swift"])
        try write("foo/added.swift", "added\nmodified\n")
        try write("foo/quote' and tab\t.swift", "untracked\n")
        try write("tracked/nested/换行\n名字.swift", "special name\n")
        try write("ignored/emoji-😀.txt", "ignored\n")

        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertTrue(model.stagedEntries.contains { $0.path == "tracked/dupe.swift" })
        XCTAssertTrue(model.changedEntries.contains { $0.path == "tracked/dupe.swift" })
        XCTAssertTrue(model.changedEntries.contains { $0.path == "foo/untracked.swift" })
        XCTAssertEqual(model.fileDecorations["foo/added.swift"], .added)
        XCTAssertEqual(model.fileDecorations["tracked/nested/first.swift"], .modified)
        XCTAssertEqual(model.fileDecorations["tracked/nested/renamed.swift"], .renamed)
        XCTAssertEqual(model.fileDecorations["tracked/delete.swift"], .deleted)
        XCTAssertEqual(model.fileDecorations["tracked/dupe.swift"], .deleted)

        // Contract oracle: the original complete scan, independent of the new index.
        func slow(_ relative: String, isDirectory: Bool) -> GitStatusModel.FileDecoration? {
            if let direct = model.fileDecorations[relative] { return direct }
            if model.ignoredPaths.contains(where: { path in
                if path.hasSuffix("/") {
                    let prefix = String(path.dropLast())
                    return relative == prefix || relative.hasPrefix(prefix + "/")
                }
                return relative == path
            }) { return .ignored }
            guard isDirectory, !relative.isEmpty else { return nil }
            let prefix = relative + "/"
            return model.fileDecorations.filter { $0.key.hasPrefix(prefix) }
                .map(\.value).max { $0.directoryPriority < $1.directoryPriority }
        }
        let candidates = ["", "foo", "foo/file.swift", "foo/added.swift", "foo/untracked.swift", "foo/ignored.log",
                          "foo/quote' and tab\t.swift", "tracked/nested/换行\n名字.swift", "ignored/emoji-😀.txt",
                          "foobar", "foobar/file.swift", "foobar-extra", "tracked", "tracked/nested",
                          "tracked/nested/renamed.swift", "tracked/dupe.swift", "tracked/delete.swift",
                          "ignored", "ignored/deeper", "ignored/deeper/cache", "ignored-extra",
                          "other", "tracked-unrelated", "tracked/nested/file.swift"]
        for path in candidates {
            let absolute = (model.repoRoot as NSString).appendingPathComponent(path)
            for isDirectory in [false, true] {
                XCTAssertEqual(model.fileDecoration(for: absolute, isDirectory: isDirectory),
                               slow(path, isDirectory: isDirectory), "path=\(path), directory=\(isDirectory)")
            }
        }
        XCTAssertEqual(model.fileDecoration(for: (model.repoRoot as NSString).appendingPathComponent("ignored/deeper/cache"),
                                            isDirectory: false), .ignored)
        XCTAssertNil(model.fileDecoration(for: "/tmp/outside-bailey-decoration-\(UUID().uuidString)", isDirectory: true))
        XCTAssertNotNil(model.fileDecoration(for: model.repoRoot + "/tracked", isDirectory: true))
        for index in 0..<1_500 {
            let prefix = ["foo", "foobar", "tracked/nested", "ignored/deeper", "tracked-other"][index % 5]
            let path = "\(prefix)/candidate-\(index)/leaf-\(index % 11).swift"
            let absolute = (model.repoRoot as NSString).appendingPathComponent(path)
            XCTAssertEqual(model.fileDecoration(for: absolute, isDirectory: false),
                           slow(path, isDirectory: false), "seeded path \(index)")
            XCTAssertEqual(model.fileDecoration(for: absolute, isDirectory: true),
                           slow(path, isDirectory: true), "seeded directory \(index)")
        }

        try write("foo/file.swift", "updated once more\n")
        model.refresh()
        try await wait { !model.isRefreshing }
        for path in candidates {
            let absolute = (model.repoRoot as NSString).appendingPathComponent(path)
            XCTAssertEqual(model.fileDecoration(for: absolute, isDirectory: true),
                           slow(path, isDirectory: true), "after external update: \(path)")
        }
        model.sync(root: FileManager.default.temporaryDirectory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertNil(model.fileDecoration(for: directory.appendingPathComponent("tracked").path, isDirectory: true))
    }

    func testDirectoryDecorationPreservesConflictPriorityAfterMerge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ args: [String], expected: Int32 = 0) {
            let run = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(run.status, expected, "\(args): \(run.stderr)")
        }
        func write(_ path: String, _ text: String) throws {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "Conflict Test"])
        git(["config", "user.email", "conflict@invalid"])
        git(["config", "commit.gpgsign", "false"])
        try write("nested/conflicted.txt", "original\n")
        try write("nested/modified.txt", "unchanged\n")
        git(["add", "-A"])
        git(["commit", "-qm", "baseline"])
        git(["switch", "-qc", "other"])
        try write("nested/conflicted.txt", "other\n")
        git(["commit", "-qam", "other change"])
        git(["switch", "main"])
        try write("nested/conflicted.txt", "main\n")
        git(["commit", "-qam", "main change"])
        try write("nested/modified.txt", "new\n")
        git(["merge", "other", "--no-edit"], expected: 1)

        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.fileDecorations["nested/conflicted.txt"], .conflict)
        XCTAssertEqual(model.fileDecorations["nested/modified.txt"], .modified)
        XCTAssertEqual(model.fileDecoration(for: directory.appendingPathComponent("nested").path,
                                            isDirectory: true), .conflict)
        XCTAssertNil(model.fileDecoration(for: directory.appendingPathComponent("nested-other").path,
                                          isDirectory: true))
        git(["merge", "--abort"])
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertEqual(model.fileDecoration(for: directory.appendingPathComponent("nested").path,
                                            isDirectory: true), .modified)
    }

    func testCoreStatusIsUsableWhileHistoryIsSuspended() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Core Test"],
                          ["config", "user.email", "core@invalid"], ["config", "commit.gpgsign", "false"],
                          ["commit", "--allow-empty", "-qm", "initial"]] {
            let result = GitCommandExecution.run(arguments, in: directory.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try Data("new text\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
        let backend = DiscardRemoteWorkspaceFixture()
        await backend.suspendHistoryRequest()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:core-test")
        let deadline = Date().addingTimeInterval(10)
        while !(await backend.awaitingGit), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let suspended = await backend.awaitingGit
        XCTAssertTrue(suspended)
        XCTAssertTrue(model.hasResolvedStatus)
        XCTAssertTrue(model.isRepo)
        XCTAssertEqual(model.branch, "main")
        XCTAssertTrue(model.hasHead)
        XCTAssertNotNil(model.headOID)
        XCTAssertEqual(model.changedEntries.map(\.path), ["new.txt"])
        XCTAssertNil(model.repositoryOperation)
        XCTAssertFalse(model.canUseCurrentHistory)
        XCTAssertFalse(model.hasCurrentLineTotals)
        let timeouts = await backend.requestTimeouts
        XCTAssertTrue(timeouts.allSatisfy { $0 != nil && $0! > 0 && $0! <= 24 })
        let runsBeforeAction = await backend.gitRuns
        model.fetch()
        XCTAssertFalse(model.isBusy)
        XCTAssertNotNil(model.lastError)
        let runsAfterAction = await backend.gitRuns
        XCTAssertEqual(runsBeforeAction, runsAfterAction)
        model.commit(message: "amended without history", includeAll: true, amend: true)
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["amended without history"])
        XCTAssertTrue(model.canUseCurrentHistory)
        let amended = model.headOID
        await backend.releaseGitRequest()
        try await wait { !model.isRefreshing }
        XCTAssertEqual(model.headOID, amended)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["amended without history"])
        XCTAssertEqual(GitCommandExecution.run(["show", "HEAD:new.txt"], in: directory.path).stdout, "new text\n")
    }

    func testCoreIsDeliveredBeforeRefMetadataAndSurvivesRefFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [
            ["init", "-q", "-b", "main"], ["config", "user.name", "Core Ref Test"],
            ["config", "user.email", "core-ref@invalid"],
            ["commit", "--allow-empty", "-qm", "initial"]
        ] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        let file = directory.appendingPathComponent("untracked.txt")
        try Data("new\n".utf8).write(to: file)
        let backend = DiscardRemoteWorkspaceFixture()
        await backend.suspendRefSnapshotRequest()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:slow-refs")
        let deadline = Date().addingTimeInterval(10)
        while !(await backend.awaitingGit), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let suspendedOnRefs = await backend.awaitingGit
        XCTAssertTrue(suspendedOnRefs)
        XCTAssertTrue(model.hasResolvedStatus, "Core must publish before waiting on refs")
        XCTAssertTrue(model.canUseCurrentStatus)
        XCTAssertEqual(model.changedEntries.map(\.path), ["untracked.txt"])
        XCTAssertEqual(model.branch, "main")
        XCTAssertFalse(model.canUseCurrentReferences)
        await backend.releaseGitRequest()
        try await wait { !model.isRefreshing }
        XCTAssertTrue(model.canUseCurrentReferences)

        let stashResult = GitCommandExecution.run(
            ["stash", "push", "--include-untracked", "--message", "preserved"],
            in: directory.path
        )
        XCTAssertEqual(stashResult.status, 0, stashResult.stderr)
        await backend.setRefSnapshotUnavailable(true)
        try Data("newer\n".utf8).write(to: file)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNil(model.statusError)
        XCTAssertNotNil(model.detailError)
        XCTAssertTrue(model.canUseCurrentStatus)
        XCTAssertFalse(model.canUseCurrentReferences)
        XCTAssertEqual(model.changedEntries.map(\.path), ["untracked.txt"])
        XCTAssertEqual(model.stashes.count, 1)
        XCTAssertTrue(model.canUseCurrentStashes, "A verified Stash list does not depend on remote Ref metadata")

        await backend.setStashListUnavailable(true)
        await backend.setHistoryLogUnavailable(true)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertTrue(model.canUseCurrentStatus)
        XCTAssertFalse(model.canUseCurrentReferences)
        XCTAssertFalse(model.canUseCurrentHistory)
        XCTAssertFalse(model.canUseCurrentStashes)
        XCTAssertEqual(model.stashes.count, 1, "Failed optional queries must retain read-only contents")
        await backend.setRefSnapshotUnavailable(false)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertTrue(model.canUseCurrentReferences)
        XCTAssertFalse(model.canUseCurrentHistory)
        XCTAssertFalse(model.canUseCurrentStashes)
        await backend.setHistoryLogUnavailable(false)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertTrue(model.canUseCurrentHistory)
        XCTAssertFalse(model.canUseCurrentStashes)
        await backend.setStashListUnavailable(false)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertTrue(model.canUseCurrentStashes)
        XCTAssertNil(model.detailError)
    }

    func testMissingRemoteCoreBatchIsFailureWithoutIndividualRetry() async throws {
        let backend = DiscardRemoteWorkspaceFixture()
        await backend.omitNextBatch()
        let model = GitStatusModel()
        model.sync(root: "/tmp", backend: backend, scope: "ssh:missing-frame")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertNotNil(model.statusError)
        XCTAssertFalse(model.isRepo)
        let runs = await backend.gitRuns
        XCTAssertEqual(runs, 1)
    }

    func testCappedLineTotalsAreUnknownUntilACompleteReadSucceeds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(GitCommandExecution.run(["init", "-q"], in: directory.path).status, 0)
        let file = directory.appendingPathComponent("untracked")
        try Data(repeating: 65, count: 8 * 1_024 * 1_024 + 1).write(to: file)
        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertTrue(model.canUseCurrentHistory)
        XCTAssertFalse(model.hasCurrentLineTotals)
        XCTAssertNil(model.statusError)
        XCTAssertEqual(model.changedEntries.map(\.path), ["untracked"])
        try Data("one\ntwo".utf8).write(to: file)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertTrue(model.hasCurrentLineTotals)
        XCTAssertEqual(model.lineAdditions, 2)
        XCTAssertEqual(model.lineDeletions, 0)
    }

    func testDetailsQualificationFollowsCoreIdentityRatherThanRefreshActivity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Qualification Test"],
                          ["config", "user.email", "qualification@invalid"], ["config", "commit.gpgsign", "false"],
                          ["commit", "--allow-empty", "-qm", "initial"]] {
            XCTAssertEqual(GitCommandExecution.run(arguments, in: directory.path).status, 0)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:qualification")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let oldHead = try XCTUnwrap(model.headOID)
        for changesHead in [false, true] {
            if changesHead {
                XCTAssertEqual(GitCommandExecution.run(["commit", "--allow-empty", "-qm", "changed"],
                    in: directory.path).status, 0)
            }
            await backend.suspendHistoryRequest()
            model.refresh()
            XCTAssertTrue(model.canUseCurrentHistory, "Merely starting a query must not cancel a valid retry")
            let deadline = Date().addingTimeInterval(10)
            while !(await backend.awaitingGit), Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let suspended = await backend.awaitingGit
            XCTAssertTrue(suspended)
            XCTAssertEqual(model.canUseCurrentHistory, !changesHead)
            if changesHead { XCTAssertNotEqual(model.headOID, oldHead) }
            await backend.releaseGitRequest()
            try await wait { !model.isRefreshing }
            XCTAssertTrue(model.canUseCurrentHistory)
        }
        await backend.setHistoryLogUnavailable(true)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNotNil(model.detailError)
        XCTAssertNil(model.statusError, "An optional Git history failure must not disable verified core status")
        XCTAssertFalse(model.canUseCurrentHistory)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["changed", "initial"])
    }

    func testTransientGitFailurePreservesLastRepositorySnapshotAndRecovers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ args: [String]) throws {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Git Recovery Test"])
        try git(["config", "user.email", "test@invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try "baseline\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "ignored.tmp\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "ignored contents".write(to: directory.appendingPathComponent("ignored.tmp"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-qm", "first"])
        try git(["commit", "--allow-empty", "-qm", "second"])
        try git(["branch", "topic/safe"])
        try git(["tag", "v1"])
        try git(["remote", "add", "origin", directory.path])
        try "changed\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)

        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
        let priorChanges = model.changedEntries
        XCTAssertEqual(priorChanges.map(\.path), ["tracked.txt"])
        let priorBranch = model.branch
        let priorRefs = model.refsByName
        let priorRemotes = model.remotes
        XCTAssertNotNil(priorRefs["refs/heads/topic/safe"])
        XCTAssertNotNil(priorRefs["refs/tags/v1"])
        XCTAssertEqual(priorRemotes, ["origin"])
        XCTAssertTrue(model.ignoredPaths.contains("ignored.tmp"))
        XCTAssertTrue(model.canUseCurrentReferences)
        XCTAssertTrue(model.canUseCurrentHistory)
        XCTAssertTrue(model.canUseCurrentStashes)

        await backend.setGitUnavailable(true)
        model.refresh()
        try await wait { model.statusError != nil && !model.isRefreshing }
        XCTAssertTrue(model.isRepo, "Temporary SSH/Git errors must not erase the repository")
        XCTAssertEqual(model.branch, priorBranch)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
        XCTAssertEqual(model.changedEntries, priorChanges)
        XCTAssertFalse(model.isCurrent(model.actionTarget()), "Stale SSH status must not authorize writes")
        model.stage(try XCTUnwrap(priorChanges.first,
                                  "A verified file change is required before testing stale writes"))
        let index = GitCommandExecution.run(["diff", "--cached", "--name-only"], in: directory.path)
        XCTAssertEqual(index.stdout, "", "A stale snapshot must never stage user files")

        await backend.setGitUnavailable(false)
        model.refresh()
        try await wait { model.statusError == nil && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
        XCTAssertEqual(model.changedEntries, priorChanges)

        // The main status command can succeed while the history subcommand
        // fails. That must not silently publish an empty Git Graph.
        await backend.setHistoryLogUnavailable(true)
        model.refresh()
        try await wait { model.detailError != nil && !model.isRefreshing }
        XCTAssertNil(model.statusError, "History failure cannot invalidate the core Git status")
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
        XCTAssertEqual(model.changedEntries, priorChanges)
        XCTAssertTrue(model.canUseCurrentReferences)
        XCTAssertFalse(model.canUseCurrentHistory)
        XCTAssertTrue(model.canUseCurrentStashes)

        // Returning to the same repository restores readable Graph history,
        // not fresh permission to act on that unverified history.
        model.sync(root: "", backend: backend, scope: "ssh:fixture")
        model.sync(root: directory.path, backend: backend, scope: "ssh:fixture")
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
        XCTAssertFalse(model.canUseCurrentStatus)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.canUseCurrentReferences)
        XCTAssertFalse(model.canUseCurrentHistory)
        XCTAssertTrue(model.canUseCurrentStashes)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
        await backend.setHistoryLogUnavailable(false)
        model.refresh()
        try await wait { model.detailError == nil && !model.isRefreshing }
        XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
        XCTAssertTrue(model.canUseCurrentHistory)
        XCTAssertTrue(model.canUseCurrentStashes)

        // Ignored decorations can be expensive on large SSH repositories.
        // A failure here cannot turn valid HEAD, refs, and working files stale.
        await backend.setIgnoredStatusUnavailable(true)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNil(model.statusError, "Ignored-file scanning must be optional")
        XCTAssertNotNil(model.detailError)
        XCTAssertTrue(model.canUseCurrentStatus)
        XCTAssertTrue(model.canUseCurrentHistory, "Ignored decoration is not an input to Graph actions")
        XCTAssertTrue(model.canUseCurrentStashes, "Ignored decoration is not an input to Stash actions")
        XCTAssertTrue(model.canUseCurrentReferences)
        XCTAssertEqual(model.changedEntries.map(\.path), priorChanges.map(\.path))
        XCTAssertFalse(model.isCurrent(priorChanges[0]), "The old row must stay invalid after switching repositories")
        XCTAssertTrue(model.isCurrent(model.changedEntries[0]), "The fresh row must be writable once core status is verified")
        XCTAssertTrue(model.ignoredPaths.contains("ignored.tmp"))
        model.refresh(kind: .historyOnly)
        try await wait { !model.isRefreshing }
        XCTAssertNotNil(model.detailError, "Paging must not erase an unrelated ignored-scan warning")
        await backend.setIgnoredStatusUnavailable(false)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNil(model.statusError)
        XCTAssertNil(model.detailError)

        // An individual metadata query failing must not publish a partial
        // successful snapshot that hides Branch/Tag menus or an in-progress operation.
        for kind in 0..<3 {
            switch kind {
            case 0: await backend.setRefSnapshotUnavailable(true)
            case 1: await backend.setRemoteListUnavailable(true)
            default: await backend.setGitDirectoryUnavailable(true)
            }
            model.refresh()
            try await wait { !model.isRefreshing }
            if kind == 2 {
                XCTAssertNotNil(model.statusError, "Git directory is required before core can publish")
            } else {
                XCTAssertNil(model.statusError, "Ref/remote failure cannot invalidate core status")
                XCTAssertNotNil(model.detailError)
                XCTAssertTrue(model.canUseCurrentStatus)
                XCTAssertFalse(model.canUseCurrentReferences)
            }
            XCTAssertEqual(model.refsByName, priorRefs)
            XCTAssertEqual(model.remotes, priorRemotes)
            XCTAssertEqual(model.recentCommits.map(\.subject), ["second", "first"])
            switch kind {
            case 0: await backend.setRefSnapshotUnavailable(false)
            case 1: await backend.setRemoteListUnavailable(false)
            default: await backend.setGitDirectoryUnavailable(false)
            }
            model.refresh()
            try await wait { !model.isRefreshing }
            XCTAssertNil(model.statusError)
        }

        try git(["stash", "push", "-qm", "preserve on query failure"])
        model.refresh()
        try await wait { !model.isRefreshing }
        let priorStashes = model.stashes
        XCTAssertEqual(priorStashes.count, 1)
        await backend.setStashListUnavailable(true)
        model.refresh()
        try await wait { model.detailError != nil && !model.isRefreshing }
        XCTAssertNil(model.statusError)
        XCTAssertEqual(model.stashes, priorStashes)
        XCTAssertEqual(model.stashes.count, 1)
        XCTAssertTrue(model.canUseCurrentReferences)
        XCTAssertTrue(model.canUseCurrentHistory)
        XCTAssertFalse(model.canUseCurrentStashes)
        await backend.setStashListUnavailable(false)
        try git(["stash", "clear"])
        model.refresh()
        try await wait { model.detailError == nil && !model.isRefreshing }
        XCTAssertTrue(model.stashes.isEmpty)
        XCTAssertTrue(model.canUseCurrentStashes)

        // A failed remote marker check must not turn an in-progress merge
        // into a clean repository that enables other commit actions.
        let marker = directory.appendingPathComponent(".git/MERGE_HEAD")
        try (try XCTUnwrap(model.headOID) + "\n").write(to: marker, atomically: true, encoding: .utf8)
        model.refresh()
        try await wait { !model.isRefreshing }
        let priorOperation = try XCTUnwrap(model.repositoryOperation)
        await backend.setOperationMarkerUnavailable(true)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNotNil(model.statusError, "Failed SSH marker check must not be treated as no operation")
        XCTAssertEqual(model.repositoryOperation, priorOperation)
        await backend.setOperationMarkerUnavailable(false)
        try FileManager.default.removeItem(at: marker)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNil(model.statusError)
        XCTAssertNil(model.repositoryOperation)
    }

    func testSSHCoreStatusAppearsWhileSlowHistoryIsStillLoading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [
            ["init", "-q"], ["config", "user.name", "Core Status"],
            ["config", "user.email", "core@invalid"], ["commit", "--allow-empty", "-qm", "first"]
        ] {
            let command = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(command.status, 0, command.stderr)
        }
        try Data("pending".utf8).write(to: directory.appendingPathComponent("new.txt"))
        let backend = DiscardRemoteWorkspaceFixture()
        await backend.suspendHistory()
        defer { Task { await backend.releaseHistory() } }
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:core-first")
        let deadline = Date().addingTimeInterval(10)
        while await !backend.historyWaiting && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await backend.historyWaiting
        XCTAssertTrue(waiting, "History must be a distinct SSH request")
        XCTAssertTrue(model.hasResolvedStatus, "Core status must publish before history finishes")
        XCTAssertTrue(model.isRepo)
        XCTAssertEqual(model.changedEntries.map(\.path), ["new.txt"])
        XCTAssertNil(model.statusError)
        await backend.releaseHistory()
        try await wait { !model.isRefreshing }
        XCTAssertEqual(model.recentCommits.map(\.subject), ["first"])
    }

    func testStashFileLoadRejectsStaleSSHChannelAndRetriesAfterFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-stash-ssh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.name", "Stash Channel Test"],
            ["config", "user.email", "stash-ssh@invalid"],
            ["config", "commit.gpgsign", "false"]
        ] {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        let file = directory.appendingPathComponent("tracked.txt")
        try "baseline\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitCommandExecution.run(["add", "."], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "base"], in: directory.path).status, 0)
        try "stash change\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitCommandExecution.run(
            ["stash", "push", "-qm", "saved"], in: directory.path
        ).status, 0)

        let oldChannel = DiscardRemoteWorkspaceFixture()
        let newChannel = DiscardRemoteWorkspaceFixture()
        defer { Task { await oldChannel.releaseGitRequest() } }
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: oldChannel, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing && model.isRepo }
        let selected = try XCTUnwrap(model.stashes.first)
        await oldChannel.suspendNextGitRequest()
        model.loadStashFiles(for: selected)
        let deadline = Date().addingTimeInterval(5)
        while await !oldChannel.awaitingGit, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let paused = await oldChannel.awaitingGit
        XCTAssertTrue(paused)
        XCTAssertEqual(model.stashFilesByOID[selected.oid], .loading)

        model.sync(root: directory.path, backend: newChannel, scope: "ssh:fixture")
        XCTAssertNil(model.stashFilesByOID[selected.oid],
                     "Replacing a channel must release the old loading indicator")
        try await wait { model.hasResolvedStatus && !model.isRefreshing && model.isRepo }
        let current = try XCTUnwrap(model.stashes.first)
        await newChannel.setGitUnavailable(true)
        model.loadStashFiles(for: current)
        try await wait {
            if case .failed = model.stashFilesByOID[current.oid] { return true }
            return false
        }
        await newChannel.setGitUnavailable(false)
        model.loadStashFiles(for: current)
        try await wait {
            if case .loaded = model.stashFilesByOID[current.oid] { return true }
            return false
        }
        await oldChannel.setGitUnavailable(true)
        await oldChannel.releaseGitRequest()
        if case .loaded(let changes) = model.stashFilesByOID[current.oid] {
            XCTAssertEqual(changes.map(\.path), ["tracked.txt"])
        } else {
            XCTFail("A completed new SSH read must not be overwritten by the old channel")
        }
    }

    func testReplacingSSHChannelKeepsCachedGitReadOnlyUntilCoreIsVerified() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [
            ["init", "-q"], ["config", "user.name", "SSH Verification"],
            ["config", "user.email", "ssh-verification@invalid"],
            ["config", "commit.gpgsign", "false"]
        ] {
            let run = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(run.status, 0, run.stderr)
        }
        let file = directory.appendingPathComponent("tracked.txt")
        try Data("baseline".utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["add", "."], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: directory.path).status, 0)
        try Data("changed".utf8).write(to: file)
        let oldChannel = DiscardRemoteWorkspaceFixture()
        let newChannel = DiscardRemoteWorkspaceFixture()
        defer { Task { await newChannel.releaseGitRequest() } }
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: oldChannel, scope: "ssh:verification")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let pending = try XCTUnwrap(model.changedEntries.first)
        XCTAssertTrue(model.isCurrent(model.actionTarget()))

        await newChannel.suspendNextGitRequest()
        model.sync(root: directory.path, backend: newChannel, scope: "ssh:verification")
        let deadline = Date().addingTimeInterval(5)
        while await !newChannel.awaitingGit, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let suspended = await newChannel.awaitingGit
        XCTAssertTrue(suspended)
        XCTAssertEqual(model.changedEntries.map(\.path), ["tracked.txt"])
        XCTAssertFalse(model.isCurrent(model.actionTarget()),
                       "A new SSH channel is not yet verified and cannot write from old Git status")
        model.stage(pending)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(GitCommandExecution.run(["diff", "--cached", "--name-only"], in: directory.path).stdout, "")
        await newChannel.releaseGitRequest()
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isCurrent(model.actionTarget()))

        // Reopening the same repo from the remembered snapshot must also
        // remain read-only until the restored checkout is freshly verified.
        model.sync(root: "", backend: newChannel, scope: "ssh:verification")
        await newChannel.suspendNextGitRequest()
        model.sync(root: directory.path, backend: newChannel, scope: "ssh:verification")
        XCTAssertEqual(model.changedEntries.map(\.path), ["tracked.txt"])
        XCTAssertFalse(model.isCurrent(model.actionTarget()))
        let reopenDeadline = Date().addingTimeInterval(5)
        while await !newChannel.awaitingGit, Date() < reopenDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await newChannel.releaseGitRequest()
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isCurrent(model.actionTarget()))
    }

    func testReplacingSSHBackendDoesNotWaitForStaleGitWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ args: [String]) throws {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try git(["init", "-q"])
        try git(["config", "user.name", "Git Channel Test"])
        try git(["config", "user.email", "test@invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try "hello".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-qm", "baseline"])

        let oldChannel = DiscardRemoteWorkspaceFixture()
        let newChannel = DiscardRemoteWorkspaceFixture()
        await oldChannel.suspendNextGitRequest()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: oldChannel, scope: "ssh:fixture")
        let oldDeadline = Date().addingTimeInterval(5)
        while await !oldChannel.awaitingGit, Date() < oldDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let oldStarted = await oldChannel.awaitingGit
        XCTAssertTrue(oldStarted)
        // The same host and repository, but a different SSH connection.
        model.sync(root: directory.path, backend: newChannel, scope: "ssh:fixture")
        let deadline = Date().addingTimeInterval(1.5)
        while await newChannel.gitRuns == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let launched = await newChannel.gitRuns
        await oldChannel.setGitUnavailable(true)
        await oldChannel.releaseGitRequest()
        XCTAssertGreaterThan(launched, 0, "A new SSH channel must not wait for an old Git worker")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertNil(model.statusError)
        XCTAssertEqual(model.recentCommits.map(\.subject), ["baseline"])
    }

    func testContextChangeDuringMutationPreflightDoesNotSwitchOldRepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"],
                     ["config", "user.name", "Preflight Test"],
                     ["config", "user.email", "preflight@invalid"],
                     ["config", "commit.gpgsign", "false"],
                     ["commit", "--allow-empty", "-qm", "root"],
                     ["branch", "other"]] {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:first")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        await backend.suspendNextGitRequest()
        model.switchBranch(to: "other")
        let deadline = Date().addingTimeInterval(5)
        while await !backend.awaitingGit, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let paused = await backend.awaitingGit
        XCTAssertTrue(paused)
        model.sync(root: directory.path, backend: backend, scope: "ssh:second")
        await backend.releaseGitRequest()
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(GitCommandExecution.run(["branch", "--show-current"], in: directory.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines), "main")
    }

    func testNewEditDuringCommitPreflightStopsBeforeFirstMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Late Edit"],
                     ["config", "user.email", "edit@invalid"], ["config", "commit.gpgsign", "false"],
                     ["commit", "--allow-empty", "-qm", "first"], ["commit", "--allow-empty", "-qm", "second"]] {
            let result = GitCommandExecution.run(args, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: directory.path, backend: backend, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let target = try XCTUnwrap(model.recentCommits.last)
        let head = model.headOID
        let filePath = directory.appendingPathComponent("editing.txt")
        try Data("baseline".utf8).write(to: filePath)
        let file = FileTab(path: filePath.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        await backend.suspendNextGitRequest()
        model.actOnCommit(target, action: .checkout, target: model.actionTarget(),
                          prepare: { true }, isCurrentTarget: { !file.isDirty })
        let deadline = Date().addingTimeInterval(5)
        while await !backend.awaitingGit, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        file.text = "new edit during preflight"
        file.refreshDirtyState()
        await backend.releaseGitRequest()
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(file.text, "new edit during preflight")
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(try String(contentsOf: filePath, encoding: .utf8), "baseline")
        XCTAssertEqual(GitCommandExecution.run(["rev-parse", "HEAD"], in: directory.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines), head)
    }

    func testRecentCommitsKeepMergeParentsAndTypedReferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func git(_ arguments: [String]) throws -> String {
            let result = GitCommandExecution.run(arguments, in: directory.path, timeout: 15)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Graph Test"])
        _ = try git(["config", "user.email", "graph@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        try "root".write(to: directory.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "root"])
        let root = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-qc", "feature/nested"])
        try "side".write(to: directory.appendingPathComponent("side.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "side"])
        let side = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-q", "main"])
        try "main".write(to: directory.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "main"])
        let firstParent = try git(["rev-parse", "HEAD"])
        _ = try git(["merge", "-q", "--no-ff", "-m", "merge", "feature/nested"])
        let merge = try git(["rev-parse", "HEAD"])
        _ = try git(["branch", "release/stable", merge])
        _ = try git(["branch", "feature,hotfix", merge])
        _ = try git(["tag", "v1.0", merge])
        _ = try git(["tag", "v1,hotfix", merge])
        _ = try git(["update-ref", "refs/remotes/origin/main", merge])
        _ = try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        // A second tip that HEAD cannot reach must still appear in the graph.
        _ = try git(["switch", "-qc", "experiment/other", root])
        _ = try git(["commit", "--allow-empty", "-qm", "independent tip"])
        let extra = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-q", "main"])

        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let rows = model.recentCommits
        let top = try XCTUnwrap(rows.first { $0.hash == merge })
        XCTAssertEqual(top.parentHashes, [firstParent, side])
        XCTAssertEqual(top.files.map(\.path), ["side.txt"], "Merge files must compare with the first parent")
        XCTAssertEqual(rows.first { $0.hash == root }?.parentHashes, [])
        XCTAssertNotNil(rows.first { $0.hash == extra })
        XCTAssertEqual(
            Set(top.references),
            Set([
                .init(kind: .currentBranch, name: "main"),
                .init(kind: .localBranch, name: "release/stable"),
                .init(kind: .localBranch, name: "feature,hotfix"),
                .init(kind: .remoteBranch, name: "origin/main"),
                .init(kind: .remoteAlias, name: "origin/HEAD"),
                .init(kind: .tag, name: "v1.0"),
                .init(kind: .tag, name: "v1,hotfix"),
            ])
        )
        XCTAssertEqual(rows.first { $0.hash == side }?.references,
                       [.init(kind: .localBranch, name: "feature/nested")])
        XCTAssertEqual(rows.first { $0.hash == side }?.files.map(\.path), ["side.txt"])
    }

    func testWorktreeListParserPreservesExactPathsAndRejectsMalformedMetadata() {
        let sha1 = String(repeating: "a", count: 40)
        let sha256 = String(repeating: "b", count: 64)
        let source = "worktree /tmp/空 格\n路径\u{0}HEAD \(sha1)\u{0}branch refs/heads/topic/a\u{0}\u{0}"
            + "worktree /tmp/detached\u{0}HEAD \(sha256)\u{0}detached\u{0}\u{0}"
            + "worktree C:/Users/workspace folder\u{0}HEAD \(sha1)\u{0}branch refs/heads/windows\u{0}\u{0}"
            + "worktree /tmp/removed\u{0}HEAD \(sha1)\u{0}prunable gitdir file points to non-existent location\u{0}\u{0}"
        let locations = GitStatusModel.parseWorktreeList(source)
        XCTAssertEqual(locations?.count, 4)
        XCTAssertEqual(locations?.first?.path, "/tmp/空 格\n路径")
        XCTAssertEqual(locations?.first?.branch, "topic/a")
        XCTAssertEqual(locations?[1].path, "/tmp/detached")
        XCTAssertNil(locations?[1].branch)
        XCTAssertEqual(locations?[1].headOID, sha256)
        XCTAssertEqual(locations?.map(\.isMain), [true, false, false, false])
        XCTAssertTrue(locations?.allSatisfy { !$0.isLocked } == true)
        XCTAssertEqual(locations?[2].path, "C:/Users/workspace folder")
        XCTAssertEqual(locations?[2].branch, "windows")
        XCTAssertEqual(locations?.last?.path, "/tmp/removed")
        XCTAssertEqual(locations?.last?.isPrunable, true)
        XCTAssertNil(GitStatusModel.parseWorktreeList("worktree /tmp/bad\u{0}HEAD malformed\u{0}\u{0}"))
        XCTAssertNil(GitStatusModel.parseWorktreeList("worktree /tmp/truncated\u{0}"))
        let locked = "worktree /tmp/root\u{0}HEAD \(sha1)\u{0}branch refs/heads/main\u{0}\u{0}"
            + "worktree /tmp/locked\u{0}HEAD \(sha1)\u{0}locked automatic maintenance\u{0}\u{0}"
        XCTAssertEqual(GitStatusModel.parseWorktreeList(locked)?.map(\.isLocked), [false, true])
    }

    func testUnavailableRemoteWorktreeListRetainsLastGraphSnapshot() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-worktree-failure-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("root")
        let other = fixture.appendingPathComponent("checkout\n更新")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        func git(_ args: [String]) throws {
            let result = GitCommandExecution.run(args, in: root.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Test"])
        try git(["config", "user.email", "test@invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["commit", "--allow-empty", "-qm", "baseline"])
        try git(["worktree", "add", "-q", "-b", "feature", other.path, "HEAD"])
        try Data("other checkout untracked".utf8).write(
            to: other.appendingPathComponent("new.txt")
        )

        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: root.path, backend: backend, scope: "ssh:fixture")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.graphCommits.contains {
            $0.worktree?.entries.contains(where: { $0.path == "new.txt" }) == true
        })
        let previousHistory = model.recentCommits
        // A commit in the other checkout changes for-each-ref while main's HEAD
        // stays unchanged. Failure must not mistake invalidated refs for clean status.
        let moved = GitCommandExecution.run(
            ["commit", "--allow-empty", "-qm", "other branch advanced"],
            in: other.path, timeout: 10
        )
        XCTAssertEqual(moved.status, 0, moved.stderr)
        await backend.setWorktreeListUnavailable(true)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNotNil(model.detailError)
        XCTAssertTrue(model.canUseCurrentStatus)
        XCTAssertEqual(model.recentCommits, previousHistory)
        XCTAssertFalse(model.canUseCurrentHistory)
        XCTAssertTrue(model.graphCommits.contains {
            $0.worktree?.entries.contains(where: { $0.path == "new.txt" }) == true
        }, "Updated refs and an unavailable worktree query must retain the last known dirty state")

        await backend.setWorktreeListUnavailable(false)
        model.refresh()
        try await wait { !model.isRefreshing }
        let actual = GitCommandExecution.run(["rev-parse", "HEAD"], in: other.path)
        XCTAssertEqual(actual.status, 0)
        XCTAssertEqual(model.otherWorktrees.first?.headOID,
                       actual.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNil(model.detailError)
    }

    func testGitGraphReadsUncommittedChangesFromEachRealWorktree() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-worktree-graph-" + UUID().uuidString)
        let main = fixture.appendingPathComponent("main")
        let other = fixture.appendingPathComponent("另一个 worktree")
        let detached = fixture.appendingPathComponent("detached")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        func git(_ args: [String], at path: URL = main) throws -> String {
            let result = GitCommandExecution.run(args, in: path.path, timeout: 12)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Working Tree Test"])
        _ = try git(["config", "user.email", "worktrees@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: main.appendingPathComponent("tracked.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "base"])
        let head = try git(["rev-parse", "HEAD"])
        _ = try git(["worktree", "add", "-q", "-b", "feature/topic", other.path, "HEAD"])
        _ = try git(["worktree", "add", "-q", "--detach", detached.path, "HEAD"])

        try Data("staged\n".utf8).write(to: main.appendingPathComponent("tracked.txt"))
        _ = try git(["add", "tracked.txt"])
        try Data("unstaged\n".utf8).write(to: main.appendingPathComponent("tracked.txt"))
        try Data("other\n".utf8).write(to: other.appendingPathComponent("特殊\n目录.txt"))
        try Data("detached\n".utf8).write(to: detached.appendingPathComponent("detached.txt"))
        let model = GitStatusModel()
        model.sync(root: main.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }

        let gitMain = try git(["rev-parse", "--show-toplevel"], at: main)
        let gitOther = try git(["rev-parse", "--show-toplevel"], at: other)
        let gitDetached = try git(["rev-parse", "--show-toplevel"], at: detached)
        let trees = model.graphCommits.compactMap(\.worktree)
        XCTAssertEqual(trees.count, 3)
        XCTAssertEqual(Set(trees.map(\.path)), Set([gitMain, gitOther, gitDetached]))
        XCTAssertEqual(trees.first(where: { $0.path == gitMain })?.entries.first?.staged, "M")
        XCTAssertEqual(trees.first(where: { $0.path == gitMain })?.entries.first?.unstaged, "M")
        XCTAssertEqual(trees.first(where: { $0.path == gitOther })?.branch, "feature/topic")
        XCTAssertEqual(trees.first(where: { $0.path == gitDetached })?.branch, nil)
        XCTAssertEqual(trees.first(where: { $0.path == gitOther })?.entries.first?.path, "特殊\n目录.txt")
        XCTAssertTrue(trees.allSatisfy { $0.headOID == head })
        let headRow = try XCTUnwrap(model.graphCommits.first {
            $0.hash == head && $0.worktree == nil && $0.stash == nil
        })
        XCTAssertEqual(Set(headRow.checkedOutWorktrees.map(\.path)),
                       Set([gitMain, gitOther, gitDetached]))
        XCTAssertEqual(headRow.checkedOutWorktrees.filter(\.isMain).map(\.path), [gitMain])
        XCTAssertTrue(model.hasCurrentWorktrees)
        XCTAssertEqual(Set(model.graphCommits.map(\.id)).count, model.graphCommits.count)
        let graph = CommitGraphLayout(commits: model.graphCommits)
        XCTAssertEqual(graph.knownHeadHistory, [head])
        for (index, record) in model.graphCommits.enumerated() where record.worktree != nil {
            XCTAssertFalse(graph.rows[index].links.isEmpty, "Dirty worktree must lead to the actual HEAD")
        }

        // Independently changing another checkout cannot be inferred from main's status.
        try FileManager.default.removeItem(at: detached.appendingPathComponent("detached.txt"))
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertEqual(model.graphCommits.compactMap(\.worktree).count, 2)
        XCTAssertEqual(model.graphCommits.first(where: { $0.hash == head && $0.worktree == nil })?
            .checkedOutWorktrees.count, 3, "Clean linked worktrees must keep a badge")
        XCTAssertTrue(model.changedEntries.contains { $0.path == "tracked.txt" })
        XCTAssertEqual(try git(["status", "--porcelain", "--untracked-files=all"], at: detached), "")
    }

    func testDetachedWorktreeHistoryIncludesCleanDirtyAndSharedHeadsOnBothBackends() async throws {
        for format in ["sha1", "sha256"] {
            for remote in [false, true] {
                let fixture = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bailey-detached-history-" + UUID().uuidString)
                let main = fixture.appendingPathComponent("main")
                let detached = fixture.appendingPathComponent("游离 worktree\n目录")
                let shared = fixture.appendingPathComponent("shared")
                let branched = fixture.appendingPathComponent("branched")
                try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: fixture) }
                func git(_ args: [String], at path: URL = main) throws -> String {
                    let result = GitCommandExecution.run(args, in: path.path, timeout: 12)
                    XCTAssertEqual(result.status, 0, result.stderr)
                    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                _ = try git(["init", "-q", "--object-format=\(format)", "-b", "main"])
                _ = try git(["config", "user.name", "Worktree History"])
                _ = try git(["config", "user.email", "history@invalid"])
                _ = try git(["config", "commit.gpgsign", "false"])
                _ = try git(["commit", "--allow-empty", "-qm", "base"])
                let base = try git(["rev-parse", "HEAD"])
                _ = try git(["worktree", "add", "-q", "--detach", detached.path, base])
                try Data("committed\n".utf8).write(to: detached.appendingPathComponent("committed.txt"))
                _ = try git(["add", "."], at: detached)
                _ = try git(["commit", "-qm", "detached first"], at: detached)
                let first = try git(["rev-parse", "HEAD"], at: detached)
                _ = try git(["commit", "--allow-empty", "-qm", "detached second"], at: detached)
                let tip = try git(["rev-parse", "HEAD"], at: detached)
                XCTAssertEqual(try git(["for-each-ref", "--contains", tip]), "")
                _ = try git(["worktree", "add", "-q", "--detach", shared.path, tip])
                _ = try git(["worktree", "add", "-q", "-b", "feature", branched.path, base])
                _ = try git(["commit", "--allow-empty", "-qm", "feature commit"], at: branched)
                let feature = try git(["rev-parse", "HEAD"], at: branched)
                try Data("stash only\n".utf8).write(to: main.appendingPathComponent("stash.txt"))
                _ = try git(["stash", "push", "-qu", "-m", "hidden internal commits"])
                let stash = try git(["rev-parse", "refs/stash"])
                let stashIndex = try git(["rev-parse", "refs/stash^2"])
                let backend: any WorkspaceBackend = remote
                    ? DiscardRemoteWorkspaceFixture() : LocalWorkspaceBackend.shared
                let model = GitStatusModel()
                model.sync(root: main.path, backend: backend, scope: remote ? "ssh:fixture" : "local")
                try await wait { model.hasResolvedStatus && !model.isRefreshing }
                XCTAssertNil(model.detailError)
                XCTAssertEqual(Set(model.recentCommits.map(\.hash)), Set([base, first, tip, feature]))
                XCTAssertEqual(model.recentCommits.count, 4)
                XCTAssertFalse(model.recentCommits.contains { $0.hash == stash || $0.hash == stashIndex })
                let committed = try XCTUnwrap(model.recentCommits.first { $0.hash == first })
                XCTAssertEqual(committed.parentHashes, [base])
                XCTAssertEqual(committed.files.map(\.path), ["committed.txt"])
                let tipRow = try XCTUnwrap(model.graphCommits.first { $0.hash == tip })
                XCTAssertEqual(tipRow.parentHashes, [first])
                XCTAssertEqual(tipRow.checkedOutWorktrees.count, 2)
                XCTAssertTrue(model.graphCommits.compactMap(\.worktree).isEmpty)
                XCTAssertEqual(try git(["show", "\(first):committed.txt"]), "committed")

                try Data("dirty\n".utf8).write(to: detached.appendingPathComponent("dirty.txt"))
                model.refresh()
                try await wait { !model.isRefreshing }
                let rows = model.graphCommits
                let dirtyIndex = try XCTUnwrap(rows.firstIndex { $0.worktree?.headOID == tip })
                let headIndex = try XCTUnwrap(rows.firstIndex { $0.hash == tip })
                let layout = CommitGraphLayout(commits: rows)
                XCTAssertFalse(layout.rows[dirtyIndex].links.isEmpty)
                XCTAssertEqual(layout.rows[dirtyIndex].node, layout.rows[headIndex].node)
                XCTAssertEqual(model.recentCommits.count, 4)

                _ = try git(["commit", "--allow-empty", "-qm", "external worktree commit"], at: shared)
                let advanced = try git(["rev-parse", "HEAD"], at: shared)
                if remote { model.refresh() }
                try await wait {
                    !model.isRefreshing && model.recentCommits.contains { $0.hash == advanced }
                }
                XCTAssertEqual(model.graphCommits.first { $0.hash == advanced }?.checkedOutWorktrees.count, 1)
                XCTAssertEqual(try git(["rev-parse", "HEAD"]), base)

                model.sync(root: detached.path, backend: backend, scope: remote ? "ssh:fixture" : "local")
                try await wait { model.hasResolvedStatus && !model.isRefreshing }
                XCTAssertEqual(model.headOID, tip)
                XCTAssertEqual(Set(model.recentCommits.map(\.hash)), Set([base, first, tip, feature, advanced]))
                XCTAssertEqual(model.graphCommits.first { $0.hash == tip }?.checkedOutWorktrees.count, 1)
                XCTAssertEqual(try git(["rev-parse", "HEAD"]), base)
            }
        }
    }

    func testDetachedWorktreeHistoryPaginationChecksHeadsAndRetainsFailedPages() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-detached-pages-" + UUID().uuidString)
        let main = fixture.appendingPathComponent("main")
        let detached = fixture.appendingPathComponent("detached")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        func git(_ args: [String], at path: URL = main) throws -> String {
            let result = GitCommandExecution.run(args, in: path.path, timeout: 12)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Worktree Pages"])
        _ = try git(["config", "user.email", "pages@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["commit", "--allow-empty", "-qm", "base"])
        let base = try git(["rev-parse", "HEAD"])
        _ = try git(["worktree", "add", "-q", "--detach", detached.path, base])
        for number in 0..<64 {
            _ = try git(["commit", "--allow-empty", "-qm", "detached \(number)"], at: detached)
        }
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: main.path, backend: backend, scope: "ssh:pages")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.recentCommits.count, 30)
        XCTAssertTrue(model.hasMoreRecentCommits)
        let previous = model.recentCommits
        await backend.setWorktreeListUnavailable(true)
        XCTAssertTrue(model.loadMoreCommits())
        try await wait { !model.isRefreshing && !model.isLoadingMoreCommits }
        XCTAssertNotNil(model.detailError)
        XCTAssertEqual(model.recentCommits, previous)
        await backend.setWorktreeListUnavailable(false)
        model.refresh(kind: .historyOnly)
        try await wait { !model.isRefreshing }
        XCTAssertNil(model.detailError)
        XCTAssertEqual(model.recentCommits.count, 60)

        _ = try git(["commit", "--allow-empty", "-qm", "advanced without changing refs"], at: detached)
        let tip = try git(["rev-parse", "HEAD"], at: detached)
        let before = await backend.commands.count
        XCTAssertTrue(model.loadMoreCommits())
        try await wait { !model.isRefreshing && !model.isLoadingMoreCommits }
        XCTAssertEqual(model.recentCommits.count, 66)
        XCTAssertFalse(model.hasMoreRecentCommits)
        XCTAssertTrue(model.worktreeLocations.contains { $0.headOID == tip })
        XCTAssertEqual(model.graphCommits.first { $0.hash == tip }?.checkedOutWorktrees.count, 1)
        XCTAssertTrue(model.canUseCurrentHistory)
        let queries = Array((await backend.commands).dropFirst(before)).joined(separator: "\n")
        XCTAssertTrue(queries.contains("git 'stash' 'list' "), "A changed worktree HEAD requires a full snapshot")
        XCTAssertEqual(model.headOID, base)

        _ = try git(["worktree", "remove", detached.path])
        model.refresh(kind: .historyOnly)
        try await wait { !model.isRefreshing }
        XCTAssertEqual(model.recentCommits.map(\.hash), [base])
        XCTAssertEqual(model.worktreeLocations.count, 1)
        XCTAssertFalse(model.hasMoreRecentCommits)
    }

    func testUnbornCurrentWorktreeStillShowsOtherWorktreeHistoryAndPreservesLogFailures() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-unborn-worktree-" + UUID().uuidString)
        let main = fixture.appendingPathComponent("main")
        let detached = fixture.appendingPathComponent("detached")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        func git(_ args: [String], at path: URL = main) throws -> String {
            let result = GitCommandExecution.run(args, in: path.path, timeout: 12)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Unborn Worktree"])
        _ = try git(["config", "user.email", "unborn@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["commit", "--allow-empty", "-qm", "base"])
        let base = try git(["rev-parse", "HEAD"])
        _ = try git(["worktree", "add", "-q", "--detach", detached.path, base])
        _ = try git(["commit", "--allow-empty", "-qm", "independent"], at: detached)
        let tip = try git(["rev-parse", "HEAD"], at: detached)
        _ = try git(["switch", "--orphan", "empty"])
        _ = try git(["branch", "-D", "main"])
        XCTAssertEqual(try git(["for-each-ref"]), "")
        let backend = DiscardRemoteWorkspaceFixture()
        let model = GitStatusModel()
        model.sync(root: main.path, backend: backend, scope: "ssh:unborn")
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertFalse(model.hasHead)
        XCTAssertNil(model.detailError)
        XCTAssertEqual(Set(model.recentCommits.map(\.hash)), Set([base, tip]))

        await backend.setHistoryLogUnavailable(true)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNotNil(model.detailError)
        XCTAssertEqual(Set(model.recentCommits.map(\.hash)), Set([base, tip]))
        XCTAssertFalse(model.canUseCurrentHistory)
        await backend.setHistoryLogUnavailable(false)
        model.refresh()
        try await wait { !model.isRefreshing }
        XCTAssertNil(model.detailError)
        XCTAssertTrue(model.canUseCurrentHistory)
        XCTAssertEqual(model.graphCommits.first { $0.hash == tip }?.checkedOutWorktrees.count, 1)
    }

    func testWorktreeCreateRemoveKeepsBranchAndRefusesDirtyLockedAndMain() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-worktree-actions-" + UUID().uuidString)
        let main = fixture.appendingPathComponent("main")
        let topic = fixture.appendingPathComponent("topic 空格😀")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        @discardableResult
        func git(_ args: [String], at path: URL = main) throws -> String {
            let result = GitCommandExecution.run(args, in: path.path, timeout: 15)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Worktree Test"])
        _ = try git(["config", "user.email", "worktree@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["commit", "--allow-empty", "-qm", "base"])
        _ = try git(["branch", "topic/review"])
        let oid = try git(["rev-parse", "refs/heads/topic/review"])
        let model = GitStatusModel()
        model.sync(root: main.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.canCreateWorktree(for: "topic/review"))

        model.createWorktree(for: "topic/review", at: topic.path,
                             expectedOID: oid, target: model.actionTarget())
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"], at: topic), "refs/heads/topic/review")
        let canonicalTopic = try git(["rev-parse", "--show-toplevel"], at: topic)
        XCTAssertTrue(model.worktreeLocations.contains { $0.path == canonicalTopic })
        XCTAssertFalse(model.canCreateWorktree(for: "topic/review"))
        XCTAssertEqual(model.graphCommits.compactMap(\.worktree).count, 0,
                       "A clean checkout must not create an Uncommitted Changes node")
        XCTAssertEqual(model.graphCommits.first(where: { $0.hash == oid && $0.worktree == nil })?
                       .checkedOutWorktrees.count, 2)

        model.createWorktree(for: "topic/review", at: fixture.appendingPathComponent("duplicate").path,
                             expectedOID: oid, target: model.actionTarget())
        XCTAssertNotNil(model.lastError)
        let selected = try XCTUnwrap(model.worktreeLocations.first { $0.path == canonicalTopic })
        let primary = try XCTUnwrap(model.worktreeLocations.first { $0.isMain })
        model.removeWorktree(primary, target: model.actionTarget())
        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: main.path))

        try Data("important".utf8).write(to: topic.appendingPathComponent("untracked.txt"))
        model.removeWorktree(selected, target: model.actionTarget())
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(try String(contentsOf: topic.appendingPathComponent("untracked.txt"),
                                  encoding: .utf8), "important")
        try FileManager.default.removeItem(at: topic.appendingPathComponent("untracked.txt"))
        _ = try git(["worktree", "lock", topic.path])
        model.refresh()
        try await wait { !model.isRefreshing }
        let locked = try XCTUnwrap(model.worktreeLocations.first { $0.path == canonicalTopic })
        XCTAssertTrue(locked.isLocked)
        model.removeWorktree(locked, target: model.actionTarget())
        XCTAssertNotNil(model.lastError)
        _ = try git(["worktree", "unlock", topic.path])
        model.refresh()
        try await wait { !model.isRefreshing }
        let clean = try XCTUnwrap(model.worktreeLocations.first { $0.path == canonicalTopic })
        model.removeWorktree(clean, target: model.actionTarget())
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: topic.path))
        XCTAssertEqual(try git(["rev-parse", "refs/heads/topic/review"]), oid,
                       "Removing a Worktree must never remove its branch")
    }

    func testWorktreeProtectionUsesEachContentsMachineInsteadOfItsProjectsMachine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-混合-\(UUID())")
        let tree = root.appendingPathComponent("checkout")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: tree)
        try Data("keep".utf8).write(to: tree.appendingPathComponent("file.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        for projectScope in ["local", "ssh:alpha"] {
            for contentScope in ["local", "ssh:alpha", "ssh:beta"] {
                for kind in ["file", "diff"] {
                    let application = WorkspaceApplication()
                    let window = application.makeWindow()
                    defer { window.windowClosed() }
                    let project = Project(fallbackName: "Mixed", workspaceConfiguration: .standard)
                    project.customDirectory = root.appendingPathComponent("elsewhere").path
                    project.sshHost = projectScope == "local" ? nil : "alpha"
                    let identity = contentScope == "local" ? nil : contentScope
                    let content: PaneContent
                    switch kind {
                    case "file":
                        content = .file(FileTab(path: tree.appendingPathComponent("file.txt").path,
                            backend: LocalWorkspaceBackend.shared, workspaceIdentity: identity))
                    default:
                        content = .diff(DiffTab(repoRoot: tree.path, path: "file.txt", source: .worktree,
                            untracked: true, origPath: nil, backend: LocalWorkspaceBackend.shared,
                            workspaceIdentity: identity))
                    }
                    project.tabs = [PaneTab(content: content)]
                    window.projects = [project]
                    for scope in ["local", "ssh:alpha", "ssh:beta"] {
                        XCTAssertEqual(application.isWorktreeInUse(path: tree.path, scope: scope),
                                       scope == contentScope, "\(projectScope), \(contentScope), \(kind), \(scope)")
                    }
                    XCTAssertFalse(application.isWorktreeInUse(path: tree.path + "-other", scope: contentScope))
                    XCTAssertEqual(application.isWorktreeInUse(path: alias.path, scope: contentScope),
                                   contentScope == "local")
                }
            }
        }
    }

    func testFixedSSHTerminalWorktreeProtectionKeepsItsProjectsScope() throws {
        let application = WorkspaceApplication()
        let window = application.makeWindow()
        defer { window.windowClosed() }
        let project = Project(fallbackName: "Pinned SSH", workspaceConfiguration: .standard)
        project.sshHost = "fixture-alias"
        project.customDirectory = "/fixture/original"
        window.projects = [project]
        let session = project.newSession(launchCommand: "exec /bin/sh -i")
        session.workingDirectory = "/fixture/other-worktree/subdirectory"
        XCTAssertFalse(session.acceptsLocalFileDrop)
        XCTAssertNil(session.workspaceIdentity)
        XCTAssertEqual(project.panelContext?.scope, "ssh:fixture-alias")
        for connected in [false, true] {
            if connected {
                let connection = RemoteConnection(user: "fixture", host: "fixture.invalid", port: 2222,
                    controlSocket: URL(fileURLWithPath: "/tmp/bailey-unused-\(UUID())"), sshPID: 0)
                connection.workingDirectory = session.workingDirectory
                connection.markConnected()
                session.location = .remote(connection)
                XCTAssertNotEqual(session.workspaceIdentity, project.panelContext?.scope)
            }
            XCTAssertTrue(application.isWorktreeInUse(path: "/fixture/other-worktree", scope: "ssh:fixture-alias"))
            XCTAssertFalse(application.isWorktreeInUse(path: "/fixture/other-worktree", scope: "local"))
            XCTAssertFalse(application.isWorktreeInUse(path: "/fixture/other-worktree", scope: "ssh:other"))
            XCTAssertFalse(application.isWorktreeInUse(path: "/fixture/other-worktree-copy", scope: "ssh:fixture-alias"))
        }
    }

    func testWorktreeInUseProtectsOpenProjectAndKeepsMachineAndSiblingPathsSeparate() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-worktree-in-use-" + UUID().uuidString)
        let tree = fixture.appendingPathComponent("checkout")
        let sibling = fixture.appendingPathComponent("checkout-other")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([tree])
        XCTAssertTrue(self.workspaceApplication.isWorktreeInUse(path: tree.path, scope: "local"))
        XCTAssertTrue(self.workspaceApplication.isWorktreeInUse(
            path: tree.resolvingSymlinksInPath().path, scope: "local"
        ), "Equivalent /var and /private/var paths must identify the same checkout")
        XCTAssertFalse(self.workspaceApplication.isWorktreeInUse(path: sibling.path, scope: "local"))
        XCTAssertFalse(self.workspaceApplication.isWorktreeInUse(path: tree.path, scope: "ssh:windows"))

        manager.selectedProject?.sshHost = "windows"
        manager.selectedProject?.customDirectory = "/d/Github/bailey-test-worktree"
        XCTAssertTrue(self.workspaceApplication.isWorktreeInUse(
            path: "/d/Github/bailey-test-worktree", scope: "ssh:windows"
        ))
        XCTAssertFalse(self.workspaceApplication.isWorktreeInUse(
            path: "/d/Github/bailey-test-worktree", scope: "local"
        ))
        XCTAssertFalse(self.workspaceApplication.isWorktreeInUse(
            path: "/d/Github/bailey-test-worktree-copy", scope: "ssh:windows"
        ))
    }

    func testWorktreeRemovalRejectsStaleHeadWithoutDeletingFiles() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-worktree-stale-" + UUID().uuidString)
        let main = fixture.appendingPathComponent("main")
        let linked = fixture.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        @discardableResult
        func git(_ args: [String], at path: URL = main) -> String {
            let run = GitCommandExecution.run(args, in: path.path, timeout: 15)
            XCTAssertEqual(run.status, 0, run.stderr)
            return run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "Worktree Test"])
        git(["config", "user.email", "worktree@invalid"])
        git(["config", "commit.gpgsign", "false"])
        git(["commit", "--allow-empty", "-qm", "base"])
        git(["worktree", "add", "-q", "-b", "topic", linked.path])
        let model = GitStatusModel()
        model.sync(root: main.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let actualPath = git(["rev-parse", "--show-toplevel"], at: linked)
        let before = try XCTUnwrap(model.worktreeLocations.first { $0.path == actualPath })
        git(["commit", "--allow-empty", "-qm", "changed externally"], at: linked)
        model.removeWorktree(before, target: model.actionTarget())
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNotNil(model.lastError, "The original selection must not remove a checkout whose HEAD moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
    }

    func testWorktreeFileActionsReadIndependentIndexAndWorkingBytes() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-diff-worktree-" + UUID().uuidString)
        let main = fixture.appendingPathComponent("main")
        let other = fixture.appendingPathComponent("feature workspace")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        func git(_ args: [String], in directory: URL = main) throws -> String {
            let result = GitCommandExecution.run(args, in: directory.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Diff Worktree Test"])
        _ = try git(["config", "user.email", "worktree-diff@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        try Data("baseline\n".utf8).write(to: main.appendingPathComponent("tracked.txt"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-qm", "baseline"])
        _ = try git(["worktree", "add", "-q", "-b", "feature", other.path, "HEAD"])

        try Data("mac main content\n".utf8).write(to: main.appendingPathComponent("tracked.txt"))
        try Data("other staged\n".utf8).write(to: other.appendingPathComponent("tracked.txt"))
        _ = try git(["add", "tracked.txt"], in: other)
        try Data("other latest content\n".utf8).write(to: other.appendingPathComponent("tracked.txt"))

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([main])
        let project = try XCTUnwrap(manager.selectedProject)
        let otherRoot = try git(["rev-parse", "--show-toplevel"], in: other)

        manager.openDiff(
            repoRoot: otherRoot, path: "tracked.txt",
            staged: true, untracked: false, origPath: nil
        )
        guard case .diff(let staged)? = project.focusedContent else {
            return XCTFail("Expected staged DiffTab")
        }
        try await wait { staged.hasLoadedContent || staged.error != nil }
        XCTAssertNil(staged.error)
        XCTAssertEqual(staged.oldContent, "baseline\n")
        XCTAssertEqual(staged.newContent, "other staged\n")
        XCTAssertEqual(staged.repoRoot, otherRoot)
        XCTAssertEqual(staged.source, .staged)

        manager.openDiff(
            repoRoot: otherRoot, path: "tracked.txt",
            staged: false, untracked: false, origPath: nil
        )
        guard case .diff(let unstaged)? = project.focusedContent else {
            return XCTFail("Expected worktree DiffTab")
        }
        try await wait { unstaged.hasLoadedContent || unstaged.error != nil }
        XCTAssertNil(unstaged.error)
        XCTAssertEqual(unstaged.oldContent, "other staged\n")
        XCTAssertEqual(unstaged.newContent, "other latest content\n")
        XCTAssertEqual(unstaged.repoRoot, otherRoot)
        XCTAssertEqual(unstaged.source, .worktree)

        // Neither opening another checkout's diff nor switching tabs may
        // rewrite the branch's index or the Mac checkout's working files.
        XCTAssertEqual(
            try String(contentsOf: main.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "mac main content\n"
        )
        XCTAssertEqual(
            try git(["show", ":tracked.txt"], in: other),
            "other staged"
        )
    }

    func testIndexedRenameAndCopyDiffPathsPreserveBothCorrectStages() {
        for indexStatus: Character in ["R", "C"] {
            let entry = GitStatusModel.Entry(
                path: "new name.txt", staged: indexStatus, unstaged: "M",
                origPath: "old name.txt"
            )
            XCTAssertEqual(entry.diffOriginalPath(staged: true), "old name.txt")
            XCTAssertNil(entry.diffOriginalPath(staged: false))
        }
        let unstagedRename = GitStatusModel.Entry(
            path: "destination", staged: ".", unstaged: "R", origPath: "original"
        )
        XCTAssertEqual(unstagedRename.diffOriginalPath(staged: false), "original")
        let plain = GitStatusModel.Entry(path: "plain.txt", staged: "M", unstaged: "M")
        XCTAssertNil(plain.diffOriginalPath(staged: true))
        XCTAssertNil(plain.diffOriginalPath(staged: false))
    }

    func testStagedRenameInOtherWorktreeUsesDestinationIndexForUnstagedDiff() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-graph-rename-" + UUID().uuidString)
        let main = fixture.appendingPathComponent("main")
        let other = fixture.appendingPathComponent("other checkout")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        func git(_ arguments: [String], in directory: URL = main) throws -> String {
            let run = GitCommandExecution.run(arguments, in: directory.path, timeout: 12)
            XCTAssertEqual(run.status, 0, run.stderr)
            return run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Git Graph"])
        try git(["config", "user.email", "git-graph@invalid"])
        try git(["config", "commit.gpgsign", "false"])
        let baseline = "alpha\nbeta\ngamma\ndelta\nepsilon\n"
        try Data(baseline.utf8).write(to: main.appendingPathComponent("before.txt"))
        try git(["add", "before.txt"])
        try git(["commit", "-qm", "base"])
        try git(["worktree", "add", "-q", "-b", "feature", other.path, "HEAD"])
        try git(["mv", "before.txt", "after.txt"], in: other)
        let modified = baseline + "uncommitted addition\n"
        try Data(modified.utf8).write(to: other.appendingPathComponent("after.txt"))

        let model = GitStatusModel()
        model.sync(root: main.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let entry = try XCTUnwrap(
            model.graphCommits.compactMap(\.worktree)
                .first(where: { !$0.isCurrent })?.entries.first
        )
        XCTAssertEqual(entry.staged, "R")
        XCTAssertEqual(entry.unstaged, "M")
        XCTAssertEqual(entry.origPath, "before.txt")
        XCTAssertEqual(entry.diffOriginalPath(staged: true), "before.txt")
        XCTAssertNil(entry.diffOriginalPath(staged: false),
                     "The working tree must compare the renamed destination with its own index")
        let otherRoot = try git(["rev-parse", "--show-toplevel"], in: other)
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([main])
        let project = try XCTUnwrap(manager.selectedProject)

        manager.openDiff(repoRoot: otherRoot, path: entry.path,
                         staged: true, untracked: false,
                         origPath: entry.diffOriginalPath(staged: true))
        guard case .diff(let stagedTab)? = project.focusedContent else {
            return XCTFail("Expected staged diff")
        }
        try await wait { stagedTab.hasLoadedContent || stagedTab.error != nil }
        XCTAssertNil(stagedTab.error)
        XCTAssertEqual(stagedTab.oldContent, baseline)
        XCTAssertEqual(stagedTab.newContent, baseline)

        manager.openDiff(repoRoot: otherRoot, path: entry.path,
                         staged: false, untracked: false,
                         origPath: entry.diffOriginalPath(staged: false))
        guard case .diff(let workingTab)? = project.focusedContent else {
            return XCTFail("Expected working tree diff")
        }
        try await wait { workingTab.hasLoadedContent || workingTab.error != nil }
        XCTAssertNil(workingTab.error)
        XCTAssertEqual(workingTab.oldContent, baseline)
        XCTAssertEqual(workingTab.newContent, modified)
        XCTAssertEqual(try git(["show", ":after.txt"], in: other), baseline.trimmingCharacters(in: .newlines))
        XCTAssertEqual(try String(contentsOf: main.appendingPathComponent("before.txt"), encoding: .utf8), baseline)
    }

    func testUnbornRepositoryWithUntrackedFilesHasUncommittedGraphNode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-unborn-graph-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(GitCommandExecution.run(["init", "-q", "-b", "main"],
                       in: root.path).status, 0)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("尚未跟踪.txt"))
        let model = GitStatusModel()
        model.sync(root: root.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertTrue(model.isRepo)
        XCTAssertFalse(model.hasHead)
        XCTAssertTrue(model.recentCommits.isEmpty)
        XCTAssertEqual(model.graphCommits.count, 1)
        XCTAssertEqual(model.graphCommits[0].worktree?.entries.first?.path, "尚未跟踪.txt")
        XCTAssertTrue(CommitGraphLayout(commits: model.graphCommits).rows[0].links.isEmpty)
    }

    func testGitGraphParsesRealSHA256MergeAndUnicodeRemoteDecorations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-graph-sha256-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: directory.path, timeout: 15)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "--object-format=sha256", "-b", "main"])
        _ = try git(["config", "user.name", "Graph SHA256 Test"])
        _ = try git(["config", "user.email", "sha256@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["commit", "--allow-empty", "-qm", "root"])
        _ = try git(["switch", "-qc", "修复/topic,β"])
        _ = try git(["commit", "--allow-empty", "-qm", "side"])
        let side = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "-q", "main"])
        _ = try git(["commit", "--allow-empty", "-qm", "main"])
        let main = try git(["rev-parse", "HEAD"])
        _ = try git(["merge", "--no-ff", "-qm", "merge", "修复/topic,β"])
        let head = try git(["rev-parse", "HEAD"])
        XCTAssertEqual(head.count, 64)
        _ = try git(["tag", "版本,β"])
        _ = try git(["remote", "add", "origin", directory.path])
        _ = try git(["remote", "add", "upstream", directory.path])
        _ = try git(["update-ref", "refs/remotes/origin/main", head])
        _ = try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        _ = try git(["symbolic-ref", "refs/remotes/origin/ALIAS", "refs/remotes/origin/main"])
        _ = try git(["update-ref", "refs/remotes/upstream/HEAD", head])

        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let commit = try XCTUnwrap(model.recentCommits.first { $0.hash == head })
        XCTAssertEqual(commit.hash.count, 64)
        XCTAssertEqual(commit.parentHashes, [main, side])
        XCTAssertEqual(Set(commit.references), Set([
            .init(kind: .currentBranch, name: "main"),
            .init(kind: .tag, name: "版本,β"),
            .init(kind: .remoteBranch, name: "origin/main"),
            .init(kind: .remoteBranch, name: "upstream/HEAD"),
            .init(kind: .remoteAlias, name: "origin/HEAD"),
            .init(kind: .remoteAlias, name: "origin/ALIAS"),
        ]))
        XCTAssertEqual(
            model.recentCommits.first { $0.hash == side }?.references,
            [.init(kind: .localBranch, name: "修复/topic,β")]
        )
        XCTAssertEqual(CommitGraphLayout(commits: model.graphCommits).knownHeadHistory.count,
                       4, "Both parents and the root must remain reachable from HEAD")
    }

    func testGitGraphUsesCommitDateOrderWithoutBreakingMergeParents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-git-order-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: directory.path, timeout: 15)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func datedGit(_ args: [String], date: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + args
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_AUTHOR_DATE"] = date
            environment["GIT_COMMITTER_DATE"] = date
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Graph Date Order"])
        _ = try git(["config", "user.email", "graph@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        try datedGit(["commit", "--allow-empty", "-qm", "root"], date: "2026-10-05T00:00:00+0000")
        let root = try git(["rev-parse", "HEAD"])
        for (subject, date) in [
            ("main1", "2026-10-07T11:26:00+0000"),
            ("main2", "2026-10-07T12:02:00+0000"),
            ("main3", "2026-10-07T12:15:00+0000"),
        ] {
            try datedGit(["commit", "--allow-empty", "-qm", subject], date: date)
        }
        _ = try git(["switch", "-qc", "side", root])
        for (subject, date) in [
            ("side1", "2026-10-07T19:08:00+0000"),
            ("side2", "2026-10-07T19:24:00+0000"),
        ] {
            try datedGit(["commit", "--allow-empty", "-qm", subject], date: date)
        }
        try datedGit(["merge", "-q", "--no-ff", "-m", "merged", "main"],
                     date: "2026-10-08T14:20:00+0000")

        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.recentCommits.map(\.subject),
                       ["merged", "side2", "side1", "main3", "main2", "main1", "root"],
                       "Git Graph must interleave branches by commit date, not group them topologically")
        let indexByHash = Dictionary(uniqueKeysWithValues: model.recentCommits.enumerated()
            .map { ($0.element.hash, $0.offset) })
        for (index, commit) in model.recentCommits.enumerated() {
            for parent in commit.parentHashes {
                XCTAssertGreaterThan(indexByHash[parent] ?? -1, index,
                                     "Git Graph must still place every child above its parent")
            }
        }
    }

    func testHistoricalBranchMustPointAtSelectedCommitWithoutSwitchingHEAD() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: directory.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "History Test"])
        _ = try git(["config", "user.email", "history@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["commit", "--allow-empty", "-qm", "first"])
        let selected = try git(["rev-parse", "HEAD"])
        _ = try git(["commit", "--allow-empty", "-qm", "second"])
        let head = try git(["rev-parse", "HEAD"])

        let model = GitStatusModel()
        model.sync(root: directory.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let target = try XCTUnwrap(model.recentCommits.first { $0.hash == selected })
        let expectedRepository = model.repoRoot
        model.createBranch(named: "history/first", at: selected,
            checkout: false, replacing: nil, target: model.actionTarget())
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/history/first"]), selected)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try git(["branch", "--show-current"]), "main")
        XCTAssertTrue(model.recentCommits.first { $0.hash == selected }?.references.contains {
            $0.kind == .localBranch && $0.name == "history/first"
        } == true)

        model.createTag(named: "v1-local", at: selected, type: .lightweight,
                        message: "", replacing: nil, target: model.actionTarget())
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(try git(["rev-parse", "refs/tags/v1-local"]), selected)
        XCTAssertTrue(model.recentCommits.first { $0.hash == selected }?.references.contains {
            $0.kind == .tag && $0.name == "v1-local"
        } == true)

        model.createBranch(named: "history/first", at: selected,
            checkout: false, replacing: nil, target: model.actionTarget())
        try await wait { !model.isBusy && !model.isRefreshing }
        XCTAssertNotNil(model.lastError, "Duplicate branch must fail without force")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/history/first"]), selected)

        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        func otherGit(_ args: [String]) -> Int32 {
            GitCommandExecution.run(args, in: other.path, timeout: 10).status
        }
        XCTAssertEqual(otherGit(["init", "-q", "-b", "other"]), 0)
        let before = model.operation
        model.sync(root: other.path)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        model.createTag(named: "should-not-exist", at: selected, type: .lightweight,
                        message: "", replacing: nil, target: model.actionTarget())
        XCTAssertNotNil(model.lastError)
        XCTAssertNotEqual(model.operation, before)
        XCTAssertNotEqual(otherGit(["show-ref", "--verify", "--quiet",
                                    "refs/tags/should-not-exist"]), 0)
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
