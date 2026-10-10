// Renders the app icon background: a before/after spectrogram, the decoded MP3 on the left half and the
// full-band source on the right, with Refine's spectrogram palette (`SpectrogramRenderer`).
// Also writes a greyscale version for the tinted appearances, where the system reads luminance as opacity.
// Usage: swift spectrogram.swift source.wav decoded-mp3.wav color.png mono.png
import Accelerate
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let size = 1024
let fftSize = 2048 // 1024 bins: one pixel row per bin, 0 Hz to Nyquist on a linear axis like the app.
let floorDecibels: Float = -100
let ceilingDecibels: Float = -24
let monoGain: Float = 1.5
let monoGamma: Float = 0.7

func readMono(_ path: String) -> [Float] {
    let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    precondition(file.processingFormat.sampleRate == 44_100, "\(path) must be 44.1 kHz")
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: buffer)
    let channels = Int(buffer.format.channelCount)
    return (0..<Int(buffer.frameLength)).map { i in
        (0..<channels).reduce(0) { $0 + buffer.floatChannelData![$1][i] } / Float(channels)
    }
}

/// Power columns relative to a full-scale sine, `size` frames spread over the whole clip.
func spectrogram(_ signal: [Float]) -> [[Float]] {
    let log2n = vDSP_Length(log2(Float(fftSize)))
    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    var window = [Float](repeating: 0, count: fftSize)
    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    let normalization = pow(window.reduce(0, +), 2)
    let hop = Double(signal.count - fftSize) / Double(size - 1)
    var real = [Float](repeating: 0, count: fftSize / 2)
    var imaginary = [Float](repeating: 0, count: fftSize / 2)

    return (0..<size).map { column in
        let start = Int((Double(column) * hop).rounded())
        let frame = (0..<fftSize).map { signal[start + $0] * window[$0] }
        var power = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                frame.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                for bin in 1..<(fftSize / 2) {
                    power[bin] = (re[bin] * re[bin] + im[bin] * im[bin]) / normalization
                }
                power[0] = power[1]
            }
        }
        return power
    }
}

/// 3×3 box blur: keeps the texture of noise from turning into grain at icon sizes.
func smoothed(_ columns: [[Float]]) -> [[Float]] {
    columns.indices.map { x in
        columns[x].indices.map { bin in
            var sum: Float = 0
            var weight: Float = 0
            for dx in -1...1 where columns.indices.contains(x + dx) {
                for db in -1...1 where columns[x].indices.contains(bin + db) {
                    sum += columns[x + dx][bin + db]
                    weight += 1
                }
            }
            return sum / weight
        }
    }
}

let stops: [(position: Float, color: SIMD3<Float>)] = [
    (0.00, [0.03, 0.02, 0.09]),
    (0.22, [0.17, 0.06, 0.38]),
    (0.45, [0.52, 0.11, 0.58]),
    (0.65, [0.89, 0.28, 0.45]),
    (0.83, [0.99, 0.60, 0.27]),
    (1.00, [1.00, 0.95, 0.74]),
]

func paletteColor(_ value: Float) -> SIMD3<Float> {
    for (lower, upper) in zip(stops, stops.dropFirst()) where value <= upper.position {
        let local = (value - lower.position) / (upper.position - lower.position)
        return lower.color + (upper.color - lower.color) * local
    }
    return stops[stops.count - 1].color
}

func writePNG(_ path: String, color: (Float) -> SIMD3<Float>, columns: (Int) -> [Float]) {
    var pixels = [UInt8](repeating: 255, count: size * size * 4)
    for x in 0..<size {
        let column = columns(x)
        for bin in 0..<size {
            let decibels = 10 * log10(max(column[bin], 1e-20))
            let value = min(max((decibels - floorDecibels) / (ceilingDecibels - floorDecibels), 0), 1)
            let rgb = color(value)
            let index = ((size - 1 - bin) * size + x) * 4
            pixels[index] = UInt8(rgb.x * 255)
            pixels[index + 1] = UInt8(rgb.y * 255)
            pixels[index + 2] = UInt8(rgb.z * 255)
        }
    }
    let image = CGImage(
        width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let source = smoothed(spectrogram(readMono(arguments[1])))
let decoded = smoothed(spectrogram(readMono(arguments[2])))
let beforeAfter = { (x: Int) in x < size / 2 ? decoded[x] : source[x] }
writePNG(arguments[3], color: paletteColor, columns: beforeAfter)
writePNG(arguments[4], color: { SIMD3(repeating: pow(min($0 * monoGain, 1), monoGamma)) }, columns: beforeAfter)
