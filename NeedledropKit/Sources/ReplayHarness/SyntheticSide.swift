import AVFAudio
import Foundation

/// Generates a plausible vinyl side — lead-in groove noise with crackle, tracks with
/// drums and chords at known tempos, gaps, a clicking run-out — with ground truth.
/// Lets every part of the pipeline be tested without a turntable.
public struct SyntheticSide: Sendable {
    public enum Segment: Sendable {
        /// Groove hiss and crackle only.
        case surfaceNoise(seconds: Double)
        /// Music over the surface noise. `abruptEnd` cuts off instead of fading.
        case track(seconds: Double, bpm: Double, rootHz: Double, abruptEnd: Bool = false)
        /// Locked run-out groove: surface noise plus a thump every revolution.
        case runout(seconds: Double, rpm: Double = 100.0 / 3)
        /// Needle off the record: true digital silence.
        case digitalSilence(seconds: Double)
    }

    public struct Truth: Sendable {
        public struct Track: Sendable {
            public var start: Double
            public var end: Double
            public var bpm: Double
        }
        public var tracks: [Track]
        public var duration: Double
    }

    public var sampleRate: Double
    public var segments: [Segment]
    public var seed: UInt64
    /// Groove hiss RMS (full band), dBFS.
    public var surfaceNoiseDB: Float = -54
    public var cracklePerSecond: Double = 8

    public init(sampleRate: Double = 48_000, segments: [Segment], seed: UInt64 = 1) {
        self.sampleRate = sampleRate
        self.segments = segments
        self.seed = seed
    }

    /// ~80 s side: 3 tracks (120, 96, 140 BPM), the second ending abruptly.
    public static func demo(sampleRate: Double = 48_000) -> SyntheticSide {
        SyntheticSide(sampleRate: sampleRate, segments: [
            .surfaceNoise(seconds: 4),
            .track(seconds: 24, bpm: 120, rootHz: 220),
            .surfaceNoise(seconds: 3),
            .track(seconds: 20, bpm: 96, rootHz: 196, abruptEnd: true),
            .surfaceNoise(seconds: 2.5),
            .track(seconds: 16, bpm: 140, rootHz: 261.63),
            .runout(seconds: 12),
            .digitalSilence(seconds: 1),
        ])
    }

    public func render() -> (left: [Float], right: [Float], truth: Truth) {
        var rng = SplitMix64(seed: seed)
        var left: [Float] = []
        var right: [Float] = []
        var tracks: [Truth.Track] = []
        let hiss = powf(10, surfaceNoiseDB / 20)
        let crackleProbability = cracklePerSecond / sampleRate

        for segment in segments {
            let start = Double(left.count) / sampleRate
            switch segment {
            case .digitalSilence(let seconds):
                let n = Int(seconds * sampleRate)
                left += repeatElement(0, count: n)
                right += repeatElement(0, count: n)
                continue
            case .surfaceNoise(let seconds), .runout(let seconds, _), .track(let seconds, _, _, _):
                let n = Int(seconds * sampleRate)
                var l = [Float](repeating: 0, count: n)
                var r = [Float](repeating: 0, count: n)
                // Hiss + crackle on everything that isn't digital silence.
                for i in 0..<n {
                    l[i] = rng.gaussian() * hiss
                    r[i] = rng.gaussian() * hiss
                    if rng.unit() < crackleProbability {
                        let a = Float(0.05 + 0.35 * rng.unit()) * (rng.unit() < 0.5 ? -1 : 1)
                        l[i] += a
                        r[i] += a * 0.7
                    }
                }
                if case .runout(_, let rpm) = segment {
                    addRunoutThumps(&l, &r, period: 60 / rpm)
                }
                if case .track(_, let bpm, let root, let abrupt) = segment {
                    addMusic(&l, &r, bpm: bpm, root: root, abruptEnd: abrupt, rng: &rng)
                    tracks.append(.init(start: start, end: start + seconds, bpm: bpm))
                }
                left += l.map { max(-1, min(1, $0)) }
                right += r.map { max(-1, min(1, $0)) }
            }
        }
        return (left, right, Truth(tracks: tracks, duration: Double(left.count) / sampleRate))
    }

    /// Writes a 24-bit stereo WAV, like a typical USB interface capture.
    @discardableResult
    public func write(to url: URL) throws -> Truth {
        let (left, right, truth) = render()
        try Self.writeWAV(left: left, right: right, sampleRate: sampleRate, to: url)
        return truth
    }

    public static func writeWAV(left: [Float], right: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)),
              let data = buffer.floatChannelData else { throw CocoaError(.fileWriteUnknown) }
        var position = 0
        while position < left.count {
            let n = min(chunk, left.count - position)
            left.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress! + position, count: n) }
            right.withUnsafeBufferPointer { data[1].update(from: $0.baseAddress! + position, count: n) }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            position += n
        }
    }

    // MARK: - Synthesis

    private func addMusic(_ l: inout [Float], _ r: inout [Float], bpm: Double, root: Double, abruptEnd: Bool,
                          rng: inout SplitMix64) {
        let n = l.count
        let sr = sampleRate
        let fadeIn = Int(0.02 * sr)
        let fadeOut = Int((abruptEnd ? 0.01 : 1.5) * sr)
        let ratios: [Double] = [1, 1.25, 1.5, 2]

        // Sustained chord with slow tremolo.
        for i in 0..<n {
            let t = Double(i) / sr
            var envelope = 1.0
            if i < fadeIn { envelope = Double(i) / Double(fadeIn) }
            if i > n - fadeOut { envelope = Double(n - i) / Double(fadeOut) }
            let tremolo = 0.85 + 0.15 * sin(2 * .pi * 0.3 * t)
            var sampleL = 0.0, sampleR = 0.0
            for (k, ratio) in ratios.enumerated() {
                let s = 0.08 * sin(2 * .pi * root * ratio * t)
                sampleL += s * (k % 2 == 0 ? 1.0 : 0.8)
                sampleR += s * (k % 2 == 0 ? 0.8 : 1.0)
            }
            l[i] += Float(sampleL * envelope * tremolo)
            r[i] += Float(sampleR * envelope * tremolo)
        }

        // Kick every beat, snare on 2 and 4, stopping before the fade.
        let period = 60 / bpm
        let usable = Double(n - fadeOut) / sr
        var beat = 0
        while Double(beat) * period + 0.05 < usable - 0.3 {
            let onset = Int((Double(beat) * period + 0.05) * sr)
            let length = min(Int(0.3 * sr), n - onset)
            for j in 0..<length {
                let tau = Double(j) / sr
                let phase = 2 * .pi * (50 * tau + 100 * 0.03 * (1 - exp(-tau / 0.03)))
                var s = 0.45 * exp(-tau / 0.12) * sin(phase)
                if beat % 2 == 1 {
                    s += 0.12 * exp(-tau / 0.05) * Double(rng.gaussian())
                    s += 0.08 * exp(-tau / 0.08) * sin(2 * .pi * 200 * tau)
                }
                l[onset + j] += Float(s)
                r[onset + j] += Float(s)
            }
            beat += 1
        }
    }

    private func addRunoutThumps(_ l: inout [Float], _ r: inout [Float], period: Double) {
        var t = 0.4
        while Int(t * sampleRate) < l.count {
            let onset = Int(t * sampleRate)
            for j in 0..<min(Int(0.005 * sampleRate), l.count - onset) {
                let s = Float(0.3 * exp(-Double(j) / (0.001 * sampleRate)))
                l[onset + j] += s
                r[onset + j] += s
            }
            t += period
        }
    }
}

/// Small deterministic PRNG so fixtures are identical run to run.
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Approximately standard normal (sum of uniforms — cheap and good enough for hiss).
    mutating func gaussian() -> Float {
        Float((unit() + unit() + unit() + unit() - 2) * 1.7320508)
    }
}
