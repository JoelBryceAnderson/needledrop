import CryptoKit
import Foundation
import Visuals

/// What Claude is told about a track to score it.
public struct TrackBrief: Sendable, Equatable {
    public var artist: String
    public var title: String
    public var album: String?
    public var tempo: Double?
    public var timeline: LyricTimeline
    /// The album's look (the score works within it).
    public var style: LookStyle
    public var mood: String?

    public init(artist: String, title: String, album: String? = nil, tempo: Double? = nil, timeline: LyricTimeline,
                style: LookStyle = LookStyle(), mood: String? = nil) {
        self.artist = artist
        self.title = title
        self.album = album
        self.tempo = tempo
        self.timeline = timeline
        self.style = style
        self.mood = mood
    }

    /// Identifies the track and the lyric version (a different version needs a new score).
    public var key: String {
        let lyrics = timeline.lines.map { "\($0.index):\($0.text)" }.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(lyrics.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "score-v2|\(artist.lowercased())|\(title.lowercased())|\(hash)"
    }
}

/// Claude scores each track ahead of time, with the whole lyric in view: sections and their
/// energy, keyframed moves in the gaps, and how particular lines are set. The reply is
/// strict JSON; it's dry-run against the lyric timing, and Claude gets one turn to fix what
/// doesn't work; anything still wrong is dropped. Scores are cached per track.
public actor TrackDirector {
    /// A plain-text planning job: Sonnet does it well, quickly and cheaply.
    public static let defaultModel = "claude-sonnet-5-5"

    private let client: ClaudeClient
    private let store: ScoreStore
    private let effort: String

    public init(client: ClaudeClient, store: ScoreStore, effort: String = "medium") {
        self.client = client
        self.store = store
        self.effort = effort
    }

    public struct Result: Sendable, Equatable {
        public var score: TrackScore
        /// What the dry run still found after the correction turn (and was dropped).
        public var dropped: [String]
        public var fromCache: Bool
    }

    public func score(for brief: TrackBrief, reroll: Bool = false) async throws -> Result {
        let key = brief.key
        let pinned = await store.isPinned(key)
        if !reroll || pinned, let cached = await store.current(for: key) {
            return Result(score: cached.sanitized(for: brief.timeline), dropped: [], fromCache: true)
        }
        var messages: [[String: Any]] = [["role": "user", "content": [["type": "text", "text": Self.prompt(brief)]]]]
        var reply = try await client.send(system: Self.system, messages: messages, schema: Self.schema,
                                          effort: effort, maxTokens: 12_000)
        var score = try decode(reply.text).sanitized(for: brief.timeline)

        let issues = ScoreChecker.check(score, timeline: brief.timeline, style: brief.style, tempo: brief.tempo)
        if !issues.isEmpty {
            messages.append(["role": "assistant", "content": reply.content])
            messages.append(["role": "user", "content": [["type": "text", "text": """
                A dry run of this score against the track's timing found:
                \(issues.map { "- \($0.message)" }.joined(separator: "\n"))

                Return the complete JSON again with these fixed; keep the rest unless it needs to change.
                """]]])
            reply = try await client.send(system: Self.system, messages: messages, schema: Self.schema,
                                          effort: effort, maxTokens: 12_000)
            score = try decode(reply.text).sanitized(for: brief.timeline)
        }
        let (playable, dropped) = Self.dropFailures(score, brief: brief)
        await store.add(playable, for: key, model: reply.model)
        return Result(score: playable, dropped: dropped, fromCache: false)
    }

    /// Removes what the dry run still rejects: keyframes in gaps too short, and line
    /// treatments that don't fit (those lines are set normally).
    static func dropFailures(_ score: TrackScore, brief: TrackBrief) -> (TrackScore, [String]) {
        var s = score
        let issues = ScoreChecker.check(score, timeline: brief.timeline, style: brief.style, tempo: brief.tempo)
        var droppedEffects = IndexSet()
        for issue in issues {
            switch issue.kind {
            case .keyframe(let line): s.keyframes.removeAll { $0.beforeLine == line }
            case .line(let line): s.lines.removeAll { $0.line == line }
            case .section(let line): s.sections.removeAll { $0.startLine == line }
            case .effect(let index): droppedEffects.insert(index)
            }
        }
        s.effects = s.effects.enumerated().filter { !droppedEffects.contains($0.offset) }.map(\.element)
        return (s, issues.map(\.message))
    }

    private func decode(_ text: String) throws -> TrackScore {
        do {
            return try JSONDecoder().decode(TrackScore.self, from: Data(text.utf8))
        } catch {
            throw ClaudeError.malformed("\(error)")
        }
    }

    // MARK: - Prompt

    public static func prompt(_ brief: TrackBrief) -> String {
        let timeline = brief.timeline
        let structure = timeline.structure()
        var out = ["Track: \(brief.title)", "Artist: \(brief.artist)"]
        if let album = brief.album { out.append("Album: \(album)") }
        if let tempo = brief.tempo { out.append(String(format: "Tempo: about %.0f BPM", tempo)) }
        if let duration = timeline.duration { out.append(String(format: "Length: %d:%02d", Int(duration) / 60, Int(duration) % 60)) }
        let style = brief.style
        out.append("Album look: \(brief.mood ?? "unnamed"); background \(style.background.rawValue); folds \(style.foldCount.map(String.init) ?? "2–4") creases\(style.foldAngle.map { String(format: " at %.0f°", $0) } ?? ""); type \(style.font.rawValue) \(style.weight.rawValue), \(style.animation.rawValue)")
        out.append("")
        out.append("Lyrics (idx | starts | shown until | gap before (s) | repeat group | words):")
        var previousEnd = 0.0
        for line in timeline.lines {
            let gap = max(0, line.start - previousEnd)
            previousEnd = line.shownUntil
            let group = structure.repeats[line.index].map { "R\($0)" } ?? "-"
            out.append(String(format: "%d | %.1f | %.1f | %.1f | %@ | %@", line.index, line.start, line.shownUntil, gap, group, line.text))
        }
        out.append("")
        out.append("Sections found by gaps and repeats (a starting point; relabel freely):")
        for (i, section) in structure.sections.enumerated() {
            out.append(String(format: "%d. lines %d–%d, %@ (%.1f s of quiet before)", i + 1, section.firstLine, section.lastLine,
                              section.kind.rawValue, section.gapBefore))
        }
        out.append("")
        out.append("Score this track.")
        return out.joined(separator: "\n")
    }

    /// The effects, described from the library itself (so prompt, checker and renderer agree).
    static var effectGuide: String {
        Effect.Kind.allCases.map { kind in
            let i = kind.info
            let over = i.maxOverLine < 1 ? String(format: "; at most %.1f while a line is up", i.maxOverLine) : ""
            return String(format: "  - %@: %@ (%g beats typical, %g–%g%@)", kind.rawValue, i.summary, i.defaultBeats,
                          i.beats.lowerBound, i.beats.upperBound, over)
        }.joined(separator: "\n")
    }

    public static var system: String { systemIntro + "\n" + effectsSection + "\n" + systemOutro }

    static var effectsSection: String {
        """
        - effects: accents at exact moments, on top of the moves. Each is anchored to a line \
        (at_line, with at_line_text = its first three words) plus offset_beats from that line's \
        start (negative lands in the gap before it, e.g. −1 for a hit just before the line), \
        duration_beats and intensity 0–1. Effects may land while a line is up. At most \
        \(ScoreChecker.maximumConcurrentEffects) at once. Available:
        \(effectGuide)
        Use them like a video editor uses accents: a handful per song, on the moments that \
        matter (a drop, the last chorus, a key word), not on every line.
        """
    }

    static let systemIntro = """
        You are the art director for Needledrop, which turns a living-room TV into a visual \
        world for the record playing: a sheet of folded paper in the album's colours, with the \
        lyrics printed along its creases, one line at a time, and a small now-playing strip in \
        the bottom-left corner. You're scoring one track: read the whole lyric and plan how the \
        picture moves through the song, like a director planning a music video.

        How the picture behaves (the engine enforces this whatever you plan):
        - While a lyric line is up, everything holds still. The picture only moves in the gaps \
        between lines, and each move settles before the next line starts. The table gives each \
        line's start, when it comes down, and the gap before it.
        - A move changes the camera's framing over the paper and refolds it into a new \
        composition (new creases), and can shift the palette.

        What you plan:
        - sections: where each part of the song starts (start_line), a label (intro, verse, \
        pre-chorus, chorus, bridge, outro…) and its energy: "still" holds the composition \
        through the section unless you place a keyframe; "gentle" makes small moves in the \
        gaps; "directed" makes bold ones. Contrast is the point: a still verse makes the chorus land.
        - keyframes: a deliberate move in the gap before a particular line (before_line, with \
        before_line_text = its first three words exactly as given). framing: flat, lean_back, \
        lean_forward, turn_left, turn_right, push_in or roll; intensity 0–1. creases 2–4 and \
        angle_degrees −45…45 for the new composition (null to let it vary); accent_strip \
        (which strip, counting from 0, takes the accent colour; null keeps it). transition: \
        "snap" (quick, needs 0.8 s of gap), "glide" (1.1 s), "refold" (a big slow refold, \
        1.8 s). palette: "none", "swap" (sheet and accent trade places) or "mute" (the colour \
        drains — for a breakdown or a hushed moment; a later keyframe with "none" brings it back). \
        Put keyframes where the song turns: the first chorus, a drop, the bridge, the last \
        chorus, a key line. Only use gaps long enough for the transition. Usually 4–12 per song.
        - lines: special treatment for particular lines (line, text = the line's words): \
        emphasis "big" (short lines only, 7 words or fewer — a title line, a hook), "whisper" \
        or "normal"; placement any, upper, middle or lower; animation default, ink or \
        typewriter; hold = stay up until the next line starts (no gap after it, so no move — \
        use it to keep a couplet together). Only list lines you want to change; most lines need \
        nothing.
        """

    static let systemOutro = """
        - notes: one sentence on the idea.

        The medium is a 65" TV over composite video at 480 lines: big, bold, deliberate moves \
        read well; fussy ones don't. Your plan is checked against the timing; you'll hear about \
        anything that doesn't fit.
        """

    static var schema: [String: Any] {
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": Array(properties.keys), "additionalProperties": false]
        }
        func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
        let section = object([
            "start_line": ["type": "integer"],
            "label": ["type": "string"],
            "energy": choice(TrackScore.Energy.allCases.map(\.rawValue)),
        ])
        let keyframe = object([
            "before_line": ["type": "integer"],
            "before_line_text": ["type": "string"],
            "framing": choice(TrackScore.Framing.allCases.map(\.rawValue)),
            "intensity": ["type": "number"],
            "creases": ["type": ["integer", "null"]],
            "angle_degrees": ["type": ["number", "null"]],
            "accent_strip": ["type": ["integer", "null"]],
            "transition": choice(TrackScore.Transition.allCases.map(\.rawValue)),
            "palette": choice(TrackScore.PaletteMove.allCases.map(\.rawValue)),
        ])
        let effect = object([
            "effect": choice(Effect.Kind.allCases.map(\.rawValue)),
            "at_line": ["type": "integer"],
            "at_line_text": ["type": "string"],
            "offset_beats": ["type": "number"],
            "duration_beats": ["type": "number"],
            "intensity": ["type": "number"],
        ])
        let line = object([
            "line": ["type": "integer"],
            "text": ["type": "string"],
            "emphasis": choice(TrackScore.Emphasis.allCases.map(\.rawValue)),
            "placement": choice(TrackScore.Placement.allCases.map(\.rawValue)),
            "animation": choice(TrackScore.LineAnimation.allCases.map(\.rawValue)),
            "hold": ["type": "boolean"],
        ])
        return object([
            "sections": ["type": "array", "items": section],
            "keyframes": ["type": "array", "items": keyframe],
            "lines": ["type": "array", "items": line],
            "effects": ["type": "array", "items": effect],
            "notes": ["type": "string"],
        ])
    }
}

/// Each track's current score (and whether it's pinned), one JSON file per track.
public actor ScoreStore {
    private struct Entry: Codable {
        var score: TrackScore
        var model: String
        var created: Date
        var pinned = false
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func current(for key: String) -> TrackScore? { read(key)?.score }
    public func isPinned(_ key: String) -> Bool { read(key)?.pinned ?? false }

    public func setPinned(_ pinned: Bool, for key: String) {
        guard var entry = read(key) else { return }
        entry.pinned = pinned
        write(entry, key)
    }

    public func add(_ score: TrackScore, for key: String, model: String) {
        write(Entry(score: score, model: model, created: Date(), pinned: read(key)?.pinned ?? false), key)
    }

    private func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).json")
    }

    private func read(_ key: String) -> Entry? {
        (try? Data(contentsOf: file(key))).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
    }

    private func write(_ entry: Entry, _ key: String) {
        try? JSONEncoder().encode(entry).write(to: file(key), options: .atomic)
    }
}
