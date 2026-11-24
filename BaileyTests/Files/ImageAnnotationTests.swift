import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Bailey

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
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket), timeout: 25)
        let created = try await backend.run(argv: ["mktemp", "-d", "/tmp/bailey-annotation-XXXXXX"],
            cwd: nil, env: nil, stdin: nil, timeout: 25)
        XCTAssertEqual(created.status, 0, String(decoding: created.stderr, as: UTF8.self))
        let root = String(decoding: created.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard (root as NSString).deletingLastPathComponent == "/tmp",
              (root as NSString).lastPathComponent.hasPrefix("bailey-annotation-") else {
            throw WorkspaceError.notFound
        }
        func cleanup() async {
            do { try await backend.delete(paths: [root]) }
            catch { XCTFail("Cannot delete only the isolated remote fixture: \(error)") }
            let result = await Task.detached {
                ProcessRemoteCommandRunner.run(sshPath: "/usr/bin/ssh",
                    arguments: ["-S", socket, "-O", "exit", host], stdin: nil, timeout: 10)
            }.value
            XCTAssertEqual(result.status, 0)
        }
        do {
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
            let remaining = try await backend.list(directory: root)
            XCTAssertEqual(Set(remaining.map(\.name)), [name, name + ImageAnnotationSidecar.suffix])
            let remoteSource = try await backend.read(path: path, maxBytes: original.count)
            XCTAssertEqual(remoteSource, original)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), local)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), sentinel)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
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
        for _ in 0..<3 { scroll.undoManager?.undo() }
        XCTAssertFalse(file.isDirty)
        XCTAssertTrue(document.state.isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImageAnnotationSidecar.path(for: path.path)))
    }
}
