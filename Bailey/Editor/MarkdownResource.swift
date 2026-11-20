import Foundation
import ImageIO
import SwiftUI
import Textual
import UniformTypeIdentifiers

nonisolated struct MarkdownResource: Sendable {
    let path: String
    let directory: String?
    let backend: any WorkspaceBackend

    func relativePath(for url: URL) throws -> String {
        guard let directory,
              LocalPathScope.contains(path, in: directory),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == nil, components.host == nil, components.query == nil,
              !components.path.isEmpty, !components.path.hasPrefix("/"),
              !components.path.contains("\\"), !components.path.utf8.contains(0) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let combined = (path as NSString).deletingLastPathComponent + "/" + components.path
        var segments: [Substring] = []
        for segment in combined.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": _ = segments.popLast()
            default: segments.append(segment)
            }
        }
        let resolved = "/" + segments.joined(separator: "/")
        guard LocalPathScope.contains(resolved, in: directory) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return resolved
    }

    func read(_ url: URL, maxBytes: Int) async throws -> Data {
        let candidate = try relativePath(for: url)
        guard let directory else { throw CocoaError(.fileReadNoPermission) }
        if let local = backend as? LocalWorkspaceBackend {
            return try await local.read(path: candidate, maxBytes: maxBytes, confinedTo: directory)
        }
        return try await remoteResource(candidate, directory: directory, maxBytes: maxBytes)
    }

    func resolvedFile(_ url: URL) async throws -> String {
        let candidate = try relativePath(for: url)
        guard let directory else { throw CocoaError(.fileReadNoPermission) }
        if let local = backend as? LocalWorkspaceBackend {
            try await local.checkConfinedFile(candidate, in: directory)
        } else {
            _ = try await remoteResource(candidate, directory: directory, maxBytes: nil)
        }
        return candidate
    }

    private func remoteResource(_ candidate: String, directory: String, maxBytes: Int?) async throws -> Data {
        if let maxBytes, maxBytes < 0 || maxBytes == .max { throw WorkspaceError.tooLarge }
        let count = maxBytes.map { String($0 + 1) } ?? ""
        let result = try await backend.runLimited(
            argv: ["sh", "-c", """
                root=$(realpath -- "$1" && printf '.') || exit 1
                root=${root%?}; root=${root%?}
                candidate=$(realpath -- "$2" && printf '.') || exit 1
                candidate=${candidate%?}; candidate=${candidate%?}
                [ -n "$root" ] && [ -d "$root" ] && [ -f "$candidate" ] || exit 1
                case "$candidate" in "${root%/}/"*) ;; *) exit 1;; esac
                if [ -n "$3" ]; then head -c "$3" -- "$candidate"; fi
                """, "bailey-markdown", directory, candidate, count],
            cwd: nil, env: nil, stdin: nil, timeout: 25, stdoutLimit: maxBytes.map { $0 + 1 } ?? 0,
            stderrLimit: 16_384
        )
        guard result.status == 0 else { throw CocoaError(.fileReadNoPermission) }
        if let maxBytes, result.stdout.count > maxBytes { throw WorkspaceError.tooLarge }
        return result.stdout
    }

    @concurrent func picture(_ url: URL) async throws -> MarkdownPicture {
        let svg = url.pathExtension.lowercased() == "svg"
        let data = try await read(url, maxBytes: svg ? 1 << 20 : 16 << 20)
        try Task.checkCancellation()
        if svg { return MarkdownPicture(poster: try MarkdownSVG.render(data)) }
        return try MarkdownPicture.decode(data)
    }
}

nonisolated struct MarkdownPicture: Hashable, Sendable {
    struct Frame: Hashable, Sendable {
        let image: CGImage
        let seconds: TimeInterval
    }

    let poster: CGImage
    var animation: [Frame] = []

    static func decode(_ data: Data) throws -> Self {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ), let poster = FileTab.imageThumbnail(source, maximumDimension: 2048) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let count = CGImageSourceGetCount(source)
        guard CGImageSourceGetType(source) as String? == UTType.gif.identifier,
              (2...32).contains(count) else { return Self(poster: poster) }
        var pixels = 0
        var frames: [Frame] = []
        for index in 0..<count {
            try Task.checkCancellation()
            guard let frame = FileTab.imageThumbnail(source, index: index, maximumDimension: 1024) else {
                return Self(poster: poster)
            }
            pixels += frame.width * frame.height
            guard pixels <= 8_000_000 else { return Self(poster: poster) }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
            frames.append(Frame(image: frame, seconds: delay.isFinite ? min(max(delay, 0.04), 10) : 0.1))
        }
        return Self(poster: poster, animation: frames)
    }

    func image(at time: TimeInterval) -> CGImage {
        guard !animation.isEmpty else { return poster }
        let total = animation.reduce(0) { $0 + $1.seconds }
        var elapsed = time.truncatingRemainder(dividingBy: total)
        for frame in animation {
            if elapsed < frame.seconds { return frame.image }
            elapsed -= frame.seconds
        }
        return poster
    }
}

nonisolated struct MarkdownImageLoader: AttachmentLoader {
    let resource: MarkdownResource

    func attachment(for url: URL, text: String, environment: ColorEnvironmentValues) async throws -> MarkdownImage {
        do {
            let image = try await resource.picture(url)
            try Task.checkCancellation()
            return MarkdownImage(image: image, alt: text, url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return MarkdownImage(image: nil, alt: text, url: url)
        }
    }
}

nonisolated struct MarkdownImage: Attachment {
    let image: MarkdownPicture?
    let alt: String
    let url: URL?

    var description: String { alt.isEmpty ? String(localized: "Image") : alt }

    @MainActor var body: some View {
        if let image {
            MarkdownImageLink(image: image, alt: description, url: url)
        } else {
            Label(description, systemImage: "photo")
                .foregroundStyle(.secondary)
                .accessibilityHint(Text("Image is missing, invalid, or outside the project."))
                .help(Text("Image is missing, invalid, or outside the project."))
                .lineLimit(1)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        guard let image else {
            return CGSize(width: min(proposal.width ?? 240, 240), height: 24)
        }
        let naturalWidth = CGFloat(image.poster.width)
        let width = min(proposal.width ?? naturalWidth, naturalWidth)
        return CGSize(width: width, height: width * CGFloat(image.poster.height) / naturalWidth)
    }
}

private struct MarkdownImageLink: View {
    let image: MarkdownPicture
    let alt: String
    let url: URL?
    @Environment(\.openURL) private var openURL
    @Environment(\.appearsActive) private var active

    var body: some View {
        Group {
            if let url {
                Button { openURL(url) } label: { frames }
                    .buttonStyle(.plain)
            } else {
                frames
            }
        }
        .accessibilityLabel(alt)
    }

    @ViewBuilder private var frames: some View {
        if image.animation.isEmpty {
            raster(image.poster)
        } else {
            TimelineView(.animation(minimumInterval: 0.04, paused: !active)) { context in
                raster(image.image(at: context.date.timeIntervalSinceReferenceDate))
            }
        }
    }

    private func raster(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
    }
}
