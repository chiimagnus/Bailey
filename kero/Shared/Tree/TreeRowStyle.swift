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

struct TreeRowLayout: ViewModifier {
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// The one row surface shared by Files, working-tree Git and committed Git.
/// Callers apply the supplied layout inside button labels so hover and hit areas agree.
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
    private let content: (Bool, TreeRowLayout) -> Content

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
        @ViewBuilder content: @escaping (Bool, TreeRowLayout) -> Content
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
        content(isHovering, TreeRowLayout(
            leadingInset: leadingInset + CGFloat(depth) * TreeRowStyle.indent,
            trailingInset: trailingInset,
            height: height ?? TreeRowStyle.rowHeight(scale)
        ))
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
                if showsGuides {
                    TreeGuideBackground(depth: depth, leadingInset: outerInset + leadingInset)
                }
            }
    }
}

/// Identical SwiftUI folder glyph in Files and both Git trees.
struct TreeFolderIcon: View {
    private let themeChanges = Theme.changes
    let expanded: Bool
    let scale: CGFloat

    var body: some View {
        let _ = themeChanges.revision
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
    var leadingInset = TreeRowStyle.leadingInset

    var body: some View {
        Canvas { context, size in
            guard depth > 0 else { return }
            for level in 0..<depth {
                let x = leadingInset + TreeRowStyle.iconSize / 2
                    + CGFloat(level) * TreeRowStyle.indent
                let line = Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height))
                context.fill(line, with: .color(.primary.opacity(0.18)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension TreeDisplayModel.Status {
    var color: Color {
        switch self {
        case .modified: Color(red: 0.82, green: 0.60, blue: 0.13)
        case .added, .untracked: Color(red: 0.25, green: 0.73, blue: 0.31)
        case .deleted: Color(red: 1.0, green: 0.48, blue: 0.45)
        case .renamed, .copied: Color(red: 0.35, green: 0.65, blue: 1.0)
        case .conflict: Color(red: 0.74, green: 0.55, blue: 1.0)
        case .ignored: Color.secondary.opacity(0.55)
        case .changed: .secondary
        }
    }
}

private struct TreeRowLabel: View {
    let row: TreeDisplayModel.Row
    let iconPath: String
    let scale: CGFloat
    var directory: String? = nil

    var body: some View {
        HStack(spacing: TreeRowStyle.iconSpacing) {
            if row.isDirectory {
                TreeFolderIcon(expanded: row.isExpanded, scale: scale)
            } else {
                MaterialFileIconView(path: iconPath, size: TreeRowStyle.iconSize,
                                     opacity: row.status == .deleted ? 0.6 : 1)
                    .frame(width: TreeRowStyle.iconSize)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.system(size: TreeRowStyle.fontSize * scale))
                        .foregroundStyle(row.status?.color
                            ?? (row.name.hasPrefix(".") ? Color.secondary.opacity(0.55) : .secondary))
                        .strikethrough(!row.isDirectory && row.status == .deleted)
                        .fixedSize(horizontal: true, vertical: false)
                    if let directory, !directory.isEmpty {
                        Text(directory)
                            .font(.system(size: 10 * scale))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct TreeFolderRow: View {
    let row: TreeDisplayModel.Row
    let scale: CGFloat
    var leadingInset = TreeRowStyle.contentInset
    let toggle: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TreeRowSurface(depth: row.depth, scale: scale, focused: focused, leadingInset: leadingInset) { _, layout in
            Button(action: toggle) {
                TreeRowLabel(row: row, iconPath: row.path, scale: scale)
                    .modifier(layout)
            }
            .buttonStyle(.plain)
            .focused($focused)
            .help(row.accessibilityLabel + "\n" + row.path)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityValue(row.isExpanded
                ? String(localized: "Expanded", table: "Sidebar")
                : String(localized: "Collapsed", table: "Sidebar"))
        }
    }
}

struct TreeFileRow<Accessory: View>: View {
    let row: TreeDisplayModel.Row
    let scale: CGFloat
    var iconPath: String? = nil
    var directory: String? = nil
    var selected = false
    var leadingInset = TreeRowStyle.contentInset
    var accessibilityHint = ""
    let open: () -> Void
    @ViewBuilder var accessory: (Bool) -> Accessory
    @FocusState private var focused: Bool

    var body: some View {
        TreeRowSurface(depth: row.depth, scale: scale, selected: selected,
                       focused: focused, leadingInset: leadingInset) { hovering, layout in
            HStack(spacing: 0) {
                Button(action: open) {
                    TreeRowLabel(row: row, iconPath: iconPath ?? row.path, scale: scale,
                                 directory: directory)
                        .modifier(layout)
                }
                .buttonStyle(.plain)
                .focused($focused)
                .help(row.accessibilityLabel + "\n" + row.path)
                .accessibilityLabel(row.accessibilityLabel + ", " + row.path)
                .accessibilityHint(accessibilityHint)
                accessory(hovering || focused)
            }
        }
    }
}
