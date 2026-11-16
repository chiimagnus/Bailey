import AppKit
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
final class GitPanelVisibilityTests: XCTestCase {
    func testRealDockConstrainsGitScrollWidthToItsAllocatedPane() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-GitDockWidth-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: root.path)
            guard result.status == 0 else {
                throw NSError(domain: "GitDockWidth", code: Int(result.status),
                              userInfo: [NSLocalizedDescriptionKey: result.stderr])
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Bailey Width Test"])
        try git(["config", "user.email", "width@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try "hello\n".write(to: root.appendingPathComponent("file.txt"),
                            atomically: true, encoding: .utf8)
        try git(["add", "file.txt"])
        try git(["commit", "-qm", "a real commit"])

        let application = WorkspaceApplication()
        let manager = application.makeWindow()
        let project = Project(fallbackName: "width", workspaceConfiguration: .standard)
        project.customDirectory = root.path
        manager.projects = [project]
        manager.selectedProjectID = project.id
        project.dock.select(.git)
        let model = GitStatusModel()

        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: WorkspaceDockView(manager: manager, git: model))
        host.sizingOptions = []
        window.contentView = host
        manager.attach(to: window)
        window.orderFront(nil)
        manager.syncGitStatus(model)

        let deadline = Date().addingTimeInterval(12)
        while !model.isRepo || !model.hasResolvedStatus || model.isRefreshing {
            guard Date() < deadline else {
                XCTFail("The real Dock did not resolve its isolated Git repository")
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        func scrolls(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrolls)
        }
        func checkWidth(expected: CGFloat? = nil) throws {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let candidates = scrolls(in: host).map { ($0, $0.convert($0.bounds, to: host)) }
            let scroll = try XCTUnwrap(candidates.first { _, frame in
                frame.minX > host.bounds.width * 0.65 && frame.height > 140
            }, "Cannot locate the Git panel's vertical ScrollView in its right-side Dock group")
            let width = host.bounds.width
            print("GIT_DOCK_SCROLL_FRAME \(scroll.1) host=\(host.bounds)")
            XCTAssertGreaterThan(scroll.1.width, 100)
            XCTAssertLessThanOrEqual(scroll.1.maxX, width + 2,
                "Git scroll must never leave its real Dock pane")
            XCTAssertLessThanOrEqual(scroll.1.width, width * 0.35,
                "The Git group occupies a fraction of the window, not all of it")
            if let documentWidth = scroll.0.documentView?.frame.width {
                XCTAssertLessThanOrEqual(documentWidth, scroll.1.width + 2,
                    "The inner Git Graph must not use the entire window width")
            }
            if let expected {
                XCTAssertEqual(scroll.1.width, expected, accuracy: 4,
                    "The Git panel must match its allocated Dock width")
            }
        }
        try checkWidth(expected: 216)
        for width in [700.0, 1_200.0, 1_380.0, 900.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            try await Task.sleep(for: .milliseconds(50))
            try checkWidth(expected: width * 0.24)
        }
        guard case .split(let outer) = project.dock.root,
              case .split(let inner) = outer.second else {
            XCTFail("The standard Dock must expose an actual right-side split")
            return
        }
        let available = window.contentView!.bounds.width * 0.76 - 2
        project.dock.resize(inner.id, to: 1 - 150 / available)
        try await Task.sleep(for: .milliseconds(100))
        try checkWidth(expected: 150)
        func attachSnapshot(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        try attachSnapshot("Real Dock Git panel at 150pt")
        project.dock.resize(inner.id, to: 0.52 / 0.76)
        try await Task.sleep(for: .milliseconds(100))
        try checkWidth(expected: 216)

        // Exceptionally long Unicode names must not expand the narrow sidebar.
        let filename = String(repeating: "中文 🧪", count: 16) + ".txt"
        try "unicode payload\n".write(to: root.appendingPathComponent(filename),
                                      atomically: true, encoding: .utf8)
        try git(["add", "--", filename])
        model.refresh()
        let updated = Date().addingTimeInterval(8)
        while model.stagedEntries.count == 0 || model.isRefreshing {
            guard Date() < updated else {
                XCTFail("The real Git panel did not refresh its staged Unicode path")
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        try checkWidth(expected: 216)
        try attachSnapshot("Real Dock Git panel with long Unicode filename")

        // The original blank-Graph bug needs to be exercised in the real Dock,
        // not only in the separately mounted GitPanel.
        let oldHead = try git(["rev-parse", "HEAD"])
        let tree = try git(["rev-parse", "HEAD^{tree}"])
        try git(["reset", "--hard", "HEAD"])
        let unicodeURL = root.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: unicodeURL.path) {
            try FileManager.default.removeItem(at: unicodeURL)
        }
        var tip = oldHead
        for index in 0..<202 {
            tip = try git(["commit-tree", tree, "-p", tip, "-m", "dock-history-\(index)"])
        }
        try git(["update-ref", "refs/heads/main", tip])
        model.refresh()
        let historyDeadline = Date().addingTimeInterval(15)
        while model.recentCommits.count < 30 || model.isRefreshing {
            guard Date() < historyDeadline else {
                XCTFail("The full Dock did not load its expanded 203-commit history")
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let scrolling = try XCTUnwrap(scrolls(in: host).first { candidate in
            let frame = candidate.convert(candidate.bounds, to: host)
            return frame.minX > host.bounds.width * 0.65 && frame.height > 140
        })
        let initialHistoryCount = model.recentCommits.count
        let initialDocumentHeight = scrolling.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(initialDocumentHeight, 900,
                             "The real Dock must lay out a long, scrollable Git Graph")
        scrolling.contentView.scroll(to: NSPoint(x: 0, y: 155))
        scrolling.reflectScrolledClipView(scrolling.contentView)
        let paginationOffset = scrolling.contentView.bounds.minY
        XCTAssertGreaterThan(paginationOffset, 50)
        var priorCount = initialHistoryCount
        for page in 1...6 {
            XCTAssertTrue(model.hasMoreRecentCommits)
            XCTAssertTrue(model.loadMoreCommits())
            let pageDeadline = Date().addingTimeInterval(15)
            while model.recentCommits.count <= priorCount || model.isLoadingMoreCommits {
                guard Date() < pageDeadline else {
                    XCTFail("Real Git Graph pagination did not finish page \(page)")
                    return
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertGreaterThan(model.recentCommits.count, priorCount)
            XCTAssertEqual(scrolling.contentView.bounds.minY, paginationOffset, accuracy: 6,
                           "Appending history page \(page) must not jump the visible Git Graph")
            priorCount = model.recentCommits.count
        }
        XCTAssertEqual(model.recentCommits.count, 203)
        XCTAssertFalse(model.hasMoreRecentCommits)
        print("GIT_DOCK_PAGINATION_OFFSETS before=\(paginationOffset) after=\(scrolling.contentView.bounds.minY) count=\(model.recentCommits.count)")
        let expandedHeight = scrolling.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(expandedHeight, initialDocumentHeight + 200)
        scrolling.contentView.scroll(to: NSPoint(x: 0, y: expandedHeight - 100))
        scrolling.reflectScrolledClipView(scrolling.contentView)
        window.displayIfNeeded()
        try git(["update-ref", "refs/heads/main", oldHead])
        model.refresh()
        let shrinkDeadline = Date().addingTimeInterval(20)
        while model.recentCommits.count != 1 || model.isRefreshing
                || (scrolling.documentView?.frame.height ?? .infinity) > 900 {
            guard Date() < shrinkDeadline else {
                XCTFail("The offscreen history kept an obsolete Git Graph height in the real Dock")
                return
            }
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        XCTAssertEqual(model.graphCommits.count, 1)
        let liveScroll = try XCTUnwrap(scrolls(in: host).first { candidate in
            let frame = candidate.convert(candidate.bounds, to: host)
            return frame.minX > host.bounds.width * 0.65 && frame.height > 140
        })
        XCTAssertTrue(liveScroll === scrolling,
                      "History replacement must not destroy the real Dock scroll host")
        let finalHeight = liveScroll.documentView?.frame.height ?? 0
        let maxOffset = max(0, finalHeight - liveScroll.contentView.bounds.height)
        XCTAssertLessThanOrEqual(liveScroll.contentView.bounds.minY, maxOffset + 1)
        try checkWidth(expected: 216)
        liveScroll.contentView.scroll(to: .zero)
        liveScroll.reflectScrolledClipView(liveScroll.contentView)
        try attachSnapshot("Real Dock Git Graph after deep-scroll history rewrite")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let background = try XCTUnwrap(bitmap.colorAt(
            x: bitmap.pixelsWide - 12, y: bitmap.pixelsHigh - 30
        )?.usingColorSpace(.deviceRGB))
        let sx = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let sy = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        var commitPixels = 0
        for y in Int(290 * sy)..<Int(360 * sy) {
            for x in Int(705 * sx)..<Int(890 * sx) {
                guard let rgb = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                if max(abs(rgb.redComponent - background.redComponent),
                       max(abs(rgb.greenComponent - background.greenComponent),
                           abs(rgb.blueComponent - background.blueComponent))) > 0.2 {
                    commitPixels += 1
                }
            }
        }
        print("GIT_DOCK_COMMIT_ROW_PIXELS \(commitPixels)")
        XCTAssertGreaterThan(commitPixels, 80,
            "The rewritten HEAD commit must paint in the real Dock, not leave an empty Graph")
    }

    func testDenseGraphSurvivesThemeFontModeAndViewportMatrix() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-GitGraphMatrix-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-GitGraphMatrix-" + UUID().uuidString + ".toml")
        defer { try? FileManager.default.removeItem(at: config) }

        @discardableResult
        func git(_ args: [String]) throws -> String {
            let result = GitCommandExecution.run(args, in: repository.path)
            guard result.status == 0 else {
                throw NSError(domain: "GitGraphMatrix", code: Int(result.status),
                              userInfo: [NSLocalizedDescriptionKey: result.stderr])
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q", "-b", "main"])
        _ = try git(["config", "user.name", "Bailey Graph Matrix"])
        _ = try git(["config", "user.email", "matrix@example.invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        try "base\n".write(to: repository.appendingPathComponent("base.txt"),
                           atomically: true, encoding: .utf8)
        _ = try git(["add", "base.txt"])
        _ = try git(["commit", "-qm", "Dense graph base"])
        let base = try git(["rev-parse", "HEAD"])
        let tree = try git(["rev-parse", "HEAD^{tree}"])
        for index in 0..<20 {
            let tip = try git(["commit-tree", tree, "-p", base, "-m", "Dense topic \(index)"])
            _ = try git(["update-ref", "refs/heads/topic-\(index)", tip])
        }
        var current = base
        for index in 0..<4 {
            current = try git(["commit-tree", tree, "-p", current, "-m", "Dense main \(index)"])
        }
        _ = try git(["update-ref", "refs/heads/main", current])
        _ = try git(["update-ref",
                     "refs/heads/超长图谱-" + String(repeating: "分支", count: 18),
                     try git(["rev-parse", "refs/heads/topic-0"])])
        _ = try git(["tag", "-a", "图谱-tag", "-m", "tag decoration",
                     try git(["rev-parse", "refs/heads/topic-1"])])
        let filename = "嵌套/" + String(repeating: "中🧪", count: 15) + ".txt"
        let stagedFile = repository.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: stagedFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "Unicode staged change\n".write(
            to: stagedFile, atomically: true, encoding: .utf8
        )
        _ = try git(["add", "--", filename])

        let settings = AppSettings(configURL: config)
        let application = WorkspaceApplication()
        let manager = application.makeWindow()
        let project = Project(fallbackName: "matrix", workspaceConfiguration: .standard)
        project.customDirectory = repository.path
        manager.projects = [project]
        manager.selectedProjectID = project.id
        project.dock.select(.git)
        let model = GitStatusModel()
        func panel(scale: CGFloat, dark: Bool) -> some View {
            GitPanel(settings: settings, model: model, manager: manager, project: project,
                     sshHost: nil, openFile: { _ in }, openDiff: { _, _ in },
                     openCommitDiff: { _, _ in })
                .environment(\.panelFontScale, scale)
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: Theme.terminal(dark: dark).sidebarNSColor))
        }
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: panel(scale: 1, dark: true))
        host.sizingOptions = []
        window.contentView = host
        manager.attach(to: window)
        window.orderFront(nil)
        manager.syncGitStatus(model)

        let deadline = Date().addingTimeInterval(20)
        while !model.hasResolvedStatus || model.isRefreshing
                || model.recentCommits.count < 25 || model.stagedEntries.count != 1 {
            guard Date() < deadline else {
                XCTFail("Real Git Graph must load its 25 commits and Unicode staged change")
                return
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        let graph = CommitGraphLayout(commits: model.graphCommits)
        XCTAssertGreaterThanOrEqual(graph.laneCount, 13,
                                    "This fixture must actually exercise densely packed lanes")
        let axStatus = await Task.detached {
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                kAXWindowsAttribute as CFString, &windows
            ).rawValue
        }.value
        XCTAssertEqual(axStatus, AXError.success.rawValue)

        func scrolls(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrolls)
        }
        func attribute(_ node: NSObject, _ key: String) -> Any? {
            guard node.responds(to: NSSelectorFromString(key)) else { return nil }
            return node.value(forKey: key)
        }
        func descendants(_ node: NSObject) -> [NSObject] {
            let children = attribute(node, "accessibilityChildrenInNavigationOrder") as? [NSObject]
                ?? attribute(node, "accessibilityChildren") as? [NSObject] ?? []
            return [node] + children.flatMap(descendants)
        }
        var combinations = 0
        var heightByFont: [Double: CGFloat] = [:]
        var darkBackground: NSColor?
        for fontSize in [9.0, 14.0, 18.0] {
            settings.panelFontSize = fontSize
            for mode in [GitViewMode.tree, .list] {
                settings.gitViewMode = mode
                let rows = model.displayChanges(filter: "", mode: mode, closed: [])
                XCTAssertEqual(rows.stagedRows.count, mode == .tree ? 2 : 1,
                               "Tree mode must actually render a folder above the Unicode file")
                for dark in [true, false] {
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.rootView = panel(
                        scale: CGFloat(fontSize / AppSettings.defaultPanelFontSize), dark: dark
                    )
                    var stableScroll: NSScrollView?
                    for size in [
                        NSSize(width: 120, height: 280),
                        NSSize(width: 160, height: 900),
                        NSSize(width: 320, height: 900),
                        NSSize(width: 520, height: 900),
                    ] {
                        window.setContentSize(size)
                        try await Task.sleep(for: .milliseconds(35))
                        host.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                        let scrolling = try XCTUnwrap(scrolls(in: host).first {
                            $0.contentView.bounds.height > 80
                                && $0.contentView.bounds.width > 70
                        }, "The Git panel must keep a native ScrollView for every size")
                        if let stableScroll {
                            XCTAssertTrue(scrolling === stableScroll,
                                          "Resizing must not replace the native scroll host")
                        } else {
                            stableScroll = scrolling
                        }
                        let documentWidth = try XCTUnwrap(scrolling.documentView?.frame.width)
                        let viewportWidth = scrolling.contentView.bounds.width
                        XCTAssertGreaterThan(viewportWidth, 75)
                        XCTAssertLessThanOrEqual(documentWidth, viewportWidth + 2,
                            "Graph must stay inside \(size), font \(fontSize), \(mode), dark=\(dark)")
                        XCTAssertGreaterThan(scrolling.documentView?.frame.height ?? 0,
                                             scrolling.contentView.bounds.height + 100,
                            "The full Graph must contribute to scroll height without going blank")
                        if size.width == 320 {
                            let elements = (host.accessibilityChildren() as? [NSObject] ?? [])
                                .flatMap(descendants)
                            if mode == .tree && dark {
                                heightByFont[fontSize] = scrolling.documentView?.frame.height
                            }
                            if mode == .tree && fontSize == 14 {
                                let bitmap = try XCTUnwrap(
                                    host.bitmapImageRepForCachingDisplay(in: host.bounds)
                                )
                                host.cacheDisplay(in: host.bounds, to: bitmap)
                                let picture = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                                let proof = XCTAttachment(data: picture, uniformTypeIdentifier: "public.png")
                                proof.name = dark ? "Dense Graph in dark appearance" : "Dense Graph in light appearance"
                                proof.lifetime = .keepAlways
                                add(proof)
                                let backdrop = try XCTUnwrap(bitmap.colorAt(
                                    x: bitmap.pixelsWide - 5, y: bitmap.pixelsHigh / 2
                                )?.usingColorSpace(.sRGB))
                                if dark {
                                    darkBackground = backdrop
                                } else {
                                    let before = try XCTUnwrap(darkBackground)
                                    let luminance: (NSColor) -> CGFloat = { color in
                                        color.redComponent * 0.2126
                                            + color.greenComponent * 0.7152
                                            + color.blueComponent * 0.0722
                                    }
                                    XCTAssertGreaterThan(luminance(backdrop),
                                                         luminance(before) + 0.25,
                                        "Light appearance must actually repaint the Git panel")
                                }
                            }
                            if fontSize == 9 && mode == .tree && dark {
                                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                                host.cacheDisplay(in: host.bounds, to: bitmap)
                                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                                attachment.name = "Dense Graph with Unicode refs and 20 tracks"
                                attachment.lifetime = .keepAlways
                                add(attachment)
                            }
                            XCTAssertTrue(elements.contains {
                                attribute($0, "accessibilityRole") as? String == "AXButton"
                                    && attribute($0, "accessibilityLabel") as? String
                                        == "Dense main 3"
                            }, "Current HEAD must remain accessible with \(mode), font \(fontSize)")
                        }
                        combinations += 1
                    }
                }
            }
        }
        // At the most constrained width, verify the actual interactive commit
        // control, not merely the graph's document size or accessibility label.
        window.setContentSize(NSSize(width: 120, height: 280))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let narrowScroll = try XCTUnwrap(scrolls(in: host).first {
            $0.contentView.bounds.height > 80 && $0.contentView.bounds.width > 70
        })
        narrowScroll.contentView.scroll(to: .zero)
        narrowScroll.reflectScrolledClipView(narrowScroll.contentView)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func narrowCommitButton() throws -> NSObject {
            let nodes = (host.accessibilityChildren() as? [NSObject] ?? []).flatMap(descendants)
            return try XCTUnwrap(nodes.first {
                attribute($0, "accessibilityRole") as? String == "AXButton"
                    && attribute($0, "accessibilityLabel") as? String == "Dense main 3"
            }, "A 120pt Graph must still expose the current HEAD's native button")
        }
        let head = try XCTUnwrap(model.graphCommits.first { $0.subject == "Dense main 3" })
        XCTAssertFalse(model.expandedCommitIDs.contains(head.id))
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        for expanded in [true, false] {
            let button = try narrowCommitButton()
            XCTAssertTrue(button.responds(to: selector))
            let perform = unsafeBitCast(button.method(for: selector), to: Action.self)
            XCTAssertTrue(perform(button, selector),
                          "A 120pt Git Graph row must accept the actual native AXPress")
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(model.expandedCommitIDs.contains(head.id), expanded,
                           "The 120pt native click must toggle the correct commit")
        }
        XCTAssertEqual(combinations, 48)
        let minimumHeight = try XCTUnwrap(heightByFont[9])
        let maximumHeight = try XCTUnwrap(heightByFont[18])
        XCTAssertGreaterThan(maximumHeight, minimumHeight + 100,
                             "Graph layout must actually react to minimum/maximum panel typography")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), current)
        XCTAssertEqual(try git(["-c", "core.quotePath=false", "status", "--porcelain=v1"]),
                       "A  " + filename,
                       "Layout, theme and mode must not mutate the real index or working tree")
    }

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

        // Reproduce Bailey's own commit completion, not only external Git changes.
        let previousHEAD = try git(["rev-parse", "HEAD"])
        let previousCommit = try XCTUnwrap(model.graphCommits.first)
        model.expandedCommitIDs.insert(previousCommit.id)
        let newFile = repository.appendingPathComponent("native-graph-commit.txt")
        try "native commit\n".write(to: newFile, atomically: true, encoding: .utf8)
        _ = try git(["add", "--", newFile.lastPathComponent])
        model.refresh()
        let stagedForNativeCommit = try await waitFor {
            !model.isRefreshing && model.stagedEntries.count == 1
        }
        XCTAssertTrue(stagedForNativeCommit)
        model.commit(message: "Native Git Graph regression", includeAll: false)
        let completed = try await waitFor {
            !model.isBusy && !model.isRefreshing
                && model.graphCommits.count == 2
                && model.graphCommits.first?.subject == "Native Git Graph regression"
        }
        XCTAssertTrue(completed, "A native commit must finish with the new Graph visible")
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"]), previousHEAD)
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "Native Git Graph regression")
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
        let updatedGraph = model.graphCommits
        XCTAssertEqual(updatedGraph[1].hash, previousHEAD)
        XCTAssertTrue(model.expandedCommitIDs.contains(previousCommit.id),
                      "The older commit must remain expanded after a new HEAD is appended")
        let layout = CommitGraphLayout(commits: updatedGraph)
        XCTAssertEqual(layout.rows[0].node.lane, layout.rows[1].node.lane)
        XCTAssertTrue(layout.rows[0].links.contains {
            if case .outgoing(let rail) = $0 {
                return rail.lane == layout.rows[1].node.lane
            }
            return false
        }, "The new HEAD must draw an outgoing rail toward its parent")
        XCTAssertTrue(layout.rows[1].links.contains {
            if case .incoming(let rail) = $0 {
                return rail.lane == layout.rows[0].node.lane
            }
            return false
        }, "The parent must receive the same Git rail")
        XCTAssertTrue(visibleScroll() === scroll)
        XCTAssertEqual(Set(keyboardViews(in: host).map(ObjectIdentifier.init)),
                       Set(originalKeyboardHosts.map(ObjectIdentifier.init)),
                       "A native commit must preserve keyboard host identity")
        XCTAssertTrue(window.firstResponder === nativeResponder)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let committedImage = try capture()
        XCTAssertGreaterThan(contrastingPixels(committedImage, x: 40..<310, y: 225..<330), 80,
                             "Both commit rows must repaint after Bailey commits")
        let committedPNG = try XCTUnwrap(committedImage.representation(using: .png, properties: [:]))
        let committedAttachment = XCTAttachment(data: committedPNG,
                                                uniformTypeIdentifier: "public.png")
        committedAttachment.name = "Native Git commit updates connected Graph without changing Project"
        committedAttachment.lifetime = .keepAlways
        add(committedAttachment)
        // Exercise the native keyboard row action without stealing the user's desktop.
        func sendGraphKey(_ keyCode: UInt16, characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ))
            nativeResponder.keyDown(with: event)
        }
        try sendGraphKey(126, characters: "\u{F700}") // Up: previous HEAD to new HEAD
        try sendGraphKey(49, characters: " ") // Space: same disclosure action as a row click
        let keyboardExpanded = try await waitFor {
            model.expandedCommitIDs.contains(updatedGraph[0].id)
        }
        XCTAssertTrue(keyboardExpanded,
                      "The new HEAD must still accept the native Graph row action")
        try sendGraphKey(49, characters: " ")
        let keyboardCollapsed = try await waitFor {
            !model.expandedCommitIDs.contains(updatedGraph[0].id)
        }
        XCTAssertTrue(keyboardCollapsed)
        XCTAssertTrue(model.expandedCommitIDs.contains(previousCommit.id),
                      "Toggling a new commit must not collapse another existing commit")

        // The same SwiftUI controls must remain accessible and respond to native
        // AXPress after the HEAD changes; model-only keyboard tests cannot prove this.
        let axStatus = await Task.detached {
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                kAXWindowsAttribute as CFString, &windows
            ).rawValue
        }.value
        XCTAssertEqual(axStatus, AXError.success.rawValue)
        func attribute(_ object: NSObject, _ key: String) -> Any? {
            guard object.responds(to: NSSelectorFromString(key)) else { return nil }
            return object.value(forKey: key)
        }
        func descendants(_ object: NSObject) -> [NSObject] {
            let children = attribute(object, "accessibilityChildrenInNavigationOrder") as? [NSObject]
                ?? attribute(object, "accessibilityChildren") as? [NSObject] ?? []
            return [object] + children.flatMap(descendants)
        }
        func commitButton(_ subject: String) throws -> NSObject {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let accessible = (host.accessibilityChildren() as? [NSObject] ?? [])
                .flatMap(descendants)
            return try XCTUnwrap(accessible.first {
                attribute($0, "accessibilityRole") as? String == "AXButton"
                    && attribute($0, "accessibilityLabel") as? String == subject
            }, "A real, pressable Graph commit button must exist for \(subject)")
        }
        func pressCommit(_ subject: String) throws {
            let row = try commitButton(subject)
            let selector = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(row.responds(to: selector))
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            let perform = unsafeBitCast(row.method(for: selector), to: Action.self)
            XCTAssertTrue(perform(row, selector),
                          "Graph commit must perform the native accessibility click")
        }
        try pressCommit("Native Git Graph regression")
        let axExpanded = try await waitFor { model.expandedCommitIDs.contains(updatedGraph[0].id) }
        XCTAssertTrue(axExpanded)
        try pressCommit("Native Git Graph regression")
        let axCollapsed = try await waitFor { !model.expandedCommitIDs.contains(updatedGraph[0].id) }
        XCTAssertTrue(axCollapsed)
        try pressCommit("visible-history-0")
        let parentCollapsed = try await waitFor { !model.expandedCommitIDs.contains(previousCommit.id) }
        XCTAssertTrue(parentCollapsed)
        try pressCommit("visible-history-0")
        let parentExpanded = try await waitFor { model.expandedCommitIDs.contains(previousCommit.id) }
        XCTAssertTrue(parentExpanded)

        // A single successful refresh is insufficient: each new HEAD must update
        // the native, still-mounted graph without destroying prior rows or rails.
        var previousOID = updatedGraph[0].hash
        for index in 1...5 {
            let filename = "native-followup-\(index).txt"
            try "followup \(index)\n".write(
                to: repository.appendingPathComponent(filename), atomically: true, encoding: .utf8
            )
            _ = try git(["add", "--", filename])
            model.refresh()
            let stagedReady = try await waitFor {
                !model.isRefreshing && model.stagedEntries.count == 1
            }
            XCTAssertTrue(stagedReady)
            let subject = "Native followup \(index)"
            model.commit(message: subject, includeAll: false)
            let committed = try await waitFor {
                !model.isBusy && !model.isRefreshing && model.graphCommits.first?.subject == subject
            }
            XCTAssertTrue(committed, "The \(index)th native commit must update the mounted Graph")
            let records = model.graphCommits
            let head = try XCTUnwrap(records.first)
            let parent = try XCTUnwrap(records.dropFirst().first)
            XCTAssertEqual(head.hash, try git(["rev-parse", "HEAD"]))
            XCTAssertEqual(parent.hash, previousOID, "The \(index)th HEAD must retain its true parent")
            let dag = CommitGraphLayout(commits: records)
            XCTAssertEqual(dag.rows[0].node.lane, dag.rows[1].node.lane)
            XCTAssertTrue(dag.rows[0].links.contains {
                if case .outgoing(let rail) = $0 {
                    return rail.lane == dag.rows[1].node.lane
                }
                return false
            }, "The \(index)th HEAD must paint its outgoing rail")
            XCTAssertTrue(dag.rows[1].links.contains {
                if case .incoming(let rail) = $0 {
                    return rail.lane == dag.rows[0].node.lane
                }
                return false
            }, "The \(index)th parent must paint its incoming rail")
            XCTAssertTrue(visibleScroll() === scroll, "Repeated commits must retain the scroll host")
            XCTAssertEqual(Set(keyboardViews(in: host).map(ObjectIdentifier.init)),
                           Set(originalKeyboardHosts.map(ObjectIdentifier.init)))
            try pressCommit(subject)
            let expanded = try await waitFor { model.expandedCommitIDs.contains(head.id) }
            XCTAssertTrue(expanded, "The \(index)th HEAD must expand via real AXPress")
            try pressCommit(subject)
            let collapsed = try await waitFor { !model.expandedCommitIDs.contains(head.id) }
            XCTAssertTrue(collapsed, "The \(index)th HEAD must collapse via real AXPress")
            previousOID = head.hash
        }
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "7")

        // Amend rewrites an existing node rather than prepending another one:
        // the obsolete HEAD must disappear without breaking its live replacement.
        model.commit(message: "Native amended graph", includeAll: false, amend: true)
        let amended = try await waitFor {
            !model.isBusy && !model.isRefreshing
                && model.graphCommits.first?.subject == "Native amended graph"
        }
        XCTAssertTrue(amended)
        let amendedHead = try XCTUnwrap(model.graphCommits.first)
        XCTAssertNotEqual(amendedHead.hash, previousOID)
        XCTAssertEqual(amendedHead.hash, try git(["rev-parse", "HEAD"]))
        XCTAssertFalse(model.graphCommits.contains { $0.hash == previousOID })
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "7")
        try pressCommit("Native amended graph")
        let amendedExpanded = try await waitFor {
            model.expandedCommitIDs.contains(amendedHead.id)
        }
        XCTAssertTrue(amendedExpanded, "Amended HEAD must remain clickable without changing Project")
        try pressCommit("Native amended graph")
        let amendedCollapsed = try await waitFor {
            !model.expandedCommitIDs.contains(amendedHead.id)
        }
        XCTAssertTrue(amendedCollapsed)

        // AXPress bypasses pointer hit-testing. Send a real AppKit mouseDown/up
        // through the isolated offscreen NSWindow to catch stale hit regions.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        func clickCommitInOffscreenWindow(_ subject: String) throws {
            let element = try commitButton(subject)
            let rect = try XCTUnwrap(
                (attribute(element, "accessibilityFrame") as? NSValue)?.rectValue,
                "A native Graph button must provide its onscreen hit rectangle"
            )
            let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
            XCTAssertTrue(window.contentView?.bounds.contains(point) == true,
                          "The Graph button must be located within its NSWindow")
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: kind, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0
                ))
                window.sendEvent(event)
            }
        }
        try clickCommitInOffscreenWindow("Native amended graph")
        let clickedExpanded = try await waitFor {
            model.expandedCommitIDs.contains(amendedHead.id)
        }
        XCTAssertTrue(clickedExpanded,
                      "Actual mouse down/up must expand new HEAD after repeated commits")
        try clickCommitInOffscreenWindow("Native amended graph")
        let clickedCollapsed = try await waitFor {
            !model.expandedCommitIDs.contains(amendedHead.id)
        }
        XCTAssertTrue(clickedCollapsed,
                      "Actual mouse down/up must collapse new HEAD without changing Project")
    }
}
