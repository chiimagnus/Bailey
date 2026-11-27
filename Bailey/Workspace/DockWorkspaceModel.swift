import CoreGraphics
import Foundation
import Observation

/// One movable workspace tab. A project owns its live editor/terminal tabs;
/// this model owns only where each tab is displayed.
nonisolated enum DockItem: Hashable, Sendable {
    case projects
    case files
    case git
    case tab(UUID)
    case filePreview(UUID)

    var tabID: UUID? {
        if case .tab(let id) = self { return id }
        return nil
    }

    var contentTabID: UUID? {
        if case .filePreview(let id) = self { return id }
        return tabID
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
    static func edge(at pointer: CGPoint, in frame: CGRect) -> DockEdge? {
        guard frame.contains(pointer), pointer.y >= frame.minY + 38 else { return nil }
        let x = (pointer.x - frame.minX) / max(frame.width, 1)
        let y = (pointer.y - frame.minY - 38) / max(frame.height - 38, 1)
        let nearest = min(x, 1 - x, y, 1 - y)
        guard nearest < 0.22 else { return nil }
        if nearest == x { return .left }
        if nearest == 1 - x { return .right }
        return nearest == y ? .top : .bottom
    }
}

struct DockGroup: Equatable {
    let id: UUID
    var items: [DockItem]
    var selected: DockItem?

    init(id: UUID = UUID(), items: [DockItem], selected: DockItem? = nil) {
        self.id = id
        self.items = items
        self.selected = selected.flatMap { items.contains($0) ? $0 : nil } ?? items.first
    }
}

struct DockSplit: Equatable {
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

indirect enum DockNode: Equatable {
    case group(DockGroup)
    case split(DockSplit)

    var groups: [DockGroup] {
        switch self {
        case .group(let group): return [group]
        case .split(let split): return split.first.groups + split.second.groups
        }
    }

    private func firstGroup(where matches: (DockGroup) -> Bool) -> DockGroup? {
        switch self {
        case .group(let group): return matches(group) ? group : nil
        case .split(let split):
            return split.first.firstGroup(where: matches) ?? split.second.firstGroup(where: matches)
        }
    }

    func group(id: UUID) -> DockGroup? { firstGroup { $0.id == id } }
    func group(containing item: DockItem) -> DockGroup? { firstGroup { $0.items.contains(item) } }

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

    /// Explicit panel removal folds only its own empty group; keep the last slot.
    func removing(_ item: DockItem) -> DockNode {
        guard let group = group(containing: item) else { return self }
        let updated = editingGroup(group.id) { group in
            group.items.removeAll { $0 == item }
            if group.selected == item { group.selected = group.items.first }
        }
        return updated.removingEmptyGroup(group.id) ?? updated
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

    func removingEmptyGroup(_ groupID: UUID) -> DockNode? {
        switch self {
        case .group(let group):
            return group.items.isEmpty && groupID == group.id ? nil : self
        case .split(var split):
            switch (split.first.removingEmptyGroup(groupID), split.second.removingEmptyGroup(groupID)) {
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
        case .filePreview: return nil
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

extension DockSavedGroup {
    init(_ group: DockGroup, tabIDs: [UUID]) {
        self.init(id: group.id, items: group.items.compactMap { DockSavedItem($0, tabIDs: tabIDs) },
                  selected: group.selected.flatMap { DockSavedItem($0, tabIDs: tabIDs) })
    }

    func restore(tabIDs: [UUID]) -> DockGroup {
        DockGroup(id: id, items: items.compactMap { $0.resolve(tabIDs: tabIDs) },
                  selected: selected?.resolve(tabIDs: tabIDs))
    }
}

indirect enum DockSavedNode: Codable {
    case group(DockSavedGroup)
    case split(id: UUID, axis: DockAxis, fraction: Double, first: DockSavedNode, second: DockSavedNode)

    init(_ node: DockNode) {
        switch node {
        case .group(let group):
            self = .group(DockSavedGroup(group, tabIDs: []))
        case .split(let split):
            self = .split(
                id: split.id, axis: split.axis, fraction: split.fraction,
                first: DockSavedNode(split.first),
                second: DockSavedNode(split.second)
            )
        }
    }

    var groups: [DockSavedGroup] {
        switch self {
        case .group(let group): [group]
        case .split(_, _, _, let first, let second): first.groups + second.groups
        }
    }

    func restoreLayout() -> DockNode {
        switch self {
        case .group(let saved):
            return .group(saved.restore(tabIDs: []))
        case .split(let id, let axis, let fraction, let first, let second):
            return .split(DockSplit(
                id: id, axis: axis, fraction: fraction,
                first: first.restoreLayout(), second: second.restoreLayout()
            ))
        }
    }
}

/// Owned by one window; contains only the split structure and tool panels.
@MainActor
@Observable
final class DockWindowLayout {
    var root = DockNode.split(DockSplit(
        axis: .horizontal, fraction: 0.24,
        first: .group(DockGroup(items: [.projects])),
        second: .split(DockSplit(
            axis: .horizontal, fraction: 0.52 / 0.76,
            first: .group(DockGroup(items: [])),
            second: .group(DockGroup(items: [.files, .git]))
        ))
    ))

    var availableTools: [DockItem] {
        [DockItem.projects, .files, .git].filter { root.group(containing: $0) == nil }
    }

    @discardableResult
    func resize(_ splitID: UUID, to fraction: Double) -> Bool {
        let updated = root.settingFraction(splitID, fraction)
        guard updated != root else { return false }
        root = updated
        return true
    }
}

@MainActor
@Observable
final class DockWorkspaceModel {
    enum SelectionChange { case replace, preserve, toggle, range }
    enum CommandScope { case selection, otherTabs }
    private struct ExtendedSelection {
        var items: Set<DockItem>
        var anchor: DockItem?
    }
    private var extendedSelections: [UUID: ExtendedSelection] = [:]
    let layout: DockWindowLayout
    // Only groups differing from the window defaults belong to the project.
    private var contents: [DockGroup] = []
    private var preferredGroupID: UUID?

    var root: DockNode {
        let structure = layout.root
        guard !contents.isEmpty else { return structure }
        let slots = structure.groups
        let ids = Set(slots.map(\.id))
        let fallback = slots.first { $0.items.isEmpty } ?? slots.first
        let local = Dictionary(contents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let displaced = contents.filter { !ids.contains($0.id) }
        return structure.mappingGroups { group in
            var items = group.items
            var selected = group.selected
            if let saved = local[group.id] {
                let allowed = Set(items)
                var tools = items.makeIterator()
                items = saved.items.compactMap { item in
                    item.contentTabID != nil ? item : (allowed.contains(item) ? tools.next() : nil)
                } + Array(tools)
                selected = saved.selected ?? selected
            }
            if group.id == fallback?.id {
                items.append(contentsOf: displaced.flatMap(\.items).filter { $0.contentTabID != nil })
                if let previous = displaced.first(where: { $0.id == preferredGroupID }) {
                    selected = previous.selected ?? selected
                }
            }
            group = DockGroup(id: group.id, items: items, selected: selected)
        }
    }

    var activeGroupID: UUID? {
        if let preferredGroupID, layout.root.group(id: preferredGroupID) != nil { return preferredGroupID }
        let selected = contents.first { $0.id == preferredGroupID }?.selected
        return selected.flatMap { root.group(containing: $0)?.id } ?? layout.root.groups.first?.id
    }
    private(set) var contextTarget: DockItem?
    @ObservationIgnored var onSnapshotChange: (() -> Void)?
    @ObservationIgnored var onDeactivate: ((DockItem) -> Void)?
    @ObservationIgnored var onActiveItemChange: ((DockItem?, DockItem?) -> Void)?

    init(layout: DockWindowLayout) {
        self.layout = layout
        preferredGroupID = self.layout.root.groups.first?.id
    }

    var activeGroup: DockGroup? { activeGroupID.flatMap { root.group(id: $0) } }

    func selection(in groupID: UUID) -> [DockItem] {
        guard let group = root.group(id: groupID) else { return [] }
        let selected = (extendedSelections[groupID]?.items ?? []).union(group.selected.map { [$0] } ?? [])
        return group.items.filter { selected.contains($0) }
    }

    func anchor(in groupID: UUID) -> DockItem? {
        extendedSelections[groupID]?.anchor.flatMap { root.group(id: groupID)?.items.contains($0) == true ? $0 : nil }
    }

    func commandTargets(for item: DockItem, scope: CommandScope = .selection) -> [DockItem] {
        guard let group = group(containing: item) else { return [] }
        let selected = selection(in: group.id)
        let targets = selected.contains(item) ? selected : [item]
        switch scope {
        case .selection: return targets
        case .otherTabs: return group.items.filter { $0.tabID != nil && !targets.contains($0) }
        }
    }

    private func reconcileSelection(with updated: DockNode, activating groupID: UUID?) {
        if let groupID, groupID != activeGroupID, let old = activeGroupID {
            extendedSelections[old] = nil
        }
        for (identity, var state) in extendedSelections {
            guard let group = updated.group(id: identity) else {
                extendedSelections[identity] = nil
                continue
            }
            state.items.formIntersection(group.items)
            if let displayed = group.selected { state.items.insert(displayed) }
            if let anchor = state.anchor, !state.items.contains(anchor) { state.anchor = nil }
            extendedSelections[identity] = state.items.count > 1 || state.anchor != nil ? state : nil
        }
    }

    func selectForContextMenu(_ item: DockItem) {
        guard group(containing: item) != nil else { return }
        contextTarget = item
    }

    func clearContextTarget() { contextTarget = nil }

    private func update(_ updated: DockNode, from old: DockNode, activating groupID: UUID? = nil,
                        changesLayout: Bool = false) {
        let previous = activeGroupID.flatMap { old.group(id: $0)?.selected }
        reconcileSelection(with: updated, activating: groupID)
        if contextTarget.map({ updated.group(containing: $0) == nil }) == true {
            contextTarget = nil
        }
        if groupID != nil { contextTarget = nil }
        preferredGroupID = (groupID ?? activeGroupID).flatMap { updated.group(id: $0)?.id }
            ?? updated.groups.first?.id
        if changesLayout {
            let structure = updated.mappingGroups { group in
                group.items.removeAll { $0.contentTabID != nil }
                group.selected = layout.root.group(id: group.id)?.selected
                    .flatMap { group.items.contains($0) ? $0 : nil } ?? group.items.first
            }
            if layout.root != structure { layout.root = structure }
        }
        let groups = updated.groups.filter { layout.root.group(id: $0.id) != $0 }
        if contents != groups { contents = groups }
        if old != updated { onSnapshotChange?() }
        let current = preferredGroupID.flatMap { updated.group(id: $0)?.selected }
        if previous != current {
            if let previous, previous.contentTabID == nil || previous.contentTabID != current?.contentTabID {
                onDeactivate?(previous)
            }
            onActiveItemChange?(previous, current)
        }
    }

    func activate(_ groupID: UUID) {
        guard root.group(id: groupID) != nil, activeGroupID != groupID else { return }
        contextTarget = nil
        let previous = activeGroup?.selected
        if let old = activeGroupID { extendedSelections[old] = nil }
        preferredGroupID = groupID
        let current = activeGroup?.selected
        if let previous, previous.contentTabID == nil || previous.contentTabID != current?.contentTabID {
            onDeactivate?(previous)
        }
        if previous != current {
            onActiveItemChange?(previous, current)
        }
    }

    func group(containing item: DockItem) -> DockGroup? { root.group(containing: item) }

    func select(_ item: DockItem, activating: Bool = true,
                extending change: SelectionChange = .replace, preferred: @autoclosure () -> [DockItem] = []) {
        let current = root
        guard let owner = current.group(containing: item) else { return }
        var selected = Set(selection(in: owner.id))
        var anchor = anchor(in: owner.id)
        var displayed = item
        switch change {
        case .replace:
            selected = [item]
            anchor = nil
        case .preserve:
            if !selected.contains(item) { selected = [item]; anchor = nil }
        case .toggle:
            if selected.contains(item) {
                if selected.count == 1 { return }
                selected.remove(item)
                if owner.selected == item {
                    displayed = (preferred() + owner.items).first { selected.contains($0) } ?? item
                } else { displayed = owner.selected ?? item }
                if anchor == item { anchor = nil }
            } else {
                selected.insert(item)
                anchor = item
            }
        case .range:
            let origin = anchor.flatMap { selected.contains($0) ? $0 : nil } ?? owner.selected ?? item
            anchor = origin
            guard let start = owner.items.firstIndex(of: origin),
                  let end = owner.items.firstIndex(of: item) else { return }
            let opposite = end > start ? -1 : 1
            var cursor = start + opposite
            while owner.items.indices.contains(cursor), selected.contains(owner.items[cursor]) {
                selected.remove(owner.items[cursor])
                cursor += opposite
            }
            selected.formUnion(owner.items[min(start, end)...max(start, end)])
        }
        selected.insert(displayed)
        let state = ExtendedSelection(items: selected, anchor: anchor)
        extendedSelections[owner.id] = selected.count > 1 || anchor != nil ? state : nil
        if activating { contextTarget = nil }
        if owner.selected != displayed {
            update(current.editingGroup(owner.id) { $0.selected = displayed },
                   from: current, activating: activating ? owner.id : nil)
        } else if activating {
            activate(owner.id)
        }
    }

    func reconcileLayout() {
        let current = root
        update(current, from: current)
    }

    /// Keep new tabs near the selected tab, otherwise prefer an empty group.
    /// There is no privileged main/left/right container.
    func syncTabs(_ tabIDs: [UUID], near selectedTab: UUID?) {
        let allowed = Set(tabIDs)
        var seen = Set<DockItem>()
        let current = root
        var updated = current.mappingGroups { group in
            group.items = group.items.filter { item in
                if let id = item.contentTabID, !allowed.contains(id) { return false }
                return seen.insert(item).inserted
            }
            if let selected = group.selected, !group.items.contains(selected) {
                group.selected = group.items.first
            }
        }
        let missing = tabIDs.map(DockItem.tab).filter { !seen.contains($0) }
        if !missing.isEmpty {
            let groups = updated.groups
            if let destination = selectedTab.flatMap({ updated.group(containing: .tab($0)) })
                ?? groups.first(where: { $0.items.isEmpty })
                ?? groups.first(where: { $0.items.contains { $0.tabID != nil } })
                ?? groups.first {
                updated = updated.editingGroup(destination.id) { group in
                    group.items.append(contentsOf: missing)
                    group.selected = missing.last
                }
            }
        }
        // Opening or closing project content does not create or remove window regions.
        update(updated, from: current)
    }

    func move(_ item: DockItem, into destinationID: UUID, edge: DockEdge? = nil, index: Int? = nil,
              items: [DockItem]? = nil, sourceGroupID: UUID? = nil) -> Bool {
        let current = root
        guard let source = current.group(containing: item), current.group(id: destinationID) != nil,
              sourceGroupID == nil || sourceGroupID == source.id else { return false }
        let requested = items ?? commandTargets(for: item)
        let movingSet = Set(requested)
        let moving = source.items.filter { movingSet.contains($0) }
        guard moving.contains(item), moving.count == requested.count else { return false }
        if source.id == destinationID, edge != nil, moving.count == source.items.count { return false }
        if source.id == destinationID, edge == nil,
           let first = source.items.firstIndex(where: movingSet.contains),
           let last = source.items.lastIndex(where: movingSet.contains),
           (first...last + 1).contains(min(max(index ?? source.items.count, 0), source.items.count)) { return false }
        var updated = current.editingGroup(source.id) { group in
            group.items.removeAll { movingSet.contains($0) }
            if let selected = group.selected, movingSet.contains(selected) { group.selected = group.items.first }
        }
        let targetID: UUID
        if let edge {
            let newGroup = DockGroup(items: moving, selected: item)
            targetID = newGroup.id
            updated = updated.inserting(.group(newGroup), edge: edge, at: destinationID)
        } else {
            targetID = destinationID
            updated = updated.editingGroup(destinationID) { group in
                var insertAt = index ?? group.items.count
                if source.id == destinationID {
                    let originalIndex = min(max(index ?? source.items.count, 0), source.items.count)
                    insertAt = originalIndex - source.items.prefix(originalIndex).filter { movingSet.contains($0) }.count
                }
                insertAt = min(max(insertAt, 0), group.items.count)
                group.items.insert(contentsOf: moving, at: insertAt)
                group.selected = item
            }
        }
        if source.id != targetID {
            updated = updated.removingEmptyGroup(source.id) ?? updated
        }
        update(updated, from: current, activating: targetID, changesLayout: true)
        extendedSelections[source.id] = nil
        extendedSelections[targetID] = moving.count > 1 ? ExtendedSelection(items: movingSet, anchor: item) : nil
        return true
    }

    @discardableResult
    func place(_ item: DockItem, in groupID: UUID) -> Bool {
        let current = root
        guard current.group(id: groupID) != nil else { return false }
        if current.group(containing: item) != nil { return move(item, into: groupID) }
        update(current.editingGroup(groupID) { group in
            group.items.append(item)
            group.selected = item
        }, from: current, activating: groupID, changesLayout: item.contentTabID == nil)
        return true
    }

    func removeTool(_ item: DockItem) {
        if case .tab = item { return }
        if case .filePreview(let id) = item {
            setFilePreview(of: id, visible: false)
            return
        }
        let current = root
        let remaining = current.removing(item)
        if remaining != current { update(remaining, from: current, changesLayout: true) }
    }

    func setFilePreview(of tabID: UUID, visible: Bool) {
        let item = DockItem.filePreview(tabID)
        let current = root
        guard let sourceGroup = current.group(containing: .tab(tabID)) else { return }
        if visible {
            guard current.group(containing: item) == nil else { return }
            let preview = DockNode.group(DockGroup(items: [item]))
            update(current.inserting(preview, edge: .right, at: sourceGroup.id), from: current, changesLayout: true)
        } else if current.group(containing: item) != nil {
            var updated = current.removing(item)
            let destination = activeGroup?.selected == item ? sourceGroup.id : nil
            if let destination { updated = updated.editingGroup(destination) { $0.selected = .tab(tabID) } }
            update(updated, from: current, activating: destination, changesLayout: true)
        }
    }

    func snapshot(tabIDs: [UUID]) -> [DockSavedGroup] {
        root.groups.filter { layout.root.group(id: $0.id) != $0 }
            .map { DockSavedGroup($0, tabIDs: tabIDs) }
    }

    func restore(_ saved: [DockSavedGroup], tabIDs: [UUID]) {
        extendedSelections.removeAll()
        contents = saved.map { $0.restore(tabIDs: tabIDs) }
        preferredGroupID = layout.root.groups.first?.id
        syncTabs(tabIDs, near: nil)
    }

    var tabOrder: [UUID] {
        root.groups.flatMap(\.items).compactMap { item in
            if case .tab(let id) = item { return id }
            return nil
        }
    }

}
