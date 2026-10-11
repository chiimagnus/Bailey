import Foundation

@main
@MainActor
struct CheckDockWorkspace {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() throws {
        let dock = DockWorkspaceModel()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        dock.syncTabs([a, b], near: nil)
        let main = dock.group(region: .main)!
        let left = dock.group(region: .left)!
        check(main.items == [.tab(a), .tab(b)], "new tabs must appear in main group")
        check(dock.move(.git, into: main.id, edge: .bottom), "move git to bottom split")
        check(dock.root.groups.count == 4, "edge drop should create an auxiliary group")
        check(dock.group(containing: .git)?.region == .extra, "git was not moved")
        check(dock.group(region: .right)?.items == [.info, .files], "source group not updated")
        check(dock.move(.git, into: left.id), "merge git as left tab")
        check(dock.group(region: .left)?.selected == .git, "destination selection not updated")
        check(dock.root.groups.count == 3, "empty auxiliary group must collapse")
        dock.syncTabs([a, b, c], near: b)
        check(dock.move(.tab(a), into: main.id, index: 2), "reorder earlier tab")
        check(dock.group(region: .main)?.items == [.tab(b), .tab(a), .tab(c)], "reorder destination must account for removed index")
        check(dock.move(.tab(c), into: main.id, index: 0), "reorder later tab")
        check(dock.group(region: .main)?.items == [.tab(c), .tab(b), .tab(a)], "reverse reorder wrong")
        check(dock.move(.tab(c), into: main.id, edge: .top), "split content to auxiliary group")
        check(dock.root.groups.count == 4, "auxiliary split not created")
        dock.syncTabs([a, b], near: b)
        check(dock.root.groups.count == 3, "closing last auxiliary tab must collapse its group")

        let saved = dock.snapshot(tabIDs: [a, b])
        let encoded = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(DockSavedNode.self, from: encoded)
        let restored = DockWorkspaceModel()
        restored.restore(decoded, tabIDs: [b, c])
        check(restored.group(region: .main)?.items == [.tab(c), .tab(b)], "restored tab references must rebind by index")
        check(restored.group(region: .left)?.items == [.projects, .git], "tool placement must survive restore")
        check(restored.visibleItems.count == 6, "a tab or tool must not be duplicated")

        restored.syncTabs([b], near: b)
        check(!restored.visibleItems.contains(.tab(c)), "closed tab must leave the layout")
        check(restored.root.visible(left: false, right: false)?.groups.count == 1, "both collapsed sidebars must preserve main")
        check(restored.root.visible(left: true, right: true)?.groups.count == 3, "reopening must preserve original groups")
        check(restored.move(.projects, into: UUID()) == false, "stale target IDs should not modify layout")
        restored.place(.projects, in: .right)
        check(restored.group(region: .right)?.items.contains(.projects) == true, "project list should be movable")
        check(restored.group(region: .left)?.items == [.git], "moving must not clone panel")

        let legacy = DockWorkspaceModel()
        legacy.syncTabs([a], near: nil)
        check(legacy.group(region: .left)?.items == [.projects], "legacy sidebar default")
        check(legacy.group(region: .right)?.items == [.info, .files, .git], "legacy right panels default")

        print("PASS: docking, tab identity, split/merge, snapshots, sidebars, legacy defaults")
    }
}
