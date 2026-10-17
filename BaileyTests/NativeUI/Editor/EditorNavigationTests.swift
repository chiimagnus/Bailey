import AppKit
import STTextKitPlus
import STTextView
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
final class EditorNavigationTests: XCTestCase {
    func testVariableLengthUnwrappedCodeGeometryBaseline() throws {
        let source = (0..<1_000).map { row in
            row % 3 == 0 ? "" : "let value = 1 // " + String(repeating: "wide", count: row % 43)
        }.joined(separator: "\n")
        let (window, editor) = mount(source, font: TerminalFont.resolve(family: "", size: 13))
        defer { window.close() }
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        var heights: [CGFloat] = []
        for fraction in [0, 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - 600) * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            editor.prepareContent(in: editor.visibleRect)
            editor.layoutSubtreeIfNeeded()
            heights.append(editor.frame.height)
        }
        print("EDITOR_VARIABLE heights=\(heights)")
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(source.utf8))
    }

    func testSourceGeometryAndEditCosts() async throws {
        executionTimeAllowance = 300
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for rows in [382, 1_000, 10_000, 100_000] {
            let source = (0..<rows).map { row in
                switch row % 5 {
                case 0: "struct Item\(row) {"
                case 1: "    let title = \"中文 👋 e\u{301}\" // a fairly realistic code line"
                case 2: "    let value = 1234567890 // " + String(repeating: "wide", count: row % 31)
                case 3: "}"
                default: ""
                }
            }.joined(separator: "\n")
            let path = directory.appendingPathComponent("fixture-\(rows).txt")
            try Data(source.utf8).write(to: path)
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await file.waitForText()
            for wraps in [false, true] {
                let host = NSHostingView(rootView: SourceTextEditor(
                    file: file, font: TerminalFont.resolve(family: "", size: 13), palette: .theme(dark: true), wrapLines: wraps,
                    isFocused: false
                ))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                let deadline = Date().addingTimeInterval(5)
                while file.editorView == nil, Date() < deadline {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(5))
                }
                let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
                let editor = try XCTUnwrap(scroll.documentView as? STTextView)
                while scroll.contentView.bounds.height < 100, Date() < deadline {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertGreaterThan(scroll.contentView.bounds.height, 100)
                print("EDITOR_ENV font=\(editor.font.fontName) size=\(editor.font.pointSize) scale=\(window.backingScaleFactor) viewport=\(scroll.contentView.bounds.size)")
                var heights: [CGFloat] = []
                var origins: [CGFloat] = []
                for fraction in [0, 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0] {
                    let origin = NSPoint(x: 0, y: max(0, editor.frame.height - scroll.contentView.bounds.height) * fraction)
                    scroll.contentView.scroll(to: origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    editor.prepareContent(in: editor.visibleRect)
                    editor.layoutSubtreeIfNeeded()
                    heights.append(editor.frame.height)
                    origins.append(scroll.contentView.bounds.minY)
                }
                print("EDITOR_SOURCE rows=\(rows) wrap=\(wraps) bytes=\(source.utf8.count) heights=\(heights) origins=\(origins)")
                for position in [0, source.utf16.count / 2, source.utf16.count] {
                    var durations: [Double] = []
                    for _ in 0..<30 {
                        let started = CFAbsoluteTimeGetCurrent()
                        editor.replaceCharacters(in: NSRange(location: position, length: 0), with: "a")
                        editor.replaceCharacters(in: NSRange(location: position, length: 1), with: "")
                        durations.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                        await Task.yield()
                    }
                    durations.sort()
                    print("EDITOR_INPUT rows=\(rows) wrap=\(wraps) position=\(position) pair_ms median=\(durations[15]) p95=\(durations[28]) max=\(durations[29])")
                }
                XCTAssertEqual(Data(file.text.utf8), Data(source.utf8))
            }
        }
    }

    func testUnwrappedDocumentGeometryAcrossNewViewports() async throws {
        for rows in [382, 1_000, 10_000, 100_000] {
            let source = String(repeating: "struct Item { let value = 123 } // stable code row\n", count: rows)
            let started = CFAbsoluteTimeGetCurrent()
            let (window, editor) = mount(source)
            defer { window.close() }
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            let initialHeight = editor.frame.height
            var heights = [initialHeight]
            var knobs = [scroll.verticalScroller?.knobProportion ?? -1]
            for fraction in [0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0] {
                let origin = NSPoint(x: 0, y: max(0, editor.frame.height - scroll.contentView.bounds.height) * fraction)
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                editor.prepareContent(in: editor.visibleRect)
                editor.layoutSubtreeIfNeeded()
                heights.append(editor.frame.height)
                knobs.append(scroll.verticalScroller?.knobProportion ?? -1)
            }
            print("EDITOR_GEOMETRY rows=\(rows) seconds=\(CFAbsoluteTimeGetCurrent() - started) heights=\(heights) knobs=\(knobs)")
            XCTAssertEqual(try XCTUnwrap(heights.max()), try XCTUnwrap(heights.min()), accuracy: 1, "rows=\(rows)")
        }
    }

    private func mount(_ source: String, fixedRows: Bool = false, font: NSFont? = nil) -> (NSWindow, STTextView) {
        let editor = STTextView()
        let font = font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
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
