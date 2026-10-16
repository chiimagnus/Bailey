import AppKit
import Neon
import STTextKitPlus
import STTextView
import STTextViewCommon
import SwiftUI
import SwiftTreeSitter
import TreeSitterClient
import XCTest
@testable import kero

private final class ReadInterceptingContentStorage: STTextContentStorage {
    var onNextRead: (() -> Void)?

    override var textStorage: NSTextStorage? {
        get {
            let callback = onNextRead
            onNextRead = nil
            callback?()
            return super.textStorage
        }
        set { super.textStorage = newValue }
    }
}

private struct ObservedSyntaxPlugin: STPlugin {
    let plugin: SyntaxHighlightPlugin
    let observe: (SyntaxHighlightCoordinator) -> Void

    func makeCoordinator(context: CoordinatorContext) -> SyntaxHighlightCoordinator {
        let coordinator = plugin.makeCoordinator(context: context)
        observe(coordinator)
        return coordinator
    }

    func setUp(context: any Context) {
        plugin.setUp(context: SyntaxContext(coordinator: context.coordinator,
            textView: context.textView, events: context.events))
    }

    private struct SyntaxContext: PluginContext {
        typealias Plugin = SyntaxHighlightPlugin
        let coordinator: SyntaxHighlightCoordinator
        let textView: STTextView
        let events: STPluginEvents
    }
}

@MainActor
final class SyntaxHighlightingTests: XCTestCase {
    private func mountedPlugin(
        path: String = "fixture.swift", source: String = "let value = Capitalized.method()\n"
    ) throws -> (
        window: NSWindow, editor: STTextView, coordinator: SyntaxHighlightCoordinator,
        storage: ReadInterceptingContentStorage
    ) {
        let plugin = try XCTUnwrap(SyntaxHighlighting.plugin(for: path))
        let storage = ReadInterceptingContentStorage()
        storage.textStorage = NSTextStorage()
        let editor = STTextView()
        editor.textContentManager = storage
        editor.text = source
        var observed: SyntaxHighlightCoordinator?
        editor.addPlugin(ObservedSyntaxPlugin(plugin: plugin) { observed = $0 })
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        editor.frame = scroll.bounds
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        return (window, editor, try XCTUnwrap(observed), storage)
    }

    private func hasRenderingColor(_ editor: STTextView) -> Bool {
        var colored = false
        editor.layoutSubtreeIfNeeded()
        editor.textLayoutManager.enumerateRenderingAttributes(
            from: editor.textContentManager.documentRange.location, reverse: false
        ) { _, attributes, _ in
            colored = attributes[.foregroundColor] != nil
            return !colored
        }
        return colored
    }

    private func color(_ editor: STTextView, at offset: Int) -> NSColor? {
        var found: NSColor?
        editor.layoutSubtreeIfNeeded()
        editor.textLayoutManager.enumerateRenderingAttributes(
            from: editor.textContentManager.documentRange.location, reverse: false
        ) { _, attributes, range in
            if NSLocationInRange(offset, NSRange(range, in: editor.textContentManager)) {
                found = attributes[.foregroundColor] as? NSColor
                return false
            }
            return true
        }
        return found
    }

    func testOldSuccessIsNotDeliveredWhenContentChangesDuringPredicateRead() async throws {
        let mounted = try mountedPlugin()
        defer { mounted.window.close() }
        try await wait { self.hasRenderingColor(mounted.editor) }
        let provider = try XCTUnwrap(mounted.coordinator.highlighter).tokenProvider
        let length = (mounted.editor.text ?? "").utf16.count
        var edited = false
        mounted.storage.onNextRead = {
            mounted.editor.insertText("// fresh\n", replacementRange: NSRange(location: 0, length: 0))
            edited = true
        }
        var deliveries = 0
        provider(NSRange(location: 0, length: length)) { _ in deliveries += 1 }
        try await wait { edited }
        XCTAssertEqual(deliveries, 0, "The actual provider must discard its old success, not paint old offsets")
        let tree = try await mounted.coordinator.tsClient.currentTree()
        XCTAssertEqual(tree.rootNode?.range.length, (mounted.editor.text ?? "").utf16.count)
        try await wait {
            self.color(mounted.editor, at: 0)
                == SyntaxHighlightCoordinator.themeColor(for: "comment", theme: SyntaxHighlighting.theme)
        }
        XCTAssertTrue((mounted.editor.text ?? "").hasPrefix("// fresh\n"))
    }

    func testCompositionFinalReplacementKeepsParserAndCurrentColors() async throws {
        let source = "// comment 中文 👋\nlet value = 42\n"
        let mounted = try mountedPlugin(source: source)
        defer { mounted.window.close() }
        try await wait { self.hasRenderingColor(mounted.editor) }
        let replaced = (source as NSString).range(of: "value")
        mounted.editor.setMarkedText("café", selectedRange: NSRange(location: 4, length: 0),
                                     replacementRange: replaced)
        mounted.editor.setMarkedText("cafe\u{301}", selectedRange: NSRange(location: 5, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
        mounted.editor.insertText("新值", replacementRange: mounted.editor.markedRange())
        let expected = source.replacingOccurrences(of: "value", with: "新值")
        XCTAssertEqual(Data((mounted.editor.text ?? "").utf8), Data(expected.utf8))
        let actual = try await mounted.coordinator.tsClient.currentTree()
        let plugin = try XCTUnwrap(SyntaxHighlighting.plugin(for: "fixture.swift"))
        let parser = Parser()
        try parser.setLanguage(plugin.language.parser)
        let fresh = try XCTUnwrap(parser.parse(expected)?.rootNode)
        XCTAssertEqual(actual.rootNode?.sExpressionString, fresh.sExpressionString)
        XCTAssertEqual(actual.rootNode?.range, fresh.range)
        XCTAssertEqual(actual.rootNode?.pointRange, fresh.pointRange)
        let keyword = (expected as NSString).range(of: "let").location
        try await wait {
            self.color(mounted.editor, at: 0) == SyntaxHighlightCoordinator.themeColor(for: "comment", theme: plugin.theme)
                && self.color(mounted.editor, at: keyword) == SyntaxHighlightCoordinator.themeColor(for: "keyword", theme: plugin.theme)
        }
    }

    func testOldFailureIsNotDeliveredAfterNewEdit() async throws {
        let mounted = try mountedPlugin()
        defer { mounted.window.close() }
        try await wait { self.hasRenderingColor(mounted.editor) }
        let provider = try XCTUnwrap(mounted.coordinator.highlighter).tokenProvider
        let length = (mounted.editor.text ?? "").utf16.count
        let stale = expectation(description: "Old failure must not clear a newer pending request")
        stale.isInverted = true
        provider(NSRange(location: 0, length: length)) { _ in stale.fulfill() }
        mounted.editor.insertText("// current\n", replacementRange: NSRange(location: 0, length: 0))
        _ = try await mounted.coordinator.tsClient.currentTree()
        await fulfillment(of: [stale], timeout: 0.1)
        try await wait {
            self.color(mounted.editor, at: 0)
                == SyntaxHighlightCoordinator.themeColor(for: "comment", theme: SyntaxHighlighting.theme)
        }
    }

    func testInjectionReadCannotDeliverOldBaseAndCurrentViewportRecolors() async throws {
        let source = "```swift\n// embedded 中文 👋\nlet value = 42\n```\n"
        let mounted = try mountedPlugin(path: "fixture.md", source: source)
        defer { mounted.window.close() }
        let commentOffset = (source as NSString).range(of: "// embedded").location
        let expected = SyntaxHighlightCoordinator.themeColor(for: "comment", theme: SyntaxHighlighting.theme)
        try await wait { self.color(mounted.editor, at: commentOffset) == expected }
        let provider = try XCTUnwrap(mounted.coordinator.highlighter).tokenProvider
        let insertion = "prefix 中文 👋\n\n"
        var edited = false
        mounted.storage.onNextRead = {
            mounted.editor.insertText(insertion, replacementRange: NSRange(location: 0, length: 0))
            edited = true
        }
        var deliveries = 0
        provider(NSRange(location: 0, length: source.utf16.count)) { _ in deliveries += 1 }
        try await wait { edited }
        _ = try await mounted.coordinator.tsClient.currentTree()
        XCTAssertEqual(deliveries, 0)
        try await wait { self.color(mounted.editor, at: commentOffset + insertion.utf16.count) == expected }
        mounted.editor.breakUndoCoalescing()
        mounted.editor.undoManager?.undo()
        _ = try await mounted.coordinator.tsClient.currentTree()
        try await wait { self.color(mounted.editor, at: commentOffset) == expected }
        XCTAssertEqual(mounted.editor.text, source)
        mounted.editor.undoManager?.redo()
        _ = try await mounted.coordinator.tsClient.currentTree()
        try await wait { self.color(mounted.editor, at: commentOffset + insertion.utf16.count) == expected }
        XCTAssertEqual(mounted.editor.text, insertion + source)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testRealPluginTailDeleteAllDeleteAndQueuedEditsMatchFreshParserAndColors() async throws {
        let plugin = try XCTUnwrap(SyntaxHighlighting.plugin(for: "fixture.swift"))
        let editor = STTextView()
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.text = "// 中文 👋\r\nlet value = 42\n"
        var observed: SyntaxHighlightCoordinator?
        editor.addPlugin(ObservedSyntaxPlugin(plugin: plugin) { observed = $0 })
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        editor.frame = scroll.bounds
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scroll
        window.orderFront(nil)
        try await wait { observed != nil }
        let coordinator = try XCTUnwrap(observed)
        let parser = Parser()
        try parser.setLanguage(plugin.language.parser)
        func checkTree() async throws {
            let source = editor.text ?? ""
            let actual = try await coordinator.tsClient.currentTree()
            let expected = try XCTUnwrap(parser.parse(source)?.rootNode)
            XCTAssertEqual(actual.rootNode?.sExpressionString, expected.sExpressionString)
            XCTAssertEqual(actual.rootNode?.range, expected.range)
            XCTAssertEqual(actual.rootNode?.pointRange, expected.pointRange)
        }
        try await checkTree()
        editor.insertText("// prepended\n", replacementRange: NSRange(location: 0, length: 0))
        try await checkTree()
        let length = (editor.text ?? "").utf16.count
        editor.insertText("", replacementRange: NSRange(location: length - 8, length: 8))
        try await checkTree()
        editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.text ?? "").utf16.count))
        try await checkTree()
        for iteration in 0..<8 {
            editor.insertText("// \(iteration) " + String(repeating: "a", count: 2048) + "\r\n",
                              replacementRange: NSRange(location: 0, length: 0))
        }
        let final = "// final 中文 👋\nlet value = 42\n"
        editor.insertText(final, replacementRange: NSRange(location: 0, length: (editor.text ?? "").utf16.count))
        try await checkTree()
        let keyword = (final as NSString).range(of: "let").location
        func color(at offset: Int) -> NSColor? {
            var found: NSColor?
            editor.textLayoutManager.enumerateRenderingAttributes(
                from: editor.textContentManager.documentRange.location, reverse: false
            ) { _, attributes, range in
                if NSLocationInRange(offset, NSRange(range, in: editor.textContentManager)) {
                    found = attributes[.foregroundColor] as? NSColor
                    return false
                }
                return true
            }
            return found
        }
        try await wait {
            scroll.layoutSubtreeIfNeeded()
            editor.layoutSubtreeIfNeeded()
            return color(at: 0) == SyntaxHighlightCoordinator.themeColor(for: "comment", theme: plugin.theme)
                && color(at: keyword) == SyntaxHighlightCoordinator.themeColor(for: "keyword", theme: plugin.theme)
        }
        XCTAssertEqual(editor.text, final)
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
