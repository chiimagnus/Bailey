import AppKit
import SwiftUI

enum BottomToolbarLayout {
    static let height: CGFloat = 24
}

/// Project context for the active workspace. It stays deliberately compact so
/// terminal content remains the center of gravity below the tab strip.
struct BottomToolbarView: View {
    let model: GitStatusModel
    private let themeChanges = Theme.changes
    let height: CGFloat
    let toggleGitPanel: () -> Void
    let switchBranch: (String, String) -> Void
    let hideToolbar: () -> Void

    @State private var isShowingBranches = false
    @State private var branchFilter = ""
    @State private var branchSearchFocusRequest: UInt = 0
    @State private var branchScrollRequest: UInt = 0
    @State private var isBranchButtonHovered = false
    @State private var isChangesButtonHovered = false
    @State private var isNoRepositoryButtonHovered = false
    @State private var hoveredBranch: String?

    private var filteredBranches: [String] {
        let query = branchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        var branches = query.isEmpty ? model.branches : model.branches.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
        if let current = model.branch,
           let index = branches.firstIndex(of: current), index != branches.startIndex {
            branches.remove(at: index)
            branches.insert(current, at: branches.startIndex)
        }
        return branches
    }

    private var changesAccessibilityValue: String {
        guard model.totalChangeCount > 0 else { return String(localized: "Clean", table: "Workspace") }
        guard model.hasCurrentLineTotals else { return String(localized: "Line totals unavailable", table: "Workspace") }
        return String(localized: "+\(model.lineAdditions), −\(model.lineDeletions)", table: "Workspace")
    }

    var body: some View {
        let _ = themeChanges.revision
        HStack(spacing: 9) {
            if model.isRepo {
                branchButton
                changesButton
            } else {
                noRepositoryButton
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: height)
        .contentShape(Rectangle())
        .background {
            ToolbarContextMenuMonitor(hideToolbar: hideToolbar)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: Theme.divider))
                .frame(height: 1)
        }
    }

    private var noRepositoryButton: some View {
        Button(action: toggleGitPanel) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(String(localized: "No Git Repository", table: "Interface"))
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        isNoRepositoryButtonHovered
                            ? Color.primary.opacity(0.08)
                            : Color.clear
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isNoRepositoryButtonHovered = $0 }
    }

    private var branchButton: some View {
        Button {
            toggleBranchPicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(nsColor: Theme.accent))
                Text(verbatim: model.branch ?? "detached HEAD")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isBranchButtonHovered ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isBranchButtonHovered = $0 }
        .background {
            InstantPopoverPresenter(
                isPresented: $isShowingBranches,
                preferredEdge: .maxY,
                onPresent: {
                    guard isShowingBranches else { return }
                    branchSearchFocusRequest &+= 1
                    branchScrollRequest &+= 1
                },
                onDismiss: {
                    hoveredBranch = nil
                }
            ) {
                branchPicker
            }
        }
        .disabled(model.isBusy || !model.canUseCurrentReferences)
        .help(String(localized: "Switch Branch", table: "Interface"))
        .accessibilityLabel(
            String(localized: "Current branch, \(model.branch ?? String(localized: "detached HEAD", table: "Workspace"))", table: "Workspace")
        )
    }

    private var changesButton: some View {
        Button(action: toggleGitPanel) {
            HStack {
                if model.totalChangeCount == 0 {
                    Circle()
                        .fill(Color(red: 0.25, green: 0.73, blue: 0.31))
                        .frame(width: 6, height: 6)
                    Text(String(localized: "Clean", table: "Interface"))
                } else if model.hasCurrentLineTotals {
                    Text(verbatim: "+\(model.lineAdditions)")
                        .foregroundStyle(Color(red: 0.25, green: 0.73, blue: 0.31))
                        .monospacedDigit()
                    Text(verbatim: "−\(model.lineDeletions)")
                        .foregroundStyle(Color(red: 1.0, green: 0.48, blue: 0.45))
                        .monospacedDigit()
                } else {
                    Text(verbatim: "…")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isChangesButtonHovered ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isChangesButtonHovered = $0 }
        .help(String(localized: "Open Changes", table: "Interface"))
        .accessibilityLabel(String(localized: "Open Changes", table: "Interface"))
        .accessibilityValue(changesAccessibilityValue)
    }

    private var branchPicker: some View {
        VStack(spacing: 0) {
            BranchSearchField(
                text: $branchFilter,
                focusRequest: branchSearchFocusRequest
            ) {
                if filteredBranches.count == 1,
                   let branch = filteredBranches.first,
                   branch != model.branch {
                    selectBranch(branch, expectedOID: model.refsByName["refs/heads/" + branch]?.oid)
                }
            }
            .frame(height: 22)
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filteredBranches.isEmpty {
                            Text(String(localized: "No matches", table: "Interface"))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(filteredBranches, id: \.self) { branch in
                                let isHovered = hoveredBranch == branch
                                let expectedOID = model.refsByName["refs/heads/" + branch]?.oid
                                Button {
                                    selectBranch(branch, expectedOID: expectedOID)
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .semibold))
                                            .opacity(branch == model.branch ? 1 : 0)
                                        Text(verbatim: branch)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        if branch == model.defaultBranch {
                                            Text(String(
                                                localized: "default", table: "Interface",
                                                comment: "Badge for the repository's default branch."
                                            ))
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(
                                                isHovered
                                                    ? Color.white.opacity(0.85)
                                                    : Color(nsColor: .secondaryLabelColor)
                                            )
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(
                                                Capsule().fill(
                                                    isHovered
                                                        ? Color.white.opacity(0.18)
                                                        : Color.primary.opacity(0.07)
                                                )
                                            )
                                            .fixedSize()
                                        }
                                    }
                                    .foregroundStyle(isHovered ? Color.white : Color.primary)
                                    .padding(.horizontal, 9)
                                    .frame(height: 26)
                                    .background {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(
                                                isHovered
                                                    ? Color(nsColor: .selectedContentBackgroundColor)
                                                    : Color.clear
                                            )
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { isHovered in
                                    if isHovered {
                                        hoveredBranch = branch
                                    } else if hoveredBranch == branch {
                                        hoveredBranch = nil
                                    }
                                }
                                .disabled(branch == model.branch || model.isBusy)
                                .id(branch)
                            }
                        }
                    }
                    .padding(5)
                }
                .onChange(of: branchScrollRequest) {
                    guard let branch = model.branch else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(branch, anchor: .top)
                    }
                }
            }
        }
        .font(.system(size: 11))
        .frame(width: 260, height: 250)
        .background {
            VisualEffectView(material: .popover)
                .ignoresSafeArea()
        }
    }

    private func toggleBranchPicker() {
        if !isShowingBranches { branchFilter = "" }
        isShowingBranches.toggle()
    }

    private func selectBranch(_ branch: String, expectedOID: String?) {
        guard let expectedOID else { return }
        isShowingBranches = false
        switchBranch(branch, expectedOID)
    }
}

/// NSSearchField supplies the standard macOS bezel, magnifier, clear button,
/// focus ring, and vibrancy-aware colors inside the native popover.
private struct BranchSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UInt
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.placeholderString = String(localized: "Filter branches", table: "Workspace")
        field.setAccessibilityLabel(String(localized: "Filter branches", table: "Workspace"))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.string = text
        }
        guard context.coordinator.handledFocusRequest != focusRequest else { return }
        context.coordinator.handledFocusRequest = focusRequest
        context.coordinator.focus(field)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: BranchSearchField
        var handledFocusRequest: UInt?

        init(parent: BranchSearchField) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest == 0 ? 0 : nil
        }

        func focus(_ field: NSSearchField, attemptsRemaining: Int = 6) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                if let window = field.window, window.makeFirstResponder(field) { return }
                guard attemptsRemaining > 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.focus(field, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            parent.text = textView.string
            parent.onSubmit()
            return true
        }
    }
}

/// SwiftUI anchors a context menu to this full-width toolbar view. A local
/// AppKit monitor retains the same hit area while presenting from the actual
/// right-click event, so the menu appears at the pointer instead.
private struct ToolbarContextMenuMonitor: NSViewRepresentable {
    let hideToolbar: () -> Void

    func makeNSView(context: Context) -> ToolbarContextMenuMonitorView {
        let view = ToolbarContextMenuMonitorView()
        view.hideToolbar = hideToolbar
        return view
    }

    func updateNSView(_ nsView: ToolbarContextMenuMonitorView, context: Context) {
        nsView.hideToolbar = hideToolbar
    }

    static func dismantleNSView(
        _ nsView: ToolbarContextMenuMonitorView,
        coordinator: ()
    ) {
        nsView.detach()
    }
}

@MainActor
private final class ToolbarContextMenuMonitorView: NSView {
    var hideToolbar: () -> Void = {}
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
            [weak self, weak window] event in
            let input = ToolbarContextMenuEvent(event)
            let output: ToolbarContextMenuEvent = MainActor.assumeIsolated {
                guard let self,
                      let window,
                      let event = input.value,
                      event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return input }

                let menu = NSMenu()
                let hideItem = NSMenuItem(
                    title: String(localized: "Hide", table: "Workspace"),
                    action: #selector(self.hideToolbarFromMenu),
                    keyEquivalent: ""
                )
                hideItem.target = self
                menu.addItem(hideItem)
                menu.update()
                var screenPoint = window.convertPoint(toScreen: event.locationInWindow)
                // The toolbar sits at the screen's lower edge. Position the
                // menu upward so its bottom edge, rather than its top edge,
                // meets the pointer without AppKit relocating the whole menu.
                screenPoint.y += menu.size.height
                _ = menu.popUp(positioning: nil, at: screenPoint, in: nil)
                return ToolbarContextMenuEvent(nil)
            }
            return output.value
        }
    }

    @objc private func hideToolbarFromMenu() {
        hideToolbar()
    }

    func detach() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    isolated deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}

/// Local event monitors run synchronously on AppKit's main event thread.
private struct ToolbarContextMenuEvent: @unchecked Sendable {
    let value: NSEvent?

    init(_ value: NSEvent?) {
        self.value = value
    }
}

/// A single AppKit-owned popover avoids SwiftUI's re-entrant presentation path:
/// rapid binding changes reconcile against `isShown`, and generation checks
/// prevent a stale close callback from dismissing a newer presentation.
private struct InstantPopoverPresenter<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let onPresent: () -> Void
    let onDismiss: () -> Void
    let content: () -> PopoverContent

    init(
        isPresented: Binding<Bool>,
        preferredEdge: NSRectEdge,
        onPresent: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) {
        _isPresented = isPresented
        self.preferredEdge = preferredEdge
        self.onPresent = onPresent
        self.onDismiss = onDismiss
        self.content = content
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: InstantPopoverPresenter
        let popover: NSPopover
        let hostingController: NSHostingController<PopoverContent>
        private var presentationGeneration: UInt = 0

        init(parent: InstantPopoverPresenter) {
            self.parent = parent
            popover = NSPopover()
            hostingController = NSHostingController(rootView: parent.content())
            super.init()
            popover.animates = false
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = hostingController
        }

        func reconcile(parent: InstantPopoverPresenter, anchor: NSView) {
            self.parent = parent
            hostingController.rootView = parent.content()
            popover.animates = false

            if parent.isPresented {
                guard !popover.isShown, anchor.window != nil else { return }
                presentationGeneration &+= 1
                hostingController.view.layoutSubtreeIfNeeded()
                let fittingSize = hostingController.view.fittingSize
                if fittingSize.width > 0, fittingSize.height > 0 {
                    popover.contentSize = fittingSize
                }
                popover.show(
                    relativeTo: anchor.bounds,
                    of: anchor,
                    preferredEdge: parent.preferredEdge
                )
            } else if popover.isShown {
                popover.close()
            }
        }

        func popoverWillShow(_ notification: Notification) {
            popover.animates = false
        }

        func popoverDidShow(_ notification: Notification) {
            let generation = presentationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      self.popover.isShown,
                      self.parent.isPresented else { return }
                self.parent.onPresent()
            }
        }

        func popoverWillClose(_ notification: Notification) {
            popover.animates = false
        }

        func popoverDidClose(_ notification: Notification) {
            let generation = presentationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      !self.popover.isShown else { return }
                self.parent.onDismiss()
                if self.parent.isPresented {
                    self.parent.isPresented = false
                }
            }
        }

        func dismantle() {
            popover.delegate = nil
            popover.animates = false
            popover.close()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.reconcile(parent: self, anchor: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismantle()
    }
}
