import Accelerate

/// Tempo by autocorrelation of the onset-strength envelope (with a log-normal prior
/// centred on 120 BPM to settle octave ambiguity), plus a simple phase-locked beat
/// clock that's nudged towards detected onsets.
struct TempoTracker {
    let hopRate: Double
    var minimumBPM = 60.0
    var maximumBPM = 180.0
    var priorCentreBPM = 120.0
    var priorWidthOctaves = 0.8

    private var envelope: [Float]
    private var writeIndex = 0
    private var filled = 0
    private var hopsUntilEstimate = 0
    private let estimateInterval: Int

    private(set) var bpm: Double?
    private var pendingBPM: Double?
    private var pendingCount = 0
    private var nextBeat: Double?
    private var lastOnsetTime = -Double.infinity

    init(hopRate: Double, window: Double = 6) {
        self.hopRate = hopRate
        envelope = Array(repeating: 0, count: Int(window * hopRate))
        estimateInterval = max(1, Int(hopRate / 2))
    }

    mutating func process(flux: Float, onsetTime: Double?, time: Double) -> (tempo: Double?, beat: Bool, phase: Float) {
        envelope[writeIndex] = flux
        writeIndex = (writeIndex + 1) % envelope.count
        filled = min(filled + 1, envelope.count)
        if let onsetTime { lastOnsetTime = onsetTime }

        if time - lastOnsetTime > 4 {
            // Music stopped (or never started): forget the tempo.
            bpm = nil
            pendingBPM = nil
            pendingCount = 0
            nextBeat = nil
        } else {
            hopsUntilEstimate -= 1
            if hopsUntilEstimate <= 0 {
                hopsUntilEstimate = estimateInterval
                if let estimate = estimate() { accept(estimate) }
            }
        }

        guard let bpm else { return (nil, false, 0) }
        let period = 60 / bpm
        guard var next = nextBeat else {
            // Anchor the beat clock on the first onset after tempo locks.
            if let onsetTime { nextBeat = onsetTime + period }
            return (bpm, onsetTime != nil, 0)
        }

        if let onsetTime {
            let errorToNext = onsetTime - next
            let errorToPrevious = onsetTime - (next - period)
            let error = abs(errorToPrevious) < abs(errorToNext) ? errorToPrevious : errorToNext
            if abs(error) < 0.2 * period { next += error * 0.25 }
        }
        var beat = false
        while time >= next {
            beat = true
            next += period
        }
        nextBeat = next
        let phase = Float(min(1, max(0, 1 - (next - time) / period)))
        return (bpm, beat, phase)
    }

    private mutating func accept(_ estimate: Double) {
        if let current = bpm, abs(estimate - current) / current < 0.04 {
            bpm = current * 0.8 + estimate * 0.2
            pendingCount = 0
            return
        }
        if let pending = pendingBPM, abs(estimate - pending) / pending < 0.04 {
            pendingCount += 1
        } else {
            pendingBPM = estimate
            pendingCount = 1
        }
        // A new tempo has to show up twice in a row (~1 s) before we switch to it.
        if pendingCount >= 2, let pending = pendingBPM {
            if bpm != nil { nextBeat = nil }
            bpm = pending
            pendingCount = 0
        }
    }

    private func estimate() -> Double? {
        let n = filled
        guard n >= Int(3 * hopRate) else { return nil }
        let minLag = max(2, Int((hopRate * 60 / maximumBPM).rounded(.down)))
        let maxLag = Int((hopRate * 60 / minimumBPM).rounded(.up))
        guard maxLag + 1 < n / 2 else { return nil }

        // Oldest-first, mean-removed copy of the envelope.
        var x = [Float](repeating: 0, count: n)
        let start = filled < envelope.count ? 0 : writeIndex
        for i in 0..<n { x[i] = envelope[(start + i) % envelope.count] }
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(n))
        var negativeMean = -mean
        vDSP_vsadd(x, 1, &negativeMean, &x, 1, vDSP_Length(n))

        var energy: Float = 0
        vDSP_dotpr(x, 1, x, 1, &energy, vDSP_Length(n))
        energy /= Float(n)
        guard energy > 1e-9 else { return nil }

        var acf = [Float](repeating: 0, count: maxLag + 2)
        x.withUnsafeBufferPointer { p in
            for lag in (minLag - 1)...(maxLag + 1) {
                var s: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(n - lag))
                acf[lag] = s / Float(n - lag)
            }
        }

        var bestLag = 0
        var bestScore: Float = -.infinity
        for lag in minLag...maxLag {
            let bpm = 60 * hopRate / Double(lag)
            let octaves = log2(bpm / priorCentreBPM) / priorWidthOctaves
            let score = acf[lag] * Float(exp(-0.5 * octaves * octaves))
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        // Require real periodicity, not just noise.
        guard acf[bestLag] / energy > 0.1 else { return nil }

        let a = acf[bestLag - 1], b = acf[bestLag], c = acf[bestLag + 1]
        let denominator = a - 2 * b + c
        let offset = denominator != 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) : 0
        return 60 * hopRate / (Double(bestLag) + Double(offset))
    }
}
