import Foundation
import SwiftTreeSitter
import XCTest
@testable import STTextViewAppKit
@testable import Bailey

@MainActor
final class TextCoordinateIndexTests: XCTestCase {
    func testNativeLineIndexHandlesBoundaryJoinsAndRandomEdits() throws {
        var trailing = STTextLineIndex("a\nb\nc\n")
        trailing.replace(in: NSRange(location: 2, length: 1), replacementLength: 1, text: "a\nx\nc\n")
        XCTAssertEqual(trailing.starts, [0, 2, 4, 6])
        func expectedStarts(_ text: String) -> [Int] {
            let units = Array(text.utf16)
            var starts = [0]
            var offset = 0
            while offset < units.count {
                let unit = units[offset]
                offset += 1
                if unit == 13, offset < units.count, units[offset] == 10 { offset += 1 }
                if [10, 13, 0x2028, 0x2029].contains(unit) { starts.append(offset) }
            }
            return starts
        }
        var seed: UInt64 = 0xABCDEF1234
        func next(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        for original in ["", "\r\n", "a\r\nb\r", "中文👋\u{2028}e\u{301}\u{2029}\n", String(repeating: "x\r\n", count: 1_000)] {
            var text = original
            var index = STTextLineIndex(text as NSString)
            for _ in 0..<300 {
                XCTAssertEqual(index.starts, expectedStarts(text))
                let units = Array(text.utf16)
                var paragraph = 0
                for (row, start) in expectedStarts(text).enumerated() {
                    if row > 0, units[start - 1] != 0x2028 { paragraph += 1 }
                    XCTAssertEqual(index.paragraph(at: start), paragraph)
                }
                var boundaries = [0]
                for scalar in text.unicodeScalars { boundaries.append(boundaries.last! + scalar.utf16.count) }
                let first = next(boundaries.count)
                let last = first + next(boundaries.count - first)
                let range = NSRange(location: boundaries[first], length: boundaries[last] - boundaries[first])
                let replacement = ["", "\r", "\n", "\r\n", "👋", "\u{2028}", "\u{2029}", "abc"][next(8)]
                text = (text as NSString).replacingCharacters(in: range, with: replacement)
                index.replace(in: range, replacementLength: replacement.utf16.count, text: text as NSString)
                XCTAssertEqual(index.length, text.utf16.count)
                for (row, start) in expectedStarts(text).enumerated() { XCTAssertEqual(index.row(at: start), row) }
            }
            XCTAssertEqual(index.starts, expectedStarts(text))
        }
    }

    func testLargeDocumentEditCosts() throws {
        for rows in [382, 1_000, 10_000, 100_000] {
            let source = String(repeating: "struct Item { let value = 123 } // 中文 👋\n", count: rows)
            let index = TextCoordinateIndex(source)
            for position in [0, source.utf16.count / 2, source.utf16.count] {
                var durations: [Double] = []
                for _ in 0..<30 {
                    let started = CFAbsoluteTimeGetCurrent()
                    index.replace(in: NSRange(location: position, length: 0), with: "a")
                    index.replace(in: NSRange(location: position, length: 1), with: "")
                    durations.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                }
                durations.sort()
                print("EDITOR_INDEX rows=\(rows) offset=\(position) pair_ms median=\(durations[15]) p95=\(durations[28]) max=\(durations[29])")
                XCTAssertEqual(index.length, source.utf16.count)
                XCTAssertEqual(index.point(at: source.utf16.count)?.row, UInt32(rows))
            }
        }
    }

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
