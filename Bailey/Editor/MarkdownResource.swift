import Foundation
import ImageIO
import SwiftUI
import Textual

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
        guard maxBytes >= 0, maxBytes < .max else { throw WorkspaceError.tooLarge }
        let result = try await backend.runLimited(
            argv: ["sh", "-c", """
                root=$(realpath -- "$1" && printf '.') || exit 1
                root=${root%?}; root=${root%?}
                candidate=$(realpath -- "$2" && printf '.') || exit 1
                candidate=${candidate%?}; candidate=${candidate%?}
                [ -n "$root" ] && [ -d "$root" ] && [ -f "$candidate" ] || exit 1
                case "$candidate" in "${root%/}/"*) head -c "$3" -- "$candidate";; *) exit 1;; esac
                """, "bailey-markdown", directory, candidate, String(maxBytes + 1)],
            cwd: nil, env: nil, stdin: nil, timeout: 25, stdoutLimit: maxBytes + 1, stderrLimit: 16_384
        )
        guard result.status == 0 else { throw CocoaError(.fileReadNoPermission) }
        guard result.stdout.count <= maxBytes else { throw WorkspaceError.tooLarge }
        return result.stdout
    }

    @concurrent func image(_ url: URL) async throws -> CGImage {
        let data = try await read(url, maxBytes: 16 << 20)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ), let thumbnail = FileTab.imageThumbnail(source, maximumDimension: 2048) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return thumbnail
    }
}

nonisolated struct MarkdownImageLoader: AttachmentLoader {
    let resource: MarkdownResource

    func attachment(for url: URL, text: String, environment: ColorEnvironmentValues) async throws -> MarkdownImage {
        do {
            let image = try await resource.image(url)
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
    let image: CGImage?
    let alt: String
    let url: URL

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
        let naturalWidth = CGFloat(image.width)
        let width = min(proposal.width ?? naturalWidth, naturalWidth)
        return CGSize(width: width, height: width * CGFloat(image.height) / naturalWidth)
    }
}

private struct MarkdownImageLink: View {
    let image: CGImage
    let alt: String
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(url) } label: {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(alt)
    }
}
