//
//  AppSettings.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// The app-specific language macOS should use when Kero next launches.
///
/// `AppleLanguages` is stored in Kero's own defaults domain, matching the
/// per-app language preference managed by System Settings. Removing it returns
/// control to the user's system language order.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Language names are autonyms so the picker stays usable even when the
    /// current app language is unfamiliar to the user.
    var title: String {
        switch self {
        case .system:
            String(
                localized: "System Default", table: "Settings",
                comment: "Language choice that follows the macOS setting."
            )
        case .english:
            "English"
        case .simplifiedChinese:
            "简体中文"
        }
    }

    static var saved: AppLanguage {
        guard
            let bundleIdentifier = Bundle.main.bundleIdentifier,
            let domain = UserDefaults.standard.persistentDomain(
                forName: bundleIdentifier
            ),
            let identifiers = domain["AppleLanguages"] as? [String],
            let identifier = identifiers.first
        else {
            return .system
        }

        return from(identifier: identifier) ?? .system
    }

    private static func from(identifier: String) -> AppLanguage? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        if normalized == "zh-Hans"
            || normalized.hasPrefix("zh-Hans-")
            || normalized.hasPrefix("zh-CN")
            || normalized.hasPrefix("zh-SG") {
            return .simplifiedChinese
        }
        if normalized == "en" || normalized.hasPrefix("en-") {
            return .english
        }
        return nil
    }

    func persist() {
        switch self {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChinese:
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Whether the toolbar follows project context, always shows, or stays hidden.
enum ToolbarVisibility: String, CaseIterable, Identifiable {
    case auto
    case always
    case hide

    var id: String { rawValue }
}

/// File presentation for working-tree changes and commit history in Git; not Files.
enum GitViewMode: String, CaseIterable, Identifiable {
    case tree
    case list

    var id: String { rawValue }
}

/// User-configurable settings, persisted to `$HOME/.config/kero/config.toml`.
/// Views observe this directly; `TerminalManager` re-themes live sessions on
/// any change.
@MainActor
final class AppSettings: nonisolated ObservableObject {
    static let shared = AppSettings()

    nonisolated static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/kero/config.toml")
    private let settingsURL: URL

    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 8...32
    static let defaultPanelFontSize: Double = 14
    static let panelFontSizeRange: ClosedRange<Double> = 9...18
    static let defaultToolbarVisibility: ToolbarVisibility = .hide

    /// Loaded once at launch; changing the initial template never rearranges
    /// a project's already saved dock tree.
    let workspaceConfiguration: DockWorkspaceConfiguration

    /// The language this process launched with, kept separate from the pending
    /// selection so Settings can explain when a relaunch is required.
    let activeLanguage: AppLanguage

    @Published var language: AppLanguage {
        didSet { language.persist() }
    }

    var languageRequiresRelaunch: Bool {
        language != activeLanguage
    }

    /// Light/dark appearance override; `system` follows macOS.
    @Published var theme: AppTheme {
        didSet {
            applyAppearance()
            save()
        }
    }

    /// Color theme names, one per appearance; the terminal, window chrome,
    /// and editor all derive from them. `Theme` keeps the resolved
    /// definitions (kero built-ins plus the ghostty catalog).
    @Published var themeDark: String {
        didSet {
            reloadThemeSelection()
            save()
        }
    }

    @Published var themeLight: String {
        didSet {
            reloadThemeSelection()
            save()
        }
    }

    /// Terminal font family name; empty string means the bundled default
    /// (JetBrains Mono).
    @Published var fontFamily: String {
        didSet { save() }
    }

    @Published var fontSize: Double {
        didSet { save() }
    }

    /// Base text size for project and tool panels. Each panel preserves its relative
    /// hierarchy for section labels, content, metadata, and controls.
    @Published var panelFontSize: Double {
        didSet { save() }
    }

    /// `auto` shows the toolbar only for Git projects; `always` keeps its Git
    /// panel entry point visible in every project; `hide` suppresses it.
    @Published var toolbarVisibility: ToolbarVisibility {
        didSet { save() }
    }

    @Published var gitViewMode: GitViewMode {
        didSet { save() }
    }

    /// Render terminal glyphs with slightly heavier strokes, like classic
    /// macOS font smoothing. Each backend maps this to its own rasterizer.
    /// Persisted as `terminal.font-thicken`; off by default so Kero's text
    /// matches a stock Ghostty install.
    @Published var fontThicken: Bool {
        didSet { save() }
    }

    @Published var cursorShape: TerminalCursorShape {
        didSet { save() }
    }

    @Published var cursorBlinking: Bool {
        didSet { save() }
    }

    /// Send Option-key chords to terminal programs as Alt/Meta instead of
    /// letting the active macOS input source produce text. Off by default so
    /// layouts such as Polish Pro can type their Option-composed characters.
    @Published var macosOptionAsAlt: Bool {
        didSet { save() }
    }

    /// Soft-wrap file editor lines to the viewport width. Off by default so
    /// long lines scroll horizontally.
    @Published var wrapLines: Bool {
        didSet { save() }
    }

    /// Restore each terminal's previous scrollback (as static, styled text)
    /// when the app relaunches, above the freshly started shell. Off by
    /// default: opt-in, and it writes captured output to disk.
    @Published var restoreTerminalHistory: Bool {
        didSet { save() }
    }

    init(configURL: URL = AppSettings.configURL) {
        settingsURL = configURL
        let savedLanguage = AppLanguage.saved
        activeLanguage = savedLanguage
        language = savedLanguage

        let existing = TOML.parse(at: settingsURL)
        let toml = existing ?? [:]
        workspaceConfiguration = Self.workspace(from: toml) ?? .standard
        theme = toml["theme"]?.string.flatMap(AppTheme.init(rawValue:)) ?? .system
        themeDark = Self.knownTheme(
            toml["theme-dark"]?.string,
            dark: true,
            fallback: Theme.defaultDarkThemeName
        )
        themeLight = Self.knownTheme(
            toml["theme-light"]?.string,
            dark: false,
            fallback: Theme.defaultLightThemeName
        )
        fontFamily = toml["font-family"]?.string ?? ""
        let size = toml["font-size"]?.double ?? Self.defaultFontSize
        fontSize = Self.fontSizeRange.contains(size) ? size : Self.defaultFontSize
        let panelSize = toml["panel.font-size"]?.double
            ?? Self.defaultPanelFontSize
        panelFontSize = Self.panelFontSizeRange.contains(panelSize)
            ? panelSize
            : Self.defaultPanelFontSize
        toolbarVisibility = ToolbarVisibility(
            rawValue: toml["toolbar.visibility"]?.string ?? ""
        ) ?? Self.defaultToolbarVisibility
        gitViewMode = GitViewMode(rawValue: toml["git.view-mode"]?.string ?? "") ?? .tree
        fontThicken = toml["terminal.font-thicken"]?.bool ?? false
        cursorShape = TerminalCursorShape(
            rawValue: toml["terminal.cursor-shape"]?.string ?? ""
        ) ?? .block
        cursorBlinking = toml["terminal.cursor-blinking"]?.bool ?? true
        macosOptionAsAlt = toml["terminal.macos-option-as-alt"]?.bool ?? false
        wrapLines = toml["editor.wrap-lines"]?.bool ?? false
        restoreTerminalHistory = toml["terminal.restore-history"]?.bool ?? false
        applyAppearance()
        reloadThemeSelection()
        if existing == nil { save() }
    }

    /// Parse the same typed workspace configuration for launch and for saves.
    /// Reading again before saving preserves manual edits made while Kero runs.
    private static func workspace(from toml: [String: TOML.Value]) -> DockWorkspaceConfiguration? {
        let standard = DockWorkspaceConfiguration.standard
        let keys = ["workspace.groups", "workspace.selected", "workspace.weights",
                    "workspace.add-actions", "workspace.edge-threshold"]
        let validTypes = keys.allSatisfy { key in
            guard let value = toml[key] else { return true }
            switch key {
            case "workspace.weights": return value.numbers != nil
            case "workspace.edge-threshold": return value.double != nil
            default: return value.strings != nil
            }
        }
        let groups = toml["workspace.groups"]?.strings ?? standard.groupNames
        let selected = toml["workspace.selected"]?.strings
            ?? (toml["workspace.groups"] == nil
                ? standard.selectedNames : Array(repeating: "", count: groups.count))
        let config = validTypes ? DockWorkspaceConfiguration(
            groupNames: groups,
            selectedNames: selected,
            weights: toml["workspace.weights"]?.numbers ?? standard.weights,
            actionNames: toml["workspace.add-actions"]?.strings ?? standard.actionNames,
            edgeThreshold: toml["workspace.edge-threshold"]?.double ?? standard.edgeThreshold
        ) : nil
        if config == nil, keys.contains(where: { toml[$0] != nil }) {
            NSLog("kero: invalid workspace configuration; using defaults")
        }
        return config
    }

    /// Pushes the current names into `Theme`, which resolves and caches the
    /// definitions. Called from `init` because `didSet` doesn't run there.
    private func reloadThemeSelection() {
        Theme.reloadSelection(light: themeLight, dark: themeDark)
    }

    /// A saved shared-theme name, or `fallback` when it is absent or no longer
    /// part of the cross-backend catalog, so Settings never shows an empty
    /// selection after upgrading from the larger Ghostty-only list.
    private static func knownTheme(
        _ name: String?, dark: Bool, fallback: String
    ) -> String {
        guard let name, Theme.isCommonTheme(named: name, dark: dark) else {
            return fallback
        }
        return name
    }

    /// Overrides the app-wide appearance so every window — and the terminal
    /// theme, which reads `NSApp.effectiveAppearance` — follows the choice.
    /// Called from `init` because `didSet` doesn't run during initialization.
    func applyAppearance() {
        NSApp?.appearance = theme.nsAppearance
    }

    func resetFont() {
        fontFamily = ""
        fontSize = Self.defaultFontSize
        panelFontSize = Self.defaultPanelFontSize
        fontThicken = false
    }

    func resetToDefaults() {
        resetFont()
        language = .system
        theme = .system
        themeDark = Theme.defaultDarkThemeName
        themeLight = Theme.defaultLightThemeName
        toolbarVisibility = Self.defaultToolbarVisibility
        gitViewMode = .tree
        cursorShape = .block
        cursorBlinking = true
        macosOptionAsAlt = false
        wrapLines = false
        restoreTerminalHistory = false
    }

    private func save() {
        var lines: [String] = []
        if theme != .system {
            lines.append("theme = \(TOML.quote(theme.rawValue))")
        }
        // Top-level like `theme`: the color theme drives the whole window,
        // not just the terminal.
        if themeDark != Theme.defaultDarkThemeName {
            lines.append("theme-dark = \(TOML.quote(themeDark))")
        }
        if themeLight != Theme.defaultLightThemeName {
            lines.append("theme-light = \(TOML.quote(themeLight))")
        }
        if !fontFamily.isEmpty {
            lines.append("font-family = \(TOML.quote(fontFamily))")
        }
        lines.append("font-size = \(TOML.number(fontSize))")
        if panelFontSize != Self.defaultPanelFontSize {
            lines.append("panel.font-size = \(TOML.number(panelFontSize))")
        }
        if toolbarVisibility != Self.defaultToolbarVisibility {
            lines.append("toolbar.visibility = \(TOML.quote(toolbarVisibility.rawValue))")
        }
        if gitViewMode != .tree {
            lines.append("git.view-mode = \(TOML.quote(gitViewMode.rawValue))")
        }
        if fontThicken {
            lines.append("terminal.font-thicken = true")
        }
        if cursorShape != .block {
            lines.append("terminal.cursor-shape = \(TOML.quote(cursorShape.rawValue))")
        }
        if !cursorBlinking {
            lines.append("terminal.cursor-blinking = false")
        }
        if macosOptionAsAlt {
            lines.append("terminal.macos-option-as-alt = true")
        }
        if wrapLines {
            lines.append("editor.wrap-lines = true")
        }
        if restoreTerminalHistory {
            lines.append("terminal.restore-history = true")
        }
        let standard = DockWorkspaceConfiguration.standard
        let configured = TOML.parse(at: settingsURL).flatMap(Self.workspace)
            ?? workspaceConfiguration
        if configured.groupNames != standard.groupNames {
            lines.append("workspace.groups = \(TOML.list(configured.groupNames))")
        }
        if configured.selectedNames != standard.selectedNames {
            lines.append("workspace.selected = \(TOML.list(configured.selectedNames))")
        }
        if configured.weights != standard.weights {
            lines.append("workspace.weights = \(TOML.list(configured.weights))")
        }
        if configured.actionNames != standard.actionNames {
            lines.append("workspace.add-actions = \(TOML.list(configured.actionNames))")
        }
        if configured.edgeThreshold != standard.edgeThreshold {
            lines.append("workspace.edge-threshold = \(TOML.number(configured.edgeThreshold))")
        }
        let dir = settingsURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n")
                .write(to: settingsURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("kero: failed to write \(settingsURL.path): \(error)")
        }
    }

}

/// TOML subset used by Kero: dotted keys, tables, primitive values,
/// one-line arrays and comments.
enum TOML {
    enum Value {
        case string(String)
        case number(Double)
        case bool(Bool)
        case array([Value])

        var string: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        var double: Double? {
            if case .number(let n) = self { return n }
            return nil
        }

        var bool: Bool? {
            if case .bool(let b) = self { return b }
            return nil
        }

        var strings: [String]? {
            guard case .array(let values) = self else { return nil }
            let strings = values.compactMap(\.string)
            return strings.count == values.count ? strings : nil
        }

        var numbers: [Double]? {
            guard case .array(let values) = self else { return nil }
            let numbers = values.compactMap(\.double)
            return numbers.count == values.count ? numbers : nil
        }
    }

    static func parse(at url: URL) -> [String: Value]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        var table = ""
        var result: [String: Value] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                table = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let value = parseValue(rawValue) else { continue }
            result[table.isEmpty ? key : "\(table).\(key)"] = value
        }
        return result
    }

    static func parseValue(_ raw: String) -> Value? {
        if raw.hasPrefix("[") {
            var values: [Value] = []
            var token = ""
            var depth = 0
            var quoted = false
            var escaped = false
            var closed = false
            for ch in raw {
                if closed {
                    if ch == "#" { break }
                    guard ch.isWhitespace else { return nil }
                    continue
                }
                if quoted {
                    token.append(ch)
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { quoted = false }
                    continue
                }
                switch ch {
                case "\"": quoted = true; token.append(ch)
                case "[":
                    depth += 1
                    if depth > 1 { token.append(ch) }
                case "]":
                    depth -= 1
                    guard depth >= 0 else { return nil }
                    if depth == 0 {
                        let value = token.trimmingCharacters(in: .whitespaces)
                        if !value.isEmpty {
                            guard let item = parseValue(value) else { return nil }
                            values.append(item)
                        }
                        closed = true
                    } else { token.append(ch) }
                case "," where depth == 1:
                    let value = token.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty, let item = parseValue(value) else { return nil }
                    values.append(item)
                    token = ""
                default: token.append(ch)
                }
            }
            return closed && !quoted && depth == 0 ? .array(values) : nil
        }
        if raw.hasPrefix("\"") {
            var out = ""
            var escaped = false
            for ch in raw.dropFirst() {
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    return .string(out)
                } else {
                    out.append(ch)
                }
            }
            return nil
        }
        // Unquoted: strip a trailing comment, then try bool/number.
        let bare = (raw.split(separator: "#", maxSplits: 1,
                              omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        switch bare {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return Double(bare).map(Value.number)
        }
    }

    static func list(_ values: [String]) -> String {
        "[" + values.map(quote).joined(separator: ", ") + "]"
    }

    static func list(_ values: [Double]) -> String {
        "[" + values.map(number).joined(separator: ", ") + "]"
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"", "\\": out.append("\\\(ch)")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    static func number(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15
            ? String(Int(n)) : String(n)
    }
}
