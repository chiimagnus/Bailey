import AppKit
import Foundation
import XCTest
@testable import Bailey

@MainActor
final class MarkdownPreviewTests: XCTestCase {
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
