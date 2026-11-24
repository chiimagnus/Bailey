import AVFoundation
import SwiftUI

nonisolated struct AudioWaveformViewport: Equatable {
    let duration: Double
    private(set) var interval: Range<Double>

    init(duration: Double) {
        self.duration = duration
        interval = 0..<duration
    }

    func time(at fraction: Double) -> Double {
        interval.lowerBound + (interval.upperBound - interval.lowerBound) * min(1, max(0, fraction))
    }

    mutating func zoom(by factor: Double, anchor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        let fraction = min(1, max(0, anchor))
        let span = min(duration, max(min(duration, 0.1),
                                    (interval.upperBound - interval.lowerBound) / factor))
        let start = min(duration - span, max(0, time(at: fraction) - span * fraction))
        interval = start..<(start + span)
    }

    mutating func move(by pages: Double) {
        let span = interval.upperBound - interval.lowerBound
        let start = min(duration - span, max(0, interval.lowerBound + pages * span))
        interval = start..<(start + span)
    }
}

/// The native AVPlayer remains the owner of playback and seeking.
/// This view owns only the current visible, bounded PCM summary.
struct NativeAudioWaveformView: View {
    let file: FileTab
    let media: NativeMedia
    let player: AVPlayer
    let active: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var viewport: AudioWaveformViewport?
    @State private var durationUnavailable = false
    @State private var trackID: CMPersistentTrackID?
    @State private var result: Result<NativeAudioWaveform, Error>?
    @State private var completedRequest: Request?

    private struct Request: Hashable {
        let revision: String
        let environmentRevision: UInt
        let interval: Range<Double>
        let count: Int
        let trackID: CMPersistentTrackID?
    }

    var body: some View {
        GeometryReader { geometry in
            if let viewport {
                let request = Request(
                    revision: file.fileContentRevision, environmentRevision: file.mediaEnvironmentRevision,
                    interval: viewport.interval,
                    count: bucketCount(for: geometry.size.width), trackID: trackID
                )
                VStack(spacing: 3) {
                    waveform(request, width: geometry.size.width, viewport: viewport)
                    HStack {
                        Text(timeLabel(viewport.interval.lowerBound))
                        Spacer(minLength: 0)
                        Text(timeLabel(viewport.interval.upperBound))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
                    .task(id: active ? request : nil) {
                        guard active, request != completedRequest else { return }
                        result = nil
                        do {
                            // Coalesce resize and successive zoom changes before opening a reader.
                            try await Task.sleep(for: .milliseconds(100))
                            let summary = try await NativeAudioWaveform.read(
                                media, interval: request.interval,
                                bucketCount: request.count, trackID: request.trackID
                            )
                            try Task.checkCancellation()
                            guard file.fileContentRevision == request.revision,
                                  file.mediaEnvironmentRevision == request.environmentRevision,
                                  file.mediaPlayer === player, !file.mediaSleeping else { return }
                            completedRequest = request
                            result = .success(summary)
                        } catch {
                            guard !Task.isCancelled, file.fileContentRevision == request.revision,
                                  file.mediaEnvironmentRevision == request.environmentRevision,
                                  file.mediaPlayer === player, !file.mediaSleeping else { return }
                            completedRequest = request
                            result = .failure(error)
                        }
                    }
            } else {
                Group {
                    if durationUnavailable {
                        Text("Waveform Unavailable", tableName: "Editor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: active ? file.fileContentRevision : nil) {
            guard active else { return }
            updateTrack()
            guard viewport == nil else { return }
            durationUnavailable = false
            completedRequest = nil
            result = nil
            trackID = media.audioTrackID
            if let duration = try? await media.asset.load(.duration).seconds,
               duration.isFinite, duration > 0, !Task.isCancelled, file.mediaPlayer === player {
                viewport = AudioWaveformViewport(duration: duration)
                updateTrack()
            } else if !Task.isCancelled {
                durationUnavailable = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.mediaSelectionDidChangeNotification)) { event in
            guard let item = event.object as? AVPlayerItem, item === player.currentItem else { return }
            updateTrack()
        }
    }

    private func bucketCount(for width: CGFloat) -> Int {
        // Powers of two avoid restarting the reader for every pixel of a resize.
        let pixels = min(Double(NativeAudioWaveform.maximumBuckets), max(1, Double(width * displayScale)))
        return min(NativeAudioWaveform.maximumBuckets, Int(pow(2, ceil(log2(pixels)))))
    }

    private func timeLabel(_ seconds: Double) -> String {
        Duration.seconds(seconds.isFinite ? max(0, seconds) : 0).formatted(.time(pattern: .hourMinuteSecond))
    }

    private var accessibleTime: String { timeLabel(player.currentTime().seconds) }

    private func updateTrack() {
        trackID = player.currentItem?.tracks.first(where: {
            $0.isEnabled && $0.assetTrack?.mediaType == .audio
        })?.assetTrack?.trackID ?? media.audioTrackID
    }

    private func seek(_ time: Double) {
        guard active, time.isFinite, file.mediaPlayer === player, !file.mediaSleeping else { return }
        // AVPlayer interrupts superseded seeks; no completion callback is allowed
        // to write an earlier requested time back into the view.
        player.seek(to: CMTime(seconds: time, preferredTimescale: 1_000_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func drawing(_ summary: NativeAudioWaveform) -> some View {
        Canvas { context, size in
            let middle: CGFloat = size.height / 2
            let step: CGFloat = size.width / CGFloat(summary.buckets.count)
            var peaks = Path()
            var rms = Path()
            for (index, bucket) in summary.buckets.enumerated() {
                let x: CGFloat = (CGFloat(index) + 0.5) * step
                let peak: CGFloat = CGFloat(min(1, bucket.peak)) * middle
                let rootMeanSquare: CGFloat = CGFloat(min(1, bucket.rms)) * middle
                peaks.move(to: CGPoint(x: x, y: middle - peak))
                peaks.addLine(to: CGPoint(x: x, y: middle + peak))
                rms.move(to: CGPoint(x: x, y: middle - rootMeanSquare))
                rms.addLine(to: CGPoint(x: x, y: middle + rootMeanSquare))
            }
            let minimumWidth: CGFloat = 1 / displayScale
            let lineWidth: CGFloat = max(minimumWidth, step * 0.8)
            context.stroke(peaks, with: .color(Color.accentColor.opacity(0.35)), lineWidth: lineWidth)
            context.stroke(rms, with: .color(Color.accentColor), lineWidth: lineWidth)
        }
    }

    private func playhead(in viewport: AudioWaveformViewport) -> some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !active)) { _ in
            let time = player.currentTime().seconds
            Canvas { context, size in
                let range = viewport.interval
                guard time.isFinite, time >= range.lowerBound, time <= range.upperBound else { return }
                let fraction = (time - range.lowerBound) / (range.upperBound - range.lowerBound)
                let x = size.width * CGFloat(fraction)
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .foreground, lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private func waveform(_ request: Request, width: CGFloat, viewport: AudioWaveformViewport) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.45))
            if completedRequest == request, let result {
                switch result {
                case .success(let summary):
                    drawing(summary)
                case .failure:
                    Text("Waveform Unavailable", tableName: "Editor")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            playhead(in: viewport)
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                seek(viewport.time(at: value.location.x / width))
            })
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            self.viewport?.zoom(by: value.magnification, anchor: value.startAnchor.x)
        })
        .contextMenu {
            Button {
                self.viewport?.zoom(by: 2, anchor: 0.5)
            } label: { Text("Zoom In", tableName: "Editor") }
            Button {
                self.viewport?.zoom(by: 0.5, anchor: 0.5)
            } label: { Text("Zoom Out", tableName: "Editor") }
            Button {
                self.viewport = AudioWaveformViewport(duration: viewport.duration)
            } label: { Text("Fit", tableName: "Editor") }
            Divider()
            Button {
                self.viewport?.move(by: -0.5)
            } label: { Text("Previous Waveform Section", tableName: "Editor") }
            .disabled(viewport.interval.lowerBound == 0)
            Button {
                self.viewport?.move(by: 0.5)
            } label: { Text("Next Waveform Section", tableName: "Editor") }
            .disabled(viewport.interval.upperBound >= viewport.duration)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("bailey.audio.waveform")
        .accessibilityLabel(Text("Waveform", tableName: "Editor"))
        .accessibilityValue(accessibleTime)
        .accessibilityAdjustableAction { direction in
            let step = (viewport.interval.upperBound - viewport.interval.lowerBound) / 20
            let current = player.currentTime().seconds
            guard current.isFinite else { return }
            switch direction {
            case .increment: seek(min(viewport.duration, current + step))
            case .decrement: seek(max(0, current - step))
            @unknown default: break
            }
        }
    }
}
