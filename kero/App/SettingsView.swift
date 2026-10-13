//
//  SettingsView.swift
//  kero
//

import AppKit
import GhosttyTheme
import SwiftUI

/// The app settings window (Cmd+,).
struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var relaunchError = ""
    @State private var isShowingRelaunchError = false

    /// Installed fixed-pitch families (bundled default first).
    private let families = TerminalFont.selectableFamilies()

    private var toolbarVisibilityDescription: String {
        switch settings.toolbarVisibility {
        case .auto:
            String(localized: "Shows the toolbar only in Git repositories", table: "Settings")
        case .always:
            String(localized: "Shows the toolbar in every project", table: "Settings")
        case .hide:
            String(localized: "Keeps the toolbar hidden", table: "Settings")
        }
    }

    var body: some View {
        CappedIdealHeight(maxHeight: 600) { form }
    }

    private var form: some View {
        Form {
            Section(String(localized: "Appearance", table: "Settings")) {
                // A plain row rather than LabeledContent: that stamps its own
                // label onto every child, leaving all three previews named
                // "Theme" to VoiceOver instead of System/Light/Dark.
                HStack {
                    Text(String(localized: "Theme", table: "Settings"))
                    Spacer()
                    ThemePicker(selection: $settings.theme)
                }

                Picker(String(localized: "Language", table: "Settings"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language)
                    }
                }

                DescribedSettingsRow(
                    String(localized: "Toolbar", table: "Settings"),
                    description: toolbarVisibilityDescription
                ) {
                    Picker(String(localized: "Toolbar", table: "Settings"), selection: $settings.toolbarVisibility) {
                        Text(String(localized: "Auto", table: "Settings")).tag(ToolbarVisibility.auto)
                        Text(String(localized: "Always Show", table: "Settings")).tag(ToolbarVisibility.always)
                        Text(String(localized: "Hide", table: "Settings")).tag(ToolbarVisibility.hide)
                    }
                    .labelsHidden()
                }

                if settings.languageRequiresRelaunch {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(localized: "Relaunch Kero to apply the language change.", table: "Settings"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Relaunch Kero", table: "Settings")) {
                            relaunch()
                        }
                    }
                }
            }

            Section(String(localized: "Git", table: "Settings")) {
                GitViewModeSettingsRow(mode: settings.gitViewMode) {
                    settings.gitViewMode = $0
                }
                .frame(height: 28)
            }

            Section(String(localized: "Colors", table: "Settings")) {
                Picker(String(localized: "Dark theme", table: "Settings"), selection: $settings.themeDark) {
                    ForEach(Self.darkThemeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Picker(String(localized: "Light theme", table: "Settings"), selection: $settings.themeLight) {
                    ForEach(Self.lightThemeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            Section(String(localized: "Font", table: "Settings")) {
                Picker(String(localized: "Family", table: "Settings"), selection: $settings.fontFamily) {
                    Text(String(localized: "\(TerminalFont.bundledFamily) (Bundled)", table: "Settings")).tag("")
                    Divider()
                    ForEach(families.dropFirst(), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack {
                    Text(String(localized: "Size", table: "Settings"))
                    Slider(
                        value: $settings.fontSize,
                        in: AppSettings.fontSizeRange,
                        step: 1
                    )
                    Text(String(localized: "\(Int(settings.fontSize)) pt", table: "Settings"))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Stepper(
                        "",
                        value: $settings.fontSize,
                        in: AppSettings.fontSizeRange,
                        step: 1
                    )
                    .labelsHidden()
                }
            }

            Section(String(localized: "Panels", table: "Settings")) {
                HStack {
                    Text(String(localized: "Font size", table: "Settings"))
                    Slider(
                        value: $settings.panelFontSize,
                        in: AppSettings.panelFontSizeRange,
                        step: 1
                    )
                    .accessibilityLabel(String(localized: "Panel font size", table: "Settings"))
                    Text(String(localized: "\(Int(settings.panelFontSize)) pt", table: "Settings"))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Stepper(
                        "",
                        value: $settings.panelFontSize,
                        in: AppSettings.panelFontSizeRange,
                        step: 1
                    )
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "Panel font size", table: "Settings"))
                }
            }

            Section(String(localized: "Preview", table: "Settings")) {
                // SwiftUI Text cannot show Ghostty's font-thicken — that flag
                // only affects CoreText glyph rasterization — so draw through
                // AppKit with shouldSmoothFonts matching the toggle.
                FontThickenPreview(font: previewFont, thicken: settings.fontThicken)
                    .padding(.vertical, 4)
                    // NSView drawing has no semantic children of its own.
                    // Preserve the sample text that the previous SwiftUI Text
                    // views exposed to VoiceOver.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: """
                    kero ❯ echo "the quick brown fox" 0O 1lI
                    \u{E0A0} main \u{E0B0} ~/dev/kero \u{E711} \u{F024B} \u{F0A7D}
                    bold — permission denied (os error 13)
                    """))
                    .accessibilityAddTraits(.isStaticText)
            }

            Section(String(localized: "Terminal", table: "Settings")) {
                TerminalCursorShapeSettingsRow(
                    shape: settings.cursorShape,
                    onChange: { settings.cursorShape = $0 }
                )

                TerminalCursorBlinkingSettingsRow(
                    isBlinking: settings.cursorBlinking,
                    onChange: { settings.cursorBlinking = $0 }
                )

                DescribedSettingsRow(
                    String(localized: "Thicken font strokes", table: "Settings"),
                    description: String(localized: "Renders terminal text with slightly heavier strokes, like classic macOS font smoothing", table: "Settings")
                ) {
                    Toggle(String(localized: "Thicken font strokes", table: "Settings"), isOn: $settings.fontThicken)
                        .labelsHidden()
                }

                DescribedSettingsRow(
                    String(localized: "Use Option as Alt/Meta", table: "Settings"),
                    description: String(localized: "Sends Option-key combinations to terminal programs as Meta shortcuts instead of macOS text input", table: "Settings")
                ) {
                    Toggle(
                        String(localized: "Use Option as Alt/Meta", table: "Settings"),
                        isOn: $settings.macosOptionAsAlt
                    )
                    .labelsHidden()
                }

                DescribedSettingsRow(
                    String(localized: "Restore session history on relaunch", table: "Settings"),
                    description: String(localized: "Reopened terminals show their previous scrollback above a fresh shell", table: "Settings")
                ) {
                    Toggle(
                        String(localized: "Restore session history on relaunch", table: "Settings"),
                        isOn: $settings.restoreTerminalHistory
                    )
                    .labelsHidden()
                }
            }

            Section(String(localized: "Port Forwarding", table: "Settings")) {
                TunnelSettingsRow()
                    .frame(height: 176)
            }

            Section(String(localized: "Text Editing", table: "Settings")) {
                Toggle(String(localized: "Wrap lines to editor width", table: "Settings"), isOn: $settings.wrapLines)
            }

            Section {
                HStack {
                    Spacer()
                    Button(String(localized: "Reset to Defaults", table: "Settings")) {
                        settings.resetToDefaults()
                    }
                    .disabled(settings.fontFamily.isEmpty
                        && settings.fontSize == AppSettings.defaultFontSize
                        && settings.panelFontSize == AppSettings.defaultPanelFontSize
                        && !settings.fontThicken
                        && settings.cursorShape == .block
                        && settings.cursorBlinking
                        && !settings.macosOptionAsAlt
                        && settings.language == .system
                        && settings.theme == .system
                        && settings.themeDark == Theme.defaultDarkThemeName
                        && settings.themeLight == Theme.defaultLightThemeName
                        && settings.toolbarVisibility == AppSettings.defaultToolbarVisibility
                        && settings.gitViewMode == .tree
                        && !settings.wrapLines
                        && !settings.restoreTerminalHistory)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .alert(
            String(localized: "Couldn’t Relaunch Kero", table: "Settings"),
            isPresented: $isShowingRelaunchError
        ) {
            Button(String(localized: "OK", table: "Settings"), role: .cancel) {}
        } message: {
            Text(verbatim: relaunchError)
        }
    }

    private var previewFont: NSFont {
        TerminalFont.resolve(family: settings.fontFamily, size: CGFloat(settings.fontSize))
    }

    private func relaunch() {
        TerminalManager.saveForRelaunch()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            DispatchQueue.main.async {
                if let error {
                    relaunchError = error.localizedDescription
                    isShowingRelaunchError = true
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// The compact catalog of popular terminal themes,
    /// split by the appearance slot they suit.
    private static let darkThemeNames = Theme.commonDarkThemes.map(\.name)
    private static let lightThemeNames = Theme.commonLightThemes.map(\.name)
}

/// Matches macOS Settings: a title and explanation form one label stack,
/// while the setting control stays aligned to the row's top-right corner.
private struct DescribedSettingsRow<Control: View>: View {
    let title: String
    let description: String
    let control: Control

    init(
        _ title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                Text(verbatim: description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Settings font preview that honors `font-thicken`. Ghostty thickens by
/// enabling CoreText font smoothing when rasterizing glyphs; SwiftUI `Text`
/// does not, so toggling the setting left this preview unchanged.
private struct FontThickenPreview: NSViewRepresentable {
    var font: NSFont
    var thicken: Bool

    func makeNSView(context: Context) -> FontThickenPreviewView {
        FontThickenPreviewView()
    }

    func updateNSView(_ view: FontThickenPreviewView, context: Context) {
        view.previewFont = font
        view.thicken = thicken
        view.needsDisplay = true
        view.invalidateIntrinsicContentSize()
    }
}

private final class FontThickenPreviewView: NSView {
    var previewFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    var thicken = false

    /// Regular / icon / bold lines — same samples as the old SwiftUI preview.
    private let lines: [(text: String, bold: Bool)] = [
        ("kero ❯ echo \"the quick brown fox\" 0O 1lI", false),
        ("\u{E0A0} main \u{E0B0} ~/dev/kero \u{E711} \u{F024B} \u{F0A7D}", false),
        ("bold — permission denied (os error 13)", true),
    ]

    private let lineSpacing: CGFloat = 6
    private let verticalPadding: CGFloat = 4

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let lineHeight = ceil(previewFont.boundingRectForFont.height)
        let height = verticalPadding * 2
            + CGFloat(lines.count) * lineHeight
            + CGFloat(max(0, lines.count - 1)) * lineSpacing
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Mirror Ghostty's CoreText glyph path (face/coretext.zig):
        // font-thicken == shouldSmoothFonts.
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(thicken)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let color = NSColor.labelColor
        var y = verticalPadding
        let lineHeight = ceil(previewFont.boundingRectForFont.height)
        for (text, bold) in lines {
            let font = bold
                ? NSFontManager.shared.convert(previewFont, toHaveTrait: .boldFontMask)
                : previewFont
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            (text as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: attrs)
            y += lineHeight + lineSpacing
        }
    }
}

/// Sizes its sole child to the child's ideal height, capped at `maxHeight`.
/// A `maxHeight` frame plus `fixedSize` can't express this: the grouped Form
/// is a List, which only scrolls when *proposed* the capped height, yet still
/// has to be measured unconstrained to hug shorter content.
private struct CappedIdealHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let ideal = subviews[0].sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(bounds.size)
        )
    }
}

/// Theme chooser modelled on the Appearance control in System Settings: one
/// tappable preview per option instead of a row of words.
private struct ThemePicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTheme.allCases) { theme in
                ThemeOption(
                    theme: theme,
                    isSelected: selection == theme,
                    select: { selection = theme }
                )
            }
        }
    }
}

private struct ThemeOption: View {
    let theme: AppTheme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                ThemePreview(theme: theme)
                Text(theme.title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    // Without this the row's HStack can squeeze a label to
                    // zero width, wrapping it into blank lines that stretch
                    // that one option taller than its neighbours.
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(isSelected ? 0.15 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A miniature kero window painted in one appearance's real colors. `system`
/// splits down the middle — light on the left, dark on the right — the same
/// way System Settings previews "Auto".
private struct ThemePreview: View {
    let theme: AppTheme

    private static let size = CGSize(width: 76, height: 50)
    private static let corner: CGFloat = 7

    var body: some View {
        ZStack {
            switch theme {
            case .light:
                MiniWindow(dark: false)
            case .dark:
                MiniWindow(dark: true)
            case .system:
                MiniWindow(dark: false)
                MiniWindow(dark: true)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: Self.size.width / 2)
                    }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

/// Sidebar, traffic lights, a tab, and a few lines of terminal output —
/// enough of kero's layout to read at thumbnail size.
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let theme = Theme.terminal(dark: dark)
        let text = Color(nsColor: theme.foregroundNSColor)
        let cursor = Color(nsColor: theme.cursorNSColor)

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 2.5) {
                    dot(0xFF5F57)
                    dot(0xFEBC2E)
                    dot(0x28C840)
                }
                .padding(.bottom, 3)

                bar(11, text.opacity(0.35))
                bar(8, text.opacity(0.35))
                bar(11, text.opacity(0.35))
            }
            .padding(5)
            .frame(minWidth: 22, maxWidth: 22, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: Theme.sidebarFill(dark: dark)))

            VStack(alignment: .leading, spacing: 3.5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(text.opacity(0.12))
                    .frame(width: 14, height: 5)
                    .padding(.bottom, 1)

                HStack(spacing: 2) {
                    bar(3, cursor)
                    bar(22, text.opacity(0.8))
                }
                bar(30, text.opacity(0.45))
                bar(16, text.opacity(0.45))
                HStack(spacing: 2) {
                    bar(3, cursor)
                    bar(7, text.opacity(0.8))
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: theme.backgroundNSColor))
        }
    }

    private func dot(_ hex: Int) -> some View {
        Circle()
            .fill(Color(
                .sRGB,
                red: Double((hex >> 16) & 0xff) / 255,
                green: Double((hex >> 8) & 0xff) / 255,
                blue: Double(hex & 0xff) / 255
            ))
            .frame(width: 3.5, height: 3.5)
    }

    private func bar(_ width: CGFloat, _ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(fill)
            .frame(width: width, height: 2.5)
    }
}

// AppKit controls this Git preference inside the SwiftUI Settings form.
@MainActor
private final class GitViewModeSettingsNSView: NSView {
    private let label = NSTextField(labelWithString: String(localized: "File layout", table: "Settings"))
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    var onChange: ((GitViewMode) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        popup.controlSize = .small
        popup.target = self
        popup.action = #selector(changedMode)
        popup.setAccessibilityLabel(String(localized: "File layout", table: "Settings"))
        for mode in GitViewMode.allCases {
            let title = mode == .tree ? String(localized: "Tree", table: "Settings") : String(localized: "List", table: "Settings")
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = mode.rawValue
            popup.menu?.addItem(item)
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(label)
        addSubview(popup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -16),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func apply(_ mode: GitViewMode) {
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == mode.rawValue }) {
            popup.select(item)
        }
    }

    @objc private func changedMode() {
        guard let value = popup.selectedItem?.representedObject as? String,
              let mode = GitViewMode(rawValue: value) else { return }
        onChange?(mode)
    }
}

private struct GitViewModeSettingsRow: NSViewRepresentable {
    let mode: GitViewMode
    let onChange: (GitViewMode) -> Void

    func makeNSView(context: Context) -> GitViewModeSettingsNSView {
        GitViewModeSettingsNSView(frame: .zero)
    }

    func updateNSView(_ view: GitViewModeSettingsNSView, context: Context) {
        view.onChange = onChange
        view.apply(mode)
    }
}

#Preview {
    SettingsView()
}
