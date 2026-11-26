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
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root)
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
        func expectArrow(_ expected: Bool) {
            let pixels = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard viewer.exists,
                      let bitmap = NSBitmapImageRep(data: viewer.screenshot().pngRepresentation) else { return false }
                for y in stride(from: bitmap.pixelsHigh / 3, to: bitmap.pixelsHigh * 4 / 5, by: 2) {
                    for x in stride(from: bitmap.pixelsWide / 3, to: bitmap.pixelsWide * 2 / 3, by: 2) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                           color.redComponent > 0.65, color.redComponent - color.greenComponent > 0.4,
                           color.redComponent - color.blueComponent > 0.4 { return expected }
                    }
                }
                return !expected
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [pixels], timeout: 10), .completed,
                           "Expected arrow pixels: \(expected)")
        }
        expectArrow(true)
        app.typeKey("z", modifierFlags: .command)
        expectArrow(false)
        app.typeKey("z", modifierFlags: [.command, .shift])
        expectArrow(true)
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
        expectArrow(true)
        viewer.rightClick()
        let copy = WorkspaceUITestSupport.menuItem("Copy Annotated Image", in: app)
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let clipboard = NSPasteboard.general
        let initialClipboardVersion = clipboard.changeCount
        copy.click()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            clipboard.changeCount != initialClipboardVersion && clipboard.data(forType: .png) != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 10), .completed)
        let png = try XCTUnwrap(clipboard.data(forType: .png))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, 640)
        XCTAssertEqual(bitmap.pixelsHigh, 480)
        func containsArrow(_ bitmap: NSBitmapImageRep) -> Bool {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       c.redComponent > 0.65, c.redComponent - c.greenComponent > 0.4,
                       c.redComponent - c.blueComponent > 0.4 { return true }
                }
            }
            return false
        }
        XCTAssertTrue(containsArrow(bitmap), "The clipboard must contain the rendered annotation, not just the original image")
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

        viewer.rightClick()
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.click()
        let proceed = window.sheets.firstMatch.buttons["Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 5))
        proceed.click()
        let output = fixture.root.appendingPathComponent("Annotations-annotated.png")
        try WorkspaceUITestSupport.saveFile(output, in: app, window: window)
        let exported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: output.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exported], timeout: 10), .completed)
        let exportedBitmap = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: output)))
        XCTAssertEqual(exportedBitmap.pixelsWide, 640)
        XCTAssertEqual(exportedBitmap.pixelsHigh, 480)
        XCTAssertTrue(containsArrow(exportedBitmap))

        // The native panel's overwrite confirmation is followed by the
        // document's version-bound confirmation. Both affect only this fixture.
        let previous = try Data(contentsOf: output)
        func chooseExistingExport() throws {
            let beforeSelection = try Data(contentsOf: output)
            viewer.rightClick()
            XCTAssertTrue(export.waitForExistence(timeout: 5))
            export.click()
            XCTAssertTrue(proceed.waitForExistence(timeout: 5))
            proceed.click()
            try WorkspaceUITestSupport.saveFile(output, in: app, window: window, replacing: true)
            // NSSavePanel hosts this alert in a nested, out-of-process sheet.
            let nativeReplace = window.sheets["save-panel"].descendants(matching: .button)
                .matching(identifier: "action-button-1").firstMatch
            XCTAssertTrue(nativeReplace.waitForExistence(timeout: 10))
            XCTAssertEqual(try Data(contentsOf: output), beforeSelection)
            nativeReplace.click()
            XCTAssertTrue(window.sheets["save-panel"].waitForNonExistence(timeout: 10))
            let confirmation = window.staticTexts.matching(NSPredicate(
                format: "value == %@ OR label == %@", "Replace existing export?", "Replace existing export?"
            )).firstMatch
            XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
            XCTAssertEqual(try Data(contentsOf: output), beforeSelection)
        }
        try chooseExistingExport()
        window.sheets.firstMatch.buttons["Cancel"].click()
        XCTAssertEqual(try Data(contentsOf: output), previous)
        // Use a different valid image to establish an observable replacement.
        try original.write(to: output, options: .atomic)
        try chooseExistingExport()
        window.sheets.firstMatch.buttons["Replace"].click()
        let replaced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let bytes = try? Data(contentsOf: output), bytes != original,
                  let image = NSBitmapImageRep(data: bytes) else { return false }
            return containsArrow(image)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [replaced], timeout: 10), .completed)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBytes)

        // Rename only the original through the actual Files menu; the saved
        // sidecar and the open viewer must follow it without another document.
        row.rightClick()
        let rename = WorkspaceUITestSupport.menuItem("Rename", in: app)
        XCTAssertTrue(rename.waitForExistence(timeout: 8))
        rename.click()
        let name = window.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Renamed.png")
        name.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let renamed = fixture.root.appending(path: "Renamed.png")
        let renamedSidecar = URL(fileURLWithPath: renamed.path + ".bailey-annotations.json")
        let renamedPair = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: renamed)) == original &&
                (try? Data(contentsOf: renamedSidecar)) == sidecarBytes &&
                !FileManager.default.fileExists(atPath: file.path) &&
                !FileManager.default.fileExists(atPath: sidecar.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [renamedPair], timeout: 15), .completed)
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(renamed, in: window).waitForExistence(timeout: 10))
        XCTAssertFalse(tab.exists)
        expectArrow(true)
    }
}
