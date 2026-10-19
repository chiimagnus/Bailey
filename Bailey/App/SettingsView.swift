import AppKit
import GhosttyTheme
import SwiftUI

/// The existing preference areas, with the labels users see in the sidebar.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case terminal
    case workspace
    case notifications
    case portForwarding

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General", table: "Settings")
        case .terminal: String(localized: "Terminal", table: "Settings")
        case .workspace: String(localized: "Workspace", table: "Settings")
        case .notifications: String(localized: "Phone Notifications", table: "Settings")
        case .portForwarding: String(localized: "Port Forwarding", table: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .terminal: "terminal"
        case .workspace: "square.split.2x2"
        case .notifications: "bell"
        case .portForwarding: "network"
        }
    }
}

/// The single native Settings scene. Selection and in-progress sheets belong to
/// this root, not a detail page which is destroyed on navigation.
struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var selection: SettingsPage? = .general
    @State private var tunnelSelection: UUID?
    @State private var tunnelEditor: TunnelEditDraft?
    @State private var isConfirmingReset = false
    @State private var relaunchError = ""
    @State private var isShowingRelaunchError = false
    @State private var barkURLInput = ""
    @State private var barkDestinations: [BarkDestination] = []
    @State private var barkBusy = true
    @State private var barkLoaded = false
    @State private var barkStatus: String?

    private let families = TerminalFont.selectableFamilies()

    private var selectedPage: SettingsPage { selection ?? .general }

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

    private var hasCustomizedPreferences: Bool {
        !settings.fontFamily.isEmpty
            || settings.fontSize != AppSettings.defaultFontSize
            || settings.panelFontSize != AppSettings.defaultPanelFontSize
            || settings.fontThicken
            || settings.cursorShape != .block
            || !settings.cursorBlinking
            || settings.macosOptionAsAlt
            || settings.language != .system
            || settings.theme != .system
            || settings.themeDark != Theme.defaultDarkThemeName
            || settings.themeLight != Theme.defaultLightThemeName
            || settings.toolbarVisibility != AppSettings.defaultToolbarVisibility
            || settings.gitViewMode != .tree
            || settings.gitAlwaysAcceptCheckout
            || settings.gitAlwaysProceedPushTag
            || settings.wrapLines
            || settings.restoreTerminalHistory
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsPage.allCases.filter {
                    !BaileyInstanceMode.isIsolated || $0 != .notifications
                }) { page in
                    Label(page.title, systemImage: page.symbol)
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 164, ideal: 185, max: 230)
        } detail: {
            Form {
                switch selectedPage {
                case .general: generalSettings
                case .terminal: terminalSettings
                case .workspace: workspaceSettings
                case .notifications: notificationSettings
                case .portForwarding:
                    TunnelSettingsPane(selection: $tunnelSelection, editor: $tunnelEditor)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(selectedPage.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 740, idealWidth: 820, minHeight: 480, idealHeight: 610)
        .alert(
            String(localized: "Couldn’t Relaunch Bailey", table: "Settings"),
            isPresented: $isShowingRelaunchError
        ) {
            Button(String(localized: "OK", table: "Settings"), role: .cancel) {}
        } message: {
            Text(verbatim: relaunchError)
        }
        .confirmationDialog(
            String(localized: "Reset all app preferences?", table: "Settings"),
            isPresented: $isConfirmingReset
        ) {
            Button(String(localized: "Reset to Defaults", table: "Settings"), role: .destructive) {
                settings.resetToDefaults()
            }
        } message: {
            Text(String(
                localized: "Port forwarding rules and phone notification destinations will be kept.",
                table: "Settings"
            ))
        }
        .sheet(item: $tunnelEditor) { draft in
            TunnelEditorSheet(draft: draft) { tunnel in
                if draft.existing == nil {
                    TunnelManager.shared.add(tunnel)
                } else {
                    TunnelManager.shared.update(tunnel)
                }
                tunnelSelection = tunnel.id
            }
        }
    }

    @ViewBuilder
    private var generalSettings: some View {
        Section(String(localized: "Appearance", table: "Settings")) {
            // Every thumbnail remains an independent VoiceOver button.
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
                    Text(String(localized: "Relaunch Bailey to apply the language change.", table: "Settings"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Relaunch Bailey", table: "Settings")) {
                        relaunch()
                    }
                }
            }
        }

        Section {
            HStack {
                Spacer()
                Button(String(localized: "Reset to Defaults", table: "Settings")) {
                    isConfirmingReset = true
                }
                .disabled(!hasCustomizedPreferences)
            }
        }
    }

    @ViewBuilder
    private var terminalSettings: some View {
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
                Slider(value: $settings.fontSize, in: AppSettings.fontSizeRange, step: 1)
                    .accessibilityLabel(String(localized: "Size", table: "Settings"))
                Text(String(localized: "\(Int(settings.fontSize)) pt", table: "Settings"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                Stepper("", value: $settings.fontSize, in: AppSettings.fontSizeRange, step: 1)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "Size", table: "Settings"))
            }
        }

        Section(String(localized: "Preview", table: "Settings")) {
            // Ghostty's shouldSmoothFonts rasterization requires CoreText/AppKit.
            FontThickenPreview(font: previewFont, thicken: settings.fontThicken)
                .padding(.vertical, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: """
                bailey ❯ echo "the quick brown fox" 0O 1lI
                \u{E0A0} main \u{E0B0} ~/dev/bailey \u{E711} \u{F024B} \u{F0A7D}
                bold — permission denied (os error 13)
                """))
                .accessibilityAddTraits(.isStaticText)
        }

        Section(String(localized: "Terminal", table: "Settings")) {
            Picker(String(localized: "Cursor shape", table: "Terminal"), selection: $settings.cursorShape) {
                ForEach(TerminalCursorShape.allCases, id: \.self) { shape in
                    Text(shape.title).tag(shape)
                }
            }
            Toggle(String(localized: "Blink cursor", table: "Terminal"), isOn: $settings.cursorBlinking)

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
                Toggle(String(localized: "Use Option as Alt/Meta", table: "Settings"), isOn: $settings.macosOptionAsAlt)
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
    }

    @ViewBuilder
    private var workspaceSettings: some View {
        Section(String(localized: "Panels", table: "Settings")) {
            HStack {
                Text(String(localized: "Font size", table: "Settings"))
                Slider(value: $settings.panelFontSize, in: AppSettings.panelFontSizeRange, step: 1)
                    .accessibilityLabel(String(localized: "Panel font size", table: "Settings"))
                Text(String(localized: "\(Int(settings.panelFontSize)) pt", table: "Settings"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                Stepper("", value: $settings.panelFontSize, in: AppSettings.panelFontSizeRange, step: 1)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "Panel font size", table: "Settings"))
            }
        }

        Section(String(localized: "Git", table: "Settings")) {
            Picker(String(localized: "File layout", table: "Settings"), selection: $settings.gitViewMode) {
                Text(String(localized: "Tree", table: "Settings")).tag(GitViewMode.tree)
                Text(String(localized: "List", table: "Settings")).tag(GitViewMode.list)
            }
        }

        Section(String(localized: "Text Editing", table: "Settings")) {
            Toggle(String(localized: "Wrap lines to editor width", table: "Settings"), isOn: $settings.wrapLines)
        }
    }

    @ViewBuilder
    private var notificationSettings: some View {
        if !BaileyInstanceMode.isIsolated {
            Section(String(localized: "Phone Notifications", table: "Settings")) {
                HStack {
                    SecureField(
                        String(localized: "Bark push URL or device key", table: "Settings"),
                        text: $barkURLInput
                    )
                    Button(String(localized: "Add", table: "Settings")) { addBarkDestination() }
                        .disabled(barkBusy || BarkDestination(barkURLInput) == nil)
                }
                ForEach(barkDestinations) { destination in
                    HStack {
                        Text(verbatim: destination.displayName)
                        Spacer()
                        Button(String(localized: "Remove", table: "Settings")) {
                            removeBarkDestination(destination)
                        }
                        .disabled(barkBusy)
                        .accessibilityLabel(
                            String(localized: "Remove \(destination.displayName)", table: "Settings")
                        )
                    }
                }
                HStack {
                    Spacer()
                    Button(String(localized: "Send Test Notification", table: "Settings")) {
                        sendBarkTest()
                    }
                    .disabled(barkDestinations.isEmpty || barkBusy)
                }
                Text(String(
                    localized: "Codex and other terminal notifications are sent to every Bark destination. Messages may contain sensitive output.",
                    table: "Settings"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                if let barkStatus {
                    Text(verbatim: barkStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .task {
                if !barkLoaded {
                    await loadBarkDestinations()
                    barkLoaded = true
                }
            }
        }
    }

    private func loadBarkDestinations() async {
        do {
            barkDestinations = try await Task.detached(priority: .utility) {
                try BarkPushService.destinations()
            }.value
            barkStatus = nil
        } catch {
            barkStatus = String(localized: "Could not access Bark URLs in Keychain", table: "Settings")
        }
        barkBusy = false
    }

    private func addBarkDestination() {
        let input = barkURLInput
        barkBusy = true
        barkStatus = nil
        Task {
            do {
                let updated = try await Task.detached(priority: .utility) {
                    try BarkPushService.add(input)
                }.value
                if let updated {
                    barkDestinations = updated
                    barkURLInput = ""
                } else {
                    barkStatus = String(localized: "Bark URL already exists", table: "Settings")
                }
            } catch {
                barkStatus = String(localized: "Could not save Bark URL", table: "Settings")
            }
            barkBusy = false
        }
    }

    private func removeBarkDestination(_ destination: BarkDestination) {
        barkBusy = true
        barkStatus = nil
        Task {
            do {
                barkDestinations = try await Task.detached(priority: .utility) {
                    try BarkPushService.remove(destination)
                }.value
            } catch {
                barkStatus = String(localized: "Could not remove Bark URL", table: "Settings")
            }
            barkBusy = false
        }
    }

    private func sendBarkTest() {
        barkBusy = true
        barkStatus = nil
        let message = String(localized: "Test notification from Bailey", table: "Settings")
        Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try await BarkPushService.sendConfigured(title: "Bailey", message: message)
                }.value
                barkStatus = String(
                    localized: "Bark accepted \(result.accepted) of \(result.total) pushes",
                    table: "Settings"
                )
            } catch {
                barkStatus = String(localized: "Could not send the test notification", table: "Settings")
            }
            barkBusy = false
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
        ("bailey ❯ echo \"the quick brown fox\" 0O 1lI", false),
        ("\u{E0A0} main \u{E0B0} ~/dev/bailey \u{E711} \u{F024B} \u{F0A7D}", false),
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

/// A miniature bailey window painted in one appearance's real colors. `system`
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
/// enough of bailey's layout to read at thumbnail size.
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

#Preview {
    SettingsView()
}
