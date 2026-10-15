/// Lanes are derived only from the loaded Git DAG; no visual-only connections.
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

    init(commits: [GitStatusModel.RecentCommit]) {
        let positions = Dictionary(uniqueKeysWithValues: commits.enumerated().compactMap {
            $0.element.stash == nil ? ($0.element.hash, $0.offset) : nil
        })
        var nodes = [Node?](repeating: nil, count: commits.count)

        // A paged log may omit HEAD. Never color an unrelated tip as the main branch.
        let loadedHead = commits.firstIndex(where: {
            $0.references.contains {
                $0.kind == .currentBranch || $0.kind == .detachedHead
            }
        })
        if let start = loadedHead ?? commits.indices.first {
            var cursor = start
            while nodes[cursor] == nil {
                nodes[cursor] = Node(lane: 0, color: loadedHead == nil ? 1 : 0)
                guard let parent = commits[cursor].parentHashes.first,
                      let next = positions[parent], next > cursor else { break }
                cursor = next
            }
        }

        var reservations: [(lane: Int, first: Int, last: Int)] = []
        var nextColor = loadedHead == nil ? 2 : 1
        for start in commits.indices where nodes[start] == nil {
            var path: [Int] = []
            var cursor = start
            var end = start
            while nodes[cursor] == nil {
                path.append(cursor)
                guard let parent = commits[cursor].parentHashes.first,
                      let next = positions[parent], next > cursor else { break }
                end = next
                if nodes[next] != nil { break }
                cursor = next
            }
            var lane = 1
            while reservations.contains(where: {
                $0.lane == lane && $0.first <= end && start <= $0.last
            }) {
                lane += 1
            }
            for index in path { nodes[index] = Node(lane: lane, color: nextColor) }
            reservations.append((lane, start, end))
            nextColor += 1
        }

        var graph = nodes.map { Row(node: $0!) }
        var largestLane = nodes.compactMap(\.self).map(\.lane).max() ?? -1
        for (index, commit) in commits.enumerated() {
            let from = graph[index].node
            for hash in commit.parentHashes {
                guard let parentIndex = positions[hash], parentIndex > index else { continue }
                let to = graph[parentIndex].node
                let color = from.lane == 0 && to.lane != 0 ? to.color : from.color
                let between = (index + 1)..<parentIndex

                func clear(_ lane: Int) -> Bool {
                    between.allSatisfy { row in
                        guard graph[row].node.lane != lane else { return false }
                        return !graph[row].links.contains { link in
                            switch link {
                            case .incoming(let rail), .outgoing(let rail), .through(let rail):
                                return rail.lane == lane
                            case .depart(let a, let b, _), .arrive(let a, let b, _):
                                return a == lane || b == lane
                            }
                        }
                    }
                }

                var lane = max(from.lane, to.lane)
                if !clear(lane) {
                    let alternate = min(from.lane, to.lane)
                    if clear(alternate) {
                        lane = alternate
                    } else {
                        lane = max(largestLane, lane) + 1
                        while !clear(lane) { lane += 1 }
                    }
                }
                largestLane = max(largestLane, lane)
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
