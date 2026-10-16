import Foundation
import XCTest
@testable import kero

final class DiffEngineTests: XCTestCase {
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
