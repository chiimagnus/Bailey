import AVFoundation
import Foundation
import XCTest
@testable import Bailey

@MainActor
final class NativeAudioTimingTests: XCTestCase {
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
