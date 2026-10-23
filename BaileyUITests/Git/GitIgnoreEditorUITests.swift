import Foundation
import XCTest

@MainActor
final class GitIgnoreEditorUITests: XCTestCase {
    func testIgnoreUpdatesOpenNativeEditorAndCommandZCanUndoTheInsertedPatterns() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let ignore = try fixture.file(".gitignore", text: "existing-rule\n")
        try fixture.initializeGit()
        let newFile = try fixture.file("literal*.txt", text: "untracked\n")
        let beforeEdit = "existing-rule\nunsaved-rule"
        let originalHead = try fixture.git(["rev-parse", "HEAD"])
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let window = app.windows.firstMatch

        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let ignoreRow = WorkspaceUITestSupport.fileRow(ignore, in: window)
        XCTAssertTrue(ignoreRow.waitForExistence(timeout: 15))
        ignoreRow.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(ignore, in: window)
            .waitForExistence(timeout: 15))
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        editor.typeText(beforeEdit)
        XCTAssertEqual(editor.value as? String, beforeEdit)
        XCTAssertEqual(try Data(contentsOf: ignore), Data("existing-rule\n".utf8),
                       "Typing must modify the native buffer before an explicit save")

        app.typeKey("g", modifierFlags: [.command, .shift])
        let untracked = WorkspaceUITestSupport.fileRow(newFile, in: window,
                                                      relativeTo: fixture.root)
        XCTAssertTrue(untracked.waitForExistence(timeout: 25))
        untracked.rightClick()
        let addIgnore = app.menuItems.matching(NSPredicate(
            format: "title IN %@", ["Add to .gitignore", "添加到 .gitignore"]
        )).firstMatch
        XCTAssertTrue(addIgnore.waitForExistence(timeout: 8))
        addIgnore.click()
        let ignoredOnDisk = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? fixture.git(["check-ignore", "--no-index", "--", "literal*.txt"])) != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ignoredOnDisk], timeout: 20), .completed)
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(ignore, in: window).exists,
                      "Git Ignore must reuse the existing file tab rather than duplicate it")
        let reused = window.textViews.firstMatch
        XCTAssertTrue(reused.waitForExistence(timeout: 15))
        let inserted = reused.value as? String ?? ""
        XCTAssertTrue(inserted.hasPrefix(beforeEdit + "\n"))
        XCTAssertTrue(inserted.contains("/literal\\*.txt"),
                      "The appended .gitignore rule must escape the wildcard literally")

        reused.click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(reused.value as? String, beforeEdit,
                       "Native Command-Z must undo Git Ignore's inserted patterns")
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: ignore)) == Data(beforeEdit.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed)
        XCTAssertNil(try? fixture.git(["check-ignore", "--no-index", "--", "literal*.txt"]),
                     "Undo followed by save must make the file visible to Git again")
        XCTAssertEqual(try Data(contentsOf: newFile), Data("untracked\n".utf8))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), originalHead)
    }
}
