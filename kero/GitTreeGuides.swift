import AppKit
import SwiftUI

/// Thin hierarchy guides shared by the Git working tree and commit history.
@MainActor
enum GitTreeGuides {
    static func draw(depth: Int, in bounds: NSRect, firstX: CGFloat) {
        guard depth > 0 else { return }
        let lines = NSBezierPath()
        lines.lineWidth = 1
        for level in 0..<depth {
            let x = firstX + CGFloat(level) * 12
            lines.move(to: NSPoint(x: x, y: bounds.minY))
            lines.line(to: NSPoint(x: x, y: bounds.maxY))
        }
        let x = firstX + CGFloat(depth - 1) * 12
        lines.move(to: NSPoint(x: x, y: bounds.midY))
        lines.line(to: NSPoint(x: x + 6, y: bounds.midY))
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        lines.stroke()
    }
}

@MainActor
private final class GitTreeGuideNSView: NSView {
    var depth = 0 { didSet { if depth != oldValue { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        GitTreeGuides.draw(depth: depth, in: bounds, firstX: 8)
    }
}

/// AppKit artwork behind the existing interactive SwiftUI file rows.
struct GitTreeGuideBackground: NSViewRepresentable {
    let depth: Int

    func makeNSView(context: Context) -> NSView {
        GitTreeGuideNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? GitTreeGuideNSView)?.depth = depth
    }
}
