import XCTest
@testable import kero

@MainActor
final class CommitGraphLayoutTests: XCTestCase {
    private func commit(
        _ hash: String, parents: [String] = [],
        current: Bool = false
    ) -> GitStatusModel.RecentCommit {
        .init(
            hash: hash, shortHash: hash, subject: hash, author: "Test",
            date: .distantPast, parentHashes: parents,
            references: current ? [.init(kind: .currentBranch, name: "main")] : [],
            files: []
        )
    }

    func testLinearHistoryUsesOneLaneAndEndsAtRoot() {
        let graph = CommitGraphLayout(commits: [
            commit("C", parents: ["B"], current: true),
            commit("B", parents: ["A"]),
            commit("A"),
        ])
        XCTAssertEqual(graph.laneCount, 1)
        XCTAssertEqual(graph.rows.map(\.node.lane), [0, 0, 0])
        XCTAssertTrue(graph.rows[0].links.contains(.outgoing(.init(lane: 0, color: 0))))
        XCTAssertTrue(graph.rows[1].links.contains(.incoming(.init(lane: 0, color: 0))))
        XCTAssertTrue(graph.rows[2].bottomRails.isEmpty)
    }

    func testOverlappingSideBranchesOccupyDistinctLanes() {
        let graph = CommitGraphLayout(commits: [
            commit("left", parents: ["root"]),
            commit("right", parents: ["root"]),
            commit("main", parents: ["root"], current: true),
            commit("root"),
        ])
        XCTAssertEqual(graph.rows.map(\.node.lane), [1, 2, 0, 0])
        XCTAssertEqual(graph.laneCount, 3)
        XCTAssertNotEqual(graph.rows[0].node.color, graph.rows[1].node.color)
        XCTAssertEqual(graph.rows[1].bottomRails.count, 2)
    }

    func testMergeEdgesFollowRealParentsAcrossIntermediateRows() {
        let graph = CommitGraphLayout(commits: [
            commit("merge", parents: ["base", "side"], current: true),
            commit("side", parents: ["root"]),
            commit("base", parents: ["root"]),
            commit("root"),
        ])
        XCTAssertEqual(graph.rows.map(\.node.lane), [0, 1, 0, 0])
        XCTAssertTrue(graph.rows[0].links.contains(
            .curve(fromX: 0, fromY: 0.5, control1X: 0, control2X: 0.25,
                   toX: 0.5, toY: 1, color: 1)
        ))
        XCTAssertTrue(graph.rows[1].links.contains(
            .curve(fromX: 0.5, fromY: 0, control1X: 0.75, control2X: 1,
                   toX: 1, toY: 0.5, color: 1)
        ))
        XCTAssertTrue(graph.rows[2].links.contains(
            .curve(fromX: 0.84375, fromY: 0, control1X: 0.65625, control2X: 0.34375,
                   toX: 0.15625, toY: 1, color: 1)
        ))
        XCTAssertTrue(graph.rows[3].links.contains(
            .curve(fromX: 0.15625, fromY: 0, control1X: 0.0625, control2X: 0,
                   toX: 0, toY: 0.5, color: 1)
        ))
        XCTAssertTrue(graph.rows[1].bottomRails.contains(.init(lane: 0.84375, color: 1)))
    }

    func testCrossLaneParentEdgeDoesNotJoinAnUnrelatedVerticalRail() {
        let graph = CommitGraphLayout(commits: [
            commit("merge", parents: ["main", "side"], current: true),
            commit("side", parents: ["root"]),
            commit("main", parents: ["root"]),
            commit("root"),
        ])
        let sideColor = graph.rows[1].node.color
        XCTAssertFalse(graph.rows[2].links.contains(.through(.init(lane: 1, color: sideColor))),
                       "A side-parent connection must be a direct diagonal, not a vertical line followed by a bend")
        let segments = [
            (row: 1, fromX: 1.0, fromY: 0.5, c1: 1.0, c2: 0.9375, toX: 0.84375, toY: 1.0),
            (row: 2, fromX: 0.84375, fromY: 0.0, c1: 0.65625, c2: 0.34375, toX: 0.15625, toY: 1.0),
            (row: 3, fromX: 0.15625, fromY: 0.0, c1: 0.0625, c2: 0.0, toX: 0.0, toY: 0.5),
        ]
        for segment in segments {
            XCTAssertTrue(graph.rows[segment.row].links.contains(.curve(
                fromX: segment.fromX, fromY: segment.fromY,
                control1X: segment.c1, control2X: segment.c2,
                toX: segment.toX, toY: segment.toY, color: sideColor
            )), "Each row must contain the correct piece of the same node-to-node curve")
        }
    }

    func testCrossLaneCurveEasesIntoTheActualParentNode() {
        let graph = CommitGraphLayout(commits: [
            commit("merge", parents: ["base", "side"], current: true),
            commit("side", parents: ["root"]),
            commit("base", parents: ["root"]),
            commit("root"),
        ])
        let firstSegment = graph.rows[1].links.compactMap { link -> (Double, Double, Double)? in
            if case .curve(let fromX, let fromY, let control1X, let control2X,
                           let toX, _, let color) = link,
               fromX == 1, fromY == 0.5, color == 1 {
                return (control1X, control2X, toX)
            }
            return nil
        }
        XCTAssertEqual(firstSegment.count, 1)
        if let segment = firstSegment.first {
            XCTAssertEqual(segment.0, 1, accuracy: 0.000001,
                           "Curve must leave the source node vertically")
            XCTAssertLessThan(segment.1, segment.0)
            XCTAssertGreaterThan(segment.2, 0.8,
                                 "Curve must ease away from the source, not trace a straight diagonal")
        }
    }

    func testUnloadedHeadDoesNotMarkAnotherBranchAsCurrentMain() {
        // Git --topo-order may return many commits from another branch before HEAD.
        let graph = CommitGraphLayout(commits: [
            commit("other-tip", parents: ["other-parent"]),
            commit("other-parent", parents: ["unloaded-main"]),
        ])
        XCTAssertEqual(graph.laneCount, 1)
        XCTAssertTrue(graph.rows.allSatisfy { $0.node.color != 0 },
                      "Blue must identify the loaded HEAD ancestry, not an arbitrary tip")
    }

    func testPaginationKeepsVisibleLaneAssignmentsAndNeverDrawsUnknownParents() {
        let prefix = [
            commit("main", parents: ["base"], current: true),
            commit("side", parents: ["root"]),
        ]
        let short = CommitGraphLayout(commits: prefix)
        XCTAssertTrue(short.rows.allSatisfy { $0.links.isEmpty })
        let longer = CommitGraphLayout(commits: prefix + [
            commit("base", parents: ["root"]),
            commit("root"),
        ])
        XCTAssertEqual(short.rows.map(\.node), Array(longer.rows.prefix(2)).map(\.node))
        XCTAssertTrue(longer.rows[0].links.contains(.outgoing(.init(lane: 0, color: 0))))
    }
}
