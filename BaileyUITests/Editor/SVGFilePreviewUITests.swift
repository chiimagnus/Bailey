import AppKit
import XCTest

@MainActor
final class SVGFilePreviewUITests: XCTestCase {
    func testDefaultVectorPaintsAndSharesSourceAndCompanionActions() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" width="360" height="220" viewBox="-180 -110 360 220">
              <defs>
                <pattern id="paper" width="2" height="2"><rect width="1" height="1"/></pattern>
                <symbol id="sheet" viewBox="0 0 36 22"><rect width="36" height="22"/></symbol>
              </defs>
              <use href="#sheet" x="-180" y="-110" width="360" height="220" fill="#f11a14"/>
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
                format: "value BEGINSWITH %@ OR label BEGINSWITH %@", reason, reason
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

    func testPNGOutputMenusOfferExplicitOptionsAndCancelWithoutChangingFiles() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = #"<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><rect width="80" height="40" fill="red"/></svg>"#
        let file = try fixture.file("Diagram.svg", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let preview = WorkspaceUITestSupport.element("bailey.svg.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 12))
        let clipboardChangeCount = NSPasteboard.general.changeCount
        for title in ["Copy PNG…", "Export PNG…"] {
            preview.rightClick()
            let action = WorkspaceUITestSupport.menuItem(title, in: app)
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            action.click()
            let sheet = window.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 8))
            let cancel = sheet.buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            XCTAssertTrue(sheet.staticTexts["Pixel width"].exists, sheet.debugDescription)
            XCTAssertTrue(sheet.staticTexts["Pixel height"].exists, sheet.debugDescription)
            XCTAssertTrue(sheet.staticTexts["Color space"].exists, sheet.debugDescription)
            XCTAssertTrue(sheet.staticTexts["Background"].exists, sheet.debugDescription)
            cancel.click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 8))
            XCTAssertTrue(preview.exists)
            XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: "Diagram.png").path))
            XCTAssertEqual(NSPasteboard.general.changeCount, clipboardChangeCount)
        }
    }

    func testCompressedSVGShowsAnActionableMessageAndDoesNotEnterPreview() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let bytes = try XCTUnwrap(Data(base64Encoded:
            "H4sIAAAAAAAAAxXMQQ6DMAwF0atY/wDYhF0VZ8FNqpImkdJSgYU5fmE9TxP3o9D56d9dUc1+D2Z3H3wa1q1wEBG+BOho2ef1VAgJBaFRkOKWX0beFquKIKCaW6mmuCK9W+8Ky88OTvGepD+3uwqDbAAAAA=="
        ))
        let compressed = fixture.root.appending(path: "Diagram.SVGZ")
        try bytes.write(to: compressed)
        let xml = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10"><rect width="20" height="10" fill="teal"/></svg>"#
        let original = try fixture.file("Diagram.svg", text: xml)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(compressed, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let message = window.staticTexts["Compressed SVG is not supported. Open an uncompressed SVG file."]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        let preview = WorkspaceUITestSupport.element("bailey.svg.preview", in: app)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(message.exists)
        XCTAssertFalse(preview.exists)
        XCTAssertFalse(window.textViews.firstMatch.exists)
        WorkspaceUITestSupport.fileRow(original, in: window).doubleClick()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: compressed), bytes)
        XCTAssertEqual(try Data(contentsOf: original), Data(xml.utf8))
    }

    func testSVGPreviewByteBudgetKeepsTheOverLimitDocumentAvailableAsSource() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let prefix = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"180\" height=\"120\">\n<!--"
        let suffix = "--><rect width=\"180\" height=\"120\" fill=\"red\"/></svg>"
        let byteLimit = 1 << 20
        let remaining = byteLimit - prefix.utf8.count - suffix.utf8.count
        let line = String(repeating: " ", count: 1023) + "\n"
        let exact = prefix + String(repeating: line, count: remaining / 1024)
            + String(repeating: " ", count: remaining % 1024) + suffix
        let overflow = exact + "\n"
        XCTAssertEqual(exact.utf8.count, byteLimit)
        XCTAssertEqual(overflow.utf8.count, byteLimit + 1)
        let accepted = try fixture.file("Exact.svg", text: exact)
        let tooLarge = try fixture.file("Overflow.svg", text: overflow)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        func open(_ url: URL) {
            let row = WorkspaceUITestSupport.fileRow(url, in: window)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
        }

        open(accepted)
        let preview = WorkspaceUITestSupport.element("bailey.svg.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let bitmap = NSBitmapImageRep(data: preview.screenshot().pngRepresentation),
                  let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
            else { return false }
            return color.redComponent - color.greenComponent > 0.45
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 8), .completed)

        open(tooLarge)
        let reason = "SVG is too large to preview. You can still edit the source."
        let message = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", reason, reason)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertFalse(preview.exists)
        WorkspaceUITestSupport.element("bailey.svg.showSource", in: app).click()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, overflow)
        XCTAssertEqual(try Data(contentsOf: accepted), Data(exact.utf8))
        XCTAssertEqual(try Data(contentsOf: tooLarge), Data(overflow.utf8))
    }
}
