import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class FreeToUseMusicPreview {
    private(set) var trackID: String?
    private(set) var position: TimeInterval = 0
    private(set) var selectionPosition: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var error: String?
    var isScrubbing = false

    var scrubPosition: TimeInterval {
        get { position }
        set {
            guard newValue.isFinite else { return }
            selectionPosition = max(0, newValue)
            seek(to: newValue)
        }
    }

    @ObservationIgnored private let player: AVPlayer
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var seekID: UUID?

    init(player: AVPlayer = AVPlayer()) { self.player = player }

    func toggle(_ track: FreeToUseMusicAPI.Track) {
        guard track.isUsable, let url = track.mp3URL else { return }
        if trackID == track.id {
            if isPlaying { player.pause(); isPlaying = false }
            else {
                if position >= track.duration - 0.1 { seek(to: 0) }
                player.play()
                isPlaying = true
            }
            return
        }
        stop()
        trackID = track.id
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item, item.status == .failed else { return }
                self.error = "Couldn't preview this track. Check your connection and retry."
                self.player.pause()
                self.isPlaying = false
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self, weak item] time in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item,
                      !self.isScrubbing, self.seekID == nil, time.seconds.isFinite else { return }
                self.updatePlaybackPosition(time.seconds, duration: track.duration)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                self.isPlaying = false
            }
        }
        player.play()
        isPlaying = true
    }

    func retry(_ track: FreeToUseMusicAPI.Track) {
        stop()
        toggle(track)
    }

    func updatePlaybackPosition(_ seconds: TimeInterval, duration: TimeInterval) {
        guard seconds.isFinite else { return }
        position = min(duration, max(0, seconds))
    }

    private func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        position = max(0, seconds)
        let requestID = UUID()
        seekID = requestID
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.seekID == requestID else { return }
                self?.seekID = nil
            }
        }
    }

    func stop() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        trackID = nil
        position = 0
        selectionPosition = 0
        isPlaying = false
        isScrubbing = false
        seekID = nil
        error = nil
    }
}
