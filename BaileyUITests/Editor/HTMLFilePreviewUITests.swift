import AppKit
import XCTest

@MainActor
final class HTMLFilePreviewUITests: XCTestCase {
    func testHTMLUsesSystemMenuAndSharedDockWithoutSaving() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            <!doctype html>
            <style>body { background: #dbe8fa; } h1 { color: #143558; }</style>
            <h1>WebKit layout acceptance</h1>
            <script>document.querySelector('h1').textContent='Script must not execute';</script>
            """
        let file = try fixture.file("布局.HTM", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, source)
        let webView = window.webViews.firstMatch
        XCTAssertFalse(webView.exists)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(webView.waitForExistence(timeout: 10), window.debugDescription)
        let heading = webView.staticTexts.matching(identifier: "WebKit layout acceptance").firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), webView.debugDescription)
        XCTAssertFalse(webView.staticTexts["Script must not execute"].exists)
        XCTAssertFalse(editor.exists)

        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let split = WorkspaceUITestSupport.menuItem("Show Side by Side", in: app)
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.click()
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, source)
        heading.click()
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(webView.waitForNonExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
    }
}
