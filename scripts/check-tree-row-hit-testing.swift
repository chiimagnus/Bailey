import AppKit
import SwiftUI

struct MaterialFileIconView: View {
    let path: String
    let size: CGFloat
    var opacity: Double = 1

    var body: some View { Image(systemName: "doc").frame(width: size, height: size) }
}

enum Theme {
    static var accent: NSColor { .systemBlue }
}

@main
enum TreeRowHitTestingCheck {
    @MainActor
    final class Actions {
        var primary = 0
        var accessory = 0
    }

    @MainActor
    static func settle() {
        let deadline = Date().addingTimeInterval(0.1)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor
    static func click(_ point: NSPoint, in window: NSWindow) {
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: eventType, location: point,
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        settle()
    }

    @MainActor
    static func check<Content: View>(_ title: String, height: CGFloat,
                                    actions: Actions, content: Content,
                                    accessory: Bool = false) -> Bool {
        let width: CGFloat = 240
        let window = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.frame(width: width, height: height))
        window.orderFront(nil)
        settle()
        defer { window.close() }
        var passed = true
        let points: [NSPoint] = [
            NSPoint(x: 110, y: height / 2),
            NSPoint(x: 8, y: height / 2),
            NSPoint(x: 70, y: 1),
            NSPoint(x: 70, y: height - 1),
            NSPoint(x: accessory ? 170 : width - 8, y: height / 2)
        ]
        for point in points {
            let previous = actions.primary
            click(point, in: window)
            if actions.primary != previous + 1 || actions.accessory != 0 {
                print("FAIL: \(title) primary at \(point), count \(actions.primary - previous)")
                passed = false
            }
        }
        if accessory {
            let previous = actions.primary
            for vertical in [CGFloat(1), height / 2, height - 1] {
                let previousAccessory = actions.accessory
                click(NSPoint(x: width - 14, y: vertical), in: window)
                if actions.accessory != previousAccessory + 1 || actions.primary != previous {
                    print("FAIL: \(title) accessory at y=\(vertical)")
                    passed = false
                }
            }
        }
        return passed
    }

    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var passed = true
        for scale in [CGFloat(1), CGFloat(1.6)] {
            for depth in [0, 2] {
                let height = TreeRowStyle.rowHeight(scale)
                let folderActions = Actions()
                let folder = TreeDisplayModel.Row(name: "parent / child", path: "parent/child",
                                                  isDirectory: true, depth: depth)
                passed = check("folder scale=\(scale) depth=\(depth)", height: height,
                               actions: folderActions,
                               content: TreeFolderRow(row: folder, scale: scale,
                                                      toggle: { folderActions.primary += 1 })) && passed
                let file = TreeDisplayModel.Row(name: "file.swift", path: "parent/child/file.swift",
                                                isDirectory: false, depth: depth)
                let fileActions = Actions()
                passed = check("file scale=\(scale) depth=\(depth)", height: height,
                               actions: fileActions,
                               content: TreeFileRow(row: file, scale: scale,
                                                    open: { fileActions.primary += 1 }) { _ in EmptyView() }) && passed
                let gitActions = Actions()
                passed = check("Git scale=\(scale) depth=\(depth)", height: height,
                               actions: gitActions,
                               content: TreeFileRow(row: file, scale: scale,
                                                    open: { gitActions.primary += 1 }) { _ in
                                   Button { gitActions.accessory += 1 } label: {
                                       Image(systemName: "plus").frame(width: 16, height: height)
                                           .padding(.horizontal, 3).contentShape(Rectangle())
                                   }.buttonStyle(.plain)
                               }, accessory: true) && passed
                let committedActions = Actions()
                passed = check("committed file scale=\(scale) depth=\(depth)", height: height,
                               actions: committedActions,
                               content: TreeFileRow(row: file, scale: scale, leadingInset: 39,
                                                    open: { committedActions.primary += 1 }) { _ in EmptyView() }) && passed
            }
            let commitActions = Actions()
            let commitHeight = max(22, ceil(26 * scale))
            passed = check("commit header scale=\(scale)", height: commitHeight,
                           actions: commitActions,
                           content: TreeRowSurface(depth: 0, scale: scale, leadingInset: 21,
                                                   showsGuides: false, height: commitHeight) { _, layout in
                               Button { commitActions.primary += 1 } label: {
                                   Text("Commit subject").modifier(layout)
                               }.buttonStyle(.plain)
                           }) && passed
        }
        if !passed { exit(1) }
        print("PASS: native Files/Git/committed row clicks cover indentation, top/bottom and trailing edges; accessory clicks stay isolated at both font scales")
    }
}
