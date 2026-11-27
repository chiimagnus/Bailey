import Foundation
import XCTest

@MainActor
final class FindWidgetUITests: XCTestCase {
    func testChineseFindOptionsKeepCompactAlignedControlsAndLocalizedActions() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "开发 alpha\n开发 ALPHA\n开发 alphabet\n"
        let file = try fixture.file("Find.txt", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "zh-Hans", project: fixture.root,
                                                    clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        let documentFrame = editor.frame
        app.typeKey("f", modifierFlags: .command)
        let query = window.textFields["bailey.find.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.click()
        query.typeKey("a", modifierFlags: .command)
        try WorkspaceUITestSupport.selectASCIIInputSource()
        query.typeText("alpha")
        let count = window.staticTexts["bailey.find.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let toggle = window.buttons["bailey.find.replace-toggle"]
        toggle.click()
        let replacement = window.textFields["bailey.find.replacement"]
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        let labels = [
            ("case", "区分大小写"), ("word", "全词匹配"),
            ("regex", "使用正则表达式"), ("preserve-case", "保留大小写")
        ]
        for (id, label) in labels {
            let button = window.buttons["bailey.find." + id]
            XCTAssertTrue(button.exists)
            XCTAssertEqual(button.label, label)
        }
        let close = window.buttons["bailey.find.close"]
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "FindChineseExpanded"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(close.frame.maxX - toggle.frame.minX, 355,
                                 "The complete find widget must be compact, not the old 419pt layout")
        let firstRow = [toggle, query] + ["case", "word", "regex"].map {
            window.buttons["bailey.find." + $0]
        } + [count] + ["previous", "next", "selection", "close"].map {
            window.buttons["bailey.find." + $0]
        }
        for (left, right) in zip(firstRow, firstRow.dropFirst()) {
            XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX + 1,
                                     "\(left.identifier) overlaps \(right.identifier)")
        }
        XCTAssertEqual(query.frame.minX, replacement.frame.minX, accuracy: 1)
        XCTAssertLessThanOrEqual(replacement.frame.minY - query.frame.minY, 26)
        XCTAssertEqual(editor.frame.minY, documentFrame.minY, accuracy: 1)
        XCTAssertEqual(editor.frame.height, documentFrame.height, accuracy: 1)
        let matchCase = window.buttons["bailey.find.case"]
        matchCase.click()
        window.buttons["bailey.find.word"].click()
        let one = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (count.value as? String ?? count.label) == "1 / 1"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [one], timeout: 5), .completed)
        window.buttons["bailey.find.regex"].click()
        query.click()
        query.typeKey("a", modifierFlags: .command)
        try WorkspaceUITestSupport.selectASCIIInputSource()
        query.typeText("alpha")
        replacement.click()
        try WorkspaceUITestSupport.selectASCIIInputSource()
        replacement.typeText("beta")
        window.buttons["bailey.find.preserve-case"].click()
        let replaceAll = window.buttons["bailey.find.replace-all"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: replaceAll)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        replaceAll.click()
        let expected = original.replacingOccurrences(of: "alpha", with: "beta", options: .literal,
                                                     range: original.range(of: "alpha"))
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.value as? String == expected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [edited], timeout: 5), .completed)
        close.click()
        XCTAssertTrue(query.waitForNonExistence(timeout: 5))
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == Data(expected.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
    }

    func testSourceFindUsesOneShortcutAndFloatingWidgetWithoutChangingDocumentGeometry() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "let first = \"alpha\"\nlet second = \"alpha\"\nlet third = \"ALPHA\"\n"
        let file = try fixture.file("Find.swift", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root,
                                                    clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, original)
        editor.click()
        let frame = editor.frame
        let query = window.textFields["bailey.find.query"]
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: .command)
        for _ in 0..<3 { app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .shift) }
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertEqual(query.value as? String, "let")
        editor.click()
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: .command)
        for _ in 0..<4 { app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: []) }
        for _ in 0..<5 { app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .shift) }
        app.typeKey("f", modifierFlags: .command)
        XCTAssertEqual(query.value as? String, "first")
        app.typeKey("f", modifierFlags: .command)
        XCTAssertEqual(query.value as? String, "first")
        try WorkspaceUITestSupport.selectASCIIInputSource()
        query.typeText("alpha")
        XCTAssertEqual(query.value as? String, "alpha")
        let count = window.staticTexts["bailey.find.count"]
        let matchCase = window.buttons["bailey.find.case"]
        XCTAssertTrue(matchCase.exists)
        matchCase.click()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let total = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (count.value as? String ?? count.label).hasSuffix(" of 2")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [total], timeout: 5), .completed)
        let next = window.buttons["bailey.find.next"]
        let previous = window.buttons["bailey.find.previous"]
        XCTAssertTrue(next.isEnabled && previous.isEnabled)
        next.click()
        let afterNext = count.value as? String ?? count.label
        previous.click()
        let beforeKeyboard = count.value as? String ?? count.label
        XCTAssertNotEqual(beforeKeyboard, afterNext)
        query.click()
        query.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let keyboardNext = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (count.value as? String ?? count.label) != beforeKeyboard
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardNext], timeout: 5), .completed)
        query.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .shift)
        let keyboardPrevious = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (count.value as? String ?? count.label) == beforeKeyboard
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardPrevious], timeout: 5), .completed)
        XCTAssertEqual(editor.frame.minY, frame.minY, accuracy: 2)
        XCTAssertEqual(editor.frame.height, frame.height, accuracy: 2)
        XCTAssertGreaterThanOrEqual(query.frame.minX, frame.maxX - 350 - 12)
        XCTAssertLessThan(query.frame.minY - frame.minY, 70)
        let closed = XCTAttachment(screenshot: window.screenshot())
        closed.name = "FindCollapsedNativeSymbols"
        closed.lifetime = .keepAlways
        add(closed)
        // The menu must contain one Find command; no duplicate navigation or replace shortcuts.
        let edit = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(edit.exists)
        edit.click()
        XCTAssertTrue(edit.menuItems["Find…"].exists)
        for title in ["Find Next", "Find Previous", "Use Selection for Find", "Find and Replace…"] {
            XCTAssertFalse(edit.menuItems[title].exists)
        }
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(query.exists)
        // Repeated Cmd-F selects the current query without opening another field.
        XCTAssertEqual(window.textFields.matching(identifier: "bailey.find.query").count, 1)
        window.buttons["bailey.find.replace-toggle"].click()
        let replacement = window.textFields["bailey.find.replacement"]
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        XCTAssertEqual(query.frame.minX, replacement.frame.minX, accuracy: 2)
        XCTAssertEqual(replacement.frame.minY - query.frame.minY, 25, accuracy: 2)
        XCTAssertTrue(window.buttons["bailey.find.selection"].exists)
        XCTAssertTrue(window.buttons["bailey.find.preserve-case"].exists)
        replacement.click()
        try WorkspaceUITestSupport.selectASCIIInputSource()
        replacement.typeText("beta")
        let replaceAll = window.buttons["bailey.find.replace-all"]
        XCTAssertTrue(replaceAll.isEnabled)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "FloatingFindReplace"
        attachment.lifetime = .keepAlways
        add(attachment)
        replaceAll.click()
        let changed = original.replacingOccurrences(of: "alpha", with: "beta")
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.value as? String == changed }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [edited], timeout: 5), .completed)
        window.buttons["bailey.find.close"].click()
        XCTAssertTrue(query.waitForNonExistence(timeout: 5))
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: file)) == Data(changed.utf8)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        app.typeKey("z", modifierFlags: .command)
        let undone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.value as? String == original }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [undone], timeout: 5), .completed)
    }
}
