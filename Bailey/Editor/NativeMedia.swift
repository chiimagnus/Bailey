import AppKit
import AVFoundation
import AVKit
import CoreAudio
import Foundation
import SwiftUI

nonisolated struct NativeMedia: Sendable {
    enum Kind: Sendable { case audio, video }
    enum Failure: Error { case unsupported }

    let asset: AVURLAsset
    private let source: LocalWorkspaceBackend.ReadableFile
    var identity: LocalFileIdentity { source.identity }
    let kind: Kind
    let videoAspectRatio: CGFloat?

    @MainActor func makePlayer() -> AVPlayer {
        let item = AVPlayerItem(asset: asset)
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        return AVPlayer(playerItem: item)
    }

    static func candidate(_ pathExtension: String) -> Kind? {
        switch pathExtension.lowercased() {
        case "mp4", "mov", "m4v": .video
        case "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac": .audio
        default: nil
        }
    }

    @concurrent static func stillIdentifies(_ path: String, media: Self) async -> Bool {
        guard let source = try? LocalWorkspaceBackend.readableFile(at: path, includingDataGeneration: true) else { return false }
        return source.hasSameData(as: media.source)
    }

    @concurrent static func open(_ path: String, reusing current: Self? = nil) async throws -> Self {
        let source = try LocalWorkspaceBackend.readableFile(at: path, includingDataGeneration: true)
        let url = URL(fileURLWithPath: source.path)
        if let current, source.hasSameData(as: current.source) { return current }
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        return try await withTaskCancellationHandler {
            do {
                let (playable, protected) = try await asset.load(.isPlayable, .hasProtectedContent)
                guard playable, !protected else { throw Failure.unsupported }
                let kind: Kind
                let videoAspectRatio: CGFloat?
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                if !videoTracks.isEmpty {
                    guard let track = try await decodableTrack(videoTracks, type: .video, in: asset) else {
                        throw Failure.unsupported
                    }
                    kind = .video
                    let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                    let displayed = CGRect(origin: .zero, size: size).applying(transform).size
                    let ratio = displayed.width / displayed.height
                    videoAspectRatio = ratio.isFinite && ratio > 0 ? ratio : nil
                } else if try await decodableTrack(asset.loadTracks(withMediaType: .audio), type: .audio, in: asset) != nil {
                    kind = .audio
                    videoAspectRatio = nil
                } else {
                    throw Failure.unsupported
                }
                try Task.checkCancellation()
                let accepted = try LocalWorkspaceBackend.readableFile(at: path, includingDataGeneration: true)
                guard accepted.hasSameData(as: source) else {
                    throw WorkspaceError.changedExternally
                }
                return Self(asset: asset, source: accepted, kind: kind,
                            videoAspectRatio: videoAspectRatio)
            } catch is AVError {
                try Task.checkCancellation()
                throw Failure.unsupported
            }
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private static func decodableTrack(_ tracks: [AVAssetTrack], type: AVMediaType, in asset: AVURLAsset) async throws -> AVAssetTrack? {
        for track in tracks {
            try Task.checkCancellation()
            if try await track.load(.isDecodable, .isSelfContained) == (true, true),
               try hasDecodedSample(track, type: type, in: asset) { return track }
        }
        return nil
    }

    // A valid track index and nonempty compressed samples do not prove decodability.
    // Decode only until the first actual audio buffer or video frame is available.
    private static func hasDecodedSample(_ track: AVAssetTrack, type: AVMediaType, in asset: AVURLAsset) throws -> Bool {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = type == .video
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            : [AVFormatIDKey: kAudioFormatLinearPCM]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        // AVAssetReader forbids concurrent cancelReading and copyNextSampleBuffer calls.
        // The entire probe stays on the caller's background executor and retires the reader before returning.
        defer { reader.cancelReading() }
        try Task.checkCancellation()
        guard reader.startReading() else { return false }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard sample.numSamples > 0 else { continue }
            if type == .video {
                if sample.imageBuffer != nil { return true }
            } else if let data = sample.dataBuffer, CMBlockBufferGetDataLength(data) > 0 {
                return true
            }
        }
        try Task.checkCancellation()
        return false
    }
}

/// Only the FileTab's current player subscribes to system media events.
@MainActor
final class NativeMediaEnvironmentObservation {
    enum Event: Sendable { case sleep, wake, outputChanged }

    private var observers: [NSObjectProtocol] = []
    private var outputListener: AudioObjectPropertyListenerBlock?

    private static var outputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    init(onEvent: @escaping @MainActor @Sendable (Event) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, Event)] = [
            (NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.didWakeNotification, .wake)
        ]
        for (name, event) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onEvent(event) }
            })
        }
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onEvent(.outputChanged) }
        }
        var address = Self.outputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                              &address, .main, listener) == noErr {
            outputListener = listener
        }
    }

    func invalidate() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let outputListener {
            var address = Self.outputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, .main, outputListener)
            self.outputListener = nil
        }
    }

    isolated deinit { invalidate() }
}

struct NativePlayerView: NSViewRepresentable {
    weak var player: AVPlayer?
    var allowsFullScreen = false
    var controlsStyle: AVPlayerViewControlsStyle = .inline
    var isDockActive: Bool?

    final class Presentation: NSObject, AVPlayerViewDelegate {
        var isDockActive: Bool?
        private(set) var isFullScreen = false

        func playerViewWillEnterFullScreen(_ playerView: AVPlayerView) { isFullScreen = true }

        func playerViewDidExitFullScreen(_ playerView: AVPlayerView) {
            isFullScreen = false
            if isDockActive == false { playerView.player?.pause() }
        }
    }

    func makeCoordinator() -> Presentation { Presentation() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.delegate = context.coordinator
        context.coordinator.isDockActive = isDockActive
        view.controlsStyle = controlsStyle
        view.showsFullScreenToggleButton = allowsFullScreen
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let changedPlayer = view.player !== player
        if changedPlayer { view.player = player }
        if view.showsFullScreenToggleButton != allowsFullScreen {
            view.showsFullScreenToggleButton = allowsFullScreen
        }
        let presentation = context.coordinator
        if (presentation.isDockActive == true || changedPlayer), isDockActive == false,
           !presentation.isFullScreen {
            player?.pause()
        }
        presentation.isDockActive = isDockActive
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Presentation) {
        // FileTab or Markdown owns playback; a cached AppKit view must not
        // retain it after this native surface leaves the SwiftUI hierarchy.
        view.updatesNowPlayingInfoCenter = false
        view.delegate = nil
        view.player = nil
    }
}
