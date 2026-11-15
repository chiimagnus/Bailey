import XCTest
@testable import Bailey

@MainActor
final class GitGraphSelectionTests: XCTestCase {
    private let rows = ["head", "side", "middle", "older", "root"]

    func testOrdinaryClickAndCommandClickManageSelectionIndependentOfHistory() {
        var selection = RecentCommitsView.Selection()
        selection.select("head", visible: rows)
        XCTAssertEqual(selection.ids, ["head"])
        selection.select("middle", visible: rows, toggling: true)
        XCTAssertEqual(selection.ids, Set(["head", "middle"]))
        selection.select("middle", visible: rows, toggling: true)
        XCTAssertEqual(selection.ids, ["head"])
        selection.select("older", visible: rows)
        XCTAssertEqual(selection.ids, ["older"])
    }

    func testShiftUsesVisualOrderNotGitAncestryAndShrinksWithoutLosingIslands() {
        var selection = RecentCommitsView.Selection()
        selection.select("head", visible: rows)
        selection.select("older", visible: rows, toggling: true)
        selection.select("middle", visible: rows, extending: true)
        XCTAssertEqual(selection.ids, Set(["head", "middle", "older"]))
        selection.select("side", visible: rows, extending: true)
        XCTAssertEqual(selection.ids, Set(["head", "side", "middle", "older"]))
        selection.select("older", visible: rows, extending: true)
        XCTAssertEqual(selection.ids, Set(["head", "older"]))
    }

    func testAllEscapeAndReconciliationDoNotChangeFocusOrInventRows() {
        var selection = RecentCommitsView.Selection()
        selection.selectAll(visible: rows)
        XCTAssertEqual(selection.ids, Set(rows))
        selection.reconcile(visible: ["root", "older", "head"])
        XCTAssertEqual(selection.ids, Set(["root", "older", "head"]))
        selection.clear()
        XCTAssertTrue(selection.ids.isEmpty)
        selection.select("missing", visible: rows)
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testModifierSelectionOfGraphDetailRowsIsNotSquashSelection() {
        var selection = RecentCommitsView.Selection()
        selection.select("head", visible: rows)
        selection.select("head-file", visible: ["head", "head-file", "side"], toggling: true)
        XCTAssertEqual(selection.ids, Set(["head", "head-file"]))
        selection.select("head-file", visible: ["head", "head-file", "side"])
        XCTAssertEqual(selection.ids, ["head-file"])
    }

    func testVisibleCommitRangeCanSkipSyntheticGraphNodesAndNestedRows() {
        let graph = ["worktree", "head", "file", "stash", "side", "root"]
        let commits = graph.filter { ["head", "side", "root"].contains($0) }
        var selection = RecentCommitsView.Selection()
        selection.select("head", visible: commits)
        selection.select("root", visible: commits, extending: true)
        XCTAssertEqual(selection.ids, Set(["head", "side", "root"]))
        XCTAssertFalse(selection.ids.contains("stash"))
        XCTAssertFalse(selection.ids.contains("worktree"))
        XCTAssertFalse(selection.ids.contains("file"))
    }

    func testReconcilePrunesRemovedAnchorAndOnlyInvisibleSelection() {
        var selection = RecentCommitsView.Selection()
        selection.select("head", visible: rows)
        selection.select("middle", visible: rows, extending: true)
        XCTAssertEqual(selection.ids, Set(["head", "side", "middle"]))
        selection.reconcile(visible: ["side", "middle", "older", "root"])
        XCTAssertEqual(selection.ids, Set(["side", "middle"]))
        XCTAssertNil(selection.anchor)
        selection.select("older", visible: ["side", "middle", "older", "root"],
                         extending: true, fallbackAnchor: "middle")
        XCTAssertEqual(selection.ids, Set(["side", "middle", "older"]))
    }

    func testShiftWithoutValidAnchorUsesFocusedRow() {
        var selection = RecentCommitsView.Selection()
        selection.select("older", visible: rows, extending: true, fallbackAnchor: "side")
        XCTAssertEqual(selection.ids, Set(["side", "middle", "older"]))
        selection.clear()
        selection.select("older", visible: rows, extending: true)
        XCTAssertEqual(selection.ids, Set(["older"]))
    }
}
