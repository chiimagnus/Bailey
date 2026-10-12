import Foundation
import XCTest
@testable import kero

@MainActor
final class SessionStoreTests: XCTestCase {
    func testSnapshotRoundTripAndInvalidReferences() throws {
        typealias Project = SessionSnapshot.ProjectSnapshot
        let contents: [Project.ContentSnapshot] = [
            .session(workingDirectory: "/fixture"),
            .file(path: "/fixture/file", editorState: EditorState(selectionLocation: 4, scrollY: 22)),
            .browser(url: nil),
            .diff(repoRoot: "/fixture", path: "file", staged: true, untracked: false, origPath: nil),
            .commitDiff(repoRoot: "/fixture", path: "file", commitHash: "fixture", parentHash: nil, status: "A", origPath: "old"),
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

        for invalid in ["{}", "{\"columns\":[]}", "{\"session\":{\"workingDirectory\":\"/fixture\"}}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Project.TabSnapshot.self, from: Data(invalid.utf8)))
        }
    }
}
