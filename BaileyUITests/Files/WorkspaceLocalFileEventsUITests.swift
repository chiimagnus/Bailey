import Foundation
import XCTest

@MainActor
final class WorkspaceLocalFileEventsUITests: XCTestCase {
    func testRealLocalFilesRefreshAndCatchUpWhenPanelIsHidden() throws {
        let fixture = try WorkspaceUITestFixture(in: self)
        let first = try fixture.file("first.swift", text: "original content\n")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
        let files = WorkspaceUITestSupport.element("bailey.dock.files", in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        files.click()
        let window = app.windows.firstMatch
        let firstRow = WorkspaceUITestSupport.fileRow(first, in: window)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15))

        // These changes originate in XCTest, not in Bailey or its terminal.
        let added = try fixture.file("external.swift", text: "new content\n")
        let addedRow = WorkspaceUITestSupport.fileRow(added, in: window)
        XCTAssertTrue(addedRow.waitForExistence(timeout: 15),
                      "Visible Files must update without an explicit Refresh or a 2-second timer")
        let renamed = fixture.root.appendingPathComponent("renamed.swift")
        try FileManager.default.moveItem(at: first, to: renamed)
        XCTAssertTrue(WorkspaceUITestSupport.fileRow(renamed, in: window)
            .waitForExistence(timeout: 15))
        XCTAssertTrue(firstRow.waitForNonExistence(timeout: 15))
        try FileManager.default.removeItem(at: added)
        XCTAssertTrue(addedRow.waitForNonExistence(timeout: 15))

        let git = WorkspaceUITestSupport.element("bailey.dock.git", in: app)
        XCTAssertTrue(git.waitForExistence(timeout: 15))
        git.click()
        let hiddenChange = try fixture.file("while-hidden.swift", text: "hidden content\n")
        files.click()
        XCTAssertTrue(WorkspaceUITestSupport.fileRow(hiddenChange, in: window)
            .waitForExistence(timeout: 15),
            "Reopening Files must rescan once and recover changes missed while hidden")
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "original content\n")
        XCTAssertEqual(try String(contentsOf: hiddenChange, encoding: .utf8), "hidden content\n")
    }
}
