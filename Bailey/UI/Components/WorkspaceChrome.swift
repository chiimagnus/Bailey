import AppKit
import SwiftUI

/// A tab in the strip. Observes its content's live title and dirty state.
struct PaneTabItem: View {
    let tab: PaneTab
    let isDisplayed: Bool
    var isSelected = false
    var isKeyboardFocused = false
    let isPaneFocused: Bool
    let isContextTarget: Bool
    let select: () -> Void
    let close: () -> Void
    @Binding var renamingTabID: UUID?

    var body: some View {
        if renamingTabID == tab.id {
            TabRenameChrome(
                systemImage: tab.content.systemImage,
                browserIcon: focusedBrowser,
                fileIconPath: focusedFileIconPath,
                initialValue: tab.displayTitle,
                commit: { name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    tab.customName = trimmed.isEmpty ? nil : trimmed
                },
                end: { renamingTabID = nil }
            )
        } else {
            switch tab.content {
            case .session(let session):
                TabItemChrome(
                    systemImage: "terminal", title: tab.customName ?? session.title,
                    isDisplayed: isDisplayed, isSelected: isSelected,
                    isKeyboardFocused: isKeyboardFocused, isPaneFocused: isPaneFocused,
                    isContextTarget: isContextTarget, select: select, close: close
                )
            case .file(let file):
                TabItemChrome(
                    systemImage: "doc.text", fileIconPath: file.path,
                    title: tab.customName ?? file.name,
                    isDisplayed: isDisplayed, isSelected: isSelected,
                    isKeyboardFocused: isKeyboardFocused, isPaneFocused: isPaneFocused,
                    isContextTarget: isContextTarget, isDirty: file.isDirty,
                    select: select, close: close
                )
                .help(file.path)
                .accessibilityIdentifier("bailey.tab.file")
                .accessibilityValue(file.path)
            case .browser(let browser):
                TabItemChrome(
                    systemImage: "globe", browserIcon: browser,
                    title: tab.customName ?? browser.title,
                    isDisplayed: isDisplayed, isSelected: isSelected,
                    isKeyboardFocused: isKeyboardFocused, isPaneFocused: isPaneFocused,
                    isContextTarget: isContextTarget, select: select, close: close
                )
                .help(browser.urlString)
            case .diff(let diff):
                TabItemChrome(
                    systemImage: "plus.forwardslash.minus", fileIconPath: diff.path,
                    title: tab.customName ?? diff.title,
                    isDisplayed: isDisplayed, isSelected: isSelected,
                    isKeyboardFocused: isKeyboardFocused, isPaneFocused: isPaneFocused,
                    isContextTarget: isContextTarget, isDirty: diff.isDirty,
                    select: select, close: close
                )
                .help(diff.path)
            }
        }
    }

    private var focusedBrowser: BrowserTab? {
        if case .browser(let browser) = tab.content {
            browser
        } else {
            nil
        }
    }

    private var focusedFileIconPath: String? {
        tab.content.fileIconPath
    }
}

/// Inline editor shown in place of a tab while it's renamed — the same
/// affordance as the project row's rename. Commits on Return or focus loss,
/// cancels on Escape; an empty name returns the tab to its automatic title.
private struct TabRenameChrome: View {
    private let themeChanges = Theme.changes
    let systemImage: String
    let browserIcon: BrowserTab?
    let fileIconPath: String?
    let commit: (String) -> Void
    let end: () -> Void

    @State private var draft: String
    /// Set by the first commit/cancel so the focus-loss handler that fires
    /// while the field is being torn down doesn't commit a second time.
    @State private var finished = false
    @FocusState private var focused: Bool

    init(
        systemImage: String,
        browserIcon: BrowserTab?,
        fileIconPath: String?,
        initialValue: String,
        commit: @escaping (String) -> Void,
        end: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.browserIcon = browserIcon
        self.fileIconPath = fileIconPath
        self.commit = commit
        self.end = end
        _draft = State(initialValue: initialValue)
    }

    var body: some View {
        let _ = themeChanges.revision
        HStack(spacing: 5) {
            if let browserIcon {
                BrowserFaviconView(browser: browserIcon, size: 11)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.accent))
            } else if let fileIconPath {
                MaterialFileIconView(path: fileIconPath, size: 12)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.accent))
            }
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .frame(width: 110)
                .focused($focused)
                .onSubmit { finish(apply: true) }
                .onExitCommand { finish(apply: false) }
                .onChange(of: focused) {
                    if !focused { finish(apply: true) }
                }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.09))
        )
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }

    private func finish(apply: Bool) {
        guard !finished else { return }
        finished = true
        if apply { commit(draft) }
        end()
    }
}

struct TabItemChrome: View {
    private let themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    var browserIcon: BrowserTab? = nil
    var fileIconPath: String? = nil
    let title: String
    let isDisplayed: Bool
    var isSelected = false
    var isKeyboardFocused = false
    let isPaneFocused: Bool
    let isContextTarget: Bool
    var isDirty = false
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        let _ = themeChanges.revision
        Button(action: select) {
            HStack(spacing: 5) {
                ZStack {
                    if isHovering {
                        Button(action: close) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Close Tab", table: "Interface"))
                    } else if let browserIcon {
                        BrowserFaviconView(browser: browserIcon, size: 11)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(
                                isDisplayed && isPaneFocused
                                    ? AnyShapeStyle(Color(nsColor: Theme.accent))
                                    : (isDisplayed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                            )
                            .opacity(isDisplayed ? 1 : 0.78)
                    } else if let fileIconPath {
                        MaterialFileIconView(
                            path: fileIconPath,
                            size: 12,
                            opacity: isDisplayed && isPaneFocused ? 1 : 0.82
                        )
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(
                                isDisplayed && isPaneFocused
                                    ? AnyShapeStyle(Color(nsColor: Theme.accent))
                                    : (isDisplayed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                            )
                    }
                }
                .frame(width: 14, height: 14)
                Text(verbatim: title)
                    .font(.system(size: 11.5))
                    .foregroundStyle((isDisplayed || isSelected) && isPaneFocused ? .primary : .secondary)
                    .lineLimit(1)
                if isDirty {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        // Cap tab width so a long title truncates instead of stretching the
        // tab; short titles still shrink to fit (maxWidth is an upper bound).
        .frame(maxWidth: 220)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(background)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isContextTarget || isKeyboardFocused
                    ? Color(nsColor: Theme.terminal(dark: colorScheme == .dark).accentNSColor).opacity(0.65)
                    : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isDisplayed || isSelected ? .isSelected : [])
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        let theme = Theme.terminal(dark: colorScheme == .dark)
        let accent = Color(nsColor: theme.accentNSColor)
        let foreground = Color(nsColor: theme.foregroundNSColor)
        if isContextTarget { return .clear }
        if isDisplayed {
            return isPaneFocused ? accent.opacity(colorScheme == .dark ? 0.36 : 0.42)
                : foreground.opacity(0.14)
        }
        if isSelected {
            return isPaneFocused ? accent.opacity(0.18) : foreground.opacity(0.08)
        }
        return isHovering ? foreground.opacity(0.05) : .clear
    }
}

struct ChromeIconButton: View {
    let systemImage: String
    let tooltip: String
    var font: Font = .system(size: 12, weight: .medium)
    var iconSize: CGFloat = 16
    var tooltipEdge: TooltipEdge = .below
    var tooltipAlignment: HorizontalAlignment = .trailing
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: iconSize, height: iconSize)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(tooltip, edge: tooltipEdge, alignment: tooltipAlignment)
    }
}
