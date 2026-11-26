import AppKit
import XCTest
@testable import Bailey

@MainActor
final class GitGraphPresentationTests: XCTestCase {
    private typealias Commit = GitStatusModel.RecentCommit
    private typealias Key = RecentCommitsView.GraphDisplayKey
    private typealias Cache = RecentCommitsView.GraphDisplayCache

    private func commit(_ hash: String, parents: [String] = []) -> Commit {
        .init(hash: hash, shortHash: hash, subject: hash, author: "Test",
              date: .distantPast, parentHashes: parents, references: [])
    }

    private func key(
        _ commits: [Commit], scope: String = "local", repository: String = "/repo",
        expanded: Set<String> = []
    ) -> Key {
        .init(scope: scope, repository: repository, commits: commits,
              historicalFiles: [:], stashFiles: [:], expanded: expanded, collapsed: [], mode: .tree)
    }

    private func prepare(_ key: Key, previous: Cache = Cache()) async throws -> Cache {
        let prepared = await Cache.prepare(key, previous: previous)
        return try XCTUnwrap(prepared)
    }

    func testGraphKeepsCompleteRenderedSnapshotUntilSameRepositoryUpdateIsReady() async throws {
        let commits = [commit("head", parents: ["base"]), commit("base")]
        let initial = key(commits)
        let first = try await prepare(initial)
        let firstPresentation = try XCTUnwrap(first.presentation(for: initial))
        let firstRun = try XCTUnwrap(firstPresentation.display.runs.first).id
        let dirty = GitStatusModel.WorktreeChanges(
            path: "/repo", branch: "main", headOID: "head",
            entries: [.init(path: "new.txt", staged: ".", unstaged: "?")], isCurrent: true
        )
        let dirtyCommits = GitStatusModel.graphCommits(commits, stashes: [], worktrees: [dirty])
        let changed = key(dirtyCommits)
        XCTAssertFalse(first.isPrepared(for: changed))
        let pending = first.presentation(for: changed)
        XCTAssertNotNil(pending, "A worktree change must not replace the whole graph with a spinner")
        XCTAssertEqual(pending?.key.commits, commits)
        XCTAssertEqual(pending?.display.navigation.map(\.id), firstPresentation.display.navigation.map(\.id))

        let second = try await prepare(changed, previous: first)
        let updated = try XCTUnwrap(second.presentation(for: changed))
        XCTAssertEqual(updated.key.commits, dirtyCommits)
        XCTAssertEqual(updated.display.navigation.map { updated.key.commits[$0.commitIndex].id },
                       dirtyCommits.map(\.id))
        XCTAssertEqual(updated.display.runs.first?.id, firstRun,
                       "Adding a worktree node must not remount all existing commit rows")

        let rewritten = key([commit("new-head", parents: ["base"]), commit("base")])
        XCTAssertEqual(second.presentation(for: rewritten)?.key.commits, dirtyCommits)
        let third = try await prepare(rewritten, previous: second)
        let final = try XCTUnwrap(third.presentation(for: rewritten))
        XCTAssertEqual(final.key.commits, rewritten.commits)
        XCTAssertEqual(final.display.navigation.map { final.key.commits[$0.commitIndex].id },
                       rewritten.commits.map(\.id))
        XCTAssertEqual(final.display.runs.first?.id, firstRun)
        XCTAssertNil(third.presentation(for: key(commits, scope: "ssh:other")))
        XCTAssertNil(third.presentation(for: key(commits, repository: "/other")))
    }

    func testGraphRetainsExistingRunWhenPrependingOrAppendingHistory() async throws {
        let initial = key([commit("head", parents: ["base"]), commit("base")])
        let first = try await prepare(initial)
        let firstID = try XCTUnwrap(first.presentation(for: initial)?.display.runs.first?.id)
        let added = key([commit("new", parents: ["head"])] + initial.commits)
        let second = try await prepare(added, previous: first)
        XCTAssertEqual(second.presentation(for: added)?.display.runs.first?.id, firstID)
        let paged = key(added.commits + [commit("older")])
        let third = try await prepare(paged, previous: second)
        XCTAssertEqual(third.presentation(for: paged)?.display.runs.first?.id, firstID)
    }

    func testPointerSelectionRejectsUnrelatedKeyboardAndWindowEvents() throws {
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer { window.close(); other.close() }
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        func click(_ target: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
                modifierFlags: [.shift, .command], timestamp: 0, windowNumber: target.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        }
        XCTAssertTrue(TreePointerSelection.modifiers(event: key, window: window).isEmpty)
        XCTAssertTrue(TreePointerSelection.modifiers(event: try click(other), window: window).isEmpty)
        XCTAssertTrue(TreePointerSelection.modifiers(event: nil, window: window).isEmpty)
        XCTAssertEqual(TreePointerSelection.modifiers(event: try click(window), window: window), [.shift, .command])
    }

}
