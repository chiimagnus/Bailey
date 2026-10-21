import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
@Observable
private final class FilesPanelReadiness {
    var ready = false
}

@MainActor
private final class FocusRecordingWindow: NSWindow {
    var hasPalette: () -> Bool = { false }
    private(set) var treeFocusAttemptsBehindPalette = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is TreeKeyboardView, hasPalette() {
            treeFocusAttemptsBehindPalette += 1
        }
        return super.makeFirstResponder(responder)
    }
}

/// Two full workspaces in separate native windows. The current key window is
/// not a valid substitute for the manager that owns a file or its save target.
@MainActor
final class WorkspaceWindowIsolationTests: XCTestCase {
    @MainActor private lazy var workspaceApplication = WorkspaceApplication()

    private func hasForegroundKeyWindow(_ window: NSWindow) async -> Bool {
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func testAsyncFilesTargetBecomingCurrentRestoresVisibleFileCursor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("alpha.swift")
        let second = directory.appendingPathComponent("beta.swift")
        for path in [first, second] {
            try "unchanged\n".write(to: path, atomically: true, encoding: .utf8)
        }
        let tree = FileTreeModel()
        await tree.sync(root: directory.path, backend: LocalWorkspaceBackend.shared)
        let gate = FilesPanelReadiness()
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 440, height: 250),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var opened = 0
        let host = NSHostingView(rootView: FileTreePanel(
            model: tree, git: GitStatusModel(), session: nil, sshHost: nil,
            rootBadge: nil, currentFilePath: second.path,
            openFile: { _, _ in opened += 1 },
            onRename: { _, _ in }, refreshGitStatus: {},
            isCurrentTarget: { gate.ready },
            canImportFromFinder: false, importFromFinder: { _, _ in false }
        ))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(tree.selectedPath, "An outdated Files target cannot select a row")
        gate.ready = true
        try await wait {
            host.layoutSubtreeIfNeeded()
            return tree.selectedPath == second.path
        }
        XCTAssertEqual(opened, 0, "Target readiness must not open a FileTab")
    }

    func testFilesCursorDoesNotActivateBehindPaletteBeforeSearchFieldFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha.swift", "beta.swift"] {
            try "unchanged\n".write(to: root.appendingPathComponent(name),
                                      atomically: true, encoding: .utf8)
        }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        project.dock.select(.git)
        manager.toggleCommandPalette()
        manager.showPanel(.files)

        // This assertion does not require a foreground key window: the
        // Palette owns input before SwiftUI installs its native field editor.
        let window = NSWindow(
            contentRect: NSRect(x: -1200, y: -1200, width: 1100, height: 620),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.attachedWindow === window && project.fileTree.items.count == 2
        }
        XCTAssertTrue(manager.isCommandPaletteVisible)
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
        XCTAssertNil(project.fileTree.selectedPath,
                     "Files cannot install its keyboard cursor under a pending Palette")

        manager.dismissCommandPalette()
        try await wait {
            host.layoutSubtreeIfNeeded()
            return project.fileTree.selectedPath == root.appendingPathComponent("alpha.swift").path
        }
        XCTAssertEqual(project.tabs.count, 0,
                       "Recovering Files selection must not open an editor automatically")
    }

    func testCancelingCommandPaletteRestoresFilesRowKeyboardNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha.swift", "beta.swift"] {
            try "unchanged\n".write(
                to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        project.dock.select(.files)

        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 1200, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        guard await hasForegroundKeyWindow(window) else {
            throw XCTSkip("Native Files focus requires a foreground XCTest key window")
        }
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.attachedWindow === window
                && project.fileTree.items.count == 2
                && window.firstResponder is TreeKeyboardView
        }
        let first = try XCTUnwrap(project.fileTree.selectedPath)
        XCTAssertEqual((first as NSString).lastPathComponent, "alpha.swift")
        manager.toggleCommandPalette()
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.isCommandPaletteVisible
                && (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        manager.dismissCommandPalette()
        try await wait {
            host.layoutSubtreeIfNeeded()
            return !manager.isCommandPaletteVisible
                && window.firstResponder is TreeKeyboardView
        }
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125
        ))
        window.sendEvent(key)
        try await wait {
            project.fileTree.selectedPath == root.appendingPathComponent("beta.swift").path
        }
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
        XCTAssertEqual(project.tabs.count, 0)

        // Executing a palette action must not later restore the displaced Files row.
        manager.openFile(root.appendingPathComponent("beta.swift").path)
        let workTab = try XCTUnwrap(project.selectedTab)
        project.dock.select(.files)
        try await wait { window.firstResponder is TreeKeyboardView }
        let displaced = window.firstResponder
        manager.toggleCommandPalette()
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.isCommandPaletteVisible
                && (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        manager.dismissCommandPalette(restoringFocus: false)
        project.selectTab(workTab.id)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return !manager.isCommandPaletteVisible
                && project.dock.activeGroup?.selected == .tab(workTab.id)
                && window.firstResponder is FocusReportingTextView
        }
        XCTAssertFalse(window.firstResponder === displaced)
    }

    func testCurrentToolTreeResponderFollowsDockGroupAfterPanelSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "unchanged\n".write(
            to: root.appendingPathComponent("file.swift"), atomically: true, encoding: .utf8)
        let commands = [
            ["init", "-q", "-b", "main"], ["add", "file.swift"],
            ["-c", "user.name=Test", "-c", "user.email=test@invalid", "commit", "-qm", "baseline"]
        ]
        for arguments in commands {
            let result = GitCommandExecution.run(arguments, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let project = Project(fallbackName: "focus scope", workspaceConfiguration: .standard)
        project.customDirectory = root.path
        manager.projects = [project]
        manager.selectedProjectID = project.id
        let window = NSWindow(
            contentRect: NSRect(x: -1100, y: -1100, width: 1200, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.orderFront(nil)
        project.dock.select(.files)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.activeTreeResponder(in: window) != nil
        }
        let filesReceiver = try XCTUnwrap(manager.activeTreeResponder(in: window))
        XCTAssertTrue(filesReceiver.window === window)
        project.dock.select(.git)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.activeTreeResponder(in: window) != nil
                && manager.activeTreeResponder(in: window) !== filesReceiver
        }
        XCTAssertFalse(manager.activeTreeResponder(in: window) === filesReceiver,
                       "Restoring Git must not select the hidden Files responder")
        let gitReceiver = try XCTUnwrap(manager.activeTreeResponder(in: window))
        project.dock.select(.files)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.activeTreeResponder(in: window) != nil
                && manager.activeTreeResponder(in: window) !== gitReceiver
        }
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
    }

    func testEditorPaletteSwitchToFilesRestoresNewToolKeyboardFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha.swift", "beta.swift"] {
            try "unchanged\n".write(to: root.appendingPathComponent(name),
                                      atomically: true, encoding: .utf8)
        }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        manager.openFile(root.appendingPathComponent("alpha.swift").path)
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 1200, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.attachedWindow === window && self.editor(in: host) != nil
        }
        guard await hasForegroundKeyWindow(window) else {
            throw XCTSkip("Foreground key window is required to validate native palette focus")
        }
        let oldEditor = try XCTUnwrap(editor(in: host))
        XCTAssertTrue(window.makeFirstResponder(oldEditor))
        XCTAssertTrue(manager.ownsActiveResponder(oldEditor))
        manager.toggleCommandPalette()
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.isCommandPaletteVisible
                && (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        manager.showPanel(.files)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return project.dock.activeGroup?.selected == .files
                && project.fileTree.items.count == 2
        }
        XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true,
                      "The palette still owns input while Files becomes visible")
        manager.dismissCommandPalette()
        try await wait {
            host.layoutSubtreeIfNeeded()
            return !manager.isCommandPaletteVisible
                && window.firstResponder === manager.activeTreeResponder(in: window)
        }
        let first = project.fileTree.selectedPath
        XCTAssertNotNil(first)
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125
        ))
        window.sendEvent(down)
        try await wait { project.fileTree.selectedPath != first }
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
    }

    func testSwitchingToFilesBehindCommandPaletteDoesNotStealItsSearchField() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha.swift", "beta.swift"] {
            try "unchanged\n".write(to: root.appendingPathComponent(name),
                                      atomically: true, encoding: .utf8)
        }
        let commands = [
            ["init", "-q", "-b", "main"], ["add", "alpha.swift", "beta.swift"],
            ["-c", "user.name=Test", "-c", "user.email=test@invalid", "commit", "-qm", "baseline"]
        ]
        for arguments in commands {
            let result = GitCommandExecution.run(arguments, in: root.path)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        project.dock.select(.git)
        let window = FocusRecordingWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 1200, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await wait { host.layoutSubtreeIfNeeded(); return manager.attachedWindow === window }
        guard await hasForegroundKeyWindow(window) else {
            throw XCTSkip("Native overlay focus requires a foreground XCTest key window; cannot seize the user's Bailey")
        }
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.activeTreeResponder(in: window) != nil
        }
        let gitReceiver = try XCTUnwrap(manager.activeTreeResponder(in: window))
        XCTAssertTrue(window.makeFirstResponder(gitReceiver))
        window.hasPalette = { [weak manager] in manager?.isCommandPaletteVisible == true }
        manager.toggleCommandPalette()
        // Switch immediately, before the search field can become first responder.
        manager.showPanel(.files)
        host.layoutSubtreeIfNeeded()
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.isCommandPaletteVisible
                && (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        XCTAssertEqual(window.treeFocusAttemptsBehindPalette, 0,
                       "Files must not even request keyboard focus behind a pending Palette")
        try await wait {
            host.layoutSubtreeIfNeeded()
            return project.dock.activeGroup?.selected == .files
                && project.fileTree.items.count == 2
        }
        // The palette is an actual overlay, not an instruction to focus the hidden tool.
        XCTAssertTrue(manager.isCommandPaletteVisible)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true,
                      "File Manager becoming visible must not steal Palette's text input")
        manager.dismissCommandPalette()
        try await wait {
            host.layoutSubtreeIfNeeded()
            return !manager.isCommandPaletteVisible
                && window.firstResponder === manager.activeTreeResponder(in: window)
        }
        let first = project.fileTree.selectedPath
        XCTAssertNotNil(first)
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125
        ))
        window.sendEvent(down)
        try await wait { project.fileTree.selectedPath != first }
    }

    func testCancelingCommandPaletteRestoresGitTreeKeyboardNavigation() async throws {
        for dirty in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            func git(_ args: [String]) throws {
                let result = GitCommandExecution.run(args, in: root.path)
                XCTAssertEqual(result.status, 0, result.stderr)
            }
            try git(["init", "-q", "-b", "main"])
            try git(["config", "user.name", "Palette Focus Test"])
            try git(["config", "user.email", "palette@invalid"])
            try git(["config", "commit.gpgsign", "false"])
            try "committed\n".write(to: root.appendingPathComponent("file.txt"),
                                      atomically: true, encoding: .utf8)
            try git(["add", "file.txt"])
            try git(["commit", "-qm", "history"])
            if dirty {
                try "modified\n".write(to: root.appendingPathComponent("file.txt"),
                                         atomically: true, encoding: .utf8)
            }

            let manager = self.workspaceApplication.makeWindow()
            defer { manager.windowClosed() }
            manager.addLocalFolders([root])
            let project = try XCTUnwrap(manager.selectedProject)
            project.dock.select(.git)
            let window = NSWindow(
                contentRect: NSRect(x: -1000, y: -1000, width: 1200, height: 700),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: ContentView(manager: manager))
            window.contentView = host
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            guard await hasForegroundKeyWindow(window) else {
                throw XCTSkip("Native Git focus requires a foreground XCTest key window")
            }
            try await wait {
                host.layoutSubtreeIfNeeded()
                return manager.attachedWindow === window
                    && window.firstResponder is TreeKeyboardView
            }
            let previous = try XCTUnwrap(window.firstResponder as? TreeKeyboardView)
            manager.toggleCommandPalette()
            try await wait {
                host.layoutSubtreeIfNeeded()
                return manager.isCommandPaletteVisible
                    && (window.firstResponder as? NSTextView)?.isFieldEditor == true
            }
            manager.dismissCommandPalette()
            try await wait {
                host.layoutSubtreeIfNeeded()
                return !manager.isCommandPaletteVisible && window.firstResponder === previous
            }
            XCTAssertEqual(project.dock.activeGroup?.selected, .git)
            XCTAssertEqual(project.tabs.count, 0)
        }
    }

    func testFilesActivationBeforeDirectoryListingFocusesFirstVisibleRowWhenLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("alpha.swift")
        let second = root.appendingPathComponent("beta.swift")
        for file in [first, second] {
            try "original\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let tree = FileTreeModel()
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 380, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var browsed = 0
        let host = NSHostingView(rootView: FileTreePanel(
            model: tree, git: GitStatusModel(), session: nil, sshHost: nil,
            rootBadge: nil, currentFilePath: nil,
            openFile: { _, _ in browsed += 1 },
            onRename: { _, _ in }, refreshGitStatus: {}, isCurrentTarget: { true },
            canImportFromFinder: false, importFromFinder: { _, _ in false }
        ))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(tree.selectedPath)
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return tree.selectedPath == first.path
        }
        XCTAssertEqual(browsed, 0, "Focusing Files must not open files automatically")
        XCTAssertEqual(tree.items.count, 2)
    }

    func testFilesInlineRenameAndDraftExitRestoreNativeTreeKeyboardFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alpha.swift", "beta.swift"] {
            try "unchanged\n".write(to: root.appendingPathComponent(name),
                                      atomically: true, encoding: .utf8)
        }
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let window = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 440, height: 250),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileTreePanel(
            model: tree, git: GitStatusModel(), session: nil, sshHost: nil,
            rootBadge: nil, currentFilePath: nil, openFile: { _, _ in },
            onRename: { _, _ in }, refreshGitStatus: {}, isCurrentTarget: { true },
            canImportFromFinder: false, importFromFinder: { _, _ in false }
        ))
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        guard await hasForegroundKeyWindow(window) else {
            throw XCTSkip("Native input requires a foreground key window")
        }
        try await wait {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder is TreeKeyboardView && tree.selectedItem != nil
        }
        let first = try XCTUnwrap(tree.selectedItem)
        tree.beginRename(first)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        tree.cancelRename()
        try await wait {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder is TreeKeyboardView
        }
        await tree.beginNewFile(in: root.path)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        await tree.cancelDraft()
        try await wait {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder is TreeKeyboardView
        }
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125
        ))
        window.sendEvent(down)
        try await wait { tree.selectedPath == root.appendingPathComponent("beta.swift").path }
    }

    func testFilesTreeClickTransfersNativeKeyboardAndArrowsMoveTheVisibleCursor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("alpha.swift")
        let second = directory.appendingPathComponent("beta.swift")
        for path in [first, second] {
            try "unchanged\n".write(to: path, atomically: true, encoding: .utf8)
        }
        let tree = FileTreeModel()
        await tree.sync(root: directory.path, backend: LocalWorkspaceBackend.shared)
        XCTAssertEqual(tree.items.count, 2)
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 380, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var opened: [(String, Bool)] = []
        let host = NSHostingView(rootView: FileTreePanel(
            model: tree, git: GitStatusModel(), session: nil, sshHost: nil,
            rootBadge: nil, currentFilePath: nil,
            openFile: { opened.append(($0, $1)) },
            onRename: { _, _ in }, refreshGitStatus: {}, isCurrentTarget: { true },
            canImportFromFinder: false, importFromFinder: { _, _ in false }
        ))
        let surface = NSView(frame: window.contentView?.bounds ?? .zero)
        let focusReader = DockGroupFocusView(groupID: UUID())
        focusReader.frame = surface.bounds
        focusReader.isActive = true
        focusReader.focusesEmptySpace = true
        focusReader.canFocus = { true }
        surface.addSubview(focusReader)
        host.frame = surface.bounds
        surface.addSubview(host)
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        for y in stride(from: CGFloat(211), through: 19, by: -8) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let click = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 130, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ))
                window.sendEvent(click)
            }
            try await Task.sleep(for: .milliseconds(20))
            if !opened.isEmpty { break }
        }
        XCTAssertEqual(opened.count, 1, "The native click must actually browse a file")
        XCTAssertNotNil(tree.selectedPath, "The clicked file must have a row cursor")
        let focused = try XCTUnwrap(window.firstResponder)
        focusReader.requestFocusAfterClick()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(window.firstResponder === focused,
                      "Dock fallback must not replace a SwiftUI row's first responder")
        for (keyCode, text, expected) in [
            (UInt16(126), "\u{F700}", first.path),
            (UInt16(125), "\u{F701}", second.path),
        ] {
            let key = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: keyCode
            ))
            window.sendEvent(key)
            try await wait { tree.selectedPath == expected }
        }
        func sendKey(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ))
            window.sendEvent(event)
        }
        try sendKey(125, "\u{F701}", modifiers: [.command])
        XCTAssertEqual(tree.selectedPath, second.path, "Modified shortcuts must not navigate Files")
        try sendKey(49, " ")
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(opened.last?.0, second.path)
        XCTAssertEqual(opened.last?.1, false, "Space previews without activating editor")
        try sendKey(36, "\r")
        XCTAssertEqual(opened.last?.1, true, "Return explicitly activates editor")
        try sendKey(53, "\u{1b}")
        XCTAssertNil(tree.selectedPath, "Escape clears the row cursor")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "unchanged\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "unchanged\n")
    }

    func testDockIntegratedFilesRowsKeepNativeFocusWhenOpeningAnotherPane() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("alpha.swift")
        let second = directory.appendingPathComponent("beta.swift")
        for path in [first, second] {
            try "doNotEdit\n".write(to: path, atomically: true, encoding: .utf8)
        }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([directory])
        let project = try XCTUnwrap(manager.selectedProject)
        manager.openFile(second.path)
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 1450, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return project.fileTree.rootPath == directory.path && project.fileTree.items.count == 2
        }
        let oldEditor = try XCTUnwrap(editor(in: host))
        XCTAssertTrue(window.makeFirstResponder(oldEditor),
                      "Reproduce the existing editor owning keyboard input before the Files click")
        // Synthetic NSWindow.sendEvent bypasses NSEvent's Dock click monitor.
        // Explicitly model the user switching the active Dock group to Files.
        project.dock.select(.files)
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
        let x: CGFloat = 1290
        for y in stride(from: CGFloat(590), through: 425, by: -5) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(20))
            if project.tabs.count == 2 { break }
        }
        XCTAssertNotNil(project.fileTree.selectedPath, "Integrated Files must have a current row")
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
        try await wait { project.tabs.count == 2 }
        XCTAssertFalse(window.firstResponder === oldEditor,
                       "Clicking Files must release the old native editor first responder")
        XCTAssertFalse(window.firstResponder is DockGroupFocusView,
                       "The Files keyboard receiver, not a Dock background, must own input")
        func scopes(in view: NSView) -> [DockGroupFocusView] {
            (view as? DockGroupFocusView).map { [$0] } ?? view.subviews.flatMap(scopes(in:))
        }
        let filesGroup = try XCTUnwrap(project.dock.group(containing: .files))
        let reader = try XCTUnwrap(scopes(in: host).first { $0.groupID == filesGroup.id })
        // A separate active Bailey window can keep this test process non-key.
        // Model the same positive activation predicates as a real key-window click.
        reader.isActive = true
        reader.focusesEmptySpace = true
        reader.canFocus = { true }
        reader.requestFocusAfterClick()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(window.firstResponder === reader,
                       "A late Dock fallback must not replace a focused Files keyboard row")
        for (keyCode, text, expected) in [
            (UInt16(126), "\u{F700}", first.path),
            (UInt16(125), "\u{F701}", second.path),
        ] {
            let key = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: keyCode
            ))
            window.sendEvent(key)
            try await wait { project.fileTree.selectedPath == expected }
        }
        XCTAssertEqual(project.dock.activeGroup?.selected, .files,
                       "Arrow navigation must not activate the editor group")
        project.dock.select(.git)
        host.layoutSubtreeIfNeeded()
        let gitGroup = try XCTUnwrap(project.dock.group(containing: .git))
        let gitReader = try XCTUnwrap(scopes(in: host).first { $0.groupID == gitGroup.id })
        gitReader.isActive = true
        gitReader.canFocus = { true }
        gitReader.focusesEmptySpace = true
        gitReader.requestFocusAfterClick()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(window.firstResponder === gitReader,
                      "Switching from a Files row to Git must release the old row responder")
        project.dock.select(.files)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return project.dock.activeGroup?.selected == .files
                && (!(window.isKeyWindow && NSApp.isActive)
                    || window.firstResponder !== gitReader)
        }
        XCTAssertEqual(project.fileTree.selectedPath, second.path,
                       "Reentering Files must retain its existing file cursor")
        if window.isKeyWindow && NSApp.isActive {
            let up = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
                isARepeat: false, keyCode: 126
            ))
            window.sendEvent(up)
            try await wait { project.fileTree.selectedPath == first.path }
            XCTAssertEqual(project.dock.activeGroup?.selected, .files)
        }
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "doNotEdit\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "doNotEdit\n")
    }

    func testSwitchingToFileManagerSelectsVisibleCurrentFileAndTakesNativeKeyboard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("alpha.swift")
        let second = directory.appendingPathComponent("beta.swift")
        for file in [first, second] {
            try "original\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([directory])
        manager.openFile(second.path)
        let project = try XCTUnwrap(manager.selectedProject)
        XCTAssertNil(project.fileTree.selectedPath)
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 1450, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return project.fileTree.rootPath == directory.path && project.fileTree.items.count == 2
        }
        let editor = try XCTUnwrap(editor(in: host))
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertNotEqual(project.dock.activeGroup?.selected, .files)
        project.dock.select(.files)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return project.fileTree.selectedPath == second.path
                && (!(window.isKeyWindow && NSApp.isActive)
                    || window.firstResponder !== editor)
        }
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
        if window.isKeyWindow && NSApp.isActive {
            let up = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
                isARepeat: false, keyCode: 126
            ))
            window.sendEvent(up)
            try await wait { project.fileTree.selectedPath == first.path }
        }
        XCTAssertEqual(project.tabs.count, 1, "Activating File Manager must not create a new FileTab")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "original\n")
    }

    func testFilesOpenedInItsOwnDockGroupDoNotRetainHiddenKeyboardFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("same-group.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let configuration = try XCTUnwrap(DockWorkspaceConfiguration(
            groupNames: ["projects,files,git"], selectedNames: ["files"],
            weights: [1], actionNames: ["session", "projects", "files", "git"], edgeThreshold: 0.22
        ))
        let project = Project(fallbackName: "one-group", workspaceConfiguration: configuration)
        project.customDirectory = root.path
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.projects = [project]
        manager.selectedProjectID = project.id
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: 900, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return project.fileTree.rootPath == root.path && project.fileTree.items.count == 1
        }
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
        for y in stride(from: CGFloat(570), through: 540, by: -4) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let click = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 90, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ))
                window.sendEvent(click)
            }
            try await Task.sleep(for: .milliseconds(15))
            if project.tabs.count == 1 { break }
        }
        XCTAssertEqual(project.fileTree.selectedPath, file.path)
        XCTAssertEqual(project.tabs.count, 1, "The native click must open the file")
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.editor(in: host) != nil
        }
        let tab = try XCTUnwrap(project.selectedTab)
        XCTAssertEqual(project.dock.activeGroup?.selected, .tab(tab.id),
                       "When the only Files panel is replaced, the visible editor must own the group")
        let editor = try XCTUnwrap(editor(in: host))
        XCTAssertFalse(editor.isHiddenOrHasHiddenAncestor)
        if NSApp.isActive && window.isKeyWindow {
            try await wait { window.firstResponder === editor }
        } else {
            XCTAssertTrue(window.makeFirstResponder(editor),
                          "The visible editor must accept keyboard input in a non-key test window")
        }
        XCTAssertEqual(window.firstResponder as? NSView, editor)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 1\n")
    }

    func testDockGroupClickDoesNotPreemptNativeFieldFocus() async throws {
        let bounds = NSRect(x: 0, y: 0, width: 560, height: 280)
        let window = NSWindow(contentRect: bounds, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: bounds)
        let oldEditor = NSTextView(frame: NSRect(x: 12, y: 200, width: 140, height: 45))
        let group = DockGroupFocusView(groupID: UUID())
        group.frame = NSRect(x: 180, y: 0, width: 380, height: 280)
        group.canFocus = { true }
        group.isActive = true
        let input = NSTextField(frame: NSRect(x: 20, y: 190, width: 260, height: 28))
        group.addSubview(input)
        root.addSubview(oldEditor)
        root.addSubview(group)
        window.contentView = root
        window.orderFront(nil)

        XCTAssertTrue(window.makeFirstResponder(oldEditor))
        group.requestFocusAfterClick()
        XCTAssertTrue(window.firstResponder === oldEditor,
                      "A click observed before native dispatch must not steal the first responder")
        input.selectText(nil)
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor)
        try await wait { window.firstResponder === fieldEditor }
        XCTAssertTrue(window.firstResponder === fieldEditor,
                      "The newly focused control must win over the background focus reader")

        XCTAssertTrue(window.makeFirstResponder(oldEditor))
        group.requestFocusAfterClick()
        try await wait { window.firstResponder === group }
        XCTAssertTrue(window.firstResponder === group,
                      "Clicking empty pane space should release the previous editor")
    }

    func testNarrowTerminalFindFieldEditorBelongsOnlyToItsActualDockGroup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let terminal = project.newSession(launchCommand: "exec /bin/sh -i")
        let terminalTab = try XCTUnwrap(project.selectedTab)
        let target = try XCTUnwrap(project.dock.group(containing: .projects))
        XCTAssertTrue(project.dock.move(.tab(terminalTab.id), into: target.id))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1800, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.orderFront(nil)
        terminal.find.present()
        func input(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable,
               !field.isHiddenOrHasHiddenAncestor { return field }
            return view.subviews.lazy.compactMap { input(in: $0) }.first
        }
        try await wait {
            host.layoutSubtreeIfNeeded()
            return input(in: host) != nil
        }
        let field = try XCTUnwrap(input(in: host))
        field.selectText(nil)
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor)
        func scopes(in view: NSView) -> [DockGroupFocusView] {
            (view as? DockGroupFocusView).map { [$0] } ?? view.subviews.flatMap { scopes(in: $0) }
        }
        let readers = scopes(in: host)
        XCTAssertEqual(readers.count, project.dock.root.groups.count)
        fieldEditor.insertText("owner check 中文", replacementRange: NSRange(location: 0, length: 0))
        try await wait { terminal.find.query == "owner check 中文" }
        for reader in readers {
            XCTAssertEqual(reader.containsResponder(fieldEditor), reader.groupID == target.id)
        }
    }

    func testRestoredGroupIDsReplaceOnlyTheFocusScopesNotTheEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("restored.swift")
        try "let value = 1\n".write(to: url, atomically: true, encoding: .utf8)
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        manager.openFile(url.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.editor(in: host) != nil
        }
        let editor = try XCTUnwrap(editor(in: host))
        func scopeIDs(in view: NSView) -> Set<UUID> {
            let own = (view as? DockGroupFocusView).map { Set([$0.groupID]) } ?? []
            return view.subviews.reduce(into: own) { $0.formUnion(scopeIDs(in: $1)) }
        }
        let replacement = DockWorkspaceModel().snapshot(tabIDs: [])
        project.dock.restore(replacement, tabIDs: project.tabs.map(\.id))
        let expected = Set(project.dock.root.groups.map(\.id))
        try await wait {
            host.layoutSubtreeIfNeeded()
            return scopeIDs(in: host) == expected
        }
        XCTAssertTrue(self.editor(in: host) === editor)
        XCTAssertEqual(editor.text, "let value = 1\n")
    }

    func testFocusAcrossAppearancesAndSizesKeepsTheNativeDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(String(repeating: "长标题😀", count: 8) + ".swift")
        let text = "let greeting = \"中文 😀\"\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        manager.openFile(url.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let tab = try XCTUnwrap(project.selectedTab)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.editor(in: host) != nil && manager.attachedWindow === window
        }
        let editor = try XCTUnwrap(editor(in: host))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 480, height: 320), NSSize(width: 1100, height: 700),
                         NSSize(width: 1800, height: 1000)] {
                window.setContentSize(size)
                for item in [DockItem.projects, .files, .git, .tab(tab.id)] {
                    project.dock.select(item)
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    XCTAssertTrue(self.editor(in: host) === editor)
                    XCTAssertEqual(editor.text, text)
                    XCTAssertEqual(project.dock.activeGroup?.selected, item)
                    XCTAssertEqual(manager.ownsActiveResponder(editor), item == .tab(tab.id))
                    XCTAssertTrue(editor.visibleRect.width.isFinite)
                    XCTAssertTrue(editor.visibleRect.height.isFinite)
                }
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    func testResponderOwnershipRejectsInactiveProjectsHiddenTabsAndParking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let url = root.appendingPathComponent("owner.swift")
        try "let value = 1\n".write(to: url, atomically: true, encoding: .utf8)
        manager.openFile(url.path)
        let fileTab = try XCTUnwrap(project.selectedTab)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.editor(in: host) != nil && manager.attachedWindow === window
        }
        let editor = try XCTUnwrap(editor(in: host))
        XCTAssertTrue(manager.ownsActiveResponder(editor))
        manager.showPanel(.files)
        XCTAssertFalse(manager.ownsActiveResponder(editor))
        project.selectTab(fileTab.id)
        XCTAssertTrue(manager.ownsActiveResponder(editor))

        let terminal = project.newSession(launchCommand: "exec /bin/sh -i")
        let terminalTab = try XCTUnwrap(project.selectedTab)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return terminal.surface.superview is TerminalContainerView
        }
        XCTAssertTrue(manager.ownsActiveResponder(terminal.surface))
        project.selectTab(fileTab.id)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return terminal.surface.superview is TerminalParkingContainerView
                && self.editor(in: host) === editor
        }
        XCTAssertTrue(terminal.surface.window === window, "Parking must really retain this window")
        XCTAssertNil(terminal.surface.onBecomeFirstResponder)
        XCTAssertNil(terminal.surface.openMenuTarget.onNewBrowserTab)
        XCTAssertNil(terminal.surface.openMenuTarget.onNewFileTab)
        XCTAssertFalse(manager.ownsActiveResponder(terminal.surface))
        XCTAssertTrue(manager.ownsActiveResponder(editor))

        manager.selectedProjectID = nil
        XCTAssertFalse(manager.ownsActiveResponder(editor))
        manager.selectedProjectID = project.id
        project.selectTab(terminalTab.id)
        project.close(fileTab)
        XCTAssertFalse(manager.ownsActiveResponder(editor))
        manager.windowClosed()
        XCTAssertFalse(manager.ownsActiveResponder(terminal.surface))
    }

    func testDockToolsTakeNativeFocusWithoutReplacingVisibleEditors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let url = root.appendingPathComponent("focus 中文.swift")
        try "let value = 1\n".write(to: url, atomically: true, encoding: .utf8)
        manager.openFile(url.path)
        let tab = try XCTUnwrap(project.selectedTab)
        guard case .file(let file) = tab.content else { return XCTFail("File required") }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.editor(in: host) != nil && manager.attachedWindow === window
        }
        let editor = try XCTUnwrap(editor(in: host))
        let original = try XCTUnwrap(editor.text)
        for tool in [DockItem.files, .git, .projects] {
            XCTAssertTrue(window.makeFirstResponder(editor))
            XCTAssertTrue(manager.ownsActiveResponder(editor))
            XCTAssertEqual(project.focusedContent?.id, file.id)
            editor.insertText("// \(tool) 中文 😀\n", replacementRange: NSRange(location: 0, length: 0))
            XCTAssertTrue(file.isDirty)
            manager.showPanel(tool)
            try await wait {
                host.layoutSubtreeIfNeeded()
                let active = NSApp.isActive && window.isKeyWindow
                let validResponder = window.firstResponder is DockGroupFocusView
                    || (tool == .files && window.firstResponder is TreeKeyboardView)
                return (!active || validResponder) && !file.isDirty
            }
            if NSApp.isActive && window.isKeyWindow {
                if let scope = window.firstResponder as? DockGroupFocusView {
                    XCTAssertEqual(scope.groupID, project.dock.group(containing: tool)?.id)
                } else {
                    XCTAssertEqual(tool, .files,
                                   "Only Files has its own keyboard receiver in this fixture")
                    XCTAssertTrue(window.firstResponder is TreeKeyboardView)
                }
            }
            XCTAssertNil(project.focusedContent)
            XCTAssertFalse(manager.ownsActiveResponder(editor))
            XCTAssertTrue(self.editor(in: host) === editor)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), file.text)
            project.selectTab(tab.id)
            if NSApp.isActive && window.isKeyWindow {
                try await wait { window.firstResponder === editor }
            }
        }
        XCTAssertTrue(file.text.hasSuffix(original))
        let before = file.text
        editor.undoManager?.undo()
        XCTAssertNotEqual(file.text, before)
        XCTAssertTrue(editor === self.editor(in: host))
    }

    func testWindowFocusLossSavesAllDirtyBuffersNotOnlyTheMostRecentTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let project = try XCTUnwrap(manager.selectedProject)
        var files: [FileTab] = []
        for name in ["甲.swift", "乙.swift"] {
            let url = root.appendingPathComponent(name)
            try "original".write(to: url, atomically: true, encoding: .utf8)
            manager.openFile(url.path)
            guard case .file(let file)? = project.selectedTab?.content else { return XCTFail("File required") }
            try await file.waitForText()
            files.append(file)
        }
        for file in files {
            file.text = "changed \(file.tabTitle) 😀"
            file.refreshDirtyState()
        }
        XCTAssertTrue(files.allSatisfy(\.isDirty))
        manager.autoSaveEditedTabs()
        try await wait { files.allSatisfy { !$0.isDirty } }
        for file in files {
            XCTAssertEqual(try String(contentsOfFile: file.path, encoding: .utf8), file.text)
        }
    }

    private func editor(in view: NSView) -> FocusReportingTextView? {
        if let editor = view as? FocusReportingTextView { return editor }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }

    private func wait(
        _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Window did not finish rendering", file: file, line: line)
                throw WorkspaceError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testTwoMountedWorkspaceManagersSaveTheirOwnNativeAXBuffers() async throws {
        let previousSnapshots = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previousSnapshots)
            TerminalHistoryStore.save(previousHistories)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let aFolder = root.appendingPathComponent("A")
        let bFolder = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: aFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aURL = aFolder.appendingPathComponent("same-name.swift")
        let bURL = bFolder.appendingPathComponent("same-name.swift")
        let originalA = "let origin = \"A\"\n"
        let originalB = "let origin = \"B\"\n"
        let changedA = "let origin = \"甲 中文 😀\"\n"
        let changedB = "let origin = \"乙 emoji 👋\"\n"
        try originalA.write(to: aURL, atomically: true, encoding: .utf8)
        try originalB.write(to: bURL, atomically: true, encoding: .utf8)

        let first = self.workspaceApplication.makeWindow()
        let second = self.workspaceApplication.makeWindow()
        defer { first.windowClosed(); second.windowClosed() }
        first.addLocalFolders([aFolder])
        second.addLocalFolders([bFolder])
        first.openFile(aURL.path)
        second.openFile(bURL.path)
        guard case .file(let aFile)? = first.selectedProject?.focusedContent,
              case .file(let bFile)? = second.selectedProject?.focusedContent else {
            XCTFail("Both windows must own independent focused file tabs")
            return
        }
        aFile.autoSaveSuspendedForClose = true
        bFile.autoSaveSuspendedForClose = true
        let aWindow = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 780, height: 490),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let bWindow = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 780, height: 490),
                               styleMask: [.titled], backing: .buffered, defer: false)
        aWindow.isReleasedWhenClosed = false
        bWindow.isReleasedWhenClosed = false
        defer { aWindow.close(); bWindow.close() }
        let aHost = NSHostingView(rootView: ContentView(manager: first))
        let bHost = NSHostingView(rootView: ContentView(manager: second))
        aWindow.contentView = aHost
        bWindow.contentView = bHost
        aWindow.orderFront(nil)
        bWindow.makeKeyAndOrderFront(nil)
        try await wait {
            aHost.layoutSubtreeIfNeeded()
            bHost.layoutSubtreeIfNeeded()
            return self.editor(in: aHost)?.text == originalA
                && self.editor(in: bHost)?.text == originalB
                && first.attachedWindow === aWindow
                && second.attachedWindow === bWindow
        }
        let aEditor = try XCTUnwrap(editor(in: aHost))
        let bEditor = try XCTUnwrap(editor(in: bHost))
        aEditor.setAccessibilityValue(changedA)
        bEditor.setAccessibilityValue(changedB)
        XCTAssertTrue(aFile.isDirty)
        XCTAssertTrue(bFile.isDirty)
        XCTAssertEqual(try String(contentsOf: aURL, encoding: .utf8), originalA)
        XCTAssertEqual(try String(contentsOf: bURL, encoding: .utf8), originalB)

        first.saveSelectedFile()
        try await wait {
            (try? String(contentsOf: aURL, encoding: .utf8)) == changedA && !aFile.isDirty
        }
        XCTAssertEqual(try String(contentsOf: bURL, encoding: .utf8), originalB,
                       "Saving workspace A must not write workspace B's focused buffer")
        XCTAssertTrue(bFile.isDirty)
        XCTAssertTrue(editor(in: aHost) === aEditor)
        XCTAssertTrue(editor(in: bHost) === bEditor)

        second.saveSelectedFile()
        try await wait {
            (try? String(contentsOf: bURL, encoding: .utf8)) == changedB && !bFile.isDirty
        }
        XCTAssertEqual(try String(contentsOf: aURL, encoding: .utf8), changedA)
        XCTAssertEqual(aEditor.text, changedA)
        XCTAssertEqual(bEditor.text, changedB)
    }

    func testFinderWindowDropLoadsURLProvidersIntoItsOriginalWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first drop.swift")
        let second = root.appendingPathComponent("second-drop.txt")
        try "first body".write(to: first, atomically: true, encoding: .utf8)
        try "second body".write(to: second, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 440),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        defer { window.close() }
        XCTAssertFalse(FinderWindowDrop.receive([], preferred: manager))
        XCTAssertFalse(FinderWindowDrop.receive(
            [NSItemProvider(object: "not a local file" as NSString)], preferred: manager
        ))
        let providers = [first, second].map { NSItemProvider(object: $0 as NSURL) }
        XCTAssertTrue(FinderWindowDrop.receive(providers, preferred: manager))
        try await wait {
            manager.selectedProject?.tabs.filter { $0.content.isFile }.count == 2
        }
        let project = try XCTUnwrap(manager.selectedProject)
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(project.customDirectory, root.path)
        XCTAssertEqual(project.selectedTab?.content.title, "second-drop.txt")
        guard case .file(let editor) = try XCTUnwrap(project.selectedTab).content else {
            return XCTFail("The drop must create a real file buffer")
        }
        try await editor.waitForText()
        XCTAssertEqual(editor.text, "second body")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first body")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second body")
    }

    func testProjectsDropFilesOpenTabsAndFoldersAddProjects() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = base.appendingPathComponent("one")
        let other = base.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let pinned = other.appendingPathComponent("pinned.md")
        try "content".write(to: pinned, atomically: true, encoding: .utf8)
        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([first])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        defer { window.close() }
        let providers = [pinned, other].map { NSItemProvider(object: $0 as NSURL) }
        let originalProject = try XCTUnwrap(manager.selectedProject)
        XCTAssertTrue(FinderWindowDrop.receive(providers, preferred: manager) { urls, owner in
            self.workspaceApplication.openExternalFiles(urls, preferred: owner)
        })
        try await wait { manager.projects.count == 2 && originalProject.tabs.count == 1 }
        XCTAssertEqual(manager.projects.first?.customDirectory, first.path)
        XCTAssertEqual(originalProject.tabs.first?.content.title, "pinned.md")
        XCTAssertNil(originalProject.pinnedFile)
        let folderProject = try XCTUnwrap(manager.projects.first {
            $0.customDirectory == other.path && $0.pinnedFile == nil
        })
        XCTAssertTrue(folderProject.tabs.isEmpty)
        XCTAssertEqual(manager.selectedProjectID, originalProject.id)
        let originalIDs = Set(manager.projects.map(\.id))
        let openedTab = try XCTUnwrap(originalProject.selectedTab)
        XCTAssertTrue(FinderWindowDrop.receive(providers, preferred: manager) { urls, owner in
            self.workspaceApplication.openExternalFiles(urls, preferred: owner)
        })
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(Set(manager.projects.map(\.id)), originalIDs)
        XCTAssertTrue(originalProject.selectedTab === openedTab)
        XCTAssertEqual(originalProject.tabs.count, 1)
        XCTAssertEqual(try String(contentsOf: pinned, encoding: .utf8), "content")
    }

    func testFinderDropIntoAnotherTabStripKeepsNewTabsInTheActualTargetGroup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = (1...4).map { directory.appendingPathComponent("drop-\($0).swift") }
        for file in files { try "let file = 1".write(to: file, atomically: true, encoding: .utf8) }

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([directory])
        let project = try XCTUnwrap(manager.selectedProject)
        project.openFile(files[0].path)
        project.openFile(files[1].path)
        let initialTabs = project.tabs
        let left = try XCTUnwrap(project.dock.group(containing: .tab(initialTabs[0].id)))
        let right = try XCTUnwrap(project.dock.root.groups.last)
        XCTAssertNotEqual(left.id, right.id)
        XCTAssertTrue(project.dock.move(.tab(initialTabs[1].id), into: right.id))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 550),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        manager.attach(to: window)

        let target = (projectID: project.id, groupID: left.id)
        var responses: [Bool] = []
        self.workspaceApplication.openExternalFiles(Array(files[2...3]), preferred: manager, destination: target) {
            responses.append($0)
        }
        XCTAssertEqual(responses, [true])
        XCTAssertEqual(project.tabs.count, 4)
        let newTabs = Array(project.tabs.filter { tab in
            guard case .file(let file) = tab.content else { return false }
            return files[2...3].contains { $0.path == file.path }
        })
        XCTAssertEqual(newTabs.count, 2)
        XCTAssertTrue(newTabs.allSatisfy {
            project.dock.group(containing: .tab($0.id))?.id == left.id
        }, "Finder files must open in the drop target's actual Dock group")
        XCTAssertEqual(project.dock.group(containing: .tab(initialTabs[1].id))?.id, right.id)

        self.workspaceApplication.openExternalFiles([files[1]], preferred: manager, destination: target) {
            responses.append($0)
        }
        XCTAssertEqual(responses, [true, true])
        XCTAssertEqual(project.tabs.count, 4)
        XCTAssertEqual(project.dock.group(containing: .tab(initialTabs[1].id))?.id, right.id,
                       "Reusing an existing tab must not move it to the drop target")
        XCTAssertTrue(project.tabs.contains { $0.id == initialTabs[0].id })
        XCTAssertEqual(try String(contentsOf: files[1], encoding: .utf8), "let file = 1")
    }

    func testFinderDropIntoEmptyTabGroupKeepsGroupAndDoesNotMoveFilesAcrossProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstRoot = root.appendingPathComponent("one")
        let otherRoot = root.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFile = firstRoot.appendingPathComponent("new.swift")
        let otherFile = otherRoot.appendingPathComponent("other.swift")
        try "first".write(to: firstFile, atomically: true, encoding: .utf8)
        try "other".write(to: otherFile, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([firstRoot])
        let first = try XCTUnwrap(manager.selectedProject)
        let empty = try XCTUnwrap(first.dock.root.groups.first(where: { $0.items.isEmpty }))
        manager.addLocalFolders([otherRoot])
        let other = try XCTUnwrap(manager.selectedProject)
        manager.selectedProjectID = first.id
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        manager.attach(to: window)
        let destination = (projectID: first.id, groupID: empty.id)
        XCTAssertTrue(FinderWindowDrop.receive(
            [NSItemProvider(object: firstFile as NSURL)],
            preferred: manager, destination: destination
        ))
        try await wait { first.tabs.count == 1 }
        let firstTab = try XCTUnwrap(first.tabs.first)
        XCTAssertEqual(first.dock.group(containing: .tab(firstTab.id))?.id, empty.id,
                       "Empty groups must survive the first Finder tab insertion")
        XCTAssertEqual(other.tabs.count, 0)

        // An unopened file under B still opens in the actual receiving A group.
        self.workspaceApplication.openExternalFiles([otherFile], preferred: manager, destination: destination)
        XCTAssertEqual(first.tabs.count, 2)
        XCTAssertEqual(other.tabs.count, 0)
        XCTAssertEqual(manager.selectedProjectID, first.id)
        let secondTab = try XCTUnwrap(first.selectedTab)
        XCTAssertEqual(first.dock.group(containing: .tab(secondTab.id))?.id, empty.id)
        XCTAssertEqual(first.dock.group(containing: .tab(firstTab.id))?.id, empty.id)
        XCTAssertEqual(try String(contentsOf: otherFile, encoding: .utf8), "other")
    }

    func testQueuedFinderBatchRejectsChangedReceivingProjectBeforeRestoredOwnerAttaches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        for directory in [firstRoot, secondRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = secondRoot.appendingPathComponent("existing.swift")
        let newFile = firstRoot.appendingPathComponent("new.swift")
        try "already open".write(to: existing, atomically: true, encoding: .utf8)
        try "new data".write(to: newFile, atomically: true, encoding: .utf8)

        let receiver = self.workspaceApplication.makeWindow()
        let waitingOwner = self.workspaceApplication.makeWindow()
        defer { receiver.windowClosed(); waitingOwner.windowClosed() }
        receiver.addLocalFolders([firstRoot, secondRoot])
        let initial = try XCTUnwrap(receiver.projects.first { $0.customDirectory == firstRoot.path })
        let changed = try XCTUnwrap(receiver.projects.first { $0.customDirectory == secondRoot.path })
        receiver.selectedProjectID = initial.id
        waitingOwner.addLocalFolders([secondRoot])
        waitingOwner.selectedProject?.openLocalFile(existing.path)
        let previousTabID = waitingOwner.selectedProject?.selectedTabID

        let receiverWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let ownerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        receiverWindow.isReleasedWhenClosed = false
        ownerWindow.isReleasedWhenClosed = false
        defer { receiverWindow.close(); ownerWindow.close() }
        receiver.attach(to: receiverWindow)

        var replies: [Bool] = []
        self.workspaceApplication.openExternalFiles([existing, newFile], preferred: receiver) {
            replies.append($0)
        }
        XCTAssertTrue(replies.isEmpty, "Wait for the file's original owner before routing the batch")
        receiver.selectedProjectID = changed.id
        waitingOwner.attach(to: ownerWindow)

        XCTAssertEqual(replies, [false], "The delayed request belongs to the original Project")
        XCTAssertTrue(initial.tabs.isEmpty)
        XCTAssertTrue(changed.tabs.isEmpty, "New files cannot migrate to a later-selected Project")
        XCTAssertEqual(waitingOwner.selectedProject?.selectedTabID, previousTabID)
        XCTAssertEqual(try String(contentsOf: newFile, encoding: .utf8), "new data")
    }

    func testFinderProjectsDropDoesNotSwitchTargetDuringProviderLoading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        for directory in [firstRoot, secondRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project-drop.swift")
        try "let owner = 1".write(to: source, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([firstRoot, secondRoot])
        let first = try XCTUnwrap(manager.projects.first { $0.customDirectory == firstRoot.path })
        let second = try XCTUnwrap(manager.projects.first { $0.customDirectory == secondRoot.path })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 450),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        manager.attach(to: window)

        manager.selectedProjectID = first.id
        XCTAssertTrue(FinderWindowDrop.receive(
            [NSItemProvider(object: source as NSURL)], preferred: manager
        ))
        // The URL provider is still loading when the user selects another Project.
        manager.selectedProjectID = second.id
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(first.tabs.isEmpty)
        XCTAssertTrue(second.tabs.isEmpty, "A late Finder drop must never open in a different Project")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "let owner = 1")
    }

    func testFinderEmptyStateDropCannotOpenIntoFolderAddedWhileProviderLoads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("empty-state.txt")
        try "original".write(to: source, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 450),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        manager.attach(to: window)
        XCTAssertNil(manager.selectedProject)

        XCTAssertTrue(FinderWindowDrop.receive(
            [NSItemProvider(object: source as NSURL)], preferred: manager
        ))
        manager.addLocalFolders([root])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertTrue(manager.projects[0].tabs.isEmpty,
                      "A file dropped into an empty state cannot become an implicit open")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
    }

    func testFinderDropDoesNotRouteLateProvidersIntoAnotherOrClosedWindow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("slow.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { if manager.attachedWindow != nil { manager.windowClosed() } }
        let original = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 450),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let replacement = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 450),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        original.isReleasedWhenClosed = false
        replacement.isReleasedWhenClosed = false
        defer { original.close(); replacement.close() }

        manager.attach(to: original)
        XCTAssertTrue(FinderWindowDrop.receive([NSItemProvider(object: file as NSURL)], preferred: manager))
        // The provider callback runs asynchronously; even if the manager is
        // reattached, it must not redirect a pending drop to the new window.
        manager.attach(to: replacement)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(manager.projects.isEmpty)

        XCTAssertTrue(FinderWindowDrop.receive([NSItemProvider(object: file as NSURL)], preferred: manager))
        manager.windowClosed()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(manager.projects.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    func testExternalBatchRoutesToActualMountedFileBuffers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("入口.swift")
        let second = folder.appendingPathComponent("two.json")
        try "let value = 42".write(to: first, atomically: true, encoding: .utf8)
        try "{\"number\":7}".write(to: second, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([folder])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 490),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return manager.attachedWindow === window
        }

        // XCTest hosts can have unrelated windows from other integration tests.
        // Choose the mounted recipient explicitly; process-wide activation and
        // default window selection are covered by the separate Launch Services E2E.
        var replies: [Bool] = []
        self.workspaceApplication.openExternalFiles([first, second], preferred: manager) {
            replies.append($0)
        }
        XCTAssertEqual(replies, [true])
        let project = try XCTUnwrap(manager.selectedProject)
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(project.customDirectory, folder.path)
        XCTAssertNil(project.pinnedFile)
        XCTAssertEqual(project.tabs.filter { $0.content.isFile }.count, 2)
        guard case .file(let opened) = try XCTUnwrap(project.selectedTab).content else {
            return XCTFail("The system batch route must create a real file content tab")
        }
        try await opened.waitForText()
        XCTAssertEqual(opened.text, "{\"number\":7}")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "let value = 42")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "{\"number\":7}")

        let existing = opened
        self.workspaceApplication.openExternalFiles([second], preferred: manager)
        guard case .file(let reused) = try XCTUnwrap(manager.selectedProject?.selectedTab).content
        else { return XCTFail("The previous buffer must still exist") }
        XCTAssertTrue(reused === existing)
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(project.tabs.count, 2)

        self.workspaceApplication.openExternalFiles([folder], preferred: manager)
        XCTAssertEqual(manager.projects.count, 1, "Opening a directory reuses the existing root")
        XCTAssertEqual(manager.selectedProject?.customDirectory, folder.path)
        XCTAssertEqual(project.tabs.count, 2, "A folder is a project, not a file editor")

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let imagePath = folder.appendingPathComponent("example.png")
        try png.write(to: imagePath)
        self.workspaceApplication.openExternalFiles([imagePath], preferred: manager)
        guard case .file(let preview) = try XCTUnwrap(project.selectedTab).content else {
            return XCTFail("System image open should create a native preview tab")
        }
        preview.loadIfNeeded()
        try await wait {
            if case .image = preview.content { return true }
            return false
        }
        XCTAssertEqual(project.tabs.count, 3)
        XCTAssertEqual(try Data(contentsOf: imagePath), png)
    }

    func testExternalOpenFindsExistingFileInOtherWindowBeforeCreatingAnEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = secondRoot.appendingPathComponent("opened.swift")
        let extra = firstRoot.appendingPathComponent("new.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        try "new".write(to: extra, atomically: true, encoding: .utf8)

        let a = self.workspaceApplication.makeWindow()
        let b = self.workspaceApplication.makeWindow()
        defer { a.windowClosed(); b.windowClosed() }
        a.addLocalFolders([firstRoot])
        b.addLocalFolders([secondRoot])
        b.openFile(file.path)
        let bProject = try XCTUnwrap(b.selectedProject)
        guard case .file(let original) = try XCTUnwrap(bProject.selectedTab).content else {
            return XCTFail("Must have a real existing file tab")
        }

        let windowA = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 550),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let windowB = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 550),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        windowA.isReleasedWhenClosed = false
        windowB.isReleasedWhenClosed = false
        defer { windowA.close(); windowB.close() }
        let hostA = NSHostingView(rootView: ContentView(manager: a))
        let hostB = NSHostingView(rootView: ContentView(manager: b))
        windowA.contentView = hostA
        windowB.contentView = hostB
        windowB.orderFront(nil)
        windowA.makeKeyAndOrderFront(nil)
        try await wait {
            hostA.layoutSubtreeIfNeeded()
            hostB.layoutSubtreeIfNeeded()
            return a.attachedWindow === windowA && b.attachedWindow === windowB
        }

        var replies: [Bool] = []
        self.workspaceApplication.openExternalFiles([file], preferred: a) { replies.append($0) }
        XCTAssertEqual(replies, [true])
        XCTAssertTrue(b.selectedProject === bProject)
        guard case .file(let located) = try XCTUnwrap(bProject.selectedTab).content else {
            return XCTFail("Expected to find the existing file buffer")
        }
        XCTAssertTrue(located === original)
        XCTAssertEqual(a.projects.count, 1)
        XCTAssertEqual(bProject.tabs.filter { $0.content.isFile }.count, 1)
        XCTAssertTrue(windowB.isVisible)
        XCTAssertTrue(
            NSApp.orderedWindows.first(where: { $0 === windowA || $0 === windowB }) === windowB,
            "The real receiver should move in front of the other workspace"
        )
        // An XCTest-hosted app may not hold macOS foreground activation; when
        // AppKit grants it, also require real key-window focus.
        if NSApp.isActive { try await wait { windowB.isKeyWindow } }

        // A genuinely new file is opened in the explicit receiving window.
        self.workspaceApplication.openExternalFiles([extra], preferred: a) { replies.append($0) }
        XCTAssertEqual(replies, [true, true])
        XCTAssertEqual(a.selectedProject?.selectedTab?.content.title, "new.swift")
        XCTAssertEqual(bProject.tabs.filter { $0.content.isFile }.count, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    func testFinderReusesMacFileInsideRemoteProjectInAnotherWindow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("same.swift")
        try "local bytes".write(to: file, atomically: true, encoding: .utf8)

        let a = self.workspaceApplication.makeWindow()
        let b = self.workspaceApplication.makeWindow()
        defer { a.windowClosed(); b.windowClosed() }
        a.addLocalFolders([folder])
        let remote = Project(fallbackName: "SSH", workspaceConfiguration: .standard)
        remote.sshHost = "invalid-p4-cross-window"
        remote.customDirectory = "/remote/workspace"
        b.projects.append(remote)
        b.selectedProjectID = remote.id
        XCTAssertTrue(b.openExternalLocalItems([file]).isEmpty)
        let originalTab = try XCTUnwrap(remote.selectedTab)
        guard case .file(let originalFile) = originalTab.content else {
            return XCTFail("Expected Mac file in SSH project")
        }
        XCTAssertNil(originalFile.workspaceIdentity)

        let windowA = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let windowB = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
                               styleMask: [.titled], backing: .buffered, defer: false)
        windowA.isReleasedWhenClosed = false
        windowB.isReleasedWhenClosed = false
        defer { windowA.close(); windowB.close() }
        a.attach(to: windowA)
        b.attach(to: windowB)

        var handled: Bool?
        self.workspaceApplication.openExternalFiles([file], preferred: a) { handled = $0 }
        XCTAssertEqual(handled, true)
        XCTAssertTrue(b.selectedProject === remote)
        XCTAssertTrue(remote.selectedTab === originalTab)
        XCTAssertEqual(remote.tabs.filter { $0.content.isFile }.count, 1)
        XCTAssertEqual(a.selectedProject?.tabs.filter { $0.content.isFile }.count, 0)
        try await originalFile.waitForText()
        XCTAssertEqual(originalFile.text, "local bytes")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "local bytes")
    }

    func testExternalOpenDefersUntilAllCreatedWindowsHaveAttached() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("restored.md")
        try "saved".write(to: file, atomically: true, encoding: .utf8)

        let first = self.workspaceApplication.makeWindow()
        let restored = self.workspaceApplication.makeWindow()
        defer { first.windowClosed(); restored.windowClosed() }
        restored.addLocalFolders([directory])
        restored.openFile(file.path)
        let project = try XCTUnwrap(restored.selectedProject)
        guard case .file(let original) = try XCTUnwrap(project.selectedTab).content else {
            return XCTFail("Saved window already owns the file")
        }
        let firstWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 370),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        let laterWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 370),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        laterWindow.isReleasedWhenClosed = false
        defer { firstWindow.close(); laterWindow.close() }
        first.attach(to: firstWindow)

        var replies = 0
        self.workspaceApplication.openExternalFiles([file]) { handled in
            XCTAssertTrue(handled)
            replies += 1
        }
        XCTAssertEqual(replies, 0, "Do not consume before the other restored manager attaches")
        XCTAssertTrue(first.projects.isEmpty)
        restored.attach(to: laterWindow)
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(first.projects.count, 0)
        XCTAssertEqual(restored.projects.count, 1)
        guard case .file(let same) = try XCTUnwrap(project.selectedTab).content else {
            return XCTFail("The existing editor must be retained")
        }
        XCTAssertTrue(same === original)
        restored.attach(to: laterWindow)
        XCTAssertEqual(replies, 1, "Repeated attach must never replay system requests")
    }

    func testExternalOpenKeepsOneDirectoryProjectAcrossInterleavedWindowBatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("local")
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = local.appendingPathComponent("first.txt")
        let last = local.appendingPathComponent("last.txt")
        let opened = existing.appendingPathComponent("already-open.txt")
        for (url, text) in [(first, "one"), (last, "two"), (opened, "three")] {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let a = self.workspaceApplication.makeWindow()
        let b = self.workspaceApplication.makeWindow()
        defer { a.windowClosed(); b.windowClosed() }
        a.addLocalFolders([local])
        b.addLocalFolders([existing])
        b.openFile(opened.path)
        let bTab = try XCTUnwrap(b.selectedProject?.selectedTab)
        let windowA = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 350),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let windowB = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 350),
                               styleMask: [.titled], backing: .buffered, defer: false)
        windowA.isReleasedWhenClosed = false
        windowB.isReleasedWhenClosed = false
        defer { windowA.close(); windowB.close() }
        a.attach(to: windowA)
        b.attach(to: windowB)

        var result: Bool?
        self.workspaceApplication.openExternalFiles([first, opened, last], preferred: a) { result = $0 }
        XCTAssertEqual(result, true)
        XCTAssertEqual(a.projects.count, 1, "New files stay in A even when B owns the interleaved open file")
        let aProject = try XCTUnwrap(a.selectedProject)
        XCTAssertNil(aProject.pinnedFile)
        XCTAssertEqual(aProject.customDirectory, local.path)
        XCTAssertEqual(aProject.tabs.filter { $0.content.isFile }.count, 2)
        XCTAssertEqual(aProject.selectedTab?.content.title, "last.txt")
        XCTAssertEqual(b.selectedProject?.selectedTab?.id, bTab.id)
        XCTAssertEqual(b.projects.count, 1)
    }

    func testExternalOpenCancelledWhenOwningWindowClosesBeforeRestoreCompletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("pending.txt")
        try "sentinel".write(to: file, atomically: true, encoding: .utf8)
        let a = self.workspaceApplication.makeWindow()
        let b = self.workspaceApplication.makeWindow()
        defer { a.windowClosed(); b.windowClosed() }
        // The not-yet-attached B really owns this file; this is the
        // condition that must defer even if unrelated unmounted managers exist.
        b.addLocalFolders([root])
        b.openFile(file.path)
        let priorTab = try XCTUnwrap(b.selectedProject?.selectedTab)
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { owner.close(); second.close() }
        a.attach(to: owner)
        var replies: [Bool] = []
        self.workspaceApplication.openExternalFiles([file], preferred: a) { replies.append($0) }
        XCTAssertTrue(replies.isEmpty)
        a.windowClosed()
        XCTAssertEqual(replies, [false], "The closed window cancels its own outstanding drop")
        b.attach(to: second)
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(b.selectedProject?.selectedTab?.id, priorTab.id)
        XCTAssertEqual(b.projects.count, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "sentinel")
    }

    func testClosingAnUnattachedFileOwnerDrainsAllWaitingFinderEventsWithoutRetargeting() throws {
        for changesReceivingProject in [false, true] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("bailey-owner-close-\(UUID().uuidString)")
            let original = root.appendingPathComponent("original", isDirectory: true)
            let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = original.appendingPathComponent("buffer.swift")
            try "important bytes".write(to: file, atomically: true, encoding: .utf8)

            let receiver = self.workspaceApplication.makeWindow()
            let awaitingOwner = self.workspaceApplication.makeWindow()
            defer { receiver.windowClosed(); awaitingOwner.windowClosed() }
            receiver.addLocalFolders([original, unrelated])
            let target = try XCTUnwrap(receiver.projects.first { $0.customDirectory == original.path })
            let other = try XCTUnwrap(receiver.projects.first { $0.customDirectory == unrelated.path })
            receiver.selectedProjectID = target.id
            awaitingOwner.addLocalFolders([original])
            awaitingOwner.openFile(file.path)
            XCTAssertTrue(awaitingOwner.selectedProject?.selectedTab?.content.isFile == true)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 490, height: 350),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            receiver.attach(to: window)
            var replies: [Bool] = []
            let count = changesReceivingProject ? 3 : 67
            for _ in 0..<count {
                self.workspaceApplication.openExternalFiles([file], preferred: receiver) {
                    replies.append($0)
                }
            }
            XCTAssertTrue(replies.isEmpty, "Existing FileTab belongs to the unattached owner")
            if changesReceivingProject { receiver.selectedProjectID = other.id }

            awaitingOwner.windowClosed()
            XCTAssertEqual(replies, Array(repeating: !changesReceivingProject, count: count),
                           "An owner can close before attaching; every Finder event must complete once")
            XCTAssertEqual(target.tabs.filter { $0.content.isFile }.count,
                           changesReceivingProject ? 0 : 1)
            XCTAssertTrue(other.tabs.isEmpty, "Never redirect late events to a newly selected project")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "important bytes")
        }
    }

    func testAnUnattachedUnrelatedManagerCannotHoldFinderRequestsForever() throws {
        // Other features may construct a WorkspaceWindowModel before they ever mount
        // a window. It must not block an independent, attached Finder receiver.
        let unmounted = self.workspaceApplication.makeWindow()
        let receiver = self.workspaceApplication.makeWindow()
        defer { unmounted.windowClosed(); receiver.windowClosed() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("unrelated.txt")
        try "fixture".write(to: url, atomically: true, encoding: .utf8)
        receiver.addLocalFolders([root])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        receiver.attach(to: window)
        var handled: Bool?
        self.workspaceApplication.openExternalFiles([url], preferred: receiver) { handled = $0 }
        XCTAssertEqual(handled, true)
        XCTAssertEqual(receiver.selectedProject?.selectedTab?.content.title, "unrelated.txt")
        XCTAssertTrue(unmounted.projects.isEmpty)
    }

    func testPendingFinderDocumentsSurviveMoreThan64EventsBeforeOwnerWindowAttaches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("pending-owner.txt")
        try "unchanged".write(to: file, atomically: true, encoding: .utf8)

        let receiver = self.workspaceApplication.makeWindow()
        let awaitingOwner = self.workspaceApplication.makeWindow()
        defer { receiver.windowClosed(); awaitingOwner.windowClosed() }
        receiver.addLocalFolders([root])
        awaitingOwner.addLocalFolders([root])
        awaitingOwner.selectedProject?.openLocalFile(file.path)
        let ownerTab = try XCTUnwrap(awaitingOwner.selectedProject?.selectedTab)

        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let ownerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        firstWindow.isReleasedWhenClosed = false
        ownerWindow.isReleasedWhenClosed = false
        defer { firstWindow.close(); ownerWindow.close() }
        receiver.attach(to: firstWindow)

        var replies: [Bool] = []
        for _ in 0..<80 {
            self.workspaceApplication.openExternalFiles([file], preferred: receiver) { replies.append($0) }
        }
        XCTAssertTrue(replies.isEmpty, "Wait for the actual existing file owner, not the receiving window")

        awaitingOwner.attach(to: ownerWindow)
        XCTAssertEqual(replies.count, 80, "Every deferred Finder event needs a completion")
        XCTAssertTrue(replies.allSatisfy { $0 })
        XCTAssertEqual(receiver.selectedProject?.tabs.count, 0)
        XCTAssertEqual(awaitingOwner.selectedProject?.tabs.count, 1)
        XCTAssertTrue(awaitingOwner.selectedProject?.selectedTab === ownerTab)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unchanged")
    }

    func testClosingOneWorkspaceWindowKeepsOtherManagerEditorAndSnapshot() async throws {
        let previousSnapshots = SessionStore.load()
        let previousHistories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(previousSnapshots)
            TerminalHistoryStore.save(previousHistories)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let aFolder = root.appendingPathComponent("A")
        let bFolder = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: aFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aURL = aFolder.appendingPathComponent("a.txt")
        let bURL = bFolder.appendingPathComponent("b.txt")
        try "window A".write(to: aURL, atomically: true, encoding: .utf8)
        try "window B".write(to: bURL, atomically: true, encoding: .utf8)

        let first = self.workspaceApplication.makeWindow()
        let second = self.workspaceApplication.makeWindow()
        defer {
            first.windowClosed()
            second.windowClosed()
        }
        first.addLocalFolders([aFolder])
        second.addLocalFolders([bFolder])
        first.openFile(aURL.path)
        second.openFile(bURL.path)

        let firstWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 520),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 520),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        defer { firstWindow.close(); secondWindow.close() }
        let firstHost = NSHostingView(rootView: ContentView(manager: first))
        let secondHost = NSHostingView(rootView: ContentView(manager: second))
        firstWindow.contentView = firstHost
        secondWindow.contentView = secondHost
        firstWindow.orderFront(nil)
        secondWindow.makeKeyAndOrderFront(nil)
        try await wait {
            firstHost.layoutSubtreeIfNeeded()
            secondHost.layoutSubtreeIfNeeded()
            return self.editor(in: firstHost)?.text == "window A"
                && self.editor(in: secondHost)?.text == "window B"
                && first.attachedWindow === firstWindow
                && second.attachedWindow === secondWindow
        }
        let bEditor = try XCTUnwrap(editor(in: secondHost))
        // Closing A has to remove only A from the window registry and snapshot;
        // it must not remove B or its native editor when B owns the key window.
        firstWindow.performClose(nil)
        XCTAssertFalse(firstWindow.isVisible, "A clean native window must close immediately")
        first.windowClosed()
        XCTAssertNil(first.attachedWindow)
        XCTAssertTrue(second.attachedWindow === secondWindow)
        XCTAssertTrue(editor(in: secondHost) === bEditor)
        XCTAssertEqual(bEditor.text, "window B")
        let savedProjects = SessionStore.load().flatMap(\.projects)
        XCTAssertTrue(savedProjects.contains { $0.customDirectory == bFolder.path })
        XCTAssertFalse(savedProjects.contains { $0.customDirectory == aFolder.path })
        XCTAssertEqual(try String(contentsOf: aURL, encoding: .utf8), "window A")
        XCTAssertEqual(try String(contentsOf: bURL, encoding: .utf8), "window B")
    }

    func testSpeculativeSceneConstructionDoesNotRegisterOrConsumeRestoredWindows() throws {
        XCTAssertTrue(BaileyInstanceMode.isIsolated)
        let saved = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(saved)
            TerminalHistoryStore.save(histories)
        }

        func snapshot(named name: String) -> SessionSnapshot {
            let project = SessionSnapshot.ProjectSnapshot(
                customName: name,
                customDirectory: "/fixture/" + name,
                sshHost: nil,
                pinnedFile: nil,
                tabs: [],
                selectedTabIndex: nil,
                dock: .group(.init(id: UUID(), items: [.files], selected: .files))
            )
            return SessionSnapshot(projects: [project], selectedProjectIndex: 0)
        }
        SessionStore.save([snapshot(named: "one"), snapshot(named: "two")])
        let application = WorkspaceApplication(loadSavedState: true)
        let discarded = WorkspaceWindowModel(application: application)
        let redundant = WorkspaceWindowModel(application: application)
        XCTAssertEqual(application.windowCount, 0)
        XCTAssertTrue(discarded.projects.isEmpty)
        XCTAssertTrue(redundant.projects.isEmpty)

        let first = application.makeWindow()
        let second = application.makeWindow()
        defer {
            first.windowClosed()
            second.windowClosed()
        }
        XCTAssertEqual(application.windowCount, 2)
        XCTAssertEqual(first.selectedProject?.customName, "one")
        XCTAssertEqual(second.selectedProject?.customName, "two")
        application.register(first)
        application.register(second)
        XCTAssertEqual(application.windowCount, 2,
                       "Repeated SwiftUI appear or native attachment cannot claim another snapshot")
        XCTAssertEqual(first.selectedProject?.customName, "one")
        XCTAssertEqual(second.selectedProject?.customName, "two")
        XCTAssertTrue(SessionStore.load().count == 2)
        withExtendedLifetime([discarded, redundant]) {}
    }

    func testLocalWorktreeUseProtectsMacFileInsideAnSSHProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        let sibling = root.appendingPathComponent("checkout-other", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = checkout.appendingPathComponent("unsaved.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let manager = self.workspaceApplication.makeWindow()
        defer { manager.windowClosed() }
        let remote = Project(fallbackName: "SSH", workspaceConfiguration: .standard)
        remote.sshHost = "invalid-worktree-protection-fixture"
        remote.customDirectory = "/remote/unrelated"
        manager.projects.append(remote)
        manager.selectedProjectID = remote.id
        XCTAssertTrue(manager.openExternalLocalItems([file]).isEmpty)
        let tab = try XCTUnwrap(remote.selectedTab)
        guard case .file(let localFile) = tab.content else {
            return XCTFail("Mac file should open in an SSH project's editor tab")
        }
        XCTAssertNil(localFile.workspaceIdentity)
        XCTAssertEqual(remote.panelContext?.scope, "ssh:invalid-worktree-protection-fixture")

        XCTAssertTrue(self.workspaceApplication.isWorktreeInUse(path: checkout.path, scope: "local"),
                      "A local editor inside an SSH project must block worktree removal")
        XCTAssertFalse(self.workspaceApplication.isWorktreeInUse(path: sibling.path, scope: "local"))
        XCTAssertFalse(self.workspaceApplication.isWorktreeInUse(path: checkout.path,
                                                                scope: "ssh:invalid-worktree-protection-fixture"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    func testTwoApplicationOwnersNeverShareWorkspaceRegistryOrWorktreeProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let aFolder = root.appendingPathComponent("first", isDirectory: true)
        let bFolder = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: aFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let otherApplication = WorkspaceApplication()
        let first = self.workspaceApplication.makeWindow()
        let second = otherApplication.makeWindow()
        defer {
            first.windowClosed()
            second.windowClosed()
        }
        first.addLocalFolders([aFolder])
        second.addLocalFolders([bFolder])
        XCTAssertEqual(self.workspaceApplication.windowCount, 1)
        XCTAssertEqual(otherApplication.windowCount, 1)
        XCTAssertTrue(self.workspaceApplication.isWorktreeInUse(path: aFolder.path, scope: "local"))
        XCTAssertFalse(self.workspaceApplication.isWorktreeInUse(path: bFolder.path, scope: "local"))
        XCTAssertTrue(otherApplication.isWorktreeInUse(path: bFolder.path, scope: "local"))
        XCTAssertFalse(otherApplication.isWorktreeInUse(path: aFolder.path, scope: "local"))
        XCTAssertFalse(otherApplication.containsWindow(first))
        XCTAssertFalse(self.workspaceApplication.containsWindow(second))
    }
}
