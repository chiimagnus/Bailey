//  Native diff computation for the diff viewer: line-level diff, word-level
//  intraline highlights, and the row/document models the NSTextView-based
//  viewer renders. Everything here is pure and nonisolated so a diff can be
//  computed off the main actor.
//

import Foundation

// MARK: - Line model

/// One line of a file, sliced out of the original string without copying.
/// `utf16Range` addresses the line's content (no terminator) in the source
/// string, so highlight runs computed against the whole file can be re-based
/// onto diff documents.
nonisolated struct DiffSourceLine {
    let text: Substring
    let utf16Range: NSRange
}

nonisolated enum DiffLineSplitter {
    /// Splits on `\n` only (git content normalizes nothing; a `\r` stays part
    /// of the line and renders as-is, matching `git diff`). A trailing
    /// newline's phantom empty last component is dropped — it is a terminator,
    /// not a line. `hasTrailingNewline` preserves the distinction so callers
    /// can still detect "\ No newline at end of file" changes.
    static func lines(of text: String) -> (lines: [DiffSourceLine], hasTrailingNewline: Bool) {
        var lines: [DiffSourceLine] = []
        var lineStart = text.startIndex
        var utf16Offset = 0
        // CRLF is one Swift Character but two Unicode scalars. Git splits at
        // the LF code point; retain the CR and the original UTF-16 offsets.
        let scalars = text.unicodeScalars
        let end = scalars.endIndex
        var index = scalars.startIndex
        while index < end {
            if scalars[index] == "\n" {
                let content = text[lineStart..<index]
                let length = content.utf16.count
                lines.append(DiffSourceLine(
                    text: content,
                    utf16Range: NSRange(location: utf16Offset, length: length)
                ))
                utf16Offset += length + 1
                index = scalars.index(after: index)
                lineStart = index
            } else {
                index = scalars.index(after: index)
            }
        }
        let hasTrailingNewline = !text.isEmpty && lineStart == end
        if !hasTrailingNewline && !text.isEmpty {
            let content = text[lineStart..<end]
            lines.append(DiffSourceLine(
                text: content,
                utf16Range: NSRange(location: utf16Offset, length: content.utf16.count)
            ))
        }
        return (lines, hasTrailingNewline)
    }
}

/// Git determines which lines change; the editor retains raw worktree bytes.
/// Only use raw Review coordinates when its lines match Git's cleaned content.
nonisolated enum GitWorktreeComparison {
    nonisolated struct Content {
        let old: String
        let new: String
        /// When a clean filter changes line structure, live editing compares
        /// against the raw buffer captured at load rather than Git's blob.
        let editBaseline: String?
        /// Verified Git hunk coordinates, reusable for the first display snapshot.
        var operations: [DiffLineOp]? = nil
    }

    static func resolve(
        old: String, worktree: String, patch: String,
        oldOID: String, newOID: String
    ) -> Content? {
        let (oldLines, oldTrailing) = DiffLineSplitter.lines(of: old)
        let (rawLines, rawTrailing) = DiffLineSplitter.lines(of: worktree)
        if patch.isEmpty {
            return oldOID == newOID
                ? Content(old: worktree, new: worktree, editBaseline: nil)
                : nil
        }

        var files = 0
        var hunks = 0
        var pair: (String, String)?
        var oldCursor = 0
        var newCursor = 0
        var oldRemaining = 0
        var newRemaining = 0
        var projected = oldLines.map { String($0.text) }
        var canonical: [String] = []
        var lastChangedOldEnd = 0
        var newTrailing = oldTrailing
        var operations = DiffEngine.OpsBuilder()
        var lastKind: Character?

        func coordinate(_ token: Substring, prefix: Character) -> (start: Int, count: Int)? {
            guard token.first == prefix else { return nil }
            let parts = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count),
                  let start = Int(parts[0]), start >= 0,
                  let count = parts.count == 2 ? Int(parts[1]) : 1,
                  count >= 0, (count == 0 || start > 0) else { return nil }
            return (count == 0 ? start : start - 1, count)
        }

        func unchanged(until oldEnd: Int, newEnd: Int) -> Bool {
            guard oldEnd >= oldCursor, oldEnd <= oldLines.count,
                  newEnd >= newCursor,
                  oldEnd - oldCursor == newEnd - newCursor else { return false }
            operations.equal(oldStart: oldCursor, newStart: newCursor,
                             count: oldEnd - oldCursor)
            for offset in 0..<(oldEnd - oldCursor) {
                canonical.append(String(oldLines[oldCursor + offset].text))
                if newCursor + offset < rawLines.count {
                    projected[oldCursor + offset] = String(rawLines[newCursor + offset].text)
                }
            }
            oldCursor = oldEnd
            newCursor = newEnd
            return true
        }

        for entry in DiffLineSplitter.lines(of: patch).lines {
            let line = entry.text
            if line.hasPrefix("diff --git ") {
                files += 1
                guard files == 1 else { return nil }
            } else if line.hasPrefix("index ") {
                let ids = line.dropFirst(6).split(separator: " ").first?
                    .components(separatedBy: "..")
                guard let ids, ids.count == 2 else { return nil }
                pair = (ids[0], ids[1])
            } else if hunks == 0,
                      line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                return nil
            } else if line.hasPrefix("@@ -") {
                guard oldRemaining == 0, newRemaining == 0 else { return nil }
                let parts = line.split(separator: " ", maxSplits: 3)
                guard parts.count >= 3, parts[0] == "@@",
                      let before = coordinate(parts[1], prefix: "-"),
                      let after = coordinate(parts[2], prefix: "+"),
                      unchanged(until: before.start, newEnd: after.start),
                      before.start + before.count <= oldLines.count else { return nil }
                hunks += 1
                oldRemaining = before.count
                newRemaining = after.count
                lastChangedOldEnd = before.start + before.count
                if lastChangedOldEnd == oldLines.count { newTrailing = true }
                lastKind = nil
            } else if hunks > 0, let kind = line.first, kind == "-" || kind == "+" || kind == " " {
                let content = String(line.dropFirst())
                switch kind {
                case "-":
                    guard oldRemaining > 0, oldCursor < oldLines.count,
                          oldLines[oldCursor].text == content else { return nil }
                    operations.delete(oldStart: oldCursor, count: 1)
                    oldCursor += 1
                    oldRemaining -= 1
                case "+":
                    guard newRemaining > 0 else { return nil }
                    operations.insert(newStart: newCursor, count: 1)
                    canonical.append(content)
                    newCursor += 1
                    newRemaining -= 1
                default:
                    guard oldRemaining > 0, newRemaining > 0,
                          oldCursor < oldLines.count,
                          oldLines[oldCursor].text == content else { return nil }
                    operations.equal(oldStart: oldCursor, newStart: newCursor, count: 1)
                    canonical.append(content)
                    oldCursor += 1
                    newCursor += 1
                    oldRemaining -= 1
                    newRemaining -= 1
                }
                lastKind = kind
            } else if line.hasPrefix("\\ No newline at end of file") {
                if lastKind == "+" || lastKind == " " { newTrailing = false }
            } else if !line.isEmpty, hunks > 0 {
                // Git itself produced the patch; unknown output must never be
                // mistaken for an unchanged line.
                return nil
            }
        }
        if files == 1, hunks == 0, oldOID == newOID,
           pair == nil || (pair?.0 == oldOID && pair?.1 == newOID) {
            // A mode-only patch carries no text changes.
            return Content(old: worktree, new: worktree, editBaseline: nil)
        }
        guard files == 1, hunks > 0, oldRemaining == 0, newRemaining == 0,
              let pair, pair.0 == oldOID,
              pair.1 == newOID || (worktree.isEmpty && pair.1.allSatisfy { $0 == "0" }),
              unchanged(until: oldLines.count,
                        newEnd: newCursor + oldLines.count - oldCursor) else { return nil }

        let canonicalNew = canonical.joined(separator: "\n")
            + (!canonical.isEmpty && newTrailing ? "\n" : "")
        let projectedTrailing = lastChangedOldEnd < oldLines.count ? rawTrailing : oldTrailing
        let projectedOld = projected.joined(separator: "\n") + (projectedTrailing ? "\n" : "")
        let (cleanedLines, cleanedTrailing) = DiffLineSplitter.lines(of: canonicalNew)
        let rawMatchesGit = rawTrailing == cleanedTrailing && rawLines.count == cleanedLines.count
            && zip(rawLines, cleanedLines).allSatisfy { raw, cleaned in
                raw.text == cleaned.text || raw.text == String(cleaned.text) + "\r"
            }
        if rawMatchesGit && !projectedOld.utf8.elementsEqual(worktree.utf8) {
            return Content(old: projectedOld, new: worktree, editBaseline: nil,
                           operations: operations.finish())
        }
        // Clean filters are not generally invertible (they can erase lines).
        // Render the two canonical sides Git compared; edit the raw file.
        return Content(old: old, new: canonicalNew, editBaseline: worktree,
                       operations: operations.finish())
    }
}

// MARK: - Line diff

/// A run of consecutive lines with one fate. Offsets index the line arrays.
nonisolated enum DiffLineOp: Equatable {
    case equal(oldStart: Int, newStart: Int, count: Int)
    case delete(oldStart: Int, count: Int)
    case insert(newStart: Int, count: Int)
}

/// Line-level diff tuned for real-world source files:
///
/// 1. Common prefix/suffix trimming — the dominant case (a small edit in a
///    large file) collapses to a tiny middle region.
/// 2. Patience anchoring — lines unique to both sides pin the alignment, then
///    each gap recurses. Bounded and fast even when the middle is huge (e.g.
///    a regenerated lockfile), and it produces the readable, structure-aware
///    splits patience diff is known for.
/// 3. Exact Myers for small gaps, and bounded Myers for large gaps with
///    few changes. Repeated equal-length regions retain confirmed aligned
///    runs; only unresolved large gaps become replace blocks.
nonisolated enum DiffEngine {
    /// Large repeated regions still get precise matches when edit distance
    /// is small, without allowing unbounded quadratic work.
    private static let myersLimit = 700
    private static let largeGapEditLimit = 96

    static func lineOps(old: [DiffSourceLine], new: [DiffSourceLine]) -> [DiffLineOp] {
        // Only cancellation can throw; this synchronous API cannot cancel.
        do {
            return try computeLineOps(old: old, new: new, cancellation: { false })
        } catch {
            preconditionFailure("Non-cancellable diff unexpectedly aborted: \(error)")
        }
    }

    static func lineOpsIfActive(
        old: [DiffSourceLine], new: [DiffSourceLine], cancellation: @escaping () -> Bool
    ) -> [DiffLineOp]? {
        // CancellationError is the only thrown error; no partial ops escape.
        try? computeLineOps(old: old, new: new, cancellation: cancellation)
    }

    private static func computeLineOps(
        old: [DiffSourceLine], new: [DiffSourceLine], cancellation: @escaping () -> Bool
    ) throws -> [DiffLineOp] {
        guard !cancellation() else { throw CancellationError() }
        var builder = OpsBuilder()
        // Hash once: line equality during the diff is then integer comparison
        // with a rare full-text confirmation on hash collisions.
        let oldHashes = try hashes(for: old, cancellation: cancellation)
        let newHashes = try hashes(for: new, cancellation: cancellation)
        let oldTexts = old.map(\.text)
        let newTexts = new.map(\.text)
        let context = Context(
            oldHashes: oldHashes, newHashes: newHashes,
            oldTexts: oldTexts, newTexts: newTexts, cancellation: cancellation
        )
        try diffRegion(
            context, old: 0..<old.count, new: 0..<new.count, into: &builder
        )
        try context.checkCancellation()
        let ops = builder.finish()
        #if DEBUG
        assertReconstructs(ops: ops, oldCount: old.count, newCount: new.count)
        #endif
        return ops
    }

    private static func hashes(
        for lines: [DiffSourceLine], cancellation: () -> Bool
    ) throws -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if index.isMultiple(of: 256), cancellation() { throw CancellationError() }
            result.append(line.text.hashValue)
        }
        return result
    }

    private struct Context {
        let oldHashes: [Int]
        let newHashes: [Int]
        let oldTexts: [Substring]
        let newTexts: [Substring]
        let cancellation: () -> Bool

        func checkCancellation() throws {
            if cancellation() { throw CancellationError() }
        }

        func linesEqual(_ oldIndex: Int, _ newIndex: Int) -> Bool {
            oldHashes[oldIndex] == newHashes[newIndex]
                && oldTexts[oldIndex].utf8.elementsEqual(newTexts[newIndex].utf8)
        }
    }

    /// Accumulates ops while merging adjacent runs of the same kind, so the
    /// recursive splits can emit freely.
    fileprivate struct OpsBuilder {
        private var ops: [DiffLineOp] = []

        mutating func equal(oldStart: Int, newStart: Int, count: Int) {
            guard count > 0 else { return }
            if case .equal(let o, let n, let c) = ops.last,
               o + c == oldStart, n + c == newStart {
                ops[ops.count - 1] = .equal(oldStart: o, newStart: n, count: c + count)
            } else {
                ops.append(.equal(oldStart: oldStart, newStart: newStart, count: count))
            }
        }

        mutating func delete(oldStart: Int, count: Int) {
            guard count > 0 else { return }
            if case .delete(let o, let c) = ops.last, o + c == oldStart {
                ops[ops.count - 1] = .delete(oldStart: o, count: c + count)
            } else {
                ops.append(.delete(oldStart: oldStart, count: count))
            }
        }

        mutating func insert(newStart: Int, count: Int) {
            guard count > 0 else { return }
            if case .insert(let n, let c) = ops.last, n + c == newStart {
                ops[ops.count - 1] = .insert(newStart: n, count: c + count)
            } else {
                ops.append(.insert(newStart: newStart, count: count))
            }
        }

        /// Reorders each changed block to deletes-then-inserts (the shape the
        /// viewer renders) without moving blocks across equal runs.
        func finish() -> [DiffLineOp] {
            var result: [DiffLineOp] = []
            result.reserveCapacity(ops.count)
            var pendingInserts: [DiffLineOp] = []
            for op in ops {
                switch op {
                case .equal:
                    result.append(contentsOf: pendingInserts)
                    pendingInserts.removeAll(keepingCapacity: true)
                    result.append(op)
                case .delete:
                    result.append(op)
                case .insert:
                    pendingInserts.append(op)
                }
            }
            result.append(contentsOf: pendingInserts)
            return result
        }
    }

    private static func diffRegion(
        _ context: Context, old: Range<Int>, new: Range<Int>, into builder: inout OpsBuilder
    ) throws {
        try context.checkCancellation()
        var old = old
        var new = new

        // Common prefix.
        var prefixCount = 0
        while prefixCount < old.count, prefixCount < new.count,
              context.linesEqual(old.lowerBound + prefixCount, new.lowerBound + prefixCount) {
            if prefixCount.isMultiple(of: 256) { try context.checkCancellation() }
            prefixCount += 1
        }
        if prefixCount > 0 {
            builder.equal(oldStart: old.lowerBound, newStart: new.lowerBound, count: prefixCount)
            old = (old.lowerBound + prefixCount)..<old.upperBound
            new = (new.lowerBound + prefixCount)..<new.upperBound
        }

        // Common suffix. Emitted only after the middle is diffed, to keep
        // output ordered.
        var suffixCount = 0
        while suffixCount < old.count, suffixCount < new.count,
              context.linesEqual(old.upperBound - 1 - suffixCount, new.upperBound - 1 - suffixCount) {
            if suffixCount.isMultiple(of: 256) { try context.checkCancellation() }
            suffixCount += 1
        }
        let suffixOldStart = old.upperBound - suffixCount
        let suffixNewStart = new.upperBound - suffixCount
        old = old.lowerBound..<suffixOldStart
        new = new.lowerBound..<suffixNewStart

        defer {
            builder.equal(oldStart: suffixOldStart, newStart: suffixNewStart, count: suffixCount)
        }

        if old.isEmpty && new.isEmpty {
            return
        }
        if old.isEmpty {
            builder.insert(newStart: new.lowerBound, count: new.count)
            return
        }
        if new.isEmpty {
            builder.delete(oldStart: old.lowerBound, count: old.count)
            return
        }

        let smallGap = old.count <= myersLimit && new.count <= myersLimit
        if try myersDiff(context, old: old, new: new,
                         editLimit: smallGap ? old.count + new.count : largeGapEditLimit,
                         into: &builder) {
            return
        }

        let anchors = try patienceAnchors(context, old: old, new: new)
        guard !anchors.isEmpty else {
            // Repeated lines have no unique patience anchor. Preserve proven
            // aligned runs instead of painting every unchanged row as replaced.
            if try alignedEqualRuns(context, old: old, new: new, into: &builder) {
                return
            }
            builder.delete(oldStart: old.lowerBound, count: old.count)
            builder.insert(newStart: new.lowerBound, count: new.count)
            return
        }

        var oldCursor = old.lowerBound
        var newCursor = new.lowerBound
        for anchor in anchors {
            try diffRegion(
                context,
                old: oldCursor..<anchor.oldIndex,
                new: newCursor..<anchor.newIndex,
                into: &builder
            )
            builder.equal(oldStart: anchor.oldIndex, newStart: anchor.newIndex, count: 1)
            oldCursor = anchor.oldIndex + 1
            newCursor = anchor.newIndex + 1
        }
        try diffRegion(
            context, old: oldCursor..<old.upperBound, new: newCursor..<new.upperBound, into: &builder
        )
    }

    /// Repeated rows can be common without ever being unique. An equal-length
    /// gap with sufficiently long byte-confirmed same-position runs can be
    /// partitioned without inventing shifted matches or crossing any hunk.
    /// Changed gaps are still resolved by the existing exact/bounded algorithm.
    private static func alignedEqualRuns(
        _ context: Context, old: Range<Int>, new: Range<Int>,
        into builder: inout OpsBuilder
    ) throws -> Bool {
        guard old.count == new.count, old.count >= 16 else { return false }
        let minimumRun = 8
        var consecutive = 0
        var found = false
        for offset in 0..<old.count {
            if offset.isMultiple(of: 256) { try context.checkCancellation() }
            if context.linesEqual(old.lowerBound + offset, new.lowerBound + offset) {
                consecutive += 1
                if consecutive == minimumRun {
                    found = true
                    break
                }
            } else {
                consecutive = 0
            }
        }
        guard found else { return false }

        var cursor = 0
        var offset = 0
        while offset < old.count {
            if offset.isMultiple(of: 256) { try context.checkCancellation() }
            guard context.linesEqual(old.lowerBound + offset, new.lowerBound + offset) else {
                offset += 1
                continue
            }
            let start = offset
            repeat {
                offset += 1
                if offset.isMultiple(of: 256) { try context.checkCancellation() }
            } while offset < old.count
                && context.linesEqual(old.lowerBound + offset, new.lowerBound + offset)
            guard offset - start >= minimumRun else { continue }
            try diffRegion(
                context,
                old: (old.lowerBound + cursor)..<(old.lowerBound + start),
                new: (new.lowerBound + cursor)..<(new.lowerBound + start),
                into: &builder
            )
            builder.equal(oldStart: old.lowerBound + start,
                          newStart: new.lowerBound + start, count: offset - start)
            cursor = offset
        }
        try diffRegion(
            context, old: (old.lowerBound + cursor)..<old.upperBound,
            new: (new.lowerBound + cursor)..<new.upperBound, into: &builder
        )
        return true
    }

    // MARK: Patience anchors

    private struct Anchor {
        let oldIndex: Int
        let newIndex: Int
    }

    /// Lines that appear exactly once on each side, matched up, then reduced
    /// to their longest increasing subsequence so the anchors are mutually
    /// consistent.
    private static func patienceAnchors(
        _ context: Context, old: Range<Int>, new: Range<Int>
    ) throws -> [Anchor] {
        struct Occurrence {
            var oldIndex = -1
            var oldCount = 0
            var newIndex = -1
            var newCount = 0
        }
        // Keyed by hash; a collision can merge two distinct lines and either
        // inflate a count (anchor discarded — harmless) or pair different
        // lines, so candidate pairs are text-confirmed below.
        var table: [Int: Occurrence] = [:]
        table.reserveCapacity(min(old.count + new.count, 4096))
        for index in old {
            if index.isMultiple(of: 256) { try context.checkCancellation() }
            table[context.oldHashes[index], default: Occurrence()].oldCount += 1
            table[context.oldHashes[index]]?.oldIndex = index
        }
        for index in new {
            if index.isMultiple(of: 256) { try context.checkCancellation() }
            table[context.newHashes[index], default: Occurrence()].newCount += 1
            table[context.newHashes[index]]?.newIndex = index
        }

        var candidates: [Anchor] = []
        for (index, occurrence) in table.values.enumerated() {
            if index.isMultiple(of: 256) { try context.checkCancellation() }
            guard occurrence.oldCount == 1, occurrence.newCount == 1,
                  context.linesEqual(occurrence.oldIndex, occurrence.newIndex)
            else { continue }
            candidates.append(Anchor(oldIndex: occurrence.oldIndex, newIndex: occurrence.newIndex))
        }
        candidates.sort { $0.oldIndex < $1.oldIndex }
        guard !candidates.isEmpty else { return [] }

        // Longest increasing subsequence by newIndex (patience sorting).
        var pileTops: [Int] = [] // candidate index of the top of each pile
        var previous = [Int](repeating: -1, count: candidates.count)
        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: 256) { try context.checkCancellation() }
            var lo = 0
            var hi = pileTops.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if candidates[pileTops[mid]].newIndex < candidate.newIndex {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            if lo > 0 {
                previous[index] = pileTops[lo - 1]
            }
            if lo == pileTops.count {
                pileTops.append(index)
            } else {
                pileTops[lo] = index
            }
        }

        var chain: [Anchor] = []
        var cursor = pileTops.last ?? -1
        while cursor >= 0 {
            chain.append(candidates[cursor])
            cursor = previous[cursor]
        }
        return chain.reversed()
    }

    // MARK: Myers

    /// Exact Myers within a bounded edit-distance budget.
    private static func myersDiff(
        _ context: Context, old: Range<Int>, new: Range<Int>,
        editLimit: Int, into builder: inout OpsBuilder
    ) throws -> Bool {
        let n = old.count
        let m = new.count
        let maxD = min(n + m, editLimit)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []

        var foundD = -1
        outer: for d in 0...maxD {
            try context.checkCancellation()
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    x = v[k + 1 + offset] // down: insert
                } else {
                    x = v[k - 1 + offset] + 1 // right: delete
                }
                var y = x - k
                while x < n, y < m,
                      context.linesEqual(old.lowerBound + x, new.lowerBound + y) {
                    if x.isMultiple(of: 256) { try context.checkCancellation() }
                    x += 1
                    y += 1
                }
                v[k + offset] = x
                if x >= n, y >= m {
                    foundD = d
                    break outer
                }
                k += 2
            }
        }
        guard foundD >= 0 else { return false }

        // Backtrack from (n, m) to (0, 0), collecting steps in reverse.
        enum Step { case equalOne, deleteOne, insertOne }
        var steps: [Step] = []
        var x = n
        var y = m
        var d = foundD
        while d > 0 {
            let vPrev = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vPrev[k - 1 + offset] < vPrev[k + 1 + offset]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = vPrev[prevK + offset]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                steps.append(.equalOne)
                x -= 1
                y -= 1
            }
            if x == prevX {
                steps.append(.insertOne)
                y -= 1
            } else {
                steps.append(.deleteOne)
                x -= 1
            }
            d -= 1
        }
        while x > 0, y > 0 {
            steps.append(.equalOne)
            x -= 1
            y -= 1
        }
        while x > 0 {
            steps.append(.deleteOne)
            x -= 1
        }
        while y > 0 {
            steps.append(.insertOne)
            y -= 1
        }

        var oldCursor = old.lowerBound
        var newCursor = new.lowerBound
        for step in steps.reversed() {
            switch step {
            case .equalOne:
                builder.equal(oldStart: oldCursor, newStart: newCursor, count: 1)
                oldCursor += 1
                newCursor += 1
            case .deleteOne:
                builder.delete(oldStart: oldCursor, count: 1)
                oldCursor += 1
            case .insertOne:
                builder.insert(newStart: newCursor, count: 1)
                newCursor += 1
            }
        }
        return true
    }

    #if DEBUG
    /// The one invariant every correct line diff satisfies: walking the ops
    /// consumes both sides exactly once, in order.
    private static func assertReconstructs(ops: [DiffLineOp], oldCount: Int, newCount: Int) {
        var oldCovered = 0
        var newCovered = 0
        for op in ops {
            switch op {
            case .equal(let oldStart, let newStart, let count):
                assert(oldStart == oldCovered && newStart == newCovered, "equal op out of order")
                oldCovered += count
                newCovered += count
            case .delete(let oldStart, let count):
                assert(oldStart == oldCovered, "delete op out of order")
                oldCovered += count
            case .insert(let newStart, let count):
                assert(newStart == newCovered, "insert op out of order")
                newCovered += count
            }
        }
        assert(oldCovered == oldCount && newCovered == newCount, "diff does not cover both files")
    }
    #endif
}

// MARK: - Intraline (word-level) diff

/// Character ranges (relative to each line's own content) that differ within
/// a paired removed/added line.
nonisolated struct DiffIntralineResult {
    var oldRanges: [NSRange]
    var newRanges: [NSRange]
}

nonisolated enum DiffIntraline {
    /// Lines longer than this (in tokens) skip word diffing: the pairing is
    /// almost certainly generated content where per-word emphasis is noise.
    private static let tokenLimit = 400
    /// If more than this fraction of both lines changed, the pair reads as a
    /// rewrite; per-word emphasis would highlight nearly everything.
    private static let noiseThreshold = 0.66

    /// A token is a run of alphanumerics (plus `_`), a run of spaces/tabs, or
    /// a single other character. Ranges are UTF-16, line-relative.
    private static func tokenize(_ line: Substring) -> [(text: Substring, range: NSRange)] {
        var tokens: [(Substring, NSRange)] = []
        var utf16Offset = 0
        var index = line.startIndex

        func kind(_ character: Character) -> Int {
            if character.isLetter || character.isNumber || character == "_" { return 0 }
            if character == " " || character == "\t" { return 1 }
            return 2
        }

        while index < line.endIndex {
            let start = index
            let startOffset = utf16Offset
            let tokenKind = kind(line[index])
            utf16Offset += line[index].utf16.count
            index = line.index(after: index)
            if tokenKind != 2 {
                while index < line.endIndex, kind(line[index]) == tokenKind {
                    utf16Offset += line[index].utf16.count
                    index = line.index(after: index)
                }
            }
            tokens.append((line[start..<index], NSRange(
                location: startOffset, length: utf16Offset - startOffset
            )))
        }
        return tokens
    }

    /// Word-level diff for one removed/added line pair, or nil when emphasis
    /// would be noise. Token sequences are diffed with the same Myers used for
    /// lines (token counts are small).
    static func diff(old: Substring, new: Substring) -> DiffIntralineResult? {
        guard !old.utf8.elementsEqual(new.utf8) else { return nil }
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        guard oldTokens.count <= tokenLimit, newTokens.count <= tokenLimit,
              !oldTokens.isEmpty, !newTokens.isEmpty, !Task.isCancelled
        else { return nil }

        let oldTexts = oldTokens.map(\.text)
        let newTexts = newTokens.map(\.text)
        // Tokens absent from the opposite line must be edited in any matching.
        // When that minimal cost already exceeds both noise thresholds,
        // Myers cannot produce useful emphasis even with optimal alignment.
        let oldSet = Set(oldTexts)
        let newSet = Set(newTexts)
        let unavoidableOld = oldTokens.reduce(0) {
            $0 + (newSet.contains($1.text) ? 0 : $1.range.length)
        }
        let unavoidableNew = newTokens.reduce(0) {
            $0 + (oldSet.contains($1.text) ? 0 : $1.range.length)
        }
        if Double(unavoidableOld) / Double(max(1, old.utf16.count)) > noiseThreshold,
           Double(unavoidableNew) / Double(max(1, new.utf16.count)) > noiseThreshold {
            return nil
        }

        var builder = TokenOpsBuilder()
        guard myersTokens(oldTexts: oldTexts, newTexts: newTexts, into: &builder)
        else { return nil }
        let ops = builder.ops

        var oldRanges: [NSRange] = []
        var newRanges: [NSRange] = []
        var changedOld = 0
        var changedNew = 0
        for op in ops {
            switch op {
            case .equal:
                break
            case .delete(let start, let count):
                let union = unionRange(oldTokens[start..<(start + count)].map(\.range))
                oldRanges.append(union)
                changedOld += union.length
            case .insert(let start, let count):
                let union = unionRange(newTokens[start..<(start + count)].map(\.range))
                newRanges.append(union)
                changedNew += union.length
            }
        }

        let oldLength = max(1, old.utf16.count)
        let newLength = max(1, new.utf16.count)
        if Double(changedOld) / Double(oldLength) > noiseThreshold,
           Double(changedNew) / Double(newLength) > noiseThreshold {
            return nil
        }
        // Merge ranges separated by nothing (adjacent) so emphasis rectangles
        // don't splinter.
        return DiffIntralineResult(
            oldRanges: mergeAdjacent(oldRanges),
            newRanges: mergeAdjacent(newRanges)
        )
    }

    private struct TokenOpsBuilder {
        var ops: [DiffLineOp] = []

        mutating func equal(_ count: Int) {
            guard count > 0 else { return }
            appendMerged(.equal(oldStart: nextOld, newStart: nextNew, count: count))
        }
        mutating func delete(_ count: Int) {
            guard count > 0 else { return }
            appendMerged(.delete(oldStart: nextOld, count: count))
        }
        mutating func insert(_ count: Int) {
            guard count > 0 else { return }
            appendMerged(.insert(newStart: nextNew, count: count))
        }

        private var nextOld = 0
        private var nextNew = 0

        private mutating func appendMerged(_ op: DiffLineOp) {
            switch op {
            case .equal(_, _, let count):
                if case .equal(let o, let n, let c) = ops.last {
                    ops[ops.count - 1] = .equal(oldStart: o, newStart: n, count: c + count)
                } else {
                    ops.append(op)
                }
                nextOld += count
                nextNew += count
            case .delete(_, let count):
                if case .delete(let o, let c) = ops.last {
                    ops[ops.count - 1] = .delete(oldStart: o, count: c + count)
                } else {
                    ops.append(op)
                }
                nextOld += count
            case .insert(_, let count):
                if case .insert(let n, let c) = ops.last {
                    ops[ops.count - 1] = .insert(newStart: n, count: c + count)
                } else {
                    ops.append(op)
                }
                nextNew += count
            }
        }
    }

    /// Myers on token sequences; same algorithm as the line version, kept
    /// separate because the inputs and the builder are simpler.
    private static func myersTokens(
        oldTexts: [Substring], newTexts: [Substring],
        into builder: inout TokenOpsBuilder
    ) -> Bool {
        func equalTokens(_ oldIndex: Int, _ newIndex: Int) -> Bool {
            oldTexts[oldIndex].utf8.elementsEqual(newTexts[newIndex].utf8)
        }

        let n = oldTexts.count
        let m = newTexts.count
        let maxD = n + m
        let offset = maxD
        var v = [Int](repeating: 0, count: 2 * maxD + 1)
        var trace: [[Int]] = []

        var foundD = -1
        outer: for d in 0...maxD {
            if Task.isCancelled { return false }
            trace.append(v)
            var k = -d
            while k <= d {
                if Task.isCancelled { return false }
                var x: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    x = v[k + 1 + offset]
                } else {
                    x = v[k - 1 + offset] + 1
                }
                var y = x - k
                while x < n, y < m, equalTokens(x, y) {
                    if Task.isCancelled { return false }
                    x += 1
                    y += 1
                }
                v[k + offset] = x
                if x >= n, y >= m {
                    foundD = d
                    break outer
                }
                k += 2
            }
        }
        precondition(foundD >= 0)

        enum Step { case equalOne, deleteOne, insertOne }
        var steps: [Step] = []
        var x = n
        var y = m
        var d = foundD
        while d > 0 {
            let vPrev = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vPrev[k - 1 + offset] < vPrev[k + 1 + offset]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = vPrev[prevK + offset]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                steps.append(.equalOne)
                x -= 1
                y -= 1
            }
            if x == prevX {
                steps.append(.insertOne)
                y -= 1
            } else {
                steps.append(.deleteOne)
                x -= 1
            }
            d -= 1
        }
        while x > 0, y > 0 {
            steps.append(.equalOne)
            x -= 1
            y -= 1
        }
        while x > 0 { steps.append(.deleteOne); x -= 1 }
        while y > 0 { steps.append(.insertOne); y -= 1 }

        for step in steps.reversed() {
            switch step {
            case .equalOne: builder.equal(1)
            case .deleteOne: builder.delete(1)
            case .insertOne: builder.insert(1)
            }
        }
        return true
    }

    private static func unionRange(_ ranges: [NSRange]) -> NSRange {
        guard let first = ranges.first else { return NSRange(location: 0, length: 0) }
        var union = first
        for range in ranges.dropFirst() {
            union = NSUnionRange(union, range)
        }
        return union
    }

    private static func mergeAdjacent(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if range.location <= last.location + last.length {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

// MARK: - Diff rows and documents

/// What one visible row of the diff is.
nonisolated enum DiffRowKind {
    case context
    case removed
    case added
    /// Split view only: blank spacer opposite the other side's extra lines.
    case filler
    /// Stands in for a folded run of unmodified lines; expandable.
    case collapsed
}

/// Metadata carried by a `.collapsed` row.
nonisolated struct DiffCollapsedRun: Equatable {
    /// Where a click reveals lines, fixed by the gap's position in the file
    /// (ported from Pierre's separator buttons).
    enum Direction: Equatable {
        /// Gap above the first change: reveal from the hidden range's end,
        /// growing upward from the content below.
        case revealUp
        /// Gap after the last change: reveal from the hidden range's start,
        /// growing downward from the content above.
        case revealDown
        /// Gap between changes: reveal a chunk at both edges.
        case both
    }

    /// Original-file coordinates survive editing on the modified side.
    let baselineRange: Range<Int>
    var hiddenLines: Int { baselineRange.count }
    let direction: Direction

    func revealNext(excluding revealed: [Range<Int>] = []) -> [Range<Int>] {
        // The tab keeps revealed intervals sorted and merged. Subtract them
        // from this separator's original range so consecutive clicks on a
        // still-rendered separator reveal new lines instead of the same ones.
        var hidden: [Range<Int>] = []
        var cursor = baselineRange.lowerBound
        for range in revealed where range.upperBound > cursor
            && range.lowerBound < baselineRange.upperBound {
            let end = min(baselineRange.upperBound, range.lowerBound)
            if cursor < end { hidden.append(cursor..<end) }
            cursor = max(cursor, min(baselineRange.upperBound, range.upperBound))
        }
        if cursor < baselineRange.upperBound { hidden.append(cursor..<baselineRange.upperBound) }
        guard let first = hidden.first, let last = hidden.last else { return [] }
        switch direction {
        case .revealUp:
            return [(last.upperBound - min(last.count, DiffCollapse.expansionLineCount))..<last.upperBound]
        case .revealDown:
            return [first.lowerBound..<(first.lowerBound + min(first.count, DiffCollapse.expansionLineCount))]
        case .both:
            return [
                first.lowerBound..<(first.lowerBound + min(first.count, DiffCollapse.expansionLineCount)),
                (last.upperBound - min(last.count, DiffCollapse.expansionLineCount))..<last.upperBound,
            ]
        }
    }
}

/// Hidden original new-file paragraphs for a fold. TextKit skips their layout,
/// never removes them from the editable text storage.
nonisolated struct DiffEditFold: Equatable {
    let range: Range<Int> // 0-based source lines; first line hosts the expander
    let separator: DiffCollapsedRun

    static func sourceFolds(in document: DiffSideDocument, lineCount: Int) -> [Self] {
        let rows = document.rows
        var following = Array(repeating: lineCount + 1, count: rows.count)
        var next = lineCount + 1
        for index in rows.indices.reversed() {
            following[index] = next
            if let line = rows[index].newLine { next = line }
        }
        var previous = 0
        var result: [Self] = []
        for (index, row) in rows.enumerated() {
            if let separator = row.collapsed {
                let end = min(lineCount, following[index] - 1)
                if end > previous, end - previous == separator.hiddenLines {
                    result.append(Self(range: previous..<end, separator: separator))
                }
            } else if let line = row.newLine {
                previous = line
            }
        }
        return result
    }
}

/// A block of removed lines shown as read-only ghosts in edit mode, anchored
/// to the new-file line it precedes. Mirrors Pierre's editable diffs, where
/// the buffer holds only the new file and deletions are render-layer rows.
nonisolated struct DiffEditGhostBlock {
    struct Line {
        /// The line's content range in the *old* file (UTF-16, no terminator).
        let sourceRange: NSRange
        /// Word-level changed spans, relative to the line's own content.
        let emphasis: [NSRange]
    }

    /// 0-based new-file line index the block sits in front of; a value equal
    /// to the new file's line count marks a deletion at end-of-file.
    let anchorLine: Int
    /// 1-based old-file number of the first ghost line.
    let firstOldLine: Int
    let lines: [Line]
}

/// Live decorations for the edit-mode buffer (the plain new file).
nonisolated struct DiffEditState {
    let addedLines: [Int]
    /// New-file line index → word-level changed spans (line-relative).
    let addedEmphasis: [Int: [NSRange]]
    let ghosts: [DiffEditGhostBlock]
}

/// How much context stays visible around changes, and how folding behaves —
/// constants ported from Pierre's diff renderer defaults.
nonisolated enum DiffCollapse {
    /// Unmodified lines kept visible on each side of a change.
    static let contextLines = 3
    /// Lines revealed per expander click (Pierre's `expansionLineCount`).
    static let expansionLineCount = 100
    /// Gaps of at most this many lines render inline instead of folding
    /// (Pierre's `collapsedContextThreshold`). Applies to the original gap;
    /// a partially expanded fold persists down to its last hidden line.
    static let inlineGapThreshold = 1
}

/// Which original file a row's text was sliced from, for re-basing that
/// file's syntax-highlight runs onto the rendered document.
nonisolated enum DiffRowSource {
    case old
    case new
    case none
}

/// One row of a rendered diff document.
nonisolated struct DiffRow {
    let kind: DiffRowKind
    /// 1-based line numbers in each file; nil when the row has no line on
    /// that side.
    let oldLine: Int?
    let newLine: Int?
    let source: DiffRowSource
    /// The row's content range in its source file (UTF-16, no terminator).
    let sourceRange: NSRange
    /// Word-level changed spans, relative to the row's own content.
    var emphasis: [NSRange]
    /// True on the last line of a side that does not end with a newline while
    /// the other side does (or the file's own terminator was removed/added).
    var missingNewline: Bool
    /// Present on `.collapsed` rows only.
    var collapsed: DiffCollapsedRun? = nil
}

/// A full document the viewer hands to one native NSTextView: the joined text plus
/// per-row metadata aligned with its paragraphs.
nonisolated struct DiffSideDocument {
    let text: String
    let rows: [DiffRow]
    /// UTF-16 offset of each row's first character in `text`; one entry per
    /// row. Row i spans `lineStart[i] ..< lineStart[i] + length(i)`.
    let lineStartOffsets: [Int]
}

/// The content-derived half of a diff — line arrays, ops, and the
/// trailing-newline adjustment — computed once per old/new pair and cached so
/// expanding a folded run only rebuilds documents, not the diff itself.
nonisolated struct DiffCore {
    let oldLines: [DiffSourceLine]
    let newLines: [DiffSourceLine]
    let ops: [DiffLineOp]
    let oldMissingNewline: Bool
    let newMissingNewline: Bool

    static func compute(oldText: String, newText: String) -> DiffCore {
        let (oldLines, oldTrailing) = DiffLineSplitter.lines(of: oldText)
        let (newLines, newTrailing) = DiffLineSplitter.lines(of: newText)
        return assemble(
            oldLines: oldLines, newLines: newLines,
            oldTrailing: oldTrailing, newTrailing: newTrailing,
            ops: DiffEngine.lineOps(old: oldLines, new: newLines)
        )
    }

    static func fromVerifiedOperations(
        oldText: String, newText: String, operations: [DiffLineOp]
    ) -> DiffCore? {
        let (oldLines, oldTrailing) = DiffLineSplitter.lines(of: oldText)
        let (newLines, newTrailing) = DiffLineSplitter.lines(of: newText)
        var oldCursor = 0
        var newCursor = 0
        for op in operations {
            switch op {
            case .equal(let old, let new, let count):
                guard old == oldCursor, new == newCursor,
                      count > 0, old + count <= oldLines.count,
                      new + count <= newLines.count else { return nil }
                // The Git patch verifier already constructed matching unchanged
                // source rows; validating their indices here is sufficient.
                oldCursor += count
                newCursor += count
            case .delete(let old, let count):
                guard old == oldCursor, count > 0,
                      old + count <= oldLines.count else { return nil }
                oldCursor += count
            case .insert(let new, let count):
                guard new == newCursor, count > 0,
                      new + count <= newLines.count else { return nil }
                newCursor += count
            }
        }
        guard oldCursor == oldLines.count, newCursor == newLines.count else { return nil }
        return assemble(oldLines: oldLines, newLines: newLines,
                        oldTrailing: oldTrailing, newTrailing: newTrailing,
                        ops: operations)
    }

    static func computeIfActive(
        oldText: String, newText: String, cancellation: @escaping () -> Bool
    ) -> DiffCore? {
        guard !cancellation() else { return nil }
        let (oldLines, oldTrailing) = DiffLineSplitter.lines(of: oldText)
        guard !cancellation() else { return nil }
        let (newLines, newTrailing) = DiffLineSplitter.lines(of: newText)
        guard !cancellation(),
              let ops = DiffEngine.lineOpsIfActive(
                  old: oldLines, new: newLines, cancellation: cancellation
              ), !cancellation() else { return nil }
        return assemble(
            oldLines: oldLines, newLines: newLines,
            oldTrailing: oldTrailing, newTrailing: newTrailing, ops: ops
        )
    }

    private static func assemble(
        oldLines: [DiffSourceLine], newLines: [DiffSourceLine],
        oldTrailing: Bool, newTrailing: Bool, ops sourceOps: [DiffLineOp]
    ) -> DiffCore {
        var ops = sourceOps
        // A trailing-newline difference is a real change to the last line that
        // line-splitting hides. Convert the final shared line into a
        // removed/added pair so it surfaces.
        var oldMissingNewline = false
        var newMissingNewline = false
        if oldTrailing != newTrailing, !oldLines.isEmpty, !newLines.isEmpty {
            oldMissingNewline = !oldTrailing
            newMissingNewline = !newTrailing
            if case .equal(let oldStart, let newStart, let count) = ops.last,
               oldStart + count == oldLines.count, newStart + count == newLines.count {
                ops.removeLast()
                if count > 1 {
                    ops.append(.equal(oldStart: oldStart, newStart: newStart, count: count - 1))
                }
                ops.append(.delete(oldStart: oldLines.count - 1, count: 1))
                ops.append(.insert(newStart: newLines.count - 1, count: 1))
            }
        }

        return DiffCore(
            oldLines: oldLines,
            newLines: newLines,
            ops: ops,
            oldMissingNewline: oldMissingNewline,
            newMissingNewline: newMissingNewline
        )
    }
}

/// Everything the viewer needs for one old/new content pair, precomputed off
/// the main actor: the shared line diff plus unified and split documents.
nonisolated struct DiffComputation {
    let unified: DiffSideDocument
    let splitLeft: DiffSideDocument
    let splitRight: DiffSideDocument
    /// Live decorations for the edit-mode buffer: added lines, word-level
    /// emphasis, and read-only deletion ghost blocks.
    let editState: DiffEditState

    /// Revealed ranges are anchored to the immutable original file.
    /// Pass nil to disable folding entirely.
    static func build(core: DiffCore, revealedLines: [Range<Int>]?) -> DiffComputation {
        let blocks = DiffBlocks(ops: core.ops, oldLines: core.oldLines, newLines: core.newLines)
        let unified = buildUnified(
            blocks: blocks, oldLines: core.oldLines, newLines: core.newLines,
            oldMissingNewline: core.oldMissingNewline,
            newMissingNewline: core.newMissingNewline,
            revealedLines: revealedLines
        )
        let (left, right) = buildSplit(
            blocks: blocks, oldLines: core.oldLines, newLines: core.newLines,
            oldMissingNewline: core.oldMissingNewline,
            newMissingNewline: core.newMissingNewline,
            revealedLines: revealedLines
        )

        return DiffComputation(
            unified: unified,
            splitLeft: left,
            splitRight: right,
            editState: editState(blocks: blocks, oldLines: core.oldLines)
        )
    }

    /// Extra blank rows on the editable side when old lines outnumber new
    /// lines within a change block. No complete unfolded split document needed.
    static func editableSplitPadding(core: DiffCore) -> [Int: Int] {
        let blocks = DiffBlocks(ops: core.ops)
        var padding: [Int: Int] = [:]
        var newLine = 0
        for item in blocks.items {
            switch item {
            case .equal(_, _, let count):
                newLine += count
            case .block(let block):
                newLine += block.inserts.count
                let excess = block.deletes.count - block.inserts.count
                if excess > 0 { padding[newLine, default: 0] += excess }
            }
        }
        return padding
    }

    /// Full render with no folding — the shape the invariant tests verify.
    static func compute(oldText: String, newText: String) -> DiffComputation {
        build(core: .compute(oldText: oldText, newText: newText), revealedLines: nil)
    }

    // MARK: Collapse planning

    /// A previously revealed interval can lie in the middle of a new
    /// equal run after editing, so one run may contain multiple folds.
    private enum EqualSegment {
        case lines(Range<Int>)
        case fold(hidden: Range<Int>, direction: DiffCollapsedRun.Direction)
    }

    private static func equalSegments(
        oldStart: Int, count: Int, hasChangeBefore: Bool, hasChangeAfter: Bool,
        revealedLines: [Range<Int>]?
    ) -> [EqualSegment] {
        guard let revealedLines else { return [.lines(0..<count)] }
        let lead = hasChangeBefore ? min(count, DiffCollapse.contextLines) : 0
        let trail = hasChangeAfter ? min(count - lead, DiffCollapse.contextLines) : 0
        guard count - lead - trail > DiffCollapse.inlineGapThreshold else {
            return [.lines(0..<count)]
        }

        var visible: [Range<Int>] = []
        if lead > 0 { visible.append(0..<lead) }
        for revealed in revealedLines {
            let start = max(oldStart, revealed.lowerBound)
            let end = min(oldStart + count, revealed.upperBound)
            if start < end { visible.append((start - oldStart)..<(end - oldStart)) }
        }
        if trail > 0 { visible.append((count - trail)..<count) }
        visible.sort { $0.lowerBound < $1.lowerBound }

        let direction: DiffCollapsedRun.Direction
        switch (hasChangeBefore, hasChangeAfter) {
        case (false, _): direction = .revealUp
        case (_, false): direction = .revealDown
        default: direction = .both
        }
        var segments: [EqualSegment] = []
        var position = 0
        for range in visible where range.upperBound > position {
            if range.lowerBound > position {
                segments.append(.fold(hidden: position..<range.lowerBound, direction: direction))
            }
            let start = max(position, range.lowerBound)
            segments.append(.lines(start..<range.upperBound))
            position = range.upperBound
        }
        if position < count {
            segments.append(.fold(hidden: position..<count, direction: direction))
        }
        return segments
    }

    private static func collapsedRow(
        baselineRange: Range<Int>, direction: DiffCollapsedRun.Direction
    ) -> DiffRow {
        DiffRow(
            kind: .collapsed,
            oldLine: nil,
            newLine: nil,
            source: .none,
            sourceRange: NSRange(location: 0, length: 0),
            emphasis: [],
            missingNewline: false,
            collapsed: DiffCollapsedRun(baselineRange: baselineRange, direction: direction)
        )
    }

    /// Edit-mode state, mirroring Pierre's editable diffs: the buffer holds
    /// only the new file, while removed lines surface as read-only ghost
    /// blocks anchored to the new-file line they sit in front of
    /// (`anchorLine == line count` marks a deletion at end-of-file). Rebuilt
    /// live (debounced) as the user types.
    static func editState(
        ops: [DiffLineOp], oldLines: [DiffSourceLine], newLines: [DiffSourceLine]
    ) -> DiffEditState {
        editState(blocks: DiffBlocks(ops: ops, oldLines: oldLines, newLines: newLines),
                  oldLines: oldLines)
    }

    private static func editState(blocks: DiffBlocks, oldLines: [DiffSourceLine]) -> DiffEditState {
        var added: [Int] = []
        var addedEmphasis: [Int: [NSRange]] = [:]
        var ghosts: [DiffEditGhostBlock] = []
        var newCursor = 0
        for item in blocks.items {
            switch item {
            case .equal(_, _, let count):
                newCursor += count
            case .block(let block):
                added.append(contentsOf: block.inserts)
                for index in block.inserts {
                    if let ranges = block.newEmphasis[index] { addedEmphasis[index] = ranges }
                }
                if let first = block.deletes.first {
                    ghosts.append(DiffEditGhostBlock(
                        anchorLine: block.inserts.first ?? newCursor,
                        firstOldLine: first + 1,
                        lines: block.deletes.map { index in
                            DiffEditGhostBlock.Line(
                                sourceRange: oldLines[index].utf16Range,
                                emphasis: block.oldEmphasis[index] ?? []
                            )
                        }
                    ))
                }
                newCursor += block.inserts.count
            }
        }
        return DiffEditState(addedLines: added, addedEmphasis: addedEmphasis, ghosts: ghosts)
    }

    /// Change blocks: consecutive delete+insert ops between equal runs, with
    /// intraline emphasis computed for index-paired lines.
    private struct DiffBlocks {
        struct Block {
            var deletes: [Int] = []   // old line indexes
            var inserts: [Int] = []   // new line indexes
            var oldEmphasis: [Int: [NSRange]] = [:]
            var newEmphasis: [Int: [NSRange]] = [:]
        }
        /// Ordered walk items: either an equal run or a change block.
        enum Item {
            case equal(oldStart: Int, newStart: Int, count: Int)
            case block(Block)
        }
        var items: [Item] = []

        init(ops: [DiffLineOp], oldLines: [DiffSourceLine]? = nil,
             newLines: [DiffSourceLine]? = nil) {
            var pending = Block()
            func flush() {
                if !pending.deletes.isEmpty || !pending.inserts.isEmpty {
                    if let oldLines, let newLines {
                        let ranges = DiffComputation.blockEmphasis(
                            pending, oldLines: oldLines, newLines: newLines
                        )
                        pending.oldEmphasis = ranges.old
                        pending.newEmphasis = ranges.new
                    }
                    items.append(.block(pending))
                    pending = Block()
                }
            }
            for op in ops {
                if Task.isCancelled { break }
                switch op {
                case .equal(let oldStart, let newStart, let count):
                    flush()
                    items.append(.equal(oldStart: oldStart, newStart: newStart, count: count))
                case .delete(let oldStart, let count):
                    pending.deletes.append(contentsOf: oldStart..<(oldStart + count))
                case .insert(let newStart, let count):
                    pending.inserts.append(contentsOf: newStart..<(newStart + count))
                }
            }
            flush()
        }
    }

    /// Intraline emphasis for a block, pairing removed/added lines by index.
    private static func blockEmphasis(
        _ block: DiffBlocks.Block, oldLines: [DiffSourceLine], newLines: [DiffSourceLine]
    ) -> (old: [Int: [NSRange]], new: [Int: [NSRange]]) {
        var old: [Int: [NSRange]] = [:]
        var new: [Int: [NSRange]] = [:]
        for pair in 0..<min(block.deletes.count, block.inserts.count) {
            if Task.isCancelled { break }
            let oldIndex = block.deletes[pair]
            let newIndex = block.inserts[pair]
            if let result = DiffIntraline.diff(
                old: oldLines[oldIndex].text, new: newLines[newIndex].text
            ) {
                old[oldIndex] = result.oldRanges
                new[newIndex] = result.newRanges
            }
        }
        return (old, new)
    }

    private struct DocumentBuilder {
        private var parts: [Substring] = []
        private(set) var rows: [DiffRow] = []
        private(set) var lineStartOffsets: [Int] = []
        private var utf16Length = 0

        mutating func append(_ row: DiffRow, text: Substring) {
            lineStartOffsets.append(utf16Length)
            rows.append(row)
            parts.append(text)
            utf16Length += text.utf16.count + 1
        }

        func document() -> DiffSideDocument {
            var rendered = parts.joined(separator: "\n")
            if !parts.isEmpty { rendered.append("\n") }
            return DiffSideDocument(
                text: rendered,
                rows: rows,
                lineStartOffsets: lineStartOffsets
            )
        }
    }

    private static func buildUnified(
        blocks: DiffBlocks, oldLines: [DiffSourceLine], newLines: [DiffSourceLine],
        oldMissingNewline: Bool, newMissingNewline: Bool,
        revealedLines: [Range<Int>]?
    ) -> DiffSideDocument {
        var builder = DocumentBuilder()
        for (itemIndex, item) in blocks.items.enumerated() {
            switch item {
            case .equal(let oldStart, let newStart, let count):
                let segments = equalSegments(
                    oldStart: oldStart, count: count,
                    hasChangeBefore: itemIndex > 0,
                    hasChangeAfter: itemIndex < blocks.items.count - 1,
                    revealedLines: revealedLines
                )
                for segment in segments {
                    switch segment {
                    case .lines(let range):
                        for offset in range {
                            let newIndex = newStart + offset
                            builder.append(
                                DiffRow(
                                    kind: .context,
                                    oldLine: oldStart + offset + 1,
                                    newLine: newIndex + 1,
                                    source: .new,
                                    sourceRange: newLines[newIndex].utf16Range,
                                    emphasis: [],
                                    missingNewline: false
                                ),
                                text: newLines[newIndex].text
                            )
                        }
                    case .fold(let hidden, let direction):
                        builder.append(
                            collapsedRow(
                                baselineRange: (oldStart + hidden.lowerBound)..<(oldStart + hidden.upperBound),
                                direction: direction
                            ),
                            text: ""
                        )
                    }
                }
            case .block(let block):
                for oldIndex in block.deletes {
                    builder.append(
                        DiffRow(
                            kind: .removed,
                            oldLine: oldIndex + 1,
                            newLine: nil,
                            source: .old,
                            sourceRange: oldLines[oldIndex].utf16Range,
                            emphasis: block.oldEmphasis[oldIndex] ?? [],
                            missingNewline: oldMissingNewline && oldIndex == oldLines.count - 1
                        ),
                        text: oldLines[oldIndex].text
                    )
                }
                for newIndex in block.inserts {
                    builder.append(
                        DiffRow(
                            kind: .added,
                            oldLine: nil,
                            newLine: newIndex + 1,
                            source: .new,
                            sourceRange: newLines[newIndex].utf16Range,
                            emphasis: block.newEmphasis[newIndex] ?? [],
                            missingNewline: newMissingNewline && newIndex == newLines.count - 1
                        ),
                        text: newLines[newIndex].text
                    )
                }
            }
        }
        return builder.document()
    }

    private static func buildSplit(
        blocks: DiffBlocks, oldLines: [DiffSourceLine], newLines: [DiffSourceLine],
        oldMissingNewline: Bool, newMissingNewline: Bool,
        revealedLines: [Range<Int>]?
    ) -> (left: DiffSideDocument, right: DiffSideDocument) {
        var left = DocumentBuilder()
        var right = DocumentBuilder()

        func filler() -> DiffRow {
            DiffRow(
                kind: .filler, oldLine: nil, newLine: nil,
                source: .none, sourceRange: NSRange(location: 0, length: 0),
                emphasis: [], missingNewline: false
            )
        }

        for (itemIndex, item) in blocks.items.enumerated() {
            switch item {
            case .equal(let oldStart, let newStart, let count):
                let segments = equalSegments(
                    oldStart: oldStart, count: count,
                    hasChangeBefore: itemIndex > 0,
                    hasChangeAfter: itemIndex < blocks.items.count - 1,
                    revealedLines: revealedLines
                )
                for segment in segments {
                    switch segment {
                    case .lines(let range):
                        for offset in range {
                            let oldIndex = oldStart + offset
                            let newIndex = newStart + offset
                            left.append(
                                DiffRow(
                                    kind: .context,
                                    oldLine: oldIndex + 1,
                                    newLine: newIndex + 1,
                                    source: .old,
                                    sourceRange: oldLines[oldIndex].utf16Range,
                                    emphasis: [],
                                    missingNewline: false
                                ),
                                text: oldLines[oldIndex].text
                            )
                            right.append(
                                DiffRow(
                                    kind: .context,
                                    oldLine: oldIndex + 1,
                                    newLine: newIndex + 1,
                                    source: .new,
                                    sourceRange: newLines[newIndex].utf16Range,
                                    emphasis: [],
                                    missingNewline: false
                                ),
                                text: newLines[newIndex].text
                            )
                        }
                    case .fold(let hidden, let direction):
                        // Both sides share the exact original-file interval.
                        let separator = collapsedRow(
                            baselineRange: (oldStart + hidden.lowerBound)..<(oldStart + hidden.upperBound),
                            direction: direction
                        )
                        left.append(separator, text: "")
                        right.append(separator, text: "")
                    }
                }
            case .block(let block):
                let rowCount = max(block.deletes.count, block.inserts.count)
                for rowOffset in 0..<rowCount {
                    if rowOffset < block.deletes.count {
                        let oldIndex = block.deletes[rowOffset]
                        left.append(
                            DiffRow(
                                kind: .removed,
                                oldLine: oldIndex + 1,
                                newLine: nil,
                                source: .old,
                                sourceRange: oldLines[oldIndex].utf16Range,
                                emphasis: block.oldEmphasis[oldIndex] ?? [],
                                missingNewline: oldMissingNewline && oldIndex == oldLines.count - 1
                            ),
                            text: oldLines[oldIndex].text
                        )
                    } else {
                        left.append(filler(), text: "")
                    }
                    if rowOffset < block.inserts.count {
                        let newIndex = block.inserts[rowOffset]
                        right.append(
                            DiffRow(
                                kind: .added,
                                oldLine: nil,
                                newLine: newIndex + 1,
                                source: .new,
                                sourceRange: newLines[newIndex].utf16Range,
                                emphasis: block.newEmphasis[newIndex] ?? [],
                                missingNewline: newMissingNewline && newIndex == newLines.count - 1
                            ),
                            text: newLines[newIndex].text
                        )
                    } else {
                        right.append(filler(), text: "")
                    }
                }
            }
        }
        return (left.document(), right.document())
    }
}
