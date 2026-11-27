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
                            historyKey: "history-\(index)", contextSessionIndex: nil
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

    func testWindowLayoutRestoresOnceAndPreservesEveryProjectTab() throws {
        let application = WorkspaceApplication()
        let window = application.makeWindow()
        defer { window.windowClosed() }
        func legacy(_ name: String, fraction: Double) -> SessionSnapshot.ProjectSnapshot {
            let left = DockSavedGroup(id: UUID(), items: [.projects], selected: .projects)
            let right = DockSavedGroup(id: UUID(), items: [.files, .tab(0)], selected: .tab(0))
            return .init(customDirectory: "/fixture/" + name, tabs: [
                .init(content: .browser(url: "about:blank"))
            ], selectedTabIndex: 0, dock: .split(id: UUID(), axis: .horizontal, fraction: fraction,
                first: .group(left), second: .group(right)))
        }
        let old = SessionSnapshot(projects: [legacy("A", fraction: 0.3), legacy("B", fraction: 0.6)],
                                  selectedProjectIndex: 1)
        XCTAssertTrue(window.restore(from: old, histories: [:]))
        let expected = try XCTUnwrap(old.projects[1].dock).restoreLayout()
        XCTAssertEqual(window.dockLayout.root, expected)
        for project in window.projects {
            XCTAssertEqual(project.tabs.count, 1)
            XCTAssertEqual(project.dock.tabOrder, project.tabs.map(\.id))
            XCTAssertEqual(project.dock.root.groups.map(\.id), expected.groups.map(\.id))
        }
        let saved = window.makeWindowSnapshot(captureTerminalHistory: false).snapshot
        XCTAssertNotNil(saved.layout)
        XCTAssertTrue(saved.projects.allSatisfy { $0.dock == nil && $0.groups != nil })
        let bytes = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: bytes)
        let otherApplication = WorkspaceApplication()
        let restored = otherApplication.makeWindow()
        defer { restored.windowClosed() }
        XCTAssertTrue(restored.restore(from: decoded, histories: [:]))
        XCTAssertEqual(restored.dockLayout.root, expected)
        XCTAssertEqual(restored.selectedProject?.name, "B")
        for project in restored.projects {
            XCTAssertEqual(project.tabs.count, 1)
            XCTAssertEqual(project.dock.tabOrder, project.tabs.map(\.id))
            XCTAssertEqual(project.dock.root.groups.map(\.id), expected.groups.map(\.id))
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

    func testWindowCloseReleasesTabsOfRetainedProjectsAfterSavingSnapshot() async throws {
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
        let savedWindows = SessionStore.load()
        let savedHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(savedWindows)
            TerminalHistoryStore.save(savedHistories)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("retained.txt")
        try Data("saved text".utf8).write(to: url)
        let application = WorkspaceApplication()
        let manager = application.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        project.openFile(url.path)
        weak var owner: FileTab?
        do {
            guard case .file(let file) = try XCTUnwrap(project.selectedTab).content else {
                return XCTFail("Expected a file")
            }
            try await file.waitForText()
            owner = file
        }

        // Retain the project as a dismissed native host can do. Closing the
        // final window must save its reopen snapshot before retiring content.
        manager.windowClosed()
        XCTAssertTrue(manager.projects.isEmpty)
        XCTAssertTrue(project.tabs.isEmpty)
        XCTAssertNil(project.selectedTabID)
        let restored = try XCTUnwrap(SessionStore.load().first?.projects.first)
        XCTAssertEqual(restored.tabs.count, 1)
        if case .file(let path, _) = restored.tabs.first?.content {
            XCTAssertEqual(path, url.path)
        } else {
            XCTFail("Expected the saved file in the reopen snapshot")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved text")
        XCTAssertNil(owner)
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

    func testTwoWindowRestoreKeepsPreviewFilesLazyAndReusesTheirOwnTabs() async throws {
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
        let savedWindows = SessionStore.load()
        let savedHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(savedWindows)
            TerminalHistoryStore.save(savedHistories)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let samples: [(String, String, FilePreviewMode)] = [
            ("plot.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\"/></svg>", .preview),
            ("values.csv", "name,value\na,2\n", .preview),
            ("page.html", "<!doctype html><title>Fixture</title><p>HTML</p>", .source),
            ("notes.md", "# Fixture\n\nMarkdown\n", .source),
        ]
        let application = WorkspaceApplication()
        var directories: [URL] = []
        var originalIDs = Set<UUID>()
        var originals: [URL: Data] = [:]
        var oldWindows: [WorkspaceWindowModel] = []
        defer { oldWindows.forEach { $0.windowClosed() } }
        for windowIndex in 0..<2 {
            let directory = root.appendingPathComponent("window-\(windowIndex)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            directories.append(directory)
            let manager = application.makeWindow()
            oldWindows.append(manager)
            manager.addLocalFolders([directory])
            let project = try XCTUnwrap(manager.selectedProject)
            for (name, source, _) in samples {
                let url = directory.appendingPathComponent(name)
                let bytes = Data((source + "\n").utf8)
                try bytes.write(to: url)
                originals[url] = bytes
                project.openFile(url.path)
                let tab = try XCTUnwrap(project.selectedTab)
                originalIDs.insert(tab.id)
                guard case .file(let file) = tab.content else { return XCTFail("Expected file") }
                try await file.waitForText()
                project.setFilePreviewMode(.sideBySide, for: tab)
                XCTAssertEqual(project.filePreviewMode(for: tab), .sideBySide)
            }
            XCTAssertEqual(project.tabs.count, samples.count)
        }
        application.saveForRelaunch()
        let snapshots = SessionStore.load()
        XCTAssertEqual(snapshots.count, 2)
        oldWindows.forEach { $0.windowClosed() }
        oldWindows.removeAll()
        // Closing the first live window updates the store; restore the exact
        // two-window snapshot captured by the relaunch action above.
        SessionStore.save(snapshots)
        let restoredApplication = WorkspaceApplication(loadSavedState: true)
        var restoredWindows: [WorkspaceWindowModel] = []
        defer { restoredWindows.forEach { $0.windowClosed() } }
        for directory in directories {
            let manager = restoredApplication.makeWindow()
            restoredWindows.append(manager)
            let project = try XCTUnwrap(manager.selectedProject)
            XCTAssertEqual(project.customDirectory, directory.path)
            XCTAssertEqual(project.tabs.count, samples.count)
            for (name, _, expectedMode) in samples {
                let path = directory.appendingPathComponent(name)
                let tab = try XCTUnwrap(project.tabs.first { tab in
                    if case .file(let file) = tab.content { return file.path == path.path }
                    return false
                })
                guard case .file(let file) = tab.content else { return XCTFail("Expected restored file") }
                XCTAssertFalse(originalIDs.contains(tab.id))
                guard case .loading = file.content else { return XCTFail("Restore must keep file IO lazy") }
                XCTAssertNil(project.dock.group(containing: .filePreview(tab.id)))
                XCTAssertEqual(project.filePreviewMode(for: tab), expectedMode)
                project.openFile(path.path)
                XCTAssertTrue(project.selectedTab === tab)
                XCTAssertEqual(project.tabs.count, samples.count)
                try await file.waitForText()
                XCTAssertEqual(project.filePreviewMode(for: tab), expectedMode)
                XCTAssertEqual(try Data(contentsOf: path), originals[path])
                XCTAssertFalse(file.isDirty)
            }
        }
        XCTAssertEqual(restoredApplication.windowCount, 2)
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
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("customName"),
                       "A tab's title is derived from content and never persisted separately")
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: data)
        XCTAssertEqual(try encoder.encode(decoded), data)

        let ids = [UUID()]
        XCTAssertEqual(dock.groups.flatMap { $0.restore(tabIDs: ids).items }.count, 2)
        XCTAssertEqual(dock.restoreLayout().groups.flatMap(\.items), [.files])
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
            historyKey: nil, contextSessionIndex: nil,
            localFile: true
        )
        let json = try JSONEncoder().encode(mac)
        let decoded = try JSONDecoder().decode(Snapshot.TabSnapshot.self, from: json)
        XCTAssertEqual(decoded.localFile, true)

        let project = Project(fallbackName: "SSH", layout: .init())
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
        let ssh = Project(fallbackName: "SSH", layout: manager.dockLayout)
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
                historyKey: key, contextSessionIndex: nil
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
        first.resizeDock(split.id, to: 0.31)

        // Mutations should be coalesced for 500 ms, not saved synchronously.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(savedProject(SessionStore.load()))
        try await waitForSnapshot { savedProject($0) != nil }
        let firstSaved = try XCTUnwrap(savedProject(SessionStore.load()))
        XCTAssertEqual(firstSaved.customDirectory, directory.path)
        XCTAssertEqual(firstSaved.selectedTabIndex, nil)
        if case .split(_, _, let fraction, _, _)? = SessionStore.load().first(where: {
            $0.projects.contains { $0.customDirectory == directory.path }
        })?.layout {
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
        try FileManager.default.moveItem(at: oldFile, to: newFile)
        workspaceApplication.fileRenamed(from: oldFile.path, to: newFile.path, workspace: nil)
        try await waitForSnapshot { snapshots in
            guard let tabs = savedProject(snapshots)?.tabs else { return false }
            return tabs.contains {
                if case .file(let path, _) = $0.content {
                    return path == newFile.path
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
        let migrated = try XCTUnwrap(legacy.groups.first).restore(tabIDs: [tabID])
        XCTAssertEqual(migrated.id, groupID)
        XCTAssertEqual(migrated.items, [.files, .tab(tabID), .git])
        XCTAssertEqual(migrated.selected, .files)

        let encoded = try JSONEncoder().encode(DockSavedGroup(migrated, tabIDs: [tabID]))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("info"))

        guard BaileyInstanceMode.isIsolated else { return XCTFail("Snapshot verification requires isolated storage") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: BaileyInstanceMode.snapshotSuiteName))
        let previous = defaults.data(forKey: "workspaceSnapshot")
        defer {
            if let previous { defaults.set(previous, forKey: "workspaceSnapshot") }
            else { defaults.removeObject(forKey: "workspaceSnapshot") }
        }
        let firstTab = Project.TabSnapshot(content: .file(path: "/fixture/first", editorState: nil))
        let secondTab = Project.TabSnapshot(content: .browser(url: "https://example.invalid"))
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
        guard case .file(let restoredPath, _) = loadedOld.tabs.first?.content,
              case .browser(let restoredURL) = loadedCurrent.tabs.first?.content else {
            return XCTFail("Both windows must retain their original content types")
        }
        XCTAssertEqual(restoredPath, "/fixture/first")
        XCTAssertEqual(restoredURL, "https://example.invalid")
        XCTAssertEqual(loadedOld.selectedTabIndex, 0)
        XCTAssertEqual(loadedCurrent.selectedTabIndex, 0)
        let restoredLegacy = DockWorkspaceModel(layout: .init())
        let oldLayout = try XCTUnwrap(loadedOld.dock)
        restoredLegacy.layout.root = oldLayout.restoreLayout()
        restoredLegacy.restore(oldLayout.groups, tabIDs: [tabID])
        XCTAssertEqual(restoredLegacy.root.groups.first?.id, groupID)
        XCTAssertEqual(restoredLegacy.root.groups.first?.items, [.files, .tab(tabID), .git])
        XCTAssertEqual(restoredLegacy.root.groups.first?.selected, .files)
        let currentTabID = UUID()
        let restoredCurrent = try XCTUnwrap(loadedCurrent.dock?.groups.first).restore(tabIDs: [currentTabID])
        XCTAssertEqual(restoredCurrent.id, secondGroupID)
        XCTAssertEqual(restoredCurrent.selected, .tab(currentTabID))
        let currentData = try JSONEncoder().encode(restoredLegacy.snapshot(tabIDs: [tabID]))
        XCTAssertFalse(String(decoding: currentData, as: UTF8.self).contains("info"))

        for invalid in ["{}", "{\"columns\":[]}", "{\"session\":{\"workingDirectory\":\"/fixture\"}}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Project.TabSnapshot.self, from: Data(invalid.utf8)))
        }
    }
}
