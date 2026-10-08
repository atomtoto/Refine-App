import Foundation

/// Final stage before 16-bit: soft-knee peak protection and TPDF dither.
struct OutputConditioner {
    /// Above this level, peaks are bent smoothly towards full scale instead of hard-clipping.
    static let knee: Float = 0.92

    private var random: SeededRandom

    init(seed: UInt64 = 0x5EED) {
        random = SeededRandom(seed: seed)
    }

    static func softClip(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > knee else { return x }
        let headroom = 1 - knee
        let bent = knee + headroom * tanh((magnitude - knee) / headroom)
        return x < 0 ? -bent : bent
    }

    /// Converts float channels to 16-bit. Mono input is duplicated to stereo.
    mutating func process(_ channels: [[Float]]) -> [[Int16]] {
        let converted = channels.map { channel in
            channel.map { sample -> Int16 in
                let dither = random.nextUnit() - random.nextUnit()
                let scaled = Self.softClip(sample) * 32_767 + dither
                return Int16(clamping: Int(scaled.rounded()))
            }
        }
        return converted.count == 1 ? [converted[0], converted[0]] : converted
    }
}
