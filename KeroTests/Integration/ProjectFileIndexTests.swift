import Foundation
import XCTest
@testable import kero

final class ProjectFileIndexTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-palette-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ name: String, in root: URL) throws {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: file)
    }

    func testGitIndexIncludesTrackedAndNonignoredUntrackedWithExactUTF8Paths() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) {
            let result = GitCommandExecution.run(args, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        git(["init", "-q"])
        try write("ignored.tmp\n", ".gitignore", in: root)
        try write("tracked", "tracked.swift", in: root)
        let unicode = "nested/中文😀\nname.swift"
        try write("unicode", unicode, in: root)
        try write("hidden", "ignored.tmp", in: root)
        try write("new", "untracked.js", in: root)
        git(["add", "--", "tracked.swift", unicode, ".gitignore"])

        let files = ProjectFileIndex.load(in: root.path)
        let paths = Set(files.map(\.relativePath))
        XCTAssertTrue(paths.contains("tracked.swift"))
        XCTAssertTrue(paths.contains(unicode))
        XCTAssertTrue(paths.contains("untracked.js"))
        XCTAssertTrue(paths.contains(".gitignore"))
        XCTAssertFalse(paths.contains("ignored.tmp"))
        XCTAssertFalse(paths.contains { $0.hasPrefix(".git/") })
        XCTAssertEqual(files.first { $0.relativePath == unicode }?.name, "中文😀\nname.swift")
        XCTAssertEqual(
            files.first { $0.relativePath == unicode }?.parentPath, "nested"
        )

        try FileManager.default.removeItem(at: root.appendingPathComponent("tracked.swift"))
        XCTAssertFalse(ProjectFileIndex.load(in: root.path).contains {
            $0.relativePath == "tracked.swift"
        })
    }

    func testPlainDirectoryFallbackSkipsVCSMetadataAndHonorsCancellation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("alpha", "nested/a.swift", in: root)
        try write("bravo", "b.swift", in: root)
        try write("internal", ".git/objects/private", in: root)

        let files = ProjectFileIndex.load(in: root.path)
        XCTAssertEqual(files.map(\.relativePath), ["b.swift", "nested/a.swift"])
        XCTAssertEqual(files.first?.absolutePath, root.appendingPathComponent("b.swift").path)

        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ProjectFileIndex.load(in: root.path)
        }.value
        XCTAssertTrue(cancelled.isEmpty, "A canceled index must not publish stale files")
    }
}
