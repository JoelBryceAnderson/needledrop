import AudioCapture
import Foundation
import Pipeline
import ReplayHarness
import SessionState
import Testing

/// End-to-end: synthetic sides through the full analysis path, checked against ground truth.
@Suite struct ReplayIntegrationTests {
    @Test(arguments: [44_100.0, 48_000, 96_000])
    func demoSideMatchesGroundTruth(sampleRate: Double) throws {
        let side = SyntheticSide.demo(sampleRate: sampleRate)
        let (left, right, truth) = side.render()
        let result = OfflineReplay.analyze(left: left, right: right, sampleRate: sampleRate, keepTimeline: true)
        let report = SideReport(events: result.events, timeline: result.timeline)

        try #require(report.sides.count == 1, "events: \(result.events)")
        let found = report.sides[0]
        #expect(found.endReason == .runout)
        try #require(found.tracks.count == truth.tracks.count)
        for (track, expected) in zip(found.tracks, truth.tracks) {
            #expect(abs(track.start - expected.start) < 0.3, "start \(track.start) vs \(expected.start)")
            #expect(abs(track.end - expected.end) < 0.3, "end \(track.end) vs \(expected.end)")
            let tempo = try #require(track.tempo)
            #expect(abs(tempo - expected.bpm) < 2, "tempo \(tempo) vs \(expected.bpm)")
        }
    }

    @Test func surfaceNoiseAloneNeverStartsASide() {
        let side = SyntheticSide(segments: [.surfaceNoise(seconds: 30), .runout(seconds: 20)])
        let (left, right, _) = side.render()
        #expect(OfflineReplay.analyze(left: left, right: right, sampleRate: side.sampleRate).events.isEmpty)
    }

    @Test func needleLiftMidTrack() {
        let side = SyntheticSide(segments: [
            .surfaceNoise(seconds: 2), .track(seconds: 15, bpm: 110, rootHz: 220, abruptEnd: true), .digitalSilence(seconds: 6),
        ])
        let (left, right, truth) = side.render()
        let events = OfflineReplay.analyze(left: left, right: right, sampleRate: side.sampleRate, trailingSilence: 0).events
        guard case .sideEnded(_, let end, let reason)? = events.last else {
            Issue.record("no side end in \(events)")
            return
        }
        #expect(reason == .needleLift)
        #expect(abs(end - truth.tracks[0].end) < 0.3)
    }

    @Test func wavFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let side = SyntheticSide.demo()
        try side.write(to: url)
        let (left, right, _) = side.render()

        let fromFile = try OfflineReplay.analyze(url: url)
        let inMemory = OfflineReplay.analyze(left: left, right: right, sampleRate: side.sampleRate)
        #expect(fromFile.format == CaptureFormat(sampleRate: 48_000, channelCount: 2))
        #expect(fromFile.events.count == inMemory.events.count)
        for (a, b) in zip(fromFile.events, inMemory.events) {
            #expect(abs(a.time - b.time) < 0.05, "\(a) vs \(b)")  // 24-bit quantisation only
        }
    }

    /// The real-time path: file → ring buffer → analysis thread → event stream.
    @Test(.timeLimit(.minutes(1)))
    func liveReplayPathProducesTheSameEvents() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SyntheticSide.demo().write(to: url)
        let offline = try OfflineReplay.analyze(url: url, trailingSilence: 12)

        let pipeline = ListeningPipeline()
        try pipeline.start(source: FileReplaySource(url: url, speed: 40, trailingSilence: 12))
        var live: [SideEvent] = []
        for await event in pipeline.events {
            if case .side(let e) = event { live.append(e) }
            if case .source(.finished) = event { break }
        }
        pipeline.stop()

        #expect(live.count == offline.events.count, "live \(live) vs offline \(offline.events)")
        for (a, b) in zip(live, offline.events) {
            #expect(abs(a.time - b.time) < 0.05)
        }
        #expect(pipeline.snapshot().droppedFrames == 0)
    }
}
