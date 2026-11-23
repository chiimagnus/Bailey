import AppKit
import XCTest

@MainActor
final class NativeMediaFileUITests: XCTestCase {
    func testNativeVideoContinuesPlayingAcrossSystemFullScreen() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let video = fixture.root.appending(path: "Fullscreen.mp4")
        try FileManager.default.copyItem(
            at: root.appending(path: ".github/features/video-file-playback/demo-video.mp4"), to: video
        )
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let windowID = app.windows.firstMatch.identifier
        let window = app.windows.matching(identifier: windowID).firstMatch
        open(video, in: window, app: app)
        let tab = WorkspaceUITestSupport.fileTab(video, in: window)
        let toggle = window.checkBoxes["play/pause"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let fullScreen = window.checkBoxes["toggle full screen"]
        XCTAssertTrue(fullScreen.exists, window.debugDescription)
        let inlineWidth = window.sliders["timeline"].frame.width
        let inlineWindow = window.frame
        let paused = String(describing: toggle.value ?? "")
        let speed = window.buttons["playback speed"]
        speed.click()
        let slow = WorkspaceUITestSupport.menuItem("0.5×", in: speed)
        XCTAssertTrue(slow.waitForExistence(timeout: 5))
        slow.click()
        toggle.click()
        XCTAssertNotEqual(String(describing: toggle.value ?? ""), paused)
        fullScreen.click()

        func fullTimeline() -> XCUIElement? {
            app.sliders.matching(identifier: "timeline").allElementsBoundByIndex.first {
                $0.frame.width > inlineWidth + 50
            }
        }
        func time(_ slider: XCUIElement) -> Double? {
            Double(String(describing: slider.value ?? ""))
        }
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fullTimeline() != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed, app.debugDescription)
        let enteredAt = try XCTUnwrap(fullTimeline().flatMap(time))
        let advances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (fullTimeline().flatMap(time) ?? 0) > enteredAt + 0.15
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 2), .completed,
                       "The native playhead must keep advancing in full screen")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fullTimeline() == nil && tab.exists && window.sliders["timeline"].exists
                && window.frame.width == inlineWindow.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 8), .completed)
        XCTAssertTrue(tab.isSelected)
        let inlineTimeline = window.sliders["timeline"]
        let returnedAt = try XCTUnwrap(time(inlineTimeline))
        XCTAssertGreaterThan(returnedAt, enteredAt)
        let inlineAdvances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (time(inlineTimeline) ?? 0) > returnedAt + 0.15
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [inlineAdvances], timeout: 3), .completed)

        toggle.click()
        XCTAssertEqual(String(describing: toggle.value ?? ""), paused)
        let pausedAt = try XCTUnwrap(time(inlineTimeline))
        fullScreen.click()
        let pausedFullScreen = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in fullTimeline() != nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pausedFullScreen], timeout: 5), .completed)
        let progressesWhilePaused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs((fullTimeline().flatMap(time) ?? pausedAt) - pausedAt) > 0.06
        }, object: nil)
        progressesWhilePaused.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [progressesWhilePaused], timeout: 1.5), .completed)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let pausedExit = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fullTimeline() == nil && tab.isSelected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pausedExit], timeout: 8), .completed)
        XCTAssertEqual(String(describing: toggle.value ?? ""), paused)
    }

    func testNativeAudioControlsAndPauseWhenAnotherFileTakesFocus() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let audio = fixture.root.appending(path: "录音.m4a")
        try FileManager.default.copyItem(at: root.appending(path: ".github/features/audio-file-playback/demo-audio.m4a"),
                                         to: audio)
        let original = try Data(contentsOf: audio)
        let text = try fixture.file("other.txt", text: "Another file\n")
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        open(audio, in: window, app: app)
        let play = window.checkBoxes["play/pause"]
        let position = window.sliders["timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        let paused = String(describing: play.value ?? "")
        let initial = String(describing: position.value ?? "")
        position.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).click()
        let sought = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(describing: position.value ?? "") != initial
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 5), .completed)
        XCTAssertEqual(String(describing: play.value ?? ""), paused)
        let startTime = String(describing: position.value ?? "")
        let speed = window.buttons["playback speed"]
        XCTAssertTrue(speed.exists)
        speed.click()
        let slow = WorkspaceUITestSupport.menuItem("0.5×", in: speed)
        XCTAssertTrue(slow.waitForExistence(timeout: 5))
        XCTAssertTrue(WorkspaceUITestSupport.menuItem("2×", in: speed).exists)
        slow.click()
        XCTAssertEqual(String(describing: play.value ?? ""), paused)
        speed.click()
        XCTAssertTrue(slow.waitForExistence(timeout: 5))
        XCTAssertTrue(slow.isSelected)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let volume = window.sliders["volume"]
        XCTAssertTrue(volume.waitForExistence(timeout: 5))
        func volumeLevel() -> Double? { Double(String(describing: volume.value ?? "")) }
        volume.adjust(toNormalizedSliderPosition: 0.35)
        XCTAssertEqual(try XCTUnwrap(volumeLevel()), 0.35, accuracy: 0.08)
        let mute = window.buttons["mute"]
        XCTAssertTrue(mute.exists)
        mute.click()
        XCTAssertEqual(volumeLevel(), 0)
        mute.click()
        XCTAssertEqual(try XCTUnwrap(volumeLevel()), 0.35, accuracy: 0.08)
        mute.click()
        XCTAssertEqual(volumeLevel(), 0)
        play.click()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(describing: play.value ?? "") != paused && String(describing: position.value ?? "") != startTime
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 6), .completed)

        open(text, in: window, app: app)
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(play.exists)
        WorkspaceUITestSupport.fileTab(audio, in: window).click()
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertEqual(String(describing: play.value ?? ""), paused)
        XCTAssertTrue(volume.waitForExistence(timeout: 5))
        XCTAssertEqual(volumeLevel(), 0)
        XCTAssertEqual(try Data(contentsOf: audio), original)
    }

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
        open(video, in: window, app: app)
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

        open(source, in: window, app: app)
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

    private func open(_ file: URL, in window: XCUIElement, app: XCUIApplication) {
        app.activate()
        let row = WorkspaceUITestSupport.fileRow(file, in: window)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground && row.exists && row.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        row.doubleClick()
    }
}
