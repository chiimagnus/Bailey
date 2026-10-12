import AppKit
import Foundation
import SwiftUI
import WebKit
@testable import kero

@main
enum PaneRetentionCheck {
    @MainActor
    static func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        preconditionFailure("Native browser did not settle")
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
        tab.split(Pane(content: .file(file)), toward: .right)
        let webView = browser.webView
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        func host() -> NSHostingView<BrowserView> {
            let view = NSHostingView(rootView: BrowserView(browser: browser, isFocused: false,
                onFocused: {}, onNewBrowserTab: { _ in }, onNewBrowserPane: { _ in }))
            view.frame = container.bounds
            container.addSubview(view)
            view.layoutSubtreeIfNeeded()
            return view
        }
        var mounted: NSHostingView<BrowserView>? = host()
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
        precondition(retained == state && tab.browsers.first === browser && browser.webView === webView)
        precondition(file.isDirty && file.text == "unsaved retained\n" && tab.allPanes.count == 2)
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
        print("PASS: actual App Pane/Dock move retains dirty File and Browser identity; native SwiftUI Browser remount retains page/form/scroll and back-forward history")
    }

    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("Pane retention failed: \(error)\n", stderr); exit(1) }
        }
        application.run()
    }
}
