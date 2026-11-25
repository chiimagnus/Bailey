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
    var body: some View {
        switch tab.content {
        case .session(let session):
            TabItemChrome(
                systemImage: "terminal", title: session.title,
                isDisplayed: isDisplayed, isSelected: isSelected,
                isKeyboardFocused: isKeyboardFocused, isPaneFocused: isPaneFocused,
                isContextTarget: isContextTarget, select: select, close: close
            )
        case .file(let file):
            TabItemChrome(
                systemImage: "doc.text", fileIconPath: file.path,
                title: file.name,
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
                title: browser.title,
                isDisplayed: isDisplayed, isSelected: isSelected,
                isKeyboardFocused: isKeyboardFocused, isPaneFocused: isPaneFocused,
                isContextTarget: isContextTarget, select: select, close: close
            )
            .help(browser.urlString)
        case .diff(let diff):
            TabItemChrome(
                systemImage: "plus.forwardslash.minus", fileIconPath: diff.path,
                title: diff.title,
                isDisplayed: isDisplayed, isSelected: isSelected,
                isKeyboardFocused: isKeyboardFocused, isPaneFocused: isPaneFocused,
                isContextTarget: isContextTarget, isDirty: diff.isDirty,
                select: select, close: close
            )
            .help(diff.path)
        }
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

/// File and Diff errors can contain a recovery location; never truncate it.
struct WorkspaceErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(red: 0.82, green: 0.60, blue: 0.13))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
    }
}
