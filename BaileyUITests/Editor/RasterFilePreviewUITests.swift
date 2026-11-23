import AppKit
import XCTest

@MainActor
final class RasterFilePreviewUITests: XCTestCase {
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
