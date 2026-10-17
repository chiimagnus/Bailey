import Foundation

/// Commit rails use the loaded Git DAG; stash rails use their existing base-commit display link.
nonisolated struct CommitGraphLayout {
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
    let knownHeadHistory: Set<String>

    init(commits: [GitStatusModel.RecentCommit]) {
        let positions = Dictionary(uniqueKeysWithValues: commits.enumerated().compactMap {
            $0.element.stash == nil && $0.element.worktree == nil
                ? ($0.element.hash, $0.offset) : nil
        })
        var headHistory: Set<String> = []
        if let headIndex = commits.firstIndex(where: {
            $0.stash == nil && $0.worktree == nil && $0.references.contains {
                $0.kind == .currentBranch || $0.kind == .detachedHead
            }
        }) {
            var pending = [headIndex]
            while let index = pending.popLast() {
                let commit = commits[index]
                guard headHistory.insert(commit.hash).inserted else { continue }
                pending += commit.parentHashes.compactMap { hash in
                    guard let parentIndex = positions[hash], parentIndex > index else { return nil }
                    return parentIndex
                }
            }
        }
        knownHeadHistory = headHistory
        var nodes = [Node?](repeating: nil, count: commits.count)

        var reservations: [(lane: Int, color: Int, first: Int, last: Int)] = []
        // Stash display edges do not own the main commit's first-parent path.
        let order = commits.indices.filter { commits[$0].stash == nil && commits[$0].worktree == nil }
            + commits.indices.filter { commits[$0].stash != nil || commits[$0].worktree != nil }
        for start in order where nodes[start] == nil {
            var path: [Int] = []
            var cursor = start
            var end = start
            while nodes[cursor] == nil {
                path.append(cursor)
                guard let parent = commits[cursor].parentHashes.first else { break }
                guard let next = positions[parent], next > cursor else {
                    // Only real commits can continue beyond the loaded page.
                    if commits[cursor].stash == nil && commits[cursor].worktree == nil {
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
            var lane = 0
            while concurrent.contains(where: { $0.lane == lane }) { lane += 1 }
            let occupiedColors = Set(concurrent.map(\.color))
            let color = (0..<12).first { !occupiedColors.contains($0) }
                ?? reservations.count % 12
            for index in path { nodes[index] = Node(lane: lane, color: color) }
            reservations.append((lane, color, start, end))
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

                func clear(_ lane: Int) -> Bool {
                    occupied[lane]?.intersects(integersIn: between) != true
                }

                var lane = parentOffset == 0 ? from.lane : to.lane
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
            var seen: Set<Link> = []
            graph[index].links = graph[index].links.filter { seen.insert($0).inserted }
            let bottom = graph[index].links.compactMap { link -> Rail? in
                switch link {
                case .outgoing(let rail), .through(let rail):
                    return rail
                case .depart(_, let to, let color):
                    return Rail(lane: to, color: color)
                case .incoming, .arrive:
                    return nil
                }
            }
            graph[index].bottomRails = Array(Set(bottom)).sorted {
                $0.lane == $1.lane ? $0.color < $1.color : $0.lane < $1.lane
            }
        }
        rows = graph
        laneCount = largestLane + 1
    }
}
