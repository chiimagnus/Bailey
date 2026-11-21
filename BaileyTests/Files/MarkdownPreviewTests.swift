import AppKit
import AVFoundation
import Foundation
import XCTest
import Textual
@testable import Bailey

@MainActor
final class MarkdownPreviewTests: XCTestCase {
    func testMarkdownMermaidUsesFenceBodyAndRendersNativeDiagramTypes() async throws {
        let documents = [
            "flowchart TD\n    Start --> Stop",
            "sequenceDiagram\n    Alice->>Bob: Hello",
            "classDiagram\n    class Ledger",
            "stateDiagram-v2\n    [*] --> Idle"
        ]
        for source in documents {
            let fenced = "---\nname: sample\n---\n```mermaid\n" + source + "\n```"
            let document = try await MarkdownDocument.parse(fenced)
            guard case .mermaid(let body, line: 4) = document.blocks.first?.content else {
                return XCTFail("Missing fence and original start line")
            }
            XCTAssertEqual(body, source + "\n")
            for dark in [false, true] {
                let rendered = await MarkdownMermaid.image(body, dark: dark)
                let image = try XCTUnwrap(rendered)
                XCTAssertGreaterThan(image.size.width, 20)
                XCTAssertGreaterThan(image.size.height, 20)
                XCTAssertNotNil(image.tiffRepresentation)
            }
        }
        for source in ["not a diagram", "flowchart TD\n click Start href \"https://example.invalid\"", String(repeating: "a", count: 20_000)] {
            let rendered = await MarkdownMermaid.image(source, dark: false)
            XCTAssertNil(rendered)
        }
    }

    func testRenderMathAndFootnotesWhileKeepingLiteralCode() async throws {
        let document = try await MarkdownDocument.parse("""
            Inline $x^2$ and a note[^ref]. Literal `$x$`.

            $$\\frac{1}{2}$$

            [^ref]: Note

            ```text
            [^fake]: Do not turn this into a footnote.
            ```
            """)
        let note = try XCTUnwrap(document.blocks.first { $0.anchor == "bailey-note:ref" })
        guard case .markdown(let noteText) = note.content else { return XCTFail("No footnote content") }
        XCTAssertEqual(String(noteText.characters), "[1] Note")
        XCTAssertFalse(document.blocks.contains { $0.anchor == "bailey-note:fake" })
        let allMarkup = try document.blocks.compactMap { block -> AttributedString? in
            guard case .markdown(let raw) = block.content else { return nil }
            return try PreparedMarkdown(markup: raw).attributedString(for: "")
        }
        let attachments = allMarkup.flatMap { $0.runs.compactMap { $0.textual.attachment?.description } }
        XCTAssertEqual(attachments, ["$x^2$", "$$\\frac{1}{2}$$"])
        XCTAssertTrue(allMarkup.contains { $0.runs.contains { $0.link?.fragment == "bailey-note:ref" } })
        XCTAssertTrue(allMarkup.contains { String($0.characters).contains("Literal $x$") })
    }
    func testSVGInlineAndRelativeShareStaticRenderingWithoutExternalContent() async throws {
        let source = """
            <svg xmlns="http://www.w3.org/2000/svg" width="20" height="10">
              <title>Gradient</title>
              <defs><linearGradient id="paint">
                <stop offset="0%" stop-color="red"/><stop offset="100%" stop-color="blue"/>
              </linearGradient></defs>
              <script>alert(1)</script><image href="https://example.invalid/image.png"/>
              <rect width="20" height="10" fill="url(#paint)" onclick="alert(1)"/>
            </svg>
            """
        let nodes = try XCTUnwrap(MarkdownHTML.parse(source))
        guard case .svg(let xml, alt: "Gradient") = nodes.first else { return XCTFail("Missing inline SVG") }
        let inline = try MarkdownSVG.render(Data(xml.utf8))
        XCTAssertEqual(inline.width, 40)
        XCTAssertEqual(inline.height, 20)
        let inlinePixels = NSBitmapImageRep(cgImage: inline)
        let left = try XCTUnwrap(inlinePixels.colorAt(x: 1, y: 8)?.usingColorSpace(.deviceRGB))
        let right = try XCTUnwrap(inlinePixels.colorAt(x: 38, y: 8)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(left.redComponent, left.blueComponent)
        XCTAssertGreaterThan(right.blueComponent, right.redComponent)
        XCTAssertThrowsError(try MarkdownSVG.render(Data("<!DOCTYPE svg><svg/>".utf8)))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(source.utf8).write(to: root.appending(path: "chart.svg"))
        let resource = MarkdownResource(path: root.appending(path: "paper.md").path,
                                        directory: root.path, backend: LocalWorkspaceBackend.shared)
        let loaded = try await resource.picture(try XCTUnwrap(URL(string: "chart.svg")))
        XCTAssertEqual(loaded.poster.width, inline.width)
        XCTAssertEqual(loaded.poster.height, inline.height)
    }

    func testControlledHTMLMediaStagesPlayableLocalBytesAndSeeks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "sound.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        samples.frameLength = 8_000
        do {
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            try file.write(from: samples)
        }
        let url = try XCTUnwrap(URL(string: "sound.wav"))
        let parsed = try XCTUnwrap(MarkdownHTML.parse("""
            <audio controls loop autoplay onplay="start()"><source src="sound.wav"></audio>
            """))
        XCTAssertEqual(parsed, [.media(url, video: false)])
        let excluded = try XCTUnwrap(MarkdownHTML.parse("<audio autoplay src='sound.wav'></audio>"))
        XCTAssertFalse(excluded.contains(.media(url, video: false)))
        let resource = MarkdownResource(path: root.appending(path: "paper.md").path,
                                        directory: root.path, backend: LocalWorkspaceBackend.shared)
        let staged = try await MarkdownMedia.stage(url, from: resource)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: input))
        let asset = MarkdownMedia.asset(at: staged)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.02)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        let seeked = await player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 8_000),
                                       toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(seeked)
        XCTAssertEqual(player.currentTime().seconds, 0.5, accuracy: 0.02)
        XCTAssertEqual(player.rate, 0)
        do {
            _ = try await MarkdownMedia.stage(try XCTUnwrap(URL(string: "https://example.invalid/sound.wav")),
                                              from: resource)
            XCTFail("Network media must never be staged")
        } catch is CocoaError {}
    }
    func testMarkdownLinkOpensTheAuthorizedProjectFileAndReusesIt() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let root = temporary.appending(path: "Project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let origin = root.appending(path: "Origin.md")
        let destination = root.appending(path: "Linked 图.md")
        try Data("# Origin".utf8).write(to: origin)
        try Data("# Linked".utf8).write(to: destination)
        let outside = temporary.appending(path: "outside.md")
        try Data("must not be read".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "out.md"), withDestinationURL: outside)
        let project = Project(fallbackName: "Project", workspaceConfiguration: .standard)
        project.customDirectory = root.path
        project.openFile(origin.path)
        guard case .file(let source)? = project.focusedContent else { return XCTFail("Expected Markdown source") }
        try await source.waitForText()
        for link in ["out.md", "../outside.md", "file:///etc/hosts", "javascript:alert(1)", "missing.md"] {
            let opened = await project.openMarkdownLink(try XCTUnwrap(URL(string: link)), from: source) { true }
            XCTAssertFalse(opened, link)
        }
        XCTAssertEqual(project.tabs.count, 1)
        let link = try XCTUnwrap(URL(string: "Linked%20%E5%9B%BE.md"))
        let rejected = await project.openMarkdownLink(link, from: source) { false }
        XCTAssertFalse(rejected)
        for _ in 0..<2 {
            let opened = await project.openMarkdownLink(link, from: source) { true }
            XCTAssertTrue(opened)
            guard case .file(let linked)? = project.focusedContent else { return XCTFail("Expected linked file") }
            try await linked.waitForText()
            XCTAssertEqual(linked.text, "# Linked")
            XCTAssertEqual(linked.path, destination.path)
            XCTAssertEqual(project.tabs.count, 2)
        }
    }

    func testSavingAndRestoringMarkdownReopensExactBytesWithoutAnEmptyCompanion() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: path) }
        let bom = Data([0xEF, 0xBB, 0xBF])
        try (bom + Data("# Before\r\n".utf8)).write(to: path)
        let project = Project(fallbackName: "Project", workspaceConfiguration: .standard)
        project.openLocalFile(path.path)
        let tab = try XCTUnwrap(project.focusedTab)
        guard case .file(let file) = tab.content else { return XCTFail("Expected Markdown source") }
        try await file.waitForText()
        let baseline = project.dock.root
        project.setMarkdownMode(.sideBySide, for: tab)
        file.text = "# After 👋\r\n"
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), bom + Data("# After 👋\r\n".utf8))
        let snapshot = project.dock.snapshot(tabIDs: [tab.id])
        XCTAssertEqual(snapshot.restore(tabIDs: [tab.id]), baseline)
        let restored = Project(fallbackName: "Restored", workspaceConfiguration: .standard)
        let restoredTab = restored.restoreTab(from: .init(
            content: .file(path: path.path, editorState: nil), localFile: true
        ))
        guard case .file(let restoredFile) = restoredTab.content else { return XCTFail("Missing restored file") }
        try await restoredFile.waitForText()
        XCTAssertEqual(restoredFile.text, "# After 👋\r\n")
        XCTAssertEqual(restored.markdownMode(for: restoredTab), .source)
    }
    func testDockCompanionReusesFileTabAndCollapsesWithoutDeactivatingTheDocument() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: path) }
        let bytes = Data("# Original\n".utf8)
        try bytes.write(to: path)
        let project = Project(fallbackName: "Project", workspaceConfiguration: .standard)
        project.openLocalFile(path.path)
        let tab = try XCTUnwrap(project.focusedTab)
        guard case .file(let file) = tab.content else { return XCTFail("Expected one file tab") }
        try await file.waitForText()
        let original = project.dock.root
        let storage = file.nativeTextStorage
        let request = file.markdownRequestID
        file.text = "# Edited\n"
        XCTAssertNotEqual(file.markdownRequestID, request)
        project.setMarkdownMode(.sideBySide, for: tab)
        let side = try XCTUnwrap(project.dock.group(containing: .markdownPreview(tab.id)))
        XCTAssertEqual(project.dock.root.groups.count, original.groups.count + 1)
        XCTAssertEqual(project.dock.tabOrder, [tab.id])
        XCTAssertEqual(project.tabs.count, 1)
        XCTAssertFalse(file.showsMarkdownPreview)
        project.dock.activate(side.id)
        XCTAssertTrue(project.focusedTab === tab)
        project.setMarkdownMode(.source, for: tab)
        XCTAssertEqual(project.dock.root, original)
        XCTAssertTrue(project.focusedTab === tab)
        XCTAssertTrue(file.nativeTextStorage === storage)
        XCTAssertTrue(file.isDirty)
        XCTAssertFalse(file.isSaving)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testMarkdownModeRequiresActualTextAndDoesNotTouchDirtyNativeSource() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mdx")
        defer { try? FileManager.default.removeItem(at: path) }
        let bytes = Data("# Original\r\n".utf8)
        try bytes.write(to: path)
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        XCTAssertFalse(file.canPreviewMarkdown)
        try await file.waitForText()
        XCTAssertTrue(file.canPreviewMarkdown)
        let storage = file.nativeTextStorage
        file.text = "# Draft\r\n"
        file.setMarkdownPreview(true)
        XCTAssertTrue(file.showsMarkdownPreview)
        XCTAssertTrue(file.isDirty)
        XCTAssertTrue(file.nativeTextStorage === storage)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        file.updatePath(path.path + ".txt")
        XCTAssertFalse(file.canPreviewMarkdown)
        XCTAssertFalse(file.showsMarkdownPreview)
        XCTAssertTrue(file.nativeTextStorage === storage)
        XCTAssertEqual(file.text, "# Draft\r\n")
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
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

            ```swift
            func call() {
                helper()
            }
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
        let fence = try XCTUnwrap(markup.first { $0.characters.starts(with: "func call()") })
        XCTAssertEqual(String(fence.characters), "func call() {\n    helper()\n}\n")
        XCTAssertEqual(fence.runs.first?.markdownSourcePosition?.startColumn, 1)
    }

    func testHTMLProducesOnlyNativeDataAndDoesNotInterpretUnsupportedNodes() throws {
        let nodes = try XCTUnwrap(MarkdownHTML.parse("""
            <details><summary>Notes</summary><img src="image.png" alt="A" onerror="doSomething()">
            <script>doSomething()</script><iframe src="https://example.invalid"></iframe></details>
            """))
        guard case .details("Notes", let children, open: false) = nodes.first else {
            return XCTFail("Expected a native details block")
        }
        XCTAssertTrue(children.contains(.image(try XCTUnwrap(URL(string: "image.png")), alt: "A")))
        XCTAssertTrue(children.contains { if case .text(let text) = $0 { text.contains("<script>") } else { false } })
        XCTAssertTrue(children.contains { if case .text(let text) = $0 { text.contains("<iframe") } else { false } })
        let opened = try XCTUnwrap(MarkdownHTML.parse("<details open><summary>Open</summary>Content</details>"))
        XCTAssertTrue(opened.contains {
            if case .details("Open", _, open: true) = $0 { return true }
            return false
        })
    }

    func testHTMLTablesPreserveHeaderSemanticsAndInlineBlocks() throws {
        let nodes = try XCTUnwrap(MarkdownHTML.parse("""
            <p>Hello <strong>bold</strong>, <em>italic</em>, and <code>code</code>.</p>
            <table><tr><th>Header</th><td>Ordinary cell</td></tr>
            <tr><td>Value</td><td>123</td></tr></table>
            <blockquote><p>Quoted paragraph</p></blockquote>
            """))
        guard let paragraph = nodes.compactMap({ node -> [MarkdownHTML]? in
            if case .paragraph(let parts) = node { return parts }
            return nil
        }).first else { return XCTFail("HTML paragraph was flattened") }
        XCTAssertTrue(paragraph.contains(.emphasis([.text("bold")], tag: "strong")))
        XCTAssertTrue(paragraph.contains(.emphasis([.text("italic")], tag: "em")))
        XCTAssertTrue(paragraph.contains(.emphasis([.text("code")], tag: "code")))

        guard let table = nodes.compactMap({ node -> [[MarkdownHTML.TableCell]]? in
            if case .table(let rows) = node { return rows }
            return nil
        }).first else { return XCTFail("HTML table missing") }
        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(table[0][0], .init(text: "Header", isHeader: true))
        XCTAssertEqual(table[0][1], .init(text: "Ordinary cell", isHeader: false))
        XCTAssertEqual(table[1][0], .init(text: "Value", isHeader: false))
        XCTAssertTrue(nodes.contains {
            if case .quote([.paragraph([.text("Quoted paragraph")])]) = $0 { return true }
            return false
        })
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
            let decoded = try await resource.picture(url).poster
            XCTAssertEqual(decoded.width, 5)
            XCTAssertEqual(decoded.height, 3)
        }
        let html = try XCTUnwrap(MarkdownHTML.parse(#"<img src="../红%20图.png" alt="图片">"#))
        guard case .image(let htmlURL, alt: "图片") = html.first else {
            return XCTFail("Expected HTML image")
        }
        let htmlImage = try await resource.picture(htmlURL).poster
        XCTAssertEqual(htmlImage.width, 5)
        for link in ["../../outside.png", "%2e%2e/%2e%2e/outside.png", "escape.png", "other/outside.png",
                     "file:///outside.png", "https://example.invalid/image.png", "//example.invalid/image.png",
                     "%00.png", "missing.png", "alias.png?untrusted"] {
            let url = try XCTUnwrap(URL(string: link))
            do {
                _ = try await resource.picture(url)
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

    func testMarkdownAtTheNativeTextByteBoundaryPreservesTheWholeBlock() async throws {
        let prefix = "# Capacity\n\n"
        let suffix = "\n\n# End"
        let size = 32 << 20
        let count = size - prefix.utf8.count - suffix.utf8.count
        let source = prefix + String(repeating: "a", count: count) + suffix
        XCTAssertEqual(source.utf8.count, size)
        let start = ContinuousClock.now
        let document = try await MarkdownDocument.parse(source)
        XCTAssertEqual(document.blocks.first?.anchor, "capacity")
        XCTAssertEqual(document.blocks.last?.anchor, "end")
        XCTAssertEqual(document.blocks.count, 3)
        guard case .markdown(let block) = document.blocks[1].content else {
            return XCTFail("The preview must preserve the content of the long paragraph")
        }
        XCTAssertEqual(String(block.characters).utf8.count, count)
        print("Markdown 32 MiB: \(start.duration(to: .now))")
    }

    private func previewText(_ document: MarkdownDocument) -> String {
        document.blocks.compactMap { block in
            guard case .markdown(let content) = block.content else { return nil }
            return String(content.characters)
        }.joined(separator: "\n")
    }
}
