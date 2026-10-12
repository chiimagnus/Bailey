import AppKit
import SwiftUI
import XCTest
@testable import kero

@MainActor
final class TreeRowHitTestingTests: XCTestCase {
    private final class Actions {
        var primary = 0
        var accessory = 0
    }

    private func settle() {
        let deadline = Date().addingTimeInterval(0.08)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func click(_ point: NSPoint, in window: NSWindow) {
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: eventType,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
            window.sendEvent(event)
        }
        settle()
    }

    private func assertSurface<Content: View>(
        height: CGFloat,
        actions: Actions,
        accessory: Bool = false,
        content: Content,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let width: CGFloat = 240
        let window = NSWindow(
            contentRect: NSRect(x: -1000, y: -1000, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.frame(width: width, height: height))
        window.orderFront(nil)
        settle()
        defer { window.close() }

        for point in [
            NSPoint(x: 110, y: height / 2),
            NSPoint(x: 8, y: height / 2),
            NSPoint(x: 70, y: 1),
            NSPoint(x: 70, y: height - 1),
            NSPoint(x: accessory ? 170 : width - 8, y: height / 2),
        ] {
            let previous = actions.primary
            click(point, in: window)
            XCTAssertEqual(actions.primary, previous + 1, file: file, line: line)
            XCTAssertEqual(actions.accessory, 0, file: file, line: line)
        }

        if accessory {
            let primary = actions.primary
            for y in [CGFloat(1), height / 2, height - 1] {
                let previous = actions.accessory
                click(NSPoint(x: width - 14, y: y), in: window)
                XCTAssertEqual(actions.accessory, previous + 1, file: file, line: line)
                XCTAssertEqual(actions.primary, primary, file: file, line: line)
            }
        }
    }

    func testFilesAndGitRowsOwnTheirFullHitArea() {
        for scale in [CGFloat(1), CGFloat(1.6)] {
            for depth in [0, 2] {
                let height = TreeRowStyle.rowHeight(scale)
                let folderActions = Actions()
                let folder = TreeDisplayModel.Row(
                    name: "parent / child", path: "parent/child", isDirectory: true, depth: depth
                )
                assertSurface(
                    height: height,
                    actions: folderActions,
                    content: TreeFolderRow(row: folder, scale: scale) { folderActions.primary += 1 }
                )

                let file = TreeDisplayModel.Row(
                    name: "file.swift", path: "parent/child/file.swift", isDirectory: false, depth: depth
                )
                let fileActions = Actions()
                assertSurface(
                    height: height,
                    actions: fileActions,
                    content: TreeFileRow(row: file, scale: scale, open: { fileActions.primary += 1 }) { _ in EmptyView() }
                )

                let gitActions = Actions()
                assertSurface(
                    height: height,
                    actions: gitActions,
                    accessory: true,
                    content: TreeFileRow(row: file, scale: scale, open: { gitActions.primary += 1 }) { _ in
                        Button { gitActions.accessory += 1 } label: {
                            Image(systemName: "plus")
                                .frame(width: 16, height: height)
                                .padding(.horizontal, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                )
            }
        }
    }
}
