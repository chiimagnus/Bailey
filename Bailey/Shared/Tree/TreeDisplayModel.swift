import Foundation

enum TreeDisplayModel {
    enum Status: Equatable, Sendable {
        case modified, added, untracked, deleted, renamed, copied, conflict, ignored, changed

        init(_ character: Character) {
            switch character {
            case "M": self = .modified
            case "A": self = .added
            case "?": self = .untracked
            case "D": self = .deleted
            case "R": self = .renamed
            case "C": self = .copied
            case "U": self = .conflict
            case "!": self = .ignored
            default: self = .changed
            }
        }

        init(staged: Character, unstaged: Character, isConflict: Bool) {
            let statuses = [staged, unstaged]
            if isConflict || statuses.contains("U") { self = .conflict }
            else if statuses.contains("?") { self = .untracked }
            else if staged == "A" { self = .added }
            else if statuses.contains("D") { self = .deleted }
            else if statuses.contains("R") { self = .renamed }
            else if statuses.contains("C") { self = .copied }
            else if staged == "." && unstaged == "." { self = .modified }
            else { self.init(unstaged == "." ? staged : unstaged) }
        }

        var accessibilityName: String {
            switch self {
            case .modified: String(localized: "Modified", table: "Sidebar")
            case .added: String(localized: "Added", table: "Sidebar")
            case .untracked: String(localized: "Untracked", table: "Sidebar")
            case .deleted: String(localized: "Deleted", table: "Sidebar")
            case .renamed: String(localized: "Renamed", table: "Sidebar")
            case .copied: String(localized: "Copied", table: "Sidebar")
            case .conflict: String(localized: "Conflict", table: "Sidebar")
            case .ignored: String(localized: "Ignored", table: "Sidebar")
            case .changed: String(localized: "Changed", table: "Sidebar")
            }
        }

        var directoryPriority: Int {
            switch self {
            case .conflict: 8
            case .deleted: 7
            case .modified, .changed: 6
            case .added: 5
            case .untracked: 4
            case .renamed: 3
            case .copied: 2
            case .ignored: 1
            }
        }
    }

    struct Row: Identifiable, Equatable {
        struct CompactComponent: Identifiable, Equatable {
            let name: String
            let path: String
            var id: String { path }
        }

        var id: String { namespace + path }
        let name: String
        let path: String
        let isDirectory: Bool
        var depth = 0
        var compactPrefix: [String] = []
        var isDraft = false
        var isExpanded = false
        var status: Status?
        var namespace = ""

        var displayName: String { (compactPrefix + [name]).joined(separator: " / ") }
        var compactComponents: [CompactComponent] {
            var currentPath = path
            var result: [CompactComponent] = []
            for name in (compactPrefix + [name]).reversed() {
                result.append(CompactComponent(name: name, path: currentPath))
                currentPath = (currentPath as NSString).deletingLastPathComponent
            }
            return result.reversed()
        }

        func item(for component: CompactComponent) -> Row {
            Row(name: component.name, path: component.path, isDirectory: true, depth: depth)
        }

        var accessibilityLabel: String {
            status.map { displayName + ", " + $0.accessibilityName } ?? displayName
        }
    }

    // The source supplies one directory at a time, synchronously for Git or
    // asynchronously for disk/SSH. Only this traversal owns display semantics.
    struct Traversal {
        private enum Step {
            case root(String)
            case row(Row, compactDepth: Int)
        }

        private var pending: [Step]
        private var reading: Step?
        private let expanded: (String) -> Bool
        private let inspectDirectory: (String) -> Bool
        private let foldDirectory: (String) -> Bool
        private let directoryDepthLimit: Int?
        private(set) var rows: [Row] = []
        private(set) var rootReadable = true

        /// Only directories whose entries are already known or explicitly
        /// expanded may enter the next read batch.
        var pendingDirectories: [String] {
            pending.compactMap { step in
                guard case .row(let row, _) = step, row.isDirectory, !row.isDraft,
                      inspectDirectory(row.path) else { return nil }
                return row.path
            }
        }

        init(
            root: String, directoryDepthLimit: Int? = nil,
            inspectDirectory: @escaping (String) -> Bool = { _ in true },
            foldDirectory: @escaping (String) -> Bool = { _ in true },
            expanded: @escaping (String) -> Bool
        ) {
            pending = [.root(root)]
            self.directoryDepthLimit = directoryDepthLimit
            self.inspectDirectory = inspectDirectory
            self.foldDirectory = foldDirectory
            self.expanded = expanded
        }

        mutating func nextDirectory() -> String? {
            while let step = pending.popLast() {
                switch step {
                case .root(let path):
                    reading = step
                    return path
                case .row(var row, _):
                    if row.isDirectory && !row.isDraft && inspectDirectory(row.path) {
                        reading = step
                        return row.path
                    }
                    row.isExpanded = row.isDirectory && expanded(row.path)
                    rows.append(row)
                }
            }
            return nil
        }

        mutating func receive(_ children: [Row]?) {
            guard let reading else { return }
            self.reading = nil
            switch reading {
            case .root:
                rootReadable = children != nil
                enqueue(children ?? [], depth: 0)
            case .row(var row, let compactDepth):
                if (directoryDepthLimit.map({ compactDepth < $0 }) ?? true),
                   foldDirectory(row.path),
                   let children, children.count == 1, var child = children.first,
                   child.isDirectory, !child.isDraft, inspectDirectory(child.path) {
                    child.depth = row.depth
                    child.compactPrefix = row.compactPrefix + [row.name]
                    pending.append(.row(child, compactDepth: compactDepth + 1))
                } else {
                    row.isExpanded = expanded(row.path)
                    rows.append(row)
                    if row.isExpanded, directoryDepthLimit.map({ row.depth < $0 - 1 }) ?? true {
                        enqueue(children ?? [], depth: row.depth + 1)
                    }
                }
            }
        }

        private mutating func enqueue(_ children: [Row], depth: Int) {
            let sorted = children.sorted { first, second in
                if first.isDraft != second.isDraft { return first.isDraft }
                if first.isDirectory != second.isDirectory { return first.isDirectory }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
            for var row in sorted.reversed() {
                row.depth = depth
                pending.append(.row(row, compactDepth: 0))
            }
        }
    }

    static func pathRows(
        _ files: [Row], section: String, collapsed: Set<String>
    ) -> [Row] {
        var directories: [String: [String: Row]] = [:]
        var seen: Set<String> = []
        for file in files {
            guard seen.insert(file.path).inserted else { continue }
            let components = file.path.split(separator: "/").map(String.init)
            var parent = ""
            for (index, name) in components.enumerated() {
                let path = parent.isEmpty ? name : parent + "/" + name
                var row = index == components.count - 1
                    ? file : (directories[parent]?[path] ?? Row(name: name, path: path, isDirectory: true))
                row.namespace = section + ":"
                if row.isDirectory, let status = file.status,
                   status.directoryPriority > (row.status?.directoryPriority ?? 0) {
                    row.status = status
                }
                directories[parent, default: [:]][path] = row
                parent = path
            }
        }
        var traversal = Traversal(root: "") { !collapsed.contains(section + ":" + $0) }
        while let directory = traversal.nextDirectory() {
            traversal.receive(Array(directories[directory, default: [:]].values))
        }
        return traversal.rows
    }
}
