import AppKit
import Foundation
import Observation
import XCTest
@testable import Bailey

@MainActor
final class SessionStoreTests: XCTestCase {
    func testIsolatedSnapshotsDoNotReadOrOverwritePreviousTestRuns() {
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
        let oldSuite = UserDefaults(suiteName: AppIdentity.bundleIdentifier + ".isolated-ui-test")
        let oldBytes = oldSuite?.data(forKey: "workspaceSnapshot")
        let activeSuite = BaileyInstanceMode.snapshotSuiteName
        XCTAssertNotEqual(activeSuite, AppIdentity.bundleIdentifier + ".isolated-ui-test")
        XCTAssertTrue(activeSuite.hasPrefix(AppIdentity.bundleIdentifier + ".isolated-ui-test."))

        let saved = SessionStore.load()
        defer { SessionStore.save(saved) }
        SessionStore.save([SessionSnapshot(projects: [], selectedProjectIndex: nil)])
        XCTAssertEqual(SessionStore.load().count, 1)
        XCTAssertEqual(oldSuite?.data(forKey: "workspaceSnapshot"), oldBytes,
                       "An isolated XCTest instance must never change previous test fixtures")
    }

    func testClosedWindowCannotBeUsedForLateFileOperationErrors() {
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
        let previouslySaved = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previouslySaved)
            TerminalHistoryStore.save(previousHistories)
        }

        let manager = TerminalManager()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        // AppKit normally releases programmatic NSWindow instances on close.
        // XCTest still owns this reference until the test method returns.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        manager.attach(to: window)
        XCTAssertTrue(manager.attachedWindow === window)
        manager.windowClosed()
        XCTAssertNil(manager.attachedWindow)
    }

    func testSnapshotRoundTripAndInvalidReferences() throws {
        typealias Project = SessionSnapshot.ProjectSnapshot
        let contents: [Project.ContentSnapshot] = [
            .session(workingDirectory: "/fixture"),
            .file(path: "/fixture/file", editorState: EditorState(selectionLocation: 4, scrollY: 22)),
            .browser(url: nil),
            .diff(repoRoot: "/fixture", path: "file", source: .staged, untracked: false, origPath: nil),
            .diff(repoRoot: "/fixture", path: "file", source: .commit(hash: "fixture", parent: nil, status: "A"), untracked: false, origPath: "old"),
        ]
        let tabs = contents.enumerated().map { index, content in
            Project.TabSnapshot(
                content: content,
                historyKey: index == 0 ? "history-fixture" : nil,
                customName: index == 0 ? "fixture" : nil,
                contextSessionIndex: index == 1 ? 0 : nil
            )
        }
        let dock = DockSavedNode.split(
            id: UUID(), axis: .horizontal, fraction: 0.3,
            first: .group(DockSavedGroup(id: UUID(), items: [.files], selected: .files)),
            second: .group(DockSavedGroup(id: UUID(), items: [.tab(0), .tab(999)], selected: .tab(999)))
        )
        let project = Project(
            customName: nil, customDirectory: "/fixture", sshHost: nil, pinnedFile: nil,
            tabs: tabs, selectedTabIndex: 0, dock: dock
        )
        let snapshot = AppSnapshot(windows: [
            SessionSnapshot(projects: [project], selectedProjectIndex: 0),
            SessionSnapshot(projects: [], selectedProjectIndex: nil),
        ])

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: data)
        XCTAssertEqual(try encoder.encode(decoded), data)

        let restored = dock.restore(tabIDs: [UUID()])
        XCTAssertEqual(restored.groups.flatMap(\.items).count, 2)
    }

    func testSavedHistoryKeysPairWithSidecarAndOrphansAreCleared() throws {
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
        let previousWindows = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previousWindows)
            TerminalHistoryStore.save(previousHistories)
        }

        let key = UUID().uuidString
        let output = "terminal fixture output"
        let project = SessionSnapshot.ProjectSnapshot(
            customName: "fixture", customDirectory: "/fixture",
            sshHost: nil, pinnedFile: nil,
            tabs: [.init(
                content: .session(workingDirectory: "/fixture"),
                historyKey: key, customName: nil, contextSessionIndex: nil
            )],
            selectedTabIndex: 0,
            dock: .group(.init(id: UUID(), items: [.projects, .tab(0)], selected: .tab(0)))
        )
        SessionStore.save([.init(projects: [project], selectedProjectIndex: 0)])
        TerminalHistoryStore.save([key: output])

        let storedKey = try XCTUnwrap(
            SessionStore.load().first?.projects.first?.tabs.first?.historyKey
        )
        XCTAssertEqual(TerminalHistoryStore.load()[storedKey], output)

        // A save with no referenced history has to remove the old sidecar.
        TerminalHistoryStore.save([:])
        XCTAssertTrue(TerminalHistoryStore.load().isEmpty)
    }

    func testSemanticAutosavePersistsRealWindowStateAndSkipsUIOnlyChanges() async throws {
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
        let previousWindows = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        SessionStore.save([])
        TerminalHistoryStore.save([:])
        defer {
            SessionStore.save(previousWindows)
            TerminalHistoryStore.save(previousHistories)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-autosave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldFile = directory.appendingPathComponent("before.txt")
        let newFile = directory.appendingPathComponent("after.txt")
        try Data("fixture\n".utf8).write(to: oldFile)
        let page = directory.appendingPathComponent("page.html")
        try Data("<title>Fixture</title>".utf8).write(to: page)

        let existingManagerCount = TerminalManager.activeManagers.count
        func savedProject(_ windows: [SessionSnapshot]) -> SessionSnapshot.ProjectSnapshot? {
            windows.flatMap(\.projects).first {
                $0.customDirectory == directory.path && $0.customName == "Edited Project"
            }
        }
        let first = TerminalManager()
        var firstClosed = false
        defer { if !firstClosed { first.windowClosed() } }

        let projectAdded = expectation(description: "Window manager directly observes project insertion")
        withObservationTracking({ _ = first.projects.map(\.id) }) { projectAdded.fulfill() }
        first.addLocalItems([directory])
        await fulfillment(of: [projectAdded], timeout: 1)
        let project = try XCTUnwrap(first.selectedProject)
        project.customName = "Edited Project"
        guard case .split(let split) = project.dock.root else {
            return XCTFail("Expected the configured split layout")
        }
        project.dock.resize(split.id, to: 0.31)

        // Mutations should be coalesced for 500 ms, not saved synchronously.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(savedProject(SessionStore.load()))
        try await waitForSnapshot { savedProject($0) != nil }
        let firstSaved = try XCTUnwrap(savedProject(SessionStore.load()))
        XCTAssertEqual(firstSaved.customDirectory, directory.path)
        XCTAssertEqual(firstSaved.selectedTabIndex, nil)
        if case .split(_, _, let fraction, _, _) = firstSaved.dock {
            XCTAssertEqual(fraction, 0.31, accuracy: 0.001)
        } else {
            XCTFail("Layout was not serialized")
        }

        // Neither the performance badge nor another UI-only publication
        // should write a new window snapshot.
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: BaileyInstanceMode.snapshotSuiteName
        ))
        let originalData = try XCTUnwrap(defaults.data(forKey: "workspaceSnapshot"))
        first.toggleFPSCounter()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(defaults.data(forKey: "workspaceSnapshot"), originalData)

        let tabAdded = expectation(description: "Nested project tab change is observed without manager relays")
        withObservationTracking({ _ = first.selectedProject?.tabs.map(\.id) }) { tabAdded.fulfill() }
        project.openFile(oldFile.path)
        await fulfillment(of: [tabAdded], timeout: 1)
        let fileTab = try XCTUnwrap(project.selectedTab)
        fileTab.customName = "Renamed File Tab"
        try FileManager.default.moveItem(at: oldFile, to: newFile)
        first.fileRenamed(from: oldFile.path, to: newFile.path, workspace: nil)
        try await waitForSnapshot { snapshots in
            guard let tabs = savedProject(snapshots)?.tabs else { return false }
            return tabs.contains {
                if case .file(let path, _) = $0.content {
                    return path == newFile.path && $0.customName == "Renamed File Tab"
                }
                return false
            }
        }

        // Editing bytes and the dirty indicator are not persisted. Only the
        // existing file path and editor location belong to the snapshot.
        let savedFileSnapshot = try XCTUnwrap(defaults.data(forKey: "workspaceSnapshot"))
        guard case .file(let file) = fileTab.content else {
            return XCTFail("Expected a file tab")
        }
        try await file.waitForText()
        file.text = "unsaved fixture edit"
        file.refreshDirtyState()
        XCTAssertTrue(file.isDirty)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(defaults.data(forKey: "workspaceSnapshot"), savedFileSnapshot)
        file.text = "fixture\n"
        file.refreshDirtyState()

        let session = project.newSession(directory: directory.path)
        try await waitForSnapshot { snapshots in
            savedProject(snapshots)?.tabs.contains {
                if case .session(let path) = $0.content { return path == directory.path }
                return false
            } == true
        }
        let movedDirectory = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: movedDirectory, withIntermediateDirectories: true)
        session.terminalDidChangeWorkingDirectory(movedDirectory.path)
        try await waitForSnapshot { snapshots in
            savedProject(snapshots)?.tabs.contains {
                if case .session(let path) = $0.content { return path == movedDirectory.path }
                return false
            } == true
        }

        let browser = project.newBrowserTab(initialURL: page.absoluteString)
        try await waitForSnapshot { snapshots in
            guard let tabs = savedProject(snapshots)?.tabs else { return false }
            return tabs.contains {
                if case .browser(let url) = $0.content {
                    return url == browser.snapshotURL && url == page.absoluteString
                }
                return false
            }
        }

        project.openDiff(
            repoRoot: directory.path, path: "after.txt",
            staged: false, untracked: false, origPath: nil
        )
        // An already selected diff can change its persisted rename metadata
        // without the selectedTabID (or the Dock layout) changing.
        project.openDiff(
            repoRoot: directory.path, path: "after.txt",
            staged: false, untracked: true, origPath: "before.txt"
        )
        try await waitForSnapshot { snapshots in
            savedProject(snapshots)?.tabs.contains {
                if case .diff(let root, let path, _, let untracked, let origPath) = $0.content {
                    return root == directory.path && path == "after.txt"
                        && untracked && origPath == "before.txt"
                }
                return false
            } == true
        }

        let second = TerminalManager()
        var secondClosed = false
        defer { if !secondClosed { second.windowClosed() } }
        second.addLocalItems([directory])
        try await waitForSnapshot { $0.count == existingManagerCount + 2 }
        first.windowClosed()
        firstClosed = true
        XCTAssertEqual(SessionStore.load().count, existingManagerCount + 1)
        XCTAssertTrue(SessionStore.load().contains { window in
            window.projects.contains { $0.customDirectory == directory.path }
        })

        second.windowClosed()
        secondClosed = true
        XCTAssertEqual(SessionStore.load().count, max(1, existingManagerCount))
        if existingManagerCount == 0 {
            // The last window retains its snapshot for re-opening.
            XCTAssertEqual(SessionStore.load().first?.projects.first?.customDirectory, directory.path)
            let restored = TerminalManager()
            for project in restored.projects { restored.close(project) }
            restored.windowClosed()
        } else {
            // The XCTest app's own window is still active; it must not be closed.
            XCTAssertFalse(SessionStore.load().contains { window in
                window.projects.contains { $0.customDirectory == directory.path }
            })
        }
    }

    private func waitForSnapshot(
        _ predicate: ([SessionSnapshot]) -> Bool
    ) async throws {
        for _ in 0..<80 {
            if predicate(SessionStore.load()) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Persisted snapshot never reflected the semantic change")
    }

    func testObsoleteInfoItemIsFilteredWithoutDiscardingLayout() throws {
        typealias Project = SessionSnapshot.ProjectSnapshot
        let tabID = UUID()
        let groupID = UUID()
        let legacy = DockSavedNode.group(DockSavedGroup(
            id: groupID,
            items: [.info, .files, .tab(0), .git],
            selected: .info
        ))
        let migrated = legacy.restore(tabIDs: [tabID])
        XCTAssertEqual(migrated.groups.first?.id, groupID)
        XCTAssertEqual(migrated.groups.first?.items, [.files, .tab(tabID), .git])
        XCTAssertEqual(migrated.groups.first?.selected, .files)

        let encoded = try JSONEncoder().encode(DockSavedNode(migrated, tabIDs: [tabID]))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("info"))

        guard BaileyInstanceMode.isIsolated else { return XCTFail("Snapshot verification requires isolated storage") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: BaileyInstanceMode.snapshotSuiteName))
        let previous = defaults.data(forKey: "workspaceSnapshot")
        defer {
            if let previous { defaults.set(previous, forKey: "workspaceSnapshot") }
            else { defaults.removeObject(forKey: "workspaceSnapshot") }
        }
        let firstTab = Project.TabSnapshot(content: .file(path: "/fixture/first", editorState: nil), customName: "First")
        let secondTab = Project.TabSnapshot(content: .browser(url: "https://example.invalid"), customName: "Second")
        let secondGroupID = UUID()
        let oldProject = Project(
            customName: "Legacy", tabs: [firstTab], selectedTabIndex: 0, dock: legacy
        )
        let currentProject = Project(
            customName: "Current", tabs: [secondTab], selectedTabIndex: 0,
            dock: .group(DockSavedGroup(id: secondGroupID, items: [.projects, .tab(0)], selected: .tab(0)))
        )
        let app = AppSnapshot(windows: [
            SessionSnapshot(projects: [oldProject], selectedProjectIndex: 0),
            SessionSnapshot(projects: [currentProject], selectedProjectIndex: 0),
        ])
        defaults.set(try JSONEncoder().encode(app), forKey: "workspaceSnapshot")
        let windows = SessionStore.load()
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.selectedProjectIndex), [0, 0])
        let loadedOld = try XCTUnwrap(windows.first?.projects.first)
        let loadedCurrent = try XCTUnwrap(windows.last?.projects.first)
        XCTAssertEqual(loadedOld.customName, "Legacy")
        XCTAssertEqual(loadedCurrent.customName, "Current")
        XCTAssertEqual(loadedOld.tabs.first?.customName, "First")
        XCTAssertEqual(loadedCurrent.tabs.first?.customName, "Second")
        guard case .file(let restoredPath, _) = loadedOld.tabs.first?.content,
              case .browser(let restoredURL) = loadedCurrent.tabs.first?.content else {
            return XCTFail("Both windows must retain their original content types")
        }
        XCTAssertEqual(restoredPath, "/fixture/first")
        XCTAssertEqual(restoredURL, "https://example.invalid")
        XCTAssertEqual(loadedOld.selectedTabIndex, 0)
        XCTAssertEqual(loadedCurrent.selectedTabIndex, 0)
        let restoredLegacy = DockWorkspaceModel()
        restoredLegacy.restore(loadedOld.dock, tabIDs: [tabID])
        XCTAssertEqual(restoredLegacy.root.groups.first?.id, groupID)
        XCTAssertEqual(restoredLegacy.root.groups.first?.items, [.files, .tab(tabID), .git])
        XCTAssertEqual(restoredLegacy.root.groups.first?.selected, .files)
        let currentTabID = UUID()
        let restoredCurrent = loadedCurrent.dock.restore(tabIDs: [currentTabID])
        XCTAssertEqual(restoredCurrent.groups.first?.id, secondGroupID)
        XCTAssertEqual(restoredCurrent.groups.first?.selected, .tab(currentTabID))
        let currentData = try JSONEncoder().encode(restoredLegacy.snapshot(tabIDs: [tabID]))
        XCTAssertFalse(String(decoding: currentData, as: UTF8.self).contains("info"))

        for invalid in ["{}", "{\"columns\":[]}", "{\"session\":{\"workingDirectory\":\"/fixture\"}}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Project.TabSnapshot.self, from: Data(invalid.utf8)))
        }
    }
}
