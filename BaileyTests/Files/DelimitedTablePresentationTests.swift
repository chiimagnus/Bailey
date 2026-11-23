import AppKit
import Foundation
import XCTest
@testable import Bailey

@MainActor
final class DelimitedTablePresentationTests: XCTestCase {
    func testNativeGridVirtualizesTallAndWideTablesAndCanReachTheirLastCells() async throws {
        let viewport = CGRect(x: 0, y: 0, width: 480, height: 330)
        let window = NSWindow(contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let grid = DelimitedGrid()
        window.contentView = grid
        let tall = "Name,Value\n" + (0..<100_000).map { "Row \($0),\($0)\n" }.joined()
        let wide = (0..<2501).map { "column \($0)" }.joined(separator: ",") + "\n"
            + (0..<2501).map { "cell \($0)" }.joined(separator: ",")
        for (source, row, column, expected) in [
            (tall, 99_999, 1, "99999"),
            (wide, 0, 2500, "cell 2500"),
        ] {
            let index = try await DelimitedTableIndex.parse(source, preferred: .comma)
            let presentation = try await DelimitedTablePresentation.evaluate(
                source: source, index: index, configuration: .init()
            )
            grid.install(.init(index: index, source: source, requestID: expected, preservesOriginalBytes: true),
                         presentation: presentation)
            grid.layoutSubtreeIfNeeded()
            grid.table.select(.init(row: row, column: column), reveal: true)
            grid.layoutSubtreeIfNeeded()
            XCTAssertTrue(grid.table.frameOfCell(atColumn: column, row: row).intersects(grid.table.visibleRect))
            let field = try XCTUnwrap(grid.table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)
            XCTAssertEqual(field.stringValue, expected)
            XCTAssertTrue(field.isAccessibilitySelected())
            var realizedRows = 0
            grid.table.enumerateAvailableRowViews { _, _ in realizedRows += 1 }
            XCTAssertLessThan(realizedRows, 100)
        }
        grid.detach()
        XCTAssertEqual(grid.table.numberOfRows, 0)
    }

    func testSortedAndFilteredRowsRetainSourceIdentityAndFindQuotedCells() async throws {
        let source = "Name,Group,Value\r\nItem 10,Équipe,blue\r\nItem 2,equipe,\"blue\r\nred\"\r\nItem 3,Other,blue\r\n"
        let index = try await DelimitedTableIndex.parse(source, preferred: .comma)
        let configuration = DelimitedTablePresentation.Configuration(
            filters: [1: "equipe", 2: "blue"], sort: [.init(column: 0, ascending: true)]
        )
        let ordered = try await DelimitedTablePresentation.evaluate(
            source: source, index: index, configuration: configuration
        )
        XCTAssertEqual(ordered.rows, [2, 1])
        let matches = try await ordered.find("red", source: source, index: index, columnCount: 3)
        XCTAssertEqual(matches, [.init(row: 0, column: 2)])
        let original = source as NSString
        XCTAssertEqual(original.substring(with: index.records[2].source),
                       "Item 2,equipe,\"blue\r\nred\"\r\n")
        let reset = try await DelimitedTablePresentation.evaluate(
            source: source, index: index, configuration: .init(header: false)
        )
        XCTAssertEqual(reset.rows, [0, 1, 2, 3])
    }

    func testCopyUsesSelectedCellsInDisplayOrderWithoutLosingQuotesOrLineBreaks() async throws {
        let source = "Name,Text,Value\r\nB,\"a\"\"b\r\nc\",20\r\nA,one,10"
        let index = try await DelimitedTableIndex.parse(source, preferred: .comma)
        let ordered = try await DelimitedTablePresentation.evaluate(
            source: source, index: index, configuration: .init(sort: [.init(column: 0, ascending: true)])
        )
        var selection = DelimitedTablePresentation.Selection()
        selection.select(.init(row: 0, column: 0))
        selection.select(.init(row: 1, column: 1), adding: true)
        let copied = try await ordered.copy(selection, source: source, index: index)
        XCTAssertEqual(copied, "A\t\n\t\"a\"\"b\r\nc\"")
        selection.select(.init(row: 0, column: 1))
        selection.select(.init(row: 1, column: 2), extending: true)
        let rectangle = try await ordered.copy(selection, source: source, index: index)
        XCTAssertEqual(rectangle, "one\t10\n\"a\"\"b\r\nc\"\t20")
    }

    func testLargeDisplayEvaluatesOnDemandAndCanceledSearchHasNoResult() async throws {
        let source = "Name,Group\n" + (0..<100_000).map { "Item \($0),\($0 % 2)\n" }.joined()
        let index = try await DelimitedTableIndex.parse(source, preferred: .comma)
        let display = try await DelimitedTablePresentation.evaluate(
            source: source, index: index,
            configuration: .init(filters: [1: "1"], sort: [.init(column: 0, ascending: false)])
        )
        XCTAssertEqual(display.rows.count, 50_000)
        XCTAssertEqual(display.rows.first, 100_000)
        XCTAssertEqual(display.rows.last, 2)
        let search = Task { try await display.find("Item", source: source, index: index, columnCount: 2) }
        search.cancel()
        do {
            _ = try await search.value
            XCTFail("Canceled view search must not publish matches")
        } catch is CancellationError {}
    }
}
