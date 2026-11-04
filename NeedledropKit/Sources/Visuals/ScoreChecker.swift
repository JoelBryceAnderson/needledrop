import CoreGraphics
import Foundation

/// Plays a score against the track's lyric timing before it's used, the way the shader
/// validator renders a shader before it's shown: every keyframe needs a gap long enough for
/// its move, and every line it treats must fit its composition, legibly, clear of the
/// now-playing strip. Problems go back to Claude once; whatever's still wrong is dropped
/// (the choreographer would hold or skip it anyway).
public enum ScoreChecker {
    public struct Issue: Sendable, Equatable, CustomStringConvertible {
        public enum Kind: Sendable, Equatable { case keyframe(Int), line(Int), section(Int) }
        public var kind: Kind
        public var message: String
        public var description: String { message }
    }

    /// How long before the next line a move must have settled (matches the choreographer).
    static let settle = 0.3

    public static func check(_ score: TrackScore, timeline: LyricTimeline, style: LookStyle = LookStyle(),
                             aspect: Double = 16.0 / 9) -> [Issue] {
        var issues: [Issue] = []
        let indices = Set(timeline.lines.map(\.index))

        for section in score.sections where !indices.contains(section.startLine) {
            issues.append(Issue(kind: .section(section.startLine), message: "Section \"\(section.label)\" starts at line \(section.startLine), which isn't a line with words."))
        }

        // Keyframes: the gap before their line, given which lines are held.
        func gap(before index: Int) -> Double? {
            guard let i = timeline.position(of: index) else { return nil }
            guard i > 0 else { return timeline.lines[i].start }
            let previous = timeline.lines[i - 1]
            let held = score.treatment(line: previous.index)?.hold ?? false
            return max(0, timeline.lines[i].start - (held ? previous.heldUntil : previous.shownUntil))
        }
        for k in score.keyframes {
            guard let available = gap(before: k.beforeLine) else {
                issues.append(Issue(kind: .keyframe(k.beforeLine), message: "Keyframe before line \(k.beforeLine): there's no such line."))
                continue
            }
            let needed = Choreographer.gapNeeded(k.transition) + settle
            if available < needed {
                let nearby = timeline.lines.map(\.index)
                    .filter { abs($0 - k.beforeLine) <= 6 && (gap(before: $0) ?? 0) >= needed }
                    .map { "\($0) (\(String(format: "%.1f", gap(before: $0) ?? 0)) s)" }
                let suggestion = nearby.isEmpty
                    ? "Use a shorter transition (snap needs \(String(format: "%.1f", Choreographer.gapNeeded(.snap) + settle)) s) or drop it."
                    : "Gaps long enough nearby: before lines \(nearby.joined(separator: ", "))."
                issues.append(Issue(kind: .keyframe(k.beforeLine), message: "Keyframe before line \(k.beforeLine) (\(k.transition.rawValue)) needs a \(String(format: "%.1f", needed)) s gap, but there's \(String(format: "%.1f", available)) s. \(suggestion)"))
            }
        }

        // Lines: big ones must be short enough, and every treated line must fit somewhere.
        for t in score.lines {
            guard let line = timeline.line(t.line) else {
                issues.append(Issue(kind: .line(t.line), message: "Treatment for line \(t.line): there's no such line."))
                continue
            }
            let words = TrackScore.words(line.text).count
            if t.emphasis == .big, words > 7 {
                issues.append(Issue(kind: .line(t.line), message: "Line \(t.line) has \(words) words, too many to set big; keep big for short lines (7 words or fewer)."))
                continue
            }
            guard t.emphasis != .normal || t.placement != .any else { continue }
            let composition = score.keyframes.last { $0.beforeLine <= t.line }
            if !fits(line.text, treatment: t, composition: composition, style: style, aspect: aspect) {
                let folds = composition?.creases.map { "\($0) creases" } ?? "this composition"
                issues.append(Issue(kind: .line(t.line), message: "Line \(t.line) doesn't fit as \(t.emphasis.rawValue)\(t.placement == .any ? "" : " in the \(t.placement.rawValue) part of the screen") with \(folds); try normal emphasis, another placement, or fewer creases there."))
            }
        }
        return issues
    }

    /// Does the line fit, at one of its emphasis's sizes, along the creases of a few versions
    /// of the composition? (The exact folds are seeded at play time, so most of them must work.)
    static func fits(_ text: String, treatment: TrackScore.LineTreatment, composition: TrackScore.Keyframe?,
                     style: LookStyle, aspect: Double) -> Bool {
        let band: ClosedRange<Double> = switch treatment.placement {
        case .any: 0...1
        case .upper: 0...0.55
        case .middle: 0.2...0.8
        case .lower: 0.45...1
        }
        // Keep clear of the edges and of the now-playing strip, bottom left.
        let strip = CGRect(x: 0, y: 0.75, width: aspect * 0.45, height: 0.25)
        let allowed: (SIMD2<Double>) -> Bool = { p in
            p.x > 0.05 && p.x < aspect - 0.05 && p.y > 0.05 && p.y < 0.95 && band.contains(p.y)
                && !strip.contains(CGPoint(x: p.x, y: p.y))
        }
        let sizes = Array(VisualsRenderer.sizes(for: treatment.emphasis).prefix(treatment.emphasis == .normal ? 5 : 4))
        let scale = 960.0  // twice 480 lines, as the renderer rasterises
        var successes = 0
        for seed in [UInt64(1), 7, 23] {
            let layout = FoldLayout.make(seed: seed, aspect: aspect, flow: 0, angle: composition?.angleDegrees ?? style.foldAngle,
                                         count: composition?.creases ?? style.foldCount ?? 3)
            let fitted = sizes.contains { size in
                guard let image = LyricRasterizer.image(for: style.apply(case: text), fontSize: CGFloat(size.font * scale),
                                                        maxWidth: CGFloat(size.width * scale), maxLines: size.lines,
                                                        font: style.font, weight: style.weight) else { return false }
                let measured = SIMD2(Double(image.width), Double(image.height)) / scale
                return layout.spot(forLine: treatment.line, size: measured, obstacles: [], allowed: allowed) != nil
            }
            if fitted { successes += 1 }
        }
        return successes >= 2
    }
}
