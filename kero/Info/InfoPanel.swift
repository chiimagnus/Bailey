import AppKit
import SwiftUI

// MARK: - Info panel

/// Session dashboard: working directory (with reveal/open/copy actions),
/// processes running under the shell, and ports they are listening on.
struct InfoPanel: View {
    @ObservedObject var model: SessionInfoModel
    @ObservedObject private var themeChanges = Theme.changes
    let session: TerminalSession?
    let sshHost: String?
    /// The remote session's open forwards. Nil while local, where a listening
    /// port is already reachable on this Mac.
    var forwards: PortForwardController?

    @State private var currentDirectoryCollapsed = false
    @State private var projectDirectoryCollapsed = false
    @State private var processesCollapsed = false
    @State private var portsCollapsed = false

    private static let vsCodeURL = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")

    /// Whether these directories live on another machine. Finder and VS Code
    /// would otherwise open whatever sits at the same path locally.
    private var isRemote: Bool {
        sshHost != nil || session?.location.remoteConnection != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    currentDirectorySection
                    projectDirectorySection
                    processesSection
                    if let forwards {
                        ObservedPortForwards(controller: forwards) { portsSection(localPorts: $0) }
                    } else {
                        portsSection(localPorts: [:])
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .panelFont(size: 11, weight: .medium)
                .foregroundStyle(Color(nsColor: Theme.accent))
            PanelHeader(
                title: session == nil
                    ? String(localized: "Project", table: "Sidebar")
                    : (model.shellName.isEmpty
                        ? String(localized: "Session", table: "Sidebar") : model.shellName),
                subtitle: model.shellPid > 0 ? "pid \(String(model.shellPid))" : nil
            )
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .panelFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Refresh", table: "Sidebar"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: Directories

    /// Hidden while the shell sits at the project root — it earns its row
    /// once the cwd diverges from the directory the panels anchor to.
    @ViewBuilder
    private var currentDirectorySection: some View {
        if model.rootPath != model.projectRootPath {
            PanelSectionHeader(
                title: String(localized: "CURRENT DIRECTORY", table: "Sidebar"), count: 0,
                isCollapsed: $currentDirectoryCollapsed, actions: []
            )
            if !currentDirectoryCollapsed {
                directoryGroup(path: model.rootPath)
            }
        }
    }

    @ViewBuilder
    private var projectDirectorySection: some View {
        if !model.projectRootPath.isEmpty {
            PanelSectionHeader(
                title: projectDirectoryTitle,
                count: 0,
                isCollapsed: $projectDirectoryCollapsed, actions: [],
                helpText: String(localized: "Files and Git anchor to this directory. When automatic, it follows the closest Git repository containing the shell’s current directory, or the one the terminal’s foreground job moved to — a coding agent that switched to its own worktree. A directory set manually from the project’s context menu is always used as-is.", table: "Sidebar")
            )
            if !projectDirectoryCollapsed {
                directoryGroup(path: model.projectRootPath)
            }
        }
    }

    /// Names the rule behind the project directory: a root taken from the
    /// foreground job says so rather than passing itself off as the shell's
    /// own repository.
    private var projectDirectoryTitle: String {
        switch model.projectRootSource {
        case .pinned:
            return String(localized: "PROJECT DIRECTORY", table: "Sidebar")
        case .shell:
            return String(localized: "PROJECT DIRECTORY (AUTO)", table: "Sidebar")
        case .foreground(let isWorktree):
            return isWorktree
                ? String(localized: "PROJECT DIRECTORY (WORKTREE)", table: "Sidebar")
                : String(localized: "PROJECT DIRECTORY (JOB)", table: "Sidebar")
        }
    }

    /// Path line plus Finder / VS Code / Copy actions, shared by both
    /// directory sections.
    private func directoryGroup(path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: path)
                .panelFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(path)
                .contextMenu {
                    Button(String(localized: "Copy Path", table: "Sidebar")) { copyPath(path) }
                }

            HStack(spacing: 4) {
                if !isRemote {
                    actionButton("Finder", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)]
                        )
                    }
                }
                if !isRemote, let vsCode = Self.vsCodeURL {
                    actionButton("VS Code", systemImage: "chevron.left.forwardslash.chevron.right") {
                        NSWorkspace.shared.open(
                            [URL(fileURLWithPath: path)],
                            withApplicationAt: vsCode,
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    }
                }
                actionButton(String(localized: "Copy", table: "Sidebar"), systemImage: "doc.on.doc") {
                    copyPath(path)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    /// Locally a listening port is already reachable here. On a remote it is
    /// not, so "open" means forward it to a loopback port first and open that.
    /// Never automatic: this only runs because someone clicked the row.
    private func openPort(_ port: SessionInfoModel.PortItem) {
        guard isRemote else {
            if let url = port.url { NSWorkspace.shared.open(url) }
            return
        }
        withForwardedURL(port) { NSWorkspace.shared.open($0) }
    }

    private func copyPortURL(_ port: SessionInfoModel.PortItem) {
        guard isRemote else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("http://localhost:\(port.port)", forType: .string)
            return
        }
        withForwardedURL(port) { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    /// Forwards `port` if it is not already, then hands over the loopback URL
    /// it is reachable on. Asking twice reuses the same forward.
    private func withForwardedURL(
        _ port: SessionInfoModel.PortItem, then use: @escaping (URL) -> Void
    ) {
        guard let forwards else { return }
        Task {
            do {
                let localPort = try await forwards.forward(remotePort: port.port)
                guard let url = URL(string: "http://127.0.0.1:\(localPort)/") else { return }
                use(url)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(
                    localized: "Couldn’t forward port \(port.port).", table: "Sidebar",
                    comment: "Remote port forward failure. The placeholder is a port number."
                )
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func actionButton(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .panelFont(size: 9, weight: .medium)
                Text(verbatim: title)
                    .panelFont(size: 10, weight: .medium)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(systemImage == "doc.on.doc"
            ? String(localized: "Copy Path", table: "Sidebar")
            : String(localized: "Open in \(title)", table: "Sidebar"))
    }

    // MARK: Processes

    @ViewBuilder
    private var processesSection: some View {
        PanelSectionHeader(
            title: String(localized: "PROCESSES", table: "Sidebar"),
            count: model.processes.count,
            isCollapsed: $processesCollapsed,
            actions: []
        )
        if !processesCollapsed {
            if model.processes.isEmpty {
                emptyRow(String(localized: "No running processes", table: "Sidebar"))
            } else {
                ForEach(model.processes) { process in
                    InfoProcessRow(process: process) { force in
                        Task { await model.kill(process.pid, force: force) }
                    }
                }
            }
        }
    }

    // MARK: Ports

    @ViewBuilder
    private func portsSection(localPorts: [Int: Int]) -> some View {
        PanelSectionHeader(
            title: String(localized: "PORTS", table: "Sidebar"),
            count: model.ports.count,
            isCollapsed: $portsCollapsed,
            actions: []
        )
        if !portsCollapsed {
            if model.ports.isEmpty {
                emptyRow(String(localized: "No listening ports", table: "Sidebar"))
            } else {
                ForEach(model.ports) { port in
                    InfoPortRow(
                        port: port,
                        localPort: localPorts[port.port],
                        isRemote: isRemote,
                        open: { openPort(port) },
                        copyURL: { copyPortURL(port) },
                        kill: { force in
                            Task { await model.kill(port.pid, force: force) }
                        }
                    )
                }
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .panelFont(size: 11)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct ObservedPortForwards<Content: View>: View {
    @ObservedObject var controller: PortForwardController
    let content: ([Int: Int]) -> Content

    var body: some View { content(controller.localPortsByRemote) }
}

private struct InfoProcessRow: View {
    let process: SessionInfoModel.ProcessItem
    let kill: (_ force: Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(red: 0.25, green: 0.73, blue: 0.31))
                .frame(width: 5, height: 5)
            Text(process.name)
                .panelFont(size: 11.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
                .help(process.executable)
            Text(String(process.pid))
                .panelFont(size: 10, design: .monospaced)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if isHovering {
                Button {
                    kill(false)
                } label: {
                    Image(systemName: "xmark")
                        .panelFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Terminate Process", table: "Sidebar"))
            } else {
                Text(String(localized: "\(process.cpu, format: .number.precision(.fractionLength(0)))% · \(process.memoryLabel)", table: "Sidebar"))
                    .panelFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        // Fixed height so the taller hover button doesn't grow the row.
        .frame(height: 16)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(String(localized: "Terminate", table: "Sidebar")) { kill(false) }
            Button(String(localized: "Force Kill", table: "Sidebar")) { kill(true) }
            Divider()
            Button(String(localized: "Copy PID", table: "Sidebar")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(process.pid)", forType: .string)
            }
            Button(String(localized: "Copy Executable Path", table: "Sidebar")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(process.executable, forType: .string)
            }
        }
    }
}

private struct InfoPortRow: View {
    let port: SessionInfoModel.PortItem
    /// The loopback port this remote port is forwarded to, once it is.
    let localPort: Int?
    let isRemote: Bool
    let open: () -> Void
    let copyURL: () -> Void
    let kill: (_ force: Bool) -> Void

    @State private var isHovering = false

    /// What clicking the row reaches. A remote port that is not forwarded yet
    /// has no address to show until it is, so the label says so instead of
    /// naming one that would not answer.
    private var urlString: String {
        if let localPort { return "http://127.0.0.1:\(localPort)" }
        return isRemote
            ? String(localized: "Forward this port and open it", table: "Sidebar")
            : "http://localhost:\(port.port)"
    }

    /// The port cell: the remote number alone, or both numbers once forwarded
    /// to a different local port, so a mismatch is obvious. A forward on the
    /// same number, the usual case, needs no arrow.
    private var portLabel: String {
        guard let localPort, localPort != port.port else { return String(port.port) }
        return "\(port.port) → \(localPort)"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                Image(systemName: isRemote ? "arrow.left.arrow.right" : "network")
                    .panelFont(size: 9, weight: .medium)
                    .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
                    .frame(width: 12)
                Text(portLabel)
                    .panelFont(size: 11.5, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                Text(port.processName)
                    .panelFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHovering {
                    Image(systemName: "arrow.up.forward")
                        .panelFont(size: 9, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
            }
            // Fixed height to match the other sidebar rows.
            .frame(height: 16)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(isRemote && localPort == nil
                ? String(localized: "Forward and Open", table: "Sidebar")
                : String(localized: "Open in Browser", table: "Sidebar")) {
                open()
            }
            Button(String(localized: "Copy URL", table: "Sidebar")) { copyURL() }
            Divider()
            Button(String(localized: "Kill Process (\(port.processName))", table: "Sidebar")) { kill(false) }
        }
    }

    private var helpText: String {
        guard isRemote else { return String(localized: "Open \(urlString)", table: "Sidebar") }
        guard let localPort else {
            return String(
                localized: "Forward remote port \(port.port) to this Mac and open it", table: "Sidebar",
                comment: "Port row tooltip on a remote session. The placeholder is a port number."
            )
        }
        return String(
            localized: "Remote port \(port.port), open at http://127.0.0.1:\(localPort)/", table: "Sidebar",
            comment: "Port row tooltip once forwarded. The placeholders are the remote and local port numbers."
        )
    }
}
