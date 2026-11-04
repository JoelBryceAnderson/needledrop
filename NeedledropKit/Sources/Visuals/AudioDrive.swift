import Foundation
import SignalAnalysis

/// Audio values ready for shaders: 0…1, smoothed, and auto-gained so a quiet folk record
/// moves the picture as much as a loud rock one.
public struct AudioDrive: Sendable, Equatable {
    public var bass: Float = 0
    public var mids: Float = 0
    public var highs: Float = 0
    public var level: Float = 0
    /// 1 on a beat, decaying over ~150 ms.
    public var beat: Float = 0

    public init() {}
}

public struct AudioDriveFilter: Sendable {
    /// Each value is scaled against a peak that follows loud moments instantly and
    /// relaxes at `peakRelease` dB/s; `range` dB below the peak reads as 0.
    public var range: Float = 24
    public var peakRelease: Float = 6
    /// Levels below this always read as 0, so groove noise between tracks stays dark.
    public var noiseFloor: Float = -60
    public var attack = 0.03
    public var release = 0.25

    private var peaks: [Float] = [-50, -50, -50, -50]
    private var values: [Float] = [0, 0, 0, 0]

    public init() {}

    /// `beatAge`: seconds since the last tracked beat, if any.
    public mutating func update(features: AudioFeatures, beatAge: Double?, dt: Double) -> AudioDrive {
        let b = features.bands
        let raw = [
            (b.sub * b.sub + b.bass * b.bass).squareRoot(),
            b.mids,
            b.highs,
            features.musicBandRMS,
        ].map(decibels)

        for i in raw.indices {
            peaks[i] = max(raw[i], peaks[i] - peakRelease * Float(dt))
            let zero = max(noiseFloor, peaks[i] - range)
            let target = max(0, min(1, (raw[i] - zero) / max(6, peaks[i] - zero)))
            let tau = target > values[i] ? attack : release
            values[i] += (target - values[i]) * Float(1 - exp(-dt / tau))
        }

        var drive = AudioDrive()
        drive.bass = values[0]
        drive.mids = values[1]
        drive.highs = values[2]
        drive.level = values[3]
        // No pulses while the room is quiet, even if the beat clock is still running.
        drive.beat = beatAge.map { Float(exp(-max(0, $0) / 0.15)) * min(1, values[3] * 2) } ?? 0
        return drive
    }
}
