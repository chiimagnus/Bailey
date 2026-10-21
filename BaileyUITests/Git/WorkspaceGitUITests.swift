import XCTest

@MainActor
final class WorkspaceGitUITests: XCTestCase {
    func testGitGraphDisplaysTheRealCommitAndExpandsItsFiles() throws {
        let fixture = try WorkspaceUITestFixture()
        let committed = try fixture.file("history-marker.swift", text: "let historyMarker = true\n")
        try fixture.initializeGit()
        let app = try WorkspaceUITestSupport.launch()
        defer {
            app.terminate()
            fixture.remove()
        }

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(git.waitForExistence(timeout: 20))
        git.click()

        let history = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "E2E fixture history")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 25),
                      "Git Graph must show a commit from the actual fixture repository")
        history.click()
        let path = WorkspaceUITestSupport.element("bailey.tree.file.\(committed.path)", in: app)
        XCTAssertTrue(path.waitForExistence(timeout: 15),
                      "Opening a real Git Graph commit must reveal its changed file")
    }

    func testGitChangesAreScopedToTheOpenedRepository() throws {
        let fixture = try WorkspaceUITestFixture()
        let changed = try fixture.file("changed-file.swift", text: "let saved = 1\n")
        try fixture.initializeGit()
        try "let saved = 2\n".write(to: changed, atomically: true, encoding: .utf8)
        let app = try WorkspaceUITestSupport.launch()
        defer {
            app.terminate()
            fixture.remove()
        }

        try WorkspaceUITestSupport.addFolder(fixture.root, to: app)
        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(git.waitForExistence(timeout: 20))
        git.click()

        let change = WorkspaceUITestSupport.element("bailey.tree.file.\(changed.path)", in: app)
        XCTAssertTrue(change.waitForExistence(timeout: 25),
                      "Git Changes must expose the modified file in the selected repository")
        change.click()
        let diff = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "changed-file.swift")
        ).firstMatch
        XCTAssertTrue(diff.waitForExistence(timeout: 15),
                      "The real Git Changes row must open a diff tab")
    }
}
