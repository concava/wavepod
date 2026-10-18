import AVFoundation
import Library
import Observation

/// The app's single playback transport. Views read `currentTime` to highlight the transcript and call `seek` from
/// timestamp pills, chapters and citations.
///
/// With an audio URL it drives an `AVPlayer`. Without one (sample episode, previews, tests) it runs a simulated clock,
/// so every playback-dependent view behaves the same.
@MainActor
@Observable
public final class PlayerModel {
    public static let skipInterval: Seconds = 15
    public static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    public private(set) var episode: Episode?
    public private(set) var currentTime: Seconds = 0
    public private(set) var duration: Seconds = 0
    public private(set) var isPlaying = false
    public var rate: Float = 1 {
        didSet { if isPlaying { avPlayer?.rate = rate } }
    }
    public var volume: Float = 1 {
        didSet { avPlayer?.volume = volume }
    }

    @ObservationIgnored private var avPlayer: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var clock: Task<Void, Never>?

    public init() {}

    public func load(_ episode: Episode, audioURL: URL? = nil, at time: Seconds = 0) {
        pause()
        tearDownAVPlayer()
        self.episode = episode
        duration = episode.duration
        currentTime = min(max(0, time), duration)
        if let url = audioURL ?? episode.enclosureURL {
            let player = AVPlayer(url: url)
            player.volume = volume
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 20), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.currentTime = time.seconds }
            }
            avPlayer = player
            if time > 0 { player.seek(to: CMTime(seconds: time, preferredTimescale: 600)) }
        }
    }

    public func play() {
        guard episode != nil, !isPlaying else { return }
        if currentTime >= duration { currentTime = 0 }
        isPlaying = true
        if let avPlayer {
            avPlayer.rate = rate
        } else {
            startClock()
        }
    }

    public func pause() {
        isPlaying = false
        avPlayer?.pause()
        clock?.cancel()
        clock = nil
    }

    public func togglePlayback() { isPlaying ? pause() : play() }

    public func seek(to time: Seconds) {
        currentTime = min(max(0, time), duration)
        avPlayer?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                       toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Seek and start playing: what a timestamp pill or citation does.
    public func jump(to time: Seconds) {
        seek(to: time)
        play()
    }

    public func skip(by delta: Seconds) { seek(to: currentTime + delta) }

    public func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 1
        rate = Self.rates[(index + 1) % Self.rates.count]
    }

    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                let now = ContinuousClock.now
                let elapsed = now - last
                last = now
                let step = Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds)
                self.currentTime = min(self.duration, self.currentTime + step * Double(self.rate))
                if self.currentTime >= self.duration { self.pause() }
            }
        }
    }

    private func tearDownAVPlayer() {
        if let timeObserver { avPlayer?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        avPlayer = nil
    }
}
