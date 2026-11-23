import AppKit
import XCTest

@MainActor
final class SVGFilePreviewUITests: XCTestCase {
    func testDefaultVectorPaintsAndSharesSourceAndCompanionActions() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" width="360" height="220" viewBox="-180 -110 360 220">
              <defs><pattern id="paper" width="2" height="2"><rect width="1" height="1"/></pattern></defs>
              <rect x="-180" y="-110" width="360" height="220" fill="#f11a14"/>
            </svg>
            """
        let file = try fixture.file("图形.SVG", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let preview = WorkspaceUITestSupport.element("bailey.svg.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 12))
        func redCenter() -> Bool {
            guard let bitmap = NSBitmapImageRep(data: window.screenshot().pngRepresentation) else { return false }
            let origin = window.frame.origin
            let column = Int((preview.frame.midX - origin.x) * CGFloat(bitmap.pixelsWide) / window.frame.width)
            let row = Int((preview.frame.midY - origin.y) * CGFloat(bitmap.pixelsHigh) / window.frame.height)
            guard (0..<bitmap.pixelsWide).contains(column), (0..<bitmap.pixelsHigh).contains(row),
                  let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { return false }
            return color.redComponent > 0.6 && color.redComponent > 2 * max(color.greenComponent, color.blueComponent)
        }
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in redCenter() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 8), .completed)
        let omitted = app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@ OR label CONTAINS %@", "omits: pattern", "omits: pattern"
        )).firstMatch
        XCTAssertTrue(omitted.exists)

        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let split = WorkspaceUITestSupport.menuItem("Show Side by Side", in: app)
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.click()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        XCTAssertTrue((window.textViews.firstMatch.value as? String)?.contains("<pattern id=\"paper\"") == true)
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
    }

    func testInvalidSVGOffersItsUnchangedSource() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let invalid = "<svg><g>"
        let oversized = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"3000\" height=\"3000\"/>"
        let fixtures = [
            (try fixture.file("invalid.svg", text: invalid), invalid, "Could not display this SVG."),
            (try fixture.file("oversized.svg", text: oversized), oversized,
             "SVG is too large to preview. You can still edit the source."),
        ]
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        for (file, source, reason) in fixtures {
            let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
            let message = app.staticTexts.matching(NSPredicate(
                format: "value == %@ OR label == %@", reason, reason
            )).firstMatch
            XCTAssertTrue(message.waitForExistence(timeout: 10))
            let showSource = WorkspaceUITestSupport.element("bailey.svg.showSource", in: app)
            XCTAssertTrue(showSource.waitForExistence(timeout: 5))
            showSource.click()
            let editor = app.windows.firstMatch.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            XCTAssertTrue((editor.value as? String)?.contains(source) == true)
            XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
        }
    }
}
