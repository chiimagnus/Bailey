import AppKit
import Observation
import SwiftUI
import WebKit
import XCTest
@testable import Bailey

/// Minimal component compositions for lifecycle assertions. No full Dock or
/// ContentView is assembled inside the host Test Target.
private struct NativeRetainedFiles: View {
    let project: Project

    var body: some View {
        HStack(spacing: 0) {
            ForEach(project.tabs, id: \.id) { tab in
                if case .file(let file) = tab.content {
                    FileViewerView(file: file)
                        .id(tab.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

private struct NativeSelectedFile: View {
    let project: Project

    var body: some View {
        Group {
            if let tab = project.selectedTab, case .file(let file) = tab.content {
                FileViewerView(file: file).id(tab.id)
            }
        }
    }
}

@MainActor
final class NativePaneRetentionIntegrationTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    func testParkingDropsObsoleteHostActionsBeforeDelayedDismantle() async throws {
        let terminal = TerminalSession(launchCommand: "exec /bin/sh -i")
        defer { terminal.terminate() }
        let container = NSView(frame: .init(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = container
        let host = NSHostingView(rootView: TerminalHostView(
            session: terminal, isFocused: false, onFocused: {},
            onNewBrowserTab: { _ in }, onNewFileTab: { _ in }
        ))
        host.frame = container.bounds
        container.addSubview(host)
        window.orderFront(nil)
        try await settle {
            host.layoutSubtreeIfNeeded()
            return terminal.surface.superview is TerminalContainerView
        }
        let previous = try XCTUnwrap(terminal.surface.superview as? TerminalContainerView)
        XCTAssertNotNil(terminal.surface.onBecomeFirstResponder)
        XCTAssertNotNil(terminal.surface.openMenuTarget.onNewBrowserTab)
        let parking = TerminalParkingContainerView(frame: .zero)
        container.addSubview(parking)
        parking.mount([terminal])
        XCTAssertTrue(terminal.surface.superview === parking)
        XCTAssertTrue(terminal.surface.window === window)
        XCTAssertNil(terminal.surface.onBecomeFirstResponder)
        XCTAssertNil(terminal.surface.openMenuTarget.onNewBrowserTab)
        XCTAssertNil(terminal.surface.openMenuTarget.onNewFileTab)
        TerminalHostView.dismantleNSView(previous, coordinator: TerminalHostView.Coordinator())
        XCTAssertTrue(terminal.surface.superview === parking)
    }

    func testTerminalFindFieldStaysInsideNarrowAndWidePanes() async throws {
        let terminal = TerminalSession(launchCommand: "exec /bin/sh -i")
        defer { terminal.terminate() }
        let host = NSHostingView(rootView: TerminalFindBar(find: terminal.find))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable,
               field.window === window, !field.isHiddenOrHasHiddenAncestor { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [150.0, 210.0, 400.0, 900.0] {
                window.setContentSize(NSSize(width: width, height: 100))
                try await settle {
                    host.layoutSubtreeIfNeeded()
                    return field(in: host) != nil && abs(host.bounds.width - width) < 1
                }
                let input = try XCTUnwrap(field(in: host))
                let frame = host.convert(input.bounds, from: input)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX)
                XCTAssertGreaterThan(frame.width, 20)
            }
        }
    }

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
        project.selectTab(tab.id)
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
        let local = WorkspaceNativeDialogs.folderPanel()
        XCTAssertFalse(local.canChooseFiles, "Add Folder must not offer to create pinned-file projects")
        XCTAssertTrue(local.canChooseDirectories)
        XCTAssertTrue(local.allowsMultipleSelection)
        XCTAssertEqual(local.prompt, String(localized: "Add", table: "Terminal"))
        XCTAssertEqual(local.message, String(localized: "Add folders to Bailey", table: "Terminal"))
        let files = WorkspaceNativeDialogs.filePanel()
        XCTAssertTrue(files.canChooseFiles)
        XCTAssertFalse(files.canChooseDirectories)
        XCTAssertTrue(files.allowsMultipleSelection)
        XCTAssertEqual(files.prompt, String(localized: "Open", table: "Sidebar"))
        XCTAssertEqual(files.message, String(localized: "Open files in Bailey", table: "Terminal"))
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
        let firstManager = self.workspaceApplication.makeWindow()
        let secondManager = self.workspaceApplication.makeWindow()
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
        firstManager.chooseFolders()
        try await settle { first.attachedSheet != nil }
        XCTAssertNil(second.attachedSheet)
        first.endSheet(try XCTUnwrap(first.attachedSheet), returnCode: .cancel)
        try await settle { first.attachedSheet == nil }
        XCTAssertEqual(firstManager.projects.count, initialProjectCount)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("p4-picker-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        firstManager.addLocalFolders([folder])
        second.makeKeyAndOrderFront(nil)
        firstManager.chooseFiles()
        try await settle { first.attachedSheet != nil }
        XCTAssertNil(second.attachedSheet, "The Open File sheet belongs to its caller")
        let panel = try XCTUnwrap(first.attachedSheet as? NSOpenPanel)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        first.endSheet(panel, returnCode: .cancel)
        try await settle { first.attachedSheet == nil }
        XCTAssertTrue(firstManager.selectedProject?.tabs.isEmpty == true)
        XCTAssertEqual(firstManager.projects.count, initialProjectCount + 1)
    }

    func testTabSwitcherKeepsProvisionalSelectionAndCancelsWithoutSideEffects() async throws {
        let saved = SessionStore.load()
        let history = TerminalHistoryStore.load()
        defer { SessionStore.save(saved); TerminalHistoryStore.save(history) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tab-switcher-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([directory])
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
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
                tab: browserTab, isFocused: false,
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
                tab: fileTab, isFocused: false,
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


    func testClosingMountedFiveFileTabsReleasesTheirNativeDocuments() async throws {
        final class WeakNativeContent {
            weak var file: FileTab?
            weak var editor: FocusReportingTextView?
            init(file: FileTab, editor: FocusReportingTextView) {
                self.file = file
                self.editor = editor
            }
        }

        let previousWindows = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previousWindows)
            TerminalHistoryStore.save(previousHistories)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-native-close-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = try (0..<5).map { i -> URL in
            let path = folder.appendingPathComponent("pane-\(i).swift")
            try String(repeating: "let value = \"中文 👋\"\n", count: 1_000)
                .write(to: path, atomically: true, encoding: .utf8)
            return path
        }
        var weakContents: [WeakNativeContent] = []
        var secondWeakContents: [WeakNativeContent] = []
        do {
            let manager = self.workspaceApplication.makeWindow()
            defer { manager.windowClosed() }
            manager.addLocalFolders([folder])
            manager.openFile(paths[0].path)
            let project = try XCTUnwrap(manager.selectedProject)
            for path in paths.dropFirst() { project.openFile(path.path) }
            let tabs = project.tabs.map(\.id)
            XCTAssertEqual(tabs.count, 5)
            let groups = (0..<5).map { index in
                DockSavedNode.group(DockSavedGroup(id: UUID(), items: [.tab(index)], selected: .tab(index)))
            }
            let layout = groups.dropFirst().reduce(groups[0]) { partial, group in
                DockSavedNode.split(id: UUID(), axis: .horizontal, fraction: 0.5,
                                    first: partial, second: group)
            }
            project.dock.restore(layout, tabIDs: tabs)
            let host = NSHostingView(rootView: NativeRetainedFiles(project: project))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_700, height: 650),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            manager.attach(to: window)
            window.orderFront(nil)
            try await settle {
                host.layoutSubtreeIfNeeded()
                return project.tabs.allSatisfy { tab in
                    guard case .file(let file) = tab.content else { return false }
                    return (file.editorView as? NSScrollView)?.documentView is FocusReportingTextView
                }
            }
            for tab in project.tabs {
                guard case .file(let file) = tab.content else { continue }
                let editor = try XCTUnwrap((file.editorView as? NSScrollView)?
                    .documentView as? FocusReportingTextView)
                XCTAssertNotNil(editor.syntaxCoordinator)
                weakContents.append(WeakNativeContent(file: file, editor: editor))
            }
            XCTAssertEqual(weakContents.count, 5)
            let cachedScrollViews = project.tabs.compactMap { tab -> NSScrollView? in
                guard case .file(let file) = tab.content else { return nil }
                return file.editorView as? NSScrollView
            }
            XCTAssertEqual(cachedScrollViews.count, 5)
            do {
                let selected = try XCTUnwrap(project.selectedTab)
                guard case .file(let file) = selected.content else {
                    return XCTFail("Expected selected file")
                }
                let focusedEditor = try XCTUnwrap((file.editorView as? NSScrollView)?
                    .documentView as? FocusReportingTextView)
                XCTAssertTrue(window.makeFirstResponder(focusedEditor))
                XCTAssertTrue(window.firstResponder === focusedEditor)
            }
            project.closeFiles()
            XCTAssertTrue(project.tabs.isEmpty)
            XCTAssertTrue(cachedScrollViews.allSatisfy { $0.documentView == nil },
                          "Actual tab closure must retire document views even when AppKit caches old scroll views")
            try await settle { weakContents.allSatisfy { $0.file == nil } }
            XCTAssertTrue(weakContents.allSatisfy { $0.editor?.syntaxCoordinator == nil },
                          "An AppKit-cached native view must not keep its retired parser active")

            // Closing the whole project is another semantic close; the window
            // remains alive and AppKit may retain all five former scroll views.
            for path in paths { project.openFile(path.path) }
            XCTAssertEqual(project.tabs.count, 5)
            project.dock.restore(layout, tabIDs: project.tabs.map(\.id))
            try await settle {
                host.layoutSubtreeIfNeeded()
                return project.tabs.allSatisfy { tab in
                    guard case .file(let file) = tab.content else { return false }
                    return (file.editorView as? NSScrollView)?.documentView is FocusReportingTextView
                }
            }
            let projectScrollViews = project.tabs.compactMap { tab -> NSScrollView? in
                guard case .file(let file) = tab.content else { return nil }
                return file.editorView as? NSScrollView
            }
            XCTAssertEqual(projectScrollViews.count, 5)
            for tab in project.tabs {
                if case .file(let file) = tab.content,
                   let editor = (file.editorView as? NSScrollView)?.documentView as? FocusReportingTextView {
                    secondWeakContents.append(WeakNativeContent(file: file, editor: editor))
                }
            }
            XCTAssertEqual(secondWeakContents.count, 5)
            manager.close(project)
            XCTAssertFalse(manager.projects.contains { $0 === project })
            XCTAssertTrue(project.tabs.isEmpty, "Closing a project must release every owned tab")
            XCTAssertTrue(projectScrollViews.allSatisfy { $0.documentView == nil },
                          "Closing a project must retire native documents retained by cached AppKit views")
            XCTAssertTrue(secondWeakContents.allSatisfy { $0.editor?.syntaxCoordinator == nil })
        }
        // AppKit may retain a detached text view while the hosting window is alive.
        // After its real owners are torn down, neither generation may survive.
        try await settle {
            (weakContents + secondWeakContents).allSatisfy { $0.file == nil && $0.editor == nil }
        }
        XCTAssertTrue((weakContents + secondWeakContents).allSatisfy {
            $0.file == nil && $0.editor == nil
        })
    }

    func testClosingNativeWindowReleasesItsProjectBeforeSwiftUIDisappears() throws {
        let previousWindows = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previousWindows)
            TerminalHistoryStore.save(previousHistories)
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-closed-window-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("sample.swift")
        try "let value = \"中文 👋\"\n".write(to: path, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([folder])
        manager.openFile(path.path)
        weak var retiredFile: FileTab?
        do {
            let pane = try XCTUnwrap(manager.selectedProject?.selectedTab)
            guard case .file(let file) = pane.content else {
                return XCTFail("Expected file to be owned by closed window")
            }
            retiredFile = file
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        window.orderFront(nil)
        window.close()

        XCTAssertNil(manager.attachedWindow,
                     "NSWindow close must release its manager before SwiftUI onDisappear")
        XCTAssertFalse(self.workspaceApplication.containsWindow(manager))
        XCTAssertTrue(manager.projects.isEmpty,
                      "Closing the native window must release its project owner")
        XCTAssertNil(retiredFile, "Closing the window must release its owned FileTab")
    }

    func testHundredThousandLineWorkspaceEditsSavesAndReleasesFile() async throws {
        let previousWindows = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previousWindows)
            TerminalHistoryStore.save(previousHistories)
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-100k-workspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("large.swift")
        let source = (0..<100_000).map { row in
            "let value_\(row) = \(row) // 中文 👋 edit undo find verify\n"
        }.joined()
        let original = Data(source.utf8)
        XCTAssertGreaterThan(original.count, 5 << 20)
        XCTAssertLessThan(original.count, 8 << 20)
        try original.write(to: path)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([folder])
        manager.openFile(path.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let host = NSHostingView(rootView: NativeSelectedFile(project: project))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        manager.attach(to: window)
        window.orderFront(nil)
        defer { window.close() }

        weak var retiredFile: FileTab?
        do {
            let pane = try XCTUnwrap(project.selectedTab)
            guard case .file(let file) = pane.content else {
                return XCTFail("Expected a real file tab in WorkspaceDockView")
            }
            retiredFile = file
            try await file.waitForText()
            try await settle {
                host.layoutSubtreeIfNeeded()
                return (file.editorView as? NSScrollView)?.documentView is FocusReportingTextView
            }
            let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
            let editor = try XCTUnwrap(scroll.documentView as? FocusReportingTextView)
            XCTAssertNotNil(editor.syntaxCoordinator)
            XCTAssertEqual(Data(editor.string.utf8), original)

            for position in [0, source.utf16.count / 2, source.utf16.count - 1, 0] {
                editor.scrollRangeToVisible(NSRange(location: position, length: 0))
                editor.layoutSubtreeIfNeeded()
                let viewport = try XCTUnwrap(editor.nativeLayoutManager.textViewportLayoutController.viewportRange)
                let visible = NSRange(viewport, in: editor.nativeContentManager)
                XCTAssertLessThanOrEqual(visible.location, position)
                XCTAssertGreaterThanOrEqual(NSMaxRange(visible), position)
            }

            let appended = "let appended = \"中文 👋\"\n"
            editor.insertText(appended,
                              replacementRange: NSRange(location: source.utf16.count, length: 0))
            editor.breakUndoCoalescing()
            try await settle { file.isDirty }
            XCTAssertEqual(Data(file.text.utf8), original + Data(appended.utf8))
            editor.undoManager?.undo()
            try await settle { !file.isDirty }
            XCTAssertEqual(Data(file.text.utf8), original)
            editor.undoManager?.redo()
            try await settle { file.isDirty }
            XCTAssertEqual(Data(file.text.utf8), original + Data(appended.utf8))

            await file.save()
            XCTAssertFalse(file.isDirty)
            XCTAssertEqual(try Data(contentsOf: path), original + Data(appended.utf8))
            project.closeFiles()
            XCTAssertTrue(project.tabs.isEmpty)
            XCTAssertNil(scroll.documentView, "Closing the file must detach its TextKit document")
            XCTAssertNil(editor.syntaxCoordinator, "Closing the file must retire its parser")
        }

        try await settle { retiredFile == nil }
        XCTAssertNil(retiredFile, "The live Dock must not retain a closed 100k FileTab")
    }

    func testFiveConcurrentNativeEditorsReleaseDocumentAndParsingTasks() async throws {
        final class WeakEditor {
            weak var editor: FocusReportingTextView?
            init(_ editor: FocusReportingTextView) { self.editor = editor }
        }
        final class WeakFile {
            weak var file: FileTab?
            init(_ file: FileTab) { self.file = file }
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-native-5tabs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let baseline = String(repeating: "let item = \"中文 👋\" // exact data\n", count: 10_000)
        for cycle in 0..<5 {
            var files: [FileTab] = []
            var windows: [NSWindow] = []
            var hosts: [NSHostingView<SourceTextEditor>] = []
            var weakEditors: [WeakEditor] = []
            var weakFiles: [WeakFile] = []
            for i in 0..<5 {
                let url = folder.appendingPathComponent("source\(cycle)-\(i).swift")
                try baseline.write(to: url, atomically: true, encoding: .utf8)
                let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared,
                                   workspaceIdentity: nil)
                try await file.waitForText()
                let host = NSHostingView(rootView: SourceTextEditor(
                    file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    palette: .theme(dark: (cycle + i).isMultiple(of: 2)),
                    wrapLines: !(cycle + i).isMultiple(of: 2), isFocused: false
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
                weakFiles.append(WeakFile(file))
            }
            print("T5_NATIVE_LIFETIME cycle=\(cycle) simultaneous=\(weakEditors.count) allRetained=\(weakEditors.allSatisfy { $0.editor != nil })")
            XCTAssertTrue(weakEditors.allSatisfy { $0.editor != nil })
            // A real tab/window close retires its TextKit document before
            // releasing the SwiftUI host (Project.close / terminateAll). This
            // test must exercise that ownership contract, not rely on AppKit
            // eventually discarding a cached NSHostingView by itself.
            for file in files { file.retireNativeEditor() }
            for i in (0..<windows.count).reversed() {
                hosts[i].removeFromSuperview()
                windows[i].contentView = nil
                windows[i].close()
            }
            hosts.removeAll()
            windows.removeAll()
            files.removeAll()
            try await settle {
                weakEditors.allSatisfy { $0.editor == nil }
                    && weakFiles.allSatisfy { $0.file == nil }
            }
            let releasedEditors = weakEditors.filter { $0.editor == nil }.count
            let releasedFiles = weakFiles.filter { $0.file == nil }.count
            XCTAssertEqual(releasedEditors, 5, "cycle \(cycle): TextKit views still held")
            XCTAssertEqual(releasedFiles, 5, "cycle \(cycle): FileTab owners still held")
            print("T5_NATIVE_LIFETIME cycle=\(cycle) simultaneous=5 released=\(releasedEditors) filesReleased=\(releasedFiles)")
        }
    }

    func testExternalReloadReleasesObsoleteDocumentEvenWhenOldScrollViewIsCached() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reload.swift")
        let oldText = String(repeating: "let stale = \"中文 😀\"\n", count: 400)
        let newText = "let current = \"updated 👋\"\n"
        try oldText.write(to: path, atomically: true, encoding: .utf8)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        let host = NSHostingView(rootView: SourceTextEditor(
            file: file, font: .monospacedSystemFont(ofSize: 14, weight: .regular),
            palette: .theme(dark: false), wrapLines: false, isFocused: false
        ))
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 700, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        try await settle { host.layoutSubtreeIfNeeded(); return file.editorView != nil }
        // The old SwiftUI host and scroll may be retained by a pending AppKit
        // layout even after its tab's document generation becomes obsolete.
        let cachedScroll = try XCTUnwrap(file.editorView as? NSScrollView)
        var editor: FocusReportingTextView? = try XCTUnwrap(
            cachedScroll.documentView as? FocusReportingTextView)
        weak var retiredEditor = editor
        XCTAssertEqual(editor?.text, oldText)
        let initialRevision = file.reloadRevision
        // A successful refresh of byte-identical content must not retire the
        // document, reset Undo or replace the tab's native view.
        file.reloadFromDiskIfClean()
        try await file.waitForText()
        XCTAssertEqual(file.reloadRevision, initialRevision)
        XCTAssertTrue(file.editorView === cachedScroll)
        XCTAssertTrue(cachedScroll.documentView === editor)
        XCTAssertTrue(window.makeFirstResponder(editor),
            "Retiring a clean editor must also handle a previously focused NSTextView")
        host.removeFromSuperview()
        try newText.write(to: path, atomically: true, encoding: .utf8)
        file.reloadFromDiskIfClean()
        try await settle { file.text == newText && file.reloadRevision > 0 }
        editor = nil
        XCTAssertNil(file.editorView, "The file must not expose a stale native editor after reload")
        XCTAssertNil(cachedScroll.documentView,
                     "A retired file generation must not keep its obsolete native text document")
        try await settle { retiredEditor == nil }

        let replacementHost = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = replacementHost
        try await settle {
            replacementHost.layoutSubtreeIfNeeded()
            return file.editorView !== cachedScroll && file.editorView != nil
        }
        let freshScroll = try XCTUnwrap(file.editorView as? NSScrollView)
        var freshEditor: FocusReportingTextView? = try XCTUnwrap(
            freshScroll.documentView as? FocusReportingTextView)
        weak var retiredReplacement = freshEditor
        XCTAssertEqual(freshEditor?.text, newText)
        XCTAssertFalse(freshEditor?.undoManager?.canUndo ?? true)
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), newText)

        // The same generation handoff also applies when valid text becomes
        // binary: the old document must leave memory while the real file tab
        // switches to its unsupported-content view.
        let binary = Data([0xFF, 0x00, 0xFE])
        try binary.write(to: path)
        file.reloadFromDiskIfClean()
        try await settle {
            replacementHost.layoutSubtreeIfNeeded()
            if case .unavailable = file.content { return true }
            return false
        }
        freshEditor = nil
        XCTAssertNil(freshScroll.documentView)
        try await settle { retiredReplacement == nil }
        XCTAssertTrue(file.text.isEmpty)
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: path), binary)
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

        // An old, now-clean document can still have redo transactions.
        // Replacing its bytes must retire that Undo history, not just its callbacks.
        retiredEditor?.insertText("temporary edit", replacementRange: NSRange(location: 0, length: 0))
        try await settle { file?.isDirty == true }
        retiredEditor?.undoManager?.undo()
        try await settle { file?.isDirty == false }
        XCTAssertTrue(retiredEditor?.undoManager?.canRedo == true)
        host?.removeFromSuperview()
        host = nil
        try "changed on disk\n".write(to: path, atomically: true, encoding: .utf8)
        file?.reloadFromDiskIfClean()
        try await settle { file?.text == "changed on disk\n" }
        XCTAssertFalse(retiredEditor?.isEditable ?? true,
                       "The retired NSTextView must not accept new edits or undo registrations")
        XCTAssertFalse(retiredEditor?.undoManager?.canUndo ?? true)
        XCTAssertFalse(retiredEditor?.undoManager?.canRedo ?? true,
                       "Retired document's UndoManager must not retain obsolete TextKit storage")
        retiredEditor?.insertText("stale editor", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(file?.text, "changed on disk\n")
        XCTAssertFalse(try XCTUnwrap(file).isDirty)
        host = mount(try XCTUnwrap(file))
        try await settle { file?.editorView != nil }
        weak var currentEditor = (file?.editorView as? NSScrollView)?.documentView
        XCTAssertFalse(currentEditor === retiredEditor)
        XCTAssertEqual((currentEditor as? FocusReportingTextView)?.text, "changed on disk\n")
        XCTAssertFalse((currentEditor as? FocusReportingTextView)?.undoManager?.canUndo ?? true)
        // A retired document must be unusable immediately (checked above),
        // but AppKit may keep its views alive until the window is torn down.
        host?.removeFromSuperview()
        host = nil
        file?.retireNativeEditor()
        window.contentView = nil
        window.close()
        retiredScroll = nil
        retiredEditor = nil
        file = nil
        try await settle {
            releasedEditor == nil && releasedFile == nil && currentEditor == nil
        }
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
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([directory])
        manager.openFile(path.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let pane = try XCTUnwrap(project.selectedTab)
        guard case .file(let file) = pane.content else { return XCTFail("Expected a file") }
        let host = NSHostingView(rootView: NativeSelectedFile(project: project))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        host.frame = root.bounds
        root.addSubview(host)
        let window = NSWindow(contentRect: root.bounds,
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        manager.attach(to: window)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        try await settle { file.editorView?.window === window }
        let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
        let editor = try XCTUnwrap(scroll.documentView as? FocusReportingTextView)
        NSApp.activate()
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
        XCTAssertNotEqual(offset, NSNotFound)
        editor.textSelection = NSRange(location: offset, length: 0)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        let scrollBefore = scroll.contentView.bounds.origin
        let heightBefore = scroll.bounds.height
        let target = try XCTUnwrap(project.dock.group(containing: .files))
        XCTAssertTrue(project.dock.move(.tab(pane.id), into: target.id, edge: .bottom))
        // The Dock model moves the same tab. Reparent only its native component
        // here; the real Dock drag, target group, and focus route are UI E2E.
        let destination = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 260))
        root.addSubview(destination)
        host.removeFromSuperview()
        host.frame = destination.bounds
        destination.addSubview(host)
        try await settle {
            host.layoutSubtreeIfNeeded()
            return file.editorView === scroll && scroll.window === window
                && scroll.bounds.height > 0 && scroll.bounds.height < heightBefore
        }
        XCTAssertEqual(project.dock.tabOrder, [pane.id])
        XCTAssertEqual(project.selectedTabID, pane.id)
        XCTAssertTrue(scroll.documentView === editor)
        // Native surface identity is proved here; real key-window transfer
        // is checked by the dedicated XCUIApplication Dock tests.
        if window.isKeyWindow && NSApp.isActive {
            try await settle { window.firstResponder === editor }
        } else {
            XCTAssertTrue(manager.ownsActiveResponder(editor))
            XCTAssertTrue(editor.window === window)
        }
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

    func testUnmanagedForegroundSSHRejectsLocalFinderPathsBeforeAnyRemoteHandoff() async throws {
        try await assertUnmanagedSSHRejectsLocalDrop(replacesRootShell: false)
    }

    func testUnmanagedExecSSHRejectsLocalFinderPathsEvenWhenForegroundPIDIsShellPID() async throws {
        try await assertUnmanagedSSHRejectsLocalDrop(replacesRootShell: true)
    }

    private func assertUnmanagedSSHRejectsLocalDrop(replacesRootShell: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let terminal = TerminalSession(initialDirectory: directory.path, launchCommand: "exec /bin/sh -i")
        defer { terminal.terminate() }
        let tab = PaneTab(content: .session(terminal))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: PanelContentView(
            tab: tab, isFocused: false,
            onFocused: {}, onNewBrowserTab: { _ in }, onNewFileTab: { _ in }
        ))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await settle { terminal.shellPid != nil }
        XCTAssertTrue(terminal.acceptsLocalFileDrop)

        // An SSH client that bypasses Bailey's helper keeps location == .local.
        // ProxyCommand sleeps over local pipes only: no network, credentials,
        // user SSH config, authorized hosts, or shared ControlMaster is touched.
        terminal.sendCommand(
            (replacesRootShell ? "exec " : "")
                + "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=20 "
                + "-o 'ProxyCommand=/bin/sleep 30' fixture.invalid\r"
        )
        if replacesRootShell {
            try await settle {
                guard let root = terminal.shellPid,
                      let executable = processExecutablePath(pid: root)
                else { return false }
                return (executable as NSString).lastPathComponent == "ssh"
            }
        } else {
            try await settle {
                guard let foreground = terminal.surface.foregroundPid,
                      let executable = processExecutablePath(pid: foreground)
                else { return false }
                return (executable as NSString).lastPathComponent == "ssh"
            }
            XCTAssertNotEqual(terminal.surface.foregroundPid, terminal.shellPid)
        }
        XCTAssertNil(terminal.location.remoteConnection)
        XCTAssertFalse(terminal.acceptsLocalFileDrop,
                       "A foreground ssh is remote input regardless of whether it replaced the root shell")
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
                tab: tab, isFocused: false,
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
