import AppKit
import XCTest

@MainActor
final class MarkdownSelectionBoundaryUITests: XCTestCase {
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
