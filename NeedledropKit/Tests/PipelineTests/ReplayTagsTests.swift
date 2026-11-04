import AVFoundation
import Archive
import Foundation
import ReplayHarness
import Testing

@Suite struct ReplayTagsTests {
    @Test func aTaggedSongFileBecomesAScriptedTrack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("needledrop-tags-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 10 s tagged ALAC file, made with the archive's own encoder.
        let raw = dir.appendingPathComponent("raw.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: raw, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000)!
            buffer.frameLength = 480_000
            for c in 0..<2 { for i in 0..<480_000 { buffer.floatChannelData![c][i] = 0.2 * sinf(Float(i) * 0.05) } }
            try file.write(from: buffer)
        }
        var tags = TrackTags(title: "Origami Heart", artist: "The Creases")
        tags.album = "Paper Weather"
        let song = dir.appendingPathComponent("song.m4a")
        _ = try await TrackEncoder.encode(from: raw, start: 0, end: 10, to: song, format: .alac, tags: tags)

        let script = try #require(await ReplayScript.fromTags(of: song, loops: 3, gap: 12))
        #expect(script.tracks.count == 3)
        #expect(script.tracks[0].title == "Origami Heart" && script.tracks[0].artist == "The Creases")
        #expect(abs(script.tracks[0].end - 10) < 0.05)
        #expect(abs(script.tracks[1].start - 22) < 0.05)
        // Untagged audio (the synthetic WAV) has nothing to go on.
        #expect(await ReplayScript.fromTags(of: raw) == nil)
    }
}
