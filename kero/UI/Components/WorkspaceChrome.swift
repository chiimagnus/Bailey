import AppKit
import SwiftUI

/// A tab in the strip. Shows its content's title/icon and dirty indicator.
/// Observes the tab so name changes refresh it; the content is observed by the
/// per-kind label below so its live title/dirty state shows.
struct PaneTabItem: View {
    @ObservedObject var tab: PaneTab
    let isSelected: Bool
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
                SessionTabLabel(session: session, customTitle: tab.customName, isSelected: isSelected, select: select, close: close)
            case .file(let file):
                FileTabLabel(file: file, customTitle: tab.customName, isSelected: isSelected, select: select, close: close)
            case .browser(let browser):
                BrowserTabLabel(browser: browser, customTitle: tab.customName, isSelected: isSelected, select: select, close: close)
            case .diff(let diff):
                DiffTabLabel(
                    diff: diff,
                    customTitle: tab.customName,
                    isSelected: isSelected,
                    select: select,
                    close: close
                )
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
    @ObservedObject private var themeChanges = Theme.changes
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

private struct SessionTabLabel: View {
    @ObservedObject var session: TerminalSession
    /// User-assigned tab name overriding the live terminal title.
    var customTitle: String?
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "terminal",
            title: customTitle ?? session.title,
            isSelected: isSelected,
            select: select,
            close: close
        )
    }
}

private struct FileTabLabel: View {
    @ObservedObject var file: FileTab
    /// User-assigned tab name overriding the file name.
    var customTitle: String?
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "doc.text",
            fileIconPath: file.path,
            title: customTitle ?? file.name,
            isSelected: isSelected,
            isDirty: file.isDirty,
            select: select,
            close: close
        )
        .help(file.path)
    }
}

private struct BrowserTabLabel: View {
    @ObservedObject var browser: BrowserTab
    /// User-assigned tab name overriding the webpage title.
    var customTitle: String?
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "globe",
            browserIcon: browser,
            title: customTitle ?? browser.title,
            isSelected: isSelected,
            select: select,
            close: close
        )
        .help(browser.urlString)
    }
}

private struct DiffTabLabel: View {
    @ObservedObject var diff: DiffTab
    var customTitle: String?
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        TabItemChrome(
            systemImage: "plus.forwardslash.minus",
            fileIconPath: diff.path,
            title: customTitle ?? diff.title,
            isSelected: isSelected,
            isDirty: diff.isDirty,
            select: select,
            close: close
        )
        .help(diff.path)
    }
}

struct TabItemChrome: View {
    @ObservedObject private var themeChanges = Theme.changes
    let systemImage: String
    var browserIcon: BrowserTab? = nil
    var fileIconPath: String? = nil
    let title: String
    let isSelected: Bool
    var isDirty = false
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
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
                                isSelected
                                    ? AnyShapeStyle(Color(nsColor: Theme.accent))
                                    : AnyShapeStyle(.tertiary)
                            )
                            .opacity(isSelected ? 1 : 0.78)
                    } else if let fileIconPath {
                        MaterialFileIconView(
                            path: fileIconPath,
                            size: 12,
                            opacity: isSelected ? 1 : 0.82
                        )
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(
                                isSelected
                                    ? AnyShapeStyle(Color(nsColor: Theme.accent))
                                    : AnyShapeStyle(.tertiary)
                            )
                    }
                }
                .frame(width: 14, height: 14)
                Text(verbatim: title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? .primary : .secondary)
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
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.09) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .onHover { isHovering = $0 }
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

/// Live frames-per-second readout in the header strip, fed by `FPSCounter`.
/// It exists only while the manager's toggle is on, so the counter starts
/// when the badge appears and stops when it leaves the hierarchy.
struct FPSBadge: View {
    @StateObject private var counter = FPSCounter()

    var body: some View {
        Text(String(localized: "\(counter.fps) fps", table: "Sidebar"))
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.07))
            )
            .onAppear { counter.start() }
            .onDisappear { counter.stop() }
    }
}
