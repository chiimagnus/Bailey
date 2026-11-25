import AppKit
import XCTest

@MainActor
final class FilePreviewWorkspaceUITests: XCTestCase {
    func testSevenRealFormatsKeepWindowOwnershipAcrossSwitchesAndNormalRelaunch() async throws {
        guard let path = ProcessInfo.processInfo.environment["BAILEY_PREVIEW_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_PREVIEW_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let samples = URL(fileURLWithPath: path, isDirectory: true)
        let primary = fixture.root.appending(path: "primary")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        for name in ["Markdown 综合验收.md", "HTML 综合验收.html", "graphics", "images", "media", "styles", "tables"] {
            try FileManager.default.copyItem(at: samples.appending(path: name), to: primary.appending(path: name))
        }
        let names = ["Markdown 综合验收.md", "tables/复杂字段.csv", "graphics/复杂科研图.svg",
                     "HTML 综合验收.html", "images/动画-34帧.gif",
                     "media/音频-定位.m4a", "media/视频-内置字幕.mp4"]
        let files = names.map { primary.appending(path: $0) }
        let markdown = files[0], csv = files[1], svg = files[2], html = files[3]
        let gif = files[4], audio = files[5], video = files[6]
        let otherCSV = try fixture.file("secondary/tables/复杂字段.csv", text: "Name,Value\nSecond window,91\n")
        let otherHTML = try fixture.file("secondary/HTML 综合验收.html", text: "<!doctype html><h1>Second window HTML</h1>")
        let secondary = fixture.root.appending(path: "secondary")
        let allFiles = files + [otherCSV, otherHTML]
        let original = try allFiles.map { try Data(contentsOf: $0) }

        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", configurationHome: fixture.root, project: primary
        )
        let devID = "chiimagnus.bailey.dev"

        func wait(_ message: String, timeout: TimeInterval = 10, until condition: @escaping () -> Bool) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message)
        }
        func inWindow(_ id: String, _ window: XCUIElement) -> XCUIElement {
            window.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        func owner(of file: URL) -> XCUIElement? {
            guard let found = app.windows.allElementsBoundByIndex.first(where: {
                WorkspaceUITestSupport.fileTab(file, in: $0).exists
            }) else { return nil }
            return app.windows.matching(identifier: found.identifier).firstMatch
        }
        func deliver(_ urls: [URL]) async throws {
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: devID)
            XCTAssertEqual(applications.count, 1)
            let running = try XCTUnwrap(applications.first)
            let config = NSWorkspace.OpenConfiguration()
            config.allowsRunningApplicationSubstitution = false
            config.arguments = app.launchArguments
            config.environment = app.launchEnvironment
            let delivered = try await NSWorkspace.shared.open(
                urls, withApplicationAt: XCTUnwrap(running.bundleURL), configuration: config
            )
            XCTAssertEqual(delivered.processIdentifier, running.processIdentifier)
            XCTAssertEqual(delivered.bundleIdentifier, devID)
        }
        func select(_ file: URL, in window: XCUIElement) async throws {
            let tab = WorkspaceUITestSupport.fileTab(file, in: window)
            XCTAssertTrue(tab.waitForExistence(timeout: 15), file.lastPathComponent)
            if app.windows.firstMatch.identifier != window.identifier {
                // Reopen the existing file through Launch Services instead of
                // clicking a potentially occluded background window.
                try await deliver([file])
            } else if !tab.isSelected {
                if tab.isHittable {
                    tab.click()
                } else {
                    // Seven long Unicode filenames can overflow the tab strip.
                    // Exercise the real Next Panel command, which scrolls the
                    // selected tab into view, rather than clicking clipped AX frames.
                    let count = window.buttons.matching(identifier: "bailey.tab.file").count
                    for _ in 0..<count {
                        if tab.isSelected { break }
                        app.typeKey("]", modifierFlags: [.command, .shift])
                    }
                }
            }
            wait("The correct file and its window must receive focus") {
                tab.isSelected && app.windows.firstMatch.identifier == window.identifier
            }
        }
        func toggleFromSource(_ window: XCUIElement, marker: String) {
            let source = window.textViews.firstMatch
            XCTAssertTrue(source.waitForExistence(timeout: 15))
            XCTAssertTrue((source.value as? String)?.contains(marker) == true)
            source.click()
            app.typeKey("v", modifierFlags: [.command, .shift])
            XCTAssertTrue(source.waitForNonExistence(timeout: 10))
        }
        func mediaTime(_ window: XCUIElement) -> Double? {
            Double(String(describing: window.sliders["timeline"].value ?? ""))
        }
        func inspect(_ file: URL, in window: XCUIElement, initially: Bool) async throws {
            try await select(file, in: window)
            switch file {
            case markdown:
                let preview = inWindow("bailey.markdown.preview", window)
                if initially {
                    XCTAssertFalse(preview.exists)
                    toggleFromSource(window, marker: "# Bailey 跨格式预览综合测试")
                }
                XCTAssertTrue(preview.waitForExistence(timeout: 15))
                XCTAssertTrue(preview.descendants(matching: .any)
                    .matching(identifier: "bailey.markdown.heading.bailey-跨格式预览综合测试")
                    .firstMatch.waitForExistence(timeout: 10))
            case csv:
                let table = inWindow("bailey.csv.table", window)
                XCTAssertTrue(table.staticTexts["试样 A"].waitForExistence(timeout: 15))
                XCTAssertTrue(table.staticTexts["001"].exists)
            case svg:
                let preview = inWindow("bailey.svg.preview", window)
                XCTAssertTrue(preview.waitForExistence(timeout: 15))
                let omission = window.staticTexts.matching(NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@", "omits: pattern", "omits: pattern"
                )).firstMatch
                XCTAssertFalse(omission.exists, "The research plot pattern should now render")
            case html:
                let web = window.webViews.firstMatch
                if initially {
                    XCTAssertFalse(web.exists)
                    toggleFromSource(window, marker: "Bailey / HTML 综合验收")
                }
                XCTAssertTrue(web.staticTexts["Bailey / HTML 综合验收"].waitForExistence(timeout: 15))
            case gif:
                let viewer = inWindow("bailey.image.inspector", window)
                XCTAssertTrue(viewer.waitForExistence(timeout: 15))
                viewer.rightClick()
                XCTAssertTrue(WorkspaceUITestSupport.menuItem("100%", in: app).waitForExistence(timeout: 5))
                app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            case audio, video:
                let timeline = window.sliders["timeline"]
                XCTAssertTrue(timeline.waitForExistence(timeout: 15))
                XCTAssertTrue(window.checkBoxes["play/pause"].exists)
                if initially {
                    timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).click()
                    wait("The real native media playhead must seek") { (mediaTime(window) ?? 0) > 0.3 }
                }
            default:
                XCTFail("Unexpected fixture: \(file)")
            }
        }
        func assertAllTabs(_ window: XCUIElement, expected: [URL], excluding: [URL]) {
            for file in expected {
                XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: window).waitForExistence(timeout: 15))
            }
            XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, expected.count)
            for file in excluding { XCTAssertFalse(WorkspaceUITestSupport.fileTab(file, in: window).exists) }
        }

        let firstID = app.windows.firstMatch.identifier
        let first = app.windows.matching(identifier: firstID).firstMatch
        try await deliver(files)
        assertAllTabs(first, expected: files, excluding: [otherCSV, otherHTML])
        for file in files { try await inspect(file, in: first, initially: true) }
        let videoPosition = try XCTUnwrap(mediaTime(first))

        app.typeKey("n", modifierFlags: [.command, .shift])
        let other = app.windows.matching(NSPredicate(format: "identifier != %@", firstID)).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 15))
        let second = app.windows.matching(identifier: other.identifier).firstMatch
        try WorkspaceUITestSupport.addFolder(secondary, to: app, in: second)
        try await deliver([otherCSV, otherHTML])
        assertAllTabs(second, expected: [otherCSV, otherHTML], excluding: files)
        try await select(otherHTML, in: second)
        toggleFromSource(second, marker: "Second window HTML")
        XCTAssertTrue(second.webViews.firstMatch.staticTexts["Second window HTML"].waitForExistence(timeout: 10))
        try await select(otherCSV, in: second)
        XCTAssertTrue(inWindow("bailey.csv.table", second).staticTexts["Second window"].waitForExistence(timeout: 10))

        // Redelivery while the other window is key must reuse the original owner,
        // even for same-named files; no duplicate writable buffer or tab.
        try await deliver([csv])
        wait("System delivery must bring the original CSV owner forward") {
            app.windows.firstMatch.identifier == firstID
        }
        assertAllTabs(first, expected: files, excluding: [otherCSV, otherHTML])
        assertAllTabs(second, expected: [otherCSV, otherHTML], excluding: files)

        for _ in 0..<2 {
            for file in files.reversed() {
                try await inspect(file, in: first, initially: false)
                if file == video {
                    XCTAssertEqual(try XCTUnwrap(mediaTime(first)), videoPosition, accuracy: 0.1)
                }
            }
            try await select(otherCSV, in: second)
            XCTAssertTrue(inWindow("bailey.csv.table", second).staticTexts["Second window"].exists)
        }
        try await select(html, in: first)
        WorkspaceUITestSupport.fileTab(html, in: first).rightClick()
        let split = WorkspaceUITestSupport.menuItem("Show Side by Side", in: app)
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.click()
        XCTAssertTrue(first.textViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(first.webViews.firstMatch.staticTexts["Bailey / HTML 综合验收"].waitForExistence(timeout: 10))

        // Normal Quit, not terminate(), must save both windows. The temporary
        // companion is not a second persisted editor or restored tab.
        app.typeKey("q", modifierFlags: .command)
        wait("Normal Quit must finish before cold relaunch", timeout: 15) { app.state == .notRunning }
        app.launch()
        app.activate()
        wait("Both original windows and their tabs must be restored", timeout: 30) {
            app.windows.count == 2 && owner(of: csv) != nil && owner(of: otherCSV) != nil
        }
        let restoredFirst = try XCTUnwrap(owner(of: csv))
        let restoredSecond = try XCTUnwrap(owner(of: otherCSV))
        XCTAssertNotEqual(restoredFirst.identifier, restoredSecond.identifier)
        assertAllTabs(restoredFirst, expected: files, excluding: [otherCSV, otherHTML])
        assertAllTabs(restoredSecond, expected: [otherCSV, otherHTML], excluding: files)
        for file in files { try await inspect(file, in: restoredFirst, initially: true) }
        try await select(otherHTML, in: restoredSecond)
        toggleFromSource(restoredSecond, marker: "Second window HTML")
        XCTAssertTrue(restoredSecond.webViews.firstMatch.staticTexts["Second window HTML"].waitForExistence(timeout: 10))
        try await select(otherCSV, in: restoredSecond)
        XCTAssertTrue(inWindow("bailey.csv.table", restoredSecond).staticTexts["Second window"].waitForExistence(timeout: 10))

        // Closing every real tab must leave the original input bytes untouched.
        for (window, owned) in [(restoredFirst, files), (restoredSecond, [otherCSV, otherHTML])] {
            for file in owned {
                try await select(file, in: window)
                app.typeKey("w", modifierFlags: .command)
                XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: window).waitForNonExistence(timeout: 10))
            }
            XCTAssertEqual(window.buttons.matching(identifier: "bailey.tab.file").count, 0)
        }
        for (index, file) in allFiles.enumerated() {
            XCTAssertEqual(try Data(contentsOf: file), original[index])
            if index < names.count {
                XCTAssertEqual(try Data(contentsOf: samples.appending(path: names[index])), original[index])
            }
        }
    }
}
