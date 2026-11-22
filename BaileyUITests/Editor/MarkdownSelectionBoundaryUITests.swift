import AppKit
import XCTest

@MainActor
final class MarkdownSelectionBoundaryUITests: XCTestCase {
    func testMarkdownSelectionAndCanvasUseTheTerminalTheme() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file(".config/bailey-dev/config.toml", text: """
            theme = "dark"
            theme-dark = "Dracula"
            """)
        let source = "# Theme preview\n\nFIRST selection stays visible.\n\n> LAST selection is across a quote.\n"
        let file = try fixture.file("ThemeSelection.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    configurationHome: fixture.root, project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let start = preview.staticTexts["FIRST selection stays visible."].firstMatch
        let quote = preview.staticTexts["LAST selection is across a quote."].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(quote.waitForExistence(timeout: 10))

        func pixels(_ color: UInt32) throws -> Int {
            let shot = preview.screenshot()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: shot.pngRepresentation))
            let image = try XCTUnwrap(bitmap.cgImage)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let expected = [Int((color >> 16) & 255), Int((color >> 8) & 255), Int(color & 255)]
            var count = 0
            for row in stride(from: 0, to: image.height, by: 2) {
                for column in stride(from: 0, to: image.width, by: 2) {
                    let offset = row * context.bytesPerRow + column * 4
                    if expected.indices.allSatisfy({ abs(Int(bytes[offset + $0]) - expected[$0]) <= 4 }) {
                        count += 1
                    }
                }
            }
            return count
        }

        XCTAssertGreaterThan(try pixels(0x282A36), 1000, "Dracula's canvas must replace the fixed GitHub background")
        let unselected = try pixels(0x44475A)
        for destination in [start, quote] {
            start.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5)).click(
                forDuration: 0.15,
                thenDragTo: destination.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            )
            XCTAssertGreaterThan(try pixels(0x44475A), unselected + 40,
                                 "Single-text and cross-block drag must both use the terminal selection color")
            app.typeKey("c", modifierFlags: .command)
            XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.hasPrefix("FIRST selection") == true)
        }
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        let darkPicker = settings.popUpButtons.element(boundBy: 1)
        darkPicker.click()
        let gruvbox = darkPicker.menuItems["Gruvbox Dark"]
        XCTAssertTrue(gruvbox.waitForExistence(timeout: 12))
        gruvbox.click()
        let closeSettings = settings.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeSettings.waitForExistence(timeout: 12))
        closeSettings.click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 12))
        XCTAssertTrue(preview.waitForExistence(timeout: 12), "The same reading view remains open after a theme change")
        XCTAssertGreaterThan(try pixels(0x282828), 1000, "An open preview must repaint for the new theme")
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5)).click(
            forDuration: 0.15, thenDragTo: quote.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        )
        XCTAssertGreaterThan(try pixels(0x665C54), 40, "Selection must not retain the previous theme's color")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testHTMLBlockGlyphLocatesSourceAndSelectsAcrossMarkdownParagraph() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # HTML coordinates

            <div>
            <p>🧪 DUPLICATE</p>
            <p><code>🧪 DUPLICATE</code></p>
            </div>

            MARKDOWN_TAIL
            """
        let file = try fixture.file("HTMLCoordinates.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let repeated = preview.staticTexts.matching(NSPredicate(format: "value == %@", "🧪 DUPLICATE"))
        let second = repeated.element(boundBy: 1)
        let tail = preview.staticTexts["MARKDOWN_TAIL"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 15), preview.debugDescription)
        XCTAssertTrue(tail.waitForExistence(timeout: 10), preview.debugDescription)
        let target = second.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.50))
        target.click(forDuration: 0.15,
                     thenDragTo: tail.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.53)))
        app.typeKey("c", modifierFlags: .command)
        let copied = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertTrue(copied.hasSuffix("MARKDOWN_TAIL"), copied)
        XCTAssertTrue("DUPLICATE".hasSuffix(String(copied.prefix { !$0.isNewline })), copied)
        XCTAssertFalse(copied.contains("🧪") || copied.contains("DUPLICATE"), copied)

        target.doubleClick()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        app.typeKey("z", modifierFlags: [])
        let value = try XCTUnwrap(window.textViews.firstMatch.value as? String)
        let edited = try XCTUnwrap(value.components(separatedBy: "<code>🧪 ").last?.components(separatedBy: "</code>").first)
        XCTAssertTrue(edited.contains("z"), value)
        XCTAssertEqual(edited.replacingOccurrences(of: "z", with: ""), "DUPLICATE")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testSelectAllIncludesBodyAfterEarlierFootnoteDefinition() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Footnote selection

            FIRST_BLOCK with a reference[^note].

            [^note]: Definition text.

            FINAL_TAIL_VISIBLE after the footnote definition.
            """
        let file = try fixture.file("SelectFootnote.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let first = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "FIRST_BLOCK")
        ).firstMatch
        let tail = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "FINAL_TAIL_VISIBLE")
        ).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(tail.waitForExistence(timeout: 10))
        first.click()
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Untouched", forType: .string))
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("FIRST_BLOCK") && copied.contains("Definition text.")
                      && copied.contains("FINAL_TAIL_VISIBLE"),
                      "Select All must include every visible block despite out-of-order footnotes: \(copied)")

        let heading = preview.staticTexts["Footnote selection"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        heading.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        let fromHeading = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(fromHeading.contains("FIRST_BLOCK")
                      && fromHeading.contains("FINAL_TAIL_VISIBLE"), fromHeading)
    }

    func testFoldedSectionSelectAllCopiesOnlyVisibleBlocks() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Start

            FIRST_VISIBLE_CONTENT

            ## Fold

            HIDDEN_SECTION_BODY

            ### Child

            HIDDEN_CHILD_BODY

            ## Next

            LAST_VISIBLE_CONTENT
            """
        let file = try fixture.file("FoldCopy.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root
        )
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let heading = preview.staticTexts["Fold"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        heading.hover()
        let fold = preview.buttons["bailey.markdown.fold.fold"]
        XCTAssertTrue(fold.waitForExistence(timeout: 10))
        fold.click()
        XCTAssertFalse(preview.staticTexts["HIDDEN_SECTION_BODY"].exists)
        let first = preview.staticTexts["FIRST_VISIBLE_CONTENT"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.click()
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Untouched", forType: .string))
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("FIRST_VISIBLE_CONTENT")
                      && copied.contains("LAST_VISIBLE_CONTENT")
                      && copied.contains("Fold"), copied)
        XCTAssertFalse(copied.contains("HIDDEN_SECTION_BODY") ||
                       copied.contains("HIDDEN_CHILD_BODY"),
                       "Selection must honor the same collapsed block visibility as the renderer")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testDetailsSelectionCopyTracksUserExpansionAndCollapse() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Selection

            <details><summary>Show information</summary><p>Hidden 中文 🚀 text</p></details>
            """
        let file = try fixture.file("CopyDetails.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let details = preview.buttons["bailey.markdown.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 15))

        func selectedCopy() -> String {
            NSPasteboard.general.clearContents()
            XCTAssertTrue(NSPasteboard.general.setString("Untouched", forType: .string))
            details.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey("c", modifierFlags: .command)
            return NSPasteboard.general.string(forType: .string) ?? ""
        }

        let opened = selectedCopy()
        XCTAssertTrue(preview.staticTexts["Hidden 中文 🚀 text"].waitForExistence(timeout: 10))
        XCTAssertTrue(opened.contains("Hidden 中文 🚀 text"), opened)
        let closed = selectedCopy()
        XCTAssertTrue(preview.staticTexts["Hidden 中文 🚀 text"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(closed.contains("Show information") && !closed.contains("Hidden 中文 🚀 text"),
                      "Collapsed details must exclude the hidden body: \(closed)")
    }

    func testSelectingAcrossTwelfthAndThirteenthParagraphCopiesBothEnds() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let paragraphs = (0..<13).map { index -> String in
            if index == 0 { return "SELECTION_START alpha beta gamma." }
            if index == 12 { return "SELECTION_END omega 中文 🛰️." }
            return "MIDDLE_PARAGRAPH_\(index) regular prose."
        }
        let file = try fixture.file("SelectionBoundary.md", text: paragraphs.joined(separator: "\n\n"))
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])

        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let start = preview.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "SELECTION_START")
        ).firstMatch
        let end = preview.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "SELECTION_END")
        ).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), preview.debugDescription)
        XCTAssertTrue(end.waitForExistence(timeout: 10), preview.debugDescription)

        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Untouched clipboard", forType: .string))
        let from = start.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.005))
        let to = end.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.50))
        from.click(forDuration: 0.15, thenDragTo: to)
        app.typeKey("c", modifierFlags: .command)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertEqual(copied, paragraphs.joined(separator: "\n\n"),
                       "Cross-group selection must copy exactly the visible text, with paragraph separators")
    }

    func testDragFromNestedListIntoTableSelectsWithoutEarlierItems() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Selection

            - FIRST_ITEM must not copy
            - SECOND_ITEM selection starts

            | Key | Result |
            | --- | ------ |
            | One | RESULT_CELL_B |

            Last paragraph.
            """
        let file = try fixture.file("SelectMixed.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let start = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "SECOND_ITEM")
        ).firstMatch
        let end = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "RESULT_CELL_B")
        ).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), preview.debugDescription)
        XCTAssertTrue(end.waitForExistence(timeout: 10), preview.debugDescription)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Untouched", forType: .string))
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
            .click(forDuration: 0.15,
                   thenDragTo: end.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5)))
        app.typeKey("c", modifierFlags: .command)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("SECOND_ITEM") && copied.contains("RESULT_CELL_B"),
                      "Drag must cross list and table text: \(copied)")
        XCTAssertFalse(copied.contains("FIRST_ITEM"), copied)
    }

    func testDraggingFromLinkedTextIntoNextParagraphCopiesActualLinkLabel() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Selection

            [OPEN_LINK](https://example.org) following prose.

            AFTER_LINK destination.
            """
        let file = try fixture.file("LinkedSelect.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let start = preview.links["OPEN_LINK"].firstMatch
        let end = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "AFTER_LINK")
        ).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), preview.debugDescription)
        XCTAssertTrue(end.waitForExistence(timeout: 10), preview.debugDescription)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Untouched", forType: .string))
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
            .click(forDuration: 0.15,
                   thenDragTo: end.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.97)))
        app.typeKey("c", modifierFlags: .command)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("OPEN_LINK") && copied.contains("AFTER_LINK"),
                      "Selection starting on a link must include its visible label: \(copied)")
        XCTAssertTrue(preview.exists, "Dragging a link must not open its target")
    }

    func testShiftClickExtendsAcrossHeadingQuoteAndParagraph() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = "# Starting Heading\n\n> Quoted 中文 sentence.\n\nClosing destination text."
        let file = try fixture.file("ShiftSelect.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let first = preview.staticTexts["Starting Heading"].firstMatch
        let last = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "Closing destination")
        ).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Selection untouched", forType: .string))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5)).click()
        XCUIElement.perform(withKeyModifiers: .shift) { last.click() }
        app.typeKey("c", modifierFlags: .command)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("Starting Heading")
                      && copied.contains("Quoted 中文 sentence.")
                      && copied.contains("Closing"),
                      "Shift-click must create one continuous selection across separate views: \(copied)")
    }

    func testDoubleClickSecondCodeLineLocatesOriginalSourceGlyph() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = String(repeating: "L", count: 12)
        let second = String(repeating: "S", count: 12)
        let source = "# Code\n\n```swift\n" + first + "\n" + second + "\n```\n"
        let file = try fixture.file("DoubleClickCodeLine.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let code = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", second)
        ).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(code.frame.height, 30)
        let target = 9
        code.coordinate(withNormalizedOffset: CGVector(dx: (CGFloat(target) + 0.5) / 12, dy: 0.58))
            .doubleClick()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10),
                      "Double-click on the second code line must switch to the authoritative editor")
        app.typeKey("z", modifierFlags: [])
        let editor = app.windows.firstMatch.textViews.firstMatch
        XCTAssertEqual(editor.value as? String, source.replacingOccurrences(
            of: second, with: String(repeating: "S", count: target) + "z"
                + String(repeating: "S", count: 12 - target)
        ))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testDragFromSecondCodeLineToFollowingParagraphCopiesOnlyVisibleRange() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Code example

            ```swift
            first line
            second line
            ```

            AFTER_CODE destination.
            """
        let file = try fixture.file("CodeSelection.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let code = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "second line")
        ).firstMatch
        let destination = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "AFTER_CODE")
        ).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Selection untouched", forType: .string))
        let from = code.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.74))
        let to = destination.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5))
        from.click(forDuration: 0.15, thenDragTo: to)
        app.typeKey("c", modifierFlags: .command)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("second line") && copied.contains("AFTER_CODE")
                      && !copied.contains("first line") && !copied.contains("```"),
                      "Selection starting inside fenced code must not include earlier hidden content: \(copied)")
    }

    func testShiftArrowAdvancesOneCompleteUnicodeGrapheme() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = "🛰️e\u{301} suffix"
        let file = try fixture.file("UnicodeShift.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let body = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "suffix")
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Selection untouched", forType: .string))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5)).click()
        app.typeKey(.rightArrow, modifierFlags: .shift)
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "🛰️")
        app.typeKey(.rightArrow, modifierFlags: .shift)
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "🛰️e\u{301}")
    }

    func testShiftArrowExtendsSelectionWithoutSplittingText() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("ShiftArrow.md", text: "STARTSHIFT word")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let body = preview.staticTexts["STARTSHIFT word"].firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Selection untouched", forType: .string))
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5)).click()
        app.typeKey(.rightArrow, modifierFlags: .shift)
        app.typeKey(.rightArrow, modifierFlags: .shift)
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "ST",
                       "Shift+Arrow should select the next two visible glyphs")
    }

    func testPreviewSelectionDoesNotHijackSourceEditorSelectAll() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = "# Focus\n\nText **bold**\n\n> quoted\n"
        let file = try fixture.file("Focus.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let body = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "Text bold")
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        body.click()
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Selection untouched", forType: .string))
        app.typeKey("a", modifierFlags: .command)
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), source,
                       "The native source editor must keep its own Select All and Copy commands")
    }

    func testCommandAOnReaderSelectsAcrossHeadingQuoteTableAndCode() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Visible Heading

            Body with **bold** and `code`.

            > Quoted prose.

            | Key | Value |
            | --- | ----- |
            | Item | 42 |

            ```swift
            let value = 42
            ```
            """
        let file = try fixture.file("SelectAll.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let body = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "Body with")
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        body.click()
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Not selected", forType: .string))
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("Visible Heading") && copied.contains("Quoted prose.")
                      && copied.contains("Key\tValue") && copied.contains("let value = 42"),
                      "Select All in the reader must include all visible structures: \(copied)")
        XCTAssertFalse(copied.contains("**") || copied.contains("```"),
                       "Copy must omit Markdown delimiters: \(copied)")
    }
}
