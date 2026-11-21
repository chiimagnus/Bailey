import AppKit
import Foundation
import AVFoundation
import XCTest

@MainActor
final class MarkdownPreviewUITests: XCTestCase {
    func testImageBetweenParagraphWordsIsAnAccessibleNativeImage() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("tiny.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">
              <circle cx="12" cy="12" r="10" fill="#1479ca"/>
            </svg>
            """)
        let file = try fixture.file("Mixed.md", text: "# Mixed content\n\nBefore ![tiny](tiny.svg) after.\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue(preview.buttons["tiny"].waitForExistence(timeout: 15),
                      "Markdown image mixed with prose must create a native image, not only alt text: \(preview.debugDescription)")
        XCTAssertTrue(preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "Before"
        )).firstMatch.exists)
        XCTAssertTrue(preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "after"
        )).firstMatch.exists)
    }

    func testCodeFenceHighlightCopyAndFootnotesRemainNative() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let code = "let answer = 42\nprint(answer)\n"
        let file = try fixture.file("Highlight.md", text: """
            # Swift syntax

            Refer to[^note] after the code.

            ```swift
            let answer = 42
            print(answer)
            ```

            [^note]: A native footnote.
            """)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.staticTexts["Swift syntax"].waitForExistence(timeout: 15))
        XCTAssertTrue(preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "let answer = 42"
        )).firstMatch.waitForExistence(timeout: 15), preview.debugDescription)
        XCTAssertTrue(preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "A native footnote"
        )).firstMatch.waitForExistence(timeout: 15), preview.debugDescription)
        let copy = preview.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), code)

        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Swift fenced code and footnote in native Markdown"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testHTMLImageSizeIsAppliedToTheRealNativeImage() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("badge.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="320" height="120">
              <rect width="320" height="120" fill="#2980b9"/>
            </svg>
            """)
        let file = try fixture.file("Images.md", text: """
            # Sized images

            <p><img src="badge.svg" alt="Small badge" width="48" height="32"></p>

            <p><img src="badge.svg" alt="Natural badge"></p>
            """)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let small = preview.buttons["Small badge"]
        let natural = preview.buttons["Natural badge"]
        XCTAssertTrue(small.waitForExistence(timeout: 15), preview.debugDescription)
        XCTAssertTrue(natural.waitForExistence(timeout: 15), preview.debugDescription)
        XCTAssertLessThanOrEqual(small.frame.width, 52, "The 48px HTML width must constrain the image")
        XCTAssertEqual(small.frame.height, 32, accuracy: 2,
                       "HTML width and height attributes should determine the displayed geometry")
        XCTAssertGreaterThan(natural.frame.width, small.frame.width * 2,
                             "An image without a width must retain the natural responsive size")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "GitHub HTML image width in native preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let tab = WorkspaceUITestSupport.fileTab(file, in: app.windows.firstMatch)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        let editor = app.windows.firstMatch.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let edited = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "width=\"48\" height=\"32\"", with: "width=\"96\" height=\"16\"")
            + "\n\nAfter edit\n"
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(edited)
        XCTAssertEqual(editor.value as? String, edited,
                       "Source editor must never substitute typographic quotes into HTML attributes")
        XCTAssertTrue(preview.staticTexts["After edit"].waitForExistence(timeout: 10))
        XCTAssertTrue(small.waitForExistence(timeout: 15), preview.debugDescription)
        XCTAssertEqual(small.frame.width, 96, accuracy: 3,
                       "Live changes to HTML dimensions must update without changing the image source")
        XCTAssertEqual(small.frame.height, 16, accuracy: 2)
    }

    func testOversizedHTMLImageScalesInsideTheNativePreview() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("badge.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="320" height="120">
              <rect width="320" height="120" fill="#2980b9"/>
            </svg>
            """)
        let file = try fixture.file("Responsive.md", text: """
            # Responsive image

            <img src="badge.svg" alt="Oversized badge" width="2000" height="800">
            """)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let image = preview.buttons["Oversized badge"]
        XCTAssertTrue(image.waitForExistence(timeout: 15), preview.debugDescription)
        XCTAssertLessThan(image.frame.width, 1000,
                          "An oversized 2000px image must shrink inside the native Markdown viewport")
        XCTAssertLessThanOrEqual(image.frame.width, preview.frame.width,
                                 "The image must not expand beyond the visible preview width")
        XCTAssertEqual(image.frame.width / image.frame.height, 2.5, accuracy: 0.1,
                       "Responsive scaling must preserve the explicitly requested HTML aspect ratio")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "GitHub responsive oversized image in native preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testAdjacentInlineHTMLStaysOnOneTextLine() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("Inline.md", text: """
            # HTML inline

            <span>Alpha </span><strong>Beta</strong><span> Gamma</span>

            <details open><summary>Notes</summary><span>One </span><em>Two</em> Three</details>
            """)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.staticTexts["Alpha Beta Gamma"].waitForExistence(timeout: 10),
                      "Adjacent HTML inline elements must form a single visual line: \(preview.debugDescription)")
        XCTAssertTrue(preview.staticTexts["One Two Three"].exists, preview.debugDescription)
    }

    func testMarkdownRelativeLinksOpenActualProjectFiles() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try WorkspaceUITestFixture(in: self)
        let paths = ["SECURITY.md", "AGENTS.md", "docs/testing.md", "docs/features/ssh.md",
                     "docs/features/editor.md", "docs/features/git.md", "docs/features/tunnels.md",
                     "docs/signing.md"]
        var files: [String: URL] = [:]
        for path in paths {
            let original = try String(contentsOf: repository.appending(path: path), encoding: .utf8)
            files[path] = try fixture.file(path, text: original)
        }
        let security = try XCTUnwrap(files["SECURITY.md"])
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(security, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.staticTexts["安全"].waitForExistence(timeout: 10), preview.debugDescription)

        for _ in 0..<2 {
            for (title, path) in [("编辑器", "docs/features/editor.md"),
                                  ("SSH", "docs/features/ssh.md"),
                                  ("AGENTS.md", "AGENTS.md"),
                                  ("docs/testing.md", "docs/testing.md"),
                                  ("Git", "docs/features/git.md"),
                                  ("隧道", "docs/features/tunnels.md"),
                                  ("签名", "docs/signing.md")] {
                let link = preview.links[title]
                XCTAssertTrue(link.waitForExistence(timeout: 10), "Missing \(title): \(preview.debugDescription)")
                link.click()
                let destination = try XCTUnwrap(files[path])
                let editor = window.textViews.firstMatch
                XCTAssertTrue(editor.waitForExistence(timeout: 10), "SECURITY.md link \(title) must open \(path)")
                XCTAssertEqual(editor.value as? String,
                               try String(contentsOf: destination, encoding: .utf8),
                               "SECURITY.md link \(title) must select and read the real \(path)")
                app.typeKey("w", modifierFlags: .command)
                XCTAssertTrue(preview.waitForExistence(timeout: 10), "Closing \(path) must restore SECURITY.md preview")
            }
        }
    }

    func testMarkdownAndHTMLImagesOpenAuthorizedFiles() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let image = try fixture.file("badge.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="80" height="40">
              <rect width="80" height="40" fill="#2980b9"/>
            </svg>
            """)
        let document = try fixture.file("Images.md", text: """
            # Image links

            ![Markdown badge](badge.svg)

            <img src="badge.svg" alt="HTML badge" width="60" height="30">
            """)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(document, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        for name in ["Markdown badge", "HTML badge"] {
            let button = preview.buttons[name]
            XCTAssertTrue(button.waitForExistence(timeout: 15), "Missing \(name): \(preview.debugDescription)")
            button.click()
            XCTAssertTrue(WorkspaceUITestSupport.fileTab(image, in: window).waitForExistence(timeout: 10),
                          "\(name) must open the authorized SVG file tab")
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(preview.waitForExistence(timeout: 10), "Must return to Markdown preview")
        }
    }

    func testSelectionAcrossSeparateMarkdownParagraphsCopiesWholeRange() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("Selection.md", text: """
            # Selection

            ALPHA paragraph has original text.

            OMEGA paragraph ends the selection.
            """)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let first = preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "ALPHA paragraph"
        )).firstMatch
        let last = preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "OMEGA paragraph"
        )).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), preview.debugDescription)
        XCTAssertTrue(last.waitForExistence(timeout: 10), preview.debugDescription)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Unchanged selection", forType: .string))
        let origin = first.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.2))
        let sameLine = first.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.2))
        origin.click(forDuration: 0.1, thenDragTo: sameLine)
        app.typeKey("c", modifierFlags: .command)
        let withinOne = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertNotEqual(withinOne, "Unchanged selection", "Drag gesture must first select within native Text")
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Unchanged selection", forType: .string))
        let target = last.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8))
        origin.click(forDuration: 0.1, thenDragTo: target)
        app.typeKey("c", modifierFlags: .command)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("paragraph has original text.") && copied.contains("OMEGA paragraph"),
                      "The native preview must support one selection across blocks; actual copied: \(copied)")
    }

    func testSecurityMarkdownSelectionCopiesOriginalText() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = try String(contentsOf: repository.appending(path: "SECURITY.md"), encoding: .utf8)
        let file = try fixture.file("SECURITY.md", text: original)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root)
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let prose = preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "本页负责漏洞报告"
        )).firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 10), preview.debugDescription)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString("Bailey selection test", forType: .string))
        prose.doubleClick()
        app.typeKey("c", modifierFlags: .command)
        let copied = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertNotEqual(copied, "Bailey selection test", "Markdown selection must reach the native clipboard")
        XCTAssertTrue(original.contains(copied), "Copied prose must come from SECURITY.md, not a stale source")
    }

    func testHTMLHeadingListAndRelativeLinkNavigateInsideProject() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let overview = try fixture.file("Overview.md", text: """
            # Overview

            <h2>Native heading</h2>
            <ul><li>First item</li><li>Second item</li></ul>
            <p>Open <a href="Guide.md"><strong>Guide</strong></a> now.</p>
            """)
        let guide = try fixture.file("Guide.md", text: "# Verified destination\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let row = WorkspaceUITestSupport.fileRow(overview, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.staticTexts["Native heading"].waitForExistence(timeout: 10), preview.debugDescription)
        XCTAssertTrue(preview.staticTexts["First item"].exists, preview.debugDescription)
        let link = preview.links["Guide"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), preview.debugDescription)
        link.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(guide, in: app.windows.firstMatch)
            .waitForExistence(timeout: 10), "The native HTML link must reach the authorized FileTab")
    }

    func testDetailsOpenAttributeTracksLiveEdits() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let closed = "# Live HTML\n\n<details><summary>Notes</summary><p>Editable content</p></details>\n"
        let open = closed.replacingOccurrences(of: "<details>", with: "<details open>")
        let file = try fixture.file("Details.md", text: closed)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let details = preview.buttons["bailey.markdown.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 15))
        XCTAssertFalse(preview.staticTexts["Editable content"].exists)
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(open)
        XCTAssertTrue(preview.staticTexts["Editable content"].waitForExistence(timeout: 10),
                      "The open attribute must update the existing details control")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(closed)
        XCTAssertTrue(preview.staticTexts["Editable content"].waitForNonExistence(timeout: 10),
                      "Removing the open attribute must collapse the same details control")
    }

    func testExternalImageRefreshKeepsManualDetailsExpansion() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let badge = try fixture.file("badge.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="120" height="60">
              <rect width="120" height="60" fill="#336699"/>
            </svg>
            """)
        let file = try fixture.file("Readme.md", text: """
            # Section

            <details><summary>Instructions</summary><p>Keep this visible.</p></details>

            <img src="badge.svg" alt="Badge">
            """)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let originalWindow = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: originalWindow)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(originalWindow.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = originalWindow.descendants(matching: .any)
            .matching(identifier: "bailey.markdown.preview").firstMatch
        let details = preview.buttons["bailey.markdown.details"]
        guard details.waitForExistence(timeout: 15) else {
            return XCTFail("The Markdown fixture must display its HTML details control")
        }
        details.click()
        let content = preview.staticTexts["Keep this visible."]
        XCTAssertTrue(content.waitForExistence(timeout: 10))
        let image = preview.buttons["Badge"]
        XCTAssertTrue(image.waitForExistence(timeout: 10), preview.debugDescription)
        let originalWidth = image.frame.width
        XCTAssertGreaterThan(originalWidth, 60, "The fixture SVG must load before the external edit")

        try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="50" height="50">
              <rect width="50" height="50" fill="#996633"/>
            </svg>
            """.utf8).write(to: badge)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertEqual(finder.state, .runningForeground,
                       "The fixture must actually activate Finder before returning to Bailey")
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        let currentPreview = originalWindow.descendants(matching: .any)
            .matching(identifier: "bailey.markdown.preview").firstMatch
        XCTAssertTrue(currentPreview.waitForExistence(timeout: 10), "The original preview must remain mounted")
        let screenshot = XCTAttachment(screenshot: originalWindow.screenshot())
        screenshot.name = "Original Markdown window after external SVG refresh"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let currentImage = currentPreview.buttons["Badge"]
        let imageUpdated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            currentImage.exists && abs(currentImage.frame.width - originalWidth * 50 / 120) < 6
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [imageUpdated], timeout: 10), .completed,
                       "Window reactivation must reload changed relative images")
        XCTAssertTrue(currentPreview.staticTexts["Keep this visible."].waitForExistence(timeout: 10),
                      "Reloading an image must not collapse an unrelated details control")
    }

    func testRemovingMarkdownImageDoesNotLeaveStaleAttachment() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        _ = try fixture.file("badge.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="80" height="40">
              <rect width="80" height="40" fill="#446688"/>
            </svg>
            """)
        let file = try fixture.file("Attachment.md", text: "# Attachment\n\n![Badge](badge.svg)\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let badge = preview.buttons["Badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), preview.debugDescription)
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("# Attachment\n\nReplaced by text.\n")
        XCTAssertTrue(preview.staticTexts["Replaced by text."].waitForExistence(timeout: 10))
        XCTAssertTrue(badge.waitForNonExistence(timeout: 10),
                      "Removing a Markdown image must discard Textual's old resolved attachment")
    }

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
