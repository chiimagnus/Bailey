import Foundation
import XCTest
@testable import Bailey

final class DiffEngineTests: XCTestCase {
    func testBaselineRevelationsSurviveNewEditsAndSplitUnchangedRunIntoTwoFolds() {
        let original = (0..<1_200).map { "line \($0)\n" }.joined()
        let modified = original.replacingOccurrences(of: "line 150\n", with: "changed 150\n")
            .replacingOccurrences(of: "line 1050\n", with: "changed 1050\n")
        let core = DiffCore.compute(oldText: original, newText: modified)
        let revealed = 500..<506
        let projected = DiffComputation.build(core: core, revealedLines: [revealed])
        let originalRanges = projected.unified.rows.compactMap(\.collapsed)
            .map(\.baselineRange)
        XCTAssertTrue(originalRanges.contains { $0.upperBound == revealed.lowerBound })
        XCTAssertTrue(originalRanges.contains { $0.lowerBound == revealed.upperBound })
        for line in revealed {
            XCTAssertTrue(projected.unified.rows.contains { $0.oldLine == line + 1 },
                          "Explicitly revealed original line \(line) must stay visible")
        }
        XCTAssertEqual(projected.splitLeft.rows.count, projected.splitRight.rows.count)
        XCTAssertEqual(projected.unified.rows.compactMap(\.collapsed),
                       projected.splitLeft.rows.compactMap(\.collapsed))

        let updated = modified.replacingOccurrences(of: "line 300\n", with: "changed 300\n")
        let edited = DiffComputation.build(
            core: .compute(oldText: original, newText: updated), revealedLines: [revealed]
        )
        for line in revealed {
            XCTAssertTrue(edited.unified.rows.contains { $0.oldLine == line + 1 })
        }
        XCTAssertTrue(edited.unified.rows.contains { $0.collapsed?.baselineRange.contains(900) == true })
        XCTAssertEqual(edited.splitLeft.rows.count, edited.splitRight.rows.count)
        XCTAssertEqual(edited.unified.rows.compactMap(\.collapsed),
                       edited.splitRight.rows.compactMap(\.collapsed))
    }

    func testSeededUnicodeAndNewlineDiffsPreserveAllOriginalByteAndRowRanges() {
        var seed: UInt64 = 0x5A17E20261017
        func next(_ max: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed % UInt64(max))
        }
        let alphabet = [
            "a", "b", "甲", "👩‍👩‍👧", "é", "e\u{301}", " ", "\t", "\r", "\n",
            "\r\n", "\u{0085}", "\u{2028}", "\u{2029}", "_",
        ]
        func source() -> String {
            (0..<next(75)).map { _ in alphabet[next(alphabet.count)] }.joined()
        }
        func check(_ old: String, _ new: String, caseID: Int) {
            let core = DiffCore.compute(oldText: old, newText: new)
            let nativeOld = old as NSString
            let nativeNew = new as NSString
            for (value, lines, missingNewline) in [
                (old, core.oldLines, core.oldMissingNewline),
                (new, core.newLines, core.newMissingNewline)
            ] {
                let expected = value as NSString
                let text = lines.enumerated().map { index, line -> String in
                    XCTAssertEqual(expected.substring(with: line.utf16Range), String(line.text),
                                   "case \(caseID), line \(index)")
                    return String(line.text) + (index < lines.count - 1 ||
                        value.unicodeScalars.last == "\n" ? "\n" : "")
                }.joined()
                XCTAssertEqual(Data(text.utf8), Data(value.utf8), "case \(caseID)")
                _ = missingNewline
            }

            var oldCursor = 0
            var newCursor = 0
            for operation in core.ops {
                switch operation {
                case .equal(let oldStart, let newStart, let count):
                    XCTAssertEqual(oldStart, oldCursor, "old cursor case \(caseID)")
                    XCTAssertEqual(newStart, newCursor, "new cursor case \(caseID)")
                    for index in 0..<count {
                        XCTAssertTrue(core.oldLines[oldStart + index].text.utf8.elementsEqual(
                            core.newLines[newStart + index].text.utf8
                        ), "equal op must be byte-identical")
                    }
                    oldCursor += count
                    newCursor += count
                case .delete(let start, let count):
                    XCTAssertEqual(start, oldCursor, "delete case \(caseID)")
                    oldCursor += count
                case .insert(let start, let count):
                    XCTAssertEqual(start, newCursor, "insert case \(caseID)")
                    newCursor += count
                }
            }
            XCTAssertEqual(oldCursor, core.oldLines.count, "case \(caseID)")
            XCTAssertEqual(newCursor, core.newLines.count, "case \(caseID)")

            let display = DiffComputation.build(core: core, revealedLines: nil)
            XCTAssertEqual(display.splitLeft.rows.count, display.splitRight.rows.count)
            for document in [display.unified, display.splitLeft, display.splitRight] {
                let documentLines = DiffLineSplitter.lines(of: document.text).lines
                XCTAssertEqual(document.rows.count, documentLines.count, "case \(caseID)")
                XCTAssertEqual(document.lineStartOffsets.count, document.rows.count)
                for (index, row) in document.rows.enumerated() {
                    guard index < documentLines.count else { continue }
                    XCTAssertEqual(document.lineStartOffsets[index],
                                   documentLines[index].utf16Range.location)
                    let original: NSString
                    switch row.source {
                    case .old: original = nativeOld
                    case .new: original = nativeNew
                    case .none: continue
                    }
                    let source = row.sourceRange
                    XCTAssertLessThanOrEqual(source.location + source.length, original.length)
                    XCTAssertEqual(String(documentLines[index].text),
                                   original.substring(with: source),
                                   "rendered row differs at case \(caseID), row \(index)")
                    for emphasis in row.emphasis {
                        XCTAssertGreaterThanOrEqual(emphasis.location, 0)
                        XCTAssertLessThanOrEqual(emphasis.location + emphasis.length, source.length)
                    }
                }
            }
        }
        for caseID in 0..<500 {
            check(source(), source(), caseID: caseID)
        }
        let large = (0..<820).map { "same\($0)\n" }.joined()
        check(large, large.replacingOccurrences(of: "same", with: "changed"), caseID: 500)
        check(large, "first\n" + large + "last\n", caseID: 501)
    }

    func testGitWorktreeProjectionKeepsOneBaselineAcrossReviewAndEditing() throws {
        let old = "alpha\nold\nlast\n"
        let edited = "alpha\r\nnew\r\nlast\r\n"
        let oldOID = String(repeating: "a", count: 40)
        let newOID = String(repeating: "b", count: 40)
        let cleanCheckout = "alpha\r\nold\r\nlast\r\n"
        XCTAssertEqual(GitWorktreeComparison.resolve(
            old: old, worktree: cleanCheckout, patch: "",
            oldOID: oldOID, newOID: oldOID
        )?.old, cleanCheckout)
        let patch = """
        diff --git a/file b/file
        index \(oldOID)..\(newOID) 100644
        --- a/file
        +++ b/file
        @@ -2 +2 @@
        -old
        +new
        """
        let baseline = try XCTUnwrap(GitWorktreeComparison.resolve(
            old: old, worktree: edited, patch: patch,
            oldOID: oldOID, newOID: newOID
        )).old
        XCTAssertEqual(baseline, "alpha\r\nold\nlast\r\n")
        let expected: [DiffLineOp] = [
            .equal(oldStart: 0, newStart: 0, count: 1),
            .delete(oldStart: 1, count: 1),
            .insert(newStart: 1, count: 1),
            .equal(oldStart: 2, newStart: 2, count: 1),
        ]
        XCTAssertEqual(DiffCore.compute(oldText: baseline, newText: edited).ops, expected)
        XCTAssertEqual(DiffCore.compute(
            oldText: baseline, newText: "alpha\r\nnewer\r\nlast\r\n"
        ).ops, expected, "Editing must reuse the exact same comparison baseline")
        XCTAssertNil(GitWorktreeComparison.resolve(
            old: old, worktree: edited, patch: patch,
            oldOID: newOID, newOID: newOID
        ), "Changing the index between reads must not reinterpret the old blob")
        XCTAssertNil(GitWorktreeComparison.resolve(
            old: old, worktree: edited, patch: patch,
            oldOID: oldOID, newOID: oldOID
        ), "Changing the worktree between reads must not reinterpret the patch")
        XCTAssertEqual(old, "alpha\nold\nlast\n", "Original stored blob must stay untouched")
    }

    func testGitProjectionKeepsNonTextChangesAndCleanFilterEquivalence() throws {
        let old = "first\nsecond\n"
        let checkout = "first\r\nsecond\r\n"
        let oldOID = String(repeating: "a", count: 40)
        let newOID = String(repeating: "b", count: 40)
        let patch = """
        diff --git a/raw.txt b/raw.txt
        index \(oldOID)..\(newOID) 100644
        @@ -1,2 +1,2 @@
        -first
        -second
        +first
        +second
        """
        let baseline = try XCTUnwrap(GitWorktreeComparison.resolve(
            old: old, worktree: checkout, patch: patch,
            oldOID: oldOID, newOID: newOID
        )).old
        XCTAssertEqual(baseline, old, "-text does not normalize CRLF")
        let ops = DiffCore.compute(oldText: baseline, newText: checkout).ops
        XCTAssertEqual(ops.filter { if case .equal = $0 { false } else { true } }.count, 2)
        let filtered = "first\nTRANSIENT\nsecond\n"
        XCTAssertEqual(GitWorktreeComparison.resolve(
            old: old, worktree: filtered, patch: "",
            oldOID: oldOID, newOID: oldOID
        )?.old, filtered, "Git can clean entire lines without changing its stored blob")
        XCTAssertNil(GitWorktreeComparison.resolve(
            old: old, worktree: filtered, patch: "",
            oldOID: oldOID, newOID: newOID
        ))
        XCTAssertNil(GitWorktreeComparison.resolve(
            old: old, worktree: checkout,
            patch: "diff --git a/a b/a\ndiff --git a/b b/b\n",
            oldOID: oldOID, newOID: newOID
        ))
        let noninvertible = """
        diff --git a/file b/file
        index \(oldOID)..\(newOID) 100644
        @@ -1 +1 @@
        -first
        +cleaned first
        """
        let canonical = try XCTUnwrap(GitWorktreeComparison.resolve(
            old: old, worktree: old, patch: noninvertible,
            oldOID: oldOID, newOID: newOID
        ))
        XCTAssertEqual(canonical.old, old)
        XCTAssertEqual(canonical.new, "cleaned first\nsecond\n")
        XCTAssertEqual(canonical.editBaseline, old,
                       "Filtered Review must not silently change what Edit saves")
    }

    func testGitCanonicalReviewPatchHandlesMultipleHunksUnicodeAndNoFinalNewline() throws {
        let old = "first\nmiddle\nlast"
        let raw = "甲\nTRANSIENT\nmiddle\n乙"
        let oldOID = String(repeating: "a", count: 40)
        let newOID = String(repeating: "b", count: 40)
        let patch = """
        diff --git a/x b/x
        index \(oldOID)..\(newOID) 100644
        --- a/x
        +++ b/x
        @@ -1 +1 @@
        -first
        +甲
        @@ -3 +3 @@
        -last
        \\ No newline at end of file
        +乙
        \\ No newline at end of file
        """
        let result = try XCTUnwrap(GitWorktreeComparison.resolve(
            old: old, worktree: raw, patch: patch,
            oldOID: oldOID, newOID: newOID
        ))
        XCTAssertEqual(result.old, old)
        XCTAssertEqual(result.new, "甲\nmiddle\n乙")
        XCTAssertEqual(result.editBaseline, raw)
        XCTAssertEqual(DiffCore.compute(oldText: result.old, newText: result.new)
            .ops.filter { if case .equal = $0 { false } else { true } }.count, 4)
    }

    func testGitCanonicalReviewHandlesCompleteDeletionWithoutVirtualNewline() throws {
        let oldOID = String(repeating: "a", count: 40)
        let patch = """
        diff --git a/file b/file
        deleted file mode 100644
        index \(oldOID)..\(String(repeating: "0", count: 40))
        --- a/file
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        """
        let content = try XCTUnwrap(GitWorktreeComparison.resolve(
            old: "gone\n", worktree: "", patch: patch,
            oldOID: oldOID, newOID: String(repeating: "b", count: 40)
        ))
        XCTAssertEqual(content.old, "gone\n")
        XCTAssertEqual(content.new, "", "Deleting the last line must not invent a trailing blank row")
        XCTAssertEqual(DiffCore.compute(oldText: content.old, newText: content.new)
            .ops.filter { if case .delete = $0 { true } else { false } }.count, 1)
    }

    func testGitModeOnlyPatchNeedsNoContentFallback() throws {
        let oid = String(repeating: "c", count: 40)
        let raw = "unchanged\r\n"
        let patch = """
        diff --git a/a.txt b/a.txt
        old mode 100644
        new mode 100755
        """
        let result = try XCTUnwrap(GitWorktreeComparison.resolve(
            old: "unchanged\n", worktree: raw, patch: patch,
            oldOID: oid, newOID: oid
        ))
        XCTAssertEqual(result.old, raw)
        XCTAssertEqual(result.new, raw)
        XCTAssertNil(result.editBaseline)
    }

    func testBinaryPatchMarkersInsideAddedTextDoNotRejectOrdinaryDiff() throws {
        let oldOID = String(repeating: "a", count: 40)
        let newOID = String(repeating: "b", count: 40)
        let actual = "Binary files a/x and b/x differ\nGIT binary patch\n"
        let patch = """
        diff --git a/x b/x
        index \(oldOID)..\(newOID) 100644
        --- a/x
        +++ b/x
        @@ -1 +1,2 @@
        -before
        +Binary files a/x and b/x differ
        +GIT binary patch
        """
        let content = try XCTUnwrap(GitWorktreeComparison.resolve(
            old: "before\n", worktree: actual, patch: patch,
            oldOID: oldOID, newOID: newOID
        ))
        XCTAssertEqual(content.old, "before\n")
        XCTAssertEqual(content.new, actual)
        XCTAssertNil(content.editBaseline)
        XCTAssertNil(GitWorktreeComparison.resolve(
            old: "before\n", worktree: actual,
            patch: "diff --git a/x b/x\nindex \(oldOID)..\(newOID) 100644\n"
                + "Binary files a/x and b/x differ\n",
            oldOID: oldOID, newOID: newOID
        ), "Actual binary metadata must still be rejected")
    }

    func testLargeRepeatedShiftStillProducesMinimalLineDiff() {
        let old = (0..<800).map { $0.isMultiple(of: 2) ? "A" : "B" }.joined(separator: "\n") + "\n"
        let new = (0..<800).map { $0.isMultiple(of: 2) ? "B" : "A" }.joined(separator: "\n") + "\n"
        let ops = DiffCore.compute(oldText: old, newText: new).ops
        let deleted = ops.reduce(0) { result, op in
            if case .delete(_, let count) = op { return result + count }
            return result
        }
        let inserted = ops.reduce(0) { result, op in
            if case .insert(_, let count) = op { return result + count }
            return result
        }
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(inserted, 1)
    }

    func testLFAndCRLFHaveExactUTF16OffsetsWithoutChangingOriginalBytes() {
        let value = "甲\r\nB👋\nC\rD\r\n"
        let result = DiffLineSplitter.lines(of: value)
        XCTAssertEqual(result.lines.map { String($0.text) }, ["甲\r", "B👋", "C\rD\r"])
        XCTAssertEqual(result.lines.map(\.utf16Range), [
            NSRange(location: 0, length: 2),
            NSRange(location: 3, length: 3),
            NSRange(location: 7, length: 4),
        ])
        XCTAssertTrue(result.hasTrailingNewline)
        XCTAssertEqual(DiffLineSplitter.lines(of: "").lines.count, 0)
        XCTAssertFalse(DiffLineSplitter.lines(of: "").hasTrailingNewline)
        XCTAssertEqual(DiffLineSplitter.lines(of: "\r").lines.map { String($0.text) }, ["\r"])
        XCTAssertFalse(DiffLineSplitter.lines(of: "\r").hasTrailingNewline)
        XCTAssertEqual(DiffLineSplitter.lines(of: "\n").lines.map { String($0.text) }, [""])
        XCTAssertTrue(DiffLineSplitter.lines(of: "\n").hasTrailingNewline)
    }

    func testCRLFLineDiffReconstructsOriginalBytesAndNativeRowNumbers() {
        let pairs = [
            ("", "\r\n"),
            ("a\r\nb\n", "a\r\nc\n"),
            ("x\r\ny\r\n", "x\r\nz\r\n"),
            ("x\r\n", "x\r"),
            ("中文👋\r\nlet café = 1\n", "中文👋\r\nlet cafe\u{301} = 1\n"),
            ("A\rB\nC\r\n", "A\rB\nD\r\n"),
        ]
        for (old, new) in pairs {
            let core = DiffCore.compute(oldText: old, newText: new)
            var oldIndexes: [Int] = []
            var newIndexes: [Int] = []
            for op in core.ops {
                switch op {
                case .equal(let a, let b, let count):
                    oldIndexes.append(contentsOf: a..<(a + count))
                    newIndexes.append(contentsOf: b..<(b + count))
                case .delete(let start, let count):
                    oldIndexes.append(contentsOf: start..<(start + count))
                case .insert(let start, let count):
                    newIndexes.append(contentsOf: start..<(start + count))
                }
            }
            func originalBytes(_ lines: [DiffSourceLine], _ indexes: [Int], _ trailing: Bool) -> Data {
                var result = Data()
                for i in indexes {
                    result.append(contentsOf: lines[i].text.utf8)
                    if i != lines.count - 1 || trailing { result.append(10) }
                }
                return result
            }
            XCTAssertEqual(oldIndexes, Array(core.oldLines.indices), "old \(old.debugDescription)")
            XCTAssertEqual(newIndexes, Array(core.newLines.indices), "new \(new.debugDescription)")
            XCTAssertEqual(originalBytes(core.oldLines, oldIndexes, old.unicodeScalars.last == "\n"), Data(old.utf8))
            XCTAssertEqual(originalBytes(core.newLines, newIndexes, new.unicodeScalars.last == "\n"), Data(new.utf8))
        }

        let diff = DiffComputation.compute(oldText: "one\r\nold\r\nlast\n", newText: "one\r\nnew\r\nlast\n")
        XCTAssertEqual(diff.unified.rows.compactMap(\.oldLine), [1, 2, 3])
        XCTAssertEqual(diff.unified.rows.compactMap(\.newLine), [1, 2, 3])
        XCTAssertEqual(diff.splitLeft.rows.count, diff.splitRight.rows.count)
        XCTAssertEqual(diff.unified.rows.count, diff.unified.lineStartOffsets.count)
        XCTAssertNotEqual((diff.unified.text as NSString).range(of: "old\r").location, NSNotFound)
        XCTAssertNotEqual((diff.unified.text as NSString).range(of: "new\r").location, NSNotFound)
    }

    func testSyntheticNativeReviewTerminatesTheFinalCRLFRow() {
        let before = "old\r\n"
        let after = "new\r\n"
        let computation = DiffComputation.compute(oldText: before, newText: after)
        XCTAssertTrue(computation.unified.text.hasSuffix("new\r\n"))
        XCTAssertTrue(computation.splitRight.text.hasSuffix("new\r\n"))
        XCTAssertEqual(DiffLineSplitter.lines(of: after).lines.map { String($0.text) }, ["new\r"])
    }

    func testCanonicalEquivalentLinesRemainByteDifferentAndReconstructBothSides() {
        let old = "prefix\nlet café = 1\nsuffix\n"
        let new = "prefix\nlet cafe\u{301} = 1\nsuffix\n"
        let core = DiffCore.compute(oldText: old, newText: new)
        var reconstructedOld = Data()
        var reconstructedNew = Data()
        var changed = false
        for operation in core.ops {
            switch operation {
            case .equal(let oldStart, let newStart, let count):
                for offset in 0..<count {
                    let before = Data(core.oldLines[oldStart + offset].text.utf8)
                    let after = Data(core.newLines[newStart + offset].text.utf8)
                    XCTAssertEqual(before, after)
                    reconstructedOld.append(before + Data([10]))
                    reconstructedNew.append(before + Data([10]))
                }
            case .delete(let start, let count):
                changed = true
                for line in core.oldLines[start..<(start + count)] {
                    reconstructedOld.append(contentsOf: line.text.utf8)
                    reconstructedOld.append(10)
                }
            case .insert(let start, let count):
                changed = true
                for line in core.newLines[start..<(start + count)] {
                    reconstructedNew.append(contentsOf: line.text.utf8)
                    reconstructedNew.append(10)
                }
            }
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(reconstructedOld, Data(old.utf8))
        XCTAssertEqual(reconstructedNew, Data(new.utf8))
        XCTAssertEqual(core.oldLines[1].utf16Range, NSRange(location: 7, length: 12))
        XCTAssertEqual(core.newLines[1].utf16Range, NSRange(location: 7, length: 13))
        let identical = DiffCore.compute(oldText: new, newText: new)
        XCTAssertEqual(identical.ops, [.equal(oldStart: 0, newStart: 0, count: 3)])
    }

    func testCanonicalEquivalentTokensHaveExactUTF16Emphasis() throws {
        let result = try XCTUnwrap(DiffIntraline.diff(old: "let café = 1", new: "let cafe\u{301} = 1"))
        XCTAssertEqual(result.oldRanges, [NSRange(location: 4, length: 4)])
        XCTAssertEqual(result.newRanges, [NSRange(location: 4, length: 5)])
        XCTAssertNil(DiffIntraline.diff(old: "中文👋", new: "中文👋"))
    }
}
