import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Bailey

@MainActor
final class DockFocusIntegrationTests: XCTestCase {
    func testOnlyActiveMountedEditorOwnsNativeResponder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("owner.swift")
        try "let value = 1\n".write(to: path, atomically: true, encoding: .utf8)

        let manager = WorkspaceApplication().makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        manager.openFile(path.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let tab = try XCTUnwrap(project.selectedTab)
        guard case .file(let file) = tab.content else {
            return XCTFail("Expected a file tab")
        }

        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 680, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        window.contentView = host
        manager.attach(to: window)
        window.orderFront(nil)
        try await waitForCondition("The native editor must mount in its owning window") {
            host.layoutSubtreeIfNeeded()
            return file.editorView?.window === window
        }
        let scroll = try XCTUnwrap(file.editorView)
        let editor = try XCTUnwrap((scroll as? NSScrollView)?.documentView)
        XCTAssertTrue(manager.ownsActiveResponder(editor))
        project.dock.select(.files)
        XCTAssertFalse(manager.ownsActiveResponder(editor),
                       "A hidden tab must not keep ownership of native keyboard input")
        project.selectTab(tab.id)
        XCTAssertTrue(manager.ownsActiveResponder(editor))
        manager.selectedProjectID = nil
        XCTAssertFalse(manager.ownsActiveResponder(editor),
                       "An inactive project must not own the keyboard")
        manager.selectedProjectID = project.id
        XCTAssertTrue(manager.ownsActiveResponder(editor))
        scroll.isHidden = true
        XCTAssertFalse(manager.ownsActiveResponder(editor))
        scroll.isHidden = false
        host.removeFromSuperview()
        XCTAssertFalse(manager.ownsActiveResponder(editor),
                       "A detached editor must not receive keyboard input")
    }

    private func waitForCondition(
        _ description: String,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(description)
    }

    func testNativeFieldEditorWinsUntilDockFocusIsRequestedForEmptySpace() async throws {
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
                      "A focus request before native dispatch must not steal the editor responder")
        input.selectText(nil)
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor)
        try await waitForCondition("The native field editor should remain first responder") {
            window.firstResponder === fieldEditor
        }
        XCTAssertTrue(window.firstResponder === fieldEditor,
                      "The focused control must win over the background Dock focus reader")

        XCTAssertTrue(window.makeFirstResponder(oldEditor))
        group.requestFocusAfterClick()
        try await waitForCondition("An empty-pane focus request should release the previous editor") {
            window.firstResponder === group
        }
        XCTAssertTrue(window.firstResponder === group)
    }

    func testTerminalFindFieldEditorBelongsOnlyToItsDockGroup() async throws {
        let terminal = TerminalSession(launchCommand: "exec /bin/sh -i")
        defer { terminal.terminate() }
        let bounds = NSRect(x: 0, y: 0, width: 1800, height: 700)
        let window = NSWindow(contentRect: bounds, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: bounds)
        let targetID = UUID()
        let target = DockGroupFocusView(groupID: targetID)
        target.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        target.isActive = true
        target.focusesEmptySpace = false
        target.canFocus = { false }
        let other = DockGroupFocusView(groupID: UUID())
        other.frame = NSRect(x: 900, y: 0, width: 900, height: 700)
        other.isActive = false
        other.focusesEmptySpace = false
        other.canFocus = { false }
        let host = NSHostingView(rootView: TerminalFindBar(find: terminal.find))
        host.frame = NSRect(x: 0, y: 620, width: 900, height: 80)
        target.addSubview(host)
        root.addSubview(target)
        root.addSubview(other)
        window.contentView = root
        window.orderFront(nil)
        terminal.find.present()

        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable,
               !field.isHiddenOrHasHiddenAncestor { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        try await waitForCondition("The terminal find field should be mounted") {
            host.layoutSubtreeIfNeeded()
            return field(in: host) != nil
        }
        let input = try XCTUnwrap(field(in: host))
        input.selectText(nil)
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor)
        fieldEditor.insertText("owner check 中文", replacementRange: NSRange(location: 0, length: 0))
        try await waitForCondition("The terminal find query should receive the field editor input") {
            terminal.find.query == "owner check 中文"
        }
        XCTAssertTrue(target.containsResponder(fieldEditor))
        XCTAssertFalse(other.containsResponder(fieldEditor))
    }
}
