import AppKit
import SwiftUI
import XCTest
@testable import kero

@MainActor
final class GitWorkspaceMenuTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() {
            guard Date() < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testUncommittedDialogDefaultsAndPermanentCleanWarning() {
        let target = GitStatusModel().actionTarget()
        let stash = GitUncommittedDialog(action: .stash, target: target)
        XCTAssertEqual(stash.message.stringValue, "")
        XCTAssertEqual(stash.includeUntracked.state, .on)
        XCTAssertEqual(stash.alert.buttons[0].title, String(localized: "Yes, Stash", table: "Git"))
        let reset = GitUncommittedDialog(action: .reset, target: target)
        XCTAssertEqual(reset.resetMode.numberOfItems, 2)
        XCTAssertEqual(reset.resetMode.indexOfSelectedItem, 0)
        let clean = GitUncommittedDialog(action: .clean, target: target)
        XCTAssertEqual(clean.directories.state, .on)
        XCTAssertTrue(clean.alert.informativeText.contains(String(localized:
            "Permanently delete untracked files, including directories when selected. Ignored files are kept. This does not move files to the Trash.", table: "Git")))
        XCTAssertEqual(clean.alert.buttons.count, 2)
        XCTAssertEqual(clean.alert.buttons[1].keyEquivalent, "\u{1b}")
    }

    func testIgnoreAppendsNativeBufferSavesAndCanUndoWithoutRemounting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kero-ignore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = GitCommandExecution.run(["init", "-q"], in: root.path)
        XCTAssertEqual(result.status, 0, result.stderr)
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let path = root.appendingPathComponent(".gitignore").path
        try Data("existing-rule\r\n".utf8).write(to: URL(fileURLWithPath: path))
        project.openFile(path)
        guard case .file(let file) = project.selectedTab?.content else { return XCTFail("File tab missing") }
        let window = NSWindow(contentRect: NSRect(x: -1200, y: -1200, width: 550, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FileViewerView(file: file))
        window.orderFront(nil)
        defer { window.close() }
        try await wait { file.textView != nil }
        let native = try XCTUnwrap(file.textView)
        file.appendText("unsaved-rule")
        XCTAssertTrue(file.isDirty)
        let before = file.text
        let revision = file.reloadRevision
        let names = ["literal*.txt", "literal?.txt", "[abc].txt", "#hash", "!bang", "back\\slash", "trailing "]
        let context = try XCTUnwrap(project.panelContext)
        try await project.ignoreGitPaths(names, isDirectory: false, repository: root.path,
                                         context: context, isCurrent: { true })
        XCTAssertTrue(file.textView === native)
        XCTAssertEqual(file.reloadRevision, revision)
        XCTAssertEqual(native.text, file.text)
        XCTAssertTrue(file.text.hasPrefix(before + "\r\n"))
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), file.text)
        for name in names {
            let ignored = GitCommandExecution.run(["check-ignore", "--no-index", "--", name], in: root.path)
            XCTAssertEqual(ignored.status, 0, name + ": " + ignored.stderr)
        }
        XCTAssertEqual(GitCommandExecution.run(["check-ignore", "--no-index", "other.txt"], in: root.path).status, 1)
        native.undoManager?.undo()
        XCTAssertEqual(native.text, before)
        XCTAssertEqual(file.text, before)
        XCTAssertTrue(file.isDirty)
        XCTAssertThrowsError(try GitStatusModel.ignorePatterns(["bad\nrule"], isDirectory: false))
        file.autoSaveSuspendedForClose = true
    }

    func testIgnoreCreatesOrdinaryFileTabAndRejectsStaleTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kero-ignore-create-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let context = try XCTUnwrap(project.panelContext)
        try await project.ignoreGitPaths(["build"], isDirectory: true, repository: root.path,
                                         context: context, isCurrent: { true })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8), "/build/\n")
        guard case .file(let file) = project.selectedTab?.content else { return XCTFail("Ordinary FileTab required") }
        XCTAssertFalse(file.isDirty)
        do {
            try await project.ignoreGitPaths(["other"], isDirectory: false, repository: root.path,
                                             context: context, isCurrent: { false })
            XCTFail("Stale target must be rejected")
        } catch is CancellationError {} catch { XCTFail(error.localizedDescription) }
        XCTAssertEqual(file.text, "/build/\n")
    }

    func testIgnoreContextMenuIsOnlyOfferedForUntrackedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-ignore-menu-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) {
            let result = GitCommandExecution.run(arguments, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "Ignore Menu Test"])
        git(["config", "user.email", "ignore@invalid"])
        try "original".write(to: root.appendingPathComponent("aa-tracked.txt"),
                             atomically: true, encoding: .utf8)
        git(["add", "aa-tracked.txt"])
        git(["-c", "commit.gpgsign=false", "commit", "-qm", "baseline"])
        try "modified".write(to: root.appendingPathComponent("aa-tracked.txt"),
                             atomically: true, encoding: .utf8)
        try "intent".write(to: root.appendingPathComponent("za-intent.txt"),
                           atomically: true, encoding: .utf8)
        git(["add", "-N", "za-intent.txt"])
        try "new".write(to: root.appendingPathComponent("zz-untracked.txt"),
                        atomically: true, encoding: .utf8)

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let model = GitStatusModel()
        model.syncSelectedProject(in: manager)
        try await wait {
            model.hasResolvedStatus && !model.isRefreshing && model.changedEntries.count == 3
        }
        XCTAssertEqual(Set(model.changedEntries.map(\.path)),
                       Set(["aa-tracked.txt", "za-intent.txt", "zz-untracked.txt"]))
        let intent = try XCTUnwrap(model.changedEntries.first { $0.path == "za-intent.txt" })
        XCTAssertTrue(intent.isIntentToAdd)
        let window = NSWindow(
            contentRect: NSRect(x: -1200, y: -1200, width: 460, height: 680),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GitPanel(
            model: model, manager: manager, project: manager.selectedProject,
            session: nil, sshHost: nil, openFile: { _ in },
            openDiff: { _, _ in }, openCommitDiff: { _, _ in }
        ).frame(width: 460, height: 680))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))

        let openFile = String(localized: "Open File", table: "Sidebar")
        let stage = String(localized: "Stage Changes", table: "Sidebar")
        let ignore = String(localized: "Add to .gitignore", table: "Git")
        var menuSamples: [(y: Int, titles: [String])] = []
        for y in stride(from: 670, through: 15, by: -5) {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 120, y: CGFloat(y)),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1
            ))
            let titles = window.contentView?.menu(for: event)?.items.map(\.title) ?? []
            let isFileRow = titles.contains(openFile) && titles.contains(stage)
            if isFileRow { menuSamples.append((y, titles)) }
        }
        let first = try XCTUnwrap(menuSamples.first)
        let last = try XCTUnwrap(menuSamples.last)
        let rowHeight = Int(TreeRowStyle.rowHeight(1))
        XCTAssertGreaterThan(first.y - last.y, rowHeight * 2,
            "All three CHANGES rows must be visible and independently hit-tested")
        let middle = try XCTUnwrap(menuSamples.first { $0.y <= first.y - rowHeight })
        XCTAssertFalse(first.titles.contains(ignore),
            "Tracked changes cannot be ignored via .gitignore")
        XCTAssertFalse(middle.titles.contains(ignore),
            "Intent-to-add is already in the index and is not affected by .gitignore")
        XCTAssertTrue(last.titles.contains(ignore),
            "Untracked changes must retain the Ignore action")
    }

    func testUncommittedSheetCancelAndConfirmReachRealStash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kero-uncommitted-sheet-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) -> String {
            let result = GitCommandExecution.run(arguments, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.name", "Sheet Test"])
        _ = git(["config", "user.email", "sheet@invalid"])
        _ = git(["config", "commit.gpgsign", "false"])
        _ = git(["commit", "--allow-empty", "-qm", "base"])
        let untracked = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: untracked)
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let window = NSWindow(contentRect: NSRect(x: -1200, y: -1200, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        window.orderFront(nil)
        defer { window.close() }
        let model = GitStatusModel()
        model.syncSelectedProject(in: manager)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        let panel = GitPanel(model: model, manager: manager, project: project, session: nil,
            sshHost: nil, openFile: { _ in }, openDiff: { _, _ in }, openCommitDiff: { _, _ in })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        panel.presentUncommittedDialog(.stash)
        try await wait { window.attachedSheet != nil }
        let cancel = try XCTUnwrap(descendants(try XCTUnwrap(window.attachedSheet?.contentView))
            .compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Cancel", table: "Sidebar") })
        cancel.performClick(nil)
        try await wait { window.attachedSheet == nil }
        XCTAssertEqual(git(["stash", "list"]), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: untracked.path))
        panel.presentUncommittedDialog(.stash)
        try await wait { window.attachedSheet != nil }
        let controls = descendants(try XCTUnwrap(window.attachedSheet?.contentView))
        let field = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == String(localized: "Message (optional)", table: "Git") })
        field.stringValue = "native sheet message"
        let confirm = try XCTUnwrap(controls.compactMap { $0 as? NSButton }
            .first { $0.title == String(localized: "Yes, Stash", table: "Git") })
        confirm.performClick(nil)
        try await wait { window.attachedSheet == nil && !model.isBusy && !model.isRefreshing }
        XCTAssertNil(model.lastError)
        XCTAssertTrue(git(["stash", "list"]).contains("native sheet message"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: untracked.path))
    }
}
