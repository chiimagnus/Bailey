import AppKit
import SwiftUI

/// One native drag source and destination. Local Files expose one Finder URL per
/// selected resource; remote Files never publish a local URL.
struct FileTreeNativeDragSurface: NSViewRepresentable {
    var onClick: ((NSEvent) -> Void)? = nil
    var beginDrag: (() -> FileTreeDrag.Record?)? = nil
    var endDrag: ((UUID) -> Void)? = nil
    let directory: String
    let isCurrent: () -> Bool
    let allowsFinder: Bool
    let receiveInternal: (FileTreeDrag.Record, String, Bool) -> Bool
    let importFinder: ([NSItemProvider], String) -> Bool
    var onDragOperationChanged: (NSDragOperation) -> Void = { _ in }

    func makeNSView(context: Context) -> FileTreeNativeDragView {
        FileTreeNativeDragView()
    }

    func updateNSView(_ view: FileTreeNativeDragView, context: Context) {
        view.onClick = onClick
        view.beginDrag = beginDrag
        view.endDrag = endDrag
        view.directory = directory
        view.isCurrent = isCurrent
        view.allowsFinder = allowsFinder
        view.receiveInternal = receiveInternal
        view.importFinder = importFinder
        view.onDragOperationChanged = onDragOperationChanged
    }

    static func dismantleNSView(_ view: FileTreeNativeDragView, coordinator: ()) {
        view.onClick = nil
        view.beginDrag = nil
        view.endDrag = nil
        view.receiveInternal = nil
        view.importFinder = nil
        view.clearDragOperation()
        view.onDragOperationChanged = nil
    }
}

final class FileTreeNativeDragView: NSView, NSDraggingSource {
    var onClick: ((NSEvent) -> Void)?
    var beginDrag: (() -> FileTreeDrag.Record?)?
    var endDrag: ((UUID) -> Void)?
    var directory = ""
    var isCurrent: () -> Bool = { false }
    var allowsFinder = false
    var receiveInternal: ((FileTreeDrag.Record, String, Bool) -> Bool)?
    var importFinder: (([NSItemProvider], String) -> Bool)?
    var onDragOperationChanged: ((NSDragOperation) -> Void)?
    private(set) var dragRecord: FileTreeDrag.Record?
    private var startedAsCopy = false
    private var acceptedDropOperation: NSDragOperation = []
    private var mouseDownEvent: NSEvent?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType(FileTreeDrag.type)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent {
            if event.type == .scrollWheel { return nil }
            if event.type == .rightMouseDown ||
               (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
                return nil
            }
            if onClick == nil && event.type == .leftMouseDown { return nil }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        if isCurrent() { onClick?(event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, isCurrent(), dragRecord == nil,
              hypot(down.locationInWindow.x - event.locationInWindow.x,
                    down.locationInWindow.y - event.locationInWindow.y) >= 4,
              let record = beginDrag?() else { return }
        mouseDownEvent = nil
        dragRecord = record
        startedAsCopy = down.modifierFlags.contains(.option)
            || event.modifierFlags.contains(.option)
        let items = Self.dragItems(record: record, local: allowsFinder)
        guard !items.isEmpty else {
            endDrag?(record.nonce)
            dragRecord = nil
            startedAsCopy = false
            return
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    static func dragItems(record: FileTreeDrag.Record, local: Bool) -> [NSDraggingItem] {
        record.source.paths.enumerated().map { index, path in
            let writer: NSPasteboardWriting
            if local {
                writer = URL(fileURLWithPath: path) as NSURL
            } else {
                let item = NSPasteboardItem()
                item.setString("drag", forType: NSPasteboard.PasteboardType(FileTreeDrag.type))
                writer = item
            }
            let item = NSDraggingItem(pasteboardWriter: writer)
            let image = local ? NSWorkspace.shared.icon(forFile: path)
                : (NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                   ?? NSImage(size: NSSize(width: 20, height: 20)))
            item.setDraggingFrame(
                NSRect(x: CGFloat(index) * 3, y: 0, width: 20, height: 20),
                contents: image
            )
            return item
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication
            ? (startedAsCopy ? .copy : [.copy, .move])
            : (allowsFinder ? .copy : [])
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let record = dragRecord { endDrag?(record.nonce) }
        dragRecord = nil
        startedAsCopy = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDragOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDragOperation()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDragOperation()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isCurrent() && acceptedDropOperation != []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = acceptedDropOperation
        defer { clearDragOperation() }
        guard isCurrent(), accepted != [] else { return false }
        if let source = sender.draggingSource as? FileTreeNativeDragView {
            guard source.window === window, let record = source.dragRecord else { return false }
            return receiveInternal?(record, directory, accepted == .copy) == true
        }
        guard allowsFinder, accepted == .copy,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
              ) as? [URL], !urls.isEmpty else { return false }
        return importFinder?(urls.map { NSItemProvider(object: $0 as NSURL) }, directory) == true
    }

    private func updateDragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let proposed = operation(for: sender)
        if acceptedDropOperation != proposed {
            acceptedDropOperation = proposed
            onDragOperationChanged?(proposed)
        }
        return proposed
    }

    func clearDragOperation() {
        guard acceptedDropOperation != [] else { return }
        acceptedDropOperation = []
        onDragOperationChanged?([])
    }

    static func preferredInternalOperation(from allowed: NSDragOperation) -> NSDragOperation {
        if allowed.contains(.move) { return .move }
        return allowed.contains(.copy) ? .copy : []
    }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard isCurrent(), !directory.isEmpty else { return [] }
        if let source = sender.draggingSource as? FileTreeNativeDragView {
            guard source.window === window, source.dragRecord != nil else { return [] }
            let allowed = sender.draggingSourceOperationMask
            if allowed == .copy { source.startedAsCopy = true }
            if source.startedAsCopy { return allowed.contains(.copy) ? .copy : [] }
            return Self.preferredInternalOperation(from: allowed)
        }
        guard allowsFinder,
              sender.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
              ) else { return [] }
        return .copy
    }
}
