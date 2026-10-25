import AppKit
import Carbon
import Foundation
import XCTest

@MainActor
enum WorkspaceUITestSupport {
    private struct Session {
        let app: XCUIApplication
        let home: URL
        let language: String?
        let usesFixtureHome: Bool
    }

    private static var session: Session?
    private static let observer = UITestSessionObserver()
    private static var observing = false

    static func launch(
        in test: XCTestCase, language: String? = nil, configurationHome: URL? = nil
    ) throws -> XCUIApplication {
        if !observing {
            XCTestObservationCenter.shared.addTestObserver(observer)
            observing = true
        }

        let app: XCUIApplication
        let needsLaunch: Bool
        if let current = session,
           configurationHome == nil, !current.usesFixtureHome, current.language == language,
           current.app.state != .notRunning, resetWorkspace(current.app) {
            app = current.app
            needsLaunch = false
        } else {
            finishSession()
            app = XCUIApplication(bundleIdentifier: "chiimagnus.bailey.dev")
            guard app.state == .notRunning else {
                throw NSError(domain: "BaileyUITestLaunch", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "An unowned Bailey Dev is already running; tests cannot attach to it"
                ])
            }
            let home: URL
            if let configurationHome {
                home = configurationHome
            } else {
                home = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Bailey-UITest-Shared-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            }
            precondition(home.standardizedFileURL.path.hasPrefix(
                FileManager.default.temporaryDirectory.standardizedFileURL.path + "/Bailey-UITest-"
            ), "UI configuration must belong to an isolated fixture")
            // Keep one test-only HOME across ordinary methods; custom configurations
            // and language changes still need a distinct process.
            app.launchArguments = ["--isolated-ui-test", "-ApplePersistenceIgnoreState", "YES"]
            if let language { app.launchArguments += ["-AppleLanguages", "(\(language))"] }
            app.launchEnvironment["BAILEY_UI_TEST_RUN_ID"] = UUID().uuidString
            app.launchEnvironment["CFFIXED_USER_HOME"] = home.path
            app.launchEnvironment["HOME"] = home.path
            session = Session(app: app, home: home, language: language,
                              usesFixtureHome: configurationHome != nil)
            needsLaunch = true
        }

        let previousInput = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let unicodeHexWasEnabled = inputSource(id: "com.apple.keylayout.UnicodeHexInput") != nil
        let originalClipboard = try clipboardItems()
        test.addTeardownBlock { @MainActor in
            if let active = session, active.app === app, !active.usesFixtureHome,
               app.state != .notRunning {
                if !resetWorkspace(app) { finishSession() }
            } else {
                finishSession()
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !originalClipboard.isEmpty {
                XCTAssertTrue(pasteboard.writeObjects(originalClipboard))
            }
            XCTAssertEqual(TISSelectInputSource(previousInput), noErr,
                           "Restore the user's original input method after UI testing")
            if !unicodeHexWasEnabled,
               let unicodeHex = inputSource(id: "com.apple.keylayout.UnicodeHexInput") {
                XCTAssertEqual(TISDisableInputSource(unicodeHex), noErr,
                               "UI typing must not leave Unicode Hex Input enabled")
            }
        }
        if needsLaunch { app.launch() }
        app.activate()
        XCTAssertEqual(app.state, .runningForeground,
                       "Only Bailey Dev may receive keyboard actions from UI tests")
        // XCUITest can launch macOS without a WindowGroup scene.
        if !app.windows.firstMatch.waitForExistence(timeout: 4) {
            let newWindow = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["New Window", "新建窗口"])).firstMatch
            XCTAssertTrue(newWindow.waitForExistence(timeout: 8),
                          "Bailey Dev must expose the native New Window command")
            newWindow.click()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        let home = try XCTUnwrap(session?.home)
        let configuration = home.appendingPathComponent(".config/bailey-dev/config.toml")
        let initialized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: configuration.path)
        }, object: nil)
        guard XCTWaiter.wait(for: [initialized], timeout: 8) == .completed else {
            throw NSError(domain: "BaileyUITestLaunch", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Bailey Dev did not initialize its temporary configuration"
            ])
        }
        try selectASCIIInputSource()
        return app
    }

    private static func resetWorkspace(_ app: XCUIApplication) -> Bool {
        app.activate()
        guard app.windows.count == 1, !app.sheets.firstMatch.exists else { return false }
        if app.buttons["bailey.emptyState.addFolder"].exists { return true }
        let projects = app.buttons["bailey.dock.projects"]
        guard projects.exists else { return false }
        projects.click()
        let rows = app.buttons.matching(identifier: "bailey.project.row")
        for _ in 0..<40 {
            let count = rows.count
            if count == 0 {
                return app.buttons["bailey.emptyState.addFolder"].waitForExistence(timeout: 3)
            }
            rows.firstMatch.rightClick()
            let close = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["Close Project", "关闭项目"])).firstMatch
            guard close.waitForExistence(timeout: 3) else { return false }
            close.click()
            let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                rows.count < count
            }, object: nil)
            guard XCTWaiter.wait(for: [removed], timeout: 5) == .completed else { return false }
        }
        return false
    }

    static func finishSession() {
        guard let current = session else { return }
        session = nil
        if current.app.state != .notRunning { current.app.terminate() }
        if !current.usesFixtureHome {
            try? FileManager.default.removeItem(at: current.home)
        }
    }

    private static func inputSource(id: String) -> TISInputSource? {
        let inputs = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        return inputs.first { input in
            guard let value = TISGetInputSourceProperty(input, kTISPropertyInputSourceID) else {
                return false
            }
            return (Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String) == id
        }
    }

    private static func selectASCIIInputSource() throws {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let abc = inputSource(id: "com.apple.keylayout.ABC")
        let us = inputSource(id: "com.apple.keylayout.US")
        let systemASCII = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        let available = [abc, us, systemASCII].compactMap { $0 }
        guard let selected = available.first(where: { CFEqual($0, current) })
                ?? available.first,
              CFEqual(selected, current) || TISSelectInputSource(selected) == noErr else {
            throw NSError(domain: "BaileyUITestKeyboard", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "A selectable ASCII keyboard layout is required for literal shortcuts and paths"
            ])
        }
    }

    static func addFolder(
        _ url: URL, to app: XCUIApplication, in window: XCUIElement? = nil
    ) throws {
        let owner = window ?? app.windows.firstMatch
        let entry = owner.buttons["bailey.emptyState.addFolder"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.click()
        try choose(url, in: app, window: owner)
        XCTAssertFalse(entry.waitForExistence(timeout: 1),
                       "A folder selected through the native picker must create a project")
    }

    static func choose(
        _ url: URL, in app: XCUIApplication, window: XCUIElement? = nil
    ) throws {
        let owner = window ?? app.windows.firstMatch
        let sheet = owner.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15),
                      "The native file/folder picker should be attached to the current window")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.textFields["PathTextField"]
        guard pathField.waitForExistence(timeout: 10) else {
            throw NSError(domain: "BaileyUITestPicker", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Go to Folder input not found"])
        }
        pathField.click()
        // The system picker can restore a document-specific input method on focus.
        try selectASCIIInputSource()
        let pasteboard = NSPasteboard.general
        let preserved = try clipboardItems()
        pasteboard.clearContents()
        guard pasteboard.setString(url.path, forType: .string) else {
            pasteboard.clearContents()
            if !preserved.isEmpty { XCTAssertTrue(pasteboard.writeObjects(preserved)) }
            throw NSError(domain: "BaileyUITestPicker", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Cannot prepare the native picker path paste"
            ])
        }
        let changeCount = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == changeCount {
                pasteboard.clearContents()
                if !preserved.isEmpty { XCTAssertTrue(pasteboard.writeObjects(preserved)) }
            }
        }
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeKey("v", modifierFlags: .command)
        // NSOpenPanel sometimes resolves an absolute path immediately, closes
        // Go to Folder, and selects its target in the parent directory.
        // Both native states must identify the exact test target before Add/Open.
        func selectedExpectedTarget() -> Bool {
            let parent = url.deletingLastPathComponent().lastPathComponent
            guard sheet.popUpButtons["where popup"].value as? String == parent else { return false }
            return sheet.outlineRows.allElementsBoundByIndex.contains { row in
                guard row.isSelected else { return false }
                return row.textFields.allElementsBoundByIndex.contains { field in
                    guard let displayed = field.value as? String else { return false }
                    let visibleName = displayed.replacingOccurrences(of: "...", with: "")
                        .replacingOccurrences(of: "…", with: "")
                    return visibleName.count >= 8 && url.lastPathComponent.hasPrefix(visibleName)
                }
            }
        }
        let entered = app.textFields.matching(identifier: "PathTextField").matching(NSPredicate(
            format: "value IN %@", [url.path, url.path + "/"]
        )).firstMatch
        let resolved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if entered.exists { return true }
            if pathField.exists { return false }
            return selectedExpectedTarget()
        }, object: nil)
        guard XCTWaiter.wait(for: [resolved], timeout: 8) == .completed else {
            throw NSError(domain: "BaileyUITestPicker", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Go to Folder did not resolve the intended fixture path: \(url.path)"
            ])
        }
        if pathField.exists { pathField.typeKey(XCUIKeyboardKey.return, modifierFlags: []) }
        let confirmation = sheet.buttons["OKButton"]
        guard confirmation.waitForExistence(timeout: 15) else {
            throw NSError(domain: "BaileyUITestPicker", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Native picker confirmation missing"])
        }
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == YES"), object: confirmation
        )
        guard XCTWaiter.wait(for: [selected], timeout: 12) == .completed else {
            throw NSError(domain: "BaileyUITestPicker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Native picker did not select fixture path"])
        }
        confirmation.click()
    }

    static func clipboardItems() throws -> [NSPasteboardItem] {
        try (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else {
                    throw NSError(domain: "BaileyUITestPicker", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "Cannot preserve all clipboard items and types"
                    ])
                }
            }
            return copy
        }
    }

    static func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    static func fileRow(
        _ url: URL, in scope: XCUIElement, relativeTo repository: URL? = nil
    ) -> XCUIElement {
        let path: String
        if let repository {
            let prefix = repository.standardizedFileURL.path + "/"
            let absolute = url.standardizedFileURL.path
            precondition(absolute.hasPrefix(prefix), "Git fixture file must belong to its repository")
            path = String(absolute.dropFirst(prefix.count))
        } else {
            path = url.standardizedFileURL.path
        }
        return scope.descendants(matching: .any)
            .matching(identifier: "bailey.tree.file")
            .matching(NSPredicate(format: "label ENDSWITH %@", ", " + path))
            .firstMatch
    }

    static func fileTab(_ url: URL, in scope: XCUIElement) -> XCUIElement {
        scope.buttons.matching(identifier: "bailey.tab.file")
            .matching(NSPredicate(format: "value == %@", url.standardizedFileURL.path))
            .firstMatch
    }
}

private final class UITestSessionObserver: NSObject, XCTestObservation {
    func testBundleDidFinish(_ testBundle: Bundle) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { WorkspaceUITestSupport.finishSession() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { WorkspaceUITestSupport.finishSession() }
            }
        }
    }
}

struct WorkspaceUITestFixture {
    let root: URL

    init(in test: XCTestCase) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test.addTeardownBlock { [root] in
            try? FileManager.default.removeItem(at: root)
        }
    }

    func file(_ name: String, text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    func git(_ args: [String]) throws -> Data {
        // /usr/bin/git invokes xcrun, which cannot run inside XCTest's sandbox.
        let developerGit = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("usr/bin/git").path }
        let candidates = [developerGit, "/Library/Developer/CommandLineTools/usr/bin/git"]
            .compactMap { $0 }
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw NSError(domain: "BaileyUITestGit", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "A real Xcode or Command Line Tools Git binary is required"
            ])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // Inherited GIT_DIR/GIT_WORK_TREE override -C and can redirect fixture writes.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                             "-C", root.path] + args
        let diagnostics = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-Git-" + UUID().uuidString)
        let output = diagnostics.appendingPathExtension("stdout")
        try Data().write(to: diagnostics)
        try Data().write(to: output)
        let errorOutput = try FileHandle(forWritingTo: diagnostics)
        let outputHandle = try FileHandle(forWritingTo: output)
        defer {
            try? errorOutput.close()
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: diagnostics)
            try? FileManager.default.removeItem(at: output)
        }
        process.standardOutput = outputHandle
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? ""
            throw NSError(domain: "BaileyUITestGit", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return try Data(contentsOf: output)
    }

    func initializeGit() throws {
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "BaileyUITest"])
        try git(["config", "user.email", "tests@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["config", "core.hooksPath", "/dev/null"])
        try git(["add", "."])
        try git(["commit", "-qm", "E2E fixture history"])
    }

}
