import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Plays the original and the restored file in lockstep, so switching between them is instant and
/// stays on the same beat.
///
/// Each version has its own `AVPlayer`, both started at the same host time; switching crossfades their
/// volumes. Playing through `AVPlayer` (rather than an audio engine) is what lets the system offer Spatial
/// Audio — stereo spatialisation and head tracking — in Control Center with AirPods, and the app publishes
/// itself as Now Playing for the lock screen and Control Center.
@MainActor
@Observable
final class ABPlayer {
    enum Source: Hashable {
        case original, restored
    }

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var hasRestored = false
    /// Smoothed output level, 0…1.
    private(set) var level: Float = 0
    /// Bluetooth headphones re-encode everything, which narrows the audible gap between versions.
    private(set) var isBluetoothOutput = false
    /// Whether the output can spatialise this audio and the listener allows it (Control Center).
    private(set) var isSpatialAudioEnabled = false
    /// Whether the louder version is turned down to the other's loudness, so neither wins by volume alone.
    private(set) var isLoudnessMatched = false
    var source: Source = .original {
        didSet { if source != oldValue { crossfade() } }
    }

    @ObservationIgnored private var originalPlayer: AVPlayer?
    @ObservationIgnored private var restoredPlayer: AVPlayer?
    @ObservationIgnored private var envelopes: (original: [Float], restored: [Float]) = ([], [])
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var routeObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var nowPlaying: [String: Any] = [:]
    @ObservationIgnored private var fade: Task<Void, Never>?
    @ObservationIgnored private var restoredMix: Float = 0
    @ObservationIgnored private var trims: (original: Float, restored: Float) = (1, 1)

    init() {
        updateRoute()
        let center = NotificationCenter.default
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.spatialPlaybackCapabilitiesChangedNotification] {
            routeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { @Sendable [weak self] _ in
                Task { @MainActor in self?.updateRoute() }
            })
        }
    }

    // MARK: - Loading

    func load(original: URL, restored: URL?) async throws {
        stop()
        removeTimeObserver()

        let (originalPlayer, originalDuration) = try await Self.makePlayer(url: original)
        var restoredPlayer: AVPlayer?
        if let restored { restoredPlayer = try await Self.makePlayer(url: restored).player }
        self.originalPlayer = originalPlayer
        self.restoredPlayer = restoredPlayer
        duration = originalDuration
        currentTime = min(currentTime, duration)
        hasRestored = restoredPlayer != nil
        if !hasRestored { source = .original }
        applyVolumes(restoredMix: source == .restored ? 1 : 0)

        let interval = CMTime(value: 1, timescale: 20)
        timeObserver = originalPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let item = originalPlayer.currentItem {
            itemObservers.append(NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { @Sendable [weak self] _ in
                Task { @MainActor in self?.stop() }
            })
        }

        // The background breathes with the music: levels read ahead of time, off the main actor.
        let originalEnvelope = await Self.envelope(of: original)
        let restoredEnvelope = if let restored { await Self.envelope(of: restored) } else { [Float]() }
        envelopes = (originalEnvelope, restoredEnvelope)
    }

    /// A player whose item is ready, so it can be started at a precise host time.
    private static func makePlayer(url: URL) async throws -> (player: AVPlayer, duration: TimeInterval) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        let item = AVPlayerItem(asset: asset)
        // Stereo is eligible for spatialisation too, not only multichannel.
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        // Local files are ready within a few frames.
        for _ in 0..<250 where item.status == .unknown {
            try await Task.sleep(for: .milliseconds(20))
        }
        if item.status != .readyToPlay { throw item.error ?? CocoaError(.fileReadCorruptFile) }
        return (player, duration.isFinite ? duration : 0)
    }

    /// Describes the track for Now Playing (lock screen, Control Center).
    func setNowPlaying(title: String, artist: String?, artwork: UIImage?) {
        nowPlaying[MPMediaItemPropertyTitle] = title
        nowPlaying[MPMediaItemPropertyArtist] = artist
        if let artwork {
            nowPlaying[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { @Sendable _ in artwork }
        } else {
            nowPlaying[MPMediaItemPropertyArtwork] = nil
        }
        if isPlaying { publishNowPlaying() }
    }

    // MARK: - Transport

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let originalPlayer, originalPlayer.currentItem?.status == .readyToPlay else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            return
        }
        updateRoute()
        if currentTime >= duration - 0.05 { currentTime = 0 }
        start(at: currentTime)
        isPlaying = true
        registerRemoteCommands()
        publishNowPlaying()
    }

    func pause() {
        currentTime = playbackTime()
        players.forEach { $0.pause() }
        isPlaying = false
        level = 0
        publishNowPlaying()
    }

    func stop() {
        players.forEach { $0.pause() }
        isPlaying = false
        currentTime = 0
        level = 0
        unregisterRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to time: TimeInterval) {
        currentTime = min(max(time, 0), duration)
        if isPlaying {
            start(at: currentTime)
        } else {
            let target = CMTime(seconds: currentTime, preferredTimescale: 44_100)
            players.forEach { $0.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) }
        }
        publishNowPlaying()
    }

    private var players: [AVPlayer] { [originalPlayer, restoredPlayer].compactMap { $0 } }

    /// Starts both players on the same host time, slightly ahead, so they stay sample-aligned.
    private func start(at time: TimeInterval) {
        let itemTime = CMTime(seconds: time, preferredTimescale: 44_100)
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 1, timescale: 10)
        for player in players where player.currentItem?.status == .readyToPlay {
            player.setRate(1, time: itemTime, atHostTime: hostTime)
        }
    }

    private func playbackTime() -> TimeInterval {
        guard let seconds = originalPlayer?.currentTime().seconds, seconds.isFinite else { return currentTime }
        return min(max(seconds, 0), duration)
    }

    private func tick() {
        guard isPlaying else { return }
        currentTime = playbackTime()
        updateLevel()
    }

    private func removeTimeObserver() {
        if let timeObserver { originalPlayer?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemObservers = []
    }

    private func updateRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        isBluetoothOutput = outputs.contains { bluetooth.contains($0.portType) }
        isSpatialAudioEnabled = outputs.contains { $0.isSpatialAudioEnabled }
    }

    // MARK: - A/B

    /// Levels both versions to the quieter one's loudness (in LUFS). Differences under 0.5 LU are left alone.
    func matchLoudness(original: Double?, restored: Double?) {
        if let original, let restored, original > -70, restored > -70, abs(original - restored) >= 0.5 {
            let quieter = min(original, restored)
            trims = (Float(pow(10, (quieter - original) / 20)), Float(pow(10, (quieter - restored) / 20)))
            isLoudnessMatched = true
        } else {
            trims = (1, 1)
            isLoudnessMatched = false
        }
        applyVolumes(restoredMix: restoredMix)
    }

    private func crossfade() {
        let target: Float = source == .restored ? 1 : 0
        let from = restoredMix
        fade?.cancel()
        fade = Task { [weak self] in
            let steps = 8
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                self?.applyVolumes(restoredMix: from + (target - from) * Float(step) / Float(steps))
                try? await Task.sleep(for: .milliseconds(4))
            }
        }
    }

    private func applyVolumes(restoredMix: Float) {
        self.restoredMix = restoredMix
        restoredPlayer?.volume = restoredMix * trims.restored
        originalPlayer?.volume = (1 - restoredMix) * trims.original
    }

    // MARK: - Level

    nonisolated static let envelopeRate = 20.0

    private func updateLevel() {
        let envelope = source == .restored && !envelopes.restored.isEmpty ? envelopes.restored : envelopes.original
        let index = Int(currentTime * Self.envelopeRate)
        guard envelope.indices.contains(index) else { return }
        let decibels = 20 * log10(max(envelope[index], 1e-6))
        let normalized = min(max((decibels + 48) / 48, 0), 1)
        level = level * 0.6 + normalized * 0.4
    }

    /// RMS every 50 ms, read once per file.
    @concurrent
    private static func envelope(of url: URL) async -> [Float] {
        guard let reader = try? AudioReader(url: url) else { return [] }
        let window = Int(AudioReader.targetSampleRate / envelopeRate)
        var envelope: [Float] = []
        var sum: Float = 0
        var count = 0
        while let block = try? reader.read(maxFrames: 65_536) {
            for sample in AudioReader.mixdown(block) {
                sum += sample * sample
                count += 1
                if count == window {
                    envelope.append((sum / Float(window)).squareRoot())
                    sum = 0
                    count = 0
                }
            }
        }
        return envelope
    }

    // MARK: - Now Playing

    private func publishNowPlaying() {
        var info = nowPlaying
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = isPlaying ? playbackTime() : currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func registerRemoteCommands() {
        guard commandTargets.isEmpty else { return }
        let commands = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { event in
                MainActor.assumeIsolated { action(event) }
                return .success
            }
            commandTargets.append((command, target))
        }
        add(commands.playCommand) { [weak self] _ in self?.play() }
        add(commands.pauseCommand) { [weak self] _ in self?.pause() }
        add(commands.togglePlayPauseCommand) { [weak self] _ in self?.togglePlayback() }
        add(commands.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            self?.seek(to: event.positionTime)
        }
    }

    private func unregisterRemoteCommands() {
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
    }
}
