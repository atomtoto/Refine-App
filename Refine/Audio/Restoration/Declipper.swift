/// Rebuilds the tops of clipped waveform plateaus with cubic Hermite curves through their neighbours.
struct Declipper {
    var threshold: Float = LevelStatistics.clipThreshold
    var minimumRun = 3
    var maximumRun = 160

    func process(_ samples: inout [Float]) {
        let count = samples.count
        guard count > 4 else { return }
        samples.withUnsafeMutableBufferPointer { x in
            var i = 2
            while i < count - 2 {
                guard abs(x[i]) >= threshold else {
                    i += 1
                    continue
                }
                let sign: Float = x[i] > 0 ? 1 : -1
                var end = i
                while end < count, abs(x[end]) >= threshold, (x[end] > 0) == (sign > 0) { end += 1 }

                let run = end - i
                // Runs touching the block edges are left alone: they lack the context to rebuild.
                if run >= minimumRun, run <= maximumRun, end + 1 < count {
                    let a = i - 1
                    let b = end
                    let p0 = x[a], p1 = x[b]
                    let span = Float(b - a)
                    let m0 = (x[a] - x[a - 1]) * span
                    let m1 = (x[b + 1] - x[b]) * span
                    for n in i..<end {
                        let t = Float(n - a) / span
                        let t2 = t * t, t3 = t2 * t
                        let value = (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0
                            + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
                        // Only ever extend the plateau outward, never cut into it.
                        x[n] = sign * min(max(abs(x[n]), sign * value), 2)
                    }
                }
                i = end
            }
        }
    }
}
