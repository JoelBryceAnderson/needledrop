import Foundation

/// Accents a track's score can place at exact moments: a flash on a hit, the folds snapping
/// over, a light sweeping across the paper. Each is cheap at 480 lines and has a 0…1 envelope
/// over its duration. One definition per effect (`Effect.Kind.info`) feeds Claude's prompt and
/// schema, the dry run, and the renderer, so they can't disagree.
public enum Effect {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case creaseSnap = "crease_snap"
        case lightSweep = "light_sweep"
        case flash
        case inkBleed = "ink_bleed"
        case wordSwell = "word_swell"
        case letterbox
        case duotone
        case shake
    }

    /// What an effect touches.
    public enum Scope: String, Sendable { case background, ink, frame, camera }

    public struct Info: Sendable {
        /// For Claude: what it looks like and when it suits.
        public var summary: String
        public var scope: Scope
        /// Typical length in beats, and the range allowed.
        public var defaultBeats: Double
        public var beats: ClosedRange<Double>
        /// Estimated extra GPU time at full intensity, ms at 854×480.
        public var cost: Double
        /// Highest intensity while a lyric line is up (it would hurt legibility past this).
        public var maxOverLine: Double
    }
}

extension Effect.Kind {
    public var info: Effect.Info {
        switch self {
        case .creaseSnap:
            Effect.Info(summary: "the folds snap over, mountains becoming valleys and back — a hit, a downbeat, a turn in the song",
                        scope: .background, defaultBeats: 1, beats: 0.5...4, cost: 0.1, maxOverLine: 1)
        case .lightSweep:
            Effect.Info(summary: "a band of light sweeps across the paper — a lift into a chorus, a long held note",
                        scope: .background, defaultBeats: 4, beats: 1...16, cost: 0.2, maxOverLine: 1)
        case .flash:
            Effect.Info(summary: "the whole frame flashes light and fades — a big hit; use sparingly",
                        scope: .frame, defaultBeats: 1, beats: 0.25...4, cost: 0.05, maxOverLine: 0.5)
        case .inkBleed:
            Effect.Info(summary: "the printed words bleed and spread into the paper — an emotional line, a lingering word",
                        scope: .ink, defaultBeats: 4, beats: 1...16, cost: 0.3, maxOverLine: 0.6)
        case .wordSwell:
            Effect.Info(summary: "the line on screen swells slightly on each beat — a chant, a hook",
                        scope: .ink, defaultBeats: 4, beats: 1...16, cost: 0.05, maxOverLine: 1)
        case .letterbox:
            Effect.Info(summary: "black bars close in top and bottom, cinematic — a bridge, an intro, a breakdown (lines move to the middle)",
                        scope: .frame, defaultBeats: 16, beats: 4...64, cost: 0.05, maxOverLine: 1)
        case .duotone:
            Effect.Info(summary: "everything collapses to two colours, the darkest and lightest of the palette — a stark verse, a breakdown",
                        scope: .frame, defaultBeats: 8, beats: 2...64, cost: 0.1, maxOverLine: 1)
        case .shake:
            Effect.Info(summary: "a short, gentle camera shake — a drop, a crash; one bar at most",
                        scope: .camera, defaultBeats: 2, beats: 0.5...4, cost: 0, maxOverLine: 0.6)
        }
    }

    /// The envelope at `p` (0…1 through the effect), and for sweeps how far it's travelled.
    public func envelope(_ p: Double) -> Double {
        guard p >= 0, p <= 1 else { return 0 }
        func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
        switch self {
        case .flash: return p < 0.04 ? p / 0.04 : exp(-(p - 0.04) * 5)
        case .creaseSnap: return ease(p / 0.3) * (1 - ease((p - 0.6) / 0.4))
        case .lightSweep: return sin(.pi * p)
        case .shake, .wordSwell: return ease(p / 0.15) * (1 - ease((p - 0.75) / 0.25))
        case .inkBleed, .letterbox, .duotone: return ease(p / 0.2) * (1 - ease((p - 0.8) / 0.2))
        }
    }
}

/// A score's effects on the track's clock, ready to read each frame.
public struct EffectTimeline: Sendable, Equatable {
    public struct Event: Sendable, Equatable {
        public var kind: Effect.Kind
        /// Track seconds.
        public var start: Double
        public var duration: Double
        public var intensity: Double
        public var beat: Double

        public var end: Double { start + duration }
    }

    public var events: [Event]

    /// Effects are anchored to lines and beats; with no tempo known, a beat is half a second.
    public init(score: TrackScore, timeline: LyricTimeline, tempo: Double?) {
        let beat = 60 / min(200, max(60, tempo ?? 120))
        events = score.effects.compactMap { e in
            guard let line = timeline.line(e.atLine) else { return nil }
            return Event(kind: e.kind, start: line.start + e.offsetBeats * beat, duration: e.durationBeats * beat,
                         intensity: e.intensity, beat: beat)
        }.sorted { $0.start < $1.start }
    }

    /// Each effect's level now (the strongest if several of a kind overlap), and how far
    /// through it is (for sweeps).
    public func levels(at position: Double) -> [Effect.Kind: (amount: Double, progress: Double)] {
        var out: [Effect.Kind: (amount: Double, progress: Double)] = [:]
        for e in events where position >= e.start && position <= e.end {
            let p = (position - e.start) / max(0.01, e.duration)
            var amount = e.kind.envelope(p) * e.intensity
            if e.kind == .wordSwell {
                // A pulse on each beat inside the envelope.
                let beats = (position - e.start) / e.beat
                amount *= exp(-(beats - beats.rounded(.down)) * 4)
            }
            if amount > (out[e.kind]?.amount ?? 0) { out[e.kind] = (amount, p) }
        }
        return out
    }
}
