import XCTest
@testable import Bailey

@MainActor
final class SwiftMarkdownSelectionTests: XCTestCase {
    func testFootnoteDefinitionBeforeTrailingBodyKeepsEverySourceRange() async throws {
        let source = """
            # Footnote selection

            FIRST_BLOCK with a reference[^note].

            [^note]: Definition text.

            FINAL_TAIL_VISIBLE after the footnote definition.
            """
        let document = try await MarkdownDocument.parse(source)
        let spans = document.blocks.map { "\($0.line): \(String(describing: $0.sourceRange))" }
            .joined(separator: "; ")
        let range = try XCTUnwrap(MarkdownSelectionText.fullRange(in: document))
        let tail = (source as NSString).range(of: "FINAL_TAIL_VISIBLE")
        XCTAssertGreaterThan(NSMaxRange(range), NSMaxRange(tail),
                             "Select All must use the union of original block ranges")
        let copied = MarkdownSelectionText.copy(range, from: document)
        XCTAssertTrue(copied.contains("FIRST_BLOCK")
                      && copied.contains("Definition text.")
                      && copied.contains("FINAL_TAIL_VISIBLE"),
                      "All rendered blocks must have original source ranges: \(spans) / \(copied)")
    }

    func testCollapsedHeadingExcludesHiddenBodyFromReaderSelectAllAndCopy() async throws {
        let source = """
            # Outline

            BEGIN_VISIBLE

            ## Folded

            SECRET_TEXT_NOT_VISIBLE

            ### Child

            CHILD_TEXT_NOT_VISIBLE

            ## Kept

            END_VISIBLE
            """
        let document = try await MarkdownDocument.parse(source)
        let heading = try XCTUnwrap(document.headingOutline.first { $0.anchor == "folded" })
        let collapsed: Set<MarkdownDocument.HeadingIdentity> = [heading.identity]
        let visibleRange = try XCTUnwrap(MarkdownSelectionText.fullRange(
            in: document, collapsed: collapsed
        ))
        let copied = MarkdownSelectionText.copy(visibleRange, from: document, collapsed: collapsed)
        XCTAssertTrue(copied.contains("BEGIN_VISIBLE") && copied.contains("END_VISIBLE"), copied)
        XCTAssertTrue(copied.contains("Folded"), copied)
        XCTAssertFalse(copied.contains("SECRET_TEXT_NOT_VISIBLE"), copied)
        XCTAssertFalse(copied.contains("CHILD_TEXT_NOT_VISIBLE"), copied)
        let original = MarkdownSelectionText.copy(visibleRange, from: document)
        XCTAssertTrue(original.contains("SECRET_TEXT_NOT_VISIBLE"))
    }

    func testDetailsToggleChangesCopyAndKeepsOriginalDocument() async throws {
        let source = "<details><summary>Read more</summary><p>Secret body</p></details>"
        let document = try await MarkdownDocument.parse(source)
        let range = try XCTUnwrap(document.blocks.first?.sourceRange)
        let key = MarkdownHTML.detailKey([0, 0])
        XCTAssertEqual(MarkdownSelectionText.copy(range, from: document), "Read more")
        XCTAssertTrue(MarkdownSelectionText.copy(range, from: document,
                                                details: [key: true]).contains("Secret body"))
        XCTAssertEqual(MarkdownSelectionText.copy(range, from: document,
                                                 details: [key: false]), "Read more")
    }

    func testRepeatedDetailsHaveIndependentCopyVisibility() async throws {
        let source = """
            <details><summary>First</summary><p>FIRST_SECRET</p></details>
            <details><summary>Second</summary><p>SECOND_SECRET</p></details>
            """
        let document = try await MarkdownDocument.parse(source)
        let copiedRange = NSRange(location: 0, length: source.utf16.count)
        let baseline = MarkdownSelectionText.copy(copiedRange, from: document)
        XCTAssertFalse(baseline.contains("FIRST_SECRET") || baseline.contains("SECOND_SECRET"))
        let expanded = MarkdownSelectionText.copy(copiedRange, from: document,
                                                 details: [MarkdownHTML.detailKey([0, 0]): true])
        XCTAssertTrue(expanded.contains("FIRST_SECRET"), expanded)
        XCTAssertFalse(expanded.contains("SECOND_SECRET"), expanded)
    }

    func testClosedHTMLDetailsCopiesOnlyVisibleSummary() async throws {
        let source = "<details><summary>Read more</summary><p>SECRET content</p></details>"
        let document = try await MarkdownDocument.parse(source)
        let first = try XCTUnwrap(document.blocks.first?.sourceRange)
        XCTAssertEqual(MarkdownSelectionText.copy(first, from: document), "Read more",
                       "Collapsed details must not copy their invisible body")
    }

    func testExpandedHTMLDetailsCopiesSummaryAndVisibleBody() async throws {
        let source = "<details open><summary>Read more</summary><p>Visible content</p></details>"
        let document = try await MarkdownDocument.parse(source)
        let first = try XCTUnwrap(document.blocks.first?.sourceRange)
        XCTAssertTrue(MarkdownSelectionText.copy(first, from: document).contains("Read more"))
        XCTAssertTrue(MarkdownSelectionText.copy(first, from: document).contains("Visible content"))
    }

    func testTwoThousandTaskListItemsCopyWithoutTruncation() async throws {
        let source = (0..<2_000).map { index in
            "- [\(index.isMultiple(of: 2) ? "x" : " ")] Task \(index) 中文 🛰️"
        }.joined(separator: "\n")
        let document = try await MarkdownDocument.parse(source)
        let copied = MarkdownSelectionText.copy(
            NSRange(location: 0, length: source.utf16.count), from: document
        )
        XCTAssertEqual(copied, source)
    }

    func testCheckedAndNestedListsRetainTheirVisibleHierarchy() async throws {
        let source = "- [x] Complete\n- [ ] Pending\n  - Child line\n"
        let document = try await MarkdownDocument.parse(source)
        let first = try XCTUnwrap(document.blocks.first?.sourceRange)
        XCTAssertEqual(MarkdownSelectionText.copy(first, from: document),
                       "- [x] Complete\n- [ ] Pending\n  - Child line")
    }

    func testInlineHTMLCopyMatchesRenderedTagsAndLineBreaks() async throws {
        let source = "Before <strong>Bold</strong> and <br> after <em>italic</em>."
        let document = try await MarkdownDocument.parse(source)
        let paragraph = try XCTUnwrap(document.blocks.first?.sourceRange)
        XCTAssertEqual(MarkdownSelectionText.copy(paragraph, from: document),
                       "Before Bold and \n after italic.")
    }

    func testNestedCodeBlockPreservesVisibleLinesAndOriginalCoordinates() async throws {
        let source = "> ```swift\n> alpha\n> beta 中文\n> ```\n"
        let document = try await MarkdownDocument.parse(source)
        guard case .quote(let blocks) = document.blocks.first?.content,
              case .code(let displayed, _, let runs) = blocks.first else {
            return XCTFail("Expected nested fenced code in a block quote")
        }
        XCTAssertTrue(displayed.contains("beta 中文"))
        let actual = (source as NSString).range(of: "beta 中文")
        XCTAssertTrue(runs.contains(where: { $0.original == actual }),
                      "Nested markup prefixes must not corrupt code line source positions")
        let copied = MarkdownSelectionText.copy(actual, from: document)
        XCTAssertEqual(copied, "beta 中文")
    }

    func testFencedCodeSecondLineMapsToOriginalContentNotFence() async throws {
        let source = "# Header\r\n\r\n```swift\r\nfirst 🛰️\r\nsecond 中文\r\n```\r\n\r\nAFTER_CODE destination."
        let document = try await MarkdownDocument.parse(source)
        let original = source as NSString
        let code = try XCTUnwrap(document.blocks.first {
            if case .code = $0.content { return true }
            return false
        })
        guard case .code(let visible, let language, let runs) = code.content else {
            return XCTFail("Expected native fenced code")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(visible.contains("first 🛰️") && visible.contains("second 中文"))
        let expected = original.range(of: "second 中文")
        let mapped = runs.first { run in
            (visible as NSString).substring(with: run.displayed).contains("second 中文")
        }
        XCTAssertEqual(mapped?.original, expected,
                       "A code line must map to its original UTF-16 coordinates after CRLF and emoji")
        let final = original.range(of: "AFTER_CODE")
        let selection = NSRange(location: expected.location,
                                length: NSMaxRange(final) - expected.location)
        let copied = MarkdownSelectionText.copy(selection, from: document)
        XCTAssertTrue(copied.contains("second 中文") && copied.contains("AFTER_CODE"), copied)
        XCTAssertFalse(copied.contains("first 🛰️") || copied.contains("```"), copied)
    }

    func testIndentedCodeRemovesStructuralIndentFromVisibleMapping() async throws {
        let source = "    first line\n    second line\n\nafter code"
        let document = try await MarkdownDocument.parse(source)
        guard case .code(let visible, _, let runs) = document.blocks.first?.content else {
            return XCTFail("Expected indented code")
        }
        let expected = (source as NSString).range(of: "second line")
        XCTAssertTrue(visible.contains("second line"))
        XCTAssertTrue(runs.contains(where: { $0.original == expected }))
        let second = NSRange(location: expected.location, length: expected.length)
        XCTAssertEqual(MarkdownSelectionText.copy(second, from: document), "second line")
    }

    func testPartialUTF16SelectionCopiesWholeEmojiAndCombiningGraphemes() async throws {
        let source = "one 🛰️ two 👩‍🚀 and e\u{301}."
        let document = try await MarkdownDocument.parse(source)
        let original = source as NSString
        for grapheme in ["🛰️", "👩‍🚀", "e\u{301}"] {
            let span = original.range(of: grapheme)
            XCTAssertNotEqual(span.location, NSNotFound)
            let partial = NSRange(location: span.location + 1, length: 1)
            XCTAssertEqual(MarkdownSelectionText.copy(partial, from: document), grapheme,
                           "Copying one UTF-16 code unit must not split a rendered grapheme")
        }
    }

    func testCopyRendersEscapedMarkdownAndEntitiesWithoutTheirMarkup() async throws {
        let source = "Before \\*star\\* &amp; after"
        let document = try await MarkdownDocument.parse(source)
        let paragraph = try XCTUnwrap(document.blocks.first?.sourceRange)
        XCTAssertEqual(MarkdownSelectionText.copy(paragraph, from: document),
                       "Before *star* & after")
    }

    func testCopyAcrossStructuresExcludesMarkdownDelimiters() async throws {
        let source = """
            # Heading

            > **Quote** text

            - First
            - Second

            | Key | Value |
            | --- | ----- |
            | A | B |

            ```swift
            let value = 42
            ```
            """
        let document = try await MarkdownDocument.parse(source)
        XCTAssertGreaterThanOrEqual(document.blocks.count, 4)
        let first = try XCTUnwrap(document.blocks.first?.sourceRange)
        let last = try XCTUnwrap(document.blocks.last?.sourceRange)
        let all = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let copied = MarkdownSelectionText.copy(all, from: document)
        XCTAssertTrue(copied.contains("Heading") && copied.contains("Quote text")
                      && copied.contains("- First\n- Second")
                      && copied.contains("Key\tValue\nA\tB")
                      && copied.contains("let value = 42"), copied)
        XCTAssertFalse(copied.contains("**") || copied.contains("```")
                       || copied.contains("| ---"), copied)
    }
}
