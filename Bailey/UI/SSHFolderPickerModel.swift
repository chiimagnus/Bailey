import Foundation
import Observation

/// The picker's remote state belongs to one presentation, not to the active project.
@MainActor
@Observable
final class SSHFolderPickerModel {
    let hosts: [String]

    private(set) var host: String?
    private(set) var directory: String?
    private(set) var pendingPath: String?
    private(set) var input = ""
    private(set) var folders: [String] = []
    private(set) var windowsDrives: [String] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var selectedName: String?
    var showHidden = false {
        didSet {
            if !showHidden, selectedName?.hasPrefix(".") == true { selectedName = nil }
        }
    }

    @ObservationIgnored private let backendForHost: @MainActor (String) -> any WorkspaceBackend
    @ObservationIgnored private var requestID = 0
    @ObservationIgnored private var inputRevision = 0

    @ObservationIgnored private var isActive = true

    private enum FolderIssue: LocalizedError {
        case missing(String)
        case file(String)

        var errorDescription: String? {
            switch self {
            case .missing(let path):
                String(localized: "Remote file or folder not found: \(path)", table: "Terminal")
            case .file:
                String(localized: "This is a file. Choose Add to open it.", table: "Terminal")
            }
        }
    }

    init(
        hosts: [String],
        backendForHost: @escaping @MainActor (String) -> any WorkspaceBackend = {
            SSHHostWorkspaces.backend(for: $0)
        }
    ) {
        self.hosts = hosts
        self.backendForHost = backendForHost
    }

    var showingDrives: Bool { directory == "/" && !windowsDrives.isEmpty }

    var parent: String? {
        guard let directory, directory != "/" else { return nil }
        let parent = (directory as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    var rows: [String] {
        let available = folders.filter { showHidden || !$0.hasPrefix(".") }
        guard let directory, let edited = Self.remotePath(input) else { return [] }
        let prefix = directory == "/" ? "/" : directory + "/"
        let filtered: [String]
        if edited == directory {
            filtered = available
        } else if edited.hasPrefix(prefix) {
            let suffix = String(edited.dropFirst(prefix.count))
            filtered = suffix.contains("/") ? [] : available.filter {
                $0.localizedStandardContains(suffix)
            }
        } else {
            // A separately typed path must not leave unrelated old entries visible.
            return []
        }
        return (parent == nil ? [] : [".."]) + filtered
    }

    func path(for name: String) -> String? {
        guard let directory, rows.contains(name) else { return nil }
        if name == ".." { return parent }
        return (directory as NSString).appendingPathComponent(name)
    }

    var selectedPath: String? {
        guard let selectedName, selectedName != ".." else { return nil }
        return path(for: selectedName)
    }

    var addPath: String? {
        guard host != nil, !isLoading else { return nil }
        if selectedName == ".." { return nil }
        if let selectedPath { return selectedPath }
        guard let path = Self.remotePath(input) else { return nil }
        if path == directory { return showingDrives ? nil : directory }
        return path
    }

    var enterPath: String? {
        guard host != nil else { return nil }
        if selectedName == ".." { return parent }
        if let selectedPath { return selectedPath }
        guard let requested = Self.remotePath(input), requested != directory else { return nil }
        return requested
    }

    func editInput(_ text: String) {
        input = text
        inputRevision &+= 1
        selectedName = nil
        errorMessage = nil
    }

    func moveSelection(_ step: Int) {
        let available = rows
        guard !available.isEmpty else { return }
        let previous = selectedName.flatMap { available.firstIndex(of: $0) }
            ?? (step > 0 ? -1 : available.count)
        selectedName = available[max(0, min(available.count - 1, previous + step))]
    }

    func invalidate() {
        isActive = false
        requestID &+= 1
    }

    /// Normalize a remote path without ever interpreting it on the Mac filesystem.
    static func remotePath(_ raw: String) -> String? {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count == 2, let letter = path.first, path.last == ":",
           letter.isASCII && letter.isLetter {
            return "/" + letter.lowercased()
        }
        let normalized = SSHHostWorkspaces.normalizedPath(path)
        guard normalized.hasPrefix("/"), !normalized.contains("\0"),
              !normalized.contains("\n"), !normalized.contains("\r") else { return nil }
        return (normalized as NSString).standardizingPath
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

    func selectHost(_ alias: String) async {
        guard isActive, hosts.contains(alias) else { return }
        requestID &+= 1
        let request = requestID
        host = alias
        directory = nil
        pendingPath = nil
        folders = []
        windowsDrives = []
        input = ""
        selectedName = nil
        errorMessage = nil
        isLoading = true
        do {
            let command = "cd && pwd -P && case \"$(uname -s)\" in "
                + "MSYS*|MINGW*|CYGWIN*) for drive in c d e f g h i j k l m n o p q r s t u v w x y z; do "
                + "if [ -d \"/$drive\" ]; then printf 'DRIVE:%s\\n' \"$drive\"; fi; "
                + "done ;; esac"
            let result = try await backendForHost(alias).run(
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
            guard isCurrent(request, host: alias) else { return }
            windowsDrives = location.drives
            await navigate(to: location.drives.isEmpty ? location.home : "/")
        } catch {
            guard isCurrent(request, host: alias) else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func navigate(to rawPath: String) async {
        guard let host, isActive else { return }
        guard let destination = Self.remotePath(rawPath) else {
            errorMessage = String(
                localized: "Enter an absolute remote folder path.", table: "Terminal"
            )
            return
        }
        if isLoading, pendingPath == destination { return }
        requestID &+= 1
        let request = requestID
        let editRevision = inputRevision
        input = destination == "/" ? "/" : destination + "/"
        pendingPath = destination
        directory = nil
        folders = []
        selectedName = nil
        isLoading = true
        errorMessage = nil

        if destination == "/", !windowsDrives.isEmpty {
            directory = destination
            pendingPath = nil
            folders = windowsDrives
            isLoading = false
            return
        }
        do {
            let backend = backendForHost(host)
            guard let stat = try await backend.stat(path: destination) else {
                throw FolderIssue.missing(destination)
            }
            guard stat.isDirectory else { throw FolderIssue.file(destination) }
            let entries = try await backend.list(directory: destination)
            guard isCurrent(request, host: host) else { return }
            directory = destination
            pendingPath = nil
            folders = entries.filter {
                $0.isDirectory && $0.name != "." && $0.name != ".."
                    && !$0.name.contains("/") && !$0.name.contains("\0")
            }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if inputRevision == editRevision {
                input = destination == "/" ? "/" : destination + "/"
            }
            isLoading = false
        } catch {
            guard isCurrent(request, host: host) else { return }
            isLoading = false
            pendingPath = nil
            errorMessage = error.localizedDescription
        }
    }

    func confirm(onChoose: @MainActor (String, String) -> Void) async {
        guard let host, let target = addPath, isActive else { return }
        requestID &+= 1
        let request = requestID
        isLoading = true
        errorMessage = nil
        do {
            guard let stat = try await backendForHost(host).stat(path: target),
                  stat.isDirectory || stat.isRegular else {
                throw FolderIssue.missing(target)
            }
            guard isCurrent(request, host: host) else { return }
            isLoading = false
            onChoose(host, target)
        } catch {
            guard isCurrent(request, host: host) else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func isCurrent(_ request: Int, host: String) -> Bool {
        isActive && request == requestID && self.host == host
    }
}
