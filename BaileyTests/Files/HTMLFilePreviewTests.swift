import AppKit
import ImageIO
import Network
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
        let file = try await open("""
            <!doctype html>
            <link rel="stylesheet" href="right.css">
            <p>Page stays available</p>
            <img src="own.svg" alt="own image">
            <img src="../project/project.svg" alt="another workspace">
            <img src="folder.svg" alt="folder">
            <img src="wrong.svg" alt="different document type">
            <img src="right.png" alt="native raster">
            <img src="wrong.jpg" alt="wrong raster type">
            <img src="right.jpg" alt="complete JPEG">
            <img src="cut.jpg" alt="truncated JPEG">
            """, in: external)
        let original = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let webView = try await display(file, in: project)
        let color = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('p')).color", contentWorld: .defaultClient
        ) as? String
        XCTAssertEqual(color, "rgb(12, 34, 56)")
        let imageWidths = "Array.from(document.images, img => img.naturalWidth)"
        let initial = try await webView.evaluateJavaScript(imageWidths, contentWorld: .defaultClient) as? [Int]
        XCTAssertEqual(initial, [31, 0, 0, 0, 11, 0, 11, 0])

        try FileManager.default.moveItem(at: ownImage, to: project.appendingPathComponent("own.svg"))
        let reopened = FileTab(path: file.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await reopened.waitForText()
        let nextView = try await display(reopened, in: project)
        let afterMove = try await nextView.evaluateJavaScript(imageWidths, contentWorld: .defaultClient) as? [Int]
        XCTAssertEqual(afterMove, [0, 0, 0, 0, 11, 0, 11, 0])
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

    private func solidPNG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1)
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
