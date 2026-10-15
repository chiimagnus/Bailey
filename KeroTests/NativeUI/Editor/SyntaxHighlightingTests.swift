import AppKit
import STTextKitPlus
import STTextView
import SwiftUI
import SwiftTreeSitter
import TreeSitterClient
import XCTest
@testable import kero

@MainActor
final class SyntaxHighlightingTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testPluginColorsPreserveTextFontCleanStateAndUndo() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift")
        let source = "// comment 中文 👋\nlet value = 42\n"
        try Data(source.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let font = NSFont.monospacedSystemFont(ofSize: 19, weight: .regular)
        let host = NSHostingView(rootView: SourceTextEditor(file: file, font: font,
            palette: .theme(dark: true), wrapLines: false, isFocused: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
        let editor = try XCTUnwrap(scroll.documentView as? STTextView)
        var commentColor: NSColor?
        try await wait {
            host.layoutSubtreeIfNeeded()
            var colors = 0
            editor.textLayoutManager.enumerateRenderingAttributes(
                from: editor.textContentManager.documentRange.location, reverse: false
            ) { _, attributes, range in
                if let color = attributes[.foregroundColor] as? NSColor {
                    colors += 1
                    if NSRange(range, in: editor.textContentManager).location == 0 { commentColor = color }
                }
                return true
            }
            return colors >= 2
        }
        XCTAssertEqual(commentColor, SyntaxHighlightCoordinator.themeColor(for: "comment", theme: SyntaxHighlighting.theme))
        XCTAssertEqual(editor.font, font)
        XCTAssertEqual(editor.text, source)
        XCTAssertEqual(file.text, source)
        XCTAssertFalse(file.isDirty)
        XCTAssertFalse(editor.undoManager?.canUndo ?? false)
        let changedFont = NSFont.monospacedSystemFont(ofSize: 25, weight: .regular)
        host.rootView = SourceTextEditor(file: file, font: changedFont,
            palette: .theme(dark: true), wrapLines: false, isFocused: false)
        try await wait { host.layoutSubtreeIfNeeded(); return editor.font == changedFont }
        let document = try XCTUnwrap(editor.textContentManager.attributedString(in: nil))
        document.enumerateAttribute(.font, in: NSRange(location: 0, length: document.length)) { value, _, _ in
            XCTAssertEqual(value as? NSFont, changedFont)
        }
        XCTAssertEqual(editor.text, source)
        XCTAssertFalse(file.isDirty)
        XCTAssertFalse(editor.undoManager?.canUndo ?? false)
    }

    func testProductionTransformerMatchesUTF16ParserPoints() async throws {
        for source in ["", "let value = 1", "// 中文 👋\r\nlet value = 1\n", "// a\rb\u{2028}c\u{2029}d\n", "\n"] {
            let view = STTextView()
            view.text = source
            let plugin = try XCTUnwrap(SyntaxHighlighting.plugin(for: "fixture.swift"))
            let coordinator = SyntaxHighlightCoordinator(
                textView: view, theme: plugin.theme, language: plugin.language,
                highlightsData: plugin.highlightsData, injectionsData: nil
            )
            let client = coordinator.tsClient
            let transform = try XCTUnwrap(client.locationTransformer)
            var row = 0
            var column = 0
            XCTAssertEqual(transform(0), .zero)
            for (offset, unit) in source.utf16.enumerated() {
                if unit == 10 { row += 1; column = 0 } else { column += 2 }
                XCTAssertEqual(transform(offset + 1), Point(row: row, column: column), "offset \(offset + 1) in \(source.debugDescription)")
            }
            XCTAssertNil(transform(-1))
            XCTAssertNil(transform(source.utf16.count + 1))
            let tree = try await client.currentTree()
            let parser = Parser()
            try parser.setLanguage(plugin.language.parser)
            let expected = try XCTUnwrap(parser.parse(source)?.rootNode)
            XCTAssertEqual(tree.rootNode?.range, expected.range)
            XCTAssertEqual(tree.rootNode?.pointRange, expected.pointRange)
        }
    }
}
