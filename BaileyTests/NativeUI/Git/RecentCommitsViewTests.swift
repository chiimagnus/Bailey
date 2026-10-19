import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
@Observable
private final class GraphSelection {
    var expanded: Set<String> = []
    var folders: Set<String> = []
}

@MainActor
private final class WorktreeMenuCalls {
    var events: [(String, RecentCommitsView.WorktreeAction)] = []
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
        width: CGFloat = 260, height: CGFloat = 200, fontScale: CGFloat = 1,
        viewMode: GitViewMode = .list,
        remotes: [String] = [],
        stashAction: @escaping (GitStatusModel.Stash, GitStatusModel.StashAction) -> Void = { _, _ in },
        openWorktreeDiff: @escaping (GitStatusModel.WorktreeChanges, GitStatusModel.Entry, Bool) -> Void = { _, _, _ in },
        canActOnWorktrees: Bool = false,
        worktreeAction: @escaping (GitStatusModel.WorktreeLocation, RecentCommitsView.WorktreeAction) -> Void = { _, _ in }
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
            viewMode: viewMode, fontScale: fontScale,
            hasMoreCommits: false, isLoadingMore: false, loadMore: { false },
            openDiff: { _, _ in }, canSwitchBranch: true,
            switchBranch: { _ in }, branchAction: { _, _, _ in }, remoteAction: { _, _, _ in }, tagAction: { _, _, _ in },
            isAnnotatedTag: { _ in false },
            canFetchRemoteBranch: { _ in false }, createBranch: { _ in }, addTag: { _ in },
            canActOnCommit: true, canDropCommit: { _ in false }, commitAction: { _, _ in },
            stashAction: stashAction,
            openWorktreeDiff: openWorktreeDiff,
            canActOnWorktrees: canActOnWorktrees,
            canRevealWorktreeInFinder: true,
            worktreeAction: worktreeAction
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

    func testPaletteIconsRemainReadableOverEveryGraphColor() {
        func luminance(_ color: NSColor) -> CGFloat {
            let rgb = color.usingColorSpace(.sRGB)!
            func channel(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb.redComponent)
                + 0.7152 * channel(rgb.greenComponent)
                + 0.0722 * channel(rgb.blueComponent)
        }

        XCTAssertEqual(GitGraphPalette.iconInks.count, GitGraphPalette.colors.count)
        for (index, background) in GitGraphPalette.colors.enumerated() {
            let ink = GitGraphPalette.iconInks[index]
            let lighter = max(luminance(background), luminance(ink))
            let darker = min(luminance(background), luminance(ink))
            let contrast = (lighter + 0.05) / (darker + 0.05)
            XCTAssertGreaterThanOrEqual(contrast, 4.5,
                "Palette color \(index) must keep the Git icon legible")
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

    func testCurrentAndFeatureUncommittedDiamondsAlignAndToggleInNativeGraph() throws {
        typealias Commit = GitStatusModel.RecentCommit
        let baseOID = String(repeating: "b", count: 40)
        let featureOID = String(repeating: "f", count: 40)
        let mainOID = String(repeating: "a", count: 40)
        let commits: [Commit] = [
            .init(hash: featureOID, shortHash: "fffffff", subject: "Feature tip",
                  author: "Dev", date: .now, parentHashes: [baseOID],
                  references: [.init(kind: .localBranch, name: "feature")], files: []),
            .init(hash: mainOID, shortHash: "aaaaaaa", subject: "Main checkout",
                  author: "Dev", date: .now, parentHashes: [baseOID],
                  references: [.init(kind: .currentBranch, name: "main")], files: []),
            .init(hash: baseOID, shortHash: "bbbbbbb", subject: "Shared ancestor",
                  author: "Dev", date: .now, parentHashes: [],
                  references: [], files: []),
        ]
        let worktrees = [
            GitStatusModel.WorktreeChanges(
                path: "/tmp/feature", branch: "feature", headOID: featureOID,
                entries: [.init(path: "feature-file", staged: "M", unstaged: ".")],
                isCurrent: false),
            GitStatusModel.WorktreeChanges(
                path: "/tmp/main", branch: "main", headOID: mainOID,
                entries: [.init(path: "main-file", staged: ".", unstaged: "M")],
                isCurrent: true),
        ]
        let rows = GitStatusModel.graphCommits(commits, stashes: [], worktrees: worktrees)
        let graph = CommitGraphLayout(commits: rows)
        let featureRow = try XCTUnwrap(rows.firstIndex { $0.hash == featureOID && $0.worktree == nil })
        let mainRow = try XCTUnwrap(rows.firstIndex { $0.hash == mainOID && $0.worktree == nil })
        XCTAssertEqual(graph.rows[mainRow].node.lane, 0)
        XCTAssertEqual(graph.rows[featureRow].node.lane, 1)
        for (tree, headRow) in [(worktrees[0], featureRow), (worktrees[1], mainRow)] {
            let source = try XCTUnwrap(rows.firstIndex { $0.worktree?.path == tree.path })
            XCTAssertEqual(graph.rows[source].node, graph.rows[headRow].node)
        }
        let height: CGFloat = 260
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let selection = GraphSelection()
            let window = hostHistory(rows, selection: selection, width: 400, height: height)
            defer { window.close() }
            window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
            settle()
            for tree in worktrees {
                let index = try XCTUnwrap(rows.firstIndex { $0.worktree?.path == tree.path })
                let lane = graph.rows[index].node.lane
                let point = NSPoint(x: CGFloat(8 + lane * 9),
                                    y: height - CGFloat(index * 38 + 19))
                click(point, in: window)
                XCTAssertTrue(selection.expanded.contains(rows[index].id),
                              "Diamond in lane \(lane) must open its own worktree")
                click(point, in: window)
                XCTAssertFalse(selection.expanded.contains(rows[index].id))
                let badge = NSPoint(x: 70, y: point.y)
                click(badge, in: window)
                XCTAssertTrue(selection.expanded.contains(rows[index].id),
                              "The worktree label must toggle the same details as its diamond")
                click(badge, in: window)
                XCTAssertFalse(selection.expanded.contains(rows[index].id))
            }
        }
    }

    func testShortCommitHashCopiesWithoutExpandingDetails() {
        let selection = GraphSelection()
        let fullHash = String(repeating: "a", count: 40)
        let commit = GitStatusModel.RecentCommit(
            hash: fullHash, shortHash: "aaaaaaa", subject: "Unchanged commit",
            author: "Dev", date: .now, parentHashes: [],
            references: [], files: []
        )
        let height: CGFloat = 160
        let window = hostHistory([commit], selection: selection, height: height)
        defer { window.close() }
        click(NSPoint(x: 62, y: height - 29), in: window)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), fullHash)
        XCTAssertTrue(selection.expanded.isEmpty,
                      "Copying the hash must not implicitly expand commit details")
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
            ("main", CGFloat(52), localMenu, remoteMenu),
            ("origin/main", CGFloat(87), remoteMenu, localMenu),
            ("upstream/main", CGFloat(119), remoteMenu, localMenu),
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

    func testGraphGutterLeavesRoomForCommitContentAtExtremeLaneCounts() {
        let widths: [CGFloat] = [48, 120, 260, 400, 800]
        let scales: [CGFloat] = [0.8, 1, 1.6, 2]
        let laneCounts = [0, 1, 2, 12, 30, 100, 237, 1_000]
        for width in widths {
            for scale in scales {
                for lanes in laneCounts {
                    let spacing = CommitGraphRails.spacing(
                        lanes: lanes, viewportWidth: width, scale: scale)
                    let gutter = CommitGraphRails.gutter(
                        lanes: lanes, spacing: spacing, scale: scale)
                    let minimumNodeGutter = 16 * scale
                    XCTAssertTrue(spacing.isFinite && spacing >= 0,
                                  "Invalid spacing at \(width)pt, \(scale)x, \(lanes) lanes")
                    XCTAssertLessThanOrEqual(
                        gutter, max(width * 0.34, minimumNodeGutter) + 0.01,
                        "Commit title is displaced by \(lanes) lanes at \(width)pt / \(scale)x"
                    )
                    if width >= minimumNodeGutter {
                        XCTAssertLessThanOrEqual(gutter, width,
                                                 "Graph must not consume the whole sidebar")
                    }
                }
            }
        }
    }

    func testDenseRealNativeGraphRetainsVisibleTitleScrollerInBothThemes() throws {
        let commits: [GitStatusModel.RecentCommit] = (0..<237).map { index in
            .init(hash: "tip-\(index)", shortHash: "tip-\(index)",
                  subject: "Branch \(index) is still readable",
                  author: "Tester", date: .now, parentHashes: ["root"],
                  references: [], files: [])
        } + [.init(hash: "root", shortHash: "root", subject: "Root",
                    author: "Tester", date: .now, parentHashes: [],
                    references: [], files: [])]

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (width, scale) in [(CGFloat(260), CGFloat(1)),
                                   (CGFloat(260), CGFloat(1.6)),
                                   (CGFloat(400), CGFloat(2))] {
                let window = hostHistory(commits, selection: GraphSelection(),
                                         width: width, height: 180,
                                         fontScale: scale)
                defer { window.close() }
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                settle()
                let titleScrollers = horizontallyScrollableViews(in: window.contentView!).filter {
                    $0.contentView.bounds.height < 30 * scale
                        && $0.contentView.bounds.width >= 64 * scale
                }
                let title = try XCTUnwrap(titleScrollers.first,
                    "Dense graph must still have a native commit title viewport")
                let visible = title.convert(title.bounds, to: window.contentView)
                XCTAssertLessThanOrEqual(
                    visible.minX, width * 0.34 + 24,
                    "Title must start beside the bounded graph gutter")
                XCTAssertGreaterThanOrEqual(visible.width, 64 * scale)
                XCTAssertLessThanOrEqual(visible.minX + visible.width, width + 1,
                    "Title must not be pushed beyond the sidebar's right edge")
            }
        }
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
                with: .rightMouseDown, location: NSPoint(x: 50, y: height - 12),
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

    func testLongWorktreeBranchBadgeDoesNotObscureTheTitleInNarrowSidebar() throws {
        let branch = "feature/" + String(repeating: "极长的分支名称-long-name-", count: 10)
        let head = String(repeating: "a", count: 40)
        let tree = GitStatusModel.WorktreeChanges(
            path: "/Users/fixture/worktrees/very-long-worktree-name",
            branch: branch, headOID: head,
            entries: [.init(path: "edit.txt", staged: ".", unstaged: "M")],
            isCurrent: false
        )
        let commit = GitStatusModel.RecentCommit(
            hash: head, shortHash: "aaaaaaa", subject: "Base",
            author: "Tester", date: .now, parentHashes: [],
            references: [.init(kind: .currentBranch, name: "main")], files: []
        )
        let rows = GitStatusModel.graphCommits([commit], stashes: [], worktrees: [tree])
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (width, scale) in [(CGFloat(180), CGFloat(0.8)),
                                   (CGFloat(260), CGFloat(1)),
                                   (CGFloat(260), CGFloat(1.6)),
                                   (CGFloat(400), CGFloat(2))] {
                let window = hostHistory(rows, selection: GraphSelection(),
                                         width: width, height: 175, fontScale: scale)
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                settle()
                let layout = CommitGraphLayout(commits: rows)
                let spacing = CommitGraphRails.spacing(
                    lanes: layout.laneCount, viewportWidth: width, scale: scale)
                let gutter = CommitGraphRails.gutter(
                    lanes: layout.laneCount, spacing: spacing, scale: scale)
                let badge = RecentCommitsView.worktreeBadgeWidth(
                    branch, viewportWidth: width, gutter: gutter, scale: scale)
                XCTAssertLessThanOrEqual(badge, 112 * scale)
                XCTAssertGreaterThanOrEqual(badge, 18 * scale)
                let shortBadge = RecentCommitsView.worktreeBadgeWidth(
                    "main", viewportWidth: width, gutter: gutter, scale: scale)
                XCTAssertLessThanOrEqual(shortBadge, badge,
                                         "Short branches should use less space than long ones")
                if width >= 260, scale <= 1.6 {
                    XCTAssertLessThanOrEqual(shortBadge, 62 * scale,
                                             "The 'main' label must not expand into a long empty pill")
                    XCTAssertGreaterThan(shortBadge, 18 * scale,
                                         "Common sidebar sizes must still display the short branch name")
                }
                XCTAssertLessThanOrEqual(badge + gutter + 64 * scale + 24 * scale,
                                         max(width, gutter + 18 * scale + 88 * scale) + 1,
                                         "Badge must not crowd out the title at \(width)pt / \(scale)x")
                XCTAssertFalse(horizontallyScrollableViews(in: window.contentView!).contains {
                    $0.contentView.bounds.height > 60 * scale
                        && ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 10
                }, "Worktree header must not become a horizontally scrolling row")
                window.close()
            }
        }
    }

    func testWorktreeDisplayPathsStayUniqueWithSameCheckoutDirectoryNames() {
        let paths = [
            "/Users/test/A/shared",
            "/Users/test/B/shared",
            "/Users/test/C/one/shared",
            "/Users/test/D/one/shared",
            "/Users/test/独特工作树",
        ]
        let labels = paths.map { RecentCommitsView.worktreeDisplayPath($0, among: paths) }
        XCTAssertEqual(labels.count, Set(labels).count)
        XCTAssertEqual(labels[0], "A/shared")
        XCTAssertEqual(labels[1], "B/shared")
        XCTAssertEqual(labels[2], "C/one/shared")
        XCTAssertEqual(labels[3], "D/one/shared")
        XCTAssertEqual(labels[4], "独特工作树")
        XCTAssertEqual(RecentCommitsView.worktreeDisplayPath("/Users/test/B/shared",
                         among: ["/Users/test/B/shared"]), "shared")
    }

    func testWorktreeConflictStatusAlwaysUsesUInTreeAndList() {
        let conflicts: [(Character, Character)] = [
            ("U", "U"), ("A", "A"), ("D", "D"), ("A", "U"), ("U", "D")
        ]
        for (index, status) in conflicts.enumerated() {
            let entry = GitStatusModel.Entry(
                path: "conflict-\(index).txt", staged: status.0,
                unstaged: status.1, isConflict: true
            )
            XCTAssertEqual(RecentCommitsView.worktreeDisplayStatus(entry, staged: true), "U")
            XCTAssertEqual(RecentCommitsView.worktreeDisplayStatus(entry, staged: false), "U")
        }
        let modified = GitStatusModel.Entry(path: "modified", staged: "R", unstaged: "M")
        XCTAssertEqual(RecentCommitsView.worktreeDisplayStatus(modified, staged: true), "R")
        XCTAssertEqual(RecentCommitsView.worktreeDisplayStatus(modified, staged: false), "M")
    }

    func testGraphBadgeRowsStayCompactAcrossAppearanceAndFontSizes() throws {
        let base = String(repeating: "a", count: 40)
        let stash = GitStatusModel.Stash(
            selector: "stash@{12}", oid: String(repeating: "b", count: 40),
            message: "Kept changes", baseHash: base,
            untrackedFilesHash: nil, author: "Test", date: .now
        )
        let worktree = GitStatusModel.WorktreeChanges(
            path: "/tmp/team/feature/branch workspace",
            branch: "feature/很长很长的分支名称-v2",
            headOID: base,
            entries: [.init(path: "file.txt", staged: "M", unstaged: "M")],
            isCurrent: false
        )
        let commit = GitStatusModel.RecentCommit(
            hash: base, shortHash: "aaaaaaa", subject: "Base commit is readable",
            author: "Test", date: .now, parentHashes: [],
            references: [
                .init(kind: .currentBranch, name: "main"),
                .init(kind: .remoteBranch, name: "origin/main"),
                .init(kind: .tag, name: "v12.34.56"),
            ], files: []
        )
        let rows = GitStatusModel.graphCommits(
            [commit], stashes: [stash], worktrees: [worktree]
        )
        XCTAssertEqual(rows.count, 3)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (width, scale) in [
                (CGFloat(120), CGFloat(0.8)),
                (CGFloat(180), CGFloat(1)),
                (CGFloat(260), CGFloat(1.6)),
                (CGFloat(400), CGFloat(2)),
                (CGFloat(400), CGFloat(1)),
            ] {
                let window = hostHistory(
                    rows, selection: GraphSelection(),
                    width: width, height: 210, fontScale: scale, remotes: ["origin"]
                )
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                settle()
                XCTAssertFalse(
                    horizontallyScrollableViews(in: window.contentView!).contains {
                        $0.contentView.bounds.height > 60 * scale
                            && ($0.documentView?.frame.width ?? 0)
                                > $0.contentView.bounds.width + 10
                    },
                    "Badges must not scroll the whole graph at \(width)pt, \(scale)x"
                )
                let graph = CommitGraphLayout(commits: rows)
                let worktreeIndex = try XCTUnwrap(rows.firstIndex { $0.worktree != nil })
                let headIndex = try XCTUnwrap(rows.firstIndex {
                    $0.hash == base && $0.worktree == nil && $0.stash == nil
                })
                XCTAssertEqual(graph.rows[worktreeIndex].node.color,
                               graph.rows[headIndex].node.color,
                               "Badges cannot change node-to-HEAD color")
                window.close()
            }
        }
    }

    func testGraphBadgesUseCompactSharedMetrics() {
        XCTAssertEqual(RecentCommitsView.badgeHeight, 16)
        XCTAssertEqual(RecentCommitsView.badgeIconSize, 16)
        XCTAssertEqual(RecentCommitsView.badgeFontSize, 9)
        XCTAssertEqual(RecentCommitsView.badgeHorizontalPadding, 4)
    }

    func testCleanWorktreeBadgesAreSeparateFromUncommittedChangesInBothThemes() throws {
        let oid = String(repeating: "c", count: 40)
        let main = GitStatusModel.WorktreeLocation(
            path: "/tmp/bailey-main", headOID: oid, branch: "main", isMain: true
        )
        let linked = GitStatusModel.WorktreeLocation(
            path: "/tmp/feature 重名", headOID: oid, branch: "topic"
        )
        let commit = GitStatusModel.RecentCommit(
            hash: oid, shortHash: "ccccccc", subject: "One HEAD, two Worktrees",
            author: "Dev", date: .now, parentHashes: [],
            references: [.init(kind: .currentBranch, name: "main")], files: []
        )
        let graph = GitStatusModel.graphCommits(
            [commit], stashes: [], locations: [main, linked]
        )
        XCTAssertEqual(graph.count, 1, "Clean Worktrees must not insert synthetic DAG nodes")
        XCTAssertEqual(graph[0].checkedOutWorktrees.count, 2)
        XCTAssertEqual(CommitGraphLayout(commits: graph).rows.count, 1)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(180), 260, 430] {
                let calls = WorktreeMenuCalls()
                let window = hostHistory(
                    graph, selection: GraphSelection(), width: width,
                    canActOnWorktrees: true,
                    worktreeAction: { item, action in
                        calls.events.append((item.path, action))
                    }
                )
                defer { window.close() }
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                settle()
                let h = window.frame.height
                let menuEvent = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .rightMouseDown, location: NSPoint(x: 68, y: h - 12),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ))
                let menu = try XCTUnwrap(window.contentView?.menu(for: menuEvent))
                let titles = menu.items.map(\.title)
                XCTAssertTrue(titles.contains(String(localized: "Open Worktree", table: "Git")), "Actual menu: \(titles)")
                XCTAssertTrue(titles.contains(String(localized: "Remove Worktree…", table: "Git")))
                XCTAssertTrue(titles.contains(String(localized: "Copy Worktree Path", table: "Git")))
                XCTAssertFalse(titles.contains(String(localized: "Checkout Commit…", table: "Git")))
                XCTAssertFalse(try XCTUnwrap(menu.items.first(where: {
                    $0.title == String(localized: "Remove Worktree…", table: "Git")
                })).isEnabled, "Main Worktree must not be removable")
                click(NSPoint(x: 68, y: h - 12), in: window)
                XCTAssertTrue(calls.events.contains(where: { $0.0 == main.path && $0.1 == .open }))
            }
        }
    }

    func testUncommittedWorktreeNodeHasSafeMenuAndNativeStageAwareFileActions() throws {
        let head = String(repeating: "a", count: 40)
        let worktree = GitStatusModel.WorktreeChanges(
            path: "/private/tmp/另一个 worktree", branch: "topic/修改", headOID: head,
            entries: [.init(path: "Scripts/更改.swift", staged: "M", unstaged: "M")],
            isCurrent: false
        )
        let commit = GitStatusModel.RecentCommit(
            hash: head, shortHash: String(head.prefix(7)), subject: "Base",
            author: "Tester", date: .now, parentHashes: [],
            references: [.init(kind: .currentBranch, name: "main")], files: []
        )
        let graph = GitStatusModel.graphCommits([commit], stashes: [], worktrees: [worktree])
        let node = try XCTUnwrap(graph.first)
        XCTAssertEqual(node.worktree?.path, worktree.path)
        XCTAssertEqual(graph.count, 2)
        XCTAssertTrue(CommitGraphLayout(commits: graph).rows[0].links.count > 0)
        XCTAssertTrue(RecentCommitsView.nodeHelp(node, inHeadHistory: false).contains(worktree.path))
        XCTAssertFalse(RecentCommitsView.nodeHelp(node, inHeadHistory: false).contains("worktree:" + worktree.path))

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for mode in [GitViewMode.list, .tree] {
                let selection = GraphSelection()
                let height: CGFloat = 380
                var opened: [(path: String, file: String, staged: Bool)] = []
                let window = hostHistory(
                    graph, selection: selection, width: 430, height: height,
                    viewMode: mode,
                    openWorktreeDiff: { tree, entry, staged in
                        opened.append((tree.path, entry.path, staged))
                    }
                )
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                settle()
                let menuEvent = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .rightMouseDown, location: NSPoint(x: 220, y: height - 12),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1
                ))
                let titles = try XCTUnwrap(window.contentView?.menu(for: menuEvent)).items.map(\.title)
                XCTAssertTrue(titles.contains(String(localized: "Copy Worktree Path", table: "Git")))
                XCTAssertFalse(titles.contains(String(localized: "Checkout Commit…", table: "Git")))
                XCTAssertFalse(titles.contains(String(localized: "Reset Current Branch to Commit…", table: "Git")))
                XCTAssertFalse(titles.contains(String(localized: "Apply Stash…", table: "Git")))

                click(NSPoint(x: 245, y: height - 19), in: window)
                XCTAssertTrue(selection.expanded.contains(node.id))
                let row = TreeRowStyle.rowHeight(1)
                // Staged header + first file row. Tree mode adds a folder
                // parent for Scripts; its nested row is one step below.
                let stagedFileY = height - 38 - row - (mode == .tree ? row : 0) - row / 2
                click(NSPoint(x: 255, y: stagedFileY), in: window)
                XCTAssertTrue(opened.contains {
                    $0.path == worktree.path && $0.file == "Scripts/更改.swift" && $0.staged
                }, "Staged diff must target the source checkout, not the displayed repository")
                let unstagedFileY = height - 38 - 3 * row
                    - (mode == .tree ? 2 * row : 0) - row / 2
                click(NSPoint(x: 255, y: unstagedFileY), in: window)
                XCTAssertTrue(opened.contains {
                    $0.path == worktree.path && $0.file == "Scripts/更改.swift" && !$0.staged
                }, "Working changes must not silently open the staged version")
                window.close()
            }
        }
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
