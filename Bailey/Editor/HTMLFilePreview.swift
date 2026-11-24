import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct HTMLFilePreview: View {
    let file: FileTab
    let directory: String?
    let onFocused: () -> Void
    let onShowSource: () -> Void

    var body: some View {
        let request = file.textPreviewRequestID
        let scope = file.previewResource(in: directory)
        Group {
            if let preview = file.htmlPreview {
                if preview.failed {
                    ContentUnavailableView {
                        Label(String(localized: "HTML Preview Unavailable", table: "Editor"),
                              systemImage: "doc.text.magnifyingglass")
                    } actions: {
                        Button(String(localized: "Show Source", table: "Editor"), action: onShowSource)
                    }
                } else {
                    HTMLPreviewMount(preview: preview, onFocused: onFocused)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: [request, scope.directory ?? "", String(file.previewAssetRevision)]) {
            await file.showHTMLPreview(request: request, in: directory)
        }
    }
}

private struct HTMLPreviewMount: NSViewRepresentable {
    let preview: HTMLPreview
    let onFocused: () -> Void

    func makeCoordinator() -> HTMLPreview { preview }

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        let webView = preview.webView
        webView.removeFromSuperview()
        host.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        if preview.webView.superview === host { preview.webView.onFocused = onFocused }
    }

    static func dismantleNSView(_ host: NSView, coordinator: HTMLPreview) {
        guard coordinator.webView.superview === host else { return }
        coordinator.webView.onFocused = nil
        coordinator.suspend()
        coordinator.webView.removeFromSuperview()
    }
}

final class HTMLPreviewWebView: WKWebView {
    var onFocused: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onFocused?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFocused?()
        super.rightMouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items where item.action != #selector(NSText.copy(_:))
            && item.action != #selector(NSText.selectAll(_:)) {
            menu.removeItem(item)
        }
    }
}

@Observable
final class HTMLPreview: NSObject, WKNavigationDelegate {
    private struct Revision: Equatable {
        let document: String
        let directory: String?
        let assets: UInt
    }

    let webView: HTMLPreviewWebView
    private(set) var failed = false
    @ObservationIgnored private let handler = HTMLPreviewScheme()
    @ObservationIgnored private var revision: Revision?
    @ObservationIgnored private var navigation: WKNavigation?
    @ObservationIgnored private var nextNavigationURL: URL?
    @ObservationIgnored private var attempt: UInt = 0
    @ObservationIgnored private var scrollToRestore: CGPoint?

    var hasRefreshableAssets: Bool { !failed && handler.hasRequestedAssets }

    private static let contentRules = Task { @MainActor in
        try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "bailey-static-file-preview-v1", encodedContentRuleList: #"""
            [
              {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^bailey-preview://"},"action":{"type":"ignore-previous-rules"}}
            ]
            """#
        )
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(handler, forURLScheme: HTMLPreviewScheme.scheme)
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            document.querySelectorAll('[contenteditable]').forEach(node => node.removeAttribute('contenteditable'));
            const textTypes = new Set(['text', 'search', 'url', 'tel', 'email', 'password', 'number']);
            document.querySelectorAll('input, textarea, select, button').forEach(node => {
                if (node.tagName === 'TEXTAREA' || (node.tagName === 'INPUT' && textTypes.has(node.type))) {
                    node.readOnly = true;
                } else {
                    node.disabled = true;
                }
            });
            """,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient
        ))
        webView = HTMLPreviewWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func display(_ text: String, resource: PreviewResource, request: String, assets: UInt, isCurrent: () -> Bool) async {
        let revision = Revision(document: request, directory: resource.directory, assets: assets)
        if self.revision == revision && !failed {
            handler.enabled = true
            return
        }
        var scroll: CGPoint?
        if self.revision?.document == request, self.revision?.directory == resource.directory {
            let attempt = self.attempt
            scroll = scrollToRestore
            if scroll == nil,
               let offsets = try? await webView.evaluateJavaScript("([window.scrollX, window.scrollY])",
                                                                 contentWorld: .defaultClient) as? [Double],
               offsets.count == 2, offsets.allSatisfy(\.isFinite) {
                scroll = CGPoint(x: offsets[0], y: offsets[1])
            }
            guard self.attempt == attempt else { return }
        }
        guard !Task.isCancelled, isCurrent() else { return }
        invalidate()
        let attempt = self.attempt
        do {
            guard let rules = try await Self.contentRules.value else { throw URLError(.cannotLoadFromNetwork) }
            try Task.checkCancellation()
            let data = try await Self.documentBytes(text)
            try Task.checkCancellation()
            guard self.attempt == attempt, isCurrent() else { return }
            let url = try handler.install(document: data, resource: resource)
            webView.configuration.userContentController.removeAllContentRuleLists()
            webView.configuration.userContentController.add(rules)
            self.revision = revision
            scrollToRestore = scroll
            failed = false
            nextNavigationURL = url
            navigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            if navigation == nil { failed = true }
        } catch is CancellationError {
        } catch {
            if self.attempt == attempt { failed = true }
        }
    }

    @concurrent private static func documentBytes(_ text: String) async throws -> Data {
        try Task.checkCancellation()
        guard text.utf8.count <= FileTab.maxTextBytes else { throw WorkspaceError.tooLarge }
        return Data(text.utf8)
    }

    func suspend() {
        if webView.isLoading || handler.isLoading { invalidate() }
        handler.enabled = false
    }

    func retire() {
        webView.navigationDelegate = nil
        webView.onFocused = nil
        invalidate()
    }

    func invalidate() {
        attempt &+= 1
        revision = nil
        navigation = nil
        scrollToRestore = nil
        nextNavigationURL = nil
        webView.stopLoading()
        handler.invalidate()
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = false
        guard let url = nextNavigationURL, action.request.url == url,
              action.navigationType == .other, action.targetFrame?.isMainFrame == true,
              !action.shouldPerformDownload else {
            return (.cancel, preferences)
        }
        nextNavigationURL = nil
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async
        -> WKNavigationResponsePolicy {
        guard response.isForMainFrame, response.response.url == handler.documentURL,
              response.response.mimeType == "text/html", response.canShowMIMEType else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, didFail code: WKNavigation!, withError error: any Error) {
        if let navigation, code === navigation { failed = true }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation code: WKNavigation!, withError error: any Error) {
        if let navigation, code === navigation { failed = true }
    }

    func webView(_ webView: WKWebView, didFinish code: WKNavigation!) {
        guard let navigation, code === navigation, let scroll = scrollToRestore,
              let url = handler.documentURL else { return }
        scrollToRestore = nil
        webView.callAsyncJavaScript(
            "if (location.href === expected) window.scrollTo({left, top, behavior: 'instant'});",
            arguments: ["expected": url.absoluteString, "left": scroll.x, "top": scroll.y],
            in: nil, in: .defaultClient, completionHandler: nil
        )
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        invalidate()
        failed = true
    }
}

private final class HTMLPreviewScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "bailey-preview"
    private static let policy = [
        "default-src 'none'",
        "style-src \(scheme): 'unsafe-inline'",
        "img-src \(scheme):",
        "font-src \(scheme):",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
        "sandbox allow-same-origin",
    ].joined(separator: "; ")
    private static let concurrentReads = 4
    private static let resourceLimit = 128
    private static let byteLimit = FileTab.maxTextBytes

    private(set) var documentURL: URL?
    private var document: Data?
    private var resource: PreviewResource?
    private var pending: [(any WKURLSchemeTask, String, HTMLPreviewAsset)] = []
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var callbacks: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    private var remainingReads = 0
    private var remainingBytes = 0
    private var remainingRasterPixels = 0
    var enabled = false
    var isLoading: Bool { !pending.isEmpty || !callbacks.isEmpty }
    var hasRequestedAssets: Bool { documentURL != nil && remainingReads < Self.resourceLimit }

    func install(document: Data, resource: PreviewResource) throws -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = UUID().uuidString.lowercased()
        components.path = resource.path
        guard let url = components.url else { throw URLError(.badURL) }
        documentURL = url
        self.document = document
        self.resource = resource
        remainingReads = Self.resourceLimit
        remainingBytes = Self.byteLimit
        remainingRasterPixels = RasterPreview.pixelLimit
        enabled = true
        return url
    }

    func invalidate() {
        enabled = false
        documentURL = nil
        document = nil
        resource = nil
        let stopped = pending.map(\.0) + Array(callbacks.values)
        pending.removeAll()
        callbacks.removeAll()
        for task in running.values { task.cancel() }
        for callback in stopped { callback.didFailWithError(URLError(.cancelled)) }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard enabled, let url = task.request.url, task.request.httpMethod == "GET",
              url.scheme == Self.scheme, url.host == documentURL?.host, url.port == nil,
              url.user == nil, url.password == nil, url.query == nil else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        if url == documentURL, let document {
            self.document = nil
            respond(to: task, at: url, data: document, type: "text/html; charset=UTF-8")
            return
        }
        guard remainingReads > 0, remainingBytes > 0,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
              url != documentURL,
              let asset = HTMLPreviewAsset(path: path) else {
            task.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        remainingReads -= 1
        pending.append((task, path, asset))
        startReads()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        pending.removeAll { ObjectIdentifier($0.0) == id }
        callbacks.removeValue(forKey: id)
        running[id]?.cancel()
    }

    private func startReads() {
        while enabled, running.count < Self.concurrentReads, !pending.isEmpty, let resource {
            let (callback, path, asset) = pending.removeFirst()
            guard let url = callback.request.url, remainingBytes > 0 else {
                callback.didFailWithError(URLError(.resourceUnavailable))
                continue
            }
            let id = ObjectIdentifier(callback)
            callbacks[id] = callback
            let limit = min(remainingBytes, asset.byteLimit)
            running[id] = Task { [weak self] in
                let result: Result<HTMLPreviewAsset.Payload, any Error>
                do { result = .success(try await asset.read(from: resource, path: path, limit: limit)) }
                catch { result = .failure(error) }
                self?.complete(ObjectIdentifier(callback), at: url, type: asset.contentType, with: result)
            }
        }
    }

    private func complete(
        _ id: ObjectIdentifier, at url: URL, type: String, with result: Result<HTMLPreviewAsset.Payload, any Error>
    ) {
        running.removeValue(forKey: id)
        defer { startReads() }
        guard let callback = callbacks.removeValue(forKey: id) else { return }
        switch result {
        case .success(let asset) where asset.data.count <= remainingBytes && asset.rasterPixels <= remainingRasterPixels:
            remainingBytes -= asset.data.count
            remainingRasterPixels -= asset.rasterPixels
            respond(to: callback, at: url, data: asset.data, type: type)
        case .success:
            callback.didFailWithError(WorkspaceError.tooLarge)
        case .failure(let error):
            callback.didFailWithError(error)
        }
    }

    private func respond(to task: any WKURLSchemeTask, at url: URL, data: Data, type: String) {
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type,
            "Content-Length": String(data.count),
            "Content-Security-Policy": Self.policy,
            "X-Content-Type-Options": "nosniff",
            "X-DNS-Prefetch-Control": "off",
            "Referrer-Policy": "no-referrer",
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
        ]) else { return task.didFailWithError(URLError(.badServerResponse)) }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

private nonisolated enum HTMLPreviewAsset {
    case style, svg, raster(String), font(String, [UInt8])

    struct Payload: Sendable {
        let data: Data
        let rasterPixels: Int
    }

    init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "css": self = .style
        case "svg": self = .svg
        case "png": self = .raster("png")
        case "jpeg", "jpg": self = .raster("jpeg")
        case "gif": self = .raster("gif")
        case "webp": self = .raster("webp")
        case "woff": self = .font("woff", Array("wOFF".utf8))
        case "woff2": self = .font("woff2", Array("wOF2".utf8))
        case "ttf": self = .font("ttf", [0, 1, 0, 0])
        case "otf": self = .font("otf", Array("OTTO".utf8))
        default: return nil
        }
    }

    var byteLimit: Int {
        switch self {
        case .style, .svg: SVGArtwork.byteLimit
        case .font: 4 << 20
        case .raster: 16 << 20
        }
    }

    var contentType: String {
        switch self {
        case .style: "text/css; charset=UTF-8"
        case .svg: "image/svg+xml"
        case .raster(let format): "image/\(format)"
        case .font(let format, _): "font/\(format)"
        }
    }

    @concurrent func read(from resource: PreviewResource, path: String, limit: Int) async throws -> Payload {
        let data = try await resource.read(path: path, maxBytes: limit)
        try Task.checkCancellation()
        var rasterPixels = 0
        switch self {
        case .style:
            guard let css = String(data: data, encoding: .utf8), !css.utf8.contains(0),
                  !css.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else {
                throw CocoaError(.fileReadCorruptFile)
            }
        case .svg:
            try SVGArtwork.validateDocument(data)
        case .raster(let format):
            guard let source = try RasterPreview.source(data),
                  let identifier = CGImageSourceGetType(source),
                  UTType(identifier as String)?.preferredMIMEType == "image/\(format)" else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let count = CGImageSourceGetCount(source)
            guard (1...32).contains(count) else { throw WorkspaceError.tooLarge }
            for index in 0..<count {
                try Task.checkCancellation()
                guard let size = RasterPreview.pixelSize(source, at: index) else { throw WorkspaceError.tooLarge }
                rasterPixels += Int(size.width) * Int(size.height)
                guard rasterPixels <= RasterPreview.pixelLimit else { throw WorkspaceError.tooLarge }
            }
        case .font(_, let signature):
            guard data.starts(with: signature) else { throw CocoaError(.fileReadCorruptFile) }
        }
        return Payload(data: data, rasterPixels: rasterPixels)
    }
}
