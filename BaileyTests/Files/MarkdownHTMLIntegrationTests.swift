import Foundation
import XCTest
@testable import Bailey

@MainActor
final class MarkdownHTMLIntegrationTests: XCTestCase {
    func testInlineHTMLLinkWithinMarkdownParagraphUsesNativeLink() async throws {
        let document = try await MarkdownDocument.parse("Before <a href='Guide.md'>the guide</a> after.")
        let links = document.blocks.flatMap { block -> [URL] in
            switch block.content {
            case .markdown(let text): return text.runs.compactMap(\.link)
            case .html(let nodes): return nodes.compactMap { node in
                if case .link(let url, _) = node { return url }
                return nil
            }
            case .mermaid: return []
            }
        }
        XCTAssertTrue(links.contains { $0.relativeString == "Guide.md" },
                      "A Markdown paragraph containing inline HTML must preserve a clickable link")
        let plain = document.blocks.compactMap { block -> String? in
            if case .markdown(let text) = block.content { return String(text.characters) }
            return nil
        }.joined()
        XCTAssertEqual(plain, "Before the guide after.")
    }

    func testInlineHTMLStrongWithinMarkdownParagraphKeepsEmphasis() async throws {
        let document = try await MarkdownDocument.parse("Before <strong>important</strong> after.")
        let raw = document.blocks.compactMap { block -> AttributedString? in
            guard case .markdown(let text) = block.content else { return nil }
            return text
        }
        XCTAssertFalse(raw.contains { String($0.characters).contains("<strong>") },
                       "A supported HTML element within ordinary Markdown must not appear as a literal tag")
        XCTAssertTrue(raw.contains { text in
            text.runs.contains { run in
                String(text[run.range].characters) == "important"
                    && run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            }
        })
    }

    func testNestedNativeHTMLAndMarkdownFormattingPreserveOneParagraph() async throws {
        let document = try await MarkdownDocument.parse("Before **Markdown** <a href='Guide.md'><strong>Guide</strong></a> and <em>HTML</em> after.")
        guard let first = document.blocks.first, case .markdown(let text) = first.content else {
            return XCTFail("Inline HTML belongs to the same Markdown paragraph")
        }
        XCTAssertEqual(String(text.characters), "Before Markdown Guide and HTML after.")
        let attributes = text.runs.map { run in
            (String(text[run.range].characters), run.inlinePresentationIntent, run.link)
        }
        XCTAssertTrue(attributes.contains { text, intent, _ in
            text == "Markdown" && intent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertTrue(attributes.contains { text, intent, link in
            text == "Guide" && intent?.contains(.stronglyEmphasized) == true
                && link?.relativeString == "Guide.md"
        })
        XCTAssertTrue(attributes.contains { text, intent, _ in
            text == "HTML" && intent?.contains(.emphasized) == true
        })
    }

    func testInlineHTMLRejectsUnsafeLinksWithoutHidingText() async throws {
        for scheme in ["javascript:alert(1)", "file:///etc/hosts"] {
            let source = "Before <a href='\(scheme)'>click</a> after."
            let document = try await MarkdownDocument.parse(source)
            guard let first = document.blocks.first, case .markdown(let text) = first.content else {
                return XCTFail("Missing paragraph")
            }
            XCTAssertEqual(String(text.characters), "Before click after.")
            XCTAssertFalse(text.runs.contains { $0.link != nil })
        }
    }

    func testInlineHTMLLeavesInvalidTagsAndCodeUntouched() async throws {
        let document = try await MarkdownDocument.parse("Before <strong>unclosed and `<a href='Guide.md'>` after.")
        let raw = document.blocks.compactMap { block -> AttributedString? in
            guard case .markdown(let text) = block.content else { return nil }
            return text
        }
        let text = raw.map { String($0.characters) }.joined()
        XCTAssertTrue(text.contains("<strong>"), "Unclosed markup should not silently disappear")
        XCTAssertTrue(text.contains("<a href='Guide.md'>"), "Literal code must remain literal")
        XCTAssertFalse(raw.contains { $0.runs.contains { $0.link != nil } })
    }

    func testHTMLParagraphImagesReachNativeImageNodesInFullDocument() async throws {
        let document = try await MarkdownDocument.parse("""
            # Sized images

            <p><img src="badge.svg" alt="Small badge" width="48" height="32"></p>

            <p><img src="badge.svg" alt="Natural badge"></p>
            """)
        var images: [(URL, String, Int?, Int?)] = []
        func scan(_ nodes: [MarkdownHTML]) {
            for node in nodes {
                switch node {
                case .image(let url, let alt, let width, let height):
                    images.append((url, alt, width, height))
                case .paragraph(let children), .quote(let children),
                     .emphasis(let children, _), .link(_, let children), .heading(_, let children):
                    scan(children)
                default: break
                }
            }
        }
        for block in document.blocks {
            if case .html(let nodes) = block.content { scan(nodes) }
        }
        XCTAssertEqual(images.count, 2, "The Markdown document should preserve HTML images as native nodes")
        if images.count == 2 {
            XCTAssertEqual(images[0].1, "Small badge")
            XCTAssertEqual(images[0].2, 48)
            XCTAssertEqual(images[0].3, 32)
            XCTAssertNil(images[1].2)
        }
    }

    func testInlineHTMLInsideHeadingListAndQuoteRetainsSemantics() async throws {
        let document = try await MarkdownDocument.parse("""
            # Before <em>Important</em> Now

            - Item <a href="Guide.md">Guide</a>
            - Item <strong>Bold</strong>

            > Quote <em>Point</em>.
            """)
        XCTAssertEqual(document.blocks.first?.anchor, "before-important-now",
                       "Heading links should use visible text, not raw HTML tag names")
        let text = document.blocks.compactMap { block -> AttributedString? in
            if case .markdown(let markup) = block.content { return markup }
            return nil
        }
        let body = text.map { String($0.characters) }.joined(separator: "\n")
        XCTAssertFalse(body.contains("<em>"), body)
        XCTAssertFalse(body.contains("<strong>"), body)
        XCTAssertFalse(body.contains("<a "), body)
        XCTAssertTrue(text.contains { markup in
            markup.runs.contains { $0.link?.relativeString == "Guide.md" }
        })
    }

    func testInlineHTMLLineBreakAndStandaloneSpan() async throws {
        let document = try await MarkdownDocument.parse("<span>First</span><br>Second")
        guard let first = document.blocks.first, case .markdown(let text) = first.content else {
            return XCTFail("Inline markup should retain Markdown semantics")
        }
        XCTAssertEqual(String(text.characters), "First\nSecond")
    }
}
