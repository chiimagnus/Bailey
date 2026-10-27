import AppKit
import GhosttyTheme
import SwiftUI

enum TreeEditAction {
    case cut, copy, paste, delete, selectAll
}

/// Per-tree native keyboard focus. Does not intercept mouse input or own row selection.
@MainActor
final class TreeKeyboardOwner {
    weak var view: TreeKeyboardView?

    func focus() {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}

final class TreeKeyboardView: NSView, NSMenuItemValidation {
    var onKeyDown: (NSEvent) -> Bool = { _ in false }
    var onEditCommand: ((TreeEditAction) -> Void)?
    var canEditCommand: ((TreeEditAction) -> Bool)?
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

    @IBAction func cut(_ sender: Any?) { performEdit(.cut) }
    @IBAction func copy(_ sender: Any?) { performEdit(.copy) }
    @IBAction func paste(_ sender: Any?) { performEdit(.paste) }
    @IBAction func delete(_ sender: Any?) { performEdit(.delete) }
    @IBAction override func selectAll(_ sender: Any?) { performEdit(.selectAll) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action: TreeEditAction?
        switch menuItem.action {
        case #selector(cut(_:)): action = .cut
        case #selector(copy(_:)): action = .copy
        case #selector(paste(_:)): action = .paste
        case #selector(delete(_:)): action = .delete
        case #selector(selectAll(_:)): action = .selectAll
        default: return true
        }
        guard let action else { return false }
        return window?.firstResponder === self && canEditCommand?(action) == true
    }

    private func performEdit(_ action: TreeEditAction) {
        guard window?.firstResponder === self, canEditCommand?(action) == true else { return }
        onEditCommand?(action)
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
    var onEditCommand: ((TreeEditAction) -> Void)? = nil
    var canEditCommand: ((TreeEditAction) -> Bool)? = nil

    func makeNSView(context: Context) -> TreeKeyboardView {
        let view = TreeKeyboardView()
        owner.view = view
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TreeKeyboardView, context: Context) {
        // 旧宿主可能晚于新宿主收到更新；只有 makeNSView 可以登记键盘所有权。
        view.onKeyDown = onKeyDown
        view.onEditCommand = onEditCommand
        view.canEditCommand = canEditCommand
        view.onFocusChanged = onFocusChanged
        view.onAttachedToWindow = onAttachedToWindow
    }

    static func dismantleNSView(_ view: TreeKeyboardView, coordinator: ()) {
        view.onKeyDown = { _ in false }
        view.onEditCommand = nil
        view.canEditCommand = nil
        view.onFocusChanged = { _ in }
        view.onAttachedToWindow = {}
    }
}

/// Receive a secondary click without taking primary clicks or drags from a SwiftUI row.
struct ContextMenuClickTarget: NSViewRepresentable {
    let onContextClick: () -> Void
    var onMenuClosed: (() -> Void)?
    var onMenuKeyDown: ((NSMenu, NSEvent) -> Bool)?

    init(onContextClick: @escaping () -> Void, onMenuClosed: (() -> Void)? = nil,
         onMenuKeyDown: ((NSMenu, NSEvent) -> Bool)? = nil) {
        self.onContextClick = onContextClick
        self.onMenuClosed = onMenuClosed
        self.onMenuKeyDown = onMenuKeyDown
    }

    func makeNSView(context: Context) -> ContextMenuClickView {
        ContextMenuClickView()
    }

    func updateNSView(_ view: ContextMenuClickView, context: Context) {
        view.onContextClick = onContextClick
        view.onMenuClosed = onMenuClosed
        view.onMenuKeyDown = onMenuKeyDown
    }

    static func dismantleNSView(_ view: ContextMenuClickView, coordinator: ()) {
        view.stopObservingMenu()
        view.onContextClick = nil
        view.onMenuClosed = nil
        view.onMenuKeyDown = nil
    }
}

final class ContextMenuClickView: NSView {
    var onContextClick: (() -> Void)?
    var onMenuClosed: (() -> Void)?
    var onMenuKeyDown: ((NSMenu, NSEvent) -> Bool)?
    private weak var contextMouseEvent: NSEvent?
    private var menuKeyMonitor: Any?
    private var trackingMenu: NSMenu?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown
                  || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        else { return nil }
        let hit = super.hitTest(point)
        if hit != nil { prepareContextClick(event) }
        return hit
    }

    private func prepareContextClick(_ event: NSEvent) {
        guard contextMouseEvent !== event else { return }
        contextMouseEvent = event
        stopObservingMenu()
        if onMenuClosed != nil || onMenuKeyDown != nil {
            NotificationCenter.default.addObserver(
                self, selector: #selector(menuDidBeginTracking(_:)),
                name: NSMenu.didBeginTrackingNotification, object: nil
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(menuDidEndTracking(_:)),
                name: NSMenu.didEndTrackingNotification, object: nil
            )
        }
        onContextClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        prepareContextClick(event)
        return super.menu(for: event)
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard trackingMenu == nil, let menu = notification.object as? NSMenu else { return }
        trackingMenu = menu
        guard onMenuKeyDown != nil else { return }
        menuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            let handled = assumeMainActor { self?.handleMenuKeyDown(event) == true }
            return handled ? nil : event
        }
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        guard trackingMenu === notification.object as? NSMenu else { return }
        onMenuClosed?()
        stopObservingMenu()
    }

    private func handleMenuKeyDown(_ event: NSEvent) -> Bool {
        guard let menu = trackingMenu,
              window?.isKeyWindow == true, NSApp.keyWindow === window,
              onMenuKeyDown?(menu, event) == true else { return false }
        if trackingMenu === menu {
            onMenuClosed?()
            stopObservingMenu()
        }
        return true
    }

    func stopObservingMenu() {
        NotificationCenter.default.removeObserver(
            self, name: NSMenu.didBeginTrackingNotification, object: nil
        )
        NotificationCenter.default.removeObserver(
            self, name: NSMenu.didEndTrackingNotification, object: nil
        )
        if let menuKeyMonitor { NSEvent.removeMonitor(menuKeyMonitor) }
        menuKeyMonitor = nil
        trackingMenu = nil
    }
}

/// One visual rule for selection, displayed content, keyboard cursor and menu target.
struct RowHighlightStyle: ViewModifier {
    private let themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    var isSelected = false
    var listActive = false
    var displayed = false
    var focusRing = false
    var contextRing = false
    var hovering = false
    var cornerRadius: CGFloat = 4

    func body(content: Content) -> some View {
        let _ = themeChanges.revision
        let theme = Theme.terminal(dark: colorScheme == .dark)
        let accent = Color(nsColor: theme.accentNSColor)
        let foreground = Color(nsColor: theme.foregroundNSColor)
        let fill: Color = if contextRing {
            .clear
        } else if isSelected {
            listActive
                ? accent.opacity(colorScheme == .dark ? 0.36 : 0.42)
                : foreground.opacity(0.14)
        } else if displayed {
            foreground.opacity(0.09)
        } else if hovering && !focusRing {
            foreground.opacity(0.05)
        } else {
            .clear
        }
        return content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(fill))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(focusRing || contextRing ? accent.opacity(0.65) : .clear,
                                  lineWidth: 1)
                    .allowsHitTesting(false)
            }
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
    let depth: Int
    let scale: CGFloat
    var displayed = false
    var isSelected = false
    var listActive = false
    var focusRing = false
    var contextRing = false
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
        displayed: Bool = false,
        isSelected: Bool = false,
        listActive: Bool = false,
        focusRing: Bool = false,
        contextRing: Bool = false,
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
        self.displayed = displayed
        self.isSelected = isSelected
        self.listActive = listActive
        self.focusRing = focusRing
        self.contextRing = contextRing
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
            .modifier(RowHighlightStyle(
                isSelected: isSelected, listActive: listActive, displayed: displayed,
                focusRing: focusRing, contextRing: contextRing,
                hovering: hoverEnabled && isHovering
            ))
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

struct TreeCompactSegment<MenuContent: View>: View {
    let component: TreeDisplayModel.Row.CompactComponent
    let index: Int
    var highlighted = false
    var isContextTarget = false
    let onClick: () -> Void
    let onContextClick: () -> Void
    let onMenuClosed: () -> Void
    var onMenuKeyDown: ((NSMenu, NSEvent) -> Bool)? = nil
    @ViewBuilder var menuContent: () -> MenuContent
    @State private var hovering = false

    var body: some View {
        Text(component.name)
            .underline(highlighted)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 3)
                .fill(hovering && !isContextTarget ? Color.primary.opacity(0.05) : .clear))
            .onHover { hovering = $0 }
            .highPriorityGesture(TapGesture().onEnded { onClick() })
            .overlay {
                ContextMenuClickTarget(onContextClick: onContextClick,
                                      onMenuClosed: onMenuClosed, onMenuKeyDown: onMenuKeyDown)
                    .contextMenu(menuItems: menuContent)
            }
            .accessibilityLabel(component.name)
            .accessibilityValue(component.path)
            .accessibilityIdentifier("bailey.tree.folder.component.\(index)")
    }
}

private struct TreeRowLabel: View {
    private let themeChanges = Theme.changes
    @Environment(\.colorScheme) private var colorScheme
    let row: TreeDisplayModel.Row
    let iconPath: String
    let scale: CGFloat
    var directory: String? = nil
    var compactSegment: ((TreeDisplayModel.Row.CompactComponent, Int) -> AnyView)? = nil

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
                                    compactSegment(entry.element, entry.offset)
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
    var contextRing = false
    var isSelected = false
    var listActive = false
    var compactSegment: ((TreeDisplayModel.Row.CompactComponent, Int) -> AnyView)? = nil
    let toggle: () -> Void
    @ViewBuilder var accessory: (Bool) -> Accessory

    var body: some View {
        TreeRowSurface(depth: row.depth, scale: scale,
                       isSelected: isSelected, listActive: listActive, focusRing: focusRing,
                       contextRing: contextRing, leadingInset: leadingInset) { hovering, layout in
            HStack(spacing: 0) {
                TreeRowLabel(row: row, iconPath: row.path, scale: scale,
                             compactSegment: compactSegment)
                    .modifier(layout)
                    .onTapGesture(perform: toggle)
                    .accessibilityAction(.default) { toggle() }
                    .help(row.accessibilityLabel + "\n" + row.path)
                .accessibilityLabel(row.accessibilityLabel)
                .accessibilityIdentifier("bailey.tree.folder")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
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
         focusRing: Bool = false, contextRing: Bool = false,
         isSelected: Bool = false,
         listActive: Bool = false,
         compactSegment: ((TreeDisplayModel.Row.CompactComponent, Int) -> AnyView)? = nil,
         toggle: @escaping () -> Void) {
        self.init(row: row, scale: scale, leadingInset: leadingInset,
                  focusRing: focusRing, contextRing: contextRing,
                  isSelected: isSelected,
                  listActive: listActive, compactSegment: compactSegment,
                  toggle: toggle) { _ in EmptyView() }
    }
}

struct TreeFileRow<Accessory: View>: View {
    let row: TreeDisplayModel.Row
    let scale: CGFloat
    var iconPath: String? = nil
    var directory: String? = nil
    var displayed = false
    var isSelected = false
    var listActive = false
    var focusRing = false
    var contextRing = false
    var leadingInset = TreeRowStyle.contentInset
    var accessibilityHint = ""
    var accessibilityID = "bailey.tree.file"
    let open: () -> Void
    var activate: (() -> Void)? = nil
    @ViewBuilder var accessory: (Bool) -> Accessory

    var body: some View {
        TreeRowSurface(depth: row.depth, scale: scale, displayed: displayed,
                       isSelected: isSelected, listActive: listActive, focusRing: focusRing,
                       contextRing: contextRing, leadingInset: leadingInset) { hovering, layout in
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
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(accessibilityHint)
                accessory(hovering || focusRing)
            }
        }
    }
}
