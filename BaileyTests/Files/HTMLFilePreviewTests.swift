import AppKit
import Network
import WebKit
import XCTest
@testable import Bailey

@MainActor
final class HTMLFilePreviewTests: XCTestCase {
    @MainActor private final class ConnectionProbe {
        var count = 0
    }

    func testHTMLDefaultsToSourceWithoutChangingTheDecodedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("源稿.HTM")
        let source = "<!doctype html><p>中文 🧪 &amp; CSS</p>\r\n"
        let bytes = Data([0xff, 0xfe]) + (try XCTUnwrap(source.data(using: .utf16LittleEndian)))
        try bytes.write(to: url)
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        XCTAssertTrue(file.canPreviewFile)
        XCTAssertFalse(file.showsFilePreview)
        XCTAssertEqual(file.text, source)
        let webView = try await display(file, in: directory)
        let rendered = try await webView.evaluateJavaScript("document.querySelector('p').textContent",
                                                            contentWorld: .defaultClient) as? String
        XCTAssertEqual(rendered, "中文 🧪 & CSS")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
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
            <style>@import "\(endpoint)/css"; body { background-image: url("\(endpoint)/css-image"); }</style>
            <h1 id="status" contenteditable="true">static</h1>
            <script>document.querySelector('#status').textContent = 'script ran';</script>
            <img src="\(endpoint)/img" onerror="document.querySelector('#status').textContent = 'event ran';">
            <img srcset="\(endpoint)/srcset 1x" alt="network">
            <img src="\(outside.absoluteString)" alt="file">
            <img src="data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20width='9'%20height='9'/%3E">
            <iframe src="\(endpoint)/frame"></iframe>
            <form action="\(endpoint)/form"><input value="static"><button>Submit</button></form>
            <a id="new-window" target="_blank" href="\(endpoint)/new-window">New window</a>
            <a id="navigate" href="\(endpoint)/navigate">Open remote URL</a>
            """, in: root)
        let webView = try await display(file, in: root)
        let url = try XCTUnwrap(webView.url)
        let state = try await webView.evaluateJavaScript("""
            [document.querySelector('h1').textContent, String(document.querySelector('h1').isContentEditable),
             String(document.querySelector('input').readOnly), document.baseURI]
            """, contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(state, ["static", "false", "true", url.absoluteString])
        let widths = try await webView.evaluateJavaScript(
            "Array.from(document.images, img => img.naturalWidth)", contentWorld: .defaultClient
        ) as? [Int]
        XCTAssertEqual(widths, [0, 0, 0, 0])
        _ = try await webView.evaluateJavaScript("""
            document.querySelector('form').requestSubmit();
            document.querySelector('#new-window').click();
            document.querySelector('#navigate').click();
            """, contentWorld: .defaultClient)
        let quiet = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in probe.count > 0 }, object: nil)
        quiet.isInverted = true
        await fulfillment(of: [quiet], timeout: 1)
        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(webView.url, url)
        let positiveControl = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
        positiveControl.start(queue: .main)
        defer { positiveControl.cancel() }
        try await waitUntil { probe.count == 1 }
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

    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !ready() {
            guard ContinuousClock.now < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
