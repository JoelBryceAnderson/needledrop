import Archive
import AVFoundation
import Foundation
import Pipeline
import Recognition
import ReplayHarness
import Testing

/// Synthetic side → live replay path → recorder → splitter → ALAC files + library rows.
@Suite struct ArchiveEndToEndTests {
    @Test(.timeLimit(.minutes(1)))
    func archivesASideAsTaggedTracks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-archive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("side.wav")
        let truth = try SyntheticSide.demo().write(to: wav)

        let titles = ["Dreams", "Go Your Own Way", "Songbird"]
        let segments = zip(truth.tracks, titles).map { t, title in
            ScriptedRecognizer.Segment(start: t.start, end: t.end, track: TrackMatch(title: title, artist: "Fleetwood Mac", isrc: title))
        }
        var settings = ArchiveSettings()
        settings.rootPath = dir.appendingPathComponent("Archive").path
        let library = try Library()
        let engine = Engine(recognizer: ScriptedRecognizer(segments: segments), metadata: nil,
                            archiver: Archiver(settings: settings, library: library))
        try await engine.start(source: FileReplaySource(url: wav, speed: 20, trailingSilence: 12))

        var report: ArchiveReport?
        for await event in engine.events {
            if case .archived(let r) = event {
                report = r
                await engine.stop()
            }
        }

        let archived = try #require(report)
        #expect(archived.error == nil)
        #expect(archived.tracks.map(\.title) == titles)
        #expect(archived.tracks.allSatisfy { !$0.uncertain })

        // Boundaries sit at the gap midpoints; first/last get lead-in and tail.
        let starts = [truth.tracks[0].start - TrackSplitter.leadIn,
                      (truth.tracks[0].end + truth.tracks[1].start) / 2,
                      (truth.tracks[1].end + truth.tracks[2].start) / 2]
        let ends = [starts[1], starts[2], truth.tracks[2].end + TrackSplitter.tail]
        for (i, track) in archived.tracks.enumerated() {
            let path = try #require(track.path)
            #expect(path.hasSuffix("Fleetwood Mac/Unknown Album/\(titles[i]).m4a"), "\(path)")
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let duration = Double(file.length) / file.fileFormat.sampleRate
            #expect(abs(duration - (ends[i] - starts[i])) < 0.4, "\(titles[i]): \(duration) vs \(ends[i] - starts[i])")
        }
        #expect(try library.recordings(forTrackIdentity: "isrc:Dreams").count == 1)
        // Raw side discarded, nothing left half-written.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: settings.root.appendingPathComponent(".incoming").path)
        #expect(leftovers.isEmpty)
    }
}
