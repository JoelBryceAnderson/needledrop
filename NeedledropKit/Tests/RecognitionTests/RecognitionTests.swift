import Recognition
import Testing

@Suite struct PlaybackClockTests {
    @Test func runsAtSkewRateFromOneAnchor() {
        let clock = PlaybackClock(time: 100, position: 30, frequencySkew: 0.01)
        #expect(abs(clock.position(at: 110) - 40.1) < 1e-9)
        #expect(abs(clock.trackStartTime - (100 - 30 / 1.01)) < 1e-9)
    }

    @Test func smallCorrectionsAreSlewedNotJumped() {
        var clock = PlaybackClock(time: 0, position: 0)
        let error = clock.add(time: 25, position: 25.5)
        #expect(abs(error - 0.5) < 1e-9)
        // Continuous at the correction…
        #expect(abs(clock.position(at: 25) - 25) < 1e-9)
        // …halfway through the slew…
        #expect(abs(clock.position(at: 26) - 26.25) < 1e-9)
        // …and fully corrected after it.
        #expect(abs(clock.position(at: 30) - 30.5) < 1e-9)
    }

    @Test func bigErrorsSnap() {
        var clock = PlaybackClock(time: 0, position: 0)
        clock.add(time: 25, position: 90)  // needle moved forward
        #expect(abs(clock.position(at: 25) - 90) < 1e-9)
        #expect(clock.anchors.count == 1)
    }

    @Test func slopeFitCorrectsDriftOnceAnchorsSpanLongEnough() {
        // Record runs 0.8% fast, Shazam reports no skew.
        let rate = 1.008
        var clock = PlaybackClock(time: 0, position: 0)
        for t in stride(from: 25.0, through: 100, by: 25) {
            clock.add(time: t, position: t * rate)
        }
        #expect(abs(clock.rate - rate) < 1e-6)
        #expect(abs(clock.position(at: 160) - 160 * rate) < 0.01)
    }

    @Test func confidenceFallsWithStalenessAndBigCorrections() {
        var clock = PlaybackClock(time: 0, position: 0)
        let fresh = clock.confidence(at: 1)
        #expect(clock.confidence(at: 300) < fresh / 2)
        clock.add(time: 25, position: 25)
        #expect(clock.confidence(at: 26) > fresh)
        clock.add(time: 50, position: 52.5)
        #expect(clock.confidence(at: 51) < 0.5)
    }
}

@Suite struct ScriptedRecognizerTests {
    @Test func matchesAfterLatencyInsideASegment() {
        let track = TrackMatch(title: "A", artist: "X", isrc: "A1")
        let recognizer = ScriptedRecognizer(segments: [.init(start: 10, end: 40, track: track, offset: 5, rate: 1.01)], latency: 4)
        let results = Box()
        recognizer.setHandler { results.append($0) }
        let silence = [Float](repeating: 0, count: 480)
        func run(from: Double, to: Double) {
            recognizer.beginWindow(sampleRate: 48_000)
            for t in stride(from: from, to: to, by: 0.01) {
                silence.withUnsafeBufferPointer { recognizer.feed($0.baseAddress!, frameCount: 480, endTime: t) }
            }
            recognizer.endWindow()
        }
        run(from: 0, to: 9)
        #expect(results.matches.isEmpty)
        run(from: 12, to: 20)
        let match = try! #require(results.matches.first)
        #expect(results.matches.count == 1)
        #expect(abs(match.position - (5 + 6 * 1.01)) < 0.02)
        #expect(abs(match.frequencySkew - 0.01) < 1e-9)
    }

    @Test func identityPrefersStableIDs() {
        #expect(TrackMatch(title: "T", artist: "A", appleMusicID: "1", isrc: "US1").identity == "isrc:US1")
        #expect(TrackMatch(title: "T", artist: "A", appleMusicID: "1").identity == "am:1")
        #expect(TrackMatch(title: "Song", artist: "Band").isSameTrack(as: TrackMatch(title: "song", artist: "BAND", position: 9)))
    }
}

private final class Box: @unchecked Sendable {
    var matches: [TrackMatch] = []
    func append(_ r: RecognizerResult) {
        if case .match(let m) = r { matches.append(m) }
    }
}
