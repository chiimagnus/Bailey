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
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ))
        NSApp.sendEvent(down)
        NSApp.sendEvent(event)
        try await until { window.firstResponder === group }
        XCTAssertTrue(group.containsResponder(window.firstResponder))
    }

    func testDragReleasedOverAnotherDockGroupDoesNotActivateIt() throws {
        let window = NSWindow(
            contentRect: NSRect(x: -900, y: -900, width: 640, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let source = DockGroupFocusView(groupID: UUID())
        let destination = DockGroupFocusView(groupID: UUID())
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            DockFocusP2Mount(view: source).frame(width: 320, height: 320)
            DockFocusP2Mount(view: destination, isActive: false).frame(width: 320, height: 320)
        }.frame(width: 640, height: 320))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(source.window === window)
        XCTAssertTrue(destination.window === window)

        var destinationActivations = 0
        destination.onFocused = { destinationActivations += 1 }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint, number: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: number, clickCount: 1, pressure: 0
            ))
        }
        let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let end = destination.convert(
            NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
        NSApp.sendEvent(try mouse(.leftMouseDown, at: start, number: 1))
        NSApp.sendEvent(try mouse(.leftMouseDragged, at: end, number: 2))
        NSApp.sendEvent(try mouse(.leftMouseUp, at: end, number: 3))
        XCTAssertEqual(destinationActivations, 0,
                       "Releasing a cross-pane drag is not a click in the destination pane")

        NSApp.sendEvent(try mouse(.leftMouseDown, at: end, number: 4))
        NSApp.sendEvent(try mouse(.leftMouseUp, at: end, number: 5))
        XCTAssertEqual(destinationActivations, 1,
                       "A genuine click in the destination must activate it once")
        NSApp.sendEvent(try mouse(.leftMouseUp, at: end, number: 6))
        XCTAssertEqual(destinationActivations, 1,
                       "A stray mouse release cannot activate a Dock group")
        NSApp.sendEvent(try mouse(.rightMouseDown, at: end, number: 7))
        XCTAssertEqual(destinationActivations, 2,
                       "Context-click activation must still work")
    }

    func testPaletteFileManagerCommandTransfersKeyboardFocusToVisibleFileTree() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-palette-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("alpha.swift")
        let second = directory.appendingPathComponent("beta.swift")
        for path in [first, second] {
            try "original\n".write(to: path, atomically: true, encoding: .utf8)
        }

        let manager = WorkspaceApplication().makeWindow()
        defer { manager.windowClosed() }
        manager.addLocalFolders([directory])
        manager.openFile(second.path)
        let project = try XCTUnwrap(manager.selectedProject)
        let tab = try XCTUnwrap(project.selectedTab)
        guard case .file(let file) = tab.content else {
            return XCTFail("Expected a native file tab")
        }

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
        try await until {
            host.layoutSubtreeIfNeeded()
            return manager.attachedWindow === window
                && (file.editorView as? NSScrollView)?.documentView is FocusReportingTextView
        }
        let scroll = try XCTUnwrap(file.editorView as? NSScrollView)
        let editor = try XCTUnwrap(scroll.documentView as? FocusReportingTextView)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(manager.ownsActiveResponder(editor))

        manager.toggleCommandPalette()
        try await until {
            host.layoutSubtreeIfNeeded()
            return manager.isCommandPaletteVisible
                && (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        let search = try XCTUnwrap(window.firstResponder as? NSTextView)
        search.insertText(String(localized: "File Manager", table: "Sidebar"),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        let enter = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        window.sendEvent(enter)
        try await until {
            host.layoutSubtreeIfNeeded()
            return !manager.isCommandPaletteVisible
                && project.dock.activeGroup?.selected == .files
                && project.fileTree.selectedPath == second.path
                && window.firstResponder === manager.activeTreeResponder(in: window)
        }
        XCTAssertFalse(window.firstResponder === editor)
        XCTAssertTrue(window.firstResponder is TreeKeyboardView)

        let up = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
            isARepeat: false, keyCode: 126
        ))
        window.sendEvent(up)
        try await until { project.fileTree.selectedPath == first.path }
        XCTAssertEqual(project.dock.activeGroup?.selected, .files)
        XCTAssertEqual(project.tabs.filter { $0.content.isFile }.count, 1)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "original\n")
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Expected native focus condition was not reached")
    }
}
