import Foundation

/// Turns a few measured levels into advice and side-detector settings, for the setup
/// assistant. Pure, so the arithmetic is testable without a turntable.
public enum Calibration {
    public enum GainAdvice: Equatable, Sendable {
        /// Nothing arriving: check the cable / input.
        case noSignal
        case tooQuiet(raiseByDB: Int)
        case good
        case tooHot(lowerByDB: Int)
        case clipping

        public var message: String {
            switch self {
            case .noSignal: "No signal. Check the turntable is playing into the interface you picked."
            case .tooQuiet(let db): "Quiet: turn the interface gain up about \(db) dB."
            case .good: "Good level."
            case .tooHot(let db): "A little hot: turn the gain down about \(db) dB."
            case .clipping: "Clipping. Turn the interface gain down until the CLIP light stays off."
            }
        }
    }

    /// From the loudest peak of a loud passage. Aims for peaks around -9 dBFS: plenty of
    /// headroom for a hot pressing, plenty of signal for recognition and the archive.
    public static func gainAdvice(peakDB: Float, clipped: Bool) -> GainAdvice {
        if clipped || peakDB >= -0.5 { return .clipping }
        if peakDB > -3 { return .tooHot(lowerByDB: Int((peakDB + 9).rounded())) }
        if peakDB >= -18 { return .good }
        if peakDB > -60 { return .tooQuiet(raiseByDB: Int((-9 - peakDB).rounded())) }
        return .noSignal
    }

    public struct Levels: Equatable, Sendable {
        /// Music-band level of the lead-in groove (needle down, no music yet).
        public var grooveNoiseDB: Float
        /// Typical (not peak) music-band level while music plays.
        public var musicDB: Float
        /// With the needle lifted, if measured.
        public var needleUpDB: Float?

        public init(grooveNoiseDB: Float, musicDB: Float, needleUpDB: Float? = nil) {
            self.grooveNoiseDB = grooveNoiseDB
            self.musicDB = musicDB
            self.needleUpDB = needleUpDB
        }
    }

    public struct Fit: Equatable, Sendable {
        public var config: SideDetectorConfig
        public var warnings: [String]
    }

    /// Thresholds placed between the measured levels.
    /// - stop: just above the groove noise (quiet between tracks reads as quiet).
    /// - start: well above it, but comfortably below typical music.
    /// - needle-lift floor: between needle-up silence and groove noise, if they differ.
    public static func fit(_ levels: Levels, base: SideDetectorConfig = SideDetectorConfig()) -> Fit {
        var config = base
        var warnings: [String] = []
        let noise = levels.grooveNoiseDB, music = levels.musicDB
        let span = music - noise
        if span < 12 {
            warnings.append(String(format: "Music is only %.0f dB above the groove noise. Raise the gain, or clean the record and stylus; side detection may be unreliable.", span))
        }
        config.stopThresholdDB = (noise + min(6, max(3, span * 0.3))).rounded()
        config.startThresholdDB = (noise + max(8, span * 0.45)).rounded()
        config.startThresholdDB = min(config.startThresholdDB, music - 6)
        config.startThresholdDB = max(config.startThresholdDB, config.stopThresholdDB + 4)

        if let up = levels.needleUpDB {
            if noise - up >= 6 {
                config.needleLiftFloorDB = ((up + noise) / 2).rounded()
            } else {
                warnings.append("With the needle up it's hardly quieter than the groove noise, so a lifted needle is detected by the run-out timer instead.")
                config.needleLiftFloorDB = (up - 30).rounded()
            }
        } else {
            config.needleLiftFloorDB = (noise - 8).rounded()
        }
        return Fit(config: config, warnings: warnings)
    }

    /// A robust level from samples taken over a few seconds: the `percentile` (0…1) of the
    /// values, so a click or a pause doesn't skew it.
    public static func level(_ samples: [Float], percentile: Double) -> Float? {
        let values = samples.filter(\.isFinite).sorted()
        guard !values.isEmpty else { return nil }
        let index = Int((Double(values.count - 1) * min(1, max(0, percentile))).rounded())
        return values[index]
    }
}
