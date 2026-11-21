import Foundation
import AVFoundation
import XCTest

@MainActor
final class MarkdownPreviewUITests: XCTestCase {
    func testHTMLDetailsAndGitHubStyleTableUseNativeControls() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("HTML.md", text: """
            # Native HTML

            <details open><summary>Open section</summary><p>Hello <strong>world</strong>!</p></details>

            <details><summary>Closed section</summary><p>Hidden content</p></details>

            <table><tr><th>Header</th><td>Ordinary cell</td></tr>
            <tr><td>Value</td><td>42</td></tr></table>
            """)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let details = preview.buttons.matching(identifier: "bailey.markdown.details")
        XCTAssertEqual(details.count, 2)
        XCTAssertTrue(preview.staticTexts["Hello world!"].waitForExistence(timeout: 10))
        XCTAssertFalse(preview.staticTexts["Hidden content"].exists)
        details.element(boundBy: 1).click()
        XCTAssertTrue(preview.staticTexts["Hidden content"].waitForExistence(timeout: 10))
        details.element(boundBy: 0).click()
        XCTAssertFalse(preview.staticTexts["Hello world!"].exists)
        XCTAssertTrue(preview.staticTexts["Header"].exists)
    }

    func testRichMarkdownShowsStaticSVGAndLoadsNativeAudioOnDemand() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("Paper.md", text: """
            # Offline paper

            ![Constrained SVG](chart.svg)

            <table><tr><th>Measurement</th><td>42</td></tr></table>

            <audio controls src="sound.wav" autoplay loop></audio>

            ```mermaid
            flowchart LR
              Source --> Preview
            ```

            """)
        _ = try fixture.file("chart.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="30">
              <rect width="100" height="30" fill="blue"/>
            </svg>
            """)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 8_000)
        do {
            let audio = try AVAudioFile(forWriting: fixture.root.appending(path: "sound.wav"), settings: format.settings)
            try audio.write(from: buffer)
        }
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.staticTexts["Offline paper"].waitForExistence(timeout: 10))
        XCTAssertTrue(preview.staticTexts["Measurement"].exists)
        XCTAssertTrue(preview.buttons["Constrained SVG"].waitForExistence(timeout: 10), preview.debugDescription)
        let start = preview.buttons["Load Audio"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let player = WorkspaceUITestSupport.element("bailey.markdown.media", in: app)
        XCTAssertFalse(player.exists)
        start.click()
        XCTAssertTrue(player.waitForExistence(timeout: 10), preview.debugDescription)
        let diagram = WorkspaceUITestSupport.element("bailey.markdown.mermaid", in: app)
        XCTAssertTrue(diagram.waitForExistence(timeout: 10), preview.debugDescription)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(player.waitForNonExistence(timeout: 10))
    }
    func testSideBySideUpdatesWhileEditingAndUsesTheOriginalSavePath() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = "# Initial heading\n"
        let file = try fixture.file("Live.md", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        tab.rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        if !preview.staticTexts["Initial heading"].waitForExistence(timeout: 5) {
            let screenshot = XCTAttachment(screenshot: window.screenshot())
            screenshot.name = "Initial Markdown companion"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("The initial preview did not display its heading. \(preview.debugDescription)")
        }
        XCTAssertTrue(editor.exists)
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("# Updated heading\n")
        XCTAssertTrue(preview.staticTexts["Updated heading"].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "# Updated heading\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
        app.typeKey("s", modifierFlags: .command)
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8)) == "# Updated heading\n"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 10), .completed)
    }

    func testFileMenuPreviewsMDXWithoutSavingAndKeepsTheNativeUndo() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = "---\nname: skill\n---\n# Native Markdown preview\n\n<Widget value={1} />\n"
        let markdown = try fixture.file("SKILL.mdx", text: source)
        let plain = try fixture.file("plain.txt", text: "plain")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let fileMenu = app.menuBars.menuBarItems["File"]
        let showPreview = app.menuItems["Show Preview"]
        let showSource = app.menuItems["Show Source"]
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)

        guard fileMenu.waitForExistence(timeout: 10) else { return XCTFail("File menu is not accessible") }
        fileMenu.click()
        XCTAssertTrue(showPreview.exists)
        XCTAssertFalse(showPreview.isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        let plainRow = WorkspaceUITestSupport.fileRow(plain, in: window)
        XCTAssertTrue(plainRow.waitForExistence(timeout: 20))
        plainRow.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(plain, in: window).waitForExistence(timeout: 15))
        fileMenu.click()
        XCTAssertTrue(showPreview.exists)
        XCTAssertFalse(showPreview.isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        let markdownRow = WorkspaceUITestSupport.fileRow(markdown, in: window)
        markdownRow.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(markdown, in: window)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        fileMenu.click()
        XCTAssertTrue(showPreview.isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("temporary")
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue(preview.staticTexts["Native Markdown preview"].waitForExistence(timeout: 15))
        XCTAssertEqual(try String(contentsOf: markdown, encoding: .utf8), source)
        XCTAssertTrue(tab.exists)

        fileMenu.click()
        XCTAssertTrue(showSource.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 15))
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String)?.hasSuffix("temporary") == true)
        editor.click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertEqual(try String(contentsOf: markdown, encoding: .utf8), source)
    }
}
