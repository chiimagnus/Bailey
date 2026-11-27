import AppKit
import SwiftUI

/// Compact shared find widget. The editor
/// remains the document owner; the overlay never participates in its layout.
struct FindWidget<Options: View, Replacement: View>: View {
    @Binding var query: String
    let count: String
    var hasMatches: Bool
    var noResults = false
    var invalidPattern = false
    var canReplace = false
    var showsReplace = false
    var toggleReplace: () -> Void = {}
    var selectionActive = false
    var canSelectScope = false
    var toggleSelection: (() -> Void)? = nil
    let focusRequest: Int
    let canFocus: () -> Bool
    var onFocused: () -> Void = {}
    let navigate: (Bool) -> Void
    let dismiss: () -> Void
    let restoreFocus: () -> Void
    @ViewBuilder let options: () -> Options
    @ViewBuilder let replacement: (CGFloat, Bool) -> Replacement
    @FocusState private var focused: Bool
    @State private var preferredWidth: CGFloat = 350
    @GestureState private var resize: CGFloat = 0
    @Environment(\.colorScheme) private var appearance

    private let themeChanges = Theme.changes

    var body: some View {
        let _ = themeChanges.revision
        let theme = Theme.terminal(dark: appearance == .dark)
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - 16)
            let width = min(available, max(170, preferredWidth - resize))
            let collapsed = width < 230
            let leading: CGFloat = canReplace ? 22 : 4
            let navigationWidth: CGFloat = collapsed ? 0 : 44
            let scopeWidth: CGFloat = toggleSelection == nil ? 0 : 22
            let inputWidth = width - leading - 4 - navigationWidth - scopeWidth - 22
            let countWidth: CGFloat = width >= 310 ? 64 : 0
            let fieldWidth = max(24, inputWidth - countWidth)
            HStack(alignment: .top, spacing: 0) {
                if canReplace {
                    FindIconButton(icon: .symbol(showsReplace ? "chevron.down" : "chevron.right"),
                                   title: String(localized: "Toggle Replace", table: "Editor"),
                                   action: toggleReplace)
                        .accessibilityIdentifier("bailey.find.replace-toggle")
                        .accessibilityValue(showsReplace ? "1" : "0")
                        .frame(width: 20, height: 23)
                        .padding(.trailing, 2)
                } else {
                    Spacer().frame(width: 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        FindInputFrame(focused: focused, invalid: invalidPattern) {
                            TextField(String(localized: "Find", table: "Interface"), text: $query)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .focused($focused)
                                .accessibilityIdentifier("bailey.find.query")
                                .onKeyPress(.escape) { dismiss(); return .handled }
                                .onKeyPress(keys: [.return], phases: .down) { press in
                                    navigate(!press.modifiers.contains(.shift))
                                    return .handled
                                }
                                .padding(.leading, 6)
                                .frame(minWidth: 12, maxWidth: .infinity)
                            if !collapsed {
                                HStack(spacing: 1) { options() }
                                    .padding(.trailing, 3)
                            }
                        }
                        .frame(width: fieldWidth)
                        if countWidth > 0 {
                            Text(verbatim: count)
                                .font(.system(size: 12))
                                .foregroundStyle(noResults || invalidPattern ? Color.red : Color.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(width: countWidth - 4, alignment: .leading)
                                .padding(.leading, 4)
                                .help(count)
                                .accessibilityIdentifier("bailey.find.count")
                        }
                        if !collapsed {
                            FindIconButton(icon: .symbol("arrow.up"), title: String(localized: "Previous match", table: "Terminal")) {
                                navigate(false)
                            }
                            .accessibilityIdentifier("bailey.find.previous")
                            .disabled(!hasMatches)
                            .frame(width: 22)
                            FindIconButton(icon: .symbol("arrow.down"), title: String(localized: "Next match", table: "Terminal")) {
                                navigate(true)
                            }
                            .accessibilityIdentifier("bailey.find.next")
                            .disabled(!hasMatches)
                            .frame(width: 22)
                        }
                        if let toggleSelection {
                            FindIconButton(icon: .symbol("text.alignleft"), title: String(localized: "Find in Selection", table: "Editor"),
                                           selected: selectionActive, action: toggleSelection)
                                .disabled(!canSelectScope && !selectionActive)
                                .accessibilityIdentifier("bailey.find.selection")
                                .frame(width: 22)
                        }
                        FindIconButton(icon: .symbol("xmark"), title: String(localized: "Close find bar", table: "Terminal"), action: dismiss)
                            .accessibilityIdentifier("bailey.find.close")
                            .frame(width: 22)
                    }
                    if canReplace, showsReplace {
                        replacement(fieldWidth, !collapsed)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.trailing, 4)
            .frame(width: width, alignment: .leading)
            .foregroundStyle(Color(nsColor: theme.foregroundNSColor))
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.isBaileyDefault ? AnyShapeStyle(.regularMaterial)
                          : AnyShapeStyle(Color(nsColor: theme.surfaceNSColor(elevation: 0.07))))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: theme.foregroundNSColor).opacity(0.16))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.25), radius: 7, y: 3)
            .overlay(alignment: .leading) {
                Color.clear.frame(width: 4)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .updating($resize) { value, state, _ in state = value.translation.width }
                        .onEnded { value in
                            preferredWidth = min(available, max(170, preferredWidth - value.translation.width))
                        })
                    .onTapGesture(count: 2) { preferredWidth = 350 }
                    .accessibilityHidden(true)
            }
            .padding(.top, 4)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onAppear { focusQuery() }
        .onChange(of: focusRequest) { focusQuery() }
        .onChange(of: focused) { if focused { onFocused() } }
        .onDisappear(perform: restoreFocus)
    }

    private func focusQuery() {
        DispatchQueue.main.async {
            guard canFocus(), NSApp.isActive, NSApp.keyWindow != nil else { return }
            focused = true
            DispatchQueue.main.async {
                guard focused, canFocus(), NSApp.isActive,
                      let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                      editor.isFieldEditor else { return }
                editor.selectAll(nil)
            }
        }
    }
}

private struct FindInputFrame<Content: View>: View {
    var focused: Bool
    var invalid = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0, content: content)
            .frame(height: 23)
            .background(.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(invalid ? Color.red : focused ? Color(nsColor: Theme.accent) : Color.primary.opacity(0.13))
                    .allowsHitTesting(false)
            }
    }
}

struct FindIconButton: View {
    enum Mark {
        case symbol(String)
        case text(String, underlined: Bool = false)
    }

    let icon: Mark
    let title: String
    var selected = false
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Group {
                switch icon {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 13, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                case .text(let mark, let underlined):
                    // Search syntax is a fixed mark, not localized symbol artwork.
                    Text(verbatim: mark)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .underline(underlined)
                }
            }
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(selected ? Color(nsColor: Theme.accent).opacity(0.19)
                              : hovered && enabled ? Color.primary.opacity(0.12) : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? Color(nsColor: Theme.accent) : .clear)
                }
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct FindReplacementRow: View {
    @Binding var replacement: String
    var preserveCase: Binding<Bool>? = nil
    let canReplace: Bool
    let canReplaceAll: Bool
    let replace: () -> Void
    let replaceAll: () -> Void
    let dismiss: () -> Void
    let fieldWidth: CGFloat
    let showsActions: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            FindInputFrame(focused: focused) {
                TextField(String(localized: "Replace", table: "Editor"), text: $replacement)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .accessibilityIdentifier("bailey.find.replacement")
                    .onSubmit { if canReplace { replace() } }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .padding(.leading, 6)
                    .frame(minWidth: 12, maxWidth: .infinity)
                if let preserveCase, fieldWidth >= 80 {
                    FindIconButton(icon: .text("AB"), title: String(localized: "Preserve Case", table: "Editor"),
                                   selected: preserveCase.wrappedValue) { preserveCase.wrappedValue.toggle() }
                        .accessibilityIdentifier("bailey.find.preserve-case")
                        .padding(.trailing, 3)
                }
            }
            .frame(width: fieldWidth)
            if showsActions {
                FindIconButton(icon: .symbol("arrow.turn.down.right"), title: String(localized: "Replace", table: "Editor"), action: replace)
                    .disabled(!canReplace)
                    .accessibilityIdentifier("bailey.find.replace")
                    .frame(width: 22)
                FindIconButton(icon: .symbol("arrow.triangle.2.circlepath"), title: String(localized: "Replace All", table: "Editor"), action: replaceAll)
                    .disabled(!canReplaceAll)
                    .accessibilityIdentifier("bailey.find.replace-all")
                    .frame(width: 22)
            }
        }
    }
}
