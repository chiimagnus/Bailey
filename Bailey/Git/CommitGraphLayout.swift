import Foundation

/// Commit rails use the loaded Git DAG; stash rails use their existing base-commit display link.
nonisolated struct CommitGraphLayout: Sendable {
    /// An uncommitted checkout with no visible HEAD has no known branch color.
    static let unconnectedWorktreeColor = -1

    struct Node: Equatable {
        let lane: Int
        let color: Int
    }

    struct Rail: Hashable {
        let lane: Int
        let color: Int
    }

    enum Link: Hashable {
        case incoming(Rail)
        case outgoing(Rail)
        case through(Rail)
        case depart(from: Int, to: Int, color: Int)
        case arrive(from: Int, to: Int, color: Int)
    }

    struct Row {
        let node: Node
        var links: [Link] = []
        var bottomRails: [Rail] = []
    }

    let rows: [Row]
    let laneCount: Int
    private(set) var knownHeadHistory: Set<String>

    private static func realPositions(in commits: [GitStatusModel.RecentCommit]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: commits.enumerated().compactMap {
            $0.element.stash == nil && $0.element.worktree == nil
                ? ($0.element.hash, $0.offset) : nil
        })
    }

    private static func headHistory(
        in commits: [GitStatusModel.RecentCommit], positions: [String: Int]
    ) -> Set<String> {
        guard let headIndex = commits.firstIndex(where: {
            $0.stash == nil && $0.worktree == nil && $0.references.contains {
                $0.kind == .currentBranch || $0.kind == .detachedHead
            }
        }) else { return [] }
        var history: Set<String> = []
        var pending = [headIndex]
        while let index = pending.popLast() {
            let commit = commits[index]
            guard history.insert(commit.hash).inserted else { continue }
            pending += commit.parentHashes.compactMap { hash in
                guard let parentIndex = positions[hash], parentIndex > index else { return nil }
                return parentIndex
            }
        }
        return history
    }

    // A checkout, ref label or worktree annotation is not a graph edge.
    // Reuse geometry only when the ordered row identities, roles and parents match.
    func reusingGeometry(
        from previous: [GitStatusModel.RecentCommit],
        for commits: [GitStatusModel.RecentCommit]
    ) -> Self? {
        guard previous.count == commits.count,
              zip(previous, commits).allSatisfy({ old, new in
                  old.hash == new.hash && old.parentHashes == new.parentHashes
                      && (old.stash != nil) == (new.stash != nil)
                      && (old.worktree != nil) == (new.worktree != nil)
              }) else { return nil }
        var updated = self
        updated.knownHeadHistory = Self.headHistory(in: commits, positions: Self.realPositions(in: commits))
        return updated
    }

    init(commits: [GitStatusModel.RecentCommit]) {
        let positions = Self.realPositions(in: commits)
        knownHeadHistory = Self.headHistory(in: commits, positions: positions)
        var nodes = [Node?](repeating: nil, count: commits.count)

        var reservations: [(lane: Int, color: Int, first: Int, last: Int)] = []
        // Allocate paths in history order, independent of the active checkout.
        // Stashes retain separate display lanes; dirty worktrees extend their HEAD.
        let order = commits.indices.filter { commits[$0].stash == nil && commits[$0].worktree == nil }
            + commits.indices.filter { commits[$0].stash != nil }
        for start in order where nodes[start] == nil {
            var path: [Int] = []
            var cursor = start
            var end = start
            while nodes[cursor] == nil {
                path.append(cursor)
                guard let parent = commits[cursor].parentHashes.first else { break }
                guard let next = positions[parent], next > cursor else {
                    // Only real commits can continue beyond the loaded page.
                    if commits[cursor].stash == nil {
                        end = commits.count
                    }
                    break
                }
                end = next
                if commits[cursor].stash != nil || nodes[next] != nil { break }
                cursor = next
            }
            let concurrent = reservations.filter {
                $0.first <= end && start <= $0.last
            }
            let occupiedLanes = Set(concurrent.map(\.lane))
            var lane = 0
            while occupiedLanes.contains(lane) { lane += 1 }
            let occupiedColors = Set(concurrent.map(\.color))
            let color = (0..<12).first { !occupiedColors.contains($0) }
                ?? reservations.count % 12
            for index in path { nodes[index] = Node(lane: lane, color: color) }
            reservations.append((lane, color, start, end))
        }

        for index in commits.indices where commits[index].worktree != nil {
            if let parentHash = commits[index].parentHashes.first,
               let parentIndex = positions[parentHash], let parentNode = nodes[parentIndex] {
                // A checkout's dirty state belongs on its actual HEAD rail.
                nodes[index] = parentNode
            } else {
                let occupied = reservations.filter { $0.first <= index && index <= $0.last }
                var lane = 0
                while occupied.contains(where: { $0.lane == lane }) { lane += 1 }
                nodes[index] = Node(lane: lane, color: Self.unconnectedWorktreeColor)
                reservations.append((lane, Self.unconnectedWorktreeColor, index, index))
            }
        }

        var graph = nodes.map { Row(node: $0!) }
        var occupied: [Int: IndexSet] = [:]
        for (index, row) in graph.enumerated() {
            occupied[row.node.lane, default: IndexSet()].insert(index)
        }
        var largestLane = nodes.compactMap(\.self).map(\.lane).max() ?? -1
        for (index, commit) in commits.enumerated() {
            let from = graph[index].node
            for (parentOffset, hash) in commit.parentHashes.enumerated() {
                guard let parentIndex = positions[hash], parentIndex > index else { continue }
                let to = graph[parentIndex].node
                let color = parentOffset == 0 ? from.color : to.color
                let between = (index + 1)..<parentIndex

                var lane = parentOffset == 0 ? from.lane : to.lane
                // Worktree rows already share their visible HEAD node's lane.
                // Only ordinary Git/stash edges reserve transit lanes.
                if commit.worktree == nil {
                    func clear(_ lane: Int) -> Bool {
                        occupied[lane]?.intersects(integersIn: between) != true
                    }
                    if !clear(lane) {
                        let alternate = parentOffset == 0 ? to.lane : from.lane
                        if clear(alternate) {
                            lane = alternate
                        } else {
                            lane = (0...largestLane).first(where: clear) ?? (largestLane + 1)
                        }
                    }
                    largestLane = max(largestLane, lane)
                    occupied[lane, default: IndexSet()].insert(integersIn: index..<(parentIndex + 1))
                }
                let rail = Rail(lane: lane, color: color)
                if from.lane == lane {
                    graph[index].links.append(.outgoing(rail))
                } else {
                    graph[index].links.append(.depart(from: from.lane, to: lane, color: color))
                }
                if to.lane == lane {
                    graph[parentIndex].links.append(.incoming(rail))
                } else {
                    graph[parentIndex].links.append(.arrive(from: lane, to: to.lane, color: color))
                }
                for intermediate in between {
                    graph[intermediate].links.append(.through(rail))
                }
            }
        }

        for index in graph.indices {
            let count = graph[index].links.count
            var links = Set<Link>(minimumCapacity: count)
            var rails = Set<Rail>(minimumCapacity: count)
            graph[index].links = graph[index].links.filter { link in
                guard links.insert(link).inserted else { return false }
                switch link {
                case .outgoing(let rail), .through(let rail):
                    rails.insert(rail)
                case .depart(_, let to, let color):
                    rails.insert(Rail(lane: to, color: color))
                case .incoming, .arrive:
                    break
                }
                return true
            }
            graph[index].bottomRails = rails.sorted {
                $0.lane == $1.lane ? $0.color < $1.color : $0.lane < $1.lane
            }
        }
        rows = graph
        laneCount = largestLane + 1
    }
}
