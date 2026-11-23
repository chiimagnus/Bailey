import AppKit
import XCTest

@MainActor
final class MarkdownMathUITests: XCTestCase {
    func testDoubleClickCanvasFormulaLocatesOriginalUTF16Delimiters() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let cases = [
            (name: "Inline",
             source: "# Coordinates\n\nBefore 🧪 e\u{301} $x_i+y$ then after.\n",
             latex: "x_i+y", raw: "$x_i+y$"),
            (name: "Display",
             source: "# Coordinates\n\nBefore paragraph.\n\n$$\n\\frac{a+b}{2}\n$$\n",
             latex: "\\frac{a+b}{2}", raw: "$$\n\\frac{a+b}{2}\n$$")
        ]
        let documents = try cases.map {
            (file: try fixture.file("\($0.name).md", text: $0.source),
             source: $0.source, latex: $0.latex, raw: $0.raw)
        }
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        for entry in documents {
            let row = WorkspaceUITestSupport.fileRow(entry.file, in: window)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            app.activate()
            row.doubleClick()
            XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 12))
            app.typeKey("v", modifierFlags: [.command, .shift])
            let formula = preview.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Math: " + entry.latex)
            ).firstMatch
            XCTAssertTrue(formula.waitForExistence(timeout: 15),
                          "Actual native math Canvas must be reachable")
            formula.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
            XCTAssertTrue(preview.waitForNonExistence(timeout: 10),
                          "Double-clicking Canvas must switch to the original source buffer")
            let editor = window.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            app.typeKey("z", modifierFlags: [])
            let expected = entry.source.replacingOccurrences(
                of: entry.raw, with: "z" + entry.raw
            )
            XCTAssertEqual(editor.value as? String, expected,
                           "The inserted character must land before the exact original TeX delimiter")
            XCTAssertEqual(try String(contentsOf: entry.file, encoding: .utf8), entry.source,
                           "Source navigation must not save text implicitly")
        }
    }

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

    func testMixedOfflineMathMermaidAndFootnoteStaySafeAfterLiveEdits() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let fence = String(repeating: String(UnicodeScalar(96)!), count: 3)
        let original = [
            "# Experimental report", "",
            "Cost $5 and formula $E=mc^2$ with note[^ref].", "",
            fence + "mermaid", "flowchart TD", "  click A \"https://example.com\"", fence, "",
            "[^ref]: A **formatted** footnote.",
        ].joined(separator: "\n")
        let file = try fixture.file("Mixed-Lab.md", text: original)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        func formula(_ latex: String) -> XCUIElement {
            preview.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "Math: " + latex)
            ).firstMatch
        }
        XCTAssertTrue(formula("E=mc^2").waitForExistence(timeout: 12),
                      "Currency text must not swallow the following formula")
        XCTAssertTrue(preview.staticTexts.containing(
            NSPredicate(format: "value CONTAINS %@", "Cost $5")
        ).firstMatch.exists, "The unpaired currency must remain normal prose")
        XCTAssertTrue(preview.staticTexts.containing(
            NSPredicate(format: "value CONTAINS %@", "Could not render Mermaid")
        ).firstMatch.waitForExistence(timeout: 12),
                      "Unsafe Mermaid input must fall back to readable source")
        XCTAssertTrue(preview.staticTexts.containing(
            NSPredicate(format: "value CONTAINS %@", "click A")
        ).firstMatch.exists)
        XCTAssertTrue(preview.links["1"].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)

        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        let edited = original.replacingOccurrences(of: "E=mc^2", with: "x_i+y_j")
        editor.typeText(edited)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(formula("x_i+y_j").waitForExistence(timeout: 15),
                      "Preview must reparse live edits instead of rendering stale formula Canvas")
        XCTAssertFalse(formula("E=mc^2").exists)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original,
                       "Preview must remain read-only until the ordinary source save path is used")
    }

    func testMalformedMathShowsReadableSourceWithoutHidingNeighboringEquations() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = [
            "# Formula diagnostic", "",
            "Broken $\\unknowncommand$ but $x^2$ is valid.", "",
            "$$", "\\frac{", "$$"
        ].joined(separator: "\n")
        let file = try fixture.file("Math-Errors.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        for latex in ["\\unknowncommand", "\\frac{"] {
            let accessible = preview.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Math: " + latex)
            )
            let fallback = accessible.firstMatch
            XCTAssertTrue(fallback.waitForExistence(timeout: 12),
                          "Invalid LaTeX must remain accessible instead of vanishing")
            XCTAssertEqual(accessible.count, 1,
                           "The zero-size Math Canvas must not duplicate fallback in VoiceOver")
            XCTAssertGreaterThan(fallback.frame.width, 3)
            XCTAssertGreaterThan(fallback.frame.height, 3)
        }
        let valid = preview.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Math: x^2")
        ).firstMatch
        XCTAssertTrue(valid.waitForExistence(timeout: 12))
        XCTAssertGreaterThan(valid.frame.height, 3)
        XCTAssertFalse(preview.staticTexts.matching(
            NSPredicate(format: "value == %@", "$x^2$")
        ).firstMatch.exists, "A successfully typeset formula must never draw its fallback Text")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Native formula errors with readable fallback and valid equation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
