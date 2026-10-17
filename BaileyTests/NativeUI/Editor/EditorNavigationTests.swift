import AppKit
import STTextKitPlus
import STTextView
import XCTest
@testable import Bailey

@MainActor
final class EditorNavigationTests: XCTestCase {
    private func mount(_ source: String, fixedRows: Bool = false) -> (NSWindow, STTextView) {
        let editor = STTextView()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.font = font
        editor.showsLineNumbers = !fixedRows
        editor.isHorizontallyResizable = true
        if fixedRows {
            let style = DiffTypography.paragraphStyle(for: font)
            editor.defaultParagraphStyle = style
            editor.typingAttributes[.paragraphStyle] = style
            let rows = source.utf16.filter { $0 == 10 }.count + 1
            editor.overrideContentHeight = CGFloat(rows) * DiffTypography.lineHeight(for: font)
        }
        editor.text = source
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.clipsToBounds = true
        editor.frame = scroll.bounds
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        return (window, editor)
    }

    private func reveal(_ range: NSRange, in editor: STTextView) async throws -> Bool {
        editor.scrollRangeToVisible(range)
        let deadline = Date().addingTimeInterval(5)
        while true {
            editor.layoutSubtreeIfNeeded()
            let viewport = editor.textLayoutManager.textViewportLayoutController.viewportRange
                .map { NSRange($0, in: editor.textContentManager) }
            if let viewport, viewport.location <= range.location, NSMaxRange(viewport) >= NSMaxRange(range) {
                if range.length == 0 { return true }
                if let target = NSTextRange(range, in: editor.textContentManager),
                   let segment = editor.textLayoutManager.textSegmentFrame(in: target, type: .standard),
                   segment.minY >= editor.visibleRect.minY - 1, segment.maxY <= editor.visibleRect.maxY + 1 {
                    return true
                }
            }
            if Date() >= deadline {
                let segment = NSTextRange(range, in: editor.textContentManager)
                    .flatMap { editor.textLayoutManager.textSegmentFrame(in: $0, type: .standard) }
                XCTFail("Requested \(range), actual viewport \(String(describing: viewport)); visible=\(editor.visibleRect), segment=\(String(describing: segment)), document=\(editor.frame)")
                return false
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testLongDocumentRevealsForwardAndReverseTargets() async throws {
        let prefix = "# Test\n\n```swift\n"
        let line = "// 中文 👋\nstruct Item { let name = \"value\" }\n"
        let source = prefix + String(repeating: line, count: 4096) + "```\n"
        let (window, editor) = mount(source)
        defer { window.close() }
        for batch in 0..<2 {
            for iteration in 0..<30 {
                let row = batch == 0 ? iteration * 4095 / 29 : (29 - iteration) * 4095 / 29
                let range = NSRange(location: prefix.utf16.count + row * line.utf16.count, length: 2)
                guard try await reveal(range, in: editor) else { return }
            }
        }
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(source.utf8))
    }

    func testShortAndFixedRowDocumentsKeepEndAndBeginningVisible() async throws {
        for (source, fixedRows) in [("short\n中文 👋\n", false), (String(repeating: "row 中文 👋\n", count: 1000), true)] {
            let (window, editor) = mount(source, fixedRows: fixedRows)
            defer { window.close() }
            for offset in [source.utf16.count, source.utf16.count / 2, 0, source.utf16.count] {
                guard try await reveal(NSRange(location: offset, length: 0), in: editor) else { return }
            }
            XCTAssertGreaterThanOrEqual(editor.frame.height, 600)
            if let height = editor.overrideContentHeight { XCTAssertEqual(editor.frame.height, height, accuracy: 1) }
            XCTAssertEqual(Data((editor.text ?? "").utf8), Data(source.utf8))
        }
    }
}
