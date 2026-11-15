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
        defer { window.close() }
        let host = NSHostingView(rootView: GitPanel(
            model: model, manager: manager, project: project, sshHost: nil,
            openFile: { _ in }, openDiff: { _, _ in }, openCommitDiff: { _, _ in }
        ))
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

        func capture() throws -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }

        func contrastingPixels(_ bitmap: NSBitmapImageRep, x: Range<Int>, y: Range<Int>) -> Int {
            // A light theme must not pass just because its empty background is white.
            guard let background = bitmap.colorAt(
                x: bitmap.pixelsWide - 5, y: bitmap.pixelsHigh - 5
            )?.usingColorSpace(.deviceRGB) else { return 0 }
            var count = 0
            for row in y where row < bitmap.pixelsHigh {
                for column in x where column < bitmap.pixelsWide {
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

        for index in 0..<55 {
            try "changed \(index)\n".write(
                to: repository.appendingPathComponent("file-\(index).txt"),
                atomically: true, encoding: .utf8
            )
        }
        _ = try git(["add", "-A"])
        model.refresh()
        let manyLoaded = try await waitFor { model.stagedEntries.count == 56 && !model.isRefreshing }
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
        XCTAssertTrue(cleared, "Clearing 56 changes must shrink the scroll document without changing HEAD")
        XCTAssertTrue(visibleScroll() === scroll, "Ordinary Git status refresh must retain scroll identity")
        let sameHead = try capture()
        XCTAssertGreaterThan(contrastingPixels(sameHead, x: 40..<310, y: 300..<440), 80,
                             "Existing Git Graph rows must remain visible after clearing changes")

        let rootCommit = try git(["rev-parse", "HEAD~79"])
        _ = try git(["reset", "--hard", rootCommit])
        model.refresh()
        let rewritten = try await waitFor {
            guard model.recentCommits.count == 1, !model.isRefreshing,
                  let live = visibleScroll(), live !== scroll
            else { return false }
            return (live.documentView?.frame.height ?? .infinity) < 1_100
        }
        XCTAssertTrue(rewritten, "Rewriting history must retire the previous offscreen Graph geometry")

        let liveScroll = try XCTUnwrap(visibleScroll())
        let finalHeight = liveScroll.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(finalHeight, 110)
        XCTAssertLessThan(finalHeight, 1_100)
        XCTAssertEqual(model.graphCommits.count, 1)
        let maxOffset = max(0, finalHeight - liveScroll.contentView.bounds.height)
        XCTAssertLessThanOrEqual(liveScroll.contentView.bounds.minY, maxOffset + 1)

        let reduced = try capture()
        XCTAssertGreaterThan(contrastingPixels(reduced, x: 40..<310, y: 320..<440), 80,
                             "The actual commit row, not just the model or Graph header, must paint")
        func keyboardViews(in view: NSView) -> [TreeKeyboardView] {
            let own = (view as? TreeKeyboardView).map { [$0] } ?? []
            return own + view.subviews.flatMap(keyboardViews)
        }
        let keyboards = keyboardViews(in: host)
        XCTAssertEqual(keyboards.count, 2, "The remounted Git Changes and Graph must have one native keyboard host each")
        XCTAssertTrue(keyboards.allSatisfy { $0.window === window })

        let image = try XCTUnwrap(reduced.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: image, uniformTypeIdentifier: "public.png")
        attachment.name = "Git Graph after offscreen history rewrite"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
