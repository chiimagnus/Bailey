import AppKit
import Foundation
import SwiftUI
import WebKit
@testable import kero

@main
enum PaneRetentionCheck {
    @MainActor
    static func settle(_ predicate: () -> Bool, file: StaticString = #fileID, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        preconditionFailure("Native panel did not settle", file: file, line: line)
    }

    @MainActor
    static func close(_ tab: PaneTab, in project: Project, choosing title: String) async throws {
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        var handled = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !handled,
                      let dialog = NSApp.modalWindow ?? NSApp.windows.compactMap(\.attachedSheet).first,
                      let content = dialog.contentView else { return }
                let dialogButtons = buttons(in: content)
                guard let button = dialogButtons.first(where: { $0.title == title }) else { return }
                precondition(!dialogButtons.contains {
                    $0.keyEquivalent.lowercased() == "d" && $0.keyEquivalentModifierMask.contains(.command)
                })
                handled = true
                button.performClick(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        project.close(tab)
        try await settle { handled }
        try await settle { NSApp.modalWindow == nil && !NSApp.windows.contains { $0.attachedSheet != nil } }
    }

    @MainActor
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.html")
        let second = directory.appendingPathComponent("second.html")
        try "<title>Retention first</title><input id='value'><div style='height:5000px'></div>".write(to: first, atomically: true, encoding: .utf8)
        try "<title>Retention second</title><p>Second page</p>".write(to: second, atomically: true, encoding: .utf8)
        let browser = BrowserTab(initialFocus: .none)
        let tab = PaneTab(content: .browser(browser))
        let project = Project(fallbackName: "retention", workspaceConfiguration: .standard)
        project.append(tab)
        let filePath = directory.appendingPathComponent("dirty.txt").path
        try Data("baseline\n".utf8).write(to: URL(fileURLWithPath: filePath))
        let file = FileTab(path: filePath, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        file.text = "unsaved retained\n"
        file.refreshDirtyState()
        let fileTab = PaneTab(content: .file(file))
        project.append(fileTab)
        precondition(project.tabs.count == 2)
        let webView = browser.webView
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFront(nil)
        defer { window.close() }
        func host() -> NSHostingView<PanelContentView> {
            let view = NSHostingView(rootView: PanelContentView(tab: tab, isSelected: false,
                onFocused: {}, onNewBrowserTab: { _ in }, onNewFileTab: { _ in }))
            view.frame = container.bounds
            container.addSubview(view)
            view.layoutSubtreeIfNeeded()
            return view
        }
        var mounted: NSHostingView<PanelContentView>? = host()
        webView.loadFileURL(first, allowingReadAccessTo: directory)
        try await settle { webView.title == "Retention first" && !webView.isLoading }
        _ = try await webView.evaluateJavaScript("document.getElementById('value').value='unsaved form'; window.scrollTo(0, 900); 'ready'")
        let state = try await webView.evaluateJavaScript("document.getElementById('value').value + ':' + scrollY") as! String
        precondition(state.hasPrefix("unsaved form:"))
        precondition((Int(state.split(separator: ":").last!) ?? 0) > 0)
        let source = project.dock.root.group(containing: .tab(tab.id))!
        let destination = project.dock.root.groups.first { $0.id != source.id }!
        precondition(project.dock.move(.tab(tab.id), into: destination.id, edge: .bottom))
        mounted?.removeFromSuperview()
        mounted = nil
        mounted = host()
        try await Task.sleep(for: .milliseconds(100))
        let retained = try await webView.evaluateJavaScript("document.getElementById('value').value + ':' + scrollY") as! String
        precondition(retained == state && browser.webView === webView)
        precondition(file.isDirty && file.text == "unsaved retained\n" && project.tabs.count == 2)
        webView.loadFileURL(second, allowingReadAccessTo: directory)
        try await settle { webView.title == "Retention second" && !webView.isLoading && webView.canGoBack }
        mounted?.removeFromSuperview()
        mounted = nil
        mounted = host()
        browser.goBack()
        try await settle { webView.title == "Retention first" && !webView.isLoading && webView.canGoForward }
        browser.goForward()
        try await settle { webView.title == "Retention second" && !webView.isLoading }
        mounted?.removeFromSuperview()
        mounted = nil
        func fileHost() -> NSHostingView<PanelContentView> {
            let view = NSHostingView(rootView: PanelContentView(tab: fileTab, isSelected: false,
                onFocused: {}, onNewBrowserTab: { _ in }, onNewFileTab: { _ in }))
            view.frame = container.bounds
            container.addSubview(view)
            view.layoutSubtreeIfNeeded()
            return view
        }
        var editorHost: NSHostingView<PanelContentView>? = fileHost()
        try await settle { file.editorView != nil }
        let editor = (file.editorView as! NSScrollView).documentView as! FocusReportingTextView
        editor.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        try await settle { file.text.hasPrefix("edited ") }
        editor.textSelection = NSRange(location: 3, length: 2)
        try await settle { file.editorState.selectionLocation == 3 }
        editorHost?.removeFromSuperview()
        editorHost = nil
        editorHost = fileHost()
        try await settle { file.editorView != nil }
        let restoredEditor = (file.editorView as! NSScrollView).documentView as! FocusReportingTextView
        precondition(restoredEditor.text == file.text && restoredEditor.textSelection == NSRange(location: 3, length: 2))
        precondition(file.isDirty)
        project.close(tab)
        precondition(project.tabs.count == 1 && project.tabs[0] === fileTab)
        try await close(fileTab, in: project, choosing: String(localized: "Cancel", table: "Workspace"))
        precondition(project.tabs.contains { $0 === fileTab } && file.isDirty)
        let failureDirectory = directory.appendingPathComponent("save-failure")
        try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: false)
        let failurePath = failureDirectory.appendingPathComponent("file.txt")
        try Data("baseline".utf8).write(to: failurePath)
        let failedFile = FileTab(path: failurePath.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        failedFile.text = "unsaved failure"
        failedFile.refreshDirtyState()
        let failedTab = PaneTab(content: .file(failedFile))
        project.append(failedTab)
        try FileManager.default.moveItem(at: failureDirectory, to: directory.appendingPathComponent("moved-save-failure"))
        try await close(failedTab, in: project, choosing: String(localized: "Save", table: "Workspace"))
        try await settle { failedFile.saveError != nil }
        precondition(failedFile.isDirty && failedFile.text == "unsaved failure" && project.tabs.contains { $0 === failedTab })
        try await close(failedTab, in: project, choosing: String(localized: "Don’t Save", table: "Workspace"))
        try await settle { !project.tabs.contains { $0 === failedTab } }
        await file.save()
        precondition(!file.isDirty && file.saveError == nil)
        project.close(fileTab)
        precondition(project.tabs.isEmpty)
        editorHost?.removeFromSuperview()
        editorHost = nil

        let restoredProject = Project(fallbackName: "restored independent tabs", workspaceConfiguration: .standard)
        let restoredTab = restoredProject.restoreTab(from: SessionSnapshot.ProjectSnapshot.TabSnapshot(
            content: .file(path: filePath, editorState: file.editorState),
            historyKey: nil, customName: "saved file", contextSessionIndex: nil
        ))
        guard case .file(let restoredFile) = restoredTab.content else { preconditionFailure("Expected restored file") }
        precondition(restoredTab.id != fileTab.id && restoredTab.customName == "saved file")
        precondition(restoredFile.text == file.text && restoredFile.editorState == file.editorState)
        let restoredBrowserTab = restoredProject.restoreTab(from: SessionSnapshot.ProjectSnapshot.TabSnapshot(
            content: .browser(url: nil), historyKey: nil, customName: nil, contextSessionIndex: nil
        ))
        guard case .browser(let restoredBrowser) = restoredBrowserTab.content else { preconditionFailure("Expected restored browser") }
        precondition(restoredBrowser.isBlank && restoredProject.tabs.count == 2)
        restoredProject.closeAll()
        precondition(restoredProject.tabs.isEmpty)

        let terminal = TerminalSession(initialDirectory: directory.path, launchCommand: "exec /bin/sh -i")
        defer { terminal.terminate() }
        let terminalTab = PaneTab(content: .session(terminal))
        project.append(terminalTab)
        func terminalHost() -> NSHostingView<PanelContentView> {
            let view = NSHostingView(rootView: PanelContentView(tab: terminalTab, isSelected: false,
                onFocused: {}, onNewBrowserTab: { _ in }, onNewFileTab: { _ in }))
            view.frame = container.bounds
            return view
        }
        var terminalView: NSHostingView<PanelContentView>? = terminalHost()
        window.contentView = terminalView
        terminalView?.layoutSubtreeIfNeeded()
        try await settle { terminal.shellPid != nil }
        let firstPIDPath = directory.appendingPathComponent("pid-before")
        terminal.sendCommand("printf '%s' $$ > '\(firstPIDPath.path)'\r")
        try await settle { FileManager.default.fileExists(atPath: firstPIDPath.path) }
        let originalPID = try String(contentsOf: firstPIDPath, encoding: .utf8)
        let surface = terminal.surface
        let parking = NSHostingView(rootView: TerminalParkingView(sessions: [terminal]))
        parking.frame = container.bounds
        window.contentView = parking
        terminalView = nil
        parking.layoutSubtreeIfNeeded()
        let parkedPIDPath = directory.appendingPathComponent("pid-parked")
        terminal.sendCommand("printf '%s' $$ > '\(parkedPIDPath.path)'\r")
        try await settle { FileManager.default.fileExists(atPath: parkedPIDPath.path) }
        let parkedPID = try String(contentsOf: parkedPIDPath, encoding: .utf8)
        precondition(parkedPID == originalPID)
        terminalView = terminalHost()
        window.contentView = terminalView
        terminalView?.layoutSubtreeIfNeeded()
        let returnedPIDPath = directory.appendingPathComponent("pid-after")
        terminal.sendCommand("printf '%s' $$ > '\(returnedPIDPath.path)'\r")
        try await settle { FileManager.default.fileExists(atPath: returnedPIDPath.path) }
        let returnedPID = try String(contentsOf: returnedPIDPath, encoding: .utf8)
        precondition(returnedPID == originalPID && terminal.surface === surface)
        project.close(terminalTab)
        try await settle { terminal.hasExited }
        precondition(project.tabs.isEmpty)
        print("PASS: actual single-content panel hosts retain browser page/form/scroll/history, native editor edits/selection, and terminal shell PID across parking/remount")
        print("PASS: closing one independent tab preserves others; native unsaved dialog has no command-D discard binding; Cancel/save failure retain edits; explicit discard/successful save complete")
    }

    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("Pane retention failed: \(error)\n", stderr); exit(1) }
        }
        application.run()
    }
}
