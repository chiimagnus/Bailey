import AppKit
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
final class SwiftMarkdownLayoutTests: XCTestCase {
    private func visibleRenderingWindow(width: CGFloat, height: CGFloat) throws -> NSWindow {
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame,
                                   "SwiftUI glyph layout requires a visible display")
        return NSWindow(contentRect: NSRect(x: screen.minX + 24, y: screen.minY + 24,
                                            width: width, height: height),
                        styleMask: [.titled], backing: .buffered, defer: false)
    }

    private func readerGeometry(_ scroll: NSScrollView, host: NSView, window: NSWindow) -> String {
        func bridgeCount(_ view: NSView) -> Int {
            let own = String(describing: type(of: view)).contains("MarkdownReaderClipView") ? 1 : 0
            return own + view.subviews.reduce(0) { $0 + bridgeCount($1) }
        }
        return "clip=\(scroll.contentView.bounds), document=\(scroll.documentView?.frame ?? .zero), "
            + "host=\(host.bounds), visible=\(window.isVisible), key=\(window.isKeyWindow), "
            + "scale=\(window.screen?.backingScaleFactor ?? 0), "
            + "scrollStyle=\(scroll.scrollerStyle.rawValue), preferred=\(NSScroller.preferredScrollerStyle.rawValue), "
            + "bridges=\(bridgeCount(host))"
    }

    func testPreviewScrollAlignsActualTextKitLineEvenWhenAlreadyVisible() async throws {
        let source = (0..<90).map { "Line \($0) 中文 👩‍🚀" }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).md")
        try Data(source.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        let host = NSHostingView(rootView: SourceTextEditor(
            file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            palette: .theme(dark: false), wrapLines: false, isFocused: false
        ))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
        let editor = try XCTUnwrap(scroll.documentView as? NativeCodeTextView)
        let offset = (source as NSString).range(of: "Line 40").location
        let target = NSRange(location: offset, length: 1)
        editor.scrollRangeToVisible(target)
        let layout = try XCTUnwrap(editor.textLayoutManager)
        let manager = try XCTUnwrap(editor.textContentStorage)
        let range = try XCTUnwrap(NSTextRange(target, in: manager))
        let fragment = try XCTUnwrap(layout.textLayoutFragment(for: range.location))
        let line = try XCTUnwrap(fragment.textLineFragments.first)
        let y = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
            + editor.textContainerOrigin.y
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y - 35))
        scroll.reflectScrolledClipView(clip)
        XCTAssertGreaterThan(clip.bounds.minY, 0)
        XCTAssertLessThan(clip.bounds.minY, y)
        let originalSelection = editor.selectedRange()

        XCTAssertTrue(file.editorCoordinator?.showMarkdownSource(atUTF16Offset: offset) == true)
        XCTAssertEqual(clip.bounds.minY, y, accuracy: 2,
                       "Preview-originated scrolling must align the actual source line at the viewport top")
        XCTAssertEqual(editor.selectedRange(), originalSelection,
                       "Scrolling must not move the insertion point or steal the editor selection")
    }

    func testReaderSynchronizesTwoLoadedImagesInsideOneRichParagraph() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-Markdown-Images-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for name in ["first.png", "second.png"] {
            try png.write(to: folder.appendingPathComponent(name))
        }

        let before = String(repeating: "Prefix text 🧪 with rich Unicode. ", count: 55)
        let between = String(repeating: "Intermediate words and paragraph text. ", count: 65)
        let after = String(repeating: "Remaining content after the images. ", count: 45)
        let source = before + "![First](first.png) " + between + "![Second](second.png) " + after
        let document = try await MarkdownDocument.parse(source)
        XCTAssertEqual(document.blocks.count, 1)
        let first = (source as NSString).range(of: "![First](first.png)").location
        let second = (source as NSString).range(of: "![Second](second.png)").location
        let file = folder.appendingPathComponent("Document.md")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let resource = MarkdownResource(path: file.path, directory: folder.path,
                                        backend: LocalWorkspaceBackend.shared)
        let firstPicture = try await resource.picture(XCTUnwrap(URL(string: "first.png")))
        XCTAssertEqual(firstPicture.poster.width, 320)
        func view(synced: Int?) -> MarkdownPreview {
            MarkdownPreview(document: document, revision: "image-same", resource: resource, assetRefresh: 0,
                            restoredBlock: 0, sourceBlock: 0, restoredSourceOffset: first,
                            synchronizedSourceOffset: synced)
        }

        let window = try visibleRenderingWindow(width: 320, height: 200)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view(synced: nil))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? []
                + view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(in: host).first {
            $0.contentView.bounds.width > 200 && $0.contentView.bounds.height > 100
        })
        let initial = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            scroll.contentView.bounds.minY > 100
        }, object: nil)
        await fulfillment(of: [initial], timeout: 6)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 100,
                             "First loaded image must restore to its real viewport, not paragraph top. "
                                 + readerGeometry(scroll, host: host, window: window))
        let originalY = scroll.contentView.bounds.minY

        host.rootView = view(synced: second)
        host.layoutSubtreeIfNeeded()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            scroll.contentView.bounds.minY > originalY + 150
        }, object: nil)
        await fulfillment(of: [moved], timeout: 6)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, originalY + 150,
                             "Second image in same paragraph needs its own source-mapped viewport")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    func testReaderRestoresAndSynchronizesActualCanvasFormulasWithinOneParagraph() async throws {
        let firstPart = String(repeating: "Rich 中文 text with emoji 🧪 before formula. ", count: 55)
        let middle = String(repeating: "Intermediate text with nested structures and words. ", count: 65)
        let ending = String(repeating: "Final paragraphs of the same AST block. ", count: 55)
        let source = firstPart + "$x_i+y$ " + middle + "$z^2$ " + ending
        let document = try await MarkdownDocument.parse(source)
        XCTAssertEqual(document.blocks.count, 1)
        let first = (source as NSString).range(of: "$x_i+y$").location
        let second = (source as NSString).range(of: "$z^2$").location
        let resource = MarkdownResource(path: "/tmp/Bailey-Markdown-Layout/Formula.md",
                                        directory: "/tmp/Bailey-Markdown-Layout",
                                        backend: LocalWorkspaceBackend.shared)
        func view(synced: Int?) -> MarkdownPreview {
            MarkdownPreview(document: document, revision: "same", resource: resource, assetRefresh: 0,
                            restoredBlock: 0, sourceBlock: 0, restoredSourceOffset: first,
                            synchronizedSourceOffset: synced)
        }

        let window = try visibleRenderingWindow(width: 320, height: 200)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view(synced: nil))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? []
                + view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(in: host).first {
            $0.contentView.bounds.width > 200 && $0.contentView.bounds.height > 100
        })
        let firstPosition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            scroll.contentView.bounds.minY > 100
        }, object: nil)
        await fulfillment(of: [firstPosition], timeout: 5)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 100,
                             "Canvas formula must restore its actual position, not the paragraph top. "
                                 + readerGeometry(scroll, host: host, window: window))
        let firstY = scroll.contentView.bounds.minY

        host.rootView = view(synced: second)
        host.layoutSubtreeIfNeeded()
        let secondPosition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            scroll.contentView.bounds.minY > firstY + 140
        }, object: nil)
        await fulfillment(of: [secondPosition], timeout: 5)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, firstY + 140,
                             "Source offset for another formula in the same AST block must shift the reader")
    }

    func testReaderRestoresAndTracksExactGlyphWithinOneLongParagraph() async throws {
        let source = (0..<150).map { "token-\($0) 中文 👩‍🚀" }.joined(separator: " ")
        let parsed = try await MarkdownDocument.parse(source)
        XCTAssertEqual(parsed.blocks.count, 1)
        let first = (source as NSString).range(of: "token-50").location
        let second = (source as NSString).range(of: "token-110").location
        let resource = MarkdownResource(path: "/tmp/Bailey-Markdown-Layout/Source.md",
                                        directory: "/tmp/Bailey-Markdown-Layout",
                                        backend: LocalWorkspaceBackend.shared)
        func view(sourceOffset: Int?) -> MarkdownPreview {
            MarkdownPreview(document: parsed, revision: "same", resource: resource, assetRefresh: 0,
                            restoredBlock: 0, sourceBlock: 0, restoredSourceOffset: first,
                            synchronizedSourceOffset: sourceOffset,
                            onLocateSource: { _ in })
        }

        let window = try visibleRenderingWindow(width: 320, height: 200)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view(sourceOffset: nil))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? []
                + view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(in: host).first {
            $0.contentView.bounds.width > 200 && $0.contentView.bounds.height > 100
        })
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            scroll.contentView.bounds.minY > 75
        }, object: nil)
        await fulfillment(of: [restored], timeout: 4)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 75,
                             "Restoration must reach the glyph inside the first paragraph. "
                                 + readerGeometry(scroll, host: host, window: window))
        let initialY = scroll.contentView.bounds.minY

        // Native relayout can reset the clip without a user scroll gesture.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            scroll.contentView.bounds.minY > 75
        }, object: nil)
        await fulfillment(of: [recovered], timeout: 4)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 75,
                             "A native clip reset must not discard the pending source anchor")

        host.rootView = view(sourceOffset: second)
        host.layoutSubtreeIfNeeded()
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            scroll.contentView.bounds.minY > initialY + 75
        }, object: nil)
        await fulfillment(of: [advanced], timeout: 4)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, initialY + 75,
                             "Source offsets changing inside the same block must move the reader viewport")
    }

    func testMarkdownSourceReportsDifferentUTF16OffsetsInsideOneWrappedParagraph() async throws {
        let source = String(repeating: "Long 中文 👩‍🚀 wrapped source text ", count: 160)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).md")
        try Data(source.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.markdownSourceIndex = (file.markdownRequestID, MarkdownBlockIndex(
            try await MarkdownDocument.parse(source)
        ))
        let host = NSHostingView(rootView: SourceTextEditor(
            file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            palette: .theme(dark: false), wrapLines: true, isFocused: false
        ))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 270, height: 175),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
        let editor = try XCTUnwrap(scroll.documentView as? NativeCodeTextView)
        let layout = editor.nativeLayoutManager
        let start = editor.nativeContentManager.documentRange.location
        let initial = try XCTUnwrap(layout.textLayoutFragment(for: start))
        let lines = initial.textLineFragments
        XCTAssertGreaterThan(lines.count, 36, "The single paragraph must wrap into many visual lines")
        var previous = -1
        for lineIndex in [15, 35] {
            let expected = lines[lineIndex].characterRange.location
            editor.scrollRangeToVisible(NSRange(location: expected, length: 0))
            let location = try XCTUnwrap(editor.nativeContentManager.location(start, offsetBy: expected))
            let currentFragment = try XCTUnwrap(layout.textLayoutFragment(for: location))
            let relative = editor.nativeContentManager.offset(
                from: currentFragment.rangeInElement.location, to: location
            )
            let visualLines = currentFragment.textLineFragments
            let selected = try XCTUnwrap(visualLines.firstIndex {
                $0.characterRange.location <= relative && NSMaxRange($0.characterRange) > relative
            })
            let bottom = visualLines[selected].typographicBounds.maxY
            let previousBottom = selected == 0 ? visualLines[selected].typographicBounds.minY
                : visualLines[selected - 1].typographicBounds.maxY
            let y = currentFragment.layoutFragmentFrame.minY
                + (previousBottom + bottom) / 2 + editor.textContainerOrigin.y
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
            layout.textViewportLayoutController.layoutViewport()
            await Task.yield()
            XCTAssertEqual(clip.bounds.minY, y, accuracy: 2,
                           "The requested wrapped line must reach the viewport; document height: \(scroll.documentView?.frame.height ?? -1)")
            let visibleLineStart = visualLines[selected].characterRange.location
            XCTAssertEqual(file.markdownSourceOffset, visibleLineStart,
                           "Use the actual first visible glyph line after TextKit reflows the paragraph")
            XCTAssertGreaterThan(visibleLineStart, previous,
                                 "Scrolling within one AST paragraph must update its source coordinate")
            previous = visibleLineStart
        }
    }

    func testMarkdownSourceSynchronizationUsesTheActuallyVisibleNativeLine() async throws {
        let source = (0..<64).map { index in
            "# Section \(index)\n\n" + String(repeating: "长行 👩‍🚀 Markdown 字符 ", count: 12)
        }.joined(separator: "\n\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).md")
        try Data(source.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await MarkdownDocument.parse(source)
        let expectedBlock = try XCTUnwrap(document.blocks.firstIndex { $0.anchor == "section-32" })
        let expectedSource = try XCTUnwrap(document.blocks[expectedBlock].sourceRange)
        for wraps in [false, true] {
            let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await file.waitForText()
            file.markdownSourceIndex = (file.markdownRequestID, MarkdownBlockIndex(document))
            let host = NSHostingView(rootView: SourceTextEditor(
                file: file, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                palette: .theme(dark: false), wrapLines: wraps, isFocused: false
            ))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 260, height: 170),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
            let editor = try XCTUnwrap(scroll.documentView as? NativeCodeTextView)
            let target = NSRange(location: expectedSource.location, length: 1)
            editor.scrollRangeToVisible(target)
            let layout = editor.nativeLayoutManager
            layout.textViewportLayoutController.layoutViewport()
            let range = try XCTUnwrap(NSTextRange(target, in: editor.nativeContentManager))
            let fragment = try XCTUnwrap(layout.textLayoutFragment(for: range.location))
            let line = try XCTUnwrap(fragment.textLineFragments.first)
            let targetY = fragment.layoutFragmentFrame.minY + line.typographicBounds.midY
                + editor.textContainerOrigin.y
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: targetY))
            scroll.reflectScrolledClipView(clip)
            layout.textViewportLayoutController.layoutViewport()
            XCTAssertEqual(clip.bounds.minY, targetY, accuracy: 1)
            await Task.yield()
            XCTAssertEqual(file.markdownSourceOffset, expectedSource.location,
                           "Report the exact visible UTF-16 offset, not a prefetched block (wraps: \(wraps))")
        }
    }

    func testRenderedGlyphIndicesMeasureUTF16AcrossEmojiAndCombiningText() async {
        let literal = "A👩‍🚀e\u{301}Z"
        var measured: [Int] = []
        let view = Text(verbatim: literal)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                let indices = layouts.flatMap { entry in
                    entry.layout.flatMap { line in
                        line.flatMap { run in run.flatMap(\.characterIndices) }
                    }
                }
                let first = indices.min()
                let offsets = first.map { start in
                    Set(indices.map { start.distance(to: $0) }).sorted()
                } ?? []
                Color.clear.preference(key: MarkdownGlyphOffsets.self, value: offsets)
            }
            .onPreferenceChange(MarkdownGlyphOffsets.self) { measured = $0 }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
        }
        XCTAssertEqual(measured.last, literal.dropLast().utf16.count)
        XCTAssertTrue(measured.contains("A👩‍🚀".utf16.count))
    }

    private struct MarkdownGlyphOffsets: PreferenceKey {
        static let defaultValue: [Int] = []

        static func reduce(value: inout [Int], nextValue: () -> [Int]) {
            value.append(contentsOf: nextValue())
        }
    }

    func testWrappedLinkPointerRegionsFollowNativeWindowResizing() async throws {
        func descendants(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let title = Array(repeating: "GitHub 中文 Unicode link", count: 36)
            .joined(separator: " ")
        let document = try await MarkdownDocument.parse("[\(title)](docs/guide.md)")
        let preview = MarkdownPreview(
            document: document, revision: "resize-link",
            resource: MarkdownResource(path: "/tmp/Bailey-Markdown-Layout/Resize.md",
                                       directory: "/tmp/Bailey-Markdown-Layout",
                                       backend: LocalWorkspaceBackend.shared),
            assetRefresh: 0
        )
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 280, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: preview)
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        var lineCountByWidth: [Int] = []
        for width in [280, 640, 340] {
            window.setContentSize(NSSize(width: width, height: 500))
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await Task.yield()
            }
            let overlay = try XCTUnwrap(descendants(in: host)
                .compactMap { $0 as? MarkdownCursorRectView }.first)
            let clip = try XCTUnwrap(descendants(in: host)
                .compactMap { $0 as? NSClipView }.first(where: {
                    guard let documentView = $0.documentView else { return false }
                    return overlay.isDescendant(of: documentView)
                }))
            let content = try XCTUnwrap(clip.documentView)
            let registered = content.trackingAreas.filter {
                ($0.owner as? MarkdownCursorRectView) === overlay
            }
            XCTAssertEqual(registered.count, overlay.linkRects.count,
                           "Every visible wrapped link line must have an exact cursor region")
            XCTAssertGreaterThan(overlay.linkRects.count, 1)
            for (source, area) in zip(overlay.linkRects, registered) {
                let expected = overlay.convert(source, to: content)
                XCTAssertEqual(expected.minX, area.rect.minX, accuracy: 1)
                XCTAssertEqual(expected.minY, area.rect.minY, accuracy: 1)
            }
            lineCountByWidth.append(registered.count)
        }
        XCTAssertGreaterThan(lineCountByWidth[0], lineCountByWidth[1],
                             "Narrow Markdown must wrap links into more cursor regions")
        XCTAssertGreaterThan(lineCountByWidth[2], lineCountByWidth[1],
                             "Shrinking again must rebuild the true native link bounds")
    }

    func testLinkCursorRectsRemainAlignedAfterScrollingOneLargeParagraph() async throws {
        func descendants(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }

        let source = "[Start](guide.md) "
            + String(repeating: "word mixed Unicode 中文 café ", count: 450)
            + " [Finish](guide.md)"
        let document = try await MarkdownDocument.parse(source)
        let preview = MarkdownPreview(
            document: document, revision: "scroll-link",
            resource: MarkdownResource(path: "/tmp/Bailey-Markdown-Layout/Long.md",
                                       directory: "/tmp/Bailey-Markdown-Layout",
                                       backend: LocalWorkspaceBackend.shared),
            assetRefresh: 0
        )
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 440, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: preview)
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
        }
        let overlay = try XCTUnwrap(descendants(in: host)
            .compactMap { $0 as? MarkdownCursorRectView }.first)
        XCTAssertEqual(overlay.linkRects.count, 2)
        var ancestor: NSView? = overlay.superview
        while let view = ancestor, !(view is NSClipView) {
            ancestor = view.superview
        }
        let trackingSurface = try XCTUnwrap((ancestor as? NSClipView)?.documentView)

        func checkAlignment(_ stage: String) {
            let expected = overlay.linkRects
                .map { overlay.convert($0, to: trackingSurface) }
                .sorted { $0.minY < $1.minY }
            let actual = trackingSurface.trackingAreas
                .filter { ($0.owner as? MarkdownCursorRectView) === overlay }
                .map(\.rect)
                .sorted { $0.minY < $1.minY }
            XCTAssertEqual(actual.count, expected.count,
                           "Tracked link areas must follow both actual glyph runs at \(stage)")
            for (found, target) in zip(actual, expected) {
                XCTAssertEqual(found.minX, target.minX, accuracy: 1,
                               "Stale horizontal link cursor range at \(stage)")
                XCTAssertEqual(found.minY, target.minY, accuracy: 1,
                               "Stale vertical link cursor range at \(stage)")
                XCTAssertEqual(found.width, target.width, accuracy: 1)
                XCTAssertEqual(found.height, target.height, accuracy: 1)
            }
        }
        checkAlignment("first frame")
        let scroll = try XCTUnwrap(descendants(in: host)
            .compactMap { $0 as? NSScrollView }.first(where: {
                $0.contentView.bounds.height > 100 && $0.contentView.bounds.width > 150
            }))
        let content = try XCTUnwrap(scroll.documentView)
        let bottom = content.frame.height - scroll.contentView.bounds.height
        XCTAssertGreaterThan(bottom, 100)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
        }
        checkAlignment("after scrolling without changing the Markdown text")
    }

    func testLongLinkedDocumentsKeepCursorTrackingBoundedWhileScrolling() async throws {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrollViews)
        }

        let resource = MarkdownResource(
            path: "/tmp/Bailey-Markdown-Layout/Links.md",
            directory: "/tmp/Bailey-Markdown-Layout",
            backend: LocalWorkspaceBackend.shared
        )
        for count in [500, 5_000, 20_000] {
            let source = (0..<count)
                .map { "Paragraph \($0) [document \($0)](docs/\($0).md) **highlighted**." }
                .joined(separator: "\n\n")
            let document = try await MarkdownDocument.parse(source)
            XCTAssertEqual(document.blocks.count, count)
            let window = NSWindow(
                contentRect: NSRect(x: -2000, y: -2000, width: 720, height: 420),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MarkdownPreview(
                document: document, revision: "\(count)",
                resource: resource, assetRefresh: 0
            ))
            host.sizingOptions = []
            window.contentView = host
            window.orderFront(nil)

            let clock = ContinuousClock()
            let start = clock.now
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let first = start.duration(to: clock.now)
            func cursorTrackingCount(in view: NSView) -> Int {
                view.trackingAreas.filter { $0.owner is MarkdownCursorRectView }.count
                    + view.subviews.reduce(0) { $0 + cursorTrackingCount(in: $1) }
            }
            let tracking = { cursorTrackingCount(in: host) }
            XCTAssertGreaterThan(tracking(), 0,
                                 "A visible linked paragraph needs native hand-pointer tracking")
            XCTAssertLessThanOrEqual(tracking(), 256,
                                     "A long document must not register a tracking area for every link")
            guard let scroll = scrollViews(in: host).first(where: {
                $0.contentView.bounds.height > 200 && $0.contentView.bounds.width > 200
            }), let content = scroll.documentView else {
                window.close()
                return XCTFail("Expected scrollable Markdown content at \(count) paragraphs")
            }
            let bottom = max(0, content.frame.height - scroll.contentView.bounds.height)
            let scrollStart = clock.now
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let scrolling = scrollStart.duration(to: clock.now)
            XCTAssertLessThanOrEqual(tracking(), 256,
                                     "Old link hover areas must be replaced after scrolling")
            print("SWIFTMARKDOWN_LINKS paragraphs=\(count) first=\(first) "
                + "scroll=\(scrolling) tracking=\(tracking())")
            window.close()
        }
    }

    func testLinkPointerRectanglesComeFromVisibleSwiftUITextRuns() async throws {
        let document = try await MarkdownDocument.parse(
            "Before [**linked text**](guide.md) and after.\n\nAnother paragraph."
        )
        let preview = MarkdownPreview(
            document: document, revision: "link-rect",
            resource: MarkdownResource(path: "/tmp/Bailey-Markdown-Layout/Pointer.md",
                                       directory: "/tmp/Bailey-Markdown-Layout",
                                       backend: LocalWorkspaceBackend.shared),
            assetRefresh: 0
        )
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 720, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(preview))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        func cursorViews(in view: NSView) -> [MarkdownCursorRectView] {
            let own = (view as? MarkdownCursorRectView).map { [$0] } ?? []
            return own + view.subviews.flatMap(cursorViews)
        }
        var overlays: [MarkdownCursorRectView] = []
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            overlays = cursorViews(in: host)
            if overlays.contains(where: { !$0.linkRects.isEmpty }) { break }
            await Task.yield()
        }
        XCTAssertFalse(overlays.isEmpty, "SwiftUI must host an AppKit cursor-rect overlay")
        let glyphRects = overlays.flatMap(\.linkRects)
        XCTAssertFalse(glyphRects.isEmpty,
                       "Text.Layout must expose exact linked text run bounds")
        for overlay in overlays {
            XCTAssertGreaterThan(overlay.bounds.width, 0)
            XCTAssertGreaterThan(overlay.bounds.height, 0)
            for rect in overlay.linkRects {
                XCTAssertGreaterThan(rect.width, 0)
                XCTAssertGreaterThan(rect.height, 0)
                XCTAssertTrue(overlay.bounds.intersects(rect), "Link glyph must be inside active cursor-rect view")
            }
        }
        func activeLinkAreas(in view: NSView) -> [NSTrackingArea] {
            view.trackingAreas.filter { $0.owner is MarkdownCursorRectView }
                + view.subviews.flatMap(activeLinkAreas)
        }
        XCTAssertFalse(activeLinkAreas(in: host).isEmpty,
                       "Link hover must be tracked in its scrolling content coordinates")
        host.rootView = AnyView(Text("New document without Markdown links"))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertTrue(activeLinkAreas(in: host).isEmpty,
                      "Switching documents must release the old link tracking areas")
    }

    func testGitHubStylePreviewRendersAcrossLightDarkAndNarrowWidths() async throws {
        let markdown = """
            # Repository README

            > [!NOTE]
            > 本文包含 mixed Latin, 中文, and emoji 🧪.

            > [!TIP]
            > Read the examples first.

            > [!IMPORTANT]
            > Use the same source for preview and editing.

            > [!WARNING]
            > Long links and tables should not scroll the whole page sideways.

            > [!CAUTION]
            > Read-only tasks must not edit the document.

            A paragraph with **strong emphasis**, *italic*, ~~strike~~,
            `inline code`, and [**styled link**](docs/guide.md).

            ## Installation

            > Important: GitHub-flavored Markdown must remain readable with long quoted text
            > and links to [documentation](docs/guide.md).

            - [x] Completed task
            - [ ] Pending task
            - Nested list item **keeps bold**

            | File | Status | Comment |
            | :--- | :---: | ---: |
            | README.md | Ready | Excellent |
            | AGENTS.md | Review | Pending |

            ```swift
            let answer = 42
            print(answer)
            ```

            ### Additional notes

            The preview remains native, selectable, and keyboard accessible.
            """
        let document = try await MarkdownDocument.parse(markdown)
        let resource = MarkdownResource(
            path: "/tmp/Bailey-Markdown-Primer/README.md",
            directory: "/tmp/Bailey-Markdown-Primer",
            backend: LocalWorkspaceBackend.shared
        )
        for (dimension, dark) in [(960.0, false), (960.0, true),
                                  (340.0, false), (340.0, true)] {
            let width = CGFloat(dimension)
            let window = NSWindow(
                contentRect: NSRect(x: -2000, y: -2000, width: width, height: 620),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let view = MarkdownPreview(document: document, revision: "README",
                                       resource: resource, assetRefresh: 0)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let screenshot = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: screenshot, uniformTypeIdentifier: "public.png")
            attachment.name = "GitHub README \(Int(width))pt \(dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
            let expectedRails: [UInt32] = dark
                ? [0x4493F8, 0x3FB950, 0xAB7DF8, 0xD29922, 0xF85149]
                : [0x0969DA, 0x1A7F37, 0x8250DF, 0x9A6700, 0xD1242F]
            let input = try XCTUnwrap(bitmap.cgImage)
            let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(
                data: nil, width: input.width, height: input.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(input, in: CGRect(x: 0, y: 0, width: input.width, height: input.height))
            let normalized = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            let actualCanvas = try XCTUnwrap(normalized.colorAt(x: 5, y: normalized.pixelsHigh - 5))
            let themeCanvas = try XCTUnwrap(Theme.terminal(dark: dark).backgroundNSColor.usingColorSpace(.sRGB))
            XCTAssertEqual(actualCanvas.redComponent, themeCanvas.redComponent, accuracy: 0.025)
            XCTAssertEqual(actualCanvas.greenComponent, themeCanvas.greenComponent, accuracy: 0.025)
            XCTAssertEqual(actualCanvas.blueComponent, themeCanvas.blueComponent, accuracy: 0.025)
            let inset = width < 768 ? 17.0 : 47.0
            let railX = Int(inset * CGFloat(normalized.pixelsWide) / width)
            for color in expectedRails {
                let red = CGFloat((color >> 16) & 255) / 255
                let green = CGFloat((color >> 8) & 255) / 255
                let blue = CGFloat(color & 255) / 255
                let painted = (0..<normalized.pixelsHigh).count { row in
                    guard let actual = normalized.colorAt(x: railX, y: row) else {
                        return false
                    }
                    return abs(actual.redComponent - red) < 0.025
                        && abs(actual.greenComponent - green) < 0.025
                        && abs(actual.blueComponent - blue) < 0.025
                }
                XCTAssertGreaterThan(painted, 20, "Missing GitHub Alert \(String(color, radix: 16)) at \(width)pt dark=\(dark)")
            }
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            window.close()
        }
    }

    func testRepositoryDocumentationRendersWithoutLosingContentInNarrowAndWideDocks() async throws {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrollViews)
        }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relativePath in ["AGENTS.md", "docs/testing.md", "docs/features/editor.md"] {
            let url = repository.appendingPathComponent(relativePath)
            let original = try Data(contentsOf: url)
            let source = try XCTUnwrap(String(data: original, encoding: .utf8))
            let document = try await MarkdownDocument.parse(source)
            XCTAssertGreaterThan(document.blocks.count, 10, relativePath)
            XCTAssertTrue(document.blocks.contains {
                if case .heading = $0.content { return true }
                return false
            }, "Actual documentation must retain its headings: \(relativePath)")

            let resource = MarkdownResource(
                path: url.path, directory: url.deletingLastPathComponent().path,
                backend: LocalWorkspaceBackend.shared
            )
            for (width, dark) in [(340.0, false), (960.0, true)] {
                let window = NSWindow(
                    contentRect: NSRect(x: -2000, y: -2000, width: width, height: 620),
                    styleMask: [.titled], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: MarkdownPreview(
                    document: document, revision: relativePath,
                    resource: resource, assetRefresh: 0
                ).environment(\.colorScheme, dark ? .dark : .light))
                host.sizingOptions = []
                window.contentView = host
                window.orderFront(nil)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()

                let scroll = try XCTUnwrap(scrollViews(in: host).first {
                    $0.contentView.bounds.width > 200 && $0.contentView.bounds.height > 200
                }, "Actual Markdown requires a scrollable content surface: \(relativePath)")
                let content = try XCTUnwrap(scroll.documentView)
                XCTAssertGreaterThan(content.frame.height, scroll.contentView.bounds.height,
                                     "Actual documentation should scroll: \(relativePath)")
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let snapshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                snapshot.name = "Real \(relativePath) \(Int(width))pt \(dark ? "dark" : "light")"
                snapshot.lifetime = .keepAlways
                add(snapshot)

                let bottom = content.frame.height - scroll.contentView.bounds.height
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0,
                                     "A long real Markdown file must reach its final blocks")
                window.close()
            }
            XCTAssertEqual(try Data(contentsOf: url), original,
                           "Rendering actual documentation must never change its bytes")
        }
    }

    func testWideGFMTableScrollsHorizontallyWithoutExpandingTheDocument() async throws {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrollViews)
        }
        let wideCell = String(repeating: "UNBREAKABLECOLUMN", count: 40)
        let source = [
            "# Wide GFM table", "",
            "| Kind | Long description | Status |",
            "| --- | --- | --- |",
            "| Markdown | \(wideCell) | Ready |"
        ].joined(separator: "\n")
        let document = try await MarkdownDocument.parse(source)
        let resource = MarkdownResource(
            path: "/tmp/Bailey-Markdown-Layout/Wide.md",
            directory: "/tmp/Bailey-Markdown-Layout",
            backend: LocalWorkspaceBackend.shared
        )
        for width in [340.0, 520.0] {
            let window = NSWindow(
                contentRect: NSRect(x: -2000, y: -2000, width: width, height: 620),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MarkdownPreview(
                document: document, revision: source,
                resource: resource, assetRefresh: 0
            ))
            host.sizingOptions = []
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let candidates = scrollViews(in: host)
            guard let horizontal = candidates.first(where: {
                guard let documentView = $0.documentView else { return false }
                return $0.contentView.bounds.width < width - 10
                    && documentView.frame.width > $0.contentView.bounds.width + 100
            }) else {
                window.close()
                return XCTFail("Wide GFM table must have its own scrollable width at \(Int(width))pt")
            }
            guard let documentView = horizontal.documentView else {
                window.close()
                return XCTFail("Missing GFM table scroll content")
            }
            let right = documentView.frame.width - horizontal.contentView.bounds.width
            horizontal.contentView.scroll(to: NSPoint(x: right, y: 0))
            horizontal.reflectScrolledClipView(horizontal.contentView)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertGreaterThan(horizontal.contentView.bounds.minX, 100,
                                 "The last table column must remain reachable at \(Int(width))pt")
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            window.close()
        }
    }

    func testNativePreviewFirstFrameAndLongDocumentScrolling() async throws {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrollViews)
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bailey-Markdown-Mixed-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="80" height="32"><rect width="80" height="32" fill="#0969da"/></svg>
            """
        try Data(svg.utf8).write(to: folder.appendingPathComponent("asset.svg"))
        let resource = MarkdownResource(path: folder.appendingPathComponent("README.md").path,
                                        directory: folder.path, backend: LocalWorkspaceBackend.shared)
        for count in [500, 5_000, 20_000] {
            var lines: [String] = []
            func section(_ index: Int) -> [String] {
                [
                    "## Section \(index) 中文 🧪", "",
                    "Paragraph e\u{301} [anchor](#section-0-中文-) with $x_i+y$ and **emphasis**.", "",
                    "> [!NOTE]", "> A mixed-content reading fixture.", "",
                    "- [x] Checked", "  - Nested step", "",
                    "| 名称 | Value |", "| --- | ---: |", "| العربية | \(index) |", "",
                    "```swift", "let sample = \(index)", "```", "",
                    "<details>", "<summary>Method</summary>", "<p>HTML &amp; text</p>", "</details>", "",
                    index.isMultiple(of: 4) ? "![Scoped SVG](asset.svg)" : "![Missing resource](missing.png)", ""
                ]
            }
            let sectionHeight = section(0).count
            for index in 0..<((count - 1) / sectionHeight) {
                lines += section(index)
            }
            while lines.count < count - 1 { lines.append("") }
            lines.append("## End marker")
            let text = lines.joined(separator: "\n")
            let clock = ContinuousClock()
            let parseStart = clock.now
            let document = try await MarkdownDocument.parse(text)
            let parse = parseStart.duration(to: clock.now)
            XCTAssertEqual(document.headingOutline.last?.title, "End marker")
            XCTAssertEqual(document.headingOutline.count, (count - 1) / sectionHeight + 1)
            let preview = MarkdownPreview(document: document, revision: "0",
                                          resource: resource, assetRefresh: 0)
                .environment(\.colorScheme, .dark)
            let window = NSWindow(
                contentRect: NSRect(x: -2000, y: -2000, width: 340, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: preview)
            host.sizingOptions = []
            let start = clock.now
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let first = start.duration(to: clock.now)
            guard let scroll = scrollViews(in: host).first(where: {
                $0.contentView.bounds.height > 200 && $0.contentView.bounds.width > 200
            }), let content = scroll.documentView else {
                window.close()
                return XCTFail("Expected a native scroll container at \(count) paragraphs")
            }
            XCTAssertGreaterThan(content.frame.height, scroll.contentView.bounds.height,
                                 "Lazy preview must be scrollable at \(count) mixed lines")
            var warm: [Duration] = []
            for sample in 1...30 {
                let warmStart = clock.now
                scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(sample * 124)))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                warm.append(warmStart.duration(to: clock.now))
            }
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1000)
            let scrollStart = clock.now
            let endHeading = try XCTUnwrap(document.headingOutline.last)
            host.rootView = MarkdownPreview(document: document, revision: "0",
                                            resource: resource, assetRefresh: 0,
                                            sourceBlock: endHeading.blockIndex,
                                            synchronizedSourceOffset: endHeading.identity.offset)
                .environment(\.colorScheme, .dark)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let atEnd = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                scroll.contentView.bounds.minY > content.frame.height - 2 * scroll.contentView.bounds.height
            }, object: nil)
            await fulfillment(of: [atEnd], timeout: 5)
            let scrolling = scrollStart.duration(to: clock.now)
            XCTAssertGreaterThan(scroll.contentView.bounds.maxY,
                                 content.frame.height - scroll.contentView.bounds.height,
                                 "Jump into the final viewport even if the lazy height estimate is revised")
            warm.sort()
            var usage = rusage()
            _ = getrusage(RUSAGE_SELF, &usage)
            print("SWIFTMARKDOWN_LAYOUT mixed_lines=\(count) width=340 dark=true parse=\(parse) first=\(first) "
                    + "jump_end=\(scrolling) warm_p50=\((warm[14] + warm[15]) / 2) warm_p95=\(warm[28]) worst=\(warm[29]) "
                    + "process_peak_rss_mib=\(Double(usage.ru_maxrss) / 1_048_576)")
            window.close()
        }
    }
}
