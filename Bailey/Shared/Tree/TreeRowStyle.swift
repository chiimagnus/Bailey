import AppKit
import GhosttyTheme
import SwiftUI

/// Per-tree native keyboard focus. Does not intercept mouse input or own row selection.
@MainActor
final class TreeKeyboardOwner {
    weak var view: TreeKeyboardView?

    func focus() {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}

final class TreeKeyboardView: NSView {
    var onKeyDown: (NSEvent) -> Bool = { _ in false }
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onAttachedToWindow: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttachedToWindow() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChanged(false) }
        return resigned
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The system Edit menu handles Cmd+C/X/V before keyDown reaches a tree.
        guard window?.firstResponder === self, event.modifierFlags.contains(.command)
        else { return super.performKeyEquivalent(with: event) }
        return onKeyDown(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !onKeyDown(event) { super.keyDown(with: event) }
    }
}

struct TreeKeyboardHost: NSViewRepresentable {
    let owner: TreeKeyboardOwner
    let onKeyDown: (NSEvent) -> Bool
    let onFocusChanged: (Bool) -> Void
    let onAttachedToWindow: () -> Void

    func makeNSView(context: Context) -> TreeKeyboardView {
        let view = TreeKeyboardView()
        owner.view = view
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TreeKeyboardView, context: Context) {
        owner.view = view
        view.onKeyDown = onKeyDown
        view.onFocusChanged = onFocusChanged
        view.onAttachedToWindow = onAttachedToWindow
    }

    static func dismantleNSView(_ view: TreeKeyboardView, coordinator: ()) {
        view.onKeyDown = { _ in false }
        view.onFocusChanged = { _ in }
        view.onAttachedToWindow = {}
    }
}

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
/// Callers apply the supplied layout to interactive rows so hover and hit areas agree.
struct TreeRowSurface<Content: View>: View {
    private let themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    let depth: Int
    let scale: CGFloat
    var selected = false
    var multiSelected = false
    var focusRing = false
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
        multiSelected: Bool = false,
        focusRing: Bool = false,
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
        self.multiSelected = multiSelected
        self.focusRing = focusRing
        self.hoverEnabled = hoverEnabled
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.outerInset = outerInset
        self.showsGuides = showsGuides
        self.height = height
        self.content = content
    }

    var body: some View {
        let _ = themeChanges.revision
        let theme = Theme.terminal(dark: colorScheme == .dark)
        let accent = Color(nsColor: theme.accentNSColor)
        let foreground = Color(nsColor: theme.foregroundNSColor)
        content(isHovering, TreeRowLayout(
            leadingInset: leadingInset + CGFloat(depth) * TreeRowStyle.indent,
            trailingInset: trailingInset,
            height: height ?? TreeRowStyle.rowHeight(scale)
        ))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 4))
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(multiSelected ? accent.opacity(0.14)
                           : selected ? foreground.opacity(0.09)
                           : (isHovering ? foreground.opacity(0.05) : .clear))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(focusRing ? accent.opacity(0.65) : .clear,
                                  lineWidth: 1)
                    .allowsHitTesting(false)
            }
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
    @Environment(\.colorScheme) private var colorScheme
    let expanded: Bool
    let scale: CGFloat

    var body: some View {
        let _ = themeChanges.revision
        Image(systemName: TreeRowStyle.folderSymbol(expanded: expanded))
            .font(.system(size: 11 * scale))
            .foregroundStyle(Color(nsColor: Theme.terminal(dark: colorScheme == .dark).accentNSColor).opacity(0.8))
            .frame(width: TreeRowStyle.iconSize, height: TreeRowStyle.iconSize)
            .accessibilityHidden(true)
    }
}

/// Draw across the entire SwiftUI row, including scaled typography and inline editing.
/// A zero-spacing LazyVStack makes the full-height rectangles touch exactly.
struct TreeGuideBackground: View {
    private let themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    let depth: Int
    var leadingInset = TreeRowStyle.leadingInset

    var body: some View {
        let _ = themeChanges.revision
        let guideColor = Color(nsColor: Theme.terminal(dark: colorScheme == .dark).foregroundNSColor)
        Canvas { context, size in
            guard depth > 0 else { return }
            for level in 0..<depth {
                let x = leadingInset + TreeRowStyle.iconSize / 2
                    + CGFloat(level) * TreeRowStyle.indent
                let line = Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height))
                context.fill(line, with: .color(guideColor.opacity(0.18)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension TreeDisplayModel.Status {
    func color(theme: GhosttyThemeDefinition) -> Color {
        let foreground = Color(nsColor: theme.foregroundNSColor)
        return switch self {
        case .modified: Color(nsColor: theme.paletteNSColor(3) ?? theme.accentNSColor)
        case .added, .untracked: Color(nsColor: theme.paletteNSColor(2) ?? theme.accentNSColor)
        case .deleted: Color(nsColor: theme.paletteNSColor(1) ?? theme.accentNSColor)
        case .renamed, .copied: Color(nsColor: theme.paletteNSColor(4) ?? theme.accentNSColor)
        case .conflict: Color(nsColor: theme.paletteNSColor(5) ?? theme.accentNSColor)
        case .ignored: foreground.opacity(0.35)
        case .changed: foreground.opacity(0.65)
        }
    }
}

private struct TreeRowLabel: View {
    private let themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    let row: TreeDisplayModel.Row
    let iconPath: String
    let scale: CGFloat
    var directory: String? = nil
    var compactSegment: ((TreeDisplayModel.Row.CompactComponent) -> AnyView)? = nil

    var body: some View {
        let _ = themeChanges.revision
        let theme = Theme.terminal(dark: colorScheme == .dark)
        let text = Color(nsColor: theme.foregroundNSColor)
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
                    Group {
                        if let compactSegment, !row.compactPrefix.isEmpty {
                            HStack(spacing: 0) {
                                ForEach(Array(row.compactComponents.enumerated()), id: \.element.path) { entry in
                                    if entry.offset > 0 { Text(" / ") }
                                    compactSegment(entry.element)
                                }
                            }
                        } else {
                            Text(row.displayName)
                        }
                    }
                    .font(.system(size: TreeRowStyle.fontSize * scale))
                    .foregroundStyle(row.status?.color(theme: theme)
                        ?? text.opacity(row.name.hasPrefix(".") ? 0.35 : 0.65))
                    .strikethrough(!row.isDirectory && row.status == .deleted)
                    .fixedSize(horizontal: true, vertical: false)
                    if let directory, !directory.isEmpty {
                        Text(directory)
                            .font(.system(size: 10 * scale))
                            .foregroundStyle(text.opacity(0.45))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct TreeFolderRow<Accessory: View>: View {
    let row: TreeDisplayModel.Row
    let scale: CGFloat
    var leadingInset = TreeRowStyle.contentInset
    var focusRing = false
    var multiSelected = false
    var multiSelectionEnabled = false
    var compactSegment: ((TreeDisplayModel.Row.CompactComponent) -> AnyView)? = nil
    let toggle: () -> Void
    @ViewBuilder var accessory: (Bool) -> Accessory

    var body: some View {
        TreeRowSurface(depth: row.depth, scale: scale,
                       multiSelected: multiSelected, focusRing: focusRing,
                       leadingInset: leadingInset) { hovering, layout in
            HStack(spacing: 0) {
                TreeRowLabel(row: row, iconPath: row.path, scale: scale,
                             compactSegment: compactSegment)
                    .modifier(layout)
                    .onTapGesture(perform: toggle)
                    .accessibilityAction(.default) { toggle() }
                    .help(row.accessibilityLabel + "\n" + row.path)
                .accessibilityLabel(row.accessibilityLabel)
                .accessibilityIdentifier("bailey.tree.folder")
                .accessibilityAddTraits((multiSelectionEnabled ? multiSelected : focusRing) ? .isSelected : [])
                .accessibilityValue(row.isExpanded
                    ? String(localized: "Expanded", table: "Sidebar")
                    : String(localized: "Collapsed", table: "Sidebar"))
                accessory(hovering || focusRing)
            }
        }
    }
}

extension TreeFolderRow where Accessory == EmptyView {
    init(row: TreeDisplayModel.Row, scale: CGFloat,
         leadingInset: CGFloat = TreeRowStyle.contentInset,
         focusRing: Bool = false, multiSelected: Bool = false,
         multiSelectionEnabled: Bool = false,
         compactSegment: ((TreeDisplayModel.Row.CompactComponent) -> AnyView)? = nil,
         toggle: @escaping () -> Void) {
        self.init(row: row, scale: scale, leadingInset: leadingInset,
                  focusRing: focusRing, multiSelected: multiSelected,
                  multiSelectionEnabled: multiSelectionEnabled,
                  compactSegment: compactSegment,
                  toggle: toggle) { _ in EmptyView() }
    }
}

struct TreeFileRow<Accessory: View>: View {
    let row: TreeDisplayModel.Row
    let scale: CGFloat
    var iconPath: String? = nil
    var directory: String? = nil
    var selected = false
    var multiSelected = false
    var multiSelectionEnabled = false
    var focusRing = false
    var leadingInset = TreeRowStyle.contentInset
    var accessibilityHint = ""
    var accessibilityID = "bailey.tree.file"
    let open: () -> Void
    var activate: (() -> Void)? = nil
    @ViewBuilder var accessory: (Bool) -> Accessory

    var body: some View {
        TreeRowSurface(depth: row.depth, scale: scale, selected: selected,
                       multiSelected: multiSelected, focusRing: focusRing, leadingInset: leadingInset) { hovering, layout in
            HStack(spacing: 0) {
                TreeRowLabel(row: row, iconPath: iconPath ?? row.path, scale: scale,
                             directory: directory)
                    .modifier(layout)
                    .onTapGesture(perform: open)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { activate?() })
                    .accessibilityAction(.default) { open() }
                    .help(row.accessibilityLabel + "\n" + row.path)
                .accessibilityLabel(row.accessibilityLabel + ", " + row.path)
                .accessibilityIdentifier(accessibilityID)
                .accessibilityAddTraits((multiSelectionEnabled ? multiSelected : focusRing) ? .isSelected : [])
                .accessibilityHint(accessibilityHint)
                accessory(hovering || focusRing)
            }
        }
    }
}
