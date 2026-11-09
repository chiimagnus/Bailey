import Foundation
import SwiftTreeSitter
@testable import Bailey

nonisolated enum DiffSyntaxOracle {
    static func captures(text: String, context: DiffHighlightContext,
                         ranges: [NSRange]? = nil) -> [DiffCaptureRun] {
        guard !text.isEmpty,
              let grammar = SyntaxLanguage.parser(grammarIndex: context.grammarIndex) else { return [] }
        let parser = Parser()
        do { try parser.setLanguage(grammar) }
        catch { return [] }
        guard let tree = parser.parse(text), let root = tree.rootNode else { return [] }
        let cursor = context.query.execute(node: root, in: tree)
        let predicate = SwiftTreeSitter.Predicate.Context(string: text)
        let captures = cursor.resolve(with: predicate).highlights().filter { capture in
            capture.range.length > 0
                && !SyntaxHighlightCoordinator.ignoredCaptures.contains(capture.name)
                && (ranges?.contains { NSIntersectionRange($0, capture.range).length > 0 } ?? true)
        }.sorted { $0.range.location < $1.range.location }
        var result: [DiffCaptureRun] = []
        for capture in captures {
            if let last = result.last, last.range == capture.range, last.name == capture.name { continue }
            result.append(DiffCaptureRun(range: capture.range, name: capture.name))
        }
        return result
    }
}
