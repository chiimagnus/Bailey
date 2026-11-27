import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Bailey

// A real Core Image processor fails at execution, after an image graph has
// been created successfully. It does not reset the user's GPU or mock CIContext.
private nonisolated final class FailingAnnotationRenderKernel: CIImageProcessorKernel {
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        throw NSError(domain: "Bailey.AnnotationRenderTest", code: 42)
    }
}

@MainActor
final class ImageAnnotationTests: XCTestCase {
    private func makeRoot(on volume: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let root = volume.appendingPathComponent("bailey-annotations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func png(width: Int = 160, height: Int = 120, offset: Int = 0) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width / 2, by: 4) {
                let gray: CGFloat = ((x / 4 + y / 4 + offset) % 2 == 0) ? 1 : 0
                context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func waitFor(_ label: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(label)
                throw WorkspaceError.timedOut
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private func open(_ path: URL, backend: LocalWorkspaceBackend = .shared) async throws -> FileTab {
        let file = FileTab(path: path.path, backend: backend, workspaceIdentity: nil)
        file.loadIfNeeded()
        try await waitFor("Open original image and its annotation document") {
            if case .image = file.content { return true }
            return false
        }
        return file
    }

    private func add(_ tool: ImageAnnotationTool, to document: ImageAnnotationDocument,
                     from first: CGPoint, to last: CGPoint) {
        if !document.isEditing { document.begin() }
        document.tool = tool
        document.commitGesture(from: first, to: last)
    }

    private func image(_ bytes: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(bitmap.colorAt(x: x, y: image.height - 1 - y)?.usingColorSpace(.sRGB))
    }

    func testConfirmedExportReplacesOnlyTheAcceptedIndependentFile() async throws {
        let root = try makeRoot()
        let original = try png()
        let source = root.appendingPathComponent("original.png")
        let output = root.appendingPathComponent("export.png")
        try original.write(to: source)
        let file = try await open(source)
        defer { file.retireContent() }
        let document = try XCTUnwrap(file.imageAnnotations)
        add(.arrow, to: document, from: CGPoint(x: 30, y: 10), to: CGPoint(x: 120, y: 90))
        let revision = file.fileContentRevision
        let options = ImageAnnotationDrawing.Options(width: 160, height: 120)
        let previous = try png(offset: 1)
        try previous.write(to: output)
        let target = try await file.prepareAnnotationExport(request: revision, options: options, to: output)
        XCTAssertTrue(target.replacesExistingFile)
        XCTAssertEqual(try Data(contentsOf: output), previous, "Confirmation preparation is read-only")
        do {
            try await file.exportAnnotatedImage(request: revision, options: options, to: output)
            XCTFail("An existing output still requires confirmation")
        } catch {}
        try await file.exportAnnotatedImage(request: revision, options: options, to: output, confirmedTarget: target)
        let rendered = try Data(contentsOf: output)
        XCTAssertNotEqual(rendered, previous)
        XCTAssertEqual(try image(rendered).width, 160)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(file.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImageAnnotationSidecar.path(for: source.path)))

        let stale = try await file.prepareAnnotationExport(request: revision, options: options, to: output)
        try previous.write(to: output, options: .atomic)
        do {
            try await file.exportAnnotatedImage(request: revision, options: options, to: output, confirmedTarget: stale)
            XCTFail("A replacement after confirmation must not overwrite new bytes")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: output), previous)
        let link = root.appendingPathComponent("alias.png")
        try FileManager.default.linkItem(at: source, to: link)
        for forbidden in [source, link] {
            do {
                _ = try await file.prepareAnnotationExport(request: revision, options: options, to: forbidden)
                XCTFail("The original and hard-link alias must not be replacement targets")
            } catch {}
        }
        let protectedOutputSidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: output.path))
        try Data("protected".utf8).write(to: protectedOutputSidecar)
        do {
            _ = try await file.prepareAnnotationExport(request: revision, options: options, to: output)
            XCTFail("An annotated image must not be a replacement target")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: output), previous)
        XCTAssertEqual(try Data(contentsOf: protectedOutputSidecar), Data("protected".utf8))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMutationLockAndRetirementRejectStaleAnnotationActions() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("locked.png")
        let original = try png()
        try original.write(to: path)
        let file = try await open(path)
        let doc = try XCTUnwrap(file.imageAnnotations)
        let start = CGPoint(x: 10, y: 10), end = CGPoint(x: 30, y: 30)
        doc.begin()
        doc.tool = .rectangle
        let locked = await file.beginFileMutation()
        XCTAssertTrue(locked)
        XCTAssertFalse(doc.canMutate)
        doc.commitGesture(from: start, to: end)
        XCTAssertTrue(doc.state.isEmpty)
        XCTAssertFalse(file.isDirty)
        file.endFileMutation()
        doc.commitGesture(from: start, to: end)
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(doc.state.layers.count, 1)
        file.retireContent()
        XCTAssertFalse(doc.canMutate)
        doc.commitGesture(from: start, to: end)
        XCTAssertEqual(doc.state.layers.count, 1)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImageAnnotationSidecar.path(for: path.path)))
    }

    func testAllToolsShareOrientedCoordinatesAndOneUndoStack() throws {
        let document = ImageAnnotationDocument(size: CGSize(width: 600, height: 400))
        document.begin()
        let start = CGPoint(x: 20, y: 30), end = CGPoint(x: 200, y: 160)
        for tool in [ImageAnnotationTool.arrow, .rectangle, .ellipse, .number, .blur, .pixelate, .crop] {
            add(tool, to: document, from: start, to: end)
        }
        add(.text, to: document, from: CGPoint(x: 240, y: 300), to: end)
        document.textEdit?.text = "中文标注🙂"
        document.commitText()
        let completed = document.state
        XCTAssertEqual(completed.layers.map(\.kind), [.arrow, .rectangle, .ellipse, .number, .blur, .pixelate, .text])
        XCTAssertEqual(completed.crop, CGRect(x: 20, y: 30, width: 180, height: 130))
        XCTAssertEqual(completed.layers.last?.text, "中文标注🙂")
        XCTAssertNil(document.textError)
        XCTAssertTrue(document.isDirty)
        for _ in 0..<8 { document.undoManager.undo() }
        XCTAssertTrue(document.state.isEmpty)
        XCTAssertFalse(document.isDirty)
        for _ in 0..<8 { document.undoManager.redo() }
        XCTAssertEqual(document.state, completed)
        document.tool = .select
        document.select(at: CGPoint(x: 100, y: 100), tolerance: 0, extending: false)
        XCTAssertEqual(document.selection, [completed.layers[5].id], "Topmost layer wins an overlap")
        let label = try XCTUnwrap(completed.layers.last).bounds
        document.select(at: CGPoint(x: label.midX, y: label.midY), tolerance: 0, extending: true)
        XCTAssertEqual(document.selection.count, 2)
        let before = document.state
        document.commitGesture(from: CGPoint(x: 100, y: 100), to: CGPoint(x: -3000, y: 4000))
        XCTAssertNotEqual(document.state, before)
        XCTAssertNoThrow(try document.state.validated(in: document.size))
        document.undoManager.undo()
        XCTAssertEqual(document.state, before)
        document.cancel()
        XCTAssertTrue(document.state.isEmpty)
        XCTAssertFalse(document.isEditing)
        XCTAssertFalse(document.isDirty)
    }

    func testPenBendsHitOnlyTheStrokeAndMoveWithNativeUndo() throws {
        let document = ImageAnnotationDocument(size: CGSize(width: 160, height: 120))
        document.begin()
        document.tool = .pen
        let start = CGPoint(x: 120, y: 24), bend = CGPoint(x: 96, y: 64), end = CGPoint(x: 120, y: 96)
        let pending = document.proposedGesture(from: start, to: end, via: [start, bend, bend, end])
        XCTAssertTrue(document.state.isEmpty, "Preview should not register an edit")
        XCTAssertEqual(pending.layers.first?.via, [bend])
        document.commitGesture(from: start, to: end, via: [bend])
        let ink = try XCTUnwrap(document.state.layers.first)
        XCTAssertEqual(ink.bounds, CGRect(x: 96, y: 24, width: 24, height: 72))
        XCTAssertTrue(ink.hit(bend, tolerance: 0))
        XCTAssertFalse(ink.hit(CGPoint(x: 116, y: 64), tolerance: 0), "Do not hit empty space inside the bounds")

        document.undoManager.undo()
        XCTAssertTrue(document.state.isEmpty, "The complete stroke is one undo action")
        document.undoManager.redo()
        XCTAssertEqual(document.state.layers, [ink])
        document.tool = .select
        document.select(at: bend, tolerance: 0, extending: false)
        document.commitGesture(from: bend, to: CGPoint(x: 1000, y: -1000))
        let moved = try XCTUnwrap(document.state.layers.first)
        XCTAssertEqual(moved.start, CGPoint(x: 160, y: 0))
        XCTAssertEqual(moved.via, [CGPoint(x: 136, y: 40)])
        XCTAssertEqual(moved.end, CGPoint(x: 160, y: 72))
        document.undoManager.undo()
        XCTAssertEqual(document.state.layers, [ink])

        document.tool = .pen
        let edge = CGPoint(x: 5, y: 6)
        document.commitGesture(from: edge, to: edge)
        let dot = try XCTUnwrap(document.state.layers.last)
        XCTAssertTrue(dot.hit(edge, tolerance: 0))
        XCTAssertFalse(dot.hit(CGPoint(x: 7, y: 6), tolerance: 0))
        document.commitGesture(from: edge, to: edge, via: [CGPoint(x: CGFloat.infinity, y: 0)])
        XCTAssertEqual(document.state.layers.last, dot, "Nonfinite path samples must not enter the document")
        let loopOrigin = CGPoint(x: 15, y: 12)
        document.commitGesture(from: loopOrigin, to: loopOrigin, via: [CGPoint(x: -1, y: 120.5)])
        let loop = try XCTUnwrap(document.state.layers.last)
        let corner = CGPoint(x: 0, y: 120)
        XCTAssertEqual(loop.via, [corner], "A stroke returning to its origin still keeps its intermediate samples")
        XCTAssertTrue(loop.hit(corner, tolerance: 0))
        document.tool = .select
        document.select(at: edge, tolerance: 0, extending: false)
        document.select(at: bend, tolerance: 0, extending: true)
        XCTAssertEqual(document.selection, [dot.id, ink.id])
        document.commitGesture(from: bend, to: CGPoint(x: 1000, y: 1000))
        XCTAssertEqual(document.state.layers[1].start, CGPoint(x: 45, y: 30))
        XCTAssertEqual(document.state.layers.last, loop, "Only the selected paths move")
        document.cancel()
        XCTAssertTrue(document.state.isEmpty)
    }

    func testPenPathPointBudgetsAndMalformedGeometry() throws {
        let size = CGSize(width: 160, height: 120)
        let start = CGPoint(x: 20, y: 10), end = CGPoint(x: 7, y: 13)
        let maximumIntermediate = ImageAnnotationLayer.maximumPenPoints - 2
        let points = (0..<maximumIntermediate).map { CGPoint(x: 30, y: $0.isMultiple(of: 2) ? 48 : 50) }
        func layer(_ kind: ImageAnnotationLayer.Kind = .pen, via: [CGPoint]) -> ImageAnnotationLayer {
            .init(kind: kind, start: start, end: end, color: .red, strokeWidth: 2, via: via)
        }
        let full = (0..<(ImageAnnotationState.maximumPenPoints / ImageAnnotationLayer.maximumPenPoints))
            .map { _ in layer(via: points) }
        XCTAssertNoThrow(try ImageAnnotationState(layers: full).validated(in: size))
        for layers in [
            full + [layer(via: [start])],
            [layer(via: points + [start])],
            [layer(via: [CGPoint(x: -1, y: 0)])],
            [layer(via: [CGPoint(x: 0, y: CGFloat.nan)])],
            [layer(.rectangle, via: [start])],
        ] {
            XCTAssertThrowsError(try ImageAnnotationState(layers: layers).validated(in: size))
        }

        let document = ImageAnnotationDocument(size: size)
        document.begin()
        document.tool = .pen
        document.commitGesture(from: start, to: end, via: points + [start])
        XCTAssertTrue(document.state.isEmpty)
        document.commitGesture(from: start, to: end, via: points)
        XCTAssertEqual(document.state.layers.first?.via.count, maximumIntermediate)
        let maxedDocument = ImageAnnotationDocument(size: size, state: .init(layers: full))
        maxedDocument.begin()
        maxedDocument.tool = .pen
        XCTAssertEqual(maxedDocument.proposedGesture(from: start, to: end).layers.count, full.count)
    }

    func testPenReopensCurrentSidecarAndPreservesBentPixelsInCopyAndExport() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("pen.png")
        let original = try png()
        try original.write(to: path)
        let sidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path))
        let version = WorkspaceFileVersion(data: original)
        let earlier = try await ImageAnnotationSidecar.encode(.init(layers: [
            .init(kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 20, y: 20),
                  color: .blue, strokeWidth: 2)
        ]), version: version, size: CGSize(width: 160, height: 120))
        try earlier.write(to: sidecar)
        let file = try await open(path)
        defer { file.retireContent() }
        let document = try XCTUnwrap(file.imageAnnotations)
        XCTAssertEqual(document.state.layers.map(\.kind), [.rectangle])
        document.begin()
        document.tool = .pen
        document.commitGesture(from: CGPoint(x: 120, y: 24), to: CGPoint(x: 120, y: 96),
                               via: [CGPoint(x: 96, y: 64)])
        document.commitGesture(from: CGPoint(x: 137.5, y: 48.5), to: CGPoint(x: 137.5, y: 48.5))
        add(.crop, to: document, from: CGPoint(x: 90, y: 15), to: CGPoint(x: 150, y: 105))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try await file.copyAnnotatedImage(request: file.fileContentRevision, to: pasteboard)
        XCTAssertEqual(try Data(contentsOf: sidecar), earlier, "Copy keeps the earlier saved document")
        let copied = try image(XCTUnwrap(pasteboard.data(forType: .png)))

        await file.save()
        XCTAssertFalse(file.isDirty)
        XCTAssertNil(file.saveError)
        let saved = try Data(contentsOf: sidecar)
        let reopened = try await open(path)
        defer { reopened.retireContent() }
        XCTAssertEqual(reopened.imageAnnotations?.state, document.state)
        let output = root.appendingPathComponent("pen-export.png")
        try await reopened.exportAnnotatedImage(request: reopened.fileContentRevision,
            options: .init(width: 60, height: 90), to: output)
        let exported = try image(Data(contentsOf: output))
        for result in [copied, exported] {
            XCTAssertEqual(result.width, 60)
            XCTAssertEqual(result.height, 90)
            for (x, y) in [(6, 49), (17, 29), (18, 65), (47, 33)] {
                let ink = try pixel(result, x: x, y: y)
                XCTAssertGreaterThan(ink.redComponent - ink.greenComponent, 0.5)
                XCTAssertGreaterThan(ink.alphaComponent, 0.5)
            }
            XCTAssertLessThan(try pixel(result, x: 30, y: 49).alphaComponent, 0.01,
                              "Do not draw a straight line between the first and last points")
        }
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try Data(contentsOf: sidecar), saved)
    }

    func testSaveReopenUndoAndExportNeverChangeTheOriginalBytes() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("原图.png")
        let original = try png()
        try original.write(to: path)
        let sidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path))
        let file = try await open(path)
        defer { file.retireContent() }
        let document = try XCTUnwrap(file.imageAnnotations)
        XCTAssertTrue(file.canAnnotateImage)
        XCTAssertFalse(file.isDirty)
        await file.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        add(.arrow, to: document, from: CGPoint(x: 8, y: 10), to: CGPoint(x: 45, y: 45))
        XCTAssertTrue(file.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        document.cancel()
        XCTAssertFalse(file.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        add(.rectangle, to: document, from: CGPoint(x: 85, y: 20), to: CGPoint(x: 140, y: 90))
        add(.pixelate, to: document, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 75, y: 120))
        add(.crop, to: document, from: CGPoint(x: 16, y: 10), to: CGPoint(x: 156, y: 110))
        let state = document.state
        let version = WorkspaceFileVersion(data: original)
        XCTAssertTrue(PaneContent.file(file).isDirty)
        await file.save()
        XCTAssertNil(file.saveError)
        XCTAssertFalse(file.isDirty)
        XCTAssertEqual(try Data(contentsOf: path), original)
        let saved = try Data(contentsOf: sidecar)
        XCTAssertEqual(try ImageAnnotationSidecar.decode(saved, version: version, size: document.size), state)
        let reopened = try await open(path)
        defer { reopened.retireContent() }
        let restored = try XCTUnwrap(reopened.imageAnnotations)
        XCTAssertEqual(restored.state, state)
        XCTAssertFalse(restored.isDirty)
        add(.ellipse, to: restored, from: CGPoint(x: 95, y: 40), to: CGPoint(x: 120, y: 75))
        restored.undoManager.undo()
        XCTAssertFalse(reopened.isDirty)
        restored.undoManager.redo()
        XCTAssertTrue(reopened.isDirty)
        let options = ImageAnnotationDrawing.Options(width: 280, height: 200,
            colorSpace: .displayP3, background: .transparent, dpi: 300)
        let output = root.appendingPathComponent("export.png")
        try await reopened.exportAnnotatedImage(request: reopened.fileContentRevision, options: options, to: output)
        let bytes = try Data(contentsOf: output)
        let rendered = try image(bytes)
        XCTAssertEqual(rendered.width, 280)
        XCTAssertEqual(rendered.height, 200)
        XCTAssertEqual(rendered.colorSpace?.copyICCData() as Data?,
                       CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyDPIWidth] as? Double ?? 0, 300, accuracy: 0.1)
        let stroke = try pixel(rendered, x: (85 - 16) * 2, y: (60 - 10) * 2)
        XCTAssertGreaterThan(stroke.redComponent - stroke.greenComponent, 0.4)
        let transparent = try pixel(rendered, x: 270, y: 10)
        XCTAssertLessThan(transparent.alphaComponent, 0.01)
        XCTAssertEqual(try Data(contentsOf: sidecar), saved, "Export is not a save")
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertTrue(reopened.isDirty)
        do {
            try await reopened.exportAnnotatedImage(request: reopened.fileContentRevision, options: options, to: output)
            XCTFail("Export must not overwrite a prior target")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        let jpeg = root.appendingPathComponent("export.jpg")
        let jpegOptions = ImageAnnotationDrawing.Options(width: 140, height: 100,
            format: .jpeg, background: .white, dpi: 144)
        try await reopened.exportAnnotatedImage(request: reopened.fileContentRevision, options: jpegOptions, to: jpeg)
        let jpg = try image(Data(contentsOf: jpeg))
        XCTAssertEqual(jpg.width, 140)
        XCTAssertEqual(jpg.height, 100)
        XCTAssertGreaterThan(try pixel(jpg, x: 135, y: 5).redComponent, 0.9)
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testCopyAnnotatedDraftUsesActualCroppedPixelsWithoutWritingAndRejectsStaleRequests() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("copy.png")
        let original = try png()
        try original.write(to: path)
        let file = try await open(path)
        defer { file.retireContent() }
        let document = try XCTUnwrap(file.imageAnnotations)
        add(.rectangle, to: document, from: CGPoint(x: 15, y: 20), to: CGPoint(x: 50, y: 60))
        add(.crop, to: document, from: .zero, to: CGPoint(x: 80, y: 80))
        let draft = document.state
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let request = file.fileContentRevision
        try await file.copyAnnotatedImage(request: request, to: pasteboard)
        let copied = try XCTUnwrap(pasteboard.data(forType: .png))
        let rendered = try image(copied)
        XCTAssertEqual(rendered.width, 80)
        XCTAssertEqual(rendered.height, 80)
        let color = try pixel(rendered, x: 15, y: 40)
        XCTAssertGreaterThan(color.redComponent - color.greenComponent, 0.4)
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(document.state, draft)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImageAnnotationSidecar.path(for: path.path)))
        do {
            try await file.copyAnnotatedImage(request: "retired request", to: pasteboard)
            XCTFail("An outdated request must not replace the clipboard")
        } catch WorkspaceError.changedExternally {}
        let cancelled = Task { try await file.copyAnnotatedImage(request: request, to: pasteboard) }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled copy must not publish") }
        catch is CancellationError {}
        XCTAssertEqual(pasteboard.data(forType: .png), copied)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(document.state, draft)
    }

    func testClippedPreviewAndExportPreserveStrokesExtendingBeyondShapeBounds() async throws {
        let source = try image(png())
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let poster = RasterDetail.Patch(image: source, rect: bounds)
        let crop = CGRect(x: 60, y: 20, width: 20, height: 40)
        let options = ImageAnnotationDrawing.Options(width: 20, height: 40)
        for kind in [ImageAnnotationLayer.Kind.rectangle, .ellipse] {
            let state = ImageAnnotationState(layers: [
                .init(kind: kind, start: CGPoint(x: 40, y: 25),
                      end: CGPoint(x: 59, y: 55), color: .red, strokeWidth: 8)
            ], crop: crop)
            let whole = try await ImageAnnotationDrawing.preview(
                state, poster: poster, detail: nil, region: bounds, scale: 1)
            let partial = try await ImageAnnotationDrawing.preview(
                state, poster: poster, detail: nil, region: crop, scale: 1)
            let exported = try await ImageAnnotationDrawing.export(state, source: .whole(source), options: options)
            let output = try image(exported)
            let expected = try pixel(whole.image, x: 60, y: 40)
            XCTAssertGreaterThan(expected.redComponent - expected.greenComponent, 0.5)
            for image in [partial.image, output] {
                let actual = try pixel(image, x: 0, y: 20)
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.02, "\(kind)")
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.02, "\(kind)")
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.02, "\(kind)")
                XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.02, "\(kind)")
            }
        }
    }

    func testConcurrentFilteredExportsKeepTheirOwnPixelsAndColorSpace() async throws {
        let source = try image(png())
        let size = CGSize(width: source.width, height: source.height)
        let red = ImageAnnotationDocument(size: size)
        add(.blur, to: red, from: CGPoint(x: 4, y: 4), to: CGPoint(x: 76, y: 116))
        add(.rectangle, to: red, from: CGPoint(x: 12, y: 20), to: CGPoint(x: 60, y: 90))
        let blue = ImageAnnotationDocument(size: size)
        blue.color = .blue
        add(.pixelate, to: blue, from: CGPoint(x: 4, y: 4), to: CGPoint(x: 76, y: 116))
        add(.rectangle, to: blue, from: CGPoint(x: 12, y: 20), to: CGPoint(x: 60, y: 90))
        let first = red.state, second = blue.state
        let a = ImageAnnotationDrawing.Options(width: source.width, height: source.height, background: .white)
        let b = ImageAnnotationDrawing.Options(width: source.width, height: source.height, colorSpace: .displayP3, background: .black)
        for _ in 0..<12 {
            async let left = ImageAnnotationDrawing.export(first, source: .whole(source), options: a)
            async let right = ImageAnnotationDrawing.export(second, source: .whole(source), options: b)
            let (leftBytes, rightBytes) = try await (left, right)
            let leftImage = try image(leftBytes), rightImage = try image(rightBytes)
            let redStroke = try pixel(leftImage, x: 12, y: 50)
            let blueStroke = try pixel(rightImage, x: 12, y: 50)
            XCTAssertGreaterThan(redStroke.redComponent - redStroke.blueComponent, 0.4)
            XCTAssertGreaterThan(blueStroke.blueComponent - blueStroke.redComponent, 0.4)
            XCTAssertGreaterThan(try pixel(leftImage, x: 150, y: 50).redComponent, 0.95)
            XCTAssertLessThan(try pixel(rightImage, x: 150, y: 50).redComponent, 0.05)
            XCTAssertEqual(rightImage.colorSpace?.copyICCData() as Data?,
                           CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?)
        }
    }

    func testFilteredCropAndRegionalPreviewMatchWholeCompositionAtBoundaries() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 160)
        let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 160,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(bounds)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 114, y: 0, width: 126, height: 160))
        let source = try XCTUnwrap(context.makeImage())
        let poster = RasterDetail.Patch(image: source, rect: bounds)
        let crop = CGRect(x: 114, y: 20, width: 80, height: 100)
        let regional = RasterDetail.region(.native(source), .identity, .up)
        let detail = try await regional.render(crop)
        let small = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        small.draw(source, in: CGRect(x: 0, y: 0, width: 12, height: 8))
        let reducedPoster = RasterDetail.Patch(image: try XCTUnwrap(small.makeImage()), rect: bounds)
        let rectangle = ImageAnnotationLayer(kind: .rectangle, start: CGPoint(x: 102, y: 40),
            end: CGPoint(x: 110, y: 110), color: .red, strokeWidth: 8)
        let blur = ImageAnnotationLayer(kind: .blur, start: .zero,
            end: CGPoint(x: 240, y: 160), color: .red, strokeWidth: 8)
        let pixelate = ImageAnnotationLayer(kind: .pixelate, start: CGPoint(x: 24, y: 8),
            end: CGPoint(x: 232, y: 152), color: .red, strokeWidth: 8)
        for (index, layers) in [[blur], [pixelate], [rectangle, blur, pixelate, blur]].enumerated() {
            let state = ImageAnnotationState(layers: layers.map { layer in
                // Each layer owns an independent identity, even if its geometry repeats.
                .init(kind: layer.kind, start: layer.start, end: layer.end,
                      color: layer.color, strokeWidth: layer.strokeWidth)
            }, crop: crop)
            for scale: CGFloat in [0.5, 1, 2] {
                let whole = try await ImageAnnotationDrawing.preview(
                    state, poster: poster, detail: nil, region: bounds, scale: scale)
                let partial = try await ImageAnnotationDrawing.preview(
                    state, poster: poster, detail: nil, region: crop, scale: scale)
                let width = Int(crop.width * scale), height = Int(crop.height * scale)
                let output = try image(await ImageAnnotationDrawing.export(state, source: .whole(source),
                    options: .init(width: width, height: height)))
                let expected = NSBitmapImageRep(cgImage: whole.image)
                let regionalOutput = try image(await ImageAnnotationDrawing.export(state, source: regional,
                    options: .init(width: width, height: height)))
                let exactPreview = try await ImageAnnotationDrawing.preview(
                    state, poster: reducedPoster, detail: detail, region: crop, scale: scale, original: regional)
                let images = [partial.image, output, regionalOutput, exactPreview.image].map(NSBitmapImageRep.init(cgImage:))
                if index == 0 && scale == 1 {
                    let boundary = try XCTUnwrap(expected.colorAt(x: 114, y: expected.pixelsHigh - 1 - 70)?.usingColorSpace(.sRGB))
                    XCTAssertLessThan(boundary.redComponent, 0.9, "The black pixels outside the crop must contribute")
                }
                if scale == 2 {
                    let letterboxed = try image(await ImageAnnotationDrawing.export(state, source: regional,
                        options: .init(width: width + 40, height: height, background: .transparent)))
                    XCTAssertEqual(try pixel(letterboxed, x: 5, y: height / 2).alphaComponent, 0, accuracy: 0.01)
                    let actual = try pixel(letterboxed, x: 20, y: height / 2)
                    let reference = try pixel(output, x: 0, y: height / 2)
                    XCTAssertEqual(actual.redComponent, reference.redComponent, accuracy: 0.025)
                    XCTAssertEqual(actual.greenComponent, reference.greenComponent, accuracy: 0.025)
                    XCTAssertEqual(actual.blueComponent, reference.blueComponent, accuracy: 0.025)
                }
                for x in [0, 1, width / 4, width / 2, width - 1] {
                    for y in [0, 1, height / 2, height - 2, height - 1] {
                        let reference = try XCTUnwrap(expected.colorAt(
                            x: x + Int(crop.minX * scale),
                            y: expected.pixelsHigh - 1 - y - Int(crop.minY * scale))?.usingColorSpace(.sRGB))
                        for bitmap in images {
                            let actual = try XCTUnwrap(bitmap.colorAt(x: x, y: height - 1 - y)?.usingColorSpace(.sRGB))
                            let description = "layers=\(index), scale=\(scale), x=\(x), y=\(y)"
                            XCTAssertEqual(actual.redComponent, reference.redComponent, accuracy: 0.025, description)
                            XCTAssertEqual(actual.greenComponent, reference.greenComponent, accuracy: 0.025, description)
                            XCTAssertEqual(actual.blueComponent, reference.blueComponent, accuracy: 0.025, description)
                            XCTAssertEqual(actual.alphaComponent, reference.alphaComponent, accuracy: 0.025, description)
                        }
                    }
                }
            }
        }
    }

    func testCoreImageExecutionFailureCannotPublishTransparentPixels() throws {
        let region = CGRect(x: 17, y: 9, width: 32, height: 24)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let failing = try FailingAnnotationRenderKernel.apply(withExtent: region, inputs: nil, arguments: nil)
        XCTAssertThrowsError(try ImageAnnotationDrawing.renderedImage(failing, area: region, space: space)) { error in
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(underlying?.domain, "Bailey.AnnotationRenderTest")
            XCTAssertEqual(underlying?.code, 42)
        }
        // The same renderer must still accept genuinely transparent imagery
        // and subsequent successful renders; opacity is not an error signal.
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
        let blank = try ImageAnnotationDrawing.renderedImage(transparent, area: region, space: space)
        XCTAssertEqual(try pixel(blank, x: 8, y: 8).alphaComponent, 0, accuracy: 0.001)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
        let valid = try ImageAnnotationDrawing.renderedImage(red, area: region, space: space)
        XCTAssertEqual(valid.width, 32)
        XCTAssertEqual(valid.height, 24)
        let sample = try pixel(valid, x: 8, y: 8)
        XCTAssertEqual(sample.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(sample.alphaComponent, 1, accuracy: 0.001)
    }

    func testRegionalAnnotationSamplingMatchesWholeImageAcrossColorsAndZooms() async throws {
        // Fixed-seed coverage of filter chains, image/patch boundaries, alpha
        // and the fractional zooms at which implicit CG sampling diverged.
        var seed: UInt64 = 0x9284192
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 32) % UInt64(bound))
        }
        func channels(_ image: NSBitmapImageRep, x: Int, y: Int) throws -> [CGFloat] {
            let color = try XCTUnwrap(image.colorAt(x: x, y: image.pixelsHigh - 1 - y)?.usingColorSpace(.sRGB))
            return [color.redComponent * color.alphaComponent, color.greenComponent * color.alphaComponent,
                    color.blueComponent * color.alphaComponent, color.alphaComponent]
        }
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 160)
        let scales: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3]
        let fractionalScales: [CGFloat] = [0.17, 0.37, 0.71, 1.37, 1.91, 2.11, 3.14159]
        let strokes: [CGFloat] = [1, 2.5, 7.25, 16, 64]
        let kinds: [ImageAnnotationLayer.Kind] = [.blur, .pixelate, .rectangle]
        for colorSpace in [ImageAnnotationDrawing.ColorSpace.sRGB, .displayP3] {
            let space = try XCTUnwrap(colorSpace.value)
            let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 160,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for y in stride(from: 0, to: 160, by: 4) {
                for x in stride(from: 0, to: 240, by: 4) {
                    let alpha = colorSpace == .sRGB ? 1 : CGFloat(next(5)) / 4
                    context.setFillColor(red: CGFloat(next(256)) / 255, green: CGFloat(next(256)) / 255,
                                         blue: CGFloat(next(256)) / 255, alpha: alpha)
                    context.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
            let source = try XCTUnwrap(context.makeImage())
            let regional = RasterDetail.region(.native(source), .identity, .up)
            let poster = RasterDetail.Patch(image: source, rect: bounds)
            for index in 0..<100 {
                let scale = scales[index % scales.count]
                let x = next(45) * 4, y = next(25) * 4
                let crop = CGRect(x: x, y: y, width: (next((240 - x) / 4) + 1) * 4,
                                  height: (next((160 - y) / 4) + 1) * 4)
                let layers: [ImageAnnotationLayer] = (0..<(1 + next(4))).map { layer in
                    let lx = next(40) * 4, ly = next(25) * 4
                    let ex = lx + (next((240 - lx) / 4) + 1) * 4
                    let ey = ly + (next((160 - ly) / 4) + 1) * 4
                    let kind = layer == 0 ? (index.isMultiple(of: 2) ? .blur : .pixelate) : kinds[next(3)]
                    return .init(kind: kind, start: CGPoint(x: lx, y: ly), end: CGPoint(x: ex, y: ey),
                                 color: .red, strokeWidth: strokes[next(strokes.count)])
                }
                let state = ImageAnnotationState(layers: layers, crop: crop)
                let whole = try await ImageAnnotationDrawing.preview(
                    state, poster: poster, detail: nil, region: bounds, scale: scale)
                let partial = try await ImageAnnotationDrawing.preview(
                    state, poster: poster, detail: nil, region: crop, scale: scale)
                let width = Int(crop.width * scale), height = Int(crop.height * scale)
                let exported = try image(await ImageAnnotationDrawing.export(state, source: regional,
                    options: .init(width: width, height: height, colorSpace: colorSpace)))
                let reference = NSBitmapImageRep(cgImage: whole.image)
                let images = [partial.image, exported].map(NSBitmapImageRep.init(cgImage:))
                // A pan at a fractional zoom must sample exactly the same
                // global pixel grid, even when the requested rect is not
                // aligned to the device pixels and its rounded size changes.
                let fractional = fractionalScales[index % fractionalScales.count]
                let pan = CGRect(x: crop.minX + 1, y: crop.minY + 1,
                                 width: crop.width - 2, height: crop.height - 2)
                let fullFractional = try await ImageAnnotationDrawing.preview(
                    state, poster: poster, detail: nil, region: bounds, scale: fractional)
                let panned = try await ImageAnnotationDrawing.preview(
                    state, poster: poster, detail: nil, region: pan, scale: fractional)
                let panReference = NSBitmapImageRep(cgImage: fullFractional.image)
                let panBitmap = NSBitmapImageRep(cgImage: panned.image)
                let startX = Int((panned.rect.minX * fractional).rounded())
                let startY = Int((panned.rect.minY * fractional).rounded())
                for dx in Set([0, panned.image.width / 2, panned.image.width - 1]) {
                    for dy in Set([0, panned.image.height / 2, panned.image.height - 1]) {
                        let expected = try channels(panReference, x: startX + dx, y: startY + dy)
                        let actual = try channels(panBitmap, x: dx, y: dy)
                        for (a, e) in zip(actual, expected) {
                            XCTAssertEqual(a, e, accuracy: 0.025,
                                "\(colorSpace) pan \(index), zoom \(fractional), pixel (\(dx), \(dy))")
                        }
                    }
                }
                for dx in Set([0, min(1, width - 1), width / 4, width / 2, width - 1]) {
                    for dy in Set([0, min(1, height - 1), height / 4, height / 2, height - 1]) {
                        let expected = try channels(reference, x: Int(crop.minX * scale) + dx,
                                                    y: Int(crop.minY * scale) + dy)
                        for bitmap in images {
                            let actual = try channels(bitmap, x: dx, y: dy)
                            for (a, e) in zip(actual, expected) {
                                XCTAssertEqual(a, e, accuracy: 0.025,
                                    "\(colorSpace) case \(index), zoom \(scale), pixel (\(dx), \(dy))")
                            }
                        }
                    }
                }
            }
        }
    }

    func testFiltersChangeActualPixelsAndRespectLayerOrder() async throws {
        let source = try image(png())
        let region = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let doc = ImageAnnotationDocument(size: region.size)
        add(.blur, to: doc, from: CGPoint(x: 4, y: 4), to: CGPoint(x: 76, y: 116))
        add(.rectangle, to: doc, from: CGPoint(x: 12, y: 20), to: CGPoint(x: 60, y: 90))
        let options = ImageAnnotationDrawing.Options(width: source.width, height: source.height)
        let result = try image(await ImageAnnotationDrawing.export(doc.state, source: .whole(source), options: options))
        let blurred = try pixel(result, x: 34, y: 34)
        XCTAssertGreaterThan(blurred.redComponent, 0.05)
        XCTAssertLessThan(blurred.redComponent, 0.95)
        let stroke = try pixel(result, x: 12, y: 50)
        XCTAssertGreaterThan(stroke.redComponent - stroke.greenComponent, 0.4)
        let preview = try await ImageAnnotationDrawing.preview(doc.state,
            poster: .init(image: source, rect: region), detail: nil, region: region, scale: 1)
        let visible = try pixel(preview.image, x: 12, y: 50)
        XCTAssertEqual(visible.redComponent, stroke.redComponent, accuracy: 0.04)
        XCTAssertEqual(visible.greenComponent, stroke.greenComponent, accuracy: 0.04)
        let reverse = ImageAnnotationState(layers: Array(doc.state.layers.reversed()))
        let reversed = try image(await ImageAnnotationDrawing.export(reverse, source: .whole(source), options: options))
        let filteredStroke = try pixel(reversed, x: 12, y: 50)
        XCTAssertLessThan(filteredStroke.redComponent - filteredStroke.greenComponent, stroke.redComponent - stroke.greenComponent)
    }

    func testSidecarConflictsFirstCreationAndReplacedSourcePreserveBothDrafts() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("same.png")
        let original = try png()
        try original.write(to: path)
        let sidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path))
        let first = try await open(path)
        let second = try await open(path)
        defer { first.retireContent(); second.retireContent() }
        let a = try XCTUnwrap(first.imageAnnotations), b = try XCTUnwrap(second.imageAnnotations)
        add(.rectangle, to: a, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 90, y: 90))
        add(.ellipse, to: b, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 100, y: 100))
        async let saveA: Void = first.save()
        async let saveB: Void = second.save()
        _ = await (saveA, saveB)
        XCTAssertNotEqual(first.isDirty, second.isDirty)
        let winner = first.isDirty ? b : a
        let loser = first.isDirty ? first : second
        XCTAssertNotNil(loser.saveError)
        let stored = try Data(contentsOf: sidecar)
        XCTAssertEqual(try ImageAnnotationSidecar.decode(stored, version: WorkspaceFileVersion(data: original),
                                                         size: winner.size), winner.state)
        let x = try await open(path), y = try await open(path)
        defer { x.retireContent(); y.retireContent() }
        let xd = try XCTUnwrap(x.imageAnnotations), yd = try XCTUnwrap(y.imageAnnotations)
        add(.arrow, to: xd, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 50, y: 50))
        add(.number, to: yd, from: CGPoint(x: 45, y: 45), to: CGPoint(x: 45, y: 45))
        await x.save()
        XCTAssertFalse(x.isDirty)
        let updated = try Data(contentsOf: sidecar)
        await y.save()
        XCTAssertTrue(y.isDirty)
        XCTAssertNotNil(y.saveError)
        XCTAssertEqual(try Data(contentsOf: sidecar), updated)
        let other = try png(offset: 1)
        try other.write(to: path, options: .atomic)
        add(.arrow, to: xd, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 70, y: 80))
        await x.save()
        XCTAssertTrue(x.isDirty)
        XCTAssertNotNil(x.saveError)
        XCTAssertEqual(try Data(contentsOf: path), other)
        XCTAssertEqual(try Data(contentsOf: sidecar), updated)
        let replaced = try await open(path)
        defer { replaced.retireContent() }
        XCTAssertNil(replaced.imageAnnotations)
        XCTAssertNotNil(replaced.annotationError)
        XCTAssertFalse(replaced.canAnnotateImage)
    }

    func testReviewedSidecarConflictRequiresSameOriginalAndReviewedLayers() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("same.png")
        let original = try png()
        try original.write(to: path)
        let sidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path))
        let first = try await open(path)
        let second = try await open(path)
        defer { first.retireContent(); second.retireContent() }
        let a = try XCTUnwrap(first.imageAnnotations), b = try XCTUnwrap(second.imageAnnotations)
        add(.rectangle, to: a, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 90, y: 90))
        add(.ellipse, to: b, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 100, y: 100))
        await first.save()
        await second.save()
        XCTAssertTrue(second.canCompareSaveConflict)
        let disk = try Data(contentsOf: sidecar)
        let review = try await second.compareSaveConflict()
        XCTAssertEqual(review.diskVersion, WorkspaceFileVersion(data: disk))
        XCTAssertTrue(review.review.rows.contains { $0.kind == .added })
        XCTAssertTrue(review.review.rows.contains { $0.kind == .removed })
        XCTAssertEqual(try Data(contentsOf: sidecar), disk)
        add(.arrow, to: a, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 50, y: 50))
        await first.save()
        let newer = try Data(contentsOf: sidecar)
        do {
            try await second.resolveSaveConflict(review)
            XCTFail("Reviewed layers are stale")
        } catch WorkspaceError.changedExternally {}
        XCTAssertEqual(try Data(contentsOf: sidecar), newer)
        let next = try await second.compareSaveConflict()
        let replacement = try png(offset: 1)
        try replacement.write(to: path, options: .atomic)
        do {
            try await second.resolveSaveConflict(next)
            XCTFail("An annotation approval cannot apply to a different image")
        } catch WorkspaceError.changedExternally {}
        XCTAssertEqual(try Data(contentsOf: path), replacement)
        XCTAssertEqual(try Data(contentsOf: sidecar), newer)
        XCTAssertTrue(second.isDirty)
        try original.write(to: path, options: .atomic)
        let last = try await second.compareSaveConflict()
        try await second.resolveSaveConflict(last)
        XCTAssertFalse(second.isDirty)
        XCTAssertNil(second.saveError)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try ImageAnnotationSidecar.decode(Data(contentsOf: sidecar),
                                                         version: WorkspaceFileVersion(data: original),
                                                         size: b.size), b.state)
    }

    func testLateIndependentSidecarPublicationRetainsDisplacedLayersAndDraft() async throws {
        for replacing in [false, true] {
            let root = try makeRoot()
            let path = root.appendingPathComponent("image 中文.png")
            let original = try png()
            try original.write(to: path)
            let sidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path))
            let rival = root.appendingPathComponent("rival.json")
            let seed = try await open(path)
            defer { seed.retireContent() }
            let initial = try XCTUnwrap(seed.imageAnnotations)
            add(.arrow, to: initial, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 35, y: 35))
            await seed.save()
            XCTAssertFalse(seed.isDirty)
            let baseline = try Data(contentsOf: sidecar)
            let other = ImageAnnotationDocument(size: initial.size, state: initial.state)
            add(.ellipse, to: other, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 50, y: 50))
            let version = WorkspaceFileVersion(data: original)
            let external = try await ImageAnnotationSidecar.encode(other.state, version: version, size: other.size)
            try external.write(to: rival)
            let backend = LocalWorkspaceBackend(beforeConditionalPublication: {
                try publishIndependentFile(rival, to: $0, replacing: replacing)
            })
            let file = try await open(path, backend: backend)
            defer { file.retireContent() }
            let doc = try XCTUnwrap(file.imageAnnotations)
            add(.rectangle, to: doc, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60))
            let draft = doc.state
            await file.save()
            XCTAssertFalse(FileManager.default.fileExists(atPath: rival.path), "Independent publication must have run")
            XCTAssertTrue(file.isDirty)
            XCTAssertEqual(doc.state, draft)
            XCTAssertNotNil(file.saveError)
            let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let recovery = entries.filter { $0.lastPathComponent.hasPrefix("Bailey Save Recovery ") }
            XCTAssertEqual(recovery.count, 1)
            guard let directory = recovery.first else { continue }
            let stored = directory.appendingPathComponent(sidecar.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: stored), external)
            XCTAssertTrue(file.saveError?.contains(stored.path) == true,
                          "Expected recovery at \(stored.path), got \(file.saveError ?? "nil")")
            let written = try Data(contentsOf: sidecar)
            XCTAssertEqual(try ImageAnnotationSidecar.decode(written, version: version, size: doc.size), draft)
            XCTAssertEqual(try Data(contentsOf: path), original)
            await file.save()
            XCTAssertTrue(file.isDirty)
            XCTAssertTrue(file.saveError?.contains(stored.path) == true, "A retry must retain the exact recovery location")
            XCTAssertEqual(try Data(contentsOf: sidecar), written)
            XCTAssertEqual(try Data(contentsOf: stored), external)
            try baseline.write(to: sidecar, options: .atomic)
            await file.save()
            XCTAssertFalse(file.isDirty)
            XCTAssertNil(file.saveError)
            XCTAssertEqual(try Data(contentsOf: sidecar), written)
            XCTAssertEqual(try Data(contentsOf: stored), external)
            XCTAssertEqual(try Data(contentsOf: path), original)
        }
    }

    func testExistingSidecarHasOnlyOneSuccessfulConcurrentPublisher() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("concurrent.png")
        let original = try png()
        try original.write(to: path)
        let sidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path))
        let seed = try await open(path)
        defer { seed.retireContent() }
        let doc = try XCTUnwrap(seed.imageAnnotations)
        add(.arrow, to: doc, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 35, y: 35))
        await seed.save()
        XCTAssertFalse(seed.isDirty)
        for attempt in 0..<12 {
            let a = try await open(path), b = try await open(path)
            let da = try XCTUnwrap(a.imageAnnotations), db = try XCTUnwrap(b.imageAnnotations)
            add(.rectangle, to: da, from: CGPoint(x: 10 + attempt, y: 15), to: CGPoint(x: 40, y: 50))
            add(.ellipse, to: db, from: CGPoint(x: 25, y: 25 + attempt), to: CGPoint(x: 70, y: 75))
            async let left: Void = a.save()
            async let right: Void = b.save()
            _ = await (left, right)
            XCTAssertNotEqual(a.isDirty, b.isDirty)
            let winner = a.isDirty ? db : da
            let loser = a.isDirty ? a : b
            XCTAssertNotNil(loser.saveError)
            XCTAssertEqual(try ImageAnnotationSidecar.decode(Data(contentsOf: sidecar),
                version: WorkspaceFileVersion(data: original), size: winner.size), winner.state)
            XCTAssertEqual(try Data(contentsOf: path), original)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                           [path.lastPathComponent, sidecar.lastPathComponent])
            a.retireContent()
            b.retireContent()
        }
    }

    func testAuthorizedWindowsReviewedSidecarRejectsStaleLayersAndReplacedOriginal() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Requires the authorized isolated Windows SSH host")
        }
        let id = UUID().uuidString.prefix(8)
        let socket = "/tmp/bailey-image-review-a-\(id).sock"
        let rivalSocket = "/tmp/bailey-image-review-b-\(id).sock"
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket), timeout: 25)
        let rival = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: rivalSocket), timeout: 25)
        try await withPublicationSSHFixture(host: host, backend: rival, sockets: [socket, rivalSocket],
                                            prefix: "bailey-review-image") { root in
            let path = root + "/标注.png"
            let sidecar = ImageAnnotationSidecar.path(for: path)
            let original = try png()
            let replacement = try png(offset: 1)
            let version = WorkspaceFileVersion(data: original)
            try await rival.write(path: path, data: original)
            let remoteStat = try await backend.stat(path: path)
            XCTAssertEqual(remoteStat?.size, original.count)
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: root) }
            let sentinel = Data("Mac-only sidecar".utf8)
            try replacement.write(to: URL(fileURLWithPath: path))
            try sentinel.write(to: URL(fileURLWithPath: sidecar))
            let first = FileTab(path: path, backend: rival, workspaceIdentity: "ssh:\(host)")
            let second = FileTab(path: path, backend: backend, workspaceIdentity: "ssh:\(host)")
            defer { first.retireContent(); second.retireContent() }
            first.loadIfNeeded()
            second.loadIfNeeded()
            // Loading spans several separately bounded SSH commands. Wait for
            // their actual terminal state rather than a local-image deadline.
            try await waitFor("Both remote image documents finished loading", timeout: .seconds(125)) {
                if case .loading = first.content { return false }
                if case .loading = second.content { return false }
                return true
            }
            let a = try XCTUnwrap(first.imageAnnotations, first.annotationError ?? "First remote image unavailable")
            let b = try XCTUnwrap(second.imageAnnotations, second.annotationError ?? "Second remote image unavailable")
            add(.arrow, to: a, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 60, y: 60))
            add(.ellipse, to: b, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 100, y: 100))
            XCTAssertTrue(first.isDirty, "First draft must actually contain an annotation")
            XCTAssertTrue(second.isDirty, "Second draft must actually contain an annotation")
            XCTAssertNil(a.sidecarVersion)
            XCTAssertNil(b.sidecarVersion)
            let aBytes = try await ImageAnnotationSidecar.encode(a.state, version: version, size: a.size)
            let bBytes = try await ImageAnnotationSidecar.encode(b.state, version: version, size: b.size)
            await first.save()
            XCTAssertFalse(first.isDirty)
            XCTAssertNil(first.saveError)
            let initial = try await rival.read(path: sidecar, maxBytes: aBytes.count)
            XCTAssertEqual(initial, aBytes)
            await second.save()
            XCTAssertTrue(second.isDirty)
            XCTAssertTrue(second.canCompareSaveConflict)
            let firstReview = try await second.compareSaveConflict()
            XCTAssertEqual(firstReview.diskVersion, WorkspaceFileVersion(data: aBytes))
            XCTAssertEqual(firstReview.draftVersion, WorkspaceFileVersion(data: bBytes))
            XCTAssertTrue(firstReview.review.rows.contains { $0.kind == .added })
            XCTAssertTrue(firstReview.review.rows.contains { $0.kind == .removed })
            let unchanged = try await rival.read(path: sidecar, maxBytes: aBytes.count)
            XCTAssertEqual(unchanged, aBytes)
            print("REVIEW_IMAGE_LIVE first creation conflict and read-only comparison verified")
            add(.rectangle, to: a, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
            await first.save()
            XCTAssertFalse(first.isDirty)
            let newer = try await rival.read(path: sidecar, maxBytes: ImageAnnotationSidecar.maximumBytes)
            do {
                try await second.resolveSaveConflict(firstReview)
                XCTFail("Stale layer approval must be refused")
            } catch WorkspaceError.changedExternally {}
            let retained = try await rival.read(path: sidecar, maxBytes: newer.count)
            XCTAssertEqual(retained, newer)
            print("REVIEW_IMAGE_LIVE stale layer confirmation rejected")
            let secondReview = try await second.compareSaveConflict()
            try await rival.write(path: path, data: replacement)
            do {
                try await second.resolveSaveConflict(secondReview)
                XCTFail("The reviewed sidecar cannot overwrite after the original changes")
            } catch WorkspaceError.changedExternally {}
            let protected = try await rival.read(path: sidecar, maxBytes: newer.count)
            XCTAssertEqual(protected, newer)
            XCTAssertTrue(second.isDirty)
            print("REVIEW_IMAGE_LIVE replaced original rejected")
            try await rival.write(path: path, data: original)
            let fresh = try await second.compareSaveConflict()
            try await second.resolveSaveConflict(fresh)
            XCTAssertFalse(second.isDirty)
            XCTAssertNil(second.saveError)
            let saved = try await rival.read(path: sidecar, maxBytes: bBytes.count)
            XCTAssertEqual(saved, bBytes)
            let source = try await rival.read(path: path, maxBytes: original.count)
            XCTAssertEqual(source, original)
            let reopened = FileTab(path: path, backend: rival, workspaceIdentity: "ssh:\(host)")
            defer { reopened.retireContent() }
            reopened.loadIfNeeded()
            try await waitFor("Remote sidecar finished reopening", timeout: .seconds(125)) {
                if case .loading = reopened.content { return false }
                return true
            }
            XCTAssertEqual(reopened.imageAnnotations?.state, b.state)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), replacement)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sidecar)), sentinel)
            let remaining = try await rival.list(directory: root)
            XCTAssertEqual(Set(remaining.map(\.name)), ["标注.png", "标注.png" + ImageAnnotationSidecar.suffix])
        }
    }

    func testAuthorizedWindowsSidecarPersistsOnlyOnRemoteMachineAndRejectsCompetingWrites() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Requires the authorized isolated Windows SSH host")
        }
        let socket = "/tmp/bailey-annotation-" + UUID().uuidString.prefix(8) + ".sock"
        let runner = PublicationAcknowledgementRunner(host: host, socket: socket)
        let backend = SSHWorkspaceBackend(runner: runner, timeout: 25)
        try await withPublicationSSHFixture(host: host, backend: backend, sockets: [socket],
                                            prefix: "bailey-annotation") { root in
            let name = "图像.png"
            let path = root + "/" + name
            let target = ImageAnnotationSidecar.path(for: path)
            let original = try png()
            let version = WorkspaceFileVersion(data: original)
            let size = CGSize(width: 160, height: 120)
            try await backend.write(path: path, data: original)
            // A same-path Mac fixture is intentionally different; neither
            // remote source reads nor sidecar publication may consult it.
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(atPath: root) }
            let local = try png(offset: 1)
            try local.write(to: URL(fileURLWithPath: path))
            let sentinel = Data("Local sentinel".utf8)
            try sentinel.write(to: URL(fileURLWithPath: target))

            let first = ImageAnnotationDocument(size: size)
            let second = ImageAnnotationDocument(size: size)
            add(.arrow, to: first, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 60, y: 60))
            add(.ellipse, to: second, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 100, y: 100))
            let a = try await ImageAnnotationSidecar.encode(first.state, version: version, size: size)
            let b = try await ImageAnnotationSidecar.encode(second.state, version: version, size: size)
            func compete(_ data: Data, previous: WorkspaceFileVersion?) async -> Bool {
                do {
                    try await ImageAnnotationSidecar.publish(data, image: path, backend: backend,
                        version: version, previous: previous)
                    return true
                } catch { return false }
            }
            async let createA = compete(a, previous: nil)
            async let createB = compete(b, previous: nil)
            let createdPair = await (createA, createB)
            XCTAssertNotEqual(createdPair.0, createdPair.1)
            let saved = try await backend.read(path: target, maxBytes: ImageAnnotationSidecar.maximumBytes)
            XCTAssertEqual(saved, createdPair.0 ? a : b)
            let previous = WorkspaceFileVersion(data: saved)
            // Different content from the shared baseline is essential to the
            // actual check-and-publish race, even when one wins immediately.
            add(.number, to: first, from: CGPoint(x: 25, y: 25), to: CGPoint(x: 25, y: 25))
            add(.rectangle, to: second, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 30))
            let c = try await ImageAnnotationSidecar.encode(first.state, version: version, size: size)
            let d = try await ImageAnnotationSidecar.encode(second.state, version: version, size: size)
            async let replaceA = compete(c, previous: previous)
            async let replaceB = compete(d, previous: previous)
            let replacedPair = await (replaceA, replaceB)
            XCTAssertNotEqual(replacedPair.0, replacedPair.1)
            let result = try await backend.read(path: target, maxBytes: ImageAnnotationSidecar.maximumBytes)
            XCTAssertEqual(result, replacedPair.0 ? c : d)
            let restored = await ImageAnnotationSidecar.load(image: path, backend: backend, version: version, size: size)
            guard case .existing(let state, _) = restored else { throw WorkspaceError.notFound }
            XCTAssertEqual(state, replacedPair.0 ? first.state : second.state)
            // A lost reply is not a rejected publication. Prove both the
            // initial create and a later update against the real remote bytes.
            let recoveryName = "acknowledgement.png"
            let recoveryPath = root + "/" + recoveryName
            let recoveryTarget = ImageAnnotationSidecar.path(for: recoveryPath)
            try await backend.write(path: recoveryPath, data: original)
            await runner.loseNextAcknowledgement()
            try await ImageAnnotationSidecar.publish(a, image: recoveryPath, backend: backend,
                                                    version: version, previous: nil)
            let createdBytes = try await backend.read(path: recoveryTarget, maxBytes: a.count)
            XCTAssertEqual(createdBytes, a)
            do {
                try await ImageAnnotationSidecar.publish(a, image: recoveryPath, backend: backend,
                                                        version: version, previous: nil)
                XCTFail("A definite already-exists response must remain a rejection, even for identical bytes")
            } catch let error as CocoaError where error.code == .fileWriteFileExists {}
            await runner.loseNextAcknowledgement()
            try await ImageAnnotationSidecar.publish(b, image: recoveryPath, backend: backend,
                                                    version: version, previous: WorkspaceFileVersion(data: a))
            let updatedBytes = try await backend.read(path: recoveryTarget, maxBytes: b.count)
            XCTAssertEqual(updatedBytes, b)
            do {
                try await ImageAnnotationSidecar.publish(b, image: recoveryPath, backend: backend,
                                                        version: version, previous: WorkspaceFileVersion(data: a))
                XCTFail("A definite changed-version response must remain a rejection")
            } catch WorkspaceError.changedExternally {}
            let recoverySource = try await backend.read(path: recoveryPath, maxBytes: original.count)
            XCTAssertEqual(recoverySource, original)
            let remaining = try await backend.list(directory: root)
            XCTAssertEqual(Set(remaining.map(\.name)), [name, name + ImageAnnotationSidecar.suffix,
                recoveryName, recoveryName + ImageAnnotationSidecar.suffix])
            let remoteSource = try await backend.read(path: path, maxBytes: original.count)
            XCTAssertEqual(remoteSource, original)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), local)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), sentinel)
            // Exercise the real remote Files operations, not a mock backend.
            let destination = root + "/paired-copy"
            try await backend.createDirectory(path: destination)
            let tree = FileTreeModel()
            await tree.sync(root: root, backend: backend, scope: "ssh:" + host)
            let copy = await tree.performFileOperation(.copy, paths: [path, target], into: destination)
            XCTAssertTrue(copy.failures.isEmpty, copy.failures.joined(separator: "\n"))
            let copiedImage = destination + "/" + name
            let copiedSidecar = ImageAnnotationSidecar.path(for: copiedImage)
            XCTAssertEqual(Set(copy.succeeded.compactMap(\.destination)), [copiedImage, copiedSidecar])
            let copiedBytes = try await backend.read(path: copiedImage, maxBytes: original.count)
            let copiedAnnotation = try await backend.read(path: copiedSidecar, maxBytes: result.count)
            XCTAssertEqual(copiedBytes, original)
            XCTAssertEqual(copiedAnnotation, result)
            let item = try XCTUnwrap(tree.items.first { $0.path == path })
            let newName = "重命名.png"
            let renamed = await tree.rename(item, to: newName)
            let newPath = root + "/" + newName
            XCTAssertEqual(renamed, newPath)
            let moved = await tree.performFileOperation(.move, paths: [newPath], into: destination)
            XCTAssertTrue(moved.failures.isEmpty, moved.failures.joined(separator: "\n"))
            let newDestination = destination + "/" + newName
            let newAnnotation = ImageAnnotationSidecar.path(for: newDestination)
            let movedImage = try await backend.read(path: newDestination, maxBytes: original.count)
            let movedAnnotation = try await backend.read(path: newAnnotation, maxBytes: result.count)
            XCTAssertEqual(movedImage, original)
            XCTAssertEqual(movedAnnotation, result)
            let deleted = await tree.performFileOperation(.delete, paths: [newDestination, newAnnotation], into: nil)
            XCTAssertTrue(deleted.failures.isEmpty, deleted.failures.joined(separator: "\n"))
            let after = try await backend.list(directory: destination)
            XCTAssertEqual(Set(after.map(\.name)), [name, name + ImageAnnotationSidecar.suffix])
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), local)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), sentinel)
        }
    }

    func testInvalidSidecarsAndDanglingLinksCannotBecomeWritableDocuments() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("image.png")
        let original = try png()
        try original.write(to: path)
        let version = WorkspaceFileVersion(data: original)
        let sidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path))
        let badLayer = ImageAnnotationLayer(kind: .arrow, start: CGPoint(x: -1, y: 0),
            end: CGPoint(x: 1, y: 1), color: .red, strokeWidth: 2)
        let oversized = Array(repeating: badLayer, count: ImageAnnotationState.maximumLayers + 1)
        let legacy = """
            {"schema":1,"sourceSHA256":"\(version.sha256)","sourceBytes":\(version.byteCount),
             "pixelSize":[160,120],"annotations":{"layers":[
              {"id":"B3226ED0-4111-4D04-9491-183ABBD129D8","kind":"rectangle","start":[10,10],
               "end":[20,20],"color":"blue","strokeWidth":2,"text":""}]}}
            """
        let invalid = [
            Data(legacy.utf8),
            Data(legacy.replacingOccurrences(of: #""text":""}"#, with: #""text":"","via":null}"#).utf8),
            Data(),
            Data("not JSON".utf8),
            try JSONEncoder().encode(ImageAnnotationSidecar.Record(schema: 99, sourceSHA256: version.sha256,
                sourceBytes: version.byteCount, pixelSize: CGSize(width: 160, height: 120), annotations: .init())),
            try JSONEncoder().encode(ImageAnnotationSidecar.Record(schema: 1, sourceSHA256: version.sha256,
                sourceBytes: version.byteCount, pixelSize: CGSize(width: 160, height: 120),
                annotations: .init(layers: [badLayer]))),
            try JSONEncoder().encode(ImageAnnotationSidecar.Record(schema: 1, sourceSHA256: version.sha256,
                sourceBytes: version.byteCount, pixelSize: CGSize(width: 160, height: 120),
                annotations: .init(layers: oversized))),
        ]
        for data in invalid {
            try data.write(to: sidecar)
            let file = try await open(path)
            XCTAssertNil(file.imageAnnotations)
            XCTAssertNotNil(file.annotationError)
            await file.save()
            XCTAssertEqual(try Data(contentsOf: sidecar), data)
            file.retireContent()
        }
        try FileManager.default.removeItem(at: sidecar)
        let missing = root.appendingPathComponent("missing.json")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: missing)
        let file = try await open(path)
        defer { file.retireContent() }
        XCTAssertNil(file.imageAnnotations)
        XCTAssertNotNil(file.annotationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testLocalTransferCarriesValidatedPairWithoutOverwritingOrMovingSidecarAlone() async throws {
        let root = try makeRoot()
        let folder = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("target")
        for url in [folder, destination] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let path = folder.appendingPathComponent("image.png")
        let original = try png()
        try original.write(to: path)
        let file = try await open(path)
        defer { file.retireContent() }
        let document = try XCTUnwrap(file.imageAnnotations)
        add(.arrow, to: document, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 50, y: 50))
        await file.save()
        XCTAssertFalse(file.isDirty)
        let sidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path))
        let annotations = try Data(contentsOf: sidecar)
        let output = destination.appendingPathComponent(path.lastPathComponent)
        let outputSidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: output.path))
        let backend = LocalWorkspaceBackend.shared
        for move in [false, true] {
            do {
                _ = try await backend.transferLocalFile(from: sidecar.path, into: destination.path, move: move)
                XCTFail("Selecting only the sidecar must not separate it from its image")
            } catch {}
        }
        try Data("unrelated".utf8).write(to: outputSidecar)
        do {
            _ = try await backend.transferLocalFile(from: path.path, into: destination.path, move: true)
            XCTFail("A destination sidecar collision must stop the entire move")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: outputSidecar), Data("unrelated".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try Data(contentsOf: sidecar), annotations)
        try FileManager.default.removeItem(at: outputSidecar)
        _ = try await backend.transferLocalFile(from: path.path, into: destination.path, move: false)
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(try Data(contentsOf: outputSidecar), annotations)
        XCTAssertEqual(try Data(contentsOf: sidecar), annotations)
        let copied = try await open(output)
        XCTAssertEqual(copied.imageAnnotations?.state, document.state)
        copied.retireContent()
        try FileManager.default.removeItem(at: output)
        try FileManager.default.removeItem(at: outputSidecar)
        _ = try await backend.transferLocalFile(from: path.path, into: destination.path, move: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(try Data(contentsOf: outputSidecar), annotations)
        let restored = try await open(output)
        defer { restored.retireContent() }
        XCTAssertEqual(restored.imageAnnotations?.state, document.state)
    }

    func testChineseEmojiAnnotationReopensEditsAndRendersRealGlyphs() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("text.png")
        let original = try png(width: 600, height: 400)
        try original.write(to: path)
        let file = try await open(path)
        defer { file.retireContent() }
        let document = try XCTUnwrap(file.imageAnnotations)
        let point = CGPoint(x: 350, y: 300)
        add(.text, to: document, from: point, to: point)
        document.textEdit?.text = "标注🙂"
        document.commitText()
        let first = try XCTUnwrap(document.state.layers.first)
        XCTAssertEqual(first.text, "标注🙂")
        await file.save()
        XCTAssertFalse(file.isDirty)
        let other = try await open(path)
        defer { other.retireContent() }
        let reopened = try XCTUnwrap(other.imageAnnotations)
        XCTAssertEqual(reopened.state.layers, [first])
        let options = ImageAnnotationDrawing.Options(width: 600, height: 400)
        let before = try await other.annotatedImageData(request: other.fileContentRevision, options: options)
        let bitmap = NSBitmapImageRep(cgImage: try image(before))
        let rect = first.bounds.integral
        var paintedPixels = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: 399 - y))
                if color.alphaComponent > 0.25 { paintedPixels += 1 }
            }
        }
        XCTAssertGreaterThan(paintedPixels, 30, "The transparent right half must contain rendered text pixels")
        reopened.begin()
        reopened.editSelectedText(at: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(reopened.textEdit?.id, first.id)
        reopened.textEdit?.text = "修改🙂：第二行\n新文本"
        reopened.commitText()
        let edited = try XCTUnwrap(reopened.state.layers.first)
        XCTAssertEqual(edited.id, first.id)
        XCTAssertEqual(edited.text, "修改🙂：第二行\n新文本")
        let after = try await other.annotatedImageData(request: other.fileContentRevision, options: options)
        XCTAssertNotEqual(after, before)
        reopened.undoManager.undo()
        XCTAssertEqual(reopened.state.layers, [first])
        XCTAssertFalse(other.isDirty)
        reopened.undoManager.redo()
        XCTAssertTrue(other.isDirty)
        await other.save()
        XCTAssertFalse(other.isDirty)
        let persisted = try Data(contentsOf: URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path)))
        XCTAssertEqual(try ImageAnnotationSidecar.decode(persisted, version: WorkspaceFileVersion(data: original),
                                                        size: reopened.size).layers, [edited])
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testSpaceExhaustionPreservesDraftsAndExistingExportsAndAllowsRetry() async throws {
        guard let path = ProcessInfo.processInfo.environment["BAILEY_WRITE_FAILURE_ROOT"] else {
            throw XCTSkip("Set BAILEY_WRITE_FAILURE_ROOT to a disposable, bounded test volume")
        }
        let volume = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let capacity = try XCTUnwrap(volume.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity)
        XCTAssertLessThanOrEqual(capacity, 512 * 1_048_576)
        guard capacity <= 512 * 1_048_576,
              try volume.resourceValues(forKeys: [.volumeURLKey]).volume?.resolvingSymlinksInPath().path == volume.resolvingSymlinksInPath().path
        else { return XCTFail("Use a dedicated small mounted test volume, not a folder on the system disk") }
        let root = try makeRoot(on: volume)
        let source = root.appending(path: "source.png")
        let original = try png()
        try original.write(to: source)
        let annotation = try await open(source)
        defer { annotation.retireContent() }
        let document = try XCTUnwrap(annotation.imageAnnotations)
        XCTAssertTrue(annotation.canAnnotateImage)
        add(.rectangle, to: document, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 30, y: 30))
        XCTAssertTrue(annotation.isDirty)
        await annotation.save()
        XCTAssertNil(annotation.saveError)
        XCTAssertFalse(annotation.isDirty)
        let sidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: source.path))
        let savedSidecar = try Data(contentsOf: sidecar)
        add(.arrow, to: document, from: CGPoint(x: 35, y: 30), to: CGPoint(x: 85, y: 90))
        let draft = document.state
        let replacement = root.appending(path: "existing.png")
        let previous = try png(offset: 1)
        try previous.write(to: replacement)
        let options = ImageAnnotationDrawing.Options(width: 160, height: 120)
        let target = try await annotation.prepareAnnotationExport(request: annotation.fileContentRevision,
                                                                  options: options, to: replacement)
        let newImage = root.appending(path: "new.png")
        let newSVG = root.appending(path: "vector.png")
        let svg = root.appending(path: "drawing.svg")
        let oldSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\" fill=\"red\"/></svg>"
        try Data(oldSVG.utf8).write(to: svg)
        let vector = FileTab(path: svg.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        defer { vector.retireContent() }
        try await vector.waitForText()
        vector.autoSaveSuspendedForClose = true
        vector.text = oldSVG.replacingOccurrences(of: "red", with: "blue")
        await vector.showSVGPreview(request: vector.textPreviewRequestID)
        let csv = root.appending(path: "table.csv")
        let html = root.appending(path: "page.html")
        let txt = root.appending(path: "plain.txt")
        let textInputs = [(csv, "Name,Value\r\nA,old\r\n"), (html, "<h1>old</h1>\n"), (txt, "old\n")]
        var tabs: [(FileTab, URL, Data, String)] = []
        defer { for (file, _, _, _) in tabs { file.retireContent() } }
        for (url, originalText) in textInputs {
            let bytes = Data(originalText.utf8)
            try bytes.write(to: url)
            let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await file.waitForText()
            file.autoSaveSuspendedForClose = true
            let text = originalText.replacingOccurrences(of: "old", with: "new 中文")
            file.text = text
            tabs.append((file, url, bytes, text))
        }

        func outOfSpace(_ error: Error) -> Bool {
            let e = error as NSError
            if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) { return true }
            if e.domain == NSCocoaErrorDomain && e.code == CocoaError.Code.fileWriteOutOfSpace.rawValue { return true }
            if let underlying = e.userInfo[NSUnderlyingErrorKey] as? Error { return outOfSpace(underlying) }
            return false
        }
        let filler = root.appending(path: "space-reservation")
        XCTAssertTrue(FileManager.default.createFile(atPath: filler.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: filler) }
        let handle = try FileHandle(forWritingTo: filler)
        defer { try? handle.close() }
        // Only the disposable volume can be exhausted; cap writes by its actual size.
        func fill(_ count: Int, limit: Int) throws {
            let bytes = Data(repeating: 0xA7, count: count)
            for _ in 0..<limit {
                do { try handle.write(contentsOf: bytes) }
                catch {
                    guard outOfSpace(error) else { throw error }
                    return
                }
            }
            XCTFail("The bounded test volume did not report ENOSPC")
        }
        try fill(1_048_576, limit: capacity / 1_048_576 + 1)
        try fill(4096, limit: 512)
        try? handle.synchronize()
        try handle.close()

        let namesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        do {
            try await LocalWorkspaceBackend.shared.writeNewFile(path: newSVG.path, data: Data(repeating: 0xA8, count: 1_048_576))
            XCTFail("The real publication must fail with exhausted space")
        } catch { XCTAssertTrue(outOfSpace(error), "\(error)") }
        for (file, url, bytes, text) in tabs {
            await file.save()
            XCTAssertNotNil(file.saveError, url.lastPathComponent)
            XCTAssertTrue(file.isDirty)
            XCTAssertEqual(file.text, text)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        await vector.save()
        await annotation.save()
        XCTAssertTrue(vector.isDirty)
        XCTAssertNotNil(vector.saveError)
        XCTAssertTrue(annotation.isDirty)
        XCTAssertNotNil(annotation.saveError)
        for (url, confirmed) in [(newImage, false), (replacement, true)] {
            do {
                try await annotation.exportAnnotatedImage(request: annotation.fileContentRevision, options: options,
                    to: url, confirmedTarget: confirmed ? target : nil)
                XCTFail("Export must not publish on the exhausted volume")
            } catch { XCTAssertTrue(outOfSpace(error), "\(error)") }
        }
        do {
            try await vector.exportSVGPNG(request: vector.textPreviewRequestID, options: .init(width: 32, height: 32), to: newSVG)
            XCTFail("SVG export must fail without leaving a target")
        } catch { XCTAssertTrue(outOfSpace(error), "\(error)") }
        XCTAssertEqual(try Data(contentsOf: svg), Data(oldSVG.utf8))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: sidecar), savedSidecar)
        XCTAssertEqual(try Data(contentsOf: replacement), previous)
        XCTAssertEqual(document.state, draft)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), namesBefore)
        try FileManager.default.removeItem(at: filler)
        for (file, url, _, text) in tabs {
            await file.save()
            XCTAssertNil(file.saveError)
            XCTAssertFalse(file.isDirty)
            XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))
        }
        await annotation.save()
        await vector.save()
        XCTAssertFalse(annotation.isDirty)
        XCTAssertFalse(vector.isDirty)
        XCTAssertNil(annotation.saveError)
        XCTAssertNil(vector.saveError)
        XCTAssertEqual(try Data(contentsOf: svg), Data(vector.text.utf8))
        XCTAssertEqual(try ImageAnnotationSidecar.decode(Data(contentsOf: sidecar),
            version: WorkspaceFileVersion(data: original), size: document.size), draft)
        try await annotation.exportAnnotatedImage(request: annotation.fileContentRevision, options: options, to: newImage)
        try await vector.exportSVGPNG(request: vector.textPreviewRequestID, options: .init(width: 32, height: 32), to: newSVG)
        XCTAssertEqual(try image(Data(contentsOf: newImage)).width, 160)
        XCTAssertEqual(try image(Data(contentsOf: newSVG)).width, 32)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: replacement), previous)
        let retryTarget = try await annotation.prepareAnnotationExport(request: annotation.fileContentRevision,
                                                                      options: options, to: replacement)
        try await annotation.exportAnnotatedImage(request: annotation.fileContentRevision, options: options,
                                                   to: replacement, confirmedTarget: retryTarget)
        XCTAssertEqual(try Data(contentsOf: replacement), try Data(contentsOf: newImage))
        print("WRITE_SPACE: real ENOSPC, four text formats, annotation sidecar, new/replacement exports, cleanup and retry passed")
    }

    func testReadOnlyDirectoryAndCancelledExportPreserveDraftAndLeaveNoTargets() async throws {
        let root = try makeRoot()
        let directory = root.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let path = directory.appendingPathComponent("image.png")
        let original = try png()
        try original.write(to: path)
        let file = try await open(path)
        defer { file.retireContent() }
        let document = try XCTUnwrap(file.imageAnnotations)
        add(.blur, to: document, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 60, y: 60))
        let draft = document.state
        let options = ImageAnnotationDrawing.Options(width: 160, height: 120)
        let target = directory.appendingPathComponent("export.png")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: directory.path))
        await file.save()
        XCTAssertTrue(file.isDirty)
        XCTAssertNotNil(file.saveError)
        do {
            try await file.exportAnnotatedImage(request: file.fileContentRevision, options: options, to: target)
            XCTFail("Read-only directory must not permit a new export")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["image.png"])
        XCTAssertEqual(document.state, draft)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let cancelled = Task {
            try await file.exportAnnotatedImage(request: file.fileContentRevision, options: options, to: target)
        }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled export must not publish") }
        catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["image.png"])
        XCTAssertEqual(document.state, draft)
        XCTAssertTrue(file.isDirty)
        await file.save()
        XCTAssertFalse(file.isDirty)
        XCTAssertNil(file.saveError)
        let stored = try Data(contentsOf: URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path)))
        try await file.exportAnnotatedImage(request: file.fileContentRevision, options: options, to: target)
        XCTAssertEqual(try image(Data(contentsOf: target)).width, 160)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path))), stored)
    }

    func testAllEXIFOrientationsSurviveAnnotationSaveAndPixelExport() async throws {
        let root = try makeRoot()
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for (index, color) in [NSColor.white, .green, .blue, .yellow].enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: (index % 2) * 60, y: (1 - index / 2) * 40, width: 60, height: 40))
        }
        let source = try XCTUnwrap(context.makeImage())
        for orientation in 1...8 {
            let data = NSMutableData()
            let writer = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(writer, source, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(writer))
            let original = data as Data
            let path = root.appendingPathComponent("orientation-\(orientation).jpg")
            try original.write(to: path)
            let file = try await open(path)
            defer { file.retireContent() }
            guard case .image(let preview) = file.content else { return XCTFail("Expected original raster") }
            let document = try XCTUnwrap(file.imageAnnotations)
            let width = orientation >= 5 ? 80 : 120
            let height = orientation >= 5 ? 120 : 80
            XCTAssertEqual(document.size, CGSize(width: width, height: height))
            add(.rectangle, to: document, from: CGPoint(x: 8, y: 8), to: CGPoint(x: 34, y: 34))
            let expected = document.state
            await file.save()
            XCTAssertFalse(file.isDirty)
            let restored = try await open(path)
            defer { restored.retireContent() }
            XCTAssertEqual(restored.imageAnnotations?.state, expected)
            let options = ImageAnnotationDrawing.Options(width: width, height: height)
            let output = root.appendingPathComponent("export-\(orientation).png")
            try await restored.exportAnnotatedImage(request: restored.fileContentRevision, options: options, to: output)
            let rendered = try image(Data(contentsOf: output))
            XCTAssertEqual(rendered.width, width)
            XCTAssertEqual(rendered.height, height)
            let stroke = try pixel(rendered, x: 8, y: 20)
            XCTAssertGreaterThan(stroke.redComponent - stroke.greenComponent, 0.4, "EXIF \(orientation) stroke")
            for (x, y) in [(width - 15, 15), (15, height - 15), (width - 15, height - 15)] {
                let actual = try pixel(rendered, x: x, y: y)
                let expected = try pixel(preview.poster, x: x, y: y)
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.06, "EXIF \(orientation)")
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.06)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.06)
            }
            XCTAssertEqual(try Data(contentsOf: path), original)
        }
    }

    private func mountedClipboardTestVolume() throws -> URL {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let marker = project.appendingPathComponent(".build/.file-clipboard-test-volume")
        guard let mount = try? String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              (mount.hasPrefix("/private/tmp/bailey-clipboard-vol.") ||
                  mount.hasPrefix("/tmp/bailey-clipboard-vol.")),
              mount.hasSuffix("/mounted") else {
            throw XCTSkip("Requires an isolated mounted test volume; never a user volume")
        }
        return URL(fileURLWithPath: mount)
    }

    func testActualFilesTreeRenamesAndDeletesValidatedImagePair() async throws {
        let root = try makeRoot(on: mountedClipboardTestVolume())
        let folder = root.appendingPathComponent("paired")
        let target = root.appendingPathComponent("target")
        for directory in [folder, target] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let path = folder.appendingPathComponent("image.png")
        let original = try png()
        try original.write(to: path)
        let file = try await open(path)
        defer { file.retireContent() }
        let document = try XCTUnwrap(file.imageAnnotations)
        add(.arrow, to: document, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 50, y: 50))
        await file.save()
        XCTAssertFalse(file.isDirty)
        let sidecar = ImageAnnotationSidecar.path(for: path.path)
        let stored = try Data(contentsOf: URL(fileURLWithPath: sidecar))
        let tree = FileTreeModel()
        await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        let row = try XCTUnwrap(tree.items.first { $0.path == folder.path })
        await tree.toggle(row)
        for half in [sidecar] {
            let item = try XCTUnwrap(tree.items.first { $0.path == half })
            let rename = await tree.rename(item, to: "renamed-" + item.name)
            XCTAssertNil(rename)
            for operation in [FileTreeModel.FileOperation.copy, .move, .delete] {
                let result = await tree.performFileOperation(operation, paths: [half],
                    into: operation == .delete ? nil : target.path)
                XCTAssertTrue(result.succeeded.isEmpty)
                XCTAssertEqual(result.failures.count, 1)
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sidecar)), stored)
        let item = try XCTUnwrap(tree.items.first { $0.path == path.path })
        let renamed = await tree.rename(item, to: "renamed.png")
        let moved = folder.appendingPathComponent("renamed.png")
        XCTAssertEqual(renamed, moved.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar))
        let restored = try await open(moved)
        XCTAssertEqual(restored.imageAnnotations?.state, document.state)
        restored.retireContent()
        XCTAssertEqual(try Data(contentsOf: moved), original)
        let movedSidecar = ImageAnnotationSidecar.path(for: moved.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: movedSidecar)), stored)
        let localCopy = try makeRoot()
        XCTAssertNotEqual(LocalFileIdentity.read(root.path)?.device, LocalFileIdentity.read(localCopy.path)?.device)
        let transferred = await LocalWorkspaceBackend.shared.transferLocalFiles([moved], into: localCopy.path, move: true)
        XCTAssertTrue(transferred.failures.isEmpty, transferred.failures.joined(separator: "\n"))
        XCTAssertEqual(transferred.moved.count, 2)
        let copiedImage = localCopy.appendingPathComponent(moved.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: copiedImage), original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ImageAnnotationSidecar.path(for: copiedImage.path))), stored)
        // Restore another pair to the disposable volume for the real tree deletion.
        let copied = await LocalWorkspaceBackend.shared.transferLocalFiles([copiedImage], into: folder.path)
        XCTAssertEqual(copied.copied.count, 2, copied.failures.joined(separator: "\n"))
        // The pair was recreated by an independent file operation. Refresh the
        // actual tree before issuing a command against its current rows.
        let refreshed = await tree.sync(root: root.path, backend: LocalWorkspaceBackend.shared)
        XCTAssertTrue(refreshed)
        XCTAssertTrue(tree.items.contains { $0.path == moved.path })
        let revealed = await tree.revealFile(moved.path)
        XCTAssertTrue(revealed)
        let traversal = await tree.performFileOperation(.delete,
            paths: [folder.path + "/../paired/" + moved.lastPathComponent], into: nil)
        XCTAssertTrue(traversal.succeeded.isEmpty)
        XCTAssertEqual(traversal.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: moved), original)
        let deleted = await tree.performFileOperation(.delete, paths: [moved.path, movedSidecar], into: nil)
        XCTAssertTrue(deleted.failures.isEmpty, deleted.failures.joined(separator: "\n"))
        XCTAssertEqual(Set(deleted.succeeded.map(\.source)), [moved.path, movedSidecar])
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedSidecar))
    }

    func testNativeCloseVetoPreservesConflictedAnnotationDraft() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("close.png")
        let original = try png()
        try original.write(to: path)
        let file = try await open(path)
        let document = try XCTUnwrap(file.imageAnnotations)
        add(.rectangle, to: document, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        await file.save()
        let other = try await open(path)
        defer { other.retireContent() }
        let otherDocument = try XCTUnwrap(other.imageAnnotations)
        add(.arrow, to: otherDocument, from: CGPoint(x: 60, y: 10), to: CGPoint(x: 100, y: 40))
        await other.save()
        XCTAssertFalse(other.isDirty)
        add(.ellipse, to: document, from: CGPoint(x: 10, y: 60), to: CGPoint(x: 40, y: 90))
        let draft = document.state
        let sidecar = URL(fileURLWithPath: ImageAnnotationSidecar.path(for: path.path))
        let accepted = try Data(contentsOf: sidecar)
        let project = Project(customDirectory: "/fixture/annotation close", layout: .init())
        let tab = PaneTab(content: .file(file))
        project.append(tab)
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 720, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        project.onPresentationWindow = { window }
        defer { window.close(); file.retireContent() }
        project.close(tab)
        try await waitFor("Native annotation close sheet") { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await waitFor("Conflicted save vetoes the close") { !file.autoSaveSuspendedForClose && file.saveError != nil }
        XCTAssertTrue(project.tabs.contains { $0 === tab })
        XCTAssertTrue(file.isDirty)
        XCTAssertEqual(document.state, draft)
        XCTAssertEqual(try Data(contentsOf: sidecar), accepted)
        project.close(tab)
        try await waitFor("Native discard confirmation") { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        try await waitFor("Explicit discard closes annotation tab") { project.tabs.isEmpty }
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try Data(contentsOf: sidecar), accepted)
    }

    func testAnnotationKeysFollowOnlyTheNativeCanvasAndCommitTheDrawnPath() async throws {
        let original = try png(width: 400, height: 300)
        let path = try makeRoot().appendingPathComponent("keys.png")
        try original.write(to: path)
        let file = try await open(path)
        defer { file.retireContent() }
        let document = try XCTUnwrap(file.imageAnnotations)
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: FileViewerView(file: file))
        host.sizingOptions = []
        window.contentView = host
        window.orderBack(nil)
        func findCanvas(in view: NSView) -> PreviewScrollView? {
            if let scroll = view as? PreviewScrollView { return scroll }
            return view.subviews.lazy.compactMap(findCanvas).first
        }
        try await waitFor("Mount the standalone file viewer") {
            host.layoutSubtreeIfNeeded()
            return findCanvas(in: host)?.documentView?.bounds.size == document.size
        }
        let scroll = try XCTUnwrap(findCanvas(in: host))
        let canvas = try XCTUnwrap(scroll.documentView)
        func key(_ letter: String, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: letter, charactersIgnoringModifiers: letter, isARepeat: false, keyCode: 0))
            window.sendEvent(event)
        }
        func mouse(_ type: NSEvent.EventType, _ x: Int, _ y: Int) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: canvas.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        XCTAssertTrue(window.makeFirstResponder(scroll))
        try key("r")
        XCTAssertEqual(document.tool, .select, "Preview has no tool shortcuts")
        let annotate = try XCTUnwrap(scroll.accessibilityCustomActions()?.first {
            $0.name == String(localized: "Annotate Image", table: "Editor")
        })
        XCTAssertTrue(try XCTUnwrap(annotate.handler)())
        XCTAssertTrue(window.firstResponder === scroll)
        let tools: [(String, ImageAnnotationTool)] = [
            ("p", .pen), ("r", .rectangle), ("v", .select), ("a", .arrow), ("e", .ellipse),
            ("t", .text), ("n", .number), ("b", .blur), ("m", .pixelate), ("c", .crop)
        ]
        for (letter, tool) in tools {
            try key(letter)
            XCTAssertEqual(document.tool, tool)
        }
        for flags: NSEvent.ModifierFlags in [.shift, .control, .option] {
            try key("r", modifiers: flags)
            XCTAssertEqual(document.tool, .crop)
        }
        XCTAssertFalse(file.isDirty)
        try key("P", modifiers: .capsLock)
        try mouse(.leftMouseDown, 110, 90)
        try mouse(.leftMouseDragged, 135, 140)
        try mouse(.leftMouseUp, 160, 90)
        let stroke = try XCTUnwrap(document.state.layers.first)
        XCTAssertEqual(stroke.kind, .pen)
        XCTAssertEqual(try XCTUnwrap(stroke.via.first).y, 140, accuracy: 0.01)
        try mouse(.leftMouseDown, 100, 90)
        try mouse(.leftMouseDragged, 110, 150)
        try key("r")
        try mouse(.leftMouseUp, 120, 90)
        XCTAssertEqual(document.state.layers, [stroke], "A tool switch cancels only the in-flight gesture")
        try key("t")
        try mouse(.leftMouseDown, 100, 80)
        try mouse(.leftMouseUp, 100, 80)
        try await waitFor("Native annotation text field receives focus") {
            (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.insertText("拼", replacementRange: editor.markedRange())
        for letter in ["p", "r", "a"] { try key(letter) }
        XCTAssertEqual(document.textEdit?.text, "拼pra")
        XCTAssertEqual(document.tool, .text)
        try mouse(.leftMouseDown, 120, 110)
        try mouse(.leftMouseUp, 120, 110)
        XCTAssertEqual(document.textEdit?.text, "拼pra", "Clicking elsewhere cannot discard an unsubmitted label")
        let field = NSSearchField()
        host.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        for letter in ["r", "p"] { try key(letter) }
        XCTAssertEqual(field.stringValue, "rp")
        XCTAssertEqual(document.tool, .text)
        XCTAssertEqual(document.state.layers, [stroke])
        document.cancelText()
        field.removeFromSuperview()
        for width in [360, 260, 220, 150] {
            window.setContentSize(CGSize(width: width, height: 480))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertTrue(window.makeFirstResponder(scroll))
            try key("t")
            // Use the center of the actual visible document viewport, not a
            // point outside the narrowed window.
            let visible = scroll.contentView.bounds
            try mouse(.leftMouseDown, Int(visible.midX), Int(visible.midY))
            try mouse(.leftMouseUp, Int(visible.midX), Int(visible.midY))
            try await waitFor("Annotation text field focused at width \(width)") {
                (window.firstResponder as? NSTextView)?.isFieldEditor == true
            }
            let textEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
            print("ANNOTATION_WIDTH \(width) window=\(window.contentView?.bounds.width ?? -1) field=\(textEditor.frame)")
            XCTAssertGreaterThanOrEqual(textEditor.frame.width, 40, "A focused text editor must remain visible and usable")
            textEditor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(textEditor.hasMarkedText())
            textEditor.insertText("中文", replacementRange: textEditor.markedRange())
            XCTAssertEqual(document.textEdit?.text, "中文")
            document.cancelText()
            try await waitFor("The cancelled text editor retires") {
                (window.firstResponder as? NSTextView)?.isFieldEditor != true
            }
        }
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testMountedCanvasUsesImageCoordinatesAtDifferentZoomAndNativeUndo() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("canvas.png")
        let original = try png(width: 600, height: 400)
        try original.write(to: path)
        let file = try await open(path)
        defer { file.retireContent() }
        let document = try XCTUnwrap(file.imageAnnotations)
        let window = NSWindow(contentRect: CGRect(x: -2000, y: -2000, width: 600, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderBack(nil)
        func find(_ view: NSView) -> PreviewScrollView? {
            if let scroll = view as? PreviewScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        func mount() async throws -> PreviewScrollView {
            let host = NSHostingView(rootView: FileViewerView(file: file).environment(\.appearsActive, true))
            host.sizingOptions = []
            window.contentView = host
            try await waitFor("Mount real annotation canvas") {
                host.layoutSubtreeIfNeeded()
                return find(host)?.documentView?.bounds.size == document.size
            }
            return try XCTUnwrap(find(host))
        }
        var scroll = try await mount()
        let action = try XCTUnwrap(scroll.accessibilityCustomActions()?.first {
            $0.name == String(localized: "Annotate Image", table: "Editor")
        })
        XCTAssertTrue(try XCTUnwrap(action.handler)())
        XCTAssertTrue(document.isEditing)
        XCTAssertTrue(scroll.undoManager === document.undoManager)
        let first = CGPoint(x: 200, y: 160), last = CGPoint(x: 260, y: 210)
        func drag(_ scroll: PreviewScrollView, from first: CGPoint, to last: CGPoint) throws {
            let canvas = try XCTUnwrap(scroll.documentView)
            func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            canvas.mouseDown(with: try event(.leftMouseDown, first))
            canvas.mouseDragged(with: try event(.leftMouseDragged, last))
            canvas.mouseUp(with: try event(.leftMouseUp, last))
        }
        for scale: CGFloat in [0.1, 1, 4] {
            scroll.setZoom(scale, at: first)
            document.tool = .rectangle
            try drag(scroll, from: first, to: last)
            let layer = try XCTUnwrap(document.state.layers.last)
            XCTAssertEqual(layer.start.x, first.x, accuracy: 0.01)
            XCTAssertEqual(layer.start.y, first.y, accuracy: 0.01)
            XCTAssertEqual(layer.end.x, last.x, accuracy: 0.01)
            XCTAssertEqual(layer.end.y, last.y, accuracy: 0.01)
        }
        let saved = document.state
        window.contentView = NSView()
        scroll = try await mount()
        XCTAssertTrue(scroll.undoManager === document.undoManager)
        XCTAssertEqual(document.state, saved)
        XCTAssertTrue(window.makeFirstResponder(scroll))
        XCTAssertTrue(file.canAnnotateImage)
        XCTAssertTrue(document.canMutate)
        XCTAssertTrue(document.undoManager.canUndo)
        XCTAssertTrue(window.firstResponder === scroll, "Actual responder: \(String(describing: window.firstResponder))")
        let undo = NSSelectorFromString("undo:")
        let redo = NSSelectorFromString("redo:")
        let undoItem = NSMenuItem(title: "Undo", action: undo, keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: redo, keyEquivalent: "Z")
        XCTAssertTrue(scroll.responds(to: undo))
        XCTAssertTrue(scroll.responds(to: redo))
        guard let validator = scroll as? NSMenuItemValidation,
              scroll.responds(to: undo), scroll.responds(to: redo) else {
            return XCTFail("The focused native canvas must receive standard Edit menu actions")
        }
        for remaining in stride(from: 2, through: 0, by: -1) {
            XCTAssertTrue(validator.validateMenuItem(undoItem))
            _ = scroll.perform(undo, with: undoItem)
            XCTAssertEqual(document.state.layers.count, remaining)
        }
        XCTAssertFalse(file.isDirty)
        XCTAssertTrue(document.state.isEmpty)
        XCTAssertFalse(validator.validateMenuItem(undoItem))
        for remaining in 1...3 {
            XCTAssertTrue(validator.validateMenuItem(redoItem))
            _ = scroll.perform(redo, with: redoItem)
            XCTAssertEqual(document.state.layers.count, remaining)
        }
        XCTAssertEqual(document.state, saved)
        XCTAssertTrue(file.isDirty)
        XCTAssertFalse(validator.validateMenuItem(redoItem))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(validator.validateMenuItem(undoItem))
        _ = scroll.perform(undo, with: undoItem)
        XCTAssertEqual(document.state, saved, "A nonfocused canvas must not consume Undo")
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImageAnnotationSidecar.path(for: path.path)))
    }
}
