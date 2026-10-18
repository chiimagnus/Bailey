import AppKit
import STTextKitPlus
import STTextView
import SwiftUI
import XCTest
@testable import STTextViewAppKit
@testable import Bailey

@MainActor
final class EditorNavigationTests: XCTestCase {
    func testCurrentSourceFileKeepsGeometry() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Bailey/Files/FileTreeModel.swift")
        let source = try String(contentsOf: sourceFile, encoding: .utf8)
        let (window, editor) = mount(source, font: TerminalFont.resolve(family: "", size: 13))
        defer { window.close() }
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        var heights: [CGFloat] = []
        for fraction in [0, 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - 600) * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            editor.prepareContent(in: editor.visibleRect)
            editor.layoutSubtreeIfNeeded()
            heights.append(editor.frame.height)
            let point = window.convertPoint(toScreen: editor.convert(NSPoint(x: 110, y: editor.visibleRect.minY + 200), to: nil))
            let offset = editor.characterIndex(for: point)
            XCTAssertNotEqual(offset, NSNotFound)
            let rect = editor.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
            XCTAssertTrue(rect.minY.isFinite)
        }
        XCTAssertEqual(try XCTUnwrap(heights.max()), try XCTUnwrap(heights.min()), accuracy: 1)
        print("EDITOR_CURRENT_FILE heights=\(heights)")
    }

    func testGutterParagraphNumbersMatchNativeElementsAcrossSeparators() throws {
        for separator in ["\n", "\r\n", "\r", "\u{2029}", "\u{2028}x\n"] {
            let source = (0..<1_000).map { "let value\($0) = 1" + separator }.joined()
            for wraps in [false, true] {
                let (window, editor) = mount(source, font: TerminalFont.resolve(family: "", size: 13), width: 280, wraps: wraps)
                defer { window.close() }
                var offsets: [Int] = []
                editor.textContentManager.enumerateTextElements(from: editor.textContentManager.documentRange.location) { element in
                    if let range = element.elementRange {
                        offsets.append(editor.textContentManager.offset(from: editor.textContentManager.documentRange.location,
                                                                        to: range.location))
                    }
                    return true
                }
                let scroll = try XCTUnwrap(editor.enclosingScrollView)
                for fraction in [0, 0.25, 0.5, 0.75, 1, 0.5, 0] {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - 600) * fraction))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    editor.prepareContent(in: editor.visibleRect)
                    editor.layoutSubtreeIfNeeded()
                    let index = try XCTUnwrap(editor.textLineIndex)
                    for (paragraph, offset) in offsets.enumerated() {
                        XCTAssertEqual(index.paragraph(at: offset), paragraph, "separator=\(separator.debugDescription)")
                    }
                    let gutter = try XCTUnwrap(editor.gutterView)
                    let cells = gutter.containerView.subviews.compactMap { $0 as? STGutterLineNumberCell }
                    XCTAssertFalse(cells.isEmpty)
                    for cell in cells where cell.lineNumber <= offsets.count {
                        let range = NSRange(location: offsets[cell.lineNumber - 1], length: 0)
                        let rect = editor.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
                        XCTAssertEqual(editor.convert(cell.bounds, from: cell).minY, rect.minY, accuracy: 1)
                    }
                }
            }
        }
    }

    func testAvailableEditorFontsKeepNaturalUniformGeometry() async throws {
        let source = (0..<382).map { "let item\($0) = 1 // " + String(repeating: "wide", count: $0 % 43) }.joined(separator: "\n")
        let fonts = TerminalFont.selectableFamilies().map { TerminalFont.resolve(family: $0, size: 13) } + [TerminalFont.current()]
        for font in fonts {
            let (window, editor) = mount(source, font: font)
            defer { window.close() }
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            var heights: [CGFloat] = []
            for fraction in [0, 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - 600) * fraction))
                scroll.reflectScrolledClipView(scroll.contentView)
                editor.prepareContent(in: editor.visibleRect)
                editor.layoutSubtreeIfNeeded()
                heights.append(editor.frame.height)
            }
            var advances = Set<CGFloat>()
            editor.textLayoutManager.enumerateTextLayoutFragments(from: editor.textContentManager.documentRange.location,
                                                                  options: [.ensuresLayout]) { fragment in
                XCTAssertFalse(fragment.textLineFragments.isEmpty)
                advances.insert(fragment.layoutFragmentFrame.height / CGFloat(max(1, fragment.textLineFragments.count)))
                return true
            }
            print("EDITOR_FONT name=\(font.fontName) size=\(font.pointSize) advances=\(advances) heights=\(heights)")
            if advances.count == 1 {
                XCTAssertEqual(try XCTUnwrap(heights.max()), try XCTUnwrap(heights.min()), accuracy: 1)
            }
            await Task.yield()
        }
    }

    func testVariableHeightUndoAndDeleteAllKeepGeometryValid() async throws {
        let source = (0..<1_000).map { row in
            row % 3 == 0 ? "" : "let value = 1 // " + String(repeating: "wide", count: row % 43)
        }.joined(separator: "\n")
        let (window, editor) = mount(source, font: TerminalFont.resolve(family: "", size: 13))
        defer { window.close() }
        editor.replaceCharacters(in: NSRange(location: 0, length: 0), with: NSAttributedString(
            string: "tall\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 32, weight: .regular)]))
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.hasVariableLineHeight)
        editor.undoManager?.undo()
        editor.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.text, source)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        var heights: [CGFloat] = []
        for fraction in [0, 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - 600) * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            editor.prepareContent(in: editor.visibleRect)
            editor.layoutSubtreeIfNeeded()
            heights.append(editor.frame.height)
        }
        XCTAssertEqual(try XCTUnwrap(heights.max()), try XCTUnwrap(heights.min()), accuracy: 1)
        guard try await reveal(NSRange(location: source.utf16.count - 1, length: 1), in: editor) else { return }
        editor.insertText("x", replacementRange: NSRange(location: 0, length: source.utf16.count))
        editor.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.text, "x")
        XCTAssertGreaterThanOrEqual(editor.frame.height, scroll.contentView.bounds.height)
        editor.undoManager?.undo()
        editor.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.text, source)
    }

    func testSourceRestoresAndResizesLogicalViewport() async throws {
        let line = "let value = 1 // " + String(repeating: "wide", count: 40) + "\n"
        let source = String(repeating: line, count: 1_000)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data(source.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.editorState.scrollY = 5_000
        let host = NSHostingView(rootView: SourceTextEditor(
            file: file, font: TerminalFont.resolve(family: "", size: 13), palette: .theme(dark: true),
            wrapLines: false, isFocused: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func settle(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !predicate() {
                guard Date() < deadline else {
                    let scroll = file.editorView as? NSScrollView
                    let editor = scroll?.documentView as? STTextView
                    XCTFail("Source geometry did not settle: clip=\(String(describing: scroll?.contentView.bounds)) frame=\(String(describing: editor?.frame)) uniform=\(String(describing: editor?.uniformLineHeight)) variable=\(String(describing: editor?.hasVariableLineHeight)) rows=\(String(describing: editor?.textLineIndex?.lineCount))")
                    throw WorkspaceError.timedOut
                }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        try await settle {
            guard let scroll = file.editorView as? NSScrollView,
                  let editor = scroll.documentView as? STTextView else { return false }
            return scroll.contentView.bounds.height > 100 && editor.uniformDocumentHeight != nil
                && abs(scroll.contentView.bounds.minY - 5_000) <= 1
        }
        let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
        let editor = try XCTUnwrap(scroll.documentView as? STTextView)
        let height = try XCTUnwrap(editor.uniformLineHeight)
        for size in [NSSize(width: 280, height: 300), NSSize(width: 900, height: 700), NSSize(width: 900, height: 600)] {
            editor.viewWillStartLiveResize()
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            editor.viewDidEndLiveResize()
            scroll.viewDidEndLiveResize()
            try await settle {
                abs(scroll.bounds.width - size.width) <= 1 && abs(scroll.contentView.bounds.minY - 5_000) <= 1
                    && abs((scroll.verticalScroller?.frame.maxX ?? -1) - scroll.bounds.maxX) <= 1
            }
            editor.layoutSubtreeIfNeeded()
            let row = Int((scroll.contentView.bounds.minY + 100) / height)
            let range = NSRange(location: row * line.utf16.count, length: 0)
            let rect = editor.firstRect(forCharacterRange: range, actualRange: nil)
            let documentRect = editor.convert(window.convertFromScreen(rect), from: nil)
            XCTAssertEqual(documentRect.minY, CGFloat(row) * height, accuracy: 1)
            XCTAssertEqual(editor.characterIndex(for: NSPoint(x: rect.minX + 1, y: rect.midY)), range.location)
            XCTAssertTrue(file.editorView === scroll)
            XCTAssertEqual(scroll.verticalScroller?.frame.maxX ?? -1, scroll.bounds.maxX, accuracy: 1)
        }
        let anchor = NSRange(location: Int(scroll.contentView.bounds.minY / height) * line.utf16.count, length: 0)
        let before = editor.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: anchor, actualRange: nil)), from: nil)
        let offset = before.minY - scroll.contentView.bounds.minY
        for size: CGFloat in [32, 8, 13] {
            host.rootView = SourceTextEditor(file: file, font: TerminalFont.resolve(family: "", size: size),
                                             palette: .theme(dark: true), wrapLines: false, isFocused: false)
            try await settle { editor.font.pointSize == size && editor.uniformDocumentHeight != nil }
            editor.layoutSubtreeIfNeeded()
            let rect = editor.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: anchor, actualRange: nil)), from: nil)
            XCTAssertEqual(rect.minY - scroll.contentView.bounds.minY, offset, accuracy: 1)
            XCTAssertTrue(file.editorView === scroll)
        }
        for wraps in [true, false, true, false] {
            host.rootView = SourceTextEditor(file: file, font: TerminalFont.resolve(family: "", size: 13),
                                             palette: .theme(dark: true), wrapLines: wraps, isFocused: false)
            try await settle { editor.isHorizontallyResizable == !wraps }
            editor.layoutSubtreeIfNeeded()
            let rect = editor.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: anchor, actualRange: nil)), from: nil)
            XCTAssertEqual(rect.minY - scroll.contentView.bounds.minY, offset, accuracy: 1, "wrap toggle=\(wraps)")
        }
        XCTAssertEqual(Data(file.text.utf8), Data(source.utf8))
        XCTAssertFalse(file.isDirty)
        for focused in [false, true] {
            window.contentView = NSView()
            let remount = NSHostingView(rootView: SourceTextEditor(
                file: file, font: TerminalFont.resolve(family: "", size: focused ? 8 : 32),
                palette: .theme(dark: true), wrapLines: false, isFocused: focused))
            window.contentView = remount
            remount.layoutSubtreeIfNeeded()
            try await settle { editor.font.pointSize == (focused ? 8 : 32) && editor.window != nil }
            editor.needsLayout = true
            editor.layoutSubtreeIfNeeded()
            let rect = editor.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: anchor, actualRange: nil)), from: nil)
            XCTAssertEqual(rect.minY - scroll.contentView.bounds.minY, offset, accuracy: 1, "remounted focused=\(focused)")
            XCTAssertTrue(file.editorView === scroll)
        }
    }

    func testGeometryConfigurationBoundaries() async throws {
        let sources = ["", "\n\n", "a\r\nb\r\n", "a\rb\u{2028}c\u{2029}",
                       String(repeating: "中文 👩‍💻 e\u{301} مرحبا\n", count: 50),
                       String(repeating: "long_code_", count: 2_000)]
        for size: CGFloat in [8, 13, 32] {
            for font in [NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
                         TerminalFont.resolve(family: "", size: size)] {
                for wraps in [false, true] {
                    for style in [NSScroller.Style.overlay, .legacy] {
                        for width: CGFloat in [1, 280, 900] {
                            for source in sources {
                                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                                    try autoreleasepool {
                                        let (window, editor) = mount(source, font: font, width: width, wraps: wraps,
                                                                     scrollerStyle: style, appearance: appearance)
                                        defer { window.close() }
                                        let scroll = try XCTUnwrap(editor.enclosingScrollView)
                                        XCTAssertTrue(editor.frame.width.isFinite)
                                        XCTAssertTrue(editor.frame.height.isFinite)
                                        XCTAssertGreaterThan(editor.textContainer.size.width, 0)
                                        if width == 1 {
                                            window.setContentSize(NSSize(width: 900, height: 600))
                                            scroll.layoutSubtreeIfNeeded()
                                            editor.needsLayout = true
                                            editor.layoutSubtreeIfNeeded()
                                        }
                                        for offset in [source.utf16.count, 0] {
                                            editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
                                            editor.layoutSubtreeIfNeeded()
                                            let rect = editor.convert(window.convertFromScreen(editor.firstRect(
                                                forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)), from: nil)
                                            XCTAssertGreaterThanOrEqual(rect.minY, editor.visibleRect.minY - 1)
                                            XCTAssertLessThanOrEqual(rect.maxY, editor.visibleRect.maxY + 1)
                                        }
                                        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(source.utf8))
                                        XCTAssertGreaterThanOrEqual(editor.frame.height, scroll.contentView.bounds.height)
                                    }
                                    await Task.yield()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testScrollingPreservesVisibleTextOffset() async throws {
        let source = (0..<1_000).map { "let value\($0) = 1 // " + String(repeating: "word ", count: $0 % 43) }.joined(separator: "\n")
        for wraps in [false, true] {
            let (window, editor) = mount(source, font: TerminalFont.resolve(family: "", size: 13))
            defer { window.close() }
            editor.isHorizontallyResizable = !wraps
            guard try await reveal(NSRange(location: source.utf16.count / 2, length: 1), in: editor) else { return }
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            for delta: CGFloat in Array(repeating: 48, count: 15) + Array(repeating: -48, count: 15) {
                let oldOrigin = scroll.contentView.bounds.minY
                let point = window.convertPoint(toScreen: editor.convert(
                    NSPoint(x: 100, y: editor.visibleRect.minY + 300), to: nil))
                let offset = editor.characterIndex(for: point)
                let range = NSRange(location: offset, length: 0)
                let before = editor.convert(window.convertFromScreen(
                    editor.firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: oldOrigin + delta))
                scroll.reflectScrolledClipView(scroll.contentView)
                editor.prepareContent(in: editor.visibleRect)
                editor.layoutSubtreeIfNeeded()
                let after = editor.convert(window.convertFromScreen(
                    editor.firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
                XCTAssertEqual(after.minY - scroll.contentView.bounds.minY,
                               before.minY - oldOrigin - delta, accuracy: 1, "wrap=\(wraps)")
            }
        }
    }

    func testVariableLengthUnwrappedCodeKeepsGeometry() throws {
        let source = (0..<1_000).map { row in
            row % 3 == 0 ? "" : "let value = 1 // " + String(repeating: "wide", count: row % 43)
        }.joined(separator: "\n")
        let (window, editor) = mount(source, font: TerminalFont.resolve(family: "", size: 13))
        defer { window.close() }
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let beginning = NSTextRange(location: editor.textContentManager.documentRange.location)
        let lineHeight = try XCTUnwrap(editor.textLayoutManager.textSegmentFrame(in: beginning, type: .standard)).height
        var offsets = [0]
        for row in source.components(separatedBy: "\n").dropLast() {
            offsets.append(try XCTUnwrap(offsets.last) + row.utf16.count + 1)
        }
        var heights: [CGFloat] = []
        let marker = STGutterMarker(lineNumber: 250)
        editor.gutterView?.areMarkersEnabled = true
        editor.gutterView?.addMarker(marker)
        for fraction in [0, 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - 600) * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            editor.prepareContent(in: editor.visibleRect)
            editor.layoutSubtreeIfNeeded()
            heights.append(editor.frame.height)
            var row = min(offsets.count - 1, Int(editor.visibleRect.minY / lineHeight) + 1)
            if row % 3 == 0, row + 1 < offsets.count { row += 1 }
            let screenRect = editor.firstRect(forCharacterRange: NSRange(location: offsets[row], length: 0), actualRange: nil)
            let documentRect = editor.convert(window.convertFromScreen(screenRect), from: nil)
            XCTAssertEqual(documentRect.minY, CGFloat(row) * lineHeight, accuracy: 1)
            let hit = editor.characterIndex(for: NSPoint(x: screenRect.minX + 1, y: screenRect.midY))
            XCTAssertEqual(hit, offsets[row])
            let gutter = try XCTUnwrap(editor.gutterView)
            let cells = gutter.containerView.subviews.compactMap { $0 as? STGutterLineNumberCell }
            XCTAssertFalse(cells.isEmpty)
            for cell in cells {
                let rect = editor.convert(cell.bounds, from: cell)
                XCTAssertEqual(rect.minY, CGFloat(cell.lineNumber - 1) * lineHeight, accuracy: 1)
            }
            if let cell = cells.first(where: { $0.lineNumber == marker.lineNumber }) {
                XCTAssertNotNil(marker.view.superview)
                XCTAssertEqual(editor.convert(marker.view.bounds, from: marker.view).midY,
                               editor.convert(NSPoint(x: 0, y: cell.textVisualCenter), from: cell).y, accuracy: 1)
            }
        }
        print("EDITOR_VARIABLE heights=\(heights)")
        XCTAssertEqual(try XCTUnwrap(heights.max()), try XCTUnwrap(heights.min()), accuracy: 1)
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(source.utf8))
    }

    func testSourceGeometryAndEditCosts() async throws {
        executionTimeAllowance = 300
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for rows in [382, 1_000, 10_000, 100_000] {
            let source = (0..<rows).map { row in
                switch row % 5 {
                case 0: "struct Item\(row) {"
                case 1: "    let title = \"中文 👋 e\u{301}\" // a fairly realistic code line"
                case 2: "    let value = 1234567890 // " + String(repeating: "wide", count: row % 31)
                case 3: "}"
                default: ""
                }
            }.joined(separator: "\n")
            let path = directory.appendingPathComponent("fixture-\(rows).txt")
            try Data(source.utf8).write(to: path)
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await file.waitForText()
            for wraps in [false, true] {
                let host = NSHostingView(rootView: SourceTextEditor(
                    file: file, font: TerminalFont.resolve(family: "", size: 13), palette: .theme(dark: true), wrapLines: wraps,
                    isFocused: false
                ))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                let deadline = Date().addingTimeInterval(5)
                while file.editorView == nil, Date() < deadline {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(5))
                }
                let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
                let editor = try XCTUnwrap(scroll.documentView as? STTextView)
                while scroll.contentView.bounds.height < 100, Date() < deadline {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertGreaterThan(scroll.contentView.bounds.height, 100)
                print("EDITOR_ENV font=\(editor.font.fontName) size=\(editor.font.pointSize) scale=\(window.backingScaleFactor) viewport=\(scroll.contentView.bounds.size)")
                var heights: [CGFloat] = []
                var origins: [CGFloat] = []
                for fraction in [0, 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0] {
                    let origin = NSPoint(x: 0, y: max(0, editor.frame.height - scroll.contentView.bounds.height) * fraction)
                    scroll.contentView.scroll(to: origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    editor.prepareContent(in: editor.visibleRect)
                    editor.layoutSubtreeIfNeeded()
                    heights.append(editor.frame.height)
                    origins.append(scroll.contentView.bounds.minY)
                }
                print("EDITOR_SOURCE rows=\(rows) wrap=\(wraps) bytes=\(source.utf8.count) heights=\(heights) origins=\(origins)")
                for position in [0, source.utf16.count / 2, source.utf16.count] {
                    var durations: [Double] = []
                    var insertions: [Double] = []
                    var deletions: [Double] = []
                    for _ in 0..<30 {
                        let started = CFAbsoluteTimeGetCurrent()
                        editor.replaceCharacters(in: NSRange(location: position, length: 0), with: "a")
                        let inserted = CFAbsoluteTimeGetCurrent()
                        editor.replaceCharacters(in: NSRange(location: position, length: 1), with: "")
                        let deleted = CFAbsoluteTimeGetCurrent()
                        insertions.append((inserted - started) * 1_000)
                        deletions.append((deleted - inserted) * 1_000)
                        durations.append((deleted - started) * 1_000)
                        await Task.yield()
                    }
                    durations.sort()
                    insertions.sort()
                    deletions.sort()
                    print("EDITOR_INPUT rows=\(rows) wrap=\(wraps) position=\(position) pair_ms median=\(durations[15]) p95=\(durations[28]) max=\(durations[29])")
                    print("EDITOR_SINGLE rows=\(rows) wrap=\(wraps) position=\(position) insert_ms median=\(insertions[15]) p95=\(insertions[28]) delete_ms median=\(deletions[15]) p95=\(deletions[28])")
                }
                XCTAssertEqual(Data(file.text.utf8), Data(source.utf8))
            }
        }
    }

    func testUnwrappedDocumentGeometryAcrossNewViewports() async throws {
        for rows in [382, 1_000, 10_000, 100_000] {
            let source = String(repeating: "struct Item { let value = 123 } // stable code row\n", count: rows)
            let started = CFAbsoluteTimeGetCurrent()
            let (window, editor) = mount(source)
            defer { window.close() }
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            let initialHeight = editor.frame.height
            var heights = [initialHeight]
            var knobs = [scroll.verticalScroller?.knobProportion ?? -1]
            for fraction in [0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0] {
                let origin = NSPoint(x: 0, y: max(0, editor.frame.height - scroll.contentView.bounds.height) * fraction)
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                editor.prepareContent(in: editor.visibleRect)
                editor.layoutSubtreeIfNeeded()
                heights.append(editor.frame.height)
                knobs.append(scroll.verticalScroller?.knobProportion ?? -1)
            }
            print("EDITOR_GEOMETRY rows=\(rows) seconds=\(CFAbsoluteTimeGetCurrent() - started) heights=\(heights) knobs=\(knobs)")
            editor.scrollToEndOfDocument(nil)
            var durations: [Double] = []
            print("EDITOR_SCROLL_BEGIN rows=\(rows)")
            for iteration in 0..<30 {
                let started = CFAbsoluteTimeGetCurrent()
                autoreleasepool {
                    let delta: CGFloat = iteration.isMultiple(of: 2) ? -48 : 48
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + delta))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    editor.prepareContent(in: editor.visibleRect)
                    editor.layoutSubtreeIfNeeded()
                    heights.append(editor.frame.height)
                }
                durations.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                await Task.yield()
            }
            durations.sort()
            print("EDITOR_SCROLL rows=\(rows) ms median=\(durations[15]) p95=\(durations[28]) max=\(durations[29])")
            XCTAssertEqual(try XCTUnwrap(heights.max()), try XCTUnwrap(heights.min()), accuracy: 1, "rows=\(rows)")
        }
    }

    private func mount(
        _ source: String, fixedRows: Bool = false, font: NSFont? = nil, width: CGFloat = 900,
        wraps: Bool = false, scrollerStyle: NSScroller.Style? = nil, appearance: NSAppearance.Name? = nil
    ) -> (NSWindow, STTextView) {
        let editor = STTextView()
        let font = font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.font = font
        editor.usesPlainTextGeometry = !fixedRows
        editor.showsLineNumbers = !fixedRows
        editor.isHorizontallyResizable = !wraps
        if fixedRows {
            let style = DiffTypography.paragraphStyle(for: font)
            editor.defaultParagraphStyle = style
            editor.typingAttributes[.paragraphStyle] = style
            let rows = source.utf16.filter { $0 == 10 }.count + 1
            editor.overrideContentHeight = CGFloat(rows) * DiffTypography.lineHeight(for: font)
        }
        editor.text = source
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        if let scrollerStyle { scroll.scrollerStyle = scrollerStyle }
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.clipsToBounds = true
        editor.frame = scroll.bounds
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let appearance { window.appearance = NSAppearance(named: appearance) }
        window.contentView = scroll
        window.orderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        return (window, editor)
    }

    private func reveal(_ range: NSRange, in editor: STTextView) async throws -> Bool {
        editor.scrollRangeToVisible(range)
        let deadline = Date().addingTimeInterval(5)
        while true {
            editor.layoutSubtreeIfNeeded()
            let viewport = editor.textLayoutManager.textViewportLayoutController.viewportRange
                .map { NSRange($0, in: editor.textContentManager) }
            if let viewport, viewport.location <= range.location, NSMaxRange(viewport) >= NSMaxRange(range) {
                if range.length == 0 { return true }
                if let target = NSTextRange(range, in: editor.textContentManager),
                   let nativeSegment = editor.textLayoutManager.textSegmentFrame(in: target, type: .standard) {
                    let segment = editor.convert(nativeSegment, from: editor.contentView)
                    if segment.minY >= editor.visibleRect.minY - 1, segment.maxY <= editor.visibleRect.maxY + 1 {
                        return true
                    }
                }
            }
            if Date() >= deadline {
                let segment = NSTextRange(range, in: editor.textContentManager)
                    .flatMap { editor.textLayoutManager.textSegmentFrame(in: $0, type: .standard) }
                XCTFail("Requested \(range), actual viewport \(String(describing: viewport)); visible=\(editor.visibleRect), segment=\(String(describing: segment)), document=\(editor.frame)")
                return false
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testLongDocumentRevealsForwardAndReverseTargets() async throws {
        let prefix = "# Test\n\n```swift\n"
        let line = "// 中文 👋\nstruct Item { let name = \"value\" }\n"
        let source = prefix + String(repeating: line, count: 4096) + "```\n"
        let (window, editor) = mount(source)
        defer { window.close() }
        for batch in 0..<2 {
            for iteration in 0..<30 {
                let row = batch == 0 ? iteration * 4095 / 29 : (29 - iteration) * 4095 / 29
                let range = NSRange(location: prefix.utf16.count + row * line.utf16.count, length: 2)
                guard try await reveal(range, in: editor) else { return }
            }
        }
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(source.utf8))
    }

    func testShortAndFixedRowDocumentsKeepEndAndBeginningVisible() async throws {
        for (source, fixedRows) in [("short\n中文 👋\n", false), (String(repeating: "row 中文 👋\n", count: 1000), true)] {
            let (window, editor) = mount(source, fixedRows: fixedRows)
            defer { window.close() }
            for offset in [source.utf16.count, source.utf16.count / 2, 0, source.utf16.count] {
                guard try await reveal(NSRange(location: offset, length: 0), in: editor) else { return }
            }
            XCTAssertGreaterThanOrEqual(editor.frame.height, 600)
            if let height = editor.overrideContentHeight { XCTAssertEqual(editor.frame.height, height, accuracy: 1) }
            XCTAssertEqual(Data((editor.text ?? "").utf8), Data(source.utf8))
        }
    }
}
