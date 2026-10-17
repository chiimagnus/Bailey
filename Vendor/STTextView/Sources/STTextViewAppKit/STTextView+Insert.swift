//  Created by Marcin Krzyzanowski
//  https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md

import AppKit

extension STTextView {

    override open func insertLineBreak(_ sender: Any?) {
        insertText("\u{2028}", replacementRange: .notFound)
    }

    override open func insertTab(_ sender: Any?) {
        insertText("\t", replacementRange: .notFound)
    }

    override open func insertBacktab(_ sender: Any?) {
        insertText("\u{19}", replacementRange: .notFound)
    }

    override open func insertTabIgnoringFieldEditor(_ sender: Any?) {
        insertTab(sender)
    }

    override open func insertParagraphSeparator(_ sender: Any?) {
        insertText("\u{2029}", replacementRange: .notFound)
    }

    override open func insertNewline(_ sender: Any?) {
        // insert newline with current typing attributes
        breakUndoCoalescing()
        insertText("\n")
        breakUndoCoalescing()
    }

    override open func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        insertNewline(sender)
    }

    override open func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: .notFound)
    }

}
