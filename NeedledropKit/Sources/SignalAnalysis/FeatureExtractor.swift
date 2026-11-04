import Accelerate

/// Turns hop-sized chunks of stereo PCM into `AudioFeatures`. Synchronous and
/// deterministic: the same samples always give the same features, live or replayed.
/// Not thread-safe — owned by whichever thread drives analysis.
public final class FeatureExtractor {
    public static let displayBandCount = 40
    public static let musicBand = (low: 100.0, high: 5000.0)

    public let parameters: AnalysisParameters
    /// dBFS per log-spaced display band (30 Hz – 16 kHz), updated every hop.
    public private(set) var displaySpectrum: [Float]
    public private(set) var latest = AudioFeatures()

    private let spectrum: SpectrumAnalyzer
    private let window: UnsafeMutablePointer<Float>   // last fftSize mono samples
    private let mono: UnsafeMutablePointer<Float>
    private let bandRanges: [Range<Int>]
    private let musicRange: Range<Int>
    private let fluxRange: Range<Int>
    /// Sub-ranges of `fluxRange` (offsets into it): lows, mids, highs.
    private let fluxBands: [Range<Int>]
    private let displayRanges: [Range<Int>]
    private let logMagnitude: UnsafeMutablePointer<Float>
    private let previousLogMagnitude: UnsafeMutablePointer<Float>
    private var onsets: OnsetDetector
    private var tempo: TempoTracker
    private var framesProcessed = 0

    public init(parameters: AnalysisParameters) {
        self.parameters = parameters
        let spectrum = SpectrumAnalyzer(fftSize: parameters.fftSize, sampleRate: parameters.sampleRate)
        self.spectrum = spectrum
        window = .allocate(capacity: parameters.fftSize)
        window.initialize(repeating: 0, count: parameters.fftSize)
        mono = .allocate(capacity: parameters.hopSize)
        mono.initialize(repeating: 0, count: parameters.hopSize)

        let nyquist = parameters.sampleRate / 2
        bandRanges = BandEnergies.ranges.map { spectrum.bins(from: $0.low, to: min($0.high, nyquist)) }
        musicRange = spectrum.bins(from: Self.musicBand.low, to: Self.musicBand.high)
        let fluxRange = spectrum.bins(from: 30, to: min(10_000, nyquist))
        self.fluxRange = fluxRange
        fluxBands = [(30.0, 150.0), (150, 1000), (1000, 10_000)].map { low, high in
            let r = spectrum.bins(from: low, to: min(high, nyquist)).clamped(to: fluxRange)
            return (r.lowerBound - fluxRange.lowerBound)..<(r.upperBound - fluxRange.lowerBound)
        }

        let top = min(16_000, nyquist)
        let ratio = pow(top / 30, 1 / Double(Self.displayBandCount))
        displayRanges = (0..<Self.displayBandCount).map { i in
            spectrum.bins(from: 30 * pow(ratio, Double(i)), to: 30 * pow(ratio, Double(i + 1)))
        }
        displaySpectrum = Array(repeating: -120, count: Self.displayBandCount)

        logMagnitude = .allocate(capacity: fluxRange.count)
        logMagnitude.initialize(repeating: 0, count: fluxRange.count)
        previousLogMagnitude = .allocate(capacity: fluxRange.count)
        previousLogMagnitude.initialize(repeating: 0, count: fluxRange.count)

        onsets = OnsetDetector(hopDuration: parameters.hopDuration)
        tempo = TempoTracker(hopRate: parameters.hopRate)
    }

    deinit {
        for p in [window, mono, logMagnitude, previousLogMagnitude] { p.deallocate() }
    }

    /// Processes exactly `parameters.hopSize` frames. Pass `right: nil` for mono.
    @discardableResult
    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>?) -> AudioFeatures {
        let hop = parameters.hopSize
        let fft = parameters.fftSize
        framesProcessed += hop
        var f = AudioFeatures(time: Double(framesProcessed) / parameters.sampleRate)

        // Level & clipping, per channel.
        var peak: Float = 0
        var clipped = 0
        for channel in [left, right].compactMap({ $0 }) {
            var channelPeak: Float = 0
            vDSP_maxmgv(channel, 1, &channelPeak, vDSP_Length(hop))
            peak = max(peak, channelPeak)
            if channelPeak >= 0.999 {
                for i in 0..<hop where abs(channel[i]) >= 0.999 { clipped += 1 }
            }
        }
        f.peak = peak
        f.clippedSamples = clipped

        // Mono downmix into the tail of the sliding window.
        if let right {
            var half: Float = 0.5
            vDSP_vasm(left, 1, right, 1, &half, mono, 1, vDSP_Length(hop))
        } else {
            mono.update(from: left, count: hop)
        }
        vDSP_rmsqv(mono, 1, &f.rms, vDSP_Length(hop))
        window.update(from: window + hop, count: fft - hop)
        (window + fft - hop).update(from: mono, count: hop)

        spectrum.analyze(window)

        let b = bandRanges.map { sqrtf(spectrum.sum($0)) }
        f.bands = BandEnergies(sub: b[0], bass: b[1], mids: b[2], highs: b[3])
        f.musicBandRMS = sqrtf(spectrum.sum(musicRange))
        f.flatness = spectrum.flatness(musicRange)
        f.flux = spectralFlux()

        let onsetTime = onsets.process(flux: f.flux, time: f.time)
        f.onset = onsetTime != nil
        (f.tempo, f.beat, f.beatPhase) = tempo.process(flux: f.flux, onsetTime: onsetTime, time: f.time)

        for (i, range) in displayRanges.enumerated() {
            displaySpectrum[i] = 10 * log10f(max(spectrum.sum(range), 1e-12))
        }
        latest = f
        return f
    }

    /// Half-wave-rectified rise in log magnitude, averaged within lows / mids / highs and
    /// then across them, so a kick counts as much as a broadband snare. Without the split
    /// a backbeat makes the envelope repeat every two beats and tempo comes out halved.
    private func spectralFlux() -> Float {
        let count = fluxRange.count
        var n = Int32(count)
        vvsqrtf(logMagnitude, spectrum.power + fluxRange.lowerBound, &n)
        var gain: Float = 1000
        vDSP_vsmul(logMagnitude, 1, &gain, logMagnitude, 1, vDSP_Length(count))
        vvlog1pf(logMagnitude, logMagnitude, &n)

        var flux: Float = 0
        for band in fluxBands where !band.isEmpty {
            var bandFlux: Float = 0
            for k in band {
                let rise = logMagnitude[k] - previousLogMagnitude[k]
                if rise > 0 { bandFlux += rise }
            }
            flux += bandFlux / Float(band.count)
        }
        previousLogMagnitude.update(from: logMagnitude, count: count)
        return flux / Float(fluxBands.count)
    }
}
