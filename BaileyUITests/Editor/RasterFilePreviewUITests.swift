import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class RasterFilePreviewUITests: XCTestCase {
    func testJPEGAtActualSizeKeepsFinePixelsAndPansToBothSides() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = fixture.root.appending(path: "Regional detail.jpeg")
        let width = 5600
        let height = 500
        let canvas = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        canvas.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        canvas.setFillColor(red: 0.07, green: 0.25, blue: 0.9, alpha: 1)
        canvas.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        canvas.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        for column in stride(from: 0, to: width, by: 4) {
            canvas.fill(CGRect(x: column, y: 0, width: 2, height: height))
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()),
                                  [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let before = try Data(contentsOf: file)
        let app = try WorkspaceUITestSupport.launch(in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true)
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let viewer = WorkspaceUITestSupport.element("bailey.image.inspector", in: app)
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        viewer.rightClick()
        let actual = WorkspaceUITestSupport.menuItem("100%", in: app)
        XCTAssertTrue(actual.waitForExistence(timeout: 5))
        actual.click()
        let left = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.5))
        let right = viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.5))

        func expectPixels(blue: Bool) {
            let pixels = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let bitmap = NSBitmapImageRep(data: viewer.screenshot().pngRepresentation) else { return false }
                let middle = bitmap.pixelsWide / 2
                let row = bitmap.pixelsHigh / 2
                guard middle > 90 else { return false }
                var bright = 0
                var wanted = 0
                var other = 0
                for column in (middle - 80)..<(middle + 80) {
                    guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                    if min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) > 0.78 { bright += 1 }
                    let difference = pixel.blueComponent - pixel.redComponent
                    if blue ? difference > 0.4 : difference < -0.4 { wanted += 1 }
                    if blue ? difference < -0.4 : difference > 0.4 { other += 1 }
                }
                return bright > 18 && wanted > 18 && other == 0
            }, object: nil)
            let result = XCTWaiter.wait(for: [pixels], timeout: 8)
            if result != .completed { add(XCTAttachment(screenshot: viewer.screenshot())) }
            XCTAssertEqual(result, .completed, "Expected fine \(blue ? "blue" : "red") stripes after native pan")
        }

        right.click(forDuration: 0.2, thenDragTo: left)
        expectPixels(blue: true)
        left.click(forDuration: 0.2, thenDragTo: right)
        left.click(forDuration: 0.2, thenDragTo: right)
        expectPixels(blue: false)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testGIFStopsAdvancingWhileAnotherBaileyWindowIsKey() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = fixture.root.appending(path: "Window Focus.gif")
        let canvas = try XCTUnwrap(CGContext(
            data: nil, width: 72, height: 72, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            file as CFURL, UTType.gif.identifier as CFString, 2, nil
        ))
        for red in [true, false] {
            canvas.setFillColor(red: red ? 1 : 0, green: red ? 0 : 1, blue: 0, alpha: 1)
            canvas.fill(CGRect(x: 0, y: 0, width: 72, height: 72))
            CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: red ? 8 : 24],
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: file)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let firstID = app.windows.firstMatch.identifier
        let first = app.windows.matching(identifier: firstID).firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: first)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let viewer = first.descendants(matching: .any).matching(identifier: "bailey.image.inspector").firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        func centerColor() -> NSColor? {
            guard let bitmap = NSBitmapImageRep(data: viewer.screenshot().pngRepresentation) else { return nil }
            return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        }
        let foregroundRed = try XCTUnwrap(centerColor())
        XCTAssertGreaterThan(foregroundRed.redComponent - foregroundRed.greenComponent, 0.45)

        app.typeKey("n", modifierFlags: [.command, .shift])
        let second = app.windows.matching(NSPredicate(format: "identifier != %@", firstID)).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 15))
        let secondID = second.identifier
        XCTAssertEqual(app.windows.firstMatch.identifier, secondID)
        let firstBecomesKey = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.identifier != secondID
        }, object: nil)
        firstBecomesKey.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [firstBecomesKey], timeout: 9), .completed)
        XCTAssertTrue(viewer.exists, "The original viewer must remain mounted in its background window")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(second.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.windows.firstMatch.identifier, firstID)
        let resumedColor = try XCTUnwrap(centerColor())
        XCTAssertEqual(resumedColor.redComponent, foregroundRed.redComponent, accuracy: 0.05,
                       "The red frame must not have expired in the background")
        XCTAssertEqual(resumedColor.greenComponent, foregroundRed.greenComponent, accuracy: 0.05)
        let advances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            centerColor().map { $0.greenComponent - $0.redComponent > 0.45 } ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 9), .completed)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testRealGIFPausesAndResumesThroughTheNativeImageMenu() throws {
        guard let acceptance = ProcessInfo.processInfo.environment["BAILEY_IMAGE_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_IMAGE_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        continueAfterFailure = false
        let original = URL(fileURLWithPath: acceptance).appending(path: "images/动画-34帧.gif")
        let fixture = try WorkspaceUITestFixture(in: self)
        let file = fixture.root.appending(path: "Animation.gif")
        let bytes = try Data(contentsOf: original)
        try bytes.write(to: file)
        let other = try fixture.file("Other.txt", text: "Switch away from the animation.")
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let viewer = WorkspaceUITestSupport.element("bailey.image.inspector", in: app)
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        func spriteCenter() -> Int? {
            guard viewer.exists, let bitmap = NSBitmapImageRep(data: viewer.screenshot().pngRepresentation) else {
                return nil
            }
            let center = bitmap.pixelsWide / 2
            let row = bitmap.pixelsHigh / 2
            let extent = min(140, center - 1)
            guard extent > 0, row > 0 else { return nil }
            let blue = stride(from: center - extent, through: center + extent, by: 2).filter { column in
                guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { return false }
                return color.blueComponent > 0.69 && color.greenComponent < 0.54
            }
            guard let first = blue.first, let last = blue.last, last - first >= 12 else { return nil }
            return (first + last) / 2
        }
        let firstFrame = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in spriteCenter() != nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [firstFrame], timeout: 8), .completed)
        let initial = try XCTUnwrap(spriteCenter())
        func expectMovement(from center: Int, inverted: Bool = false) {
            let moves = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                spriteCenter().map { abs($0 - center) > 4 } ?? false
            }, object: nil)
            moves.isInverted = inverted
            XCTAssertEqual(XCTWaiter.wait(for: [moves], timeout: inverted ? 0.8 : 5), .completed)
        }
        expectMovement(from: initial)
        viewer.rightClick()
        let pause = WorkspaceUITestSupport.menuItem("Pause Animation", in: app)
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.click()
        let paused = try XCTUnwrap(spriteCenter())
        expectMovement(from: paused, inverted: true)

        WorkspaceUITestSupport.fileRow(other, in: window).doubleClick()
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 10))
        WorkspaceUITestSupport.fileTab(file, in: window).click()
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(abs(try XCTUnwrap(spriteCenter()) - paused), 4)
        viewer.rightClick()
        let resume = WorkspaceUITestSupport.menuItem("Resume Animation", in: app)
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.click()
        expectMovement(from: paused)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
}
