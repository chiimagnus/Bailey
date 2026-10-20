import CoreGraphics
import Foundation
import Observation

/// One movable workspace tab. A project owns its live editor/terminal tabs;
/// this model owns only where each tab is displayed.
enum DockItem: Hashable {
    case projects
    case files
    case git
    case tab(UUID)

    init?(configurationName: String) {
        switch configurationName {
        case "projects": self = .projects
        case "files": self = .files
        case "git": self = .git
        default: return nil
        }
    }

    var configurationName: String? {
        switch self {
        case .projects: "projects"
        case .files: "files"
        case .git: "git"
        case .tab: nil
        }
    }
}

/// Defines workspace actions without binding the model to SwiftUI menus.
enum DockAddAction: String, CaseIterable, Hashable {
    case session, projects, files, git

    var item: DockItem? {
        self == .session ? nil : DockItem(configurationName: rawValue)
    }
}

/// Shared, validated configuration for new projects and tab-group menus.
/// Per-project saved layouts remain separate from this starting template.
struct DockWorkspaceConfiguration {
    static let standard = DockWorkspaceConfiguration(
        groups: [[.projects], [], [.files, .git]],
        selected: [.projects, nil, .files],
        weights: [0.12, 0.69256, 0.18744],
        addActions: DockAddAction.allCases,
        edgeThreshold: 0.22
    )

    let groups: [[DockItem]]
    let selected: [DockItem?]
    let weights: [Double]
    let addActions: [DockAddAction]
    let edgeThreshold: Double

    private init(
        groups: [[DockItem]], selected: [DockItem?], weights: [Double],
        addActions: [DockAddAction], edgeThreshold: Double
    ) {
        self.groups = groups
        self.selected = selected
        self.weights = weights
        self.addActions = addActions
        self.edgeThreshold = edgeThreshold
    }

    init?(
        groupNames: [String], selectedNames: [String], weights: [Double],
        actionNames: [String], edgeThreshold: Double
    ) {
        guard !groupNames.isEmpty, weights.count == groupNames.count,
              selectedNames.count == groupNames.count,
              edgeThreshold.isFinite, (0.05...0.4).contains(edgeThreshold) else { return nil }
        var groups: [[DockItem]] = []
        var seen = Set<DockItem>()
        for name in groupNames {
            let names = name.isEmpty ? [] : name.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            var items: [DockItem] = []
            for name in names {
                if name == "info" { continue }
                guard let item = DockItem(configurationName: name), seen.insert(item).inserted else {
                    return nil
                }
                items.append(item)
            }
            groups.append(items)
        }
        guard seen.contains(.projects), weights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        var selected: [DockItem?] = []
        for (index, name) in selectedNames.enumerated() {
            let item = name.isEmpty || name == "info" ? groups[index].first : DockItem(configurationName: name)
            if !name.isEmpty && name != "info" && item == nil { return nil }
            if let item, !groups[index].contains(item) { return nil }
            selected.append(item)
        }
        let total = weights.reduce(0, +)
        guard total.isFinite else { return nil }
        for index in 0..<(weights.count - 1) {
            let fraction = weights[index] / weights[index...].reduce(0, +)
            guard (0.1...0.9).contains(fraction) else { return nil }
        }
        let activeActionNames = actionNames.filter { $0 != "info" }
        let actions = activeActionNames.compactMap(DockAddAction.init(rawValue:))
        guard actions.count == activeActionNames.count, Set(actions).count == actions.count,
              actions.contains(.session), actions.contains(.projects) else { return nil }
        self.init(groups: groups, selected: selected, weights: weights,
                  addActions: actions, edgeThreshold: edgeThreshold)
    }

    var groupNames: [String] {
        groups.map { $0.compactMap(\.configurationName).joined(separator: ",") }
    }

    var selectedNames: [String] { selected.map { $0?.configurationName ?? "" } }
    var actionNames: [String] { addActions.map(\.rawValue) }

    func makeInitialLayout() -> DockNode {
        func make(_ index: Int) -> DockNode {
            let group = DockNode.group(DockGroup(items: groups[index], selected: selected[index]))
            guard index + 1 < groups.count else { return group }
            let fraction = weights[index] / weights[index...].reduce(0, +)
            return .split(DockSplit(
                axis: .horizontal, fraction: fraction,
                first: group, second: make(index + 1)
            ))
        }
        return make(0)
    }
}

enum DockAxis: String, Codable {
    case horizontal, vertical
}

enum DockEdge: Equatable {
    case left, right, top, bottom
}

/// Hit-test directly against the pane's visible content, not a five-zone
/// overlay. The tab strip always accepts a merge/reorder drop.
enum DockDropHitTest {
    static func edge(
        at pointer: CGPoint, in frame: CGRect,
        headerHeight: CGFloat = 38, threshold: CGFloat = 0.22
    ) -> DockEdge? {
        guard frame.contains(pointer), pointer.y >= frame.minY + headerHeight else { return nil }
        let x = (pointer.x - frame.minX) / max(frame.width, 1)
        let y = (pointer.y - frame.minY - headerHeight) / max(frame.height - headerHeight, 1)
        let nearest = min(x, 1 - x, y, 1 - y)
        guard nearest < threshold else { return nil }
        if nearest == x { return .left }
        if nearest == 1 - x { return .right }
        return nearest == y ? .top : .bottom
    }
}

struct DockGroup {
    let id: UUID
    var items: [DockItem]
    var selected: DockItem?

    init(id: UUID = UUID(), items: [DockItem], selected: DockItem? = nil) {
        self.id = id
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

    /// Empty groups collapse naturally after moving or closing their last tab.
    func removing(_ item: DockItem) -> DockNode? {
        switch self {
        case .group(var group):
            guard group.items.contains(item) else { return .group(group) }
            group.items.removeAll { $0 == item }
            if group.selected == item { group.selected = group.items.first }
            return group.items.isEmpty ? nil : .group(group)
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

    func removingEmptyGroups() -> DockNode? {
        switch self {
        case .group(let group): return group.items.isEmpty ? nil : self
        case .split(var split):
            switch (split.first.removingEmptyGroups(), split.second.removingEmptyGroups()) {
            case (let first?, let second?):
                split.first = first
                split.second = second
                return .split(split)
            case (let first?, nil): return first
            case (nil, let second?): return second
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

}

/// Saved tab references are indices into the *persistable* project tab list:
/// restored PaneTab UUIDs are intentionally different from the original IDs.
enum DockSavedItem: Codable, Hashable {
    case projects, info, files, git, tab(Int)

    init?(_ item: DockItem, tabIDs: [UUID]) {
        switch item {
        case .projects: self = .projects
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
        case .info: return nil
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
                id: group.id,
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
                id: saved.id,
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
@Observable
final class DockWorkspaceModel {
    let configuration: DockWorkspaceConfiguration
    private(set) var root: DockNode {
        didSet { onSnapshotChange?() }
    }
    private(set) var activeGroupID: UUID?
    @ObservationIgnored var onSnapshotChange: (() -> Void)?
    @ObservationIgnored var onDeactivate: ((DockItem) -> Void)?

    init(configuration: DockWorkspaceConfiguration = .standard) {
        self.configuration = configuration
        root = configuration.makeInitialLayout()
        activeGroupID = root.groups.first?.id
    }

    var activeGroup: DockGroup? { activeGroupID.flatMap { root.group(id: $0) } }

    private func updateLayout(_ updated: DockNode, activating groupID: UUID? = nil) {
        let previous = activeGroup?.selected
        activeGroupID = (groupID ?? activeGroupID).flatMap { updated.group(id: $0)?.id }
            ?? updated.groups.first?.id
        root = updated
        if previous != activeGroup?.selected, let previous { onDeactivate?(previous) }
    }

    func activate(_ groupID: UUID) {
        guard root.group(id: groupID) != nil, activeGroupID != groupID else { return }
        let previous = activeGroup?.selected
        activeGroupID = groupID
        if let previous { onDeactivate?(previous) }
    }

    func group(containing item: DockItem) -> DockGroup? { root.group(containing: item) }

    func select(_ item: DockItem) {
        guard let owner = group(containing: item) else { return }
        if owner.selected != item {
            updateLayout(root.editingGroup(owner.id) { $0.selected = item }, activating: owner.id)
        } else {
            activate(owner.id)
        }
    }

    /// Keep new tabs near the selected tab, otherwise prefer an empty group.
    /// There is no privileged main/left/right container.
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
            ?? updated.groups.first(where: { $0.items.isEmpty })
            ?? updated.groups.first(where: { group in
                group.items.contains { if case .tab = $0 { return true }; return false }
            })
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
        let hadTerminalTabs = root.groups.contains { group in
            group.items.contains { if case .tab = $0 { return true }; return false }
        }
        let normalized = hadTerminalTabs
            ? (updated.removingEmptyGroups() ?? .group(DockGroup(items: [])))
            : updated
        updateLayout(normalized)
    }

    func move(_ item: DockItem, into destinationID: UUID, edge: DockEdge? = nil, index: Int? = nil) -> Bool {
        guard let source = root.group(containing: item),
              root.group(id: destinationID) != nil
        else { return false }
        if source.id == destinationID && source.items.count == 1 {
            guard edge == nil else { return false }
            select(item)
            return true
        }
        guard let remaining = root.removing(item) else { return false }
        let updated: DockNode
        if let edge {
            guard remaining.group(id: destinationID) != nil else { return false }
            updated = remaining.inserting(
                .group(DockGroup(items: [item])),
                edge: edge, at: destinationID
            )
        } else {
            guard let target = remaining.group(id: destinationID) else { return false }
            let sourceIndex = source.items.firstIndex(of: item)
            updated = remaining.editingGroup(target.id) { group in
                var insertAt = index ?? group.items.count
                if source.id == destinationID, let sourceIndex, sourceIndex < insertAt {
                    insertAt -= 1
                }
                insertAt = min(max(insertAt, 0), group.items.count)
                group.items.insert(item, at: insertAt)
                group.selected = item
            }
        }
        updateLayout(updated, activating: updated.group(containing: item)?.id)
        return true
    }

    @discardableResult
    func place(_ item: DockItem, in groupID: UUID) -> Bool {
        guard root.group(id: groupID) != nil else { return false }
        if root.group(containing: item) != nil { return move(item, into: groupID) }
        updateLayout(root.editingGroup(groupID) { group in
            group.items.append(item)
            group.selected = item
        }, activating: groupID)
        return true
    }

    func removeTool(_ item: DockItem) {
        if case .tab = item { return }
        if let remaining = root.removing(item) {
            updateLayout(remaining)
        } else if let owner = root.group(containing: item) {
            updateLayout(root.editingGroup(owner.id) { group in
                group.items.removeAll { $0 == item }
                group.selected = nil
            })
        }
    }

    func resize(_ splitID: UUID, to fraction: Double) {
        updateLayout(root.settingFraction(splitID, fraction))
    }

    func snapshot(tabIDs: [UUID]) -> DockSavedNode {
        DockSavedNode(root, tabIDs: tabIDs)
    }

    func restore(_ saved: DockSavedNode, tabIDs: [UUID]) {
        let restored = saved.restore(tabIDs: tabIDs)
        updateLayout(restored, activating: restored.groups.first?.id)
        // Normalize the saved tree: missing/unsnapshotable references and
        // project tabs opened since the snapshot must never disappear.
        syncTabs(tabIDs, near: nil)
    }

    var tabOrder: [UUID] {
        root.groups.flatMap(\.items).compactMap { item in
            if case .tab(let id) = item { return id }
            return nil
        }
    }

    var visibleItems: Set<DockItem> {
        Set(root.groups.flatMap(\.items))
    }
}
