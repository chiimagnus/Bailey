import XCTest
@testable import Bailey

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

    func testWorktreeNodesUseRealHeadsWithoutBecomingCommitsOrChangingHeadAncestors() {
        let head = String(repeating: "a", count: 40)
        let root = String(repeating: "b", count: 40)
        let commits = [commit(head, parents: [root], current: true), commit(root)]
        let changes = [
            GitStatusModel.WorktreeChanges(
                path: "/tmp/main", branch: "main", headOID: head,
                entries: [.init(path: "file.txt", staged: ".", unstaged: "M")],
                isCurrent: true
            ),
            GitStatusModel.WorktreeChanges(
                path: "/tmp/worktree", branch: "feature", headOID: head,
                entries: [.init(path: "other.txt", staged: "?", unstaged: "?")],
                isCurrent: false
            )
        ]
        let rows = GitStatusModel.graphCommits(commits, stashes: [], worktrees: changes)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.compactMap(\.worktree).count, 2)
        XCTAssertTrue(rows.prefix(2).allSatisfy { $0.worktree != nil })
        XCTAssertEqual(rows.suffix(2).map(\.hash), [head, root])
        let layout = CommitGraphLayout(commits: rows)
        XCTAssertEqual(layout.knownHeadHistory, Set([head, root]))
        assertConnected(layout, from: 0, to: 2, color: layout.rows[0].node.color)
        assertConnected(layout, from: 1, to: 2, color: layout.rows[1].node.color)
        assertConnected(layout, from: 2, to: 3, color: layout.rows[2].node.color)
    }

    func testUnknownWorktreeHeadRemainsVisibleWithoutInventingAParentLine() {
        let head = String(repeating: "c", count: 40)
        let missingHead = String(repeating: "d", count: 40)
        let orphan = GitStatusModel.WorktreeChanges(
            path: "/tmp/detached", branch: nil, headOID: missingHead,
            entries: [.init(path: "new.txt", staged: "?", unstaged: "?")],
            isCurrent: false
        )
        let rows = GitStatusModel.graphCommits([commit(head, current: true)],
                                                 stashes: [], worktrees: [orphan])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].worktree?.path, orphan.path)
        XCTAssertTrue(CommitGraphLayout(commits: rows).rows[0].links.isEmpty)
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

    func testDeterministicCrossMergeHistoriesConnectEveryLoadedParent() {
        var state: UInt64 = 0xA0B1_C2D3_E4F5
        func roll(_ count: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state % UInt64(count))
        }
        for _ in 0..<6 {
            let count = 120
            let history: [GitStatusModel.RecentCommit] = (0..<count).map { index in
                guard index < count - 1 else { return commit("id-119") }
                let first = index + 1 + roll(count - index - 1)
                var parents = ["id-\(first)"]
                if index < count - 2 && roll(3) == 0 {
                    let second = index + 1 + roll(count - index - 1)
                    if second != first { parents.append("id-\(second)") }
                }
                if index < count - 3 && roll(12) == 0 {
                    let third = index + 1 + roll(count - index - 1)
                    if !parents.contains("id-\(third)") { parents.append("id-\(third)") }
                }
                return commit("id-\(index)", parents: parents, current: index == 0)
            }
            let graph = CommitGraphLayout(commits: history)
            XCTAssertEqual(graph.rows.count, count)
            for (index, item) in history.enumerated() {
                for (offset, hash) in item.parentHashes.enumerated() {
                    let parent = Int(hash.dropFirst(3))!
                    let color = offset == 0
                        ? graph.rows[index].node.color : graph.rows[parent].node.color
                    assertConnected(graph, from: index, to: parent, color: color)
                }
                for link in graph.rows[index].links {
                    if case .through(let rail) = link {
                        XCTAssertNotEqual(rail.lane, graph.rows[index].node.lane,
                                          "Rails must not pass through unrelated commits")
                    }
                }
            }
        }
    }

    func testNonoverlappingMergeDetoursReuseTheSameFreeLane() {
        // Both extra parents are already reachable from each first parent.
        // Git permits these edges, and their transit intervals do not overlap.
        let commits = (0..<9).map { index -> GitStatusModel.RecentCommit in
            let first = index == 8 ? [] : ["n-\(index + 1)"]
            let other = index == 0 ? ["n-2"] : index == 4 ? ["n-6"] : []
            return commit("n-\(index)", parents: first + other, current: index == 0)
        }
        let graph = CommitGraphLayout(commits: commits)
        XCTAssertEqual(Set(graph.rows.map(\.node.lane)), [0])
        assertConnected(graph, from: 0, to: 2, color: graph.rows[2].node.color)
        assertConnected(graph, from: 4, to: 6, color: graph.rows[6].node.color)
        XCTAssertEqual(graph.laneCount, 2,
                       "Two disjoint detours must reuse one transit lane, not grow the gutter")
    }

    func testUnloadedStashBasesDoNotReserveInvisibleRails() {
        let stashes = (0..<40).map { index in
            GitStatusModel.Stash(
                selector: "stash@{\(index)}",
                oid: String(format: "%040x", index + 1),
                message: "Saved work",
                baseHash: "missing-base",
                untrackedFilesHash: nil,
                author: "Tester", date: .distantPast
            )
        }
        let commits = GitStatusModel.graphCommits([
            commit("head", parents: ["not-yet-loaded"], current: true)
        ], stashes: stashes)
        let graph = CommitGraphLayout(commits: commits)
        XCTAssertEqual(commits.count, 41)
        XCTAssertEqual(Set(commits.compactMap { $0.stash?.id }).count, 40)
        XCTAssertTrue(graph.rows.dropFirst().allSatisfy { $0.links.isEmpty })
        XCTAssertEqual(graph.laneCount, 2,
                       "Missing stash bases must not consume a new lane for each invisible edge")
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

    func testThousandRowsWithThirtyParallelRefsDoNotCreatePhantomConnections() {
        let sideTips = (0..<30).map { index in
            commit("side-\(index)", parents: ["root"])
        }
        let main = (0..<970).map { index in
            commit("main-\(index)", parents: [
                index == 969 ? "root" : "main-\(index + 1)"
            ], current: index == 0)
        }
        let history = sideTips + main + [commit("root")]
        var timings: [Double] = []
        for _ in 0..<30 {
            let start = ProcessInfo.processInfo.systemUptime
            let layout = CommitGraphLayout(commits: history)
            timings.append(ProcessInfo.processInfo.systemUptime - start)
            XCTAssertEqual(layout.laneCount, 31)
        }
        let sorted = timings.sorted()
        let graph = CommitGraphLayout(commits: history)
        print(String(format: "Git graph %d rows, 31 lanes, n=%d: median %.3f s, p95 %.3f s, max %.3f s",
                     history.count, timings.count, sorted[15], sorted[28], sorted[29]))
        XCTAssertEqual(graph.rows.count, 1_001)
        XCTAssertEqual(graph.laneCount, 31)
        XCTAssertEqual(graph.knownHeadHistory.count, 971)
        for index in [0, 15, 29] {
            assertConnected(graph, from: index, to: 1_000,
                            color: graph.rows[index].node.color)
        }
        XCTAssertFalse(graph.knownHeadHistory.contains("side-0"))
    }

    func testFiveThousandLoadedCommitsWithOneHundredFiftyLanesStayConnected() {
        let tips = (0..<149).map { commit("tip-\($0)", parents: ["root"]) }
        let main = (0..<4_850).map { index in
            commit("main-\(index)", parents: [
                index == 4_849 ? "root" : "main-\(index + 1)"
            ], current: index == 0)
        }
        let history = tips + main + [commit("root")]
        let start = ProcessInfo.processInfo.systemUptime
        let graph = CommitGraphLayout(commits: history)
        print(String(format: "5000 Git rows / 150 lanes: %.3f s",
                     ProcessInfo.processInfo.systemUptime - start))
        XCTAssertEqual(graph.rows.count, 5_000)
        XCTAssertEqual(graph.laneCount, 150)
        XCTAssertEqual(graph.knownHeadHistory.count, 4_851)
        for index in [0, 1, 74, 148] {
            assertConnected(graph, from: index, to: 4_999,
                            color: graph.rows[index].node.color)
        }
        assertConnected(graph, from: 4_998, to: 4_999,
                        color: graph.rows[4_998].node.color)
        for row in graph.rows {
            for link in row.links {
                if case .through(let rail) = link {
                    XCTAssertNotEqual(rail.lane, row.node.lane,
                                      "No long-range rail may pass through an unrelated commit")
                }
            }
        }
        let repeated = CommitGraphLayout(commits: history)
        XCTAssertEqual(graph.rows.map(\.node), repeated.rows.map(\.node))
        XCTAssertEqual(graph.laneCount, repeated.laneCount)
    }

    func testOnlyLoadedGitAncestorsAreProvenReachableFromHEAD() {
        let graph = CommitGraphLayout(commits: [
            commit("tip", parents: ["main", "side"], current: true),
            commit("side", parents: ["base"]),
            commit("main", parents: ["base"]),
            commit("unrelated", parents: ["root"]),
            commit("base", parents: ["root"]),
            commit("root"),
        ])
        XCTAssertEqual(graph.knownHeadHistory,
                       Set(["tip", "side", "main", "base", "root"]))
        let withoutHead = CommitGraphLayout(commits: [
            commit("side", parents: ["root"]),
            commit("root"),
        ])
        XCTAssertTrue(withoutHead.knownHeadHistory.isEmpty,
                      "Visible refs are not proof that an unseen HEAD reaches a commit")
        let missingParent = CommitGraphLayout(commits: [
            commit("tip", parents: ["not-loaded"], current: true),
            commit("unrelated"),
        ])
        XCTAssertEqual(missingParent.knownHeadHistory, Set(["tip"]),
                       "Unknown ancestors cannot be inferred from a truncated page")
    }

    func testDetachedHeadHistoryUsesTheRealDetachedTip() {
        let detached = GitStatusModel.RecentCommit(
            hash: "detached", shortHash: "detached", subject: "Detached",
            author: "Test", date: .distantPast, parentHashes: ["root"],
            references: [.init(kind: .detachedHead, name: "HEAD")], files: []
        )
        let graph = CommitGraphLayout(commits: [
            detached, commit("unrelated"), commit("root"),
        ])
        XCTAssertEqual(graph.knownHeadHistory, Set(["detached", "root"]))
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
