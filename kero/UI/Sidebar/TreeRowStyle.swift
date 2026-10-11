import AppKit
import SwiftUI

/// One file-tree layout for Files, working-tree changes and commit history.
@MainActor
enum TreeRowStyle {
    static let indent: CGFloat = 18
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

    static func minimumWidth(name: String, depth: Int, scale: CGFloat, trailing: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize * scale)
        let nameWidth = (name as NSString).size(withAttributes: [.font: font]).width
        return ceil(leadingInset + CGFloat(depth) * indent + iconSize + iconSpacing
                    + nameWidth + trailing)
    }
}

/// Identical SwiftUI folder glyph in Files and both Git trees.
struct TreeFolderIcon: View {
    let expanded: Bool
    let scale: CGFloat

    var body: some View {
        Image(systemName: TreeRowStyle.folderSymbol(expanded: expanded))
            .font(.system(size: 11 * scale))
            .foregroundStyle(Color(nsColor: Theme.accent).opacity(0.8))
            .frame(width: TreeRowStyle.iconSize, height: TreeRowStyle.iconSize)
            .accessibilityHidden(true)
    }
}

/// Draw across the entire SwiftUI row, including scaled typography and inline editing.
/// A zero-spacing LazyVStack makes the full-height rectangles touch exactly.
struct TreeGuideBackground: View {
    let depth: Int

    var body: some View {
        Canvas { context, size in
            guard depth > 0 else { return }
            for level in 0..<depth {
                let x = TreeRowStyle.leadingInset + TreeRowStyle.iconSize / 2
                    + CGFloat(level) * TreeRowStyle.indent
                let line = Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height))
                context.fill(line, with: .color(.primary.opacity(0.18)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
