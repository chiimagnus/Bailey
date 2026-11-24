import CoreGraphics
import Observation

@Observable
final class GIFPlayback {
    nonisolated struct Frames: Sendable {
        let count: Int
        let read: @Sendable (Int) async throws -> RasterPreview.GIFFrame
    }

    private(set) var image: CGImage?
    private var pauseOverride: Bool?
    private(set) var failed = false
    @ObservationIgnored private var index = 0
    @ObservationIgnored private var runID: UInt = 0
    @ObservationIgnored private var deadline: ContinuousClock.Instant?
    @ObservationIgnored private var remaining: Duration?
    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    private let clock = ContinuousClock()

    func isPaused(automaticallyPlays: Bool) -> Bool {
        pauseOverride ?? !automaticallyPlays
    }

    func togglePause(automaticallyPlays: Bool) {
        let paused = !isPaused(automaticallyPlays: automaticallyPlays)
        pauseOverride = paused
        if paused { suspend() }
    }

    func reset() {
        suspend()
        remaining = nil
        index = 0
        image = nil
        pauseOverride = nil
        failed = false
    }

    func play(automaticallyPlays: Bool, load: @escaping () async throws -> Frames) async {
        guard !Task.isCancelled else { return }
        suspend()
        guard !isPaused(automaticallyPlays: automaticallyPlays) else { return }
        let run = runID
        failed = false
        let task = Task { await advance(load: load, run: run) }
        advanceTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if run == runID { suspend() }
    }

    private func advance(load: () async throws -> Frames, run: UInt) async {
        do {
            try Task.checkCancellation()
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
        advanceTask?.cancel()
        advanceTask = nil
        if let deadline {
            remaining = max(.zero, clock.now.duration(to: deadline))
            self.deadline = nil
        }
    }
}
