import AppKit
import AVFoundation
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
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
        XCTAssertTrue(inlines.contains { if case .text(let text, _) = $0 { text.contains("前文 before") } else { false } })
        XCTAssertTrue(inlines.contains { if case .image("assets/plot%20one.svg", "示意图") = $0 { true } else { false } })
        XCTAssertTrue(inlines.contains { if case .text(let text, _) = $0 { text.contains("后文 after") } else { false } })
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
        XCTAssertTrue(String(MarkdownNativeText.attributed(inline).characters).contains("$5"),
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
        XCTAssertTrue(String(MarkdownNativeText.attributed(inline).characters).contains("$x$"))
        for source in ["unclosed $x", "cost $5", "\\$escaped"] {
            let document = try await MarkdownDocument.parse(source)
            guard case let .paragraph(inline) = document.blocks.first?.content else {
                return XCTFail("Missing literal paragraph")
            }
            XCTAssertFalse(inline.contains { if case .math = $0 { true } else { false } },
                           "Unexpected formula from \(source)")
        }
    }

    func testCurrencyDollarsCannotConsumeLaterValidMathOpeners() async throws {
        for (source, expected) in [
            ("Cost $5 and equation $E=mc^2$ is inline.", ["E=mc^2"]),
            ("Costs $5 and $10 then $x_i$", ["x_i"]),
            ("Price $5 and \\$escaped, then $\\alpha + 1$", ["\\alpha + 1"]),
        ] {
            let document = try await MarkdownDocument.parse(source)
            guard case let .paragraph(inline) = document.blocks.first?.content else {
                return XCTFail("Missing prose for \(source)")
            }
            let expressions = inline.compactMap { node -> String? in
                guard case let .math(latex, display: false) = node else { return nil }
                return latex
            }
            XCTAssertEqual(expressions, expected,
                           "A rejected currency delimiter must not consume a later math opener: \(source)")
            XCTAssertTrue(MarkdownNativeText.attributed(inline).characters.contains("5"),
                          "Ordinary currency must remain readable")
        }
    }

    func testMathCannotSwallowInlineCodeOrLinksBetweenDelimiters() async throws {
        let source = "Open $alpha `literal` beta$ then $x$ and $open [docs](guide.md) close$ then $y$."
        let document = try await MarkdownDocument.parse(source)
        guard case let .paragraph(inline) = document.blocks.first?.content else {
            return XCTFail("Expected Markdown prose")
        }
        let expressions = inline.compactMap { node -> String? in
            if case let .math(latex, display: false) = node { return latex }
            return nil
        }
        XCTAssertEqual(expressions, ["x", "y"],
                       "Math must not cross inline code or linked Markdown nodes")
        XCTAssertTrue(inline.contains {
            if case .code("literal") = $0 { return true }
            return false
        }, "Inline code must survive math tokenization")
        XCTAssertTrue(inline.contains {
            if case .link("guide.md", _) = $0 { return true }
            return false
        }, "Links inside a rejected formula candidate must remain interactive Markdown")
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

    func testMalformedMathRemainsVisibleInsteadOfVanishing() throws {
        for latex in ["\\unknowncommand", "\\frac{", "\\left(x"] {
            let window = NSWindow(
                contentRect: NSRect(x: -1800, y: -1800, width: 460, height: 140),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MarkdownFormulaView(latex: latex, display: false))
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 1,
                                 "Malformed TeX must not collapse to invisible zero-width content: \(latex)")
            XCTAssertGreaterThan(host.fittingSize.height, 1,
                                 "Malformed TeX must retain readable native fallback height")
            window.close()
        }
    }

    func testMermaidKeepsSourceAndRejectsExecutableCallbacks() async throws {
        let diagrams = [
            "flowchart TD\n  A[Start] --> B[Done]",
            "sequenceDiagram\n  Alice->>Bob: Hello",
            "classDiagram\n  Animal <|-- Dog",
            "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Running",
        ]
        for diagram in diagrams {
            let markdown = "```mermaid\n\(diagram)\n```"
            let document = try await MarkdownDocument.parse(markdown)
            guard case let .mermaid(source, _) = document.blocks.first?.content else {
                return XCTFail("Mermaid must remain a native AST block: \(diagram)")
            }
            XCTAssertEqual(source.trimmingCharacters(in: .whitespacesAndNewlines), diagram)
            let picture = await MarkdownMermaid.image(source, dark: false)
            let rendered = try XCTUnwrap(picture, "Supported Mermaid diagram must render: \(diagram)")
            XCTAssertGreaterThan(rendered.size.width, 0)
            XCTAssertGreaterThan(rendered.size.height, 0)
        }
        for unsafe in [
            "flowchart TD\n  click A \"https://example.com\"",
            "flowchart TD\n  link A https://example.com",
            "flowchart TD\n  links A https://example.com",
        ] {
            let image = await MarkdownMermaid.image(unsafe, dark: false)
            XCTAssertNil(image, "Mermaid's actionable link directives must be rejected")
        }
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

    func testInlineHTMLDetailsOpenStateSurvivesNativeASTProjection() async throws {
        let source = """
            # HTML inline

            <span>Alpha </span><strong>Beta</strong><span> Gamma</span>

            <details open><summary>Notes</summary><span>One </span><em>Two</em> Three</details>
            """
        for _ in 0..<10 {
            let document = try await MarkdownDocument.parse(source)
            let nativeHTML = document.blocks.flatMap { block -> [MarkdownHTML] in
                if case let .html(nodes) = block.content { return nodes }
                return []
            }
            let details = nativeHTML.compactMap { node -> (String, [MarkdownHTML], Bool)? in
                guard case let .details(label, children, open) = node else { return nil }
                return (label, children, open)
            }
            XCTAssertEqual(details.count, 1)
            let detail = try XCTUnwrap(details.first)
            XCTAssertEqual(detail.0, "Notes")
            XCTAssertTrue(detail.2, "The native HTML AST must preserve the open attribute")
            XCTAssertTrue(detail.1.contains {
                if case .emphasis(_, tag: "em") = $0 { return true }
                return false
            }, "Inline emphasis nested inside details must remain in the native AST")
        }
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
        XCTAssertEqual(image.image.width, 40)
        XCTAssertEqual(image.image.height, 20)
        XCTAssertThrowsError(try MarkdownSVG.render(Data("<!DOCTYPE svg><svg/>".utf8)))
    }

    func testSVGOnlyAllowsLocalFragmentURLsInsideStyledGradientsAndFilters() throws {
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="12">
              <defs>
                <linearGradient id="safe"><stop offset="0" stop-color="red"/>
                  <stop offset="1" stop-color="blue"/></linearGradient>
                <filter id="localBlur"><feGaussianBlur stdDeviation="0.2"/></filter>
              </defs>
              <rect width="24" height="12" style="fill:url(#safe);filter:url(#localBlur)" onclick="alert(1)"/>
              <rect width="24" height="12" fill="url(#safe) url(https://example.invalid/exfil)"/>
              <rect width="24" height="12"
                style="fill:url(#safe);filter:url('https://example.invalid/exfil')"/>
              <rect width="24" height="12" fill="url('https://example.invalid/exfil')"/>
              <image href="file:///etc/passwd"/>
              <script>alert(1)</script>
            </svg>
            """
        let cleaned = try MarkdownSVG.sanitizedXML(Data(source.utf8))
        XCTAssertTrue(cleaned.contains("linearGradient"))
        XCTAssertTrue(cleaned.contains("fill:url(#safe)"),
                      "A valid local CSS gradient must survive sanitization")
        XCTAssertTrue(cleaned.contains("filter:url(#localBlur)"),
                      "A valid local SVG filter must survive sanitization")
        XCTAssertFalse(cleaned.contains("example.invalid"),
                       "Every URL function must be checked, not only the first one")
        XCTAssertFalse(cleaned.contains("file:///"))
        XCTAssertFalse(cleaned.contains("onclick"))
        XCTAssertFalse(cleaned.contains("<script"))
        let image = try MarkdownSVG.render(Data(source.utf8))
        XCTAssertEqual(image.image.width, 48)
        XCTAssertEqual(image.image.height, 24)
        XCTAssertEqual(image.pointSize.width, 24)
        XCTAssertEqual(image.pointSize.height, 12)

        let gradient = """
            <svg xmlns="http://www.w3.org/2000/svg" width="40" height="12">
              <defs><linearGradient id="fade"><stop offset="0" stop-color="red"/>
                <stop offset="1" stop-color="blue"/></linearGradient></defs>
              <rect width="40" height="12" fill="url(#fade)"/>
            </svg>
            """
        let raster = NSBitmapImageRep(cgImage: try MarkdownSVG.render(Data(gradient.utf8)).image)
        let left = try XCTUnwrap(raster.colorAt(x: 6, y: 12)?.usingColorSpace(.deviceRGB))
        let right = try XCTUnwrap(raster.colorAt(x: 74, y: 12)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(left.redComponent, right.redComponent + 0.25,
                             "SVG gradients must produce different actual pixel colors")
        XCTAssertGreaterThan(right.blueComponent, left.blueComponent + 0.25)
    }

    func testRenderedHeadingTextRangePointsPastMarkdownMarkers() async throws {
        let source = "\u{FEFF}---\r\nname: try\r\n---\r\n## Destination 👩‍🚀\r\n\r\n**Strong** paragraph."
        let document = try await MarkdownDocument.parse(source)
        let original = source as NSString
        let heading = try XCTUnwrap(document.blocks.first)
        XCTAssertEqual(heading.sourceRange, original.range(of: "## Destination 👩‍🚀"))
        guard case .heading(_, let title) = heading.content, case .text(_, let headingText) = title.first
        else { return XCTFail("Expected original heading text") }
        XCTAssertEqual(headingText, original.range(of: "Destination 👩‍🚀"),
                       "Double-click navigation must not position the caret on heading markers")
        let paragraph = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.content { return true }
            return false
        })
        guard case .paragraph(let inline) = paragraph.content, case .strong(let children) = inline.first,
              case .text(_, let strongText) = children.first
        else { return XCTFail("Expected bold text in the original paragraph") }
        XCTAssertEqual(strongText, original.range(of: "Strong"))
    }

    func testOriginalBlockIndexTracksRepeatedHeadingsUnicodeAndExtractedFootnotes() async throws {
        let source = """
            # Same 🧪

            第一段 e\u{301} and $x^2$.

            # Same 🧪

            第二段[^note] with 👩‍💻.

            [^note]: 真实脚注
            """
        let document = try await MarkdownDocument.parse(source)
        let index = MarkdownBlockIndex(document)
        let nsSource = source as NSString
        for (text, number) in [("# Same 🧪", 0), ("第一段 e\u{301}", 0),
                               ("# Same 🧪", 1), ("第二段[^note]", 0),
                               ("[^note]: 真实脚注", 0)] {
            let first = nsSource.range(of: text)
            let match = number == 0 ? first : nsSource.range(
                of: text, options: [], range: NSRange(
                    location: NSMaxRange(first), length: nsSource.length - NSMaxRange(first)
                )
            )
            let mapped = try XCTUnwrap(index.block(atUTF16Offset: match.location))
            let sourceRange = try XCTUnwrap(document.blocks[mapped].sourceRange)
            XCTAssertTrue(sourceRange.location <= match.location
                          && match.location < NSMaxRange(sourceRange),
                          "The source index must resolve the original UTF-16 containing block")
        }
    }

    func testOriginalUTF16BlockRangesSurviveFrontMatterCRLFMathAndFootnotes() async throws {
        let heading = "# 👩‍🚀 中文 Café"
        let paragraph = "e\u{301}moji 😀\tmath $a_b$ and [^note]."
        let definition = "[^note]: 原文 🍵"
        let source = "\u{FEFF}---\r\nname: 位置\r\n---\r\n" + heading
            + "\r\n\r\n" + paragraph + "\r\n\r\n" + definition + "\r\n"
        let document = try await MarkdownDocument.parse(source)
        let nsSource = source as NSString
        for (label, original) in [
            ("heading", heading), ("paragraph", paragraph), ("note", definition)
        ] {
            let expected = nsSource.range(of: original)
            XCTAssertNotEqual(expected.location, NSNotFound)
            let block: MarkdownDocument.Block?
            if label == "note" {
                block = document.blocks.first { $0.anchor == "bailey-note:note" }
            } else {
                block = document.blocks.first { $0.line == (label == "heading" ? 4 : 6) }
            }
            let mapped = try XCTUnwrap(block?.sourceRange,
                                       "Missing original range for \(label)")
            XCTAssertEqual(mapped, expected,
                           "The \(label) range must index the untouched UTF-16 file, not the rewritten AST")
            XCTAssertEqual(nsSource.substring(with: mapped), original)
        }
        XCTAssertEqual(document.blocks.first?.line, 4)
        XCTAssertTrue(document.blocks.contains {
            if case .mathBlock = $0.content { return true }
            if case .paragraph(let inline) = $0.content {
                return inline.contains { if case .math = $0 { return true }; return false }
            }
            return false
        }, "The original-coordinate projection must not change math rendering")
    }

    func testMarkdownFileSoftBreaksBecomeSpacesAndExplicitBreaksStayNewlines() async throws {
        for ending in ["\n", "\r\n", "\r"] {
            let source = ["软", "换行  ", "双空格\\", "反斜杠"].joined(separator: ending)
            let document = try await MarkdownDocument.parse(source)
            guard case .paragraph(let inline) = document.blocks.first?.content else {
                return XCTFail("Expected the original paragraph")
            }
            XCTAssertEqual(String(MarkdownNativeText.attributed(inline).characters), "软 换行\n双空格\n反斜杠")
        }
    }

    func testGitHubAlertsRequireAnUnescapedStandaloneMarkerInATopLevelQuote() async throws {
        let tags = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]
        let source = tags.map { "> [!\($0)]\n> **中文 \($0)**" }.joined(separator: "\n\n")
            + "\n\n> [!UNKNOWN]\n> 普通引用"
            + "\n\n> [!NOTE] trailing\n> 普通引用"
            + "\n\n> \\[!NOTE]\n> 转义"
            + "\n\n> > [!NOTE]\n> > 嵌套引用"
            + "\n\n```markdown\n> [!NOTE]\n> 代码\n```"
        let document = try await MarkdownDocument.parse(source)
        XCTAssertEqual(document.blocks.count, tags.count + 5)
        for (block, tag) in zip(document.blocks, tags) {
            guard case .alert(let kind, let children) = block.content,
                  case .paragraph(let inline) = children.first else {
                return XCTFail("The top-level \(tag) quote should render as an alert")
            }
            XCTAssertEqual(kind.rawValue, "[!\(tag)]")
            XCTAssertEqual(String(MarkdownNativeText.attributed(inline).characters), "中文 \(tag)")
            XCTAssertNotNil(block.sourceRange)
        }
        for block in document.blocks.dropFirst(tags.count).dropLast() {
            guard case .quote = block.content else { return XCTFail("Keep ordinary quotes as quotes") }
        }
        guard case .code = document.blocks.last?.content else { return XCTFail("Keep fenced markup literal") }
    }

    func testEscapedTextAndEntitiesRetainIndividualOriginalTokenRanges() async throws {
        let source = #"A \* B & no &amp; C &#x1F680; 末"#
        let expected = [("A ", "A "), ("*", #"\*"#), (" B & no ", " B & no "), ("&", "&amp;"),
                        (" C ", " C "), ("🚀", "&#x1F680;"), (" 末", " 末")]
        let original = source as NSString
        let document = try await MarkdownDocument.parse(source)
        guard case .paragraph(let inline) = document.blocks.first?.content else {
            return XCTFail("Expected a literal paragraph")
        }
        XCTAssertEqual(String(MarkdownNativeText.attributed(inline).characters), "A * B & no & C 🚀 末")
        XCTAssertEqual(inline.count, expected.count)
        for (node, (displayed, raw)) in zip(inline, expected) {
            guard case .text(let value, let range) = node else { return XCTFail("Expected text") }
            XCTAssertEqual(value, displayed)
            XCTAssertEqual(range, original.range(of: raw))
        }
    }

    func testInlineSourceRangesSurviveCombinedMathFootnotesAndUnicode() async throws {
        let paragraph = "首段 $x_y$ **e\u{301}中文** 脚注[^note] 最后 👩‍🚀。"
        let source = "\u{FEFF}---\r\nname: text\r\n---\r\n\(paragraph)\r\n\r\n[^note]: 注释"
        let document = try await MarkdownDocument.parse(source)
        guard case .paragraph(let inline) = document.blocks.first?.content else {
            return XCTFail("Expected the original prose block")
        }
        let original = source as NSString
        let bold = try XCTUnwrap(inline.first {
            if case .strong = $0 { return true }
            return false
        })
        guard case .strong(let children) = bold, case .text(let label, let sourceRange) = children.first else {
            return XCTFail("Expected the inner text of the strong node")
        }
        XCTAssertEqual(label, "e\u{301}中文")
        XCTAssertEqual(sourceRange, original.range(of: label))
        guard case .text(let tail, let tailRange) = inline.last else {
            return XCTFail("Expected text following the footnote reference")
        }
        XCTAssertEqual(tail, " 最后 👩‍🚀。")
        XCTAssertEqual(tailRange, original.range(of: tail))
        let leading = try XCTUnwrap(inline.first)
        guard case .text(let prefix, let prefixRange) = leading else {
            return XCTFail("Expected the text before the formula")
        }
        XCTAssertEqual(prefix, "首段 ")
        XCTAssertEqual(prefixRange, original.range(of: prefix))
    }

    func testMarkdownRewriteMapsUnchangedTextSyntheticTokensAndDeletionEdges() throws {
        let original = "🛰️ $x$ 中文 [^n]\r\n[^n]: text\r\nNext"
        let bytes = Array(original.utf8)
        func span(_ needle: String, in text: String) throws -> Range<Int> {
            let match = try XCTUnwrap(text.range(of: needle))
            let start = text.utf8.distance(from: text.startIndex, to: match.lowerBound)
            return start..<text.utf8.distance(from: text.startIndex, to: match.upperBound)
        }
        let math = try span("$x$", in: original)
        let reference = try span("[^n]", in: original)
        let definition = try span("[^n]: text", in: original)
        let rewrite = MarkdownSourceRewrite(original, replacing: [
            .init(bytes: math, text: "MATH_TOKEN"),
            .init(bytes: reference, text: "[1](#note)"),
            .init(bytes: definition, text: "")
        ])
        XCTAssertEqual(rewrite.source, "🛰️ MATH_TOKEN 中文 [1](#note)\r\n\r\nNext")
        for (visible, raw) in [("🛰️", "🛰️"), ("中文", "中文"), ("TOKEN", "$x$"),
                               ("[1](#note)", "[^n]"), ("Next", "Next")] {
            let mapped = try XCTUnwrap(rewrite.originalBytes(for: span(visible, in: rewrite.source)))
            XCTAssertEqual(String(decoding: bytes[mapped], as: UTF8.self), raw)
        }
        let next = try span("Next", in: rewrite.source)
        let deletion = next.lowerBound - 2
        XCTAssertEqual(rewrite.originalBytes(for: (deletion - 2)..<deletion),
                       (definition.lowerBound - 2)..<definition.lowerBound)
        XCTAssertEqual(rewrite.originalBytes(for: deletion..<(deletion + 2)),
                       definition.upperBound..<(definition.upperBound + 2))
    }

    func testMarkdownCoordinatesDistinguishUnicodeSeparatorsFromSourceLineEndings() async throws {
        for ending in ["\n", "\r\n", "\r"] {
            for separator in ["\u{0085}", "\u{2028}", "\u{2029}", "\u{000B}", "\u{000C}"] {
                let body = "First\(separator)still the same Markdown line."
                let heading = "## Destination 👩‍🚀"
                let paragraph = "Use $x^2$ and [^note]."
                let note = "[^note]: 中文 👩‍🚀"
                let source = [body, "", heading, "", paragraph, "", note].joined(separator: ending)
                let original = source as NSString
                let document = try await MarkdownDocument.parse(source)
                for text in [body, heading, paragraph, note] {
                    let expected = original.range(of: text)
                    let block = document.blocks.first { $0.sourceRange == expected }
                    XCTAssertNotNil(block, "Expected untouched source range for \(text.debugDescription)")
                }
                XCTAssertEqual(document.blocks.first { $0.anchor == "destination-" }?.line, 3)
                XCTAssertNotNil(document.blocks.first { $0.anchor == "bailey-note:note" })
                XCTAssertTrue(document.blocks.contains {
                    guard case .paragraph(let inline) = $0.content else { return false }
                    return inline.contains { if case .math("x^2", display: false) = $0 { true } else { false } }
                })
            }
        }
    }

    func testOriginalRangesKeepNestedListQuoteAndMultilineFootnoteContent() async throws {
        let source = """
            # Title

            > Quote 🌏
            > still quoted

            - **item** with `code`
            - next

            Footnote[^deep].

            [^deep]: First line
                second line with e\u{301}
            """
        let document = try await MarkdownDocument.parse(source)
        let original = source as NSString
        for label in ["> Quote 🌏\n> still quoted",
                      "- **item** with `code`\n- next\n",
                      "Footnote[^deep].",
                      "[^deep]: First line\n    second line with e\u{301}"] {
            let expected = original.range(of: label)
            XCTAssertNotEqual(expected.location, NSNotFound)
            let match = document.blocks.first {
                guard let range = $0.sourceRange else { return false }
                return range.location == expected.location
            }
            let range = try XCTUnwrap(match?.sourceRange, "No original mapping for \(label)")
            XCTAssertEqual(range, expected)
        }
    }

    func testStaticPNGJPEGHEICAndWebPUseNativeImageIODecoding() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let source = try XCTUnwrap(context.makeImage())
        for codec in [UTType.png, .jpeg, .heic] {
            let bytes = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
                bytes, codec.identifier as CFString, 1, nil
            ), "ImageIO must encode \(codec.identifier) on this Mac")
            CGImageDestinationAddImage(destination, source, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination), codec.identifier)
            let picture = try MarkdownPicture.decode(bytes as Data)
            XCTAssertEqual(picture.poster.width, 16, codec.identifier)
            XCTAssertEqual(picture.poster.height, 16, codec.identifier)
            XCTAssertTrue(picture.animation.isEmpty, codec.identifier)
        }
        // macOS decodes WebP but has no WebP ImageIO encoder. This 16px
        // lossless image is a complete static fixture, not an external dependency.
        let webp = try XCTUnwrap(Data(base64Encoded:
            "UklGRhwAAABXRUJQVlA4TA8AAAAvD8ADAAcQ9Y/+ByKi/wEA"
        ))
        let picture = try MarkdownPicture.decode(webp)
        XCTAssertEqual(picture.poster.width, 16)
        XCTAssertEqual(picture.poster.height, 16)
        XCTAssertTrue(picture.animation.isEmpty)
    }

    func testGIFFramesHonorTimingAndAnimationBudget() throws {
        func frame(_ color: CGColor, dimension: Int = 16) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: dimension, height: dimension, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
            return try XCTUnwrap(context.makeImage())
        }

        let red = try frame(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let blue = try frame(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-gif-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func animatedGIF(frameCount: Int, at path: URL,
                         images: (CGImage, CGImage)? = nil) throws -> Data {
            let pair = images ?? (red, blue)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                path as CFURL, UTType.gif.identifier as CFString, frameCount, nil
            ))
            for index in 0..<frameCount {
                let properties = [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: index.isMultiple(of: 2) ? 0.2 : 0.6
                    ]
                ] as CFDictionary
                CGImageDestinationAddImage(destination, index.isMultiple(of: 2) ? pair.0 : pair.1, properties)
            }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return try Data(contentsOf: path)
        }

        let picture = try MarkdownPicture.decode(animatedGIF(frameCount: 2, at: root.appending(path: "animated.gif")))
        XCTAssertEqual(picture.animation.count, 2)
        XCTAssertEqual(picture.animation[0].seconds, 0.2, accuracy: 0.01)
        XCTAssertEqual(picture.animation[1].seconds, 0.6, accuracy: 0.01)
        XCTAssertEqual(picture.image(at: 0), picture.animation[0].image)
        XCTAssertEqual(picture.image(at: 0.3), picture.animation[1].image)
        XCTAssertEqual(picture.image(at: 0.85), picture.animation[0].image,
                       "Animations must loop rather than freeze on the last frame")

        let overBudget = try MarkdownPicture.decode(animatedGIF(
            frameCount: 33, at: root.appending(path: "oversized-animation.gif")
        ))
        XCTAssertTrue(overBudget.animation.isEmpty,
                      "More than 32 GIF frames must degrade to a static poster")
        XCTAssertEqual(overBudget.poster.width, 16)
        let large = try frame(CGColor(red: 1, green: 0, blue: 0, alpha: 1), dimension: 600)
        let overPixelBudget = try MarkdownPicture.decode(animatedGIF(
            frameCount: 32, at: root.appending(path: "oversized-pixels.gif"),
            images: (large, large)
        ))
        XCTAssertTrue(overPixelBudget.animation.isEmpty,
                      "32 frames exceeding eight million decoded pixels must use a static poster")
        XCTAssertThrowsError(try MarkdownPicture.decode(Data("not an image".utf8)))
    }

    func testMediaStageUsesAuthorizedBytesAndRejectsUnboundedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-audio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appending(path: "Readme.md")
        try Data("# Audio".utf8).write(to: document)
        let audio = root.appending(path: "sound.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 8_000)
        let writer = try AVAudioFile(forWriting: audio, settings: format.settings)
        try writer.write(from: buffer)
        let resource = MarkdownResource(
            path: document.path, directory: root.path, backend: LocalWorkspaceBackend.shared
        )
        let staged = try await MarkdownMedia.stage(try XCTUnwrap(URL(string: "sound.wav")), from: resource)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertNotEqual(staged, audio)
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: audio))
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: staged.deletingLastPathComponent().path
        )[.posixPermissions] as? Int)
        XCTAssertEqual(permissions & 0o077, 0,
                       "The staged file must reside in a private directory")
        let playable = try await MarkdownMedia.asset(at: staged).load(.isPlayable)
        XCTAssertTrue(playable)

        let tooBig = root.appending(path: "oversized.wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: tooBig.path, contents: nil))
        let handle = try FileHandle(forWritingTo: tooBig)
        try handle.truncate(atOffset: UInt64((64 << 20) + 1))
        try handle.close()
        for rawURL in ["oversized.wav", "../secret.wav", "https://example.invalid/sound.wav",
                       "file:///etc/passwd", "unsupported.bin"] {
            do {
                _ = try await MarkdownMedia.stage(try XCTUnwrap(URL(string: rawURL)), from: resource)
                XCTFail("Media staging must reject \(rawURL)")
            } catch {
                // Rejection must happen before an unauthorized resource is staged.
            }
        }
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
              case .text("1. ", _) = definition.first else {
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
