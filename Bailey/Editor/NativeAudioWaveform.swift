import Accelerate
import AVFoundation
import Foundation

/// A bounded, time-aligned summary of decoded audio, not another player or PCM cache.
nonisolated struct NativeAudioWaveform: Sendable {
    static let maximumBuckets = 100_000

    struct Bucket: Sendable {
        let peak: Float
        let rms: Float
    }

    let duration: Double
    let interval: Range<Double>
    let buckets: [Bucket]

    private struct Accumulator {
        var peak: Float = 0
        var squares: Double = 0
        var samples: Int64 = 0

        var bucket: Bucket {
            Bucket(peak: peak, rms: samples == 0 ? 0 : Float(sqrt(squares / Double(samples))))
        }
    }

    @concurrent static func read(
        _ media: NativeMedia, interval requested: Range<Double>? = nil,
        bucketCount: Int, trackID: CMPersistentTrackID? = nil
    ) async throws -> Self {
        try Task.checkCancellation()
        guard (1...maximumBuckets).contains(bucketCount) else { throw WorkspaceError.tooLarge }
        guard media.kind == .audio, let trackID = trackID ?? media.audioTrackID else {
            throw NativeMedia.Failure.unsupported
        }
        let asset = media.asset
        guard LocalFileIdentity.read(asset.url.path) == media.identity else {
            throw WorkspaceError.changedExternally
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTrack(withTrackID: trackID),
              track.mediaType == .audio,
              try await track.load(.isDecodable, .isSelfContained) == (true, true) else {
            throw NativeMedia.Failure.unsupported
        }
        let lower = max(0, requested?.lowerBound ?? 0)
        let upper = min(duration, requested?.upperBound ?? duration)
        guard lower.isFinite, upper.isFinite, lower < upper else { throw NativeMedia.Failure.unsupported }
        let interval = lower..<upper

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NativeMedia.Failure.unsupported }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: lower, preferredTimescale: 1_000_000_000),
            end: CMTime(seconds: upper, preferredTimescale: 1_000_000_000)
        )
        // The reader belongs to this worker. Cancellation must not cancel
        // loading of the shared AVURLAsset or touch the existing AVPlayer.
        defer { reader.cancelReading() }
        try Task.checkCancellation()
        guard reader.startReading() else { throw reader.error ?? NativeMedia.Failure.unsupported }

        var accumulators = [Accumulator](repeating: Accumulator(), count: bucketCount)
        var scratch = [Float](repeating: 0, count: 16_384)
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let sample = output.copyNextSampleBuffer() else { return false }
            try consume(sample, in: interval, into: &accumulators, scratch: &scratch)
            return true
        }) {}
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? NativeMedia.Failure.unsupported }
        guard LocalFileIdentity.read(asset.url.path) == media.identity else {
            throw WorkspaceError.changedExternally
        }
        return Self(duration: duration, interval: interval, buckets: accumulators.map(\.bucket))
    }

    private static func consume(
        _ sample: CMSampleBuffer, in interval: Range<Double>,
        into buckets: inout [Accumulator], scratch: inout [Float]
    ) throws {
        let frames = sample.numSamples
        guard frames > 0 else { return }
        guard let description = sample.formatDescription,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let data = sample.dataBuffer else { throw NativeMedia.Failure.unsupported }

        let channels = Int(format.mChannelsPerFrame)
        let bytesPerFrame = Int(format.mBytesPerFrame)
        let rate = format.mSampleRate
        let timestamp = sample.presentationTimeStamp.seconds
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              channels > 0, channels <= scratch.count,
              bytesPerFrame == channels * MemoryLayout<Float>.size,
              rate.isFinite, rate > 0, timestamp.isFinite,
              CMBlockBufferGetDataLength(data) / bytesPerFrame >= frames else {
            throw NativeMedia.Failure.unsupported
        }
        // Clip to presentation time, including packets that straddle the
        // requested interval and codec priming. One millionth of a frame
        // compensates for floating-point rounding at exact sample boundaries.
        func frameIndex(at seconds: Double) -> Int {
            Int(min(Double(frames), max(0, ((seconds - timestamp) * rate - 0.000_001).rounded(.up))))
        }
        let span = interval.upperBound - interval.lowerBound
        let last = frameIndex(at: interval.upperBound)
        var frame = frameIndex(at: interval.lowerBound)
        let bucketCount = buckets.count
        while frame < last {
            let time = timestamp + Double(frame) / rate
            let offset = (time - interval.lowerBound) / span * Double(bucketCount)
            var bucket = Int(min(Double(bucketCount - 1), max(0, offset.rounded(.down))))
            func boundary(_ index: Int) -> Int {
                frameIndex(at: interval.lowerBound + span * Double(index + 1) / Double(bucketCount))
            }
            var end = min(last, boundary(bucket))
            while end <= frame, bucket + 1 < bucketCount {
                bucket += 1
                end = min(last, boundary(bucket))
            }
            end = max(frame + 1, end)

            // Summarize consecutive frames with vector operations. Interleaved
            // channels contribute independently; opposite phases never cancel.
            while frame < end {
                try Task.checkCancellation()
                let length = min(end - frame, scratch.count / channels)
                let samples = length * channels
                let (status, peak, squares) = scratch.withUnsafeMutableBufferPointer { buffer in
                    let address = buffer.baseAddress!
                    let status = CMBlockBufferCopyDataBytes(
                        data, atOffset: frame * bytesPerFrame,
                        dataLength: samples * MemoryLayout<Float>.size, destination: address
                    )
                    var peak: Float = 0
                    var squares: Float = 0
                    if status == kCMBlockBufferNoErr {
                        vDSP_maxmgv(address, 1, &peak, vDSP_Length(samples))
                        vDSP_svesq(address, 1, &squares, vDSP_Length(samples))
                    }
                    return (status, peak, squares)
                }
                guard status == kCMBlockBufferNoErr, peak.isFinite, squares.isFinite else {
                    throw NativeMedia.Failure.unsupported
                }
                buckets[bucket].peak = max(buckets[bucket].peak, peak)
                buckets[bucket].squares += Double(squares)
                buckets[bucket].samples += Int64(samples)
                frame += length
            }
        }
    }
}
