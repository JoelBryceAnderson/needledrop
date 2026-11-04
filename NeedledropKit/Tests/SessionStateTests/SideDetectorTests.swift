import SessionState
import SignalAnalysis
import Testing

/// Drives a `SideDetector` with hand-built feature sequences at a 10 ms hop.
private struct Script {
    var detector = SideDetector()
    var time = 0.0
    var events: [SideEvent] = []
    let hop = 0.01

    static let music: (db: Float, flatness: Float) = (-20, 0.02)
    static let grooveNoise: (db: Float, flatness: Float) = (-60, 0.55)
    static let needleUp: (db: Float, flatness: Float) = (-95, 1)

    mutating func play(_ seconds: Double, _ level: (db: Float, flatness: Float)) {
        for _ in 0..<Int((seconds / hop).rounded()) { step(level) }
    }

    mutating func step(_ level: (db: Float, flatness: Float)) {
        time += hop
        let features = AudioFeatures(time: time, musicBandRMS: powf(10, level.db / 20), flatness: level.flatness)
        events += detector.process(features)
    }

    var starts: [Double] { events.compactMap { if case .sideStarted(let t) = $0 { t } else { nil } } }
    var gaps: [(Double, Double, Bool)] { events.compactMap { if case .trackGap(let s, let e, let a) = $0 { (s, e, a) } else { nil } } }
    var ends: [(Double, SideEndReason)] { events.compactMap { if case .sideEnded(_, let e, let r) = $0 { (e, r) } else { nil } } }
}

@Suite struct SideDetectorTests {
    @Test func leadInGrooveNoiseDoesNotStartASide() {
        var s = Script()
        s.play(30, Script.grooveNoise)
        #expect(s.events.isEmpty)
        #expect(s.detector.phase == .idle)
    }

    @Test func loudNoiseIsRejectedByFlatness() {
        // Heavy surface noise above the start threshold still isn't music.
        var s = Script()
        s.play(10, (-35, 0.5))
        #expect(s.events.isEmpty)
    }

    @Test func cracklesAndTheNeedleDropThumpDoNotStartASide() {
        var s = Script()
        for _ in 0..<40 {
            s.play(0.2, Script.grooveNoise)
            s.play(0.03, (-10, 0.1))  // click: loud, short
        }
        #expect(s.events.isEmpty)
    }

    @Test func musicStartsASideAfterTheHold() {
        var s = Script()
        s.play(3, Script.grooveNoise)
        s.play(1.4, Script.music)
        #expect(s.starts.isEmpty)
        s.play(0.5, Script.music)
        #expect(s.starts.count == 1)
        #expect(abs(s.starts[0] - 3) < 0.05, "start at \(s.starts[0]) — should be when music began")
        guard case .playing = s.detector.phase else { Issue.record("expected playing"); return }
    }

    @Test func briefDropoutsDuringArmingAreTolerated() {
        var s = Script()
        s.play(1, Script.grooveNoise)
        s.play(0.8, Script.music)
        s.play(0.1, Script.grooveNoise)
        s.play(1.0, Script.music)
        #expect(s.starts.count == 1)
        #expect(abs(s.starts[0] - 1) < 0.05)
    }

    @Test func quietPassagesInsideATrackAreNotGaps() {
        var s = Script()
        s.play(5, Script.music)
        s.play(0.6, Script.grooveNoise)  // shorter than gapMinimum
        s.play(5, Script.music)
        s.play(4, (-46, 0.05))  // quiet but still music, between stop and start thresholds
        s.play(5, Script.music)
        #expect(s.gaps.isEmpty)
        #expect(s.ends.isEmpty)
    }

    @Test func silenceBetweenTracksIsAGap() {
        var s = Script()
        s.play(10, Script.music)
        s.play(3, Script.grooveNoise)
        s.play(10, Script.music)
        #expect(s.gaps.count == 1)
        let (start, end, abrupt) = s.gaps[0]
        #expect(abs(start - 10) < 0.05 && abs(end - 13) < 0.05)
        #expect(abrupt)  // -20 → -60 in one hop
        #expect(s.ends.isEmpty)
    }

    @Test func sustainedRunoutEndsTheSide() {
        var s = Script()
        s.play(10, Script.music)
        s.play(8.5, Script.grooveNoise)
        #expect(s.ends.isEmpty)
        s.play(1, Script.grooveNoise)
        #expect(s.ends.count == 1)
        #expect(abs(s.ends[0].0 - 10) < 0.05)
        #expect(s.ends[0].1 == .runout)
        #expect(s.detector.phase == .idle)
    }

    @Test func needleLiftEndsTheSideQuickly() {
        var s = Script()
        s.play(10, Script.music)
        s.play(3.5, Script.needleUp)
        #expect(s.ends.count == 1)
        #expect(s.ends.first?.1 == .needleLift)
        #expect(abs((s.ends.first?.0 ?? 0) - 10) < 0.05)
    }

    @Test func abruptStopIntoSurfaceNoiseIsAGapNotALift() {
        // A song that ends on a hit drops just as fast, but groove noise is still there.
        var s = Script()
        s.play(10, Script.music)
        s.play(4, Script.grooveNoise)
        s.play(5, Script.music)
        #expect(s.ends.isEmpty)
        #expect(s.gaps.count == 1)
    }

    @Test func fadeOutToSilenceIsARunoutNotALift() {
        var s = Script()
        s.play(10, Script.music)
        for i in 0..<300 { s.step((-20 - Float(i) * 0.25, 0.05)) }  // 3 s fade to -95
        s.play(10, Script.needleUp)
        #expect(s.ends.count == 1)
        #expect(s.ends.first?.1 == .runout)
    }

    @Test func nextSideStartsAfterTheFlip() {
        var s = Script()
        s.play(10, Script.music)
        s.play(10, Script.needleUp)
        s.play(20, Script.needleUp)  // flipping
        s.play(3, Script.grooveNoise)
        s.play(5, Script.music)
        #expect(s.starts.count == 2)
        #expect(s.ends.count == 1)
    }

    @Test func configRoundTripsThroughJSON() throws {
        var config = SideDetectorConfig()
        config.startThresholdDB = -38
        config.sideEndSilence = 12
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(SideDetectorConfig.self, from: data) == config)
    }

    @Test func configDecodingKeepsDefaultsForMissingKeys() throws {
        let partial = Data(#"{"startThresholdDB": -38}"#.utf8)
        let config = try JSONDecoder().decode(SideDetectorConfig.self, from: partial)
        #expect(config.startThresholdDB == -38)
        #expect(config.sideEndSilence == SideDetectorConfig().sideEndSilence)
    }
}

import Foundation
