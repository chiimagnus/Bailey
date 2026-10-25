import Foundation

nonisolated struct PanelContext {
    enum RootSource: Equatable, Sendable {
        case pinned
        case shell
        case foreground(isWorktree: Bool)
    }

    enum Identity: Hashable, Sendable {
        case pinned(project: UUID, workspace: String?, directory: String)
        case automatic(
            project: UUID, workspace: String?, directory: String, foreground: String?,
            session: UUID, connection: UUID?, state: RemoteConnection.State?
        )

        var workspace: String? {
            switch self {
            case .pinned(_, let workspace, _), .automatic(_, let workspace, _, _, _, _, _):
                workspace
            }
        }
    }

    let identity: Identity
    let backend: WorkspaceBackend

    var cwd: String {
        switch identity {
        case .pinned(_, _, let directory), .automatic(_, _, let directory, _, _, _, _):
            directory
        }
    }

    var foreground: String? {
        guard case .automatic(_, _, _, let foreground, _, _, _) = identity else { return nil }
        return foreground
    }

    var scope: String { identity.workspace ?? "local" }
    var isRemote: Bool { identity.workspace != nil }

    @MainActor var connectionRevision: UInt64 {
        guard let workspace = identity.workspace, workspace.hasPrefix("ssh:") else { return 0 }
        return SSHHostWorkspaces.connectionRevision(for: String(workspace.dropFirst(4)))
    }

    func resolvedRoot() async throws -> (root: String, source: RootSource) {
        if case .pinned = identity { return (cwd, .pinned) }
        let shellRoot = try await backend.gitRoot(containing: cwd) ?? cwd
        if let foreground,
           let foregroundRoot = try await backend.gitRoot(containing: foreground),
           foregroundRoot != shellRoot {
            let isWorktree = try await backend.isLinkedWorktree(foregroundRoot)
            return (foregroundRoot, .foreground(isWorktree: isWorktree))
        }
        return (shellRoot, .shell)
    }
}
