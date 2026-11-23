import AppKit
import XCTest

@MainActor
final class NativeMediaFileUITests: XCTestCase {
    func testVideoPlaysAndRetainsItsPositionAwayFromTheForegroundTab() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sample = root.appending(path: ".github/features/video-file-playback/demo-video.mp4")
        let video = fixture.root.appending(path: "本机片段.MP4")
        try FileManager.default.copyItem(at: sample, to: video)
        let original = try Data(contentsOf: video)
        let source = try fixture.file("other.txt", text: "Another file\n")
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        let row = WorkspaceUITestSupport.fileRow(video, in: window)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let toggle = window.checkBoxes["play/pause"]
        let timeline = window.sliders["timeline"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        XCTAssertFalse(window.textViews.firstMatch.exists)
        func value(_ element: XCUIElement) -> String { String(describing: element.value ?? "") }
        func waitForChange(_ element: XCUIElement, from previous: String) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                value(element) != previous
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        }
        let stopped = value(toggle)
        let initialTime = value(timeline)
        toggle.click()
        waitForChange(toggle, from: stopped)
        waitForChange(timeline, from: initialTime)
        toggle.click()
        XCTAssertEqual(value(toggle), stopped)
        let pausedTime = value(timeline)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).click()
        waitForChange(timeline, from: pausedTime)
        let soughtPosition = try XCTUnwrap(Double(value(timeline)))
        XCTAssertEqual(soughtPosition, 4.8, accuracy: 0.4)

        WorkspaceUITestSupport.fileRow(source, in: window).doubleClick()
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(toggle.exists)
        WorkspaceUITestSupport.fileTab(video, in: window).click()
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        XCTAssertEqual(value(toggle), stopped)
        XCTAssertEqual(try XCTUnwrap(Double(value(timeline))), soughtPosition, accuracy: 1.0 / 30.0)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(WorkspaceUITestSupport.fileTab(video, in: window).waitForNonExistence(timeout: 10))
        XCTAssertFalse(toggle.exists)
        XCTAssertEqual(try Data(contentsOf: video), original)
    }
}
