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
                            historyKey: "history-\(index)"
                        )], selectedTabIndex: nil,
                        groups: []
                    )], selectedProjectIndex: 0, layout: .group(DockGroup(items: [.files])))
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
        let left = DockGroup(items: [.projects])
        let right = DockGroup(items: [.files])
        let layout = DockNode.split(DockSplit(axis: .horizontal, fraction: 0.6,
                                              first: .group(left), second: .group(right)))
        func project(_ name: String, in group: DockGroup) -> SessionSnapshot.ProjectSnapshot {
            let placement = DockSavedGroup(id: group.id,
                items: group.items.compactMap { DockSavedItem($0, tabIDs: []) } + [.tab(0)],
                selected: .tab(0))
            return .init(customDirectory: "/fixture/" + name, tabs: [
                .init(content: .browser(url: "about:blank"))
            ], selectedTabIndex: 0, groups: [placement])
        }
        let snapshot = SessionSnapshot(projects: [project("A", in: left), project("B", in: right)],
                                       selectedProjectIndex: 1, layout: layout)
        XCTAssertTrue(window.restore(from: snapshot, histories: [:]))
        XCTAssertEqual(window.dockLayout.root, layout)
        func check(_ window: WorkspaceWindowModel) throws {
            XCTAssertEqual(window.dockLayout.root, layout)
            XCTAssertEqual(window.selectedProject?.name, "B")
            XCTAssertEqual(window.projects.count, 2)
            for (project, group) in zip(window.projects, [left, right]) {
                let tab = try XCTUnwrap(project.tabs.first)
                XCTAssertEqual(project.dock.tabOrder, [tab.id])
                XCTAssertEqual(project.dock.root.groups.map(\.id), [left.id, right.id])
                XCTAssertEqual(project.dock.group(containing: .tab(tab.id))?.id, group.id)
                XCTAssertEqual(project.dock.root.group(id: group.id)?.selected, .tab(tab.id))
            }
        }
        try check(window)
        let saved = window.makeWindowSnapshot(captureTerminalHistory: false).snapshot
        XCTAssertEqual(saved.layout, layout)
        XCTAssertEqual(saved.projects.map { $0.groups.count }, [1, 1])
        let bytes = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: bytes)
        let otherApplication = WorkspaceApplication()
        let restored = otherApplication.makeWindow()
        defer { restored.windowClosed() }
        XCTAssertTrue(restored.restore(from: decoded, histories: [:]))
        try check(restored)
    }

    func testRestoreSkipsInvalidProjectRecordsWithoutChangingValidSelection() {
        func saved(_ directory: String?, sshHost: String? = nil,
                   file: String? = nil) -> SessionSnapshot.ProjectSnapshot {
            .init(
                customDirectory: directory, sshHost: sshHost, pinnedFile: file,
                tabs: [], selectedTabIndex: nil,
                groups: []
            )
        }

        let snapshot = SessionSnapshot(projects: [
            saved(nil),
            saved(""),
            saved("relative/project"),
            saved("relative/remote", sshHost: "fixture-ssh"),
            saved("/tmp/fixed-one"),
            saved("/tmp/invalid-local", file: "/tmp/invalid-local/file.txt"),
            saved("/d/remote", sshHost: "fixture-ssh", file: "/d/remote/source.swift"),
            saved("/tmp/fixed-two"),
        ], selectedProjectIndex: 7, layout: .group(DockGroup(items: [.projects, .files])))
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        XCTAssertTrue(manager.restore(from: snapshot, histories: [:]))
        XCTAssertEqual(manager.projects.map(\.customDirectory),
                       ["/tmp/fixed-one", "/d/remote", "/tmp/fixed-two"])
        XCTAssertEqual(manager.selectedProject?.name, "fixed-two",
                       "Rejecting invalid project records cannot shift selection to a different project")
        XCTAssertEqual(manager.projects[1].name, "source.swift")
        XCTAssertEqual(manager.projects[1].pinnedFile, "/d/remote/source.swift")
        XCTAssertTrue(manager.projects[1].tabs.isEmpty,
                      "Restoring a project must not reopen a file absent from its saved tabs")
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
        SessionStore.save([SessionSnapshot(projects: [], selectedProjectIndex: nil, layout: .group(DockGroup(items: [.files])))])
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

    func testIndependentTabsDoNotPersistRetiredTerminalAssociations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shellDirectory = root.appendingPathComponent("shell")
        try FileManager.default.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: file)

        let application = WorkspaceApplication()
        let window = application.makeWindow()
        defer { window.windowClosed() }
        window.addLocalFolders([root])
        let project = try XCTUnwrap(window.selectedProject)
        let terminal = project.newSession(directory: shellDirectory.path)
        project.openFile(file.path)
        project.newBrowserTab(initialFocus: .none)
        project.openDiff(repoRoot: root.path, path: "file.txt", staged: false,
                         untracked: true, origPath: nil)
        let newTerminal = project.newSession()
        XCTAssertEqual(newTerminal.currentDirectoryPath, root.path)

        let saved = window.makeWindowSnapshot(captureTerminalHistory: false).snapshot
        let data = try JSONEncoder().encode(saved)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("contextSessionIndex"),
                       "Files, browser tabs and diffs must not persist any terminal ownership")
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let restored = application.makeWindow()
        defer { restored.windowClosed() }
        XCTAssertTrue(restored.restore(from: decoded, histories: [:]))
        let restoredProject = try XCTUnwrap(restored.selectedProject)
        XCTAssertEqual(restoredProject.sessions.map(\.currentDirectoryPath), [shellDirectory.path, root.path])
        XCTAssertEqual(restoredProject.tabs.count, 5)
        project.close(try XCTUnwrap(project.tabs.first { $0.content.id == terminal.id }))
        XCTAssertEqual(project.tabs.count, 4)
        XCTAssertEqual(project.customDirectory, root.path)
    }

    func testTerminalSnapshotAndWorktreeProtectionStayOnLaunchMachine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let application = WorkspaceApplication()
        let window = application.makeWindow()
        defer { window.windowClosed() }
        window.addLocalFolders([root])
        let local = try XCTUnwrap(window.selectedProject)
        let remote = Project(customDirectory: "/remote/project", sshHost: "fixture-alias", layout: window.dockLayout)
        window.projects.append(remote)
        let localTerminal = local.newSession()
        let remoteTerminal = remote.newSession()
        let explicitTerminal = remote.newSession(directory: "/remote/explicit")
        func savedDirectories() -> [String] {
            window.makeWindowSnapshot(captureTerminalHistory: false).snapshot.projects.flatMap { project in
                project.tabs.compactMap { tab in
                    guard case .session(let directory) = tab.content else { return nil }
                    return directory
                }
            }
        }
        XCTAssertEqual(savedDirectories(), [root.path, "/remote/project", "/remote/explicit"])
        XCTAssertFalse(remoteTerminal.acceptsLocalFileDrop)
        explicitTerminal.terminalDidChangeWorkingDirectory("/remote/changed")
        let connection = RemoteConnection(user: "fixture", host: "fixture.invalid", port: 22,
            controlSocket: URL(fileURLWithPath: "/tmp/bailey-unused-\(UUID())"), sshPID: 0)
        connection.workingDirectory = "/remote/observed"
        connection.markConnected()
        remoteTerminal.remoteConnection = connection
        XCTAssertEqual(savedDirectories(), [root.path, "/remote/observed", "/remote/changed"])
        XCTAssertTrue(application.isWorktreeInUse(path: "/remote/observed", scope: "ssh:fixture-alias"))
        XCTAssertFalse(application.isWorktreeInUse(path: "/remote/observed", scope: "local"))

        let manual = RemoteConnection(user: "fixture", host: "other.invalid", port: 22,
            controlSocket: URL(fileURLWithPath: "/tmp/bailey-unused-\(UUID())"), sshPID: 0)
        manual.workingDirectory = "/remote/manual"
        manual.markConnected()
        localTerminal.remoteConnection = manual
        localTerminal.terminalDidChangeWorkingDirectory("/remote/manual")
        XCTAssertEqual(savedDirectories().first, root.path)
        XCTAssertFalse(application.isWorktreeInUse(path: "/remote/manual", scope: "local"))
        localTerminal.remoteConnection = nil
        XCTAssertEqual(localTerminal.currentDirectoryPath, root.path)

        let snapshot = window.makeWindowSnapshot(captureTerminalHistory: false).snapshot
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        let restored = application.makeWindow()
        defer { restored.windowClosed() }
        XCTAssertTrue(restored.restore(from: decoded, histories: [:]))
        XCTAssertEqual(restored.projects.flatMap(\.sessions).map(\.currentDirectoryPath),
                       [root.path, "/remote/observed", "/remote/changed"])
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
                historyKey: index == 0 ? "history-fixture" : nil
            )
        }
        let left = DockGroup(items: [.files])
        let right = DockGroup(items: [])
        let layout = DockNode.split(DockSplit(axis: .horizontal, fraction: 0.3,
                                              first: .group(left), second: .group(right)))
        let placement = DockSavedGroup(id: right.id, items: [.tab(0), .tab(999)], selected: .tab(999))
        let project = Project(
            customDirectory: "/fixture", sshHost: nil, pinnedFile: nil,
            tabs: tabs, selectedTabIndex: 0, groups: [placement]
        )
        let snapshot = AppSnapshot(windows: [
            SessionSnapshot(projects: [project], selectedProjectIndex: 0, layout: layout),
            SessionSnapshot(projects: [], selectedProjectIndex: nil, layout: .group(DockGroup(items: []))),
        ])

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(snapshot)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("customName"),
                       "A tab's title is derived from content and never persisted separately")
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: data)
        XCTAssertEqual(try encoder.encode(decoded), data)

        let ids = [UUID()]
        let restored = placement.restore(tabIDs: ids)
        XCTAssertEqual(restored.items, [.tab(ids[0])])
        XCTAssertEqual(restored.selected, .tab(ids[0]))
        XCTAssertEqual(decoded.windows.first?.layout, layout)
    }

    func testClosedPinnedSSHFileStaysClosedAfterRoundTrip() throws {
        let application = WorkspaceApplication()
        let window = application.makeWindow()
        defer { window.windowClosed() }
        let path = "/remote/project/pinned.swift"
        let snapshot = SessionSnapshot(projects: [.init(
            customDirectory: "/remote/project", sshHost: "fixture-ssh", pinnedFile: path,
            tabs: [.init(content: .file(path: path, editorState: nil))],
            selectedTabIndex: 0, groups: []
        )], selectedProjectIndex: 0, layout: .group(DockGroup(items: [.files])))
        XCTAssertTrue(window.restore(from: snapshot, histories: [:]))
        let project = try XCTUnwrap(window.selectedProject)
        let tab = try XCTUnwrap(project.tabs.first)
        XCTAssertEqual(project.tabs.count, 1)
        guard case .file(let file) = tab.content else {
            return XCTFail("Expected the saved SSH file")
        }
        XCTAssertEqual(file.workspaceIdentity, "ssh:fixture-ssh")
        project.close(tab)
        XCTAssertTrue(project.tabs.isEmpty)
        let saved = window.makeWindowSnapshot(captureTerminalHistory: false).snapshot
        XCTAssertEqual(saved.projects.first?.pinnedFile, path)
        XCTAssertTrue(saved.projects.first?.tabs.isEmpty == true)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(saved))
        let restoredApplication = WorkspaceApplication()
        let restored = restoredApplication.makeWindow()
        defer { restored.windowClosed() }
        XCTAssertTrue(restored.restore(from: decoded, histories: [:]))
        XCTAssertEqual(restored.selectedProject?.pinnedFile, path)
        XCTAssertEqual(restored.selectedProject?.name, "pinned.swift")
        XCTAssertTrue(restored.selectedProject?.tabs.isEmpty == true)
    }

    func testMacAndRemoteFilesInSSHProjectRestoreTheirOwnMachine() async throws {
        typealias Snapshot = SessionSnapshot.ProjectSnapshot
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("same.swift")
        try "Mac bytes".write(to: path, atomically: true, encoding: .utf8)

        let mac = Snapshot.TabSnapshot(
            content: .file(path: path.path, editorState: EditorState(selectionLocation: 3)),
            historyKey: nil,
            localFile: true
        )
        let json = try JSONEncoder().encode(mac)
        let decoded = try JSONDecoder().decode(Snapshot.TabSnapshot.self, from: json)
        XCTAssertEqual(decoded.localFile, true)

        let project = Project(customDirectory: "/fixture/SSH", sshHost: "invalid-p4-snapshot", layout: .init())
        let tab = project.restoreTab(from: decoded)
        guard case .file(let restoredMac) = tab.content else {
            return XCTFail("Restored file must be a native FileTab")
        }
        XCTAssertNil(restoredMac.workspaceIdentity)
        try await restoredMac.waitForText()
        XCTAssertEqual(restoredMac.text, "Mac bytes")
        XCTAssertEqual(restoredMac.editorState.selectionLocation, 3)

        let remoteSnapshot = Snapshot.TabSnapshot(content: mac.content, localFile: false)
        let restoredSnapshot = try JSONDecoder().decode(
            Snapshot.TabSnapshot.self, from: JSONEncoder().encode(remoteSnapshot)
        )
        XCTAssertFalse(restoredSnapshot.localFile)
        let remoteTab = project.restoreTab(from: restoredSnapshot)
        guard case .file(let remote) = remoteTab.content else {
            return XCTFail("Remote file tab must be restored")
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
        let ssh = Project(customDirectory: "/remote/project", sshHost: "invalid-p4-autosave", layout: manager.dockLayout)
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
                historyKey: key
            )],
            selectedTabIndex: 0,
            groups: []
        )
        SessionStore.save([.init(projects: [project], selectedProjectIndex: 0,
                                 layout: .group(DockGroup(items: [.projects])))])
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
        if case .split(let split)? = SessionStore.load().first(where: {
            $0.projects.contains { $0.customDirectory == directory.path }
        })?.layout {
            XCTAssertEqual(split.fraction, 0.31, accuracy: 0.001)
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

    func testInvalidWindowLayoutIsRejectedWithoutChangingWindow() throws {
        let application = WorkspaceApplication()
        let window = application.makeWindow()
        defer { window.windowClosed() }
        let before = window.dockLayout.root
        let project = SessionSnapshot.ProjectSnapshot(customDirectory: "/fixture",
            tabs: [.init(content: .browser(url: "about:blank"))],
            selectedTabIndex: 0, groups: [])
        let contentGroup = DockGroup(items: [.tab(UUID())])
        var invalidSelection = DockGroup(items: [.files])
        invalidSelection.selected = .git
        for group in [contentGroup, invalidSelection] {
            let snapshot = SessionSnapshot(projects: [project], selectedProjectIndex: 0,
                                           layout: .group(group))
            let decoded = try JSONDecoder().decode(SessionSnapshot.self,
                                                  from: JSONEncoder().encode(snapshot))
            XCTAssertFalse(window.restore(from: decoded, histories: [:]))
            XCTAssertEqual(window.dockLayout.root, before)
            XCTAssertTrue(window.projects.isEmpty)
        }
    }

    func testOnlyCurrentWindowSnapshotSchemaIsAccepted() throws {
        let application = WorkspaceApplication()
        let window = application.makeWindow()
        defer { window.windowClosed() }
        let project = Project(customDirectory: "/fixture", layout: window.dockLayout)
        window.projects = [project]
        window.selectedProjectID = project.id
        project.newBrowserTab(initialFocus: .none)
        let snapshot = window.makeWindowSnapshot(captureTerminalHistory: false).snapshot
        let data = try JSONEncoder().encode(snapshot)
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoder = JSONDecoder()
        XCTAssertNoThrow(try decoder.decode(SessionSnapshot.self, from: data))

        var missingLayout = current
        missingLayout.removeValue(forKey: "layout")
        XCTAssertThrowsError(try decoder.decode(SessionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: missingLayout)))

        let projects = try XCTUnwrap(current["projects"] as? [[String: Any]])
        var missingGroups = projects
        missingGroups[0].removeValue(forKey: "groups")
        var invalid = current
        invalid["projects"] = missingGroups
        XCTAssertThrowsError(try decoder.decode(SessionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: invalid)))

        var missingIdentity = projects
        var tabs = try XCTUnwrap(projects[0]["tabs"] as? [[String: Any]])
        tabs[0].removeValue(forKey: "localFile")
        missingIdentity[0]["tabs"] = tabs
        invalid["projects"] = missingIdentity
        XCTAssertThrowsError(try decoder.decode(SessionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: invalid)))

        var retiredInfo = projects
        var groups = try XCTUnwrap(projects[0]["groups"] as? [[String: Any]])
        groups[0]["items"] = [["info": [:] as [String: Any]]]
        retiredInfo[0]["groups"] = groups
        invalid["projects"] = retiredInfo
        XCTAssertThrowsError(try decoder.decode(SessionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: invalid)))
    }

}
