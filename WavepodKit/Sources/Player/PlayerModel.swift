import AVFoundation
import Library
import MediaPlayer
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
        didSet { if isPlaying { avPlayer?.rate = rate }; publishNowPlaying() }
    }
    public var volume: Float = 1 {
        didSet { avPlayer?.volume = volume }
    }

    @ObservationIgnored private var avPlayer: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var publishesNowPlaying = false

    public init() {}

    /// Makes the Mac's play/pause key, headphone buttons and Control Center control this player, and shows the
    /// episode in Now Playing. Only the app calls this: previews and tests keep the system controls untouched.
    public func enableSystemMediaControls() {
        guard !publishesNowPlaying else { return }
        publishesNowPlaying = true
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerModel, MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            command.addTarget { [weak self] event in
                guard let self else { return .noActionableNowPlayingItem }
                Task { @MainActor in action(self, event) }
                return .success
            }
        }
        handle(center.togglePlayPauseCommand) { player, _ in player.togglePlayback() }
        handle(center.playCommand) { player, _ in player.play() }
        handle(center.pauseCommand) { player, _ in player.pause() }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        handle(center.skipBackwardCommand) { player, _ in player.skip(by: -Self.skipInterval) }
        handle(center.skipForwardCommand) { player, _ in player.skip(by: Self.skipInterval) }
        handle(center.changePlaybackPositionCommand) { player, event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { player.seek(to: event.positionTime) }
        }
        publishNowPlaying()
    }

    /// Title, podcast, length, position and rate for Now Playing. The system moves the position on by itself from
    /// the rate, so this runs on changes only, not on every clock tick.
    private func publishNowPlaying() {
        guard publishesNowPlaying else { return }
        let info = MPNowPlayingInfoCenter.default()
        guard let episode, !episode.id.isEmpty else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.showName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        info.playbackState = isPlaying ? .playing : .paused
    }

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
        publishNowPlaying()
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
        publishNowPlaying()
    }

    public func pause() {
        isPlaying = false
        avPlayer?.pause()
        clock?.cancel()
        clock = nil
        publishNowPlaying()
    }

    public func togglePlayback() { isPlaying ? pause() : play() }

    public func seek(to time: Seconds) {
        currentTime = min(max(0, time), duration)
        avPlayer?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                       toleranceBefore: .zero, toleranceAfter: .zero)
        publishNowPlaying()
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
