/// Lanes are derived only from the loaded Git DAG; no visual-only connections.
nonisolated struct CommitGraphLayout {
    struct Node: Equatable {
        let lane: Int
        let color: Int
    }

    struct Rail: Hashable {
        let lane: Double
        let color: Int
    }

    enum Link: Hashable {
        case incoming(Rail)
        case outgoing(Rail)
        case through(Rail)
        case diagonal(fromX: Double, fromY: Double, toX: Double, toY: Double, color: Int)
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
        for (index, commit) in commits.enumerated() {
            let from = graph[index].node
            for hash in commit.parentHashes {
                guard let parentIndex = positions[hash], parentIndex > index else { continue }
                let to = graph[parentIndex].node
                let color = from.lane == 0 && to.lane != 0 ? to.color : from.color
                if from.lane == to.lane {
                    let rail = Rail(lane: Double(from.lane), color: color)
                    graph[index].links.append(.outgoing(rail))
                    graph[parentIndex].links.append(.incoming(rail))
                    if parentIndex > index + 1 {
                        for intermediate in (index + 1)..<parentIndex {
                            graph[intermediate].links.append(.through(rail))
                        }
                    }
                } else {
                    let distance = Double(parentIndex - index)
                    for rowIndex in index...parentIndex {
                        let fromY = rowIndex == index ? 0.5 : 0.0
                        let toY = rowIndex == parentIndex ? 0.5 : 1.0
                        func x(_ y: Double) -> Double {
                            let fraction = (Double(rowIndex - index) + y - 0.5) / distance
                            return Double(from.lane) + Double(to.lane - from.lane) * fraction
                        }
                        graph[rowIndex].links.append(.diagonal(
                            fromX: x(fromY), fromY: fromY,
                            toX: x(toY), toY: toY, color: color
                        ))
                    }
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
                case .diagonal(_, _, let toX, let toY, let color):
                    return toY == 1 ? Rail(lane: toX, color: color) : nil
                case .incoming:
                    return nil
                }
            }
            graph[index].bottomRails = Array(Set(bottom)).sorted {
                $0.lane == $1.lane ? $0.color < $1.color : $0.lane < $1.lane
            }
        }
        rows = graph
        laneCount = (nodes.compactMap(\.self).map(\.lane).max() ?? -1) + 1
    }
}
