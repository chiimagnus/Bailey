import SwiftUI

struct PanelContentView: View {
    private let themeChanges = Theme.changes
    let tab: PaneTab
    var isSelected: Bool
    var onFocused: () -> Void
    var onNewBrowserTab: (String?) -> Void
    var onNewFileTab: (String) -> Void

    var body: some View {
        let _ = themeChanges.revision
        Group {
            switch tab.content {
            case .session(let session):
                TerminalHostView(
                    session: session,
                    isFocused: isSelected,
                    onFocused: onFocused,
                    onNewBrowserTab: onNewBrowserTab,
                    onNewFileTab: onNewFileTab
                )
                .overlay(alignment: .topTrailing) {
                    TerminalFindOverlay(find: session.find)
                }
            case .file(let file):
                FileViewerView(file: file, isFocused: isSelected, onFocused: onFocused)
            case .browser(let browser):
                BrowserView(
                    browser: browser,
                    isFocused: isSelected,
                    onFocused: onFocused,
                    onNewBrowserTab: onNewBrowserTab
                )
            case .diff(let diff):
                DiffViewerView(diff: diff, isSelected: true)
            }
        }
        .background(Color(nsColor: Theme.background))
    }
}
