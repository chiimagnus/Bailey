import AVFoundation
import CryptoKit
import Darwin
import Foundation
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
