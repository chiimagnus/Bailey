import AppKit
import AVFoundation
import AVKit
import SwiftUI
import Foundation
import XCTest
@testable import Bailey

@MainActor
final class NativeAudioTimingTests: XCTestCase {
    func testWaveformMeasuresPCMTimeBucketsAndKeepsTheExistingPlayer() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (rate, channels) in [(8_000, 1), (44_100, 2), (48_000, 6)] {
            let url = directory.appending(path: "Waveform-\(rate)-\(channels).wav")
            let format: AVAudioFormat
            if channels == 6 {
                let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
                format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channelLayout: layout)
            } else {
                format = try XCTUnwrap(AVAudioFormat(
                    standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels)
                ))
            }
            do {
                let writer = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 4)
                ))
                buffer.frameLength = buffer.frameCapacity
                let samples = try XCTUnwrap(buffer.floatChannelData)
                for channel in 0..<channels {
                    let polarity: Float = channel.isMultiple(of: 2) ? 1 : -1
                    for frame in 0..<rate * 4 {
                        let value: Float
                        switch frame / rate {
                        case 0: value = 0
                        case 1: value = frame.isMultiple(of: 2) ? 0.25 : -0.25
                        case 2: value = frame == 2 * rate ? 0.875 : 0
                        default: value = Float(0.5 * sin(2 * .pi * 100 * Double(frame) / Double(rate)))
                        }
                        samples[channel][frame] = polarity * value
                    }
                }
                try writer.write(from: buffer)
            }

            let original = try Data(contentsOf: url)
            let media = try await NativeMedia.open(url.path)
            let item = AVPlayerItem(asset: media.asset)
            let player = AVPlayer(playerItem: item)
            defer { player.replaceCurrentItem(with: nil) }

            let result = try await NativeAudioWaveform.read(media, bucketCount: 4)
            XCTAssertEqual(result.duration, 4, accuracy: 0.001)
            XCTAssertEqual(result.interval, 0..<4)
            XCTAssertEqual(result.buckets.count, 4)
            XCTAssertEqual(result.buckets[0].peak, 0, accuracy: 0.0001)
            XCTAssertEqual(result.buckets[0].rms, 0, accuracy: 0.0001)
            XCTAssertEqual(result.buckets[1].peak, 0.25, accuracy: 0.001)
            XCTAssertEqual(result.buckets[1].rms, 0.25, accuracy: 0.001)
            XCTAssertEqual(result.buckets[2].peak, 0.875, accuracy: 0.001)
            XCTAssertEqual(result.buckets[2].rms, 0.875 / sqrt(Float(rate)), accuracy: 0.0001)
            XCTAssertEqual(result.buckets[3].peak, 0.5, accuracy: 0.001)
            XCTAssertEqual(result.buckets[3].rms, 0.5 / sqrt(2), accuracy: 0.001)

            let detail = try await NativeAudioWaveform.read(media, interval: 2..<3, bucketCount: 8)
            XCTAssertEqual(detail.interval, 2..<3)
            XCTAssertEqual(detail.buckets.first?.peak, 0.875)
            XCTAssertTrue(detail.buckets.dropFirst().allSatisfy { $0.peak == 0 && $0.rms == 0 })
            XCTAssertTrue(player.currentItem === item)
            XCTAssertTrue(item.asset === media.asset)
            XCTAssertEqual(try Data(contentsOf: url), original)
            if channels == 1 {
                let dense = try await NativeAudioWaveform.read(
                    media, interval: 2..<2.01, bucketCount: NativeAudioWaveform.maximumBuckets
                )
                XCTAssertEqual(dense.buckets.count, 100_000)
                XCTAssertEqual(dense.buckets.filter { $0.peak > 0 }.count, 1)
                XCTAssertEqual(dense.buckets.first?.peak, 0.875)
                do {
                    _ = try await NativeAudioWaveform.read(media, bucketCount: NativeAudioWaveform.maximumBuckets + 1)
                    XCTFail("An unbounded summary must be refused")
                } catch WorkspaceError.tooLarge {}
            }

            let cancelled = Task { try await NativeAudioWaveform.read(media, bucketCount: 256) }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                XCTFail("A cancelled summary must not publish")
            } catch is CancellationError {}
            XCTAssertTrue(player.currentItem === item)
            // A replacement with equal bytes is still a different source identity.
            try original.write(to: url, options: .atomic)
            do {
                _ = try await NativeAudioWaveform.read(media, bucketCount: 4)
                XCTFail("An old media source must not publish a new waveform")
            } catch WorkspaceError.changedExternally {}
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testWaveformTimeObservationFollowsPausedNativeSeeksAndStopsOnCancellation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Waveform.m4a")
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

        try await wait("The file's own AVPlayer must be ready") {
            file.mediaPlayer?.currentItem?.status == .readyToPlay
        }
        let player = try XCTUnwrap(file.mediaPlayer)
        let item = try XCTUnwrap(player.currentItem)
        player.isMuted = true
        XCTAssertEqual(player.rate, 0)

        var observed: [Double] = []
        let observer = Task {
            await NativeAudioWaveformView.observePlaybackTime(of: player) { observed.append($0) }
        }
        defer { observer.cancel() }
        try await wait("The waveform receives the native time on activation") {
            observed.last.map { abs($0) < 0.05 } ?? false
        }
        for seconds in [8.0, 2.0, 10.0, 0.0] {
            let accepted = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                                            toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(accepted)
            XCTAssertEqual(player.currentTime().seconds, seconds, accuracy: 0.05)
            try await wait("Waveform observation must follow the paused seek") {
                observed.last.map { abs($0 - seconds) < 0.05 } ?? false
            }
            XCTAssertTrue(file.mediaPlayer === player)
            XCTAssertTrue(player.currentItem === item)
        }

        try await Task.sleep(for: .milliseconds(200))
        let countWhilePaused = observed.count
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(observed.count, countWhilePaused,
                       "A stationary paused player needs no waveform refresh")
        observer.cancel()
        await observer.value
        let countAfterCancellation = observed.count
        let accepted = await player.seek(to: CMTime(seconds: 4, preferredTimescale: 600),
                                        toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(accepted)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(observed.count, countAfterCancellation)
        XCTAssertEqual(player.currentTime().seconds, 4, accuracy: 0.05)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testMountedWaveformAndNativePlayerExposeTheSameActualSeekTime() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Waveform.m4a")
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
        let host = NSHostingView(rootView: VStack(spacing: 8) {
            NativeAudioWaveformView(file: file, media: media, player: player, active: true)
                .frame(height: 72).padding(.horizontal, 12)
            NativePlayerView(player: player, controlsStyle: .floating, isDockActive: true)
                .frame(height: 112)
        })
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
        func waveform() -> NSObject? { control("bailey.audio.waveform") }
        func timeline() -> NSObject? { control("timeline") }
        try await wait("The waveform and native AVKit timeline must exist") {
            waveform() != nil && timeline() != nil
        }
        for time in [9.0, 3.0, 4.49, 4.5, 4.51, 11.99, 0.0] {
            let accepted = await player.seek(to: CMTime(seconds: time, preferredTimescale: 1_000_000),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(accepted)
            let actual = player.currentTime().seconds
            try await wait("Waveform AX slider must follow the native player at \(actual)") {
                guard let element = waveform(), attribute(element, "accessibilityRole") as? String == "AXSlider",
                      let value = attribute(element, "accessibilityValue") as? NSNumber,
                      let native = timeline(), let nativeValue = attribute(native, "accessibilityValue") as? NSNumber
                else { return false }
                return abs(value.doubleValue - actual) < 0.01 && abs(nativeValue.doubleValue - actual) < 0.05
            }
            let element = try XCTUnwrap(waveform())
            XCTAssertEqual((attribute(element, "accessibilityMinValue") as? NSNumber)?.doubleValue, 0)
            XCTAssertEqual(try XCTUnwrap(attribute(element, "accessibilityMaxValue") as? NSNumber).doubleValue, duration, accuracy: 0.000_001)
            let description = attribute(element, "accessibilityValueDescription") as? String
            print("AUDIT_WAVEFORM_AX time=\(actual) value=\(String(describing: attribute(element, "accessibilityValue"))) description=\(String(describing: description)) label=\(String(describing: attribute(element, "accessibilityLabel")))")
            XCTAssertEqual(description, Duration.seconds(actual).formatted(.time(pattern: .hourMinuteSecond)))
            XCTAssertEqual(player.rate, 0)
        }
        // Native AX adjustments must seek the same player, not merely update a
        // mirror of its accessible value. No foreground keyboard is required.
        let start = await player.seek(to: CMTime(seconds: 6, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(start)
        try await wait("The slider accepts the player's new time") {
            guard let element = waveform(), let value = attribute(element, "accessibilityValue") as? NSNumber else { return false }
            return abs(value.doubleValue - 6) < 0.01
        }
        for (name, direction) in [("accessibilityPerformIncrement", 1.0), ("accessibilityPerformDecrement", -1.0)] {
            let element = try XCTUnwrap(waveform())
            let before = player.currentTime().seconds
            let selector = NSSelectorFromString(name)
            XCTAssertTrue(element.responds(to: selector))
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            let invoke = unsafeBitCast(element.method(for: selector), to: Action.self)
            XCTAssertTrue(invoke(element, selector))
            try await wait("Native AX action \(name) must change AVPlayer time and update AXValue") {
                let actual = player.currentTime().seconds
                guard let current = waveform(), let value = attribute(current, "accessibilityValue") as? NSNumber else { return false }
                return abs(actual - (before + direction * duration / 20)) < 0.01 && abs(value.doubleValue - actual) < 0.01
            }
            XCTAssertEqual(player.rate, 0)
            print("AUDIT_WAVEFORM_AX action=\(name) time=\(player.currentTime().seconds)")
        }
        // The system volume slider must operate the same real player, even
        // though its pointer geometry is controlled by AVKit. Playback is paused.
        player.isMuted = false
        player.volume = 0.5
        func volumeSlider() -> NSObject? {
            controls().first {
                attribute($0, "accessibilityRole") as? String == "AXSlider"
                    && (attribute($0, "accessibilityMinValue") as? NSNumber)?.doubleValue == 0
                    && (attribute($0, "accessibilityMaxValue") as? NSNumber)?.doubleValue == 1
            }
        }
        try await wait("Native AVKit volume slider") { volumeSlider() != nil }
        let volume = try XCTUnwrap(volumeSlider())
        XCTAssertTrue(volume.responds(to: NSSelectorFromString("setAccessibilityValue:")))
        for value in [0.2, 0.75, 0.35] {
            volume.setValue(NSNumber(value: value), forKey: "accessibilityValue")
            try await wait("Native AVKit volume adjusts actual player to \(value)") {
                guard let slider = volumeSlider(), let actual = attribute(slider, "accessibilityValue") as? NSNumber else { return false }
                return abs(Double(player.volume) - value) < 0.001 && abs(actual.doubleValue - Double(player.volume)) < 0.001
            }
            print("AUDIT_AVKIT_VOLUME player=\(player.volume) ax=\(String(describing: attribute(volume, "accessibilityValue")))")
            XCTAssertEqual(player.rate, 0)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testWaveformViewportKeepsAnchoredTimeAndClampsAtFileEnds() {
        var viewport = AudioWaveformViewport(duration: 14_400)
        let anchor = viewport.time(at: 0.75)
        viewport.zoom(by: 16, anchor: 0.75)
        XCTAssertEqual(viewport.time(at: 0.75), anchor, accuracy: 0.000_001)
        XCTAssertEqual(viewport.interval.upperBound - viewport.interval.lowerBound, 900, accuracy: 0.000_001)
        viewport.move(by: 100)
        XCTAssertEqual(viewport.interval.upperBound, 14_400)
        XCTAssertEqual(viewport.time(at: 2), 14_400)
        viewport.move(by: -100)
        XCTAssertEqual(viewport.interval.lowerBound, 0)
        XCTAssertEqual(viewport.time(at: -1), 0)
        viewport.zoom(by: 1_000_000, anchor: 0.5)
        XCTAssertEqual(viewport.interval.upperBound - viewport.interval.lowerBound, 0.1, accuracy: 0.000_001)
        viewport.zoom(by: 0.000_000_1, anchor: 0)
        XCTAssertEqual(viewport.interval, 0..<14_400)
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
            let waveform = try await NativeAudioWaveform.read(media, interval: 10..<12, bucketCount: 256)
            XCTAssertEqual(waveform.interval, 10..<12, format.name)
            XCTAssertEqual(waveform.buckets.count, 256, format.name)
            XCTAssertGreaterThan(waveform.buckets.map(\.peak).max() ?? 0, 0.01, format.name)
            XCTAssertTrue(waveform.buckets.allSatisfy { $0.rms.isFinite && $0.rms <= $0.peak + 0.0001 }, format.name)
            XCTAssertTrue(player.currentItem === item)
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
