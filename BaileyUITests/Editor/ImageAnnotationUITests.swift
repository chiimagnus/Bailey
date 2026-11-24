import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ImageAnnotationUITests: XCTestCase {
    func testNativeGestureUndoSaveReopenAndCancelExportLeaveOriginalUntouched() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = fixture.root.appending(path: "Annotations.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: file)
        let sidecar = URL(fileURLWithPath: file.path + ".bailey-annotations.json")
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root,
                                                     clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let viewer = WorkspaceUITestSupport.element("bailey.image.inspector", in: app)
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        viewer.rightClick()
        let annotate = WorkspaceUITestSupport.menuItem("Annotate Image", in: app)
        XCTAssertTrue(annotate.waitForExistence(timeout: 5))
        annotate.click()
        let arrow = WorkspaceUITestSupport.element("bailey.annotation.tool.arrow", in: app)
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        arrow.click()
        let a = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.55))
        let b = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.68))
        a.click(forDuration: 0.15, thenDragTo: b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: [.command, .shift])
        app.typeKey("s", modifierFlags: .command)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: sidecar.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        let annotations = try XCTUnwrap(json["annotations"] as? [String: Any])
        let layers = try XCTUnwrap(annotations["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers.first?["kind"] as? String, "arrow")
        XCTAssertEqual(try Data(contentsOf: file), original)
        let sidecarBytes = try Data(contentsOf: sidecar)
        let tab = WorkspaceUITestSupport.fileTab(file, in: window)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(tab.waitForNonExistence(timeout: 10))
        row.doubleClick()
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let bitmap = NSBitmapImageRep(data: viewer.screenshot().pngRepresentation) else { return false }
            for y in stride(from: bitmap.pixelsHigh / 3, to: bitmap.pixelsHigh * 4 / 5, by: 2) {
                for x in stride(from: bitmap.pixelsWide / 3, to: bitmap.pixelsWide * 2 / 3, by: 2) {
                    if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       c.redComponent > 0.65, c.redComponent - c.greenComponent > 0.4,
                       c.redComponent - c.blueComponent > 0.4 { return true }
                }
            }
            return false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 10), .completed)
        viewer.rightClick()
        let export = WorkspaceUITestSupport.menuItem("Export Annotated Image…", in: app)
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.click()
        let cancel = window.sheets.firstMatch.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)),
                       [file.lastPathComponent, sidecar.lastPathComponent])
    }
}
