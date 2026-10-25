import AppKit
import Darwin
import Foundation
import Observation

extension TerminalSession {
    /// Which workspace a tab opened from this session belongs to. Nil is this
    /// Mac, and two machines are different workspaces even at the same path —
    /// which is what keeps a remote `/etc/hosts` from reusing the local tab.
    var workspaceIdentity: String? {
        location.remoteConnection?.workspaceIdentity ?? initialWorkspace?.identity.workspace
    }
}

/// One long-lived terminal process rendered by one terminal surface. Normally
/// that process is the user's login shell; an SSH project launches its host
/// command instead. SwiftUI only reparents the same surface, so
/// PTY state, selection, and scrollback survive tab and docking changes.
///
/// The surface reports its lifecycle and input events through
/// ``TerminalBackendEvents`` so session logic stays independent of rendering.
@MainActor
@Observable
final class TerminalSession: NSObject, nonisolated Identifiable {
    nonisolated let id: UUID

    var title: String
    var workingDirectory: String? {
        didSet { if workingDirectory != oldValue { onSnapshotChange?() } }
    }
    @ObservationIgnored var onSnapshotChange: (() -> Void)?
    var hasExited = false
    private(set) var commandLifecycle = TerminalCommandLifecycle()
    /// Where this session's workspace tools look. Set by Bailey's `ssh` helper
    /// through the private authenticated handoff, never guessed from the foreground
    /// process: an ssh Bailey did not front cannot be followed.
    var location: WorkspaceLocation = .local
    private var initialWorkspace: PanelContext?
    private let isRemoteLaunch: Bool
    /// A fixed-SSH project has a remote launch target even before the private
    /// handoff has populated location. A dynamic SSH session becomes local
    /// again only after its actual ssh process has exited. A manually launched
    /// foreground ssh is remote input too, even without Bailey's handoff.
    var acceptsLocalFileDrop: Bool {
        !isRemoteLaunch && location.remoteConnection == nil
            && !hasUnmanagedSSH && !hasExited
    }
    let surface: any TerminalBackendSurface
    let overlayScrollbar = OverlayScrollbarView()
    /// Find-in-terminal state for this session's pane (⌘F).
    let find: TerminalFind
    @ObservationIgnored var onExited: ((TerminalSession) -> Void)?

    private static let persistedHistoryLineLimit = 500

    private let shellPath: String
    private let launchWorkingDirectory: String
    private let launchDirectoryURL: URL?
    private let shellPidFileURL: URL?
    @ObservationIgnored private var cachedShellPid: pid_t?
    @ObservationIgnored private var remoteMonitor: Task<Void, Never>?
    @ObservationIgnored private var lastHistorySnapshot: String?
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var commandExecutionStartedAtNanos: UInt64?
    init(
        initialDirectory: String? = nil,
        restoredHistory: String? = nil,
        launchCommand: String? = nil,
        initialWorkspace: PanelContext? = nil,
        initialInput: String? = nil,
        fixedSSHLaunch: Bool = false
    ) {
        let sessionID = UUID()
        let shellPath = LocalWorkspaceBackend.loginShell
        let directory = Self.validWorkingDirectory(initialDirectory)
        let artifacts = Self.makeLaunchArtifacts(restoredHistory: restoredHistory)
        let environment = Self.surfaceEnvironment(sessionID: sessionID, shellPath: shellPath)
        let script = Self.makeLaunchScript(
            shellPath: shellPath,
            pidFileURL: artifacts.pidFileURL,
            replayFileURL: artifacts.replayFileURL,
            launchCommand: launchCommand
        )
        let launch = TerminalLaunch(
            commandLine: "/bin/sh -c \(Self.shellQuote(script))",
            workingDirectory: directory,
            environment: environment,
            initialInput: initialInput
        )

        id = sessionID
        self.shellPath = shellPath
        self.initialWorkspace = initialWorkspace
        isRemoteLaunch = fixedSSHLaunch || initialWorkspace != nil
        launchWorkingDirectory = directory
        launchDirectoryURL = artifacts.directoryURL
        shellPidFileURL = artifacts.pidFileURL
        title = (shellPath as NSString).lastPathComponent

        let surface = BaileyTerminalView(launch: launch)
        self.surface = surface
        find = TerminalFind(surface: surface)
        lastHistorySnapshot = restoredHistory
        super.init()

        surface.events = self
        installOverlayScrollbar()
        applyTheme()
    }

    deinit {
        if let launchDirectoryURL {
            try? FileManager.default.removeItem(at: launchDirectoryURL)
        }
    }

    private func installOverlayScrollbar() {
        overlayScrollbar.alphaValue = 0
        overlayScrollbar.onScroll = { [weak self] position in
            self?.surface.scroll(toFraction: position)
        }
    }

    /// Reconfigures the surface in place when either appearance or terminal
    /// font settings change.
    func applyTheme() {
        surface.applyAppearance()
    }

    /// Stops the whole PTY job before releasing the surface. The backend's
    /// teardown owns the final reap; sending HUP first gives shells the same
    /// close signal they received before the backend migration.
    func terminate() {
        guard !hasExited, !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: true, notifyExit: false)
    }

    /// Keeps the session and surface alive until the child has either exited
    /// or been force-stopped. Detaching first can make a backend wait
    /// synchronously for a process that ignored SIGHUP.
    private func beginTeardown(processAlive: Bool, notifyExit: Bool) {
        // TerminalHostView normally clears these while dismantling, but close
        // teardown must not depend on a later SwiftUI reconciliation pass.
        // These callbacks originate on PanelContentView and capture this session.
        surface.setSurfaceVisible(false)
        surface.onBecomeFirstResponder = nil
        surface.openMenuTarget.onNewBrowserTab = nil
        surface.openMenuTarget.onNewFileTab = nil

        if processAlive {
            _ = shellPid // Cache it before `hasExited` changes.
            signalTerminalJob(SIGHUP)
        }

        Task { @MainActor [self] in
            if processAlive {
                // Give well-behaved shells a moment to unwind, then guarantee
                // surface teardown cannot wait indefinitely.
                try? await Task.sleep(for: .milliseconds(120))
                signalTerminalJob(SIGKILL)
            } else {
                // Avoid freeing the surface reentrantly from the backend's
                // process-close callback.
                await Task.yield()
            }
            surface.detach()
            hasExited = true
            removeLaunchArtifacts()
            if notifyExit { onExited?(self) }
        }
    }

    private func signalTerminalJob(_ signal: Int32) {
        var pids = Set<pid_t>()
        if let shellPid { pids.insert(shellPid) }
        if let foreground = surface.foregroundPid, foreground > 0 {
            pids.insert(foreground)
        }
        for pid in pids where pid > 1 {
            // Interactive shells and their foreground jobs normally lead
            // distinct process groups. Signal the group, then the leader as a
            // fallback for an unusual launch configuration.
            _ = Darwin.kill(-pid, signal)
            _ = Darwin.kill(pid, signal)
        }
    }

    private func removeLaunchArtifacts() {
        endRemoteConnection(reason: "terminal closed")
        BaileySSHService.shared.revokeTerminal(id: id)
        guard let launchDirectoryURL else { return }
        try? FileManager.default.removeItem(at: launchDirectoryURL)
    }

    // MARK: - Remote workspace

    /// Adopts the connection Bailey's `ssh` helper just announced and starts
    /// watching it. Exactly one connection per session: an `ssh` typed from
    /// inside an already-remote shell is nested and is not followed.
    @discardableResult
    func beginRemoteConnection(_ connection: RemoteConnection) -> Bool {
        // A live connection means this ssh was typed from inside the remote
        // shell. That is nested and Bailey does not follow it. A connection that
        // has already finished is simply the previous one, and the session is
        // free to go remote again.
        if let existing = location.remoteConnection, existing.state != .disconnected {
            NSLog(
                "bailey: ignoring nested ssh in terminal %@ (already remote)",
                id.uuidString
            )
            return false
        }
        endRemoteConnection(reason: "replaced by a new connection")
        if let initialWorkspace { connection.workingDirectory = initialWorkspace.cwd }
        initialWorkspace = nil
        location = .remote(connection)
        remoteMonitor = Task { [weak self] in
            await self?.watchRemoteConnection(connection)
        }
        return true
    }

    func endRemoteConnection(reason: String) {
        remoteMonitor?.cancel()
        remoteMonitor = nil
        guard let connection = location.remoteConnection else { return }
        connection.markDisconnected(reason: reason)
    }

    /// The pane returns to the local machine only when the ssh process itself
    /// is gone, which is what `exit` does. A connection that drops while ssh is
    /// still running keeps the pane remote and disconnected on purpose: falling
    /// back to local paths under a remote heading is the one outcome to avoid.
    private func finishRemoteProcess(_ connection: RemoteConnection, reason: String) {
        connection.markDisconnected(reason: reason)
        if !isRemoteLaunch { location = .local }
    }

    /// One check a second. While connecting, only the ssh process going away
    /// is a failure: the control socket does not exist until authentication
    /// finishes, and a password or a hardware key can take a while.
    private func watchRemoteConnection(_ connection: RemoteConnection) async {
        var tick = 0
        var consecutiveFailures = 0

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }

            // The only way back to the local machine is the ssh process
            // ending, which is what `exit` does.
            guard connection.isSSHProcessAlive else {
                finishRemoteProcess(connection, reason: "ssh process exited")
                return
            }
            // The master removes its socket when it goes; cheaper than asking.
            guard connection.controlSocketExists else {
                connection.markDisconnected(reason: "control socket removed")
                continue
            }

            if connection.state == .connecting {
                guard await connection.check() else { continue }
                connection.markConnected()
                // Probe at once rather than waiting a tick: the pane only
                // switches to the remote once a directory is known.
                await probeRemoteWorkingDirectory(connection)
                continue
            }

            tick += 1
            // Every 2 s while healthy, but every second once a probe has
            // failed: the second opinion that confirms a drop should not wait
            // out a full cycle when the pane is already showing stale state.
            guard tick.isMultiple(of: 2) || consecutiveFailures > 0 else { continue }

            // One real round trip every 2 s. This is the liveness test, not
            // `-O check`: the multiplexing master runs on this Mac and keeps
            // answering while the network is down, so only a command that
            // reaches the other machine can tell a live link from a dead one.
            if await probeRemoteWorkingDirectory(connection) {
                consecutiveFailures = 0
                if connection.state == .disconnected {
                    connection.markConnected()
                }
                continue
            }

            consecutiveFailures += 1
            // Two in a row before saying so: a single timeout can be a busy
            // remote or a slow link, and a pane that flickers is worse than
            // one that takes a few seconds to tell the truth.
            if consecutiveFailures >= 2, connection.state == .connected {
                connection.markDisconnected(reason: "no reply from the remote machine")
            }
        }
    }

    /// Identifies the remote shell process to read its directory over the
    /// shared channel. Returns whether the round trip succeeded, which tells
    /// a live connection from a dropped one.
    ///
    /// A miss keeps the last known values: the lookup can fail transiently
    /// while a command is running, and the pane must keep describing the
    /// remote machine rather than falling back to this Mac's paths.
    @discardableResult
    private func probeRemoteWorkingDirectory(
        _ connection: RemoteConnection
    ) async -> Bool {
        let found: (pid: pid_t, directory: String)?
        do {
            // Only a thrown error means the round trip failed. `try?` would
            // flatten "the remote answered, the shell was not found" into the
            // same nil as "the remote never answered", and the pane would
            // report a drop that had not happened.
            found = try await connection.livenessBackend.remoteWorkingDirectory(
                terminalTag: id.uuidString
            )
        } catch {
            return false
        }
        guard let found, !found.directory.isEmpty else { return true }
        if connection.workingDirectory != found.directory {
            connection.workingDirectory = found.directory
        }
        return true
    }

    /// Best-effort live shell directory: OSC 7 first, kernel process metadata
    /// second, then the directory used to launch this session.
    var currentDirectoryPath: String {
        if let dir = workingDirectory {
            if let url = URL(string: dir), url.isFileURL { return url.path }
            if dir.hasPrefix("/") { return dir }
        }
        if let shellPid, let path = processWorkingDirectory(pid: shellPid) {
            return path
        }
        return launchWorkingDirectory
    }

    /// Working directory of the terminal's foreground job, when that job is
    /// something other than the shell itself. Coding agents change their own
    /// process directory when they move to another checkout — Claude Code's
    /// worktree switch is a `chdir` inside the running `claude` process — and
    /// the shell never moves, so no OSC 7 arrives and `currentDirectoryPath`
    /// keeps describing the old tree. This is deliberately a separate fact:
    /// `currentDirectoryPath` must stay true to the shell.
    var foregroundDirectoryPath: String? {
        // While the session is remote this would be the ssh client's own local
        // directory, which means nothing on the other machine.
        guard location.remoteConnection == nil else { return nil }
        guard let foreground = surface.foregroundPid, foreground > 0,
              foreground != shellPid
        else { return nil }
        return processWorkingDirectory(pid: foreground)
    }

    func sendCommand(_ text: String) {
        surface.sendText(text)
    }

    /// Clears the emulator's visible screen and scrollback, then asks the
    /// foreground shell to repaint its prompt at the top.
    func clear() {
        surface.clearScreen()
    }

    /// Styled VT snapshot used by the existing sidecar history store. A
    /// scrollback/PID heuristic keeps a full-screen alternate buffer from
    /// replacing the last saved shell scrollback in normal shell/TUI use.
    func serializedHistory(captureLive: Bool) -> String? {
        guard AppSettings.shared.restoreTerminalHistory else { return nil }
        guard captureLive else { return lastHistorySnapshot }

        let rootShellIsForeground = shellPid != nil
            && surface.foregroundPid == shellPid
        if !rootShellIsForeground,
           !TerminalHistorySerializer.hasPrimaryScrollback(surface) {
            // A primary screen with no rows above the viewport and an
            // alternate screen both have no scrollback export. The root shell
            // is foreground only in the former case; a TUI owns its own
            // foreground process group in the latter.
            return lastHistorySnapshot
        }
        switch TerminalHistorySerializer.capture(
            from: surface, maxLines: Self.persistedHistoryLineLimit
        ) {
        case .captured(let snapshot):
            lastHistorySnapshot = snapshot
            return snapshot
        case .failed:
            return lastHistorySnapshot
        }
    }

    /// PID of the root terminal process. The launch shim records its own PID
    /// before `exec`, so this remains stable while a shell's foreground PID
    /// moves to child jobs and back.
    var shellPid: pid_t? {
        if let cachedShellPid, cachedShellPid > 0 { return cachedShellPid }
        guard !hasExited, let shellPidFileURL,
              let text = try? String(contentsOf: shellPidFileURL, encoding: .utf8),
              let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else { return nil }
        cachedShellPid = value
        return value
    }

    /// The terminal's own working directory on its current machine.
    /// Project Files and Git instead use the project's fixed root.
    var panelDirectoryPath: String {
        if let initialWorkspace { return initialWorkspace.cwd }
        guard let directory = connectedRemote?.workingDirectory else {
            return currentDirectoryPath
        }
        return directory
    }

    /// A manually launched ssh cannot accept Finder's local file paths.
    /// Also detect `exec ssh`, which may retain the shell PID.
    private var hasUnmanagedSSH: Bool {
        guard !isRemoteLaunch else { return false }
        for candidate in [surface.foregroundPid, shellPid] {
            guard let pid = candidate, pid > 0,
                  let path = processExecutablePath(pid: pid),
                  (path as NSString).lastPathComponent == "ssh"
            else { continue }
            return true
        }
        return false
    }

    /// The remote this session is working on. Both the backend and the panel
    /// path read this, so the pane can never pair a remote backend with a
    /// local path or the reverse.
    ///
    /// Deliberately not restricted to `.connected`. A dropped connection keeps
    /// describing the remote machine with its last known directory: showing
    /// this Mac's files under a remote heading is the one outcome to avoid,
    /// and remote work simply fails while the link is down.
    private var connectedRemote: RemoteConnection? {
        guard let connection = location.remoteConnection,
              connection.workingDirectory != nil
        else { return nil }
        return connection
    }

    // MARK: - Launch

    private static func surfaceEnvironment(
        sessionID: UUID,
        shellPath: String
    ) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
        ]
        environment.merge(
            BaileySSHService.shared.terminalEnvironment(for: sessionID),
            uniquingKeysWith: { _, sshValue in sshValue }
        )
        environment.merge(
            zshIntegrationEnvironment(shellPath: shellPath),
            uniquingKeysWith: { _, integrationValue in integrationValue }
        )
        // Locale belongs to the user's shell environment. Bailey's app language
        // must never synthesize or override LANG/LC_* for terminal processes.
        return environment
    }

    /// Points zsh at Bailey's own startup directory.
    ///
    /// The bundled `.zshenv` restores the user's `ZDOTDIR` and sources their
    /// files before doing anything, so their shell starts exactly as it would
    /// otherwise; it then adds an interactive `ssh` function that routes
    /// through Bailey's helper.
    ///
    /// This replaces shadowing `ssh` on `PATH`, which cannot work on macOS:
    /// `/etc/zprofile` runs `path_helper`, which rebuilds `PATH` with the
    /// system directories first and leaves anything Bailey prepended behind
    /// `/usr/bin`. A shell function is also the better tool, because it
    /// applies only to what the user types and never to scripts or agents.
    private static func zshIntegrationEnvironment(
        shellPath: String
    ) -> [String: String] {
        guard (shellPath as NSString).lastPathComponent == "zsh",
              let resources = Bundle.main.resourceURL,
              let executables = Bundle.main.executableURL?.deletingLastPathComponent()
        else { return [:] }

        let directory = resources
            .appendingPathComponent("shell-integration/zsh", isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".zshenv").path
        ) else { return [:] }

        var environment = [
            "ZDOTDIR": directory.path,
            // argv[0] must still be `ssh`, so this names the symlink rather
            // than the app binary it points at.
            "BAILEY_SSH_HELPER": executables.appendingPathComponent("ssh").path,
        ]
        // Only set when the user had one, so the bundled file can tell
        // "restore this" from "there was none".
        if let existing = ProcessInfo.processInfo.environment["ZDOTDIR"],
           !existing.isEmpty {
            environment["BAILEY_ZSH_ZDOTDIR"] = existing
        }
        return environment
    }

    private struct LaunchArtifacts {
        let directoryURL: URL?
        let pidFileURL: URL?
        let replayFileURL: URL?
    }

    private static func makeLaunchArtifacts(restoredHistory: String?) -> LaunchArtifacts {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("bailey-terminal-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let pidFile = directory.appendingPathComponent("shell.pid")
            var replayFile: URL?
            if AppSettings.shared.restoreTerminalHistory,
               let restoredHistory,
               !restoredHistory.isEmpty {
                let file = directory.appendingPathComponent("history.vt")
                let separator = restoredHistory.hasSuffix("\n") ? "" : "\r\n"
                let contents = restoredHistory + separator
                    + TerminalHistorySerializer.restoredBanner() + "\r\n"
                try Data(contents.utf8).write(to: file, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path
                )
                replayFile = file
            }
            return LaunchArtifacts(
                directoryURL: directory,
                pidFileURL: pidFile,
                replayFileURL: replayFile
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            NSLog("bailey: failed to prepare terminal launch files: \(error)")
            return LaunchArtifacts(directoryURL: nil, pidFileURL: nil, replayFileURL: nil)
        }
    }

    /// The `sh` script every pane starts with: record the process PID, replay
    /// any restored scrollback, advertise the emulator, then exec the login shell.
    private static func makeLaunchScript(
        shellPath: String,
        pidFileURL: URL?,
        replayFileURL: URL?,
        launchCommand: String? = nil
    ) -> String {
        var commands: [String] = []
        if let pidFileURL {
            // The PID file is the only thing this script creates, so the
            // tightened mask stays inside a subshell: `umask` outlives the
            // `exec` below, and a terminal that leaves the user's shell at 077
            // silently makes every file they create private. `$$` keeps
            // expanding to this shell's PID inside the subshell — the same PID
            // `exec` hands to the shell itself.
            commands.append(
                "(umask 077; printf '%s\\n' \"$$\" > \(shellQuote(pidFileURL.path)))"
            )
        }
        if let replayFileURL {
            let path = shellQuote(replayFileURL.path)
            commands.append("if [ -r \(path) ]; then /bin/cat \(path); /bin/rm -f \(path); fi")
        }
        // Expose the protocols implemented by Bailey's embedded Ghostty surface.
        commands.append("export BAILEY_TERM='ghostty'")
        commands.append("export TERM_PROGRAM='ghostty'")
        commands.append("export TERM_PROGRAM_VERSION='1.3.2-dev'")
        commands.append(launchCommand ?? "exec \(shellQuote(shellPath)) -l")
        // Ghostty's macOS launcher prepends `exec -l` to a shell command.
        // Keeping the setup as one compound command means `exec -l` does not
        // stop after the first shell builtin.
        return commands.joined(separator: "; ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validWorkingDirectory(_ requested: String?) -> String {
        var isDirectory: ObjCBool = false
        if let requested,
           FileManager.default.fileExists(atPath: requested, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return requested
        }
        return NSHomeDirectory()
    }

}

// MARK: - Terminal surface callbacks

extension TerminalSession: TerminalBackendEvents {
    func terminalDidChangeTitle(_ title: String) {
        guard !title.isEmpty else { return }
        self.title = title
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        workingDirectory = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).absoluteString : path
    }

    func terminalDidRingBell() {
        NSSound.beep()
        guard !surface.hasEffectiveTerminalFocus else { return }
        TerminalNotificationService.shared.post(
            message: String(localized: "Terminal bell", table: "Terminal"),
            sessionID: id
        )
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func terminalDidReportShellIntegration(_ event: TerminalShellIntegrationEvent) {
        var lifecycle = commandLifecycle
        switch event {
        case .promptStart:
            lifecycle.phase = .prompt
        case .commandStart:
            lifecycle.phase = .input
        case .commandExecuting:
            lifecycle.phase = .executing
            commandExecutionStartedAtNanos = DispatchTime.now().uptimeNanoseconds
        case let .commandFinished(exitCode, reportedDuration):
            let measuredDuration = commandExecutionStartedAtNanos.flatMap { started in
                let now = DispatchTime.now().uptimeNanoseconds
                return now >= started ? now - started : nil
            }
            lifecycle.phase = .idle
            lifecycle.lastExitCode = exitCode
            lifecycle.lastDurationNanos = reportedDuration ?? measuredDuration
            lifecycle.completionSequence &+= 1
            commandExecutionStartedAtNanos = nil
        }
        commandLifecycle = lifecycle
    }

    func terminalDidClose(processAlive: Bool) {
        guard !isTerminating else { return }
        isTerminating = true
        beginTeardown(processAlive: processAlive, notifyExit: true)
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        let message = body.isEmpty ? title : body
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        TerminalNotificationService.shared.post(
            message: message, sessionID: id, forwardToBark: true
        )
    }

    func terminalDidRequestOpenURL(_ value: String) {
        guard let target = terminalLinkTarget(for: value) else { return }
        switch target {
        case .file(let fileURL):
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        case .url(let url):
            NSWorkspace.shared.open(url)
        }
    }

    /// Classifies a detected terminal link only after proving a local path
    /// exists or a non-file URL has a scheme. Context menus and Command-click
    /// use this same answer, so neither offers an action it cannot perform.
    func terminalLinkTarget(for value: String) -> TerminalLinkTarget? {
        if let fileURL = existingFileURL(from: value) {
            return .file(fileURL)
        }
        guard let url = URL(string: value),
              url.scheme != nil,
              !url.isFileURL
        else { return nil }
        return .url(url)
    }

    /// Resolves terminal links the way the shell would: `file:` URLs are
    /// already absolute, `~` belongs to the current user, and other paths are
    /// relative to this pane's live working directory. Diagnostics commonly
    /// append `:line[:column]`, so try the literal path before peeling those
    /// numeric locations off.
    private func existingFileURL(from value: String) -> URL? {
        let candidate: URL
        if let url = URL(string: value), url.scheme != nil {
            guard url.isFileURL else { return nil }
            candidate = url
        } else {
            let decoded = value.removingPercentEncoding ?? value
            let expanded = (decoded as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                candidate = URL(fileURLWithPath: expanded)
            } else {
                let basePath = foregroundDirectoryPath ?? currentDirectoryPath
                candidate = URL(
                    fileURLWithPath: expanded,
                    relativeTo: URL(fileURLWithPath: basePath, isDirectory: true)
                )
            }
        }

        var url = candidate.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            let strippedPath = url.path.replacingOccurrences(
                of: #":\d+$"#,
                with: "",
                options: .regularExpression
            )
            guard strippedPath != url.path else { return nil }
            url = URL(fileURLWithPath: strippedPath).standardizedFileURL
        }
    }

    func terminalDidScroll(_ position: TerminalScrollPosition) {
        overlayScrollbar.update(
            position: position.position,
            proportion: position.proportion,
            active: position.isScrollable
        )
    }

    func terminalDidBeginFind(needle: String) {
        find.started(needle: needle)
    }

    func terminalDidEndFind() {
        find.ended()
    }

    func terminalDidUpdateFindTotal(_ total: Int?) {
        find.update(total: total)
    }

    func terminalDidUpdateFindSelected(_ selected: Int?) {
        find.update(selected: selected)
    }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardRequest) {
        guard let window = surface.window else {
            request.deny()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request.kind {
        case .unsafePaste:
            alert.messageText = String(localized: "Warning: Potentially Unsafe Paste", table: "Terminal")
            alert.informativeText =
                String(localized: "Pasting this text to the terminal may be dangerous because it looks like one or more commands may execute.", table: "Terminal")
        case .programRead:
            alert.messageText = String(localized: "Authorize Clipboard Access", table: "Terminal")
            alert.informativeText =
                String(localized: "A program is attempting to read from the clipboard. The current clipboard contents are shown below.", table: "Terminal")
        }
        alert.accessoryView = Self.clipboardPreview(request.contents)
        alert.addButton(withTitle: request.kind == .unsafePaste
            ? String(localized: "Paste", table: "Terminal")
            : String(localized: "Allow", table: "Terminal"))
        let cancel = alert.addButton(
            withTitle: request.kind == .unsafePaste
                ? String(localized: "Cancel", table: "Terminal")
                : String(localized: "Deny", table: "Terminal")
        )
        cancel.keyEquivalent = "\u{1b}"

        Task { @MainActor in
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                request.approve()
            } else {
                request.deny()
            }
        }
    }

    /// Bounded, read-only preview of the text under decision, mirroring
    /// the preview area in Ghostty's own confirmation dialog.
    private static func clipboardPreview(_ contents: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        // A pathological clipboard can be arbitrarily large; the decision
        // only needs a glimpse.
        text.string = String(contents.prefix(4096))
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }
}
