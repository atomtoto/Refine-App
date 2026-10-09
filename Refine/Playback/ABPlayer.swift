import AVFoundation
import Accelerate
import Observation

/// Plays the original and the restored file in lockstep, so switching between them is instant and
/// stays on the same beat.
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
    /// Whether the louder version is turned down to the other's loudness, so neither wins by volume alone.
    private(set) var isLoudnessMatched = false
    var source: Source = .original {
        didSet { if source != oldValue { crossfade() } }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let originalNode = AVAudioPlayerNode()
    @ObservationIgnored private let restoredNode = AVAudioPlayerNode()
    @ObservationIgnored private var originalFile: AVAudioFile?
    @ObservationIgnored private var restoredFile: AVAudioFile?
    @ObservationIgnored private var segmentStart: TimeInterval = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var fade: Task<Void, Never>?
    @ObservationIgnored private var restoredMix: Float = 0
    @ObservationIgnored private var trims: (original: Float, restored: Float) = (1, 1)

    init() {
        engine.attach(originalNode)
        engine.attach(restoredNode)
        updateRoute()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in self?.updateRoute() }
        }
    }

    func load(original: URL, restored: URL?) throws {
        stop()
        engine.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.disconnectNodeOutput(originalNode)
        engine.disconnectNodeOutput(restoredNode)

        let original = try AVAudioFile(forReading: original)
        originalFile = original
        restoredFile = try restored.map { try AVAudioFile(forReading: $0) }
        try engine.connectNode(originalNode, to: engine.mainMixerNode, format: original.processingFormat)
        if let restoredFile {
            try engine.connectNode(restoredNode, to: engine.mainMixerNode, format: restoredFile.processingFormat)
        }

        duration = Double(original.length) / original.processingFormat.sampleRate
        currentTime = min(currentTime, duration)
        hasRestored = restoredFile != nil
        if !hasRestored { source = .original }
        applyVolumes(restoredMix: source == .restored ? 1 : 0)

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil, block: Self.levelTap { [weak self] rms in
            Task { @MainActor in self?.updateLevel(rms) }
        })
        engine.prepare()
    }

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

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard originalFile != nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            updateRoute()
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }
        if currentTime >= duration - 0.05 { currentTime = 0 }
        startNodes(at: currentTime)
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func pause() {
        currentTime = playbackTime()
        stopNodes()
        isPlaying = false
        ticker?.cancel()
        level = 0
    }

    func stop() {
        stopNodes()
        isPlaying = false
        ticker?.cancel()
        currentTime = 0
        level = 0
    }

    func seek(to time: TimeInterval) {
        currentTime = min(max(time, 0), duration)
        if isPlaying { startNodes(at: currentTime) }
    }

    // MARK: - Scheduling

    private func startNodes(at time: TimeInterval) {
        stopNodes()
        let generation = generation
        let pairs: [(AVAudioPlayerNode, AVAudioFile?)] = [(originalNode, originalFile), (restoredNode, restoredFile)]
        for (node, file) in pairs {
            guard let file else { continue }
            let startFrame = AVAudioFramePosition(time * file.processingFormat.sampleRate)
            let remaining = file.length - startFrame
            guard remaining > 0 else { continue }
            let isLeader = node === originalNode
            node.scheduleSegment(
                file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining), at: nil,
                completionCallbackType: .dataPlayedBack
            ) { @Sendable [weak self] _ in
                guard isLeader else { return }
                Task { @MainActor in self?.segmentFinished(generation: generation) }
            }
        }
        segmentStart = time
        // A shared start time in the near future keeps both nodes sample-aligned.
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        try? originalNode.playAudio(at: start)
        if restoredFile != nil { try? restoredNode.playAudio(at: start) }
    }

    private func stopNodes() {
        generation += 1
        originalNode.stop()
        restoredNode.stop()
    }

    private func segmentFinished(generation: Int) {
        guard generation == self.generation, isPlaying else { return }
        stop()
    }

    private func playbackTime() -> TimeInterval {
        guard isPlaying,
              let nodeTime = originalNode.lastRenderTime,
              let playerTime = originalNode.playerTime(forNodeTime: nodeTime)
        else { return currentTime }
        return min(segmentStart + max(0, Double(playerTime.sampleTime) / playerTime.sampleRate), duration)
    }

    private func tick() {
        currentTime = playbackTime()
    }

    private func updateRoute() {
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        isBluetoothOutput = AVAudioSession.sharedInstance().currentRoute.outputs.contains { bluetooth.contains($0.portType) }
    }

    // MARK: - A/B

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
        restoredNode.volume = restoredMix * trims.restored
        originalNode.volume = (1 - restoredMix) * trims.original
    }

    // MARK: - Level

    private func updateLevel(_ rms: Float) {
        guard isPlaying else { return }
        let decibels = 20 * log10(max(rms, 1e-6))
        let normalized = min(max((decibels + 48) / 48, 0), 1)
        level = level * 0.6 + normalized * 0.4
    }

    /// Built outside the main actor: the tap runs on the audio render thread.
    nonisolated private static func levelTap(_ report: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            report(rms)
        }
    }
}
