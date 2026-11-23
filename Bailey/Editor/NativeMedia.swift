import AVFoundation
import AVKit
import Foundation
import SwiftUI

nonisolated struct NativeMedia: Sendable {
    enum Kind: Sendable { case audio, video }
    enum Failure: Error { case unsupported }

    let asset: AVURLAsset
    let identity: LocalFileIdentity
    let kind: Kind
    let videoAspectRatio: CGFloat?

    static func candidate(_ pathExtension: String) -> Kind? {
        switch pathExtension.lowercased() {
        case "mp4", "mov", "m4v": .video
        case "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac": .audio
        default: nil
        }
    }

    @concurrent static func open(_ path: String, reusing current: Self? = nil) async throws -> Self {
        let source = try LocalWorkspaceBackend.readableFile(at: path)
        let url = URL(fileURLWithPath: source.path)
        if let current, current.identity == source.identity, current.asset.url == url { return current }
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        return try await withTaskCancellationHandler {
            do {
                let (playable, protected) = try await asset.load(.isPlayable, .hasProtectedContent)
                guard playable, !protected else { throw Failure.unsupported }
                let kind: Kind
                let videoAspectRatio: CGFloat?
                if let track = try await decodableTrack(.video, in: asset) {
                    kind = .video
                    let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                    let displayed = CGRect(origin: .zero, size: size).applying(transform).size
                    let ratio = displayed.width / displayed.height
                    videoAspectRatio = ratio.isFinite && ratio > 0 ? ratio : nil
                } else if try await decodableTrack(.audio, in: asset) != nil {
                    kind = .audio
                    videoAspectRatio = nil
                } else {
                    throw Failure.unsupported
                }
                try Task.checkCancellation()
                let accepted = try LocalWorkspaceBackend.readableFile(at: path)
                guard accepted.path == source.path, accepted.identity == source.identity else {
                    throw WorkspaceError.changedExternally
                }
                return Self(asset: asset, identity: source.identity, kind: kind, videoAspectRatio: videoAspectRatio)
            } catch is AVError {
                try Task.checkCancellation()
                throw Failure.unsupported
            }
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private static func decodableTrack(_ type: AVMediaType, in asset: AVURLAsset) async throws -> AVAssetTrack? {
        for track in try await asset.loadTracks(withMediaType: type) {
            try Task.checkCancellation()
            if try await track.load(.isDecodable, .isSelfContained) == (true, true) { return track }
        }
        return nil
    }
}

struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    var allowsFullScreen = false
    var controlsStyle: AVPlayerViewControlsStyle = .inline
    var isDockActive: Bool?

    final class Presentation: NSObject, AVPlayerViewDelegate {
        var isDockActive: Bool?
        private(set) var isFullScreen = false

        func playerViewWillEnterFullScreen(_ playerView: AVPlayerView) { isFullScreen = true }

        func playerViewDidExitFullScreen(_ playerView: AVPlayerView) { isFullScreen = false }
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
        if view.player !== player { view.player = player }
        if view.showsFullScreenToggleButton != allowsFullScreen {
            view.showsFullScreenToggleButton = allowsFullScreen
        }
        let presentation = context.coordinator
        if presentation.isDockActive == true, isDockActive == false, !presentation.isFullScreen {
            player.pause()
        }
        presentation.isDockActive = isDockActive
    }
}
