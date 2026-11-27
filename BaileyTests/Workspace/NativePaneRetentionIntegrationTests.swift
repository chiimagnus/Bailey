import AppKit
import ApplicationServices
import AVFoundation
import AVKit
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
        XCTAssertNotNil(terminal.surface.onNewBrowserTab)
        let parking = TerminalParkingContainerView(frame: .zero)
        container.addSubview(parking)
        parking.mount([terminal])
        XCTAssertTrue(terminal.surface.superview === parking)
        XCTAssertTrue(terminal.surface.window === window)
        XCTAssertNil(terminal.surface.onBecomeFirstResponder)
        XCTAssertNil(terminal.surface.onNewBrowserTab)
        XCTAssertNil(terminal.surface.onNewFileTab)
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
        let project = Project(customDirectory: "/fixture/observation", layout: .init())
        let tab = PaneTab(content: .browser(BrowserTab(initialFocus: .none)))
        project.append(tab)
        XCTAssertEqual(project.tabs.first?.displayTitle, tab.content.title)
        var snapshots = 0
        project.onSnapshotChange = { snapshots += 1 }

        let other = PaneTab(content: .browser(BrowserTab(initialFocus: .none)))
        project.append(other)
        XCTAssertGreaterThan(snapshots, 0)
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

    func testSSHFolderPickerStartsAtWindowsDrivesWithoutChangingUnixHome() {
        let windows = SSHFolderPickerModel.startupLocation(Data(
            "/c/Users/Administrator\nDRIVE:d\nDRIVE:c\nDRIVE:d\n".utf8
        ))
        XCTAssertEqual(windows?.home, "/c/Users/Administrator")
        XCTAssertEqual(windows?.drives, ["c", "d"])

        let unix = SSHFolderPickerModel.startupLocation(Data("/home/username\n".utf8))
        XCTAssertEqual(unix?.home, "/home/username")
        XCTAssertEqual(unix?.drives, [])
        XCTAssertNil(SSHFolderPickerModel.startupLocation(Data("invalid\nDRIVE:c\n".utf8)))
        XCTAssertEqual(
            SSHFolderPickerModel.startupLocation(Data("/home/user\nDRIVE:../\n".utf8))?.drives,
            []
        )
    }

    func testNativeFileAndSSHChoosersStayOnOwningWindow() async throws {
        let local = WorkspaceNativeDialogs.folderPanel()
        XCTAssertFalse(local.canChooseFiles, "Add Projects must select directories only")
        XCTAssertTrue(local.canChooseDirectories)
        XCTAssertTrue(local.allowsMultipleSelection)
        XCTAssertEqual(local.prompt, String(localized: "Add", table: "Terminal"))
        XCTAssertEqual(local.message, String(localized: "Add projects to Bailey", table: "Terminal"))
        let files = WorkspaceNativeDialogs.filePanel()
        XCTAssertTrue(files.canChooseFiles)
        XCTAssertFalse(files.canChooseDirectories)
        XCTAssertTrue(files.allowsMultipleSelection)
        XCTAssertEqual(files.prompt, String(localized: "Open", table: "Sidebar"))
        XCTAssertEqual(files.message, String(localized: "Open files in Bailey", table: "Terminal"))
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
        XCTAssertTrue(firstManager.isSSHFolderPickerVisible)
        XCTAssertFalse(secondManager.isSSHFolderPickerVisible,
                       "SSH picker must stay on the requesting manager")
        XCTAssertNil(first.attachedSheet, "SSH picker is a window-owned overlay, not a native sheet")
        XCTAssertNil(second.attachedSheet)
        let keyBeforeDismissal = NSApp.keyWindow
        let firstResponderBefore = first.firstResponder
        let secondResponderBefore = second.firstResponder
        firstManager.dismissSSHFolderPicker()
        XCTAssertFalse(firstManager.isSSHFolderPickerVisible)
        firstManager.restoreFocusAfterSSHFolderPicker()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(NSApp.keyWindow === keyBeforeDismissal)
        XCTAssertTrue(first.firstResponder === firstResponderBefore)
        XCTAssertTrue(second.firstResponder === secondResponderBefore,
                      "Dismissing one window's picker must not steal another window's responder")
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
        let switcher = manager.tabSwitcher

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
        XCTAssertNotNil(switcher.handle(controlTab), "The Panel menu owns the Control-Tab binding")
        XCTAssertTrue(switcher.cycle(in: manager, reverse: false))
        await fulfillment(of: [previewStarted], timeout: 1)
        XCTAssertTrue(switcher.isPresented)
        XCTAssertEqual(switcher.orderedTabIDs, [tabs[2].id, tabs[1].id, tabs[0].id])
        XCTAssertEqual(switcher.highlightedTabID, tabs[1].id)
        XCTAssertEqual(project.selectedTabID, tabs[2].id)

        // A stationary pointer must not replace the keyboard highlight.
        switcher.highlight(tabs[0].id, in: project)
        XCTAssertEqual(switcher.highlightedTabID, tabs[1].id)
        XCTAssertTrue(switcher.cycle(in: manager, reverse: false))
        XCTAssertEqual(switcher.highlightedTabID, tabs[0].id)
        XCTAssertEqual(project.selectedTabID, tabs[2].id)

        let release = try key(.flagsChanged, 59, [])
        XCTAssertNil(switcher.handle(release))
        XCTAssertFalse(switcher.isPresented)
        XCTAssertEqual(project.selectedTabID, tabs[0].id)
        XCTAssertEqual(switcher.highlightedTabID, nil)

        // A reverse cycle can be canceled by Escape without committing.
        let original = project.selectedTabID
        XCTAssertTrue(switcher.cycle(in: manager, reverse: true))
        XCTAssertTrue(switcher.isPresented)
        XCTAssertEqual(project.selectedTabID, original)
        XCTAssertNil(switcher.handle(try key(.keyDown, 53, [.control])))
        XCTAssertFalse(switcher.isPresented)
        XCTAssertEqual(project.selectedTabID, original)
        XCTAssertNotNil(switcher.handle(release))

        // Closing a candidate during preview cannot select a removed tab.
        XCTAssertTrue(switcher.cycle(in: manager, reverse: false))
        let candidate = try XCTUnwrap(switcher.highlightedTabID)
        let closing = try XCTUnwrap(project.tabs.first { $0.id == candidate })
        project.close(closing)
        XCTAssertNil(switcher.handle(release))
        XCTAssertNotEqual(project.selectedTabID, candidate)
        XCTAssertTrue(project.tabs.contains { $0.id == project.selectedTabID })
    }

    func testTabSwitcherCannotCommitOrSelectAfterChangingProjects() throws {
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let first = Project(customDirectory: "/fixture/A", layout: manager.dockLayout)
        let second = Project(customDirectory: "/fixture/B", layout: manager.dockLayout)
        manager.projects = [first, second]
        let firstTabs = (0..<3).map { _ in
            PaneTab(content: .browser(BrowserTab(initialFocus: .none)))
        }
        firstTabs.forEach(first.append)
        let secondTab = PaneTab(content: .browser(BrowserTab(initialFocus: .none)))
        second.append(secondTab)
        manager.selectedProjectID = first.id
        let original = first.selectedTabID

        let switcher = manager.tabSwitcher
        XCTAssertTrue(switcher.cycle(in: manager, reverse: false))
        let staleCandidate = try XCTUnwrap(switcher.highlightedTabID)
        XCTAssertTrue(switcher.isPresented)
        manager.selectedProjectID = second.id
        XCTAssertFalse(switcher.isPresented,
                       "A project change must synchronously cancel old Control-Tab previews")
        switcher.finish()
        XCTAssertEqual(first.selectedTabID, original,
                       "A stale Control release cannot write the old project's MRU")
        XCTAssertEqual(second.selectedTabID, secondTab.id)

        XCTAssertTrue(switcher.cycle(in: manager, reverse: false) == false,
                      "One-tab projects cannot open a Control-Tab overlay")
        switcher.select(staleCandidate, in: first)
        XCTAssertEqual(first.selectedTabID, original,
                       "A stale overlay card cannot select another project's tab")
        XCTAssertEqual(manager.selectedProjectID, second.id)
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
        let project = Project(customDirectory: directory.path, layout: .init())
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

    func testClosedBrowserRetiresNativePageBeforeHostDismantles() async throws {
        let project = Project(customDirectory: "/fixture/browser", layout: .init())
        let browser = project.newBrowserTab(initialFocus: .none)
        let native = browser.webView
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); project.terminateAll() }
        var newTabs = 0
        let host = NSHostingView(rootView: BrowserView(
            browser: browser, isFocused: false, onFocused: {},
            onNewBrowserTab: { _ in newTabs += 1 }
        ))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        native.loadHTMLString("<title>Retirement fixture</title><input id='draft' value='retired document'>",
                              baseURL: nil)
        try await settle { native.window === window && browser.title == "Retirement fixture"
            && !browser.isLoading && native.onNewBrowserTab != nil }
        XCTAssertNotNil(native.navigationDelegate)
        XCTAssertNotNil(native.uiDelegate)

        // Retain the old SwiftUI host and WKWebView just as AppKit may do
        // until the next view update.
        project.closeContent(.browser(browser))
        XCTAssertTrue(project.tabs.isEmpty)
        XCTAssertNil(native.navigationDelegate)
        XCTAssertNil(native.uiDelegate)
        XCTAssertNil(native.focusOwner)
        XCTAssertNil(native.onFocused)
        XCTAssertNil(native.onFocusReady)
        XCTAssertNil(native.onNewBrowserTab)
        native.onNewBrowserTab?("about:blank")
        XCTAssertEqual(newTabs, 0)

        try await settle { native.title != "Retirement fixture" && !native.isLoading }
        let retainedDraft = try await native.evaluateJavaScript(
            "document.getElementById('draft') !== null"
        ) as? Bool
        XCTAssertEqual(retainedDraft, false, "Closing a tab must unload its old page")
        XCTAssertEqual(browser.title, "Retirement fixture", "Retirement must stop obsolete KVO updates")
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(native.onNewBrowserTab)
    }

    func testDetachedBrowserRejectsJavaScriptDialogInsteadOfBlockingTheApp() async throws {
        let browser = BrowserTab(initialFocus: .none)
        defer { browser.retireContent() }
        browser.webView.loadHTMLString("<title>Detached dialog</title>", baseURL: nil)
        try await settle { browser.title == "Detached dialog" && !browser.isLoading }
        XCTAssertNil(browser.webView.window)
        let confirmed = try await browser.webView.evaluateJavaScript(
            "confirm('Detached browser must not open a modal window')"
        ) as? Bool
        XCTAssertEqual(confirmed, false)
        XCTAssertNil(NSApp.modalWindow)
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
        let project = Project(customDirectory: directory.path, layout: .init())
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
                DockSavedGroup(id: UUID(), items: [.tab(index)], selected: .tab(index))
            }
            let panes = groups.map { DockNode.group(DockGroup(id: $0.id, items: [])) }
            manager.dockLayout.root = panes.dropFirst().reduce(panes[0]) { partial, pane in
                .split(DockSplit(axis: .horizontal, fraction: 0.5, first: partial, second: pane))
            }
            project.dock.restore(groups, tabIDs: tabs)
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
            project.closeAll()
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
            project.dock.restore(groups, tabIDs: project.tabs.map(\.id))
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
            project.closeAll()
            XCTAssertTrue(project.tabs.isEmpty)
            XCTAssertNil(scroll.documentView, "Closing the file must detach its TextKit document")
            XCTAssertNil(editor.syntaxCoordinator, "Closing the file must retire its parser")
        }

        try await settle { retiredFile == nil }
        XCTAssertNil(retiredFile, "The live Dock must not retain a closed 100k FileTab")
    }

    func testEmbeddedAndFileMediaOwnIndependentPlayersAndStagingLifetimes() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-shared-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/features")

        func nativePlayers(in view: NSView) -> [AVPlayerView] {
            if let playerView = view as? AVPlayerView { return [playerView] }
            return view.subviews.flatMap { nativePlayers(in: $0) }
        }
        let project = Project(customDirectory: "/fixture/Shared media", layout: .init())
        defer { project.closeAll() }
        let host = NSHostingView(rootView: NativeRetainedFiles(project: project))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1080, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 560))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        window.setContentSize(container.bounds.size)
        window.orderFront(nil)
        let pid = ProcessInfo.processInfo.processIdentifier
        // Activate the host's native accessibility tree without requiring this
        // offscreen window to appear in the system-wide window list.
        let ax = await Task.detached {
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                kAXWindowsAttribute as CFString, &windows).rawValue
        }.value
        XCTAssertEqual(ax, AXError.success.rawValue)

        func attribute(_ element: NSObject, _ name: String) -> Any? {
            guard element.responds(to: NSSelectorFromString(name)) else { return nil }
            return element.value(forKey: name)
        }
        func loadButton(in element: NSObject) -> NSObject? {
            if attribute(element, "accessibilityIdentifier") as? String == "bailey.markdown.media.load" {
                return element
            }
            let children = attribute(element, "accessibilityChildrenInNavigationOrder") as? [NSObject]
                ?? attribute(element, "accessibilityChildren") as? [NSObject] ?? []
            for child in children {
                if let found = loadButton(in: child) { return found }
            }
            return nil
        }

        var sources = [
            ("audio", fixtures.appendingPathComponent("audio-file-playback/demo-audio.m4a")),
            ("video", fixtures.appendingPathComponent("video-file-playback/demo-video.mp4")),
        ]
        if let root = ProcessInfo.processInfo.environment["BAILEY_MEDIA_ACCEPTANCE_ROOT"] {
            let samples = URL(fileURLWithPath: root).appendingPathComponent("media")
            sources.append(("audio", samples.appendingPathComponent("音频-定位.wav")))
            sources.append(("video", samples.appendingPathComponent("视频-内置字幕.mp4")))
        }
        for (tag, fixture) in sources {
            let source = folder.appendingPathComponent("shared." + fixture.pathExtension)
            let bytes = try Data(contentsOf: fixture)
            try bytes.write(to: source)
            let document = folder.appendingPathComponent("Media.md")
            let markdown = Data("# Media\n\n<\(tag) controls src=\"\(source.lastPathComponent)\"></\(tag)>\n".utf8)
            try markdown.write(to: document)
            project.openLocalFile(source.path)
            let mediaTab = try XCTUnwrap(project.selectedTab)
            guard case .file(let media) = mediaTab.content else { return XCTFail("Expected media file tab") }
            project.openLocalFile(document.path)
            let markdownTab = try XCTUnwrap(project.selectedTab)
            guard case .file(let file) = markdownTab.content else { return XCTFail("Expected Markdown file tab") }
            file.setFilePreview(true)
            try await file.waitForText()
            try await settle {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return media.mediaPlayer?.currentItem?.status == .readyToPlay
                    && file.markdownSourceIndex?.request == file.textPreviewRequestID
            }
            let independent = try XCTUnwrap(media.mediaPlayer)
            let mountedPlayers = nativePlayers(in: host).compactMap(\.player)
            XCTAssertEqual(mountedPlayers.count, 1)
            XCTAssertTrue(mountedPlayers.first === independent,
                          "Only the standalone system player may exist before requesting Markdown media")
            // Exercise the real accessible control from this mounted host,
            // as the other native component tests do. Window-server enumeration
            // can omit an offscreen window during a complete host test run.
            XCTAssertTrue(host.window === window)
            try await settle {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return loadButton(in: host) != nil
            }
            XCTAssertEqual(host.bounds.width, 1080, accuracy: 1,
                           "The window must retain its allocated viewport, not shrink to SwiftUI's ideal size")
            XCTAssertEqual(host.bounds.height, 560, accuracy: 1)
            let load = try XCTUnwrap(loadButton(in: host), "Markdown media button in its owning host")
            XCTAssertEqual(attribute(load, "accessibilityRole") as? String, kAXButtonRole)
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard load.responds(to: selector) else {
                return XCTFail("The real Markdown media button must expose a press action")
            }
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            let press = unsafeBitCast(load.method(for: selector), to: Action.self)
            guard press(load, selector) else {
                return XCTFail("The real Markdown media button must perform its press action")
            }
            try await settle {
                host.layoutSubtreeIfNeeded()
                return nativePlayers(in: host).compactMap(\.player).contains {
                    $0 !== independent && $0.currentItem?.status == .readyToPlay
                }
            }
            let embedded = try XCTUnwrap(nativePlayers(in: host).compactMap(\.player).first { $0 !== independent })
            let independentItem = try XCTUnwrap(independent.currentItem)
            let embeddedItem = try XCTUnwrap(embedded.currentItem)
            XCTAssertEqual(independentItem.allowedAudioSpatializationFormats, .monoStereoAndMultichannel)
            XCTAssertEqual(embeddedItem.allowedAudioSpatializationFormats, .monoStereoAndMultichannel)
            let independentAsset = try XCTUnwrap(independentItem.asset as? AVURLAsset)
            let embeddedAsset = try XCTUnwrap(embeddedItem.asset as? AVURLAsset)
            XCTAssertEqual(try Data(contentsOf: independentAsset.url), bytes)
            XCTAssertEqual(try Data(contentsOf: embeddedAsset.url), bytes)
            XCTAssertNotEqual(independentAsset.url, embeddedAsset.url)
            XCTAssertEqual(independentAsset.url.resolvingSymlinksInPath(), source.resolvingSymlinksInPath())
            let stagedFolder = embeddedAsset.url.deletingLastPathComponent()
            XCTAssertTrue(stagedFolder.lastPathComponent.hasPrefix("Bailey-Markdown-"))
            let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(
                atPath: stagedFolder.path
            )[.posixPermissions] as? Int)
            XCTAssertEqual(permissions & 0o077, 0)
            independent.isMuted = true
            embedded.isMuted = true
            let firstPosition = await independent.seek(to: CMTime(seconds: 1, preferredTimescale: 600),
                                                       toleranceBefore: .zero, toleranceAfter: .zero)
            let secondPosition = await embedded.seek(to: CMTime(seconds: 2, preferredTimescale: 600),
                                                   toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(firstPosition)
            XCTAssertTrue(secondPosition)
            embedded.playImmediately(atRate: 1)
            independent.playImmediately(atRate: 1)
            try await settle { independent.rate != 0 && embedded.rate != 0 }
            embedded.pause()
            XCTAssertEqual(embedded.rate, 0)
            XCTAssertNotEqual(independent.rate, 0, "Pausing Markdown must not pause the independent media tab")
            project.closeContent(.file(file))
            try await settle {
                embedded.currentItem == nil && !FileManager.default.fileExists(atPath: stagedFolder.path)
            }
            XCTAssertEqual(embedded.rate, 0)
            XCTAssertTrue(independent.currentItem === independentItem)
            XCTAssertTrue(media.mediaPlayer === independent)
            XCTAssertNotEqual(independent.rate, 0, "Closing Markdown must leave the other player's playback untouched")
            independent.pause()
            project.closeContent(.file(media))
            try await settle { independent.currentItem == nil }
            XCTAssertNil(media.mediaPlayer)
            XCTAssertTrue(project.tabs.isEmpty)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try Data(contentsOf: document), markdown)
        }
    }

    func testSevenRealFormatsSurviveOneHundredNativeViewerSwitchesAndClose() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["BAILEY_PREVIEW_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_PREVIEW_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-mixed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let primary = folder.appending(path: "primary")
        let secondary = folder.appending(path: "secondary")
        for root in [primary, secondary] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            for name in ["Markdown 综合验收.md", "HTML 综合验收.html", "graphics", "images", "media", "styles", "tables"] {
                try FileManager.default.copyItem(at: fixture.appending(path: name), to: root.appending(path: name))
            }
        }
        let names = ["Markdown 综合验收.md", "tables/复杂字段.csv", "graphics/复杂科研图.svg",
                     "HTML 综合验收.html", "images/动画-34帧.gif", "media/音频-定位.m4a",
                     "media/视频-内置字幕.mp4"]
        let paths = names.map { primary.appending(path: $0) }
        let otherPaths = names.map { secondary.appending(path: $0) }
        // Same filenames but different actual data in the second project.
        let otherHTML = try String(contentsOf: otherPaths[3], encoding: .utf8)
            .replacingOccurrences(of: "Bailey / HTML 综合验收", with: "Second window HTML")
        try Data(otherHTML.utf8).write(to: otherPaths[3])
        let otherCSV = try String(contentsOf: otherPaths[1], encoding: .utf8)
            .replacingOccurrences(of: "试样 A", with: "Second window CSV")
        try Data(otherCSV.utf8).write(to: otherPaths[1])
        let baseline = try (paths + otherPaths).map { try Data(contentsOf: $0) }
        let previousWindows = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previousWindows)
            TerminalHistoryStore.save(previousHistories)
        }

        final class WeakOwner {
            let label: String
            weak var value: AnyObject?
            init(_ label: String, _ value: AnyObject) { self.label = label; self.value = value }
        }
        func mounted<T: NSView>(_ type: T.Type, in root: NSView, matching: (T) -> Bool = { _ in true }) -> T? {
            if let view = root as? T, view.window != nil, !view.isHiddenOrHasHiddenAncestor, matching(view) {
                return view
            }
            for child in root.subviews {
                if let view = mounted(type, in: child, matching: matching) { return view }
            }
            return nil
        }
        func memoryMiB() -> (resident: Double, peak: Double, footprint: Double) {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            XCTAssertEqual(result, KERN_SUCCESS)
            return (Double(info.resident_size) / 1_048_576, Double(info.resident_size_peak) / 1_048_576,
                    Double(info.phys_footprint) / 1_048_576)
        }

        let before = memoryMiB()
        let started = ProcessInfo.processInfo.systemUptime
        var weakOwners: [WeakOwner] = []
        var weakPlayers: [WeakOwner] = []
        var closedTabIDs = Set<UUID>()
        do {
            let manager = workspaceApplication.makeWindow()
            defer { manager.windowClosed() }
            manager.addLocalFolders([primary])
            let project = try XCTUnwrap(manager.selectedProject)
            var tabs: [PaneTab] = []
            var files: [FileTab] = []
            for path in paths {
                project.openFile(path.path)
                let tab = try XCTUnwrap(project.selectedTab)
                guard case .file(let file) = tab.content else { return XCTFail("Expected a real file tab") }
                tabs.append(tab)
                files.append(file)
                weakOwners.append(WeakOwner("file " + path.lastPathComponent, file))
            }
            XCTAssertEqual(Set(tabs.map(\.id)).count, 7)
            let host = NSHostingView(rootView: NativeSelectedFile(project: project))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            manager.attach(to: window)
            window.orderFront(nil)

            let otherManager = workspaceApplication.makeWindow()
            defer { otherManager.windowClosed() }
            otherManager.addLocalFolders([secondary])
            let otherProject = try XCTUnwrap(otherManager.selectedProject)
            let otherHost = NSHostingView(rootView: NativeSelectedFile(project: otherProject))
            let otherWindow = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 820, height: 560),
                                       styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            otherWindow.isReleasedWhenClosed = false
            defer { otherWindow.close() }
            otherWindow.contentView = otherHost
            otherManager.attach(to: otherWindow)
            otherWindow.orderBack(nil)

            // Each iteration must reach a mounted native surface, not just a new selected ID.
            func ready(_ index: Int, file: FileTab, tab: PaneTab, project: Project,
                       host: NSView, window: NSWindow) -> Bool {
                host.layoutSubtreeIfNeeded()
                guard project.selectedTabID == tab.id else { return false }
                switch index {
                case 0:
                    return file.markdownSourceIndex?.request == file.textPreviewRequestID
                        && mounted(NSScrollView.self, in: host) != nil
                case 1:
                    return mounted(DelimitedGrid.self, in: host)?.table.numberOfRows == 5
                case 2:
                    return mounted(SVGPreviewScrollView.self, in: host)?.documentView?.subviews.isEmpty == false
                case 3:
                    guard let preview = file.htmlPreview else { return false }
                    return preview.webView.window === window && !preview.webView.isLoading && preview.webView.url != nil
                        && !preview.failed
                case 4:
                    return mounted(PreviewScrollView.self, in: host) { $0.accessibilityIdentifier() == "bailey.image.inspector" } != nil
                        && file.gifPlayback != nil
                default:
                    guard let player = file.mediaPlayer else { return false }
                    return mounted(AVPlayerView.self, in: host) { $0.player === player } != nil
                        && player.currentItem?.status == .readyToPlay
                }
            }
            var identities: [Int: ObjectIdentifier] = [:]
            var cachedPlayerViews: [Int: AVPlayerView] = [:]
            var memorySamples: [(resident: Double, peak: Double, footprint: Double)] = []
            for step in 0..<100 {
                let index = step % files.count
                let file = files[index]
                project.selectTab(tabs[index].id)
                if step < 4 {
                    try await file.waitForText()
                    project.setFilePreviewMode(.preview, for: tabs[index])
                }
                try await settle {
                    ready(index, file: file, tab: tabs[index], project: project, host: host, window: window)
                }
                guard ready(index, file: file, tab: tabs[index], project: project, host: host, window: window) else {
                    return XCTFail("Unready native viewer at step \(step), \(paths[index].lastPathComponent)")
                }
                XCTAssertFalse(file.isDirty)
                XCTAssertNil(file.reloadError)
                let retained: AnyObject
                switch index {
                case 0, 1, 2: retained = file.nativeTextStorage
                case 3: retained = try XCTUnwrap(file.htmlPreview)
                case 4: retained = try XCTUnwrap(file.gifPlayback)
                default: retained = try XCTUnwrap(file.mediaPlayer)
                }
                if let first = identities[index] {
                    XCTAssertEqual(ObjectIdentifier(retained), first, "Reload/remount must not replace the tab-owned state")
                } else {
                    identities[index] = ObjectIdentifier(retained)
                    // AppKit may cache an empty retired NSTextStorage. The FileTab
                    // must release, and its document must be cleared on true close.
                    if index >= 5, let player = retained as? AVPlayer {
                        let item = try XCTUnwrap(player.currentItem)
                        weakPlayers.append(WeakOwner(paths[index].lastPathComponent, player))
                        weakOwners.append(WeakOwner("item " + paths[index].lastPathComponent, item))
                        weakOwners.append(WeakOwner("asset " + paths[index].lastPathComponent, item.asset))
                    } else if index >= 3 {
                        weakOwners.append(WeakOwner("resource " + paths[index].lastPathComponent, retained))
                    }
                }
                if index == 3 {
                    let webView = try XCTUnwrap(file.htmlPreview?.webView)
                    let title = try await webView.evaluateJavaScript("document.querySelector('h1').textContent", contentWorld: .defaultClient) as? String
                    XCTAssertEqual(title, "Bailey / HTML 综合验收")
                }
                if index == 4, step == 4 {
                    let playback = try XCTUnwrap(file.gifPlayback)
                    playback.togglePause(automaticallyPlays: true)
                    XCTAssertTrue(playback.isPaused(automaticallyPlays: true))
                } else if index == 4 {
                    XCTAssertEqual(file.gifPlayback?.isPaused(automaticallyPlays: true), true)
                }
                // Keep all seven first-window owners alive while actually opening
                // and closing a same-named file in the other native window.
                otherProject.openFile(otherPaths[index].path)
                let otherTab = try XCTUnwrap(otherProject.selectedTab)
                guard case .file(let otherFile) = otherTab.content else {
                    return XCTFail("Expected an independently owned file in the second window")
                }
                XCTAssertTrue(closedTabIDs.insert(otherTab.id).inserted)
                XCTAssertFalse(otherFile === file)
                XCTAssertEqual(otherFile.path, otherPaths[index].path)
                XCTAssertEqual(otherProject.tabs.count, 1)
                weakOwners.append(WeakOwner("second window tab \(step)", otherFile))
                if index < 4 {
                    try await otherFile.waitForText()
                    otherProject.setFilePreviewMode(.preview, for: otherTab)
                }
                try await settle {
                    ready(index, file: otherFile, tab: otherTab, project: otherProject,
                          host: otherHost, window: otherWindow)
                }
                guard ready(index, file: otherFile, tab: otherTab, project: otherProject,
                            host: otherHost, window: otherWindow) else {
                    return XCTFail("Unready second-window viewer at step \(step)")
                }
                XCTAssertFalse(otherFile.isDirty)
                XCTAssertNil(otherFile.reloadError)
                if index < 4 {
                    XCTAssertFalse(otherFile.nativeTextStorage === file.nativeTextStorage)
                }
                if index == 1 {
                    XCTAssertTrue(otherFile.text.contains("Second window CSV"))
                    XCTAssertFalse(file.text.contains("Second window CSV"))
                } else if index == 3 {
                    let preview = try XCTUnwrap(otherFile.htmlPreview)
                    XCTAssertFalse(preview === file.htmlPreview)
                    let title = try await preview.webView.evaluateJavaScript(
                        "document.querySelector('h1').textContent", contentWorld: .defaultClient
                    ) as? String
                    XCTAssertEqual(title, "Second window HTML")
                    weakOwners.append(WeakOwner("second window HTML \(step)", preview))
                } else if index == 4 {
                    let playback = try XCTUnwrap(otherFile.gifPlayback)
                    XCTAssertFalse(playback === file.gifPlayback)
                    weakOwners.append(WeakOwner("second window GIF \(step)", playback))
                } else if index >= 5 {
                    let player = try XCTUnwrap(otherFile.mediaPlayer)
                    XCTAssertFalse(player === file.mediaPlayer)
                    let item = try XCTUnwrap(player.currentItem)
                    weakPlayers.append(WeakOwner("second window player \(step)", player))
                    weakOwners.append(WeakOwner("second window item \(step)", item))
                    weakOwners.append(WeakOwner("second window asset \(step)", item.asset))
                    let asset = try XCTUnwrap(item.asset as? AVURLAsset)
                    XCTAssertEqual(asset.url.resolvingSymlinksInPath().path,
                                   otherPaths[index].resolvingSymlinksInPath().path)
                    player.isMuted = true
                    let moved = await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600),
                                                  toleranceBefore: .zero, toleranceAfter: .zero)
                    XCTAssertTrue(moved)
                    XCTAssertEqual(player.currentTime().seconds, 1, accuracy: 0.1)
                }
                if step == 99 {
                    otherWindow.close()
                    XCTAssertNil(otherManager.attachedWindow)
                    XCTAssertFalse(workspaceApplication.containsWindow(otherManager))
                    XCTAssertTrue(otherManager.projects.isEmpty)
                    otherWindow.contentView = nil
                } else {
                    otherProject.close(otherTab)
                    XCTAssertTrue(otherProject.tabs.isEmpty)
                }
                XCTAssertNil(otherFile.htmlPreview)
                XCTAssertNil(otherFile.gifPlayback)
                XCTAssertNil(otherFile.mediaPlayer)
                XCTAssertTrue(otherFile.text.isEmpty)
                XCTAssertEqual(project.tabs.count, 7)
                XCTAssertTrue(manager.attachedWindow === window)
                XCTAssertTrue(ready(index, file: file, tab: tabs[index], project: project, host: host, window: window),
                              "Closing the other owner must not invalidate the active viewer")

                if index >= 5 {
                    let player = try XCTUnwrap(file.mediaPlayer)
                    player.isMuted = true
                    if step < 7 {
                        let moved = await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600),
                                                      toleranceBefore: .zero, toleranceAfter: .zero)
                        XCTAssertTrue(moved)
                        cachedPlayerViews[index] = try XCTUnwrap(mounted(AVPlayerView.self, in: host) { $0.player === player })
                        player.playImmediately(atRate: 1)
                    } else {
                        XCTAssertEqual(player.rate, 0)
                        XCTAssertEqual(player.currentTime().seconds, 2, accuracy: 0.5)
                    }
                }
                if step > 0 {
                    let last = (step - 1) % files.count
                    if last >= 5 {
                        let player = try XCTUnwrap(files[last].mediaPlayer)
                        try await settle { player.rate == 0 }
                        XCTAssertEqual(player.rate, 0)
                        if let cached = cachedPlayerViews.removeValue(forKey: last) {
                            try await settle { cached.player == nil }
                            guard cached.player == nil else {
                                return XCTFail("A dismantled native view must not own its former player")
                            }
                            XCTAssertFalse(cached.updatesNowPlayingInfoCenter)
                        }
                    }
                }
                if step.isMultiple(of: 10) { memorySamples.append(memoryMiB()) }
            }
            XCTAssertEqual(closedTabIDs.count, 100)
            XCTAssertEqual(project.tabs.count, 7)
            XCTAssertEqual(identities.count, 7)
            project.selectTab(tabs[0].id)
            project.setFilePreviewMode(.source, for: tabs[0])
            let markdown = files[0]
            try await settle { markdown.editorView?.window === window }
            let editor = try XCTUnwrap((markdown.editorView as? NSScrollView)?.documentView as? FocusReportingTextView)
            let original = markdown.text
            editor.insertText("X", replacementRange: NSRange(location: 0, length: 0))
            try await settle { markdown.isDirty }
            XCTAssertTrue(markdown.isDirty)
            try XCTUnwrap(editor.undoManager).undo()
            try await settle { !markdown.isDirty }
            XCTAssertEqual(markdown.text, original)
            XCTAssertFalse(markdown.isDirty)
            XCTAssertEqual(ObjectIdentifier(markdown.nativeTextStorage), identities[0])

            project.closeAll()
            XCTAssertTrue(project.tabs.isEmpty)
            for file in files {
                XCTAssertNil(file.mediaPlayer)
                XCTAssertNil(file.htmlPreview)
                XCTAssertNil(file.gifPlayback)
                XCTAssertTrue(file.text.isEmpty)
            }
            manager.close(project)
            XCTAssertFalse(manager.projects.contains { $0 === project })
            window.contentView = nil
            print("PREVIEW_MIXED primary_switches=100 secondary_opens_and_closes=100 elapsed_s=\(ProcessInfo.processInfo.systemUptime - started) initial_mib=\(before) samples_mib=\(memorySamples)")
        }
        try await settle { weakOwners.allSatisfy { $0.value == nil } }
        XCTAssertTrue(weakOwners.allSatisfy { $0.value == nil }, "Closed owners: \(weakOwners.filter { $0.value != nil }.map(\.label))")
        // AVKit can retain an empty AVPlayer via its private controller after
        // the view is dismantled. Test the real media lifetime, and surface
        // any retained shells instead of calling them fully deallocated.
        for owner in weakPlayers {
            if let player = owner.value as? AVPlayer {
                XCTAssertEqual(player.rate, 0)
                XCTAssertNil(player.currentItem)
            }
        }
        for (path, original) in zip(paths + otherPaths, baseline) {
            XCTAssertEqual(try Data(contentsOf: path), original, "Source bytes changed: \(path.path)")
        }
        print("PREVIEW_MIXED after_release_mib=\(memoryMiB()) live_owners=\(weakOwners.filter { $0.value != nil }.count) retained_empty_players=\(weakPlayers.filter { $0.value != nil }.map(\.label))")
    }

    func testFiveLargeFileTabsReleaseNativeDocumentsAfterRealProjectClose() async throws {
        final class WeakFileOwner {
            weak var file: FileTab?
            init(_ file: FileTab) { self.file = file }
        }

        func currentResidentMiB() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(
                MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            XCTAssertEqual(result, KERN_SUCCESS)
            return Double(info.resident_size) / 1_048_576
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-large-5tabs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rssBefore = currentResidentMiB()
        for (cycle, sizeMiB) in [0, 8, 16, 32, 32].enumerated() {
            let limit = sizeMiB << 20
            let source = String(repeating: String(repeating: "a", count: 511) + "\n",
                                count: limit / 512)
            XCTAssertEqual(source.utf8.count, limit)
            var paths: [URL] = []
            for index in 0..<5 {
                let path = root.appendingPathComponent("cycle\(cycle)-\(index).txt")
                let data = limit == 0 ? Data() : Data(String(index).utf8) + Data(source.utf8.dropFirst())
                XCTAssertEqual(data.count, limit)
                try data.write(to: path)
                paths.append(path)
            }
            let manager = workspaceApplication.makeWindow()
            defer { manager.windowClosed() }
            manager.addLocalFolders([root])
            manager.openFile(paths[0].path)
            let project = try XCTUnwrap(manager.selectedProject)
            for path in paths.dropFirst() { project.openFile(path.path) }
            XCTAssertEqual(project.tabs.count, 5)

            let host = NSHostingView(rootView: NativeRetainedFiles(project: project))
            let window = NSWindow(
                contentRect: NSRect(x: -950, y: -950, width: 1_600, height: 620),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            let deadline = Date().addingTimeInterval(90)
            var mounted = false
            while Date() < deadline {
                host.layoutSubtreeIfNeeded()
                mounted = project.tabs.allSatisfy { tab in
                    guard case .file(let file) = tab.content,
                          let scroll = file.editorView as? NSScrollView,
                          let editor = scroll.documentView as? FocusReportingTextView else {
                        return false
                    }
                    return file.nativeTextStorage.length == limit
                        && editor.textStorage === file.nativeTextStorage
                }
                if mounted { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(mounted, "Five native document owners must really mount")
            guard mounted else {
                window.contentView = nil
                window.close()
                throw WorkspaceError.timedOut
            }
            let activeRSS = currentResidentMiB()
            let oldOwners = project.tabs.compactMap { tab -> WeakFileOwner? in
                guard case .file(let file) = tab.content else { return nil }
                return WeakFileOwner(file)
            }
            let oldStorages = project.tabs.compactMap { tab -> NSTextStorage? in
                guard case .file(let file) = tab.content else { return nil }
                return file.nativeTextStorage
            }
            let cachedScrollViews = project.tabs.compactMap { tab -> NSScrollView? in
                guard case .file(let file) = tab.content else { return nil }
                return file.editorView as? NSScrollView
            }
            XCTAssertEqual(oldOwners.count, 5)
            XCTAssertEqual(cachedScrollViews.count, 5)
            XCTAssertTrue(oldStorages.allSatisfy { $0.length == limit })

            // Publish real bytes through the first editor before closing all five.
            if let first = project.tabs.first,
               case .file(let file) = first.content,
               let scroll = file.editorView as? NSScrollView,
               let editor = scroll.documentView as? FocusReportingTextView {
                editor.insertText("Z", replacementRange: NSRange(location: 0, length: limit == 0 ? 0 : 1))
                XCTAssertTrue(file.isDirty)
                await file.save()
                XCTAssertNil(file.saveError)
                XCTAssertFalse(file.isDirty)
                let actual = try Data(contentsOf: paths[0])
                XCTAssertEqual(actual.count, max(1, limit))
                XCTAssertEqual(actual.first, 90)
                let reopened = FileTab(path: paths[0].path, backend: LocalWorkspaceBackend.shared,
                                       workspaceIdentity: nil)
                try await reopened.waitForText()
                XCTAssertEqual(Data(reopened.text.utf8), actual,
                               "Every size must round-trip its final saved bytes")
                reopened.retireNativeEditor()
            } else {
                XCTFail("The first native editor must be mounted")
            }

            project.closeAll()
            XCTAssertTrue(project.tabs.isEmpty, "Real Project.closeAll must retire all five tabs")
            XCTAssertTrue(cachedScrollViews.allSatisfy { $0.documentView == nil })
            XCTAssertTrue(oldStorages.allSatisfy { $0.length == 0 },
                          "AppKit must not retain the retired text in cached views")
            let releasedDeadline = Date().addingTimeInterval(20)
            while oldOwners.contains(where: { $0.file != nil }), Date() < releasedDeadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(oldOwners.allSatisfy { $0.file == nil },
                          "Closing all tabs must release every FileTab")
            host.removeFromSuperview()
            window.contentView = nil
            window.close()
            let postCloseRSS = currentResidentMiB()
            print("P3_FIVE_LARGE_TABS cycle=\(cycle) each_mib=\(sizeMiB) "
                  + "resident_before_mib=\(rssBefore) active_mib=\(activeRSS) "
                  + "post_close_with_fixtures_mib=\(postCloseRSS) "
                  + "retained_file_owners=\(oldOwners.filter { $0.file != nil }.count) "
                  + "retained_text_bytes=\(oldStorages.reduce(0) { $0 + $1.length })")
        }
        // System allocators may keep free pages resident; RSS is diagnostic,
        // not a substitute for the assertions about native owners and bytes.
        print("P3_FIVE_LARGE_TABS_FINAL initial_mib=\(rssBefore) "
              + "after_scopes_mib=\(currentResidentMiB())")
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
            let cachedScrolls = files.compactMap { $0.editorView as? NSScrollView }
            XCTAssertEqual(cachedScrolls.count, 5)
            for file in files { file.retireNativeEditor() }
            XCTAssertTrue(files.allSatisfy { $0.editorView == nil })
            XCTAssertTrue(cachedScrolls.allSatisfy { $0.documentView == nil },
                          "Retired TextKit document must leave the cached scroll views")
            for item in weakEditors {
                guard let editor = item.editor else { continue }
                XCTAssertNil(editor.syntaxCoordinator)
                XCTAssertNil(editor.delegate)
                XCTAssertFalse(editor.isEditable)
                XCTAssertFalse(editor.isSelectable)
                XCTAssertFalse(editor.undoManager?.canUndo ?? true)
                XCTAssertFalse(editor.undoManager?.canRedo ?? true)
                XCTAssertEqual(editor.textStorage?.length ?? 0, 0,
                               "AppKit may retain the view, not the retired source bytes")
            }
            for i in (0..<windows.count).reversed() {
                hosts[i].removeFromSuperview()
                windows[i].contentView = nil
                windows[i].close()
            }
            hosts.removeAll()
            windows.removeAll()
            files.removeAll()
            try await settle { weakFiles.allSatisfy { $0.file == nil } }
            let releasedFiles = weakFiles.filter { $0.file == nil }.count
            XCTAssertEqual(releasedFiles, 5, "cycle \(cycle): FileTab owners still held")
            // NSWindow and TextKit can cache *detached* view instances longer
            // than their document owner. The required guarantee is that those
            // cached views cannot retain live source, parsers or Undo state.
            for item in weakEditors {
                guard let editor = item.editor else { continue }
                XCTAssertNil(editor.superview)
                XCTAssertNil(editor.window)
                XCTAssertNil(editor.syntaxCoordinator)
                XCTAssertNil(editor.delegate)
                XCTAssertFalse(editor.isEditable)
                XCTAssertFalse(editor.isSelectable)
                XCTAssertFalse(editor.undoManager?.canUndo ?? true)
                XCTAssertFalse(editor.undoManager?.canRedo ?? true)
                XCTAssertEqual(editor.textStorage?.length ?? 0, 0)
            }
            let releasedViews = weakEditors.filter { $0.editor == nil }.count
            print("T5_NATIVE_LIFETIME cycle=\(cycle) simultaneous=5 releasedViews=\(releasedViews) retiredViews=5 filesReleased=\(releasedFiles)")
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
        // Keep the obsolete view alive on purpose: AppKit may cache it even
        // though the owning FileTab has retired its document.
        let cachedRetiredEditor = try XCTUnwrap(editor)
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
        XCTAssertNil(cachedRetiredEditor.superview)
        XCTAssertNil(cachedRetiredEditor.syntaxCoordinator)
        XCTAssertNil(cachedRetiredEditor.delegate)
        XCTAssertFalse(cachedRetiredEditor.isEditable)
        XCTAssertFalse(cachedRetiredEditor.isSelectable)
        XCTAssertFalse(cachedRetiredEditor.undoManager?.canUndo ?? true)
        XCTAssertFalse(cachedRetiredEditor.undoManager?.canRedo ?? true)
        XCTAssertEqual(cachedRetiredEditor.textStorage?.length ?? 0, 0,
                       "A cached obsolete view must release its text immediately")

        let replacementHost = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = replacementHost
        try await settle {
            replacementHost.layoutSubtreeIfNeeded()
            return file.editorView !== cachedScroll && file.editorView != nil
        }
        let freshScroll = try XCTUnwrap(file.editorView as? NSScrollView)
        var freshEditor: FocusReportingTextView? = try XCTUnwrap(
            freshScroll.documentView as? FocusReportingTextView)
        let cachedReplacementEditor = try XCTUnwrap(freshEditor)
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
        XCTAssertNil(cachedReplacementEditor.superview)
        XCTAssertNil(cachedReplacementEditor.syntaxCoordinator)
        XCTAssertNil(cachedReplacementEditor.delegate)
        XCTAssertFalse(cachedReplacementEditor.isEditable)
        XCTAssertFalse(cachedReplacementEditor.isSelectable)
        XCTAssertFalse(cachedReplacementEditor.undoManager?.canUndo ?? true)
        XCTAssertFalse(cachedReplacementEditor.undoManager?.canRedo ?? true)
        XCTAssertEqual(cachedReplacementEditor.textStorage?.length ?? 0, 0,
                       "Switching to binary must retire the old text without waiting for AppKit")
        XCTAssertTrue(file.text.isEmpty)
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: path), binary)
    }

    func testReloadedDocumentDoesNotShareUndoWithRetiredNativeView() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("old\n".utf8).write(to: path)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let host = NSHostingView(rootView: FileViewerView(file: file))
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 700, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            file.retireNativeEditor()
            window.contentView = nil
            window.close()
        }
        window.contentView = host
        window.orderFront(nil)
        try await settle { host.layoutSubtreeIfNeeded(); return file.editorView != nil }
        let oldScroll = try XCTUnwrap(file.editorView as? NSScrollView)
        let oldEditor = try XCTUnwrap(oldScroll.documentView as? NativeCodeTextView)
        let oldUndo = try XCTUnwrap(oldEditor.undoManager)
        oldEditor.insertText("first ", replacementRange: NSRange(location: 0, length: 0))
        oldEditor.breakUndoCoalescing()
        XCTAssertTrue(oldUndo.canUndo)
        await file.save()
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: path), Data("first old\n".utf8))

        // A byte-identical read and remount must preserve the same history.
        file.reloadFromDiskIfClean()
        try await file.waitForText()
        XCTAssertTrue(file.documentUndoManager === oldUndo)
        XCTAssertTrue(oldUndo.canUndo)

        // An accepted replacement is a different document, even while
        // AppKit still retains the old native responder.
        try Data("new\n".utf8).write(to: path)
        file.reloadFromDiskIfClean()
        try await file.waitForText()
        try await settle {
            host.layoutSubtreeIfNeeded()
            return file.editorView != nil && file.editorView !== oldScroll
        }
        let newScroll = try XCTUnwrap(file.editorView as? NSScrollView)
        let newEditor = try XCTUnwrap(newScroll.documentView as? NativeCodeTextView)
        let newUndo = try XCTUnwrap(newEditor.undoManager)
        XCTAssertFalse(newUndo === oldUndo)
        XCTAssertFalse(oldUndo.canUndo)
        XCTAssertFalse(oldUndo.canRedo)
        XCTAssertFalse(oldEditor.allowsUndo)
        XCTAssertTrue(newUndo === file.documentUndoManager)

        newEditor.insertText("second ", replacementRange: NSRange(location: 0, length: 0))
        newEditor.breakUndoCoalescing()
        XCTAssertEqual(file.text, "second new\n")
        XCTAssertTrue(newUndo.canUndo)
        XCTAssertFalse(oldUndo.canUndo, "The obsolete responder must not acquire current document history")
        if oldUndo.canUndo { oldUndo.undo() }
        XCTAssertEqual(file.text, "second new\n", "An obsolete undo owner must not mutate the current document")
        if newUndo.canUndo { newUndo.undo() }
        XCTAssertEqual(file.text, "new\n")
        if newUndo.canRedo { newUndo.redo() }
        XCTAssertEqual(file.text, "second new\n")
    }

    func testRetiredNativeDocumentReleasesLargeTextFromCachedAppKitView() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("retire.swift")
        let source = String(repeating: "let value = \"中文 👋\"\n", count: 10_000)
        try source.write(to: path, atomically: true, encoding: .utf8)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil)
        try await file.waitForText()
        let host = NSHostingView(rootView: SourceTextEditor(
            file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            palette: .theme(dark: true), wrapLines: false, isFocused: false
        ))
        let window = NSWindow(contentRect: NSRect(x: -910, y: -910, width: 680, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        window.orderFront(nil)
        try await settle { host.layoutSubtreeIfNeeded(); return file.editorView != nil }
        let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
        // Deliberately keep the old view alive: AppKit is entitled to cache
        // detached view objects, but not the retired file's large text buffer.
        let editor = try XCTUnwrap(scroll.documentView as? FocusReportingTextView)
        XCTAssertGreaterThan(editor.textStorage?.length ?? 0, 100_000)
        let contentStorage = try XCTUnwrap(editor.textContentStorage)
        let oldStorage = try XCTUnwrap(editor.textStorage)
        let layoutManager = try XCTUnwrap(editor.textLayoutManager)
        XCTAssertTrue(contentStorage.textLayoutManagers.contains { $0 === layoutManager })
        file.retireNativeEditor()
        XCTAssertFalse(contentStorage.textLayoutManagers.contains { $0 === layoutManager },
                       "A retired view must no longer bind the old document to its layout manager")
        XCTAssertNil(file.editorView)
        XCTAssertNil(scroll.documentView)
        XCTAssertNil(editor.syntaxCoordinator)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(oldStorage.length, 0,
                       "The retired document must release its obsolete text bytes")
        XCTAssertEqual(editor.textStorage?.length ?? 0, 0,
                       "A cached retired view must not retain document bytes")
        XCTAssertTrue(file.text.isEmpty, "A retired file must not keep a second text buffer")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), source)
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
        try await settle { releasedFile == nil }
        XCTAssertNil(releasedFile, "Closed FileTab is still owned")
        for editor in [releasedEditor, currentEditor as? FocusReportingTextView].compactMap({ $0 }) {
            XCTAssertNil(editor.superview)
            XCTAssertNil(editor.window)
            XCTAssertNil(editor.syntaxCoordinator)
            XCTAssertNil(editor.delegate)
            XCTAssertFalse(editor.isEditable)
            XCTAssertFalse(editor.isSelectable)
            XCTAssertFalse(editor.undoManager?.canUndo ?? true)
            XCTAssertFalse(editor.undoManager?.canRedo ?? true)
            XCTAssertEqual(editor.textStorage?.length ?? 0, 0,
                           "AppKit-cached retired view must not retain the obsolete document")
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
        let browser = project.newBrowserTab(initialFocus: .none)
        let browserPane = try XCTUnwrap(project.selectedTab)
        let webView = browser.webView
        let source = try XCTUnwrap(project.dock.group(containing: .tab(pane.id)))
        XCTAssertTrue(project.dock.move(.files, into: source.id))
        project.selectTab(pane.id)
        project.selectTab(browserPane.id, extending: .toggle)
        project.dock.select(.files, extending: .toggle)
        project.selectTab(pane.id, extending: .preserve)
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
        let target = try XCTUnwrap(project.dock.group(containing: .git))
        XCTAssertTrue(project.movePanels(.tab(pane.id), into: target.id, edge: .bottom))
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
        XCTAssertEqual(project.dock.tabOrder, [pane.id, browserPane.id])
        XCTAssertEqual(project.dock.selection(in: try XCTUnwrap(project.dock.activeGroupID)), [.tab(pane.id), .tab(browserPane.id), .files])
        XCTAssertTrue(project.tabs.contains { $0 === browserPane })
        XCTAssertTrue(browser.webView === webView)
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

    func testPanelMenuPresentationPinsEntriesOnlyDuringNativeTracking() async {
        let terminal = TerminalSession(launchCommand: "exec /bin/sh -i")
        defer { terminal.terminate() }
        let project = Project(customDirectory: "/fixture/menu", layout: .init())
        let tab = PaneTab(content: .session(terminal))
        project.append(tab)
        let presentation = MainMenuPresentation()

        terminal.terminalDidChangeTitle("⠋ Meaningful Unicode")
        XCTAssertEqual(presentation.panelEntries(for: project).first?.title, "⠋ Meaningful Unicode")
        presentation.beginTracking(project: project, projects: [project])
        let initial = presentation.panelEntries(for: project)
        let invalidated = expectation(description: "Changing a live title must not update a tracked menu")
        invalidated.isInverted = true
        withObservationTracking({ _ = presentation.panelEntries(for: project).map(\.title) }) {
            invalidated.fulfill()
        }
        for title in ["⠙ Meaningful Unicode", "42% complete", "Elapsed 00:03", "Final title"] {
            terminal.terminalDidChangeTitle(title)
            XCTAssertEqual(tab.displayTitle, title)
            XCTAssertEqual(presentation.panelEntries(for: project).map(\.title), initial.map(\.title))
        }
        let another = PaneTab(content: .browser(BrowserTab(initialFocus: .none)))
        project.append(another)
        XCTAssertEqual(presentation.panelEntries(for: project).map(\.id), initial.map(\.id))
        await fulfillment(of: [invalidated], timeout: 0.1)

        presentation.endTracking()
        XCTAssertEqual(presentation.panelEntries(for: project).first?.title, "Final title")
        XCTAssertEqual(presentation.panelEntries(for: project).count, 2)
        XCTAssertEqual(terminal.title, "Final title")
    }

    func testMenuSelectionTracksActiveDockContentAndFreezesOnlyWhileOpen() throws {
        let project = Project(customDirectory: "/fixture/same", layout: .init())
        let other = Project(customDirectory: "/fixture/same", layout: .init())
        let terminal = TerminalSession(launchCommand: "exec /bin/sh -i")
        defer { terminal.terminate() }
        let shell = PaneTab(content: .session(terminal))
        project.append(shell)
        let browser = PaneTab(content: .browser(BrowserTab(initialFocus: .none)))
        project.append(browser)
        let presentation = MainMenuPresentation()
        project.selectTab(shell.id)
        XCTAssertEqual(presentation.activePanel(for: project), .tab(shell.id))
        presentation.beginTracking(project: project, projects: [other, project])
        XCTAssertEqual(presentation.activeProjectID(for: nil), project.id)
        XCTAssertEqual(presentation.activePanel(for: project), .tab(shell.id))
        project.selectTab(browser.id)
        XCTAssertEqual(presentation.activePanel(for: project), .tab(shell.id))
        let oldOrder = ProjectMenuEntry.entries(for: [project, other])
        XCTAssertEqual(presentation.projectDisplay(for: oldOrder[0]).id, project.id)
        XCTAssertEqual(presentation.projectDisplay(for: oldOrder[0]).index, 1)
        presentation.endTracking()
        XCTAssertEqual(presentation.activePanel(for: project), .tab(browser.id))
        project.dock.select(.files)
        XCTAssertEqual(presentation.activePanel(for: project), .files)
        presentation.beginTracking(project: project, projects: [other, project])
        project.dock.select(.git)
        XCTAssertEqual(presentation.activePanel(for: project), .files)
        presentation.endTracking()
        XCTAssertEqual(presentation.activePanel(for: project), .git)
        presentation.beginTracking(project: nil, projects: [])
        XCTAssertNil(presentation.activePanel(for: project))
        XCTAssertNil(presentation.activeProjectID(for: nil))
        presentation.endTracking()
    }

    func testProjectMenuPresentationPinsOrderOnlyWhileTracked() {
        let first = Project(customDirectory: "/fixture/First", layout: .init())
        let second = Project(customDirectory: "/fixture/Second", layout: .init())
        let presentation = MainMenuPresentation()
        XCTAssertEqual(presentation.projectEntries(for: [first]).map(\.title), ["First"])
        presentation.beginTracking(project: nil, projects: [first])
        XCTAssertEqual(presentation.projectEntries(for: [first, second]).map(\.title), ["First"])
        presentation.endTracking()
        XCTAssertEqual(presentation.projectEntries(for: [first, second]).map(\.title),
                       ["First", "Second"])
    }

    func testPanelRefreshKeyOnlyChangesForProjectOrCommandCompletion() {
        let project = Project(customDirectory: "/fixture/repo", layout: .init())
        let other = Project(customDirectory: "/fixture/repo", layout: .init())
        let original = project.panelRefreshKey()
        let withoutCommands = project.panelRefreshKey(includingCommands: false)
        let otherOriginal = other.panelRefreshKey()
        let terminal = project.newSession(launchCommand: "exec /bin/sh -i")
        defer { project.terminateAll(); other.terminateAll() }
        XCTAssertEqual(project.panelRefreshKey(), original, "Opening a terminal does not complete a command")

        let second = project.newSession(launchCommand: "exec /bin/sh -i")
        XCTAssertEqual(project.panelRefreshKey(), original)
        terminal.surface.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000_000)
        let finished = project.panelRefreshKey()
        XCTAssertNotEqual(finished, original, "A background terminal must refresh its own project")
        XCTAssertEqual(project.panelRefreshKey(includingCommands: false), withoutCommands)
        XCTAssertEqual(other.panelRefreshKey(), otherOriginal)
        XCTAssertNotEqual(finished, otherOriginal, "Same directory does not mean same project")

        project.closeContent(.session(second))
        XCTAssertEqual(project.panelRefreshKey(), finished, "Closing another terminal is not a command")
        project.closeContent(.session(terminal))
        XCTAssertEqual(project.panelRefreshKey(), finished, "Closing the last terminal is not a command")
        terminal.surface.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000_000)
        XCTAssertEqual(project.panelRefreshKey(), finished, "Retired terminal callbacks must not refresh")
    }

    func testRepeatedTerminalFindSeedsNewNativeSelection() async throws {
        let terminal = TerminalSession(launchCommand: "exec /bin/sh -c 'stty -echo -echonl; printf \"alpha     \"; read ignored; printf beta; exec /bin/sleep 60'")
        defer { terminal.terminate() }
        let host = NSHostingView(rootView: TerminalHostView(session: terminal, isFocused: false))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: window.contentLayoutRect)
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        window.contentView = root
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await settle { terminal.shellPid != nil }
        let surface = terminal.surface
        let find = terminal.find
        find.present()
        find.query = "alpha"
        try await settle { find.total == 1 }
        func caretRect() -> CGRect {
            window.convertFromScreen(surface.firstRect(forCharacterRange: .init(location: 0, length: 0),
                                                       actualRange: nil))
        }
        let before = caretRect()
        surface.sendText("\n")
        try await settle { caretRect().minX > before.minX + 1 }
        let caret = caretRect()
        XCTAssertEqual(caret.midY, before.midY, accuracy: 1)
        let cellWidth = (caret.minX - before.minX) / 4
        XCTAssertGreaterThan(cellWidth, 0)
        XCTAssertGreaterThan(caret.height, 0)
        // Ghostty reports the bottom of the caret cell as its IME anchor.
        let rowCenter = caret.maxY + caret.height / 2
        let start = CGPoint(x: before.minX - 0.4 * cellWidth, y: rowCenter)
        let end = CGPoint(x: caret.minX - 0.6 * cellWidth, y: rowCenter)
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        XCTAssertTrue(window.makeFirstResponder(surface))
        surface.mouseDown(with: try mouse(.leftMouseDown, at: start))
        surface.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
        surface.mouseUp(with: try mouse(.leftMouseUp, at: end))
        try await settle { surface.hasSelection }
        XCTAssertTrue(window.firstResponder === surface)
        XCTAssertTrue(surface.hasSelection)
        find.present()
        try await settle { find.query == "beta" }
        XCTAssertTrue(find.isPresented)
        XCTAssertEqual(find.query, "beta")
        try await settle { find.total == 1 }
        find.dismiss()
        XCTAssertFalse(find.isPresented)
        find.present()
        XCTAssertTrue(find.isPresented)
        XCTAssertEqual(find.query, "beta")
        try await settle { find.total == 1 }
        let input = NSTextField(string: "")
        root.addSubview(input)
        defer { input.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(input))
        find.query = "alpha"
        find.present()
        XCTAssertEqual(find.query, "alpha", "Retained terminal selection must not overwrite focused find input")
        XCTAssertTrue(terminal.surface === surface)
        find.dismiss()
    }

    func testTerminalAndFindObservationPreserveNativeSurfaceIdentity() async throws {
        let terminal = TerminalSession(launchCommand: "exec /bin/sh -i")
        defer { terminal.terminate() }
        let surface = terminal.surface
        let project = Project(customDirectory: "/fixture/fallback", layout: .init())
        project.append(PaneTab(content: .session(terminal)))

        let titleChanged = expectation(description: "Terminal title observation")
        withObservationTracking({ _ = terminal.title }) { titleChanged.fulfill() }
        terminal.terminalDidChangeTitle("Observed title")
        await fulfillment(of: [titleChanged], timeout: 2)
        XCTAssertEqual(terminal.title, "Observed title")
        XCTAssertEqual(project.name, "fallback")

        let commandChanged = expectation(description: "Real command completion observation")
        withObservationTracking({ _ = project.commandCompletionSequence }) {
            commandChanged.fulfill()
        }
        let previous = project.commandCompletionSequence
        surface.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000_000)
        await fulfillment(of: [commandChanged], timeout: 2)
        XCTAssertEqual(project.commandCompletionSequence, previous + 1)
        surface.terminalDidFinishCommand(exitCode: 0, durationNanos: 1_000_000)
        XCTAssertEqual(project.commandCompletionSequence, previous + 2)

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

        let sentinel = directory.appendingPathComponent("local-only.txt")
        try Data("local".utf8).write(to: sentinel)
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
        guard case .file? = terminal.terminalLinkTarget(for: sentinel.path) else {
            return XCTFail("Local path must resolve before SSH")
        }

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
        XCTAssertNil(terminal.remoteConnection)
        XCTAssertFalse(terminal.acceptsLocalFileDrop,
                       "A foreground ssh is remote input regardless of whether it replaced the root shell")
        XCTAssertNil(terminal.terminalLinkTarget(for: sentinel.path))
        XCTAssertNil(terminal.terminalLinkTarget(for: sentinel.absoluteString))
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
