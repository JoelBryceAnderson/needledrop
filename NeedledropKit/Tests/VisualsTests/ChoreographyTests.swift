import Foundation
import Testing
import simd
@testable import Visuals

@Suite("Camera")
struct CameraTests {
    let aspect = 16.0 / 9

    @Test func atRestTheScreenIsTheSheet() throws {
        for p in [SIMD2(0.1, 0.1), SIMD2(aspect / 2, 0.5), SIMD2(aspect - 0.2, 0.9)] {
            let w = try #require(CameraPose.identity.world(of: p, aspect: aspect))
            #expect(simd_distance(w, p) < 1e-9)
        }
    }

    @Test func screenAndWorldRoundTripUnderPerspective() throws {
        let camera = CameraPose(zoom: 1.2, pan: SIMD2(0.1, -0.05), roll: 0.1, pitch: 0.35, yaw: -0.3)
        for p in [SIMD2(0.2, 0.15), SIMD2(aspect / 2, 0.5), SIMD2(aspect - 0.1, 0.85)] {
            let w = try #require(camera.world(of: p, aspect: aspect))
            let back = try #require(camera.screen(of: w, aspect: aspect))
            #expect(simd_distance(back, p) < 1e-9)
        }
    }

    @Test func zoomingInShowsLessOfTheSheet() throws {
        let camera = CameraPose(zoom: 2)
        let left = try #require(camera.world(of: SIMD2(0, 0.5), aspect: aspect))
        let right = try #require(camera.world(of: SIMD2(aspect, 0.5), aspect: aspect))
        #expect(abs((right.x - left.x) - aspect / 2) < 1e-9)
    }

    @Test func aTiltedSheetRecedes() throws {
        // Leaning back: the same screen distance covers more sheet at one edge than the other.
        let camera = CameraPose(pitch: 0.4)
        func span(atY y: Double) throws -> Double {
            let a = try #require(camera.world(of: SIMD2(0.2, y), aspect: aspect))
            let b = try #require(camera.world(of: SIMD2(aspect - 0.2, y), aspect: aspect))
            return b.x - a.x
        }
        let top = try span(atY: 0.05), bottom = try span(atY: 0.95)
        #expect(abs(top - bottom) > 0.1)
        // And the frame centre stays put: w is normalised to 1 there.
        let m = camera.worldFromScreen(aspect: aspect)
        #expect(abs(m.columns.2.z - 1) < 1e-9)
    }
}

/// Loudness over time (a struct, so trailing closures go to the frame callback).
struct Loudness {
    let at: (Double) -> Double
    init(_ at: @escaping (Double) -> Double) { self.at = at }
}

@Suite("Choreographer")
struct ChoreographerTests {
    /// Plays `seconds` of music at `bpm`, calling `body` with each frame.
    func play(_ c: inout Choreographer, from start: Double = 0, seconds: Double, bpm: Double = 120,
              level: Loudness = Loudness { _ in 0.4 }, lyrics: Bool = false, track: String = "a|song",
              _ body: (Double, Choreographer.Frame) -> Void = { _, _ in }) {
        let period = 60 / bpm
        var t = start
        while t < start + seconds {
            let age = (t - start).truncatingRemainder(dividingBy: period)
            let frame = c.update(.init(time: t, level: level.at(t), beatAge: age, tempo: bpm, lyrics: lyrics, trackID: track))
            body(t, frame)
            t += 1.0 / 30
        }
    }

    @Test func theSameSongPlaysOutTheSameWay() {
        var a = Choreographer(), b = Choreographer()
        var framesA: [Choreographer.Frame] = [], framesB: [Choreographer.Frame] = []
        play(&a, seconds: 60) { framesA.append($1) }
        play(&b, seconds: 60) { framesB.append($1) }
        #expect(framesA == framesB)
        // A different song is directed differently.
        var c = Choreographer()
        var framesC: [Choreographer.Frame] = []
        play(&c, seconds: 60, track: "another|song") { framesC.append($1) }
        #expect(framesA != framesC)
    }

    @Test func cutsLandOnPhrases() {
        var c = Choreographer()
        var cutTimes: [Double] = []
        var lastCuts = 0
        play(&c, seconds: 70) { t, frame in
            if frame.cuts != lastCuts { cutTimes.append(t); lastCuts = frame.cuts }
        }
        // The establishing shot at the start, then every 16 beats (8 s at 120 BPM).
        #expect(cutTimes.count == 9)
        for (a, b) in zip(cutTimes, cutTimes.dropFirst()) { #expect(abs((b - a) - 8) < 0.2) }
    }

    @Test func aDropCutsEarly() {
        var c = Choreographer()
        var cutTimes: [Double] = []
        var lastCuts = 0
        // Quiet for 20 s, then loud.
        play(&c, seconds: 30, level: Loudness { $0 < 20 ? 0.12 : 0.9 }) { t, frame in
            if frame.cuts != lastCuts { cutTimes.append(t); lastCuts = frame.cuts }
        }
        #expect(cutTimes.contains { $0 > 20 && $0 < 23 })
    }

    @Test func shotsWithLyricsLeaveRoomForThem() {
        var c = Choreographer()
        play(&c, seconds: 600, lyrics: true) { _, frame in
            let cover = frame.targetCover
            // Never the big centred hero: off to a side, small, or gone.
            #expect(cover.visibility < 0.01 || abs(cover.x - 0.5) > 0.15 || cover.size < 0.35)
        }
    }

    @Test func motionIsSmooth() {
        var c = Choreographer()
        var previous: Choreographer.Frame?
        play(&c, seconds: 300, level: Loudness { 0.3 + 0.3 * sin($0 / 7) }) { _, frame in
            if let p = previous {
                // At 30 fps nothing jumps: the furthest move is a slow glide. (An invisible
                // cover may move anywhere.)
                let seen = min(frame.cover.visibility, p.cover.visibility)
                #expect(abs(frame.cover.x - p.cover.x) * seen < 0.02)
                #expect(abs(frame.cover.size - p.cover.size) * seen < 0.03)
                #expect(abs(frame.cover.visibility - p.cover.visibility) < 0.05)
                #expect(abs(frame.camera.pitch - p.camera.pitch) < 0.02)
                #expect(abs(frame.camera.zoom - p.camera.zoom) < 0.02)
            }
            previous = frame
        }
    }

    @Test func stillHoldsTheOldComposition() {
        var c = Choreographer()
        c.motion = 0
        var last: Choreographer.Frame?
        play(&c, seconds: 60, lyrics: true) { last = $1 }
        #expect(last?.camera == .identity)
        #expect(last?.cover == .asideLeft)
    }

    @Test func aNewTrackOpensOnAnEstablishingShot() {
        var c = Choreographer()
        play(&c, seconds: 40)
        var frame: Choreographer.Frame?
        play(&c, from: 40, seconds: 1, track: "next|track") { frame = $1 }
        #expect(frame?.shot == "establishing")
        #expect(frame?.targetCover == .hero)
    }
}

@Suite("Choreographer with timed lyrics")
struct TimedLyricsTests {
    @Test func holdsStillWhileALineIsUpAndMovesInTheGaps() {
        var c = Choreographer()
        var previous: Choreographer.Frame?
        var movedInGaps = 0
        var t = 0.0
        while t < 120 {
            let inLine = t.truncatingRemainder(dividingBy: 4) < 2.8
            var input = Choreographer.Input(time: t, level: 0.4, beatAge: t.truncatingRemainder(dividingBy: 0.5),
                                            tempo: 120, lyrics: true, trackID: "a|song")
            input.lineShowing = inLine
            input.nextLineIn = 4 - t.truncatingRemainder(dividingBy: 4)
            let frame = c.update(input)
            if let p = previous, t > 1 {
                if inLine {
                    #expect(frame.cover == p.cover, "cover moved during a line at \(t)")
                    #expect(frame.camera == p.camera, "camera moved during a line at \(t)")
                } else if frame.cover != p.cover || frame.camera != p.camera {
                    movedInGaps += 1
                }
            }
            previous = frame
            t += 1.0 / 30
        }
        #expect(movedInGaps > 100)
    }
}

@Suite("Choreographer following a score")
struct ScoredChoreographyTests {
    /// Lines every 4 s (up 2.8 s each); calls `body` with each frame and the next line's index.
    func play(_ c: inout Choreographer, seconds: Double, _ body: (Double, Int, Choreographer.Frame) -> Void) {
        var t = 0.0
        while t < seconds {
            let line = Int(t / 4)
            var input = Choreographer.Input(time: t, level: 0.4, beatAge: t.truncatingRemainder(dividingBy: 0.5),
                                            tempo: 120, lyrics: true, trackID: "a|song")
            input.lineShowing = t.truncatingRemainder(dividingBy: 4) < 2.8
            input.nextLineIn = 4 - t.truncatingRemainder(dividingBy: 4)
            input.nextLineIndex = line + 1
            body(t, line, c.update(input))
            t += 1.0 / 30
        }
    }

    @Test func aStillSectionHoldsAndAKeyframeLands() {
        var c = Choreographer()
        c.score = TrackScore(sections: [.init(startLine: 0, label: "verse", energy: .still),
                                        .init(startLine: 4, label: "chorus", energy: .directed)],
                             keyframes: [.init(beforeLine: 4, framing: .leanBack, intensity: 1, creases: 2, transition: .glide)])
        var cutsBeforeChorus = 0
        var chorus: Choreographer.Frame?
        play(&c, seconds: 17.5) { t, line, frame in
            if t > 1, t < 14 { cutsBeforeChorus = frame.cuts }
            if line == 4, t.truncatingRemainder(dividingBy: 4) < 2.8 { chorus = frame }
        }
        #expect(cutsBeforeChorus == 1)  // just the establishing shot: the verse holds
        #expect(chorus?.shot == "score:lean_back")
        #expect((chorus?.camera.pitch ?? 0) > 0.4)
        #expect(chorus?.directive?.creases == 2)
    }

    @Test func aKeyframeInAGapTooShortWaitsForTheNextOne() {
        var c = Choreographer()
        c.score = TrackScore(sections: [.init(startLine: 0, label: "verse", energy: .still)],
                             keyframes: [.init(beforeLine: 2, framing: .turnLeft, intensity: 1, transition: .refold)])
        // Gaps are 1.2 s: a refold needs 1.8 s with settling. It never fits here, so the
        // picture holds rather than cramming it in.
        var shots: Set<String> = []
        play(&c, seconds: 20) { _, _, frame in shots.insert(frame.shot) }
        #expect(!shots.contains("score:turn_left"))
    }
}
