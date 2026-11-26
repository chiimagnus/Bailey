import Accessibility
import AppKit
import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class MarkdownPreviewUITests: XCTestCase {
    private func markdownHeading(_ anchor: String, in preview: XCUIElement) -> XCUIElement {
        preview.descendants(matching: .any)
            .matching(identifier: "bailey.markdown.heading.\(anchor)").firstMatch
    }

    func testGitHubAlertsShowFiveNativeTitlesAndPreserveQuotedContent() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let titles = ["Note", "Tip", "Important", "Warning", "Caution"]
        let source = titles.enumerated().map { index, title in
            "> [!\(title.uppercased())]\n> Body \(index + 1) 中文"
        }.joined(separator: "\n\n")
        let file = try fixture.file("Alerts.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        for (index, title) in titles.enumerated() {
            let header = preview.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@ OR value == %@", title, title
            )).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 10), "Missing native \(title) title")
            let body = preview.staticTexts["Body \(index + 1) 中文"].firstMatch
            XCTAssertTrue(body.waitForExistence(timeout: 5), "Missing quoted body for \(title)")
        }
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
    }

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
        app.activate()
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual((editor.value as? String)?.count, source.count)
        XCTAssertTrue((editor.value as? String)?.hasPrefix("# 测试与验收") == true,
                      "Opening the source must preserve the original heading delimiter")

        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue(preview.descendants(matching: .any).matching(
            identifier: "bailey.markdown.heading.测试与验收").firstMatch.waitForExistence(timeout: 15),
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

    func testGFMTaskMarkersAreReadOnlyAndLineBreaksKeepTheirReadingSemantics() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # GFM interaction

            Soft first
            soft second

            Hard first\\
            hard second

            > - [x] Completed fixture task
            >   - Nested action with **emphasis** and العربية
            > - [ ] Pending fixture task
            """
        let file = try fixture.file("GFM.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, source)
        app.typeKey("v", modifierFlags: [.command, .shift])

        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        func text(containing value: String) -> XCUIElement {
            preview.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                     value, value)).firstMatch
        }
        XCTAssertTrue(text(containing: "Soft first soft second").waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Hard first\nhard second").exists)
        XCTAssertTrue(text(containing: "Nested action with emphasis and العربية").exists)
        for state in ["Completed", "Incomplete"] {
            let marker = preview.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@ OR value == %@", state, state
            )).firstMatch
            guard marker.waitForExistence(timeout: 5) else {
                return XCTFail("Missing task state \(state) in the native AX tree: \(preview.debugDescription)")
            }
            marker.click()
            XCTAssertTrue(marker.exists, "A read-only marker must keep its original state")
        }
        XCTAssertEqual(preview.checkBoxes.count, 0, "A task marker must not expose a toggle action")
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, source, "Task marks must not edit the TextKit buffer")
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
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
        let heading = preview.descendants(matching: .any)
            .matching(identifier: "bailey.markdown.heading.plain-heading").firstMatch
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
        let heading = markdownHeading("章节-中文", in: preview)
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
        let destination = markdownHeading("章节-中文", in: preview)
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

        let heading = markdownHeading("detail-section", in: preview)
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
        let start = markdownHeading("navigation", in: preview)
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

    func testNestedMarkdownImageInsideEmphasisUsesRealAuthorizedNativeImage() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let image = try fixture.file("nested.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="90" height="45">
              <rect width="90" height="45" fill="#2980b9"/>
            </svg>
            """)
        let source = """
            # Nested media

            **Styled prose with ![Nested chart](nested.svg) in the same paragraph.**
            """
        let document = try fixture.file("NestedImage.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en",
                                                    project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(document, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let nested = preview.buttons["Nested chart"]
        XCTAssertTrue(nested.waitForExistence(timeout: 15),
                      "Image nested inside emphasis must render as interactive native media, not alt-only Text")
        XCTAssertGreaterThan(nested.frame.height, 30)
        nested.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(image, in: window).waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), source)
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
        let start = prose.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.25))
        let end = prose.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.25))
        start.click(forDuration: 0.15, thenDragTo: end)
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

    func testSVGUsesIntrinsicPointSizeWithoutLosingRetinaPixels() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let document = try fixture.file("Retina.md", text: "# Retina\n\n![Red SVG](red.svg)\n")
        _ = try fixture.file("red.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">
              <rect width="40" height="20" fill="#ff0000"/>
            </svg>
            """)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let row = WorkspaceUITestSupport.fileRow(document, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let picture = preview.buttons["Red SVG"]
        XCTAssertTrue(picture.waitForExistence(timeout: 10), preview.debugDescription)
        let tiff = try XCTUnwrap(picture.screenshot().image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        XCTAssertEqual(picture.frame.width, 40, accuracy: 2,
                       "Retina SVG rasterization must not double the declared CSS display width")
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / picture.frame.width,
                       try XCTUnwrap(NSScreen.main).backingScaleFactor, accuracy: 0.2,
                       "The SVG must render at the actual display backing scale without blurring")
    }

    func testAnimatedGIFChangesVisibleFramesAndSourceBytesStayUntouched() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let document = try fixture.file("Animated.md", text: "# Animation\n\n![Pulse](pulse.gif)\n")
        let original = try Data(contentsOf: document)
        let gif = fixture.root.appending(path: "pulse.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            gif as CFURL, UTType.gif.identifier as CFString, 2, nil
        ))
        for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                      CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            let frame = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let row = WorkspaceUITestSupport.fileRow(document, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let image = preview.buttons["Pulse"]
        XCTAssertTrue(image.waitForExistence(timeout: 10), preview.debugDescription)

        func sampledColor() -> NSColor? {
            guard let tiff = image.screenshot().image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        }
        func isRed(_ color: NSColor) -> Bool { color.redComponent > 0.7 && color.blueComponent < 0.3 }
        func isBlue(_ color: NSColor) -> Bool { color.blueComponent > 0.7 && color.redComponent < 0.3 }
        if AccessibilitySettings.animatedImagesEnabled {
            var redSeen = false
            var blueSeen = false
            let changingFrames = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let sampled = sampledColor() else { return false }
                redSeen = redSeen || isRed(sampled)
                blueSeen = blueSeen || isBlue(sampled)
                return redSeen && blueSeen
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [changingFrames], timeout: 8), .completed,
                           "Animated GIF must display both actual frames, not only a static poster")
        } else {
            let poster = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                sampledColor().map(isRed) == true
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [poster], timeout: 8), .completed)
            let changes = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                sampledColor().map { !isRed($0) } ?? true
            }, object: nil)
            changes.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [changes], timeout: 1.6), .completed,
                           "Disabled system animation must retain the actual first frame")
        }
        XCTAssertEqual(try Data(contentsOf: document), original)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
    }

    func testNativeVideoLoadsOnlyOnDemandAndSupportsSeekPauseAndRelease() async throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let document = try fixture.file("Video.md", text: """
            # Local Video

            <video controls src="clip.mov"></video>
            """)
        let movie = fixture.root.appending(path: "clip.mov")
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64
            ]
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frameIndex in 0..<16 {
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(
                kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB,
                nil, &pixelBuffer
            ), kCVReturnSuccess)
            let frame = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(frame, [])
            if let bytes = CVPixelBufferGetBaseAddress(frame) {
                memset(bytes, 0xff, CVPixelBufferGetDataSize(frame))
            }
            CVPixelBufferUnlockBaseAddress(frame, [])
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !input.isReadyForMoreMediaData && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData, "The local video encoder must accept each frame")
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(frameIndex), timescale: 2)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        let asset = AVURLAsset(url: movie)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)

        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let row = WorkspaceUITestSupport.fileRow(document, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let start = preview.buttons["Load Video"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let player = WorkspaceUITestSupport.element("bailey.markdown.media", in: app)
        XCTAssertFalse(player.exists, "Video must not create an AVPlayer before a user requests it")
        start.click()
        XCTAssertTrue(player.waitForExistence(timeout: 12), preview.debugDescription)
        player.hover()
        let toggle = player.checkBoxes["play/pause"]
        let timeline = player.sliders["timeline"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        let stopped = String(describing: toggle.value ?? "")
        toggle.click()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(describing: toggle.value ?? "") != stopped
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 5), .completed)
        toggle.click()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(describing: toggle.value ?? "") == stopped
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        let before = String(describing: timeline.value ?? "")
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
        let seeked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(describing: timeline.value ?? "") != before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [seeked], timeout: 5), .completed,
                       "Video must seek through the native AVKit timeline")
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(player.waitForNonExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.buttons["Load Video"].waitForExistence(timeout: 10),
                      "Video player must release its previous asset on preview dismissal")
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
        let frameCount: AVAudioFrameCount = 64_000
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(frameCount))
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
        player.hover()
        let toggle = player.checkBoxes["play/pause"]
        let timeline = player.sliders["timeline"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10),
                      "The native AVKit player must expose its play/pause control")
        XCTAssertTrue(timeline.waitForExistence(timeout: 10),
                      "The native AVKit player must expose its seek timeline")
        let before = String(describing: toggle.value ?? "")
        toggle.click()
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(describing: toggle.value ?? "") != before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 5), .completed,
                       "Playing audio must change the native AVKit play/pause state")
        toggle.click()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(describing: toggle.value ?? "") == before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed,
                       "Pause must restore the actual native AVKit control state")
        let positionBefore = String(describing: timeline.value ?? "")
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
        let seeked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(describing: timeline.value ?? "") != positionBefore
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [seeked], timeout: 5), .completed,
                       "Dragging the AVKit timeline must seek within the original local WAV")
        let diagram = WorkspaceUITestSupport.element("bailey.markdown.mermaid", in: app)
        XCTAssertTrue(diagram.waitForExistence(timeout: 10), preview.debugDescription)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(player.waitForNonExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.buttons["Load Audio"].waitForExistence(timeout: 10),
                      "Reopening the Markdown preview must not reuse a retired AVPlayer")
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
        let targetLines = 20_000
        func section(_ index: Int) -> [String] {
            ["## Section \(index) 中文 🧪", "",
             "Paragraph \(index) with **emphasis**, العربية, [link](guide.md), and $x_i+y$.", "",
             "> [!NOTE]", "> A mixed-content reading fixture.", "",
             "- [x] Checked", "  - Nested step", "",
             "| 名称 | Value |", "| --- | ---: |", "| 中文 | \(index) |", "",
             "```swift", "let sample = \(index)", "```", "",
             "<details>", "<summary>Method</summary>", "<p>HTML &amp; text</p>", "</details>", "",
             index.isMultiple(of: 4) ? "![Scoped SVG](asset.svg)" : "![Missing resource](missing.png)", ""]
        }
        _ = try fixture.file("asset.svg", text: """
            <svg xmlns="http://www.w3.org/2000/svg" width="80" height="32"><rect width="80" height="32" fill="#0969da"/></svg>
            """)
        _ = try fixture.file("guide.md", text: "# Linked guide\n")
        var lines = ["# Baseline heading", ""]
        for index in 0..<((targetLines - lines.count - 1) / section(0).count) {
            lines += section(index)
        }
        while lines.count < targetLines - 1 { lines.append("") }
        lines.append("## End marker")
        let original = lines.joined(separator: "\n")
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
        let end = preview.staticTexts["End marker"]
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        let atEnd = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            end.exists && end.frame.intersection(preview.frame).height > 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [atEnd], timeout: 20), .completed,
                       "The real companion must reach the end of the mixed 20,000-line Markdown")
        editor.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(preview.staticTexts["Baseline heading"].waitForExistence(timeout: 15))

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

    func testMarkdownScrollSynchronizationCanBeDisabledAndReenabledFromFileMenu() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = (0..<80).map { index in
            "## Section \(index)\n\nParagraph \(index) is kept in the original source."
        }.joined(separator: "\n\n")
        let file = try fixture.file("ScrollMenu.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let nativeSource = window.scrollViews.containing(.textView, identifier: nil).firstMatch
        let sourceBar = nativeSource.scrollBars.element(boundBy: 1)
        XCTAssertTrue(sourceBar.waitForExistence(timeout: 10))
        func sourceProgress() -> Double {
            Double(String(describing: sourceBar.value ?? "")) ?? -1
        }
        XCTAssertEqual(sourceProgress(), 0, accuracy: 0.02)
        tab.rightClick()
        let syncMenu = app.menuItems["Synchronize Scrolling"]
        XCTAssertTrue(syncMenu.waitForExistence(timeout: 10))
        syncMenu.click()
        for _ in 0..<5 { preview.swipeUp() }
        XCTAssertEqual(sourceProgress(), 0, accuracy: 0.02,
                       "Disabling sync must not scroll the source during reader interaction")
        tab.rightClick()
        XCTAssertTrue(syncMenu.waitForExistence(timeout: 10))
        syncMenu.click()
        for _ in 0..<5 { preview.swipeUp() }
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            sourceProgress() > 0.08
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 8), .completed,
                       "Reenabling sync must reconnect the original source editor")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testPreviewKeepsReadingTheSameHeadingWhenSourceGrowsAboveIt() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Overview

            [Jump to destination](#reading-destination)

            """ + (0..<44).map { index in
                let title = index == 22 ? "Reading destination" : "Section \(index)"
                return "\n## \(title)\n\n中文 paragraph e\u{301} 🛰️ with **emphasis** and `code`.\n"
            }.joined()
        let file = try fixture.file("ReadingPosition.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        tab.rightClick()
        let syncMenu = app.menuItems["Synchronize Scrolling"]
        XCTAssertTrue(syncMenu.waitForExistence(timeout: 10))
        syncMenu.click()

        let preview = window.scrollViews.matching(identifier: "bailey.markdown.preview").firstMatch
        let link = preview.links["Jump to destination"]
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.click()
        let destination = window.descendants(matching: .any)
            .matching(identifier: "bailey.markdown.heading.reading-destination").firstMatch
        func destinationIsVisible() -> Bool {
            guard destination.exists, destination.label == "Reading destination" else { return false }
            return destination.frame.intersection(preview.frame).height > 1
        }
        let located = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            destinationIsVisible()
        }, object: nil)
        guard XCTWaiter.wait(for: [located], timeout: 10) == .completed else {
            return XCTFail("The internal link must make the original heading visible before the edit")
        }

        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        let prefix = (0..<16).map { "## Inserted \($0)\n\n" }.joined()
        editor.typeText(prefix)
        XCTAssertEqual(editor.value as? String, prefix + source)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)

        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        tab.rightClick()
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            destinationIsVisible()
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed,
                       "After a new parse and remount, the original heading must remain visible")
    }

    func testDoubleClickInsidePreviewTextLocatesActuallyClickedGlyph() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let cases = [
            (name: "Literal", raw: "M", rendered: "M", opening: "", closing: ""),
            (name: "Named", raw: "&amp;", rendered: "&", opening: "", closing: ""),
            (name: "Numeric", raw: "&#x1F680;", rendered: "🚀", opening: "", closing: ""),
            (name: "InlineCode", raw: "M", rendered: "M", opening: "`` ", closing: " ``")
        ]
        let glyphCount = 12
        let target = 9
        let files = try cases.map { entry in
            let prefix = "# Click location\n\n" + entry.opening
            let source = prefix + String(repeating: entry.raw, count: glyphCount) + entry.closing
            return (file: try fixture.file("\(entry.name).md", text: source), source: source,
                    raw: entry.raw, rendered: entry.rendered, prefix: prefix, suffix: entry.closing)
        }
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        for entry in files {
            let row = WorkspaceUITestSupport.fileRow(entry.file, in: window)
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            row.doubleClick()
            XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
            app.typeKey("v", modifierFlags: [.command, .shift])
            let paragraph = String(repeating: entry.rendered, count: glyphCount)
            let text = preview.staticTexts.matching(NSPredicate(format: "value == %@", paragraph)).firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 15))
            XCTAssertLessThan(text.frame.height, 32, "This coordinate targets a known glyph on a single line")
            let fraction = (CGFloat(target) + 0.5) / CGFloat(glyphCount)
            text.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).doubleClick()
            guard preview.waitForNonExistence(timeout: 10) else {
                return XCTFail("Double-click must open the source of \(entry.file.lastPathComponent)")
            }
            let editor = window.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            app.typeKey("z", modifierFlags: [])
            XCTAssertEqual(editor.value as? String, entry.prefix
                           + String(repeating: entry.raw, count: target) + "z"
                           + String(repeating: entry.raw, count: glyphCount - target) + entry.suffix)
            XCTAssertEqual(try Data(contentsOf: entry.file), Data(entry.source.utf8))
        }
    }

    func testDoubleClickSecondMergedParagraphLocatesItsOwnOriginalSourceRange() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Title

            Alpha first paragraph content.

            Beta second paragraph content.

            Gamma third paragraph content.
            """
        let file = try fixture.file("MergedLocate.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let merged = preview.staticTexts.containing(NSPredicate(
            format: "value CONTAINS %@", "Beta second paragraph content."
        )).firstMatch
        XCTAssertTrue(merged.waitForExistence(timeout: 10), preview.debugDescription)
        merged.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.5)).doubleClick()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10))
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.typeKey("z", modifierFlags: [])
        let edited = try XCTUnwrap(editor.value as? String)
        let insertion = (edited as NSString).range(of: "z")
        let beta = (source as NSString).range(of: "Beta second paragraph content.")
        XCTAssertTrue(insertion.location >= beta.location
                      && insertion.location <= NSMaxRange(beta),
                      "The double click must use the actual glyph's source block, not the merged run's first paragraph")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testDoubleClickInCompanionFocusesExistingTextKitWithoutClosingPreview() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = "# Introduction\n\nIntro content.\n\n## Destination\n\nBody after heading.\n"
        let file = try fixture.file("CompanionLocate.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let destination = markdownHeading("destination", in: preview)
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).doubleClick()
        XCTAssertTrue(preview.exists,
                      "Double-clicking companion text must preserve the side-by-side Dock layout")
        app.typeKey("x", modifierFlags: [])
        XCTAssertEqual(editor.value as? String,
                       source.replacingOccurrences(of: "## Destination", with: "## xDestination"),
                       "Double-click must focus the already-mounted TextKit caret at its original text")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testDoubleClickOnPlainPreviewHeadingLocatesOriginalSourceText() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = "# Introduction\n\nIntro content.\n\n## Destination\n\nBody after heading.\n"
        let file = try fixture.file("Locate.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let destination = markdownHeading("destination", in: preview)
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).doubleClick()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 10),
                      "Double-clicking ordinary preview text must switch to the source")
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.typeKey("x", modifierFlags: [])
        XCTAssertEqual(editor.value as? String,
                       source.replacingOccurrences(of: "## Destination", with: "## xDestination"),
                       "The caret must land on the original heading text, not its Markdown markers")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source,
                       "Locating source and editing the buffer must not save bytes implicitly")
    }

    func testReaderScrollPositionSurvivesSwitchBackToNativeSource() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = (0..<90).map { index in
            "## Section \(index)\n\nParagraph \(index) with 中文 and 👩‍🚀."
        }.joined(separator: "\n\n")
        let file = try fixture.file("SourceRestore.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let showPreview = app.menus["bailey.tab.file"].menuItems["Show Preview"]
        XCTAssertTrue(showPreview.waitForExistence(timeout: 10))
        showPreview.click()
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        for _ in 0..<8 { preview.swipeUp() }
        app.typeKey("v", modifierFlags: [.command, .shift])
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let sourceScroll = window.scrollViews.containing(.textView, identifier: nil).firstMatch
        XCTAssertTrue(sourceScroll.waitForExistence(timeout: 10))
        let sourceBar = try XCTUnwrap(sourceScroll.scrollBars.allElementsBoundByIndex.first {
            $0.frame.height > $0.frame.width
        }, "The restored source should expose its actual vertical scroll bar")
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Double(String(describing: sourceBar.value ?? "")) ?? -1) > 0.08
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 8), .completed,
                       "Switching reader to source must show the same original paragraph")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testPreviewScrollMovesActualSourceViewport() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = (0..<80).map { index in
            "## Section \(index)\n\nParagraph \(index) with regular content and 中文 emoji 🛰️."
        }.joined(separator: "\n\n")
        let file = try fixture.file("PreviewScroll.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let sourceScroll = window.scrollViews.containing(.textView, identifier: nil).firstMatch
        let sourceVerticalBar = sourceScroll.scrollBars.element(boundBy: 1)
        XCTAssertTrue(sourceVerticalBar.waitForExistence(timeout: 10))
        func value() -> Double {
            Double(String(describing: sourceVerticalBar.value ?? "")) ?? -1
        }
        let before = value()
        XCTAssertEqual(before, 0, accuracy: 0.02,
                       "The source must begin at its actual first line, not an unsettled layout")
        for _ in 0..<6 { preview.swipeUp() }
        let follows = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            value() > before + 0.08
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [follows], timeout: 8), .completed,
                       "Scrolling the native preview must advance the actual TextKit scroll bar")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source,
                       "Scrolling both panes must not modify or save the source bytes")
    }

    func testNativeImageViewerZoomFitAndActualSizePreservesOriginalPNG() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 5200, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 5200, height: 2000))
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let file = fixture.root.appendingPathComponent("Zoom.png")
        try png.write(to: file)
        let other = try fixture.file("Other.txt", text: "Leave the image tab.")
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let inspector = WorkspaceUITestSupport.element("bailey.image.inspector", in: app)
        XCTAssertTrue(inspector.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch
        let margins = inspector.frame.height - inspector.frame.width * 2000 / 5200
        XCTAssertGreaterThan(margins, 30, "The fixture must have vertical margins in Fit")
        let sampleY = margins / (4 * inspector.frame.height)
        func showsImage(_ bitmap: NSBitmapImageRep, at fraction: CGFloat) -> Bool {
            let windowFrame = window.frame
            let frame = inspector.frame
            let column = Int((frame.midX - windowFrame.minX) * CGFloat(bitmap.pixelsWide) / windowFrame.width)
            let row = Int((frame.minY + fraction * frame.height - windowFrame.minY)
                          * CGFloat(bitmap.pixelsHigh) / windowFrame.height)
            guard (0..<bitmap.pixelsWide).contains(column), (0..<bitmap.pixelsHigh).contains(row),
                  let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { return false }
            return color.redComponent > 0.6 && color.redComponent > 2 * max(color.greenComponent, color.blueComponent)
        }
        func waitForMargin(toShowImage visible: Bool) {
            let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let bitmap = NSBitmapImageRep(data: window.screenshot().pngRepresentation) else { return false }
                return showsImage(bitmap, at: 0.5) && showsImage(bitmap, at: sampleY) == visible
            }, object: nil)
            let result = XCTWaiter.wait(for: [rendered], timeout: 8)
            if result != .completed { add(XCTAttachment(screenshot: window.screenshot())) }
            XCTAssertEqual(result, .completed, "Expected the former Fit margin to show image: \(visible)")
        }
        waitForMargin(toShowImage: false)
        inspector.rightClick()
        let actual = WorkspaceUITestSupport.menuItem("100%", in: app)
        XCTAssertTrue(actual.waitForExistence(timeout: 5))
        actual.click()
        waitForMargin(toShowImage: true)
        WorkspaceUITestSupport.fileRow(other, in: window).doubleClick()
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 10))
        WorkspaceUITestSupport.fileTab(file, in: window).click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 10))
        waitForMargin(toShowImage: true)
        inspector.doubleClick()
        waitForMargin(toShowImage: false)
        XCTAssertEqual(try Data(contentsOf: file), png)
    }

    func testMermaidDiagramOpensNativeZoomSurfaceAndCloses() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Diagram

            ```mermaid
            flowchart TD
              A[Start] --> B[Finish]
            ```
            """
        let file = try fixture.file("Inspect.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let diagram = app.buttons["bailey.markdown.mermaid"]
        XCTAssertTrue(diagram.waitForExistence(timeout: 20),
                      "A valid Mermaid diagram must be a native inspectable image")
        diagram.click()
        let close = app.buttons["bailey.image.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let inspector = WorkspaceUITestSupport.element("bailey.image.inspector", in: app)
        XCTAssertTrue(inspector.waitForExistence(timeout: 10))
        inspector.rightClick()
        let actual = WorkspaceUITestSupport.menuItem("100%", in: app)
        XCTAssertTrue(actual.waitForExistence(timeout: 5))
        actual.click()
        let inspectorScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        inspectorScreenshot.name = "Native Mermaid image inspector at actual size"
        inspectorScreenshot.lifetime = .keepAlways
        add(inspectorScreenshot)
        close.click()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testHeadingFoldStateFollowsPrependedTextEditsUndoAndPreviewRemount() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Intro

            The initial paragraph.

            ## Folded

            SECRET_AFTER_HEADING

            ## Following

            FOLLOWING_BODY
            """
        let file = try fixture.file("FoldEdits.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(file, in: window)
            .waitForExistence(timeout: 15))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let heading = markdownHeading("folded", in: preview)
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        heading.hover()
        let toggle = preview.buttons["bailey.markdown.fold.folded"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertFalse(preview.staticTexts["SECRET_AFTER_HEADING"].exists)

        app.typeKey("v", modifierFlags: [.command, .shift])
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey(.upArrow, modifierFlags: .command)
        let prefix = "Inserted paragraph before heading.\n\n"
        editor.typeText(prefix)
        XCTAssertEqual(editor.value as? String, prefix + source)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "Collapsed",
                       "Folded heading must retain its identity when earlier text changes")
        XCTAssertFalse(preview.staticTexts["SECRET_AFTER_HEADING"].exists)

        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, source)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertFalse(preview.staticTexts["SECRET_AFTER_HEADING"].exists)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testChineseOutlineMenuUsesLocalizedLabel() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = try fixture.file("中文大纲.md", text: "# 第一节\n\n内容。\n\n## 第二节\n\n尾声。")
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "zh-Hans", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.rightClick()
        let outline = app.menuItems["大纲…"]
        XCTAssertTrue(outline.waitForExistence(timeout: 10),
                      "The document tab outline must be localized in Simplified Chinese")
        outline.click()
        let destination = app.buttons["bailey.markdown.outline.第二节"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.click()
        XCTAssertTrue(WorkspaceUITestSupport.element(
            "bailey.markdown.preview", in: app
        ).waitForExistence(timeout: 15))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "# 第一节\n\n内容。\n\n## 第二节\n\n尾声。")
    }

    func testOutlineKeyboardNavigationAndEscapeFromSourceMode() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # First

            FIRST_KB_BODY

            ## Second

            SECOND_KB_BODY

            # Third

            THIRD_KB_BODY
            """
        let file = try fixture.file("OutlineKeys.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        let outlineAction = app.menuItems["Outline…"]
        tab.rightClick()
        XCTAssertTrue(outlineAction.waitForExistence(timeout: 10))
        outlineAction.click()
        let second = app.buttons["bailey.markdown.outline.second"]
        XCTAssertTrue(second.waitForExistence(timeout: 15))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(second.waitForNonExistence(timeout: 10),
                      "Escape must dismiss the native outline without navigating")

        tab.rightClick()
        XCTAssertTrue(outlineAction.waitForExistence(timeout: 10))
        outlineAction.click()
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let destination = preview.staticTexts["SECOND_KB_BODY"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(destination.frame.intersection(preview.frame).height, 1,
                             "Arrow and Return must navigate to the selected heading")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testLastFoldedChapterStillShowsGlobalFootnoteAndReturnRevealsReference() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Last chapter

            RETURN_POINT[^note] is hidden after folding.

            HIDDEN_BODY_TEXT

            [^note]: Global note stays visible.
            """
        let file = try fixture.file("FoldedFootnote.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = window.scrollViews.matching(identifier: "bailey.markdown.preview").firstMatch
        let heading = window.descendants(matching: .any)
            .matching(identifier: "bailey.markdown.heading.last-chapter").firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertEqual(heading.label, "Last chapter")
        XCTAssertGreaterThan(heading.frame.intersection(preview.frame).height, 1)
        heading.hover()
        let fold = preview.buttons["bailey.markdown.fold.last-chapter"]
        XCTAssertTrue(fold.waitForExistence(timeout: 10))
        fold.click()
        XCTAssertEqual(fold.value as? String, "Collapsed")
        XCTAssertFalse(preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "HIDDEN_BODY_TEXT")
        ).firstMatch.exists)

        let note = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "Global note stays visible.")
        ).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10),
                      "Footnotes are a document-level section, never part of the final collapsed heading")
        let back = preview.links["↩"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.click()
        XCTAssertEqual(fold.value as? String, "Expanded")
        let reference = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "RETURN_POINT")
        ).firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(reference.frame.intersection(preview.frame).height, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testFootnoteReturnNavigatesBackToOriginalReference() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = "# Footnotes\n\nRETURN_TARGET_TEXT[^note] at the beginning.\n\n"
            + (0..<50).map { "A long intervening paragraph \($0) with 中文 content." }
                .joined(separator: "\n\n")
            + "\n\n[^note]: Definition at the end."
        let file = try fixture.file("Return.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let row = WorkspaceUITestSupport.fileRow(file, in: app.windows.firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(app.windows.firstMatch.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let noteLink = preview.links["1"].firstMatch
        XCTAssertTrue(noteLink.waitForExistence(timeout: 10), preview.debugDescription)
        noteLink.click()
        let definition = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "Definition at the end.")
        ).firstMatch
        XCTAssertTrue(definition.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(definition.frame.intersection(preview.frame).height, 1,
                             "Clicking footnote reference must show its native definition")
        let back = preview.links["↩"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10),
                      "The footnote needs a native return-to-reference link")
        back.click()
        let reference = preview.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "RETURN_TARGET_TEXT")
        ).firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(reference.frame.intersection(preview.frame).height, 1,
                             "Return link must actually restore the original reference's viewport")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testInternalLinkRevealsFoldedAncestorWithoutEditingSource() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Index

            [Jump to hidden section](#nested)

            ## Parent

            Parent body.

            ### Nested

            HIDDEN_DESTINATION_TEXT

            # End

            Finish.
            """
        let file = try fixture.file("FoldLink.md", text: source)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("v", modifierFlags: [.command, .shift])
        let preview = window.scrollViews.matching(identifier: "bailey.markdown.preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let parent = window.descendants(matching: .any)
            .matching(identifier: "bailey.markdown.heading.parent").firstMatch
        XCTAssertTrue(parent.waitForExistence(timeout: 10))
        XCTAssertEqual(parent.label, "Parent")
        XCTAssertGreaterThan(parent.frame.intersection(preview.frame).height, 1)
        parent.hover()
        let fold = preview.buttons["bailey.markdown.fold.parent"]
        XCTAssertTrue(fold.waitForExistence(timeout: 10))
        fold.click()
        XCTAssertEqual(fold.value as? String, "Collapsed")
        XCTAssertFalse(preview.staticTexts["HIDDEN_DESTINATION_TEXT"].exists)

        let link = preview.links["Jump to hidden section"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()
        let destination = preview.staticTexts["HIDDEN_DESTINATION_TEXT"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10),
                      "Internal heading links must reveal collapsed ancestor sections")
        XCTAssertEqual(fold.value as? String, "Expanded")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testOutlineOpensDuplicateHeadingAndFoldsOnlyItsSection() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = """
            # Main

            ## Topic

            FIRST_TOPIC_BODY

            ## Topic

            SECOND_TOPIC_BODY

            ### Child

            CHILD_BODY

            # Tail

            TAIL_BODY
            """
        let file = try fixture.file("Outline.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        XCTAssertTrue(tab.waitForExistence(timeout: 15),
                      "The file tab must exist before opening its outline")
        tab.rightClick()
        let outlineAction = app.menuItems["Outline…"]
        XCTAssertTrue(outlineAction.waitForExistence(timeout: 10))
        outlineAction.click()
        let destination = app.buttons["bailey.markdown.outline.topic-1"]
        XCTAssertTrue(destination.waitForExistence(timeout: 15),
                      "The native tab outline must distinguish repeated headings")
        let outlineScreenshot = XCTAttachment(screenshot: window.screenshot())
        outlineScreenshot.name = "Markdown native outline with duplicate headings"
        outlineScreenshot.lifetime = .keepAlways
        add(outlineScreenshot)
        destination.click()

        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let secondBody = preview.staticTexts["SECOND_TOPIC_BODY"].firstMatch
        guard secondBody.waitForExistence(timeout: 10) else {
            return XCTFail("Outline must reveal the selected section: \(preview.debugDescription)")
        }
        XCTAssertGreaterThan(secondBody.frame.intersection(preview.frame).height, 1,
                             "Outline selection must scroll to the requested repeated heading")

        let duplicate = preview.staticTexts.matching(identifier: "Topic").element(boundBy: 1)
        XCTAssertTrue(duplicate.waitForExistence(timeout: 10))
        duplicate.hover()
        let fold = preview.buttons["bailey.markdown.fold.topic-1"]
        XCTAssertTrue(fold.waitForExistence(timeout: 10))
        fold.click()
        XCTAssertEqual(fold.value as? String, "Collapsed")
        XCTAssertTrue(secondBody.waitForNonExistence(timeout: 10))
        XCTAssertFalse(preview.staticTexts["CHILD_BODY"].exists,
                       "A folded heading must also hide descendants")
        XCTAssertTrue(preview.staticTexts["TAIL_BODY"].waitForExistence(timeout: 10),
                      "The next top-level heading must stay visible")
        let foldedScreenshot = XCTAttachment(screenshot: window.screenshot())
        foldedScreenshot.name = "Markdown folded heading with following sections"
        foldedScreenshot.lifetime = .keepAlways
        add(foldedScreenshot)
        fold.click()
        XCTAssertEqual(fold.value as? String, "Expanded")
        XCTAssertTrue(secondBody.waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source,
                       "Folding and navigation must not edit or save source bytes")
    }

    func testAlternatingScrollBetweenCodeHeavyReaderAndSourcePreservesOriginalPositions() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = (0..<64).map { index -> String in
            let prose = "## Section \(index)\n\nParagraph 中文 🛰️ \(index) with **emphasis**."
            guard index.isMultiple(of: 4) else { return prose }
            return prose + "\n\n```swift\nlet number = \(index)\nprint(number)\n```"
        }.joined(separator: "\n\n")
        let file = try fixture.file("Alt.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        let preview = window.scrollViews.matching(identifier: "bailey.markdown.preview").firstMatch
        let first = window.descendants(matching: .any)
            .matching(identifier: "bailey.markdown.heading.section-0").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertEqual(first.label, "Section 0")
        XCTAssertGreaterThan(first.frame.intersection(preview.frame).height, 1)
        let sourceScroll = window.scrollViews.containing(.textView, identifier: nil).firstMatch
        XCTAssertTrue(sourceScroll.waitForExistence(timeout: 10))
        let bar = try XCTUnwrap(sourceScroll.scrollBars.allElementsBoundByIndex.first {
            $0.frame.height > $0.frame.width
        })
        func fraction() -> Double { Double(String(describing: bar.value ?? "")) ?? -1 }
        func awaitFraction(_ predicate: @escaping () -> Bool) -> Bool {
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in predicate() }, object: nil
            )], timeout: 8) == .completed
        }
        for _ in 0..<8 { preview.swipeUp() }
        XCTAssertTrue(awaitFraction { fraction() > 0.07 },
                      "Reader scrolling must move the actual native editor")
        for _ in 0..<12 { editor.swipeDown() }
        XCTAssertTrue(awaitFraction { fraction() < 0.04 },
                      "The source editor must scroll back to its beginning")
        XCTAssertTrue(awaitFraction {
            first.exists && first.frame.intersection(preview.frame).height > 1
        }, "Source scrolling back to the top must restore the first rendered heading")
        for _ in 0..<8 { editor.swipeUp() }
        XCTAssertTrue(awaitFraction { fraction() > 0.07 },
                      "Source scroll must continue to work after reader-driven scrolling")
        XCTAssertTrue(awaitFraction {
            !first.exists || first.frame.intersection(preview.frame).height < 1
        }, "The reader must follow source scroll after direction changes")
        for _ in 0..<12 { preview.swipeDown() }
        XCTAssertTrue(awaitFraction { fraction() < 0.04 },
                      "Reader must scroll the source back to top after alternating directions")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testSideBySideScrollTracksOriginalSourcePosition() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let source = (0..<60).map { index in
            "## Section \(index)\n\nParagraph \(index) with real selectable content and 中文 emoji 🛰️."
        }.joined(separator: "\n\n")
        let file = try fixture.file("Scroll.md", text: source)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        app.activate()
        row.doubleClick()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        tab.rightClick()
        let sideBySide = app.menuItems["Show Side by Side"]
        XCTAssertTrue(sideBySide.waitForExistence(timeout: 10))
        sideBySide.click()
        let preview = WorkspaceUITestSupport.element("bailey.markdown.preview", in: app)
        let first = markdownHeading("section-0", in: preview)
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(first.frame.intersection(preview.frame).height, 1)

        for _ in 0..<8 { editor.swipeUp() }
        let sourceDrivesPreview = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !first.exists || first.frame.intersection(preview.frame).height < 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sourceDrivesPreview], timeout: 5), .completed,
                       "Scrolling native TextKit source must move the companion preview to the same source block")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source,
                       "Navigation must never save the buffer or alter the original bytes")
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
