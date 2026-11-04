import Recognition
import SessionState
import Testing

private let trackA = TrackMatch(title: "Dreams", artist: "Fleetwood Mac", isrc: "A")
private let trackB = TrackMatch(title: "Never Going Back Again", artist: "Fleetwood Mac", isrc: "B")

/// Drives the machine with ticks every 0.25 s and records effects with their times.
private struct Run {
    var machine = SessionMachine()
    var time = 0.0
    var effects: [(Double, SessionEffect)] = []
    var detector: SidePhase = .idle

    mutating func send(_ input: SessionInput) {
        effects += machine.handle(input).map { (time, $0) }
    }

    mutating func advance(to t: Double) {
        while time + 0.25 <= t + 1e-9 {
            time += 0.25
            send(.tick(time: time, detector: detector))
        }
    }

    mutating func match(_ track: TrackMatch, position: Double) {
        var m = track
        m.position = position
        send(.match(m, at: time))
    }

    var starts: [Double] { effects.filter { $0.1 == .startRecognition }.map(\.0) }
    var changes: [TrackMatch?] { effects.compactMap { if case .trackChanged(let t) = $0.1 { t } else { nil } } }
}

@Suite struct SessionMachineTests {
    @Test func listensWhileTheDetectorArms() {
        var run = Run()
        run.detector = .arming(since: 0)
        run.advance(to: 1)
        #expect(run.machine.phase == .listening)
        run.detector = .idle
        run.advance(to: 2)
        #expect(run.machine.phase == .idle)
    }

    @Test func sideStartOpensAWindowAndAMatchPlays() {
        var run = Run()
        run.advance(to: 3)
        run.send(.side(.sideStarted(at: 3)))
        #expect(run.machine.phase == .recognizing)
        #expect(run.machine.isRecognizing)
        run.advance(to: 9)
        run.match(trackA, position: 6)
        #expect(run.machine.phase == .playing)
        #expect(run.machine.track == trackA.with(position: 6))
        #expect(!run.machine.isRecognizing)
        #expect(run.changes.map { $0?.identity } == ["isrc:A"])
        #expect(abs(run.machine.clock!.position(at: 19) - 16) < 1e-9)
    }

    @Test func rematchesPeriodicallyAndRefinesTheClock() {
        var run = Run()
        run.send(.side(.sideStarted(at: 0)))
        run.advance(to: 5)
        run.match(trackA, position: 5)
        run.advance(to: 29.9)
        #expect(run.starts.count == 1)
        run.advance(to: 30)
        #expect(run.starts.count == 2)
        run.advance(to: 34)
        run.match(trackA, position: 34.2)
        #expect(run.machine.matchCount == 2)
        #expect(run.machine.clock!.anchors.count == 2)
        #expect(run.changes.count == 1)  // same track: no change event
    }

    @Test func gapThenNewTrack() {
        var run = Run()
        run.send(.side(.sideStarted(at: 0)))
        run.advance(to: 5)
        run.match(trackA, position: 5)
        run.advance(to: 200)
        run.send(.side(.gapStarted(at: 199)))
        #expect(run.machine.phase == .betweenTracks)
        #expect(!run.machine.isRecognizing)
        run.advance(to: 202)
        run.send(.side(.trackGap(start: 199, end: 202, abrupt: false)))
        #expect(run.machine.phase == .recognizing)
        #expect(run.machine.isRecognizing)
        #expect(run.machine.track == nil)
        run.advance(to: 207)
        run.match(trackB, position: 5)
        #expect(run.changes.map { $0?.identity } == ["isrc:A", nil, "isrc:B"])
    }

    @Test func aTrackNamedJustBeforeTheGapSurvivesIt() {
        // Apple Music announces the next song as it starts; the side detector hears the
        // quiet between songs a moment later. The new track (and its lyrics) must survive.
        var run = Run()
        run.send(.side(.sideStarted(at: 0)))
        run.advance(to: 5)
        run.match(trackA, position: 5)
        run.advance(to: 198)
        run.match(trackB, position: 0)
        run.advance(to: 199)
        run.send(.side(.gapStarted(at: 199)))
        run.advance(to: 201)
        run.send(.side(.trackGap(start: 199, end: 201, abrupt: false)))
        #expect(run.machine.phase == .playing)
        #expect(run.machine.track?.identity == "isrc:B")
        #expect(abs(run.machine.clock!.position(at: 210) - 12) < 1e-9)
        #expect(run.changes.map { $0?.identity } == ["isrc:A", "isrc:B"])
    }

    @Test func aRematchOfTheOldTrackBeforeAGapDoesNotHoldIt() {
        var run = Run()
        run.send(.side(.sideStarted(at: 0)))
        run.advance(to: 5)
        run.match(trackA, position: 5)
        run.advance(to: 197)
        run.match(trackA, position: 197)  // same track: refines the clock, names nothing new
        run.send(.side(.gapStarted(at: 199)))
        run.advance(to: 201)
        run.send(.side(.trackGap(start: 199, end: 201, abrupt: false)))
        #expect(run.machine.track == nil)
        #expect(run.machine.phase == .recognizing)
    }

    @Test func segueWithoutAGapIsCaughtByTheRematch() {
        var run = Run()
        run.send(.side(.sideStarted(at: 0)))
        run.advance(to: 5)
        run.match(trackA, position: 5)
        run.advance(to: 34)
        run.match(trackB, position: 3)
        #expect(run.machine.track?.identity == "isrc:B")
        #expect(abs(run.machine.clock!.position(at: 34) - 3) < 1e-9)
    }

    @Test func knownDurationPullsTheNextMatchToTheTrackEnd() {
        var run = Run()
        run.send(.side(.sideStarted(at: 0)))
        run.advance(to: 5)
        run.match(trackA, position: 100)  // started 100 s before the side? no: needle dropped mid-song
        run.send(.trackDuration(identity: "isrc:A", seconds: 110))
        // Track ends at audio time 15; grace 3 s → window opens at 18, not 30.
        run.advance(to: 18.25)
        #expect(run.starts.last == 18)
    }

    @Test func givesUpAndCallsItUnknownThenKeepsTrying() {
        var run = Run()
        run.send(.side(.sideStarted(at: 0)))
        run.advance(to: 60)
        #expect(run.machine.unidentified)
        #expect(run.machine.phase == .playing)
        #expect(run.changes.count == 1 && run.changes[0] == nil)
        let windowsSoFar = run.starts.count
        run.advance(to: 120)
        #expect(run.starts.count > windowsSoFar)  // still retrying, slowly
        run.match(trackA, position: 80)
        #expect(!run.machine.unidentified)
        #expect(run.machine.track?.identity == "isrc:A")
    }

    @Test func sideEndStopsEverythingAndIgnoresLateMatches() {
        var run = Run()
        run.send(.side(.sideStarted(at: 0)))
        run.advance(to: 5)
        run.match(trackA, position: 5)
        run.advance(to: 30.5)
        #expect(run.machine.isRecognizing)
        run.send(.side(.sideEnded(start: 0, end: 30, reason: .needleLift)))
        #expect(run.machine.phase == .sideEnded)
        #expect(!run.machine.isRecognizing)
        #expect(run.machine.track == nil)
        run.match(trackA, position: 31)
        #expect(run.machine.track == nil)
        run.advance(to: 60)
        #expect(run.machine.phase == .sideEnded)
        #expect(run.effects.last?.1 == .trackChanged(nil))
    }
}

private extension TrackMatch {
    func with(position: Double) -> TrackMatch {
        var copy = self
        copy.position = position
        return copy
    }
}
