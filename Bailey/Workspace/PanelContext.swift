import Foundation

nonisolated struct PanelContext {
    struct Identity: Hashable, Sendable {
        let project: UUID
        let workspace: String?
        let directory: String
    }

    let identity: Identity
    let backend: WorkspaceBackend

    var cwd: String { identity.directory }

    var scope: String { identity.workspace ?? "local" }
    var isRemote: Bool { identity.workspace != nil }

    @MainActor var connectionRevision: UInt64 {
        guard let workspace = identity.workspace, workspace.hasPrefix("ssh:") else { return 0 }
        return SSHHostWorkspaces.connectionRevision(for: String(workspace.dropFirst(4)))
    }

}
