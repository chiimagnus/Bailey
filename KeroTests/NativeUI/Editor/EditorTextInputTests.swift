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

    func testDirectUnmarkUndoMatchesNativeTextView() throws {
        for replacedLength in [0, 5] {
            let editor = STTextView()
            let reference = NSTextView()
            editor.allowsUndo = true
            reference.allowsUndo = true
            let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                                        styleMask: [.titled], backing: .buffered, defer: false)
            let referenceWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                                           styleMask: [.titled], backing: .buffered, defer: false)
            editorWindow.isReleasedWhenClosed = false
            referenceWindow.isReleasedWhenClosed = false
            defer { editorWindow.close(); referenceWindow.close() }
            editorWindow.contentView = editor
            referenceWindow.contentView = reference
            editor.text = "before after"
            reference.string = "before after"
            let range = NSRange(location: 7, length: replacedLength)
            editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: range)
            reference.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: range)
            editor.setMarkedText("中文👋", selectedRange: NSRange(location: 4, length: 0), replacementRange: .notFound)
            reference.setMarkedText("中文👋", selectedRange: NSRange(location: 4, length: 0), replacementRange: .notFound)
            editor.unmarkText()
            reference.unmarkText()
            XCTAssertEqual(editor.text, reference.string)
            let expectedUndo = reference.undoManager?.canUndo ?? false
            XCTAssertEqual(editor.undoManager?.canUndo ?? false, expectedUndo,
                           "Accepting a completed composition should keep native undo semantics")
            if expectedUndo {
                editor.undoManager?.undo()
                reference.undoManager?.undo()
                XCTAssertEqual(editor.text, reference.string)
                editor.undoManager?.redo()
                reference.undoManager?.redo()
                XCTAssertEqual(editor.text, reference.string)
            }
        }
    }

    func testCompositionReplacingExistingTextRestoresOriginalOnUndo() throws {
        let editor = STTextView()
        let reference = NSTextView()
        editor.allowsUndo = true
        reference.allowsUndo = true
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: false)
        let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        native.isReleasedWhenClosed = false
        defer { host.close(); native.close() }
        host.contentView = editor
        native.contentView = reference
        editor.text = "before after"
        reference.string = "before after"
        let range = NSRange(location: 7, length: 5)
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: range)
        reference.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: range)
        editor.setMarkedText("中文👋", selectedRange: NSRange(location: 4, length: 0), replacementRange: .notFound)
        reference.setMarkedText("中文👋", selectedRange: NSRange(location: 4, length: 0), replacementRange: .notFound)
        editor.insertText("完成", replacementRange: .notFound)
        reference.insertText("完成", replacementRange: .notFound)
        XCTAssertEqual(editor.text, reference.string)
        editor.undoManager?.undo()
        reference.undoManager?.undo()
        XCTAssertEqual(editor.text, reference.string)
        XCTAssertEqual(reference.string, "before after")
        editor.undoManager?.redo()
        reference.undoManager?.redo()
        XCTAssertEqual(editor.text, reference.string)
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
