import AppKit
import Foundation

enum AppTheme: String {
    case system, light, dark
    var nsAppearance: NSAppearance? { nil }
}
enum TerminalCursorShape: String { case block, bar, underline }
enum Theme {
    static let defaultDarkThemeName = "fixture-dark"
    static let defaultLightThemeName = "fixture-light"
    static func isCommonTheme(named name: String, dark: Bool) -> Bool {
        name == (dark ? defaultDarkThemeName : defaultLightThemeName)
    }
    static func reloadSelection(light: String, dark: String) {}
}

@main
enum SettingsCheck {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.toml")
        UserDefaults.standard.register(defaults: ["terminalFontFamily": "legacy fixture", "terminalFontSize": 27])
        let defaults = AppSettings(configURL: url)
        precondition(defaults.fontFamily.isEmpty && defaults.fontSize == 13 && !defaults.fontThicken)
        precondition(defaults.workspaceConfiguration.groupNames == DockWorkspaceConfiguration.standard.groupNames)
        precondition(TOML.parse(at: url)?["font-size"]?.double == 13)
        try """
        font-family = "Fixture\\\"Font"
        font-size = 18
        panel.font-size = 16
        terminal.font-thicken = true
        workspace.groups = ["projects,files", "git,info"]
        workspace.selected = ["files", "git"]
        workspace.weights = [2, 3]
        workspace.add-actions = ["projects", "session", "files", "git", "info"]
        workspace.edge-threshold = 0.3
        """.write(to: url, atomically: true, encoding: .utf8)
        let customized = AppSettings(configURL: url)
        precondition(customized.fontFamily == "Fixture\"Font" && customized.fontSize == 18)
        precondition(customized.panelFontSize == 16 && customized.fontThicken)
        precondition(customized.workspaceConfiguration.groupNames == ["projects,files", "git,info"])
        customized.fontSize = 19
        let roundtrip = AppSettings(configURL: url)
        precondition(roundtrip.fontFamily == customized.fontFamily && roundtrip.fontSize == 19)
        precondition(roundtrip.workspaceConfiguration.weights == [2, 3])
        try """
        workspace.groups = ["projects", "files", "git,info"]
        workspace.selected = ["projects", "files", "info"]
        workspace.weights = [1, 3, 2]
        workspace.edge-threshold = 0.25
        """.write(to: url, atomically: true, encoding: .utf8)
        customized.fontSize = 20
        let manuallyEdited = AppSettings(configURL: url)
        precondition(manuallyEdited.fontSize == 20)
        precondition(manuallyEdited.workspaceConfiguration.groupNames == ["projects", "files", "git,info"])
        precondition(manuallyEdited.workspaceConfiguration.weights == [1, 3, 2])
        try "font-thicken = true\nfont-size = 100\nworkspace.groups = [1]\n".write(to: url, atomically: true, encoding: .utf8)
        let invalid = AppSettings(configURL: url)
        precondition(!invalid.fontThicken && invalid.fontSize == 13)
        precondition(invalid.workspaceConfiguration.groupNames == DockWorkspaceConfiguration.standard.groupNames)
        try "font-thicken = true\nterminal.font-thicken = false\n".write(to: url, atomically: true, encoding: .utf8)
        precondition(!AppSettings(configURL: url).fontThicken)
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("preserve".utf8).write(to: blocked)
        let unwritable = AppSettings(configURL: blocked.appendingPathComponent("config.toml"))
        unwritable.fontSize = 20
        let preserved = try String(contentsOf: blocked, encoding: .utf8)
        precondition(preserved == "preserve")
        if CommandLine.arguments.count == 2 {
            let current = URL(fileURLWithPath: CommandLine.arguments[1])
            let copy = directory.appendingPathComponent("current-copy.toml")
            try Data(contentsOf: current).write(to: copy)
            let loaded = AppSettings(configURL: copy)
            let previousGroups = loaded.workspaceConfiguration.groupNames
            loaded.fontSize = loaded.fontSize
            let reloaded = AppSettings(configURL: copy)
            precondition(loaded.fontSize == reloaded.fontSize)
            precondition(previousGroups == reloaded.workspaceConfiguration.groupNames)
        }
        print("PASS: real settings default/custom roundtrip, manual workspace preservation, obsolete keys ignored, invalid types and failed writes preserve data")
    }
}
