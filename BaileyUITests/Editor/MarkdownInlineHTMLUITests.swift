import Foundation
import XCTest

@MainActor
final class MarkdownInlineHTMLUITests: XCTestCase {
    func testParagraphInlineHTMLLinkUsesNativeNavigationAndDoesNotPrintTags() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let readme = try fixture.file("Readme.md", text: """
            # Mixed Markdown and HTML

            Before <a href="Guide.md">Guide</a> and <strong>important</strong> after.

            A second paragraph remains separate.
            """)
        let destination = try fixture.file("Guide.md", text: "# Linked document\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(readme, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertFalse(preview.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "<strong>"
        )).firstMatch.exists, "Inline HTML tags must not be printed")
        let link = preview.links["Guide"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), preview.debugDescription)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Mixed native Markdown and HTML link"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        link.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(destination, in: window)
            .waitForExistence(timeout: 10), "Inline HTML link must use the same project-authorized file route")
    }
}
