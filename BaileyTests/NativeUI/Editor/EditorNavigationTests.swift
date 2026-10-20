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

    func testNativeGutterKeepsEditorThemeBackgroundInBothAppearances() throws {
        for dark in [false, true] {
            let (window, scroll, editor) = mount(
                "first line\nsecond line\n", width: 480,
                appearance: dark ? .darkAqua : .aqua
            )
            defer { window.close() }
            let palette = EditorPalette.theme(dark: dark)
            editor.backgroundColor = palette.background
            scroll.backgroundColor = palette.background
            editor.showsLineNumbers = true
            let ruler = try XCTUnwrap(editor.gutterView)
            ruler.textColor = palette.gutterText
            ruler.selectedLineTextColor = palette.text
            scroll.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
            ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
            let sampled = try XCTUnwrap(bitmap.colorAt(x: 2, y: bitmap.pixelsHigh / 2))
            let actual = try XCTUnwrap(sampled.usingColorSpace(.deviceRGB))
            let expected = try XCTUnwrap(palette.background.usingColorSpace(.deviceRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.035,
                           "The gutter must not use system gray instead of the editor theme")
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.035)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.035)
        }
    }

    func testNativeGutterSelectedLineAndLargeDocumentWidth() throws {
        let (window, scroll, editor) = mount("one\ntwo\n", width: 480)
        defer { window.close() }
        editor.showsLineNumbers = true
        editor.highlightSelectedLine = true
        let ruler = try XCTUnwrap(editor.gutterView)
        let activeRow = NSColor(calibratedRed: 0.73, green: 0.15, blue: 0.28, alpha: 1)
        ruler.selectedLineHighlightColor = activeRow
        editor.textSelection = NSRange(location: 0, length: 0)
        scroll.layoutSubtreeIfNeeded()
        ruler.needsDisplay = true
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
        ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
        let found = (0..<bitmap.pixelsHigh).contains { y in
            guard let color = bitmap.colorAt(x: 2, y: y)?.usingColorSpace(.deviceRGB) else {
                return false
            }
            return color.redComponent - color.greenComponent > 0.35
                && color.redComponent - color.blueComponent > 0.25
        }
        XCTAssertTrue(found, "The selected line must retain its gutter background highlight")
        XCTAssertEqual(ruler.ruleThickness, 35, accuracy: 1)
        editor.text = String(repeating: "x\n", count: 100_000)
        XCTAssertGreaterThan(ruler.ruleThickness, 35,
                             "Six-digit line numbers must not be clipped by a fixed gutter width")
    }

    func testSelectedTextRangeKeepsAllTouchedGutterNumbersHighlighted() throws {
        for dark in [false, true] {
            let (window, scroll, editor) = mount("first\nsecond\nthird", width: 480,
                appearance: dark ? .darkAqua : .aqua)
            defer { window.close() }
            editor.showsLineNumbers = true
            editor.highlightSelectedLine = true
            let ruler = try XCTUnwrap(editor.gutterView)
            ruler.backgroundColor = .black
            ruler.textColor = .white
            ruler.selectedLineTextColor = .red
            ruler.selectedLineHighlightColor = .black
            // The legacy gutter tints every line containing selected text,
            // even though only an insertion caret gets a row background.
            editor.textSelection = NSRange(location: 2, length: 7)
            scroll.layoutSubtreeIfNeeded()
            ruler.needsDisplay = true
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
            ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / ruler.bounds.height
            let lineHeight = ceil(NSLayoutManager().defaultLineHeight(
                for: try XCTUnwrap(editor.font))) * scale
            func coloredPixels(in image: NSBitmapImageRep, on row: Int) -> Int {
                let start = max(0, Int(CGFloat(row) * lineHeight))
                let end = min(bitmap.pixelsHigh, Int(CGFloat(row + 1) * lineHeight))
                return (start..<end).reduce(0) { total, y in
                    total + (0..<image.pixelsWide).filter { x in
                        guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                        else { return false }
                        return c.redComponent - c.greenComponent > 0.35
                            && c.redComponent - c.blueComponent > 0.35
                    }.count
                }
            }
            XCTAssertGreaterThan(coloredPixels(in: bitmap, on: 0), 3,
                "First selected row must tint its number")
            XCTAssertGreaterThan(coloredPixels(in: bitmap, on: 1), 3,
                "Second selected row must tint its number")
            XCTAssertEqual(coloredPixels(in: bitmap, on: 2), 0,
                "Unselected row must retain subdued number color")

            // Selection ending exactly at the next line's first offset must
            // not tint that untouched line or add the caret-only row fill.
            editor.textSelection = NSRange(location: 0, length: 6)
            ruler.needsDisplay = true
            window.displayIfNeeded()
            let edge = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
            ruler.cacheDisplay(in: ruler.bounds, to: edge)
            XCTAssertGreaterThan(coloredPixels(in: edge, on: 0), 3)
            XCTAssertEqual(coloredPixels(in: edge, on: 1), 0,
                "A selection must not highlight the row at its exclusive end")
        }
    }

    func testEmptyNativeEditorStillPaintsFirstGutterNumber() throws {
        let (window, scroll, editor) = mount("", width: 450)
        defer { window.close() }
        editor.showsLineNumbers = true
        let ruler = try XCTUnwrap(editor.gutterView)
        ruler.backgroundColor = .black
        ruler.textColor = .white
        ruler.selectedLineTextColor = .white
        ruler.selectedLineHighlightColor = .black
        scroll.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
        ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
        let brightPixels = (0..<min(80, bitmap.pixelsHigh)).reduce(0) { count, y in
            count + (max(0, bitmap.pixelsWide - 40)..<max(1, bitmap.pixelsWide - 8)).filter { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { return false }
                return color.redComponent > 0.6 && color.greenComponent > 0.6
            }.count
        }
        XCTAssertGreaterThan(brightPixels, 4,
                             "An empty source file must display line number 1 like the old gutter")
    }

    func testFinalBlankLineRetainsVisibleGutterNumber() throws {
        for source in ["one\n", "one\r\n"] {
            let (window, scroll, editor) = mount(source, width: 450)
            defer { window.close() }
            editor.showsLineNumbers = true
            let ruler = try XCTUnwrap(editor.gutterView)
            ruler.backgroundColor = .black
            ruler.textColor = .white
            ruler.selectedLineTextColor = .white
            ruler.selectedLineHighlightColor = .black
            editor.textSelection = NSRange(location: source.utf16.count, length: 0)
            scroll.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
            ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
            let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: try XCTUnwrap(editor.font)))
            let scale = CGFloat(bitmap.pixelsHigh) / ruler.bounds.height
            let start = min(bitmap.pixelsHigh - 1, Int(lineHeight * scale))
            let end = min(bitmap.pixelsHigh, Int(lineHeight * scale * 3))
            let bright = (start..<end).reduce(0) { count, y in
                count + (max(0, bitmap.pixelsWide - 40)..<max(1, bitmap.pixelsWide - 8)).filter { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    else { return false }
                    return color.redComponent > 0.6 && color.greenComponent > 0.6
                }.count
            }
            XCTAssertGreaterThan(bright, 4,
                                 "The final empty line must show its own gutter number for \(source.debugDescription)")
        }
    }

    func testSelectedFinalBlankLineHighlightsItsOwnTextRow() throws {
        let source = "one\n"
        let (window, scroll, editor) = mount(source, width: 450)
        defer { window.close() }
        editor.backgroundColor = .black
        editor.selectedLineHighlightColor = NSColor(srgbRed: 0.75, green: 0.13, blue: 0.27, alpha: 1)
        editor.highlightSelectedLine = true
        editor.textSelection = NSRange(location: source.utf16.count, length: 0)
        scroll.layoutSubtreeIfNeeded()
        editor.needsDisplay = true
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: try XCTUnwrap(editor.font)))
        let scale = CGFloat(bitmap.pixelsHigh) / editor.bounds.height
        let rowPixels = Int(lineHeight * scale)
        let x = bitmap.pixelsWide - 60
        func redPixels(_ range: Range<Int>) -> Int {
            range.filter { y in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { return false }
                return color.redComponent - color.greenComponent > 0.35
                    && color.redComponent - color.blueComponent > 0.25
            }.count
        }
        XCTAssertGreaterThan(redPixels(rowPixels..<(2 * rowPixels)), 8,
                             "The EOF caret must highlight the empty second row")
        XCTAssertEqual(redPixels(0..<rowPixels), 0,
                       "The preceding nonempty line must not be highlighted")
    }

    func testEmptyEditorPaintsSelectedLineAtTheCaret() throws {
        let (window, scroll, editor) = mount("", width: 420, viewportHeight: 200)
        defer { window.close() }
        editor.backgroundColor = .black
        editor.selectedLineHighlightColor = NSColor(
            srgbRed: 0.75, green: 0.13, blue: 0.27, alpha: 1
        )
        editor.highlightSelectedLine = true
        editor.textSelection = NSRange(location: 0, length: 0)
        scroll.layoutSubtreeIfNeeded()
        editor.needsDisplay = true
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        let y = min(bitmap.pixelsHigh - 1, 14)
        let x = bitmap.pixelsWide - 30
        let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.redComponent - pixel.greenComponent, 0.35,
                             "The empty document caret must retain the selected-line background")
    }

    func testGutterWidthUsesTheSameUserFontAsSourceText() throws {
        let font = NSFont(name: "Menlo", size: 26)
            ?? NSFont.monospacedSystemFont(ofSize: 26, weight: .regular)
        let source = String(repeating: "entry\n", count: 10_000)
        let (window, _, editor) = mount(source, font: font, width: 500)
        defer { window.close() }
        editor.showsLineNumbers = true
        let gutter = try XCTUnwrap(editor.gutterView)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let expected = max(35, ceil(digitWidth * 5 + 10))
        XCTAssertEqual(gutter.ruleThickness, expected, accuracy: 1,
                       "Line numbers must use the editor font, not smaller system mono")
    }

    func testGutterTransitionsAcrossDigitBoundariesWithoutShiftingTextUnderIt() throws {
        for wraps in [false, true] {
            let (window, scroll, editor) = mount("initial", width: 340, wraps: wraps)
            defer { window.close() }
            editor.showsLineNumbers = true
            let ruler = try XCTUnwrap(editor.gutterView)
            let font = try XCTUnwrap(editor.font)
            let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
            for rowCount in [1, 9, 10, 99, 100, 999, 1_000, 9_999, 10_000, 1] {
                let source = String(repeating: "q\n", count: rowCount - 1) + "last"
                editor.text = source
                editor.configureWrapping(wraps, viewportWidth: 340)
                scroll.layoutSubtreeIfNeeded()
                let expectedWidth = max(35, ceil(CGFloat(String(rowCount).count) * digitWidth + 10))
                XCTAssertEqual(ruler.ruleThickness, expectedWidth, accuracy: 1,
                    "Gutter width must follow live row count: \(rowCount)")
                XCTAssertEqual(editor.textContainerInset.width, expectedWidth, accuracy: 1,
                    "Text origin must follow the actual gutter, including after narrowing")
                let fragment = try XCTUnwrap(editor.nativeLayoutManager.textLayoutFragment(
                    for: editor.nativeLayoutManager.documentRange.location
                ))
                let leading = editor.convert(NSPoint(
                    x: fragment.layoutFragmentFrame.minX + editor.textContainerInset.width,
                    y: fragment.layoutFragmentFrame.minY
                ), to: ruler).x
                XCTAssertGreaterThanOrEqual(leading, ruler.bounds.maxX - 1,
                    "First glyph overlaps gutter after crossing \(rowCount) lines")
            }
            editor.showsLineNumbers = false
            XCTAssertNil(editor.gutterView)
            XCTAssertEqual(editor.textContainerInset.width, 0, accuracy: 0.5)
            editor.showsLineNumbers = true
            XCTAssertEqual(editor.textContainerInset.width,
                           try XCTUnwrap(editor.gutterView).ruleThickness, accuracy: 1)
        }
    }

    func testWrappingAndUnwrappedLongUnicodeLinesKeepRealCharacterHitTargets() async throws {
        let line = "中文👋" + String(repeating: "ABcd", count: 180) + "終"
        let source = String(repeating: "short\n", count: 15) + line + "\nend"
        let target = (source as NSString).range(of: "終").location
        for wraps in [false, true] {
            let (window, scroll, editor) = mount(source, width: 360, wraps: wraps)
            defer { window.close() }
            editor.showsLineNumbers = true
            editor.configureWrapping(wraps, viewportWidth: 360)
            try await reveal(NSRange(location: target, length: 1), in: editor)
            let rect = editor.firstRect(forCharacterRange: NSRange(location: target, length: 1),
                                        actualRange: nil)
            XCTAssertTrue(rect.width > 0 && rect.height > 0,
                          "Glyph rect for wraps=\(wraps): screen=\(rect), editor=\(editor.frame), clip=\(scroll.contentView.bounds), textContainer=\(String(describing: editor.textContainer?.size))")
            let windowPoint = try XCTUnwrap(editor.window).convertPoint(
                fromScreen: NSPoint(x: rect.midX, y: rect.midY)
            )
            let localPoint = editor.convert(windowPoint, from: nil)
            // NSTextInputClient takes a screen-space point, not a local view point.
            let hit = editor.characterIndex(for: NSPoint(x: rect.midX, y: rect.midY))
            XCTAssertNotEqual(hit, NSNotFound, "Native TextKit 2 must map the actual glyph to a character; wraps=\(wraps), rect=\(rect), editor=\(editor.frame), clip=\(scroll.contentView.bounds)")
            if hit != NSNotFound {
                XCTAssertLessThanOrEqual(abs(hit - target), 1,
                    "Long Unicode line must preserve native reverse hit testing")
            }
            if wraps {
                let visible = scroll.contentView.bounds
                XCTAssertGreaterThanOrEqual(localPoint.x, visible.minX)
                XCTAssertLessThanOrEqual(localPoint.x, visible.maxX + 2,
                                         "Wrapped final glyph must fit inside the viewport")
            } else {
                XCTAssertGreaterThan(scroll.documentView?.frame.width ?? 0, scroll.frame.width,
                                     "Long unwrapped line must remain horizontally reachable")
            }
        }
    }

    func testMountedSourceEditorActuallyPaintsVisibleTextInBothAppearances() async throws {
        for (ext, dark) in [("txt", true), ("txt", false), ("swift", true), ("swift", false)] {
            for count in [2, 10_000] {
                let path = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "." + ext)
                let source = String(repeating: "let visibleText = \"中文 123\"\n", count: count)
                try Data(source.utf8).write(to: path)
                defer { try? FileManager.default.removeItem(at: path) }
                let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared,
                                   workspaceIdentity: nil)
                try await file.waitForText()
                let host = NSHostingView(rootView: SourceTextEditor(
                    file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    palette: .theme(dark: dark), wrapLines: false, isFocused: false
                ))
                let window = NSWindow(contentRect: NSRect(x: -950, y: -950, width: 840, height: 650),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                let editor = try XCTUnwrap((file.editorView as? NSScrollView)?.documentView
                                           as? NativeCodeTextView)
                XCTAssertEqual(editor.text, source)
                let ruler = try XCTUnwrap(editor.gutterView)
                let firstFragment = try XCTUnwrap(editor.nativeLayoutManager.textLayoutFragment(
                    for: editor.nativeLayoutManager.documentRange.location
                ))
                let firstGlyph = editor.convert(NSPoint(
                    x: firstFragment.layoutFragmentFrame.minX + editor.textContainerInset.width,
                    y: firstFragment.layoutFragmentFrame.minY
                ), to: ruler)
                XCTAssertGreaterThanOrEqual(firstGlyph.x, ruler.bounds.maxX - 1,
                    "Source \(ext), \(count) lines, dark=\(dark): gutter must never cover initial glyph")
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                let x0 = Int(80 * scale)
                let x1 = min(bitmap.pixelsWide, Int(380 * scale))
                let y1 = min(bitmap.pixelsHigh, Int(75 * scale))
                let background = try XCTUnwrap(EditorPalette.theme(dark: dark)
                    .background.usingColorSpace(.deviceRGB))
                let visiblePixels = (0..<y1).reduce(0) { total, y in
                    total + (x0..<x1).filter { x in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                        else { return false }
                        return max(abs(color.redComponent - background.redComponent),
                                   abs(color.greenComponent - background.greenComponent),
                                   abs(color.blueComponent - background.blueComponent)) > 0.3
                    }.count
                }
                XCTAssertGreaterThan(visiblePixels, 30,
                                     "Source \(ext), \(count) lines, dark=\(dark): the real window must paint glyphs, not only expose AX text")
            }
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
        XCTAssertEqual(scroll.contentView.bounds.minY, 5_000, accuracy: 2,
                       "Initial restoration: editor=\(editor.frame), clip=\(scroll.contentView.bounds), state=\(String(describing: file.editorState.scrollY)), selected=\(editor.selectedRange())")
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

    func testFourSizesWrappingAndThreeInputPositionsKeepDataAndLatency() async throws {
        let line = "let message = \"中文 👋\" // long readable code\n"
        for rows in [382, 1_000, 10_000, 100_000] {
            let source = String(repeating: line, count: rows)
            let originalLength = source.utf16.count
            for wraps in [false, true] {
                let (window, _, editor) = mount(source, width: wraps ? 280 : 820, wraps: wraps)
                defer { window.close() }
                let positions = [
                    ("head", 0),
                    ("middle", (rows / 2) * line.utf16.count),
                    ("tail", originalLength),
                ]
                for (position, offset) in positions {
                    try await reveal(NSRange(location: offset, length: 0), in: editor)
                    var costs: [Double] = []
                    for _ in 0..<30 {
                        let started = CFAbsoluteTimeGetCurrent()
                        editor.insertText("X", replacementRange: NSRange(location: offset, length: 0))
                        costs.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                        XCTAssertEqual((editor.string as NSString).substring(
                            with: NSRange(location: offset, length: 1)), "X")
                        editor.insertText("", replacementRange: NSRange(location: offset, length: 1))
                        XCTAssertEqual(editor.string.utf16.count, originalLength)
                    }
                    XCTAssertEqual(editor.string, source,
                                   "No text loss after \(rows) rows, \(wraps), \(position)")
                    costs.sort()
                    let median = costs[15]
                    let p95 = costs[28]
                    let worst = costs[29]
                    print("T5_INPUT rows=\(rows) wraps=\(wraps) position=\(position) count=30 median=\(median) p95=\(p95) worst=\(worst)")
                    if rows == 100_000 {
                        XCTAssertLessThanOrEqual(median, 16,
                            "100k native editor must retain its agreed median latency budget")
                        XCTAssertLessThanOrEqual(p95, 32,
                            "100k native editor must retain its agreed p95 latency budget")
                    }
                }
                XCTAssertEqual(editor.text, source)
            }
        }
    }

    func testDeletingLongestUnwrappedLineRestoresHorizontalExtent() async throws {
        let long = "let veryLong = \"" + String(repeating: "a", count: 2_000) + "\"\n"
        let short = "let value = \"中文 👋\"\n"
        let (window, scroll, editor) = mount(long + short, width: 500)
        defer { window.close() }
        editor.allowsUndo = true
        let originalWidth = editor.frame.width
        XCTAssertGreaterThan(originalWidth, 5_000)

        editor.insertText("", replacementRange: NSRange(location: 0, length: long.utf16.count))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.string, short)
        XCTAssertLessThan(editor.frame.width, originalWidth / 3,
            "Removing the widest line must not leave a stale horizontal scroll range")
        XCTAssertEqual(editor.frame.width, editor.textContainer?.size.width ?? -1, accuracy: 1)
        try await reveal(NSRange(location: short.utf16.count - 1, length: 1), in: editor)

        editor.undoManager?.undo()
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.string, long + short)
        XCTAssertGreaterThan(editor.frame.width, originalWidth - 1)
        XCTAssertEqual(editor.frame.width, editor.textContainer?.size.width ?? -1, accuracy: 1)
    }

    func testColdAndWarmScrollbarGeometryAcrossFourFileSizes() async throws {
        let line = "let value = \"中文 👋\" // fixed row\n"
        for rows in [382, 1_000, 10_000, 100_000] {
            let document = String(repeating: line, count: rows)
            let (window, scroll, editor) = mount(document, width: 820, wraps: false)
            defer { window.close() }
            var heightSamples: [CGFloat] = []
            var knobSamples: [CGFloat] = []
            var offsets: [CGFloat] = []
            let visits = [0, rows/4, rows/10, rows/4, 0, rows/2,
                          rows*3/4, rows-1, rows/2, 0, rows*3/4,
                          rows/10, rows-1, rows/4, rows/2, rows/10, 0]
            for row in visits {
                let location = row * line.utf16.count
                try await reveal(NSRange(location: location, length: 1), in: editor)
                scroll.layoutSubtreeIfNeeded()
                let height = editor.frame.height
                let knob = scroll.verticalScroller?.knobProportion ?? .nan
                heightSamples.append(height)
                knobSamples.append(knob)
                offsets.append(scroll.contentView.bounds.minY)
                XCTAssertTrue(height.isFinite && height >= scroll.contentView.bounds.height)
                XCTAssertTrue(knob.isFinite && knob >= 0 && knob <= 1)
                XCTAssertTrue(offsets.last!.isFinite)
                XCTAssertEqual(editor.string.utf16.count, document.utf16.count)
            }
            let swing = (heightSamples.max() ?? 0) - (heightSamples.min() ?? 0)
            let knobSwing = (knobSamples.max() ?? 0) - (knobSamples.min() ?? 0)
            XCTAssertLessThanOrEqual(swing, 1,
                "A fixed-height document must not change its scroll height during cold/warm jumps")
            XCTAssertLessThanOrEqual(knobSwing, 0.00000001,
                "A fixed-height document must not change the scrollbar thumb ratio")
            print("T5_SCROLLER rows=\(rows) visits=\(visits.count) heightSwing=\(swing) knobSwing=\(knobSwing) minY=\(offsets.min() ?? -1) maxY=\(offsets.max() ?? -1)")
        }
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
