import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import Bailey

@MainActor
final class NativeMediaFileTests: XCTestCase {
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
