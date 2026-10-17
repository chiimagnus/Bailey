import Foundation
import SwiftTreeSitter
import XCTest
@testable import Bailey

@MainActor
final class TextCoordinateIndexTests: XCTestCase {
    private func check(_ index: TextCoordinateIndex, text: String, parser: Parser,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(index.length, text.utf16.count, file: file, line: line)
        var row = 0
        var column = 0
        XCTAssertEqual(index.point(at: 0), .zero, file: file, line: line)
        for (offset, unit) in text.utf16.enumerated() {
            if unit == 10 { row += 1; column = 0 } else { column += 2 }
            XCTAssertEqual(index.point(at: offset + 1), Point(row: row, column: column), file: file, line: line)
        }
        XCTAssertNil(index.point(at: -1), file: file, line: line)
        XCTAssertNil(index.point(at: text.utf16.count + 1), file: file, line: line)
        let root = try XCTUnwrap(parser.parse(text)?.rootNode, file: file, line: line)
        XCTAssertEqual(index.point(at: root.range.location), root.pointRange.lowerBound, file: file, line: line)
        XCTAssertEqual(index.point(at: NSMaxRange(root.range)), root.pointRange.upperBound, file: file, line: line)
    }

    func testLFByteColumnsAndReplacementBoundariesMatchParser() throws {
        let language = try XCTUnwrap(SyntaxHighlighting.language(for: "fixture.swift"))
        let parser = Parser()
        try parser.setLanguage(language.parser)
        for original in ["", "\n", "a\r\nb\r", "// 中文👋\u{2028}\u{2029}\nlet café = 1\n"] {
            let index = TextCoordinateIndex(original)
            try check(index, text: original, parser: parser)
            var text = original
            for replacement in ["\n\n", "\r\n👋", "same", "", "\n"] {
                let range = NSRange(location: 0, length: text.utf16.count)
                index.replace(in: range, with: replacement)
                text = replacement
                try check(index, text: text, parser: parser)
            }
        }
    }

    func testSeededEditsMatchDirectScanAndFreshParser() throws {
        let language = try XCTUnwrap(SyntaxHighlighting.language(for: "fixture.swift"))
        let parser = Parser()
        try parser.setLanguage(language.parser)
        var text = "// 中文 👋\r\nlet café = 1\n"
        let index = TextCoordinateIndex(text)
        var seed: UInt64 = 0xC001D00D
        func next(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        let replacements = ["", "A", "\n", "\r", "\r\n", "中文", "👋", "e\u{301}", "\u{2028}", "\u{2029}"]
        for _ in 0..<400 {
            var boundaries = [0]
            for scalar in text.unicodeScalars {
                boundaries.append(boundaries.last! + scalar.utf16.count)
            }
            let first = next(boundaries.count)
            let last = first + next(boundaries.count - first)
            let range = NSRange(location: boundaries[first], length: boundaries[last] - boundaries[first])
            let replacement = replacements[next(replacements.count)]
            index.replace(in: range, with: replacement)
            text = (text as NSString).replacingCharacters(in: range, with: replacement)
            try check(index, text: text, parser: parser)
        }
    }
}
