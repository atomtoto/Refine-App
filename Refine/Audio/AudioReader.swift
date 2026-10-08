import AVFoundation

enum AudioReaderError: LocalizedError {
    case unsupportedFormat
    case conversionFailed(NSError?)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Ce format audio n'est pas pris en charge."
        case .conversionFailed(let error): error?.localizedDescription ?? "La conversion audio a échoué."
        }
    }
}

/// Streams any file Core Audio can decode as deinterleaved Float32 blocks at the CD sample rate.
/// Only the first two channels are kept.
final class AudioReader {
    static let targetSampleRate: Double = 44_100

    let codec: AudioCodec
    let sourceSampleRate: Double
    let channelCount: Int
    /// Length in frames at the target rate (an estimate for VBR files).
    let estimatedFrameCount: Int
    var duration: TimeInterval { Double(estimatedFrameCount) / Self.targetSampleRate }

    private let file: AVAudioFile
    private let sourceBuffer: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    private let convertedFormat: AVAudioFormat
    private var sourceExhausted = false

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768)
        else { throw AudioReaderError.unsupportedFormat }

        codec = AudioCodec(formatID: file.fileFormat.streamDescription.pointee.mFormatID)
        sourceSampleRate = format.sampleRate
        channelCount = min(Int(format.channelCount), 2)
        sourceBuffer = buffer
        estimatedFrameCount = Int(Double(file.length) * Self.targetSampleRate / format.sampleRate)

        if format.sampleRate == Self.targetSampleRate {
            converter = nil
            convertedFormat = format
        } else {
            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate,
                channels: format.channelCount, interleaved: false),
                  let converter = AVAudioConverter(from: format, to: target)
            else { throw AudioReaderError.unsupportedFormat }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            self.converter = converter
            convertedFormat = target
        }
    }

    /// Next block of up to `maxFrames` frames per channel, or `nil` at the end of the file.
    func read(maxFrames: Int = 32_768) throws -> [[Float]]? {
        guard let converter else {
            guard file.framePosition < file.length else { return nil }
            let count = AVAudioFrameCount(min(maxFrames, Int(sourceBuffer.frameCapacity)))
            try file.read(into: sourceBuffer, frameCount: count)
            return sourceBuffer.frameLength > 0 ? channels(of: sourceBuffer) : nil
        }

        guard let output = AVAudioPCMBuffer(pcmFormat: convertedFormat, frameCapacity: AVAudioFrameCount(maxFrames)) else {
            throw AudioReaderError.unsupportedFormat
        }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [self] packetCount, inputStatus in
            // A fresh buffer each time: the converter may still hold the previous one's unread frames.
            if !sourceExhausted,
               let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: packetCount) {
                try? file.read(into: input, frameCount: packetCount)
                if input.frameLength > 0 {
                    inputStatus.pointee = .haveData
                    return input
                }
                sourceExhausted = true
            }
            inputStatus.pointee = .endOfStream
            return nil
        }
        if status == .error { throw AudioReaderError.conversionFailed(error) }
        return output.frameLength > 0 ? channels(of: output) : nil
    }

    private func channels(of buffer: AVAudioPCMBuffer) -> [[Float]] {
        let frames = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { return [] }
        return (0..<channelCount).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
    }

    static func mixdown(_ channels: [[Float]]) -> [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        var mono = channels[0]
        for channel in channels.dropFirst() {
            mono.withUnsafeMutableBufferPointer { mono in
                for i in 0..<min(mono.count, channel.count) { mono[i] += channel[i] }
            }
        }
        let scale = 1 / Float(channels.count)
        return mono.map { $0 * scale }
    }
}
