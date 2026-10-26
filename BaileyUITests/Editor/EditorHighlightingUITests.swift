import AppKit
import XCTest

@MainActor
final class EditorHighlightingUITests: XCTestCase {
    func testSwiftSyntaxColorsDifferFromPlainTextWithoutChangingFileBytes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = "func greeting() -> Int {\n    let count = 42 // 中文 👋\n    return count\n}\n"
        let plain = try fixture.file("a-plain.txt", text: source)
        let swift = try fixture.file("b-highlight.swift", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, project: fixture.root)
        let window = app.windows.firstMatch
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))

        files.click()
        let plainRow = WorkspaceUITestSupport.fileRow(plain, in: window)
        XCTAssertTrue(plainRow.waitForExistence(timeout: 15))
        plainRow.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, source)
        let plainScreenshot = editor.screenshot()

        files.click()
        let swiftRow = WorkspaceUITestSupport.fileRow(swift, in: window)
        XCTAssertTrue(swiftRow.waitForExistence(timeout: 15))
        swiftRow.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(swift, in: window)
            .waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, source)
        let swiftScreenshot = editor.screenshot()

        for (name, screenshot) in [("Plain text", plainScreenshot),
                                   ("Swift syntax", swiftScreenshot)] {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertGreaterThan(try changedTextSamples(plainScreenshot, swiftScreenshot), 24,
                             "Swift keywords and comments must render differently from plain text")
        XCTAssertEqual(try Data(contentsOf: plain), Data(source.utf8))
        XCTAssertEqual(try Data(contentsOf: swift), Data(source.utf8))
    }

    private func changedTextSamples(
        _ plain: XCUIScreenshot, _ highlighted: XCUIScreenshot
    ) throws -> Int {
        let plainBitmap = try XCTUnwrap(NSBitmapImageRep(
            data: try XCTUnwrap(plain.image.tiffRepresentation)))
        let highlightedBitmap = try XCTUnwrap(NSBitmapImageRep(
            data: try XCTUnwrap(highlighted.image.tiffRepresentation)))
        XCTAssertEqual(plainBitmap.pixelsWide, highlightedBitmap.pixelsWide)
        XCTAssertEqual(plainBitmap.pixelsHigh, highlightedBitmap.pixelsHigh)
        // Sample identical native text viewports, excluding tab titles and toolbars.
        let width = min(plainBitmap.pixelsWide, highlightedBitmap.pixelsWide)
        let height = min(plainBitmap.pixelsHigh, highlightedBitmap.pixelsHigh)
        var changed = 0
        for y in stride(from: 8, to: min(height, 180), by: 2) {
            for x in stride(from: min(80, width / 4), to: min(width, 800), by: 2) {
                guard let before = plainBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let after = highlightedBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let delta = max(
                    abs(before.redComponent - after.redComponent),
                    abs(before.greenComponent - after.greenComponent),
                    abs(before.blueComponent - after.blueComponent)
                )
                if delta > 0.12 { changed += 1 }
            }
        }
        return changed
    }
}
