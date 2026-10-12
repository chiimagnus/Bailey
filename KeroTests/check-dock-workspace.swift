import CoreGraphics
import Foundation

@main
@MainActor
struct CheckDockWorkspace {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() throws {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 300)
        check(DockDropHitTest.edge(at: CGPoint(x: 12, y: 170), in: frame) == .left, "left drop")
        check(DockDropHitTest.edge(at: CGPoint(x: 308, y: 170), in: frame) == .right, "right drop")
        check(DockDropHitTest.edge(at: CGPoint(x: 160, y: 60), in: frame) == .top, "top drop")
        check(DockDropHitTest.edge(at: CGPoint(x: 160, y: 317), in: frame) == .bottom, "bottom drop")
        check(DockDropHitTest.edge(at: CGPoint(x: 160, y: 170), in: frame) == nil, "merge center")
        check(DockDropHitTest.edge(at: CGPoint(x: 12, y: 25), in: frame) == nil, "tab header")

        let dock = DockWorkspaceModel()
        let defaults = dock.root.groups
        check(defaults.count == 3, "default three-column workspace")
        check(defaults[0].items == [.projects], "projects default")
        check(defaults[1].items.isEmpty, "empty middle group")
        check(defaults[2].items == [.files, .git], "tools default")
        check(defaults[2].selected == .files, "default file manager tab selection")
        if case .split(let outer) = dock.root,
           case .split(let inner) = outer.second {
            check(abs(outer.fraction - 0.12) < 0.0001, "configured outer fraction")
            check(abs(inner.fraction - 0.787) < 0.0001, "configured inner fraction")
        } else { preconditionFailure("default horizontal split configuration") }

        let configured = DockWorkspaceConfiguration(
            groupNames: ["files", "projects,info", "git"],
            selectedNames: ["files", "info", "git"],
            weights: [2, 3, 1],
            actionNames: ["session", "git", "projects", "files"], edgeThreshold: 0.1
        )!
        let customDock = DockWorkspaceModel(configuration: configured)
        check(customDock.root.groups.map(\.items) == [
            [.files], [.projects], [.git]
        ], "configuration controls all initial groups")
        check(customDock.root.groups[1].selected == .projects, "removed Info selection falls back within its group")
        check(customDock.configuration.addActions == [.session, .git, .projects, .files],
              "configuration controls add-menu ordering")
        let nearEdge = CGPoint(x: 55, y: 160)
        check(DockDropHitTest.edge(at: nearEdge, in: frame) == .left, "default edge accepts 15%")
        check(DockDropHitTest.edge(at: nearEdge, in: frame,
              threshold: CGFloat(configured.edgeThreshold)) == nil, "configured edge rejects 15%")
        let invalid = [
            (["projects,projects"], ["projects"], [1.0], ["session"], 0.22),
            (["projects,unknown"], ["projects"], [1.0], ["session"], 0.22),
            (["projects,,git"], ["projects"], [1.0], ["session"], 0.22),
            (["projects"], ["git"], [1.0], ["session"], 0.22),
            (["projects"], ["projects"], [0.0], ["session"], 0.22),
            (["projects"], ["projects"], [1.0], ["session", "session"], 0.22),
            (["projects"], ["projects"], [1.0], ["files"], 0.22),
            (["projects"], ["projects"], [1.0], ["session"], 0.22),
            (["projects"], ["projects"], [1.0], ["session"], 0.95)
        ]
        for (groups, selected, weights, actions, edge) in invalid {
            check(DockWorkspaceConfiguration(
                groupNames: groups, selectedNames: selected, weights: weights,
                actionNames: actions, edgeThreshold: edge
            ) == nil, "malformed configuration rejected")
        }

        let newSessionDock = DockWorkspaceModel()
        let leftTarget = newSessionDock.root.groups[0].id
        let newID = UUID()
        newSessionDock.syncTabs([newID], near: nil)
        check(newSessionDock.move(.tab(newID), into: leftTarget),
              "the plus button can place a new session in the clicked group")
        check(newSessionDock.group(containing: .tab(newID))?.id == leftTarget,
              "new session must not remain in the original middle group")

        let a = UUID(), b = UUID(), c = UUID()
        dock.syncTabs([a, b], near: nil)
        let center = defaults[1].id
        let projects = defaults[0].id
        check(dock.root.group(id: center)?.items == [.tab(a), .tab(b)], "tabs in empty group")
        check(dock.move(.git, into: center, edge: .bottom), "split tool below terminals")
        check(dock.root.groups.count == 4, "four groups after split")
        check(dock.move(.git, into: projects), "merge tool with projects")
        check(dock.root.groups.count == 3, "empty split collapses")
        check(dock.root.group(id: projects)?.items == [.projects, .git], "merge destination")

        dock.syncTabs([a, b, c], near: b)
        check(dock.move(.tab(a), into: center, index: 2), "move earlier tab")
        check(dock.root.group(id: center)?.items == [.tab(b), .tab(a), .tab(c)], "index adjusted")
        check(dock.move(.tab(c), into: center, index: 0), "move later tab")
        check(dock.root.group(id: center)?.items == [.tab(c), .tab(b), .tab(a)], "tab reordered")
        check(dock.tabOrder == [c, b, a], "keyboard order")
        check(dock.move(.tab(c), into: center, edge: .top), "split session")
        check(dock.root.groups.count == 4, "four groups after session split")
        dock.syncTabs([a, b], near: b)
        check(dock.root.groups.count == 3, "empty split closed")

        let data = try JSONEncoder().encode(dock.snapshot(tabIDs: [a, b]))
        check(!String(decoding: data, as: UTF8.self).contains("region"), "no region persistence")
        let restored = DockWorkspaceModel(configuration: configured)
        restored.restore(try JSONDecoder().decode(DockSavedNode.self, from: data), tabIDs: [b, c])
        check(restored.root.groups.count == 3, "saved layout overrides configured initial groups")
        check(restored.root.group(id: center)?.items == [.tab(c), .tab(b)], "tab identity rebound")
        check(restored.root.group(id: projects)?.items == [.projects, .git], "tool location persisted")
        check(restored.visibleItems.count == 5, "no duplication")
        check(!restored.move(.projects, into: UUID()), "invalid target rejected")

        let target = restored.root.groups.last!.id
        check(restored.place(.projects, in: target), "move projects anywhere")
        check(restored.root.group(id: projects)?.items == [.git], "origin updated")
        check(restored.root.group(id: target)?.items.contains(.projects) == true, "target updated")
        restored.removeTool(.git)
        check(!restored.visibleItems.contains(.git), "close tool")
        check(restored.place(.git, in: center), "reopen selected group")
        check(restored.group(containing: .git)?.id == center, "exact reopen target")

        let stacked = DockWorkspaceModel()
        let first = stacked.root.groups[0].id
        check(stacked.move(.files, into: first, edge: .top), "stack files above projects")
        check(stacked.root.groups.count == 3, "empty groups collapse when splitting")
        if case .split(let outer) = stacked.root,
           case .split(let inner) = outer.first {
            check(abs(outer.fraction - 0.12) < 0.001, "outer width preserved")
            check(inner.fraction == 0.5, "nested split half")
            stacked.resize(outer.id, to: 0.25)
            stacked.resize(inner.id, to: 0.65)
            check(stacked.group(containing: .files) != nil, "resizing keeps nested tab")
        } else { preconditionFailure("nested split tree") }

        print("PASS: uniform dock groups, splits, tab order, snapshots, tool restore")
    }
}
