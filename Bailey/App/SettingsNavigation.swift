import Foundation

/// A window-local navigation history; the settings manager never owns UI navigation.
struct SettingsNavigationHistory {
    private(set) var current: SettingsPage = .general
    private var backStack: [SettingsPage] = []
    private var forwardStack: [SettingsPage] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    mutating func select(_ page: SettingsPage) {
        guard current != page else { return }
        backStack.append(current)
        current = page
        forwardStack.removeAll()
    }

    mutating func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
    }

    mutating func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
    }
}

/// One entry per *existing* control. Search targets the actual Form row, not
/// just the page; titles use the same localization keys as the controls.
enum SettingsField: String, CaseIterable, Identifiable {
    case appearance, language, toolbar, reset
    case darkTheme, lightTheme, fontFamily, fontSize, preview
    case cursorShape, cursorBlinking, fontThicken, optionAsAlt, restoreHistory
    case panelFontSize, gitLayout, wrapLines
    case barkDestinations, portForwarding

    var id: Self { self }

    var page: SettingsPage {
        switch self {
        case .appearance, .language, .toolbar, .reset: .general
        case .darkTheme, .lightTheme, .fontFamily, .fontSize, .preview,
             .cursorShape, .cursorBlinking, .fontThicken, .optionAsAlt, .restoreHistory: .terminal
        case .panelFontSize, .gitLayout, .wrapLines: .workspace
        case .barkDestinations: .notifications
        case .portForwarding: .portForwarding
        }
    }

    var title: String {
        switch self {
        case .appearance: String(localized: "Theme", table: "Settings")
        case .language: String(localized: "Language", table: "Settings")
        case .toolbar: String(localized: "Toolbar", table: "Settings")
        case .reset: String(localized: "Reset to Defaults", table: "Settings")
        case .darkTheme: String(localized: "Dark theme", table: "Settings")
        case .lightTheme: String(localized: "Light theme", table: "Settings")
        case .fontFamily: String(localized: "Family", table: "Settings")
        case .fontSize: String(localized: "Font size", table: "Settings")
        case .preview: String(localized: "Preview", table: "Settings")
        case .cursorShape: String(localized: "Cursor shape", table: "Terminal")
        case .cursorBlinking: String(localized: "Blink cursor", table: "Terminal")
        case .fontThicken: String(localized: "Thicken font strokes", table: "Settings")
        case .optionAsAlt: String(localized: "Use Option as Alt/Meta", table: "Settings")
        case .restoreHistory: String(localized: "Restore session history on relaunch", table: "Settings")
        case .panelFontSize: String(localized: "Panel font size", table: "Settings")
        case .gitLayout: String(localized: "File layout", table: "Settings")
        case .wrapLines: String(localized: "Wrap lines to editor width", table: "Settings")
        case .barkDestinations: String(localized: "Phone Notifications", table: "Settings")
        case .portForwarding: String(localized: "Port Forwarding", table: "Settings")
        }
    }

    var section: String {
        switch self {
        case .appearance, .language, .toolbar: String(localized: "Appearance", table: "Settings")
        case .reset: String(localized: "Reset", table: "Settings")
        case .darkTheme, .lightTheme: String(localized: "Colors", table: "Settings")
        case .fontFamily, .fontSize: String(localized: "Font", table: "Settings")
        case .preview: String(localized: "Preview", table: "Settings")
        case .cursorShape, .cursorBlinking, .fontThicken, .optionAsAlt, .restoreHistory:
            String(localized: "Terminal", table: "Settings")
        case .panelFontSize: String(localized: "Panels", table: "Settings")
        case .gitLayout: String(localized: "Git", table: "Settings")
        case .wrapLines: String(localized: "Text Editing", table: "Settings")
        case .barkDestinations: String(localized: "Phone Notifications", table: "Settings")
        case .portForwarding: String(localized: "Port Forwarding", table: "Settings")
        }
    }

    private var aliases: String {
        switch self {
        case .appearance: "appearance dark light theme system 外观 主题"
        case .language: "language english chinese locale 语言 中文 英文"
        case .toolbar: "toolbar auto show hide 工具栏 显示 隐藏"
        case .reset: "reset defaults restore preferences 恢复 默认 重置"
        case .darkTheme: "dark theme terminal color 夜间 暗色 终端 配色"
        case .lightTheme: "light theme terminal color 白天 亮色 终端 配色"
        case .fontFamily: "font family monospace typeface 字体 家族"
        case .fontSize: "font size terminal 字体 字号"
        case .preview: "font preview sample render 字体 预览"
        case .cursorShape: "cursor shape caret block bar underline 光标 形状"
        case .cursorBlinking: "cursor blink blinking 闪烁 光标"
        case .fontThicken: "font stroke smoothing bold 加粗 字体"
        case .optionAsAlt: "option alt meta keyboard modifier 键盘 修饰键"
        case .restoreHistory: "history restore scrollback relaunch terminal 终端 历史"
        case .panelFontSize: "panel font size sidebar 字号 面板 字体"
        case .gitLayout: "git layout files tree list 文件 布局 树 列表"
        case .wrapLines: "editor word wrap line wrapping 自动换行 折行 编辑器"
        case .barkDestinations: "bark phone notification push alerts 通知 手机 推送"
        case .portForwarding: "port forwarding ssh tunnel local remote tcp 隧道 端口 转发"
        }
    }

    static func search(_ query: String, includeNotifications: Bool) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return [] }
        return allCases.filter { field in
            (includeNotifications || field.page != .notifications)
                && terms.allSatisfy {
                    "\(field.title) \(field.section) \(field.page.title) \(field.aliases)"
                        .localizedStandardContains(String($0))
                }
        }
    }
}
