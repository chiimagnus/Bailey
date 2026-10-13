import AppKit
import Observation
import SwiftUI
import WebKit
import XCTest
@testable import kero

@MainActor
final class PaneRetentionTests: XCTestCase {
    private func settle(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else { return XCTFail("Native panel did not settle") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func testBrowserKVOUpdatesObservationHistoryFaviconAndRepeatedFocus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.html")
        let second = directory.appendingPathComponent("second.html")
        let icon = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jMZkAAAAASUVORK5CYII="
        try "<title>First fixture</title><link rel='icon' href='\(icon)'><input id='draft'>".write(to: first, atomically: true, encoding: .utf8)
        try "<title>Second fixture</title>Second page".write(to: second, atomically: true, encoding: .utf8)
        let browser = BrowserTab(initialFocus: .none)
        let native = browser.webView
        let project = Project(fallbackName: "browser", workspaceConfiguration: .standard)
        project.append(PaneTab(content: .browser(browser)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BrowserView(
            browser: browser, isFocused: true, onFocused: {}, onNewBrowserTab: { _ in }
        ))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.close() }

        let titleChanged = expectation(description: "WebKit title KVO updates the observed title")
        withObservationTracking({ _ = project.tabs[0].displayTitle }) { titleChanged.fulfill() }
        let navigationChanged = expectation(description: "WebKit URL KVO updates snapshot semantics")
        browser.onSnapshotChange = { navigationChanged.fulfill() }
        native.loadFileURL(first, allowingReadAccessTo: directory)
        try await settle { browser.title == "First fixture" && !browser.isLoading }
        await fulfillment(of: [titleChanged, navigationChanged], timeout: 1)
        browser.onSnapshotChange = nil
        XCTAssertEqual(browser.snapshotURL, first.absoluteString)
        XCTAssertNil(browser.shareURL)
        try await settle { browser.favicon != nil }
        XCTAssertEqual(browser.favicon?.size, NSSize(width: 1, height: 1))
        _ = try await native.evaluateJavaScript("document.getElementById('draft').value='retained draft'")

        native.loadFileURL(second, allowingReadAccessTo: directory)
        try await settle { browser.title == "Second fixture" && !browser.isLoading }
        XCTAssertEqual(browser.snapshotURL, second.absoluteString)
        XCTAssertTrue(browser.canGoBack)
        browser.goBack()
        try await settle { browser.title == "First fixture" && !browser.isLoading }
        XCTAssertTrue(browser.canGoForward)
        let restored = try await native.evaluateJavaScript("document.getElementById('draft').value") as? String
        XCTAssertEqual(restored, "retained draft")
        browser.goForward()
        try await settle { browser.title == "Second fixture" && !browser.isLoading }
        XCTAssertTrue(browser.webView === native)

        let focused = expectation(description: "Repeated address focus requests are observable")
        withObservationTracking({ _ = browser.focusAddressRequest }) { focused.fulfill() }
        let initialRequest = browser.focusAddressRequest
        browser.requestAddressFocus()
        await fulfillment(of: [focused], timeout: 1)
        try await settle {
            (window.firstResponder as? NSTextView)?.string == second.absoluteString
        }
        let addressEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(addressEditor.selectedRange(), NSRange(location: 0, length: second.absoluteString.utf16.count))
        addressEditor.setSelectedRange(NSRange(location: 0, length: 0))
        browser.requestAddressFocus()
        XCTAssertEqual(browser.focusAddressRequest, initialRequest + 2)
        try await settle { addressEditor.selectedRange().length == second.absoluteString.utf16.count }
        XCTAssertTrue(browser.webView === native)
    }

    func testBrowserAndEditorStateSurviveViewRemount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = directory.appendingPathComponent("page.html")
        try "<title>Retention</title><input id='value'><div style='height:5000px'></div>".write(
            to: page, atomically: true, encoding: .utf8
        )
        let filePath = directory.appendingPathComponent("dirty.txt").path
        try Data("baseline\n".utf8).write(to: URL(fileURLWithPath: filePath))

        let browser = BrowserTab(initialFocus: .none)
        let browserTab = PaneTab(content: .browser(browser))
        let file = FileTab(path: filePath, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        let fileTab = PaneTab(content: .file(file))
        let project = Project(fallbackName: "retention", workspaceConfiguration: .standard)
        project.append(browserTab)
        project.append(fileTab)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFront(nil)
        defer { window.close() }

        func browserHost() -> NSHostingView<PanelContentView> {
            let view = NSHostingView(rootView: PanelContentView(
                tab: browserTab, isSelected: false,
                onFocused: {}, onNewBrowserTab: { _ in }, onNewFileTab: { _ in }
            ))
            view.frame = container.bounds
            container.addSubview(view)
            view.layoutSubtreeIfNeeded()
            return view
        }
        var browserView: NSHostingView<PanelContentView>? = browserHost()
        let webView = browser.webView
        webView.loadFileURL(page, allowingReadAccessTo: directory)
        try await settle { webView.title == "Retention" && !webView.isLoading }
        _ = try await webView.evaluateJavaScript("document.getElementById('value').value='unsaved'; window.scrollTo(0, 900)")
        let before = try await webView.evaluateJavaScript("document.getElementById('value').value + ':' + scrollY") as! String
        browserView?.removeFromSuperview()
        browserView = browserHost()
        try await Task.sleep(for: .milliseconds(100))
        let after = try await webView.evaluateJavaScript("document.getElementById('value').value + ':' + scrollY") as! String
        XCTAssertEqual(after, before)
        XCTAssertTrue(browser.webView === webView)
        browserView?.removeFromSuperview()

        func editorHost() -> NSHostingView<PanelContentView> {
            let view = NSHostingView(rootView: PanelContentView(
                tab: fileTab, isSelected: false,
                onFocused: {}, onNewBrowserTab: { _ in }, onNewFileTab: { _ in }
            ))
            view.frame = container.bounds
            container.addSubview(view)
            view.layoutSubtreeIfNeeded()
            return view
        }
        var editorView: NSHostingView<PanelContentView>? = editorHost()
        try await settle { file.editorView != nil }
        let editor = try XCTUnwrap((file.editorView as? NSScrollView)?.documentView as? FocusReportingTextView)
        editor.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        try await settle { file.text.hasPrefix("edited ") }
        XCTAssertTrue(file.isDirty)
        let undoManager = try XCTUnwrap(editor.undoManager)
        undoManager.undo()
        try await settle { file.text == "baseline\n" }
        XCTAssertFalse(file.isDirty)
        undoManager.redo()
        try await settle { file.text.hasPrefix("edited ") }
        XCTAssertTrue(file.isDirty)
        editor.textSelection = NSRange(location: 3, length: 2)
        try await settle { file.editorState.selectionLocation == 3 }
        editorView?.removeFromSuperview()
        editorView = editorHost()
        try await settle { file.editorView != nil }
        let restored = try XCTUnwrap((file.editorView as? NSScrollView)?.documentView as? FocusReportingTextView)
        XCTAssertEqual(restored.text, file.text)
        XCTAssertEqual(restored.textSelection, NSRange(location: 3, length: 2))
        XCTAssertTrue(file.isDirty)
        XCTAssertTrue(restored === editor)
        let restoredUndo = try XCTUnwrap(restored.undoManager)
        XCTAssertTrue(restoredUndo.canUndo)
        restoredUndo.undo()
        try await settle { file.text == "baseline\n" }
        XCTAssertFalse(file.isDirty)
        restoredUndo.redo()
        try await settle { file.text.hasPrefix("edited ") }
        XCTAssertTrue(file.isDirty)
        editorView?.removeFromSuperview()
    }

    func testEditorRetainsScrollAndReleasesRetiredNativeResources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scroll.txt")
        let contents = (0..<400).map { "Line \($0) 中文 😀\r\n" }.joined()
        try contents.write(to: path, atomically: true, encoding: .utf8)
        var file: FileTab? = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        weak var releasedFile = file
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFront(nil)
        defer { window.close() }

        func mount(_ file: FileTab) -> NSHostingView<SourceTextEditor> {
            let host = NSHostingView(rootView: SourceTextEditor(
                file: file, font: .monospacedSystemFont(ofSize: 14, weight: .regular),
                palette: .theme(dark: true), wrapLines: false, isFocused: false
            ))
            host.frame = container.bounds
            container.addSubview(host)
            host.layoutSubtreeIfNeeded()
            return host
        }
        var host: NSHostingView<SourceTextEditor>? = mount(try XCTUnwrap(file))
        try await settle { file?.editorView != nil }
        var retiredScroll: NSScrollView? = file?.editorView as? NSScrollView
        var retiredEditor: FocusReportingTextView? = try XCTUnwrap(retiredScroll?.documentView as? FocusReportingTextView)
        weak var releasedEditor = retiredEditor
        retiredScroll?.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900))
        retiredScroll?.reflectScrolledClipView(try XCTUnwrap(retiredScroll?.contentView))
        let before = try XCTUnwrap(retiredScroll?.contentView.bounds.origin)
        XCTAssertGreaterThan(before.y, 0)
        host?.removeFromSuperview()
        host = nil
        host = mount(try XCTUnwrap(file))
        try await settle { file?.editorView != nil }
        XCTAssertTrue(file?.editorView === retiredScroll)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(retiredScroll?.contentView.bounds.origin, before)
        XCTAssertEqual(retiredEditor?.text, contents)

        host?.removeFromSuperview()
        host = nil
        try "changed on disk\n".write(to: path, atomically: true, encoding: .utf8)
        file?.reloadFromDiskIfClean()
        try await settle { file?.text == "changed on disk\n" }
        retiredEditor?.insertText("stale editor", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(file?.text, "changed on disk\n")
        XCTAssertFalse(try XCTUnwrap(file).isDirty)
        host = mount(try XCTUnwrap(file))
        try await settle { file?.editorView != nil }
        weak var currentEditor = (file?.editorView as? NSScrollView)?.documentView
        XCTAssertFalse(currentEditor === retiredEditor)
        XCTAssertEqual((currentEditor as? FocusReportingTextView)?.text, "changed on disk\n")
        XCTAssertFalse((currentEditor as? FocusReportingTextView)?.undoManager?.canUndo ?? true)
        retiredScroll = nil
        retiredEditor = nil
        try await settle { releasedEditor == nil }
        host?.removeFromSuperview()
        host = nil
        file = nil
        try await settle { releasedFile == nil && currentEditor == nil }
    }

    func testObservedDockMoveReparentsRealEditorAndPreservesUndoAndScroll() async throws {
        let previousWindows = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previousWindows)
            TerminalHistoryStore.save(previousHistories)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("dock.txt")
        let original = (0..<400).map { "Line \($0) 中文😀\n" }.joined()
        try original.write(to: path, atomically: true, encoding: .utf8)
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([path])
        let project = try XCTUnwrap(manager.selectedProject)
        let pane = try XCTUnwrap(project.selectedTab)
        guard case .file(let file) = pane.content else { return XCTFail("Expected a file") }
        let git = GitStatusModel()
        let host = NSHostingView(rootView: WorkspaceDockView(manager: manager, git: git))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        manager.attach(to: window)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        try await settle { file.editorView?.window === window }
        let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
        let editor = try XCTUnwrap(scroll.documentView as? FocusReportingTextView)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("E", replacementRange: NSRange(location: 0, length: 0))
        try await settle { file.isDirty }
        // Keep the insertion point inside the viewport while checking native reparenting.
        editor.textSelection = NSRange(location: (original as NSString).range(of: "Line 40").location + 1, length: 0)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        let scrollBefore = scroll.contentView.bounds.origin
        let heightBefore = scroll.bounds.height
        let target = try XCTUnwrap(project.dock.group(containing: .files))
        XCTAssertTrue(project.dock.move(.tab(pane.id), into: target.id, edge: .bottom))
        try await settle {
            file.editorView === scroll && scroll.window === window
                && scroll.bounds.height > 0 && scroll.bounds.height < heightBefore
        }
        XCTAssertEqual(project.dock.tabOrder, [pane.id])
        XCTAssertEqual(project.selectedTabID, pane.id)
        XCTAssertTrue(scroll.documentView === editor)
        try await settle { window.firstResponder === editor }
        XCTAssertEqual(scroll.contentView.bounds.origin, scrollBefore)
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        try await settle { file.text == original }
        XCTAssertFalse(file.isDirty)
        undo.redo()
        try await settle { file.text == "E" + original }
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), original)
    }

    func testTerminalAndFindObservationPreserveNativeSurfaceIdentity() async throws {
        let terminal = TerminalSession(launchCommand: "exec /bin/sh -i")
        defer { terminal.terminate() }
        let surface = terminal.surface
        let project = Project(fallbackName: "fallback", workspaceConfiguration: .standard)
        project.append(PaneTab(content: .session(terminal)))

        let projectNameChanged = expectation(description: "Project title follows observed session")
        withObservationTracking({ _ = project.name }) { projectNameChanged.fulfill() }
        let titleChanged = expectation(description: "Terminal title observation")
        withObservationTracking({ _ = terminal.title }) { titleChanged.fulfill() }
        terminal.terminalDidChangeTitle("Observed title")
        await fulfillment(of: [titleChanged, projectNameChanged], timeout: 2)
        XCTAssertEqual(terminal.title, "Observed title")
        XCTAssertEqual(project.name, "Observed title")

        let commandChanged = expectation(description: "Real command completion observation")
        withObservationTracking({ _ = terminal.commandLifecycle.completionSequence }) {
            commandChanged.fulfill()
        }
        let previous = terminal.commandLifecycle.completionSequence
        terminal.terminalDidReportShellIntegration(
            .commandFinished(exitCode: 0, durationNanos: 1_000_000)
        )
        await fulfillment(of: [commandChanged], timeout: 2)
        XCTAssertEqual(terminal.commandLifecycle.completionSequence, previous + 1)

        let findChanged = expectation(description: "Find focus request observation")
        withObservationTracking({ _ = terminal.find.focusRequest }) {
            findChanged.fulfill()
        }
        terminal.find.present()
        await fulfillment(of: [findChanged], timeout: 2)
        XCTAssertTrue(terminal.find.isPresented)
        let firstFocus = terminal.find.focusRequest
        terminal.find.present()
        XCTAssertEqual(terminal.find.focusRequest, firstFocus + 1)
        terminal.find.dismiss()
        XCTAssertFalse(terminal.find.isPresented)

        // A headless/closed Ghostty surface must deny OSC 52 rather than
        // accidentally authorizing clipboard access or leaving it unresolved.
        var decisions: [Bool] = []
        terminal.terminalDidRequestClipboardConfirmation(
            TerminalClipboardRequest(
                kind: .programRead, contents: "test clipboard",
                resolve: { decisions.append($0) }
            )
        )
        XCTAssertEqual(decisions, [false])
        XCTAssertTrue(terminal.surface === surface)
    }

    func testTerminalKeepsSameShellAcrossParkingAndRemount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let terminal = TerminalSession(initialDirectory: directory.path, launchCommand: "exec /bin/sh -i")
        defer { terminal.terminate() }
        let tab = PaneTab(content: .session(terminal))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        func host() -> NSHostingView<PanelContentView> {
            let view = NSHostingView(rootView: PanelContentView(
                tab: tab, isSelected: false,
                onFocused: {}, onNewBrowserTab: { _ in }, onNewFileTab: { _ in }
            ))
            view.frame = container.bounds
            return view
        }
        var mounted: NSHostingView<PanelContentView>? = host()
        window.contentView = mounted
        window.orderFront(nil)
        mounted?.layoutSubtreeIfNeeded()
        try await settle { terminal.shellPid != nil }

        let beforeURL = directory.appendingPathComponent("pid-before")
        terminal.sendCommand("printf '%s' $$ > '\(beforeURL.path)'\r")
        try await settle { FileManager.default.fileExists(atPath: beforeURL.path) }
        let before = try String(contentsOf: beforeURL, encoding: .utf8)
        let surface = terminal.surface

        let parking = NSHostingView(rootView: TerminalParkingView(sessions: [terminal]))
        parking.frame = container.bounds
        window.contentView = parking
        mounted = nil
        parking.layoutSubtreeIfNeeded()
        let parkedURL = directory.appendingPathComponent("pid-parked")
        terminal.sendCommand("printf '%s' $$ > '\(parkedURL.path)'\r")
        try await settle { FileManager.default.fileExists(atPath: parkedURL.path) }
        XCTAssertEqual(try String(contentsOf: parkedURL, encoding: .utf8), before)

        mounted = host()
        window.contentView = mounted
        mounted?.layoutSubtreeIfNeeded()
        let afterURL = directory.appendingPathComponent("pid-after")
        terminal.sendCommand("printf '%s' $$ > '\(afterURL.path)'\r")
        try await settle { FileManager.default.fileExists(atPath: afterURL.path) }
        XCTAssertEqual(try String(contentsOf: afterURL, encoding: .utf8), before)
        XCTAssertTrue(terminal.surface === surface)
    }
}
