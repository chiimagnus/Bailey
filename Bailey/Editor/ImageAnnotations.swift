import CoreGraphics
import Foundation
import Observation

/// Geometry is in the oriented image's original pixels, with the same
/// bottom-left origin as the shared RasterPreviewCanvas.
nonisolated enum ImageAnnotationTool: String, CaseIterable, Sendable {
    case select, arrow, rectangle, ellipse, text, number, blur, pixelate, crop
}

nonisolated enum ImageAnnotationColor: String, Codable, CaseIterable, Sendable {
    case red, orange, blue, white, black

    var cgColor: CGColor {
        switch self {
        case .red: CGColor(srgbRed: 0.9, green: 0.12, blue: 0.15, alpha: 1)
        case .orange: CGColor(srgbRed: 1, green: 0.5, blue: 0.05, alpha: 1)
        case .blue: CGColor(srgbRed: 0.12, green: 0.45, blue: 0.95, alpha: 1)
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
    }
}

nonisolated struct ImageAnnotationLayer: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case arrow, rectangle, ellipse, text, number, blur, pixelate

        var filtersPixels: Bool { self == .blur || self == .pixelate }
    }

    let id: UUID
    let kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: ImageAnnotationColor
    var strokeWidth: CGFloat
    var text: String

    init(id: UUID = UUID(), kind: Kind, start: CGPoint, end: CGPoint,
         color: ImageAnnotationColor, strokeWidth: CGFloat, text: String = "") {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.strokeWidth = strokeWidth
        self.text = text
    }

    var bounds: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var hitBounds: CGRect {
        kind == .arrow ? bounds.insetBy(dx: -strokeWidth * 2, dy: -strokeWidth * 2) : bounds
    }

    func hit(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let tolerance = max(0, tolerance) + strokeWidth / 2
        if kind == .arrow {
            let dx = end.x - start.x, dy = end.y - start.y
            let squared = dx * dx + dy * dy
            guard squared > 0 else { return false }
            let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / squared))
            return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy) <= tolerance
        }
        let rect = bounds.insetBy(dx: -tolerance, dy: -tolerance)
        guard rect.contains(point) else { return false }
        if kind == .ellipse || kind == .number {
            let x = (point.x - rect.midX) / (rect.width / 2)
            let y = (point.y - rect.midY) / (rect.height / 2)
            return x * x + y * y <= 1
        }
        return true
    }

    mutating func translate(x: CGFloat, y: CGFloat) {
        start.x += x
        start.y += y
        end.x += x
        end.y += y
    }
}

nonisolated struct ImageAnnotationState: Codable, Equatable, Sendable {
    static let maximumLayers = 1_024
    static let maximumTextUnits = 4_096

    var layers: [ImageAnnotationLayer] = []
    var crop: CGRect?

    var isEmpty: Bool { layers.isEmpty && crop == nil }
    var hasFilters: Bool { layers.contains { $0.kind.filtersPixels } }

    func validated(in size: CGSize) throws -> Self {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              layers.count <= Self.maximumLayers,
              Set(layers.map(\.id)).count == layers.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func valid(_ point: CGPoint) -> Bool {
            point.x.isFinite && point.y.isFinite &&
                point.x >= 0 && point.y >= 0 && point.x <= size.width && point.y <= size.height
        }
        for layer in layers {
            guard valid(layer.start), valid(layer.end), layer.strokeWidth.isFinite,
                  layer.strokeWidth > 0, layer.strokeWidth <= 128,
                  layer.text.utf16.count <= Self.maximumTextUnits,
                  !layer.text.utf16.contains(0) else { throw CocoaError(.fileReadCorruptFile) }
            if layer.kind == .arrow {
                guard layer.start != layer.end else { throw CocoaError(.fileReadCorruptFile) }
            } else {
                guard layer.bounds.width >= 1, layer.bounds.height >= 1 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            if layer.kind == .text || layer.kind == .number {
                guard !layer.text.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            } else if !layer.text.isEmpty {
                throw CocoaError(.fileReadCorruptFile)
            }
            if layer.kind == .number {
                guard let number = Int(layer.text), number > 0, number <= Self.maximumLayers else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
        if let crop {
            guard crop == crop.standardized, crop.width >= 1, crop.height >= 1,
                  valid(crop.origin), valid(CGPoint(x: crop.maxX, y: crop.maxY)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return self
    }
}

/// The FileTab retains this document across viewport remounts. The view owns
/// only the transient drag and text-field focus; committed edits have one undo stack.
@MainActor
@Observable
final class ImageAnnotationDocument {
    struct TextEdit {
        let id: UUID?
        let point: CGPoint
        var text: String
    }

    let size: CGSize
    private(set) var state: ImageAnnotationState
    private(set) var savedState: ImageAnnotationState
    private(set) var sidecarVersion: WorkspaceFileVersion?
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var permitsMutation: (() -> Bool)?
    var canMutate: Bool { permitsMutation?() ?? true }
    private var checkpoint: ImageAnnotationState?
    private(set) var selection: Set<UUID> = []
    var tool: ImageAnnotationTool = .select
    var color: ImageAnnotationColor = .red
    var textEdit: TextEdit?
    private(set) var textError: String?

    init(size: CGSize, state: ImageAnnotationState = .init(), version: WorkspaceFileVersion? = nil) {
        self.size = size
        self.state = state
        savedState = state
        sidecarVersion = version
        undoManager.groupsByEvent = false
    }

    var isEditing: Bool { checkpoint != nil }
    var isDirty: Bool { state != savedState }

    func begin() {
        guard canMutate, !isEditing else { return }
        checkpoint = state
        tool = .select
        selection.removeAll()
    }

    func finish() {
        guard canMutate, textEdit == nil else { return }
        checkpoint = nil
        textError = nil
        selection.removeAll()
    }

    func cancelText() {
        textEdit = nil
        textError = nil
    }

    func cancel() {
        guard canMutate, let checkpoint else { return }
        replace(with: checkpoint)
        cancelText()
        finish()
    }

    func markSaved(_ snapshot: ImageAnnotationState, version: WorkspaceFileVersion) {
        savedState = snapshot
        sidecarVersion = version
        // An explicit save during an annotation session establishes the
        // new cancel baseline; a later cancel must not undo saved bytes.
        if isEditing { checkpoint = snapshot }
        onChange?()
    }

    func select(at point: CGPoint, tolerance: CGFloat, extending: Bool) {
        let target = state.layers.last { $0.hit(point, tolerance: tolerance) }?.id
        if let target {
            if extending {
                if !selection.insert(target).inserted { selection.remove(target) }
            } else if !selection.contains(target) {
                selection = [target]
            }
        } else if !extending {
            selection.removeAll()
        }
    }

    func movedSelection(by delta: CGPoint) -> ImageAnnotationState {
        let selected = state.layers.filter { selection.contains($0.id) }
        guard !selected.isEmpty, delta.x.isFinite, delta.y.isFinite else { return state }
        let minX = selected.map { $0.bounds.minX }.min()!
        let maxX = selected.map { $0.bounds.maxX }.max()!
        let minY = selected.map { $0.bounds.minY }.min()!
        let maxY = selected.map { $0.bounds.maxY }.max()!
        let x = min(size.width - maxX, max(-minX, delta.x))
        let y = min(size.height - maxY, max(-minY, delta.y))
        var result = state
        for index in result.layers.indices where selection.contains(result.layers[index].id) {
            result.layers[index].translate(x: x, y: y)
        }
        return result
    }

    func proposedGesture(from first: CGPoint, to last: CGPoint) -> ImageAnnotationState {
        guard canMutate, isEditing, first.x.isFinite, first.y.isFinite, last.x.isFinite, last.y.isFinite else { return state }
        if tool == .select {
            return movedSelection(by: CGPoint(x: last.x - first.x, y: last.y - first.y))
        }
        guard tool != .text else { return state }
        let a = clamped(first), b = clamped(last)
        let line = min(24, max(2, min(size.width, size.height) * 0.004))
        var result = state
        if tool == .crop {
            let rect = rectangle(a, b).integral.intersection(CGRect(origin: .zero, size: size))
            if rect.width >= 1, rect.height >= 1 { result.crop = rect }
            return result
        }
        guard result.layers.count < ImageAnnotationState.maximumLayers else { return result }
        let kind: ImageAnnotationLayer.Kind
        var start = a, end = b, text = ""
        switch tool {
        case .select, .crop, .text: return result
        case .arrow:
            guard hypot(b.x - a.x, b.y - a.y) >= 1 else { return result }
            kind = .arrow
        case .rectangle: kind = .rectangle
        case .ellipse: kind = .ellipse
        case .blur: kind = .blur
        case .pixelate: kind = .pixelate
        case .number:
            kind = .number
            let used = Set(result.layers.filter { $0.kind == .number }.compactMap { Int($0.text) })
            guard let number = (1...ImageAnnotationState.maximumLayers).first(where: { !used.contains($0) }) else {
                return result
            }
            text = String(number)
            let side = min(size.width, size.height, max(20, line * 8))
            start = CGPoint(x: min(size.width - side, max(0, a.x - side / 2)),
                            y: min(size.height - side, max(0, a.y - side / 2)))
            end = CGPoint(x: start.x + side, y: start.y + side)
        }
        if kind != .arrow {
            let rect = rectangle(start, end)
            guard rect.width >= 1, rect.height >= 1 else { return result }
        }
        result.layers.append(.init(kind: kind, start: start, end: end, color: color, strokeWidth: line, text: text))
        return result
    }

    func commitGesture(from first: CGPoint, to last: CGPoint) {
        guard canMutate, isEditing else { return }
        if tool == .text {
            textEdit = .init(id: nil, point: clamped(first), text: "")
        } else {
            replace(with: proposedGesture(from: first, to: last))
        }
    }

    func editSelectedText(at point: CGPoint) {
        guard canMutate, isEditing, let layer = state.layers.last(where: { $0.kind == .text && $0.hit(point, tolerance: 0) }) else { return }
        selection = [layer.id]
        textEdit = .init(id: layer.id, point: layer.start, text: layer.text)
    }

    func commitText() {
        guard canMutate, isEditing, let edit = textEdit else { return }
        let text = edit.text
        guard !text.isEmpty, text.utf16.count <= ImageAnnotationState.maximumTextUnits,
              !text.utf16.contains(0) else {
            textError = String(localized: "Enter valid annotation text (up to 4096 UTF-16 code units).", table: "Editor")
            return
        }
        var result = state
        let index = edit.id.flatMap { id in result.layers.firstIndex { $0.id == id } }
        guard index != nil || result.layers.count < ImageAnnotationState.maximumLayers else { return }
        let existing = index.map { result.layers[$0] }
        let line = existing?.strokeWidth ?? min(24, max(2, min(size.width, size.height) * 0.004))
        let measured = ImageAnnotationDrawing.textSize(text, strokeWidth: line,
            within: CGSize(width: min(size.width, max(80, line * 60)), height: size.height))
        guard measured.height <= size.height else {
            textError = String(localized: "The annotation text does not fit on this image.", table: "Editor")
            return
        }
        let anchor = existing.map { CGPoint(x: $0.bounds.minX, y: $0.bounds.maxY) } ?? edit.point
        let start = CGPoint(x: min(size.width - measured.width, max(0, anchor.x)),
                            y: min(size.height - measured.height, max(0, anchor.y - measured.height)))
        let layer = ImageAnnotationLayer(id: existing?.id ?? UUID(), kind: .text, start: start,
            end: CGPoint(x: start.x + measured.width, y: start.y + measured.height),
            color: existing?.color ?? color, strokeWidth: line, text: text)
        if let index { result.layers[index] = layer }
        else { result.layers.append(layer) }
        replace(with: result)
        selection = [layer.id]
        cancelText()
    }

    func removeSelection() {
        guard canMutate, isEditing, !selection.isEmpty else { return }
        var result = state
        result.layers.removeAll { selection.contains($0.id) }
        replace(with: result)
    }

    func resetCrop() {
        guard canMutate, isEditing else { return }
        var result = state
        result.crop = nil
        replace(with: result)
    }

    private func replace(with value: ImageAnnotationState) {
        guard canMutate, state != value, (try? value.validated(in: size)) != nil else { return }
        let previous = state
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.replace(with: previous) }
        }
        state = value
        selection.formIntersection(Set(state.layers.map(\.id)))
        if grouping { undoManager.endUndoGrouping() }
        onChange?()
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(size.width, max(0, point.x)), y: min(size.height, max(0, point.y)))
    }

    private func rectangle(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
