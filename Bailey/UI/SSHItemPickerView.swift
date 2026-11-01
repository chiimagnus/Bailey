import AppKit
import Observation
import SwiftUI

/// A remote picker must list through the selected SSH backend, never the Mac filesystem.
@MainActor
@Observable
final class SSHItemPickerModel {
    let aliases: [String]
    var host: String {
        didSet {
            guard host != oldValue else { return }
            invalidate()
            homeDirectory = nil
            currentDirectory = nil
            entries = []
            selection = []
            errorMessage = nil
        }
    }
    var selection: Set<String> = []
    var manualPaths = ""
    private(set) var homeDirectory: String?
    private(set) var currentDirectory: String?
    private(set) var entries: [WorkspaceEntry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let backendForHost: @MainActor (String) -> any WorkspaceBackend

    init(
        aliases: [String], preferredHost: String? = nil,
        backendForHost: @escaping @MainActor (String) -> any WorkspaceBackend = {
            SSHHostWorkspaces.backend(for: $0)
        }
    ) {
        var seen = Set<String>()
        self.aliases = aliases.filter { seen.insert($0).inserted }
        host = preferredHost ?? self.aliases.first ?? ""
        self.backendForHost = backendForHost
    }

    var canAdd: Bool {
        SSHHostWorkspaces.validHost(host.trimmingCharacters(in: .whitespacesAndNewlines))
            && !pathsToAdd.isEmpty && pathsToAdd.allSatisfy { $0.hasPrefix("/") }
    }

    var pathsToAdd: [String] {
        let entered = manualPaths.components(separatedBy: .newlines)
            .map(SSHHostWorkspaces.normalizedPath)
            .filter { !$0.isEmpty }
        var paths = entered + selection.sorted()
        if paths.isEmpty, let currentDirectory { paths = [currentDirectory] }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    var parentDirectory: String? {
        guard let currentDirectory, currentDirectory != "/" else { return nil }
        return (currentDirectory as NSString).deletingLastPathComponent
    }

    func path(for entry: WorkspaceEntry) -> String {
        ((currentDirectory ?? "/") as NSString).appendingPathComponent(entry.name)
    }

    func invalidate() {
        revision &+= 1
        isLoading = false
    }

    func browse(path: String? = nil) async {
        let targetHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHHostWorkspaces.validHost(targetHost) else {
            errorMessage = String(localized: "Enter an SSH host from ~/.ssh/config.", table: "Terminal")
            return
        }
        revision &+= 1
        let request = revision
        isLoading = true
        errorMessage = nil
        defer { if revision == request { isLoading = false } }

        let backend = backendForHost(targetHost)
        do {
            var home = homeDirectory
            if home == nil {
                let response = try await backend.run(
                    argv: ["/bin/sh", "-c", "cd && pwd -P"],
                    cwd: nil, env: nil, stdin: nil, timeout: 10
                )
                let candidate = String(data: response.stdout, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard response.status == 0, let candidate,
                      candidate.hasPrefix("/"), !candidate.contains("\n") else {
                    throw PickerError.homeUnavailable
                }
                home = candidate
            }
            guard let directory = path.map(SSHHostWorkspaces.normalizedPath) ?? home,
                  directory.hasPrefix("/") else {
                throw PickerError.invalidDirectory(path ?? "")
            }
            guard try await backend.stat(path: directory)?.isDirectory == true else {
                throw PickerError.invalidDirectory(directory)
            }
            let result = try await backend.list(directory: directory)
            guard revision == request, host.trimmingCharacters(in: .whitespacesAndNewlines) == targetHost
            else { return }
            homeDirectory = home
            currentDirectory = directory
            entries = result.filter {
                $0.name != "." && $0.name != ".."
                    && !$0.name.contains("/") && !$0.name.contains("\0")
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            selection = []
        } catch {
            guard revision == request else { return }
            errorMessage = error.localizedDescription
        }
    }

    private enum PickerError: LocalizedError {
        case homeUnavailable
        case invalidDirectory(String)

        var errorDescription: String? {
            switch self {
            case .homeUnavailable:
                String(localized: "Cannot locate the remote home folder.", table: "Terminal")
            case .invalidDirectory(let path):
                String(localized: "Remote folder not found or inaccessible: \(path)", table: "Terminal")
            }
        }
    }
}

@MainActor
struct SSHItemPickerView: View {
    @State private var model: SSHItemPickerModel
    @State private var location = ""
    let onCancel: @MainActor () -> Void
    let onSelection: @MainActor (String, [String]) -> Void

    init(
        aliases: [String], preferredHost: String?,
        onCancel: @escaping @MainActor () -> Void,
        onSelection: @escaping @MainActor (String, [String]) -> Void
    ) {
        _model = State(initialValue: SSHItemPickerModel(
            aliases: aliases, preferredHost: preferredHost
        ))
        self.onCancel = onCancel
        self.onSelection = onSelection
    }

    var body: some View {
        @Bindable var picker = model
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Add SSH Files or Projects", table: "Terminal"))
                    .font(.title2.weight(.semibold))
                Text(String(localized: "Choose a host, then browse its folders and files.", table: "Terminal"))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(String(localized: "SSH host", table: "Terminal"))
                TextField(String(localized: "Host from ~/.ssh/config", table: "Terminal"),
                          text: $picker.host)
                    .accessibilityIdentifier("bailey.sshPicker.host")
                if !model.aliases.isEmpty {
                    Menu {
                        ForEach(model.aliases, id: \.self) { alias in
                            Button(alias) {
                                model.host = alias
                                Task { await model.browse() }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .help(String(localized: "Saved SSH hosts", table: "Terminal"))
                }
                Button(String(localized: "Browse", table: "Terminal")) {
                    Task { await model.browse(path: model.currentDirectory) }
                }
                .disabled(model.isLoading || !SSHHostWorkspaces.validHost(
                    model.host.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                .accessibilityIdentifier("bailey.sshPicker.browse")
            }

            HStack {
                Button {
                    if let home = model.homeDirectory {
                        Task { await model.browse(path: home) }
                    }
                } label: {
                    Image(systemName: "house")
                }
                .help(String(localized: "Home Folder", table: "Terminal"))
                .disabled(model.homeDirectory == nil || model.isLoading)

                Button {
                    if let parent = model.parentDirectory {
                        Task { await model.browse(path: parent) }
                    }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help(String(localized: "Parent Folder", table: "Terminal"))
                .disabled(model.parentDirectory == nil || model.isLoading)

                TextField(String(localized: "Remote folder path", table: "Terminal"),
                          text: $location)
                    .onSubmit { navigateToLocation() }
                    .accessibilityIdentifier("bailey.sshPicker.location")
                Button(String(localized: "Go", table: "Terminal")) {
                    navigateToLocation()
                }
                .disabled(location.isEmpty || model.isLoading)
            }
            .buttonStyle(.borderless)

            ZStack {
                List(selection: $picker.selection) {
                    ForEach(model.entries, id: \.name) { entry in
                        let path = model.path(for: entry)
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .foregroundStyle(.secondary)
                            Text(entry.name)
                                .lineLimit(1)
                            Spacer()
                            if entry.isDirectory {
                                Button {
                                    Task { await model.browse(path: path) }
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(String(localized: "Open Folder", table: "Terminal"))
                            }
                        }
                        .tag(path)
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            if entry.isDirectory {
                                Task { await model.browse(path: path) }
                            }
                        })
                    }
                }
                .listStyle(.plain)
                .disabled(model.isLoading)
                .accessibilityIdentifier("bailey.sshPicker.files")

                if model.isLoading {
                    ProgressView(String(localized: "Loading remote folders…", table: "Terminal"))
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                } else if model.currentDirectory == nil {
                    ContentUnavailableView(
                        String(localized: "Browse a remote host", table: "Terminal"),
                        systemImage: "network",
                        description: Text(String(
                            localized: "Select an SSH host above to see its files.", table: "Terminal"
                        ))
                    )
                } else if model.entries.isEmpty {
                    ContentUnavailableView(
                        String(localized: "Empty Folder", table: "Terminal"),
                        systemImage: "folder",
                        description: Text(String(
                            localized: "You can add this folder as a project.", table: "Terminal"
                        ))
                    )
                }
            }
            .frame(height: 280)

            DisclosureGroup(String(localized: "Enter paths manually", table: "Terminal")) {
                Text(String(
                    localized: "One absolute remote path per line. Windows drive paths are also accepted.",
                    table: "Terminal"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                TextEditor(text: $picker.manualPaths)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 72)
                    .accessibilityIdentifier("bailey.sshPicker.manualPaths")
            }

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("bailey.sshPicker.error")
            }

            HStack {
                if model.selection.isEmpty, let directory = model.currentDirectory,
                   model.manualPaths.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(directory)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                } else if !model.pathsToAdd.isEmpty {
                    Text(String(localized: "\(model.pathsToAdd.count) items selected", table: "Terminal"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Cancel", table: "Terminal"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Add", table: "Terminal")) {
                    onSelection(
                        model.host.trimmingCharacters(in: .whitespacesAndNewlines),
                        model.pathsToAdd
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdd || model.isLoading)
                .accessibilityIdentifier("bailey.sshPicker.add")
            }
        }
        .padding(20)
        .frame(width: 640)
        .onChange(of: model.currentDirectory) { _, path in location = path ?? "" }
        .onChange(of: model.host) { location = "" }
        .onDisappear { model.invalidate() }
    }

    private func navigateToLocation() {
        Task { await model.browse(path: location) }
    }
}
