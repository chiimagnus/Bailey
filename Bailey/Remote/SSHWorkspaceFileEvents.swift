import Foundation
import Observation

/// One temporary SSH Files subscription per project, shared by visible Files panels.
@MainActor
@Observable
final class SSHWorkspaceFileEvents {
    private struct Target: Equatable {
        let host: String
        let root: String
        let identity: PanelContext.Identity
        let revision: UInt64
    }

    private(set) var healthy = false
    @ObservationIgnored private var members: Set<UUID> = []
    @ObservationIgnored private var current: Target?
    @ObservationIgnored private weak var owner: Project?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    func subscribe(id: UUID, project: Project, host: String, root: String, context: PanelContext) {
        let target = Target(
            host: host, root: root, identity: context.identity,
            revision: context.connectionRevision
        )
        members.insert(id)
        guard current != target || worker == nil else { return }
        worker?.cancel()
        generation &+= 1
        let token = generation
        healthy = false
        current = target
        owner = project
        worker = Task { [weak self] in
            await self?.run(target: target, backend: context.backend, token: token)
        }
    }

    func unsubscribe(id: UUID) {
        members.remove(id)
        guard members.isEmpty else { return }
        worker?.cancel()
        generation &+= 1
        worker = nil
        current = nil
        owner = nil
        healthy = false
    }

    private func run(target: Target, backend: WorkspaceBackend, token: UInt64) async {
        defer {
            if generation == token { healthy = false; worker = nil }
        }
        while !Task.isCancelled && generation == token && current == target {
            do {
                // FileSystemWatcher does not follow a symlinked root.
                // Keep polling instead of claiming this scope is covered.
                guard let rootStat = try await backend.stat(path: target.root),
                      generation == token, !Task.isCancelled,
                      rootStat.isDirectory, !rootStat.isSymlink else { return }
                let result = try await backend.run(
                    argv: ["cygpath", "-w", target.root], cwd: nil,
                    env: nil, stdin: nil, timeout: 10
                )
                guard generation == token, !Task.isCancelled,
                      result.status == 0 else { return } // Unsupported: keep polling.
                let windowsRoot = String(decoding: result.stdout, as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                guard !windowsRoot.isEmpty else { return }
                let subscription = SSHWindowsFileEvents.subscribe(
                    host: target.host, windowsRoot: windowsRoot
                )
                var cleanLeaseExpiry = false
                await withTaskCancellationHandler {
                    observe: for await event in subscription.events {
                        guard !Task.isCancelled, generation == token, current == target,
                              let project = owner, !members.isEmpty else { break observe }
                        switch event {
                        case .ready:
                            // The new watcher starts before re-reading disk, closing
                            // the gap between subscription and its first snapshot.
                            guard (try? await backend.list(directory: target.root)) != nil,
                                  generation == token, !Task.isCancelled else {
                                break observe
                            }
                            let synced = await project.syncFiles(isCurrent: {
                                project.matchesPanelTarget(target.identity)
                                    && project.panelContext?.connectionRevision == target.revision
                            })
                            guard generation == token, !Task.isCancelled else { break observe }
                            guard synced != nil else {
                                healthy = false
                                break observe
                            }
                            healthy = true
                        case .dirty:
                            guard healthy else { break observe }
                            let synced = await project.syncFiles(isCurrent: {
                                project.matchesPanelTarget(target.identity)
                                    && project.panelContext?.connectionRevision == target.revision
                            })
                            guard generation == token, !Task.isCancelled else { break observe }
                            guard synced != nil else {
                                healthy = false
                                break observe
                            }
                        case .lost:
                            healthy = false
                            break observe
                        case .ended:
                            healthy = false
                            cleanLeaseExpiry = true
                            break observe
                        }
                    }
                } onCancel: {
                    subscription.cancel()
                }
                subscription.cancel()
                guard generation == token else { return }
                healthy = false
                if !cleanLeaseExpiry {
                    try await Task.sleep(for: .seconds(15)) // The 2-second poll remains active.
                }
            } catch {
                guard generation == token else { return }
                healthy = false
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
            }
        }
    }
}
