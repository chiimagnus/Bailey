import AppKit
import XCTest

@MainActor
final class EditorHighlightingUITests: XCTestCase {
    func testSwiftSyntaxColorsDifferFromPlainTextWithoutChangingFileBytes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = "func greeting() -> Int {\n    let count = 42 // 中文 👋\n    return count\n}\n"
        let plain = try fixture.file("a-plain.txt", text: source)
        let swift = try fixture.file("b-highlight.swift", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self)

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
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

    func testEmbeddedAndTSXColorsReachTheRealEditor() throws {
        let examples: [(name: String, ext: String, text: String)] = [
            ("markdown", "md", "# 中文标题 👋\n```swift\nfunc greeting() -> Int { return 42 }\n```\n"),
            ("tsx", "tsx", "type Props = { title: string };\nexport function Card({ title }: Props) {\n    return <section className=\"card\">{title}</section>;\n}\n"),
            ("html", "html", "<div class=\"card\">中文 👋</div>\n<script>\nconst count = 42;\n</script>\n<style>.card { color: red; }</style>\n"),
            ("css", "css", "@media screen and (min-width: 400px) {\n    .card { color: #abcdef; font-size: 18px; }\n}\n")
        ]
        let fixture = try WorkspaceUITestFixture(in: self)
        let files = try examples.map { example in
            (example: example,
             plain: try fixture.file("a-\(example.name).txt", text: example.text),
             highlighted: try fixture.file("b-\(example.name).\(example.ext)", text: example.text))
        }
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let window = app.windows.firstMatch
        let fileManager = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(fileManager.waitForExistence(timeout: 15))
        let editor = window.textViews.firstMatch

        for pair in files {
            func screenshot(of url: URL) -> XCUIScreenshot {
                fileManager.click()
                let row = WorkspaceUITestSupport.fileRow(url, in: window)
                XCTAssertTrue(row.waitForExistence(timeout: 15), "Missing fixture row: \(url.lastPathComponent)")
                row.doubleClick()
                XCTAssertTrue(WorkspaceUITestSupport.fileTab(url, in: window)
                    .waitForExistence(timeout: 15))
                XCTAssertTrue(editor.waitForExistence(timeout: 15))
                XCTAssertEqual(editor.value as? String, pair.example.text)
                return editor.screenshot()
            }

            let plain = screenshot(of: pair.plain)
            let highlighted = screenshot(of: pair.highlighted)
            for (kind, screenshot) in [("plain", plain), ("syntax", highlighted)] {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "\(pair.example.name)-\(kind)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertGreaterThan(try changedTextSamples(plain, highlighted), 24,
                                 "\(pair.example.ext) must highlight visible syntax, including embedded code")
            XCTAssertEqual(try Data(contentsOf: pair.plain), Data(pair.example.text.utf8))
            XCTAssertEqual(try Data(contentsOf: pair.highlighted), Data(pair.example.text.utf8))
        }
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
