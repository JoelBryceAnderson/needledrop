import Accelerate

/// Frame/hop sizing, scaled so time and frequency resolution stay roughly constant
/// across 44.1–192 kHz.
public struct AnalysisParameters: Sendable, Equatable {
    public var sampleRate: Double
    public var fftSize: Int
    public var hopSize: Int

    public init(sampleRate: Double, fftSize: Int, hopSize: Int) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hopSize = hopSize
    }

    /// ~43 ms window, ~11 ms hop (2048/512 at 48 kHz, 4096/1024 at 96 kHz).
    public static func standard(sampleRate: Double) -> AnalysisParameters {
        var fft = 2048
        while Double(fft) * 48_000 / sampleRate < 1800 { fft *= 2 }
        return AnalysisParameters(sampleRate: sampleRate, fftSize: fft, hopSize: fft / 4)
    }

    public var hopDuration: Double { Double(hopSize) / sampleRate }
    public var hopRate: Double { sampleRate / Double(hopSize) }
}

/// Hann-windowed real FFT producing a power spectrum whose bins sum to mean-square
/// amplitude: summing a band's bins gives that band's RMS², and summing every bin gives
/// the frame's (window-corrected) mean square. That keeps band levels in real dBFS.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    public let sampleRate: Double
    public var binCount: Int { fftSize / 2 + 1 }
    public var binWidth: Double { sampleRate / Double(fftSize) }

    /// `binCount` values; see type docs for scaling.
    public let power: UnsafeMutablePointer<Float>

    private let setup: vDSP_DFT_Setup
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let inReal, inImag, outReal, outImag: UnsafeMutablePointer<Float>
    private let powerScale: Float

    public init(fftSize: Int, sampleRate: Double) {
        precondition(fftSize >= 16 && fftSize.nonzeroBitCount == 1, "fftSize must be a power of two")
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
            fatalError("vDSP_DFT_zrop_CreateSetup failed for size \(fftSize)")
        }
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.setup = setup
        let half = fftSize / 2

        window = .allocate(capacity: fftSize)
        vDSP_hann_window(window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        var meanSquareWindow: Float = 0
        vDSP_measqv(window, 1, &meanSquareWindow, vDSP_Length(fftSize))
        // zrop output is 2× the mathematical DFT, so |X|² = mags / 4. One-sided band mean
        // square = 2·Σ|X|² / (N²·mean(w²)) = Σ mags / (2·N²·mean(w²)).
        powerScale = 1 / (2 * Float(fftSize) * Float(fftSize) * meanSquareWindow)

        windowed = .allocate(capacity: fftSize)
        inReal = .allocate(capacity: half)
        inImag = .allocate(capacity: half)
        outReal = .allocate(capacity: half)
        outImag = .allocate(capacity: half)
        power = .allocate(capacity: half + 1)
        power.initialize(repeating: 0, count: half + 1)
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
        for p in [window, windowed, inReal, inImag, outReal, outImag, power] { p.deallocate() }
    }

    /// Analyzes `fftSize` contiguous samples and fills `power`.
    public func analyze(_ samples: UnsafePointer<Float>) {
        let n = vDSP_Length(fftSize)
        let half = fftSize / 2
        vDSP_vmul(samples, 1, window, 1, windowed, 1, n)
        // Pack even/odd samples into the real/imag halves zrop expects.
        var split = DSPSplitComplex(realp: inReal, imagp: inImag)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_DFT_Execute(setup, inReal, inImag, outReal, outImag)

        // Bin 0 carries DC in real and Nyquist in imag; both are one-sided (weight 1, not 2).
        power[0] = outReal[0] * outReal[0] * powerScale / 2
        power[half] = outImag[0] * outImag[0] * powerScale / 2
        var bins = DSPSplitComplex(realp: outReal + 1, imagp: outImag + 1)
        vDSP_zvmags(&bins, 1, power + 1, 1, vDSP_Length(half - 1))
        var scale = powerScale
        vDSP_vsmul(power + 1, 1, &scale, power + 1, 1, vDSP_Length(half - 1))
    }

    /// Bins whose centre frequency lies in `[low, high)`, never empty.
    public func bins(from low: Double, to high: Double) -> Range<Int> {
        let lower = max(1, min(binCount - 1, Int((low / binWidth).rounded(.up))))
        let upper = max(lower + 1, min(binCount, Int((high / binWidth).rounded(.up))))
        return lower..<upper
    }

    public func sum(_ range: Range<Int>) -> Float {
        var total: Float = 0
        vDSP_sve(power + range.lowerBound, 1, &total, vDSP_Length(range.count))
        return total
    }

    /// Spectral flatness (geometric / arithmetic mean of power) over `range`.
    /// ~0 for tones, ~0.56 for white noise per frame; 1 for digital silence.
    public func flatness(_ range: Range<Int>) -> Float {
        var logSum: Float = 0
        var arithmetic: Float = 0
        for k in range {
            let p = power[k]
            arithmetic += p
            logSum += logf(p + 1e-20)
        }
        let count = Float(range.count)
        arithmetic /= count
        guard arithmetic > 1e-14 else { return 1 }
        return min(1, expf(logSum / count) / arithmetic)
    }
}

/// Linear amplitude → dBFS, floored at -200.
@inlinable
public func decibels(_ amplitude: Float) -> Float {
    20 * log10f(max(amplitude, 1e-10))
}
