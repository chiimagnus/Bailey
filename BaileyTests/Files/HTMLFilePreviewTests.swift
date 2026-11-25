import AppKit
import ImageIO
import Network
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import Bailey

@MainActor
final class HTMLFilePreviewTests: XCTestCase {
    @MainActor private final class ConnectionProbe {
        var count = 0
    }

    private actor SuspendedAssetRunner: RemoteCommandRunner {
        let source: String
        private var started = 0
        private var active = 0
        private var cancelled = 0
        private var peak = 0
        private var stalled = true

        init(source: String) { self.source = source }

        var counts: (started: Int, active: Int, cancelled: Int, peak: Int) {
            (started, active, cancelled, peak)
        }

        func resumeReads() { stalled = false }

        func run(_ argv: [String], stdin: Data?, timeout: TimeInterval) async throws
            -> (status: Int32, stdout: Data, stderr: Data) {
            guard argv.first?.contains("bailey-preview") == true else {
                return (0, Data(source.utf8), Data())
            }
            if stalled {
                started += 1
                active += 1
                peak = max(peak, active)
                defer { active -= 1 }
                do {
                    try await Task.sleep(for: .seconds(20))
                    throw WorkspaceError.timedOut
                } catch is CancellationError {
                    cancelled += 1
                    return (0, svg(width: 17), Data())
                }
            }
            return (0, svg(width: 34), Data())
        }

        private func svg(width: Int) -> Data {
            Data("""
                <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="12">
                  <rect width="\(width)" height="12" fill="blue"/>
                </svg>
                """.utf8)
        }
    }

    func testExplicitBrowserRunsAcceptedSavedHTMLWithoutSavingTheMountedDraft() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("网页 Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let path = directory.appendingPathComponent("index.html")
        let css = directory.appendingPathComponent("style.css")
        try Data("#revision { color: rgb(1, 2, 3) }".utf8).write(to: css)
        let outside = root.appendingPathComponent("outside.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="green"/></svg>"#.utf8).write(to: outside)
        func source(_ revision: String) -> String {
            """
            <!doctype html><meta charset="utf-8">
            <title>\(revision)</title><link rel="stylesheet" href="style.css">
            <div id="revision">\(revision)</div><div id="script">not run</div>
            <img id="outside" src="../outside.svg" onload="this.dataset.result='loaded'" onerror="this.dataset.result='blocked'">
            <script>document.getElementById('script').textContent = 'ran ' + document.title</script>
            """
        }
        let original = Data(source("Saved").utf8)
        let draft = source("Draft")
        try original.write(to: path)
        let project = Project(fallbackName: "Explicit HTML", workspaceConfiguration: .standard)
        project.openLocalFile(path.path)
        let pane = try XCTUnwrap(project.selectedTab)
        guard case .file(let file) = pane.content else { return XCTFail("Expected file tab") }
        defer { file.retireContent() }
        try await file.waitForText()

        // Static preview must retain its security settings even after a normal
        // Browser is opened for the same file.
        let staticPreview = try await display(file, in: directory)
        let staticScript = try await staticPreview.evaluateJavaScript(
            "document.getElementById('script').textContent", contentWorld: .defaultClient
        ) as? String
        XCTAssertEqual(staticScript, "not run")

        let host = NSHostingView(rootView: FileViewerView(file: file, resourceDirectory: directory.path))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderBack(nil)
        file.setFilePreview(false)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return file.editorCoordinator?.scrollView?.window === window
        }
        let editor = try XCTUnwrap(file.editorCoordinator?.scrollView?.documentView as? NativeCodeTextView)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText(draft, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await waitUntil { file.isDirty && file.text == draft }
        XCTAssertEqual(try Data(contentsOf: path), original)

        let browser = try await project.openHTMLInBrowser(file, saveFirst: false) { true }
        XCTAssertEqual(project.selectedTab?.content.id, browser.id)
        XCTAssertFalse(window.firstResponder === editor)
        window.contentView = browser.webView
        try await waitUntil { browser.title == "Saved" && !browser.isLoading }
        let script = try await browser.webView.evaluateJavaScript("document.getElementById('script').textContent") as? String
        let color = try await browser.webView.evaluateJavaScript("getComputedStyle(document.getElementById('revision')).color") as? String
        XCTAssertEqual(script, "ran Saved")
        XCTAssertEqual(color, "rgb(1, 2, 3)")
        try await waitUntil {
            (try? await browser.webView.evaluateJavaScript("document.getElementById('outside').dataset.result") as? String) != nil
        }
        let boundary = try await browser.webView.evaluateJavaScript("document.getElementById('outside').dataset.result") as? String
        XCTAssertEqual(boundary, "blocked")
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, draft)
        let staticScriptAfter = try await staticPreview.evaluateJavaScript(
            "document.getElementById('script').textContent", contentWorld: .defaultClient
        ) as? String
        XCTAssertEqual(staticScriptAfter, "not run")

        // Explicit save-and-run must persist the draft before running it.
        let second = try await project.openHTMLInBrowser(file, saveFirst: true) { true }
        window.contentView = second.webView
        try await waitUntil { second.title == "Draft" && !second.isLoading }
        let secondScript = try await second.webView.evaluateJavaScript("document.getElementById('script').textContent") as? String
        XCTAssertEqual(secondScript, "ran Draft")
        XCTAssertEqual(try Data(contentsOf: path), Data(draft.utf8))
        XCTAssertFalse(file.isDirty)
        XCTAssertNil(file.saveError)
        XCTAssertNil(second.errorMessage)
        XCTAssertFalse(browser.webView === second.webView)
        browser.stopLoading()
        second.stopLoading()
    }

    func testExplicitHTMLBrowserRejectsRemoteIdentityExternalVersionAndStaleTarget() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("index.html")
        let source = Data("<title>accepted</title>".utf8)
        let external = Data("<title>external</title>".utf8)
        XCTAssertEqual(source.count, external.count)
        try source.write(to: path)
        let project = Project(fallbackName: "HTML conflict", workspaceConfiguration: .standard)
        project.openLocalFile(path.path)
        let pane = try XCTUnwrap(project.selectedTab)
        guard case .file(let local) = pane.content else { return XCTFail("Expected local HTML") }
        defer { local.retireContent() }
        try await local.waitForText()
        let remote = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: "windows-tailscale")
        // Deliberately identical pathname and available local bytes; logical
        // remote identity alone must prohibit any execution on this Mac.
        try await remote.waitForText()
        defer { remote.retireContent() }
        project.append(PaneTab(content: .file(remote)))
        XCTAssertFalse(remote.canRunLocalHTML)
        do {
            try await project.openHTMLInBrowser(remote, saveFirst: false) { true }
            XCTFail("A remote HTML target must not be executed on this Mac")
        } catch {}
        XCTAssertEqual(project.tabs.count, 2)

        local.text = "<title>dirty draft</title>"
        XCTAssertTrue(local.isDirty)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date)
        try external.write(to: path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        for saveFirst in [false, true] {
            do {
                try await project.openHTMLInBrowser(local, saveFirst: saveFirst) { true }
                XCTFail("The changed disk version must not be executed or overwritten")
            } catch {}
            XCTAssertEqual(project.tabs.count, 2)
            XCTAssertEqual(try Data(contentsOf: path), external)
            XCTAssertEqual(local.text, "<title>dirty draft</title>")
            XCTAssertTrue(local.isDirty)
        }
        do {
            try await project.openHTMLInBrowser(local, saveFirst: false) { false }
            XCTFail("A stale UI target must not create a Browser")
        } catch {}
        XCTAssertEqual(project.tabs.count, 2)
        XCTAssertEqual(try Data(contentsOf: path), external)
    }

    func testLiveHTMLKeepsReadingPositionAndOnlyDisplaysTheLatestDraft() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Live.html")
        try Data("h1 { color: navy }".utf8).write(to: root.appendingPathComponent("theme.css"))
        func source(_ revision: String) -> String {
            """
            <!doctype html><meta charset="utf-8"><link rel="stylesheet" href="theme.css">
            <div style="height:1500px"></div>
            <h1 id="revision">\(revision)</h1>
            <div style="height:3000px"></div>
            <script>document.getElementById('revision').textContent = 'SCRIPT RAN'</script>
            """
        }
        let original = Data(source("Original").utf8)
        try original.write(to: path)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.setFilePreview(true)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 340),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { file.retireContent(); window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file, resourceDirectory: root.path))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(CGSize(width: 500, height: 340))
        window.orderFront(nil)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            guard let preview = file.htmlPreview else { return false }
            return preview.webView.window === window && preview.webView.url != nil && !preview.webView.isLoading
        }
        let preview = try XCTUnwrap(file.htmlPreview)
        let webView = preview.webView
        func renderedRevision() async -> String? {
            try? await webView.evaluateJavaScript("document.getElementById('revision')?.textContent",
                                                  contentWorld: .defaultClient) as? String
        }
        func scrollY() async -> Double? {
            try? await webView.evaluateJavaScript("window.scrollY", contentWorld: .defaultClient) as? Double
        }
        let initial = await renderedRevision()
        XCTAssertEqual(initial, "Original")
        print("HTML_LIVE original DOM loaded")
        _ = try await webView.evaluateJavaScript("window.scrollTo(0, 1520)", contentWorld: .defaultClient)
        try await waitUntil { (await scrollY() ?? 0) > 1000 }
        let initialScroll = await scrollY()
        XCTAssertEqual(try XCTUnwrap(initialScroll), 1520, accuracy: 2)
        XCTAssertTrue(preview.hasRefreshableAssets)
        let latest = source("最终版本 🧪")
        for revision in 0..<100 {
            file.nativeTextStorage.replaceCharacters(
                in: NSRange(location: 0, length: file.nativeTextStorage.length),
                with: source("Intermediate \(revision)")
            )
        }
        file.nativeTextStorage.replaceCharacters(
            in: NSRange(location: 0, length: file.nativeTextStorage.length), with: latest
        )
        // The previous page remains readable after its resource requests are cancelled.
        // Move inside that page while the new draft is being prepared.
        try await waitUntil { !preview.hasRefreshableAssets }
        let end = "\u{f72b}"
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .function,
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, characters: end, charactersIgnoringModifiers: end,
                                                isARepeat: false, keyCode: 119))
        XCTAssertTrue(window.makeFirstResponder(webView))
        window.sendEvent(key)
        try await waitUntil {
            guard await renderedRevision() == "Original" else { return false }
            return (await scrollY() ?? 0) > 1600
        }
        let moved = await scrollY()
        let readingPosition = try XCTUnwrap(moved)
        try await waitUntil { await renderedRevision() == "最终版本 🧪" && !webView.isLoading }
        do {
            try await waitUntil { abs((await scrollY() ?? 0) - readingPosition) < 2 }
        } catch {
            let actual = await scrollY()
            return XCTFail("Latest edit restored \(actual as Any), not the reader's new position \(readingPosition)")
        }
        XCTAssertTrue(file.htmlPreview === preview)
        XCTAssertTrue(file.htmlPreview?.webView === webView)
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, latest)
        XCTAssertEqual(try Data(contentsOf: path), original)
        file.setFilePreview(false)
        try await waitUntil { webView.superview == nil }
        file.setFilePreview(true)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return webView.window === window && !webView.isLoading
        }
        XCTAssertTrue(file.htmlPreview?.webView === webView)
        let restoredScroll = await scrollY()
        XCTAssertEqual(try XCTUnwrap(restoredScroll), readingPosition, accuracy: 2)
        let restoredRevision = await renderedRevision()
        XCTAssertEqual(restoredRevision, "最终版本 🧪")
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testFindMenuTargetsReadOnlyHTMLPreviewRatherThanItsSource() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("find.html")
        let needle = "真实查找 & WebKit 🧪"
        let source = """
            <!doctype html><div style="height:1000px"></div>
            <p id="first">真实查找 &amp; WebKit 🧪</p><div style="height:1000px"></div>
            <p id="second">真实查找 &amp; WebKit 🧪</p>
            <span data-source-only="not-rendered-attribute">Visible text</span>
            """
        try Data(source.utf8).write(to: path)
        let application = WorkspaceApplication()
        let manager = application.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        manager.openFile(path.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let tab = try XCTUnwrap(project.selectedTab)
        guard case .file(let file) = tab.content else { return XCTFail("Expected HTML file") }
        try await file.waitForText()
        XCTAssertTrue(manager.canFind)
        XCTAssertTrue(manager.canReplace)
        project.setFilePreviewMode(.preview, for: tab)
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 500, height: 320),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: AnyView(FileViewerView(file: file, canFocus: { false },
                                                                  resourceDirectory: root.path)))
        window.contentView = host
        manager.attach(to: window)
        window.orderBack(nil)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            guard let preview = file.htmlPreview else { return false }
            return preview.webView.window === window && preview.webView.url != nil && !preview.webView.isLoading
        }
        let preview = try XCTUnwrap(file.htmlPreview)
        let webView = preview.webView
        XCTAssertFalse(preview.failed)
        XCTAssertFalse(webView.isEditable)
        XCTAssertTrue(manager.canFind)
        XCTAssertFalse(manager.canReplace)
        manager.performFindAction(.show)
        XCTAssertTrue(preview.showsFind)
        func findField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, !field.isHiddenOrHasHiddenAncestor { return field }
            return view.subviews.lazy.compactMap { findField(in: $0) }.first
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [180.0, 500.0] {
                window.setContentSize(.init(width: width, height: 320))
                try await waitUntil {
                    host.layoutSubtreeIfNeeded()
                    return findField(in: host) != nil && abs(host.bounds.width - width) < 1
                }
                let field = try XCTUnwrap(findField(in: host))
                let frame = host.convert(field.bounds, from: field)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX)
                XCTAssertGreaterThan(frame.width, 20)
            }
        }
        func selectedElement() async -> String? {
            try? await webView.evaluateJavaScript(
                "window.getSelection().anchorNode?.parentElement?.id ?? ''", contentWorld: .defaultClient
            ) as? String
        }
        preview.findQuery = needle
        try await waitUntil { await selectedElement() == "first" && preview.findMatchFound == true }
        let firstY = try await webView.evaluateJavaScript("window.scrollY", contentWorld: .defaultClient) as? Double
        XCTAssertGreaterThan(try XCTUnwrap(firstY), 0)
        manager.performFindAction(.next)
        try await waitUntil { await selectedElement() == "second" }
        manager.performFindAction(.previous)
        try await waitUntil { await selectedElement() == "first" }
        preview.findQuery = "not-rendered-attribute"
        try await waitUntil { preview.findMatchFound == false }
        preview.findQuery = "superseded query"
        preview.findQuery = needle
        try await waitUntil { preview.findMatchFound == true }
        _ = try await webView.evaluateJavaScript(
            "window.getSelection().selectAllChildren(document.getElementById('second'))",
            contentWorld: .defaultClient
        )
        preview.findQuery = ""
        manager.performFindAction(.useSelection)
        try await waitUntil { preview.findQuery == needle && preview.findMatchFound == true }
        manager.performFindAction(.useSelection)
        try await waitUntil { preview.findQuery == needle && preview.findMatchFound == true }
        manager.performFindAction(.replace)
        XCTAssertFalse(webView.isEditable)
        XCTAssertFalse(file.isDirty)
        manager.performFindAction(.hide)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return !preview.showsFind && findField(in: host) == nil
        }

        project.setFilePreviewMode(.sideBySide, for: tab)
        host.rootView = AnyView(HStack(spacing: 0) {
            FileViewerView(file: file, canFocus: { false }, resourceDirectory: root.path)
            FileViewerView(file: file, canFocus: { false }, resourceDirectory: root.path, rendersOnlyPreview: true)
        })
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return preview.webView.window === window && file.textView?.window === window
        }
        project.selectPanel(.tab(tab.id))
        XCTAssertTrue(manager.canFind)
        XCTAssertTrue(manager.canReplace)
        let sourceScroll = try XCTUnwrap(file.textView?.enclosingScrollView)
        manager.performFindAction(.show)
        try await waitUntil { sourceScroll.isFindBarVisible }
        XCTAssertFalse(preview.showsFind, "Source Find cannot open the companion's search bar")
        project.selectPanel(.filePreview(tab.id))
        XCTAssertTrue(manager.canFind)
        XCTAssertFalse(manager.canReplace)
        manager.performFindAction(.show)
        XCTAssertTrue(preview.showsFind)
        XCTAssertTrue(file.htmlPreview?.webView === webView)
        XCTAssertEqual(try Data(contentsOf: path), Data(source.utf8))

        let otherRoot = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
        let otherPath = otherRoot.appendingPathComponent(path.lastPathComponent)
        let otherSource = "<p>Independent window</p>"
        try Data(otherSource.utf8).write(to: otherPath)
        let otherManager = application.makeWindow()
        defer { otherManager.windowClosed() }
        otherManager.addLocalFolders([otherRoot])
        otherManager.openFile(otherPath.path)
        let otherProject = try XCTUnwrap(otherManager.selectedProject)
        let otherTab = try XCTUnwrap(otherProject.selectedTab)
        guard case .file(let otherFile) = otherTab.content else { return XCTFail("Expected second HTML file") }
        try await otherFile.waitForText()
        otherProject.setFilePreviewMode(.preview, for: otherTab)
        _ = try await display(otherFile, in: otherRoot)
        let otherPreview = try XCTUnwrap(otherFile.htmlPreview)
        otherManager.performFindAction(.show)
        otherPreview.findQuery = "Independent window"
        try await waitUntil { otherPreview.findMatchFound == true }
        XCTAssertEqual(preview.findQuery, needle)
        manager.performFindAction(.hide)
        XCTAssertTrue(otherPreview.showsFind)
        XCTAssertEqual(otherPreview.findQuery, "Independent window")
        XCTAssertEqual(try Data(contentsOf: otherPath), Data(otherSource.utf8))
        project.close(tab)
        XCTAssertNil(file.htmlPreview)
        preview.performFindAction(.show)
        XCTAssertFalse(preview.showsFind, "Retired previews cannot resume searching")
    }

    func testHTMLDefaultsToSourceWithoutChangingTheDecodedFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures: [(encoding: TextFileEncoding, explicit: Bool, literal: String, expected: [String])] = [
            (.utf16LEBOM, false, "中文 🧪", ["中文 🧪 & CSS", "补全标签"]),
            (.utf8BOM, false, "中文 🧪", ["中文 🧪 & CSS", "补全标签"]),
            (.gbk, true, "中文", ["中文 & CSS", "补全标签"]),
            (.utf8, false, "", [])
        ]
        for fixture in fixtures {
            let url = directory.appendingPathComponent("源稿-\(fixture.encoding.name).HTM")
            let source = fixture.literal.isEmpty ? "" : """
                <!doctype html><meta charset="windows-1252">
                <ul><li>\(fixture.literal) &amp; CSS<li>补全标签</ul>\r
                """
            let bytes = try XCTUnwrap(fixture.encoding.encoded(source))
            try bytes.write(to: url)
            let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            if fixture.explicit { file.reopen(using: fixture.encoding) }
            try await file.waitForText()
            XCTAssertTrue(file.canPreviewFile)
            XCTAssertFalse(file.showsFilePreview)
            XCTAssertEqual(file.text, source)
            XCTAssertEqual(file.fileEncoding, fixture.encoding)
            let webView = try await display(file, in: directory)
            let rendered = try await webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('li'), item => item.textContent)", contentWorld: .defaultClient
            ) as? [String]
            let charset = try await webView.evaluateJavaScript("document.characterSet", contentWorld: .defaultClient)
                as? String
            XCTAssertEqual(rendered, fixture.expected, fixture.encoding.name)
            XCTAssertEqual(charset, "UTF-8")
            XCTAssertFalse(file.isDirty)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testExactHTMLDocumentLimitRendersItsTailAndOverflowStaysUnavailable() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = 32 << 20
        let prefix = Data("<!doctype html>\n<!--\n".utf8)
        let tail = Data("-->\n<h1>末尾 🧪 &amp; intact</h1>\n".utf8)
        let line = Data(repeating: 0x20, count: 4095) + Data([0x0a])
        var bytes = Data(capacity: limit + 1)
        bytes.append(prefix)
        while bytes.count + line.count + tail.count <= limit { bytes.append(line) }
        bytes.append(Data(repeating: 0x20, count: limit - bytes.count - tail.count))
        bytes.append(tail)
        let exactURL = root.appendingPathComponent("exact.html")
        try bytes.write(to: exactURL)
        let exact = FileTab(path: exactURL.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await exact.waitForText()
        XCTAssertEqual(exact.text.utf8.count, limit)
        let webView = try await display(exact, in: root)
        let heading = try await webView.evaluateJavaScript("document.querySelector('h1').textContent",
                                                         contentWorld: .defaultClient) as? String
        XCTAssertEqual(heading, "末尾 🧪 & intact")
        XCTAssertEqual(try Data(contentsOf: exactURL), bytes)

        let overURL = root.appendingPathComponent("over.html")
        bytes.append(0x20)
        try bytes.write(to: overURL)
        let over = FileTab(path: overURL.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        over.loadIfNeeded()
        try await waitUntil { if case .loading = over.content { return false }; return true }
        guard case .unavailable(let reason) = over.content else { return XCTFail("Expected the capacity placeholder") }
        XCTAssertEqual(reason, String(localized: "File is too large to open", table: "Workspace"))
        await over.showHTMLPreview(request: over.textPreviewRequestID, in: root.path)
        XCTAssertNil(over.htmlPreview)
        XCTAssertEqual(try Data(contentsOf: overURL), bytes)
    }

    func testNestedCSSAndImagesUseEachStylesheetsOwnDirectory() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project #100% 中文")
        let styles = project.appendingPathComponent("styles/nested")
        try FileManager.default.createDirectory(at: styles, withIntermediateDirectories: true)
        try Data(#"@import "nested/components.css"; p { display: grid; }"#.utf8)
            .write(to: styles.deletingLastPathComponent().appendingPathComponent("base.css"))
        try Data(#"p { color: rgb(16, 32, 48); background-image: url("../../矢量%20%23%25.svg"); }"#.utf8)
            .write(to: styles.appendingPathComponent("components.css"))
        let svg = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="31" height="19">
              <rect width="31" height="19" fill="blue" />
            </svg>
            """.utf8)
        try svg.write(to: project.appendingPathComponent("矢量 #%.svg"))
        try svg.write(to: root.appendingPathComponent("outside.svg"))
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("outside.svg"),
                                                    withDestinationURL: root.appendingPathComponent("outside.svg"))
        let file = try await open("""
            <!doctype html><link rel="stylesheet" href="styles/base.css">
            <p id="layout">Native   preview</p>
            <img src="矢量%20%23%25.svg" alt="relative">
            <img src="../outside.svg" alt="outside">
            <img src="outside.svg" alt="symbolic link">
            <img src="矢量%20%23%25.svg?variant=other" alt="query">
            """, in: project)
        let webView = try await display(file, in: project)
        let style = try await webView.evaluateJavaScript("""
            [getComputedStyle(document.querySelector('p')).color,
             getComputedStyle(document.querySelector('p')).display,
             document.querySelector('p').innerText]
            """, contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(style, ["rgb(16, 32, 48)", "grid", "Native preview"])
        let widths = try await webView.evaluateJavaScript(
            "Array.from(document.images, img => img.naturalWidth)", contentWorld: .defaultClient
        ) as? [Int]
        XCTAssertEqual(widths, [31, 0, 0, 0])
        let image = try await webView.evaluateJavaScript("""
            const style = getComputedStyle(document.querySelector('p')).backgroundImage;
            style.includes('矢量') || style.includes('%E7%9F%A2')
            """, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(image, true)
    }

    func testProjectExternalHTMLKeepsOnlyItsOwnResourcesBeforeAndAfterAssetMoves() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let external = root.appendingPathComponent("external")
        for directory in [project, external, external.appendingPathComponent("folder.svg")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="31" height="19"/>"#.utf8)
        let ownImage = external.appendingPathComponent("own.svg")
        try svg.write(to: ownImage)
        try svg.write(to: project.appendingPathComponent("project.svg"))
        try Data("<!doctype html><p>Not an image</p>".utf8)
            .write(to: external.appendingPathComponent("wrong.svg"))
        let png = try solidPNG(width: 11, height: 7)
        try png.write(to: external.appendingPathComponent("right.png"))
        try png.write(to: external.appendingPathComponent("wrong.jpg"))
        let jpeg = try XCTUnwrap(NSBitmapImageRep(data: png)?.representation(using: .jpeg, properties: [:]))
        XCTAssertEqual(Array(jpeg.suffix(2)), [0xff, 0xd9])
        try jpeg.write(to: external.appendingPathComponent("right.jpg"))
        try Data(jpeg.dropLast(2)).write(to: external.appendingPathComponent("cut.jpg"))
        try Data("\u{feff}p { color: rgb(12, 34, 56); }".utf8)
            .write(to: external.appendingPathComponent("right.css"))
        try Data("<!doctype html><style>p { color: red !important; }</style>".utf8)
            .write(to: external.appendingPathComponent("wrong.css"))
        try png.write(to: external.appendingPathComponent("encoded #?%中文.png"))
        try FileManager.default.createSymbolicLink(at: external.appendingPathComponent("escaped.svg"),
                                                    withDestinationURL: project.appendingPathComponent("project.svg"))
        let fifo = external.appendingPathComponent("pipe.png")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let file = try await open("""
            <!doctype html>
            <link rel="stylesheet" href="right.css">
            <link rel="stylesheet" href="wrong.css">
            <p>Page stays available</p>
            <img src="own.svg" alt="own image">
            <img src="../project/project.svg" alt="another workspace">
            <img src="folder.svg" alt="folder">
            <img src="wrong.svg" alt="different document type">
            <img src="right.png" alt="native raster">
            <img src="wrong.jpg" alt="wrong raster type">
            <img src="right.jpg" alt="complete JPEG">
            <img src="cut.jpg" alt="truncated JPEG">
            <img src="encoded%20%23%3F%25%E4%B8%AD%E6%96%87.png" alt="encoded filename">
            <img src="right.png?probe=1" alt="query not a filename">
            <img src="escaped.svg" alt="outside symlink">
            <img src="pipe.png" alt="nonregular file">
            """, in: external)
        let original = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let webView = try await display(file, in: project)
        let color = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('p')).color", contentWorld: .defaultClient
        ) as? String
        XCTAssertEqual(color, "rgb(12, 34, 56)")
        let imageWidths = "Array.from(document.images, img => img.naturalWidth)"
        let initial = try await webView.evaluateJavaScript(imageWidths, contentWorld: .defaultClient) as? [Int]
        XCTAssertEqual(initial, [31, 0, 0, 0, 11, 0, 11, 0, 11, 0, 0, 0])

        try FileManager.default.moveItem(at: ownImage, to: project.appendingPathComponent("own.svg"))
        let reopened = FileTab(path: file.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await reopened.waitForText()
        let nextView = try await display(reopened, in: project)
        let afterMove = try await nextView.evaluateJavaScript(imageWidths, contentWorld: .defaultClient) as? [Int]
        XCTAssertEqual(afterMove, [0, 0, 0, 0, 11, 0, 11, 0, 11, 0, 0, 0])
        let status = try await nextView.evaluateJavaScript("""
            [document.querySelector('p').textContent, document.images[0].alt]
            """, contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(status, ["Page stays available", "own image"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path)), original)
    }

    func testNestedStylesheetLoadsScopedFontWithoutUsingOutsideLink() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project")
        let styles = project.appendingPathComponent("styles/nested")
        let fonts = project.appendingPathComponent("fonts")
        try FileManager.default.createDirectory(at: styles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: false)
        let systemFont = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Courier New.ttf")
        let outside = root.appendingPathComponent("Outside.ttf")
        try FileManager.default.copyItem(at: systemFont, to: outside)
        try FileManager.default.copyItem(at: systemFont, to: fonts.appendingPathComponent("Fixture Font.ttf"))
        try FileManager.default.createSymbolicLink(at: fonts.appendingPathComponent("Denied.ttf"),
                                                    withDestinationURL: outside)
        try Data(#"@import "nested/fonts.css";"#.utf8)
            .write(to: styles.deletingLastPathComponent().appendingPathComponent("base.css"))
        try Data("""
            @font-face { font-family: FixtureFont; src: url("../../fonts/Fixture%20Font.ttf"); }
            @font-face { font-family: DeniedFont; src: url("../../fonts/Denied.ttf"); }
            span { font: 20px system-ui; }
            #fixture { font-family: FixtureFont, system-ui; }
            #denied { font-family: DeniedFont, system-ui; }
            """.utf8).write(to: styles.appendingPathComponent("fonts.css"))
        let file = try await open("""
            <!doctype html><link rel="stylesheet" href="styles/base.css">
            <span id="fixture">iiiiiiii</span><span id="denied">iiiiiiii</span><span id="fallback">iiiiiiii</span>
            """, in: project)
        let webView = try await display(file, in: project)
        let result = try await webView.callAsyncJavaScript("""
            const [fixture, denied] = await Promise.allSettled([
                document.fonts.load('20px FixtureFont'),
                document.fonts.load('20px DeniedFont')
            ]);
            const width = id => document.getElementById(id).getBoundingClientRect().width;
            return [fixture.status, fixture.value?.[0]?.status ?? '', denied.status,
                    String(width('fixture') > width('fallback') + 20),
                    String(width('denied') === width('fallback'))];
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(result, ["fulfilled", "loaded", "rejected", "true", "true"])
    }

    func testActiveContentAndExternalRequestsStayInTheStaticPreview() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let probe = ConnectionProbe()
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                probe.count += 1
                connection.cancel()
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }
        try await waitUntil { listener.port != nil }
        let endpoint = "http://127.0.0.1:\(try XCTUnwrap(listener.port).rawValue)"
        let outside = root.appendingPathComponent("other.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="9" height="9"/>"#.utf8).write(to: outside)
        let file = try await open("""
            <!doctype html>
            <base href="\(endpoint)/base/">
            <meta http-equiv="refresh" content="0;url=\(endpoint)/refresh">
            <link rel="preconnect" href="\(endpoint)">
            <link rel="prefetch" href="\(endpoint)/prefetch">
            <link rel="preload" as="image" href="\(endpoint)/preload">
            <script src="\(endpoint)/script"></script>
            <style>
                @import "\(endpoint)/css";
                @font-face { font-family: BlockedNetworkFont; src: url("\(endpoint)/font.ttf"); }
                body { background-image: url("\(endpoint)/css-image"); }
                #network-style { width: 30px; height: 30px;
                    font-family: BlockedNetworkFont;
                    background-image: image-set(url("\(endpoint)/image-set") 1x, url("\(endpoint)/image-set-2x") 2x); }
            </style>
            <h1 id="status" contenteditable="true">static</h1>
            <script>document.querySelector('#status').textContent = 'script ran';</script>
            <img src="\(endpoint)/img" onerror="document.querySelector('#status').textContent = 'event ran';">
            <img srcset="\(endpoint)/srcset 1x" alt="network">
            <img src="\(outside.absoluteString)" alt="file">
            <img src="data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20width='9'%20height='9'/%3E">
            <img src="https://127.0.0.1:\(try XCTUnwrap(listener.port).rawValue)/tls-image" alt="TLS">
            <p id="network-style">Network font and image-set</p>
            <iframe src="\(endpoint)/frame"></iframe>
            <iframe id="inline-frame" srcdoc="<p id='inline-sentinel'>Nested document</p><img src='\(endpoint)/srcdoc'>"></iframe>
            <object data="\(endpoint)/object" type="text/html"></object>
            <embed src="\(endpoint)/embed" type="text/html">
            <form action="\(endpoint)/form">
                <input value="static"><textarea>copyable</textarea>
                <label for="checked">Check</label><input id="checked" type="checkbox">
                <input id="radio" type="radio"><input id="slider" type="range">
                <input id="color" type="color"><input id="file" type="file">
                <select id="select"><option>First</option><option>Second</option></select>
                <button id="reset" type="reset">Reset</button><button id="submit">Submit</button>
            </form>
            <a id="new-window" target="_blank" href="\(endpoint)/new-window">New window</a>
            <a id="navigate" href="\(endpoint)/navigate">Open remote URL</a>
            <a id="javascript" href="javascript:document.querySelector('#status').textContent='link ran'">Script URL</a>
            <a id="download" href="\(endpoint)/download" download="preview-probe.txt">Download</a>
            """, in: root)
        let original = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let webView = try await display(file, in: root)
        let url = try XCTUnwrap(webView.url)
        let state = try await webView.evaluateJavaScript("""
            [document.querySelector('h1').textContent, String(document.querySelector('h1').isContentEditable),
             String(document.querySelector('input').readOnly), document.baseURI]
            """, contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(state, ["static", "false", "true", url.absoluteString])
        let controls = try await webView.evaluateJavaScript("""
            document.querySelector('label').click();
            document.querySelector('#radio').click();
            [String(document.querySelector('#checked').checked),
             String(document.querySelector('#radio').checked),
             String(document.querySelector('textarea').readOnly),
             ...Array.from(document.querySelectorAll('#checked, #radio, #slider, #color, #file, #select, #reset, #submit'),
                           node => String(node.disabled))]
            """, contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(controls, ["false", "false", "true"] + Array(repeating: "true", count: 8))
        let widths = try await webView.evaluateJavaScript(
            "Array.from(document.images, img => img.naturalWidth)", contentWorld: .defaultClient
        ) as? [Int]
        XCTAssertEqual(widths, [0, 0, 0, 0, 0])
        let subresources = try await webView.callAsyncJavaScript("""
            const font = await Promise.allSettled([document.fonts.load('12px BlockedNetworkFont')]);
            const blob = URL.createObjectURL(new Blob(['<svg xmlns="http://www.w3.org/2000/svg" width="9" height="9"/>'], {type: 'image/svg+xml'}));
            try {
                const img = document.createElement('img');
                img.src = blob;
                document.body.append(img);
                const decoded = await Promise.allSettled([img.decode()]);
                return [font[0].status, decoded[0].status, String(img.naturalWidth),
                        String(document.querySelector('#inline-frame').contentDocument?.querySelector('#inline-sentinel') != null)];
            } finally {
                URL.revokeObjectURL(blob);
            }
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(subresources, ["rejected", "rejected", "0", "false"])
        _ = try await webView.evaluateJavaScript("""
            document.querySelector('form').requestSubmit();
            document.querySelector('#new-window').click();
            document.querySelector('#navigate').click();
            document.querySelector('#javascript').click();
            document.querySelector('#download').click();
            """, contentWorld: .defaultClient)
        let quiet = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in probe.count > 0 }, object: nil)
        quiet.isInverted = true
        await fulfillment(of: [quiet], timeout: 1)
        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(webView.url, url)
        let status = try await webView.evaluateJavaScript("document.querySelector('#status').textContent", contentWorld: .defaultClient) as? String
        XCTAssertEqual(status, "static")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path)), original)
        XCTAssertFalse(file.isDirty)
        let positiveControl = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
        positiveControl.start(queue: .main)
        defer { positiveControl.cancel() }
        try await waitUntil { probe.count == 1 }
    }

    func testSharedSVGSubresourcesCannotReachOutsideFileOrNetwork() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let outside = root.appendingPathComponent("private.png")
        let sentinel = try solidPNG(width: 48, height: 24, red: 1, green: 0, blue: 0)
        try sentinel.write(to: outside)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let probe = ConnectionProbe()
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                probe.count += 1
                connection.cancel()
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }
        try await waitUntil { listener.port != nil }
        let endpoint = "http://127.0.0.1:\(try XCTUnwrap(listener.port).rawValue)"
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
                 xmlns:xi="http://www.w3.org/2001/XInclude" width="48" height="24">
              <rect width="48" height="24" fill="#00cc00" onload="fetch('\(endpoint)/event')"/>
              <image width="48" height="24" href="\(endpoint)/image"/>
              <image width="48" height="24" xlink:href="\(outside.absoluteString)"/>
              <image width="48" height="24" href="../private.png"/>
              <xi:include href="\(endpoint)/include"/>
              <foreignObject width="48" height="24"><img xmlns="http://www.w3.org/1999/xhtml" src="\(endpoint)/foreign"/></foreignObject>
              <style>@import url('\(endpoint)/style');</style>
              <script>fetch('\(endpoint)/script')</script>
            </svg>
            """
        let bytes = Data(source.utf8)
        let svgURL = project.appendingPathComponent("shared.svg")
        try bytes.write(to: svgURL)
        let entity = Data("<!DOCTYPE svg [<!ENTITY external SYSTEM '\(endpoint)/entity'>]><svg xmlns='http://www.w3.org/2000/svg' width='48' height='24'><text>&external;</text></svg>".utf8)
        try entity.write(to: project.appendingPathComponent("entity.svg"))
        XCTAssertThrowsError(try SVGArtwork.parse(entity))
        let vector = try SVGArtwork.parse(bytes)
        XCTAssertEqual(vector.image.size, CGSize(width: 48, height: 24))
        XCTAssertEqual(Set(vector.omitted), ["@onload", "image", "include", "foreignObject", "style", "script"])
        let markdownResource = PreviewResource(path: project.appendingPathComponent("README.md").path,
                                               directory: project.path, backend: LocalWorkspaceBackend.shared)
        let markdown = try await markdownResource.picture(XCTUnwrap(URL(string: "shared.svg")))
        let markdownPixels = NSBitmapImageRep(cgImage: markdown.poster)
        func isGreen(_ color: NSColor?) -> Bool {
            guard let color = color?.usingColorSpace(.sRGB) else { return false }
            return color.greenComponent > 0.65 && color.greenComponent - max(color.redComponent, color.blueComponent) > 0.3 && color.alphaComponent > 0.95
        }
        XCTAssertTrue(isGreen(markdownPixels.colorAt(x: 48, y: 24)))

        let svg = FileTab(path: svgURL.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await svg.waitForText()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); svg.retireContent() }
        let host = NSHostingView(rootView: FileViewerView(file: svg, resourceDirectory: project.path))
        window.contentView = host
        window.orderFront(nil)
        func canvas(in view: NSView) -> SVGPreviewScrollView? {
            (view as? SVGPreviewScrollView) ?? view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return canvas(in: host)?.documentView?.subviews.first?.frame.size == vector.image.size
        }
        let native = try XCTUnwrap(canvas(in: host))
        let document = try XCTUnwrap(native.documentView)
        native.setZoom(4, at: CGPoint(x: 24, y: 12))
        native.layoutSubtreeIfNeeded()
        func nativeCenterIsGreen() -> Bool {
            window.displayIfNeeded()
            guard let pixels = native.bitmapImageRepForCachingDisplay(in: native.bounds) else { return false }
            native.cacheDisplay(in: native.bounds, to: pixels)
            let center = document.convert(CGPoint(x: 24, y: 12), to: native)
            let column = Int(center.x * CGFloat(pixels.pixelsWide) / native.bounds.width)
            let row = Int(center.y * CGFloat(pixels.pixelsHigh) / native.bounds.height)
            guard (0..<pixels.pixelsWide).contains(column), (0..<pixels.pixelsHigh).contains(row) else { return false }
            return isGreen(pixels.colorAt(x: column, y: row))
        }
        do { try await waitUntil { nativeCenterIsGreen() } }
        catch {
            if let bitmap = native.bitmapImageRepForCachingDisplay(in: native.bounds) {
                native.cacheDisplay(in: native.bounds, to: bitmap)
                let attachment = XCTAttachment(image: NSImage(size: native.bounds.size, flipped: false) { _ in bitmap.draw(in: native.bounds); return true })
                attachment.name = "Native SVG canvas"
                attachment.lifetime = .keepAlways
                add(attachment)
                print("SVG geometry: \(native.bounds), \(document.frame), \(native.contentView.bounds), \(document.convert(CGPoint(x: 24, y: 12), to: native)), \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            }
            XCTFail("The native SVG canvas did not paint the expected green center: \(error)")
        }

        let page = try await open("<img id='safe' src='shared.svg'><img id='entity' src='entity.svg'>", in: project)
        let webView = try await display(page, in: project)
        let widths = try await webView.evaluateJavaScript(
            "Array.from(document.images, img => img.naturalWidth)", contentWorld: .defaultClient
        ) as? [Int]
        XCTAssertEqual(widths, [48, 0])
        // A custom-scheme image can taint a JavaScript canvas; inspect the actual native snapshot instead.
        let bounds = try await webView.evaluateJavaScript("""
            const r = document.getElementById('safe').getBoundingClientRect(); [r.x, r.y, r.width, r.height];
            """, contentWorld: .defaultClient) as? [Double]
        let rect = try XCTUnwrap(bounds)
        XCTAssertEqual(rect.count, 4)
        guard rect.count == 4 else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        let imageData: Data = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { snapshot, error in
                if let data = snapshot?.tiffRepresentation { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
        let pixels = try XCTUnwrap(NSBitmapImageRep(data: imageData))
        XCTAssertTrue(isGreen(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)))
        let quiet = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in probe.count > 0 }, object: nil)
        quiet.isInverted = true
        await fulfillment(of: [quiet], timeout: 1)
        XCTAssertEqual(probe.count, 0)
        let control = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
        control.start(queue: .main)
        defer { control.cancel() }
        try await waitUntil { probe.count == 1 }
        XCTAssertEqual(try Data(contentsOf: svgURL), bytes)
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
        XCTAssertFalse(svg.isDirty)
    }

    func testIncompleteAndCorruptPNGsAreRejectedByAllPreviewEntries() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var fixtures = [try solidPNG(width: 81, height: 43)]
        if let samples = ProcessInfo.processInfo.environment["BAILEY_IMAGE_ACCEPTANCE_ROOT"] {
            let sample = URL(fileURLWithPath: samples).appending(path: "images/透明与渐变.png")
            fixtures.append(try Data(contentsOf: sample))
        }
        let resource = PreviewResource(path: root.appending(path: "README.md").path,
                                       directory: root.path, backend: LocalWorkspaceBackend.shared)
        var names: [String] = []
        var expected: [Int] = []
        var damaged: [(FileTab, URL, Data, Int)] = []
        defer { for (tab, _, _, _) in damaged { tab.retireContent() } }
        for (index, bytes) in fixtures.enumerated() {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            let dimensions = try XCTUnwrap(RasterPreview.pixelSize(source, at: 0))
            let width = Int(dimensions.width)
            XCTAssertEqual(bytes.suffix(8), Data([0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]))
            let idat = try XCTUnwrap(bytes.range(of: Data("IDAT".utf8)))
            let length = bytes[(idat.lowerBound - 4)..<idat.lowerBound].reduce(0) { ($0 << 8) | Int($1) }
            let crc = idat.upperBound + length
            XCTAssertLessThan(crc + 3, bytes.count)
            var changedCRC = bytes
            changedCRC[crc] ^= 1
            let variants: [(String, Data, Bool)] = [
                ("complete", bytes, true),
                ("missing-end", Data(bytes.dropLast(12)), false),
                ("truncated-data", Data(bytes.prefix(idat.upperBound + length / 2)), false),
                ("bad-crc", changedCRC, false)
            ]
            for (kind, data, valid) in variants {
                let name = "\(index)-\(kind).png"
                let url = root.appending(path: name)
                try data.write(to: url)
                names.append(name)
                expected.append(valid ? width : 0)
                let reference = try XCTUnwrap(URL(string: name))
                let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
                tab.loadIfNeeded()
                try await waitUntil { if case .loading = tab.content { return false }; return true }
                if valid {
                    defer { tab.retireContent() }
                    guard case .image(let preview) = tab.content else { return XCTFail("Valid PNG must open") }
                    XCTAssertEqual(preview.poster.width, width)
                    let picture = try await resource.picture(reference)
                    XCTAssertEqual(picture.poster.width, width)
                } else {
                    damaged.append((tab, url, bytes, width))
                    if case .unavailable = tab.content {} else { XCTFail("\(name) published an invalid image") }
                    XCTAssertNil(tab.originalImageRequest())
                    do {
                        _ = try await resource.picture(reference)
                        XCTFail("Markdown accepted \(name)")
                    } catch CocoaError.fileReadCorruptFile {}
                }
                XCTAssertFalse(tab.isDirty)
                XCTAssertEqual(try Data(contentsOf: url), data)
            }
        }
        let html = names.map { "<img src='\($0)'>" }.joined()
        let page = try await open(html, in: root)
        defer { page.retireContent() }
        let view = try await display(page, in: root)
        let widths = try await view.evaluateJavaScript("Array.from(document.images, img => img.naturalWidth)",
                                                       contentWorld: .defaultClient) as? [Int]
        XCTAssertEqual(widths, expected)
        for (tab, url, bytes, width) in damaged {
            try bytes.write(to: url, options: .atomic)
            tab.reloadFromDiskIfClean()
            try await waitUntil { if case .image = tab.content { return true }; return false }
            guard case .image(let preview) = tab.content else { return XCTFail("Repaired PNG must reopen") }
            XCTAssertEqual(preview.poster.width, width)
            let picture = try await resource.picture(XCTUnwrap(URL(string: url.lastPathComponent)))
            XCTAssertEqual(picture.poster.width, width)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        // A fresh static page must request the repaired source bytes, not reuse the earlier error.
        let repaired = try await open(html, in: root)
        defer { repaired.retireContent() }
        let repairedView = try await display(repaired, in: root)
        let repairedWidths = try await repairedView.evaluateJavaScript("Array.from(document.images, img => img.naturalWidth)",
                                                                       contentWorld: .defaultClient) as? [Int]
        XCTAssertEqual(repairedWidths, fixtures.flatMap { bytes in
            let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
            return Array(repeating: Int(RasterPreview.pixelSize(source, at: 0)!.width), count: 4)
        })
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "preview.html")), Data(html.utf8))
    }

    func testComprehensiveAcceptanceDocumentWithRealStylesAndImages() async throws {
        guard let path = ProcessInfo.processInfo.environment["BAILEY_HTML_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_HTML_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let document = root.appendingPathComponent("HTML 综合验收.html")
        let original = try Data(contentsOf: document)
        let file = FileTab(path: document.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        let webView = try await display(file, in: root)
        let title = try await webView.evaluateJavaScript("document.querySelector('h1').textContent",
                                                       contentWorld: .defaultClient) as? String
        XCTAssertEqual(title, "Bailey / HTML 综合验收")
        let widths = try await webView.evaluateJavaScript(
            "Array.from(document.images, img => img.naturalWidth)", contentWorld: .defaultClient
        ) as? [Int]
        XCTAssertEqual(widths?.count, 4)
        XCTAssertTrue(widths?.allSatisfy { $0 > 0 } == true, String(describing: widths))
        let radius = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.card')).borderRadius", contentWorld: .defaultClient
        ) as? String
        XCTAssertEqual(radius, "14px", "Both levels of on-disk CSS must apply")
        webView.frame.size.width = 380
        let padding = try await webView.evaluateJavaScript("getComputedStyle(document.body).padding",
                                                         contentWorld: .defaultClient) as? String
        XCTAssertEqual(padding, "10px", "Media queries must use the actual WKWebView width")
        XCTAssertEqual(try Data(contentsOf: document), original)
    }

    func testOwnWindowRefreshesHTMLAssetsWithoutRewritingTheDocument() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = root.appendingPathComponent("图形.png")
        try solidPNG(width: 41, height: 24, red: 0.9, green: 0.05, blue: 0.75).write(to: asset)
        let source = """
            <!doctype html><style>body { min-height: 1800px; }</style><img src="图形.png" alt="Shared image">
            """
        let page = try await open(source, in: root)
        let image = FileTab(path: asset.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        let markdownURL = root.appendingPathComponent("shared.md")
        let markdownSource = "![Shared image](图形.png)\n"
        try Data(markdownSource.utf8).write(to: markdownURL)
        let markdown = FileTab(path: markdownURL.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await markdown.waitForText()
        page.setFilePreview(true)
        markdown.setFilePreview(true)
        let frame = NSRect(x: 0, y: 0, width: 800, height: 420)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let imageWindow = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let markdownWindow = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        for item in [window, imageWindow, markdownWindow] { item.isReleasedWhenClosed = false }
        defer {
            for item in [window, imageWindow, markdownWindow] { item.close() }
            for file in [page, image, markdown] { file.retireContent() }
        }
        window.contentView = NSHostingView(rootView: FileViewerView(file: page, resourceDirectory: root.path))
        imageWindow.contentView = NSHostingView(rootView: FileViewerView(file: image))
        markdownWindow.contentView = NSHostingView(rootView: FileViewerView(file: markdown, resourceDirectory: root.path))
        for item in [window, imageWindow, markdownWindow] { item.orderFront(nil) }

        func htmlWidth(_ view: WKWebView?) async -> Int? {
            guard let view, !view.isLoading else { return nil }
            return try? await view.evaluateJavaScript(
                "document.images[0]?.naturalWidth", contentWorld: .defaultClient
            ) as? Int
        }
        func fileWidth() -> Int? {
            guard case .image(let artwork) = image.content else { return nil }
            return artwork.poster.width
        }
        func markdownShowsRevisedImage(_ revised: Bool) -> Bool {
            guard let view = markdownWindow.contentView else { return false }
            view.layoutSubtreeIfNeeded()
            markdownWindow.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var matches = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let found = revised
                        ? color.greenComponent > 0.6 && color.greenComponent - max(color.redComponent, color.blueComponent) > 0.25
                        : min(color.redComponent, color.blueComponent) > 0.5
                            && min(color.redComponent, color.blueComponent) - color.greenComponent > 0.25
                    if found { matches += 1 }
                    if matches >= 24 { return true }
                }
            }
            return false
        }
        do {
            try await waitUntil {
                window.contentView?.layoutSubtreeIfNeeded()
                imageWindow.contentView?.layoutSubtreeIfNeeded()
                guard fileWidth() == 41, markdownShowsRevisedImage(false) else { return false }
                return await htmlWidth(page.htmlPreview?.webView) == 41
            }
        } catch {
            let html = await htmlWidth(page.htmlPreview?.webView)
            if let view = markdownWindow.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "Markdown shared image initial view"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            return XCTFail("Initial image versions: file=\(fileWidth() as Any), HTML=\(html as Any), Markdown=\(markdownShowsRevisedImage(false)), parsed=\(markdown.markdownSourceIndex != nil), error=\(error)")
        }
        let webView = try XCTUnwrap(page.htmlPreview?.webView)
        let documentRequest = page.textPreviewRequestID
        let readingOffset = try await webView.evaluateJavaScript("window.scrollTo(0, 460); window.scrollY",
                                                                contentWorld: .defaultClient) as? Int
        XCTAssertEqual(readingOffset, 460)
        let revised = try solidPNG(width: 67, height: 24, red: 0.1, green: 0.8, blue: 0.1)
        try revised.write(to: asset, options: .atomic)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: imageWindow)
        try await waitUntil { fileWidth() == 67 }
        let beforeOwnWindow = await htmlWidth(webView)
        XCTAssertEqual(beforeOwnWindow, 41)
        XCTAssertTrue(markdownShowsRevisedImage(false))
        XCTAssertFalse(markdownShowsRevisedImage(true))

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        do {
            try await waitUntil { await htmlWidth(webView) == 67 }
        } catch {
            let actual = await htmlWidth(webView)
            return XCTFail("The standalone image refreshed, but the same asset in WebKit is still \(actual as Any)")
        }
        try await waitUntil {
            let offset = try? await webView.evaluateJavaScript("window.scrollY", contentWorld: .defaultClient)
            return offset as? Int == readingOffset
        }
        XCTAssertTrue(markdownShowsRevisedImage(false))
        XCTAssertFalse(markdownShowsRevisedImage(true))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: markdownWindow)
        do { try await waitUntil { markdownShowsRevisedImage(true) } }
        catch { return XCTFail("Markdown did not display the replacement image, revision=\(markdown.previewAssetRevision), error=\(error)") }
        XCTAssertFalse(markdownShowsRevisedImage(false))
        XCTAssertTrue(page.htmlPreview?.webView === webView)
        XCTAssertEqual(page.textPreviewRequestID, documentRequest)
        XCTAssertFalse(page.isDirty)
        XCTAssertFalse(markdown.isDirty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: page.path)), Data(source.utf8))
        XCTAssertEqual(try Data(contentsOf: markdownURL), Data(markdownSource.utf8))
        XCTAssertEqual(try Data(contentsOf: asset), revised)
        window.close()
        page.retireContent()
        XCTAssertEqual(fileWidth(), 67, "Closing the page must not retire the independent image viewer")
        XCTAssertTrue(markdownShowsRevisedImage(true), "Closing the page must not retire the Markdown image")
    }

    func testPageBoundsCombinedPixelsOfConcurrentCompressedImages() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try solidPNG(width: 4_000, height: 4_000)
        XCTAssertLessThan(image.count, 1 << 20)
        for index in 1...3 {
            try image.write(to: root.appendingPathComponent("image-\(index).png"))
        }
        try Data("p { color: rgb(15, 42, 70); }".utf8).write(to: root.appendingPathComponent("page.css"))
        let file = try await open("""
            <!doctype html><link rel="stylesheet" href="page.css">
            <p>Text remains visible</p>
            <img src="image-1.png" width="60" alt="One">
            <img src="image-2.png" width="60" alt="Two">
            <img src="image-3.png" width="60" alt="Three">
            """, in: root)
        let webView = try await display(file, in: root)
        let result = try await webView.evaluateJavaScript("""
            [getComputedStyle(document.querySelector('p')).color,
             ...Array.from(document.images, img => String(img.naturalWidth)).sort()]
            """, contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(result, ["rgb(15, 42, 70)", "0", "4000", "4000"])
    }

    func testEmptyExactAndOversizedStylesheetsAlongsideImportCycle() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = 1 << 20
        let rule = Data("p { color: rgb(21, 31, 41); }".utf8)
        let exact = rule + Data(repeating: 0x20, count: limit - rule.count)
        let rejectedRule = Data("p { color: red; }".utf8)
        let styles: [(String, Data)] = [
            ("empty", Data()),
            ("exact", exact),
            ("over", rejectedRule + Data(repeating: 0x20, count: limit + 1 - rejectedRule.count)),
            ("first", Data(#"@import "second.css";"#.utf8)),
            ("second", Data(#"@import "first.css"; p { background: rgb(80, 90, 100); }"#.utf8)),
            ("not-css", Data("<!doctype html><title>Not a stylesheet</title> {} p { display: none; }".utf8)),
        ]
        for (name, bytes) in styles {
            try bytes.write(to: root.appendingPathComponent(name + ".css"))
        }
        let file = try await open("""
            <!doctype html>
            <link rel="stylesheet" href="empty.css"><link rel="stylesheet" href="exact.css">
            <link rel="stylesheet" href="over.css"><link rel="stylesheet" href="first.css">
            <link rel="stylesheet" href="not-css.css">
            <p>Preview survives failed resources</p>
            """, in: root)
        let webView = try await display(file, in: root)
        let layout = try await webView.evaluateJavaScript("""
            const style = getComputedStyle(document.querySelector('p'));
            [style.color, style.backgroundColor, style.display]
            """, contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(layout, ["rgb(21, 31, 41)", "rgb(80, 90, 100)", "block"])
    }

    func testSlowAssetBurstCancelsOnDetachAndCloseThenReopensWithNewBytes() async throws {
        let images = (1...12).map { "<img src='image-\($0).svg'>" }.joined()
        let runner = SuspendedAssetRunner(source: "<!doctype html><title>Preview</title>" + images)
        let backend = SSHWorkspaceBackend(runner: runner)
        let path = "/fixture/index.html"
        let directory = "/fixture"
        let project = Project(fallbackName: "Preview lifecycle", workspaceConfiguration: .standard)
        defer { project.terminateAll() }
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        let tab = PaneTab(content: .file(file))
        project.tabs = [tab]
        try await file.waitForText()
        await file.showHTMLPreview(request: file.textPreviewRequestID, in: directory)
        try await waitUntil { await runner.counts.active == 4 }
        weak var oldPreview = file.htmlPreview
        weak var oldWebView = file.htmlPreview?.webView
        XCTAssertNotNil(oldWebView)

        file.htmlPreview?.suspend()
        try await waitUntil {
            let counts = await runner.counts
            return counts.cancelled == 4 && counts.active == 0
        }
        let suspended = await runner.counts
        XCTAssertEqual(suspended.started, 4)
        XCTAssertEqual(suspended.peak, 4)

        await file.showHTMLPreview(request: file.textPreviewRequestID, in: directory)
        XCTAssertTrue(file.htmlPreview === oldPreview)
        XCTAssertTrue(file.htmlPreview?.webView === oldWebView)
        try await waitUntil { await runner.counts.active == 4 }
        project.close(tab)
        XCTAssertTrue(project.tabs.isEmpty)
        XCTAssertNil(file.htmlPreview)
        try await waitUntil {
            let counts = await runner.counts
            return counts.cancelled == 8 && counts.active == 0
        }
        try await waitUntil { oldPreview == nil && oldWebView == nil }
        let closed = await runner.counts
        XCTAssertEqual(closed.started, 8, "Queued reads must not start during close")

        await runner.resumeReads()
        let reopened = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        project.tabs = [PaneTab(content: .file(reopened))]
        try await reopened.waitForText()
        let webView = try await display(reopened, in: URL(fileURLWithPath: directory))
        let widths = try await webView.evaluateJavaScript(
            "Array.from(document.images, img => img.naturalWidth)", contentWorld: .defaultClient
        ) as? [Int]
        XCTAssertEqual(widths, Array(repeating: 34, count: 12))
    }

    func testTerminatedWebContentCancelsReadsAndRecoversOnTheSameStaticView() async throws {
        let source = """
            <!doctype html><title>Static preview</title><p id="status">Original</p>
            <script>document.getElementById('status').textContent = 'Ran script'</script>
            """ + (1...12).map { "<img src='image-\($0).svg'>" }.joined()
        let runner = SuspendedAssetRunner(source: source)
        let backend = SSHWorkspaceBackend(runner: runner)
        let project = Project(fallbackName: "Preview renderer exit", workspaceConfiguration: .standard)
        defer { project.terminateAll() }
        let file = FileTab(path: "/fixture/index.html", backend: backend, workspaceIdentity: "ssh:fixture")
        let tab = PaneTab(content: .file(file))
        project.tabs = [tab]
        try await file.waitForText()
        let request = file.textPreviewRequestID
        await file.showHTMLPreview(request: request, in: "/fixture")
        let preview = try XCTUnwrap(file.htmlPreview)
        let webView = preview.webView
        let store = webView.configuration.websiteDataStore
        try await waitUntil {
            let reads = await runner.counts
            return webView.title == "Static preview" && reads.active == 4
        }
        let initialURL = try XCTUnwrap(webView.url)

        let terminateRenderer = NSSelectorFromString("_killWebContentProcess")
        try XCTSkipUnless(webView.responds(to: terminateRenderer), "WebKit does not expose its renderer test hook")
        let implementation = webView.method(for: terminateRenderer)
        let terminate = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Void).self)
        terminate(webView, terminateRenderer)
        try await waitUntil {
            let reads = await runner.counts
            return preview.failed && reads.active == 0 && reads.cancelled == 4
        }
        let interrupted = await runner.counts
        XCTAssertEqual(interrupted.started, 4, "The crash must not restart or advance the old queue")
        XCTAssertEqual(file.text, source)
        XCTAssertFalse(file.isDirty)

        await runner.resumeReads()
        await file.showHTMLPreview(request: request, in: "/fixture")
        try await waitUntil { webView.url != initialURL && webView.title == "Static preview" && !webView.isLoading }
        XCTAssertTrue(file.htmlPreview === preview)
        XCTAssertTrue(file.htmlPreview?.webView === webView)
        XCTAssertTrue(webView.configuration.websiteDataStore === store)
        XCTAssertFalse(preview.failed)
        let status = try await webView.evaluateJavaScript(
            "document.getElementById('status').textContent", contentWorld: .defaultClient
        ) as? String
        XCTAssertEqual(status, "Original")
        let widths = try await webView.evaluateJavaScript(
            "Array.from(document.images, img => img.naturalWidth)", contentWorld: .defaultClient
        ) as? [Int]
        XCTAssertEqual(widths, Array(repeating: 34, count: 12))
        XCTAssertEqual(file.text, source)
        XCTAssertFalse(file.isDirty)

        project.close(tab)
        XCTAssertTrue(project.tabs.isEmpty)
        XCTAssertNil(file.htmlPreview)
        XCTAssertNil(webView.navigationDelegate, "Closing must detach the delegate even if the view is still retained")
        await file.showHTMLPreview(request: file.textPreviewRequestID, in: "/fixture")
        XCTAssertNil(file.htmlPreview)
    }

    private func solidPNG(width: Int, height: Int, red: CGFloat = 0.1,
                          green: CGFloat = 0.5, blue: CGFloat = 0.8) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    private func makeDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        return path
    }

    private func open(_ source: String, in directory: URL) async throws -> FileTab {
        let url = directory.appendingPathComponent("preview.html")
        try Data(source.utf8).write(to: url)
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        return file
    }

    private func display(_ file: FileTab, in directory: URL?) async throws -> WKWebView {
        let load = Task { await file.showHTMLPreview(request: file.textPreviewRequestID, in: directory?.path) }
        try await waitUntil { file.htmlPreview != nil }
        let preview = try XCTUnwrap(file.htmlPreview)
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview.webView
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        await load.value
        try await waitUntil { preview.failed || (preview.webView.url != nil && !preview.webView.isLoading) }
        XCTAssertFalse(preview.failed)
        return preview.webView
    }

    private func waitUntil(_ ready: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await ready()) {
            guard ContinuousClock.now < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
