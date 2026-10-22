import Foundation
import XCTest

@MainActor
final class EditorNavigationUITests: XCTestCase {
    func testDistantNavigationKeepsBothEndsEditableAndPersistsBytes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "header\n" + String(repeating: "let value = \"中文 👋\"\n", count: 10_000)
            + "footer\n"
        let file = try fixture.file("navigation.swift", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        WorkspaceUITestSupport.element("bailey.dock.files", in: app).click()
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: app.windows.firstMatch)
            .waitForExistence(timeout: 15))

        let editor = app.windows.firstMatch.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        editor.click()
        for jump in 0..<17 {
            app.typeKey(jump.isMultiple(of: 2) ? .downArrow : .upArrow,
                        modifierFlags: .command)
        }
        editor.typeText("__TAIL_MARKER__")
        app.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("__HEAD_MARKER__")
        app.typeKey("s", modifierFlags: .command)

        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return value == "__HEAD_MARKER__" + original + "__TAIL_MARKER__"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed,
                       "A large document must preserve both far-away edits and all intervening bytes")
    }

    func testHundredThousandLineNavigationPreservesAllInterveningBytes() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "first\n" + String(repeating: "let value = 12345\n", count: 100_000)
            + "last\n"
        let file = try fixture.file("large.swift", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        files.click()
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.doubleClick()
        let editor = app.windows.firstMatch.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        editor.click()
        for step in 0..<17 {
            app.typeKey(step.isMultiple(of: 2) ? .downArrow : .upArrow,
                        modifierFlags: .command)
        }
        editor.typeText("TAIL_")
        app.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("HEAD_")
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8))
                == "HEAD_" + original + "TAIL_"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 30), .completed,
                       "Navigating 100,000 lines must not discard distant edits or middle bytes")
    }

    func testUnicodeReplacementUndoRedoAndRealSave() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "before 👩🏽‍💻 after\n"
        let file = try fixture.file("unicode.swift", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self)
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        app.typeKey("e", modifierFlags: [.command, .shift])
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: app.windows.firstMatch)
            .waitForExistence(timeout: 15))
        let editor = app.windows.firstMatch.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("x", modifierFlags: [])
        XCTAssertEqual(editor.value as? String, "x")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, original,
                       "Undo must restore the actual native text view before saving")
        app.typeKey("s", modifierFlags: .command)
        let undone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8)) == original
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [undone], timeout: 10), .completed,
                       "Undo must restore original Unicode bytes")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(editor.value as? String, "x",
                       "Redo must update the native editor")
        app.typeKey("s", modifierFlags: .command)
        let redone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8)) == "x"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [redone], timeout: 10), .completed,
                       "Redo must persist the exact replacement bytes")

        app.typeKey("a", modifierFlags: .command)
        editor.typeText("中文👋")
        XCTAssertEqual(editor.value as? String, "中文👋")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "x",
                       "Unicode insertion must participate in native Undo")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(editor.value as? String, "中文👋",
                       "Redo must restore inserted Unicode text")
        app.typeKey("s", modifierFlags: .command)
        let unicodeSaved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8)) == "中文👋"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unicodeSaved], timeout: 10), .completed)
    }
}
