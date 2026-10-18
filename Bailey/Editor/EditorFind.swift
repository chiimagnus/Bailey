import AppKit

/// Find and replace inside a file tab's editor.
///
/// NSTextView already carries the AppKit find interface — an `NSTextFinder`
/// over the document, with the search-and-replace bar hosted by the editor's
/// enclosing scroll view — so all that is left is translating bailey's Find menu
/// into finder actions and aiming them at the text view this file is currently
/// mounted in.
extension FileTab {
    /// The mounted editor's text view, or nil while this file has no pane on
    /// screen: `editorView` is weak and lives only as long as the editor does.
    var textView: NativeCodeTextView? {
        (editorView as? NSScrollView)?.documentView as? NativeCodeTextView
    }

    func performFindAction(_ action: FindAction) {
        guard let textView else { return }
        let finderAction: NSTextFinder.Action =
            switch action {
            case .show: .showFindInterface
            case .replace: .showReplaceInterface
            case .hide: .hideFindInterface
            case .next: .nextMatch
            case .previous: .previousMatch
            case .useSelection: .setSearchString
            }
        // Asking for the next match before anything has been searched for, or
        // for the selection with none, does nothing rather than beeping.
        let item = NSMenuItem()
        item.tag = finderAction.rawValue
        textView.performFindPanelAction(item)
    }
}
