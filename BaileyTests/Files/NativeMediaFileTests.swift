import AppKit
import AVFoundation
import AVKit
import CryptoKit
import CoreVideo
import Darwin
import Foundation
import MediaToolbox
import os
import SwiftUI
import VideoToolbox
import XCTest
@testable import Bailey

@MainActor
final class NativeMediaFileTests: XCTestCase {
    @MainActor private final class CaptionProbe: NSObject, AVPlayerItemLegibleOutputPushDelegate {
        private(set) var received: [(String, CMTime)] = []

        nonisolated func legibleOutput(
            _ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
            nativeSampleBuffers: [Any], forItemTime itemTime: CMTime
        ) {
            let caption = strings.map(\.string).joined(separator: "\n")
            guard !caption.isEmpty else { return }
            MainActor.assumeIsolated { received.append((caption, itemTime)) }
        }
    }

    func testFileTabAcceptsRealWAVBeforeTheTextReadLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for size in [96_000, 32 << 20, 64 << 20, 256 << 20] {
            let file = directory.appending(path: "录音 \(size).WAV")
            try Self.createWAV(file, payloadBytes: size)
            let asset = AVURLAsset(url: file)
            let baseline = try await asset.load(.isPlayable, .duration)
            XCTAssertTrue(baseline.0)
            XCTAssertEqual(baseline.1.seconds, Double(size) / 96_000, accuracy: 0.001)
            let tab = FileTab(path: file.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await load(tab)
            guard case .media(let media) = tab.content else {
                return XCTFail("Valid media (\(size) PCM bytes) must not hit the text reader")
            }
            XCTAssertEqual(media.kind, .audio)
            let displayedDuration = try await media.asset.load(.duration)
            XCTAssertEqual(displayedDuration.seconds, baseline.1.seconds, accuracy: 0.001)
            XCTAssertEqual(media.asset.url.path, try Self.canonicalPath(file))
            XCTAssertEqual(media.identity.size, Int64(size + 44))
            XCTAssertTrue(tab.mediaPlayer?.currentItem?.asset === media.asset)
            XCTAssertTrue(tab.text.isEmpty)
            XCTAssertFalse(tab.isDirty)
            tab.retireContent()
        }
    }

    func testFourHourPCMRecordingSeeksToActualEndSamplesWithoutWholeFileLoading() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "四小时录音.wav")
        let seconds = 4 * 60 * 60
        let sampleRate = 48_000
        let bytesPerSecond = sampleRate * 2
        let payloadBytes = seconds * bytesPerSecond
        try Self.createWAV(url, payloadBytes: payloadBytes)
        // A real PCM timeline: silent sparse regions and different tone markers at
        // the beginning, midpoint and end. No fake duration or padded container.
        let markers = [(0, 440.0), (seconds / 2, 660.0), (seconds - 1, 880.0)]
        let tones: [(Int, Data)] = markers.map { offset, frequency in
            var pcm = Data(capacity: bytesPerSecond)
            for frame in 0..<sampleRate {
                var sample = Int16(12_000 * sin(2 * .pi * frequency * Double(frame) / Double(sampleRate))).littleEndian
                withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
            }
            return (offset, pcm)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            for (offset, pcm) in tones {
                try handle.seek(toOffset: UInt64(44 + offset * bytesPerSecond))
                try handle.write(contentsOf: pcm)
            }
        }
        let original = try await Self.checksum(url)
        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(size, payloadBytes + 44)
        let residentBefore = Self.residentMiB()
        var before = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        let start = ContinuousClock.now
        let project = Project(fallbackName: "Four hour recording", workspaceConfiguration: .standard)
        defer { project.closeAll() }
        project.openLocalFile(url.path)
        guard case .file(let tab)? = project.focusedContent else { return XCTFail("Missing file tab") }
        try await load(tab)
        guard case .media(let media) = tab.content else { return XCTFail("Long PCM must bypass text and staging limits") }
        XCTAssertEqual(media.kind, .audio)
        XCTAssertEqual(media.asset.url.path, try Self.canonicalPath(url))
        XCTAssertEqual(media.identity.size, Int64(size))
        XCTAssertTrue(tab.text.isEmpty)
        XCTAssertFalse(tab.isDirty)
        let duration = try await media.asset.load(.duration)
        XCTAssertEqual(duration.seconds, Double(seconds), accuracy: 0.001)
        let tracks = try await media.asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let player = try XCTUnwrap(tab.mediaPlayer)
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(item.asset === media.asset)
        player.isMuted = true
        try await waitUntil { item.status != .unknown }
        XCTAssertEqual(item.status, .readyToPlay)
        for (offset, expected) in tones {
            let target = CMTime(value: Int64(offset), timescale: 1)
            let moved = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(moved)
            XCTAssertEqual(player.currentTime().seconds, Double(offset), accuracy: 0.02)
            let reader = try AVAssetReader(asset: media.asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(output)
            reader.timeRange = CMTimeRange(start: target, duration: CMTime(value: 1, timescale: 1))
            XCTAssertTrue(reader.startReading(), String(describing: reader.error))
            var decoded = Data()
            while let sample = output.copyNextSampleBuffer() {
                let buffer = try XCTUnwrap(sample.dataBuffer)
                var pcm = Data(count: CMBlockBufferGetDataLength(buffer))
                let copied = pcm.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: bytes.count,
                                               destination: bytes.baseAddress!)
                }
                XCTAssertEqual(copied, kCMBlockBufferNoErr)
                decoded.append(pcm)
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(decoded, expected, "Decoded PCM must match the actual marker at \(offset)s")
        }
        player.play()
        try await waitUntil { player.currentTime().seconds > Double(seconds - 1) + 0.025 }
        player.pause()
        var after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        let residentAfter = Self.residentMiB()
        print("MEDIA_FOUR_HOURS bytes=\(size) duration=\(duration.seconds) elapsed=\(start.duration(to: .now)) maxrss_delta=\(after.ru_maxrss - before.ru_maxrss) resident_mib=\(residentBefore)->\(residentAfter)")
        XCTAssertLessThan(after.ru_maxrss - before.ru_maxrss, size / 2)
        project.closeAll()
        XCTAssertNil(player.currentItem)
        XCTAssertNil(tab.mediaPlayer)
        let checksum = try await Self.checksum(url)
        XCTAssertEqual(checksum, original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
    }

    func testDamagedMediaWithIntactMetadataIsRejectedAndCanRecover() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".github/features")
        for (sample, type) in [("audio-file-playback/demo-audio.m4a", AVMediaType.audio),
                               ("video-file-playback/demo-video.mp4", .video)] {
            let original = try Data(contentsOf: fixtures.appending(path: sample))
            // Preserve the fast-start track index while removing or corrupting the sample payload.
            let marker = try XCTUnwrap(original.range(of: Data("mdat".utf8)))
            XCTAssertNotNil(original[..<marker.lowerBound].range(of: Data("moov".utf8)))
            let atomStart = marker.lowerBound - 4
            let atomSize = original[atomStart..<marker.lowerBound].reduce(0) { ($0 << 8) | Int($1) }
            XCTAssertEqual(atomStart + atomSize, original.count)
            let header = Data(original[..<marker.upperBound])
            let corrupt = header + Data(repeating: 0, count: original.count - header.count)
            for (name, bytes, hasPayload) in [("截断", header, false), ("损坏", corrupt, true)] {
                let url = directory.appending(path: name + "-" + URL(fileURLWithPath: sample).lastPathComponent)
                try bytes.write(to: url)
                let asset = AVURLAsset(url: url)
                if hasPayload {
                    let playable = try await asset.load(.isPlayable)
                    XCTAssertTrue(playable, "The corrupted fixture must still pass AVAsset metadata checks")
                }
                var foundPayload = false
                if let tracks = try? await asset.loadTracks(withMediaType: type), let track = tracks.first,
                   let reader = try? AVAssetReader(asset: asset) {
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                    if reader.canAdd(output) {
                        reader.add(output)
                        if reader.startReading() {
                            while let buffer = output.copyNextSampleBuffer() {
                                if buffer.numSamples > 0, let data = buffer.dataBuffer,
                                   CMBlockBufferGetDataLength(data) > 0 {
                                    foundPayload = true
                                    break
                                }
                            }
                        }
                        reader.cancelReading()
                    }
                }
                XCTAssertEqual(foundPayload, hasPayload, "The fixture must distinguish encoded bytes from decoded media")
                let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
                defer { tab.retireContent() }
                try await load(tab)
                if case .unavailable = tab.content {} else {
                    XCTFail("A container without decodable samples must be unavailable: \(url.lastPathComponent)")
                }
                XCTAssertNil(tab.mediaPlayer)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                let resource = PreviewResource(path: directory.appending(path: "Preview.md").path,
                                               directory: directory.path, backend: LocalWorkspaceBackend.shared)
                var relative = URLComponents()
                relative.path = url.lastPathComponent
                let reference = try XCTUnwrap(relative.url)
                let staged = try await MarkdownMedia.stage(reference, from: resource)
                defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
                XCTAssertEqual(try Data(contentsOf: staged), bytes)
                do {
                    _ = try await NativeMedia.open(staged.path)
                    XCTFail("The shared Markdown reader must reject undecodable media samples")
                } catch NativeMedia.Failure.unsupported {}
                let prior = tab.reloadRevision
                try original.write(to: url, options: .atomic)
                tab.reloadFromDiskIfClean()
                try await waitUntil { if case .media = tab.content { return tab.reloadRevision != prior }; return false }
                let item = try XCTUnwrap(tab.mediaPlayer?.currentItem)
                try await waitUntil { item.status != .unknown }
                XCTAssertEqual(item.status, .readyToPlay)
                let recovered = try await MarkdownMedia.stage(reference, from: resource)
                defer { try? FileManager.default.removeItem(at: recovered.deletingLastPathComponent()) }
                let embedded = try await NativeMedia.open(recovered.path)
                XCTAssertEqual(embedded.kind, type == .audio ? .audio : .video)
                XCTAssertEqual(try Data(contentsOf: recovered), original)
                XCTAssertEqual(try Data(contentsOf: url), original)
            }
        }
    }

    func testUndecodableVideoWithIntactAudioDoesNotMasqueradeAsAnAudioFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".github/features/video-file-playback/demo-video.mp4")
        let original = try Data(contentsOf: fixture)
        let source = AVURLAsset(url: fixture)
        let tracks = try await source.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: source)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading(), String(describing: reader.error))
        var damaged = original
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = sample.dataBuffer else { continue }
            let count = CMBlockBufferGetDataLength(buffer)
            guard count > 0 else { continue }
            var packet = Data(count: count)
            let status = packet.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: count,
                                           destination: bytes.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            let range = try XCTUnwrap(original.range(of: packet))
            XCTAssertNil(original.range(of: packet, in: range.upperBound..<original.endIndex),
                         "The fixture must identify actual video samples unambiguously")
            damaged.replaceSubrange(range, with: Data(repeating: 0, count: count))
            sampleCount += 1
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(sampleCount, 10)
        XCTAssertEqual(damaged.count, original.count)
        let url = directory.appendingPathComponent("Corrupt video with valid audio.mp4")
        try damaged.write(to: url)

        let corrupt = AVURLAsset(url: url)
        let playable = try await corrupt.load(.isPlayable)
        XCTAssertTrue(playable, "Valid audio and track metadata must still satisfy the metadata-only check")
        for type in [AVMediaType.video, .audio] {
            let candidates = try await corrupt.loadTracks(withMediaType: type)
            let track = try XCTUnwrap(candidates.first)
            let decodable = try await track.load(.isDecodable)
            XCTAssertTrue(decodable, "Codec metadata is valid even when all video payloads are damaged")
            let decoder = try AVAssetReader(asset: corrupt)
            let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: type == .video
                ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                : [AVFormatIDKey: kAudioFormatLinearPCM])
            XCTAssertTrue(decoder.canAdd(decoded))
            decoder.add(decoded)
            XCTAssertTrue(decoder.startReading(), String(describing: decoder.error))
            defer { decoder.cancelReading() }
            var found = false
            while let sample = decoded.copyNextSampleBuffer() {
                guard sample.numSamples > 0 else { continue }
                if type == .video, sample.imageBuffer != nil { found = true; break }
                if type == .audio, let data = sample.dataBuffer, CMBlockBufferGetDataLength(data) > 0 {
                    found = true
                    break
                }
            }
            XCTAssertEqual(found, type == .audio)
        }

        let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        defer { tab.retireContent() }
        try await load(tab)
        if case .unavailable = tab.content {} else {
            XCTFail("A container with an existing but undecodable video track is not an audio-only file")
        }
        XCTAssertNil(tab.mediaPlayer)
        let resource = PreviewResource(path: directory.appendingPathComponent("Media.md").path,
                                       directory: directory.path, backend: LocalWorkspaceBackend.shared)
        var components = URLComponents()
        components.path = url.lastPathComponent
        let staged = try await MarkdownMedia.stage(try XCTUnwrap(components.url), from: resource)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        do {
            _ = try await NativeMedia.open(staged.path)
            XCTFail("The shared Markdown AVAsset validator must reject the damaged video")
        } catch NativeMedia.Failure.unsupported {}
        XCTAssertEqual(try Data(contentsOf: staged), damaged)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        try original.write(to: url, options: .atomic)
        tab.reloadFromDiskIfClean()
        try await waitUntil {
            if case .media(let media) = tab.content { return media.kind == .video }
            return false
        }
        XCTAssertNotNil(tab.mediaPlayer)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try Data(contentsOf: fixture), original)
    }

    func testMarkdownMediaStagesExactByteBoundaryButStandaloneCanOpenBeyondIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".github/features/audio-file-playback/demo-audio.m4a")
        let original = try Data(contentsOf: fixture)
        let resource = PreviewResource(path: directory.appendingPathComponent("Media.md").path,
                                       directory: directory.path, backend: LocalWorkspaceBackend.shared)
        let limit = 64 << 20
        for size in [limit - 1, limit, limit + 1] {
            let source = directory.appendingPathComponent("boundary-\(size).m4a")
            // A real ISO media free box extends a playable M4A to the exact
            // byte boundary without corrupting the track index or samples.
            try original.write(to: source)
            let handle = try FileHandle(forWritingTo: source)
            try handle.seekToEnd()
            var length = UInt32(size - original.count).bigEndian
            let header = withUnsafeBytes(of: &length) { Data($0) } + Data("free".utf8)
            try handle.write(contentsOf: header)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
            let before = try await Self.checksum(source)
            let tab = FileTab(path: source.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            defer { tab.retireContent() }
            try await load(tab)
            guard case .media(let media) = tab.content else {
                return XCTFail("A valid independent M4A must remain playable at \(size) bytes")
            }
            XCTAssertEqual(media.kind, .audio)
            XCTAssertEqual(media.identity.size, Int64(size))
            XCTAssertEqual(media.asset.url.path, try Self.canonicalPath(source))
            let reference = try XCTUnwrap(URL(string: source.lastPathComponent))
            if size <= limit {
                let staged = try await MarkdownMedia.stage(reference, from: resource)
                defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
                XCTAssertNotEqual(staged.path, source.path)
                let stagedChecksum = try await Self.checksum(staged)
                XCTAssertEqual(stagedChecksum, before)
                let embedded = try await NativeMedia.open(staged.path)
                XCTAssertEqual(embedded.kind, .audio)
                XCTAssertEqual(embedded.identity.size, Int64(size))
            } else {
                do {
                    _ = try await MarkdownMedia.stage(reference, from: resource)
                    XCTFail("Markdown may not stage a file larger than its exact 64 MiB limit")
                } catch WorkspaceError.tooLarge {}
            }
            let after = try await Self.checksum(source)
            XCTAssertEqual(after, before)
        }
    }

    func testProtectedNativeMediaIsRejectedBeforePlaybackAndRecoversAfterReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = PreviewResource(path: directory.appending(path: "Preview.md").path,
                                       directory: directory.path, backend: LocalWorkspaceBackend.shared)
        for (ext, type, fixture) in [
            ("m4a", AVMediaType.audio, NativeProtectedMediaFixtures.m4a),
            ("mp4", AVMediaType.video, NativeProtectedMediaFixtures.mp4),
        ] {
            let encrypted = try XCTUnwrap(Data(base64Encoded: fixture.encrypted, options: .ignoreUnknownCharacters))
            let plain = try XCTUnwrap(Data(base64Encoded: fixture.plain, options: .ignoreUnknownCharacters))
            XCTAssertNotEqual(encrypted, plain)
            let url = directory.appendingPathComponent("Protected." + ext)
            try encrypted.write(to: url)
            let asset = AVURLAsset(url: url)
            let (playable, protected, duration) = try await asset.load(.isPlayable, .hasProtectedContent, .duration)
            XCTAssertTrue(playable, "The fixture must pass the metadata-only playable check")
            XCTAssertTrue(protected, "AVFoundation must identify genuinely encrypted media")
            XCTAssertGreaterThan(duration.seconds, 0)
            let tracks = try await asset.loadTracks(withMediaType: type)
            XCTAssertFalse(tracks.isEmpty)

            let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            defer { tab.retireContent() }
            try await load(tab)
            guard case .unavailable = tab.content else {
                return XCTFail("Protected media must not publish an independent player")
            }
            XCTAssertNil(tab.mediaPlayer)
            XCTAssertTrue(tab.text.isEmpty)
            XCTAssertFalse(tab.isDirty)
            XCTAssertEqual(try Data(contentsOf: url), encrypted)

            let reference = try XCTUnwrap(URL(string: url.lastPathComponent))
            let staged = try await MarkdownMedia.stage(reference, from: resource)
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            XCTAssertEqual(try Data(contentsOf: staged), encrypted)
            do {
                _ = try await NativeMedia.open(staged.path)
                XCTFail("The shared embedded-media path must refuse protected content")
            } catch NativeMedia.Failure.unsupported {}
            XCTAssertEqual(try Data(contentsOf: staged), encrypted)
            XCTAssertEqual(try Data(contentsOf: url), encrypted)

            // Replace with the actual unencrypted source of the CENC fixture,
            // not a different or metadata-only file.
            try plain.write(to: url, options: .atomic)
            let clearAsset = AVURLAsset(url: url)
            let (clearPlayable, clearProtected) = try await clearAsset.load(.isPlayable, .hasProtectedContent)
            XCTAssertTrue(clearPlayable)
            XCTAssertFalse(clearProtected)
            tab.reloadFromDiskIfClean()
            try await waitUntil { tab.mediaPlayer != nil }
            guard case .media(let media) = tab.content else { return XCTFail("Unprotected replacement must load") }
            XCTAssertEqual(media.kind, type == .audio ? .audio : .video)
            let item = try XCTUnwrap(tab.mediaPlayer?.currentItem)
            try await waitUntil { item.status != .unknown }
            XCTAssertEqual(item.status, .readyToPlay)
            let recovered = try await MarkdownMedia.stage(reference, from: resource)
            defer { try? FileManager.default.removeItem(at: recovered.deletingLastPathComponent()) }
            let embedded = try await NativeMedia.open(recovered.path)
            XCTAssertEqual(embedded.kind, media.kind)
            XCTAssertEqual(try Data(contentsOf: recovered), plain)
            XCTAssertEqual(try Data(contentsOf: url), plain)
            XCTAssertEqual(try Data(contentsOf: staged), encrypted, "The previous staged version is immutable")
        }
    }

    func testUnsupportedNativeCodecsKeepRealTrackMetadataButNeverPublishAPlayer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".github/features/audio-file-playback/demo-audio.m4a")
        let video = directory.appending(path: "Original.mov")
        try await createVideoFixture(video, size: CGSize(width: 240, height: 240))
        for (source, type, codec) in [(audio, AVMediaType.audio, "mp4a"), (video, .video, "avc1")] {
            let original = try Data(contentsOf: source)
            let marker = try XCTUnwrap(original.range(of: Data("stsd".utf8)))
            let entry = marker.upperBound + 8
            // Retain the complete container, sample table, track metadata and
            // compressed payload. Change only the one sample description type.
            XCTAssertGreaterThanOrEqual(marker.lowerBound, 4)
            let boxSize = Int(original[marker.lowerBound - 4..<marker.lowerBound].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            let entryCount = original[entry - 4..<entry].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            XCTAssertEqual(entryCount, 1)
            let entrySize = Int(original[entry..<entry + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            XCTAssertGreaterThanOrEqual(entrySize, 8)
            XCTAssertLessThanOrEqual(entry + entrySize, marker.lowerBound - 4 + boxSize)
            let codecRange = (entry + 4)..<(entry + 8)
            XCTAssertEqual(Data(original[codecRange]), Data(codec.utf8))
            var unsupported = original
            unsupported.replaceSubrange(codecRange, with: Data("zzzz".utf8))
            let url = directory.appendingPathComponent("Unsupported." + source.pathExtension)
            try unsupported.write(to: url)
            let reference = AVURLAsset(url: url)
            let tracks = try await reference.loadTracks(withMediaType: type)
            let track = try XCTUnwrap(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(descriptions.first)), 0x7a7a7a7a)
            let (playable, protected) = try await reference.load(.isPlayable, .hasProtectedContent)
            let (decodable, contained) = try await track.load(.isDecodable, .isSelfContained)
            XCTAssertFalse(playable)
            XCTAssertFalse(protected)
            XCTAssertFalse(decodable)
            XCTAssertTrue(contained)
            let duration = try await reference.load(.duration)
            XCTAssertGreaterThan(duration.seconds, 0)
            let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            defer { tab.retireContent() }
            try await load(tab)
            guard case .unavailable = tab.content else { return XCTFail("Unsupported codec must not create a player") }
            XCTAssertNil(tab.mediaPlayer)
            XCTAssertTrue(tab.text.isEmpty)
            let resource = PreviewResource(path: directory.appendingPathComponent("Preview.md").path,
                                           directory: directory.path, backend: LocalWorkspaceBackend.shared)
            let staged = try await MarkdownMedia.stage(try XCTUnwrap(URL(string: url.lastPathComponent)), from: resource)
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            XCTAssertEqual(try Data(contentsOf: staged), unsupported)
            do {
                _ = try await NativeMedia.open(staged.path)
                XCTFail("Markdown must use the same actual codec validation")
            } catch NativeMedia.Failure.unsupported {}
            XCTAssertEqual(try Data(contentsOf: url), unsupported)

            try original.write(to: url, options: .atomic)
            XCTAssertEqual(chmod(url.path, 0o400), 0)
            defer { _ = chmod(url.path, 0o600) }
            tab.reloadFromDiskIfClean()
            try await waitUntil { tab.mediaPlayer != nil }
            let item = try XCTUnwrap(tab.mediaPlayer?.currentItem)
            try await waitUntil { item.status != .unknown }
            XCTAssertEqual(item.status, .readyToPlay)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testTrackKindUsesRealContainersAndLocalSymlinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".github/features")
        let audio = document.appending(path: "audio-file-playback/demo-audio.m4a")
        let video = document.appending(path: "video-file-playback/demo-video.mp4")
        let audioInMP4 = directory.appending(path: "仅音轨.mp4")
        try FileManager.default.copyItem(at: audio, to: audioInMP4)
        let linked = directory.appending(path: "影片.MOV")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: video)
        let aiff = directory.appending(path: "正弦.aiff")
        let caf = directory.appending(path: "正弦.CAF")
        for url in [aiff, caf] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                                      channels: 2, interleaved: true))
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 48_000))
            samples.frameLength = 48_000
            for channel in 0..<Int(samples.format.channelCount) {
                let signal = try XCTUnwrap(samples.floatChannelData?[channel])
                for frame in 0..<Int(samples.frameLength) {
                    signal[frame] = Float(0.1 * sin(2 * .pi * 440 * Double(frame) / 48_000))
                }
            }
            try writer.write(from: samples)
        }
        for (url, kind, duration) in [(audio, NativeMedia.Kind.audio, 12.0), (audioInMP4, .audio, 12.0),
                                      (linked, .video, 8.0), (aiff, .audio, 1.0), (caf, .audio, 1.0)] {
            let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await load(tab)
            guard case .media(let media) = tab.content else { return XCTFail("Unreadable sample: \(url.lastPathComponent)") }
            XCTAssertEqual(media.kind, kind)
            let displayedDuration = try await media.asset.load(.duration)
            XCTAssertEqual(displayedDuration.seconds, duration, accuracy: 0.05)
            XCTAssertEqual(media.asset.url.path, try Self.canonicalPath(url))
            tab.retireContent()
        }
    }

    func testFileTabDecodesFramesFromNativeHEVCProResAndM4VExports() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".github/features/video-file-playback/demo-video.mp4")
        let source = AVURLAsset(url: sample)
        let exports: [(name: String, preset: String, type: AVFileType, codec: FourCharCode)] = [
            ("节选-HEVC.mp4", AVAssetExportPresetHEVCHighestQuality, .mp4, kCMVideoCodecType_HEVC),
            ("节选-ProRes.MOV", AVAssetExportPresetAppleProRes422LPCM, .mov, kCMVideoCodecType_AppleProRes422),
            ("节选-H264.m4v", AVAssetExportPresetPassthrough, .m4v, kCMVideoCodecType_H264),
        ]
        for export in exports {
            let destination = directory.appending(path: export.name)
            let session = try XCTUnwrap(AVAssetExportSession(asset: source, presetName: export.preset))
            session.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
            try await session.export(to: destination, as: export.type)
            let original = try Data(contentsOf: destination)
            let tab = FileTab(path: destination.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await load(tab)
            guard case .media(let media) = tab.content else { return XCTFail("Cannot load \(export.name)") }
            XCTAssertEqual(media.kind, .video)
            XCTAssertTrue(tab.mediaPlayer?.currentItem?.asset === media.asset)
            let tracks = try await media.asset.loadTracks(withMediaType: .video)
            let descriptions = try await XCTUnwrap(tracks.first).load(.formatDescriptions)
            XCTAssertTrue(descriptions.contains { CMFormatDescriptionGetMediaSubType($0) == export.codec })
            let generator = AVAssetImageGenerator(asset: media.asset)
            let output = try await generator.image(at: CMTime(value: 1, timescale: 2))
            XCTAssertGreaterThan(output.image.width, 100)
            XCTAssertGreaterThan(output.image.height, 100)
            XCTAssertTrue(output.actualTime.isNumeric)
            tab.retireContent()
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }

    func testRealAudioFormatsSeekAndDecodeAudibleSamplesWithoutChangingTheSource() async throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_MEDIA_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_MEDIA_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        let directory = URL(fileURLWithPath: root).appending(path: "media")
        let formats: [(String, AudioFormatID)] = [
            ("mp3", kAudioFormatMPEGLayer3), ("m4a", kAudioFormatMPEG4AAC),
            ("wav", kAudioFormatLinearPCM), ("aiff", kAudioFormatLinearPCM), ("caf", kAudioFormatLinearPCM),
        ]
        for (suffix, format) in formats {
            let url = directory.appending(path: "音频-定位.\(suffix)")
            let original = try Data(contentsOf: url)
            let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            defer { tab.retireContent() }
            try await load(tab)
            guard case .media(let media) = tab.content else { return XCTFail("Cannot open \(url.lastPathComponent)") }
            XCTAssertEqual(media.kind, .audio)
            XCTAssertEqual(media.asset.url.path, try Self.canonicalPath(url))
            let duration = try await media.asset.load(.duration)
            XCTAssertEqual(duration.seconds, 12, accuracy: 0.05)
            let tracks = try await media.asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(tracks.count, 1)
            let track = try XCTUnwrap(tracks.first)
            let formats = try await track.load(.formatDescriptions)
            let description = try XCTUnwrap(formats.first.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription))
            XCTAssertEqual(description.pointee.mFormatID, format)
            XCTAssertEqual(description.pointee.mChannelsPerFrame, 2)

            let player = try XCTUnwrap(tab.mediaPlayer)
            let item = try XCTUnwrap(player.currentItem)
            XCTAssertTrue(item.asset === media.asset)
            try await waitUntil { item.status != .unknown }
            XCTAssertEqual(item.status, .readyToPlay)
            let target = CMTime(value: 7, timescale: 1)
            let moved = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(moved)
            XCTAssertEqual(player.currentTime().seconds, 7, accuracy: 0.02)
            XCTAssertEqual(player.rate, 0)

            let reader = try AVAssetReader(asset: media.asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(output)
            reader.timeRange = CMTimeRange(start: target, duration: CMTime(value: 1, timescale: 4))
            XCTAssertTrue(reader.startReading(), String(describing: reader.error))
            let samples = try XCTUnwrap(output.copyNextSampleBuffer())
            XCTAssertGreaterThan(samples.numSamples, 0)
            let block = try XCTUnwrap(samples.dataBuffer)
            var decoded = Data(count: CMBlockBufferGetDataLength(block))
            let copied = try decoded.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count,
                                           destination: try XCTUnwrap(bytes.baseAddress))
            }
            XCTAssertEqual(copied, kCMBlockBufferNoErr)
            XCTAssertTrue(decoded.contains { $0 != 0 }, "The real seek target must contain decoded audio")
            reader.cancelReading()
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testLargeNativeMovieSeeksIntoTheFinalSegmentWithoutStagingOrEditing() async throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_MEDIA_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_MEDIA_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = URL(fileURLWithPath: root).appending(path: "media/视频-ProRes.mov")
        let source = AVURLAsset(url: sample)
        let duration = try await source.load(.duration)
        XCTAssertEqual(duration.seconds, 4, accuracy: 0.001)
        let clip = CMTimeRange(start: .zero, duration: duration)
        let repeats: Int32 = 128
        let composition = AVMutableComposition()
        for index in 0..<repeats {
            try await composition.insertTimeRange(clip, of: source, at: CMTimeMultiply(duration, multiplier: index))
        }
        let url = directory.appending(path: "长视频 — ProRes.MOV")
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: url, as: .mov)
        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(size, 256 << 20)
        let original = try await Self.checksum(url)
        var before = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        let start = ContinuousClock.now

        let project = Project(fallbackName: "Large movie", workspaceConfiguration: .standard)
        defer { project.closeAll() }
        project.openLocalFile(url.path)
        guard case .file(let tab)? = project.focusedContent else { return XCTFail("Missing file tab") }
        try await load(tab)
        guard case .media(let media) = tab.content else { return XCTFail("The movie must bypass the text limit") }
        XCTAssertEqual(media.kind, .video)
        XCTAssertEqual(media.asset.url.path, try Self.canonicalPath(url))
        XCTAssertEqual(media.identity.size, Int64(size))
        let actualDuration = try await media.asset.load(.duration)
        XCTAssertEqual(actualDuration.seconds, 512, accuracy: 0.05)
        XCTAssertTrue(tab.text.isEmpty)
        XCTAssertFalse(tab.isDirty)
        let player = try XCTUnwrap(tab.mediaPlayer)
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(item.asset === media.asset)
        try await waitUntil { item.status != .unknown }
        XCTAssertEqual(item.status, .readyToPlay)
        let target = CMTime(value: 510, timescale: 1)
        let moved = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(moved)
        XCTAssertEqual(player.currentTime().seconds, target.seconds, accuracy: 0.07)
        let generator = AVAssetImageGenerator(asset: media.asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: target)
        let expected = try await AVAssetImageGenerator(asset: source).image(at: CMTime(value: 2, timescale: 1))
        XCTAssertEqual(image.actualTime.seconds, target.seconds, accuracy: 0.07)
        XCTAssertEqual(image.image.width, 640)
        XCTAssertEqual(image.image.height, 480)
        let pixels = try XCTUnwrap(image.image.dataProvider?.data) as Data
        let expectedPixels = try XCTUnwrap(expected.image.dataProvider?.data) as Data
        XCTAssertEqual(pixels, expectedPixels)
        var after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        print("MEDIA_LARGE bytes=\(size) seek_seconds=\(image.actualTime.seconds) elapsed=\(start.duration(to: .now)) maxrss_before=\(before.ru_maxrss) maxrss_after=\(after.ru_maxrss)")
        XCTAssertLessThan(after.ru_maxrss - before.ru_maxrss, size / 2)

        project.closeAll()
        XCTAssertNil(player.currentItem)
        XCTAssertNil(tab.mediaPlayer)
        let checksum = try await Self.checksum(url)
        XCTAssertEqual(checksum, original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
    }

    func testTwoHourVideoSeeksToRealEncodedFramesWithoutStaging() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let shortURL = directory.appending(path: "source.mov")
        try await createVideoFixture(shortURL, size: CGSize(width: 96, height: 64), frameCount: 300)
        let source = AVURLAsset(url: shortURL)
        let segmentDuration = try await source.load(.duration)
        XCTAssertEqual(segmentDuration.seconds, 30, accuracy: 0.11)
        let composition = AVMutableComposition()
        let segmentCount: Int32 = 240
        for index in 0..<segmentCount {
            try await composition.insertTimeRange(
                CMTimeRange(start: .zero, duration: segmentDuration),
                of: source, at: CMTimeMultiply(segmentDuration, multiplier: index)
            )
        }
        let url = directory.appending(path: "两小时视频.mp4")
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: url, as: .mp4)
        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let original = try await Self.checksum(url)
        let start = ContinuousClock.now
        let project = Project(fallbackName: "Long video", workspaceConfiguration: .standard)
        defer { project.closeAll() }
        project.openLocalFile(url.path)
        guard case .file(let tab)? = project.focusedContent else { return XCTFail("Missing file tab") }
        try await load(tab)
        guard case .media(let media) = tab.content else { return XCTFail("Expected playable long video") }
        XCTAssertEqual(media.kind, .video)
        XCTAssertEqual(media.asset.url.path, try Self.canonicalPath(url))
        XCTAssertEqual(media.identity.size, Int64(size))
        let duration = try await media.asset.load(.duration)
        XCTAssertEqual(duration.seconds, segmentDuration.seconds * Double(segmentCount), accuracy: 0.11)
        XCTAssertGreaterThan(duration.seconds, 7_150)
        let player = try XCTUnwrap(tab.mediaPlayer)
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(item.asset === media.asset)
        try await waitUntil { item.status != .unknown }
        XCTAssertEqual(item.status, .readyToPlay)
        let generator = AVAssetImageGenerator(asset: media.asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Passthrough must retain the encoded video; independently opening the
        // exported container is the pixel reference for AVPlayer's asset.
        func firstEncodedSample(_ asset: AVAsset) async throws -> Data {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset: asset)
            defer { reader.cancelReading() }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            XCTAssertTrue(reader.startReading(), String(describing: reader.error))
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = sample.dataBuffer else { continue }
                let length = CMBlockBufferGetDataLength(buffer)
                guard length > 0 else { continue }
                var bytes = Data(count: length)
                let status = bytes.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                }
                XCTAssertEqual(status, kCMBlockBufferNoErr)
                return bytes
            }
            throw WorkspaceError.notFound
        }
        let referenceAsset = AVURLAsset(url: url)
        let originalSample = try await firstEncodedSample(source)
        let exportedSample = try await firstEncodedSample(referenceAsset)
        XCTAssertEqual(originalSample, exportedSample)
        let referenceGenerator = AVAssetImageGenerator(asset: referenceAsset)
        referenceGenerator.requestedTimeToleranceBefore = .zero
        referenceGenerator.requestedTimeToleranceAfter = .zero
        let reference = try await referenceGenerator.image(at: CMTime(value: 2, timescale: 1))
        func displayPixels(_ image: CGImage) throws -> Data {
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            var bytes = Data(count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let expectedPixels = try displayPixels(reference.image)
        for index in [Int32(0), segmentCount / 2, segmentCount - 1, 0] {
            let target = CMTimeAdd(CMTimeMultiply(segmentDuration, multiplier: index), CMTime(value: 2, timescale: 1))
            let moved = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(moved)
            XCTAssertEqual(player.currentTime().seconds, target.seconds, accuracy: 0.11)
            let frame = try await generator.image(at: target)
            XCTAssertEqual(frame.actualTime.seconds, target.seconds, accuracy: 0.11)
            XCTAssertEqual(frame.image.width, 96)
            XCTAssertEqual(frame.image.height, 64)
            let pixels = try displayPixels(frame.image)
            XCTAssertEqual(pixels, expectedPixels)
        }
        print("MEDIA_TWO_HOURS bytes=\(size) duration=\(duration.seconds) elapsed=\(start.duration(to: .now))")
        XCTAssertFalse(tab.isDirty)
        XCTAssertTrue(tab.text.isEmpty)
        project.closeAll()
        XCTAssertNil(tab.mediaPlayer)
        XCTAssertNil(player.currentItem)
        let checksum = try await Self.checksum(url)
        XCTAssertEqual(checksum, original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set([shortURL.lastPathComponent, url.lastPathComponent]))
    }

    func testRepeatedPlaybackAndProjectCloseReleaseNativePlayersAcrossMediaKinds() async throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_MEDIA_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_MEDIA_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        let directory = URL(fileURLWithPath: root)
        let samples: [(URL, NativeMedia.Kind)] = [
            (directory.appending(path: "边界测试/257MiB静音.wav"), .audio),
            (directory.appending(path: "media/音频-定位.mp3"), .audio),
            (directory.appending(path: "media/视频-ProRes.mov"), .video),
        ]
        let size = try XCTUnwrap(samples[0].0.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(size, 256 << 20)
        var original: [SHA256.Digest] = []
        for (url, _) in samples { original.append(try await Self.checksum(url)) }
        let project = Project(fallbackName: "Repeated native media", workspaceConfiguration: .standard)
        defer { project.closeAll() }
        let formerPlayers = NSHashTable<AVPlayer>.weakObjects()
        var before = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        let start = ContinuousClock.now
        let initialResident = Self.residentMiB()
        var residentCurve: [Double] = []

        for index in 0..<100 {
            let (url, kind) = samples[index % samples.count]
            project.openLocalFile(url.path)
            guard case .file(let tab)? = project.focusedContent else { return XCTFail("Missing media tab \(index)") }
            try await load(tab)
            guard case .media(let media) = tab.content else { return XCTFail("Unreadable media on cycle \(index)") }
            XCTAssertEqual(media.kind, kind)
            XCTAssertEqual(media.asset.url.path, try Self.canonicalPath(url))
            let player = try XCTUnwrap(tab.mediaPlayer)
            let item = try XCTUnwrap(player.currentItem)
            XCTAssertTrue(item.asset === media.asset)
            XCTAssertFalse(formerPlayers.contains(player))
            formerPlayers.add(player)
            player.isMuted = true
            try await waitUntil { item.status != .unknown }
            XCTAssertEqual(item.status, .readyToPlay)

            let duration = try await media.asset.load(.duration)
            if index % samples.count == 0 { XCTAssertEqual(duration.seconds, 1403.562667, accuracy: 0.001) }
            let target = CMTime(seconds: duration.seconds - 1, preferredTimescale: 600)
            let moved = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(moved)
            XCTAssertEqual(player.currentTime().seconds, target.seconds, accuracy: 0.07)
            player.play()
            try await waitUntil { player.currentTime().seconds > target.seconds + 0.025 }
            player.pause()
            XCTAssertEqual(player.rate, 0)

            if index.isMultiple(of: 2) { player.play() }
            project.closeAll()
            XCTAssertTrue(project.tabs.isEmpty)
            XCTAssertNil(tab.mediaPlayer)
            XCTAssertNil(player.currentItem)
            XCTAssertEqual(player.rate, 0)
            if (index + 1).isMultiple(of: 10) { residentCurve.append(Self.residentMiB()) }
        }

        try await waitUntil { formerPlayers.allObjects.isEmpty }
        var after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        func cpuSeconds(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        print("MEDIA_REOPEN cycles=100 elapsed=\(start.duration(to: .now)) cpu_seconds=\(cpuSeconds(after) - cpuSeconds(before)) maxrss_before=\(before.ru_maxrss) maxrss_after=\(after.ru_maxrss) resident_mib_initial=\(initialResident) resident_mib_every_10=\(residentCurve) resident_mib_after_release=\(Self.residentMiB()) remaining_players=\(formerPlayers.allObjects.count)")
        for ((url, _), checksum) in zip(samples, original) {
            let actual = try await Self.checksum(url)
            XCTAssertEqual(actual, checksum)
        }
    }

    func testRapidVideoSeeksDisplayTheFinalDecodedFrameAtFixedAndVariableRates() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for variable in [false, true] {
            let url = root.appending(path: variable ? "variable.mov" : "fixed.mov")
            try await createVideoFixture(url, size: CGSize(width: 96, height: 64), frameCount: 60,
                                         alternatingFrames: true, variableTiming: variable)
            let original = try await Self.checksum(url)
            let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            defer { tab.retireContent() }
            try await load(tab)
            guard case .media(let media) = tab.content else { return XCTFail("Cannot open seek fixture") }
            let player = try XCTUnwrap(tab.mediaPlayer)
            let item = try XCTUnwrap(player.currentItem)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            item.add(output)
            defer { item.remove(output) }
            player.isMuted = true
            try await waitUntil { item.status != .unknown }
            XCTAssertEqual(item.status, .readyToPlay)
            let duration = try await media.asset.load(.duration).seconds
            XCTAssertGreaterThan(duration, 5)
            let tracks = try await media.asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset: media.asset)
            let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(samples)
            XCTAssertTrue(reader.startReading())
            var timestamps: [Double] = []
            while let sample = samples.copyNextSampleBuffer() {
                // Some readers return an empty end-marker with an invalid PTS.
                guard sample.numSamples > 0 else { continue }
                XCTAssertTrue(sample.presentationTimeStamp.isNumeric)
                if sample.presentationTimeStamp.isNumeric {
                    timestamps.append(sample.presentationTimeStamp.seconds)
                }
            }
            XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
            timestamps.sort()
            let differences = Set(zip(timestamps, timestamps.dropFirst()).map { Int((($1 - $0) * 1000).rounded()) })
            XCTAssertEqual(timestamps.count, 60)
            XCTAssertEqual(differences.count, variable ? 2 : 1)
            for (target, expectRed) in [(0.5, true), (duration - 0.9, false), (0.5, true)] {
                player.pause()
                // Enqueue conflicting forward/backward seeks before any completion is observed.
                for second in [duration - 0.5, 0.2, duration / 2, 0.1, duration - 1] {
                    player.seek(to: CMTime(seconds: second, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
                }
                let time = CMTime(seconds: target, preferredTimescale: 600)
                let finished = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                XCTAssertTrue(finished)
                XCTAssertEqual(player.currentTime().seconds, target, accuracy: 0.12)
                // Inspect a frame decoded by the actual player, not an independent image generator.
                var decoded: CVPixelBuffer?
                var displayed = CMTime.invalid
                player.playImmediately(atRate: 0.5)
                try await waitUntil {
                    let now = player.currentTime()
                    guard let buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &displayed) else { return false }
                    decoded = buffer
                    return true
                }
                player.pause()
                let frame = try XCTUnwrap(decoded)
                XCTAssertTrue(displayed.isNumeric)
                XCTAssertGreaterThanOrEqual(displayed.seconds, target - 0.16)
                XCTAssertLessThan(displayed.seconds, target + 0.7)
                XCTAssertEqual(CVPixelBufferLockBaseAddress(frame, .readOnly), kCVReturnSuccess)
                defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
                let pixel = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
                let offset = 32 * CVPixelBufferGetBytesPerRow(frame) + 24 * 4
                let red = Int(pixel[offset + 2]), green = Int(pixel[offset + 1])
                XCTAssertGreaterThan(expectRed ? red - green : green - red, 80)
                XCTAssertTrue(player.currentItem === item)
                XCTAssertEqual(player.rate, 0)
            }
            let actual = try await Self.checksum(url)
            XCTAssertEqual(actual, original)
            XCTAssertFalse(tab.isDirty)
        }
    }

    func testEmbeddedSubtitleSelectionEmitsTheActualChineseCue() async throws {
        guard let root = ProcessInfo.processInfo.environment["BAILEY_MEDIA_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set BAILEY_MEDIA_ACCEPTANCE_ROOT to the comprehensive sample directory")
        }
        let directory = URL(fileURLWithPath: root).appending(path: "media")
        let url = directory.appending(path: "视频-内置字幕.mp4")
        let original = try Data(contentsOf: url)
        let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        defer { tab.retireContent() }
        try await load(tab)
        guard case .media(let media) = tab.content else { return XCTFail("Cannot open the captioned movie") }
        XCTAssertEqual(media.kind, .video)
        let offered = try await media.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(offered)
        XCTAssertTrue(group.allowsEmptySelection)
        let chinese = try XCTUnwrap(group.options.first { $0.locale?.language.languageCode?.identifier == "zh" })
        let player = try XCTUnwrap(tab.mediaPlayer)
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(item.asset === media.asset)
        let output = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
        let probe = CaptionProbe()
        output.setDelegate(probe, queue: .main)
        item.add(output)
        player.isMuted = true
        try await waitUntil { item.status != .unknown }
        XCTAssertEqual(item.status, .readyToPlay)
        item.select(chinese, in: group)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group), chinese)
        let moved = await player.seek(to: CMTime(value: 48, timescale: 10), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(moved)
        player.play()
        try await waitUntil { probe.received.contains { $0.0 == "第三段：seek / 时间定位" } }
        let cue = try XCTUnwrap(probe.received.first { $0.0 == "第三段：seek / 时间定位" })
        XCTAssertEqual(cue.1.seconds, 5, accuracy: 0.07)
        player.pause()
        item.select(nil, in: group)
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
        XCTAssertEqual(try Data(contentsOf: url), original)

        let plain = AVURLAsset(url: directory.appending(path: "视频-ProRes.mov"))
        let noCaptions = try await plain.loadMediaSelectionGroup(for: .legible)
        XCTAssertNil(noCaptions)
    }

    func testNativeReferenceMoviesAreRejectedInFilesAndMarkdownAndCanRecover() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let workspace = directory.appending(path: "Project")
        let sibling = directory.appending(path: "Project copy")
        for folder in [workspace, sibling] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".github/features")
        let fixtures: [(URL, URL, NativeMedia.Kind, AVMediaType)] = [
            (repository.appending(path: "video-file-playback/demo-video.mp4"), sibling, .video, .video),
            (repository.appending(path: "audio-file-playback/demo-audio.m4a"), workspace, .audio, .audio),
        ]
        let resource = PreviewResource(path: workspace.appending(path: "Preview.md").path,
                                       directory: workspace.path, backend: LocalWorkspaceBackend.shared)
        for (index, fixture) in fixtures.enumerated() {
            let (original, folder, kind, trackType) = fixture
            let source = folder.appending(path: original.lastPathComponent)
            let bytes = try Data(contentsOf: original)
            try bytes.write(to: source)
            let reference = workspace.appending(path: "引用 \(index).mov")
            let movie = AVMovie(url: source)
            try movie.writeHeader(to: reference, fileType: .mov, options: .truncateDestinationToMovieHeaderOnly)
            let header = try Data(contentsOf: reference)
            XCTAssertGreaterThan(header.count, 0)
            XCTAssertLessThan(header.count, bytes.count / 4)
            let sample = AVURLAsset(url: reference)
            let referenceTracks = try await sample.loadTracks(withMediaType: trackType)
            let selfContained = try await XCTUnwrap(referenceTracks.first).load(.isSelfContained)
            XCTAssertFalse(selfContained, "The native fixture must actually depend on another file")

            let tab = FileTab(path: reference.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            defer { tab.retireContent() }
            try await load(tab)
            guard case .unavailable = tab.content else { return XCTFail("An external reference must not enter AVPlayer") }
            XCTAssertNil(tab.mediaPlayer)
            XCTAssertTrue(tab.text.isEmpty)
            var relative = URLComponents()
            relative.path = reference.lastPathComponent
            let staged = try await MarkdownMedia.stage(try XCTUnwrap(relative.url), from: resource)
            defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            XCTAssertEqual(try Data(contentsOf: staged), header)
            do {
                _ = try await NativeMedia.open(staged.path)
                XCTFail("An authorized Markdown reference file must not grant access to other media")
            } catch NativeMedia.Failure.unsupported {}
            XCTAssertEqual(try Data(contentsOf: reference), header)

            try bytes.write(to: reference, options: .atomic)
            tab.reloadFromDiskIfClean()
            try await waitUntil { tab.mediaPlayer != nil }
            guard case .media(let accepted) = tab.content else { return XCTFail("Replacing the header with real media must recover") }
            XCTAssertEqual(accepted.kind, kind)
            XCTAssertTrue(tab.mediaPlayer?.currentItem?.asset === accepted.asset)
            XCTAssertEqual(try Data(contentsOf: reference), bytes)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testNativeVideoControlsFitTheActualLandscapeAndRotatedVideoBounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let landscape = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".github/features/video-file-playback/demo-video.mp4")
        let asset = AVURLAsset(url: landscape)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)
        let composition = AVMutableComposition()
        let portraitTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid))
        let duration = try await asset.load(.duration)
        try portraitTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        portraitTrack.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: naturalSize.height, ty: 0)
        let portrait = directory.appending(path: "Portrait.mov")
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: portrait, as: .mov)

        func playerView(in view: NSView) -> AVPlayerView? {
            (view as? AVPlayerView) ?? view.subviews.lazy.compactMap { playerView(in: $0) }.first
        }
        let variants: [(name: String, coded: CGSize, displayed: CGSize, pixelAspect: CGSize, aperture: CGSize?)] = [
            ("Square", CGSize(width: 240, height: 240), CGSize(width: 240, height: 240), CGSize(width: 1, height: 1), nil),
            ("Wide", CGSize(width: 420, height: 180), CGSize(width: 420, height: 180), CGSize(width: 1, height: 1), nil),
            ("Anamorphic", CGSize(width: 360, height: 240), CGSize(width: 480, height: 240), CGSize(width: 4, height: 3), nil),
            ("Clean aperture", CGSize(width: 360, height: 240), CGSize(width: 320, height: 180), CGSize(width: 1, height: 1), CGSize(width: 320, height: 180)),
        ]
        var sources = [(landscape, naturalSize.width / naturalSize.height),
                       (portrait, naturalSize.height / naturalSize.width)]
        for variant in variants {
            let url = directory.appending(path: "\(variant.name).mov")
            try await createVideoFixture(url, size: variant.coded, pixelAspect: variant.pixelAspect, aperture: variant.aperture)
            let fixture = AVURLAsset(url: url)
            let fixtureTracks = try await fixture.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(fixtureTracks.first)
            let formats = try await track.load(.formatDescriptions)
            let format = try XCTUnwrap(formats.first)
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            XCTAssertEqual(Int(dimensions.width), Int(variant.coded.width))
            XCTAssertEqual(Int(dimensions.height), Int(variant.coded.height))
            let presentation = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
            XCTAssertEqual(presentation, variant.displayed)
            let frame = try await AVAssetImageGenerator(asset: fixture).image(at: .zero)
            XCTAssertEqual(frame.image.width, Int(variant.displayed.width))
            XCTAssertEqual(frame.image.height, Int(variant.displayed.height))
            sources.append((url, variant.displayed.width / variant.displayed.height))
        }
        let panelSizes = [CGSize(width: 800, height: 440), CGSize(width: 460, height: 680), CGSize(width: 240, height: 440)]
        for (url, ratio) in sources {
            let original = try Data(contentsOf: url)
            let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await load(tab)
            let player = try XCTUnwrap(tab.mediaPlayer)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: panelSizes[0]),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close(); tab.retireContent() }
            let host = NSHostingView(rootView: FileViewerView(file: tab))
            window.contentView = host
            window.orderBack(nil)
            try await waitUntil { playerView(in: host)?.videoBounds.width ?? 0 > 0 }
            let native = try XCTUnwrap(playerView(in: host))
            XCTAssertEqual(native.controlsStyle, .inline)
            for size in panelSizes {
                window.setContentSize(size)
                host.layoutSubtreeIfNeeded()
                let expectedWidth = min(size.width, size.height * ratio)
                let expectedHeight = expectedWidth / ratio
                try await waitUntil {
                    host.layoutSubtreeIfNeeded()
                    return abs(native.videoBounds.width - expectedWidth) < 1
                        && abs(native.videoBounds.height - expectedHeight) < 1
                }
                XCTAssertTrue(native === playerView(in: host))
                XCTAssertTrue(native.player === player)
                XCTAssertEqual(native.videoBounds.width / native.videoBounds.height, ratio, accuracy: 0.02)
                XCTAssertEqual(native.bounds.width, native.videoBounds.width, accuracy: 1)
                XCTAssertEqual(native.bounds.height, native.videoBounds.height, accuracy: 1)
                XCTAssertEqual(native.videoBounds.midX, native.bounds.midX, accuracy: 1)
                XCTAssertEqual(native.videoBounds.midY, native.bounds.midY, accuracy: 1)
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testNativePlayerAcceptsReal4KTenBitHDRAndRetainsTheEncodedSignal() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "HDR-PQ.mov")
        try await createVideoFixture(url, size: CGSize(width: 3840, height: 2160), hdr: true)
        let original = try Data(contentsOf: url)
        let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        defer { tab.retireContent() }
        try await load(tab)
        guard case .media(let media) = tab.content else { return XCTFail("Cannot load native HDR video") }
        XCTAssertEqual(media.kind, .video)
        XCTAssertEqual(try XCTUnwrap(media.videoAspectRatio), 16.0 / 9, accuracy: 0.001)
        let tracks = try await media.asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width, 3840)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).height, 2160)
        let metadata = try XCTUnwrap(CMFormatDescriptionGetExtensions(format) as? [String: Any])
        XCTAssertEqual(metadata["BitsPerComponent"] as? Int, 10)
        XCTAssertEqual(metadata[kCVImageBufferColorPrimariesKey as String] as? String, kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        XCTAssertEqual(metadata[kCVImageBufferTransferFunctionKey as String] as? String, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        XCTAssertEqual(metadata[kCVImageBufferYCbCrMatrixKey as String] as? String, kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        let player = try XCTUnwrap(tab.mediaPlayer)
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(item.asset === media.asset)
        try await waitUntil { item.status != .unknown }
        XCTAssertEqual(item.status, .readyToPlay)
        let moved = await player.seek(to: CMTime(value: 1, timescale: 10), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(moved)
        XCTAssertEqual(player.currentTime().seconds, 0.1, accuracy: 0.02)
        let reader = try AVAssetReader(asset: media.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        ])
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading(), String(describing: reader.error))
        defer { reader.cancelReading() }
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let buffer = try XCTUnwrap(sample.imageBuffer)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 3840)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 2160)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        XCTAssertEqual(Double(base[1080 * stride + 960] >> 6), 384, accuracy: 30)
        XCTAssertEqual(Double(base[1080 * stride + 2880] >> 6), 704, accuracy: 30)
        // Mount the real HDR item in Bailey’s native video surface as well as decoding it.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: FileViewerView(file: tab))
        host.sizingOptions = []
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        func mounted(_ view: NSView) -> AVPlayerView? {
            (view as? AVPlayerView) ?? view.subviews.lazy.compactMap(mounted).first
        }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return mounted(host)?.isReadyForDisplay == true
        }
        let native = try XCTUnwrap(mounted(host))
        XCTAssertTrue(native.player === player)
        XCTAssertEqual(native.videoBounds.width / native.videoBounds.height, 16.0 / 9, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    // A test-only tap on the AVPlayer's audio mix observes what the active
    // player actually decodes, rather than re-reading the fixture separately.
    nonisolated private final class AudioTapProbe: Sendable {
        struct Measurement: Sendable {
            var sampleRate = 0.0
            var stride = 0
            var frames = 0
            var lowPower = 0.0
            var highPower = 0.0
            var peak: Float = 0
        }
        let measurement = OSAllocatedUnfairLock(initialState: Measurement())

        @available(macOS 27.0, *)
        func makeTap() throws -> MTAudioProcessingTap {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let retained = Unmanaged.passRetained(self)
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: retained.toOpaque(),
                init: { _, info, storage in storage.pointee = info },
                finalize: { tap in
                    Unmanaged<AudioTapProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
                },
                prepare: { tap, _, format in
                    let probe = Unmanaged<AudioTapProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    let asbd = format.pointee
                    probe.measurement.withLock {
                        $0.sampleRate = asbd.mSampleRate
                        $0.stride = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
                            && asbd.mBitsPerChannel == 32
                            ? Int(asbd.mBytesPerFrame) / MemoryLayout<Float>.stride : 0
                    }
                },
                unprepare: nil,
                process: { tap, frames, _, buffers, delivered, flags in
                    guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, nil, delivered) == noErr,
                          delivered.pointee > 1 else { return }
                    let probe = Unmanaged<AudioTapProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    let format = probe.measurement.withLock { $0 }
                    guard format.stride > 0, format.sampleRate > 0,
                          let buffer = UnsafeMutableAudioBufferListPointer(buffers).first,
                          let data = buffer.mData else { return }
                    let count = min(delivered.pointee, Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride / format.stride)
                    guard count >= 256 else { return }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    // Compare spectral energy, not zero-crossings through
                    // silent padding at the ends of decoded audio buffers.
                    func power(_ frequency: Double) -> Double {
                        let coefficient = 2 * cos(2 * .pi * frequency / format.sampleRate)
                        var previous = 0.0, older = 0.0
                        for index in 0..<count {
                            let next = Double(samples[index * format.stride]) + coefficient * previous - older
                            older = previous
                            previous = next
                        }
                        return max(0, previous * previous + older * older - coefficient * previous * older)
                    }
                    let low = power(440), high = power(880)
                    let peak = (0..<count).reduce(Float(0)) { max($0, abs(samples[$1 * format.stride])) }
                    guard peak > 0.001 else { return }
                    probe.measurement.withLock {
                        $0.frames += count
                        $0.lowPower += low
                        $0.highPower += high
                        $0.peak = max($0.peak, peak)
                    }
                }
            )
            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreateWithPreferredFormat(kCFAllocatorDefault, &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects, format.formatDescription, &tap)
            guard status == noErr, let tap else {
                retained.release()
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return tap
        }
    }

    func testSelectableNativeAudioTracksDeliverTheChosenPCM() async throws {
        guard #available(macOS 27.0, *) else {
            throw XCTSkip("Mixed PCM output observation requires the macOS 27 audio tap API")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Alternate languages.mov")
        try FileManager.default.copyItem(at: root.appending(path: ".github/features/video-file-playback/demo-audio-tracks.mov"), to: url)
        let bytes = try Data(contentsOf: url)
        let project = Project(fallbackName: "Alternate audio", workspaceConfiguration: .standard)
        project.openLocalFile(url.path)
        guard case .file(let tab)? = project.focusedContent else { return XCTFail("Missing video") }
        defer { project.closeContent(.file(tab)) }
        let tabID = try XCTUnwrap(project.selectedTabID)
        try await load(tab)
        let player = try XCTUnwrap(tab.mediaPlayer)
        let item = try XCTUnwrap(player.currentItem)
        try await waitUntil { item.status != .unknown }
        XCTAssertEqual(item.status, .readyToPlay)
        let group = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let audio = try XCTUnwrap(group)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(Set(audio.options.compactMap(\.extendedLanguageTag)), ["en", "fr"])
        let probe = AudioTapProbe()
        let parameters = AVMutableAudioMixInputParameters()
        parameters.audioTapProcessor = try probe.makeTap()
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        player.volume = 0.05
        defer { player.pause(); item.audioMix = nil }
        for (language, seek) in [("en", 1.0), ("fr", 3.0), ("en", 5.0)] {
            player.pause()
            let option = try XCTUnwrap(audio.options.first { $0.extendedLanguageTag == language })
            item.select(option, in: audio)
            try await waitUntil { item.currentMediaSelection.selectedMediaOption(in: audio) == option }
            let accepted = await player.seek(to: CMTime(seconds: seek, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(accepted)
            XCTAssertEqual(player.currentTime().seconds, seek, accuracy: 0.05)
            XCTAssertEqual(player.rate, 0)
            probe.measurement.withLock { $0.frames = 0; $0.lowPower = 0; $0.highPower = 0; $0.peak = 0 }
            player.play()
            try await waitUntil { probe.measurement.withLock { $0.frames >= 24_000 } }
            player.pause()
            let signal = probe.measurement.withLock { $0 }
            print("AUDIO_SELECTION language=\(language) frames=\(signal.frames) sampleRate=\(signal.sampleRate) low=\(signal.lowPower) high=\(signal.highPower)")
            XCTAssertGreaterThan(signal.peak, 0.001)
            let wanted = language == "en" ? signal.lowPower : signal.highPower
            let unwanted = language == "en" ? signal.highPower : signal.lowPower
            XCTAssertGreaterThan(wanted, 16 * unwanted, "The selected tone must dominate the actual audio mix")
            XCTAssertGreaterThan(player.currentTime().seconds, seek)
            XCTAssertTrue(tab.mediaPlayer === player)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: audio), option)
        }
        // Switch without pausing; discard queued PCM from the old selection
        // only after the actual playback clock has advanced.
        let french = try XCTUnwrap(audio.options.first { $0.extendedLanguageTag == "fr" })
        let switchTime = player.currentTime().seconds
        player.play()
        try await waitUntil { player.currentTime().seconds > switchTime + 0.1 }
        let selectedAt = player.currentTime().seconds
        item.select(french, in: audio)
        try await waitUntil {
            item.currentMediaSelection.selectedMediaOption(in: audio) == french
                && player.currentTime().seconds > selectedAt + 0.5
        }
        probe.measurement.withLock { $0.frames = 0; $0.lowPower = 0; $0.highPower = 0; $0.peak = 0 }
        try await waitUntil { probe.measurement.withLock { $0.frames >= 24_000 } }
        let switched = probe.measurement.withLock { $0 }
        XCTAssertGreaterThan(switched.peak, 0.001)
        XCTAssertGreaterThan(switched.highPower, 16 * switched.lowPower)
        XCTAssertEqual(player.rate, 1)
        print("AUDIO_SELECTION playing-switch fr frames=\(switched.frames) low=\(switched.lowPower) high=\(switched.highPower)")

        // Another file must not take over this selected track or player.
        let otherURL = directory.appending(path: "Other.wav")
        try Self.createWAV(otherURL, payloadBytes: 96_000)
        project.openLocalFile(otherURL.path)
        XCTAssertEqual(player.rate, 0)
        let paused = player.currentTime().seconds
        guard case .file(let other)? = project.focusedContent else { return XCTFail("Missing other file") }
        defer { project.closeContent(.file(other)) }
        try await load(other)
        let otherPlayer = try XCTUnwrap(other.mediaPlayer)
        XCTAssertFalse(otherPlayer === player)
        project.selectTab(tabID)
        XCTAssertTrue(tab.mediaPlayer === player)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: audio), french)
        XCTAssertEqual(player.currentTime().seconds, paused, accuracy: 0.12)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testVideoWithTwoActualAudioTracksKeepsBothTracksAndSourceBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".github/features/video-file-playback/demo-video.mp4")
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videoTracks.first)
        let audio = try XCTUnwrap(audioTracks.first)
        let composition = AVMutableComposition()
        let targetVideo = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let duration = CMTime(value: 1, timescale: 1)
        try targetVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video, at: .zero)
        for second in [0, 2] {
            let targetAudio = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try targetAudio.insertTimeRange(CMTimeRange(start: CMTime(value: Int64(second), timescale: 1), duration: duration), of: audio, at: .zero)
        }
        let url = directory.appending(path: "双音轨.mov")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await exporter.export(to: url, as: .mov)
        let original = try Data(contentsOf: url)
        let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
        defer { tab.retireContent() }
        try await load(tab)
        guard case .media(let media) = tab.content else { return XCTFail("Cannot open dual audio video") }
        XCTAssertEqual(media.kind, .video)
        let player = try XCTUnwrap(tab.mediaPlayer)
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(item.asset === media.asset)
        let tracks = try await media.asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(Set(tracks.map(\.trackID)).count, 2)
        for track in tracks {
            let reader = try AVAssetReader(asset: media.asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            XCTAssertTrue(reader.canAdd(output))
            reader.add(output)
            XCTAssertTrue(reader.startReading(), String(describing: reader.error))
            defer { reader.cancelReading() }
            let sample = try XCTUnwrap(output.copyNextSampleBuffer())
            XCTAssertGreaterThan(sample.numSamples, 0)
            XCTAssertGreaterThan(CMBlockBufferGetDataLength(try XCTUnwrap(sample.dataBuffer)), 0)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testMediaRejectsCorruptMissingUnopenedAndRemoteFilesWithoutReadingTheirNamesakes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appending(path: "fake.wav")
        let original = Data("not media".utf8)
        try original.write(to: text)
        let empty = directory.appending(path: "empty.MP4")
        try Data().write(to: empty)
        let pipe = directory.appending(path: "pipe.aac")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let folder = directory.appending(path: "directory.mov")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let missing = directory.appending(path: "missing.aiff")
        let dangling = directory.appending(path: "dangling.flac")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
        let namesake = directory.appending(path: "here.wav")
        try Self.createWAV(namesake, payloadBytes: 96_000)
        let denied = directory.appending(path: "denied.wav")
        try FileManager.default.copyItem(at: namesake, to: denied)
        XCTAssertEqual(chmod(denied.path, 0), 0)
        defer { _ = chmod(denied.path, 0o600) }
        XCTAssertThrowsError(try FileHandle(forReadingFrom: denied))
        for url in [text, empty, pipe, folder, missing, dangling, denied, namesake] {
            let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared,
                              workspaceIdentity: url == namesake ? "ssh:other-machine" : nil)
            try await load(tab)
            guard case .unavailable = tab.content else { return XCTFail("Unexpected media route for \(url)") }
            XCTAssertNil(tab.mediaPlayer)
            XCTAssertTrue(tab.text.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: text), original)
    }

    func testMediaRefreshKeepsPositionAfterMetadataChangesButRejectsRewrittenBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".github/features")
        for name in ["video-file-playback/demo-video.mp4", "audio-file-playback/demo-audio.m4a"] {
            let original = try Data(contentsOf: fixtures.appending(path: name))
            let url = directory.appending(path: (name as NSString).lastPathComponent)
            try original.write(to: url)
            let tab = FileTab(path: url.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            defer { tab.retireContent() }
            try await load(tab)
            let player = try XCTUnwrap(tab.mediaPlayer)
            let item = try XCTUnwrap(player.currentItem)
            try await waitUntil { item.status == .readyToPlay }
            let sought: Bool = await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600),
                                                 toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(sought)
            var before = stat()
            XCTAssertEqual(stat(url.path, &before), 0)
            var value: UInt8 = 1
            XCTAssertEqual(setxattr(url.path, "com.example.BaileyTest", &value, 1, 0, 0), 0)
            var tagged = stat()
            XCTAssertEqual(stat(url.path, &tagged), 0)
            XCTAssertNotEqual([before.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec],
                              [tagged.st_ctimespec.tv_sec, tagged.st_ctimespec.tv_nsec])
            XCTAssertEqual(try Data(contentsOf: url), original)
            tab.refreshWhenSelected()
            // Join the FileTab's pending read. A media tab has no text to return.
            _ = try? await tab.waitForText()
            XCTAssertTrue(tab.mediaPlayer === player)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertEqual(tab.mediaPlayer?.currentTime().seconds ?? -1, 2, accuracy: 0.05)

            // Preserve inode, byte count and nanosecond mtime even as the content becomes invalid.
            let writer = try FileHandle(forWritingTo: url)
            try writer.write(contentsOf: Data(repeating: 0, count: original.count))
            try writer.close()
            var times = [before.st_atimespec, before.st_mtimespec]
            XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
            var rewritten = stat()
            XCTAssertEqual(stat(url.path, &rewritten), 0)
            XCTAssertEqual(rewritten.st_ino, before.st_ino)
            XCTAssertEqual(rewritten.st_size, before.st_size)
            XCTAssertEqual(rewritten.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
            XCTAssertEqual(rewritten.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
            tab.refreshWhenSelected()
            try await waitUntil { if case .unavailable = tab.content { true } else { false } }
            XCTAssertNil(tab.mediaPlayer)
            XCTAssertNil(player.currentItem)
        }
    }

    func testMediaMetadataChangeWhileTheFileIsMappedRequiresFreshValidation() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).wav")
        try Self.createWAV(url, payloadBytes: 96_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let media = try await NativeMedia.open(url.path)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let page = try XCTUnwrap(mmap(nil, 4096, PROT_READ, MAP_SHARED, handle.fileDescriptor, 0))
        guard page != MAP_FAILED else { return XCTFail("mmap failed: \(errno)") }
        defer { _ = munmap(page, 4096) }
        XCTAssertEqual(page.load(as: UInt8.self), 0x52) // Fault the RIFF header into the mapping.
        XCTAssertNil(try LocalWorkspaceBackend.readableFile(at: url.path, includingDataGeneration: true).dataGeneration)
        var value: UInt8 = 1
        XCTAssertEqual(setxattr(url.path, "com.example.BaileyTest", &value, 1, 0, 0), 0)
        let identifies = await NativeMedia.stillIdentifies(url.path, media: media)
        XCTAssertFalse(identifies)
        let reopened = try await NativeMedia.open(url.path, reusing: media)
        XCTAssertFalse(reopened.asset === media.asset)
    }

    func testMediaRefreshAndProjectCloseRetireTheObsoleteAVPlayerItem() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "sample.wav")
        try Self.createWAV(url, payloadBytes: 96_000)
        let project = Project(fallbackName: "Media lifecycle", workspaceConfiguration: .standard)
        project.openLocalFile(url.path)
        guard case .file(let tab)? = project.focusedContent else { return XCTFail("Missing real project tab") }
        try await load(tab)
        let oldPlayer = try XCTUnwrap(tab.mediaPlayer)
        guard case .media(let media) = tab.content else { return XCTFail("Missing initial source") }
        let unchanged = try await NativeMedia.open(url.path, reusing: media)
        XCTAssertTrue(unchanged.asset === media.asset)

        let timestamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let replacement = directory.appending(path: "new.wav")
        try Self.createWAV(replacement, payloadBytes: 96_000)
        let handle = try FileHandle(forWritingTo: replacement)
        try handle.seek(toOffset: 44)
        try handle.write(contentsOf: Data([0x53, 0x26]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: replacement.path)
        XCTAssertEqual(rename(replacement.path, url.path), 0)
        tab.reloadFromDiskIfClean()
        try await waitUntil { tab.mediaPlayer != nil && tab.mediaPlayer !== oldPlayer }
        XCTAssertNil(oldPlayer.currentItem)
        guard case .media(let changed) = tab.content else { return XCTFail("Missing replaced source") }
        XCTAssertNotEqual(changed.identity.inode, media.identity.inode)
        XCTAssertEqual(changed.identity.size, media.identity.size)

        let renamed = directory.appending(path: "重命名.wav")
        try FileManager.default.moveItem(at: url, to: renamed)
        let replacedPlayer = try XCTUnwrap(tab.mediaPlayer)
        project.updateFilePaths(from: url.path, to: renamed.path, workspace: nil)
        XCTAssertNil(replacedPlayer.currentItem)
        try await load(tab)
        let finalPlayer = try XCTUnwrap(tab.mediaPlayer)
        guard case .media(let moved) = tab.content else { return XCTFail("Missing renamed source") }
        XCTAssertEqual(moved.asset.url.path, try Self.canonicalPath(renamed))

        tab.reloadFromDiskIfClean()
        project.closeContent(.file(tab))
        XCTAssertTrue(project.tabs.isEmpty)
        XCTAssertNil(tab.mediaPlayer)
        XCTAssertNil(finalPlayer.currentItem)
        tab.refreshWhenSelected()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(tab.mediaPlayer)
    }

    func testRapidMediaRenameAndReopenCannotPublishAnObsoleteAsset() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".github/features")
        let video = try Data(contentsOf: fixtures.appending(path: "video-file-playback/demo-video.mp4"))
        let audio = try Data(contentsOf: fixtures.appending(path: "audio-file-playback/demo-audio.m4a"))
        let project = Project(fallbackName: "Media initial-load races", workspaceConfiguration: .standard)
        defer { project.closeAll() }
        var loadingRenames = 0
        var loadingCloses = 0
        for index in 0..<10 {
            let original = directory.appending(path: "original-\(index).mp4")
            let moved = directory.appending(path: "renamed-\(index).mp4")
            try video.write(to: original)
            project.openLocalFile(original.path)
            guard case .file(let initial)? = project.focusedContent else { return XCTFail("Missing initial file tab") }
            initial.loadIfNeeded()
            await Task.yield()
            if case .loading = initial.content { loadingRenames += 1 }
            let obsoletePlayer = initial.mediaPlayer
            try FileManager.default.moveItem(at: original, to: moved)
            try audio.write(to: original)
            project.updateFilePaths(from: original.path, to: moved.path, workspace: nil)
            XCTAssertNil(obsoletePlayer?.currentItem)
            try await load(initial)
            guard case .media(let renamed) = initial.content else { return XCTFail("Renamed video must load") }
            XCTAssertEqual(renamed.kind, .video)
            XCTAssertEqual(renamed.asset.url.path, try Self.canonicalPath(moved))
            let renamedPlayer = try XCTUnwrap(initial.mediaPlayer)
            project.closeContent(.file(initial))
            XCTAssertNil(renamedPlayer.currentItem)

            project.openLocalFile(original.path)
            guard case .file(let pending)? = project.focusedContent else { return XCTFail("Missing replaced file tab") }
            pending.loadIfNeeded()
            await Task.yield()
            if case .loading = pending.content { loadingCloses += 1 }
            let pendingPlayer = pending.mediaPlayer
            project.closeContent(.file(pending))
            XCTAssertNil(pendingPlayer?.currentItem)
            project.openLocalFile(original.path)
            guard case .file(let reopened)? = project.focusedContent else { return XCTFail("Missing reopened file tab") }
            XCTAssertFalse(reopened === pending)
            try await load(reopened)
            guard case .media(let current) = reopened.content else { return XCTFail("Replaced audio must load") }
            XCTAssertEqual(current.kind, .audio)
            XCTAssertEqual(current.asset.url.path, try Self.canonicalPath(original))
            XCTAssertNil(initial.mediaPlayer)
            XCTAssertNil(pending.mediaPlayer)
            let reopenedPlayer = try XCTUnwrap(reopened.mediaPlayer)
            XCTAssertTrue(reopenedPlayer.currentItem?.asset === current.asset)
            project.closeAll()
            XCTAssertNil(reopenedPlayer.currentItem)
            XCTAssertEqual(try Data(contentsOf: moved), video)
            XCTAssertEqual(try Data(contentsOf: original), audio)
        }
        XCTAssertGreaterThan(loadingRenames, 0, "Exercise a real rename before the initial load returns")
        XCTAssertGreaterThan(loadingCloses, 0, "Exercise a real close before the initial load returns")
        print("MEDIA_RACE cycles=10 loading_renames=\(loadingRenames) loading_closes=\(loadingCloses)")
    }

    func testUnmountedPlayersPauseAtDockTransitionsAndResumeFromTheirOwnPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first.wav")
        let second = root.appending(path: "second.wav")
        try Self.createWAV(first, payloadBytes: 960_000)
        try Self.createWAV(second, payloadBytes: 960_000)
        let project = Project(fallbackName: "Independent media owners", workspaceConfiguration: .standard)
        project.openLocalFile(first.path)
        guard case .file(let a)? = project.focusedContent else { return XCTFail("Missing first file") }
        let aID = try XCTUnwrap(project.selectedTabID)
        try await load(a)
        let player = try XCTUnwrap(a.mediaPlayer)
        let item = try XCTUnwrap(player.currentItem)
        player.isMuted = true
        player.play()
        try await waitUntil { player.currentTime().seconds > 0.08 }
        project.openLocalFile(second.path)
        XCTAssertEqual(player.rate, 0)
        let paused = player.currentTime().seconds
        guard case .file(let b)? = project.focusedContent else { return XCTFail("Missing second file") }
        try await load(b)
        let other = try XCTUnwrap(b.mediaPlayer)
        other.isMuted = true
        other.play()
        try await waitUntil { other.currentTime().seconds > 0.08 }
        project.selectTab(aID)
        XCTAssertEqual(other.rate, 0)
        XCTAssertTrue(a.mediaPlayer === player)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(player.currentTime().seconds, paused, accuracy: 0.12)
        XCTAssertEqual(player.rate, 0, "Selection does not implicitly resume audio")
        project.closeContent(.file(a))
        project.closeContent(.file(b))
        XCTAssertNil(player.currentItem)
        XCTAssertNil(other.currentItem)
    }

    func testMediaSleepWakeAndOutputChangeNeverReviveAReplacedItem() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "sample.wav")
        try Self.createWAV(url, payloadBytes: 960_000)
        let project = Project(fallbackName: "Media environment", workspaceConfiguration: .standard)
        project.openLocalFile(url.path)
        guard case .file(let tab)? = project.focusedContent else { return XCTFail("Missing file") }
        try await load(tab)
        let player = try XCTUnwrap(tab.mediaPlayer)
        let item = try XCTUnwrap(player.currentItem)
        player.isMuted = true
        player.play()
        try await waitUntil { player.currentTime().seconds > 0.08 }
        // Deliver the same workspace notifications as the system, without
        // actually putting the user's machine to sleep or changing its output.
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await waitUntil { tab.mediaSleeping }
        XCTAssertEqual(player.rate, 0)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil { !tab.mediaSleeping }
        XCTAssertTrue(tab.mediaPlayer === player)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(player.rate, 0)
        player.play()
        try await waitUntil { player.rate != 0 }
        tab.handleMediaEnvironmentEvent(.outputChanged)
        XCTAssertEqual(player.rate, 0)

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await waitUntil { tab.mediaSleeping }
        let stamp = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let replacement = root.appending(path: "replacement.wav")
        try Self.createWAV(replacement, payloadBytes: 960_000)
        let handle = try FileHandle(forWritingTo: replacement)
        try handle.seek(toOffset: 44)
        try handle.write(contentsOf: Data([0x10, 0x20]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: replacement.path)
        XCTAssertEqual(rename(replacement.path, url.path), 0)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil { tab.mediaPlayer != nil && tab.mediaPlayer !== player }
        let fresh = try XCTUnwrap(tab.mediaPlayer)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(fresh.rate, 0)
        try FileManager.default.removeItem(at: url)
        tab.reloadFromDiskIfClean()
        try await waitUntil { fresh.currentItem == nil }
        project.closeContent(.file(tab))
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(tab.mediaPlayer)
    }

    private func load(_ tab: FileTab) async throws {
        tab.loadIfNeeded()
        try await waitUntil {
            if case .loading = tab.content { return false }
            return true
        }
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !ready() {
            guard ContinuousClock.now < deadline else { throw WorkspaceError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func canonicalPath(_ url: URL) throws -> String {
        let path = try XCTUnwrap(realpath(url.path, nil))
        defer { free(path) }
        return String(cString: path)
    }

    @concurrent private static func checksum(_ url: URL) async throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty {
            try Task.checkCancellation()
            digest.update(data: bytes)
        }
        return digest.finalize()
    }

    private static func residentMiB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        return Double(info.resident_size) / 1_048_576
    }

    private func createVideoFixture(_ url: URL, size: CGSize, pixelAspect: CGSize = CGSize(width: 1, height: 1),
                                    aperture: CGSize? = nil, hdr: Bool = false, frameCount: Int = 3,
                                    alternatingFrames: Bool = false, variableTiming: Bool = false) async throws {
        let width = Int(size.width), height = Int(size.height)
        var settings: [String: Any] = [
            AVVideoCodecKey: hdr ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoPixelAspectRatioKey: [AVVideoPixelAspectRatioHorizontalSpacingKey: Int(pixelAspect.width),
                                         AVVideoPixelAspectRatioVerticalSpacingKey: Int(pixelAspect.height)],
        ]
        if let aperture {
            settings[AVVideoCleanApertureKey] = [AVVideoCleanApertureWidthKey: Int(aperture.width),
                                                 AVVideoCleanApertureHeightKey: Int(aperture.height),
                                                 AVVideoCleanApertureHorizontalOffsetKey: 0, AVVideoCleanApertureVerticalOffsetKey: 0]
        }
        if hdr {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                                   AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                                                   AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
            settings[AVVideoCompressionPropertiesKey] = [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel]
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        do {
            XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            if hdr {
                for plane in 0..<2 {
                    let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)).assumingMemoryBound(to: UInt16.self)
                    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
                    for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                        for x in 0..<stride { base[y * stride + x] = UInt16(plane == 0 ? (x < stride / 2 ? 384 : 704) : 512) << 6 }
                    }
                }
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            } else {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt32.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
                for y in 0..<height {
                    for x in 0..<width { base[y * stride + x] = x < width / 2 ? 0xffd02020 : 0xff20d020 }
                }
            }
        }
        let alternate: CVPixelBuffer?
        if alternatingFrames {
            precondition(!hdr)
            var second: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &second), kCVReturnSuccess)
            let other = try XCTUnwrap(second)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(other, []), kCVReturnSuccess)
            do {
                defer { CVPixelBufferUnlockBaseAddress(other, []) }
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(other)).assumingMemoryBound(to: UInt32.self)
                let stride = CVPixelBufferGetBytesPerRow(other) / 4
                for y in 0..<height {
                    for x in 0..<width { base[y * stride + x] = x < width / 2 ? 0xff20d020 : 0xffd02020 }
                }
            }
            alternate = other
        } else {
            alternate = nil
        }
        for index in 0..<frameCount {
            try await waitUntil { input.isReadyForMoreMediaData || writer.status != .writing }
            let presentation = variableTiming ? CMTime(value: Int64(index * 9 + (index / 3) * 6), timescale: 100)
                : CMTime(value: Int64(index), timescale: 10)
            let frame = index >= frameCount / 2 ? (alternate ?? buffer) : buffer
            guard writer.status == .writing, adaptor.append(frame, withPresentationTime: presentation) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
    }

    private static func createWAV(_ file: URL, payloadBytes: Int) throws {
        var header = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var bytes = value.littleEndian
            withUnsafeBytes(of: &bytes) { header.append(contentsOf: $0) }
        }
        append(UInt32(payloadBytes + 36))
        header.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(48_000))
        append(UInt32(96_000))
        append(UInt16(2))
        append(UInt16(16))
        header.append(contentsOf: "data".utf8)
        append(UInt32(payloadBytes))
        try header.write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(header.count + payloadBytes))
    }
}
