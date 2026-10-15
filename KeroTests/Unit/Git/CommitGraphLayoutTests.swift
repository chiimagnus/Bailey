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
            .diagonal(fromX: 0, fromY: 0.5, toX: 0.5, toY: 1, color: 1)
        ))
        XCTAssertTrue(graph.rows[1].links.contains(
            .diagonal(fromX: 0.5, fromY: 0, toX: 1, toY: 0.5, color: 1)
        ))
        XCTAssertTrue(graph.rows[2].links.contains(
            .diagonal(fromX: 0.75, fromY: 0, toX: 0.25, toY: 1, color: 1)
        ))
        XCTAssertTrue(graph.rows[3].links.contains(
            .diagonal(fromX: 0.25, fromY: 0, toX: 0, toY: 0.5, color: 1)
        ))
        XCTAssertTrue(graph.rows[1].bottomRails.contains(.init(lane: 0.75, color: 1)))
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
            (row: 1, startX: 1.0, startY: 0.5, endX: 0.75, endY: 1.0),
            (row: 2, startX: 0.75, startY: 0.0, endX: 0.25, endY: 1.0),
            (row: 3, startX: 0.25, startY: 0.0, endX: 0.0, endY: 0.5),
        ]
        for segment in segments {
            XCTAssertTrue(graph.rows[segment.row].links.contains(.diagonal(
                fromX: segment.startX, fromY: segment.startY,
                toX: segment.endX, toY: segment.endY, color: sideColor
            )), "Each row must contain its exact portion of the same node-to-node line")
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
