import Carbon
import Foundation
import XCTest

@MainActor
enum WorkspaceUITestSupport {
    static func launch(in test: XCTestCase, language: String? = nil) throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "chiimagnus.bailey.dev")
        guard app.state == .notRunning else {
            throw XCTSkip("UI automation must not terminate an existing Bailey Dev instance")
        }
        app.launchArguments = ["--isolated-ui-test"]
        if let language { app.launchArguments += ["-AppleLanguages", "(\(language))"] }
        app.launchEnvironment["BAILEY_UI_TEST_RUN_ID"] = UUID().uuidString
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
        try selectASCIIInputSource()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        app.activate()
        XCTAssertEqual(app.state, .runningForeground,
                       "Only Bailey Dev may receive keyboard actions from UI tests")
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

    static func addFolder(_ url: URL, to app: XCUIApplication) throws {
        let entry = app.buttons["bailey.emptyState.addFolder"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.click()
        try choose(url, in: app)
        XCTAssertFalse(entry.waitForExistence(timeout: 1),
                       "A folder selected through the native picker must create a project")
    }

    static func choose(_ url: URL, in app: XCUIApplication) throws {
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15),
                      "The native file/folder picker should be attached to the current window")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.textFields["PathTextField"]
        guard pathField.waitForExistence(timeout: 10) else {
            throw NSError(domain: "BaileyUITestPicker", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Go to Folder input not found"])
        }
        pathField.click()
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(url.path)
        guard pathField.value as? String == url.path else {
            throw NSError(domain: "BaileyUITestPicker", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Incomplete path in Go to Folder input"])
        }
        pathField.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
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

    func git(_ args: [String]) throws {
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
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                             "-C", root.path] + args
        let diagnostics = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-Git-" + UUID().uuidString)
        try Data().write(to: diagnostics)
        let errorOutput = try FileHandle(forWritingTo: diagnostics)
        defer {
            try? errorOutput.close()
            try? FileManager.default.removeItem(at: diagnostics)
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? ""
            throw NSError(domain: "BaileyUITestGit", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    func initializeGit() throws {
        try git(["init", "-q", "-b", "main"])
        try git(["add", "."])
        try git(["-c", "user.name=BaileyUITest", "-c",
                 "user.email=tests@example.invalid", "commit", "-qm", "E2E fixture history"])
    }

}
