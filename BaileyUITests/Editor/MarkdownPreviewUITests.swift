import AppKit
import Foundation
import AVFoundation
import XCTest

@MainActor
final class MarkdownPreviewUITests: XCTestCase {
    func testRealBaileyDocumentationPreviewKeepsItsOriginalBytes() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repository.appendingPathComponent("docs/testing.md")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertGreaterThan(source.utf8.count, 20_000)
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("Actual-Testing.md", text: source)
        let original = try Data(contentsOf: file)

        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual((editor.value as? String)?.count, source.count)

        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue(preview.staticTexts["测试与验收"].waitForExistence(timeout: 15),
                      "The real repository document must render its first heading")
        XCTAssertTrue(preview.staticTexts["完成标准"].waitForExistence(timeout: 15))
        preview.swipeUp()
        XCTAssertTrue(preview.exists, "Long real documentation must remain readable after scrolling")

        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual((editor.value as? String)?.count, source.count)
        XCTAssertEqual(try Data(contentsOf: file), original,
                       "Opening, scrolling, and closing preview must not write the source file")
    }

    func testInlineAndBlockHTMLLinksUseHandPointerWithoutWebKit() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let destination = try fixture.file("docs/guide.md", text: "# Actual guide")
        let source = try fixture.file("HTMLLinks.md", text: """
            # Native HTML links

            Before <a href="docs/guide.md"><strong>Inline HTML</strong></a> after.

            <p><a href="docs/guide.md"><em>Block HTML</em></a></p>
            """)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(source, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        for label in ["Inline HTML", "Block HTML"] {
            let link = preview.links[label]
            XCTAssertTrue(link.waitForExistence(timeout: 10), preview.debugDescription)
            link.hover()
            XCTAssertEqual(NSCursor.currentSystem?.hotSpot, NSCursor.pointingHand.hotSpot,
                           "HTML \(label) must use the pointing-hand cursor over actual linked text")
            link.click()
            XCTAssertTrue(WorkspaceUITestSupport.fileTab(destination, in: window)
                .waitForExistence(timeout: 10), "\(label) did not open the authorized project file")
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(preview.waitForExistence(timeout: 10))
        }
    }

    func testHoverUsesHandOnlyForActualMarkdownLinks() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("Pointer.md", text: """
            # Plain Heading

            Regular text has a text-selection cursor.

            [Read guide](guide.md) and [More info](guide.md) after.
            """)
        let destination = try fixture.file("guide.md", text: "# Guide")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let heading = preview.staticTexts["Plain Heading"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 15))
        heading.hover()
        guard let normal = NSCursor.currentSystem else { return XCTFail("System cursor unavailable") }
        let hand = NSCursor.pointingHand
        XCTAssertFalse(normal.image.tiffRepresentation == hand.image.tiffRepresentation
                       && normal.hotSpot == hand.hotSpot,
                       "Ordinary Markdown text must not inherit the hand cursor")

        let link = preview.links["Read guide"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), preview.debugDescription)
        link.hover()
        guard let cursor = NSCursor.currentSystem else { return XCTFail("Link cursor unavailable") }
        XCTAssertEqual(cursor.hotSpot, hand.hotSpot,
                       "A link must expose the pointing-hand system cursor")
        XCTAssertEqual(cursor.image.tiffRepresentation, hand.image.tiffRepresentation,
                       "Moving onto a Markdown text link must change the actual cursor shape")
        let second = preview.links["More info"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        second.hover()
        XCTAssertEqual(NSCursor.currentSystem?.hotSpot, hand.hotSpot,
                       "Another link in the same paragraph must also use the hand pointer")
        let plain = preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "Regular text has a text-selection cursor"
        )).firstMatch
        XCTAssertTrue(plain.waitForExistence(timeout: 10))
        plain.hover()
        XCTAssertNotEqual(NSCursor.currentSystem?.hotSpot, hand.hotSpot,
                          "Leaving a link must restore the normal text cursor")
        guard let textPointer = NSCursor.currentSystem else {
            return XCTFail("Selectable prose must expose a system cursor")
        }
        XCTAssertGreaterThan(textPointer.image.size.height, textPointer.image.size.width * 1.5,
                             "Selectable Markdown prose must restore the tall I-beam pointer")
        let anchor = preview.buttons.matching(identifier: "bailey.markdown.anchor.plain-heading").firstMatch
        XCTAssertTrue(anchor.waitForExistence(timeout: 10))
        for iteration in 0..<10 {
            anchor.hover()
            let handReady = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in NSCursor.currentSystem?.hotSpot == hand.hotSpot },
                object: nil
            )
            let handSettled = XCTWaiter.wait(for: [handReady], timeout: 2) == .completed
            if !handSettled {
                print("ANCHOR_HOVER_FAILURE iteration=\(iteration) mouse=\(NSEvent.mouseLocation) anchor=\(anchor.frame) cursor=\(String(describing: NSCursor.currentSystem?.hotSpot))")
            }
            XCTAssertTrue(handSettled,
                          "The heading button must settle to the native hand cursor after each hover")
            plain.hover()
            let textReady = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in NSCursor.currentSystem?.hotSpot != hand.hotSpot },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [textReady], timeout: 2), .completed,
                           "Leaving a heading link must restore the text-selection cursor")
        }
        link.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(destination, in: window).waitForExistence(timeout: 10),
                      "Link cursor tracking must not steal the native Text click action")
    }

    func testFootnoteLinkOpensSeparatedNumberedSection() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let filler = (0..<40).map { "Paragraph \($0) with safe content." }
            .joined(separator: "\n\n")
        let file = try fixture.file("Footnotes.md", text: """
            # Footnote article

            Read the attached footnote[^ref].

            \(filler)

            [^ref]: A separate, **formatted** native footnote.
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
        let reference = preview.links["1"].firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 15), preview.debugDescription)
        reference.hover()
        let original = XCTAttachment(screenshot: window.screenshot())
        original.name = "GitHub superscript footnote link"
        original.lifetime = .keepAlways
        add(original)

        reference.click()
        let reached = XCTAttachment(screenshot: window.screenshot())
        reached.name = "GitHub footnote section immediately after navigation"
        reached.lifetime = .keepAlways
        add(reached)
        let definition = preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "A separate, formatted native footnote"
        )).firstMatch
        XCTAssertTrue(definition.waitForExistence(timeout: 15), preview.debugDescription)
        XCTAssertTrue(preview.frame.intersects(definition.frame),
                      "Clicking a footnote reference must reveal the separated note")
    }

    func testRepeatedHeadingFootnoteAndInvalidCrossFileFragments() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let filler = (0..<48).map { "Paragraph \($0) before the second heading." }
            .joined(separator: "\n\n")
        let targetSource = [
            "# Target document", "", "## Duplicate", "",
            filler, "", "## Duplicate", "", "Footnote reference[^ref].", "",
            "[^ref]: Destination note **with emphasis**."
        ].joined(separator: "\n")
        let target = try fixture.file("Notes.md", text: targetSource)
        let index = try fixture.file("Index.md", text: [
            "# Index", "",
            "[Second repeated heading](Notes.md#duplicate-1)", "",
            "[Linked footnote](Notes.md#bailey-note:ref)", "",
            "[Invalid fragment](Notes.md#heading-does-not-exist)"
        ].joined(separator: "\n"))
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(index, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let indexTab = WorkspaceUITestSupport.fileTab(index, in: window)
        let targetTab = WorkspaceUITestSupport.fileTab(target, in: window)
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))

        let repeated = preview.links["Second repeated heading"]
        XCTAssertTrue(repeated.waitForExistence(timeout: 10))
        repeated.click()
        XCTAssertTrue(targetTab.waitForExistence(timeout: 15))
        let secondAnchor = WorkspaceUITestSupport.element(
            "bailey.markdown.anchor.duplicate-1", in: app
        )
        XCTAssertTrue(secondAnchor.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(secondAnchor.frame.intersection(window.frame).height, 1,
                             "The duplicate suffix must select the second heading, not the first")

        indexTab.click()
        let footnote = preview.links["Linked footnote"]
        XCTAssertTrue(footnote.waitForExistence(timeout: 10))
        footnote.click()
        let note = preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "Destination note with emphasis"
        )).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(note.frame.intersection(window.frame).height, 1,
                             "A cross-file footnote fragment must reach its definition")

        indexTab.click()
        let invalid = preview.links["Invalid fragment"]
        XCTAssertTrue(invalid.waitForExistence(timeout: 10))
        invalid.click()
        let warning = app.staticTexts["Could not open this link."].firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(warning.frame.intersection(window.frame).height, 1,
                             "An invalid cross-file fragment must show an immediately visible error")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), targetSource)
    }

    func testRelativeMarkdownUnicodeFileFragmentOpensItsTargetHeading() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let destinationText = "# Document\n\n" + (0..<70).map { index in
            "Paragraph \(index): 中英 mixed content."
        }.joined(separator: "\n\n") + "\n\n## 章节 中文\n\nReached target."
        let destination = try fixture.file("Notes 中文.md", text: destinationText)
        let index = try fixture.file("Index.md", text: [
            "# Index", "",
            "[Open Chinese chapter](Notes%20%E4%B8%AD%E6%96%87.md#%E7%AB%A0%E8%8A%82-%E4%B8%AD%E6%96%87)"
        ].joined(separator: "\n"))
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(index, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let link = preview.links["Open Chinese chapter"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()
        let targetTab = WorkspaceUITestSupport.fileTab(destination, in: window)
        XCTAssertTrue(targetTab.waitForExistence(timeout: 15),
                      "Relative links must reuse the real authorized destination FileTab")
        XCTAssertTrue(preview.waitForExistence(timeout: 20),
                      "A target link with a heading fragment must open native Markdown preview")
        let heading = preview.staticTexts["章节 中文"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(heading.frame.intersection(window.frame).height, 1,
                             "The cross-file heading fragment must scroll its target into view")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), destinationText)
    }

    func testPercentEncodedChineseHeadingAndMissingFragmentNavigateNatively() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let filler = (0..<65).map { "Long paragraph \($0) of Markdown content." }
            .joined(separator: "\n\n")
        let file = try fixture.file("Chinese-Anchor.md", text: [
            "# Navigation", "",
            "[Jump Chinese](#章节-中文) and [Missing](#no-such-heading).", "",
            filler, "", "## 章节 中文", "", "Destination reached.", "",
            "[Missing near destination](#no-such-heading)"
        ].joined(separator: "\n"))
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))

        let missing = preview.links["Missing"]
        XCTAssertTrue(missing.waitForExistence(timeout: 10))
        missing.click()
        XCTAssertTrue(app.staticTexts["Could not open this link."].waitForExistence(timeout: 10),
                      "An unknown fragment must show an inline navigation error")

        let valid = preview.links["Jump Chinese"]
        XCTAssertTrue(valid.waitForExistence(timeout: 10))
        valid.click()
        let destination = preview.staticTexts["章节 中文"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 15),
                      "Percent-encoded Unicode fragment must resolve to its decoded heading")
        let visibleRect = destination.frame.intersection(window.frame)
        XCTAssertGreaterThan(visibleRect.height, 1,
                             "Clicking a distant Unicode heading must scroll it into the visible window")
        XCTAssertGreaterThan(visibleRect.width, 5)
        let missingAtBottom = preview.links["Missing near destination"]
        XCTAssertTrue(missingAtBottom.waitForExistence(timeout: 10))
        missingAtBottom.click()
        let warning = app.staticTexts["Could not open this link."].firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(warning.frame.intersection(window.frame).height, 1,
                             "Invalid in-page anchors must reveal their error from deep in a document")
        XCTAssertGreaterThan(missingAtBottom.frame.intersection(window.frame).height, 1,
                             "An invalid anchor must not jump the reader away from the clicked link")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).contains("## 章节 中文"), true)
    }

    func testHeadingLinkScrollsToAnchorAndProvidesCopyablePointerTarget() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let filler = (0..<45).map { "Paragraph \($0) before the target." }
            .joined(separator: "\n\n")
        let file = try fixture.file("Anchors.md", text: """
            # Navigation

            [Go to details](#detail-section)

            \(filler)

            ## Detail Section

            Target paragraph is visible after navigation.

            [Return to top](#navigation)
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
        let link = preview.links["Go to details"]
        XCTAssertTrue(link.waitForExistence(timeout: 15), preview.debugDescription)
        link.click()

        let heading = preview.staticTexts["Detail Section"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 15), preview.debugDescription)
        XCTAssertTrue(preview.frame.intersects(heading.frame),
                      "Anchor navigation must scroll the destination into the visible viewport")
        heading.hover()
        let hovered = XCTAttachment(screenshot: window.screenshot())
        hovered.name = "GitHub heading link hovered after in-document navigation"
        hovered.lifetime = .keepAlways
        add(hovered)
        let copy = preview.buttons.matching(
            identifier: "bailey.markdown.anchor.detail-section"
        ).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10), preview.debugDescription)
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "#detail-section")
        let back = preview.links["Return to top"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), preview.debugDescription)
        back.hover()
        XCTAssertEqual(NSCursor.currentSystem?.hotSpot, NSCursor.pointingHand.hotSpot,
                       "A link revealed after scrolling must use the hand cursor")
        back.click()
        let start = preview.staticTexts["Navigation"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.frame.intersects(start.frame),
                      "In-document navigation must restore the heading at the top")
    }

    func testStyledMarkdownLinkRetainsRichTextAndOpensTarget() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let destination = try fixture.file("docs/guide.md", text: "# Target\n\nDestination body.")
        let source = try fixture.file("Links.md", text: """
            # Styled links

            [**Bold** *Italic* ~~Strike~~](docs/guide.md)
            """)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(source, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let link = preview.links["Bold Italic Strike"]
        XCTAssertTrue(link.waitForExistence(timeout: 15), preview.debugDescription)
        link.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(destination, in: window).waitForExistence(timeout: 10))
        XCTAssertEqual(window.textViews.firstMatch.value as? String,
                       "# Target\n\nDestination body.")
    }

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
        app.activate()
        XCTAssertEqual(app.state, .runningForeground,
                       "The GUI test must own the graphical session before opening the file")
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
        XCTAssertTrue(copy.waitForExistence(timeout: 10),
                      "Copy must remain accessible to keyboard and VoiceOver before mouse hover")
        XCTAssertEqual(copy.value as? String, "Ready")
        preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "let answer = 42"
        )).firstMatch.hover()
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), code)
        XCTAssertEqual(copy.value as? String, "Copied")

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
        for _ in 0..<5 {
            XCTAssertTrue(preview.staticTexts["Alpha Beta Gamma"].waitForExistence(timeout: 10),
                          "Adjacent HTML inline elements must form a single visual line")
            XCTAssertTrue(preview.staticTexts["One Two Three"].waitForExistence(timeout: 10),
                          "HTML details open must survive each preview mount")
            app.typeKey("v", modifierFlags: [.command, .shift])
            XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
            app.typeKey("v", modifierFlags: [.command, .shift])
            XCTAssertTrue(preview.waitForExistence(timeout: 10))
        }
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
        let sourceTab = WorkspaceUITestSupport.fileTab(security, in: window)
        XCTAssertTrue(sourceTab.exists)

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
                let destinationTab = WorkspaceUITestSupport.fileTab(destination, in: window)
                XCTAssertTrue(destinationTab.waitForExistence(timeout: 10),
                              "SECURITY.md link \(title) must open \(path)")
                if path == "docs/testing.md" {
                    // This source link includes #隔离环境. An anchored file link opens
                    // the authorized Markdown preview at its requested heading.
                    XCTAssertTrue(preview.waitForExistence(timeout: 15))
                    let anchor = WorkspaceUITestSupport.element(
                        "bailey.markdown.anchor.隔离环境", in: app
                    )
                    XCTAssertTrue(anchor.waitForExistence(timeout: 15))
                    XCTAssertGreaterThan(anchor.frame.intersection(window.frame).height, 1,
                                         "The original SECURITY.md link must reach its target section")
                    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8),
                                   try String(contentsOf: repository.appending(path: path), encoding: .utf8))
                } else {
                    let editor = window.textViews.firstMatch
                    XCTAssertTrue(editor.waitForExistence(timeout: 10),
                                  "Unanchored SECURITY.md link \(title) must open source \(path)")
                    XCTAssertEqual(editor.value as? String,
                                   try String(contentsOf: destination, encoding: .utf8))
                }
                destinationTab.click()
                app.typeKey("w", modifierFlags: .command)
                XCTAssertTrue(destinationTab.waitForNonExistence(timeout: 10),
                              "⌘W must close the explicitly selected \(path) tab")
                sourceTab.click()
                XCTAssertTrue(preview.waitForExistence(timeout: 10),
                              "Re-selecting SECURITY.md must restore its own preview")
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
    func testSwitchingBetweenDifferentMarkdownTabsNeverReusesAnotherPreview() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let firstText = "# First document\n\n" + (0..<500).map {
            "First-only paragraph \($0) with **markdown**."
        }.joined(separator: "\n\n")
        let secondText = "# Second document\n\nSecond-only content."
        let first = try fixture.file("First.md", text: firstText)
        let second = try fixture.file("Second.md", text: secondText)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))
        firstRow.doubleClick()
        let firstTab = WorkspaceUITestSupport.fileTab(first, in: window)
        XCTAssertTrue(firstTab.waitForExistence(timeout: 15))
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.staticTexts["First document"].waitForExistence(timeout: 15))

        let secondRow = WorkspaceUITestSupport.fileRow(second, in: window)
        XCTAssertTrue(secondRow.waitForExistence(timeout: 15))
        secondRow.doubleClick()
        let secondTab = WorkspaceUITestSupport.fileTab(second, in: window)
        XCTAssertTrue(secondTab.waitForExistence(timeout: 15))
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 15))
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.staticTexts["Second document"].waitForExistence(timeout: 15))
        XCTAssertFalse(preview.staticTexts["First document"].exists,
                       "The second tab must never inherit another file's parsed AST")

        firstTab.click()
        XCTAssertTrue(preview.staticTexts["First document"].waitForExistence(timeout: 15))
        XCTAssertFalse(preview.staticTexts["Second document"].exists,
                       "Returning to the first tab must restore its own preview")
        secondTab.click()
        XCTAssertTrue(preview.staticTexts["Second document"].waitForExistence(timeout: 15))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), firstText)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), secondText)
    }

    func testRapidEditsInLongSideBySidePreviewNeverRestoreOlderSnapshot() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let body = (0..<1_200).map { index in
            "Paragraph \(index) with **emphasis**, 中文, and [link](guide.md)."
        }.joined(separator: "\n\n")
        let original = "# Baseline heading\n\n" + body + "\n"
        let file = try fixture.file("Rapid-Live.md", text: original)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        tab.rightClick()
        let companion = app.menuItems["Show Side by Side"]
        XCTAssertTrue(companion.waitForExistence(timeout: 10))
        companion.click()
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue(preview.staticTexts["Baseline heading"].waitForExistence(timeout: 20))

        func replaceHeading(_ heading: String) {
            editor.click()
            editor.typeKey(.upArrow, modifierFlags: .command)
            editor.typeKey(.rightArrow, modifierFlags: [.command, .shift])
            editor.typeText("# " + heading)
        }
        replaceHeading("Intermediate heading")
        replaceHeading("Latest heading")

        XCTAssertTrue(preview.staticTexts["Latest heading"].waitForExistence(timeout: 30),
                      "Only the newest native TextKit revision may be published")
        XCTAssertFalse(preview.staticTexts["Intermediate heading"].exists,
                       "A cancelled background Markdown parse must not restore stale content")
        XCTAssertTrue(preview.staticTexts.containing(
            NSPredicate(format: "value CONTAINS %@", "Paragraph 0")
        ).firstMatch.exists, "A fast heading edit must preserve the long document body")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original,
                       "Live preview must never save an unfinished draft")
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
