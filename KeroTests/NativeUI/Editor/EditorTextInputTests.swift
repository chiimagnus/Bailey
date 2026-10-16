import AppKit
import STTextKitPlus
import STTextView
import XCTest

@MainActor
final class EditorTextInputTests: XCTestCase {
    private func beginComposition(_ editor: STTextView) {
        editor.text = "before after"
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 7, length: 0))
        editor.setMarkedText("中文👋", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func beginComposition(_ editor: NSTextView) {
        editor.string = "before after"
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 7, length: 0))
        editor.setMarkedText("中文👋", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func testUnmarkAcceptsCompositionLikeSystemTextViewAndClearsMarking() throws {
        let editor = STTextView()
        let reference = NSTextView()
        let font = NSFont.monospacedSystemFont(ofSize: 19, weight: .regular)
        editor.font = font
        editor.textColor = .systemBlue
        editor.markedTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue,
                                      .foregroundColor: NSColor.systemRed]
        beginComposition(editor)
        beginComposition(reference)
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(reference.string.utf8))
        reference.unmarkText()
        editor.unmarkText()
        XCTAssertEqual(reference.string, "before 中文👋after")
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(reference.string.utf8))
        XCTAssertFalse(editor.hasMarkedText())
        let text = try XCTUnwrap(editor.textContentManager.attributedString(in: nil))
        XCTAssertNil(text.attribute(.underlineStyle, at: 7, effectiveRange: nil))
        XCTAssertEqual(text.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor, .systemBlue)
        XCTAssertEqual(text.attribute(.font, at: 7, effectiveRange: nil) as? NSFont, font)
        editor.unmarkText()
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(reference.string.utf8))
    }

    func testFinalCompositionDefaultAndExplicitRangesMatchSystemAndKeepUndo() throws {
        for replacement in [NSRange(location: NSNotFound, length: 0),
                            NSRange(location: 7, length: 4), NSRange(location: 0, length: 11)] {
            let editor = STTextView()
            let reference = NSTextView()
            beginComposition(editor)
            beginComposition(reference)
            reference.insertText("完成", replacementRange: replacement)
            editor.insertText("完成", replacementRange: replacement)
            XCTAssertEqual(Data((editor.text ?? "").utf8), Data(reference.string.utf8), "\(replacement)")
            XCTAssertFalse(editor.hasMarkedText())
            editor.breakUndoCoalescing()
            let undo = try XCTUnwrap(editor.undoManager)
            XCTAssertTrue(undo.canUndo)
            undo.undo()
            XCTAssertEqual(editor.text, "before after")
            undo.redo()
            XCTAssertEqual(Data((editor.text ?? "").utf8), Data(reference.string.utf8))
        }
    }

    func testOrdinaryInputAndSelectedReplacementKeepUndo() throws {
        let editor = STTextView()
        editor.text = "before after"
        editor.insertText("中文👋", replacementRange: NSRange(location: 0, length: 6))
        editor.breakUndoCoalescing()
        XCTAssertEqual(editor.text, "中文👋 after")
        let undo = try XCTUnwrap(editor.undoManager)
        undo.undo()
        XCTAssertEqual(editor.text, "before after")
        undo.redo()
        XCTAssertEqual(editor.text, "中文👋 after")
    }
}
