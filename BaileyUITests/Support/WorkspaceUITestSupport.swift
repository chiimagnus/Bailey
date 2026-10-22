import Foundation
import XCTest

@MainActor
enum WorkspaceUITestSupport {
    static func launch(in test: XCTestCase) throws -> XCUIApplication {
        let app = XCUIApplication()
        guard app.state == .notRunning else {
            throw XCTSkip("UI automation must not terminate an existing Bailey instance")
        }
        app.launchArguments = ["--isolated-ui-test"]
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
        try choose(url, button: "Add", in: app)
        XCTAssertFalse(entry.waitForExistence(timeout: 1),
                       "A folder selected through the native picker must create a project")
    }

    static func choose(_ url: URL, button: String, in app: XCUIApplication) throws {
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 15),
                      "The native file/folder picker should be attached to Bailey")
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(url.path)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let confirmation = app.sheets.firstMatch.buttons[button].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 15),
                      "The native picker must expose its \(button) action")
        XCTAssertTrue(confirmation.isEnabled, "The selected path must be valid")
        confirmation.click()
    }

    static func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    static func fileRow(_ url: URL, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "bailey.tree.file")
            .matching(NSPredicate(format: "label CONTAINS %@", url.lastPathComponent))
            .firstMatch
    }

    static func fileTab(_ url: URL, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "bailey.tab.file")
            .matching(NSPredicate(format: "label CONTAINS %@", url.lastPathComponent))
            .firstMatch
    }
}

struct WorkspaceUITestFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-UITest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func file(_ name: String, text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func git(_ args: [String]) throws {
        let executable = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/git")
            ? "/opt/homebrew/bin/git" : "/usr/bin/git"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", root.path] + args
        let error = Pipe()
        process.standardError = error
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = String(decoding: error.fileHandleForReading.readDataToEndOfFile(),
                                as: UTF8.self)
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

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
