//
//  SessionStore.swift
//  kero
//

import Foundation

/// Snapshot of open projects and tabs, saved so a relaunch restores the
/// previous layout. Terminal sessions restore as fresh shells started in
/// their last known working directory — with their previous scrollback
/// replayed above the prompt when the "Restore session history" setting is on
/// (see `historyKey` and `TerminalHistoryStore`); file and diff panes reload
/// from disk.
struct SessionSnapshot: Codable {
    struct ProjectSnapshot: Codable {
        /// A tab's content — the terminal, file, browser, or diff it
        /// holds.
        enum ContentSnapshot: Codable {
            case session(workingDirectory: String)
            case file(path: String, editorState: EditorState?)
            case browser(url: String?)
            case diff(repoRoot: String, path: String, staged: Bool, untracked: Bool, origPath: String?)
            case commitDiff(
                repoRoot: String,
                path: String,
                commitHash: String,
                parentHash: String?,
                status: String,
                origPath: String?
            )
        }

        struct TabSnapshot: Codable {
            var content: ContentSnapshot
            var historyKey: String?
            var customName: String?
            var contextSessionIndex: Int?
        }

        var customName: String?
        /// User-pinned project directory; nil when the directory is
        /// automatic (the closest git repository, never persisted).
        var customDirectory: String?
        var sshHost: String?
        var pinnedFile: String?
        var tabs: [TabSnapshot]
        var selectedTabIndex: Int?
        var dock: DockSavedNode
    }

    var projects: [ProjectSnapshot]
    var selectedProjectIndex: Int?
}

/// Persisted top level: one `SessionSnapshot` per open window, in
/// window-creation order.
struct AppSnapshot: Codable {
    var windows: [SessionSnapshot]
}

/// Explicitly isolated secondary instances must not overwrite the running
/// Kero window snapshot or start its saved background forwards.
nonisolated enum KeroInstanceMode {
    static let isIsolated = ProcessInfo.processInfo.arguments.contains("--isolated-ui-test")
}

enum SessionStore {
    private static let key = "workspaceSnapshot"
    private static let defaults: UserDefaults? = KeroInstanceMode.isIsolated
        ? UserDefaults(suiteName: AppIdentity.bundleIdentifier + ".isolated-ui-test") : .standard

    static func save(_ windows: [SessionSnapshot]) {
        guard let data = try? JSONEncoder().encode(AppSnapshot(windows: windows)) else { return }
        defaults?.set(data, forKey: key)
    }

    static func load() -> [SessionSnapshot] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        if let app = try? JSONDecoder().decode(AppSnapshot.self, from: data) {
            return app.windows
        }
        return []
    }
}
