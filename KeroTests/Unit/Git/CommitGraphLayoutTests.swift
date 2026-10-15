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
        XCTAssertTrue(graph.rows[0].links.contains(.depart(from: 0, to: 1, color: 1)))
        XCTAssertTrue(graph.rows[1].links.contains(.incoming(.init(lane: 1, color: 1))))
        XCTAssertTrue(graph.rows[2].links.contains(.through(.init(lane: 1, color: 1))))
        XCTAssertTrue(graph.rows[3].links.contains(.arrive(from: 1, to: 0, color: 1)))
        XCTAssertTrue(graph.rows[1].bottomRails.contains(.init(lane: 1, color: 1)))
    }

    func testSideBranchMergeConnectsBothActualParentsAtTheirNodes() {
        let graph = CommitGraphLayout(commits: [
            commit("tip", parents: ["main"], current: true),
            commit("merge", parents: ["side", "main"]),
            commit("main", parents: ["base"]),
            commit("side", parents: ["base"]),
            commit("base"),
        ])
        XCTAssertEqual(graph.rows.map(\.node.lane), [0, 1, 0, 1, 0])
        let green = graph.rows[1].node.color
        let rail = CommitGraphLayout.Rail(lane: 1, color: green)

        XCTAssertTrue(graph.rows[1].links.contains(.outgoing(rail)))
        XCTAssertFalse(graph.rows[1].links.contains(
            .depart(from: 1, to: 0, color: green)
        ), "Merge second parent must not jump to the main rail at the child node")
        XCTAssertTrue(graph.rows[2].links.contains(
            .arrive(from: 1, to: 0, color: green)
        ), "Merge second parent must connect to its real main parent node")
        XCTAssertTrue(graph.rows[3].links.contains(.incoming(rail)),
                      "Merge first parent must still connect to the side node")
    }

    func testCrossLaneMergeAvoidsPassingThroughUnrelatedCommitNodes() {
        let graph = CommitGraphLayout(commits: [
            commit("tip", parents: ["main-middle"], current: true),
            commit("merge", parents: ["side-older", "main-base"]),
            commit("main-middle", parents: ["main-base"]),
            commit("side-older", parents: ["root"]),
            commit("main-base", parents: ["root"]),
            commit("root"),
        ])
        XCTAssertEqual(graph.rows.map(\.node.lane), [0, 1, 0, 1, 0, 0])
        let green = graph.rows[1].node.color
        let clear = CommitGraphLayout.Rail(lane: 2, color: green)
        XCTAssertEqual(graph.laneCount, 3,
                       "When both endpoint lanes contain unrelated nodes, reserve a clear edge lane")
        XCTAssertTrue(graph.rows[1].links.contains(.depart(from: 1, to: 2, color: green)))
        XCTAssertTrue(graph.rows[2].links.contains(.through(clear)))
        XCTAssertTrue(graph.rows[3].links.contains(.through(clear)))
        XCTAssertTrue(graph.rows[4].links.contains(.arrive(from: 2, to: 0, color: green)))
        XCTAssertFalse(graph.rows[2].links.contains(.through(.init(lane: 0, color: green))))
        XCTAssertFalse(graph.rows[3].links.contains(.through(.init(lane: 1, color: green))))
        XCTAssertTrue(graph.rows[3].links.contains(.incoming(.init(lane: 1, color: green))),
                      "The side branch's first-parent edge remains on its own node")
    }

    func testMergeWithTwoParentsOnMainRailEndsAtEachParent() {
        let graph = CommitGraphLayout(commits: [
            commit("head", parents: ["near"], current: true),
            commit("merge", parents: ["deep", "near"]),
            commit("near", parents: ["middle"]),
            commit("middle", parents: ["deep"]),
            commit("deep", parents: ["root"]),
            commit("root"),
        ])
        XCTAssertEqual(graph.rows.map(\.node.lane), [0, 1, 0, 0, 0, 0])
        let green = graph.rows[1].node.color
        let sideRail = CommitGraphLayout.Rail(lane: 1, color: green)
        XCTAssertTrue(graph.rows[1].links.contains(.outgoing(sideRail)))
        XCTAssertEqual(graph.rows[1].links.filter { $0 == .outgoing(sideRail) }.count, 1)
        XCTAssertTrue(graph.rows[2].links.contains(.arrive(from: 1, to: 0, color: green)),
                      "The near second-parent must receive its own connection")
        XCTAssertTrue(graph.rows[2].links.contains(.through(sideRail)),
                      "The other parent edge must continue separately to the distant parent")
        XCTAssertTrue(graph.rows[3].links.contains(.through(sideRail)))
        XCTAssertTrue(graph.rows[4].links.contains(.arrive(from: 1, to: 0, color: green)),
                      "The first-parent connection must end at its actual node")
        XCTAssertFalse(graph.rows[2].links.contains(.through(.init(lane: 0, color: green))))
    }

    func testEmptyHistoryDoesNotReserveAVisualLane() {
        let graph = CommitGraphLayout(commits: [])
        XCTAssertEqual(graph.laneCount, 0)
        XCTAssertTrue(graph.rows.isEmpty)
    }

    func testUnloadedHeadDoesNotMarkAnotherBranchAsCurrentMain() {
        // A paged Git history may omit HEAD while still showing unrelated branch commits.
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
