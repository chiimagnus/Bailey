import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Bailey

/// Retained native File/Diff/Browser surfaces across the real pane component.
@MainActor
final class NativeContentIdentityIntegrationTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    func testNativeTabPointerPreservesDownModifiersAndFinishesDragOnlyOnce() throws {
        let view = DockTabPointerView(frame: .init(x: 0, y: 0, width: 100, height: 24))
        var presses: [NSEvent.ModifierFlags] = []
        var releases: [NSEvent.ModifierFlags] = []
        var drops = 0
        view.press = { presses.append($0) }
        view.release = { releases.append($0) }
        view.drag = { _, finished in if finished { drops += 1 } }
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .init(x: x, y: 10),
                modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, 10, .command))
        view.mouseUp(with: try mouse(.leftMouseUp, 10))
        XCTAssertEqual(presses, [.command])
        XCTAssertEqual(releases, [.command])
        view.mouseDown(with: try mouse(.leftMouseDown, 10))
        view.mouseDragged(with: try mouse(.leftMouseDragged, 13))
        XCTAssertEqual(drops, 0)
        view.mouseDragged(with: try mouse(.leftMouseDragged, 14))
        view.mouseUp(with: try mouse(.leftMouseUp, 20))
        view.mouseUp(with: try mouse(.leftMouseUp, 20))
        XCTAssertEqual(drops, 1)
        XCTAssertEqual(releases, [.command], "A completed drag must never replay ordinary selection")
    }

    func testTabStripNativeKeyboardNavigatesWithoutDisplayingUntilReturn() async throws {
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let project = Project(fallbackName: "keyboard", workspaceConfiguration: .standard)
        manager.projects = [project]
        manager.selectedProjectID = project.id
        let group = try XCTUnwrap(project.dock.group(containing: .files))
        let host = NSHostingView(rootView: DockTabGroupView(
            group: group, project: project, manager: manager, git: GitStatusModel(),
            dragging: DockTabDragCoordinator()
        ))
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 360, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func strip(_ view: NSView) -> TreeKeyboardView? {
            if let keyboard = view as? TreeKeyboardView,
               keyboard.accessibilityIdentifier() == "bailey.dock.tabstrip" { return keyboard }
            return view.subviews.lazy.compactMap(strip).first
        }
        try await wait { host.layoutSubtreeIfNeeded(); return strip(host) != nil }
        let keyboard = try XCTUnwrap(strip(host))
        XCTAssertTrue(window.makeFirstResponder(keyboard))
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            keyboard.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
            )))
            host.layoutSubtreeIfNeeded()
        }
        try key(119)
        XCTAssertEqual(project.dock.group(containing: .files)?.selected, .files)
        try key(36)
        XCTAssertEqual(project.dock.group(containing: .git)?.selected, .git)
        try key(115)
        try key(49)
        XCTAssertEqual(project.dock.group(containing: .files)?.selected, .files)
        XCTAssertTrue(window.firstResponder === keyboard)
    }

    func testDisplayedTabExposesRealAccessibilitySelection() async throws {
        let host = NSHostingView(rootView: TabItemChrome(
            systemImage: "doc", title: "Selected document", isDisplayed: true,
            isPaneFocused: false, isContextTarget: false, select: {}, close: {}
        ))
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 300, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func attribute(_ element: NSObject, _ key: String) -> Any? {
            let selector = NSSelectorFromString(key == "accessibilitySelected" ? "isAccessibilitySelected" : key)
            guard element.responds(to: selector) else { return nil }
            return element.value(forKey: key)
        }
        func elements(_ element: NSObject) -> [NSObject] {
            let children = attribute(element, "accessibilityChildrenInNavigationOrder") as? [NSObject]
                ?? attribute(element, "accessibilityChildren") as? [NSObject] ?? []
            return [element] + children.flatMap(elements)
        }
        try await wait {
            host.layoutSubtreeIfNeeded()
            return elements(host).contains {
                (attribute($0, "accessibilityLabel") as? String ?? attribute($0, "accessibilityTitle") as? String) == "Selected document"
            }
        }
        XCTAssertTrue(elements(host).contains {
            (attribute($0, "accessibilityLabel") as? String ?? attribute($0, "accessibilityTitle") as? String) == "Selected document"
                && attribute($0, "accessibilitySelected") as? Bool == true
        }, "The displayed tab must be AX selected, not just painted as selected")
        for displayed in [false, true] {
            for selected in [false, true] {
                for focused in [false, true] {
                    host.rootView = TabItemChrome(
                        systemImage: "doc", title: "Selected document", isDisplayed: displayed,
                        isSelected: selected, isPaneFocused: focused, isContextTarget: true,
                        select: {}, close: {}
                    )
                    try await wait {
                        host.layoutSubtreeIfNeeded()
                        return elements(host).contains {
                            attribute($0, "accessibilityLabel") as? String == "Selected document"
                                && attribute($0, "accessibilitySelected") as? Bool == (displayed || selected)
                        }
                    }
                }
            }
        }
    }

    // Host only the actual pane component, never a complete ContentView or Dock.
    private func panel(for tab: PaneTab) -> some View {
        PanelContentView(tab: tab, isFocused: false,
                         onFocused: {}, onNewBrowserTab: { _ in }, onNewFileTab: { _ in })
            .id(tab.id)
    }

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

    // Native scroll elasticity requires observing the actual Dock component,
    // not a hand-built replacement or a full ContentView host.
    func testDockTabStripOnlyBouncesWhenTabsOverflowAfterResizing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-tab-bounce-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(snapshots); TerminalHistoryStore.save(histories) }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let file = root.appendingPathComponent("a.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        manager.openFile(file.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let pane = try XCTUnwrap(project.selectedTab)
        let sourceGroup = try XCTUnwrap(project.dock.group(containing: .tab(pane.id)))
        let destinationGroup = try XCTUnwrap(project.dock.group(containing: .files))
        XCTAssertTrue(project.dock.move(.files, into: sourceGroup.id))
        XCTAssertTrue(project.dock.move(.tab(pane.id), into: destinationGroup.id))
        let tabGroup = try XCTUnwrap(project.dock.group(containing: .tab(pane.id)))
        XCTAssertTrue(tabGroup.items.contains(.git))
        XCTAssertTrue(tabGroup.items.contains(.tab(pane.id)))

        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1700, height: 440),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Mount the actual production group/tab strip, not the entire Dock
        // tree or a separate test implementation of scroll behavior.
        let host = NSHostingView(rootView: DockTabGroupView(
            group: tabGroup, project: project, manager: manager,
            git: GitStatusModel(), dragging: DockTabDragCoordinator()
        ).coordinateSpace(name: "workspaceDock"))
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

        window.setContentSize(NSSize(width: 180, height: 440))
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
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Create a worktree change before mounting a clean file editor. An
        // external edit afterward would rightly reload the clean document.
        try "let identity = \"worktree A\"\n".write(to: fileURL, atomically: true, encoding: .utf8)
        manager.openFile(fileURL.path)
        let host = NSHostingView(rootView: panel(for: try XCTUnwrap(project.selectedTab)))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.find(FocusReportingTextView.self, in: host) != nil
        }
        let editor = try XCTUnwrap(find(FocusReportingTextView.self, in: host))
        XCTAssertEqual(editor.text, "let identity = \"worktree A\"\n")
        manager.openDiff(repoRoot: root.path, path: fileURL.lastPathComponent,
                         staged: false, untracked: false, origPath: nil)
        host.rootView = panel(for: try XCTUnwrap(project.selectedTab))
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
        host.rootView = panel(for: try XCTUnwrap(project.selectedTab))
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.find(FocusReportingTextView.self, in: host) === editor
        }
        XCTAssertEqual(editor.text, "let identity = \"worktree A\"\n")
        XCTAssertNil(find(DiffNativeSurface.self, in: host))

        manager.openDiff(repoRoot: root.path, path: fileURL.lastPathComponent,
                         staged: false, untracked: false, origPath: nil)
        host.rootView = panel(for: try XCTUnwrap(project.selectedTab))
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
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        manager.openFile(aURL.path)
        let host = NSHostingView(rootView: panel(for: try XCTUnwrap(project.selectedTab)))
        window.contentView = host
        window.orderFront(nil)
        try await wait { host.layoutSubtreeIfNeeded(); return self.find(FocusReportingTextView.self, in: host) != nil }
        let a = try XCTUnwrap(find(FocusReportingTextView.self, in: host))
        let browser = project.newBrowserTab(initialURL: "about:blank", initialFocus: .none)
        host.rootView = panel(for: try XCTUnwrap(project.selectedTab))
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.find(WKWebView.self, in: host) === browser.webView
        }
        XCTAssertNil(find(FocusReportingTextView.self, in: host))
        manager.openFile(bURL.path)
        host.rootView = panel(for: try XCTUnwrap(project.selectedTab))
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.find(FocusReportingTextView.self, in: host)?.text == "let second = \"B\"\n"
        }
        let b = try XCTUnwrap(find(FocusReportingTextView.self, in: host))
        XCTAssertFalse(a === b)
        manager.openFile(aURL.path)
        host.rootView = panel(for: try XCTUnwrap(project.selectedTab))
        try await wait { host.layoutSubtreeIfNeeded(); return self.find(FocusReportingTextView.self, in: host) === a }
        XCTAssertEqual(a.text, "let identity = \"original A\"\n")
        XCTAssertEqual(b.text, "let second = \"B\"\n")
        XCTAssertNil(find(WKWebView.self, in: host))
    }
}
