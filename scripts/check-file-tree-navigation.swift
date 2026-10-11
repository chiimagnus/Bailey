// Regression check using the real FileTreeModel and local filesystem backend.
// From the repository root:
// xcrun swiftc -swift-version 5 -o build/check-file-tree-navigation \
//   kero/Workspace/WorkspaceBackend.swift kero/Workspace/FileTreeModel.swift \
//   scripts/check-file-tree-navigation.swift && build/check-file-tree-navigation

import Combine
import Foundation

// WorkspaceBackend.swift also extends these app-only types; no sessions run here.
struct RemoteConnection { let port: Int; let destination: String }
struct TerminalSessionLocation { let remoteConnection: RemoteConnection? }
struct TerminalSession { let location: TerminalSessionLocation }

@main
enum FileTreeNavigationCheck {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
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
        let original = nested.appendingPathComponent("a.swift").path
        try Data().write(to: URL(fileURLWithPath: original))
        try Data().write(to: other.appendingPathComponent("b.swift"))

        let backend = LocalWorkspaceBackend.shared
        let first = FileTreeModel()
        let second = FileTreeModel()
        await first.sync(root: a.path, backend: backend)
        let directory = first.items.first { $0.path == nested.deletingLastPathComponent().path }!
        await first.toggle(directory)
        let inner = first.items.first { $0.path == nested.path }!
        await first.toggle(inner)
        assert(first.items.contains { $0.path == original })

        await second.sync(root: b.path, backend: backend)
        await second.toggle(second.items.first { $0.path == other.path }!)
        await first.sync(root: a.path, backend: backend)
        assert(first.isExpanded(directory) && first.isExpanded(inner))
        assert(second.items.contains { $0.path == other.appendingPathComponent("b.swift").path })

        await first.sync(root: b.path, backend: backend)
        assert(!first.isExpanded(directory))
        await first.sync(root: a.path, backend: backend)
        assert(first.isExpanded(directory) && first.isExpanded(inner))

        await first.sync(root: a.path, backend: backend, scope: "ssh:fixture")
        assert(!first.isExpanded(directory))
        await first.sync(root: a.path, backend: backend, scope: "local")
        assert(first.isExpanded(directory) && first.isExpanded(inner))

        let added = nested.appendingPathComponent("new.swift").path
        try Data().write(to: URL(fileURLWithPath: added))
        await first.sync(root: a.path, backend: backend)
        assert(first.items.contains { $0.path == added })
        assert(first.isExpanded(directory) && first.isExpanded(inner))

        let emptyItem = first.items.first { $0.path == empty.path }!
        let before = first.items
        var notifications = 0
        let observation = first.objectWillChange.sink { notifications += 1 }
        await first.toggle(emptyItem)
        assert(first.isExpanded(emptyItem) && first.items == before)
        assert(notifications > 0)
        withExtendedLifetime(observation) {}
        print("PASS: project isolation, root return, scope separation, live refresh, empty folder notification")
    }
}
