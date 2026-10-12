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
        /// A single pane's content — the terminal, file, browser, or diff it
        /// holds.
        enum PaneContentSnapshot: Codable {
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

        struct PaneSnapshot: Codable {
            var content: PaneContentSnapshot
            /// Key into the sidecar terminal-history store for a session pane;
            /// nil for files, browsers, diffs, or when history restore is off.
            var historyKey: String?
        }

        /// The persisted recursive pane tree. Fractions belong to individual
        /// splits, so a child can be divided on either axis without affecting
        /// its siblings.
        indirect enum LayoutSnapshot: Codable {
            case pane(PaneSnapshot)
            case split(
                axis: PaneSplitAxis,
                fraction: Double,
                first: LayoutSnapshot,
                second: LayoutSnapshot
            )
        }

        /// One tab's recursive layout plus the focused leaf's tree-order
        /// position.
        struct TabSnapshot: Codable {
            var layout: LayoutSnapshot
            var focusedPaneIndex: Int
            /// User-assigned tab name; nil when the title is automatic.
            var customName: String?
            /// Position of the terminal this non-terminal tab was opened
            /// from in the project's flattened session list; nil without one.
            var contextSessionIndex: Int?

            init(
                layout: LayoutSnapshot, focusedPaneIndex: Int,
                customName: String? = nil, contextSessionIndex: Int? = nil
            ) {
                self.layout = layout
                self.focusedPaneIndex = focusedPaneIndex
                self.customName = customName
                self.contextSessionIndex = contextSessionIndex
            }

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

/// A second process of the same signed Debug app must not overwrite the
/// running Kero's window snapshots or stop its background SSH forwards.
enum KeroInstanceMode {
    static let isIsolated = ProcessInfo.processInfo.arguments.contains("--isolated-ui-test")
}

enum SessionStore {
    private static let key = "sessionSnapshot"
    private static let defaults: UserDefaults? = KeroInstanceMode.isIsolated
        ? UserDefaults(suiteName: AppIdentity.current.isolatedDefaultsSuite) : .standard

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
