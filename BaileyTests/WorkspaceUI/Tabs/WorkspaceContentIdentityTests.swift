import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Bailey

/// Exercises the actual workspace content branch, rather than rendering each
/// editor in isolation. A single dock group changes content type and identity.
@MainActor
final class WorkspaceContentIdentityTests: XCTestCase {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let matching = view as? T { return matching }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func wait(
        _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Workspace view did not settle", file: file, line: line)
                throw WorkspaceError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("identity.swift")
        try "let identity = \"original A\"\n".write(to: file, atomically: true, encoding: .utf8)
        for args in [
            ["init", "-q"], ["config", "user.name", "Bailey Identity Test"],
            ["config", "user.email", "test@invalid"], ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", "/dev/null"], ["add", "."],
            ["commit", "-qm", "baseline"],
        ] {
            let result = GitCommandExecution.run(args, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        return (root, file)
    }

    func testDockTabStripOnlyBouncesWhenTabsOverflowAfterResizing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-tab-bounce-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let file = root.appendingPathComponent("a.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        manager.openFile(file.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let pane = try XCTUnwrap(project.selectedTab)
        let sourceGroup = try XCTUnwrap(project.dock.group(containing: .tab(pane.id)))
        let destinationGroup = try XCTUnwrap(project.dock.group(containing: .files))
        XCTAssertTrue(project.dock.move(.files, into: sourceGroup.id))
        XCTAssertTrue(project.dock.move(.tab(pane.id), into: destinationGroup.id))

        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1700, height: 440),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: WorkspaceDockView(
            manager: manager, git: GitStatusModel()
        ))
        window.contentView = host
        window.orderFront(nil)

        func tabStrip() -> NSScrollView? {
            func scrolls(in view: NSView) -> [NSScrollView] {
                let own = (view as? NSScrollView).map { [$0] } ?? []
                return own + view.subviews.flatMap(scrolls)
            }
            return scrolls(in: host)
                .filter { $0.bounds.height > 10 && $0.bounds.height < 30 }
                .max { ($0.documentView?.frame.width ?? 0)
                    < ($1.documentView?.frame.width ?? 0) }
        }
        try await wait {
            host.layoutSubtreeIfNeeded()
            guard let scroll = tabStrip() else { return false }
            return (scroll.documentView?.frame.width ?? 0) > 100
                && scroll.contentView.bounds.width > 140
        }
        let wide = try XCTUnwrap(tabStrip())
        XCTAssertLessThanOrEqual(
            (wide.documentView?.frame.width ?? 0) - wide.contentView.bounds.width, 1
        )
        XCTAssertEqual(wide.horizontalScrollElasticity, .none,
                       "Short tab strips must not bounce horizontally")

        window.setContentSize(NSSize(width: 640, height: 440))
        try await wait {
            host.layoutSubtreeIfNeeded()
            guard let scroll = tabStrip() else { return false }
            return (scroll.documentView?.frame.width ?? 0) - scroll.contentView.bounds.width > 50
        }
        let narrow = try XCTUnwrap(tabStrip())
        let before = narrow.contentView.bounds.minX
        narrow.contentView.scroll(to: NSPoint(x: before + 35, y: 0))
        narrow.reflectScrolledClipView(narrow.contentView)
        XCTAssertGreaterThan(narrow.contentView.bounds.minX, before + 15,
                             "Overflowing tabs must remain horizontally scrollable")

        window.setContentSize(NSSize(width: 1700, height: 440))
        try await wait {
            host.layoutSubtreeIfNeeded()
            guard let scroll = tabStrip() else { return false }
            return (scroll.documentView?.frame.width ?? 0) - scroll.contentView.bounds.width <= 1
        }
        XCTAssertEqual(try XCTUnwrap(tabStrip()).horizontalScrollElasticity, .none,
                       "Tabs must stop bouncing when the panel widens again")
    }

    func testFileDiffFileReturnsToSameEditorAndDiffDocument() async throws {
        let (root, fileURL) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.orderFront(nil)

        // Create a worktree change before mounting a clean file editor. An
        // external edit afterward would rightly reload the clean document.
        try "let identity = \"worktree A\"\n".write(to: fileURL, atomically: true, encoding: .utf8)
        manager.openFile(fileURL.path)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.find(FocusReportingTextView.self, in: host) != nil
        }
        let editor = try XCTUnwrap(find(FocusReportingTextView.self, in: host))
        XCTAssertEqual(editor.text, "let identity = \"worktree A\"\n")
        manager.openDiff(repoRoot: root.path, path: fileURL.lastPathComponent,
                         staged: false, untracked: false, origPath: nil)
        let diff = try XCTUnwrap(project.tabs.compactMap {
            if case .diff(let candidate) = $0.content { return candidate }
            return nil
        }.first)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return diff.display != nil && self.find(DiffNativeSurface.self, in: host) === diff.nativeSurface
        }
        let originalDiffSurface = try XCTUnwrap(diff.nativeSurface)
        XCTAssertEqual(diff.newContent, "let identity = \"worktree A\"\n")
        XCTAssertNil(find(FocusReportingTextView.self, in: host))

        manager.openFile(fileURL.path)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.find(FocusReportingTextView.self, in: host) === editor
        }
        XCTAssertEqual(editor.text, "let identity = \"worktree A\"\n")
        XCTAssertNil(find(DiffNativeSurface.self, in: host))

        manager.openDiff(repoRoot: root.path, path: fileURL.lastPathComponent,
                         staged: false, untracked: false, origPath: nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.find(DiffNativeSurface.self, in: host) === originalDiffSurface
        }
    }

    func testBrowserTabBetweenTwoFilesDoesNotStealTheirNativeEditors() async throws {
        let (root, aURL) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bURL = root.appendingPathComponent("second.swift")
        try "let second = \"B\"\n".write(to: bURL, atomically: true, encoding: .utf8)
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.orderFront(nil)

        manager.openFile(aURL.path)
        try await wait { host.layoutSubtreeIfNeeded(); return self.find(FocusReportingTextView.self, in: host) != nil }
        let a = try XCTUnwrap(find(FocusReportingTextView.self, in: host))
        let browser = project.newBrowserTab(initialURL: "about:blank", initialFocus: .none)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.find(WKWebView.self, in: host) === browser.webView
        }
        XCTAssertNil(find(FocusReportingTextView.self, in: host))
        manager.openFile(bURL.path)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.find(FocusReportingTextView.self, in: host)?.text == "let second = \"B\"\n"
        }
        let b = try XCTUnwrap(find(FocusReportingTextView.self, in: host))
        XCTAssertFalse(a === b)
        manager.openFile(aURL.path)
        try await wait { host.layoutSubtreeIfNeeded(); return self.find(FocusReportingTextView.self, in: host) === a }
        XCTAssertEqual(a.text, "let identity = \"original A\"\n")
        XCTAssertEqual(b.text, "let second = \"B\"\n")
        XCTAssertNil(find(WKWebView.self, in: host))
    }
}
