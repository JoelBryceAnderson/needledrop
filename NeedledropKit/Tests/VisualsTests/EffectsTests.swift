import Foundation
import Testing
@testable import Visuals

@Suite struct EffectsTests {
    let timeline = LyricTimeline(lines: [
        .init(index: 0, start: 10, shownUntil: 12.6, text: "we drove out past the edge of town"),
        .init(index: 1, start: 16, shownUntil: 18.6, text: "so let it play"),
    ])

    @Test func everyEnvelopeRisesAndFallsBackToNothing() {
        for kind in Effect.Kind.allCases {
            #expect(kind.envelope(0) < 0.05, "\(kind) starts at \(kind.envelope(0))")
            #expect(kind.envelope(1) < 0.05, "\(kind) ends at \(kind.envelope(1))")
            #expect((0...20).map { kind.envelope(Double($0) / 20) }.max()! > 0.8, "\(kind) never peaks")
            #expect(kind.envelope(-0.1) == 0 && kind.envelope(1.1) == 0)
        }
    }

    @Test func effectsLandOnLinesAndBeats() {
        let score = TrackScore(effects: [
            .init(kind: .flash, atLine: 1, offsetBeats: -1, durationBeats: 1, intensity: 1),
            .init(kind: .letterbox, atLine: 0, offsetBeats: 0, durationBeats: 8, intensity: 1),
        ])
        let effects = EffectTimeline(score: score, timeline: timeline, tempo: 120)
        // 120 BPM: a beat is 0.5 s. The flash is the beat before line 1.
        #expect(effects.events.map(\.kind) == [.letterbox, .flash])
        #expect(effects.events[1].start == 15.5)
        #expect(effects.events[1].duration == 0.5)
        #expect((effects.levels(at: 15.52)[.flash]?.amount ?? 0) > 0.4)
        #expect(effects.levels(at: 15.2)[.flash] == nil)
        #expect((effects.levels(at: 12)[.letterbox]?.amount ?? 0) > 0.9)
        #expect(effects.levels(at: 14.5)[.letterbox] == nil)
    }

    @Test func sanitizingKeepsEffectsInRangeAndOnRealLines() {
        let score = TrackScore(effects: [
            .init(kind: .shake, atLine: 1, atLineText: "so let it", offsetBeats: 99, durationBeats: 40, intensity: 3),
            .init(kind: .flash, atLine: 7, atLineText: "nowhere to be found"),
        ]).sanitized(for: timeline)
        #expect(score.effects.count == 1)
        #expect(score.effects[0].durationBeats == Effect.Kind.shake.info.beats.upperBound)
        #expect(score.effects[0].offsetBeats == 32)
        #expect(score.effects[0].intensity == 1)
    }

    @Test func theDryRunKeepsEffectsReadableAndFew() {
        // A full-strength flash over a line is too much; in the gap before it, fine.
        let over = TrackScore(effects: [.init(kind: .flash, atLine: 1, offsetBeats: 0, durationBeats: 1, intensity: 1)])
        #expect(ScoreChecker.check(over, timeline: timeline).map(\.kind) == [.effect(0)])
        let before = TrackScore(effects: [.init(kind: .flash, atLine: 1, offsetBeats: -2, durationBeats: 1, intensity: 1)])
        #expect(ScoreChecker.check(before, timeline: timeline).isEmpty)
        // Four at once is one too many.
        let pile = TrackScore(effects: [Effect.Kind.lightSweep, .duotone, .letterbox, .wordSwell].map {
            .init(kind: $0, atLine: 0, offsetBeats: 0, durationBeats: 8, intensity: 0.5)
        })
        #expect(ScoreChecker.check(pile, timeline: timeline).map(\.kind) == [.effect(3)])
        // Nothing placed top or bottom while the letterbox bars are there.
        var boxed = TrackScore(effects: [.init(kind: .letterbox, atLine: 0, durationBeats: 16)])
        boxed.lines = [.init(line: 1, text: "so let it play", placement: .upper)]
        #expect(ScoreChecker.check(boxed, timeline: timeline).map(\.kind).contains(.line(1)))
    }

    @Test func oldScoresWithoutEffectsStillDecode() throws {
        let json = #"{"sections":[],"keyframes":[],"lines":[],"notes":"from before effects"}"#
        let score = try JSONDecoder().decode(TrackScore.self, from: Data(json.utf8))
        #expect(score.effects.isEmpty)
        #expect(score.notes == "from before effects")
    }
}

@Suite struct LayoutFieldTests {
    /// A cream ground with a navy block on the left and a purple one beside it (similar
    /// lightness, different colour).
    func field() -> LayoutField {
        let w = 160, h = 90
        var rgb = [SIMD3<Float>](repeating: SIMD3(0.92, 0.88, 0.8), count: w * h)
        for y in 20..<70 {
            for x in 10..<60 { rgb[y * w + x] = SIMD3(0.1, 0.15, 0.32) }
            for x in 60..<100 { rgb[y * w + x] = SIMD3(0.3, 0.18, 0.4) }
        }
        return LayoutField(width: w, height: h, rgb: rgb)
    }

    let aspect = 16.0 / 9

    @Test func flatGroundIsCalmAndAnEdgeIsBusy() {
        let f = field()
        let insideNavy = f.read(centre: SIMD2(0.35 * aspect / 1.6, 0.5), angle: 0, size: SIMD2(0.2, 0.05), aspect: aspect)
        let acrossColours = f.read(centre: SIMD2(60.0 / 160 * aspect, 0.5), angle: 0, size: SIMD2(0.3, 0.05), aspect: aspect)
        let cream = f.read(centre: SIMD2(1.5, 0.12), angle: 0, size: SIMD2(0.3, 0.05), aspect: aspect)
        #expect(insideNavy.busyness < 0.05)
        #expect(cream.busyness < 0.05)
        // Navy and purple are close in lightness, but the colour edge still counts.
        #expect(acrossColours.busyness > 0.2)
    }

    @Test func inkTakesTheToneThatStandsOut() {
        let f = field()
        #expect(f.read(centre: SIMD2(1.5, 0.12), angle: 0, size: SIMD2(0.3, 0.05), aspect: aspect).tone == 1)
        #expect(f.read(centre: SIMD2(0.35 * aspect / 1.6, 0.5), angle: 0, size: SIMD2(0.2, 0.05), aspect: aspect).tone == 2)
    }
}
