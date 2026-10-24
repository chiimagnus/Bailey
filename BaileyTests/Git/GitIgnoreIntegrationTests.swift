import Foundation
import XCTest
@testable import Bailey

@MainActor
final class GitIgnoreIntegrationTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    func testIgnoreEscapesSpecialFileNamesAndPreservesUnsavedCRLFBuffer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-gitignore-literal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = GitCommandExecution.run(["init", "-q", "-b", "main"], in: root.path)
        XCTAssertEqual(initial.status, 0, initial.stderr)

        let ignore = root.appendingPathComponent(".gitignore")
        try Data("existing-rule\r\n".utf8).write(to: ignore)
        let manager = workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        project.openFile(ignore.path)
        guard case .file(let file) = project.selectedTab?.content else {
            return XCTFail("A normal FileTab must own .gitignore")
        }
        try await file.waitForText()
        file.appendText("unsaved-rule")
        let before = file.text
        XCTAssertTrue(file.isDirty)
        let names = ["literal*.txt", "literal?.txt", "[abc].txt", "#hash", "!bang",
                     "back\\slash", "trailing "]
        let context = try XCTUnwrap(project.panelContext)
        try await project.ignoreGitPaths(names, isDirectory: false,
                                         repository: root.path, context: context,
                                         isCurrent: { true })
        XCTAssertTrue(file.text.hasPrefix(before + "\r\n"),
                      "Appending patterns must not discard a dirty file or normalize its CRLF")
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: ignore), Data(file.text.utf8))
        for name in names {
            let result = GitCommandExecution.run(["check-ignore", "--no-index", "--", name], in: root.path)
            XCTAssertEqual(result.status, 0, name + ": " + result.stderr)
        }
        let other = GitCommandExecution.run(["check-ignore", "--no-index", "--", "other.txt"], in: root.path)
        XCTAssertEqual(other.status, 1, "Escaping literal patterns must not ignore unrelated names")
        XCTAssertThrowsError(try GitStatusModel.ignorePatterns(["bad\nrule"], isDirectory: false))
    }

    func testIgnoreReloadsCleanCachedFileBeforeAppendingWithoutMountedView() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-ignore-external-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let path = root.appendingPathComponent(".gitignore")
        try Data("cached-rule\n".utf8).write(to: path)
        project.openFile(path.path)
        guard case .file(let file) = project.selectedTab?.content else {
            return XCTFail("Expected cached file tab")
        }
        try await file.waitForText()
        XCTAssertEqual(file.text, "cached-rule\n")
        try Data("external-rule\n".utf8).write(to: path)
        XCTAssertEqual(file.text, "cached-rule\n", "File remains cached until explicitly consumed")
        let context = try XCTUnwrap(project.panelContext)
        try await project.ignoreGitPaths(["new-rule.txt"], isDirectory: false, repository: root.path,
                                         context: context, isCurrent: { true })
        let expected = "external-rule\n/new-rule.txt\n"
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), expected,
                       "Non-view Git Ignore must preserve external edits, not write a stale cached baseline")
        XCTAssertEqual(file.text, expected)
        XCTAssertFalse(file.isDirty)
    }

    func testIgnoreCreatesOrdinaryFileTabAndRejectsStaleTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-ignore-create-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let context = try XCTUnwrap(project.panelContext)
        try await project.ignoreGitPaths(["build"], isDirectory: true, repository: root.path,
                                         context: context, isCurrent: { true })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8), "/build/\n")
        guard case .file(let file) = project.selectedTab?.content else { return XCTFail("Ordinary FileTab required") }
        XCTAssertFalse(file.isDirty)
        do {
            try await project.ignoreGitPaths(["other"], isDirectory: false, repository: root.path,
                                             context: context, isCurrent: { false })
            XCTFail("Stale target must be rejected")
        } catch is CancellationError {} catch { XCTFail(error.localizedDescription) }
        XCTAssertEqual(file.text, "/build/\n")
    }
}
