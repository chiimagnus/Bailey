import AppKit
import AVFoundation
import Combine
import SwiftUI

/// AVPlayerView always paints a movie surface. Standalone audio needs only a transport.
struct FileAudioControls: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> Bar { Bar(player: player) }
    func updateNSView(_ bar: Bar, context: Context) {}
    static func dismantleNSView(_ bar: Bar, coordinator: ()) { bar.disconnect() }

    final class Bar: NSStackView {
        private(set) var player: AVPlayer?
        private let play = NSButton(), mute = NSButton()
        private final class Slider: NSSlider {
            private(set) var isTracking = false
            override var acceptsFirstResponder: Bool { true }
            override func mouseDown(with event: NSEvent) {
                window?.makeFirstResponder(self)
                isTracking = true
                defer { isTracking = false }
                super.mouseDown(with: event)
            }
        }
        private let timeline = Slider(), volume = Slider()
        private let clock = NSTextField(labelWithString: "")
        private var observations = Set<AnyCancellable>()
        private var timeObserver: Any?

        init(player: AVPlayer) {
            self.player = player
            super.init(frame: .zero)
            orientation = .horizontal
            alignment = .centerY
            spacing = 8
            setAccessibilityIdentifier("bailey.audio.controls")
            for (button, id, action) in [(play, "play/pause", #selector(togglePlayback)),
                                          (mute, "mute", #selector(toggleMute))] {
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.target = self
                button.action = action
                button.setAccessibilityIdentifier(id)
                button.widthAnchor.constraint(equalToConstant: 24).isActive = true
                button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            }
            play.setButtonType(.toggle)
            play.setAccessibilityRole(.checkBox)
            for (slider, id, label, action) in [
                (timeline, "timeline", String(localized: "Playback position", table: "Editor"), #selector(seek)),
                (volume, "volume", String(localized: "Volume", table: "Editor"), #selector(changeVolume)),
            ] {
                slider.isContinuous = true
                slider.target = self
                slider.action = action
                slider.setAccessibilityIdentifier(id)
                slider.setAccessibilityLabel(label)
                slider.toolTip = label
            }
            volume.maxValue = 1
            clock.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            clock.textColor = .secondaryLabelColor
            [play, timeline, clock, mute, volume].forEach { addArrangedSubview($0) }
            timeline.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let volumeWidth = volume.widthAnchor.constraint(equalToConstant: 72)
            volumeWidth.priority = .defaultHigh
            volumeWidth.isActive = true
            setVisibilityPriority(.detachOnlyIfNecessary, for: clock)

            player.publisher(for: \.rate).combineLatest(player.publisher(for: \.isMuted), player.publisher(for: \.volume))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateButtons() }.store(in: &observations)
            player.currentItem?.publisher(for: \.duration).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateTime() }.store(in: &observations)
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.updateTime() }
            }
            updateButtons()
            updateTime()
        }

        required init?(coder: NSCoder) { nil }
        isolated deinit { disconnect() }

        func disconnect() {
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            timeObserver = nil
            observations.removeAll()
            player = nil
        }

        private func updateButtons() {
            guard let player else { return }
            let playing = player.rate != 0
            play.state = playing ? .on : .off
            play.toolTip = playing ? String(localized: "Pause", table: "Editor") : String(localized: "Play", table: "Editor")
            mute.toolTip = player.isMuted ? String(localized: "Unmute", table: "Editor") : String(localized: "Mute", table: "Editor")
            play.setAccessibilityLabel(play.toolTip)
            mute.setAccessibilityLabel(mute.toolTip)
            play.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
            mute.image = NSImage(systemSymbolName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)
            if !volume.isTracking { volume.doubleValue = player.isMuted ? 0 : Double(player.volume) }
        }

        private func updateTime() {
            guard let player else { return }
            let total = player.currentItem?.duration.seconds ?? .nan
            let now = player.currentTime().seconds
            timeline.isEnabled = total.isFinite && total > 0
            timeline.maxValue = timeline.isEnabled ? total : 1
            if !timeline.isTracking {
                timeline.doubleValue = now.isFinite ? min(max(0, now), timeline.maxValue) : 0
            }
            func stamp(_ seconds: Double) -> String {
                Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
            }
            clock.stringValue = stamp(timeline.doubleValue) + " / " + (timeline.isEnabled ? stamp(total.rounded()) : "–:––")
            timeline.setAccessibilityValueDescription(clock.stringValue)
        }

        @objc private func togglePlayback() {
            guard let player else { return }
            if player.rate != 0 { player.pause(); return }
            if let duration = player.currentItem?.duration, duration.isNumeric, player.currentTime() >= duration {
                player.seek(to: .zero)
            }
            player.play()
        }

        @objc private func seek() {
            player?.seek(to: CMTime(seconds: timeline.doubleValue, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero)
        }

        @objc private func toggleMute() { player?.isMuted.toggle() }
        @objc private func changeVolume() {
            player?.volume = Float(volume.doubleValue)
            player?.isMuted = false
        }
    }
}
