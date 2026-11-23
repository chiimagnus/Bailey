import Foundation
import SwiftUI

nonisolated extension PreviewResource {
    @concurrent func picture(_ url: URL) async throws -> MarkdownPicture {
        let svg = url.pathExtension.lowercased() == "svg"
        let data = try await read(url, maxBytes: svg ? SVGArtwork.byteLimit : 16 << 20)
        try Task.checkCancellation()
        if svg {
            let raster = try SVGArtwork.render(data)
            return MarkdownPicture(poster: raster.image, pointSize: raster.pointSize)
        }
        return try MarkdownPicture.decode(data)
    }
}

nonisolated struct MarkdownPicture: Hashable, Sendable {
    let poster: CGImage
    var pointSize: CGSize? = nil
    var animation: [RasterPreview.GIFFrame] = []

    static func decode(_ data: Data) throws -> Self {
        guard let source = RasterPreview.source(data),
              let poster = RasterPreview.decode(source, maximumDimension: 2048)?.poster else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let count = RasterPreview.gifFrameCount(source)
        guard (2...32).contains(count) else { return Self(poster: poster) }
        var pixels = 0
        var frames: [RasterPreview.GIFFrame] = []
        for index in 0..<count {
            let frame: RasterPreview.GIFFrame
            do {
                frame = try RasterPreview.gifFrame(source, at: index, maximumDimension: 1024)
            } catch CocoaError.fileReadCorruptFile {
                return Self(poster: poster)
            }
            pixels += frame.image.width * frame.image.height
            guard pixels <= 8_000_000 else { return Self(poster: poster) }
            frames.append(frame)
        }
        return Self(poster: poster, animation: frames)
    }

}


/// SwiftUI owns displayed images; bytes always come from the file's backend.
struct MarkdownNativeImage: View {
    let picture: MarkdownPicture?
    let alt: String
    let url: URL?
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    @Environment(\.openURL) private var openURL
    @State private var inspecting = false

    var body: some View {
        Group {
            if let picture {
                if let url {
                    Button { openURL(url) } label: { frames(picture) }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                } else {
                    Button { inspecting = true } label: { frames(picture) }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help("Inspect image")
                        .sheet(isPresented: $inspecting) {
                            ImageInspector(image: RasterPreview(
                                poster: picture.poster,
                                pixelSize: CGSize(width: picture.poster.width, height: picture.poster.height)
                            ), showsCloseButton: true)
                            .frame(minWidth: 360, minHeight: 280)
                        }
                }
            } else {
                Label(alt.isEmpty ? String(localized: "Image") : alt, systemImage: "photo")
                    .foregroundStyle(.secondary)
                    .help(Text("Image is missing, invalid, or outside the project."))
            }
        }
        .accessibilityLabel(alt)
    }

    @ViewBuilder
    private func frames(_ picture: MarkdownPicture) -> some View {
        if picture.animation.isEmpty {
            raster(picture.poster, pointSize: picture.pointSize)
        } else {
            MarkdownAnimatedImage(frames: picture.animation, poster: picture.poster) { image in
                raster(image, pointSize: picture.pointSize)
            }
            .id(ObjectIdentifier(picture.poster))
        }
    }

    private func raster(_ image: CGImage, pointSize: CGSize?) -> some View {
        let natural = pointSize ?? CGSize(width: image.width, height: image.height)
        let w = width ?? height.map { $0 * natural.width / natural.height }
        let h = height ?? width.map { $0 * natural.height / natural.width }
        let targetW = w ?? natural.width
        let targetH = h ?? natural.height
        return ViewThatFits(in: .horizontal) {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: targetW, height: targetH)
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(targetW / targetH, contentMode: .fit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownAnimatedImage<Content: View>: View {
    let frames: [RasterPreview.GIFFrame]
    let poster: CGImage
    @ViewBuilder let content: (CGImage) -> Content
    @State private var playback = GIFPlayback()
    @Environment(\.appearsActive) private var active

    var body: some View {
        content(playback.image ?? frames.first?.image ?? poster)
            .task(id: active) {
                guard active else { return }
                await playback.play {
                    GIFPlayback.Frames(count: frames.count) { [frames] index in frames[index] }
                }
            }
    }
}

struct MarkdownResourceImage: View {
    private struct Request: Hashable {
        let url: URL
        let refresh: UInt
        let path: String
    }

    let url: URL
    let alt: String
    let resource: PreviewResource
    let refresh: UInt
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var sourceRange: NSRange? = nil
    @State private var picture: MarkdownPicture?
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                MarkdownNativeImage(picture: picture, alt: alt, url: url, width: width, height: height)
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
            }
        }
        .modifier(MarkdownEmbeddedSourceMapping(source: sourceRange))
        .task(id: Request(url: url, refresh: refresh, path: resource.path)) {
            loaded = false
            picture = nil
            let result = try? await resource.picture(url)
            guard !Task.isCancelled else { return }
            picture = result
            loaded = true
        }
    }
}
