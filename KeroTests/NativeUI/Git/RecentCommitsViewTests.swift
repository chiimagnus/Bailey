import AppKit
import Observation
import SwiftUI
import XCTest
@testable import kero

@MainActor
@Observable
private final class GraphSelection {
    var expanded: Set<String> = []
    var folders: Set<String> = []
}

@MainActor
final class RecentCommitsViewTests: XCTestCase {
    private func settle() {
        let until = Date().addingTimeInterval(0.12)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )!
            window.sendEvent(event)
        }
        settle()
    }

    private func horizontallyScrollableViews(in root: NSView) -> [NSScrollView] {
        let own = (root as? NSScrollView).map { [$0] } ?? []
        return own + root.subviews.flatMap(horizontallyScrollableViews)
    }

    private func assertHorizontalScroll(
        in root: NSView, file: StaticString = #filePath, line: UInt = #line
    ) {
        let scroll = horizontallyScrollableViews(in: root).first {
            $0.contentView.bounds.height < 30
                && ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 60
        }
        guard let scroll else {
            XCTFail("Expected horizontally scrollable content", file: file, line: line)
            return
        }
        let before = scroll.contentView.bounds.minX
        scroll.contentView.scroll(to: NSPoint(x: before + 50, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, before + 20,
                             "Horizontal scrolling must actually move the content",
                             file: file, line: line)
    }

    private func hostHistory(
        _ commits: [GitStatusModel.RecentCommit], selection: GraphSelection,
        width: CGFloat = 260, height: CGFloat = 200, viewMode: GitViewMode = .list,
        remotes: [String] = [],
        stashAction: @escaping (GitStatusModel.Stash, GitStatusModel.StashAction) -> Void = { _, _ in }
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -1200, y: -1200, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RecentCommitsView(
            commits: commits,
            remotes: remotes,
            repoRoot: "/fixture", fileAction: { _, _, _ in },
            loadBinaryStatus: { _ in }, isBinaryFile: { _, _ in false },
            expandedCommitIDs: Binding(get: { selection.expanded }, set: { selection.expanded = $0 }),
            collapsedFolders: Binding(get: { selection.folders }, set: { selection.folders = $0 }),
            viewMode: viewMode, fontScale: 1,
            hasMoreCommits: false, isLoadingMore: false, loadMore: { false },
            openDiff: { _, _ in }, canSwitchBranch: true,
            switchBranch: { _ in }, branchAction: { _, _, _ in }, remoteAction: { _, _, _ in }, tagAction: { _, _, _ in },
            isAnnotatedTag: { _ in false },
            canFetchRemoteBranch: { _ in false }, createBranch: { _ in }, addTag: { _ in },
            canActOnCommit: true, canDropCommit: { _ in false }, commitAction: { _, _ in },
            stashAction: stashAction
        ).frame(width: width, height: height, alignment: .topLeading)
            .background(Color(nsColor: Theme.sidebar)))
        window.orderFront(nil)
        settle()
        return window
    }

    func testGraphPaletteMatchesTwelveReferenceColors() {
        let expected: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 133, 217), (217, 0, 143), (0, 217, 10), (217, 133, 0),
            (163, 0, 217), (255, 0, 0), (0, 217, 204), (225, 56, 232),
            (133, 217, 0), (220, 91, 35), (111, 36, 214), (255, 204, 0),
        ]
        XCTAssertEqual(GitGraphPalette.colors.count, expected.count)
        for (index, rgb) in expected.enumerated() {
            let actual = GitGraphPalette.colors[index]
            XCTAssertEqual(actual.redComponent, rgb.0 / 255, accuracy: 0.001)
            XCTAssertEqual(actual.greenComponent, rgb.1 / 255, accuracy: 0.001)
            XCTAssertEqual(actual.blueComponent, rgb.2 / 255, accuracy: 0.001)
        }
    }

    func testHeadAndStashGraphGutterRemainsClickableInBothAppearances() throws {
        let stash = GitStatusModel.Stash(
            selector: "stash@{0}", oid: String(repeating: "d", count: 40),
            message: "saved", baseHash: "head", untrackedFilesHash: nil,
            author: "Tester", date: .now
        )
        let head = GitStatusModel.RecentCommit(
            hash: "head", shortHash: "head", subject: "Main change",
            author: "Developer", date: .now, parentHashes: ["base"],
            references: [.init(kind: .currentBranch, name: "main")],
            files: [.init(status: "M", path: "file.swift", originalPath: nil)]
        )
        let root = GitStatusModel.RecentCommit(
            hash: "base", shortHash: "base", subject: "Initial",
            author: "Developer", date: .now, parentHashes: [], references: [], files: []
        )
        let commits = GitStatusModel.graphCommits([head, root], stashes: [stash])
        XCTAssertEqual(commits.first?.stash?.selector, stash.selector)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let selection = GraphSelection()
            let window = hostHistory(commits, selection: selection, height: 200)
            window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
            settle()
            click(NSPoint(x: 8, y: 200 - 19 - 38), in: window)
            XCTAssertTrue(selection.expanded.contains("head"))
            click(NSPoint(x: 8, y: 200 - 19), in: window)
            XCTAssertTrue(selection.expanded.contains(commits[0].id))
            window.close()
        }
    }

    func testCompositeReferencesUseLongestConfiguredRemoteAndPreserveEveryTarget() throws {
        typealias Ref = GitStatusModel.RecentCommit.Reference
        let references: [Ref] = [
            .init(kind: .localBranch, name: "team/topic/nested"),
            .init(kind: .remoteBranch, name: "origin/team/topic/nested"),
            .init(kind: .remoteBranch, name: "old/main"),
            .init(kind: .currentBranch, name: "main"),
            .init(kind: .remoteBranch, name: "upstream/main"),
            .init(kind: .localBranch, name: "topic/nested"),
            .init(kind: .tag, name: "v1,β"),
            .init(kind: .remoteBranch, name: "origin/main"),
            .init(kind: .remoteAlias, name: "origin/HEAD"),
        ]
        let groups = GitGraphReferenceGroup.grouped(
            references, remotes: ["origin", "origin/team", "upstream"]
        )
        XCTAssertEqual(groups.first?.primary.name, "main")
        XCTAssertEqual(groups.first?.remotes.map(\.name), ["upstream/main", "origin/main"])
        XCTAssertEqual(groups.first?.remotes.map { groups[0].remoteTitle($0) },
                       ["upstream", "origin"])
        let topic = try XCTUnwrap(groups.first { $0.primary.name == "topic/nested" })
        XCTAssertEqual(topic.remotes.map(\.name), ["origin/team/topic/nested"])
        XCTAssertEqual(topic.remoteTitle(try XCTUnwrap(topic.remotes.first)), "origin/team")
        XCTAssertTrue(groups.contains {
            $0.primary.name == "team/topic/nested" && $0.remotes.isEmpty
        })
        XCTAssertTrue(groups.contains {
            $0.primary.name == "old/main" && $0.remotes.isEmpty
        })
        XCTAssertTrue(groups.contains {
            $0.primary.kind == .remoteAlias && $0.remotes.isEmpty
        })
        XCTAssertTrue(groups.contains { $0.primary.kind == .tag })
        let flattened = groups.flatMap(\.references)
        XCTAssertEqual(flattened.count, references.count)
        XCTAssertEqual(Set(flattened), Set(references))
    }

    func testCompositeReferencesNeverJoinDifferentCommitRowsOrUnknownRemotes() {
        typealias Ref = GitStatusModel.RecentCommit.Reference
        let local = Ref(kind: .localBranch, name: "修复/feature,α")
        let remote = Ref(kind: .remoteBranch, name: "origin/修复/feature,α")
        let first = GitGraphReferenceGroup.grouped([local], remotes: ["origin"])
        let second = GitGraphReferenceGroup.grouped([remote], remotes: ["origin"])
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].remotes.isEmpty)
        XCTAssertEqual(second[0].primary, remote)
        let stale = GitGraphReferenceGroup.grouped([local, remote], remotes: [])
        XCTAssertEqual(stale.count, 2)
        XCTAssertTrue(stale.allSatisfy { $0.remotes.isEmpty })
        let matched = GitGraphReferenceGroup.grouped([local, remote], remotes: ["origin"])
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched[0].remotes, [remote])
        XCTAssertEqual(matched[0].remoteTitle(remote), "origin")
    }

    func testCompositeOverflowKeepsRealReferencesAvailableWithoutWholeRowScrolling() {
        typealias Ref = GitStatusModel.RecentCommit.Reference
        let refs: [Ref] = [.init(kind: .currentBranch, name: "main")]
            + (0..<33).map { .init(kind: .remoteBranch, name: "remote-\($0)/main") }
        let remoteNames = (0..<33).map { "remote-\($0)" }
        let groups = GitGraphReferenceGroup.grouped(refs, remotes: remoteNames)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].references.count, 34)
        XCTAssertEqual(Set(groups.flatMap(\.references)), Set(refs))

        let commit = GitStatusModel.RecentCommit(
            hash: "many-refs", shortHash: "many", subject: "A change with many remotes",
            author: "Tester", date: .now, parentHashes: [], references: refs, files: []
        )
        let window = hostHistory([commit], selection: GraphSelection(), height: 120,
                                 remotes: remoteNames)
        defer { window.close() }
        XCTAssertFalse(horizontallyScrollableViews(in: window.contentView!).contains {
            $0.contentView.bounds.height > 60
                && ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 10
        }, "Many references must fold locally, not turn the graph into a scrolling table")
    }

    func testCompositeBranchSegmentsCopyAndUseTheirOwnMenus() throws {
        let selection = GraphSelection()
        let commit = GitStatusModel.RecentCommit(
            hash: "composite", shortHash: "composite", subject: "Change",
            author: "Developer", date: .now, parentHashes: [],
            references: [
                .init(kind: .currentBranch, name: "main"),
                .init(kind: .remoteBranch, name: "origin/main"),
                .init(kind: .remoteBranch, name: "upstream/main"),
                .init(kind: .tag, name: "v1.0"),
            ], files: []
        )
        let height: CGFloat = 150
        let window = hostHistory([commit], selection: selection, width: 500,
                                 height: height, remotes: ["origin", "upstream"])
        defer { window.close() }
        let localMenu = String(localized: "Rename Branch…", table: "Git")
        let remoteMenu = String(localized: "Delete Remote Branch…", table: "Git")
        for (name, x, expected, excluded) in [
            ("main", CGFloat(65), localMenu, remoteMenu),
            ("origin/main", CGFloat(103), remoteMenu, localMenu),
            ("upstream/main", CGFloat(141), remoteMenu, localMenu),
        ] {
            let point = NSPoint(x: x, y: height - 12)
            click(point, in: window)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), name)
            XCTAssertTrue(selection.expanded.isEmpty, "A label click must not expand the commit")
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1
            ))
            let titles = try XCTUnwrap(window.contentView?.menu(for: event), name)
                .items.map(\.title)
            XCTAssertTrue(titles.contains(expected), "\(name): \(titles)")
            XCTAssertFalse(titles.contains(excluded), "\(name): \(titles)")
        }
    }

    func testGraphNodeHelpOnlyStatesConfirmedHEADMembershipAndActualReferences() throws {
        let commit = GitStatusModel.RecentCommit(
            hash: String(repeating: "a", count: 40),
            shortHash: "aaaaaaa", subject: "Merge branch",
            author: "Tester", date: .now, parentHashes: ["parent", "side"],
            references: [
                .init(kind: .remoteBranch, name: "origin/main"),
                .init(kind: .tag, name: "v1.0"),
            ], files: []
        )
        let confirmed = RecentCommitsView.nodeHelp(commit, inHeadHistory: true)
        XCTAssertTrue(confirmed.contains(commit.hash))
        XCTAssertTrue(confirmed.contains(commit.subject))
        XCTAssertTrue(confirmed.contains("origin/main"))
        XCTAssertTrue(confirmed.contains("v1.0"))
        XCTAssertTrue(confirmed.contains(
            String(localized: "In HEAD History", table: "Git")
        ))
        let unknown = RecentCommitsView.nodeHelp(commit, inHeadHistory: false)
        XCTAssertFalse(unknown.contains(
            String(localized: "In HEAD History", table: "Git")
        ))
        let stash = GitStatusModel.Stash(
            selector: "stash@{1}", oid: String(repeating: "b", count: 40),
            message: "saved", baseHash: "parent", untrackedFilesHash: nil,
            author: "Tester", date: .now
        )
        let stashCommit = try XCTUnwrap(
            GitStatusModel.graphCommits([], stashes: [stash]).first
        )
        XCTAssertTrue(RecentCommitsView.nodeHelp(
            stashCommit, inHeadHistory: false
        ).contains(stash.selector))
    }

    func testNodeHoverTargetRetainsSingleClickAndCommitContextMenu() throws {
        let selection = GraphSelection()
        let commit = GitStatusModel.RecentCommit(
            hash: "node", shortHash: "node", subject: "One commit",
            author: "Tester", date: .now, parentHashes: [],
            references: [.init(kind: .currentBranch, name: "main")], files: []
        )
        let height: CGFloat = 160
        let window = hostHistory([commit], selection: selection, height: height)
        defer { window.close() }
        let node = NSPoint(x: 8, y: height - 19)
        click(node, in: window)
        XCTAssertTrue(selection.expanded.contains(commit.id))
        click(node, in: window)
        XCTAssertFalse(selection.expanded.contains(commit.id),
                       "Node hit area must not trigger both its own and the row action")
        click(NSPoint(x: 20, y: height - 19), in: window)
        XCTAssertTrue(selection.expanded.contains(commit.id),
                      "Clicking the gutter outside the node still toggles the row")
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: node,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
        let titles = try XCTUnwrap(window.contentView?.menu(for: event)).items.map(\.title)
        XCTAssertTrue(titles.contains(String(localized: "Create Branch at Commit…",
                                              table: "Git")))
        XCTAssertFalse(titles.contains(String(localized: "Delete Remote Branch…",
                                               table: "Git")))
    }

    func testLongCommitMessageCanScrollHorizontallyInNarrowSidebar() {
        let selection = GraphSelection()
        let longSubject = "修复远程工作区同步并保留所有 Git 分支的真实关系 " + String(repeating: "very-long-commit-message-", count: 12)
        let commit = GitStatusModel.RecentCommit(
            hash: "a", shortHash: "a", subject: longSubject,
            author: "Developer", date: .now, parentHashes: [],
            references: [.init(kind: .currentBranch, name: "main")], files: []
        )
        let window = hostHistory([commit], selection: selection, height: 110)
        defer { window.close() }
        assertHorizontalScroll(in: window.contentView!)
    }

    func testManyParallelBranchesDoNotScrollWholeGraphSideways() {
        let selection = GraphSelection()
        func commit(_ hash: String, parents: [String] = [], current: Bool = false)
            -> GitStatusModel.RecentCommit {
            .init(hash: hash, shortHash: hash, subject: hash,
                  author: "Developer", date: .now, parentHashes: parents,
                  references: current ? [.init(kind: .currentBranch, name: "main")] : [],
                  files: [])
        }
        let commits = (0..<30).map { commit("branch-\($0)", parents: ["root"]) }
            + [commit("main", parents: ["root"], current: true), commit("root")]
        let window = hostHistory(commits, selection: selection, height: 320)
        defer { window.close() }
        let rowScrolls = horizontallyScrollableViews(in: window.contentView!)
        XCTAssertFalse(rowScrolls.contains {
            $0.contentView.bounds.height > 60
                && ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 10
        }, "Graph and commit rows must stay anchored while only text scrolls")
        XCTAssertTrue(rowScrolls.contains {
            $0.contentView.bounds.height < 30 && $0.contentView.bounds.width > 90
        }, "Even with many Git lanes, the message must remain readable in the sidebar")
    }

    func testShortCommitMessagesDoNotBounceHorizontally() {
        let selection = GraphSelection()
        let commit = GitStatusModel.RecentCommit(
            hash: "short", shortHash: "short", subject: "Fix",
            author: "Developer", date: .now, parentHashes: [],
            references: [], files: []
        )
        let window = hostHistory([commit], selection: selection)
        defer { window.close() }
        guard let scroll = horizontallyScrollableViews(in: window.contentView!).first(where: {
            $0.contentView.bounds.height < 30
        }) else {
            XCTFail("Expected a message-only horizontal scroller")
            return
        }
        XCTAssertLessThanOrEqual(
            (scroll.documentView?.frame.width ?? 0) - scroll.contentView.bounds.width, 1
        )
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none,
                       "A short commit message must not bounce horizontally")
    }

    func testExpandedHistoryKeepsLongFolderPathsScrollable() {
        let selection = GraphSelection()
        let hash = "a"
        selection.expanded.insert(hash)
        let commit = GitStatusModel.RecentCommit(
            hash: hash, shortHash: hash, subject: "Short title",
            author: "Developer", date: .now, parentHashes: [],
            references: [], files: [
                .init(status: "M",
                      path: String(repeating: "very-long-folder/", count: 9) + "file.swift",
                      originalPath: nil)
            ]
        )
        let window = hostHistory([commit], selection: selection, viewMode: .tree)
        defer { window.close() }
        assertHorizontalScroll(in: window.contentView!)
    }

    func testRecentCommitHistoryOnlyPagesAtBottom() {
        let selection = GraphSelection()
        let commits: [GitStatusModel.RecentCommit] = (0..<60).map { index in
            .init(hash: "hash-\(index)", shortHash: "hash-\(index)",
                  subject: "Commit \(index)", author: "Developer", date: .now,
                  parentHashes: index < 59 ? ["hash-\(index + 1)"] : [],
                  references: index == 0
                    ? [.init(kind: .currentBranch, name: "main")] : [],
                  files: [])
        }
        let width: CGFloat = 260
        let height: CGFloat = 190
        var pageRequests = 0
        let window = NSWindow(
            contentRect: NSRect(x: -1200, y: -1200, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView(.vertical) {
            RecentCommitsView(
                commits: commits,
            repoRoot: "/fixture", fileAction: { _, _, _ in },
            loadBinaryStatus: { _ in }, isBinaryFile: { _, _ in false },
                expandedCommitIDs: Binding(get: { selection.expanded }, set: { selection.expanded = $0 }),
                collapsedFolders: Binding(get: { selection.folders }, set: { selection.folders = $0 }),
                viewMode: .list, fontScale: 1,
                hasMoreCommits: true, isLoadingMore: false,
                loadMore: { pageRequests += 1; return true },
                openDiff: { _, _ in }, canSwitchBranch: true,
                switchBranch: { _ in }, branchAction: { _, _, _ in }, remoteAction: { _, _, _ in }, tagAction: { _, _, _ in },
            isAnnotatedTag: { _ in false },
            canFetchRemoteBranch: { _ in false }, createBranch: { _ in }, addTag: { _ in },
                canActOnCommit: true, canDropCommit: { _ in false }, commitAction: { _, _ in }
            )
        }.frame(width: width, height: height))
        window.orderFront(nil)
        settle()
        defer { window.close() }
        XCTAssertEqual(pageRequests, 0, "Offscreen commits must not trigger history pagination")
        guard let verticalScroll = horizontallyScrollableViews(in: window.contentView!).first(where: {
            ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 200
        }), let document = verticalScroll.documentView else {
            XCTFail("Expected the vertical Git history scroller")
            return
        }
        verticalScroll.contentView.scroll(to: NSPoint(
            x: 0, y: document.frame.height - verticalScroll.contentView.bounds.height
        ))
        verticalScroll.reflectScrolledClipView(verticalScroll.contentView)
        settle()
        XCTAssertEqual(pageRequests, 1, "Reaching the last visible row must still page history")
    }

    func testEntireCommitRowTogglesIncludingGraphMetadataAndBlankSpace() {
        let selection = GraphSelection()
        let commit = GitStatusModel.RecentCommit(
            hash: "one", shortHash: "one", subject: "Commit message",
            author: "Developer", date: .now, parentHashes: [],
            references: [], files: [
                .init(status: "A", path: "Sources/test.swift", originalPath: nil)
            ]
        )
        let height: CGFloat = 200
        let window = hostHistory([commit], selection: selection, height: height)
        defer { window.close() }

        // All coordinates are within the 38-point commit row, including its
        // graph gutter, metadata, blank space and top/bottom edges.
        for point in [
            NSPoint(x: 10, y: height - 19),
            NSPoint(x: 28, y: height - 19),
            NSPoint(x: 142, y: height - 30),
            NSPoint(x: 251, y: height - 13),
            NSPoint(x: 18, y: height - 1),
            NSPoint(x: 18, y: height - 37),
        ] {
            let wasExpanded = selection.expanded.contains(commit.hash)
            click(point, in: window)
            XCTAssertNotEqual(
                selection.expanded.contains(commit.hash), wasExpanded,
                "Whole commit row should toggle at \(point)"
            )
        }
    }

    func testMergedHistoryOpensItsRealFileAfterExpansion() {
        let selection = GraphSelection()
        let files: [GitStatusModel.RecentCommit.FileChange] = [
            .init(status: "M", path: "Sources/file.swift", originalPath: nil)
        ]
        func row(_ id: String, parents: [String], name: String, current: Bool = false)
            -> GitStatusModel.RecentCommit {
            .init(hash: id, shortHash: id, subject: name, author: "Developer",
                  date: .distantPast, parentHashes: parents,
                  references: current
                    ? [.init(kind: .currentBranch, name: "main")]
                    : [], files: files)
        }
        let commits = [
            row("merge", parents: ["base", "side"], name: "Merge branch", current: true),
            row("side", parents: ["root"], name: "Side commit"),
            row("base", parents: ["root"], name: "Main commit"),
            row("root", parents: [], name: "Root commit"),
        ]
        let width: CGFloat = 440
        let height: CGFloat = 390
        var diffs: [String] = []
        let window = NSWindow(
            contentRect: NSRect(x: -1200, y: -1200, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RecentCommitsView(
            commits: commits,
            repoRoot: "/fixture", fileAction: { _, _, _ in },
            loadBinaryStatus: { _ in }, isBinaryFile: { _, _ in false },
            expandedCommitIDs: Binding(
                get: { selection.expanded },
                set: { selection.expanded = $0 }
            ),
            collapsedFolders: Binding(
                get: { selection.folders },
                set: { selection.folders = $0 }
            ),
            viewMode: .list, fontScale: 1,
            hasMoreCommits: false, isLoadingMore: false,
            loadMore: { false },
            openDiff: { commit, file in diffs.append(commit.hash + ":" + file.path) },
            canSwitchBranch: true, switchBranch: { _ in },
            branchAction: { _, _, _ in }, remoteAction: { _, _, _ in }, tagAction: { _, _, _ in },
            isAnnotatedTag: { _ in false },
            canFetchRemoteBranch: { _ in false }, createBranch: { _ in }, addTag: { _ in }, canActOnCommit: true, canDropCommit: { _ in false }, commitAction: { _, _ in }
        ).frame(width: width, height: height, alignment: .topLeading)
            .background(Color(nsColor: Theme.sidebar)))
        window.orderFront(nil)
        settle()
        click(NSPoint(x: 95, y: height - 18), in: window)
        XCTAssertTrue(selection.expanded.contains("merge"))
        click(NSPoint(x: 125, y: height - 38 - TreeRowStyle.rowHeight(1) / 2), in: window)
        XCTAssertEqual(diffs, ["merge:Sources/file.swift"])
        window.close()
    }

    func testCommitTitleExpandsFilesInWideAndNarrowPanels() {
        for (width, scale) in [(CGFloat(420), CGFloat(1)),
                               (CGFloat(260), CGFloat(1.6))] {
            let selection = GraphSelection()
            let commit = GitStatusModel.RecentCommit(
                hash: "0000000000000000000000000000000000000001",
                shortHash: "0000000", subject: "Add feature",
                author: "Developer", date: .now,
                parentHashes: [],
                references: [
                    .init(kind: .currentBranch, name: "main"),
                    .init(kind: .remoteBranch, name: "origin/main"),
                    .init(kind: .tag, name: "v1.2.3"),
                ],
                files: [.init(status: "A", path: "Sources/new.swift", originalPath: nil)]
            )
            let height: CGFloat = 180
            let window = NSWindow(
                contentRect: NSRect(x: -1200, y: -1200, width: width, height: height),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RecentCommitsView(
                commits: [commit],
            repoRoot: "/fixture", fileAction: { _, _, _ in },
            loadBinaryStatus: { _ in }, isBinaryFile: { _, _ in false },
                expandedCommitIDs: Binding(
                    get: { selection.expanded },
                    set: { selection.expanded = $0 }
                ),
                collapsedFolders: Binding(
                    get: { selection.folders },
                    set: { selection.folders = $0 }
                ),
                viewMode: .list, fontScale: scale,
                hasMoreCommits: false, isLoadingMore: false,
                loadMore: { false }, openDiff: { _, _ in },
                canSwitchBranch: true, switchBranch: { _ in },
                branchAction: { _, _, _ in }, remoteAction: { _, _, _ in }, tagAction: { _, _, _ in },
            isAnnotatedTag: { _ in false },
            canFetchRemoteBranch: { _ in false }, createBranch: { _ in }, addTag: { _ in }, canActOnCommit: true, canDropCommit: { _ in false }, commitAction: { _, _ in }
            )
            .frame(width: width, height: height, alignment: .topLeading)
                .background(Color(nsColor: Theme.sidebar)))
            window.orderFront(nil)
            settle()
            let titlePoint = NSPoint(x: width - 45, y: height - 14 * scale)
            click(titlePoint, in: window)
            XCTAssertTrue(selection.expanded.contains(commit.hash),
                          "Commit title must remain clickable at width \(width)")
            click(titlePoint, in: window)
            XCTAssertFalse(selection.expanded.contains(commit.hash))
            window.close()
        }
    }

    func testNativeContextMenuAtDirectReferencesContainsOnlyTheSelectedObjectActions() throws {
        let cases: [(GitStatusModel.RecentCommit.Reference.Kind, String, String)] = [
            (.currentBranch, "main", String(localized: "Rename Branch…", table: "Git")),
            (.localBranch, "topic", String(localized: "Delete Branch…", table: "Git")),
            (.remoteBranch, "origin/topic", String(localized: "Delete Remote Branch…", table: "Git")),
            (.tag, "v1.2.3", String(localized: "Delete Tag…", table: "Git")),
        ]
        for (kind, name, expected) in cases {
            let selection = GraphSelection()
            let commit = GitStatusModel.RecentCommit(
                hash: "menu", shortHash: "menu", subject: "Small change", author: "Developer",
                date: .now, parentHashes: [], references: [.init(kind: kind, name: name)], files: []
            )
            let height: CGFloat = 110
            let window = hostHistory([commit], selection: selection, height: height)
            defer { window.close() }
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 70, y: height - 12),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
            let menu = try XCTUnwrap(window.contentView?.menu(for: event), name)
            let titles = menu.items.map(\.title)
            XCTAssertTrue(titles.contains(expected), name)
            XCTAssertFalse(titles.contains(String(localized: "Create Branch at Commit…", table: "Git")), name)
            XCTAssertTrue(selection.expanded.isEmpty, "Requesting a context menu must not trigger a left action")
        }
    }

    func testSymbolicRemoteAliasHasOnlyCopyActionAndDoesNotToggleCommit() throws {
        let alias = GitStatusModel.RecentCommit.Reference(kind: .remoteAlias,
                                                         name: "upstream/HEAD")
        let commit = GitStatusModel.RecentCommit(
            hash: "alias", shortHash: "alias", subject: "Small change",
            author: "Developer", date: .now, parentHashes: [],
            references: [alias], files: []
        )
        let selection = GraphSelection()
        let height: CGFloat = 110
        let window = hostHistory([commit], selection: selection, height: height)
        defer { window.close() }
        let point = NSPoint(x: 70, y: height - 12)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
        let titles = try XCTUnwrap(window.contentView?.menu(for: event)).items.map(\.title)
        XCTAssertTrue(titles.contains(String(localized: "Copy Remote Branch Name", table: "Git")))
        XCTAssertFalse(titles.contains(String(localized: "Delete Remote Branch…", table: "Git")))
        XCTAssertFalse(titles.contains(String(localized: "Checkout Remote Branch…", table: "Git")))
        click(point, in: window)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), alias.name)
        XCTAssertTrue(selection.expanded.isEmpty)
    }

    func testStashIsANodeInTheSameGraphWithOnlyStashActions() throws {
        let stash = GitStatusModel.Stash(
            selector: "stash@{0}", oid: String(repeating: "d", count: 40),
            message: "saved work", baseHash: String(repeating: "b", count: 40),
            untrackedFilesHash: nil, author: "Tester", date: .now
        )
        let base = GitStatusModel.RecentCommit(
            hash: stash.baseHash, shortHash: "bbbbbbb", subject: "Base revision",
            author: "Developer", date: .now, parentHashes: [],
            references: [.init(kind: .currentBranch, name: "main")], files: []
        )
        let graph = GitStatusModel.graphCommits([base], stashes: [stash])
        XCTAssertEqual(graph.count, 2)
        XCTAssertEqual(graph.first?.stash?.selector, "stash@{0}")
        XCTAssertEqual(graph.last?.hash, stash.baseHash)
        XCTAssertTrue(CommitGraphLayout(commits: graph).rows[0].links.count > 0)

        let selection = GraphSelection()
        let height: CGFloat = 180
        let window = hostHistory(graph, selection: selection, height: height)
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 112, y: height - 12),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
        let menu = try XCTUnwrap(window.contentView?.menu(for: event))
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains(String(localized: "Apply Stash…", table: "Git")))
        XCTAssertTrue(titles.contains(String(localized: "Pop Stash…", table: "Git")))
        XCTAssertTrue(titles.contains(String(localized: "Drop Stash…", table: "Git")))
        XCTAssertFalse(titles.contains(String(localized: "Checkout Commit…", table: "Git")))
        XCTAssertFalse(titles.contains(String(localized: "Reset Current Branch to Commit…", table: "Git")))
        XCTAssertTrue(selection.expanded.isEmpty, "A right click must not toggle the stash")
    }

    func testTagBadgeDoesNotToggleExpandedCommitClosed() {
        let selection = GraphSelection()
        let commit = GitStatusModel.RecentCommit(
            hash: "tag-commit", shortHash: "tag-commit", subject: "Small change",
            author: "Developer", date: .now, parentHashes: [],
            references: [.init(kind: .tag, name: "v1.2.3")],
            files: [.init(status: "A", path: "Sources/new.swift", originalPath: nil)]
        )
        let height: CGFloat = 180
        let window = hostHistory([commit], selection: selection, height: height)
        defer { window.close() }
        let tagPoint = NSPoint(x: 70, y: height - 12)
        click(tagPoint, in: window)
        XCTAssertTrue(selection.expanded.contains(commit.hash),
                      "Tag badge should locate the tagged commit")
        click(tagPoint, in: window)
        XCTAssertTrue(selection.expanded.contains(commit.hash),
                      "Clicking Tag again must not collapse its commit")
    }
}
