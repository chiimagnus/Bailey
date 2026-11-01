import AppKit
import SwiftUI

/// A compact remote folder picker styled like Bailey's command palette.
/// The list only reads from the chosen SSH backend, never the Mac filesystem.
@MainActor
struct SSHFolderPickerView: View {
    let hosts: [String]
    let onCancel: () -> Void
    let onChoose: (String, String) -> Void

    @State private var host = ""
    @State private var customHost = ""
    @State private var isEnteringHost = false
    @State private var directory: String?
    @State private var input = ""
    @State private var folders: [String] = []
    @State private var windowsDrives: [String] = []
    @State private var selection = -1
    @State private var showHidden = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var requestID = 0
    @FocusState private var inputFocused: Bool

    private let themeChanges = Theme.changes

    private var showingDrives: Bool { directory == "/" && !windowsDrives.isEmpty }

    private var parent: String? {
        guard let directory, directory != "/" else { return nil }
        let parent = (directory as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private var visibleFolders: [String] {
        let available = folders.filter { showHidden || !$0.hasPrefix(".") }
        guard let directory, !input.isEmpty else { return available }
        let edited = SSHHostWorkspaces.normalizedPath(input)
        let prefix = directory == "/" ? "/" : directory + "/"
        guard edited.hasPrefix(prefix) else { return available }
        let fragment = String(edited.dropFirst(prefix.count))
        guard !fragment.isEmpty, !fragment.contains("/") else { return available }
        return available.filter { $0.localizedStandardContains(fragment) }
    }

    private var rows: [String] {
        (parent == nil ? [] : [".."]) + visibleFolders
    }

    private var typedDirectory: String? {
        let path = SSHHostWorkspaces.normalizedPath(input)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n") else {
            return nil
        }
        return (path as NSString).standardizingPath
    }

    private var currentFolder: String? {
        guard !host.isEmpty, !loading, let directory,
              typedDirectory == directory else { return nil }
        if rows.indices.contains(selection), rows[selection] != ".." {
            return (directory as NSString).appendingPathComponent(rows[selection])
        }
        return showingDrives ? nil : directory
    }

    private var selectionTarget: String? {
        guard let typedDirectory else { return nil }
        return typedDirectory == directory ? currentFolder : typedDirectory
    }

    static func startupLocation(_ output: Data) -> (home: String, drives: [String])? {
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
        guard let first = lines.first else { return nil }
        let home = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/"), !home.contains("\0") else { return nil }
        let drives = lines.dropFirst().compactMap { line -> String? in
            guard line.hasPrefix("DRIVE:"), line.count == 7,
                  let letter = line.last, "abcdefghijklmnopqrstuvwxyz".contains(letter)
            else { return nil }
            return String(letter)
        }
        return (home, Array(Set(drives)).sorted())
    }

    var body: some View {
        let _ = themeChanges.revision
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            panel
                .padding(.top, 110)
        }
        .ignoresSafeArea()
        .onExitCommand(perform: onCancel)
        .alert(String(localized: "Other SSH Host…", table: "Terminal"),
               isPresented: $isEnteringHost) {
            TextField(String(localized: "SSH host", table: "Terminal"), text: $customHost)
            Button(String(localized: "Connect", table: "Terminal")) {
                Task { await chooseHost(customHost.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            Button(String(localized: "Cancel", table: "Terminal"), role: .cancel) {}
        }
        .onDisappear { requestID &+= 1 }
        .onChange(of: showHidden) { selection = -1 }
        .task {
            if let first = hosts.first { await chooseHost(first) }
            DispatchQueue.main.async { inputFocused = true }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                TextField(
                    String(localized: "Remote folder path…", table: "Terminal"),
                    text: $input
                )
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($inputFocused)
                .onSubmit { acceptInput() }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.escape) { onCancel(); return .handled }
                .accessibilityIdentifier("bailey.sshFolderPicker.path")

                Menu {
                    ForEach(hosts, id: \.self) { alias in
                        Button(alias) {
                            Task { await chooseHost(alias) }
                        }
                    }
                    Button(String(localized: "Other SSH Host…", table: "Terminal")) {
                        isEnteringHost = true
                    }
                    Divider()
                    Toggle(
                        String(localized: "Show Hidden Folders", table: "Terminal"),
                        isOn: $showHidden
                    )
                } label: {
                    Label(host.isEmpty ? "SSH" : host, systemImage: "network")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("bailey.sshFolderPicker.host")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider().opacity(0.5)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .accessibilityIdentifier("bailey.sshFolderPicker.error")
            }

            if loading {
                ProgressView(String(localized: "Loading remote folders…", table: "Terminal"))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 34)
            } else if rows.isEmpty {
                Text(directory == nil
                     ? String(localized: "Choose an SSH host to browse folders.", table: "Terminal")
                     : String(localized: "No subfolders", table: "Terminal"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 27)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, folder in
                                folderRow(folder, index: index)
                                    .id(index)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 310)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selection) {
                        if rows.indices.contains(selection) {
                            proxy.scrollTo(selection)
                        }
                    }
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(String(localized: "Cancel", table: "Terminal"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Add", table: "Terminal")) {
                    Task { await chooseFolder() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || loading || selectionTarget == nil)
                .accessibilityIdentifier("bailey.sshFolderPicker.add")
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: Theme.background)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 28, y: 10)
    }

    private func folderRow(_ folder: String, index: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: folder == ".." ? "arrow.up" : showingDrives ? "internaldrive" : "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(
                    folder == ".." ? Color.secondary : Color(nsColor: Theme.accent)
                )
                .frame(width: 16)
            Text(verbatim: showingDrives ? folder.uppercased() + ":" : folder)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if folder != ".." {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .gesture(
            TapGesture(count: 2)
                .onEnded {
                    let destination = folder == ".." ? parent
                        : directory.map { ($0 as NSString).appendingPathComponent(folder) }
                    if let destination { Task { await browse(destination) } }
                }
                .exclusively(before: TapGesture(count: 1).onEnded {
                    selection = index
                    inputFocused = true
                })
        )
        .modifier(RowHighlightStyle(
            isSelected: selection == index,
            listActive: inputFocused,
            cornerRadius: 6
        ))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            selection = index
            inputFocused = true
        }
        .accessibilityIdentifier("bailey.sshFolderPicker.folder")
        .accessibilityValue(folder)
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = max(0, min(rows.count - 1, selection + delta))
    }

    private func acceptInput() {
        guard !loading else { return }
        if let path = typedDirectory, path != directory {
            Task { await browse(path) }
        } else if rows.indices.contains(selection) {
            let folder = rows[selection]
            let destination = folder == ".." ? parent
                : directory.map { ($0 as NSString).appendingPathComponent(folder) }
            if let destination { Task { await browse(destination) } }
        } else {
            Task { await chooseFolder() }
        }
    }

    private func chooseFolder() async {
        let isDirectPath = typedDirectory != directory
        guard let target = selectionTarget, !host.isEmpty, !loading else { return }
        let activeHost = host
        let request = requestID
        let backend = SSHHostWorkspaces.backend(for: activeHost)
        loading = true
        defer { if request == requestID { loading = false } }
        do {
            guard let stat = try await backend.stat(path: target),
                  stat.isDirectory || (isDirectPath && stat.isRegular) else {
                throw WorkspaceError.notFound
            }
            guard request == requestID, host == activeHost else { return }
            onChoose(activeHost, target)
        } catch {
            guard request == requestID, host == activeHost else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func chooseHost(_ alias: String) async {
        guard SSHHostWorkspaces.validHost(alias) else { return }
        requestID &+= 1
        let request = requestID
        host = alias
        directory = nil
        input = ""
        folders = []
        windowsDrives = []
        selection = -1
        errorMessage = nil
        loading = true

        do {
            let backend = SSHHostWorkspaces.backend(for: alias)
            let command = "cd && pwd -P && case \"$(uname -s)\" in "
                + "MSYS*|MINGW*|CYGWIN*) for drive in c d e f g h i j k l m n o p q r s t u v w x y z; do "
                + "if [ -d \"/$drive\" ]; then printf 'DRIVE:%s\\n' \"$drive\"; fi; "
                + "done ;; esac"
            let result = try await backend.run(
                argv: ["/bin/sh", "-c", command],
                cwd: nil, env: nil, stdin: nil, timeout: 12
            )
            guard result.status == 0 else {
                throw RemoteCommandFailure(
                    command: "pwd -P", status: result.status,
                    message: String(decoding: result.stderr, as: UTF8.self)
                )
            }
            guard let location = Self.startupLocation(result.stdout) else {
                throw WorkspaceError.notFound
            }
            guard request == requestID, host == alias else { return }
            windowsDrives = location.drives
            await browse(location.drives.isEmpty ? location.home : "/")
        } catch {
            guard request == requestID, host == alias else { return }
            loading = false
            errorMessage = error.localizedDescription
        }
    }

    private func browse(_ path: String) async {
        guard !host.isEmpty else { return }
        let destination = SSHHostWorkspaces.normalizedPath(path)
        guard destination.hasPrefix("/"), !destination.contains("\n"),
              !destination.contains("\0") else {
            errorMessage = String(localized: "Enter an absolute remote folder path.", table: "Terminal")
            return
        }
        requestID &+= 1
        let request = requestID
        let activeHost = host
        loading = true
        errorMessage = nil
        if destination == "/", !windowsDrives.isEmpty {
            directory = "/"
            input = "/"
            folders = windowsDrives
            selection = -1
            loading = false
            return
        }
        do {
            let backend = SSHHostWorkspaces.backend(for: activeHost)
            guard try await backend.stat(path: destination)?.isDirectory == true else {
                throw WorkspaceError.notFound
            }
            let contents = try await backend.list(directory: destination)
            guard request == requestID, host == activeHost else { return }
            directory = destination
            input = destination == "/" ? "/" : destination + "/"
            folders = contents.filter {
                $0.isDirectory && $0.name != "." && $0.name != ".."
                    && !$0.name.contains("/") && !$0.name.contains("\0")
            }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            selection = -1
            loading = false
        } catch {
            guard request == requestID, host == activeHost else { return }
            errorMessage = error.localizedDescription
            loading = false
        }
    }
}
