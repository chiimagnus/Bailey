import AppKit
import XCTest

@MainActor
final class HTMLExplicitBrowserUITests: XCTestCase {
    func testOpenSavedThenSaveAndOpenUsesOnlyTheExplicitlyChosenDiskVersion() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let saved = "<h1>Saved markup</h1><script>document.querySelector('h1').textContent='Saved executed'</script>"
        let suffix = "<script>document.querySelector('h1').textContent='Draft executed'</script>"
        let file = try fixture.file("Explicit.html", text: saved)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root,
                                                     clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        app.typeKey(.end, modifierFlags: .command)
        editor.typeText(suffix)
        XCTAssertEqual(editor.value as? String, saved + suffix)
        XCTAssertEqual(try Data(contentsOf: file), Data(saved.utf8))
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let savedOnly = WorkspaceUITestSupport.menuItem("Open Saved HTML in Browser", in: app)
        XCTAssertTrue(savedOnly.waitForExistence(timeout: 5))
        savedOnly.click()
        let executed = window.webViews.firstMatch.staticTexts["Saved executed"]
        XCTAssertTrue(executed.waitForExistence(timeout: 15), window.debugDescription)
        XCTAssertFalse(window.webViews.firstMatch.staticTexts["Draft executed"].exists)
        XCTAssertEqual(try Data(contentsOf: file), Data(saved.utf8))
        tab.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, saved + suffix)
        tab.rightClick()
        let saveAndOpen = WorkspaceUITestSupport.menuItem("Save and Open HTML in Browser", in: app)
        XCTAssertTrue(saveAndOpen.waitForExistence(timeout: 5))
        saveAndOpen.click()
        let draft = window.webViews.firstMatch.staticTexts["Draft executed"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15), window.debugDescription)
        XCTAssertEqual(try Data(contentsOf: file), Data((saved + suffix).utf8))
    }
}
