import AVFoundation

enum AudioWriterError: LocalizedError {
    case bufferAllocationFailed

    var errorDescription: String? { "Impossible de préparer l'écriture du fichier audio." }
}

/// Writes 16-bit / 44.1 kHz stereo — the Red Book CD format — as WAV or Apple Lossless, or encodes it to
/// AAC 256 kbps, the format Apple Music streams and AirPods receive over Bluetooth.
final class AudioWriter {
    static let channelCount = 2

    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer

    init(url: URL, format: RestorationSettings.ExportFormat) throws {
        var settings: [String: Any] = [
            AVSampleRateKey: AudioReader.targetSampleRate,
            AVNumberOfChannelsKey: Self.channelCount,
        ]
        switch format {
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 16
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 256_000
            settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_VariableConstrained
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.max.rawValue
        }
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            throw AudioWriterError.bufferAllocationFailed
        }
        self.buffer = buffer
    }

    func write(_ channels: [[Int16]]) throws {
        guard let frames = channels.first?.count, frames > 0, let data = buffer.int16ChannelData else { return }
        let capacity = Int(buffer.frameCapacity)
        var offset = 0
        while offset < frames {
            let count = min(capacity, frames - offset)
            for channel in 0..<Self.channelCount {
                let source = channels[min(channel, channels.count - 1)]
                source.withUnsafeBufferPointer { source in
                    data[channel].update(from: source.baseAddress! + offset, count: count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
    }

    func close() {
        file.close()
    }
}
