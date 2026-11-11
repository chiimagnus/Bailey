import AppKit
import SwiftUI

/// Keeps the traffic-light buttons aligned with the app's 38pt header bar:
/// 20pt leading, vertically centered on the header's center line. AppKit
/// re-lays the buttons out on various events, so we re-apply after each.
struct WindowChromeAccessor: NSViewRepresentable {
    static let buttonCenterY: CGFloat = 21
    static let buttonLeading: CGFloat = 16
    static let buttonSpacing: CGFloat = 20

    private let onAttach: (NSWindow) -> Void
    private let hasUnsavedEdits: () -> Bool
    private let saveBeforeClose: () async -> Bool

    init(
        onAttach: @escaping (NSWindow) -> Void,
        hasUnsavedEdits: @escaping () -> Bool,
        saveBeforeClose: @escaping () async -> Bool
    ) {
        self.onAttach = onAttach
        self.hasUnsavedEdits = hasUnsavedEdits
        self.saveBeforeClose = saveBeforeClose
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onAttach: onAttach, hasUnsavedEdits: hasUnsavedEdits,
            saveBeforeClose: saveBeforeClose
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowChromeAttachmentView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? WindowChromeAttachmentView else { return }
        view.coordinator = context.coordinator
        if let window = view.window {
            context.coordinator.attach(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        // Objective-C selector forwarding is nonisolated; AppKit owns this
        // delegate and calls it on the main thread, like our attach method.
        nonisolated(unsafe) private weak var originalDelegate: (any NSWindowDelegate)?
        private var observers: [NSObjectProtocol] = []
        private var savingBeforeClose = false
        private var approvedClose = false
        private let onAttach: (NSWindow) -> Void
        private let hasUnsavedEdits: () -> Bool
        private let saveBeforeClose: () async -> Bool

        init(
            onAttach: @escaping (NSWindow) -> Void,
            hasUnsavedEdits: @escaping () -> Bool,
            saveBeforeClose: @escaping () async -> Bool
        ) {
            self.onAttach = onAttach
            self.hasUnsavedEdits = hasUnsavedEdits
            self.saveBeforeClose = saveBeforeClose
            super.init()
        }

        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
        }

        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let originalDelegate, originalDelegate.responds(to: aSelector) {
                return originalDelegate
            }
            return super.forwardingTarget(for: aSelector)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if approvedClose || !hasUnsavedEdits() {
                return originalDelegate?.windowShouldClose?(sender) ?? true
            }
            guard !savingBeforeClose else { return false }
            savingBeforeClose = true
            Task { @MainActor [weak self, weak sender] in
                guard let self else { return }
                let saved = await self.saveBeforeClose()
                self.savingBeforeClose = false
                guard saved, !self.hasUnsavedEdits(),
                      let sender, sender === self.window else { return }
                self.approvedClose = true
                sender.performClose(nil)
                self.approvedClose = false
            }
            return false
        }

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            if let previous = self.window, previous.delegate === self {
                previous.delegate = originalDelegate
            }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            self.window = window
            // A SwiftUI content remount can replace this coordinator before
            // the old one is destroyed. Keep forwarding to SwiftUI's actual
            // delegate, not to an earlier temporary coordinator.
            if let earlier = window.delegate as? Coordinator {
                originalDelegate = earlier.originalDelegate
            } else {
                originalDelegate = window.delegate
            }
            window.delegate = self
            onAttach(window)
            reposition()
            // The initial system layout can land after us; catch up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reposition() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reposition() }

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResignMainNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reposition()
                    }
                })
            }
        }

        private func reposition() {
            guard let window else { return }
            guard !window.styleMask.contains(.fullScreen) else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in types.enumerated() {
                guard let button = window.standardWindowButton(type),
                      let superview = button.superview
                else { continue }
                let centerInWindow = NSPoint(
                    x: WindowChromeAccessor.buttonLeading + CGFloat(index) * WindowChromeAccessor.buttonSpacing + button.frame.width / 2,
                    y: window.frame.height - WindowChromeAccessor.buttonCenterY
                )
                let center = superview.convert(centerInWindow, from: nil)
                let origin = NSPoint(
                    x: center.x - button.frame.width / 2,
                    y: center.y - button.frame.height / 2
                )
                if button.frame.origin != origin {
                    button.setFrameOrigin(origin)
                }
            }
        }

        isolated deinit {
            if let window, window.delegate === self {
                window.delegate = originalDelegate
            }
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

/// SwiftUI may finish its initial update before AppKit installs the view in a window.
/// The attachment event, not a one-shot runloop check, owns that transition.
private final class WindowChromeAttachmentView: NSView {
    weak var coordinator: WindowChromeAccessor.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { coordinator?.attach(window) }
    }
}

/// The native titlebar moves the window; blank areas alone handle its double-click action.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragAreaView { WindowDragAreaView() }
    func updateNSView(_ view: WindowDragAreaView, context: Context) {}

    static func dismantleNSView(_ view: WindowDragAreaView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class WindowDragAreaView: NSView {
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            assumeMainActor {
                self?.handleDoubleClick(event) == true ? nil : event
            }
        }
    }

    private func handleDoubleClick(_ event: NSEvent) -> Bool {
        guard event.clickCount == 2, let window, event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
        window.performTitlebarDoubleClickAction()
        return true
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    isolated deinit { stopMonitoring() }
}

extension NSWindow {
    /// Mirrors what a standard title bar does on double-click, honoring the
    /// "Double-click a window's title bar to" setting in System Settings.
    /// The global default is absent when set to Zoom, which is the default.
    func performTitlebarDoubleClickAction() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            performMiniaturize(nil)
        case "None":
            break
        default: // "Maximize" or unset
            performZoom(nil)
        }
    }
}
