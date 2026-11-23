import CoreGraphics
import Observation

@Observable
final class GIFPlayback {
    nonisolated struct Frames: Sendable {
        let count: Int
        let read: @Sendable (Int) async throws -> RasterPreview.GIFFrame
    }

    private(set) var image: CGImage?
    private(set) var paused = false
    private(set) var failed = false
    @ObservationIgnored private var index = 0
    @ObservationIgnored private var runID: UInt = 0
    @ObservationIgnored private var deadline: ContinuousClock.Instant?
    @ObservationIgnored private var remaining: Duration?
    private let clock = ContinuousClock()

    func togglePause() {
        paused.toggle()
        if paused { suspend() }
    }

    func reset() {
        suspend()
        remaining = nil
        index = 0
        image = nil
        paused = false
        failed = false
    }

    func play(load: () async throws -> Frames) async {
        suspend()
        let run = runID
        defer { if run == runID { suspend() } }
        failed = false
        do {
            let frames = try await load()
            guard frames.count > 1, run == runID, !Task.isCancelled else { return }
            var frame = try await frames.read(index)
            while run == runID, !Task.isCancelled {
                image = frame.image
                let end = clock.now.advanced(by: remaining ?? .seconds(frame.seconds))
                deadline = end
                remaining = nil
                let nextIndex = (index + 1) % frames.count
                async let next = frames.read(nextIndex)
                try await clock.sleep(until: end)
                let decoded = try await next
                guard run == runID, !Task.isCancelled else { return }
                deadline = nil
                index = nextIndex
                frame = decoded
            }
        } catch is CancellationError {
        } catch {
            if run == runID, !Task.isCancelled { failed = true }
        }
    }

    private func suspend() {
        runID &+= 1
        if let deadline {
            remaining = max(.zero, clock.now.duration(to: deadline))
            self.deadline = nil
        }
    }
}
