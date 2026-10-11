import AppKit
import SwiftUI

/// One file-tree layout for Files, working-tree changes and commit history.
enum TreeRowStyle {
    static let indent: CGFloat = 18
    static let outerInset: CGFloat = 6
    static let contentInset: CGFloat = 6
    static let leadingInset: CGFloat = outerInset + contentInset
    static let iconSize: CGFloat = 14
    static let iconSpacing: CGFloat = 6
    static let fontSize: CGFloat = 11.5

    static func rowHeight(_ scale: CGFloat) -> CGFloat {
        max(22, ceil(22 * scale))
    }

    static func folderSymbol(expanded: Bool) -> String {
        expanded ? "folder" : "folder.fill"
    }

}

/// The one row surface shared by Files, working-tree Git and committed Git.
/// Callers provide only their semantic content; hover/selection geometry lives here.
struct TreeRowSurface<Content: View>: View {
    let depth: Int
    let scale: CGFloat
    var selected = false
    var focused = false
    var hoverEnabled = true
    var leadingInset = TreeRowStyle.contentInset
    var trailingInset = TreeRowStyle.contentInset
    var outerInset = TreeRowStyle.outerInset
    var showsGuides = true
    var height: CGFloat? = nil
    private let content: (Bool) -> Content

    @State private var isHovering = false

    init(
        depth: Int,
        scale: CGFloat,
        selected: Bool = false,
        focused: Bool = false,
        hoverEnabled: Bool = true,
        leadingInset: CGFloat = TreeRowStyle.contentInset,
        trailingInset: CGFloat = TreeRowStyle.contentInset,
        outerInset: CGFloat = TreeRowStyle.outerInset,
        showsGuides: Bool = true,
        height: CGFloat? = nil,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.depth = depth
        self.scale = scale
        self.selected = selected
        self.focused = focused
        self.hoverEnabled = hoverEnabled
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.outerInset = outerInset
        self.showsGuides = showsGuides
        self.height = height
        self.content = content
    }

    var body: some View {
        content(isHovering)
            .padding(.leading, leadingInset + CGFloat(depth) * TreeRowStyle.indent)
            .padding(.trailing, trailingInset)
            .frame(height: height ?? TreeRowStyle.rowHeight(scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 4))
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selected
                        ? Color.primary.opacity(0.09)
                        : (isHovering || focused ? Color.primary.opacity(0.05) : .clear))
            )
            .onHover { if hoverEnabled { isHovering = $0 } }
            .padding(.horizontal, outerInset)
            .background {
                if showsGuides { TreeGuideBackground(depth: depth) }
            }
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
