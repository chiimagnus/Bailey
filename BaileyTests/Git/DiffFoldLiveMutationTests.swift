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
