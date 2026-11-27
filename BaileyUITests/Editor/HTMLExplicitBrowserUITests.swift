import AppKit
import XCTest

@MainActor
final class HTMLExplicitBrowserUITests: XCTestCase {
    func testOpenSavedThenSaveAndOpenUsesOnlyTheExplicitlyChosenDiskVersion() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let saved = #"<!doctype html><h1>Saved revision</h1><script src="assets/run.js"></script>"#
        let draft = saved.replacingOccurrences(of: "Saved revision", with: "Draft revision")
        let file = try fixture.file("Run.html", text: saved)
        let script = "document.querySelector('h1').textContent += ' executed';"
        let scriptFile = try fixture.file("assets/run.js", text: script)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        tab.rightClick()
        let menu = app.menus.containing(.menuItem, identifier: "Reveal in File Manager").firstMatch
        let split = WorkspaceUITestSupport.menuItem("Show Side by Side", in: menu)
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.click()
        func heading(_ text: String) -> XCUIElement {
            window.webViews.firstMatch.staticTexts.matching(identifier: text).firstMatch
        }
        XCTAssertTrue(heading("Saved revision").waitForExistence(timeout: 10))
        XCTAssertFalse(heading("Saved revision executed").exists)

        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(draft, forType: .string))
        editor.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, draft)
        XCTAssertTrue(heading("Draft revision").waitForExistence(timeout: 10))
        XCTAssertFalse(heading("Draft revision executed").exists)
        XCTAssertEqual(try Data(contentsOf: file), Data(saved.utf8),
                       "Refreshing the preview while editing must not publish the draft")

        tab.rightClick()
        let runSaved = WorkspaceUITestSupport.menuItem("Open Saved HTML in Browser", in: menu)
        XCTAssertTrue(runSaved.waitForExistence(timeout: 5))
        runSaved.click()
        XCTAssertTrue(heading("Saved revision executed").waitForExistence(timeout: 20),
                      "The normal Browser must load the actual saved file and its relative script")
        XCTAssertFalse(heading("Draft revision executed").exists)
        XCTAssertEqual(try Data(contentsOf: file), Data(saved.utf8))

        tab.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, draft)
        XCTAssertTrue(heading("Draft revision").waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: file), Data(saved.utf8))
        tab.rightClick()
        let saveAndRun = WorkspaceUITestSupport.menuItem("Save and Open HTML in Browser", in: menu)
        XCTAssertTrue(saveAndRun.waitForExistence(timeout: 5))
        saveAndRun.click()
        XCTAssertTrue(heading("Draft revision executed").waitForExistence(timeout: 20))
        XCTAssertEqual(try Data(contentsOf: file), Data(draft.utf8))
        XCTAssertEqual(try Data(contentsOf: scriptFile), Data(script.utf8))
    }
}
