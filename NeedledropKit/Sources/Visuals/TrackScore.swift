import Foundation

/// A plan for one track, written ahead of time with the whole lyric in view (by Claude, as
/// art director): sections with an energy each, keyframed moves in the gaps between lines,
/// and how particular lines are treated. It's a plan, not a script: the choreographer still
/// never moves while a line is up, fits every move into the real gap, and keeps every line
/// legible — a keyframe it can't honour is held for the next gap or dropped.
///
/// Everything refers to lyric lines by index (with their words, to catch a different
/// version of the lyrics), not by time, so clock drift can't misplace it.
public struct TrackScore: Sendable, Equatable, Codable {
    public enum Energy: String, Sendable, Codable, CaseIterable {
        /// Holds still through the section (moves only where a keyframe says).
        case still
        /// Small moves between phrases.
        case gentle
        /// Bold moves between phrases.
        case directed
    }

    /// Named camera framings, so a plan stays inside what reads well on the TV.
    public enum Framing: String, Sendable, Codable, CaseIterable {
        case flat
        case leanBack = "lean_back"
        case leanForward = "lean_forward"
        case turnLeft = "turn_left"
        case turnRight = "turn_right"
        case pushIn = "push_in"
        case roll
    }

    public enum Transition: String, Sendable, Codable, CaseIterable {
        /// Eases across the whole gap.
        case glide
        /// A slower, bigger refold of the paper (needs a longer gap).
        case refold
        /// A quick move on the beat.
        case snap
    }

    public enum Emphasis: String, Sendable, Codable, CaseIterable { case whisper, normal, big }
    public enum Placement: String, Sendable, Codable, CaseIterable { case any, upper, middle, lower }

    public enum PaletteMove: String, Sendable, Codable, CaseIterable {
        case none
        /// The sheet and accent colours trade places.
        case swap
        /// The colour drains out (a breakdown, a quiet verse).
        case mute
    }

    public enum LineAnimation: String, Sendable, Codable, CaseIterable {
        /// The album's choice.
        case `default`
        case ink, typewriter
    }

    public struct Section: Sendable, Equatable, Codable {
        public var startLine: Int
        public var label: String
        public var energy: Energy

        public init(startLine: Int, label: String, energy: Energy) {
            self.startLine = startLine
            self.label = label
            self.energy = energy
        }

        enum CodingKeys: String, CodingKey { case startLine = "start_line", label, energy }
    }

    public struct Keyframe: Sendable, Equatable, Codable {
        /// The move happens in the gap before this line, and has settled when it starts.
        public var beforeLine: Int
        /// The first words of that line, to check the plan against these lyrics.
        public var beforeLineText: String
        public var framing: Framing
        /// 0…1.
        public var intensity: Double
        /// 2…4 creases; nil keeps the count.
        public var creases: Int?
        /// −45…45° lean of the creases; nil lets it vary.
        public var angleDegrees: Double?
        /// Which strip (0-based, across the folds) takes the accent colour; nil keeps it.
        public var accentStrip: Int?
        public var transition: Transition
        public var palette: PaletteMove

        public init(beforeLine: Int, beforeLineText: String = "", framing: Framing, intensity: Double = 0.6,
                    creases: Int? = nil, angleDegrees: Double? = nil, accentStrip: Int? = nil,
                    transition: Transition = .glide, palette: PaletteMove = .none) {
            self.beforeLine = beforeLine
            self.beforeLineText = beforeLineText
            self.framing = framing
            self.intensity = intensity
            self.creases = creases
            self.angleDegrees = angleDegrees
            self.accentStrip = accentStrip
            self.transition = transition
            self.palette = palette
        }

        enum CodingKeys: String, CodingKey {
            case beforeLine = "before_line", beforeLineText = "before_line_text", framing, intensity, creases
            case angleDegrees = "angle_degrees", accentStrip = "accent_strip", transition, palette
        }
    }

    public struct LineTreatment: Sendable, Equatable, Codable {
        public var line: Int
        public var text: String
        public var emphasis: Emphasis
        public var placement: Placement
        public var animation: LineAnimation
        /// Stays up until the next line starts (no gap, so no move, after it).
        public var hold: Bool

        public init(line: Int, text: String = "", emphasis: Emphasis = .normal, placement: Placement = .any,
                    animation: LineAnimation = .default, hold: Bool = false) {
            self.line = line
            self.text = text
            self.emphasis = emphasis
            self.placement = placement
            self.animation = animation
            self.hold = hold
        }
    }

    public var sections: [Section]
    public var keyframes: [Keyframe]
    public var lines: [LineTreatment]
    /// A sentence on the idea (shown in the debug overlay).
    public var notes: String

    public init(sections: [Section] = [], keyframes: [Keyframe] = [], lines: [LineTreatment] = [], notes: String = "") {
        self.sections = sections
        self.keyframes = keyframes
        self.lines = lines
        self.notes = notes
    }

    // MARK: - Lookups

    public func keyframe(beforeLine line: Int) -> Keyframe? { keyframes.first { $0.beforeLine == line } }
    public func treatment(line: Int) -> LineTreatment? { lines.first { $0.line == line } }

    /// The section a line belongs to (the last one starting at or before it).
    public func section(atLine line: Int) -> Section? { sections.last { $0.startLine <= line } }

    // MARK: - Making a plan safe to play

    /// The plan with everything out of range clamped or dropped, and every reference checked
    /// against `timeline`: a line whose words don't match is looked for a few lines either
    /// side (the lyrics may be a slightly different version), and dropped if it isn't there.
    public func sanitized(for timeline: LyricTimeline) -> TrackScore {
        func resolve(_ index: Int, _ text: String) -> Int? {
            let wanted = Self.words(text)
            if wanted.isEmpty { return timeline.line(index) != nil ? index : nil }
            func matches(_ i: Int) -> Bool {
                guard let line = timeline.line(i) else { return false }
                let have = Self.words(line.text)
                return Array(have.prefix(wanted.count)) == wanted || have.starts(with: wanted.prefix(2))
            }
            if matches(index) { return index }
            for offset in 1...4 {
                if matches(index - offset) { return index - offset }
                if matches(index + offset) { return index + offset }
            }
            return nil
        }
        var s = self
        let valid = Set(timeline.lines.map(\.index))
        let first = timeline.lines.first?.index ?? 0
        s.sections = sections.filter { valid.contains($0.startLine) }.sorted { $0.startLine < $1.startLine }
        if s.sections.first?.startLine != first, let opening = s.sections.first ?? sections.first {
            s.sections.insert(Section(startLine: first, label: opening.label, energy: opening.energy), at: 0)
        }
        var seen = Set<Int>()
        s.keyframes = keyframes.compactMap { k in
            guard let line = resolve(k.beforeLine, k.beforeLineText), seen.insert(line).inserted else { return nil }
            var k = k
            k.beforeLine = line
            k.intensity = min(1, max(0, k.intensity.isFinite ? k.intensity : 0.5))
            k.creases = k.creases.map { min(FoldLayout.maximumCreases, max(2, $0)) }
            k.angleDegrees = k.angleDegrees.flatMap { $0.isFinite ? min(45, max(-45, $0)) : nil }
            k.accentStrip = k.accentStrip.map { min(4, max(0, $0)) }
            return k
        }.sorted { $0.beforeLine < $1.beforeLine }
        var treated = Set<Int>()
        s.lines = lines.compactMap { t in
            guard let line = resolve(t.line, t.text), treated.insert(line).inserted else { return nil }
            var t = t
            t.line = line
            return t
        }.sorted { $0.line < $1.line }
        s.notes = String(notes.prefix(200))
        return s
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

extension TrackScore.Framing {
    /// The camera for this framing at `intensity` (0…1). `side` (±1) picks a direction for
    /// framings that have no inherent one.
    public func camera(intensity: Double, side: Double = 1) -> CameraPose {
        let i = min(1, max(0, intensity))
        switch self {
        case .flat: return .identity
        case .leanBack: return CameraPose(zoom: 1.04, pitch: 0.55 * i)
        case .leanForward: return CameraPose(zoom: 1.04, pitch: -0.4 * i)
        case .turnLeft: return CameraPose(zoom: 1.04, yaw: -0.5 * i)
        case .turnRight: return CameraPose(zoom: 1.04, yaw: 0.5 * i)
        case .pushIn: return CameraPose(zoom: 1 + 0.4 * i)
        case .roll: return CameraPose(zoom: 1.05 + 0.05 * i, roll: 0.16 * i * (side < 0 ? -1 : 1))
        }
    }
}
