import AVFoundation
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
