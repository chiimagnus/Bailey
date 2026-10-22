import AppKit
import XCTest
@testable import Bailey

@MainActor
final class NativeEditorCompositionTests: XCTestCase {
    private func beginComposition(_ editor: NativeCodeTextView) {
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
        let editor = NativeCodeTextView()
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
        let text = try XCTUnwrap(editor.nativeContentManager.attributedString(in: nil))
        XCTAssertNil(text.attribute(.underlineStyle, at: 7, effectiveRange: nil))
        XCTAssertEqual(text.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor, .systemBlue)
        XCTAssertEqual(text.attribute(.font, at: 7, effectiveRange: nil) as? NSFont, font)
        editor.unmarkText()
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(reference.string.utf8))
    }

    func testCompositionWithImplicitReplacementReplacesSelectedTextAndRestoresUndo() throws {
        let editor = NativeCodeTextView()
        let reference = NSTextView()
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        native.isReleasedWhenClosed = false
        defer { host.close(); native.close() }
        host.contentView = editor
        native.contentView = reference
        editor.allowsUndo = true
        reference.allowsUndo = true
        editor.text = "before after"
        reference.string = "before after"
        editor.textSelection = NSRange(location: 7, length: 5)
        reference.setSelectedRange(NSRange(location: 7, length: 5))
        XCTAssertEqual(editor.selectedRange(), reference.selectedRange())
        editor.setMarkedText("中文👋", selectedRange: NSRange(location: 4, length: 0), replacementRange: .notFound)
        reference.setMarkedText("中文👋", selectedRange: NSRange(location: 4, length: 0), replacementRange: .notFound)
        XCTAssertEqual(editor.text, reference.string, "Composing over a selection must replace, not duplicate it")
        editor.unmarkText()
        reference.unmarkText()
        XCTAssertEqual(editor.text, reference.string)
        editor.undoManager?.undo()
        reference.undoManager?.undo()
        XCTAssertEqual(editor.text, reference.string)
        XCTAssertEqual(editor.text, "before after")
    }

    func testAttachedInputGeometryRemainsUsable() throws {
        let editor = NativeCodeTextView()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scroll
        editor.text = "hello 中文 👋\nsecond line\n"
        window.orderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        editor.nativeLayoutManager.ensureLayout(for: editor.nativeContentManager.documentRange)
        var actual = NSRange(location: NSNotFound, length: 0)
        let requested = NSRange(location: 0, length: (editor.text ?? "").utf16.count)
        let rect = editor.firstRect(forCharacterRange: requested, actualRange: &actual)
        XCTAssertFalse(rect.isEmpty)
        XCTAssertNotEqual(actual.location, NSNotFound, "Multiline queries must return the first line's actual range")
        XCTAssertLessThan(actual.length, requested.length)
        let index = editor.characterIndex(for: CGPoint(x: rect.minX + 2, y: rect.midY))
        XCTAssertTrue(index >= 0 && index < (editor.text ?? "").utf16.count, "\(index)")
    }

    func testInputGeometryAfterEditorDetachesDoesNotUseDisposedWindow() {
        let editor = NativeCodeTextView()
        editor.text = "中文 👋"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.layoutIfNeeded()
        window.contentView = nil
        XCTAssertNil(editor.window)
        XCTAssertEqual(editor.characterIndex(for: .zero), NSNotFound)
        XCTAssertEqual(editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil), .zero)
        window.close()
    }

    func testUnicodeCompositionSelectionMatrixMatchesSystem() throws {
        let initial = "α👩🏽‍💻Z\r\n尾巴"
        let selectedRanges = [
            NSRange(location: 0, length: 0),
            (initial as NSString).range(of: "👩🏽‍💻"),
            (initial as NSString).range(of: "尾巴"),
        ]
        for range in selectedRanges {
            for completesWithInsert in [false, true] {
                let editor = NativeCodeTextView()
                let reference = NSTextView()
                editor.allowsUndo = true
                reference.allowsUndo = true
                let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
                let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
                host.isReleasedWhenClosed = false
                native.isReleasedWhenClosed = false
                defer { host.close(); native.close() }
                host.contentView = editor
                native.contentView = reference
                editor.text = initial
                reference.string = initial
                editor.textSelection = range
                reference.setSelectedRange(range)
                let candidate = "👋e\u{301}"
                editor.setMarkedText(candidate, selectedRange: NSRange(location: (candidate as NSString).length, length: 0), replacementRange: .notFound)
                reference.setMarkedText(candidate, selectedRange: NSRange(location: (candidate as NSString).length, length: 0), replacementRange: .notFound)
                editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: .notFound)
                reference.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: .notFound)
                XCTAssertEqual(Data((editor.text ?? "").utf8), Data(reference.string.utf8), "mark \(range)")
                if completesWithInsert {
                    editor.insertText("完成", replacementRange: .notFound)
                    reference.insertText("完成", replacementRange: .notFound)
                } else {
                    editor.unmarkText()
                    reference.unmarkText()
                }
                XCTAssertEqual(Data((editor.text ?? "").utf8), Data(reference.string.utf8), "finish \(range), \(completesWithInsert)")
                editor.undoManager?.undo()
                reference.undoManager?.undo()
                XCTAssertEqual(Data((editor.text ?? "").utf8), Data(reference.string.utf8), "undo \(range), \(completesWithInsert)")
                editor.undoManager?.redo()
                reference.undoManager?.redo()
                XCTAssertEqual(Data((editor.text ?? "").utf8), Data(reference.string.utf8), "redo \(range), \(completesWithInsert)")
            }
        }
    }

    func testDirectUnmarkUndoMatchesNativeTextView() throws {
        for replacedLength in [0, 5] {
            let editor = NativeCodeTextView()
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
        let editor = NativeCodeTextView()
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
            let editor = NativeCodeTextView()
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

    func testNativeMultipleSelectionsShareDocumentAndUndo() throws {
        let editor = NativeCodeTextView()
        editor.text = "first second third"
        editor.selectedRanges = [NSValue(range: NSRange(location: 0, length: 5)),
                                 NSValue(range: NSRange(location: 13, length: 5))]
        XCTAssertEqual(editor.selectedRanges.map(\.rangeValue),
                       [NSRange(location: 0, length: 5), NSRange(location: 13, length: 5)])
        editor.insertText("X", replacementRange: .notFound)
        editor.breakUndoCoalescing()
        XCTAssertEqual(editor.text, "X second X")
        XCTAssertEqual(editor.nativeLayoutManager.textSelections.count, 2)
        editor.insertText("Y", replacementRange: .notFound)
        XCTAssertEqual(editor.text, "XY second XY")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.text, "X second X")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.text, "first second third")
        editor.undoManager?.redo()
        editor.undoManager?.redo()
        XCTAssertEqual(editor.text, "XY second XY")
    }

    func testOrdinaryInputAndSelectedReplacementKeepUndo() throws {
        let editor = NativeCodeTextView()
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
