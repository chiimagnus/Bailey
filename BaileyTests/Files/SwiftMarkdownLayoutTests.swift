import AppKit
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
final class SwiftMarkdownLayoutTests: XCTestCase {
    func testNativePreviewFirstFrameAndLongDocumentScrolling() async throws {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrollViews)
        }

        let resource = MarkdownResource(path: "/tmp/Bailey-Markdown-Layout/README.md",
                                        directory: "/tmp/Bailey-Markdown-Layout",
                                        backend: LocalWorkspaceBackend.shared)
        for count in [500, 5_000, 20_000] {
            let text = (0..<count).map { "Paragraph \($0) **emphasized**." }
                .joined(separator: "\n\n")
            let document = try await MarkdownDocument.parse(text)
            XCTAssertEqual(document.blocks.count, count)
            let preview = MarkdownPreview(document: document, revision: "0",
                                          resource: resource, assetRefresh: 0,
                                          position: .constant(nil))
            let window = NSWindow(
                contentRect: NSRect(x: -2000, y: -2000, width: 800, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: preview)
            host.sizingOptions = []
            window.contentView = host
            window.orderFront(nil)
            let clock = ContinuousClock()
            let start = clock.now
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let first = start.duration(to: clock.now)
            guard let scroll = scrollViews(in: host).first(where: {
                $0.contentView.bounds.height > 200 && $0.contentView.bounds.width > 200
            }), let content = scroll.documentView else {
                window.close()
                return XCTFail("Expected a native scroll container at \(count) paragraphs")
            }
            XCTAssertGreaterThan(content.frame.height, scroll.contentView.bounds.height,
                                 "Lazy preview must be scrollable at \(count) paragraphs")
            let scrollStart = clock.now
            let bottom = max(0, content.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let scrolling = scrollStart.duration(to: clock.now)
            var usage = rusage()
            _ = getrusage(RUSAGE_SELF, &usage)
            print("SWIFTMARKDOWN_LAYOUT paragraphs=\(count) first=\(first) scroll=\(scrolling) "
                    + "process_peak_rss_mib=\(Double(usage.ru_maxrss) / 1_048_576)")
            window.close()
        }
    }
}
