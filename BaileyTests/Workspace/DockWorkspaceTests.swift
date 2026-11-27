import CoreGraphics
import Observation
import XCTest
@testable import Bailey

@MainActor
final class DockWorkspaceTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    func testCloseOthersKeepsBackgroundGroupSelectionWithoutActivatingIt() throws {
        let project = Project(customDirectory: "/fixture/background menu", layout: .init())
        for _ in 0..<5 { project.newBrowserTab(initialFocus: .none) }
        let tabs = project.tabs
        let destination = try XCTUnwrap(project.dock.group(containing: .files))
        XCTAssertTrue(project.movePanels(.tab(tabs[1].id), into: destination.id,
            items: Array(tabs[1...3]).map { .tab($0.id) }))
        project.selectTab(tabs[0].id)
        project.dock.select(.tab(tabs[2].id), activating: false, extending: .toggle)
        let active = project.dock.activeGroupID
        let displayed = project.dock.root.group(id: destination.id)?.selected
        project.dock.selectForContextMenu(.tab(tabs[1].id))
        project.closeOthers(tabs[1])
        XCTAssertEqual(project.dock.activeGroupID, active)
        XCTAssertEqual(project.selectedTabID, tabs[0].id)
        XCTAssertEqual(project.dock.root.group(id: destination.id)?.selected, displayed)
        XCTAssertEqual(project.tabs.map(\.id), [tabs[0].id, tabs[1].id, tabs[2].id, tabs[4].id])
        XCTAssertNotNil(project.dock.group(containing: .files))
        XCTAssertNotNil(project.dock.group(containing: .git))
    }

    func testCloseOthersUsesUnselectedContextTargetAndKeepsSingletonTools() throws {
        let project = Project(customDirectory: "/fixture/alternate close menu", layout: .init())
        for _ in 0..<3 { project.newBrowserTab(initialFocus: .none) }
        let tabs = project.tabs
        let group = try XCTUnwrap(project.dock.group(containing: .tab(tabs[0].id)))
        XCTAssertTrue(project.dock.move(.git, into: group.id))
        project.selectTab(tabs[0].id)
        project.selectTab(tabs[2].id, extending: .toggle)
        project.dock.selectForContextMenu(.tab(tabs[1].id))
        project.closeOthers(tabs[1])
        XCTAssertEqual(project.tabs.map(\.id), [tabs[1].id])
        XCTAssertEqual(project.dock.group(containing: .git)?.id, group.id)
        XCTAssertNotNil(project.dock.group(containing: .files))
        XCTAssertNotNil(project.dock.group(containing: .projects))
    }

    func testEverySmallGroupSelectionAndInsertionBoundaryIsAtomic() throws {
        for count in 1...6 {
            for mask in 1..<(1 << count) {
                for index in -1...(count + 1) {
                    let dock = DockWorkspaceModel(layout: .init())
                    let ids = (0..<count).map { _ in UUID() }
                    let items = ids.map(DockItem.tab)
                    dock.syncTabs(ids, near: nil)
                    let source = try XCTUnwrap(dock.group(containing: items[0]))
                    let selectedIndices = (0..<count).filter { mask & (1 << $0) != 0 }
                    let selected = selectedIndices.map { items[$0] }
                    dock.select(selected[0])
                    for item in selected.dropFirst() { dock.select(item, extending: .toggle) }
                    let before = dock.root
                    var snapshots = 0
                    dock.onSnapshotChange = { snapshots += 1 }
                    let insertion = min(max(index, 0), count)
                    let noOp = (try XCTUnwrap(selectedIndices.first)...XCTUnwrap(selectedIndices.last) + 1).contains(insertion)
                    let moved = dock.move(selected[0], into: source.id, index: index)
                    XCTAssertEqual(moved, !noOp)
                    XCTAssertEqual(snapshots, noOp ? 0 : 1)
                    if noOp { XCTAssertEqual(dock.root, before) }
                    else {
                        var expected = items.filter { !selected.contains($0) }
                        expected.insert(contentsOf: selected, at: insertion - selectedIndices.filter { $0 < insertion }.count)
                        XCTAssertEqual(dock.activeGroup?.items, expected)
                        XCTAssertEqual(dock.selection(in: source.id), selected)
                    }
                }
            }
        }
    }

    func testBatchMoveMatrixPreservesOrderUniquenessAndRejectsInvalidSources() throws {
        for count in [1, 2, 32] {
            for edge in [nil, DockEdge.left, .right, .top, .bottom] {
                for entireGroup in [false, true] {
                    let dock = DockWorkspaceModel(layout: .init())
                    let ids = (0..<count).map { _ in UUID() }
                    let items = ids.map(DockItem.tab)
                    dock.syncTabs(ids, near: nil)
                    let source = try XCTUnwrap(dock.group(containing: items[0]))
                    let target = try XCTUnwrap(dock.group(containing: .files))
                    let selected = entireGroup ? items : items.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                    dock.select(selected[0])
                    for item in selected.dropFirst() { dock.select(item, extending: .toggle) }
                    let before = dock.root
                    var snapshots = 0
                    dock.onSnapshotChange = { snapshots += 1 }
                    for invalid in [[], [items[0], items[0]], [items[0], .git], [.tab(UUID())]] as [[DockItem]] {
                        XCTAssertFalse(dock.move(items[0], into: target.id, edge: edge, items: invalid))
                        XCTAssertEqual(dock.root, before)
                    }
                    XCTAssertFalse(dock.move(items[0], into: target.id, items: selected, sourceGroupID: UUID()))
                    XCTAssertFalse(dock.move(items[0], into: UUID(), items: selected))
                    XCTAssertEqual(snapshots, 0)
                    XCTAssertTrue(dock.move(selected[0], into: target.id, edge: edge, items: selected.reversed(), sourceGroupID: source.id))
                    let movedGroup = try XCTUnwrap(dock.group(containing: selected[0]))
                    XCTAssertEqual(movedGroup.items.filter { selected.contains($0) }, selected)
                    XCTAssertEqual(dock.selection(in: movedGroup.id), selected)
                    XCTAssertEqual(dock.root.group(id: source.id)?.items ?? [], items.filter { !selected.contains($0) })
                    XCTAssertEqual(dock.root.groups.flatMap(\.items).count, count + 3)
                    XCTAssertEqual(Set(dock.root.groups.flatMap(\.items)).count, count + 3)
                    XCTAssertEqual(snapshots, 1)
                }
            }
        }
    }

    func testIdleDragCancellationDoesNotInvalidateDockObservation() async throws {
        let project = Project(customDirectory: "/fixture/idle drag", layout: .init())
        let dragging = DockTabDragCoordinator()
        let invalidation = expectation(description: "No preview mutation without a drag position")
        invalidation.isInverted = true
        withObservationTracking({ _ = dragging.position }) { invalidation.fulfill() }
        for _ in 0..<30 { dragging.cancel() }
        dragging.begin(.files, dock: project.dock)
        dragging.cancel()
        await fulfillment(of: [invalidation], timeout: 0.1)
        XCTAssertNil(dragging.position)
    }

    func testDragSourceCannotRestartAfterCancelResizeOrLayoutInvalidation() throws {
        let project = Project(customDirectory: "/fixture/drag", layout: .init())
        project.newBrowserTab(initialFocus: .none)
        project.newBrowserTab(initialFocus: .none)
        let dock = project.dock
        let items = project.tabs.map { DockItem.tab($0.id) }
        project.selectTab(project.tabs[0].id)
        project.selectTab(project.tabs[1].id, extending: .toggle)
        let target = try XCTUnwrap(dock.group(containing: .files))
        let bounds = CGRect(x: 100, y: 100, width: 1000, height: 600)
        let frame = try XCTUnwrap(DockLayout(dock.root, in: bounds).panes.first { $0.id == target.id }).frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let dragging = DockTabDragCoordinator()
        let before = dock.root
        for invalidation in 0..<3 {
            dragging.setRootFrame(bounds)
            dragging.begin(items[0], dock: dock)
            dragging.update(items[0], at: point, dock: dock)
            XCTAssertEqual(dragging.position?.items, items)
            switch invalidation {
            case 0: dragging.cancel()
            case 1: dragging.setRootFrame(bounds.offsetBy(dx: 1, dy: 0))
            default:
                let other = Project(customDirectory: "/fixture/other window", layout: .init())
                dragging.finish(project: other)
                XCTAssertEqual(other.tabs.count, 0)
            }
            dragging.update(items[0], at: point, dock: dock)
            dragging.finish(project: project)
            XCTAssertEqual(dock.root, before)
            XCTAssertNil(dragging.position)
        }
        dragging.setRootFrame(bounds)
        dragging.begin(items[0], dock: dock)
        dragging.update(items[0], at: point, dock: dock)
        dock.removeTool(.git)
        let changed = dock.root
        dragging.update(items[0], at: point, dock: dock)
        dragging.finish(project: project)
        XCTAssertEqual(dock.root, changed)
        XCTAssertTrue(project.tabs.enumerated().allSatisfy { items[$0.offset] == .tab($0.element.id) })
    }

    func testBatchMoveCollapsesOnlyItsSourceAndPublishesOneFinalLayout() throws {
        for edge in [nil, DockEdge.left, .right, .top, .bottom] {
            let dock = DockWorkspaceModel(layout: .init())
            let source = try XCTUnwrap(dock.group(containing: .files))
            let target = try XCTUnwrap(dock.group(containing: .projects))
            let empty = try XCTUnwrap(dock.root.groups.first { $0.items.isEmpty })
            dock.select(.files)
            dock.select(.git, extending: .toggle)
            var snapshots: [DockNode] = []
            var deactivated: [DockItem] = []
            dock.onSnapshotChange = { snapshots.append(dock.root) }
            dock.onDeactivate = { deactivated.append($0) }
            XCTAssertTrue(dock.move(.git, into: target.id, edge: edge))
            XCTAssertNil(dock.root.group(id: source.id))
            XCTAssertNotNil(dock.root.group(id: empty.id), "Unrelated empty drop targets must survive")
            XCTAssertEqual(dock.selection(in: try XCTUnwrap(dock.activeGroupID)), [.files, .git])
            XCTAssertEqual(dock.activeGroup?.selected, .git)
            XCTAssertEqual(snapshots, [dock.root])
            XCTAssertTrue(deactivated.isEmpty, "Moving active content never deactivates it through an intermediate layout")
            XCTAssertEqual(Set(dock.root.groups.flatMap(\.items)), [.projects, .files, .git])
        }
    }

    func testBatchReorderRejectsSelectionInteriorAndAdjustsAllRemovedIndices() throws {
        for index in [-2, 0, 1, 2, 3, 4, 5, 6, 99] {
            let dock = DockWorkspaceModel(layout: .init())
            let ids = (0..<6).map { _ in UUID() }
            let items = ids.map(DockItem.tab)
            dock.syncTabs(ids, near: nil)
            let group = try XCTUnwrap(dock.group(containing: items[0]))
            dock.select(items[1])
            dock.select(items[3], extending: .toggle)
            let before = dock.root
            var snapshots = 0
            dock.onSnapshotChange = { snapshots += 1 }
            let moved = dock.move(items[1], into: group.id, index: index)
            if (1...4).contains(index) {
                XCTAssertFalse(moved, "A drop within the selected span is a no-op: \(index)")
                XCTAssertEqual(dock.root, before)
                XCTAssertEqual(snapshots, 0)
                XCTAssertEqual(dock.activeGroup?.selected, items[3])
            } else {
                let originalIndex = min(max(index, 0), items.count)
                let adjusted = originalIndex - [1, 3].filter { $0 < originalIndex }.count
                var expected = [items[0], items[2], items[4], items[5]]
                expected.insert(contentsOf: [items[1], items[3]], at: adjusted)
                XCTAssertTrue(moved)
                XCTAssertEqual(dock.root.group(id: group.id)?.items, expected)
                XCTAssertEqual(dock.activeGroup?.selected, items[1])
                XCTAssertEqual(snapshots, 1)
            }
        }
    }

    func testTabSelectionKeepsIslandsAndRemovesOnlyOppositeAnchorSide() throws {
        let dock = DockWorkspaceModel(layout: .init())
        let items = (0..<5).map { _ in DockItem.tab(UUID()) }
        dock.syncTabs(items.compactMap { if case .tab(let id) = $0 { id } else { nil } }, near: nil)
        let group = try XCTUnwrap(dock.group(containing: items[0]))
        dock.select(items[0])
        dock.select(items[2], extending: .toggle)
        dock.select(items[4], extending: .range)
        XCTAssertEqual(dock.selection(in: group.id), [items[0], items[2], items[3], items[4]])
        dock.select(items[3], extending: .range)
        XCTAssertEqual(dock.selection(in: group.id), [items[0], items[2], items[3], items[4]])
        dock.select(items[2], extending: .range)
        XCTAssertEqual(dock.selection(in: group.id), [items[0], items[2]])
        dock.select(items[4], extending: .range)
        dock.select(items[1], extending: .range)
        XCTAssertEqual(dock.selection(in: group.id), Array(items[0...2]))
        XCTAssertEqual(dock.activeGroup?.selected, items[1])
        dock.select(items[1], extending: .toggle, preferred: [items[2], items[0]])
        XCTAssertEqual(dock.activeGroup?.selected, items[2])
        XCTAssertEqual(dock.selection(in: group.id), [items[0], items[2]])
        dock.select(items[0], extending: .toggle)
        dock.select(items[2], extending: .toggle)
        XCTAssertEqual(dock.selection(in: group.id), [items[2]])
    }

    func testTabPointerDownPreservesDragSelectionAndOrdinaryReleaseCollapsesIt() throws {
        let dock = DockWorkspaceModel(layout: .init())
        let group = try XCTUnwrap(dock.group(containing: .files))
        dock.select(.files)
        dock.select(.git, extending: .toggle)
        var snapshots = 0
        dock.onSnapshotChange = { snapshots += 1 }
        dock.select(.git, extending: .preserve)
        XCTAssertEqual(dock.selection(in: group.id), [.files, .git])
        XCTAssertEqual(snapshots, 0)
        dock.selectForContextMenu(.files)
        XCTAssertEqual(dock.commandTargets(for: .files), [.files, .git])
        dock.select(.git)
        XCTAssertEqual(dock.selection(in: group.id), [.git])
        XCTAssertEqual(snapshots, 0, "Transient selection must not be persisted")
        dock.select(.files, extending: .toggle)
        dock.activate(try XCTUnwrap(dock.group(containing: .projects)).id)
        XCTAssertEqual(dock.selection(in: group.id), [.files])
        XCTAssertNil(dock.anchor(in: group.id))
    }

    func testSelectionPrunesRemovedMembersAndAnchorAndDoesNotCrossWindows() throws {
        let dock = DockWorkspaceModel(layout: .init())
        let ids = (0..<32).map { _ in UUID() }
        dock.syncTabs(ids, near: nil)
        dock.select(.tab(ids[0]))
        dock.select(.tab(ids[31]), extending: .range)
        let group = try XCTUnwrap(dock.activeGroup)
        XCTAssertEqual(dock.selection(in: group.id).count, 32)
        dock.syncTabs(Array(ids.dropFirst()), near: nil)
        XCTAssertNil(dock.anchor(in: group.id))
        XCTAssertEqual(dock.selection(in: group.id).count, 31)
        XCTAssertTrue(DockWorkspaceModel(layout: .init()).selection(in: group.id).isEmpty)
        dock.select(.tab(ids[1]), extending: .range)
        XCTAssertTrue(dock.selection(in: group.id).contains(try XCTUnwrap(dock.activeGroup?.selected)))
        dock.syncTabs([], near: nil)
        XCTAssertTrue(dock.selection(in: group.id).isEmpty)
    }

    func testGitChangesPreviewDisplaysDiffWithoutActivatingEditorGroup() throws {
        let project = Project(customDirectory: "/fixture/Git preview", layout: .init())
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
        let project = Project(customDirectory: directory.path, layout: .init())
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

    func testDockSwitchesRevealOnlyTheActiveFileInFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("a.swift")
        let second = directory.appendingPathComponent("b.swift")
        try "let a = 1\n".write(to: first, atomically: true, encoding: .utf8)
        try "let b = 2\n".write(to: second, atomically: true, encoding: .utf8)

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([directory])
        let project = try XCTUnwrap(manager.selectedProject)
        let files = try XCTUnwrap(project.dock.group(containing: .files))
        project.dock.activate(files.id)
        let synced = await project.syncFiles(isCurrent: { manager.selectedProject === project })
        XCTAssertNotNil(synced)

        project.openFile(first.path, activating: false)
        let firstID = try XCTUnwrap(project.selectedTabID)
        project.openFile(second.path, activating: false)
        let secondID = try XCTUnwrap(project.selectedTabID)
        XCTAssertEqual(project.dock.activeGroupID, files.id)
        project.selectTab(firstID)
        for _ in 0..<100 where project.fileTree.selectedPath != first.path {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(project.fileTree.selectedPaths, [first.path])
        XCTAssertEqual(project.fileTree.selectedPath, first.path)

        project.selectTab(secondID)
        for _ in 0..<100 where project.fileTree.selectedPath != second.path {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(project.fileTree.selectedPaths, [second.path])
        XCTAssertEqual(project.fileTree.selectedPath, second.path)
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(secondID))
    }

    func testShowingFilesAfterHiddenFileTabRevealsItsLastActiveDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.swift")
        let second = directory.appendingPathComponent("second.swift")
        try "first\n".write(to: first, atomically: true, encoding: .utf8)
        try "second\n".write(to: second, atomically: true, encoding: .utf8)
        let manager = WorkspaceWindowModel(application: workspaceApplication)
        workspaceApplication.register(manager)
        manager.dockLayout.root = .group(DockGroup(items: [.projects, .files, .git], selected: .files))
        let project = Project(customDirectory: directory.path, layout: manager.dockLayout)
        defer { manager.windowClosed() }
        manager.projects = [project]
        manager.selectedProjectID = project.id
        let synced = await project.syncFiles(isCurrent: { manager.selectedProject === project })
        XCTAssertNotNil(synced)
        project.openFile(first.path)
        project.openFile(second.path)
        let oldSelected = try XCTUnwrap(project.fileTree.items.first { $0.path == first.path })
        project.fileTree.select(oldSelected)
        XCTAssertEqual(project.fileTree.selectedPaths, [first.path])
        project.dock.select(.files)
        for _ in 0..<100 where project.fileTree.selectedPath != second.path {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(project.fileTree.selectedPaths, [second.path])
        XCTAssertEqual(project.fileTree.selectedPath, second.path)
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
    }

    func testBrowsingSameGroupMustNotKeepFocusOnHiddenFilesPanel() throws {
        let layout = DockWindowLayout()
        layout.root = .group(DockGroup(items: [.projects, .files, .git], selected: .files))
        let project = Project(customDirectory: "/fixture/same group", layout: layout)
        let path = "/tmp/preview-in-same-group.swift"
        project.dock.select(.files)
        project.openFile(path, activating: false)
        let tab = try XCTUnwrap(project.selectedTab)
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(tab.id))
        XCTAssertEqual(project.focusedContent?.id, tab.content.id,
                       "When Files is hidden, a visible document must receive focus")
    }

    func testOrdinarySelectionDoesNotCalculateRecentTabOrder() throws {
        let dock = DockWorkspaceModel(layout: .init())
        let ids = [UUID(), UUID(), UUID()]
        dock.syncTabs(ids, near: nil)
        let items = ids.map(DockItem.tab)
        var calls = 0
        func recency() -> [DockItem] {
            calls += 1
            return [items[1], items[0]]
        }
        dock.select(items[0], preferred: recency())
        dock.select(items[1], extending: .toggle, preferred: recency())
        dock.select(items[2], extending: .range, preferred: recency())
        dock.select(items[2], extending: .preserve, preferred: recency())
        XCTAssertEqual(calls, 0)
        dock.select(items[2], extending: .toggle, preferred: recency())
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(dock.activeGroup?.selected, items[1])
    }

    func testDefaultWindowGroupsAreNotStoredAsProjectOverrides() async throws {
        let layout = DockWindowLayout()
        let dock = DockWorkspaceModel(layout: layout)
        let invalidation = expectation(description: "Unchanged default groups do not invalidate content")
        invalidation.isInverted = true
        withObservationTracking({ _ = dock.root }) { invalidation.fulfill() }
        dock.syncTabs([], near: nil)
        await fulfillment(of: [invalidation], timeout: 0.1)
        XCTAssertTrue(dock.snapshot(tabIDs: []).isEmpty)

        let tools = try XCTUnwrap(layout.root.group(containing: .files))
        dock.select(.git)
        let overrides = dock.snapshot(tabIDs: [])
        XCTAssertEqual(overrides.map(\.id), [tools.id])
        XCTAssertEqual(overrides.first?.selected, .git)
        XCTAssertEqual(layout.root.group(id: tools.id)?.selected, .files)
        dock.select(.files)
        XCTAssertTrue(dock.snapshot(tabIDs: []).isEmpty)

        let id = UUID()
        dock.syncTabs([id], near: nil)
        let work = try XCTUnwrap(dock.group(containing: .tab(id)))
        XCTAssertEqual(dock.snapshot(tabIDs: [id]).map(\.id), [work.id])
        let restored = DockWorkspaceModel(layout: layout)
        restored.restore(dock.snapshot(tabIDs: [id]), tabIDs: [id])
        XCTAssertEqual(restored.root, dock.root)
        dock.syncTabs([], near: nil)
        XCTAssertTrue(dock.snapshot(tabIDs: []).isEmpty)
    }

    func testSyncTabsWithIdenticalLayoutDoesNotRequestSnapshot() throws {
        let project = Project(customDirectory: "/fixture/stable layout", layout: .init())
        let dock = project.dock
        var snapshots = 0
        project.onSnapshotChange = { snapshots += 1 }
        dock.syncTabs([], near: nil)
        dock.syncTabs([], near: nil)
        XCTAssertEqual(snapshots, 0, "An unchanged tab list must not publish a duplicate layout")
        let group = try XCTUnwrap(dock.group(containing: .files))
        dock.activate(group.id)
        dock.syncTabs([], near: nil)
        XCTAssertEqual(snapshots, 0, "Transient activity must not publish a layout")
    }

    func testFocusingAlreadyVisibleWorkTabsDoesNotRequestASnapshot() throws {
        let project = Project(customDirectory: "/fixture/transient focus", layout: .init())
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
        let project = Project(customDirectory: "/fixture/Panels", layout: .init())
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

    func testPanelAndProjectSelectionBeyondNineItems() throws {
        let project = Project(customDirectory: "/fixture/Many panels", layout: .init())
        for _ in 0..<12 {
            project.newBrowserTab(initialFocus: .none)
        }
        let ids = project.dock.tabOrder
        XCTAssertEqual(ids.count, 12)
        project.selectPanel(.tab(ids[11]))
        XCTAssertEqual(project.selectedTabID, ids[11])

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.projects = (0..<12).map {
            Project(customDirectory: "/fixture/Project \($0 + 1)", layout: manager.dockLayout)
        }
        XCTAssertEqual(manager.projects.count, 12)
        manager.selectProject(index: 11)
        XCTAssertEqual(manager.selectedProjectID, manager.projects[11].id)
    }

    func testAddPanelOnlyOffersMissingToolsAcrossAllGroups() throws {
        let dock = DockWorkspaceModel(layout: .init())
        let emptyGroup = try XCTUnwrap(dock.root.groups.first { $0.items.isEmpty })
        XCTAssertEqual(dock.layout.availableTools, [])

        XCTAssertTrue(dock.move(.files, into: emptyGroup.id))
        let otherGroup = try XCTUnwrap(dock.group(containing: .projects))
        XCTAssertEqual(dock.layout.availableTools, [],
                       "A tool moved into another group must not appear as addable")

        dock.removeTool(.files)
        XCTAssertEqual(dock.layout.availableTools, [.files])
        XCTAssertTrue(dock.place(.files, in: otherGroup.id))
        XCTAssertEqual(dock.layout.availableTools, [])

        dock.removeTool(.git)
        dock.removeTool(.projects)
        XCTAssertEqual(dock.layout.availableTools, [.projects, .git])
        XCTAssertEqual(DockWindowLayout().availableTools, [],
                       "Other windows retain their own available tool list")
    }

    func testToolsCanMoveIntoEmptyGroupsAtTheCenterAndEveryEdge() throws {
        for item in [DockItem.projects, .files, .git] {
            for edge in [nil, DockEdge.left, .right, .top, .bottom] {
                let dock = DockWorkspaceModel(layout: .init())
                let empty = try XCTUnwrap(dock.root.groups.first(where: { $0.items.isEmpty }))
                XCTAssertTrue(dock.move(item, into: empty.id, edge: edge), "\(item), \(String(describing: edge))")
                XCTAssertEqual(dock.activeGroup?.selected, item)
                if edge == nil { XCTAssertEqual(dock.activeGroupID, empty.id) }
                XCTAssertEqual(dock.root.groups.flatMap(\.items).filter { $0 == item }.count, 1)
            }
        }
    }

    func testSingleAndTwoGroupLayoutsAndEmptyToolOnlyProject() throws {
        for count in [1, 2] {
            let application = WorkspaceApplication()
            let manager = WorkspaceWindowModel(application: application)
            application.register(manager)
            manager.dockLayout.root = count == 1
                ? .group(DockGroup(items: [.projects, .files, .git]))
                : .split(DockSplit(axis: .horizontal, fraction: 0.5,
                    first: .group(DockGroup(items: [.projects])),
                    second: .group(DockGroup(items: [.files, .git]))))
            defer { manager.windowClosed() }
            let project = Project(customDirectory: "/fixture/empty", layout: manager.dockLayout)
            manager.projects = [project]
            manager.selectedProjectID = project.id
            XCTAssertEqual(project.dock.root.groups.count, count)
            for tool in [DockItem.files, .git, .projects] {
                manager.showPanel(tool)
                XCTAssertNil(project.focusedContent)
                manager.closeActivePanelOrWindow()
                XCTAssertNil(project.dock.group(containing: tool))
                XCTAssertTrue(manager.selectedProject === project)
                XCTAssertNotNil(project.dock.activeGroup)
            }
            XCTAssertTrue(project.tabs.isEmpty)
            XCTAssertNil(project.dock.activeGroup?.selected)
        }
    }

    func testClosingRecentWorkDoesNotOverrideAnActiveTool() throws {
        let project = Project(customDirectory: "/fixture/close focus", layout: .init())
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
        let dock = DockWorkspaceModel(layout: .init())
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
        let project = Project(customDirectory: "/fixture/focus", layout: .init())
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
        let dock = DockWorkspaceModel(layout: .init())
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
        XCTAssertEqual(dock.activeGroupID, oldActive)
        XCTAssertNil(dock.activeGroup?.selected)
        for tool in [DockItem.files, .git, .projects] {
            dock.select(tool)
            dock.removeTool(tool)
            XCTAssertNotNil(dock.activeGroup)
        }
        let other = DockWorkspaceModel(layout: .init())
        dock.layout.root = other.layout.root
        dock.restore(other.snapshot(tabIDs: []), tabIDs: [])
        XCTAssertNotNil(dock.activeGroup)
        XCTAssertTrue(dock.root.groups.contains { $0.id == dock.activeGroupID })
        dock.syncTabs([], near: nil)
        let empty = try XCTUnwrap(dock.root.groups.first(where: { $0.items.isEmpty }))
        dock.activate(empty.id)
        XCTAssertNil(dock.activeGroup?.selected)
    }

    func testProjectSwitchDoesNotChangeWindowLayoutOrOtherWindows() throws {
        let application = WorkspaceApplication()
        let first = application.makeWindow()
        let second = application.makeWindow()
        defer { first.windowClosed(); second.windowClosed() }
        let a = Project(customDirectory: "/fixture/A", layout: first.dockLayout)
        let b = Project(customDirectory: "/fixture/B", layout: first.dockLayout)
        let c = Project(customDirectory: "/fixture/C", layout: second.dockLayout)
        first.projects = [a, b]
        first.selectedProjectID = a.id
        second.projects = [c]
        second.selectedProjectID = c.id
        for project in [a, b, c] {
            project.newBrowserTab(initialFocus: .none)
            project.newBrowserTab(initialFocus: .none)
        }
        func layout(_ project: Project) -> DockNode {
            project.dock.root.mappingGroups { group in
                group.items.removeAll { $0.contentTabID != nil }
                group.selected = nil
            }
        }
        let independent = layout(c)
        XCTAssertEqual(layout(a), layout(b))
        guard case .split(let split) = a.dock.root else { return XCTFail("Expected split") }
        first.resizeDock(split.id, to: 0.32)
        let work = try XCTUnwrap(a.dock.group(containing: .tab(a.tabs[0].id)))
        XCTAssertTrue(a.movePanels(.tab(a.tabs[1].id), into: work.id, edge: .bottom))
        let lower = try XCTUnwrap(a.dock.group(containing: .tab(a.tabs[1].id)))
        XCTAssertTrue(a.dock.move(.git, into: work.id))
        let shared = layout(a)
        first.selectedProjectID = b.id
        XCTAssertEqual(layout(b), shared)
        XCTAssertEqual(layout(c), independent)
        XCTAssertEqual(Set(b.dock.tabOrder), Set(b.tabs.map(\.id)))
        guard b.dock.root.group(id: lower.id) != nil else { return XCTFail("Split must exist in every project in this window") }
        let retained = b.tabs[1]
        XCTAssertTrue(b.movePanels(.tab(retained.id), into: lower.id))
        b.selectTab(retained.id)
        first.selectedProjectID = a.id
        XCTAssertTrue(a.movePanels(.tab(a.tabs[1].id), into: work.id))
        let merged = layout(a)
        a.closeAll()
        XCTAssertTrue(a.tabs.isEmpty)
        XCTAssertEqual(layout(a), merged, "Closing content must not collapse the window layout")
        first.selectedProjectID = b.id
        XCTAssertEqual(layout(b), merged)
        XCTAssertEqual(Set(b.dock.tabOrder), Set(b.tabs.map(\.id)))
        XCTAssertTrue(b.tabs.contains { $0 === retained })
        XCTAssertNotNil(b.dock.group(containing: .tab(retained.id)))
        XCTAssertEqual(layout(c), independent)
        first.projects.append(Project(customDirectory: "/fixture/New", layout: first.dockLayout))
        let new = try XCTUnwrap(first.projects.last)
        XCTAssertEqual(layout(new), merged)
        XCTAssertTrue(new.dock.tabOrder.isEmpty)
    }

    func testOpeningAndClosingContentDirectlyInAGroupPreservesTheWindow() throws {
        let application = WorkspaceApplication()
        let window = application.makeWindow()
        defer { window.windowClosed() }
        let a = Project(customDirectory: "/fixture/A", layout: window.dockLayout)
        let b = Project(customDirectory: "/fixture/B", layout: window.dockLayout)
        window.projects = [a, b]
        window.selectedProjectID = a.id
        let target = try XCTUnwrap(a.dock.group(containing: .files))
        let before = window.dockLayout.root
        a.newSession(inGroup: target.id)
        XCTAssertEqual(a.dock.group(containing: .tab(try XCTUnwrap(a.selectedTabID)))?.id, target.id)
        XCTAssertEqual(window.dockLayout.root, before)
        window.selectedProjectID = b.id
        b.newBrowserTab(initialFocus: .none)
        let selected = b.dock.activeGroup?.selected
        a.closeAll()
        XCTAssertTrue(a.tabs.isEmpty)
        XCTAssertEqual(window.dockLayout.root, before)
        XCTAssertEqual(b.dock.activeGroup?.selected, selected)
        window.closePanel(.git, in: b)
        XCTAssertNil(a.dock.group(containing: .git))
        XCTAssertNil(b.dock.group(containing: .git))
        window.showPanel(.git)
        XCTAssertEqual(a.dock.group(containing: .git)?.id, b.dock.group(containing: .git)?.id)
    }

    func testClosePanelInEmptyDockGroupDoesNotCloseProject() throws {
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let project = Project(customDirectory: "/fixture/empty dock", layout: manager.dockLayout)
        manager.projects = [project]
        manager.selectedProjectID = project.id
        let empty = try XCTUnwrap(project.dock.root.groups.first { $0.items.isEmpty })
        project.dock.activate(empty.id)

        manager.closeActivePanelOrWindow()

        XCTAssertTrue(manager.selectedProject === project,
                      "An empty Dock group is not a request to delete its project")
        XCTAssertEqual(project.dock.activeGroupID, empty.id)
        XCTAssertNotNil(project.dock.group(containing: .files))
    }

    func testExplicitPanelCloseKeepsActiveTargetAndRejectsAnotherProject() throws {
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let project = Project(customDirectory: "/fixture/active", layout: manager.dockLayout)
        let other = Project(customDirectory: "/fixture/other", layout: manager.dockLayout)
        manager.projects = [project, other]
        manager.selectedProjectID = project.id
        manager.showPanel(.files)
        let activeGroupID = project.dock.activeGroupID

        manager.closePanel(.git, in: project)
        XCTAssertNil(project.dock.group(containing: .git))
        XCTAssertEqual(project.dock.activeGroupID, activeGroupID)
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
        XCTAssertNotNil(project.dock.group(containing: .files))

        manager.closePanel(.projects, in: other)
        XCTAssertNotNil(other.dock.group(containing: .projects),
                        "An outdated context menu cannot close another project's panel")

        manager.closeActivePanelOrWindow()
        XCTAssertNil(project.dock.group(containing: .files))
        XCTAssertNotNil(project.dock.group(containing: .projects))
        XCTAssertTrue(manager.selectedProject === project)
    }

    func testRightClickInactiveFileTabKeepsActiveSelectionUntilExplicitClose() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-close-target-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = (0..<3).map { directory.appendingPathComponent("file\($0).txt") }
        for file in files {
            try "original bytes\n".write(to: file, atomically: true, encoding: .utf8)
        }

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([directory])
        let project = try XCTUnwrap(manager.selectedProject)
        for file in files { project.openFile(file.path) }
        let tabs = project.tabs
        XCTAssertEqual(tabs.count, 3)
        let active = try XCTUnwrap(project.dock.activeGroupID)
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(tabs[2].id))

        project.dock.selectForContextMenu(.tab(tabs[1].id))
        XCTAssertEqual(project.dock.contextTarget, .tab(tabs[1].id))
        XCTAssertEqual(project.dock.activeGroupID, active)
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(tabs[2].id))

        manager.closePanel(.tab(tabs[1].id), in: project)
        XCTAssertEqual(project.tabs.map(\.id), [tabs[0].id, tabs[2].id])
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(tabs[2].id))
        XCTAssertNil(project.dock.contextTarget)

        project.dock.selectForContextMenu(.tab(tabs[2].id))
        project.selectTab(tabs[0].id)
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(tabs[0].id))
        manager.closeActivePanelOrWindow()
        XCTAssertEqual(project.tabs.map(\.id), [tabs[2].id])
        for file in files {
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original bytes\n")
        }
    }

    func testDirectTabCloseClearsMenuTargetWhenAnEarlierCloseIsStillPending() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-pending-close-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try "first bytes\n".write(to: first, atomically: true, encoding: .utf8)
        try "second bytes\n".write(to: second, atomically: true, encoding: .utf8)

        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([directory])
        let project = try XCTUnwrap(manager.selectedProject)
        project.openFile(first.path)
        project.openFile(second.path)
        let tabs = project.tabs
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(tabs[1].id))

        // A right-clicked inactive tab can already be awaiting a save or a
        // native Cancel decision. A repeated Close must not leave its menu
        // target armed for a later system Cmd-W.
        tabs[0].content.suspendAutoSaveForClose(true)
        defer { tabs[0].content.suspendAutoSaveForClose(false) }
        project.dock.selectForContextMenu(.tab(tabs[0].id))
        manager.closePanel(.tab(tabs[0].id), in: project)

        XCTAssertNil(project.dock.contextTarget)
        XCTAssertEqual(project.tabs.map(\.id), tabs.map(\.id))
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(tabs[1].id))

        manager.closeActivePanelOrWindow()
        XCTAssertEqual(project.tabs.map(\.id), [tabs[0].id],
                       "A later Cmd-W must close active B, never retry the blocked A")
        XCTAssertEqual(try Data(contentsOf: first), Data("first bytes\n".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second bytes\n".utf8))
    }

    func testLosingKeyWindowInvalidatesCurrentContextTarget() throws {
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let project = Project(customDirectory: "/fixture/first", layout: manager.dockLayout)
        manager.projects = [project]
        manager.selectedProjectID = project.id
        let active = project.dock.activeGroup?.selected
        project.dock.selectForContextMenu(.git)
        XCTAssertEqual(project.dock.contextTarget, .git)

        manager.windowResignedKey()

        XCTAssertNil(project.dock.contextTarget)
        XCTAssertEqual(project.dock.activeGroup?.selected, active)
    }

    func testMainMenuCloseIgnoresContextOnlyTarget() throws {
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let project = Project(customDirectory: "/fixture/main-menu", layout: manager.dockLayout)
        manager.projects = [project]
        manager.selectedProjectID = project.id
        manager.showPanel(.files)
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)

        project.dock.selectForContextMenu(.git)
        manager.closeActivePanelOrWindow()
        XCTAssertNil(project.dock.group(containing: .files),
                     "The system Panel command must close the selected panel, not a context-only target")
        XCTAssertNotNil(project.dock.group(containing: .git))
    }

    func testRightClickToolTargetIsIndependentOfActiveGroupAndProject() throws {
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let first = Project(customDirectory: "/fixture/one", layout: manager.dockLayout)
        let second = Project(customDirectory: "/fixture/two", layout: manager.dockLayout)
        manager.projects = [first, second]
        manager.selectedProjectID = first.id
        first.dock.select(.files)
        let active = first.dock.activeGroupID

        first.dock.selectForContextMenu(.git)
        XCTAssertEqual(first.dock.contextTarget, .git)
        XCTAssertEqual(first.dock.activeGroupID, active)
        XCTAssertEqual(first.dock.activeGroup?.selected, .files)
        manager.closePanel(.git, in: first)
        XCTAssertNil(first.dock.group(containing: .git))
        XCTAssertNotNil(first.dock.group(containing: .files))

        first.dock.selectForContextMenu(.projects)
        manager.selectedProjectID = second.id
        XCTAssertNil(first.dock.contextTarget)
        XCTAssertNil(second.dock.contextTarget)
        manager.selectedProjectID = first.id
        XCTAssertEqual(first.dock.activeGroup?.selected, .files)
    }

    func testToolsAreNotTheMostRecentWorkContentAndCloseTheirOwnPanel() throws {
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let project = Project(customDirectory: "/fixture/focus", layout: manager.dockLayout)
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
            manager.closeActivePanelOrWindow()
            XCTAssertNil(project.dock.group(containing: tool))
            XCTAssertEqual(project.tabs.count, 1)
            XCTAssertEqual(project.tabs.first?.content.id, browser.id)
        }
    }

    func testNestedLayoutObservationAndDragCancelPreserveUniqueOwners() async throws {
        let project = Project(customDirectory: "/fixture/dock observation", layout: .init())
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
        let bounds = CGRect(x: 100, y: 100, width: 1600, height: 800)
        let frame = try XCTUnwrap(DockLayout(dock.root, in: bounds).panes.first { $0.id == moved.id }).frame
        let positionChanged = expectation(description: "Only real drag preview changes are observed")
        withObservationTracking({ _ = dragging.position }) { positionChanged.fulfill() }
        dragging.setRootFrame(bounds)
        dragging.setTabFrame(CGRect(x: frame.minX, y: frame.minY, width: 120, height: 38), for: .tab(pane.id), in: moved.id, dock: dock)
        XCTAssertNil(dragging.position)
        dragging.begin(.files, dock: dock)
        dragging.update(.files, at: CGPoint(x: frame.minX + 1, y: frame.midY), dock: dock)
        XCTAssertEqual(dock.activeGroupID, activityBeforePreview)
        await fulfillment(of: [positionChanged], timeout: 1)
        XCTAssertEqual(dragging.position?.destination, moved.id)
        XCTAssertEqual(dragging.position?.edge, .left)
        dragging.cancel()
        XCTAssertEqual(dock.activeGroupID, activityBeforePreview)
        XCTAssertNil(dragging.position)
        XCTAssertTrue(dock.root.groups.contains { $0.items.contains(.files) })
        dragging.begin(.files, dock: dock)
        dragging.update(.files, at: CGPoint(x: frame.minX + 60, y: frame.minY + 18), dock: dock)
        XCTAssertEqual(dragging.position?.index, 1)
        XCTAssertEqual(dragging.insertionX(in: moved), frame.minX + 120)
        dragging.update(.files, at: CGPoint(x: frame.minX + 59, y: frame.minY + 18), dock: dock)
        XCTAssertEqual(dragging.position?.index, 0)
        XCTAssertEqual(dragging.insertionX(in: moved), frame.minX)
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

    func testDropInsertionUsesMountedTabRangeInsteadOfUnloadedTail() throws {
        let dock = DockWorkspaceModel(layout: .init())
        let ids = (0..<120).map { _ in UUID() }
        let items = ids.map(DockItem.tab)
        dock.syncTabs(ids, near: nil)
        let group = try XCTUnwrap(dock.group(containing: items[0]))
        let dragging = DockTabDragCoordinator()
        let bounds = CGRect(x: 100, y: 100, width: 1600, height: 600)
        let frame = try XCTUnwrap(DockLayout(dock.root, in: bounds).panes.first { $0.id == group.id }).frame
        dragging.setRootFrame(bounds)
        for index in 20...25 {
            dragging.setTabFrame(CGRect(x: frame.minX + 40 + CGFloat(index - 20) * 60, y: frame.minY, width: 60, height: 38),
                                 for: items[index], in: group.id, dock: dock)
        }
        dragging.begin(.files, dock: dock)
        for (x, index, insertion) in [(41, 20, 40), (150, 22, 160), (410, 26, 400)] {
            dragging.update(.files, at: CGPoint(x: frame.minX + CGFloat(x), y: frame.minY + 18), dock: dock)
            XCTAssertEqual(dragging.position?.index, index)
            XCTAssertEqual(dragging.insertionX(in: group), frame.minX + CGFloat(insertion))
        }
        // A scroll/selection update changes insertion geometry, not ownership.
        for index in 20...25 {
            dragging.setTabFrame(nil, for: items[index], in: group.id, dock: dock)
        }
        dragging.setTabFrame(CGRect(x: frame.minX + 40, y: frame.minY, width: 60, height: 38),
                             for: items[26], in: group.id, dock: dock)
        dock.select(items[26], activating: false)
        dragging.update(.files, at: CGPoint(x: frame.minX + 75, y: frame.minY + 18), dock: dock)
        XCTAssertEqual(dragging.position?.index, 27)
        XCTAssertEqual(dragging.position?.items, [.files])
        dragging.cancel()
    }

    func testDockLayoutPartitionsEveryNestedGroupAndKeepsIdentitiesOnResize() throws {
        let a = DockGroup(items: [.projects])
        let b = DockGroup(items: [.files])
        let c = DockGroup(items: [.git])
        let vertical = DockSplit(axis: .vertical, fraction: 0.25, first: .group(b), second: .group(c))
        let outer = DockSplit(axis: .horizontal, fraction: 0.4, first: .group(a), second: .split(vertical))
        let root = DockNode.split(outer)
        let bounds = CGRect(x: 13, y: 27, width: 1001, height: 801)
        let initial = DockLayout(root, in: bounds)
        XCTAssertEqual(initial.panes.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(initial.panes.map(\.frame), [
            CGRect(x: 13, y: 27, width: 400, height: 801),
            CGRect(x: 414, y: 27, width: 600, height: 200),
            CGRect(x: 414, y: 228, width: 600, height: 600)
        ])
        XCTAssertEqual(Set(initial.dividers.map(\.id)), [outer.id, vertical.id])
        let resized = DockLayout(root, in: bounds, resizing: (vertical.id, 0.75))
        XCTAssertEqual(resized.panes.map(\.id), initial.panes.map(\.id))
        XCTAssertEqual(resized.panes[0].frame, initial.panes[0].frame)
        XCTAssertEqual(resized.panes[1].frame.height, 600)
        XCTAssertEqual(resized.panes[2].frame.height, 200)
        XCTAssertEqual(resized.panes[2].frame.maxY, bounds.maxY)
        let collapsed = DockLayout(DockNode.split(DockSplit(id: outer.id, axis: .horizontal,
            fraction: outer.fraction, first: .group(a), second: .group(b))), in: bounds)
        XCTAssertEqual(collapsed.panes.map(\.id), [a.id, b.id])
        XCTAssertEqual(collapsed.panes[1].frame, CGRect(x: 414, y: 27, width: 600, height: 801))
    }

    func testDefaultLayoutAndDropHitTesting() throws {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 300)
        XCTAssertEqual(DockDropHitTest.edge(at: CGPoint(x: 12, y: 170), in: frame), .left)
        XCTAssertEqual(DockDropHitTest.edge(at: CGPoint(x: 308, y: 170), in: frame), .right)
        XCTAssertEqual(DockDropHitTest.edge(at: CGPoint(x: 160, y: 60), in: frame), .top)
        XCTAssertEqual(DockDropHitTest.edge(at: CGPoint(x: 160, y: 317), in: frame), .bottom)
        XCTAssertNil(DockDropHitTest.edge(at: CGPoint(x: 160, y: 170), in: frame))
        XCTAssertNil(DockDropHitTest.edge(at: CGPoint(x: 12, y: 25), in: frame))

        let dock = DockWorkspaceModel(layout: .init())
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
        XCTAssertEqual(outer.fraction, 0.24, accuracy: 0.0001)
        XCTAssertEqual(inner.fraction, 0.52 / 0.76, accuracy: 0.0001)
    }

    func testMoveReorderSnapshotAndRestore() throws {
        let dock = DockWorkspaceModel(layout: .init())
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
        let saved = try JSONDecoder().decode([DockSavedGroup].self, from: data)
        let restored = DockWorkspaceModel(layout: .init())
        restored.layout.root = dock.layout.root
        restored.restore(saved, tabIDs: [a, b, c])
        XCTAssertEqual(restored.tabOrder, [c, b, a])
        XCTAssertFalse(restored.move(.projects, into: UUID()))
    }

    func testNestedResizeKeepsContent() throws {
        let dock = DockWorkspaceModel(layout: .init())
        let first = try XCTUnwrap(dock.root.groups.first?.id)
        XCTAssertTrue(dock.move(.files, into: first, edge: .top))
        guard case .split(let outer) = dock.root,
              case .split(let inner) = outer.first else {
            return XCTFail("Expected nested split")
        }
        dock.layout.resize(outer.id, to: 0.25)
        dock.layout.resize(inner.id, to: 0.65)
        XCTAssertNotNil(dock.group(containing: .files))
    }
}
