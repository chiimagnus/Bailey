import AppKit
import Carbon
import Foundation
import XCTest

@MainActor
enum WorkspaceUITestSupport {
    static func launch(
        in test: XCTestCase, language: String? = nil, configurationHome: URL? = nil
    ) throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "chiimagnus.bailey.dev")
        guard app.state == .notRunning else {
            throw NSError(domain: "BaileyUITestLaunch", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bailey Dev is already running; refusing to terminate it or silently skip UI coverage"
            ])
        }
        let home = try configurationHome ?? WorkspaceUITestFixture(in: test).root
        precondition(home.standardizedFileURL.path.hasPrefix(
            FileManager.default.temporaryDirectory.standardizedFileURL.path + "/Bailey-UITest-"
        ), "UI configuration must belong to an isolated fixture")
        // Disable AppKit's separate saved-window state; Bailey's own isolated
        // SessionStore snapshots remain available for deliberate restart tests.
        app.launchArguments = ["--isolated-ui-test", "-ApplePersistenceIgnoreState", "YES"]
        if let language { app.launchArguments += ["-AppleLanguages", "(\(language))"] }
        app.launchEnvironment["BAILEY_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["CFFIXED_USER_HOME"] = home.path
        app.launchEnvironment["HOME"] = home.path
        let previousInput = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let unicodeHexWasEnabled = inputSource(id: "com.apple.keylayout.UnicodeHexInput") != nil
        test.addTeardownBlock { @MainActor in
            if app.state != .notRunning { app.terminate() }
            XCTAssertEqual(TISSelectInputSource(previousInput), noErr,
                           "Restore the user's original input method after UI testing")
            if !unicodeHexWasEnabled,
               let unicodeHex = inputSource(id: "com.apple.keylayout.UnicodeHexInput") {
                XCTAssertEqual(TISDisableInputSource(unicodeHex), noErr,
                               "UI typing must not leave Unicode Hex Input enabled")
            }
        }
        app.launch()
        app.activate()
        XCTAssertEqual(app.state, .runningForeground,
                       "Only Bailey Dev may receive keyboard actions from UI tests")
        // XCUITest can start the macOS process without opening its WindowGroup
        // scene. Use the real native New Window command; do not attach a fake NSWindow.
        if !app.windows.firstMatch.waitForExistence(timeout: 4) {
            let newWindow = app.menuItems.matching(NSPredicate(
                format: "title IN %@", ["New Window", "新建窗口"])).firstMatch
            XCTAssertTrue(newWindow.waitForExistence(timeout: 8),
                          "Bailey Dev must expose the native New Window command")
            newWindow.click()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
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
        guard let abc = inputSource(id: "com.apple.keylayout.ABC"),
              TISSelectInputSource(abc) == noErr else {
            throw NSError(domain: "BaileyUITestKeyboard", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ABC keyboard layout is required for literal shortcuts and paths"
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
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TEMPLATE_DIR"] = nil
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
