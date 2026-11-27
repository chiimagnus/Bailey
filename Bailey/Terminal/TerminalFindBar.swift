import SwiftUI

struct TerminalFindBar: View {
    @Bindable var find: TerminalFind

    var body: some View {
        FindWidget(query: $find.query, count: countLabel, hasMatches: (find.total ?? 0) > 0,
                   noResults: find.total == 0 && !find.query.isEmpty,
                   focusRequest: find.focusRequest, canFocus: { find.isPresented && find.canFocusSource },
                   navigate: find.navigate, dismiss: find.dismiss, restoreFocus: find.restoreTerminalFocus,
                   options: { EmptyView() }, replacement: { _, _ in EmptyView() })
    }

    private var countLabel: String {
        guard !find.query.isEmpty, let total = find.total else { return "" }
        if total == 0 { return String(localized: "No matches", table: "Interface") }
        return String(localized: "\(find.selected.map { String(min($0 + 1, total)) } ?? "?") of \(total)", table: "Editor")
    }
}
