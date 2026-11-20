import Foundation
import XCTest

@MainActor
final class MarkdownPreviewUITests: XCTestCase {
    func testFileMenuPreviewsMDXWithoutSavingAndKeepsTheNativeUndo() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = "---\nname: skill\n---\n# Native Markdown preview\n\n<Widget value={1} />\n"
        let markdown = try fixture.file("SKILL.mdx", text: source)
        let plain = try fixture.file("plain.txt", text: "plain")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let fileMenu = app.menuBars.menuBarItems["File"]
        let showPreview = app.menuItems["Show Preview"]
        let showSource = app.menuItems["Show Source"]
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)

        guard fileMenu.waitForExistence(timeout: 10) else { return XCTFail("File menu is not accessible") }
        fileMenu.click()
        XCTAssertTrue(showPreview.exists)
        XCTAssertFalse(showPreview.isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        let plainRow = WorkspaceUITestSupport.fileRow(plain, in: window)
        XCTAssertTrue(plainRow.waitForExistence(timeout: 20))
        plainRow.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(plain, in: window).waitForExistence(timeout: 15))
        fileMenu.click()
        XCTAssertTrue(showPreview.exists)
        XCTAssertFalse(showPreview.isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        let markdownRow = WorkspaceUITestSupport.fileRow(markdown, in: window)
        markdownRow.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(markdown, in: window)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        fileMenu.click()
        XCTAssertTrue(showPreview.isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("temporary")
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue(preview.staticTexts["Native Markdown preview"].waitForExistence(timeout: 15))
        XCTAssertEqual(try String(contentsOf: markdown, encoding: .utf8), source)
        XCTAssertTrue(tab.exists)

        fileMenu.click()
        XCTAssertTrue(showSource.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 15))
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String)?.hasSuffix("temporary") == true)
        editor.click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertEqual(try String(contentsOf: markdown, encoding: .utf8), source)
    }
}
