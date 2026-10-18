import Foundation
import SwiftTreeSitter
import XCTest
@testable import Bailey

@MainActor
final class TextCoordinateIndexTests: XCTestCase {
    func testNativeLineIndexHandlesBoundaryJoinsAndRandomEdits() throws {
        var trailing = NativeTextLineIndex("a\nb\nc\n")
        trailing.replace(in: NSRange(location: 2, length: 1), replacementLength: 1, text: "a\nx\nc\n")
        XCTAssertEqual((0..<trailing.lineCount).map { trailing.offset(atLine: $0) }, [0, 2, 4, 6])
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
            var index = NativeTextLineIndex(text as NSString)
            for _ in 0..<300 {
                XCTAssertEqual((0..<index.lineCount).map { index.offset(atLine: $0) }, expectedStarts(text))
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
            XCTAssertEqual((0..<index.lineCount).map { index.offset(atLine: $0) }, expectedStarts(text))
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

    func testNativeLineIndexEditCosts() {
        let source = NSMutableString(string: String(repeating: "item line\n", count: 100_000))
        var index = NativeTextLineIndex(source)
        for position in [0, source.length / 2, source.length] {
            var durations: [Double] = []
            for _ in 0..<30 {
                let started = CFAbsoluteTimeGetCurrent()
                source.insert("a", at: position)
                index.replace(in: NSRange(location: position, length: 0),
                              replacementLength: 1, text: source)
                source.deleteCharacters(in: NSRange(location: position, length: 1))
                index.replace(in: NSRange(location: position, length: 1),
                              replacementLength: 0, text: source)
                durations.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
            }
            durations.sort()
            print("EDITOR_NATIVE_INDEX rows=100000 offset=\(position) pair_ms median=\(durations[15]) p95=\(durations[28]) max=\(durations[29])")
            XCTAssertEqual(index.length, source.length)
            XCTAssertEqual(index.row(at: source.length), 100_000)
        }
    }

    func testNativeHundredThousandLineEditsMatchFreshIndex() throws {
        let source = NSMutableString(string: String(repeating: "a\r\nb\u{2028}c\u{2029}d\n", count: 25_000))
        var index = NativeTextLineIndex(source)
        let replacements = ["", "👋", "\r", "\n", "\r\n", "a\u{2028}b", "\u{2029}", "\n\n"]
        for iteration in 0..<24 {
            let starts = (0..<index.lineCount).map { index.offset(atLine: $0) }
            let row = [0, starts.count / 4, starts.count / 2, starts.count - 1][iteration % 4]
            let location = starts[row]
            let end = iteration.isMultiple(of: 3) && row + 1 < starts.count
                ? starts[row + 1] : location
            let range = NSRange(location: location, length: end - location)
            let replacement = replacements[iteration % replacements.count]
            source.replaceCharacters(in: range, with: replacement)
            index.replace(in: range, replacementLength: replacement.utf16.count, text: source)
            let fresh = NativeTextLineIndex(source)
            XCTAssertEqual(index.length, source.length)
            XCTAssertEqual((0..<index.lineCount).map { index.offset(atLine: $0) },
                           (0..<fresh.lineCount).map { fresh.offset(atLine: $0) },
                           "iteration=\(iteration)")
            for offset in [0, 1, source.length / 4, source.length / 2,
                           3 * source.length / 4, source.length - 1, source.length] {
                XCTAssertEqual(index.row(at: offset), fresh.row(at: offset), "iteration=\(iteration)")
            }
        }
    }

    func testHundredThousandLineStructuralNewlineEditCostsAndCoordinates() {
        let original = String(repeating: "item\n", count: 100_000)
        for position in [0, original.utf16.count / 2, original.utf16.count] {
            let source = NSMutableString(string: original)
            var native = NativeTextLineIndex(source)
            let coordinates = TextCoordinateIndex(original)
            for insertion in ["\n", "\r\n", "\u{2028}", "\u{2029}"] {
                let count = insertion.utf16.count
                var nativeDurations: [Double] = []
                var coordinateDurations: [Double] = []
                for iteration in 0..<12 {
                    source.insert(insertion, at: position)
                    var started = CFAbsoluteTimeGetCurrent()
                    native.replace(in: NSRange(location: position, length: 0),
                                   replacementLength: count, text: source)
                    nativeDurations.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                    started = CFAbsoluteTimeGetCurrent()
                    coordinates.replace(in: NSRange(location: position, length: 0), with: insertion)
                    coordinateDurations.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                    if iteration == 0 {
                        let freshNative = NativeTextLineIndex(source)
                        let freshCoordinates = TextCoordinateIndex(source as String)
                        XCTAssertEqual(native.lineCount, freshNative.lineCount)
                        for offset in [0, position, position + count, source.length] {
                            XCTAssertEqual(native.row(at: offset), freshNative.row(at: offset))
                            XCTAssertEqual(coordinates.point(at: offset), freshCoordinates.point(at: offset))
                        }
                    }

                    source.deleteCharacters(in: NSRange(location: position, length: count))
                    started = CFAbsoluteTimeGetCurrent()
                    native.replace(in: NSRange(location: position, length: count),
                                   replacementLength: 0, text: source)
                    nativeDurations.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                    started = CFAbsoluteTimeGetCurrent()
                    coordinates.replace(in: NSRange(location: position, length: count), with: "")
                    coordinateDurations.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                    XCTAssertEqual(native.length, source.length)
                    XCTAssertEqual(coordinates.length, source.length)
                }
                nativeDurations.sort()
                coordinateDurations.sort()
                print("EDITOR_STRUCTURAL_INDEX utf16=\(count) offset=\(position) native_ms=\(nativeDurations[12]) coordinate_ms=\(coordinateDurations[12])")
                let fresh = NativeTextLineIndex(source)
                XCTAssertEqual(native.lineCount, fresh.lineCount)
                for row in [0, 1, native.lineCount / 4, native.lineCount / 2, native.lineCount - 1] {
                    XCTAssertEqual(native.offset(atLine: row), fresh.offset(atLine: row))
                }
                XCTAssertEqual(coordinates.point(at: position),
                               Point(row: position / 5, column: 0))
            }
        }
    }

    func testHundredThousandLinesEraseToEmptyAndRestore() {
        let original = String(repeating: "a\r\nb\u{2028}c\u{2029}d\n", count: 25_000)
        let source = NSMutableString(string: original)
        var native = NativeTextLineIndex(source)
        let coordinates = TextCoordinateIndex(original)
        let length = source.length
        source.setString("")
        native.replace(in: NSRange(location: 0, length: length), replacementLength: 0, text: source)
        coordinates.replace(in: NSRange(location: 0, length: length), with: "")
        XCTAssertEqual(native.lineCount, 1)
        XCTAssertEqual(native.offset(atLine: 0), 0)
        XCTAssertEqual(native.length, 0)
        XCTAssertEqual(coordinates.point(at: 0), .zero)
        XCTAssertNil(coordinates.point(at: 1))

        source.setString(original)
        native.replace(in: NSRange(location: 0, length: 0), replacementLength: length, text: source)
        coordinates.replace(in: NSRange(location: 0, length: 0), with: original)
        let fresh = NativeTextLineIndex(source)
        XCTAssertEqual(native.lineCount, fresh.lineCount)
        for row in [0, native.lineCount / 4, native.lineCount / 2, native.lineCount - 1] {
            XCTAssertEqual(native.offset(atLine: row), fresh.offset(atLine: row))
        }
        let freshCoordinates = TextCoordinateIndex(original)
        for offset in [0, length / 4, length / 2, length] {
            XCTAssertEqual(coordinates.point(at: offset), freshCoordinates.point(at: offset))
        }
    }

    func testHundredThousandLineOffsetEditsMatchFullScan() throws {
        var text = String(repeating: "item\n", count: 100_000)
        let index = TextCoordinateIndex(text)
        for iteration in 0..<24 {
            let units = Array(text.utf16)
            var starts = [0]
            for (offset, unit) in units.enumerated() where unit == 10 {
                starts.append(offset + 1)
            }
            let row = [0, starts.count / 2, starts.count - 1, starts.count / 4][iteration % 4]
            let start = starts[row]
            let range = iteration.isMultiple(of: 3)
                ? NSRange(location: start, length: row + 1 < starts.count ? starts[row + 1] - start : 0)
                : NSRange(location: start, length: 0)
            let replacement = ["👋", "\n", "\r\n中文\n", "", "a\nb", "e\u{301}", "x"][iteration % 7]
            index.replace(in: range, with: replacement)
            text = (text as NSString).replacingCharacters(in: range, with: replacement)
            var expectedStarts = [0]
            for (offset, unit) in text.utf16.enumerated() where unit == 10 {
                expectedStarts.append(offset + 1)
            }
            let size = text.utf16.count
            XCTAssertEqual(index.length, size)
            let checkpoints = [0, 1, size / 4, size / 2, 3 * size / 4, size - 1, size,
                               start, min(start + replacement.utf16.count, size)]
            for offset in checkpoints where offset >= 0 && offset <= size {
                let position = try XCTUnwrap(expectedStarts.lastIndex(where: { $0 <= offset }))
                XCTAssertEqual(index.point(at: offset),
                               Point(row: position, column: (offset - expectedStarts[position]) * 2),
                               "iteration=\(iteration) offset=\(offset)")
            }
            XCTAssertNil(index.point(at: size + 1))
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
