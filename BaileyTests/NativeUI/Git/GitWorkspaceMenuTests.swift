import AppKit
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
final class GitWorkspaceMenuTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

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
        let manager = self.workspaceApplication.makeWindow()
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
        let manager = self.workspaceApplication.makeWindow()
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
        let manager = self.workspaceApplication.makeWindow()
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

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let model = GitStatusModel()
        manager.syncGitStatus(model)
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

    func testGitChangeRowPreviewKeepsNativeKeyboardAndUsesCorrectIndexSide() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-git-preview-" + UUID().uuidString)
        let root = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        func git(_ args: [String]) -> String {
            let result = GitCommandExecution.run(args, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.name", "Preview Test"])
        _ = git(["config", "user.email", "preview@invalid"])
        _ = git(["config", "commit.gpgsign", "false"])
        let file = root.appendingPathComponent("alpha.swift")
        try "baseline\n".write(to: file, atomically: true, encoding: .utf8)
        _ = git(["add", "alpha.swift"])
        _ = git(["commit", "-qm", "baseline"])
        try "staged\n".write(to: file, atomically: true, encoding: .utf8)
        _ = git(["add", "alpha.swift"])
        try "worktree\n".write(to: file, atomically: true, encoding: .utf8)
        let headBefore = git(["rev-parse", "HEAD"])
        let indexBefore = git(["rev-parse", ":alpha.swift"])
        let worktreeBefore = git(["hash-object", "alpha.swift"])

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        project.dock.select(.git)
        let gitGroup = try XCTUnwrap(project.dock.group(containing: .git))
        let model = GitStatusModel()
        manager.syncGitStatus(model)
        try await wait { model.hasResolvedStatus && !model.isRefreshing }
        XCTAssertEqual(model.stagedEntries.map(\.path), ["alpha.swift"],
                       "Unexpected staged entries or status error: \(model.statusError ?? "none")")
        XCTAssertEqual(model.changedEntries.map(\.path), ["alpha.swift"],
                       "Unexpected worktree entries or status error: \(model.statusError ?? "none")")
        let settings = AppSettings(configURL: sandbox.appendingPathComponent("settings.toml"))
        settings.gitViewMode = .list
        let width: CGFloat = 450
        let height: CGFloat = 680
        let window = NSWindow(
            contentRect: NSRect(x: -1200, y: -1200, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: GitPanel(
            settings: settings, model: model, manager: manager, project: project,
            session: nil, sshHost: nil, openFile: { _ in },
            openDiff: { entry, staged in
                manager.openDiff(repoRoot: model.repoRoot, path: entry.path,
                                 staged: staged, untracked: entry.isUntracked,
                                 origPath: entry.origPath, activating: false)
            },
            openCommitDiff: { commit, file in
                manager.openCommitDiff(
                    repoRoot: model.repoRoot, path: file.path,
                    commitHash: commit.hash, parentHash: commit.parentHashes.first,
                    status: file.status, origPath: file.originalPath,
                    activating: false
                )
            }
        ).frame(width: width, height: height))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return findTreeKeyboard(in: host) != nil
        }
        let receiver = try XCTUnwrap(findTreeKeyboard(in: host))
        XCTAssertTrue(window.makeFirstResponder(receiver))

        let openChanges = String(localized: "Open Changes", table: "Sidebar")
        let unstage = String(localized: "Unstage Changes", table: "Sidebar")
        let stage = String(localized: "Stage Changes", table: "Sidebar")
        func yOfRow(with action: String) -> CGFloat? {
            for y in stride(from: Int(height - 10), through: 12, by: -4) {
                guard let event = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: NSPoint(x: 75, y: CGFloat(y)),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ) else { continue }
                let titles = window.contentView?.menu(for: event)?.items.map(\.title) ?? []
                if titles.contains(openChanges) && titles.contains(action) { return CGFloat(y) }
            }
            return nil
        }
        let stagedY = try XCTUnwrap(yOfRow(with: unstage), "Staged file row must be hittable")
        let changedY = try XCTUnwrap(yOfRow(with: stage), "Unstaged file row must be hittable")
        XCTAssertGreaterThan(stagedY, changedY)
        func click(x: CGFloat, y: CGFloat) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ))
                window.sendEvent(event)
            }
        }
        try click(x: 75, y: stagedY)
        try await wait { project.tabs.count == 1 }
        guard case .diff(let stagedDiff)? = project.selectedTab?.content else {
            return XCTFail("Clicking staged changes must create a DiffTab")
        }
        try await wait { stagedDiff.hasLoadedContent }
        XCTAssertEqual(stagedDiff.source, .staged)
        XCTAssertEqual(stagedDiff.path, "alpha.swift")
        XCTAssertEqual(stagedDiff.oldContent, "baseline\n")
        XCTAssertEqual(stagedDiff.newContent, "staged\n")
        XCTAssertEqual(project.dock.activeGroupID, gitGroup.id)
        XCTAssertTrue(window.firstResponder === receiver, "Git must retain its keyboard receiver")

        func press(_ code: UInt16, characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ))
            window.sendEvent(event)
        }
        try press(125, characters: "\u{F701}") // Down moves focus, not the displayed Diff.
        guard case .diff(let displayedBeforeSpace)? = project.selectedTab?.content else {
            return XCTFail("Keyboard navigation must keep the displayed DiffTab")
        }
        XCTAssertTrue(displayedBeforeSpace === stagedDiff,
                      "The grey preview selection must not follow the blue keyboard cursor")
        try press(49, characters: " ")         // Space previews like a row click
        try await wait { project.tabs.count == 2 }
        guard case .diff(let worktreeDiff)? = project.selectedTab?.content else {
            return XCTFail("Return must open the worktree side as a separate DiffTab")
        }
        try await wait { worktreeDiff.hasLoadedContent }
        XCTAssertEqual(worktreeDiff.source, .worktree)
        XCTAssertEqual(worktreeDiff.path, "alpha.swift")
        XCTAssertEqual(worktreeDiff.oldContent, "staged\n")
        XCTAssertEqual(worktreeDiff.newContent, "worktree\n")
        XCTAssertEqual(project.dock.activeGroupID, gitGroup.id)
        XCTAssertTrue(window.firstResponder === receiver)
        XCTAssertEqual(git(["rev-parse", "HEAD"]), headBefore)
        XCTAssertEqual(git(["rev-parse", ":alpha.swift"]), indexBefore)
        XCTAssertEqual(git(["hash-object", "alpha.swift"]), worktreeBefore)

        // Inline buttons must perform only their Git operation, never browse a Diff.
        try click(x: width - 22, y: changedY)
        try await wait {
            model.changedEntries.isEmpty && model.stagedEntries.count == 1
                && !model.isBusy && !model.isRefreshing
        }
        XCTAssertEqual(git(["rev-parse", ":alpha.swift"]), worktreeBefore)
        XCTAssertEqual(project.tabs.count, 2, "Stage must not open another Diff")
        XCTAssertEqual(project.dock.activeGroupID, gitGroup.id)
        let unstagingY = try XCTUnwrap(yOfRow(with: unstage))
        try click(x: width - 22, y: unstagingY)
        try await wait {
            model.stagedEntries.isEmpty && model.changedEntries.count == 1
                && !model.isBusy && !model.isRefreshing
        }
        XCTAssertEqual(git(["diff", "--cached", "--name-only"]), "")
        XCTAssertEqual(git(["rev-parse", "HEAD"]), headBefore)
        XCTAssertEqual(git(["hash-object", "alpha.swift"]), worktreeBefore)
        XCTAssertEqual(project.tabs.count, 2, "Unstage must not open another Diff")

        try await wait { model.graphCommits.count > 0 }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        try await wait {
            host.layoutSubtreeIfNeeded()
            return descendants(host).compactMap { $0 as? TreeKeyboardView }.count >= 2
        }
        let graphReceiver = try XCTUnwrap(descendants(host)
            .compactMap { $0 as? TreeKeyboardView }
            .first { $0 !== receiver })
        let createBranch = String(localized: "Create Branch at Commit…", table: "Git")
        func graphCommitY() -> CGFloat? {
            for y in stride(from: Int(height - 12), through: 12, by: -4) {
                guard let event = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: NSPoint(x: 155, y: CGFloat(y)),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ) else { continue }
                if window.contentView?.menu(for: event)?.items.contains(where: {
                    $0.title == createBranch
                }) == true { return CGFloat(y) }
            }
            return nil
        }
        let graphY = try XCTUnwrap(graphCommitY(), "Graph commit must be mouse-hittable")
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try click(x: 155, y: graphY)
        XCTAssertTrue(window.firstResponder === graphReceiver,
                      "Clicking a Graph commit must release Git Changes' native keyboard")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(window.firstResponder === graphReceiver,
                      "Key-window restoration must not pull Graph focus back to Changes")
        try press(49, characters: " ") // Space toggles the clicked Graph commit
        XCTAssertEqual(project.tabs.count, 2,
                       "Toggling a Graph commit must not open a Diff or mutate Git")
        XCTAssertTrue(window.firstResponder === graphReceiver)
        try press(49, characters: " ") // Reopen that commit's historical file list
        try press(125, characters: "\u{F701}") // Down selects its first history file
        try press(49, characters: " ") // Space previews the actual historical Diff
        try await wait { project.tabs.count == 3 }
        guard case .diff(let historyDiff)? = project.selectedTab?.content else {
            return XCTFail("Graph Space must open the selected historical Diff")
        }
        try await wait { historyDiff.hasLoadedContent }
        XCTAssertEqual(historyDiff.source,
                       .commit(hash: headBefore, parent: nil, status: "A"))
        XCTAssertEqual(historyDiff.oldContent, "")
        XCTAssertEqual(historyDiff.newContent, "baseline\n")
        XCTAssertEqual(project.dock.activeGroupID, gitGroup.id)
        XCTAssertTrue(window.firstResponder === graphReceiver)

        let input = try XCTUnwrap(descendants(host)
            .compactMap { $0 as? NSTextField }
            .first { $0.isEditable && $0.isEnabled },
            "The commit message must be a real native text field")
        XCTAssertTrue(window.makeFirstResponder(input))
        let oldText = input.currentEditor()?.string ?? input.stringValue
        try press(49, characters: " ")
        let edited = input.currentEditor()?.string ?? input.stringValue
        XCTAssertEqual(edited, oldText + " ",
                       "Space must type into the commit field, not activate a Graph row")
        XCTAssertFalse(window.firstResponder === graphReceiver)
        XCTAssertFalse(window.firstResponder === receiver)
        XCTAssertEqual(project.tabs.count, 3)
        XCTAssertEqual(git(["rev-parse", "HEAD"]), headBefore)

    }

    func testStaleGitChangeClickCannotOpenDiffInAnotherProject() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-git-stale-focus-" + UUID().uuidString)
        let firstRoot = sandbox.appendingPathComponent("first")
        let secondRoot = sandbox.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        func git(_ args: [String]) {
            let result = GitCommandExecution.run(args, in: firstRoot.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "Focus Test"])
        git(["config", "user.email", "focus@invalid"])
        git(["config", "commit.gpgsign", "false"])
        try "original\n".write(to: firstRoot.appendingPathComponent("first.txt"),
                               atomically: true, encoding: .utf8)
        git(["add", "first.txt"])
        git(["commit", "-qm", "baseline"])
        try "modified\n".write(to: firstRoot.appendingPathComponent("first.txt"),
                               atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([firstRoot, secondRoot])
        let firstIndex = try XCTUnwrap(manager.projects.firstIndex {
            $0.customDirectory == firstRoot.path
        })
        let secondIndex = try XCTUnwrap(manager.projects.firstIndex {
            $0.customDirectory == secondRoot.path
        })
        manager.selectProject(index: firstIndex)
        let firstProject = try XCTUnwrap(manager.selectedProject)
        firstProject.dock.select(.git)
        let model = GitStatusModel()
        manager.syncGitStatus(model)
        try await wait {
            model.hasResolvedStatus && !model.isRefreshing
                && model.changedEntries.map(\.path) == ["first.txt"]
        }
        let window = NSWindow(contentRect: NSRect(x: -1200, y: -1200, width: 460, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: GitPanel(
            model: model, manager: manager, project: firstProject,
            session: nil, sshHost: nil, openFile: { _ in },
            openDiff: { entry, staged in
                manager.openDiff(repoRoot: model.repoRoot, path: entry.path,
                                 staged: staged, untracked: entry.isUntracked,
                                 origPath: entry.origPath, activating: false)
            }, openCommitDiff: { commit, file in
                manager.openCommitDiff(
                    repoRoot: model.repoRoot, path: file.path,
                    commitHash: commit.hash, parentHash: commit.parentHashes.first,
                    status: file.status, origPath: file.originalPath,
                    activating: false
                )
            }
        ).frame(width: 460, height: 650))
        window.contentView = host
        window.orderFront(nil)
        let openChanges = String(localized: "Open Changes", table: "Sidebar")
        let stage = String(localized: "Stage Changes", table: "Sidebar")
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.findTreeKeyboard(in: host) != nil
        }
        func rowY(x: CGFloat, matching titles: [String]) -> CGFloat? {
            for y in stride(from: 640, through: 12, by: -4) {
                guard let event = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: NSPoint(x: x, y: CGFloat(y)),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1
                ) else { continue }
                let actions = window.contentView?.menu(for: event)?.items.map(\.title) ?? []
                if titles.allSatisfy(actions.contains) { return CGFloat(y) }
            }
            return nil
        }
        func click(x: CGFloat, y: CGFloat) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ))
                window.sendEvent(event)
            }
        }
        let changedY = try XCTUnwrap(rowY(x: 95, matching: [openChanges, stage]),
                                     "The original project must have an actionable change row")
        let graphY = try XCTUnwrap(rowY(x: 155, matching: [
            String(localized: "Create Branch at Commit…", table: "Git")
        ]), "The original project's graph commit must be actionable")
        try click(x: 155, y: graphY)
        var historyY: CGFloat?
        try await wait {
            host.layoutSubtreeIfNeeded()
            historyY = rowY(x: 155, matching: [String(localized: "Open Historical Diff", table: "Git")])
            return historyY != nil
        }
        manager.selectProject(index: secondIndex)
        let secondProject = try XCTUnwrap(manager.selectedProject)
        XCTAssertFalse(firstProject === secondProject)
        try click(x: 95, y: changedY)
        let tabsAfterChanges = secondProject.tabs.count
        XCTAssertEqual(tabsAfterChanges, 0,
                       "A stale Git Changes row must not open a diff in another project")
        try click(x: 155, y: try XCTUnwrap(historyY))
        XCTAssertEqual(secondProject.tabs.count, tabsAfterChanges,
                       "A stale Git Graph file must not open another project's history diff")
        XCTAssertTrue(firstProject.tabs.isEmpty,
                      "Old Git rows must not browse in the inactive project")
        let indexBefore = GitCommandExecution.run(["diff", "--cached", "--name-only"],
                                                 in: firstRoot.path)
        XCTAssertEqual(indexBefore.status, 0)
        XCTAssertEqual(indexBefore.stdout, "")
        try click(x: 460 - 22, y: changedY)
        try await Task.sleep(for: .milliseconds(600))
        let indexAfter = GitCommandExecution.run(["diff", "--cached", "--name-only"],
                                                in: firstRoot.path)
        XCTAssertEqual(indexAfter.status, 0)
        XCTAssertEqual(indexAfter.stdout, "",
                       "A stale Stage button must not modify the inactive repository's index")
    }

    func testGitChangesTreeKeyboardBrowsesNestedFilesWithoutWritingIndex() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-git-tree-keys-" + UUID().uuidString)
        let root = sandbox.appendingPathComponent("repo")
        let folder = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        func git(_ args: [String]) -> String {
            let result = GitCommandExecution.run(args, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.name", "Tree Navigation"])
        _ = git(["config", "user.email", "tree@invalid"])
        _ = git(["config", "commit.gpgsign", "false"])
        for name in ["alpha.txt", "beta.txt"] {
            try "old \(name)\n".write(to: folder.appendingPathComponent(name),
                                        atomically: true, encoding: .utf8)
        }
        _ = git(["add", "nested"])
        _ = git(["commit", "-qm", "two files"])
        let headBefore = git(["rev-parse", "HEAD"])
        for name in ["alpha.txt", "beta.txt"] {
            try "new \(name)\n".write(to: folder.appendingPathComponent(name),
                                        atomically: true, encoding: .utf8)
        }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        project.dock.select(.git)
        let model = GitStatusModel()
        manager.syncGitStatus(model)
        try await wait {
            model.hasResolvedStatus && !model.isRefreshing && model.changedEntries.count == 2
        }
        let settings = AppSettings(configURL: sandbox.appendingPathComponent("settings.toml"))
        settings.gitViewMode = .tree
        let window = NSWindow(contentRect: NSRect(x: -1200, y: -1200, width: 460, height: 660),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: GitPanel(
            settings: settings, model: model, manager: manager, project: project,
            session: nil, sshHost: nil, openFile: { _ in },
            openDiff: { entry, staged in
                manager.openDiff(repoRoot: model.repoRoot, path: entry.path,
                                 staged: staged, untracked: entry.isUntracked,
                                 origPath: entry.origPath, activating: false)
            }, openCommitDiff: { _, _ in }
        ).frame(width: 460, height: 660))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.treeKeyboards(in: host).count == 2
        }
        let receiver = try XCTUnwrap(treeKeyboards(in: host).first)
        XCTAssertTrue(window.makeFirstResponder(receiver))
        func press(_ code: UInt16, characters: String) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await press(124, characters: "\u{F703}") // Expand the first folder or select its child.
        try await press(49, characters: " ") // Browse nested/alpha.txt.
        try await wait { project.tabs.count == 1 }
        guard case .diff(let alpha)? = project.selectedTab?.content else {
            return XCTFail("Space should open the first nested DiffTab")
        }
        try await wait { alpha.hasLoadedContent }
        XCTAssertEqual(alpha.path, "nested/alpha.txt")
        XCTAssertEqual(alpha.oldContent, "old alpha.txt\n")
        XCTAssertEqual(alpha.newContent, "new alpha.txt\n")
        XCTAssertTrue(window.firstResponder === receiver)
        try await press(125, characters: "\u{F701}")
        try await press(36, characters: "\r") // Return browses the second sibling.
        try await wait { project.tabs.count == 2 }
        guard case .diff(let beta)? = project.selectedTab?.content else {
            return XCTFail("Return should open the second nested DiffTab")
        }
        try await wait { beta.hasLoadedContent }
        XCTAssertEqual(beta.path, "nested/beta.txt")
        XCTAssertEqual(beta.oldContent, "old beta.txt\n")
        XCTAssertEqual(beta.newContent, "new beta.txt\n")
        XCTAssertEqual(project.dock.activeGroup?.selected, .git)
        XCTAssertTrue(window.firstResponder === receiver)
        try await press(123, characters: "\u{F702}") // Select parent folder.
        try await press(123, characters: "\u{F702}") // Collapse parent.
        XCTAssertEqual(git(["rev-parse", "HEAD"]), headBefore)
        XCTAssertEqual(git(["diff", "--cached", "--name-only"]), "")
    }

    private func findTreeKeyboard(in view: NSView) -> TreeKeyboardView? {
        if let keyboard = view as? TreeKeyboardView { return keyboard }
        return view.subviews.lazy.compactMap { self.findTreeKeyboard(in: $0) }.first
    }

    func testGitGraphIsKeyboardReadyWhenRepositoryHasNoChangedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-graph-only-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) {
            let result = GitCommandExecution.run(args, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "Graph Only"])
        git(["config", "user.email", "graph@invalid"])
        git(["config", "commit.gpgsign", "false"])
        try "history\n".write(to: root.appendingPathComponent("note.txt"),
                              atomically: true, encoding: .utf8)
        git(["add", "note.txt"])
        git(["commit", "-qm", "history"])

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        project.dock.select(.git)
        let model = GitStatusModel()
        manager.syncGitStatus(model)
        try await wait {
            model.hasResolvedStatus && model.canUseCurrentStatus
                && model.graphCommits.count == 1 && model.totalChangeCount == 0
        }
        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 100, width: 450, height: 660),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var opened: [String] = []
        let host = NSHostingView(rootView: GitPanel(
            model: model, manager: manager, project: project, session: nil, sshHost: nil,
            openFile: { _ in }, openDiff: { _, _ in },
            openCommitDiff: { _, file in opened.append(file.path) }
        ).frame(width: 450, height: 660))
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.treeKeyboards(in: host).count == 2
        }
        let owners = treeKeyboards(in: host)
        let graph = try XCTUnwrap(owners.last)
        if window.isKeyWindow && NSApp.isActive {
            try await wait {
                host.layoutSubtreeIfNeeded()
                return window.firstResponder === graph
            }
        } else {
            // Xcode's isolated XCTest host may never gain foreground activation.
            // Exercise the real NSWindow responder and keyboard path without
            // pretending this verified automatic key-window activation.
            XCTAssertTrue(window.makeFirstResponder(graph))
        }
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49
        ))
        window.sendEvent(key) // Expand the initially selected commit
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125
        ))
        window.sendEvent(down)
        window.sendEvent(key) // Browse its first file without switching panels
        try await wait { opened == ["note.txt"] }
        XCTAssertTrue(window.firstResponder === graph)
        XCTAssertTrue(project.tabs.isEmpty, "The callback fixture is not a real editor")
    }

    private func treeKeyboards(in view: NSView) -> [TreeKeyboardView] {
        (view as? TreeKeyboardView).map { [$0] }
            ?? view.subviews.flatMap { self.treeKeyboards(in: $0) }
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
        let manager = self.workspaceApplication.makeWindow()
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
        manager.syncGitStatus(model)
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

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let model = GitStatusModel()
        manager.syncGitStatus(model)
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
