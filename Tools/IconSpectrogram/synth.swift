// Synthesizes one bar of a music-like mono clip (drums, 808, chords, a sung lead, air) for the app icon spectrogram.
// Usage: swift synth.swift output.wav
import Foundation

let sampleRate = 44_100.0
let bpm = 92.0
let beat = 60 / bpm
let duration = beat * 4 + 0.04
let count = Int(duration * sampleRate)
var out = [Double](repeating: 0, count: count)

struct Random {
    var state: UInt64
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 500_000 - 1
    }
}
var rng = Random(state: 0x5EED_1234_ABCD)

func add(_ start: Double, _ length: Double, _ sample: (Double) -> Double) {
    let s = Int(start * sampleRate)
    let n = Int(length * sampleRate)
    for i in 0..<n where s + i < count && s + i >= 0 {
        out[s + i] += sample(Double(i) / sampleRate)
    }
}

// One-pole high-pass for noise colouring.
func highpassed(_ x: [Double], cutoff: Double) -> [Double] {
    let rc = 1 / (2 * Double.pi * cutoff), dt = 1 / sampleRate, a = rc / (rc + dt)
    var y = [Double](repeating: 0, count: x.count)
    for i in 1..<x.count { y[i] = a * (y[i - 1] + x[i] - x[i - 1]) }
    return y
}

// One-pole low-pass: stacked, it gives the noise the downward tilt of a real mix.
func lowpassed(_ x: [Double], cutoff: Double) -> [Double] {
    let a = exp(-2 * Double.pi * cutoff / sampleRate)
    var y = [Double](repeating: 0, count: x.count)
    for i in 1..<x.count { y[i] = (1 - a) * x[i] + a * y[i - 1] }
    return y
}

// Kick: pitched sine drop with a click.
func kick(at t0: Double) {
    var phase = 0.0
    add(t0, 0.45) { t in
        let f = 48 + 110 * exp(-t * 28)
        phase += 2 * .pi * f / sampleRate
        return 0.9 * sin(phase) * exp(-t * 7) + 0.25 * exp(-t * 400) * sin(phase * 7)
    }
}

// Snare: tone plus broadband noise.
func snare(at t0: Double, gain: Double = 1) {
    let n = Int(0.32 * sampleRate)
    let noise = lowpassed(lowpassed(highpassed((0..<n).map { _ in rng.next() }, cutoff: 700), cutoff: 3_500), cutoff: 6_000)
    add(t0, 0.32) { t in
        let k = min(Int(t * sampleRate), n - 1)
        return gain * (2.2 * noise[k] * exp(-t * 18) + 0.3 * sin(2 * .pi * 190 * t) * exp(-t * 30))
    }
}

// Hi-hat: short, bright noise that reaches the top of the spectrum.
func hat(at t0: Double, open: Bool = false, gain: Double = 1) {
    let length = open ? 0.28 : 0.07
    let n = Int(length * sampleRate)
    let noise = lowpassed(lowpassed(highpassed(highpassed((0..<n).map { _ in rng.next() }, cutoff: 4_000), cutoff: 4_000), cutoff: 8_000), cutoff: 12_000)
    add(t0, length) { t in
        let k = min(Int(t * sampleRate), n - 1)
        return gain * 1.6 * noise[k] * exp(-t * (open ? 11 : 60))
    }
}

// 808 bass with soft saturation (gives it harmonics).
func bass(at t0: Double, length: Double, frequency: Double, glideTo: Double? = nil) {
    var phase = 0.0
    add(t0, length) { t in
        let f = glideTo.map { frequency + ($0 - frequency) * min(t / length, 1) } ?? frequency
        phase += 2 * .pi * f / sampleRate
        let env = min(t * 200, 1) * exp(-t * 1.3)
        return 0.55 * tanh(2.2 * sin(phase)) * env
    }
}

// Pad chord: additive harmonics rolling off gently, slow swell.
func chord(at t0: Double, length: Double, notes: [Double]) {
    add(t0, length) { t in
        var v = 0.0
        for f in notes {
            var h = 1.0
            while f * h < 9_000 {
                v += sin(2 * .pi * f * h * t + h) / (h * h * 0.6 + 1)
                h += 1
            }
        }
        return 0.035 * v * min(t * 4, 1) * min((length - t) * 6, 1)
    }
}

// Sung lead: harmonic stack with vibrato, formant colouring and a little breath.
func vocal(at t0: Double, length: Double, notes: [Double]) {
    var phase = 0.0
    add(t0, length) { t in
        let segment = min(Int(t / length * Double(notes.count)), notes.count - 1)
        let next = min(segment + 1, notes.count - 1)
        let local = t / length * Double(notes.count) - Double(segment)
        let glide = local > 0.8 ? (local - 0.8) / 0.2 : 0
        let base = notes[segment] + (notes[next] - notes[segment]) * glide
        let f = base * (1 + 0.012 * sin(2 * .pi * 5.4 * t) * min(t * 2, 1))
        phase += 2 * .pi * f / sampleRate
        var v = 0.0
        var h = 1.0
        while f * h < 12_000 {
            let fh = f * h
            let formants = exp(-pow((fh - 700) / 380, 2)) + 0.7 * exp(-pow((fh - 1_250) / 420, 2))
                + 0.35 * exp(-pow((fh - 2_800) / 700, 2)) + 0.12 * exp(-pow((fh - 4_200) / 1_200, 2))
            v += sin(phase * h) * (formants + 0.02) / sqrt(h)
            h += 1
        }
        let env = min(t * 10, 1) * min((length - t) * 5, 1)
        return 0.11 * v * env
    }
}

let sixteenth = beat / 4
for k in [0.0, 1.75, 2.5] { kick(at: k * beat) }
snare(at: beat)
snare(at: 3 * beat)
for i in 0..<16 where i % 4 != 2 || i == 14 {
    hat(at: Double(i) * sixteenth, open: i == 6, gain: i % 2 == 0 ? 1 : 0.6)
    if i == 13 || i == 15 { hat(at: (Double(i) + 0.5) * sixteenth, gain: 0.45) }
}
bass(at: 0, length: 1.75 * beat, frequency: 55)
bass(at: 1.75 * beat, length: 0.75 * beat, frequency: 65.4, glideTo: 61.7)
bass(at: 2.5 * beat, length: 1.5 * beat + 0.4, frequency: 49)
chord(at: 0, length: 2 * beat, notes: [220, 261.6, 329.6])
chord(at: 2 * beat, length: 2 * beat + 0.4, notes: [196, 246.9, 293.7])
vocal(at: 0.45 * beat, length: 1.4 * beat, notes: [329.6, 392, 440])
vocal(at: 2.1 * beat, length: 1.8 * beat, notes: [493.9, 440, 392, 329.6])

// Air: a faint reverb-like wash that keeps the top octave alive.
let airNoise = lowpassed(lowpassed(highpassed((0..<count).map { _ in rng.next() }, cutoff: 1_000), cutoff: 2_500), cutoff: 5_000)
for i in 0..<count { out[i] += 0.03 * airNoise[i] }

// Normalize and write 16-bit PCM WAV.
let peak = out.map(abs).max() ?? 1
let pcm = out.map { Int16(max(-1, min(1, $0 / peak * 0.89)) * 32_767) }
var data = Data()
func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
data.append(contentsOf: "RIFF".utf8); append(UInt32(36 + pcm.count * 2).littleEndian)
data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16).littleEndian); append(UInt16(1).littleEndian)
append(UInt16(1).littleEndian); append(UInt32(44_100).littleEndian); append(UInt32(88_200).littleEndian)
append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
data.append(contentsOf: "data".utf8); append(UInt32(pcm.count * 2).littleEndian)
for v in pcm { append(v.littleEndian) }
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(count) samples, \(String(format: "%.2f", duration)) s")
