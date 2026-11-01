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
            manualPaths = ""
            backHistory = []
            forwardHistory = []
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
    private(set) var backHistory: [String] = []
    private(set) var forwardHistory: [String] = []

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

    var breadcrumbPaths: [String] {
        guard let currentDirectory else { return [] }
        var paths = ["/"]
        var prefix = ""
        for component in currentDirectory.split(separator: "/") {
            prefix += "/" + component
            paths.append(prefix)
        }
        return paths
    }

    func path(for entry: WorkspaceEntry) -> String {
        ((currentDirectory ?? "/") as NSString).appendingPathComponent(entry.name)
    }

    func invalidate() {
        revision &+= 1
        isLoading = false
    }

    func browse(path: String? = nil) async {
        await browse(path: path, navigation: .push)
    }

    func goBack() async {
        guard let destination = backHistory.last else { return }
        await browse(path: destination, navigation: .back)
    }

    func goForward() async {
        guard let destination = forwardHistory.last else { return }
        await browse(path: destination, navigation: .forward)
    }

    private enum Navigation {
        case push, back, forward
    }

    private func browse(path: String?, navigation: Navigation) async {
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

            let listed = result.filter {
                $0.name != "." && $0.name != ".."
                    && !$0.name.contains("/") && !$0.name.contains("\0")
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let previous = currentDirectory
            if let previous, previous != directory {
                switch navigation {
                case .push:
                    backHistory.append(previous)
                    forwardHistory = []
                case .back:
                    backHistory.removeLast()
                    forwardHistory.append(previous)
                case .forward:
                    forwardHistory.removeLast()
                    backHistory.append(previous)
                }
            }
            homeDirectory = home
            currentDirectory = directory
            entries = listed
            if previous == directory {
                let available = Set(listed.map {
                    (directory as NSString).appendingPathComponent($0.name)
                })
                selection.formIntersection(available)
            } else {
                selection = []
            }
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

private struct SSHBrowserRow: Identifiable {
    let id: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
}

@MainActor
struct SSHItemPickerView: View {
    @State private var model: SSHItemPickerModel
    @State private var location = ""
    @State private var isEditingLocation = false
    @FocusState private var locationIsFocused: Bool
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

    private var rows: [SSHBrowserRow] {
        model.entries.map { entry in
            SSHBrowserRow(
                id: model.path(for: entry), name: entry.name,
                isDirectory: entry.isDirectory, isSymlink: entry.isSymlink
            )
        }
    }

    var body: some View {
        @Bindable var picker = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                Text(String(localized: "SSH Host", table: "Terminal"))
                    .fontWeight(.medium)
                TextField(
                    String(localized: "Host from ~/.ssh/config", table: "Terminal"),
                    text: $picker.host
                )
                .frame(maxWidth: 270)
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
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(String(localized: "Saved SSH hosts", table: "Terminal"))
                }
                Spacer()
                Button(model.currentDirectory == nil
                       ? String(localized: "Connect", table: "Terminal")
                       : String(localized: "Refresh", table: "Terminal")) {
                    Task { await model.browse(path: model.currentDirectory) }
                }
                .disabled(model.isLoading || !SSHHostWorkspaces.validHost(
                    model.host.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                .accessibilityIdentifier("bailey.sshPicker.browse")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            HStack(spacing: 10) {
                Button {
                    Task { await model.goBack() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(model.backHistory.isEmpty || model.isLoading)
                .help(String(localized: "Back", table: "Terminal"))
                .accessibilityLabel("Back")

                Button {
                    Task { await model.goForward() }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(model.forwardHistory.isEmpty || model.isLoading)
                .help(String(localized: "Forward", table: "Terminal"))
                .accessibilityLabel("Forward")

                Button {
                    if let home = model.homeDirectory {
                        Task { await model.browse(path: home) }
                    }
                } label: {
                    Image(systemName: "house")
                }
                .disabled(model.homeDirectory == nil || model.isLoading)
                .help(String(localized: "Home Folder", table: "Terminal"))
                .accessibilityLabel("Home Folder")

                Button {
                    if let parent = model.parentDirectory {
                        Task { await model.browse(path: parent) }
                    }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(model.parentDirectory == nil || model.isLoading)
                .help(String(localized: "Parent Folder", table: "Terminal"))
                .accessibilityLabel("Parent Folder")

                Divider()
                    .frame(height: 18)

                if isEditingLocation {
                    TextField(
                        String(localized: "Remote folder path", table: "Terminal"),
                        text: $location
                    )
                    .focused($locationIsFocused)
                    .onSubmit { navigateToLocation() }
                    .accessibilityIdentifier("bailey.sshPicker.location")
                    Button(String(localized: "Go", table: "Terminal")) {
                        navigateToLocation()
                    }
                    .disabled(location.isEmpty || model.isLoading)
                } else if let current = model.currentDirectory {
                    ScrollViewReader { scroll in
                        ScrollView(.horizontal) {
                            HStack(spacing: 5) {
                                ForEach(model.breadcrumbPaths, id: \.self) { path in
                                    if path != "/" {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Button {
                                        Task { await model.browse(path: path) }
                                    } label: {
                                        Text(path == "/" ? "/" : (path as NSString).lastPathComponent)
                                            .fontWeight(path == current ? .semibold : .regular)
                                            .foregroundStyle(path == current ? Color.primary : Color.secondary)
                                            .lineLimit(1)
                                    }
                                    .disabled(model.isLoading)
                                    .help(path)
                                    .id(path)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .scrollIndicators(.hidden)
                        .onAppear { scroll.scrollTo(current, anchor: .trailing) }
                        .onChange(of: current) { _, next in
                            scroll.scrollTo(next, anchor: .trailing)
                        }
                    }
                } else {
                    Text(String(localized: "Choose a host to browse", table: "Terminal"))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    location = model.currentDirectory ?? ""
                    isEditingLocation.toggle()
                } label: {
                    Image(systemName: "pencil.line")
                }
                .help(String(localized: "Go to Folder", table: "Terminal"))
                .accessibilityLabel("Go to Folder")
                .disabled(model.isLoading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ZStack {
                Table(rows, selection: $picker.selection) {
                    TableColumn("Name") { row in
                        HStack(spacing: 8) {
                            Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(row.isDirectory ? Color.accentColor : Color.secondary)
                            Text(row.name)
                                .lineLimit(1)
                            if row.isSymlink {
                                Image(systemName: "arrow.turn.up.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            if row.isDirectory {
                                Task { await model.browse(path: row.id) }
                            } else {
                                onSelection(
                                    model.host.trimmingCharacters(in: .whitespacesAndNewlines),
                                    [row.id]
                                )
                            }
                        })
                        .help(row.id)
                    }
                    TableColumn("Kind") { row in
                        Text(row.isSymlink
                             ? String(localized: "Alias", table: "Terminal")
                             : row.isDirectory
                                ? String(localized: "Folder", table: "Terminal")
                                : String(localized: "File", table: "Terminal"))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 112, max: 180)
                }
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
                            localized: "Choose an SSH host above to see its folders and files.",
                            table: "Terminal"
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
            .frame(minHeight: 300)

            Divider()

            DisclosureGroup(
                String(localized: "Enter paths manually", table: "Terminal")
            ) {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("bailey.sshPicker.error")
            }

            Divider()

            HStack(spacing: 12) {
                if model.selection.isEmpty, let directory = model.currentDirectory,
                   model.manualPaths.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(
                        String(localized: "Current folder", table: "Terminal"),
                        systemImage: "folder"
                    )
                    .help(directory)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 510, idealHeight: 550)
        .onChange(of: isEditingLocation) { _, editing in
            if editing { locationIsFocused = true }
        }
        .onChange(of: model.currentDirectory) { _, path in
            location = path ?? ""
            isEditingLocation = false
        }
        .onChange(of: model.host) {
            location = ""
            isEditingLocation = false
        }
        .onDisappear { model.invalidate() }
    }

    private func navigateToLocation() {
        Task { await model.browse(path: location) }
    }
}
