import AppKit
import Neon
import SwiftUI
import SwiftTreeSitter
import TreeSitterClient
import XCTest
@testable import Bailey

private final class ReadInterceptingContentStorage: NSTextContentStorage {
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

@MainActor
final class NativeSyntaxHighlightingTests: XCTestCase {
    func testEmbeddedRequestsStayWithinRequestedRangeAndMatchFreshCaptures() async throws {
        let cases = [
            ("fixture.md", "```swift\n", "// 中文 👋 e\u{301}\nlet value = 42\n", "```\n", "fixture.swift", "//"),
            ("fixture.md", "```swift\r\n", "// 中文 👋 e\u{301}\r\nlet value = 42\r\n", "```\r\n", "fixture.swift", "//"),
            ("fixture.md", "```tsx\n", "// 中文 👋 e\u{301}\nconst view = <main/>;\n", "```\n", "fixture.tsx", "//"),
            ("fixture.html", "<script>\n", "// 中文 👋 e\u{301}\nconst value = 42;\n", "</script>\n", "fixture.js", "//"),
            ("fixture.html", "<style>\n", "/* 中文 👋 e\u{301} */\nbody { color: red; }\n", "</style>\n", "fixture.css", "/*")
        ]
        for (path, prefix, fragment, suffix, childPath, marker) in cases {
            let mounted = try mountedPlugin(path: path, source: prefix + fragment + suffix)
            defer { mounted.window.close() }
            let child = try XCTUnwrap(SyntaxHighlighting.language(for: childPath))
            let queryResult = await HighlightQueryCache.shared.query(
                for: child, data: SyntaxHighlighting.highlightsData(for: child)
            )
            let query = try XCTUnwrap(queryResult)
            let parser = Parser()
            try parser.setLanguage(child.parser)
            let tree = try XCTUnwrap(parser.parse(fragment))
            let root = try XCTUnwrap(tree.rootNode)
            let local = (fragment as NSString).range(of: marker).location
            let captures = query.execute(node: root, in: tree)
                .resolve(with: SwiftTreeSitter.Predicate.Context(string: fragment)).highlights()
            let expected = captures.filter {
                NSLocationInRange(local, $0.range) && !SyntaxHighlightCoordinator.ignoredCaptures.contains($0.name)
            }.last.flatMap { SyntaxHighlightCoordinator.themeColor(for: $0.name, theme: SyntaxHighlighting.theme) }
            XCTAssertNotNil(expected, childPath)
            let offset = prefix.utf16.count + local
            try await wait { self.color(mounted.editor, at: offset) == expected }
            let range = NSRange(location: offset, length: 2)
            let ready = expectation(description: "Current fragment matches fresh parser: \(childPath)")
            try XCTUnwrap(mounted.coordinator.highlighter).tokenProvider(range) { result in
                switch result {
                case .failure(let error): XCTFail(error.localizedDescription)
                case .success(let application):
                    var color: NSColor?
                    for token in application.tokens {
                        XCTAssertEqual(NSIntersectionRange(token.range, range), token.range, childPath)
                        if NSLocationInRange(offset, token.range)
                            && !SyntaxHighlightCoordinator.ignoredCaptures.contains(token.name) {
                            color = SyntaxHighlightCoordinator.themeColor(for: token.name, theme: SyntaxHighlighting.theme)
                        }
                    }
                    XCTAssertEqual(color, expected, childPath)
                }
                ready.fulfill()
            }
            await fulfillment(of: [ready], timeout: 5)
            XCTAssertEqual(Data((mounted.editor.text ?? "").utf8), Data((prefix + fragment + suffix).utf8))
        }
    }

    func testEmbeddedSameLengthEditLanguageRemovalAndUndoKeepCurrentColors() async throws {
        let source = "```swift\n// note\n```\n\n```swift\n// next\n```\n"
        let mounted = try mountedPlugin(path: "fixture.md", source: source)
        defer { mounted.window.close() }
        let first = (source as NSString).range(of: "// note").location
        let second = (source as NSString).range(of: "// next").location
        let comment = SyntaxHighlightCoordinator.themeColor(for: "comment", theme: SyntaxHighlighting.theme)
        let keyword = SyntaxHighlightCoordinator.themeColor(for: "keyword", theme: SyntaxHighlighting.theme)
        try await wait {
            self.color(mounted.editor, at: first) == comment && self.color(mounted.editor, at: second) == comment
        }
        mounted.editor.insertText("let n=1", replacementRange: NSRange(location: first, length: 7))
        try await wait {
            self.color(mounted.editor, at: first) == keyword && self.color(mounted.editor, at: second) == comment
        }
        mounted.editor.breakUndoCoalescing()
        mounted.editor.undoManager?.undo()
        try await wait { self.color(mounted.editor, at: first) == comment }
        XCTAssertEqual(Data((mounted.editor.text ?? "").utf8), Data(source.utf8))
        let language = (source as NSString).range(of: "swift")
        mounted.editor.insertText("xxxxx", replacementRange: language)
        let plain = SyntaxHighlightCoordinator.themeColor(for: "text.literal", theme: SyntaxHighlighting.theme)
        XCTAssertNotEqual(plain, comment)
        try await wait {
            self.color(mounted.editor, at: first) == plain && self.color(mounted.editor, at: second) == comment
        }
        mounted.editor.breakUndoCoalescing()
        mounted.editor.undoManager?.undo()
        try await wait { self.color(mounted.editor, at: first) == comment }
        let blockEnd = NSMaxRange((source as NSString).range(of: "```\n\n"))
        mounted.editor.insertText("// note\n\n", replacementRange: NSRange(location: 0, length: blockEnd))
        let remaining = try XCTUnwrap(mounted.editor.text)
        let next = (remaining as NSString).range(of: "// next").location
        try await wait {
            self.color(mounted.editor, at: 0) == nil && self.color(mounted.editor, at: next) == comment
        }
        mounted.editor.breakUndoCoalescing()
        mounted.editor.undoManager?.undo()
        try await wait { self.color(mounted.editor, at: first) == comment }
        XCTAssertEqual(Data((mounted.editor.text ?? "").utf8), Data(source.utf8))
        mounted.editor.insertText("", replacementRange: NSRange(location: 0, length: (mounted.editor.text ?? "").utf16.count))
        let tree = try await mounted.coordinator.tsClient.currentTree()
        XCTAssertEqual(tree.rootNode?.range.length, 0)
        XCTAssertEqual(mounted.editor.text, "")
    }

    func testClosingEmbeddedEditorReleasesPendingHighlightRequests() async throws {
        weak var editor: NativeCodeTextView?
        weak var coordinator: SyntaxHighlightCoordinator?
        func startAndClose() async throws {
            let source = "```swift\n" + String(repeating: "// 中文 👋\nlet value = 42\n", count: 2048) + "```\n"
            let mounted = try autoreleasepool { try mountedPlugin(path: "fixture.md", source: source) }
            editor = mounted.editor
            coordinator = mounted.coordinator
            _ = try await mounted.coordinator.tsClient.currentTree()
            try XCTUnwrap(mounted.coordinator.highlighter).tokenProvider(NSRange(location: 0, length: 1024)) { _ in }
            mounted.window.contentView = nil
            mounted.window.close()
        }
        try await startAndClose()
        try await wait { editor == nil && coordinator == nil }
    }

    func testClosingFirstEditorDoesNotPreventSecondEditorAndDiffColors() async throws {
        let source = "package main\n// shared 中文 👋\nfunc main() {}\n"
        func openThenClose() async throws {
            let first = try mountedPlugin(path: "first.go", source: source)
            await Task.yield()
            first.window.contentView = nil
            first.window.close()
        }
        try await openThenClose()
        let second = try mountedPlugin(path: "second.go", source: source)
        defer { second.window.close() }
        let contextResult = await DiffSyntaxHighlighter.context(for: "second.go")
        let context = try XCTUnwrap(contextResult)
        let comment = (source as NSString).range(of: "// shared").location
        let expected = SyntaxHighlightCoordinator.themeColor(for: "comment", theme: SyntaxHighlighting.theme)
        XCTAssertNotNil(expected)
        try await wait { self.color(second.editor, at: comment) == expected }
        let captures = await Task.detached {
            DiffSyntaxHighlighter.captures(text: source, context: context)
        }.value
        let colors = DiffSyntaxHighlighter.colors(for: captures)
        XCTAssertTrue(colors.contains { NSLocationInRange(comment, $0.range) && $0.color == expected })
    }

    func testThemeCapturesMatchBundledPaletteAcrossAppearances() throws {
        let bundle = Bundle.main
        let names = ["plain", "boolean", "comment", "constructor", "function.call", "include",
                     "keyword", "keyword.function", "keyword.return", "method", "number", "operator",
                     "parameter", "punctuation.special", "string", "text.literal", "text.title",
                     "type", "variable.builtin", "variable"]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for token in names {
                    let expected = NSColor(named: "neon.plugin.default/\(token)", bundle: bundle)
                    let actual = SyntaxHighlightCoordinator.themeColor(for: token, theme: SyntaxHighlighting.theme)
                    XCTAssertNotNil(expected, "\(name.rawValue) \(token)")
                    XCTAssertEqual(actual?.usingColorSpace(.deviceRGB), expected?.usingColorSpace(.deviceRGB))
                }
                for (capture, token) in [("tag", "constructor"), ("attribute", "method"),
                                         ("variable.parameter", "variable"), ("unknown.capture", "plain")] {
                    XCTAssertEqual(
                        SyntaxHighlightCoordinator.themeColor(for: capture, theme: SyntaxHighlighting.theme)?
                            .usingColorSpace(.deviceRGB),
                        NSColor(named: "neon.plugin.default/\(token)", bundle: bundle)?.usingColorSpace(.deviceRGB)
                    )
                }
            }
        }
    }

    func testClosingEditorDuringQueuedParsingReleasesItsContent() async throws {
        weak var editor: NativeCodeTextView?
        weak var coordinator: SyntaxHighlightCoordinator?
        try autoreleasepool {
            let mounted = try mountedPlugin()
            editor = mounted.editor
            coordinator = mounted.coordinator
            for iteration in 0..<8 {
                mounted.editor.insertText("// \(iteration) 中文 👋\n",
                                          replacementRange: NSRange(location: 0, length: 0))
            }
            mounted.editor.insertText(String(repeating: "// pasted\n", count: 4096),
                                      replacementRange: NSRange(location: 0, length: 0))
            mounted.window.contentView = nil
            mounted.window.close()
        }
        try await wait { editor == nil && coordinator == nil }
    }

    func testQueuedSemanticEditAndEarlierInsertionRecolorCurrentViewport() async throws {
        let prefix = "/*\n" + String(repeating: String(repeating: "a", count: 64) + "\n", count: 16384) + "*/\n"
        let source = prefix + "func target() {}\n"
        let mounted = try mountedPlugin(source: source)
        defer { mounted.window.close() }
        let highlighter = try XCTUnwrap(mounted.coordinator.highlighter)
        let requestLimit = highlighter.requestLengthLimit
        highlighter.requestLengthLimit = source.utf16.count + 16384
        highlighter.invalidate()
        _ = try await mounted.coordinator.tsClient.currentTree()
        let oldName = (source as NSString).range(of: "target").location
        mounted.editor.scrollRangeToVisible(NSRange(location: oldName, length: 6))
        let declarationColor = SyntaxHighlightCoordinator.themeColor(for: "method", theme: SyntaxHighlighting.theme)
        try await wait {
            guard let viewport = mounted.editor.nativeLayoutManager.textViewportLayoutController.viewportRange else { return false }
            return NSLocationInRange(oldName, NSRange(viewport, in: mounted.editor.nativeContentManager))
                && self.color(mounted.editor, at: oldName) == declarationColor
        }
        let provider = highlighter.tokenProvider
        var requests = 0
        highlighter.tokenProvider = { range, completion in
            requests += 1
            provider(range) { result in
                completion(result)
                requests -= 1
            }
        }
        highlighter.invalidate()
        try await wait { requests == 0 && self.color(mounted.editor, at: oldName) == declarationColor }
        highlighter.tokenProvider = provider
        highlighter.requestLengthLimit = requestLimit

        mounted.editor.insertText("", replacementRange: NSRange(location: prefix.utf16.count, length: 5))
        let inserted = String(repeating: "a", count: 8192)
        mounted.editor.insertText(inserted, replacementRange: NSRange(location: 100, length: 0))
        let text = try XCTUnwrap(mounted.editor.text)
        let currentName = (text as NSString).range(of: "target").location
        let tree = try await mounted.coordinator.tsClient.currentTree()
        let plugin = try XCTUnwrap(SyntaxHighlighting.configuration(for: "fixture.swift"))
        let parser = Parser()
        try parser.setLanguage(plugin.language.parser)
        let fresh = try XCTUnwrap(parser.parse(text)?.rootNode)
        XCTAssertEqual(tree.rootNode?.sExpressionString, fresh.sExpressionString)
        XCTAssertEqual(tree.rootNode?.range, fresh.range)

        let queried = expectation(description: "Actual current provider resolves the call color")
        var expected: NSColor?
        provider(NSRange(location: currentName, length: 6)) { result in
            switch result {
            case .failure(let error): XCTFail(error.localizedDescription)
            case .success(let application):
                for token in application.tokens where NSLocationInRange(currentName, token.range)
                    && !SyntaxHighlightCoordinator.ignoredCaptures.contains(token.name) {
                    expected = SyntaxHighlightCoordinator.themeColor(for: token.name, theme: plugin.theme)
                }
            }
            queried.fulfill()
        }
        await fulfillment(of: [queried], timeout: 5)
        XCTAssertEqual(expected, SyntaxHighlightCoordinator.themeColor(for: "function.call", theme: plugin.theme))
        XCTAssertNotEqual(expected, declarationColor)
        do {
            try await wait { self.color(mounted.editor, at: currentName) == expected }
        } catch {
            XCTFail("Current tree/provider resolve the new call, but viewport color is \(String(describing: self.color(mounted.editor, at: currentName))); expected \(String(describing: expected))")
        }
    }

    func testParserReadsAcrossUTF16ChunkBoundariesAndEditShift() async throws {
        let plugin = try XCTUnwrap(SyntaxHighlighting.configuration(for: "fixture.swift"))
        let parser = Parser()
        try parser.setLanguage(plugin.language.parser)
        for prefixLength in [1022, 1023, 2047] {
            for boundary in ["👋", "e\u{301}", "\r\n", "👨‍👩‍👧‍👦"] {
                let source = "//" + String(repeating: "a", count: prefixLength - 2)
                    + boundary + "\nlet value = \"完整\"\n"
                let mounted = try mountedPlugin(source: source)
                defer { mounted.window.close() }
                for insertion in ["", " "] {
                    if !insertion.isEmpty {
                        mounted.editor.insertText(insertion, replacementRange: NSRange(location: 0, length: 0))
                    }
                    let text = insertion + source
                    let actualText = try XCTUnwrap(mounted.editor.text)
                    XCTAssertEqual(Data(actualText.utf8), Data(text.utf8))
                    for snapshot in [text, actualText] {
                        let expectedBytes = try XCTUnwrap(snapshot.data(using: .utf16LittleEndian))
                        let reader = Parser.readFunction(for: snapshot)
                        var bytes = Data()
                        while let chunk = reader(bytes.count, .zero), !chunk.isEmpty {
                            bytes.append(chunk)
                            if bytes.count > expectedBytes.count { break }
                        }
                        XCTAssertEqual(bytes, expectedBytes, "\(prefixLength) \(boundary.debugDescription)")
                    }
                    let actual = try await mounted.coordinator.tsClient.currentTree()
                    let expected = try XCTUnwrap(parser.parse(text)?.rootNode)
                    XCTAssertEqual(actual.rootNode?.range, expected.range, "\(prefixLength) \(boundary.debugDescription) \(insertion.debugDescription)")
                    XCTAssertEqual(actual.rootNode?.pointRange, expected.pointRange)
                    XCTAssertEqual(actual.rootNode?.sExpressionString, expected.sExpressionString)
                    guard actual.rootNode?.range == expected.range else { continue }
                    let keyword = (text as NSString).range(of: "let").location
                    try await wait {
                        self.color(mounted.editor, at: keyword)
                            == SyntaxHighlightCoordinator.themeColor(for: "keyword", theme: plugin.theme)
                    }
                }
            }
        }
    }

    func testFourSizeRealFileTabHighlightedInputAndParserBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-audit-editor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for rows in [382, 1_000, 10_000, 100_000] {
            // Preserve T1's mixed length, blank row, Unicode and long-row fixture.
            let lines = (0..<rows).map { row in
                switch row % 5 {
                case 0: "struct Item\(row) {"
                case 1: "    let title = \"中文 👋 e\u{301}\" // a fairly realistic code line"
                case 2: "    let value = 1234567890 // " + String(repeating: "wide", count: row % 31)
                case 3: "}"
                default: ""
                }
            }
            let source = lines.joined(separator: "\n")
            let midpointRow = (rows / 2) / 5 * 5
            let midpoint = (source as NSString).range(of: "struct Item\(midpointRow) {").location
            XCTAssertNotEqual(midpoint, NSNotFound)
            for wraps in [false, true] {
                let url = directory.appendingPathComponent("fixture-\(rows)-\(wraps).swift")
                try Data(source.utf8).write(to: url)
                let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared,
                                   workspaceIdentity: nil)
                try await file.waitForText()
                file.autoSaveSuspendedForClose = true
                let host = NSHostingView(rootView: SourceTextEditor(
                    file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    palette: .theme(dark: true), wrapLines: wraps, isFocused: false
                ))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                window.orderFront(nil)
                let deadline = Date().addingTimeInterval(12)
                while file.editorView == nil, Date() < deadline {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                }
                let editor = try XCTUnwrap((file.editorView as? NSScrollView)?.documentView as? NativeCodeTextView)
                let syntax = try XCTUnwrap(editor.syntaxCoordinator)
                let initialTree = try await syntax.tsClient.currentTree()
                XCTAssertEqual(initialTree.rootNode?.range.length, source.utf16.count)
                for (label, offset) in [("head", 0), ("middle", midpoint), ("tail", source.utf16.count)] {
                    editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
                    host.layoutSubtreeIfNeeded()
                    var costs: [Double] = []
                    for _ in 0..<30 {
                        let started = CFAbsoluteTimeGetCurrent()
                        editor.insertText("X", replacementRange: NSRange(location: offset, length: 0))
                        costs.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                        editor.insertText("", replacementRange: NSRange(location: offset, length: 1))
                    }
                    XCTAssertEqual(editor.text, source, "\(rows) rows \(wraps) \(label)")
                    XCTAssertEqual(file.text, source, "Real FileTab must match the native buffer")
                    costs.sort()
                    print("AUDIT_P1_HIGHLIGHT_INPUT rows=\(rows) wraps=\(wraps) position=\(label) median=\(costs[15]) p95=\(costs[28]) worst=\(costs[29])")
                    if rows == 100_000 {
                        XCTAssertLessThanOrEqual(costs[15], 16, "Real highlighted input median must meet P1 budget")
                        XCTAssertLessThanOrEqual(costs[28], 32, "Real highlighted input p95 must meet P1 budget")
                    }
                }
                let currentTree = try await syntax.tsClient.currentTree()
                XCTAssertEqual(currentTree.rootNode?.range.length, source.utf16.count)
                XCTAssertFalse(file.isDirty)
            }
        }
    }

    private func mountedPlugin(
        path: String = "fixture.swift", source: String = "let value = Capitalized.method()\n"
    ) throws -> (
        window: NSWindow, editor: NativeCodeTextView, coordinator: SyntaxHighlightCoordinator,
        storage: ReadInterceptingContentStorage
    ) {
        let plugin = try XCTUnwrap(SyntaxHighlighting.configuration(for: path))
        let storage = ReadInterceptingContentStorage()
        storage.textStorage = NSTextStorage()
        let editor = NativeCodeTextView(contentStorage: storage)
        editor.text = source
        editor.installSyntaxHighlighting(plugin)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        editor.frame = scroll.bounds
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        return (window, editor, try XCTUnwrap(editor.syntaxCoordinator), storage)
    }

    private func hasRenderingColor(_ editor: NativeCodeTextView) -> Bool {
        var colored = false
        editor.layoutSubtreeIfNeeded()
        editor.nativeLayoutManager.enumerateRenderingAttributes(
            from: editor.nativeContentManager.documentRange.location, reverse: false
        ) { _, attributes, _ in
            colored = attributes[.foregroundColor] != nil
            return !colored
        }
        return colored
    }

    private func color(_ editor: NativeCodeTextView, at offset: Int) -> NSColor? {
        var found: NSColor?
        editor.layoutSubtreeIfNeeded()
        editor.nativeLayoutManager.enumerateRenderingAttributes(
            from: editor.nativeContentManager.documentRange.location, reverse: false
        ) { _, attributes, range in
            if NSLocationInRange(offset, NSRange(range, in: editor.nativeContentManager)) {
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
        let plugin = try XCTUnwrap(SyntaxHighlighting.configuration(for: "fixture.swift"))
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

    func testEmbeddedQueryReadyDropsInFlightEarlierTokens() async throws {
        let source = "```swift\n// embedded 中文 👋\nlet value = 42\n```\n"
        let mounted = try mountedPlugin(path: "fixture.md", source: source)
        defer { mounted.window.close() }
        let marker = (source as NSString).range(of: "// embedded").location
        let expected = SyntaxHighlightCoordinator.themeColor(for: "comment", theme: SyntaxHighlighting.theme)
        try await wait { self.color(mounted.editor, at: marker) == expected }
        let provider = try XCTUnwrap(mounted.coordinator.highlighter).tokenProvider
        var oldDeliveries = 0
        var queryBecameReady = false
        mounted.storage.onNextRead = {
            queryBecameReady = true
            mounted.coordinator.injectedQueryBecameAvailable()
        }
        let range = NSRange(location: 0, length: source.utf16.count)
        provider(range) { _ in oldDeliveries += 1 }
        try await wait { queryBecameReady }
        _ = try await mounted.coordinator.tsClient.currentTree()
        XCTAssertEqual(oldDeliveries, 0, "A superseded highlight request must not apply tokens")
        let current = expectation(description: "New query state completes the current request")
        provider(range) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            current.fulfill()
        }
        await fulfillment(of: [current], timeout: 5)
        try await wait { self.color(mounted.editor, at: marker) == expected }
        XCTAssertEqual(Data((mounted.editor.text ?? "").utf8), Data(source.utf8))
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
        let plugin = try XCTUnwrap(SyntaxHighlighting.configuration(for: "fixture.swift"))
        let editor = NativeCodeTextView()
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.text = "// 中文 👋\r\nlet value = 42\n"
        editor.installSyntaxHighlighting(plugin)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        editor.frame = scroll.bounds
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scroll
        window.orderFront(nil)
        let coordinator = try XCTUnwrap(editor.syntaxCoordinator)
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
            editor.nativeLayoutManager.enumerateRenderingAttributes(
                from: editor.nativeContentManager.documentRange.location, reverse: false
            ) { _, attributes, range in
                if NSLocationInRange(offset, NSRange(range, in: editor.nativeContentManager)) {
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
        let editor = try XCTUnwrap(scroll.documentView as? NativeCodeTextView)
        var commentColor: NSColor?
        try await wait {
            host.layoutSubtreeIfNeeded()
            var colors = 0
            editor.nativeLayoutManager.enumerateRenderingAttributes(
                from: editor.nativeContentManager.documentRange.location, reverse: false
            ) { _, attributes, range in
                if let color = attributes[.foregroundColor] as? NSColor {
                    colors += 1
                    if NSRange(range, in: editor.nativeContentManager).location == 0 { commentColor = color }
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
        let document = try XCTUnwrap(editor.nativeContentManager.attributedString(in: nil))
        document.enumerateAttribute(.font, in: NSRange(location: 0, length: document.length)) { value, _, _ in
            XCTAssertEqual(value as? NSFont, changedFont)
        }
        XCTAssertEqual(editor.text, source)
        XCTAssertFalse(file.isDirty)
        XCTAssertFalse(editor.undoManager?.canUndo ?? false)
    }

    func testSelectedCompositionFlowsIntoActualFileBytesAndUndo() async throws {
        for finishWithInsert in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("source.swift")
            let source = "before 👋after\r\n"
            try Data(source.utf8).write(to: url)
            let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await file.waitForText()
            file.autoSaveSuspendedForClose = true
            let host = NSHostingView(rootView: SourceTextEditor(file: file,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                palette: .theme(dark: true), wrapLines: false, isFocused: false))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            let editor = try XCTUnwrap((file.editorView as? NSScrollView)?.documentView as? NativeCodeTextView)
            let selection = (source as NSString).range(of: "after")
            editor.textSelection = selection
            editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: .notFound)
            if finishWithInsert {
                editor.insertText("完成", replacementRange: .notFound)
            } else {
                editor.unmarkText()
            }
            let expected = source.replacingOccurrences(of: "after", with: finishWithInsert ? "完成" : "中文")
            XCTAssertEqual(Data(file.text.utf8), Data(expected.utf8))
            XCTAssertTrue(file.isDirty)
            await file.save()
            XCTAssertEqual(try Data(contentsOf: url), Data(expected.utf8))
            XCTAssertFalse(file.isDirty)
            editor.undoManager?.undo()
            XCTAssertEqual(Data(file.text.utf8), Data(source.utf8))
            XCTAssertTrue(file.isDirty)
            await file.save()
            XCTAssertEqual(try Data(contentsOf: url), Data(source.utf8))
            XCTAssertFalse(file.isDirty)
        }
    }

    func testRepeatedGrammarSwitchReleasesPriorCoordinators() async throws {
        let editor = FocusReportingTextView()
        editor.text = "# Heading\n```swift\nlet value = 42\n```\n"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = editor
        window.orderFront(nil)
        editor.updateSyntaxHighlighting(for: "before.swift")
        do {
            let first = try XCTUnwrap(editor.syntaxCoordinator)
            editor.updateSyntaxHighlighting(for: "same.swift")
            XCTAssertTrue(editor.syntaxCoordinator === first)
        }
        for index in 0..<24 {
            weak var previous = editor.syntaxCoordinator
            let path = ["file.md", "file.html", "file.txt", "file.swift"][index % 4]
            editor.updateSyntaxHighlighting(for: path)
            try await wait { previous == nil }
            if path.hasSuffix(".txt") {
                XCTAssertNil(editor.syntaxCoordinator)
            } else {
                XCTAssertNotNil(editor.syntaxCoordinator)
            }
        }
        XCTAssertEqual(editor.text, "# Heading\n```swift\nlet value = 42\n```\n")
    }

    func testRenamingMountedFileChangesGrammarWithoutDiscardingUndo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("source.swift")
        let renamed = folder.appendingPathComponent("source.md")
        let source = "# Heading\n\nlet value = 42\n"
        try Data(source.utf8).write(to: original)
        let file = FileTab(path: original.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
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
        let editor = try XCTUnwrap(scroll.documentView as? NativeCodeTextView)
        let heading = (source as NSString).range(of: "Heading").location
        let markdownColor = try XCTUnwrap(SyntaxHighlightCoordinator.themeColor(
            for: "text.title", theme: SyntaxHighlighting.theme))
        XCTAssertNotEqual(self.color(editor, at: heading), markdownColor)
        editor.insertText("// unsaved\n", replacementRange: NSRange(location: source.utf16.count, length: 0))
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        try FileManager.default.moveItem(at: original, to: renamed)
        file.updatePath(renamed.path)
        host.rootView = SourceTextEditor(file: file, font: font,
            palette: .theme(dark: true), wrapLines: false, isFocused: false)
        try await wait { self.color(editor, at: heading) == markdownColor }
        let unsupported = folder.appendingPathComponent("source.txt")
        try FileManager.default.moveItem(at: renamed, to: unsupported)
        file.updatePath(unsupported.path)
        try await wait { self.color(editor, at: heading) == nil }
        try FileManager.default.moveItem(at: unsupported, to: original)
        file.updatePath(original.path)
        let keyword = (source as NSString).range(of: "let").location
        let keywordColor = try XCTUnwrap(SyntaxHighlightCoordinator.themeColor(
            for: "keyword", theme: SyntaxHighlighting.theme))
        try await wait { self.color(editor, at: keyword) == keywordColor }
        XCTAssertTrue((file.editorView as? NSScrollView)?.documentView === editor)
        XCTAssertTrue(editor.undoManager === undo)
        undo.undo()
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(source.utf8))
        XCTAssertFalse(file.isDirty)
    }

    func testRapidNativeUnicodeReplacementsKeepParserAndBytesAligned() async throws {
        let plugin = try XCTUnwrap(SyntaxHighlighting.configuration(for: "fixture.swift"))
        let parser = Parser()
        try parser.setLanguage(plugin.language.parser)
        var source = "// 中文 👋 e\u{301}\r\nlet value = 42\n"
        let mounted = try mountedPlugin(source: source)
        defer { mounted.window.close() }
        var seed: UInt64 = 0x7E57A113
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(bound))
        }
        let replacements = ["", "A", "\n", "\r\n", "👋", "中文", "e\u{301}", "/*", "*/", "let", "{ }", "\u{2028}"]
        for edit in 0..<160 {
            var boundaries = [0]
            for character in source { boundaries.append(boundaries.last! + character.utf16.count) }
            let first = next(boundaries.count)
            let last = first + next(boundaries.count - first)
            let range = NSRange(location: boundaries[first], length: boundaries[last] - boundaries[first])
            let replacement = replacements[next(replacements.count)]
            mounted.editor.insertText(replacement, replacementRange: range)
            source = (source as NSString).replacingCharacters(in: range, with: replacement)
            XCTAssertEqual(Data((mounted.editor.text ?? "").utf8), Data(source.utf8), "edit \(edit)")
            if edit % 16 == 0 || edit == 159 {
                let actual = try await mounted.coordinator.tsClient.currentTree()
                let fresh = try XCTUnwrap(parser.parse(source)?.rootNode)
                XCTAssertEqual(actual.rootNode?.range, fresh.range, "edit \(edit)")
                XCTAssertEqual(actual.rootNode?.pointRange, fresh.pointRange, "edit \(edit)")
                XCTAssertEqual(actual.rootNode?.sExpressionString, fresh.sExpressionString, "edit \(edit)")
            }
        }
    }

    func testAtomicMultiCursorUnicodeEditAndUndoKeepParserAndNativeStorageAligned() async throws {
        let plugin = try XCTUnwrap(SyntaxHighlighting.configuration(for: "fixture.swift"))
        let parser = Parser()
        try parser.setLanguage(plugin.language.parser)
        let original = "// 中文 👋\nlet first = 1\nlet second = 2\n"
        let edited = "// 中文 👋\nlet 标志 = 1\nlet 标志 = 2\n"
        let mounted = try mountedPlugin(source: original)
        defer { mounted.window.close() }
        let old = original as NSString
        mounted.editor.selectedRanges = [
            NSValue(range: old.range(of: "first")),
            NSValue(range: old.range(of: "second"))
        ]
        mounted.editor.insertText("标志", replacementRange: .notFound)
        XCTAssertEqual(Data((mounted.editor.text ?? "").utf8), Data(edited.utf8))
        let changed = try await mounted.coordinator.tsClient.currentTree()
        let freshlyParsed = try XCTUnwrap(parser.parse(edited)?.rootNode)
        XCTAssertEqual(changed.rootNode?.sExpressionString, freshlyParsed.sExpressionString)
        XCTAssertEqual(changed.rootNode?.range, freshlyParsed.range)
        XCTAssertEqual(changed.rootNode?.pointRange, freshlyParsed.pointRange)
        mounted.editor.undoManager?.undo()
        XCTAssertEqual(Data((mounted.editor.text ?? "").utf8), Data(original.utf8))
        let restored = try await mounted.coordinator.tsClient.currentTree()
        let freshOriginal = try XCTUnwrap(parser.parse(original)?.rootNode)
        XCTAssertEqual(restored.rootNode?.sExpressionString, freshOriginal.sExpressionString)
        mounted.editor.undoManager?.redo()
        XCTAssertEqual(Data((mounted.editor.text ?? "").utf8), Data(edited.utf8))
        let redone = try await mounted.coordinator.tsClient.currentTree()
        XCTAssertEqual(redone.rootNode?.sExpressionString, freshlyParsed.sExpressionString)
    }

    func testProductionTransformerMatchesUTF16ParserPoints() async throws {
        for source in ["", "let value = 1", "// 中文 👋\r\nlet value = 1\n", "// a\rb\u{2028}c\u{2029}d\n", "\n"] {
            let view = NativeCodeTextView()
            view.text = source
            let plugin = try XCTUnwrap(SyntaxHighlighting.configuration(for: "fixture.swift"))
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
