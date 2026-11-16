import AppKit
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
final class GitPanelVisibilityTests: XCTestCase {
    func testGraphRemainsVisibleAfterResizeChangesAndHistoryRewrite() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-GitVisibility-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: repository.path)
            guard result.status == 0 else {
                throw NSError(domain: "GitPanelVisibility", code: Int(result.status),
                              userInfo: [NSLocalizedDescriptionKey: result.stderr])
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Bailey Visibility Test"])
        _ = try git(["config", "user.email", "visibility@example.invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        for index in 0..<80 {
            let file = repository.appendingPathComponent("file-\(index).txt")
            try "original \(index)\n".write(to: file, atomically: true, encoding: .utf8)
            _ = try git(["add", file.lastPathComponent])
            _ = try git(["commit", "-qm", "visible-history-\(index)"])
        }

        let application = WorkspaceApplication()
        let manager = application.makeWindow()
        manager.addLocalFolders([repository])
        let project = try XCTUnwrap(manager.selectedProject)
        project.dock.select(.git)
        let model = GitStatusModel()
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 338, height: 790),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let host = NSHostingView(rootView: GitPanel(
            model: model, manager: manager, project: project, sshHost: nil,
            openFile: { _ in }, openDiff: { _, _ in }, openCommitDiff: { _, _ in }
        ).environment(\.colorScheme, .dark))
        // The actual Dock fixes the panel's width; a standalone host must do the same.
        host.sizingOptions = []
        window.contentView = host
        manager.attach(to: window)
        window.orderFront(nil)
        manager.syncGitStatus(model)

        func scrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrollViews)
        }

        func visibleScroll() -> NSScrollView? {
            scrollViews(in: host).first { $0.contentView.bounds.height > 200 }
        }

        func keyboardViews(in view: NSView) -> [TreeKeyboardView] {
            let own = (view as? TreeKeyboardView).map { [$0] } ?? []
            return own + view.subviews.flatMap(keyboardViews)
        }

        func capture() throws -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }

        func contrastingPixels(_ bitmap: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> Int {
            // The test window is sized in points; bitmap pixels can be Retina-scaled.
            // A light theme must not pass just because its empty background is white.
            guard let background = bitmap.colorAt(
                x: bitmap.pixelsWide - 5, y: bitmap.pixelsHigh - 5
            )?.usingColorSpace(.deviceRGB) else { return 0 }
            let xScale = CGFloat(bitmap.pixelsWide) / max(1, host.bounds.width)
            let yScale = CGFloat(bitmap.pixelsHigh) / max(1, host.bounds.height)
            let columns = Int(CGFloat(x.lowerBound) * xScale)..<min(
                bitmap.pixelsWide, Int(CGFloat(x.upperBound) * xScale)
            )
            let rows = Int(CGFloat(y.lowerBound) * yScale)..<min(
                bitmap.pixelsHigh, Int(CGFloat(y.upperBound) * yScale)
            )
            var count = 0
            for row in rows {
                for column in columns {
                    guard let rgb = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB)
                    else { continue }
                    if max(abs(rgb.redComponent - background.redComponent),
                           abs(rgb.greenComponent - background.greenComponent),
                           abs(rgb.blueComponent - background.blueComponent)) > 0.2 {
                        count += 1
                    }
                }
            }
            return count
        }

        func waitFor(_ condition: () -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(40))
            }
            return false
        }

        let initialLoaded = try await waitFor {
            model.hasResolvedStatus && !model.isRefreshing && model.recentCommits.count >= 30
        }
        XCTAssertTrue(initialLoaded, "The initial 80-commit repository must load actual Git history")
        XCTAssertEqual(model.totalChangeCount, 0)
        let scroll = try XCTUnwrap(visibleScroll())
        let initialHeight = scroll.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(initialHeight, scroll.contentView.bounds.height)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, initialHeight - 100)))
        scroll.reflectScrolledClipView(scroll.contentView)
        for size in [
            NSSize(width: 160, height: 125),
            NSSize(width: 250, height: 320),
            NSSize(width: 338, height: 790),
            NSSize(width: 160, height: 180),
            NSSize(width: 338, height: 790),
        ] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, 658)

        let staged = repository.appendingPathComponent("stage-visible.txt")
        try "staged\n".write(to: staged, atomically: true, encoding: .utf8)
        _ = try git(["add", staged.lastPathComponent])
        model.refresh()
        let stagedLoaded = try await waitFor { model.stagedEntries.count == 1 && !model.isRefreshing }
        XCTAssertTrue(stagedLoaded)

        for index in 0..<1_024 {
            try "changed \(index)\n".write(
                to: repository.appendingPathComponent("file-\(index).txt"),
                atomically: true, encoding: .utf8
            )
        }
        _ = try git(["add", "-A"])
        model.refresh()
        let manyLoaded = try await waitFor { model.stagedEntries.count == 1_025 && !model.isRefreshing }
        XCTAssertTrue(manyLoaded)
        let expandedHeight = scroll.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(expandedHeight, initialHeight + 500)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, expandedHeight - 300)))
        scroll.reflectScrolledClipView(scroll.contentView)

        try FileManager.default.removeItem(at: staged)
        _ = try git(["reset", "--hard", "HEAD"])
        model.refresh()
        let cleared = try await waitFor {
            model.totalChangeCount == 0 && !model.isRefreshing
                && (scroll.documentView?.frame.height ?? .infinity) < expandedHeight - 500
        }
        XCTAssertTrue(cleared, "Clearing 1,025 changes must shrink the scroll document without changing HEAD")
        XCTAssertTrue(visibleScroll() === scroll, "Ordinary Git status refresh must retain scroll identity")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let sameHead = try capture()
        XCTAssertGreaterThan(contrastingPixels(sameHead, x: 40..<310, y: 225..<290), 80,
                             "Existing Git Graph rows must remain visible after clearing changes")

        let originalKeyboardHosts = keyboardViews(in: host)
        XCTAssertEqual(originalKeyboardHosts.count, 2)
        let nativeResponder = try XCTUnwrap(originalKeyboardHosts.last)
        XCTAssertTrue(window.makeFirstResponder(nativeResponder))

        let rootCommit = try git(["rev-parse", "HEAD~79"])
        _ = try git(["reset", "--hard", rootCommit])
        model.refresh()
        let rewritten = try await waitFor {
            guard model.recentCommits.count == 1, !model.isRefreshing,
                  let live = visibleScroll()
            else { return false }
            return (live.documentView?.frame.height ?? .infinity) < 1_100
        }
        XCTAssertTrue(rewritten, "Rewriting history must update the offscreen Graph height")
        XCTAssertTrue(visibleScroll() === scroll,
                      "Changing HEAD should update the Graph without replacing the native scroll host")

        let liveScroll = try XCTUnwrap(visibleScroll())
        let finalHeight = liveScroll.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(finalHeight, 110)
        XCTAssertLessThan(finalHeight, 1_100)
        XCTAssertEqual(model.graphCommits.count, 1)
        let maxOffset = max(0, finalHeight - liveScroll.contentView.bounds.height)
        XCTAssertLessThanOrEqual(liveScroll.contentView.bounds.minY, maxOffset + 1)

        liveScroll.contentView.scroll(to: .zero)
        liveScroll.reflectScrolledClipView(liveScroll.contentView)
        let reduced = try capture()
        XCTAssertGreaterThan(contrastingPixels(reduced, x: 40..<310, y: 225..<290), 80,
                             "The actual commit row, not just the model or Graph header, must paint")
        XCTAssertGreaterThan(contrastingPixels(reduced, x: 80..<280, y: 135..<195), 80,
                             "The clean working-tree state must be painted")
        XCTAssertGreaterThan(contrastingPixels(reduced, x: 10..<180, y: 190..<230), 80,
                             "The GIT GRAPH section header must be painted")
        let keyboards = keyboardViews(in: host)
        XCTAssertEqual(keyboards.count, 2, "Git Changes and Graph must keep one native keyboard host each")
        XCTAssertTrue(keyboards.allSatisfy { $0.window === window })
        XCTAssertEqual(Set(keyboards.map(ObjectIdentifier.init)),
                       Set(originalKeyboardHosts.map(ObjectIdentifier.init)),
                       "HEAD changes must not recreate the native keyboard hosts")
        XCTAssertTrue(window.firstResponder === nativeResponder,
                      "HEAD changes must preserve the active native keyboard responder")

        let image = try XCTUnwrap(reduced.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: image, uniformTypeIdentifier: "public.png")
        attachment.name = "Git Graph after offscreen history rewrite"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Updating another ref can rewrite the visible DAG without moving HEAD.
        // The normal scroll host must update its content height without remounting.
        let unchangedHead = try git(["rev-parse", "HEAD"])
        let rootTree = try git(["rev-parse", "HEAD^{tree}"])
        var tip = unchangedHead
        for index in 0..<75 {
            tip = try git(["commit-tree", rootTree, "-p", tip, "-m", "topic-history-\(index)"])
        }
        _ = try git(["update-ref", "refs/heads/topic", tip])
        model.refresh()
        let topicLoaded = try await waitFor {
            !model.isRefreshing && model.recentCommits.count > 1
        }
        XCTAssertTrue(topicLoaded)
        for _ in 0..<4 where model.hasMoreRecentCommits {
            XCTAssertTrue(model.loadMoreCommits())
            let completePage = try await waitFor { !model.isRefreshing && !model.isLoadingMoreCommits }
            XCTAssertTrue(completePage)
        }
        let topicScroll = try XCTUnwrap(visibleScroll())
        let largeHistoryHeight = topicScroll.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(largeHistoryHeight, finalHeight + 800)
        topicScroll.contentView.scroll(to: NSPoint(
            x: 0, y: max(0, largeHistoryHeight - topicScroll.contentView.bounds.height)
        ))
        topicScroll.reflectScrolledClipView(topicScroll.contentView)

        _ = try git(["update-ref", "-d", "refs/heads/topic"])
        model.refresh()
        let topicRemoved = try await waitFor {
            model.recentCommits.count == 1 && !model.isRefreshing
                && (topicScroll.documentView?.frame.height ?? .infinity) < 1_100
        }
        XCTAssertTrue(topicRemoved)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), unchangedHead)
        XCTAssertTrue(visibleScroll() === topicScroll,
                      "A branch ref update must not unnecessarily reset keyboard and scroll identity")
        let reducedHistoryHeight = topicScroll.documentView?.frame.height ?? 0
        XCTAssertLessThan(reducedHistoryHeight, 1_100,
                          "Removing a long-lived side branch must not leave a stale offscreen Graph")
        topicScroll.contentView.scroll(to: .zero)
        topicScroll.reflectScrolledClipView(topicScroll.contentView)
        let afterRefRemoval = try capture()
        XCTAssertGreaterThan(contrastingPixels(afterRefRemoval, x: 40..<310, y: 225..<290), 80,
                             "The current HEAD commit must still be painted after ref-only history rewrite")

        // Stash is another synthetic Graph node: changing it does not move HEAD.
        let trackedFile = repository.appendingPathComponent("file-0.txt")
        try "stash only\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        _ = try git(["stash", "push", "-m", "graph-visibility-stash"])
        model.refresh()
        let stashLoaded = try await waitFor {
            !model.isRefreshing && model.graphCommits.contains { $0.stash != nil }
        }
        XCTAssertTrue(stashLoaded)
        XCTAssertTrue(visibleScroll() === scroll)
        let stashHeight = scroll.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(stashHeight, reducedHistoryHeight + 15)

        _ = try git(["stash", "drop", "stash@{0}"])
        model.refresh()
        let stashRemoved = try await waitFor {
            !model.isRefreshing && model.graphCommits.count == 1
                && !model.graphCommits.contains(where: { $0.stash != nil })
        }
        XCTAssertTrue(stashRemoved)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), unchangedHead)
        XCTAssertTrue(visibleScroll() === scroll)
        XCTAssertLessThan(scroll.documentView?.frame.height ?? 0, stashHeight)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let afterStashRemoval = try capture()
        XCTAssertGreaterThan(contrastingPixels(afterStashRemoval, x: 40..<310, y: 225..<290), 80,
                             "The current HEAD commit must remain painted after Stash removal")
    }
}
