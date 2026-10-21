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

    private func primaryBadgePoint(
        commits: [GitStatusModel.RecentCommit], width: CGFloat, height: CGFloat, scale: CGFloat = 1
    ) -> NSPoint {
        let layout = CommitGraphLayout(commits: commits)
        let spacing = CommitGraphRails.spacing(lanes: layout.laneCount, viewportWidth: width, scale: scale)
        let gutter = CommitGraphRails.gutter(lanes: layout.laneCount, spacing: spacing, scale: scale)
        return NSPoint(x: TreeRowStyle.outerInset + gutter + 10 * scale, y: height - 12 * scale)
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
        resizable: Bool = false, viewMode: GitViewMode = .list,
        remotes: [String] = [], displayedDiff: DiffTab? = nil,
        stashAction: @escaping (GitStatusModel.Stash, GitStatusModel.StashAction) -> Void = { _, _ in },
        openWorktreeDiff: @escaping (GitStatusModel.WorktreeChanges, GitStatusModel.Entry, Bool) -> Void = { _, _, _ in },
        canActOnWorktrees: Bool = false,
        canRevealWorktreeInFinder: Bool = true,
        worktreeAction: @escaping (GitStatusModel.WorktreeLocation, RecentCommitsView.WorktreeAction) -> Void = { _, _ in },
        openDiff: @escaping (GitStatusModel.RecentCommit, GitStatusModel.RecentCommit.FileChange) -> Void = { _, _ in },
        onKeyboardFocused: @escaping () -> Void = {}
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -1200, y: -1200, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RecentCommitsView(
            commits: commits,
            remotes: remotes,
            repoRoot: "/fixture", displayedDiff: displayedDiff,
            fileAction: { _, _, _ in },
            loadBinaryStatus: { _ in }, isBinaryFile: { _, _ in false },
            expandedCommitIDs: Binding(get: { selection.expanded }, set: { selection.expanded = $0 }),
            collapsedFolders: Binding(get: { selection.folders }, set: { selection.folders = $0 }),
            viewMode: viewMode, fontScale: fontScale,
            hasMoreCommits: false, isLoadingMore: false, loadMore: { false },
            openDiff: openDiff, canSwitchBranch: true,
            switchBranch: { _ in }, branchAction: { _, _, _ in }, remoteAction: { _, _, _ in }, tagAction: { _, _, _ in },
            isAnnotatedTag: { _ in false },
            canFetchRemoteBranch: { _ in false }, createBranch: { _ in }, addTag: { _ in },
            canActOnCommit: true, canDropCommit: { _ in false }, commitAction: { _, _ in },
            stashAction: stashAction,
            openWorktreeDiff: openWorktreeDiff,
            canActOnWorktrees: canActOnWorktrees,
            canRevealWorktreeInFinder: canRevealWorktreeInFinder,
            worktreeAction: worktreeAction,
            onKeyboardFocused: onKeyboardFocused
        ).frame(width: resizable ? nil : width, height: height, alignment: .topLeading)
            .background(Color(nsColor: Theme.sidebar)))
        window.orderFront(nil)
        settle()
        return window
    }

    func testDisplayedHistoricalDiffHasGreySelectionIndependentOfGraphFocus() throws {
        let hash = String(repeating: "a", count: 40)
        let file = GitStatusModel.RecentCommit.FileChange(
            status: "M", path: "Sources/alpha.swift", originalPath: nil
        )
        let commit = GitStatusModel.RecentCommit(
            hash: hash, shortHash: "aaaaaaa", subject: "Change file",
            author: "Tester", date: .now, parentHashes: [], references: [], files: [file]
        )
        let displayed = DiffTab(
            repoRoot: "/fixture", path: file.path,
            source: .commit(hash: hash, parent: nil, status: "M"),
            untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: nil
        )
        func render(_ activeDiff: DiffTab?, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
            let selection = GraphSelection()
            selection.expanded.insert(commit.id)
            let window = hostHistory([commit], selection: selection,
                                     width: 420, height: 120, displayedDiff: activeDiff)
            window.appearance = NSAppearance(named: appearance)
            defer { window.close() }
            settle()
            let host = try XCTUnwrap(window.contentView)
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            return image
        }
        func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
            abs(a.redComponent - b.redComponent)
                + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let plain = try render(nil, appearance: appearance)
            let selected = try render(displayed, appearance: appearance)
            let x = plain.pixelsWide * 4 / 5
            let rowY = Int(CGFloat(plain.pixelsHigh) * (38 + 11) / 120)
            let ys = [rowY, plain.pixelsHigh - rowY - 1]
            let changes = ys.compactMap { y -> CGFloat? in
                guard let p = plain.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let s = selected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
                return difference(p, s)
            }
            XCTAssertGreaterThan(changes.max() ?? 0, 0.045,
                "A historical file being displayed needs a grey fill independent of keyboard focus")
        }
    }

    func testExpandedHistoryAndUncommittedNodesHaveNoPersistentSelectionFill() throws {
        typealias Commit = GitStatusModel.RecentCommit
        let hash = String(repeating: "a", count: 40)
        let commit = Commit(
            hash: hash, shortHash: "aaaaaaa", subject: "Changed history",
            author: "Tester", date: .now, parentHashes: [], references: [],
            files: [.init(status: "M", path: "Sources/alpha.swift", originalPath: nil)]
        )
        let worktree = GitStatusModel.WorktreeChanges(
            path: "/tmp/bailey-graph-selection", branch: "main", headOID: hash,
            entries: [.init(path: "Sources/beta.swift", staged: ".", unstaged: "M")],
            isCurrent: true
        )
        let uncommitted = try XCTUnwrap(
            GitStatusModel.graphCommits([commit], stashes: [], worktrees: [worktree])
                .first(where: { $0.worktree != nil })
        )
        let width: CGFloat = 420
        let height: CGFloat = 126

        func capture(
            _ node: Commit, expanded: Bool, appearance: NSAppearance.Name,
            mode: GitViewMode
        ) throws -> NSBitmapImageRep {
            let selection = GraphSelection()
            if expanded { selection.expanded.insert(node.id) }
            let window = hostHistory([node], selection: selection,
                                     width: width, height: height, viewMode: mode)
            defer { window.close() }
            window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
            settle()
            let host = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }

        for node in [commit, uncommitted] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for mode in [GitViewMode.list, .tree] {
                    let collapsed = try capture(node, expanded: false,
                                                appearance: appearance, mode: mode)
                    let expanded = try capture(node, expanded: true,
                                               appearance: appearance, mode: mode)
                    XCTAssertEqual(collapsed.pixelsWide, expanded.pixelsWide)
                    XCTAssertEqual(collapsed.pixelsHigh, expanded.pixelsHigh)
                    // Compare empty space inside the commit header, away from
                    // its text and graph rails. Expanding may add child rows,
                    // but must never tint the parent header like a selected file.
                    for y in [10, 14, 18] {
                        let px = collapsed.pixelsWide * 94 / 100
                        let py = Int(CGFloat(collapsed.pixelsHigh) * CGFloat(y) / height)
                        let a = try XCTUnwrap(collapsed.colorAt(x: px, y: py)?
                            .usingColorSpace(.sRGB))
                        let b = try XCTUnwrap(expanded.colorAt(x: px, y: py)?
                            .usingColorSpace(.sRGB))
                        let difference = abs(a.redComponent - b.redComponent)
                            + abs(a.greenComponent - b.greenComponent)
                            + abs(a.blueComponent - b.blueComponent)
                        XCTAssertLessThan(difference, 0.035,
                            "Expanded \(node.worktree == nil ? "commit" : "worktree") header must match its collapsed background (\(appearance.rawValue), \(mode), y=\(y))")
                    }
                }
            }
        }
    }

    func testGraphReferenceBadgeTakesKeyboardFocusFromAnotherTree() throws {
        let selection = GraphSelection()
        let commit = GitStatusModel.RecentCommit(
            hash: String(repeating: "a", count: 40), shortHash: "aaaaaaa",
            subject: "Reference focus", author: "Tester", date: .now,
            parentHashes: [], references: [.init(kind: .localBranch, name: "topic")], files: []
        )
        let height: CGFloat = 200
        let window = hostHistory([commit], selection: selection, width: 420, height: height)
        defer { window.close() }
        func keyboard(in view: NSView) -> TreeKeyboardView? {
            if let owner = view as? TreeKeyboardView { return owner }
            return view.subviews.lazy.compactMap { keyboard(in: $0) }.first
        }
        let receiver = try XCTUnwrap(keyboard(in: try XCTUnwrap(window.contentView)))
        let old = TreeKeyboardView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        window.contentView?.addSubview(old)
        XCTAssertTrue(window.makeFirstResponder(old))
        click(NSPoint(x: 45, y: height - 19), in: window)
        XCTAssertTrue(selection.expanded.contains(commit.id), "A reference badge must expand the commit")
        XCTAssertTrue(window.firstResponder === receiver,
                      "Clicking a graph reference must hand keyboard focus to Git Graph")
    }

    func testGraphClickRecordsFocusIntentBeforeMovingNativeResponder() throws {
        let selection = GraphSelection()
        let commit = GitStatusModel.RecentCommit(
            hash: String(repeating: "a", count: 40), shortHash: "aaaaaaa",
            subject: "Focus Intent", author: "Tester", date: .now,
            parentHashes: [], references: [], files: []
        )
        var windowForEvent: NSWindow?
        var oldResponder: NSResponder?
        var responderAtIntent: NSResponder?
        var capture = false
        let height: CGFloat = 240
        let window = hostHistory([commit], selection: selection, width: 420, height: height,
            onKeyboardFocused: {
                if capture, responderAtIntent == nil {
                    responderAtIntent = windowForEvent?.firstResponder
                }
            })
        defer { window.close() }
        windowForEvent = window
        let old = TreeKeyboardView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        window.contentView?.addSubview(old)
        XCTAssertTrue(window.makeFirstResponder(old))
        oldResponder = old
        capture = true
        click(NSPoint(x: 150, y: height - 19), in: window)
        XCTAssertTrue(selection.expanded.contains(commit.id))
        XCTAssertTrue(responderAtIntent === oldResponder,
                      "Graph click intent must precede focus transfer, so parent recovery cannot reclaim Changes")
        XCTAssertFalse(window.firstResponder === old)
    }

    func testGraphSpaceUsesTheSelectedCommitAndFileWithoutStealingKeyboard() throws {
        let selection = GraphSelection()
        let historyFile = GitStatusModel.RecentCommit.FileChange(
            status: "M", path: "Sources/alpha.swift", originalPath: nil
        )
        let first = GitStatusModel.RecentCommit(
            hash: String(repeating: "a", count: 40), shortHash: "aaaaaaa", subject: "First commit",
            author: "Tester", date: .now, parentHashes: [], references: [], files: [historyFile]
        )
        let second = GitStatusModel.RecentCommit(
            hash: String(repeating: "b", count: 40), shortHash: "bbbbbbb", subject: "Second commit",
            author: "Tester", date: .now, parentHashes: [], references: [], files: [historyFile]
        )
        var opened: [(String, String)] = []
        let height: CGFloat = 280
        let window = hostHistory(
            [first, second], selection: selection, width: 420, height: height,
            openDiff: { commit, file in opened.append((commit.hash, file.path)) }
        )
        defer { window.close() }
        func keyboard(in view: NSView) -> TreeKeyboardView? {
            if let view = view as? TreeKeyboardView { return view }
            return view.subviews.lazy.compactMap { keyboard(in: $0) }.first
        }
        let receiver = try XCTUnwrap(keyboard(in: try XCTUnwrap(window.contentView)),
                                     "Git Graph must own a native keyboard receiver")
        click(NSPoint(x: 150, y: height - 19), in: window)
        XCTAssertTrue(selection.expanded.contains(first.id), "A single click must expand a commit")
        XCTAssertTrue(window.firstResponder === receiver, "Click must focus Git Graph, not the editor")
        func press(_ keyCode: UInt16, characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ))
            window.sendEvent(event)
            settle()
        }
        try press(125, characters: "\u{F701}")
        try press(49, characters: " ")
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].0, first.hash)
        XCTAssertEqual(opened[0].1, historyFile.path)
        XCTAssertTrue(window.firstResponder === receiver)
        try press(125, characters: "\u{F701}")
        try press(49, characters: " ")
        XCTAssertTrue(selection.expanded.contains(second.id), "Space must toggle the next commit")
        XCTAssertTrue(selection.expanded.contains(first.id), "Selecting must not collapse the prior commit")
        try press(126, characters: "\u{F700}")
        try press(36, characters: "\r")
        XCTAssertEqual(opened.last?.0, first.hash, "Return must browse the historical file")
    }

    func testGraphTreeKeyboardTraversesFoldersAndBothHistoricalFiles() throws {
        let selection = GraphSelection()
        let files = [
            GitStatusModel.RecentCommit.FileChange(
                status: "M", path: "nested/alpha.swift", originalPath: nil),
            GitStatusModel.RecentCommit.FileChange(
                status: "A", path: "nested/beta.swift", originalPath: nil),
        ]
        let commit = GitStatusModel.RecentCommit(
            hash: String(repeating: "a", count: 40), shortHash: "aaaaaaa",
            subject: "Nested history", author: "Tester", date: .now,
            parentHashes: [], references: [], files: files
        )
        var opened: [String] = []
        let height: CGFloat = 280
        let window = hostHistory([commit], selection: selection,
                                 width: 420, height: height, viewMode: .tree,
                                 openDiff: { _, file in opened.append(file.path) })
        defer { window.close() }
        func keyboard(in view: NSView) -> TreeKeyboardView? {
            if let view = view as? TreeKeyboardView { return view }
            return view.subviews.lazy.compactMap { keyboard(in: $0) }.first
        }
        let receiver = try XCTUnwrap(keyboard(in: try XCTUnwrap(window.contentView)))
        click(NSPoint(x: 150, y: height - 19), in: window)
        XCTAssertTrue(selection.expanded.contains(commit.id))
        XCTAssertTrue(window.firstResponder === receiver)
        func press(_ keyCode: UInt16, characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ))
            window.sendEvent(event)
            settle()
        }
        try press(125, characters: "\u{F701}") // Enter nested folder row.
        try press(124, characters: "\u{F703}") // Select its first visible child.
        try press(49, characters: " ")
        XCTAssertEqual(opened, ["nested/alpha.swift"])
        try press(125, characters: "\u{F701}")
        try press(36, characters: "\r")
        XCTAssertEqual(opened, ["nested/alpha.swift", "nested/beta.swift"])
        try press(123, characters: "\u{F702}") // Select folder.
        try press(123, characters: "\u{F702}") // Collapse folder, not the commit.
        XCTAssertTrue(selection.folders.contains("commit:" + commit.id + ":nested"))
        XCTAssertTrue(selection.expanded.contains(commit.id))
        XCTAssertTrue(window.firstResponder === receiver)
    }

    func testGraphPaletteKeepsTwelveLaneColors() {
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

    func testColoredBadgeIconsRemainReadableOverEveryGraphLaneColor() {
        func luminance(_ color: NSColor) -> CGFloat {
            let rgb = color.usingColorSpace(.sRGB)!
            func linear(_ channel: CGFloat) -> CGFloat {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent)
                + 0.7152 * linear(rgb.greenComponent)
                + 0.0722 * linear(rgb.blueComponent)
        }
        XCTAssertEqual(GitGraphPalette.iconInks.count, GitGraphPalette.colors.count)
        for (index, fill) in GitGraphPalette.colors.enumerated() {
            let ink = GitGraphPalette.iconInks[index]
            let lighter = max(luminance(fill), luminance(ink))
            let darker = min(luminance(fill), luminance(ink))
            XCTAssertGreaterThanOrEqual((lighter + 0.05) / (darker + 0.05), 4.5,
                                        "Graph lane \(index) badge icon contrast")
        }
    }

    func testTagStashDetachedAndStandaloneWorktreeIconsMatchGraphColors() throws {
        typealias Commit = GitStatusModel.RecentCommit
        let taggedHash = String(repeating: "a", count: 40)
        let detachedHash = String(repeating: "b", count: 40)
        let standaloneHash = String(repeating: "c", count: 40)
        let stashHash = String(repeating: "d", count: 40)
        let commits: [Commit] = [
            .init(hash: taggedHash, shortHash: "aaaaaaa", subject: "Tagged",
                  author: "Tester", date: .now, parentHashes: [],
                  references: [.init(kind: .tag, name: "v1.0")], files: []),
            .init(hash: detachedHash, shortHash: "bbbbbbb", subject: "Detached HEAD",
                  author: "Tester", date: .now, parentHashes: [],
                  references: [.init(kind: .detachedHead, name: "HEAD")], files: []),
            .init(hash: standaloneHash, shortHash: "ccccccc", subject: "No Ref",
                  author: "Tester", date: .now, parentHashes: [],
                  references: [], files: []),
        ]
        let stash = GitStatusModel.Stash(
            selector: "stash@{0}", oid: stashHash, message: "Saved edits",
            baseHash: taggedHash, untrackedFilesHash: nil,
            author: "Tester", date: .now
        )
        let locations: [GitStatusModel.WorktreeLocation] = [
            .init(path: "/tmp/worktree-detached", headOID: detachedHash, branch: nil),
            .init(path: "/tmp/worktree-no-ref", headOID: standaloneHash, branch: nil),
        ]
        let rows = GitStatusModel.graphCommits(
            commits, stashes: [stash], locations: locations
        )
        XCTAssertEqual(rows.count, 4)
        let layout = CommitGraphLayout(commits: rows)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(180), 320] {
                let window = hostHistory(
                    rows, selection: GraphSelection(), width: width, height: 230
                )
                defer { window.close() }
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                settle()
                let view = try XCTUnwrap(window.contentView)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / width
                let spacing = CommitGraphRails.spacing(
                    lanes: layout.laneCount, viewportWidth: width, scale: 1
                )
                let gutter = CommitGraphRails.gutter(
                    lanes: layout.laneCount, spacing: spacing, scale: 1
                )
                let x = Int((TreeRowStyle.outerInset + gutter + 3) * scale)
                for (index, commit) in rows.enumerated() {
                    let y = Int((CGFloat(index) * 38 + 10) * scale)
                    let paint = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?
                        .usingColorSpace(.sRGB))
                    let lane = layout.rows[index].node.color
                    XCTAssertGreaterThanOrEqual(lane, 0)
                    let expected = GitGraphPalette.colors[lane % GitGraphPalette.colors.count]
                    let channels = [paint.redComponent, paint.greenComponent,
                                    paint.blueComponent]
                    XCTAssertGreaterThan(channels.max()! - channels.min()!, 0.25,
                                         "\(commit.id) icon must not be gray")
                    let delta = abs(paint.hueComponent - expected.hueComponent)
                    XCTAssertLessThan(min(delta, 1 - delta), 0.08,
                                      "\(commit.id) badge must match Git lane color")
                }
            }
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
        let topic = try XCTUnwrap(groups.first { $0.primary.name == "topic/nested" })
        XCTAssertEqual(topic.remotes.map(\.name), ["origin/team/topic/nested"])
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

    func testCompactPrimaryBranchTogglesCommitAndKeepsContextMenu() throws {
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
        let point = NSPoint(x: 52, y: height - 12)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("unchanged", forType: .string)
        click(point, in: window)
        XCTAssertEqual(selection.expanded, [commit.id])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "unchanged")
        click(point, in: window)
        XCTAssertTrue(selection.expanded.isEmpty)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
        let titles = try XCTUnwrap(window.contentView?.menu(for: event)).items.map(\.title)
        XCTAssertTrue(titles.contains(String(localized: "Rename Branch…", table: "Git")))
        XCTAssertTrue(titles.contains(String(localized: "Copy Branch Name", table: "Git")))
        XCTAssertFalse(titles.contains(String(localized: "Delete Remote Branch…", table: "Git")))
        let refs = GitGraphReferenceGroup.grouped(commit.references, remotes: ["origin", "upstream"])
        XCTAssertEqual(refs[0].remotes.count, 2)
        XCTAssertEqual(refs.flatMap(\.references).count, commit.references.count,
                       "Secondary remote refs and Tag must remain available in overflow")
    }

    func testShortPrimaryBranchBadgeKeepsIntrinsicWidth() throws {
        let commit = GitStatusModel.RecentCommit(
            hash: String(repeating: "a", count: 40), shortHash: "aaaaaaa",
            subject: "Commit subject remains visible", author: "Developer",
            date: .now, parentHashes: [],
            references: [
                .init(kind: .currentBranch, name: "main"),
                .init(kind: .remoteBranch, name: "origin/main"),
                .init(kind: .tag, name: "v1.0"),
            ], files: []
        )
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(320), 520] {
                let window = hostHistory(
                    [commit], selection: GraphSelection(), width: width,
                    height: 160, remotes: ["origin"]
                )
                defer { window.close() }
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                settle()

                let view = try XCTUnwrap(window.contentView)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let colorfulFarRight = stride(
                    from: 180, through: Int(width) - 40, by: 2
                ).contains { x in
                    (0..<40).contains { y in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                        else { return false }
                        let channels = [color.redComponent, color.greenComponent,
                                        color.blueComponent]
                        return channels.max()! - channels.min()! > 0.35
                    }
                }
                XCTAssertFalse(
                    colorfulFarRight,
                    "Short Branch must not stretch across \(width)pt in \(appearance.rawValue)"
                )
            }
        }
    }

    func testPrimaryBranchContextMenuRemainsAvailableThroughWidthChanges() throws {
        let branch = "feature/" + String(repeating: "long-", count: 12)
        let commit = GitStatusModel.RecentCommit(
            hash: "width-change", shortHash: "width", subject: "Commit title",
            author: "Developer", date: .now, parentHashes: [],
            references: [
                .init(kind: .currentBranch, name: branch),
                .init(kind: .remoteBranch, name: "origin/" + branch),
                .init(kind: .tag, name: "v1.0"),
            ], files: []
        )
        let selection = GraphSelection()
        let height: CGFloat = 160
        let window = hostHistory(
            [commit], selection: selection, width: 520, height: height,
            resizable: true, remotes: ["origin"]
        )
        defer { window.close() }

        for width in [CGFloat(520), 180, 120, 320, 120] {
            window.setContentSize(NSSize(width: width, height: height))
            settle()
            let primaryMenuFound = stride(from: 20, through: Int(width - 8), by: 4).contains { x in
                guard let event = NSEvent.mouseEvent(
                    with: .rightMouseDown,
                    location: NSPoint(x: CGFloat(x), y: height - 12),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ) else { return false }
                let titles = window.contentView?.menu(for: event)?.items.map(\.title) ?? []
                return titles.contains(String(localized: "Copy Branch Name", table: "Git"))
                    && titles.contains(String(localized: "Rename Branch…", table: "Git"))
            }
            XCTAssertTrue(primaryMenuFound, "Primary Branch actions disappeared at \(width)pt")
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
        let cases: [(GitStatusModel.RecentCommit.Reference.Kind, String, String, String)] = [
            (.currentBranch, "main", String(localized: "Rename Branch…", table: "Git"),
             String(localized: "Copy Branch Name", table: "Git")),
            (.localBranch, "topic", String(localized: "Delete Branch…", table: "Git"),
             String(localized: "Copy Branch Name", table: "Git")),
            (.remoteBranch, "origin/topic", String(localized: "Delete Remote Branch…", table: "Git"),
             String(localized: "Copy Remote Branch Name", table: "Git")),
            (.tag, "v1.2.3", String(localized: "Delete Tag…", table: "Git"),
             String(localized: "Copy Tag Name", table: "Git")),
        ]
        for (kind, name, expected, copyTitle) in cases {
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
            XCTAssertTrue(titles.contains(copyTitle), "\(name): Copy must remain in the context menu")
            XCTAssertFalse(titles.contains(String(localized: "Create Branch at Commit…", table: "Git")), name)
            XCTAssertTrue(selection.expanded.isEmpty, "Requesting a context menu must not trigger a left action")
            let copyIndex = try XCTUnwrap(menu.items.firstIndex(where: { $0.title == copyTitle }))
            NSPasteboard.general.clearContents()
            menu.performActionForItem(at: copyIndex)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), name,
                           "\(name): Context menu must still copy the selected reference")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("unchanged", forType: .string)
            click(NSPoint(x: 50, y: height - 12), in: window)
            XCTAssertEqual(selection.expanded, [commit.id], "\(name) must expand the selected commit")
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "unchanged")
            click(NSPoint(x: 50, y: height - 12), in: window)
            XCTAssertTrue(selection.expanded.isEmpty, "\(name) must collapse the selected commit")
        }
    }

    func testDetachedHeadBadgeExpandsCommitAndKeepsCopyHashInMenu() throws {
        let commit = GitStatusModel.RecentCommit(
            hash: String(repeating: "f", count: 40), shortHash: "fffffff",
            subject: "Detached revision", author: "Developer", date: .now,
            parentHashes: [],
            references: [.init(kind: .detachedHead, name: "HEAD")], files: []
        )
        let selection = GraphSelection()
        let height: CGFloat = 120
        let window = hostHistory([commit], selection: selection, height: height)
        defer { window.close() }
        let point = NSPoint(x: 50, y: height - 12)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let titles = try XCTUnwrap(window.contentView?.menu(for: event)).items.map(\.title)
        XCTAssertTrue(titles.contains(String(localized: "Copy Commit Hash", table: "Git")))
        XCTAssertFalse(titles.contains(String(localized: "Checkout Commit…", table: "Git")))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("unchanged", forType: .string)
        click(point, in: window)
        XCTAssertEqual(selection.expanded, [commit.id])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "unchanged")
        click(point, in: window)
        XCTAssertTrue(selection.expanded.isEmpty)
    }

    func testSymbolicRemoteAliasOnlyCopiesFromMenuAndTogglesCommit() throws {
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("unchanged", forType: .string)
        click(point, in: window)
        XCTAssertEqual(selection.expanded, [commit.id])
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "unchanged")
        click(point, in: window)
        XCTAssertTrue(selection.expanded.isEmpty)
    }

    func testDirtyWorktreeDoesNotRepeatLongBranchBadgeInNarrowSidebar() throws {
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
                let selection = GraphSelection()
                let window = hostHistory(rows, selection: selection,
                                         width: width, height: 175, fontScale: scale)
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                settle()
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .rightMouseDown, location: NSPoint(x: 68, y: 163),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ))
                let menu = try XCTUnwrap(window.contentView?.menu(for: event))
                XCTAssertEqual(menu.items.map(\.title),
                               [String(localized: "Copy Worktree Path", table: "Git")],
                               "Dirty node has no duplicate Branch badge or unrelated actions")
                click(NSPoint(x: 68, y: 163), in: window)
                XCTAssertEqual(selection.expanded, [rows[0].id])
                XCTAssertFalse(horizontallyScrollableViews(in: window.contentView!).contains {
                    $0.contentView.bounds.height > 60 * scale
                        && ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 10
                }, "A long branch name must not turn the dirty node into a scrolling header")
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

    func testDenseWorktreeGraphKeepsCommitTitlesReadableAcrossThemes() throws {
        typealias Commit = GitStatusModel.RecentCommit
        let design = String(repeating: "a", count: 40)
        let feature = String(repeating: "b", count: 40)
        let backup = String(repeating: "c", count: 40)
        let commits: [Commit] = [
            .init(hash: design, shortHash: "aaaaaaa", subject: "重做原生两栏",
                  author: "Developer", date: .now, parentHashes: [backup],
                  references: [.init(kind: .localBranch, name: "feat/issue-11-settings-redesign")],
                  files: []),
            .init(hash: feature, shortHash: "bbbbbbb", subject: "统一 Worktree 标签单击行为",
                  author: "Developer", date: .now, parentHashes: [backup],
                  references: [
                    .init(kind: .localBranch, name: "feat/issue-33-worktree-graph"),
                    .init(kind: .tag, name: "v0.1.0"),
                ], files: []),
            .init(hash: backup, shortHash: "ccccccc", subject: "收敛原生编辑器文档",
                  author: "Developer", date: .now, parentHashes: [],
                  references: [
                    .init(kind: .currentBranch, name: "backup/local-main-20261019"),
                    .init(kind: .remoteBranch, name: "origin/backup/local-main-20261019"),
                ], files: []),
        ]
        let locations: [GitStatusModel.WorktreeLocation] = [
            .init(path: "/tmp/Bailey-settings-redesign", headOID: design,
                  branch: "feat/issue-11-settings-redesign"),
            .init(path: "/tmp/Bailey-issue-33-worktree-graph", headOID: feature,
                  branch: "feat/issue-33-worktree-graph"),
            .init(path: "/tmp/Bailey-issue-33-other", headOID: feature, branch: "topic"),
            .init(path: "/tmp/Bailey-issue-33-detached", headOID: feature, branch: nil),
            .init(path: "/tmp/Bailey", headOID: backup,
                  branch: "backup/local-main-20261019", isMain: true),
        ]
        let dirty = [
            GitStatusModel.WorktreeChanges(
                path: locations[0].path, branch: locations[0].branch, headOID: design,
                entries: [.init(path: "Settings.swift", staged: ".", unstaged: "M")],
                isCurrent: false),
            GitStatusModel.WorktreeChanges(
                path: locations[1].path, branch: locations[1].branch, headOID: feature,
                entries: [.init(path: "Graph.swift", staged: "M", unstaged: ".")],
                isCurrent: false),
            GitStatusModel.WorktreeChanges(
                path: locations[4].path, branch: locations[4].branch, headOID: backup,
                entries: [.init(path: "Editor.swift", staged: ".", unstaged: "M")],
                isCurrent: true),
        ]
        let rows = GitStatusModel.graphCommits(
            commits, stashes: [], worktrees: dirty, locations: locations
        )
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.filter { $0.worktree != nil }.count, 3)
        XCTAssertEqual(rows.first { $0.hash == feature }?.checkedOutWorktrees.count, 3)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(360), 520] {
                let window = hostHistory(
                    rows, selection: GraphSelection(), width: width, height: 310,
                    remotes: ["origin"], canActOnWorktrees: true
                )
                defer { window.close() }
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                settle()
                XCTAssertFalse(horizontallyScrollableViews(in: window.contentView!).contains {
                    $0.contentView.bounds.height > 60
                        && ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 10
                }, "Dense graph must not become a horizontally scrolling table")

                let view = try XCTUnwrap(window.contentView)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let layout = CommitGraphLayout(commits: rows)
                let pixelScale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                let laneSpacing = CommitGraphRails.spacing(
                    lanes: layout.laneCount, viewportWidth: width, scale: 1
                )
                let gutter = CommitGraphRails.gutter(
                    lanes: layout.laneCount, spacing: laneSpacing, scale: 1
                )
                // Read the colored badge background, not the SF Symbol glyph.
                // Raster coordinates and row heights differ across macOS runners.
                let iconX = Int(
                    (TreeRowStyle.outerInset + gutter + 3) * pixelScale
                )
                let requiredPixels = max(3, Int(3 * pixelScale))
                var nextY = 0
                for (index, commit) in rows.enumerated()
                    where commit.worktree == nil && commit.stash == nil {
                    let expected = GitGraphPalette.colors[layout.rows[index].node.color]
                    let expectedChannels = [expected.redComponent, expected.greenComponent,
                                            expected.blueComponent]
                    let dominant = expectedChannels.firstIndex(of: expectedChannels.max()!)
                    var matchingPixels = 0
                    var found = false
                    for y in nextY..<bitmap.pixelsHigh {
                        guard let pixel = bitmap.colorAt(x: iconX, y: y)?.usingColorSpace(.sRGB)
                        else { matchingPixels = 0; continue }
                        let channels = [pixel.redComponent, pixel.greenComponent,
                                        pixel.blueComponent]
                        let hueDelta = abs(pixel.hueComponent - expected.hueComponent)
                        if channels.max()! - channels.min()! > 0.25,
                           channels.firstIndex(of: channels.max()!) == dominant,
                           min(hueDelta, 1 - hueDelta) < 0.08 {
                            matchingPixels += 1
                            if matchingPixels >= requiredPixels {
                                nextY = y + 1
                                found = true
                                break
                            }
                        } else {
                            matchingPixels = 0
                        }
                    }
                    XCTAssertTrue(found, "Reference badge must match lane color at row \(index)")
                }
                if let directory = ProcessInfo.processInfo.environment["BAILEY_GIT_GRAPH_SCREENSHOT_DIR"] {
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let name = "git-graph-compact-\(Int(width))-\(appearance.rawValue).png"
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
        }
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

    func testLocalBranchTakesPriorityOverRemoteDefaultAliasWithoutLosingReferences() {
        typealias Reference = GitStatusModel.RecentCommit.Reference
        let references: [Reference] = [
            .init(kind: .remoteAlias, name: "origin/HEAD"),
            .init(kind: .remoteBranch, name: "origin/main"),
            .init(kind: .localBranch, name: "main"),
            .init(kind: .tag, name: "v1"),
        ]
        let groups = GitGraphReferenceGroup.grouped(references, remotes: ["origin"])
        XCTAssertEqual(groups.first?.primary.name, "main")
        XCTAssertEqual(Set(groups.flatMap(\.references)), Set(references))
        let current = Reference(kind: .currentBranch, name: "topic")
        XCTAssertEqual(GitGraphReferenceGroup.grouped(references + [current], remotes: ["origin"])
            .first?.primary, current)
        let detached = Reference(kind: .detachedHead, name: "HEAD")
        XCTAssertEqual(GitGraphReferenceGroup.grouped(references + [detached], remotes: ["origin"])
            .first?.primary, detached)
        let feature = Reference(kind: .localBranch, name: "feature")
        let location = GitStatusModel.WorktreeLocation(path: "/fixture/feature", headOID: nil, branch: "feature")
        let checkedOut = GitGraphReferenceGroup.grouped(
            references + [feature], remotes: ["origin"], worktrees: [location]
        )
        XCTAssertEqual(checkedOut.first?.primary, feature)
        XCTAssertEqual(Set(checkedOut.flatMap(\.references)), Set(references + [feature]))
    }

    func testUnassociatedWorktreeLabelChineseTranslationPreservesDirectoryName() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        let pattern = bundle.localizedString(forKey: "%@ · No branch", value: nil, table: "Git")
        XCTAssertEqual(String(format: pattern, "a904/Bailey"), "a904/Bailey · 未关联分支")
    }

    func testRealWorktreeHistoryRendersNamedLabelsAndPreservesSharedHeadActions() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-worktree-label-" + UUID().uuidString)
        let main = fixture.appendingPathComponent("main/Bailey")
        let detached = fixture.appendingPathComponent("a904/Bailey")
        let shared = fixture.appendingPathComponent("b905/Bailey")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        func git(_ args: [String], at path: URL = main) throws -> String {
            let result = GitCommandExecution.run(args, in: path.path, timeout: 10)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Label Test"])
        _ = try git(["config", "user.email", "labels@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["commit", "--allow-empty", "-qm", "base"])
        let base = try git(["rev-parse", "HEAD"])
        _ = try git(["worktree", "add", "-q", "--detach", detached.path, base])
        _ = try git(["commit", "--allow-empty", "-qm", "independent worktree commit"], at: detached)
        let tip = try git(["rev-parse", "HEAD"], at: detached)
        _ = try git(["worktree", "add", "-q", "--detach", shared.path, tip])
        let model = GitStatusModel()
        model.sync(root: main.path)
        let deadline = Date().addingTimeInterval(12)
        while !model.hasResolvedStatus || model.isRefreshing {
            guard Date() < deadline else { XCTFail("Worktree history did not load"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let rows = model.graphCommits
        XCTAssertEqual(Set(model.recentCommits.map(\.hash)), Set([base, tip]))
        XCTAssertEqual(rows.first { $0.hash == tip }?.checkedOutWorktrees.count, 2)
        XCTAssertTrue(rows.first { $0.hash == tip }?.references.isEmpty == true)
        let selection = GraphSelection()
        let calls = WorktreeMenuCalls()
        let window = hostHistory(rows, selection: selection, width: 420, canActOnWorktrees: true,
                                 worktreeAction: { calls.events.append(($0.path, $1)) })
        defer { window.close() }
        let view = try XCTUnwrap(window.contentView)
        let locations = try XCTUnwrap(rows.first { $0.hash == tip }?.checkedOutWorktrees)
        let primary = try XCTUnwrap(locations.first { $0.path == main.path }
            ?? locations.first { $0.branch == nil } ?? locations.first)
        XCTAssertEqual(primary.path, detached.path)
        let label = RecentCommitsView.worktreeDisplayLabel(
            primary, among: ["/fixture", main.path, detached.path, shared.path]
        )
        XCTAssertTrue(label.contains("a904/Bailey"), label)
        XCTAssertTrue(label.contains("No branch") || label.contains("未关联分支"), label)
        let point = primaryBadgePoint(commits: rows, width: 420, height: window.frame.height)
        click(point, in: window)
        XCTAssertEqual(selection.expanded, [tip])
        XCTAssertTrue(calls.events.isEmpty)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(view.menu(for: event))
        XCTAssertEqual(Set(menu.items.map(\.title)), Set(["a904/Bailey", "b905/Bailey"]))
        let firstMenu = try XCTUnwrap(menu.items.first { $0.title == "a904/Bailey" }?.submenu)
        let openIndex = try XCTUnwrap(firstMenu.items.firstIndex {
            $0.title == String(localized: "Open Worktree", table: "Git")
        })
        firstMenu.performActionForItem(at: openIndex)
        XCTAssertEqual(calls.events.first?.0, try git(["rev-parse", "--show-toplevel"], at: detached))
        XCTAssertEqual(calls.events.first?.1, .open)
        XCTAssertEqual(try git(["for-each-ref", "--contains", tip]), "")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), base)
    }

    func testWorktreePrimaryLabelsReplaceAliasAndIconOnlyCombinations() throws {
        typealias Commit = GitStatusModel.RecentCommit
        let tip = String(repeating: "a", count: 40)
        let base = String(repeating: "b", count: 40)
        for state in ["unreferenced", "detached", "alias", "branch"] {
            let path = "/fixture/a904/Bailey"
            let branch: String? = state == "branch" ? "main" : nil
            let references: [Commit.Reference] = state == "detached"
                ? [.init(kind: .detachedHead, name: "HEAD")]
                : state == "unreferenced" ? [] : [
                    .init(kind: .remoteAlias, name: "origin/HEAD"),
                    .init(kind: .localBranch, name: "main"),
                    .init(kind: .remoteBranch, name: "origin/main"),
                ]
            let commits: [Commit] = [
                .init(hash: tip, shortHash: "aaaaaaa", subject: "Worktree change",
                      author: "Dev", date: .now, parentHashes: [base], references: references, files: []),
                .init(hash: base, shortHash: "bbbbbbb", subject: "Base",
                      author: "Dev", date: .now, parentHashes: [], references: [], files: []),
            ]
            let locations: [GitStatusModel.WorktreeLocation] = [
                .init(path: path, headOID: tip, branch: branch),
                .init(path: "/fixture/main/Bailey", headOID: base, branch: "base", isMain: true),
            ]
            let graph = GitStatusModel.graphCommits(commits, stashes: [], locations: locations)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for width in [CGFloat(180), 360] {
                    for scale in [CGFloat(1), 1.5] {
                        let selection = GraphSelection()
                        let window = hostHistory(graph, selection: selection, width: width,
                                                 height: 190, fontScale: scale, remotes: ["origin"])
                        defer { window.close() }
                        window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                        settle()
                        let view = try XCTUnwrap(window.contentView)
                        if width == 360 {
                            let row = try XCTUnwrap(graph.first { $0.hash == tip })
                            let groups = GitGraphReferenceGroup.grouped(
                                row.references, remotes: ["origin"], worktrees: row.checkedOutWorktrees
                            )
                            if branch != nil {
                                XCTAssertEqual(groups.first?.primary.name, "main", state)
                            } else {
                                let location = try XCTUnwrap(row.checkedOutWorktrees.first)
                                let label = RecentCommitsView.worktreeDisplayLabel(
                                    location, among: ["/fixture"] + locations.map(\.path)
                                )
                                XCTAssertTrue(label.contains("a904/Bailey"), "\(state): \(label)")
                                XCTAssertTrue(label.contains("No branch") || label.contains("未关联分支"), label)
                            }
                            XCTAssertFalse(groups.first?.primary.name == "origin/HEAD", state)
                        }
                        let point = primaryBadgePoint(commits: graph, width: width,
                                                      height: window.frame.height, scale: scale)
                        click(point, in: window)
                        XCTAssertEqual(selection.expanded, [tip])
                        click(point, in: window)
                        XCTAssertTrue(selection.expanded.isEmpty)
                        if let directory = ProcessInfo.processInfo.environment["BAILEY_GIT_GRAPH_SCREENSHOT_DIR"], scale == 1 {
                            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(
                                "worktree-\(state)-\(appearance.rawValue)-\(Int(width)).png"))
                        }
                    }
                }
            }
        }
    }

    func testDetachedAndUnreferencedWorktreesRetainNativeActionsWithoutDuplicatePills() throws {
        let oid = String(repeating: "d", count: 40)
        for (hasHEADRef, isMain) in [(false, false), (true, true)] {
            let location = GitStatusModel.WorktreeLocation(
                path: "/tmp/standalone-detached", headOID: oid,
                branch: nil, isMain: isMain
            )
            let commit = GitStatusModel.RecentCommit(
                hash: oid, shortHash: "ddddddd", subject: "Detached revision",
                author: "Dev", date: .now, parentHashes: [],
                references: hasHEADRef ? [.init(kind: .detachedHead, name: "HEAD")] : [],
                files: []
            )
            let graph = GitStatusModel.graphCommits(
                [commit], stashes: [], locations: [location]
            )
            let calls = WorktreeMenuCalls()
            let selection = GraphSelection()
            let window = hostHistory(
                graph, selection: selection, width: 300, height: 150,
                canActOnWorktrees: true, canRevealWorktreeInFinder: false,
                worktreeAction: { item, action in calls.events.append((item.path, action)) }
            )
            defer { window.close() }
            let point = NSPoint(x: hasHEADRef ? 48 : 30,
                                y: window.frame.height - 12)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let menu = try XCTUnwrap(window.contentView?.menu(for: event))
            if let directory = ProcessInfo.processInfo.environment["BAILEY_GIT_GRAPH_SCREENSHOT_DIR"] {
                let view = try XCTUnwrap(window.contentView)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = hasHEADRef ? "detached-ref.png" : "detached-no-ref.png"
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
            let actions: NSMenu
            if hasHEADRef {
                XCTAssertTrue(menu.items.map(\.title).contains(
                    String(localized: "Copy Commit Hash", table: "Git")))
                let item = try XCTUnwrap(menu.items.first {
                    $0.title == String(localized: "Worktree", table: "Git")
                })
                actions = try XCTUnwrap(item.submenu)
            } else {
                actions = menu
            }
            XCTAssertTrue(actions.items.map(\.title).contains(
                String(localized: "Open Worktree", table: "Git")),
                "hasHEADRef=\(hasHEADRef), root=\(menu.items.map(\.title)), actions=\(actions.items.map(\.title))")
            XCTAssertFalse(actions.items.map(\.title).contains(
                String(localized: "Reveal in Finder", table: "Git")),
                "SSH-backed Worktrees must not offer Finder")
            let remove = try XCTUnwrap(actions.items.first {
                $0.title == String(localized: "Remove Worktree…", table: "Git")
            })
            XCTAssertEqual(remove.isEnabled, !isMain)
            let openIndex = try XCTUnwrap(actions.items.firstIndex {
                $0.title == String(localized: "Open Worktree", table: "Git")
            })
            actions.performActionForItem(at: openIndex)
            XCTAssertTrue(calls.events.contains {
                $0.0 == location.path && $0.1 == .open
            })
            click(point, in: window)
            XCTAssertEqual(selection.expanded, [commit.id])
            click(point, in: window)
            XCTAssertTrue(selection.expanded.isEmpty)
        }
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
                let selection = GraphSelection()
                let window = hostHistory(
                    graph, selection: selection, width: width,
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
                XCTAssertTrue(titles.contains(String(localized: "Rename Branch…", table: "Git")),
                              "Worktree must share its matching Branch badge: \(titles)")
                XCTAssertFalse(titles.contains(String(localized: "Open Worktree", table: "Git")),
                               "Worktree actions belong in a nested branch menu")
                let item = try XCTUnwrap(menu.items.first {
                    $0.title == String(localized: "Worktree", table: "Git")
                })
                let worktreeMenu = try XCTUnwrap(item.submenu)
                XCTAssertEqual(Set(worktreeMenu.items.map(\.title)),
                               Set(["bailey-main", "feature 重名"]),
                               "One compact branch badge must retain both distinct Worktrees")
                let mainActions = try XCTUnwrap(worktreeMenu.items.first {
                    $0.title == "bailey-main"
                }?.submenu)
                let mainTitles = mainActions.items.map(\.title)
                XCTAssertTrue(mainTitles.contains(String(localized: "Open Worktree", table: "Git")))
                XCTAssertTrue(mainTitles.contains(String(localized: "Copy Worktree Path", table: "Git")))
                XCTAssertFalse(try XCTUnwrap(mainActions.items.first(where: {
                    $0.title == String(localized: "Remove Worktree…", table: "Git")
                })).isEnabled, "Main Worktree must not be removable")
                let copyIndex = try XCTUnwrap(mainActions.items.firstIndex(where: {
                    $0.title == String(localized: "Copy Worktree Path", table: "Git")
                }))
                NSPasteboard.general.clearContents()
                mainActions.performActionForItem(at: copyIndex)
                XCTAssertEqual(NSPasteboard.general.string(forType: .string), main.path)
                let linkedActions = try XCTUnwrap(worktreeMenu.items.first {
                    $0.title == "feature 重名"
                }?.submenu)
                XCTAssertTrue(try XCTUnwrap(linkedActions.items.first(where: {
                    $0.title == String(localized: "Remove Worktree…", table: "Git")
                })).isEnabled)
                let linkedCopy = try XCTUnwrap(linkedActions.items.firstIndex(where: {
                    $0.title == String(localized: "Copy Worktree Path", table: "Git")
                }))
                NSPasteboard.general.clearContents()
                linkedActions.performActionForItem(at: linkedCopy)
                XCTAssertEqual(NSPasteboard.general.string(forType: .string), linked.path)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("unchanged", forType: .string)
                click(NSPoint(x: 68, y: h - 12), in: window)
                XCTAssertEqual(selection.expanded, [commit.id],
                               "The main Worktree badge must expand the actual commit")
                XCTAssertEqual(NSPasteboard.general.string(forType: .string), "unchanged")
                XCTAssertTrue(calls.events.isEmpty, "Badge click must not open a project")
                click(NSPoint(x: 68, y: h - 12), in: window)
                XCTAssertTrue(selection.expanded.isEmpty)
                if width == 430 {
                    click(NSPoint(x: 135, y: h - 12), in: window)
                    XCTAssertEqual(selection.expanded, [commit.id],
                                   "Another Worktree at the same HEAD must expand that commit")
                    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "unchanged")
                    XCTAssertTrue(calls.events.isEmpty)
                    click(NSPoint(x: 135, y: h - 12), in: window)
                    XCTAssertTrue(selection.expanded.isEmpty)
                }
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

                func graphKeyboard(in view: NSView) -> TreeKeyboardView? {
                    if let keyboard = view as? TreeKeyboardView { return keyboard }
                    return view.subviews.lazy.compactMap { graphKeyboard(in: $0) }.first
                }
                let receiver = try XCTUnwrap(graphKeyboard(in: try XCTUnwrap(window.contentView)))
                XCTAssertTrue(window.firstResponder === receiver,
                              "Clicking a worktree file must focus Git Graph")
                func press(_ keyCode: UInt16, _ chars: String) throws {
                    let event = try XCTUnwrap(NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        characters: chars, charactersIgnoringModifiers: chars,
                        isARepeat: false, keyCode: keyCode
                    ))
                    window.sendEvent(event)
                    settle()
                }
                try press(126, "\u{F700}") // Up: previous folder (tree) or staged file (list)
                if mode == .tree { try press(126, "\u{F700}") }
                try press(49, " ")
                XCTAssertTrue(opened.last?.staged == true,
                              "Space must browse the selected staged side even for identical paths")
                XCTAssertEqual(opened.last?.path, worktree.path)
                XCTAssertTrue(window.firstResponder === receiver)
                if mode == .tree {
                    try press(126, "\u{F700}") // The staged directory
                    try press(123, "\u{F702}") // Left collapses
                    let key = "worktree:" + worktree.path + ":staged:Scripts"
                    XCTAssertTrue(selection.folders.contains(key))
                    try press(124, "\u{F703}") // Right expands
                    XCTAssertFalse(selection.folders.contains(key))
                }
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

    func testTagBadgeTogglesSameCommitAsOtherReferences() {
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
        XCTAssertFalse(selection.expanded.contains(commit.hash),
                       "Clicking Tag again must collapse the same commit")
    }
}
