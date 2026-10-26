import CoreGraphics
import Observation
import XCTest
@testable import Bailey

@MainActor
final class DockWorkspaceTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    func testGitChangesPreviewDisplaysDiffWithoutActivatingEditorGroup() throws {
        let project = Project(fallbackName: "Git preview", workspaceConfiguration: .standard)
        let gitGroup = try XCTUnwrap(project.dock.group(containing: .git))
        project.dock.select(.git)
        let repo = "/tmp/bailey-focus-git-preview"
        project.openDiff(repoRoot: repo, path: "src/alpha.swift", staged: false,
                         untracked: true, origPath: nil, activating: false)
        let diff = try XCTUnwrap(project.selectedTab)
        let destination = try XCTUnwrap(project.dock.group(containing: .tab(diff.id)))
        XCTAssertEqual(project.dock.activeGroupID, gitGroup.id)
        XCTAssertEqual(destination.selected, .tab(diff.id))
        XCTAssertNil(project.focusedContent)
        project.openDiff(repoRoot: repo, path: "src/alpha.swift", staged: false,
                         untracked: true, origPath: nil, activating: false)
        XCTAssertEqual(project.tabs.count, 1, "Preview reuses the existing Diff tab")
        XCTAssertEqual(project.dock.activeGroupID, gitGroup.id)
        project.openDiff(repoRoot: repo, path: "src/alpha.swift", staged: false,
                         untracked: true, origPath: nil, activating: true)
        XCTAssertEqual(project.dock.activeGroupID, destination.id)
        XCTAssertEqual(project.focusedContent?.id, diff.content.id)
    }

    func testBrowsingFilesShowsNewAndExistingDocumentsWithoutActivatingEditor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("preview.swift").path
        try "let preview = 1\n".write(toFile: path, atomically: true, encoding: .utf8)
        let project = Project(fallbackName: "preview", workspaceConfiguration: .standard)
        let files = try XCTUnwrap(project.dock.group(containing: .files))
        project.dock.activate(files.id)
        project.openFile(path, activating: false)
        let tab = try XCTUnwrap(project.selectedTab)
        let fileGroup = try XCTUnwrap(project.dock.group(containing: .tab(tab.id)))
        XCTAssertNotEqual(fileGroup.id, files.id)
        XCTAssertEqual(fileGroup.selected, .tab(tab.id))
        XCTAssertEqual(project.dock.activeGroupID, files.id)
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
        XCTAssertNil(project.focusedContent)
        project.openFile(path, activating: false)
        XCTAssertEqual(project.tabs.count, 1)
        XCTAssertEqual(project.dock.activeGroupID, files.id)
        project.openFile(path)
        XCTAssertEqual(project.dock.activeGroupID, fileGroup.id)
        XCTAssertEqual(project.focusedContent?.id, tab.content.id)
    }

    func testBrowsingSameGroupMustNotKeepFocusOnHiddenFilesPanel() throws {
        let configuration = try XCTUnwrap(DockWorkspaceConfiguration(
            groupNames: ["projects,files,git"], selectedNames: ["files"],
            weights: [1], actionNames: ["session", "projects", "files", "git"],
            edgeThreshold: 0.22
        ))
        let project = Project(fallbackName: "same group", workspaceConfiguration: configuration)
        let path = "/tmp/preview-in-same-group.swift"
        project.dock.select(.files)
        project.openFile(path, activating: false)
        let tab = try XCTUnwrap(project.selectedTab)
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(tab.id))
        XCTAssertEqual(project.focusedContent?.id, tab.content.id,
                       "When Files is hidden, a visible document must receive focus")
    }

    func testFocusingAlreadyVisibleWorkTabsDoesNotRequestASnapshot() throws {
        let project = Project(fallbackName: "transient focus", workspaceConfiguration: .standard)
        project.newBrowserTab(initialFocus: .none)
        let first = try XCTUnwrap(project.selectedTab)
        project.newBrowserTab(initialFocus: .none)
        let second = try XCTUnwrap(project.selectedTab)
        let target = try XCTUnwrap(project.dock.group(containing: .files))
        XCTAssertTrue(project.dock.move(.tab(first.id), into: target.id, edge: .bottom))
        project.selectTab(second.id)
        var snapshots = 0
        project.onSnapshotChange = { snapshots += 1 }
        for tab in [first, second, first, second] {
            project.selectTab(tab.id)
            XCTAssertEqual(project.selectedTabID, tab.id)
            XCTAssertEqual(project.focusedContent?.id, tab.content.id)
            XCTAssertEqual(project.dock.group(containing: .tab(tab.id))?.selected, .tab(tab.id))
        }
        XCTAssertEqual(snapshots, 0)
    }

    func testPanelNavigationSkipsToolPanels() throws {
        let project = Project(fallbackName: "Panels", workspaceConfiguration: .standard)
        let emptyGroup = try XCTUnwrap(project.dock.root.groups.first { $0.items.isEmpty })
        project.dock.activate(emptyGroup.id)
        project.selectNextPanel()
        project.selectPreviousPanel()
        XCTAssertEqual(project.dock.activeGroupID, emptyGroup.id)
        XCTAssertNil(project.dock.activeGroup?.selected)
        project.dock.select(.git)
        project.selectNextPanel()
        project.selectPreviousPanel()
        XCTAssertEqual(project.dock.activeGroup?.selected, .git)

        project.newBrowserTab(initialFocus: .none)
        let onlyTab = try XCTUnwrap(project.selectedTabID)
        project.dock.select(.files)
        project.selectNextPanel()
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(onlyTab))
        project.dock.select(.git)
        project.selectPreviousPanel()
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(onlyTab))

        project.newBrowserTab(initialFocus: .none)
        let order = project.dock.tabOrder
        XCTAssertEqual(order.count, 2)

        for (index, id) in order.enumerated() {
            project.selectPanel(.tab(id))
            project.selectNextPanel()
            XCTAssertEqual(project.dock.activeGroup?.selected, .tab(order[(index + 1) % order.count]))
            project.selectPreviousPanel()
            XCTAssertEqual(project.dock.activeGroup?.selected, .tab(id))
        }

        for tool in [DockItem.projects, .files, .git] {
            project.selectPanel(tool)
            XCTAssertEqual(project.dock.activeGroup?.selected, tool)
            project.selectNextPanel()
            XCTAssertEqual(project.dock.activeGroup?.selected, .tab(order[0]))
            project.selectPanel(tool)
            project.selectPreviousPanel()
            XCTAssertEqual(project.dock.activeGroup?.selected, .tab(order[1]))
        }

        project.dock.removeTool(.files)
        XCTAssertEqual(project.dock.tabOrder, order)
        project.selectNextPanel()
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(order[0]))
    }

    func testAddPanelOnlyOffersMissingToolsAcrossAllGroups() throws {
        let dock = DockWorkspaceModel()
        let emptyGroup = try XCTUnwrap(dock.root.groups.first { $0.items.isEmpty })
        XCTAssertEqual(dock.availableAddActions(), [.session])

        XCTAssertTrue(dock.move(.files, into: emptyGroup.id))
        let otherGroup = try XCTUnwrap(dock.group(containing: .projects))
        XCTAssertEqual(dock.availableAddActions(), [.session],
                       "A tool moved into another group must not appear as addable")

        dock.removeTool(.files)
        XCTAssertEqual(dock.availableAddActions(), [.session, .files])
        XCTAssertTrue(dock.place(.files, in: otherGroup.id))
        XCTAssertEqual(dock.availableAddActions(), [.session])

        dock.removeTool(.git)
        dock.removeTool(.projects)
        XCTAssertEqual(dock.availableAddActions(), [.session, .projects, .git])
        XCTAssertEqual(DockWorkspaceModel().availableAddActions(), [.session],
                       "Other projects retain their own available tool list")
    }

    func testToolsCanMoveIntoEmptyGroupsAtTheCenterAndEveryEdge() throws {
        for item in [DockItem.projects, .files, .git] {
            for edge in [nil, DockEdge.left, .right, .top, .bottom] {
                let dock = DockWorkspaceModel()
                let empty = try XCTUnwrap(dock.root.groups.first(where: { $0.items.isEmpty }))
                XCTAssertTrue(dock.move(item, into: empty.id, edge: edge), "\(item), \(String(describing: edge))")
                XCTAssertEqual(dock.activeGroup?.selected, item)
                if edge == nil { XCTAssertEqual(dock.activeGroupID, empty.id) }
                XCTAssertEqual(dock.root.groups.flatMap(\.items).filter { $0 == item }.count, 1)
            }
        }
    }

    func testSingleAndTwoGroupLayoutsAndEmptyToolOnlyProject() throws {
        for names in [["projects,files,git"], ["projects", "files,git"]] {
            let configuration = try XCTUnwrap(DockWorkspaceConfiguration(
                groupNames: names, selectedNames: names.map { String($0.split(separator: ",")[0]) },
                weights: names.map { _ in 1 }, actionNames: ["session", "projects", "files", "git"],
                edgeThreshold: 0.22
            ))
            let manager = self.workspaceApplication.makeWindow()
            defer { manager.windowClosed() }
            let project = Project(fallbackName: "empty", workspaceConfiguration: configuration)
            manager.projects = [project]
            manager.selectedProjectID = project.id
            XCTAssertEqual(project.dock.root.groups.count, names.count)
            for tool in [DockItem.files, .git, .projects] {
                manager.showPanel(tool)
                XCTAssertNil(project.focusedContent)
                manager.closeSelectedTab()
                XCTAssertNil(project.dock.group(containing: tool))
                XCTAssertTrue(manager.selectedProject === project)
                XCTAssertNotNil(project.dock.activeGroup)
            }
            XCTAssertTrue(project.tabs.isEmpty)
            XCTAssertNil(project.dock.activeGroup?.selected)
        }
    }

    func testClosingRecentWorkDoesNotOverrideAnActiveTool() throws {
        let project = Project(fallbackName: "close focus", workspaceConfiguration: .standard)
        project.newBrowserTab(initialFocus: .none)
        project.newBrowserTab(initialFocus: .none)
        let recent = try XCTUnwrap(project.selectedTab)
        project.dock.select(.files)
        let tools = project.dock.activeGroupID
        project.close(recent)
        XCTAssertEqual(project.tabs.count, 1)
        XCTAssertEqual(project.dock.activeGroupID, tools)
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
        XCTAssertNil(project.focusedContent)
    }

    func testMovingActiveContentDoesNotDeactivateItThroughAnIntermediateGroup() throws {
        let dock = DockWorkspaceModel()
        let id = UUID()
        dock.syncTabs([id], near: nil)
        dock.select(.tab(id))
        var deactivated: [DockItem] = []
        dock.onDeactivate = { deactivated.append($0) }
        for edge in [DockEdge.left, .right, .top, .bottom] {
            let target = try XCTUnwrap(dock.group(containing: .files))
            XCTAssertTrue(dock.move(.tab(id), into: target.id, edge: edge))
            XCTAssertEqual(dock.activeGroup?.selected, .tab(id))
            XCTAssertTrue(deactivated.isEmpty)
        }
        XCTAssertFalse(dock.move(.tab(id), into: UUID()))
        XCTAssertEqual(dock.activeGroup?.selected, .tab(id))
        dock.select(.files)
        XCTAssertEqual(deactivated, [.tab(id)])
    }

    func testActivityIsTransientAndDoesNotChangeOtherGroupSelections() throws {
        let project = Project(fallbackName: "focus", workspaceConfiguration: .standard)
        let first = project.newBrowserTab(initialFocus: .none)
        let webView = first.webView
        let firstTab = try XCTUnwrap(project.selectedTab)
        project.newBrowserTab(initialFocus: .none)
        let dock = project.dock
        let tools = try XCTUnwrap(dock.group(containing: .files))
        XCTAssertTrue(dock.move(.tab(firstTab.id), into: tools.id, edge: .bottom))
        let selected = dock.root.groups.map(\.selected)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(dock.snapshot(tabIDs: project.tabs.map(\.id)))
        var snapshots = 0
        project.onSnapshotChange = { snapshots += 1 }
        for group in dock.root.groups {
            dock.activate(group.id)
            XCTAssertEqual(dock.activeGroupID, group.id)
            XCTAssertEqual(dock.root.groups.map(\.selected), selected)
        }
        let active = dock.activeGroupID
        dock.activate(UUID())
        XCTAssertEqual(dock.activeGroupID, active)
        XCTAssertEqual(snapshots, 0)
        XCTAssertEqual(try encoder.encode(dock.snapshot(tabIDs: project.tabs.map(\.id))), before)
        XCTAssertTrue(first.webView === webView)
        project.selectTab(firstTab.id)
        dock.select(.files)
        project.selectTab(firstTab.id)
        XCTAssertEqual(project.focusedContent?.id, first.id, "Reselecting MRU must reactivate its group")
    }

    func testActiveGroupSurvivesNestedMovesAndFallsBackAfterRemovalAndRestore() throws {
        let dock = DockWorkspaceModel()
        let ids = (0..<8).map { _ in UUID() }
        dock.syncTabs(ids, near: nil)
        for (index, id) in ids.enumerated() {
            let target = try XCTUnwrap(dock.group(containing: .files))
            XCTAssertTrue(dock.move(.tab(id), into: target.id, edge: index.isMultiple(of: 2) ? .bottom : .right))
            XCTAssertEqual(dock.activeGroup?.selected, .tab(id))
        }
        XCTAssertGreaterThan(dock.root.groups.count, 6)
        let oldActive = dock.activeGroupID
        dock.syncTabs(Array(ids.dropLast()), near: nil)
        XCTAssertNotEqual(dock.activeGroupID, oldActive)
        XCTAssertNotNil(dock.activeGroup)
        for tool in [DockItem.files, .git, .projects] {
            dock.select(tool)
            dock.removeTool(tool)
            XCTAssertNotNil(dock.activeGroup)
        }
        let other = DockWorkspaceModel()
        dock.restore(other.snapshot(tabIDs: []), tabIDs: [])
        XCTAssertNotNil(dock.activeGroup)
        XCTAssertTrue(dock.root.groups.contains { $0.id == dock.activeGroupID })
        dock.syncTabs([], near: nil)
        let empty = try XCTUnwrap(dock.root.groups.first(where: { $0.items.isEmpty }))
        dock.activate(empty.id)
        XCTAssertNil(dock.activeGroup?.selected)
    }

    func testToolsAreNotTheMostRecentWorkContentAndCloseTheirOwnPanel() throws {
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let project = Project(fallbackName: "focus", workspaceConfiguration: .standard)
        manager.projects = [project]
        manager.selectedProjectID = project.id
        let browser = project.newBrowserTab(initialFocus: .none)
        let workID = try XCTUnwrap(project.selectedTabID)
        for tool in [DockItem.files, .git, .projects] {
            manager.showPanel(tool)
            XCTAssertNil(project.focusedContent)
            XCTAssertEqual(project.selectedTabID, workID)
            XCTAssertFalse(manager.hasSelectedBrowser)
            XCTAssertFalse(manager.canFind)
            XCTAssertFalse(manager.canReplace)
            XCTAssertFalse(manager.canClearActiveTerminal)
            XCTAssertFalse(manager.canSaveSelectedFile)
            manager.closeSelectedTab()
            XCTAssertNil(project.dock.group(containing: tool))
            XCTAssertEqual(project.tabs.count, 1)
            XCTAssertEqual(project.tabs.first?.content.id, browser.id)
        }
    }

    func testNestedLayoutObservationAndDragCancelPreserveUniqueOwners() async throws {
        let project = Project(fallbackName: "dock observation", workspaceConfiguration: .standard)
        let browser = BrowserTab(initialFocus: .none)
        let pane = PaneTab(content: .browser(browser))
        project.append(pane)
        let webView = browser.webView
        let dock = project.dock
        let source = try XCTUnwrap(dock.group(containing: .tab(pane.id)))
        let destination = try XCTUnwrap(dock.group(containing: .files))
        let rootChanged = expectation(description: "Nested Dock root is observed without Project relay")
        withObservationTracking({ _ = project.dock.root.groups.flatMap(\.items) }) { rootChanged.fulfill() }
        var snapshotChanges = 0
        project.onSnapshotChange = { snapshotChanges += 1 }
        XCTAssertTrue(dock.move(.tab(pane.id), into: destination.id, edge: .bottom))
        await fulfillment(of: [rootChanged], timeout: 1)
        XCTAssertGreaterThan(snapshotChanges, 0)
        XCTAssertEqual(dock.tabOrder, [pane.id])
        XCTAssertTrue(browser.webView === webView)

        let dragging = DockTabDragCoordinator()
        let activityBeforePreview = dock.activeGroupID
        let moved = try XCTUnwrap(dock.group(containing: .tab(pane.id)))
        let frame = CGRect(x: 100, y: 100, width: 300, height: 400)
        let positionChanged = expectation(description: "Only real drag preview changes are observed")
        withObservationTracking({ _ = dragging.position }) { positionChanged.fulfill() }
        dragging.setFrames(groups: [moved.id: frame])
        dragging.setFrames(tabs: [.tab(pane.id): CGRect(x: 100, y: 100, width: 120, height: 38)])
        XCTAssertNil(dragging.position)
        dragging.update(.files, at: CGPoint(x: 101, y: 300), dock: dock)
        XCTAssertEqual(dock.activeGroupID, activityBeforePreview)
        await fulfillment(of: [positionChanged], timeout: 1)
        XCTAssertEqual(dragging.position?.destination, moved.id)
        XCTAssertEqual(dragging.position?.edge, .left)
        dragging.cancel()
        XCTAssertEqual(dock.activeGroupID, activityBeforePreview)
        XCTAssertNil(dragging.position)
        XCTAssertTrue(dock.root.groups.contains { $0.items.contains(.files) })
        dragging.update(.files, at: CGPoint(x: 160, y: 118), dock: dock)
        XCTAssertEqual(dragging.position?.index, 1)
        XCTAssertEqual(dragging.insertionX(in: moved), 220)
        dragging.update(.files, at: CGPoint(x: 159, y: 118), dock: dock)
        XCTAssertEqual(dragging.position?.index, 0)
        XCTAssertEqual(dragging.insertionX(in: moved), 100)
        dragging.finish(project: project)
        XCTAssertNil(dragging.position)
        XCTAssertEqual(dock.root.groups.flatMap(\.items).filter { $0 == .files }.count, 1)
        XCTAssertEqual(dock.group(containing: .files)?.id, moved.id)
        XCTAssertEqual(dock.activeGroupID, moved.id)
        XCTAssertEqual(dock.activeGroup?.selected, .files)
        XCTAssertNotEqual(source.id, moved.id)
        XCTAssertTrue(project.tabs.first === pane)
        XCTAssertTrue(browser.webView === webView)
    }

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
