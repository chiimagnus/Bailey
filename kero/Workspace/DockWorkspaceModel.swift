import Combine
import Foundation

/// One movable workspace tab. A project owns its live editor/terminal tabs;
/// this model owns only where each tab is displayed.
enum DockItem: Hashable {
    case projects
    case info
    case files
    case git
    case tab(UUID)
}

enum DockRegion: String, Codable {
    case left, main, right, extra
}

enum DockAxis: String, Codable {
    case horizontal, vertical
}

enum DockEdge {
    case left, right, top, bottom
}

struct DockGroup {
    let id: UUID
    var region: DockRegion
    var items: [DockItem]
    var selected: DockItem?

    init(id: UUID = UUID(), region: DockRegion, items: [DockItem], selected: DockItem? = nil) {
        self.id = id
        self.region = region
        self.items = items
        self.selected = selected ?? items.first
    }
}

struct DockSplit {
    let id: UUID
    var axis: DockAxis
    var fraction: Double
    var first: DockNode
    var second: DockNode

    init(id: UUID = UUID(), axis: DockAxis, fraction: Double, first: DockNode, second: DockNode) {
        self.id = id
        self.axis = axis
        self.fraction = fraction
        self.first = first
        self.second = second
    }
}

indirect enum DockNode {
    case group(DockGroup)
    case split(DockSplit)

    var groups: [DockGroup] {
        switch self {
        case .group(let group): return [group]
        case .split(let split): return split.first.groups + split.second.groups
        }
    }

    func group(id: UUID) -> DockGroup? { groups.first { $0.id == id } }
    func group(region: DockRegion) -> DockGroup? { groups.first { $0.region == region } }
    func group(containing item: DockItem) -> DockGroup? {
        groups.first { $0.items.contains(item) }
    }

    func editingGroup(_ id: UUID, _ edit: (inout DockGroup) -> Void) -> DockNode {
        switch self {
        case .group(var group):
            if group.id == id { edit(&group) }
            return .group(group)
        case .split(var split):
            split.first = split.first.editingGroup(id, edit)
            split.second = split.second.editingGroup(id, edit)
            return .split(split)
        }
    }

    func mappingGroups(_ edit: (inout DockGroup) -> Void) -> DockNode {
        switch self {
        case .group(var group):
            edit(&group)
            return .group(group)
        case .split(var split):
            split.first = split.first.mappingGroups(edit)
            split.second = split.second.mappingGroups(edit)
            return .split(split)
        }
    }

    /// Empty auxiliary groups collapse; the three default regions remain
    /// available for reopening from the existing sidebar buttons.
    func removing(_ item: DockItem) -> DockNode? {
        switch self {
        case .group(var group):
            group.items.removeAll { $0 == item }
            if group.selected == item { group.selected = group.items.first }
            return group.items.isEmpty && group.region == .extra ? nil : .group(group)
        case .split(var split):
            let first = split.first.removing(item)
            let second = split.second.removing(item)
            switch (first, second) {
            case (let a?, let b?):
                split.first = a
                split.second = b
                return .split(split)
            case (let a?, nil): return a
            case (nil, let b?): return b
            case (nil, nil): return nil
            }
        }
    }

    func inserting(_ new: DockNode, edge: DockEdge, at groupID: UUID) -> DockNode {
        switch self {
        case .group(let group):
            guard group.id == groupID else { return self }
            return .split(DockSplit(
                axis: edge == .left || edge == .right ? .horizontal : .vertical,
                fraction: 0.5,
                first: edge == .left || edge == .top ? new : self,
                second: edge == .left || edge == .top ? self : new
            ))
        case .split(var split):
            split.first = split.first.inserting(new, edge: edge, at: groupID)
            split.second = split.second.inserting(new, edge: edge, at: groupID)
            return .split(split)
        }
    }

    func removingEmptyExtras() -> DockNode? {
        switch self {
        case .group(let group):
            return group.items.isEmpty && group.region == .extra ? nil : self
        case .split(var split):
            let first = split.first.removingEmptyExtras()
            let second = split.second.removingEmptyExtras()
            switch (first, second) {
            case (let a?, let b?):
                split.first = a
                split.second = b
                return .split(split)
            case (let a?, nil): return a
            case (nil, let b?): return b
            case (nil, nil): return nil
            }
        }
    }

    func settingFraction(_ splitID: UUID, _ fraction: Double) -> DockNode {
        switch self {
        case .group: return self
        case .split(var split):
            if split.id == splitID {
                split.fraction = min(max(fraction, 0.1), 0.9)
            } else {
                split.first = split.first.settingFraction(splitID, fraction)
                split.second = split.second.settingFraction(splitID, fraction)
            }
            return .split(split)
        }
    }

    /// Remove collapsed side regions from the rendered tree without modifying
    /// the saved layout or moving their contained tabs.
    func visible(left: Bool, right: Bool) -> DockNode? {
        switch self {
        case .group(let group):
            if group.region == .left && !left { return nil }
            if group.region == .right && !right { return nil }
            return self
        case .split(var split):
            let first = split.first.visible(left: left, right: right)
            let second = split.second.visible(left: left, right: right)
            switch (first, second) {
            case (let a?, let b?):
                split.first = a
                split.second = b
                return .split(split)
            case (let a?, nil): return a
            case (nil, let b?): return b
            case (nil, nil): return nil
            }
        }
    }
}

/// Saved tab references are indices into the *persistable* project tab list:
/// restored PaneTab UUIDs are intentionally different from the original IDs.
enum DockSavedItem: Codable, Hashable {
    case projects, info, files, git, tab(Int)

    init?(_ item: DockItem, tabIDs: [UUID]) {
        switch item {
        case .projects: self = .projects
        case .info: self = .info
        case .files: self = .files
        case .git: self = .git
        case .tab(let id):
            guard let index = tabIDs.firstIndex(of: id) else { return nil }
            self = .tab(index)
        }
    }

    func resolve(tabIDs: [UUID]) -> DockItem? {
        switch self {
        case .projects: return .projects
        case .info: return .info
        case .files: return .files
        case .git: return .git
        case .tab(let index):
            guard tabIDs.indices.contains(index) else { return nil }
            return .tab(tabIDs[index])
        }
    }
}

struct DockSavedGroup: Codable {
    var id: UUID
    var region: DockRegion
    var items: [DockSavedItem]
    var selected: DockSavedItem?
}

indirect enum DockSavedNode: Codable {
    case group(DockSavedGroup)
    case split(id: UUID, axis: DockAxis, fraction: Double, first: DockSavedNode, second: DockSavedNode)

    init(_ node: DockNode, tabIDs: [UUID]) {
        switch node {
        case .group(let group):
            self = .group(DockSavedGroup(
                id: group.id, region: group.region,
                items: group.items.compactMap { DockSavedItem($0, tabIDs: tabIDs) },
                selected: group.selected.flatMap { DockSavedItem($0, tabIDs: tabIDs) }
            ))
        case .split(let split):
            self = .split(
                id: split.id, axis: split.axis, fraction: split.fraction,
                first: DockSavedNode(split.first, tabIDs: tabIDs),
                second: DockSavedNode(split.second, tabIDs: tabIDs)
            )
        }
    }

    func restore(tabIDs: [UUID]) -> DockNode {
        switch self {
        case .group(let saved):
            return .group(DockGroup(
                id: saved.id, region: saved.region,
                items: saved.items.compactMap { $0.resolve(tabIDs: tabIDs) },
                selected: saved.selected?.resolve(tabIDs: tabIDs)
            ))
        case .split(let id, let axis, let fraction, let first, let second):
            return .split(DockSplit(
                id: id, axis: axis, fraction: fraction,
                first: first.restore(tabIDs: tabIDs), second: second.restore(tabIDs: tabIDs)
            ))
        }
    }
}

@MainActor
final class DockWorkspaceModel: ObservableObject {
    @Published private(set) var root: DockNode

    init() {
        root = Self.defaults()
    }

    private static func defaults() -> DockNode {
        .split(DockSplit(
            axis: .horizontal, fraction: 0.12,
            first: .group(DockGroup(region: .left, items: [.projects])),
            second: .split(DockSplit(
                axis: .horizontal, fraction: 0.787,
                first: .group(DockGroup(region: .main, items: [])),
                second: .group(DockGroup(region: .right, items: [.info, .files, .git], selected: .files))
            ))
        ))
    }

    func group(containing item: DockItem) -> DockGroup? { root.group(containing: item) }
    func group(region: DockRegion) -> DockGroup? { root.group(region: region) }

    func select(_ item: DockItem) {
        guard let owner = group(containing: item), owner.selected != item else { return }
        root = root.editingGroup(owner.id) { $0.selected = item }
    }

    /// A new content tab belongs beside the previously selected tab, or to the
    /// main group if no live anchor remains. Removes stale tabs after closes.
    func syncTabs(_ tabIDs: [UUID], near selectedTab: UUID?) {
        let allowed = Set(tabIDs)
        var seen = Set<DockItem>()
        var updated = root.mappingGroups { group in
            group.items = group.items.filter { item in
                if case .tab(let id) = item, !allowed.contains(id) { return false }
                return seen.insert(item).inserted
            }
            if let selected = group.selected, !group.items.contains(selected) {
                group.selected = group.items.first
            }
        }
        let destination = selectedTab.flatMap { updated.group(containing: .tab($0)) }
            ?? updated.group(region: .main)
            ?? updated.groups.first
        if let destination {
            let missing = tabIDs.map(DockItem.tab).filter { !seen.contains($0) }
            if !missing.isEmpty {
                updated = updated.editingGroup(destination.id) { group in
                    group.items.append(contentsOf: missing)
                    group.selected = missing.last
                }
            }
        }
        root = updated.removingEmptyExtras() ?? Self.defaults()
    }

    func move(_ item: DockItem, into destinationID: UUID, edge: DockEdge? = nil, index: Int? = nil) -> Bool {
        guard let source = root.group(containing: item),
              root.group(id: destinationID) != nil
        else { return false }
        if source.id == destinationID && edge != nil && source.items.count == 1 { return false }
        guard let remaining = root.removing(item) else { return false }
        if let edge {
            guard remaining.group(id: destinationID) != nil else { return false }
            root = remaining.inserting(
                .group(DockGroup(region: .extra, items: [item])),
                edge: edge, at: destinationID
            )
        } else {
            guard let target = remaining.group(id: destinationID) else { return false }
            let sourceIndex = source.items.firstIndex(of: item)
            root = remaining.editingGroup(target.id) { group in
                var insertAt = index ?? group.items.count
                if source.id == destinationID, let sourceIndex, sourceIndex < insertAt {
                    insertAt -= 1
                }
                insertAt = min(max(insertAt, 0), group.items.count)
                group.items.insert(item, at: insertAt)
                group.selected = item
            }
        }
        return true
    }

    /// An empty side can be reopened and populated without copying a panel.
    func place(_ item: DockItem, in region: DockRegion) {
        guard let destination = root.group(region: region) else { return }
        if root.group(containing: item) != nil {
            _ = move(item, into: destination.id)
        } else {
            root = root.editingGroup(destination.id) { group in
                group.items.append(item)
                group.selected = item
            }
        }
    }

    func resize(_ splitID: UUID, to fraction: Double) {
        root = root.settingFraction(splitID, fraction)
    }

    func snapshot(tabIDs: [UUID]) -> DockSavedNode {
        DockSavedNode(root, tabIDs: tabIDs)
    }

    func restore(_ saved: DockSavedNode, tabIDs: [UUID]) {
        root = saved.restore(tabIDs: tabIDs)
        // Normalize the saved tree: missing/unsnapshotable references and
        // project tabs opened since the snapshot must never disappear.
        syncTabs(tabIDs, near: nil)
    }

    var visibleItems: Set<DockItem> {
        Set(root.groups.flatMap(\.items))
    }
}
