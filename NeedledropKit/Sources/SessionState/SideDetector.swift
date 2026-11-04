import SignalAnalysis

public struct SideDetectorConfig: Codable, Sendable, Equatable {
    /// Music-band level a side has to exceed (while sounding like music) to start.
    public var startThresholdDB: Float = -42
    /// Below this the side is "quiet" (between tracks, or ending).
    public var stopThresholdDB: Float = -50
    /// Resuming after a quiet stretch needs stop threshold + this margin (hysteresis).
    public var resumeMarginDB: Float = 3
    /// Spectral flatness above this is treated as groove noise rather than music.
    public var maxMusicFlatness: Float = 0.3
    /// Signal must sound like music this long before a side starts.
    public var startHold: Double = 1.5
    /// Dropouts shorter than this don't reset the start hold.
    public var startDropoutTolerance: Double = 0.25
    /// Music must be back this long to end a quiet stretch.
    public var resumeHold: Double = 0.25
    /// Quiet stretches at least this long are reported as track gaps.
    public var gapMinimum: Double = 1.0
    /// Sustained quiet this long ends the side (run-out groove).
    public var sideEndSilence: Double = 9.0
    /// Needle lift: the level falls from ≥ stop + `needleLiftDropDB` to quiet within
    /// `needleLiftWindow`, then sits under `needleLiftFloorDB` (no surface noise at all)
    /// for `needleLiftConfirm`.
    public var needleLiftDropDB: Float = 25
    public var needleLiftWindow: Double = 0.15
    public var needleLiftFloorDB: Float = -66
    public var needleLiftConfirm: Double = 3.0
    /// Median filter length applied to level and flatness. Kills crackle and clicks.
    public var smoothingWindow: Double = 0.3

    public init() {}

    /// Missing keys keep their defaults, so adding a field doesn't reset tuned thresholds.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let d = SideDetectorConfig()
        startThresholdDB = try value(.startThresholdDB, d.startThresholdDB)
        stopThresholdDB = try value(.stopThresholdDB, d.stopThresholdDB)
        resumeMarginDB = try value(.resumeMarginDB, d.resumeMarginDB)
        maxMusicFlatness = try value(.maxMusicFlatness, d.maxMusicFlatness)
        startHold = try value(.startHold, d.startHold)
        startDropoutTolerance = try value(.startDropoutTolerance, d.startDropoutTolerance)
        resumeHold = try value(.resumeHold, d.resumeHold)
        gapMinimum = try value(.gapMinimum, d.gapMinimum)
        sideEndSilence = try value(.sideEndSilence, d.sideEndSilence)
        needleLiftDropDB = try value(.needleLiftDropDB, d.needleLiftDropDB)
        needleLiftWindow = try value(.needleLiftWindow, d.needleLiftWindow)
        needleLiftFloorDB = try value(.needleLiftFloorDB, d.needleLiftFloorDB)
        needleLiftConfirm = try value(.needleLiftConfirm, d.needleLiftConfirm)
        smoothingWindow = try value(.smoothingWindow, d.smoothingWindow)
    }
}

public enum SideEndReason: String, Sendable, Codable {
    case runout
    case needleLift
}

public enum SideEvent: Sendable, Equatable {
    case sideStarted(at: Double)
    case trackGap(start: Double, end: Double, abrupt: Bool)
    case sideEnded(start: Double, end: Double, reason: SideEndReason)

    public var time: Double {
        switch self {
        case .sideStarted(let t): t
        case .trackGap(_, let end, _): end
        case .sideEnded(_, let end, _): end
        }
    }
}

public enum SidePhase: Sendable, Equatable {
    /// No side playing; waiting for the needle.
    case idle
    /// Music-like signal heard; waiting for `startHold` to confirm.
    case arming(since: Double)
    case playing(sideStart: Double)
    /// Quiet within a side: a gap between tracks, or the run-out if it lasts.
    case quiet(sideStart: Double, since: Double)
}

/// Decides when a side starts, pauses between tracks, and ends, from per-hop features.
///
/// All times are audio time (`AudioFeatures.time`) corrected for the median filter's
/// delay, so they line up with the audio itself — useful for archiving later.
public struct SideDetector: Sendable {
    public var config: SideDetectorConfig
    public private(set) var phase: SidePhase = .idle
    /// Median-filtered music-band level and flatness — what decisions are made on.
    public private(set) var gatedLevelDB: Float = -120
    public private(set) var gatedFlatness: Float = 1

    private var levelFilter = MedianFilter()
    private var flatnessFilter = MedianFilter()
    private var lastActive = -Double.infinity
    private var lastLoud = -Double.infinity
    private var quietIsAbrupt = false
    private var resumeSince: Double?
    private var floorSince: Double?

    public init(config: SideDetectorConfig = SideDetectorConfig()) {
        self.config = config
    }

    public mutating func process(_ features: AudioFeatures) -> [SideEvent] {
        gatedLevelDB = levelFilter.push(features.musicBandDB, at: features.time, window: config.smoothingWindow)
        gatedFlatness = flatnessFilter.push(features.flatness, at: features.time, window: config.smoothingWindow)
        let t = features.time - config.smoothingWindow / 2

        let musicLike = gatedFlatness <= config.maxMusicFlatness
        let active = gatedLevelDB >= config.startThresholdDB && musicLike
        let quiet = gatedLevelDB < config.stopThresholdDB || (!musicLike && gatedLevelDB < config.startThresholdDB)
        let resuming = gatedLevelDB >= config.stopThresholdDB + config.resumeMarginDB && musicLike
        if gatedLevelDB >= config.stopThresholdDB + config.needleLiftDropDB { lastLoud = t }

        var events: [SideEvent] = []
        switch phase {
        case .idle:
            if active {
                phase = .arming(since: t)
                lastActive = t
            }

        case .arming(let since):
            if active {
                lastActive = t
                if t - since >= config.startHold {
                    phase = .playing(sideStart: since)
                    events.append(.sideStarted(at: since))
                }
            } else if t - lastActive > config.startDropoutTolerance {
                phase = .idle
            }

        case .playing(let sideStart):
            if quiet {
                phase = .quiet(sideStart: sideStart, since: t)
                quietIsAbrupt = t - lastLoud <= config.needleLiftWindow + config.smoothingWindow
                resumeSince = nil
                floorSince = nil
            }

        case .quiet(let sideStart, let since):
            if resuming {
                let resumedAt = resumeSince ?? t
                resumeSince = resumedAt
                if t - resumedAt >= config.resumeHold {
                    if resumedAt - since >= config.gapMinimum {
                        events.append(.trackGap(start: since, end: resumedAt, abrupt: quietIsAbrupt))
                    }
                    phase = .playing(sideStart: sideStart)
                }
                break
            }
            resumeSince = nil
            if gatedLevelDB < config.needleLiftFloorDB {
                floorSince = floorSince ?? t
            } else {
                floorSince = nil
            }
            if quietIsAbrupt, let floorSince, t - floorSince >= config.needleLiftConfirm {
                events.append(.sideEnded(start: sideStart, end: since, reason: .needleLift))
                phase = .idle
            } else if t - since >= config.sideEndSilence {
                events.append(.sideEnded(start: sideStart, end: since, reason: .runout))
                phase = .idle
            }
        }
        return events
    }
}

/// Running median over a time window. Windows are ~30 values, so sort-per-push is fine.
struct MedianFilter: Sendable {
    private var samples: [(time: Double, value: Float)] = []
    private var scratch: [Float] = []

    mutating func push(_ value: Float, at time: Double, window: Double) -> Float {
        samples.append((time, value))
        let cutoff = time - window
        if let firstKept = samples.firstIndex(where: { $0.time > cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
        scratch.removeAll(keepingCapacity: true)
        for s in samples { scratch.append(s.value) }
        scratch.sort()
        return scratch[scratch.count / 2]
    }
}
