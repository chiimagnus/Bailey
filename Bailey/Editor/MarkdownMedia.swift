import AVFoundation
import Foundation
import SwiftUI

nonisolated enum MarkdownMedia {
    @concurrent static func stage(_ url: URL, from resource: PreviewResource) async throws -> URL {
        guard NativeMedia.candidate(url.pathExtension) != nil else { throw CocoaError(.fileReadUnsupportedScheme) }
        let bytes = try await resource.read(url, maxBytes: 64 << 20)
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appending(path: "Bailey-Markdown-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let destination = folder.appending(path: "media." + url.pathExtension.lowercased())
            try bytes.write(to: destination, options: .atomic)
            try Task.checkCancellation()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

struct MarkdownMediaView: View {
    let url: URL
    let video: Bool
    let resource: PreviewResource
    @State private var loading = false
    @State private var failed = false
    @State private var player: AVPlayer?
    @State private var stagedFile: URL?
    @Environment(\.appearsActive) private var windowAppearsActive
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let player {
                VStack {
                    NativePlayerView(player: player)
                        .frame(height: video ? 220 : 46)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(video ? Text("Video") : Text("Audio"))
                .accessibilityIdentifier("bailey.markdown.media")
            } else if loading {
                ProgressView()
            } else {
                if failed {
                    Label("Media is unavailable or outside the project.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                Button(video ? "Load Video" : "Load Audio") { loading = true }
            }
            Button("Open File") { openURL(url) }
                .buttonStyle(.link)
        }
        .task(id: loading) {
            guard loading else { return }
            var temporary: URL?
            do {
                let localFile = try await MarkdownMedia.stage(url, from: resource)
                temporary = localFile
                let media = try await NativeMedia.open(localFile.path)
                try Task.checkCancellation()
                stagedFile = localFile
                player = AVPlayer(playerItem: AVPlayerItem(asset: media.asset))
                failed = false
            } catch {
                if let temporary { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
                if !Task.isCancelled { failed = true }
            }
            loading = false
        }
        .onChange(of: windowAppearsActive) { _, active in if !active { player?.pause() } }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            if let stagedFile { try? FileManager.default.removeItem(at: stagedFile.deletingLastPathComponent()) }
            stagedFile = nil
        }
    }
}
