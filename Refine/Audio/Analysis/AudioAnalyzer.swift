import Foundation

struct AnalysisOutput: Sendable {
    var analysis: AudioAnalysis
    var spectrogramPNG: Data?
}

enum AudioAnalyzer {
    /// Decodes the whole file once, off the main actor, and inspects its spectrum.
    @concurrent
    static func analyze(url: URL) async throws -> AnalysisOutput {
        let reader = try AudioReader(url: url)
        let collector = SpectrumCollector(sampleRate: AudioReader.targetSampleRate, expectedSamples: reader.estimatedFrameCount)
        var levels = LevelStatistics()

        while let block = try reader.read(maxFrames: 65_536) {
            try Task.checkCancellation()
            levels.consume(block)
            collector.consume(AudioReader.mixdown(block))
        }

        let analysis = makeAnalysis(
            collector: collector, levels: levels, codec: reader.codec,
            sourceSampleRate: reader.sourceSampleRate, channelCount: reader.channelCount)
        return AnalysisOutput(analysis: analysis, spectrogramPNG: collector.makeImage().flatMap(SpectrogramRenderer.pngData))
    }

    static func makeAnalysis(
        collector: SpectrumCollector, levels: LevelStatistics, codec: AudioCodec,
        sourceSampleRate: Double, channelCount: Int
    ) -> AudioAnalysis {
        let detection = CutoffDetector.detect(averagePower: collector.averagePower, sampleRate: collector.sampleRate)
        return AudioAnalysis(
            codec: codec,
            sourceSampleRate: sourceSampleRate,
            channelCount: channelCount,
            duration: Double(collector.processedSamples) / collector.sampleRate,
            declaredBitrate: nil,
            cutoffFrequency: detection.cutoff,
            spectralSlope: detection.slope,
            clippingRatio: levels.clippingRatio,
            peak: Double(levels.peak),
            verdict: AudioAnalysis.verdict(cutoff: detection.cutoff, codec: codec),
            estimatedBitrate: AudioAnalysis.estimatedBitrate(forCutoff: detection.cutoff))
    }
}
