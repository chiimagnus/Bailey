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

        let first = TerminalManager()
        let second = TerminalManager()
        defer { first.windowClosed(); second.windowClosed() }
        first.addLocalItems([aFolder])
        second.addLocalItems([bFolder])
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
