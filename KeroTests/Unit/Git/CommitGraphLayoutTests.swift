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

    private func assertConnected(
        _ graph: CommitGraphLayout, from child: Int, to parent: Int,
        color expectedColor: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        let source = graph.rows[child]
        let target = graph.rows[parent]
        let outgoing = source.links.compactMap { link -> CommitGraphLayout.Rail? in
            switch link {
            case .outgoing(let rail): rail
            case .depart(let from, let to, let color) where from == source.node.lane:
                .init(lane: to, color: color)
            default: nil
            }
        }
        let connected = outgoing.contains { rail in
            guard rail.color == expectedColor else { return false }
            let reachesParent = target.links.contains {
                switch $0 {
                case .incoming(let arrival): arrival == rail
                case .arrive(let from, let to, let color):
                    from == rail.lane && to == target.node.lane && color == rail.color
                default: false
                }
            }
            return reachesParent && ((child + 1)..<parent).allSatisfy {
                graph.rows[$0].links.contains(.through(rail))
            }
        }
        XCTAssertTrue(connected,
                      "Missing same-color path from row \(child) to real parent \(parent)",
                      file: file, line: line)
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
        XCTAssertEqual(Set(graph.rows.prefix(3).map(\.node.lane)).count, 3)
        XCTAssertEqual(graph.laneCount, 3)
        XCTAssertEqual(Set(graph.rows.prefix(3).map(\.node.color)).count, 3)
        for tip in 0..<3 {
            assertConnected(graph, from: tip, to: 3,
                            color: graph.rows[tip].node.color)
        }
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
        let merge = graph.rows[1].node
        let main = graph.rows[2].node
        let side = graph.rows[3].node
        XCTAssertEqual(merge.color, side.color)
        XCTAssertNotEqual(merge.color, main.color)
        assertConnected(graph, from: 1, to: 3, color: side.color)
        assertConnected(graph, from: 1, to: 2, color: main.color)
        XCTAssertFalse(graph.rows[2].links.contains(.through(.init(
            lane: main.lane, color: side.color
        ))), "The side-branch edge must not pass through the unrelated main node")
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
        let side = graph.rows[3].node
        let main = graph.rows[4].node
        XCTAssertEqual(graph.laneCount, 3,
                       "Occupied endpoint lanes require a third, node-free transit lane")
        let rail = CommitGraphLayout.Rail(lane: 2, color: main.color)
        XCTAssertTrue(graph.rows[1].links.contains(.depart(
            from: graph.rows[1].node.lane, to: 2, color: main.color
        )))
        XCTAssertTrue(graph.rows[2].links.contains(.through(rail)))
        XCTAssertTrue(graph.rows[3].links.contains(.through(rail)))
        XCTAssertTrue(graph.rows[4].links.contains(.arrive(
            from: 2, to: main.lane, color: main.color
        )))
        for intermediate in 2...3 {
            XCTAssertNotEqual(graph.rows[intermediate].node.lane, rail.lane)
        }
        assertConnected(graph, from: 1, to: 3, color: side.color)
        assertConnected(graph, from: 1, to: 4, color: main.color)
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
        let merge = graph.rows[1].node
        let near = graph.rows[2].node
        let deep = graph.rows[4].node
        XCTAssertNotEqual(merge.color, near.color)
        XCTAssertEqual(deep.color, near.color)
        assertConnected(graph, from: 1, to: 4, color: merge.color)
        assertConnected(graph, from: 1, to: 2, color: near.color)
        XCTAssertTrue(graph.rows[2].links.contains(.incoming(.init(
            lane: near.lane, color: near.color
        ))), "The nearer parent gets its own edge without borrowing the side path")
        let sideRail = CommitGraphLayout.Rail(lane: merge.lane, color: merge.color)
        XCTAssertTrue(graph.rows[2].links.contains(.through(sideRail)))
        XCTAssertTrue(graph.rows[3].links.contains(.through(sideRail)))
        XCTAssertFalse(graph.rows[2].links.contains(.through(.init(
            lane: near.lane, color: merge.color
        ))))
    }

    func testMergeLinksUseTheJoinedBranchColorInsteadOfTheChildLane() {
        let graph = CommitGraphLayout(commits: [
            commit("tip", parents: ["main"], current: true),
            commit("merge", parents: ["side", "main"]),
            commit("main", parents: ["base"]),
            commit("side", parents: ["base"]),
            commit("base"),
        ])
        let merge = graph.rows[1]
        let main = graph.rows[2]
        let side = graph.rows[3]
        XCTAssertNotEqual(merge.node.color, main.node.color)
        XCTAssertEqual(merge.node.color, side.node.color)
        assertConnected(graph, from: 1, to: 2, color: main.node.color)
        assertConnected(graph, from: 1, to: 3, color: side.node.color)
        XCTAssertTrue(merge.links.contains(.depart(
            from: merge.node.lane, to: main.node.lane, color: main.node.color
        )), "A merged-in branch must retain its own path color")
    }

    func testUnrelatedTipPrecedingHEADKeepsItsOwnPathColor() {
        let graph = CommitGraphLayout(commits: [
            commit("unrelated", parents: ["common"]),
            commit("checked-out", parents: ["common"], current: true),
            commit("common"),
        ])
        XCTAssertEqual(graph.rows[0].node.color, 0)
        XCTAssertNotEqual(graph.rows[0].node.color, graph.rows[1].node.color)
        XCTAssertTrue(graph.rows[0].links.contains(.outgoing(.init(
            lane: graph.rows[0].node.lane, color: graph.rows[0].node.color
        ))))
    }

    func testPaginationPreservesOpenTipColorsAndLanes() {
        let initial = [
            commit("head", parents: ["A"], current: true),
            commit("other", parents: ["B"]),
        ]
        let partial = CommitGraphLayout(commits: initial)
        let more = CommitGraphLayout(commits: initial + [
            commit("A", parents: ["root"]),
            commit("B", parents: ["root"]),
            commit("root"),
        ])
        XCTAssertEqual(partial.rows.map(\.node), Array(more.rows.prefix(2)).map(\.node))
        XCTAssertFalse(more.rows[0].links.isEmpty)
        XCTAssertFalse(more.rows[1].links.isEmpty)
    }

    func testOctopusMergePreservesAllParentPathsAndColors() {
        let commits = [
            commit("merge", parents: ["main", "side-a", "side-b"], current: true),
            commit("side-a", parents: ["root"]),
            commit("side-b", parents: ["root"]),
            commit("main", parents: ["root"]),
            commit("root"),
        ]
        let graph = CommitGraphLayout(commits: commits)
        for (offset, parent) in [3, 1, 2].enumerated() {
            let color = offset == 0 ? graph.rows[0].node.color : graph.rows[parent].node.color
            assertConnected(graph, from: 0, to: parent, color: color)
        }
        for node in graph.rows {
            for link in node.links {
                if case .through(let rail) = link {
                    XCTAssertNotEqual(rail.lane, node.node.lane,
                                      "An intermediate line must not pass through a commit node")
                }
            }
        }
    }

    func testStashNodesDoNotTakeOverRegularCommitPaths() throws {
        let oid = String(repeating: "f", count: 40)
        let base = "base"
        let stashOne = GitStatusModel.Stash(
            selector: "stash@{0}", oid: oid, message: "first", baseHash: base,
            untrackedFilesHash: nil, author: "Test", date: .distantPast
        )
        let stashTwo = GitStatusModel.Stash(
            selector: "stash@{1}", oid: oid, message: "second", baseHash: base,
            untrackedFilesHash: nil, author: "Test", date: .distantPast
        )
        let entries = GitStatusModel.graphCommits([
            commit("head", parents: [base], current: true), commit(base),
        ], stashes: [stashOne, stashTwo])
        let graph = CommitGraphLayout(commits: entries)
        let head = try XCTUnwrap(entries.firstIndex { $0.hash == "head" })
        let ancestor = try XCTUnwrap(entries.firstIndex { $0.hash == base })
        let stashIndices = Array(entries.indices.filter { entries[$0].stash != nil })
        XCTAssertEqual(stashIndices.count, 2)
        XCTAssertNotEqual(entries[stashIndices[0]].id, entries[stashIndices[1]].id)
        XCTAssertEqual(graph.rows[head].node.lane, 0)
        XCTAssertEqual(graph.rows[head].node.color, 0)
        assertConnected(graph, from: head, to: ancestor, color: 0)
        for i in stashIndices {
            XCTAssertNotEqual(graph.rows[i].node.lane, graph.rows[head].node.lane)
            assertConnected(graph, from: i, to: ancestor, color: graph.rows[i].node.color)
        }

        let paged = GitStatusModel.graphCommits([commit("head", current: true)],
                                                stashes: [stashOne, stashTwo])
        let withoutBase = CommitGraphLayout(commits: paged)
        for index in paged.indices where paged[index].stash != nil {
            XCTAssertTrue(withoutBase.rows[index].links.isEmpty,
                          "A stash with unloaded base must not invent an edge")
        }
    }

    func testThirtyParallelTipsReusePaletteWithoutOverlappingNodes() {
        let tips = (0..<30).map { commit("tip-\($0)", parents: ["root"]) }
        let graph = CommitGraphLayout(commits: tips + [commit("root")])
        XCTAssertEqual(graph.laneCount, 30)
        XCTAssertEqual(Set(graph.rows.prefix(30).map(\.node.lane)).count, 30)
        XCTAssertEqual(Set(graph.rows.prefix(30).map(\.node.color)).count, 12)
        for tip in 0..<30 {
            assertConnected(graph, from: tip, to: 30, color: graph.rows[tip].node.color)
        }
    }

    func testThousandLinearCommitsDoNotCreateExtraLanes() {
        let commits = (0..<1_000).map { index in
            commit("commit-\(index)", parents: index == 999 ? [] : ["commit-\(index + 1)"])
        }
        let graph = CommitGraphLayout(commits: commits)
        XCTAssertEqual(graph.rows.count, 1_000)
        XCTAssertEqual(graph.laneCount, 1)
        XCTAssertTrue(graph.rows.allSatisfy { $0.node.color == 0 })
        XCTAssertTrue(graph.rows.last?.bottomRails.isEmpty == true)
    }

    func testEmptyHistoryDoesNotReserveAVisualLane() {
        let graph = CommitGraphLayout(commits: [])
        XCTAssertEqual(graph.laneCount, 0)
        XCTAssertTrue(graph.rows.isEmpty)
    }

    func testUnloadedHeadDoesNotInventPhantomEdgesOrReserveAColor() {
        // A paged Git history may omit HEAD while still showing unrelated branch commits.
        let graph = CommitGraphLayout(commits: [
            commit("other-tip", parents: ["other-parent"]),
            commit("other-parent", parents: ["unloaded-main"]),
        ])
        XCTAssertEqual(graph.laneCount, 1)
        XCTAssertEqual(graph.rows[0].node.color, 0,
                       "Palette starts at blue regardless of HEAD identity")
        XCTAssertEqual(graph.rows[0].node.lane, graph.rows[1].node.lane)
        XCTAssertTrue(graph.rows[1].links.allSatisfy {
            if case .outgoing = $0 { return false }
            if case .depart = $0 { return false }
            return true
        }, "Unloaded parents cannot produce phantom outgoing edges")
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
