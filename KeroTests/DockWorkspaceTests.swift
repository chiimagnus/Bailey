import CoreGraphics
import XCTest
@testable import kero

@MainActor
final class DockWorkspaceTests: XCTestCase {
    func testDefaultLayoutAndDropHitTesting() throws {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 300)
        XCTAssertEqual(DockDropHitTest.edge(at: CGPoint(x: 12, y: 170), in: frame), .left)
        XCTAssertEqual(DockDropHitTest.edge(at: CGPoint(x: 308, y: 170), in: frame), .right)
        XCTAssertEqual(DockDropHitTest.edge(at: CGPoint(x: 160, y: 60), in: frame), .top)
        XCTAssertEqual(DockDropHitTest.edge(at: CGPoint(x: 160, y: 317), in: frame), .bottom)
        XCTAssertNil(DockDropHitTest.edge(at: CGPoint(x: 160, y: 170), in: frame))
        XCTAssertNil(DockDropHitTest.edge(at: CGPoint(x: 12, y: 25), in: frame))

        let dock = DockWorkspaceModel()
        let groups = dock.root.groups
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].items, [.projects])
        XCTAssertTrue(groups[1].items.isEmpty)
        XCTAssertEqual(groups[2].items, [.files, .git])
        XCTAssertEqual(groups[2].selected, .files)

        guard case .split(let outer) = dock.root,
              case .split(let inner) = outer.second else {
            return XCTFail("Expected default nested horizontal split")
        }
        XCTAssertEqual(outer.fraction, 0.12, accuracy: 0.0001)
        XCTAssertEqual(inner.fraction, 0.787, accuracy: 0.0001)
    }

    func testConfigurationRejectsInvalidLayouts() throws {
        let configuration = try XCTUnwrap(DockWorkspaceConfiguration(
            groupNames: ["files", "projects,info", "git"],
            selectedNames: ["files", "info", "git"],
            weights: [2, 3, 1],
            actionNames: ["session", "git", "projects", "files"],
            edgeThreshold: 0.1
        ))
        XCTAssertEqual(configuration.groupNames, ["files", "projects", "git"])
        XCTAssertEqual(configuration.addActions, [.session, .git, .projects, .files])

        let invalid: [([String], [String], [Double], [String], Double)] = [
            (["projects,projects"], ["projects"], [1], ["session"], 0.22),
            (["projects,unknown"], ["projects"], [1], ["session"], 0.22),
            (["projects"], ["git"], [1], ["session"], 0.22),
            (["projects"], ["projects"], [0], ["session"], 0.22),
            (["projects"], ["projects"], [1], ["session", "session"], 0.22),
            (["projects"], ["projects"], [1], ["files"], 0.22),
            (["projects"], ["projects"], [1], ["session"], 0.95),
        ]
        for value in invalid {
            XCTAssertNil(DockWorkspaceConfiguration(
                groupNames: value.0,
                selectedNames: value.1,
                weights: value.2,
                actionNames: value.3,
                edgeThreshold: value.4
            ))
        }
    }

    func testMoveReorderSnapshotAndRestore() throws {
        let dock = DockWorkspaceModel()
        let initialGroups = dock.root.groups
        let center = initialGroups[1].id
        let projects = initialGroups[0].id
        let a = UUID(), b = UUID(), c = UUID()

        dock.syncTabs([a, b], near: nil)
        XCTAssertEqual(dock.root.group(id: center)?.items, [.tab(a), .tab(b)])
        XCTAssertTrue(dock.move(.git, into: center, edge: .bottom))
        XCTAssertEqual(dock.root.groups.count, 4)
        XCTAssertTrue(dock.move(.git, into: projects))
        XCTAssertEqual(dock.root.groups.count, 3)

        dock.syncTabs([a, b, c], near: b)
        XCTAssertTrue(dock.move(.tab(a), into: center, index: 2))
        XCTAssertEqual(dock.root.group(id: center)?.items, [.tab(b), .tab(a), .tab(c)])
        XCTAssertTrue(dock.move(.tab(c), into: center, index: 0))
        XCTAssertEqual(dock.tabOrder, [c, b, a])

        let data = try JSONEncoder().encode(dock.snapshot(tabIDs: [a, b, c]))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("region"))
        let saved = try JSONDecoder().decode(DockSavedNode.self, from: data)
        let restored = DockWorkspaceModel()
        restored.restore(saved, tabIDs: [a, b, c])
        XCTAssertEqual(restored.tabOrder, [c, b, a])
        XCTAssertFalse(restored.move(.projects, into: UUID()))
    }

    func testNestedResizeKeepsContent() throws {
        let dock = DockWorkspaceModel()
        let first = try XCTUnwrap(dock.root.groups.first?.id)
        XCTAssertTrue(dock.move(.files, into: first, edge: .top))
        guard case .split(let outer) = dock.root,
              case .split(let inner) = outer.first else {
            return XCTFail("Expected nested split")
        }
        dock.resize(outer.id, to: 0.25)
        dock.resize(inner.id, to: 0.65)
        XCTAssertNotNil(dock.group(containing: .files))
    }
}
