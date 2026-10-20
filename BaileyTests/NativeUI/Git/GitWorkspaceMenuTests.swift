import AppKit
import SwiftUI
import XCTest
@testable import Bailey

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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-ignore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = GitCommandExecution.run(["init", "-q"], in: root.path)
        XCTAssertEqual(result.status, 0, result.stderr)
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
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

    func testIgnoreReloadsCleanCachedFileBeforeAppendingWithoutMountedView() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-ignore-external-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let path = root.appendingPathComponent(".gitignore")
        try Data("cached-rule\n".utf8).write(to: path)
        project.openFile(path.path)
        guard case .file(let file) = project.selectedTab?.content else {
            return XCTFail("Expected cached file tab")
        }
        try await file.waitForText()
        XCTAssertEqual(file.text, "cached-rule\n")
        try Data("external-rule\n".utf8).write(to: path)
        XCTAssertEqual(file.text, "cached-rule\n", "File remains cached until explicitly consumed")
        let context = try XCTUnwrap(project.panelContext)
        try await project.ignoreGitPaths(["new-rule.txt"], isDirectory: false, repository: root.path,
                                         context: context, isCurrent: { true })
        let expected = "external-rule\n/new-rule.txt\n"
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), expected,
                       "Non-view Git Ignore must preserve external edits, not write a stale cached baseline")
        XCTAssertEqual(file.text, expected)
        XCTAssertFalse(file.isDirty)
    }

    func testIgnoreCreatesOrdinaryFileTabAndRejectsStaleTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-ignore-create-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
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
            .appendingPathComponent("bailey-ignore-menu-" + UUID().uuidString)
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
        manager.addLocalFolders([root])
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-uncommitted-sheet-" + UUID().uuidString)
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
        manager.addLocalFolders([root])
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

    func testFolderInlineStageAndUnstageAffectOnlyThatDirectory() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-folder-buttons-" + UUID().uuidString)
        let root = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        func git(_ args: [String]) -> String {
            let result = GitCommandExecution.run(args, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "Folder Button Test"])
        git(["config", "user.email", "folder@invalid"])
        git(["config", "commit.gpgsign", "false"])
        for path in ["inside/one.txt", "inside/two.txt", "outside/keep.txt"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "original".write(to: file, atomically: true, encoding: .utf8)
        }
        git(["add", "."])
        git(["commit", "-qm", "base"])
        for path in ["inside/one.txt", "inside/two.txt", "outside/keep.txt"] {
            try "modified".write(to: root.appendingPathComponent(path),
                                 atomically: true, encoding: .utf8)
        }

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let model = GitStatusModel()
        model.syncSelectedProject(in: manager)
        try await wait { model.hasResolvedStatus && !model.isRefreshing && model.changedEntries.count == 3 }
        let width: CGFloat = 440
        let height: CGFloat = 640
        let window = NSWindow(
            contentRect: NSRect(x: -1200, y: -1200, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GitPanel(
            settings: AppSettings(configURL: sandbox.appendingPathComponent("settings.toml")),
            model: model, manager: manager, project: manager.selectedProject,
            session: nil, sshHost: nil, openFile: { _ in },
            openDiff: { _, _ in }, openCommitDiff: { _, _ in }
        ).frame(width: width, height: height))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))

        func folderY(menu expected: String) -> CGFloat? {
            for y in stride(from: Int(height - 8), through: 8, by: -4) {
                guard let event = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: NSPoint(x: 85, y: CGFloat(y)),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1
                ) else { continue }
                let titles = window.contentView?.menu(for: event)?.items.map(\.title) ?? []
                if titles.contains(expected)
                    && !titles.contains(String(localized: "Open File", table: "Sidebar")) {
                    return CGFloat(y)
                }
            }
            return nil
        }
        func clickAction(y: CGFloat, x: CGFloat = width - 23) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: x, y: y),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1
                )!
                window.sendEvent(event)
            }
        }
        let stage = String(localized: "Stage Changes", table: "Sidebar")
        let folderBefore = try XCTUnwrap(folderY(menu: stage), "Expected CHANGES folder row")
        let collapsedBefore = model.collapsedFolders
        clickAction(y: folderBefore)
        try await wait { model.stagedEntries.count == 2 && !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(model.collapsedFolders, collapsedBefore,
                       "Right-side action must not collapse the directory")
        XCTAssertEqual(Set(git(["diff", "--cached", "--name-only"]).split(separator: "\n").map(String.init)),
                       Set(["inside/one.txt", "inside/two.txt"]))
        XCTAssertTrue(model.changedEntries.contains { $0.path == "outside/keep.txt" })

        let unstage = String(localized: "Unstage Changes", table: "Sidebar")
        let stagedFolder = try XCTUnwrap(folderY(menu: unstage), "Expected STAGED folder row")
        clickAction(y: stagedFolder)
        try await wait { model.stagedEntries.isEmpty && !model.isBusy && !model.isRefreshing }
        XCTAssertEqual(git(["diff", "--cached", "--name-only"]), "")
        XCTAssertEqual(model.changedEntries.count, 3)

        let folderForDiscard = try XCTUnwrap(folderY(menu: stage), "Expected CHANGES folder")
        clickAction(y: folderForDiscard, x: width - 45)
        try await wait { window.attachedSheet != nil }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("inside/one.txt"),
                                  encoding: .utf8), "modified",
                       "The inline discard button must require confirmation")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("outside/keep.txt"),
                                  encoding: .utf8), "modified")
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let confirm = try XCTUnwrap(descendants(try XCTUnwrap(sheet.contentView))
            .compactMap { $0 as? NSButton }
            .first { $0.title == String(localized: "Discard Changes", table: "Sidebar") })
        XCTAssertNotEqual(confirm.title, String(localized: "Discard All Changes", table: "Sidebar"))
        confirm.performClick(nil)
        try await wait {
            !model.isBusy && !model.isRefreshing && model.changedEntries.count == 1
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("inside/one.txt"),
                                  encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("inside/two.txt"),
                                  encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("outside/keep.txt"),
                                  encoding: .utf8), "modified")
    }
}
