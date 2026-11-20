import AppKit
import Foundation
import XCTest
@testable import Bailey

@MainActor
final class MarkdownPreviewTests: XCTestCase {
    func testSKILLMetadataKeepsMultilineAndNullValuesOutOfBody() async throws {
        let source = "\u{FEFF}" + [
            "---", "name: sample", "description: |", "  多行", "  second line",
            "# a comment", "empty:", "custom: !include ../private.yaml", "---",
            "# Read me", "", "---", "Body"
        ].joined(separator: "\r\n")
        let document = try await MarkdownDocument.parse(source)
        XCTAssertNil(document.warning)
        XCTAssertEqual(document.properties.map(\.name), ["name", "description", "empty", "custom"])
        XCTAssertEqual(document.properties.map(\.value), ["sample", "多行\nsecond line\n", "", "../private.yaml"])
        XCTAssertEqual(document.blocks.first?.anchor, "read-me")
        XCTAssertFalse(previewText(document).contains("private.yaml"))
        XCTAssertTrue(previewText(document).contains("Body"))
    }

    func testOnlyDocumentHeadIsTreatedAsYAML() async throws {
        let unclosed = try await MarkdownDocument.parse("---\nname: keep me")
        XCTAssertNotNil(unclosed.warning)
        XCTAssertTrue(previewText(unclosed).contains("name: keep me"))
        let horizontalRule = try await MarkdownDocument.parse("# Body\n\n---\n\nname: stays\n---")
        XCTAssertTrue(horizontalRule.properties.isEmpty)
        XCTAssertNil(horizontalRule.warning)
        XCTAssertTrue(previewText(horizontalRule).contains("name: stays"))
        let invalid = try await MarkdownDocument.parse("---\nname: [\n---\nBody")
        XCTAssertNotNil(invalid.warning)
        XCTAssertEqual(previewText(invalid), "Body")
    }

    func testGFMSourceRangesAndMDXAreReadableWithoutExecution() async throws {
        for filename in ["SKILL.md", "paper.Markdown", "README.MDX", "科研 🙂.md"] {
            XCTAssertTrue(MarkdownDocument.supports(filename))
        }
        for filename in ["markdown", ".md", "file.md.txt", "file.html", "file.svg"] {
            XCTAssertFalse(MarkdownDocument.supports(filename))
        }
        let document = try await MarkdownDocument.parse("""
            # 科研 Report

            # 科研 Report

            - [x] 已完成
            - [ ] Pending

            | one | two |
            | --- | --- |
            | ~~removed~~ | https://example.invalid |

            ```mermaid title
            graph TD
                A --> B
            ```

            import Widget from './widget'

            <Widget data={items} />

            {items.length}
            """)
        XCTAssertEqual(document.blocks.compactMap(\.anchor), ["科研-report", "科研-report-1"])
        let text = previewText(document)
        for literal in ["☑ 已完成", "☐ Pending", "removed", "import Widget", "<Widget data={items} />", "{items.length}"] {
            XCTAssertTrue(text.contains(literal), literal)
        }
        let markup = document.blocks.compactMap { block -> AttributedString? in
            if case .markdown(let content) = block.content { return content }
            return nil
        }
        let runs = markup.flatMap { Array($0.runs) }
        XCTAssertTrue(runs.contains { $0.link?.host == "example.invalid" })
        XCTAssertTrue(runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
        XCTAssertTrue(runs.contains { run in
            run.presentationIntent?.components.contains { if case .table = $0.kind { true } else { false } } == true
        })
        let fence = try XCTUnwrap(markup.first { $0.characters.starts(with: "graph TD") })
        XCTAssertEqual(String(fence.characters), "graph TD\n    A --> B\n")
        XCTAssertEqual(fence.runs.first?.markdownSourcePosition?.startColumn, 1)
    }

    func testHTMLProducesOnlyNativeDataAndDoesNotInterpretUnsupportedNodes() throws {
        let nodes = try XCTUnwrap(MarkdownHTML.parse("""
            <details><summary>Notes</summary><img src="image.png" alt="A" onerror="doSomething()">
            <script>doSomething()</script><iframe src="https://example.invalid"></iframe></details>
            """))
        guard case .details("Notes", let children) = nodes.first else {
            return XCTFail("Expected a native details block")
        }
        XCTAssertTrue(children.contains(.image(try XCTUnwrap(URL(string: "image.png")), alt: "A")))
        XCTAssertTrue(children.contains { if case .text(let text) = $0 { text.contains("<script>") } else { false } })
        XCTAssertTrue(children.contains { if case .text(let text) = $0 { text.contains("<iframe") } else { false } })
    }

    func testActualImageAndBoundedReadStayInsideDocumentProject() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let project = temporary.appending(path: "Project")
        let folder = project.appending(path: "docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = project.appending(path: "红 图.png")
        let image = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 5, pixelsHigh: 3, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        image.setColor(.red, atX: 0, y: 0)
        let bytes = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try bytes.write(to: asset)
        let secret = temporary.appending(path: "outside.png")
        try bytes.write(to: secret)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "escape.png"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "other"), withDestinationURL: temporary)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "alias.png"), withDestinationURL: asset)
        let resource = MarkdownResource(path: folder.appending(path: "SKILL.md").path,
                                        directory: project.path, backend: LocalWorkspaceBackend.shared)
        for link in ["../红%20图.png", "alias.png"] {
            let markup = try AttributedString(markdown: "![alt](<\(link)>)")
            let url = try XCTUnwrap(markup.runs.first?.imageURL)
            let read = try await resource.read(url, maxBytes: bytes.count)
            XCTAssertEqual(read, bytes)
            let decoded = try await resource.image(url)
            XCTAssertEqual(decoded.width, 5)
            XCTAssertEqual(decoded.height, 3)
        }
        let html = try XCTUnwrap(MarkdownHTML.parse(#"<img src="../红%20图.png" alt="图片">"#))
        guard case .image(let htmlURL, alt: "图片") = html.first else {
            return XCTFail("Expected HTML image")
        }
        let htmlImage = try await resource.image(htmlURL)
        XCTAssertEqual(htmlImage.width, 5)
        for link in ["../../outside.png", "%2e%2e/%2e%2e/outside.png", "escape.png", "other/outside.png",
                     "file:///outside.png", "https://example.invalid/image.png", "//example.invalid/image.png",
                     "%00.png", "missing.png", "alias.png?untrusted"] {
            let url = try XCTUnwrap(URL(string: link))
            do {
                _ = try await resource.image(url)
                XCTFail("Unexpectedly decoded \(link)")
            } catch {}
        }
        do {
            _ = try await resource.read(try XCTUnwrap(URL(string: "alias.png")), maxBytes: bytes.count - 1)
            XCTFail("Unexpectedly read past byte budget")
        } catch WorkspaceError.tooLarge {}
    }

    func testManyBlocksParseOffMainAndKeepTheLastHeading() async throws {
        for count in [500, 5_000, 20_000] {
            let started = ContinuousClock.now
            let source = String(repeating: "A **preview** paragraph.\n\n", count: count) + "# Final"
            let result = try await MarkdownDocument.parse(source)
            XCTAssertEqual(result.blocks.count, count + 1)
            XCTAssertEqual(result.blocks.last?.anchor, "final")
            print("Markdown \(count) paragraphs: \(started.duration(to: .now))")
        }
    }

    private func previewText(_ document: MarkdownDocument) -> String {
        document.blocks.compactMap { block in
            guard case .markdown(let content) = block.content else { return nil }
            return String(content.characters)
        }.joined(separator: "\n")
    }
}
