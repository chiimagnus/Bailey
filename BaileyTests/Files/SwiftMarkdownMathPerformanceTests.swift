import Darwin
import Foundation
import XCTest
@testable import Bailey

@MainActor
final class SwiftMarkdownMathPerformanceTests: XCTestCase {
    func testCancelledLongMarkdownParseCannotReturnASnapshot() async throws {
        let source = (0..<20_000).map { index in
            "## Heading \(index) 中文🙂\n\nText with **bold** and [link](guide.md)."
        }.joined(separator: "\n\n")
        let pending = Task { try await MarkdownDocument.parse(source) }
        try await Task.sleep(for: .milliseconds(10))
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("A cancelled long parse must not publish an obsolete snapshot")
        } catch is CancellationError {
            // The preview's request identity check additionally rejects stale completions.
        }
    }

    func testLargeMixedMathAndCodeStaysComplete() async throws {
        for count in [500, 5_000, 20_000] {
            let source = (0..<count).map { index in
                switch index % 10 {
                case 0: "Equation \(index) $x_{i}*y_{j}$ and prose."
                case 1: "Literal \(index) " + String(UnicodeScalar(96)!) + "$not_a_formula$"
                    + String(UnicodeScalar(96)!)
                case 2: "Link \(index) [navigation](docs/guide.md)."
                default: "Ordinary paragraph \(index) contains **strong**."
                }
            }.joined(separator: "\n\n")
            let clock = ContinuousClock()
            let start = clock.now
            let document = try await MarkdownDocument.parse(source)
            let elapsed = start.duration(to: clock.now)
            XCTAssertEqual(document.blocks.count, count)
            var expressionCount = 0
            for block in document.blocks {
                if case let .paragraph(inline) = block.content {
                    for fragment in inline {
                        if case let .math(latex, _) = fragment {
                            XCTAssertEqual(latex, "x_{i}*y_{j}")
                            expressionCount += 1
                        }
                    }
                }
            }
            XCTAssertEqual(expressionCount, count / 10)
            var usage = rusage()
            _ = getrusage(RUSAGE_SELF, &usage)
            print("SWIFTMARKDOWN_MATH_SOURCE paragraphs=\(count) formulae=\(expressionCount) "
                  + "parse=\(elapsed) peak_rss_mib=\(Double(usage.ru_maxrss) / 1_048_576)")
        }
    }
}
