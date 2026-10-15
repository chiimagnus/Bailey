import AppKit
import STTextView
import SwiftTreeSitter
import TreeSitterClient
import XCTest
@testable import kero

@MainActor
final class SyntaxHighlightingTests: XCTestCase {
    func testProductionTransformerMatchesUTF16ParserPoints() async throws {
        for source in ["", "let value = 1", "// 中文 👋\r\nlet value = 1\n", "// a\rb\u{2028}c\u{2029}d\n", "\n"] {
            let view = STTextView()
            view.text = source
            let plugin = try XCTUnwrap(SyntaxHighlighting.plugin(for: "fixture.swift"))
            let coordinator = SyntaxHighlightCoordinator(
                textView: view, theme: plugin.theme, language: plugin.language,
                highlightsData: plugin.highlightsData, injectionsData: nil
            )
            let client = coordinator.tsClient
            let transform = try XCTUnwrap(client.locationTransformer)
            var row = 0
            var column = 0
            XCTAssertEqual(transform(0), .zero)
            for (offset, unit) in source.utf16.enumerated() {
                if unit == 10 { row += 1; column = 0 } else { column += 2 }
                XCTAssertEqual(transform(offset + 1), Point(row: row, column: column), "offset \(offset + 1) in \(source.debugDescription)")
            }
            XCTAssertNil(transform(-1))
            XCTAssertNil(transform(source.utf16.count + 1))
            let tree = try await client.currentTree()
            let parser = Parser()
            try parser.setLanguage(plugin.language.parser)
            let expected = try XCTUnwrap(parser.parse(source)?.rootNode)
            XCTAssertEqual(tree.rootNode?.range, expected.range)
            XCTAssertEqual(tree.rootNode?.pointRange, expected.pointRange)
        }
    }
}
