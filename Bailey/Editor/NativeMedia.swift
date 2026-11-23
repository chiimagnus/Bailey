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
    let duration: Double?

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
                let (playable, duration, protected) = try await asset.load(.isPlayable, .duration, .hasProtectedContent)
                guard playable, !protected else { throw Failure.unsupported }
                let kind: Kind
                if try await hasDecodableTrack(.video, in: asset) { kind = .video }
                else if try await hasDecodableTrack(.audio, in: asset) { kind = .audio }
                else { throw Failure.unsupported }
                try Task.checkCancellation()
                let accepted = try LocalWorkspaceBackend.readableFile(at: path)
                guard accepted.path == source.path, accepted.identity == source.identity else {
                    throw WorkspaceError.changedExternally
                }
                let seconds = duration.seconds
                return Self(asset: asset, identity: source.identity, kind: kind,
                            duration: seconds.isFinite && seconds > 0 ? seconds : nil)
            } catch is AVError {
                try Task.checkCancellation()
                throw Failure.unsupported
            }
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private static func hasDecodableTrack(_ type: AVMediaType, in asset: AVURLAsset) async throws -> Bool {
        for track in try await asset.loadTracks(withMediaType: type) {
            try Task.checkCancellation()
            if try await track.load(.isDecodable, .isSelfContained) == (true, true) { return true }
        }
        return false
    }
}

struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    var allowsFullScreen = false

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = allowsFullScreen
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.showsFullScreenToggleButton = allowsFullScreen
    }
}
