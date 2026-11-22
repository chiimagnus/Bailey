import AppKit
import XCTest

@MainActor
final class MarkdownScrollPrecisionUITests: XCTestCase {
    func testScrolledReaderDragShiftSelectionAndDoubleClickUseVisibleGlyphs() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let body = (0..<45).map { index in
            "## Reader heading \(index)\r\n\r\nText for navigation, 中文 and 🧪.\r\n"
        }.joined(separator: "\r\n")
        let source = "[Jump to reader test](#reader-heading-30)\r\n\r\n" + body
        let file = try fixture.file("ScrolledGlyphs.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let jump = preview.links["Jump to reader test"]
        XCTAssertTrue(jump.waitForExistence(timeout: 15))
        jump.click()
        let title = "Reader heading 30"
        let heading = preview.staticTexts["bailey.markdown.heading.reader-heading-30"]
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            heading.exists && preview.frame.contains(heading.frame)
        }, object: nil)
        guard XCTWaiter.wait(for: [shown], timeout: 10) == .completed else {
            return XCTFail("The internal link must scroll the heading fully into the actual viewport")
        }
        XCTAssertTrue(!jump.exists || jump.frame.intersection(preview.frame).height < 1)
        let start = heading.coordinate(withNormalizedOffset: CGVector(dx: 0.008, dy: 0.5))
        let end = heading.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Untouched clipboard", forType: .string))
        start.click(forDuration: 0.15, thenDragTo: end)
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), title,
                       "Dragging must select the visible heading, not an off-screen range")
        start.click()
        XCUIElement.perform(withKeyModifiers: .shift) { end.click() }
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), title,
                       "Shift selection must use the same scrolled coordinates")
        start.doubleClick()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.typeKey("x", modifierFlags: [])
        let headingRange = try XCTUnwrap(source.range(of: "## " + title + "\r\n"))
        XCTAssertTrue(editor.value as? String == source.replacingCharacters(in: headingRange,
                                                                              with: "## x" + title + "\r\n"))
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
    }

    func testBidirectionalScrollingWithinOneMarkdownParagraphTracksActualSourceLines() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = (0..<180).map { index in
            "Sequence line \(index) with selectable words, 中文 and emoji 🛰️ in one paragraph."
        }.joined(separator: "\n")
        let file = try fixture.file("SingleParagraphScroll.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()

        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()

        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let paragraph = preview.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "Sequence line 0")
        ).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10), preview.debugDescription)
        let sourceScroll = window.scrollViews.containing(.textView, identifier: nil).firstMatch
        let sourceBar = sourceScroll.scrollBars.element(boundBy: 1)
        XCTAssertTrue(sourceBar.waitForExistence(timeout: 10))
        func sourcePosition() -> Double {
            Double(String(describing: sourceBar.value ?? "")) ?? -1
        }

        let originalSourcePosition = sourcePosition()
        let originalReaderY = paragraph.frame.minY
        for _ in 0..<6 { preview.swipeUp() }

        let readerDrivesSource = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            sourcePosition() > originalSourcePosition + 0.08
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [readerDrivesSource], timeout: 4), .completed,
                       "A reader scroll inside one AST block must advance the actual source scrollbar")
        let readerY = paragraph.frame.minY
        XCTAssertLessThan(readerY, originalReaderY - 30)
        let readerDrivenSourcePosition = sourcePosition()

        for _ in 0..<4 { editor.swipeDown() }
        let sourceReverses = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            sourcePosition() < readerDrivenSourcePosition - 0.08
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sourceReverses], timeout: 5), .completed,
                       "Source scrolling must reverse from the end without resetting the source")
        let sourceDrivesReader = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            paragraph.frame.minY > readerY + 35
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sourceDrivesReader], timeout: 5), .completed,
                       "New source lines inside the same AST block must reverse the reader viewport")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source,
                       "Synchronization must not alter the original source bytes")
    }
}
