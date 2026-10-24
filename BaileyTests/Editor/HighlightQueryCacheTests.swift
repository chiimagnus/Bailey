import Foundation
import SwiftTreeSitter
import XCTest
@testable import Bailey

@MainActor
final class HighlightQueryCacheTests: XCTestCase {
    func testFixedQueryFailuresAreRememberedPerGrammarAndKind() async throws {
        let language = try XCTUnwrap(SyntaxHighlighting.language(for: "fixture.swift"))
        let valid = Data("(_) @keyword".utf8)
        let invalid = Data("(not_a_real_node) @keyword".utf8)
        for kind in [HighlightQueryCache.Kind.highlights, .injections] {
            let cache = HighlightQueryCache()
            let failed = await cache.query(for: language, kind: kind, data: invalid)
            XCTAssertNil(failed)
            XCTAssertTrue(cache.isComplete(language, kind: kind))
            for _ in 0..<4 {
                let repeated = await cache.query(for: language, kind: kind, data: valid)
                XCTAssertNil(repeated, "Fixed resources have no hot-reload/retry path")
            }
            let otherKind: HighlightQueryCache.Kind = kind == .highlights ? .injections : .highlights
            let otherQuery = await cache.query(for: language, kind: otherKind, data: valid)
            XCTAssertNotNil(otherQuery)
            let tsxQuery = await cache.query(for: .tsx, kind: kind, data: valid)
            XCTAssertNotNil(tsxQuery)
        }
    }

    func testConcurrentAndCancelledWaitersShareTheSameImmutableQuery() async throws {
        let cache = HighlightQueryCache()
        let language = try XCTUnwrap(SyntaxHighlighting.language(for: "fixture.ts"))
        let data = SyntaxHighlighting.highlightsData(for: language)
        let first = Task { await cache.query(for: language, data: data) }
        let second = Task { await cache.query(for: language, data: data) }
        first.cancel()
        let firstResult = await first.value
        let secondResult = await second.value
        let firstQuery = try XCTUnwrap(firstResult)
        let secondQuery = try XCTUnwrap(secondResult)
        XCTAssertTrue(firstQuery === secondQuery)
        XCTAssertTrue(cache.cached(language) === secondQuery)
        let tsxResult = await cache.query(for: .tsx, data: SyntaxHighlighting.highlightsData(for: .tsx))
        let tsx = try XCTUnwrap(tsxResult)
        XCTAssertFalse(tsx === secondQuery)
    }
}
