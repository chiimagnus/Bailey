import AppKit
import XCTest

@MainActor
final class HTMLFilePreviewUITests: XCTestCase {
    func testBackgroundTabMenuAndSystemShortcutKeepTheirOwnWindowTargets() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let backgroundSource = "<!doctype html><h1>Background HTML</h1>"
        let foregroundSource = "<!doctype html><h1>Foreground HTML</h1>"
        let otherSource = "<!doctype html><h1>Other window HTML</h1>"
        let backgroundFile = try fixture.file("one/shared.html", text: backgroundSource)
        let foregroundFile = try fixture.file("one/visible.html", text: foregroundSource)
        let otherFile = try fixture.file("two/shared.html", text: otherSource)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: backgroundFile.deletingLastPathComponent()
        )
        let firstID = app.windows.firstMatch.identifier
        let first = app.windows.matching(identifier: firstID).firstMatch
        func open(_ file: URL, in window: XCUIElement) {
            let row = WorkspaceUITestSupport.fileRow(file, in: window)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
        }
        func heading(_ title: String, in window: XCUIElement) -> XCUIElement {
            window.webViews.firstMatch.staticTexts.matching(identifier: title).firstMatch
        }

        open(backgroundFile, in: first)
        let background = WorkspaceUITestSupport.fileTab(backgroundFile, in: first)
        XCTAssertTrue(background.waitForExistence(timeout: 10))
        open(foregroundFile, in: first)
        XCTAssertTrue(first.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let foregroundHeading = heading("Foreground HTML", in: first)
        XCTAssertTrue(foregroundHeading.waitForExistence(timeout: 10))
        XCTAssertFalse(background.isSelected)

        background.rightClick()
        let menu = app.menus.containing(.menuItem, identifier: "Close Others").firstMatch
        let show = WorkspaceUITestSupport.menuItem("Show Preview", in: menu)
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.click()
        XCTAssertTrue(foregroundHeading.exists)
        XCTAssertFalse(background.isSelected)
        background.click()
        let backgroundHeading = heading("Background HTML", in: first)
        XCTAssertTrue(backgroundHeading.waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: [.command, .shift])
        let second = app.windows.matching(NSPredicate(format: "identifier != %@", firstID)).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 15))
        try WorkspaceUITestSupport.addFolder(otherFile.deletingLastPathComponent(), to: app, in: second)
        second.descendants(matching: .any).matching(identifier: "bailey.dock.files").firstMatch.click()
        open(otherFile, in: second)
        let editor = second.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, otherSource)
        app.typeKey("v", modifierFlags: [.command, .shift])
        let otherHeading = heading("Other window HTML", in: second)
        XCTAssertTrue(otherHeading.waitForExistence(timeout: 10))
        XCTAssertTrue(backgroundHeading.exists)
        otherHeading.click()
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(second.webViews.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, otherSource)
        XCTAssertTrue(backgroundHeading.exists)
        XCTAssertEqual(try Data(contentsOf: backgroundFile), Data(backgroundSource.utf8))
        XCTAssertEqual(try Data(contentsOf: foregroundFile), Data(foregroundSource.utf8))
        XCTAssertEqual(try Data(contentsOf: otherFile), Data(otherSource.utf8))
    }

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
            in: self, language: "en", project: fixture.root
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
        editor.click()
        let initialFieldCount = window.textFields.count + window.searchFields.count
        app.typeKey("f", modifierFlags: .command)
        let nativeFind = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.textFields.count + window.searchFields.count > initialFieldCount
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [nativeFind], timeout: 5), .completed)
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
        let clipboard = NSPasteboard.general
        let initialClipboardVersion = clipboard.changeCount
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            clipboard.changeCount != initialClipboardVersion
                && clipboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "WebKit layout acceptance"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 5), .completed)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(webView.waitForNonExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
    }
}
