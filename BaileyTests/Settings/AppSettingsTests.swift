import AppKit
import Foundation
import Observation
import SwiftUI
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
        workspace.groups = ["projects,files", "git"]
        workspace.selected = ["files", "git"]
        workspace.weights = [2, 3]
        workspace.add-actions = ["projects", "session", "files", "git"]
        workspace.edge-threshold = 0.3
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let customized = AppSettings(configURL: configURL)
        XCTAssertEqual(customized.fontFamily, "Fixture\"Font")
        XCTAssertEqual(customized.fontSize, 18)
        XCTAssertEqual(customized.panelFontSize, 16)
        XCTAssertTrue(customized.fontThicken)
        XCTAssertEqual(customized.workspaceConfiguration.groupNames, ["projects,files", "git"])
        XCTAssertEqual(customized.workspaceConfiguration.actionNames,
                       ["projects", "session", "files", "git"])

        customized.fontSize = 19
        XCTAssertEqual(AppSettings(configURL: configURL).fontSize, 19)
    }

    func testCustomHostRulesPersistWithoutUnrequestedGitGraphPreferences() throws {
        let settings = AppSettings(configURL: configURL)
        XCTAssertTrue(settings.gitHostingRules.isEmpty)

        try settings.applyGitHostingRules([
            "git.company.internal=gitlab", "github.enterprise.test=github"
        ])
        let saved = try XCTUnwrap(TOML.parse(at: configURL))
        XCTAssertEqual(saved["git.host-providers"]?.strings, settings.gitHostingRules)

        let restored = AppSettings(configURL: configURL)
        XCTAssertEqual(restored.gitHostProviders["git.company.internal"], .gitlab)
        let before = try Data(contentsOf: configURL)
        XCTAssertThrowsError(try restored.applyGitHostingRules(["invalid/host=github"]))
        XCTAssertEqual(try Data(contentsOf: configURL), before)

        restored.resetToDefaults()
        XCTAssertTrue(AppSettings(configURL: configURL).gitHostingRules.isEmpty)
        let keys = try XCTUnwrap(TOML.parse(at: configURL))
        for obsolete in ["git.graph.show-stashes", "git.graph.show-tags",
                         "git.graph.show-remote-labels", "git.fetch-prune"] {
            XCTAssertNil(keys[obsolete], "\(obsolete) was not requested and must not be persisted")
        }
    }

    func testObsoleteInfoWorkspaceNamesAreRejectedAndOnlyNormalizedOnSave() throws {
        let validConfig = """
        font-family = "Fixture Font"
        font-size = 18
        panel.font-size = 16
        workspace.groups = ["projects,files", "git"]
        workspace.selected = ["files", "git"]
        workspace.weights = [2, 3]
        workspace.add-actions = ["projects", "session", "files", "git"]
        workspace.edge-threshold = 0.3
        """
        for (existing, obsolete) in [
            ("workspace.groups = [\"projects,files\", \"git\"]",
             "workspace.groups = [\"projects,files\", \"git,info\"]"),
            ("workspace.selected = [\"files\", \"git\"]",
             "workspace.selected = [\"files\", \"info\"]"),
            ("workspace.add-actions = [\"projects\", \"session\", \"files\", \"git\"]",
             "workspace.add-actions = [\"projects\", \"session\", \"files\", \"git\", \"info\"]"),
        ] {
            let source = validConfig.replacingOccurrences(of: existing, with: obsolete) + "\n"
            try source.write(to: configURL, atomically: true, encoding: .utf8)
            let bytes = try Data(contentsOf: configURL)
            let settings = AppSettings(configURL: configURL)
            XCTAssertEqual(settings.workspaceConfiguration.groupNames,
                           DockWorkspaceConfiguration.standard.groupNames)
            XCTAssertEqual(settings.fontFamily, "Fixture Font")
            XCTAssertEqual(settings.fontSize, 18)
            XCTAssertEqual(settings.panelFontSize, 16)
            XCTAssertEqual(try Data(contentsOf: configURL), bytes,
                           "Loading must not rewrite the user's original config")
            settings.fontSize = 20
            let saved = try XCTUnwrap(TOML.parse(at: configURL))
            XCTAssertEqual(saved["font-family"]?.string, "Fixture Font")
            XCTAssertEqual(saved["font-size"]?.double, 20)
            XCTAssertNil(saved["workspace.groups"],
                         "An actual save normalizes the rejected layout to standard")
            XCTAssertNil(saved["workspace.add-actions"])
        }
    }

    func testFilesExcludeDefaultsExplicitEmptyAndPersistence() throws {
        let settings = AppSettings(configURL: configURL)
        XCTAssertEqual(settings.filesExclude, ["**/.git"])
        XCTAssertNil(TOML.parse(at: configURL)?["files.exclude"])

        try settings.applyFilesExclude([])
        XCTAssertEqual(settings.filesExclude, [])
        XCTAssertEqual(TOML.parse(at: configURL)?["files.exclude"]?.strings, [])
        settings.fontSize = 17
        XCTAssertEqual(AppSettings(configURL: configURL).filesExclude, [],
                       "Other settings must preserve an explicit empty rule list")

        try settings.applyFilesExclude(["**/.git", "**/node_modules", "**/*.log"])
        let before = try Data(contentsOf: configURL)
        for invalid in ["../outside", "a/[bc]", "/tmp", "folder//other"] {
            XCTAssertThrowsError(try settings.applyFilesExclude([invalid]))
            XCTAssertEqual(settings.filesExclude, ["**/.git", "**/node_modules", "**/*.log"])
            XCTAssertEqual(try Data(contentsOf: configURL), before)
        }
        settings.resetToDefaults()
        XCTAssertEqual(settings.filesExclude, ["**/.git"])
        XCTAssertEqual(AppSettings(configURL: configURL).filesExclude, ["**/.git"])
        XCTAssertNil(TOML.parse(at: configURL)?["files.exclude"])
    }

    func testFilesExcludeInvalidDiskAndFailedApplyLeaveEffectiveValuesUnchanged() throws {
        try "files.exclude = [true]\n".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(AppSettings(configURL: configURL).filesExclude, ["**/.git"])
        try "files.exclude = [\"../outside\"]\n".write(
            to: configURL, atomically: true, encoding: .utf8
        )
        XCTAssertEqual(AppSettings(configURL: configURL).filesExclude, ["**/.git"])

        let blocked = directory.appendingPathComponent("blocked-config")
        try Data("unmodified".utf8).write(to: blocked)
        let settings = AppSettings(configURL: blocked.appendingPathComponent("config.toml"))
        XCTAssertEqual(settings.filesExclude, ["**/.git"])
        XCTAssertThrowsError(try settings.applyFilesExclude([]))
        XCTAssertEqual(settings.filesExclude, ["**/.git"])
        XCTAssertEqual(try Data(contentsOf: blocked), Data("unmodified".utf8))
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
        try settings.applyFilesExclude([])
        XCTAssertTrue(view.hasCustomizedPreferences,
                      "Explicitly showing excluded Files must enable Reset to Defaults")
        settings.resetToDefaults()
        XCTAssertFalse(view.hasCustomizedPreferences)
        XCTAssertEqual(AppSettings(configURL: configURL).filesExclude,
                       AppSettings.defaultFilesExclude)
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

    func testMountedSettingsSidebarActuallyRepaintsGhosttyAccent() throws {
        let originalLight = Theme.terminal(dark: false).name
        let originalDark = Theme.terminal(dark: true).name
        defer { Theme.reloadSelection(light: originalLight, dark: originalDark) }

        for (dark, first, second) in [
            (true, "Catppuccin Macchiato", "Dracula"),
            (false, "Rose Pine Dawn", "Ayu Light"),
        ] {
            Theme.reloadSelection(
                light: dark ? "Default Light" : first,
                dark: dark ? first : "Default Dark"
            )
            let host = NSHostingView(rootView: SettingsView(
                application: WorkspaceApplication(), settings: AppSettings(configURL: configURL)
            ))
            let window = NSWindow(
                contentRect: NSRect(x: -950, y: -950, width: 840, height: 560),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }

            func capture() throws -> NSBitmapImageRep {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                return bitmap
            }
            let before = try capture()
            Theme.reloadSelection(
                light: dark ? "Default Light" : second,
                dark: dark ? second : "Default Dark"
            )
            var changed = 0
            var selectionPixels = 0
            let accent = Theme.terminal(dark: dark).accentNSColor.usingColorSpace(.deviceRGB)!
            let repainted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let after = try? capture() else { return false }
                let scale = CGFloat(after.pixelsWide) / host.bounds.width
                changed = 0
                for y in Int(55 * scale)..<Int(375 * scale) {
                    for x in Int(15 * scale)..<Int(50 * scale) {
                        guard let old = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              let new = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                        else { continue }
                        let delta = abs(old.redComponent - new.redComponent)
                            + abs(old.greenComponent - new.greenComponent)
                            + abs(old.blueComponent - new.blueComponent)
                        if delta > 0.16 { changed += 1 }
                    }
                }
                func matchesAccent(_ x: Int, _ y: Int) -> Bool {
                    guard let sample = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                    else { return false }
                    return max(abs(sample.redComponent - accent.redComponent),
                               abs(sample.greenComponent - accent.greenComponent),
                               abs(sample.blueComponent - accent.blueComponent)) < 0.25
                }
                selectionPixels = 0
                for y in Int(20 * scale)..<Int(100 * scale) {
                    for x in Int(64 * scale)..<Int(175 * scale) where matchesAccent(x, y) {
                        selectionPixels += 1
                    }
                }
                return changed > 30 && selectionPixels > 100
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [repainted], timeout: 3), .completed,
                "Settings icons and selected row must repaint for \(first) → \(second): changed=\(changed), selected=\(selectionPixels)")
        }
    }

    func testSettingsSelectedSidebarTitleUsesLightForeground() throws {
        let savedLight = Theme.terminal(dark: false).name
        let savedDark = Theme.terminal(dark: true).name
        defer { Theme.reloadSelection(light: savedLight, dark: savedDark) }

        Theme.reloadSelection(light: "Ayu Light", dark: "GitHub Dark")
        for dark in [false, true] {
            let host = NSHostingView(rootView: SettingsView(
                application: WorkspaceApplication(), settings: AppSettings(configURL: configURL)
            ))
            let window = NSWindow(
                contentRect: NSRect(x: -980, y: -980, width: 840, height: 560),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            var selectedTitlePixels = 0
            for y in Int(37 * scale)..<Int(60 * scale) {
                for x in Int(45 * scale)..<Int(92 * scale) {
                    guard let rgb = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                    else { continue }
                    if min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) > 0.85 {
                        selectedTitlePixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(selectedTitlePixels, 35,
                "Selected sidebar title must be light in \(dark ? "dark" : "light") appearance; found \(selectedTitlePixels) pixels")
        }
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
