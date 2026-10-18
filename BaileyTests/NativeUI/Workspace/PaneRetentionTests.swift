import AppKit
import Observation
import SwiftUI
import WebKit
import XCTest
@testable import Bailey

@MainActor
final class PaneRetentionTests: XCTestCase {
    private func settle(
        _ predicate: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Native panel did not settle", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func testProjectAndPaneTabObservationsReplacePublisherRelays() async throws {
        let project = Project(fallbackName: "observation", workspaceConfiguration: .standard)
        let tab = PaneTab(content: .browser(BrowserTab(initialFocus: .none)))
        project.append(tab)
        let renamed = expectation(description: "Tab rename invalidates the project-backed title")
        withObservationTracking({ _ = project.tabs.first?.displayTitle }) { renamed.fulfill() }
        var snapshots = 0
        project.onSnapshotChange = { snapshots += 1 }
        tab.customName = "Renamed"
        await fulfillment(of: [renamed], timeout: 1)
        XCTAssertEqual(project.tabs.first?.displayTitle, "Renamed")
        XCTAssertGreaterThan(snapshots, 0)

        let other = PaneTab(content: .browser(BrowserTab(initialFocus: .none)))
        project.append(other)
        let selected = expectation(description: "Project selection is directly observed")
        withObservationTracking({ _ = project.selectedTabID }) { selected.fulfill() }
        project.selectedTabID = tab.id
        await fulfillment(of: [selected], timeout: 1)
        XCTAssertTrue(project.selectedTab === tab)
        XCTAssertEqual(project.dock.group(containing: .tab(tab.id))?.selected, .tab(tab.id))
        project.close(other)
        XCTAssertEqual(project.tabs.map(\.id), [tab.id])
        XCTAssertTrue(project.tabs.first === tab)
        project.close(tab)
        XCTAssertTrue(project.tabs.isEmpty)
        XCTAssertTrue(project.dock.tabOrder.isEmpty)
        XCTAssertNil(project.selectedTabID)
    }

    func testNativeUnsavedConfirmationPreservesSheetAndButtonSemantics() async throws {
        let alert = ProjectCloseConfirmation.alert(title: "draft.txt")
        XCTAssertEqual(alert.alertStyle, .warning)
        let title = "draft.txt"
        XCTAssertEqual(alert.messageText, String(
            localized: "Do you want to save the changes you made to \(title)?", table: "Workspace",
            comment: "Unsaved file or diff confirmation. The placeholder is a file name."
        ))
        XCTAssertEqual(alert.informativeText, String(
            localized: "Your changes will be lost if you don't save them.", table: "Workspace"
        ))
        XCTAssertEqual(alert.buttons.map(\.title), [
            String(localized: "Save", table: "Workspace"),
            String(localized: "Don’t Save", table: "Workspace"),
            String(localized: "Cancel", table: "Workspace"),
        ])
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertEqual(alert.buttons[2].keyEquivalent, "\u{1b}")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let response = Task { await ProjectCloseConfirmation.present(title: "draft.txt", in: window) }
        try await settle { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
        let result = await response.value
        XCTAssertEqual(result, .alertThirdButtonReturn)
        try await settle { window.attachedSheet == nil }
    }

    func testNativeFileAndSSHChoosersStayOnOwningWindow() async throws {
        let local = WorkspaceNativeDialogs.localPanel()
        XCTAssertTrue(local.canChooseFiles)
        XCTAssertTrue(local.canChooseDirectories)
        XCTAssertTrue(local.allowsMultipleSelection)
        XCTAssertEqual(local.prompt, String(localized: "Add", table: "Terminal"))
        XCTAssertEqual(local.message, String(localized: "Add files and folders to Bailey", table: "Terminal"))
        let ssh = WorkspaceNativeDialogs.sshForm(aliases: ["fixture-one", "fixture-two"])
        XCTAssertEqual(ssh.alert.buttons.map(\.title), [
            String(localized: "Add", table: "Terminal"),
            String(localized: "Cancel", table: "Terminal"),
        ])
        XCTAssertEqual(ssh.hosts.stringValue, "fixture-one")
        XCTAssertEqual(ssh.hosts.objectValues as? [String], ["fixture-one", "fixture-two"])
        XCTAssertEqual(ssh.alert.accessoryView?.frame.size, NSSize(width: 420, height: 214))
        XCTAssertFalse(ssh.paths.isRichText)
        XCTAssertFalse(ssh.paths.isAutomaticTextReplacementEnabled)

        let previous = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previous)
            TerminalHistoryStore.save(histories)
        }
        let firstManager = TerminalManager()
        let secondManager = TerminalManager()
        defer { firstManager.windowClosed(); secondManager.windowClosed() }
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 420),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        firstManager.attach(to: first)
        secondManager.attach(to: second)
        first.orderFront(nil)
        second.makeKeyAndOrderFront(nil)
        let initialProjectCount = firstManager.projects.count
        firstManager.chooseSSHItems()
        try await settle { first.attachedSheet != nil }
        XCTAssertNil(second.attachedSheet, "A menu action must not attach to the key window of another manager")
        first.endSheet(try XCTUnwrap(first.attachedSheet), returnCode: .alertSecondButtonReturn)
        try await settle { first.attachedSheet == nil }
        firstManager.chooseLocalItems()
        try await settle { first.attachedSheet != nil }
        XCTAssertNil(second.attachedSheet)
        first.endSheet(try XCTUnwrap(first.attachedSheet), returnCode: .cancel)
        try await settle { first.attachedSheet == nil }
        XCTAssertEqual(firstManager.projects.count, initialProjectCount)
    }

    func testTabSwitcherKeepsProvisionalSelectionAndCancelsWithoutSideEffects() async throws {
        let saved = SessionStore.load()
        let history = TerminalHistoryStore.load()
        defer { SessionStore.save(saved); TerminalHistoryStore.save(history) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tab-switcher-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([directory])
        let project = try XCTUnwrap(manager.selectedProject)
        let tabs = (0..<3).map { _ in PaneTab(content: .browser(BrowserTab(initialFocus: .none))) }
        tabs.forEach(project.append)
        XCTAssertEqual(project.selectedTabID, tabs[2].id)
        let switcher = TabSwitcherController()

        func key(_ type: NSEvent.EventType, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: keyCode
            ))
        }

        let previewStarted = expectation(description: "Switcher reports provisional highlight")
        withObservationTracking({ _ = switcher.isPresented; _ = switcher.highlightedTabID }) {
            previewStarted.fulfill()
        }
        let controlTab = try key(.keyDown, 48, [.control])
        XCTAssertNil(switcher.handle(controlTab, manager: manager))
        await fulfillment(of: [previewStarted], timeout: 1)
        XCTAssertTrue(switcher.isPresented)
        XCTAssertEqual(switcher.orderedTabIDs, [tabs[2].id, tabs[1].id, tabs[0].id])
        XCTAssertEqual(switcher.highlightedTabID, tabs[1].id)
        XCTAssertEqual(project.selectedTabID, tabs[2].id)

        // A stationary pointer must not replace the keyboard highlight.
        switcher.highlight(tabs[0].id, in: project)
        XCTAssertEqual(switcher.highlightedTabID, tabs[1].id)
        XCTAssertNil(switcher.handle(controlTab, manager: manager))
        XCTAssertEqual(switcher.highlightedTabID, tabs[0].id)
        XCTAssertEqual(project.selectedTabID, tabs[2].id)

        let release = try key(.flagsChanged, 59, [])
        XCTAssertNil(switcher.handle(release, manager: manager))
        XCTAssertFalse(switcher.isPresented)
        XCTAssertEqual(project.selectedTabID, tabs[0].id)
        XCTAssertEqual(switcher.highlightedTabID, nil)

        // A reverse cycle can be canceled by Escape without committing.
        let original = project.selectedTabID
        XCTAssertNil(switcher.handle(try key(.keyDown, 48, [.control, .shift]), manager: manager))
        XCTAssertTrue(switcher.isPresented)
        XCTAssertEqual(project.selectedTabID, original)
        XCTAssertNil(switcher.handle(try key(.keyDown, 53, [.control]), manager: manager))
        XCTAssertFalse(switcher.isPresented)
        XCTAssertEqual(project.selectedTabID, original)
        XCTAssertNotNil(switcher.handle(release, manager: manager))

        // Closing a candidate during preview cannot select a removed tab.
        XCTAssertNil(switcher.handle(controlTab, manager: manager))
        let candidate = try XCTUnwrap(switcher.highlightedTabID)
        let closing = try XCTUnwrap(project.tabs.first { $0.id == candidate })
        project.close(closing)
        XCTAssertNil(switcher.handle(release, manager: manager))
        XCTAssertNotEqual(project.selectedTabID, candidate)
        XCTAssertTrue(project.tabs.contains { $0.id == project.selectedTabID })
    }

    func testFPSCounterExposesOnlyPresentationAndStopsCleanly() async throws {
        let counter = FPSCounter()
        XCTAssertEqual(counter.fps, 0)
        let changed = expectation(description: "FPS is directly observable")
        withObservationTracking({ _ = counter.fps }) { changed.fulfill() }
        try await Task.sleep(for: .milliseconds(1100))
        counter.tick()
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertGreaterThan(counter.fps, 0)
        counter.stop()
        XCTAssertEqual(counter.fps, 0)
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

    func testWebKitJavaScriptDialogsInvokeNativeDelegateSheets() async throws {
        let browser = BrowserTab(initialFocus: .none)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: BrowserView(
            browser: browser, isFocused: true, onFocused: {}, onNewBrowserTab: { _ in }
        ))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        browser.webView.loadHTMLString("<title>Delegate fixture</title>", baseURL: nil)
        try await settle { browser.title == "Delegate fixture" && !browser.isLoading }

        let alertTask = Task { @MainActor in
            _ = try await browser.webView.evaluateJavaScript("alert('Native alert check')")
            return true
        }
        try await settle { window.attachedSheet != nil }
        let alertSheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(alertSheet, returnCode: .alertFirstButtonReturn)
        let alertCompleted = try await alertTask.value
        XCTAssertTrue(alertCompleted)

        let confirmTask = Task {
            try await browser.webView.evaluateJavaScript("confirm('Native confirmation')") as? Bool
        }
        try await settle { window.attachedSheet != nil }
        let confirmSheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(confirmSheet, returnCode: .alertSecondButtonReturn)
        let confirmed = try await confirmTask.value
        XCTAssertEqual(confirmed, false)

        let promptTask = Task {
            try await browser.webView.evaluateJavaScript("prompt('Native prompt', 'default-text')") as? String
        }
        try await settle { window.attachedSheet != nil }
        let promptSheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(promptSheet, returnCode: .alertFirstButtonReturn)
        let prompted = try await promptTask.value
        XCTAssertEqual(prompted, "default-text")
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
        try await file.waitForText()
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


    func testFiveConcurrentNativeEditorsReleaseDocumentAndParsingTasks() async throws {
        final class WeakEditor {
            weak var editor: FocusReportingTextView?
            init(_ editor: FocusReportingTextView) { self.editor = editor }
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-native-5tabs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let baseline = String(repeating: "let item = \"中文 👋\" // exact data\n", count: 10_000)
        var files: [FileTab] = []
        var windows: [NSWindow] = []
        var hosts: [NSHostingView<SourceTextEditor>] = []
        var weakEditors: [WeakEditor] = []
        for i in 0..<5 {
            let url = folder.appendingPathComponent("source\(i).swift")
            try baseline.write(to: url, atomically: true, encoding: .utf8)
            let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared,
                               workspaceIdentity: nil)
            try await file.waitForText()
            let host = NSHostingView(rootView: SourceTextEditor(
                file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                palette: .theme(dark: i.isMultiple(of: 2)),
                wrapLines: !i.isMultiple(of: 2), isFocused: false
            ))
            host.frame = NSRect(x: 0, y: 0, width: 680, height: 450)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await settle { file.editorView != nil }
            let editor = try XCTUnwrap((file.editorView as? NSScrollView)?
                .documentView as? FocusReportingTextView)
            XCTAssertEqual(editor.string, baseline)
            XCTAssertNotNil(editor.syntaxCoordinator)
            editor.insertText(String(i), replacementRange: NSRange(location: 0, length: 0))
            try await settle { file.isDirty && file.text.hasPrefix(String(i)) }
            editor.undoManager?.undo()
            try await settle { file.text == baseline && !file.isDirty }
            XCTAssertEqual(editor.string, baseline)
            files.append(file)
            hosts.append(host)
            windows.append(window)
            weakEditors.append(WeakEditor(editor))
        }
        print("T5_NATIVE_LIFETIME simultaneous=\(weakEditors.count) allRetained=\(weakEditors.allSatisfy { $0.editor != nil })")
        XCTAssertTrue(weakEditors.allSatisfy { $0.editor != nil })
        // Destroy real owners, not just the currently visible NSView. The
        // editor's notification subscription and queued parser work must not
        // retain retired documents after the last FileTab is gone.
        for i in (0..<windows.count).reversed() {
            hosts[i].removeFromSuperview()
            windows[i].contentView = nil
            windows[i].close()
        }
        hosts.removeAll()
        windows.removeAll()
        files.removeAll()
        try await settle { weakEditors.allSatisfy { $0.editor == nil } }
        XCTAssertTrue(weakEditors.allSatisfy { $0.editor == nil })
        print("T5_NATIVE_LIFETIME simultaneous=5 released=5")
    }

    func testEditorRetainsScrollAndReleasesRetiredNativeResources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scroll.txt")
        let contents = (0..<400).map { "Line \($0) 中文 😀\r\n" }.joined()
        try contents.write(to: path, atomically: true, encoding: .utf8)
        var file: FileTab? = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file?.waitForText()
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
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        // Derive the insertion point from the rendered viewport, not a fixed
        // line number: fonts and pane heights vary across macOS/Xcode runners.
        // A caret outside the pane makes AppKit legitimately scroll it into view.
        let point = CGPoint(x: 20, y: scroll.contentView.bounds.minY + 30)
        let screenPoint = window.convertPoint(toScreen: editor.convert(point, to: nil))
        let offset = editor.characterIndex(for: screenPoint)
        print("DOCK_TRACE beforeHit offset=\(offset) editorSize=\(editor.frame) scroll=\(scroll.contentView.bounds) selected=\(editor.selectedRange()) firstResponder=\(window.firstResponder === editor)")
        XCTAssertNotEqual(offset, NSNotFound)
        editor.textSelection = NSRange(location: offset, length: 0)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        let scrollBefore = scroll.contentView.bounds.origin
        let heightBefore = scroll.bounds.height
        print("DOCK_TRACE beforeMove desired=\(scrollBefore) editorFrame=\(editor.frame) selection=\(editor.selectedRange()) viewport=\(String(describing: editor.textLayoutManager?.textViewportLayoutController.viewportRange))")
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
        print("DOCK_TRACE afterMove actual=\(scroll.contentView.bounds.origin) editorFrame=\(editor.frame) selection=\(editor.selectedRange()) viewport=\(String(describing: editor.textLayoutManager?.textViewportLayoutController.viewportRange))")
        try await settle { scroll.contentView.bounds.origin == scrollBefore }
        XCTAssertEqual(scroll.contentView.bounds.origin, scrollBefore)
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        let background = try XCTUnwrap(scroll.backgroundColor.usingColorSpace(.deviceRGB))
        let scale = CGFloat(bitmap.pixelsWide) / scroll.bounds.width
        let glyphPixels = (Int(25 * scale)..<min(bitmap.pixelsHigh, Int(140 * scale)))
            .reduce(0) { count, y in
                count + (Int(80 * scale)..<min(bitmap.pixelsWide, Int(260 * scale)))
                    .filter { x in
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                        else { return false }
                        return max(abs(c.redComponent - background.redComponent),
                                   abs(c.greenComponent - background.greenComponent),
                                   abs(c.blueComponent - background.blueComponent)) > 0.3
                    }.count
            }
        XCTAssertGreaterThan(glyphPixels, 30,
            "Dock reparent must restore visible Source glyphs, not only the scroll origin")
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
