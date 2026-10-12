import Foundation

struct EditorState: Codable, Equatable {
    var selectionLocation: Int?
    var selectionLength: Int?
    var scrollX: Double?
    var scrollY: Double?
}

@main
enum SessionSnapshotCheck {
    static func main() throws {
        typealias Project = SessionSnapshot.ProjectSnapshot
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let decoder = JSONDecoder()
        let contents: [Project.ContentSnapshot] = [
            .session(workingDirectory: "/fixture"),
            .file(path: "/fixture/file", editorState: EditorState(selectionLocation: 4, scrollY: 22)),
            .browser(url: nil),
            .diff(repoRoot: "/fixture", path: "file", staged: true, untracked: false, origPath: nil),
            .commitDiff(repoRoot: "/fixture", path: "file", commitHash: "fixture", parentHash: nil, status: "A", origPath: "old")
        ]
        let tabs = contents.enumerated().map { index, content in
            Project.TabSnapshot(
                content: content, historyKey: index == 0 ? "history-fixture" : nil,
                customName: index == 0 ? "fixture" : nil, contextSessionIndex: index == 1 ? 0 : nil
            )
        }
        let dock = DockSavedNode.split(id: UUID(), axis: .horizontal, fraction: 0.3,
            first: .group(DockSavedGroup(id: UUID(), items: [.files], selected: .files)),
            second: .group(DockSavedGroup(id: UUID(), items: [.tab(0), .tab(999)], selected: .tab(999))))
        let project = Project(customName: nil, customDirectory: "/fixture", sshHost: nil, pinnedFile: nil, tabs: tabs, selectedTabIndex: 0, dock: dock)
        let app = AppSnapshot(windows: [SessionSnapshot(projects: [project], selectedProjectIndex: 0), SessionSnapshot(projects: [], selectedProjectIndex: nil)])
        let data = try encoder.encode(app)
        let encodedAgain = try encoder.encode(decoder.decode(AppSnapshot.self, from: data))
        precondition(encodedAgain == data)
        let restoredDock = dock.restore(tabIDs: [UUID()])
        precondition(restoredDock.groups.flatMap(\.items).count == 2)
        let legacyGroupID = UUID(), legacyTabID = UUID()
        let legacyDock = DockSavedNode.group(DockSavedGroup(
            id: legacyGroupID, items: [.info, .files, .tab(0), .git], selected: .info
        ))
        var legacyProject = project
        legacyProject.dock = legacyDock
        let legacyApp = AppSnapshot(windows: [SessionSnapshot(projects: [legacyProject], selectedProjectIndex: 0)])
        let decodedLegacy = try decoder.decode(AppSnapshot.self, from: encoder.encode(legacyApp))
        precondition(decodedLegacy.windows[0].projects[0].tabs.count == tabs.count)
        let migrated = decodedLegacy.windows[0].projects[0].dock.restore(tabIDs: [legacyTabID])
        precondition(migrated.groups[0].id == legacyGroupID)
        precondition(migrated.groups[0].items == [.files, .tab(legacyTabID), .git])
        precondition(migrated.groups[0].selected == .files)
        let currentSnapshot = DockSavedNode(migrated, tabIDs: [legacyTabID])
        let currentSnapshotData = try encoder.encode(currentSnapshot)
        precondition(!String(decoding: currentSnapshotData, as: UTF8.self).contains("info"))
        for invalid in ["{}", "{\"columns\":[],\"focusedColumn\":0,\"focusedRow\":0}", "{\"session\":{\"workingDirectory\":\"/fixture\"}}"] {
            precondition((try? decoder.decode(Project.TabSnapshot.self, from: Data(invalid.utf8))) == nil)
        }
        let tabData = try encoder.encode(tabs[0])
        let tabObject = try JSONSerialization.jsonObject(with: tabData) as! [String: Any]
        var missingContent = tabObject
        missingContent.removeValue(forKey: "content")
        let missingContentData = try JSONSerialization.data(withJSONObject: missingContent)
        precondition((try? decoder.decode(Project.TabSnapshot.self, from: missingContentData)) == nil)
        var badOptional = tabObject
        badOptional["contextSessionIndex"] = "bad"
        let invalid = try JSONSerialization.data(withJSONObject: badOptional)
        precondition((try? decoder.decode(Project.TabSnapshot.self, from: invalid)) == nil)
        let oldTop = try encoder.encode(app.windows[0])
        precondition((try? decoder.decode(AppSnapshot.self, from: oldTop)) == nil)
        for path in CommandLine.arguments.dropFirst() {
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
            let currentData = plist["workspaceSnapshot"] as! Data
            let current = try decoder.decode(AppSnapshot.self, from: currentData)
            let encoded = try encoder.encode(current)
            let roundtrip = try decoder.decode(AppSnapshot.self, from: encoded)
            precondition(current.windows.count == roundtrip.windows.count)
            print("PASS: current private snapshot decoded/roundtripped: \(current.windows.count) windows, \(current.windows.reduce(0) { $0 + $1.projects.count }) projects")
        }
        print("PASS: single-content tabs and outer docking snapshot, optional/history fields, required field rejection, obsolete formats rejected, invalid Dock reference filtered")
    }
}
