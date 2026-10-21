import SwiftUI
import UniformTypeIdentifiers

struct PanelContentView: View {
    private let themeChanges = Theme.changes
    let tab: PaneTab
    var isFocused: Bool
    var canFocus: () -> Bool = { true }
    var onFocused: () -> Void
    var onNewBrowserTab: (String?) -> Void
    var onNewFileTab: (String) -> Void
    var onExternalFilesDropped: ([NSItemProvider]) -> Bool = { _ in false }

    var body: some View {
        let _ = themeChanges.revision
        Group {
            switch tab.content {
            case .session(let session):
                TerminalHostView(
                    session: session,
                    isFocused: isFocused,
                    canFocus: canFocus,
                    onFocused: onFocused,
                    onNewBrowserTab: onNewBrowserTab,
                    onNewFileTab: onNewFileTab
                )
                .overlay(alignment: .topTrailing) {
                    TerminalFindOverlay(find: session.find)
                }
            case .file(let file):
                FileViewerView(file: file, isFocused: isFocused, canFocus: canFocus, onFocused: onFocused)
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: onExternalFilesDropped)
            case .browser(let browser):
                BrowserView(
                    browser: browser,
                    isFocused: isFocused,
                    canFocus: canFocus,
                    onFocused: onFocused,
                    onNewBrowserTab: onNewBrowserTab,
                    onExternalFilesDropped: onExternalFilesDropped
                )
            case .diff(let diff):
                DiffViewerView(diff: diff, isSelected: true, isFocused: isFocused,
                               canFocus: canFocus, onFocused: onFocused)
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: onExternalFilesDropped)
            }
        }
        .background(Color(nsColor: Theme.background))
    }
}
