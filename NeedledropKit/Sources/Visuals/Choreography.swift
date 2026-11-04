import Foundation
import simd

// MARK: - Poses

/// Where the cover sits on screen. Screen space: x and y as fractions of width and height,
/// size in frame heights.
public struct CoverPose: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var size: Double
    /// Radians.
    public var rotation: Double
    /// 0 = gone, 1 = fully there.
    public var visibility: Double

    public init(x: Double = 0.5, y: Double = 0.5, size: Double = 0.64, rotation: Double = 0, visibility: Double = 1) {
        self.x = x
        self.y = y
        self.size = size
        self.rotation = rotation
        self.visibility = visibility
    }

    public static let hero = CoverPose()
    public static let asideLeft = CoverPose(x: 0.3, size: 0.52)

    func mixed(_ other: CoverPose, _ t: Double) -> CoverPose {
        func m(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        // Appearing or leaving: stay where the visible pose is rather than sliding from or to
        // a place nobody saw.
        let from = visibility < 0.01 ? CoverPose(x: other.x, y: other.y, size: other.size * 0.85, rotation: other.rotation, visibility: 0) : self
        let to = other.visibility < 0.01 ? CoverPose(x: x, y: y, size: size * 0.85, rotation: rotation, visibility: 0) : other
        return CoverPose(x: m(from.x, to.x), y: m(from.y, to.y), size: m(from.size, to.size),
                         rotation: m(from.rotation, to.rotation), visibility: m(from.visibility, to.visibility))
    }

    /// Corners on screen in scene units (frame height = 1, x across 0…aspect), padded.
    func contains(_ p: SIMD2<Double>, aspect: Double, padding: Double) -> Bool {
        guard visibility > 0.05 else { return false }
        let d = p - SIMD2(x * aspect, y)
        let c = cos(-rotation), s = sin(-rotation)
        let local = SIMD2(c * d.x - s * d.y, s * d.x + c * d.y)
        let half = size / 2 + padding
        return abs(local.x) < half && abs(local.y) < half
    }
}

/// A camera over the background plane: pan and zoom, a roll, and perspective tilts that
/// lean the sheet away from you.
public struct CameraPose: Sendable, Equatable {
    /// >1 moves in.
    public var zoom: Double
    /// Scene units: where the camera looks, relative to the frame centre.
    public var pan: SIMD2<Double>
    /// Radians.
    public var roll: Double
    /// Radians: the sheet leans back (+) or forward (−) about the horizontal axis…
    public var pitch: Double
    /// …and turns about the vertical one.
    public var yaw: Double

    public init(zoom: Double = 1, pan: SIMD2<Double> = .zero, roll: Double = 0, pitch: Double = 0, yaw: Double = 0) {
        self.zoom = zoom
        self.pan = pan
        self.roll = roll
        self.pitch = pitch
        self.yaw = yaw
    }

    public static let identity = CameraPose()

    func mixed(_ other: CameraPose, _ t: Double) -> CameraPose {
        func m(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return CameraPose(zoom: exp(m(log(zoom), log(other.zoom))), pan: pan + (other.pan - pan) * t,
                          roll: m(roll, other.roll), pitch: m(pitch, other.pitch), yaw: m(yaw, other.yaw))
    }

    /// Focal length in frame heights: long enough that tilts read as perspective without
    /// stretching type out of shape.
    static let focal = 1.6

    /// Maps a screen point (scene units, centred on the frame) to the background plane
    /// (scene units, absolute: 0…aspect, 0…1 when the camera is at rest).
    func worldFromScreen(aspect: Double) -> simd_double3x3 {
        let f = Self.focal
        // Plane → screen: K · [r1 r2 t] with R = yaw · pitch and the plane at distance f.
        let cp = cos(pitch), sp = sin(pitch), cy = cos(yaw), sy = sin(yaw)
        let rx = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cp, -sp), SIMD3(0, sp, cp)])
        let ry = simd_double3x3(rows: [SIMD3(cy, 0, sy), SIMD3(0, 1, 0), SIMD3(-sy, 0, cy)])
        let r = ry * rx
        let k = simd_double3x3(diagonal: SIMD3(f, f, 1))
        let planeToScreen = k * simd_double3x3(columns: (r.columns.0, r.columns.1, SIMD3(0, 0, f)))
        // Plane → world: roll, zoom, then the pan from the frame centre.
        let cr = cos(roll), sr = sin(roll), z = 1 / zoom
        let centre = SIMD2(aspect / 2, 0.5) + pan
        let planeToWorld = simd_double3x3(rows: [SIMD3(cr * z, -sr * z, centre.x),
                                                 SIMD3(sr * z, cr * z, centre.y),
                                                 SIMD3(0, 0, 1)])
        let m = planeToWorld * planeToScreen.inverse
        // Scale so the frame centre has w = 1: the shader reads w < 1 as "further away".
        return m * (1 / m.columns.2.z)
    }

    static func apply(_ m: simd_double3x3, _ p: SIMD2<Double>) -> SIMD2<Double>? {
        let h = m * SIMD3(p.x, p.y, 1)
        guard h.z > 1e-4 else { return nil }
        return SIMD2(h.x, h.y) / h.z
    }

    /// Where world point `p` lands on screen (scene units, 0…aspect, 0…1), if in front.
    func screen(of p: SIMD2<Double>, aspect: Double) -> SIMD2<Double>? {
        Self.apply(worldFromScreen(aspect: aspect).inverse, p).map { $0 + SIMD2(aspect / 2, 0.5) }
    }

    func world(of screen: SIMD2<Double>, aspect: Double) -> SIMD2<Double>? {
        Self.apply(worldFromScreen(aspect: aspect), screen - SIMD2(aspect / 2, 0.5))
    }
}

// MARK: - The choreographer

/// Directs the picture over a song like an editor cutting a video: a sequence of shots
/// (where the cover sits, how the camera looks at the background), changing on phrase
/// boundaries and on big swings in energy, easing from one to the next over a couple of
/// bars. Seeded by the track, so a song plays out the same way every time.
public struct Choreographer: Sendable {
    public struct Input: Sendable {
        public var time: Double
        /// 0…1, smoothed.
        public var level: Double
        public var beatAge: Double?
        public var tempo: Double?
        public var lyrics: Bool
        public var showCover: Bool
        /// Changes when the track (or album) changes.
        public var trackID: String?
        public var active: Bool
        /// A lyric line is up: hold still.
        public var lineShowing = false
        /// Seconds until the next lyric line (nil: no timed lyrics coming). Moves happen in
        /// the gaps and settle before it.
        public var nextLineIn: Double?

        public init(time: Double, level: Double = 0, beatAge: Double? = nil, tempo: Double? = nil, lyrics: Bool = false,
                    showCover: Bool = true, trackID: String? = nil, active: Bool = true) {
            self.time = time
            self.level = level
            self.beatAge = beatAge
            self.tempo = tempo
            self.lyrics = lyrics
            self.showCover = showCover
            self.trackID = trackID
            self.active = active
        }
    }

    public struct Shot: Sendable, Equatable {
        public var name: String
        public var cover: CoverPose
        public var camera: CameraPose
    }

    public struct Frame: Sendable, Equatable {
        public var cover: CoverPose
        public var camera: CameraPose
        /// Where the current transition is heading (equal to the above between cuts), so
        /// text can be set where it will stay visible.
        public var targetCover: CoverPose
        public var targetCamera: CameraPose
        public var shot: String
        /// How many cuts so far (counts the establishing shot).
        public var cuts: Int
        /// A move is under way.
        public var moving: Bool
        /// 0…1 through the move, eased (1 when settled).
        public var progress: Double
        /// Which fold composition the move is heading to (0 = the album's own); the folds
        /// morph from the one before it as `progress` runs.
        public var composition: Int
    }

    /// 0 = still (the cover only steps aside for lyrics), 1 = full choreography.
    public var motion = 1.0
    /// Beats per shot without timed lyrics (4 bars of 4/4).
    public var phraseBeats = 16
    /// Phrase length when no beat is tracked.
    public var phraseSeconds = 8.0
    /// Shortest gap between cuts, so a busy passage can't turn into flicker.
    public var minimumShot = 4.0

    public private(set) var cuts = 0
    private var from: Shot
    private var to: Shot
    private var transitionStart = -Double.infinity
    private var transitionLength = 3.5
    private var lastCut = -Double.infinity
    private var beatsSinceCut = 0
    private var lastBeatAge: Double?
    private var shortEnergy = 0.0
    private var longEnergy = 0.0
    private var lastTime: Double?
    private var trackID: String?
    private var lyrics = false
    private var showCover = true
    private var lastMotion = 1.0
    private var pendingEnergyCut = false
    /// Timed lyrics: a recomposition waiting for the next gap, and whether this gap has had
    /// its move.
    private var pendingRecompose = false
    private var movedThisGap = false
    /// The shortest gap worth moving in, and how long before the next line a move settles.
    public var minimumGap = 0.6
    public var settleBefore = 0.3
    private var driftAmount = 0.0
    /// When the current track started: energy needs some history before it means anything.
    private var trackStart = 0.0
    private var seed: UInt64 = 0

    public init() {
        let still = Self.still(lyrics: false)
        from = still
        to = still
    }

    static func still(lyrics: Bool) -> Shot {
        Shot(name: lyrics ? "aside" : "hero", cover: lyrics ? .asideLeft : .hero, camera: .identity)
    }

    public mutating func update(_ input: Input) -> Frame {
        let dt = lastTime.map { min(0.25, max(0, input.time - $0)) } ?? 0
        if lastTime == nil { (shortEnergy, longEnergy) = (input.level, input.level) }
        lastTime = input.time
        // Energy: a few seconds against the last ten or so.
        shortEnergy += (input.level - shortEnergy) * (1 - exp(-dt / 1.5))
        longEnergy += (input.level - longEnergy) * (1 - exp(-dt / 10))
        let beat = Self.isNewBeat(input.beatAge, previous: lastBeatAge)
        lastBeatAge = input.beatAge
        if beat { beatsSinceCut += 1 }

        let sinceCut = input.time - lastCut
        let timed = input.lyrics && (input.lineShowing || input.nextLineIn != nil)
        let settledNow = input.time - transitionStart >= transitionLength
        if input.lineShowing { movedThisGap = false }
        if input.trackID != trackID {
            trackID = input.trackID
            trackStart = input.time
            seed = Self.hash(input.trackID ?? "")
            lyrics = input.lyrics
            showCover = input.showCover
            cut(at: input.time, establishing: true, tempo: input.tempo)
        } else if input.lyrics != lyrics || input.showCover != showCover || (motion > 0) != (lastMotion > 0) {
            // Lyrics turned up (or the cover was toggled): recompose so there's room — in the
            // next gap if a line is up now.
            lyrics = input.lyrics
            showCover = input.showCover
            if timed, input.lineShowing, motion > 0 {
                pendingRecompose = true
            } else {
                cut(at: input.time, establishing: false, tempo: input.tempo)
            }
        } else if timed {
            // Still while a line is up; a move in the gap between lines, timed to settle before
            // the next one (a long instrumental gap may get more than one).
            if !input.lineShowing, settledNow, let window = input.nextLineIn, window >= minimumGap,
               motion > 0 || pendingRecompose,
               pendingRecompose || !movedThisGap || (window >= 2.5 && input.time - transitionStart - transitionLength >= 1.5) {
                cut(at: input.time, establishing: false, tempo: input.tempo,
                    length: min(3.5, max(0.5, window - settleBefore)))
                movedThisGap = true
                pendingRecompose = false
            }
        } else if motion > 0, input.active {
            let ratio = shortEnergy / max(0.04, longEnergy)
            let settled = input.time - trackStart > 10
            if settled, sinceCut > minimumShot, longEnergy > 0.05, ratio > 1.5 || ratio < 0.55 { pendingEnergyCut = true }
            let phraseDone = input.beatAge != nil ? beatsSinceCut >= phraseBeats : sinceCut >= phraseSeconds
            // Cut on the beat when there is one.
            if phraseDone || (pendingEnergyCut && (beat || input.beatAge == nil)) {
                cut(at: input.time, establishing: false, tempo: input.tempo)
            }
        }
        lastMotion = motion

        let x = min(1, max(0, (input.time - transitionStart) / transitionLength))
        let t = x * x * x * (x * (x * 6 - 15) + 10)  // smootherstep: no jolt at either end
        var cover = from.cover.mixed(to.cover, t)
        var camera = from.camera.mixed(to.camera, t)
        // A slow drift within the shot, so it never sits dead still. On the clock, not on the
        // shot, so a cut doesn't jolt it. With timed lyrics there's none: the picture holds.
        let driftTarget = timed ? 0 : motion * (input.active ? 1 : 0.4)
        driftAmount += (driftTarget - driftAmount) * (1 - exp(-dt / (timed ? 0.5 : 2)))
        let s = input.time, d = driftAmount
        camera.pan += SIMD2(sin(s * 0.11), cos(s * 0.083)) * 0.018 * d
        camera.roll += sin(s * 0.07 + 2.1) * 0.012 * d
        camera.zoom *= 1 + (0.5 + 0.5 * sin(s * 0.045)) * 0.04 * d  // a slow push in and out
        cover.y += sin(s * 0.19) * 0.006 * d
        cover.rotation += sin(s * 0.13 + 0.7) * 0.01 * d
        if !showCover { cover.visibility = 0 }
        var target = to.cover
        if !showCover { target.visibility = 0 }
        return Frame(cover: cover, camera: camera, targetCover: target, targetCamera: to.camera, shot: to.name, cuts: cuts,
                     moving: x < 1, progress: t, composition: max(0, cuts - 1))
    }

    private mutating func cut(at time: Double, establishing: Bool, tempo: Double?, length: Double? = nil) {
        // Start from wherever the picture is now (a cut can land mid-transition).
        let x = min(1, max(0, (time - transitionStart) / transitionLength))
        let t = x * x * x * (x * (x * 6 - 15) + 10)
        from = Shot(name: to.name, cover: from.cover.mixed(to.cover, t), camera: from.camera.mixed(to.camera, t))
        cuts += 1
        to = motion > 0 ? next(establishing: establishing) : Self.still(lyrics: lyrics)
        // The very first shot is simply there; there's nothing on screen to move from.
        if cuts == 1 { from = to }
        transitionStart = time
        // Two bars, within reason.
        let beat = tempo.map { 60 / max(60, min(200, $0)) } ?? 0.5
        transitionLength = length ?? min(5, max(2.5, beat * 8)) / max(0.5, motion)
        lastCut = time
        beatsSinceCut = 0
        pendingEnergyCut = false
    }

    /// The next shot: chosen from the library by the track's seed, bolder when the music is
    /// loud, always leaving room for lyrics when there are some.
    private func next(establishing: Bool) -> Shot {
        var rng = SeededRandom(seed: seed &+ UInt64(cuts) &* 0x9E37_79B9_7F4A_7C15)
        let intensity = min(1, max(0, shortEnergy * 1.6))
        if establishing {
            let cover = lyrics ? (rng.unit() < 0.5 ? CoverPose.asideLeft : CoverPose(x: 0.7, size: 0.52)) : .hero
            return Shot(name: "establishing", cover: cover, camera: camera(rng: &rng, boldness: 0.3))
        }
        let library = lyrics ? Self.lyricCovers : Self.covers
        var pick = library[Int(rng.unit() * Double(library.count)) % library.count]
        if pick.name == to.name { pick = library[(library.firstIndex { $0.name == pick.name }! + 1) % library.count] }
        // Loud passages go bold; quiet ones stay composed and keep the cover.
        if intensity < 0.3, pick.cover.visibility == 0 { pick = library[0] }
        let boldness = 0.5 + 0.5 * intensity
        var camera = camera(rng: &rng, boldness: boldness * motion)
        // With the cover gone the sheet is the whole picture: sometimes push right in.
        if pick.cover.visibility == 0, rng.unit() < 0.5 { camera.zoom *= 1 + 0.35 * motion }
        return Shot(name: pick.name, cover: pick.cover, camera: camera)
    }

    /// One tilt dominates (leaning back, or turned to one side), so each shot has a clear
    /// point of view rather than a bit of everything.
    private func camera(rng: inout SeededRandom, boldness: Double) -> CameraPose {
        func signed() -> Double { rng.unit() * 2 - 1 }
        func strong() -> Double { (0.55 + 0.45 * rng.unit()) * (rng.unit() < 0.5 ? -1 : 1) }
        let leanBack = rng.unit() < 0.55
        return CameraPose(zoom: 1.06 + 0.3 * rng.unit() * boldness,
                          pan: SIMD2(signed() * 0.12, signed() * 0.08) * boldness,
                          roll: signed() * 0.12 * boldness,
                          pitch: (leanBack ? strong() * 0.62 : signed() * 0.15) * boldness,
                          yaw: (leanBack ? signed() * 0.15 : strong() * 0.55) * boldness)
    }

    /// Without lyrics the cover can be the subject. Every pose keeps the whole cover on screen.
    static let covers: [(name: String, cover: CoverPose)] = [
        ("hero", .hero),
        ("aside-left", CoverPose(x: 0.32, size: 0.56, rotation: -0.03)),
        ("aside-right", CoverPose(x: 0.68, size: 0.56, rotation: 0.03)),
        ("corner", CoverPose(x: 0.8, y: 0.72, size: 0.36, rotation: -0.05)),
        ("high-left", CoverPose(x: 0.24, y: 0.34, size: 0.42, rotation: 0.05)),
        ("gone", CoverPose(visibility: 0)),
    ]

    /// With lyrics, every shot leaves a field for the words.
    static let lyricCovers: [(name: String, cover: CoverPose)] = [
        ("aside-left", .asideLeft),
        ("aside-right", CoverPose(x: 0.7, size: 0.52)),
        ("corner-low", CoverPose(x: 0.84, y: 0.74, size: 0.32, rotation: 0.04)),
        ("corner-high", CoverPose(x: 0.15, y: 0.25, size: 0.3, rotation: -0.05)),
        ("gone", CoverPose(visibility: 0)),
    ]

    static func isNewBeat(_ age: Double?, previous: Double?) -> Bool {
        guard let age else { return false }
        guard let previous else { return age < 0.1 }
        return age < previous - 0.05
    }

    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return h
    }
}
