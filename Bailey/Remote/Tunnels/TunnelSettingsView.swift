import AppKit
import Combine
import SwiftUI

/// Native Settings list. TunnelManager, not this page, owns connections and
/// persistence; opening or leaving Settings never changes a running forward.
struct TunnelSettingsPane: View {
    @ObservedObject private var manager = TunnelManager.shared
    @Binding var selection: UUID?
    @Binding var editor: TunnelEditDraft?
    @State private var now = Date()
    @State private var conflictMessage = ""
    @State private var showsConflict = false
    @State private var deletingID: UUID?
    @State private var showsDeleteConfirmation = false

    private var selectedTunnel: TunnelDefinition? {
        manager.tunnels.first { $0.id == selection }
    }

    var body: some View {
        Section {
            if manager.tunnels.isEmpty {
                VStack(spacing: 12) {
                    Label(
                        String(localized: "No saved forwards", table: "Workspace"),
                        systemImage: "network"
                    )
                    .foregroundStyle(.secondary)
                    Button(String(localized: "Add forward", table: "Workspace")) {
                        editor = TunnelEditDraft(existing: nil)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 132)
            } else {
                List(selection: $selection) {
                    ForEach(manager.tunnels) { tunnel in
                        tunnelRow(tunnel)
                            .tag(tunnel.id)
                            .contextMenu {
                                Button(
                                    tunnel.direction == .local
                                        ? String(localized: "Copy Local Address", table: "Workspace")
                                        : String(localized: "Copy Remote Address", table: "Workspace")
                                ) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(tunnel.listenAddress, forType: .string)
                                }

                                if tunnel.isEnabled {
                                    Button(String(localized: "Reconnect", table: "Workspace")) {
                                        manager.restart(id: tunnel.id)
                                    }
                                }
                                Divider()
                                Button(String(localized: "Edit…", table: "Workspace")) {
                                    editor = TunnelEditDraft(existing: tunnel)
                                }
                                Button(String(localized: "Delete", table: "Workspace"), role: .destructive) {
                                    requestDelete(tunnel)
                                }
                            }
                    }
                }
                .listStyle(.bordered)
                .frame(minHeight: 180, idealHeight: 290)
                .accessibilityLabel(String(localized: "Saved port forwards", table: "Workspace"))

                HStack(spacing: 8) {
                    Button {
                        editor = TunnelEditDraft(existing: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(String(localized: "Add forward", table: "Workspace"))
                    .help(String(localized: "Add forward", table: "Workspace"))

                    Button {
                        if let selectedTunnel { requestDelete(selectedTunnel) }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedTunnel == nil)
                    .accessibilityLabel(String(localized: "Remove selected forward", table: "Workspace"))
                    .help(String(localized: "Remove selected forward", table: "Workspace"))

                    Spacer()

                    Button(String(localized: "Edit…", table: "Workspace")) {
                        if let selectedTunnel { editor = TunnelEditDraft(existing: selectedTunnel) }
                    }
                    .disabled(selectedTunnel == nil)
                }
            }

            Text(String(
                localized: "Forwards stay open while Bailey is running, even with no terminal connected. They use your ssh keys and ~/.ssh/config; Bailey never asks for a password.",
                table: "Workspace"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            // Only advance the clock when a retry countdown is visible.
            if manager.states.values.contains(where: {
                if case .failed(_, let retryAt?) = $0 { return retryAt > date }
                return false
            }) {
                now = date
            }
        }
        .alert(String(localized: "Port Conflict", table: "Workspace"), isPresented: $showsConflict) {
            Button(String(localized: "OK", table: "Settings"), role: .cancel) {}
        } message: {
            Text(verbatim: conflictMessage)
        }
        .confirmationDialog(
            String(localized: "Delete this forward?", table: "Workspace"),
            isPresented: $showsDeleteConfirmation
        ) {
            Button(String(localized: "Delete", table: "Workspace"), role: .destructive) {
                if let deletingID {
                    manager.remove(id: deletingID)
                    if selection == deletingID { selection = nil }
                }
                deletingID = nil
            }
        }
    }

    private func tunnelRow(_ tunnel: TunnelDefinition) -> some View {
        let status = status(for: tunnel)
        return HStack(alignment: .center, spacing: 12) {
            Toggle(
                String(localized: "Keep \(tunnel.name) open", table: "Workspace"),
                isOn: Binding(
                    get: { manager.tunnels.first { $0.id == tunnel.id }?.isEnabled ?? false },
                    set: { enabled in
                        guard let current = manager.tunnels.first(where: { $0.id == tunnel.id }) else { return }
                        if enabled, let other = manager.conflict(with: current) {
                            conflictMessage = current.conflictMessage(with: other) + "\n"
                                + String(localized: "Turn that forward off or give this one a different port.", table: "Workspace")
                            showsConflict = true
                            return
                        }
                        manager.setEnabled(enabled, id: tunnel.id)
                    }
                )
            )
            .labelsHidden()
            .accessibilityLabel(String(localized: "Keep \(tunnel.name) open", table: "Workspace"))

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: tunnel.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(verbatim: tunnel.routeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(tunnel.name)\n\(tunnel.routeDescription)")
            .onTapGesture(count: 2) {
                editor = TunnelEditDraft(existing: tunnel)
            }

            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: status.text)
                    .lineLimit(1)
                if let detail = status.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(width: 135, alignment: .trailing)
            .help(status.reason ?? status.text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                [status.text, status.detail, status.reason].compactMap { $0 }.joined(separator: ", ")
            )
        }
        .padding(.vertical, 5)
    }

    private func status(for tunnel: TunnelDefinition) -> (text: String, detail: String?, reason: String?) {
        if !tunnel.isEnabled {
            return (String(localized: "Off", table: "Workspace"), nil, nil)
        }
        switch manager.state(for: tunnel.id) {
        case .stopped:
            return (String(localized: "Stopped", table: "Workspace"), nil, nil)
        case .connecting:
            return (String(localized: "Connecting…", table: "Workspace"), nil, nil)
        case .up:
            return (String(localized: "Connected", table: "Workspace"), nil, nil)
        case .failed(let reason, let retryAt):
            let detail: String?
            if let retryAt {
                let seconds = max(0, Int(retryAt.timeIntervalSince(now).rounded(.up)))
                detail = String(localized: "retrying in \(String(seconds)) s", table: "Workspace")
            } else {
                detail = nil
            }
            return (String(localized: "Failed", table: "Workspace"), detail, reason)
        }
    }

    private func requestDelete(_ tunnel: TunnelDefinition) {
        deletingID = tunnel.id
        showsDeleteConfirmation = true
    }
}

/// In-progress form values are strings so invalid ports never disappear while
/// editing. Conversion and conflict checks happen once, on Save.
struct TunnelEditDraft: Identifiable {
    let id = UUID()
    let existing: TunnelDefinition?
    var name: String
    var host: String
    var direction: TunnelDirection
    var localHost: String
    var localPort: String
    var remoteHost: String
    var remotePort: String
    var isEnabled: Bool

    init(existing: TunnelDefinition?) {
        self.existing = existing
        name = existing?.name ?? ""
        host = existing?.host ?? ""
        direction = existing?.direction ?? .local
        localHost = existing?.localHost ?? "127.0.0.1"
        localPort = existing.map { String($0.localPort) } ?? ""
        remoteHost = existing?.remoteHost ?? "127.0.0.1"
        remotePort = existing.map { String($0.remotePort) } ?? ""
        isEnabled = existing?.isEnabled ?? true
    }

    func build(against saved: [TunnelDefinition]) -> (tunnel: TunnelDefinition?, problem: String?) {
        let remote = remotePort.trimmingCharacters(in: .whitespaces)
        guard let remoteNumber = Int(remote) else {
            return (nil, String(localized: "Enter the remote port as a number.", table: "Workspace"))
        }
        let local = localPort.trimmingCharacters(in: .whitespaces)
        guard let localNumber = local.isEmpty ? remoteNumber : Int(local) else {
            return (nil, String(localized: "Enter the local port as a number.", table: "Workspace"))
        }

        let host = host.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        var tunnel = existing ?? TunnelDefinition(name: "", host: "", localPort: 0, remotePort: 0)
        tunnel.name = name.isEmpty ? "\(host):\(remoteNumber)" : name
        tunnel.host = host
        tunnel.direction = direction
        tunnel.localHost = localHost.trimmingCharacters(in: .whitespaces)
        tunnel.localPort = localNumber
        tunnel.remoteHost = remoteHost.trimmingCharacters(in: .whitespaces)
        tunnel.remotePort = remoteNumber
        tunnel.isEnabled = isEnabled

        if let problem = tunnel.validationProblem { return (nil, problem) }
        if tunnel.isEnabled, let other = saved.first(where: {
            $0.isEnabled && $0.id != tunnel.id && $0.listensAlongside(tunnel)
        }) {
            return (nil, tunnel.conflictMessage(with: other))
        }
        return (tunnel, nil)
    }
}

extension TunnelDefinition {
    func conflictMessage(with other: TunnelDefinition) -> String {
        switch direction {
        case .local:
            String(localized: "Local port \(String(localPort)) is already used by “\(other.name)”.", table: "Workspace")
        case .remote:
            String(localized: "Port \(String(remotePort)) on \(host) is already used by “\(other.name)”.", table: "Workspace")
        }
    }
}

/// A native SwiftUI sheet; the actual TunnelManager remains outside its lifetime.
struct TunnelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TunnelEditDraft
    @State private var problem: String?
    @FocusState private var isHostFocused: Bool

    let onSave: (TunnelDefinition) -> Void

    init(draft: TunnelEditDraft, onSave: @escaping (TunnelDefinition) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(
                        String(localized: "Name:", table: "Workspace"),
                        text: $draft.name,
                        prompt: Text(String(localized: "A1 desktop", table: "Workspace"))
                    )
                    Picker(String(localized: "Direction:", table: "Workspace"), selection: $draft.direction) {
                        Text(String(localized: "Reach a remote port from this Mac", table: "Workspace"))
                            .tag(TunnelDirection.local)
                        Text(String(localized: "Let the remote machine reach this Mac", table: "Workspace"))
                            .tag(TunnelDirection.remote)
                    }
                    TextField(
                        String(localized: "SSH host:", table: "Workspace"),
                        text: $draft.host,
                        prompt: Text(String(localized: "oracle or user@host", table: "Workspace"))
                    )
                        .focused($isHostFocused)
                }

                Section {
                    if draft.direction == .local {
                        TextField(String(localized: "Remote host:", table: "Workspace"), text: $draft.remoteHost)
                    } else {
                        TextField(String(localized: "Local host:", table: "Workspace"), text: $draft.localHost)
                    }
                    TextField(
                        String(localized: "Remote port:", table: "Workspace"),
                        text: $draft.remotePort,
                        prompt: Text(verbatim: draft.direction == .local ? "3389" : "2222")
                    )
                    TextField(
                        String(localized: "Local port:", table: "Workspace"),
                        text: $draft.localPort,
                        prompt: Text(draft.direction == .local
                            ? String(localized: "Same as remote", table: "Workspace") : "22")
                    )
                }

                Section {
                    Toggle(
                        String(localized: "Keep this forward open", table: "Workspace"),
                        isOn: $draft.isEnabled
                    )
                    if draft.direction == .remote {
                        Text(String(
                            localized: "Anything that can reach that port on the remote machine reaches this Mac through it. To reach this Mac's own ssh, turn on Remote Login in System Settings → General → Sharing.",
                            table: "Workspace"
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }

                if let problem {
                    Text(verbatim: problem)
                        .foregroundStyle(.red)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel", table: "Workspace")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Save", table: "Workspace")) {
                    let result = draft.build(against: TunnelManager.shared.tunnels)
                    guard let tunnel = result.tunnel else {
                        problem = result.problem
                        return
                    }
                    onSave(tunnel)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 490, idealWidth: 530, minHeight: 420, idealHeight: 480)
        .onAppear { isHostFocused = draft.existing == nil }
    }
}
