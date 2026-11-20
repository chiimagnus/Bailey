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
        let owner: ObjectIdentifier
        let project: URL?
        let clipboardIsReadOnly: Bool
    }

    private static var session: Session?
    private static let observer = UITestSessionObserver()
    private static var observing = false

    static func launch(
        in test: XCTestCase, language: String? = nil,
        configurationHome: URL? = nil, project: URL? = nil,
        clipboardIsReadOnly: Bool = false
    ) throws -> XCUIApplication {
        if !observing {
            XCTestObservationCenter.shared.addTestObserver(observer)
            observing = true
        }

        let owner = ObjectIdentifier(test)
        let project = project?.standardizedFileURL
        if let current = session, current.owner == owner,
           current.language == language, current.project == project,
           current.clipboardIsReadOnly == clipboardIsReadOnly,
           current.usesFixtureHome == (configurationHome != nil),
           (configurationHome == nil || current.home == configurationHome),
           current.app.state != .notRunning {
            return current.app
        }

        finishSession()
        let app = XCUIApplication(bundleIdentifier: "chiimagnus.bailey.dev")
        guard app.state == .notRunning else {
            throw NSError(domain: "BaileyUITestLaunch", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "An unowned Bailey Dev is already running; tests cannot attach to it"
            ])
        }
        // Preserve process-global input state before allocating a test session.
        // If a clipboard type cannot be copied, leave no owned session or HOME behind.
        let previousInput = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let unicodeHexWasEnabled = inputSource(id: "com.apple.keylayout.UnicodeHexInput") != nil
        let clipboardVersion = NSPasteboard.general.changeCount
        let originalClipboard = clipboardIsReadOnly ? nil : try clipboardItems()
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
        app.launchArguments = ["--isolated-ui-test"]
        if let language { app.launchArguments += ["-AppleLanguages", "(\(language))"] }
        app.launchEnvironment["BAILEY_UI_TEST_RUN_ID"] = UUID().uuidString
        if let project {
            precondition(project.path.hasPrefix(
                FileManager.default.temporaryDirectory.standardizedFileURL.path
                    + "/Bailey-UITest-"), "Only a test-owned directory may be preloaded")
            app.launchEnvironment["BAILEY_UI_TEST_PROJECT"] = project.path
        }
        app.launchEnvironment["CFFIXED_USER_HOME"] = home.path
        app.launchEnvironment["HOME"] = home.path
        app.launchEnvironment["ZDOTDIR"] = home.path
        session = Session(app: app, home: home, language: language,
                          usesFixtureHome: configurationHome != nil,
                          owner: owner, project: project,
                          clipboardIsReadOnly: clipboardIsReadOnly)
        test.addTeardownBlock { @MainActor in
            if let active = session, active.app === app { finishSession() }
            let pasteboard = NSPasteboard.general
            if let originalClipboard, pasteboard.changeCount != clipboardVersion {
                pasteboard.clearContents()
                if !originalClipboard.isEmpty {
                    XCTAssertTrue(pasteboard.writeObjects(originalClipboard))
                }
            } else if clipboardIsReadOnly {
                XCTAssertEqual(pasteboard.changeCount, clipboardVersion,
                               "This GUI test must not modify the user's clipboard")
            }
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
        // The isolated app explicitly requests one initial scene. Do not hide
        // a failed attachment by sending a second new-window shortcut.
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.windows.count, 1,
                       "An isolated launch must not inherit windows from other UI tests")
        if let project {
            let mountedProject = app.buttons.matching(identifier: "bailey.project.row")
                .matching(NSPredicate(format: "label CONTAINS %@", project.path)).firstMatch
            guard mountedProject.waitForExistence(timeout: 30) else {
                throw NSError(domain: "BaileyUITestLaunch", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "The isolated fixture project did not appear"
                ])
            }
        }
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

    static func assertClipboard(
        _ expected: String, _ message: String = "",
        timeout: TimeInterval = 4, file: StaticString = #filePath, line: UInt = #line
    ) {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSPasteboard.general.string(forType: .string) == expected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: timeout), .completed,
                       message.isEmpty ? "Expected native clipboard result: \(expected)" : message,
                       file: file, line: line)
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

    static func selectSSHFolder(_ root: String, host: String, in app: XCUIApplication) {
        let dismiss = element("bailey.sshFolderPicker.dismiss", in: app)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 15),
                      "SSH uses the in-window picker, not the macOS folder sheet")
        let hostChoice = app.buttons.matching(identifier: "bailey.sshFolderPicker.hostChoice")
            .matching(NSPredicate(format: "value == %@", host)).firstMatch
        XCTAssertTrue(hostChoice.waitForExistence(timeout: 15))
        hostChoice.click()
        let path = app.textFields["bailey.sshFolderPicker.path"]
        XCTAssertTrue(path.waitForExistence(timeout: 40))
        // The path field is visible before the real remote directory read
        // finishes. Input must not race the host switch or focus transition.
        let loading = app.staticTexts["Loading remote folders…"]
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            path.exists && !loading.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 60), .completed)
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText(root)
        XCTAssertEqual(path.value as? String, root)
        let confirm = app.buttons["bailey.sshFolderPicker.add"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 40))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: confirm
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 40), .completed)
        confirm.click()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 40))
    }

    static func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    static func menuItem(_ title: String, in scope: XCUIElement) -> XCUIElement {
        scope.menuItems.matching(NSPredicate(
            format: "title == %@ OR title BEGINSWITH %@ OR title BEGINSWITH %@",
            title, title + ",", title + "，"
        )).firstMatch
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

    static func finderDragSource(for file: URL) -> (window: XCUIElement, source: XCUIElement) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        let window = finder.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        finder.activate()
        if !window.outlines["ListView"].waitForExistence(timeout: 2) {
            finder.typeKey("2", modifierFlags: .command)
        }
        XCTAssertTrue(window.outlines["ListView"].waitForExistence(timeout: 12),
                      "The selected Finder file must expose an actual draggable row")
        let source = window.outlines["ListView"].outlineRows.firstMatch
            .textFields[file.lastPathComponent]
        XCTAssertTrue(source.waitForExistence(timeout: 12),
                      "The system drag must originate from the actual selected file")
        return (window, source)
    }

    static func positionFinderDragWindow(
        _ window: XCUIElement, awayFrom target: XCUICoordinate
    ) -> Bool {
        let point = target.screenPoint
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main else {
            XCTFail("A real display is required for Finder drag acceptance testing")
            return false
        }
        let margin: CGFloat = 24
        let bounds = screen.frame
        var frame = window.frame
        guard frame.width > 0, frame.height > 0 else {
            XCTFail("The Finder source must have a visible window")
            return false
        }
        if !frame.insetBy(dx: -margin, dy: -margin).contains(point) { return true }

        // Use XCTest's real mouse events. The sandboxed UI Runner cannot read
        // another app's raw AX window list or change its AX position.
        func unobscuredPosition(for size: CGSize) -> CGPoint? {
            let horizontal = max(bounds.minX + margin,
                                 min(point.x - size.width / 2,
                                     bounds.maxX - size.width - margin))
            let vertical = max(bounds.minY + margin,
                               min(point.y - size.height / 2,
                                   bounds.maxY - size.height - margin))
            let left = point.x - size.width - margin
            if left >= bounds.minX + margin {
                return CGPoint(x: left, y: vertical)
            }
            let right = point.x + margin
            if right + size.width <= bounds.maxX - margin {
                return CGPoint(x: right, y: vertical)
            }
            let above = point.y - size.height - margin
            if above >= bounds.minY + margin {
                return CGPoint(x: horizontal, y: above)
            }
            let below = point.y + margin
            if below + size.height <= bounds.maxY - margin {
                return CGPoint(x: horizontal, y: below)
            }
            return nil
        }
        if unobscuredPosition(for: frame.size) == nil {
            let width = min(frame.width, 500)
            let height = min(frame.height, 360)
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995))
            corner.click(forDuration: 0.3, thenDragTo: corner.withOffset(
                CGVector(dx: width - frame.width, dy: height - frame.height)
            ))
            frame = window.frame
            guard frame.width <= width + 20, frame.height <= height + 20 else {
                XCTFail("The real Finder window did not resize to expose the drop target")
                return false
            }
        }
        guard let destination = unobscuredPosition(for: frame.size) else {
            XCTFail("The Finder source and target cannot fit on this display")
            return false
        }
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        titleBar.click(forDuration: 0.3, thenDragTo: titleBar.withOffset(
            CGVector(dx: destination.x - frame.minX, dy: destination.y - frame.minY)
        ))
        guard !window.frame.insetBy(dx: -margin / 2, dy: -margin / 2).contains(point) else {
            XCTFail("Finder still obscures the real destination; do not start a file drag")
            return false
        }
        return true
    }

    static func closeFinderDragWindow(_ window: XCUIElement) {
        if window.exists { window.buttons["_XCUI:CloseWindow"].firstMatch.click() }
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

    init(in test: XCTestCase, baseDirectory: URL? = nil) throws {
        root = (baseDirectory ?? FileManager.default.temporaryDirectory)
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

    /// The temporary GUI HOME may reuse approved SSH aliases and Cloudflare
    /// authorization without copying tokens or exposing real Bailey settings.
    func includeAuthorizedSSHHost(_ host: String) throws {
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              let account = getpwuid(getuid()) else {
            throw NSError(domain: "BaileyUITestSSH", code: 1)
        }
        let realHome = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
        let config = realHome.appendingPathComponent(".ssh/config")
        guard FileManager.default.fileExists(atPath: config.path) else {
            throw NSError(domain: "BaileyUITestSSH", code: 2)
        }
        _ = try file(".ssh/config", text: "Include \(config.path)\n")
        let cache = realHome.appendingPathComponent(".cloudflared")
        if FileManager.default.fileExists(atPath: cache.path) {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(".cloudflared"), withDestinationURL: cache
            )
        }
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
