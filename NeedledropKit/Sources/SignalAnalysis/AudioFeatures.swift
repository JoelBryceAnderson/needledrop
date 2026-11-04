/// RMS amplitude per frequency band (linear, 1.0 = full-scale sine × √2).
public struct BandEnergies: Sendable, Equatable {
    public var sub: Float     // 20–60 Hz
    public var bass: Float    // 60–250 Hz
    public var mids: Float    // 250 Hz – 4 kHz
    public var highs: Float   // 4–16 kHz

    public init(sub: Float = 0, bass: Float = 0, mids: Float = 0, highs: Float = 0) {
        self.sub = sub
        self.bass = bass
        self.mids = mids
        self.highs = highs
    }

    public static let ranges: [(name: String, low: Double, high: Double)] = [
        ("sub", 20, 60), ("bass", 60, 250), ("mids", 250, 4000), ("highs", 4000, 16000),
    ]

    public var asArray: [Float] { [sub, bass, mids, highs] }
}

/// Everything downstream (session logic, visuals, archive) knows about one analysis hop.
public struct AudioFeatures: Sendable, Equatable {
    /// Seconds of audio consumed so far, at the end of this hop. This is *audio* time, not
    /// wall time, so replay at any speed produces identical results.
    public var time: Double
    public var rms: Float
    public var peak: Float
    /// Samples at or above 0.999 full scale in this hop, across channels.
    public var clippedSamples: Int
    public var bands: BandEnergies
    /// RMS over 100 Hz – 5 kHz: where music lives and where rumble and most hiss don't.
    public var musicBandRMS: Float
    /// Spectral flatness over the music band: low for music, high for groove noise.
    public var flatness: Float
    /// Spectral flux (onset strength).
    public var flux: Float
    public var onset: Bool
    public var tempo: Double?
    /// True on the hop where a tracked beat lands.
    public var beat: Bool
    /// 0 at a beat, rising to 1 just before the next.
    public var beatPhase: Float

    public init(
        time: Double = 0, rms: Float = 0, peak: Float = 0, clippedSamples: Int = 0,
        bands: BandEnergies = BandEnergies(), musicBandRMS: Float = 0, flatness: Float = 1,
        flux: Float = 0, onset: Bool = false, tempo: Double? = nil, beat: Bool = false, beatPhase: Float = 0
    ) {
        self.time = time
        self.rms = rms
        self.peak = peak
        self.clippedSamples = clippedSamples
        self.bands = bands
        self.musicBandRMS = musicBandRMS
        self.flatness = flatness
        self.flux = flux
        self.onset = onset
        self.tempo = tempo
        self.beat = beat
        self.beatPhase = beatPhase
    }

    public var musicBandDB: Float { decibels(musicBandRMS) }
}
