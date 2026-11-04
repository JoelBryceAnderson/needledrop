import Foundation
import Pipeline
import Recognition
import ReplayHarness
import SessionState
import Testing

/// The whole brain, end to end: synthetic side → replay (real-time path, sped up) →
/// detector → session machine → scripted recognizer → playback clock.
@Suite struct EngineTests {
    @Test(.timeLimit(.minutes(1)))
    func followsASideTrackByTrack() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let truth = try SyntheticSide.demo().write(to: url)

        let titles = ["Dreams", "Go Your Own Way", "Songbird"]
        let segments = zip(truth.tracks, titles).map { t, title in
            ScriptedRecognizer.Segment(start: t.start, end: t.end,
                                       track: TrackMatch(title: title, artist: "Fleetwood Mac", isrc: title),
                                       rate: 1.004)
        }
        let engine = Engine(recognizer: ScriptedRecognizer(segments: segments, latency: 4), metadata: nil)
        try await engine.start(source: FileReplaySource(url: url, speed: 40, trailingSilence: 12), lockstep: true)

        var changes: [String?] = []
        var trackStarts: [String: Double] = [:]
        var phases: [SessionPhase] = []
        for await event in engine.events {
            switch event {
            case .trackChanged(let track):
                changes.append(track?.title)
            case .pipeline(.tick):
                let session = engine.session()
                if phases.last != session.phase { phases.append(session.phase) }
                if let track = session.track, let clock = session.clock, trackStarts[track.title] == nil {
                    trackStarts[track.title] = clock.trackStartTime
                }
            case .pipeline(.source(.finished)):
                await engine.stop()
            default:
                break
            }
        }

        #expect(changes == ["Dreams", nil, "Go Your Own Way", nil, "Songbird", nil])
        // The run-out reads as a gap for a few seconds before it's long enough to end the side.
        #expect(phases == [.idle, .listening, .recognizing, .playing, .betweenTracks, .recognizing, .playing,
                           .betweenTracks, .recognizing, .playing, .betweenTracks, .sideEnded])
        for (t, title) in zip(truth.tracks, titles) {
            let start = try #require(trackStarts[title])
            #expect(abs(start - t.start) < 0.1, "\(title) clock start \(start) vs \(t.start)")
        }
    }
}

@Suite struct ManualIdentifyTests {
    @Test(.timeLimit(.minutes(1)))
    func namingATrackByHandWorksLikeAMatch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let truth = try SyntheticSide.demo().write(to: url)
        // A recognizer that never answers (no Shazam).
        let engine = Engine(recognizer: ScriptedRecognizer(segments: []), metadata: nil)
        #expect(await engine.identify(title: "Too early", artist: "Nobody") == false)  // nothing playing yet
        try await engine.start(source: FileReplaySource(url: url, speed: 10, trailingSilence: 0), lockstep: true)

        var named = false
        for await event in engine.events {
            if case .pipeline(.tick(let time, _)) = event, !named, time > truth.tracks[0].start + 8 {
                named = await engine.identify(title: "Paper Weather", artist: "The Creases")
                let session = engine.session()
                #expect(session.track?.title == "Paper Weather" && session.identifiedByHand)
                // Assumed to have started with the music: position ≈ time since the side began.
                let position = try #require(session.clock?.position(at: time))
                #expect(abs(position - (time - truth.tracks[0].start)) < 0.6, "position \(position)")
                await engine.stop()
            }
        }
        #expect(named)
    }
}
