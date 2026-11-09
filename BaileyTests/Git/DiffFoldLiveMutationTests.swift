import AppKit
import XCTest
@testable import Bailey

@MainActor
final class DiffFoldLiveMutationTests: XCTestCase {
    func testReplacingHiddenSourceKeepsUnrelatedContextCollapsedDuringDebounce() throws {
        let text = (0..<32).map { "line \($0)\n" }.joined()
        for replacement in ["edited 14", "edited\n14"] {
            let editor = DiffTextView()
            editor.text = text
            let index = NativeTextLineIndex(text as NSString, breakMode: .gitLF)
            let starts = (0..<index.lineCount).map(index.offset(atLine:))
            let originalFold = DiffEditFold(
                range: 5..<23,
                separator: DiffCollapsedRun(baselineRange: 5..<23, direction: .both)
            )
            editor.resetLiveGitLineIndex(text)
            XCTAssertTrue(editor.setEditingFolds([originalFold]))
            let range = (text as NSString).range(of: "line 14")
            XCTAssertNotEqual(range.location, NSNotFound)

            editor.textStorage?.replaceCharacters(in: range, with: replacement)
            let edited = try XCTUnwrap(editor.adjustLiveFoldSource(
                in: range, replacement: replacement
            ))
            XCTAssertEqual(edited.lineDelta, replacement.contains("\n") ? 1 : 0)
            XCTAssertTrue(editor.editingFolds.contains { $0.range.contains(8) },
                          "Editing line 14 must not reveal unrelated hidden line 8")
            let shiftedRow = 20 + edited.lineDelta
            XCTAssertTrue(editor.editingFolds.contains { $0.range.contains(shiftedRow) },
                          "Editing line 14 must not reveal unrelated hidden line 20")
        }
    }

    func testRemovedRowGhostStaysOnItsSourceLineDuringLiveNewlineEdit() throws {
        let before = (0..<80).map { "line \($0)\n" }.joined()
        let after = before.replacingOccurrences(of: "line 40\n", with: "changed 40\n")
        let core = DiffCore.compute(oldText: before, newText: after)
        let projection = DiffComputation.build(core: core, revealedLines: [])
        let folds = DiffEditFold.sourceFolds(in: projection.unified,
                                             lineCount: core.newLines.count)
        let starts = core.newLines.map(\.utf16Range.location)
        let ghost = try XCTUnwrap(projection.editState.ghosts.first)
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        pane.setEditBufferText(after)
        pane.setEditingFolds(
            folds,
            baseDecorations: .edit(
                state: projection.editState, snapshotOffsets: starts,
                lineCount: starts.count,
                ghostBlocks: [
                    .init(anchorLine: ghost.anchorLine, firstOldLine: ghost.firstOldLine,
                          lines: [NSAttributedString(string: "line 40")])
                ]
            ),
            revision: 1
        )
        XCTAssertNotNil(pane.decorations.ghostsByAnchor[ghost.anchorLine])
        let insertion = NSRange(location: (after as NSString).range(of: "line 10").location,
                                length: 0)
        pane.textView.textStorage?.replaceCharacters(in: insertion, with: "\n")
        pane.applyLiveNativeEdit(previousRange: insertion, replacement: "\n")
        let newAnchor = ghost.anchorLine + 1
        XCTAssertNotNil(pane.decorations.ghostsByAnchor[newAnchor],
                        "A deleted row must follow its source line without waiting for Diff")
        XCTAssertNil(pane.decorations.ghostsByAnchor[ghost.anchorLine])
        XCTAssertEqual(pane.textView.liveGitOffset(forLine: newAnchor),
                       (pane.textView.string as NSString).range(of: "changed 40").location)
        XCTAssertEqual(pane.decorations.rows.count, starts.count + 1)
    }

    func testLeadingDeletionGhostNeverOverlapsEditableGlyphsAfterNewlineEdit() throws {
        let original = "let value = 2\n"
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let window = NSWindow(contentRect: CGRect(x: -900, y: -900, width: 700, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = pane
        window.orderFront(nil)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .textColor)
        pane.setEditBufferText(original)
        let initialOffsets = [0]
        let ghost = DiffDecorations.GhostBlock(
            anchorLine: 0, firstOldLine: 1,
            lines: [NSAttributedString(string: "let value = 1")]
        )
        let state = DiffEditState(addedLines: [0], addedEmphasis: [:], ghosts: [])
        pane.setEditingFolds([],
                             baseDecorations: .edit(state: state, snapshotOffsets: initialOffsets,
                                                    lineCount: 1, ghostBlocks: [ghost]),
                             revision: 1)
        pane.layoutSubtreeIfNeeded()

        func assertNoOverlap(_ phase: String) {
            let first = DiffRowGeometry.visibleRows(textView: pane.textView,
                                                     decorations: pane.decorations)
                .first { $0.index == 0 && !$0.isContinuation }
            let row = try? XCTUnwrap(first)
            let lineHeight = DiffTypography.lineHeight(for: pane.textView.font
                ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
            XCTAssertGreaterThanOrEqual(row?.frame.minY ?? -1, lineHeight - 1,
                                        "\(phase): source glyphs must start below the deleted row")
            let screenRect = pane.textView.firstRect(
                forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil
            )
            let nativeRect = pane.textView.convert(window.convertFromScreen(screenRect), from: nil)
            XCTAssertGreaterThanOrEqual(nativeRect.minY, lineHeight - 1,
                                        "\(phase): actual TextKit glyph must stay outside the removed ghost")
        }

        assertNoOverlap("initial")
        let insertion = NSRange(location: original.utf16.count, length: 0)
        pane.textView.textStorage?.replaceCharacters(
            in: insertion, with: "let value = 3 // 中文 👋\n")
        pane.applyLiveNativeEdit(previousRange: insertion,
                                 replacement: "let value = 3 // 中文 👋\n")
        pane.layoutSubtreeIfNeeded()
        XCTAssertNotNil(pane.decorations.ghostsByAnchor[0],
                        "An append must not lose an unrelated deletion at the start")
        XCTAssertEqual(pane.textView.textContainerInset.height,
                       DiffTypography.lineHeight(for: font), accuracy: 1,
                       "An unchanged leading ghost still reserves its native top inset")
        assertNoOverlap("after append")
        XCTAssertEqual(pane.textView.string,
                       original + "let value = 3 // 中文 👋\n")
        let larger = NSFont.monospacedSystemFont(ofSize: 19, weight: .regular)
        pane.applyTypography(font: larger,
                             paragraphStyle: DiffTypography.paragraphStyle(for: larger),
                             textColor: .textColor)
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.textView.textContainerInset.height,
                       DiffTypography.lineHeight(for: larger), accuracy: 1,
                       "Font changes must resize the ghost's actual native text gap")
        assertNoOverlap("after font change")
        pane.decorations = .empty
        XCTAssertEqual(pane.textView.textContainerInset.height, 0, accuracy: 0.5,
                       "Removing the last leading deletion must remove its top inset")
    }

    func testLineBoundaryInsertAndDeleteDoNotAttachOldColorsToWrongSourceRows() {
        let text = "row 0\nrow 1\nrow 2\nrow 3\n"
        for (line, deletedRows, replacement, expectedColoredLine) in [
            (2, 0, "\n", 3),
            (1, 2, "", 1),
        ] {
            let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
            pane.setEditBufferText(text)
            let index = NativeTextLineIndex(text as NSString, breakMode: .gitLF)
            let starts = (0..<index.lineCount).map(index.offset(atLine:))
            pane.setEditingFolds(
                [],
                baseDecorations: .edit(
                    state: DiffEditState(addedLines: [deletedRows == 0 ? 2 : 3],
                                         addedEmphasis: [:], ghosts: []),
                    snapshotOffsets: starts, lineCount: starts.count, ghostBlocks: []
                ),
                revision: 1
            )
            let start = starts[line]
            let length = starts[line + deletedRows] - start
            let range = NSRange(location: start, length: length)
            pane.textView.textStorage?.replaceCharacters(in: range, with: replacement)
            pane.applyLiveNativeEdit(previousRange: range, replacement: replacement)
            XCTAssertEqual(pane.decorations.rows[expectedColoredLine].kind, .added,
                           "Unedited original content must retain its row tint after structural edit")
            if deletedRows == 0 {
                XCTAssertEqual(pane.decorations.rows[line].kind, .context,
                               "Inserted empty line must not borrow the original highlighted row tint")
            }
        }
    }

    func testFoldedTextKitEnumeratesOnlyVisibleSourceInBothDirections() throws {
        let source = (0..<100).map { "row \($0)" }.joined(separator: "\n")
        let starts = DiffLineSplitter.lines(of: source).lines.map(\.utf16Range.location)
        let collapsed = [10..<45, 60..<94]
        let folds = collapsed.map {
            DiffEditFold(range: $0,
                         separator: DiffCollapsedRun(baselineRange: $0, direction: .both))
        }
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        pane.setEditBufferText(source)
        pane.setEditingFolds(
            folds, baseDecorations: .edit(
                state: DiffEditState(addedLines: [], addedEmphasis: [:], ghosts: []),
                snapshotOffsets: starts, lineCount: starts.count, ghostBlocks: []),
            revision: 1
        )
        let content = pane.textView.nativeContentManager
        let base = content.documentRange.location
        let wanted = (0..<100).filter { row in
            !collapsed.contains { $0.contains(row) && $0.lowerBound != row }
        }
        for reverse in [false, true] {
            var actual: [Int] = []
            let edge = content.enumerateTextElements(
                from: nil, options: reverse ? .reverse : []
            ) { element in
                if let range = element.elementRange {
                    let offset = content.offset(from: base, to: range.location)
                    actual.append(pane.textView.liveGitLine(atUTF16: offset) ?? -1)
                }
                return true
            }
            XCTAssertEqual(actual, reverse ? Array(wanted.reversed()) : wanted)
            XCTAssertEqual(content.offset(from: base, to: try XCTUnwrap(edge)),
                           reverse ? 0 : (source as NSString).length)
        }
        let hiddenOffset = try XCTUnwrap(pane.textView.liveGitOffset(forLine: 30))
        let hiddenLocation = try XCTUnwrap(content.location(base, offsetBy: hiddenOffset))
        for (reverse, nextExpected) in [(false, 45), (true, 10)] {
            var first: Int?
            _ = content.enumerateTextElements(
                from: hiddenLocation, options: reverse ? .reverse : []
            ) { element in
                guard let range = element.elementRange else { return true }
                let offset = content.offset(from: base, to: range.location)
                first = pane.textView.liveGitLine(atUTF16: offset)
                return false
            }
            XCTAssertEqual(first, nextExpected,
                           "Enumeration starting inside hidden text must reach a visible row")
        }
    }

    func testNewSourceRetiresOldFoldsGhostsAndPresentationRevision() {
        let oldText = (0..<200).map { "old \($0)" }.joined(separator: "\n")
        let oldStarts = DiffLineSplitter.lines(of: oldText).lines.map(\.utf16Range.location)
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        pane.setEditBufferText(oldText)
        let range = 50..<150
        pane.setEditingFolds(
            [DiffEditFold(range: range,
                          separator: DiffCollapsedRun(baselineRange: range, direction: .both))],
            baseDecorations: .edit(
                state: DiffEditState(addedLines: [], addedEmphasis: [:], ghosts: []),
                snapshotOffsets: oldStarts, lineCount: oldStarts.count,
                ghostBlocks: [.init(anchorLine: 175, firstOldLine: 175,
                                    lines: [NSAttributedString(string: "old deletion")])]),
            revision: 1
        )
        XCTAssertFalse(pane.textView.editingFolds.isEmpty)
        XCTAssertNotNil(pane.decorations.ghostsByAnchor[175])

        let replacement = "fresh\ncontent\n"
        pane.setEditBufferText(replacement)
        XCTAssertEqual(pane.textView.string, replacement)
        XCTAssertTrue(pane.textView.editingFolds.isEmpty)
        XCTAssertTrue(pane.decorations.rows.isEmpty)
        XCTAssertTrue(pane.decorations.ghostsByAnchor.isEmpty)
        XCTAssertNil(pane.textView.overrideContentHeight)

        let newStarts = DiffLineSplitter.lines(of: replacement).lines.map(\.utf16Range.location)
        pane.setEditingFolds(
            [], baseDecorations: .edit(
                state: DiffEditState(addedLines: [1], addedEmphasis: [:], ghosts: []),
                snapshotOffsets: newStarts, lineCount: newStarts.count, ghostBlocks: []),
            revision: 1
        )
        XCTAssertEqual(pane.decorations.rows.count, 2,
                       "A new source must accept its first presentation despite reused version")
        XCTAssertEqual(pane.decorations.rows[1].kind, .added)
        XCTAssertEqual(pane.textView.liveGitOffset(forLine: 1), 6)
    }

    func testLiveGhostVirtualRowsDoNotRewriteParagraphSpacingAcrossCRChanges() throws {
        let text = "first\nsecond\n"
        let second = (text as NSString).range(of: "second").location
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pane.applyTypography(font: font, paragraphStyle: DiffTypography.paragraphStyle(for: font),
                             textColor: .textColor)
        pane.setEditBufferText(text)
        pane.setEditingFolds(
            [], baseDecorations: .edit(
                state: DiffEditState(addedLines: [], addedEmphasis: [:], ghosts: []),
                snapshotOffsets: [0, second], lineCount: 2,
                ghostBlocks: [.init(anchorLine: 1, firstOldLine: 1,
                                    lines: [NSAttributedString(string: "removed")])]),
            revision: 1
        )
        pane.textView.isEditable = true
        pane.textView.onCharacterEdit = { [weak pane] range, replacement in
            pane?.applyLiveNativeEdit(previousRange: range, replacement: replacement)
        }
        func ghostGap() throws -> CGFloat {
            let attributes = try XCTUnwrap(pane.textView.attributedText)
            let style = attributes.attribute(.paragraphStyle, at: second,
                                             effectiveRange: nil) as? NSParagraphStyle
            return style?.paragraphSpacingBefore ?? 0
        }
        XCTAssertEqual(try ghostGap(), 0, accuracy: 0.5,
                       "Fixed LF uses virtual deletion geometry, not native paragraph spacing")
        pane.textView.insertText("\r", replacementRange: NSRange(location: second + 3, length: 0))
        XCTAssertTrue(pane.textView.hasNativeNonLFSeparators)
        XCTAssertEqual(try ghostGap(), 0, accuracy: 0.5,
                       "CR must retain virtual ghost geometry without rewriting source paragraphs")
        pane.textView.insertText("", replacementRange: NSRange(location: second + 3, length: 1))
        XCTAssertFalse(pane.textView.hasNativeNonLFSeparators)
        XCTAssertEqual(try ghostGap(), 0, accuracy: 0.5,
                       "Restoring LF-only text must remove stale native ghost spacing")
        XCTAssertEqual(pane.textView.string, text)
        XCTAssertEqual(pane.textView.liveGitSourceLineCount, 2)
    }

    func testEmphasisKeepsItsSourceCharacterAcrossAnEarlierStructuralEdit() {
        let source = "first\nabcXdef\nthird\n"
        let starts = DiffLineSplitter.lines(of: source).lines.map(\.utf16Range.location)
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        pane.setEditBufferText(source)
        pane.setEditingFolds(
            [], baseDecorations: .edit(
                state: DiffEditState(addedLines: [1],
                                     addedEmphasis: [1: [NSRange(location: 3, length: 1)]],
                                     ghosts: []),
                snapshotOffsets: starts, lineCount: starts.count, ghostBlocks: []),
            revision: 1
        )
        XCTAssertEqual(pane.decorations.rows[1].emphasis,
                       [NSRange(location: 3, length: 1)])
        pane.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0),
                                                     with: "inserted\n")
        pane.applyLiveNativeEdit(previousRange: NSRange(location: 0, length: 0),
                                 replacement: "inserted\n")
        XCTAssertEqual(pane.decorations.rows[2].kind, .added)
        XCTAssertEqual(pane.decorations.rows[2].emphasis,
                       [NSRange(location: 3, length: 1)])
        let offset = pane.textView.liveGitOffset(forLine: 2) ?? -1
        XCTAssertEqual((pane.textView.string as NSString).substring(
            with: NSRange(location: offset + 3, length: 1)), "X")
    }

    func testLiveGitRowsExcludeTerminalEmptyParagraphAcrossEOFEdits() {
        let cases: [(text: String, range: NSRange, replacement: String)] = [
            ("first\nsecond\n", NSRange(location: 0, length: 0), "\n"),
            ("one\n", NSRange(location: 4, length: 0), "tail"),
            ("one\n", NSRange(location: 4, length: 0), "tail\n"),
            ("one", NSRange(location: 3, length: 0), "\n"),
            ("one\n", NSRange(location: 3, length: 1), ""),
            ("one\n", NSRange(location: 0, length: 4), ""),
            ("", NSRange(location: 0, length: 0), "one\n"),
            ("one\n", NSRange(location: 4, length: 0), "\n"),
        ]
        for item in cases {
            let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
            pane.setEditBufferText(item.text)
            let originalLines = DiffLineSplitter.lines(of: item.text).lines
            let starts = originalLines.map(\.utf16Range.location)
            pane.setEditingFolds(
                [], baseDecorations: .edit(
                    state: DiffEditState(addedLines: [], addedEmphasis: [:], ghosts: []),
                    snapshotOffsets: starts, lineCount: starts.count, ghostBlocks: []),
                revision: 1
            )
            let changed = (item.text as NSString).replacingCharacters(in: item.range,
                                                                       with: item.replacement)
            pane.textView.textStorage?.replaceCharacters(in: item.range, with: item.replacement)
            pane.applyLiveNativeEdit(previousRange: item.range, replacement: item.replacement)
            let actualLines = DiffLineSplitter.lines(of: changed).lines
            XCTAssertEqual(pane.textView.liveGitSourceLineCount, actualLines.count,
                           "Git source line count must exclude TextKit's terminal empty paragraph")
            XCTAssertEqual(pane.decorations.rows.count, max(1, actualLines.count),
                           "Live Diff rows must track Git line count after EOF changes")
            XCTAssertEqual(pane.textView.string, changed)
        }
    }

    func testUnfoldedEditableDiffRowsTrackInsertedLFBeforeBackgroundProjection() {
        let text = "first\nsecond\n"
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        pane.setEditBufferText(text)
        let starts = DiffLineSplitter.lines(of: text).lines.map(\.utf16Range.location)
        let state = DiffEditState(addedLines: [], addedEmphasis: [:], ghosts: [])
        pane.setEditingFolds(
            [],
            baseDecorations: .edit(state: state, snapshotOffsets: starts,
                                   lineCount: starts.count, ghostBlocks: []),
            revision: 1
        )
        let insertion = NSRange(location: "first".utf16.count, length: 0)
        pane.textView.textStorage?.replaceCharacters(in: insertion, with: "\n")
        pane.applyLiveNativeEdit(previousRange: insertion, replacement: "\n")
        XCTAssertEqual(pane.decorations.rows.count, starts.count + 1,
                       "An unfolded editable Diff must not display stale row numbers during debounce")
        XCTAssertEqual(pane.textView.liveGitSourceLineCount, starts.count + 1)
        XCTAssertEqual(pane.decorations.rows.count, starts.count + 1)
    }
}
