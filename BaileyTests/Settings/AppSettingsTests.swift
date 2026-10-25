import Foundation
import Observation
import XCTest
@testable import Bailey

@MainActor
final class AppSettingsTests: XCTestCase {
    private var directory: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configURL = directory.appendingPathComponent("config.toml")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultsAndRoundTrip() throws {
        let defaults = AppSettings(configURL: configURL)
        XCTAssertTrue(defaults.fontFamily.isEmpty)
        XCTAssertEqual(defaults.fontSize, 13)
        XCTAssertFalse(defaults.fontThicken)
        XCTAssertEqual(defaults.workspaceConfiguration.groupNames, DockWorkspaceConfiguration.standard.groupNames)
        XCTAssertEqual(TOML.parse(at: configURL)?["font-size"]?.double, 13)

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
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let customized = AppSettings(configURL: configURL)
        XCTAssertEqual(customized.fontFamily, "Fixture\"Font")
        XCTAssertEqual(customized.fontSize, 18)
        XCTAssertEqual(customized.panelFontSize, 16)
        XCTAssertTrue(customized.fontThicken)
        XCTAssertEqual(customized.workspaceConfiguration.groupNames, ["projects,files", "git"])
        XCTAssertFalse(customized.workspaceConfiguration.addActions.map(\.rawValue).contains("info"))

        customized.fontSize = 19
        XCTAssertEqual(AppSettings(configURL: configURL).fontSize, 19)
    }

    func testCheckoutConsentIsPersistedAndResetWithTemporaryConfig() throws {
        let domain = "bailey-checkout-consent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["en"], forKey: "AppleLanguages")
        let settings = AppSettings(configURL: configURL, languageDefaults: defaults, languageDomain: domain)
        XCTAssertEqual(settings.language, .english)
        XCTAssertFalse(settings.gitAlwaysAcceptCheckout)
        XCTAssertFalse(settings.gitAlwaysProceedPushTag)
        settings.gitAlwaysAcceptCheckout = true
        settings.gitAlwaysProceedPushTag = true
        let saved = AppSettings(configURL: configURL)
        XCTAssertTrue(saved.gitAlwaysAcceptCheckout)
        XCTAssertTrue(saved.gitAlwaysProceedPushTag)
        settings.resetToDefaults()
        XCTAssertFalse(settings.gitAlwaysAcceptCheckout)
        XCTAssertFalse(settings.gitAlwaysProceedPushTag)
        let reset = AppSettings(configURL: configURL)
        XCTAssertFalse(reset.gitAlwaysAcceptCheckout)
        XCTAssertFalse(reset.gitAlwaysProceedPushTag)
    }

    func testNativeSettingsResetAvailabilityTracksGitConsentFlags() throws {
        let domain = "bailey-native-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(configURL: configURL,
                                   languageDefaults: defaults, languageDomain: domain)
        let view = SettingsView(application: WorkspaceApplication(), settings: settings)
        XCTAssertFalse(view.hasCustomizedPreferences)
        settings.gitAlwaysAcceptCheckout = true
        XCTAssertTrue(view.hasCustomizedPreferences)
        settings.gitAlwaysAcceptCheckout = false
        XCTAssertFalse(view.hasCustomizedPreferences)
        settings.gitAlwaysProceedPushTag = true
        XCTAssertTrue(view.hasCustomizedPreferences)
        settings.resetToDefaults()
        XCTAssertFalse(view.hasCustomizedPreferences)
        XCTAssertFalse(AppSettings(configURL: configURL).gitAlwaysProceedPushTag)
    }

    func testObservationTracksAllNativeTerminalSettingsWithTemporaryConfig() {
        let configured = AppSettings(configURL: configURL)

        let fields: [(name: String, read: () -> Any, change: () -> Void)] = [
            ("font family", { configured.fontFamily }, { configured.fontFamily = "Fixture Mono" }),
            ("font size", { configured.fontSize }, { configured.fontSize = 18 }),
            ("font strokes", { configured.fontThicken }, { configured.fontThicken = true }),
            ("appearance", { configured.theme }, { configured.theme = .dark }),
            ("dark palette", { configured.themeDark }, { configured.themeDark = "Ayu" }),
            ("light palette", { configured.themeLight },
             { configured.themeLight = "Apple System Colors Light" }),
            ("Option as Alt", { configured.macosOptionAsAlt },
             { configured.macosOptionAsAlt = true }),
            ("cursor shape", { configured.cursorShape }, { configured.cursorShape = .bar }),
            ("cursor blinking", { configured.cursorBlinking },
             { configured.cursorBlinking = false }),
        ]
        for field in fields {
            let notified = expectation(description: field.name)
            withObservationTracking({ _ = field.read() }) {
                notified.fulfill()
            }
            field.change()
            wait(for: [notified], timeout: 1)
        }

        let saved = AppSettings(configURL: configURL)
        XCTAssertEqual(saved.fontFamily, "Fixture Mono")
        XCTAssertEqual(saved.fontSize, 18)
        XCTAssertTrue(saved.fontThicken)
        XCTAssertEqual(saved.theme, .dark)
        XCTAssertEqual(saved.themeDark, "Ayu")
        XCTAssertEqual(saved.themeLight, "Apple System Colors Light")
        XCTAssertTrue(saved.macosOptionAsAlt)
        XCTAssertEqual(saved.cursorShape, .bar)
        XCTAssertFalse(saved.cursorBlinking)
    }

    func testThemeRevisionInvalidatesObserversAndUpdatesNativePalette() {
        let settings = AppSettings(configURL: configURL)
        let previousLight = Theme.terminal(dark: false).name
        let previousDark = Theme.terminal(dark: true).name
        defer { Theme.reloadSelection(light: previousLight, dark: previousDark) }

        let oldRevision = Theme.changes.revision
        let invalidated = expectation(description: "theme revision changed")
        withObservationTracking({ _ = Theme.changes.revision }) {
            invalidated.fulfill()
        }
        settings.themeDark = "Ayu"
        XCTAssertEqual(Theme.changes.revision, oldRevision,
                       "Independent configuration changes must not alter the app palette")
        Theme.reloadSelection(light: settings.themeLight, dark: settings.themeDark)
        wait(for: [invalidated], timeout: 1)
        XCTAssertEqual(Theme.changes.revision, oldRevision + 1)
        XCTAssertEqual(Theme.terminal(dark: true).name, "Ayu")
        settings.themeLight = "Apple System Colors Light"
        XCTAssertEqual(Theme.changes.revision, oldRevision + 1,
                       "Independent configuration changes must not alter the app palette")
        Theme.reloadSelection(light: settings.themeLight, dark: settings.themeDark)
        XCTAssertEqual(Theme.changes.revision, oldRevision + 2)
        XCTAssertEqual(Theme.terminal(dark: false).name, "Apple System Colors Light")
    }

    func testIndependentAppearanceChangesNeverInvalidateApplicationTheme() throws {
        let domain = "bailey-appearance-fixture-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let oldRevision = Theme.changes.revision
        let oldLight = Theme.terminal(dark: false).name
        let oldDark = Theme.terminal(dark: true).name
        let settings = AppSettings(configURL: configURL,
                                   languageDefaults: defaults, languageDomain: domain)
        settings.theme = .dark
        settings.themeDark = "Ayu"
        settings.themeLight = "Apple System Colors Light"
        settings.resetToDefaults()
        XCTAssertEqual(Theme.changes.revision, oldRevision)
        XCTAssertEqual(Theme.terminal(dark: false).name, oldLight)
        XCTAssertEqual(Theme.terminal(dark: true).name, oldDark)
    }

    func testInvalidValuesFallBackAndFailedWritePreservesExistingFile() throws {
        try "font-thicken = true\nfont-size = 100\nworkspace.groups = [1]\n".write(
            to: configURL, atomically: true, encoding: .utf8
        )
        let invalid = AppSettings(configURL: configURL)
        XCTAssertFalse(invalid.fontThicken)
        XCTAssertEqual(invalid.fontSize, 13)
        XCTAssertEqual(invalid.workspaceConfiguration.groupNames, DockWorkspaceConfiguration.standard.groupNames)

        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("preserve".utf8).write(to: blocked)
        let unwritable = AppSettings(configURL: blocked.appendingPathComponent("config.toml"))
        unwritable.fontSize = 20
        XCTAssertEqual(try String(contentsOf: blocked, encoding: .utf8), "preserve")
    }
}
