import AppKit
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import Bailey

private actor DiffWorkspaceFixture: WorkspaceBackend {
    private var contents = Data("baseline😀\r\n".utf8)
    private var pendingWrite: (Data, CheckedContinuation<Void, Error>)?
    private var pendingRead: CheckedContinuation<Data, Error>?
    private var pauseRead = false
    private(set) var writing = false
    private(set) var reading = false
    private(set) var writes = 0
    private var mutateIndexAfterSize = false
    private var indexMoved = false
    private var shortGitBlob = false

    func simulateIndexChangeAfterSize() { mutateIndexAfterSize = true }
    func simulateIncompleteGitBlob() {
        mutateIndexAfterSize = true
        shortGitBlob = true
    }

    func finishWrite(failing: Bool = false) {
        guard let (data, continuation) = pendingWrite else { return }
        pendingWrite = nil
        writing = false
        if failing {
            continuation.resume(throwing: WorkspaceError.timedOut)
        } else {
            contents = data
            continuation.resume()
        }
    }
    func stored() -> Data { contents }
    func pauseOneRead() { pauseRead = true }
    func finishRead(with data: Data) {
        let continuation = pendingRead
        pendingRead = nil
        reading = false
        continuation?.resume(returning: data)
    }
    func write(path: String, data: Data) async throws {
        writes += 1
        try await withCheckedThrowingContinuation { continuation in
            writing = true
            pendingWrite = (data, continuation)
        }
    }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        guard mutateIndexAfterSize else {
            return .init(status: 0, stdout: Data(), stderr: Data())
        }
        let headID = String(repeating: "a", count: 40)
        let indexID = String(repeating: "b", count: 40)
        let newID = String(repeating: "c", count: 40)
        let head = Data("head\n".utf8)
        let index = Data("indexA\n".utf8)
        let moved = Data("indexB\n".utf8)
        func result(_ data: Data) -> WorkspaceRunResult {
            .init(status: 0, stdout: data, stderr: Data())
        }
        if argv.contains("ls-tree") {
            return result(Data("100644 blob \(headID)\tstable.txt\0".utf8))
        }
        if argv.contains("ls-files") {
            let id = indexMoved ? newID : indexID
            return result(Data("100644 \(id) 0\tstable.txt\0".utf8))
        }
        if argv.contains("cat-file"), argv.count >= 4 {
            let id = argv.last ?? ""
            let bytes = id == headID || id == "HEAD:stable.txt" ? head
                : id == indexID ? index
                : id == newID || id == ":stable.txt" ? (indexMoved ? moved : index)
                : Data()
            if argv.contains("-s") {
                if id == indexID || id == ":stable.txt" { indexMoved = true }
                return result(Data("\(bytes.count)\n".utf8))
            }
            if argv.contains("blob") {
                return result(shortGitBlob && id == indexID ? Data(bytes.dropLast()) : bytes)
            }
        }
        return .init(status: 128, stdout: Data(), stderr: Data("unexpected Git command".utf8))
    }
    func stat(path: String) async throws -> WorkspaceStat? {
        .init(isRegular: true, isDirectory: false, isSymlink: false, size: contents.count, mtime: .distantPast)
    }
    func read(path: String, maxBytes: Int) async throws -> Data {
        if pauseRead {
            pauseRead = false
            reading = true
            return try await withCheckedThrowingContinuation { pendingRead = $0 }
        }
        return contents
    }
    func readSymlinkDestination(path: String) async throws -> String? { nil }
    func list(directory: String) async throws -> [WorkspaceEntry] { [] }
    func createFile(path: String) async throws { throw WorkspaceError.notFound }
    func createDirectory(path: String) async throws { throw WorkspaceError.notFound }
    func copy(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func rename(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func delete(paths: [String]) async throws { throw WorkspaceError.notFound }
}

@MainActor
@Observable
private final class DiffSelectionFixture {
    var selected: DiffTab
    init(_ selected: DiffTab) { self.selected = selected }
}

private struct DiffSelectionFixtureView: View {
    let selection: DiffSelectionFixture
    var body: some View { DiffViewerView(diff: selection.selected) }
}

@MainActor
final class NativeDiffTabTests: XCTestCase {
    func testNativeDiffAccessibilityAllowsOnlyEditableTextChanges() {
        // AppKit API-level contract: XCUIApplication exercises the full user
        // interaction separately in GitHistoryUITests and WorkspaceGitUITests.
        let editor = DiffTextView()
        editor.frame = .init(x: 0, y: 0, width: 300, height: 150)
        editor.text = "original"
        for editable in [false, true, false] {
            editor.isEditable = editable
            XCTAssertEqual(editor.isAccessibilitySelectorAllowed(#selector(editor.setAccessibilityValue(_:))), editable)
            let previous = editor.text
            let replacement = editable ? "editable change" : "readonly change"
            editor.setAccessibilityValue(replacement)
            XCTAssertEqual(editor.text, editable ? replacement : previous)
            XCTAssertTrue(editor.isSelectable)
        }
    }

    private func isolatedPreferences() throws -> DiffViewPreferences {
        let domain = "bailey-native-diff-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        return DiffViewPreferences(defaults: defaults)
    }

    private func sRGBColumn(_ bitmap: NSBitmapImageRep, x: Int) -> [NSColor] {
        let maximum = CGFloat((1 << bitmap.bitsPerSample) - 1)
        return (0..<bitmap.pixelsHigh).map { y in
            var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
            bitmap.getPixel(&pixel, atX: x, y: y)
            return NSColor(srgbRed: CGFloat(pixel[0]) / maximum,
                           green: CGFloat(pixel[1]) / maximum,
                           blue: CGFloat(pixel[2]) / maximum, alpha: 1)
        }
    }

    func testDiffShortDocumentsDoNotExposePhantomHorizontalScroll() {
        for mode in [DiffCodePaneView.Mode.review, .edit] {
            let pane = DiffCodePaneView(mode: mode, gutterLayout: .single)
            let window = NSWindow(
                contentRect: NSRect(x: -900, y: -900, width: 720, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = pane
            defer { window.close() }
            window.orderFront(nil)
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            pane.applyTypography(
                font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                textColor: .textColor
            )
            let shortContent = String(repeating: "ASCII only ", count: 6) + "\n中文 👋\n"
            if mode == .review {
                pane.setReviewDocument(NSAttributedString(string: shortContent),
                                       decorations: .empty)
            } else {
                pane.setEditBufferText(shortContent)
            }
            pane.layoutSubtreeIfNeeded()
            let scroll = pane.scrollView
            let visible = scroll.contentView.bounds
            XCTAssertEqual(pane.textView.frame.width, visible.width, accuracy: 1,
                           "Both review and edit modes must not invent horizontal content width")
            XCTAssertEqual(
                scroll.contentView.constrainBoundsRect(NSRect(
                    x: 500, y: 0, width: visible.width, height: visible.height
                )).minX,
                0, accuracy: 1
            )
        }
    }

    func testNativeDiffRendersRowsThroughTransparentTextSurface() throws {
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        let window = NSWindow(
            contentRect: NSRect(x: -900, y: -900, width: 680, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.appearance = NSAppearance(named: .aqua)
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .textColor)
        let document = DiffComputation.compute(
            oldText: "old value\nshared value\n", newText: "new value\nshared value\n"
        ).unified
        pane.setReviewDocument(NSAttributedString(string: document.text),
                               decorations: .review(document))
        pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(document.rows.contains { $0.kind == .removed })
        XCTAssertTrue(document.rows.contains { $0.kind == .added })
        XCTAssertFalse(pane.textView.drawsBackground,
                       "Native text must not paint over the diff's underlay tints and emphasis")
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds)?
            .retagging(with: .sRGB))
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        let scheme = DiffColorScheme.current(dark: false)
        func near(_ color: NSColor, _ expected: NSColor) -> Bool {
            guard let b = expected.usingColorSpace(.sRGB) else { return false }
            return abs(color.redComponent - b.redComponent) < 0.06
                && abs(color.greenComponent - b.greenComponent) < 0.06
                && abs(color.blueComponent - b.blueComponent) < 0.06
        }
        let samples = sRGBColumn(bitmap, x: bitmap.pixelsWide - 50)
        XCTAssertTrue(samples.contains { near($0, scheme.addedRow) },
                      "Added-row tint must actually reach rendered pixels")
        XCTAssertTrue(samples.contains { near($0, scheme.removedRow) },
                      "Removed-row tint must actually reach rendered pixels")
    }

    func testSplitAndUnifiedDiffRowTintsReachPixelsInBothThemes() throws {
        let compared = DiffComputation.compute(
            oldText: "header\nold value\nfooter\n",
            newText: "header\nnew value\nfooter\n"
        )
        for dark in [false, true] {
            let scheme = DiffColorScheme.current(dark: dark)
            let cases: [(DiffSideDocument, DiffGutterLayout, [NSColor])] = [
                (compared.unified, .single, [scheme.addedRow, scheme.removedRow]),
                (compared.splitLeft, .oldOnly, [scheme.removedRow]),
                (compared.splitRight, .newOnly, [scheme.addedRow]),
            ]
            for (document, layout, requiredTints) in cases {
                let pane = DiffCodePaneView(mode: .review, gutterLayout: layout)
                let window = NSWindow(
                    contentRect: NSRect(x: -920, y: -920, width: 690, height: 300),
                    styleMask: [.titled], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = pane
                window.orderFront(nil)
                let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                let paragraphStyle = DiffTypography.paragraphStyle(for: font)
                let textColor = Theme.terminal(dark: dark).foregroundNSColor
                pane.applyTypography(font: font, paragraphStyle: paragraphStyle,
                                     textColor: textColor)
                pane.setReviewDocument(NSAttributedString(string: document.text, attributes: [
                    .font: font, .foregroundColor: textColor, .paragraphStyle: paragraphStyle,
                ]), decorations: .review(document))
                pane.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds)?
                    .retagging(with: .sRGB))
                pane.cacheDisplay(in: pane.bounds, to: bitmap)
                let colors = sRGBColumn(bitmap, x: bitmap.pixelsWide - 50)
                let observedPalette = Array(Set(colors.map {
                    String(format: "%.3f,%.3f,%.3f",
                           $0.redComponent, $0.greenComponent, $0.blueComponent)
                })).sorted()
                // Compare bitmap channels and theme colors in the same sRGB
                // space. Do not reinterpret sampled channels as display RGB.
                let background = try XCTUnwrap(scheme.background.usingColorSpace(.sRGB))
                let backgroundGreen = background.greenComponent - background.redComponent
                let backgroundBlue = background.blueComponent - background.redComponent
                for tint in requiredTints {
                    let expected = try XCTUnwrap(tint.usingColorSpace(.sRGB))
                    let expectedGreen = expected.greenComponent - expected.redComponent - backgroundGreen
                    let expectedBlue = expected.blueComponent - expected.redComponent - backgroundBlue
                    let expectedMagnitude = hypot(expectedGreen, expectedBlue)
                    XCTAssertGreaterThan(expectedMagnitude, 0.01)
                    let matching = colors.filter { sample in
                        let green = sample.greenComponent - sample.redComponent - backgroundGreen
                        let blue = sample.blueComponent - sample.redComponent - backgroundBlue
                        let magnitude = hypot(green, blue)
                        guard magnitude >= expectedMagnitude * 0.6 else { return false }
                        return (green * expectedGreen + blue * expectedBlue)
                            / (magnitude * expectedMagnitude) > 0.9
                    }.count
                    XCTAssertGreaterThan(matching, 8,
                                         "Native \(layout) diff tint must reach pixels, dark=\(dark); appearance=\(pane.effectiveAppearance.name.rawValue); expectedRGB=\(expected); sampledRGB=\(observedPalette.prefix(24))")
                }
                window.close()
            }
        }
    }

    func testLongLeadingDeletionRemainsVisibleAtTopOfEditableDiff() throws {
        let old = (0..<500).map { "removed line \($0)\n" }.joined() + "survivor\n"
            + (0..<500).map { "trailing removed line \($0)\n" }.joined()
        let current = "survivor\n"
        let core = DiffCore.compute(oldText: old, newText: current)
        let state = DiffComputation.editState(
            ops: core.ops, oldLines: core.oldLines, newLines: core.newLines
        )
        let ghostLines = (0..<500).map { NSAttributedString(string: "removed line \($0)") }
        let trailingLines = (0..<500).map {
            NSAttributedString(string: "trailing removed line \($0)")
        }
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(
            contentRect: NSRect(x: -920, y: -920, width: 680, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .textColor)
        pane.setEditBufferText(current)
        pane.decorations = .edit(
            state: state, snapshotOffsets: [0], lineCount: 1,
            ghostBlocks: [
                .init(anchorLine: 0, firstOldLine: 1, lines: ghostLines),
                .init(anchorLine: 1, firstOldLine: 502, lines: trailingLines),
            ]
        )
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds)?
            .retagging(with: .sRGB))
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        let dark = pane.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let expected = try XCTUnwrap(DiffColorScheme.current(dark: dark).removedRow.usingColorSpace(.sRGB))
        let matching = sRGBColumn(bitmap, x: bitmap.pixelsWide - 50).reduce(0) { count, color in
            let isRemoval = abs((color.greenComponent - color.redComponent)
                - (expected.greenComponent - expected.redComponent)) < 0.03
                && abs((color.blueComponent - color.redComponent)
                    - (expected.blueComponent - expected.redComponent)) < 0.03
            return count + (isRemoval ? 1 : 0)
        }
        XCTAssertGreaterThan(matching, 8,
                             "Removed lines cannot become blank space when their anchor is below the viewport")
        pane.setVerticalScrollOffset(2_000)
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let scrolled = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds)?
            .retagging(with: .sRGB))
        pane.cacheDisplay(in: pane.bounds, to: scrolled)
        let middle = sRGBColumn(scrolled, x: scrolled.pixelsWide - 50).filter { color in
            abs((color.greenComponent - color.redComponent)
                - (expected.greenComponent - expected.redComponent)) < 0.03
                && abs((color.blueComponent - color.redComponent)
                    - (expected.blueComponent - expected.redComponent)) < 0.03
        }.count
        XCTAssertGreaterThan(middle, 8, "Removed rows must stay visible while scrolling inside a ghost block")
        pane.setVerticalScrollOffset(10_000)
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let trailing = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds)?
            .retagging(with: .sRGB))
        pane.cacheDisplay(in: pane.bounds, to: trailing)
        let lastBlock = sRGBColumn(trailing, x: trailing.pixelsWide - 50).filter { color in
            abs((color.greenComponent - color.redComponent)
                - (expected.greenComponent - expected.redComponent)) < 0.03
                && abs((color.blueComponent - color.redComponent)
                    - (expected.blueComponent - expected.redComponent)) < 0.03
        }.count
        XCTAssertGreaterThan(lastBlock, 8,
                             "Deep scrolling must locate the next virtual deletion block")
    }

    func testFoldedNativeDiffScrollbarHasCompleteHeightBeforeDeepScrolling() throws {
        var lines = (0..<24_000).map { "let row\($0) = \($0)\n" }
        let original = lines.joined()
        for index in stride(from: 120, to: lines.count, by: 200) {
            lines[index] = "let row\(index) = -1\n"
        }
        let changed = lines.joined()
        let core = DiffCore.compute(oldText: original, newText: changed)
        let computation = DiffComputation.build(core: core, revealedLines: [])
        let folds = DiffEditFold.sourceFolds(in: computation.unified,
                                             lineCount: core.newLines.count)
        let offsets = core.newLines.map(\.utf16Range.location)
        let originalText = original as NSString
        let ghosts = computation.editState.ghosts.map { block in
            DiffDecorations.GhostBlock(
                anchorLine: block.anchorLine, firstOldLine: block.firstOldLine,
                lines: block.lines.map {
                    NSAttributedString(string: originalText.substring(with: $0.sourceRange))
                }
            )
        }
        XCTAssertGreaterThan(folds.count, 50)
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: CGRect(x: -950, y: -950, width: 800, height: 330),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let rowHeight = DiffTypography.paragraphStyle(for: font).maximumLineHeight
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .textColor)
        pane.setEditBufferText(changed)
        pane.setEditingFolds(
            folds, lineOffsets: offsets,
            baseDecorations: .edit(state: computation.editState, snapshotOffsets: offsets,
                                   lineCount: offsets.count, ghostBlocks: ghosts),
            revision: 1
        )
        let visibleSourceRows = core.newLines.count - folds.reduce(0) {
            $0 + max(0, $1.range.count - 1)
        }
        let expected = CGFloat(visibleSourceRows + ghosts.reduce(0) { $0 + $1.lines.count })
            * rowHeight
        func height() -> CGFloat {
            pane.layoutSubtreeIfNeeded()
            pane.scrollView.layoutSubtreeIfNeeded()
            pane.textView.nativeLayoutManager.textViewportLayoutController.layoutViewport()
            return pane.scrollView.documentView?.frame.height ?? 0
        }
        let initial = height()
        let initialKnob = pane.scrollView.verticalScroller?.knobProportion
        var samples: [CGFloat] = []
        for _ in 0..<8 {
            pane.setVerticalScrollOffset(1_000_000)
            samples.append(height())
            XCTAssertEqual(pane.scrollView.verticalScroller?.knobProportion ?? -1,
                           initialKnob ?? -1, accuracy: 0.001,
                           "Scrolling must not make the native scrollbar thumb shorter")
        }
        XCTAssertEqual(initial, expected, accuracy: rowHeight * 2,
                       "The native scroll range must already account for all folded and ghost rows")
        for sample in samples {
            XCTAssertEqual(sample, initial, accuracy: rowHeight,
                           "Deep scrolling may not resize the document and shrink the scrollbar")
        }
        let bottomRows = DiffRowGeometry.visibleRows(textView: pane.textView,
                                                     decorations: pane.decorations)
        XCTAssertTrue(bottomRows.contains { $0.index >= (folds.last?.range.lowerBound ?? Int.max) },
                      "The complete scroll track must reach the final visible Git source row")
        let next = DiffComputation.build(core: core, revealedLines:
            try XCTUnwrap(computation.unified.rows.first(where: { $0.collapsed != nil })?.collapsed)
                .revealNext()
        )
        let expandedFolds = DiffEditFold.sourceFolds(in: next.unified, lineCount: core.newLines.count)
        pane.setEditingFolds(
            expandedFolds, lineOffsets: offsets,
            baseDecorations: .edit(state: next.editState, snapshotOffsets: offsets,
                                   lineCount: offsets.count, ghostBlocks: ghosts),
            revision: 2
        )
        pane.layoutSubtreeIfNeeded()
        let expandedRows = core.newLines.count - expandedFolds.reduce(0) {
            $0 + max(0, $1.range.count - 1)
        }
        let expandedHeight = CGFloat(expandedRows + ghosts.reduce(0) { $0 + $1.lines.count })
            * rowHeight
        XCTAssertEqual(pane.textView.frame.height, expandedHeight, accuracy: rowHeight,
                       "Unfolding must update the full native scroll extent before scrolling")
        pane.setVerticalScrollOffset(1_000_000)
        XCTAssertTrue(DiffRowGeometry.visibleRows(textView: pane.textView,
            decorations: pane.decorations).contains {
                $0.index >= (expandedFolds.last?.range.lowerBound ?? Int.max)
            }, "The expanded native scroll track must still reach the last visible source line")
        XCTAssertEqual(pane.textView.string, changed)
    }

    func testFoldedEditorUpdatesSourceOffsetsWithoutRevealingHiddenParagraphs() throws {
        let original = (0..<900).map { "line \($0)\n" }.joined()
        let changed = original.replacingOccurrences(of: "line 500\n", with: "changed 500\n")
        let core = DiffCore.compute(oldText: original, newText: changed)
        let projection = DiffComputation.build(core: core, revealedLines: [])
        let folds = DiffEditFold.sourceFolds(in: projection.unified,
                                             lineCount: core.newLines.count)
        let offsets = core.newLines.map(\.utf16Range.location)
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: CGRect(x: -940, y: -940, width: 760, height: 330),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .textColor)
        pane.setEditBufferText(changed)
        pane.setEditingFolds(
            folds, lineOffsets: offsets,
            baseDecorations: .edit(state: projection.editState, snapshotOffsets: offsets,
                                   lineCount: offsets.count, ghostBlocks: []),
            revision: 1
        )
        pane.layoutSubtreeIfNeeded()
        let firstHeight = pane.textView.frame.height
        let edited = changed.replacingOccurrences(of: "changed 500\n",
                                                   with: "changed LARGER 500\n")
        pane.textView.textStorage?.replaceCharacters(
            in: NSRange(location: offsets[500], length: "changed 500".utf16.count),
            with: "changed LARGER 500"
        )
        let updatedCore = DiffCore.compute(oldText: original, newText: edited)
        let updatedProjection = DiffComputation.build(core: updatedCore, revealedLines: [])
        let updatedFolds = DiffEditFold.sourceFolds(in: updatedProjection.unified,
                                                    lineCount: updatedCore.newLines.count)
        XCTAssertEqual(updatedFolds.map(\.range), folds.map(\.range),
                       "Editing inside a changed line shifts UTF-16 offsets, not collapsed Git ranges")
        let nextOffsets = updatedCore.newLines.map(\.utf16Range.location)
        XCTAssertNotEqual(offsets.last, nextOffsets.last)
        pane.setEditingFolds(
            updatedFolds, lineOffsets: nextOffsets,
            baseDecorations: .edit(state: updatedProjection.editState, snapshotOffsets: nextOffsets,
                                   lineCount: nextOffsets.count, ghostBlocks: []),
            revision: 2
        )
        pane.layoutSubtreeIfNeeded()
        let layout = pane.textView.nativeLayoutManager
        layout.ensureLayout(for: layout.documentRange)
        var renderedParagraphs: [String] = []
        layout.enumerateTextLayoutFragments(in: layout.documentRange) { fragment in
            renderedParagraphs.append(
                (fragment.textElement as? NSTextParagraph)?.attributedString.string ?? ""
            )
            return true
        }
        XCTAssertTrue(renderedParagraphs.contains { $0.contains("changed LARGER 500") })
        XCTAssertFalse(renderedParagraphs.contains { $0 == "line 20\n" },
                       "Updating UTF-16 source offsets must not reveal a hidden paragraph")
        XCTAssertEqual(pane.textView.frame.height, firstHeight, accuracy: 1)
        pane.setVerticalScrollOffset(1_000_000)
        XCTAssertEqual(pane.textView.frame.height, firstHeight, accuracy: 1)
        XCTAssertEqual(pane.textView.string, edited)
    }

    func testUnfoldedGitDiffScrollbarReachesEndWithoutHeightGrowth() throws {
        let source = (0..<5_000).map { "row \($0)\n" }.joined()
        let split = DiffLineSplitter.lines(of: source).lines
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: NSRect(x: -950, y: -950, width: 750, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let rowHeight = DiffTypography.paragraphStyle(for: font).maximumLineHeight
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .textColor)
        pane.setEditBufferText(source)
        pane.setEditingFolds(
            [], lineOffsets: split.map(\.utf16Range.location),
            baseDecorations: .edit(
                state: DiffEditState(addedLines: [], addedEmphasis: [:], ghosts: []),
                snapshotOffsets: split.map(\.utf16Range.location),
                lineCount: split.count, ghostBlocks: []),
            revision: 1
        )
        pane.layoutSubtreeIfNeeded()
        let initialHeight = pane.textView.frame.height
        pane.setVerticalScrollOffset(1_000_000)
        pane.textView.nativeLayoutManager.textViewportLayoutController.layoutViewport()
        let visible = DiffRowGeometry.visibleRows(textView: pane.textView,
                                                   decorations: pane.decorations)
        XCTAssertEqual(initialHeight, CGFloat(split.count) * rowHeight, accuracy: rowHeight)
        XCTAssertTrue(visible.contains { $0.index >= split.count - 1 },
                      "An unfolded worktree diff must reach its last line on the first scroll")
        XCTAssertEqual(pane.textView.frame.height, initialHeight, accuracy: rowHeight)

        let added = "inserted\n"
        pane.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: added)
        let edited = added + source
        let next = DiffLineSplitter.lines(of: edited).lines
        let nextOffsets = next.map(\.utf16Range.location)
        pane.setEditingFolds(
            [], lineOffsets: nextOffsets,
            baseDecorations: .edit(
                state: DiffEditState(addedLines: [], addedEmphasis: [:], ghosts: []),
                snapshotOffsets: nextOffsets, lineCount: next.count, ghostBlocks: []),
            revision: 2
        )
        pane.layoutSubtreeIfNeeded()
        let revisedHeight = pane.textView.frame.height
        XCTAssertEqual(revisedHeight, initialHeight + rowHeight, accuracy: rowHeight,
                       "Adding a source line must update the complete scroll range")
        pane.setVerticalScrollOffset(1_000_000)
        pane.textView.nativeLayoutManager.textViewportLayoutController.layoutViewport()
        XCTAssertTrue(DiffRowGeometry.visibleRows(textView: pane.textView,
            decorations: pane.decorations).contains { $0.index >= next.count - 1 },
                      "Editing before the last line must not strand native content below the scrollbar")
        XCTAssertEqual(pane.textView.frame.height, revisedHeight, accuracy: rowHeight)
        XCTAssertEqual(pane.textView.string, edited)
    }

    func testNativeCRDiffScrollbarUsesFinalNativeParagraphHeight() throws {
        let source = (0..<1_400).map { "part\($0)" }.joined(separator: "\r") + "\n"
        let split = DiffLineSplitter.lines(of: source).lines
        XCTAssertEqual(split.count, 1)
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: NSRect(x: -950, y: -950, width: 750, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let rowHeight = DiffTypography.paragraphStyle(for: font).maximumLineHeight
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .textColor)
        pane.setEditBufferText(source)
        pane.setEditingFolds(
            [], lineOffsets: split.map(\.utf16Range.location),
            baseDecorations: .edit(
                state: DiffEditState(addedLines: [], addedEmphasis: [:], ghosts: []),
                snapshotOffsets: split.map(\.utf16Range.location),
                lineCount: split.count, ghostBlocks: []),
            revision: 1
        )
        pane.layoutSubtreeIfNeeded()
        let initialHeight = pane.textView.frame.height
        XCTAssertGreaterThan(initialHeight, 1_300 * rowHeight,
                             "Git counts one LF row but TextKit must lay out 1400 native CR paragraphs")
        for _ in 0..<5 {
            pane.setVerticalScrollOffset(1_000_000)
            pane.layoutSubtreeIfNeeded()
            XCTAssertEqual(pane.textView.frame.height, initialHeight, accuracy: rowHeight,
                           "Native CR paragraphs may not grow the scroll range during scrolling")
        }
        XCTAssertEqual(pane.textView.string, source)
    }

    func testDenseIntralineProjectionCancellationLatency() async throws {
        let lineCount = 100
        let old = String(repeating: String(repeating: "+", count: 400) + "\n", count: lineCount)
        let new = String(repeating: String(repeating: "-", count: 400) + "\n", count: lineCount)
        let core = try XCTUnwrap(DiffCore.fromVerifiedOperations(
            oldText: old, newText: new,
            operations: [.delete(oldStart: 0, count: lineCount),
                         .insert(newStart: 0, count: lineCount)]))
        let entered = expectation(description: "Dense projection started in the real background owner")
        let task = Task {
            await DiffTab.runBackgroundDiffWork {
                entered.fulfill()
                return DiffComputation.build(core: core, revealedLines: [])
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        let started = CFAbsoluteTimeGetCurrent()
        task.cancel()
        let result = await task.value
        XCTAssertNil(result, "Cancelled projection must never publish a partial or stale result")
        print("AUDIT_DIFF_DENSE_CANCELLATION tokens=400 pairs=100 elapsedMs=\((CFAbsoluteTimeGetCurrent() - started) * 1_000)")
    }

    func testCancelledDiffTaskStopsItsBackgroundChild() async {
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish()
            gate.continuation.finish()
        }
        let parent = Task { () -> Bool? in
            await DiffTab.runBackgroundDiffWork {
                started.continuation.yield()
                var waiting = gate.stream.makeAsyncIterator()
                _ = await waiting.next()
                return Task.isCancelled
            }
        }
        var ready = started.stream.makeAsyncIterator()
        _ = await ready.next()
        parent.cancel()
        gate.continuation.yield()
        let value = await parent.value
        XCTAssertNil(value,
                     "Cancelling the tab task must also cancel its running background projection")
    }

    func testClosingDiffDuringSyntaxCaptureReleasesItsOwner() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("close-during-color.swift")
        var lines = (0..<24_000).map { "let item\($0) = \($0)\n" }
        try Data(lines.joined().utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["add", file.lastPathComponent], in: root.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: root.path).status, 0)
        lines[12_000] = "let item12000 = -1\n"
        try Data(lines.joined().utf8).write(to: file)
        weak var retained: DiffTab?
        func loadAndRelease() async throws {
            let diff = DiffTab(repoRoot: root.path, path: file.lastPathComponent,
                               source: .worktree, untracked: false, origPath: nil,
                               backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                               preferences: try isolatedPreferences())
            retained = diff
            try await wait({ diff.canPresentNativeContent },
                           pollingInterval: .milliseconds(1), timeout: 20)
            XCTAssertTrue(diff.hasChanges)
        }
        try await loadAndRelease()
        let started = CFAbsoluteTimeGetCurrent()
        try await wait({ retained == nil }, pollingInterval: .milliseconds(1), timeout: 0.4)
        print("AUDIT_DIFF_OWNER_RELEASE milliseconds=\((CFAbsoluteTimeGetCurrent() - started) * 1_000)")
    }

    func testFoldedWorktreeViewportGeometryBudgetWithManyChanges() throws {
        var lines = (0..<24_000).map { "let row\($0) = \($0)\n" }
        let original = lines.joined()
        for index in stride(from: 100, to: lines.count, by: 240) {
            lines[index] = "let row\(index) = -1\n"
        }
        let updated = lines.joined()
        let core = DiffCore.compute(oldText: original, newText: updated)
        let presentation = DiffComputation.build(core: core, revealedLines: [])
        let folds = DiffEditFold.sourceFolds(in: presentation.unified,
                                              lineCount: core.newLines.count)
        let starts = core.newLines.map(\.utf16Range.location)
        let oldText = original as NSString
        let ghosts = presentation.editState.ghosts.map { block in
            DiffDecorations.GhostBlock(
                anchorLine: block.anchorLine, firstOldLine: block.firstOldLine,
                lines: block.lines.map {
                    NSAttributedString(string: oldText.substring(with: $0.sourceRange))
                }
            )
        }
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 800, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        pane.setEditBufferText(updated)
        pane.setEditingFolds(
            folds, lineOffsets: starts,
            baseDecorations: .edit(state: presentation.editState, snapshotOffsets: starts,
                                   lineCount: starts.count, ghostBlocks: ghosts),
            revision: 1
        )
        pane.layoutSubtreeIfNeeded()
        var samples: [Double] = []
        for index in 0..<30 {
            pane.setVerticalScrollOffset(CGFloat((index * 347) % 9_000))
            pane.layoutSubtreeIfNeeded()
            let started = CFAbsoluteTimeGetCurrent()
            let visible = DiffRowGeometry.visibleRows(textView: pane.textView,
                                                      decorations: pane.decorations)
            samples.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
            XCTAssertFalse(visible.isEmpty, "The native folded viewport must never lose every row")
        }
        samples.sort()
        print("AUDIT_DIFF_FOLDED_GEOMETRY lines=24000 folds=\(folds.count) samples=30 median=\(samples[15]) p95=\(samples[28]) worst=\(samples[29])")
        XCTAssertLessThanOrEqual(samples[28], 32,
                                 "Warm folded TextKit viewport geometry must meet the Debug p95 budget")
        XCTAssertEqual(pane.textView.string, updated)
    }

    func testDiffPipelineTwentyFourThousandLinePhaseCosts() async throws {
        var rows = (0..<24_000).map { "let value\($0) = \($0)\n" }
        let before = rows.joined()
        rows[12_000] = "let value12000 = -1\n"
        let after = rows.joined()
        let resolved = await DiffSyntaxHighlighter.context(for: "fixture.swift")
        let context = try XCTUnwrap(resolved)
        var coreTimes: [Double] = []
        var projectionTimes: [Double] = []
        var syntaxTimes: [Double] = []
        for _ in 0..<10 {
            var start = CFAbsoluteTimeGetCurrent()
            let core = await Task.detached(priority: .userInitiated) {
                DiffCore.compute(oldText: before, newText: after)
            }.value
            coreTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            start = CFAbsoluteTimeGetCurrent()
            let projection = await Task.detached(priority: .userInitiated) {
                DiffComputation.build(core: core, revealedLines: [])
            }.value
            projectionTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            XCTAssertTrue(projection.unified.rows.contains { $0.kind == .added })
            start = CFAbsoluteTimeGetCurrent()
            let captured = await Task.detached(priority: .userInitiated) {
                (
                    DiffSyntaxOracle.captures(text: before, context: context),
                    DiffSyntaxOracle.captures(text: after, context: context)
                )
            }.value
            syntaxTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            XCTAssertFalse(captured.0.isEmpty)
            XCTAssertFalse(captured.1.isEmpty)
        }
        coreTimes.sort()
        projectionTimes.sort()
        syntaxTimes.sort()
        print("AUDIT_DIFF_PHASE lines=24000 samples=10 coreMedian=\(coreTimes[5]) projectionMedian=\(projectionTimes[5]) syntaxMedian=\(syntaxTimes[5]) coreWorst=\(coreTimes[9]) projectionWorst=\(projectionTimes[9]) syntaxWorst=\(syntaxTimes[9])")
    }

    func testVerifiedGitHunksMatchLoadedWorktreeForLineMutationMatrix() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "worktree hunk matrix.txt"
        let file = root.appendingPathComponent(name)
        let original = "alpha\nbeta\nsame\nsame\nsame\nlast\n"
        try Data(original.utf8).write(to: file)
        for arguments in [["add", "--", name], ["commit", "-qm", "baseline"]] {
            let result = GitCommandExecution.run(arguments, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        let previous = GitCommandExecution.run(["rev-parse", "HEAD:" + name], in: root.path)
        XCTAssertEqual(previous.status, 0)
        let oldOID = previous.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let variants: [(label: String, value: String)] = [
            ("prepend", "new\n" + original),
            ("append", original + "new\n"),
            ("delete first", "beta\nsame\nsame\nsame\nlast\n"),
            ("delete all", ""),
            ("change repeated", "alpha\nbeta\nsame\nchanged\nsame\nlast\n"),
            ("two distant edits", "new\nalpha\nbeta\nsame\nsame\nsame\nLAST\n"),
            ("no final LF", "alpha\nbeta\nsame\nsame\nsame\nlast"),
            ("unicode and mixed newlines", "alpha\r\n👩‍🚀\nbeta\r\nsame\nsame\nlast\r\n"),
            ("replace entire", "完全不同\n"),
        ]
        let preferences = try isolatedPreferences()
        func rowSignatures(_ rows: [DiffRow]) -> [String] {
            rows.map { "\($0.kind) \($0.oldLine ?? 0) \($0.newLine ?? 0)" }
        }
        for variant in variants {
            try Data(variant.value.utf8).write(to: file)
            let oid = GitCommandExecution.run(
                ["hash-object", "--path=" + name, name], in: root.path
            )
            XCTAssertEqual(oid.status, 0, variant.label)
            let patch = GitCommandExecution.run(
                ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv",
                 "--no-color", "--no-renames", "--full-index", "--unified=0",
                 "--inter-hunk-context=0", "HEAD", "--", name], in: root.path
            )
            XCTAssertEqual(patch.status, 0, "\(variant.label): \(patch.stderr)")
            let comparison = try XCTUnwrap(GitWorktreeComparison.resolve(
                old: original, worktree: variant.value, patch: patch.stdout,
                oldOID: oldOID,
                newOID: oid.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            ), variant.label)
            let expected = try XCTUnwrap(DiffCore.fromVerifiedOperations(
                oldText: comparison.old, newText: comparison.new,
                operations: try XCTUnwrap(comparison.operations)
            ), variant.label)
            let tab = DiffTab(repoRoot: root.path, path: name, source: .worktree,
                              untracked: false, origPath: nil,
                              backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                              preferences: preferences)
            try await wait { !tab.isLoading && tab.display != nil }
            XCTAssertNil(tab.error, variant.label)
            XCTAssertEqual(tab.newContent, variant.value, variant.label)
            let actual = try XCTUnwrap(tab.display, variant.label).computation
            let direct = DiffComputation.build(core: expected, revealedLines: [])
            XCTAssertEqual(rowSignatures(actual.unified.rows),
                           rowSignatures(direct.unified.rows), variant.label)
            XCTAssertEqual(rowSignatures(actual.splitLeft.rows),
                           rowSignatures(direct.splitLeft.rows), variant.label)
            XCTAssertEqual(rowSignatures(actual.splitRight.rows),
                           rowSignatures(direct.splitRight.rows), variant.label)
            XCTAssertEqual(try Data(contentsOf: file), Data(variant.value.utf8), variant.label)
        }
    }

    func testLocalGitStagedAndUnstagedDiffReadyLatencyMatrix() async throws {
        for lineCount in [1_000, 24_000] {
            let root = try repository()
            defer { try? FileManager.default.removeItem(at: root) }
            let filename = "latency-\(lineCount).swift"
            let file = root.appendingPathComponent(filename)
            var lines = (0..<lineCount).map { "let value\($0) = \($0)\n" }
            try Data(lines.joined().utf8).write(to: file)
            XCTAssertEqual(GitCommandExecution.run(["add", filename], in: root.path).status, 0)
            XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: root.path).status, 0)
            lines[lineCount / 2] = "let value\(lineCount / 2) = -1\n"
            try Data(lines.joined().utf8).write(to: file)
            XCTAssertEqual(GitCommandExecution.run(["add", filename], in: root.path).status, 0)
            lines[lineCount / 2 + 1] = "let value\(lineCount / 2 + 1) = -2\n"
            try Data(lines.joined().utf8).write(to: file)

            let preferences = try isolatedPreferences()
            func load(_ source: DiffTab.Source) async throws -> Double {
                let start = CFAbsoluteTimeGetCurrent()
                let diff = DiffTab(repoRoot: root.path, path: filename, source: source,
                                   untracked: false, origPath: nil,
                                   backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                                   preferences: preferences)
                try await wait({ diff.canPresentNativeContent }, pollingInterval: .milliseconds(1),
                               timeout: 25)
                XCTAssertNil(diff.error)
                XCTAssertTrue(diff.hasChanges)
                return (CFAbsoluteTimeGetCurrent() - start) * 1_000
            }
            var staged: [Double] = []
            var unstaged: [Double] = []
            for run in 0..<30 {
                if run.isMultiple(of: 2) {
                    staged.append(try await load(.staged))
                    unstaged.append(try await load(.worktree))
                } else {
                    unstaged.append(try await load(.worktree))
                    staged.append(try await load(.staged))
                }
            }
            staged.sort()
            unstaged.sort()
            print("AUDIT_GIT_DIFF_MODEL_READY rows=\(lineCount) samples=30 stagedMedian=\(staged[15]) stagedP95=\(staged[28]) unstagedMedian=\(unstaged[15]) unstagedP95=\(unstaged[28])")
        }
    }

    func testWorktreeDiffWaitsForFoldedDisplayBeforeFirstNativeFrame() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var lines = (0..<24_000).map { "let entry\($0) = \($0)\n" }
        let path = directory.appendingPathComponent("first-frame.swift")
        try Data(lines.joined().utf8).write(to: path)
        XCTAssertEqual(GitCommandExecution.run(["add", "first-frame.swift"], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: directory.path).status, 0)
        lines[12_000] = "let entry12000 = 42\n"
        try Data(lines.joined().utf8).write(to: path)
        let tab = DiffTab(repoRoot: directory.path, path: "first-frame.swift",
                          source: .worktree, untracked: false, origPath: nil,
                          backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                          preferences: try isolatedPreferences())
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 800, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: tab, isSelected: false))
        window.contentView = host
        window.orderFront(nil)
        try await wait({
            tab.isEditing && tab.hasChanges && tab.display == nil
        }, pollingInterval: .milliseconds(1), timeout: 15)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertNil(tab.nativeSurface,
                     "An unfinished diff must not briefly expose the full editable source")
        try await wait({ tab.display != nil }, timeout: 20)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return tab.nativeSurface?.subviews.compactMap { $0 as? DiffCodePaneView }
                .contains { !$0.isHidden && $0.decorations.rows.contains { $0.collapsed != nil } }
                == true
        }
        XCTAssertEqual(try Data(contentsOf: path), Data(lines.joined().utf8))
    }

    func testReopeningGitChangesDuringDiffPreparationKeepsTheOriginalRead() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var lines = (0..<24_000).map { "let value\($0) = \($0)\n" }
        let file = directory.appendingPathComponent("reopen.swift")
        try Data(lines.joined().utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["add", "reopen.swift"], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: directory.path).status, 0)
        lines[12_000] = "let value12000 = 42\n"
        try Data(lines.joined().utf8).write(to: file)

        let project = Project(fallbackName: "Git", workspaceConfiguration: .standard)
        project.customDirectory = directory.path
        project.openDiff(repoRoot: directory.path, path: "reopen.swift", staged: false,
                         untracked: false, origPath: nil, activating: false)
        let firstTab = try XCTUnwrap(project.selectedTab)
        guard case .diff(let diff) = firstTab.content else {
            return XCTFail("Git Changes must create a DiffTab")
        }
        try await wait({
            !diff.isLoading && diff.hasChanges && diff.display != nil
        }, pollingInterval: .milliseconds(1), timeout: 15)

        project.openDiff(repoRoot: directory.path, path: "reopen.swift", staged: false,
                         untracked: false, origPath: nil, activating: false)
        XCTAssertTrue(project.selectedTab === firstTab)
        XCTAssertFalse(diff.isLoading,
                       "Reopening an unfinished diff must not restart its Git read")
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 800, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.orderFront(nil)
        XCTAssertFalse(diff.isLoading, "Mounting the selected diff must not restart its read")
        try await wait({ diff.display != nil }, timeout: 20)
        XCTAssertTrue(try XCTUnwrap(diff.display).computation.unified.rows.contains {
            $0.collapsed != nil
        })
        let keyword = try XCTUnwrap(SyntaxHighlightCoordinator.themeColor(
            for: "keyword", theme: SyntaxHighlighting.theme
        ))
        try await wait({
            guard let colored = diff.display?.unifiedText else { return false }
            let location = (colored.string as NSString).range(of: "let value12000").location
            guard location != NSNotFound else { return false }
            return (colored.attribute(.foregroundColor, at: location,
                                      effectiveRange: nil) as? NSColor) == keyword
        }, timeout: 20)

        lines[13_000] = "let value13000 = 43\n"
        let latest = lines.joined()
        try Data(latest.utf8).write(to: file)
        project.openDiff(repoRoot: directory.path, path: "reopen.swift", staged: false,
                         untracked: false, origPath: nil, activating: false)
        try await wait({ diff.newContent == latest && !diff.isLoading }, timeout: 15)
        try await wait({ diff.display?.computation.unified.text.contains("value13000 = 43") == true },
                       timeout: 20)
        XCTAssertEqual(try Data(contentsOf: file), Data(latest.utf8))
    }

    func testActiveCleanWorktreeEditorSurvivesNewDiffComputation() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var lines = (0..<20_000).map { "line \($0)\n" }
        let path = directory.appendingPathComponent("was-clean.txt")
        try Data(lines.joined().utf8).write(to: path)
        XCTAssertEqual(GitCommandExecution.run(["add", "was-clean.txt"], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: directory.path).status, 0)
        let tab = DiffTab(repoRoot: directory.path, path: "was-clean.txt",
                          source: .worktree, untracked: false, origPath: nil,
                          backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                          preferences: try isolatedPreferences())
        try await wait { !tab.isLoading && tab.isEditing && !tab.hasChanges }
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 800, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: tab, isSelected: false))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return tab.nativeSurface?.subviews.compactMap { $0 as? DiffCodePaneView }
                .contains { !$0.isHidden && $0.textView.isEditable } == true
        }
        let editor = try XCTUnwrap(tab.nativeSurface?.subviews
            .compactMap { $0 as? DiffCodePaneView }.first { $0.textView.isEditable })
        XCTAssertTrue(window.makeFirstResponder(editor.textView))
        XCTAssertTrue(tab.editorActive)

        lines[10_000] = "line 10000 is changed\n"
        let modified = lines.joined()
        try Data(modified.utf8).write(to: path)
        tab.reload()
        try await wait({
            tab.hasChanges && tab.display == nil
        }, pollingInterval: .milliseconds(1), timeout: 15)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(tab.canPresentNativeContent,
                      "A pending diff must not hide a native editor that owns keyboard focus")
        XCTAssertFalse(editor.isHidden)
        try await wait({ tab.display != nil }, timeout: 20)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(editor.isHidden)
        XCTAssertEqual(editor.textView.text, modified)
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(try Data(contentsOf: path), Data(modified.utf8))
    }

    func testTextKitContentDelegateCanCollapseLayoutWithoutChangingEditableStorage() async throws {
        final class Filter: NSObject, NSTextContentStorageDelegate {
            func textContentManager(_ textContentManager: NSTextContentManager,
                                    shouldEnumerate textElement: NSTextElement,
                                    options: NSTextContentManager.EnumerationOptions) -> Bool {
                !((textElement as? NSTextParagraph)?.attributedString.string
                    .hasPrefix("hidden ") ?? false)
            }
        }
        let filter = Filter()
        let source = "first visible\n"
            + (0..<120).map { "hidden \($0)\n" }.joined()
            + "last visible\n"
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 800, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        window.contentView = pane
        window.orderFront(nil)
        pane.setEditBufferText(source)
        pane.textView.nativeContentManager.delegate = filter
        pane.textView.nativeLayoutManager.invalidateLayout(
            for: pane.textView.nativeLayoutManager.documentRange)
        pane.layoutSubtreeIfNeeded()
        var shown: [String] = []
        pane.textView.nativeLayoutManager.enumerateTextLayoutFragments(
            in: pane.textView.nativeLayoutManager.documentRange) { fragment in
            shown.append((fragment.textElement as? NSTextParagraph)?.attributedString.string ?? "")
            return true
        }
        XCTAssertEqual(pane.textView.string, source)
        XCTAssertTrue(pane.textView.isEditable)
        XCTAssertTrue(shown.contains { $0.contains("first visible") })
        XCTAssertTrue(shown.contains { $0.contains("last visible") })
        XCTAssertFalse(shown.contains { $0.contains("hidden ") },
                       "Native TextKit can skip layout of unchanged paragraphs without altering source")
    }

    func testFoldedGitLineHidesAllItsNativeCRParagraphsExceptSeparator() throws {
        let original = "head\rtail\n" + (0..<240).map { "line \($0)\n" }.joined()
        let modified = original.replacingOccurrences(of: "line 170\n", with: "changed 170\n")
        let core = DiffCore.compute(oldText: original, newText: modified)
        let folds = DiffEditFold.sourceFolds(
            in: DiffComputation.build(core: core, revealedLines: []).unified,
            lineCount: core.newLines.count
        )
        XCTAssertEqual(folds.first?.range.lowerBound, 0)
        let offsets = core.newLines.map(\.utf16Range.location)
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 700, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        pane.setEditBufferText(modified)
        pane.setEditingFolds(
            folds, lineOffsets: offsets,
            baseDecorations: .edit(
                state: DiffComputation.editState(ops: core.ops, oldLines: core.oldLines,
                                                 newLines: core.newLines),
                snapshotOffsets: offsets, lineCount: offsets.count, ghostBlocks: []
            ), revision: 1
        )
        pane.layoutSubtreeIfNeeded()
        func laidOutParagraphs() -> [String] {
            var result: [String] = []
            pane.textView.nativeLayoutManager.enumerateTextLayoutFragments(
                in: pane.textView.nativeLayoutManager.documentRange
            ) { fragment in
                result.append((fragment.textElement as? NSTextParagraph)?.attributedString.string ?? "")
                return true
            }
            return result
        }
        let collapsed = laidOutParagraphs()
        XCTAssertTrue(collapsed.contains { $0.contains("head") },
                      "The fold's first native paragraph hosts its separator")
        XCTAssertFalse(collapsed.contains { $0.contains("tail") },
                       "A bare CR cannot expose a second paragraph inside a hidden Git LF line")
        XCTAssertEqual(pane.textView.string, modified)
        pane.setEditingFolds([], lineOffsets: offsets, baseDecorations: .empty, revision: 2)
        XCTAssertTrue(laidOutParagraphs().contains { $0.contains("tail") })
        XCTAssertEqual(pane.textView.string, modified)
    }


    func testFoldIndicatorIsClippedInsideScrollContentAndNeverCoversScroller() throws {
        let before = (0..<320).map { "line \($0)\n" }.joined()
        var after = before
        for line in stride(from: 16, through: 304, by: 16) {
            let replacement = line == 160
                ? "changed " + String(repeating: "long ", count: 100)
                : "changed \(line)"
            after = after.replacingOccurrences(of: "line \(line)\n", with: replacement + "\n")
        }
        let core = DiffCore.compute(oldText: before, newText: after)
        let compared = DiffComputation.build(core: core, revealedLines: [])
        let folds = DiffEditFold.sourceFolds(in: compared.unified, lineCount: core.newLines.count)
        XCTAssertFalse(folds.isEmpty)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        var didScrollHorizontally = false

        for dark in [false, true] {
            for editable in [false, true] {
                for style in [NSScroller.Style.legacy, .overlay] {
                    let window = NSWindow(
                        contentRect: NSRect(x: -900, y: -900, width: 820, height: 400),
                        styleMask: [.titled], backing: .buffered, defer: false
                    )
                    window.isReleasedWhenClosed = false
                    defer { window.close() }
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let pane = DiffCodePaneView(mode: editable ? .edit : .review, gutterLayout: .single)
                    window.contentView = pane
                    window.orderFront(nil)
                    pane.scrollView.scrollerStyle = style
                    pane.scrollView.autohidesScrollers = false
                    pane.applyTypography(
                        font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                        textColor: Theme.terminal(dark: dark).foregroundNSColor
                    )
                    if editable {
                        pane.setEditBufferText(after)
                        let offsets = core.newLines.map(\.utf16Range.location)
                        pane.setEditingFolds(
                            folds, lineOffsets: offsets,
                            baseDecorations: .edit(
                                state: compared.editState, snapshotOffsets: offsets,
                                lineCount: offsets.count, ghostBlocks: []
                            ), revision: 1
                        )
                    } else {
                        pane.setReviewDocument(
                            NSAttributedString(string: compared.unified.text),
                            decorations: .review(compared.unified)
                        )
                    }
                    pane.layoutSubtreeIfNeeded()
                    pane.scrollView.layoutSubtreeIfNeeded()
                    XCTAssertTrue(DiffRowGeometry.visibleRows(
                        textView: pane.textView, decorations: pane.decorations
                    ).contains { $0.index < pane.decorations.rows.count
                        && pane.decorations.rows[$0.index].collapsed != nil })
                    let clip = pane.scrollView.contentView
                    let verticalScroller = try XCTUnwrap(pane.scrollView.verticalScroller)
                    let horizontalScroller = pane.scrollView.horizontalScroller
                    let overlay = try XCTUnwrap(clip.subviews.first {
                        String(describing: type(of: $0)) == "DiffFoldOverlayView"
                    })
                    XCTAssertTrue(pane.scrollView.documentView === pane.textView,
                                  "The clipped overlay must not displace the editable document")
                    XCTAssertFalse(pane.subviews.contains {
                        String(describing: type(of: $0)) == "DiffFoldOverlayView"
                    }, "Fold overlay must not cover the whole scroll view")
                    let layers = pane.scrollView.subviews
                    let clipIndex = try XCTUnwrap(layers.firstIndex(of: clip))
                    let scrollerIndex = try XCTUnwrap(layers.firstIndex(of: verticalScroller))
                    XCTAssertLessThan(clipIndex, scrollerIndex,
                                      "The clipped content must remain behind native scrollers")
                    if let horizontalScroller {
                        let horizontalIndex = try XCTUnwrap(layers.firstIndex(of: horizontalScroller))
                        XCTAssertLessThan(clipIndex, horizontalIndex,
                                          "The clipped content must remain behind the horizontal scroller")
                    }
                    XCTAssertEqual(overlay.frame, clip.bounds,
                                   "Fold label must be clipped to the visible document rectangle")
                    if style == .legacy {
                        XCTAssertLessThanOrEqual(clip.frame.maxX, verticalScroller.frame.minX + 1)
                    }
                    let requested = NSRect(origin: NSPoint(x: 90, y: 160), size: clip.bounds.size)
                    let allowed = clip.constrainBoundsRect(requested).origin
                    pane.setScrollOffset(requested.origin)
                    XCTAssertEqual(clip.bounds.origin.x, allowed.x, accuracy: 1)
                    didScrollHorizontally = didScrollHorizontally || clip.bounds.origin.x > 1
                    XCTAssertGreaterThan(clip.bounds.origin.y, 0)
                    XCTAssertEqual(overlay.frame, clip.bounds,
                                   "Overlay must remain pinned to the viewport while scrolling")
                    window.setContentSize(NSSize(width: 460, height: 300))
                    pane.layoutSubtreeIfNeeded()
                    pane.scrollView.layoutSubtreeIfNeeded()
                    XCTAssertEqual(overlay.frame, clip.bounds,
                                   "Overlay must track viewport changes on resize")
                    pane.scrollView.scrollerStyle = style == .legacy ? .overlay : .legacy
                    pane.scrollView.layoutSubtreeIfNeeded()
                    XCTAssertEqual(overlay.frame, clip.bounds,
                                   "Overlay must track the visible region when scrollbar style changes")
                }
            }
        }
        XCTAssertTrue(didScrollHorizontally,
                      "At least one case must exercise actual horizontal scrolling")
    }

    func testFoldIndicatorUsesTheSameForegroundPixelsInReviewAndEdit() throws {
        let before = (0..<320).map { "line \($0)\n" }.joined()
        let after = before.replacingOccurrences(of: "line 160\n", with: "changed 160\n")
        let core = DiffCore.compute(oldText: before, newText: after)
        let compared = DiffComputation.build(core: core, revealedLines: [])
        let folds = DiffEditFold.sourceFolds(in: compared.unified,
                                              lineCount: core.newLines.count)
        XCTAssertFalse(folds.isEmpty)
        let previous = before as NSString
        let ghostBlocks = compared.editState.ghosts.map { block in
            DiffDecorations.GhostBlock(
                anchorLine: block.anchorLine, firstOldLine: block.firstOldLine,
                lines: block.lines.map { NSAttributedString(string: previous.substring(with: $0.sourceRange)) }
            )
        }

        func foldedOverlay(dark: Bool, editable: Bool) throws -> NSBitmapImageRep {
            let window = NSWindow(
                contentRect: NSRect(x: -900, y: -900, width: 820, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let pane = DiffCodePaneView(mode: editable ? .edit : .review, gutterLayout: .single)
            window.contentView = pane
            window.orderFront(nil)
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            pane.applyTypography(font: font,
                                 paragraphStyle: DiffTypography.paragraphStyle(for: font),
                                 textColor: Theme.terminal(dark: dark).foregroundNSColor)
            if editable {
                pane.setEditBufferText(after)
                let offsets = core.newLines.map(\.utf16Range.location)
                pane.setEditingFolds(
                    folds, lineOffsets: offsets,
                    baseDecorations: .edit(state: compared.editState,
                                           snapshotOffsets: offsets,
                                           lineCount: offsets.count, ghostBlocks: ghostBlocks),
                    revision: 1
                )
            } else {
                pane.setReviewDocument(NSAttributedString(string: compared.unified.text),
                                       decorations: .review(compared.unified))
            }
            pane.layoutSubtreeIfNeeded()
            pane.scrollView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertTrue(DiffRowGeometry.visibleRows(
                textView: pane.textView, decorations: pane.decorations
            ).contains { $0.index < pane.decorations.rows.count
                && pane.decorations.rows[$0.index].collapsed != nil })
            let gutter = try XCTUnwrap(pane.subviews.compactMap { $0 as? DiffGutterView }.first)
            let button = try XCTUnwrap(gutter.accessibilityChildren()?.first as? NSAccessibilityElement)
            var expanded: DiffCollapsedRun?
            pane.onExpandCollapsedRun = { expanded = $0 }
            XCTAssertTrue(button.accessibilityPerformPress())
            XCTAssertNotNil(expanded,
                            "Both read-only and editable folds must expose an AX expand action")
            let separator = try XCTUnwrap(DiffRowGeometry.visibleRows(
                textView: pane.textView, decorations: pane.decorations
            ).first { $0.index < pane.decorations.rows.count
                && pane.decorations.rows[$0.index].collapsed != nil })
            expanded = nil
            let windowPoint = pane.textView.convert(
                NSPoint(x: 24, y: separator.frame.midY), to: nil
            )
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: windowPoint,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            pane.textView.mouseDown(with: event)
            XCTAssertNotNil(expanded,
                            "Clicking the actual folded text row must expand in both modes")
            let overlay = try XCTUnwrap(pane.scrollView.contentView.subviews.first {
                String(describing: type(of: $0)) == "DiffFoldOverlayView"
            })
            let bitmap = try XCTUnwrap(
                overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds)?
                    .retagging(with: .sRGB)
            )
            overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
            return bitmap
        }

        for dark in [false, true] {
            let review = try foldedOverlay(dark: dark, editable: false)
            let edit = try foldedOverlay(dark: dark, editable: true)
            XCTAssertEqual(review.pixelsWide, edit.pixelsWide)
            XCTAssertEqual(review.pixelsHigh, edit.pixelsHigh)
            var differing = 0
            var painted = 0
            for y in 0..<min(review.pixelsHigh, edit.pixelsHigh) {
                for x in 0..<min(220, review.pixelsWide, edit.pixelsWide) {
                    let a = review.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
                    let b = edit.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
                    if a.alphaComponent > 0.15 { painted += 1 }
                    if abs(a.alphaComponent - b.alphaComponent) > 0.04 ||
                        abs(a.redComponent - b.redComponent) > 0.04 ||
                        abs(a.greenComponent - b.greenComponent) > 0.04 ||
                        abs(a.blueComponent - b.blueComponent) > 0.04 {
                        differing += 1
                    }
                }
            }
            XCTAssertGreaterThan(painted, 200,
                                 "Both layouts must visibly paint a folded separator")
            XCTAssertLessThan(differing, 160,
                              "Read-only and editable xx unmodified lines must share one visual renderer")
        }
    }

    func testEditingBeforeExpandedContextRetainsItsSourceLinesWithoutOpeningOtherFolds() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = (0..<1_200).map { "line \($0)\n" }.joined()
        let modified = original
            .replacingOccurrences(of: "line 400\n", with: "changed 400\n")
            .replacingOccurrences(of: "line 700\n", with: "changed 700\n")
        let path = directory.appendingPathComponent("stable-fold.txt")
        try Data(original.utf8).write(to: path)
        XCTAssertEqual(GitCommandExecution.run(["add", "stable-fold.txt"], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: directory.path).status, 0)
        try Data(modified.utf8).write(to: path)

        let tab = DiffTab(repoRoot: directory.path, path: "stable-fold.txt",
                          source: .worktree, untracked: false, origPath: nil,
                          backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                          preferences: try isolatedPreferences())
        tab.autoSaveSuspendedForClose = true
        try await wait { tab.isEditing && tab.editFoldsReady && tab.editFolds.count >= 3 }
        let tail = try XCTUnwrap(tab.editFolds.last)
        XCTAssertGreaterThan(tail.range.lowerBound, 700)
        tab.expandRun(tail.separator)
        try await wait { !tab.editFolds.contains { $0.range.contains(720) } }
        XCTAssertTrue(tab.editFolds.contains { $0.range.contains(500) })

        let priorRevision = tab.editPresentationRevision
        let next = modified.replacingOccurrences(of: "line 180\n", with: "changed 180\n")
        tab.updateEditedContent(next)
        try await wait { tab.editPresentationRevision > priorRevision }
        XCTAssertTrue(tab.isDirty)
        XCTAssertFalse(tab.editFolds.contains { $0.range.contains(720) },
                       "Typing before a revealed region must not refold its original source lines")
        XCTAssertTrue(tab.editFolds.contains { $0.range.contains(500) },
                      "Typing elsewhere must not apply a stale fold ordinal to a different region")
        XCTAssertEqual(try Data(contentsOf: path), Data(modified.utf8))

        await tab.save()
        try await wait {
            !tab.isLoading && tab.newContent == next && tab.editFoldsReady
                && !tab.isDirty
        }
        XCTAssertFalse(tab.editFolds.contains { $0.range.contains(720) },
                       "Saving the edited worktree must not collapse a manually revealed baseline range")
        XCTAssertTrue(tab.editFolds.contains { $0.range.contains(500) },
                      "Saving must not unfold unrelated unchanged regions")
        XCTAssertEqual(try Data(contentsOf: path), Data(next.utf8))
        XCTAssertEqual(GitCommandExecution.run(["status", "--porcelain=v1"], in: directory.path).stdout,
                       " M stable-fold.txt\n")

        XCTAssertEqual(GitCommandExecution.run(["add", "stable-fold.txt"], in: directory.path).status, 0)
        let later = next.replacingOccurrences(of: "changed 400\n", with: "revised 400\n")
        try Data(later.utf8).write(to: path)
        tab.reload()
        try await wait { !tab.isLoading && tab.newContent == later && tab.editFoldsReady }
        XCTAssertTrue(tab.editFolds.contains { $0.range.contains(720) },
                      "A new Git index baseline must discard reveals anchored to the previous index")
        XCTAssertEqual(try Data(contentsOf: path), Data(later.utf8))
        XCTAssertEqual(GitCommandExecution.run(["status", "--porcelain=v1"], in: directory.path).stdout,
                       "MM stable-fold.txt\n")
    }

    func testRapidRepeatedFoldClicksRevealDistinctUnchangedLines() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = (0..<1_200).map { "line \($0)\n" }.joined()
        let modified = original.replacingOccurrences(of: "line 400\n", with: "changed 400\n")
        let file = directory.appendingPathComponent("rapid-fold.txt")
        try Data(original.utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["add", "rapid-fold.txt"], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: directory.path).status, 0)
        try Data(modified.utf8).write(to: file)

        let tab = DiffTab(repoRoot: directory.path, path: "rapid-fold.txt",
                          source: .worktree, untracked: false, origPath: nil,
                          backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                          preferences: try isolatedPreferences())
        tab.autoSaveSuspendedForClose = true
        try await wait { tab.isEditing && tab.editFoldsReady && tab.editFolds.count >= 2 }
        let tail = try XCTUnwrap(tab.editFolds.last?.separator)
        XCTAssertEqual(tail.direction, .revealDown)
        XCTAssertTrue(tail.baselineRange.contains(550))
        XCTAssertTrue(tail.baselineRange.contains(650))
        tab.expandRun(tail)
        tab.expandRun(tail)
        try await wait {
            tab.editFoldsReady && tab.editFolds.contains { $0.range.contains(650) }
                && !tab.editFolds.contains { $0.range.contains(550) }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data(modified.utf8))
    }

    func testWorktreeFoldedEditorKeepsFoldsOnClickAndExpandsOnlyOnSeparator() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = (0..<320).map { "line \($0)\n" }.joined()
        let modified = original.replacingOccurrences(of: "line 160\n", with: "changed 160\n")
        let path = directory.appendingPathComponent("folded.txt")
        try Data(original.utf8).write(to: path)
        XCTAssertEqual(GitCommandExecution.run(["add", "folded.txt"], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: directory.path).status, 0)
        try Data(modified.utf8).write(to: path)

        let tab = DiffTab(repoRoot: directory.path, path: "folded.txt", source: .worktree,
                          untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
                          workspaceIdentity: nil, preferences: try isolatedPreferences())
        try await wait { tab.display != nil && tab.editDecorations.rows.count == 320 }
        let display = try XCTUnwrap(tab.display)
        let foldMapping = DiffEditFold.sourceFolds(in: display.computation.unified,
                                                    lineCount: 320)
        XCTAssertFalse(foldMapping.isEmpty,
                       "Fold mapping from actual Git new-line numbers must retain hidden intervals")
        tab.autoSaveSuspendedForClose = true
        let window = NSWindow(contentRect: NSRect(x: -930, y: -930, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: tab))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return tab.nativeSurface != nil
        }
        let surface = try XCTUnwrap(tab.nativeSurface)
        let visible = surface.subviews.compactMap { $0 as? DiffCodePaneView }
            .filter { !$0.isHidden }
        XCTAssertEqual(visible.count, 1)
        let editor = try XCTUnwrap(visible.first)
        XCTAssertTrue(editor.textView.isEditable,
                      "The folded presentation must itself be the editable source document")
        XCTAssertEqual(editor.textView.string, modified)
        XCTAssertFalse(tab.isDirty)
        XCTAssertFalse(tab.showsCanonicalComparison)
        XCTAssertFalse(editor.textView.editingFolds.isEmpty,
                       "native fold mapping: \(foldMapping.count), dirty: \(tab.isDirty), editing: \(tab.isEditing), canonical: \(tab.showsCanonicalComparison), source: \(tab.editDecorations.editSnapshotOffsets.count)")
        XCTAssertTrue(editor.decorations.rows.contains { $0.collapsed != nil })
        editor.layoutSubtreeIfNeeded()
        editor.scrollView.layoutSubtreeIfNeeded()
        editor.textView.layoutSubtreeIfNeeded()
        let visibleRows = DiffRowGeometry.visibleRows(textView: editor.textView,
                                                      decorations: editor.decorations)
        XCTAssertTrue(visibleRows.contains {
            $0.index < editor.decorations.rows.count &&
                editor.decorations.rows[$0.index].collapsed != nil
        }, "Native folded editor must expose real visible separator rows; visible indexes: \(visibleRows.map(\.index)), fold indexes: \(editor.textView.editingFolds.map { $0.range.lowerBound })")
        let before = editor.textView.editingFolds
        let surfaceID = ObjectIdentifier(editor.textView)
        editor.textView.setSelectedRange(NSRange(location: 30, length: 0))
        window.makeFirstResponder(editor.textView)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.textView.editingFolds, before,
                       "Moving the caret and focusing editable code must not unfold context")
        XCTAssertEqual(ObjectIdentifier(editor.textView), surfaceID)
        let gutter = try XCTUnwrap(editor.subviews.compactMap { $0 as? DiffGutterView }.first)
        func firstLabel() -> String? {
            (gutter.accessibilityChildren()?.first as? NSAccessibilityElement)?
                .accessibilityLabel()
        }
        let priorLabel = try XCTUnwrap(firstLabel())
        let previousDisplay = tab.display?.id
        tab.expandRun(try XCTUnwrap(before.first).separator)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return tab.display?.id != previousDisplay
        }
        try await wait {
            host.layoutSubtreeIfNeeded()
            return firstLabel() != nil && firstLabel() != priorLabel
        }
        XCTAssertEqual(ObjectIdentifier(editor.textView), surfaceID)
        XCTAssertEqual(editor.textView.string, modified)
        XCTAssertTrue(tab.isEditing)
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(try Data(contentsOf: path), Data(modified.utf8))
    }

    func testEditableSplitAlignsFullWorktreeWithReadOnlyBaselineAcrossFoldedContext() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = (0..<900).map { "line \($0)\n" }.joined()
        let file = directory.appendingPathComponent("large.txt")
        try Data(original.utf8).write(to: file)
        for arguments in [["add", "large.txt"], ["commit", "-qm", "baseline"]] {
            XCTAssertEqual(GitCommandExecution.run(arguments, in: directory.path).status, 0)
        }
        let modified = original.replacingOccurrences(of: "line 600\n", with: "changed 600\n")
        try Data(modified.utf8).write(to: file)
        let preferences = try isolatedPreferences()
        preferences.diffStyle = .split
        let tab = DiffTab(
            repoRoot: directory.path, path: "large.txt", source: .worktree,
            untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: nil, preferences: preferences
        )
        try await wait { tab.display != nil && tab.editDecorations.rows.count == 900 }
        tab.autoSaveSuspendedForClose = true
        let window = NSWindow(contentRect: NSRect(x: -930, y: -930, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: tab))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            let panes = tab.nativeSurface?.subviews.compactMap { $0 as? DiffCodePaneView }
                .filter { !$0.isHidden } ?? []
            return panes.count == 2
        }
        let surface = try XCTUnwrap(tab.nativeSurface)
        let compactPanes = surface.subviews.compactMap { $0 as? DiffCodePaneView }
            .filter { !$0.isHidden }
        XCTAssertEqual(compactPanes.filter { $0.textView.isEditable }.count, 1)
        let baseline = try XCTUnwrap(compactPanes.first { !$0.textView.isEditable })
        let editor = try XCTUnwrap(compactPanes.first { $0.textView.isEditable })
        XCTAssertTrue(baseline.decorations.rows.contains { $0.collapsed != nil })
        XCTAssertTrue(editor.decorations.rows.contains { $0.collapsed != nil })
        XCTAssertFalse(editor.textView.editingFolds.isEmpty)
        let originalFolds = editor.textView.editingFolds
        XCTAssertLessThan(baseline.decorations.rows.count, editor.decorations.rows.count,
                          "Only the editable source owns all physical lines")
        XCTAssertEqual(editor.textView.string, modified)
        let content = editor.textView.nativeContentManager
        let offset = tab.editDecorations.editSnapshotOffsets[599]
        let sourceRange = try XCTUnwrap(NSTextRange(NSRange(location: offset, length: 1), in: content))
        let layout = editor.textView.nativeLayoutManager
        layout.ensureLayout(for: sourceRange)
        let changedFragment = try XCTUnwrap(layout.textLayoutFragment(for: sourceRange.location))
        XCTAssertLessThan(changedFragment.layoutFragmentFrame.minY, 600,
                          "Folded TextKit layout must remove the physical height of hidden lines")
        try await wait {
            host.layoutSubtreeIfNeeded()
            return editor.textView.window === window
        }
        XCTAssertTrue(window.makeFirstResponder(editor.textView))
        XCTAssertTrue(window.firstResponder === editor.textView,
                      "Split focus must reach the mounted native worktree editor")
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(editor.textView.editingFolds.isEmpty,
                       "Split editor focus must not unfold unchanged lines")
        let previousID = tab.editableBaseline?.id
        let caret = (modified as NSString).range(of: "changed 600").location
        editor.textView.insertText("new line\n", replacementRange: NSRange(location: caret, length: 0))
        try await wait {
            tab.editableBaseline?.id != previousID && tab.editDecorations.rows.count == 901
        }
        try await wait {
            host.layoutSubtreeIfNeeded()
            return editor.textView.editingFolds != originalFolds
                && baseline.decorations.rows.contains { $0.collapsed != nil }
        }
        XCTAssertTrue(tab.isDirty)
        XCTAssertGreaterThan(editor.textView.editingFolds.last?.range.lowerBound ?? -1,
                             originalFolds.last?.range.lowerBound ?? -1,
                             "A newline before a later fold must shift the actual hidden source lines")
        XCTAssertEqual(editor.textView.string,
                       (modified as NSString).replacingCharacters(
                           in: NSRange(location: caret, length: 0), with: "new line\n"))
        XCTAssertEqual(try Data(contentsOf: file), Data(modified.utf8),
                       "Typing into a diff cannot write the file before an explicit save")
        editor.textView.undoManager?.undo()
        try await wait { !tab.isDirty }
        XCTAssertEqual(editor.textView.string, modified)
        XCTAssertFalse(editor.textView.editingFolds.isEmpty)
    }

    func testEditableSplitUsesEmptyCaretRowForFirstRemovedFileLine() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("empty.txt")
        try Data("first\nsecond\nthird\n".utf8).write(to: path)
        for arguments in [["add", "empty.txt"], ["commit", "-qm", "baseline"]] {
            XCTAssertEqual(GitCommandExecution.run(arguments, in: directory.path).status, 0)
        }
        try Data().write(to: path)
        let preferences = try isolatedPreferences()
        preferences.diffStyle = .split
        let tab = DiffTab(
            repoRoot: directory.path, path: "empty.txt", source: .worktree,
            untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: nil, preferences: preferences
        )
        try await wait { tab.editableBaseline != nil && !tab.editDecorations.rows.isEmpty }
        let originalRows = try XCTUnwrap(tab.editableBaseline).document.rows.count
        XCTAssertEqual(originalRows, 3)
        XCTAssertEqual(tab.editDecorations.rows.count, 1)
        XCTAssertEqual(
            originalRows,
            tab.editDecorations.rows.count
                + tab.editDecorations.ghostsByAnchor.values.reduce(0) { $0 + $1.lines.count },
            "An empty editor already owns one real cursor row; Split must not add a fourth row"
        )
        XCTAssertEqual(try Data(contentsOf: path), Data())
    }

    func testNativeEditableDiffPaintsDeletedGhostRowsInBothThemes() throws {
        let old = "first\ndeleted\nlast\n"
        let current = "first\nlast\n"
        let core = DiffCore.compute(oldText: old, newText: current)
        let state = DiffComputation.editState(
            ops: core.ops, oldLines: core.oldLines, newLines: core.newLines
        )
        let starts = DiffLineSplitter.lines(of: current).lines.map(\.utf16Range.location)
        for dark in [false, true] {
            let pane = DiffCodePaneView(mode: .edit, gutterLayout: .newOnly)
            let window = NSWindow(
                contentRect: NSRect(x: -920, y: -920, width: 680, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = pane
            window.orderFront(nil)
            let scheme = DiffColorScheme.current(dark: dark)
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let foreground = Theme.terminal(dark: dark).foregroundNSColor
            pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                                 textColor: foreground)
            pane.setEditBufferText(current)
            pane.decorations = .edit(
                state: state, snapshotOffsets: starts, lineCount: starts.count,
                ghostBlocks: [.init(anchorLine: 1, firstOldLine: 2, lines: [
                    NSAttributedString(string: "deleted", attributes: [
                        .font: font, .foregroundColor: foreground,
                    ]),
                ])]
            )
            XCTAssertEqual(pane.decorations.ghostsByAnchor[1]?.lines.count, 1)
            pane.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds)?
                .retagging(with: .sRGB))
            pane.cacheDisplay(in: pane.bounds, to: bitmap)
            let expected = try XCTUnwrap(scheme.removedRow.usingColorSpace(.sRGB))
            let matching = sRGBColumn(bitmap, x: bitmap.pixelsWide - 50).reduce(0) { total, sample in
                let isRemoval = abs((sample.greenComponent - sample.redComponent)
                    - (expected.greenComponent - expected.redComponent)) < 0.03
                    && abs((sample.blueComponent - sample.redComponent)
                        - (expected.blueComponent - expected.redComponent)) < 0.03
                return total + (isRemoval ? 1 : 0)
            }
            XCTAssertGreaterThan(matching, 8,
                                 "Editable diff deletion ghosts must be visibly red, dark=\(dark)")
            window.close()
        }
    }

    func testFoldedEditableDiffDrawsRemovalGhostBesideChangedSource() throws {
        let before = (0..<500).map { "line \($0)\n" }.joined()
        let after = before.replacingOccurrences(of: "line 250\n", with: "changed 250\n")
        let core = DiffCore.compute(oldText: before, newText: after)
        let state = DiffComputation.editState(
            ops: core.ops, oldLines: core.oldLines, newLines: core.newLines
        )
        let folds = DiffEditFold.sourceFolds(
            in: DiffComputation.build(core: core, revealedLines: []).unified,
            lineCount: core.newLines.count
        )
        XCTAssertFalse(folds.isEmpty)
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: .init(x: -930, y: -930, width: 680, height: 330),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .textColor)
        pane.setEditBufferText(after)
        let offsets = core.newLines.map(\.utf16Range.location)
        let removed = try XCTUnwrap(state.ghosts.first)
        XCTAssertEqual(removed.anchorLine, 250)
        let base = DiffDecorations.edit(
            state: state, snapshotOffsets: offsets, lineCount: offsets.count,
            ghostBlocks: [
                .init(anchorLine: removed.anchorLine, firstOldLine: removed.firstOldLine,
                      lines: [NSAttributedString(string: "line 250", attributes: [
                        .font: font, .foregroundColor: NSColor.textColor,
                      ])]),
            ]
        )
        pane.setEditingFolds(folds, lineOffsets: offsets, baseDecorations: base, revision: 1)
        pane.layoutSubtreeIfNeeded()
        pane.scrollToRow(250)
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds)?
            .retagging(with: .sRGB))
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        let dark = pane.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let expected = try XCTUnwrap(DiffColorScheme.current(dark: dark).removedRow.usingColorSpace(.sRGB))
        let count = sRGBColumn(bitmap, x: bitmap.pixelsWide - 50).filter { sample in
            abs((sample.greenComponent - sample.redComponent)
                - (expected.greenComponent - expected.redComponent)) < 0.03 &&
            abs((sample.blueComponent - sample.redComponent)
                - (expected.blueComponent - expected.redComponent)) < 0.03
        }.count
        XCTAssertGreaterThan(count, 8,
                             "Collapsed context must not move real removed rows offscreen")
        XCTAssertEqual(pane.textView.string, after)
    }

    func testLongDeletedBlockRemainsVisibleInsideFoldedEditorViewport() throws {
        let prefix = (0..<400).map { "before \($0)\n" }.joined()
        let removed = (0..<500).map { "deleted \($0)\n" }.joined()
        let suffix = (0..<400).map { "after \($0)\n" }.joined()
        let before = prefix + removed + suffix
        let after = prefix + suffix
        let core = DiffCore.compute(oldText: before, newText: after)
        let state = DiffComputation.editState(
            ops: core.ops, oldLines: core.oldLines, newLines: core.newLines
        )
        let folds = DiffEditFold.sourceFolds(
            in: DiffComputation.build(core: core, revealedLines: []).unified,
            lineCount: core.newLines.count
        )
        XCTAssertEqual(state.ghosts.first?.lines.count, 500)
        XCTAssertGreaterThanOrEqual(folds.count, 2)
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: .init(x: -930, y: -930, width: 680, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .textColor)
        pane.setEditBufferText(after)
        let starts = core.newLines.map(\.utf16Range.location)
        pane.setEditingFolds(
            folds, lineOffsets: starts,
            baseDecorations: .edit(state: state, snapshotOffsets: starts,
                                   lineCount: starts.count, ghostBlocks: [
                .init(anchorLine: 400, firstOldLine: 401,
                      lines: (0..<500).map { NSAttributedString(string: "deleted \($0)") }),
            ]),
            revision: 1
        )
        pane.layoutSubtreeIfNeeded()
        let dark = pane.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let red = try XCTUnwrap(DiffColorScheme.current(dark: dark).removedRow.usingColorSpace(.sRGB))
        for offset: CGFloat in [2_000, 6_000] {
            pane.setVerticalScrollOffset(offset)
            pane.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds)?
                .retagging(with: .sRGB))
            pane.cacheDisplay(in: pane.bounds, to: bitmap)
            let redPixels = sRGBColumn(bitmap, x: bitmap.pixelsWide - 50).filter { pixel in
                abs((pixel.greenComponent - pixel.redComponent)
                    - (red.greenComponent - red.redComponent)) < 0.03 &&
                abs((pixel.blueComponent - pixel.redComponent)
                    - (red.blueComponent - red.redComponent)) < 0.03
            }.count
            XCTAssertGreaterThan(redPixels, 8,
                                 "Long deletion must paint inside folded viewport at y=\(offset)")
        }
        XCTAssertEqual(pane.textView.string, after)
    }

    func testLongDiffLineTruncationPreservesGhostSpacingAndTypography() throws {
        let long = String(repeating: "0123456789", count: 2_200)
        let old = long + "\nremoved\nlast\n"
        let current = long + "\nlast\n"
        let core = DiffCore.compute(oldText: old, newText: current)
        let state = DiffComputation.editState(
            ops: core.ops, oldLines: core.oldLines, newLines: core.newLines
        )
        let starts = DiffLineSplitter.lines(of: current).lines.map(\.utf16Range.location)
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .newOnly)
        let window = NSWindow(
            contentRect: NSRect(x: -920, y: -920, width: 680, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = pane
        window.orderFront(nil)
        defer { window.close() }
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let style = DiffTypography.paragraphStyle(for: font)
        pane.applyTypography(font: font, paragraphStyle: style, textColor: .black)
        pane.setEditBufferText(current)
        pane.decorations = .edit(
            state: state, snapshotOffsets: starts, lineCount: starts.count,
            ghostBlocks: [.init(anchorLine: 1, firstOldLine: 2, lines: [
                NSAttributedString(string: "removed")
            ])]
        )
        pane.layoutSubtreeIfNeeded()

        let editor = pane.textView
        XCTAssertTrue(editor.truncatesLongLines)
        XCTAssertEqual(editor.frame.width, 12288, accuracy: 1)
        let firstStyle = try XCTUnwrap(editor.textStorage?.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil
        ) as? NSParagraphStyle)
        XCTAssertEqual(firstStyle.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(firstStyle.minimumLineHeight, style.minimumLineHeight)

        let lastStyle = try XCTUnwrap(editor.textStorage?.attribute(
            .paragraphStyle, at: starts[1], effectiveRange: nil
        ) as? NSParagraphStyle)
        XCTAssertEqual(lastStyle.lineBreakMode, .byTruncatingTail)
        XCTAssertGreaterThan(lastStyle.paragraphSpacingBefore, 0)

        pane.applyTypography(font: font, paragraphStyle: style, textColor: .black)
        XCTAssertEqual(editor.defaultParagraphStyle?.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(editor.text, current)

        pane.setEditBufferText("short\nlast\n")
        pane.layoutSubtreeIfNeeded()
        XCTAssertFalse(editor.truncatesLongLines)
        XCTAssertEqual(editor.text, "short\nlast\n")
    }

    func testDiffLongLineWidthModesPreserveEditGhostsAndReviewText() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let style = DiffTypography.paragraphStyle(for: font)
        let full = String(repeating: "x", count: 9_000) + "\nshort\n"
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: CGRect(x: -950, y: -950, width: 680, height: 280),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        window.orderFront(nil)
        defer { window.close() }
        pane.applyTypography(font: font, paragraphStyle: style, textColor: .black,
                             longLineDisplayWidth: .standard)
        pane.setEditBufferText(full)
        let old = String(repeating: "x", count: 9_000) + "\nremoved\nshort\n"
        let core = DiffCore.compute(oldText: old, newText: full)
        let state = DiffComputation.editState(
            ops: core.ops, oldLines: core.oldLines, newLines: core.newLines
        )
        let starts = DiffLineSplitter.lines(of: full).lines.map(\.utf16Range.location)
        pane.decorations = .edit(state: state, snapshotOffsets: starts, lineCount: starts.count,
        ghostBlocks: [.init(anchorLine: 1, firstOldLine: 2,
                            lines: [NSAttributedString(string: "removed")])])
        pane.layoutSubtreeIfNeeded()
        let editor = pane.textView
        XCTAssertEqual(editor.frame.width, 12_288, accuracy: 1)
        let before = try XCTUnwrap(editor.textStorage?.attribute(
            .paragraphStyle, at: 9_001, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(before.paragraphSpacingBefore, 0)
        for mode in [LongLineDisplayWidth.expanded, .showAll, .compact, .standard] {
            pane.applyTypography(font: font, paragraphStyle: style, textColor: .black,
                                 longLineDisplayWidth: mode)
            pane.layoutSubtreeIfNeeded()
            let actual = CGFloat(mode == .showAll
                ? LongLineDisplayWidth.expanded.rawValue : mode.rawValue)
            XCTAssertLessThanOrEqual(editor.frame.width, max(680, actual) + 1)
            let after = try XCTUnwrap(editor.textStorage?.attribute(
                .paragraphStyle, at: 9_001, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(after.paragraphSpacingBefore, before.paragraphSpacingBefore,
                           "Ghost spacing must survive \(mode)")
            XCTAssertEqual(editor.text, full)
            if mode == .showAll {
                XCTAssertTrue(editor.wrapsLines)
                let fragment = try XCTUnwrap(editor.nativeLayoutManager.textLayoutFragment(
                    for: editor.nativeLayoutManager.documentRange.location
                ))
                XCTAssertGreaterThan(fragment.textLineFragments.count, 1)
            }
        }
        let review = DiffCodePaneView(mode: .review, gutterLayout: .single)
        review.frame = CGRect(x: 0, y: 0, width: 600, height: 250)
        window.contentView = review
        review.applyTypography(font: font, paragraphStyle: style, textColor: .black,
                               longLineDisplayWidth: .showAll)
        let document = DiffComputation.compute(oldText: full, newText: full).unified
        review.setReviewDocument(NSAttributedString(string: document.text),
                                 decorations: .review(document))
        review.layoutSubtreeIfNeeded()
        XCTAssertFalse(review.textView.truncatesLongLines)
        XCTAssertTrue(review.textView.wrapsLines)
        XCTAssertGreaterThan(review.textView.overrideContentHeight ?? 0,
                             CGFloat(document.rows.count) * style.maximumLineHeight,
                             "Wrapped review must use measured native layout height, not Git row count")
        XCTAssertEqual(review.textView.text, document.text)
        review.applyTypography(font: font, paragraphStyle: style, textColor: .black,
                               longLineDisplayWidth: .standard)
        XCTAssertTrue(review.textView.truncatesLongLines)
        XCTAssertFalse(review.textView.wrapsLines)
        XCTAssertEqual(review.textView.overrideContentHeight,
                       CGFloat(document.rows.count) * style.maximumLineHeight,
                       "Returning to fixed lines must restore the split/unified row height")
        review.applyTypography(font: font, paragraphStyle: style, textColor: .black,
                               longLineDisplayWidth: .showAll)
        review.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(review.textView.overrideContentHeight ?? 0,
                             CGFloat(document.rows.count) * style.maximumLineHeight)
        XCTAssertEqual(review.textView.text, document.text)
    }

    func testFullDisplayDiffScrollToGitRowUsesWrappedParagraphGeometry() throws {
        let line = String(repeating: "abcdefghij", count: 7_000)
        let source = line + "\nsecond\nthird\n"
        let document = DiffComputation.compute(oldText: source, newText: source).unified
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        let window = NSWindow(contentRect: CGRect(x: -950, y: -950, width: 650, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        window.orderFront(nil)
        defer { window.close() }
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .black, longLineDisplayWidth: .showAll)
        pane.setReviewDocument(NSAttributedString(string: document.text),
                               decorations: .review(document))
        pane.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(pane.textView.overrideContentHeight ?? 0,
                             CGFloat(document.rows.count) * 15,
                             "Long wrapped lines must have a stable native scroll range")
        let initialHeight = pane.textView.frame.height
        pane.scrollToRow(1)
        XCTAssertGreaterThan(pane.scrollOffset.y, 80,
                             "Anchor must follow wrapped layout, not a one-row offset")
        pane.setVerticalScrollOffset(1_000_000)
        pane.textView.nativeLayoutManager.textViewportLayoutController.layoutViewport()
        XCTAssertEqual(pane.textView.frame.height, initialHeight, accuracy: 1,
                       "Wrapped source must have its complete scroll range before scrolling")
        let bottom = DiffRowGeometry.visibleRows(textView: pane.textView,
                                                 decorations: pane.decorations)
        XCTAssertTrue(bottom.contains { $0.index >= document.rows.count - 1 },
                      "The final wrapped review line must remain reachable")
        XCTAssertEqual(pane.textView.text, document.text)
    }

    func testLongCRLogicalRowDoesNotPutEOFGhostsAtViewportBoundary() {
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(
            contentRect: NSRect(x: -990, y: -990, width: 600, height: 170),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pane.applyTypography(
            font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
            textColor: .textColor
        )
        let source = (0..<150).map { "part\($0)" }.joined(separator: "\r") + "\n"
        pane.setEditBufferText(source)
        let split = DiffLineSplitter.lines(of: source).lines
        let core = DiffCore.compute(oldText: "deleted\n", newText: source)
        let state = DiffComputation.editState(
            ops: core.ops, oldLines: core.oldLines, newLines: core.newLines
        )
        XCTAssertEqual(split.count, 1)
        pane.decorations = .edit(
            state: state, snapshotOffsets: split.map(\.utf16Range.location),
            lineCount: split.count,
            ghostBlocks: [
                .init(anchorLine: 1, firstOldLine: 1, lines: [NSAttributedString(string: "deleted")])
            ]
        )
        pane.layoutSubtreeIfNeeded()
        let visible = DiffRowGeometry.visibleRows(
            textView: pane.textView, decorations: pane.decorations
        ).filter { $0.index == 0 }
        XCTAssertGreaterThan(visible.count, 1)
        XCTAssertLessThan(visible.count, 150, "Viewport must not eagerly paint the entire CR file")
        XCTAssertTrue(visible.allSatisfy { !$0.isLastSegment },
                      "The viewport edge is not the real EOF ghost anchor")
    }

    func testUnicodeLineSeparatorsDecorateEveryNativeVisualSegment() {
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        let window = NSWindow(
            contentRect: NSRect(x: -960, y: -960, width: 650, height: 340),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pane.applyTypography(
            font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
            textColor: .textColor
        )

        for separator in ["\u{2028}", "\u{0085}", "\u{2029}", "\r"] {
            let text = "before" + separator + "after\n"
            let document = DiffComputation.compute(oldText: "", newText: text).unified
            XCTAssertEqual(document.rows.count, 1)
            pane.setReviewDocument(NSAttributedString(string: document.text),
                                   decorations: .review(document))
            pane.layoutSubtreeIfNeeded()
            let paintedRows = DiffRowGeometry.visibleRows(
                textView: pane.textView, decorations: pane.decorations
            ).filter { $0.index == 0 }
            XCTAssertEqual(paintedRows.count, 2,
                           "Both native visual lines within one Git LF row must have decoration geometry")
            if paintedRows.count == 2 {
                XCTAssertFalse(paintedRows[0].isContinuation)
                XCTAssertTrue(paintedRows[1].isContinuation,
                              "A continuation must not draw the same gutter number or ghost again")
                XCTAssertFalse(paintedRows[0].isLastSegment,
                               "EOF markers and deletion ghosts belong after the final native part")
                XCTAssertTrue(paintedRows[1].isLastSegment)
                XCTAssertGreaterThan(paintedRows[1].frame.minY, paintedRows[0].frame.minY)
                XCTAssertTrue(paintedRows[0].frame.maxY <= paintedRows[1].frame.minY + 1)
            }
        }
    }

    func testDeletingEveryEditLineKeepsEOFRemovalGhostScrollAccessible() {
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(
            contentRect: NSRect(x: -950, y: -950, width: 600, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pane.applyTypography(
            font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
            textColor: .textColor
        )
        pane.setEditBufferText("")
        let core = DiffCore.compute(oldText: "deleted one\ndeleted two\n", newText: "")
        let state = DiffComputation.editState(
            ops: core.ops, oldLines: core.oldLines, newLines: core.newLines
        )
        XCTAssertEqual(state.ghosts.first?.anchorLine, 0)
        pane.decorations = .edit(
            state: state, snapshotOffsets: [], lineCount: 0,
            ghostBlocks: [
                .init(anchorLine: 0, firstOldLine: 1, lines: [
                    NSAttributedString(string: "deleted one"),
                    NSAttributedString(string: "deleted two"),
                ])
            ]
        )
        XCTAssertEqual(pane.decorations.rows.count, 1, "Empty editable buffer keeps its virtual row")
        XCTAssertEqual(pane.decorations.ghostsByAnchor[1]?.lines.count, 2,
                       "Deletions from an empty buffer belong after its virtual row")
        XCTAssertGreaterThanOrEqual(
            pane.textView.overrideContentHeight ?? 0,
            3 * DiffTypography.paragraphStyle(for: font).maximumLineHeight,
            "An empty edit buffer still needs enough native scroll height to show deleted lines"
        )
        XCTAssertEqual(pane.textView.text, "")
        pane.setEditBufferText("restored\n")
        XCTAssertNil(pane.textView.overrideContentHeight,
                     "Typing into the empty editor must remove its virtual ghost height")
        pane.setEditBufferText("")
        XCTAssertNotNil(pane.textView.overrideContentHeight)
        pane.decorations = .empty
        XCTAssertNil(pane.textView.overrideContentHeight)
    }

    func testDeletedGhostSpacingStaysOnOneTextKitParagraphWithBareCR() throws {
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pane.applyTypography(
            font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
            textColor: .textColor
        )
        let source = "first\rsecond\nthird\n"
        pane.setEditBufferText(source)
        let split = DiffLineSplitter.lines(of: source)
        let core = DiffCore.compute(oldText: "deleted\n", newText: source)
        let state = DiffComputation.editState(
            ops: core.ops, oldLines: core.oldLines, newLines: core.newLines
        )
        XCTAssertEqual(state.ghosts.first?.anchorLine, 0)
        pane.decorations = .edit(
            state: state, snapshotOffsets: split.lines.map(\.utf16Range.location),
            lineCount: split.lines.count,
            ghostBlocks: [
                .init(anchorLine: 0, firstOldLine: 1, lines: [NSAttributedString(string: "deleted")])
            ]
        )
        let attributed = try XCTUnwrap(pane.textView.attributedText)
        let firstStyle = try XCTUnwrap(
            attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        let secondStyle = try XCTUnwrap(
            attributed.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertGreaterThan(firstStyle.paragraphSpacingBefore, 0)
        XCTAssertEqual(secondStyle.paragraphSpacingBefore, 0,
                       "One Git deletion must not insert ghost spacing into every native CR paragraph")

        pane.decorations = .edit(
            state: state, snapshotOffsets: split.lines.map(\.utf16Range.location),
            lineCount: split.lines.count,
            ghostBlocks: [
                .init(anchorLine: split.lines.count, firstOldLine: 1,
                      lines: [NSAttributedString(string: "deleted")])
            ]
        )
        let endAttributes = try XCTUnwrap(pane.textView.attributedText)
        let firstAtEnd = try XCTUnwrap(
            endAttributes.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        let lastAtEnd = try XCTUnwrap(
            endAttributes.attribute(.paragraphStyle, at: 13, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(firstAtEnd.paragraphSpacingBefore, 0)
        XCTAssertEqual(firstAtEnd.paragraphSpacing, 0)
        XCTAssertGreaterThan(lastAtEnd.paragraphSpacing, 0)

        pane.decorations = .edit(
            state: state, snapshotOffsets: split.lines.map(\.utf16Range.location),
            lineCount: split.lines.count, ghostBlocks: []
        )
        let cleared = try XCTUnwrap(pane.textView.attributedText)
        for offset in [0, 6, 13] {
            let style = try XCTUnwrap(
                cleared.attribute(.paragraphStyle, at: offset, effectiveRange: nil)
                    as? NSParagraphStyle
            )
            XCTAssertEqual(style.paragraphSpacingBefore, 0)
            XCTAssertEqual(style.paragraphSpacing, 0)
        }
        XCTAssertEqual(pane.textView.text, source)
    }

    func testEditGeometryUsesGitLFLinesAcrossNativeBareCRParagraphs() async throws {
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(
            contentRect: NSRect(x: -900, y: -900, width: 730, height: 410),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pane.applyTypography(
            font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
            textColor: .textColor
        )
        let raw = "alpha\rbeta\nsecond\n"
        pane.setEditBufferText(raw)
        let lines = DiffLineSplitter.lines(of: raw).lines
        let computation = DiffComputation.compute(oldText: "", newText: raw)
        pane.decorations = DiffDecorations.edit(
            state: computation.editState,
            snapshotOffsets: lines.map(\.utf16Range.location),
            lineCount: lines.count, ghostBlocks: []
        )
        try await wait {
            DiffRowGeometry.visibleRows(
                textView: pane.textView, decorations: pane.decorations
            ).count >= 3
        }
        let rows = DiffRowGeometry.visibleRows(
            textView: pane.textView, decorations: pane.decorations
        )
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(Array(rows.prefix(3).map(\.index)), [0, 0, 1],
                       "TextKit bare-CR paragraphs must share the same Git LF line number")
        XCTAssertEqual(Array(rows.prefix(3).map(\.isContinuation)), [false, true, false],
                       "Only the first native visual fragment may draw Git gutter/ghost metadata")
        XCTAssertEqual(Array(rows.prefix(3).map(\.isLastSegment)), [false, true, true])
        XCTAssertTrue(pane.textView.hasNativeNonLFSeparators)

        pane.setEditBufferText("alpha\nsecond\n")
        XCTAssertFalse(pane.textView.hasNativeNonLFSeparators)
        pane.textView.insertText("\r", replacementRange: NSRange(location:2,length:0))
        XCTAssertTrue(pane.textView.hasNativeNonLFSeparators,
                      "Actual native editing must invalidate the prior layout mapping")
        pane.textView.breakUndoCoalescing()
        pane.textView.undoManager?.undo()
        XCTAssertFalse(pane.textView.hasNativeNonLFSeparators,
                       "Undo must restore the ordinary LF layout mapping")
    }

    func testBareCRReviewUsesTextKitParagraphHeightInsteadOfLFOnlyHeight() {
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 700, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pane.applyTypography(
            font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
            textColor: .textColor
        )

        let normal = DiffComputation.compute(oldText: "before\n", newText: "after\n").unified
        pane.setReviewDocument(NSAttributedString(string: normal.text), decorations: .review(normal))
        XCTAssertNotNil(pane.textView.overrideContentHeight)
        let crlf = DiffComputation.compute(oldText: "before\r\n", newText: "after\r\n").unified
        pane.setReviewDocument(NSAttributedString(string: crlf.text), decorations: .review(crlf))
        XCTAssertNotNil(pane.textView.overrideContentHeight,
                        "Normal CRLF remains one TextKit paragraph per Git line")

        let manyCRs = (0..<90).map { "part\($0)" }.joined(separator: "\r")
        let unusual = DiffComputation.compute(
            oldText: manyCRs + "\n", newText: manyCRs + "\rchanged\n"
        ).unified
        pane.setReviewDocument(NSAttributedString(string: unusual.text), decorations: .review(unusual))
        pane.layoutSubtreeIfNeeded()
        let elements = pane.textView.nativeContentManager.textElements(
            for: pane.textView.nativeLayoutManager.documentRange
        )
        XCTAssertGreaterThan(elements.count, unusual.rows.count,
                             "Bare CR forms additional TextKit paragraphs within one Git LF line")
        XCTAssertGreaterThan(pane.textView.overrideContentHeight ?? 0,
                             CGFloat(unusual.rows.count) * 15,
                             "Native CR paragraph height must be measured, not inferred from Git LF rows")
        XCTAssertEqual(pane.textView.attributedText.string, unusual.text)

        let unicode = DiffComputation.compute(
            oldText: "before\u{2028}after\n", newText: "before\u{2028}updated\n"
        ).unified
        pane.setReviewDocument(NSAttributedString(string: unicode.text), decorations: .review(unicode))
        pane.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(pane.textView.overrideContentHeight ?? 0,
                             CGFloat(unicode.rows.count) * 12,
                             "Unicode separators must use measured native content height")
    }

    func testStagedDeletionShowsDeletedLinesInsteadOfMissingRevision() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("deleted.txt")
        let original = "first\r\nsecond\r\n"
        try Data(original.utf8).write(to: path)
        for args in [["add", "deleted.txt"], ["commit", "-qm", "baseline"],
                     ["rm", "deleted.txt"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: root.path).status, 0)
        }
        let diff = DiffTab(
            repoRoot: root.path, path: "deleted.txt", source: .staged,
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
            preferences: try isolatedPreferences()
        )
        try await wait { !diff.isLoading }
        XCTAssertNil(diff.error)
        XCTAssertEqual(Data(diff.oldContent.utf8), Data(original.utf8))
        XCTAssertEqual(diff.newContent, "")
        try await wait { diff.display != nil }
        let display = try XCTUnwrap(diff.display)
        XCTAssertEqual(display.computation.unified.rows.compactMap(\.oldLine), [1, 2])
        XCTAssertTrue(display.unifiedText.string.contains("second"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await wait {
            self.findNativeTextView(in: host, editable: false)?.attributedText.string
                == display.unifiedText.string
        }
    }

    func testStagedConflictWithoutStageZeroIsNotADeletion() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conflict.txt")
        try Data("base\n".utf8).write(to: file)
        for args in [["add", "conflict.txt"], ["commit", "-qm", "base"],
                     ["checkout", "-qb", "other"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: root.path).status, 0)
        }
        try Data("theirs\n".utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qam", "other"], in: root.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["checkout", "-q", "main"], in: root.path).status, 0)
        try Data("ours\n".utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qam", "ours"], in: root.path).status, 0)
        XCTAssertNotEqual(GitCommandExecution.run(["merge", "other"], in: root.path).status, 0)
        let unmerged = GitCommandExecution.run(["ls-files", "-u", "--", "conflict.txt"], in: root.path)
        XCTAssertEqual(unmerged.status, 0, unmerged.stderr)
        XCTAssertEqual(unmerged.stdout.split(separator: "\n").count, 3,
                       "The fixture must contain all three conflict stages")
        let diff = DiffTab(
            repoRoot: root.path, path: "conflict.txt", source: .staged,
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
            preferences: try isolatedPreferences()
        )
        try await wait { !diff.isLoading }
        XCTAssertNotNil(diff.error)
        XCTAssertFalse(diff.hasLoadedContent)
    }

    func testAppearanceChangeAfterReadErrorKeepsLastSuccessfulDiff() async throws {
        let domain = "bailey-diff-appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        // Keep the same native tab through a read failure and appearance change.
        let preferences = DiffViewPreferences(defaults: defaults)
        preferences.diffStyle = .unified
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("review.txt")
        try Data("before\n".utf8).write(to: path)
        for args in [["add", "review.txt"], ["commit", "-qm", "baseline"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: root.path).status, 0)
        }
        try Data("after\n".utf8).write(to: path)
        let diff = DiffTab(
            repoRoot: root.path, path: "review.txt", source: .worktree,
            untracked: false, origPath: nil,
            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
            preferences: preferences
        )
        try await wait { !diff.isLoading && diff.display != nil }
        let before = try XCTUnwrap(diff.display)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await wait {
            self.findNativeTextView(in: host, editable: true)?.text == "after\n"
        }
        let git = root.appendingPathComponent(".git")
        let unavailable = root.appendingPathComponent(".git-unavailable")
        try FileManager.default.moveItem(at: git, to: unavailable)
        defer { try? FileManager.default.moveItem(at: unavailable, to: git) }
        diff.reload()
        try await wait { !diff.isLoading && diff.error != nil }
        XCTAssertEqual(diff.display?.computation.unified.text, before.computation.unified.text)
        diff.refreshNativeAppearance()
        try await wait({ diff.display?.id != before.id && diff.display != nil }, timeout: 3)
        XCTAssertEqual(diff.display?.computation.unified.text, before.computation.unified.text)
        try await wait {
            self.findNativeTextView(in: host, editable: false)?.attributedText.string
                == diff.display?.unifiedText.string
                && diff.nativeSurface?.superview != nil
        }
        XCTAssertNotNil(diff.error)
    }

    func testIncompleteSelectedGitBlobFailsInsteadOfPublishingTruncatedContent() async throws {
        let backend = DiffWorkspaceFixture()
        await backend.simulateIncompleteGitBlob()
        let domain = "bailey-diff-short-git-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let tab = DiffTab(
            repoRoot: "/fixture", path: "stable.txt", source: .staged,
            untracked: false, origPath: nil, backend: backend,
            workspaceIdentity: nil, preferences: DiffViewPreferences(defaults: defaults)
        )
        try await wait { !tab.isLoading }
        XCTAssertNotNil(tab.error)
        XCTAssertEqual(tab.error, String(localized: "Incomplete Git content", table: "Git"))
        XCTAssertFalse(tab.hasLoadedContent)
        XCTAssertEqual(tab.newContent, "")
    }

    func testFoldingPreviousDisplayCannotOverrideNewLoadedDiff() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("pending.swift")
        var lines = (0..<3600).map { "let value\($0) = \($0)\n" }
        try Data(lines.joined().utf8).write(to: file)
        for args in [["add", "."], ["commit", "-qm", "baseline"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        lines[1800] = "let value1800 = 111111\n"
        try Data(lines.joined().utf8).write(to: file)
        let preferences = try isolatedPreferences()
        let tab = DiffTab(
            repoRoot: directory.path, path: "pending.swift", source: .worktree,
            untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: nil, preferences: preferences
        )
        try await wait({ !tab.isLoading && tab.display != nil }, timeout: 15)
        let oldDisplay = try XCTUnwrap(tab.display)
        let oldFold = try XCTUnwrap(oldDisplay.computation.unified.rows.compactMap(\.collapsed).first)
        lines[1800] = "let value1800 = 222222\n"
        lines[2000] = "let value2000 = 333333\n"
        let latest = lines.joined()
        try Data(latest.utf8).write(to: file)
        tab.reload()
        try await wait({ tab.newContent.utf8.elementsEqual(latest.utf8) }, pollingInterval: .milliseconds(1), timeout: 15)
        XCTAssertNotEqual(tab.display?.id, oldDisplay.id,
                          "A newly accepted snapshot must not show the previous file's row mapping")
        tab.expandRun(oldFold)
        try await wait({ tab.display != nil && tab.display?.id != oldDisplay.id }, timeout: 15)
        let rendered = try XCTUnwrap(tab.display)
        XCTAssertEqual(Data(tab.newContent.utf8), Data(latest.utf8))
        XCTAssertTrue(rendered.computation.unified.text.contains("333333"),
                      "A fold from the previous display must not supersede the newest loaded source")
    }

    func testIndexMutationDuringGitContentReadUsesSelectedImmutableBlob() async throws {
        let backend = DiffWorkspaceFixture()
        await backend.simulateIndexChangeAfterSize()
        let domain = "bailey-diff-index-race-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let tab = DiffTab(
            repoRoot: "/fixture", path: "stable.txt", source: .staged,
            untracked: false, origPath: nil, backend: backend,
            workspaceIdentity: nil, preferences: DiffViewPreferences(defaults: defaults)
        )
        try await wait { !tab.isLoading }
        XCTAssertNil(tab.error)
        XCTAssertEqual(tab.oldContent, "head\n")
        XCTAssertEqual(tab.newContent, "indexA\n",
                       "One stage read must keep the OID captured by metadata despite a later index mutation")
    }

    func testCanonicalEquivalentEditDuringDiffWriteRemainsDirty() async throws {
        let domain = "bailey-canonical-save-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "canonical.txt", source: .worktree,
                           untracked: true, origPath: nil, backend: backend,
                           workspaceIdentity: nil, preferences: DiffViewPreferences(defaults: defaults))
        try await wait { !diff.isLoading }
        diff.updateEditedContent("café")
        let saving = Task { await diff.save() }
        try await wait { await backend.writing }
        diff.updateEditedContent("cafe\u{301}")
        await backend.finishWrite()
        await saving.value
        let stored = await backend.stored()
        XCTAssertEqual(stored, Data("café".utf8))
        XCTAssertTrue(diff.isDirty)
        XCTAssertEqual(Data(diff.editedNewContent.utf8), Data("cafe\u{301}".utf8))
    }

    func testCanonicalEquivalentGitContentIsARealDiff() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("canonical.txt")
        let composed = "let café = 1\n"
        let decomposed = "let cafe\u{301} = 1\n"
        try Data(composed.utf8).write(to: path)
        for arguments in [["add", "."], ["commit", "-qm", "baseline"]] {
            XCTAssertEqual(GitCommandExecution.run(arguments, in: directory.path).status, 0)
        }
        try Data(decomposed.utf8).write(to: path)
        let domain = "bailey-canonical-diff-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let diff = DiffTab(repoRoot: directory.path, path: "canonical.txt", source: .worktree,
                           untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil, preferences: preferences)
        try await wait { !diff.isLoading }
        XCTAssertNil(diff.error)
        XCTAssertEqual(Data(diff.oldContent.utf8), Data(composed.utf8))
        XCTAssertEqual(Data(diff.newContent.utf8), Data(decomposed.utf8))
        XCTAssertTrue(diff.hasChanges)
        guard diff.hasChanges else { return }
        try await wait { diff.display != nil }
        let display = try XCTUnwrap(diff.display)
        XCTAssertTrue(display.computation.unified.rows.contains { $0.kind == .removed })
        XCTAssertTrue(display.computation.unified.rows.contains { $0.kind == .added })
    }

    func testTextContainingGitBinaryPatchWordsOpensAndSavesInWorktreeDiff() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ordinary.txt")
        try Data("before\n".utf8).write(to: path)
        for arguments in [["add", "ordinary.txt"], ["commit", "-qm", "baseline"]] {
            XCTAssertEqual(GitCommandExecution.run(arguments, in: directory.path).status, 0)
        }
        let changed = "Binary files a/x and b/x differ\nGIT binary patch\n"
        try Data(changed.utf8).write(to: path)
        let tab = DiffTab(
            repoRoot: directory.path, path: "ordinary.txt", source: .worktree,
            untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: nil, preferences: try isolatedPreferences()
        )
        try await wait { !tab.isLoading }
        XCTAssertNil(tab.error, "Text lines must not be treated as binary patch metadata")
        try await wait { tab.display != nil }
        XCTAssertEqual(tab.newContent, changed)
        XCTAssertTrue(tab.hasChanges)
        XCTAssertTrue(tab.isEditing)
        tab.updateEditedContent(changed + "saved\n")
        await tab.save()
        XCTAssertNil(tab.saveError)
        XCTAssertEqual(try Data(contentsOf: path), Data((changed + "saved\n").utf8))
    }

    func testCanonicalEquivalentNativeDiffEditSaveAndReload() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("canonical.txt")
        let composed = "café 中文👋\n"
        let decomposed = "cafe\u{301} 中文👋\n"
        try Data(composed.utf8).write(to: path)
        let domain = "bailey-canonical-edit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let diff = DiffTab(repoRoot: directory.path, path: "canonical.txt", source: .worktree,
                           untracked: true, origPath: nil, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil, preferences: preferences)
        try await wait { !diff.isLoading && diff.display != nil }
        diff.autoSaveSuspendedForClose = true
        let host = NSHostingView(rootView: DiffViewerView(diff: diff))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(findNativeTextView(in: host, editable: true))
        editor.insertText(decomposed, replacementRange: NSRange(location: 0, length: composed.utf16.count))
        editor.breakUndoCoalescing()
        XCTAssertEqual(Data(diff.editedNewContent.utf8), Data(decomposed.utf8))
        XCTAssertTrue(diff.isDirty)
        editor.undoManager?.undo()
        XCTAssertFalse(diff.isDirty)
        editor.undoManager?.redo()
        XCTAssertTrue(diff.isDirty)
        await diff.save()
        XCTAssertEqual(try Data(contentsOf: path), Data(decomposed.utf8))
        XCTAssertFalse(diff.isDirty)
        try await wait { diff.newContent.utf8.elementsEqual(decomposed.utf8) }
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.text, decomposed)
        try Data(composed.utf8).write(to: path)
        diff.reload()
        try await wait { !diff.isLoading }
        try await wait { diff.display?.computation.splitRight.text.utf8.elementsEqual(composed.utf8) == true }
        let newDisplayID = diff.display?.id
        try Data(decomposed.utf8).write(to: path)
        diff.reload()
        try await wait { !diff.isLoading }
        try await wait { diff.display?.id != newDisplayID }
        XCTAssertEqual(Data(try XCTUnwrap(diff.display).computation.splitRight.text.utf8), Data(decomposed.utf8))
    }

    private func clickDiffSourceRow(_ pane: DiffCodePaneView, in window: NSWindow) async throws {
        try await wait {
            pane.layoutSubtreeIfNeeded()
            pane.scrollView.layoutSubtreeIfNeeded()
            pane.textView.nativeLayoutManager.textViewportLayoutController.layoutViewport()
            return DiffRowGeometry.visibleRows(
                textView: pane.textView, decorations: pane.decorations
            ).contains { row in
                row.index < pane.decorations.rows.count
                    && pane.decorations.rows[row.index].newLine != nil
            }
        }
        let rows = DiffRowGeometry.visibleRows(
            textView: pane.textView, decorations: pane.decorations
        )
        let target = try XCTUnwrap(rows.first {
            $0.index < pane.decorations.rows.count
                && pane.decorations.rows[$0.index].newLine != nil
                && pane.decorations.rows[$0.index].collapsed == nil
        })
        let position = pane.textView.convert(
            NSPoint(x: 12, y: target.frame.midY), to: nil
        )
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: position, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 1
        ))
        pane.textView.mouseDown(with: click)
    }

    private func findNativeSurface(in view: NSView) -> DiffNativeSurface? {
        if let surface = view as? DiffNativeSurface { return surface }
        return view.subviews.lazy.compactMap { self.findNativeSurface(in: $0) }.first
    }

    private func findNativeTextView(in view: NSView, editable: Bool? = nil) -> DiffTextView? {
        if let textView = view as? DiffTextView,
           editable == nil || textView.isEditable == editable { return textView }
        return view.subviews.lazy.compactMap { self.findNativeTextView(in: $0, editable: editable) }.first
    }

    private func wait(
        _ condition: () async -> Bool,
        pollingInterval: Duration = .milliseconds(15),
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline {
                XCTFail("Native or backend operation did not settle", file: file, line: line)
                throw WorkspaceError.timedOut
            }
            try await Task.sleep(for: pollingInterval)
        }
    }

    private func repository() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for arguments in [
            ["init", "-q", "-b", "main"], ["config", "user.name", "Diff Test"],
            ["config", "user.email", "test@invalid"], ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", "/dev/null"],
        ] {
            let result = GitCommandExecution.run(arguments, in: directory.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        return directory
    }

    func testSwitchingLoadedDiffTabsKeepsEachNativeDocument() async throws {
        let suite = "bailey-diff-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let aBackend = DiffWorkspaceFixture()
        let bBackend = DiffWorkspaceFixture()
        let a = DiffTab(repoRoot: "/fixture", path: "A.txt", source: .worktree,
                        untracked: true, origPath: nil, backend: aBackend,
                        workspaceIdentity: nil, preferences: preferences)
        try await wait { a.display != nil }

        let selection = DiffSelectionFixture(a)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 570),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffSelectionFixtureView(selection: selection))
        window.contentView = host
        window.orderFront(nil)
        try await wait { self.findNativeSurface(in: host) === a.nativeSurface && a.nativeSurface != nil }

        await bBackend.pauseOneRead()
        let b = DiffTab(repoRoot: "/fixture", path: "B.txt", source: .worktree,
                        untracked: true, origPath: nil, backend: bBackend,
                        workspaceIdentity: nil, preferences: preferences)
        selection.selected = b
        try await wait { await bBackend.reading }
        await bBackend.finishRead(with: Data("different B document".utf8))
        try await wait { b.display != nil && self.findNativeSurface(in: host) === b.nativeSurface && b.nativeSurface != nil }
        XCTAssertNotEqual(a.newContent, b.newContent)

        selection.selected = a
        try await wait { self.findNativeSurface(in: host)?.diff === a }
        XCTAssertTrue(findNativeSurface(in: host) === a.nativeSurface,
                      "Returning A must mount A's own TextKit document, not B's")
        selection.selected = b
        try await wait { self.findNativeSurface(in: host)?.diff === b }
        XCTAssertTrue(findNativeSurface(in: host) === b.nativeSurface)
    }

    func testNativeDiffEditorFocusLossSavesThroughBackend() async throws {
        let suite = "bailey-diff-focus-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "editable.txt", source: .worktree,
                           untracked: true, origPath: nil, backend: backend,
                           workspaceIdentity: nil, preferences: preferences)
        try await wait { !diff.isLoading && diff.isEditable }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 570),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await wait { diff.nativeSurface != nil }
        let surface = try XCTUnwrap(diff.nativeSurface)
        let editor = try XCTUnwrap(findNativeTextView(in: surface, editable: true))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("new🙂", replacementRange: NSRange(location: 0, length: 0))
        try await wait { diff.isDirty }
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await wait { await backend.writing }
        await backend.finishWrite()
        try await wait { !diff.isDirty }
        let saved = await backend.stored()
        XCTAssertEqual(saved, Data("new🙂baseline😀\r\n".utf8))
    }

    func testFocusTriggeredDiffSavePreservesNewestBufferAndFailure() async throws {
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "editable.txt", source: .worktree,
                           untracked: true, origPath: nil, backend: backend,
                           workspaceIdentity: "ssh:fixture", preferences: try isolatedPreferences())
        try await wait { !diff.isLoading && diff.isEditable }
        diff.updateEditedContent("first 中文😀")
        let writesBeforeFocusLoss = await backend.writes
        XCTAssertEqual(writesBeforeFocusLoss, 0, "Editing alone must not automatically write")
        diff.autoSaveOnFocusLoss()
        try await wait { await backend.writing }
        diff.updateEditedContent("second 中文🪨")
        diff.autoSaveOnFocusLoss()
        await backend.finishWrite()
        try await wait {
            let stored = await backend.stored()
            let writes = await backend.writes
            return stored == Data("first 中文😀".utf8) && writes == 2
        }
        XCTAssertTrue(diff.isDirty)
        await backend.finishWrite()
        try await wait { !diff.isDirty }
        let latest = await backend.stored()
        XCTAssertEqual(latest, Data("second 中文🪨".utf8))

        diff.updateEditedContent("unsaved during outage")
        diff.autoSaveOnFocusLoss()
        try await wait { await backend.writing }
        await backend.finishWrite(failing: true)
        try await wait { diff.saveError != nil }
        XCTAssertTrue(diff.isDirty)
        XCTAssertEqual(diff.editedNewContent, "unsaved during outage")
        let retained = await backend.stored()
        XCTAssertEqual(retained, Data("second 中文🪨".utf8))
    }

    func testWorktreeStagedHistoryBinarySizeAndSymlink() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = "原文😀\r\n"
        let stagedText = "暂存🪨\r\n"
        let worktreeText = "工作区🙂\r\n"
        let file = directory.appendingPathComponent("tracked.txt")
        try Data(original.utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["add", "."], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "initial"], in: directory.path).status, 0)
        let hash = GitCommandExecution.run(["rev-parse", "HEAD"], in: directory.path).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try Data(stagedText.utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["add", "tracked.txt"], in: directory.path).status, 0)
        try Data(worktreeText.utf8).write(to: file)
        let preferences = try isolatedPreferences()

        func diff(_ path: String = "tracked.txt", staged: Bool = false, commit: String? = nil) -> DiffTab {
            DiffTab(repoRoot: directory.path, path: path,
                    source: commit.map { .commit(hash: $0, parent: nil, status: "A") }
                        ?? (staged ? .staged : .worktree), untracked: false,
                    origPath: nil, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                    preferences: preferences)
        }
        let worktree = diff()
        let index = diff(staged: true)
        let history = diff(commit: hash)
        try await wait { !worktree.isLoading && !index.isLoading && !history.isLoading }
        XCTAssertEqual(worktree.oldContent, stagedText)
        XCTAssertEqual(worktree.newContent, worktreeText)
        XCTAssertTrue(worktree.isEditable)
        XCTAssertEqual(index.oldContent, original)
        XCTAssertEqual(index.newContent, stagedText)
        XCTAssertFalse(index.isEditable)
        XCTAssertEqual(history.oldContent, "")
        XCTAssertEqual(history.newContent, original)
        XCTAssertFalse(history.isEditable)

        let pane = PaneTab(content: .diff(worktree))
        let dirty = expectation(description: "Diff dirty propagates through the existing pane")
        withObservationTracking({ _ = pane.content.isDirty }) { dirty.fulfill() }
        worktree.updateEditedContent("saved😀\r\n")
        await fulfillment(of: [dirty], timeout: 1)
        XCTAssertEqual(worktree.newContent, worktreeText)
        await worktree.save()
        XCTAssertFalse(worktree.isDirty)
        XCTAssertEqual(try Data(contentsOf: file), Data("saved😀\r\n".utf8))

        try Data([0x41, 0x00, 0x42]).write(to: directory.appendingPathComponent("binary.bin"))
        try Data(repeating: 0x41, count: 5 * 1024 * 1024 + 1).write(to: directory.appendingPathComponent("large.txt"))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path, withDestinationPath: "tracked.txt")
        let binary = diff("binary.bin")
        let large = diff("large.txt")
        let link = diff("link")
        try await wait { !binary.isLoading && !large.isLoading && !link.isLoading }
        XCTAssertNotNil(binary.error)
        XCTAssertFalse(binary.isEditable)
        XCTAssertNotNil(large.error)
        XCTAssertFalse(large.isEditable)
        XCTAssertEqual(link.newContent, "tracked.txt")
        XCTAssertFalse(link.isEditable)
    }

    func testSaveDuringEditFailureAndDisconnectKeepUnsavedContent() async throws {
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "remote.txt", source: .worktree,
                           untracked: true, origPath: nil, backend: backend,
                           workspaceIdentity: "ssh:fixture", preferences: try isolatedPreferences())
        try await wait { !diff.isLoading }
        diff.updateEditedContent("first😀\r\n")
        let saving = Task { await diff.save() }
        try await wait { await backend.writing }
        diff.updateEditedContent("second🪨\r\n")
        await backend.finishWrite()
        await saving.value
        XCTAssertTrue(diff.isDirty)
        let firstStored = await backend.stored()
        XCTAssertEqual(firstStored, Data("first😀\r\n".utf8))

        let failing = Task { await diff.save() }
        try await wait { await backend.writing }
        await backend.finishWrite(failing: true)
        await failing.value
        XCTAssertTrue(diff.isDirty)
        XCTAssertNotNil(diff.saveError)

        let outdated = Task { await diff.save() }
        try await wait { await backend.writing }
        let project = Project(fallbackName: "offline", workspaceConfiguration: .standard)
        diff.reevaluateWorkspace(in: project)
        await backend.finishWrite()
        await outdated.value
        XCTAssertTrue(diff.isDirty)
        XCTAssertNotNil(diff.readOnlyReason)
        XCTAssertFalse(diff.isEditableNow)
        XCTAssertEqual(diff.newContent, "second🪨\r\n", "Disconnected native review must still display unsaved edits")
        await diff.save()
        XCTAssertEqual(diff.saveError, diff.readOnlyReason)
        let count = await backend.writes
        XCTAssertEqual(count, 3)
        XCTAssertEqual(diff.editedNewContent, "second🪨\r\n")
        XCTAssertTrue(diff.isDirty)
    }

    func testNativeDiffRendersAndRetainsTextKitSurface() async throws {
        let domain = "bailey-native-render-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "render.txt", source: .worktree,
                           untracked: true, origPath: nil, backend: backend,
                           workspaceIdentity: nil, preferences: preferences)
        try await wait { !diff.isLoading && diff.display != nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        func mount() -> NSHostingView<DiffViewerView> {
            let host = NSHostingView(rootView: DiffViewerView(diff: diff))
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            return host
        }

        let first = mount()
        try await wait { diff.nativeSurface != nil && self.findNativeTextView(in: first) != nil }
        let surface = try XCTUnwrap(diff.nativeSurface)
        let textView = try XCTUnwrap(findNativeTextView(in: surface))
        XCTAssertTrue(textView.attributedText.string.contains("baseline") == true)
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(textView.window === window)

        first.removeFromSuperview()
        let second = mount()
        try await wait { self.findNativeTextView(in: second) === textView }
        XCTAssertTrue(diff.nativeSurface === surface)
        XCTAssertTrue(findNativeTextView(in: second) === textView)
        XCTAssertTrue(textView.attributedText.string.contains("baseline") == true)
        second.removeFromSuperview()
    }


    func testReviewDocumentChangeRestoresHorizontalStartWithoutDiscardingRestyleScroll() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let style = DiffTypography.paragraphStyle(for: font)
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        let window = NSWindow(contentRect: NSRect(x: -940, y: -940, width: 730, height: 370),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        pane.layoutSubtreeIfNeeded()
        pane.applyTypography(font: font, paragraphStyle: style, textColor: .black)

        let oldLine = String(repeating: "before", count: 700)
        let newLine = String(repeating: "after", count: 700)
        let original = DiffComputation.compute(oldText: oldLine + "\n", newText: "initial\n").unified
        pane.setReviewDocument(NSAttributedString(string: original.text), decorations: .review(original))
        pane.layoutSubtreeIfNeeded()
        let clip = pane.scrollView.contentView
        XCTAssertGreaterThan(pane.textView.frame.width, 3000)
        clip.scroll(to: NSPoint(x: 2600, y: 0))
        pane.scrollView.reflectScrolledClipView(clip)
        XCTAssertEqual(clip.bounds.origin.x, 2600, accuracy: 2)

        // A pure restyle/rebuild is the same document and should keep the user's viewport.
        pane.setReviewDocument(NSAttributedString(string: original.text), decorations: .review(original))
        XCTAssertEqual(clip.bounds.origin.x, 2600, accuracy: 2)

        // The new Git snapshot retains a long deleted line, but its newly added
        // content lives near x=0. A stale offset otherwise makes additions blank.
        let changed = DiffComputation.compute(oldText: oldLine + "\n", newText: newLine + "\n").unified
        pane.setReviewDocument(NSAttributedString(string: changed.text), decorations: .review(changed))
        XCTAssertEqual(clip.bounds.origin.x, 0, accuracy: 2)
        XCTAssertEqual(pane.textView.text, changed.text)
    }

    func testWrappedReviewReloadKeepsRealLineAnchorRatherThanFixedPixelEstimate() throws {
        let veryLong = String(repeating: "let a = 1234567890; ", count: 3_300)
        let old = ([veryLong] + (1..<800).map { "line \($0)" }).joined(separator: "\n") + "\n"
        var next = ([veryLong] + (1..<800).map { "line \($0)" })
        next[710] = "line 710 edited"
        let first = DiffComputation.compute(oldText: "", newText: old).unified
        let second = DiffComputation.compute(oldText: "", newText: next.joined(separator: "\n") + "\n").unified
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        let window = NSWindow(contentRect: NSRect(x: -950, y: -950, width: 700, height: 280),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        pane.layoutSubtreeIfNeeded()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let style = DiffTypography.paragraphStyle(for: font)
        pane.applyTypography(font: font, paragraphStyle: style, textColor: .black,
                             longLineDisplayWidth: .showAll)
        pane.setReviewDocument(NSAttributedString(string: first.text), decorations: .review(first))
        pane.layoutSubtreeIfNeeded()
        pane.scrollToRow(595)
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let before = try XCTUnwrap(pane.firstVisibleRowIndex)
        XCTAssertGreaterThanOrEqual(before, 593)
        XCTAssertLessThanOrEqual(before, 596)
        XCTAssertTrue(pane.textView.wrapsLines)
        pane.setReviewDocument(NSAttributedString(string: second.text), decorations: .review(second))
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let after = try XCTUnwrap(pane.firstVisibleRowIndex)
        XCTAssertEqual(after, before, "Full display reload must restore the real native paragraph geometry")
        for index in [780, 2, 595] {
            pane.scrollToRow(index)
            pane.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let visible = try XCTUnwrap(pane.firstVisibleRowIndex)
            XCTAssertGreaterThanOrEqual(visible, max(0, index - 2))
            XCTAssertLessThanOrEqual(visible, index + 1)
        }
        XCTAssertEqual(pane.textView.text, second.text)
    }

    func testReviewReloadPreservesLogicalRowWithCRLFUnicodeSeparatorsAndFontChanges() throws {
        let source = "start\rbare\u{2028}segment\r\n"
            + (1..<160).map { "line \($0)\r\n" }.joined()
        let updated = source.replacingOccurrences(of: "line 140", with: "line 140 updated")
        let initial = DiffComputation.compute(oldText: "", newText: source).unified
        let changed = DiffComputation.compute(oldText: "", newText: updated).unified
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        let window = NSWindow(contentRect: NSRect(x: -930, y: -930, width: 650, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        pane.layoutSubtreeIfNeeded()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .black)
        pane.setReviewDocument(NSAttributedString(string: initial.text), decorations: .review(initial))
        pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(pane.textView.hasNativeNonLFSeparators)
        pane.scrollToRow(90)
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let before = try XCTUnwrap(pane.firstVisibleRowIndex)
        XCTAssertGreaterThanOrEqual(before, 88)
        XCTAssertLessThanOrEqual(before, 91)
        pane.setReviewDocument(NSAttributedString(string: changed.text), decorations: .review(changed))
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(pane.firstVisibleRowIndex, before)
        let larger = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        pane.applyTypography(font: larger, paragraphStyle: DiffTypography.paragraphStyle(for: larger),
                             textColor: .black)
        pane.setReviewDocument(NSAttributedString(string: changed.text), decorations: .review(changed))
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(pane.firstVisibleRowIndex), before - 2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(pane.firstVisibleRowIndex), before + 2)
        XCTAssertEqual(pane.textView.text, changed.text)
    }

    func testReviewCompactFoldStartsAtTopAndKeepsContextAfterDeepScroll() throws {
        let original = (0..<900).map { "line \($0)" }
        var edited = original
        edited[594] = "line 594 changed"
        edited[617] = "line 617 changed"
        let oldSource = original.joined(separator: "\n") + "\n"
        let newSource = edited.joined(separator: "\n") + "\n"
        let complete = DiffComputation.compute(oldText: oldSource, newText: newSource).unified
        let compact = DiffComputation.build(core: .compute(oldText: oldSource, newText: newSource),
                                            revealedLines: []).unified
        XCTAssertTrue(compact.rows.contains(where: { $0.collapsed != nil }))
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        let window = NSWindow(contentRect: NSRect(x: -930, y: -930, width: 700, height: 750),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        pane.layoutSubtreeIfNeeded()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .black)
        pane.setReviewDocument(NSAttributedString(string: complete.text), decorations: .review(complete))
        pane.layoutSubtreeIfNeeded()
        let clip = pane.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 9000))
        pane.scrollView.reflectScrolledClipView(clip)
        XCTAssertGreaterThan(clip.bounds.minY, 750)
        pane.setReviewDocument(NSAttributedString(string: compact.text), decorations: .review(compact))
        pane.layoutSubtreeIfNeeded()
        let expectedHeight = CGFloat(compact.rows.count) * DiffTypography.lineHeight(for: font)
        XCTAssertGreaterThanOrEqual(pane.textView.frame.height, expectedHeight - 2)
        XCTAssertLessThanOrEqual(pane.textView.frame.height,
                                 max(expectedHeight, clip.bounds.height)
                                     + DiffTypography.lineHeight(for: font) + 3)
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 2,
                       "Collapsing thousands of context lines must not leave an empty viewport")
        let layout = pane.textView.nativeLayoutManager
        let first = try XCTUnwrap(layout.textLayoutFragment(for: layout.documentRange.location))
        XCTAssertLessThan(first.layoutFragmentFrame.minY, 2)
        XCTAssertEqual(pane.textView.text, compact.text)
    }

    func testReviewTypographyUpdatesDoNotEraseTreeSitterForegroundColors() throws {
        let source = "import AppKit\nstruct FileTreePanel: View { let model: Int }\n"
        let document = DiffComputation.compute(oldText: "", newText: source).unified
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let style = DiffTypography.paragraphStyle(for: font)
        let colored = NSMutableAttributedString(string: document.text, attributes: [
            .font: font, .foregroundColor: NSColor.black, .paragraphStyle: style,
        ])
        let keyword = (colored.string as NSString).range(of: "struct")
        colored.addAttribute(.foregroundColor, value: NSColor.systemPink, range: keyword)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
            pane.appearance = NSAppearance(named: appearance)
            pane.applyTypography(font: font, paragraphStyle: style, textColor: .black)
            pane.setReviewDocument(colored, decorations: .review(document))
            let storage = try XCTUnwrap(pane.textView.textStorage)
            XCTAssertEqual(storage.attribute(.foregroundColor, at: keyword.location,
                                             effectiveRange: nil) as? NSColor, .systemPink)
            pane.applyTypography(font: font, paragraphStyle: style, textColor: .systemBlue)
            XCTAssertEqual(storage.attribute(.foregroundColor, at: keyword.location,
                                             effectiveRange: nil) as? NSColor, .systemPink,
                           "Review colors belong to the immutable attributed document, not NSTextView.textColor")
            XCTAssertEqual(pane.textView.text, document.text)
        }
    }

    func testReadonlySyntaxRestyleKeepsTheExistingSourceSelectionAndScroll() throws {
        let projection = DiffComputation.compute(
            oldText: "let value = 0\n", newText: "let value = 42\n"
        )
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 720, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let source = projection.unified
        let plain = NSAttributedString(string: source.text,
                                       attributes: [.foregroundColor: NSColor.textColor])
        let rows = DiffDecorations.review(source)
        pane.setReviewDocument(plain, decorations: rows)
        let selection = (source.text as NSString).range(of: "value")
        XCTAssertNotEqual(selection.location, NSNotFound)
        pane.textView.setSelectedRange(selection)
        let scroll = pane.scrollView.contentView.bounds.origin
        let colored = NSMutableAttributedString(attributedString: plain)
        colored.addAttribute(.foregroundColor, value: NSColor.systemPink, range: selection)
        pane.setReviewDocument(colored, decorations: rows)
        XCTAssertEqual(pane.textView.selectedRange(), selection,
                       "Asynchronous syntax coloring cannot clear a user's read-only selection")
        XCTAssertEqual(pane.scrollView.contentView.bounds.origin, scroll)
        XCTAssertEqual(pane.textView.string, source.text)
    }

    func testHistoricalSourceRevisionSharesWorktreeSyntaxHighlightingWithoutBecomingEditable() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = "// syntax revision\nlet value = 42\n"
        try Data(content.utf8).write(to: root.appendingPathComponent("revision.swift"))
        XCTAssertEqual(GitCommandExecution.run(["add", "revision.swift"], in: root.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: root.path).status, 0)
        let hashResult = GitCommandExecution.run(["rev-parse", "HEAD"], in: root.path)
        XCTAssertEqual(hashResult.status, 0)
        let hash = hashResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let diff = DiffTab(repoRoot: root.path, path: "revision.swift",
                           source: .revision(hash: hash), untracked: false, origPath: nil,
                           backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                           preferences: try isolatedPreferences())
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 800, height: 380),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return diff.nativeSurface != nil && !diff.isLoading
        }
        let source = try XCTUnwrap(findNativeTextView(in: host, editable: false))
        XCTAssertEqual(source.string, content)
        XCTAssertNotNil(source.syntaxCoordinator,
                        "A historical source is read-only, not plain unhighlighted text")
        let expected = try XCTUnwrap(SyntaxHighlightCoordinator.themeColor(
            for: "comment", theme: SyntaxHighlighting.theme
        ))
        try await wait {
            source.layoutSubtreeIfNeeded()
            var painted: NSColor?
            source.nativeLayoutManager.enumerateRenderingAttributes(
                from: source.nativeContentManager.documentRange.location, reverse: false
            ) { _, attributes, range in
                if NSLocationInRange(3, NSRange(range, in: source.nativeContentManager)) {
                    painted = attributes[.foregroundColor] as? NSColor
                    return false
                }
                return true
            }
            return painted == expected
        }
        XCTAssertEqual(source.string, content)
        XCTAssertFalse(source.isEditable)
    }

    func testStagedAndUnstagedShareUnifiedDiffRowsAndExplicitFoldSemantics() throws {
        let old = (0..<320).map { "line \($0)\n" }.joined()
        let new = old.replacingOccurrences(of: "line 160\n", with: "changed 160\n")
        let core = DiffCore.compute(oldText: old, newText: new)
        let projection = DiffComputation.build(core: core, revealedLines: [])
        let reviewed = DiffDecorations.review(projection.unified)
        let state = projection.editState
        let offsets = core.newLines.map(\.utf16Range.location)
        let source = old as NSString
        let ghosts = state.ghosts.map { block in
            DiffDecorations.GhostBlock(
                anchorLine: block.anchorLine, firstOldLine: block.firstOldLine,
                lines: block.lines.map { NSAttributedString(string: source.substring(with: $0.sourceRange)) }
            )
        }
        let editable = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 800, height: 380),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = editable
        window.orderFront(nil)
        editable.setEditBufferText(new)
        let folds = DiffEditFold.sourceFolds(in: projection.unified,
                                              lineCount: core.newLines.count)
        editable.setEditingFolds(
            folds, lineOffsets: offsets,
            baseDecorations: .edit(state: state, snapshotOffsets: offsets,
                                   lineCount: offsets.count, ghostBlocks: ghosts),
            revision: 1
        )
        editable.layoutSubtreeIfNeeded()
        let editRows = editable.decorations.rows
        XCTAssertEqual(reviewed.rows.compactMap { $0.kind == .added ? $0.newLine : nil },
                       editRows.compactMap { $0.kind == .added ? $0.newLine : nil })
        XCTAssertEqual(reviewed.rows.compactMap { $0.kind == .removed ? $0.oldLine : nil },
                       ghosts.flatMap { block in
                           (0..<block.lines.count).map { block.firstOldLine + $0 }
                       })
        XCTAssertEqual(reviewed.rows.compactMap { $0.collapsed?.hiddenLines },
                       editRows.compactMap { $0.collapsed?.hiddenLines })
        for ghost in editable.decorations.positionedGhosts {
            let hidden = folds.reduce(0) { count, fold in
                let preceding = min(ghost.block.anchorLine, fold.range.upperBound)
                    - fold.range.lowerBound
                return count + max(0, preceding - 1)
            }
            XCTAssertEqual(ghost.visibleStartRow, ghost.startRow - hidden,
                           "Unstaged ghost rows must share the staged diff's folded geometry")
        }
        XCTAssertEqual(editable.textView.string, new,
                       "Shared diff presentation must never replace the writable source with review rows")
        XCTAssertTrue(editable.textView.isEditable)
    }

    func testLargeSourceVisibleSyntaxUsesProductionParser() async throws {
        let source = String(repeating: "let value = 42\n", count: 115_000)
        XCTAssertGreaterThan(source.utf8.count, 1_500_000)
        let resolved = await DiffSyntaxHighlighter.context(for: "large.swift")
        let context = try XCTUnwrap(resolved)
        let started = CFAbsoluteTimeGetCurrent()
        let visible = await DiffSyntaxSource().captures(
            text: source, context: context, ranges: [NSRange(location: 0, length: 30)])
        print("AUDIT_LARGE_DIFF_VISIBLE_SYNTAX bytes=\(source.utf8.count) milliseconds=\((CFAbsoluteTimeGetCurrent() - started) * 1_000)")
        XCTAssertFalse(visible.isEmpty,
                       "Large files must highlight the visible source through the production parser")
        XCTAssertTrue(visible.contains { NSLocationInRange(2, $0.range) })
    }

    func testEditableDiffSkipsModifiedOfflineSyntaxWhileReadonlyParsesBothSides() async throws {
        let resolved = await DiffSyntaxHighlighter.context(for: "editable.swift")
        let context = try XCTUnwrap(resolved)
        let original = (0..<320).map { "let count\($0) = \($0)\n" }.joined()
        let modified = original.replacingOccurrences(of: "let count160 = 160\n",
                                                      with: "let count160 = -1\n")
        let projection = DiffComputation.build(
            core: DiffCore.compute(oldText: original, newText: modified), revealedLines: []
        )
        let oldParser = DiffSyntaxSource()
        let newParser = DiffSyntaxSource()
        let edited = await DiffTab.captureVisibleSyntax(
            before: original, after: modified, computation: projection,
            context: context, originalSyntax: oldParser, modifiedSyntax: newParser,
            highlightModified: false
        )
        XCTAssertFalse(edited.old.isEmpty)
        XCTAssertTrue(edited.new.isEmpty,
                      "The editable new buffer is already highlighted by Neon")
        let editedOldParseCount = await oldParser.parseCount
        let editedNewParseCount = await newParser.parseCount
        XCTAssertEqual(editedOldParseCount, 1)
        XCTAssertEqual(editedNewParseCount, 0,
                       "Worktree Diff must not parse the same modified source twice")

        let readonly = await DiffTab.captureVisibleSyntax(
            before: original, after: modified, computation: projection,
            context: context, originalSyntax: oldParser, modifiedSyntax: newParser,
            highlightModified: true
        )
        XCTAssertFalse(readonly.new.isEmpty,
                       "Staged, history and clean-filter canonical review still need new-side tokens")
        let afterReadonlyOldCount = await oldParser.parseCount
        let afterReadonlyNewCount = await newParser.parseCount
        XCTAssertEqual(afterReadonlyOldCount, 1)
        XCTAssertEqual(afterReadonlyNewCount, 1)
        let direct = DiffSyntaxOracle.captures(
            text: modified, context: context,
            ranges: DiffSyntaxHighlighter.visibleRanges(in: projection.splitRight, source: .new)
        )
        XCTAssertEqual(readonly.new.map(\.range), direct.map(\.range))
        XCTAssertEqual(readonly.new.map(\.name), direct.map(\.name))
    }

    func testDiffSyntaxReusesParseTreeAcrossFoldExpansionAndInvalidatesOnByteChanges() async throws {
        let resolved = await DiffSyntaxHighlighter.context(for: "fixture.swift")
        let context = try XCTUnwrap(resolved)
        let source = (0..<24_000).map { "let value\($0) = \($0) // text\n" }.joined()
        let modified = source.replacingOccurrences(
            of: "let value12000 = 12000 // text\n", with: "let value12000 = -1 // text\n"
        )
        let core = DiffCore.compute(oldText: source, newText: modified)
        let initial = DiffComputation.build(core: core, revealedLines: [])
        let oldRanges = DiffSyntaxHighlighter.visibleRanges(in: initial.splitLeft, source: .old)
        let cached = DiffSyntaxSource()
        let start = CFAbsoluteTimeGetCurrent()
        let first = await cached.captures(text: source, context: context, ranges: oldRanges)
        let cold = (CFAbsoluteTimeGetCurrent() - start) * 1_000
        XCTAssertFalse(first.isEmpty)
        let initialCount = await cached.parseCount
        XCTAssertEqual(initialCount, 1)

        let fold = try XCTUnwrap(initial.unified.rows.first(where: { $0.collapsed != nil })?.collapsed)
        let expanded = DiffComputation.build(core: core, revealedLines: fold.revealNext())
        let expandedRanges = DiffSyntaxHighlighter.visibleRanges(
            in: expanded.splitLeft, source: .old
        )
        let warmStart = CFAbsoluteTimeGetCurrent()
        let warm = await cached.captures(text: source, context: context, ranges: expandedRanges)
        let warmTime = (CFAbsoluteTimeGetCurrent() - warmStart) * 1_000
        XCTAssertFalse(warm.isEmpty)
        let afterExpansion = await cached.parseCount
        XCTAssertEqual(afterExpansion, 1, "Unfolding may query new rows, but may not reparse source")
        let direct = DiffSyntaxOracle.captures(
            text: source, context: context, ranges: expandedRanges
        )
        XCTAssertEqual(warm.map(\.range), direct.map(\.range))
        XCTAssertEqual(warm.map(\.name), direct.map(\.name))

        let composed = "let café = 1\n"
        let decomposed = "let cafe\u{301} = 1\n"
        _ = await cached.captures(
            text: composed, context: context,
            ranges: [NSRange(location: 0, length: composed.utf16.count)]
        )
        _ = await cached.captures(
            text: decomposed, context: context,
            ranges: [NSRange(location: 0, length: decomposed.utf16.count)]
        )
        let afterUnicode = await cached.parseCount
        XCTAssertEqual(afterUnicode, 3,
                       "Unicode-canonically equivalent but byte-different text must reparse")
        print("AUDIT_DIFF_SYNTAX_REUSE lines=24000 coldMs=\(cold) foldReuseMs=\(warmTime)")
    }

    func testVisibleSyntaxRangesMatchFullCapturesAfterFoldingAndExpansion() async throws {
        for path in ["fixture.swift", "README.md"] {
            let source: String
            let replacement: String
            if path.hasSuffix(".md") {
                source = (0..<360).map { "# Heading \($0)\n**bold** and `code`\n" }.joined()
                replacement = "# New Heading 180\n**bold** and `code`\n"
            } else {
                source = (0..<360).map { "let value\($0) = \($0) // comment\n" }.joined()
                replacement = "let value180 = -1 // changed\n"
            }
            let oldLine = path.hasSuffix(".md")
                ? "# Heading 180\n**bold** and `code`\n"
                : "let value180 = 180 // comment\n"
            let after = source.replacingOccurrences(of: oldLine, with: replacement)
            let resolved = await DiffSyntaxHighlighter.context(for: path)
            let context = try XCTUnwrap(resolved)
            let core = DiffCore.compute(oldText: source, newText: after)
            var variants: [[Range<Int>]] = [[]]
            let initial = DiffComputation.build(core: core, revealedLines: [])
            if let collapsed = initial.unified.rows.first(where: { $0.collapsed != nil })?.collapsed {
                variants.append(collapsed.revealNext())
            }
            for revealed in variants {
                let computation = DiffComputation.build(core: core, revealedLines: revealed)
                let oldRanges = DiffSyntaxHighlighter.visibleRanges(
                    in: computation.splitLeft, source: .old
                )
                let newRanges = DiffSyntaxHighlighter.visibleRanges(
                    in: computation.splitRight, source: .new
                )
                let oldAll = DiffSyntaxHighlighter.colors(for:
                    DiffSyntaxOracle.captures(text: source, context: context))
                let newAll = DiffSyntaxHighlighter.colors(for:
                    DiffSyntaxOracle.captures(text: after, context: context))
                let oldVisible = DiffSyntaxHighlighter.colors(for: await DiffSyntaxSource().captures(
                    text: source, context: context, ranges: oldRanges))
                let newVisible = DiffSyntaxHighlighter.colors(for: await DiffSyntaxSource().captures(
                    text: after, context: context, ranges: newRanges))
                let plain: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor]
                for document in [computation.unified, computation.splitLeft, computation.splitRight] {
                    let full = DiffSyntaxHighlighter.attributedDocument(
                        document, oldRuns: oldAll, newRuns: newAll, baseAttributes: plain)
                    let visible = DiffSyntaxHighlighter.attributedDocument(
                        document, oldRuns: oldVisible, newRuns: newVisible, baseAttributes: plain)
                    XCTAssertTrue(full.isEqual(to: visible),
                                  "Visible \(path) capture colors must equal full query after folding")
                }
            }
        }
    }

    func testBackgroundSyntaxCapturesReachNativeDiffColors() async throws {
        for (path, source) in [
            ("sample.swift", "let answer = 42\n"),
            ("View.tsx", "const View = () => <main title=\"hi\">Hello</main>;\n"),
            ("script.py", "def answer():\n    return 42\n"),
            ("script.ts", "const answer: number = 42;\n"),
            ("README.md", "# Heading\n\n**bold** and `inline code`\n"),
            ("style.css", "main { color: red; margin: 1px; }\n"),
            ("data.json", "{\"enabled\": true, \"count\": 42}\n"),
            ("page.html", "<main class=\"hero\">Hello</main>\n"),
            ("query.sql", "SELECT id FROM records WHERE id = 42;\n"),
            ("main.go", "package main\nfunc main() {}\n"),
            ("main.rs", "fn main() { let answer = 42; }\n"),
            ("config.yaml", "enabled: true\nport: 42\n"),
        ] {
            let resolved = await DiffSyntaxHighlighter.context(for: path)
            let context = try XCTUnwrap(resolved, "Missing grammar for \(path)")
            let captures = await DiffSyntaxSource().captures(
                text: source, context: context,
                ranges: [NSRange(location: 0, length: source.utf16.count)])
            XCTAssertFalse(captures.isEmpty, "Syntax parser returned no highlights for \(path)")
            XCTAssertTrue(captures.allSatisfy {
                $0.range.length > 0 && NSMaxRange($0.range) <= source.utf16.count
            })
            let colored = DiffSyntaxHighlighter.colors(for: captures)
            XCTAssertEqual(colored.count, captures.count)
            let computed = DiffComputation.compute(oldText: "", newText: source)
            let rendered = DiffSyntaxHighlighter.attributedDocument(
                computed.unified, oldRuns: [], newRuns: colored,
                baseAttributes: [.foregroundColor: NSColor.textColor]
            )
            XCTAssertEqual(rendered.string, computed.unified.text)
            XCTAssertFalse(colored.isEmpty, "No native foreground colors for \(path)")
        }
    }

    func testGitWorktreeDiffUsesGitEOLRulesWithoutChangingEditorBytes() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let ordinary = root.appendingPathComponent("normal space 'quoted'.md")
        let literal = root.appendingPathComponent("literal.txt")
        let explicitEOL = root.appendingPathComponent("explicit-eol.txt")
        let old = "alpha\n中文👋\nlast\n"
        let worktree = "alpha\r\n中文👋\r\nlast\r\n"
        let changed = "alpha\r\n中文👋 edited\r\nlast\r\n"
        try Data(old.utf8).write(to: ordinary)
        try Data(old.utf8).write(to: literal)
        try Data(old.utf8).write(to: explicitEOL)
        try Data("literal.txt -text\nexplicit-eol.txt text eol=crlf\n".utf8)
            .write(to: root.appendingPathComponent(".gitattributes"))
        for args in [["config", "core.autocrlf", "true"], ["add", "."],
                     ["commit", "-qm", "baseline"]] {
            let result = GitCommandExecution.run(args, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try Data(worktree.utf8).write(to: ordinary)
        try Data(worktree.utf8).write(to: literal)
        try Data(worktree.utf8).write(to: explicitEOL)
        XCTAssertEqual(GitCommandExecution.run(["diff", "--numstat", "HEAD", "--",
                                                 ordinary.lastPathComponent],
                                                in: root.path).stdout, "")

        let preferences = try isolatedPreferences()
        let normal = DiffTab(repoRoot: root.path, path: ordinary.lastPathComponent,
                             source: .worktree, untracked: false, origPath: nil,
                             backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                             preferences: preferences)
        let raw = DiffTab(repoRoot: root.path, path: literal.lastPathComponent,
                          source: .worktree, untracked: false, origPath: nil,
                          backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                          preferences: preferences)
        let eol = DiffTab(repoRoot: root.path, path: explicitEOL.lastPathComponent,
                          source: .worktree, untracked: false, origPath: nil,
                          backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                          preferences: preferences)
        try await wait { !normal.isLoading && !raw.isLoading && !eol.isLoading }
        XCTAssertNil(normal.error)
        XCTAssertNil(raw.error)
        XCTAssertNil(eol.error)
        XCTAssertFalse(eol.hasChanges, "Per-path eol=crlf must not invent additions")
        XCTAssertEqual(normal.oldContent, old)
        XCTAssertEqual(normal.newContent, worktree)
        XCTAssertFalse(normal.hasChanges, "Git regards a CRLF checkout as unchanged")
        XCTAssertNil(normal.display)
        XCTAssertTrue(raw.hasChanges, "-text must preserve real CRLF changes")

        let mixed = "alpha\r\n中文👋\nlast\r\n"
        try Data(mixed.utf8).write(to: ordinary)
        XCTAssertEqual(GitCommandExecution.run(
            ["diff", "--numstat", "--", ordinary.lastPathComponent], in: root.path
        ).stdout, "")
        normal.reload()
        try await wait { !normal.isLoading && normal.newContent == mixed }
        XCTAssertFalse(normal.hasChanges, "Mixed LF/CRLF is still Git-equivalent")
        XCTAssertNil(normal.display)

        try Data(changed.utf8).write(to: ordinary)
        normal.reload()
        try await wait { !normal.isLoading && normal.newContent == changed }
        try await wait { normal.display != nil }
        let display = try XCTUnwrap(normal.display)
        let removed = display.computation.unified.rows.filter { $0.kind == .removed }
        let added = display.computation.unified.rows.filter { $0.kind == .added }
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(removed.first?.oldLine, 2)
        XCTAssertEqual(added.first?.newLine, 2)
        XCTAssertEqual(try Data(contentsOf: ordinary), Data(changed.utf8))

        normal.autoSaveSuspendedForClose = true
        try await wait { normal.editDecorations.rows.filter { $0.kind == .added }.count == 1 }
        let edited = "alpha\r\n中文👋 edited again\r\nlast\r\n"
        normal.updateEditedContent(edited)
        try await wait {
            normal.editDecorations.rows.filter { $0.kind == .added }.count == 1
                && normal.editedNewContent == edited
        }
        XCTAssertEqual(normal.editDecorations.rows.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(normal.editDecorations.ghostsByAnchor.values.reduce(0) { $0 + $1.lines.count }, 1)
        await normal.save()
        XCTAssertNil(normal.saveError)
        XCTAssertEqual(try Data(contentsOf: ordinary), Data(edited.utf8))
        try await wait {
            !normal.isLoading && normal.newContent == edited
                && normal.display?.computation.unified.rows.filter { $0.kind == .added }.count == 1
        }
        let beforeAppearance = normal.display?.id
        normal.refreshNativeAppearance()
        try await wait {
            normal.display?.id != beforeAppearance
                && normal.display?.computation.unified.rows.filter { $0.kind == .added }.count == 1
        }
        XCTAssertEqual(normal.newContent, edited)
        normal.reload()
        try await wait { !normal.isLoading && normal.newContent == edited }
        try await wait {
            normal.display?.computation.unified.rows.filter { $0.kind == .added }.count == 1
        }

        let oldRevision = GitCommandExecution.run(["rev-parse", "HEAD"], in: root.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let historical = DiffTab(
            repoRoot: root.path, path: ordinary.lastPathComponent,
            source: .revisionWorktree(hash: oldRevision), untracked: false,
            origPath: nil, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: nil, preferences: preferences
        )
        try await wait { !historical.isLoading && historical.display != nil }
        XCTAssertEqual(historical.display?.computation.unified.rows.filter { $0.kind == .added }.count, 1)
        let stagedResult = GitCommandExecution.run(
            ["--literal-pathspecs", "add", "--", ordinary.lastPathComponent], in: root.path
        )
        XCTAssertEqual(stagedResult.status, 0, stagedResult.stderr)
        let staged = DiffTab(repoRoot: root.path, path: ordinary.lastPathComponent,
                             source: .staged, untracked: false, origPath: nil,
                             backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                             preferences: preferences)
        let clean = DiffTab(repoRoot: root.path, path: ordinary.lastPathComponent,
                            source: .worktree, untracked: false, origPath: nil,
                            backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                            preferences: preferences)
        try await wait { !staged.isLoading && !clean.isLoading && staged.display != nil }
        XCTAssertNil(staged.error)
        XCTAssertNil(clean.error)
        XCTAssertEqual(staged.display?.computation.unified.rows.filter { $0.kind == .added }.count, 1)
        XCTAssertFalse(clean.hasChanges, "Index and CRLF checkout are Git-equivalent after staging")
        XCTAssertNil(clean.display)
        XCTAssertEqual(clean.newContent, edited)
        XCTAssertEqual(try Data(contentsOf: ordinary), Data(edited.utf8))
    }

    func testGitCleanFiltersShowCanonicalReviewWhenRawLinesDoNotCorrespond() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let attributes = """
        one.txt filter=swap
        lines.txt filter=drop
        """
        try Data((attributes + "\n").utf8).write(
            to: root.appendingPathComponent(".gitattributes")
        )
        let one = root.appendingPathComponent("one.txt")
        let lines = root.appendingPathComponent("lines.txt")
        try Data("value BASE\n".utf8).write(to: one)
        try Data("keep\n".utf8).write(to: lines)
        for args in [
            ["config", "filter.swap.clean", "sed 's/SECRET/BASE/g'"],
            ["config", "filter.drop.clean", "sed '/^TRANSIENT/d'"],
            ["add", "."],
            ["commit", "-qm", "filtered baseline"],
        ] {
            let result = GitCommandExecution.run(args, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        try Data("value SECRET\n".utf8).write(to: one)
        try Data("keep\nTRANSIENT\n".utf8).write(to: lines)
        XCTAssertEqual(GitCommandExecution.run(
            ["diff", "--numstat", "HEAD", "--", "one.txt", "lines.txt"],
            in: root.path
        ).stdout, "")
        let prefs = try isolatedPreferences()
        let simple = DiffTab(repoRoot: root.path, path: "one.txt", source: .worktree,
                             untracked: false, origPath: nil,
                             backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                             preferences: prefs)
        let filtered = DiffTab(repoRoot: root.path, path: "lines.txt", source: .worktree,
                               untracked: false, origPath: nil,
                               backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                               preferences: prefs)
        try await wait { !simple.isLoading && !filtered.isLoading }
        XCTAssertNil(simple.error)
        XCTAssertNil(filtered.error)
        XCTAssertFalse(simple.hasChanges)
        XCTAssertFalse(filtered.hasChanges)
        XCTAssertEqual(simple.newContent, "value SECRET\n")
        XCTAssertEqual(filtered.newContent, "keep\nTRANSIENT\n")
        XCTAssertNil(filtered.display)

        try Data("value SECRET edited\n".utf8).write(to: one)
        XCTAssertEqual(GitCommandExecution.run(
            ["diff", "--numstat", "--", "one.txt"], in: root.path
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1\t1\tone.txt")
        simple.reload()
        try await wait { !simple.isLoading && simple.display != nil }
        XCTAssertEqual(simple.display?.computation.unified.rows.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(simple.display?.computation.unified.rows.filter { $0.kind == .removed }.count, 1)

        try Data("changed\nTRANSIENT\n".utf8).write(to: lines)
        filtered.reload()
        try await wait { !filtered.isLoading }
        try await wait { !filtered.isLoading && filtered.display != nil }
        XCTAssertNil(filtered.error)
        XCTAssertTrue(filtered.hasChanges)
        XCTAssertEqual(filtered.oldContent, "keep\n")
        XCTAssertEqual(filtered.newContent, "changed\nTRANSIENT\n",
                       "Editable buffer must remain the original unfiltered worktree bytes")
        let visible = try XCTUnwrap(filtered.display)
        XCTAssertEqual(visible.computation.unified.rows.filter { $0.kind == .removed }.count, 1)
        XCTAssertEqual(visible.computation.unified.rows.filter { $0.kind == .added }.count, 1)
        XCTAssertTrue(visible.unifiedText.string.contains("changed"))
        XCTAssertFalse(visible.unifiedText.string.contains("TRANSIENT"),
                       "Review must show exactly the Git-cleaned comparison")
        XCTAssertEqual(filtered.editedNewContent, "changed\nTRANSIENT\n")
        XCTAssertEqual(try Data(contentsOf: lines), Data("changed\nTRANSIENT\n".utf8))
    }

    func testLargeSwiftWorktreeWithManyIndependentHunksRendersWithoutReadError() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("DiffEngine.swift")
        let original = (0..<1300).map { "    let value_\($0) = \($0)" }
        try Data((original.joined(separator: "\n") + "\n").utf8).write(to: file)
        for args in [["add", "."], ["commit", "-qm", "Swift baseline"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: root.path).status, 0)
        }
        var modified = original
        let changed = Array(stride(from: 12, to: 1290, by: 37))
        for row in changed { modified[row] += " + 1" }
        let body = modified.joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: file)
        let tab = DiffTab(repoRoot: root.path, path: "DiffEngine.swift", source: .worktree,
                          untracked: false, origPath: nil,
                          backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                          preferences: try isolatedPreferences())
        try await wait({ !tab.isLoading && tab.display != nil }, timeout: 30)
        XCTAssertNil(tab.error, "Unrelated Git hunks must never blank the entire editor")
        XCTAssertEqual(tab.display?.computation.unified.rows.filter {
            $0.kind == .added
        }.count, changed.count)
        XCTAssertEqual(tab.display?.computation.unified.rows.filter {
            $0.kind == .removed
        }.count, changed.count)
        XCTAssertEqual(tab.newContent, body)
    }

    func testWorktreeRewriteDuringGitCleanReloadsOneCoherentSnapshot() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("edited.txt")
        let script = root.appendingPathComponent("clean-once.sh")
        try Data("old\n".utf8).write(to: file)
        try Data("edited.txt filter=once\n".utf8)
            .write(to: root.appendingPathComponent(".gitattributes"))
        for args in [["add", "."], ["commit", "-qm", "baseline"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: root.path).status, 0)
        }
        try Data("""
        #!/bin/sh
        marker='\(root.path)/.git/clean-ran'
        if [ ! -e "$marker" ]; then
            : > "$marker"
            printf 'new\\n' > '\(file.path)'
        fi
        cat
        """.utf8).write(to: script)
        let configured = GitCommandExecution.run(
            ["config", "filter.once.clean", "sh '\(script.path)'"], in: root.path
        )
        XCTAssertEqual(configured.status, 0, configured.stderr)

        let tab = DiffTab(repoRoot: root.path, path: "edited.txt", source: .worktree,
                          untracked: false, origPath: nil,
                          backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                          preferences: try isolatedPreferences())
        try await wait({
            !tab.isLoading && tab.newContent == "new\n" && tab.display != nil
        }, timeout: 30)
        XCTAssertNil(tab.error, "The Git diff should reload if the file changes while reading")
        XCTAssertEqual(try Data(contentsOf: file), Data("new\n".utf8))
        XCTAssertEqual(tab.display?.computation.unified.rows.filter {
            $0.kind == .removed
        }.count, 1)
        XCTAssertEqual(tab.display?.computation.unified.rows.filter {
            $0.kind == .added
        }.count, 1)
    }

    func testAuthorizedWindowsSSHGitReviewAndRawSaveMatchGitCleanRules() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Real SSH Git Review requires an explicitly selected test host")
        }
        let socket = "/tmp/bailey-diff-eol-" + UUID().uuidString + ".sock"
        let backend = SSHWorkspaceBackend(
            runner: SSHHostCommandRunner(host: host, socket: socket), timeout: 45
        )
        let created = try await backend.run(
            argv: ["mktemp", "-d", "/tmp/bailey-diff-eol-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 30
        )
        XCTAssertEqual(created.status, 0, String(decoding: created.stderr, as: UTF8.self))
        let root = String(decoding: created.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.range(of: #"^/tmp/bailey-diff-eol-[A-Za-z0-9]{6}$"#,
                         options: .regularExpression) != nil else {
            throw WorkspaceError.notFound
        }

        func execute(_ command: [String]) async throws -> String {
            let result = try await backend.run(
                argv: command, cwd: root, env: nil, stdin: nil, timeout: 45
            )
            XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
            guard result.status == 0 else { throw WorkspaceError.notFound }
            return String(decoding: result.stdout, as: UTF8.self)
        }
        func cleanup() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Could not clean owned Windows SSH Git fixture: \(error)") }
            if FileManager.default.fileExists(atPath: socket) {
                do {
                    let result = try await Task.detached {
                        try ProcessRemoteCommandRunner.launch(
                            sshPath: "/usr/bin/ssh",
                            arguments: ["-S", socket, "-O", "exit", host],
                            stdin: nil, timeout: 10
                        )
                    }.value
                    XCTAssertEqual(result.status, 0)
                } catch {
                    XCTFail("Could not stop test-owned SSH master: \(error)")
                }
            }
        }

        do {
            _ = try await execute(["git", "init", "-q", "-b", "main"])
            for pair in [
                ["user.name", "Windows Git Review Fixture"],
                ["user.email", "fixture@invalid"],
                ["commit.gpgsign", "false"],
                ["core.autocrlf", "true"],
                ["filter.drop.clean", "sed '/^TRANSIENT/d'"],
            ] {
                _ = try await execute(["git", "config"] + pair)
            }
            try await backend.write(
                path: root + "/.gitattributes",
                data: Data("note.txt text\nraw.txt -text\nfiltered.txt filter=drop\n".utf8)
            )
            let base = "alpha\nbeta\nlast\n"
            try await backend.write(path: root + "/note.txt", data: Data(base.utf8))
            try await backend.write(path: root + "/raw.txt", data: Data(base.utf8))
            try await backend.write(path: root + "/filtered.txt", data: Data("keep\n".utf8))
            _ = try await execute(["git", "add", "--", "."])
            _ = try await execute(["git", "commit", "-qm", "Windows SSH fixture"])
            let checkout = "alpha\r\nbeta\r\nlast\r\n"
            try await backend.write(path: root + "/note.txt", data: Data(checkout.utf8))
            try await backend.write(path: root + "/raw.txt", data: Data(checkout.utf8))
            try await backend.write(
                path: root + "/filtered.txt",
                data: Data("changed\nTRANSIENT\n".utf8)
            )
            let truth = try await execute(["git", "diff", "--numstat", "--"])
            XCTAssertFalse(truth.contains("note.txt"), truth)
            XCTAssertTrue(truth.contains("raw.txt"), truth)
            XCTAssertTrue(truth.contains("filtered.txt"), truth)

            let preferences = try isolatedPreferences()
            let normal = DiffTab(
                repoRoot: root, path: "note.txt", source: .worktree,
                untracked: false, origPath: nil, backend: backend,
                workspaceIdentity: nil, preferences: preferences
            )
            let raw = DiffTab(
                repoRoot: root, path: "raw.txt", source: .worktree,
                untracked: false, origPath: nil, backend: backend,
                workspaceIdentity: nil, preferences: preferences
            )
            let filtered = DiffTab(
                repoRoot: root, path: "filtered.txt", source: .worktree,
                untracked: false, origPath: nil, backend: backend,
                workspaceIdentity: nil, preferences: preferences
            )
            try await wait({ !normal.isLoading && !raw.isLoading && !filtered.isLoading },
                           timeout: 90)
            XCTAssertNil(normal.error)
            XCTAssertNil(raw.error)
            XCTAssertNil(filtered.error)
            XCTAssertFalse(normal.hasChanges, "Windows checkout CRLF is Git-equivalent")
            XCTAssertTrue(raw.hasChanges, "Windows -text must retain real EOL changes")
            XCTAssertEqual(filtered.newContent, "changed\nTRANSIENT\n")
            XCTAssertTrue(filtered.hasChanges)
            try await wait({ filtered.display != nil }, timeout: 30)
            let review = try XCTUnwrap(filtered.display)
            XCTAssertTrue(review.unifiedText.string.contains("changed"))
            XCTAssertFalse(review.unifiedText.string.contains("TRANSIENT"))
            XCTAssertEqual(review.computation.unified.rows.filter { $0.kind == .removed }.count, 1)
            XCTAssertEqual(review.computation.unified.rows.filter { $0.kind == .added }.count, 1)

            XCTAssertTrue(filtered.isEditing)
            filtered.updateEditedContent("changed again\nTRANSIENT\n")
            await filtered.save()
            XCTAssertNil(filtered.saveError)
            let persisted = try await backend.read(path: root + "/filtered.txt", maxBytes: 128)
            XCTAssertEqual(persisted, Data("changed again\nTRANSIENT\n".utf8))
            try await wait({
                !filtered.isLoading && !filtered.isDirty
                    && filtered.newContent == "changed again\nTRANSIENT\n"
                    && filtered.display?.unifiedText.string.contains("changed again") == true
            }, timeout: 90)
            XCTAssertNil(filtered.error)
            XCTAssertEqual(filtered.display?.computation.unified.rows.filter {
                $0.kind == .added
            }.count, 1)
            let after = try await execute(["git", "diff", "--numstat", "--", "filtered.txt"])
            XCTAssertEqual(after.trimmingCharacters(in: .whitespacesAndNewlines),
                           "1\t1\tfiltered.txt")
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    func testEOLOnlyEditAndSaveConvergesToCleanGitReview() async throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("eol-edit.txt")
        let canonical = "alpha\nbeta\nlast\n"
        let checkedOut = "alpha\r\nbeta\r\nlast\r\n"
        try Data(canonical.utf8).write(to: path)
        for args in [["config", "core.autocrlf", "true"], ["add", "."],
                     ["commit", "-qm", "baseline"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: root.path).status, 0)
        }
        try Data(checkedOut.utf8).write(to: path)
        let tab = DiffTab(repoRoot: root.path, path: "eol-edit.txt", source: .worktree,
                          untracked: false, origPath: nil,
                          backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil,
                          preferences: try isolatedPreferences())
        try await wait { !tab.isLoading }
        XCTAssertFalse(tab.hasChanges)
        tab.updateEditedContent(canonical)
        await tab.save()
        XCTAssertNil(tab.saveError)
        XCTAssertEqual(try Data(contentsOf: path), Data(canonical.utf8))
        XCTAssertEqual(GitCommandExecution.run(
            ["diff", "--numstat", "--", "eol-edit.txt"], in: root.path
        ).stdout, "")
        try await wait { !tab.isLoading && !tab.hasChanges }
        XCTAssertNil(tab.display, "Review must converge to Git's clean state after saving")

        tab.updateEditedContent(checkedOut)
        tab.autoSaveOnFocusLoss()
        try await wait {
            !tab.isLoading && !tab.isDirty && !tab.hasChanges
                && (try? Data(contentsOf: path)) == Data(checkedOut.utf8)
        }
        XCTAssertNil(tab.saveError)
        XCTAssertNil(tab.display, "Auto-save must refresh the Git comparison baseline")
    }

    func testCRLFNativeReviewRowsAndEditUndoSavePreserveBytes() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("crlf.txt")
        let old = "one\r\nold\r\nlast\n"
        let new = "one\r\nnew\r\nlast\n"
        try Data(old.utf8).write(to: file)
        for args in [["add", "."], ["commit", "-qm", "baseline"]] {
            XCTAssertEqual(GitCommandExecution.run(args, in: directory.path).status, 0)
        }
        try Data(new.utf8).write(to: file)
        let domain = "bailey-crlf-native-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let diff = DiffTab(
            repoRoot: directory.path, path: "crlf.txt", source: .worktree,
            untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: nil, preferences: preferences
        )
        try await wait { !diff.isLoading && diff.display != nil }
        XCTAssertNil(diff.error)
        XCTAssertEqual(Data(diff.oldContent.utf8), Data(old.utf8))
        XCTAssertEqual(Data(diff.newContent.utf8), Data(new.utf8))
        let display = try XCTUnwrap(diff.display)
        XCTAssertEqual(display.computation.unified.rows.compactMap(\.oldLine), [1, 2, 3])
        XCTAssertEqual(display.computation.unified.rows.compactMap(\.newLine), [1, 2, 3])
        XCTAssertEqual(display.computation.splitLeft.rows.count, display.computation.splitRight.rows.count)
        let decorated = DiffDecorations.review(display.computation.unified)
        XCTAssertEqual(decorated.rows.count, 4)
        XCTAssertEqual(decorated.lineStartOffsets.count, 4)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 830, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await wait { self.findNativeTextView(in: host, editable: true) != nil }
        let editor = try XCTUnwrap(findNativeTextView(in: host, editable: true))
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(new.utf8))
        try await wait { diff.editDecorations.ghostsByAnchor.values.reduce(0) { $0 + $1.lines.count } == 1 }
        let surface = try XCTUnwrap(diff.nativeSurface)
        diff.setDiffStyle(.split)
        try await wait {
            let visible = surface.subviews.compactMap { $0 as? DiffCodePaneView }
                .filter { !$0.isHidden }
            return visible.count == 2 && visible.filter { $0.textView.isEditable }.count == 1
        }
        XCTAssertTrue(findNativeTextView(in: surface, editable: true) === editor)
        XCTAssertTrue(surface.subviews.compactMap { $0 as? DiffCodePaneView }
            .contains { !$0.isHidden && !$0.textView.isEditable })
        diff.setDiffStyle(.unified)
        let replacement = (try XCTUnwrap(editor.text) as NSString).range(of: "new")
        XCTAssertNotEqual(replacement.location, NSNotFound)
        editor.insertText("newer", replacementRange: replacement)
        let edited = "one\r\nnewer\r\nlast\n"
        XCTAssertEqual(Data(diff.editedNewContent.utf8), Data(edited.utf8))
        editor.undoManager?.undo()
        XCTAssertEqual(Data(diff.editedNewContent.utf8), Data(new.utf8))
        editor.undoManager?.redo()
        XCTAssertEqual(Data(diff.editedNewContent.utf8), Data(edited.utf8))
        await diff.save()
        XCTAssertNil(diff.error)
        XCTAssertEqual(try Data(contentsOf: file), Data(edited.utf8))
        try await wait { diff.newContent.utf8.elementsEqual(edited.utf8) }
    }

    func testNativeDiffUnicodeAndSplitAlignmentWithFoldExpansion() {
        let old = "one\r\n中文😀\r\nlast\n"
        let new = "one\r\n中文🪨\r\nlast"
        let compared = DiffComputation.compute(oldText: old, newText: new)
        XCTAssertEqual(compared.splitLeft.rows.count, compared.splitRight.rows.count)
        XCTAssertEqual(compared.unified.rows.count, compared.unified.lineStartOffsets.count)
        XCTAssertTrue(compared.unified.rows.contains { if case .removed = $0.kind { true } else { false } })
        XCTAssertTrue(compared.unified.rows.contains { if case .added = $0.kind { true } else { false } })
        XCTAssertTrue(compared.unified.rows.contains { $0.missingNewline })
        XCTAssertTrue(compared.unified.text.contains("中文"))

        let oldLines = (0..<240).map { "line \($0)" }
        var newLines = oldLines
        newLines[120] = "line 120 changed"
        let oldText = oldLines.joined(separator: "\n") + "\n"
        let newText = newLines.joined(separator: "\n") + "\n"
        let core = DiffCore.compute(oldText: oldText, newText: newText)
        let folded = DiffComputation.build(core: core, revealedLines: [])
        let folds = folded.unified.rows.compactMap(\.collapsed)
        XCTAssertFalse(folds.isEmpty)
        XCTAssertEqual(folded.splitLeft.rows.count, folded.splitRight.rows.count)
        let expanded = DiffComputation.build(
            core: core,
            revealedLines: folds[0].revealNext()
        )
        XCTAssertGreaterThan(expanded.unified.rows.count, folded.unified.rows.count)
        XCTAssertEqual(expanded.splitLeft.rows.count, expanded.splitRight.rows.count)
    }

    func testCollapsedDiffAccessibilityPressReachesNativeExpansion() async throws {
        let oldLines = (0..<240).map { "line \($0)" }
        var newLines = oldLines
        newLines[120] = "line 120 changed"
        let old = oldLines.joined(separator: "\n") + "\n"
        let new = newLines.joined(separator: "\n") + "\n"
        let compared = DiffComputation.build(
            core: DiffCore.compute(oldText: old, newText: new), revealedLines: []
        )
        XCTAssertTrue(compared.unified.rows.contains { $0.collapsed != nil })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = DiffCodePaneView(mode: .review, gutterLayout: .single)
        window.contentView = pane
        window.orderFront(nil)
        pane.setReviewDocument(
            NSAttributedString(string: compared.unified.text),
            decorations: DiffDecorations.review(compared.unified)
        )
        pane.layoutSubtreeIfNeeded()
        let gutter = try XCTUnwrap(pane.subviews.compactMap { $0 as? DiffGutterView }.first)
        var expanded: DiffCollapsedRun?
        pane.onExpandCollapsedRun = { expanded = $0 }
        try await wait {
            pane.layoutSubtreeIfNeeded()
            return (gutter.accessibilityChildren()?.count ?? 0) > 0
        }
        let controls = try XCTUnwrap(gutter.accessibilityChildren())
        let first = try XCTUnwrap(controls.first as? NSAccessibilityElement)
        let expectedRow = try XCTUnwrap(DiffRowGeometry.visibleRows(
            textView: pane.textView, decorations: pane.decorations
        ).first { $0.index < pane.decorations.rows.count
            && pane.decorations.rows[$0.index].collapsed != nil })
        let axFrame = first.accessibilityFrame()
        let center = NSPoint(x: axFrame.midX, y: axFrame.midY)
        let cursor = gutter.convert(window.convertPoint(fromScreen: center), from: nil)
        let expectedY = expectedRow.frame.midY - pane.scrollView.contentView.bounds.origin.y
        XCTAssertEqual(cursor.y, expectedY, accuracy: 2,
                       "The actual center of an AX fold button must hit the native gutter separator")
        XCTAssertTrue(first.accessibilityPerformPress())
        let activated = try XCTUnwrap(expanded)
        XCTAssertTrue(compared.unified.rows.contains {
            $0.collapsed?.baselineRange == activated.baselineRange
        })
    }

    func testEditableFoldAccessibilityFrameMatchesActualClickAfterScrolling() throws {
        let old = (0..<900).map { "line \($0)\n" }.joined()
        let modified = old.replacingOccurrences(of: "line 594\n", with: "changed 594\n")
            .replacingOccurrences(of: "line 617\n", with: "changed 617\n")
        let core = DiffCore.compute(oldText: old, newText: modified)
        let projection = DiffComputation.build(core: core, revealedLines: [])
        let offsets = core.newLines.map(\.utf16Range.location)
        let folds = DiffEditFold.sourceFolds(in: projection.unified, lineCount: offsets.count)
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 750, height: 280),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        pane.applyTypography(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                             paragraphStyle: DiffTypography.paragraphStyle(
                                 for: .monospacedSystemFont(ofSize: 12, weight: .regular)),
                             textColor: .textColor)
        pane.setEditBufferText(modified)
        pane.setEditingFolds(
            folds, lineOffsets: offsets,
            baseDecorations: .edit(state: projection.editState, snapshotOffsets: offsets,
                                   lineCount: offsets.count, ghostBlocks: []),
            revision: 1
        )
        pane.layoutSubtreeIfNeeded()
        let gutter = try XCTUnwrap(pane.subviews.compactMap { $0 as? DiffGutterView }.first)
        let scroll = pane.scrollView.contentView
        for offset in [0.0, 50.0, 100.0] {
            pane.setVerticalScrollOffset(offset)
            pane.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let rows = DiffRowGeometry.visibleRows(textView: pane.textView,
                                                   decorations: pane.decorations)
            let folded = rows.filter { $0.index < pane.decorations.rows.count
                && pane.decorations.rows[$0.index].collapsed != nil }
            let children = gutter.accessibilityChildren() ?? []
            XCTAssertEqual(children.count, folded.count)
            for (row, child) in zip(folded, children) {
                let button = try XCTUnwrap(child as? NSAccessibilityElement)
                let frame = button.accessibilityFrame()
                let cursor = gutter.convert(window.convertPoint(fromScreen: NSPoint(
                    x: frame.midX, y: frame.midY
                )), from: nil)
                let expected = row.frame.midY - scroll.bounds.origin.y
                XCTAssertEqual(cursor.y, expected, accuracy: 2,
                               "A scrolled editable AX fold button must hit its actual separator")
            }
        }
        XCTAssertEqual(pane.textView.string, modified)
    }

    func testNativeDiffSplitLayoutPreservesPaneIdentity() async throws {
        let domain = "bailey-native-layout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        preferences.diffStyle = .unified
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(
            repoRoot: "/fixture", path: "split.txt", source: .worktree,
            untracked: true, origPath: nil, backend: backend,
            workspaceIdentity: nil, preferences: preferences
        )
        try await wait { !diff.isLoading && diff.display != nil }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await wait { diff.nativeSurface != nil && self.findNativeTextView(in: host) != nil }
        let surface = try XCTUnwrap(diff.nativeSurface)
        let editor = try XCTUnwrap(findNativeTextView(in: surface, editable: true))
        XCTAssertEqual(editor.text, diff.newContent)

        // The worktree has one editable TextKit document independent of the
        // layout preference; changing the preference cannot replace its undo stack.
        let manager = editor.undoManager
        diff.setDiffStyle(.split)
        try await wait {
            let visible = surface.subviews.compactMap { $0 as? DiffCodePaneView }
                .filter { !$0.isHidden }
            return visible.count == 2 && visible.filter { $0.textView.isEditable }.count == 1
        }
        XCTAssertTrue(findNativeTextView(in: surface, editable: true) === editor)
        XCTAssertTrue(surface.subviews.compactMap { $0 as? DiffCodePaneView }
            .contains { !$0.isHidden && !$0.textView.isEditable })
        diff.setDiffStyle(.unified)
        XCTAssertTrue(findNativeTextView(in: surface, editable: true) === editor)
        XCTAssertTrue(editor.undoManager === manager)
    }

    func testSplitDiffSynchronizesHorizontalAndVerticalScrolling() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("wide.txt")
        let oldText = ([String(repeating: "a", count: 1100)]
            + (0..<150).map { "before \($0)" }).joined(separator: "\n") + "\n"
        let newText = ([String(repeating: "b", count: 1400)]
            + (0..<150).map { "after \($0)" }).joined(separator: "\n") + "\n"
        try Data(oldText.utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["add", "wide.txt"], in: directory.path).status, 0)
        XCTAssertEqual(GitCommandExecution.run(["commit", "-qm", "baseline"], in: directory.path).status, 0)
        try Data(newText.utf8).write(to: file)
        XCTAssertEqual(GitCommandExecution.run(["add", "wide.txt"], in: directory.path).status, 0)

        let suite = "bailey-diff-scroll-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DiffViewPreferences(defaults: defaults)
        preferences.diffStyle = .split
        let diff = DiffTab(
            repoRoot: directory.path, path: "wide.txt", source: .staged,
            untracked: false, origPath: nil, backend: LocalWorkspaceBackend.shared,
            workspaceIdentity: nil, preferences: preferences
        )
        try await wait { !diff.isLoading && diff.display != nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.contentView = host
        window.orderFront(nil)

        try await wait {
            host.layoutSubtreeIfNeeded()
            guard let surface = diff.nativeSurface else { return false }
            surface.layoutSubtreeIfNeeded()
            let panes = surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }
            guard panes.count == 2 else { return false }
            return panes.allSatisfy { pane in
                pane.layoutSubtreeIfNeeded()
                return (pane.scrollView.documentView?.frame.width ?? 0)
                    > pane.scrollView.contentView.bounds.width + 300
            }
        }
        let surface = try XCTUnwrap(diff.nativeSurface)
        let panes = surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }
        let left = try XCTUnwrap(panes.first)
        let right = try XCTUnwrap(panes.last)
        XCTAssertFalse(left === right)

        let leftClip = left.scrollView.contentView
        let rightClip = right.scrollView.contentView
        leftClip.scroll(to: NSPoint(x: 120, y: 60))
        left.scrollView.reflectScrolledClipView(leftClip)
        XCTAssertEqual(leftClip.bounds.origin.x, 120, accuracy: 1)
        XCTAssertEqual(rightClip.bounds.origin.x, leftClip.bounds.origin.x, accuracy: 1)
        XCTAssertEqual(rightClip.bounds.origin.y, leftClip.bounds.origin.y, accuracy: 1)

        rightClip.scroll(to: NSPoint(x: 240, y: 100))
        right.scrollView.reflectScrolledClipView(rightClip)
        XCTAssertEqual(rightClip.bounds.origin.x, 240, accuracy: 1)
        XCTAssertEqual(leftClip.bounds.origin.x, rightClip.bounds.origin.x, accuracy: 1)
        XCTAssertEqual(leftClip.bounds.origin.y, rightClip.bounds.origin.y, accuracy: 1)

        // A longer right-hand line can scroll farther without being pulled
        // back by the shorter left-hand document.
        let leftEnd = (left.scrollView.documentView?.frame.width ?? 0) - leftClip.bounds.width
        let rightEnd = (right.scrollView.documentView?.frame.width ?? 0) - rightClip.bounds.width
        XCTAssertGreaterThan(rightEnd, leftEnd + 200)
        rightClip.scroll(to: NSPoint(x: leftEnd + 120, y: 100))
        right.scrollView.reflectScrolledClipView(rightClip)
        XCTAssertEqual(leftClip.bounds.origin.x, leftEnd, accuracy: 2)
        XCTAssertEqual(rightClip.bounds.origin.x, leftEnd + 120, accuracy: 2)

        diff.setDiffStyle(.unified)
        try await wait { surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }.count == 1 }
        diff.setDiffStyle(.split)
        try await wait { surface.subviews.compactMap { $0 as? DiffCodePaneView }.filter { !$0.isHidden }.count == 2 }
        XCTAssertEqual(leftClip.bounds.origin.x, leftEnd, accuracy: 2)
        XCTAssertEqual(rightClip.bounds.origin.x, leftEnd + 120, accuracy: 2)
        leftClip.scroll(to: NSPoint(x: 30, y: 0))
        left.scrollView.reflectScrolledClipView(leftClip)
        XCTAssertEqual(rightClip.bounds.origin.x, 30, accuracy: 1)
    }

    func testReadInFlightCannotReplaceEditingOrDisconnectedContent() async throws {
        let domain = "bailey-native-stale-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "stale.txt", source: .worktree,
                           untracked: true, origPath: nil, backend: backend,
                           workspaceIdentity: "ssh:fixture", preferences: preferences)
        try await wait { !diff.isLoading }
        let baseline = diff.newContent
        await backend.pauseOneRead()
        diff.reload()
        try await wait { await backend.reading }
        diff.updateEditedContent("editing during read")
        await backend.finishRead(with: Data("stale result".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(diff.isDirty)
        XCTAssertEqual(diff.newContent, baseline)

        XCTAssertFalse(diff.isLoading, "Invalidated read must release its loading state")

        diff.updateEditedContent(baseline)
        XCTAssertFalse(diff.isDirty)
        await backend.pauseOneRead()
        diff.reload()
        try await wait { await backend.reading }
        let project = Project(fallbackName: "disconnected", workspaceConfiguration: .standard)
        diff.reevaluateWorkspace(in: project)
        await backend.finishRead(with: Data("outdated before outage".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotNil(diff.readOnlyReason)
        XCTAssertEqual(diff.newContent, baseline)
        XCTAssertFalse(diff.isEditableNow)
        XCTAssertFalse(diff.isLoading, "Disconnect must release the invalidated read")
    }

    func testGitReloadUpdatesCleanMountedEditSurfaceWithoutLosingDirtyText() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("reload.txt")
        try Data("before\n".utf8).write(to: file)
        let domain = "bailey-git-reload-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let diff = DiffTab(repoRoot: directory.path, path: "reload.txt", source: .worktree,
                           untracked: true, origPath: nil, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil, preferences: preferences)
        try await wait { !diff.isLoading && diff.isEditable }
        let window = NSWindow(contentRect: .init(x: -1200, y: -1200, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: DiffViewerView(diff: diff))
        window.orderFront(nil)
        try await wait { self.findNativeTextView(in: window.contentView!, editable: true) != nil }
        let editor = try XCTUnwrap(findNativeTextView(in: window.contentView!, editable: true))
        try Data("after Git\n".utf8).write(to: file)
        diff.reload()
        try await wait {
            !diff.isLoading && diff.canPresentNativeContent && editor.text == "after Git\n"
                && self.findNativeTextView(in: window.contentView!, editable: true) === editor
        }
        XCTAssertTrue(findNativeTextView(in: window.contentView!, editable: true) === editor)
        editor.insertText("draft ", replacementRange: .init(location: 0, length: 0))
        try await wait { diff.isDirty }
        try Data("external\n".utf8).write(to: file)
        diff.reload()
        XCTAssertEqual(editor.text, "draft after Git\n")
        XCTAssertTrue(diff.isDirty)
    }

    func testNativeDiffEditUndoScrollSaveAndReparent() async throws {
        let directory = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("editor.txt")
        let original = (0..<180).map { "line \($0) 中文😀\n" }.joined()
        try Data(original.utf8).write(to: file)
        let domain = "bailey-native-diff-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let diff = DiffTab(repoRoot: directory.path, path: "editor.txt", source: .worktree,
                           untracked: true, origPath: nil, backend: LocalWorkspaceBackend.shared,
                           workspaceIdentity: nil, preferences: preferences)
        try await wait { !diff.isLoading && diff.isEditable && diff.display != nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = container
        var host: NSHostingView<DiffViewerView>?
        func mount() {
            let root = NSHostingView(rootView: DiffViewerView(diff: diff))
            root.frame = container.bounds
            host = root
            container.addSubview(root)
            window.orderFront(nil)
            root.layoutSubtreeIfNeeded()
        }
        mount()
        try await wait { diff.nativeSurface != nil && self.findNativeTextView(in: container, editable: true) != nil }
        let surface = try XCTUnwrap(diff.nativeSurface)
        let editor = try XCTUnwrap(findNativeTextView(in: surface, editable: true))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("E", replacementRange: NSRange(location: 0, length: 0))
        try await wait { diff.isDirty }
        XCTAssertEqual(editor.text, "E" + original)
        // Keep the native insertion point inside the viewport before
        // checking that reparenting preserves the reader's scroll offset.
        editor.textSelection = NSRange(
            location: (editor.text! as NSString).range(of: "line 45").location,
            length: 0
        )
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 700))
        scroll.reflectScrolledClipView(scroll.contentView)
        let previousOffset = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(previousOffset.y, 0)
        let undoManager = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undoManager.canUndo)

        host?.removeFromSuperview()
        host = nil
        mount()
        try await wait { self.findNativeTextView(in: container, editable: true) === editor }
        XCTAssertTrue(diff.nativeSurface === surface)
        XCTAssertTrue(findNativeTextView(in: container, editable: true) === editor)
        XCTAssertEqual(scroll.contentView.bounds.origin, previousOffset,
                       "Reparent scroll: editor=\(editor.frame), clip=\(scroll.contentView.bounds), doc=\(String(describing: scroll.documentView?.frame))")
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        try await wait { !diff.isDirty }
        XCTAssertEqual(editor.text, original)
        undoManager.redo()
        try await wait { diff.isDirty }
        XCTAssertEqual(editor.text, "E" + original)
        await diff.save()
        XCTAssertFalse(diff.isDirty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "E" + original)

        // Save completion must update the comparison without replacing the editor.
        try await wait { diff.newContent == "E" + original && diff.display != nil }
        XCTAssertEqual(diff.newContent, "E" + original)
        host?.removeFromSuperview()
    }

    func testDirectWorktreeEditingDiscardsInFlightReadAndKeepsSharedPreferences() async throws {
        let domain = "bailey-diff-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = DiffViewPreferences(defaults: defaults)
        let backend = DiffWorkspaceFixture()
        let diff = DiffTab(repoRoot: "/fixture", path: "editing.txt", source: .worktree,
                           untracked: true, origPath: nil, backend: backend, workspaceIdentity: nil,
                           preferences: preferences)
        try await wait { !diff.isLoading }
        let baseline = diff.newContent
        await backend.pauseOneRead()
        diff.reload()
        try await wait { await backend.reading }
        XCTAssertTrue(diff.preferences === preferences)
        XCTAssertTrue(diff.isEditing, "A regular worktree is directly editable")
        diff.updateEditedContent("current buffer")
        XCTAssertTrue(diff.isDirty)
        await backend.finishRead(with: Data("stale before editor appeared".utf8))
        try await wait { !diff.isLoading }
        XCTAssertEqual(diff.newContent, baseline)
        XCTAssertEqual(diff.editedNewContent, "current buffer")
        diff.reload()
        XCTAssertEqual(diff.newContent, baseline)
        XCTAssertTrue(diff.isDirty)
        diff.setDiffStyle(.split)
        XCTAssertEqual(defaults.string(forKey: "diffView.layout"), "split")
    }
}
