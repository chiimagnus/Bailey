import Foundation
import XCTest
@testable import Bailey

private actor PickerBackend: WorkspaceBackend {
    let startup: Data
    let directories: [String: [WorkspaceEntry]]
    let files: Set<String>
    private(set) var runCount = 0
    private(set) var statCounts: [String: Int] = [:]
    private var heldPaths = Set<String>()
    private var blocked: [String: CheckedContinuation<WorkspaceStat?, Error>] = [:]
    private var observers: [String: CheckedContinuation<Void, Never>] = [:]

    init(
        startup: String,
        directories: [String: [WorkspaceEntry]],
        files: Set<String> = []
    ) {
        self.startup = Data(startup.utf8)
        self.directories = directories
        self.files = files
    }

    func hold(_ path: String) { heldPaths.insert(path) }

    func waitForStat(_ path: String) async {
        if blocked[path] != nil { return }
        await withCheckedContinuation { observers[path] = $0 }
    }

    func release(_ path: String) {
        heldPaths.remove(path)
        blocked.removeValue(forKey: path)?.resume(returning: metadata(for: path))
    }

    private func metadata(for path: String) -> WorkspaceStat? {
        guard directories[path] != nil || files.contains(path) else { return nil }
        return WorkspaceStat(
            isRegular: files.contains(path),
            isDirectory: directories[path] != nil,
            isSymlink: false, size: 0, mtime: .distantPast
        )
    }

    func stat(path: String) async throws -> WorkspaceStat? {
        statCounts[path, default: 0] += 1
        if heldPaths.contains(path) {
            return try await withCheckedThrowingContinuation { continuation in
                blocked[path] = continuation
                observers.removeValue(forKey: path)?.resume()
            }
        }
        if path == "/error" { throw WorkspaceError.timedOut }
        return metadata(for: path)
    }

    func list(directory: String) async throws -> [WorkspaceEntry] {
        guard let entries = directories[directory] else { throw WorkspaceError.notFound }
        return entries
    }

    func run(
        argv: [String], cwd: String?, env: [String: String]?,
        stdin: Data?, timeout: TimeInterval?
    ) async throws -> WorkspaceRunResult {
        runCount += 1
        return WorkspaceRunResult(status: 0, stdout: startup, stderr: Data())
    }

    func readSymlinkDestination(path: String) async throws -> String? { nil }
    func read(path: String, maxBytes: Int) async throws -> Data { throw WorkspaceError.notFound }
    func write(path: String, data: Data) async throws { throw WorkspaceError.notFound }
    func createFile(path: String) async throws { throw WorkspaceError.notFound }
    func createDirectory(path: String) async throws { throw WorkspaceError.notFound }
    func copy(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func rename(from: String, to: String) async throws { throw WorkspaceError.notFound }
    func delete(paths: [String]) async throws { throw WorkspaceError.notFound }
}

@MainActor
final class SSHFolderPickerTests: XCTestCase {
    private func folder(_ name: String) -> WorkspaceEntry {
        WorkspaceEntry(name: name, isDirectory: true, isSymlink: false)
    }

    func testOpeningDoesNotConnectAndRejectsUnlistedHost() async {
        let backend = PickerBackend(startup: "/home/user\n", directories: [:])
        let model = SSHFolderPickerModel(hosts: ["server"], backendForHost: { _ in backend })
        XCTAssertNil(model.host)
        XCTAssertNil(model.directory)
        XCTAssertNil(model.addPath)
        XCTAssertFalse(model.isLoading)
        let initialCalls = await backend.runCount
        XCTAssertEqual(initialCalls, 0)
        await model.selectHost("unknown")
        XCTAssertNil(model.host)
        let callsAfterInvalidHost = await backend.runCount
        XCTAssertEqual(callsAfterInvalidHost, 0)
    }

    func testWindowsRootAndDriveSelection() async {
        let backend = PickerBackend(
            startup: "/c/Users/Admin\nDRIVE:d\nDRIVE:c\n",
            directories: [
                "/d": [folder("Projects"), folder(".hidden")],
                "/d/Projects": [],
            ]
        )
        let model = SSHFolderPickerModel(hosts: ["windows"], backendForHost: { _ in backend })
        await model.selectHost("windows")
        XCTAssertEqual(model.host, "windows")
        XCTAssertEqual(model.directory, "/")
        XCTAssertEqual(model.rows, ["c", "d"])
        XCTAssertNil(model.addPath, "The virtual disk overview is not a remote project")
        model.selectedName = "d"
        XCTAssertEqual(model.addPath, "/d")
        XCTAssertEqual(model.enterPath, "/d")
        await model.navigate(to: "/d")
        XCTAssertEqual(model.input, "/d/")
        XCTAssertEqual(model.rows, ["..", "Projects"])
        XCTAssertEqual(model.parent, "/")
        model.showHidden = true
        XCTAssertEqual(model.rows, ["..", ".hidden", "Projects"])
        model.selectedName = ".hidden"
        model.showHidden = false
        XCTAssertNil(model.selectedName)
        await model.navigate(to: "/")
        XCTAssertEqual(model.rows, ["c", "d"])
    }

    func testTypedAndKeyboardSelectionDoNotSelectStaleFolder() async {
        let backend = PickerBackend(
            startup: "/home/user\n",
            directories: ["/home/user": [folder("Alpha"), folder("Beta")],
                          "/home/user/Alpha": []]
        )
        let model = SSHFolderPickerModel(hosts: ["server"], backendForHost: { _ in backend })
        await model.selectHost("server")
        XCTAssertEqual(model.rows, ["..", "Alpha", "Beta"])
        model.moveSelection(1)
        XCTAssertEqual(model.selectedName, "..")
        XCTAssertNil(model.addPath)
        model.moveSelection(1)
        XCTAssertEqual(model.selectedName, "Alpha")
        XCTAssertEqual(model.enterPath, "/home/user/Alpha")
        model.editInput("/home/user/B")
        XCTAssertNil(model.selectedName)
        XCTAssertEqual(model.rows, ["..", "Beta"])
        XCTAssertEqual(model.enterPath, "/home/user/B")
        model.editInput("relative")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.addPath)
        XCTAssertNil(model.enterPath)
        await model.navigate(to: "/home/user/Alpha")
        XCTAssertEqual(model.directory, "/home/user/Alpha")
        XCTAssertEqual(model.input, "/home/user/Alpha/")
        XCTAssertNil(model.enterPath, "Return on the current folder must not submit it")
        XCTAssertEqual(model.addPath, "/home/user/Alpha")
    }

    func testNavigationCommitsInputBeforeSSHResponseAndDiscardsOlderResponse() async {
        let backend = PickerBackend(
            startup: "/home/user\n",
            directories: [
                "/home/user": [], "/slow": [folder("Obsolete")],
                "/fast": [folder("Current")],
            ]
        )
        let model = SSHFolderPickerModel(hosts: ["server"], backendForHost: { _ in backend })
        await model.selectHost("server")
        await backend.hold("/slow")
        let old = Task { await model.navigate(to: "/slow") }
        await backend.waitForStat("/slow")
        XCTAssertEqual(model.input, "/slow/", "The entered path updates before remote IO ends")
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.directory)
        XCTAssertTrue(model.rows.isEmpty)
        await model.navigate(to: "/slow")
        let duplicateCount = await backend.statCounts["/slow"]
        XCTAssertEqual(duplicateCount, 1, "Repeated Return must not spawn duplicate SSH requests")
        await model.navigate(to: "/fast")
        XCTAssertEqual(model.directory, "/fast")
        XCTAssertEqual(model.rows, ["..", "Current"])
        await backend.release("/slow")
        await old.value
        XCTAssertEqual(model.directory, "/fast")
        XCTAssertEqual(model.input, "/fast/")
        XCTAssertEqual(model.rows, ["..", "Current"])
    }

    func testTypingWhileRemoteRequestIsPendingNeverGetsOverwritten() async {
        let backend = PickerBackend(
            startup: "/home/user\n",
            directories: ["/home/user": [], "/slow": [folder("Folder")]]
        )
        let model = SSHFolderPickerModel(hosts: ["server"], backendForHost: { _ in backend })
        await model.selectHost("server")
        await backend.hold("/slow")
        let request = Task { await model.navigate(to: "/slow") }
        await backend.waitForStat("/slow")
        model.editInput("/typed-by-user")
        await backend.release("/slow")
        await request.value
        XCTAssertEqual(model.directory, "/slow")
        XCTAssertEqual(model.input, "/typed-by-user")
        XCTAssertTrue(model.rows.isEmpty, "Never show unrelated items under a different typed path")
    }

    func testHostSwitchAndCancellationIgnoreDelayedRemoteResults() async {
        let first = PickerBackend(startup: "/home/one\n",
                                  directories: ["/home/one": []])
        let second = PickerBackend(startup: "/home/two\n",
                                   directories: ["/home/two": []])
        let model = SSHFolderPickerModel(hosts: ["one", "two"], backendForHost: {
            $0 == "one" ? first : second
        })
        await first.hold("/home/one")
        let old = Task { await model.selectHost("one") }
        await first.waitForStat("/home/one")
        await model.selectHost("two")
        XCTAssertEqual(model.host, "two")
        XCTAssertEqual(model.directory, "/home/two")
        await first.release("/home/one")
        await old.value
        XCTAssertEqual(model.host, "two")
        XCTAssertEqual(model.directory, "/home/two")

        await second.hold("/home/two")
        let delayed = Task { await model.navigate(to: "/home/two") }
        await second.waitForStat("/home/two")
        model.invalidate()
        await second.release("/home/two")
        await delayed.value
        XCTAssertNil(model.directory)
    }

    func testFailedNavigationPreservesUserEnteredPath() async {
        let backend = PickerBackend(
            startup: "/home/user\n",
            directories: ["/home/user": [folder("Existing")]]
        )
        let model = SSHFolderPickerModel(hosts: ["server"], backendForHost: { _ in backend })
        await model.selectHost("server")
        await model.navigate(to: "/error")
        XCTAssertEqual(model.input, "/error/")
        XCTAssertNil(model.directory)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        model.editInput("/home/user")
        XCTAssertNil(model.errorMessage)
        await model.navigate(to: model.input)
        XCTAssertEqual(model.directory, "/home/user")
    }

    func testPastedFilePathStillAddsFilesWithoutListingThem() async {
        let backend = PickerBackend(
            startup: "/home/user\n",
            directories: ["/home/user": []],
            files: ["/home/user/file.swift"]
        )
        let model = SSHFolderPickerModel(hosts: ["server"], backendForHost: { _ in backend })
        await model.selectHost("server")
        model.editInput("/home/user/file.swift")
        var choice: (String, String)?
        await model.confirm { choice = ($0, $1) }
        XCTAssertEqual(choice?.0, "server")
        XCTAssertEqual(choice?.1, "/home/user/file.swift")
    }

    func testCancelledValidationCannotCreateAProject() async {
        let backend = PickerBackend(
            startup: "/home/user\n",
            directories: ["/home/user": []]
        )
        let model = SSHFolderPickerModel(hosts: ["server"], backendForHost: { _ in backend })
        await model.selectHost("server")
        await backend.hold("/home/user")
        var wasAdded = false
        let request = Task {
            await model.confirm { _, _ in wasAdded = true }
        }
        await backend.waitForStat("/home/user")
        model.invalidate()
        await backend.release("/home/user")
        await request.value
        XCTAssertFalse(wasAdded)
    }

    func testPastedFileShowsActionableFeedbackAndCanStillBeAdded() async {
        let backend = PickerBackend(
            startup: "/home/user\n",
            directories: ["/home/user": []],
            files: ["/home/user/file.txt"]
        )
        let model = SSHFolderPickerModel(hosts: ["server"], backendForHost: { _ in backend })
        await model.selectHost("server")
        await model.navigate(to: "/home/user/file.txt")
        XCTAssertEqual(model.input, "/home/user/file.txt/")
        XCTAssertNil(model.directory)
        XCTAssertNotNil(model.errorMessage)
        var result: String?
        await model.confirm { _, path in result = path }
        XCTAssertEqual(result, "/home/user/file.txt")
    }

    func testUnicodeAndLargeDirectoryNavigation() async {
        let many = (0..<1500).map { folder("Folder-\($0)") }
        let backend = PickerBackend(
            startup: "/home/user\n",
            directories: ["/home/user": many + [
                folder("中文 空格"), folder("目录 🧪"), folder(".secret")
            ]]
        )
        let model = SSHFolderPickerModel(hosts: ["server"], backendForHost: { _ in backend })
        await model.selectHost("server")
        XCTAssertEqual(model.rows.count, 1503, "1 parent and 1502 visible folders")
        model.editInput("/home/user/中文")
        XCTAssertEqual(model.rows, ["..", "中文 空格"])
        model.moveSelection(1)
        model.moveSelection(1)
        XCTAssertEqual(model.enterPath, "/home/user/中文 空格")
    }

    func testWindowsPathNormalizationAndInvalidInputs() {
        XCTAssertEqual(SSHFolderPickerModel.remotePath("D:"), "/d")
        XCTAssertEqual(SSHFolderPickerModel.remotePath("D:\\GitHub\\Bailey"), "/d/GitHub/Bailey")
        XCTAssertEqual(SSHFolderPickerModel.remotePath("/a/../b"), "/b")
        XCTAssertNil(SSHFolderPickerModel.remotePath("relative"))
        XCTAssertNil(SSHFolderPickerModel.remotePath("/foo\nbar"))
        XCTAssertNil(SSHFolderPickerModel.remotePath("/foo\0bar"))
    }

}
