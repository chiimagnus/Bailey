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
            XCTAssertTrue(editor.setEditingFolds([originalFold], lineOffsets: starts))
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
            folds, lineOffsets: starts,
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
        XCTAssertEqual(pane.decorations.editSnapshotOffsets[newAnchor],
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
        pane.setEditingFolds([], lineOffsets: initialOffsets,
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
                [], lineOffsets: starts,
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

    func testUnfoldedEditableDiffRowsTrackInsertedLFBeforeBackgroundProjection() {
        let text = "first\nsecond\n"
        let pane = DiffCodePaneView(mode: .edit, gutterLayout: .single)
        pane.setEditBufferText(text)
        let index = NativeTextLineIndex(text as NSString, breakMode: .gitLF)
        let starts = (0..<index.lineCount).map(index.offset(atLine:))
        let state = DiffEditState(addedLines: [], addedEmphasis: [:], ghosts: [])
        pane.setEditingFolds(
            [], lineOffsets: starts,
            baseDecorations: .edit(state: state, snapshotOffsets: starts,
                                   lineCount: starts.count, ghostBlocks: []),
            revision: 1
        )
        let insertion = NSRange(location: "first".utf16.count, length: 0)
        pane.textView.textStorage?.replaceCharacters(in: insertion, with: "\n")
        pane.applyLiveNativeEdit(previousRange: insertion, replacement: "\n")
        XCTAssertEqual(pane.decorations.rows.count, starts.count + 1,
                       "An unfolded editable Diff must not display stale row numbers during debounce")
        XCTAssertEqual(pane.decorations.editSnapshotOffsets.count, starts.count + 1)
    }
}
