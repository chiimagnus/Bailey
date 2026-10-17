import AppKit
import Foundation
import Observation
import SwiftUI
import XCTest
@testable import kero

private actor EditorWorkspaceFixture: WorkspaceBackend {
    enum Rejection: Error { case simulated }

    private struct PendingWrite {
        let path: String
        let data: Data
        let finish: CheckedContinuation<Void, Error>
    }

    private var files: [String: Data]
    private var writing: PendingWrite?
    private var reading: [CheckedContinuation<Data, Error>] = []
    private var nextReadPaused = false
    private(set) var readCount = 0
    private(set) var writingPath: String?
    private(set) var readingPath: String?
    var pendingReadCount: Int { reading.count }

    init(path: String, contents: Data) { files = [path: contents] }

    func pauseOneRead() { nextReadPaused = true }
    func finishRead(with data: Data? = nil) {
        guard !reading.isEmpty else { return }
        let continuation = reading.removeFirst()
        if reading.isEmpty { readingPath = nil }
        if let data { continuation.resume(returning: data) }
        else { continuation.resume(throwing: Rejection.simulated) }
    }
    func finishWrite(failing: Bool = false) {
        guard let pending = writing else { return }
        writing = nil
        writingPath = nil
        if failing {
            pending.finish.resume(throwing: Rejection.simulated)
        } else {
            files[pending.path] = pending.data
            pending.finish.resume()
        }
    }
    func data(at path: String) -> Data? { files[path] }
    func replace(path: String, with data: Data) { files[path] = data }

    func read(path: String, maxBytes: Int) async throws -> Data {
        readCount += 1
        guard let data = files[path] else { throw WorkspaceError.notFound }
        guard data.count <= maxBytes else { throw WorkspaceError.tooLarge }
        if nextReadPaused {
            nextReadPaused = false
            readingPath = path
            return try await withCheckedThrowingContinuation { reading.append($0) }
        }
        return data
    }
    func write(path: String, data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writingPath = path
            writing = PendingWrite(path: path, data: data, finish: continuation)
        }
    }

    func list(directory: String) async throws -> [WorkspaceEntry] { [] }
    func stat(path: String) async throws -> WorkspaceStat? { nil }
    func readSymlinkDestination(path: String) async throws -> String? { nil }
    func createFile(path: String) async throws { throw WorkspaceError.notFound }
    func createDirectory(path: String) async throws { throw WorkspaceError.notFound }
    func rename(from: String, to: String) async throws {
        guard let data = files.removeValue(forKey: from) else { throw WorkspaceError.notFound }
        files[to] = data
    }
    func delete(paths: [String]) async throws { throw WorkspaceError.notFound }
    func gitRoot(containing path: String) async throws -> String? { nil }
    func isLinkedWorktree(_ root: String) async throws -> Bool { false }
    func run(argv: [String], cwd: String?, env: [String: String]?, stdin: Data?, timeout: TimeInterval?) async throws -> WorkspaceRunResult {
        throw WorkspaceError.notFound
    }
    func processes(descendantsOf pid: pid_t) async throws -> WorkspaceProcessSnapshot {
        .init(descendants: [], namesByPid: [:])
    }
    func listeningPorts(pids: [pid_t]) async throws -> [WorkspacePort] { [] }
    func kill(pid: pid_t, force: Bool) async throws { throw WorkspaceError.notFound }
}

@MainActor
final class FileTabTests: XCTestCase {
    func testCanonicalEquivalentNativeReplacementUndoAndSavePreserveBytes() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let composed = "café 中文👋\r\n"
        let decomposed = "cafe\u{301} 中文👋\r\n"
        try Data(composed.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        let host = NSHostingView(rootView: FileViewerView(file: file))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(mountedEditor(in: host))
        editor.insertText(decomposed, replacementRange: NSRange(location: 0, length: composed.utf16.count))
        editor.breakUndoCoalescing()
        XCTAssertEqual(Data((editor.text ?? "").utf8), Data(decomposed.utf8))
        XCTAssertEqual(Data(file.text.utf8), Data(decomposed.utf8))
        XCTAssertTrue(file.isDirty)
        editor.undoManager?.undo()
        XCTAssertEqual(Data(file.text.utf8), Data(composed.utf8))
        XCTAssertFalse(file.isDirty)
        editor.undoManager?.redo()
        XCTAssertTrue(file.isDirty)
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), Data(decomposed.utf8))
        XCTAssertFalse(file.isDirty)
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: decomposed.utf16.count))
        editor.setMarkedText("中文👋", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("中文👋", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(Data(file.text.utf8), Data("中文👋".utf8))
        await file.save()
        XCTAssertEqual(try Data(contentsOf: path), Data("中文👋".utf8))
    }

    func testCanonicalEquivalentCleanReloadInstallsNewBytes() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let composed = "café 中文👋\r\n"
        let decomposed = "cafe\u{301} 中文👋\r\n"
        try Data(composed.utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        let revision = file.reloadRevision
        try Data(decomposed.utf8).write(to: path)
        file.reloadFromDiskIfClean()
        try await file.waitForText()
        XCTAssertEqual(Data(file.text.utf8), Data(decomposed.utf8))
        XCTAssertEqual(file.reloadRevision, revision + 1)
        let updated = file.reloadRevision
        file.reloadFromDiskIfClean()
        try await file.waitForText()
        XCTAssertEqual(file.reloadRevision, updated, "Identical bytes must not replace the document")
        XCTAssertFalse(file.isDirty)
    }

    func testCanonicalEquivalentEditDuringWriteRemainsDirty() async throws {
        let path = "/fixture/canonical.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("baseline".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        file.text = "café"
        file.refreshDirtyState()
        let saving = Task { await file.save() }
        try await wait { await backend.writingPath == path }
        file.text = "cafe\u{301}"
        file.refreshDirtyState()
        await backend.finishWrite()
        await saving.value
        let stored = await backend.data(at: path)
        XCTAssertEqual(stored, Data("café".utf8))
        XCTAssertTrue(file.isDirty, "A completed write must not claim different current bytes were saved")
        XCTAssertEqual(Data(file.text.utf8), Data("cafe\u{301}".utf8))
    }

    func testUnconsumedTabDoesNotReadAndWaitLoadsExactlyOnce() async throws {
        let path = "/fixture/lazy.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        await Task.yield()
        let before = await backend.readCount
        XCTAssertEqual(before, 0)
        try await backend.rename(from: path, to: "/fixture/renamed-lazy.txt")
        file.updatePath("/fixture/renamed-lazy.txt")
        await Task.yield()
        let afterRename = await backend.readCount
        XCTAssertEqual(afterRename, 0)
        try await file.waitForText()
        try await file.waitForText()
        XCTAssertEqual(file.text, "original")
        let after = await backend.readCount
        XCTAssertEqual(after, 1)
    }

    func testInitialReadFollowsRenameAndOldReadCannotWin() async throws {
        let backend = EditorWorkspaceFixture(path: "/fixture/old.txt", contents: Data("original".utf8))
        await backend.pauseOneRead()
        let file = FileTab(path: "/fixture/old.txt", backend: backend, workspaceIdentity: nil)
        file.loadIfNeeded()
        try await wait { await backend.pendingReadCount == 1 }
        try await backend.rename(from: file.path, to: "/fixture/new.txt")
        await backend.pauseOneRead()
        file.updatePath("/fixture/new.txt")
        try await wait { await backend.pendingReadCount == 2 }
        await backend.finishRead(with: Data("stale".utf8))
        XCTAssertEqual(file.text, "")
        await backend.finishRead(with: Data("new path content".utf8))
        try await file.waitForText()
        XCTAssertEqual(file.text, "new path content")
        XCTAssertEqual(file.path, "/fixture/new.txt")
    }

    func testLocalTextReadCapacityAndFailureKinds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for count in [0, (5 << 20) - 1, 5 << 20, (5 << 20) + 1] {
            let path = root.appendingPathComponent("\(count).txt")
            try Data(repeating: 65, count: count).write(to: path)
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            guard case .loading = file.content else { return XCTFail("init must remain lazy") }
            if count <= 5 << 20 {
                try await file.waitForText()
                XCTAssertEqual(file.text.utf8.count, count)
            } else {
                do { try await file.waitForText(); XCTFail("Expected capacity rejection") } catch {}
                guard case .unavailable(let reason) = file.content else { return XCTFail("Expected capacity placeholder") }
                XCTAssertEqual(reason, String(localized: "File is too large to open", table: "Workspace"))
            }
        }
        let missing = FileTab(path: root.appendingPathComponent("missing.txt").path,
                              backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        do { try await missing.waitForText(); XCTFail("Expected missing read failure") } catch {}
        guard case .unavailable(let reason) = missing.content else { return XCTFail("Expected read failure") }
        XCTAssertEqual(reason, String(localized: "Could not read file", table: "Workspace"))
        try Data("recovered".utf8).write(to: URL(fileURLWithPath: missing.path))
        try await missing.waitForText()
        XCTAssertEqual(missing.text, "recovered")
    }

    func testLocalSymbolicLinkUsesTargetContents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("link.txt")
        let original = "symlink 中文 👋\r\n"
        try Data(original.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let file = FileTab(path: link.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        XCTAssertEqual(Data(file.text.utf8), Data(original.utf8))
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: target), Data(original.utf8))
    }

    func testInvalidUTF8AndImageFallbackRespectTextCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binaryReason = String(localized: "Binary file", table: "Workspace")
        let sizeReason = String(localized: "File is too large to open", table: "Workspace")
        for (name, data, expected) in [
            ("invalid.txt", Data([0xff, 0xfe, 0x00]), binaryReason),
            ("invalid.png", Data([0xff, 0xfe, 0x00]), binaryReason),
            ("oversized.png", Data(repeating: 0xff, count: (5 << 20) + 1), sizeReason),
        ] {
            let path = directory.appendingPathComponent(name)
            try data.write(to: path)
            let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            do {
                try await file.waitForText()
                XCTFail("Expected unavailable content for \(name)")
            } catch {}
            guard case .unavailable(let reason) = file.content else {
                return XCTFail("Expected unavailable content for \(name)")
            }
            XCTAssertEqual(reason, expected)
            XCTAssertFalse(file.isDirty)
        }
        let imageNamedText = directory.appendingPathComponent("plain.png")
        try Data("not an image; valid UTF-8".utf8).write(to: imageNamedText)
        let file = FileTab(path: imageNamedText.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        XCTAssertEqual(file.text, "not an image; valid UTF-8")

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let imagePath = directory.appendingPathComponent("valid.png")
        try png.write(to: imagePath)
        let image = FileTab(path: imagePath.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        image.loadIfNeeded()
        try await wait { if case .image = image.content { return true }; return false }
        guard case .image(let preview) = image.content else { return XCTFail("Expected actual image preview") }
        XCTAssertEqual(preview.representations.first?.pixelsWide, 2)
    }

    func testNativeReadOnlyRejectsAXValueAndSelectionReplacement() {
        let editor = FocusReportingTextView()
        editor.text = "original"
        editor.isEditable = false
        editor.textSelection = NSRange(location: 0, length: 8)
        XCTAssertFalse(editor.isAccessibilitySelectorAllowed(#selector(editor.setAccessibilityValue(_:))))
        editor.setAccessibilityValue("overwritten")
        XCTAssertEqual(editor.text, "original")
        editor.setAccessibilitySelectedText("overwritten selection")
        XCTAssertEqual(editor.text, "original")
        XCTAssertEqual(editor.accessibilityValue() as? String, "original")
    }

    func testMountedEditorDisconnectReconnectKeepsNativeBufferAndUndo() async throws {
        let project = Project(fallbackName: "native read-only", workspaceConfiguration: .standard)
        defer { project.terminateAll() }
        let connection = RemoteConnection(user: "fixture", host: "invalid", port: 2222,
            controlSocket: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), sshPID: 0)
        connection.workingDirectory = "/fixture"
        connection.markConnected()
        XCTAssertTrue(project.newSession().beginRemoteConnection(connection))
        let backend = EditorWorkspaceFixture(path: "/fixture/file.txt", contents: Data("original".utf8))
        let file = FileTab(path: "/fixture/file.txt", backend: backend, workspaceIdentity: connection.workspaceIdentity)
        try await file.waitForText()
        file.autoSaveSuspendedForClose = true
        file.text = "unsaved"
        file.refreshDirtyState()
        project.append(PaneTab(content: .file(file)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = host
        window.orderFront(nil)
        try await wait { host.layoutSubtreeIfNeeded(); return self.mountedEditor(in: host) != nil }
        let editor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertTrue(editor.isEditable)
        connection.markDisconnected(reason: "controlled outage")
        try await wait { host.layoutSubtreeIfNeeded(); return !editor.isEditable }
        editor.setAccessibilityValue("must not replace")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        editor.keyDown(with: event)
        XCTAssertEqual(editor.text, "unsaved")
        connection.markConnected()
        try await wait { host.layoutSubtreeIfNeeded(); return editor.isEditable }
        XCTAssertTrue(mountedEditor(in: host) === editor)
        editor.insertText("new ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(file.text, "new unsaved")
        editor.breakUndoCoalescing()
        editor.undoManager?.undo()
        XCTAssertEqual(file.text, "unsaved")
        XCTAssertTrue(file.isDirty)
    }

    func testFixedHostDisconnectRebindsDirtyFileWithoutLosingDraft() async throws {
        let host = "fixture-\(UUID().uuidString)"
        let project = Project(fallbackName: "fixed host", workspaceConfiguration: .standard)
        project.sshHost = host
        let path = "/fixture/file.txt"
        let file = FileTab(path: path, backend: EditorWorkspaceFixture(path: path, contents: Data("original".utf8)),
                           workspaceIdentity: "ssh:" + host)
        try await file.waitForText()
        file.text = "unsaved"
        file.refreshDirtyState()
        project.append(PaneTab(content: .file(file)))
        SSHHostWorkspaces.setConnected(false, for: host)
        XCTAssertNil(project.connectedWorkspace(for: "ssh:" + host))
        try await wait { file.readOnlyReason != nil }
        guard file.readOnlyReason != nil else { return }
        await file.save()
        XCTAssertEqual(file.text, "unsaved")
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
        SSHHostWorkspaces.setConnected(true, for: host)
        XCTAssertNil(file.readOnlyReason)
        XCTAssertEqual(file.text, "unsaved")
        XCTAssertTrue(file.isDirty)
    }

    func testUnconsumedRemoteTabRemainsLazyAcrossReconnect() async throws {
        let path = "/fixture/restored.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("restored".utf8))
        let identity = "ssh:p2-\(UUID().uuidString)"
        let file = FileTab(path: path, backend: backend, workspaceIdentity: identity)
        file.rebindWorkspace(to: nil)
        file.rebindWorkspace(to: backend)
        try await Task.sleep(for: .milliseconds(80))
        let unreadCount = await backend.readCount
        XCTAssertEqual(unreadCount, 0, "Reconnect must not read an unconsumed restored tab")
        try await file.waitForText()
        let loadedCount = await backend.readCount
        XCTAssertEqual(loadedCount, 1)
        XCTAssertEqual(file.text, "restored")
    }

    func testVisibleRemoteTabRecoversWhenConnectionReturns() async throws {
        let path = "/fixture/visible.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("visible".utf8))
        let identity = "ssh:p2-\(UUID().uuidString)"
        let file = FileTab(path: path, backend: backend, workspaceIdentity: identity)
        file.rebindWorkspace(to: nil)
        file.refreshWhenSelected()
        file.rebindWorkspace(to: backend)
        try await wait { if case .text = file.content { return true }; return false }
        XCTAssertEqual(file.text, "visible")
        let readCount = await backend.readCount
        XCTAssertEqual(readCount, 1)
    }

    func testWindowFocusRefreshesOnlyItsMountedFile() async throws {
        let pathA = "/fixture/\(UUID().uuidString)-A.txt"
        let pathB = "/fixture/\(UUID().uuidString)-B.txt"
        let backendA = EditorWorkspaceFixture(path: pathA, contents: Data("original A".utf8))
        let backendB = EditorWorkspaceFixture(path: pathB, contents: Data("original B".utf8))
        let fileA = FileTab(path: pathA, backend: backendA, workspaceIdentity: nil)
        let fileB = FileTab(path: pathB, backend: backendB, workspaceIdentity: nil)
        let windowA = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let windowB = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                               styleMask: [.titled], backing: .buffered, defer: false)
        windowA.isReleasedWhenClosed = false
        windowB.isReleasedWhenClosed = false
        defer { windowA.close(); windowB.close() }
        let hostA = NSHostingView(rootView: FileViewerView(file: fileA))
        let hostB = NSHostingView(rootView: FileViewerView(file: fileB))
        windowA.contentView = hostA
        windowB.contentView = hostB
        windowA.orderFront(nil)
        windowB.orderFront(nil)
        try await fileA.waitForText()
        try await fileB.waitForText()
        try await wait {
            hostA.layoutSubtreeIfNeeded()
            hostB.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: hostA) != nil && self.mountedEditor(in: hostB) != nil
        }
        let beforeB = await backendB.readCount
        await backendA.replace(path: pathA, with: Data("external A".utf8))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: windowA)
        try await wait { fileA.text == "external A" }
        try await Task.sleep(for: .milliseconds(40))
        let afterB = await backendB.readCount
        XCTAssertEqual(afterB, beforeB, "Switching to A must not re-read the mounted file in window B")
        XCTAssertEqual(fileB.text, "original B")
    }

    func testImagePreviewReloadIsScopedToItsWindow() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let path = "/fixture/\(UUID().uuidString).png"
        let backend = EditorWorkspaceFixture(path: path, contents: png)
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            if case .image = file.content { return true }
            return false
        }
        let before = await backend.readCount
        let revision = file.reloadRevision
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await wait { await backend.pendingReadCount == 1 }
        await backend.finishRead()
        try await Task.sleep(for: .milliseconds(60))
        if case .image = file.content {} else { XCTFail("Transient read failure must keep preview") }
        XCTAssertNotNil(file.reloadError)
        XCTAssertEqual(file.reloadRevision, revision)
        await backend.replace(path: path, with: Data("external text".utf8))
        let unrelated = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        defer { unrelated.close() }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: unrelated)
        try await Task.sleep(for: .milliseconds(30))
        let afterUnrelated = await backend.readCount
        XCTAssertEqual(afterUnrelated, before + 1, "Other windows must not reload this image")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await wait { file.text == "external text" }
        let afterOwn = await backend.readCount
        XCTAssertEqual(afterOwn, before + 2)
        XCTAssertNil(file.reloadError)
    }

    func testRepeatedWindowFocusCoalescesInFlightCleanRefresh() async throws {
        let path = "/fixture/\(UUID().uuidString)-focus.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await wait { await backend.pendingReadCount == 1 }
        await backend.replace(path: path, with: Data("updated".utf8))
        for _ in 0..<12 { file.refreshWhenSelected() }
        try await Task.sleep(for: .milliseconds(100))
        let reads = await backend.readCount
        await backend.finishRead(with: Data("original".utf8))
        try await wait { file.text == "updated" }
        let total = await backend.readCount
        XCTAssertEqual(reads, 2, "Repeated activation must reuse the pending disk read")
        XCTAssertEqual(total, 3, "One follow-up read must observe later changes without a refresh storm")
        XCTAssertEqual(file.text, "updated")
    }

    func testQueuedRefreshCannotResurrectAfterDirtyEdit() async throws {
        let path = "/fixture/\(UUID().uuidString)-edit.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await wait { await backend.pendingReadCount == 1 }
        file.refreshWhenSelected()
        file.text = "user draft"
        file.refreshDirtyState()
        await backend.finishRead(with: Data("late disk snapshot".utf8))
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(file.text, "user draft")
        XCTAssertTrue(file.isDirty)
        let reads = await backend.readCount
        XCTAssertEqual(reads, 2)
    }

    func testQueuedRefreshCannotResurrectAfterSSHDisconnect() async throws {
        let path = "/fixture/\(UUID().uuidString)-ssh.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend,
                           workspaceIdentity: "ssh:fixture-\(UUID().uuidString)")
        try await file.waitForText()
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await wait { await backend.pendingReadCount == 1 }
        file.refreshWhenSelected()
        file.rebindWorkspace(to: nil)
        await backend.finishRead(with: Data("late disconnected data".utf8))
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(file.text, "original")
        XCTAssertNotNil(file.readOnlyReason)
        let reads = await backend.readCount
        XCTAssertEqual(reads, 2, "Old pending focus must not retry over a disconnected channel")
        file.rebindWorkspace(to: backend)
        try await file.waitForText()
        XCTAssertNil(file.readOnlyReason)
        XCTAssertEqual(file.text, "original")
        let recoveredCount = await backend.readCount
        XCTAssertEqual(recoveredCount, 3)
    }

    func testTransientCleanRefreshErrorPreservesLoadedTextAndRecovers() async throws {
        let path = "/fixture/\(UUID().uuidString)-transient.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        let revision = file.reloadRevision
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await wait { await backend.pendingReadCount == 1 }
        await backend.finishRead()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(file.text, "original", "A transient refresh failure cannot erase a loaded preview")
        if case .text = file.content {} else { XCTFail("A loaded document must survive a transient read error") }
        XCTAssertEqual(file.reloadRevision, revision)
        XCTAssertNotNil(file.reloadError, "Stale cached content must be visibly identified")
        await backend.replace(path: path, with: Data("recovered".utf8))
        file.refreshWhenSelected()
        try await file.waitForText()
        XCTAssertEqual(file.text, "recovered")
        XCTAssertNil(file.reloadError)
        try await backend.rename(from: path, to: path + ".gone")
        file.refreshWhenSelected()
        try await wait { if case .unavailable = file.content { return true }; return false }
        XCTAssertEqual(file.text, "", "A genuinely removed file must not masquerade as loaded data")
        XCTAssertNil(file.reloadError)
    }

    func testAppendRejectsStaleCachedTextWhenFreshReadFails() async throws {
        let path = "/fixture/\(UUID().uuidString)-ignore.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("old-rule\n".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        await backend.pauseOneRead()
        let append = Task {
            try await file.waitForTextBeforeAppending()
            file.appendText("/unsafe\n")
        }
        try await wait { await backend.pendingReadCount == 1 }
        await backend.finishRead()
        do {
            try await append.value
            XCTFail("A failed freshness check must not silently save stale .gitignore rules")
        } catch {}
        XCTAssertEqual(file.text, "old-rule\n")
        XCTAssertFalse(file.isDirty)
        let unchanged = await backend.data(at: path)
        XCTAssertEqual(unchanged, Data("old-rule\n".utf8))
        await backend.replace(path: path, with: Data("external-rule\n".utf8))
        try await file.waitForTextBeforeAppending()
        file.appendText("/safe\n")
        XCTAssertEqual(file.text, "external-rule\n/safe\n")
        XCTAssertTrue(file.isDirty)
    }

    func testFailedRefreshBlocksStaleWritesUntilSuccessfulRetry() async throws {
        let path = "/fixture/\(UUID().uuidString)-protected.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await wait { await backend.pendingReadCount == 1 }
        await backend.finishRead()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotNil(file.reloadError)
        file.text = "stale edit"
        file.refreshDirtyState()
        let attempted = Task { await file.save() }
        try await Task.sleep(for: .milliseconds(100))
        let unexpectedWrite = await backend.writingPath
        if unexpectedWrite != nil { await backend.finishWrite(failing: true) }
        await attempted.value
        XCTAssertNil(unexpectedWrite, "A stale preview must not initiate a disk write")
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.reloadError)
        let unchanged = await backend.data(at: path)
        XCTAssertEqual(unchanged, Data("original".utf8), "Refresh failure must block a stale write")
        file.text = "original"
        file.refreshDirtyState()
        file.refreshWhenSelected()
        try await file.waitForText()
        XCTAssertNil(file.reloadError)
        file.text = "new edit"
        file.refreshDirtyState()
        let saved = Task { await file.save() }
        try await wait { await backend.writingPath == path }
        await backend.finishWrite()
        await saved.value
        XCTAssertFalse(file.isDirty)
        let result = await backend.data(at: path)
        XCTAssertEqual(result, Data("new edit".utf8))
    }

    func testNativeEditorSurvivesTransientRefreshFailureWithUndo() async throws {
        let path = "/fixture/\(UUID().uuidString)-native.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        try await file.waitForText()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = host
        window.orderFront(nil)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) != nil
        }
        let editor = try XCTUnwrap(mountedEditor(in: host))
        try await Task.sleep(for: .milliseconds(50))
        let revision = file.reloadRevision
        await backend.pauseOneRead()
        file.refreshWhenSelected()
        try await wait { await backend.pendingReadCount == 1 }
        await backend.finishRead()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(file.reloadRevision, revision)
        XCTAssertTrue(mountedEditor(in: host) === editor)
        XCTAssertEqual(editor.text, "original")
        XCTAssertNotNil(file.reloadError)
        guard !editor.isEditable else {
            return XCTFail("A stale cached editor must stay read-only until a successful refresh")
        }
        editor.setAccessibilityValue("attempt overwrite")
        XCTAssertEqual(file.text, "original")
        file.refreshWhenSelected()
        try await file.waitForText()
        try await wait { host.layoutSubtreeIfNeeded(); return file.reloadError == nil && editor.isEditable }
        XCTAssertTrue(mountedEditor(in: host) === editor)
        editor.insertText("hello ", replacementRange: NSRange(location: 0, length: 0))
        editor.breakUndoCoalescing()
        XCTAssertEqual(file.text, "hello original")
        editor.undoManager?.undo()
        XCTAssertEqual(file.text, "original")
        XCTAssertFalse(file.isDirty)
        file.autoSaveSuspendedForClose = true
    }

    func testWindowActivationDoesNotRestartInFlightInitialRead() async throws {
        let path = "/fixture/initial.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("initial".utf8))
        await backend.pauseOneRead()
        let file = FileTab(path: path, backend: backend, workspaceIdentity: nil)
        let host = NSHostingView(rootView: FileViewerView(file: file))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await wait { await backend.pendingReadCount == 1 }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await Task.sleep(for: .milliseconds(80))
        let readsDuringLoad = await backend.readCount
        XCTAssertEqual(readsDuringLoad, 1, "Window focus must reuse the pending initial read")
        await backend.finishRead(with: Data("initial".utf8))
        try await file.waitForText()
        XCTAssertEqual(file.text, "initial")
    }

    func testFixedHostDisconnectBeforeLoadShowsReasonWithoutReading() async throws {
        let host = "fixture-\(UUID().uuidString)"
        let project = Project(fallbackName: "offline", workspaceConfiguration: .standard)
        project.sshHost = host
        let backend = EditorWorkspaceFixture(path: "/fixture/file.txt", contents: Data("original".utf8))
        let file = FileTab(path: "/fixture/file.txt", backend: backend, workspaceIdentity: "ssh:" + host)
        project.append(PaneTab(content: .file(file)))
        SSHHostWorkspaces.setConnected(false, for: host)
        guard case .unavailable(let reason) = file.content else { return XCTFail("Must not remain blank/loading") }
        XCTAssertEqual(reason, file.readOnlyReason)
        let reads = await backend.readCount
        XCTAssertEqual(reads, 0)
    }

    func testAppendWaitsForReplacementReadWithoutUsingLoadingOrCachedText() async throws {
        for initiallyLoading in [true, false] {
            let path = "/fixture/.gitignore"
            let backend = EditorWorkspaceFixture(path: path, contents: Data("cached\n".utf8))
            if initiallyLoading { await backend.pauseOneRead() }
            let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
            file.loadIfNeeded()
            file.autoSaveSuspendedForClose = true
            if !initiallyLoading {
                try await wait { if case .text = file.content { return true }; return false }
                await backend.pauseOneRead()
                file.reloadFromDiskIfClean()
            }
            try await wait { await backend.pendingReadCount == 1 }
            let premature = expectation(description: "Wait must follow the replacement read")
            premature.isInverted = true
            let waiting = expectation(description: "Append began waiting for the first read")
            var checkingEarlyCompletion = true
            let append = Task {
                defer { if checkingEarlyCompletion { premature.fulfill() } }
                waiting.fulfill()
                try await file.waitForText()
                file.appendText("/new\n")
            }
            await fulfillment(of: [waiting], timeout: 1)
            await backend.pauseOneRead()
            file.reloadFromDiskIfClean()
            try await wait { await backend.pendingReadCount == 2 }
            await backend.finishRead(with: Data("superseded\n".utf8))
            await fulfillment(of: [premature], timeout: 0.1)
            checkingEarlyCompletion = false
            await backend.finishRead(with: Data("latest rules\n".utf8))
            do { try await append.value } catch { XCTFail(error.localizedDescription) }
            XCTAssertEqual(file.text, "latest rules\n/new\n")
            XCTAssertTrue(file.isDirty)
        }
    }

    func testAppendWaitsForRemoteReadAndRetainsTextOnSaveFailure() async throws {
        let path = "/fixture/.gitignore"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("existing\n".utf8))
        await backend.pauseOneRead()
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        file.loadIfNeeded()
        try await wait { await backend.readingPath == path }
        let append = Task {
            try await file.waitForText()
            file.appendText("/new\n")
            await file.save()
        }
        await Task.yield()
        XCTAssertEqual(file.text, "")
        await backend.finishRead(with: Data("existing\n".utf8))
        try await wait { await backend.writingPath == path }
        await backend.finishWrite(failing: true)
        try await append.value
        XCTAssertEqual(file.text, "existing\n/new\n")
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
        let stored = await backend.data(at: path)
        XCTAssertEqual(stored, Data("existing\n".utf8))
        file.autoSaveSuspendedForClose = true
    }
    private func mountedEditor(in view: NSView) -> FocusReportingTextView? {
        if let editor = view as? FocusReportingTextView { return editor }
        return view.subviews.lazy.compactMap { self.mountedEditor(in: $0) }.first
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else { return XCTFail("Editor operation did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testGitPreparationWaitsForWritesAndNeverClosesOrLosesEditedTab() async throws {
        let project = Project(fallbackName: "Git Save", workspaceConfiguration: .standard)
        let path = "/fixture/git/file.txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("baseline".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()
        let tab = PaneTab(content: .file(file))
        project.append(tab)
        try await wait { if case .text = file.content { return true }; return false }
        file.text = "first edit"
        file.refreshDirtyState()
        let saving = Task {
            await project.saveBeforeGitAction(repository: "/fixture/git", scope: "ssh:fixture", isCurrent: { true })
        }
        try await wait { await backend.writingPath == path }
        file.text = "new edit while saving"
        file.refreshDirtyState()
        await backend.finishWrite()
        let prepared = await saving.value
        XCTAssertFalse(prepared)
        XCTAssertTrue(project.tabs.contains { $0 === tab })
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, "new edit while saving")
        let persisted = await backend.data(at: path)
        XCTAssertEqual(persisted, Data("first edit".utf8))

        let failed = Task {
            await project.saveBeforeGitAction(repository: "/fixture/git", scope: "ssh:fixture", isCurrent: { true })
        }
        try await wait { await backend.writingPath == path }
        await backend.finishWrite(failing: true)
        let readyAfterFailure = await failed.value
        XCTAssertFalse(readyAfterFailure)
        XCTAssertTrue(project.tabs.contains { $0 === tab })
        XCTAssertEqual(file.text, "new edit while saving")
        XCTAssertNotNil(file.saveError)
    }

    func testGitPreparationMatchesNativePrivatePathAliasWithoutSavingOtherRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside.txt")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("baseline".utf8).write(to: inside)
        try Data("other repository".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let project = Project(fallbackName: "Aliases", workspaceConfiguration: .standard)
        let selected = FileTab(path: inside.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await selected.waitForText()
        let other = FileTab(path: outside.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await other.waitForText()
        project.append(PaneTab(content: .file(selected)))
        project.append(PaneTab(content: .file(other)))
        selected.text = "save selected"
        selected.refreshDirtyState()
        other.text = "keep unsaved elsewhere"
        other.refreshDirtyState()
        let repository = root.path.hasPrefix("/var/") ? "/private" + root.path : root.path
        let prepared = await project.saveBeforeGitAction(repository: repository, scope: "local", isCurrent: { true })
        XCTAssertTrue(prepared)
        XCTAssertEqual(try String(contentsOf: inside, encoding: .utf8), "save selected")
        XCTAssertFalse(selected.isDirty)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "other repository")
        XCTAssertTrue(other.isDirty)
    }

    func testProjectCloseWaitsForFileSaveAndRetainsUnsavedOnFailure() async throws {
        let prior = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer { SessionStore.save(prior); TerminalHistoryStore.save(histories) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let firstProject = try XCTUnwrap(manager.selectedProject)
        let firstURL = root.appendingPathComponent("must-save.txt")
        try "before".write(to: firstURL, atomically: true, encoding: .utf8)
        let local = FileTab(path: firstURL.path, backend: LocalWorkspaceBackend.shared,
                            workspaceIdentity: nil)
        try await local.waitForText()
        firstProject.append(PaneTab(content: .file(local)))
        local.text = "durably saved"
        local.refreshDirtyState()
        manager.close(firstProject)
        try await wait { !manager.projects.contains(where: { $0 === firstProject }) }
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "durably saved")

        manager.addLocalItems([root])
        let failingProject = try XCTUnwrap(manager.selectedProject)
        let remotePath = root.appendingPathComponent("remote.txt")
        try "local sentinel".write(to: remotePath, atomically: true, encoding: .utf8)
        let backend = EditorWorkspaceFixture(path: remotePath.path, contents: Data("old".utf8))
        let remote = FileTab(path: remotePath.path, backend: backend,
                             workspaceIdentity: "ssh:fixture")
        try await remote.waitForText()
        failingProject.append(PaneTab(content: .file(remote)))
        remote.text = "draft not yet persisted"
        remote.refreshDirtyState()
        manager.close(failingProject)
        try await wait { await backend.writingPath == remotePath.path }
        await backend.finishWrite(failing: true)
        try await wait { remote.saveError != nil }
        XCTAssertTrue(manager.projects.contains(where: { $0 === failingProject }))
        XCTAssertTrue(remote.isDirty)
        XCTAssertEqual(try String(contentsOf: remotePath, encoding: .utf8), "local sentinel")

        XCTAssertTrue(TerminalManager.hasUnsavedEditors)
        let exitAttempt = Task { await TerminalManager.saveBeforeTermination() }
        try await wait { await backend.writingPath == remotePath.path }
        await backend.finishWrite(failing: true)
        let shouldExit = await exitAttempt.value
        XCTAssertFalse(shouldExit, "A failed auto-save must veto application termination")
        XCTAssertTrue(remote.isDirty)
    }

    func testProjectTabSwitchAndCloseAutomaticallySaveBeforeRemoving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("autosave.txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        let project = Project(fallbackName: "autosave", workspaceConfiguration: .standard)
        let filePane = PaneTab(content: .file(file))
        project.append(filePane)

        file.text = "saved when selecting the browser"
        file.refreshDirtyState()
        project.append(PaneTab(content: .browser(BrowserTab(initialFocus: .none))))
        try await wait { !file.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved when selecting the browser")

        file.text = "saved when closing the file"
        file.refreshDirtyState()
        project.close(filePane)
        try await wait { !project.tabs.contains(where: { $0.id == filePane.id }) }
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved when closing the file")
    }

    func testFilesPanelABATabSwitchKeepsEachNativeEditorAndCorrectSaveTarget() async throws {
        let snapshots = SessionStore.load()
        let histories = TerminalHistoryStore.load()
        defer {
            SessionStore.save(snapshots)
            TerminalHistoryStore.save(histories)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aPath = root.appendingPathComponent("A.swift")
        let bPath = root.appendingPathComponent("B.swift")
        try "let fileA = \"only A\"\n".write(to: aPath, atomically: true, encoding: .utf8)
        try "let fileB = \"only B\"\n".write(to: bPath, atomically: true, encoding: .utf8)

        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalItems([root])
        let project = try XCTUnwrap(manager.selectedProject)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()

        // Same entry point used by a file row in the real Files panel.
        manager.openFile(aPath.path)
        let a = try XCTUnwrap(project.tabs.compactMap {
            if case .file(let file) = $0.content, file.path == aPath.path { return file }
            return nil
        }.first)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host)?.text == a.text
                && a.editorView?.window === window
        }
        let aEditor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertEqual(aEditor.text, "let fileA = \"only A\"\n")

        manager.openFile(bPath.path)
        let b = try XCTUnwrap(project.tabs.compactMap {
            if case .file(let file) = $0.content, file.path == bPath.path { return file }
            return nil
        }.first)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host)?.text == b.text
                && b.editorView?.window === window
        }
        let bEditor = try XCTUnwrap(mountedEditor(in: host))
        XCTAssertFalse(aEditor === bEditor)
        XCTAssertEqual(bEditor.text, "let fileB = \"only B\"\n")

        manager.openFile(aPath.path)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) === aEditor
                && a.editorView?.window === window
        }
        XCTAssertEqual(aEditor.text, "let fileA = \"only A\"\n")
        XCTAssertEqual(a.text, aEditor.text)

        // Editing after switching back must never modify B's model or bytes.
        aEditor.insertText("// edited A\n", replacementRange: NSRange(location: 0, length: 0))
        try await wait { a.isDirty }
        XCTAssertEqual(b.text, "let fileB = \"only B\"\n")
        manager.openFile(bPath.path)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) === bEditor && !a.isDirty
        }
        XCTAssertEqual(try String(contentsOf: aPath, encoding: .utf8),
                       "// edited A\nlet fileA = \"only A\"\n")
        XCTAssertEqual(try String(contentsOf: bPath, encoding: .utf8),
                       "let fileB = \"only B\"\n")

        bEditor.insertText("// edited B\n", replacementRange: NSRange(location: 0, length: 0))
        try await wait { b.isDirty }
        manager.openFile(aPath.path)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.mountedEditor(in: host) === aEditor && !b.isDirty
        }
        XCTAssertEqual(try String(contentsOf: aPath, encoding: .utf8),
                       "// edited A\nlet fileA = \"only A\"\n")
        XCTAssertEqual(try String(contentsOf: bPath, encoding: .utf8),
                       "// edited B\nlet fileB = \"only B\"\n")
    }

    func testNativeEditorResignFirstResponderWritesRealFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("focus.txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        try await file.waitForText()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()

        func findEditor(in view: NSView) -> FocusReportingTextView? {
            if let editor = view as? FocusReportingTextView { return editor }
            return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
        }
        let editor = try XCTUnwrap(findEditor(in: host))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("中文😀", replacementRange: NSRange(location: 0, length: 0))
        try await wait { file.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        XCTAssertTrue(window.makeFirstResponder(nil), "Moving focus away must notify the original editor")
        try await wait { !file.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "中文😀original")
    }

    func testFocusTriggeredSaveSerializesConcurrentEditsAndKeepsFailures() async throws {
        let path = "/fixture/\(UUID().uuidString).txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("original".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()

        file.text = "first🙂"
        file.refreshDirtyState()
        let beforeFocusLoss = await backend.writingPath
        XCTAssertNil(beforeFocusLoss, "Typing must not launch a timed or per-keystroke save")
        file.autoSaveOnFocusLoss()
        try await wait { await backend.writingPath == path }

        file.text = "second🪨"
        file.refreshDirtyState()
        file.autoSaveOnFocusLoss()
        await backend.finishWrite()
        try await wait {
            let stored = await backend.data(at: path)
            let writing = await backend.writingPath
            return stored == Data("first🙂".utf8) && writing == path
        }
        XCTAssertTrue(file.isDirty, "The first completed write cannot mark the newer edit saved")
        await backend.finishWrite()
        try await wait { !file.isDirty }
        let final = await backend.data(at: path)
        XCTAssertEqual(final, Data("second🪨".utf8))

        file.text = "offline edit"
        file.refreshDirtyState()
        file.autoSaveOnFocusLoss()
        try await wait { await backend.writingPath == path }
        await backend.finishWrite(failing: true)
        try await wait { file.saveError != nil }
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, "offline edit")
        let retained = await backend.data(at: path)
        XCTAssertEqual(retained, Data("second🪨".utf8))
    }

    func testAnotherLiveChannelTakesOverWithoutTransientReadOnlyState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("remote.txt")
        try Data("local sentinel".utf8).write(to: path)
        let project = Project(fallbackName: "channel handoff", workspaceConfiguration: .standard)
        defer { project.terminateAll() }
        func connect(_ session: TerminalSession) -> RemoteConnection {
            let connection = RemoteConnection(
                user: "fixture", host: "invalid", port: 2222,
                controlSocket: directory.appendingPathComponent(UUID().uuidString), sshPID: 0
            )
            connection.workingDirectory = directory.path
            connection.markConnected()
            XCTAssertTrue(session.beginRemoteConnection(connection))
            return connection
        }
        let first = connect(project.newSession())
        let second = connect(project.newSession())
        try await Task.sleep(for: .milliseconds(50))
        let backend = EditorWorkspaceFixture(path: path.path, contents: Data("baseline\n".utf8))
        let file = FileTab(path: path.path, backend: backend, workspaceIdentity: first.workspaceIdentity)
        try await file.waitForText()
        project.append(PaneTab(content: .file(file)))
        try await wait { if case .text = file.content { return true }; return false }
        file.text = "old channel draft"
        file.refreshDirtyState()
        let save = Task { await file.save() }
        try await wait { await backend.writingPath != nil }
        first.markDisconnected(reason: "first channel ended")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(file.readOnlyReason)
        XCTAssertEqual(second.state, .connected)
        await backend.finishWrite()
        await save.value
        XCTAssertTrue(file.isDirty, "Old-channel write cannot establish the new target's baseline")
        XCTAssertEqual(file.text, "old channel draft")
        guard file.isDirty else { return }
        file.text = "new channel draft"
        file.refreshDirtyState()
        await file.save()
        XCTAssertTrue(file.isDirty)
        XCTAssertTrue(file.saveError != nil || file.readOnlyReason != nil,
                      "The new channel has no socket and must fail, not fall back")
        let oldContents = await backend.data(at: path.path)
        XCTAssertEqual(oldContents, Data("old channel draft".utf8))
        XCTAssertEqual(try Data(contentsOf: path), Data("local sentinel".utf8))
    }

    func testDirtyUndoSaveDuringEditRenameFailureAndStaleReload() async throws {
        let first = "/fixture/\(UUID().uuidString)-original.txt"
        let renamed = first.replacingOccurrences(of: "-original", with: "-renamed")
        let original = "原文😀\r\n"
        let backend = EditorWorkspaceFixture(path: first, contents: Data(original.utf8))
        let file = FileTab(path: first, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()
        XCTAssertEqual(file.text, original)
        let pane = PaneTab(content: .file(file))

        let dirtyObserved = expectation(description: "Pane sees FileTab dirty via Observation")
        withObservationTracking({ _ = pane.content.isDirty }) { dirtyObserved.fulfill() }
        file.text = "改稿🪨\r\n"
        file.refreshDirtyState()
        await fulfillment(of: [dirtyObserved], timeout: 1)
        XCTAssertTrue(pane.content.isDirty)
        file.text = original
        file.refreshDirtyState()
        XCTAssertFalse(pane.content.isDirty, "Undo to baseline clears dirty state")

        file.text = "first draft\r\n"
        file.refreshDirtyState()
        let firstSave = Task { await file.save() }
        try await wait { await backend.writingPath == first }
        file.text = "second draft🪨\r\n"
        file.refreshDirtyState()
        await backend.finishWrite()
        await firstSave.value
        XCTAssertTrue(file.isDirty, "Edits made during save must remain unsaved")
        let firstStored = await backend.data(at: first)
        XCTAssertEqual(try XCTUnwrap(firstStored), Data("first draft\r\n".utf8))

        let secondSave = Task { await file.save() }
        try await wait { await backend.writingPath == first }
        await backend.finishWrite()
        await secondSave.value
        XCTAssertFalse(file.isDirty)
        let secondStored = await backend.data(at: first)
        XCTAssertEqual(try XCTUnwrap(secondStored), Data(file.text.utf8))

        file.text = "third draft"; file.refreshDirtyState()
        let outdatedWrite = Task { await file.save() }
        try await wait { await backend.writingPath == first }
        let pathObserved = expectation(description: "FileTab rename updates its path")
        withObservationTracking({ _ = file.path }) { pathObserved.fulfill() }
        file.updatePath(renamed)
        await fulfillment(of: [pathObserved], timeout: 1)
        await backend.finishWrite()
        await outdatedWrite.value
        XCTAssertEqual(file.path, renamed)
        XCTAssertTrue(file.isDirty, "Old path write must not claim new path was saved")
        let renamedBeforeSave = await backend.data(at: renamed)
        XCTAssertNil(renamedBeforeSave)

        let renamedWrite = Task { await file.save() }
        try await wait { await backend.writingPath == renamed }
        await backend.finishWrite()
        await renamedWrite.value
        XCTAssertFalse(file.isDirty)
        let renamedStored = await backend.data(at: renamed)
        XCTAssertEqual(try XCTUnwrap(renamedStored), Data("third draft".utf8))

        file.text = "fourth draft"; file.refreshDirtyState()
        let rejectedWrite = Task { await file.save() }
        try await wait { await backend.writingPath == renamed }
        await backend.finishWrite(failing: true)
        await rejectedWrite.value
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
        XCTAssertEqual(file.text, "fourth draft")
        let retainedAfterFailure = await backend.data(at: renamed)
        XCTAssertEqual(try XCTUnwrap(retainedAfterFailure), Data("third draft".utf8))

        file.text = "third draft"; file.refreshDirtyState()
        XCTAssertFalse(file.isDirty)
        await backend.pauseOneRead()
        file.reloadFromDiskIfClean()
        try await wait { await backend.readingPath == renamed }
        file.text = "local edit while old read awaits"; file.refreshDirtyState()
        await backend.finishRead(with: Data("stale remote read".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(file.text, "local edit while old read awaits")
        XCTAssertTrue(file.isDirty)
    }

    func testBinaryAndLargeTextAreNotTreatedAsEditable() async throws {
        let invalidPath = "/fixture/\(UUID().uuidString).bin"
        let invalid = FileTab(
            path: invalidPath,
            backend: EditorWorkspaceFixture(path: invalidPath, contents: Data([0xFF, 0x00, 0x80])),
            workspaceIdentity: "ssh:fixture"
        )
        invalid.loadIfNeeded()
        try await wait { if case .loading = invalid.content { return false }; return true }
        guard case .unavailable = invalid.content else { return XCTFail("Expected binary placeholder") }
        XCTAssertFalse(invalid.isDirty)

        let largePath = "/fixture/\(UUID().uuidString).txt"
        let large = FileTab(
            path: largePath,
            backend: EditorWorkspaceFixture(path: largePath, contents: Data(repeating: 0x41, count: 5 * 1024 * 1024 + 1)),
            workspaceIdentity: "ssh:fixture"
        )
        large.loadIfNeeded()
        try await wait { if case .loading = large.content { return false }; return true }
        guard case .unavailable = large.content else { return XCTFail("Expected size placeholder") }
        XCTAssertFalse(large.isDirty)
    }

    func testDisconnectDuringSavePreservesBufferAndBaseline() async throws {
        let path = "/fixture/\(UUID().uuidString).txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("baseline".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()
        file.text = "unsaved"
        file.refreshDirtyState()
        let saving = Task { await file.save() }
        try await wait { await backend.writingPath == path }
        let project = Project(fallbackName: "disconnected", workspaceConfiguration: .standard)
        file.reevaluateWorkspace(in: project)
        await backend.finishWrite()
        await saving.value
        XCTAssertNotNil(file.readOnlyReason)
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(file.text, "unsaved")
        await file.save()
        XCTAssertEqual(file.saveError, file.readOnlyReason)
        file.text = "baseline"
        file.refreshDirtyState()
        XCTAssertFalse(file.isDirty)
    }

    func testCleanReloadPublishesOnlyNewBytesAndDropsRenamedRead() async throws {
        let path = "/fixture/\(UUID().uuidString).txt"
        let backend = EditorWorkspaceFixture(path: path, contents: Data("baseline".utf8))
        let file = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:fixture")
        try await file.waitForText()
        let revision = file.reloadRevision
        await backend.pauseOneRead()
        file.reloadFromDiskIfClean()
        try await wait { await backend.readingPath == path }
        await backend.finishRead(with: Data("新内容😀\r\n".utf8))
        try await wait { file.reloadRevision != revision }
        XCTAssertEqual(file.text, "新内容😀\r\n")
        XCTAssertFalse(file.isDirty)

        await backend.pauseOneRead()
        file.reloadFromDiskIfClean()
        try await wait { await backend.readingPath == path }
        let updatedRevision = file.reloadRevision
        file.updatePath(path + ".renamed")
        await backend.finishRead(with: Data("stale bytes".utf8))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(file.text, "新内容😀\r\n")
        XCTAssertEqual(file.reloadRevision, updatedRevision)
    }
}
