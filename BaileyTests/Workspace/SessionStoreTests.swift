import Foundation
import Observation
import XCTest
@testable import Bailey

@MainActor
final class SessionStoreTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    func testSavingDuringPartialRestorePreservesUnclaimedWindowsAndHistory() async throws {
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
        let previousWindows = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previousWindows)
            TerminalHistoryStore.save(previousHistories)
        }
        for count in [1, 2, 3] {
            for action in ["relaunch", "terminate", "close", "debounce"] {
                let snapshots = (0..<count).map { index in
                    SessionSnapshot(projects: [.init(
                        customDirectory: "/fixture/\(index)",
                        sshHost: nil, pinnedFile: nil,
                        tabs: index == 0 ? [] : [.init(
                            content: .session(workingDirectory: "/fixture/\(index)"),
                            historyKey: "history-\(index)", customName: nil, contextSessionIndex: nil
                        )], selectedTabIndex: nil,
                        dock: .group(.init(id: UUID(), items: [.files], selected: .files))
                    )], selectedProjectIndex: 0)
                }
                let histories = Dictionary(uniqueKeysWithValues: (1..<count).map {
                    ("history-\($0)", "output-\($0)")
                })
                SessionStore.save(snapshots)
                TerminalHistoryStore.save(histories)
                let application = WorkspaceApplication(loadSavedState: true)
                let window = application.makeWindow()
                window.selectedProject?.customDirectory = "/fixture/updated"
                switch action {
                case "relaunch": application.saveForRelaunch()
                case "terminate": application.willTerminate()
                case "close": window.windowClosed()
                default:
                    let deadline = Date().addingTimeInterval(5)
                    while SessionStore.load().first?.projects.first?.customDirectory != "/fixture/updated",
                          Date() < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                let saved = SessionStore.load()
                XCTAssertEqual(saved.count, count, "\(action), \(count) windows")
                XCTAssertEqual(saved.first?.projects.first?.customDirectory, "/fixture/updated", action)
                XCTAssertEqual(saved.dropFirst().compactMap { $0.projects.first?.customDirectory },
                               (1..<count).map { "/fixture/\($0)" }, action)
                XCTAssertEqual(TerminalHistoryStore.load(), histories, action)
                window.windowClosed()
                window.windowClosed()
                application.willTerminate()
                XCTAssertEqual(SessionStore.load().count, count, "Repeated close/quit: \(action)")
                XCTAssertEqual(TerminalHistoryStore.load(), histories, action)
            }
        }
    }

    func testRestoreSkipsObsoleteProjectsWithoutChangingValidSelection() {
        func saved(_ directory: String?, sshHost: String? = nil,
                   file: String? = nil) -> SessionSnapshot.ProjectSnapshot {
            .init(
                customDirectory: directory, sshHost: sshHost, pinnedFile: file,
                tabs: [], selectedTabIndex: nil,
                dock: .group(.init(id: UUID(), items: [.projects, .files], selected: .files))
            )
        }

        let snapshot = SessionSnapshot(projects: [
            saved(nil),
            saved("/tmp/fixed-one"),
            saved("/tmp/old-local", file: "/tmp/old-local/legacy.txt"),
            saved("/d/remote", sshHost: "fixture-ssh", file: "/d/remote/source.swift"),
            saved("/tmp/fixed-two"),
        ], selectedProjectIndex: 4)
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        XCTAssertTrue(manager.restore(from: snapshot, histories: [:]))
        XCTAssertEqual(manager.projects.compactMap(\.customDirectory),
                       ["/tmp/fixed-one", "/d/remote", "/tmp/fixed-two"])
        XCTAssertEqual(manager.selectedProject?.name, "fixed-two",
                       "Removing obsolete snapshots cannot shift selection to a different project")
        XCTAssertEqual(manager.projects[1].name, "source.swift")
        XCTAssertTrue(manager.projects[1].tabs.contains { $0.content.isFile },
                      "The current SSH single-file project must remain restorable")
        XCTAssertFalse(manager.projects.contains { $0.pinnedFile != nil && $0.sshHost == nil })
    }

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

    func testClosedOwnerCannotReRegisterOrReceiveNewWindowIdentity() {
        let savedWindows = SessionStore.load()
        let savedHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(savedWindows)
            TerminalHistoryStore.save(savedHistories)
        }
        let application = WorkspaceApplication()
        let closed = application.makeWindow()
        XCTAssertTrue(application.containsWindow(closed))
        closed.windowClosed()
        XCTAssertTrue(closed.isClosed)
        XCTAssertNil(closed.attachedWindow)
        XCTAssertFalse(application.containsWindow(closed))

        // A delayed SwiftUI or native attachment must not resurrect a dead owner.
        application.register(closed)
        XCTAssertFalse(application.containsWindow(closed))
        XCTAssertEqual(application.windowCount, 0)

        let newOwner = application.makeWindow()
        defer { newOwner.windowClosed() }
        XCTAssertTrue(application.containsWindow(newOwner))
        XCTAssertFalse(application.containsWindow(closed))
        XCTAssertEqual(application.windowCount, 1)
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
            customDirectory: "/fixture", sshHost: nil, pinnedFile: nil,
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

    func testMacFileInSSHProjectRestoresFromMacAndLegacyRemoteTabKeepsItsMachine() async throws {
        typealias Snapshot = SessionSnapshot.ProjectSnapshot
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("same.swift")
        try "Mac bytes".write(to: path, atomically: true, encoding: .utf8)

        let mac = Snapshot.TabSnapshot(
            content: .file(path: path.path, editorState: EditorState(selectionLocation: 3)),
            historyKey: nil, customName: "Mac", contextSessionIndex: nil,
            localFile: true
        )
        let json = try JSONEncoder().encode(mac)
        let decoded = try JSONDecoder().decode(Snapshot.TabSnapshot.self, from: json)
        XCTAssertEqual(decoded.localFile, true)

        let project = Project(fallbackName: "SSH", workspaceConfiguration: .standard)
        project.sshHost = "invalid-p4-snapshot"
        let tab = project.restoreTab(from: decoded)
        guard case .file(let restoredMac) = tab.content else {
            return XCTFail("Restored file must be a native FileTab")
        }
        XCTAssertNil(restoredMac.workspaceIdentity)
        try await restoredMac.waitForText()
        XCTAssertEqual(restoredMac.text, "Mac bytes")
        XCTAssertEqual(restoredMac.editorState.selectionLocation, 3)

        // A snapshot from before P4 has no localFile key. Preserve SSH identity.
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        legacyObject.removeValue(forKey: "localFile")
        let legacy = try JSONDecoder().decode(
            Snapshot.TabSnapshot.self, from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertNil(legacy.localFile)
        let remoteTab = project.restoreTab(from: legacy)
        guard case .file(let remote) = remoteTab.content else {
            return XCTFail("Legacy remote file tab must be restored")
        }
        XCTAssertEqual(remote.workspaceIdentity, "ssh:invalid-p4-snapshot")
        XCTAssertTrue(remote !== restoredMac)
    }

    func testRealWindowSnapshotPersistsMacFileInsideSSHProject() async throws {
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
        let previous = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previous)
            TerminalHistoryStore.save(previousHistories)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("open-in-ssh.swift")
        try "disk bytes".write(to: file, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let ssh = Project(fallbackName: "SSH", workspaceConfiguration: .standard)
        ssh.sshHost = "invalid-p4-autosave"
        ssh.customDirectory = "/remote/project"
        manager.projects.append(ssh)
        manager.selectedProjectID = ssh.id
        XCTAssertTrue(manager.openExternalLocalItems([file]).isEmpty)
        try await waitForSnapshot { windows in
            windows.flatMap(\.projects).contains { project in
                project.sshHost == "invalid-p4-autosave" && project.tabs.contains { tab in
                    guard case .file(let path, _) = tab.content else { return false }
                    return path == file.path && tab.localFile == true
                }
            }
        }
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(manager.selectedProjectID, ssh.id)
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
            customDirectory: "/fixture",
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

        let existingManagerCount = self.workspaceApplication.windowCount
        func savedProject(_ windows: [SessionSnapshot]) -> SessionSnapshot.ProjectSnapshot? {
            windows.flatMap(\.projects).first {
                $0.customDirectory == directory.path
            }
        }
        let first = self.workspaceApplication.makeWindow()
        var firstClosed = false
        defer { if !firstClosed { first.windowClosed() } }

        let projectAdded = expectation(description: "Window manager directly observes project insertion")
        withObservationTracking({ _ = first.projects.map(\.id) }) { projectAdded.fulfill() }
        first.addLocalFolders([directory])
        await fulfillment(of: [projectAdded], timeout: 1)
        let project = try XCTUnwrap(first.selectedProject)
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

        // Opening and dismissing the temporary command input must not write a workspace snapshot.
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: BaileyInstanceMode.snapshotSuiteName
        ))
        let originalData = try XCTUnwrap(defaults.data(forKey: "workspaceSnapshot"))
        first.toggleCommandPalette()
        first.dismissCommandPalette()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(defaults.data(forKey: "workspaceSnapshot"), originalData)

        let tabAdded = expectation(description: "Nested project tab change is observed without manager relays")
        withObservationTracking({ _ = first.selectedProject?.tabs.map(\.id) }) { tabAdded.fulfill() }
        project.openFile(oldFile.path)
        await fulfillment(of: [tabAdded], timeout: 1)
        let fileTab = try XCTUnwrap(project.selectedTab)
        fileTab.customName = "Renamed File Tab"
        try FileManager.default.moveItem(at: oldFile, to: newFile)
        workspaceApplication.fileRenamed(from: oldFile.path, to: newFile.path, workspace: nil)
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

        let second = self.workspaceApplication.makeWindow()
        var secondClosed = false
        defer { if !secondClosed { second.windowClosed() } }
        second.addLocalFolders([directory])
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
            let restored = self.workspaceApplication.makeWindow()
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
            customDirectory: "/fixture/legacy", sshHost: nil, pinnedFile: nil,
            tabs: [firstTab], selectedTabIndex: 0, dock: legacy
        )
        let currentProject = Project(
            customDirectory: "/fixture/current", sshHost: nil, pinnedFile: nil,
            tabs: [secondTab], selectedTabIndex: 0,
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
        XCTAssertEqual(loadedOld.customDirectory, "/fixture/legacy")
        XCTAssertEqual(loadedCurrent.customDirectory, "/fixture/current")
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
