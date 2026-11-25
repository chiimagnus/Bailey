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
        try await wait("The file exposes the native timeline") { timeline() != nil }
        let bar = try XCTUnwrap(mounted(FileAudioControls.Bar.self, in: host))
        XCTAssertTrue(bar.player === player)
        XCTAssertNil(mounted(AVPlayerView.self, in: host), "Audio must never mount a movie canvas")
        for width in [520, 220, 150] {
            window.setContentSize(NSSize(width: width, height: 260))
            host.layoutSubtreeIfNeeded()
            for slider in bar.arrangedSubviews.compactMap({ $0 as? NSSlider }) {
                XCTAssertFalse(slider.isHiddenOrHasHiddenAncestor)
                XCTAssertGreaterThan(slider.bounds.width, 10)
                XCTAssertTrue(bar.bounds.insetBy(dx: -1, dy: -1).contains(bar.convert(slider.bounds, from: slider)))
            }
        }
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
        func volumeSlider() -> NSObject? {
            controls().first {
                attribute($0, "accessibilityRole") as? String == "AXSlider"
                    && (attribute($0, "accessibilityMinValue") as? NSNumber)?.doubleValue == 0
                    && (attribute($0, "accessibilityMaxValue") as? NSNumber)?.doubleValue == 1
            }
        }
        try await wait("Native volume slider") { volumeSlider() != nil }
        let volume = try XCTUnwrap(volumeSlider())
        XCTAssertTrue(volume.responds(to: NSSelectorFromString("setAccessibilityValue:")))
        for value in [0.2, 0.75, 0.35] {
            let slider = try XCTUnwrap(volume as? NSSlider)
            slider.doubleValue = value
            XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
            try await wait("Native volume adjusts actual player to \(value)") {
                guard let slider = volumeSlider(), let actual = attribute(slider, "accessibilityValue") as? NSNumber else { return false }
                return abs(Double(player.volume) - value) < 0.001 && abs(actual.doubleValue - Double(player.volume)) < 0.001
            }
            XCTAssertEqual(player.rate, 0)
        }
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
