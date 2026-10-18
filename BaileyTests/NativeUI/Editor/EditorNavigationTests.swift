import AppKit
import SwiftUI
import XCTest
@testable import Bailey

private final class NativeParagraphCounter: NSObject, NSTextContentStorageDelegate {
    var requested = 0

    func textContentStorage(_ storage: NSTextContentStorage,
                            textParagraphWith range: NSRange) -> NSTextParagraph? {
        requested += 1
        return nil
    }
}

@MainActor
final class EditorNavigationTests: XCTestCase {
    private func mount(
        _ text: String, font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        width: CGFloat = 900, wraps: Bool = false,
        viewportHeight: CGFloat = 600, appearance: NSAppearance.Name? = nil
    ) -> (window: NSWindow, scroll: NSScrollView, editor: NativeCodeTextView) {
        let editor = NativeCodeTextView()
        editor.font = font
        editor.text = text
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: width, height: viewportHeight))
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        editor.configureWrapping(wraps, viewportWidth: width)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let appearance { window.appearance = NSAppearance(named: appearance) }
        window.contentView = scroll
        window.orderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        editor.layoutSubtreeIfNeeded()
        return (window, scroll, editor)
    }

    private func viewport(_ editor: NativeCodeTextView) -> NSRange? {
        editor.layoutSubtreeIfNeeded()
        editor.nativeLayoutManager.textViewportLayoutController.layoutViewport()
        return editor.nativeLayoutManager.textViewportLayoutController.viewportRange
            .map { NSRange($0, in: editor.nativeContentManager) }
    }

    private func reveal(_ target: NSRange, in editor: NativeCodeTextView) async throws {
        editor.scrollRangeToVisible(target)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            editor.enclosingScrollView?.layoutSubtreeIfNeeded()
            if let range = viewport(editor),
               range.location <= target.location,
               NSMaxRange(range) >= NSMaxRange(target) {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("TextKit 2 viewport must include \(target); actual=\(String(describing: viewport(editor)))")
    }

    func testNativeViewportOnlyMaterializesVisibleParagraphsAfterDistantVisits() async throws {
        let line = "let target = \"中文 👋\" // repeated line\r\n"
        let source = String(repeating: line, count: 10_000)
        for wraps in [false, true] {
            let (window, _, editor) = mount(source, width: wraps ? 300 : 900, wraps: wraps)
            defer { window.close() }
            let counter = NativeParagraphCounter()
            editor.nativeContentManager.delegate = counter
            for row in [0, 2_500, 7_500, 1_000, 9_999, 0, 5_000, 10_000] {
                let offset = min(row * line.utf16.count, source.utf16.count)
                try await reveal(NSRange(location: offset, length: 0), in: editor)
            }
            XCTAssertLessThan(counter.requested, 1_000,
                              "The native editor must not materialize unseen paragraphs")
        }
    }

    func testCurrentSourceFileKeepsCorrectViewportAndHitTesting() async throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Bailey/Files/FileTreeModel.swift")
        let source = try String(contentsOf: sourceFile, encoding: .utf8)
        let (window, scroll, editor) = mount(source)
        defer { window.close() }
        for offset in [0, source.utf16.count / 4, source.utf16.count / 2,
                       3 * source.utf16.count / 4, source.utf16.count - 1, 0] {
            try await reveal(NSRange(location: offset, length: 1), in: editor)
            let rect = editor.firstRect(forCharacterRange: NSRange(location: offset, length: 1),
                                        actualRange: nil)
            XCTAssertTrue(rect.minY.isFinite)
            XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.minY, -1)
        }
        XCTAssertEqual(editor.text, source)
    }

    func testGutterParagraphNumbersMatchNativeSeparatorsAndCRLF() throws {
        for delimiter in ["\n", "\r\n", "\r", "\u{2029}", "\u{2028}x\n"] {
            let source = (0..<1_000).map { "let value\($0) = 1" + delimiter }.joined()
            let (window, _, editor) = mount(source, width: 350)
            defer { window.close() }
            let index = NativeTextLineIndex(source as NSString)
            for row in [0, 1, index.lineCount / 4, index.lineCount / 2, index.lineCount - 1] {
                let position = index.offset(atLine: row)
                let expected = index.row(at: position) + 1
                XCTAssertEqual(editor.lineNumber(atUTF16Offset: position), expected,
                               "Native line labels follow LF source rows")
            }
            editor.showsLineNumbers = true
            XCTAssertNotNil(editor.gutterView)
        }
    }

    func testAvailableEditorFontsKeepUsableGeometry() async throws {
        let source = (0..<382).map { "let item\($0) = 1 // " + String(repeating: "wide", count: $0 % 43) }
            .joined(separator: "\n")
        for font in TerminalFont.selectableFamilies()
            .map({ TerminalFont.resolve(family: $0, size: 13) }) + [TerminalFont.current()] {
            let (window, scroll, editor) = mount(source, font: font)
            defer { window.close() }
            for offset in [0, source.utf16.count / 4, source.utf16.count / 2,
                           3 * source.utf16.count / 4, source.utf16.count - 1, 0] {
                try await reveal(NSRange(location: offset, length: 1), in: editor)
                XCTAssertTrue(scroll.contentView.bounds.minY.isFinite)
                XCTAssertEqual(editor.text, source)
            }
        }
    }

    func testVariableHeightUndoDeleteAllAndRestore() async throws {
        let source = (0..<1_000).map { $0 % 3 == 0 ? "" :
            "let value = 1 // " + String(repeating: "wide", count: $0 % 43)
        }.joined(separator: "\n")
        let (window, scroll, editor) = mount(source)
        defer { window.close() }
        editor.allowsUndo = true
        editor.insertText(NSAttributedString(
            string: "tall\n", attributes: [.font: NSFont.systemFont(ofSize: 32)]), replacementRange: NSRange(location: 0, length: 0))
        editor.undoManager?.undo()
        XCTAssertEqual(editor.text, source)
        try await reveal(NSRange(location: source.utf16.count - 1, length: 1), in: editor)
        editor.insertText("x", replacementRange: NSRange(location: 0, length: source.utf16.count))
        XCTAssertEqual(editor.text, "x")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.text, source)
        XCTAssertGreaterThanOrEqual(editor.frame.height, scroll.contentView.bounds.height)
    }

    func testSourceRestoresScrollSelectionAndResizesWithoutRecreatingDocument() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let text = String(repeating: "let value = 1 // " + String(repeating: "wide", count: 40) + "\n",
                          count: 1_000)
        try Data(text.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.editorState.scrollY = 5_000
        let host = NSHostingView(rootView: SourceTextEditor(file: file, font: TerminalFont.current(),
            palette: .theme(dark: true), wrapLines: false, isFocused: false))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
        let editor = try XCTUnwrap(scroll.documentView as? NativeCodeTextView)
        XCTAssertEqual(editor.text, text)
        XCTAssertEqual(scroll.contentView.bounds.minY, 5_000, accuracy: 2)
        for size in [NSSize(width: 280, height: 300), NSSize(width: 900, height: 700),
                     NSSize(width: 900, height: 600)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            XCTAssertTrue(file.editorView === scroll)
            XCTAssertTrue(scroll.documentView === editor)
        }
        for wraps in [true, false, true, false] {
            host.rootView = SourceTextEditor(file: file, font: TerminalFont.current(),
                palette: .theme(dark: true), wrapLines: wraps, isFocused: false)
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(scroll.documentView === editor)
            XCTAssertEqual(editor.wrapsLines, wraps)
        }
    }

    func testGeometryConfigurationBoundaries() throws {
        for source in ["", "\r\n", "a\u{2028}b\u{2029}c", "中文👋\n", String(repeating: "W", count: 250)] {
            let (window, scroll, editor) = mount(source, width: 280)
            defer { window.close() }
            XCTAssertEqual(editor.nativeContentManager.length, source.utf16.count)
            XCTAssertTrue(editor.textContainer?.widthTracksTextView == true)
            XCTAssertEqual(editor.frame.width, editor.textContainer?.size.width ?? -1, accuracy: 1)
            XCTAssertGreaterThanOrEqual(editor.frame.width, scroll.contentView.bounds.width - 1)
            XCTAssertEqual(editor.text, source)
        }
    }

    func testScrollingPreservesVisibleTextAndSelection() async throws {
        let text = String(repeating: "line 中文👋 text\n", count: 10_000)
        let (window, scroll, editor) = mount(text)
        defer { window.close() }
        for offset in [0, text.utf16.count / 2, text.utf16.count - 1, 0] {
            try await reveal(NSRange(location: offset, length: 0), in: editor)
            XCTAssertTrue(scroll.contentView.bounds.minY.isFinite)
            XCTAssertEqual(editor.text, text)
        }
    }

    func testVariableLengthUnwrappedCodeKeepsLongLineVisible() async throws {
        let source = "short\n" + String(repeating: "W", count: 250) + "z\ntrailing\n"
        let (window, scroll, editor) = mount(source)
        defer { window.close() }
        let offset = ("short\n" + String(repeating: "W", count: 250)).utf16.count
        try await reveal(NSRange(location: offset, length: 1), in: editor)
        XCTAssertGreaterThan(editor.frame.width, scroll.contentView.bounds.width)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
        let range = try XCTUnwrap(NSTextRange(NSRange(location: offset, length: 1),
                                              in: editor.nativeContentManager))
        let fragment = try XCTUnwrap(editor.nativeLayoutManager.textLayoutFragment(for: range.location))
        XCTAssertEqual(fragment.textLineFragments.count, 1)
    }

    func testSourceGeometryAndEditCosts() async throws {
        for rows in [382, 1_000, 10_000, 100_000] {
            let source = String(repeating: "let value = 42 // 中文 👋\n", count: rows)
            let (window, _, editor) = mount(source)
            defer { window.close() }
            for offset in [0, source.utf16.count / 2, source.utf16.count - 1] {
                try await reveal(NSRange(location: offset, length: 1), in: editor)
            }
            var costs = [Double]()
            for _ in 0..<30 {
                let before = CFAbsoluteTimeGetCurrent()
                editor.insertText("x", replacementRange: NSRange(location: 0, length: 0))
                costs.append((CFAbsoluteTimeGetCurrent() - before) * 1000)
                editor.insertText("", replacementRange: NSRange(location: 0, length: 1))
                XCTAssertEqual(editor.text, source)
            }
            costs.sort()
            print("NATIVE_SOURCE rows=\(rows) insertMedian=\(costs[15]) insertP95=\(costs[28])")
            XCTAssertLessThanOrEqual(costs[15], 16)
            XCTAssertLessThanOrEqual(costs[28], 32)
        }
    }

    func testUnwrappedDocumentGeometryAcrossNewViewports() async throws {
        let source = String(repeating: "let abc = \"中文👋\";\n", count: 10_000)
        let (window, scroll, editor) = mount(source)
        defer { window.close() }
        for width: CGFloat in [900, 280, 1_200, 650] {
            scroll.setFrameSize(NSSize(width: width, height: 600))
            editor.configureWrapping(false, viewportWidth: width)
            scroll.layoutSubtreeIfNeeded()
            XCTAssertEqual(editor.frame.width, editor.textContainer?.size.width ?? -1, accuracy: 1)
            for offset in [0, source.utf16.count / 2, source.utf16.count - 1] {
                try await reveal(NSRange(location: offset, length: 1), in: editor)
            }
        }
    }

    func testLongDocumentRevealsForwardAndReverseTargets() async throws {
        let prefix = "# Test\n\n```swift\n"
        let line = "// 中文 👋\nstruct Item { let name = \"value\" }\n"
        let source = prefix + String(repeating: line, count: 4096) + "```\n"
        let (window, _, editor) = mount(source)
        defer { window.close() }
        for batch in 0..<2 {
            for iteration in 0..<30 {
                let row = batch == 0 ? iteration * 4095 / 29 : (29 - iteration) * 4095 / 29
                try await reveal(NSRange(location: prefix.utf16.count + row * line.utf16.count,
                                         length: 2), in: editor)
            }
        }
        XCTAssertEqual(editor.text, source)
    }

    func testShortAndFixedRowDocumentsKeepEndAndBeginningVisible() async throws {
        for source in ["short\n中文 👋\n", String(repeating: "row 中文 👋\n", count: 1_000)] {
            let (window, scroll, editor) = mount(source)
            defer { window.close() }
            for offset in [source.utf16.count, source.utf16.count / 2, 0, source.utf16.count] {
                try await reveal(NSRange(location: offset, length: 0), in: editor)
            }
            XCTAssertGreaterThanOrEqual(editor.frame.height, scroll.contentView.bounds.height)
            XCTAssertEqual(editor.text, source)
        }
    }
}
