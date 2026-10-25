import Foundation
import XCTest

@MainActor
final class WorkspaceFileIndexRefreshUITests: XCTestCase {
    func testCommandPaletteTracksExternalFilesAndGitScopeWithoutOpeningFilesPanel() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = try fixture.file("p4watch-original.swift", text: "original byte marker\n")
        let ignored = try fixture.file("p4ignored.tmp", text: "tracked only when explicitly staged\n")
        let rules = try fixture.file(".gitignore", text: "# initially unignored\n")
        try fixture.git(["init", "-q", "-b", "main"])
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en")
        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)

        let gitPanel = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(gitPanel.waitForExistence(timeout: 15))
        gitPanel.click() // Files is not mounted: Cmd+P must still observe its root.
        app.typeKey("p", modifierFlags: .command)
        let search = app.textFields["bailey.commandPalette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("p4watch")
        func result(_ file: URL) -> XCUIElement {
            app.buttons.matching(identifier: "bailey.commandPalette.result")
                .matching(NSPredicate(format: "value == %@", "file-" + file.path)).firstMatch
        }
        let oldResult = result(original)
        XCTAssertTrue(oldResult.waitForExistence(timeout: 15))

        let added = try fixture.file("p4watch-new.swift", text: "external creation byte marker\n")
        let newResult = result(added)
        XCTAssertTrue(newResult.waitForExistence(timeout: 15),
                      "A non-Files ⌘P must see a real new file while already open")
        try FileManager.default.removeItem(at: original)
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: oldResult
        )
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 15), .completed,
                       "Cmd+P must remove externally deleted files without switching to Files")

        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("p4ignored")
        let ignoredResult = result(ignored)
        XCTAssertTrue(ignoredResult.waitForExistence(timeout: 15),
                      "Untracked and non-ignored files must initially be searchable")

        try Data("*.tmp\n".utf8).write(to: rules)
        let excluded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: ignoredResult
        )
        XCTAssertEqual(XCTWaiter.wait(for: [excluded], timeout: 15), .completed,
                       "Editing the same .gitignore file must invalidate already-open results")
        try fixture.git(["add", "-f", "--", ignored.lastPathComponent])
        XCTAssertTrue(ignoredResult.waitForExistence(timeout: 15),
                      "Staging an ignored file must update search results without a tree change")

        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("p4watch-new")
        XCTAssertTrue(newResult.waitForExistence(timeout: 15))
        newResult.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(added, in: app.windows.firstMatch)
            .waitForExistence(timeout: 15),
            "The refreshed search result must open the actual file, not merely display a row")
        XCTAssertEqual(try String(contentsOf: added, encoding: .utf8), "external creation byte marker\n")
    }
}
