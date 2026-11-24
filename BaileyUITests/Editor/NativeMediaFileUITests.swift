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

    func testWaveformSeeksTheSameNativeTimelineAndZoomsItsVisibleInterval() throws {
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let audio = fixture.root.appending(path: "Waveform.m4a")
        try FileManager.default.copyItem(at: root.appending(path: ".github/features/audio-file-playback/demo-audio.m4a"),
                                         to: audio)
        let original = try Data(contentsOf: audio)
        let other = try fixture.file("other.txt", text: "Another file")
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        open(audio, in: window, app: app)
        let waveform = window.sliders["bailey.audio.waveform"]
        let timeline = window.sliders["timeline"]
        let play = window.checkBoxes["play/pause"]
        XCTAssertTrue(waveform.waitForExistence(timeout: 10))
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let paused = String(describing: play.value ?? "")
        func time() -> Double? { Double(String(describing: timeline.value ?? "")) }
        func expectTime(_ seconds: Double) {
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let actual = time(), let accessible = Double(String(describing: waveform.value ?? "")) else { return false }
                return abs(actual - seconds) < 0.35 && abs(actual - accessible) < 0.05
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed,
                           "Expected time \(seconds); native=\(String(describing: timeline.value)), waveform=\(String(describing: waveform.value))")
        }
        // The checked-in AAC sample has a real 12-second timeline.
        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
        expectTime(9)
        let right = waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let left = waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        right.press(forDuration: 0.1, thenDragTo: left)
        expectTime(3)
        XCTAssertEqual(String(describing: play.value ?? ""), paused)

        waveform.rightClick()
        let zoom = WorkspaceUITestSupport.menuItem("Zoom In", in: app)
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        zoom.click()
        // Zooming around the center produces [3, 9]; one quarter is 4.5.
        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        expectTime(4.5)
        open(other, in: window, app: app)
        XCTAssertTrue(window.textViews.firstMatch.waitForExistence(timeout: 10))
        WorkspaceUITestSupport.fileTab(audio, in: window).click()
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        expectTime(4.5)
        XCTAssertEqual(String(describing: play.value ?? ""), paused)
        XCTAssertEqual(try Data(contentsOf: audio), original)
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
        // AVKit owns the track, thumb geometry and quantized volume steps.
        // Verify actual changes in both directions and exact restoration after mute.
        volume.adjust(toNormalizedSliderPosition: 0.2)
        let low = try XCTUnwrap(volumeLevel())
        XCTAssertGreaterThan(low, 0)
        XCTAssertLessThan(low, 0.5)
        volume.adjust(toNormalizedSliderPosition: 0.75)
        let high = try XCTUnwrap(volumeLevel())
        XCTAssertGreaterThan(high, low)
        XCTAssertLessThanOrEqual(high, 1)
        volume.adjust(toNormalizedSliderPosition: 0.35)
        let adjusted = try XCTUnwrap(volumeLevel())
        XCTAssertGreaterThan(adjusted, low)
        XCTAssertLessThan(adjusted, high)
        let mute = window.buttons["mute"]
        XCTAssertTrue(mute.exists)
        mute.click()
        XCTAssertEqual(volumeLevel(), 0)
        mute.click()
        XCTAssertEqual(try XCTUnwrap(volumeLevel()), adjusted, accuracy: 0.001)
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

    func testRealEmbeddedSubtitlesUseTheNativeVideoMenu() throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_MEDIA_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_MEDIA_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        continueAfterFailure = false
        let fixture = try WorkspaceUITestFixture(in: self)
        let original = URL(fileURLWithPath: root).appending(path: "media/视频-内置字幕.mp4")
        let bytes = try Data(contentsOf: original)
        let video = fixture.root.appending(path: "Captioned.mp4")
        try bytes.write(to: video)
        let noCaptions = fixture.root.appending(path: "Plain.mov")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: root).appending(path: "media/视频-ProRes.mov"),
                                         to: noCaptions)
        let app = try WorkspaceUITestSupport.launch(
            in: self, language: "en", project: fixture.root, clipboardIsReadOnly: true
        )
        let window = app.windows.firstMatch
        open(video, in: window, app: app)
        let play = window.checkBoxes["play/pause"]
        let timeline = window.sliders["timeline"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        let tab = WorkspaceUITestSupport.fileTab(video, in: window)
        let dividerFrames = window.descendants(matching: .any).matching(identifier: "bailey.dock.divider")
            .allElementsBoundByIndex.map(\.frame)
        let left = try XCTUnwrap(dividerFrames.map(\.maxX).filter { $0 < timeline.frame.midX }.max())
        let right = try XCTUnwrap(dividerFrames.map(\.minX).filter { $0 > timeline.frame.midX }.min())
        let panel = CGRect(x: left, y: tab.frame.maxY, width: right - left, height: window.frame.maxY - tab.frame.maxY)
        let videoHeight = panel.width * 9 / 16
        XCTAssertGreaterThan(panel.height - videoHeight, 100, "The fixture needs real letterbox bars")
        let videoBottom = panel.midY + videoHeight / 2
        XCTAssertLessThan(timeline.frame.maxY, videoBottom + 8, "Native playback controls must remain over the image")
        XCTAssertGreaterThan(timeline.frame.minY, panel.midY - videoHeight / 2 - 8)
        let paused = String(describing: play.value ?? "")
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.5)).click()
        let sought = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let position = Double(String(describing: timeline.value ?? "")) else { return false }
            return (5.5...8).contains(position)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 5), .completed)
        let frameTime = try XCTUnwrap(Double(String(describing: timeline.value ?? "")))
        let subtitles = window.buttons["show legible media selection menu"]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 5), window.debugDescription)
        let captionBottom = videoBottom - 1
        let captionTop = videoBottom - videoHeight * 0.2
        let restingPointer = window.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.72))
        func setCaptions(_ title: String) {
            subtitles.click()
            let option = WorkspaceUITestSupport.menuItem(title, in: subtitles)
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.click()
            restingPointer.hover()
        }
        func framePixels(_ screenshot: XCUIScreenshot) -> [NSColor] {
            guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation) else { return [] }
            let top = Int((captionTop - window.frame.minY) * CGFloat(bitmap.pixelsHigh) / window.frame.height)
            let bottom = Int((captionBottom - window.frame.minY) * CGFloat(bitmap.pixelsHigh) / window.frame.height)
            guard top >= 0, bottom < bitmap.pixelsHigh, top < bottom else { return [] }
            return stride(from: bitmap.pixelsWide * 40 / 100, to: bitmap.pixelsWide * 64 / 100, by: 4).flatMap { column in
                stride(from: top, to: bottom, by: 4).compactMap { row in
                    bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB)
                }
            }
        }
        setCaptions("Off")
        let initialScreenshot = window.screenshot()
        let withoutText = framePixels(initialScreenshot)
        XCTAssertGreaterThan(withoutText.count, 1_000)
        let language = WorkspaceUITestSupport.menuItem("Language", in: subtitles)
        let chinese = WorkspaceUITestSupport.menuItem("Chinese", in: language)
        func showLanguages() {
            subtitles.click()
            XCTAssertTrue(language.waitForExistence(timeout: 5), subtitles.debugDescription)
            language.hover()
            let revealed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                chinese.exists && chinese.isHittable
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [revealed], timeout: 5), .completed, language.debugDescription)
        }
        showLanguages()
        chinese.click()
        setCaptions("On")
        func changedPixels() -> Int? {
            let current = framePixels(window.screenshot())
            guard current.count == withoutText.count else { return nil }
            return zip(withoutText, current).filter { old, new in
                max(abs(old.redComponent - new.redComponent), abs(old.greenComponent - new.greenComponent),
                    abs(old.blueComponent - new.blueComponent)) > 0.2
            }.count
        }
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (changedPixels() ?? 0) > 15
        }, object: nil)
        let enabled = XCTWaiter.wait(for: [rendered], timeout: 8)
        if enabled != .completed {
            add(XCTAttachment(screenshot: initialScreenshot))
            add(XCTAttachment(screenshot: window.screenshot()))
        }
        XCTAssertEqual(enabled, .completed)
        XCTAssertEqual(String(describing: play.value ?? ""), paused)
        XCTAssertEqual(try XCTUnwrap(Double(String(describing: timeline.value ?? ""))), frameTime, accuracy: 0.04)
        setCaptions("Off")
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (changedPixels() ?? .max) < 10
        }, object: nil)
        let disabled = XCTWaiter.wait(for: [removed], timeout: 8)
        if disabled != .completed {
            add(XCTAttachment(screenshot: initialScreenshot))
            add(XCTAttachment(screenshot: window.screenshot()))
        }
        XCTAssertEqual(disabled, .completed)

        open(noCaptions, in: window, app: app)
        let plainTab = WorkspaceUITestSupport.fileTab(noCaptions, in: window)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            plainTab.exists && plainTab.isSelected && (window.staticTexts["duration"].value as? String) == "00:04"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        if subtitles.exists, subtitles.isEnabled, subtitles.isHittable {
            subtitles.click()
            XCTAssertFalse(language.exists, subtitles.debugDescription)
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
        XCTAssertEqual(try Data(contentsOf: video), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
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
