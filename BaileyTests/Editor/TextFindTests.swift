import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
final class TextFindTests: XCTestCase {
    private func withEditor(_ text: String, _ body: @MainActor (NativeCodeTextView, TextFind) async throws -> Void) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data(text.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let host = NSHostingView(rootView: FileViewerView(file: file, isFocused: false))
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 600, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
            file.retireContent()
        }
        try await settle {
            host.layoutSubtreeIfNeeded()
            return file.textView != nil
        }
        let editor = try XCTUnwrap(file.textView)
        let find = file.textFind
        file.textFind.present()
        try await body(editor, find)
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "TextFindTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Find did not settle"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testRepeatedFindUsesCurrentSourceSelectionWithoutSeedingAutomaticMatches() async throws {
        let source = "alpha ALPHA beta a.b 中文👋\nnext line"
        try await withEditor(source) { editor, find in
            let window = try XCTUnwrap(editor.window)
            let text = source as NSString
            find.query = "ALPHA"
            try await settle { find.total == 2 }
            XCTAssertTrue(window.makeFirstResponder(editor))
            find.present()
            XCTAssertEqual(find.query, "ALPHA", "An automatic match must not replace the query")
            editor.textSelection = text.range(of: "beta")
            find.present()
            XCTAssertEqual(find.query, "beta")
            try await settle { find.total == 1 }
            find.present(replacing: true)
            find.options.regex = true
            try await settle { find.total == 1 }
            XCTAssertTrue(window.makeFirstResponder(editor))
            editor.textSelection = text.range(of: "a.b")
            find.present()
            XCTAssertEqual(find.query, NSRegularExpression.escapedPattern(for: "a.b"))
            XCTAssertTrue(find.showsReplace)
            try await settle { find.total == 1 }
            XCTAssertTrue(window.makeFirstResponder(editor))
            editor.textSelection = text.range(of: "中文👋")
            find.present()
            XCTAssertEqual(find.query, "中文👋")
            try await settle { find.total == 1 }
            XCTAssertTrue(window.makeFirstResponder(editor))
            editor.textSelection = NSRange(location: 0, length: 0)
            find.present()
            XCTAssertEqual(find.query, "中文👋")
            editor.textSelection = text.range(of: "👋\nnext")
            find.present()
            XCTAssertEqual(find.query, "中文👋", "Multiline selections do not seed the single-line input")
            let other = NSTextField(string: "")
            window.contentView?.addSubview(other)
            defer { other.removeFromSuperview() }
            XCTAssertTrue(window.makeFirstResponder(other))
            editor.textSelection = text.range(of: "beta")
            find.present()
            XCTAssertEqual(find.query, "中文👋", "A retained source selection must not override the input field")
            XCTAssertEqual(editor.string, source)
        }
    }

    func testFindWidgetFitsBothRowsAcrossNarrowAndWidePanes() async throws {
        try await withEditor("alpha ALPHA alpha\n") { editor, find in
            let window = try XCTUnwrap(editor.window)
            let host = try XCTUnwrap(window.contentView)
            find.query = "alpha"
            try await settle { find.total == 3 }
            find.present(replacing: true)
            let pid = ProcessInfo.processInfo.processIdentifier
            let access = await Task.detached {
                var windows: CFTypeRef?
                return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString,
                                                      &windows).rawValue
            }.value
            XCTAssertEqual(access, AXError.success.rawValue)
            @MainActor func attribute(_ node: NSObject, _ name: String) -> Any? {
                guard node.responds(to: NSSelectorFromString(name)) else { return nil }
                return node.value(forKey: name)
            }
            @MainActor func elements(_ node: NSObject) -> [NSObject] {
                let children = attribute(node, "accessibilityChildrenInNavigationOrder") as? [NSObject]
                    ?? attribute(node, "accessibilityChildren") as? [NSObject] ?? []
                return [node] + children.flatMap(elements)
            }
            @MainActor func controls() -> [String: CGRect] {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                var result: [String: CGRect] = [:]
                for node in (host.accessibilityChildren() as? [NSObject] ?? []).flatMap(elements) {
                    guard let id = attribute(node, "accessibilityIdentifier") as? String,
                          id.hasPrefix("bailey.find."),
                          let value = attribute(node, "accessibilityFrame") as? NSValue else { continue }
                    result[id] = window.convertFromScreen(value.rectValue)
                }
                return result
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for width in [150.0, 210, 246, 290, 326, 360, 600, 900] {
                    window.setContentSize(.init(width: width, height: 340))
                    try await settle {
                        abs(host.bounds.width - width) < 1 &&
                            controls()["bailey.find.replacement"] != nil
                    }
                    // Wait for the SwiftUI geometry update after changing the host size.
                    try await Task.sleep(for: .milliseconds(30))
                    let frames = controls()
                    let query = try XCTUnwrap(frames["bailey.find.query"])
                    let replacement = try XCTUnwrap(frames["bailey.find.replacement"])
                    let close = try XCTUnwrap(frames["bailey.find.close"])
                    let toggle = try XCTUnwrap(frames["bailey.find.replace-toggle"])
                    XCTAssertGreaterThan(query.width, 12, "width=\(width)")
                    XCTAssertGreaterThan(replacement.width, 12, "width=\(width)")
                    XCTAssertEqual(query.minX, replacement.minX, accuracy: 2)
                    XCTAssertLessThanOrEqual(close.maxX - toggle.minX, 355)
                    XCTAssertLessThanOrEqual(close.maxX, host.bounds.maxX + 1)
                    XCTAssertGreaterThanOrEqual(toggle.minX, -1)
                    for (id, frame) in frames {
                        XCTAssertGreaterThanOrEqual(frame.minX, -1, id)
                        XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX + 1, id)
                    }
                    let ids = ["replace-toggle", "query", "case", "word", "regex", "count",
                               "previous", "next", "selection", "close"]
                    let firstRow = ids.compactMap { frames["bailey.find." + $0] }
                    for (left, right) in zip(firstRow, firstRow.dropFirst()) {
                        XCTAssertLessThanOrEqual(left.maxX, right.minX + 1, "width=\(width)")
                    }
                    if width >= 360 {
                        for id in ids + ["preserve-case", "replace", "replace-all"] {
                            XCTAssertNotNil(frames["bailey.find." + id], "Missing \(id) at \(width)pt")
                        }
                    }
                }
            }
            XCTAssertEqual(editor.string, "alpha ALPHA alpha\n")
        }
    }

    func testCompressedIndexPreservesVariableAndZeroWidthRangesAcrossPages() throws {
        var index = TextFindMatchIndex()
        var expected: [NSRange] = []
        var end = 0
        for i in 0..<8_193 {
            let gap = i.isMultiple(of: 31) ? 16_385 : i % 7
            let length = i.isMultiple(of: 23) ? 129 : i % 5
            let match = NSRange(location: end + gap, length: length)
            index.append(match)
            expected.append(match)
            end = NSMaxRange(match)
        }
        XCTAssertEqual(index.count, expected.count)
        for i in expected.indices {
            XCTAssertEqual(index.range(at: i), expected[i])
        }
        XCTAssertNil(index.range(at: -1))
        XCTAssertNil(index.range(at: expected.count))
        for i in stride(from: 0, to: expected.count, by: 7) {
            let position = expected[i].location
            XCTAssertEqual(index.lowerBound(position), expected.firstIndex { $0.location >= position })
            let viewport = NSRange(location: max(0, position - 3), length: 100)
            let actual = Array(index.intersecting(viewport))
            let wanted = expected.filter {
                $0.location < NSMaxRange(viewport) &&
                    ($0.location >= viewport.location || NSMaxRange($0) > viewport.location)
            }
            XCTAssertEqual(actual, wanted)
        }
        XCTAssertLessThan(index.storageBytes, expected.count * MemoryLayout<NSRange>.stride / 4)
    }

    func testDenseIndexAtMaximumTextCapacity() {
        let capacity = FileTab.maxTextBytes
        var index = TextFindMatchIndex()
        let started = ContinuousClock.now
        for location in 0..<capacity { index.append(NSRange(location: location, length: 1)) }
        XCTAssertEqual(index.count, capacity)
        XCTAssertEqual(index.range(at: capacity - 1), NSRange(location: capacity - 1, length: 1))
        for step in 0..<100 {
            let position = capacity * step / 100
            XCTAssertEqual(index.lowerBound(position), position)
            XCTAssertEqual(index.range(at: position), NSRange(location: position, length: 1))
        }
        XCTAssertLessThan(index.storageBytes, capacity * 3)
        print("FIND_DENSE_INDEX count=\(index.count) bytes=\(index.storageBytes) elapsed=\(started.duration(to: .now))")
    }

    func testDenseMatchesRemainHighlightedAndNavigateBeyondTheOldCacheLimit() async throws {
        let count = 40_001
        let source = String(repeating: "a x\n", count: count)
        try await withEditor(source) { editor, find in
            find.query = "a"
            try await settle { find.total == count }
            let tail = NSRange(location: (count - 1) * 4, length: 1)
            XCTAssertEqual(Array(find.visibleMatches(in: tail)), [tail])
            editor.textSelection = tail
            find.navigate(forward: true)
            try await settle { find.current == 0 }
            XCTAssertEqual(editor.textSelection, NSRange(location: 0, length: 1))
            find.navigate(forward: false)
            try await settle { find.current == count - 1 }
            XCTAssertEqual(editor.textSelection, tail)
            XCTAssertEqual(Array(find.visibleMatches(in: tail)), [tail])
            find.dismiss()
            XCTAssertTrue(find.visibleMatches(in: tail).isEmpty)
            XCTAssertEqual(editor.string, source)
        }
    }

    private func renderedMatch(_ range: NSRange, editor: NativeCodeTextView) throws -> Data {
        let layout = editor.nativeLayoutManager
        let manager = editor.nativeContentManager
        let textRange = try XCTUnwrap(NSTextRange(range, in: manager))
        var frame: NSRect = .null
        layout.enumerateTextSegments(in: textRange, type: .standard, options: .rangeNotRequired) { _, rect, _, _ in
            frame = frame.union(rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y))
            return true
        }
        let box = frame.intersection(editor.visibleRect)
        XCTAssertFalse(box.isEmpty, "The test match must be rendered in the actual viewport")
        let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: box))
        editor.cacheDisplay(in: box, to: bitmap)
        return try XCTUnwrap(bitmap.tiffRepresentation)
    }

    func testDenseLongLineFindPaintsWithoutReflowOrExhaustingTheViewport() async throws {
        let settings = AppSettings.shared
        let previousWrap = settings.wrapLines
        let previousWidth = settings.longLineDisplayWidth
        settings.wrapLines = false
        settings.longLineDisplayWidth = .standard
        defer {
            settings.wrapLines = previousWrap
            settings.longLineDisplayWidth = previousWidth
        }
        let source = String(repeating: "a ", count: 40_001) + "\n"
        try await withEditor(source) { editor, find in
            editor.highlightSelectedLine = false
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            let geometry = scroll.contentView.bounds.size
            let match = NSRange(location: 40, length: 1)
            let before = try renderedMatch(match, editor: editor)
            find.query = "a"
            try await settle { find.total == 40_001 }
            let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            let start = ContinuousClock.now
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            let elapsed = start.duration(to: .now)
            print("FIND_DENSE_LONG_LINE matches=40001 draw=\(elapsed)")
            XCTAssertLessThan(elapsed, .milliseconds(250))
            XCTAssertNotEqual(try renderedMatch(match, editor: editor), before,
                              "Faster rendering must retain actual unselected match pixels")
            XCTAssertEqual(scroll.contentView.bounds.size, geometry)
            XCTAssertEqual(editor.string, source)
            let tail = NSRange(location: 80_000, length: 1)
            XCTAssertEqual(Array(find.visibleMatches(in: tail)), [tail])
            find.dismiss()
            XCTAssertEqual(try renderedMatch(match, editor: editor), before)
        }
    }

    func testLongBidirectionalLineHighlightsAfterHorizontalScroll() async throws {
        let settings = AppSettings.shared
        let previousWrap = settings.wrapLines
        let previousWidth = settings.longLineDisplayWidth
        settings.wrapLines = false
        settings.longLineDisplayWidth = .standard
        defer {
            settings.wrapLines = previousWrap
            settings.longLineDisplayWidth = previousWidth
        }
        let unit = "a אבג 漢字 "
        let source = String(repeating: unit, count: 5_001) + "\n"
        try await withEditor(source) { editor, find in
            editor.highlightSelectedLine = false
            let target = NSRange(location: unit.utf16.count * 100 + 2, length: 3)
            editor.scrollRangeToVisible(target)
            editor.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
            let before = try renderedMatch(target, editor: editor)
            find.query = "אבג"
            try await settle { find.total == 5_001 }
            editor.scrollRangeToVisible(target)
            editor.layoutSubtreeIfNeeded()
            XCTAssertNotEqual(try renderedMatch(target, editor: editor), before,
                              "Visible RTL glyphs must be highlighted after horizontal scrolling")
            find.dismiss()
            XCTAssertEqual(try renderedMatch(target, editor: editor), before)
            XCTAssertEqual(Data(editor.string.utf8), Data(source.utf8))
        }
    }

    func testCanceledReplaceAndReadOnlySurfaceNeverMutateTheDocument() async throws {
        let source = String(repeating: "alpha 中文👋\r\n", count: 30_000)
        try await withEditor(source) { editor, find in
            find.query = "alpha"
            try await settle { find.total == 30_000 }
            find.present(replacing: true)
            find.replacement = "beta"
            find.replace(all: true)
            find.query = "不存在"
            try await settle { find.total == 0 }
            XCTAssertEqual(Data(editor.string.utf8), Data(source.utf8))
            find.query = "alpha"
            try await settle { find.total == 30_000 }
            find.replace(all: true)
            find.dismiss()
            find.present()
            find.query = "不存在"
            try await settle { find.total == 0 }
            XCTAssertEqual(Data(editor.string.utf8), Data(source.utf8))
            editor.isEditable = false
            find.query = "alpha"
            try await settle { find.total == 30_000 }
            find.replace(all: true)
            XCTAssertEqual(Data(editor.string.utf8), Data(source.utf8))
        }
    }

    func testZeroWidthRegexAndUnicodeWholeWordSearchAndReplace() async throws {
        let source = "a\r\na\n汉字 汉字甲 _汉字 汉字_ 👋\n"
        try await withEditor(source) { editor, find in
            find.options.regex = true
            find.query = "(?=a)"
            try await settle { find.total == 2 }
            XCTAssertEqual(editor.textSelection, NSRange(location: 0, length: 0))
            find.navigate(forward: true)
            XCTAssertEqual(editor.textSelection, NSRange(location: 3, length: 0))
            find.navigate(forward: true)
            XCTAssertEqual(editor.textSelection, NSRange(location: 0, length: 0))
            find.present(replacing: true)
            find.replacement = "X"
            find.replace(all: true)
            let expected = "Xa\r\nXa\n汉字 汉字甲 _汉字 汉字_ 👋\n"
            try await settle { editor.string.utf8.elementsEqual(expected.utf8) }
            editor.undoManager?.undo()
            XCTAssertEqual(Data(editor.string.utf8), Data(source.utf8))
            find.options.regex = false
            find.options.wholeWord = true
            find.query = "汉字"
            try await settle { find.total == 1 }
            XCTAssertEqual(editor.textSelection, (source as NSString).range(of: "汉字"))
        }
    }

    func testSupersededQueriesAndClosedDocumentCannotPublishOldMatches() async throws {
        let source = String(repeating: "alpha 中文👋\r\n", count: 30_000) + "unique"
        try await withEditor(source) { editor, find in
            find.query = "alpha"
            find.options.regex = true
            find.query = "("
            find.query = "unique"
            try await settle { find.total == 1 }
            XCTAssertFalse(find.invalidPattern)
            XCTAssertEqual(editor.textSelection, (source as NSString).range(of: "unique"))
            find.query = "."
            find.dismiss()
            XCTAssertNil(find.total)
            XCTAssertTrue(find.visibleMatches(in: NSRange(location: 0, length: 100)).isEmpty)
            find.present()
            find.query = "不存在"
            try await settle { find.total == 0 }
            XCTAssertFalse(find.invalidPattern)
            find.query = "("
            try await settle { find.invalidPattern }
            XCTAssertEqual(find.total, 0)
            find.detach(from: editor)
            XCTAssertNil(find.total)
            XCTAssertNil(editor.findOwner)
        }
    }
}
