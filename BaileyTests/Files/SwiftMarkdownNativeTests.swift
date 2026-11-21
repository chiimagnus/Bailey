import AppKit
import Foundation
import XCTest
@testable import Bailey

@MainActor
final class SwiftMarkdownNativeTests: XCTestCase {
    func testGFMAndNestedContentRetainStructure() async throws {
        let source = """
        # Heading **emphasis**
        ## Heading **emphasis**

        The **strong**, *italic*, ~~struck~~ and [linked](Guide.md) text.

        - [x] Done
        - [ ] Open
          - Child

        4. First
        5. Second

        > A quoted **word**.

        | Left | Right |
        | :--- | ---: |
        | **Bold** | Value |

        ---
        """
        let document = try await MarkdownDocument.parse(source)
        XCTAssertEqual(document.blocks.count, 8)
        XCTAssertEqual(document.blocks[0].anchor, "heading-emphasis")
        XCTAssertEqual(document.blocks[1].anchor, "heading-emphasis-1")

        guard case let .paragraph(inline) = document.blocks[2].content else {
            return XCTFail("Expected paragraph node")
        }
        XCTAssertTrue(inline.contains { if case .strong = $0 { true } else { false } })
        XCTAssertTrue(inline.contains { if case .emphasis = $0 { true } else { false } })
        XCTAssertTrue(inline.contains { if case .strike = $0 { true } else { false } })
        XCTAssertTrue(inline.contains {
            if case .link("Guide.md", _) = $0 { true } else { false }
        })

        guard case let .list(ordered: false, start: _, items) = document.blocks[3].content else {
            return XCTFail("Expected task list")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].checked, true)
        XCTAssertEqual(items[1].checked, false)
        XCTAssertTrue(items[1].blocks.contains {
            if case .list = $0 { true } else { false }
        })

        guard case let .list(ordered: true, start: start, items: ordered) = document.blocks[4].content else {
            return XCTFail("Expected ordered list")
        }
        XCTAssertEqual(start, 4)
        XCTAssertEqual(ordered.count, 2)

        guard case let .quote(blocks) = document.blocks[5].content else {
            return XCTFail("Expected block quote")
        }
        XCTAssertFalse(blocks.isEmpty)

        guard case let .table(head, rows, alignments) = document.blocks[6].content else {
            return XCTFail("Expected GFM table")
        }
        XCTAssertEqual(head.count, 2)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].count, 2)
        guard case .leading = alignments[0], case .trailing = alignments[1] else {
            return XCTFail("Table alignment not preserved")
        }
        guard case .rule = document.blocks[7].content else {
            return XCTFail("Expected thematic break")
        }
    }

    func testNestedStyledLinkPreservesInlineAttributes() async throws {
        let document = try await MarkdownDocument.parse(
            "[**粗体** *斜体* ~~删除~~](docs/guide.md)"
        )
        guard case let .paragraph(inline) = document.blocks.first?.content else {
            return XCTFail("Expected linked paragraph")
        }
        let attributed = MarkdownNativeText.attributed(inline)
        XCTAssertEqual(String(attributed.characters), "粗体 斜体 删除")
        for (substring, style) in [
            ("粗体", InlinePresentationIntent.stronglyEmphasized),
            ("斜体", .emphasized),
            ("删除", .strikethrough),
        ] {
            guard let run = attributed.runs.first(where: {
                String(attributed[$0.range].characters).contains(substring)
            }) else {
                return XCTFail("Missing styled text: \(substring)")
            }
            XCTAssertTrue(run.inlinePresentationIntent?.contains(style) == true,
                          "Lost \(style) inside Markdown link")
            XCTAssertEqual(run.link?.relativeString, "docs/guide.md")
        }
    }

    func testInlineCodeHasMutedBackgroundInsideAndOutsideLinks() async throws {
        let document = try await MarkdownDocument.parse(
            "Plain `code` and [**bold** `linked`](docs/guide.md)."
        )
        guard case let .paragraph(inline) = document.blocks.first?.content else {
            return XCTFail("Expected a paragraph")
        }
        let rendered = MarkdownNativeText.attributed(inline)
        let codeRuns = rendered.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(codeRuns.count, 2)
        for run in codeRuns {
            XCTAssertNotNil(run.backgroundColor, "GitHub inline code needs a muted background")
        }
        XCTAssertEqual(codeRuns.last?.link?.relativeString, "docs/guide.md")
    }

    func testInlineImageRetainsSourceAndUnicodeParagraphText() async throws {
        let document = try await MarkdownDocument.parse(
            "前文 before ![示意图](assets/plot%20one.svg) 后文 after, with [reference](docs/a.md)."
        )
        guard document.blocks.count == 1,
              case let .paragraph(inlines) = document.blocks[0].content else {
            return XCTFail("Mixed image and prose must share one Markdown paragraph")
        }
        XCTAssertTrue(inlines.contains { if case .text(let text) = $0 { text.contains("前文 before") } else { false } })
        XCTAssertTrue(inlines.contains { if case .image("assets/plot%20one.svg", "示意图") = $0 { true } else { false } })
        XCTAssertTrue(inlines.contains { if case .text(let text) = $0 { text.contains("后文 after") } else { false } })
        XCTAssertTrue(inlines.contains { if case .link("docs/a.md", _) = $0 { true } else { false } })
    }

    func testFencedCodeUsesExistingNativeSyntaxHighlighting() async throws {
        let source = "let answer = 42\nprint(answer)"
        guard let highlighted = await MarkdownCodeText.highlight(source, language: "swift") else {
            return XCTFail("Existing Swift grammar must provide highlighting")
        }
        XCTAssertEqual(String(highlighted.characters), source)
        let rendered = NSAttributedString(highlighted)
        var colored = false
        rendered.enumerateAttribute(.foregroundColor,
                                    in: NSRange(location: 0, length: rendered.length)) { attribute, _, _ in
            if attribute is NSColor { colored = true }
        }
        XCTAssertTrue(colored, "Visible code syntax must actually have token colors")
        let fallback = await MarkdownCodeText.highlight(source, language: "not-a-language")
        XCTAssertNil(fallback, "Unknown language must preserve plain code")
        let oversized = await MarkdownCodeText.highlight(String(repeating: "x", count: 1_048_577),
                                                         language: "swift")
        XCTAssertNil(oversized, "Very large code blocks must not monopolize syntax parsing")
    }

    func testNativeMathProjectionExcludesCodeAndEscapedDollars() async throws {
        let tick = String(Character(UnicodeScalar(96)!))
        let fence = String(repeating: tick, count: 3)
        let source = [
            "Inline formula $E=mc^2$ and currency \\$5, then another $a+b$.",
            "",
            "$$\\frac{1}{2} + \\sqrt{2}$$",
            "",
            "$$",
            "\\sum_{i=1}^{n} x_i",
            "$$",
            "",
            fence + "text",
            "$must_not_render$",
            fence,
            "",
            "Literal code " + tick + "$x$" + tick + " and an unclosed $oops.",
        ].joined(separator: "\n")
        let document = try await MarkdownDocument.parse(source)
        XCTAssertGreaterThanOrEqual(document.blocks.count, 5)
        guard case let .paragraph(inline) = document.blocks[0].content else {
            return XCTFail("Expected formula paragraph")
        }
        let expressions = inline.compactMap { node -> String? in
            guard case let .math(latex, display: false) = node else { return nil }
            return latex
        }
        XCTAssertEqual(expressions, ["E=mc^2", "a+b"])
        XCTAssertTrue(String(describing: inline).contains("$5"),
                      "Escaped currency must not turn into a math expression")
        guard case let .mathBlock(first) = document.blocks[1].content else {
            return XCTFail("Expected same-line display math block: \(document.blocks[1].content)")
        }
        XCTAssertTrue(first.contains("\\frac"))
        guard case let .mathBlock(second) = document.blocks[2].content else {
            return XCTFail("Expected multiline display math block: \(document.blocks[2].content)")
        }
        XCTAssertTrue(second.contains("\\sum"))
        XCTAssertTrue(document.blocks.contains {
            if case let .code(code, _) = $0.content { code.contains("$must_not_render$") }
            else { false }
        })
    }

    func testMathWithMarkdownDelimitersStillTypesetsWholeExpression() async throws {
        for formula in [
            "$x*y*z$",
            "$a_{i} + b_{j}$",
            "$\\frac{a_b}{\\sqrt{x}}$",
            "$\\mathbf{x}^T$",
        ] {
            let source = "Prose before " + formula + " and after."
            let document = try await MarkdownDocument.parse(source)
            guard case let .paragraph(inline) = document.blocks.first?.content else {
                return XCTFail("Missing paragraph for \(formula)")
            }
            let expressions = inline.compactMap { node -> String? in
                if case let .math(latex, display: false) = node { latex } else { nil }
            }
            XCTAssertEqual(expressions, [String(formula.dropFirst().dropLast())],
                           "Math extension must not let GFM emphasis split TeX: \(inline)")
        }
    }

    func testMathTokenizationHonorsSourceEscapesAndDoesNotInventFormulae() async throws {
        let document = try await MarkdownDocument.parse("escaped \\$x\\$ and $y$")
        guard case let .paragraph(inline) = document.blocks.first?.content else {
            return XCTFail("Missing escaped-dollar paragraph")
        }
        let expressions = inline.compactMap { node -> String? in
            if case let .math(latex, _) = node { latex } else { nil }
        }
        XCTAssertEqual(expressions, ["y"])
        XCTAssertTrue(String(describing: inline).contains("$x$"))
        for source in ["unclosed $x", "cost $5", "\\$escaped"] {
            let document = try await MarkdownDocument.parse(source)
            guard case let .paragraph(inline) = document.blocks.first?.content else {
                return XCTFail("Missing literal paragraph")
            }
            XCTAssertFalse(inline.contains { if case .math = $0 { true } else { false } },
                           "Unexpected formula from \(source)")
        }
    }

    func testMathInGFMTableCellUsesNativeFormulaNode() async throws {
        let source = "| Name | Equation |\n| --- | --- |\n| x | $x_i*y_j$ |"
        let document = try await MarkdownDocument.parse(source)
        guard case let .table(_, rows, _) = document.blocks.first?.content else {
            return XCTFail("Expected GFM table")
        }
        XCTAssertEqual(rows.count, 1)
        guard let cell = rows.first?.last else { return XCTFail("Missing formula cell") }
        XCTAssertTrue(cell.contains {
            if case let .math(latex, _) = $0 { latex == "x_i*y_j" } else { false }
        }, "Math in GFM table must not be swallowed by inline emphasis: \(cell)")
    }

    func testFencedCodeLanguageAndLiteralUnsafeText() async throws {
        let fence4 = String(repeating: "\u{60}", count: 4)
        let fence3 = String(repeating: "\u{60}", count: 3)
        let source = [
            fence4 + "swift", "let literal = " + String(reflecting: fence3),
            "<script>must not run</script>", fence4, "",
            fence3 + "mermaid", "flowchart TD", "  Start --> Done", fence3,
        ].joined(separator: "\n")
        let doc = try await MarkdownDocument.parse(source)
        XCTAssertEqual(doc.blocks.count, 2)
        guard case let .code(code, language) = doc.blocks[0].content else {
            return XCTFail("Missing code fence")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(code.contains("let literal"))
        XCTAssertTrue(code.contains("<script>must not run</script>"))
        guard case let .mermaid(source, line) = doc.blocks[1].content else {
            return XCTFail("Missing Mermaid source node")
        }
        XCTAssertTrue(source.contains("Start --> Done"))
        XCTAssertGreaterThan(line, 1)
    }

    func testFrontMatterWithBOMAndInvalidHeaderIsNondestructive() async throws {
        let source = "\u{FEFF}---\r\nname: Example\r\ndescription: |\r\n  First line\r\n  Second line\r\n---\r\n# Body\r\n"
        let document = try await MarkdownDocument.parse(source)
        XCTAssertEqual(document.properties.first(where: { $0.name == "name" })?.value, "Example")
        XCTAssertTrue(document.properties.contains { $0.name == "description" && $0.value.contains("First line") })
        XCTAssertNil(document.warning)
        guard case .heading = document.blocks.first?.content else {
            return XCTFail("Front matter must not display as horizontal rule")
        }
        XCTAssertEqual(document.blocks.first?.line, 7)

        let unclosed = try await MarkdownDocument.parse("---\nname: broken\nNo ending marker")
        XCTAssertNotNil(unclosed.warning)
        XCTAssertTrue(unclosed.blocks.count > 0)

        let nonLeading = try await MarkdownDocument.parse("# Heading\n\n---\nname: value\n---")
        XCTAssertEqual(nonLeading.properties.count, 0)

        let oversized = "---\nname: " + String(repeating: "b", count: 65536) + "\n---\n# Body"
        let oversizedDocument = try await MarkdownDocument.parse(oversized)
        XCTAssertNotNil(oversizedDocument.warning)
    }

    func testMarkdownFormatsAndHTMLNeverExecute() async throws {
        for extensionName in ["md", "markdown", "mdx", "MDX"] {
            XCTAssertTrue(MarkdownDocument.supports("/repo/README.\(extensionName)"))
        }
        XCTAssertFalse(MarkdownDocument.supports("/repo/main.swift"))

        let source = """
        Before <strong>bold</strong> after.

        <div><p>Inner <em>emphasis</em></p>
        <script>alert("danger")</script></div>

        import Chart from "./Chart"

        <Chart data={values} />
        {score + 1}
        """
        let document = try await MarkdownDocument.parse(source)
        XCTAssertTrue(document.blocks.contains {
            if case .html = $0.content { return true }
            return false
        })
        // Neither the parser nor renderer may turn MDX into executable components.
        let renderText = document.blocks.map(describe).joined(separator: "\n")
        XCTAssertTrue(renderText.contains("Chart"))
        XCTAssertTrue(renderText.contains("score + 1"))
    }

    func testSameLineHTMLContainersBecomeNativeBlocks() async throws {
        let cases = [
            "<details><summary>Notes</summary><p>Editable content</p></details>",
            "<p><img src=\"badge.svg\" alt=\"Small badge\" width=\"48\" height=\"32\"></p>",
            "<img src=\"badge.svg\" alt=\"Responsive badge\">",
        ]
        for html in cases {
            let document = try await MarkdownDocument.parse("# Heading\n\n" + html + "\n")
            guard document.blocks.count == 2 else {
                return XCTFail("Unexpected block count: \(document.blocks.count)")
            }
            guard case let .html(nodes) = document.blocks[1].content else {
                return XCTFail("Expected native HTML for \(html), got \(document.blocks[1].content)")
            }
            XCTAssertFalse(nodes.isEmpty)
            if html.hasPrefix("<details>") {
                XCTAssertTrue(nodes.contains {
                    if case .details = $0 { return true }; return false
                }, "A closed HTML details must become a native control: \(nodes)")
            } else {
                XCTAssertTrue(nodes.contains { node in
                    if case .image = node { return true }
                    if case .paragraph(let children) = node {
                        return children.contains { if case .image = $0 { return true }; return false }
                    }
                    return false
                }, "HTML image must reach native image view: \(nodes)")
            }
        }
    }

    func testStandaloneInlineAudioUsesNativeMediaInsteadOfRawHTML() async throws {
        let source = "# Audio\n\n<audio controls src=\"sound.wav\" autoplay loop></audio>\n"
        let document = try await MarkdownDocument.parse(source)
        XCTAssertEqual(document.blocks.count, 2)
        guard case let .html(nodes) = document.blocks[1].content,
              case let .media(url, video) = nodes.first else {
            return XCTFail("Expected native audio from inline HTML, got \(document.blocks[1].content)")
        }
        XCTAssertFalse(video)
        XCTAssertEqual(url.relativeString, "sound.wav")
    }

    func testHTMLAndSVGStayNativeWithoutExecutingScripts() async throws {
        let html = MarkdownHTML.parse("""
            <p><img src="logo.svg" alt="Logo" width="40" height="24"></p>
            <details open><summary>Details</summary><strong>Safe</strong></details>
            <script>fetch("https://example.invalid")</script>
            """)
        XCTAssertNotNil(html)
        XCTAssertTrue(containsImageOrDetails(try XCTUnwrap(html)))

        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="10">
          <rect width="20" height="10" fill="#f00" onclick="alert(1)" />
          <script>alert(1)</script>
        </svg>
        """
        let image = try MarkdownSVG.render(Data(svg.utf8))
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 20)
        XCTAssertThrowsError(try MarkdownSVG.render(Data("<!DOCTYPE svg><svg/>".utf8)))
    }

    func testRelativeImagesCannotFetchOutsideProject() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temporary.appendingPathComponent("repo")
        let assets = root.appendingPathComponent("assets")
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let safe = assets.appendingPathComponent("image.bin")
        try Data("safe".utf8).write(to: safe)
        try Data("secret".utf8).write(to: temporary.appendingPathComponent("secret"))
        try FileManager.default.createSymbolicLink(at: assets.appendingPathComponent("escape"),
                                                     withDestinationURL: temporary.appendingPathComponent("secret"))
        let resource = MarkdownResource(path: docs.appendingPathComponent("README.md").path,
                                        directory: root.path, backend: LocalWorkspaceBackend.shared)
        let approved = try await resource.read(try XCTUnwrap(URL(string: "../assets/image.bin")), maxBytes: 100)
        XCTAssertEqual(approved, Data("safe".utf8))
        for string in ["../../secret", "../assets/escape", "file:///etc/passwd",
                       "https://example.invalid/a.png", "javascript:alert(1)"] {
            do {
                _ = try await resource.read(try XCTUnwrap(URL(string: string)), maxBytes: 100)
                XCTFail("Forbidden resource read succeeded for \(string)")
            } catch {
                // Expected authorization rejection, not an empty successful read.
            }
        }
    }


    func testInvalidClosedFrontMatterRemainsVisible() async throws {
        let source = "---\nname: [invalid\n---\n# Main content"
        let document = try await MarkdownDocument.parse(source)
        XCTAssertNotNil(document.warning)
        let visible = String(describing: document.blocks.map(\.content))
        XCTAssertTrue(visible.contains("name: [invalid"),
                      "Malformed YAML must not silently discard user source in preview: \(visible)")
        XCTAssertTrue(visible.contains("Main content"))
    }

    func testFootnotesUseSuperscriptReferencesAndSeparatedDefinitionArea() async throws {
        let source = "Read this[^note] and another reference[^note].\n\n[^note]: A **rich** note."
        let document = try await MarkdownDocument.parse(source)
        guard case let .paragraph(inline) = document.blocks.first?.content else {
            return XCTFail("Expected paragraph containing footnotes")
        }
        let rendered = MarkdownNativeText.attributed(inline)
        let references = rendered.runs.filter {
            $0.link?.fragment == "bailey-note:note"
        }
        XCTAssertEqual(references.count, 2)
        for ref in references {
            XCTAssertGreaterThan(ref.baselineOffset ?? 0, 2,
                                 "GitHub-style footnote references must be superscript")
        }
        let regular = MarkdownNativeText.attributed([.link("#bailey-note:note", [.text("See note")])])
        XCTAssertNil(regular.runs.first?.baselineOffset,
                     "An explicit Markdown link to the note must remain normal link text")
        let index = try XCTUnwrap(document.blocks.firstIndex {
            $0.anchor == "bailey-note:note"
        })
        XCTAssertGreaterThan(index, 0)
        if case .rule = document.blocks[index - 1].content {
            // Footnote section is visually separated from article content.
        } else {
            XCTFail("Footnotes must start after the native section separator")
        }
        guard case let .paragraph(definition) = document.blocks[index].content,
              case .text("1. ") = definition.first else {
            return XCTFail("The footnote definition must use GitHub's ordered-list number")
        }
        XCTAssertTrue(definition.contains {
            if case .strong = $0 { return true }
            return false
        }, "Footnote definition must retain bold Markdown syntax rather than literal **")
    }

    func testFootnotesDoNotLinkEscapedReferences() async throws {
        let source = "A real[^same] and escaped \\[^same], with code `[^same]`.\n\n[^same]: Note"
        let document = try await MarkdownDocument.parse(source)
        guard case let .paragraph(inline) = document.blocks.first?.content else {
            return XCTFail("Expected a paragraph")
        }
        let links = inline.filter { if case .link("#bailey-note:same", _) = $0 { true } else { false } }
        XCTAssertEqual(links.count, 1, "Only the unescaped reference is a footnote")
        XCTAssertTrue(String(describing: inline).contains("[^same]"),
                      "Escaped reference must remain visible as literal text")
    }

    func testFootnotesResolveReferencesAndKeepCodeLiteral() async throws {
        let source = """
            Paragraph has a note[^ref] and the same note[^ref], then another[^second].

            [^second]: Another *formatted* note.
            [^ref]: Referenced **note**.
                Continued line.

            ```text
            [^fake]: Not a definition.
            And a literal [^ref].
            ```
            """
        let document = try await MarkdownDocument.parse(source)
        XCTAssertFalse(document.blocks.contains {
            if case .paragraph(let content) = $0.content {
                return String(describing: content).contains("[^second]:")
            }
            return false
        })
        let noteBlocks = document.blocks.filter { $0.anchor?.hasPrefix("bailey-note:") == true }
        XCTAssertEqual(noteBlocks.count, 2, "Expected two distinct linked footnote blocks")
        XCTAssertEqual(noteBlocks.map(\.anchor), ["bailey-note:ref", "bailey-note:second"])
        guard case let .paragraph(inline) = document.blocks.first?.content else {
            return XCTFail("Missing reference paragraph")
        }
        let links = inline.compactMap { node -> String? in
            guard case let .link(target, _) = node else { return nil }
            return target
        }
        XCTAssertEqual(links, ["#bailey-note:ref", "#bailey-note:ref", "#bailey-note:second"])
        XCTAssertTrue(String(describing: noteBlocks).contains("Continued line"))
        XCTAssertTrue(document.blocks.contains {
            if case let .code(source, _) = $0.content { source.contains("[^fake]") }
            else { false }
        })
    }

    func testFootnotesRespectCodeFencesAndUnresolvedReferences() async throws {
        let source = """
            Text has unresolved[^missing] reference and escaped \\[^escaped].

            ```markdown
            [^hidden]: Do not index me.
            ```

            [^visible]: A visible note.

            Text references[^visible].
            """
        let document = try await MarkdownDocument.parse(source)
        XCTAssertEqual(document.blocks.filter { $0.anchor?.hasPrefix("bailey-note:") == true }.count, 1)
        XCTAssertTrue(document.blocks.contains { $0.anchor == "bailey-note:visible" })
        XCTAssertFalse(document.blocks.contains { $0.anchor == "bailey-note:hidden" })
        XCTAssertTrue(String(describing: document.blocks.first?.content).contains("[^missing]"))
    }

    func testLargeDocumentParsesOffMainActorAndKeepsEnd() async throws {
        for lines in [500, 5_000, 20_000] {
            let source = (0..<lines).map { "Paragraph \($0) **inline**" }.joined(separator: "\n\n")
            let clock = ContinuousClock()
            let start = clock.now
            let document = try await MarkdownDocument.parse(source)
            let elapsed = start.duration(to: clock.now)
            XCTAssertEqual(document.blocks.count, lines)
            guard case let .paragraph(last) = document.blocks.last?.content else {
                return XCTFail("Missing final paragraph")
            }
            XCTAssertTrue(String(describing: last).contains("\(lines - 1)"))
            print("SwiftMarkdown AST \(lines) paragraphs: \(elapsed)")
        }
    }

    private func containsImageOrDetails(_ nodes: [MarkdownHTML]) -> Bool {
        nodes.contains { node in
            switch node {
            case .image, .details: true
            case .paragraph(let children), .quote(let children): containsImageOrDetails(children)
            default: false
            }
        }
    }

    private func describe(_ block: MarkdownDocument.Block) -> String {
        switch block.content {
        case .rawHTML(let source): source
        case .html(let nodes): String(describing: nodes)
        case .paragraph(let inline), .heading(_, let inline): String(describing: inline)
        default: String(describing: block.content)
        }
    }
}
