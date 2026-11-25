import AppKit
import AVFoundation
import AVKit
import SwiftUI
import Foundation
import XCTest
@testable import Bailey

@MainActor
final class NativeAudioTimingTests: XCTestCase {
    func testMountedAudioControlsFollowTheFilePlayerTimeAndAdjustItsVolume() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Recording.m4a")
        try FileManager.default.copyItem(at: root.appending(path: ".github/features/audio-file-playback/demo-audio.m4a"), to: url)
        let original = try Data(contentsOf: url)
        let file = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        file.loadIfNeeded()
        defer { file.retireContent() }
        func wait(_ message: String, _ ready: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while !ready() {
                guard ContinuousClock.now < deadline else {
                    XCTFail(message)
                    throw WorkspaceError.timedOut
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await wait("Ready native player") { file.mediaPlayer?.currentItem?.status == .readyToPlay }
        let player = try XCTUnwrap(file.mediaPlayer)
        guard case .media(let media) = file.content else { return XCTFail("Expected accepted audio") }
        let duration = try await media.asset.load(.duration).seconds
        XCTAssertEqual(duration, 12, accuracy: 0.1)
        player.isMuted = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: FileViewerView(file: file))
        func mounted<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            (view as? T) ?? view.subviews.lazy.compactMap { mounted(type, in: $0) }.first
        }
        host.sizingOptions = []
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        let pid = ProcessInfo.processInfo.processIdentifier
        let access = await Task.detached {
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString,
                                                  &windows).rawValue
        }.value
        XCTAssertEqual(access, AXError.success.rawValue)
        func attribute(_ element: NSObject, _ name: String) -> Any? {
            guard element.responds(to: NSSelectorFromString(name)) else { return nil }
            return element.value(forKey: name)
        }
        func elements(_ element: NSObject) -> [NSObject] {
            let children = attribute(element, "accessibilityChildrenInNavigationOrder") as? [NSObject]
                ?? attribute(element, "accessibilityChildren") as? [NSObject] ?? []
            return [element] + children.flatMap(elements)
        }
        func controls() -> [NSObject] {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return (host.accessibilityChildren() as? [NSObject] ?? []).flatMap(elements)
        }
        func control(_ identifier: String) -> NSObject? {
            controls().first { attribute($0, "accessibilityIdentifier") as? String == identifier }
        }
        func timeline() -> NSObject? { control("timeline") }
        try await wait("The file mounts Apple AVKit") { mounted(AVPlayerView.self, in: host) != nil }
        let surface = try XCTUnwrap(mounted(AVPlayerView.self, in: host),
                                    "Standalone audio must use Apple's AVKit player, not a hand-built transport")
        XCTAssertTrue(surface.player === player)
        XCTAssertEqual(surface.controlsStyle, .floating)
        XCTAssertFalse(surface.showsFullScreenToggleButton)
        try await wait("The system AVKit timeline is available") { timeline() != nil }
        func volumeSlider() -> NSObject? {
            controls().first {
                attribute($0, "accessibilityRole") as? String == "AXSlider"
                    && (attribute($0, "accessibilityMinValue") as? NSNumber)?.doubleValue == 0
                    && (attribute($0, "accessibilityMaxValue") as? NSNumber)?.doubleValue == 1
            }
        }
        for (index, width) in [520, 360, 320, 220, 150].enumerated() {
            window.setContentSize(NSSize(width: width, height: 260))
            try await wait("A stable native audio layout at width \(width)") {
                host.layoutSubtreeIfNeeded()
                return abs(host.bounds.width - CGFloat(width)) < 1
                    && abs(surface.bounds.width - 520) < 1
                    && abs((surface.enclosingScrollView?.contentSize.width ?? 0) - CGFloat(width)) < 1
            }
            let scroll = try XCTUnwrap(surface.enclosingScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertTrue(mounted(AVPlayerView.self, in: host) === surface)
            XCTAssertTrue(surface.player === player)
            func reveal(_ fraction: CGFloat) {
                let clip = scroll.contentView
                let x = document.frame.minX + max(0, document.frame.width - clip.bounds.width) * fraction
                clip.scroll(to: CGPoint(x: x, y: clip.bounds.minY))
                scroll.reflectScrolledClipView(clip)
                window.displayIfNeeded()
            }
            func localFrame(_ element: NSObject) -> NSRect? {
                guard let frame = attribute(element, "accessibilityFrame") as? NSRect else { return nil }
                return surface.convert(window.convertFromScreen(frame), from: nil)
            }
            reveal(0.1)
            try await wait("Native volume is reachable by scrolling left at width \(width)") {
                guard let volume = volumeSlider(), let rect = localFrame(volume) else { return false }
                return surface.visibleRect.insetBy(dx: -2, dy: -2).contains(rect)
            }
            let volume = try XCTUnwrap(volumeSlider())
            let targetVolume = 0.1 + Double(index) * 0.1
            volume.setValue(NSNumber(value: targetVolume), forKey: "accessibilityValue")
            try await wait("Native volume changes in the narrowed pane") { abs(Double(player.volume) - targetVolume) < 0.001 }
            reveal(0.5)
            try await wait("Native timeline is reachable at width \(width)") {
                guard let progress = timeline(), let rect = localFrame(progress) else { return false }
                return surface.visibleRect.intersection(rect).width > 60
            }
            let progress = try XCTUnwrap(timeline())
            let rect = try XCTUnwrap(localFrame(progress))
            print("AUDIO_AVKIT width=\(width) actual=\(surface.bounds.width) timeline=\(rect.width) visible=\(surface.visibleRect) volume=\(player.volume)")
            XCTAssertGreaterThanOrEqual(rect.width, 80)
            XCTAssertTrue(progress.responds(to: NSSelectorFromString("setAccessibilityValue:")))
            let targetTime = Double(index + 1)
            progress.setValue(NSNumber(value: targetTime), forKey: "accessibilityValue")
            try await wait("Native seek changes the actual player") {
                abs(player.currentTime().seconds - targetTime) < 0.1
            }
            // AVKit's main transport toggle is centered above the seek bar.
            // Locate that actual visible checkbox independently of localization.
            func transport() -> NSObject? {
                controls().first {
                    guard attribute($0, "accessibilityRole") as? String == "AXCheckBox",
                          let frame = localFrame($0),
                          let label = attribute($0, "accessibilityLabel") as? String else { return false }
                    return !label.isEmpty && abs(frame.midX - surface.bounds.midX) < 2
                        && frame.height > 18 && surface.visibleRect.contains(frame)
                }
            }
            try await wait("Native play/pause is reachable in the narrow pane") { transport() != nil }
            func pressTransport() throws {
                let element = try XCTUnwrap(transport())
                let selector = NSSelectorFromString("accessibilityPerformPress")
                guard element.responds(to: selector) else { return XCTFail("Missing native transport action") }
                typealias Action = @convention(c) (AnyObject, Selector) -> Bool
                // The AVKit proxy can return false even after changing the
                // player's state. The actual playback clock and rate below
                // are the required result, not this private proxy's BOOL.
                let reported = unsafeBitCast(element.method(for: selector), to: Action.self)(element, selector)
                print("AUDIO_AVKIT transport AXPress return=\(reported)")
            }
            player.isMuted = true
            try pressTransport()
            try await wait("Native play advances the actual clock") {
                player.rate > 0 && player.currentTime().seconds > targetTime + 0.1
            }
            try pressTransport()
            try await wait("Native pause stops the actual player") { player.rate == 0 }
        }
        window.setContentSize(NSSize(width: 520, height: 260))
        host.layoutSubtreeIfNeeded()
        try await wait("The system AVKit timeline is available") { timeline() != nil }
        for time in [9.0, 3.0, 4.49, 4.5, 4.51, 11.99, 0.0] {
            let accepted = await player.seek(to: CMTime(seconds: time, preferredTimescale: 1_000_000),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(accepted)
            let actual = player.currentTime().seconds
            try await wait("The native timeline must track the file player") {
                guard let element = timeline(), let value = attribute(element, "accessibilityValue") as? NSNumber
                else { return false }
                return abs(value.doubleValue - actual) < 0.05
            }
            XCTAssertEqual(player.rate, 0)
        }
        // Adjust the real, mounted slider without taking keyboard focus.
        player.isMuted = false
        player.volume = 0.5
        try await wait("Native volume slider") { volumeSlider() != nil }
        let volume = try XCTUnwrap(volumeSlider())
        XCTAssertTrue(volume.responds(to: NSSelectorFromString("setAccessibilityValue:")))
        for value in [0.2, 0.75, 0.35] {
            volume.setValue(NSNumber(value: value), forKey: "accessibilityValue")
            try await wait("Native volume adjusts actual player to \(value)") {
                guard let slider = volumeSlider(), let actual = attribute(slider, "accessibilityValue") as? NSNumber else { return false }
                return abs(Double(player.volume) - value) < 0.001 && abs(actual.doubleValue - Double(player.volume)) < 0.001
            }
            XCTAssertEqual(player.rate, 0)
        }
        // AVKit's floating timeline AXValue can remain at the last seek while
        // the native elapsed-time label and actual player time keep advancing.
        // Verify both directions of the transport separately, without inventing
        // a replacement timeline or treating the requested seek as playback.
        func elapsedTime() -> Double? {
            // AVKit's local AX objects do not expose the English external AX
            // label. This 12-second fixture has an elapsed clock, a negative
            // remaining clock, and the fixed duration. Require a unique
            // nonnegative clock strictly below duration, not an arbitrary label.
            let candidates = controls().compactMap { element -> Double? in
                guard attribute(element, "accessibilityRole") as? String == "AXStaticText",
                      let value = attribute(element, "accessibilityValue") as? String else { return nil }
                let fields = value.split(separator: ":")
                let parts = fields.compactMap { Double($0) }
                guard (fields.count == 2 || fields.count == 3), parts.count == fields.count,
                      parts.allSatisfy({ $0 >= 0 }) else { return nil }
                let seconds = parts.reduce(0) { $0 * 60 + $1 }
                return seconds < duration.rounded() ? seconds : nil
            }
            return candidates.count == 1 ? candidates.first : nil
        }
        player.isMuted = true
        let accepted = await player.seek(to: CMTime(seconds: 4, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(accepted)
        try await wait("The native elapsed-time label reflects the paused seek") {
            elapsedTime() == 4
        }
        player.play()
        defer { player.pause() }
        try await wait("Actual audio playback and its native elapsed time both advance") {
            guard let elapsed = elapsedTime() else { return false }
            let actual = player.currentTime().seconds
            return player.rate == 1 && actual >= 6 && elapsed >= 6 && abs(elapsed - actual) <= 1.1
        }
        print("AUDIO_CLOCK playing=\(player.currentTime().seconds) elapsed=\(String(describing: elapsedTime())) slider=\(String(describing: timeline().flatMap { attribute($0, "accessibilityValue") }))")
        player.pause()
        let pausedAt = player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(player.currentTime().seconds, pausedAt, accuracy: 0.05)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(try XCTUnwrap(elapsedTime()), pausedAt.rounded(.down), accuracy: 1)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testNativeEncodingVariantsRetainTheirFullTimelineAndChannelLayout() async throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_MEDIA_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_MEDIA_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        let source = URL(fileURLWithPath: root).appending(path: "media/音频-定位.wav")
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let formats: [(name: String, options: [String], format: AudioFormatID, channels: Int, bits: Int?)] = [
            ("Mono24.wav", ["-f", "WAVE", "-d", "LEI24", "-c", "1"], kAudioFormatLinearPCM, 1, 24),
            ("Surround32.wav", ["-f", "WAVE", "-d", "LEI32", "-c", "6"], kAudioFormatLinearPCM, 6, 32),
            ("Lossless.flac", ["-f", "flac", "-d", "flac"], kAudioFormatFLAC, 2, nil),
            ("Variable.aac", ["-f", "adts", "-d", "aac", "-s", "3", "-u", "vbrq", "65"], kAudioFormatMPEG4AAC, 2, nil),
        ]
        for format in formats {
            let file = directory.appending(path: format.name)
            try await Self.encode(source, to: file, options: format.options)
            let bytes = try Data(contentsOf: file)
            let media = try await NativeMedia.open(file.path)
            XCTAssertEqual(media.kind, .audio)
            let tracks = try await media.asset.loadTracks(withMediaType: .audio)
            let descriptions = try await XCTUnwrap(tracks.first).load(.formatDescriptions)
            let description = try XCTUnwrap(descriptions.first.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription))
            XCTAssertEqual(description.pointee.mFormatID, format.format)
            XCTAssertEqual(Int(description.pointee.mChannelsPerFrame), format.channels)
            if let bits = format.bits { XCTAssertEqual(Int(description.pointee.mBitsPerChannel), bits) }
            let duration = try await media.asset.load(.duration)
            XCTAssertEqual(duration.seconds, 12, accuracy: 0.1, format.name)

            let item = AVPlayerItem(asset: media.asset)
            let player = AVPlayer(playerItem: item)
            defer { player.replaceCurrentItem(with: nil) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while item.status == .unknown, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(item.status, .readyToPlay, format.name)
            let target = CMTime(value: 11, timescale: 1)
            let moved = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(moved, format.name)
            XCTAssertEqual(player.currentTime().seconds, 11, accuracy: 0.05, format.name)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    @concurrent private static func encode(_ source: URL, to file: URL, options: [String]) async throws {
        let encoder = Process()
        encoder.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        encoder.arguments = options + [source.path, file.path]
        try encoder.run()
        encoder.waitUntilExit()
        guard encoder.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
