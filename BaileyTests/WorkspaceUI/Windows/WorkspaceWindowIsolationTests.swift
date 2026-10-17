import AppKit
import SwiftUI
import XCTest
@testable import Bailey

/// Two full workspaces in separate native windows. The current key window is
/// not a valid substitute for the manager that owns a file or its save target.
@MainActor
final class WorkspaceWindowIsolationTests: XCTestCase {
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

        let a = TerminalManager()
        let b = TerminalManager()
        defer { a.windowClosed(); b.windowClosed() }
        a.addLocalItems([firstRoot])
        b.addLocalItems([secondRoot])
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
        TerminalManager.openExternalFiles([file], preferred: a) { replies.append($0) }
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
        TerminalManager.openExternalFiles([extra], preferred: a) { replies.append($0) }
        XCTAssertEqual(replies, [true, true])
        XCTAssertEqual(a.selectedProject?.selectedTab?.content.title, "new.swift")
        XCTAssertEqual(bProject.tabs.filter { $0.content.isFile }.count, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    func testExternalOpenDefersUntilAllCreatedWindowsHaveAttached() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("restored.md")
        try "saved".write(to: file, atomically: true, encoding: .utf8)

        let first = TerminalManager()
        let restored = TerminalManager()
        defer { first.windowClosed(); restored.windowClosed() }
        restored.addLocalItems([file])
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
        TerminalManager.openExternalFiles([file]) { handled in
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
        let a = TerminalManager()
        let b = TerminalManager()
        defer { a.windowClosed(); b.windowClosed() }
        b.addLocalItems([opened])
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
        TerminalManager.openExternalFiles([first, opened, last], preferred: a) { result = $0 }
        XCTAssertEqual(result, true)
        XCTAssertEqual(a.projects.count, 1, "Separated entries in one batch share the same directory project")
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
        let a = TerminalManager()
        let b = TerminalManager()
        defer { a.windowClosed(); b.windowClosed() }
        // The not-yet-attached B really owns this file; this is the
        // condition that must defer even if unrelated unmounted managers exist.
        b.addLocalItems([file])
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
        TerminalManager.openExternalFiles([file], preferred: a) { replies.append($0) }
        XCTAssertTrue(replies.isEmpty)
        a.windowClosed()
        XCTAssertEqual(replies, [false], "The closed window cancels its own outstanding drop")
        b.attach(to: second)
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(b.selectedProject?.selectedTab?.id, priorTab.id)
        XCTAssertEqual(b.projects.count, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "sentinel")
    }

    func testAnUnattachedUnrelatedManagerCannotHoldFinderRequestsForever() throws {
        // Other features may construct a TerminalManager before they ever mount
        // a window. It must not block an independent, attached Finder receiver.
        let unmounted = TerminalManager()
        let receiver = TerminalManager()
        defer { unmounted.windowClosed(); receiver.windowClosed() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("unrelated.txt")
        try "fixture".write(to: url, atomically: true, encoding: .utf8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        receiver.attach(to: window)
        var handled: Bool?
        TerminalManager.openExternalFiles([url], preferred: receiver) { handled = $0 }
        XCTAssertEqual(handled, true)
        XCTAssertEqual(receiver.selectedProject?.selectedTab?.content.title, "unrelated.txt")
        XCTAssertTrue(unmounted.projects.isEmpty)
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

        let first = TerminalManager()
        let second = TerminalManager()
        defer {
            first.windowClosed()
            second.windowClosed()
        }
        first.addLocalItems([aFolder])
        second.addLocalItems([bFolder])
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
}
