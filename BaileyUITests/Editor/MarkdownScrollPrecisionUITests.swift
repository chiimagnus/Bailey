import AppKit
import XCTest

@MainActor
final class MarkdownScrollPrecisionUITests: XCTestCase {
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
