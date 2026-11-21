import AppKit
import XCTest

@MainActor
final class MarkdownMathUITests: XCTestCase {
    func testNativeMathInsideHeadingsEmphasisAndTables() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("MathBlocks.md", text: [
            "# Heading $x*y*z$",
            "",
            "**Bold $a_i*b_j$ prose**",
            "",
            "| Label | Value |",
            "| --- | --- |",
            "| result | $x_i*y_j$ |",
        ].joined(separator: "\n"))
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        for latex in ["x*y*z", "a_i*b_j", "x_i*y_j"] {
            let formula = preview.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Math: " + latex))
                .firstMatch
            XCTAssertTrue(formula.waitForExistence(timeout: 8),
                          "Nested formula \(latex) must use SwiftUI Math, not raw TeX")
            XCTAssertGreaterThan(formula.frame.height, 3)
        }
    }

    func testNativeInlineAndDisplayMathRenderWithoutWebViews() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("Equations.md", text: [
            "# Formulae",
            "",
            "Einstein $E=mc^2$ and nonlinear $x*y*z$.",
            "",
            "$$",
            "\\frac{a+b}{\\sqrt{2}}",
            "$$",
            "",
            "Escaped dollar \\$5 stays prose.",
        ].joined(separator: "\n"))
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])

        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        for latex in ["E=mc^2", "x*y*z", "\\frac{a+b}{\\sqrt{2}}"] {
            let formula = preview.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Math: " + latex))
                .firstMatch
            XCTAssertTrue(formula.waitForExistence(timeout: 12),
                          "Native math formula \(latex) missing: \(preview.debugDescription)")
            XCTAssertGreaterThan(formula.frame.height, 3, "Formula must have visible layout")
        }
        XCTAssertTrue(preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "Escaped dollar $5"
        )).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "SwiftUI native Math inline and display"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
