import Foundation
import XCTest

@MainActor
enum WorkspaceUITestSupport {
    static func launch(in test: XCTestCase, language: String? = nil) throws -> XCUIApplication {
        let app = XCUIApplication()
        guard app.state == .notRunning else {
            throw XCTSkip("UI automation must not terminate an existing Bailey instance")
        }
        app.launchArguments = ["--isolated-ui-test"]
        if let language { app.launchArguments += ["-AppleLanguages", "(\(language))"] }
        app.launchEnvironment["BAILEY_UI_TEST_RUN_ID"] = UUID().uuidString
        test.addTeardownBlock { @MainActor in
            if app.state != .notRunning { app.terminate() }
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        return app
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
        app.typeText(url.path)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let confirmation = sheet.buttons["OKButton"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 15),
                      "The native picker must expose its standard confirm action")
        XCTAssertTrue(confirmation.isEnabled, "The selected path must be valid")
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
        // /usr/bin/git is an xcrun shim and cannot run inside XCTest's App Sandbox.
        let executable = "/Library/Developer/CommandLineTools/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw NSError(domain: "BaileyUITestGit", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Xcode Command Line Tools Git is required for UI test fixtures"
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
