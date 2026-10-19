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
    @State private var navigation = SettingsNavigationHistory()
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var highlightedField: SettingsField?
    @State private var requestedField: SettingsField?
    @State private var searchRevision = 0
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

    private var selectedPage: SettingsPage { navigation.current }

    private var pageSelection: Binding<SettingsPage?> {
        Binding(
            get: { navigation.current },
            set: { if let page = $0 { navigation.select(page) } }
        )
    }

    private var visiblePages: [SettingsPage] {
        SettingsPage.allCases.filter { !BaileyInstanceMode.isIsolated || $0 != .notifications }
    }

    private func navigateTo(_ field: SettingsField) {
        navigation.select(field.page)
        requestedField = field
        searchRevision += 1
        highlightedField = nil
        searchText = ""
        isSearching = false
    }

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
            Group {
                if searchText.isEmpty {
                    List(selection: pageSelection) {
                        Section(String(localized: "Preferences", table: "Settings")) {
                            ForEach(visiblePages.filter { $0 != .notifications && $0 != .portForwarding }) { page in
                                Label {
                                    Text(page.title)
                                } icon: {
                                    Image(systemName: page.symbol)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(page)
                            }
                        }
                        Section(String(localized: "Connections", table: "Settings")) {
                            ForEach(visiblePages.filter { $0 == .notifications || $0 == .portForwarding }) { page in
                                Label {
                                    Text(page.title)
                                } icon: {
                                    Image(systemName: page.symbol)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(page)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                } else {
                    let results = SettingsField.search(
                        searchText, includeNotifications: !BaileyInstanceMode.isIsolated
                    )
                    if results.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $highlightedField) {
                            Section(String(localized: "Results", table: "Settings")) {
                                ForEach(results) { field in
                                    Label {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(field.title)
                                                .font(.body)
                                            Text("\(field.page.title) · \(field.section)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    } icon: {
                                        Image(systemName: field.page.symbol)
                                            .foregroundStyle(.secondary)
                                    }
                                    .tag(field)
                                }
                            }
                        }
                        .listStyle(.sidebar)
                        .onChange(of: highlightedField) { _, field in
                            if let field { navigateTo(field) }
                        }
                    }
                }
            }
            .searchable(
                text: $searchText,
                isPresented: $isSearching,
                placement: .sidebar,
                prompt: String(localized: "Search Settings", table: "Settings")
            )
            .toolbar(removing: .sidebarToggle)
            .background {
                HStack(spacing: 0) {
                    Button(String(localized: "Search Settings", table: "Settings")) {
                        isSearching = true
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    Button(String(localized: "Back", table: "Settings")) {
                        navigation.goBack()
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!navigation.canGoBack)
                    Button(String(localized: "Forward", table: "Settings")) {
                        navigation.goForward()
                    }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!navigation.canGoForward)
                }
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
            .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 224)
        } detail: {
            ScrollViewReader { proxy in
                Form {
                    switch selectedPage {
                    case .general: generalSettings
                    case .terminal: terminalSettings
                    case .workspace: workspaceSettings
                    case .notifications: notificationSettings
                    case .portForwarding:
                        TunnelSettingsPane(selection: $tunnelSelection, editor: $tunnelEditor)
                            .id(SettingsField.portForwarding)
                    }
                }
                .formStyle(.grouped)
                .task(id: searchRevision) {
                    guard let field = requestedField, field.page == selectedPage else { return }
                    await Task.yield()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(field, anchor: .center)
                    }
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selectedPage.title)
        .frame(minWidth: 780, idealWidth: 820, minHeight: 500, idealHeight: 610)
        .background {
            SettingsWindowResizer().frame(width: 0, height: 0)
        }
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
            Picker(String(localized: "Theme", table: "Settings"), selection: $settings.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .id(SettingsField.appearance)

            Picker(String(localized: "Language", table: "Settings"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.title).tag(language)
                }
            }
            .id(SettingsField.language)

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
            .id(SettingsField.toolbar)

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

        Section(String(localized: "Reset", table: "Settings")) {
            DescribedSettingsRow(
                String(localized: "App preferences", table: "Settings"),
                description: String(
                    localized: "Port forwarding rules and phone notification destinations will be kept.",
                    table: "Settings"
                )
            ) {
                Button(String(localized: "Reset to Defaults", table: "Settings")) {
                    isConfirmingReset = true
                }
                .disabled(!hasCustomizedPreferences)
            }
            .id(SettingsField.reset)
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
            .id(SettingsField.darkTheme)
            Picker(String(localized: "Light theme", table: "Settings"), selection: $settings.themeLight) {
                ForEach(Self.lightThemeNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .id(SettingsField.lightTheme)
        }

        Section(String(localized: "Font", table: "Settings")) {
            Picker(String(localized: "Family", table: "Settings"), selection: $settings.fontFamily) {
                Text(String(localized: "\(TerminalFont.bundledFamily) (Bundled)", table: "Settings")).tag("")
                Divider()
                ForEach(families.dropFirst(), id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .id(SettingsField.fontFamily)

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
            .id(SettingsField.fontSize)
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
                .id(SettingsField.preview)
        }

        Section(String(localized: "Terminal", table: "Settings")) {
            Picker(String(localized: "Cursor shape", table: "Terminal"), selection: $settings.cursorShape) {
                ForEach(TerminalCursorShape.allCases, id: \.self) { shape in
                    Text(shape.title).tag(shape)
                }
            }
            .id(SettingsField.cursorShape)
            Toggle(String(localized: "Blink cursor", table: "Terminal"), isOn: $settings.cursorBlinking)
                .id(SettingsField.cursorBlinking)

            DescribedSettingsRow(
                String(localized: "Thicken font strokes", table: "Settings"),
                description: String(localized: "Renders terminal text with slightly heavier strokes, like classic macOS font smoothing", table: "Settings")
            ) {
                Toggle(String(localized: "Thicken font strokes", table: "Settings"), isOn: $settings.fontThicken)
                    .labelsHidden()
            }
            .id(SettingsField.fontThicken)

            DescribedSettingsRow(
                String(localized: "Use Option as Alt/Meta", table: "Settings"),
                description: String(localized: "Sends Option-key combinations to terminal programs as Meta shortcuts instead of macOS text input", table: "Settings")
            ) {
                Toggle(String(localized: "Use Option as Alt/Meta", table: "Settings"), isOn: $settings.macosOptionAsAlt)
                    .labelsHidden()
            }
            .id(SettingsField.optionAsAlt)

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
            .id(SettingsField.restoreHistory)
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
            .id(SettingsField.panelFontSize)
        }

        Section(String(localized: "Git", table: "Settings")) {
            Picker(String(localized: "File layout", table: "Settings"), selection: $settings.gitViewMode) {
                Text(String(localized: "Tree", table: "Settings")).tag(GitViewMode.tree)
                Text(String(localized: "List", table: "Settings")).tag(GitViewMode.list)
            }
            .id(SettingsField.gitLayout)
        }

        Section(String(localized: "Text Editing", table: "Settings")) {
            Toggle(String(localized: "Wrap lines to editor width", table: "Settings"), isOn: $settings.wrapLines)
                .id(SettingsField.wrapLines)
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
            .id(SettingsField.barkDestinations)
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

/// macOS Settings scenes create fixed-size NSWindows despite SwiftUI's
/// minimum content size. Configure only the containing window's resize style.
private struct SettingsWindowResizer: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowResizerView {
        SettingsWindowResizerView()
    }

    func updateNSView(_ view: SettingsWindowResizerView, context: Context) {}
}

private final class SettingsWindowResizerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // The Settings scene installs its fixed-size style after mounting its content.
        DispatchQueue.main.async { [weak self, weak window] in
            guard self?.window === window, let window else { return }
            window.styleMask.insert(.resizable)
        }
    }
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

#Preview {
    SettingsView()
}
