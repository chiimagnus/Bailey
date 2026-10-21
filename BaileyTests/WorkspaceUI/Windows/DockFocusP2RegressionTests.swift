import AppKit
import SwiftUI
import XCTest
@testable import Bailey

private struct DockFocusP2Mount: NSViewRepresentable {
    let view: DockGroupFocusView
    var isActive = true

    func makeNSView(context: Context) -> DockGroupFocusView { view }

    func updateNSView(_ nsView: DockGroupFocusView, context: Context) {
        nsView.isActive = isActive
        nsView.focusesEmptySpace = true
        nsView.canFocus = { true }
    }
}

@MainActor
final class DockFocusP2RegressionTests: XCTestCase {
    func testClickingEmptyToolPaneReleasesHostingRootResponder() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: -900, y: -900, width: 650, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let inactive = DockGroupFocusView(groupID: UUID())
        let group = DockGroupFocusView(groupID: UUID())
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            DockFocusP2Mount(view: inactive, isActive: false).frame(width: 200, height: 360)
            DockFocusP2Mount(view: group).frame(width: 450, height: 360)
        }.frame(width: 650, height: 360))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(group.window === window)
        XCTAssertTrue(inactive.window === window)
        XCTAssertGreaterThan(group.bounds.width, 0)

        XCTAssertTrue(window.makeFirstResponder(host))
        XCTAssertTrue(window.firstResponder === host)
        for reader in [inactive, group] {
            XCTAssertFalse(reader.containsResponder(host),
                           "A root host spanning multiple groups belongs to none of them")
        }
        group.requestFocusAfterClick()
        try await until { window.firstResponder === group }
        XCTAssertTrue(window.firstResponder === group,
                      "An empty pane must release the root hosting responder")
        XCTAssertTrue(group.containsResponder(group))
        XCTAssertFalse(inactive.containsResponder(group),
                       "A native responder in the active group cannot belong to another group")

        // Exercise the installed local AppKit monitor, not only its focus helper.
        XCTAssertTrue(window.makeFirstResponder(host))
        let point = group.convert(NSPoint(x: group.bounds.midX, y: group.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0
        ))
        NSApp.sendEvent(event)
        try await until { window.firstResponder === group }
        XCTAssertTrue(group.containsResponder(window.firstResponder))
    }

    func testPaletteNoTargetChangeLeavesNativeEditorReadyForTyping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("palette-focus.swift")
        try "let previous = true\n".write(to: url, atomically: true, encoding: .utf8)
        let manager = TerminalManager()
        defer { manager.windowClosed() }
        manager.addLocalFolders([root])
        manager.openFile(url.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let tab = try XCTUnwrap(project.selectedTab)
        guard case .file(let file) = tab.content else { return XCTFail("FileTab expected") }
        let window = NSWindow(
            contentRect: NSRect(x: -900, y: -900, width: 1100, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(manager: manager))
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        guard window.isKeyWindow, NSApp.isActive else {
            throw XCTSkip("A native key window is required for palette keyboard focus")
        }
        try await until {
            host.layoutSubtreeIfNeeded()
            return manager.attachedWindow === window && file.editorView?.window === window
        }
        let editor = try XCTUnwrap(file.editorView)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(manager.ownsActiveResponder(editor))
        manager.toggleCommandPalette()
        try await until {
            host.layoutSubtreeIfNeeded()
            return (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        // The Palette's current FPS action does not change the active Dock pane.
        manager.dismissCommandPalette(restoringFocus: false)
        manager.toggleFPSCounter()
        try await until {
            host.layoutSubtreeIfNeeded()
            return !manager.isCommandPaletteVisible && window.firstResponder === editor
        }
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(manager.ownsActiveResponder(editor))
        XCTAssertTrue(manager.isFPSCounterVisible)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Expected native focus condition was not reached")
    }
}
