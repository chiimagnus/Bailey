import Foundation
import XCTest
@testable import kero

@MainActor
final class FileTreeTests: XCTestCase {
    private var fixture: URL!
    private let backend = LocalWorkspaceBackend.shared

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture)
    }

    func testExclusiveCreationAndConcurrentRace() async throws {
        let file = fixture.appendingPathComponent("exclusive.txt")
        try await backend.createFile(path: file.path)
        XCTAssertEqual(try Data(contentsOf: file), Data())
        try Data("preserve".utf8).write(to: file)
        do {
            try await backend.createFile(path: file.path)
            XCTFail("Existing file must not be overwritten")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("preserve".utf8))

        let race = fixture.appendingPathComponent("race.txt").path
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do { try await LocalWorkspaceBackend.shared.createFile(path: race); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        XCTAssertEqual(winners, 1)
    }

    func testTreeExpansionDraftAndRename() async throws {
        let root = fixture.appendingPathComponent("root")
        let nested = root.appendingPathComponent("dir/inner")
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let original = nested.appendingPathComponent("a.swift")
        try Data().write(to: original)

        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: backend)
        let compact = try XCTUnwrap(tree.items.first { $0.path == nested.path })
        XCTAssertEqual(compact.displayName, "dir / inner")
        await tree.toggle(compact)
        XCTAssertTrue(tree.items.contains { $0.path == original.path })

        await tree.beginNewFile(in: nested.path)
        XCTAssertTrue(tree.items.contains { $0.isDraft && $0.depth == 1 })
        let created = await tree.commitDraft(name: "draft.swift")
        XCTAssertEqual(created, nested.appendingPathComponent("draft.swift").path)

        let renamed = await tree.rename(compact, to: "renamed")
        XCTAssertEqual(renamed, root.appendingPathComponent("dir/renamed").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed! + "/draft.swift"))
        XCTAssertEqual(tree.items.first { $0.path == renamed }?.displayName, "dir / renamed")
    }

    func testExpansionIsScopedByRootAndWorkspaceIdentity() async throws {
        let firstRoot = fixture.appendingPathComponent("a")
        let secondRoot = fixture.appendingPathComponent("b")
        let firstNested = firstRoot.appendingPathComponent("dir/inner")
        let secondNested = secondRoot.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: firstNested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondNested, withIntermediateDirectories: true)
        try Data().write(to: firstNested.appendingPathComponent("a.swift"))
        try Data().write(to: secondNested.appendingPathComponent("b.swift"))

        let tree = FileTreeModel()
        await tree.sync(root: firstRoot.path, backend: backend)
        let compact = try XCTUnwrap(tree.items.first { $0.path == firstNested.path })
        await tree.toggle(compact)
        XCTAssertTrue(tree.isExpanded(compact))

        await tree.sync(root: secondRoot.path, backend: backend)
        XCTAssertFalse(tree.isExpanded(compact))
        await tree.sync(root: firstRoot.path, backend: backend)
        XCTAssertTrue(tree.isExpanded(compact))
        await tree.sync(root: firstRoot.path, backend: backend, scope: "ssh:fixture")
        XCTAssertFalse(tree.isExpanded(compact))
        await tree.sync(root: firstRoot.path, backend: backend, scope: "local")
        XCTAssertTrue(tree.isExpanded(compact))
    }

    func testSharedTreeStatusAndCompaction() {
        let statuses: [(Character, TreeDisplayModel.Status)] = [
            ("M", .modified), ("A", .added), ("?", .untracked), ("D", .deleted),
            ("R", .renamed), ("C", .copied), ("U", .conflict), ("!", .ignored), ("T", .changed),
        ]
        let rows = statuses.map { character, status -> TreeDisplayModel.Row in
            XCTAssertEqual(TreeDisplayModel.Status(character), status)
            return TreeDisplayModel.Row(
                name: "\(character).swift",
                path: "dir/renamed/\(character).swift",
                isDirectory: false,
                status: status
            )
        }
        let display = TreeDisplayModel.pathRows(rows, section: "unstaged", collapsed: [])
        XCTAssertEqual(display.first?.displayName, "dir / renamed")
        XCTAssertEqual(display.first?.depth, 0)
        XCTAssertTrue(display.dropFirst().allSatisfy { !$0.isDirectory && $0.depth == 1 })

        let boundary = ["dir/a.swift", "dir/sub/deep/b.swift", "file10.swift", "file2.swift"].map {
            TreeDisplayModel.Row(name: ($0 as NSString).lastPathComponent, path: $0, isDirectory: false)
        }
        XCTAssertEqual(
            TreeDisplayModel.pathRows(boundary, section: "boundary", collapsed: []).map(\.displayName),
            ["dir", "sub / deep", "b.swift", "a.swift", "file2.swift", "file10.swift"]
        )
    }
}
