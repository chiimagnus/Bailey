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
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bailey-annotations-" + UUID().uuidString)
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

    private func waitFor(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(label)
                throw WorkspaceError.timedOut
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private func open(_ path: URL) async throws -> FileTab {
        let file = FileTab(path: path.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
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
        let invalid = [
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

    func testFilesTransfersCannotSeparatePairButContainingDirectoryMovesTogether() async throws {
        let root = try makeRoot()
        let folder = root.appendingPathComponent("paired")
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
        let sidecar = ImageAnnotationSidecar.path(for: path.path)
        let annotations = try Data(contentsOf: URL(fileURLWithPath: sidecar))
        for item in [path.path, sidecar] {
            for move in [true, false] {
                do {
                    _ = try await LocalWorkspaceBackend.shared.transferLocalFile(from: item, into: destination.path, move: move)
                    XCTFail("A single half must not transfer")
                } catch {}
            }
            do {
                try await ImageAnnotationSidecar.requireUnpaired(item, backend: LocalWorkspaceBackend.shared)
                XCTFail("Rename/delete must refuse the pair")
            } catch {}
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sidecar)), annotations)
        _ = try await LocalWorkspaceBackend.shared.transferLocalFile(from: folder.path, into: destination.path, move: true)
        let moved = destination.appendingPathComponent("paired/image.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        file.updatePath(moved.path)
        let restored = try await open(moved)
        defer { restored.retireContent() }
        XCTAssertEqual(restored.imageAnnotations?.state, document.state)
        XCTAssertEqual(try Data(contentsOf: moved), original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ImageAnnotationSidecar.path(for: moved.path))), annotations)
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

    func testActualFilesTreeRejectsHalfOfPairAndRenamesWholeDirectory() async throws {
        let root = try makeRoot()
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
        for half in [path.path, sidecar] {
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
        let renamed = await tree.rename(row, to: "whole")
        let moved = root.appendingPathComponent("whole/image.png")
        XCTAssertEqual(renamed, moved.deletingLastPathComponent().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        file.updatePath(moved.path)
        let restored = try await open(moved)
        defer { restored.retireContent() }
        XCTAssertEqual(restored.imageAnnotations?.state, document.state)
        XCTAssertEqual(try Data(contentsOf: moved), original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ImageAnnotationSidecar.path(for: moved.path))), stored)
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
        let project = Project(fallbackName: "annotation close", workspaceConfiguration: .standard)
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
