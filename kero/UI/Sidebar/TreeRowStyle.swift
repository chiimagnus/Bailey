import AppKit
import SwiftUI

/// One file-tree layout for Files, working-tree changes and commit history.
@MainActor
enum TreeRowStyle {
    static let indent: CGFloat = 12
    static let leadingInset: CGFloat = 12
    static let iconSize: CGFloat = 14
    static let iconSpacing: CGFloat = 6
    static let fontSize: CGFloat = 11.5

    static func rowHeight(_ scale: CGFloat) -> CGFloat {
        max(22, ceil(22 * scale))
    }

    static func folderSymbol(expanded: Bool) -> String {
        expanded ? "folder" : "folder.fill"
    }

    static func drawGuides(depth: Int, in bounds: NSRect, firstX: CGFloat) {
        guard depth > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        for level in 0..<depth {
            let x = firstX + CGFloat(level) * indent
            NSRect(x: x - 0.5, y: bounds.minY, width: 1, height: bounds.height).fill()
        }
    }
}

@MainActor
private final class TreeGuideNSView: NSView {
    var depth = 0 { didSet { if depth != oldValue { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        TreeRowStyle.drawGuides(
            depth: depth, in: bounds,
            firstX: TreeRowStyle.leadingInset + TreeRowStyle.iconSize / 2
        )
    }
}

/// AppKit artwork behind the existing interactive SwiftUI file rows.
struct TreeGuideBackground: NSViewRepresentable {
    let depth: Int

    func makeNSView(context: Context) -> NSView {
        TreeGuideNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TreeGuideNSView)?.depth = depth
    }
}
