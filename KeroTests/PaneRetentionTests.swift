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
        editor.textSelection = NSRange(location: 3, length: 2)
        try await settle { file.editorState.selectionLocation == 3 }
        editorView?.removeFromSuperview()
        editorView = editorHost()
        try await settle { file.editorView != nil }
        let restored = try XCTUnwrap((file.editorView as? NSScrollView)?.documentView as? FocusReportingTextView)
        XCTAssertEqual(restored.text, file.text)
        XCTAssertEqual(restored.textSelection, NSRange(location: 3, length: 2))
        XCTAssertTrue(file.isDirty)
        editorView?.removeFromSuperview()
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
