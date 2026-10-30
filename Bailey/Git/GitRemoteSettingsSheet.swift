import SwiftUI

/// Repository-scoped Git configuration; only the current project's remotes are editable.
struct GitRemoteSettingsSheet: View {
    let model: GitStatusModel
    let target: GitStatusModel.ActionTarget

    private var isCurrentRepository: Bool { model.canBrowse(target) }
    @Environment(\.dismiss) private var dismiss
    @State private var locations: [GitStatusModel.RemoteLocation] = []
    @State private var name = ""
    @State private var address = ""
    @State private var editingRemote: String?
    @State private var removingRemote: String?
    @State private var reading = true

    private var canSubmit: Bool {
        !model.isBusy && isCurrentRepository && !name.isEmpty && !address.isEmpty
    }

    var body: some View {
        Form {
            Section(String(localized: "Remotes", table: "Git")) {
                if reading {
                    ProgressView()
                } else if locations.isEmpty {
                    Text(String(localized: "No Git remotes configured.", table: "Git"))
                        .foregroundStyle(.secondary)
                }
                ForEach(locations) { location in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: location.name).fontWeight(.medium)
                            Text(verbatim: location.fetchURL)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            if let pushURL = location.pushURL, pushURL != location.fetchURL {
                                Text(String(localized: "Push", table: "Git") + ": " + pushURL)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                        Button(String(localized: "Edit", table: "Git")) {
                            editingRemote = location.name
                            name = location.name
                            address = location.fetchURL
                        }
                        Button(String(localized: "Remove", table: "Git")) {
                            removingRemote = location.name
                        }
                    }
                    .disabled(model.isBusy || !isCurrentRepository)
                }
                Button(String(localized: "Refresh", table: "Git")) {
                    Task { await reload() }
                }
                .disabled(model.isBusy || reading || !isCurrentRepository)
            }

            Section(editingRemote == nil
                    ? String(localized: "Add Remote", table: "Git")
                    : String(localized: "Edit Remote", table: "Git")) {
                if editingRemote == nil {
                    TextField(String(localized: "Remote name", table: "Git"), text: $name)
                        .accessibilityIdentifier("bailey.git.remote-name")
                } else {
                    Text(verbatim: name)
                }
                TextField(String(localized: "Remote URL", table: "Git"), text: $address)
                    .accessibilityIdentifier("bailey.git.remote-url")
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                HStack {
                    if editingRemote != nil {
                        Button(String(localized: "Cancel", table: "Git")) {
                            clearEditor()
                        }
                    }
                    Spacer()
                    Button(editingRemote == nil
                           ? String(localized: "Add Remote", table: "Git")
                           : String(localized: "Save", table: "Git")) {
                        guard isCurrentRepository else { dismiss(); return }
                        let editedRemote = editingRemote
                        let remote = name
                        let url = address
                        let finished: @MainActor (Bool) -> Void = { success in
                            if success {
                                clearEditor()
                                Task { await reload() }
                            }
                        }
                        if let editedRemote {
                            model.changeRemoteURL(name: editedRemote, url: url, completion: finished)
                        } else {
                            model.addRemote(name: remote, url: url, completion: finished)
                        }
                    }
                    .disabled(!canSubmit)
                }
            }

            if let error = model.lastError {
                Section {
                    Text(verbatim: error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 510, minHeight: 360)
        .navigationTitle(String(localized: "Git Remotes", table: "Git"))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button(String(localized: "Done", table: "Git")) { dismiss() }
                    .accessibilityIdentifier("bailey.git.remote-done")
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .task { if isCurrentRepository { await reload() } else { dismiss() } }
        .onChange(of: model.isBusy) { _, busy in
            if !busy { Task { await reload() } }
        }
        .onChange(of: model.repoRoot) { _, _ in dismiss() }
        .onChange(of: model.currentScope) { _, _ in dismiss() }
        .confirmationDialog(
            String(localized: "Remove Git remote?", table: "Git"),
            isPresented: Binding(
                get: { removingRemote != nil },
                set: { if !$0 { removingRemote = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let removingRemote {
                Button(String(localized: "Remove Remote", table: "Git"), role: .destructive) {
                    guard isCurrentRepository else { dismiss(); return }
                    model.removeRemote(name: removingRemote) { success in
                        if success { Task { await reload() } }
                    }
                    self.removingRemote = nil
                }
            }
        } message: {
            Text(String(localized: "This removes the remote configuration and its tracking references, not the hosted repository.", table: "Git"))
        }
    }

    private func clearEditor() {
        editingRemote = nil
        name = ""
        address = ""
    }

    private func reload() async {
        reading = true
        locations = await model.remoteLocations()
        reading = false
    }
}
