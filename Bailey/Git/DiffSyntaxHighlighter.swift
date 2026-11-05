//  Offline syntax highlighting for the diff viewer. The review documents are
//  read-only and rebuilt wholesale on reload, so instead of running the live
//  Neon plugin over an interleaved diff document (whose mixed old/new lines
//  aren't parseable source), each side of the diff is parsed *as its own
//  file* and the resulting color runs are re-based line-by-line onto the
//  rendered documents. Removed lines get the old file's colors, added and
//  context lines the new file's — the same per-side model web diff renderers
//  use, with the editor's exact grammars and theme.
//

import AppKit
import SwiftTreeSitter

/// Background parser results contain only transferable source ranges/names.
nonisolated struct DiffCaptureRun: Sendable {
    let range: NSRange
    let name: String
}

/// Native presentation colors never cross the actor boundary.
struct DiffHighlightRun {
    let range: NSRange
    let color: NSColor
}

nonisolated struct DiffHighlightContext: Sendable {
    let grammarIndex: Int
    let query: SwiftTreeSitter.Query
}

/// Each diff tab owns two independent source parsers. Folding only changes
/// queried rows; it must not rebuild syntax trees for unchanged source text.
actor DiffSyntaxSource {
    private var cachedText: String?
    private var cachedGrammar: Int?
    private var cachedTree: MutableTree?
    private(set) var parseCount = 0

    func captures(
        text: String, context: DiffHighlightContext, ranges: [NSRange]
    ) -> [DiffCaptureRun] {
        guard !Task.isCancelled, !text.isEmpty, !ranges.isEmpty else { return [] }
        let unchanged = cachedGrammar == context.grammarIndex
            && (cachedText?.utf8.elementsEqual(text.utf8) ?? false)
        if !unchanged {
            let parser = Parser()
            guard let grammar = SyntaxLanguage.parser(grammarIndex: context.grammarIndex),
                  (try? parser.setLanguage(grammar)) != nil,
                  let parsed = parser.parse(text), !Task.isCancelled else { return [] }
            parseCount += 1
            // Retain bounded snapshots only. Large files still get visible
            // highlights without keeping two multi-megabyte trees per tab.
            if text.utf8.count <= 2_000_000 {
                cachedText = text
                cachedGrammar = context.grammarIndex
                cachedTree = parsed
            } else {
                cachedText = nil
                cachedGrammar = nil
                cachedTree = nil
            }
            return DiffSyntaxHighlighter.queryCaptures(
                tree: parsed, text: text, context: context, ranges: ranges
            )
        }
        guard let cachedTree else { return [] }
        return DiffSyntaxHighlighter.queryCaptures(
            tree: cachedTree, text: text, context: context, ranges: ranges
        )
    }
}

enum DiffSyntaxHighlighter {
    /// Range-filter query captures to the source rows actually represented by
    /// the folded diff. Tree-sitter still parses the complete file for correct
    /// multiline syntax context; hidden source rows need no token attributes.
    nonisolated static func visibleRanges(
        in document: DiffSideDocument, source: DiffRowSource
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        for row in document.rows where row.source == source && row.sourceRange.length > 0 {
            let range = row.sourceRange
            if let last = ranges.last, range.location <= NSMaxRange(last) + 1 {
                ranges[ranges.count - 1].length = max(NSMaxRange(last), NSMaxRange(range))
                    - last.location
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// Resolves the language and compiled highlights query for `path`,
    /// compiling (off the main thread) and caching on first use. Returns nil
    /// for file types without a grammar — the diff renders unhighlighted.
    static func context(for path: String) async -> DiffHighlightContext? {
        guard let language = SyntaxHighlighting.language(for: path) else { return nil }
        guard let grammarIndex = language.grammarIndex else { return nil }
        let data = SyntaxHighlighting.highlightsData(for: language)
        let query = await HighlightQueryCache.shared.query(for: language, data: data)
        guard let query else { return nil }
        return DiffHighlightContext(grammarIndex: grammarIndex, query: query)
    }

    fileprivate nonisolated static func queryCaptures(
        tree: MutableTree, text: String, context: DiffHighlightContext,
        ranges: [NSRange]
    ) -> [DiffCaptureRun] {
        guard !Task.isCancelled, let root = tree.rootNode else { return [] }
        let predicateContext = SwiftTreeSitter.Predicate.Context(string: text)
        var runs: [DiffCaptureRun] = []
        for visible in ranges {
            guard !Task.isCancelled else { return [] }
            let cursor = context.query.execute(node: root, in: tree)
            cursor.setRange(visible)
            for named in cursor.resolve(with: predicateContext).highlights() {
                guard named.range.length > 0,
                      !SyntaxHighlightCoordinator.ignoredCaptures.contains(named.name)
                else { continue }
                runs.append(DiffCaptureRun(range: named.range, name: named.name))
            }
        }
        // A multiline token can intersect more than one disjoint visible
        // range. Preserve source order and avoid repainting duplicate matches.
        runs.sort { $0.range.location < $1.range.location }
        var unique: [DiffCaptureRun] = []
        for run in runs {
            if let last = unique.last, last.range == run.range, last.name == run.name {
                continue
            }
            unique.append(run)
        }
        return unique
    }

    /// Resolve AppKit theme colors on the owning actor, after parsing.
    static func colors(for captures: [DiffCaptureRun]) -> [DiffHighlightRun] {
        let theme = SyntaxHighlighting.theme
        return captures.compactMap { capture in
            guard let color = SyntaxHighlightCoordinator.themeColor(
                for: capture.name, theme: theme
            ) else { return nil }
            return DiffHighlightRun(range: capture.range, color: color)
        }
    }

    /// Builds the document's attributed text: base attributes over the whole
    /// string, then each row colored by the runs of its own source file.
    static func attributedDocument(
        _ document: DiffSideDocument,
        oldRuns: [DiffHighlightRun],
        newRuns: [DiffHighlightRun],
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: document.text, attributes: baseAttributes
        )
        applyRuns(oldRuns, source: .old, to: attributed, document: document)
        applyRuns(newRuns, source: .new, to: attributed, document: document)
        return attributed
    }

    /// Bakes an edit-mode ghost block: the removed lines' text with the old
    /// file's syntax colors and word-level emphasis as background color,
    /// ready for the decoration underlay to draw into the ghost gap. Uses the
    /// same forward-pointer walk as `applyRuns` (block lines ascend through
    /// the old file), which stays correct for multi-line runs.
    static func attributedGhostLines(
        oldText: NSString,
        block: DiffEditGhostBlock,
        runs: [DiffHighlightRun],
        baseAttributes: [NSAttributedString.Key: Any],
        emphasisColor: NSColor
    ) -> [NSAttributedString] {
        var first = 0
        return block.lines.map { line in
            let attributed = NSMutableAttributedString(
                string: oldText.substring(with: line.sourceRange),
                attributes: baseAttributes
            )
            let lineStart = line.sourceRange.location
            let lineEnd = lineStart + line.sourceRange.length

            while first < runs.count,
                  runs[first].range.location + runs[first].range.length <= lineStart {
                first += 1
            }
            var index = first
            while index < runs.count {
                let run = runs[index]
                index += 1
                if run.range.location >= lineEnd { break }
                let overlapStart = max(run.range.location, lineStart)
                let overlapEnd = min(run.range.location + run.range.length, lineEnd)
                guard overlapEnd > overlapStart else { continue }
                attributed.addAttribute(
                    .foregroundColor,
                    value: run.color,
                    range: NSRange(
                        location: overlapStart - lineStart, length: overlapEnd - overlapStart
                    )
                )
            }
            for emphasis in line.emphasis {
                let clamped = NSIntersectionRange(
                    emphasis, NSRange(location: 0, length: line.sourceRange.length)
                )
                guard clamped.length > 0 else { continue }
                attributed.addAttribute(.backgroundColor, value: emphasisColor, range: clamped)
            }
            return attributed
        }
    }

    /// Merge-walk of one side's runs against that side's rows. Both are
    /// ordered by source position (rows sourced from one file appear in file
    /// order in every diff document), so a forward pointer suffices; it only
    /// passes a run once that run can no longer overlap any later row. Runs
    /// are position-ordered with later captures painting over earlier ones on
    /// overlap — sequential `addAttribute` preserves that. Multi-line runs
    /// (block comments, strings) overlap several rows and are re-applied to
    /// each.
    private static func applyRuns(
        _ runs: [DiffHighlightRun],
        source: DiffRowSource,
        to attributed: NSMutableAttributedString,
        document: DiffSideDocument
    ) {
        guard !runs.isEmpty else { return }
        var first = 0
        for (rowIndex, row) in document.rows.enumerated()
        where row.source == source && row.sourceRange.length > 0 {
            let rowStart = row.sourceRange.location
            let rowEnd = rowStart + row.sourceRange.length
            let documentStart = document.lineStartOffsets[rowIndex]

            // Runs wholly before this row can never overlap a later row.
            while first < runs.count,
                  runs[first].range.location + runs[first].range.length <= rowStart {
                first += 1
            }
            var index = first
            while index < runs.count {
                let run = runs[index]
                index += 1
                if run.range.location >= rowEnd { break }
                let overlapStart = max(run.range.location, rowStart)
                let overlapEnd = min(run.range.location + run.range.length, rowEnd)
                guard overlapEnd > overlapStart else { continue }
                attributed.addAttribute(
                    .foregroundColor,
                    value: run.color,
                    range: NSRange(
                        location: documentStart + (overlapStart - rowStart),
                        length: overlapEnd - overlapStart
                    )
                )
            }
        }
    }
}
