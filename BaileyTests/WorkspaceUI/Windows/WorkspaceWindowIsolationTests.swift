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

    func testFinderWindowDropLoadsURLProvidersIntoItsOriginalWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first drop.swift")
        let second = root.appendingPathComponent("second-drop.txt")
        try "first body".write(to: first, atomically: true, encoding: .utf8)
        try "second body".write(to: second, atomically: true, encoding: .utf8)

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
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

    func testProjectsDropKeepsExplicitPinnedFilesAndDistinctProjectOwnership() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = base.appendingPathComponent("one")
        let other = base.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let pinned = other.appendingPathComponent("pinned.md")
        try "content".write(to: pinned, atomically: true, encoding: .utf8)
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([first])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.attach(to: window)
        defer { window.close() }
        let providers = [pinned, other].map { NSItemProvider(object: $0 as NSURL) }
        XCTAssertTrue(FinderWindowDrop.receive(providers, preferred: manager) { urls, owner in
            owner.addLocalItems(urls)
        })
        try await wait { manager.projects.count == 3 }
        XCTAssertEqual(manager.projects.first?.customDirectory, first.path)
        let fileProject = try XCTUnwrap(manager.projects.first { $0.pinnedFile == pinned.path })
        XCTAssertEqual(fileProject.customDirectory, other.path)
        XCTAssertEqual(fileProject.tabs.filter { $0.content.isFile }.count, 1)
        let folderProject = try XCTUnwrap(manager.projects.first {
            $0.customDirectory == other.path && $0.pinnedFile == nil
        })
        XCTAssertNotEqual(fileProject.id, folderProject.id)
        let originalIDs = Set(manager.projects.map(\.id))
        XCTAssertTrue(FinderWindowDrop.receive(providers, preferred: manager) { urls, owner in
            owner.addLocalItems(urls)
        })
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(Set(manager.projects.map(\.id)), originalIDs)
        XCTAssertEqual(try String(contentsOf: pinned, encoding: .utf8), "content")
    }

    func testFinderDropIntoAnotherTabStripKeepsNewTabsInTheActualTargetGroup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = (1...4).map { directory.appendingPathComponent("drop-\($0).swift") }
        for file in files { try "let file = 1".write(to: file, atomically: true, encoding: .utf8) }

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([directory])
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
        TerminalManager.openExternalFiles(Array(files[2...3]), preferred: manager, destination: target) {
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

        TerminalManager.openExternalFiles([files[1]], preferred: manager, destination: target) {
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

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([firstRoot])
        let first = try XCTUnwrap(manager.selectedProject)
        let empty = try XCTUnwrap(first.dock.root.groups.first(where: { $0.items.isEmpty }))
        manager.addLocalItems([otherRoot])
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
        TerminalManager.openExternalFiles([otherFile], preferred: manager, destination: destination)
        XCTAssertEqual(first.tabs.count, 2)
        XCTAssertEqual(other.tabs.count, 0)
        XCTAssertEqual(manager.selectedProjectID, first.id)
        let secondTab = try XCTUnwrap(first.selectedTab)
        XCTAssertEqual(first.dock.group(containing: .tab(secondTab.id))?.id, empty.id)
        XCTAssertEqual(first.dock.group(containing: .tab(firstTab.id))?.id, empty.id)
        XCTAssertEqual(try String(contentsOf: otherFile, encoding: .utf8), "other")
    }

    func testFinderDropDoesNotRouteLateProvidersIntoAnotherOrClosedWindow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("slow.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let manager = TerminalManager()
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

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([folder])
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
        TerminalManager.openExternalFiles([first, second], preferred: manager) {
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
        TerminalManager.openExternalFiles([second], preferred: manager)
        guard case .file(let reused) = try XCTUnwrap(manager.selectedProject?.selectedTab).content
        else { return XCTFail("The previous buffer must still exist") }
        XCTAssertTrue(reused === existing)
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(project.tabs.count, 2)

        TerminalManager.openExternalFiles([folder], preferred: manager)
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
        TerminalManager.openExternalFiles([imagePath], preferred: manager)
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

    func testFinderReusesMacFileInsideRemoteProjectInAnotherWindow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("same.swift")
        try "local bytes".write(to: file, atomically: true, encoding: .utf8)

        let a = TerminalManager()
        let b = TerminalManager()
        defer { a.windowClosed(); b.windowClosed() }
        a.addLocalItems([folder])
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
        TerminalManager.openExternalFiles([file], preferred: a) { handled = $0 }
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
        a.addLocalItems([local])
        b.addLocalItems([existing])
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
        TerminalManager.openExternalFiles([first, opened, last], preferred: a) { result = $0 }
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
        receiver.addLocalItems([root])
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
