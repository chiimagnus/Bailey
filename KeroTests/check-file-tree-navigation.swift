// Regression check using the real FileTreeModel and local filesystem backend.
// From the repository root:
// xcrun swiftc -swift-version 5 -o build/check-file-tree-navigation \
//   kero/Workspace/WorkspaceBackend.swift kero/Workspace/LocalWorkspaceBackend.swift \
//   kero/Shared/Tree/TreeDisplayModel.swift \
//   kero/Files/FileTreeModel.swift \
//   KeroTests/check-file-tree-navigation.swift && build/check-file-tree-navigation

import Combine
import Foundation


@main
enum FileTreeNavigationCheck {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let backend = LocalWorkspaceBackend.shared
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let a = fixture.appendingPathComponent("a")
        let b = fixture.appendingPathComponent("b")
        let nested = a.appendingPathComponent("dir/inner")
        let empty = a.appendingPathComponent("empty")
        let other = b.appendingPathComponent("other")
        for dir in [nested, empty, other] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let createdURL = fixture.appendingPathComponent("exclusive.txt")
        try await backend.createFile(path: createdURL.path)
        let createdBytes = try Data(contentsOf: createdURL)
        precondition(createdBytes.isEmpty)
        try Data("preserve".utf8).write(to: createdURL)
        do {
            try await backend.createFile(path: createdURL.path)
            preconditionFailure("Creation overwrote an existing file")
        } catch {}
        let preservedBytes = try Data(contentsOf: createdURL)
        precondition(preservedBytes == Data("preserve".utf8))
        let dangling = fixture.appendingPathComponent("dangling")
        let missingTarget = fixture.appendingPathComponent("missing")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: missingTarget)
        do {
            try await backend.createFile(path: dangling.path)
            preconditionFailure("Creation followed a dangling symlink")
        } catch {}
        precondition(!fm.fileExists(atPath: missingTarget.path))
        let createdFolder = fixture.appendingPathComponent("exclusive-folder")
        try await backend.createDirectory(path: createdFolder.path)
        let folderSentinel = createdFolder.appendingPathComponent("preserve.txt")
        try Data("preserve".utf8).write(to: folderSentinel)
        do {
            try await backend.createDirectory(path: createdFolder.path)
            preconditionFailure("Creation accepted an existing folder")
        } catch {}
        let folderBytes = try Data(contentsOf: folderSentinel)
        precondition(folderBytes == Data("preserve".utf8))
        do {
            try await backend.createDirectory(path: dangling.path)
            preconditionFailure("Folder creation followed a dangling symlink")
        } catch {}
        precondition(!fm.fileExists(atPath: missingTarget.path))
        let race = fixture.appendingPathComponent("race.txt").path
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do { try await backend.createFile(path: race); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        precondition(winners == 1)
        let original = nested.appendingPathComponent("a.swift").path
        try Data().write(to: URL(fileURLWithPath: original))
        try Data().write(to: other.appendingPathComponent("b.swift"))

        let first = FileTreeModel()
        let second = FileTreeModel()
        await first.sync(root: a.path, backend: backend)
        let compact = first.items.first { $0.path == nested.path }!
        assert(compact.displayName == "dir / inner")
        assert(compact.depth == 0)
        await first.toggle(compact)
        assert(first.items.contains { $0.path == original })

        await second.sync(root: b.path, backend: backend)
        await second.toggle(second.items.first { $0.path == other.path }!)
        await first.sync(root: a.path, backend: backend)
        assert(first.isExpanded(compact))
        assert(second.items.contains { $0.path == other.appendingPathComponent("b.swift").path })

        await first.sync(root: b.path, backend: backend)
        assert(!first.isExpanded(compact))
        await first.sync(root: a.path, backend: backend)
        assert(first.isExpanded(compact))

        await first.sync(root: a.path, backend: backend, scope: "ssh:fixture")
        assert(!first.isExpanded(compact))
        await first.sync(root: a.path, backend: backend, scope: "local")
        assert(first.isExpanded(compact))

        let added = nested.appendingPathComponent("new.swift").path
        try Data().write(to: URL(fileURLWithPath: added))
        await first.sync(root: a.path, backend: backend)
        assert(first.items.contains { $0.path == added })
        assert(first.isExpanded(compact))

        let emptyItem = first.items.first { $0.path == empty.path }!
        let before = first.items
        var notifications = 0
        let observation = first.objectWillChange.sink { notifications += 1 }
        await first.toggle(emptyItem)
        assert(first.isExpanded(emptyItem) && first.items != before)
        assert(first.items.first { $0.path == empty.path }!.isExpanded)
        assert(notifications > 0)
        withExtendedLifetime(observation) {}
        await first.beginNewFile(in: nested.path)
        assert(first.items.contains { $0.isDraft && $0.depth == 1 })
        let created = await first.commitDraft(name: "draft.swift")
        assert(created == nested.appendingPathComponent("draft.swift").path)
        assert(fm.fileExists(atPath: created!))
        assert(!first.items.contains { $0.isDraft })

        let renamed = await first.rename(compact, to: "renamed")
        assert(renamed == a.appendingPathComponent("dir/renamed").path)
        assert(fm.fileExists(atPath: renamed! + "/draft.swift"))
        let renamedRow = first.items.first { $0.path == renamed }!
        assert(renamedRow.displayName == "dir / renamed" && renamedRow.isExpanded)

        await first.beginNewFolder(in: a.appendingPathComponent("dir").path)
        let parent = first.items.first { $0.path == a.appendingPathComponent("dir").path }!
        assert(parent.displayName == "dir")
        assert(first.items.contains { $0.isDraft && $0.depth == 1 })
        await first.cancelDraft()
        assert(first.items.contains { $0.displayName == "dir / renamed" })

        var paths: [TreeDisplayModel.Row] = []
        let combinedStatuses: [(staged: Character, unstaged: Character, conflict: Bool, expected: TreeDisplayModel.Status)] = [
            (".", "A", false, .added), ("T", ".", false, .changed),
            (".", "T", false, .changed), ("A", "M", false, .added),
            ("D", "M", false, .deleted), ("R", "M", false, .renamed),
            ("C", "M", false, .copied), ("M", "M", false, .modified),
            ("?", "?", false, .untracked), ("A", "U", false, .conflict),
            ("?", "?", true, .conflict), (".", ".", false, .modified)
        ]
        for input in combinedStatuses {
            assert(TreeDisplayModel.Status(staged: input.staged, unstaged: input.unstaged,
                                           isConflict: input.conflict) == input.expected)
        }
        for (character, status) in zip(Array("MA?DRCU!T"), [
            TreeDisplayModel.Status.modified, .added, .untracked, .deleted,
            .renamed, .copied, .conflict, .ignored, .changed
        ]) {
            assert(TreeDisplayModel.Status(character) == status)
            let path = "dir/renamed/\(character).swift"
            let row = TreeDisplayModel.Row(name: "\(character).swift", path: path,
                                          isDirectory: false, status: .init(character))
            assert(row.accessibilityLabel.contains(status.accessibilityName))
            paths.append(row)
        }
        for section in ["unstaged", "staged", "merge", "commit:fixture"] {
            let rows = TreeDisplayModel.pathRows(paths, section: section, collapsed: [])
            assert(rows[0].displayName == renamedRow.displayName)
            assert(rows[0].path == "dir/renamed" && rows[0].depth == 0)
            assert(rows[0].status == .conflict && rows[0].isExpanded)
            assert(rows.dropFirst().allSatisfy { !$0.isDirectory && $0.depth == 1 })
            assert(rows.dropFirst().allSatisfy { $0.status != nil })
            let folded = TreeDisplayModel.pathRows(paths, section: section,
                                                   collapsed: [section + ":dir/renamed"])
            assert(folded.count == 1 && !folded[0].isExpanded)
            let unrelated = TreeDisplayModel.pathRows(paths, section: section,
                                                      collapsed: ["other:dir/renamed"])
            assert(unrelated == rows)
        }
        let staged = TreeDisplayModel.pathRows(paths, section: "staged", collapsed: [])
        let unstaged = TreeDisplayModel.pathRows(paths, section: "unstaged", collapsed: [])
        assert(Set(staged.map(\.id)).isDisjoint(with: unstaged.map(\.id)))

        let boundaryPaths = ["dir/a.swift", "dir/sub/deep/b.swift", "file10.swift", "file2.swift"]
        let boundary = TreeDisplayModel.pathRows(boundaryPaths.map {
            TreeDisplayModel.Row(name: ($0 as NSString).lastPathComponent, path: $0, isDirectory: false)
        }, section: "boundary", collapsed: [])
        assert(boundary.map(\.displayName) == ["dir", "sub / deep", "b.swift", "a.swift", "file2.swift", "file10.swift"])
        assert(boundary.map(\.depth) == [0, 1, 2, 1, 0, 0])
        assert(TreeDisplayModel.pathRows([], section: "empty", collapsed: []).isEmpty)
        assert(TreeDisplayModel.pathRows([paths[0], paths[0]], section: "duplicates", collapsed: []).count == 2)
        var duplicate = paths[0]
        duplicate.status = .deleted
        let deduplicated = TreeDisplayModel.pathRows([paths[0], duplicate], section: "duplicates", collapsed: [])
        assert(deduplicated.last?.status == paths[0].status)

        let missing = fixture.appendingPathComponent("temporarily-missing")
        let readable = first.items
        try fm.moveItem(at: a, to: missing)
        await first.sync(root: a.path, backend: backend)
        assert(first.items == readable)
        try fm.moveItem(at: missing, to: a)

        let cycle = a.appendingPathComponent("loop")
        try fm.createSymbolicLink(at: cycle, withDestinationURL: cycle.deletingLastPathComponent())
        await first.sync(root: a.path, backend: backend)
        assert(first.items.count < 100)

        let cycleRoot = fixture.appendingPathComponent("cycle-root")
        try fm.createDirectory(at: cycleRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: cycleRoot.appendingPathComponent("link"), withDestinationURL: cycleRoot)
        await second.sync(root: cycleRoot.path, backend: backend)
        assert(second.items.count == 1 && second.items[0].compactPrefix.count <= 32)
        await second.toggle(second.items[0])
        assert(second.items.count <= 2)
        var endless = TreeDisplayModel.Traversal(root: "cycle", directoryDepthLimit: 32) { _ in false }
        while let directory = endless.nextDirectory() {
            endless.receive([TreeDisplayModel.Row(name: "link", path: directory + "/link", isDirectory: true)])
        }
        assert(endless.rows.count == 1 && endless.rows[0].compactPrefix.count == 32)

        var deepFiles: [TreeDisplayModel.Row] = []
        var deepParent = ""
        for index in 0..<64 {
            deepParent += "level\(index)/"
            deepFiles.append(TreeDisplayModel.Row(name: "file.swift", path: deepParent + "file.swift",
                                                  isDirectory: false))
        }
        let deepRows = TreeDisplayModel.pathRows(deepFiles, section: "deep", collapsed: [])
        assert(deepRows.filter { !$0.isDirectory }.count == 64)
        assert(deepRows.map(\.depth).max() == 64)
        let deepChain = TreeDisplayModel.pathRows([deepFiles.last!], section: "chain", collapsed: [])
        assert(deepChain.count == 2 && deepChain[0].compactPrefix.count == 63)

        let large = (0..<10_000).map { index in
            TreeDisplayModel.Row(name: "file\(index).swift", path: "large/chain/file\(index).swift",
                                 isDirectory: false)
        }
        let start = Date()
        let largeRows = TreeDisplayModel.pathRows(large, section: "large", collapsed: [])
        assert(largeRows.count == 10_001 && largeRows[0].displayName == "large / chain")
        print("PASS: shared Files/Git compaction, status semantics, section isolation, sorting, drafts, leaf rename, unreadable root, symlink bound, 10k files (\(Date().timeIntervalSince(start))s)")
    }
}
